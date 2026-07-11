# Running the Kiln NPU on a mainline kernel

This is Kiln's primary path: a clean **mainline `linux-7.1.3`** base (kernel.org)
plus Kiln's small NPU patch set — no Armbian *downstream* patches, no DT overlay.
It is mainline-based, **not** stock mainline: the patches below are required.

## Why mainline (not the Armbian kernel)

The Armbian edge kernel carries ~170 downstream patches and tangles the NPU with
its own packaging (its aic8800 DKMS wifi module fails on 7.1 and blocks the whole
kernel install). Mainline is cleaner and the story is honest: **vendor `rknpu`
stack on a clean mainline base + a focused NPU patch set (`kernel-patches/`
0001–0010).** Mainline 7.1.3 already has full RK3576 + ROCK 4D support
(`rk3576-rock-4d.dts` is upstream), so this is viable.

## The patch set (`kernel-patches/` 0001–0010, verified against 7.1.3)

Ten patches, applied in order. In brief:

- **Cold power-on** — `0001` settle-delay, `0002`+`0005` BIU reset + full domain
  clocks, `0009` core "arm": without these the first NPU register read SErrors.
- **IOMMU** — `0003` take all DT clocks, `0007`+`0008` skip orphaned-fault MMU banks.
- **DT** — `0004` adds the vendor `npu@27700000` (`compatible = "rockchip,rk3576-rknpu"`)
  + two IOMMUs to `rk3576.dtsi` (mainline has no NPU compute node); `0006` hardens
  the warm power path.
- **`0010` `regulator-always-on` on `vdd_npu_s0`** — the fix for the "works once,
  then the second inference hangs the board" bug. **The critical one for re-use.**

Full per-patch rationale: [`kernel-patches/README.md`](../kernel-patches/README.md).
Mainline's own NPU path is the open `accel/rocket` driver (different `rknn_core`
DT); Kiln uses the **vendor** `rknpu` module, so `0004` gives it a node to bind and
the config leaves `CONFIG_DRM_ACCEL_ROCKET` off.

## Build (CI)

`.github/workflows/mainline-npu-kernel.yml` builds it on a GitHub runner:

1. fetch `linux-7.1.3` from kernel.org
2. `patch -p1` with `kernel-patches/` 0001 … 0010 in order
3. config: a ROCK 4D-capable base (the Armbian 7.1.3 `.config` is a good, boot-tested
   starting point — the code is mainline, the config just selects drivers) with
   `CONFIG_DRM_ACCEL_ROCKET=n`
4. `make bindeb-pkg` → `linux-image-<ver>` + `linux-headers-<ver>` `.deb`
5. publish to the `kiln-mainline-kernel` release

## Install on the board (Armbian userspace + mainline kernel)

`kiln-install.sh` does this; the manual equivalent:

```sh
# 1. headers first (so DKMS builds against a prepared tree), then the image
sudo dpkg -i linux-headers-<ver>_*.deb
sudo dpkg -i linux-image-<ver>_*.deb
sudo apt-mark hold linux-image-<ver> linux-headers-<ver>

# 2. wire Armbian's u-boot to the mainline kernel (bindeb-pkg does not):
V=<ver>
sudo mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
     -d /boot/initrd.img-$V /boot/uInitrd-$V
sudo ln -sf uInitrd-$V /boot/uInitrd
sudo ln -sf vmlinuz-$V  /boot/Image
sudo install -Dm0644 "$(find /usr/lib/linux-image-$V -name rk3576-rock-4d.dtb)" \
     /boot/dtb/rockchip/rk3576-rock-4d.dtb
sudo sed -i 's#^fdtfile=.*#fdtfile=rockchip/rk3576-rock-4d.dtb#' /boot/armbianEnv.txt
sudo reboot
```

No DT overlay is needed — the NPU node is compiled into the dtb (`0004`).

## After reboot — finish the install (phase 2)

The steps above install only the **kernel**. Build the `rknpu` module + runtimes +
tools on top — this is installer phase 2, which `kiln-install.sh` normally does
automatically (offline, via the systemd handoff); by hand it is:

```sh
sudo KILN_SKIP_KERNEL=1 bash scripts/kiln-install.sh   # DKMS driver + runtimes + tools + wifi
```

Then verify:

```sh
uname -r                          # <ver> (mainline 7.1.3)
sudo dmesg | grep -i rknpu        # kiln mmu enable_all: ... st=0x19/0x19/0x19/0x19; NO -110
ls /dev/dri/renderD*              # renderD129 (NPU)
kiln-doctor                       # pass/fail health report ("paste this in issues")
kiln-vision /opt/models/test.jpg  # needs a MobileNet .rknn in /opt/models — see VISION.md
kiln-chat                         # needs a *.rkllm in /opt/models
```

## Wi-Fi

The ROCK 4D's onboard aic8800 wifi/bt is **out-of-tree** (not in mainline) and its
stock driver — even radxa's latest 5.0 — does **not** build on 7.1 (Linux 7.1
changed the cfg80211 station/key ops from `net_device` to `wireless_dev`). So Kiln
carries the compat fix in `aic8800-patches/`, and `kiln-install.sh` builds the
patched radxa 5.0 driver via DKMS for the mainline kernel so **wifi/bt keep
working**. If that build ever fails (upstream moved), the installer warns and
continues — use ethernet, and the fix is a PR to `radxa-pkg/aic8800`.
