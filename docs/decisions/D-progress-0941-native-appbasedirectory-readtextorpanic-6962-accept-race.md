# D-progress-941 — Native: `appBaseDirectory`, `readTextOrPanic` try/catch removal, and the `accept()` spurious-wakeup race fix (#6937, #6961, #6962)

**Status:** shipped

**Context.** Three independent, small `--target native` gaps from the
`lyric-rt`/`_kernel_native` residual-seam audit lineage (#4752,
D-progress-910), each already filed as its own precisely-scoped issue.

**#6937 — `Std.Environment.appBaseDirectory`.** The last of the four
runtime-identity probes still missing from the native kernel (D-progress-910
deliberately deferred it as new `lyric-rt` C surface rather than bundling it
into that audit pass). Ships a new `lyric_env_app_base_directory_ok` seam in
`lyric-rt/src/lyric_fs.c`: resolves `/proc/self/exe` via `readlink` (Linux
only, this project's only CI target; falls back to `""` on any other
platform or failure, matching `hostRuntimeDirectory`/`hostRuntimeIdentifier`'s
existing empty-means-unavailable convention), then strips the executable's
own basename, keeping the trailing `/` to match .NET's
`AppContext.BaseDirectory` contract exactly.

**#6961 — `Std.File.readTextOrPanic`'s native `try`/`catch` block.**
`Lyric.LlvmCodegen` unconditionally rejects any `STry` node for `--target
native` (D-N-003: no unwinding) — the same root cause #6887 tracks for
`Std.Process`'s piped API, scoped separately here since #6887's own fix is
specific to that facade and `readTextOrPanic` has no opaque-timestamp
prerequisite (unlike `stat`/`fileStatIsNewer`, which remain blocked and
out of scope for this fix). Mirrors `readBytesOrPanic`'s already-shipped
fix (D-progress-910) exactly: the pure-layer body in `std/file.l` drops
`try`/`catch` and calls `hostReadAllText(path)` directly;
`_kernel_native/file_host.l`'s own `hostReadAllText` panics on failure in
the kernel (reusing the existing `hostReadTextResult` Result-returning
seam) since native has no exceptions to propagate in the first place.
`dotnet`/`jvm` kernels are unchanged — `hostReadAllText` still throws on
failure there and lets it propagate uncaught, exactly matching
`readBytesOrPanic`'s pre-existing behavior on those targets (verified
manually: both now crash identically with an uncaught
`FileNotFoundException`, exit 134).

**#6962 — `lyric_sock_accept_interruptible`'s spurious-wakeup race.** The
`EAGAIN`/`EWOULDBLOCK` "spurious wakeup" retry branch (added by #6806's
portable-accept-interrupt fix) assumed the listening socket was
non-blocking, but `lyric_sock_listen` never set `O_NONBLOCK`. On the actual
blocking socket, a losing thread's `accept()` call in that branch blocked
waiting for a NEW connection instead of returning `EAGAIN` — and while
blocked, stopped polling the wake pipe, reintroducing the exact
un-killable-accept hang #6806 fixed, but only when two threads accept
concurrently on the same `Listener` (not reachable via any caller in this
codebase today — `Std.HttpServer` spawns exactly one accept thread per
`Listener`). Fixed by setting `O_NONBLOCK` on the listening fd in
`lyric_sock_listen`. `lyric_sock_accept` (the plain blocking wrapper, used
only by the `lyric-rt` C test harness, never by production Lyric code)
now polls-and-retries on `EAGAIN`/`EWOULDBLOCK` via `poll(2)` to preserve
its blocking contract over the now-non-blocking fd. Accepted connection
fds do not inherit `O_NONBLOCK` from the listening socket on Linux, so no
behavior change leaks past `accept()` itself.

**Verification.** `llvm_stdlib_self_test.l` gained two new cases
(`readTextOrPanic` round-trip + missing-path panic regression;
`appBaseDirectory` asserting the returned directory actually contains the
running binary, not just that the call doesn't panic) — 26/26 cases pass.
`make -C lyric-rt test` (`lyric_rt_test` + `lyric_tls_test`) passes,
validating the C-level accept fix. `lyric-stdlib/tests/file_tests.l`
(dotnet target) — 11/11 pass, no regression from the shared `std/file.l`
change.

**Related:** D-progress-910 (`#4752`'s residual-seam audit, the origin of
all three issues), #6806 (the original accept-interrupt fix #6962 is a
follow-up to), #6887 (the `Std.Process` piped-API sibling of #6961's D-N-003
root cause), `docs/10-bootstrap-progress.md` ("Native N5 slice B residual-seam
audit closes out issue #4752", corrected inline), `native/plan/08-work-items.md`
N5.7.
