# REM agent one-line installer for p2p://33d076e64d2442c7495866471178e63da8eb1f66ed5cba0cf45eabddbd17db11.
# Removes any installed agent, then registers this PC with the server.
# Needs: an administrator PowerShell and $env:REM_ENROLLMENT_KEY.
& {
    $ErrorActionPreference = 'Stop'
    $base   = 'https://raw.githubusercontent.com/christianigay/agent/v2'
    $server = 'p2p://33d076e64d2442c7495866471178e63da8eb1f66ed5cba0cf45eabddbd17db11'
    $files  = [ordered]@{ 'rem-agent.exe' = '630050300ACE8B3763849830F3A2BA31B644D18CB1049FB8CF10BC280D9161D6'; 'install.ps1' = '85C76EEE6A5D29A0B63D84D54A34164285D80E12E5FABBFA15430C4964BD0A60'; 'uninstall.ps1' = '8FCC27B9FC3BE2440CC1E8FA95A2D752DC6139067322E1D21631F2198CEBC060' }

    if ($ExecutionContext.SessionState.LanguageMode.value__ -ne 0) {
        Write-Host 'PowerShell is not running in Full Language Mode.'; return
    }
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { Write-Host 'Open PowerShell as administrator and run this again.'; return }
    if (-not $env:REM_ENROLLMENT_KEY -and -not $env:REM_UPDATE) {
        Write-Host 'Set the enrollment key first:  $env:REM_ENROLLMENT_KEY = "THE-KEY"'; return
    }
    if ($env:REM_UPDATE) {
        # An update keeps the PC's registration and needs no key. Refused up front, before
        # anything is removed, if this PC has none for this server.
        $cfgFile = Join-Path $env:ProgramData 'RemAgent\agent.toml'
        $saved = if (Test-Path $cfgFile) { Get-Content -LiteralPath $cfgFile -Raw } else { '' }
        if (($saved -notmatch '(?m)^\s*device_token\s*=\s*"rem_\d+_[A-Za-z0-9_-]{43}"') -or
            ($saved -notmatch ('(?m)^\s*server_url\s*=\s*"' + [regex]::Escape($server) + '"'))) {
            Write-Host 'Error: this PC is not registered with this server, so it cannot be updated. Install it with the enrollment key instead (nothing was changed).' -ForegroundColor Red
            return
        }
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # The work: download, check, remove the old agent, install. Kept in a script block so the
    # same text can run here or, when the agent itself is the caller, from a scheduled task.
    $work = {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('rem_' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $moved = $false
        try {
            # Run everything from our own folder. Capturing a program's output starts it in
            # PowerShell's current folder, and "the directory name is invalid" follows if
            # that folder is gone or can't be used (a deleted or network location).
            Push-Location -LiteralPath $dir
            $moved = $true
            Write-Host 'Installing the agent...'
            $web = New-Object Net.WebClient
            foreach ($name in $files.Keys) {
                $path = Join-Path $dir $name
                $web.DownloadFile("$base/$name", $path)
                if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne $files[$name]) {
                    throw "Checksum mismatch for $name; nothing was installed."
                }
            }

            $ps = Join-Path $PSHOME 'powershell.exe'
            $run = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
            # The two scripts talk a lot; keep what they say for problems, and show only the
            # lines that need attention (a server that can't be reached, an approval to give).
            $quiet = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'

            $un = @($run + (Join-Path $dir 'uninstall.ps1'))
            if ($env:REM_UPDATE -or -not $env:REM_FRESH) { $un += '-KeepConfig' }
            $said = (& $ps @un 2>&1 | Out-String)
            if ($LASTEXITCODE) { $ErrorActionPreference = $quiet; throw "Removing the old agent failed (exit $LASTEXITCODE).`r`n$said" }

            $in = @($run + (Join-Path $dir 'install.ps1') + @('-ServerUrl', $server, '-SourceExe', (Join-Path $dir 'rem-agent.exe'), '-StartNow'))
            if ($env:REM_UPDATE) { $in += '-Update' }
            if (-not $env:REM_NO_ELEVATED) { $in += '-WithElevatedHelper' }
            if ($env:REM_NO_LOCATION) { $in += '-NoLocation' }
            elseif ($env:REM_LATITUDE -and $env:REM_LONGITUDE) { $in += @('-Latitude', $env:REM_LATITUDE, '-Longitude', $env:REM_LONGITUDE) }
            $said = (& $ps @in 2>&1 | Out-String)
            $code = $LASTEXITCODE
            $ErrorActionPreference = $quiet
            if ($code) { throw "Installing failed (exit $code).`r`n$said" }

            $notes = @($said -split "`r?`n" | Where-Object { $_ -match 'NOT registered|administrator must enable|can.t be reached|Installing anyway' })
            if ($notes.Count) {
                $notes | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
                Write-Host 'Agent installed (see above).'
            } else {
                Write-Host 'Agent installed successfully.'
            }
        }
        catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        finally {
            if ($moved) { try { Pop-Location -ErrorAction Stop } catch { try { Set-Location -LiteralPath $env:SystemRoot } catch {} } }
            Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue
        }
    }

    # Started from the dashboard's command box? Then rem-agent.exe is our parent, and the
    # first thing the installer does is stop every rem-agent: it would kill itself half way
    # and leave the PC with no agent. A one-time SYSTEM task outlives the agent instead.
    function Test-UnderAgent {
        try {
            $id = $PID
            for ($i = 0; $i -lt 12 -and $id; $i++) {
                $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
                if (-not $p) { break }
                if ($p.Name -ieq 'rem-agent.exe') { return $true }
                $id = $p.ParentProcessId
            }
        } catch {}
        return $false
    }

    if (-not $env:REM_NO_DETACH -and (Test-UnderAgent)) {
        try {
            $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
            $wd = Join-Path $env:ProgramData 'RemAgentInstall'
            New-Item -ItemType Directory -Force -Path $wd | Out-Null
            & icacls.exe $wd /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
            if ($LASTEXITCODE) { throw 'icacls failed on the install folder.' }
            $log = Join-Path $wd 'install.log'
            $envFile = Join-Path $wd 'env.ps1'
            $runFile = Join-Path $wd 'run.ps1'
            # Each element is parenthesized: in PowerShell the comma binds tighter than +.
            $pre = @(
                ('$base = ' + (& $q $base)),
                ('$server = ' + (& $q $server)),
                ('$files = [ordered]@{ ' + ((@($files.Keys) | ForEach-Object { (& $q $_) + ' = ' + (& $q $files[$_]) }) -join '; ') + ' }'))
            foreach ($n in 'REM_ENROLLMENT_KEY', 'REM_UPDATE', 'REM_FRESH', 'REM_NO_ELEVATED', 'REM_NO_LOCATION', 'REM_LATITUDE', 'REM_LONGITUDE', 'REM_NAME_PREFIX') {
                $v = [Environment]::GetEnvironmentVariable($n)
                if ($v) { $pre += ('$env:' + $n + ' = ' + (& $q $v)) }
            }
            [IO.File]::WriteAllText($envFile, ($pre -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
            $runText = @(
                'Start-Sleep -Seconds 5   # let the dashboard receive this command''s answer first',
                '$ErrorActionPreference = ''Continue''',
                ('Start-Transcript -Path ' + (& $q $log) + ' -Force | Out-Null'),
                ('. ' + (& $q $envFile)),
                ('Remove-Item -LiteralPath ' + (& $q $envFile) + ' -Force -ErrorAction SilentlyContinue   # the key must not stay on disk'),
                'try {',
                '& {',
                $work.ToString(),
                '}',
                '} finally {',
                '  Unregister-ScheduledTask -TaskName ''RemAgentInstall'' -Confirm:$false -ErrorAction SilentlyContinue',
                '  Stop-Transcript | Out-Null',
                '}') -join "`r`n"
            [IO.File]::WriteAllText($runFile, $runText, (New-Object Text.UTF8Encoding($false)))

            $system = (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')).Translate([Security.Principal.NTAccount]).Value
            $act = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $runFile + '"')
            $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)
            $pri = New-ScheduledTaskPrincipal -UserId $system -LogonType ServiceAccount -RunLevel Highest
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
            Register-ScheduledTask -TaskName 'RemAgentInstall' -Action $act -Trigger $trg -Principal $pri -Settings $set -Force | Out-Null
            Start-ScheduledTask -TaskName 'RemAgentInstall'
            Write-Host 'The installer was started in the background, because it replaces the agent that ran this command.'
            Write-Host 'This PC goes offline for a minute or two and then comes back by itself.'
            Write-Host "Progress and any error: $log"
        }
        catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        return
    }

    & $work
}
