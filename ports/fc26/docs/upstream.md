# Upstream workflow

The port is a branch of the `MathiasKowoll/shadPS4` fork. `origin` points to that fork and `upstream`
points to `shadps4-emu/shadPS4`.

## Update the port

From `/Users/mathias/Development/fc26-ps4-port` with no local changes:

```sh
git fetch upstream
git rebase upstream/main
```

Do not merge `upstream/main`. Rebasing keeps the port commits reviewable and allows each general fix
to be compared with its upstream equivalent. Do not force-push unless the owner explicitly requests
publishing the rebased branch.

## Validation after a rebase

1. Update submodules if their recorded revisions changed.
2. Run `ports/fc26/scripts/build.sh` to build the x86-64 target and bundled KosmicKrisp runtime.
3. Run `ports/fc26/scripts/run.sh --verify`.
4. Boot the title and compare the fixed graphics scenes.
5. Compare new SRT, shader recompiler, Vulkan, audio, and kernel errors with the previous log.
6. Accept the rebase only after menu and match rendering remain correct.

Changes under `src/` should remain candidates for upstream contribution. FC26 launch policy, build
identity, and baseline documentation belong under `ports/fc26/`.

