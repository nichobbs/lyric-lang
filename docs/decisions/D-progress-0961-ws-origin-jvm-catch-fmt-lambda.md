# D-progress-961 — lyric-ws Origin check; JVM `catch Exception`; parenthesised lambda formatting

**Status:** shipped

## lyric-ws (#7243)

- **Origin check.** Handshake headers were discarded, so a server could not
  check `Origin`, and any web page could open a WebSocket to it carrying
  the user's cookies (cross-site WebSocket hijacking). Both kernels now
  answer `403` before the upgrade unless the request:
  - has no `Origin` header, since non-browser clients send none;
  - is same-origin, meaning the `Origin` host and port equal `Host`, which
    is the default; or
  - matches `WsServerOptions.allowedOrigins`, where `"*"` opts out.

  The policy is `Ws.Handshake.originAllowed`, shared by both targets. On
  the JVM it runs in a Lyric `HttpHandler` wrapped around Undertow's
  handshake handler, so it too acts before the `101`.
- **Headers.** Handshake headers reach `onOpen`'s `WsContext`. A repeated
  header used to hit `Map.add` on a duplicate key and abort the dotnet
  connection task; its values are now joined.
- **Contracts.**
  - `startServerWithOptions`/`WsServerOptions` carry the message-size
    invariant (1024 to 67108864), and the start functions require a valid
    port and a `/`-prefixed path.
  - The frame encoders enforce RFC 6455's control-frame limits.
  - A peer close without a status is answered with an empty Close instead
    of the reserved 1005, over-long close reasons are cut to 123 bytes, and
    unsendable close codes are an `Err`.
- **Parity.**
  - `WsRateLimit` called the dotnet-only kernel; it now uses
    `Ws.checkRateLimit`.
  - The JVM receive listener declared `WebSocketChannel` where the erased
    `ChannelListener.handleEvent` takes `Channel`, so every receive failed
    with `AbstractMethodError`.
  - `scripts/ci/lyric-ws-undertow-jvm-smoke.sh` gives the JVM server its
    first live CI coverage.

## Compiler

- **JVM `catch Exception`.** MSIL handlers always name `System.Exception`,
  so `catch Exception` and `catch Bug` behave the same there. The JVM mapped
  only `Bug` to `Throwable` and lowered `Exception` to a nonexistent class,
  so a method with such a clause failed with `NoClassDefFoundError`. Both
  names now map to `Throwable`. Language reference §8.2 documents
  `Exception` as a synonym for `Bug` in a `catch`.
- **Formatter.** `{ (a: T) -> … }` and `{ a: T -> … }` parse to the same
  parameters, but the formatter always printed the bare form, and its
  loss-check then refused every file with the parenthesised spelling.
  `LambdaParam.parenthesized` records the spelling, and the formatter
  prints it back.

## Verification

- `ws_handshake_tests.l`, `ws_frame_tests.l` and the dotnet loopback tests
  cover:
  - the cross-origin 403 and same-origin 101;
  - headers in `onOpen`;
  - the empty-close reply;
  - the close-code and frame-limit contracts.
- The JVM smoke covers the Origin policy (5 cases), `onOpen` headers, and a
  text round trip.
- `try_catch_expr_self_test.l` and its JVM twin gain a `catch Exception`
  case, and `fmt_self_test.l` a parenthesised-lambda round trip.
