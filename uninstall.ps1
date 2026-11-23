#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the screen-monitoring agent: scheduled task, running processes,
    binary and (unless -KeepConfig) the configuration with the device token.
    Revoke the device on the server as well: farseer-server revoke-device <name>
#>
[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:ProgramFiles 'FarSeerAgent'),
    [switch] $KeepConfig
)

$ErrorActionPreference = 'Stop'

Unregister-ScheduledTask -TaskPath '\FarSeerAgent\' -TaskName 'FarSeerAgent' -Confirm:$false -ErrorAction SilentlyContinue
# The elevated SYSTEM helper task (present only if installed with -WithElevatedHelper).
Unregister-ScheduledTask -TaskPath '\FarSeerAgent\' -TaskName 'FarSeerAgentSystem' -Confirm:$false -ErrorAction SilentlyContinue
# The one-time "register when the server is reachable" task, if the install was waiting.
Unregister-ScheduledTask -TaskPath '\FarSeerAgent\' -TaskName 'FarSeerAgentEnroll' -Confirm:$false -ErrorAction SilentlyContinue
# Anything left under the name used before FarSeer.
foreach ($t in 'RemAgent', 'RemAgentSystem', 'RemAgentEnroll') {
    Unregister-ScheduledTask -TaskPath '\RemAgent\' -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Get-Process -Name 'farseer-agent', 'rem-agent' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
$legacyInstall = Join-Path $env:ProgramFiles 'RemAgent'
if (Test-Path $legacyInstall) { Remove-Item -Recurse -Force $legacyInstall }
$legacyConfig = Join-Path $env:ProgramData 'RemAgent'
if (-not $KeepConfig -and (Test-Path $legacyConfig)) { Remove-Item -Recurse -Force $legacyConfig }
$configDir = Join-Path $env:ProgramData 'FarSeerAgent'
# A saved enrollment key never outlives the agent, even with -KeepConfig.
Remove-Item -LiteralPath (Join-Path $configDir 'private') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $configDir 'pending-enroll.flag') -Force -ErrorAction SilentlyContinue
if (-not $KeepConfig -and (Test-Path $configDir)) { Remove-Item -Recurse -Force $configDir }

# Remove the empty task folder if nothing else uses it.
try {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $svc.GetFolder('\').DeleteFolder('FarSeerAgent', 0)
} catch { }
try { $svc.GetFolder('\').DeleteFolder('RemAgent', 0) } catch { }

Write-Host "Agent removed$(if ($KeepConfig) { ' (configuration kept)' })."
