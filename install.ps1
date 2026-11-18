#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the screen-monitoring agent (rem-agent) on a company-owned Windows PC.

.DESCRIPTION
    * Copies rem-agent.exe to "C:\Program Files\RemAgent".
    * Writes C:\ProgramData\RemAgent\agent.toml (Administrators/SYSTEM: full, Users: read).
    * Registers the scheduled task "\RemAgent\RemAgent" that starts the agent
      "At log on" of any user, inside that user's interactive session (not Session 0).
      On Remote Desktop servers every RDP session gets its own agent.

    Users see a tray icon ("This PC is monitored by IT") while the agent runs.

.EXAMPLE
    .\install.ps1 -ServerUrl "wss://monitor.corp.local:8443/agent" -DeviceToken "rem_12_..."

.EXAMPLE
    # Peer-to-peer: the address printed by "rem-server p2p-address" (no DNS name or certificate):
    .\install.ps1 -ServerUrl "p2p://<64 hex digits>" -DeviceToken "rem_12_..."

.EXAMPLE
    # Passive install: no device is added on the server first. The PC registers
    # itself with the server's enrollment key and is given a name like quiet_falcon.
    # (-AliasServer looks the name up in servers.toml next to this script.)
    .\install.ps1 -AliasServer jet-engine -EnrollmentKey "<key from rem-server enrollment-key>"

.EXAMPLE
    # Internal CA not deployed via GPO:
    .\install.ps1 -ServerUrl "wss://monitor.corp.local:8443/agent" -DeviceToken "rem_12_..." -CaCertPath .\corp-root.pem
#>
[CmdletBinding()]
param(
    # wss://host[:port]/agent, or p2p://<server id> (peer-to-peer, no DNS name needed).
    [ValidatePattern('^(wss://\S+|p2p://[0-9a-fA-F]{64})$')] [string] $ServerUrl,
    # A short name for the server address, e.g. jet-engine, looked up in servers.toml
    # ([servers] jet-engine = "p2p://..."). Use instead of -ServerUrl.
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')] [string] $AliasServer,
    # The alias file. Default: servers.toml next to this script, then
    # C:\ProgramData\RemAgent\servers.toml.
    [string] $ServersFile,
    # Either a device token (the device was added on the server first) ...
    [ValidatePattern('^rem_\d+_[A-Za-z0-9_-]{43}$')] [string] $DeviceToken,
    # ... or the server's enrollment key (passive install): the PC registers itself
    # and receives its own name and token. Can also be given in the REM_ENROLLMENT_KEY
    # environment variable, which keeps it out of the command line.
    [string] $EnrollmentKey,
    # Where this PC is, in decimal degrees. Detected automatically through Windows
    # location services when available; pass both to set it by hand.
    [ValidateRange(-90, 90)] [double] $Latitude,
    [ValidateRange(-180, 180)] [double] $Longitude,
    # Do not record where this PC is.
    [switch] $NoLocation,
    [ValidateRange(500, 3600000)] [int] $IntervalMs = 2000,
    [ValidateRange(1, 100)] [int] $JpegQuality = 70,
    [string] $CaCertPath,
    # Default: rem-agent.exe next to this script (resolved below).
    [string] $SourceExe,
    [string] $InstallDir = (Join-Path $env:ProgramFiles 'RemAgent'),
    # Start the agent immediately for users who are already logged on.
    [switch] $StartNow,
    # Also install the elevated SYSTEM helper (a second task running as SYSTEM)
    # so the dashboard's "Run as administrator" can target this PC. Off unless
    # requested; the server must also set [commands] allow_elevated = true.
    [switch] $WithElevatedHelper
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty in parameter defaults when the script is started with
# "powershell -File", so the script folder is resolved here instead.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $SourceExe) { $SourceExe = Join-Path $ScriptDir 'rem-agent.exe' }
$TaskPath = '\RemAgent\'
$TaskName = 'RemAgent'
$SystemTaskName = 'RemAgentSystem'
$ConfigDir = Join-Path $env:ProgramData 'RemAgent'
$ConfigFile = Join-Path $ConfigDir 'agent.toml'
$Exe = Join-Path $InstallDir 'rem-agent.exe'

# Well-known SIDs (language independent).
$SidSystem = 'S-1-5-18'
$SidAdmins = 'S-1-5-32-544'
$SidUsers = 'S-1-5-32-545'

function Write-Utf8NoBom([string] $Path, [string] $Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-RestrictedAcl([string] $Path) {
    # Remove inheritance; SYSTEM + Administrators full control, Users read-only.
    & icacls.exe $Path /inheritance:r /grant:r "*${SidSystem}:(OI)(CI)F" "*${SidAdmins}:(OI)(CI)F" "*${SidUsers}:(OI)(CI)RX" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Path" }
}

if (-not (Test-Path $SourceExe)) { throw "rem-agent.exe not found at $SourceExe" }

# --- What to connect to, and how this PC gets its token.
if ($ServerUrl -and $AliasServer) { throw "Use either -ServerUrl or -AliasServer, not both." }
if (-not $ServerUrl -and -not $AliasServer) { throw "Give the server: -ServerUrl <address> or -AliasServer <name>." }
if (-not $EnrollmentKey) { $EnrollmentKey = $env:REM_ENROLLMENT_KEY }
if ($DeviceToken -and $EnrollmentKey -and $PSBoundParameters.ContainsKey('EnrollmentKey')) { throw "Use either -DeviceToken or -EnrollmentKey, not both." }
if (-not $DeviceToken -and -not $EnrollmentKey) { throw "Give -DeviceToken (device added on the server) or -EnrollmentKey (passive install)." }
if ($PSBoundParameters.ContainsKey('Latitude') -ne $PSBoundParameters.ContainsKey('Longitude')) { throw "Give -Latitude and -Longitude together." }

Write-Host "Stopping running agents (if any)..."
Get-Process -Name 'rem-agent' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Write-Host "Installing binary to $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Force $SourceExe $Exe

Write-Host "Writing configuration to $ConfigFile"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Set-RestrictedAcl $ConfigDir

# Run "rem-agent --resolve/--enroll" and read what it wrote (it has no console).
# The result file is private to this script and deleted straight away.
function Invoke-AgentSetup([string[]] $Flags, [string] $Key) {
    $out = Join-Path $ConfigDir ("setup-" + [guid]::NewGuid().ToString('N') + ".out")
    $argList = @($Flags | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) + @('--out', ('"' + $out + '"'))
    if ($Key) { $env:REM_ENROLLMENT_KEY = $Key }
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList ($argList -join ' ') -Wait -PassThru -WindowStyle Hidden
    } finally {
        Remove-Item Env:REM_ENROLLMENT_KEY -ErrorAction SilentlyContinue
    }
    $result = @{}
    if (Test-Path $out) {
        Get-Content -LiteralPath $out | ForEach-Object { $k, $v = $_ -split '=', 2; if ($k) { $result[$k] = $v } }
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
    if ($p.ExitCode -ne 0 -or $result['ok'] -ne 'true') {
        $why = if ($result['error']) { $result['error'] } else { "exit code $($p.ExitCode)" }
        throw $why
    }
    return $result
}

# The caller's alias file: -ServersFile, else next to this script, else the one an earlier install left.
$serversFile = $ServersFile
if (-not $serversFile) {
    $serversFile = @((Join-Path $ScriptDir 'servers.toml'), (Join-Path $ConfigDir 'servers.toml')) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
$serverArg = if ($AliasServer) { $AliasServer } else { $ServerUrl }
$setupFlags = @('--resolve', '--server', $serverArg)
if ($serversFile) { $setupFlags += @('--servers-file', $serversFile) }
if ($CaCertPath) { $setupFlags += @('--ca-cert', $CaCertPath) }
$ServerUrl = (Invoke-AgentSetup $setupFlags $null)['server_url']
if ($AliasServer) { Write-Host "Server alias '$AliasServer' is $ServerUrl" }

# Re-running the installer must not register the PC a second time.
if (-not $DeviceToken -and (Test-Path $ConfigFile)) {
    $old = Get-Content -LiteralPath $ConfigFile -Raw
    if ($old -match '(?m)^\s*server_url\s*=\s*"([^"]+)"' -and $Matches[1] -eq $ServerUrl -and
        $old -match '(?m)^\s*device_token\s*=\s*"(rem_\d+_[A-Za-z0-9_-]{43})"') {
        $DeviceToken = $Matches[1]
        Write-Host "This PC is already registered with that server; keeping its device token."
    }
}
if (-not $DeviceToken) {
    Write-Host "Registering this PC with the server (enrollment)..."
    $enrollFlags = @('--enroll', '--server', $ServerUrl)
    if ($CaCertPath) { $enrollFlags += @('--ca-cert', $CaCertPath) }
    $enrolled = Invoke-AgentSetup $enrollFlags $EnrollmentKey
    $DeviceToken = $enrolled['device_token']
    if ($DeviceToken -notmatch '^rem_\d+_[A-Za-z0-9_-]{43}$') { throw "The server sent an unusable device token." }
    Write-Host "Registered as '$($enrolled['device_name'])'."
    if ($enrolled['pending'] -eq 'true') {
        Write-Host "An administrator must enable this device in the dashboard before it connects."
    }
}

# Where this PC is, for reports. Windows location services must be on; if they are
# not (or the PC is a server with no location source) nothing is recorded.
function Get-Coordinates {
    try {
        Add-Type -AssemblyName System.Device
        $w = New-Object System.Device.Location.GeoCoordinateWatcher([System.Device.Location.GeoPositionAccuracy]::Default)
        try {
            [void] $w.TryStart($true, [TimeSpan]::FromSeconds(8))
            $loc = $w.Position.Location
            if ($w.Permission -ne 'Denied' -and -not $loc.IsUnknown -and -not [double]::IsNaN($loc.Latitude) -and -not ($loc.Latitude -eq 0 -and $loc.Longitude -eq 0)) {
                return @($loc.Latitude, $loc.Longitude)
            }
        } finally { $w.Dispose() }
    } catch { }
    return $null
}
$coords = $null
if (-not $NoLocation) {
    if ($PSBoundParameters.ContainsKey('Latitude')) {
        $coords = @($Latitude, $Longitude)
    } else {
        $coords = Get-Coordinates
    }
}

$toml = @"
# Screen-monitoring agent configuration (managed by IT).
server_url   = "$ServerUrl"
device_token = "$DeviceToken"
interval_ms  = $IntervalMs
jpeg_quality = $JpegQuality
"@
if ($AliasServer) { $toml += "`nserver_alias = `"$AliasServer`"`n" }
if ($coords) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $toml += ("`nlatitude  = {0}`nlongitude = {1}`n" -f ([double]$coords[0]).ToString('0.######', $inv), ([double]$coords[1]).ToString('0.######', $inv))
    Write-Host ("Location recorded: {0}, {1}" -f ([double]$coords[0]).ToString('0.####', $inv), ([double]$coords[1]).ToString('0.####', $inv))
} elseif (-not $NoLocation) {
    Write-Host "Location not available on this PC; none recorded (pass -Latitude/-Longitude to set it)."
}
if ($CaCertPath) {
    if (-not (Test-Path $CaCertPath)) { throw "CA certificate not found: $CaCertPath" }
    $caDest = Join-Path $ConfigDir 'ca.pem'
    Copy-Item -Force $CaCertPath $caDest
    # TOML literal string: backslashes need no escaping.
    $toml += "`nca_cert     = '$caDest'`n"
}
# The file takes its permissions from the folder (set above). Folder-style
# inheritance flags must not be applied to a file: that left it unreadable.
# Reset first as well, so a file left unreadable by an older installer can be replaced.
if (Test-Path $ConfigFile) { & icacls.exe $ConfigFile /reset | Out-Null }
Write-Utf8NoBom $ConfigFile $toml
& icacls.exe $ConfigFile /reset | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed on $ConfigFile" }

Write-Host "Registering scheduled task $TaskPath$TaskName"
$usersGroup = (New-Object System.Security.Principal.SecurityIdentifier($SidUsers)).Translate([System.Security.Principal.NTAccount]).Value
$action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $InstallDir
$trigger = New-ScheduledTaskTrigger -AtLogOn            # no -User => any user
$principal = New-ScheduledTaskPrincipal -GroupId $usersGroup -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances Parallel `
    -StartWhenAvailable `
    -Priority 7
$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'IT security screen monitoring agent. Shows a tray icon while active.'
Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -InputObject $task -Force | Out-Null

# Elevated SYSTEM helper: a second task running as NT AUTHORITY\SYSTEM that
# executes "Run as administrator" commands. It starts at boot (no user needed),
# does no screen capture, and is isolated from the interactive user session so a
# non-admin user can't use it to escalate. Installed only on request; the server
# must also set [commands] allow_elevated = true for it to be used.
$SystemAccount = (New-Object System.Security.Principal.SecurityIdentifier($SidSystem)).Translate([System.Security.Principal.NTAccount]).Value
if ($WithElevatedHelper) {
    Write-Host "Registering elevated helper task $TaskPath$SystemTaskName (runs as $SystemAccount)"
    $sysAction = New-ScheduledTaskAction -Execute $Exe -Argument '--system' -WorkingDirectory $InstallDir
    $sysTrigger = New-ScheduledTaskTrigger -AtStartup
    $sysPrincipal = New-ScheduledTaskPrincipal -UserId $SystemAccount -LogonType ServiceAccount -RunLevel Highest
    $sysSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -Priority 7
    $sysTask = New-ScheduledTask -Action $sysAction -Trigger $sysTrigger -Principal $sysPrincipal -Settings $sysSettings `
        -Description 'IT security monitoring — elevated command helper (runs commands as SYSTEM).'
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $SystemTaskName -InputObject $sysTask -Force | Out-Null
} else {
    # Re-running without the switch removes a helper installed earlier.
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $SystemTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

if ($StartNow) {
    Write-Host "Starting agent for logged-on users..."
    Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
    if ($WithElevatedHelper) { Start-ScheduledTask -TaskPath $TaskPath -TaskName $SystemTaskName }
}

Write-Host ""
Write-Host "Installed. The agent starts at the next user logon$(if ($StartNow) { ' (and was started now)' })."
if ($WithElevatedHelper) {
    Write-Host "Elevated SYSTEM helper installed (starts at boot). 'Run as administrator' works"
    Write-Host "once the server sets [commands] allow_elevated = true."
}
Write-Host "Agent logs: %LOCALAPPDATA%\RemAgent\logs of each user."
