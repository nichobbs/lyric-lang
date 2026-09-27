# `Std.Environment.isWindows`; `process_tests` runs on JVM; native piped-process message fixes

- **`Std.Environment.isWindows()`** (`@experimental`) reports whether the
  process runs on Windows: `OperatingSystem.IsWindows()` on .NET, the
  `os.name` system property on the JVM, and a compile-time property of
  lyric-rt (`lyric_env_is_windows`) on native.
- **`lyric-stdlib/tests/process_tests.l` compiles on JVM.** It declared its
  own `.NET`-only `@externTarget` platform check outside a kernel (which
  CLAUDE.md reserves for kernel files); the JVM backend could not lower it.
  It now uses `Std.Environment.isWindows()`, and CI runs the suite on JVM.
- **Native piped-process follow-ups from #7426's review.**
  `lyric_process_piped_write_line` returns `-2` when stdin was already
  closed (distinct from a broken pipe, `-1`), so the native error names the
  actual cause. The native spawn-failure message helper now lives once, in
  `_kernel_native/process_host.l` (`hostSpawnFailureMessage`), and the
  piped kernel imports it.
- **`String.replace` on native (#6888)** was already lowered to lyric-rt's
  `lyric_string_replace`; this adds end-to-end ASan coverage and C cases for
  non-overlapping, left-to-right and multibyte replacement.

Verified: lyric-rt C tests; `llvm_stdlib_self_test.l` 31/31 (ASan);
`process_tests.l` on dotnet and JVM; `isWindows()` false on Linux on all three
targets.
