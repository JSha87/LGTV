#Requires -Version 5.1
<#
.SYNOPSIS
    LG WebOS TV controller - PowerShell 5.1, optimized, memory-safe, and file-lock resilient.
.NOTES
    DRY pass: shared retry/disposal/response-validation helpers replace duplicated scaffolding
    that used to be re-written per call site (file IO, TV connect, registration, input-switch
    retry, WOL bootstrap). Behavior and all safety mechanisms (mutex, watchdog, atomic writes,
    DPAPI, cert/TLS quirk handling) are preserved; see inline comments where a shared helper
    replaces what was previously copy-pasted logic.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('startup', 'toggle', 'shutdown', 'scan')]
    [string]$Command
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

# =====================================================================
# Configuration
# =====================================================================

$programData = if ([string]::IsNullOrEmpty($env:PROGRAMDATA)) { 'C:\ProgramData' } else { $env:PROGRAMDATA }
$StorageDir = Join-Path $programData 'LGTVControl'
$StoreFile  = Join-Path $StorageDir 'lgtv_store.json'
$LogFile    = Join-Path $StorageDir 'lgtv.log'

$Script:TV_MAC = $null
$Script:SubnetInfo = $null

$MaxScanTimeSec      = 5

$PersonalInput       = 'com.webos.app.hdmi3'
$WorkInput           = 'com.webos.app.hdmi4'

$WolPort             = 9
$ConnectTimeoutMs    = 5000
$SendTimeoutMs       = 10000
$ReceiveTimeoutMs    = 10000
$RegistrationTimeoutMs = 4000

$MaxLogSizeBytes       = 10MB
$MaxConnectRetries     = 5
$MaxRegisterRetries    = 5
$MaxInputSwitchRetries = 5
$WatchdogSec           = 60
$VerifyInputTimeoutMs  = 8000
$VerifyInputPollMs     = 400

$WebOSWssPort = 3001

$Script:InstanceMutex = $null
$Script:WatchdogTimer = $null
$Script:WatchdogEvent = $null

# =====================================================================
# Security & DPAPI
# =====================================================================

function Protect-String([string]$PlainText) {
    if ([string]::IsNullOrEmpty($PlainText)) { return $PlainText }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $encrypted = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Convert]::ToBase64String($encrypted)
}

function Unprotect-String([string]$EncryptedText) {
    if ([string]::IsNullOrEmpty($EncryptedText)) { return $EncryptedText }
    try {
        $bytes = [Convert]::FromBase64String($EncryptedText)
        $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [System.Text.Encoding]::UTF8.GetString($decrypted)
    } catch {
        return $null
    }
}

# =====================================================================
# Subnet / CIDR helpers
# =====================================================================
# BROADCAST_IP used to be a separate config field the user had to keep in
# sync with SUBNET by hand. It's derived here instead: SUBNET is expected
# in CIDR form (e.g. "192.168.1.0/24"), and both the broadcast address and
# the scannable host range come directly from that single value.

function ConvertTo-IPUInt32 {
    param([Parameter(Mandatory = $true)][string]$IpAddress)
    $bytes = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return [BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-IPUInt32 {
    param([Parameter(Mandatory = $true)][uint32]$Value)
    $bytes = [BitConverter]::GetBytes($Value)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-SubnetInfo {
    <#
        Parses CIDR notation into network address, broadcast address, and
        the number of scannable host IPs. Throws with a clear message if
        SUBNET isn't in the expected "a.b.c.d/nn" form.
    #>
    param([Parameter(Mandatory = $true)][string]$Cidr)

    if ($Cidr -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$') {
        throw "SUBNET must be in CIDR format, e.g. 192.168.1.0/24 (got: '$Cidr')"
    }
    $networkIpText = $Matches[1]
    $prefixLength = [int]$Matches[2]
    if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
        throw "Invalid CIDR prefix length in SUBNET: $Cidr"
    }

    $rawValue = ConvertTo-IPUInt32 -IpAddress $networkIpText
    $hostBits = 32 - $prefixLength
    $maskValue = if ($hostBits -eq 0) { [uint32]::MaxValue } else { [uint32]::MaxValue -shl $hostBits }
    $networkValue = $rawValue -band $maskValue
    $broadcastValue = $networkValue -bor (-bnot $maskValue -band [uint32]::MaxValue)

    $hostCount = if ($hostBits -le 1) { 0 } else { [uint32]([math]::Pow(2, $hostBits)) - 2 }

    return [pscustomobject]@{
        NetworkValue      = $networkValue
        BroadcastValue    = $broadcastValue
        NetworkAddress    = ConvertFrom-IPUInt32 -Value $networkValue
        BroadcastAddress  = ConvertFrom-IPUInt32 -Value $broadcastValue
        HostCount         = $hostCount
        PrefixLength      = $prefixLength
    }
}

# =====================================================================
# Shared helpers (retry / disposal / TV-response validation)
# =====================================================================
# Consolidated here because the same three shapes of code were being
# hand-written at every call site throughout the script:
#   1. "retry this N times, backing off between attempts"
#   2. "dispose/disconnect this thing and swallow any error"
#   3. "the TV sent back a response envelope - did it actually succeed?"

function Invoke-WithRetry {
    <#
        Runs Action (receiving the 1-based attempt number) up to
        MaxAttempts times. On failure, OnRetry (receiving the error and
        the attempt number) runs BEFORE sleeping DelayMs - but only when
        another attempt will actually follow, never on the final failed
        attempt. That lets callers put expensive recovery work (reconnects,
        network waits) in OnRetry without it running right before giving
        up anyway. On final failure the original exception propagates
        unchanged (so the caller's own error message/stack is preserved).
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$MaxAttempts = 5,
        [int]$DelayMs = 200,
        [scriptblock]$OnRetry
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try { return (& $Action $i) }
        catch {
            if ($i -eq $MaxAttempts) { throw }
            if ($OnRetry) { & $OnRetry $_ $i }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Close-Quietly {
    param($Disposable)
    if ($Disposable) { try { $Disposable.Dispose() } catch {} }
}

function Disconnect-Quietly {
    param($Client)
    if ($Client) { try { $Client.Disconnect() } catch {} }
}

function Confirm-TVResponse {
    <# Validates a ssap:// response envelope; throws "<FailMessage>: <reason>" on rejection. #>
    param([Parameter(Mandatory = $true)]$Response, [Parameter(Mandatory = $true)][string]$FailMessage)
    if (-not $Response -or $Response.type -ne 'response') { throw 'No response from TV' }
    if ($Response.payload.returnValue) { return }
    $errText = if ([string]::IsNullOrEmpty([string]$Response.payload.errorText)) { 'Unknown error' } else { [string]$Response.payload.errorText }
    throw "${FailMessage}: $errText"
}

# =====================================================================
# Safe File IO (Prevents File Locking Errors AND torn/corrupted writes)
# =====================================================================

function Read-JsonFileSafe {
    param([string]$Path)
    Invoke-WithRetry {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        try { $json = $sr.ReadToEnd() } finally { $sr.Dispose(); $fs.Dispose() }
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        return ($json | ConvertFrom-Json)
    }
}

function Write-JsonFileSafe {
    <#
        Writes to a temp file, then atomically replaces the real file via
        Move-Item -Force. This means a mid-write interruption (e.g. the
        watchdog force-killing the process) leaves an orphaned .tmp file
        instead of corrupting the live store - a reader only ever sees
        either the fully-old or fully-new content, never a torn write.

        Move-Item -Force (not [System.IO.File]::Replace) - Replace() can
        throw "The path is not of a legal form" on Windows PowerShell 5.1
        when the process's current working directory is itself a mapped
        network drive, even though both paths here are fully-qualified
        and local. Move-Item -Force still performs an atomic rename on
        the same NTFS volume and overwrites the destination without that
        quirk.
    #>
    param([string]$Path, [object]$Data)
    $json = $Data | ConvertTo-Json -Depth 10
    $tempPath = "$Path.tmp"
    Invoke-WithRetry {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        $fs = New-Object System.IO.FileStream($tempPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $sw = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
        try { $sw.Write($json); $sw.Flush() } finally { $sw.Dispose(); $fs.Dispose() }

        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    } | Out-Null
}

# =====================================================================
# Registration payload
# =====================================================================

$RegistrationPayload = @{
    forcePairing = $false
    manifest = @{
        appVersion      = '1.1'
        manifestVersion = 1
        permissions = @(
            'LAUNCH', 'LAUNCH_WEBAPP', 'APP_TO_APP', 'CLOSE', 'CONTROL_AUDIO',
            'CONTROL_DISPLAY', 'CONTROL_INPUT_JOYSTICK', 'CONTROL_INPUT_MEDIA_RECORDING',
            'CONTROL_INPUT_MEDIA_PLAYBACK', 'CONTROL_INPUT_TV', 'CONTROL_POWER',
            'READ_APP_STATUS', 'READ_CURRENT_CHANNEL', 'READ_INPUT_DEVICE_LIST',
            'READ_RUNNING_APPS', 'READ_TV_CHANNEL_LIST', 'WRITE_NOTIFICATION_TOAST',
            'READ_POWER_STATE', 'CONTROL_TV_SCREEN', 'CONTROL_TV_STANBY'
        )
        signatures = @(
            @{
                signatureVersion = 1
                signature = 'eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9'
            }
        )
        signed = @{
            appId               = 'com.lge.test'
            created             = '20140509'
            localizedAppNames   = @{ '' = 'LG Remote App' }
            localizedVendorNames = @{ '' = 'LG Electronics' }
            permissions = @(
                'CONTROL_INPUT_TEXT', 'CONTROL_MOUSE_AND_KEYBOARD', 'READ_INSTALLED_APPS',
                'CONTROL_POWER', 'READ_CURRENT_CHANNEL', 'READ_RUNNING_APPS'
            )
            serial   = '2f930e2d2cfe083771f68e4fe7bb07'
            vendorId = 'com.lge'
        }
    }
    pairingType = 'PROMPT'
}

# =====================================================================
# Logging
# =====================================================================

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message, [switch]$IsError)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] $Message"
    Write-Host $line

    if (-not $IsError) { return }

    try {
        if (-not (Test-Path -LiteralPath $StorageDir)) { New-Item -ItemType Directory -Path $StorageDir -Force | Out-Null }
        if (Test-Path -LiteralPath $LogFile) {
            try {
                if ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogSizeBytes) {
                    $backup = "$LogFile.old"
                    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
                    Rename-Item -LiteralPath $LogFile -NewName (Split-Path -Leaf $backup) -Force
                }
            } catch {
                try { Set-Content -LiteralPath $LogFile -Value "[$stamp] Log rotated due to size" -Encoding UTF8 } catch {}
            }
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {}
}

# =====================================================================
# Safety mechanisms
# =====================================================================

function Confirm-SingleInstance {
    $mutexName = 'Global\LGTV_Unified_Controller_Mutex_Lock'
    $createdNew = $false
    try {
        $Script:InstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
    } catch {
        Write-Log "Unable to create instance mutex: $($_.Exception.Message)" -IsError
        exit 0
    }
    if (-not $createdNew) { exit 0 }
}

function Start-Watchdog {
    param([Parameter(Mandatory = $true)][int]$Seconds)
    $timer = New-Object System.Timers.Timer
    $timer.Interval = $Seconds * 1000
    $timer.AutoReset = $false
    $processId = $PID
    $storage = $StorageDir
    $log = $LogFile
    $watchdogSeconds = $Seconds

    $action = {
        try {
            $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $line = "[$stamp] WATCHDOG: Script exceeded $watchdogSeconds seconds. Force exiting."
            try {
                if (-not (Test-Path -LiteralPath $storage)) { New-Item -ItemType Directory -Path $storage -Force | Out-Null }
                Add-Content -LiteralPath $log -Value $line -Encoding UTF8
            } catch {}
            Write-Host $line
        } catch {}
        try { Stop-Process -Id $processId -Force } catch {}
    }
    $registration = Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action $action
    $timer.Start()
    $Script:WatchdogTimer = $timer
    $Script:WatchdogEvent = $registration
    return $timer
}

function Stop-Watchdog {
    if ($Script:WatchdogEvent) { try { Unregister-Event -SubscriptionId $Script:WatchdogEvent.Id -Force } catch {}; $Script:WatchdogEvent = $null }
    if ($Script:WatchdogTimer) { try { $Script:WatchdogTimer.Stop(); $Script:WatchdogTimer.Dispose() } catch {}; $Script:WatchdogTimer = $null }
}

# =====================================================================
# Store / configuration
# =====================================================================

function Initialize-Store {
    $template = [ordered]@{
        _comment     = 'Fill in TV_MAC and SUBNET (CIDR format, e.g. 192.168.1.0/24). Broadcast address is derived automatically. Script populates tv_ip and client_key automatically.'
        TV_MAC       = ''
        SUBNET       = ''
        tv_ip        = ''
        client_key   = ''
    }

    try {
        if (-not (Test-Path -LiteralPath $StorageDir)) { New-Item -ItemType Directory -Path $StorageDir -Force | Out-Null }
    } catch {
        Write-Log "Failed to create storage directory: $($_.Exception.Message)" -IsError
        return $false
    }

    if (-not (Test-Path -LiteralPath $StoreFile)) {
        Write-Log 'Store file not found - creating template'
        try {
            Write-JsonFileSafe -Path $StoreFile -Data $template
            Write-Log "Created template store file at: $StoreFile"
            return $false
        } catch {
            Write-Log "Failed to create store file: $($_.Exception.Message)" -IsError
            return $false
        }
    }

    try {
        $data = Read-JsonFileSafe -Path $StoreFile
        if (-not $data) {
            Write-JsonFileSafe -Path $StoreFile -Data $template
            return $false
        }
        $modified = $false
        foreach ($key in $template.Keys) {
            if (-not ($data.PSObject.Properties.Name -contains $key)) {
                $data | Add-Member -NotePropertyName $key -NotePropertyValue $template[$key]
                $modified = $true
            }
        }
        if ($modified) {
            Write-JsonFileSafe -Path $StoreFile -Data $data
        }
        return $true
    } catch {
        Write-Log "Failed to update store file: $($_.Exception.Message)" -IsError
        return $false
    }
}

function Import-Config {
    try {
        if (-not (Test-Path -LiteralPath $StoreFile)) { return $false }
        $data = Read-JsonFileSafe -Path $StoreFile
        if (-not $data) { return $false }
        $Script:TV_MAC = [string]$data.TV_MAC
        $subnetRaw = [string]$data.SUBNET

        if ([string]::IsNullOrWhiteSpace($Script:TV_MAC) -or [string]::IsNullOrWhiteSpace($subnetRaw)) { return $false }

        try {
            $Script:SubnetInfo = Get-SubnetInfo -Cidr $subnetRaw
        } catch {
            Write-Log "Invalid SUBNET value: $($_.Exception.Message)" -IsError
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Set-StoredData {
    param([Parameter(Mandatory = $true)][string]$Ip, [AllowEmptyString()][string]$Key)
    try {
        if (-not (Test-Path -LiteralPath $StorageDir)) { New-Item -ItemType Directory -Path $StorageDir -Force | Out-Null }
        $existing = [ordered]@{}
        if (Test-Path -LiteralPath $StoreFile) {
            $raw = Read-JsonFileSafe -Path $StoreFile
            if ($raw) {
                foreach ($property in $raw.PSObject.Properties) { $existing[$property.Name] = $property.Value }
            }
        }
        $existing['tv_ip'] = $Ip
        if (-not [string]::IsNullOrEmpty($Key)) { $existing['client_key'] = Protect-String $Key }
        Write-JsonFileSafe -Path $StoreFile -Data $existing
        Write-Log "Stored TV IP: $Ip"
    } catch {
        Write-Log "Failed to write store file: $($_.Exception.Message)" -IsError
        throw
    }
}

function Get-StoredData {
    if (-not (Test-Path -LiteralPath $StoreFile)) { return [pscustomobject]@{ Ip = $null; Key = $null } }
    try {
        $data = Read-JsonFileSafe -Path $StoreFile
        if (-not $data) { return [pscustomobject]@{ Ip = $null; Key = $null } }
        $rawKey = if ($data.client_key) { [string]$data.client_key } else { $null }
        $decryptedKey = if ($rawKey) { Unprotect-String $rawKey } else { $null }
        return [pscustomobject]@{
            Ip  = if ($data.tv_ip) { [string]$data.tv_ip } else { $null }
            Key = $decryptedKey
        }
    } catch {
        return [pscustomobject]@{ Ip = $null; Key = $null }
    }
}

# =====================================================================
# Network helpers
# =====================================================================

function Test-WebOSPort {
    param([Parameter(Mandatory = $true)][string]$Ip, [Parameter(Mandatory = $true)][int]$TimeoutMs, [Parameter(Mandatory = $true)][int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    $async = $null
    try {
        $async = $client.BeginConnect($Ip, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    } catch { return $false }
    finally { Close-Quietly $async.AsyncWaitHandle; Close-Quietly $client }
}

function Find-TV {
    Write-Log 'Fast scanning for WebOS TV...'

    $hostCount = $Script:SubnetInfo.HostCount
    if ($hostCount -le 0 -or $hostCount -gt 4096) {
        throw "SUBNET range is not scannable (host count: $hostCount). Use a /20 or narrower CIDR range, e.g. 192.168.1.0/24."
    }
    $networkValue = $Script:SubnetInfo.NetworkValue
    $ips = 1..$hostCount | ForEach-Object { ConvertFrom-IPUInt32 -Value ($networkValue + $_) }

    $clients = New-Object System.Collections.Generic.List[System.Net.Sockets.TcpClient]
    $asyncResults = New-Object System.Collections.Generic.List[IAsyncResult]
    $found = $null

    try {
        foreach ($ip in $ips) {
            $c = New-Object System.Net.Sockets.TcpClient
            $clients.Add($c)
            # $asyncResults stays index-aligned with $clients even if
            # BeginConnect itself throws synchronously (e.g. transient
            # resource exhaustion) - a $null placeholder keeps both lists
            # the same length so the polling/cleanup loops below can never
            # index past the end of either one.
            try { $asyncResults.Add($c.BeginConnect($ip, $WebOSWssPort, $null, $null)) }
            catch { $asyncResults.Add($null) }
        }

        $deadline = (Get-Date).AddSeconds($MaxScanTimeSec)
        while ((Get-Date) -lt $deadline) {
            for ($i = 0; $i -lt $clients.Count; $i++) {
                if ($asyncResults[$i] -and $asyncResults[$i].IsCompleted) {
                    try {
                        $clients[$i].EndConnect($asyncResults[$i])
                        if ($clients[$i].Connected) { $found = $ips[$i]; break }
                    } catch {}
                }
            }
            if ($found) { break }
            Start-Sleep -Milliseconds 20
        }
    } finally {
        for ($i = 0; $i -lt $clients.Count; $i++) {
            Close-Quietly $asyncResults[$i].AsyncWaitHandle
            Close-Quietly $clients[$i]
        }
    }

    if ($found) { Write-Log "TV found at $found"; return $found }
    throw 'Failed to locate TV within scan window. Is the TV awake and on the same subnet?'
}

function Send-WOL {
    param([string]$TargetIp = $null)
    if ([string]::IsNullOrWhiteSpace($Script:TV_MAC)) { Write-Log 'ERROR: TV_MAC is not set' -IsError; return }
    $mac = $Script:TV_MAC -replace '[:\-]', ''
    if ($mac -notmatch '^[0-9A-Fa-f]{12}$') { Write-Log 'ERROR: Invalid TV_MAC' -IsError; return }

    try {
        $macBytes = New-Object byte[] 6
        for ($i = 0; $i -lt 6; $i++) { $macBytes[$i] = [Convert]::ToByte($mac.Substring($i * 2, 2), 16) }
        $packet = New-Object byte[] 102
        for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
        for ($i = 0; $i -lt 16; $i++) { [Array]::Copy($macBytes, 0, $packet, 6 + ($i * 6), 6) }

        $udp = New-Object System.Net.Sockets.UdpClient
        try {
            $udp.EnableBroadcast = $true
            if ($TargetIp) {
                Write-Log "WOL: Sending to $TargetIp`:$WolPort"
                [void]$udp.Send($packet, $packet.Length, $TargetIp, $WolPort)
            } else {
                $broadcastAddr = $Script:SubnetInfo.BroadcastAddress
                Write-Log "WOL: Broadcasting to $broadcastAddr`:$WolPort"
                [void]$udp.Send($packet, $packet.Length, $broadcastAddr, $WolPort)
            }
        } finally { Close-Quietly $udp }
    } catch {
        Write-Log "WOL failed: $($_.Exception.Message)" -IsError
    }
}

function Wait-ForTV {
    <#
        Reacts to actual TV state instead of guessing on a fixed clock.
        - Polls the real webOS port (not just ICMP ping - a TV can answer
          ping long before its webOS services are ready to accept a
          websocket connection).
        - Re-sends WOL periodically, since it's UDP and can be silently
          dropped; a single fire-and-forget WOL is not reliable.
        - Returns as soon as the port responds; only exhausts the full
          timeout if the TV genuinely never comes up.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Ip,
        [int]$MaxWaitSec = 25,
        [int]$PollIntervalMs = 750,
        [int]$WolResendIntervalSec = 5,
        [switch]$ResendWol
    )

    Write-Log "Waiting for TV at $Ip to become reachable on webOS port (max ${MaxWaitSec}s)..."
    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    $lastWolSend = Get-Date

    while ((Get-Date) -lt $deadline) {
        if (Test-TVResponding -Ip $Ip -TimeoutMs 500) {
            $elapsed = [int]($MaxWaitSec - ((($deadline) - (Get-Date)).TotalSeconds))
            Write-Log "TV webOS port responded after ~${elapsed}s"
            return $true
        }

        if ($ResendWol -and (((Get-Date) - $lastWolSend).TotalSeconds -ge $WolResendIntervalSec)) {
            Write-Log 'Still waiting - re-sending WOL packet (previous packet may have been dropped)'
            Send-WOL -TargetIp $Ip
            $lastWolSend = Get-Date
        }

        Start-Sleep -Milliseconds $PollIntervalMs
    }

    Write-Log "WARNING: TV at $Ip did not respond on webOS port within ${MaxWaitSec}s" -IsError
    return $false
}

function Resolve-TVIp {
    <#
        Returns the given IP if present; otherwise discovers the TV via
        WOL + scan and persists the result. Shared by Connect-TV (normal
        connect path) and Start-PersonalMode (explicit wake-up path) so
        the "no stored IP yet" bootstrap logic exists in exactly one
        place instead of being copy-pasted between them.
    #>
    param([string]$Ip, [string]$Key = '')
    if ($Ip) { return $Ip }
    Write-Log 'No stored IP - sending WOL + scan'
    Send-WOL
    Start-Sleep -Seconds 2
    try {
        $found = Find-TV
        Set-StoredData -Ip $found -Key $Key
        return $found
    } catch {
        Write-Log "Could not locate TV on the network: $($_.Exception.Message)" -IsError
        throw
    }
}

# =====================================================================
# Monitor helpers
# =====================================================================

if (-not ('LGTVControl.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
namespace LGTVControl {
    public static class Native {
        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int nIndex);
    }
    public static class DisplayConfig {
        [DllImport("user32.dll")]
        public static extern int SetDisplayConfig(
            uint numPathArrayElements,
            IntPtr pathArray,
            uint numModeArrayElements,
            IntPtr modeArray,
            uint flags);

        public const uint SDC_TOPOLOGY_INTERNAL = 0x00000001;
        public const uint SDC_TOPOLOGY_CLONE    = 0x00000002;
        public const uint SDC_TOPOLOGY_EXTEND   = 0x00000004;
        public const uint SDC_TOPOLOGY_EXTERNAL = 0x00000008;
        public const uint SDC_APPLY             = 0x00000080;
    }
    public static class CertValidator {
        // A real .NET delegate, not a PowerShell scriptblock. WebOS TVs use
        // self-signed certs, and SSL negotiation happens on a thread pool
        // thread with no PowerShell runspace, so a scriptblock callback
        // throws "There is no Runspace available" and fails the handshake.
        public static bool AlwaysTrust(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) {
            return true;
        }
    }
}
'@
}

$Script:CertValidationDelegate = $null

function Get-CertValidationDelegate {
    # Built once and cached. Uses reflection (-as [type] / GetMethod), not
    # a [LGTVControl.CertValidator] bracket literal, because PowerShell
    # resolves bracket type literals at PARSE time - before the Add-Type
    # call above has run - which would fail with "Unable to find type".
    if ($Script:CertValidationDelegate) { return $Script:CertValidationDelegate }
    try {
        $certValidatorType = 'LGTVControl.CertValidator' -as [type]
        $certMethod = $certValidatorType.GetMethod('AlwaysTrust')
        $Script:CertValidationDelegate = [System.Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], $certMethod)
    } catch {
        Write-Log "Failed to build certificate validation delegate: $($_.Exception.Message)" -IsError
        $Script:CertValidationDelegate = $null
    }
    return $Script:CertValidationDelegate
}

function Get-ActiveMonitorCount {
    try {
        $nativeType = 'LGTVControl.Native' -as [type]
        return $nativeType::GetSystemMetrics(80)
    } catch { return 1 }
}

function Wait-ForDisplayTopologyReady {
    <#
        SetDisplayConfig error 31 (ERROR_GEN_FAILURE) most commonly means
        Windows hasn't finished redetecting the HDMI path yet - the TV
        reporting the new input as foreground (Wait-ForForegroundApp) is
        not the same event as the Windows display driver re-enumerating
        that output. Polls GetSystemMetrics(SM_CMONITORS) until it matches
        what the requested topology implies, instead of guessing a fixed
        sleep: extend needs 2 monitors, external/internal-only needs 1.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('enable', 'disable')][string]$Action,
        [int]$MaxWaitMs = 4000,
        [int]$PollMs = 250
    )
    $expected = if ($Action -eq 'enable') { 2 } else { 1 }
    $deadline = (Get-Date).AddMilliseconds($MaxWaitMs)
    while ((Get-Date) -lt $deadline) {
        if ((Get-ActiveMonitorCount) -eq $expected) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    Write-Log "Display topology not ready after ${MaxWaitMs}ms (wanted $expected monitor(s), saw $(Get-ActiveMonitorCount)) - proceeding anyway" -IsError
    return $false
}

function Set-MonitorMode {
    <#
        Uses SetDisplayConfig directly (the same Win32 API DisplaySwitch.exe
        wraps) instead of shelling out to DisplaySwitch.exe. Calling it
        as a subprocess proved unreliable in this context - it could exit
        cleanly while silently failing to change the actual topology.
        Calling the API in-process avoids that failure mode entirely and
        surfaces a real Win32 error code if it does fail.

        Waits for Windows to redetect the display before calling
        SetDisplayConfig, and retries the call itself a couple of times -
        error 31 is frequently transient (mid-handshake on the HDMI path)
        rather than a real configuration problem.
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('enable', 'disable')][string]$Action)

    [void](Wait-ForDisplayTopologyReady -Action $Action)

    $topology = if ($Action -eq 'enable') {
        Write-Log 'Enabling monitor (extending displays)'
        [LGTVControl.DisplayConfig]::SDC_TOPOLOGY_EXTEND
    } else {
        Write-Log 'Disabling secondary monitor (external display only)'
        [LGTVControl.DisplayConfig]::SDC_TOPOLOGY_EXTERNAL
    }
    $flags = $topology -bor [LGTVControl.DisplayConfig]::SDC_APPLY

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $result = [LGTVControl.DisplayConfig]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, $flags)
        if ($result -eq 0) {
            Write-Log 'Monitor topology applied successfully'
            return
        }
        if ($attempt -eq $maxAttempts) {
            Write-Log "SetDisplayConfig failed with error code: $result (after $maxAttempts attempts)" -IsError
            return
        }
        Write-Log "SetDisplayConfig failed with error code: $result - retrying ($attempt/$maxAttempts)..." -IsError
        Start-Sleep -Milliseconds 750
    }
}

# =====================================================================
# WebOS client Class Definition
# =====================================================================

class LGWebOSClient {
    [string]$HostName
    [int]$Port
    [System.Net.WebSockets.ClientWebSocket]$Socket
    [int]$MessageId

    LGWebOSClient([string]$hostName, [int]$port) {
        $this.HostName = $hostName; $this.Port = $port; $this.MessageId = 0
    }

    hidden [System.Threading.CancellationTokenSource] NewCts([int]$TimeoutMs) {
        $c = New-Object System.Threading.CancellationTokenSource
        $c.CancelAfter($TimeoutMs)
        return $c
    }

    hidden [void] AssertConnected() {
        if (-not $this.Socket -or $this.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            throw "Not connected (socket state: $(if ($this.Socket) { $this.Socket.State } else { 'null' }), close status: $(if ($this.Socket -and $this.Socket.CloseStatus) { $this.Socket.CloseStatus } else { 'none' }), close description: '$(if ($this.Socket) { $this.Socket.CloseStatusDescription } else { '' })')"
        }
    }

    [void] Connect([int]$TimeoutMs) {
        # .NET Framework's default ServicePointManager security protocol
        # selection can exclude TLS versions WebOS TVs actually speak,
        # causing ConnectAsync to fault immediately (not time out).
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = `
                [System.Net.SecurityProtocolType]::Tls12 -bor `
                [System.Net.SecurityProtocolType]::Tls11 -bor `
                [System.Net.SecurityProtocolType]::Tls
        } catch {}

        # Use a compiled .NET delegate, not a PowerShell scriptblock -
        # scriptblocks fail on the SSL negotiation thread pool thread with
        # "no Runspace available", which silently breaks the handshake.
        # Built once via Get-CertValidationDelegate (script-scope function)
        # rather than inline here: PowerShell class methods use stricter
        # definite-assignment analysis than scriptblocks, so a variable
        # only assigned inside a try/catch is rejected as "not assigned"
        # even though it always gets a value.
        #
        # Two callback paths are set deliberately, not redundantly: on
        # Windows PowerShell 5.1 (.NET Framework), ClientWebSocket's
        # Options.RemoteCertificateValidationCallback is not settable, so
        # that assignment throws and we fall back to the
        # ServicePointManager-level callback, which IS honored on 5.1. On
        # PowerShell 7+ (.NET Core/5+), the Options property works
        # directly. Setting both covers both hosts without needing to
        # detect $PSVersionTable at runtime.
        $certDelegate = Get-CertValidationDelegate
        if ($certDelegate) {
            try { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $certDelegate } catch {}
        }

        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        try {
            if ($certDelegate) {
                try {
                    $ws.Options.RemoteCertificateValidationCallback = $certDelegate
                } catch {
                    Write-Log "Could not set ClientWebSocket cert callback directly (using ServicePointManager fallback): $($_.Exception.Message)"
                }
            }
            $uri = New-Object System.Uri("wss://$($this.HostName):$($this.Port)/")
            $cts = $this.NewCts($TimeoutMs)
            try {
                $task = $ws.ConnectAsync($uri, $cts.Token)
                $finished = $task.Wait($TimeoutMs)
                if (-not $finished) { throw 'Connection task timed out' }
                if ($task.IsFaulted) {
                    # Unwrap to the real cause instead of the generic
                    # AggregateException/"Wait" message.
                    $inner = $task.Exception
                    while ($inner -and $inner.InnerException) { $inner = $inner.InnerException }
                    if ($inner) { throw $inner }
                    throw $task.Exception
                }
                if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { throw "WebSocket did not enter Open state (state: $($ws.State))" }
                $this.Socket = $ws; $ws = $null
            } finally { $cts.Dispose() }
        } catch {
            Close-Quietly $ws
            $detail = $_.Exception.Message
            $inner = $_.Exception.InnerException
            while ($inner) { $detail = "$detail | Inner: $($inner.Message)"; $inner = $inner.InnerException }
            throw "WebSocket connection failed: $detail"
        }
    }

    [void] Send([object]$Message, [int]$TimeoutMs) {
        $this.AssertConnected()
        $json = $Message | ConvertTo-Json -Depth 20 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $segment = New-Object System.ArraySegment[byte] (, $bytes)
        $cts = $this.NewCts($TimeoutMs)
        try {
            $task = $this.Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
            if (-not $task.Wait($TimeoutMs)) { throw 'Send task timed out' }
        } catch { throw "Failed to send message: $($_.Exception.Message)" }
        finally { $cts.Dispose() }
    }

    [string] Receive([int]$TimeoutMs) {
        $this.AssertConnected()
        $buffer = New-Object byte[] 8192
        $segment = New-Object System.ArraySegment[byte] (, $buffer)
        $stream = New-Object System.IO.MemoryStream
        $cts = $this.NewCts($TimeoutMs)
        try {
            do {
                $task = $this.Socket.ReceiveAsync($segment, $cts.Token)
                if (-not $task.Wait($TimeoutMs)) { throw 'Receive task timed out' }
                $result = $task.Result
                if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
                if ($result.MessageType -ne [System.Net.WebSockets.WebSocketMessageType]::Text) { continue }
                if ($result.Count -gt 0) { $stream.Write($buffer, 0, $result.Count) }
            } while (-not $result.EndOfMessage)
            return [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
        } catch { throw "Failed to receive response: $($_.Exception.Message)" }
        finally { $cts.Dispose(); $stream.Dispose() }
    }

    [object] SendCommand([string]$Uri, [hashtable]$Payload, [int]$SendTimeout, [int]$ReceiveTimeout) {
        $this.MessageId++
        $message = [ordered]@{ type = 'request'; id = "$($this.MessageId)"; uri = $Uri }
        if ($null -ne $Payload) { $message['payload'] = $Payload }
        $this.Send($message, $SendTimeout)
        $response = $this.Receive($ReceiveTimeout)
        if ([string]::IsNullOrEmpty($response)) { return $null }
        return ($response | ConvertFrom-Json)
    }

    [string] Register([string]$ClientKey, [hashtable]$RegistrationPayload, [int]$SendTimeout, [int]$ReceiveTimeout) {
        $payload = $RegistrationPayload.Clone()
        if (-not [string]::IsNullOrEmpty($ClientKey)) { $payload['client-key'] = $ClientKey }
        $this.MessageId++
        $message = [ordered]@{ type = 'register'; id = "$($this.MessageId)"; payload = $payload }
        $this.Send($message, $SendTimeout)

        $maxAttempts = 10
        for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
            $response = $this.Receive($ReceiveTimeout)
            if ([string]::IsNullOrEmpty($response)) { continue }
            $data = $response | ConvertFrom-Json
            if ($data.type -eq 'response' -and $data.payload.pairingType -eq 'PROMPT') { Write-Log 'TV prompting for approval - accept on TV'; continue }
            if ($data.type -eq 'registered') {
                $key = $data.payload.'client-key'
                if ([string]::IsNullOrEmpty([string]$key)) { throw 'TV reported registration success but returned no client key' }
                Write-Log 'Registration successful'
                return [string]$key
            }
        }
        throw 'Registration failed'
    }

    [void] Disconnect() { $this.Close() }

    [void] Close() {
        $ws = $this.Socket
        $this.Socket = $null
        if (-not $ws) { return }
        if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $cts = $this.NewCts(2000)
            try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $cts.Token).Wait(2000) | Out-Null } catch {} finally { $cts.Dispose() }
        }
        Close-Quietly $ws
    }
}

# =====================================================================
# TV connection / registration runner functions
# =====================================================================

function Test-TVResponding {
    param([Parameter(Mandatory = $true)][string]$Ip, [int]$TimeoutMs = 1000)
    return Test-WebOSPort -Ip $Ip -TimeoutMs $TimeoutMs -Port $WebOSWssPort
}

function Connect-TV {
    $stored = Get-StoredData
    $key = $stored.Key
    $ip = Resolve-TVIp -Ip $stored.Ip -Key $(if ($key) { $key } else { '' })

    Write-Log "Checking if TV at $ip is responding..."
    if (-not (Test-TVResponding -Ip $ip)) {
        Write-Log 'TV not responding - sending WOL and waiting for it to wake...'
        if (-not (Wait-ForTV -Ip $ip -MaxWaitSec 20 -PollIntervalMs 750 -WolResendIntervalSec 5 -ResendWol)) {
            throw "TV at $ip did not respond after WOL - aborting (not attempting connection blindly)"
        }
    } else { Write-Log 'TV is responding' }

    Write-Log "Connecting to LG TV ($ip)..."
    $client = $null

    try {
        $client = Invoke-WithRetry -MaxAttempts $MaxConnectRetries -DelayMs 500 -Action {
            param($attempt)
            $c = [LGWebOSClient]::new($ip, $WebOSWssPort)
            try { $c.Connect($ConnectTimeoutMs) } catch { Disconnect-Quietly $c; throw }
            Write-Log "Connect succeeded, socket state: $($c.Socket.State)"
            return $c
        } -OnRetry {
            param($e, $attempt) Write-Log "Connect attempt $attempt/$MaxConnectRetries failed: $($e.Exception.Message)" -IsError
        }

        if ([string]::IsNullOrEmpty($key)) {
            Write-Log 'No client key - initiating registration'
            $key = $client.Register($null, $RegistrationPayload, $SendTimeoutMs, $RegistrationTimeoutMs)
            Set-StoredData -Ip $ip -Key $key
        } else {
            Write-Log 'Using stored client key'
            $registered = $false
            for ($regAttempt = 1; $regAttempt -le $MaxRegisterRetries; $regAttempt++) {
                try {
                    $newKey = $client.Register($key, $RegistrationPayload, $SendTimeoutMs, $RegistrationTimeoutMs)
                    if (-not [string]::IsNullOrEmpty($newKey)) { $key = $newKey; Set-StoredData -Ip $ip -Key $key }
                    $registered = $true
                    break
                } catch {
                    Write-Log "Registration attempt $regAttempt/$MaxRegisterRetries with stored key failed: $($_.Exception.Message)" -IsError
                    if ($regAttempt -eq $MaxRegisterRetries) { throw }

                    # The TV explicitly told us to back off (WebOS "EWS -
                    # Try Again Later" policy-violation close), not that the
                    # key/connection is bad. Reconnecting instantly just hits
                    # the same busy state again - give it real time to
                    # clear, backing off further on each repeated busy
                    # response. This mutable-$client reconnect loop is kept
                    # hand-written (not folded into Invoke-WithRetry) since
                    # $client must be reassigned and read across attempts,
                    # which a generic retry-scriptblock can't safely do.
                    $isBusy = $_.Exception.Message -match 'PolicyViolation|Try Again Later'
                    Disconnect-Quietly $client
                    $backoffMs = if ($isBusy) { 1500 * $regAttempt } else { 500 }
                    if ($isBusy) { Write-Log "TV reported busy/policy-violation - backing off ${backoffMs}ms before retrying registration" }
                    Start-Sleep -Milliseconds $backoffMs
                    $client = [LGWebOSClient]::new($ip, $WebOSWssPort)
                    $client.Connect($ConnectTimeoutMs)
                }
            }
            if (-not $registered) { throw 'Registration with stored key failed after retries' }
        }
        return $client
    } catch {
        Disconnect-Quietly $client
        throw "Connection/registration failed: $($_.Exception.Message)"
    }
}

# =====================================================================
# High-level actions
# =====================================================================

function Get-ForegroundAppId {
    param([Parameter(Mandatory = $true)]$Client)
    $response = $Client.SendCommand('ssap://com.webos.applicationManager/getForegroundAppInfo', $null, $SendTimeoutMs, $ReceiveTimeoutMs)
    if (-not $response -or $response.type -ne 'response') { return $null }
    if (-not $response.payload -or -not $response.payload.appId) { return $null }
    return [string]$response.payload.appId
}

function Wait-ForForegroundApp {
    <#
        Polls the TV's actual foreground-app state instead of assuming the
        switch happened just because the launch command was acknowledged.
        The launch ack only confirms the TV accepted the request - it does
        not confirm the input actually changed.
    #>
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$ExpectedAppId,
        [int]$TimeoutMs = $VerifyInputTimeoutMs,
        [int]$PollMs = $VerifyInputPollMs
    )

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $lastSeen = $null

    while ((Get-Date) -lt $deadline) {
        try {
            $appId = Get-ForegroundAppId -Client $Client
            if ($appId) { $lastSeen = $appId }
            if ($appId -eq $ExpectedAppId) { return $true }
        } catch {
            # Transient read failure while TV is mid-switch - keep polling
            # rather than failing immediately.
        }
        Start-Sleep -Milliseconds $PollMs
    }

    Write-Log "Foreground app after wait: '$lastSeen' (expected '$ExpectedAppId')" -IsError
    return $false
}

function Switch-Input {
    param([Parameter(Mandatory = $true)][string]$InputId)
    $client = $null
    try {
        $client = Connect-TV
        $response = $client.SendCommand('ssap://system.launcher/launch', @{ id = $InputId }, $SendTimeoutMs, $ReceiveTimeoutMs)
        Confirm-TVResponse -Response $response -FailMessage 'Input switch failed'

        # The launch ack only means the TV accepted the request - confirm
        # the input actually changed by polling real TV state.
        if (Wait-ForForegroundApp -Client $client -ExpectedAppId $InputId) {
            Write-Log "Switched to input: $InputId (confirmed via getForegroundAppInfo)"
            return
        }

        throw "Input switch to $InputId was acknowledged but TV never reported it as foreground app within ${VerifyInputTimeoutMs}ms"
    } catch { Write-Log "Failed to switch input: $($_.Exception.Message)" -IsError; throw }
    finally { Disconnect-Quietly $client }
}

function Invoke-InputSwitchWithRetry {
    <# Shared retry wrapper around Switch-Input, used by both startup and toggle so both paths get identical resilience. #>
    param(
        [Parameter(Mandatory = $true)][string]$InputId,
        [int]$MaxRetries = $MaxInputSwitchRetries
    )

    $ip = (Get-StoredData).Ip
    Invoke-WithRetry -MaxAttempts $MaxRetries -DelayMs 0 -Action {
        Switch-Input -InputId $InputId
        Write-Log 'Input switch completed successfully'
    } -OnRetry {
        param($e, $attempt)
        Write-Log "Input switch attempt $attempt/$MaxRetries failed: $($e.Exception.Message)" -IsError
        if (-not $ip) { return }
        Write-Log 'Re-checking TV is still reachable before retrying...'
        if (-not (Wait-ForTV -Ip $ip -MaxWaitSec 8 -PollIntervalMs 500)) {
            Write-Log 'TV dropped off the network between attempts - re-sending WOL' -IsError
            Send-WOL -TargetIp $ip
            [void](Wait-ForTV -Ip $ip -MaxWaitSec 15 -PollIntervalMs 750 -WolResendIntervalSec 5 -ResendWol)
        }
    } | Out-Null
}

function Enter-Mode {
    <#
        Replaces the separate Enter-PersonalMode/Enter-WorkMode functions -
        both did the exact same two things (switch input, set monitor
        mode), differing only in which input/action to use.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$InputId,
        [Parameter(Mandatory = $true)][ValidateSet('enable', 'disable')][string]$MonitorAction
    )
    Invoke-InputSwitchWithRetry -InputId $InputId
    Set-MonitorMode -Action $MonitorAction
}

function Invoke-TVShutdown {
    $client = $null
    $ip = $null
    try {
        $ip = (Get-StoredData).Ip
        $client = Connect-TV
        $response = $client.SendCommand('ssap://system/turnOff', $null, $SendTimeoutMs, $ReceiveTimeoutMs)
        Confirm-TVResponse -Response $response -FailMessage 'Shutdown command rejected'
        Write-Log 'Shutdown command acknowledged - verifying TV actually powers off...'
    } catch { Write-Log "Shutdown failed: $($_.Exception.Message)" -IsError; throw }
    finally { Disconnect-Quietly $client }

    # An acknowledged turnOff command doesn't guarantee the TV powers off
    # (it may go to a fast-boot standby that still accepts connections
    # briefly, or the command may be silently dropped). Confirm the webOS
    # port actually stops responding.
    if (-not $ip) { return }
    $deadline = (Get-Date).AddMilliseconds($VerifyInputTimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-TVResponding -Ip $ip -TimeoutMs 500)) {
            Write-Log 'Shutdown confirmed - TV is no longer responding'
            return
        }
        Start-Sleep -Milliseconds $VerifyInputPollMs
    }
    Write-Log "Shutdown was acknowledged but TV is still responding after ${VerifyInputTimeoutMs}ms" -IsError
    throw 'Shutdown command acknowledged but TV did not power off within the verification window'
}

function Start-PersonalMode {
    Write-Log ('=' * 60); Write-Log 'Startup: PERSONAL mode'; Write-Log ('=' * 60)
    $ip = Resolve-TVIp -Ip (Get-StoredData).Ip

    Write-Log "Waking TV at $ip..."
    Send-WOL -TargetIp $ip

    # React to real TV state: poll the actual webOS port, re-sending WOL if
    # the TV still hasn't come up (a single UDP WOL packet can be dropped).
    # If the TV genuinely never responds, fail loudly instead of trying the
    # input switch anyway on a blind timer.
    if (-not (Wait-ForTV -Ip $ip -MaxWaitSec 25 -PollIntervalMs 750 -WolResendIntervalSec 5 -ResendWol)) {
        throw "TV at $ip never became reachable after WOL - aborting startup (check TV is plugged in, WOL is enabled in TV network settings, and TV_MAC/SUBNET are correct)"
    }

    Write-Log 'Attempting to switch input...'
    Enter-Mode -InputId $PersonalInput -MonitorAction 'enable'

    Write-Log 'Startup sequence complete'; Write-Log ('=' * 60)
}

function Invoke-Toggle {
    <#
        Personal-mode branch delegates straight to Start-PersonalMode -
        the exact same function 'startup' uses. Work-mode has no
        equivalent full wake-up sequence needed (you're already at the
        PC when toggling to work), so it's a direct Enter-Mode call.
    #>
    $monitors = Get-ActiveMonitorCount

    if ($monitors -gt 1) {
        Write-Log "$monitors monitors detected -> Work mode"
        Enter-Mode -InputId $WorkInput -MonitorAction 'disable'
    } else {
        Write-Log "$monitors monitor detected -> Personal mode"
        Start-PersonalMode
    }
}

# =====================================================================
# Main Execution Entrypoint
# =====================================================================

Confirm-SingleInstance
Start-Watchdog -Seconds $WatchdogSec | Out-Null
try {
    Write-Log "Running as: $env:USERNAME"
    if (-not (Initialize-Store)) { exit 1 }
    if (-not (Import-Config)) { exit 1 }

    switch ($Command) {
        'startup'  { Start-PersonalMode }
        'toggle'   { Invoke-Toggle }
        'shutdown' { Invoke-TVShutdown }
        'scan'     { Write-Log (Find-TV) }
        default    { throw "Invalid command: $Command" }
    }
    Write-Log 'Execution finished cleanly.'
} catch {
    Write-Log "ERROR: $($_.Exception.Message)`n$($_.ScriptStackTrace)" -IsError; exit 1
} finally {
    Stop-Watchdog
    if ($Script:InstanceMutex) { try { $Script:InstanceMutex.ReleaseMutex(); $Script:InstanceMutex.Dispose() } catch {} }
}
