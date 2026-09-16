# NovelAI 自動一枚絵

ゲーム内の「NovelAI」タブで、プレイヤー・接触中のキャラ・直近の行動を使った画像を生成します。対象はプレイヤー1人＋接触相手最大5人です。

## 導入・起動

1. NovelAIを使う場合は `setup-token.cmd` を実行して **Persistent API token** を入力します。トークンは現在のWindowsユーザーだけが復号できる `runtime/token.dpapi` に保存されます。環境変数 `NOVELAI_API_TOKEN` も使え、こちらが優先されます。
2. `start.cmd` を実行します。Windows標準のPowerShellだけで動作します。
3. ゲームを再起動し、`OPTION → [5] NovelAI 自動一枚絵の設定 → [0] 有効` にして「NovelAI」タブを開きます。

初期状態は無効です。初期設定は1回1枚、生成間隔30秒以上で、ワーカー起動1回あたりの送信回数に上限はありません。生成には契約に応じてAnlasが必要です。

`stop.cmd` で停止できます。ウィンドウを閉じても停止します。通信中は応答またはタイムアウト後に停止します。ゲーム内で無効にすると新規生成と画像表示を停止します。ログは `runtime/preview.json` でも確認できます（APIキーは含みません）。

保存済み画像は「NovelAI」タブに表示され、生成・再生成の完了時に自動更新されます。表示更新でゲーム内時間は進みません。導入・更新後はゲームをセーブして再起動してください。MOD本体は `ERB/追加MOD_NovelAI一枚絵/`、入力待ち中の更新には `ERB/TRAIN_MAIN.ERB` の入力フックが必要です。

## ローカル生成（ComfyUI / Forge Neo）

NovelAIの代わりにComfyUIまたはForge Neo（Reforge-Neo）を使えます。先にバックエンドを起動してください。

1. ComfyUIは通常起動、Forge Neoは `--api` 付きで起動します。既定APIはForge Neoが `http://127.0.0.1:7860`、ComfyUIが `http://127.0.0.1:8188` です。
2. `set-backend.cmd` で `comfyui` または `forge` とAPI URLを設定します。NovelAIへ戻す場合は `novelai` を選びます。
3. ComfyUIでは **ワークフロー → 書き出し(API)** のJSONを `novelai/comfyui-workflow.json` に置きます。`comfyui-workflow.sample` は標準構成のサンプルです。別workflowでは `config.json` の `comfyui_*_node` を実際のノード番号に変更します。
4. `set-model.cmd` でモデルを設定します。Forge Neoは `/sdapi/v1/options`、ComfyUIは `comfyui_model_node` の `ckpt_name`（または `unet_name` / `model_name`）を使います。モデルはゲーム内では変更しません。
5. `start.cmd` を実行し、ゲーム内で自動生成を有効にします。保存先、キャッシュ、再生成、失敗時の自動再送禁止はNovelAIと同じです。

標準以外のComfyUI workflow（Flux、SD3、Qwenなど）では、正負プロンプト、Seed、Steps、CFG、幅、高さを受け取るノードを用意し、`config.json` の番号を合わせてください。応答画像は `resources/NovelAI/` にPNGで保存されます。

## CSVプロンプト

編集後はワーカーが自動で読み直します。Excelなどでは **CSV UTF-8** で保存してください。

| ファイル | 列 | 内容 |
| --- | --- | --- |
| `prompts.csv` | `key,prompt` | `system`（全体指示）と`negative` |
| `characters.csv` | `no,prompt` | キャラNOごとの外見タグ |
| `clothes.csv` | `name,prompt,source,status` | 現在の服装名・着用状態に対応するタグ |
| `actions.csv` | `name,scene,actor,target,source,status` | 行動タグ |

`prompts.csv` のkeyは `system` と `negative` のみです。`source` と `status` は管理用でAPIには送りません。同じkeyは重複させないでください。

実行時にキャラNOを検索し、`characters.csv` のpromptを使います。未登録・空欄ならゲーム内の名前を使います。組立順序は「固定システム → キャラ → 行動 → API用プロンプト」です。V4/V5は全体欄と個別キャラ欄に分け、V3は1本に結合します。

キャラの送信順は **目標キャラ → プレイヤー → その他の接触キャラ** です。`scene` は画像全体、`actor` / `target` は実行者・対象者に追加します。既存画像へ反映するには［再生成］を押してください。

キャラ欄には **外見タグ → 現在の服装タグ → 行動タグ** の順で追加します。服装名は着せ替え中の名前、普段着は `CSTR:服名称` から取得します。脱衣後の `TEQUIP` を参照し、外側の服がない部位だけ下着・タイツ・露出を追加します。全部脱いだ場合は元の服を追加せず `全裸` の行を使います。キャラ番号で指定する衣装も、そのキャラの服名称へ変換します。

`clothes.csv` はERBの `CLOTHES_CHANGE_*`・服名称の定義と、既存キャラクターCSVの服名称から抽出しています。一般的な衣装・着用状態には英語の初期タグ、独自名称には元の日本語名を設定しています。`prompt` は自由に編集でき、空欄なら追加しません。`上半身下着_1` はブラ、`下半身下着_1` は通常の下着など、番号はゲームの着用状態に対応します。未登録・空欄の服装はログと `runtime/unmapped-clothes.txt` に記録します。

`export-csv.cmd` は行動と服装の新しい定義を追加し、編集済みタグを保持します。服装だけ更新する場合は `powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/scripts/export-clothes.ps1` を実行します。服装の変更でも画像名は従来のキャラID＋行動名を使うため、保存済み画像を現在の服装で作り直すには `[再生成]` を押してください。導入後はワーカーとゲームの再起動が必要です。

行動CSVには342件を登録し、77件に初期タグを設定しています。残りは空欄・`要設定`です。キーはゲーム内表示名と完全一致します。行動がない、または場面タグがない場合は `待機` 行の `scene` を使います。`export-csv.cmd` で新しい静的コマンド名と継続動作を追加できます。旧TXTプロンプトはCSVへ移行済みです。

## ゲーム内設定・モデル

`OPTION → [5] NovelAI 自動一枚絵の設定`（または一枚絵欄の `[NovelAI設定]`）:

「NovelAI」タブの `[NovelAI設定]` は、画像なし・生成待ち・自動生成無効の状態でも表示されます。

- `[1]` / `[2]`: `prompts.csv` のsystem / negative。
- `[3]`: 現在のプレイヤーの`characters.csv`。
- `[7]`: 現在の相手の`characters.csv`。
- `[9]`: 幅、高さ、Steps、プロンプト強度、Sampler、Seed、生成間隔、CFG Rescale、Noise schedule、prompt format。

ゲーム内から保存するにはワーカーを起動してください。CSVとconfigは外部編集も可能です。不正な設定では新規生成を停止します。ゲーム内で半角括弧を入力する場合は `\(` / `\)` を使います。CSVでは括弧をそのまま書けます。[Emuera仕様](https://evilmask.gitlab.io/emuera.em.doc/Emuera/expression.html#inputs)

`config.json` の `backend` は `novelai` / `comfyui` / `forge`、`api_url` はローカルAPIです。NovelAIの初期モデルは `nai-diffusion-5-full` で、変更は `set-model.cmd` で行います。

`prompt_format` は `auto`（V3/V4/V4.5/V5）、`v4`（個別キャラ）、`legacy`（単一プロンプト）です。V5は `auto` または `v4` を指定します。V5は `params_version=4`、`noise_schedule=karras` で送信します。ローカルbackendでは全キャラのタグを1本に結合します。

幅・高さは64～2048の64倍数、Stepsは1～50、scaleは0～10、CFG Rescaleは0～1です。Seed=-1は新規生成時にランダム化します。

## キャッシュ・再生成・再開

- 画像名は `0-123_会話する.png` の形式です。先頭がプレイヤー、以降が接触相手です。複数行動は `+`、行動なしは `待機` です。Windowsで禁止される文字だけ `_` に置き換え、180文字超は送信前にエラーにします。
- API送信前に `resources/NovelAI/` の同名PNGを再利用します。キャラIDと行動が同じなら、モデル・設定・タグを変えてもキャッシュを使います。変更を反映するには `[再生成]` を押します。
- 通常は最新の場面だけを生成します。再生成はキャッシュを無視して1回送信し、固定Seedでも新しいSeedを使います。成功したPNGを受信してから置き換えます。
- 通信失敗・中断は記録し、自動再送しません。失敗時は以前の画像を保持し、再送はもう一度 `[再生成]` を押します。結果不明の送信は課金済みの可能性があります。
- `stop.cmd` で停止し、`start.cmd` で再開できます。設定・画像・失敗記録は保持されます。

`runtime/status.txt`: 状態、`runtime/preview.json`: API送信内容（キーなし）、`runtime/unmapped-actions.txt`: 未登録の動作名です。コード作業を再開する場合はルートの `NOVELAI_PROGRESS.md` を先に読んでください。

## オフライン検証

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/scripts/test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/scripts/test-local.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/scripts/test-controls.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/scripts/test-clothes.ps1
```

`test-controls.ps1` は無効・生成待ち・正常画像・画像読込失敗時の設定ボタンを検証します。既存の `test-render.ps1` は現在の実装にない自動更新関数に依存しており、そのままでは実行できません。

APIキー、生成画像、通信ファイルはGit対象外です。キー・送信記録を残す場合は `runtime` 全体を削除せず、画像だけ `resources/NovelAI` を整理してください。

API: [NovelAI](https://image.novelai.net/docs/index.html) / [OpenAPI](https://image.novelai.net/docs/doc.json) / [ComfyUI routes](https://docs.comfy.org/development/comfyui-server/comms_routes) / [ComfyUI workflow example](https://github.com/comfyanonymous/ComfyUI/blob/master/script_examples/basic_api_example.py) / [Forge Neo](https://github.com/Haoming02/sd-webui-forge-classic/tree/neo)
