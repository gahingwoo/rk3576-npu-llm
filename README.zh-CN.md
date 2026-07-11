# Kiln —— 在 RK3576 NPU 上跑离线本地 AI(大模型 + 视觉)

[English](README.md) · **简体中文**

**一台私有、离线的 AI 助手 + 图像识别,一条命令装到你的 Radxa ROCK 4D 上。** 在板子的
**NPU** 上跟本地大模型对话、给图片分类或做目标检测——数据不出设备、无需联网、不用 API key。
它还暴露成 **OpenAI 兼容的 API**,所以你可以直接把 **Open WebUI**(ChatGPT 式的网页)、
**LangChain** 或任何 OpenAI 客户端指向这块板子。

```sh
curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
# 自动重启,然后:`kiln` 打开菜单、`kiln-chat` 对话、`kiln-serve` 开 API
```

**它是怎么做到的(难点所在)。** 厂商的 RKLLM/RKNN NPU 软件栈通常只能跑在 Rockchip 老旧的
6.1 BSP 内核上。Kiln 让同一套软件栈跑在**干净的主线 `linux-7.1.3`** 内核上:把厂商 GPL
`rknpu` 驱动**以 out-of-tree 方式**编译,再加一小组针对性的内核补丁(时钟 / 电源域 / 双 IOMMU
修复)——这些是内核代码,光靠模块补不上。它是"基于主线",不是"纯主线",这些补丁是必须的
(见下方 *为什么需要内核补丁*)。

> **姊妹项目:** [`linux-rk3576-npu`](https://github.com/gahingwoo/linux-rk3576-npu) 是同一
> 目标的另一半——从零写的**开源** RK3576 NPU 驱动(rocket / mesa)。两条路殊途同归:本仓库
> 把厂商栈搬上主线内核;那个从零造开源驱动。

## 这适合你吗?

- **你有** 一块跑 **Armbian** 的 Radxa **ROCK 4D(RK3576)**——**这是 Kiln 唯一实测过的硬件**。
  模块、运行时和工具本身与板子无关(NPU 是同一颗硅),所以别的 RK3576 板子**理论上**只要其板级
  DTB 带上 NPU 节点 + `vdd_npu` 稳压器修复就能用——但**未经测试,欢迎来帮测**。**RK3568**
  (ROCK 3B,仅视觉)有初步支持,但**同样没上过硬件**。
- **你想要** 在**主线**内核(而非厂商 6.1 BSP)上,在 NPU 上做本地**大模型 + 视觉**推理。
- **你会得到** 一条命令 → 然后 `kiln` 打开菜单(或直接跑 `kiln-chat`、`kiln-vision`、
  `kiln-serve`——OpenAI 兼容 API);外加 `kiln-config`(TUI)、`kiln-convert`(板上转模型)、
  `kiln-doctor`(健康检查)。
- **不适合你** 如果你要留在厂商 **6.1 BSP** 内核上。视觉主要是**图像分类**(MobileNet);
  **目标检测(YOLO)**能用但较新、测的模型少——见 [`docs/VISION.md`](docs/VISION.md)。

## 现状

**在真实硬件上能跑**(ROCK 4D,RK3576)。两套栈都在 NPU 上:`kiln-chat` 多轮对话——
**Qwen2.5-1.5B(约 9 tok/s)或 Llama-3.2-1B(约 13 tok/s)**,`/model` 现场切换——
`kiln-vision` 给图片分类(**约 6 ms,约 169 fps**)。

> **实测硬件:** 仅**一块跑 Armbian 的 Radxa ROCK 4D(RK3576)**,别无其他。其他 RK3576 板子和
> RK3568(ROCK 3B)是*实现了但没上过硬件*——是"应该能跑",不是"确认能跑"。来自其他板子的
> 反馈(在 issue 里贴 `kiln-doctor` 输出)是最有价值的贡献。

## 为什么需要内核补丁

**纯主线**(或 Armbian)内核**不够**——有几处 RK3576 NPU 修复是内核代码,out-of-tree 模块
和 DT overlay 都补不上:

- **一个设备,两个 IOMMU。** 幼稚的移植只会得到 `task_counter=0` 超时:NPU 是一个设备带两个
  IOMMU,而主线 `rockchip-iommu` 只驱动其中一个,第二个核把 regcmd 的 IOVA 当成裸物理地址
  读 → 全是垃圾。Kiln 从驱动里使能全部四个 MMU bank,并逐任务刷 TLB。
- **电源域。** 冷启动 NPU 上电需要一个 settle 延时、一次 BIU 复位、完整的域时钟设置、还有一次
  核 "arm",否则第一次读寄存器就 SError。而且 ROCK 4D 板级 DTS 把 NPU 电源轨 `vdd_npu_s0`
  只标了 `regulator-boot-on`,开机约 30 秒后它被关掉——于是**第二次**推理读到一条死轨,把板子
  卡死。一行 `regulator-always-on`(`kernel-patches/0010`)修好这个"跑一次就挂"的 bug。
  (这条是每板一份:别的 RK3576 板子的 DTB 得在自己的 NPU 轨上加同样一行;驱动/运行时是共用的。)

完整说明见 [`kernel-patches/README.md`](kernel-patches/README.md)(十个补丁的逐条理由)和
[`driver/patches/README.md`](driver/patches/README.md)(双 IOMMU / MMU bank 机制)。

## 安装

**在 Armbian 上** —— 一条命令,然后走开。它会预下载所有东西、装上 Kiln 主线内核,并**自己重启
两次(约 10–15 分钟)**完成安装、进入就绪系统。**这是正常的,别断电。** 两次重启之间板载 Wi-Fi
是断的(预期如此;第二阶段离线完成、不需要网)。装完你会在登录时看到 "Kiln installed",或跑
`kiln-doctor`。详见 [`docs/ARMBIAN.md`](docs/ARMBIAN.md) / 中文 [安装指南](docs/zh/INSTALL.md)。

```sh
curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
```

**刷卡镜像(刷完即用)** —— 有预构建镜像时最省事:`dd` 到 SD 卡开机就行,免去 `curl|bash`、
免去两次重启、免去 Wi-Fi 重建。预构建镜像(有经硬件验证的版本时)在
[Releases](https://github.com/gahingwoo/kiln/releases) 页。

## 模型

Kiln **不附带**任何模型——你自备(和厂商栈一样)。但你不需要 x86 机器也不用 scp:
**`kiln-convert`** 在板子上现转 `.rknn`(`kiln-convert mobilenet` 分类器、`kiln-convert yolov8n`
检测器,或你自己的 ONNX / URL),并把 `rknn-toolkit2` 锁到与运行时匹配的版本,不会版本对不上。

- **大模型** —— 把一个 `*-rk3576-w4a16.rkllm`(须匹配 `librkllmrt` **1.2.0**)放进 `/opt/models`;
  `kiln-chat` 会自动发现那里的任意 `.rkllm`。
- **视觉** —— `kiln-convert mobilenet` 在板上现构建一个分类器 `.rknn`(或 `kiln-convert yolov8n`
  一个 YOLO 检测器);它把 `rknn-toolkit2` 锁到 `librknnrt` **2.3.x** 运行时。也可在 x86 上转好后
  丢进 `/opt/models`。见 [`docs/VISION.md`](docs/VISION.md)。

## 出问题了?

先跑 `sudo kiln-doctor`,再到 **[中文故障排查](docs/zh/TROUBLESHOOTING.md)** 里 Ctrl-F 搜你看到的
报错。想在板子上要一个 ChatGPT 式网页?见 **[中文 Open WebUI 教程](docs/zh/OPENWEBUI.md)**。

## 文档

- **中文文档索引:** [`docs/zh/README.md`](docs/zh/README.md)
- 英文完整文档:[`docs/README.md`](docs/README.md)

## 许可证

GPL-2.0(见 `LICENSE`)。Kiln 包装并编译 GPL-2.0 的厂商 `rknpu` 驱动,其源码是**抓取、非再分发**。
`librkllmrt` / `librknnrt` 运行时是 Rockchip 的闭源件,Kiln 不包含它们。模型权重各自单独授权,亦不包含。
