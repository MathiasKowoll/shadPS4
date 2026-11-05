# FC26 port rules

- Keep this branch rebaseable on `upstream/main`. Put orchestration, profiles, and documentation
  under `ports/fc26/`; avoid unrelated edits to shared files.
- Shared emulator and shader fixes must implement correct PS4 behavior for every affected title.
  Never key a core fix by FC26 title ID, executable hash, or shader hash.
- The supported baseline is the PS4 build identified by `profile.json`. Do not use Nintendo Switch
  executables, shaders, assets, or quality settings as substitutes.
- Visual correctness comes before performance. Do not reduce render resolution, texture quality,
  material features, shadows, crowd detail, post-processing, or animation to hide a bug or reach a
  frame-rate target.
- Keep game files, extracted code, shaders, caches, captures, and logs outside the repository. Do
  not add keys, credentials, copyrighted game content, or paths containing user secrets.
- Record a graphics change against the fixed scenes in `docs/graphics-baseline.md`. A menu boot is
  not evidence for match rendering, frame pacing, input, audio, or save behavior.
- Before rebasing, require a clean worktree. Use `git fetch upstream` followed by
  `git rebase upstream/main`; never merge upstream into this branch.

