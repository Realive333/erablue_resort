# NovelAI 自動口上

手動コマンドの実行後に、相手の反応をNovelAIで生成し、既存の口上の後へ追加します。初期状態は無効です。画像生成とは別のワーカー・CSV・有効設定・通信フォルダーを使用します。画像ワーカーの起動やNovelAIタブへの切替は不要です。

## 起動

1. ゲームをセーブして再起動します。
2. 初回のみ `novelai/setup-token.cmd` でPersistent API tokenを登録します。登録済みならそのまま使用できます。
3. **`novelai/text/start.cmd`** を起動します。
4. ゲームの `OPTION → NovelAI自動口上の設定 → [0] 有効` を選び、相手へのコマンドを実行します。

停止は `novelai/text/stop.cmd`、または口上ワーカーのウィンドウを閉じます。通信中の停止は応答・タイムアウト後です。画像側のstart/stopや有効設定は口上に影響しません。生成設定を変えた場合も、CSVは次の要求で読み直します。

認証の優先順位は `NOVELAI_TEXT_API_TOKEN` → `NOVELAI_API_TOKEN` → 既存の `novelai/runtime/token.dpapi` です。最後のファイルはWindowsユーザー固有の暗号化で保存されています。口上だけ別トークンにする場合は専用環境変数を使ってください。トークンをCSVへ書かないでください。

## 独立CSV

すべて **CSV UTF-8** で保存します。カンマ・改行を含むセルはダブルクォートで囲み、セル内の `"` は `""` にします。画像側の同名CSVは参照しません。

| ファイル | 列 | 用途 |
| --- | --- | --- |
| `config.csv` | `key,value` | モデルと生成条件 |
| `prompts.csv` | `key,prompt` | `system`（必須の共通指示）、`memory`（固定の背景）、`authors_note`（文体指示） |
| `characters.csv` | `no,prompt` | ゲームのキャラNOごとの性格・口調・一人称・関係性など |
| `actions.csv` | `name,prompt` | ゲーム内のコマンド表示名と、その行動についての補足 |

キーはファイル内で一意にしてください。キャラが未登録・空欄の場合はゲーム内の呼び名を使い、行動の補足がない場合はコマンド表示名だけを使用します。`characters.csv` の初期状態はヘッダーだけです。必要なキャラを追加してください。例：

```csv
no,prompt
123,"一人称は私。落ち着いた丁寧語で話す。旅や景色の話題が好き。"
```

`123` は実際のキャラNOへ変更します。操作キャラにも同じ表を使い、「あなたキャラ化」している場合はそのキャラNOを参照します。既存口上ファイルの自動収集は行いません。

`prompts.csv` の `system` と `authors_note` で、対象キャラクターの日本語のセリフだけを2〜3文出すよう指定しています。各文をそれぞれ「」で囲み、1文ごとに改行します。地の文・仕草の描写・話者名・他の人物のセリフは含めません。人物設定・行動補足も日本語で記述できます。

| configのキー | 初期値 | この実装での入力範囲 |
| --- | --- | --- |
| `model` | `glm-4-6` | `glm-4-6` / `kayra-v1` / `llama-3-erato-v1` |
| `max_length` | `150` | 整数1〜250、出力トークン数（文字数ではありません） |
| `temperature` | `0.8` | GLM: 0.1〜2、Kayra/Erato: 0.1〜100 |
| `top_p` | `0.9` | 0〜1 |
| `repetition_penalty` | `1.1` | 1〜8（Kayra/Erato専用、GLMには送信しません） |
| `timeout_seconds` | `25` | 整数1〜25、HTTP通信の待機秒数 |

`timeout_seconds` はローカル設定で、API本文には入りません。入力範囲の一部は、このMODで設けた制限です。モデル・生成長・文脈長には契約側の制限もあります。公式仕様はKayraの生成長をTablet/Scrollで150、Opusで250トークンと記載しています。初期値150はそれに合わせています。契約やモデルの条件は公式ドキュメントで確認してください。

## APIとの対応（2026-09-22確認）

利用するのは [公式Text Generation API](https://text.novelai.net/docs/index.html) です。仕様の機械可読版は [OpenAPI](https://text.novelai.net/docs/doc.json) です。

- **GLM-4.6**: `POST https://text.novelai.net/oa/v1/completions`。文脈は文字列の `prompt`、生成長は `max_tokens` として送信し、`choices[0].text` を表示します。`temperature` / `top_p` も本文直下に入ります。`stream=false` で一括取得します。
- **Kayra/Erato**: `POST https://text.novelai.net/ai/generate`。文脈は `input`、生成条件は `parameters` に入ります。`use_string=true`、必須の `logit_bias_exp` は空配列とし、`output` を表示します。
- CSVの `system` / `memory` / `authors_note` はMOD独自の編集用キーで、APIの同名フィールドではありません。共通指示 → 固定背景 → 人物 → 場所・状態・直前の行動 → 文体指示 → 反応の導入文の順に、1本の文脈へ結合します。

2026-09-21時点ではKayra/EratoがメンテナンスによってHTTP 400を返すため、初期モデルを稼働中のGLM-4.6に変更しました。[公式稼働状況](https://status.novelai.net/)を確認できます。GLMの文字列補完で実生成・本文取得まで確認済みです。モデルは自動では切り替えません。

動的に送る情報は操作キャラ・相手のNOと呼び名、コマンド名、場所名、ゲームフェイズ、相手の好感度レベル・信頼度、コマンド結果の数値です。結果値の意味はコマンドごとに異なるため、一律に成功・失敗とは解釈しません。履歴の蓄積はせず、CSVで指定した背景と現在の場面を使います。

## 表示と失敗時の動作

- `SOURCE.ERB` の共通口上処理から呼びます。対象は手動コマンドの相手1人です。オートコマンド、相手のない行動、睡眠・体力限界・発話抑制中、口上表示OFFの場合は生成しません。
- 既存口上の処理を実行した後に、生成が成功した場合だけ本文を追加します。見出しは表示しません。生成文はERBやHTMLとして実行しません。
- ワーカーの受理まで最大1.5秒、受理後を含む全体で最大30秒待機します。この待機でゲーム時間は進みません。失敗・未起動・時間切れの場合は既存口上で続行します。
- コマンドごとに要求IDを発行し、同じ行動でも新しく生成します。同じ要求IDは失敗・中断後も自動再送しません。次に実行したコマンドは別要求です。起動前に残った要求や、取り消した要求への遅い応答は表示しません。
- 文脈は6000文字までとし、超過は送信前に拒否します。正確なトークン数の計算は行わず、契約の文脈長上限はAPIが検証します。生成の日本語品質・文体や文末までの完結は、モデルと生成長に依存します。

`runtime/status.txt` は状態・エラー、`runtime/preview.json` は最新の送信本文です。HTTPエラー時にはAPIが返す具体的な理由も表示します。キャラ設定などの送信内容を確認できますが、認証トークンは含みません。通信ファイルはGit対象外です。

## 日本語と文字コード

同梱のゲーム本体は `Emuera 1.824+v24+EMv18+EEv55` です。口上の通信にはUTF-8を使い、ゲーム側も `LOADTEXT` / `SAVETEXT` のUTF-8指定を有効にしています（[Emueraの仕様](https://evilmask.gitlab.io/emuera.em.doc/Reference/LOADTEXT.html)）。Shift-JISへの変換は不要です。

Windows PowerShell 5.1では、APIが `Content-Type: application/json` をcharsetなしで返すと、日本語がLatin-1として誤読されていました。ワーカーは応答の生バイトをUTF-8で復号してからJSONを読みます。送信本文もUTF-8、PowerShellスクリプトはUTF-8 BOM付きです。

2026-09-22にGLMで日本語を実生成し、その生成文を隔離した実Emueraへ渡して、表示ログの文字一致まで確認しました。ワーカーの更新を反映するには、口上ワーカーのウィンドウを閉じ、`novelai/text/start.cmd` を起動し直してください。

## 検証

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/text/test.ps1
```

APIモックでCSV再読込・Kayra/GLMの本文・UTF-8復号・失敗後の再送禁止・取り消しを検証し、隔離した実Emueraで要求・応答・日本語の表示ログ・未起動時の待機上限を確認します。実際のAPI通信、ユーザーのセーブの読込、有効設定の変更は行いません。任意の `-GeneratedTextPath <UTF-8テキストのパス>` で、保存済みの実生成文もゲーム表示まで検証できます。
