# NovelAI 自動一枚絵・再開メモ

最新更新: 2026-09-14。日本語で回答。既存実装を再調査せず、必要箇所とgit diffから再開する。

## 実装済み
- 接触キャラ（TARGET＋PLAYERが関与する進行中モード、別室・無関係キャラは除外）から一枚絵を生成。プレイヤー＋最大5人。
- ERBは要求をtxtへ書き、Windows PowerShellワーカーがNovelAIへ送信。追加LLM・外部パッケージ不要。
- start.cmdは表示付きコンソール内でワーカーを実行。ウィンドウを閉じれば停止。stop.cmd・異常終了後はpauseでログ確認用に残る。隠し子プロセスは起動しない。
- Write-Logで日時付き状態・場面/モデル/キャラNO/行動・API送信/保存/エラー・設定更新を表示。同一状態は繰り返さず、エラー詳細のAPIキーは伏せる。送信時に全体・ネガティブ・全キャラの正負プロンプトを全文表示。preview.jsonも維持。
- 2026-09-13: 継続動作があると直近コマンドを無視するELSEIFが画像固定の原因。ユーザー指定で画像には直近コマンドだけを反映。PLAYER→TARGETのmode行で送り、継続動作DBは接触キャラの取得にだけ使用。有効な直近コマンドがなければ待機。ERB反映にはゲームの保存・再起動が必要。
- 設定: `novelai/config.json`。プロンプト: `prompts.csv`, `characters.csv`, `actions.csv`。この4ファイルが現在の設定元。
- 行動342件、タグあり77件、要設定265件。`export-csv.cmd`で静的コマンド/継続動作の新規行を追加。編集済みタグは保持する。
- 2026-09-13: actions.csvに「待機」を追加。場面タグがない場合は待機行のscene列を参照し、コード内の固定タグを廃止。空欄なら補完なし。export-csvの初期タグにも登録。既存画像への反映は［再生成］。
- OPTION→[5]→[9]からモデル・解像度・Steps・scale・Sampler・Seed・間隔・上限・CFG Rescale・Noise schedule・prompt_formatを変更。
- `prompts.csv`は固定system/negativeの2行のみ。player/character1/character2/actionテンプレートを削除。生成時にゲームの各キャラNO→characters.csv、現在の動作→actions.csvを検索して結合。未登録・空欄キャラはゲーム内名を使う。固定systemは組立時に変更しない。
- 2026-09-13: キャラプロンプトは目標→プレイヤー→その他の接触キャラへ変更。New-Payload内で先頭2人を入れ替え、V3/V4/V5と正負のキャプションへ適用。CharacterNosを返してログのNOも合わせる。シーン原本・画像名のID順は維持。既存画像への反映は再生成。
- ゲーム内[1]/[2]は固定system/negative、[3]はプレイヤー、[7]は相手のcharacters.csvを編集。NAI_キャラ番号を生成と編集で共用（あなたキャラ化記録も一致）。`settings.ps1`がtxt要求を処理し画面用の値を同期。生成中の編集は応答後に処理。
- 2026-09-13: ゲーム入力の半角括弧消失はEmuera INPUTSのマクロ解釈が原因（公式expression.html#inputs）。CSV保存・New-Payloadの変換ではない。入力時は \( と \) を使い、保存後は通常の括弧になる。設定画面とREADMEに案内追加。CSV直接編集ではエスケープ不要。前回のCSV→APIだけの確認では入力処理を見落としていた。
- V4/V4.5/V5の個別キャラキャプション、V3の単一プロンプト。未知モデルはprompt_formatを明示する。
- V5 Full/Curatedの公開とモデルIDを公式サイト・公開クライアントで確認。config.jsonのmodelをnai-diffusion-5-fullへ更新。V5はparams_version=4、送信時Karras固定、prompt_formatはauto/v4（legacyは保存拒否）。既存モデルの送信形式とNoise schedule設定は保持。
- 最新のユーザー指定で画像識別用ハッシュを完全廃止。画像名は`0-123_会話する.png`（キャラNO列＋行動テキストだけ）。Get-HashとNew-PayloadのHash、旧ハッシュとの照合を削除。モデル/プロンプト/設定変更後も同じID・行動なら既存画像を使い、作り直しは再生成のみ。
- 行動名の空白・括弧などはそのまま保持、Windowsの禁止文字だけ置換。複数行動は+で連結、未指定は待機。名前は切り詰めず180文字超過を送信前に拒否。旧画像は改名・削除せず保持し、対応するID・行動が分かる場合は手動で命名すれば利用可能。
- 一枚絵の[再生成]と設定[8]は同じNAI_再生成へ接続。現在の場面専用に1回だけキャッシュを迂回し、新しいSeedで送信。PNG確認後に原子的に置換し、失敗・中断時は旧画像を保持。通常の間隔/上限は有効。
- 再生成通信: regenerate.txtは4行（NAIREGEN1/要求ID/チケット/END＋タブ＋チケット）。regenerate-result.txtは3行（チケット/画像名/状態）。送信前に消費済みを記録。同じID・行動の失敗を自動再送しない。送信記録も平文名（画像名.txt または regenerate-チケット.txt）。旧retry.txt/旧ハッシュ記録の照合は廃止。
- 応答2行目は拡張子付き画像名。ERBのNAI_画像名が旧64桁ハッシュ応答も受け取り、区切り文字などを拒否してresources/NovelAI内だけを読む。
- 2026-09-14: auto-image-kaiの追加MOD構成で即時表示を実装。NAI_画像取得はID・直近行動名のPNGを直接確認し、キャッシュは応答待ちなし。TRAIN_MAINの両コマンド入力をTRAIN_コマンド入力経由にし、NovelAIタブだけTINPUTS 200msでNAI_表示更新を呼ぶ。1024角の同じ画像キャンバスと状態キャンバスを更新しREDRAW。再生成結果チケットの変化で同名PNGも再読込。タイムアウトの空行をCLEARLINEし、入力中テキストは保持。SHOW_STATUSを再実行せずゲーム時間を進めない。画像なしでも設定・再生成ボタンを表示。

## 主要ファイル
- `ERB/追加MOD_NovelAI一枚絵/NovelAI.ERB`, `NovelAI.ERH`: シーン取得・設定画面・通信。
- `ERB/追加MOD_NovelAI一枚絵/追加MOD設定_NovelAI.ERB`: 専用タブ・描画・入力待ち更新・設定への入口。追加ボタンは親divの外へ連結。
- `ERB/TRAIN_MAIN.ERB`: 通常・イベントのコマンド入力フック。MODなし・別タブではINPUTANY。
- `novelai/worker.ps1`, `settings.ps1`, `export-csv.ps1`: API、CSV/config管理、行動一覧更新。
- `novelai/README.md`: 利用手順。`start.cmd`, `stop.cmd`, `setup-token.cmd`: 起動・停止・キー設定。

## 整理済み
- JSON設定とプレビューは `config.json`, `runtime/preview.json` に統一。Git除外の例外も更新。
- CSV移行後に不要となった旧プロンプトTXT6件、旧configバックアップ、一時テストフォルダー（45ファイル）、ルートの生成Analysis.logを削除。移行専用コードも削除。
- APIキー、現行CSV・config、有効設定、画像キャッシュ、送信記録は保持。ゲーム連携用txtはEmueraのLOADTEXT/SAVETEXT拡張子制限に合わせて維持。
- この再開メモと再実行可能なテストは保持。一時テストは自身の作業領域を終了時に削除する。

## 検証
- 2026-09-14: test-render.ps1は追加MODの実装を直接読みPASS。応答なしのキャッシュ取得、画像なしの設定/再生成ボタン、入力待ち中の同名PNG差替え（赤→青の画素確認）、縦横比維持、入力途中文字列とログ行数不変を検証。TINPUTSタイマーは描画後に起動するため、このテストは専用ウィンドウを短時間表示する。Computer Useはnative pipe接続不可だったため使用せず、ERBから画素・入力・行数を確認。
- 同日test.ps1もPASS。ユーザーの行動CSV編集に依存しないよう、行動タグは隔離したテスト用CSVへ設定する。
- キャラ順序変更後のtest.ps1: PASS。目標→プレイヤーの順序、役割タグ、V3の結合順、ログのNO対応、シーンと画像名の不変を確認。
- 全プロンプトログ・直近行動への変更後、test.ps1とtest-render.ps1はPASS。APIモックで送信本文と全キャラのログ一致・キー非表示、実Emueraで継続動作を無視して直近コマンドだけ送信・行動変更で要求更新・対象不一致の履歴除外・待機への復帰を検証。
- 待機項目追加後のtest.ps1: PASS。待機行の編集を行動なし・未登録時に反映し、登録済み行動、未登録ログ、ID＋行動の画像名を維持することを確認。diff --checkもPASS。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/test.ps1`: PASS。実行時のプレイヤー/相手のCSV検索、CSV変更の再読込、キャラ切替・未登録/空欄の名前使用、固定system不変、V3での全結合。CSV往復、V3/V4/V5切替、V5送信形式、設定保存、不正値拒否、キャッシュ、ZIP、APIモック、失敗後再送防止も確認。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/test-render.ps1`: PASS。実EmueraでキャラNO/あなたキャラ化記録/送信行の一致、設定メニュー構文、HTML_PRINTまで無効・待機・画像あり・特殊文字を検証。
- 旧TXTなしの隔離環境でexport-csvを実行しPASS、既存actions.csvのハッシュ不変を確認。
- 実Emueraから設定要求→別プロセスのSync-Settings→CSV保存・モデル変更・不正幅拒否も検証済み（使い終えた隔離環境は削除済み）。
- `git -c core.whitespace=cr-at-eol diff --check`: PASS。ERBのCRLFとPowerShellのUTF-8 BOMを維持。
- ログ追加後もtest.ps1はPASS。日時付き状態ログの重複抑止と、APIエラー詳細のキー非表示を検証。
- ハッシュ廃止後も両テストPASS。ID・行動だけの命名、手動配置PNGの再利用、モデル/設定/プロンプト変更後もAPI送信しないこと、名前の安定性・文字の保持、1回だけ再生成、失敗/画像欠損時の再送防止、別キャラIDでの生成をAPIモックで検証。Invoke-Worker -Directoryでテスト専用CSV/configを読む。
- 実Emueraで日本語・空白・括弧を含む画像名、旧応答名、不正パス拒否、再生成要求の書込、ボタン表示、表示中のPNGを原子的に置換して再描画後のサイズが変わることを確認。

## 運用・残る確認
- 現在のブランチはauto-image-kai（ユーザーが移行した追加MOD版）。ブランチを切り替えず変更。最新行動だけの処理を移植先へ反映。開始時からactions.csv・characters.csv・runtimeの追跡済みファイルに変更があり保持。キーを読んだり出力しない。
- 過去にV5 Fullの実API生成・PNG保存は確認済み。今回の検証はAPI通信なし。通常ワーカーは変更時にstop.cmdで停止し、表示ウィンドウ付きで再起動。Start-Process後にWait-Processで親を維持するexecセッションを使う（起動だけだと残らなかった）。ゲーム本体は終了していないため、直近行動の変更はユーザー側でセーブ・再起動が必要。
- APIキー・有効設定の有無は毎回確認すること。既存画像・記録・configは保持。調査時はキーをチャットへ出さない。
- 公式API: https://image.novelai.net/docs/doc.json
- V5公式案内: https://novelai.net/v5 。仕様確認元: https://novelai.net/_next/static/chunks/pages/_app-b7172cc1a6a0b340.js （2026-09-12、公開モデル定数・初期params_version・V5送信時のKarras固定・v4Prompts対応）。
