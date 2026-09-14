param([string]$Backend, [string]$ApiUrl)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker.ps1') -Library

$path = Join-Path $script:NovelAiDirectory 'config.json'
$config = Read-Text $path | ConvertFrom-Json
if (-not $Backend) { $Backend = Read-Host 'backend（novelai / comfyui / forge）' }
$Backend = $Backend.Trim().ToLowerInvariant()
if (-not $ApiUrl -and $Backend -ne 'novelai') { $ApiUrl = Read-Host 'API URL（空欄は既定値）' }
$config | Add-Member -NotePropertyName backend -NotePropertyValue $Backend -Force
if ($Backend -ne 'novelai' -and -not $ApiUrl) { $ApiUrl = if ($Backend -eq 'comfyui') { 'http://127.0.0.1:8188' } else { 'http://127.0.0.1:7860' } }
if ($ApiUrl) { $config | Add-Member -NotePropertyName api_url -NotePropertyValue $ApiUrl.TrimEnd('/') -Force }
Test-Config $config
Write-Atomic $path (ConvertTo-Json $config -Depth 15)
Write-Host ('接続先を変更しました: ' + (Get-Backend $config) + ' / ' + (Get-ApiUrl $config))
