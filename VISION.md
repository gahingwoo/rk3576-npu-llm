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

## You provide the model

Rockchip ships the MobileNet **ONNX**, not a pre-converted RK3576 `.rknn`, so
convert it once on an **x86** host with `rknn-toolkit2` (target `rk3576`) and
drop `mobilenet_v2_for_rk3576.rknn` into `/opt/models/`. `buildroot/fetch-vision-assets.sh`
fetches the test image + labels and prints the exact conversion snippet.

## Run

```sh
# on the board, after copying mobilenet_v2_for_rk3576.rknn to /opt/models/
kiln-vision /opt/models/test.jpg
```

Expected shape of the output:

```
=== Kiln RK3576 NPU vision (MobileNet, librknnrt) ===
model: 1 in / 1 out, input 224x224x3

top-5 of 1000 classes  (NPU inference 3.2 ms):
  1. [ 494] bell cote, bell cot            0.71
  2. ...
[bench] rknn inference: 3.2 ms (312.5 fps)
```

## Build integration

`fetch-runtimes.sh` fetches `rknn_api.h` + `stb_image.h`; `post-build.sh` builds
`rknn_mobilenet` next to `rkllm_demo`, installs `librknnrt.so`, and bakes the test
image + labels. A `mobilenet_v2_for_rk3576.rknn` in `model/` is baked to `/opt/models/`.

## Why "control experiment"

The open-driver (rocket) investigation was ultimately about getting a **conv** to
compute. Running MobileNet through the *vendor* RKNN stack on mainline is the
clean comparison point: it isolates "does the NPU execute conv correctly under
Kiln's driver" from all of Mesa's payload-encoding questions.
