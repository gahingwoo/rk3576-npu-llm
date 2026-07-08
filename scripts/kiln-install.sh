#!/usr/bin/env bash
# Kiln one-click installer — LLMs + vision on the RK3576 NPU, on Armbian.
#
#   curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
#
# Runs on Armbian userspace with a Kiln MAINLINE kernel. Two phases (it tells you
# when to reboot between them):
#
#   PHASE 1 — installs the Kiln mainline 7.1.3 kernel (pure mainline + a small
#     pm-domain settle-delay fix that must be COMPILED INTO the kernel; the
#     out-of-tree module can't supply it, and a stock kernel SError-freezes the
#     NPU on the first inference). Prebuilt by CI, published as a release; the NPU
#     node is baked into its dtb. It wires Armbian's u-boot to boot it.
#     See kernel-patches/ and MAINLINE-KERNEL.md.
#
#   PHASE 2 — after you reboot into that kernel: builds the vendor rknpu driver
#     (DKMS) and installs the RKLLM/RKNN runtimes and the kiln-chat / kiln-vision
#     demos. No DT overlay -- the NPU node is already in the dtb.
#
# You supply the model files (a *-rk3576-w4a16.rkllm and/or a *_rk3576.rknn).
set -euo pipefail

REPO="${KILN_REPO:-https://github.com/gahingwoo/kiln.git}"
GH="${KILN_GH:-gahingwoo/kiln}"
# One installer serves both boards. Detect the SoC from the running (stock)
# device-tree so we pull the right kernel release + install the right dtb/model.
DT_COMPAT="$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null || true)"
case "$DT_COMPAT" in
	*rk3568*) SOC=rk3568; BOARD=rock-3b; DTB=rk3568-rock-3b.dtb; DEF_KTAG=kiln-mainline-kernel-rk3568 ;;
	*)        SOC=rk3576; BOARD=rock-4d; DTB=rk3576-rock-4d.dtb; DEF_KTAG=kiln-mainline-kernel ;;
esac
MODEL_RKNN="mobilenetv2-12_${SOC}.rknn"
KTAG="${KILN_KERNEL_TAG:-$DEF_KTAG}"
AIC_REPO="${KILN_AIC_REPO:-https://github.com/radxa-pkg/aic8800.git}"
AIC_REF="${KILN_AIC_REF:-5.0+git20260123.5f7be68d-6}"   # the release Kiln's patch is verified against
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

# Wire Armbian's u-boot to a mainline kernel (a bindeb-pkg .deb installs vmlinuz +
# modules + dtbs + an initrd.img but does NOT create the u-boot uInitrd, the
# /boot/Image link, or point armbianEnv at the dtb -- do that here, idempotently).
wire_boot(){
	local k="$1" dtb
	if [ -f "/boot/initrd.img-$k" ] && command -v mkimage >/dev/null 2>&1; then
		$SUDO mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
			-d "/boot/initrd.img-$k" "/boot/uInitrd-$k" >/dev/null 2>&1 || true
		$SUDO ln -sf "uInitrd-$k" /boot/uInitrd
	fi
	[ -e "/boot/vmlinuz-$k" ] && $SUDO ln -sf "vmlinuz-$k" /boot/Image
	dtb="$(find "/usr/lib/linux-image-$k" /boot -name "$DTB" 2>/dev/null | head -1)"
	if [ -n "$dtb" ]; then
		$SUDO install -Dm0644 "$dtb" "/boot/dtb/rockchip/$DTB"
		if grep -q '^fdtfile=' /boot/armbianEnv.txt; then
			$SUDO sed -i "s#^fdtfile=.*#fdtfile=rockchip/$DTB#" /boot/armbianEnv.txt
		else
			echo "fdtfile=rockchip/$DTB" | $SUDO tee -a /boot/armbianEnv.txt >/dev/null
		fi
	fi
}

# The ROCK 4D's onboard aic8800 wifi/bt is out-of-tree and its stock driver does
# not build on 7.1 -- so moving to the mainline kernel drops wifi. Build the
# Kiln-patched aic8800 (radxa 5.0 + aic8800-patches/) via DKMS for kernel $1 so
# wifi/bt survive. Best-effort: warns and continues (use ethernet) if it can't.
install_patched_aic8800(){
	local k="$1" src pf pkg=aic8800-usb ver=5.0-kiln
	command -v dkms >/dev/null 2>&1 || return 0
	pf="$(ls "$KILN_DIR"/aic8800-patches/0001-*.patch 2>/dev/null | head -1)"
	[ -f "$pf" ] || return 0
	say "restoring wifi/bt: building the Kiln-patched aic8800 driver for $k ..."
	# drop any aic8800 DKMS already registered (the stock one won't build on 7.1)
	$SUDO dkms status 2>/dev/null | sed -E 's#[/,:]# #g' | awk '/aic8800/{print $1"/"$2}' | sort -u |
	while read -r old; do [ -n "$old" ] && $SUDO dkms remove "$old" --all >/dev/null 2>&1 || true; done
	src="$(mktemp -d)"
	git clone --depth 1 --branch "$AIC_REF" "$AIC_REPO" "$src/a" >/dev/null 2>&1 \
		|| git clone --depth 1 "$AIC_REPO" "$src/a" >/dev/null 2>&1 \
		|| { say "  WARN: couldn't fetch aic8800 source; wifi stays down on $k (use ethernet)."; rm -rf "$src"; return 0; }
	if ! ( cd "$src/a" && patch -p1 < "$pf" ) >/dev/null 2>&1; then
		say "  WARN: aic8800 patch did not apply (upstream moved); wifi stays down on $k."; rm -rf "$src"; return 0
	fi
	$SUDO rm -rf "/usr/src/$pkg-$ver"; $SUDO mkdir -p "/usr/src/$pkg-$ver"
	$SUDO cp -r "$src/a/src/USB" "/usr/src/$pkg-$ver/"
	# Generate dkms.conf from radxa's usb template, but force AUTOINSTALL=no:
	# with AUTOINSTALL=yes a broken/half-staged aic8800 build makes the kernel
	# image postinst's 'dkms autoinstall' fail and leaves the kernel
	# half-configured (blocks apt). We build+install it explicitly below, so it
	# never needs to ride the kernel's autoinstall.
	sed -e "s/#MODULE_VERSION#/$ver/g" -e 's/^AUTOINSTALL=.*/AUTOINSTALL=no/' \
		"$src/a/debian/aic8800-usb-dkms.dkms" | $SUDO tee "/usr/src/$pkg-$ver/dkms.conf" >/dev/null
	# Firmware: aic_load_fw loads blobs from /lib/firmware/<chip>/ (the chip is
	# auto-detected, e.g. aic8800D80). Without them the USB bus never comes up
	# ("bus is not up"). Install the whole USB firmware tree there.
	$SUDO cp -a "$src/a/src/USB/driver_fw/fw/." /lib/firmware/ 2>/dev/null || true
	$SUDO dkms add "$pkg/$ver" >/dev/null 2>&1 || true
	if $SUDO dkms build "$pkg/$ver" -k "$k" >/dev/null 2>&1 && $SUDO dkms install "$pkg/$ver" -k "$k" >/dev/null 2>&1; then
		say "  aic8800 wifi/bt built and installed for $k."
	else
		say "  WARN: patched aic8800 failed to build for $k (debug: sudo dkms build $pkg/$ver -k $k). Wifi stays down; use ethernet."
	fi
	rm -rf "$src"
}

# --- 0. preflight -----------------------------------------------------------
say "Kiln installer — RK3576 NPU on Armbian"
[ "$(uname -m)" = aarch64 ] || die "aarch64 only (found $(uname -m))"
[ -f /boot/armbianEnv.txt ] || die "no /boot/armbianEnv.txt — this installer targets Armbian"
say "detected SoC: $SOC (board $BOARD, kernel release '$KTAG', dtb $DTB)"
grep -aqi "$SOC" /proc/device-tree/compatible 2>/dev/null \
	|| say "note: board does not report $SOC in /proc/device-tree/compatible; continuing"

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
$SUDO apt-get install -y git build-essential dkms device-tree-compiler curl ca-certificates u-boot-tools \
	|| die "apt failed installing prerequisites."

# --- 2. KERNEL PHASE (install the patched kernel once, then reboot) ----------
# on_patched_kernel is true once we're running the Kiln kernel. KILN_FORCE_KERNEL=1
# forces a re-install even then (e.g. a rebuilt same-version deb with a config fix).
on_patched_kernel(){ [ -z "${KILN_FORCE_KERNEL:-}" ] && [ -f "$MARKER" ] && [ "$KREL" = "$(cat "$MARKER" 2>/dev/null)" ]; }

if ! on_patched_kernel; then
	say "installing the Kiln mainline NPU kernel from the '$KTAG' release ..."
	TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
	# exclude the -dbg debug-symbol image (bindeb-pkg builds it; ~hundreds of MB,
	# not needed, and its name also matches linux-image-*.deb below).
	( cd "$TMP" && curl -fsSL "https://api.github.com/repos/$GH/releases/tags/$KTAG" \
		| grep -o 'https://[^"]*\.deb' | grep -v -- '-dbg' | xargs -n1 -r curl -fLO ) \
		|| die "could not download the mainline kernel .debs from the '$KTAG' release."
	IMG="$(ls "$TMP"/linux-image-*.deb 2>/dev/null | head -1)"
	[ -f "$IMG" ] || die "no linux-image .deb in the '$KTAG' release (is the CI build published?)."
	# no 'head' in this pipe (it would SIGPIPE dpkg-deb under pipefail); a
	# linux-image has exactly one /lib/modules/<release>.
	KREL_NEW="$(dpkg-deb -c "$IMG" | grep -oE 'lib/modules/[^/]+' | sort -u | cut -d/ -f3)"
	# Headers first: their postinst prepares the build tree DKMS needs. Then prune
	# any DKMS module that won't build on the new kernel (e.g. aic8800 wifi on 7.1)
	# BEFORE the image, or the image postinst's 'dkms autoinstall' fails and leaves
	# the kernel half-configured (which blocks apt). A bindeb-pkg build has no
	# separate linux-dtb package -- the dtbs ship inside linux-image.
	say "installing mainline kernel $KREL_NEW (headers first) ..."
	$SUDO dpkg -i "$TMP"/linux-headers-*.deb || die "installing linux-headers failed."
	prune_unbuildable_dkms "$KREL_NEW"
	$SUDO dpkg -i "$TMP"/linux-image-*.deb || die "installing the kernel failed (see dpkg errors above)."
	wire_boot "$KREL_NEW"     # point Armbian's u-boot at the mainline kernel + dtb
	$SUDO apt-mark hold "linux-image-$KREL_NEW" "linux-headers-$KREL_NEW" >/dev/null 2>&1 || true
	$SUDO mkdir -p /etc/kiln; echo "$KREL_NEW" | $SUDO tee "$MARKER" >/dev/null
	cat <<EOF

[kiln] Mainline NPU kernel $KREL_NEW installed. REBOOT into it, then run this
       installer again to finish (rknpu module + runtimes + demos):

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
# Load rknpu at boot (loading a module needs root; the dtb's NPU node is up before
# userspace, so a boot-time modprobe binds it and the render node is ready).
echo rknpu | $SUDO tee /etc/modules-load.d/rknpu.conf >/dev/null

# Restore onboard wifi/bt on the mainline kernel (the stock aic8800 doesn't build
# on 7.1; Kiln's patch does). Best-effort -- the NPU install does not depend on it.
# aic8800 is the ROCK 4D (RK3576) radio; the ROCK 3B uses a different one, so only
# run it there.
[ "$SOC" = rk3576 ] && install_patched_aic8800 "$KREL" \
	|| say "wifi: skipping aic8800 (only on the ROCK 4D / rk3576)."

# --- 5. NPU device-tree node -------------------------------------------------
# Nothing to do: on the mainline kernel the vendor NPU node is compiled into the
# dtb (kernel-patches/0004), so there is no overlay to install. wire_boot()
# already put that dtb where u-boot loads it.
say "NPU node is built into the mainline dtb (no overlay needed)."

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
# kiln-serve: OpenAI-compatible API server (LLM + optional vision). Header-only
# httplib+json, links the same librkllmrt/librknnrt. Reuses kiln_llm/vision/config.
if [ -f "$DL/rkllm.h" ] && [ -f "$DL/httplib.h" ] && [ -f "$DL/json.hpp" ]; then
	g++ -std=c++17 -O2 buildroot/board/rock4d/kiln_serve.cpp -I "$DL" -L "$DL" \
		-Wl,-rpath-link,"$DL" -lrkllmrt -lrknnrt -lpthread -lm -o /tmp/kiln-serve \
	  && $SUDO install -m0755 /tmp/kiln-serve /usr/bin/kiln-serve || say "WARN: kiln-serve build failed"
fi
$SUDO install -m0755 buildroot/rootfs/usr/bin/kiln-chat buildroot/rootfs/usr/bin/kiln-vision /usr/bin/
# NPU keep-resident: a sysfs power/control=on (via udev on rknpu bind) so the NPU
# never autosuspends -- avoids the CPU-DVFS -110 wedge AND the warm-power dead core.
$SUDO install -m0755 buildroot/rootfs/usr/bin/kiln-npu-keepon /usr/bin/kiln-npu-keepon
if [ -d /etc/udev/rules.d ]; then
	$SUDO install -m0644 buildroot/rootfs/etc/udev/rules.d/99-kiln-npu-keepon.rules /etc/udev/rules.d/
	$SUDO udevadm control --reload 2>/dev/null || true
	say "NPU keep-resident udev rule installed (applies on next cold boot)."
fi
# optional systemd unit for kiln-serve
if [ -f buildroot/rootfs/etc/systemd/system/kiln-serve.service ] && [ -d /etc/systemd/system ]; then
	$SUDO install -m0644 buildroot/rootfs/etc/systemd/system/kiln-serve.service /etc/systemd/system/
	$SUDO systemctl daemon-reload 2>/dev/null || true
	say "kiln-serve.service installed (disabled). Enable with: sudo systemctl enable --now kiln-serve"
fi

$SUDO mkdir -p /opt/models
for f in test.jpg imagenet_labels.txt "$MODEL_RKNN"; do
	[ -f "model/$f" ] && $SUDO install -m0644 "model/$f" /opt/models/ || true
done

# Seed the unified config (if absent) so kiln-chat/vision/serve/settings share
# one source of truth. The tools also work with no file (built-in defaults);
# this just makes the vision model SoC-correct and seeds a working config.
$SUDO mkdir -p /etc/kiln
if [ ! -f /etc/kiln/config.ini ]; then
	# RK3568 is a vision target (LLM impractical) -> no LLM model by default;
	# kiln-serve then runs vision-only.
	case "$SOC" in
		rk3568) LLM_MODEL="" ;;
		*)      LLM_MODEL="/opt/models/Qwen2.5-1.5B-rk3576-w4a16.rkllm" ;;
	esac
	$SUDO tee /etc/kiln/config.ini >/dev/null <<EOF
# Kiln unified config -- read by kiln-chat, kiln-vision, kiln-serve.
# Edit by hand; kiln-chat can also change the LLM knobs live (/help). Only runtime-settable fields.

[llm]
model = $LLM_MODEL
max_context_len = 2048
max_new_tokens = 512
temperature = 0.8
top_k = 1
top_p = 0.95
keep_history = 1
system_prompt = You are Qwen, created by Alibaba Cloud. You are a helpful assistant. Always reply in the same language the user writes in.

[vision]
model = /opt/models/$MODEL_RKNN
labels = /opt/models/imagenet_labels.txt
top_n = 5
core_mask = auto
priority = high

[server]
host = 0.0.0.0
port = 8080
EOF
	say "wrote default /etc/kiln/config.ini (edit by hand; kiln-chat /help for live LLM knobs)"
fi

# --- 7. finish --------------------------------------------------------------
$SUDO depmod -a "$KREL" || true
cat <<EOF

[kiln] Installed on the mainline NPU kernel. REBOOT to load rknpu against the NPU node:

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
