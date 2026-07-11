# Kiln documentation

**English** · [简体中文](zh/README.md)

Start at the root [`README.md`](../README.md) — it's the overview and the install
one-liner. This page is the full map.

## Install & setup

| doc | what |
|---|---|
| [ARMBIAN.md](ARMBIAN.md) | Install on Armbian — the one-command hands-off path (two auto-reboots), `KILN_MANUAL=1`, and the `KILN_SKIP_*` granular re-runs. |
| [MAINLINE-KERNEL.md](MAINLINE-KERNEL.md) | The mainline `linux-7.1.3` base + Kiln's NPU patch set; how CI builds it and the manual build/install. |
| [buildroot/README.md](../buildroot/README.md) | The flashable br2-external `sdcard.img` (rootfs + module + optional model) — the maintainer image path. |

## Tools

All read one config, `/etc/kiln/config.ini`.

| doc | tool |
|---|---|
| [CONFIG.md](CONFIG.md) | `/etc/kiln/config.ini` — every field, and how to edit it (by hand or via `kiln-config`). |
| [TOOLS.md](TOOLS.md) | `kiln` (umbrella launcher / menu), `kiln-doctor` (pass/fail health check), `kiln-config` (whiptail config TUI), `kiln-convert` (on-board model conversion). |
| [CHAT.md](CHAT.md) | `kiln-chat` — the interactive LLM CLI and its slash commands. |
| [SERVER.md](SERVER.md) | `kiln-serve` — the OpenAI-compatible HTTP API (LLM + optional vision). |
| [VISION.md](VISION.md) | `kiln-vision` — MobileNet image classification + YOLO object detection, and how to build an `.rknn` (`kiln-convert`). |

## Integrate & operate

| doc | what |
|---|---|
| [OPENWEBUI.md](OPENWEBUI.md) | Point **Open WebUI** (a ChatGPT-style web page), **LangChain**, the `openai` SDK, or any OpenAI client at the board. |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | **Symptom / exact error → cause → fix** knowledge base (Ctrl-F the message you're seeing). Start with `sudo kiln-doctor`. |
| [BENCHMARK.md](BENCHMARK.md) | Measured LLM tok/s, vision ms/fps, and detection latency — and how to reproduce them. |

## Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md). The single most useful contribution right now
is **testing on a board other than the ROCK 4D** and reporting back.

## Boards

| doc | board |
|---|---|
| [RK3568.md](RK3568.md) | RK3568 / Radxa ROCK 3B — vision-only, untested on hardware (help wanted). |

## Internals (NPU bring-up)

| doc | what |
|---|---|
| [kernel-patches/README.md](../kernel-patches/README.md) | The ten mainline NPU patches (0001–0010), per-patch rationale. |
| [driver/patches/README.md](../driver/patches/README.md) | The out-of-tree `rknpu` port (`kiln-mainline.patch`) + the register-dump debug probe. |
| [aic8800-patches/README.md](../aic8800-patches/README.md) | The onboard Wi-Fi (aic8800) Linux 7.1 compat patch. |
| [capture/README.md](../capture/README.md) | The NPU per-op capture / environment-diff harness (bring-up tooling). |
| [scripts/README.md](../scripts/README.md) | The CLIs (`kiln-install` / `kiln-phase2` / `kiln-doctor` / `kiln-config`) and the two-phase install flow. |
