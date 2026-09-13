@echo off
cd /d "%~dp0"
title NovelAI Worker - close this window to stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0worker.ps1"
echo.
echo NovelAI worker stopped. Press any key to close this window.
pause >nul
