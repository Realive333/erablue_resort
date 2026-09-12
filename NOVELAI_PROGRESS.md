# NovelAI 自動一枚絵・再開メモ

最新更新: 2026-09-12。日本語で回答。既存実装を再調査せず、必要箇所とgit diffから再開する。

## 実装済み
- 接触キャラ（TARGET＋PLAYERが関与する進行中モード、別室・無関係キャラは除外）から一枚絵を生成。プレイヤー＋最大5人。
- ERBは要求をtxtへ書き、Windows PowerShellワーカーがNovelAIへ送信。追加LLM・外部パッケージ不要。
- start.cmdは表示付きコンソール内でワーカーを実行。ウィンドウを閉じれば停止。stop.cmd・異常終了後はpauseでログ確認用に残る。隠し子プロセスは起動しない。
- Write-Logで日時付き状態・場面/モデル/キャラNO/行動・API送信/保存/エラー・設定更新を表示。同一状態は繰り返さず、エラー詳細のAPIキーは伏せる。プロンプト全体は既存preview.jsonで確認。
- 設定: `novelai/config.json`。プロンプト: `prompts.csv`, `characters.csv`, `actions.csv`。この4ファイルが現在の設定元。
- 行動341件、タグあり76件、要設定265件。`export-csv.cmd`で静的コマンド/継続動作の新規行を追加。編集済みタグは保持する。
- OPTION→[5]→[9]からモデル・解像度・Steps・scale・Sampler・Seed・間隔・上限・CFG Rescale・Noise schedule・prompt_formatを変更。
- `prompts.csv`は固定system/negativeの2行のみ。player/character1/character2/actionテンプレートを削除。生成時にゲームの各キャラNO→characters.csv、現在の動作→actions.csvを検索して結合。未登録・空欄キャラはゲーム内名を使う。固定systemは組立時に変更しない。
- ゲーム内[1]/[2]は固定system/negative、[3]はプレイヤー、[7]は相手のcharacters.csvを編集。NAI_キャラ番号を生成と編集で共用（あなたキャラ化記録も一致）。`settings.ps1`がtxt要求を処理し画面用の値を同期。生成中の編集は応答後に処理。
- V4/V4.5/V5の個別キャラキャプション、V3の単一プロンプト。未知モデルはprompt_formatを明示する。
- V5 Full/Curatedの公開とモデルIDを公式サイト・公開クライアントで確認。config.jsonのmodelをnai-diffusion-5-fullへ更新。V5はparams_version=4、送信時Karras固定、prompt_formatはauto/v4（legacyは保存拒否）。既存モデルの送信形式とNoise schedule設定は保持。
- 同一送信内容はSHA256キャッシュ。最新要求のみ生成、古い応答は表示しない。送信前に永続記録し、中断・失敗後の重複送信を防止。
- 生成完了は次のゲーム操作/「画像更新」で表示。入力待ち画面を外部から自動再描画する仕組みはない。

## 主要ファイル
- `ERB/NovelAI.ERB`, `ERB/汎用変数定義/NovelAI.ERH`: シーン取得・設定画面・通信。
- `ERB/サイド領域描画処理.ERB`: 一枚絵欄。追加ボタンは親divを閉じた後に追加表示文字列へ連結（Emueraはdiv入れ子不可）。
- `ERB/起床前メニュー関連処理/OPTION.ERB`: NovelAI設定への入口。
- `novelai/worker.ps1`, `settings.ps1`, `export-csv.ps1`: API、CSV/config管理、行動一覧更新。
- `novelai/README.md`: 利用手順。`start.cmd`, `stop.cmd`, `setup-token.cmd`: 起動・停止・キー設定。

## 整理済み
- JSON設定とプレビューは `config.json`, `runtime/preview.json` に統一。Git除外の例外も更新。
- CSV移行後に不要となった旧プロンプトTXT6件、旧configバックアップ、一時テストフォルダー（45ファイル）、ルートの生成Analysis.logを削除。移行専用コードも削除。
- APIキー、現行CSV・config、有効設定、画像キャッシュ、送信記録は保持。ゲーム連携用txtはEmueraのLOADTEXT/SAVETEXT拡張子制限に合わせて維持。
- この再開メモと再実行可能なテストは保持。一時テストは自身の作業領域を終了時に削除する。

## 検証
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/test.ps1`: PASS。実行時のプレイヤー/相手のCSV検索、CSV変更の再読込、キャラ切替・未登録/空欄の名前使用、固定system不変、V3での全結合。CSV往復、V3/V4/V5切替、V5送信形式、設定保存、不正値拒否、キャッシュ、ZIP、APIモック、失敗後再送防止も確認。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/test-render.ps1`: PASS。実EmueraでキャラNO/あなたキャラ化記録/送信行の一致、設定メニュー構文、HTML_PRINTまで無効・待機・画像あり・特殊文字を検証。
- 旧TXTなしの隔離環境でexport-csvを実行しPASS、既存actions.csvのハッシュ不変を確認。
- 実Emueraから設定要求→別プロセスのSync-Settings→CSV保存・モデル変更・不正幅拒否も検証済み（使い終えた隔離環境は削除済み）。
- `git -c core.whitespace=cr-at-eol diff --check`: PASS。ERBのCRLFとPowerShellのUTF-8 BOMを維持。
- ログ追加後もtest.ps1はPASS。日時付き状態ログの重複抑止と、APIエラー詳細のキー非表示を検証。

## 運用・残る確認
- 更新前に稼働していたワーカーを停止・更新・再起動済み。現在は稼働中、画面用設定もV5 Fullへ同期済み。ゲーム内の新しいモデル選択肢を読み込むにはゲーム再起動が必要。既存APIキーを保持、再入力不要。
- 再起動後の自動生成でV5 Fullの実API生成・PNG保存を確認。preview.jsonはmodel=nai-diffusion-5-full、params_version=4、noise_schedule=karras。応答ハッシュと対応PNGの存在が一致。追加の手動生成は行っていない。調査はruntime/status.txtとpreview.jsonから始め、キーをチャットへ出さない。
- キャラテンプレート廃止後もワーカー再起動済み。新しいCSV検索・組立結果のハッシュと応答/保存画像が一致、生成成功を確認。prompts.csvのsystem/negativeは元の値を保持し、キャラ設定・行動CSV・config・APIキーも維持。新しい設定メニューはゲーム再起動後に反映。
- 隠しワーカーを停止し、ログ付きの通常ウィンドウで起動済み。コンソール親プロセスとworker.lockの占有、状態更新を確認。再開はnovelai/start.cmdを開く。
- 公式API: https://image.novelai.net/docs/doc.json
- V5公式案内: https://novelai.net/v5 。仕様確認元: https://novelai.net/_next/static/chunks/pages/_app-b7172cc1a6a0b340.js （2026-09-12、公開モデル定数・初期params_version・V5送信時のKarras固定・v4Prompts対応）。
