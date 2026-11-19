# D621 - `Std.TcpHost` is fit to carry a server on dotnet and the JVM (docs/73 slice S1)

**Status:** shipped. Extends D611 (the JVM `Std.TcpHost` kernel); supersedes nothing.

## Context

docs/73 replaces the JVM `com.sun.net.httpserver` and Undertow servers with the
pure-Lyric `Std.HttpEngine` driver over `Std.TcpHost`. D611 shipped a first JVM
`Std.TcpHost` kernel that could not yet carry a server: a read allocated a
`ByteArrayOutputStream` and made three stream calls, every write with an I/O
timeout started and joined a virtual thread, there was no `hostShutdown`, and the
kernel imported `Std.HttpServer` for its server `SSLContext`, so `Std.HttpServer`
could never import `Std.TcpHost`.

## Decision

1. **Reads (JVM).** Each `Conn` owns one 16 KiB `ByteBuffer`. `hostRead` calls
   `InputStream.read(buffer.array(), 0, n)` with the array fetched as an extern
   argument in the same expression, so the compiler hands the raw `byte[]`
   through and the JDK fills it in place (a Lyric `slice[Byte]` argument is a
   copy on this target, so the array is never bound to a Lyric name, T0157). Only
   the `n` bytes that arrived leave as a fresh slice (`Arrays.copyOfRange`, then
   the boxing pass the `Object[]` slice representation requires). One
   `read(buf, 0, n)` already blocks for the first byte and returns what is
   available, so no buffered stream, no `available()` probe and no
   `readNBytes()` are needed. That is also why an `SSLSocket` is correct: its
   stream's `read` decrypts the next record when none is buffered, while
   `SSLSocket.available()` reports only the current record and would stall
   between records. A read returns at most 16 KiB per call (the dotnet kernel's
   `readBufferSize`).
2. **Write timeout (JVM): one shared watchdog, armed per write.** Alternatives
   weighed: NIO `SocketChannel` (does not cover `SSLSocket`, which every TLS
   server connection is), a `ScheduledExecutor` task per write (an allocation and
   two queue operations per write), and the old virtual thread per write (a
   thread start and join per write). Chosen: each connection with an I/O timeout
   has a guard in a global registry; one virtual thread started on first use
   sweeps it every 50 ms. `hostWrite` stamps the guard with a deadline before the
   write and clears it after, on the caller's thread (two atomic stores). The
   watchdog closes the underlying plain socket of a guard whose armed deadline
   passed; the blocked `write` then throws and `hostWrite` reports
   `Err(TransportFailed("write timed out: the peer accepted no data for N ms"))`
   (the same text as before). A compare-and-set from "armed" decides between "the
   write finished" and "the watchdog fired", so a write that completes is never
   closed after the fact. The deadline is detected within 50 ms after it expires;
   a connection with a timeout costs one atomic read per sweep; closed sockets
   leave the registry at the next sweep.
3. **Write progress semantics are chunk-granular and explicit.** A write of at
   most 64 KiB is one `OutputStream.write` with no visibility into partial
   progress: it must complete as a whole within the limit. A larger write is sent
   in 64 KiB chunks and each completed chunk re-arms a fresh window, so a peer
   that keeps draining is never cut off while a peer that accepts nothing for the
   limit ends the write. A timed-out write closes the connection; the caller
   cannot know how many bytes were sent. Writes on one connection must not run
   concurrently (they share the guard), the same rule as for reads. (dotnet's
   `SendTimeout` and native's bounded write are per-syscall inactivity limits; the
   JVM rule is the closest a blocking `OutputStream` allows.)
4. **`hostShutdown(conn)` on dotnet and the JVM**, the contract native already
   had: it ends a read or write blocked on the connection from another thread and
   does not release the connection; the owner still calls `hostClose`, which is
   safe afterwards. dotnet: `Socket.Shutdown(Both)` on the `TcpClient`'s socket,
   for plain and TLS connections alike. JVM: `shutdownInput` and `shutdownOutput`
   on the underlying plain socket (`Conn.raw`), for both kinds, because
   `SSLSocket` rejects half-close (`UnsupportedOperationException`) and closing an
   `SSLSocket` from another thread while a write holds the TLS output lock can
   itself block; the same reason the watchdog closes `raw`, not the `SSLSocket`.
   No TLS close_notify is sent. A blocked read ends as end of stream or an error.
5. **Import cycle broken.** The server `SSLContext` construction (the
   `KeyManagerFactory`/`KeyStore` reflection bridge, the TLS 1.2 floor check, the
   mTLS trust store) moved from `_kernel_jvm/http_server.l` into the JVM-only
   package `Std.TlsServerContext` (`_kernel_jvm/tls_server_context.l`), imported by
   `Std.TcpHost` and by `Std.HttpServer`. `Std.HttpServer` re-exports it with
   `pub use`, so `serverSslContextFromConfig[Mtls]`, `ServerSslContext` and the
   `internal` `rawContext` are unchanged for `lyric-web` and
   `tls_server_jvm_tests.l`. `Std.TcpHost` no longer imports `Std.HttpServer`.
6. **Listen backlog.** JVM and native pass 128; dotnet's `TcpListener.Start()`
   asks for SOMAXCONN, which the operating system clamps to its own limit (often
   larger). The difference is recorded, not changed: the engine driver bounds
   concurrent connections itself (`LYRIC_HTTP_MAX_CONNECTIONS`) and a deeper queue
   on dotnet is harmless.
7. **No `hostSetKeepAlive`.** A server's liveness for idle keep-alive connections
   comes from the per-connection idle timeout (`hostSetIoTimeout`, read side),
   which every target has; no target lacks a way to bound an idle peer, and TCP
   keepalive probes (minutes by default) would not replace it. Adding the function
   on three targets without a consumer would be surface without a use; it can be
   added additively when one needs it.
8. **dotnet sets `TCP_NODELAY`** on every connection (`TcpClient.NoDelay`), as the JVM kernel already did. A server answers in one or two segments and must not wait out Nagle's algorithm against the peer's delayed ACK; the benchmark's multi-segment 256 KiB echo went from 9 to about 950 MiB/s. Native POSIX connections do not set it (Windows does); left as an open item.
9. **Small #9183 review items.** `JSocket.new()` in `hostConnect` is inside the
   `try`, and a failure while wrapping an accepted or connected socket (stream
   acquisition) closes it instead of leaking; the write-watchdog progress rule is
   documented (point 3).

## Not done

- JVM loopback throughput for 16 KiB and larger messages stays 3.5x to 8.5x below
  dotnet because a `slice[Byte]` is a boxed `Object[]` on the JVM; closing it needs
  a compiler change (a `byte[]` representation or a bulk-conversion intrinsic),
  tracked in #9245.
- #9184 (native `hostStopListener` leaves the listening fd open) is not part of
  this slice. The split between `hostStopListener` (signal) and `hostCloseListener`
  (release after the accept thread exited) is deliberate (#6883, an fd-reuse
  hazard), so making stop close the fd changes the native contract and every
  native server's shutdown path; `tcp_host_tests.l` and `http_timeout_tests.l`
  therefore stay off the native lists. It belongs with docs/73 S5.

## Consequences

- The JVM `Std.TcpHost` is usable as the transport of the shared server driver
  (docs/73 S3 and S4), and `lyric-ws` can run on it (S7a).
- A JVM write with a timeout set no longer starts a thread; the numbers are in
  `docs/progress/2026-11-19-tcphost-server-ready.md`.
- The public `Std.TcpHost` surface is identical on dotnet, JVM and native;
  `hostShutdown` is additive on dotnet and the JVM.
