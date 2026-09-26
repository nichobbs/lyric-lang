# `Std.Process.run` compiles for native; `lyric-storage` uses `Std.File` bytes

`Std.Process.run` wrapped its host process calls in `try`/`catch`, which
`--target native` rejects (D-N-003: no unwinding), so any native program
calling it failed to build. `file_tests.l` was one: it creates symlinks with
`run("ln", ...)`, and failed on native for that reason.

- `Std.ProcessHost` gains a `hostRunInheritedResult(executable, args)` Result
  seam on all three targets. The .NET and JVM kernels hold the `try`/`catch`;
  the new native twin (`_kernel_native/process_host.l`) calls lyric-rt's new
  `lyric_process_run_inherited`, a fork/execvp that inherits the caller's
  stdio and process group. A failed exec is reported back over a CLOEXEC
  pipe, so a missing executable is an `Err` on every target, as it is when
  `Process.Start` throws on .NET, rather than exit code 127.
- `Std.Process.run` delegates to the seam.
- `lyric-storage`'s local backend reads and writes object payloads through
  `Std.File.readBytes`/`writeBytes`, which take and return `slice[Byte]`
  since D-progress-974. Its private `hostReadAllBytes`/`hostWriteAllBytes`
  externs were only there to avoid the old `List[Byte]` copy; the .NET ones
  are removed, and the JVM ones remain as private helpers of the sidecar text
  functions.

Verified: `file_tests.l` 14/14 on native, dotnet and JVM;
`llvm_stdlib_self_test.l` 29/29 (new `Std.Process.run` case, ASan); lyric-rt
C tests (new `lyric_process_run_inherited` cases: exit code, no args, missing
executable, signal); `run` on dotnet and JVM returns the exit code and an
`Err` for a missing executable; `lyric-storage` 39/39 and 3/3 on dotnet and
JVM.
