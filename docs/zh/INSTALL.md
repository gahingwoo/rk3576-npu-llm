# 安装 Kiln

英文版:[ARMBIAN.md](../ARMBIAN.md)。

有两条路:**在 Armbian 上一条命令装**(最常见),或 **`dd` 刷卡镜像**(有预构建镜像时最省事)。

## A. Armbian 一条命令(免手动)

前提:一块跑 **Armbian** 的 Radxa **ROCK 4D**(RK3576)。

```sh
curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
```

它是**免手动**的:板子会**自己重启两次(共约 10–15 分钟)**进入就绪系统——第一次重启后在
**登录之前**离线完成安装,然后再重启一次。**这是正常的,别断电。** 两次重启之间板载 Wi-Fi 是断的
(预期如此——第二阶段会重建它)。装完登录时会看到 "Kiln installed",或跑 `kiln-doctor` 确认。
完整日志在 `/var/log/kiln-phase2.log`。

不想把装内核的脚本直接管道进 shell?先下载、看一眼、再跑——它本就该被审阅:

```sh
curl -fsSLO https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh
less kiln-install.sh          # 看它干什么
bash  kiln-install.sh          # 再运行
```

**想自己掌控重启?** `KILN_MANUAL=1 bash kiln-install.sh` 手动分两阶段(它会告诉你何时重启、
何时再跑一遍),不自动接管。

### 两阶段在做什么

- **阶段 1(在原内核上,有网):** 把第二阶段需要的一切预下载到磁盘缓存(闭源运行时 + demo 源码、
  厂商 GPL 驱动源码、mobilenet 测试素材、aic8800 Wi-Fi 源码),**然后**装上 Kiln 主线 7.1.3 内核,
  并把 Armbian 的 u-boot 指过去。装完自动切到第二阶段。
- **阶段 2(在打过补丁的内核上):** 用 DKMS 构建厂商 `rknpu` 驱动、装 RKLLM/RKNN 运行时和
  demo,再重建板载 Wi-Fi(打过补丁的 aic8800)。**全程离线**从阶段 1 的缓存来(打补丁的内核在
  第二阶段重建 Wi-Fi 之前没有网——这曾是老的安装死锁)。

### 内核更新是可选的

一旦你在 Kiln 内核上,普通的重跑(或 `kiln-config → System → update`)**只**重建驱动 + 运行时,
**不动内核**。想主动升级内核:`KILN_CHECK_KERNEL=1 bash kiln-install.sh`(仅当发布了更新版本才装)
或 `KILN_FORCE_KERNEL=1`(总是重装)。

### 各种开关(细粒度重跑)

| 环境变量 | 作用 |
|---|---|
| `KILN_MANUAL=1` | 不装自动接管服务、不自动重启;你自己重启并再跑一遍 |
| `KILN_SKIP_KERNEL=1` | 跳过阶段 1 的内核检查/安装 |
| `KILN_SKIP_DRIVER=1` | 不重建 `rknpu` DKMS 模块 |
| `KILN_SKIP_RUNTIMES=1` | 不重新抓运行时、不重编 demo(慢、吃网的那部分) |
| `KILN_CHECK_KERNEL=1` / `KILN_FORCE_KERNEL=1` | 检查 / 强制内核更新 |

## B. 刷卡镜像(刷完即用)

有预构建镜像时,这是最省事的路:`dd` 到 SD 卡开机就行,免去 `curl|bash`、免去两次重启、免去
Wi-Fi 重建。驱动、运行时和 `kiln-*` 工具都已装好(模型仍需你自备)。

预构建镜像(有经硬件验证的版本时)在
[Releases](https://github.com/gahingwoo/kiln/releases) 页:

```sh
# Linux(把 /dev/sdX 换成你的卡;这会清空它):
xz -dc kiln-rock-4d-*.img.xz | sudo dd of=/dev/sdX bs=8M status=progress conv=fsync
# 或用 Raspberry Pi Imager / balenaEtcher 直接选 .img.xz
```

先校验下载:`sha256sum -c kiln-rock-4d-*.img.xz.sha256`。

自己构建镜像见 [buildroot/README.md](../../buildroot/README.md)(需要外部参考树,是维护者路径)。

## 装完之后

```sh
kiln            # 菜单:对话 / 视觉 / 模型 / 服务 / 设置 / 诊断
kiln-doctor     # 健康检查(提 issue 时把它的输出贴上)
kiln-convert mobilenet --set-active   # 在板上现构建一个视觉分类器
kiln-vision /opt/models/test.jpg      # 跑一下
kiln-chat       # 需要 /opt/models 里有一个 *.rkllm(自己 scp 进去)
```

出问题?见 [故障排查](TROUBLESHOOTING.md)。
