#!/usr/bin/env bash
# Fetch the VERSION-LOCKED closed runtimes for the ROCK 4D image, into
# buildroot/dl/. These are Rockchip's closed .so blobs (not GPL); Kiln does not
# commit them, it fetches them at build time like the GPL driver source.
#
#   librkllmrt.so  = rknn-llm release-v1.2.0  (Linux/aarch64)
#     Locked to v1.2.0 because the model TinyLlama-1.1B-Chat-v1.0-rk3576-w4a16.rkllm
#     was converted 2025-05-14, and v1.2.0 (built 2025-04-08) is the rkllm-toolkit
#     release in effect on that date; the next release v1.2.1 is 2025-06-25 (after).
#     .rkllm is version-locked across releases, so the runtime must match the
#     model's toolkit version. Verified: the v1.2.0 .so reports
#     "RKLLM SDK (version: 1.2.0 | target: Linux | build: f8ca3ae8 2025-04-08 ...)".
#   librknnrt.so   = rknn-toolkit2 v2.3.0    (vision smoke; any 2.x pairs with
#     rknpu 0.9.8. 2.3.0 is the 2025-era match for the v1.2.x rkllm generation.)
set -euo pipefail

DL="$(cd "$(dirname "$0")" && pwd)/dl"
mkdir -p "$DL"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "[kiln] fetching librkllmrt.so + demo from rknn-llm release-v1.2.0 ..."
git clone --filter=blob:none --sparse --depth 1 --branch release-v1.2.0 \
	https://github.com/airockchip/rknn-llm.git "$tmp/rknn-llm"
( cd "$tmp/rknn-llm" && git sparse-checkout set rkllm-runtime examples )
cp "$tmp/rknn-llm/rkllm-runtime/Linux/librkllm_api/aarch64/librkllmrt.so" "$DL/librkllmrt.so"
# stage the C-API demo source + header so post-build.sh can cross-compile a
# turnkey rkllm_demo (single .cpp linking librkllmrt; matches the v1.2.0 API).
cp "$tmp/rknn-llm/rkllm-runtime/Linux/librkllm_api/include/rkllm.h" "$DL/rkllm.h"
cp "$tmp/rknn-llm/examples/DeepSeek-R1-Distill-Qwen-1.5B_Demo/deploy/src/llm_demo.cpp" "$DL/llm_demo.cpp"

echo "[kiln] fetching librknnrt.so + rknn_api.h from rknn-toolkit2 v2.3.0 ..."
git clone --filter=blob:none --sparse --depth 1 --branch v2.3.0 \
	https://github.com/airockchip/rknn-toolkit2.git "$tmp/rknn-toolkit2"
( cd "$tmp/rknn-toolkit2" && git sparse-checkout set rknpu2/runtime/Linux/librknn_api )
RKNN_API="$tmp/rknn-toolkit2/rknpu2/runtime/Linux/librknn_api"
cp "$RKNN_API/aarch64/librknnrt.so" "$DL/librknnrt.so"
# rknn_api.h for the vision (RKNN) demo -- MobileNet image classification, the
# CNN "control experiment" alongside the RKLLM matmul path.
cp "$RKNN_API/include/rknn_api.h" "$DL/rknn_api.h"

# stb_image.h (public domain, single header) decodes the input JPEG/PNG in the
# vision demo without pulling in a full image library.
echo "[kiln] fetching stb_image.h (image decoder for the vision demo) ..."
if command -v curl >/dev/null 2>&1; then
	curl -fsSL https://raw.githubusercontent.com/nothings/stb/master/stb_image.h -o "$DL/stb_image.h"
else
	wget -qO "$DL/stb_image.h" https://raw.githubusercontent.com/nothings/stb/master/stb_image.h
fi

# kiln-serve's HTTP + JSON: cpp-httplib and nlohmann/json, both single-header,
# header-only, no runtime dependency (compile-time only). Pinned tags so the
# build is reproducible.
echo "[kiln] fetching httplib.h + json.hpp (kiln-serve OpenAI API server) ..."
_fetch(){ if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else wget -qO "$2" "$1"; fi; }
_fetch https://raw.githubusercontent.com/yhirose/cpp-httplib/v0.15.3/httplib.h "$DL/httplib.h"
_fetch https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp "$DL/json.hpp"

# librkllmrt.so NEEDs libgomp.so.1 (GNU OpenMP), but the buildroot toolchain is
# built without OpenMP (# BR2_GCC_ENABLE_OPENMP is not set), so no libgomp exists
# in it. Stage a glibc libgomp from the host aarch64 cross toolchain; verified it
# only requires up to GLIBC_2.38, matching the buildroot target glibc 2.38, and
# it is redistributable (GCC Runtime Library Exception).
echo "[kiln] staging libgomp.so.1 (librkllmrt OpenMP dependency) ..."
GOMP="$(aarch64-linux-gnu-gcc -print-file-name=libgomp.so.1 2>/dev/null || true)"
[ -f "$GOMP" ] || GOMP=/usr/lib/aarch64-linux-gnu/libgomp.so.1
[ -f "$GOMP" ] || { echo "[kiln] ERROR: no aarch64 libgomp.so.1 on host (apt install gcc-aarch64-linux-gnu)"; exit 1; }
cp -L "$GOMP" "$DL/libgomp.so.1"

echo "[kiln] runtimes in $DL:"
printf '  librkllmrt.so  '; strings "$DL/librkllmrt.so" | grep -m1 "RKLLM SDK (version" || echo "?"
printf '  librknnrt.so   '; strings "$DL/librknnrt.so"  | grep -m1 "librknnrt version" || echo "?"
printf '  libgomp.so.1   staged (%s)\n' "$GOMP"
