param([switch]$Library)

$ErrorActionPreference = 'Stop'
$script:TextDirectory = $PSScriptRoot
$script:Utf8 = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot '../scripts/common.ps1')

function Read-TextRequest([string]$Text) {
    $lines = @($Text -split '\r?\n')
    if ($lines.Count -ne 7 -or $lines[0] -notmatch '^NAITEXT1\t([0-9]+-[0-9]+)$') { return $null }
    $id = $Matches[1]
    if ($lines[6] -cne "END`t$id") { return $null }
    $values = @{}
    foreach ($line in $lines[1..5]) {
        $fields = @($line -split "`t")
        $key = $fields[0]
        if ($values.ContainsKey($key)) { return $null }
        switch ($key) {
            { $_ -in 'player', 'character' } {
                if ($fields.Count -ne 3 -or $fields[1] -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace($fields[2])) { return $null }
                $values[$key] = [pscustomobject]@{ No = $fields[1]; Name = $fields[2] }
            }
            { $_ -in 'action', 'place', 'state' } {
                if ($fields.Count -ne 2 -or [string]::IsNullOrWhiteSpace($fields[1])) { return $null }
                $values[$key] = $fields[1]
            }
            default { return $null }
        }
    }
    foreach ($key in 'player', 'character', 'action', 'place', 'state') {
        if (-not $values.ContainsKey($key)) { return $null }
    }
    $values.Id = $id
    return [pscustomobject]$values
}

function Read-TextConfig([string]$Directory) {
    $config = @{}
    foreach ($row in (Read-CsvTable $Directory 'config' @('key', 'value') 'key')) { $config[$row.key] = $row.value }
    $ranges = @{ max_length = @(1, 250); temperature = @(0.1, 100); top_p = @(0, 1); repetition_penalty = @(1, 8); timeout_seconds = @(1, 25) }
    if ($config.model -notin 'kayra-v1', 'llama-3-erato-v1', 'glm-4-6') { throw 'config.csvのmodelはkayra-v1 / llama-3-erato-v1 / glm-4-6を指定してください。' }
    if ($config.model -eq 'glm-4-6') { $ranges.temperature = @(0.1, 2) }
    foreach ($key in $config.Keys) {
        if ($key -ne 'model' -and -not $ranges.ContainsKey($key)) { throw "config.csvの未対応キー: $key" }
    }
    foreach ($key in $ranges.Keys) {
        $number = 0.0
        if (-not [double]::TryParse($config[$key], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
            [double]::IsNaN($number) -or $number -lt $ranges[$key][0] -or $number -gt $ranges[$key][1]) { throw "config.csvの$keyが不正です。" }
        if ($key -in 'max_length', 'timeout_seconds' -and $number -ne [math]::Truncate($number)) { throw "$keyは整数で指定してください。" }
        $config[$key] = $number
    }
    return $config
}

function New-TextPayload($Request, $Config, [string]$Directory) {
    $prompts = @{}
    foreach ($row in (Read-CsvTable $Directory 'prompts' @('key', 'prompt') 'key')) {
        if ($row.key -notin 'system', 'memory', 'authors_note') { throw "prompts.csvの未対応キー: $($row.key)" }
        $prompts[$row.key] = $row.prompt
    }
    if ([string]::IsNullOrWhiteSpace($prompts.system)) { throw 'prompts.csvのsystemは必須です。' }
    $characters = @{}
    foreach ($row in (Read-CsvTable $Directory 'characters' @('no', 'prompt') 'no')) {
        if ($row.no -notmatch '^\d+$') { throw 'characters.csvのnoはキャラ番号を指定してください。' }
        $characters[$row.no] = $row.prompt
    }
    $actions = @{}
    foreach ($row in (Read-CsvTable $Directory 'actions' @('name', 'prompt') 'name')) { $actions[$row.name] = $row.prompt }
    $parts = @($prompts.memory)
    $parts += '実行者: {0}。{1}' -f $Request.player.Name, $characters[$Request.player.No]
    $parts += '反応する人物: {0}。{1}' -f $Request.character.Name, $characters[$Request.character.No]
    $parts += '場所: ' + $Request.place
    $parts += '現在の状態: ' + $Request.state
    $parts += '直前の行動: {0}。{1}' -f $Request.action, $actions[$Request.action]
    $parts += $prompts.authors_note
    $parts += 'この行動に対する{0}の反応：' -f $Request.character.Name
    $contextText = ($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    $inputText = $prompts.system + "`n" + $contextText
    # ponytail: 自前tokenizerは持たない。長文は拒否し、契約別の厳密なtoken数検証はAPIへ任せる。
    if ($inputText.Length -gt 6000) { throw '口上の文脈が6000文字を超えています。CSVの説明を短くしてください。' }
    if ($Config.model -eq 'glm-4-6') {
        return [ordered]@{
            model = $Config.model
            # messagesのAPIはtoken_idsだけ返すことがある。文字列promptならtextが返る。
            prompt = $inputText
            max_tokens = [int]$Config.max_length
            temperature = $Config.temperature
            top_p = $Config.top_p
            stream = $false
        }
    }
    # Kayra/Eratoの/ai/generateは、systemを含む1本の物語文脈を受け取る。
    return [ordered]@{
        input = $inputText
        model = $Config.model
        parameters = [ordered]@{
            use_string = $true
            max_length = [int]$Config.max_length
            temperature = $Config.temperature
            top_p = $Config.top_p
            repetition_penalty = $Config.repetition_penalty
            logit_bias_exp = @()
        }
    }
}

function Get-TextToken {
    if ($env:NOVELAI_TEXT_API_TOKEN) { return $env:NOVELAI_TEXT_API_TOKEN }
    if ($env:NOVELAI_API_TOKEN) { return $env:NOVELAI_API_TOKEN }
    $path = Join-Path $script:TextDirectory '../runtime/token.dpapi'
    if (Test-Path -LiteralPath $path) {
        $secure = (Read-Text $path) | ConvertTo-SecureString
        return (New-Object Net.NetworkCredential('', $secure)).Password
    }
    throw 'APIキー未設定。novelai/setup-token.cmdを実行してください。'
}

function Invoke-TextGeneration($Payload, [string]$Token, [int]$TimeoutSeconds) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = $script:Utf8.GetBytes((ConvertTo-Json $Payload -Depth 10 -Compress))
    $completion = $Payload.model -eq 'glm-4-6'
    $uri = if ($completion) { 'https://text.novelai.net/oa/v1/completions' } else { 'https://text.novelai.net/ai/generate' }
    $httpResponse = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $uri -MaximumRedirection 0 `
        -Headers @{ Authorization = 'Bearer ' + $Token } -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec $TimeoutSeconds
    # Windows PowerShell 5.1はcharsetなしのJSONをLatin-1として読む。生バイトをUTF-8で復号する。
    try { $response = ([Text.UTF8Encoding]::new($false, $true).GetString($httpResponse.RawContentStream.ToArray())) | ConvertFrom-Json }
    finally { $httpResponse.RawContentStream.Dispose() }
    $outputText = if ($completion -and @($response.choices).Count -gt 0) { $response.choices[0].text } elseif (-not $completion) { $response.output }
    if ($outputText -isnot [string] -or [string]::IsNullOrWhiteSpace($outputText)) { throw 'API応答に口上テキストがありません。' }
    $result = ($outputText -replace '\r\n?', "`n" -replace '[\x00-\x08\x0B-\x1F\x7F]', '').Trim()
    if (-not $result -or $result.Length -gt 8000 -or @($result -split "`n").Count -gt 250) { throw '生成テキストの長さが不正です。' }
    return $result
}

function Set-TextStatus([string]$Runtime, [string]$Message) {
    $path = Join-Path $Runtime 'status.txt'
    if ((Read-Text $path) -ne $Message) {
        Write-Atomic $path $Message
        Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message)
    }
}

function Invoke-TextWorker {
    param([switch]$Once, [string]$Directory = $script:TextDirectory)
    $runtime = Join-Path $Directory 'runtime'
    [void][IO.Directory]::CreateDirectory($runtime)
    # ponytail: 1ゲームにつき口上ワーカー1個。複数ゲーム対応時は通信先を分ける。
    $workerLock = [IO.File]::Open((Join-Path $runtime 'worker.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $requestPath = Join-Path $runtime 'request.txt'
    $handledPath = Join-Path $runtime 'handled.txt'
    $stopPath = Join-Path $runtime 'stop.txt'
    try {
        if (Test-Path -LiteralPath $stopPath) { [IO.File]::Delete($stopPath) }
        # 起動前の残存要求は再送しない。ゲームで次のコマンドを実行すると新しいIDになる。
        if (-not $Once) {
            $old = Read-TextRequest (Read-Text $requestPath)
            if ($null -ne $old) { Write-Atomic $handledPath $old.Id }
            Set-TextStatus $runtime '口上ワーカー起動。次のコマンドを待っています。'
        }
        do {
            $request = $null
            $token = $null
            try {
                if ((Read-Text (Join-Path $runtime 'enabled.txt')) -ne '1') { continue }
                $request = Read-TextRequest (Read-Text $requestPath)
                if ($null -eq $request -or (Read-Text $handledPath) -ceq $request.Id) { continue }
                # 受理時点で消費済みにする。設定不正・タイムアウト・中断も同じIDでは自動再送しない。
                Write-Atomic $handledPath $request.Id
                Write-Atomic (Join-Path $runtime 'processing.txt') $request.Id
                $config = Read-TextConfig $Directory
                $payload = New-TextPayload $request $config $Directory
                $token = Get-TextToken
                Write-Atomic (Join-Path $runtime 'preview.json') (ConvertTo-Json $payload -Depth 10)
                $latest = Read-TextRequest (Read-Text $requestPath)
                if ($null -eq $latest -or $latest.Id -cne $request.Id -or
                    (Read-Text (Join-Path $runtime 'enabled.txt')) -ne '1' -or (Test-Path -LiteralPath $stopPath)) { continue }
                Set-TextStatus $runtime ('口上生成中: {0} / {1}' -f $request.character.Name, $request.action)
                $generated = Invoke-TextGeneration $payload $token ([int]$config.timeout_seconds)
                $latest = Read-TextRequest (Read-Text $requestPath)
                if ($null -ne $latest -and $latest.Id -ceq $request.Id -and
                    (Read-Text (Join-Path $runtime 'enabled.txt')) -eq '1' -and -not (Test-Path -LiteralPath $stopPath)) {
                    # 区切りを含む生成文も安全に運ぶため、本文の各行にtextタグを付ける。
                    $tagged = (@($generated -split "`n" | ForEach-Object { "text`t$_" })) -join "`n"
                    Write-Atomic (Join-Path $runtime 'response.txt') ("NAITEXT1`t$($request.Id)`nok`n$tagged`nEND`t$($request.Id)")
                    Set-TextStatus $runtime '口上生成完了。'
                }
            }
            catch {
                $message = [string]$_.Exception.Message
                $detail = [string]$_.ErrorDetails.Message
                if ($detail) {
                    try {
                        $apiError = $detail | ConvertFrom-Json
                        if ($apiError.message) { $detail = [string]$apiError.message }
                        elseif ($apiError.error.message) { $detail = [string]$apiError.error.message }
                    } catch { } # JSON以外のエラー本文も表示する。
                    $message += ' | API: ' + $detail
                }
                if ($token) { $message = $message.Replace($token, '[redacted]') }
                $message = $message -replace '[\r\n\t]', ' '
                Set-TextStatus $runtime ('口上生成失敗（自動再送なし）: ' + $message)
                if ($null -ne $request) {
                    Write-Atomic (Join-Path $runtime 'response.txt') ("NAITEXT1`t$($request.Id)`nerror`nEND`t$($request.Id)")
                }
            }
            finally {
                $token = $null
                if (-not $Once) { Start-Sleep -Milliseconds 200 }
            }
        } while (-not $Once -and -not (Test-Path -LiteralPath $stopPath))
    }
    finally { $workerLock.Dispose() }
}

if (-not $Library) { Invoke-TextWorker }
