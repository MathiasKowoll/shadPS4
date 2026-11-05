# GPU command thread: options for 60 FPS

FC26 holds 60 FPS in menus but drops in play (52.5 FPS mean in the validated match base, minimum
20.7) and in cinematics. The bottleneck is the emulator's `GpuCommandProcessor` thread at 80-90% of
one core while the Mac GPU sits near 55%: the GPU waits for commands. The goal is 60 FPS with
vsync everywhere except the replays the game itself caps at 30, so the target is the worst play
camera angles, not the mean.

Measurements from 2026-11-05 on the M4 Max, branch `fc26-perf-metalfx` (base `01079bde` plus the
commits listed in the last section), data copied from `port-data-dma-srt-preload-r2`.

## Method

- Scenes differ more between runs than options do, so options are compared inside one run with
  diagnostic switch files (`SHADPS4_*_FILE`, `KK_*_FILE`): the file is toggled every 30 s and each
  window is summarised from the one-second frame metrics after 6 s of settling. Windows whose
  draw counts differ a lot are different scenes and are not compared.
- `threadcpu` (per-thread CPU from `proc_pidinfo`) gives the real load of each thread; `sample`
  under Rosetta reports blocked threads as running, so waits are removed by their call frames.
  `sample` itself stalls the game for its duration.
- The emulator binary has a fixed load address (`0x700000000000`) that `atos` does not resolve;
  frames are named from the `nm` symbol table, which charges inlined code to the preceding
  symbol. Library boundaries (emulator code calling into KosmicKrisp, libc++ or the system) are
  exact.

## Where the GPU command thread spends its time

`sample` of the `GpuCommandProcessor` thread in match play, record-time encoding (the default),
503 busy samples out of 640:

| Part | Share of busy time |
|---|---:|
| Emulator code itself | 44.5% |
| KosmicKrisp and the Metal calls it makes | 40.8% |
| System calls made directly by emulator code (mostly `memcpy` in `CopySparseMemory`, `mprotect`) | 11.1% |
| libc++ and malloc | 3.6% |

Inside KosmicKrisp: `vkCmdDraw` 8.3%, `vkCmdDrawIndexed` 7.6%, `vkCmdBeginRendering` 5.8%,
`vkCmdEndRendering` 3.8%, `vkUpdateDescriptorSets` 3.0%, `vkResetDescriptorPool` 2.4%,
`vkCmdDispatch` 2.4%, `vkAllocateDescriptorSets` 2.2%, `vkCmdBindPipeline` 1.8%. KosmicKrisp creates
the Metal render encoder lazily at the first draw of a pass and ends every encoder with a full
`barrierAfterStages(all, all)`, so pass breaks are paid in `BeginRendering`, `EndRendering` and the
next draw, which re-emits all graphics state.

Frame metrics in the same runs: 44-60 render passes per frame in play, 77 in the 3D main menu,
92 while the Kick Off screen loads; about 19-25 CPU waits for GPU results per second in play,
blocking the thread for 150-180 ms of every second.

## Experiments

### Encoding Metal commands on a KosmicKrisp submit thread

Prototype: `ports/fc26/patches/kosmickrisp-deferred-encoding.patch` (KosmicKrisp only, opt-in with
`KK_DEFERRED_ENCODING=1`). Primary command buffers only enqueue their commands into Mesa's
`vk_cmd_queue`, which KosmicKrisp already uses to re-record command buffers that are submitted more
than once; a `kk-submit` worker thread executes every submission in order, replaying deferred
command buffers into fresh Metal command buffers, committing them and issuing the queue's event
waits and signals. Submissions that carry a drawable drain the worker first, because the Metal WSI
presents the drawable right after the submission returns. `KK_DEFERRED_ENCODING_OFF_FILE` switches
new command buffers back to record-time encoding in the same run.

- A standalone Vulkan test (fill, copy, barriers, dynamic rendering clear, image readback,
  timeline waits and signals, pool resets) passed 200 iterations in both modes.
- In FC26 the menus, the match and the shutdown were correct in both modes; no device loss.
- `GpuCommandProcessor` busy samples in play: 503 with record-time encoding, 334 deferred (-34%);
  KosmicKrisp's share of that thread fell from 40.8% to 12.0% (descriptor pools, command buffer
  begin and end, enqueueing). The `kk-submit` thread was busy 22% of the time.
- `threadcpu` of `GpuCommandProcessor` at about 60 FPS: 77-81% record-time, 37-68% deferred.
- FPS: the comparable windows were vsync-bound at 60 in both modes, so the freed time did not show
  as frames. Over four pairs, 50.9 FPS deferred and 53.0 FPS record-time (paired -2.1 +- 7.9,
  dominated by a heavy last pair); seconds below 50 FPS: 28 and 22 per 100 s. CPU waits for GPU
  results were the same in both modes (18.8 and 18.9 per second, 142 and 148 ms per second).
- Open issue: deferral moves the encoding of everything still queued in front of each CPU wait,
  and of every present, into that wait. Encoding while the command buffer is still being recorded
  (streaming the `vk_cmd_queue` to the worker) would keep that latency low.

### Extra render pass breaks

`SHADPS4_EXTRA_PASS_SPLIT_FILE` ends the render pass after every 12th draw. With it, FC26 showed
large noise tiles over the pitch and crowd in play, while the alternating windows without it were
clean (same run, same build). A render pass that is ended and begun again with load operations
therefore does not keep its attachments on this stack. The base already breaks passes about 13
times per frame for late layout transitions, which makes this a candidate cause of the known
occasional artifacts in cinematics. The cost of a pass break could not be measured this way.

The switch file can also hold a mode, to narrow down which attachments lose their contents:

| Mode | Passes that are broken |
|---|---|
| 1 | every pass |
| 2 | every pass, plus a full memory barrier |
| 3 | passes without a depth or stencil attachment |
| 4 | passes with a depth or stencil attachment |
| 5 | single-sample passes |
| 6 | multisampled passes |

A later match on the same day ran each mode for seven seconds, in replays, close-ups and the wide
camera. None of the saved images showed noise tiles, so the corruption is not yet tied to one kind
of attachment. Mode 1 never ran in play in that match, so mode 2's clean play frames say nothing
about the barrier yet. The noise appeared within 30-second windows of play, so each mode needs at
least that long in play.

## Ranked options

Expected gains are for CPU-bound play scenes, where frame time follows the GPU command thread.

1. **Metal encoding off the GPU command thread** (prototype above). Measured: a third less busy
   time on the thread that limits the frame rate, correct rendering. Next: stream commands to the
   worker during recording so CPU waits and presents do not pay for encoding, then measure with
   long A/B runs in CPU-bound play and cinematics. Risk: driver threading and ordering; this is a
   KosmicKrisp change.
2. **Fewer CPU waits for GPU results.** 150-180 ms of every second in play are spent waiting in
   `Scheduler::Wait`/`Finish` for buffer readbacks (images already read back asynchronously).
   Asynchronous buffer readbacks, or holding only the signals that depend on them, would return
   most of that time. Risk: stale CPU-visible data if a wait is removed that the game relies on.
3. **Find why a broken render pass loses its attachments**, then remove late breaks by issuing the
   barriers before the pass begins. This could fix cinematic artifacts and saves the encoder
   restarts (`BeginRendering`+`EndRendering` 9.6% of the thread plus state re-emission).
4. **Descriptor set churn**: `vkUpdateDescriptorSets`, `vkResetDescriptorPool` and
   `vkAllocateDescriptorSets` take 7.6% of the thread for the pipelines that cannot use push
   descriptors.
5. **Skip unchanged per-draw bindings** (`BindBuffers` 21%, `BindTextures` 18% inclusive in the
   earlier profile) with an epoch from the memory tracker and texture cache. Risk: stale bindings.
6. **Smaller items**: `CopySparseMemory` copies (about 8%), graphics key refresh by dirty registers
   (about 8%), image hashing in `MarkAsMaybeGpuDirty` (about 6%).

Not on this list: lowering render resolution or quality (excluded by the port rules), and the
replays, which the game itself renders at 30 FPS. Reaching 60 there needs either a game patch for
the replay frame limiter or frame interpolation; MetalFX frame interpolation needs motion vectors
and depth that the presenter does not have.

Already tried without gain or with regressions: a 64 KB head for unbounded buffers, the eviction
sentinel for clean images, clear-flag and read-after-read pass merges, KosmicKrisp MRs !45568 and
!45950.

## MetalFX upscaling

See the README section "MetalFX upscaling" for the design. A 1600x900 point window with the option
enabled presents 3200x1800 pixels.

- Standalone x86_64 test under Rosetta: 0.47 ms of GPU time from 1920x1080 to 3840x2160 and 39 us
  of CPU to encode and commit.
- Kick Off background (vsync bound): 59.81 FPS with MetalFX, 59.87 with the bilinear
  post-processing pass; GPU renderer utilization 48.9% and 53.6%, because the post-processing pass
  runs at 1920x1080 when MetalFX scales afterwards.
- Pause menu over a 3D stadium (CPU bound, 1000-1500 draws): 30.5 and 38.7 FPS with MetalFX, 27.8
  and 34.7 without, in the two comparable pairs.
- Match play with the first design: equal when vsync bound (60.0 and 59.9). In the comparable
  CPU-bound pair, 50.1 FPS with MetalFX and 59.3 without, with 320 instead of 175 ms per second
  spent in CPU waits for GPU results. The Vulkan queue waited at queue level for the scaler, whose
  start and completion go through host wake-ups, and every later CPU wait for GPU results queued
  behind that pause. A GPU-side dependency would need the `MTLSharedEvent` behind a Vulkan
  semaphore, which KosmicKrisp does not export (no `VK_EXT_metal_objects`).
- Match play with the current design (the presenting thread waits for the scaler and copies its
  output in `Present`), four alternating 30-second pairs:

  | Pair | MetalFX on: FPS, draws per frame | Off: FPS, draws per frame | CPU waits for GPU results, on / off (ms per second) |
  |---|---|---|---|
  | 1 | 33.8, 853 | 52.4, 400 | 222 / 224 |
  | 2 | 36.3, 932 | 54.2, 428 | 241 / 193 |
  | 3 | 42.6, 917 | 51.4, 513 | 220 / 211 |
  | 4 | 60.0, 471 | 60.0, 470 | 182 / 174 |

  In pairs 1-3 the MetalFX windows fell on replays and close cameras, with about twice the game's
  draws per frame. A presentation pass cannot change the draw count, so those pairs compare
  scenes, not the scaler. Pair 4 is the same scene: 60.0 FPS in both arms, vsync bound. The CPU
  waits for GPU results stayed close in every pair, even in the heavier MetalFX scenes, so the
  queue pause of the first design is gone. A CPU-bound pair in one scene is still missing.
- Visual: correct in menus, Kick Off, pause and play at 3200x1800, no Metal command buffer errors;
  UI text and thin structures are sharper than with the bilinear pass. The current design was also
  seen in the match intro, replays and their transitions, close-ups with depth of field, and the
  high replay camera in rain.

The option stays off by default until it is validated in a played match.

## Commits and switches

- `presenter: add an optional MetalFX spatial upscaler on macOS` (`GPU.metalfx_enabled`,
  `FC26_METALFX`, `SHADPS4_METALFX_OFF_FILE`).
- `rasterizer: add a diagnostic switch that breaks every 12th render pass`
  (`SHADPS4_EXTRA_PASS_SPLIT_FILE`; see above, it corrupts the image), and
  `rasterizer: let the pass break switch pick which passes it breaks` (the modes above).
- `presenter: add a diagnostic screenshot request file` (`SHADPS4_SCREENSHOT_FILE`).
- `presenter: wait for MetalFX on the present thread` (the current design).
