param([switch]$SetupToken, [switch]$Library)

# Windows PowerShell 5.1 / .NET Framework。外部パッケージ・文章生成APIは不要。
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path $PSScriptRoot -Parent
$script:Runtime = Join-Path $PSScriptRoot 'runtime'
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
    $modes = @()
    $action = ''
    $place = ''
    foreach ($line in $lines[1..($lines.Count - 2)]) {
        $fields = @($line -split "`t")
        switch ($fields[0]) {
            { $_ -in 'player', 'character' } {
                if ($fields.Count -ne 4 -or $fields[1] -notmatch '^\d+$' -or $fields[2] -notmatch '^\d+$') { return $null }
                $characters += [pscustomobject]@{ Role = $fields[0]; Index = [int]$fields[1]; No = $fields[2]; Name = $fields[3] }
            }
            'mode' {
                if ($fields.Count -ne 4 -or $fields[1] -notmatch '^\d+$' -or $fields[2] -notmatch '^\d+$') { return $null }
                $modes += [pscustomobject]@{ Actor = [int]$fields[1]; Target = [int]$fields[2]; Name = $fields[3] }
            }
            'action' { if ($fields.Count -ne 2) { return $null }; $action = $fields[1] }
            'place' { if ($fields.Count -ne 3) { return $null }; $place = $line }
            default { return $null }
        }
    }
    if ($characters.Count -lt 1 -or $characters.Count -gt 6 -or $characters[0].Role -ne 'player' -or
        @($characters | Where-Object Role -eq 'player').Count -ne 1 -or
        @($characters.Index | Select-Object -Unique).Count -ne $characters.Count) { return $null }
    foreach ($mode in $modes) {
        if ($mode.Actor -notin $characters.Index -or $mode.Target -notin $characters.Index -or
            ($mode.Actor -ne $characters[0].Index -and $mode.Target -ne $characters[0].Index)) { return $null }
    }
    return [pscustomobject]@{ Id = $id; Characters = $characters; Modes = $modes; Action = $action; Place = $place }
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
    if ($null -eq $Data) { $Data = Read-PromptData $Directory }
    $actions = @()
    $characterActions = @{}
    $unknown = @()
    $modeList = @($Scene.Modes | Sort-Object Actor, Target, Name)
    if ($modeList.Count -eq 0 -and $Scene.Action) { $modeList = @([pscustomobject]@{ Name = $Scene.Action; Actor = $Scene.Characters[0].Index; Target = $Scene.Characters[-1].Index }) }
    foreach ($mode in $modeList) {
        $entry = Get-Entry $Data.Actions $mode.Name
        if ($entry -is [string]) { $actions += $entry }
        elseif ($null -ne $entry) {
            $actions += [string](Get-Entry $entry 'scene')
            foreach ($role in 'actor', 'target') {
                $index = if ($role -eq 'actor') { $mode.Actor } else { $mode.Target }
                $characterActions[$index] = @($characterActions[$index]) + [string](Get-Entry $entry $role)
            }
        }
        else { $unknown += $mode.Name }
    }
    $actionText = Join-Tags $actions
    if (-not $actionText) { $actionText = [string](Get-Entry (Get-Entry $Data.Actions '待機') 'scene') }
    $basePrompt = Join-Tags @($Data.Prompts.system, $actionText)
    $negative = $Data.Prompts.negative
    $captions = @()
    $negativeCaptions = @()
    # APIの先頭2人だけを目標→プレイヤーにする。シーンと画像名のID順は保持。
    $promptCharacters = $Scene.Characters.Clone()
    if ($promptCharacters.Count -gt 1) {
        $promptCharacters[0] = $Scene.Characters[1]
        $promptCharacters[1] = $Scene.Characters[0]
    }
    foreach ($character in $promptCharacters) {
        $description = Get-Entry $Data.Characters $character.No
        if ([string]::IsNullOrWhiteSpace($description)) { $description = $character.Name }
        $caption = Join-Tags (@($description) + @($characterActions[$character.Index]))
        $centers = @([ordered]@{ x = 0.5; y = 0.5 })
        $captions += [ordered]@{ char_caption = $caption; centers = $centers }
        $negativeCaptions += [ordered]@{ char_caption = ''; centers = $centers }
    }
    # V5は公式クライアントと同じversion 4 / Karrasで送る。
    $isV5 = $Config.model -match '^nai-diffusion-5(?:-|$)'
    $parameters = [ordered]@{
        params_version = $(if ($isV5) { 4 } else { 3 }); width = [int]$Config.width; height = [int]$Config.height
        steps = [int]$Config.steps; scale = [double]$Config.scale; sampler = $Config.sampler
        seed = [long]$Config.seed; n_samples = 1; negative_prompt = $negative
        noise_schedule = $(if ($isV5 -or -not $Config.noise_schedule) { 'karras' } else { $Config.noise_schedule })
        cfg_rescale = [double]$Config.cfg_rescale; ucPreset = 0; qualityToggle = $false
    }
    if ((Get-PromptFormat $Config) -eq 'v4') {
        $parameters.v4_prompt = [ordered]@{ caption = [ordered]@{ base_caption = $basePrompt; char_captions = $captions }; use_coords = $false; use_order = $true }
        $parameters.v4_negative_prompt = [ordered]@{ caption = [ordered]@{ base_caption = $negative; char_captions = $negativeCaptions }; legacy_uc = $false }
    }
    else { $basePrompt = Join-Tags (@($basePrompt) + @($captions | ForEach-Object { $_.char_caption })) }
    $payload = [ordered]@{ input = $basePrompt; model = $Config.model; action = 'generate'; parameters = $parameters }
    $json = ConvertTo-Json $payload -Depth 15 -Compress
    if ($json.Length -gt 24000) { throw 'プロンプトが長すぎます。短いタグに整理してください。' }
    return [pscustomobject]@{ Payload = $payload; CharacterNos = @($promptCharacters.No); UnknownActions = @($unknown | Select-Object -Unique) }
}

function Get-ImageName($Scene) {
    $label = if ($Scene.Modes.Count) { ($Scene.Modes.Name | Sort-Object -Unique) -join '+' } else { $Scene.Action }
    if (-not $label) { $label = '待機' }
    # Windowsで使えない文字だけ置換し、通常の行動名は省略せずそのまま残す。
    $label = $label -replace '[<>:"/\\|?*\x00-\x1f]', '_'
    $name = ($Scene.Characters.No -join '-') + '_' + $label + '.png'
    if ($name.Length -gt 180) { throw 'キャラIDと行動名の画像名が長すぎます（180文字まで）。' }
    return $name
}

function Save-GeneratedImage([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.Drawing
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entry = $zip.Entries | Where-Object { $_.Name.EndsWith('.png', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($null -eq $entry -or $entry.Length -gt 20971520) { throw 'API応答に有効なPNGがありません。' }
        $inputStream = $entry.Open()
        $memory = New-Object IO.MemoryStream
        try {
            $inputStream.CopyTo($memory)
            $memory.Position = 0
            $image = [Drawing.Image]::FromStream($memory)
            try {
                if ($image.Width -gt 2048 -or $image.Height -gt 2048) { throw 'API画像のサイズが不正です。' }
                $image.Save($Destination + '.tmp', [Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $image.Dispose() }
        }
        finally { $inputStream.Dispose(); $memory.Dispose() }
        if ([IO.File]::Exists($Destination)) {
            [IO.File]::Replace($Destination + '.tmp', $Destination, $Destination + '.bak')
            [IO.File]::Delete($Destination + '.bak')
        } else { [IO.File]::Move($Destination + '.tmp', $Destination) }
    }
    finally { $zip.Dispose() }
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

function Set-Status([string]$Text) {
    $path = Join-Path $script:Runtime 'status.txt'
    if ((Read-Text $path) -ne $Text) { Write-Atomic $path $Text; Write-Log $Text }
}

function Invoke-Worker {
    param([switch]$Once, [string]$Directory = $PSScriptRoot)
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
        Write-Log 'NovelAIワーカー起動。このウィンドウを閉じると停止します。stop.cmdでも停止できます。'
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
                    $actionNames = if ($scene.Modes.Count) { $scene.Modes.Name -join ', ' } else { $scene.Action }
                    Write-Log ('要求 {0} | model={1} | キャラNO={2} | 動作={3} | 画像={4}' -f $scene.Id, $config.model, ($scene.Characters.No -join ','), $actionNames, $imageName)
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
                    if ($sceneChanged) { Write-Log ('画像再利用: ' + $cachedName) }
                }
                if (-not $force -and ($cachedName -or $sameRegeneration)) {
                    if ($sameRegeneration) { Set-Status $regenResult[2] }
                    else { Set-Status '保存済み画像を再利用しています。' }
                    continue
                }
                $attemptName = if ($force) { 'regenerate-' + $regenToken + '.txt' } else { $imageName + '.txt' }
                $attemptPath = Join-Path $attempts $attemptName
                if (Test-Path -LiteralPath $attemptPath) { Set-Status (Read-Text $attemptPath); continue }
                if ($count -ge $config.maximum_generations_per_run) { Set-Status '今回の生成上限に達しました。ワーカーを再起動すると再開できます。'; continue }
                if (([datetime]::UtcNow - $lastRequest).TotalSeconds -lt $config.minimum_interval_seconds) { Set-Status '生成間隔の待機中です（最新の場面だけを処理）。'; continue }
                $spec = New-Payload $scene $config $Directory
                if ($spec.UnknownActions.Count) { Write-Log ('未登録の行動タグ: ' + ($spec.UnknownActions -join ', ')) }
                $token = $env:NOVELAI_API_TOKEN
                $tokenPath = Join-Path $script:Runtime 'token.dpapi'
                if (-not $token -and (Test-Path -LiteralPath $tokenPath)) {
                    $secure = (Read-Text $tokenPath) | ConvertTo-SecureString
                    $token = (New-Object Net.NetworkCredential('', $secure)).Password
                }
                if (-not $token) { Set-Status 'APIキー未設定。novelai/setup-token.cmdを実行してください。'; continue }
                $latest = Read-Scene (Read-Text (Join-Path $script:Runtime 'request.txt'))
                if ($null -eq $latest -or $latest.Id -ne $scene.Id -or (Read-Text (Join-Path $script:Runtime 'enabled.txt')) -ne '1') { continue }
                # 送信前に永続記録。タイムアウト・中断後も同じ課金要求を自動で再送しない。
                Write-Atomic $attemptPath '前回の送信結果が未確認です。必要なら設定画面の「再試行」を選択してください。'
                if ($force) { Write-Atomic $regenResultPath ($regenToken + "`n" + $imageName + "`n再生成の送信結果が未確認です。必要なら再生成ボタンを押してください。") }
                Write-Atomic (Join-Path $script:Runtime 'preview.json') (ConvertTo-Json $spec.Payload -Depth 15)
                Write-Atomic (Join-Path $script:Runtime 'unmapped-actions.txt') ($spec.UnknownActions -join "`n")
                if ($force -or $spec.Payload.parameters.seed -eq -1) { $spec.Payload.parameters.seed = Get-Random -Minimum 0 -Maximum 2147483647 }
                $lastRequest = [datetime]::UtcNow
                $count++
                Set-Status ("生成中（{0}/{1}）。NovelAIタブで自動表示します。" -f $count, $config.maximum_generations_per_run)
                Write-Log ('API送信 | {0}x{1} | steps={2} | seed={3} | プロンプト: novelai/runtime/preview.json' -f $config.width, $config.height, $config.steps, $spec.Payload.parameters.seed)
                Write-Log ('全体プロンプト: ' + $spec.Payload.input)
                Write-Log ('ネガティブプロンプト: ' + $spec.Payload.parameters.negative_prompt)
                if ($spec.Payload.parameters.Contains('v4_prompt')) {
                    for ($i = 0; $i -lt $scene.Characters.Count; $i++) {
                        Write-Log ('キャラ{0}（NO={1}）プロンプト: {2}' -f ($i + 1), $spec.CharacterNos[$i], $spec.Payload.parameters.v4_prompt.caption.char_captions[$i].char_caption)
                        Write-Log ('キャラ{0}（NO={1}）ネガティブ: {2}' -f ($i + 1), $spec.CharacterNos[$i], $spec.Payload.parameters.v4_negative_prompt.caption.char_captions[$i].char_caption)
                    }
                }
                $archive = Join-Path $script:Runtime 'download.zip'
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    $body = $script:Utf8.GetBytes((ConvertTo-Json $spec.Payload -Depth 15 -Compress))
                    Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://image.novelai.net/ai/generate-image' -MaximumRedirection 0 `
                        -Headers @{ Authorization = 'Bearer ' + $token; Accept = 'application/zip' } `
                        -ContentType 'application/json' -Body $body -OutFile $archive -TimeoutSec 120 | Out-Null
                    Save-GeneratedImage $archive $imagePath
                    Write-Log ('画像保存: ' + $imagePath)
                    Write-Atomic $attemptPath '生成完了。'
                    if ($force) { Write-Atomic $regenResultPath ($regenToken + "`n" + $imageName + "`n再生成完了。NovelAIタブへ自動反映します。") }
                    Publish-Image $scene $imageName
                    Set-Status '生成完了。NovelAIタブへ自動反映します。'
                }
                catch {
                    $code = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    Write-Log ('APIエラー: ' + $_.Exception.Message.Replace($token, '[redacted]'))
                    if ($_.ErrorDetails.Message) { Write-Log ('API応答: ' + $_.ErrorDetails.Message.Replace($token, '[redacted]')) }
                    $message = "画像生成に失敗しました（HTTP $code、0は通信・画像読込エラー）。自動再送はしません。設定を確認して「再試行」を選択してください。"
                    if ($force) {
                        $message = "再生成に失敗しました（HTTP $code）。以前の画像は保持します。再生成ボタンでやり直せます。"
                        Write-Atomic $regenResultPath ($regenToken + "`n" + $imageName + "`n" + $message)
                    }
                    Write-Atomic $attemptPath $message
                    Set-Status $message
                }
                finally { $token = $null; if (Test-Path -LiteralPath $archive) { [IO.File]::Delete($archive) } }
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
