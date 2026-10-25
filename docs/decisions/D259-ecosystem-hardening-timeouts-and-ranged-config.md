# D259 - Ecosystem hardening: request deadlines through `sendWithCancel`, ranged aspect config, effective OTLP timeout

**Status:** shipped (#7235, #7236, #7239, #7241).

## Context

The first rounds of #7235, #7236, #7239 and #7241 (PRs #7290, #7307, #8519) fixed the headline defects. What stayed
open was the part that needed a language feature or a design choice: `lyric-search` ignored its timeouts, the
`lyric-mq` aspect config was plain `Int` checked by a per-call `panic`, and `lyric-otel` still had dead or unchecked
settings.

## Decision

1. **Search timeouts use `HttpClient.sendWithCancel`.** `HttpConfig` carries a positive `requestTimeoutMs`
   (invariant); `sendCatching` sends under a `makeCancelSourceTimeout` token and reports an elapsed deadline as
   `ConnectionFailed("request timed out after N ms")`. The `sendWithTimeoutAsync` family is not used: its doc comment
   still marks it `@experimental` and the interface method works cross-package. Connect probes run under
   `connectTimeoutMs`, later requests under `requestTimeoutMs`. A non-positive timeout is `Err(INVALID_TIMEOUT)`, not
   a panic. `connectMeilisearchWithTimeouts` is added instead of changing `connectMeilisearch`'s `@stable` signature,
   and the environment path no longer passes the request timeout as the connect timeout.
2. **Aspect config is range-typed (#7229).** `Idempotent.ttlSeconds` is `Int range 0 ..= 31536000` and
   `DeadLetter.maxDeliveries` is `Int range 1 ..= 1000000`, so a bad value is a startup failure (`G0004`, exit 78) or a
   compile error for a `from` override (`G0010`) rather than a per-call panic. The in-body panics are gone;
   `IdempotencyLedger.finish` keeps its `requires`. `OTel.Tracing.sampleRate` is `Float range 0.0 ..= 1.0`.
3. **OTLP timeouts compose.** `OtlpExporterConfig.timeoutMs` and the `timeoutMs` argument of `flushOtlpAsync` both
   apply; the request runs under the smaller. `configureOtlp*` return `Err` for a non-positive `timeoutMs` or a header
   with an empty name, and the transport fails an export when the HTTP stack rejects a header instead of sending
   without it.
4. **Spans are checked at construction.** `newSpanRecord` requires 16-byte and 8-byte non-zero ids and a kind in
   `0..=4`; `startSpan` redraws an all-zero id. The `Span` type states the kind and both id lengths as separate
   invariants (one invariant joining the two slice lengths with `and` makes the MSIL emitter fail with
   `BadImageFormatException`; filed separately). `spanFinish` raises an end time before the start to the start.
   Attributes are capped at 128 per span and 4096 characters per key or value, and an empty key is dropped.
5. **`Tracing.sampleRate` and `RequestLogging.level` are honoured.** Sampling draws a fresh 24-bit value per call from
   `Std.SecureRandom`. Unknown level strings log at info, which the README states.

## Not done

A deterministic hung-backend test needs an in-process server that accepts and stays silent, which the MSIL target
cannot host (docs: `spawn` is synchronous there). The timeout path is covered by the pure validation tests and the
unreachable-backend test; the deadline itself relies on `sendWithCancel`'s own tests. #7241 stays open for item 7 (JVM
kernel reachability, #5324).
