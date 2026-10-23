# Ecosystem hardening batch: HTTP pipelining, HPACK, mcp errors, auth switches (#7859, #7231, #7522, #7249, #7247, #7241, #7235)

Most of the security-labelled ecosystem issues were fixed earlier in
D-progress-975 to 977 and 982. This batch closes what those entries left open.

- **Pipelined HTTP/1.1 requests (#7859).** `Std.HttpEngine.feed` now stops after
  the first `RequestComplete` and leaves the next request's bytes buffered. The
  `Std.HttpServer` readers (dotnet and native) already feed an empty slice first
  to drain buffered input, so the second request is parsed on their next call
  instead of being discarded with the rest of the batch. Callers that want every
  event of a pipelined buffer feed an empty slice until `hasBufferedInput`
  is false. The engine tests and a dotnet server test cover it.
- **HPACK (#7231).** The encoder sends `authorization`, `proxy-authorization`,
  `cookie` and `set-cookie` as never-indexed literals (RFC 7541 section 7.1.3)
  and keeps them out of its dynamic table. `decoderSetMaxProtocolSize` shrinks
  the table and requires the peer's next block to open with a size update
  (`MissingSizeUpdate`). The decoded-size budget and request-header validation
  were already in place. The Huffman tables are still built per call by the
  standalone helpers; the encoder and decoder build them once per connection.
- **`Mcp.Client` errors (#7522).** See D-progress-1053.
- **Authentication aspects (#7249).** `enabled` is gone from `RequiresAuth`,
  `RequiresRole`, `ApiKey`, `WsAuth` and `ValidateKey`. See D-progress-1053.
- **lyric-grpc (#7247).** The rate-limiter cache is keyed on
  `(method, requestsPerMinute, burstSize)`, so a changed configuration no
  longer inherits the first instance's limits. `start` and `startHandle` panic
  before binding when `GrpcServer.port` is outside 1..65535 or
  `maxConnectionIdleMs` is not positive (`serverConfigProblem`).
- **lyric-db (#7241).** `DbTransaction` gains `isActive()`. A finished
  transaction answers `query`, `execute` and `commit` with `TX_FINISHED`;
  `rollback` stays idempotent.
- **lyric-otel (#7235).** `endSpan` on an ended span no longer exports it
  twice, `startSpan` requires a kind in 0..4, `incrementCounter` ignores a
  negative delta, `recordHistogram` ignores NaN and infinite values, and
  `flushOtlpAsync` requires a positive timeout.

## Still open

- #7249: symlink resolution for dotnet static files needs a stdlib symlink
  primitive on all three kernel trees.
- #7241: typed SQL text (`SqlText`) is a design item; JVM kernel reachability is
  #5324.
- #7236: request timeouts are blocked on #6367.
- #7253: the local kernel's `initFromAnnotations` is blocked on #6866.
- #7180, #7181: the `Std.AnnotationMeta` runtime reader is a new stdlib module
  with its own extern surface on both targets.
- #7541, #7462, #7668, #7907: each is a feature-sized change of its own.
