#!/usr/bin/env bash
# Kiln one-click installer — LLMs + vision on the RK3576 NPU, on Armbian.
#
#   curl -fsSL https://raw.githubusercontent.com/gahingwoo/kiln/main/scripts/kiln-install.sh | bash
#
# Runs on Armbian userspace with a Kiln MAINLINE kernel. Two phases. By DEFAULT it
# is hands-off: run the one command and the machine reboots ITSELF TWICE (~10-15
# min) into a finished system -- a systemd oneshot (kiln-phase2.service ->
# scripts/kiln-phase2.sh) auto-continues phase 2 offline after the first reboot,
# then reboots again and reports the outcome at login. Set KILN_MANUAL=1 to drive
# the two phases by hand instead (reboot + re-run yourself; no service, no auto
# reboot).
#
#   PHASE 1 — on the stock kernel (with network): PRE-DOWNLOADS everything phase 2
#     needs into an on-disk cache under $KILN_DIR (closed runtimes + demo sources,
#     the vendor GPL driver source, the mobilenet test assets, and the aic8800 wifi
#     source), THEN installs the Kiln mainline 7.1.3 kernel (mainline + a small
#     pm-domain settle-delay fix that must be COMPILED INTO the kernel; the
#     out-of-tree module can't supply it, and a stock kernel SError-freezes the
#     NPU on the first inference). Prebuilt by CI, published as a release; the NPU
#     node is baked into its dtb. It wires Armbian's u-boot to boot it.
#     See kernel-patches/ and MAINLINE-KERNEL.md.
#
#   PHASE 2 — after you reboot into that kernel: builds the vendor rknpu driver
#     (DKMS) and installs the RKLLM/RKNN runtimes and the kiln-chat / kiln-vision
#     demos, then restores onboard wifi (patched aic8800). No DT overlay -- the NPU
#     node is already in the dtb. Runs FULLY OFFLINE from the phase-1 cache: the
#     patched kernel has no onboard wifi until phase 2 rebuilds it, so phase 2 must
#     not need the network -- and it doesn't. (That wifi-vs-network chicken-and-egg
#     was the old install deadlock.)
#
# You supply the model files (a *-rk3576-w4a16.rkllm and/or a *_rk3576.rknn).
#
# Granular re-runs: by default every run does ALL of phase 2 (repo pull, DKMS
# driver rebuild, runtimes+demos), even when only one of those actually changed
# -- e.g. you edited driver/rknpu/*.c and just want it rebuilt, not a fresh
# runtime download + demo recompile too. Skip whichever stages you don't need:
#
#   KILN_SKIP_KERNEL=1    skip the phase-1 kernel check/install entirely
#   KILN_SKIP_REPO=1      don't touch $KILN_DIR (use it exactly as it is on
#                          disk -- e.g. a local patch you don't want `git pull`
#                          to fast-forward over)
#   KILN_SKIP_DRIVER=1    don't rebuild/reinstall the rknpu DKMS module
#   KILN_SKIP_RUNTIMES=1  don't re-fetch RKLLM/RKNN runtimes or rebuild the
#                          demos/kiln-serve (the slow, network-heavy part)
#   KILN_MANUAL=1         don't install the auto-handoff service or auto-reboot;
#                          you reboot and re-run the installer yourself
#
# A driver-only run (KILN_SKIP_RUNTIMES=1, kernel unchanged) reloads the module
# itself (rmmod+modprobe) instead of asking for a reboot.
#
# KERNEL UPDATES ARE OPT-IN. Once you're on the Kiln kernel, a re-run (e.g. a Kiln
# update) does NOT reinstall the kernel -- so it won't re-run the reboot flow just
# because CI republished the same kernel with a newer build-timestamp version. To
# pick up a genuinely newer kernel: KILN_CHECK_KERNEL=1 (reinstalls only if the
# published version differs) or KILN_FORCE_KERNEL=1 (always reinstalls).
set -euo pipefail

REPO="${KILN_REPO:-https://github.com/gahingwoo/kiln.git}"
GH="${KILN_GH:-gahingwoo/kiln}"
# One installer serves both boards. Detect the SoC from the running (stock)
# device-tree so we pull the right kernel release + install the right dtb/model.
DT_COMPAT="$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null || true)"
case "$DT_COMPAT" in
	*rk3568*) SOC=rk3568; BOARD=rock-3b; DTB=rk3568-rock-3b.dtb; DEF_KTAG=kiln-mainline-kernel-rk3568 ;;
	*)        SOC=rk3576; BOARD=rock-4d; DTB=rk3576-rock-4d.dtb; DEF_KTAG=kiln-mainline-kernel ;;
esac
MODEL_RKNN="mobilenetv2-12_${SOC}.rknn"
KTAG="${KILN_KERNEL_TAG:-$DEF_KTAG}"
AIC_REPO="${KILN_AIC_REPO:-https://github.com/radxa-pkg/aic8800.git}"
AIC_REF="${KILN_AIC_REF:-5.0+git20260123.5f7be68d-6}"   # the release Kiln's patch is verified against
KILN_DIR="${KILN_DIR:-/opt/kiln}"
AIC_CACHE="$KILN_DIR/cache/aic8800"   # phase-1 pre-clone of the aic8800 source ->
                                      # phase-2 restores wifi OFFLINE (no clone).
PKG=kiln-rknpu; VER=0.9.8
KREL="$(uname -r)"
MARKER=/etc/kiln/patched-kernel
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo
# Bound network hangs on a plugged-in-but-DEAD network (dead switch, stale static
# IP, captive portal): fail fast instead of stalling for the full TCP timeout.
# git: give up if a transfer stays under 1 KB/s for 15s. curl: for the small JSON
# API calls (NOT the big .deb downloads, which only get a connect timeout).
export GIT_HTTP_LOW_SPEED_LIMIT=1024 GIT_HTTP_LOW_SPEED_TIME=15
CURL_NET="--connect-timeout 8 --max-time 25"

say(){ printf '\n\033[1;36m[kiln]\033[0m %s\n' "$*"; }
die(){ printf '\n\033[1;31m[kiln] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Resolve a sibling Kiln tool: prefer the installed one on PATH, else this repo's
# scripts/ dir (used by the interactive TUI to hand off to kiln-config/convert/doctor).
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "$KILN_DIR/scripts")"
_tool(){ command -v "$1" 2>/dev/null || { [ -f "$SELF_DIR/$1" ] && echo "$SELF_DIR/$1"; }; }

# Build every registered DKMS module against kernel release $1; remove the ones
# that don't build (e.g. the aic8800 wifi driver doesn't build on 7.1). A module
# that fails to build makes the linux-image postinst's 'dkms autoinstall' fail,
# which leaves the kernel half-configured and blocks ALL apt. Pruning them keeps
# the kernel installable and apt usable -- at the cost of that driver until it
# supports the new kernel.
prune_unbuildable_dkms(){
	local k="$1" m v
	command -v dkms >/dev/null 2>&1 || return 0
	[ -d "/lib/modules/$k/build" ] || return 0
	$SUDO dkms status 2>/dev/null | sed -E 's#[/,:]# #g' | awk '{print $1, $2}' | sort -u |
	while read -r m v; do
		[ -n "$m" ] && [ "$m" != "$PKG" ] || continue
		$SUDO dkms status -m "$m" -v "$v" -k "$k" 2>/dev/null | grep -q installed && continue
		if ! $SUDO dkms build "$m/$v" -k "$k" >/dev/null 2>&1; then
			say "  DKMS $m/$v does not build on $k -- removing it"
			say "  (a driver such as aic8800 wifi/bt may stop working until it supports this kernel; use ethernet)"
			$SUDO dkms remove "$m/$v" --all >/dev/null 2>&1 || true
		fi
	done
}

# Wire Armbian's u-boot to a mainline kernel (a bindeb-pkg .deb installs vmlinuz +
# modules + dtbs + an initrd.img but does NOT create the u-boot uInitrd, the
# /boot/Image link, or point armbianEnv at the dtb -- do that here, idempotently).
wire_boot(){
	local k="$1" dtb
	if [ -f "/boot/initrd.img-$k" ] && command -v mkimage >/dev/null 2>&1; then
		$SUDO mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
			-d "/boot/initrd.img-$k" "/boot/uInitrd-$k" >/dev/null 2>&1 || true
		$SUDO ln -sf "uInitrd-$k" /boot/uInitrd
	fi
	[ -e "/boot/vmlinuz-$k" ] && $SUDO ln -sf "vmlinuz-$k" /boot/Image
	dtb="$(find "/usr/lib/linux-image-$k" /boot -name "$DTB" 2>/dev/null | head -1)"
	if [ -n "$dtb" ]; then
		$SUDO install -Dm0644 "$dtb" "/boot/dtb/rockchip/$DTB"
		if grep -q '^fdtfile=' /boot/armbianEnv.txt; then
			$SUDO sed -i "s#^fdtfile=.*#fdtfile=rockchip/$DTB#" /boot/armbianEnv.txt
		else
			echo "fdtfile=rockchip/$DTB" | $SUDO tee -a /boot/armbianEnv.txt >/dev/null
		fi
	fi
}

# The ROCK 4D's onboard aic8800 wifi/bt is out-of-tree and its stock driver does
# not build on 7.1 -- so moving to the mainline kernel drops wifi. Build the
# Kiln-patched aic8800 (radxa 5.0 + aic8800-patches/) via DKMS for kernel $1 so
# wifi/bt survive. Best-effort: warns and continues (use ethernet) if it can't.
install_patched_aic8800(){
	local k="$1" src pf pkg=aic8800-usb ver=5.0-kiln
	command -v dkms >/dev/null 2>&1 || return 0
	pf="$(ls "$KILN_DIR"/aic8800-patches/0001-*.patch 2>/dev/null | head -1)"
	[ -f "$pf" ] || return 0
	say "restoring wifi/bt: building the Kiln-patched aic8800 driver for $k ..."
	# drop any aic8800 DKMS already registered (the stock one won't build on 7.1)
	$SUDO dkms status 2>/dev/null | sed -E 's#[/,:]# #g' | awk '/aic8800/{print $1"/"$2}' | sort -u |
	while read -r old; do [ -n "$old" ] && $SUDO dkms remove "$old" --all >/dev/null 2>&1 || true; done
	src="$(mktemp -d)"
	if [ -d "$AIC_CACHE/src/USB" ]; then
		# OFFLINE path: use the source pre-cloned in phase 1 (no network needed on
		# the wifi-less patched kernel). This is what breaks the install deadlock.
		say "  using pre-cached aic8800 source ($AIC_CACHE)"
		cp -r "$AIC_CACHE" "$src/a"
	elif git clone --depth 1 --branch "$AIC_REF" "$AIC_REPO" "$src/a" >/dev/null 2>&1 \
		|| git clone --depth 1 "$AIC_REPO" "$src/a" >/dev/null 2>&1; then
		: # online fallback (no cache, e.g. a manual driver-only re-run)
	else
		say "  WARN: couldn't fetch aic8800 source; wifi stays down on $k (use ethernet)."; rm -rf "$src"; return 0
	fi
	if ! ( cd "$src/a" && patch -p1 < "$pf" ) >/dev/null 2>&1; then
		say "  WARN: aic8800 patch did not apply (upstream moved); wifi stays down on $k."; rm -rf "$src"; return 0
	fi
	$SUDO rm -rf "/usr/src/$pkg-$ver"; $SUDO mkdir -p "/usr/src/$pkg-$ver"
	$SUDO cp -r "$src/a/src/USB" "/usr/src/$pkg-$ver/"
	# Generate dkms.conf from radxa's usb template, but force AUTOINSTALL=no:
	# with AUTOINSTALL=yes a broken/half-staged aic8800 build makes the kernel
	# image postinst's 'dkms autoinstall' fail and leaves the kernel
	# half-configured (blocks apt). We build+install it explicitly below, so it
	# never needs to ride the kernel's autoinstall.
	sed -e "s/#MODULE_VERSION#/$ver/g" -e 's/^AUTOINSTALL=.*/AUTOINSTALL=no/' \
		"$src/a/debian/aic8800-usb-dkms.dkms" | $SUDO tee "/usr/src/$pkg-$ver/dkms.conf" >/dev/null
	# Firmware: aic_load_fw loads blobs from /lib/firmware/<chip>/ (the chip is
	# auto-detected, e.g. aic8800D80). Without them the USB bus never comes up
	# ("bus is not up"). Install the whole USB firmware tree there.
	$SUDO cp -a "$src/a/src/USB/driver_fw/fw/." /lib/firmware/ 2>/dev/null || true
	$SUDO dkms add "$pkg/$ver" >/dev/null 2>&1 || true
	if $SUDO dkms build "$pkg/$ver" -k "$k" >/dev/null 2>&1 && $SUDO dkms install "$pkg/$ver" -k "$k" >/dev/null 2>&1; then
		say "  aic8800 wifi/bt built and installed for $k."
	else
		say "  WARN: patched aic8800 failed to build for $k (debug: sudo dkms build $pkg/$ver -k $k). Wifi stays down; use ethernet."
	fi
	rm -rf "$src"
}

# Clone (or fast-forward) the Kiln repo into $KILN_DIR. Hoisted to run in phase 1
# so the fetch scripts + the offline cache land on disk BEFORE the first reboot;
# $KILN_DIR persists across reboots, so phase 2 finds it all locally. Honors
# KILN_SKIP_REPO (use the tree exactly as-is). cd's into $KILN_DIR.
fetch_kiln_repo(){
	if [ -n "${KILN_SKIP_REPO:-}" ]; then
		[ -d "$KILN_DIR" ] || die "KILN_SKIP_REPO set but $KILN_DIR doesn't exist yet -- need it once without the skip."
		say "KILN_SKIP_REPO set — using $KILN_DIR as-is (no git pull/clone)."
	else
		say "fetching Kiln into $KILN_DIR ..."
		if [ -d "$KILN_DIR/.git" ]; then
			$SUDO git -C "$KILN_DIR" pull --ff-only || true
		else
			# No .git yet. Clone into a temp dir and swap in only on success -- never
			# rm -rf the existing tree before a clone that could fail offline (that
			# would wipe a hand-placed tree / the cache and leave nothing).
			ktmp="$(mktemp -d)"
			if $SUDO git clone --depth 1 "$REPO" "$ktmp/k"; then
				$SUDO rm -rf "$KILN_DIR"; $SUDO mkdir -p "$(dirname "$KILN_DIR")"; $SUDO mv "$ktmp/k" "$KILN_DIR"
				$SUDO rm -rf "$ktmp"
			else
				$SUDO rm -rf "$ktmp"
				die "couldn't clone $REPO into $KILN_DIR (the first run needs network)."
			fi
		fi
		# Cloned as root, but fetch-runtimes / g++ demos run as you and write back into
		# the tree (buildroot/dl, model/); hand it over so those writes don't EPERM.
		$SUDO chown -R "$(id -u):$(id -g)" "$KILN_DIR"
	fi
	cd "$KILN_DIR"
}

# Pre-clone the aic8800 wifi source (rk3576 only) into $AIC_CACHE while we still
# have network (phase 1), so phase 2 can rebuild wifi OFFLINE on the patched
# kernel. Best-effort: a failure here just means phase 2 falls back to an online
# clone (or ethernet). Idempotent -- skips if already cached.
precache_aic8800(){
	[ "$SOC" = rk3576 ] || return 0
	command -v git >/dev/null 2>&1 || return 0
	ls "$KILN_DIR"/aic8800-patches/0001-*.patch >/dev/null 2>&1 || return 0
	if [ -d "$AIC_CACHE/src/USB" ]; then say "  aic8800 source already cached"; return 0; fi
	say "pre-caching aic8800 wifi source (for offline phase 2) ..."
	$SUDO mkdir -p "$(dirname "$AIC_CACHE")"; $SUDO rm -rf "$AIC_CACHE"
	if $SUDO git clone --depth 1 --branch "$AIC_REF" "$AIC_REPO" "$AIC_CACHE" >/dev/null 2>&1 \
		|| $SUDO git clone --depth 1 "$AIC_REPO" "$AIC_CACHE" >/dev/null 2>&1; then
		$SUDO chown -R "$(id -u):$(id -g)" "$AIC_CACHE" 2>/dev/null || true
		say "  aic8800 source cached at $AIC_CACHE"
	else
		say "  WARN: couldn't pre-cache aic8800 source; phase 2 will try online (or use ethernet)."
		$SUDO rm -rf "$AIC_CACHE"
	fi
}

# Pull EVERYTHING phase 2 needs into the on-disk cache so phase 2 runs with no
# network (the patched kernel has no wifi until phase 2 rebuilds it -- that was the
# deadlock). All idempotent, all land under $KILN_DIR (persists across the reboot).
#
# The vendor GPL rknpu source is MANDATORY: phase 2's DKMS build has no online
# fallback on the wifi-less kernel, so a failure to fetch it now (while online)
# must ABORT here -- on the networked stock kernel -- not silently continue and
# strand the user after the reboot. The heavy RKLLM/RKNN runtime + vision blobs are
# what KILN_SKIP_RUNTIMES controls; the driver source and the aic8800 wifi source
# are NOT "runtimes" and are always fetched (they are the deadlock-critical bits).
predownload_cache(){
	say "pre-downloading everything phase 2 needs (so it can run offline) ..."
	# vendor GPL rknpu source -> driver/rknpu, so DKMS PRE_BUILD is offline in phase 2.
	bash driver/fetch-vendor-driver.sh \
		|| die "couldn't fetch the rknpu driver source. Fix networking and re-run -- phase 2 (offline) needs it."
	[ -f driver/rknpu/include/rknpu_drv.h ] \
		|| die "rknpu driver source looks incomplete after fetch; re-run (KILN_FORCE_FETCH=1 to force a fresh pull)."
	# aic8800 wifi source -> cache/aic8800. Best-effort (the NPU install does not
	# depend on wifi; a failure just means phase 2 falls back to online/ethernet).
	precache_aic8800
	if [ -n "${KILN_SKIP_RUNTIMES:-}" ]; then
		say "KILN_SKIP_RUNTIMES set — skipping the heavy runtime/vision pre-download (fetch them later, online)."
	else
		bash buildroot/fetch-runtimes.sh
		bash buildroot/fetch-vision-assets.sh || true
	fi
	if [ -n "${KILN_SKIP_RUNTIMES:-}" ]; then
		say "cache ready under $KILN_DIR (driver/rknpu, cache/aic8800; runtimes skipped)."
	else
		say "cache ready under $KILN_DIR (driver/rknpu, cache/aic8800, buildroot/dl, model/)."
	fi
}

# Install a one-shot systemd service that finishes phase 2 on the next boot,
# OFFLINE, then reboots into the finished system -- so the whole install is "run
# one command, walk away". A plain systemd oneshot (not a bootloader one-shot
# trick), so it works under the ROCK 4D's u-boot exactly like it would with GRUB.
# It disables itself when done (kiln-phase2.sh) and won't re-run once phase 2 has
# completed (ConditionPathExists + the phase2-done marker we clear here for a
# re-install). Returns non-zero if there's no systemd -> caller falls back to
# manual mode. KILN_MANUAL=1 skips this entirely.
install_phase2_service(){
	[ -d /etc/systemd/system ] || { say "no systemd here -- can't auto-continue; use the manual steps below."; return 1; }
	[ -f "$KILN_DIR/scripts/kiln-phase2.sh" ] || { say "kiln-phase2.sh missing -- can't auto-continue; use the manual steps below."; return 1; }
	# Clear any stale status from a previous install so the oneshot runs for THIS
	# (re)install and the login MOTD reflects the fresh run.
	$SUDO rm -f /etc/kiln/phase2-done /etc/kiln/phase2-failed
	$SUDO tee /etc/systemd/system/kiln-phase2.service >/dev/null <<EOF
[Unit]
Description=Kiln: finishing install (driver + runtimes + wifi) -- do NOT power off
# Runs BEFORE any login is permitted: systemd-user-sessions.service is the gate that
# enables logins, so ordering before it means the user never lands on the half-set-up
# intermediate boot (onboard wifi is still down until this rebuilds it). Offline from
# the phase-1 cache -- no network dependency. Reboots into the finished system when
# done; ConditionPathExists makes it a no-op once phase 2 has completed.
After=basic.target
Before=systemd-user-sessions.service
ConditionPathExists=!/etc/kiln/phase2-done

[Service]
Type=oneshot
ExecStart=$KILN_DIR/scripts/kiln-phase2.sh
RemainAfterExit=yes
TimeoutStartSec=1800
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
	$SUDO systemctl daemon-reload 2>/dev/null || true
	$SUDO systemctl enable kiln-phase2.service >/dev/null 2>&1 \
		|| { say "couldn't enable kiln-phase2.service -- use the manual steps below."; return 1; }
	return 0
}

# Friendly whiptail front-end for INTERACTIVE runs. It only ever sets the same
# KILN_* env vars you could pass by hand (then the normal text install proceeds --
# we don't hide the build logs behind a progress bar, since you want to see them if
# something breaks). Skipped automatically when:
#   * piped (curl|bash: stdin isn't a tty) or head-less (the phase-2 systemd service),
#   * whiptail isn't installed yet (first-ever run on a bare system -> text mode),
#   * you already chose an action via a KILN_* stage flag (scripted; don't nag).
# On an already-installed board it's an action menu (mostly hands off to kiln-config /
# kiln-convert); on a fresh board it explains the two-reboot plan and gets consent.
installer_tui(){
	[ -t 0 ] && [ -t 1 ] || return 0
	[ -z "${KILN_NONINTERACTIVE:-}" ] || return 0
	command -v whiptail >/dev/null 2>&1 || return 0
	[ -z "${KILN_SKIP_KERNEL:-}${KILN_SKIP_DRIVER:-}${KILN_SKIP_RUNTIMES:-}${KILN_SKIP_REPO:-}${KILN_CHECK_KERNEL:-}${KILN_FORCE_KERNEL:-}${KILN_MANUAL:-}" ] || return 0
	local BT="Kiln installer  ·  $SOC / $BOARD  ·  LLM + vision on the RK3576 NPU"
	local cfg conv doc; cfg="$(_tool kiln-config)"; conv="$(_tool kiln-convert)"; doc="$(_tool kiln-doctor)"
	if [ -f /etc/kiln/phase2-done ]; then
		local a
		a=$(whiptail --backtitle "$BT" --title "Kiln is installed on this board" --menu \
			"What would you like to do?  (Settings live in kiln-config; this just runs the installer's actions.)" 20 78 8 -- \
			config "open kiln-config  (settings · models · diagnostics)" \
			update "update Kiln: git pull + rebuild driver & runtimes (keep kernel)" \
			model  "get / convert a model on the board  (kiln-convert)" \
			driver "rebuild the NPU driver only  (rknpu DKMS)" \
			kernel "check for a newer Kiln kernel  (may reboot)" \
			doctor "run diagnostics  (kiln-doctor)" \
			quit   "quit" 3>&1 1>&2 2>&3) || exit 0
		case "$a" in
			config) [ -n "$cfg" ] && exec "$cfg"; return 0 ;;
			update) return 0 ;;                                   # full run; kernel auto-skipped when installed
			model)  clear; [ -n "$conv" ] && "$conv" || say "kiln-convert not found"; exit $? ;;
			driver) export KILN_SKIP_KERNEL=1 KILN_SKIP_RUNTIMES=1; return 0 ;;
			kernel) export KILN_CHECK_KERNEL=1; return 0 ;;
			doctor) clear; [ -n "$doc" ] && "$doc" || true; printf '\nPress Enter to exit ...'; read -r _; exit 0 ;;
			quit|"") exit 0 ;;
		esac
	else
		if whiptail --backtitle "$BT" --title "Install Kiln" --yes-button "Auto (recommended)" --no-button "More options..." --yesno \
"This installs the Kiln mainline NPU kernel, the LLM + vision runtimes, and restores
onboard wifi.

AUTO: the board REBOOTS ITSELF TWICE (~10-15 min total) and finishes on its own --
you'll see \"Kiln installed\" at the next login. Onboard wifi is down between the
reboots (expected); the offline phase doesn't need it.  DON'T CUT POWER.

Proceed with the automatic install?" 20 78; then
			return 0
		fi
		local m
		m=$(whiptail --backtitle "$BT" --title "Install options" --menu "How would you like to run the install?" 18 78 5 -- \
			auto   "automatic: reboot twice, hands-off  (recommended)" \
			manual "manual: I'll reboot and re-run the installer myself" \
			model  "just get / convert a model first  (kiln-convert)" \
			cancel "cancel -- don't install now" 3>&1 1>&2 2>&3) || exit 0
		case "$m" in
			auto)   return 0 ;;
			manual) export KILN_MANUAL=1; return 0 ;;
			model)  clear; [ -n "$conv" ] && "$conv" || say "kiln-convert not found"; exit $? ;;
			cancel|"") exit 0 ;;
		esac
	fi
}

# --- 0. preflight -----------------------------------------------------------
say "Kiln installer — RK3576 NPU on Armbian"
[ "$(uname -m)" = aarch64 ] || die "aarch64 only (found $(uname -m))"
[ -f /boot/armbianEnv.txt ] || die "no /boot/armbianEnv.txt — this installer targets Armbian"
say "detected SoC: $SOC (board $BOARD, kernel release '$KTAG', dtb $DTB)"
grep -aqi "$SOC" /proc/device-tree/compatible 2>/dev/null \
	|| say "note: board does not report $SOC in /proc/device-tree/compatible; continuing"

# Interactive front-end (no-op when piped / head-less / scripted). May set KILN_*
# env vars, hand off to kiln-config/convert/doctor, or exit -- all before we mutate
# anything, so it's safe here at the top.
installer_tui

# --- 1. prerequisites -------------------------------------------------------
# Heal first: a kernel left half-configured by a DKMS module that won't build on
# it (e.g. a prior interrupted run) blocks every apt call below. Clear it.
if ! $SUDO dpkg --configure -a >/dev/null 2>&1; then
	say "an unfinished package configuration is blocking apt (a DKMS module won't build) -- healing ..."
	prune_unbuildable_dkms "$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1)"
	$SUDO dpkg --configure -a || true
fi
# Offline-safe: only touch apt when something is actually missing. A phase-2 run
# (patched kernel, no wifi) already has all of these from phase 1, so re-running
# apt-get install would needlessly try the network -- and `|| die` would then abort
# the whole offline install. Skip it when the prerequisites are already present.
need_apt=0
for c in git gcc dkms dtc curl mkimage whiptail python3; do command -v "$c" >/dev/null 2>&1 || need_apt=1; done
# python3-venv lets kiln-convert build a private rknn-toolkit2 venv on the board (so
# converting a model needs no extra manual apt); libs as before.
for p in libreadline-dev libgomp1 ca-certificates python3-venv; do dpkg -s "$p" >/dev/null 2>&1 || need_apt=1; done
if [ "$need_apt" = 1 ]; then
	say "installing prerequisites ..."
	$SUDO apt-get update -qq || true
	$SUDO apt-get install -y git build-essential dkms device-tree-compiler curl ca-certificates u-boot-tools \
		libreadline-dev libgomp1 whiptail python3 python3-venv \
		|| die "apt failed installing prerequisites (need network for the first run)."
else
	say "prerequisites already present — skipping apt."
fi

# --- 1b. fetch Kiln FIRST (before the kernel phase) -------------------------
# Hoisted here so phase 1 can pre-download the offline cache into $KILN_DIR while
# it still has network; $KILN_DIR survives the reboot, so phase 2 finds it all.
fetch_kiln_repo

# --- 2. KERNEL PHASE (install the patched kernel once, then reboot) ----------
# The deb version (e.g. 20260708.13) the '$KTAG' release currently offers; empty
# if offline. Two CI builds share the same 'uname -r' (7.1.3), so the deb VERSION
# -- not the release string -- is what tells a new kernel (e.g. with 0010) from an
# old one; the marker records it so a newer published build re-installs by itself.
kernel_release_ver(){
	curl -fsSL $CURL_NET "https://api.github.com/repos/$GH/releases/tags/$KTAG" 2>/dev/null \
		| grep -o 'linux-image-[^"]*\.deb' | grep -v -- '-dbg' | head -1 | awk -F_ '{print $2}'
}
# True once we're running the Kiln kernel AND it is the version the release now
# offers. KILN_FORCE_KERNEL=1 forces a re-install regardless. Offline (can't check
# the release) keeps the running kernel -- safe fallback, never blocks.
on_patched_kernel(){
	[ -n "${KILN_FORCE_KERNEL:-}" ] && return 1
	[ -f "$MARKER" ] || return 1
	[ "$KREL" = "$(sed -n 1p "$MARKER" 2>/dev/null)" ] || return 1
	# We're running the Kiln kernel. By DEFAULT do NOT reinstall it just because CI
	# republished a newer .deb -- its version is a build timestamp, so it bumps on
	# every rebuild even when the kernel code is identical, which would re-run the
	# whole kernel+reboot flow on an ordinary Kiln update. Kernel updates are opt-in:
	# KILN_CHECK_KERNEL=1 (or kiln-config -> Advanced) compares the published version
	# and reinstalls if it's genuinely newer; KILN_FORCE_KERNEL=1 always reinstalls.
	[ -n "${KILN_CHECK_KERNEL:-}" ] || return 0
	local want; want="$(kernel_release_ver)"
	[ -z "$want" ] && return 0
	[ "$(sed -n 2p "$MARKER" 2>/dev/null)" = "$want" ]
}

KERNEL_CHANGED=0
if [ -n "${KILN_SKIP_KERNEL:-}" ]; then
	say "KILN_SKIP_KERNEL set — skipping the kernel check/install; assuming $KREL is fine."
	# Still ensure the offline cache exists on this path (it's what the phase-2
	# systemd handoff uses, and what a first run with KILN_SKIP_KERNEL would need).
	# Idempotent: a no-op when the cache is already complete.
	predownload_cache
elif ! on_patched_kernel; then
	KERNEL_CHANGED=1
	# Fill the offline cache BEFORE installing the kernel. If a download fails
	# (network hiccup), we abort here -- still on the stock kernel WITH wifi, so the
	# user just fixes it and re-runs. Installing the kernel first and failing here
	# would strand them on the wifi-less patched kernel with an incomplete cache.
	predownload_cache
	say "installing the Kiln mainline NPU kernel from the '$KTAG' release ..."
	TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
	# exclude the -dbg debug-symbol image (bindeb-pkg builds it; ~hundreds of MB,
	# not needed, and its name also matches linux-image-*.deb below).
	( cd "$TMP" && curl -fsSL $CURL_NET "https://api.github.com/repos/$GH/releases/tags/$KTAG" \
		| grep -o 'https://[^"]*\.deb' | grep -v -- '-dbg' | xargs -n1 -r curl -fL --connect-timeout 8 -O ) \
		|| die "could not download the mainline kernel .debs from the '$KTAG' release."
	IMG="$(ls "$TMP"/linux-image-*.deb 2>/dev/null | head -1)"
	[ -f "$IMG" ] || die "no linux-image .deb in the '$KTAG' release (is the CI build published?)."
	# no 'head' in this pipe (it would SIGPIPE dpkg-deb under pipefail); a
	# linux-image has exactly one /lib/modules/<release>.
	KREL_NEW="$(dpkg-deb -c "$IMG" | grep -oE 'lib/modules/[^/]+' | sort -u | cut -d/ -f3)"
	# Headers first: their postinst prepares the build tree DKMS needs. Then prune
	# any DKMS module that won't build on the new kernel (e.g. aic8800 wifi on 7.1)
	# BEFORE the image, or the image postinst's 'dkms autoinstall' fails and leaves
	# the kernel half-configured (which blocks apt). A bindeb-pkg build has no
	# separate linux-dtb package -- the dtbs ship inside linux-image.
	say "installing mainline kernel $KREL_NEW (headers first) ..."
	$SUDO dpkg -i "$TMP"/linux-headers-*.deb || die "installing linux-headers failed."
	prune_unbuildable_dkms "$KREL_NEW"
	$SUDO dpkg -i "$TMP"/linux-image-*.deb || die "installing the kernel failed (see dpkg errors above)."
	wire_boot "$KREL_NEW"     # point Armbian's u-boot at the mainline kernel + dtb
	$SUDO apt-mark hold "linux-image-$KREL_NEW" "linux-headers-$KREL_NEW" >/dev/null 2>&1 || true
	# marker: line 1 = kernel release (uname -r), line 2 = deb version, so a later
	# run can tell a newer published build from the one already installed.
	DEBVER="$(basename "$IMG" | awk -F_ '{print $2}')"
	$SUDO mkdir -p /etc/kiln; printf '%s\n%s\n' "$KREL_NEW" "$DEBVER" | $SUDO tee "$MARKER" >/dev/null

	# Auto-handoff (default): a systemd oneshot finishes phase 2 offline on the next
	# boot and reboots again into the finished system -- one command, walk away.
	# KILN_MANUAL=1 keeps the old hands-on flow (reboot + re-run yourself).
	if [ -z "${KILN_MANUAL:-}" ] && install_phase2_service; then
		cat <<EOF

[kiln] Mainline NPU kernel $KREL_NEW installed and everything phase 2 needs is
       cached. From here it is HANDS-OFF: the machine will REBOOT ITSELF TWICE
       (~10-15 min total) -- once into the new kernel to finish setup (offline),
       then again into the finished system. DON'T CUT POWER. Onboard wifi is down
       between the reboots (expected); phase 2 doesn't need it. When it's done
       you'll see "Kiln installed" at the next login (or check kiln-doctor).
       Full phase-2 log: /var/log/kiln-phase2.log

       Rebooting in 5s ...
EOF
		sync; sleep 5
		$SUDO systemctl reboot
		exit 0
	fi

	# Manual mode (KILN_MANUAL=1, or no systemd to auto-continue).
	cat <<EOF

[kiln] Mainline NPU kernel $KREL_NEW installed, and everything phase 2 needs is
       cached on disk. Onboard wifi will be DOWN on the new kernel until phase 2
       rebuilds it -- but phase 2 runs fully OFFLINE, so that's fine. REBOOT into
       the new kernel, then run this installer again to finish:

           sudo reboot
           sudo bash $KILN_DIR/scripts/kiln-install.sh   # runs offline, no wifi needed
EOF
	exit 0
fi
say "on the Kiln-patched kernel ($KREL) — finishing the install (offline-capable)."

# The repo was already fetched before the kernel phase (fetch_kiln_repo), which
# also cd'd into $KILN_DIR. Nothing since changed the working dir; re-assert it
# defensively so the relative paths below resolve.
cd "$KILN_DIR"

DRIVER_REBUILT=0
if [ -n "${KILN_SKIP_DRIVER:-}" ]; then
	say "KILN_SKIP_DRIVER set — leaving the installed rknpu module as-is."
else
	# --- 4. driver via DKMS -----------------------------------------------------
	# Headers came WITH the patched kernel (linux-headers deb), so this always matches.
	[ -d "/lib/modules/$KREL/build" ] \
		|| die "no kernel headers for $KREL (the patched linux-headers deb should provide them)."
	say "building the rknpu driver with DKMS ..."
	# dkms.conf's PRE_BUILD (driver/fetch-vendor-driver.sh) fetches the vendor GPL
	# source and applies the mainline shims. It is now idempotent: if driver/rknpu
	# is already present -- pre-fetched in phase 1 (so this DKMS build runs OFFLINE),
	# or a local driver patch you're testing -- it does nothing. So PRE_BUILD no
	# longer needs network here, and no longer silently clobbers a local hand-edit.
	# Force a fresh vendor pull with KILN_FORCE_FETCH=1.
	$SUDO rm -rf "/usr/src/$PKG-$VER"; $SUDO mkdir -p "/usr/src/$PKG-$VER"
	$SUDO cp -r Kbuild Makefile dkms.conf driver "/usr/src/$PKG-$VER/"
	$SUDO dkms remove "$PKG/$VER" --all >/dev/null 2>&1 || true
	$SUDO dkms add "/usr/src/$PKG-$VER"
	$SUDO dkms build "$PKG/$VER"
	$SUDO dkms install "$PKG/$VER"
	# Load rknpu at boot (loading a module needs root; the dtb's NPU node is up before
	# userspace, so a boot-time modprobe binds it and the render node is ready).
	echo rknpu | $SUDO tee /etc/modules-load.d/rknpu.conf >/dev/null
	DRIVER_REBUILT=1

	# Restore onboard wifi/bt on the mainline kernel (the stock aic8800 doesn't build
	# on 7.1; Kiln's patch does). Best-effort -- the NPU install does not depend on it.
	# aic8800 is the ROCK 4D (RK3576) radio; the ROCK 3B uses a different one, so only
	# run it there.
	[ "$SOC" = rk3576 ] && install_patched_aic8800 "$KREL" \
		|| say "wifi: skipping aic8800 (only on the ROCK 4D / rk3576)."
fi

# If only the driver changed (no kernel change this run), reload it in place
# instead of asking for a reboot -- rmmod+modprobe picks up the freshly
# installed module immediately. Best-effort: if something has the render node
# open, fall back to asking for a reboot.
DRIVER_RELOADED=0
if [ "$DRIVER_REBUILT" = 1 ] && [ "$KERNEL_CHANGED" = 0 ]; then
	if $SUDO rmmod rknpu 2>/dev/null; then
		if $SUDO modprobe rknpu; then
			DRIVER_RELOADED=1
			say "rknpu reloaded (no reboot needed)."
		else
			say "WARN: rknpu unloaded but failed to reload -- reboot to bring it back."
		fi
	else
		say "rknpu is in use (or wasn't loaded) -- couldn't hot-reload it; reboot to load the new build."
	fi
fi

# --- 5. NPU device-tree node -------------------------------------------------
# Nothing to do: on the mainline kernel the vendor NPU node is compiled into the
# dtb (kernel-patches/0004), so there is no overlay to install. wire_boot()
# already put that dtb where u-boot loads it.
say "NPU node is built into the mainline dtb (no overlay needed)."

# --- 6. runtimes + demos (native aarch64 build) + vision assets --------------
if [ -n "${KILN_SKIP_RUNTIMES:-}" ]; then
	say "KILN_SKIP_RUNTIMES set — leaving runtimes/demos/models as installed."
	DL="$KILN_DIR/buildroot/dl"
else
	say "fetching runtimes and building the demos ..."
	bash buildroot/fetch-runtimes.sh
	bash buildroot/fetch-vision-assets.sh || true
	DL="$KILN_DIR/buildroot/dl"
	for so in librkllmrt.so librknnrt.so libgomp.so.1; do
		[ -f "$DL/$so" ] && $SUDO install -m0644 "$DL/$so" /usr/lib/ || true
	done
	[ -f "$DL/libgomp.so.1" ] || say "note: libgomp.so.1 not staged; librkllmrt will use the system one if present"

	if [ -f "$DL/rkllm.h" ]; then
		# line editing + history in kiln-chat needs readline; use it if the header is
		# present, otherwise fall back to a plain line read (no cursor/history). The
		# -D define goes before the source; -lreadline MUST come AFTER it (ld resolves
		# libs against objects already seen), so it goes at the end with the other libs.
		RLDEF=""; RLLIB=""
		printf '#include <readline/readline.h>\n' | g++ -E - >/dev/null 2>&1 && { RLDEF="-DKILN_USE_READLINE"; RLLIB="-lreadline"; }
		g++ -include cstdint $RLDEF buildroot/board/rock4d/rkllm_chat.cpp -I "$DL" -L "$DL" \
			-Wl,-rpath-link,"$DL" -lrkllmrt -lpthread $RLLIB -o /tmp/rkllm_demo \
		  && $SUDO install -m0755 /tmp/rkllm_demo /usr/bin/rkllm_demo || say "WARN: rkllm_demo build failed"
	fi
	if [ -f "$DL/rknn_api.h" ]; then
		g++ buildroot/board/rock4d/rknn_mobilenet.cpp -I "$DL" -L "$DL" \
			-Wl,-rpath-link,"$DL" -lrknnrt -lpthread -lm -o /tmp/rknn_mobilenet \
		  && $SUDO install -m0755 /tmp/rknn_mobilenet /usr/bin/rknn_mobilenet || say "WARN: rknn_mobilenet build failed"
	fi
	# kiln-serve: OpenAI-compatible API server (LLM + optional vision). Header-only
	# httplib+json, links the same librkllmrt/librknnrt. Reuses kiln_llm/vision/config.
	if [ -f "$DL/rkllm.h" ] && [ -f "$DL/httplib.h" ] && [ -f "$DL/json.hpp" ]; then
		g++ -std=c++17 -O2 buildroot/board/rock4d/kiln_serve.cpp -I "$DL" -L "$DL" \
			-Wl,-rpath-link,"$DL" -lrkllmrt -lrknnrt -lpthread -lm -o /tmp/kiln-serve \
		  && $SUDO install -m0755 /tmp/kiln-serve /usr/bin/kiln-serve || say "WARN: kiln-serve build failed"
	fi
	$SUDO install -m0755 buildroot/rootfs/usr/bin/kiln-chat buildroot/rootfs/usr/bin/kiln-vision /usr/bin/
	# login MOTD that reports the phase-2 install outcome (the auto-handoff's
	# success/failure surface). Harmless in manual mode too.
	[ -f buildroot/rootfs/etc/profile.d/kiln-motd.sh ] \
		&& $SUDO install -m0644 buildroot/rootfs/etc/profile.d/kiln-motd.sh /etc/profile.d/kiln-motd.sh || true
	# optional systemd unit for kiln-serve
	if [ -f buildroot/rootfs/etc/systemd/system/kiln-serve.service ] && [ -d /etc/systemd/system ]; then
		$SUDO install -m0644 buildroot/rootfs/etc/systemd/system/kiln-serve.service /etc/systemd/system/
		$SUDO systemctl daemon-reload 2>/dev/null || true
		say "kiln-serve.service installed (disabled). Enable with: sudo systemctl enable --now kiln-serve"
	fi

	$SUDO mkdir -p /opt/models
	for f in test.jpg imagenet_labels.txt coco_80_labels.txt "$MODEL_RKNN"; do
		[ -f "model/$f" ] && $SUDO install -m0644 "model/$f" /opt/models/ || true
	done
fi

# Diagnostic + config + model-conversion CLIs. Installed UNCONDITIONALLY (tiny, and
# useful even on a KILN_SKIP_RUNTIMES run) so they are always on PATH. kiln-convert
# gets/converts models on the board (rknn-toolkit2 in a private venv, lazily).
for t in kiln kiln-doctor kiln-config kiln-convert; do
	[ -f "scripts/$t" ] && $SUDO install -m0755 "scripts/$t" "/usr/bin/$t" || true
done

# Seed the unified config (if absent) so kiln-chat/vision/serve/settings share
# one source of truth. The tools also work with no file (built-in defaults);
# this just makes the vision model SoC-correct and seeds a working config.
$SUDO mkdir -p /etc/kiln
if [ ! -f /etc/kiln/config.ini ]; then
	# LLM model is left EMPTY -- Kiln ships/hard-codes none, and the tools auto-discover
	# any *.rkllm you drop in /opt/models. Set a path here to pin a specific one.
	LLM_MODEL=""
	$SUDO tee /etc/kiln/config.ini >/dev/null <<EOF
# Kiln unified config -- read by kiln-chat, kiln-vision, kiln-serve.
# Edit by hand; kiln-chat can also change the LLM knobs live (/help). Only runtime-settable fields.

[llm]
model = $LLM_MODEL
max_context_len = 2048
max_new_tokens = 512
temperature = 0.7
top_k = 1
top_p = 0.8
repeat_penalty = 1.3
keep_history = 1
system_prompt =

[vision]
model =
labels = /opt/models/imagenet_labels.txt
top_n = 5
core_mask = auto
priority = high

[server]
host = 0.0.0.0
port = 8080
EOF
	say "wrote default /etc/kiln/config.ini (edit by hand; kiln-chat /help for live LLM knobs)"
fi

# --- 7. finish --------------------------------------------------------------
$SUDO depmod -a "$KREL" || true
# Record phase-2 completion: drives the login MOTD, is checked by kiln-doctor, and
# (via the service's ConditionPathExists) stops the auto-handoff oneshot from ever
# re-running. We only reach section 7 in phase 2, so getting here means done.
$SUDO mkdir -p /etc/kiln; $SUDO rm -f /etc/kiln/phase2-failed; $SUDO touch /etc/kiln/phase2-done
if [ "$KERNEL_CHANGED" = 1 ] || { [ "$DRIVER_REBUILT" = 1 ] && [ "$DRIVER_RELOADED" = 0 ]; }; then
	cat <<EOF

[kiln] Installed. REBOOT to load rknpu against the NPU node:

    sudo reboot

After reboot:
  sudo dmesg | grep -i rknpu
      # expect:  RKNPU ... kiln mmu enable_all: ... st=0x19/0x19/0x19/0x19
      # and NO   'failed to get pm runtime for npu0, ret: -110'
  ls /dev/dri/renderD*          # renderD129 (NPU) present
EOF
else
	cat <<EOF

[kiln] Installed. No reboot needed ($([ "$DRIVER_RELOADED" = 1 ] && echo "rknpu already reloaded" || echo "driver unchanged this run")).
  sudo dmesg | grep -i rknpu   # confirm the version/state you expect
  ls /dev/dri/renderD*         # renderD129 (NPU) present
EOF
fi
cat <<EOF

  # vision (needs a MobileNet .rknn matched to librknnrt 2.3.0 in /opt/models):
  kiln-vision /opt/models/test.jpg
  # LLM (put a *-rk3576-w4a16.rkllm in /opt/models):
  kiln-chat

Models are not shipped. Copy your mobilenetv2-12_rk3576.rknn and/or your
*-rk3576-w4a16.rkllm into /opt/models (scp from your dev machine).
EOF
