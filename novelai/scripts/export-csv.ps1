# 行動の新規行だけ追加し、既存タグは保持する。
param([switch]$FillMissingTags)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker.ps1') -Library
$directory = $script:NovelAiDirectory
[void][IO.Directory]::CreateDirectory($script:Runtime)

# 日常動作の初期タグ。意味を決められない名前は空欄のまま出力する。
$seeds = @{
    '待機' = 'relaxed pose, spending time together'
    '会話' = 'talking together'; '会話する' = 'talking together'; 'お茶を淹れる' = 'serving tea, teacup'
    'スキンシップ' = 'gentle interaction'; '口説く' = 'talking, smiling'; '知識を教わる' = 'studying together, book'
    'ハグする' = 'hugging'; 'プレゼントを渡す' = 'giving a gift, gift box'; '起こす' = 'waking up, bedroom'
    '頭を撫でる' = 'headpat'; '手を繋ぐ' = 'holding hands'; '手をつなぐ' = 'holding hands'; '握手' = 'handshake'
    'キス' = 'kiss'; 'キスする' = 'kiss'; '頬にキス' = 'kiss on cheek'
    '雑務をこなす' = 'working, casual clothes'; '着替える' = 'choosing clothes, wardrobe'
    '連れ出す' = 'walking together'; 'デートに誘う' = 'talking, smiling'; 'デート' = 'couple, walking together'
    '移動' = 'walking'; '宿泊エリアへ行く' = 'walking, hotel'; '就寝' = 'sleeping, bed'
    '休憩' = 'resting together'; '休憩する' = 'resting together'; '観察する' = 'looking at another person'
    '暇を潰す' = 'relaxing'; '戦闘訓練' = 'training, sparring'; '勉強' = 'studying together, open book'
    '待つ' = 'waiting together'; '散歩する' = 'walking together'; '食事' = 'eating together, dining table'
    '料理' = 'cooking, kitchen'; '料理する' = 'cooking, kitchen'; '釣り' = 'fishing, fishing rod'
    '掃除' = 'cleaning'; '掃除する' = 'cleaning'; '水泳' = 'swimming'; '泳ぐ' = 'swimming'
    '読書' = 'reading a book'; '歌う' = 'singing'; 'ダンス' = 'dancing'; '踊る' = 'dancing'
    '食べる' = 'eating'; '飲む' = 'drinking, cup'; '笑う' = 'smiling'; '相談する' = 'talking together'
    'マッサージ' = 'shoulder massage'; '肩を揉む' = 'shoulder massage'
    '一緒に隠れる' = 'hiding together'; '物陰に隠れる' = 'hiding'; '物陰から出る' = 'stepping out'
    '帰宅する' = 'arriving home'; '家から出る' = 'leaving home'; '部屋から出る' = 'walking through a doorway'
    '店舗から出る' = 'leaving a shop'; '住宅街を訪れる' = 'walking, residential street'
    '商業区を訪れる' = 'walking, shopping district'; '抱き寄せる' = 'embrace'; '恋人繋ぎ' = 'holding hands, interlocked fingers'
    '結婚を申し込む' = 'marriage proposal, ring'; '告白する' = 'talking, blushing'; '告白を受け入れる' = 'smiling, blushing'
    '許しを乞う' = 'apologizing, bowed head'; '盟友の誓い' = 'handshake'; '同行解除' = 'waving goodbye'
    'デートを終える' = 'waving goodbye'; 'デートに割り込む' = 'group conversation'; 'デートに乱入' = 'group conversation'
    'リモコン操作' = 'holding a remote control'; '観光客をナンパ' = 'talking, outdoors'
    '挑発ジェスチャー' = 'taunting gesture'; '特別飼育区から出る' = 'walking'; '特別飼育区へ行く' = 'walking'
}
$actionsPath = Join-Path $directory 'actions.csv'
$existing = @{}
if (Test-Path $actionsPath) {
    foreach ($row in (Read-CsvTable $directory 'actions' @('name', 'scene', 'actor', 'target') 'name')) { $existing[$row.name] = $row }
}
$catalog = @{}
foreach ($name in $seeds.Keys) { $catalog[$name] = $true }
# ゲーム内の定義から取得。表示名が条件で変わる場合は静的に読める全候補を登録する。
foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $script:Root 'ERB/コマンド') -Recurse -File -Filter '*.ERB')) {
    $source = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    $names = @([regex]::Matches($source, '(?m)^\s*TSTR:コマンド名受渡\s*=\s*([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
    $names += @([regex]::Matches($source, '(?m)^@(?:MODE_持続快楽_|MODETYPE_)([^\(\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
    foreach ($name in $names) {
        if (-not $name -or $name -match '[%{}"\\]') { continue }
        $catalog[$name] = $true
    }
}
foreach ($name in $catalog.Keys) {
    if ($existing.ContainsKey($name)) {
        $row = $existing[$name]
        if ($FillMissingTags -and -not ($row.scene -or $row.actor -or $row.target) -and $seeds.ContainsKey($name)) {
            $row.scene = $seeds[$name]
        }
        continue
    }
    $tag = [string]$seeds[$name]
    $existing[$name] = [pscustomobject]@{
        name = $name; scene = $tag; actor = ''; target = ''
    }
}
Write-CsvTable $actionsPath @($existing.Values | Sort-Object name) @('name', 'scene', 'actor', 'target')

& (Join-Path $PSScriptRoot 'export-clothes.ps1') -OutputDirectory $directory
Sync-Settings $directory
$ready = @($existing.Values | Where-Object { $_.scene -or $_.actor -or $_.target }).Count
Write-Host ("CSVを出力しました。行動 {0} 件（タグあり {1} / 要設定 {2}）。既存の編集内容は保持しました。" -f $existing.Count, $ready, ($existing.Count - $ready))
