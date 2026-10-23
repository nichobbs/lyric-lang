# D204 - The Windows x86-64 native target

**Status:** accepted, implemented for the core runtime and toolchain (docs/67 phase G9, #7948); processes (#8433),
sockets and TLS (#8434), the graphics prebuilts and G4 to G7 examples (#8435), and the compiler-hosted self-tests,
AddressSanitizer and long paths (#8436) are follow-ups

## Decision

1. **One triple: `x86_64-pc-windows-msvc`.** The MSVC C runtime (the UCRT) and the Microsoft x64 calling
   convention, the default target of an LLVM install on Windows and the ABI every Windows C library ships for.
   MinGW (`x86_64-w64-windows-gnu`) and Windows on AArch64 are not targets; naming any other Windows triple is
   **N0025**. AArch64 can follow once the C ABI lowering below covers it and a CI runner exists.
2. **The link step uses `lld-link` on every host** (`clang -fuse-ld=lld`). On Windows clang finds the Visual
   Studio C runtime and Windows SDK itself and no `link.exe` is needed; on Linux the same command cross-compiles
   when `INCLUDE` and `LIB` name an MSVC CRT and Windows SDK. The link adds `bcrypt` and `shell32` (the runtime's
   entropy and command-line parser) and none of `-lm`, `-lpthread` or `-ldl`; `@library("c")` and
   `@library("m")` name the UCRT and add no argument, and a `.lib` file name is an input file rather than GNU
   `-l:`. A `[native.libs]` `dir` library (D191) is `<link>.lib` (static, or the import library of `<link>.dll`),
   and its DLL is bundled beside the `.exe`, where the loader looks first, with no run path. The executable is written as `<path>.exe` when the requested path has no `.exe`, since Windows starts
   a program only by its extension; the CLI's default native output name follows the triple (or the host when
   none is given), and `lyric run`/`lyric test` look for the same name.
3. **Twins, not `#ifdef`s, for the platform layer.** `lyric_posix.c` and `lyric_fs.c` get Win32 twins,
   `lyric_win32.c` and `lyric_fs_win32.c`, selected by the build (`make -C lyric-rt windows`, or CMake on a
   Windows host), as `lyric_process_unsupported.c` and `lyric_net_unsupported.c` already are for wasm32. The
   portable files take small, local branches (`lyric_parallel.c`'s pool primitives, the LeakSanitizer hook) and
   one new shared entry point, `lyric_sleep_nanos`. The kernels keep their int-descriptor shape: descriptors are
   UCRT descriptors opened in binary mode and not inherited. `Std.LibcHost`'s `close`/`unlink`/`mkdir`/`rmdir`,
   `Std.Time`'s `usleep` and `Std.Tcp`'s `shutdown` bind lyric-rt wrappers instead of the raw POSIX names.
4. **UTF-8 inside, UTF-16 at the boundary.** Paths, environment variables and the command line cross the Win32
   API through the wide (`W`) entry points: the narrow ones use the ANSI code page, so a non-ASCII name would
   otherwise be lost. `lyric_args_get` re-reads the CRT's own `argv` from `CommandLineToArgvW`; the environment
   is the Win32 one that child processes inherit. Standard streams are binary, so a `\n` stays `\n` as on every
   other target; output that reaches a real console is converted to UTF-16 and written with `WriteConsoleW`
   (a UTF-8 sequence split across two writes is held until it completes), and console input is read with
   `ReadConsoleW`. A pipe or file gets the bytes the program wrote.
5. **POSIX failure semantics.** The CRT's invalid-parameter handler is replaced so an invalid descriptor fails
   with `errno` (as POSIX does) instead of ending the process, and a panic aborts with status 3 and no message
   box or Windows Error Reporting dialog. Protected-type monitors, semaphores and condition variables are SRW
   locks and condition variables with the POSIX twin's reentrancy and wait semantics; timed waits are relative,
   so a wall-clock step cannot cut them short. Sleeps use a high-resolution waitable timer (the scheduler tick is
   15.6 ms). Entropy is `BCryptGenRandom` with the system-preferred RNG.
6. **The C ABI is the Microsoft x64 convention.** A by-value record of 1, 2, 4 or 8 bytes crosses in one integer
   register whatever its fields; any other size is passed as a pointer to a copy the caller makes (never
   `byval`) and returned through `sret`; there is no register budget. A 2-byte record crosses as `i32`, which the
   convention makes equivalent to clang's `i16` (only the low half of the register is read), so the IR needs no
   new integer width. Checked against clang 18's lowering and run against C on Windows.
7. **Float formatting no longer depends on the C library's rounding.** The shortest round-tripping formatter
   (`lyric_string_from_float`) rounded each candidate length with `printf`, which rounds an exact decimal tie to
   even in glibc and away from zero in the Windows CRT. It now prints 40 significant digits once and rounds itself
   (ties to even), consulting the exact expansion only when the printed tail is exactly one half. The output is
   byte-identical to the previous formatter on 402,098 cases (random binary32 and binary64 patterns, every power
   of two, 100,000 exact ties), the same under the Windows CRT, and 35% faster.
8. **Test.** `lyric_rt_test.c` builds for Windows (the fork-, pipe- and child-process-based cases are compiled
   out, as for wasm32; its thread cases moved from `pthread_create` to `lyric_thread_create`, so they run on
   Windows too), and `lyric_win32_test.c` covers the Windows-only behaviour by running itself as a child: binary
   streams, panic status, a UTF-16 argument, stdin readiness on a pipe, non-ASCII paths, rename over an existing
   file, invalid descriptors, the environment, timer precision. The `windows-build.yml` workflow's `native-tests`
   job takes the `lyric.exe` the workflow links and runs lyric-rt's tests, the cross-target `@test_module`
   suites and stdlib suites the Linux native lane runs (except those that need processes or sockets), and
   `scripts/ci/windows-native-e2e.sh` (records to and from C including through a callback, console and argument
   text, a non-ASCII file tree, the environment, sleeping, the parallel pool and a protected type, a panic's
   status, the `.exe` name).

## Rationale

The UCRT and the Microsoft x64 convention are what Windows C libraries (SDL3, wgpu-native, FreeType, HarfBuzz)
are built for, so the graphics libraries can link their published binaries. Keeping the platform layer as whole
files per OS keeps each readable against its own API documentation, and the unsupported twins already
established the pattern. `lld-link` everywhere gives one link command for native builds on Windows and for
cross builds from Linux, and needs nothing beyond an LLVM install.
