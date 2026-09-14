@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\worker.ps1" -SetupToken
pause
