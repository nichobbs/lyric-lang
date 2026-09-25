# D-progress-962 — lyric-ws Origin check; lyric-session ids; refilling rate limiters; lyric-web contracts; JVM `catch Exception`; lambda formatting

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

## lyric-session (#7248)

- **Session ids.** An empty `LYRIC_SESSION` cookie reached the Redis
  kernels' `requires: sessionId.length > 0` and crashed the handler. Every
  store now checks `isValidSessionId` (1 to 128 characters from
  `[A-Za-z0-9_-]`) before touching its backend:
  - a malformed id loads as `None`;
  - `destroy` and `touch` are no-ops;
  - `save` returns `Err(INVALID_SESSION_ID)`.
- **`SessionConfig` invariants.**
  - The cookie name must be an RFC 6265 token.
  - `sameSite` must be a canonical `Strict`, `Lax` or `None`. A lower-case
    `none` used to skip the forced `Secure`.
  - The TTL must be 1 second to 1 year.

  `sessionConfigFromEnv` stays fail-soft and normalises its values to
  satisfy them.
- **`InProcessSessionStore`** requires a TTL in the same range; 0 used to
  mean sessions never expired. `inMemory()` now reads the configured TTL.

## Rate limiters and lyric-web (#7249)

- **Rate limiting.**
  - The four rate-limiter kernel copies (lyric-web and lyric-ws, dotnet and
    JVM) used a tumbling window. Its burst allowance was a one-time budget
    per process that never refilled, and the window allowed twice the rate
    across a boundary.
  - All four now keep a `Resilience.TokenBucket` per key. The bucket starts
    full at `rpm + burst` tokens and refills continuously at `rpm` a minute,
    counted in exact integer units of 1/60000 of a token.
  - lyric-web's `RateLimit` keys on the handler alone. The new
    `RateLimitByClient` adds a `clientId` argument, so one client cannot
    use up everyone's budget.
- **lyric-web contracts.**
  - Route patterns must satisfy `isValidRoutePattern`; a malformed `{id`
    used to be a literal segment.
  - Response header names must be tokens and values free of control
    characters. `tryWithResponseHeader` returns `Err` for values taken
    from the request.
  - Statuses are 100 to 599. `-1`, the streamed-response sentinel, made
    the client hang.
  - Static-file mounts must be valid and match whole path segments.
- **CORS.** A `*` configuration answers with a literal `*`, so browsers
  refuse credentials; it used to reflect the `Origin`. The settings are
  validated at startup.
- **503 body.** `HttpCircuitBreaker`'s response no longer names the
  internal handler.
- **Still open on #7249.**
  - Symlink resolution for dotnet static files: `GetFullPath` does not
    follow links, while the JVM's `getCanonicalPath` does.
  - The env-toggleable `enabled` switch on security aspects.
  - Ranged aspect config (#7229).

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
