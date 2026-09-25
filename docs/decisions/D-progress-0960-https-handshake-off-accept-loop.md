# D-progress-960 — HTTPS handshakes off the accept loop, with handshake and idle timeouts (#7268)

**Status:** shipped

## Problem

- The dotnet and native `Std.HttpServer` TLS accept loops called
  `hostAcceptTls`, which ran the whole server handshake on the accept loop.
  A peer that connected and never sent a ClientHello blocked every later
  connection indefinitely.
- No handshake, read or idle timeout existed, so silent peers held
  connection permits (dotnet) and threads (native) for as long as they kept
  the socket open.
- The native kernel built and freed a fresh `SSL_CTX` (PEM parsing
  included) per connection; dotnet rebuilt `SslServerAuthenticationOptions`,
  including its reflection-set ALPN list, per connection.
- The native `lyric_tls_read`/`lyric_tls_write` loops treated `WANT_READ`/
  `WANT_WRITE` as always retryable, so a socket timeout became another
  blocking call and never returned.

## Decision

- `Std.TcpHost` (dotnet and native) gains `ServerTls`,
  `hostPrepareServerTls(cfg)` (validate once, build the reusable TLS state:
  options plus an offline `SslStreamCertificateContext` on dotnet, one
  `SSL_CTX` on native), `hostUpgradeServerTlsPrepared(conn, tls,
  handshakeTimeoutMs)`, `hostReleaseServerTls`, and `hostSetIoTimeout(conn,
  ms)`. `hostUpgradeServerTlsPrepared` leaves the plain connection for the
  caller to close on failure, so the native server can deregister it before
  its fd is released (the #6791 ordering rule). `hostAcceptTls` and
  `hostUpgradeServerTls` keep their close-on-failure contract and are built
  on the new functions.
- The server accept loops accept the raw socket only. The handshake runs on
  the connection's task/thread; a negotiated-h2 connection on native is
  still closed there.
- Timeouts are per blocking socket operation (`SO_RCVTIMEO`/`SO_SNDTIMEO`,
  `TcpClient.ReceiveTimeout`/`SendTimeout`): 10 s for the handshake
  (Kestrel's default) and 120 s of inactivity afterwards, overridable per
  deployment with `LYRIC_HTTPS_HANDSHAKE_TIMEOUT_MS` and
  `LYRIC_HTTP_IDLE_TIMEOUT_MS`, following the `LYRIC_HTTP_MAX_CONNECTIONS`
  precedent (invalid or `< 1` values fall back to the default).
- The native TLS read/write loops report a `WANT_*` with `EAGAIN` as a
  timeout error.
- The JVM is unchanged: `HttpsServer` already handshakes off its dispatcher
  thread with one `SSLContext` per listener, and the JDK applies its own
  idle limit (`sun.net.httpserver.idleInterval`).

A timeout field on `TlsServerConfig` or `EngineLimits` was considered and
not taken here: `TlsServerConfig` is `@stable` and has no idle timeout
concept, `EngineLimits` is the sans-IO engine's and deliberately has no
defaulted fields, and the JVM server could not honour a per-listener value.

## Verification

- `lyric-rt/test/lyric_tls_test.c`: plain read, TLS handshake and TLS read
  time out on a silent peer. The TLS read case hangs without the retry-loop
  fix.
- `http_server_dotnet_tests.l`: a client behind a silent peer is served; a
  silent peer is closed at a 300 ms handshake timeout; an idle keep-alive
  connection is closed at a 300 ms idle timeout; the environment overrides
  resolve with fallback.
- `llvm_http_server_self_test.l` items K and L: the same off-accept-thread
  and idle behaviour on native under ASan.
