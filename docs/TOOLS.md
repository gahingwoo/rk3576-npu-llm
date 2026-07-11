# kiln, kiln-doctor, kiln-config & kiln-convert

Helpers installed to `/usr/bin` alongside `kiln-chat` / `kiln-vision` / `kiln-serve`:
an umbrella launcher, a health check, a config TUI, and an on-board model converter.

## kiln — the launcher

`kiln` with no arguments opens a menu (whiptail) to pick a function; it also dispatches
straight to a tool:

```sh
kiln                 # menu: chat · vision · models · serve · config · doctor
kiln chat            # -> kiln-chat        (LLM chat CLI)
kiln vision <img>    # -> kiln-vision      (classify / detect; a 2nd path saves an annotated copy)
kiln models          # -> kiln-convert     (get / convert a model on the board)
kiln serve           # -> kiln-serve       (or start/stop the systemd service from the menu)
kiln config          # -> kiln-config
kiln doctor          # -> kiln-doctor
```

It only launches the tools below; each handles its own privileges (`kiln-config` /
`kiln-doctor` re-exec via `sudo` themselves). The tools read the same
`/etc/kiln/config.ini` (see [`CONFIG.md`](CONFIG.md)); `kiln-convert` builds a `.rknn`
on the board and can point the config at it.

## kiln-doctor — health check

`kiln-doctor` prints a plain-English pass/fail report — aligned `[ OK ]` / `[FAIL]` /
`[WARN]` / `[INFO]` labels, one per check — and **exits non-zero if any critical check
fails**, so it is scriptable and is the "paste this before opening an issue" tool. It
is also the engine behind kiln-config's Status page.

```sh
kiln-doctor          # full report
kiln-doctor -q       # quiet: only failures + the final verdict
sudo kiln-doctor     # run as root so it can read dmesg (MMU checks)
```

What it checks:

- **Kernel & install** — running the Kiln patched kernel? the phase-2 install marker
  (`/etc/kiln/phase2-done` / `phase2-failed`).
- **Driver** — `rknpu` loaded (+ version) and a `/dev/dri/renderD*` render node.
- **MMU state** — parses `dmesg` for all four banks armed
  (`mmu enable_all … st=0x19/0x19/0x19/0x19`) and flags the power-domain wedge
  (`failed to get pm runtime for npu0, ret: -110`).
- **Runtimes** — `librkllmrt` / `librknnrt` in `/usr/lib` (+ reported versions).
- **Tools** — `kiln-chat` / `kiln-vision` / `kiln-config` / `kiln-convert` / the demos on `PATH`.
- **Models** — the `[llm]` / `[vision]` models from the config exist on disk, and the
  vision `.rknn`'s embedded `rknn-toolkit2` version matches the `librknnrt` 2.3.x
  runtime (a mismatch throws `std::out_of_range` in `rknn_inputs_set`).
- **Network** — onboard wifi (optional; ethernet always works).

Exit code: `1` if any critical check fails (rknpu not loaded, no render node, MMU
wedge, a missing configured model, or a failed phase-2 install), else `0`.

## kiln-config — config TUI

`sudo kiln-config` is a `whiptail` (fallback `dialog`) menu tool, modelled on
`armbian-config`. It is a **front-end** to `/etc/kiln/config.ini`, never a
replacement: it edits the file **in place**, preserving your comments and any unknown
fields. It needs root (the config is root-owned and the Status page reads `dmesg`), so
it re-execs via `sudo` if you didn't.

Top menu:

| page | what |
|---|---|
| **Status** | runs `kiln-doctor`, renders the pass/fail report, with a Re-run button |
| **LLM** | `[llm]` — model (picker), temperature, top_k/top_p, max_new_tokens, max_context_len, repeat_penalty, keep_history, system_prompt |
| **Vision** | `[vision]` — task (classify/detect), model (picker), labels (picker), top_n, detector/conf/nms, core_mask, priority |
| **Server** | `[server]` host/port + `systemctl` control of `kiln-serve` |
| **Models** | **Get/convert** (runs `kiln-convert`), set the active LLM/vision model, list / inspect (sizes, `.rknn` toolkit version), add-from-path, remove |
| **System** | reload `rknpu`, rebuild the DKMS driver + restore wifi, update Kiln, check for a kernel update — each behind a yes/no confirm |

Conventions:

- **`<Save>` writes, `<Back>` discards** — nothing is persisted until you confirm, so
  a wrong turn never corrupts the config.
- **File pickers scan `/opt/models`** — pick a `*.rkllm` / `*.rknn` model or a `*.txt`
  labels file from a menu instead of typing a path.
- **Enums are radio lists** — `core_mask` (`auto`/`0`/`1`/`0_1`), `priority`
  (`high`/`medium`/`low`), `keep_history` (`1`/`0`), `detector` family.
- **Vision does classify (default) or detect (YOLO).** Switching to `task = detect`
  offers to point labels at COCO-80 and notes the export/licensing rules (NMS-off
  export, Ultralytics AGPL vs YOLOX Apache); see [`VISION.md`](VISION.md). No
  detector on disk? **Models → Get/convert** builds a YOLOv8n for you.
- Most changes apply the **next time** you start `kiln-chat` / `kiln-vision` /
  `kiln-serve`; System driver actions may need a reload or reboot (stated per action).

## kiln-convert — get / convert a model on the board

`kiln-convert` turns an ONNX into a version-matched `.rknn` **on the board** — no x86
dev machine, no manual `rknn-toolkit2` setup, no scp. On first use it builds a private
`rknn-toolkit2` venv under `/opt/kiln/rknn-venv`, **pinned to your installed
`librknnrt`** (a mismatched toolkit produces a `.rknn` that throws `std::out_of_range`
at load, so it refuses to install a different version). That first run downloads a few
hundred MB and takes a few minutes; later conversions are quick.

```sh
kiln-convert mobilenet            # pull MobileNetV2 (Apache-2.0) + convert -> classify
kiln-convert yolov8n              # pull YOLOv8n (Ultralytics AGPL-3.0! asks first) -> detect
kiln-convert ./my_model.onnx      # convert a local ONNX (type guessed from the name)
kiln-convert https://host/m.onnx  # download + convert
kiln-convert https://host/m.rknn  # just place a pre-converted .rknn into /opt/models
kiln-convert mobilenet --set-active   # ...and point /etc/kiln/config.ini at the result
```

Source can be a **model-zoo shortcut** (`mobilenet` / `yolov8n`, fetched from
`airockchip/rknn_model_zoo`), a **URL**, or a **local path**. Presets set the
normalization (`mobilenet`: ImageNet mean/std; `yolo`: `0..255`); override with
`--type` / `--mean` / `--std`. Default is fp16; `--quant --dataset FILE` does INT8 with
a calibration list. `--set-active` writes the model (and, for YOLO, `task = detect` +
COCO labels) into the config. See `kiln-convert --help` and [`VISION.md`](VISION.md).

> **Licensing.** Kiln bundles no models. `mobilenet` is Apache-2.0 (clean). `yolov8n`
> pulls Ultralytics weights, which are **AGPL-3.0** — `kiln-convert` shows a notice and
> asks before fetching. YOLOX (Apache-2.0) is a permissive alternative: point
> `kiln-convert` at a YOLOX ONNX by URL/path.
