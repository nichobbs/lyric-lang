# D-progress-960 — Ecosystem security fixes; NaN-correct MSIL comparisons

**Status:** shipped

The ecosystem half of the #7221 security band, plus a compiler fix it
surfaced.

## Compiler: NaN comparisons on MSIL (#7240)

The MSIL backend lowered `a <= b` as `!(a > b)` via `cgt` and `a >= b` as
`!(a < b)` via `clt`. Both are true when an operand is NaN, while IEEE 754
§5.11 and language reference §2.2 require every ordered comparison with NaN
to be false. Range patterns (`case 0.0 ..= 1.0`) and `Double range` subtypes
admitted NaN the same way. On doubles the lowering now uses the "unordered"
compares, `cgt.un` and `clt.un`, before the negation, and range bounds use
them too; the half-open upper bound already rejected NaN. The JVM was
already correct (#2772). `nan_compare_self_test.l` (moved from
`lyric-compiler/jvm/`, now with range-pattern and range-subtype cases) runs
on both targets.

## Ecosystem

- **lyric-web, JVM (#7233).**
  - The Undertow kernel read request bodies with `readAllBytes`. It now
    enforces the dotnet engine's `EngineLimits.defaults().maxBodyBytes`
    (10 MiB).
  - An oversized `Content-Length` is refused before anything is read. Any
    other body is read at most `limit + 1` bytes. Either way the client gets
    a bodyless `413` and the connection is closed.
- **lyric-search (#7236).**
  - `buildRequest` refuses a request path with an empty, `.` or `..` segment
    (`INVALID_PATH_SEGMENT`). URL normalisation turned
    `delete(index, "..")` into a request against the whole index, and an
    empty id into Meilisearch's delete-all.
  - Unknown filter operators (`UNKNOWN_OPERATOR`) and pagination beyond a
    10000-result window (`INVALID_PAGINATION`) are rejected before sending.
  - `joinUrl` no longer panics on a base URL that ends in `/`.
- **lyric-mq (#7239).**
  - `ack`/`nack` answer an empty broker id with `Err`, where the DeadLetter
    aspect used to trip a precondition and crash the consumer.
  - Message JSON escapes every control character, and `messageFromJson`
    returns `Result`.
  - `deliveryCount` is 0 on first delivery, `Idempotent` rejects a negative
    TTL before running the handler, and `publishBatch` checks every id
    before publishing any.
- **lyric-resilience and lyric-jobs (#7240).**
  - A half-open probe that panics no longer wedges the circuit open: after a
    further cooldown without an outcome, a fresh probe is granted. This
    holds in both kernels and in `CircuitBreakerState`.
  - `backoffDelay` has preconditions (`isValidBackoff`) and an
    `ensures: result in [0, maxDelayMs]`.
  - `Retry`, `CircuitBreaker` and lyric-jobs' `Retryable` validate their
    config before the wrapped call runs. lyric-jobs' overflowing duplicate
    backoff is gone.
- **lyric-storage and lyric-testing (#7242).**
  - `ValidateKey` applies `Storage.isSafeKey` in full. It used to check only
    empty keys, a leading `/` and `..`, and had an env-settable `allowDots`
    switch that turned the traversal check off.
  - `isSafeKey` also rejects control characters and `.` or empty path
    segments.
  - `AuditAccess` logs through `Std.Log`; it used to be a no-op.
  - `MockStorageBucket` validates keys like a real backend and pages `list`.
- **lyric-db (#7241).**
  - SQLite uses `SqliteConnectionStringBuilder`, which escapes the data
    source, and rounds a sub-second busy timeout up (0 meant "no timeout").
  - Postgres URIs with a bad port return `Err` instead of defaulting to
    5432, and builder errors no longer escape `connectPostgres`.
  - `getInt`/`getIntOpt` no longer wrap an out-of-`Int32` value.

## Not in this slice

These stay open on their issues:
- search request timeouts, which are blocked on #6367;
- lyric-db typed SQL text and transaction-state tracking (design items);
- lyric-db JVM kernel parity (#5324);
- the lyric-web JVM configurable body limit, since the cap currently
  matches dotnet's fixed default.
