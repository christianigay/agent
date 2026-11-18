#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the screen-monitoring agent: scheduled task, running processes,
    binary and (unless -KeepConfig) the configuration with the device token.
    Revoke the device on the server as well: rem-server revoke-device <name>
#>
[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:ProgramFiles 'RemAgent'),
    [switch] $KeepConfig
)

$ErrorActionPreference = 'Stop'

Unregister-ScheduledTask -TaskPath '\RemAgent\' -TaskName 'RemAgent' -Confirm:$false -ErrorAction SilentlyContinue
# The elevated SYSTEM helper task (present only if installed with -WithElevatedHelper).
Unregister-ScheduledTask -TaskPath '\RemAgent\' -TaskName 'RemAgentSystem' -Confirm:$false -ErrorAction SilentlyContinue
# The one-time "register when the server is reachable" task, if the install was waiting.
Unregister-ScheduledTask -TaskPath '\RemAgent\' -TaskName 'RemAgentEnroll' -Confirm:$false -ErrorAction SilentlyContinue
Get-Process -Name 'rem-agent' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
$configDir = Join-Path $env:ProgramData 'RemAgent'
# A saved enrollment key never outlives the agent, even with -KeepConfig.
Remove-Item -LiteralPath (Join-Path $configDir 'private') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $configDir 'pending-enroll.flag') -Force -ErrorAction SilentlyContinue
if (-not $KeepConfig -and (Test-Path $configDir)) { Remove-Item -Recurse -Force $configDir }

# Remove the empty task folder if nothing else uses it.
try {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $svc.GetFolder('\').DeleteFolder('RemAgent', 0)
} catch { }

Write-Host "Agent removed$(if ($KeepConfig) { ' (configuration kept)' })."
