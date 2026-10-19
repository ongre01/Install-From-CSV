@echo off
setlocal

rem Always run relative to this batch file's folder.
cd /d "%~dp0" || (
    echo [ERROR] Cannot access batch file folder.
    pause
    exit /b 1
)

if not exist "%~dp0Install-From-CSV.ps1" (
    echo [ERROR] Install-From-CSV.ps1 not found next to this batch file.
    pause
    exit /b 1
)

if not exist "%~dp0Install-Plan.csv" (
    echo [ERROR] Install-Plan.csv not found next to this batch file.
    pause
    exit /b 1
)

echo [INFO] Starting WinGet installation from CSV...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-From-CSV.ps1" -Install
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [INFO] Script finished successfully.
) else (
    echo [ERROR] PowerShell script exited with code %RC%.
)
echo.
pause
exit /b %RC%
