# Kiln kernel patches (RK3576 NPU)

**Honest correction to an earlier claim.** Kiln was described as running the
vendor `rknpu` stack on a mainline kernel with *no kernel patches* — everything
in the out-of-tree module plus a DT overlay. That is **not true for the RK3576
NPU power domain.** The module and the overlay cannot touch the built-in
`drivers/pmdomain/rockchip/pm-domains.c`, and without a fix there the NPU power
domain SErrors while the NoC is still settling after de-idle — on ROCK 4D that
is a **hard system freeze** during the first NPU inference (and a clean
`failed to get pm runtime for npu0, ret: -110` if the domain is cold when the
driver loads late).

The buildroot `linux-next` 7.1 image Kiln was validated on already carried these
fixes in its kernel tree, so the gap was invisible until Kiln was run on a stock
Armbian kernel. To run the NPU on Armbian you therefore need a kernel built with
(at least) the first patch below. These are **built-in driver fixes** — they
cannot be shipped as a module.

## Patches

| file | subsystem | why Kiln needs it | required? |
|---|---|---|---|
| `0001-pmdomain-rockchip-npu-settle-delay.patch` | `pmdomain/rockchip` | 15 µs settle delay for the NPUTOP/NPU0/NPU1 domains between de-idle and QoS restore. **This is the fix for the inference freeze / `-110`.** Self-contained; no DT change. | **yes — the fatal one** |
| `0002-pmdomain-rockchip-cycle-pd-resets.patch` | `pmdomain/rockchip` | Optional per-domain reset pulse on power-on for domains whose bus interface needs a reset edge. Only fires if the power-domain DT node carries `resets` (needs a matching DT change). | optional |
| `0003-iommu-rockchip-take-all-dt-clocks.patch` | `iommu/rockchip` | **Driver-only** (split from its old DT hunk): take every DT clock via `devm_clk_bulk_get_all()` instead of the named `aclk`/`iface` pair, so the NPU MMU's extra CBUF/DSU gates run during `rk_iommu_resume` (mainline enables only aclk+iface → the MMU DTE write is silently dropped). Kiln's module also programs the DTE directly, so inference works without it, but this is the correct kernel-side fix. | recommended |
| `0004-arm64-dts-rk3576-add-vendor-rknpu-node.patch` | `arm64: dts` | Adds the vendor-shaped `npu@27700000` + two v2 IOMMUs to mainline `rk3576.dtsi` and enables it on ROCK 4D with `vdd_npu_s0`. Mainline has **no** NPU compute node (its accel/rocket path uses a different `rknn_core` layout), so this is what the vendor `rknpu` driver binds — the in-tree equivalent of the Armbian DT overlay. | **yes for a mainline build** |

For a **mainline** build apply **0001 + 0003 + 0004** (0002 optional). For the
Armbian build the DT node comes from the overlay instead, so only **0001** is
strictly needed there.

## Provenance

Authored by Jiaxing Hu (`huhuvmb88`) during the RK3576 NPU bring-up. Verified to
apply to **mainline 7.1.3**: 0001 clean, 0003 clean (driver-only), 0004 clean and
compiles into a valid `rk3576-rock-4d.dtb`. They also apply to Armbian **edge**
7.1 (same base). They are **not upstream** — stock mainline / stock Armbian of any
version lacks them, which is why moving to a newer kernel alone does not help.

## Upstreaming status (honest — not yet submitted)

These are carried here to make the NPU work today; they are **not** LKML-ready as
written. Known review points before submission:

- **0001** — the 15 µs is empirical (it mirrors the vendor kernel's NPUTOP
  `delay_us`); a maintainer will want the delay tied to a documented NoC/settle
  timing, not "the vendor does it", and may ask for it as a DT property rather
  than hard-coded. The `udelay` sits in the genpd power path, so it must stay
  short.
- **0003** — the DT and driver changes are now split (this is the driver half;
  the NPU MMU node with the full clock set lives in 0004). Reviewers will scrutinise
  the `devm_clk_bulk_get_all()` `err == -ENOENT || err == 0` boundary.
- **0002** — optional; needs a matching `dt-bindings` addition for the
  power-domain `resets` and only fires when the DT provides them.
- **0004** — board/SoC DT; would go via the Rockchip DT tree, separate from the
  driver patches, and depends on the vendor `rknpu` binding being acceptable
  upstream (mainline's own NPU path is the open `accel/rocket` driver).

The long-term fix is to land 0001 (and 0003) in mainline so a **stock** kernel
runs the NPU with no rebuild.

## Applying

The mainline kernel build (see `../MAINLINE-KERNEL.md`) applies these with
`patch -p1` (or `git am`) on a `linux-7.1.3` tree; the Armbian build
(`../ARMBIAN-KERNEL.md`) drops 0001 into the framework's `userpatches/`. They are
ordinary `git format-patch` output.
