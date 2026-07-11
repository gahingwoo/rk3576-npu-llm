# Benchmarks

All numbers below are measured on the **only tested target**: a **Radxa ROCK 4D
(RK3576)** on Armbian, Kiln mainline `linux-7.1.3` kernel, `librkllmrt` 1.2.0 /
`librknnrt` 2.3.0. Your mileage varies with the model, quantization, thermal state, and
DRAM speed. Every tool prints its own `[bench]` line, so these are easy to reproduce.

## LLM (kiln-chat / kiln-serve)

Decode throughput, greedy (`top_k = 1`), W4A16 quantized models on the NPU:

| model | decode | notes |
|---|---|---|
| **Llama-3.2-1B-Instruct** (w4a16) | **~13 tok/s** | fastest of the two |
| **Qwen2.5-1.5B-Instruct** (w4a16) | **~9 tok/s** | larger, a bit slower |

`kiln-chat` prints per-turn:
```
[bench] tokens=…  prefill(TTFT)=… ms  decode=… tok/s  total=… ms
```
- **decode tok/s** is the steady-state generation rate (what "how fast is it" usually
  means).
- **TTFT** (time-to-first-token) is the prefill latency; it grows with the prompt +
  history length.

Reproduce: `kiln-chat`, ask a question, read the `[bench]` line. Switch models live with
`/model` to compare on the same box.

## Vision — classification (kiln-vision)

MobileNetV2, 224×224, fp16, single NPU inference:

| workload | latency | throughput |
|---|---|---|
| **MobileNetV2-12** | **~6 ms** (5.9 ms measured) | **~169 fps** |

Reproduce:
```sh
kiln-vision /opt/models/test.jpg
# =>  [bench] rknn inference: 5.9 ms (169.5 fps)
```

## Vision — detection (kiln-vision, task = detect)

YOLOv8n (airockchip export), 640×640, fp16, on the classic dog-bike-car image:

| workload | latency | result |
|---|---|---|
| **YOLOv8n** | **~37 ms** | bicycle / truck / dog, correct |

Reproduce:
```sh
kiln-vision /opt/models/dog_bike_car.jpg out.jpg   # prints boxes + saves an annotated image
```

## Context

- These are **NPU inference** timings — the point of Kiln is that the *vendor NPU stack
  runs on a mainline kernel*, and it's as fast there as on the vendor BSP.
- Classification at ~169 fps and an LLM at 9–13 tok/s on a ~$40-class board, fully
  offline, is the headline: a private assistant + real-time-ish vision on the edge.
- Detection is newer and tested on fewer models than classification — treat a new model
  as "confirm it once" (see [VISION.md](VISION.md)).

Have numbers from a different model or (especially) a **different board**? A
`kiln-doctor` paste + your `[bench]` lines in an
[issue](https://github.com/gahingwoo/kiln/issues) is very welcome.
