# Native platforms: Linux arm64 graphics, sanitizers and the macOS CJK goldens (#8563)

- `linux-arm64` job: lyric-text, lyric-gpu (lavapipe), lyric-draw, lyric-window, the gpu-window and Breakout X11 checks
  under Xvfb, and the native lyric-ui host, each as its own `if: always()` step; SDL3 built with `--x11` and cached.
- ThreadSanitizer and AddressSanitizer runs (`parallel-e2e.sh`, `async-mt-e2e.sh`), `plugin-e2e.sh native native` and
  `bench-vec3-alloc.sh` on macOS arm64 and Linux arm64. `parallel-e2e.sh` uses `getconf _NPROCESSORS_ONLN`,
  `bench-vec3-alloc.sh` a read loop instead of `mapfile` (macOS bash 3.2).
- macOS: `macos-graphics-e2e.sh` runs the lyric-text `shape` and lyric-draw `scene` goldens with a checksummed
  WenQuanYi Zen Hei downloaded from snapshot.debian.org (D320).
- Verified on x86-64 Linux: the touched scripts (text, parallel, async-mt, plugin-e2e, bench-vec3) pass, the font
  fetch and both checksums pass. The macOS and Linux arm64 steps are confirmed only by the `Native platforms` workflow.
- Decision: D320.
