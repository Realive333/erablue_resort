@echo off
cd /d "%~dp0"
title NovelAI Text Worker
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0worker.ps1"
echo.
echo Text worker stopped. Press any key to close this window.
pause >nul
