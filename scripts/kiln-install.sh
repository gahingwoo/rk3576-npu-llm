#!/usr/bin/env bash
# Kiln one-click installer — LLMs + vision on the RK3576 NPU, on Armbian.
#
#   curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
#
# Two phases (it tells you when to reboot between them):
#
#   PHASE 1 — installs the Kiln-PATCHED Armbian kernel. The RK3576 NPU power
#     domain needs a settle-delay fix in pmdomain/rockchip that must be COMPILED
#     INTO the kernel (the out-of-tree module and the DT overlay cannot supply
#     it); on a stock Armbian kernel the NPU SError-freezes on the first
#     inference. The patched kernel is prebuilt by CI and published as a release.
#     See kernel-patches/ and ARMBIAN-KERNEL.md.
#
#   PHASE 2 — after you reboot into the patched kernel: builds the vendor rknpu
#     driver (DKMS), installs the NPU device-tree overlay, the RKLLM/RKNN
#     runtimes, and the kiln-chat / kiln-vision demos.
#
# You supply the model files (a *-rk3576-w4a16.rkllm and/or a *_rk3576.rknn).
set -euo pipefail

REPO="${KILN_REPO:-https://github.com/gahingwoo/kiln.git}"
GH="${KILN_GH:-gahingwoo/kiln}"
KTAG="${KILN_KERNEL_TAG:-armbian-npu-kernel-edge}"
KILN_DIR="${KILN_DIR:-/opt/kiln}"
PKG=kiln-rknpu; VER=0.9.8
KREL="$(uname -r)"
MARKER=/etc/kiln/patched-kernel
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo

say(){ printf '\n\033[1;36m[kiln]\033[0m %s\n' "$*"; }
die(){ printf '\n\033[1;31m[kiln] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Build every registered DKMS module against kernel release $1; remove the ones
# that don't build (e.g. the aic8800 wifi driver doesn't build on 7.1). A module
# that fails to build makes the linux-image postinst's 'dkms autoinstall' fail,
# which leaves the kernel half-configured and blocks ALL apt. Pruning them keeps
# the kernel installable and apt usable -- at the cost of that driver until it
# supports the new kernel.
prune_unbuildable_dkms(){
	local k="$1" m v
	command -v dkms >/dev/null 2>&1 || return 0
	[ -d "/lib/modules/$k/build" ] || return 0
	$SUDO dkms status 2>/dev/null | sed -E 's#[/,:]# #g' | awk '{print $1, $2}' | sort -u |
	while read -r m v; do
		[ -n "$m" ] && [ "$m" != "$PKG" ] || continue
		$SUDO dkms status -m "$m" -v "$v" -k "$k" 2>/dev/null | grep -q installed && continue
		if ! $SUDO dkms build "$m/$v" -k "$k" >/dev/null 2>&1; then
			say "  DKMS $m/$v does not build on $k -- removing it"
			say "  (a driver such as aic8800 wifi/bt may stop working until it supports this kernel; use ethernet)"
			$SUDO dkms remove "$m/$v" --all >/dev/null 2>&1 || true
		fi
	done
}

# --- 0. preflight -----------------------------------------------------------
say "Kiln installer — RK3576 NPU on Armbian"
[ "$(uname -m)" = aarch64 ] || die "aarch64 only (found $(uname -m))"
[ -f /boot/armbianEnv.txt ] || die "no /boot/armbianEnv.txt — this installer targets Armbian"
grep -aqi rk3576 /proc/device-tree/compatible 2>/dev/null \
	|| say "note: board does not report rk3576 in /proc/device-tree/compatible; continuing"

# --- 1. prerequisites -------------------------------------------------------
# Heal first: a kernel left half-configured by a DKMS module that won't build on
# it (e.g. a prior interrupted run) blocks every apt call below. Clear it.
if ! $SUDO dpkg --configure -a >/dev/null 2>&1; then
	say "an unfinished package configuration is blocking apt (a DKMS module won't build) -- healing ..."
	prune_unbuildable_dkms "$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1)"
	$SUDO dpkg --configure -a || true
fi
say "installing prerequisites ..."
$SUDO apt-get update -qq || true
$SUDO apt-get install -y git build-essential dkms device-tree-compiler curl ca-certificates \
	|| die "apt failed installing prerequisites."

# --- 2. KERNEL PHASE (install the patched kernel once, then reboot) ----------
on_patched_kernel(){ [ -f "$MARKER" ] && [ "$KREL" = "$(cat "$MARKER" 2>/dev/null)" ]; }

if ! on_patched_kernel; then
	say "installing the Kiln-patched Armbian kernel (NPU pm-domain fix) from the '$KTAG' release ..."
	TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
	( cd "$TMP" && curl -fsSL "https://api.github.com/repos/$GH/releases/tags/$KTAG" \
		| grep -o 'https://[^"]*\.deb' | xargs -n1 -r curl -fLO ) \
		|| die "could not download the patched kernel .debs from the '$KTAG' release."
	IMG="$(ls "$TMP"/linux-image-*.deb 2>/dev/null | head -1)"
	[ -f "$IMG" ] || die "no linux-image .deb in the '$KTAG' release (is the CI build published?)."
	# NB: no 'head' in this pipe -- it would close the pipe early and SIGPIPE the
	# dpkg-deb tar listing, which under 'set -o pipefail' aborts the script. sort -u
	# consumes all input and a linux-image has exactly one /lib/modules/<release>.
	KREL_NEW="$(dpkg-deb -c "$IMG" | grep -oE 'lib/modules/[^/]+' | sort -u | cut -d/ -f3)"
	# Install linux-HEADERS first: its postinst compiles the kernel-headers build
	# scripts (fixdep/modpost/...) that DKMS needs. Then prune any DKMS module that
	# won't build on the new kernel (e.g. aic8800 wifi on 7.1) BEFORE installing the
	# image -- otherwise the image postinst's 'dkms autoinstall' fails and leaves the
	# kernel half-configured, which blocks apt.
	say "installing kernel $KREL_NEW (headers first) ..."
	$SUDO dpkg -i "$TMP"/linux-headers-*.deb || die "installing linux-headers failed."
	prune_unbuildable_dkms "$KREL_NEW"
	$SUDO dpkg -i "$TMP"/linux-dtb-*.deb "$TMP"/linux-image-*.deb \
		|| die "installing the patched kernel failed (see dpkg errors above)."
	# Hold, so 'apt upgrade' won't swap the patched kernel back for a stock one.
	$SUDO apt-mark hold linux-image-edge-rockchip64 linux-dtb-edge-rockchip64 \
		linux-headers-edge-rockchip64 >/dev/null 2>&1 || true
	$SUDO mkdir -p /etc/kiln; echo "$KREL_NEW" | $SUDO tee "$MARKER" >/dev/null
	cat <<EOF

[kiln] Patched kernel $KREL_NEW installed and held.
       REBOOT into it, then run this installer again to finish:

           sudo reboot
           curl -fsSL https://raw.githubusercontent.com/$GH/main/scripts/kiln-install.sh | bash
EOF
	exit 0
fi
say "on the Kiln-patched kernel ($KREL) — finishing the install."

# --- 3. fetch Kiln ----------------------------------------------------------
say "fetching Kiln into $KILN_DIR ..."
if [ -d "$KILN_DIR/.git" ]; then $SUDO git -C "$KILN_DIR" pull --ff-only || true
else $SUDO rm -rf "$KILN_DIR"; $SUDO git clone --depth 1 "$REPO" "$KILN_DIR"; fi
# Cloned as root, but fetch-runtimes / g++ demos run as you and write back into
# the tree (buildroot/dl, model/); hand it over so those writes don't EPERM.
$SUDO chown -R "$(id -u):$(id -g)" "$KILN_DIR"
cd "$KILN_DIR"

# --- 4. driver via DKMS -----------------------------------------------------
# Headers came WITH the patched kernel (linux-headers deb), so this always matches.
[ -d "/lib/modules/$KREL/build" ] \
	|| die "no kernel headers for $KREL (the patched linux-headers deb should provide them)."
say "building the rknpu driver with DKMS (fetches GPL source + applies the patch) ..."
$SUDO rm -rf "/usr/src/$PKG-$VER"; $SUDO mkdir -p "/usr/src/$PKG-$VER"
$SUDO cp -r Kbuild Makefile dkms.conf driver "/usr/src/$PKG-$VER/"
$SUDO dkms remove "$PKG/$VER" --all >/dev/null 2>&1 || true
$SUDO dkms add "/usr/src/$PKG-$VER"
$SUDO dkms build "$PKG/$VER"
$SUDO dkms install "$PKG/$VER"
# Load rknpu at boot (loading a module needs root; the overlay's NPU node is up
# before userspace, so a boot-time modprobe binds it and the render node is ready).
echo rknpu | $SUDO tee /etc/modules-load.d/rknpu.conf >/dev/null

# --- 5. NPU device-tree overlay (self-contained; symbols resolved at boot) ---
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

# --- 6. runtimes + demos (native aarch64 build) + vision assets --------------
say "fetching runtimes and building the demos ..."
bash buildroot/fetch-runtimes.sh
bash buildroot/fetch-vision-assets.sh || true
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

# --- 7. finish --------------------------------------------------------------
$SUDO depmod -a "$KREL" || true
cat <<EOF

[kiln] Installed on the patched kernel. REBOOT to apply the NPU overlay + load rknpu:

    sudo reboot

After reboot:
  sudo dmesg | grep -i rknpu
      # expect:  RKNPU ... kiln mmu enable_all: ... st=0x19/0x19/0x19/0x19
      # and NO   'failed to get pm runtime for npu0, ret: -110'
  ls /dev/dri/renderD*          # renderD129 (NPU) present

  # vision (needs a MobileNet .rknn matched to librknnrt 2.3.0 in /opt/models):
  kiln-vision /opt/models/test.jpg
  # LLM (put a *-rk3576-w4a16.rkllm in /opt/models):
  kiln-chat

Models are not shipped. Copy your mobilenetv2-12_rk3576.rknn and/or your
*-rk3576-w4a16.rkllm into /opt/models (scp from your dev machine).
EOF
