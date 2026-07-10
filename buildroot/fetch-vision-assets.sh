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

# Idempotent: skip the clone if the test image + labels are already staged, so a
# cache pre-fetched (online) in installer phase 1 lets phase 2 run OFFLINE.
# KILN_FORCE_FETCH=1 forces a refresh.
if [ -z "${KILN_FORCE_FETCH:-}" ] && [ -s "$MODEL/test.jpg" ] && [ -s "$MODEL/imagenet_labels.txt" ]; then
	echo "[kiln] have model/test.jpg + model/imagenet_labels.txt (skip rknn_model_zoo clone)"
else
	echo "[kiln] fetching mobilenet test image + labels from rknn_model_zoo ..."
	git clone --filter=blob:none --sparse --depth 1 \
		https://github.com/airockchip/rknn_model_zoo.git "$tmp/z"
	( cd "$tmp/z" && git sparse-checkout set examples/mobilenet )
	M="$tmp/z/examples/mobilenet/model"

	cp "$M/bell.jpg" "$MODEL/test.jpg"
	# ImageNet labels; strip the leading "nXXXXXXXX " synset id for clean names.
	sed 's/^n[0-9]* //' "$M/synset.txt" > "$MODEL/imagenet_labels.txt"
	echo "[kiln] -> model/test.jpg  and  model/imagenet_labels.txt ($(wc -l < "$MODEL/imagenet_labels.txt") classes)"
fi

# COCO-80 class labels for the EXPERIMENTAL detection path (task=detect). The class
# names are a public factual list, generated inline (no network) so it's always here.
# Idempotent. Point [vision] labels at this when you switch to a YOLO detector.
if [ ! -s "$MODEL/coco_80_labels.txt" ]; then
	cat > "$MODEL/coco_80_labels.txt" <<'COCO'
person
bicycle
car
motorcycle
airplane
bus
train
truck
boat
traffic light
fire hydrant
stop sign
parking meter
bench
bird
cat
dog
horse
sheep
cow
elephant
bear
zebra
giraffe
backpack
umbrella
handbag
tie
suitcase
frisbee
skis
snowboard
sports ball
kite
baseball bat
baseball glove
skateboard
surfboard
tennis racket
bottle
wine glass
cup
fork
knife
spoon
bowl
banana
apple
sandwich
orange
broccoli
carrot
hot dog
pizza
donut
cake
chair
couch
potted plant
bed
dining table
toilet
tv
laptop
mouse
remote
keyboard
cell phone
microwave
oven
toaster
sink
refrigerator
book
clock
vase
scissors
teddy bear
hair drier
toothbrush
COCO
	echo "[kiln] -> model/coco_80_labels.txt (80 classes, for task=detect)"
fi

# Optional: fetch a pre-converted default MobileNet .rknn so the install ends
# ready-to-run for vision. The mobilenetv2-12 ONNX (Apache-2.0) and its rknn_model_zoo
# recipe (Apache-2.0) make a converted .rknn license-clean to redistribute, but
# Rockchip publishes no pre-converted RK3576 .rknn -- so this pulls it from a
# Kiln-hosted release IF one is configured. Set KILN_MODELS_URL to the base URL
# that serves "$RKNN" (e.g. a GitHub release-asset base). Best-effort + idempotent;
# with no URL set (the default), we just print the convert-it-yourself recipe below.
RKNN="${KILN_MODEL_RKNN:-mobilenetv2-12_rk3576.rknn}"
if [ -s "$MODEL/$RKNN" ]; then
	echo "[kiln] have model/$RKNN (skip download)"
	GOT_RKNN=1
elif [ -n "${KILN_MODELS_URL:-}" ]; then
	echo "[kiln] fetching default vision model $RKNN from $KILN_MODELS_URL ..."
	if curl -fsSL --connect-timeout 8 "$KILN_MODELS_URL/$RKNN" -o "$MODEL/$RKNN.part" && [ -s "$MODEL/$RKNN.part" ]; then
		mv "$MODEL/$RKNN.part" "$MODEL/$RKNN"; echo "[kiln] -> model/$RKNN"; GOT_RKNN=1
	else
		rm -f "$MODEL/$RKNN.part"; echo "[kiln] note: couldn't fetch $RKNN from KILN_MODELS_URL; convert it yourself (below)."
	fi
fi
[ -n "${GOT_RKNN:-}" ] && exit 0   # ready-to-run; skip the convert-it-yourself note

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
