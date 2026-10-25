# Ecosystem library hardening, round 2 (D259, #7235, #7236, #7239, #7241)

Checked each issue against `main` first. Already fixed and verified: the `SpanBuffer` aliasing, double `endSpan`,
negative counter deltas, NaN/Inf histograms, `startSpan` kind (#7235); dot-segment ids, unknown filter operators,
pagination bounds (#7236); empty-id DeadLetter, JSON control characters, `deliveryCount`, `connectTo`, dead-letter
capacity (#7239); SQLite timeout and connection string, Postgres port, `isActive`, `getInt` range, `SqlText` and the
vacuous `SlowQueryAlert` clause (#7241).

Shipped here:

- `lyric-search`: `requestTimeoutMs` on `HttpConfig`, requests sent under a cancellation deadline, `INVALID_TIMEOUT`
  for non-positive values, `connectMeilisearchWithTimeouts`.
- `lyric-mq`: `Idempotent.ttlSeconds` and `DeadLetter.maxDeliveries` are range-typed; the per-call panics are removed.
- `lyric-otel`: span id/kind preconditions and invariants, end-before-start clamp, attribute bounds, `sampleRate` and
  `level` honoured, `OtlpExporterConfig` validation, `timeoutMs` wired as a ceiling, rejected headers fail the export.

Tests: `lyric-otel` (span, config and kernel header cases), `lyric-search` (timeout validation, deadline path against
an unreachable backend), `lyric-mq` (range lower bound). `lyric-mq` and `lyric-search` run on both targets;
`lyric-otel`'s OTLP export is dotnet-only by design. #7235, #7236 and #7239 are closed by this change; #7241 stays
open for JVM kernel reachability (#5324).
