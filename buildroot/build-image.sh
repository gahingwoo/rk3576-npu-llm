#!/usr/bin/env bash
# Kiln: build a flashable ROCK 4D sdcard.img (mainline kernel + out-of-tree
# vendor rknpu.ko + version-locked librkllmrt/librknnrt).
#
# Reuses the rocket tree's buildroot SOURCE (br-src) and the kernel tree that
# already carries the RK3576 IOMMU/PD/clock platform patches. No source under
# /home/parallels is modified: rocket is turned OFF by the Kiln kernel fragment,
# and the rocket NPU DT nodes are removed at the DT level by the Kiln board DTS
# (dts/rk3576-rock-4d-kiln.dts) via BR2_LINUX_KERNEL_CUSTOM_DTS_PATH.
#
# Edit the four paths below to match your machine, then run this script.
set -euo pipefail

# ---- paths you must set -----------------------------------------------------
BR_SRC="${BR_SRC:-/home/parallels/Desktop/linux-rk3576-npu/buildroot/br-src}"        # buildroot source
KERNEL_SRC="${KERNEL_SRC:-/home/parallels/Desktop/rock4d_package/kernel-build/linux-next}" # linux-next w/ platform patches
BASE_CONFIG="${BASE_CONFIG:-/home/parallels/Desktop/linux-rk3576-npu/kernel/base.config}"  # kernel .config base
ROCKCHIP_BINARIES="${ROCKCHIP_BINARIES:-/home/parallels/Desktop/rock4d_package/binaries}"   # rock4d u-boot dir
# -----------------------------------------------------------------------------

KILN="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$KILN/buildroot"
OUT="${OUT:-$KILN/br-out}"                # writable buildroot output (NOT under /home/parallels read-only trees)
export ROCKCHIP_BINARIES

for p in "$BR_SRC/Makefile" "$KERNEL_SRC/Makefile" "$BASE_CONFIG" "$ROCKCHIP_BINARIES/rock4d-sd-uboot.img"; do
	[ -e "$p" ] || { echo "ERROR: not found: $p (edit the paths at the top of $0)"; exit 1; }
done

echo "==> Kiln build: BR_SRC=$BR_SRC KERNEL_SRC=$KERNEL_SRC OUT=$OUT"
mkdir -p "$OUT" "$EXT/dl"

# 0. reuse the reference buildroot download cache (saves re-downloading package
#    sources). BR2_DL_DIR must be writable, so seed a Kiln-owned copy.
REF_DL="${REF_DL:-$(dirname "$BR_SRC")/br-src/dl}"
KILN_DL="${KILN_DL:-$KILN/br-dl}"
if [ -d "$REF_DL" ] && [ ! -d "$KILN_DL" ]; then
	echo "==> seeding download cache from $REF_DL"
	cp -a "$REF_DL" "$KILN_DL"
fi
export BR2_DL_DIR="$KILN_DL"

# 1. stage base.config where the defconfig references it
cp "$BASE_CONFIG" "$EXT/dl/base.config"

# 2. fetch the version-locked closed runtimes (librkllmrt v1.2.0, librknnrt)
"$EXT/fetch-runtimes.sh"

# 3. fetch + shim the GPL rknpu driver (build happens in post-build against the
#    kernel buildroot builds). Skip if already fetched+shimmed so in-tree edits
#    (e.g. bring-up diagnostics) survive a rebuild; force with KILN_REFETCH=1.
if [ -n "${KILN_REFETCH:-}" ] || [ ! -f "$KILN/driver/rknpu/rknpu_drv.c" ]; then
	"$KILN/driver/fetch-vendor-driver.sh"
fi

# 4. point buildroot's kernel at the patched linux-next tree (rsync'd, read-only safe)
cat > "$OUT/local.mk" <<EOF
LINUX_OVERRIDE_SRCDIR = $KERNEL_SRC
EOF

# 5. configure + build
make -C "$BR_SRC" O="$OUT" BR2_EXTERNAL="$EXT" ${DEFCONFIG:-kiln_rock4d_defconfig}
[ -n "${KILN_LINUX_REBUILD:-}" ] && make -C "$BR_SRC" O="$OUT" linux-dirclean || true
echo "==> building (first run compiles the toolchain + kernel; ~40-90 min)"
make -C "$BR_SRC" O="$OUT"

echo "==> DONE. Flashable image: $OUT/images/sdcard.img"
ls -la "$OUT/images/sdcard.img"
