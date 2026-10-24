# D219 - The native graphics libraries on Windows

**Status:** accepted, implemented (docs/67 phase G9, #8435; extends D191, D192, D205, D-N-013)

## Decision

1. **`@cfg(target_os = "X")`.** A new `@cfg` atom tests the operating system of a native build: `linux`,
   `macos`, `windows` or `wasi`, from the target triple (the host's when none is given). It is the
   `target_os.<os>` pseudo-feature the native bridge injects next to `target.native` (D-N-013's mechanism), for
   the user's packages, its path dependencies, the per-file `@cfg` of multi-file packages and the bundled stdlib.
   Off native no OS is known at compile time, so only the `not(...)` side of a `target_os` predicate holds there.
   docs/24 §4.1 named `target_os` as the first future atom; this is it, with its spelling.
2. **C `long` is per target, and so are the bindings that use it.** Windows x64 is LLP64: `long` is 32 bits,
   pointers 64. `lyric bindgen --triple <triple>` parses the header as that target (clang `--target`, so a header's
   `_WIN32` branches and its `<stdint.h>` are the target's) and sets the data model; pointers no longer take their
   size from `--long-bits`. A library whose bindings differ by data model is generated once per model, each file
   gated by `--cfg <predicate>` (written as the file's `@cfg`), and both files form the package
   (`[project.packages]` lists them). Every such variant also defines `toCLong(Long)` and `fromCLong(...)`, so the
   safe layer converts a C `long` the same way against each. FreeType is one such library (`freetype.l` and
   `freetype_windows.l`), and so is HarfBuzz, whose kernel binds FreeType's records through `hb-ft.h`;
   lyric-text's hand-written struct offsets are chosen the same way. Bindings without `long` (SDL3, wgpu-native)
   are one file, and the Windows CI job regenerates each
   with `--triple x86_64-pc-windows-msvc --check` to prove the one file holds there too. bindgen drops
   `__attribute__((...))` from clang's type strings: Windows headers mark functions with a calling convention
   (`SDLCALL` is `__cdecl`), and x86-64 has only one.
3. **A library may name a prebuilt archive for some triples and pkg-config for the rest.** `pkg_config` and
   `[native.libs.<name>.prebuilt.<triple>]` tables may now appear together: a triple with an archive restores and
   links it, and any other triple uses pkg-config. SDL3 is a system package on Linux and macOS but has no
   pkg-config on Windows, where its official Visual C++ archive is pinned.
4. **Windows archives ship their DLLs, and members can be renamed.** A `members` entry may be
   `"<path> -> <file name>"`, extracting under another name: a Windows import library may be called anything (it
   records the DLL it loads), so wgpu-native's `wgpu_native.dll.lib` is extracted as `wgpu_native-release.lib`,
   the link name the kernel's `@library` already uses on Linux, and the kernel stays one file. Every `.dll` a
   Windows archive extracts is bundled beside the executable, so a library keeps its upstream DLL name.
5. **pkg-config libraries are bundled on Windows.** Windows has no system library directory the loader searches,
   so for a pkg-config library on a Windows target the DLL of each `-l<name>` is copied beside the executable
   when it is found next to an `-L` directory's import library or in the `bin` directory beside it (the vcpkg and
   CMake install layouts). Elsewhere pkg-config libraries stay system libraries.
6. **The Windows surface.** `Gpu.createWindowsSurface(device, instance, hwnd)` creates a wgpu surface for the
   HINSTANCE and HWND that `Window.nativeWindow` returns as `Win32`, and the windowed examples, lyric-game's loop
   and the native lyric-ui host use it.
7. **CI.** A `graphics` job on the Windows workflow builds FreeType 2.13.2 and HarfBuzz 8.3.0 (with its FreeType
   bridge) from pinned sources, the releases the Linux job's goldens come from, and runs the G4 to G7 examples:
   lyric-window's demo, lyric-gpu's compute, triangle, quad and window examples, lyric-text's shape, lyric-draw's
   scene and Breakout's headless replay and live run. wgpu renders through Direct3D 12 on WARP, and the offscreen
   frames are compared with the Linux goldens at the same tolerances. D200's 100 ms stress-frame ceiling is a
   lavapipe ceiling; WARP draws that frame in about 140 ms, so the Windows job sets
   `LYRIC_DRAW_STRESS_BUDGET_MS=500` (the scene example's override, default 100).

## Not in this slice

Screenshots of the windowed examples on Windows (the Linux job takes them under Xvfb), a Windows run of the native
lyric-ui host (G10, outside G9's G4 to G7 criterion; it builds on the same surface), and macOS (#8389).
