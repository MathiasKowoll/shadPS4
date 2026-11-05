# CPU backend strategy

## Decision

Use Rosetta 2 for the first complete FC26 bring-up, while keeping guest CPU execution behind a
replaceable boundary. Evaluate FEX as the preferred post-Rosetta backend when its macOS integration
is available in a form that can be built, signed, redistributed, and debugged independently of
CrossOver.

Do not block PS4 services, shader translation, resource correctness, or graphics profiling on FEX.
Those components remain necessary with either CPU backend.

## Why FEX is promising but not the default yet

Upstream FEX currently describes itself as an x86/x86-64 user-mode emulator for ARM64 Linux. The
CrossOver Preview demonstrates a macOS route using native ARM64 Wine with FEX, but that route also
depends on recent macOS support for cross-architecture processes.

The macOS work documents several host requirements that matter to an FC26 runtime: an alternate x18
ABI, low-address-space layout, per-thread x86 TSO mode, cross-architecture entitlements, and careful
thread initialization. These mechanisms are promising, but the PS4 runtime must verify its own
memory layout, signal/exception delivery, TLS, atomics, callbacks, and generated-code behavior.

References:

- <https://github.com/FEX-Emu/FEX>
- <https://list.winehq.org/hyperkitty/list/wine-devel@list.winehq.org/thread/CKG5CEN2BE5VRXZ7O7NX4YUSBH3247WH/>

## Boundary to preserve

Core PS4 runtime code must not assume that guest instructions execute natively. A future CPU backend
needs explicit operations for:

- guest address-space creation and executable mappings;
- translated block lookup, invalidation, and code-cache persistence;
- guest thread creation, TLS, register state, and x86 TSO activation;
- PS4 exception and signal delivery;
- calls from translated game code into HLE libraries;
- callbacks from HLE libraries into translated game code;
- atomics, self-modifying code, and executable permission changes;
- profiling guest time separately from HLE and GPU command processing.

## Readiness gates

FEX becomes eligible for the main launcher only after it can:

1. run a minimal PS4 x86-64 homebrew process inside the ARM64 host;
2. pass thread, TLS, exception, callback, atomic, and memory-map hardware tests;
3. boot FC26 to the same point as Rosetta with comparable logs;
4. render the fixed graphics baseline without changing the GPU path;
5. show measured CPU or compatibility value over Rosetta;
6. run on a normally secured Mac with documented signing and entitlements.

Until all six gates pass, FEX remains an experimental backend. Static AArch64 recompilation remains a
later research option, not a prerequisite for the port.
