# capture/ — NPU per-op capture + the "cold-start arm" breakthrough probe

> **STATUS 2026-07-13 — the breakthrough probe was RUN, all-negative; do NOT re-chase it
> as an open lead.** `env-trace.sh` (regmap env), the `wtrace` direct-writel diff, the
> driver submit-register diff, a real per-submit TLB ZAP, and a CPU-cache-coherency check
> were all executed vendor-vs-rocket on this one 7.1.3 kernel — every one came back
> identical / ruled-out. Decisively, `replay_rocket` replaying the vendor's EXACT captured
> regcmd bytes through rocket STILL walls, so no payload/regcmd diff (`extract_regcmd.py`)
> can explain it either. Both GRF suspects are closed: memory-repair GRF REFUTED (this
> vendor stack never writes it yet MACs correctly), read-margin GRF board-tested null.
> Net: the closed-vs-open dimension is EXHAUSTED and it HARDENS the "arm is internal
> cold-start sequencer state (RTL)" reading. The authoritative write-up is
> `FINDINGS-DUAL-IMAGE.md` in the linux-rk3576-npu repo. The tools below remain useful as
> a general bring-up capture/diff toolkit — just not as a live wall-breaking lead.

A small capture toolkit for RK3576/RK3568 NPU bring-up. Two jobs:

1. **Per-op capture** (`run-capture.sh`) — dump one inference's register-command
   stream + buffers, decoded, from userspace. General bring-up / diff tool.
2. **The environment probe** (`env-trace.sh`) — aimed squarely at the wall
   the open [`rocket`](https://github.com/gahingwoo/linux-rk3576-npu) driver is
   stuck on.

## The wall this targets (why Kiln can crack it)

`rocket` (the open RK3576 NPU driver) can only make the NPU do **real MACs on the
first task per power session**. Every later/chained task engages and DMAs its
input, but the CMAC never fires — the output comes back zero-point / empty.

Two whole avenues have been closed by trial-and-error, so this probe does **not**
chase either:

- **Not an NPU register.** A complete writel audit found no NPU-block
  (`0x2770_xxxx`) write the vendor makes that rocket doesn't.
- **Not the command stream / payload.** The vendor's own captured regcmd bytes,
  replayed through the rocket driver, **also** wall in `task_number=N` mode
  (rocket `FINDINGS.md`). So mesa and the regcmd are exonerated.
- **Not the `npu_grf` memory-repair bit** (the earlier prime suspect): on the
  working Kiln vendor stack that write never happens (it lives in the unbuilt
  `rknpu_devfreq.c`), yet the NPU MACs correctly — so it is not the arm.

What is left is the **rocket driver's `task_number=N` execution ENVIRONMENT**:
clocks/PVTPLL, genpd power, `rk_iommu`, soft-reset, PC write ordering — everything
the driver sets up *around* the byte-identical submit.

Kiln runs the **working vendor stack** on the **same mainline kernel + same
hardware** as rocket. The old environment audit was confounded (vendor ran on the
6.1 BSP, a different kernel). Kiln removes that: a **vendor-vs-rocket environment
diff on one kernel is finally clean** — same clk driver, same genpd, same iommu.
The vendor MACs *every* chained task; rocket only the first. On one kernel, that
difference is in the driver environment, and `env-trace.sh` catches it.

## Files

| file | what |
|---|---|
| `env-trace.sh` | **the environment probe.** ftraces `regmap_reg_write` + `clk` + `genpd` + `iommu` around a WARM chained submit; run once per stack (kiln, then rocket) on the same board and diff — vendor-only env writes are the arm suspect. No kernel rebuild — pure built-in tracepoints. |
| `blindspot-trace.sh` | superseded (cold-vs-warm on one stack). Refuted the `npu_grf` memory-repair hypothesis; kept for reference. `env-trace.sh` is the same idea done vendor-vs-rocket on one kernel. |
| `run-capture.sh` | LD_PRELOAD one inference, dump submit + BOs + regcmd to `/rknpu_replay/`, decode. |
| `capture.c` | the LD_PRELOAD shim (intercepts DRM `MEM_CREATE`/`SUBMIT`). |
| `extract_regcmd.py` | decode a regcmd/`.rknn` blob into `tgt/reg/val` lines (diffs directly vs rocket's dump). |
| `rknpu-regcmd-dump.patch` | optional kernel-side dump of the regcmd stream in `commit_pc` (apply to `driver/rknpu` + rebuild the module). Also the base for a `wtrace` fallback if the environment diff comes back identical (to catch a direct `ioremap+writel` the tracepoints miss). |
| `wtrace-diff.py` | the `wtrace` fallback itself: decode + diff the vendor `rknpu` vs open `rocket` direct-`writel` (`ioremap`+`writel`) traces the regmap env-diff can't see, captured on the same dual-boot 7.1.3 image (`echo 1 > /sys/module/{rknpu,rocket}/parameters/...`). |

## Use

Run once per stack on the **same board**, then diff:

```sh
# 1) on the Kiln (vendor rknpu.ko) install:
sudo ./env-trace.sh kiln
#    -> /tmp/env-kiln.txt  (per-submit regmap/clk/genpd/iommu env writes, warm)

# 2) on the rocket (mesa teflon) install, same board:
sudo ./env-trace.sh rocket -- <your npu workload cmd...>
#    -> /tmp/env-rocket.txt

# 3) with both files on one host — vendor-ONLY env writes = the arm suspect:
comm -13 <(sort -u /tmp/env-rocket.txt) <(sort -u /tmp/env-kiln.txt)

# per-op capture of one inference (general tool)
./run-capture.sh
#    -> /rknpu_replay/{meta.txt,submit.bin,boNN.bin} + decoded regcmd
```

The delta is the concrete lead:

- **an environment write the vendor does and rocket doesn't** (a clk rate, a genpd
  transition, an iommu map, a syscon write around the submit) → a specific,
  likely-cheap fix for rocket; or
- **identical environment** → escalate to the `wtrace` fallback (a direct
  `ioremap+writel` the tracepoints miss), and if that is clean too, the arm is
  below the register bus (true HW / RTL state) — an honest negative that closes
  the software theory.

## Honest status

The per-op capture is proven (it's the RK3576 bring-up tooling, adapted here).
The **environment probe is a hypothesis-driven experiment, not a fix** — but it is
the one attack that uses Kiln's actual leverage (a working chained stack on the
same kernel as rocket) and has **not** been run: every prior audit was either
vendor-on-6.1-BSP-vs-rocket (confounded) or rocket cold-vs-warm. It may hand
rocket a fix, or it may prove the difference is unreachable HW state. Both are
real answers.

Adapted from the `vendor-capture/` toolkit in
[`gahingwoo/linux-rk3576-npu`](https://github.com/gahingwoo/linux-rk3576-npu)
(the open rocket + Mesa Teflon effort). GPL-2.0 / MIT as noted per file.
