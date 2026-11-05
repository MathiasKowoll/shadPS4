# Shader cache workflow

shadPS4 translates the PS4 GCN shaders reached during play to SPIR-V and stores the translated
modules, shader metadata, and graphics or compute pipeline keys in `user/cache/CUSA52342.zip`.
With pipeline preloading enabled, later runs rebuild those known pipelines before the game starts.
This reduces repeated translation and compilation stutter, but it does not prove that a scene is
rendered correctly.

The cache is runtime-generated game data and stays outside Git. `scripts/run.sh` validates and
preserves a content-addressed snapshot before and after every run. Each snapshot has a JSON
manifest that records the FC26 executable identity, shadPS4 commit, KosmicKrisp commit, archive
checksum, and shader and pipeline counts. Incompatible snapshots must not be combined: shadPS4
also embeds a system profile in the archive and rejects a cache when that profile changes.

Inspect or preserve the cache manually with:

```sh
ports/fc26/scripts/shader_cache.py status
ports/fc26/scripts/shader_cache.py snapshot --label country-selection
```

Snapshots are written under `FC26_DATA_DIR/shader-cache/snapshots/`. A snapshot is deduplicated by
SHA-256, so repeated captures of an unchanged cache do not consume additional space.

Static extraction cannot produce a complete cache by itself. Frostbite can create shader variants
and pipeline state dynamically, and correct translation depends on runtime descriptors,
specialization state, render targets, and resource formats. The useful prewarm procedure is
therefore to traverse fixed scenes and interactions, exit cleanly, preserve the cache, and verify
that the next run reports the expected pipelines as preloaded. Shader dumping is a diagnostic mode,
not a substitute for this pipeline cache and not a distributable artifact.
