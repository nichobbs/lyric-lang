# Native backend CI on macOS arm64 and Linux arm64 (#8419, #8401)

`.github/workflows/native-platforms.yml` runs the `--target native` suite on
`macos-latest` and `ubuntu-24.04-arm` (ci.yml is at its size ceiling, so it is a
separate workflow like `windows-build.yml`). A Linux job builds the managed
compiler closure once (cached on the compiler, stdlib and bootstrap sources);
each platform job NativeAOT-links it into its own `lyric` and runs
`scripts/ci/native-platform-tests.sh`: lyric-rt's C tests, the cross-target and
stdlib suites, the compiler-hosted `llvm_*` suites, and the portable end-to-end
programs. On macOS it also builds SDL3 from the pinned tarball and runs the
`lyric-window` demo on SDL's offscreen video and disk audio drivers.

Bringing macOS up found and fixed real defects, each now covered by that lane:

- `lyric_rt.c`: the weak `__lsan_ignore_object` reference failed every Mach-O
  link; it is now looked up with `dlsym` on macOS.
- `lyric_tls.c`: accepted sockets inherited the listener's `O_NONBLOCK` on macOS
  (they do not on Linux), so the first read returned at once; they are made
  blocking. OpenSSL 3 is also searched in the Homebrew and MacPorts prefixes.
- `lyric_fs.c`: `Std.Environment.appBaseDirectory` had no macOS implementation
  (`_NSGetExecutablePath` plus `realpath`).
- `llvm_codegen.l`: an extern taking a callback with a by-value record was
  rejected with N0010 on AArch64, whose lowered homogeneous-float-aggregate form
  is an `[N x float]` array that the coverage check mistook for an inline
  `array[N, T]` (found on Linux arm64).
- Dylib install names: a `dir` library built with a bare `clang -shared` kept
  its build path as install name, so the bundled copy was never loaded (D191's
  `@loader_path` run path only helps `@rpath/...` names). The link now stages a
  re-named, ad-hoc-signed copy and adds `@executable_path/../Frameworks` too.
- Tests that assumed Linux: `/bin/true` (macOS has `/usr/bin/true`), and the
  wasm32 object compile (Apple's clang has no WebAssembly backend).
- `build-sdl3.sh` and `window-examples-e2e.sh` now run on macOS (bash 3.2 empty
  arrays, `shasum`, `DYLD_LIBRARY_PATH`).

Not covered yet, tracked separately: the GPU, text, draw, game and native `lyric-ui`
examples on macOS and Linux arm64, and the multi-threaded scheduler sanitizer runs.
