# D611 - `Std.TcpHost` has a JVM kernel, and `hostConnect` takes a connect timeout (#9042)

**Status:** shipped.

## Context

`lyric-stdlib/std/_kernel_jvm/` had no `tcp_host.l`, so the dotnet kernel was
compiled for the JVM and any program that called `Std.TcpHost` failed with
`J002 ... stackmap simulation underflow at newServerOptions`. Libraries that
needed a TCP client or listener on both targets carried their own
`java.net.Socket` kernel (`lyric-ecosystem` `net`, ActiveMQ), and the dotnet
e2e suite of `lyric-ws` could not run on the JVM. `hostConnect` also had no
connect timeout on dotnet (the OS limit applies, about two minutes for a
blackholed address) and native's bounded operations (D605) were reachable only
through `hostConnectBounded`.

## Decision

1. **`_kernel_jvm/tcp_host.l` is the JVM twin of `_kernel/tcp_host.l`**, with the
   same public `host*` surface and `TcpError` cases: `hostListen`,
   `hostLocalPort`, `hostConnect`, `hostStopListener`, `hostAccept`,
   `hostAcceptTls`, `hostPrepareServerTls`, `hostReleaseServerTls`,
   `hostUpgradeServerTls[Prepared]`, `hostSetIoTimeout`, `hostAlpn`, `hostRead`,
   `hostWrite`, `hostRemoteAddress`, `hostClose`. It uses `extern type` and
   auto-FFI only.
2. **Semantics match dotnet.** A read returns an empty slice at end of stream and
   `Err(TransportFailed)` on error or I/O timeout; a write returns `Err` on a
   broken pipe or an I/O timeout; `hostStopListener` closes the listening socket
   so a blocked `hostAccept` fails with `AcceptFailed`; every JDK exception is a
   `Result`.
3. **Reads and writes.** A read blocks for one byte, then takes `available()`:
   `InputStream.read(byte[], ...)` cannot be used because a Lyric slice argument
   is passed as a copy. A plain `java.net.Socket` has no send timeout, so when
   `hostSetIoTimeout` is set a write runs on a virtual thread that is abandoned
   (the socket is closed) after the limit without progress.
4. **Server TLS** layers `SSLSocket` over the accepted socket. The `SSLContext`
   comes from `Std.HttpServer.serverSslContextFromConfig[Mtls]`, the single
   construction of a server context on this target (identity, TLS 1.2 floor,
   client CA). `minVersion = Tls13` also pins the socket's protocols;
   `requireClientCert` is `setNeedClientAuth`, and a `clientCa` without it is
   `setWantClientAuth`. ALPN offers `h2` then `http/1.1`
   (`SSLParameters.setApplicationProtocols`); `hostAlpn` is
   `SSLSocket.getApplicationProtocol()`. Array-typed JDK parameters are filled
   through `java.lang.reflect`, as elsewhere in the JVM kernels.
5. **`hostConnect(host, port, connectTimeoutMs)`** on all three targets
   (`0` = the operating system's limit; negative values violate the
   precondition). dotnet dials on `TcpClient.ConnectAsync` and waits for the task
   at most the limit, disposing the client when it expires; the JVM uses
   `Socket.connect(address, ms)`; native uses `hostConnectBounded` with a
   monotonic deadline. An expired connect is
   `Err(TransportFailed("connect timed out after N ms"))` on every target. Every
   caller in the repository passes `0`, which keeps the previous behaviour.

## Consequences

- `Std.TcpHost` is usable on dotnet, the JVM and native. Ecosystem packages that
  carry their own JVM socket kernel can move to it (tracked in the issue draft
  in the progress note).
- The source change to `hostConnect` is breaking for callers outside this
  repository, which must add the argument.
- Client-side TLS (`hostConnectTls`, native only today) is not part of this
  decision; dotnet and the JVM reach TLS clients through `Std.Http`.
