# EA SPORTS FC 26 PS4 port for macOS

This directory is the game-specific integration layer for running the PlayStation 4 version of
EA SPORTS FC 26 on Apple silicon. It lives in the `MathiasKowoll/shadPS4` fork so improvements from
the general emulator can be rebased into the port without maintaining a detached engine copy.

The current milestone is a reproducible bring-up environment, not a completed standalone native
port. The PS4 x86-64 executable currently runs through Rosetta 2, while shadPS4 provides PS4 system
services and translates the Liverpool/GCN graphics path through Vulkan to KosmicKrisp and Metal.
CPU recompilation can be evaluated later, after CPU and GPU frame times show where it is useful.
The planned post-Rosetta path is a replaceable FEX-based CPU backend, tracked in
`docs/cpu-backend.md`; it is deliberately not on the critical path for graphics bring-up.

## Supported build

- Title ID: `CUSA52342`
- App version: `01.25`
- Profile: `profile.json`

Only files dumped from a legally owned copy may be used. This repository contains no game files,
keys, shaders, or extracted assets.

## First run

The defaults match the local development layout. Override them with environment variables when
needed:

```sh
cd /Users/mathias/Development/fc26-ps4-port
ports/fc26/scripts/build.sh
ports/fc26/scripts/run.sh --check
ports/fc26/scripts/run.sh --verify
ports/fc26/scripts/run.sh
```

Install the dedicated Finder launcher with:

```bash
ports/fc26/scripts/install_launcher.sh
```

This creates `/Applications/EA SPORTS FC 26 Port.app`. Open that application instead of
double-clicking the raw `port-build/shadps4` CLI binary. The launcher remains connected to this
worktree's `run.sh`, which supplies the game path, isolated data directory, Vulkan driver and
runtime settings.

`FC26_RUN_PROFILE=performance` is the default and disables diagnostic logging for representative
frame-time measurements. Use `FC26_RUN_PROFILE=diagnostic` only while collecting a targeted log;
all other saved preferences remain in the port data directory.

Variables:

- `FC26_GAME_DIR`: merged PS4 game directory containing `eboot.bin` and `sce_sys/param.sfo`.
- `FC26_DATA_DIR`: external work directory for configuration, saves, logs, and shader caches.
- `FC26_BUILD_DIR`: external CMake build directory for the `fc26-port` worktree.
- `FC26_FULLSCREEN`: `true` or `false`; defaults to `false` during bring-up.
- `FC26_CONFIG_MODE`: `preserve` (the default) keeps the port's own preferences, or `managed` for
  a clean reproducible test configuration.
- `FC26_RUN_PROFILE`: `performance` (the default) or `diagnostic` for asynchronous logs.
- `FC26_NETWORK`: `preserve` (the default) keeps the isolated port preference, `online` enables
  the guest's normal network access, and `offline` disables it. Menu video configuration is dynamic
  content and requires an online run before it can be cached.
- `FC26_LOG_FILTER`: logging classes used by the diagnostic profile; defaults to warnings plus
  Vulkan information and is ignored by the performance profile.
- `FC26_METRICS`: `1` (the default) writes one frame-time sample per second; `0` disables it.
- `FC26_METAL_HUD`: `1` enables Apple's Metal performance HUD for diagnostic runs; `0` (the
  default) keeps it disabled for uncontaminated frame-time measurements.
- `FC26_METALFX`: `preserve` (the default) keeps the saved preference, `1` enables the MetalFX
  spatial upscaler for the presented image, and `0` disables it. See "MetalFX upscaling" below.
- `FC26_VBLANK_FREQUENCY`: host vblank rate from 30 to 240 Hz; defaults to the PS4 baseline of 60.
- `FC26_FLIP_RATE_OVERRIDE`: defaults to `0` for the 60 FPS port; use `auto` to honor the game's
  requested 30 FPS presentation divisor.
- `FC26_TRACE_IMPORTS`: optional diagnostic rules in `importer->library` form, separated by
  semicolons. It is unset during normal runs and adds no import wrappers unless explicitly enabled.

`--check` performs a quick identity and size check. `--verify` also checks SHA-256 for the executable
and all profiled PRX modules. `--dry-run` prints the launch command without starting the game.

### Firmware modules for menu media

FC26 imports the PS4 JSON runtime used by its dynamic-content configuration. The menu-video path
also reaches the PS4 audio decoder once playback starts. The port therefore reports readiness for
`libSceJson.sprx`, `libSceJson2.sprx`, and `libSceAudiodec.sprx` during `--check` and launch. A
missing module is a warning rather than a general boot failure: gameplay and static menu rendering
can still work while dynamic menu media remains unavailable.

Put modules dumped from your legally owned PS4 in the isolated port directory:

```text
<FC26_DATA_DIR>/user/sys_modules/
```

The launcher never downloads, bundles, or copies proprietary firmware modules. The supported
module list and legal-dump requirement come from the
[shadPS4 firmware-file documentation](https://github.com/shadps4-emu/shadPS4#firmware-files).

The launcher runs from `FC26_DATA_DIR`, where a portable `user/` directory isolates FC26 settings
and caches from the normal shadPS4 installation. Its default location is
`/Volumes/CrucialX8/Emulation/Ps4/FC26/port-data`, analogous to NXNative's per-title Application
Support folder but kept on the external drive with the game. `user/config.json` stores emulator
preferences, `user/input_config/` stores controls, and
`user/home/1000/savedata/CUSA52342/` stores the FC26 save. Shader and pipeline data lives in
`user/cache/CUSA52342.zip`, with validated snapshots under `shader-cache/`.

On the first run the launcher seeds `user/config.json` from the port-owned `config/managed.json`;
later runs preserve changes made through the UI. This avoids shadPS4's interactive legacy-config
migration dialog while giving FC26 its own persistent preferences. Set `FC26_CONFIG_MODE=managed`
for an unattended clean-baseline test that must reinstall the deterministic 1920x1080 configuration
with no FSR or resolution reduction. The performance profile disables logging so synchronous console
and file output do not distort frame-time measurements. The diagnostic profile keeps warning, error,
and Vulkan compilation messages, but writes them asynchronously.

The launcher enables the engine's optional low-frequency frame telemetry and writes the current run
to `metrics/last-run.csv`, rotating the preceding run to `metrics/previous-run.csv`. This measures
the same smoothed frame rate used by the on-screen HUD without screenshots or synchronous logging.

FC26 requests `sceVideoOutSetFlipRate(1)` in its menu, which presents one frame every two PS4
vblanks. The port keeps the guest-visible vblank clock at its normal 60 Hz and overrides only that
presentation divisor to zero. Raising the guest vblank frequency to 120 would also double the
vblank events observed by game code, so it is retained only as an explicit diagnostic option.

The default build and data directories are on the external FC26 volume. The source checkout remains
small enough to rebase normally, while generated objects and shader caches do not consume the main
disk or enter Git. `build.sh` also creates a private Python environment inside the external build
directory for the pinned Mesa/KosmicKrisp build dependencies.

## MetalFX upscaling

The game still renders at 1920x1080. With `GPU.metalfx_enabled` (or `FC26_METALFX=1`), the
presenter scales that image to the window's real pixel size with Apple's MetalFX spatial scaler
instead of the bilinear filter, as an alternative to FSR. It is off by default and can also be
toggled in the developer menu under Display > MetalFX.

- The window is created with high pixel density while the option is enabled, so on a Retina
  display the presented image is sized in physical pixels (a 1600x900 window draws 3200x1800).
  Without it macOS draws the window at point size and stretches it, and no upscaler can help.
- KosmicKrisp has no `VK_EXT_metal_objects`. The scaler images are allocated as dedicated memory
  whose MTLHeap is exported with `VK_EXT_external_memory_metal`; a Metal texture with the same
  descriptor KosmicKrisp uses is placed at offset 0 of that heap. The post-processing pass renders
  the game image into the input at 1920x1080, MetalFX runs on its own Metal queue after that
  submission completes, and the copy into the presented frame waits for a timeline semaphore
  that the Metal command buffer signals from the host when it finishes.
- `SHADPS4_METALFX_OFF_FILE=<path>` is a diagnostic A/B switch: while the file exists, frames use
  the regular presentation path in the same run.

## Shader cache

Every run preserves validated, content-addressed snapshots of the FC26 shader and pipeline cache.
Use `ports/fc26/scripts/shader_cache.py status` to inspect the current cache or
`ports/fc26/scripts/shader_cache.py snapshot --label <scene>` to mark a manual checkpoint. The
snapshots remain under `FC26_DATA_DIR` and are never added to Git. See
[`docs/shader-cache.md`](docs/shader-cache.md) for compatibility and prewarm details.

The launcher validates the active cache before and after each run. If shadPS4 aborts while writing
the archive, the incomplete file is preserved under `shader-cache/partial/` and the latest valid
snapshot is restored for the next run.

## Upstream synchronization

Run this from a clean `fc26-port` worktree:

```sh
git fetch upstream
git rebase upstream/main
```

Resolve conflicts only in port-owned files unless the branch contains a general emulation fix.
After every rebase, rebuild, run `--verify`, boot the same graphics baseline, and compare logs and
captures before accepting the update. See `docs/upstream.md`.

