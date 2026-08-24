@echo off
REM Double-click this to scan the tailnet for VNC-ready machines.
REM Runs the scanner without needing any execution-policy change.

setlocal
cd /d "%~dp0"

REM Match the script whether or not the filename kept its hyphen - some
REM download paths strip dashes, leaving GetVncTargets.ps1 in place of
REM Get-VncTargets.ps1.
set "PS1="
for /f "delims=" %%F in ('dir /b /a-d "%~dp0*VncTargets.ps1" 2^>nul') do (
    if not defined PS1 set "PS1=%~dp0%%F"
)

if not defined PS1 (
    echo.
    echo   ERROR: could not find the scanner script next to this launcher.
    echo   Expected a file named Get-VncTargets.ps1 in:
    echo     %~dp0
    echo.
    echo   PowerShell files actually present here:
    dir /b /a-d "%~dp0*.ps1" 2>nul
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*

echo.
pause
