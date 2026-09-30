# D146 — WebSocket endpoints on a `lyric-web` router's port

**Status:** accepted, implemented

Resolves #7831; docs/65 §15 findings F-11 and F-16.

## Context

`lyric-ws` could only serve a socket from a listener of its own
(`Ws.startServer*`), and `lyric-web` had no way to hand a request to
another protocol. `Ui.Host.Web` therefore served its page on `port` and its
session socket on `wsPort`. That cost a second port in every deployment and
proxy configuration, and it made page and socket cross-origin: the #7243
Origin check refused every browser handshake until `WsServerOptions.
sameHostPorts` was added to admit a sibling port (#7836).

## Decision

1. **`Ws.createEndpoint(path, options, handler)`** creates a WebSocket
   endpoint with no listener. It returns a `WsEndpoint` whose `registry` is
   an ordinary `NativeRegistry`, so pushing messages works as with
   `startServer`. `options` apply unchanged, including the Origin check.
2. **`Web.addWebSocket(router, endpoint)`** serves it on the router's port
   at exactly `endpoint.path`. `lyric-web` gains a dependency on
   `lyric-ws`; the reverse would force every standalone WebSocket user to
   take the web framework.
3. The endpoint is matched **before middleware and route dispatch**, and
   `prefix` does not move it. The endpoint's path is fixed when it is
   created (the kernels check it), and HTTP middleware is written against
   `Response`, which an upgraded connection never produces. Authorisation
   for a socket belongs in `WsHandler.onOpen` or the `Ws.Aspects.WsAuth`
   aspect, as for `startServer`.
4. **dotnet** hands the connection over through a new
   **`Std.HttpServer.takeConnection(ctx): Result[Conn, String]`**: the
   connection task stops parsing HTTP and leaves the socket open, and the
   connection stops counting against the listener's connection cap (it is
   long-lived and no longer HTTP). `takeConnection` refuses, and the
   request is answered `400`, when the request is an HTTP/2 stream (which
   shares its connection), is not HTTP/1.1, or was followed by pipelined
   bytes before any response: the engine has already consumed those bytes,
   and RFC 6455 §4.1 forbids a client from sending before the `101`.
   `Ws.Kernel.Net.adoptConnection` then validates the already-parsed
   request (`Ws.Handshake.validateUpgradeRequest`), applies the Origin
   check, answers `101`, clears the HTTP idle timeout (WebSockets rely on
   ping keepalive) and runs the same read loop as `startServer`.
5. **JVM** mounts `Ws.Kernel.Jvm.endpointHandler` (the same Origin-guarded
   Undertow handshake handler `startServer` installs) on the Undertow
   listener with an exact-path `PathHandler` in front of the Lyric
   dispatch handler.
6. `Ui.Host.Web` uses one port: `HostConfig.wsPort` is removed, the shell
   builds the socket URL from the page's own `Host` header, and
   `WebHost.router(cfg, route)` now returns the whole host (socket
   included) as a router for merging.

## Consequences

- `takeConnection` exists on the dotnet `Std.HttpServer` kernel only. The
  JVM kernel wraps the JDK's `com.sun.net.httpserver`, which never exposes
  its sockets, and `lyric-web` on the JVM does not use `Std.HttpServer`.
  The native kernel rides `Std.TcpHost` like dotnet and could add it; no
  native consumer exists yet (`lyric-web` has no native backend).
- An upgrade that fails `takeConnection` is answered `400` rather than
  routed, since the path belongs to the endpoint.
- `WsServerOptions.sameHostPorts` stays for servers that do use a separate
  WebSocket listener.
