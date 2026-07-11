# scripts/

The Kiln CLIs and installer. End-user usage lives in the root
[`README.md`](../README.md) / [`ARMBIAN.md`](../docs/ARMBIAN.md); this is a map.

| file | what it is |
|---|---|
| `kiln-install.sh` | the one-command installer. **Phase 1** (stock kernel, online) pre-downloads an offline cache into `/opt/kiln`, installs the Kiln mainline 7.1.3 kernel, then hands off. **Phase 2** (patched kernel) builds the `rknpu` DKMS driver + runtimes + demos and restores wifi, **fully offline** from that cache. Run interactively on a terminal it shows a **whiptail front-end** (welcome/consent on a fresh board; an action menu — update / driver / kernel / get-a-model / open kiln-config — on an installed one); piped (`curl \| bash`) or head-less it stays text-only. |
| `kiln-phase2.sh` | the phase-2 systemd oneshot target. On the first reboot into the patched kernel, `kiln-phase2.service` runs this to finish the install offline, log to `/var/log/kiln-phase2.log`, then reboot again into the finished system. Not run by hand. |
| `kiln` | umbrella entry point: `kiln` opens a menu to pick a function; `kiln <chat\|vision\|models\|serve\|config\|doctor> [args]` dispatches to the tool below. |
| `kiln-doctor` | pass/fail health check; exits non-zero on any critical fault. See [`../docs/TOOLS.md`](../docs/TOOLS.md). |
| `kiln-config` | whiptail TUI front-end to `/etc/kiln/config.ini`. See [`../docs/TOOLS.md`](../docs/TOOLS.md). |
| `kiln-convert` | get/convert a model to a `.rknn` **on the board** (private `rknn-toolkit2` venv pinned to the runtime): model-zoo shortcut, URL, or local ONNX. See [`../docs/TOOLS.md`](../docs/TOOLS.md). |
| `build-dual-kernel-tree.sh` | maintainer-only: builds the dual-boot (vendor `rknpu` \| open `rocket`) kernel tree that `buildroot/build-image.sh` flashes. Needs external reference trees — not part of the on-board install. |
| `release-image.sh` | maintainer-only: publish a built + **hardware-validated** `sdcard.img` as a GitHub Release asset (xz + sha256 + `dd` instructions). Needs `gh` + `xz`. |

## The install flow

By default the install is **hands-off**: run one command and the board reboots
**itself twice** (~10–15 min) into a ready system — a systemd oneshot auto-continues
phase 2 after the first reboot. Onboard wifi is down between the reboots (expected);
phase 2 runs offline, so it doesn't need it. A login MOTD reports the outcome.

- `KILN_MANUAL=1` — hands-on: no auto-handoff service, no auto-reboot; you reboot and
  re-run the installer yourself.
- `KILN_SKIP_{KERNEL,REPO,DRIVER,RUNTIMES}=1`, `KILN_FORCE_KERNEL=1`,
  `KILN_FORCE_FETCH=1` — granular re-runs; see the header of `kiln-install.sh`.
