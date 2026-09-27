# `Std.Process` piped API compiles for native; native spawn errors carry the OS reason (#6887)

`Std.Process.spawnPiped`, `pipedReadLine` and `pipedWriteLine` wrapped
their host calls in `try`/`catch`, which `--target native` rejects (D-N-003),
so no native program could use the piped-process API (#6887).

- `Std.ProcessPipedHost` gains `hostSpawnPipedResult`,
  `hostPipedReadLineResult` and `hostPipedWriteLineResult` on all three
  targets. The .NET and JVM kernels hold the `try`/`catch`; the native twin
  maps lyric-rt's return codes. `Std.Process` delegates to them, the same
  shape `run` got in the previous change.
- lyric-rt's `lyric_process_piped_spawn` now reports a failed exec (for
  example a missing executable) over a CLOEXEC pipe and returns `NULL`, so
  `spawnPiped` gives an `Err` on every target instead of a child that exits
  with code 127 on native.
- Native spawn failures carry the OS reason: lyric-rt records the errno
  behind a failed `lyric_process_run_inherited` or
  `lyric_process_piped_spawn` start (`lyric_process_last_spawn_errno`), and
  `lyric_process_errno_message` renders it, so the `IoError` reads "the
  process could not be started: No such file or directory" rather than a
  fixed string. The .NET and JVM `IoError`s already carried the host
  exception's message.
- `lyric-storage`'s tests cover the write-failure path its local backend
  gained when it moved to `Std.File.writeBytes` (a put onto a path that is a
  directory is an `Err`).

Verified: lyric-rt C tests (piped spawn of a missing executable returns
`NULL` with `ENOENT`; run-inherited records `ENOENT`);
`llvm_stdlib_self_test.l` (ASan) including a new `Std.Process` piped-API case
(write, read, EOF, write-after-close `Err`, and the OS reason for a missing
executable from both `spawnPiped` and `run`); `piped_process_jvm_main.l` on
JVM; `lyric-storage` on dotnet and JVM.
