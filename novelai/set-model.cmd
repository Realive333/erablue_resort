@echo off
cd /d "%~dp0"
title Set local image model
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\set-model.ps1" %*
if errorlevel 1 (
    echo.
    echo モデル変更に失敗しました。上のエラーを確認してください。
)
echo.
pause
