#!/usr/bin/env bash
# Kiln one-click installer — LLMs + vision on the RK3576 NPU, on Armbian (mainline).
#
#   curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
#
# Builds the vendor rknpu driver against the RUNNING Armbian kernel (DKMS, so the
# vermagic always matches), installs a self-contained NPU device-tree overlay
# (Armbian's mainline DT has the NPU peripherals but no bindable compute node),
# and installs the RKLLM + RKNN runtimes and the kiln-chat / kiln-vision demos.
# You supply the model files (a *-rk3576-w4a16.rkllm and/or a *_rk3576.rknn).
set -euo pipefail

REPO="${KILN_REPO:-https://github.com/gahingwoo/kiln.git}"
KILN_DIR="${KILN_DIR:-/opt/kiln}"
PKG=kiln-rknpu; VER=0.9.8
KREL="$(uname -r)"
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo

say(){ printf '\n\033[1;36m[kiln]\033[0m %s\n' "$*"; }
die(){ printf '\n\033[1;31m[kiln] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 0. preflight -----------------------------------------------------------
say "Kiln installer — RK3576 NPU on a mainline Armbian kernel"
[ "$(uname -m)" = aarch64 ] || die "aarch64 only (found $(uname -m))"
grep -aqi rk3576 /proc/device-tree/compatible 2>/dev/null \
	|| say "note: board does not report rk3576 in /proc/device-tree/compatible; continuing"
[ -f /boot/armbianEnv.txt ] || die "no /boot/armbianEnv.txt — this installer targets Armbian"

# --- 1. prerequisites (incl. the Armbian header package for THIS kernel) -----
BRANCH="$(printf '%s' "$KREL" | sed -E 's/^[0-9.]+-//')"     # e.g. 6.19.5-edge-rockchip64 -> edge-rockchip64
say "installing prerequisites (kernel headers: linux-headers-$BRANCH) ..."
$SUDO apt-get update -qq || true
$SUDO apt-get install -y git build-essential dkms device-tree-compiler "linux-headers-$BRANCH" \
	|| die "apt failed. If linux-headers-$BRANCH is missing, install kernel headers via 'armbian-config' (System -> Install headers) and re-run."
[ -d "/lib/modules/$KREL/build" ] || die "kernel headers for $KREL not found (/lib/modules/$KREL/build). Install linux-headers-$BRANCH."

# --- 2. fetch Kiln ----------------------------------------------------------
say "fetching Kiln into $KILN_DIR ..."
if [ -d "$KILN_DIR/.git" ]; then $SUDO git -C "$KILN_DIR" pull --ff-only || true
else $SUDO rm -rf "$KILN_DIR"; $SUDO git clone --depth 1 "$REPO" "$KILN_DIR"; fi
cd "$KILN_DIR"

# --- 3. driver via DKMS (builds against the running kernel -> vermagic matches)
say "building the rknpu driver with DKMS (fetches GPL source + applies the patch) ..."
$SUDO rm -rf "/usr/src/$PKG-$VER"; $SUDO mkdir -p "/usr/src/$PKG-$VER"
$SUDO cp -r Kbuild Makefile dkms.conf driver "/usr/src/$PKG-$VER/"
$SUDO dkms remove "$PKG/$VER" --all >/dev/null 2>&1 || true
$SUDO dkms add "/usr/src/$PKG-$VER"
$SUDO dkms build "$PKG/$VER"
$SUDO dkms install "$PKG/$VER"

# --- 4. NPU device-tree overlay (self-contained; symbols resolved at boot) ---
say "installing the NPU overlay -> /boot/overlay-user/kiln-npu.dtbo ..."
DTBO="dts/rk3576-rock-4d-kiln-npu.dtbo"
[ -f "$DTBO" ] || dtc -@ -I dts -O dtb -o "$DTBO" dts/rk3576-rock-4d-kiln-npu.dtso 2>/dev/null
$SUDO mkdir -p /boot/overlay-user
$SUDO cp "$DTBO" /boot/overlay-user/kiln-npu.dtbo
if grep -q '^user_overlays=' /boot/armbianEnv.txt; then
	grep -qw 'kiln-npu' /boot/armbianEnv.txt || $SUDO sed -i '/^user_overlays=/ s/$/ kiln-npu/' /boot/armbianEnv.txt
else
	echo 'user_overlays=kiln-npu' | $SUDO tee -a /boot/armbianEnv.txt >/dev/null
fi

# --- 5. runtimes + demos (native aarch64 build) + vision assets --------------
say "fetching runtimes and building the demos ..."
buildroot/fetch-runtimes.sh
buildroot/fetch-vision-assets.sh || true
DL="$KILN_DIR/buildroot/dl"
for so in librkllmrt.so librknnrt.so libgomp.so.1; do
	[ -f "$DL/$so" ] && $SUDO install -m0644 "$DL/$so" /usr/lib/ || true
done
[ -f "$DL/libgomp.so.1" ] || say "note: libgomp.so.1 not staged; librkllmrt will use the system one if present"

if [ -f "$DL/rkllm.h" ]; then
	g++ -include cstdint buildroot/board/rock4d/rkllm_chat.cpp -I "$DL" -L "$DL" \
		-Wl,-rpath-link,"$DL" -lrkllmrt -lpthread -o /tmp/rkllm_demo \
	  && $SUDO install -m0755 /tmp/rkllm_demo /usr/bin/rkllm_demo || say "WARN: rkllm_demo build failed"
fi
if [ -f "$DL/rknn_api.h" ]; then
	g++ buildroot/board/rock4d/rknn_mobilenet.cpp -I "$DL" -L "$DL" \
		-Wl,-rpath-link,"$DL" -lrknnrt -lpthread -lm -o /tmp/rknn_mobilenet \
	  && $SUDO install -m0755 /tmp/rknn_mobilenet /usr/bin/rknn_mobilenet || say "WARN: rknn_mobilenet build failed"
fi
$SUDO install -m0755 buildroot/rootfs/usr/bin/kiln-chat buildroot/rootfs/usr/bin/kiln-vision /usr/bin/

$SUDO mkdir -p /opt/models
for f in test.jpg imagenet_labels.txt mobilenetv2-12_rk3576.rknn; do
	[ -f "model/$f" ] && $SUDO install -m0644 "model/$f" /opt/models/ || true
done

# --- 6. finish --------------------------------------------------------------
$SUDO depmod -a "$KREL" || true
cat <<EOF

[kiln] Installed. Now REBOOT to apply the NPU overlay:   sudo reboot

After reboot:
  dmesg | grep -i rknpu
      # expect:  RKNPU ... kiln mmu enable_all: ... st=0x19/0x19/0x19/0x19
  ls /dev/dri/renderD*

  # vision (needs a MobileNet .rknn matched to librknnrt 2.3.0 in /opt/models):
  kiln-vision /opt/models/test.jpg

  # LLM (put a *-rk3576-w4a16.rkllm in /opt/models and set MODEL= in /usr/bin/kiln-chat):
  kiln-chat

Models are not shipped. Copy your mobilenetv2-12_rk3576.rknn and/or your
*-rk3576-w4a16.rkllm into /opt/models on this board (scp from your dev machine).
EOF
