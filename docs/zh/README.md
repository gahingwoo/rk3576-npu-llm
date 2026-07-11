# Kiln 中文文档

从根目录 [`README.zh-CN.md`](../../README.zh-CN.md) 开始——那是概览和安装一条命令。这里是文档地图。

> 中文文档覆盖最常用的上手路径(安装 → 排查 → 接入)。更细的参考文档目前是英文的,已在下方标注并给出链接。

## 中文指南

| 文档 | 内容 |
|---|---|
| [安装](INSTALL.md) | 在 Armbian 上一条命令安装(两次自动重启)、刷卡镜像、手动分阶段、以及各种 `KILN_*` 开关。 |
| [故障排查](TROUBLESHOOTING.md) | **报错原文 → 原因 → 修法** 知识库(Ctrl-F 搜你看到的报错)。先跑 `sudo kiln-doctor`。 |
| [Open WebUI 与生态接入](OPENWEBUI.md) | 把 Open WebUI(ChatGPT 式网页)、LangChain、`openai` SDK 或任意 OpenAI 客户端指向板子。 |

## 参考文档(英文)

| 文档 | 内容 |
|---|---|
| [VISION.md](../VISION.md) | `kiln-vision` —— 图像分类 + YOLO 目标检测,以及如何用 `kiln-convert` 转 `.rknn`。 |
| [CONFIG.md](../CONFIG.md) | `/etc/kiln/config.ini` —— 每个字段及编辑方式。 |
| [TOOLS.md](../TOOLS.md) | `kiln`(总启动器)、`kiln-doctor`、`kiln-config`、`kiln-convert`。 |
| [CHAT.md](../CHAT.md) | `kiln-chat` —— 交互式大模型 CLI 和斜杠命令。 |
| [SERVER.md](../SERVER.md) | `kiln-serve` —— OpenAI 兼容 HTTP API。 |
| [BENCHMARK.md](../BENCHMARK.md) | 实测 tok/s、ms/fps 及复现方法。 |
| [MAINLINE-KERNEL.md](../MAINLINE-KERNEL.md) | 主线 `linux-7.1.3` 基础 + Kiln NPU 补丁集;CI 构建与手动构建。 |
| [RK3568.md](../RK3568.md) | RK3568 / ROCK 3B —— 仅视觉,未上硬件(求人帮测)。 |

## 参与贡献

见 [CONTRIBUTING.md](../../CONTRIBUTING.md)。现在最有价值的贡献是**在 ROCK 4D 以外的板子上测试并反馈**。

## NPU bring-up 内部资料(英文)

- [kernel-patches/README.md](../../kernel-patches/README.md) —— 十个主线 NPU 补丁(0001–0010)的逐条理由。
- [driver/patches/README.md](../../driver/patches/README.md) —— out-of-tree `rknpu` 移植 + 寄存器 dump 调试探针。
