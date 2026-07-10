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
