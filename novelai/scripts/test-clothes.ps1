# 実Emueraの着用状態 → 通信 → CSV → 送信プロンプトを隔離環境で検証する。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker.ps1') -Library
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$testRoot = Join-Path $script:Runtime ('clothes-test-' + [guid]::NewGuid().ToString('N'))
$testUtf8 = New-Object Text.UTF8Encoding($true)
$process = $null
try {
    foreach ($directory in 'CSV', 'ERB/通常衣装関連', 'ERB/口上_キャラ個別ERB', 'resources/NovelAI', 'novelai/runtime') { [void][IO.Directory]::CreateDirectory((Join-Path $testRoot $directory)) }
    $executable = Get-ChildItem -LiteralPath $script:Root -Filter 'Emuera*.exe' | Select-Object -First 1
    New-Item -ItemType HardLink -Path (Join-Path $testRoot 'Emuera.exe') -Value $executable.FullName | Out-Null
    foreach ($file in 'Cstr.csv', 'Tequip.csv') {
        Copy-Item -LiteralPath (Join-Path $script:Root ('CSV/' + $file)) -Destination (Join-Path $testRoot ('CSV/' + $file))
    }
    foreach ($file in 'config.json', 'prompts.csv', 'characters.csv', 'actions.csv', 'clothes.csv') {
        Copy-Item -LiteralPath (Join-Path $script:NovelAiDirectory $file) -Destination (Join-Path $testRoot $file)
    }
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/GameBase.csv'), "コード,1`nバージョン,1`nタイトル,NovelAI Clothes Test", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Flag.csv'), '0,あなたキャラ化記録', $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/CFlag.csv'), "300,現在位置`n330,現在マップ種別", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/TFlag.csv'), "221,オートコマンドフラグ`n222,オートコマンド連続発動", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/VariableSize.csv'), "TEQUIP,1000`nTEQUIPNAME,1000", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Chara0.csv'), "番号,0`n名前,主人公", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'CSV/Chara123.csv'), "番号,123`n名前,相手`nCSTR,服名称,キャラ固有服", $testUtf8)
    Copy-Item -LiteralPath (Join-Path $script:Root 'ERB/追加MOD_NovelAI一枚絵/NovelAI.ERH') -Destination (Join-Path $testRoot 'ERB/NovelAI.ERH')
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/test.ERH'), "#DIM コマンド履歴, 50`n#DIMS SELECTCOM_NAME履歴, 5", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'novelai/runtime/enabled.txt'), '1', $testUtf8)
    # 画像取得は存在確認だけ。描画テストはtest-controls.ps1で実施する。
    [IO.File]::WriteAllText((Join-Path $testRoot 'resources/NovelAI/0_普段着_123_メイド服_会話する.png'), 'image fixture', $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'resources/NovelAI/0-123_会話する.png'), 'legacy fixture', $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'emuera.config'), "LOADTEXTとSAVETEXTで使える拡張子:txt`nロード時に引数を解析する:YES", $testUtf8)
    $source = Read-Text (Join-Path $script:Root 'ERB/追加MOD_NovelAI一枚絵/NovelAI.ERB')
    $functions = ''
    foreach ($name in 'NAI_有効', 'NAI_項目', 'NAI_キャラ番号', 'NAI_キャラ行', 'NAI_服装行', 'NAI_画像取得', 'NAI_画像名') {
        $function = [regex]::Match($source, ('(?ms)^@' + $name + '(?:\(|\r?\n).*?(?=^@|\z)')).Value
        Assert ($function -ne '') ("関数がありません: $name")
        $functions += "`n" + $function
    }
    $testCode = @'
@SYSTEM_TITLE
#DIMS 要求
ADDCHARA 0
ADDCHARA 123
MASTER = 0
PLAYER = 0
TARGET = 1
DT_CREATE "体位モードデータベース"
DT_COLUMN_ADD "体位モードデータベース", "モード名"
DT_COLUMN_ADD "体位モードデータベース", "実行キャラ", 3
DT_COLUMN_ADD "体位モードデータベース", "対象キャラ", 3
DT_ROW_ADD "体位モードデータベース", "モード名", "手を繋ぐ", "実行キャラ", PLAYER, "対象キャラ", TARGET
コマンド履歴:5 = TARGET
SELECTCOM_NAME履歴:0 = 会話する
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
; 専用服の名称は追加せず、番号で指定するキャラ衣装も普段着にまとめる。
CSTR:0:着せ替え服 = 123
SIF STRFIND(NAI_服装行(0), "普段着") < 0 || STRFIND(NAI_服装行(0), "キャラ固有服") >= 0
    THROW キャラ固有の衣装名は除外する必要があります。
CSTR:0:着せ替え服 =
; 操作キャラがMASTERと別のキャラでも、その本人の服装を送る。
PLAYER = 1
要求 '= "NAI1\t100-4\n" + NAI_キャラ行("player", PLAYER) + NAI_キャラ行("character", 0) + "END\t100-4"
SAVETEXT 要求, "switched-player.txt", 0, 1
PLAYER = 0
; 旧画像を直接拾わず、現在の要求IDに対するワーカーのファイル名を使う。
CALL NAI_画像取得
SIF RESULT
    THROW 服装を含まない旧画像を再利用しています。
要求 '= LOADTEXT("novelai/runtime/request.txt", 0, 1)
SIF STRFIND(要求, "action\t会話する") < 0 || STRFIND(要求, "mode\t") >= 0 || STRFIND(要求, "手を繋ぐ") >= 0
    THROW 継続行動ではなく直近のコマンドを送信する必要があります。
SAVETEXT 要求, "command-scene.txt", 0, 1
; 継続モードを変えずにコマンドだけ変更した場合も要求を更新する。
SELECTCOM_NAME履歴:0 = 散歩する
CALL NAI_画像取得
要求 '= LOADTEXT("novelai/runtime/request.txt", 0, 1)
SIF STRFIND(要求, "action\t散歩する") < 0 || STRFIND(要求, "会話する") >= 0
    THROW コマンドの変更が反映されていません。
SAVETEXT 要求, "changed-command-scene.txt", 0, 1
; コマンドが未実行なら継続モードがあっても行動を送らない。
SELECTCOM_NAME履歴:0 =
CALL NAI_画像取得
要求 '= LOADTEXT("novelai/runtime/request.txt", 0, 1)
SIF STRFIND(要求, "action\t") >= 0 || STRFIND(要求, "mode\t") >= 0
    THROW 未実行のコマンドを継続行動で補完しています。
SAVETEXT 要求, "idle-command-scene.txt", 0, 1
SELECTCOM_NAME履歴:0 = 会話する
CALL NAI_画像取得
SAVETEXT @"%NAI_要求ID%\n0_普段着_123_メイド服_会話する.png", "novelai/runtime/response.txt", 0, 1
CALL NAI_画像取得
SIF RESULT != 1 || RESULTS != "NovelAI/0_普段着_123_メイド服_会話する.png"
    THROW 新しい名前の画像をゲームへ反映できません。
; 上着だけを脱ぐと、下着は上側だけを追加する。
TEQUIP:1:上半身服あり = 0
CALL NAI_画像取得
SIF RESULT
    THROW 着替える前の画像応答を再利用しています。
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

@IS_SAME_ROOM(ARG, ARG:1)
#FUNCTION
RETURNF CFLAG:ARG:現在位置 == CFLAG:(ARG:1):現在位置 && CFLAG:ARG:現在マップ種別 == CFLAG:(ARG:1):現在マップ種別
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/test.ERB'), $testCode + $functions, $testUtf8)
    $process = Start-Process -FilePath (Join-Path $testRoot 'Emuera.exe') -WorkingDirectory $testRoot -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 40 -and -not (Test-Path (Join-Path $testRoot 'done.txt')); $i++) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path (Join-Path $testRoot 'done.txt'))) {
        if (Test-Path (Join-Path $testRoot 'emuera.log')) { Get-Content -Encoding UTF8 (Join-Path $testRoot 'emuera.log') -Tail 15 }
        throw 'Emueraの服装抽出テストが完了しませんでした。'
    }
    $scene = Read-Scene (Read-Text (Join-Path $testRoot 'dressed.txt'))
    $commandScene = Read-Scene (Read-Text (Join-Path $testRoot 'command-scene.txt'))
    $changedCommand = Read-Scene (Read-Text (Join-Path $testRoot 'changed-command-scene.txt'))
    $idleCommand = Read-Scene (Read-Text (Join-Path $testRoot 'idle-command-scene.txt'))
    Assert ($commandScene.Action -ceq '会話する' -and (Get-ImageName $commandScene) -ceq '0_普段着_123_メイド服_会話する.png') 'ゲームからワーカーまでユーザーのコマンドで画像名を決定'
    Assert ($changedCommand.Action -ceq '散歩する' -and $changedCommand.Id -ne $commandScene.Id -and (Get-ImageName $changedCommand) -ceq '0_普段着_123_メイド服_散歩する.png') '継続モードが同じでもコマンド変更で要求IDと画像名が変わる'
    Assert ($idleCommand.Action -ceq '' -and (Get-ImageName $idleCommand) -ceq '0_普段着_123_メイド服_待機.png') '未実行時は継続行動の代わりに待機'
    Assert ($scene.Clothes.Count -eq 2) 'プレイヤーと相手の衣装を個別に抽出'
    Assert ($scene.Clothes[0].Name -ceq '普段着' -and $scene.Clothes[1].Name -ceq 'メイド服') '固有の服名称を除外し、共通の服装名を取得'
    Assert ($null -eq (Read-Scene ((Read-Text (Join-Path $testRoot 'dressed.txt')).Replace("clothes`t1", "clothes`t9")))) '場面にいないキャラの衣装を拒否'
    $characterPath = Join-Path $testRoot 'characters.csv'
    $characterRows = @(
        [pscustomobject]@{ no = '0'; prompt = 'player identity'; default_outfit = 'default outfit' }
        [pscustomobject]@{ no = '123'; prompt = 'partner identity'; default_outfit = 'partner default outfit' }
    )
    Write-CsvTable $characterPath $characterRows @('no', 'prompt', 'default_outfit')
    $data = Read-PromptData $testRoot
    $data.Prompts.negative = 'negative-log-sentinel'
    $data.Clothes['普段着'] = 'unused shared outfit'
    $data.Clothes['メイド服'] = 'maid outfit'
    $data.Clothes['全裸'] = 'nude'
    $data.Clothes['上半身下着_1'] = 'bra'
    $data.Clothes['下半身下着_1'] = 'underwear'
    $config = Read-Text (Join-Path $testRoot 'config.json') | ConvertFrom-Json
    $config.backend = 'novelai'; $config.model = 'nai-diffusion-5-full'; $config.prompt_format = 'auto'
    $spec = New-Payload $scene $config $testRoot $data
    $captions = $spec.Payload.parameters.v4_prompt.caption.char_captions
    Assert ($captions[0].char_caption -ceq 'partner identity, maid outfit' -and $captions[1].char_caption -ceq 'player identity, default outfit') 'API順変更後も操作キャラを含む本人の衣装だけを追加'
    $promptLog = (@(& { Write-PromptLog $spec } 6>&1) | Out-String)
    Assert ($promptLog.Contains('    服装 [メイド服]: maid outfit') -and $promptLog.Contains('    服装 [普段着]: default outfit')) '服装名と実際の服装プロンプトを独立した行で表示'
    Assert ($promptLog.Contains('NO=0 / 操作キャラ') -and $promptLog.Contains('NO=123 / 相手キャラ')) 'キャラの送信順を変えても操作キャラと相手の表記を維持'
    Assert ($promptLog -notmatch 'negative-log-sentinel|ネガティブ') '服装ログにネガティブを含めない'
    Assert ((Get-ImageName $scene) -ceq '0_普段着_123_メイド服_待機.png') '画像名に本人のIDと服装を交互に含める'
    $bothDefaults = Read-Scene ((Read-Text (Join-Path $testRoot 'dressed.txt')).Replace("clothes`t1`tメイド服", "clothes`t1`t普段着"))
    $defaultSpec = New-Payload $bothDefaults $config $testRoot $data
    Assert ($defaultSpec.CharacterPrompts[0].Prompt -ceq 'partner identity, partner default outfit' -and $defaultSpec.CharacterPrompts[1].Prompt -ceq 'player identity, default outfit') '操作キャラ・相手とも普段着はキャラNOごとの設定を使用'
    Assert (-not $defaultSpec.Prompt.Contains('unused shared outfit')) 'clothes.csvの普段着は参照しない'
    $data.DefaultOutfits['0'] = ' '
    $emptyDefault = New-Payload $scene $config $testRoot $data
    Assert ($emptyDefault.CharacterPrompts[1].Prompt -ceq 'player identity') '普段着の空欄を共通服や他キャラの服で補完しない'
    $promptLog = (@(& { Write-PromptLog $emptyDefault } 6>&1) | Out-String)
    Assert ($promptLog.Contains('characters.csv の default_outfit、追加なし')) '普段着が空欄の場合は編集すべき列をログに表示'
    $data.DefaultOutfits['0'] = 'default outfit'
    $unregistered = Read-Scene ((Read-Text (Join-Path $testRoot 'dressed.txt')).Replace("player`t0`t0", "player`t0`t9999"))
    $missingDefault = New-Payload $unregistered $config $testRoot $data
    Assert ($missingDefault.CharacterPrompts[1].Clothes[0].Prompt -ceq '' -and $missingDefault.UnknownClothes -contains '普段着（NO=9999, characters.csv:default_outfit）') '未登録キャラの普段着は追加せずNO付きで通知'
    $switched = Read-Scene (Read-Text (Join-Path $testRoot 'switched-player.txt'))
    $switchedSpec = New-Payload $switched $config $testRoot $data
    Assert ($switchedSpec.Payload.parameters.v4_prompt.caption.char_captions[1].char_caption -ceq 'partner identity, maid outfit') '操作キャラ切替後にも本人の服装プロンプトを適用'
    Assert ((Get-ImageName $switched) -ceq '123_メイド服_0_普段着_待機.png') '画像名はMASTERではなく現在の操作キャラを先頭にする'
    foreach ($name in 'underwear', 'naked') {
        $changed = Read-Scene (Read-Text (Join-Path $testRoot ($name + '.txt')))
        $changedSpec = New-Payload $changed $config $testRoot $data
        $expected = if ($name -eq 'underwear') { 'partner identity, bra, underwear' } else { 'partner identity, nude' }
        Assert ($changedSpec.Payload.parameters.v4_prompt.caption.char_captions[0].char_caption -ceq $expected) '脱衣後は元の衣装を残さない'
        $expectedFile = if ($name -eq 'underwear') { '0_普段着_123_上半身下着_1+下半身下着_1_待機.png' } else { '0_普段着_123_全裸_待機.png' }
        Assert ((Get-ImageName $changed) -ceq $expectedFile -and (Get-ImageName $changed) -cne (Get-ImageName $scene)) '脱衣後は服装を含む別の画像名にする'
    }
    foreach ($backend in 'novelai', 'forge', 'comfyui') {
        $config.backend = $backend; $config.model = 'nai-diffusion-3'
        $flat = New-Payload $scene $config $testRoot $data
        Assert ($flat.Prompt -match 'partner identity, maid outfit, player identity, default outfit') 'V3・ローカル生成にも操作キャラと相手の服装を追加'
        $promptLog = (@(& { Write-PromptLog $flat } 6>&1) | Out-String)
        Assert ($promptLog.Contains('服装 [メイド服]: maid outfit') -and $promptLog.Contains('服装 [普段着]: default outfit') -and $promptLog -notmatch 'negative-log-sentinel|ネガティブ') 'V3・ローカルでも服装ログを表示しネガティブは非表示'
        Assert ((Join-Tags (@($flat.BasePrompt) + @($flat.CharacterPrompts.Prompt))) -ceq $flat.Prompt) '表示した全体・キャラ別の内訳が実送信プロンプトと一致'
    }
    $blank = Read-Scene "NAI1`t200-1`nplayer`t0`t0`t主人公`ncharacter`t1`t123`t相手`nclothes`t1`t未登録服`nEND`t200-1"
    $unknown = New-Payload $blank $config $testRoot $data
    Assert ($unknown.UnknownClothes -contains '未登録服') '未登録服をログ用に収集'
    $promptLog = (@(& { Write-PromptLog $unknown } 6>&1) | Out-String)
    Assert ($promptLog.Contains('服装 [未登録服]: 未登録または空欄（追加なし）')) '服装タグがない場合は追加されない理由を表示'
    $editedOutfit = "custom outfit, `"quoted`"`n日本語"
    $characterRows[0].default_outfit = $editedOutfit
    Write-CsvTable $characterPath $characterRows @('no', 'prompt', 'default_outfit')
    $reloadedSpec = New-Payload $scene $config $testRoot
    Assert ($reloadedSpec.CharacterPrompts[1].Clothes[0].Prompt -ceq $editedOutfit) 'CSV直接編集した普段着を次回の組立に反映'
    Update-Setting $testRoot 'characters' '0' 'edited player identity'
    Update-Setting $testRoot 'characters' '9999' 'new character identity'
    $updatedCharacters = Read-PromptData $testRoot
    Assert ($updatedCharacters.Characters['0'] -ceq 'edited player identity' -and $updatedCharacters.DefaultOutfits['0'] -ceq $editedOutfit -and $updatedCharacters.DefaultOutfits['123'] -ceq 'partner default outfit') 'ゲーム内の外見編集と行追加で普段着列を消さない'
    Assert ($updatedCharacters.DefaultOutfits['9999'] -ceq '') 'ゲーム内で追加したキャラの普段着は空欄'
    $rows = @(Import-Csv -LiteralPath (Join-Path $testRoot 'clothes.csv') -Encoding UTF8 | Where-Object name -ne '普段着')
    ($rows | Where-Object name -eq 'メイド服').prompt = 'edited maid outfit'
    $rows += [pscustomobject]@{ name = '『碧』の竜服'; prompt = 'exclusive outfit'; source = 'CSV/キャラデータ/Chara12 ワムデュス.csv'; status = 'test' }
    $rows += [pscustomobject]@{ name = '固有キャラ衣装'; prompt = 'exclusive costume'; source = '口上_キャラ個別ERB/test.ERB'; status = 'test' }
    $rows += [pscustomobject]@{ name = '普段着'; prompt = 'unused shared outfit' }
    Write-CsvTable (Join-Path $testRoot 'clothes.csv') $rows @('name', 'prompt', 'source', 'status')
    Assert ((Read-PromptData $testRoot).Clothes['メイド服'] -ceq 'edited maid outfit') '服装CSVの編集を次回読み込みで反映'
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/通常衣装関連/catalog.ERB'), "@CLOTHES_CHANGE_テスト衣装(ARG)`nCSTR:ARG:服名称 '= `"共通の普段着`"`nCSTR:ARG:着せ替え服追加名 =`nRETURN 0", $testUtf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/口上_キャラ個別ERB/catalog.ERB'), '@CLOTHES_CHANGE_固有キャラ衣装(ARG)', $testUtf8)
    [IO.File]::AppendAllText((Join-Path $testRoot 'CSV/Chara0.csv'), "`nCSTR,服名称,固有の普段着", $testUtf8)
    & (Join-Path $PSScriptRoot 'export-clothes.ps1') -OutputDirectory $testRoot -CatalogRoot (Join-Path $testRoot 'ERB/通常衣装関連')
    $updated = Read-PromptData $testRoot
    Assert ($updated.Clothes['メイド服'] -ceq 'edited maid outfit') '一覧再出力でユーザー編集を保持'
    Assert (-not $updated.Clothes.ContainsKey('普段着')) '一覧再出力で共通の普段着行を復活させない'
    Assert ($updated.Clothes['テスト衣装'] -ceq 'テスト衣装' -and $updated.Clothes['共通の普段着'] -ceq '共通の普段着') '共通ERBの服装定義を抽出'
    Assert (-not $updated.Clothes.ContainsKey('『碧』の竜服') -and -not $updated.Clothes.ContainsKey('固有の普段着') -and -not $updated.Clothes.ContainsKey('固有キャラ衣装')) '既存行・CSV・ERBからキャラ専用衣装を除外'
    Assert (-not $updated.Clothes.ContainsKey('RETURN 0')) '空欄の定義で次の行を服装名にしない'
    $exported = @(Import-Csv -LiteralPath (Join-Path $testRoot 'clothes.csv') -Encoding UTF8)
    Assert (($exported[0].PSObject.Properties.Name -join ',') -ceq 'name,prompt') '服装CSVは名前とプロンプトだけ出力'

    # 実際の一括出力を隔離コピーで実行し、旧形式からの整理と新形式での再出力を確認。
    $exportDirectory = Join-Path $testRoot 'novelai'
    [void][IO.Directory]::CreateDirectory((Join-Path $exportDirectory 'scripts'))
    [void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'ERB/コマンド'))
    foreach ($file in 'worker.ps1', 'settings.ps1', 'export-csv.ps1', 'export-clothes.ps1') {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $exportDirectory ('scripts/' + $file))
    }
    foreach ($file in 'config.json', 'prompts.csv', 'characters.csv', 'clothes.csv') {
        Copy-Item -LiteralPath (Join-Path $testRoot $file) -Destination (Join-Path $exportDirectory $file)
    }
    $editedTag = "edited, `"quoted`"`n日本語"
    $actions = @(
        [pscustomobject]@{ name = '会話する'; scene = $editedTag; actor = 'speaker'; target = 'listener'; source = 'old'; status = '設定済み' }
        [pscustomobject]@{ name = '待機'; scene = ''; actor = ''; target = ''; source = 'old'; status = '要設定' }
    )
    $actionsPath = Join-Path $exportDirectory 'actions.csv'
    Write-CsvTable $actionsPath $actions @('name', 'scene', 'actor', 'target', 'source', 'status')
    [IO.File]::WriteAllText((Join-Path $testRoot 'ERB/コマンド/catalog.ERB'), 'TSTR:コマンド名受渡 = 新しい行動', $testUtf8)
    & (Join-Path $exportDirectory 'scripts/export-csv.ps1')
    $actions = @(Import-Csv -LiteralPath $actionsPath -Encoding UTF8)
    Assert (($actions[0].PSObject.Properties.Name -join ',') -ceq 'name,scene,actor,target') '行動CSVは識別名とプロンプトだけ出力'
    Assert (($actions | Where-Object name -eq '待機').scene -ceq '') '通常の出力では空欄も保持'
    Assert ($actions.name -contains '新しい行動') '新規行動を抽出'
    & (Join-Path $exportDirectory 'scripts/export-csv.ps1') -FillMissingTags
    $reloaded = Read-PromptData $exportDirectory
    Assert ($reloaded.Actions['会話する'].scene -ceq $editedTag -and $reloaded.Actions['会話する'].actor -ceq 'speaker' -and $reloaded.Actions['会話する'].target -ceq 'listener') '新形式での再出力でも全プロンプトを保持'
    Assert ($reloaded.Actions['待機'].scene -ceq 'relaxed pose, spending time together') '明示した場合だけ空欄を初期タグで補完'
    Assert ($reloaded.Clothes['メイド服'] -ceq 'edited maid outfit') '服装CSVの2列形式での再出力でも編集を保持'
    Assert ($reloaded.DefaultOutfits['0'] -ceq $editedOutfit -and -not $reloaded.Clothes.ContainsKey('普段着')) '一括再出力でもキャラ別の普段着と共通服の分離を保持'
    Write-Host 'PASS: Emuera current clothes / per-character default outfits / CSV reload / game edit preservation / repeated export'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($script:Runtime) + [IO.Path]::DirectorySeparatorChar) -and
        [IO.Path]::GetFileName($resolved) -match '^clothes-test-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
