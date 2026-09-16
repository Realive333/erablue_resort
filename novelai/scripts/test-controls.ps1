# NovelAIタブの設定ボタンを実Emueraで検証。API・セーブへのアクセスなし。
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runtime = Join-Path $root 'novelai/runtime'
$testRoot = Join-Path $runtime ('controls-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($true)
$process = $null
try {
    foreach ($directory in 'CSV', 'ERB', 'resources', 'novelai/runtime') {
        [void][IO.Directory]::CreateDirectory((Join-Path $testRoot $directory))
    }
    $executable = Get-ChildItem -LiteralPath $root -Filter 'Emuera*.exe' | Select-Object -First 1
    New-Item -ItemType HardLink -Path (Join-Path $testRoot 'Emuera.exe') -Value $executable.FullName | Out-Null
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/GameBase.csv'), "コード,1`nバージョン,1`nタイトル,NovelAI Controls Test", $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'emuera.config'), "LOADTEXTとSAVETEXTで使える拡張子:txt`nロード時に引数を解析する:YES", $utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'novelai/runtime/status.txt'), '生成中 <test> & 状態表示', $utf8)
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap(64, 64)
    try { $bitmap.Save((Join-Path $testRoot 'resources/test.png'), [Drawing.Imaging.ImageFormat]::Png) }
    finally { $bitmap.Dispose() }
    $source = [IO.File]::ReadAllText((Join-Path $root 'ERB/追加MOD_NovelAI一枚絵/追加MOD設定_NovelAI.ERB'), $utf8)
    $renderer = [regex]::Match($source, '(?ms)^@サイド描画表示種類_NovelAI\(.*?(?=^@|\z)').Value
    if (-not $renderer) { throw 'NovelAI描画関数が見つかりません。' }
    $testCode = @'
@SYSTEM_TITLE
#DIMS 本文
#DIMS 追加
; 無効・生成待ち・正常画像・画像読込失敗。
FOR LOCAL, 0, 4
    TFLAG:0 = LOCAL > 0
    TFLAG:1 = LOCAL
    本文 = <div rect='5525,0,4375,4360'><nobr>
    追加 =
    CALL サイド描画表示種類_NovelAI(本文, 追加)
    SIF STRFIND(追加, "[NovelAI設定]") < 0 || STRFIND(追加, "[画像更新]") < 0
        THROW 画像の有無にかかわらず設定・更新ボタンが必要です。
    SIF (STRFIND(追加, "[再生成]") >= 0) != TFLAG:0
        THROW 再生成ボタンの表示が有効状態と一致しません。
    SIF (STRFIND(本文, "<img") >= 0) != (LOCAL == 2)
        THROW 正常画像がある場合だけ画像を表示する必要があります。
    本文 += "</nobr></div>" + 追加
    HTML_PRINT 本文, 1
NEXT
SAVETEXT "PASS", "done.txt", 0, 1
QUIT

@NAI_有効
#FUNCTION
RETURNF TFLAG:0
@NAI_画像取得
RESULTS =
IF TFLAG:1 == 2
    RESULTS = test.png
    RETURN 1
ELSEIF TFLAG:1 == 3
    RESULTS = missing.png
    RETURN 1
ENDIF
RETURN 0
@GCREATE_拡張子(ARG, ARGS)
GCREATEFROMFILE ARG, ARGS
RETURN RESULT
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/test.ERB'), $testCode + "`n" + $renderer, $utf8)
    $process = Start-Process -FilePath (Join-Path $testRoot 'Emuera.exe') -WorkingDirectory $testRoot -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 40 -and -not (Test-Path (Join-Path $testRoot 'done.txt')); $i++) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path (Join-Path $testRoot 'done.txt'))) {
        if (Test-Path (Join-Path $testRoot 'emuera.log')) { Get-Content -Encoding UTF8 (Join-Path $testRoot 'emuera.log') -Tail 12 }
        throw '設定ボタンの描画テストが完了しませんでした。'
    }
    Write-Host 'PASS: Emuera settings controls / disabled / waiting / valid image / failed image / HTML_PRINT'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($runtime) + [IO.Path]::DirectorySeparatorChar) -and
        [IO.Path]::GetFileName($resolved) -match '^controls-test-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
