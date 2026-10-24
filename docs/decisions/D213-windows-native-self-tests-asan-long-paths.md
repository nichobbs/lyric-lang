# D213 - Compiler-hosted native self-tests, AddressSanitizer and long paths on Windows

**Status:** accepted, implemented (docs/67 phase G9, #8436; extends D205)

## Decision

1. **The compiler-hosted native suites run on the Windows job.** The `llvm_*_self_test.l` suites and their
   siblings are dotnet-target `@test_module`s that codegen a program, link it and run it. They used to hand-roll
   the link (`clang` with `-lm -lpthread -ldl` against `lyric_rt.a`), so they could only run on POSIX. They now
   call `Lyric.LlvmBridge.linkNativeIr`, the host link the bridge itself performs: the Windows archive,
   `--target`, `-fuse-ld=lld` and the Windows system libraries on Windows, and the POSIX libraries elsewhere.
   Scratch directories come from `nativeScratchDir` (`TMPDIR`, then `TEMP`, then `TMP`), and the suites that start
   threads use `lyric_thread_create` / `lyric_thread_join` instead of `pthread_create`. They compare a program's
   exit status through `nativeExitStatus`, the low byte a POSIX host reports, because Windows passes `main`'s full
   32-bit result through; a negative Windows code (an NTSTATUS failure) is kept, so a crash never reads as a small
   status. A suite that codegens for the host passes `nativeHostCodegenTriple()`, which is the Windows triple on
   Windows (an empty triple selects the System V lowering). The Windows job stages the compiler bundle beside
   `lyric.exe` and runs every suite that does not spawn `sh`, call pthreads directly or build `.so` libraries.
2. **AddressSanitizer on Windows links the DLL C runtime.** clang's Windows AddressSanitizer works only with the
   DLL C runtime, while native programs link the static one so they need no Visual C++ redistributable. lyric-rt
   therefore builds twice on Windows: `lyric_rt.lib` (static CRT) and `lyric_rt_md.lib` (DLL CRT). A native build
   whose clang flags include `-fsanitize=address` links `lyric_rt_md.lib` (`$LYRIC_RT_WINDOWS_MD_PATH`, the
   installed `lib/lyric_rt_md-x86_64-pc-windows-msvc.lib`, or the dev tree's `lyric_rt_md.lib`) with
   `-fms-runtime-lib=dll`, and copies `clang_rt.asan_dynamic-x86_64.dll` beside the executable, where the loader
   looks first. **N0026** reports a clang without that DLL (an LLVM install without compiler-rt) or a failed copy.
3. **Long paths are passed in their extended-length form.** Win32 path APIs are limited to `MAX_PATH` (260)
   characters unless the path is written `\\?\C:\...` (or `\\?\UNC\server\share\...`). `lyric_win32_path` makes
   the full path with `GetFullPathNameW` and adds the prefix when it is 248 characters or more (the limit
   `CreateDirectoryW` applies), so every file and directory operation of the runtime works on deep trees without
   the system-wide long-path setting. Shorter paths are passed unchanged, so relative paths and their
   current-directory semantics are untouched.

## Not in this slice

A program path over `MAX_PATH` still cannot be started: `CreateProcessW` takes no extended-length application
name. The graphics examples on Windows are #8435.
