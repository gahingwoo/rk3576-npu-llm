#!/bin/sh
# ---------------------------------------------------------------------------
# env-trace.sh - same-kernel vendor-vs-rocket driver-ENVIRONMENT diff.
# POSIX sh (busybox-safe); baked into the Kiln image as /usr/bin/kiln-env-trace.
#
# Supersedes blindspot-trace.sh's cold-vs-warm approach for the rocket wall.
# Ground truth (rocket FINDINGS.md:705): the vendor's OWN captured regcmd bytes,
# replayed through the rocket driver, ALSO wall in task_number=N mode. So the
# command stream / payload is exonerated -- the wall is the rocket driver's
# task_number=N EXECUTION ENVIRONMENT: clocks/PVTPLL, genpd power, rk_iommu,
# soft-reset, PC write ordering -- everything the driver sets up AROUND the
# byte-identical submit.
#
# The old writel/clock/iommu audit compared vendor-on-6.1-BSP vs rocket-on-
# mainline: every environment difference was confounded by "different kernel."
# Kiln removes that confound -- the vendor rknpu.ko now runs on the SAME mainline
# kernel as rocket. So a vendor-vs-rocket environment diff is finally CLEAN
# (same clk driver, same genpd, same rk_iommu). The vendor MACs EVERY task in a
# chained submit; rocket only the first. On one kernel, that difference must be
# in the driver environment -- and these built-in tracepoints catch it, no patch.
#
# COVERAGE (built-in tracepoints, catch the framework calls):
#   regmap_reg_write  -> any GRF/CRU/PMU/PVTPLL syscon write that goes via regmap
#   clk_set_rate/enable -> NPU/PVTPLL clock rate + gate changes (PVTPLL's effect)
#   power_domain_target -> NPU power-domain on/off transitions
#   iommu map/unmap/attach -> rk_iommu setup around the submit
# NOT covered: a DIRECT ioremap+writel (e.g. PVTPLL if it bypasses regmap, or the
#   NPU block itself -- already audited byte-identical). If this diff comes back
#   IDENTICAL, that is the signal to escalate to wtrace on rknpu.ko (the fallback)
#   or to conclude the arm is below software (RTL/firmware) -- an honest negative.
#
# USAGE -- run ONCE per stack, same board, as root, then diff the two outputs:
#   ./env-trace.sh kiln                              # -> /tmp/env-kiln.txt
#   ./env-trace.sh rocket -- <your npu workload...>  # -> /tmp/env-rocket.txt
#   # then, with both files on ONE host (needs GNU coreutils comm):
#   comm -13 <(sort -u /tmp/env-rocket.txt) <(sort -u /tmp/env-kiln.txt)  # vendor-ONLY
#   comm -23 <(sort -u /tmp/env-rocket.txt) <(sort -u /tmp/env-kiln.txt)  # rocket-ONLY
#
# Trace is taken WARM (a throwaway inference first) so the one-time cold power-on
# (genpd bring-up + vdd_npu + QoS restore, already known common to both) does not
# drown out the per-submit environment activity that actually differs.
# ---------------------------------------------------------------------------
set -eu

LABEL="${1:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo stack)}"
[ "$#" -ge 1 ] && shift || true
# an optional explicit workload command follows a `--`; the rest of "$@" is it
if [ "${1:-}" = "--" ]; then shift; fi

# Persist captures on the rootfs (NOT /tmp -- tmpfs is wiped by the power-cycle
# between kiln and rocket modes, so /tmp files never coexist to be diffed).
OUTDIR="${KILN_ENV_DIR:-/root/kiln-env}"
mkdir -p "$OUTDIR" 2>/dev/null || true

# CPU-cluster DVFS clocks are per-run noise (the governor picks different points);
# drop them from the diff so only the NPU-relevant environment remains.
NOISE='scmi_armclk|scmi_armclkl|scmi_armclkb'

# Sub-command:  kiln-env-trace diff  -> compare the two persisted captures on the
# board (busybox has sort+awk but no comm). Prints vendor-only (in kiln, not
# rocket = the arm suspect) and rocket-only writes.
if [ "$LABEL" = "diff" ]; then
	A="$OUTDIR/env-kiln.txt"; B="$OUTDIR/env-rocket.txt"
	for f in "$A" "$B"; do
		[ -f "$f" ] || { echo "missing $f -- capture both modes first:"; \
			echo "  kiln-env-trace kiln   (reboot)   kiln-env-trace rocket -- kiln-rocket-run"; exit 1; }
	done
	grep -avE "$NOISE" "$A" | sort -u > "$OUTDIR/.a"
	grep -avE "$NOISE" "$B" | sort -u > "$OUTDIR/.b"
	echo "===== VENDOR(kiln)-only env writes (in kiln, NOT rocket) = the arm suspect ====="
	awk 'NR==FNR{s[$0];next} !($0 in s)' "$OUTDIR/.b" "$OUTDIR/.a"
	echo
	echo "===== ROCKET-only env writes (rocket does, vendor doesn't) ====="
	awk 'NR==FNR{s[$0];next} !($0 in s)' "$OUTDIR/.a" "$OUTDIR/.b"
	rm -f "$OUTDIR/.a" "$OUTDIR/.b"
	exit 0
fi

T=/sys/kernel/tracing
[ -d "$T/events" ] || mount -t tracefs nodev "$T" 2>/dev/null || true
if [ ! -d "$T/events" ]; then
	T=/sys/kernel/debug/tracing
	mount -t debugfs nodev /sys/kernel/debug 2>/dev/null || true
fi
[ -d "$T/events" ] || {
	echo "ftrace not available. grep -w tracefs /proc/filesystems ; kernel needs CONFIG_FTRACE/CONFIG_TRACING"
	exit 1
}

SOC="$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null | grep -oE 'rk35[0-9][0-9]' | head -1 || true)"
MODEL_RKNN="/opt/models/mobilenetv2-12_${SOC:-rk3576}.rknn"
IMG="/opt/models/test.jpg"

run_infer() {  # runs the explicit "$@" workload if given, else auto-detects one.
	# An explicit workload's exit status PROPAGATES (so a broken rocket workload --
	# e.g. rocket didn't bind, no /dev/accel/accel0 -- aborts loudly instead of
	# silently tracing nothing). Auto-detected launchers stay tolerant.
	if [ "$#" -gt 0 ]; then "$@" >/dev/null 2>&1; return $?
	elif command -v kiln-vision    >/dev/null 2>&1; then kiln-vision    "$IMG" >/dev/null 2>&1 || true
	elif command -v rknn_mobilenet >/dev/null 2>&1; then rknn_mobilenet "$MODEL_RKNN" "$IMG" >/dev/null 2>&1 || true
	else echo "  (no workload found -- pass one:  $0 $LABEL -- <cmd>)"; return 1; fi
}

# enable a tracepoint only if it exists on this kernel (avoids a noisy redirect
# error for events not built in, e.g. power_domain_target on some configs).
en() { [ -e "$T/events/$1/enable" ] && echo 1 > "$T/events/$1/enable" 2>/dev/null || true; }
arm_events() {
	echo nop > "$T/current_tracer"
	echo 0 > "$T/tracing_on"; : > "$T/trace"
	en regmap/regmap_reg_write
	en clk/clk_set_rate
	en clk/clk_enable
	en power/power_domain_target
	# rk_iommu setup around the submit -- the FINDINGS-named suspect the old
	# audit could not compare on one kernel
	en iommu/map
	en iommu/unmap
	en iommu/attach_device_to_domain
}

# normalize a trace to comparable lines: STRIP everything up to and including the
# ftrace timestamp (the leading "task-pid [cpu] flags <ts>:" -- ALL of which vary
# per run; if any is left in, the diff is pure noise). Keep only "event: args"
# (e.g. "regmap_reg_write: power-management@0x... reg=114 val=..").  The greedy
# .* backtracks to the timestamp, so it works whether or not the task/cpu/flags
# prefix is present in this kernel's trace format.
norm() {
	grep -aE 'regmap_reg_write|clk_set_rate|clk_enable|power_domain_target|iommu' "$1" \
		| sed -E 's/^.*[0-9]+\.[0-9]+: //' | sort -u
}

echo "===== env-trace [$LABEL]: driver-environment writes around a CHAINED submit ====="
echo "SoC=${SOC:-unknown}"
arm_events

# COLD by default (fresh boot -> NPU cold): capture the FULL power-on + first
# submit. This is the fair vendor-vs-rocket comparison. A WARM measurement is
# confounded: the vendor holds the NPU up for power_put_delay=600s, so its warm
# window is nearly empty (genpd/QoS/clock bring-up already done), while rocket
# re-powers per submit -- the asymmetry, not a real arm, dominates the diff.
if [ "${KILN_ENV_WARMUP:-0}" = "1" ]; then
	echo "=== warm-up inference (KILN_ENV_WARMUP=1; discarded) ==="
	echo 1 > "$T/tracing_on"; run_infer "$@" || { echo "no workload ran -- aborting"; exit 1; }
	echo 0 > "$T/tracing_on"; : > "$T/trace"
fi

echo "=== measured inference (COLD: full power-on + first submit -- run on a FRESH"
echo "    boot so the NPU is cold; KILN_ENV_WARMUP=1 measures a warm window instead) ==="
echo 1 > "$T/tracing_on"; run_infer "$@" || echo "  WARN: measured workload returned nonzero"
echo 0 > "$T/tracing_on"

OUT="$OUTDIR/env-${LABEL}.txt"
norm "$T/trace" > "$OUT"
echo "  -> $(wc -l < "$OUT") unique env events -> $OUT"
# Sanity: a valid capture MUST include NPU-relevant writes (genpd/QoS/rknn/npu).
# Zero of them means the workload never drove the NPU -- almost always the WRONG
# boot mode (label is just a filename; the DTB decides which driver binds).
NPU_N=$(grep -acE 'power-management|qos@|rknn|27700000|iommu' "$OUT" 2>/dev/null || echo 0)
if [ "$NPU_N" -eq 0 ]; then
	echo "  !! WARNING: 0 NPU-relevant events -- the NPU never powered on in this capture."
	echo "     '$LABEL' is only a FILENAME; the boot DTB decides the driver. Capture kiln"
	echo "     while booted on the KILN entry, rocket on the ROCKET entry (with"
	echo "     '-- kiln-rocket-run'). This file is not usable for the diff as-is."
fi
echo
echo "=== highlight: NPU-relevant env writes (regmap/iommu/genpd/npu/grf; CPU clk dropped) ==="
# no head-cap: a truncated + sorted highlight drops whole address ranges (e.g.
# qos@27f08.. after qos@27f04..) and makes a log-based diff look artificially
# different. The authoritative comparison is `kiln-env-trace diff` on the full file.
grep -aiE 'regmap_reg_write|iommu|power-management|npu|grf|pvtpll|repair' "$OUT" \
	| grep -avE "$NOISE" || true
echo
echo "next: capture the OTHER mode too, then diff ON THE BOARD (survives reboot):"
echo "  # kiln mode:   kiln-env-trace kiln"
echo "  # power-cycle, rocket mode:  kiln-env-trace rocket -- kiln-rocket-run"
echo "  kiln-env-trace diff        # vendor-only writes = the arm suspect"
