#Requires -Version 5.1
<#
.SYNOPSIS
    LG webOS TV / display state controller.

.DESCRIPTION
    Exactly three states exist: Personal, Work, Off.

    Each state is absolute and self-contained. Entering a state never assumes
    anything about the state the machine or the TV was previously in. Power
    (WOL) and the Windows topology are always fired, unconditionally. The TV
    input is different: it is READ from the TV (getForegroundAppInfo) and only
    switched when the TV reports something other than the target, then
    re-read to prove it stuck. The TV's own answer is the observed fact; there
    is no toggle, no "current state" tracking, and no inference from monitor
    counts.

        Personal -> TV powered on, TV input = personal HDMI, Windows extends.
        Work     -> TV powered on, TV input = work HDMI,     Windows internal only.
        Off      -> TV powered off,                          Windows internal only.

    Design rules enforced throughout:

      * No fixed sleeps or "wait and hope" delays anywhere in the happy path.
        Every transition is driven by an observed fact: a TCP connect that
        completed, a webOS subscription event that fired, a WM_DISPLAYCHANGE
        that arrived, a Win32 return code. Timeouts exist only as outer
        failure bounds, never as the mechanism by which progress is made.
        The one exception - a 1 s gap between retries while the TV's
        websocket daemon reports EWS ("Try Again Later") during a cold boot -
        is not a guessed interval: EWS is the TV asking to be retried, and
        the retry terminates the moment the daemon accepts the connection.

      * Independent work runs concurrently. The Windows display topology
        change is dispatched to a background runspace the moment it becomes
        valid to run, and is joined at the end, so it overlaps the websocket
        connect / register / input switch round trips instead of queuing
        behind them.

      * Fail loud. A state either establishes completely or the script exits
        non-zero with the reason.

.EXAMPLE
    lgtv.ps1 Personal
    lgtv.ps1 Work
    lgtv.ps1 Off
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('Personal', 'Work', 'Off')]
    [string]$State
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

$WebOSWssPort = 3001
$WolPort      = 9

# Defaults; overridable per-machine from the store file.
$DefaultPersonalInput = 'com.webos.app.hdmi3'
$DefaultWorkInput     = 'com.webos.app.hdmi4'

# --- Outer failure bounds only. Nothing below is used to pace normal work. ---
$ProbeTimeoutMs        = 350     # single TCP probe against the webOS port
$TVOnlineTimeoutMs     = 25000   # TV must answer on 3001 after WOL
$TVOfflineTimeoutMs    = 12000   # TV must stop answering after turnOff
$ConnectTimeoutMs      = 5000
$SendTimeoutMs         = 5000
$ReceiveTimeoutMs      = 8000
$RegisterTimeoutMs     = 4000
$SubscribeAckTimeoutMs = 2500
$InputConfirmTimeoutMs = 8000
$PowerReadyTimeoutMs   = 20000   # TV must report a ready power state before its input is touched
$InputSettleMs         = 2000    # listen-only window; used ONLY when the TV could not attest readiness
$DisplayConfirmMs      = 5000
$ScanTimeoutMs         = 6000
$WatchdogSec           = 75

$MaxRegisterAttempts = 30        # generous because EWS retries can span a cold boot
$MaxSwitchPasses     = 6         # read -> switch -> re-read passes inside one session
$MaxDisplayAttempts  = 3

# tvpower states in which the websocket answers but the TV is not really up.
# A launch accepted in these states is what the boot sequence later overwrites.
$TVNotReadyPowerStates = @('Suspend', 'Active Standby', 'Power Off', 'Unknown')
$MaxIoAttempts       = 5

$MaxLogSizeBytes = 2MB
$WolResendMs     = 1000          # WOL is UDP; re-emit while waiting, driven by elapsed probe time

# --- Logging verbosity ---
# $true  = every Write-Log line is persisted to $LogFile.
# $false = only -IsError lines are persisted. Informational lines still
#          print to the console, but are not written to disk. This keeps
#          the on-disk log small and focused on failures during normal
#          operation, while a single flip to $true turns the file into a
#          full trace for debugging.
$DEBUG_MODE = $true

$Script:InstanceMutex  = $null
$Script:MutexHeld      = $false
$Script:WatchdogTimer  = $null
$Script:WatchdogEvent  = $null
$Script:Store          = $null
$Script:SubnetInfo     = $null
$Script:TVMac          = $null

# =====================================================================
# Native interop
# =====================================================================
# Loaded before anything else runs so every later reference resolves.
# DisplayWatcher gives us a real OS signal for "the desktop topology
# actually changed", which is what lets the display path avoid polling.

$CoreInteropSource = @'
using System;
using System.Runtime.InteropServices;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

namespace LGTVControl {

    public static class Native {
        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int nIndex);
        public const int SM_CMONITORS = 80;
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

    // A real .NET delegate, not a PowerShell scriptblock. webOS TVs present a
    // self-signed cert, and SSL negotiation runs on a thread-pool thread with
    // no runspace attached, so a scriptblock callback breaks the handshake.
    public static class CertValidator {
        public static bool AlwaysTrust(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) {
            return true;
        }
    }
}
'@

# Compiled separately so that a host without Microsoft.Win32.SystemEvents still
# gets the core interop. Without this type the display path falls back from
# signal-driven confirmation to return-code confirmation; nothing else changes.
$DisplayWatcherSource = @'
using System;
using System.Threading;
using Microsoft.Win32;

namespace LGTVControl {
    // Event-driven replacement for "sleep, then check whether the monitors
    // changed". SystemEvents raises DisplaySettingsChanged on its own pump
    // thread, so the handler has to be compiled code - a PowerShell
    // scriptblock would fault with "no Runspace available", exactly like the
    // TLS callback would.
    public static class DisplayWatcher {
        private static readonly ManualResetEventSlim Signal = new ManualResetEventSlim(false);
        private static bool _hooked;
        private static readonly object Gate = new object();

        public static bool Arm() {
            lock (Gate) {
                Signal.Reset();
                if (_hooked) { return true; }
                try {
                    SystemEvents.DisplaySettingsChanged += delegate { Signal.Set(); };
                    _hooked = true;
                    return true;
                } catch {
                    return false;
                }
            }
        }

        public static bool Wait(int milliseconds) {
            try { return Signal.Wait(milliseconds); } catch { return false; }
        }
    }
}
'@

if (-not ('LGTVControl.Native' -as [type])) {
    Add-Type -TypeDefinition $CoreInteropSource
}

if (-not ('LGTVControl.DisplayWatcher' -as [type])) {
    try {
        Add-Type -TypeDefinition $DisplayWatcherSource -ReferencedAssemblies 'System.dll'
    } catch {
        Write-Host "WARNING: display-change signalling unavailable ($($_.Exception.Message)); falling back to return-code confirmation."
    }
}


# =====================================================================
# Logging
# =====================================================================

function Write-Log {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message, [switch]$IsError)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message

    # Console is unconditional. Interactive runs stay fully verbose regardless
    # of $DEBUG_MODE, so an operator watching the window never loses detail.
    Write-Host $line

    # File persistence is gated. -IsError always lands on disk because a
    # failure with no record is the one thing a logfile must never do.
    if (-not $IsError -and -not $DEBUG_MODE) { return }

    # Read + append + atomic rename. This is deliberately the same pattern
    # Write-JsonFileSafe uses for the store, and for the same reason: an
    # editor that saves via temp-file + rename leaves the logfile owned by
    # the editing user with an ACL that excludes the identity this script
    # runs under. Add-Content would then throw EPERM, and no amount of DACL
    # rewriting through Set-Acl can recover from a token that has lost
    # WriteDAC. Replacing the file sidesteps the problem entirely - Move-Item
    # creates a NEW file in the same directory, which inherits the directory
    # ACL that Initialize-Store has already verified and repaired.
    try {
        if (-not (Test-Path -LiteralPath $StorageDir)) { New-Item -ItemType Directory -Path $StorageDir -Force | Out-Null }

        # Read existing content. If the file exists but cannot be read, do
        # NOT overwrite it - the read failure would silently discard history.
        $existing = ''
        if (Test-Path -LiteralPath $LogFile) {
            try {
                $fs = New-Object System.IO.FileStream($LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                try { $existing = $sr.ReadToEnd() } finally { $sr.Dispose(); $fs.Dispose() }
            } catch {
                Write-Host ("[{0}] WARN: cannot read {1} - skipping file log line." -f (Get-Date -Format 'HH:mm:ss.fff'), $LogFile)
                return
            }
        }

        # Rotation check on the in-memory copy rather than a separate file
        # size call - one less handle on the file, one less race.
        if ($existing.Length -gt $MaxLogSizeBytes) {
            $backup = "$LogFile.old"
            try {
                if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
                Move-Item -LiteralPath $LogFile -Destination $backup -Force
            } catch {}
            $existing = ''
        }

        $tempPath = "$LogFile.tmp"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $fs = New-Object System.IO.FileStream($tempPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $sw = New-Object System.IO.StreamWriter($fs, $utf8NoBom)
        try {
            if ($existing.Length -gt 0) { $sw.Write($existing) }
            $sw.Write($line)
            $sw.Write([Environment]::NewLine)
            $sw.Flush()
        } finally { $sw.Dispose(); $fs.Dispose() }
        Move-Item -LiteralPath $tempPath -Destination $LogFile -Force
    } catch {
        Write-Host ("[{0}] WARN: log write failed: {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $_.Exception.Message)
    }
}

# =====================================================================
# Small shared helpers
# =====================================================================

function Get-Prop {
    # Strict-mode-safe property read. A missing or null member yields $Default
    # instead of throwing, which matters because every JSON payload here comes
    # off the wire or off disk and cannot be trusted to have a given shape.
    param($Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    try {
        $member = $Object.PSObject.Properties[$Name]
        if ($null -eq $member -or $null -eq $member.Value) { return $Default }
        return $member.Value
    } catch { return $Default }
}

function Invoke-WithRetry {
    # Retries without a fixed backoff: OnRetry performs the actual recovery
    # work (reconnect, re-probe, re-WOL) and that work is what takes time.
    # There is no Start-Sleep here by design.
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$MaxAttempts = 3,
        [scriptblock]$OnRetry
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try { return (& $Action $i) }
        catch {
            if ($i -eq $MaxAttempts) { throw }
            if ($OnRetry) { & $OnRetry $_ $i }
        }
    }
}

function Close-Quietly { param($Disposable) if ($Disposable) { try { $Disposable.Dispose() } catch {} } }
function Disconnect-Quietly { param($Client) if ($Client) { try { $Client.Disconnect() } catch {} } }

function Get-TVResponseError {
    # Inspects both layers of a webOS reply and returns $null only when both
    # say success. The SSAP envelope carries type='error' plus a top-level
    # 'error' string (e.g. "401 insufficient permissions") with an EMPTY
    # payload, so checking the payload alone loses the reason. The embedded
    # payload is the Luna service result: returnValue, and on failure
    # errorCode/errorText - the same fields webOS.service.request hands to
    # onFailure inside a TV app.
    param([AllowNull()]$Response)
    if (-not $Response) { return 'no response from TV' }

    $payload = Get-Prop $Response 'payload'
    if ([string](Get-Prop $Response 'type') -eq 'error') {
        $detail = [string](Get-Prop $Response 'error')
        if (-not $detail) { $detail = [string](Get-Prop $payload 'errorText') }
        if (-not $detail) { $detail = 'unspecified error' }
        return "error envelope: $detail"
    }

    if (Get-Prop $payload 'returnValue' $false) { return $null }
    $text = [string](Get-Prop $payload 'errorText' 'unknown error')
    $code = Get-Prop $payload 'errorCode'
    if ($null -ne $code) { return "$text (code $code)" }
    return $text
}

function Confirm-TVResponse {
    param([AllowNull()]$Response, [Parameter(Mandatory = $true)][string]$FailMessage)
    $problem = Get-TVResponseError -Response $Response
    if ($problem) { throw "${FailMessage}: $problem" }
}

function Get-TVEnvelopeError {
    # Envelope-only error check, for subscription pushes. The initial ack for
    # a subscribe carries payload.returnValue=true, but the pushes that follow
    # it do NOT necessarily carry returnValue at all - they are one-way state
    # notifications, not request replies. Running the fuller
    # Get-TVResponseError on a push therefore classifies every legitimate
    # transition as "unknown error" and skips it, which silently hangs
    # Wait-TVReady / Wait-TVForeground / Test-TVInputHolds until their bounds
    # expire. Only the SSAP envelope's type='error' is trustworthy here.
    param([AllowNull()]$Response)
    if (-not $Response) { return 'no response from TV' }
    if ([string](Get-Prop $Response 'type') -ne 'error') { return $null }
    $detail = [string](Get-Prop $Response 'error')
    if (-not $detail) { $detail = [string](Get-Prop (Get-Prop $Response 'payload') 'errorText') }
    if (-not $detail) { $detail = 'unspecified error' }
    return "error envelope: $detail"
}

# =====================================================================
# DPAPI
# =====================================================================

function Protect-String {
    param([AllowEmptyString()][string]$PlainText)
    if ([string]::IsNullOrEmpty($PlainText)) { return $PlainText }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Convert]::ToBase64String($enc)
}

function Unprotect-String {
    param([AllowEmptyString()][string]$EncryptedText)
    if ([string]::IsNullOrEmpty($EncryptedText)) { return $null }
    try {
        $bytes = [Convert]::FromBase64String($EncryptedText)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch { return $null }
}

# =====================================================================
# Subnet / CIDR
# =====================================================================

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
    param([Parameter(Mandatory = $true)][string]$Cidr)
    if ($Cidr -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$') {
        throw "SUBNET must be CIDR, e.g. 192.168.1.0/24 (got: '$Cidr')"
    }
    $networkText = $Matches[1]
    $prefix = [int]$Matches[2]
    if ($prefix -lt 16 -or $prefix -gt 32) { throw "SUBNET prefix must be between /16 and /32 (got: /$prefix)" }

    $raw = ConvertTo-IPUInt32 -IpAddress $networkText
    $hostBits = 32 - $prefix
    $mask = if ($hostBits -eq 0) { [uint32]::MaxValue } else { [uint32](([uint32]::MaxValue -shl $hostBits) -band [uint32]::MaxValue) }
    $network = [uint32]($raw -band $mask)
    $broadcast = [uint32]($network -bor ([uint32](-bnot $mask -band [uint32]::MaxValue)))
    $hosts = if ($hostBits -le 1) { 0 } else { [int]([math]::Pow(2, $hostBits)) - 2 }

    return [pscustomobject]@{
        NetworkValue     = $network
        BroadcastAddress = ConvertFrom-IPUInt32 -Value $broadcast
        HostCount        = $hosts
    }
}

# =====================================================================
# Store IO
# =====================================================================

function Repair-StorageAcl {
    # Grants FullControl to SYSTEM and Administrators, Modify to Users,
    # inheritable on directories. Never logs and never throws - Write-Log
    # calls this on write-failure, and a repair that reported its own
    # failure through Write-Log would recurse. Callers check the return.
    #
    # Two paths, because the direct .NET route does not always work:
    #
    #   Fast path - Set-Acl directly. Succeeds whenever the caller still has
    #   WriteDAC on the file. This is the normal case for files the script
    #   created and no outside process has rewritten.
    #
    #   Slow path - takeown.exe + icacls.exe. These enable
    #   SeTakeOwnershipPrivilege in their own process token, which Set-Acl
    #   does not. That matters because an editor saving via temp-file +
    #   rename can leave the file owned by the interactive user with an ACL
    #   that excludes SYSTEM entirely. In that state Set-Acl fails with
    #   "access denied" no matter how the FileSecurity object is built,
    #   because the SYSTEM token has no WriteDAC - only the ability to take
    #   ownership, which must be explicitly enabled.
    #
    # SIDs rather than names are used in the icacls call so the command is
    # locale-independent (SYSTEM / Administrators / Users translate
    # differently on non-English Windows).
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $isDir = (Get-Item -LiteralPath $Path) -is [System.IO.DirectoryInfo]
        $inherit = if ($isDir) { 'ContainerInherit,ObjectInherit' } else { 'None' }

        $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $usersSid  = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')

        try {
            $acl = Get-Acl -LiteralPath $Path
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid, 'FullControl', $inherit, 'None', 'Allow')))
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($adminsSid, 'FullControl', $inherit, 'None', 'Allow')))
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid,  'Modify',      $inherit, 'None', 'Allow')))
            Set-Acl -LiteralPath $Path -AclObject $acl
            return $true
        } catch {}

        $takeown = Join-Path $env:SystemRoot 'System32\takeown.exe'
        $icacls  = Join-Path $env:SystemRoot 'System32\icacls.exe'
        if (-not (Test-Path -LiteralPath $takeown) -or -not (Test-Path -LiteralPath $icacls)) { return $false }

        # /A sets the owner to Administrators rather than the current user.
        # SYSTEM is a member of Administrators, so it can then write DACLs
        # on the file.
        & $takeown /F $Path /A 2>&1 | Out-Null

        $grants = if ($isDir) {
            @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)M')
        } else {
            @('*S-1-5-18:F', '*S-1-5-32-544:F', '*S-1-5-32-545:M')
        }
        & $icacls $Path /grant @grants 2>&1 | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Read-JsonFileSafe {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Invoke-WithRetry -MaxAttempts $MaxIoAttempts -Action {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        try { $json = $sr.ReadToEnd() } finally { $sr.Dispose(); $fs.Dispose() }
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        return ($json | ConvertFrom-Json)
    }
}

function Write-JsonFileSafe {
    # Temp file plus atomic rename: an interrupted write leaves an orphan .tmp,
    # never a half-written store. Move-Item rather than File::Replace, which
    # throws "path is not of a legal form" on 5.1 when the process CWD is a
    # mapped network drive even though both paths are local and absolute.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Data)
    $json = $Data | ConvertTo-Json -Depth 10
    $tempPath = "$Path.tmp"
    Invoke-WithRetry -MaxAttempts $MaxIoAttempts -Action {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $fs = New-Object System.IO.FileStream($tempPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $sw = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
        try { $sw.Write($json); $sw.Flush() } finally { $sw.Dispose(); $fs.Dispose() }
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    } | Out-Null
}

function Initialize-Store {
    # Reads the store exactly once per run into $Script:Store. Every later
    # accessor works against that in-memory copy; disk is only touched again
    # when a value actually changes.
    $template = [ordered]@{
        _comment       = 'TV_MAC and SUBNET are required. SUBNET is CIDR, e.g. 192.168.1.0/24. tv_ip and client_key are managed automatically.'
        TV_MAC         = ''
        SUBNET         = ''
        PERSONAL_INPUT = $DefaultPersonalInput
        WORK_INPUT     = $DefaultWorkInput
        tv_ip          = ''
        client_key     = ''
    }

    if (-not (Test-Path -LiteralPath $StorageDir)) { New-Item -ItemType Directory -Path $StorageDir -Force | Out-Null }
    if (-not (Repair-StorageAcl -Path $StorageDir)) {
        Write-Host "WARN: could not repair ACL on $StorageDir - cross-identity writes may fail."
    }

    # The logfile is the one file an outside process is likely to have
    # touched between runs (opened in an editor). An editor saving via
    # temp-file + rename can leave it owned by the interactive user with
    # an ACL that excludes SYSTEM. Repairing it here, before the first
    # Write-Log call of the run, means a stale ACL costs one silent
    # takeown+icacls pass rather than one failed write plus a fallback.
    if ((Test-Path -LiteralPath $LogFile) -and -not (Repair-StorageAcl -Path $LogFile)) {
        Write-Host "WARN: could not repair ACL on $LogFile - writes may fail until it is fixed manually."
    }

    $store = [ordered]@{}
    foreach ($key in $template.Keys) { $store[$key] = $template[$key] }

    if (-not (Test-Path -LiteralPath $StoreFile)) {
        Write-JsonFileSafe -Path $StoreFile -Data $store
        if (-not (Repair-StorageAcl -Path $StoreFile)) {
            Write-Host "WARN: could not repair ACL on $StoreFile."
        }
        throw "Store file created at $StoreFile - populate TV_MAC and SUBNET, then re-run."
    }

    if (-not (Repair-StorageAcl -Path $StoreFile)) {
        Write-Host "WARN: could not repair ACL on $StoreFile - writes may fail."
    }

    $data = Read-JsonFileSafe -Path $StoreFile
    # Deliberately does not rewrite a template over an existing-but-unreadable
    # store: that would silently destroy TV_MAC and SUBNET.
    if (-not $data) { throw "Store file at $StoreFile is empty or unreadable - fix or delete it." }
    foreach ($prop in $data.PSObject.Properties) { $store[$prop.Name] = $prop.Value }

    $Script:Store = $store

    $Script:TVMac = [string]$Script:Store['TV_MAC']
    $subnetRaw = [string]$Script:Store['SUBNET']
    if ([string]::IsNullOrWhiteSpace($Script:TVMac) -or [string]::IsNullOrWhiteSpace($subnetRaw)) {
        throw "TV_MAC and SUBNET must both be set in $StoreFile"
    }
    if (($Script:TVMac -replace '[:\-]', '') -notmatch '^[0-9A-Fa-f]{12}$') {
        throw "TV_MAC is not a valid MAC address: $($Script:TVMac)"
    }
    $Script:SubnetInfo = Get-SubnetInfo -Cidr $subnetRaw

    if ([string]::IsNullOrWhiteSpace([string]$Script:Store['PERSONAL_INPUT'])) { $Script:Store['PERSONAL_INPUT'] = $DefaultPersonalInput }
    if ([string]::IsNullOrWhiteSpace([string]$Script:Store['WORK_INPUT']))     { $Script:Store['WORK_INPUT']     = $DefaultWorkInput }
}

function Get-StoredIp {
    $ip = [string]$Script:Store['tv_ip']
    if ([string]::IsNullOrWhiteSpace($ip)) { return $null }
    return $ip
}

function Get-StoredKey {
    $raw = [string]$Script:Store['client_key']
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return Unprotect-String $raw
}

function Save-StoredValues {
    param([string]$Ip, [string]$Key)
    $changed = $false
    if (-not [string]::IsNullOrWhiteSpace($Ip) -and [string]$Script:Store['tv_ip'] -ne $Ip) {
        $Script:Store['tv_ip'] = $Ip; $changed = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($Key)) {
        $Script:Store['client_key'] = Protect-String $Key; $changed = $true
    }
    if (-not $changed) { return }
    try {
        Write-JsonFileSafe -Path $StoreFile -Data $Script:Store
    } catch {
        # Persistence is an optimisation for the next run, never a blocker for
        # this one. The state we were asked to establish still gets established.
        Write-Log "Could not persist store: $($_.Exception.Message)" -IsError
    }
}

# =====================================================================
# Single instance + watchdog
# =====================================================================

function Confirm-SingleInstance {
    $mutexName = 'Global\LGTV_State_Controller'
    try {
        $Script:InstanceMutex = New-Object System.Threading.Mutex($false, $mutexName)
    } catch {
        Write-Log "Cannot create instance mutex: $($_.Exception.Message)" -IsError
        return $false
    }
    try {
        # Bounded wait rather than an instant bail: a state request issued while
        # a previous one is still finishing is a real request and should run,
        # just not concurrently.
        $Script:MutexHeld = $Script:InstanceMutex.WaitOne(15000)
    } catch [System.Threading.AbandonedMutexException] {
        # Previous holder was killed (watchdog). We now own it.
        $Script:MutexHeld = $true
    }
    if (-not $Script:MutexHeld) { Write-Log 'Another state change is already in progress - exiting.' }
    return $Script:MutexHeld
}

function Start-Watchdog {
    param([Parameter(Mandatory = $true)][int]$Seconds)
    $timer = New-Object System.Timers.Timer
    $timer.Interval = $Seconds * 1000
    $timer.AutoReset = $false
    $processId = $PID
    $storage = $StorageDir
    $log = $LogFile
    $limit = $Seconds
    $action = {
        try {
            $line = "[{0}] WATCHDOG: exceeded $limit seconds. Force exiting." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            try {
                if (-not (Test-Path -LiteralPath $storage)) { New-Item -ItemType Directory -Path $storage -Force | Out-Null }
                Add-Content -LiteralPath $log -Value $line -Encoding UTF8
            } catch {}
            Write-Host $line
        } catch {}
        try { Stop-Process -Id $processId -Force } catch {}
    # GetNewClosure is required: the event fires long after this function's
    # scope is gone, and without it $processId/$log/$limit are unbound at
    # fire time and the watchdog silently does nothing.
    }.GetNewClosure()
    $Script:WatchdogEvent = Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action $action
    $timer.Start()
    $Script:WatchdogTimer = $timer
}

function Stop-Watchdog {
    if ($Script:WatchdogEvent) { try { Unregister-Event -SubscriptionId $Script:WatchdogEvent.Id -Force } catch {}; $Script:WatchdogEvent = $null }
    if ($Script:WatchdogTimer) { try { $Script:WatchdogTimer.Stop(); $Script:WatchdogTimer.Dispose() } catch {}; $Script:WatchdogTimer = $null }
}

# =====================================================================
# Network
# =====================================================================

function Test-TVResponding {
    # One TCP probe of the webOS port. The port answering is the only reliable
    # evidence the TV is actually up: it replies to ICMP well before its
    # websocket service will accept a connection.
    param(
        [Parameter(Mandatory = $true)][string]$Ip,
        [int]$TimeoutMs = $ProbeTimeoutMs
    )
    $client = New-Object System.Net.Sockets.TcpClient
    $async = $null
    try {
        $async = $client.BeginConnect($Ip, $WebOSWssPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    } catch {
        return $false
    } finally {
        if ($async) { Close-Quietly $async.AsyncWaitHandle }
        Close-Quietly $client
    }
}

function Send-WOL {
    # Fired unconditionally on every Personal/Work entry. A magic packet to a TV
    # that is already awake is a no-op, so there is nothing to check first and
    # nothing to be gained by checking. Broadcast and directed unicast both go
    # out: broadcast survives an unknown/changed IP, unicast survives a switch
    # that drops subnet broadcast.
    param([string]$TargetIp)
    $mac = $Script:TVMac -replace '[:\-]', ''
    $macBytes = New-Object byte[] 6
    for ($i = 0; $i -lt 6; $i++) { $macBytes[$i] = [Convert]::ToByte($mac.Substring($i * 2, 2), 16) }
    $packet = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
    for ($i = 0; $i -lt 16; $i++) { [Array]::Copy($macBytes, 0, $packet, 6 + ($i * 6), 6) }

    $targets = New-Object System.Collections.Generic.List[string]
    $targets.Add($Script:SubnetInfo.BroadcastAddress)
    if (-not [string]::IsNullOrWhiteSpace($TargetIp)) { $targets.Add($TargetIp) }

    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        foreach ($target in $targets) {
            try { [void]$udp.Send($packet, $packet.Length, $target, $WolPort) }
            catch { Write-Log "WOL to $target failed: $($_.Exception.Message)" -IsError }
        }
    } finally { Close-Quietly $udp }
}

function Find-TV {
    # Sweeps the configured subnet for anything answering on 3001. Runs only
    # when there is no usable stored IP, or when the stored IP has gone stale.
    # All connects are launched at once and the wait is a real WaitAny on the
    # completion handles - nothing here is paced by a sleep.
    Write-Log 'Scanning subnet for webOS TV...'
    $hostCount = $Script:SubnetInfo.HostCount
    if ($hostCount -le 0 -or $hostCount -gt 4094) {
        throw "SUBNET is too large to scan (hosts: $hostCount). Use /20 or narrower."
    }

    $networkValue = $Script:SubnetInfo.NetworkValue
    $ips = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -le $hostCount; $i++) { $ips.Add((ConvertFrom-IPUInt32 -Value ([uint32]($networkValue + $i)))) }

    $clients = New-Object System.Collections.Generic.List[System.Net.Sockets.TcpClient]
    $asyncs  = New-Object System.Collections.Generic.List[System.IAsyncResult]
    $found = $null

    try {
        foreach ($ip in $ips) {
            $c = New-Object System.Net.Sockets.TcpClient
            $clients.Add($c)
            # Null placeholder keeps both lists index-aligned even if
            # BeginConnect throws synchronously under resource pressure.
            try { $asyncs.Add($c.BeginConnect($ip, $WebOSWssPort, $null, $null)) } catch { $asyncs.Add($null) }
        }

        $deadline = (Get-Date).AddMilliseconds($ScanTimeoutMs)
        $pending = New-Object System.Collections.Generic.List[int]
        for ($i = 0; $i -lt $asyncs.Count; $i++) { if ($asyncs[$i]) { $pending.Add($i) } }

        while ($pending.Count -gt 0 -and -not $found) {
            $remaining = [int]((New-TimeSpan -Start (Get-Date) -End $deadline).TotalMilliseconds)
            if ($remaining -le 0) { break }

            # WaitAny caps at 64 handles, so walk the pending set in chunks.
            $batch = [Math]::Min(64, $pending.Count)
            $handles = [System.Threading.WaitHandle[]]::new($batch)
            for ($h = 0; $h -lt $batch; $h++) { $handles[$h] = $asyncs[$pending[$h]].AsyncWaitHandle }

            $signalled = [System.Threading.WaitHandle]::WaitAny($handles, [Math]::Min($remaining, 250))
            if ($signalled -eq [System.Threading.WaitHandle]::WaitTimeout) {
                # This chunk is quiet; rotate it to the back and try the next.
                if ($pending.Count -gt $batch) {
                    $moved = $pending.GetRange(0, $batch)
                    $pending.RemoveRange(0, $batch)
                    $pending.AddRange($moved)
                }
                continue
            }

            $index = $pending[$signalled]
            $pending.RemoveAt($signalled)
            try {
                $clients[$index].EndConnect($asyncs[$index])
                if ($clients[$index].Connected) { $found = $ips[$index] }
            } catch {}
        }
    } finally {
        for ($i = 0; $i -lt $clients.Count; $i++) {
            if ($asyncs[$i]) { Close-Quietly $asyncs[$i].AsyncWaitHandle }
            Close-Quietly $clients[$i]
        }
    }

    if ($found) { Write-Log "TV found at $found"; return $found }
    throw 'No webOS TV answered on the configured subnet.'
}

function Wait-ForTVOnline {
    # Progress is driven entirely by probe results. Each probe either returns
    # immediately (host reachable, port refused) or costs its own timeout
    # (host down) - that is the pacing. WOL is re-emitted based on elapsed
    # probe time because the packet is UDP and can simply be dropped.
    param(
        [Parameter(Mandatory = $true)][string]$Ip,
        [int]$TimeoutMs = $TVOnlineTimeoutMs
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastWol = 0
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $attemptStart = $sw.ElapsedMilliseconds
        if (Test-TVResponding -Ip $Ip) {
            Write-Log ("TV online at {0} after {1}ms" -f $Ip, $sw.ElapsedMilliseconds)
            return $true
        }
        if (($sw.ElapsedMilliseconds - $lastWol) -ge $WolResendMs) {
            Send-WOL -TargetIp $Ip
            $lastWol = $sw.ElapsedMilliseconds
        }
        # A refused connection returns in microseconds. Yield the scheduler
        # briefly so a closed port cannot turn this into a hot spin; this is a
        # CPU courtesy, not a wait-and-hope.
        if (($sw.ElapsedMilliseconds - $attemptStart) -lt 25) { [System.Threading.Thread]::Sleep(25) }
    }
    return $false
}

function Resolve-TVOnline {
    <#
        Establishes the precondition shared by Personal and Work: the TV is
        powered and its websocket service is accepting connections, and we know
        its address. Assumes nothing about whether the TV was on, off, or moved
        to a new DHCP lease since the last run.
    #>
    $ip = Get-StoredIp
    Send-WOL -TargetIp $ip

    if ($ip -and (Wait-ForTVOnline -Ip $ip)) { return $ip }

    if ($ip) { Write-Log "Stored IP $ip did not come up - rescanning subnet." -IsError }

    # A scan can only see a TV that has already finished booting, so each failed
    # sweep re-emits WOL and sweeps again rather than giving up on the first
    # pass. The sweep itself is the wait.
    $ip = Invoke-WithRetry -MaxAttempts 3 -Action {
        Find-TV
    } -OnRetry {
        param($e, $attempt)
        Write-Log "Scan attempt $attempt found nothing - re-broadcasting WOL." -IsError
        Send-WOL
    }

    Save-StoredValues -Ip $ip
    Send-WOL -TargetIp $ip
    if (Wait-ForTVOnline -Ip $ip) { return $ip }

    throw "TV did not become reachable on port $WebOSWssPort. Check power, that 'Mobile TV On' / LAN wake is enabled on the TV, and that TV_MAC and SUBNET are correct."
}

# =====================================================================
# webOS client
# =====================================================================

$Script:CertValidationDelegate = $null

function Get-CertValidationDelegate {
    # Reflection rather than a [LGTVControl.CertValidator] literal: type
    # literals in class bodies bind at parse time, before Add-Type has run.
    if ($Script:CertValidationDelegate) { return $Script:CertValidationDelegate }
    try {
        $type = 'LGTVControl.CertValidator' -as [type]
        $method = $type.GetMethod('AlwaysTrust')
        $Script:CertValidationDelegate = [System.Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], $method)
    } catch {
        Write-Log "Could not build cert validation delegate: $($_.Exception.Message)" -IsError
        $Script:CertValidationDelegate = $null
    }
    return $Script:CertValidationDelegate
}

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
            appId                = 'com.lge.test'
            created              = '20140509'
            localizedAppNames    = @{ '' = 'LG Remote App' }
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

class LGWebOSClient {
    [string]$HostName
    [int]$Port
    [System.Net.WebSockets.ClientWebSocket]$Socket
    [int]$MessageId
    # Messages arriving out of order are held here rather than discarded.
    # Without this, waiting for a launch acknowledgement would swallow the
    # subscription event that proves the input actually changed.
    [System.Collections.Generic.List[object]]$Backlog
    # A read left in flight across calls, plus any half-received message. A
    # timed-out wait must NOT cancel ReceiveAsync: cancelling aborts a
    # ClientWebSocket outright, so "no push yet" would become "session dead".
    [object]$Pending
    [System.IO.MemoryStream]$Partial
    [byte[]]$RxBuffer

    LGWebOSClient([string]$hostName, [int]$port) {
        $this.HostName = $hostName
        $this.Port = $port
        $this.MessageId = 0
        $this.Backlog = New-Object System.Collections.Generic.List[object]
        $this.Pending = $null
        $this.Partial = New-Object System.IO.MemoryStream
        $this.RxBuffer = [byte[]]::new(8192)
    }

    hidden [System.Threading.CancellationTokenSource] NewCts([int]$TimeoutMs) {
        $c = New-Object System.Threading.CancellationTokenSource
        $c.CancelAfter($TimeoutMs)
        return $c
    }

    # Deliberately a class member rather than a call out to the script-scope
    # Get-Prop: class methods resolving script functions is a fragile coupling,
    # and every JSON payload read in here is untrusted in shape.
    hidden [object] Member([object]$Obj, [string]$Name) {
        if ($null -eq $Obj) { return $null }
        try {
            $property = $Obj.PSObject.Properties[$Name]
            if ($null -eq $property) { return $null }
            return $property.Value
        } catch { return $null }
    }

    hidden [void] AssertConnected() {
        if (-not $this.Socket -or $this.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            $state = if ($this.Socket) { [string]$this.Socket.State } else { 'null' }
            $desc = if ($this.Socket) { [string]$this.Socket.CloseStatusDescription } else { '' }
            throw "Not connected (state: $state, close: '$desc')"
        }
    }

    [void] Connect([int]$TimeoutMs) {
        # .NET Framework's default protocol selection can exclude the TLS
        # versions webOS speaks, which faults ConnectAsync instantly.
        try {
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.SecurityProtocolType]::Tls12 -bor
                [System.Net.SecurityProtocolType]::Tls11 -bor
                [System.Net.SecurityProtocolType]::Tls
        } catch {}

        $certDelegate = Get-CertValidationDelegate
        if ($certDelegate) {
            # Both callback paths are set on purpose. On 5.1 the ClientWebSocket
            # option is not settable and the ServicePointManager hook is the one
            # honoured; on 7+ the reverse. Setting both avoids host detection.
            try { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $certDelegate } catch {}
        }

        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        try {
            if ($certDelegate) {
                try { $ws.Options.RemoteCertificateValidationCallback = $certDelegate } catch {}
            }
            $uri = New-Object System.Uri("wss://$($this.HostName):$($this.Port)/")
            $cts = $this.NewCts($TimeoutMs)
            try {
                $task = $ws.ConnectAsync($uri, $cts.Token)
                if (-not $task.Wait($TimeoutMs)) { throw 'Connection task timed out' }
                if ($task.IsFaulted) {
                    $inner = $task.Exception
                    while ($inner -and $inner.InnerException) { $inner = $inner.InnerException }
                    if ($inner) { throw $inner }
                    throw $task.Exception
                }
                if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                    throw "WebSocket did not reach Open (state: $($ws.State))"
                }
                $this.Socket = $ws
                $ws = $null
            } finally { $cts.Dispose() }
        } catch {
            Close-Quietly $ws
            $detail = $_.Exception.Message
            $inner = $_.Exception.InnerException
            while ($inner) { $detail = "$detail | $($inner.Message)"; $inner = $inner.InnerException }
            throw "WebSocket connect failed: $detail"
        }
    }

    hidden [void] SendRaw([object]$Message, [int]$TimeoutMs) {
        $this.AssertConnected()
        $json = $Message | ConvertTo-Json -Depth 20 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $segment = New-Object System.ArraySegment[byte] (, $bytes)
        $cts = $this.NewCts($TimeoutMs)
        try {
            $task = $this.Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
            if (-not $task.Wait($TimeoutMs)) { throw 'Send timed out' }
            if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
        } catch { throw "Send failed: $($_.Exception.Message)" }
        finally { $cts.Dispose() }
    }

    # Returns one complete text message, or '' if none finished within
    # $TimeoutMs. A quiet socket is an answer, not an error: the read stays in
    # flight and the next call picks it up. Genuine faults and a close from the
    # TV still throw.
    hidden [string] ReceiveRaw([int]$TimeoutMs) {
        $this.AssertConnected()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        for (;;) {
            if ($null -eq $this.Pending) {
                $segment = New-Object System.ArraySegment[byte] (, $this.RxBuffer)
                $this.Pending = $this.Socket.ReceiveAsync($segment, [System.Threading.CancellationToken]::None)
            }
            $left = [int][Math]::Max(0, $TimeoutMs - $sw.ElapsedMilliseconds)
            $finished = $false
            try { $finished = $this.Pending.Wait($left) }
            catch {
                $this.Pending = $null
                $this.Partial.SetLength(0)
                throw "Receive failed: $($_.Exception.GetBaseException().Message)"
            }
            if (-not $finished) { return '' }

            $result = $this.Pending.Result
            $this.Pending = $null
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                $this.Partial.SetLength(0)
                throw "Receive failed: TV closed the socket ($($this.Socket.CloseStatusDescription))"
            }
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text -and $result.Count -gt 0) {
                $this.Partial.Write($this.RxBuffer, 0, $result.Count)
            }
            if ($result.EndOfMessage) {
                $text = [System.Text.Encoding]::UTF8.GetString($this.Partial.ToArray())
                $this.Partial.SetLength(0)
                return $text
            }
        }
        return ''
    }

    # Blocks on the socket until a message for $Id arrives. Anything else is
    # parked in the backlog for a later waiter.
    hidden [object] AwaitId([string]$Id, [int]$TimeoutMs) {
        for ($i = 0; $i -lt $this.Backlog.Count; $i++) {
            $held = $this.Backlog[$i]
            if ([string]$this.Member($held, 'id') -eq $Id) {
                $this.Backlog.RemoveAt($i)
                return $held
            }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $remaining = [int]($TimeoutMs - $sw.ElapsedMilliseconds)
            if ($remaining -le 0) { break }
            $raw = $this.ReceiveRaw($remaining)
            if ([string]::IsNullOrEmpty($raw)) { continue }
            $msg = $raw | ConvertFrom-Json
            if ([string]$this.Member($msg, 'id') -eq $Id) { return $msg }
            $this.Backlog.Add($msg)
        }
        return $null
    }

    [string] NextId() {
        $this.MessageId++
        return [string]$this.MessageId
    }

    [object] SendCommand([string]$Uri, [hashtable]$Payload, [int]$SendTimeout, [int]$ReceiveTimeout) {
        $id = $this.NextId()
        $message = [ordered]@{ type = 'request'; id = $id; uri = $Uri }
        if ($null -ne $Payload) { $message['payload'] = $Payload }
        $this.SendRaw($message, $SendTimeout)
        return $this.AwaitId($id, $ReceiveTimeout)
    }

    # Opens a webOS subscription and returns its id. Subsequent pushes for that
    # subscription reuse the id, which is what makes the input switch
    # event-driven instead of polled.
    [string] Subscribe([string]$Uri, [int]$SendTimeout) {
        $id = $this.NextId()
        $message = [ordered]@{ type = 'subscribe'; id = $id; uri = $Uri }
        $this.SendRaw($message, $SendTimeout)
        return $id
    }

    [object] AwaitSubscription([string]$Id, [int]$TimeoutMs) {
        return $this.AwaitId($Id, $TimeoutMs)
    }

    [string] Register([string]$ClientKey, [hashtable]$Manifest, [int]$SendTimeout, [int]$ReceiveTimeout) {
        $payload = $Manifest.Clone()
        if (-not [string]::IsNullOrEmpty($ClientKey)) { $payload['client-key'] = $ClientKey }
        $id = $this.NextId()
        $this.SendRaw([ordered]@{ type = 'register'; id = $id; payload = $payload }, $SendTimeout)

        # The TV may emit a PROMPT acknowledgement before the real result.
        # Loop until it declares one way or the other.
        for ($i = 0; $i -lt 10; $i++) {
            $msg = $this.AwaitId($id, $ReceiveTimeout)
            if ($null -eq $msg) { break }
            $type = [string]$this.Member($msg, 'type')
            $payloadIn = $this.Member($msg, 'payload')
            if ($type -eq 'registered') {
                $key = [string]$this.Member($payloadIn, 'client-key')
                if ([string]::IsNullOrEmpty($key)) { throw 'TV reported registration success without a client key' }
                return $key
            }
            if ($type -eq 'error') {
                throw "Registration rejected: $([string]$this.Member($msg, 'error'))"
            }
            if ([string]$this.Member($payloadIn, 'pairingType') -eq 'PROMPT') {
                Write-Log 'TV is prompting for pairing approval - accept it on screen.'
                continue
            }
        }
        throw 'Registration did not complete'
    }

    [void] Disconnect() { $this.Close() }

    [void] Close() {
        $ws = $this.Socket
        $this.Socket = $null
        if (-not $ws) { return }
        if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $cts = $this.NewCts(1500)
            try { [void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $cts.Token).Wait(1500) } catch {} finally { $cts.Dispose() }
        }
        Close-Quietly $ws
    }
}

function New-TVClient {
    param([Parameter(Mandatory = $true)][string]$Ip)

    $client = [LGWebOSClient]::new($Ip, $WebOSWssPort)
    $client.Connect($ConnectTimeoutMs)

    $storedKey = Get-StoredKey
    $key = $client.Register($storedKey, $RegistrationPayload, $SendTimeoutMs, $RegisterTimeoutMs)
    if ($key -and $key -ne $storedKey) {
        Save-StoredValues -Ip $Ip -Key $key
    }

    return $client
}

function Connect-TV {
    param(
        [Parameter(Mandatory = $true)][string]$Ip,
        [int]$MaxAttempts = $MaxRegisterAttempts
    )

    $lastMsg = ''
    $ewsRetries = 0

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if ($ewsRetries -gt 0) {
                Write-Log "TV websocket daemon ready after $ewsRetries EWS retr$(if ($ewsRetries -eq 1) {'y'} else {'ies'})."
            }
            return New-TVClient -Ip $Ip
        } catch {
            $lastMsg = $_.Exception.Message

            # EWS / "closed the socket" is the TV's own daemon saying "not
            # yet" during a cold boot. The retry is the correct response and
            # each individual attempt carries no information, so it stays
            # quiet. Only the final outcome - ready, or exhausted - is worth
            # a line.
            if ($lastMsg -like '*EWS*' -or $lastMsg -like '*closed the socket*') {
                $ewsRetries++
                Start-Sleep -Milliseconds 1000
                continue
            }

            # Every other failure - TLS fault, refused connection, protocol
            # error, registration rejection - is real and worth surfacing on
            # the attempt it happened. Retry immediately; the connect attempt
            # itself is the pacing.
            Write-Log "Connect attempt $attempt/$MaxAttempts failed: $lastMsg" -IsError
        }
    }

    throw "Connect/register failed after $MaxAttempts attempts (last: $lastMsg)"
}

# =====================================================================
# TV input
# =====================================================================

$Script:ForegroundUri = 'ssap://com.webos.applicationManager/getForegroundAppInfo'
$Script:PowerStateUri = 'ssap://com.webos.service.tvpower/power/getPowerState'

function Get-TVForegroundApp {
    # One direct GET of the foreground app. Envelope and embedded payload are
    # both validated. A well-formed reply with no appId (TV mid-boot, nothing
    # in front yet) reads as '' - "not the target" - rather than as an error.
    param([Parameter(Mandatory = $true)]$Client)
    $response = $Client.SendCommand($Script:ForegroundUri, $null, $SendTimeoutMs, $ReceiveTimeoutMs)
    Confirm-TVResponse -Response $response -FailMessage 'Foreground app query failed'
    return [string](Get-Prop (Get-Prop $response 'payload') 'appId' '')
}

function Wait-TVReady {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [int]$TimeoutMs = $PowerReadyTimeoutMs
    )

    # The TV pushes the current state as the first message on the
    # subscription, then again on every transition. There is no cadence
    # here - the wait is the push itself.
    $subId = $Client.Subscribe($Script:PowerStateUri, $SendTimeoutMs)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastState = '(no push)'

    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $push = $Client.AwaitSubscription($subId, [int]($TimeoutMs - $sw.ElapsedMilliseconds))
        if ($null -eq $push) { break }
        $problem = Get-TVEnvelopeError -Response $push
        if ($problem) {
            Write-Log "Power-state push carried an error: $problem" -IsError
            continue
        }
        $state = [string](Get-Prop (Get-Prop $push 'payload') 'state')
        if ($state) { $lastState = $state }
        if ($state -and ($TVNotReadyPowerStates -notcontains $state)) {
            Write-Log ("TV pushed power state '{0}' after {1}ms - ready." -f $state, $sw.ElapsedMilliseconds)
            return $true
        }
        Write-Log "TV pushed power state '$state' - awaiting Active."
    }

    throw "TV never pushed a ready power state within ${TimeoutMs}ms (last: '$lastState')"
}

function Wait-TVForeground {
    # Blocks on subscription pushes until the target shows up or the bound
    # expires. Only a hint that it is worth reading now: the caller re-reads
    # with a direct GET, which is the authority.
    param(
        [Parameter(Mandatory = $true)]$Client,
        [string]$SubId,
        [Parameter(Mandatory = $true)][string]$InputId,
        [int]$TimeoutMs = $InputConfirmTimeoutMs
    )
    if (-not $SubId) { return $false }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $push = $Client.AwaitSubscription($SubId, [int]($TimeoutMs - $sw.ElapsedMilliseconds))
        if ($null -eq $push) { return $false }
        $problem = Get-TVEnvelopeError -Response $push
        if ($problem) { Write-Log "Foreground push carried an error: $problem" -IsError; continue }
        if ([string](Get-Prop (Get-Prop $push 'payload') 'appId') -eq $InputId) {
            Write-Log ("TV pushed {0} as foreground after {1}ms" -f $InputId, $sw.ElapsedMilliseconds)
            return $true
        }
    }
    return $false
}

function Test-TVInputHolds {
    # Listen-only window on the foreground feed. $false the moment the TV
    # reports anything else in front. Silence for the whole window means it held.
    param(
        [Parameter(Mandatory = $true)]$Client,
        [string]$SubId,
        [Parameter(Mandatory = $true)][string]$InputId,
        [int]$WindowMs = $InputSettleMs
    )
    if (-not $SubId -or $WindowMs -le 0) { return $true }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $WindowMs) {
        $push = $Client.AwaitSubscription($SubId, [int]($WindowMs - $sw.ElapsedMilliseconds))
        if ($null -eq $push) { return $true }
        if (Get-TVEnvelopeError -Response $push) { continue }
        $appId = [string](Get-Prop (Get-Prop $push 'payload') 'appId')
        if ($appId -and $appId -ne $InputId) {
            Write-Log "TV moved off $InputId to '$appId' during the settle window."
            return $false
        }
    }
    return $true
}

function Set-TVInput {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$InputId
    )

    # 1. Block until the tvpower API explicitly returns an Active power state
    [void](Wait-TVReady -Client $Client)

    # 2. Subscribe to foreground app pushes
    $subId = $Client.Subscribe($Script:ForegroundUri, $SendTimeoutMs)
    [void]$Client.AwaitSubscription($subId, $SubscribeAckTimeoutMs)

    $lastSeen = ''
    for ($pass = 1; $pass -le $MaxSwitchPasses; $pass++) {
        $current = Get-TVForegroundApp -Client $Client
        if ($current) { $lastSeen = $current }

        if ($current -eq $InputId) {
            Write-Log "Input $InputId confirmed as foreground (pass $pass)."
        } else {
            Write-Log "Foreground is '$current', sending launch for '$InputId' (pass $pass of $MaxSwitchPasses)."
            $response = $Client.SendCommand('ssap://system.launcher/launch', @{ id = $InputId }, $SendTimeoutMs, $ReceiveTimeoutMs)
            Confirm-TVResponse -Response $response -FailMessage "Launch of $InputId rejected"

            [void](Wait-TVForeground -Client $Client -SubId $subId -InputId $InputId)
            $current = Get-TVForegroundApp -Client $Client
            if ($current) { $lastSeen = $current }
        }

        if ($current -eq $InputId) {
            # Monitor the push stream to capture if webOS overwrites the app during boot settling
            if (Test-TVInputHolds -Client $Client -SubId $subId -InputId $InputId) {
                Write-Log "Input $InputId verified and held by TV foreground feed."
                return
            }
            Write-Log "TV API pushed an app change event off $InputId; re-evaluating..."
        }
    }

    throw "TV API failed to settle on $InputId after $MaxSwitchPasses passes (last seen: '$lastSeen')"
}

function Invoke-TVPowerOff {
    param([Parameter(Mandatory = $true)][string]$Ip)

    $client = $null
    try {
        $client = Connect-TV -Ip $Ip

        # Subscribe BEFORE turnOff, so the transition push cannot race the
        # command acknowledgement into the backlog and get missed.
        $subId = $client.Subscribe($Script:PowerStateUri, $SendTimeoutMs)
        [void]$client.AwaitSubscription($subId, $SubscribeAckTimeoutMs)

        $response = $client.SendCommand('ssap://system/turnOff', $null, $SendTimeoutMs, $ReceiveTimeoutMs)
        Confirm-TVResponse -Response $response -FailMessage 'Power off rejected'

        # Two independent, event-shaped proofs of shutdown:
        #   1. A power-state push naming a not-ready state.
        #   2. The TV dropping the socket - the daemon goes down with it,
        #      so the close IS the evidence.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TVOfflineTimeoutMs) {
            try {
                $push = $client.AwaitSubscription($subId, [int]($TVOfflineTimeoutMs - $sw.ElapsedMilliseconds))
            } catch {
                Write-Log 'TV dropped the socket after power-off - off.'
                return
            }
            if ($null -eq $push) { break }
            $state = [string](Get-Prop (Get-Prop $push 'payload') 'state')
            if ($state -and ($TVNotReadyPowerStates -contains $state)) {
                Write-Log "TV pushed power state '$state' - off."
                return
            }
        }
        throw "Power-off acknowledged, but no shutdown push or socket close arrived within ${TVOfflineTimeoutMs}ms"
    } finally {
        Disconnect-Quietly $client
    }
}

# =====================================================================
# Windows display topology (runs concurrently with the TV work)
# =====================================================================

# Self-contained: it touches only static types compiled into the process by
# Add-Type, which every runspace in the AppDomain can see. No functions,
# variables, or modules need importing into the child runspace.
$Script:DisplayTopologyScript = {
    param([string]$Topology, [int]$ConfirmMs, [int]$MaxAttempts)

    $dc = 'LGTVControl.DisplayConfig' -as [type]
    $native = 'LGTVControl.Native' -as [type]
    $watcher = 'LGTVControl.DisplayWatcher' -as [type]
    if (-not $dc -or -not $native) { return @{ Ok = $false; Messages = @('Display interop types unavailable') } }

    $messages = New-Object System.Collections.Generic.List[string]
    $expected = if ($Topology -eq 'Extend') { 2 } else { 1 }
    $topologyFlag = if ($Topology -eq 'Extend') { $dc::SDC_TOPOLOGY_EXTEND } else { $dc::SDC_TOPOLOGY_INTERNAL }
    $flags = $topologyFlag -bor $dc::SDC_APPLY

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $armed = $false
        if ($watcher) { $armed = $watcher::Arm() }

        $rc = $dc::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, $flags)

        if ($rc -ne 0) {
            $messages.Add("SetDisplayConfig returned $rc on attempt $attempt")
            # Error 31 (ERROR_GEN_FAILURE) here is usually the HDMI path still
            # being renegotiated. Wait on the real display-change signal rather
            # than a guessed interval, then try again.
            if ($armed) { [void]$watcher::Wait($ConfirmMs) }
            continue
        }

        if ($native::GetSystemMetrics($native::SM_CMONITORS) -eq $expected) {
            $messages.Add("Topology '$Topology' applied and confirmed")
            return @{ Ok = $true; Messages = $messages.ToArray() }
        }

        # The call succeeded; Windows has not finished reprojecting yet. Block
        # on WM_DISPLAYCHANGE instead of sampling on a timer.
        if ($armed) { [void]$watcher::Wait($ConfirmMs) }

        if ($native::GetSystemMetrics($native::SM_CMONITORS) -eq $expected) {
            $messages.Add("Topology '$Topology' applied and confirmed")
            return @{ Ok = $true; Messages = $messages.ToArray() }
        }
        $messages.Add("Topology '$Topology' applied but monitor count is $($native::GetSystemMetrics($native::SM_CMONITORS)), expected $expected (attempt $attempt)")
    }

    return @{ Ok = $false; Messages = $messages.ToArray() }
}

function Start-DisplayTopology {
    param([Parameter(Mandatory = $true)][ValidateSet('Extend', 'Internal')][string]$Topology)
    Write-Log "Dispatching display topology change -> $Topology"
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($Script:DisplayTopologyScript).AddArgument($Topology).AddArgument($DisplayConfirmMs).AddArgument($MaxDisplayAttempts)
    return [pscustomobject]@{
        Shell    = $shell
        Runspace = $runspace
        Handle   = $shell.BeginInvoke()
        Topology = $Topology
    }
}

function Complete-DisplayTopology {
    param($Task)
    if (-not $Task) { return $true }
    $ok = $false
    try {
        $results = $Task.Shell.EndInvoke($Task.Handle)
        foreach ($item in $results) {
            if ($null -eq $item) { continue }
            foreach ($message in @($item.Messages)) { if ($message) { Write-Log "display: $message" } }
            $ok = [bool]$item.Ok
        }
        foreach ($errorRecord in $Task.Shell.Streams.Error) {
            Write-Log "display error: $($errorRecord.Exception.Message)" -IsError
        }
    } catch {
        Write-Log "Display topology task failed: $($_.Exception.Message)" -IsError
        $ok = $false
    } finally {
        try { $Task.Shell.Dispose() } catch {}
        try { $Task.Runspace.Close(); $Task.Runspace.Dispose() } catch {}
    }
    return $ok
}

# =====================================================================
# The three states
# =====================================================================

function Enter-ActiveState {
    param(
        [Parameter(Mandatory = $true)][string]$InputId,
        [Parameter(Mandatory = $true)][ValidateSet('Extend', 'Internal')][string]$Topology
    )

    $ip = Resolve-TVOnline

    # For 'Extend', start concurrently so the HDMI sink is ready.
    # For 'Internal', delay until after the TV sets input so Windows hotplug doesn't override Internal mode.
    $displayTask = $null
    if ($Topology -eq 'Extend') {
        $displayTask = Start-DisplayTopology -Topology $Topology
    }

    $client = $null
    $switchError = $null
    try {
        $client = Connect-TV -Ip $ip
        Set-TVInput -Client $client -InputId $InputId
    } catch {
        $switchError = $_
    } finally {
        Disconnect-Quietly $client
    }

    if ($Topology -eq 'Internal') {
        $displayTask = Start-DisplayTopology -Topology $Topology
    }

    $displayOk = Complete-DisplayTopology -Task $displayTask

    if ($switchError) { throw $switchError }
    if (-not $displayOk) { throw "Display topology '$Topology' could not be confirmed" }
}

function Enter-PersonalState {
    Write-Log '--- STATE: PERSONAL ---'
    Enter-ActiveState -InputId ([string]$Script:Store['PERSONAL_INPUT']) -Topology 'Extend'
}

function Enter-WorkState {
    Write-Log '--- STATE: WORK ---'
    Enter-ActiveState -InputId ([string]$Script:Store['WORK_INPUT']) -Topology 'Internal'
}

function Enter-OffState {
    <#
        The display topology has no dependency on the TV at all here, so it is
        dispatched immediately and runs while the TV is contacted.

        No WOL is sent: waking a TV in order to turn it off would be absurd. If
        the TV is not answering it is already in the target state, which is a
        success, not a failure - the state is defined by the end condition, not
        by which commands happened to be needed.
    #>
    Write-Log '--- STATE: OFF ---'
    $displayTask = Start-DisplayTopology -Topology 'Internal'

    $tvError = $null
    try {
        $ip = Get-StoredIp
        if (-not $ip) {
            try { $ip = Find-TV; Save-StoredValues -Ip $ip } catch { $ip = $null }
        }

        if (-not $ip) {
            Write-Log 'No TV located - treating as already off.'
        } elseif (-not (Test-TVResponding -Ip $ip -TimeoutMs 600)) {
            Write-Log "TV at $ip is not answering - already off."
        } else {
            Invoke-TVPowerOff -Ip $ip
            Write-Log 'TV powered off.'
        }
    } catch {
        $tvError = $_
    }

    $displayOk = Complete-DisplayTopology -Task $displayTask

    if ($tvError) { throw $tvError }
    if (-not $displayOk) { throw "Display topology 'Internal' could not be confirmed" }
}

# =====================================================================
# Entry point
# =====================================================================

if (-not (Confirm-SingleInstance)) { exit 0 }
Start-Watchdog -Seconds $WatchdogSec

$exitCode = 0
$runTimer = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Write-Log ("State request '{0}' by {1} (DEBUG_MODE={2})" -f $State, $env:USERNAME, $DEBUG_MODE)
    Initialize-Store

    switch ($State) {
        'Personal' { Enter-PersonalState }
        'Work'     { Enter-WorkState }
        'Off'      { Enter-OffState }
    }

    Write-Log ("State '{0}' established in {1}ms" -f $State, $runTimer.ElapsedMilliseconds)
} catch {
    Write-Log "FAILED to establish state '$State': $($_.Exception.Message)`n$($_.ScriptStackTrace)" -IsError
    $exitCode = 1
} finally {
    Stop-Watchdog
    if ($Script:InstanceMutex) {
        if ($Script:MutexHeld) { try { $Script:InstanceMutex.ReleaseMutex() } catch {} }
        try { $Script:InstanceMutex.Dispose() } catch {}
    }
}

exit $exitCode
