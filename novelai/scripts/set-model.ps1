param([string]$Model)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker.ps1') -Library

if (-not $Model) { $Model = Read-Host "モデル名（Forge Neoはチェックポイント名、ComfyUIはckpt_name）" }
Set-Model $Model $script:NovelAiDirectory
Write-Host ("モデルを変更しました: " + $Model)
