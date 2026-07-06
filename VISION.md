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
convert it once on an **x86** host with `rknn-toolkit2` (target `rk3576`) and
drop `mobilenetv2-12_rk3576.rknn` into `/opt/models/`. `buildroot/fetch-vision-assets.sh`
fetches the test image + labels and prints the exact conversion snippet.

**RKNN has the same model/runtime version-lock as RKLLM.** Convert the model with
the `rknn-toolkit2` version that matches the bundled `librknnrt` (Kiln pins
**2.3.0**). A model converted with toolkit **2.1.0** threw `std::out_of_range` in
`rknn_inputs_set` under `librknnrt` 2.3.0 — no crash in Kiln's code, purely the
version mismatch. A 2.3.0-converted ONNX MobileNetV2 just works.

## Run

```sh
# on the board, after copying mobilenetv2-12_rk3576.rknn to /opt/models/
kiln-vision /opt/models/test.jpg
```

Real output (the bundled `test.jpg` is a bell), classifying correctly at ~6 ms:

```
=== Kiln RK3576 NPU vision (MobileNet, librknnrt) ===
model: 1 in / 1 out, input 224x224x3 ...

top-5 of 1000 classes  (NPU inference 6.2 ms):
  1. [ 494] chime, bell, gong            18.6719
  2. [ 653] milk can                     12.0391
  3. [ 469] caldron, cauldron            11.4844
  4. [ 442] bell cote, bell cot          11.1562
  5. [ 747] punching bag, punch bag ...  10.6094
[bench] rknn inference: 6.2 ms (161.0 fps)
```

## Build integration

`fetch-runtimes.sh` fetches `rknn_api.h` + `stb_image.h`; `post-build.sh` builds
`rknn_mobilenet` next to `rkllm_demo`, installs `librknnrt.so`, and bakes the test
image + labels. A `mobilenetv2-12_rk3576.rknn` in `model/` is baked to `/opt/models/`.

## Why "control experiment"

The open-driver (rocket) investigation was ultimately about getting a **conv** to
compute. Running MobileNet through the *vendor* RKNN stack on mainline is the
clean comparison point: it isolates "does the NPU execute conv correctly under
Kiln's driver" from all of Mesa's payload-encoding questions.
