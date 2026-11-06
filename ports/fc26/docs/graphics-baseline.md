# Graphics baseline

FC26 PS4 graphics are a compatibility target, not a performance knob. The Switch version is not
an acceptable visual reference because its geometry, assets, materials, effects, crowd, and motion
feature set differ from the PS4 build.

## Invariants

- Use the PS4 `CUSA52342` 01.25 executable and PS4 data.
- Start at 1920x1080 internal output with FSR and RCAS disabled.
- Do not lower texture resolution, mip residency, material layers, shadow resolution, crowd detail,
  post-processing, pitch detail, weather, animation, or replay quality to fix stability or FPS.
- Shader or resource fallbacks must preserve the PS4 operation's semantics. A shader-specific skip,
  constant replacement, or disabled pass is not a fix.
- Pipeline and shader caches may remove compilation stutter, but must not change rendered output.

## Fixed validation scenes

Capture every graphics change in these stages using the same teams, stadium, time, weather, camera,
and display configuration:

1. Main menu with animated background and player materials.
2. Pre-match tunnel or player walkout.
3. Kickoff wide camera showing pitch, stadium, crowd, shadows, and HUD.
4. Close player camera showing skin, hair, cloth, kit materials, and motion.
5. Rain match showing wet pitch, reflections, droplets, and stadium lighting.
6. Replay and return to the main menu.

For each stage record a screenshot, the complete log, frame time, shader/pipeline compilation events,
and whether the SRT/descriptor path produced errors. Stable menu rendering does not validate a match.

## Performance order

1. Correct PS4 resource and shader translation.
2. Correct materials, lighting, depth, motion, and post-processing.
3. Eliminate first-use shader and pipeline compilation stalls through verified caches.
4. Measure CPU and GPU frame time separately.
5. Optimize general renderer and synchronization behavior without visual loss.
6. Consider x86-64 to ARM64 recompilation only if Rosetta is a measured CPU bottleneck.

## Verified milestones

### Main menu at 60 FPS

Verified on 2026-11-04 with `CUSA52342` 01.25, 1920x1080 internal output, FSR and RCAS
disabled, a 60 Hz guest-visible vblank clock, and the optional video-out flip-rate override set to
zero. FC26 requested `sceVideoOutSetFlipRate(1)` in the menu; overriding only that presentation
divisor removed the 30 FPS cap without doubling the vblank events observed by game code.

The same run exercised the main menu, deterministic D-pad navigation, entry into Kick Off, its
`Home` / `House Rules` / `Classic Match` submenu, and return to the main menu. Fifteen consecutive
one-second samples were recorded in each stable state:

| State | Minimum FPS | Mean FPS | Maximum FPS |
|---|---:|---:|---:|
| Main menu | 59.997 | 59.999 | 60.001 |
| Kick Off selected | 59.995 | 59.999 | 60.002 |
| Kick Off submenu | 59.996 | 59.999 | 60.002 |
| Main menu after return | 59.996 | 59.999 | 60.000 |

The full 341-row telemetry file is preserved outside the repository at
`FC26_DATA_DIR/reports/menu-60-verified.csv` with SHA-256
`221256c94a47cff0e6fe74c862359c09e3ff4fd3b1935b4465086755fb243345`. The clean shutdown
preserved a content-addressed cache containing 699 shaders and 595 pipelines, SHA-256
`4d13566fd74ed3e27710be263545e0a294a13d4f89f161dde664615302db6abd`.

This milestone proves menu presentation, menu input, Kick Off entry and return, cache preservation,
and sustained menu frame pacing. It does not validate match rendering, player materials, effects,
audio, save behavior, or gameplay performance; those remain separate fixed-scene gates above.

### Match base

Validated on 2026-11-05 by playing a full Kick Off match (Man Utd vs Liverpool, dry weather) with
the controller, with the defaults of `scripts/run.sh` and the shader cache built by the earlier
pass-v2 runs. The player judged it the stable base: no artifacts while playing, LED boards and
the ball correct, occasional flashes in cinematics.

| Scene | Seconds | Mean FPS | Notes |
|---|---:|---:|---|
| Play and menus (under 600 draws) | 233 | 52.5 | minimum 20.7; 54% of the seconds at 60 |
| Cinematics and replays | 105 | 31.1 | the game caps replays at 30 |

Telemetry: `FC26_DATA_DIR/reports/match-base-2026-11-05.csv`, SHA-256
`53feaf13d8aa4085c997d9cf9eac60a4ea3851839278c112a779029bdd4d8018`. Shader cache after the run:
1511 shaders and 1556 pipelines, SHA-256
`e083526138ee5af0a719947005fadbdb7a340b395e177a92a9f4bfe660682e60`.

Defaults that define the base:

- `SHADPS4_DEFER_UPLOADS=1`: buffer uploads whose destination the session has not used yet run
  before the session instead of ending the open render pass (31 to 43 FPS in play).
- `SHADPS4_ASYNC_IMAGE_READBACK=1` with readback fence lag -1: the 1x1 luminance ring is read back
  without draining the GPU; a probe that filled pending targets with a bright value never reached
  the screen.
- `SHADPS4_FAULT_EXPAND=1`: one fault per hot 64 KB block (42% fewer faults); every clean session
  ran with it, and the one run without it was not clean.
- GPU memory budget on unified memory: half of the heap (19169 MiB on a 48 GB Mac) instead of the
  2 GB floor, because KosmicKrisp reports a 6 GB heap budget. With the floor, the texture cache
  evicted about ten images a second and evictions downloaded images over memory the game had
  reused: black and exploded geometry, noise tiles. In the validated match no eviction downloaded
  an image (1125 evictions, 0 hash checks, 0 downloads).
- Fragment-shader dynamic table reads go through SRT-sized windows (profile `0x81`).

Known issues in the base, to be fixed one at a time and validated against these scenes before
they join it:

1. Goalkeepers sometimes wear the outfield kit. With a warm shader cache it happened in two of
   three runs of one build and data folder on 2026-11-05 and not in the third, so the cache alone
   does not decide it. The kit is decided while the match loads.
2. Occasional flashes or artifacts in cinematics.
3. Play still drops below 60 in heavier camera angles; the GPU thread (`GpuCommandProcessor`) is
   the bottleneck at 80-90% of a core while the Mac GPU sits near 55%.

### Second base: the 60 FPS commits

On 2026-11-05 the user declared the match base plus the ten commits of branch
`fc26-perf-metalfx` the new base (tag `fc26-base-2026-11-05b`). They add two options that stay
off by default, MetalFX upscaling and PS4 Pro mode (below), and diagnostic switches that only act
when their variables are set. With the defaults the code paths of the match base are unchanged.
The runs recorded below had MetalFX on; a match with this base's defaults is still to be played.

### Option: MetalFX upscaling (off by default)

Branch `fc26-perf-metalfx`, recorded on 2026-11-05 with a 1600x900 point window (3200x1800
pixels). Covered: main menu, Kick Off screen, kickoff wide camera and play, pause menu; MetalFX and
the bilinear path compared in the same run with `SHADPS4_METALFX_OFF_FILE`. Not covered: tunnel or
walkout, close player camera, rain match, replay and return to the menu. Frame cost and design are
in `docs/gpu-thread-research.md`; it stays off by default.

Second recording, same day, with the scaler waited for on the presenting thread (`415fc971`) and
a warm pipeline cache (8 graphics pipelines compiled in the whole run): Manchester United against
Liverpool at Old Trafford, in rain. Covered:
- match intro card, kickoff wide camera and play;
- replays and their Premier League transitions;
- close-ups with depth of field, and the high replay camera.

The home goalkeeper wore his own kit, and the user confirmed it in the same run. The high replay
camera shows straight dark diagonal lines and drops on the lens; they look like the camera's cable
rig and the rain, but they were not compared with the scaler off. Still not covered: tunnel or
walkout, a played match from kickoff to the final whistle, and return to the menu.

### Experimental option: PS4 Pro mode (off by default)

`FC26_PS4_PRO=1`, recorded on 2026-11-05.
- Setup: build `415fc971`, MetalFX on, a 1600x900 point window, warm cache.
- One run per mode through Kick Off, Manchester United against Liverpool. The Pro run had rain;
  the base run had dry weather.

Results:
- **Output resolution:** the game registers 1920x1080 buffers in both modes, because the reported
  display is 1080p (`GPU.internal_screen_width/height`). It has not been tested with a reported 4K
  display.
- **Play, 165 one-second samples per mode:** the weather differed, so these small gaps are within
  scene noise.

  | | Pro | Base |
  |---|---|---|
  | FPS | 51.3 | 52.5 |
  | GPU device utilization | 53.0% | 54.4% |
  | GPU renderer utilization | 69.4% | 64.4% |
  | Draws per frame | 549 | 526 |

- **Shader compiles:** 5 new graphics pipelines in the first Pro run, about 2 s of compile time in
  menus and at kickoff. None in the base run.
- **New defect with Pro:** the controlled-player triangle has a square of noise around it where
  the icon should be transparent. The base mode draws it clean in the same build.
- **Unchanged as far as the screenshots show:** LED boards, the ball, crowds and kits. The user
  found the image good apart from the icon.
- **Goalkeeper:** he wore the outfield kit in both runs (known issue 1), so Pro mode is not its
  cause.

Tried and removed because they caused regressions or showed no gain: a 64 KB head for unbounded
buffers in session tracking (exploded crowd-card geometry), the eviction sentinel for clean images
(lost GPU-made textures: LED boards, ball, goalkeeper legs), render-pass merges for clear flags
and read-after-read barriers (no FPS change), KosmicKrisp MRs !45568 and !45950 (no gain here).

