# ERBの衣装定義から一覧を作成する。再実行しても編集済みpromptは上書きしない。
param([string]$OutputDirectory, [string]$CatalogRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker.ps1') -Library
if (-not $OutputDirectory) { $OutputDirectory = $script:NovelAiDirectory }
if (-not $CatalogRoot) { $CatalogRoot = Join-Path $script:Root 'ERB/通常衣装関連' }
$seeds = @{
    'おしゃれ着' = 'formal clothes'
    '全裸' = 'nude'; '上半身裸' = 'topless'; '下半身裸' = 'bottomless'
    '上タイツ' = 'bodystocking'; '下タイツ' = 'pantyhose'
    '上半身下着_1' = 'bra'; '上半身下着_2' = 'pasties'; '上半身下着_3' = 'sarashi'; '上半身下着_4' = 'ribbon bra'
    '上半身下着_-1' = 'open-cup bra'; '上半身下着_-2' = 'nipple piercings'; '上半身下着_-3' = 'nipple tags'
    '下半身下着_1' = 'underwear'; '下半身下着_2' = 'maebari'; '下半身下着_3' = 'fundoshi'; '下半身下着_4' = 'ribbon panties'
    '下半身下着_-1' = 'crotchless underwear'; '下半身下着_-2' = 'genital piercing'; '下半身下着_-3' = 'genital tag'
    '学生服' = 'school uniform'; '体操着' = 'gym uniform'; 'メイド服' = 'maid outfit'; 'ミニメイド服' = 'maid outfit, miniskirt'
    'バニー服' = 'bunny suit'; '逆バニー' = 'reverse bunny suit'; 'ナース服' = 'nurse uniform'
    'リゾート従業員制服' = 'hotel staff uniform'; 'リゾート警備制服' = 'security guard uniform'
    '喫茶店従業員服' = 'cafe uniform, apron'; '喫茶店従業員服（特殊業務）' = 'cafe uniform, apron'
    'つやつや従業員制服' = 'shiny clothes, hotel staff uniform'; 'つやつや光沢服' = 'shiny clothes'
    '浴衣' = 'yukata'; '晴れ着' = 'kimono'; 'バスローブ' = 'bathrobe'; '湯上がり' = 'bathrobe'
    '湯浴み着' = 'towel, wrapped towel'; '部屋着' = 'loungewear'; 'マッサージ着' = 'massage robe'
    '水着' = 'swimsuit'; 'ビキニ' = 'bikini'; 'ワンピース' = 'one-piece swimsuit'; 'ボーイレッグ・ビキニ' = 'bikini, boyshorts'
    'プランジングネック' = 'one-piece swimsuit, plunging neckline'; 'マイクロビキニ' = 'micro bikini'; 'スリングショット' = 'slingshot swimsuit'
    'ウエディングドレス' = 'wedding dress'; 'ウエディングビキニ' = 'bridal bikini, bridal veil'; 'ホワイトタキシード' = 'white tuxedo'
    'ロングドレス' = 'long dress'; 'チャイナドレス' = 'china dress'; 'ミニチャイナ' = 'short china dress'
    '修道服' = 'nun habit'; '破戒修道服' = 'revealing nun habit'; '巫女装束' = 'miko outfit'
    'セクシー巫女服' = 'revealing miko outfit'; 'スーパーセクシー巫女服' = 'revealing miko outfit'
    'チアリーダー' = 'cheerleader outfit'; 'セクシーチア' = 'cheerleader outfit'; 'サキュバスチアコス' = 'succubus costume, cheerleader outfit'
    'セクシーポリス' = 'police uniform'; '逮捕しちゃうゾ' = 'police uniform'; 'セクシーキョンシー' = 'jiangshi costume'
    'ミニスカサンタ' = 'santa costume, miniskirt'; 'サンバ衣装' = 'samba costume'; 'ディアンドル' = 'dirndl'
    'レオタード' = 'leotard'; 'シースルーレオタード' = 'see-through leotard'; 'すけすけボディースーツ' = 'see-through bodysuit'
    'バスケユニ' = 'basketball uniform'; 'ヨガウェア' = 'yoga clothes'; 'アメスク' = 'american school uniform'
    'バージンキラーセーター' = 'virgin killer sweater'; 'バックレスセーター' = 'backless sweater'; 'フロントオープンセーター' = 'front cutout sweater'
    'チェリーハントセーター' = 'cutout sweater'; '白いワンピース' = 'white dress'; '普通のオーバーオール' = 'overalls'
    '裸ミニスカオーバーオール' = 'overall skirt, no shirt'; '裸エプロン' = 'naked apron'; '裸リボン' = 'ribbon, nude'
    '常夏のアロハスタイル' = 'hawaiian shirt'; '淫蕩のアロハスタイル' = 'open hawaiian shirt'
    'セクシーランジェリー' = 'lingerie'; 'キャットランジェリー' = 'cat lingerie'; '拘束服' = 'straitjacket'
    'スモック' = 'smock'; 'クマの着ぐるみ' = 'bear kigurumi'; 'ゴールデンバブリードレス' = 'gold dress'
}
$path = Join-Path $OutputDirectory 'clothes.csv'
$existing = @{}
if (Test-Path -LiteralPath $path) {
    foreach ($row in (Read-CsvTable $OutputDirectory 'clothes' @('name', 'prompt') 'name')) { $existing[$row.name] = $row }
}
$catalog = @{}
foreach ($name in $seeds.Keys) { $catalog[$name] = $true }
foreach ($file in (Get-ChildItem -LiteralPath $CatalogRoot -Recurse -File -Filter '*.ERB')) {
    $source = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    $names = @([regex]::Matches($source, '(?m)^@CLOTHES_CHANGE_([^\(\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
    $names += @([regex]::Matches($source, '(?m)^[ \t]*CSTR:[^:\r\n]+:(?:着せ替え服(?:追加名)?|服名称)[ \t]*=[ \t]*([^\r\n]*)') | ForEach-Object { $_.Groups[1].Value.Trim() })
    $names += @([regex]::Matches($source, '(?m)^[ \t]*CSTR:[^:\r\n]+:(?:着せ替え服(?:追加名)?|服名称)[ \t]*''=[ \t]*"([^"\r\n]*)"') | ForEach-Object { $_.Groups[1].Value.Trim() })
    foreach ($name in $names) {
        if (-not $name -or $name -eq 'CHARA' -or $name -match '[%{}"\\;]' -or $name -match '^\d+$') { continue }
        $catalog[$name] = $true
    }
}
foreach ($name in @($existing.Keys)) {
    # 以前の出力に含まれたキャラ専用衣装を除外。共通衣装と手動追加行は保持する。
    if (-not $catalog.ContainsKey($name) -and $existing[$name].source -match '(CSV[/\\]キャラデータ[/\\]|口上_キャラ個別ERB[/\\])') {
        $existing.Remove($name)
    }
}
foreach ($name in $catalog.Keys) {
    if ($existing.ContainsKey($name)) { continue }
    $tag = if ($seeds.ContainsKey($name)) { $seeds[$name] } else { $name }
    $existing[$name] = [pscustomobject]@{
        name = $name; prompt = $tag
    }
}
# 普段着はcharacters.csvのキャラ別設定だけを使う。
$existing.Remove('普段着')
Write-CsvTable $path @($existing.Values | Sort-Object name) @('name', 'prompt')
Write-Host ("服装CSV: {0}件。既存の編集内容は保持しました。" -f $existing.Count)
