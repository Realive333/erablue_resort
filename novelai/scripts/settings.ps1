# CSVはPowerShell標準のCSVパーサーで読む。ゲームとの連絡は既存のtxt通信。
$script:ConfigKeys = @('model', 'width', 'height', 'steps', 'scale', 'sampler', 'seed', 'minimum_interval_seconds', 'cfg_rescale', 'noise_schedule', 'prompt_format')
$script:PromptKeys = @('system', 'negative')

function Read-CsvTable([string]$Directory, [string]$Name, [string[]]$Columns, [string]$Key) {
    $path = Join-Path $Directory ($Name + '.csv')
    if (-not (Test-Path -LiteralPath $path)) { throw "$Name.csvがありません。ファイルの配置を確認してください。" }
    $text = Read-Text $path
    $rows = @($text | ConvertFrom-Csv)
    # 空のキャラ表でもヘッダーを検証する。
    $probe = @(($text.Split("`n")[0] + "`n" + (($Columns | ForEach-Object { 'x' }) -join ',')) | ConvertFrom-Csv)
    foreach ($column in $Columns) {
        if ($column -notin $probe[0].PSObject.Properties.Name) { throw "$Name.csvに列 $column がありません。" }
    }
    $seen = @{}
    foreach ($row in $rows) {
        $id = [string]$row.$Key
        if (-not $id -or $seen.ContainsKey($id)) { throw "$Name.csvのキーが空欄または重複しています: $id" }
        $seen[$id] = $true
    }
    return $rows
}

function Write-CsvTable([string]$Path, $Rows, [string[]]$Columns) {
    $lines = if (@($Rows).Count) { @($Rows | Select-Object $Columns | ConvertTo-Csv -NoTypeInformation) } else { @(($Columns -join ',')) }
    # Excelでも日本語を判別できるUTF-8 BOM付き。
    Write-Atomic $Path ([string][char]0xFEFF + ($lines -join "`r`n") + "`r`n")
}

function Read-PromptData([string]$Directory) {
    $prompts = @{}
    foreach ($row in (Read-CsvTable $Directory 'prompts' @('key', 'prompt') 'key')) { $prompts[$row.key] = $row.prompt }
    foreach ($key in $script:PromptKeys) { if (-not $prompts.ContainsKey($key)) { throw "prompts.csvに$keyがありません。" } }
    $characters = @{}
    foreach ($row in (Read-CsvTable $Directory 'characters' @('no', 'prompt') 'no')) {
        if ($row.no -notmatch '^\d+$') { throw 'characters.csvのnoはキャラ番号を指定してください。' }
        $characters[$row.no] = $row.prompt
    }
    $actions = @{}
    foreach ($row in (Read-CsvTable $Directory 'actions' @('name', 'scene', 'actor', 'target') 'name')) {
        if ($row.scene -or $row.actor -or $row.target) { $actions[$row.name] = $row }
    }
    $clothes = @{}
    foreach ($row in (Read-CsvTable $Directory 'clothes' @('name', 'prompt') 'name')) { $clothes[$row.name] = $row.prompt }
    return [pscustomobject]@{ Prompts = $prompts; Characters = $characters; Actions = $actions; Clothes = $clothes }
}

function Get-PromptFormat($Config) {
    $format = Get-Entry $Config 'prompt_format'
    if ($format -and $format -ne 'auto') { return $format }
    if ($Config.model -eq 'nai-diffusion-3') { return 'legacy' }
    if ($Config.model -match '^nai-diffusion-[45](?:-|$)') { return 'v4' }
    throw 'このモデルはprompt_formatにv4またはlegacyを明示してください。'
}

function Get-Backend($Config) {
    $backend = [string](Get-Entry $Config 'backend')
    if (-not $backend) { return 'novelai' }
    return $backend.ToLowerInvariant()
}

function Get-ApiUrl($Config) {
    $url = [string](Get-Entry $Config 'api_url')
    if (-not $url) {
        return $(if ((Get-Backend $Config) -eq 'comfyui') { 'http://127.0.0.1:8188' } else { 'http://127.0.0.1:7860' })
    }
    return $url.TrimEnd('/')
}

function Test-Config($Config) {
    $backend = Get-Backend $Config
    if ($backend -notin @('novelai', 'comfyui', 'forge')) { throw 'backendはnovelai、comfyui、forgeのいずれかを指定してください。' }
    if ($backend -ne 'novelai' -and [string](Get-Entry $Config 'api_url') -and
        [string](Get-Entry $Config 'api_url') -notmatch '^https?://[^\s]+$') { throw 'api_urlはhttpまたはhttpsのURLを指定してください。' }
    if ($backend -eq 'novelai' -and $Config.model -match '^nai-diffusion-5(?:-|$)' -and (Get-PromptFormat $Config) -ne 'v4') {
        throw 'V5のprompt_formatはautoまたはv4を指定してください。'
    }
    foreach ($key in 'width', 'height') {
        $value = Get-Entry $Config $key
        if ($null -eq $value -or $value -lt 64 -or $value -gt 2048 -or $value % 64 -ne 0) { throw '幅・高さは64～2048の64倍数で設定してください。' }
    }
    foreach ($key in 'steps', 'seed', 'minimum_interval_seconds') {
        $value = Get-Entry $Config $key
        if ($null -eq $value -or $value % 1 -ne 0) { throw "$keyには整数が必要です。" }
    }
    $modelPattern = if ($backend -eq 'novelai') { '^[a-zA-Z0-9_.-]{1,100}$' } else { '^[^<>:"|?*\x00-\x1f]{1,240}$' }
    $samplerPattern = '^[a-zA-Z0-9_+ .-]{1,80}$'
    if ($Config.width * $Config.height -gt 4194304 -or $Config.steps -lt 1 -or $Config.steps -gt 50 -or
        $null -eq $Config.scale -or $Config.scale -lt 0 -or $Config.scale -gt 10 -or $Config.seed -lt -1 -or $Config.seed -gt 4294967295 -or
        $Config.minimum_interval_seconds -lt 5 -or
        [string]$Config.model -notmatch $modelPattern -or [string]$Config.sampler -notmatch $samplerPattern -or
        ($backend -eq 'novelai' -and (Get-PromptFormat $Config) -notin @('v4', 'legacy'))) { throw 'モデル・生成パラメータが不正です。' }
    $rescale = Get-Entry $Config 'cfg_rescale'
    $schedule = Get-Entry $Config 'noise_schedule'
    if ([double]::IsNaN([double]$Config.scale) -or ($null -ne $rescale -and ([double]::IsNaN([double]$rescale) -or $rescale -lt 0 -or $rescale -gt 1)) -or
        ($schedule -and $schedule -notin @('karras', 'native', 'exponential', 'polyexponential'))) { throw 'cfg_rescaleまたはnoise_scheduleが不正です。' }
}

function Update-Setting([string]$Directory, [string]$Kind, [string]$Key, [string]$Value) {
    if ($Kind -eq 'config') {
        if ($Key -notin $script:ConfigKeys) { throw '変更できない設定項目です。' }
        if ($Key -eq 'model') { throw 'モデルはnovelai/set-model.cmdで変更してください。' }
        $path = Join-Path $Directory 'config.json'
        $config = Read-Text $path | ConvertFrom-Json
        $typedValue = $Value
        if ($Key -notin @('model', 'sampler', 'noise_schedule', 'prompt_format')) {
            $typedValue = [double]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        $config | Add-Member -NotePropertyName $Key -NotePropertyValue $typedValue -Force
        Test-Config $config
        Write-Atomic $path (ConvertTo-Json $config -Depth 15)
        return
    }
    if ($Kind -eq 'prompts' -and $Key -in $script:PromptKeys) { $keyColumn = 'key' }
    elseif ($Kind -eq 'characters' -and $Key -match '^\d+$') { $keyColumn = 'no' }
    else { throw '変更できないプロンプトです。' }
    $rows = @(Read-CsvTable $Directory $Kind @($keyColumn, 'prompt') $keyColumn)
    $row = $rows | Where-Object { $_.$keyColumn -ceq $Key }
    if ($null -eq $row) { $rows += [pscustomobject]@{ $keyColumn = $Key; prompt = $Value } }
    else { $row.prompt = $Value }
    Write-CsvTable (Join-Path $Directory ($Kind + '.csv')) $rows @($keyColumn, 'prompt')
}

function Sync-Settings([string]$Directory) {
    $reply = $null
    $edit = Read-Text (Join-Path $script:Runtime 'settings-request.txt')
    $replyPath = Join-Path $script:Runtime 'settings-result.txt'
    $lines = @($edit -split '\r?\n')
    if ($lines.Count -eq 6 -and $lines[0] -eq 'NAISET1' -and $lines[1] -match '^\d+-\d+$' -and $lines[5] -eq ("END`t" + $lines[1]) -and
        (Read-Text $replyPath).Split("`n")[0] -ne $lines[1]) {
        try { Update-Setting $Directory $lines[2] $lines[3] $lines[4]; $result = '保存しました。' }
        catch { $result = '保存失敗: ' + $_.Exception.Message }
        Write-Log ('設定更新 {0}: {1}/{2} {3}' -f $lines[1], $lines[2], $lines[3], $result)
        $reply = $lines[1] + "`n" + ($result -replace '[\r\n\t]', ' ')
    }
    $data = Read-PromptData $Directory
    $config = Read-Text (Join-Path $Directory 'config.json') | ConvertFrom-Json
    foreach ($kind in 'prompts', 'characters', 'config') {
        $values = if ($kind -eq 'config') {
            foreach ($key in $script:ConfigKeys) { "{0}`t{1}" -f $key, (Get-Entry $config $key) }
        } else {
            foreach ($key in ($data.$kind.Keys | Sort-Object)) { "{0}`t{1}" -f $key, ([string]$data.$kind[$key] -replace '[\r\n\t]', ' ') }
        }
        $path = Join-Path $script:Runtime ("view-$kind.txt")
        $value = $values -join "`n"
        if ((Read-Text $path) -cne $value) { Write-Atomic $path $value }
    }
    if ($null -ne $reply) { Write-Atomic $replyPath $reply }
}
