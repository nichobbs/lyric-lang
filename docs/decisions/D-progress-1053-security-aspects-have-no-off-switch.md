# D-progress-1053 — Authentication aspects have no `enabled` switch, and `Mcp.Client` errors are typed (#7249, #7522)

**Status:** shipped

## Authentication aspects lose `enabled`

Every aspect configuration field is readable from the environment
(`LYRIC_ASPECT_<INSTANTIATION>_<FIELD>`). `RequiresAuth`, `RequiresRole`,
`ApiKey` (lyric-web), `WsAuth` (lyric-ws) and `ValidateKey` (lyric-auth) each
had `enabled: Bool = true`, so setting one environment variable, or a typo in
a deployment template, turned authentication off for every matched handler
with no log line. #7249 offered two fixes: drop the switch, or warn at start
up.

**Decision.** Drop it. A warning at start up is easy to miss and the switch
has no production use: a handler that should not be guarded is left out of the
aspect's `matches:` or listed in `except`. A leftover `..._ENABLED` variable is
now ignored. The switch stays on the aspects that are not a security boundary
(`RateLimit`, `RateLimitByClient`, `HttpCircuitBreaker`, `WsRateLimit`).

The weaving tests that asserted the bypass now assert the opposite: a guard
with no credential rejects the call.

## `Mcp.Client` errors are a union

`Mcp.Client` returned `Result[T, String]`, so a caller could not tell a
deadline (retry) from a tool error (do not). #7522 asked for a union.

`McpClientError` has four cases, named distinctively because case names share
a bundle-global table (#5903):

- `McpTimeout(method, timeoutMs)`: the client's own deadline passed.
- `McpRpcFailure(method, code, message, data)`: the server answered with an
  error. A server that sends its own `-32001` is this case, not a timeout.
- `McpTransportError(message)`: the transport failed or closed, or the peer
  sent a malformed message.
- `McpProtocolError(message)`: the server answered, but not with what MCP
  defines for the method.

`JsonRpc.isTimeoutError` matches only the wire code `-32001`, so it cannot make
this distinction. `JsonRpc` now marks the errors `call`/`callWithin` produce
itself with a `lyricLocal` member in `RpcError.data`, and `isLocalError(e)`
reads it. Local errors are never sent to a peer, so the marker only separates
them from a peer's own error response. A peer can put the same member in its
own error data, which would misclassify one error; the result is a different
retry decision, not a security boundary.

This is a breaking change to `Mcp.Client`'s public API, taken before 1.0.
`connectTransport` and `connectStdio` keep a `String` error, because their only
failure is a spawn failure.
