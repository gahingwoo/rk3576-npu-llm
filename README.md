# Kiln — LLM + vision on the mainline RK3576 NPU

Run **LLM and vision** inference on the **Rockchip RK3576 NPU** under a
**mainline** Linux kernel (7.x), by building the vendor GPL `rknpu` driver
**out-of-tree** and driving it with the closed `librkllmrt` (RKLLM, LLMs) and
`librknnrt` (RKNN, CNN vision) runtimes. Exposed as an integrable local service:
an **OpenAI-compatible API** (`kiln-serve`) plus a slash-command chat CLI over one
config file.

The vendor RKLLM/RKNN stack runs multi-matmul LLMs and convolutional vision on
RK3576 — but on the vendor 6.1 BSP kernel. Kiln puts that same stack (vendor
`rknpu.ko` v0.9.8 + `librkllmrt` + `librknnrt`) on a **mainline** kernel, using
mainline's own clock / power-domain / IOMMU drivers instead of the BSP's.
(The repo slug is still `rk3576-npu-llm`; the LLM was the hard target, vision the
control experiment that proved the driver fix generalises.)

> **Companion project:** [`linux-rk3576-npu`](https://github.com/gahingwoo/linux-rk3576-npu)
> is the other half of the same effort — the from-scratch *open* RK3576 NPU
> driver (rocket / mesa). Two routes to the same goal: this repo puts the vendor
> stack on a mainline kernel; that one builds an open driver from scratch.

## Status

**It works.** On real hardware (ROCK 4D, RK3576) on a mainline kernel, **both**
the RKLLM LLM stack and the RKNN vision stack run on the NPU: `kiln-chat` holds a
multi-turn Qwen2.5-1.5B conversation (9.3 tok/s) and `kiln-vision` classifies
images (~169 fps), on a **pure mainline `linux-7.1.3`** kernel built by CI with
Kiln's patch set (`kernel-patches/` 0001–0010) — not just the earlier hand-built
`linux-next` image.

Verified end-to-end (first on a hand-built `linux-next` 7.1 image, then on the
pure-mainline 7.1.3 CI kernel):

- The out-of-tree `rknpu` v0.9.8 driver builds against mainline 7.x and loads.
  One patch covers both the 6.1 → 7.x API drift and the RK3576 NPU-execution
  fixes (`driver/patches/README.md`).
- Probes cleanly against a mainline DT node; the runtime/driver/platform
  version-lock passes on the board (`rkllm 1.2.0` + `rknpu 0.9.8` + `RK3576`).
- **Matmul executes and tokens generate.** `librkllmrt` runs Qwen2.5-1.5B
  `w4a16` and answers coherently at **~9 tok/s decode, ~0.3 s time-to-first-token**
  (the chat prints a `[bench]` line per turn).

**Full serial log** — boot → `rknpu 0.9.8` loads → all four MMU banks enabled →
MobileNetV2 vision (~161 fps) and Qwen2.5-1.5B chat (9.3 tok/s), both on the NPU:
[**gist**](https://gist.github.com/gahingwoo/545f90ed2b0e7542e2953e089c60ee01).
Pure **mainline linux-7.1.3** run (`kiln-chat` with slash commands + `kiln-vision`,
9 tok/s / 169 fps):
[**gist**](https://gist.github.com/gahingwoo/abaa95815953b904346b6c74a1c0fc8a).

The core porting problem — and why a naive port only produces `task_counter=0`
timeouts — is that the NPU is **one device with two IOMMUs**, but mainline
`rockchip-iommu` manages only a single primary iommu, leaving the second core's
MMU disabled: its jobs read the regcmd IOVA as a raw physical address → garbage →
no execution. Kiln enables all four MMU banks from the driver and flushes their
TLB per job. Full write-up in [`driver/patches/README.md`](driver/patches/README.md).

Bring-up caveats (honest):

- The RK3576 NPU needs **kernel** fixes, not just the module. A *cold* NPU
  power-on needs a settle delay, a BIU reset pulse, the full domain clock set and
  a core "arm" (`kernel-patches/` 0001/0002/0005/0009) or the first NPU register
  read SErrors. The subtler one: the ROCK 4D board DTS marks the NPU rail
  `vdd_npu_s0` only `regulator-boot-on`, so ~30 s after boot the regulator core
  disables it once the driver's probe balances its refs — while the genpd domain
  still reports "on". The **second** NPU inference then reads a register on a
  dead rail and the MMIO read wedges the CPU (RCU stall). So the first chat turn
  works and the second hangs the board. The fix is one line —
  `regulator-always-on` on `vdd_npu_s0` (`kernel-patches/0010`), exactly what the
  vendor BSP and the buildroot linux-next kernel carry. With it, ROCK 4D holds a
  multi-turn Qwen2.5-1.5B chat at **9.3 tok/s on pure mainline 7.1.3**. (The
  "keep the NPU resident via a sysfs `power/control=on` udev rule" idea explored
  during bring-up was a dead end — the driver already keeps the NPU warm 10 min
  between jobs; the rail-always-on is the real fix.)
- The orphan MMU's TLB is flushed per-job rather than tracked by the iommu core —
  fine for inference, not a general-purpose iommu fix.
- The **Armbian** path (DKMS + DT overlay, see [`ARMBIAN.md`](ARMBIAN.md)) is
  portable by construction (no kernel patches — all fixes are in the module + a
  DT overlay) but not yet tested on an Armbian release.

**Also works — image inference (the CNN control experiment):** a MobileNet / RKNN
path (`librknnrt`) classifies an image on the same NPU, confirming the driver fix
generalises from transformer matmul to convolution. `kiln-vision <image>` runs
MobileNetV2 and prints the top-5 ImageNet classes — **~6 ms / ~160 fps, correct
labels** on the RK3576 NPU. See [`VISION.md`](VISION.md). (The `.rknn` must be
version-matched to `librknnrt` — same model/runtime lock as RKLLM.)

## Serve & configure

Kiln is an **integrable local NPU service**, not just a demo. Three tools, one
config (`/etc/kiln/config.ini`, read by all of them):

- **`kiln-serve`** — an **OpenAI-compatible** HTTP API for the LLM. Point the
  `openai` SDK / LangChain / any OpenAI client at the board:

  ```sh
  kiln-serve                       # listens on [server] host/port from the config
  curl -N http://<board>:8080/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"hi"}],"stream":true}'
  ```

  `GET /v1/models`, `POST /v1/chat/completions` (SSE streaming), and an optional
  `POST /v1/vision/classify`. It reuses the same `librkllmrt` calls as
  `kiln-chat` — no re-implemented inference — and is header-only
  (`cpp-httplib` + `nlohmann/json`, no Python). Runs standalone or as a
  `systemd` service. See [`docs/SERVER.md`](docs/SERVER.md).
- **`kiln-chat`** — the interactive LLM CLI, with **slash commands** to manage
  the session: `/model` to list or switch models (arrow-key picker), `/system`
  to set the system prompt, `/history` for multi-turn memory, `/clear` / `/new`,
  `/context`. Type `/help`. See [`docs/CHAT.md`](docs/CHAT.md).
- **`kiln-vision`** — the image-classification CLI.

All three read `/etc/kiln/config.ini` (edit it by hand — the fields are the ones
the closed runtimes actually expose; see [`docs/CONFIG.md`](docs/CONFIG.md)).

## Build

The whole thing is assembled as a buildroot br2-external:

```sh
# 1. Fetch the GPL rknpu v0.9.8 source (not redistributed here)
driver/fetch-vendor-driver.sh

# 2. Fetch the closed runtimes (librkllmrt / librknnrt) into buildroot/dl
buildroot/fetch-runtimes.sh

# 3. Build the flashable image (rootfs + kernel module + model baked in)
buildroot/build-image.sh
```

The module alone can be built against any mainline kernel tree:

```sh
make KDIR=/path/to/your/kernel/build     # after fetch + apply-shims
```

**On Armbian** (stock mainline kernel, no kernel rebuild) — one command:

```sh
curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
```

It bootstraps the prereqs, builds the driver with DKMS (vermagic matches the
running kernel), installs a self-contained NPU device-tree overlay, and installs
the runtimes + demos. See [`ARMBIAN.md`](ARMBIAN.md).

The DT node uses the **real** vendor RK3576 addresses (see `dts/`), not the
guessed open-driver layout.

## Layout

- `dts/` — RK3576 NPU board DTS + `*-kiln-npu.dtso` device-tree overlay (Armbian)
- `driver/fetch-vendor-driver.sh` — pull the GPL v0.9.8 `rknpu` source
- `driver/apply-mainline-shims.sh` — apply `patches/kiln-mainline.patch` (idempotent)
- `driver/patches/` — the one mainline + NPU-execution patch, with a rationale README
- `driver/compat/` — build-time compat stub headers for BSP-only `soc/rockchip/*`
- `Kbuild`, `Makefile`, `dkms.conf` — out-of-tree module build (DRM_GEM path; DKMS)
- `buildroot/board/rock4d/` — the tools' sources: `kiln_config.h` (unified config),
  `kiln_llm.h` / `kiln_vision.h` (runtime wrappers), `kiln_serve.cpp` (API server),
  `rkllm_chat.cpp` (slash-command chat CLI) / `rknn_mobilenet.cpp` (vision CLI)
- `kernel-patches/` — RK3576 NPU pmdomain/iommu/DT patches (mainline build)
- `kernel-patches-rk3568/` — RK3568 (ROCK 3B) NPU patches (untested; see `RK3568.md`)
- `capture/` — NPU per-op capture + the rocket cold-start-arm breakthrough probe
- `docs/SERVER.md`, `docs/CHAT.md`, `docs/CONFIG.md` — kiln-serve API, kiln-chat slash commands, config reference
- `scripts/kiln-install.sh` — one-shot installer (mainline kernel + module + tools)
- `ARMBIAN.md`, `MAINLINE-KERNEL.md` — kernel paths
- `VISION.md` — MobileNet / RKNN image inference (the CNN control experiment)

## Credits

- **Driver base:** [`armbian/linux-rockchip`](https://github.com/armbian/linux-rockchip)
  (rk-6.1-rkr6.1), which carries the GPL-2.0 vendor `rknpu` v0.9.8 driver
  (byte-identical to `rockchip-linux/kernel` develop-6.1).
- **Out-of-tree port reference:** [`w568w/rknpu-module`](https://github.com/w568w/rknpu-module)
  — proof that the v0.9.8 `rknpu` driver builds and runs on a mainline kernel.
  Kiln does not vendor its code; its `drm_driver` shims and `soc/rockchip/*`
  compat stubs were a useful reference for the RK3576 port. Thanks to its author.

## License

GPL-2.0 (see `LICENSE`). Kiln wraps and builds the GPL-2.0 vendor `rknpu`
driver, whose source is **fetched, not redistributed** here
(`driver/fetch-vendor-driver.sh`). The `librkllmrt` / `librknnrt` runtimes are
closed and distributed by Rockchip; Kiln does not include them. Model weights
are licensed separately and are not included.
