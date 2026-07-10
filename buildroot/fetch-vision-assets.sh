#!/usr/bin/env bash
# Fetch the MobileNet test image + ImageNet labels for the Kiln vision demo into
# model/. These are small and come straight from rknn_model_zoo.
#
# The MobileNet *.rknn itself is NOT fetched: Rockchip ships the ONNX, not a
# pre-converted rk3576 .rknn, so you convert it once with rknn-toolkit2 2.3.2 --
# on THIS board (aarch64) or an x86 host; 2.3.2 ships native aarch64 wheels, so no
# x86 box is required. See the note printed at the end and drop the result in model/.
set -euo pipefail

MODEL="$(cd "$(dirname "$0")/.." && pwd)/model"
mkdir -p "$MODEL"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "[kiln] fetching mobilenet test image + labels from rknn_model_zoo ..."
git clone --filter=blob:none --sparse --depth 1 \
	https://github.com/airockchip/rknn_model_zoo.git "$tmp/z"
( cd "$tmp/z" && git sparse-checkout set examples/mobilenet )
M="$tmp/z/examples/mobilenet/model"

cp "$M/bell.jpg" "$MODEL/test.jpg"
# ImageNet labels; strip the leading "nXXXXXXXX " synset id for clean names.
sed 's/^n[0-9]* //' "$M/synset.txt" > "$MODEL/imagenet_labels.txt"
echo "[kiln] -> model/test.jpg  and  model/imagenet_labels.txt ($(wc -l < "$MODEL/imagenet_labels.txt") classes)"

cat <<'EOF'

[kiln] You still need a MobileNet .rknn for RK3576. Convert it once with
       rknn-toolkit2 2.3.2 -- on THIS board (aarch64) or an x86 host; 2.3.2 ships
       native aarch64 wheels, so no x86 box is required. Get mobilenetv2-12.onnx
       via examples/mobilenet/model/download_model.sh, then roughly:

         # on aarch64 first:  pip install 'setuptools<81'   (toolkit needs pkg_resources)
         from rknn.api import RKNN
         r = RKNN()
         r.config(mean_values=[[123.675,116.28,103.53]],
                  std_values=[[58.395,57.12,57.375]], target_platform='rk3576')
         r.load_onnx('mobilenetv2-12.onnx')
         r.build(do_quantization=False)   # fp16 -- matches Kiln's shipped .rknn
         r.export_rknn('mobilenetv2-12_rk3576.rknn')

       then copy mobilenetv2-12_rk3576.rknn into model/  (baked to /opt/models).
EOF
