# API通信を一切行わない、小さな実行可能な回帰チェック。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker.ps1') -Library
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$config = Read-Text (Join-Path $script:NovelAiDirectory 'config.json') | ConvertFrom-Json
$data = Read-PromptData $script:NovelAiDirectory
# ユーザーが編集した行動タグに依存せず、テスト用の短いタグで検証する。
$actionFixtures = @(
    [pscustomobject]@{ name = '会話する'; scene = 'talking together'; actor = ''; target = '' }
    [pscustomobject]@{ name = '散歩する'; scene = 'walking together'; actor = ''; target = '' }
    [pscustomobject]@{ name = '待機'; scene = ''; actor = ''; target = '' }
)
foreach ($row in $actionFixtures) { $data.Actions[$row.name] = $row }
$request = "NAI1`t100-1`nplayer`t0`t0`t主人公`ncharacter`t7`t123`tテスト相手`ncharacter`t8`t456`t二人目`nplace`t0`t1`naction`t会話する`nEND`t100-1"
$scene = Read-Scene $request
Assert ($scene.Characters.Count -eq 3) 'プレイヤーと接触相手の読込'
Assert ($null -eq (Read-Scene ($request.Replace('END', 'BROKEN')))) '途中の要求を拒否'
Assert ($null -eq (Read-Scene ($request.Replace("action`t会話する", "action`t0`t7`t会話する")))) '壊れたコマンド行を拒否'
Assert ($null -eq (Read-Scene ($request.Replace("character`t8", "character`t7")))) '重複キャラを拒否'
$spec = New-Payload $scene $config $script:NovelAiDirectory $data
Assert ($spec.Payload.parameters.v4_prompt.caption.char_captions.Count -eq 3) 'V4個別キャプション'
Assert ($spec.Payload.input -match 'talking together') '動作の辞書変換'
Assert ($spec.Payload.parameters.v4_negative_prompt.caption.char_captions.Count -eq 3) '正負プロンプトの人数一致'
$sameScene = Read-Scene ($request.Replace('100-1', '200-2'))
$imageName = Get-ImageName $scene
Assert ($imageName -ceq '0_普段着_123_普段着_456_普段着_会話する.png') '画像名はキャラNO・服装を操作キャラから並べ、最後に行動を付ける'
Assert ((Get-ImageName $sameScene) -ceq $imageName) '同じ条件では要求IDが変わっても同じ画像名'
$movedIndex = Read-Scene ($request.Replace("character`t7`t", "character`t70`t"))
Assert ((Get-ImageName $movedIndex) -ceq $imageName) 'ゲーム内配列番号が変わってもキャラNOで再利用'
$mixedRequest = $request.Replace('END', "mode`t0`t8`t継続中の別行動`nmode`t8`t0`t別の継続行動`nEND")
$mixedScene = Read-Scene $mixedRequest
$mixedSpec = New-Payload $mixedScene $config $script:NovelAiDirectory $data
Assert ($mixedSpec.Prompt -ceq $spec.Prompt -and $mixedSpec.UnknownActions.Count -eq 0 -and (Get-ImageName $mixedScene) -ceq $imageName) '継続行動が混在してもユーザーのコマンドだけをプロンプトと画像名へ反映'
$modeOnly = Read-Scene ($mixedRequest.Replace("action`t会話する`n", ''))
Assert ((Get-ImageName $modeOnly) -ceq '0_普段着_123_普段着_456_普段着_待機.png' -and (New-Payload $modeOnly $config $script:NovelAiDirectory $data).UnknownActions.Count -eq 0) 'コマンドがない場合も継続行動へ戻らず待機'
$unmappedA = Read-Scene ($request.Replace('会話する', '未登録A'))
$unmappedB = Read-Scene ($request.Replace('会話する', '未登録B'))
Assert ((Get-ImageName $unmappedA) -cne (Get-ImageName $unmappedB)) '同じタグでも異なる行動を区別'
$literalAction = Read-Scene ($request.Replace('会話する', '会話する (テスト)+写真'))
Assert ((Get-ImageName $literalAction) -ceq '0_普段着_123_普段着_456_普段着_会話する (テスト)+写真.png') '空白や括弧など使える文字はそのまま残す'
$unsafeAction = Read-Scene ($request.Replace('会話する', 'path/with:bad*chars?'))
Assert ((Get-ImageName $unsafeAction) -ceq '0_普段着_123_普段着_456_普段着_path_with_bad_chars_.png') 'ファイル名の禁止文字だけ置換'
$longAction = Read-Scene ($request.Replace('会話する', ('長い動作' * 60)))
$rejected = $false
try { Get-ImageName $longAction | Out-Null } catch { $rejected = $true }
Assert $rejected '長すぎる名前は切り詰めて別の画像と衝突させず送信前に拒否'
$changed = Read-Scene ($request.Replace('会話する', '散歩する'))
Assert ((New-Payload $changed $config $script:NovelAiDirectory $data).Payload.input -match 'walking together') '動作変化をプロンプトに反映'
$data.Characters['123'] = 'blue hair'
Assert ((New-Payload $scene $config $script:NovelAiDirectory $data).Payload.parameters.v4_prompt.caption.char_captions[0].char_caption -ceq 'blue hair') '先頭の目標キャラに個別設定変更を反映'
$data.Actions['会話する'] = [pscustomobject]@{ scene = 'conversation'; actor = 'speaking'; target = 'listening' }
$roles = New-Payload $scene $config $script:NovelAiDirectory $data
Assert ($roles.Payload.parameters.v4_prompt.caption.char_captions[1].char_caption -match 'speaking') '順序変更後も実行者に動作を付与'
Assert ($roles.Payload.parameters.v4_prompt.caption.char_captions[0].char_caption -match 'listening') '順序変更後も対象者に動作を付与'
Assert ($roles.Payload.parameters.v4_prompt.caption.char_captions[2].char_caption -notmatch 'speaking|listening') '追加の接触者をコマンド対象として扱わない'
Assert (($roles.CharacterNos -join ',') -ceq '123,0,456') 'APIのキャラ順は目標・プレイヤー・追加の接触相手'
Assert ((Get-ImageName $scene) -ceq $imageName -and ($scene.Characters.No -join ',') -ceq '0,123,456') 'プロンプト順を変えてもシーンと画像名のID順を維持'
$config.width = 833
$rejected = $false
try { New-Payload $scene $config $script:NovelAiDirectory | Out-Null } catch { $rejected = $true }
Assert $rejected '不正な解像度を送信前に拒否'

$testDirectory = Join-Path $script:Runtime ('test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
$realRuntime = $script:Runtime
try {
    $script:Runtime = $testDirectory
    $statusLog = @(& { Set-Status 'test status'; Set-Status 'test status' } 6>&1)
    Assert ($statusLog.Count -eq 1 -and "$($statusLog[0])" -match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] test status$') '状態ログは日時付きで変更時に1回だけ表示'
    foreach ($file in 'config.json', 'prompts.csv', 'characters.csv', 'actions.csv', 'clothes.csv') { Copy-Item -LiteralPath (Join-Path $script:NovelAiDirectory $file) -Destination (Join-Path $testDirectory $file) }
    Write-CsvTable (Join-Path $testDirectory 'actions.csv') $actionFixtures @('name', 'scene', 'actor', 'target')
    $complexPrompt = "comma, quote `"OK`"`nand second line 日本語"
    Update-Setting $testDirectory 'prompts' 'system' $complexPrompt
    Assert ((Read-PromptData $testDirectory).Prompts.system -ceq $complexPrompt) 'CSVのカンマ・引用符・改行・日本語を保持'
    Update-Setting $testDirectory 'characters' '9999' $complexPrompt
    Assert ((Read-PromptData $testDirectory).Characters['9999'] -ceq $complexPrompt) 'CSV個別キャラの追加'
    Update-Setting $testDirectory 'prompts' 'system' 'fixed system'
    $idleScene = Read-Scene ($request.Replace("action`t会話する`n", ''))
    $idleConfig = Read-Text (Join-Path $testDirectory 'config.json') | ConvertFrom-Json
    $actionRows = @(Import-Csv -LiteralPath (Join-Path $testDirectory 'actions.csv') -Encoding UTF8)
    $idleRow = $actionRows | Where-Object name -eq '待機'
    Assert ($null -ne $idleRow) '待機項目をCSVに定義（タグ空欄も許可）'
    $idleRow.scene = 'standing together, relaxed'
    Write-CsvTable (Join-Path $testDirectory 'actions.csv') $actionRows @('name', 'scene', 'actor', 'target')
    foreach ($fallbackScene in @($idleScene, $unmappedA)) {
        $idle = New-Payload $fallbackScene $idleConfig $testDirectory
        Assert ($idle.Payload.input -ceq 'fixed system, standing together, relaxed') '行動なし・未登録時に待機CSVの編集内容を反映'
    }
    Assert ((Get-ImageName $idleScene) -ceq '0_普段着_123_普段着_456_普段着_待機.png') '待機タグを編集しても画像名はID・服装と待機のまま'
    Assert ($idle.UnknownActions -contains '未登録A') '待機タグを使っても未登録行動のログ情報を保持'
    Update-Setting $testDirectory 'characters' '0' 'red jacket'
    Update-Setting $testDirectory 'characters' '123' 'blue hair'
    Update-Setting $testDirectory 'characters' '456' ' '
    $fixedPrompts = Read-Text (Join-Path $testDirectory 'prompts.csv')
    $lookup = New-Payload $scene ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    $captions = $lookup.Payload.parameters.v4_prompt.caption.char_captions
    Assert ($lookup.Payload.input -ceq 'fixed system, talking together') '固定システムに現在の行動CSVを結合'
    Assert ($captions[0].char_caption -ceq 'blue hair' -and $captions[1].char_caption -ceq 'red jacket') 'ゲーム内NOでCSVを検索し目標→プレイヤー順で結合'
    Assert ($captions[2].char_caption -ceq '二人目') '空欄キャラはゲーム内の名前を使用'
    Update-Setting $testDirectory 'characters' '123' 'green hair'
    $lookup = New-Payload $scene ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    Assert ($lookup.Payload.parameters.v4_prompt.caption.char_captions[0].char_caption -ceq 'green hair') '実行中のキャラCSV変更を次回組立時に反映'
    $otherCharacter = Read-Scene ($request.Replace("character`t7`t123", "character`t7`t789"))
    $lookup = New-Payload $otherCharacter ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    Assert ($lookup.Payload.parameters.v4_prompt.caption.char_captions[0].char_caption -ceq 'テスト相手') '未登録のキャラNOへ変わると以前のプロンプトを流用しない'
    Assert ((Read-Text (Join-Path $testDirectory 'prompts.csv')) -ceq $fixedPrompts) '実行時の組立で固定プロンプトCSVを書き換えない'
    Set-Model 'nai-diffusion-3' $testDirectory
    $v3 = New-Payload $scene ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    Assert (-not $v3.Payload.parameters.Contains('v4_prompt')) 'V3へ切替時に個別キャプションを除去'
    Assert ($v3.Payload.input -ceq 'fixed system, talking together, green hair, red jacket, 二人目') 'V3でも目標→プレイヤー順に全キャラを結合'
    Set-Model 'nai-diffusion-4-5-full' $testDirectory
    Update-Setting $testDirectory 'config' 'width' '1024'
    $v4 = New-Payload $scene ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    Assert ($v4.Payload.parameters.v4_prompt.caption.char_captions.Count -eq 3 -and $v4.Payload.parameters.width -eq 1024) 'モデル・設定変更を反映'
    Assert ($v4.Payload.parameters.params_version -eq 3) '既存V4の送信形式を維持'
    Update-Setting $testDirectory 'config' 'noise_schedule' 'native'
    foreach ($model in 'nai-diffusion-5-full', 'nai-diffusion-5-curated') {
        Set-Model $model $testDirectory
        $v5Config = Read-Text (Join-Path $testDirectory 'config.json') | ConvertFrom-Json
        $v5 = New-Payload $scene $v5Config $testDirectory
        Assert ($v5.Payload.model -eq $model -and $v5.Payload.parameters.params_version -eq 4) 'V5のモデルIDと送信バージョン'
        Assert ($v5.Payload.parameters.noise_schedule -eq 'karras' -and $v5Config.noise_schedule -eq 'native') 'V5送信時だけKarrasを強制'
        Assert ($v5.Payload.parameters.v4_prompt.caption.char_captions.Count -eq 3 -and
            $v5.Payload.parameters.v4_negative_prompt.caption.char_captions.Count -eq 3) 'V5でも正負の個別キャラ設定を送信'
    }
    $before = Read-Text (Join-Path $testDirectory 'config.json')
    $rejected = $false
    try { Update-Setting $testDirectory 'config' 'prompt_format' 'legacy' } catch { $rejected = $true }
    Assert ($rejected -and (Read-Text (Join-Path $testDirectory 'config.json')) -ceq $before) 'V5の非対応形式を保存しない'
    Set-Model 'nai-diffusion-4-5-full' $testDirectory
    $back = New-Payload $scene ((Read-Text (Join-Path $testDirectory 'config.json')) | ConvertFrom-Json) $testDirectory
    Assert ($back.Payload.parameters.params_version -eq 3 -and $back.Payload.parameters.noise_schedule -eq 'native') 'V4へ戻すと設定済みscheduleを再利用'
    Set-Model 'nai-diffusion-5-full' $testDirectory
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
    Publish-Image $sameScene $imageName
    Assert (-not (Test-Path (Join-Path $testDirectory 'response.txt'))) '古い要求への応答を表示しない'
    Publish-Image $scene $imageName
    Assert ((Read-Text (Join-Path $testDirectory 'response.txt')) -eq ("100-1`n" + $imageName)) '一致する要求の応答'
    Write-Atomic (Join-Path $testDirectory 'enabled.txt') '0'
    Publish-Image $scene 'other.png'
    Assert ((Read-Text (Join-Path $testDirectory 'response.txt')) -eq ("100-1`n" + $imageName)) '無効化後は応答を書き換えない'

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
    Save-GeneratedImage $archivePath $outputImage
    $originalImageHash = (Get-FileHash -LiteralPath $outputImage).Hash
    Write-Atomic (Join-Path $testDirectory 'bad.zip') 'invalid zip'
    $rejected = $false
    try { Save-GeneratedImage (Join-Path $testDirectory 'bad.zip') $outputImage } catch { $rejected = $true }
    Assert ($rejected -and (Get-FileHash -LiteralPath $outputImage).Hash -eq $originalImageHash) '再生成は有効PNGだけを置換し不正応答時は旧画像を保持'

    # 実HTTPの代わりに上で作ったAPI形式ZIPを返し、ワーカー全経路を検証。
    $originalRoot = $script:Root
    $originalToken = $env:NOVELAI_API_TOKEN
    $script:Root = $testDirectory
    $env:NOVELAI_API_TOKEN = 'offline-test-token'
    $script:HttpCalls = 0
    $script:SentSeeds = @()
    Update-Setting $testDirectory 'config' 'seed' '4294967295'
    function Invoke-WebRequest {
        param([switch]$UseBasicParsing, $Method, $Uri, $MaximumRedirection, $Headers, $ContentType, $Body, $OutFile, $TimeoutSec)
        $script:HttpCalls++
        Assert ($Uri -eq 'https://image.novelai.net/ai/generate-image') '送信先は公式API'
        Assert ($Headers.Accept -eq 'application/zip') 'ZIP応答を要求'
        $sent = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        $script:SentPayload = $sent
        $script:SentSeeds += $sent.parameters.seed
        Assert ($sent.model -eq 'nai-diffusion-5-full' -and $sent.parameters.params_version -eq 4 -and
            $sent.parameters.noise_schedule -eq 'karras') 'ワーカーの実送信経路でV5形式を確認'
        [IO.File]::Copy($archivePath, $OutFile, $true)
    }
    try {
        Write-Atomic (Join-Path $testDirectory 'enabled.txt') '1'
        Write-Atomic (Join-Path $testDirectory 'request.txt') $mixedRequest
        $cacheDirectory = Join-Path $testDirectory 'resources/NovelAI'
        [void][IO.Directory]::CreateDirectory($cacheDirectory)
        $namedImage = Join-Path $cacheDirectory $imageName
        Copy-Item -LiteralPath $outputImage -Destination $namedImage
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 0) 'IDと行動名で置いた画像をAPI送信せず再利用'
        Remove-Item -LiteralPath $namedImage
        $recordPath = Join-Path $testDirectory ('attempts/' + $imageName + '.txt')
        Write-Atomic $recordPath '前回の送信記録'
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 0) '同じIDと行動の送信記録で自動再送を防止'
        Remove-Item -LiteralPath $recordPath
        Update-Setting $testDirectory 'prompts' 'negative' 'negative-log-sentinel'
        $promptLog = (@(& { Invoke-Worker -Once -Directory $testDirectory } 6>&1) | ForEach-Object { [string]$_ }) -join "`n"
        Assert ($script:HttpCalls -eq 1) '新しい場面で1回だけ生成'
        Assert ($promptLog.Contains('動作: 会話する') -and $promptLog -notmatch '継続中の別行動|別の継続行動') 'ワーカーの実送信・ログでも継続行動を参照しない'
        Assert ($promptLog.Contains('全体プロンプト: ' + ($script:SentPayload.input -replace '[\r\n\t]', ' '))) '送信した全体プロンプトを省略せずログ表示'
        Assert ($script:SentPayload.parameters.negative_prompt -ceq 'negative-log-sentinel') 'ネガティブはAPI送信に保持'
        Assert ($promptLog -notmatch 'negative-log-sentinel|ネガティブ') 'ネガティブの内容と見出しをログに出さない'
        $expectedNos = @('123', '0', '456')
        for ($i = 0; $i -lt $expectedNos.Count; $i++) {
            $caption = $script:SentPayload.parameters.v4_prompt.caption.char_captions[$i].char_caption
            Assert ($promptLog -match ('キャラ{0}: .*（NO={1} / ' -f ($i + 1), $expectedNos[$i])) '送信順にキャラ名とNOを表示'
            Assert ($promptLog.Contains('    プロンプト: ' + ($caption -replace '[\r\n\t]', ' '))) 'キャラ別プロンプトを全文表示'
        }
        Assert ($promptLog.Contains('服装: ゲームから未受信')) '服装行が届いていない場合は理由を表示'
        Assert (-not $promptLog.Contains($env:NOVELAI_API_TOKEN)) 'プロンプトログにAPIキーを含めない'
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 1) '再起動後はキャッシュを使用'
        Assert ((Test-Path -LiteralPath $namedImage) -and (Read-Text (Join-Path $testDirectory 'response.txt')).EndsWith([IO.Path]::GetFileName($namedImage))) '生成画像名をゲームへ返す'
        Write-Atomic (Join-Path $testDirectory 'regenerate.txt') "NAIREGEN1`n100-1`n500-1`nEND`t500-1"
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 2 -and $script:SentSeeds[0] -eq 4294967295 -and $script:SentSeeds[1] -lt 2147483647) '再生成ボタンはキャッシュを迂回して新しいSeedで1回送信'
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 2) '消費済みの再生成要求を再起動後に繰り返さない'
        Update-Setting $testDirectory 'config' 'scale' '6'
        Update-Setting $testDirectory 'prompts' 'system' 'changed system'
        Set-Model 'nai-diffusion-3' $testDirectory
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 2) 'モデル・プロンプト・設定を変えても同じIDと行動なら再利用'
        Set-Model 'nai-diffusion-5-full' $testDirectory
        function Invoke-WebRequest { $script:HttpCalls++; throw "mock network failure: $env:NOVELAI_API_TOKEN" }
        $beforeRegenerate = (Get-FileHash -LiteralPath $namedImage).Hash
        Write-Atomic (Join-Path $testDirectory 'regenerate.txt') "NAIREGEN1`n100-1`n500-2`nEND`t500-2"
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 3 -and (Get-FileHash -LiteralPath $namedImage).Hash -eq $beforeRegenerate) '再生成失敗時は旧画像を保持'
        Remove-Item -LiteralPath $namedImage
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 3) '旧画像がない場合も失敗した再生成を通常生成として自動再送しない'
        Copy-Item -LiteralPath $outputImage -Destination $namedImage
        Write-Atomic (Join-Path $testDirectory 'regenerate.txt') "NAIREGEN1`n999-1`n500-3`nEND`t500-3"
        Invoke-Worker -Once -Directory $testDirectory
        Write-Atomic (Join-Path $testDirectory 'regenerate.txt') "NAIREGEN1`n100-1`n500-4"
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 3) '別の場面や書込途中の再生成要求ではキャッシュを迂回しない'
        Write-Atomic (Join-Path $testDirectory 'request.txt') ($request.Replace('100-1', '300-1').Replace('会話する', '散歩する'))
        function Invoke-WebRequest { $script:HttpCalls++; throw "mock network failure: $env:NOVELAI_API_TOKEN" }
        $failureLog = (@(& { Invoke-Worker -Once -Directory $testDirectory } 6>&1) | Out-String)
        Assert ($failureLog.Contains('APIエラー:') -and $failureLog.Contains('[redacted]') -and -not $failureLog.Contains($env:NOVELAI_API_TOKEN)) 'APIエラー詳細を表示してもキーをログに出さない'
        Assert ($script:HttpCalls -eq 4) '別の動作を生成'
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 4) '失敗後も再起動で勝手に再送しない'
        Write-Atomic (Join-Path $testDirectory 'regenerate.txt') "NAIREGEN1`n300-1`n500-5`nEND`t500-5"
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 5) '明示再試行でのみ再送'
        Write-Atomic (Join-Path $testDirectory 'enabled.txt') '0'
        Write-Atomic (Join-Path $testDirectory 'regenerate.txt') "NAIREGEN1`n300-1`n500-6`nEND`t500-6"
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 5) '無効中は送信しない'
        Update-Setting $testDirectory 'characters' '789' 'green hair'
        $newIdentityRequest = $request.Replace('100-1', '700-1').Replace("character`t7`t123", "character`t7`t789")
        $newIdentity = Read-Scene $newIdentityRequest
        Assert ((Get-ImageName $newIdentity) -ceq '0_普段着_789_普段着_456_普段着_会話する.png') '同じプロンプトの別キャラはIDで区別'
        Write-Atomic (Join-Path $testDirectory 'enabled.txt') '1'
        Write-Atomic (Join-Path $testDirectory 'request.txt') $newIdentityRequest
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 6) '同じプロンプトでも別キャラIDの新条件を過去の送信記録で止めない'

        function Invoke-WebRequest {
            $script:HttpCalls++
            [IO.File]::Copy($archivePath, (Join-Path $script:Runtime 'download.zip'), $true)
        }
        $wardrobeRequest = $newIdentityRequest.Replace('END', "clothes`t0`t普段着`nclothes`t7`tメイド服`nclothes`t8`t水着`nEND")
        Write-Atomic (Join-Path $testDirectory 'request.txt') $wardrobeRequest
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 7 -and (Test-Path -LiteralPath (Join-Path $cacheDirectory '0_普段着_789_メイド服_456_水着_会話する.png'))) '服装を含む新しい名前で画像を保存'
        Write-Atomic (Join-Path $testDirectory 'request.txt') ($wardrobeRequest.Replace("clothes`t0`t普段着", "clothes`t0`t浴衣"))
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 8 -and (Test-Path -LiteralPath (Join-Path $cacheDirectory '0_浴衣_789_メイド服_456_水着_会話する.png'))) '操作キャラの着替えだけでも別画像を生成'
        Invoke-Worker -Once -Directory $testDirectory
        Assert ($script:HttpCalls -eq 8) 'キャラ・服装・行動が同じなら保存済み画像を再利用'

        # 旧設定が残っていても同じワーカーで21回送信できる。通信と待ち時間だけ置換。
        $legacyConfig = Read-Text (Join-Path $testDirectory 'config.json') | ConvertFrom-Json
        $legacyConfig | Add-Member -NotePropertyName maximum_generations_per_run -NotePropertyValue 20 -Force
        Write-Atomic (Join-Path $testDirectory 'config.json') (ConvertTo-Json $legacyConfig -Depth 15)
        $script:HttpCalls = 0
        $script:WorkerIterations = 0
        function Invoke-WebRequest {
            $script:HttpCalls++
            [IO.File]::Copy($archivePath, (Join-Path $script:Runtime 'download.zip'), $true)
        }
        function Start-Sleep {
            param($Milliseconds)
            $script:WorkerIterations++
            if ($script:WorkerIterations -ge 21) { Write-Atomic (Join-Path $script:Runtime 'stop.txt') 'stop'; return }
            Set-Variable -Scope 1 -Name lastRequest -Value ([datetime]::MinValue)
            Write-Atomic (Join-Path $script:Runtime 'request.txt') ($request.Replace('100-1', ('800-' + ($script:WorkerIterations + 1))).Replace('会話する', ('limit-test-' + $script:WorkerIterations)))
        }
        Write-Atomic (Join-Path $testDirectory 'request.txt') ($request.Replace('100-1', '800-1').Replace('会話する', 'limit-test-0'))
        $unlimitedLog = (@(& { Invoke-Worker -Directory $testDirectory } 6>&1) | Out-String)
        Assert ($script:HttpCalls -eq 21) 'ワーカーを再起動せず20回を超えて生成できる'
        Assert ($unlimitedLog.Contains('今回21回目')) '上限なしの送信回数を状態に表示'
    }
    finally { $script:Root = $originalRoot; $env:NOVELAI_API_TOKEN = $originalToken }
    Write-Host 'PASS: CSV / models / ID-clothes-action filenames / outfit cache / regeneration / atomic image replacement / stale requests / worker / unlimited submissions'
}
finally {
    $script:Runtime = $realRuntime
    # 作成したテスト専用ディレクトリだけを削除する。
    $resolved = [IO.Path]::GetFullPath($testDirectory)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($realRuntime) + [IO.Path]::DirectorySeparatorChar) -and
        [IO.Path]::GetFileName($resolved) -match '^test-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
