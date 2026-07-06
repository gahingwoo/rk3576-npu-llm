# rk3576-npu-llm (Kiln)

Run LLMs on the **Rockchip RK3576 NPU** under a **mainline** Linux kernel (7.x),
by building the vendor GPL `rknpu` driver **out-of-tree** and driving it with the
closed `librkllmrt` RKLLM runtime.

The vendor RKLLM stack runs multi-matmul LLMs on RK3576 — but on the vendor 6.1
BSP kernel. Kiln puts that same stack (vendor `rknpu.ko` v0.9.8 + `librkllmrt`)
on a **mainline** kernel, using mainline's own clock / power-domain / IOMMU
drivers instead of the BSP's.

> **Companion project:** [`linux-rk3576-npu`](https://github.com/gahingwoo/linux-rk3576-npu)
> is the other half of the same effort — the from-scratch *open* RK3576 NPU
> driver (rocket / mesa). Two routes to the same goal: this repo puts the vendor
> stack on a mainline kernel; that one builds an open driver from scratch.

## Status

**It works.** On real hardware (ROCK 4D, RK3576) on a mainline kernel, the vendor
RKLLM stack runs LLM inference on the NPU and generates tokens.

Verified end-to-end on a hand-built `linux-next` 7.1 image:

- The out-of-tree `rknpu` v0.9.8 driver builds against mainline 7.x and loads.
  One patch covers both the 6.1 → 7.x API drift and the RK3576 NPU-execution
  fixes (`driver/patches/README.md`).
- Probes cleanly against a mainline DT node; the runtime/driver/platform
  version-lock passes on the board (`rkllm 1.2.0` + `rknpu 0.9.8` + `RK3576`).
- **Matmul executes and tokens generate.** `librkllmrt` runs Qwen2.5-1.5B
  `w4a16` and answers coherently at **~9 tok/s decode, ~0.3 s time-to-first-token**
  (the chat prints a `[bench]` line per turn).

The core porting problem — and why a naive port only produces `task_counter=0`
timeouts — is that the NPU is **one device with two IOMMUs**, but mainline
`rockchip-iommu` manages only a single primary iommu, leaving the second core's
MMU disabled: its jobs read the regcmd IOVA as a raw physical address → garbage →
no execution. Kiln enables all four MMU banks from the driver and flushes their
TLB per job. Full write-up in [`driver/patches/README.md`](driver/patches/README.md).

Bring-up caveats (honest):

- After a long idle the NPU power-domain drops; the first inference on the next
  cold power-on can degrade until it re-warms (mitigated by a 10-min keep-warm).
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

**On Armbian** (stock mainline kernel, no kernel rebuild): `./scripts/install-armbian.sh`
does DKMS + the DT overlay + runtime. See [`ARMBIAN.md`](ARMBIAN.md).

The DT node uses the **real** vendor RK3576 addresses (see `dts/`), not the
guessed open-driver layout.

## Layout

- `dts/` — RK3576 NPU board DTS + `*-kiln-npu.dtso` device-tree overlay (Armbian)
- `driver/fetch-vendor-driver.sh` — pull the GPL v0.9.8 `rknpu` source
- `driver/apply-mainline-shims.sh` — apply `patches/kiln-mainline.patch` (idempotent)
- `driver/patches/` — the one mainline + NPU-execution patch, with a rationale README
- `driver/compat/` — build-time compat stub headers for BSP-only `soc/rockchip/*`
- `Kbuild`, `Makefile`, `dkms.conf` — out-of-tree module build (DRM_GEM path; DKMS)
- `buildroot/` — br2-external: board config, image scripts, tracked `rkllm_chat.cpp`
- `scripts/` — build / load / run helpers + `install-armbian.sh`
- `ARMBIAN.md` — running Kiln on a stock Armbian kernel
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
