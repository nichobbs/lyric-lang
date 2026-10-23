# Compiler-hosted native self-tests, AddressSanitizer and long paths on Windows (D213, #8436)

The Windows native job now runs the compiler-hosted `--target native` suites, AddressSanitizer included, and the
runtime handles paths longer than `MAX_PATH`.

- `Lyric.LlvmBridge.linkNativeIr` links a self-test's IR for the host the way a build does, and
  `nativeScratchDir` / `nativeTempBase` find a scratch directory on every host. About twenty suites that
  hand-rolled a POSIX `clang` line now call it; the TLS and HTTP suites start their threads with
  `lyric_thread_create`. `nativeHostCodegenTriple` gives the suites the Windows triple on a Windows host.
- AddressSanitizer on Windows: lyric-rt also builds `lyric_rt_md.lib` against the DLL C runtime (Makefile and
  CMake), and a sanitized native build links it and bundles `clang_rt.asan_dynamic-x86_64.dll` beside the
  executable (`N0026` when it cannot).
- `lyric_win32_path` converts every runtime path of 248 characters or more to its `\\?\` form;
  `lyric_win32_test` covers the conversion and a directory tree deeper than 300 characters.
- `scripts/ci/windows-native-tests.sh` stages the compiler bundle beside `lyric.exe` and runs 27 suites with
  `LYRIC_LOAD_COMPILER=1`; the job sets up .NET for them. `stage-selfhosted-compiler.sh` checks the bundle with
  `grep -a` instead of `strings`, which Git Bash lacks.
- docs/01 (native target) and book appendix B (`N0026`).

Verified on Linux: every refactored suite passes unchanged. Under wine the long-path tests pass; Windows
AddressSanitizer and the compiler-hosted suites run only on the Windows CI job.
