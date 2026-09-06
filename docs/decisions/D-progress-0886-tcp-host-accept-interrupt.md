# D-progress-886 — Native `Std.TcpHost`: portable accept() interrupt via a self-pipe + `poll(2)`, replacing the Linux-only `shutdown()`-on-listening-socket trick (#6806, closing the gap #6804 disclosed at N9.3 ship time)

**Status:** shipped

**The gap.** `_kernel_native/tcp_host.l`'s `hostStopListener` interrupted a
blocked `hostAccept` call on another thread by calling `shutdown(fd,
SHUT_RDWR)` on the LISTENING socket before `close()`ing it. Linux documents
delivering `EINVAL` to a concurrently-blocked `accept()` for this specific
case, which is why it worked in CI (Linux-only) — but this is not POSIX
behavior generally: on macOS/BSD, `shutdown()` on a listening socket
returns `ENOTCONN` and does not unblock a concurrent `accept()` at all.
D-progress-850 (N9.3, `Std.HttpServer`'s native twin) shipped on top of
this knowing the gap and filed it as #6806 rather than silently assuming
portability — this entry closes it.

**The fix: the standard self-pipe trick, not a platform table.** Rather
than special-casing macOS with a different interrupt mechanism (the kind
of `@cfg(target = ...)` branch this tree avoids wherever a single portable
implementation exists), `hostAccept` no longer calls the bare blocking
`lyric_sock_accept` at all. Three new `lyric-rt` seam functions
(`lyric_sock_wake_pipe_new`, `lyric_sock_wake_pipe_signal`,
`lyric_sock_accept_interruptible`, all in `lyric_tls.c` alongside the rest
of the `lyric_sock_*`/`lyric_tls_*` transport seam) implement it:
`lyric_sock_wake_pipe_new` allocates a private, non-blocking,
close-on-exec `pipe(2)` (Linux: `pipe2(O_CLOEXEC|O_NONBLOCK)`; other POSIX
targets: `pipe(2)` + `fcntl` to set both flags on each end, since `pipe2`
is a Linux-only extension); `lyric_sock_accept_interruptible` `poll(2)`s
the listening fd alongside the pipe's read end and returns the accepted fd
the instant the listener is readable, or a new sentinel value **`-2`**
(distinct from `-1`) the instant the pipe is readable instead — draining
whatever is buffered and never touching the listening socket on that path
at all; `lyric_sock_wake_pipe_signal` writes one byte to the pipe's write
end from any thread, treating `EAGAIN` on the non-blocking write (the
buffer already holds an undrained wake byte — a duplicate/racing signal)
as success rather than a failure, since the reader will observe the
existing byte regardless. `lyric_sock_accept`, `lyric_sock_accept_errno`,
and `lyric_sock_accept_error_class` are all UNCHANGED (`lyric_tls_test.c`'s
existing TLS-scenario harness calls `lyric_sock_accept` directly on
several threads and would have needed a parallel rewrite for no benefit);
`lyric_sock_accept_interruptible` reuses the same thread-local
errno/error-class state so a caller-side `AcceptFailureKind` classification
(#6805) keeps working identically for the ordinary accept-failure path,
and explicitly resets it to `0` (→ `AcceptFatal`, "the caller's accept loop
should end") on both the pipe-interrupt path and its own defensive
`POLLERR`/`POLLHUP`/`POLLNVAL`-on-the-pipe branch (the wake pipe itself
faulting, which should never happen given the fixed close ordering
`hostStopListener` uses, but is handled the same way as a genuine stop
request rather than spin-polling on a condition that would never clear).

**Lyric-side (`_kernel_native/tcp_host.l`) changes, matched exactly to the
new seam.** `Listener` gains two package-private fields, `wakeReadFd`/
`wakeWriteFd`, allocated by `hostListen` right after a successful
`rtSockListen` (a wake-pipe allocation failure closes the just-bound
socket and reports `BindFailed` too — a `Listener` this kernel cannot
later interrupt is not safely usable, so this is not a case worth
degrading gracefully for). `hostAccept` calls the new
`rtSockAcceptInterruptible(l.fd, l.wakeReadFd)` instead of the old bare
`rtSockAccept(l.fd)`, mapping a `-2` result to
`Err(AcceptFailed(message = ..., errno = 0, kind = AcceptFatal))` — the
exact same `AcceptFatal` classification callers already treat as "end the
accept loop" (`_kernel_native/http_server.l`'s `plainAcceptLoop`/
`tlsAcceptLoop` needed ZERO changes as a result: the classification
contract they already consume didn't change shape, only how it gets
produced). `hostStopListener` no longer calls `rtShutdown` on the
listening socket at all — it calls `rtSockWakePipeSignal(l.wakeWriteFd)`
and returns; it does NOT also close the listening socket or the pipe
(see the TOCTOU addendum below for why that split exists and what calls
the new, separate `hostCloseListener`). `rtShutdown`/`shutdown(2)`
remains bound and in use for `hostShutdown` (interrupting an
already-ACCEPTED connection's blocked read/write) — that function's own
existing doc comment already establishes `shutdown()` as portable for a
CONNECTED socket on every POSIX target this project builds for; only the
LISTENING-socket case had the platform divergence, so nothing about that
path needed to change. The now-dead `rtSockAccept` extern binding (nothing
in this file calls it anymore) was removed rather than left as unused
dead code; the C-level `lyric_sock_accept` function it bound stays, used
directly by `lyric_tls_test.c`'s existing harness. Every stale doc-comment
cross-reference this change made incorrect (the `AcceptFailureKind`
union's own case comments, the `rtShutdown` extern's comment, and
`hostStopListener`'s own doc comment, which previously spent several
paragraphs explaining the now-removed Linux-only limitation) was rewritten
in place, not left describing removed behavior.

**Verification.** `lyric-rt/test/lyric_tls_test.c` gained four new cases,
all green locally (`make -C lyric-rt test` with both `gcc`/`clang`, and
`make -C lyric-rt test-asan CC=gcc`, clean — no new `lyric-rt` build
warnings under `-Wall -Wextra -Werror`): `test_accept_interruptible_normal`
(the interruptible entry point still accepts an ordinary connection
normally when nobody signals the pipe — the interrupt path is an ADDITION
to accept(), never a replacement of its ordinary behavior);
`test_accept_interruptible_wakeup` (a real second thread genuinely parked
in `poll()` with no pending connection, woken by a signal from the main
thread, asserting the exact `-2` sentinel); `test_accept_interruptible_presignaled`
(a signal sent BEFORE the accept call ever runs still wakes it immediately
— no lost-wakeup race, since the pipe buffer holds the byte until read,
same guarantee a POSIX semaphore's count gives); `test_accept_interruptible_double_signal`
(signaling twice before any drain is not a failure — the `EAGAIN`-swallowing
behavior). `lyric_tls.c` needed `_GNU_SOURCE` added to its Linux feature-test
macro block (`pipe2` is a Linux extension gated on that macro specifically;
`_DEFAULT_SOURCE` alone, already defined there, does not expose it) — the
only build-flag change this entry makes. `lyric-compiler/lyric/
llvm_http_server_self_test.l` gained item J (ten repeated
`startListener`/`stopListener` cycles with no client ever connecting in
between — the direct end-to-end proof that the portable interrupt wakes a
genuinely-parked accept-loop thread with no live connection and no
Linux-specific `shutdown()` side effect to fall back on), verified on real
Linux CI (`native-backend-self-tests`, real `clang` + real
`Lyric.LlvmCodegen`) alongside the existing items A–I, none of which
regressed. **Sandbox boundary, same class as D-progress-712/809/823/850:**
this session could not run `scripts/bootstrap.sh --stage 0`/`--stage 1` (the
GitHub release-artifact download is network-policy-blocked), so item J and
the Lyric-side `tcp_host.l` changes are CI-verified only, not locally
compiled; the C-level seam (the actual portable-interrupt mechanism) IS
independently verified locally via the four new `lyric_tls_test.c` cases
above, including under ASan.

**Disclosed scope, not silently assumed: macOS/BSD correctness follows
documented POSIX semantics (`poll(2)`, `pipe(2)`, non-blocking `write(2)`
on a pipe) but was NOT machine-verified on real macOS/BSD hardware** — this
project's CI is Linux-only (unchanged by this entry). Unlike the prior
`shutdown()`-based design, nothing in the new mechanism is Linux-specific
by construction (no reliance on a `shutdown()`-on-listening-socket side
effect, no Linux-only errno mapping), so there is no known reason it
would behave differently on macOS/BSD — but "no known reason" is a weaker
claim than "verified," and is stated as such rather than papered over.

**Related:** #6806 (this entry's issue), #6804 (the original disclosed gap,
now closed), D-progress-850 (N9.3, where the gap was first found and
filed rather than silently shipped), D-progress-712 (N9.2, this file's own
original `Listener`/`Conn` design this entry extends without changing).

**Addendum: `hostStopListener`/`hostCloseListener` split fixes a TOCTOU
fd-reuse race (#6883, found in review of this same change before merge).**
The first version of this entry's `hostStopListener` signaled the wake
pipe AND immediately closed the listening socket plus both pipe fds, all
on the calling (stopping) thread, with no synchronization confirming the
accept-loop thread had actually drained the signal. `Std.HttpServer.
stopListener` only `pthreadJoin`s that thread AFTERWARD, so there was a
real window where an unrelated fd opened elsewhere in the process could
reuse one of the just-closed fd numbers before the still-in-flight accept
thread's own wake-pipe drain `read()` ran — silently corrupting or
stealing bytes from that unrelated resource instead of harmlessly
no-op'ing, or hanging the accept thread if the reused fd happened to be
blocking. Fix: `hostStopListener` now ONLY signals (see above); a new
`hostCloseListener(l)` does the actual close, and is called ONLY after a
caller has positively confirmed the accept-loop thread exited (a
`pthreadJoin` return) — `Std.HttpServer.stopListener` is the reference
caller, calling `hostStopListener`, then `pthreadJoin`, then
`hostCloseListener`, in that order. The one call site with no accept
thread to join (a `pthreadCreate` failure during `startListener`/
`startListenerTls`, before any thread was ever spawned) calls
`hostCloseListener` directly, with no preceding `hostStopListener` call —
there is nothing to signal. `llvm_tls_self_test.l` and
`llvm_http_client_self_test.l` call `Std.TcpHost` directly (no
`Std.HttpServer` involved) and, in every case, already `pthreadJoin` (or
never spawn) their own worker before their cleanup call — these were
updated from the old single `hostStopListener` cleanup call to
`hostCloseListener`, matching the same "no thread left to signal at this
point" reasoning. Re-verified: `llvm_http_server_self_test.l` (10/10,
including item J), `llvm_tls_self_test.l` (5/5), `llvm_http_client_self_test.l`
(13/13), all `lyric-rt` C tests green.
