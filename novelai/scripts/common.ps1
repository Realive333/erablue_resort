# 画像・口上共通。生成APIや各機能の設定には依存しない。
function Read-Text([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return [IO.File]::ReadAllText($Path, $script:Utf8).TrimEnd("`r", "`n")
    }
    return ''
}

function Write-Atomic([string]$Path, [string]$Value) {
    $temporary = $Path + '.tmp'
    [IO.File]::WriteAllText($temporary, $Value, $script:Utf8)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $Path + '.bak'); [IO.File]::Delete($Path + '.bak') }
    else { [IO.File]::Move($temporary, $Path) }
}

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

