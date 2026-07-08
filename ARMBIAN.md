# Running Kiln on Armbian

Kiln runs on an **Armbian userland** with the **Kiln mainline `linux-7.1.3`
kernel** — a stock Armbian *kernel* is not enough. Bring-up proved that several
RK3576 NPU fixes are **kernel code**, not something the module or a DT overlay can
supply: the power-domain settle delay + BIU reset + cold-start "arm"
(`kernel-patches/` 0001/0002/0005/0009), the iommu stall/clocks fixes (0003/0007/
0008), and — the one that makes *repeat* inference work — `regulator-always-on` on
the NPU rail (0010). Without them the NPU SErrors on the first inference or wedges
on the second. So the supported path is: install the Kiln kernel (CI publishes it
as a release), then build the module + runtimes on top.

`scripts/kiln-install.sh` does exactly this, in two phases (Phase 1 installs the
kernel and you reboot; Phase 2 builds the driver + tools). The NPU node is built
into that kernel's DTB, so **no overlay is needed** on this path. (The standalone
`dts/` overlay — which now also carries the `regulator-always-on` rail fix — is
only for applying the NPU *device node* to a kernel that already has the code
fixes, e.g. an Armbian kernel rebuilt with `kernel-patches/` in `userpatches/`.)

> **Status:** verified end-to-end on **pure mainline `linux-7.1.3`** (ROCK 4D,
> RK3576): `kiln-chat` holds a multi-turn Qwen2.5-1.5B conversation at ~9 tok/s
> and `kiln-vision` classifies at ~169 fps, both on the NPU. The one-shot script
> automates the same steps on an Armbian userland.

## What gets installed

| Piece | Where | How |
|---|---|---|
| Kiln mainline `linux-7.1.3` kernel (0001–0010) | `linux-image`/`headers` | CI release `.deb`, `dpkg -i` |
| `rknpu.ko` (vendor v0.9.8 + Kiln patch) | kernel modules | DKMS (rebuilds on kernel upgrade) |
| `librkllmrt.so` / `librknnrt.so` (+ `libgomp`) | `/usr/lib` | fetched |
| `kiln-chat`, `kiln-vision`, `kiln-serve` | `/usr/bin` | built / copied |
| model `*.rkllm` / `*.rknn` | `/opt/models` | you provide |

The NPU device node ships **in the Kiln kernel's DTB** (kernel-patches/0004), so
there is no overlay to install on this path.

## Prerequisites

- Armbian aarch64 for ROCK 4D (RK3576). The installer replaces the kernel with the
  Kiln mainline `linux-7.1.3` build, so the starting Armbian kernel branch does not
  matter much; you need working `apt`, `dkms`, `device-tree-compiler`, `git`,
  `build-essential`, and network at install time.
- A version-matched `librkllmrt` (Kiln pins **1.2.0**) + a `*-rk3576-w4a16.rkllm`, and/or
  a `librknnrt`-matched (**2.3.0**) `*_rk3576.rknn` for vision.
- Note: moving to the mainline kernel can drop Wi-Fi (the aic8800 driver); the
  installer rebuilds a patched aic8800 via DKMS, but keep Ethernet handy.

## One-shot install (two phases)

```sh
# PHASE 1 -- installs the Kiln mainline kernel, then asks you to reboot into it
curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
sudo reboot

# after reboot, confirm you are on the Kiln kernel, then run PHASE 2
uname -r                              # expect a 7.1.3 build
curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
# copy your models into /opt/models (a *-rk3576-w4a16.rkllm and/or a *_rk3576.rknn)
kiln-vision /opt/models/test.jpg     # or: kiln-chat
```

It installs the Kiln kernel (Phase 1), then builds the driver with DKMS (so the
vermagic matches the running kernel) and installs the runtimes + tools (Phase 2).
Re-runnable.

## The standalone overlay (alternative path)

`dts/rk3576-rock-4d-kiln-npu.dtso` is **not used** by the install above (the NPU
node is already in the Kiln kernel's DTB). It exists for the case where you rebuild
an Armbian kernel with `kernel-patches/` applied but do not change its board DTB:
the overlay then adds the vendor-shaped `npu@27700000` plus its two v2 IOMMUs
(`@27702000` / `@2770a000`) from scratch, referencing only `&cru`, `&power`,
`&vdd_npu_s0` with **numeric** IDs so it builds with plain `dtc`, and it sets
`regulator-always-on` on `vdd_npu_s0` (the overlay equivalent of 0010, without
which the NPU works once and then hangs). Copy the prebuilt `.dtbo` to
`/boot/overlay-user/kiln-npu.dtbo` and add `user_overlays=kiln-npu` to
`/boot/armbianEnv.txt`. The overlay only supplies the *DT node* — it cannot supply
the pmdomain/iommu code fixes, which is why the kernel itself must carry
`kernel-patches/`.

## Verify

```sh
dmesg | grep -i rknpu
#   RKNPU ... Initialized rknpu 0.9.8 ...
#   RKNPU ... kiln mmu enable_all: dte=0x... st=0x19/0x19/0x19/0x19   <- all 4 MMU banks on
ls /dev/dri/renderD*            # NPU render node present
kiln-chat                       # chat; each turn prints a [bench] tok/s line
```

## If the NPU doesn't come up

- **Not on the Kiln kernel** — `uname -r` must show the 7.1.3 build. If Phase 1
  did not switch the kernel (u-boot still boots the old one), re-run Phase 1 and
  check `/boot/armbianEnv.txt` / extlinux points at the Kiln `linux-image`.
- **No `renderD*` / module won't load** — vermagic mismatch: the DKMS build must
  target the *running* kernel's headers. `sudo dkms status`, rebuild against
  `linux-headers-$(uname -r)`.
- **Works once, then the second inference hangs the board** — the NPU rail
  (`vdd_npu_s0`) dropped. On the Kiln kernel this is fixed by 0010
  (`regulator-always-on`); confirm `dmesg | grep vdd_npu` shows **no**
  `vdd_npu_s0: disabling`. On the overlay path, confirm the overlay carries the
  `regulator-always-on` fragment.
- **Jobs time out (`task_counter=0`)** — confirm the `kiln mmu enable_all` line
  shows `st=0x19/0x19/0x19/0x19`; if a bank is `0x18` the overlay/driver pairing
  is off. See `driver/patches/README.md` for the mechanism.
- **DKMS build can't fetch** — `driver/fetch-vendor-driver.sh` needs network at
  build time; pre-fetch `driver/rknpu` on a connected machine and copy it in.

## Toolchain note

The chat demo statically links libstdc++ (`-static-libstdc++`) so a demo built
with a newer host g++ still runs against an older target `libstdc++`. Building it
with the same gcc as the kernel avoids this entirely.
