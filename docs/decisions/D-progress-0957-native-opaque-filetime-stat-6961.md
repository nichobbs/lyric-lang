# D-progress-955 — Native: `FileTime` opaque timestamp twin unblocks `Std.File.stat`/`fileStatIsNewer` (#6961)

**Status:** shipped

**Context.** D-progress-942 (#6961) closed `Std.File.readTextOrPanic`'s
native `try`/`catch` block, but left `Std.File.stat`/`fileStatIsNewer`
out of scope: unlike `readTextOrPanic`, `stat`'s return type
(`FileStat.modifiedAt: FileTime`) is a per-kernel opaque timestamp —
`extern type FileTime = "System.DateTime"` on `.NET`, `extern type
FileTime = "java.lang.Long"` on the JVM — and native has neither BCL
nor JDK to extern against. Removing `stat()`'s `try`/`catch` needed a
native representation for `FileTime` first; that representation did not
exist.

**Decision.** Give native its own `FileTime`: a plain
`_kernel_native/file_host.l` record,

```lyric
pub record FileTime {
  epochNanos: Long
}
```

— the same epoch-nanoseconds representation `Std.Time`'s native
`Instant` already uses (D-N-027), deliberately *not* a re-export of
`Instant` itself, so `Std.FileHost` stays independent of `Std.TimeHost`
on this target the same way it already does on the other two.

**Implementation.**

- `lyric-rt/src/lyric_fs.c`: new `lyric_file_mtime_epoch_nanos_ok(path,
  int64_t* out_nanos)` — `stat(2)`'s `st_mtim` (`st_mtimespec` on
  macOS), converted to epoch-nanoseconds with an overflow guard
  mirroring `time_host.l`'s own `checkedAddNanos` pattern (both bounds
  checked separately since `tv_nsec` is always non-negative per POSIX,
  so only the lower bound needs no `nsec` term). Follows symlinks
  (`stat`, not `lstat`), matching `lyric_file_exists`/`lyric_dir_exists`.
  Declared in `lyric_rt.h` next to `lyric_env_app_base_directory_ok`.
- `_kernel_native/file_host.l`: `rtMtimeEpochNanosOk` extern +
  `hostGetLastWriteTimeUtcResult(path): Result[FileTime, IOError]` (the
  exception-free Result seam) + `hostDateTimeGreaterThan(a, b): Bool`
  (`a.epochNanos > b.epochNanos`, matching the dotnet twin's
  `DateTime.op_GreaterThan` and the JVM twin's `longValue() >
  longValue()` semantics exactly).
- `_kernel/file_host.l` (dotnet) and `_kernel_jvm/file_host.l`: both
  gained a `hostGetLastWriteTimeUtcResult` too — thin `try`/`catch`
  wrappers around their existing throwing `hostGetLastWriteTimeUtc` —
  so the pure layer's call site is uniform across all three targets
  rather than native being the odd one out.
- `std/file.l`'s `stat()` drops its `try`/`catch` entirely (D-N-003: no
  unwinding on native) and calls `hostGetLastWriteTimeUtcResult`
  directly via `match`. The pre-probe (`hostFileExists(path) or
  hostDirectoryExists(path)`) still runs first and still reports
  `FileNotFound`, unchanged; the old dotnet-only message-text
  classification (`"Could not find file"` / `FileNotFoundException` /
  `DirectoryNotFoundException`) is gone because the pre-probe already
  rules out the ordinary not-found case on every target, and a
  post-probe TOCTOU race is *not* uniformly observable: on dotnet/JVM,
  neither `File.GetLastWriteTimeUtc` nor `File.lastModified()` throws
  for a since-deleted path, so a path removed between the probe and
  the call still silently yields `Ok` with a garbage sentinel
  timestamp — identical to this function's pre-existing behavior on
  those two targets, unchanged by this PR. Only native's `stat(2)`-backed
  seam can actually observe that race (a missing path is a real syscall
  failure there), reporting `Err(IoError)` rather than `FileNotFound`
  for that racing case specifically — the race window's exact
  classification was never load-bearing either way.

**Verification.** `lyric-rt/test/lyric_rt_test.c` gained
`test_file_mtime`: an exact round-trip via `utimes(2)`-pinned
timestamps (`2024-01-15T10:30:45.500000Z` → `1705314645500000000`
nanos), a strictly-later mtime producing a strictly larger nanos value,
a pre-1970 mtime round-tripping through negative epoch-nanos, and a
missing-path failure leaving the out-param untouched — `make -C
lyric-rt test` passes (`lyric_rt_test` + `lyric_tls_test`).
`lyric-stdlib/tests/file_tests.l` gained "fileStatIsNewer reflects real
write ordering, and is false for a file compared to itself" (using
`Std.Time.sleepMillis(10)` for a real, non-flaky time gap between two
writes rather than relying on two back-to-back `stat()` calls landing
on different filesystem timestamp ticks) — `fileStatIsNewer` had no
dedicated test anywhere in the repo before this despite backing real
incremental-build staleness checks
(`cli_workspace_builder_self_test.l`). `llvm_stdlib_self_test.l` gained
"Std.File stat/fileStatIsNewer: round-trip, real write ordering,
missing path (ASan) (#6961)", exercising the same ordering assertions
end-to-end through `Lyric.LlvmBridge.compileToNativeWithFlags` with
`-fsanitize=address`.

**Related:** D-progress-910 (`#4752`'s residual-seam audit),
D-progress-942 (`readTextOrPanic`'s half of #6961, the precedent this
entry follows), D-N-027 (`Std.Time`'s native `Instant`/`Duration`
epoch-nanoseconds representation, reused here as the field
convention), `docs/10-bootstrap-progress.md`, `native/plan/08-work-items.md`
N5.7.
