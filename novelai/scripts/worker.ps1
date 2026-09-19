param([switch]$SetupToken, [switch]$Library)

# Windows PowerShell 5.1 / .NET Framework。外部パッケージ・文章生成APIは不要。
$ErrorActionPreference = 'Stop'
$script:NovelAiDirectory = Split-Path $PSScriptRoot -Parent
$script:Root = Split-Path $script:NovelAiDirectory -Parent
$script:Runtime = Join-Path $script:NovelAiDirectory 'runtime'
$script:Utf8 = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'settings.ps1')

function Read-Text([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return [IO.File]::ReadAllText($Path, $script:Utf8).TrimEnd("`r", "`n")
    }
    return ''
}

function Write-Atomic([string]$Path, [string]$Value) {
    $temporary = $Path + '.tmp'
    [IO.File]::WriteAllText($temporary, $Value, $script:Utf8)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $Path + '.bak'); [IO.File]::Delete($Path + '.bak') }
    else { [IO.File]::Move($temporary, $Path) }
}

function Read-Scene([string]$Text) {
    $lines = @($Text -split '\r?\n')
    if ($lines.Count -lt 3 -or $lines[0] -notmatch '^NAI1\t([0-9]+-[0-9]+)$') { return $null }
    $id = $Matches[1]
    if ($lines[-1] -cne "END`t$id") { return $null } # 書き込み途中は読まない
    $characters = @()
    $clothes = @()
    $action = ''
    $place = ''
    foreach ($line in $lines[1..($lines.Count - 2)]) {
        $fields = @($line -split "`t")
        switch ($fields[0]) {
            { $_ -in 'player', 'character' } {
                if ($fields.Count -ne 4 -or $fields[1] -notmatch '^\d+$' -or $fields[2] -notmatch '^\d+$') { return $null }
                $characters += [pscustomobject]@{ Role = $fields[0]; Index = [int]$fields[1]; No = $fields[2]; Name = $fields[3] }
            }
            'clothes' {
                if ($fields.Count -ne 3 -or $fields[1] -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace($fields[2])) { return $null }
                $clothes += [pscustomobject]@{ Index = [int]$fields[1]; Name = $fields[2] }
            }
            'mode' { continue } # 旧形式の継続行動は画像生成に使わない。
            'action' { if ($fields.Count -ne 2) { return $null }; $action = $fields[1] }
            'place' { if ($fields.Count -ne 3) { return $null }; $place = $line }
            default { return $null }
        }
    }
    if ($characters.Count -lt 1 -or $characters.Count -gt 6 -or $characters[0].Role -ne 'player' -or
        @($characters | Where-Object Role -eq 'player').Count -ne 1 -or
        @($characters.Index | Select-Object -Unique).Count -ne $characters.Count) { return $null }
    foreach ($item in $clothes) { if ($item.Index -notin $characters.Index) { return $null } }
    return [pscustomobject]@{ Id = $id; Characters = $characters; Clothes = $clothes; Action = $action; Place = $place }
}

function Get-Entry($Object, [string]$Key) {
    if ($Object -is [Collections.IDictionary]) { return $Object[$Key] }
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Key]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Join-Tags($Tags) {
    return (@($Tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join ', ')
}

function New-Payload($Scene, $Config, [string]$Directory, $Data = $null) {
    Test-Config $Config
    $backend = Get-Backend $Config
    if ($null -eq $Data) { $Data = Read-PromptData $Directory }
    $characterActions = @{}
    $unknown = @()
    $unknownClothes = @()
    $actionText = ''
    if ($Scene.Action) {
        $entry = Get-Entry $Data.Actions $Scene.Action
        if ($entry -is [string]) { $actionText = $entry }
        elseif ($null -ne $entry) {
            $actionText = [string](Get-Entry $entry 'scene')
            $characterActions[$Scene.Characters[0].Index] = [string](Get-Entry $entry 'actor')
            # ゲームは選択中のTARGETを最初の相手として送る。追加の接触者には付けない。
            if ($Scene.Characters.Count -gt 1) { $characterActions[$Scene.Characters[1].Index] = [string](Get-Entry $entry 'target') }
        }
        else { $unknown += $Scene.Action }
    }
    if (-not $actionText) { $actionText = [string](Get-Entry (Get-Entry $Data.Actions '待機') 'scene') }
    $basePrompt = Join-Tags @($Data.Prompts.system, $actionText)
    $negative = $Data.Prompts.negative
    $captions = @()
    $negativeCaptions = @()
    $characterPrompts = @()
    # APIの先頭2人だけを目標→プレイヤーにする。シーンと画像名のID順は保持。
    $promptCharacters = $Scene.Characters.Clone()
    if ($promptCharacters.Count -gt 1) {
        $promptCharacters[0] = $Scene.Characters[1]
        $promptCharacters[1] = $Scene.Characters[0]
    }
    foreach ($character in $promptCharacters) {
        $description = Get-Entry $Data.Characters $character.No
        if ([string]::IsNullOrWhiteSpace($description)) { $description = $character.Name }
        $clothing = @($Scene.Clothes | Where-Object Index -eq $character.Index | ForEach-Object {
            if ($_.Name -eq '普段着') {
                $tag = Get-Entry $Data.DefaultOutfits $character.No
                if ([string]::IsNullOrWhiteSpace($tag)) { $unknownClothes += ('普段着（NO={0}, characters.csv:default_outfit）' -f $character.No) }
            } else {
                $tag = Get-Entry $Data.Clothes $_.Name
                if ([string]::IsNullOrWhiteSpace($tag)) { $unknownClothes += $_.Name }
            }
            [pscustomobject]@{ Name = $_.Name; Prompt = [string]$tag }
        })
        $caption = Join-Tags (@($description) + @($clothing.Prompt) + @($characterActions[$character.Index]))
        $centers = @([ordered]@{ x = 0.5; y = 0.5 })
        $captions += [ordered]@{ char_caption = $caption; centers = $centers }
        $negativeCaptions += [ordered]@{ char_caption = ''; centers = $centers }
        $characterPrompts += [pscustomobject]@{ No = $character.No; Name = $character.Name; Role = $character.Role; Clothes = $clothing; Prompt = $caption }
    }
    # V5は公式クライアントと同じversion 4 / Karrasで送る。
    $isV5 = $backend -eq 'novelai' -and $Config.model -match '^nai-diffusion-5(?:-|$)'
    $parameters = [ordered]@{
        params_version = $(if ($isV5) { 4 } else { 3 }); width = [int]$Config.width; height = [int]$Config.height
        steps = [int]$Config.steps; scale = [double]$Config.scale; sampler = $Config.sampler
        seed = [long]$Config.seed; n_samples = 1; negative_prompt = $negative
        noise_schedule = $(if ($isV5 -or -not $Config.noise_schedule) { 'karras' } else { $Config.noise_schedule })
        cfg_rescale = [double]$Config.cfg_rescale; ucPreset = 0; qualityToggle = $false
    }
    $format = if ($backend -eq 'novelai') { Get-PromptFormat $Config } else { 'legacy' }
    $flatPrompt = Join-Tags (@($basePrompt) + @($captions | ForEach-Object { $_.char_caption }))
    if ($format -eq 'v4') {
        $parameters.v4_prompt = [ordered]@{ caption = [ordered]@{ base_caption = $basePrompt; char_captions = $captions }; use_coords = $false; use_order = $true }
        $parameters.v4_negative_prompt = [ordered]@{ caption = [ordered]@{ base_caption = $negative; char_captions = $negativeCaptions }; legacy_uc = $false }
    }
    $payload = if ($backend -eq 'novelai') {
        [ordered]@{ input = $(if ($format -eq 'v4') { $basePrompt } else { $flatPrompt }); model = $Config.model; action = 'generate'; parameters = $parameters }
    } else {
        [ordered]@{ prompt = $flatPrompt; negative_prompt = [string]$negative; model = $Config.model; width = [int]$Config.width; height = [int]$Config.height
            steps = [int]$Config.steps; scale = [double]$Config.scale; sampler = [string]$Config.sampler; seed = [long]$Config.seed }
    }
    $json = ConvertTo-Json $payload -Depth 15 -Compress
    if ($json.Length -gt 24000) { throw 'プロンプトが長すぎます。短いタグに整理してください。' }
    return [pscustomobject]@{ Payload = $payload; Prompt = $flatPrompt; NegativePrompt = [string]$negative
        BasePrompt = $basePrompt; CharacterPrompts = $characterPrompts
        CharacterNos = @($promptCharacters.No); UnknownActions = @($unknown | Select-Object -Unique)
        UnknownClothes = @($unknownClothes | Select-Object -Unique) }
}

function Get-ImageName($Scene) {
    $label = $Scene.Action
    if (-not $label) { $label = '待機' }
    $parts = foreach ($character in $Scene.Characters) {
        $clothes = @($Scene.Clothes | Where-Object Index -eq $character.Index | Select-Object -ExpandProperty Name -Unique) -join '+'
        if (-not $clothes) { $clothes = '普段着' }
        '{0}_{1}' -f $character.No, $clothes
    }
    # 操作キャラを先頭に、服装と脱衣状態もキャッシュの識別に含める。
    $name = (($parts -join '_') + '_' + $label) -replace '[<>:"/\\|?*\x00-\x1f]', '_'
    $name += '.png'
    if ($name.Length -gt 180) { throw 'キャラID・服装・行動の画像名が長すぎます（180文字まで）。' }
    return $name
}

function Save-PngBytes([byte[]]$Bytes, [string]$Destination) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0 -or $Bytes.Length -gt 20971520) { throw 'API応答に有効な画像がありません。' }
    Add-Type -AssemblyName System.Drawing
    $memory = New-Object IO.MemoryStream(, $Bytes)
    try {
        $image = [Drawing.Image]::FromStream($memory)
        try {
            if ($image.Width -gt 2048 -or $image.Height -gt 2048) { throw 'API画像のサイズが不正です。' }
            $image.Save($Destination + '.tmp', [Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $image.Dispose() }
    }
    finally { $memory.Dispose() }
    if ([IO.File]::Exists($Destination)) {
        [IO.File]::Replace($Destination + '.tmp', $Destination, $Destination + '.bak')
        [IO.File]::Delete($Destination + '.bak')
    } else { [IO.File]::Move($Destination + '.tmp', $Destination) }
}

function Save-ImageFile([string]$Source, [string]$Destination) {
    Save-PngBytes ([IO.File]::ReadAllBytes($Source)) $Destination
}

function Save-GeneratedImage([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entry = $zip.Entries | Where-Object { $_.Name.EndsWith('.png', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($null -eq $entry -or $entry.Length -gt 20971520) { throw 'API応答に有効なPNGがありません。' }
        $inputStream = $entry.Open()
        $memory = New-Object IO.MemoryStream
        try { $inputStream.CopyTo($memory); Save-PngBytes $memory.ToArray() $Destination }
        finally { $inputStream.Dispose(); $memory.Dispose() }
    }
    finally { $zip.Dispose() }
}

function Invoke-JsonPost([string]$Uri, $Object, [int]$TimeoutSec = 120) {
    $body = $script:Utf8.GetBytes((ConvertTo-Json $Object -Depth 100 -Compress))
    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Uri -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
    return [string]$response.Content
}

function Get-LocalSampler([string]$Sampler) {
    switch ($Sampler) {
        'k_euler_ancestral' { return 'Euler a' }
        'k_euler' { return 'Euler' }
        'k_dpmpp_2m' { return 'DPM++ 2M' }
        'k_dpmpp_sde' { return 'DPM++ 2M SDE' }
        'k_dpmpp_2s_ancestral' { return 'DPM++ 2S a' }
        'ddim_v3' { return 'DDIM' }
        default { return $Sampler }
    }
}

function Get-ComfySampler([string]$Sampler) {
    switch ($Sampler) {
        'k_euler_ancestral' { return 'euler_ancestral' }
        'k_euler' { return 'euler' }
        'k_dpmpp_2m' { return 'dpmpp_2m' }
        'k_dpmpp_sde' { return 'dpmpp_sde' }
        'k_dpmpp_2s_ancestral' { return 'dpmpp_2s_ancestral' }
        'ddim_v3' { return 'ddim' }
        default { return $Sampler }
    }
}

function Invoke-Forge([string]$BaseUrl, $Spec, $Config, [string]$Destination) {
    $payload = [ordered]@{
        prompt = $Spec.Prompt; negative_prompt = $Spec.NegativePrompt; steps = [int]$Config.steps
        cfg_scale = [double]$Config.scale; sampler_name = Get-LocalSampler $Config.sampler
        width = [int]$Config.width; height = [int]$Config.height; seed = [long]$Spec.Payload.seed
        batch_size = 1; n_iter = 1; send_images = $true; save_images = $false
    }
    $result = Invoke-JsonPost ($BaseUrl + '/sdapi/v1/txt2img') $payload 120 | ConvertFrom-Json
    $encoded = [string](@(Get-Entry $result 'images')[0])
    if (-not $encoded) { throw 'Forge API応答に画像がありません。' }
    $encoded = $encoded -replace '^data:image/[^;]+;base64,', ''
    Save-PngBytes ([Convert]::FromBase64String($encoded)) $Destination
}

function Get-ComfyWorkflowPath($Config) {
    $path = [string](Get-Entry $Config 'workflow_path')
    if (-not $path) { $path = 'comfyui-workflow.json' }
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $script:NovelAiDirectory $path }
    return $path
}

function Set-WorkflowInput($Workflow, [string]$NodeId, [string]$Name, $Value) {
    $node = Get-Entry $Workflow $NodeId
    $inputs = if ($null -ne $node) { Get-Entry $node 'inputs' }
    if ($null -eq $inputs -or $null -eq $inputs.PSObject.Properties[$Name]) { throw "ComfyUI workflowのノード $NodeId に入力 $Name がありません。" }
    $inputs.$Name = $Value
}

function Get-ComfyImage($History, [string]$PromptId) {
    $entry = Get-Entry $History $PromptId
    if ($null -eq $entry) { return $null }
    $outputs = Get-Entry $entry 'outputs'
    foreach ($output in @($outputs.PSObject.Properties | ForEach-Object Value)) {
        foreach ($image in @(Get-Entry $output 'images')) {
            if (Get-Entry $image 'filename') { return $image }
        }
    }
    $status = Get-Entry $entry 'status'
    if ((Get-Entry $status 'status_str') -eq 'error') { throw 'ComfyUI workflowの実行に失敗しました。' }
    return $null
}

function Invoke-ComfyUI([string]$BaseUrl, $Spec, $Config, [string]$Destination) {
    $workflowPath = Get-ComfyWorkflowPath $Config
    if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) { throw "ComfyUI workflowがありません: $workflowPath" }
    $workflow = Read-Text $workflowPath | ConvertFrom-Json
    Set-WorkflowInput $workflow ([string](Get-Entry $Config 'comfyui_prompt_node')) 'text' $Spec.Prompt
    Set-WorkflowInput $workflow ([string](Get-Entry $Config 'comfyui_negative_node')) 'text' $Spec.NegativePrompt
    Set-WorkflowInput $workflow ([string](Get-Entry $Config 'comfyui_sampler_node')) 'seed' ([long]$Spec.Payload.seed)
    Set-WorkflowInput $workflow ([string](Get-Entry $Config 'comfyui_sampler_node')) 'steps' ([int]$Config.steps)
    Set-WorkflowInput $workflow ([string](Get-Entry $Config 'comfyui_sampler_node')) 'cfg' ([double]$Config.scale)
    Set-WorkflowInput $workflow ([string](Get-Entry $Config 'comfyui_sampler_node')) 'sampler_name' (Get-ComfySampler $Config.sampler)
    Set-WorkflowInput $workflow ([string](Get-Entry $Config 'comfyui_sampler_node')) 'scheduler' $(if ($Config.noise_schedule -eq 'karras') { 'karras' } else { 'normal' })
    Set-WorkflowInput $workflow ([string](Get-Entry $Config 'comfyui_latent_node')) 'width' ([int]$Config.width)
    Set-WorkflowInput $workflow ([string](Get-Entry $Config 'comfyui_latent_node')) 'height' ([int]$Config.height)
    $reply = Invoke-JsonPost ($BaseUrl + '/prompt') ([ordered]@{ prompt = $workflow }) 120 | ConvertFrom-Json
    $promptId = [string](Get-Entry $reply 'prompt_id')
    if (-not $promptId) { throw 'ComfyUI APIがprompt_idを返しませんでした。workflowを確認してください。' }
    $timeout = [int](Get-Entry $Config 'api_timeout_seconds')
    if ($timeout -lt 30) { $timeout = 600 }
    $deadline = [datetime]::UtcNow.AddSeconds($timeout)
    $download = Join-Path $script:Runtime 'comfyui-output'
    try {
        do {
            $historyResponse = Invoke-WebRequest -UseBasicParsing -Method Get -Uri ($BaseUrl + '/history/' + [Uri]::EscapeDataString($promptId)) -TimeoutSec 30
            $image = Get-ComfyImage ($historyResponse.Content | ConvertFrom-Json) $promptId
            if ($null -ne $image) {
                $query = '?filename=' + [Uri]::EscapeDataString([string](Get-Entry $image 'filename'))
                $subfolder = [string](Get-Entry $image 'subfolder')
                $type = [string](Get-Entry $image 'type')
                if ($subfolder) { $query += '&subfolder=' + [Uri]::EscapeDataString($subfolder) }
                if ($type) { $query += '&type=' + [Uri]::EscapeDataString($type) }
                Invoke-WebRequest -UseBasicParsing -Method Get -Uri ($BaseUrl + '/view' + $query) -OutFile $download -TimeoutSec 120 | Out-Null
                Save-ImageFile $download $Destination
                return
            }
            Start-Sleep -Milliseconds 500
        } while ([datetime]::UtcNow -lt $deadline)
    }
    finally { if (Test-Path -LiteralPath $download) { [IO.File]::Delete($download) } }
    throw "ComfyUIの生成がタイムアウトしました（${timeout}秒）。"
}

function Invoke-ImageGeneration($Spec, $Config, [string]$Destination, [string]$Token) {
    $backend = Get-Backend $Config
    if ($backend -eq 'novelai') {
        $archive = Join-Path $script:Runtime 'download.zip'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $body = $script:Utf8.GetBytes((ConvertTo-Json $Spec.Payload -Depth 15 -Compress))
            Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://image.novelai.net/ai/generate-image' -MaximumRedirection 0 `
                -Headers @{ Authorization = 'Bearer ' + $Token; Accept = 'application/zip' } `
                -ContentType 'application/json' -Body $body -OutFile $archive -TimeoutSec 120 | Out-Null
            Save-GeneratedImage $archive $Destination
        }
        finally { if (Test-Path -LiteralPath $archive) { [IO.File]::Delete($archive) } }
        return
    }
    $baseUrl = Get-ApiUrl $Config
    if ($backend -eq 'forge') { Invoke-Forge $baseUrl $Spec $Config $Destination; return }
    Invoke-ComfyUI $baseUrl $Spec $Config $Destination
}

function Set-Model([string]$Model, [string]$Directory = $script:NovelAiDirectory) {
    $Model = $Model.Trim()
    if (-not $Model) { throw 'モデル名が空です。' }
    $path = Join-Path $Directory 'config.json'
    $config = Read-Text $path | ConvertFrom-Json
    $config | Add-Member -NotePropertyName model -NotePropertyValue $Model -Force
    Test-Config $config
    $backend = Get-Backend $config
    if ($backend -eq 'forge') {
        Invoke-JsonPost ((Get-ApiUrl $config) + '/sdapi/v1/options') ([ordered]@{ sd_model_checkpoint = $Model }) 120 | Out-Null
    } elseif ($backend -eq 'comfyui') {
        $workflowPath = Get-ComfyWorkflowPath $config
        if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) { throw "ComfyUI workflowがありません: $workflowPath" }
        $workflow = Read-Text $workflowPath | ConvertFrom-Json
        $nodeId = [string](Get-Entry $config 'comfyui_model_node')
        $node = Get-Entry $workflow $nodeId
        $inputs = if ($null -ne $node) { Get-Entry $node 'inputs' }
        $modelKey = @('ckpt_name', 'unet_name', 'model_name') | Where-Object { $null -ne $inputs -and $null -ne $inputs.PSObject.Properties[$_] } | Select-Object -First 1
        if (-not $modelKey) { throw "ComfyUI workflowのノード $nodeId にモデル入力がありません。" }
        Set-WorkflowInput $workflow $nodeId $modelKey $Model
        Write-Atomic $workflowPath (ConvertTo-Json $workflow -Depth 100)
    }
    Write-Atomic $path (ConvertTo-Json $config -Depth 15)
}

function Publish-Image($Scene, [string]$ImageName) {
    $latest = Read-Scene (Read-Text (Join-Path $script:Runtime 'request.txt'))
    if ($null -ne $latest -and $latest.Id -eq $Scene.Id -and (Read-Text (Join-Path $script:Runtime 'enabled.txt')) -eq '1') {
        $path = Join-Path $script:Runtime 'response.txt'
        $response = "{0}`n{1}" -f $Scene.Id, $ImageName
        if ((Read-Text $path) -ne $response) { Write-Atomic $path $response }
    }
}

function Write-Log([string]$Text) {
    Write-Host ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), ($Text -replace '[\r\n\t]', ' '))
}

function Write-PromptLog($Spec) {
    Write-Log '送信プロンプト（全体・キャラ別）'
    $lines = @('  全体プロンプト: ' + $Spec.BasePrompt)
    for ($i = 0; $i -lt $Spec.CharacterPrompts.Count; $i++) {
        $character = $Spec.CharacterPrompts[$i]
        $role = if ($character.Role -eq 'player') { '操作キャラ' } else { '相手キャラ' }
        $lines += ''
        $lines += '  キャラ{0}: {1}（NO={2} / {3}）' -f ($i + 1), $character.Name, $character.No, $role
        if (-not $character.Clothes.Count) { $lines += '    服装: ゲームから未受信（ゲームを再起動して確認してください）' }
        foreach ($clothing in $character.Clothes) {
            $tag = if (-not [string]::IsNullOrWhiteSpace($clothing.Prompt)) { $clothing.Prompt }
                elseif ($clothing.Name -eq '普段着') { '未設定（characters.csv の default_outfit、追加なし）' }
                else { '未登録または空欄（追加なし）' }
            $lines += '    服装 [{0}]: {1}' -f $clothing.Name, $tag
        }
        $lines += '    プロンプト: ' + $character.Prompt
    }
    foreach ($line in $lines) { Write-Host ($line -replace '[\r\n\t]', ' ') }
    Write-Host ''
}

function Set-Status([string]$Text) {
    $path = Join-Path $script:Runtime 'status.txt'
    if ((Read-Text $path) -ne $Text) { Write-Atomic $path $Text; Write-Log $Text }
}

function Invoke-Worker {
    param([switch]$Once, [string]$Directory = $script:NovelAiDirectory)
    $cache = Join-Path $script:Root 'resources/NovelAI'
    $attempts = Join-Path $script:Runtime 'attempts'
    [void][IO.Directory]::CreateDirectory($cache)
    [void][IO.Directory]::CreateDirectory($attempts)
    # ponytail: 1ゲーム・1ワーカー。複数同時起動が必要になったらゲームごとに通信先を分ける。
    $workerLock = [IO.File]::Open((Join-Path $script:Runtime 'worker.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $stopFile = Join-Path $script:Runtime 'stop.txt'
    if (Test-Path -LiteralPath $stopFile) { [IO.File]::Delete($stopFile) }
    $count = 0
    $lastRequest = [datetime]::MinValue
    $lastSceneKey = ''
    try {
        Write-Log '画像生成ワーカー起動。このウィンドウを閉じると停止します。stop.cmdでも停止できます。'
        Set-Status '待機中。一枚絵タブで場面が変わると生成します。'
        do {
            try {
                Sync-Settings $Directory
                if ((Read-Text (Join-Path $script:Runtime 'enabled.txt')) -ne '1') { Set-Status '自動生成は無効です。'; continue }
                $scene = Read-Scene (Read-Text (Join-Path $script:Runtime 'request.txt'))
                if ($null -eq $scene) { Set-Status 'ゲームからの要求を待っています。'; continue }
                if ($scene.Characters.Count -lt 2) { Set-Status '接触相手がいません。'; continue }
                $config = (Read-Text (Join-Path $Directory 'config.json')) | ConvertFrom-Json
                $imageName = Get-ImageName $scene
                $sceneKey = $scene.Id + ':' + $imageName
                $sceneChanged = $sceneKey -ne $lastSceneKey
                if ($sceneChanged) {
                    $actionName = if ($scene.Action) { $scene.Action } else { '待機' }
                    Write-Log ('要求 {0} | モデル: {1} | 動作: {2}' -f $scene.Id, $config.model, $actionName)
                    Write-Log ('画像名: ' + $imageName)
                    $lastSceneKey = $sceneKey
                }
                $imagePath = Join-Path $cache $imageName
                $cachedName = if (Test-Path -LiteralPath $imagePath) { $imageName } else { '' }
                $regen = @((Read-Text (Join-Path $script:Runtime 'regenerate.txt')) -split '\r?\n')
                $regenResultPath = Join-Path $script:Runtime 'regenerate-result.txt'
                $regenResult = @((Read-Text $regenResultPath) -split '\r?\n')
                $regenToken = ''
                if ($regen.Count -eq 4 -and $regen[0] -eq 'NAIREGEN1' -and $regen[1] -eq $scene.Id -and
                    $regen[2] -match '^\d+-\d+$' -and $regen[3] -ceq ("END`t" + $regen[2])) { $regenToken = $regen[2] }
                $handled = $regenToken -and $regenResult.Count -eq 3 -and $regenResult[0] -eq $regenToken
                $sameRegeneration = $handled -and $regenResult[1] -ceq $imageName
                $force = $regenToken -and -not $handled
                if ($cachedName) {
                    Publish-Image $scene $cachedName
                    if ($sceneChanged) { Write-Log ('画像再利用（API送信なし）: ' + $cachedName) }
                }
                if (-not $force -and ($cachedName -or $sameRegeneration)) {
                    if ($sameRegeneration) { Set-Status $regenResult[2] }
                    else { Set-Status '保存済み画像を再利用しています。' }
                    continue
                }
                $attemptName = if ($force) { 'regenerate-' + $regenToken + '.txt' } else { $imageName + '.txt' }
                $attemptPath = Join-Path $attempts $attemptName
                if (Test-Path -LiteralPath $attemptPath) { Set-Status (Read-Text $attemptPath); continue }
                if (([datetime]::UtcNow - $lastRequest).TotalSeconds -lt $config.minimum_interval_seconds) { Set-Status '生成間隔の待機中です（最新の場面だけを処理）。'; continue }
                $spec = New-Payload $scene $config $Directory
                if ($spec.UnknownActions.Count) { Write-Log ('未登録の行動タグ: ' + ($spec.UnknownActions -join ', ')) }
                if ($spec.UnknownClothes.Count) { Write-Log ('未設定の服装タグ: ' + ($spec.UnknownClothes -join ', ')) }
                $backend = Get-Backend $config
                $token = ''
                if ($backend -eq 'novelai') {
                    $token = $env:NOVELAI_API_TOKEN
                    $tokenPath = Join-Path $script:Runtime 'token.dpapi'
                    if (-not $token -and (Test-Path -LiteralPath $tokenPath)) {
                        $secure = (Read-Text $tokenPath) | ConvertTo-SecureString
                        $token = (New-Object Net.NetworkCredential('', $secure)).Password
                    }
                    if (-not $token) { Set-Status 'APIキー未設定。novelai/setup-token.cmdを実行してください。'; continue }
                }
                $latest = Read-Scene (Read-Text (Join-Path $script:Runtime 'request.txt'))
                if ($null -eq $latest -or $latest.Id -ne $scene.Id -or (Read-Text (Join-Path $script:Runtime 'enabled.txt')) -ne '1') { continue }
                # 送信前に永続記録。タイムアウト・中断後も同じ課金要求を自動で再送しない。
                Write-Atomic $attemptPath '前回の送信結果が未確認です。必要なら設定画面の「再試行」を選択してください。'
                if ($force) { Write-Atomic $regenResultPath ($regenToken + "`n" + $imageName + "`n再生成の送信結果が未確認です。必要なら再生成ボタンを押してください。") }
                Write-Atomic (Join-Path $script:Runtime 'unmapped-actions.txt') ($spec.UnknownActions -join "`n")
                Write-Atomic (Join-Path $script:Runtime 'unmapped-clothes.txt') ($spec.UnknownClothes -join "`n")
                $seed = if ($backend -eq 'novelai') { [long]$spec.Payload.parameters.seed } else { [long]$spec.Payload.seed }
                if ($force -or $seed -eq -1) {
                    $seed = Get-Random -Minimum 0 -Maximum 2147483647
                    if ($backend -eq 'novelai') { $spec.Payload.parameters.seed = $seed } else { $spec.Payload.seed = $seed }
                }
                Write-Atomic (Join-Path $script:Runtime 'preview.json') (ConvertTo-Json $spec.Payload -Depth 100)
                $lastRequest = [datetime]::UtcNow
                $count++
                Set-Status ("生成中（今回{0}回目、{1}）。画像タブで自動表示します。" -f $count, $backend)
                Write-Log ('API送信 | {0} | {1}x{2} | steps={3} | seed={4}' -f $backend, $config.width, $config.height, $config.steps, $seed)
                Write-PromptLog $spec
                try {
                    Invoke-ImageGeneration $spec $config $imagePath $token
                    Write-Log ('画像保存: ' + $imagePath)
                    Write-Atomic $attemptPath '生成完了。'
                    if ($force) { Write-Atomic $regenResultPath ($regenToken + "`n" + $imageName + "`n再生成完了。NovelAIタブへ自動反映します。") }
                    Publish-Image $scene $imageName
                    Set-Status '生成完了。NovelAIタブへ自動反映します。'
                }
                catch {
                    $code = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    $errorMessage = [string]$_.Exception.Message
                    if ($token) { $errorMessage = $errorMessage.Replace($token, '[redacted]') }
                    Write-Log ('APIエラー: ' + $errorMessage)
                    if ($_.ErrorDetails.Message) {
                        $detail = [string]$_.ErrorDetails.Message
                        if ($token) { $detail = $detail.Replace($token, '[redacted]') }
                        Write-Log ('API応答: ' + $detail)
                    }
                    $message = "画像生成に失敗しました（HTTP $code、0は通信・画像読込エラー）。自動再送はしません。設定を確認して「再試行」を選択してください。"
                    if ($force) {
                        $message = "再生成に失敗しました（HTTP $code）。以前の画像は保持します。再生成ボタンでやり直せます。"
                        Write-Atomic $regenResultPath ($regenToken + "`n" + $imageName + "`n" + $message)
                    }
                    Write-Atomic $attemptPath $message
                    Set-Status $message
                }
                finally { $token = $null }
            }
            catch [IO.IOException] { Write-Log ('ファイル読込・保存の再試行待ち: ' + $_.Exception.Message) }
            catch { Set-Status ('設定エラー: ' + $_.Exception.Message) }
            finally { if (-not $Once) { Start-Sleep -Milliseconds 1000 } }
        } while (-not $Once -and -not (Test-Path -LiteralPath $stopFile))
    }
    finally { $workerLock.Dispose(); if (-not $Once) { Set-Status 'ワーカーは停止しています。start.cmdで再開できます。' } }
}

if ($Library) { return }
[void][IO.Directory]::CreateDirectory($script:Runtime)
if ($SetupToken) {
    $secureToken = Read-Host 'NovelAIのPersistent API token（非表示）' -AsSecureString
    if ($secureToken.Length -eq 0) { throw 'トークンが空です。' }
    Write-Atomic (Join-Path $script:Runtime 'token.dpapi') (ConvertFrom-SecureString $secureToken)
    Write-Host 'Windowsユーザー固有の暗号化で保存しました。start.cmdで起動してください。'
}
else { Invoke-Worker }
