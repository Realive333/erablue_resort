@echo off
cd /d "%~dp0"
title Set image backend
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\set-backend.ps1" %*
if errorlevel 1 (
    echo.
    echo 接続先変更に失敗しました。上のエラーを確認してください。
)
echo.
pause
