#!/usr/bin/env bash
# Kiln buildroot ROOTFS_POST_BUILD_SCRIPT.
# Runs after the rootfs tree is populated, before it is packed into rootfs.ext2.
# Buildroot exports: TARGET_DIR, BUILD_DIR, HOST_DIR, BINARIES_DIR, BASE_DIR.
# Buildroot passes $1 = TARGET_DIR automatically; BR2_ROOTFS_POST_SCRIPT_ARGS
# are appended AFTER, so the Kiln repo path is $2.
#
# Does three things:
#   1. Fetch + shim + build the out-of-tree vendor rknpu.ko against the kernel
#      buildroot just built, and install it into the target rootfs.
#   2. Install the version-locked closed runtimes (librkllmrt v1.2.0, librknnrt).
#   3. Optionally bake the .rkllm model in (KILN_BAKE_MODEL=1); default is to
#      leave it out (668 MB) and scp it to the board.
set -euo pipefail

KILN="${2:?Kiln repo path missing (BR2_ROOTFS_POST_SCRIPT_ARGS; note \$1 is TARGET_DIR)}"

# --- locate the kernel buildroot just built + its cross toolchain ------------
KDIR="$(ls -d "$BUILD_DIR"/linux-custom 2>/dev/null || ls -d "$BUILD_DIR"/linux-* 2>/dev/null | grep -v headers | head -1)"
[ -f "$KDIR/Module.symvers" ] || { echo "[kiln] ERROR: built kernel not found under $BUILD_DIR"; exit 1; }
CROSS="$HOST_DIR/bin/$(basename "$(ls "$HOST_DIR"/bin/*-linux-*-gcc | head -1)" | sed 's/gcc$//')"
KREL="$(cat "$KDIR/include/config/kernel.release")"
echo "[kiln] kernel=$KREL  KDIR=$KDIR  CROSS=$CROSS"

# --- 1. fetch + shim + build rknpu.ko ---------------------------------------
if [ ! -f "$KILN/driver/rknpu/rknpu_drv.c" ]; then
	"$KILN/driver/fetch-vendor-driver.sh"          # clones Armbian rknpu + auto-applies shims
fi
make -C "$KDIR" M="$KILN" ARCH=arm64 CROSS_COMPILE="$CROSS" modules
install -D -m0644 "$KILN/rknpu.ko" "$TARGET_DIR/lib/modules/$KREL/extra/rknpu.ko"
# refresh modules.dep so `modprobe rknpu` works on the board
"$HOST_DIR/sbin/depmod" -b "$TARGET_DIR" "$KREL" 2>/dev/null || \
	depmod -b "$TARGET_DIR" "$KREL" 2>/dev/null || true
echo "[kiln] installed rknpu.ko -> /lib/modules/$KREL/extra/"

# --- 2. install version-locked closed runtimes ------------------------------
[ -f "$KILN/buildroot/dl/librkllmrt.so" ] || "$KILN/buildroot/fetch-runtimes.sh"
install -D -m0755 "$KILN/buildroot/dl/librkllmrt.so" "$TARGET_DIR/usr/lib/librkllmrt.so"
install -D -m0755 "$KILN/buildroot/dl/librknnrt.so"  "$TARGET_DIR/usr/lib/librknnrt.so"
# librkllmrt NEEDs libgomp.so.1 at runtime; the buildroot toolchain has no OpenMP,
# so ship the staged glibc libgomp (GLIBC_2.38-compatible with the target).
install -D -m0755 "$KILN/buildroot/dl/libgomp.so.1" "$TARGET_DIR/usr/lib/libgomp.so.1"
echo "[kiln] installed librkllmrt.so + librknnrt.so + libgomp.so.1 -> /usr/lib/"

# --- 2b. cross-compile the turnkey NPU demos --------------------------------
# Tracked sources under board/rock4d/: rkllm_chat.cpp (LLM chat, Qwen ChatML +
# per-turn tok/s benchmark) and rknn_mobilenet.cpp (MobileNet image classification
# -- the CNN "control experiment"). Headers (rkllm.h, rknn_api.h, stb_image.h) are
# fetched into dl/. -include cstdint: v1.2.0 rkllm.h omits it. -rpath-link dl
# resolves librkllmrt.so's libgomp.so.1 at link. The buildroot toolchain is
# preferred; a host aarch64 g++ + -static-libstdc++ is the fallback for when the
# buildroot toolchain's crt*.o dev objects were cleaned (avoids a GLIBCXX bump).
DL="$KILN/buildroot/dl"
build_one() {  # $1 src  $2 out  $3.. link libs
	src="$1"; out="$2"; shift 2
	[ -f "$src" ] || { echo "[kiln] WARN: $(basename "$src") missing; skip"; return; }
	if [ -x "${CROSS}g++" ] && "${CROSS}g++" -include cstdint "$src" -I"$DL" -L"$DL" \
		-Wl,-rpath-link,"$DL" "$@" -o "$out" 2>/dev/null; then
		echo "[kiln] built $(basename "$out") (buildroot toolchain)"
	elif command -v aarch64-linux-gnu-g++ >/dev/null 2>&1 && aarch64-linux-gnu-g++ \
		-include cstdint "$src" -I"$DL" -L"$DL" -static-libstdc++ -static-libgcc \
		-Wl,-rpath-link,"$DL" "$@" -o "$out"; then
		echo "[kiln] built $(basename "$out") (host g++ + static libstdc++)"
	else
		echo "[kiln] WARN: build of $(basename "$out") failed; skip"
	fi
}
build_one "$KILN/buildroot/board/rock4d/rkllm_chat.cpp"     "$TARGET_DIR/usr/bin/rkllm_demo"     -lrkllmrt -lpthread
build_one "$KILN/buildroot/board/rock4d/rknn_mobilenet.cpp" "$TARGET_DIR/usr/bin/rknn_mobilenet" -lrknnrt -lpthread -lm
# librknnrt.so alongside librkllmrt.so for the vision demo
[ -f "$DL/librknnrt.so" ] && install -D -m0644 "$DL/librknnrt.so" "$TARGET_DIR/usr/lib/librknnrt.so"

# --- 3. models + vision assets ----------------------------------------------
mkdir -p "$TARGET_DIR/opt/models"
# vision test image + ImageNet labels (small; always bake if present)
[ -f "$KILN/model/test.jpg" ]            && install -m0644 "$KILN/model/test.jpg"            "$TARGET_DIR/opt/models/test.jpg"
[ -f "$KILN/model/imagenet_labels.txt" ] && install -m0644 "$KILN/model/imagenet_labels.txt" "$TARGET_DIR/opt/models/imagenet_labels.txt"
# MobileNet .rknn (small, ~6 MB) for the vision control experiment
[ -f "$KILN/model/mobilenetv2-12_rk3576.rknn" ] \
	&& install -m0644 "$KILN/model/mobilenetv2-12_rk3576.rknn" "$TARGET_DIR/opt/models/mobilenetv2-12_rk3576.rknn" \
	&& echo "[kiln] baked mobilenetv2-12_rk3576.rknn into /opt/models/"
# LLM model (large, ~1.4 GB) only when KILN_BAKE_MODEL=1
if [ "${KILN_BAKE_MODEL:-0}" = "1" ]; then
	M="$KILN/model/Qwen2.5-1.5B-rk3576-w4a16.rkllm"
	[ -f "$M" ] && install -D -m0644 "$M" "$TARGET_DIR/opt/models/$(basename "$M")" \
		&& echo "[kiln] baked LLM model into /opt/models/ (image ~1.4 GB larger)"
else
	echo "[kiln] LLM model NOT baked in; scp it to /opt/models on the board"
fi

# --- auto-load rknpu at boot ------------------------------------------------
# modprobe binds rknpu; the cold power-on runs the 0009 pd_power arm and the NPU
# rail stays up via 0010 (regulator-always-on), so no keep-resident hack is needed.
install -D -m0755 /dev/stdin "$TARGET_DIR/etc/init.d/S89rknpu" <<'INIT'
#!/bin/sh
case "$1" in
	start) modprobe rknpu 2>/dev/null || true ;;
	stop)  : ;;
esac
INIT
echo "[kiln] post-build done."
