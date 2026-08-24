@echo off
REM Double-click this to scan the tailnet for VNC-ready machines.
REM It runs Get-VncTargets.ps1 without needing any execution-policy change.

setlocal
cd /d "%~dp0"

if not exist "%~dp0Get-VncTargets.ps1" (
    echo.
    echo   ERROR: Get-VncTargets.ps1 was not found next to this launcher.
    echo   Keep both files together in the same folder.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-VncTargets.ps1" %*

echo.
pause
