# API通信なし。隔離CSV・APIモック・実Emueraで口上連携を検証する。
param([string]$GeneratedTextPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker.ps1') -Library
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected '不正な設定を拒否する必要があります。'
}
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testRoot = Join-Path $PSScriptRoot ('runtime/test-' + [guid]::NewGuid().ToString('N'))
$runtime = Join-Path $testRoot 'runtime'
$testUtf8 = New-Object Text.UTF8Encoding($true)
$process = $null
try {
    [void][IO.Directory]::CreateDirectory($runtime)
    foreach ($file in 'config.csv', 'prompts.csv', 'characters.csv', 'actions.csv') {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $testRoot $file)
    }
    $configPath = Join-Path $testRoot 'config.csv'
    Write-Atomic $configPath ((Read-Text $configPath) -replace '(?m)^model,[^\r\n]+', 'model,kayra-v1')
    Write-Atomic (Join-Path $testRoot 'characters.csv') "no,prompt`n123,丁寧な話し方`n0,旅人"
    Write-Atomic (Join-Path $testRoot 'actions.csv') "name,prompt`n会話する,短い返事"
    $wire = "NAITEXT1`t100-1`nplayer`t0`t主人公`ncharacter`t123`tテスト相手`naction`t会話する`nplace`t海辺`nstate`t信頼度=10`nEND`t100-1"
    $request = Read-TextRequest $wire
    Assert ($request.character.No -eq '123' -and $request.action -eq '会話する') '要求の読込'
    Assert ($null -eq (Read-TextRequest ($wire.Replace('END', 'BAD')))) '途中書込みを拒否'
    Assert ($null -eq (Read-TextRequest ($wire.Replace('place', 'action')))) '重複フィールドを拒否'
    Assert ($null -eq (Read-TextRequest ($wire.Replace("character`t123", "character`t../123")))) 'キャラ番号を検証'
    $config = Read-TextConfig $testRoot
    $payload = New-TextPayload $request $config $testRoot
    Assert ($payload.input.Contains('丁寧な話し方') -and $payload.input.Contains('海辺') -and $payload.input.Contains('短い返事')) '独立CSVと場面を結合'
    Assert ($payload.parameters.use_string -and $payload.parameters.max_length -eq 150 -and $payload.parameters.logit_bias_exp.Count -eq 0) '公式APIの文字列形式'
    Write-Atomic (Join-Path $testRoot 'characters.csv') "no,prompt`n123,明るい話し方"
    Assert ((New-TextPayload $request $config $testRoot).input.Contains('明るい話し方')) 'CSVを毎回読み直す'
    Write-Atomic (Join-Path $testRoot 'characters.csv') "no,prompt`n123,`"落ち着いた,話し方`n二行目`""
    Assert ((New-TextPayload $request $config $testRoot).input.Contains("落ち着いた,話し方`n二行目")) 'CSVのカンマと改行を保持'
    Write-Atomic (Join-Path $testRoot 'characters.csv') "no,prompt`n123,a`n123,b"
    Reject { New-TextPayload $request $config $testRoot }
    Write-Atomic (Join-Path $testRoot 'characters.csv') 'no,prompt'
    Assert ((New-TextPayload $request $config $testRoot).input.Contains('テスト相手')) '未登録時はゲームの名前'
    $originalConfig = Read-Text (Join-Path $testRoot 'config.csv')
    foreach ($bad in 'NaN', 'Infinity', '-1', '150.5') {
        Write-Atomic (Join-Path $testRoot 'config.csv') ($originalConfig.Replace('max_length,150', "max_length,$bad"))
        Reject { Read-TextConfig $testRoot }
    }
    Write-Atomic (Join-Path $testRoot 'config.csv') $originalConfig

    # 外部通信関数を置換。実トークンにもアクセスしない。
    function Get-TextToken { return 'TEST-TOKEN-ONLY' }
    $script:Calls = 0
    $script:ApiMode = 'ok'
    function New-HttpReply($Value) {
        $rawBytes = $script:Utf8.GetBytes((ConvertTo-Json $Value -Depth 10 -Compress))
        # charsetなしをPS5.1が誤読したContentと、正しいUTF-8のRawContentStream。
        return [pscustomobject]@{ Content = [Text.Encoding]::GetEncoding(28591).GetString($rawBytes); RawContentStream = [IO.MemoryStream]::new($rawBytes) }
    }
    function Invoke-WebRequest($Method, $Uri, $MaximumRedirection, $Headers, $ContentType, $Body, $TimeoutSec, [switch]$UseBasicParsing) {
        $script:Calls++
        Assert ($Method -eq 'Post' -and $MaximumRedirection -eq 0) 'POST・リダイレクト禁止'
        Assert ($Headers.Authorization -ceq 'Bearer TEST-TOKEN-ONLY') '認証ヘッダー'
        Assert ($ContentType -ceq 'application/json; charset=utf-8') '送信もUTF-8を明示'
        $sent = $script:Utf8.GetString($Body) | ConvertFrom-Json
        if ($sent.model -eq 'glm-4-6') {
            Assert ($Uri -ceq 'https://text.novelai.net/oa/v1/completions') 'GLMのAPI'
            Assert ($sent.prompt -is [string] -and $sent.prompt.Contains('テスト相手') -and $null -eq $sent.messages) 'GLMにはtoken_idsではなく文字列promptを送る'
            Assert ($sent.max_tokens -eq 150 -and $sent.stream -eq $false -and $null -eq $sent.parameters) 'GLMの生成条件'
            if ($script:ApiMode -eq 'empty') { return New-HttpReply @{ choices = @() } }
            return New-HttpReply @{ choices = @(@{ text = '「こんにちは、今日はいい天気ですね」'; token_ids = @(1, 2) }) }
        }
        Assert ($Uri -ceq 'https://text.novelai.net/ai/generate') 'Kayra/EratoのAPI'
        Assert ($sent.input.Contains('テスト相手') -and $sent.parameters.use_string) 'UTF-8のAPI本文'
        if ($script:ApiMode -eq 'error') {
            $record = New-Object Management.Automation.ErrorRecord ([Exception]::new('400 Bad Request')), 'Api400', 'InvalidOperation', $null
            $record.ErrorDetails = [Management.Automation.ErrorDetails]::new('{"statusCode":400,"message":"kayra-v1 is unavailable due to maintenance TEST-TOKEN-ONLY"}')
            throw $record
        }
        if ($script:ApiMode -eq 'empty') { return New-HttpReply @{ output = '' } }
        if ($script:ApiMode -eq 'late') { Write-Atomic (Join-Path $runtime 'request.txt') '' }
        if ($script:ApiMode -eq 'disabled') { Write-Atomic (Join-Path $runtime 'enabled.txt') '0' }
        return New-HttpReply @{ output = "「こんにちは」`nEND`t100-1`n%NAME:0% <button>literal</button>" }
    }
    Write-Atomic (Join-Path $runtime 'request.txt') $wire
    Write-Atomic (Join-Path $runtime 'enabled.txt') '0'
    Invoke-TextWorker -Once -Directory $testRoot
    Assert ($script:Calls -eq 0) '無効時は通信なし'
    Write-Atomic (Join-Path $runtime 'enabled.txt') '1'
    Invoke-TextWorker -Once -Directory $testRoot
    $responsePath = Join-Path $runtime 'response.txt'
    $goodResponse = Read-Text $responsePath
    Assert ($goodResponse.Contains("`nok`ntext`t「こんにちは」") -and $goodResponse.Contains("text`tEND`t100-1")) '改行・区切りを含む応答'
    Invoke-TextWorker -Once -Directory $testRoot
    Assert ($script:Calls -eq 1) '同一要求の重複送信なし'
    $script:ApiMode = 'error'
    Write-Atomic (Join-Path $runtime 'request.txt') ($wire.Replace('100-1', '100-2'))
    Invoke-TextWorker -Once -Directory $testRoot
    Invoke-TextWorker -Once -Directory $testRoot
    Assert ($script:Calls -eq 2 -and (Read-Text $responsePath).Contains("`nerror`n")) '失敗後も自動再送なし'
    Assert (-not (Read-Text (Join-Path $runtime 'status.txt')).Contains('TEST-TOKEN-ONLY')) 'エラーにキーを残さない'
    Assert ((Read-Text (Join-Path $runtime 'status.txt')).Contains('kayra-v1 is unavailable due to maintenance')) '400の具体的理由を表示'
    foreach ($mode in 'empty', 'late', 'disabled') {
        $script:ApiMode = $mode
        Write-Atomic (Join-Path $runtime 'enabled.txt') '1'
        Write-Atomic $responsePath $goodResponse
        Write-Atomic (Join-Path $runtime 'request.txt') ($wire.Replace('100-1', ('200-' + ($script:Calls + 1))))
        Invoke-TextWorker -Once -Directory $testRoot
        if ($mode -eq 'empty') { Assert ((Read-Text $responsePath).Contains("`nerror`n")) '空応答は失敗' }
        else { Assert ((Read-Text $responsePath) -ceq $goodResponse) '取消し・無効化後の応答を破棄' }
    }
    Write-Atomic $configPath ($originalConfig.Replace('model,kayra-v1', 'model,glm-4-6'))
    Write-Atomic (Join-Path $runtime 'enabled.txt') '1'
    Write-Atomic (Join-Path $runtime 'request.txt') ($wire.Replace('100-1', '300-1'))
    Invoke-TextWorker -Once -Directory $testRoot
    Assert ((Read-Text $responsePath).Contains('今日はいい天気ですね')) 'GLMの応答を既存の口上通信へ接続'
    $script:ApiMode = 'empty'
    Write-Atomic (Join-Path $runtime 'request.txt') ($wire.Replace('100-1', '300-2'))
    Invoke-TextWorker -Once -Directory $testRoot
    Assert ((Read-Text $responsePath).Contains("`nerror`n")) 'GLMの空応答も失敗として扱う'

    $displayText = if ($GeneratedTextPath) { Read-Text $GeneratedTextPath } else { '「こんにちは、今日はいい天気ですね」' }
    Assert (-not [string]::IsNullOrWhiteSpace($displayText)) '表示検証用の日本語本文'
    $displayLines = @($displayText.Trim() -split '\r?\n')
    $displayBody = ($displayLines | ForEach-Object { "text`t$_" }) -join "`n"

    $gameRoot = Join-Path $testRoot 'game'
    foreach ($dir in 'CSV', 'ERB', 'novelai/text/runtime') { [void][IO.Directory]::CreateDirectory((Join-Path $gameRoot $dir)) }
    $exe = Get-ChildItem -LiteralPath $repoRoot -Filter 'Emuera*.exe' | Select-Object -First 1
    New-Item -ItemType HardLink -Path (Join-Path $gameRoot 'Emuera.exe') -Value $exe.FullName | Out-Null
    foreach ($file in 'FLAG.csv', 'CFLAG.csv', 'TFLAG.csv', 'TCVAR.csv', 'SAVESTR.csv', 'VariableSize.csv') {
        Copy-Item -LiteralPath (Join-Path $repoRoot ('CSV/' + $file)) -Destination (Join-Path $gameRoot 'CSV')
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'CSV/RFLAG.csv') -Destination (Join-Path $gameRoot 'ERB/RFLAG.ERD')
    Copy-Item -Path (Join-Path $repoRoot 'ERB/追加MOD_NovelAI口上/*') -Destination (Join-Path $gameRoot 'ERB')
    [IO.File]::WriteAllText((Join-Path $gameRoot 'CSV/GameBase.csv'), "コード,1`nバージョン,1`nタイトル,NovelAI Text Test", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $gameRoot 'emuera.config'), "LOADTEXTとSAVETEXTで使える拡張子:txt`nロード時に引数を解析する:YES", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $gameRoot 'ERB/test.ERH'), "#DIM RFLAG, 200`n#DIMS SELECTCOM_NAME`n#DIM 自慰ターゲット保存", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $gameRoot 'novelai/text/runtime/response.txt'), $goodResponse, $testUtf8)
    $testCode = @'
@SYSTEM_TITLE
#DIM 開始
ADDVOIDCHARA
ADDVOIDCHARA
PLAYER = 0
MASTER = 0
TARGET = 1
NO:1 = 123
CALLNAME:0 = 主人公
CALLNAME:1 = テスト相手
SELECTCOM_NAME = 会話する
自慰ターゲット保存 = -1
FLAG:口上表示切り替えオプション = 1
FLAG:あなたキャラ化記録 = 456
SIF NAIT_キャラ行("player", 0) != "player\t456\t主人公\n"
    THROW キャラ化番号の不一致
CALL NAIT_応答取得("100-1")
SIF RESULT != 1 || STRFIND(RESULTS, "%NAME:0% <button>literal</button>") < 0
    THROW 応答をプレーンテキストで取得できません
PRINTSL RESULTS
CALL NAIT_応答取得("different")
SIF RESULT != 0 || RESULTS != ""
    THROW 古い応答の混入
SAVETEXT "NAITEXT1\t100-1\nerror\nEND\t100-1", "novelai/text/runtime/response.txt", 0, 1
CALL NAIT_応答取得("100-1")
SIF RESULT != -1 || RESULTS != ""
    THROW エラー応答を表示している
SAVETEXT "NAITEXT1\t100-1\nok\n壊れた本文\nEND\t100-1", "novelai/text/runtime/response.txt", 0, 1
CALL NAIT_応答取得("100-1")
SIF RESULT != 0 || RESULTS != ""
    THROW 不正な本文を受理している
CALL NAIT_コマンド口上
SIF NAIT_連番 != 0
    THROW 無効時の送信
SAVETEXT "1", "novelai/text/runtime/enabled.txt", 0, 1
TFLAG:オートコマンドフラグ = 1
CALL NAIT_コマンド口上
SIF NAIT_連番 != 0
    THROW オートコマンドを送信している
TFLAG:オートコマンドフラグ = 0
SAVETEXT "ready", "ready.txt", 0, 1
CALL NAIT_コマンド口上
SIF NAIT_連番 != 1 || LOADTEXT("novelai/text/runtime/request.txt", 0, 1) != ""
    THROW 要求が完了していない
OUTPUTLOG "display.txt"
; ワーカーなしの待機上限。
開始 = GETMILLISECOND()
CALL NAIT_コマンド口上
SIF GETMILLISECOND() - 開始 > 5000
    THROW ワーカー未起動時の待機が長すぎる
SIF TIME != 0
    THROW 待機でゲーム時間が進んでいる
SAVETEXT "PASS", "done.txt", 0, 1
QUIT

@GETPLACENAME(ARG, ARG:1)
#FUNCTIONS
RETURNF "海辺"
'@
    [IO.File]::WriteAllText((Join-Path $gameRoot 'ERB/test.ERB'), $testCode, $testUtf8)
    $process = Start-Process -FilePath (Join-Path $gameRoot 'Emuera.exe') -WorkingDirectory $gameRoot -WindowStyle Hidden -PassThru
    $answered = $false
    for ($i = 0; $i -lt 100 -and -not (Test-Path (Join-Path $gameRoot 'done.txt')); $i++) {
        $gameRuntime = Join-Path $gameRoot 'novelai/text/runtime'
        $gameRequest = Read-TextRequest (Read-Text (Join-Path $gameRuntime 'request.txt'))
        if (-not $answered -and $null -ne $gameRequest) {
            Assert ($gameRequest.player.No -eq '456' -and $gameRequest.character.No -eq '123' -and $gameRequest.action -eq '会話する') '実Emueraの人物・行動要求'
            Write-Atomic (Join-Path $gameRuntime 'processing.txt') $gameRequest.Id
            Write-Atomic (Join-Path $gameRuntime 'response.txt') ("NAITEXT1`t$($gameRequest.Id)`nok`n$displayBody`nEND`t$($gameRequest.Id)")
            $answered = $true
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path (Join-Path $gameRoot 'done.txt'))) {
        if (Test-Path (Join-Path $gameRoot 'emuera.log')) { Get-Content -Encoding UTF8 (Join-Path $gameRoot 'emuera.log') -Tail 20 }
        throw 'Emueraの口上テストが完了しませんでした。'
    }
    Assert $answered '実Emueraとの往復'
    $displayLog = [IO.File]::ReadAllText((Join-Path $gameRoot 'display.txt'))
    foreach ($line in $displayLines) { Assert ($displayLog.Contains($line)) '実Emueraの表示ログで日本語が一致' }
    Write-Host 'PASS: independent CSV / native and GLM APIs / UTF-8 decoding / failure handling / Emuera Japanese display and timeout'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'runtime')) + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($allowed) -and [IO.Path]::GetFileName($resolved) -match '^test-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
