# Kiln buildroot external (ROCK 4D, RK3576 NPU)

Builds a flashable `sdcard.img`: mainline kernel + out-of-tree vendor `rknpu.ko`
(v0.9.8, DRM_GEM) + version-locked `librkllmrt` v1.2.0 + `librknnrt` v2.3.0, with
the rocket driver turned off so only the vendor rknpu binds the NPU.

## What is validated vs what you run

Validated on this dev machine (not just written):
- `rknpu.ko` COMPILES against the target kernel (linux-next 7.1.0 / next-20260527,
  arm64) in DRM_GEM mode via `driver/apply-mainline-shims.sh` (12 idempotent shims,
  all found by actually compiling). Produces a 510 KB `.ko`, `vermagic` matching the
  target kernel, `import_ns: DMA_BUF`, no `rk_dma_heap` symbols.
- The vendor `rockchip,rk3576-rknpu` node + IOMMUs are added to the in-tree
  `rockchip/rk3576-rock-4d` dtb by `kernel-patches/0004` (with a CRU fixed-rate NPU
  clock); the KERNEL_SRC tree must have `kernel-patches/` 0001-0010 applied.
- `buildroot/fetch-runtimes.sh` fetches librkllmrt v1.2.0 (build 2025-04-08) and
  librknnrt v2.3.0 into `dl/`.

You run (needs the ROCK 4D u-boot binaries + a writable output dir; the full
buildroot build compiles its own toolchain + the kernel, ~40-90 min first run):

```
# edit the 4 paths at the top if yours differ, then:
./buildroot/build-image.sh
# -> br-out/images/sdcard.img
```

`build-image.sh` reuses the rocket tree's buildroot source and the linux-next tree
that already carries the RK3576 IOMMU/PD/clock platform patches. It changes nothing
under /home/parallels: rocket is disabled by `npu.fragment`, and the rocket NPU DT
nodes are removed at the DT level by the Kiln board DTS (`CUSTOM_DTS_PATH`).

## Files

- `configs/kiln_rock4d_713_defconfig` — Kiln defconfig (mainline 7.1.3, rocket off, post-build).
- `npu.fragment` — kernel fragment: `# CONFIG_DRM_ACCEL_ROCKET is not set` + deps.
- `board/rock4d/post-build.sh` — builds+installs `rknpu.ko` against the built kernel,
  installs the runtimes, installs an `S89rknpu` init that `modprobe rknpu` at boot.
- `board/rock4d/post-image.sh` — packs `sdcard.img` (16 MiB u-boot + FAT32 boot +
  ext4 rootfs) with the Kiln DTB.
- `fetch-runtimes.sh` — fetches the version-locked closed `.so` blobs into `dl/`.
- `build-image.sh` — orchestrator (set 4 paths, one command).
- `dl/` — build-time fetch cache (closed `.so` + `base.config`); not source, do not commit.

## The model (668 MB) is not baked in by default

`rootfs` is 768 MiB (libs + `rknpu.ko` + headroom). The 668 MB
`TinyLlama-1.1B-Chat-v1.0-rk3576-w4a16.rkllm` is left out to keep the image small and
the rebuild fast; `scp` it to `/opt/models` on the board .
To bake it in instead: `KILN_BAKE_MODEL=1 ./buildroot/build-image.sh` and raise
`BR2_TARGET_ROOTFS_EXT2_SIZE` to ~1536M in the defconfig.
