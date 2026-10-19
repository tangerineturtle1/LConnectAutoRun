@echo off
if not exist "%~dp0LConnectAutoRun.ps1" (
    echo LConnectAutoRun.ps1 was not found next to this file.
    echo Extract the whole zip to a folder first, then run Diagnose.cmd from there.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LConnectAutoRun.ps1" -Diagnose
