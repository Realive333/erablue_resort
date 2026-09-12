# API通信を一切行わない、小さな実行可能な回帰チェック。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker.ps1') -Library
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$config = Read-Text (Join-Path $PSScriptRoot 'config.json') | ConvertFrom-Json
$data = Read-PromptData $PSScriptRoot
$request = "NAI1`t100-1`nplayer`t0`t0`t主人公`ncharacter`t7`t123`tテスト相手`ncharacter`t8`t456`t二人目`nplace`t0`t1`nmode`t0`t7`t会話する`nEND`t100-1"
$scene = Read-Scene $request
Assert ($scene.Characters.Count -eq 3) 'プレイヤーと接触相手の読込'
Assert ($null -eq (Read-Scene ($request.Replace('END', 'BROKEN')))) '途中の要求を拒否'
Assert ($null -eq (Read-Scene ($request.Replace('mode' + "`t0`t7", 'mode' + "`t7`t8")))) 'プレイヤー無関係の動作を拒否'
Assert ($null -eq (Read-Scene ($request.Replace("character`t8", "character`t7")))) '重複キャラを拒否'
$spec = New-Payload $scene $config $PSScriptRoot
Assert ($spec.Payload.parameters.v4_prompt.caption.char_captions.Count -eq 3) 'V4個別キャプション'
Assert ($spec.Payload.input -match 'talking together') '動作の辞書変換'
Assert ($spec.Payload.parameters.v4_negative_prompt.caption.char_captions.Count -eq 3) '正負プロンプトの人数一致'
$sameScene = Read-Scene ($request.Replace('100-1', '200-2'))
Assert ((New-Payload $sameScene $config $PSScriptRoot).Hash -eq $spec.Hash) '要求IDが違ってもキャッシュ共有'
$changed = Read-Scene ($request.Replace('会話する', '散歩する'))
Assert ((New-Payload $changed $config $PSScriptRoot).Hash -ne $spec.Hash) '動作変化をキャッシュに反映'
$data.Characters['123'] = 'blue hair'
Assert ((New-Payload $scene $config $PSScriptRoot $data).Hash -ne $spec.Hash) '個別キャラ設定変更を反映'
$data.Actions['会話する'] = [pscustomobject]@{ scene = 'conversation'; actor = 'speaking'; target = 'listening' }
$roles = New-Payload $scene $config $PSScriptRoot $data
Assert ($roles.Payload.parameters.v4_prompt.caption.char_captions[0].char_caption -match 'speaking') '実行者に動作を付与'
Assert ($roles.Payload.parameters.v4_prompt.caption.char_captions[1].char_caption -match 'listening') '対象者に動作を付与'
$config.width = 833
$rejected = $false
try { New-Payload $scene $config $PSScriptRoot | Out-Null } catch { $rejected = $true }
Assert $rejected '不正な解像度を送信前に拒否'

$testDirectory = Join-Path $script:Runtime ('test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
$realRuntime = $script:Runtime
try {
    $script:Runtime = $testDirectory
    $statusLog = @(& { Set-Status 'test status'; Set-Status 'test status' } 6>&1)
    Assert ($statusLog.Count -eq 1 -and "$($statusLog[0])" -match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] test status$') '状態ログは日時付きで変更時に1回だけ表示'
    foreach ($file in 'config.json', 'prompts.csv', 'characters.csv', 'actions.csv') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $testDirectory $file) }
    $complexPrompt = "comma, quote `"OK`"`nand second line 日本語"
    Update-Setting $testDirectory 'prompts' 'system' $complexPrompt
    Assert ((Read-PromptData $testDirectory).Prompts.system -ceq $complexPrompt) 'CSVのカンマ・引用符・改行・日本語を保持'
    Update-Setting $testDirectory 'characters' '9999' $complexPrompt
    Assert ((Read-PromptData $testDirectory).Characters['9999'] -ceq $complexPrompt) 'CSV個別キャラの追加'
    Update-Setting $testDirectory 'prompts' 'system' 'fixed system'
    Update-Setting $testDirectory 'characters' '0' 'red jacket'
    Update-Setting $testDirectory 'characters' '123' 'blue hair'
    Update-Setting $testDirectory 'characters' '456' ' '
    $fixedPrompts = Read-Text (Join-Path $testDirectory 'prompts.csv')
    $lookup = New-Payload $scene ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    $captions = $lookup.Payload.parameters.v4_prompt.caption.char_captions
    Assert ($lookup.Payload.input -ceq 'fixed system, talking together') '固定システムに現在の行動CSVを結合'
    Assert ($captions[0].char_caption -ceq 'red jacket' -and $captions[1].char_caption -ceq 'blue hair') 'プレイヤーも接触相手もゲーム内NOでCSVを検索'
    Assert ($captions[2].char_caption -ceq '二人目') '空欄キャラはゲーム内の名前を使用'
    Update-Setting $testDirectory 'characters' '123' 'green hair'
    $lookup = New-Payload $scene ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    Assert ($lookup.Payload.parameters.v4_prompt.caption.char_captions[1].char_caption -ceq 'green hair') '実行中のキャラCSV変更を次回組立時に反映'
    $otherCharacter = Read-Scene ($request.Replace("character`t7`t123", "character`t7`t789"))
    $lookup = New-Payload $otherCharacter ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    Assert ($lookup.Payload.parameters.v4_prompt.caption.char_captions[1].char_caption -ceq 'テスト相手') '未登録のキャラNOへ変わると以前のプロンプトを流用しない'
    Assert ((Read-Text (Join-Path $testDirectory 'prompts.csv')) -ceq $fixedPrompts) '実行時の組立で固定プロンプトCSVを書き換えない'
    Update-Setting $testDirectory 'config' 'model' 'nai-diffusion-3'
    $v3 = New-Payload $scene ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    Assert (-not $v3.Payload.parameters.Contains('v4_prompt')) 'V3へ切替時に個別キャプションを除去'
    Assert ($v3.Payload.input -ceq 'fixed system, talking together, red jacket, green hair, 二人目') 'V3でもシステム・行動・現在の全キャラを結合'
    Update-Setting $testDirectory 'config' 'model' 'nai-diffusion-4-5-full'
    Update-Setting $testDirectory 'config' 'width' '1024'
    $v4 = New-Payload $scene ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    Assert ($v4.Payload.parameters.v4_prompt.caption.char_captions.Count -eq 3 -and $v4.Payload.parameters.width -eq 1024) 'モデル・設定変更を反映'
    Assert ($v4.Payload.parameters.params_version -eq 3) '既存V4の送信形式を維持'
    Update-Setting $testDirectory 'config' 'noise_schedule' 'native'
    foreach ($model in 'nai-diffusion-5-full', 'nai-diffusion-5-curated') {
        Update-Setting $testDirectory 'config' 'model' $model
        $v5Config = Read-Text (Join-Path $testDirectory 'config.json') | ConvertFrom-Json
        $v5 = New-Payload $scene $v5Config $testDirectory
        Assert ($v5.Payload.model -eq $model -and $v5.Payload.parameters.params_version -eq 4) 'V5のモデルIDと送信バージョン'
        Assert ($v5.Payload.parameters.noise_schedule -eq 'karras' -and $v5Config.noise_schedule -eq 'native') 'V5送信時だけKarrasを強制'
        Assert ($v5.Payload.parameters.v4_prompt.caption.char_captions.Count -eq 3 -and
            $v5.Payload.parameters.v4_negative_prompt.caption.char_captions.Count -eq 3) 'V5でも正負の個別キャラ設定を送信'
        Assert ($v5.Hash -ne $v4.Hash) 'モデル変更で旧画像キャッシュを流用しない'
    }
    $before = Read-Text (Join-Path $testDirectory 'config.json')
    $rejected = $false
    try { Update-Setting $testDirectory 'config' 'prompt_format' 'legacy' } catch { $rejected = $true }
    Assert ($rejected -and (Read-Text (Join-Path $testDirectory 'config.json')) -ceq $before) 'V5の非対応形式を保存しない'
    Update-Setting $testDirectory 'config' 'model' 'nai-diffusion-4-5-full'
    $back = New-Payload $scene ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    Assert ($back.Payload.parameters.params_version -eq 3 -and $back.Payload.parameters.noise_schedule -eq 'native') 'V4へ戻すと設定済みscheduleを再利用'
    Update-Setting $testDirectory 'config' 'model' 'nai-diffusion-5-full'
    $before = Read-Text (Join-Path $testDirectory 'config.json')
    $rejected = $false
    try { Update-Setting $testDirectory 'config' 'width' '833' } catch { $rejected = $true }
    Assert ($rejected -and (Read-Text (Join-Path $testDirectory 'config.json')) -ceq $before) '不正設定を保存しない'
    Write-Atomic (Join-Path $testDirectory 'settings-request.txt') "NAISET1`n123-1`nprompts`nsystem`ngame, input`nEND`t123-1"
    Sync-Settings $testDirectory
    Assert ((Read-PromptData $testDirectory).Prompts.system -ceq 'game, input') 'ゲームからの更新をCSVへ保存'
    Assert ((Read-Text (Join-Path $testDirectory 'settings-result.txt')) -match '^123-1') '設定更新の応答ID'
    # 不正CSVは黙って別のプロンプトへフォールバックさせない。
    $savedCsv = Read-Text (Join-Path $testDirectory 'prompts.csv')
    Write-Atomic (Join-Path $testDirectory 'prompts.csv') ($savedCsv + "`n`"system`",`"duplicate`"")
    $rejected = $false
    try { Read-PromptData $testDirectory | Out-Null } catch { $rejected = $true }
    Assert $rejected 'CSVの重複キーを拒否'
    Write-Atomic (Join-Path $testDirectory 'prompts.csv') $savedCsv
    Write-Atomic (Join-Path $testDirectory 'enabled.txt') '1'
    Write-Atomic (Join-Path $testDirectory 'request.txt') $request
    Publish-Image $sameScene $spec.Hash
    Assert (-not (Test-Path (Join-Path $testDirectory 'response.txt'))) '古い要求への応答を表示しない'
    Publish-Image $scene $spec.Hash
    Assert ((Read-Text (Join-Path $testDirectory 'response.txt')) -eq ("100-1`n" + $spec.Hash)) '一致する要求の応答'
    Write-Atomic (Join-Path $testDirectory 'enabled.txt') '0'
    Publish-Image $scene ('a' * 64)
    Assert ((Read-Text (Join-Path $testDirectory 'response.txt')) -eq ("100-1`n" + $spec.Hash)) '無効化後は応答を書き換えない'

    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $bitmap = New-Object Drawing.Bitmap(2, 2)
    $inputImage = Join-Path $testDirectory 'image.png'
    try { $bitmap.Save($inputImage, [Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
    $archivePath = Join-Path $testDirectory 'result.zip'
    $archive = [IO.Compression.ZipFile]::Open($archivePath, 'Create')
    try { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $inputImage, '../image.png') | Out-Null } finally { $archive.Dispose() }
    $outputImage = Join-Path $testDirectory 'output.png'
    Save-GeneratedImage $archivePath $outputImage
    Assert (Test-Path $outputImage) 'API形式ZIPからPNGを取得（ZIP内パスは使用しない）'

    # 実HTTPの代わりに上で作ったAPI形式ZIPを返し、ワーカー全経路を検証。
    $originalRoot = $script:Root
    $originalToken = $env:NOVELAI_API_TOKEN
    $script:Root = $testDirectory
    $env:NOVELAI_API_TOKEN = 'offline-test-token'
    $script:HttpCalls = 0
    function Invoke-WebRequest {
        param([switch]$UseBasicParsing, $Method, $Uri, $MaximumRedirection, $Headers, $ContentType, $Body, $OutFile, $TimeoutSec)
        $script:HttpCalls++
        Assert ($Uri -eq 'https://image.novelai.net/ai/generate-image') '送信先は公式API'
        Assert ($Headers.Accept -eq 'application/zip') 'ZIP応答を要求'
        $sent = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        Assert ($sent.model -eq 'nai-diffusion-5-full' -and $sent.parameters.params_version -eq 4 -and
            $sent.parameters.noise_schedule -eq 'karras') 'ワーカーの実送信経路でV5形式を確認'
        [IO.File]::Copy($archivePath, $OutFile, $true)
    }
    try {
        Write-Atomic (Join-Path $testDirectory 'enabled.txt') '1'
        Invoke-Worker -Once
        Assert ($script:HttpCalls -eq 1) '新しい場面で1回だけ生成'
        Invoke-Worker -Once
        Assert ($script:HttpCalls -eq 1) '再起動後はキャッシュを使用'
        Write-Atomic (Join-Path $testDirectory 'request.txt') ($request.Replace('100-1', '300-1').Replace('会話する', '散歩する'))
        function Invoke-WebRequest { $script:HttpCalls++; throw "mock network failure: $env:NOVELAI_API_TOKEN" }
        $failureLog = (@(& { Invoke-Worker -Once } 6>&1) | Out-String)
        Assert ($failureLog.Contains('APIエラー:') -and $failureLog.Contains('[redacted]') -and -not $failureLog.Contains($env:NOVELAI_API_TOKEN)) 'APIエラー詳細を表示してもキーをログに出さない'
        Assert ($script:HttpCalls -eq 2) '別の動作を生成'
        Invoke-Worker -Once
        Assert ($script:HttpCalls -eq 2) '失敗後も再起動で勝手に再送しない'
        Write-Atomic (Join-Path $testDirectory 'retry.txt') 'retry-1'
        Invoke-Worker -Once
        Assert ($script:HttpCalls -eq 3) '明示再試行でのみ再送'
        Write-Atomic (Join-Path $testDirectory 'enabled.txt') '0'
        Write-Atomic (Join-Path $testDirectory 'retry.txt') 'retry-2'
        Invoke-Worker -Once
        Assert ($script:HttpCalls -eq 3) '無効中は送信しない'
    }
    finally { $script:Root = $originalRoot; $env:NOVELAI_API_TOKEN = $originalToken }
    Write-Host 'PASS: CSV / config / models / scene / cache / validation / stale response / ZIP / worker / retry'
}
finally {
    $script:Runtime = $realRuntime
    # 作成したテスト専用ディレクトリだけを削除する。
    $resolved = [IO.Path]::GetFullPath($testDirectory)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($realRuntime) + [IO.Path]::DirectorySeparatorChar) -and
        [IO.Path]::GetFileName($resolved) -match '^test-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
