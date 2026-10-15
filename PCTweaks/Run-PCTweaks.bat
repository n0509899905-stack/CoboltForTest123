@echo off
setlocal
rem Self-elevating launcher for PCTweaks.ps1. Extra arguments are passed through,
rem e.g.  Run-PCTweaks.bat -Recommended -Maintenance

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    set "PCT_ARGS=%*"
    if defined PCT_ARGS (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    ) else (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    )
    exit /b
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCTweaks.ps1" %*
set "PCT_EXIT=%errorlevel%"
if not "%~1"=="" pause
exit /b %PCT_EXIT%
