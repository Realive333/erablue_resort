@echo off
cd /d "%~dp0"
title Image Worker - close this window to stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\worker.ps1"
echo.
echo Image worker stopped. Press any key to close this window.
pause >nul
