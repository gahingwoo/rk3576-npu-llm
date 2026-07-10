# Image inference (MobileNet / RKNN)

Kiln's LLM path drives the NPU through **RKLLM** (`librkllmrt`, transformer
matmul). This adds a **vision** path through **RKNN** (`librknnrt`, the general
CNN runtime): MobileNet image classification — the **CNN control experiment**.

Same NPU, same out-of-tree vendor `rknpu` driver, same MMU fix. If MobileNet
classifies correctly, the driver's NPU-execution fix (enable all four MMU banks,
per-job TLB flush) is not matmul-specific — it generalises to convolution. It's
also a useful, fast, deterministic workload for probing the NPU next to the LLM.

## What's on the image

- `rknn_mobilenet` — the demo (`buildroot/board/rock4d/rknn_mobilenet.cpp`):
  decodes a JPEG/PNG (stb_image), resizes to the model input, runs one NPU
  inference, prints the top-5 ImageNet classes + inference time.
- `kiln-vision` — launcher: loads `rknpu`, then runs the demo.
- `/usr/lib/librknnrt.so`, `/opt/models/test.jpg`, `/opt/models/imagenet_labels.txt`.

## You provide the model — and it must be version-matched

Rockchip ships the MobileNet **ONNX**, not a pre-converted RK3576 `.rknn`, so
convert it once yourself — **on the board (aarch64) or an x86 host**. As of
`rknn-toolkit2` **2.3.2** the full conversion toolkit ships native aarch64 wheels,
so you do *not* need to keep an x86 box around just to convert
([writeup](https://gahingwoo.github.io/posts/rknn-toolkit2-arm64/)).
`buildroot/fetch-vision-assets.sh` fetches the test image + labels and prints the
exact conversion snippet; it is, roughly:

```py
from rknn.api import RKNN
r = RKNN()
r.config(mean_values=[[123.675, 116.28, 103.53]],
         std_values=[[58.395, 57.12, 57.375]], target_platform='rk3576')
r.load_onnx('mobilenetv2-12.onnx')
r.build(do_quantization=False)     # fp16 — matches Kiln's shipped .rknn
r.export_rknn('mobilenetv2-12_rk3576.rknn')
```

Then drop `mobilenetv2-12_rk3576.rknn` into `/opt/models/`.

> **aarch64 gotchas.** On the board, run `pip install 'setuptools<81'` first — the
> toolkit still imports `pkg_resources`, which setuptools 81 removed. And a `.rknn`
> is **not** byte-reproducible: it embeds build metadata, so the same model
> converted twice won't match by md5 (don't verify models by checksum).

**RKNN has the same model/runtime version-lock as RKLLM.** Convert with a
`rknn-toolkit2` on the **2.3.x** line (2.3.2 verified on-board) so it matches the
bundled `librknnrt` runtime (Kiln pins **2.3.0**). A model converted with toolkit
**2.1.0** threw `std::out_of_range` in `rknn_inputs_set` under `librknnrt` 2.3.0 —
no crash in Kiln's code, purely the version mismatch. A 2.3.x-converted ONNX
MobileNetV2 just works.

## Run

```sh
# on the board, after copying mobilenetv2-12_rk3576.rknn to /opt/models/
kiln-vision /opt/models/test.jpg
```

Real output (the bundled `test.jpg` is a bell), classifying correctly at ~6 ms:

```
=== Kiln RK3576 NPU vision (MobileNet, librknnrt) ===
model: 1 in / 1 out, input 224x224x3 ...

top-5 of 1000 classes  (NPU inference 5.9 ms):
  1. [ 494] chime, bell, gong            18.6719
  2. [ 653] milk can                     12.0391
  3. [ 469] caldron, cauldron            11.4844
  4. [ 442] bell cote, bell cot          11.1562
  5. [ 747] punching bag, punch bag ...  10.6094
[bench] rknn inference: 5.9 ms (169.5 fps)
```

## Build integration

`fetch-runtimes.sh` fetches `rknn_api.h` + `stb_image.h`; `post-build.sh` builds
`rknn_mobilenet` next to `rkllm_demo`, installs `librknnrt.so`, and bakes the test
image + labels. A `mobilenetv2-12_rk3576.rknn` in `model/` is baked to `/opt/models/`.

## Object detection — EXPERIMENTAL foundation

> **Status: experimental, NOT verified on hardware, OFF by default.** Kiln does not
> claim working object detection. The pieces below are a *foundation* to build on.

The vision path is **classification only** by default. A separate, experimental
detection path lives in `buildroot/board/rock4d/kiln_detect.h`, kept apart from the
classifier so the working classify path is untouched. It is enabled by
`[vision] task = detect` and supports three YOLO families: **YOLOv8 / YOLO11**
(anchor-free, DFL), **YOLOv5 / YOLOv7** (anchor-based), and **YOLOX** (anchor-free +
objectness). `detector = auto` picks the family from the model's output shapes; you
can force it (`yolov8` / `yolov5` / `yolox`).

What's **verified on the host** (unit tests, no NPU): the letterbox preprocessing +
its inverse box mapping, IoU, per-class NMS, box drawing, AND all three per-branch
decoders — planted synthetic tensors decode to the expected boxes (the decode math
mirrors `airockchip/rknn_model_zoo`). What **still needs on-board verification**:
that a *real* converted `.rknn`'s output layout matches what the decoders assume —
the output ordering, NCHW dims, the family/num-class inference — end-to-end on a
board. So boxes from a real model may still be wrong until that's checked.

To try it (you supply the model — Kiln ships none):

```ini
[vision]
task = detect
detector = auto                              # or yolov8 / yolov5 / yolox
model = /opt/models/yolov8n_rk3576.rknn      # your YOLO .rknn
labels = /opt/models/coco_80_labels.txt      # shipped: 80 COCO classes
conf_threshold = 0.25
nms_iou = 0.45
```

Then `kiln-vision image.jpg [out.jpg]` prints boxes (with an "experimental/unverified"
banner) and, given a second image path, saves `out.jpg` with the boxes drawn on it;
`kiln-serve` exposes `POST /v1/vision/detect`; and `kiln-config` → Vision flips the
task. Convert the `.rknn` the same way as classification (`rknn-toolkit2` **2.3.2**,
on the board or an x86 host).

**Licensing (important — Kiln bundles no models, you supply them):** Ultralytics
**YOLOv5 / YOLOv8 / YOLO11 are AGPL-3.0**; deploying `kiln-serve` publicly with one
may carry AGPL network-use obligations. **YOLOX is Apache-2.0** (permissive) and is
a clean alternative if you want to avoid AGPL — and its decode head is implemented.

**To finish it** (roadmap): verify + tune the decode on-board against a known model
and image (the one board-only gap); confirm/adjust the `auto` family + output-order
assumptions per real export; the int8-gating speed optimization (the foundation reads
floats for correctness); and text labels on the drawn overlay (boxes are drawn now).

## Why "control experiment"

The open-driver (rocket) investigation was ultimately about getting a **conv** to
compute. Running MobileNet through the *vendor* RKNN stack on mainline is the
clean comparison point: it isolates "does the NPU execute conv correctly under
Kiln's driver" from all of Mesa's payload-encoding questions.
