# REM agent one-line installer for p2p://33d076e64d2442c7495866471178e63da8eb1f66ed5cba0cf45eabddbd17db11.
# Removes any installed agent, then registers this PC with the server.
# Needs: an administrator PowerShell and $env:REM_ENROLLMENT_KEY.
& {
    $ErrorActionPreference = 'Stop'
    $base   = 'https://raw.githubusercontent.com/christianigay/agent/v2'
    $server = 'p2p://33d076e64d2442c7495866471178e63da8eb1f66ed5cba0cf45eabddbd17db11'
    $files  = [ordered]@{ 'rem-agent.exe' = '39DF0D4EFB31F5C5EF5EA3A569BCA1A02D662046FD0130FCB7B5969466B5F004'; 'install.ps1' = '633176517166501A8FD702C903DF30317488A6E99662D2BF133450896D6B276C'; 'uninstall.ps1' = '8FCC27B9FC3BE2440CC1E8FA95A2D752DC6139067322E1D21631F2198CEBC060' }

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
        Write-Host 'Downloading the agent...'
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

        Write-Host 'Removing any installed agent...'
        $un = @($run + (Join-Path $dir 'uninstall.ps1'))
        if (-not $env:REM_FRESH) { $un += '-KeepConfig' }
        & $ps @un
        if ($LASTEXITCODE) { throw "uninstall.ps1 failed (exit $LASTEXITCODE)." }

        Write-Host 'Installing...'
        $in = @($run + (Join-Path $dir 'install.ps1') + @('-ServerUrl', $server, '-SourceExe', (Join-Path $dir 'rem-agent.exe'), '-StartNow'))
        if (-not $env:REM_NO_ELEVATED) { $in += '-WithElevatedHelper' }
        if ($env:REM_NO_LOCATION) { $in += '-NoLocation' }
        elseif ($env:REM_LATITUDE -and $env:REM_LONGITUDE) { $in += @('-Latitude', $env:REM_LATITUDE, '-Longitude', $env:REM_LONGITUDE) }
        & $ps @in
        if ($LASTEXITCODE) { throw "install.ps1 failed (exit $LASTEXITCODE)." }
    }
    catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
    finally { Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue }
}
