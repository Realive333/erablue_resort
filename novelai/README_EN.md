# NovelAI Automatic Single-Image Generation

The in-game “NovelAI” tab generates images from the player, contact characters, and the most recent action. It includes one player and up to five contact characters.

## Setup and startup

1. For NovelAI, run `setup-token.cmd` and enter the **Persistent API token**. It is stored in `runtime/token.dpapi`, decryptable only by the current Windows user. `NOVELAI_API_TOKEN` can also be used and takes priority.
2. Run `start.cmd`. It uses Windows PowerShell and requires no Python or extra packages.
3. Restart the game, enable `OPTION → [5] NovelAI 自動一枚絵の設定 → [0] 有効`, and open the “Multi-Person Single Image” tab.

Generation is disabled by default. Defaults are one image per request, a 30-second minimum interval, and 20 submissions per worker startup. Failed submissions count toward the limit. Generation consumes Anlas according to the plan.

Run `stop.cmd` or close the worker window to stop it. A request in progress stops after its response or timeout. Disabling the feature in-game stops new generation and image display. Logs are also available in `runtime/preview.json` without the API key.

Saved images appear in the “NovelAI” tab and completed generation or regeneration results update automatically. Display updates do not advance in-game time. After installation or updates, save and restart the game. The MOD is `ERB/追加MOD_NovelAI一枚絵/`; updates while waiting for input also require the hook in `ERB/TRAIN_MAIN.ERB`.

## Local generation (ComfyUI / Forge Neo)

ComfyUI or Forge Neo (Reforge-Neo) can be used instead of NovelAI. Start the backend first.

1. Start ComfyUI normally or Forge Neo with `--api`. Defaults are `http://127.0.0.1:8188` for ComfyUI and `http://127.0.0.1:7860` for Forge Neo.
2. Run `set-backend.cmd` and set `comfyui` or `forge` with the API URL. Select `novelai` to switch back.
3. For ComfyUI, export the workflow as API JSON and place it at `novelai/comfyui-workflow.json`. `comfyui-workflow.sample` is a standard-workflow sample. For other workflows, set the actual node numbers in `config.json` (`comfyui_*_node`).
4. Set the model with `set-model.cmd`. Forge Neo uses `/sdapi/v1/options`; ComfyUI uses `ckpt_name` (or `unet_name` / `model_name`) in the node specified by `comfyui_model_node`. Do not change the model in-game.
5. Run `start.cmd` and enable automatic generation. Saving, caching, regeneration, and disabled automatic resubmission after failures work as with NovelAI.

For non-standard workflows such as Flux, SD3, or Qwen, provide nodes for positive/negative prompts, Seed, Steps, CFG, width, and height, then update the node numbers in `config.json`. Response images are saved as PNG files in `resources/NovelAI/`.

## CSV prompts

The worker reloads the files after editing. Save them as **CSV UTF-8** in spreadsheet applications.

| File | Columns | Contents |
| --- | --- | --- |
| `prompts.csv` | `key,prompt` | `system` (global instructions) and `negative` |
| `characters.csv` | `no,prompt` | Appearance tags by character number |
| `actions.csv` | `name,scene,actor,target,source,status` | Action tags |

Only `system` and `negative` are valid keys in `prompts.csv`. `source` and `status` are management fields and are not sent to the API. Do not duplicate keys.

At runtime, character numbers are looked up in `characters.csv`; a missing or blank entry falls back to the in-game name. Construction order is “fixed system → characters → actions → API prompt.” V4/V5 use global and per-character fields; V3 combines everything into one prompt.

Character submission order is **target character → player → other contact characters**. `scene` applies to the overall image; `actor` and `target` apply to the actor and target. Press [Regenerate] to apply changes to existing images.

The action CSV contains 342 entries; 77 have initial tags and the rest are blank or marked `要設定`. Keys must exactly match in-game names. If no scene tag is available, the `scene` value from the `待機` row is used. Run `export-csv.cmd` to add new static command names and continuous actions. Old TXT prompts have been migrated to CSV.

## In-game settings and models

`OPTION → [5] NovelAI 自動一枚絵の設定` (or `[NovelAI設定]` in the single-image area):

- `[1]` / `[2]`: `system` / `negative` in `prompts.csv`.
- `[3]`: The current player’s row in `characters.csv`.
- `[7]`: The current partner’s row in `characters.csv`.
- `[9]`: Width, height, Steps, prompt strength, Sampler, Seed, interval, submission limit, CFG Rescale, Noise schedule, and prompt format.

The worker must be running to save in-game changes. CSV and config files can also be edited externally; invalid settings stop new generation. Use `\(` / `\)` for half-width parentheses in-game. Parentheses can be written normally in CSV. [Emuera specification](https://evilmask.gitlab.io/emuera.em.doc/Emuera/expression.html#inputs)

In `config.json`, `backend` is `novelai` / `comfyui` / `forge` and `api_url` is the local API endpoint. The default NovelAI model is `nai-diffusion-5-full`; change it with `set-model.cmd`.

`prompt_format` is `auto` (V3/V4/V4.5/V5), `v4` (per-character), or `legacy` (single prompt). Use `auto` or `v4` for V5. V5 sends `params_version=4` and `noise_schedule=karras`. Local backends combine all character tags into one prompt.

Width and height must be multiples of 64 from 64 to 2048. Steps: 1–50; scale: 0–10; CFG Rescale: 0–1. Seed=-1 randomizes new generations.

## Caching, regeneration, and resuming

- Image names use `0-123_会話する.png`: the first ID is the player, followed by contact characters. Join multiple actions with `+`; use `待機` when there is no action. Windows-forbidden characters become `_`; names over 180 characters fail before submission.
- Before an API request, an image with the same name in `resources/NovelAI/` is reused. The cache is reused for the same character IDs and action even if the model, settings, or tags change. Press `[Regenerate]` to apply changes.
- Normal generation uses only the latest scene. Regeneration ignores the cache, sends once, uses a new Seed even with a fixed Seed, and replaces the file only after receiving a valid PNG.
- Communication failures and interruptions are recorded and not resubmitted automatically. The previous image is kept; press `[Regenerate]` again to retry. An unknown result may already have been charged.
- After reaching the limit, resume with `stop.cmd` → `start.cmd`. Settings, images, and failure records are retained.

`runtime/status.txt`: state; `runtime/preview.json`: API request without the key; `runtime/unmapped-actions.txt`: unmapped action names. For code work, read the root `NOVELAI_PROGRESS.md` first.

## Offline verification

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File novelai/test-render.ps1
```

API keys, generated images, and communication files are excluded from Git. To keep the key and submission records, clean images under `resources/NovelAI` instead of deleting all of `runtime`.

API: [NovelAI](https://image.novelai.net/docs/index.html) / [OpenAPI](https://image.novelai.net/docs/doc.json) / [ComfyUI routes](https://docs.comfy.org/development/comfyui-server/comms_routes) / [ComfyUI workflow example](https://github.com/comfyanonymous/ComfyUI/blob/master/script_examples/basic_api_example.py) / [Forge Neo](https://github.com/Haoming02/sd-webui-forge-classic/tree/neo)
