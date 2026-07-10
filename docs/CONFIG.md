# Kiln configuration

Kiln keeps one config, `/etc/kiln/config.ini`, read by **every** tool — `kiln-chat`,
`kiln-vision`, `kiln-serve`, and also `kiln-config` and `kiln-doctor`. Nothing is
hard-coded per tool. `kiln-install.sh` seeds a working default, so a fresh box runs
without touching it.

## Editing it

It stays a **hand-editable** plain INI file — that is the single source of truth. Two
optional front-ends:

- **`sudo kiln-config`** — a whiptail TUI (LLM / Vision / Server pages). It edits the
  file **in place**, preserving your comments and any unknown fields; `<Save>` writes,
  `<Back>` discards. See [`TOOLS.md`](TOOLS.md).
- **`kiln-doctor`** — reads the file and checks the referenced models exist and are
  version-matched, alongside the driver/MMU health checks. See [`TOOLS.md`](TOOLS.md).

`kiln-chat` also changes a few LLM knobs live and persists them (below).

For the LLM you usually do not need to edit the file at all: `kiln-chat` can
change the live knobs with slash commands — `/model` to switch model, `/system`
to set the system prompt, `/history` for multi-turn memory (see
[`CHAT.md`](CHAT.md)). Those changes apply to the running session; put anything
you want to persist across restarts into the file.

## What is settable — and what is not

The two runtimes are closed blobs; **only fields the runtime API actually
exposes are here.** Anything baked into a model at conversion time is not a
setting.

### `[llm]` — librkllmrt (`RKLLMParam` + APIs)

| key | meaning |
|---|---|
| `model` | path to the `.rkllm` |
| `system_prompt` | system message content (wrapped in the model's ChatML markers) |
| `max_context_len` | context window (tokens) |
| `max_new_tokens` | max tokens generated per turn |
| `temperature`, `top_k`, `top_p` | sampling |
| `repeat_penalty`, `frequency_penalty`, `presence_penalty` | repetition control |
| `keep_history` | `1` = multi-turn (KV cache retained), `0` = single-turn |
| `n_keep` | KV tokens kept when the context window shifts; `-1` = runtime default |
| `embed_flash` | `1` = stream word-embeddings from flash, `0` = RAM |

KV-cache control **is** exposed by `librkllmrt` (`rkllm_clear_kv_cache`,
`keep_history`, `n_keep`) so Kiln surfaces it. Quantization/precision are baked
into the `.rkllm` at conversion — not settable.

### `[vision]` — librknnrt

| key | meaning |
|---|---|
| `model` | path to the `.rknn` |
| `labels` | class-labels text file (one per line) |
| `top_n` | how many classes to print/return |
| `core_mask` | NPU cores: `auto` \| `0` \| `1` \| `0_1` (RK3576 has 2 cores) |
| `priority` | RKNN scheduling priority: `high` \| `medium` \| `low` |
| `task` | `classify` (default) or `detect` — **detect is EXPERIMENTAL** (YOLO, unverified on hardware); see [`../VISION.md`](../VISION.md) |
| `detector` | detect family: `auto` \| `yolov8` \| `yolov5` \| `yolox` (used only when `task=detect`) |
| `conf_threshold`, `nms_iou` | detection score / NMS-IoU thresholds (used only when `task=detect`) |

**Not settable (baked into the `.rknn`):** input size/layout and the mean/std
normalization — the runtime bakes these in at conversion, so Kiln queries them,
it does not configure them.

### `[server]` — kiln-serve

| key | meaning |
|---|---|
| `host`, `port` | listen address |
| `llm_model` | `.rkllm` the server loads; blank = use `[llm].model` |
| `vision_model` | `.rknn` for `/v1/vision/classify`; blank = use `[vision].model` |

## Example

```ini
[llm]
model = /opt/models/Qwen2.5-1.5B-rk3576-w4a16.rkllm
max_context_len = 2048
temperature = 0.8
keep_history = 1          # 1 = multi-turn (default), 0 = single-turn
system_prompt = You are a helpful assistant.

[vision]
model = /opt/models/mobilenetv2-12_rk3576.rknn
labels = /opt/models/imagenet_labels.txt
top_n = 5
core_mask = auto
priority = high

[server]
host = 0.0.0.0
port = 8080
```

The tools also run with **no** config file (built-in defaults), so a fresh box
works before the file is ever written; `kiln-install.sh` seeds a default with
the SoC-correct vision model.
