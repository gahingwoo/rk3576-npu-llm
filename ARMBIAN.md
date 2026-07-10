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

`scripts/kiln-install.sh` does exactly this in two phases. By default it's hands-off:
Phase 1 (kernel + a pre-downloaded offline cache) and Phase 2 (driver + tools + wifi,
run offline by a systemd oneshot after the first reboot) are chained with two
automatic reboots. `KILN_MANUAL=1` keeps the phases hands-on. The NPU node is built
into that kernel's DTB (`kernel-patches/0004`), so no DT overlay is involved.

> **Status:** verified end-to-end on **mainline `linux-7.1.3`** (ROCK 4D,
> RK3576): `kiln-chat` holds a multi-turn conversation (Qwen2.5-1.5B ~9 tok/s or
> Llama-3.2-1B ~13 tok/s, live `/model` switch) and `kiln-vision` classifies at
> ~169 fps, both on the NPU. The one-shot script automates it on an Armbian userland.

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
  `build-essential`, and **network during phase 1 only** (phase 2 runs offline from
  the cache phase 1 fills — that's what removes the old "wifi's down but phase 2
  needs the net" deadlock).
- A version-matched `librkllmrt` (Kiln pins **1.2.0**) + a `*-rk3576-w4a16.rkllm`, and/or
  a `librknnrt`-matched (**2.3.0**) `*_rk3576.rknn` for vision.
- Note: moving to the mainline kernel drops onboard Wi-Fi (the aic8800 driver won't
  build on 7.1) until phase 2 rebuilds a patched aic8800 — which it does offline. If
  that rebuild fails (best-effort), keep Ethernet handy.

## One-shot install

**Default — one command, hands-off.** Phase 1 pre-downloads everything into a cache
under `/opt/kiln`, installs the Kiln kernel, and the machine **reboots itself twice
(~10–15 min)**: once into the new kernel to finish setup, then again into the ready
system. Phase 2 runs **fully offline** from that cache, so the wifi drop between
reboots doesn't matter. **Don't cut power.**

```sh
curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
# ...it reboots twice on its own; when done you'll see "Kiln installed" at login.
kiln-doctor                           # confirm health (paste this in issues)
kiln-vision /opt/models/test.jpg      # or: kiln-chat  (put your models in /opt/models)
```

**Manual — keep control of the reboots** with `KILN_MANUAL=1` (no auto-reboot, no
handoff service; it prints when to reboot and re-run):

```sh
# PHASE 1 -- installs the Kiln mainline kernel, then asks you to reboot into it
curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | KILN_MANUAL=1 bash
sudo reboot

# after reboot, finish PHASE 2 (runs OFFLINE from the phase-1 cache)
uname -r                              # expect a 7.1.3 build
sudo bash /opt/kiln/scripts/kiln-install.sh
```

Either way it installs the Kiln kernel (phase 1), then builds the driver with DKMS
(vermagic matches the running kernel), installs the runtimes + tools, and restores
onboard wifi (phase 2). Re-runnable; granular re-runs via `KILN_SKIP_*` (see the
script header).

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
  `vdd_npu_s0: disabling`.
- **Jobs time out (`task_counter=0`)** — confirm the `kiln mmu enable_all` line
  shows `st=0x19/0x19/0x19/0x19`; if a bank is `0x18` the driver/DT pairing is off.
  See `driver/patches/README.md` for the mechanism.
- **DKMS build can't fetch** — normally a non-issue: phase 1 pre-fetches the vendor
  `driver/rknpu` source into the cache so the phase-2 DKMS build is offline. If you
  bypassed phase 1 (e.g. `KILN_SKIP_KERNEL=1` on a box with no cache), fetch it on a
  connected machine: `KILN_FORCE_FETCH=1 bash driver/fetch-vendor-driver.sh`.

## Toolchain note

The chat demo statically links libstdc++ (`-static-libstdc++`) so a demo built
with a newer host g++ still runs against an older target `libstdc++`. Building it
with the same gcc as the kernel avoids this entirely.
