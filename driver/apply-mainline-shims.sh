#!/usr/bin/env bash
# Apply Kiln's mainline port + RK3576 NPU-execution fixes to the fetched vendor
# rknpu v0.9.8 source. Run automatically by fetch-vendor-driver.sh.
#
# This applies ONE deterministic patch (patches/kiln-mainline.patch) against the
# pinned pristine source (armbian linux-rockchip rk-6.1-rkr6.1 drivers/rknpu).
# It does NOT commit the vendor GPL driver: fetch-vendor-driver.sh pulls the full
# source, and only Kiln's modifications (this patch, with minimal context) live
# in the repo. GPL-2.0, same as the driver it patches.
#
# The patch has two layers:
#   1. mainline (6.1 -> 7.x) BUILD shims -- the API drift that stops the vendor
#      driver compiling on a modern kernel: drop drm_driver .date, gate
#      .gem_prime_mmap < 6.6, MODULE_IMPORT_NS string literal, hrtimer_setup,
#      void platform .remove, pfn.h/vmalloc.h, iommu_map / iommu_map_sg gfp arg,
#      sg_dma_is_bus_address rename, devfreq no-op callbacks, and the
#      iommu_dma_cookie layout (iovad now at offset 0).
#   2. RK3576 NPU-EXECUTION fixes -- what makes matmul actually run on mainline
#      (without these the vendor driver loads but every job times out,
#      task_counter=0). See patches/README.md for the why of each:
#        - rknpu_mmu_enable_all(): enable ALL four MMU banks incl. the "orphan"
#          MMU that mainline rockchip-iommu never attaches (single-primary model);
#        - per-job MMU TLB ZAP so the orphan MMU cannot serve stale translations;
#        - force-resume the platform IOMMU devices on every power-on;
#        - re-enable the MMUs after soft_reset;
#        - pin a clean 594 MHz NPU clock (GPLL/2) with devfreq off;
#        - 10-min power-put delay to keep the NPU warm across a chat turn.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RKNPU="$HERE/rknpu"
PATCH="$HERE/patches/kiln-mainline.patch"

[ -d "$RKNPU" ] || { echo "[kiln] ERROR: $RKNPU not found. Run fetch-vendor-driver.sh first." >&2; exit 1; }
[ -f "$PATCH" ] || { echo "[kiln] ERROR: $PATCH missing." >&2; exit 1; }

# Idempotent: a marker unique to the patch means it is already applied.
if grep -q "rknpu_mmu_enable_all" "$RKNPU/rknpu_drv.c" 2>/dev/null; then
	echo "[kiln] shims already applied (rknpu_mmu_enable_all present); nothing to do."
	exit 0
fi

echo "[kiln] applying kiln-mainline.patch to the fetched rknpu source ..."
if ! patch -p0 -d "$HERE" --no-backup-if-mismatch < "$PATCH"; then
	echo "[kiln] ERROR: patch did not apply cleanly. The fetched vendor source has" >&2
	echo "        probably drifted from the pinned rk-6.1-rkr6.1 v0.9.8 baseline." >&2
	echo "        Re-pin fetch-vendor-driver.sh or regenerate patches/kiln-mainline.patch." >&2
	exit 1
fi

# Supplementary shim: deassert the RKNN core resets in rknpu_power_on(). The
# mainline U-Boot/ATF on ROCK 4D leaves the NPU core resets ASSERTED (the vendor
# BSP loader left them deasserted), so on a mainline boot the NPU core registers
# do not respond to READS -- rknpu_get_hw_version() (base+0x0) async-SErrors and
# panics, while state_init()'s posted WRITES silently succeed. Deassert them once
# the domain is powered+clocked (reset.h comes in via rknpu_reset.h; srsts are
# populated by rknpu_reset_get() at probe). Fold into kiln-mainline.patch later.
if ! grep -q 'KILN: bring the NPU cores out of reset' "$RKNPU/rknpu_drv.c"; then
	perl -0pi -e 's{(\n\tif \(rknpu_dev->config->state_init != NULL\))}{\n\t/*\n\t * KILN: bring the NPU cores out of reset -- the mainline bootloader leaves the\n\t * RKNN core resets asserted, so NPU core register reads (GET_HW_VERSION at\n\t * base+0x0) async-SError until deasserted. Domain is powered + clocked here.\n\t */\n\t\{\n\t\tint __ri;\n\t\tfor (__ri = 0; __ri < rknpu_dev->num_srsts; __ri++)\n\t\t\treset_control_deassert(rknpu_dev->srsts[__ri]);\n\t\}\n$1}' \
		"$RKNPU/rknpu_drv.c" \
		&& echo "[kiln] applied NPU-core reset-deassert shim."
fi

# Supplementary shim: never touch NPU registers when power-on failed. The vendor
# rknpu_ioctl() ignores rknpu_power_get()'s return value and runs the action
# regardless. On mainline a failed NPU power-domain transition (e.g. the NPUTOP
# mem_reset chain-status poll timing out -> "failed to get pm runtime for npu0,
# ret: -110") leaves the cores UNPOWERED, and the very next thing an
# RKNPU_GET_HW_VERSION ioctl does is read base+0x0 -> async SError that panics the
# WHOLE BOARD. Check the return and bail cleanly so a bad power-on becomes a plain
# "rkllm init failed" instead of a machine-check. Fold into kiln-mainline.patch later.
if ! grep -q 'KILN: never touch NPU registers if power-on failed' "$RKNPU/rknpu_drv.c"; then
	perl -0pi -e 's!\n\trknpu_power_get\(rknpu_dev\);\n\n\tswitch \(_IOC_NR\(cmd\)\) \{!\n\tret = rknpu_power_get(rknpu_dev);\n\tif (ret) {\n\t\t/*\n\t\t * KILN: never touch NPU registers if power-on failed -- a failed NPU\n\t\t * power-domain transition (NPUTOP mem_reset chain timeout, -110) leaves\n\t\t * the cores unpowered; reading GET_HW_VERSION (base+0x0) then raises an\n\t\t * async SError that panics the whole board. Bail cleanly instead.\n\t\t */\n\t\tLOG_ERROR("rknpu_power_get failed (%d); skip ioctl to avoid SError\\n", (int)ret);\n\t\tatomic_dec_if_positive(&rknpu_dev->power_refcount);\n\t\treturn ret;\n\t}\n\n\tswitch (_IOC_NR(cmd)) {!' \
		"$RKNPU/rknpu_drv.c" \
		&& echo "[kiln] applied power-on-failure bail shim (no SError on -110)."
fi

# NOTE: no driver power-keepalive hack. An earlier no-op-rknpu_power_off() shim was
# WRONG (unbalanced pm_runtime/regulator refcounts -> next power-on wedged the PMU
# path, `cpu _set_opp_voltage ... -110` RCU stall), and a sysfs "keep resident"
# (power/control=on) does not hold the driver's per-domain genpd votes anyway. The
# real fix is the kernel patch kernel-patches/0010 (regulator-always-on on
# vdd_npu_s0): the NPU rail stays up, so every power-on lands on a live core.

echo "[kiln] driver/rknpu is patched for mainline + RK3576 NPU execution."
echo "[kiln] build with: make KDIR=<your-kernel-build>"
