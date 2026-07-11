# 故障排查

先跑:**`sudo kiln-doctor`**。它按本页的分类逐项检查,每项打印一行
`[ OK ] / [FAIL] / [WARN] / [INFO]`。提 [issue](https://github.com/gahingwoo/kiln/issues) 时,
把它的完整输出贴上——这是最有用的信息。

本页把**具体现象或报错原文** → 含义 → 修法一一对应。用 Ctrl-F 搜你看到的那句话。

- [安装与内核](#安装与内核)
- [NPU 驱动与电源](#npu-驱动与电源)
- [模型与版本锁](#模型与版本锁)
- [视觉(分类与检测)](#视觉分类与检测)
- [大模型与对话](#大模型与对话)
- [API 服务](#api-服务)
- [转模型(kiln-convert)](#转模型kiln-convert)
- [Wi-Fi 与网络](#wi-fi-与网络)

---

## 安装与内核

### 板子重启后黑屏 / "什么都没发生"
**预期行为。** 安装是免手动的:板子会**自己重启两次**(共约 10–15 分钟)。第一次重启后,它在
**允许登录之前**离线完成安装,然后再重启一次。两次重启之间板载 Wi-Fi 是**断的**(也是预期——
第二阶段会重建)。**别断电。** 装完在下次登录会看到 `Kiln installed`,或跑 `kiln-doctor`。完整日志:
`/var/log/kiln-phase2.log`。

### 第二阶段失败
`kiln-doctor` 显示 `[FAIL] phase-2 install FAILED`。看日志并重跑(它离线从阶段 1 缓存跑):
```sh
cat /var/log/kiln-phase2.log
sudo bash /opt/kiln/scripts/kiln-install.sh
```

### 每次更新 Kiln 都重装内核并重启
已修复——**内核更新是可选的**。一旦在 Kiln 内核上,普通重跑(或 `kiln-config → System → update`)
只重建驱动 + 运行时,**不动内核**。要主动升级内核:`KILN_CHECK_KERNEL=1 bash kiln-install.sh`。

### `apt` 卡住 / "dpkg was interrupted" / 内核半配置
某个在当前内核上编不过的 DKMS 模块(常见是原版 `aic8800`)会让内核包半配置,从而卡住所有 `apt`。
安装器现在会自动修复;手动的话:
```sh
sudo dpkg --configure -a
sudo dkms status                  # 找到编不过的模块/版本
sudo dkms remove <模块>/<版本> --all
sudo dpkg --configure -a
```

### `no /boot/armbianEnv.txt — this installer targets Armbian`
一条命令安装针对的是 **Armbian**。其他发行版请自己构建内核(见 [MAINLINE-KERNEL.md](../MAINLINE-KERNEL.md))
再用 DKMS 装模块。

---

## NPU 驱动与电源

### `kiln-doctor: [FAIL] rknpu NOT loaded`
NPU 模块没加载:
```sh
sudo modprobe rknpu
sudo dmesg | grep -i rknpu
```
它本应通过 `/etc/modules-load.d/rknpu.conf` 在开机时自动加载。若 `modprobe` 失败,多半是你**不在
Kiln 内核上**,或 DKMS 没装好——跑 `kiln-config → System → 重建 NPU 驱动`。

### `[FAIL] no /dev/dri/renderD* render node`
驱动没绑上 NPU。确认 `rknpu` 已加载且你在 Kiln 内核上,然后**重启**(DTB 的 NPU 节点在开机时绑定)。
应出现 `renderD128` 或 `renderD129`。

### dmesg 里 `failed to get pm runtime for npu0, ret: -110`
经典的**"第一次能跑,第二次推理就挂"**。NPU 电源轨(`vdd_npu_s0`)在板级 DTS 里只标了
`regulator-boot-on`,开机约 30 秒后被关掉;下一次推理读到死轨,把板子卡死。由
`kernel-patches/0010` 的 `regulator-always-on` 修复——它**编进了 Kiln 内核**,所以解法是:
**用 Kiln 内核**(`kiln-doctor` 显示 "running the Kiln patched kernel")。原版/Armbian 内核无法从
模块提供这一修复。别的 RK3576 板子要在**它自己的**板级 DTS 上加同样一行。

### MMU 状态不是 `st=0x19/0x19/0x19/0x19`
RK3576 NPU 是一个设备带**两个 IOMMU / 四个 MMU bank**;主线 `rockchip-iommu` 只驱动一个,于是幼稚
移植把第二个核的地址读成垃圾(`task_counter=0` 超时)。Kiln 驱动使能全部四个 bank 并逐任务刷 TLB。
看不到 `0x19/0x19/0x19/0x19` 就说明你跑的不是 Kiln 的驱动或内核——重装 Kiln 驱动并重启。

### 第一次推理就 `SError` / 卡死
冷启动上电需要 settle 延时 + BIU 复位 + 核 "arm",只有 Kiln 内核补丁提供。这正是**纯主线**内核不够
的原因;用 Kiln 内核(CI 的 `.deb`,或按 [MAINLINE-KERNEL.md](../MAINLINE-KERNEL.md) 自己构建)。

---

## 模型与版本锁

Kiln **不附带**模型——你自备。两个运行时都**版本锁**:模型必须匹配它要跑的运行时。

| 运行时 | 版本 | 模型须用它转 |
|---|---|---|
| `librkllmrt`(大模型) | **1.2.0** | `rkllm-toolkit` **1.2.0** |
| `librknnrt`(视觉) | **2.3.0** | `rknn-toolkit2` **2.3.x** |

### `terminate … std::out_of_range … in rknn_inputs_set`
`.rknn` 是用**错误的 `rknn-toolkit2` 版本**(比如 2.1.0)转的,跟 2.3.0 运行时不匹配。这不是 Kiln
代码的 bug,是版本锁。**用匹配的 toolkit 重转**——最省事的方式会自动锁版本:
```sh
kiln-convert mobilenet          # 或:kiln-convert <你的.onnx>(会装 rknn-toolkit2==2.3.0)
```
`kiln-doctor` 会读 `.rknn` 里嵌的 toolkit 版本并在不匹配时报警。

### `rkllm init failed` / 大模型加载不了
通常是 `.rkllm` 用了**不是 1.2.0** 的 `librkllmrt` 转的(运行时在加载时会校验)。换一个 **1.2.0** 的
`.rkllm`。也检查文件没被截断(scp 传一半)。

### `kiln-doctor: [FAIL] LLM/vision model MISSING`
配置里的路径不存在,`/opt/models` 里也没有可自动发现的。放一个进去,或现构建一个
(`kiln-convert mobilenet`),或在 `kiln-config → Models` 里改路径。

---

## 视觉(分类与检测)

### `kiln-vision: no vision model found`
`/opt/models` 里没有 `.rknn`,配置里也没配。在板上现构建一个:
```sh
sudo kiln-convert mobilenet --set-active     # 分类器
# 或
sudo kiln-convert yolov8n  --set-active      # YOLO 检测器
```

### `kiln-vision` 在某个 YOLO `.rknn` 上崩溃(segfault)
这个 `.rknn` 是 **end2end / NMS 内置** 的导出([1, N, 6] 输出)。rknn-toolkit2 能*转*,但内置的 NMS
算子(TopK / GatherElements)**在 RK3576 NPU 上跑不了——运行时会崩**(同一块板上分类还能跑,这就是
线索)。请**关掉 NMS** 导出,让 Kiln 在 CPU 上做 NMS:
```sh
yolo export model=yolov8n.pt format=onnx nms=False opset=19 imgsz=640
kiln-convert ./yolov8n.onnx --set-active
```
`kiln-convert yolov8n` 本身就会抓一个关了 NMS 的导出。见 [VISION.md](../VISION.md)。

### 检测能跑但类别标签不对(比如 `goldfish`、`cock`)
**框和类别是对的**,但 `[vision] labels` 指向了**ImageNet-1000**(分类用),不是 **COCO-80**(检测用)。
切换:
```sh
sudo kiln-config       # Vision → labels → coco_80_labels.txt(它会主动问你要不要切)
```
`kiln-doctor` 在 `task=detect` 但标签文件超过 200 类时会报警。

### 检测报告 0 个目标 / 落到错误的家族
刚重编过的话,确认二进制里确实有新解码器:
`strings /usr/bin/rknn_mobilenet | grep -c yolo-raw` 应大于 0。`auto` 猜错时用
`[vision] detector = yolov8|yolov5|yolox|yoloraw` 强制指定,并把打印的家族 + 头几个框跟已知图对一下。

---

## 大模型与对话

### `kiln-chat: no LLM model available`
把一个 `*-rk3576-w4a16.rkllm`(匹配 `librkllmrt` 1.2.0)放进 `/opt/models`;`kiln-chat` 会自动发现那里
任意 `.rkllm`。(大模型没有板上转换——它是自备的,不像视觉。)

### 模型反复重复 / 啰嗦 / 停不下来
调高 `repeat_penalty`(比如 `1.3`),小的 1–1.5B 模型上 `top_k` 保持 `1`(`kiln-config → LLM`,或
对话里 `/help` 现场调)。生成会在模型的 EOS / 角色停止符处停;离谱的 system prompt 仍可能带偏小模型——
`/clear` 或 `/new` 重置。

### 中文 / 非 ASCII 输入编辑不正常
那需要构建时有 `readline`(光标 + UTF-8)。装 `libreadline-dev` 后重编(安装器会带上)。没有它时
`kiln-chat` 退化成普通读行。

---

## API 服务

### `POST /v1/chat/completions` 返回 `503 no LLM on this box`
`kiln-serve` 以**仅视觉**模式启动了(没加载 `.rkllm`)。加个大模型再重启:
`kiln-config → Server → service → restart`。

### Open WebUI / 客户端连不上
- 监听所有网卡:`[server] host = 0.0.0.0`(不是 `127.0.0.1`),然后重启。
- 确认在跑:`curl http://<板子IP>:8080/v1/models`。
- 防火墙:确保端口(默认 `8080`)在局域网可达。
- 完整的 Open WebUI / LangChain / `openai` 配置见 [Open WebUI 教程](OPENWEBUI.md)。

### `failed to bind <host>:<port>`
端口被别的进程占了,或权限不够。改 `[server] port`,或停掉占用者
(`sudo ss -ltnp | grep :8080`)。

---

## 转模型(kiln-convert)

### `couldn't install rknn-toolkit2==2.3.0 from PyPI`
对应的 aarch64 wheel 可能不在 PyPI 上。去
[`airockchip/rknn-toolkit2`](https://github.com/airockchip/rknn-toolkit2)(`rknn-toolkit2/packages/`)
拿,再让 `kiln-convert` 用它——版本必须匹配运行时:
```sh
kiln-convert --wheel /路径/rknn_toolkit2-2.3.0-*aarch64.whl <源>
```

### `python3-venv not found`
`sudo apt install python3-venv`(安装器通常会装)。第一次转换还会下载几百 MB 的 toolkit——这是预期,
而且只一次。

### 转换时 `ModuleNotFoundError: pkg_resources`
老的 setuptools 坑;`kiln-convert` 在它的 venv 里锁了 `setuptools<81`。若你手动建的 venv,
`pip install 'setuptools<81'`。

---

## Wi-Fi 与网络

### 装完没有 Wi-Fi
切到主线内核会丢掉 out-of-tree 的 `aic8800` 驱动;Kiln 在第二阶段重建一个打过补丁的。若还是没建起来,
**用网线**(总是能用),并:
```sh
sudo dkms status | grep aic8800
sudo bash /opt/kiln/scripts/kiln-install.sh   # 重跑 Wi-Fi 构建
```
Wi-Fi 对 Kiln 做的一切都是可选的——NPU 不需要它。

### 两次安装重启**之间**没有 Wi-Fi
预期且临时——第二阶段全程离线,并在你登录前重建好 Wi-Fi。

---

## 还是卡住?

开一个 [issue](https://github.com/gahingwoo/kiln/issues),附上:
1. `sudo kiln-doctor` 的完整输出,
2. `sudo dmesg | grep -iE 'rknpu|npu|iommu'`,
3. 你跑了什么、期望什么。成功、失败、dmesg 都欢迎——**尤其是 ROCK 4D 以外的板子**,那是目前唯一
   测过的。
