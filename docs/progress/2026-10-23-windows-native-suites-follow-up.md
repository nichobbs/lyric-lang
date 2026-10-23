# Windows native suites: exit statuses, shutdown and lyric run (D209, D213, #8436 follow-up)

The Windows `native-tests` job runs every compiler-hosted native suite it lists. The fixes it needed:

- `Lyric.LlvmBridge.nativeExitStatus` gives the exit status a POSIX host reports (the low byte), so a suite's
  expected value holds on Windows, which passes `main`'s full 32-bit result through; a negative Windows code (an
  NTSTATUS failure) is kept. The 34 places in the suites that read a program's status go through it (D213).
- `lyric_sock_shutdown` on Windows also cancels the socket's pending I/O when the read side closes, so it wakes
  a read another thread is blocked in, as POSIX `shutdown` does. `Std.HttpServer.stopListener` no longer hangs
  on an idle keep-alive connection (D209). `lyric_tls_test` covers it.
- `lyric run` of a native project finds the executable on Windows: `projectBinOutputPath` names it the way the
  build does, with `.exe` added to an `output_assembly` that lacks it.
- The Windows job sets up Java 22, since some suites also run their program on the JVM.
- `native_dependency_self_test` checks for the built binary under its Windows name.
