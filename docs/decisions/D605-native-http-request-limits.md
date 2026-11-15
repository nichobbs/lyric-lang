# D605 - `Std.Http` on native runs a send within its cancellation token's limits (#9090)

**Status:** accepted; shipped for Linux and macOS. The Windows twin is written
and has not been compiled or run.

## Context

`Std.Http` has no request timeout of its own. A send is bounded by the
`CancellationToken` it is given (`sendWithCancel`, the `*WithCancelAsync`
functions and the `*WithTimeoutAsync` wrappers): .NET cancels the request
task, the JVM kernel turns the token's deadline into the JDK request timeout.
The native kernel wrote the HTTP exchange itself over blocking sockets and
ignored the token, so a request to a server that never answered waited for
good. The HTTP backends in `lyric-ecosystem` tell a timeout (the request may
have been applied) from a failed connection (it was not) by this.

## Decision

1. **The token bounds the whole send.** Name resolution, the TCP connect,
   the TLS handshake, the request write and the response read (status line,
   headers, body in every framing), across redirects. The deadline of
   `makeCancelSourceTimeout` is one absolute instant for all of it. It is not
   an idle timeout: a peer that sends a byte now and then does not extend it.
   There is no separate connect timeout.
2. **Outcomes.** A passed deadline is `ConnectionFailed(url, "request timed
   out")`, the JVM kernel's text, and is never reported before the monotonic
   clock reaches the deadline, so `isCancelled(token)` is true by then (the
   order the JVM gets wrong in #9067). `cancelSource`/`cancelScope` from
   another thread ends the send at once with `ConnectionFailed(url, "request
   cancelled: cancellation was requested")`. A token that is already
   cancelled fails the send before any connection is made. Every other
   failure keeps its own cause. `HttpError.Timeout` stays unproduced on every
   target until #9067 changes the shared mapping in `std/http.l`.
3. **Mechanism: bounded operations in lyric-rt.** `lyric_sock_connect_bounded`,
   `lyric_sock_read_bytes_bounded`, `lyric_sock_write_bytes_bounded` and their
   `lyric_tls_*` forms take an absolute `lyric_monotonic_nanos` deadline and
   the read end of a wake pipe, wait in `poll` on both, and report
   `LYRIC_BOUNDED_OK`, `_ERROR`, `_DEADLINE` or `_INTERRUPTED`. A TLS
   operation switches the socket to non-blocking for its own duration and
   back, so OpenSSL's `WANT_READ`/`WANT_WRITE` become waits under the same
   limits and the unbounded functions are untouched. A name that is not an
   address literal is looked up on a helper thread, which is left to finish
   when the limit passes first, because `getaddrinfo` can be neither bounded
   nor interrupted.
4. **Cancellation is a wake-up, not a poll.** A send under a token opens a
   wake pipe and registers its write end for the token's source
   (`lyric_cancel_wake_register`); `Std.Task.cancelSource` calls
   `lyric_cancel_wake_signal`. The pipe is registered before the token is
   tested, so a cancel that lands in between is not lost. Two descriptors per
   cancellable send, closed when it returns.
5. **`Std.TcpHost` (native) exposes the bounded operations**
   (`hostConnectBounded`, `hostUpgradeClientTlsBounded`, `hostReadBounded`,
   `hostWriteBounded`, `WakePipe`, `BoundedError`), `@experimental`. Their
   outcome is a union case, not a message. They have no dotnet counterpart
   yet (see "Not in this slice").
6. **No send panics.** A Unix-socket client, which native cannot serve, is
   built and fails each request with `ConnectionFailed` naming the gap; it
   used to panic at construction, which native cannot catch.

7. **Name lookups in flight are capped (#9137).** A name is looked up with
   `getaddrinfo` on a detached helper thread, which cannot be interrupted, so
   a waiter whose deadline passes abandons its helper until the resolver
   returns. Against a resolver that never answers, one thread per attempt
   used to pile up without bound. At most `LYRIC_RESOLVE_MAX_INFLIGHT` (32)
   lookups are in flight at once, abandoned ones included (a helper counts
   until `getaddrinfo` returns, not until its waiter stops waiting); a bounded
   connect to a name beyond that fails at once with `LYRIC_BOUNDED_ERROR` and
   "resolve <host>: too many name lookups in flight", which `Std.Http` reports
   as `ConnectionFailed` like any other lookup failure. Address literals never
   use a helper and are unaffected. Identical in-flight lookups are not
   coalesced: the cap alone bounds the cost, and coalescing would have to
   share one result between waiters with different deadlines. The Windows twin
   (`lyric_sock_win32.c`, an interlocked counter) is written the same way and,
   like the rest of that file, has not been compiled. `lyric_tls_test.c`
   swaps the lookup through an internal function pointer
   (`lyric_resolve_lookup_hook`, defaulting to `getaddrinfo`) to hold lookups
   open, reaches the cap, sees the error, releases, and sees lookups succeed
   again. That test is built on Linux and macOS only: the Windows lookup has
   no such seam yet, so the Windows cap compiles but is not exercised (#9159).

## Not supported, and said so

- Sends without a token have no limit, as on the JVM (.NET alone applies
  `HttpClient`'s default 100 s).
- `bodyTextWithCancel` has nothing to interrupt: the send buffers the whole
  response. It fails for a token that is already cancelled.
- The send blocks its thread; it is not a reactor task.

## Not in this slice

- **Windows.** `lyric_sock_win32.c` and `lyric_tls_win32.c` implement the
  same functions (a per-thread bound that the two socket wait points test;
  `select` for the connect; a helper thread and an event for the lookup).
  This checkout has no Windows SDK, so that code has not been compiled, and
  the new suites are not in `scripts/ci/windows-native-tests.sh`.
- **The same API on dotnet (#9042, #9090 item 4).** `Std.TcpHost` on dotnet
  has `hostSetIoTimeout` only, and a timeout there is still a
  `TransportFailed` message. Bringing the bounded operations to the dotnet
  kernel, or a `TcpError.TimedOut` case to both, is a change to a shared
  union and a second kernel and is not done here.
- **`HttpError.Timeout` (#9067).**
