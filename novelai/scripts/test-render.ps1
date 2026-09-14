# 本体の一枚絵関数をEmueraのHTML_PRINTまで通す。API・セーブへのアクセスなし。
$ErrorActionPreference = 'Stop'
$novelAiDirectory = Split-Path $PSScriptRoot -Parent
$root = Split-Path $novelAiDirectory -Parent
$testRoot = Join-Path $novelAiDirectory ('runtime/render-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($true)
$process = $null
try {
    foreach ($directory in 'CSV', 'ERB', 'resources', 'novelai/runtime') {
        [void][IO.Directory]::CreateDirectory((Join-Path $testRoot $directory))
    }
    $executable = Get-ChildItem -LiteralPath $root -Filter 'Emuera*.exe' | Select-Object -First 1
    New-Item -ItemType HardLink -Path (Join-Path $testRoot 'Emuera.exe') -Value $executable.FullName | Out-Null
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/GameBase.csv'), "コード,1`nバージョン,1`nタイトル,NovelAI Render Test", $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Flag.csv'), '0,あなたキャラ化記録', $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/CFlag.csv'), "300,現在位置`n330,現在マップ種別", $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/TFlag.csv'), "221,オートコマンドフラグ`n222,オートコマンド連続発動", $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/TestVariables.ERH'), "#DIM コマンド履歴, 50`n#DIMS SELECTCOM_NAME履歴, 5`n#DIMS サイド描画表示種類", $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Chara0.csv'), "番号,0`n名前,主人公", $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Chara123.csv'), "番号,123`n名前,相手", $utf8)
    Copy-Item -LiteralPath (Join-Path $root 'ERB/追加MOD_NovelAI一枚絵/NovelAI.ERH') -Destination (Join-Path $testRoot 'ERB/NovelAI.ERH')
    [IO.File]::WriteAllText((Join-Path $testRoot 'emuera.config'), "LOADTEXTとSAVETEXTで使える拡張子:txt`nロード時に引数を解析する:YES", $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'novelai/runtime/status.txt'), '生成中 <test> & 状態表示', $utf8)
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap(64, 64)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.Clear([Drawing.Color]::Red) } finally { $graphics.Dispose() }
        $bitmap.Save((Join-Path $testRoot 'resources/0-123_会話する (テスト).png'), [Drawing.Imaging.ImageFormat]::Png)
        [void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'resources/NovelAI'))
        $bitmap.Save((Join-Path $testRoot 'resources/NovelAI/456-123_会話する.png'), [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
    $source = [IO.File]::ReadAllText((Join-Path $root 'ERB/追加MOD_NovelAI一枚絵/追加MOD設定_NovelAI.ERB'), $utf8)
    $renderer = [regex]::Match($source, '(?ms)^@サイド描画表示種類_NovelAI\(.*?(?=^@|\z)').Value
    if (-not $renderer) { throw '一枚絵描画関数が見つかりません。' }
    foreach ($name in 'NAI_表示更新', 'NAI_コマンド入力') {
        $function = [regex]::Match($source, ('(?ms)^@' + $name + '(?:\(|\r?\n).*?(?=^@|\z)')).Value
        if (-not $function) { throw "関数が見つかりません: $name" }
        if ($name -eq 'NAI_コマンド入力') {
            # 待機本体はそのまま使い、テスト終了条件と画素の観測だけ追加する。
            $function = $function.Replace('$入力待ち', '$入力待ち' + "`nSIF EXISTFILE(`"finish.txt`")`n    RETURN 0")
            $function = $function.Replace('CALL NAI_表示更新', 'CALL NAI_表示更新' + "`n    SIF GGETCOLOR(19990, 512, 512) == 0xFF0000FF`n        SAVETEXT `"DISPLAYED`", `"displayed.txt`", 0, 1")
        }
        $renderer += "`n" + $function
    }
    $naiSource = [IO.File]::ReadAllText((Join-Path $root 'ERB/追加MOD_NovelAI一枚絵/NovelAI.ERB'), $utf8)
    foreach ($name in 'NAI_項目', 'NAI_キャラ番号', 'NAI_キャラ行', 'NAI_画像取得', 'NAI_画像名', 'NAI_再生成', 'OPTION_NOVELAI', 'NAI_設定値', 'NAI_設定更新', 'OPTION_NOVELAI_CONFIG') {
        $function = [regex]::Match($naiSource, ('(?ms)^@' + $name + '(?:\(|\r?\n).*?(?=^@|\z)')).Value
        if (-not $function) { throw "関数が見つかりません: $name" }
        if ($name -eq 'NAI_画像取得') { $function = $function.Replace('@NAI_画像取得', '@NAI_画像取得_実機テスト') }
        $renderer += "`n" + $function
    }
    $testCode = @'
@SYSTEM_TITLE
#DIMS 本文
#DIMS 追加
#DIMS 前回要求
#DIM 入力前行数
ADDCHARA 0
ADDCHARA 123
MASTER = 0
SIF NAI_キャラ番号(0) != 0 || NAI_キャラ番号(1) != 123
    THROW キャラNOの検索が一致しません。
FLAG:あなたキャラ化記録 = 456
SIF NAI_キャラ番号(0) != 456 || NAI_キャラ番号(1) != 123
    THROW キャラ化したプレイヤーの検索が一致しません。
SIF NAI_キャラ行("player", MASTER) != "player\t0\t456\t主人公\n"
    THROW キャラ番号とゲームからの送信行が一致しません。
SIF NAI_画像名("0-123_会話する (テスト).png") != "0-123_会話する (テスト).png"
    THROW 日本語の画像名を読み込めません。
SIF NAI_画像名("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png"
    THROW 旧画像名を読み込めません。
SIF NAI_画像名("../outside.png") != "" || NAI_画像名("nested/file.png") != ""
    THROW フォルダー外の画像名を拒否できません。
TFLAG:0 = 1
PLAYER = 0
TARGET = 1
コマンド履歴:5 = TARGET
DT_CREATE "体位モードデータベース"
DT_COLUMN_ADD "体位モードデータベース", "モード名"
DT_COLUMN_ADD "体位モードデータベース", "実行キャラ", 3
DT_COLUMN_ADD "体位モードデータベース", "対象キャラ", 3
DT_ROW_ADD "体位モードデータベース", "モード名", "手を繋ぐ", "実行キャラ", PLAYER, "対象キャラ", TARGET
SELECTCOM_NAME履歴:0 = 会話する
CALL NAI_画像取得_実機テスト
SIF RESULT != 1 || RESULTS != "NovelAI/456-123_会話する.png"
    THROW ワーカーの応答なしで保存済み画像を取得できません。
本文 '= LOADTEXT("novelai/runtime/request.txt", 0, 1)
SIF STRFIND(本文, "手を繋ぐ") >= 0 || STRFIND(本文, "mode\t0\t1\t会話する\n") < 0
    THROW 継続動作があっても直近コマンドだけを送信する必要があります。
前回要求 '= NAI_要求ID
SELECTCOM_NAME履歴:0 = 写真を撮る
CALL NAI_画像取得_実機テスト
本文 '= LOADTEXT("novelai/runtime/request.txt", 0, 1)
SIF 前回要求 == NAI_要求ID || STRFIND(本文, "mode\t0\t1\t写真を撮る\n") < 0 || STRFIND(本文, "会話する") >= 0 || STRFIND(本文, "手を繋ぐ") >= 0
    THROW 継続動作を保ったまま直近コマンドを変更できません。
コマンド履歴:5 = -1
CALL NAI_画像取得_実機テスト
本文 '= LOADTEXT("novelai/runtime/request.txt", 0, 1)
SIF STRFIND(本文, "mode\t") >= 0
    THROW 別の対象への履歴を現在の行動に含めています。
DT_CLEAR "体位モードデータベース"
SELECTCOM_NAME履歴:0 =
CALL NAI_画像取得_実機テスト
本文 '= LOADTEXT("novelai/runtime/request.txt", 0, 1)
SIF STRFIND(本文, "mode\t") >= 0 || STRFIND(本文, "action\t") >= 0
    THROW 行動終了後に待機へ戻れません。
NAI_要求ID = 100-1
NAI_前回シーン = player\t0\t456\t主人公\ncharacter\t1\t123\t相手\n
CALL NAI_再生成
SIF !RESULT
    THROW 再生成要求を書き込めません。
; 無効・生成待ち・生成画像ありの3種類。親divの閉鎖後に追加領域を合成。
FOR LOCAL, 0, 3
    TFLAG:0 = LOCAL > 0
    TFLAG:1 = LOCAL == 2
    本文 = <div rect='5525,0,4375,4360'><nobr>
    追加 =
    CALL サイド描画表示種類_NovelAI(本文, 追加)
    SIF STRFIND(追加, "NovelAI設定") < 0 || (TFLAG:0 && STRFIND(追加, "再生成") < 0)
        THROW 画像がなくても設定・再生成ボタンが必要です。
    本文 += "</nobr></div>" + 追加
    HTML_PRINT 本文, 1
NEXT
; 入力待ちのままPNGが到着し、同じ表示キャンバスへ反映されることを確認。
SIF GGETCOLOR(19990, 512, 512) != 0xFFFF0000
    THROW 最初の画像が描画されていません。
サイド描画表示種類 = NovelAI
SETTEXTBOX "unfinished command (text)"
入力前行数 = LINECOUNT
SAVETEXT "READY", "ready.txt", 0, 1
CALL NAI_コマンド入力
SIF GWIDTH(19990) != 1024 || GGETCOLOR(19990, 512, 512) != 0xFF0000FF
    THROW 入力待ち中に再生成画像へ更新されませんでした。
SIF GGETCOLOR(19990, 512, 128) != 0xFF101010 || GGETCOLOR(19990, 512, 384) != 0xFF0000FF
    THROW 横長画像の縦横比が維持されていません。
SIF LINECOUNT != 入力前行数 || GETTEXTBOX() != "unfinished command (text)"
    THROW 自動更新でログ行数または入力途中の文字が変わりました。
SAVETEXT "PASS", "done.txt", 0, 1
QUIT

@NAI_有効
#FUNCTION
RETURNF TFLAG:0
@IS_SAME_ROOM(ARG, ARG:1)
#FUNCTION
RETURNF CFLAG:ARG:現在位置 == CFLAG:(ARG:1):現在位置 && CFLAG:ARG:現在マップ種別 == CFLAG:(ARG:1):現在マップ種別
@NAI_画像取得
RESULTS =
IF TFLAG:1
    RESULTS = 0-123_会話する (テスト).png
    RETURN 1
ENDIF
RETURN 0
@複数人一枚絵_表示処理
RESULTS =
RETURN 0
@GCREATE_拡張子(ARG, ARGS)
GCREATEFROMFILE ARG, ARGS
RETURN RESULT
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/test.ERB'), $testCode + "`n" + $renderer, $utf8)
    # Emueraの入力タイマーはウィンドウの描画後に始まるため、実入力待ちの検証では表示する。
    $process = Start-Process -FilePath (Join-Path $testRoot 'Emuera.exe') -WorkingDirectory $testRoot -WindowStyle Normal -PassThru
    $replaced = $false
    for ($i = 0; $i -lt 40 -and -not (Test-Path (Join-Path $testRoot 'done.txt')); $i++) {
        if (-not $replaced -and (Test-Path (Join-Path $testRoot 'ready.txt'))) {
            $imagePath = Join-Path $testRoot 'resources/0-123_会話する (テスト).png'
            $bitmap = New-Object Drawing.Bitmap(64, 32)
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try { $graphics.Clear([Drawing.Color]::Blue) } finally { $graphics.Dispose() }
                $bitmap.Save($imagePath + '.tmp', [Drawing.Imaging.ImageFormat]::Png)
            } finally { $bitmap.Dispose() }
            [IO.File]::Replace($imagePath + '.tmp', $imagePath, $imagePath + '.bak')
            [IO.File]::Delete($imagePath + '.bak')
            [IO.File]::WriteAllText((Join-Path $testRoot 'replaced.txt'), 'REPLACED', $utf8)
            [IO.File]::WriteAllText((Join-Path $testRoot 'novelai/runtime/regenerate-result.txt'), "500-2`n0-123_会話する (テスト).png`n再生成完了", $utf8)
            $replaced = $true
        }
        if (Test-Path (Join-Path $testRoot 'displayed.txt')) {
            [IO.File]::WriteAllText((Join-Path $testRoot 'finish.txt'), 'FINISH', $utf8)
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path (Join-Path $testRoot 'done.txt'))) {
        if (Test-Path (Join-Path $testRoot 'emuera.log')) { Get-Content -Encoding UTF8 (Join-Path $testRoot 'emuera.log') -Tail 12 }
        throw 'HTML_PRINTの実行テストが完了しませんでした。'
    }
    $regen = @(Get-Content -LiteralPath (Join-Path $testRoot 'novelai/runtime/regenerate.txt') -Encoding UTF8)
    if ($regen.Count -ne 4 -or $regen[0] -ne 'NAIREGEN1' -or $regen[1] -ne '100-1' -or $regen[2] -notmatch '^\d+-\d+$' -or $regen[3] -cne ("END`t" + $regen[2])) {
        throw 'Emueraからの再生成要求形式が一致しません。'
    }
    Write-Host 'PASS: Emuera live image refresh / input text and log preservation / waiting controls / latest action / IDs / regeneration / HTML_PRINT'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $runtime = [IO.Path]::GetFullPath((Join-Path $novelAiDirectory 'runtime')) + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($runtime) -and [IO.Path]::GetFileName($resolved) -match '^render-test-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
