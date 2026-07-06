#!/usr/bin/env bash
# Build a PATCHED Armbian edge kernel for the Radxa ROCK 4D (RK3576) that carries
# the RK3576 NPU pm-domain fix (kernel-patches/0001-...). Without that built-in
# fix the NPU power domain SErrors on the first inference -> hard freeze; the
# out-of-tree rknpu module and the DT overlay cannot supply it. See
# ARMBIAN-KERNEL.md and kernel-patches/README.md.
#
# Run this on an x86_64 build host (NOT the board). It uses the Armbian build
# framework, which cross-compiles the kernel package. Output is a set of
# linux-image / linux-dtb / linux-headers .deb files you then install on the board.
#
#   BOARD=<from /etc/armbian-release>  bash scripts/kiln-build-armbian-kernel.sh
set -euo pipefail

# ROCK 4D's Armbian board slug + branch (config/boards/radxa-rock-4d.conf,
# BOARDFAMILY=rk35xx, KERNEL_TARGET="vendor,edge"). CONFIRM on the board with:
#   cat /etc/armbian-release | grep -E '^(BOARD|BRANCH)='
BOARD="${BOARD:-${KILN_BOARD:-radxa-rock-4d}}"
BRANCH="${BRANCH:-${KILN_BRANCH:-edge}}"
# Armbian's rockchip64 kernel patch dir is versioned, NOT per-branch. From
# config/sources/families/include/rockchip64_common.inc: current->6.18,
# edge->7.1, bleedingedge->7.2. edge (7.1) is the base Kiln's NPU patches were
# written on, so they apply cleanly. Override KVER if edge moves on.
KVER="${KVER:-7.1}"
ARMBIAN_REPO="${ARMBIAN_REPO:-https://github.com/armbian/build.git}"
WORK="${KILN_BUILD_DIR:-$HOME/kiln-armbian-build}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"     # kiln repo root
# Which Kiln kernel patches to fold in. 0001 is the fatal NPU fix; 0002/0003 are
# optional (see kernel-patches/README.md). Override with KILN_KPATCHES="0001 0002".
KPATCHES="${KILN_KPATCHES:-0001}"

say(){ printf '\n\033[1;36m[kiln-kbuild]\033[0m %s\n' "$*"; }
die(){ printf '\n\033[1;31m[kiln-kbuild] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = x86_64 ] || say "note: Armbian's kernel build expects an x86_64 host; you are on $(uname -m)."

# 1. Armbian build framework -------------------------------------------------
if [ ! -d "$WORK/.git" ]; then
	say "cloning Armbian build framework into $WORK ..."
	git clone --depth 1 "$ARMBIAN_REPO" "$WORK"
else
	say "reusing $WORK (git pull for latest board support) ..."
	git -C "$WORK" pull --ff-only || true
fi

# 2. drop Kiln's kernel patches into userpatches -----------------------------
# Armbian applies every .patch under userpatches/kernel/archive/<KERNELPATCHDIR>/
# on top of its own kernel patch set. For rk35xx/rockchip64 edge that dir is
# versioned (rockchip64-7.1), not rockchip64-edge.
PDIR="$WORK/userpatches/kernel/archive/rockchip64-$KVER"
say "installing Kiln kernel patches ($KPATCHES) into $PDIR ..."
mkdir -p "$PDIR"
for n in $KPATCHES; do
	src=$(ls "$HERE"/kernel-patches/${n}-*.patch 2>/dev/null | head -1) \
		|| die "no kernel-patches/${n}-*.patch in the Kiln repo"
	cp "$src" "$PDIR/"
	echo "  + $(basename "$src")"
done

# 3. build the kernel package only -------------------------------------------
say "building the Armbian $BRANCH kernel for BOARD=$BOARD (this takes a while) ..."
cd "$WORK"
# KERNEL_CONFIGURE=no  -> keep Armbian's stock config (+ our patch), no menuconfig
./compile.sh kernel BOARD="$BOARD" BRANCH="$BRANCH" KERNEL_CONFIGURE=no

# 4. collect ------------------------------------------------------------------
say "done. kernel .deb packages:"
ls -1 "$WORK"/output/debs/linux-{image,dtb,headers}-*"$BRANCH"* 2>/dev/null || \
	ls -1 "$WORK"/output/debs/ | grep -E 'linux-(image|dtb|headers)' || true
cat <<EOF

Next, on the BOARD:
  1. copy the linux-image + linux-dtb (+ linux-headers) .deb over, then:
       sudo dpkg -i linux-image-*.deb linux-dtb-*.deb linux-headers-*.deb
     (DKMS rebuilds rknpu for the new kernel automatically via the headers.)
  2. re-enable the NPU overlay and boot-time load, then reboot:
       sudo sed -i 's/^user_overlays=.*/user_overlays=kiln-npu/' /boot/armbianEnv.txt
       sudo mv /etc/modules-load.d/rknpu.conf.disabled /etc/modules-load.d/rknpu.conf 2>/dev/null || \
         echo rknpu | sudo tee /etc/modules-load.d/rknpu.conf
       sudo reboot
  3. verify: sudo dmesg | grep -i rknpu   # expect st=0x19/... and NO 'pm runtime ... -110'
             kiln-vision /opt/models/test.jpg
EOF
