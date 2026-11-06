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
- `FC26_PS4_PRO` (experimental): `preserve` (the default) keeps the saved preference, `1` reports a
  PS4 Pro to the game (`General.neo_mode`), which FC26 declares support for, and `0` reports a base
  PS4. The validated baseline is the base PS4; `docs/graphics-baseline.md` lists what Pro mode
  changes.
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
  the game image into the input at 1920x1080, and MetalFX runs on its own Metal queue after that
  submission completes. The Metal command buffer signals a timeline semaphore from the host when
  it finishes; the presenting thread waits for that value before it copies the output into the
  presented frame, so the game's Vulkan queue never waits for the scaler.
- `SHADPS4_METALFX_OFF_FILE=<path>` is a diagnostic A/B switch: while the file exists, frames use
  the regular presentation path in the same run.
- In the same play scene with vsync it held 60.0 FPS with and without the scaler, and the
  emulator's waits for GPU results were about the same. A CPU-bound comparison in one scene is
  still missing. Measurements are in `docs/gpu-thread-research.md`.

## Player launcher

`scripts/install_launcher.sh` installs the development launcher, which runs this worktree's
`run.sh`. For other players, `scripts/package.sh` assembles a self-contained application around a
native launcher, so a player needs only the app, their own dump of `CUSA52342` 01.25 and,
optionally, system modules dumped from their own PS4:

```sh
FC26_BUILD_DIR=/path/to/engine-build ports/fc26/scripts/package.sh
```

The script compiles the SwiftUI launcher in `launcher/Sources/` for arm64 and writes
`FC26Port-<version>-<engine revision>-macos-arm64/` with the application, a zip archive and its
SHA-256; when the launcher comes from a later commit than the engine, the name carries both
revisions. It never overwrites an existing package. The application contains:

- `Contents/MacOS/`: the launcher, the x86-64 `shadps4` engine, the `libvulkan.dylib` loader and
  `libvulkan_kosmickrisp.dylib`, with debug symbols stripped, plus a link to the KosmicKrisp ICD.
  The engine points the Vulkan loader at its own folder, so the ICD must be reachable there.
- `Contents/Resources/`: `profile.json`, the port's `managed.json`, the ICD, `build-info.json` with
  the engine and KosmicKrisp revisions, and `licenses/` copied from the engine source tree.

Nothing from the game is packaged. The script stops if the bundle contains game files, firmware
modules or shader binaries, and it stops if a binary embeds `/Users/` or `/Volumes/` paths.
`build.sh` records the revision it built in `fc26-build-info.json` in the build directory; for
older builds the script reports the source checkout's current revision instead.

Variables:

- `FC26_BUILD_DIR`: engine build directory with `shadps4`, both dylibs, the ICD, and either the
  `fc26-build-info.json` written by `build.sh` or a `CMakeCache.txt` naming the source checkout,
  whose initialized submodules provide the third-party licenses.
- `FC26_PACKAGE_DIR`: output directory; defaults to
  `/Volumes/CrucialX8/Emulation/Ps4/FC26/port-package`.
- `FC26_SIGN_IDENTITY`: `-` (the default) signs ad hoc; see signing below.
- `FC26_PACKAGE_ALLOW_BUILD_PATHS`: `1` allows a local test package whose binaries still contain
  source paths from assertion messages. Current builds contain them; see the checklist below.

### What the launcher does

1. Game folder: reads `sce_sys/param.sfo` and checks the title ID, the app version and the size of
   every profiled file against `profile.json`. It accepts a merged dump or a base dump with the
   update next to it as `CUSA52342-UPDATE` or `CUSA52342-patch`, the layout the engine overlays.
   Errors name the problem: another game, an older or newer version, a missing or truncated file.
   A `CUSA52342-mods` folder is reported, because the engine loads it over the game unchecked.
   SHA-256 verification runs in the background and is remembered while the files are unchanged; a
   mismatch is a warning, because a dumper can write the same content differently.
2. Player data: one folder per player, by default
   `~/Library/Application Support/FC26 Port/Players/<name>`, or any folder the player chooses. It
   holds the engine's portable `user/` directory (settings, saves, system modules, shader cache),
   `logs/`, `metrics/`, `shader-cache/` and `launcher.json`. The first use seeds
   `user/config.json` from `managed.json` and, when the folder holds no saves or trophies in
   shadPS4's old locations, creates `user/home/1000/`, so the engine does not stop at its
   save-migration question on a new folder. The folder pickers and Play refuse game and player
   folders that contain each other.
3. System modules: shows whether `libSceJson.sprx`, `libSceJson2.sprx` and `libSceAudiodec.sprx`
   are in `user/sys_modules/`, explains that they come from the player's own console, and copies
   chosen `.sprx` files there after checking for an ELF or SELF header. Missing modules are a
   warning, as in `run.sh`: the section always shows them, and Play asks once per player.
4. Squads: Install Squads takes a PS4 squads save of FC 26, as a folder or inside a `.zip`
   (for example a community update), checks that its `param.sfo` is a save of `CUSA52342` and
   its `DATA` is a `SaveType_Squads` body, and copies `DATA`, `INDEX`, `NAME`, `param.sfo` and
   the icon to `user/home/1000/savedata/CUSA52342/<SAVEDATA_DIRECTORY>/`, with the param.sfo
   `ACCOUNT_ID` set to zero like the emulator's own saves. A save with the same name is moved to
   `save-backups/` first. The game loads it from Customize > Profile > Load > Squads; loading an
   installed community save has not been confirmed in the port yet.
5. Settings: fullscreen, frame-rate counter, upscaling, PS4 Pro mode (experimental,
   `General.neo_mode`), the Metal HUD and a detailed log. New player folders start in fullscreen
   with the frame-rate counter on, so macOS Game Mode turns on (below); the rest is off.
   Upscaling is one choice: Bilinear (the default, the presenter's plain filter), FSR with
   optional RCAS, or MetalFX; the engine prefers MetalFX when both are set. Engine settings live
   in the player's `user/config.json`, as with `FC26_METALFX` and `FC26_PS4_PRO` in `run.sh`; the
   Metal HUD and log choices in `launcher.json`.
6. Play: applies the defaults of `run.sh`'s performance profile (60 Hz vblank, the game's own
   flip rate with no override, so menus run at 30 as the game asks and play at 60, logging off or
   the diagnostic filter, `SHADPS4_DEFER_UPLOADS`, `SHADPS4_ASYNC_IMAGE_READBACK` and
   `SHADPS4_FAULT_EXPAND` set to 1, frame metrics in `metrics/last-run.csv`) and starts the engine
   from the player folder. It refuses to start without Rosetta 2, while another
   shadPS4 engine runs (also under a renamed binary such as `shadps4.diag`), or while another
   launcher uses the same player folder. The first run with an empty
   shader cache explains that early runs stutter while shaders compile.
7. Shader cache: before and after every run the launcher tests `user/cache/CUSA52342.zip`.
   Import copies a valid `CUSA52342*.zip` from another player or port data folder into the
   player (the previous cache is kept as `shader-cache/replaced.zip`) and remembers it in the
   user default `ShaderCacheSeed`; player folders created later start with a copy of it, so the
   engine builds those pipelines at boot instead of compiling them during play. A cache made by
   a different engine profile is set aside by the engine. Packages never contain a cache. A
   valid archive is copied to `shader-cache/backup.zip`; an archive left incomplete by a crash is
   kept as `shader-cache/damaged.zip` and replaced by that backup, or by the latest `run.sh`
   snapshot in a development data folder. Quitting the launcher waits for the check after a run.
8. Logs: each run writes `logs/last-run.console.log` with a header naming the engine revision,
   game, player folder and settings, and keeps the previous run next to it. The detailed log goes
   to `user/log/`. The launcher shows both, and the exit code after an unexpected stop.

macOS Game Mode: `gamepolicyd` recognizes the engine as a game from `GCSupportsGameMode` in the
Info.plist embedded in `shadps4` (it logs `labelReason=LSSupportsGameMode`) and turns Game Mode
on while the game is fullscreen and in front. Measured on 2026-11-05 with package
`FC26Port-0.1-1bc7c95c3ff7`, MetalFX on: on within 0.5 s of the fullscreen window, paused each
time another app came to the front and on again when the game returned, off when the game quit.
In a window it stays off. `log stream --predicate 'process == "gamepolicyd"'` shows the
transitions (`Game mode status is now on`).

Players need Apple silicon, macOS 26 or later (the engine's deployment target) and Rosetta 2;
the launcher shows the `softwareupdate --install-rosetta --agree-to-license` command when Rosetta
is missing. It stores the chosen game folder and recent players in the user defaults of
`com.mathiaskowoll.fc26-port`.

### Signing and notarization

The default ad-hoc signature is enough on the Mac that built the package. A copy downloaded from
the internet is quarantined and Gatekeeper blocks it until the player chooses Open Anyway in
System Settings > Privacy & Security, or removes the attribute with
`xattr -dr com.apple.quarantine "EA SPORTS FC 26 Port.app"`.

When the game or the player folder is on an external drive, macOS asks once whether the launcher
may access files on removable volumes; the engine inherits that permission. An ad-hoc signature
is a new identity for these privacy settings, so macOS asks again after every rebuild or update.

To avoid both, sign with a Developer ID and notarize. `FC26_SIGN_IDENTITY="Developer ID
Application: <name> (<team>)"` signs every binary with the hardened runtime and gives the engine
`launcher/engine.entitlements`: `allow-unsigned-executable-memory` for the guest code the engine
maps, `disable-library-validation`, and `audio-input`. The launcher gets
`launcher/launcher.entitlements` with `audio-input`, because macOS attributes the engine's
microphone use to the app that started it. The hardened runtime ignores the
`DYLD_LIBRARY_PATH` the launcher passes, which is harmless: the engine finds `libvulkan.dylib`
through its `@executable_path` rpath. This path has not been validated with the engine yet; test
a signed package through a full boot before notarizing it with
`xcrun notarytool submit <zip> --keychain-profile <profile> --wait`, then
`xcrun stapler staple` the application and archive it again.

### Before publishing

- Package from a clean engine build of a pushed revision, so the GPL source of the binaries is
  available; `build-info.json` and the archive name record the revision.
- Rebuild `shadps4` and KosmicKrisp with source path remapping (`-ffile-prefix-map`); until then
  `package.sh` stops on the source paths in their assertion messages. KosmicKrisp is built by
  Meson through `externals/mesa-kosmickrisp`, which has no option for extra compiler flags yet.
- Review the third-party licenses collected in `Contents/Resources/licenses/`.
- Choose between ad-hoc signing and Developer ID with notarization.

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

