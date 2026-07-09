# Kiln — LLM + vision on the RK3576 NPU, mainline kernel

Run **LLM and vision** inference on the **Rockchip RK3576 NPU** on a **mainline**
Linux kernel, by building the vendor GPL `rknpu` driver **out-of-tree** and driving
it with the closed `librkllmrt` (RKLLM, LLMs) and `librknnrt` (RKNN, CNN vision)
runtimes. Exposed as an integrable local service: an **OpenAI-compatible API**
(`kiln-serve`) plus a slash-command chat CLI over one config file.

The vendor RKLLM/RKNN stack normally runs on the vendor 6.1 BSP kernel. Kiln puts
that same stack (vendor `rknpu.ko` v0.9.8 + `librkllmrt` + `librknnrt`) on a clean
**mainline `linux-7.1.3`** base (kernel.org, not Armbian's downstream) using
mainline's own clock / power-domain / IOMMU drivers — **plus a small, focused NPU
patch set** (`kernel-patches/` 0001–0010). It is mainline-*based*, **not stock
mainline**: those ten patches are required (see *Why it needs kernel patches*).

> **Companion project:** [`linux-rk3576-npu`](https://github.com/gahingwoo/linux-rk3576-npu)
> is the other half of the same effort — the from-scratch *open* RK3576 NPU driver
> (rocket / mesa). Two routes to the same goal: this repo puts the vendor stack on
> a mainline kernel; that one builds an open driver from scratch.

## Status

**It works** on real hardware (ROCK 4D, RK3576). Both stacks run on the NPU:
`kiln-chat` holds a multi-turn conversation — **Qwen2.5-1.5B (~9 tok/s) or
Llama-3.2-1B (~13 tok/s)**, switchable live with `/model` — and `kiln-vision`
classifies images (**~6 ms, ~169 fps**) with a MobileNet / RKNN model, confirming
the driver fix generalises from transformer matmul to convolution.

Verified on a **mainline `linux-7.1.3`** kernel built by CI with Kiln's patch set
(`kernel-patches/` 0001–0010), and earlier on a hand-built `linux-next` 7.1 image.
The runtime/driver/platform version-lock passes on the board (`rkllm 1.2.0` +
`rknpu 0.9.8` + `RK3576`); `.rkllm`/`.rknn` models must match the runtime version.

- **Serial log** — boot → `rknpu 0.9.8` loads → all four MMU banks enabled → vision
  + chat, both on the NPU:
  [gist](https://gist.github.com/gahingwoo/545f90ed2b0e7542e2953e089c60ee01).
- **Live demo** — `fastfetch` (Kernel 7.1.3) → dual-model `kiln-chat` with a live
  `/model` switch → `kiln-vision`:
  [gist](https://gist.github.com/gahingwoo/63f5505068de0a41f718499912ae0265).

## Why it needs kernel patches

A **stock** mainline (or Armbian) kernel is **not** enough — several RK3576 NPU
fixes are kernel code the out-of-tree module and a DT overlay cannot supply:

- **Two IOMMUs, one device.** A naive port only produces `task_counter=0` timeouts:
  the NPU is one device with two IOMMUs, but mainline `rockchip-iommu` drives only
  the primary one, so the second core reads the regcmd IOVA as a raw physical
  address → garbage. Kiln enables all four MMU banks from the driver and flushes
  their TLB per job.
- **Power domain.** A cold NPU power-on needs a settle delay, a BIU reset, the full
  domain clock set, and a core "arm", or the first register read SErrors. And the
  ROCK 4D board DTS marks the NPU rail `vdd_npu_s0` only `regulator-boot-on`, so it
  is disabled ~30 s into boot — the **second** inference then reads a dead rail and
  wedges the board. One line, `regulator-always-on` (`kernel-patches/0010`), fixes
  the "works once then hangs" bug.

Full write-ups: [`kernel-patches/README.md`](kernel-patches/README.md) (the 10
patches, per-patch rationale) and [`driver/patches/README.md`](driver/patches/README.md)
(the two-IOMMU / MMU-bank mechanism).

## Serve & configure

Three tools, one config (`/etc/kiln/config.ini`, read by all of them):

- **`kiln-serve`** — an **OpenAI-compatible** HTTP API for the LLM. Point the
  `openai` SDK / LangChain / any OpenAI client at the board:

  ```sh
  kiln-serve                       # listens on [server] host/port from the config
  curl -N http://<board>:8080/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"hi"}],"stream":true}'
  ```

  `GET /v1/models`, `POST /v1/chat/completions` (SSE streaming), optional
  `POST /v1/vision/classify`. Reuses the same `librkllmrt` calls as `kiln-chat`,
  header-only (`cpp-httplib` + `nlohmann/json`, no Python), runs standalone or as a
  `systemd` service. See [`docs/SERVER.md`](docs/SERVER.md).
- **`kiln-chat`** — the interactive LLM CLI. Runs any RKLLM `.rkllm` model; the chat
  template + stop tokens auto-select for **Qwen/ChatML** or **Llama-3**. Readline
  input (cursor editing + history) and **slash commands** — `/model` (arrow-key
  picker), `/system`, `/history`, `/clear` / `/new`, `/context`, `/compact` — with
  `/model` / `/system` / `/history` persisted to the config. Type `/help`. See
  [`docs/CHAT.md`](docs/CHAT.md).
- **`kiln-vision`** — the image-classification CLI (MobileNet / RKNN). See
  [`VISION.md`](VISION.md).

All three read `/etc/kiln/config.ini` — edited by hand; only the fields the closed
runtimes actually expose. See [`docs/CONFIG.md`](docs/CONFIG.md).

## Install

**On Armbian** — one command installs the Kiln mainline kernel, then (after a
reboot) the driver + runtimes + tools. Two phases; see [`ARMBIAN.md`](ARMBIAN.md):

```sh
curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
```

**Flashable image** — the whole thing as a buildroot br2-external (rootfs + module
+ model baked in):

```sh
driver/fetch-vendor-driver.sh      # GPL rknpu v0.9.8 source (not redistributed)
buildroot/fetch-runtimes.sh        # closed runtimes into buildroot/dl
buildroot/build-image.sh
```

**Kernel** — CI publishes the `.deb`s; build it yourself per
[`MAINLINE-KERNEL.md`](MAINLINE-KERNEL.md). The module alone builds against any
patched 7.x tree: `make KDIR=/path/to/kernel/build` (after fetch + apply-shims).
The DT node uses the **real** vendor RK3576 addresses (see `dts/`).

## Layout

- `driver/` — `fetch-vendor-driver.sh` (pull GPL v0.9.8 `rknpu`),
  `apply-mainline-shims.sh` + `patches/` (the one mainline + NPU-execution patch,
  with a rationale README), `compat/` (BSP-only `soc/rockchip/*` stubs)
- `Kbuild`, `Makefile`, `dkms.conf` — out-of-tree module build (DRM_GEM; DKMS)
- `kernel-patches/` — RK3576 NPU pmdomain/iommu/DT patches (mainline build);
  `kernel-patches-rk3568/` — RK3568 / ROCK 3B (untested; see `RK3568.md`)
- `dts/` — `*-kiln-npu.dtso` NPU device-tree overlay (alternative Armbian path)
- `buildroot/board/rock4d/` — tool sources: `kiln_config.h`, `kiln_llm.h` /
  `kiln_vision.h` (runtime wrappers), `kiln_serve.cpp`, `rkllm_chat.cpp`,
  `rknn_mobilenet.cpp`
- `scripts/kiln-install.sh` — one-shot Armbian installer (kernel + module + tools)
- `docs/` — `SERVER.md`, `CHAT.md`, `CONFIG.md` (tool references)
- `ARMBIAN.md`, `MAINLINE-KERNEL.md`, `VISION.md`, `RK3568.md` — install/kernel/board paths
- `capture/` — NPU per-op capture harness

## Credits

- **Driver base:** [`armbian/linux-rockchip`](https://github.com/armbian/linux-rockchip)
  (rk-6.1-rkr6.1), which carries the GPL-2.0 vendor `rknpu` v0.9.8 driver
  (byte-identical to `rockchip-linux/kernel` develop-6.1).
- **Out-of-tree port reference:** [`w568w/rknpu-module`](https://github.com/w568w/rknpu-module)
  — proof the v0.9.8 `rknpu` driver builds on a mainline kernel. Kiln does not
  vendor its code; its `drm_driver` shims and compat stubs were a useful reference.

## License

GPL-2.0 (see `LICENSE`). Kiln wraps and builds the GPL-2.0 vendor `rknpu` driver,
whose source is **fetched, not redistributed** here. The `librkllmrt` / `librknnrt`
runtimes are closed and distributed by Rockchip; Kiln does not include them. Model
weights are licensed separately and are not included.
