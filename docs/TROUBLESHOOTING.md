# Troubleshooting

Start here: **`sudo kiln-doctor`**. It runs the same checks this guide is organised
around and prints a `[ OK ] / [FAIL] / [WARN] / [INFO]` line for each. Paste its full
output into any [issue](https://github.com/gahingwoo/kiln/issues) — it is the single
most useful thing to include.

This page maps **the exact symptom or error string** → what it means → how to fix it.
Search it (Ctrl-F) for the message you're seeing.

- [Install & kernel](#install--kernel)
- [NPU driver & power](#npu-driver--power)
- [Models & version-lock](#models--version-lock)
- [Vision (classify & detect)](#vision-classify--detect)
- [LLM & chat](#llm--chat)
- [API server](#api-server)
- [Model conversion (kiln-convert)](#model-conversion-kiln-convert)
- [Wi-Fi & network](#wi-fi--network)

---

## Install & kernel

### The board rebooted and the screen is blank / "nothing happened"
**Expected.** The install is hands-off: the board **reboots itself twice** (~10–15 min
total). After the first reboot it finishes setup **offline, before login is allowed**,
then reboots again. Onboard Wi-Fi is **down between the reboots** (also expected — phase
2 rebuilds it). **Don't cut power.** When it's done you'll see a `Kiln installed` note at
the next login, or run `kiln-doctor`. Full log: `/var/log/kiln-phase2.log`.

### Phase 2 failed
`kiln-doctor` shows `[FAIL] phase-2 install FAILED`. Read the log and re-run (it runs
offline from the phase-1 cache):
```sh
cat /var/log/kiln-phase2.log
sudo bash /opt/kiln/scripts/kiln-install.sh
```

### Every Kiln update reinstalls the kernel and reboots
Fixed — **kernel updates are opt-in.** Once you're on the Kiln kernel, a normal re-run
(or `kiln-config → System → update`) rebuilds only the driver + runtimes and does **not**
touch the kernel. To deliberately pick up a newer kernel: `KILN_CHECK_KERNEL=1 bash
kiln-install.sh` (or `System → check for a kernel update`).

### `apt` is stuck / "dpkg was interrupted" / kernel half-configured
A DKMS module that won't build on the running kernel (often the stock `aic8800`) leaves
the kernel package half-configured, which blocks all `apt`. The installer heals this
automatically now; to do it by hand:
```sh
sudo dpkg --configure -a          # if it complains a module won't build:
sudo dkms status                  # find the offending module/version
sudo dkms remove <module>/<ver> --all
sudo dpkg --configure -a
```

### `no /boot/armbianEnv.txt — this installer targets Armbian`
The one-command installer targets **Armbian** userspace. On another distro, build the
kernel yourself ([MAINLINE-KERNEL.md](MAINLINE-KERNEL.md)) and install the module with
DKMS.

### `aarch64 only (found …)`
Kiln is ARM64. You're on the wrong architecture / a cross shell.

---

## NPU driver & power

### `kiln-doctor: [FAIL] rknpu NOT loaded`
The vendor NPU module isn't loaded:
```sh
sudo modprobe rknpu
sudo dmesg | grep -i rknpu
```
It normally auto-loads at boot via `/etc/modules-load.d/rknpu.conf`. If `modprobe`
fails, you're probably **not on the Kiln kernel** (see below) or the DKMS build didn't
install — re-run `kiln-config → System → rebuild the NPU driver`.

### `[FAIL] no /dev/dri/renderD* render node`
The driver didn't bind the NPU. Confirm `rknpu` is loaded and you're on the Kiln kernel,
then **reboot** (the DT's NPU node is bound at boot). Expect `renderD128` or `renderD129`.

### `failed to get pm runtime for npu0, ret: -110`  (in `dmesg`)
The classic **"works once, then hangs on the second inference"** bug. The NPU power rail
(`vdd_npu_s0`) is only `regulator-boot-on` in the board DTS, so it's switched off ~30 s
into boot; the next inference reads a dead rail and wedges the board. Fixed by
`regulator-always-on` in **`kernel-patches/0010`** — which is **compiled into the Kiln
kernel**, so the fix is: **be on the Kiln kernel** (`kiln-doctor` → "running the Kiln
patched kernel"). A stock/Armbian kernel cannot supply this from a module. On another
RK3576 board you must add the same one-line fix to *its* board DTS.

### MMU state is not `st=0x19/0x19/0x19/0x19`
The RK3576 NPU is one device with **two IOMMUs / four MMU banks**; mainline
`rockchip-iommu` drives only one, so a naive port reads the second core's addresses as
garbage (`task_counter=0` timeouts). Kiln's driver enables all four banks and flushes
their TLB per job. If you don't see `0x19/0x19/0x19/0x19`, you're running a non-Kiln
driver or kernel — reinstall the Kiln driver and reboot.

### `SError` / hang on the very first inference
A cold NPU power-on needs a settle delay + BIU reset + core "arm" that only the Kiln
kernel patches provide. This is the reason a **stock** mainline kernel isn't enough; use
the Kiln kernel (CI `.deb`s, or build per [MAINLINE-KERNEL.md](MAINLINE-KERNEL.md)).

---

## Models & version-lock

Kiln ships **no** models — you supply them. Both runtimes are **version-locked**: a
model must match the runtime it runs on.

| runtime | version | model must be built with |
|---|---|---|
| `librkllmrt` (LLM) | **1.2.0** | `rkllm-toolkit` **1.2.0** |
| `librknnrt` (vision) | **2.3.0** | `rknn-toolkit2` **2.3.x** |

### `terminate … std::out_of_range … in rknn_inputs_set`
The `.rknn` was converted with the **wrong `rknn-toolkit2` version** (e.g. 2.1.0) for the
2.3.0 runtime. It's not a bug in Kiln's code — it's the version-lock. **Reconvert with a
matching toolkit** — the easy way pins it for you:
```sh
kiln-convert mobilenet          # or: kiln-convert <your.onnx>   (installs rknn-toolkit2==2.3.0)
```
`kiln-doctor` reads the converter version embedded in a `.rknn` and flags a mismatch.

### `rkllm init failed` / the LLM won't load
Usually a `.rkllm` built for a **different `librkllmrt`** than 1.2.0 (the runtime checks
at load). Rebuild/obtain a **1.2.0** `.rkllm`. Also check the file isn't truncated (a
half-finished `scp`).

### `kiln-doctor: [FAIL] LLM/vision model MISSING`
The configured path doesn't exist and nothing auto-discoverable is in `/opt/models`. Put
a model there, or build one (`kiln-convert mobilenet`), or fix the path in
`kiln-config → Models`.

---

## Vision (classify & detect)

### `kiln-vision: no vision model found`
No `.rknn` in `/opt/models` and none configured. Build one on the board:
```sh
sudo kiln-convert mobilenet --set-active     # classifier
# or
sudo kiln-convert yolov8n  --set-active      # YOLO detector
```

### `kiln-vision` segfaults on a YOLO `.rknn`
The `.rknn` is an **end2end / NMS-in-model** export (`[1, N, 6]` output). rknn-toolkit2
*converts* it, but the in-model NMS ops (TopK / GatherElements) **don't run on the RK3576
NPU — the runtime crashes** (classification on the same box still works, which is the
tell). Export with **NMS OFF** and let Kiln do NMS on the CPU:
```sh
yolo export model=yolov8n.pt format=onnx nms=False opset=19 imgsz=640
kiln-convert ./yolov8n.onnx --set-active
```
`kiln-convert yolov8n` already fetches an NMS-off export. See [VISION.md](VISION.md).

### Detection runs but the labels are wrong (e.g. `goldfish`, `cock`, `bulbul`)
The **boxes/classes are correct**, but `[vision] labels` points at the **ImageNet-1000**
list (for classification), not **COCO-80** (for detection). Switch it:
```sh
sudo kiln-config       # Vision → labels → coco_80_labels.txt   (it offers to do this)
```
`kiln-doctor` warns when `task=detect` but the labels file has >200 classes.

### Detection reports 0 objects / falls back to the wrong family
If you just rebuilt, confirm the binary actually has the new decoders:
`strings /usr/bin/rknn_mobilenet | grep -c yolo-raw` should be > 0. Force the family
with `[vision] detector = yolov8|yolov5|yolox|yoloraw` if `auto` guesses wrong, and check
the printed family + first boxes against a known image.

### Classes look right but boxes are shifted
Almost always a preprocessing mismatch: the model expects `mean=0 std=255` (YOLO) — which
`kiln-convert`'s `yolo` preset sets. A model converted with ImageNet mean/std for a
detector will misplace boxes.

---

## LLM & chat

### `kiln-chat: no LLM model available`
Put a `*-rk3576-w4a16.rkllm` (matched to `librkllmrt` 1.2.0) in `/opt/models`; `kiln-chat`
auto-discovers any `.rkllm` there. (There is no on-board `.rkllm` conversion — LLM models
are supplied, unlike vision.)

### The model repeats itself / rambles / never stops
Bump `repeat_penalty` (e.g. `1.3`) and keep `top_k = 1` on the small 1–1.5B models
(`kiln-config → LLM`, or `/help` live). Generation stops on the model's EOS / role-label
stop tokens; a wildly wrong system prompt can still derail small models — `/clear` or
`/new` to reset.

### Chinese / non-ASCII input edits badly
That needs `readline` at build time (cursor + UTF-8). `kiln-doctor` doesn't check this;
rebuild with `libreadline-dev` present (the installer pulls it in). Without it, `kiln-chat`
falls back to a plain line read.

### Multi-turn memory isn't working
`[llm] keep_history` must be `1` (`/history on`). With it `0`, each turn is independent.

---

## API server

### `POST /v1/chat/completions` returns `503 no LLM on this box`
`kiln-serve` started **vision-only** (no `.rkllm` loaded). Add an LLM model and restart:
`kiln-config → Server → service → restart`.

### Open WebUI / a client can't reach the server
- Bind on all interfaces: `[server] host = 0.0.0.0` (not `127.0.0.1`), then restart.
- Check it's up: `curl http://<board-ip>:8080/v1/models`.
- Firewall: make sure the port (default `8080`) is reachable on your LAN.
- See [OPENWEBUI.md](OPENWEBUI.md) for the full Open WebUI / LangChain / `openai` setup.

### `failed to bind <host>:<port>`
Another process holds the port, or you lack permission. Change `[server] port`, or stop
the other listener (`sudo ss -ltnp | grep :8080`).

---

## Model conversion (kiln-convert)

### `couldn't install rknn-toolkit2==2.3.0 from PyPI`
The matching aarch64 wheel may not be on PyPI. Grab it from
[`airockchip/rknn-toolkit2`](https://github.com/airockchip/rknn-toolkit2)
(`rknn-toolkit2/packages/`) and point `kiln-convert` at it — it must match the runtime:
```sh
kiln-convert --wheel /path/to/rknn_toolkit2-2.3.0-*aarch64.whl <source>
```

### `python3-venv not found`
`sudo apt install python3-venv` (the installer normally does this). The first conversion
also downloads a few hundred MB of toolkit — that's expected, and only once.

### `ModuleNotFoundError: pkg_resources` during conversion
An old setuptools gotcha; `kiln-convert` pins `setuptools<81` in its venv. If you built
the venv by hand, `pip install 'setuptools<81'`.

---

## Wi-Fi & network

### No Wi-Fi after installing
Moving to the mainline kernel drops the out-of-tree `aic8800` driver; Kiln rebuilds a
patched one in phase 2. If it still didn't build, **use Ethernet** (always works) and:
```sh
sudo dkms status | grep aic8800
sudo bash /opt/kiln/scripts/kiln-install.sh   # re-runs the wifi build
```
Wi-Fi is optional for everything Kiln does — the NPU doesn't need it.

### Wi-Fi is down *between* the two install reboots
Expected and temporary — phase 2 runs fully offline and rebuilds Wi-Fi before you log in.

---

## Still stuck?

Open an [issue](https://github.com/gahingwoo/kiln/issues) with:
1. `sudo kiln-doctor` output (the whole thing),
2. `sudo dmesg | grep -iE 'rknpu|npu|iommu'`,
3. what you ran and what you expected. Wins, failures, and dmesg are all welcome —
   especially from **boards other than the ROCK 4D**, which is the only one tested so far.
