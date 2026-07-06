# Running Kiln on Armbian

Kiln's NPU-execution work lives entirely in the **out-of-tree module + a device-tree
overlay** — there are **no kernel source patches**. So it can run on a stock
Armbian mainline kernel that has RK3576 support (the clock / power-domain /
rockchip-iommu drivers, upstream since ~6.13), not just the hand-built kernel it
was developed on.

> **Status:** the driver + overlay are portable by construction, but this exact
> path has **not yet been tested end-to-end on an Armbian release**. Treat the
> script as a starting point and check each step. Confirmed working on a
> hand-built `linux-next` 7.1 image on ROCK 4D (RK3576): matmul runs, tokens come
> out, ~9 tok/s decode on Qwen2.5-1.5B w4a16.

## What gets installed

| Piece | Where | How |
|---|---|---|
| `rknpu.ko` (vendor v0.9.8 + Kiln patch) | kernel modules | DKMS (rebuilds on kernel upgrade) |
| NPU device-tree overlay | `/boot/overlay-user` + `armbianEnv.txt` | `dtc` |
| `librkllmrt.so` (+ `libgomp`) | `/usr/lib` | fetched |
| `rkllm_demo`, `kiln-chat` | `/usr/bin` | built / copied |
| model `*.rkllm` | `/opt/models` | you provide |

## Prerequisites

- Armbian aarch64 with a **mainline** kernel ≥ 6.13 that has RK3576 support
  (Armbian "edge"/current for `rock-4d`). Its base DT does **not** need NPU nodes —
  the overlay adds them — but must export the symbols `cru`, `power`, `vdd_npu_s0`
  (the ROCK 4D DT does; check `ls /proc/device-tree/__symbols__/`).
- The kernel **headers** package for the running kernel. On Armbian it is named by
  branch, not version: `sudo apt install linux-headers-$(uname -r | sed -E 's/^[0-9.]+-//')`
  (e.g. `linux-headers-edge-rockchip64`), plus `dkms device-tree-compiler git build-essential`.
- A version-matched `librkllmrt` (Kiln pins **1.2.0**) + a `*-rk3576-w4a16.rkllm`, and/or
  a `librknnrt`-matched (**2.3.0**) `*_rk3576.rknn` for vision.

## One-shot install

```sh
curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
# copy your models into /opt/models (a *-rk3576-w4a16.rkllm and/or a *_rk3576.rknn)
sudo reboot
kiln-vision /opt/models/test.jpg     # or: kiln-chat
```

It bootstraps the prerequisites, builds the driver with DKMS (so the vermagic
matches the running kernel), installs the overlay, and installs the runtimes +
demos. Re-runnable.

## What the overlay does

`dts/rk3576-rock-4d-kiln-npu.dtso` is **self-contained**: it adds the vendor-shaped
`npu@27700000` plus its two v2 IOMMUs (`@27702000` / `@2770a000`) from scratch,
referencing only `&cru`, `&power`, `&vdd_npu_s0`, with **numeric** clock/reset/power
IDs so it builds with plain `dtc` (no dt-bindings headers). The prebuilt `.dtbo`
ships in the repo; it's copied to `/boot/overlay-user/kiln-npu.dtbo` and enabled via
`user_overlays=kiln-npu` in `/boot/armbianEnv.txt`.

## Verify

```sh
dmesg | grep -i rknpu
#   RKNPU ... Initialized rknpu 0.9.8 ...
#   RKNPU ... kiln mmu enable_all: dte=0x... st=0x19/0x19/0x19/0x19   <- all 4 MMU banks on
ls /dev/dri/renderD*            # NPU render node present
kiln-chat                       # chat; each turn prints a [bench] tok/s line
```

## If the NPU doesn't come up

- **No `renderD*` / module won't load** — vermagic mismatch: the DKMS build must
  target the *running* kernel's headers. `sudo dkms status`, rebuild against
  `linux-headers-$(uname -r)`.
- **Overlay not applied** — check `armbianEnv.txt user_overlays=` and that the
  `.dtbo` is in the dir Armbian reads; `cat /proc/device-tree/soc/npu@27700000/status`.
- **Jobs time out (`task_counter=0`)** — confirm the `kiln mmu enable_all` line
  shows `st=0x19/0x19/0x19/0x19`; if a bank is `0x18` the overlay/driver pairing
  is off. See `driver/patches/README.md` for the mechanism.
- **DKMS build can't fetch** — `driver/fetch-vendor-driver.sh` needs network at
  build time; pre-fetch `driver/rknpu` on a connected machine and copy it in.

## Toolchain note

The chat demo statically links libstdc++ (`-static-libstdc++`) so a demo built
with a newer host g++ still runs against an older target `libstdc++`. Building it
with the same gcc as the kernel avoids this entirely.
