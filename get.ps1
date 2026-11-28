# FarSeer agent one-line installer for p2p://092cafb964409829e2d76079ae4eccfe3b5b60f3f9d281312648cf137b111d65.
# Removes any installed agent, then registers this PC with the server.
# Needs: an administrator PowerShell and $env:FARSEER_ENROLLMENT_KEY.
# Optional: $env:FARSEER_SERVER connects to another server instead of p2p://092cafb964409829e2d76079ae4eccfe3b5b60f3f9d281312648cf137b111d65.
& {
    $ErrorActionPreference = 'Stop'
    $base   = 'https://github.com/christianigay/agent/releases/download/v3'
    $server = 'p2p://092cafb964409829e2d76079ae4eccfe3b5b60f3f9d281312648cf137b111d65'
    $files  = [ordered]@{ 'farseer-agent.exe' = '9F7BF1C39482866120B9883B9137DBF59C09770D50FBF96FFA43871D261EF7AC'; 'install.ps1' = '9FC53F1F35435FE256E33F859C59AF385327088F82A13AAB082B5170C4464029'; 'uninstall.ps1' = '3A0B743CFC55B3530726C50A9637BF48B5A384E8D5B1AF0573538A931968603E' }
    # One shared installer can serve many servers: the command may name the server to connect to.
    if ($env:FARSEER_SERVER) {
        if ($env:FARSEER_SERVER -match '^(p2p://[0-9A-Fa-f]{64}|wss://[A-Za-z0-9._:/-]+)$') { $server = $env:FARSEER_SERVER }
        else { Write-Host 'FARSEER_SERVER must look like p2p://<64 hex> or wss://host/agent.'; return }
    }

    # Commands saved before the rename set REM_* variables; they still work.
    foreach ($n in 'ENROLLMENT_KEY', 'UPDATE', 'FRESH', 'NO_ELEVATED', 'NO_LOCATION', 'LATITUDE', 'LONGITUDE', 'NAME_PREFIX', 'NO_DETACH') {
        $legacy = [Environment]::GetEnvironmentVariable('REM_' + $n)
        if ($legacy -and -not [Environment]::GetEnvironmentVariable('FARSEER_' + $n)) { [Environment]::SetEnvironmentVariable('FARSEER_' + $n, $legacy) }
    }

    if ($ExecutionContext.SessionState.LanguageMode.value__ -ne 0) {
        Write-Host 'PowerShell is not running in Full Language Mode.'; return
    }
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { Write-Host 'Open PowerShell as administrator and run this again.'; return }
    if (-not $env:FARSEER_ENROLLMENT_KEY -and -not $env:FARSEER_UPDATE) {
        Write-Host 'Set the enrollment key first:  $env:FARSEER_ENROLLMENT_KEY = "THE-KEY"'; return
    }
    if ($env:FARSEER_UPDATE) {
        # An update keeps the PC's registration and needs no key. Refused up front, before
        # anything is removed, if this PC has none for this server.
        $cfgFile = Join-Path $env:ProgramData 'FarSeerAgent\agent.toml'
        # An agent installed before the rename keeps its registration in the old folder until this update moves it.
        $oldCfg = Join-Path $env:ProgramData 'RemAgent\agent.toml'
        if (-not (Test-Path $cfgFile) -and (Test-Path $oldCfg)) { $cfgFile = $oldCfg }
        $saved = if (Test-Path $cfgFile) { Get-Content -LiteralPath $cfgFile -Raw } else { '' }
        # An update keeps the server this PC already reports to, so one shared installer can
        # update PCs registered with any server (unless FARSEER_SERVER names one explicitly).
        if (-not $env:FARSEER_SERVER -and $saved -match '(?m)^\s*server_url\s*=\s*"(p2p://[0-9A-Fa-f]{64}|wss://[A-Za-z0-9._:/-]+)"') { $server = $Matches[1] }
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
            # A neighbour on this site that already has the files (named by the server) is tried first. It is
            # never trusted: every file is checked against the same pinned SHA-256, and any failure, of the
            # connection or the hash, goes back to the normal address for that file and the rest.
            function Get-FromSeed([string] $url, [string] $to) {
                try {
                    $req = [Net.HttpWebRequest]::Create($url)
                    $req.Timeout = 5000; $req.ReadWriteTimeout = 15000
                    $resp = $req.GetResponse()
                    try {
                        $in = $resp.GetResponseStream(); $out = [IO.File]::Create($to)
                        try { $in.CopyTo($out) } finally { $out.Dispose() }
                    } finally { $resp.Close() }
                    return $true
                } catch { return $false }
            }
            $seed = if ($env:FARSEER_SEED -match '^http://\d{1,3}(\.\d{1,3}){3}:\d{4,5}/seed/[0-9A-Fa-f]{16,128}$') { $env:FARSEER_SEED } else { '' }
            foreach ($name in $files.Keys) {
                $path = Join-Path $dir $name
                $got = $false
                if ($seed) {
                    if ((Get-FromSeed "$seed/$name" $path) -and ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -eq $files[$name])) { $got = $true }
                    else { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; $seed = '' }
                }
                if (-not $got) {
                    $web.DownloadFile("$base/$name", $path)
                    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne $files[$name]) {
                        throw "Checksum mismatch for $name; nothing was installed."
                    }
                }
            }

            $ps = Join-Path $PSHOME 'powershell.exe'
            $run = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
            # The two scripts talk a lot; keep what they say for problems, and show only the
            # lines that need attention (a server that can't be reached, an approval to give).
            $quiet = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'

            # An update never removes the working agent first: install.ps1 swaps the program in place and keeps
            # the previous one until the new one has been accepted by the server (the "guard").
            if (-not $env:FARSEER_UPDATE) {
                $un = @($run + (Join-Path $dir 'uninstall.ps1'))
                if (-not $env:FARSEER_FRESH) { $un += '-KeepConfig' }
                $said = (& $ps @un 2>&1 | Out-String)
                if ($LASTEXITCODE) { $ErrorActionPreference = $quiet; throw "Removing the old agent failed (exit $LASTEXITCODE).`r`n$said" }
            }

            $in = @($run + (Join-Path $dir 'install.ps1') + @('-ServerUrl', $server, '-SourceExe', (Join-Path $dir 'farseer-agent.exe'), '-StartNow'))
            if ($env:FARSEER_UPDATE) { $in += '-Update' }
            if ($env:FARSEER_GUARD_MINUTES -match '^\d{1,4}$') { $in += @('-GuardMinutes', $env:FARSEER_GUARD_MINUTES) }
            if (-not $env:FARSEER_NO_ELEVATED) { $in += '-WithElevatedHelper' }
            if ($env:FARSEER_NO_LOCATION) { $in += '-NoLocation' }
            elseif ($env:FARSEER_LATITUDE -and $env:FARSEER_LONGITUDE) { $in += @('-Latitude', $env:FARSEER_LATITUDE, '-Longitude', $env:FARSEER_LONGITUDE) }
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

    # Started from the dashboard's command box? Then farseer-agent.exe is our parent, and the
    # first thing the installer does is stop every farseer-agent: it would kill itself half way
    # and leave the PC with no agent. A one-time SYSTEM task outlives the agent instead.
    function Test-UnderAgent {
        try {
            $id = $PID
            for ($i = 0; $i -lt 12 -and $id; $i++) {
                $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
                if (-not $p) { break }
                if ($p.Name -ieq 'farseer-agent.exe' -or $p.Name -ieq 'rem-agent.exe') { return $true }
                $id = $p.ParentProcessId
            }
        } catch {}
        return $false
    }

    if (-not $env:FARSEER_NO_DETACH -and (Test-UnderAgent)) {
        try {
            $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
            $wd = Join-Path $env:ProgramData 'FarSeerAgentInstall'
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
            foreach ($n in 'FARSEER_SERVER', 'FARSEER_ENROLLMENT_KEY', 'FARSEER_UPDATE', 'FARSEER_GUARD_MINUTES', 'FARSEER_SEED', 'FARSEER_FRESH', 'FARSEER_NO_ELEVATED', 'FARSEER_NO_LOCATION', 'FARSEER_LATITUDE', 'FARSEER_LONGITUDE', 'FARSEER_NAME_PREFIX') {
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
                '  Unregister-ScheduledTask -TaskName ''FarSeerAgentInstall'' -Confirm:$false -ErrorAction SilentlyContinue',
                '  Stop-Transcript | Out-Null',
                '}') -join "`r`n"
            [IO.File]::WriteAllText($runFile, $runText, (New-Object Text.UTF8Encoding($false)))

            $system = (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')).Translate([Security.Principal.NTAccount]).Value
            $act = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $runFile + '"')
            $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)
            $pri = New-ScheduledTaskPrincipal -UserId $system -LogonType ServiceAccount -RunLevel Highest
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
            Register-ScheduledTask -TaskName 'FarSeerAgentInstall' -Action $act -Trigger $trg -Principal $pri -Settings $set -Force | Out-Null
            Start-ScheduledTask -TaskName 'FarSeerAgentInstall'
            Write-Host 'The installer was started in the background, because it replaces the agent that ran this command.'
            Write-Host 'This PC goes offline for a minute or two and then comes back by itself.'
            Write-Host "Progress and any error: $log"
        }
        catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        return
    }

    & $work
}
