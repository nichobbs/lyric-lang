# WebSocket endpoints on a `lyric-web` router's port (#7831)

`Ui.Host.Web` used to serve its page on `port` and its session WebSocket on
`wsPort`, because `lyric-ws` could only run a listener of its own and
`lyric-web` could not hand a request to another protocol (docs/65 §15,
F-11). Page and socket are now served on one port (D146).

- `Ws.createEndpoint(path, options, handler)` creates a WebSocket endpoint
  with no listener. Its `registry` works like a `startServer` registry.
- `Web.addWebSocket(router, endpoint)` serves it on the router's port at
  exactly `endpoint.path`, before middleware and route dispatch. `lyric-web`
  now depends on `lyric-ws`.
- dotnet: `Std.HttpServer.takeConnection(ctx)` detaches an HTTP/1.1
  connection from the server. The connection task stops parsing and leaves
  the socket open, and the connection is released from the connection cap.
  It refuses HTTP/2 streams, HTTP/1.0 and requests followed by pipelined
  bytes, which are answered `400`. `Std.HttpEngine.hasBufferedInput`
  reports the pipelined case. `Ws.Kernel.Net.adoptConnection` validates
  the parsed request (`Ws.Handshake.validateUpgradeRequest`), applies the
  Origin check, answers `101`, clears the HTTP idle timeout and runs the
  usual read loop.
- JVM: `Ws.Kernel.Jvm.endpointHandler`, the Origin-guarded handshake
  handler `startServer` already used, is mounted on the Undertow listener
  with an exact-path `PathHandler`.
- `Ui.Host.Web`: `HostConfig.wsPort` is gone. The shell builds the socket
  URL from the page's `Host` header, and `WebHost.router(cfg, route)`
  returns the whole host, socket included. The `sameHostPorts` workaround
  from #7836 is no longer needed there. The browser end-to-end script
  checks a single port.

Tests:

- `lyric-stdlib/tests/http_server_dotnet_tests.l` covers the handover, the
  listener serving on afterwards, and the HTTP/1.0 and pipelined refusals.
- `lyric-web/tests/web_socket_tests.l` covers a socket and ordinary routes
  on one port, an upgrade on a kept-alive connection, and the cross-site
  `403` and plain-GET `400`.
- The ui-customers browser test covers both targets.

Found along the way: the dotnet HTTP server drops the second of two
requests that arrive in one read (#7859).
