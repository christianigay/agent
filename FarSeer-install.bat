@echo off
rem FarSeer fast install. Double-click this file and approve the Windows prompt. Keep it private: it holds the enrollment key.
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$env:FARSEER_SERVER='p2p://092cafb964409829e2d76079ae4eccfe3b5b60f3f9d281312648cf137b111d65'; $env:FARSEER_ENROLLMENT_KEY='neXsrJrUsKZpYxy4MTkd6Ihck67kXX-U'; irm 'https://raw.githubusercontent.com/christianigay/agent/v2/get.ps1' | iex"
pause
