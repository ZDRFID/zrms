@echo off
REM Double-click this to diagnose a single machine that will not connect.
REM Prompts for the machine name, then traces the connection layer by layer.

setlocal
cd /d "%~dp0"

REM Match the script whether or not the filename kept its hyphen.
set "PS1="
for /f "delims=" %%F in ('dir /b /a-d "%~dp0*VncOverTailscale.ps1" 2^>nul') do (
    if not defined PS1 set "PS1=%~dp0%%F"
)

if not defined PS1 (
    echo.
    echo   ERROR: could not find the diagnostic script next to this launcher.
    echo   Expected a file named Test-VncOverTailscale.ps1 in:
    echo     %~dp0
    echo.
    echo   PowerShell files actually present here:
    dir /b /a-d "%~dp0*.ps1" 2>nul
    echo.
    pause
    exit /b 1
)

set "TARGET=%~1"
if "%TARGET%"=="" set /p "TARGET=Machine to test (e.g. mc-hed-t1): "
if "%TARGET%"=="" (
    echo No machine name given.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Target "%TARGET%"

echo.
pause
