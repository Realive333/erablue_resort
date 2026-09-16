# 実Emueraの着用状態 → 通信 → CSV → 送信プロンプトを隔離環境で検証する。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker.ps1') -Library
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$testRoot = Join-Path $script:Runtime ('clothes-test-' + [guid]::NewGuid().ToString('N'))
$testUtf8 = New-Object Text.UTF8Encoding($true)
$process = $null
try {
    foreach ($directory in 'CSV', 'ERB', 'resources') { [void][IO.Directory]::CreateDirectory((Join-Path $testRoot $directory)) }
    $executable = Get-ChildItem -LiteralPath $script:Root -Filter 'Emuera*.exe' | Select-Object -First 1
    New-Item -ItemType HardLink -Path (Join-Path $testRoot 'Emuera.exe') -Value $executable.FullName | Out-Null
    foreach ($file in 'Cstr.csv', 'Tequip.csv', '今日の服装.csv') {
        Copy-Item -LiteralPath (Join-Path $script:Root ('CSV/' + $file)) -Destination (Join-Path $testRoot ('CSV/' + $file))
    }
    foreach ($file in 'config.json', 'prompts.csv', 'characters.csv', 'actions.csv', 'clothes.csv') {
        Copy-Item -LiteralPath (Join-Path $script:NovelAiDirectory $file) -Destination (Join-Path $testRoot $file)
    }
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/GameBase.csv'), "コード,1`nバージョン,1`nタイトル,NovelAI Clothes Test", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Flag.csv'), '0,あなたキャラ化記録', $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/VariableSize.csv'), "TEQUIP,1000`nTEQUIPNAME,1000", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Chara0.csv'), "番号,0`n名前,主人公", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Chara123.csv'), "番号,123`n名前,相手`nCSTR,服名称,キャラ固有服", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/test.ERH'), '#DIMS CHARADATA 今日の服装, 30', $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'emuera.config'), "LOADTEXTとSAVETEXTで使える拡張子:txt`nロード時に引数を解析する:YES", $testUtf8)
    $source = Read-Text (Join-Path $script:Root 'ERB/追加MOD_NovelAI一枚絵/NovelAI.ERB')
    $functions = ''
    foreach ($name in 'NAI_項目', 'NAI_キャラ番号', 'NAI_キャラ行', 'NAI_服装行') {
        $function = [regex]::Match($source, ('(?ms)^@' + $name + '\(.*?(?=^@|\z)')).Value
        Assert ($function -ne '') ("関数がありません: $name")
        $functions += "`n" + $function
    }
    $testCode = @'
@SYSTEM_TITLE
#DIMS 要求
ADDCHARA 0
ADDCHARA 123
MASTER = 0
TEQUIP:0:上半身服あり = 1
TEQUIP:0:下半身服あり = 1
CSTR:0:服名称 = 組織の戦闘服・真紅
CSTR:1:服名称 = 相手の普段着
CSTR:1:着せ替え服 = メイド服
TEQUIP:1:上半身服あり = 1
TEQUIP:1:下半身服あり = 1
TEQUIP:1:上半身下着あり = 1
TEQUIP:1:下半身下着あり = 1
要求 '= "NAI1\t100-1\n" + NAI_キャラ行("player", 0) + NAI_キャラ行("character", 1) + "END\t100-1"
SAVETEXT 要求, "dressed.txt", 0, 1
; 番号で指定するキャラ衣装は、そのキャラの服名称へ変換する。
CSTR:0:着せ替え服 = 123
SIF STRFIND(NAI_服装行(0), "キャラ固有服") < 0
    THROW キャラ衣装の番号から服名称を取得できません。
CSTR:0:着せ替え服 =
; 上着だけを脱ぐと、下着は上側だけを追加する。
TEQUIP:1:上半身服あり = 0
SIF STRFIND(NAI_服装行(1), "上半身下着_1") < 0 || STRFIND(NAI_服装行(1), "下半身下着_1") >= 0
    THROW 脱いだ部位だけ下着を追加する必要があります。
TEQUIP:1:下半身服あり = 0
要求 '= "NAI1\t100-2\n" + NAI_キャラ行("player", 0) + NAI_キャラ行("character", 1) + "END\t100-2"
SAVETEXT 要求, "underwear.txt", 0, 1
TEQUIP:1:上半身下着あり = 0
TEQUIP:1:下半身下着あり = 0
要求 '= "NAI1\t100-3\n" + NAI_キャラ行("player", 0) + NAI_キャラ行("character", 1) + "END\t100-3"
SAVETEXT 要求, "naked.txt", 0, 1
; 別衣装に替えた後も、古い服装名を送らない。
TEQUIP:1:下半身服あり = 1
CSTR:1:着せ替え服 = 水着
CSTR:1:着せ替え服追加名 = ビキニ
SIF STRFIND(NAI_服装行(1), "メイド服") >= 0 || STRFIND(NAI_服装行(1), "ビキニ") < 0 || STRFIND(NAI_服装行(1), "上半身裸") < 0
    THROW 着替え・追加名・露出が反映されていません。
; 通信を区切る文字を服名に混入させない。
CSTR:1:着せ替え服 = 名前\t追加\n改行
SIF STRFIND(NAI_服装行(1), "名前 追加 改行") < 0
    THROW 服装名の改行とタブを除去できません。
SAVETEXT "PASS", "done.txt", 0, 1
QUIT
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/test.ERB'), $testCode + $functions, $testUtf8)
    $process = Start-Process -FilePath (Join-Path $testRoot 'Emuera.exe') -WorkingDirectory $testRoot -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 40 -and -not (Test-Path (Join-Path $testRoot 'done.txt')); $i++) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path (Join-Path $testRoot 'done.txt'))) {
        if (Test-Path (Join-Path $testRoot 'emuera.log')) { Get-Content -Encoding UTF8 (Join-Path $testRoot 'emuera.log') -Tail 15 }
        throw 'Emueraの服装抽出テストが完了しませんでした。'
    }
    $scene = Read-Scene (Read-Text (Join-Path $testRoot 'dressed.txt'))
    Assert ($scene.Clothes.Count -eq 2) 'プレイヤーと相手の衣装を個別に抽出'
    Assert ($scene.Clothes[0].Name -ceq '組織の戦闘服・真紅' -and $scene.Clothes[1].Name -ceq 'メイド服') '普段着名と着せ替え服名を取得'
    Assert ($null -eq (Read-Scene ((Read-Text (Join-Path $testRoot 'dressed.txt')).Replace("clothes`t1", "clothes`t9")))) '場面にいないキャラの衣装を拒否'
    $data = Read-PromptData $testRoot
    $data.Characters['0'] = 'player identity'
    $data.Characters['123'] = 'partner identity'
    $data.Clothes['組織の戦闘服・真紅'] = 'red combat outfit'
    $data.Clothes['メイド服'] = 'maid outfit'
    $data.Clothes['全裸'] = 'nude'
    $data.Clothes['上半身下着_1'] = 'bra'
    $data.Clothes['下半身下着_1'] = 'underwear'
    $config = Read-Text (Join-Path $testRoot 'config.json') | ConvertFrom-Json
    $config.backend = 'novelai'; $config.model = 'nai-diffusion-5-full'; $config.prompt_format = 'auto'
    $spec = New-Payload $scene $config $testRoot $data
    $captions = $spec.Payload.parameters.v4_prompt.caption.char_captions
    Assert ($captions[0].char_caption -ceq 'partner identity, maid outfit' -and $captions[1].char_caption -ceq 'player identity, red combat outfit') 'API順変更後も本人の衣装だけを追加'
    foreach ($name in 'underwear', 'naked') {
        $changed = Read-Scene (Read-Text (Join-Path $testRoot ($name + '.txt')))
        $changedSpec = New-Payload $changed $config $testRoot $data
        $expected = if ($name -eq 'underwear') { 'partner identity, bra, underwear' } else { 'partner identity, nude' }
        Assert ($changedSpec.Payload.parameters.v4_prompt.caption.char_captions[0].char_caption -ceq $expected) '脱衣後は元の衣装を残さない'
        Assert ((Get-ImageName $changed) -ceq (Get-ImageName $scene)) '既存のID・行動名キャッシュ規則を維持'
    }
    foreach ($backend in 'novelai', 'forge', 'comfyui') {
        $config.backend = $backend; $config.model = 'nai-diffusion-3'
        $flat = New-Payload $scene $config $testRoot $data
        Assert ($flat.Prompt -match 'partner identity, maid outfit, player identity, red combat outfit') 'V3・ローカル生成にも本人の服装を追加'
    }
    $blank = Read-Scene "NAI1`t200-1`nplayer`t0`t0`t主人公`ncharacter`t1`t123`t相手`nclothes`t1`t未登録服`nEND`t200-1"
    $unknown = New-Payload $blank $config $testRoot $data
    Assert ($unknown.UnknownClothes -contains '未登録服') '未登録服をログ用に収集'
    $rows = @(Import-Csv -LiteralPath (Join-Path $testRoot 'clothes.csv') -Encoding UTF8)
    ($rows | Where-Object name -eq 'メイド服').prompt = 'edited maid outfit'
    Write-CsvTable (Join-Path $testRoot 'clothes.csv') $rows @('name', 'prompt', 'source', 'status')
    Assert ((Read-PromptData $testRoot).Clothes['メイド服'] -ceq 'edited maid outfit') '服装CSVの編集を次回読み込みで反映'
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/catalog.ERB'), "@CLOTHES_CHANGE_テスト衣装(ARG)`nCSTR:ARG:服名称 '= `"別の普段着`"`nCSTR:ARG:着せ替え服追加名 =`nRETURN 0", $testUtf8)
    [IO.File]::AppendAllText((Join-Path $testRoot 'CSV/Chara0.csv'), "`nCSTR,服名称,固有の普段着", $testUtf8)
    & (Join-Path $PSScriptRoot 'export-clothes.ps1') -OutputDirectory $testRoot -CatalogRoot (Join-Path $testRoot 'ERB') -CharacterDirectory (Join-Path $testRoot 'CSV')
    $updated = Read-PromptData $testRoot
    Assert ($updated.Clothes['メイド服'] -ceq 'edited maid outfit') '一覧再出力でユーザー編集を保持'
    Assert ($updated.Clothes['テスト衣装'] -ceq 'テスト衣装' -and $updated.Clothes['別の普段着'] -ceq '別の普段着' -and $updated.Clothes['固有の普段着'] -ceq '固有の普段着') 'ERBとキャラCSVの新しい定義を抽出'
    Assert (-not $updated.Clothes.ContainsKey('RETURN 0')) '空欄の定義で次の行を服装名にしない'
    Write-Host 'PASS: Emuera current clothes / undressing / per-character prompts / V3-V5 and local / CSV reload / export preservation'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($script:Runtime) + [IO.Path]::DirectorySeparatorChar) -and
        [IO.Path]::GetFileName($resolved) -match '^clothes-test-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
