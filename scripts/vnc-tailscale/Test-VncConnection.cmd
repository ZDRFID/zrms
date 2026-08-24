@echo off
REM Double-click this to diagnose a single machine that will not connect.
REM Prompts for the machine name, then runs Test-VncOverTailscale.ps1.

setlocal
cd /d "%~dp0"

if not exist "%~dp0Test-VncOverTailscale.ps1" (
    echo.
    echo   ERROR: Test-VncOverTailscale.ps1 was not found next to this launcher.
    echo   Keep both files together in the same folder.
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

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-VncOverTailscale.ps1" -Target "%TARGET%"

echo.
pause
