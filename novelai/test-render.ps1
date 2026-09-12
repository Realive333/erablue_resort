# 本体の一枚絵関数をEmueraのHTML_PRINTまで通す。API・セーブへのアクセスなし。
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path $PSScriptRoot ('runtime/render-test-' + [guid]::NewGuid().ToString('N'))
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
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Chara0.csv'), "番号,0`n名前,主人公", $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Chara123.csv'), "番号,123`n名前,相手", $utf8)
    Copy-Item -LiteralPath (Join-Path $root 'ERB/汎用変数定義/NovelAI.ERH') -Destination (Join-Path $testRoot 'ERB/NovelAI.ERH')
    [IO.File]::WriteAllText((Join-Path $testRoot 'emuera.config'), "LOADTEXTとSAVETEXTで使える拡張子:txt`nロード時に引数を解析する:YES", $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'novelai/runtime/status.txt'), '生成中 <test> & 状態表示', $utf8)
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap(64, 64)
    try { $bitmap.Save((Join-Path $testRoot 'resources/0-123_会話する (テスト).png'), [Drawing.Imaging.ImageFormat]::Png) }
    finally { $bitmap.Dispose() }
    $source = [IO.File]::ReadAllText((Join-Path $root 'ERB/サイド領域描画処理.ERB'), $utf8)
    $renderer = [regex]::Match($source, '(?ms)^@サイド描画表示種類_複数人一枚絵\(.*?(?=^@|\z)').Value
    if (-not $renderer) { throw '一枚絵描画関数が見つかりません。' }
    $naiSource = [IO.File]::ReadAllText((Join-Path $root 'ERB/NovelAI.ERB'), $utf8)
    foreach ($name in 'NAI_項目', 'NAI_キャラ番号', 'NAI_キャラ行', 'NAI_画像名', 'NAI_再生成', 'OPTION_NOVELAI', 'NAI_設定値', 'NAI_設定更新', 'OPTION_NOVELAI_CONFIG') {
        $function = [regex]::Match($naiSource, ('(?ms)^@' + $name + '(?:\(|\r?\n).*?(?=^@|\z)')).Value
        if (-not $function) { throw "関数が見つかりません: $name" }
        $renderer += "`n" + $function
    }
    $testCode = @'
@SYSTEM_TITLE
#DIMS 本文
#DIMS 追加
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
    CALL サイド描画表示種類_複数人一枚絵(本文, 追加)
    本文 += "</nobr></div>" + 追加
    HTML_PRINT 本文, 1
NEXT
; 表示中のPNGをワーカー側で置換でき、再描画時に読み直せることを確認。
SAVETEXT "READY", "ready.txt", 0, 1
FOR LOCAL, 0, 40
    SIF EXISTFILE("replaced.txt")
        BREAK
    AWAIT 100
NEXT
本文 = <div rect='5525,0,4375,4360'><nobr>
追加 =
CALL サイド描画表示種類_複数人一枚絵(本文, 追加)
本文 += "</nobr></div>" + 追加
HTML_PRINT 本文, 1
SIF GWIDTH(19990) != 32
    THROW 再生成した画像を再読込できません。
SAVETEXT "PASS", "done.txt", 0, 1
QUIT

@NAI_有効
#FUNCTION
RETURNF TFLAG:0
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
    $process = Start-Process -FilePath (Join-Path $testRoot 'Emuera.exe') -WorkingDirectory $testRoot -WindowStyle Hidden -PassThru
    $replaced = $false
    for ($i = 0; $i -lt 40 -and -not (Test-Path (Join-Path $testRoot 'done.txt')); $i++) {
        if (-not $replaced -and (Test-Path (Join-Path $testRoot 'ready.txt'))) {
            $imagePath = Join-Path $testRoot 'resources/0-123_会話する (テスト).png'
            $bitmap = New-Object Drawing.Bitmap(32, 32)
            try { $bitmap.Save($imagePath + '.tmp', [Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
            [IO.File]::Replace($imagePath + '.tmp', $imagePath, $imagePath + '.bak')
            [IO.File]::Delete($imagePath + '.bak')
            [IO.File]::WriteAllText((Join-Path $testRoot 'replaced.txt'), 'REPLACED', $utf8)
            $replaced = $true
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
    Write-Host 'PASS: Emuera character IDs / image names / regenerate request / image replacement / settings parse / HTML_PRINT'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $runtime = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'runtime')) + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($runtime) -and [IO.Path]::GetFileName($resolved) -match '^render-test-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
