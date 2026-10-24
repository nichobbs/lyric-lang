# The native graphics libraries on Windows (D219, #8435)

lyric-window, lyric-gpu, lyric-text, lyric-draw and lyric-game build and run on `--target native --triple
x86_64-pc-windows-msvc`, and a Windows CI job runs their examples.

- `@cfg(target_os = "linux" | "macos" | "windows" | "wasi")`: the native bridge injects `target_os.<os>` from the
  triple for the program, its dependencies, each file of a multi-file package and the stdlib (`Lyric.Cfg`,
  `Lyric.LlvmBridge.nativeTargetOs`, `Lyric.Emitter` project merge). `cfg_self_test.l` covers it.
- `lyric bindgen --triple` (clang `--target`, LLP64/ILP32/LP64 data models; pointers no longer sized by
  `--long-bits`), `--cfg <predicate>` (a file-level `@cfg` plus `toCLong`/`fromCLong`), and calling-convention
  attributes dropped from clang's type strings. `bindgen_self_test.l` parses a `__cdecl` header for Windows.
- lyric-text's FreeType and HarfBuzz kernels are generated for LP64 and LLP64 (`freetype_windows.l`,
  `harfbuzz_windows.l`); `text.l` reads FreeType's struct offsets and `long` fields per target, and
  `text_layout_check.c` checks both layouts. SDL3's and wgpu-native's kernels are unchanged and checked against
  the Windows headers in CI.
- `[native.libs]`: `pkg_config` with prebuilt tables for the triples they cover; `members` entries
  `"<path> -> <name>"`; every DLL of a Windows archive bundled; pkg-config DLLs bundled on Windows.
  `native_libs_self_test.l` covers each.
- Pinned Windows archives: SDL3 3.4.18 (the official Visual C++ development archive) and wgpu-native v29.0.1.1
  (its own release archive).
- `Gpu.createWindowsSurface`, used by lyric-gpu's window example, lyric-game's loop and the native lyric-ui
  host.
- CI: `scripts/ci/build-text-libs-windows.sh` builds FreeType 2.13.2 and HarfBuzz 8.3.0 from pinned sources, and
  `scripts/ci/windows-graphics-e2e.sh` (the `graphics` job of the Windows workflow) runs lyric-window's demo,
  lyric-gpu's four examples on Direct3D 12 with WARP, lyric-text's shape, lyric-draw's scene and Breakout,
  against the Linux goldens.
- docs/01 (`@cfg`, `[native.libs]`, bindgen), docs/24 §4.1, book chapter 13 and appendix B.

Verified on Linux: the regenerated FreeType and HarfBuzz kernels pass `scripts/ci/text-examples-e2e.sh` (golden:
0 differing pixels), and the Windows variants were generated locally with clang and an xwin MSVC sysroot. The
Windows examples run only on the Windows CI job.
