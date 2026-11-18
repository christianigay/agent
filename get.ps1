# REM agent one-line installer for p2p://33d076e64d2442c7495866471178e63da8eb1f66ed5cba0cf45eabddbd17db11.
# Removes any installed agent, then registers this PC with the server.
# Needs: an administrator PowerShell and $env:REM_ENROLLMENT_KEY.
& {
    $ErrorActionPreference = 'Stop'
    $base   = 'https://raw.githubusercontent.com/christianigay/agent/v2'
    $server = 'p2p://33d076e64d2442c7495866471178e63da8eb1f66ed5cba0cf45eabddbd17db11'
    $files  = [ordered]@{ 'rem-agent.exe' = '630050300ACE8B3763849830F3A2BA31B644D18CB1049FB8CF10BC280D9161D6'; 'install.ps1' = '633176517166501A8FD702C903DF30317488A6E99662D2BF133450896D6B276C'; 'uninstall.ps1' = '8FCC27B9FC3BE2440CC1E8FA95A2D752DC6139067322E1D21631F2198CEBC060' }

    if ($ExecutionContext.SessionState.LanguageMode.value__ -ne 0) {
        Write-Host 'PowerShell is not running in Full Language Mode.'; return
    }
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { Write-Host 'Open PowerShell as administrator and run this again.'; return }
    if (-not $env:REM_ENROLLMENT_KEY) {
        Write-Host 'Set the enrollment key first:  $env:REM_ENROLLMENT_KEY = "THE-KEY"'; return
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $dir = Join-Path ([IO.Path]::GetTempPath()) ('rem_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
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
        if (-not $env:REM_FRESH) { $un += '-KeepConfig' }
        $said = (& $ps @un 2>&1 | Out-String)
        if ($LASTEXITCODE) { $ErrorActionPreference = $quiet; throw "Removing the old agent failed (exit $LASTEXITCODE).`r`n$said" }

        $in = @($run + (Join-Path $dir 'install.ps1') + @('-ServerUrl', $server, '-SourceExe', (Join-Path $dir 'rem-agent.exe'), '-StartNow'))
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
    finally { Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue }
}
