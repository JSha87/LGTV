#Requires -Version 5.1
<#
.SYNOPSIS
    LG WebOS TV controller - PowerShell 5.1, optimized, memory-safe, and file-lock resilient.
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

$Script:SUBNET = $null
$Script:TV_MAC = $null
$Script:BROADCAST_IP = $null

$ScanTimeoutMs       = 300
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
$MaxInputSwitchRetries = 5
$WatchdogSec           = 60
$VerifyInputTimeoutMs  = 8000
$VerifyInputPollMs     = 400

$WebOSWsPort  = 3000
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
# Safe File IO (Prevents File Locking Errors)
# =====================================================================

function Read-JsonFileSafe {
    param([string]$Path)
    for ($i = 1; $i -le 5; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $json = $sr.ReadToEnd()
            $sr.Dispose()
            $fs.Dispose()
            if ([string]::IsNullOrWhiteSpace($json)) { return $null }
            return ($json | ConvertFrom-Json)
        } catch {
            if ($i -eq 5) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Write-JsonFileSafe {
    param([string]$Path, [object]$Data)
    $json = $Data | ConvertTo-Json -Depth 10
    for ($i = 1; $i -le 5; $i++) {
        try {
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            $sw = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
            $sw.Write($json)
            $sw.Dispose()
            $fs.Dispose()
            return
        } catch {
            if ($i -eq 5) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
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
        _comment     = 'Fill in TV_MAC, SUBNET, and BROADCAST_IP. Script populates tv_ip and client_key automatically.'
        TV_MAC       = ''
        SUBNET       = ''
        BROADCAST_IP = ''
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
        $Script:SUBNET = [string]$data.SUBNET
        $Script:BROADCAST_IP = [string]$data.BROADCAST_IP

        if ([string]::IsNullOrWhiteSpace($Script:TV_MAC) -or [string]::IsNullOrWhiteSpace($Script:SUBNET)) { return $false }
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
    finally {
        if ($async -and $async.AsyncWaitHandle) { try { $async.AsyncWaitHandle.Close() } catch {} }
        try { $client.Close(); $client.Dispose() } catch {}
    }
}

function Find-TV {
    Write-Log 'Fast scanning for WebOS TV...'
    $ips = 1..254 | ForEach-Object { "$($Script:SUBNET).$_" }

    $clients = New-Object System.Collections.Generic.List[System.Net.Sockets.TcpClient]
    $asyncResults = New-Object System.Collections.Generic.List[IAsyncResult]
    $found = $null

    try {
        for ($i = 0; $i -lt $ips.Count; $i++) {
            $client = New-Object System.Net.Sockets.TcpClient
            $clients.Add($client)
            $asyncResults.Add($client.BeginConnect($ips[$i], $WebOSWssPort, $null, $null))
        }

        $deadline = (Get-Date).AddSeconds($MaxScanTimeSec)
        while ((Get-Date) -lt $deadline) {
            for ($i = 0; $i -lt $clients.Count; $i++) {
                if ($asyncResults[$i].IsCompleted) {
                    try {
                        $clients[$i].EndConnect($asyncResults[$i])
                        if ($clients[$i].Connected) {
                            $found = $ips[$i]
                            break
                        }
                    } catch {}
                }
            }
            if ($found) { break }
            Start-Sleep -Milliseconds 20
        }
    } finally {
        for ($i = 0; $i -lt $clients.Count; $i++) {
            if ($asyncResults[$i] -and $asyncResults[$i].AsyncWaitHandle) { try { $asyncResults[$i].AsyncWaitHandle.Close() } catch {} }
            if ($clients[$i]) { try { $clients[$i].Close(); $clients[$i].Dispose() } catch {} }
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
                $broadcastAddr = if (-not [string]::IsNullOrWhiteSpace($Script:BROADCAST_IP)) { $Script:BROADCAST_IP } else { "$($Script:SUBNET).255" }
                Write-Log "WOL: Broadcasting to $broadcastAddr`:$WolPort"
                [void]$udp.Send($packet, $packet.Length, $broadcastAddr, $WolPort)
            }
        } finally {
            try { $udp.Close(); $udp.Dispose() } catch {}
        }
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

# =====================================================================
# Monitor helpers
# =====================================================================

if (-not ('LGTVControl.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace LGTVControl {
    public static class Native {
        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int nIndex);
    }
}
'@
}

if (-not ('LGTVControl.DisplayConfig' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace LGTVControl {
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
}
'@
}

if (-not ('LGTVControl.CertValidator' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
namespace LGTVControl {
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

function Set-MonitorMode {
    param([Parameter(Mandatory = $true)][ValidateSet('enable', 'disable')][string]$Action)

    $topology = if ($Action -eq 'enable') {
        Write-Log 'Enabling monitor (extending displays)'
        [LGTVControl.DisplayConfig]::SDC_TOPOLOGY_EXTEND
    } else {
        Write-Log 'Disabling secondary monitor (external display only)'
        [LGTVControl.DisplayConfig]::SDC_TOPOLOGY_EXTERNAL
    }

    $flags = $topology -bor [LGTVControl.DisplayConfig]::SDC_APPLY
    $result = [LGTVControl.DisplayConfig]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, $flags)

    if ($result -eq 0) {
        Write-Log "Monitor topology applied successfully"
    } else {
        Write-Log "SetDisplayConfig failed with error code: $result" -IsError
    }
}

function Get-ActiveMonitorCount {
    try {
        $nativeType = 'LGTVControl.Native' -as [type]
        return $nativeType::GetSystemMetrics(80)
    } catch { return 1 }
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
            $cts = New-Object System.Threading.CancellationTokenSource
            try {
                $cts.CancelAfter($TimeoutMs)
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
            if ($ws) { try { $ws.Dispose() } catch {} }
            $detail = $_.Exception.Message
            $inner = $_.Exception.InnerException
            while ($inner) { $detail = "$detail | Inner: $($inner.Message)"; $inner = $inner.InnerException }
            throw "WebSocket connection failed: $detail"
        }
    }

    [void] Send([object]$Message, [int]$TimeoutMs) {
        if (-not $this.Socket -or $this.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            throw "Not connected (socket state: $(if ($this.Socket) { $this.Socket.State } else { 'null' }), close status: $(if ($this.Socket -and $this.Socket.CloseStatus) { $this.Socket.CloseStatus } else { 'none' }), close description: '$(if ($this.Socket) { $this.Socket.CloseStatusDescription } else { '' })')"
        }
        $json = $Message | ConvertTo-Json -Depth 20 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $segment = New-Object System.ArraySegment[byte] (, $bytes)
        $cts = New-Object System.Threading.CancellationTokenSource
        try {
            $cts.CancelAfter($TimeoutMs)
            $task = $this.Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
            if (-not $task.Wait($TimeoutMs)) { throw 'Send task timed out' }
        } catch { throw "Failed to send message: $($_.Exception.Message)" }
        finally { $cts.Dispose() }
    }

    [string] Receive([int]$TimeoutMs) {
        if (-not $this.Socket -or $this.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            throw "Not connected (socket state: $(if ($this.Socket) { $this.Socket.State } else { 'null' }), close status: $(if ($this.Socket -and $this.Socket.CloseStatus) { $this.Socket.CloseStatus } else { 'none' }), close description: '$(if ($this.Socket) { $this.Socket.CloseStatusDescription } else { '' })')"
        }
        $buffer = New-Object byte[] 8192
        $segment = New-Object System.ArraySegment[byte] (, $buffer)
        $stream = New-Object System.IO.MemoryStream
        $cts = New-Object System.Threading.CancellationTokenSource
        try {
            $cts.CancelAfter($TimeoutMs)
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
        try {
            if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $cts = New-Object System.Threading.CancellationTokenSource
                try {
                    $cts.CancelAfter(2000)
                    $task = $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $cts.Token)
                    $task.Wait(2000) | Out-Null
                } catch {} finally { $cts.Dispose() }
            }
        } finally { try { $ws.Dispose() } catch {} }
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
    $ip = $stored.Ip
    $key = $stored.Key

    if (-not $ip) {
        Write-Log 'No stored IP - sending WOL + scan'
        Send-WOL
        Start-Sleep -Seconds 2
        $ip = Find-TV
        Set-StoredData -Ip $ip -Key $(if ($key) { $key } else { '' })
    }

    Write-Log "Checking if TV at $ip is responding..."
    if (-not (Test-TVResponding -Ip $ip)) {
        Write-Log 'TV not responding - sending WOL and waiting for it to wake...'
        $woke = Wait-ForTV -Ip $ip -MaxWaitSec 20 -PollIntervalMs 750 -WolResendIntervalSec 5 -ResendWol
        if (-not $woke) {
            throw "TV at $ip did not respond after WOL - aborting (not attempting connection blindly)"
        }
    } else { Write-Log 'TV is responding' }

    Write-Log "Connecting to LG TV ($ip)..."
    $client = $null

    try {
        for ($attempt = 1; $attempt -le $MaxConnectRetries; $attempt++) {
            $client = [LGWebOSClient]::new($ip, $WebOSWssPort)
            try {
                $client.Connect($ConnectTimeoutMs)
                Write-Log "Connect succeeded, socket state: $($client.Socket.State)"
                break
            } catch {
                Write-Log "Connect attempt $attempt/$MaxConnectRetries failed: $($_.Exception.Message)" -IsError
                try { $client.Disconnect() } catch {}
                $client = $null
                if ($attempt -eq $MaxConnectRetries) { throw "WebSocket connect failed after $MaxConnectRetries attempts" }
                Start-Sleep -Milliseconds 500
            }
        }
        if (-not $client) { throw 'Failed to create WebOS client' }

        if ([string]::IsNullOrEmpty($key)) {
            Write-Log 'No client key - initiating registration'
            $key = $client.Register($null, $RegistrationPayload, $SendTimeoutMs, $RegistrationTimeoutMs)
            Set-StoredData -Ip $ip -Key $key
        } else {
            Write-Log 'Using stored client key'
            $registered = $false
            $maxRegisterRetries = 5
            for ($regAttempt = 1; $regAttempt -le $maxRegisterRetries; $regAttempt++) {
                try {
                    $newKey = $client.Register($key, $RegistrationPayload, $SendTimeoutMs, $RegistrationTimeoutMs)
                    if (-not [string]::IsNullOrEmpty($newKey)) { $key = $newKey; Set-StoredData -Ip $ip -Key $key }
                    $registered = $true
                    break
                } catch {
                    $isBusy = $_.Exception.Message -match 'PolicyViolation' -or $_.Exception.Message -match 'Try Again Later'
                    Write-Log "Registration attempt $regAttempt/$maxRegisterRetries with stored key failed: $($_.Exception.Message)" -IsError

                    if ($regAttempt -eq $maxRegisterRetries) { throw }

                    # The TV explicitly told us to back off (WebOS "EWS -
                    # Try Again Later" policy-violation close), not that the
                    # key/connection is bad. Reconnecting instantly just hits
                    # the same busy state again - give it real time to clear,
                    # backing off further on each repeated busy response.
                    try { $client.Disconnect() } catch {}
                    if ($isBusy) {
                        $backoffMs = 1500 * $regAttempt
                        Write-Log "TV reported busy/policy-violation - backing off ${backoffMs}ms before retrying registration"
                        Start-Sleep -Milliseconds $backoffMs
                    } else {
                        Start-Sleep -Milliseconds 500
                    }
                    $client = [LGWebOSClient]::new($ip, $WebOSWssPort)
                    $client.Connect($ConnectTimeoutMs)
                }
            }
            if (-not $registered) { throw 'Registration with stored key failed after retries' }
        }
        return $client
    } catch {
        if ($client) { try { $client.Disconnect() } catch {} }
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
        if (-not $response -or $response.type -ne 'response') { throw 'No response from TV' }
        if (-not $response.payload.returnValue) {
            $errorText = if ([string]::IsNullOrEmpty([string]$response.payload.errorText)) { 'Unknown error' } else { $response.payload.errorText }
            throw "Input switch failed: $errorText"
        }

        # The launch ack only means the TV accepted the request - confirm
        # the input actually changed by polling real TV state.
        if (Wait-ForForegroundApp -Client $client -ExpectedAppId $InputId) {
            Write-Log "Switched to input: $InputId (confirmed via getForegroundAppInfo)"
            return
        }

        throw "Input switch to $InputId was acknowledged but TV never reported it as foreground app within ${VerifyInputTimeoutMs}ms"
    } catch { Write-Log "Failed to switch input: $($_.Exception.Message)" -IsError; throw }
    finally { if ($client) { try { $client.Disconnect() } catch {} } }
}

function Invoke-TVShutdown {
    $client = $null
    $ip = $null
    try {
        $stored = Get-StoredData
        $ip = $stored.Ip
        $client = Connect-TV
        $response = $client.SendCommand('ssap://system/turnOff', $null, $SendTimeoutMs, $ReceiveTimeoutMs)
        if (-not $response -or $response.type -ne 'response') { throw 'No response from TV' }
        if (-not $response.payload.returnValue) {
            $errorText = if ([string]::IsNullOrEmpty([string]$response.payload.errorText)) { 'Unknown error' } else { $response.payload.errorText }
            throw "Shutdown command rejected: $errorText"
        }
        Write-Log 'Shutdown command acknowledged - verifying TV actually powers off...'
    } catch { Write-Log "Shutdown failed: $($_.Exception.Message)" -IsError; throw }
    finally { if ($client) { try { $client.Disconnect() } catch {} } }

    # An acknowledged turnOff command doesn't guarantee the TV powers off
    # (it may go to a fast-boot standby that still accepts connections
    # briefly, or the command may be silently dropped). Confirm the webOS
    # port actually stops responding.
    if ($ip) {
        $deadline = (Get-Date).AddMilliseconds($VerifyInputTimeoutMs)
        $down = $false
        while ((Get-Date) -lt $deadline) {
            if (-not (Test-TVResponding -Ip $ip -TimeoutMs 500)) { $down = $true; break }
            Start-Sleep -Milliseconds $VerifyInputPollMs
        }
        if ($down) {
            Write-Log 'Shutdown confirmed - TV is no longer responding'
        } else {
            Write-Log "Shutdown was acknowledged but TV is still responding after ${VerifyInputTimeoutMs}ms" -IsError
            throw 'Shutdown command acknowledged but TV did not power off within the verification window'
        }
    }
}

function Start-PersonalMode {
    Write-Log ('=' * 60); Write-Log 'Startup: PERSONAL mode'; Write-Log ('=' * 60)
    $stored = Get-StoredData
    $ip = $stored.Ip

    if (-not $ip) {
        Write-Log 'No stored IP - sending broadcast WOL and scanning for TV...'
        Send-WOL
        Start-Sleep -Seconds 2
        try {
            $ip = Find-TV
            Set-StoredData -Ip $ip -Key ''
        } catch {
            Write-Log "Could not locate TV on the network: $($_.Exception.Message)" -IsError
            throw
        }
    }

    Write-Log "Waking TV at $ip..."
    Send-WOL -TargetIp $ip

    # React to real TV state: poll the actual webOS port, re-sending WOL if
    # the TV still hasn't come up (a single UDP WOL packet can be dropped).
    # If the TV genuinely never responds, fail loudly instead of trying the
    # input switch anyway on a blind timer.
    $ready = Wait-ForTV -Ip $ip -MaxWaitSec 25 -PollIntervalMs 750 -WolResendIntervalSec 5 -ResendWol
    if (-not $ready) {
        throw "TV at $ip never became reachable after WOL - aborting startup (check TV is plugged in, WOL is enabled in TV network settings, and TV_MAC/SUBNET are correct)"
    }

    Write-Log 'Attempting to switch input...'
    $success = $false
    $lastError = $null
    for ($retry = 1; $retry -le $MaxInputSwitchRetries; $retry++) {
        try {
            Switch-Input -InputId $PersonalInput
            Write-Log 'Input switch completed successfully'; $success = $true; break
        } catch {
            $lastError = $_
            if ($retry -eq $MaxInputSwitchRetries) {
                Write-Log "Input switch failed after $MaxInputSwitchRetries attempts: $($_.Exception.Message)" -IsError
                break
            }
            Write-Log "Input switch attempt $retry/$MaxInputSwitchRetries failed: $($_.Exception.Message)" -IsError

            # React to the failure instead of sleeping a fixed guess: confirm
            # the TV is still actually reachable before retrying the switch.
            Write-Log 'Re-checking TV is still reachable before retrying...'
            if (-not (Wait-ForTV -Ip $ip -MaxWaitSec 8 -PollIntervalMs 500)) {
                Write-Log 'TV dropped off the network between attempts - re-sending WOL' -IsError
                Send-WOL -TargetIp $ip
                [void](Wait-ForTV -Ip $ip -MaxWaitSec 15 -PollIntervalMs 750 -WolResendIntervalSec 5 -ResendWol)
            }
        }
    }

    if (-not $success) {
        if ($lastError) { throw $lastError }
        throw 'Personal mode failed to switch TV input'
    }

    Write-Log 'Enabling monitor...'
    Set-MonitorMode -Action 'enable'
    Write-Log 'Startup sequence complete'; Write-Log ('=' * 60)
}

function Invoke-Toggle {
    $monitors = Get-ActiveMonitorCount
    if ($monitors -gt 1) { Write-Log "$monitors monitors detected -> Work mode"; Switch-Input -InputId $WorkInput; Set-MonitorMode -Action 'disable' }
    else { Write-Log "$monitors monitor detected -> Personal mode"; Switch-Input -InputId $PersonalInput; Set-MonitorMode -Action 'enable' }
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
