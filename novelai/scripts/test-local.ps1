# ComfyUI / Forge Neoの通信形式だけをモックするオフラインチェック。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker.ps1') -Library

function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$testDirectory = Join-Path $script:Runtime ('local-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
$realRuntime = $script:Runtime
$realRoot = $script:Root
try {
    $script:Runtime = $testDirectory
    $script:Root = $testDirectory
    foreach ($file in 'prompts.csv', 'characters.csv', 'actions.csv', 'clothes.csv') { Copy-Item -LiteralPath (Join-Path $script:NovelAiDirectory $file) -Destination (Join-Path $testDirectory $file) }
    $config = Read-Text (Join-Path $script:NovelAiDirectory 'config.json') | ConvertFrom-Json
    $config.backend = 'comfyui'
    $config.api_url = 'http://127.0.0.1:8188'
    $config.model = 'initial.safetensors'
    $config.seed = 123
    $workflowPath = Join-Path $testDirectory 'workflow.json'
    $config.workflow_path = $workflowPath
    Write-Atomic (Join-Path $testDirectory 'config.json') (ConvertTo-Json $config -Depth 15)
    Copy-Item -LiteralPath (Join-Path $script:NovelAiDirectory 'comfyui-workflow.sample') -Destination $workflowPath

    $pngPath = Join-Path $testDirectory 'mock.png'
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap(2, 2)
    try { $bitmap.Save($pngPath, [Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
    $pngBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pngPath))
    $script:PromptCalls = 0
    $script:ViewCalls = 0
    $script:ForgePayload = $null
    function Invoke-WebRequest {
        param([switch]$UseBasicParsing, $Method, $Uri, $MaximumRedirection, $Headers, $ContentType, $Body, $OutFile, $TimeoutSec)
        if ($Uri -eq 'http://127.0.0.1:8188/prompt') {
            $script:PromptCalls++
            $script:ComfyPayload = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            return [pscustomobject]@{ Content = '{"prompt_id":"local-test-prompt"}' }
        }
        if ($Uri -match '/history/local-test-prompt$') {
            return [pscustomobject]@{ Content = '{"local-test-prompt":{"status":{"status_str":"success"},"outputs":{"9":{"images":[{"filename":"mock.png","subfolder":"","type":"output"}]}}}}' }
        }
        if ($Uri -match '/view\?') {
            $script:ViewCalls++
            Copy-Item -LiteralPath $pngPath -Destination $OutFile -Force
            return [pscustomobject]@{ Content = '' }
        }
        if ($Uri -eq 'http://127.0.0.1:7860/sdapi/v1/txt2img') {
            $script:ForgePayload = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            return [pscustomobject]@{ Content = (ConvertTo-Json @{ images = @($pngBase64) }) }
        }
        throw "unexpected mock URI: $Uri"
    }

    Set-Model 'changed.safetensors' $testDirectory
    $workflow = Read-Text $workflowPath | ConvertFrom-Json
    Assert ($workflow.'4'.inputs.ckpt_name -eq 'changed.safetensors') 'ComfyUIモデルノードを書き換える'
    $config = Read-Text (Join-Path $testDirectory 'config.json') | ConvertFrom-Json
    Assert ($config.model -eq 'changed.safetensors') 'モデル設定を保存する'

    $data = Read-PromptData $testDirectory
    $data.Actions['会話する'] = [pscustomobject]@{ scene = 'talking'; actor = ''; target = '' }
    $request = "NAI1`t100-1`nplayer`t0`t0`t主人公`ncharacter`t7`t123`t相手`nmode`t0`t7`t会話する`nEND`t100-1"
    $scene = Read-Scene $request
    $spec = New-Payload $scene $config $testDirectory $data
    $destination = Join-Path $testDirectory 'comfy.png'
    Invoke-ComfyUI $config.api_url $spec $config $destination
    Assert ($script:PromptCalls -eq 1 -and $script:ViewCalls -eq 1 -and (Test-Path $destination)) 'ComfyUIの送信・履歴・画像取得'
    Assert ($script:ComfyPayload.prompt.'6'.inputs.text -match 'talking') 'ComfyUIの正プロンプトを更新'
    Assert ($script:ComfyPayload.prompt.'3'.inputs.seed -eq 123 -and $script:ComfyPayload.prompt.'5'.inputs.width -eq 1024) 'ComfyUIのSeed・解像度を更新'

    $config.backend = 'forge'
    $config.api_url = 'http://127.0.0.1:7860'
    $config.model = 'forge-model.safetensors'
    $forgeSpec = New-Payload $scene $config $testDirectory $data
    $forgeDestination = Join-Path $testDirectory 'forge.png'
    Invoke-Forge $config.api_url $forgeSpec $config $forgeDestination
    $forgeImageOk = (Test-Path $forgeDestination) -and ($script:ForgePayload.prompt -match 'talking')
    Assert $forgeImageOk 'Forge Neoの送信・base64画像取得'
    $forgeOptionsOk = $script:ForgePayload.sampler_name -eq 'Euler a' -and $script:ForgePayload.cfg_scale -eq 5
    Assert $forgeOptionsOk 'Forge NeoへSampler・CFGを変換'
    Write-Host 'PASS: ComfyUI workflow / model cmd / Forge Neo API'
}
finally {
    $script:Runtime = $realRuntime
    $script:Root = $realRoot
    $resolved = [IO.Path]::GetFullPath($testDirectory)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($realRuntime) + [IO.Path]::DirectorySeparatorChar) -and [IO.Path]::GetFileName($resolved) -match "^local-test-[a-f0-9]{32}$") { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
