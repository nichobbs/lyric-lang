# D320 - A pinned WenQuanYi Zen Hei for the macOS goldens, and the Linux arm64 and sanitizer lanes

**Status:** accepted, implemented in `native-platforms.yml` (docs/67 phases G4 to G8, #8563)

## Decision

1. **The macOS lane fetches the Linux CJK font instead of staying Linux-only.** The lyric-text `shape` and lyric-draw
   `scene` goldens are drawn with WenQuanYi Zen Hei, which Homebrew does not ship. `scripts/ci/macos-graphics-e2e.sh`
   downloads `fonts-wqy-zenhei_0.9.45-8_all.deb` from `snapshot.debian.org` (an immutable archive URL), checks the
   package against a pinned SHA-256, extracts `wqy-zenhei.ttc` and checks that against a second pinned SHA-256. Either
   mismatch fails the run, so a golden is never compared against a different font.
2. **Evidence for choosing this over documenting the examples as Linux-only.** The Debian package and the Ubuntu 24.04
   package of the same version contain a byte-identical `wqy-zenhei.ttc` (SHA-256 `79c18ebe...29b9`, also the file the
   Linux lane reads from `/usr/share/fonts`), and the snapshot URL returns the same package bytes as the current Debian
   pool. The goldens are unchanged: the font is the same file. The Linux `shape` golden matches with 0 differing pixels,
   and both examples compare within the existing differing-pixel tolerance, which already absorbs another FreeType's edge
   rasterisation. The macOS result (Homebrew FreeType and HarfBuzz, Metal for `scene`) is confirmed only by CI; if the
   tolerance proves too tight there, the fix is to widen the examples' tolerance with a measurement, not to change a golden.
3. **Linux arm64 runs the graphics examples.** The `linux-arm64` job installs lavapipe, FreeType, HarfBuzz, the fonts and
   the X11 development packages, builds SDL3 with `--x11`, and runs `text`, `gpu`, `draw`, `window`, `gpu-window`, `game` and
   `ui-native` e2e scripts, which are architecture-neutral (the lavapipe ICD is found by glob; wgpu-native comes from the
   already pinned `aarch64-unknown-linux-gnu` prebuilt).
4. **Sanitizer lanes on both hosts.** `parallel-e2e.sh` (ThreadSanitizer) and `async-mt-e2e.sh` (ThreadSanitizer and
   AddressSanitizer) run on macOS arm64 and Linux arm64, with `plugin-e2e.sh native native` and `bench-vec3-alloc.sh`.
   The scripts lose two GNU-isms (`nproc`, `mapfile`). The Linux arm64 job prints `vm.mmap_rnd_bits` and lowers it to
   28 before ThreadSanitizer runs, because TSan's fixed shadow mappings collide with high ASLR entropy.

## Not done

Plugin runs with a `dotnet` side (`plugin-e2e.sh native dotnet`, protocol and widget variants) and the other plugin
scripts are not added to these lanes; they need the managed compiler to build a dotnet payload on the new hosts.
