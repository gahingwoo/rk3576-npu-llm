# Contributing to Kiln

Thanks for helping put the RK3576 NPU on a mainline kernel. Kiln is a small,
honesty-first project — these notes keep it that way.

## The most useful thing you can do

**Test on hardware and report back — especially a board that isn't the ROCK 4D.** The
ROCK 4D (RK3576) is the *only* board Kiln has run on. Other RK3576 boards and the RK3568
(ROCK 3B) path are implemented but unverified. If you have one:

1. Run the installer, then `sudo kiln-doctor`.
2. Try `kiln-vision /opt/models/test.jpg` and (if you have a `.rkllm`) `kiln-chat`.
3. Open an [issue](https://github.com/gahingwoo/kiln/issues) with the **full
   `kiln-doctor` output**, `sudo dmesg | grep -iE 'rknpu|npu|iommu'`, and what worked or
   didn't. Wins, failures, and dmesg are all valuable — a failure with a log turns
   "should work" into a fix.

## Ground rules (how Kiln is built)

These are non-negotiable because they're what makes the project trustworthy:

- **Don't fake capability.** Never claim support for something that isn't actually
  verified. "Implemented but untested" is a fine, honest state — label it that way
  (the code and docs do). No stubs pretending to be features.
- **Falsification first.** Before "fixing" a problem, confirm it exists at the specific
  `file:line`. Trust the code over the description.
- **`/etc/kiln/config.ini` is the hand-editable source of truth.** Tools edit it *in
  place*, preserving comments and unknown fields — never a full rewrite. `kiln-config` is
  a front-end, not a replacement.
- **Kiln bundles no models.** Users supply them (like the vendor stack). Respect model
  licenses (Ultralytics YOLO is AGPL-3.0; MobileNet/YOLOX are permissive).
- **Small, reviewable commits**, one concern each, and **update the docs with the
  behaviour** in the same change.
- **Everything idempotent / re-runnable** — the installer and fetch scripts must be safe
  to run twice.

## Code conventions

- **Shell tools** (`kiln`, `kiln-config`, `kiln-doctor`, `kiln-convert`) are POSIX `sh`
  where they can be (busybox-friendly); the installer is `bash`. TUIs use `whiptail`
  (fallback `dialog`). Match the surrounding style.
- **C++** tools (`kiln-chat`, `kiln-vision`, `kiln-serve`) share `kiln_config.h` /
  `kiln_llm.h` / `kiln_vision.h` / `kiln_detect.h` — reuse the runtime wrappers, don't
  re-implement the inference call sequence.
- **Comments, code, and commit messages in English.** (Discussion in issues can be in any
  language.)
- Keep runtime/model **version-locks** intact: `librkllmrt` 1.2.0, `librknnrt` 2.3.x.

## Building & checking locally

- Shell: `sh -n <script>` / `bash -n <script>` for a syntax check.
- C++ demos: `g++ -std=c++17 -fsyntax-only -I buildroot/dl buildroot/board/rock4d/<file>.cpp`
  (after `bash buildroot/fetch-runtimes.sh` stages the headers).
- Health: `kiln-doctor` on a board is the integration test.

## Scope

- **Kernel / NPU-bring-up** changes: see [`kernel-patches/README.md`](kernel-patches/README.md)
  and [`driver/patches/README.md`](driver/patches/README.md).
- **New board support**: needs that board's DTB with the NPU node + the `vdd_npu`
  regulator fix, plus SoC detection in `kiln-install.sh`. See [`docs/RK3568.md`](docs/RK3568.md)
  for the pattern.

## License

Kiln is GPL-2.0 (it wraps the GPL vendor `rknpu` driver). The user-facing tool sources
(`buildroot/board/rock4d/*`) are Apache-2.0. The closed `librkllmrt`/`librknnrt` runtimes
are Rockchip's and are fetched, not redistributed. By contributing you agree your changes
ship under these terms.
