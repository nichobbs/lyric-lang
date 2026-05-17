# Lyric Ecosystem Libraries — Code Review

Scope: 24 `lyric-*` packages under the repo root, excluding `lyric-vscode`
(TypeScript). Reviewed for correctness, API consistency, cross-platform
parity, completeness, and quality. Security findings are deliberately
out of scope per the request (covered by a separate pass).

Severity tags:

- **CRITICAL** — wrong behaviour, broken build, or unusable feature
- **HIGH** — significant defect or large gap; not safe for production
- **MEDIUM** — inconsistency, missing safeguard, or unfinished feature
- **LOW** — polish, doc, or minor tightening

---

## Library completeness matrix

| Library              | Kernels    | Tests | README | JVM parity claim   | Notes                                                                 |
|----------------------|------------|:-----:|:------:|:-------------------|-----------------------------------------------------------------------|
| lyric-auth           | net + jvm  |   -   |   -    | declared           | Both kernels present; no JWT lib pinned in toml                       |
| lyric-aws-secrets    | flat       |   -   |   -    | implicit .NET-only | No `net`/`jvm` split; uses `flat-kernel`                              |
| lyric-aws-xray       | flat       |   -   |   -    | implicit .NET-only | Same shape as aws-secrets                                             |
| lyric-cache          | none       |   -   |   y    | n/a (pure Lyric)   | No Redis kernel; only in-process; not thread-safe                     |
| lyric-db             | net        |   -   |   y    | gap                | `_kernel/net` only; no jvm even though `Lyric.Db` is generic          |
| lyric-feature-flags  | net        |   -   |   y    | gap                | Same                                                                  |
| lyric-grpc           | net + jvm  |   -   |   -    | declared           | jvm kernel file present; no Maven test                                |
| lyric-health         | none       |   -   |   y    | n/a                | Pure-Lyric wrapper over `lyric-web` types                             |
| lyric-i18n           | net        |   -   |   y    | gap                | `_kernel/net` only                                                    |
| lyric-jobs           | net        |   -   |   y    | gap                | Hangfire / Quartz both .NET; no JVM Quartz/JobRunr planned            |
| lyric-lambda         | flat       |   -   |   -    | n/a                | AWS Lambda runtime is .NET-only in practice                           |
| lyric-logging        | none       |   -   |   y    | n/a                | Pure-Lyric over `Std.Log`                                             |
| lyric-mail           | net        |   -   |   y    | gap                | MailKit/SES/SendGrid .NET only                                        |
| lyric-mq             | net + jvm  |   -   |   y    | declared           | Manifest missing `dotnet`/`jvm` feature flags (see HIGH below)        |
| lyric-otel           | net + jvm  |   -   |   y    | declared           | Manifest declares `dotnet`/`jvm`; OTLP kernel feature-gated           |
| lyric-proto          | net + jvm  |   -   |   -    | declared           | Pure-Lyric encoder; minimal kernel surface                            |
| lyric-resilience     | net + jvm  |   -   |   -    | declared           | Circuit state lives entirely in the kernel; no real Lyric state model |
| lyric-search         | net        |   -   |   y    | gap                | Elasticsearch/Meilisearch both have JVM clients                       |
| lyric-session        | net        |   -   |   y    | gap                | Redis has a JVM client (Lettuce/Jedis); no plan filed                 |
| lyric-storage        | net        |   -   |   y    | gap                | AWS/Azure SDKs all have JVM siblings                                  |
| lyric-testing        | none       |   -   |   y    | n/a                | Mocks only                                                            |
| lyric-validation     | none       |   -   |   y    | n/a                | Pure-Lyric                                                            |
| lyric-web            | net        |   -   |   y    | declared           | jvm feature declared but no `_kernel/jvm` directory exists            |
| lyric-ws             | net        |   -   |   y    | declared           | Same shape as web                                                     |

**Tests column**: zero test files under any `lyric-*` package
(`find lyric-* -name '*_tests.l' -o -name '*_test.l'` returns nothing;
no `tests/` directory exists in any of them). See finding **F-3**.

---

## F-1 [CRITICAL] `lyric-mq` manifest does not declare the `dotnet`/`jvm` features that the source `@cfg`s on

`lyric-mq/lyric.toml:19-23` declares only four features:

```toml
[features]
rabbitmq        = []
azureservicebus = []
sqs             = []
kafka           = []
```

…but `lyric-mq/src/mq.l:46` imports `Mq.Kernel.Jvm` under
`@cfg(feature = "jvm")`, and the platform-dispatch helpers
(`mq.l:350-418`) are split across `@cfg(feature = "dotnet")` and
`@cfg(feature = "jvm")` blocks. Since neither `dotnet` nor `jvm` is
declared in `[features]`, all eight `@cfg(feature = "dotnet")` and ten
`@cfg(feature = "jvm")` annotations in this package gate on a feature
that can never be enabled — every dispatch helper is effectively
unreachable, and the public functions (`Mq.connect`, `Mq.publish`,
`Mq.consume`, etc.) will fail to resolve at compile time on any
target.

Cross-checked: every other multi-platform library (`lyric-grpc`,
`lyric-otel`, `lyric-proto`, `lyric-resilience`, `lyric-web`,
`lyric-ws`) does declare both `dotnet = []` and `jvm = []` in
`[features]`. `lyric-mq` is the only outlier and is almost
certainly unbuildable.

**Fix**: add `dotnet = []` and `jvm = []` to `lyric-mq/lyric.toml`
`[features]` and update the README/feature matrix.

## F-2 [CRITICAL] Cross-platform parity gaps not surfaced anywhere

Per CLAUDE.md, libraries flagged with a `jvm` feature are expected to
ship a JVM kernel. The following declare `jvm` parity in
documentation but have **no** `src/_kernel/jvm/` directory:

- `lyric-web` — `lyric.toml:13` declares `jvm = []`; only
  `src/_kernel/net/web_kernel.l` exists. README §JVM in this lib does
  not exist.
- `lyric-ws` — same shape.

And the following libraries have *no* JVM story at all, despite
their .NET kernels using libraries that have first-party JVM
siblings (Elasticsearch Java client, Redis Lettuce, AWS SDK for
Java v2, Azure SDK for Java, Hangfire's Quartz-style alternatives,
MailKit→Jakarta Mail, etc.):

- `lyric-db`, `lyric-mail`, `lyric-search`, `lyric-session`,
  `lyric-storage`, `lyric-feature-flags`, `lyric-i18n`,
  `lyric-jobs`.

This is a coverage gap, not a build break, but the JVM story for
the ecosystem is materially worse than the README portrays.

**Fix**: either add `_kernel/jvm/` stubs that return
`Err("not implemented on JVM yet")`, or add a clear "Platform
parity" section in each `lyric.toml`/README explicitly listing
.NET-only status. Match `docs/33-platform-parity-remediation.md`
phrasing.

## F-3 [HIGH] Zero test coverage across the entire ecosystem

`find . -path '*/lyric-*/tests/*' -name '*.l'` returns nothing.
`find . -path '*/lyric-*' -name '*_tests.l'` returns nothing.

Of the 24 reviewed packages, **none** ship a `tests/` directory or a
`*_tests.l` file. By contrast, `stdlib/tests/` exists and is wired
into the F# emitter test suite (per `compiler/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs`).

This means there is no automated check that:

- `lyric-proto` correctly round-trips a varint (a well-defined
  algorithm with concrete test vectors widely available).
- `lyric-cache`'s `evictOldest` actually picks the oldest entry
  (the algorithm has at least one subtle bug, see F-5).
- `lyric-resilience`'s `Retry` aspect actually retries the
  documented number of times (the loop is non-trivial; see F-9).
- `lyric-mq`'s JSON parsing round-trips messages with embedded
  quotes (the inline parser has known limitations, see F-12).
- Any of the Mock implementations in `lyric-testing` produce the
  outputs the public API claims.

**Fix**: add at minimum a `lyric-proto/tests/proto_tests.l` with
RFC test vectors, `lyric-cache/tests/cache_tests.l` for the
eviction and TTL logic, `lyric-resilience/tests/resilience_tests.l`
for the retry loop, and `lyric-validation/tests/validation_tests.l`.
The stdlib's `StdlibLyricTests.fs` pattern can be replicated to
include `lyric-*` test files in the same harness.

## F-4 [HIGH] `lyric-proto` `unzigzag32` arithmetic right-shift may not match protobuf semantics

`lyric-proto/src/types.l:75-91`:

```lyric
pub func zigzag32(n: Int): Long {
  ((n << 1) ^ (n >> 31)).toLong()
}
pub func unzigzag32(n: Long): Int {
  ((n >> 1) ^ -(n & 1L)).toInt()
}
```

Protobuf zigzag requires an **arithmetic** right shift in the
encoder (so the sign bit propagates) and a **logical** right shift
in the decoder (so the high bit of the unsigned varint is treated
as data). Whether Lyric's `>>` is arithmetic for `Int` and `Long`
is not documented at the call sites here, nor in the function
docstrings. If `>>` is logical for `Int` (encoder line 76), the
encoder produces wrong output for negative inputs. If `>>` is
arithmetic for `Long` (decoder line 86), the decoder mishandles
large positive zigzag values whose high bit is set after the shift.

Compounding this: there are no tests verifying any of the
RFC-defined zigzag test vectors (`-1 → 1`, `1 → 2`, `-2 → 3`,
`2 → 4`, `INT_MIN → UINT_MAX`).

**Fix**: document the shift semantics in `Std.Core` and in these
functions; add test vectors covering `-1`, `1`, `INT_MIN`,
`INT_MAX`, `LONG_MIN`, `LONG_MAX`.

## F-5 [HIGH] `lyric-cache` `evictOldest` does not actually evict the oldest entry

`lyric-cache/src/cache.l:186-199`:

```lyric
func evictOldest(entries: inout Map[String, CacheEntry]): Unit {
  var minKey     = ""
  var minExpires = Long.maxValue
  for (k, e) in entries {
    val eff = if e.expiresAt == 0 then Long.maxValue else e.expiresAt
    if minKey == "" or eff < minExpires {
      minKey     = k
      minExpires = eff
    }
  }
  ...
}
```

Two problems:

1. `Long.maxValue` sentinel + treat-`expiresAt = 0`-as-`max` means
   **no-expiry entries are never evicted**, even when *every* entry
   in the map has no expiry — the loop just walks all of them and
   leaves `minKey = ""`. The `if minKey.length > 0` guard at line
   196 then silently no-ops, so `set` accepts the new entry, the
   map grows past `maxEntries`, and the configured cap is violated.
2. The "oldest" entry is defined by **smallest expiry timestamp**,
   not insertion time. With a wide range of TTLs (e.g., one entry
   with `ttl=86400`, one with `ttl=10`), the entry with the smaller
   TTL gets evicted first regardless of how recently it was inserted
   — that is approximately the *opposite* of LRU. The docstring on
   `InProcessCacheStore` (`cache.l:66`) implies a more conventional
   eviction policy.

**Fix**: track an insertion-order counter (or a monotonic timestamp
captured at `set`) on `CacheEntry` and evict by that; fall back to
"any entry" rather than no-op when every entry is no-expiry.

## F-6 [HIGH] `lyric-cache` `get` cannot observe TTL expiry without a write

`lyric-cache/src/cache.l:76-88`:

```lyric
func get(key: in String): Option[String] {
  val nowMs = Std.Time.SystemClock.now().toEpochMillis()
  match entries.get(key) {
    case Some(entry) ->
      if entry.expiresAt == 0 or entry.expiresAt > nowMs {
        Some(entry.value)
      } else {
        // Do not mutate here; expired entry cleaned up on next set() call.
        None
      }
    ...
  }
}
```

The comment explicitly defers cleanup to `set()`. Two consequences:

1. A read-mostly workload that never writes will accumulate
   indefinite expired entries until `maxEntries` is hit and the
   buggy `evictOldest` (F-5) runs.
2. `delete` (`cache.l:99`) and `clear` (`cache.l:103`) also do not
   sweep expired entries, so the only path to reclaiming memory is
   a `set` that crosses the cap.

Comment on `get` claims expired entries are cleaned up on next `set()`
call, but `set` only evicts when the map is full — it never
proactively walks the map for expired entries.

**Fix**: either sweep expired entries on `get` (mutate via `inout`),
or periodically (e.g., when `entries.count % 100 == 0` inside `set`).

## F-7 [HIGH] `Resilience.Retry` and `Jobs.Aspects.Retryable` have no jitter; backoff multiplier can overflow `Int`

`lyric-resilience/src/resilience.l:111-119`:

```lyric
func backoffDelay(initialDelayMs: in Int, backoffFactor: in Int, attempt: in Int): Int {
  var delay: Int = initialDelayMs
  var i:     Int = 0
  while i < attempt {
    delay = delay * backoffFactor
    i     = i + 1
  }
  return delay
}
```

Problems:

1. **No jitter.** Industry standard for exponential backoff is "full
   jitter" or at minimum "decorrelated jitter" (AWS Architecture
   Blog 2015). Without jitter, all clients retrying against a failing
   downstream synchronise their retries and create thundering herds.
2. **No upper bound.** With `initialDelayMs = 100`, `backoffFactor = 2`,
   and `attempt = 25`, `delay = 100 * 2^25 ≈ 3.35e9` ms — well over
   `Int.maxValue ≈ 2.15e9` on .NET. The multiplication silently
   overflows to a negative number, which is then passed to
   `Resilience.sleepMs(ms)` whose `requires: ms >= 0` will fire a
   contract violation. With `@runtime_checked` enabled this becomes
   a runtime panic; with checks elided it becomes a thread-sleep
   with an undefined argument.
3. The compatible aspect in `lyric-jobs/src/jobs_aspects.l:131-141`
   does add a `maxDelayMs` clamp — so the two libraries that ship
   the **same conceptual aspect** have **different** safety
   properties. `Resilience.Retry` is the one consumers will use; it
   should be at least as safe as the duplicate in `lyric-jobs`.

**Fix**: port the `maxDelayMs` clamp from `Jobs.Aspects.Retryable`
into `Resilience.Retry` (the cleaner long-term answer is to delete
the duplicate in jobs and have `Jobs.Aspects.Retryable` reuse
`Resilience.Retry`). Add a `jitterFraction: Float = 0.1` config to
both, with the standard "delay × (1 + rand(-jitter, +jitter))"
formula.

## F-8 [HIGH] `Resilience.CircuitBreaker` half-open semantics live entirely in the .NET extern; no Lyric model exists

`lyric-resilience/src/_kernel/net/resilience_kernel.l:32-46` declares
the half-open semantics in an `@axiom`'d extern:

```lyric
@axiom("In-process circuit breaker state (ConcurrentDictionary per circuit name)")
extern package Lyric.Resilience.CircuitStore {
  pub func circuitIsOpen(name: String, cooldownMs: Int): Bool
  pub func circuitRecordSuccess(name: String): Unit
  pub func circuitRecordFailure(name: String, failureThreshold: Int): Unit
}
```

The Lyric side (`resilience.l:184-208`) just calls these three
opaque externs. The half-open probe state, the "one in-flight
probe" rule, the timestamps, and the cooldown→half-open transition
are all implemented in unspecified .NET host code that is **not in
this repository** (no `Lyric.Resilience.CircuitStore` symbol exists
in `compiler/` or `stdlib/`).

This means:

1. The semantic contract that the docstring at `resilience.l:175`
   makes ("one probe call through; successful probe closes the
   circuit") is unverified — the verifier cannot reason about it,
   tests cannot exercise it (F-3), and the JVM kernel
   (`lyric-resilience/src/_kernel/jvm/`) will have to re-implement
   the same logic from scratch, with no shared spec.
2. The header comment on `resilience.l:22-41` shows a sketch of
   the *protected type* that *should* hold this state but does not
   — instead the actual implementation is delegated to an
   un-audited extern.

**Fix**: implement the state machine in Lyric as the documented
`protected type CircuitBreakerState`. The kernel boundary should
expose a single primitive (e.g. `cas` on a `ConcurrentDictionary`
slot) and let Lyric own the logic. The verifier can then prove the
state-machine invariant (consecutiveFailures ≥ 0; isOpen ⇒
openedAtMs > 0; etc.).

## F-9 [MEDIUM] `Retry` aspect loses the last error message on overflow exit

`lyric-resilience/src/resilience.l:145-163`:

```lyric
around(call) -> ret {
  ...
  ret = call.proceed()
  var attempt: Int = 1
  while attempt < maxAttempts {
    match ret {
      case Ok(_)  -> attempt = maxAttempts    // exit: success
      case Err(_) -> {
        val delay = backoffDelay(...)
        Resilience.sleepMs(delay)
        ret     = call.proceed()
        attempt = attempt + 1
      }
    }
  }
}
```

The match drops the `Err` payload entirely (`case Err(_)`), so the
final `Err` returned after all attempts is whatever
`call.proceed()` happened to set last — fine semantically, but
the aspect provides no telemetry of how many attempts were spent
or what the intermediate errors were. The companion aspect in
`lyric-jobs/src/jobs_aspects.l:75-87` has the same issue.

For an aspect named "Retryable", emitting a structured log line
like `"retry: attempt N of M failed: <err>"` on every retry would
be expected. Compare to the OTLP retry behaviour documented in
`lyric-otel/src/otlp.l:78` which says "The SDK retries within this
window" — visibility of those retries is a basic operational need.

**Fix**: invoke `Std.Log.warn` (or take a `logRetries: Bool` config)
on each retry attempt, including attempt index and error text.

## F-10 [MEDIUM] Error-type discipline is inconsistent across the ecosystem

Each library defines its own error type but the conventions diverge:

| Library              | Error type                | Has `code` field | Has `statusCode` |
|----------------------|---------------------------|:----------------:|:----------------:|
| lyric-web            | `ApiError`                |    no (status)   |       yes        |
| lyric-storage        | `StorageError`            |        yes       |        no        |
| lyric-search         | `SearchError`             |        yes       |       yes        |
| lyric-session        | `SessionError`            |     (not shown)  |        no        |
| lyric-mail           | `MailError`               |     (not shown)  |        no        |
| lyric-jobs           | `JobError`                |        yes       |        no        |
| lyric-validation     | `ValidationError` (per-item) | yes (`code`)  |        no        |
| lyric-feature-flags  | `FlagError`               |        yes       |        no        |
| lyric-ws             | `WsError`                 |     `connectionId` |      no        |
| lyric-grpc           | `GrpcStatus`              | (code: GrpcStatusCode) |    no    |
| lyric-mq             | (raw `String`)            |        n/a       |        n/a       |
| lyric-resilience     | (raw `String`)            |        n/a       |        n/a       |
| lyric-otel           | (raw `String`)            |        n/a       |        n/a       |
| lyric-proto          | (raw `String`)            |        n/a       |        n/a       |
| lyric-cache          | (Option, not Result)      |        n/a       |        n/a       |

Three issues:

1. Some libraries return `Result[T, String]` (`mq`, `resilience`,
   `otel`, `proto`); most return `Result[T, FooError]`. Consumers
   composing across libraries cannot use `?`-propagation cleanly
   because the error types don't unify. `lyric-validation` is
   especially inconsistent — its public type is
   `Result[T, [ValidationError]]` (list-of-errors), which composes
   badly with everything else.
2. The shape of `FooError` itself is not standard: some have
   `code: String`, some have `statusCode: Int`, some have
   `connectionId: String`. There is no shared `LyricError` trait
   or interface.
3. `Mq.QueueConsumer.consume` (`lyric-mq/src/mq.l:118-127`) signals
   timeout via `Err("timeout")` — a magic string sentinel. The
   correct shape is `Result[Option[Message], MqError]` where `Ok(None)`
   means timeout. Magic-string error sentinels lose round-trip
   safety the moment any caller misspells the sentinel.

**Fix**: define `pub interface LyricError { func message(): String;
func code(): String }` in `Std.Core` (or in a new `Std.Error`
module), and have each `FooError` implement it. Migrate the
string-returning libraries to typed errors. Replace
`Err("timeout")` with a typed `Mq.QueueTimeout` variant or with
`Result[Option[Message], MqError]`.

## F-11 [MEDIUM] `lyric-grpc` public signatures use `[Byte]` while docstrings advertise `slice[Byte]`

`lyric-grpc/src/grpc.l:5` (header docstring) says payloads are
`slice[Byte]`, but every actual function signature uses
`payload: in [Byte]` (lines 113, 125, 141, 153, 163, 169). The
`grpc.l` package-header comment on line 13 also says "raw
protobuf-encoded bytes (slice[Byte])". And `lyric-proto`
(`encoding.l:102`) does return `slice[Byte]` from `encodeMessage`.

So a consumer doing:

```lyric
val payload: slice[Byte] = Proto.encodeMessage([...])
Grpc.callUnary(channel, "svc", "Method", payload, opts)
```

…will get a type error: `[Byte]` vs `slice[Byte]`. The two are
distinct in `Std.Core`. Either the documented type is wrong, the
signature is wrong, or the consumer has to round-trip through a
conversion that should not exist.

**Fix**: pick one (`slice[Byte]` is more idiomatic per
`lyric-proto`'s API) and make all signatures and docs match.

## F-12 [MEDIUM] `lyric-mq` uses a hand-rolled JSON extractor that mishandles escapes

`lyric-mq/src/mq.l:498-528` defines `jsonExtractString` and
`jsonExtractInt`. The function comment (line 493-497) is candid:

> Limitation: stops at the first unescaped quote after the opening
> quote; values containing `\"` (escaped quotes) will be truncated
> at the first `\"`.

The decode path *does* round-trip body content through this on
`messageFromJson` (line 457), so a producer that publishes
`Message { body = "she said \"hi\"" }` will receive a corrupted
body on the consumer side: `body = "she said "`.

This is on the hot consume path of an MQ library and is enabled
silently. By contrast, `parseHeadersJson` (line 467-490) correctly
uses `Std.Json` — which means the library already has the right
parser available; only the message body / id path is hand-rolled.

**Fix**: replace `jsonExtractString`/`jsonExtractInt` with
`Std.Json.parseJson` + typed extraction. Delete `jsonEscape`
duplicates and reuse the stdlib JSON serializer.

## F-13 [MEDIUM] `lyric-otel` OTLP exporter exposes neither sampling, batching, nor backpressure config

`lyric-otel/src/otlp.l:66-84` defines `OtlpExporterConfig` with
exactly four fields: `endpoint`, `protocol`, `timeoutMs`, `headers`.
The OTel .NET SDK exposes additional knobs that real production
deployments need:

- `BatchExportProcessorOptions`: `MaxQueueSize`, `MaxExportBatchSize`,
  `ScheduledDelayMilliseconds`, `ExporterTimeoutMilliseconds`
- `ParentBasedSampler` and `TraceIdRatioBasedSampler` for sampling
- `MeterProvider` reader interval (the docstring mentions
  `OTEL_METRIC_EXPORT_INTERVAL` as the *only* way to override)

The Tracing aspect (`otel.l:119-143`) takes a `sampleRate: Float`
config field but **never reads it**: the body just calls
`startSpan(...)` unconditionally if `enabled`. The `sampleRate`
config does nothing. (See `otel.l:125-142`.)

This is doubly bad: the Lyric-side sampleRate is a no-op, and
there's no way to push sampling configuration down to the SDK
either.

**Fix**: either remove `sampleRate` (and document that sampling is
set via OTel SDK environment variables) or implement it (consult
`Std.Random` once that ships; until then, hash `call.qualifiedName`
+ trace ID and gate). Also expose `maxQueueSize`,
`maxExportBatchSize`, and `scheduledDelayMs` on `OtlpExporterConfig`.

## F-14 [MEDIUM] `lyric-mq` feature-gating ships *all four* broker NuGets unconditionally

`lyric-mq/lyric.toml:38-46`:

```toml
# NOTE: The [nuget] table does not yet support per-feature gating
# (see docs/21-nuget-linking.md).
# All four broker packages are restored unconditionally; only the
# active feature's code compiles.
[nuget]
"RabbitMQ.Client"            = "6.8.1"
"Azure.Messaging.ServiceBus" = "7.18.0"
"AWSSDK.SQS"                 = "3.7.300"
"Confluent.Kafka"            = "2.4.0"
```

The same shape is in `lyric-storage`, `lyric-jobs`, `lyric-mail`,
`lyric-search`, `lyric-session`. A consumer that only needs SQS
ends up with ~150 MB of unused NuGet dependencies and their
transitive deps (Azure SDK pulls Azure.Core, Microsoft.Identity,
Newtonsoft.Json; RabbitMQ pulls System.Memory.Data; etc.).

The note correctly points to `docs/21-nuget-linking.md` as the
spec gap, but the impact is concrete: any service that adopts
even one of these libs picks up megabytes of unused code and
unused CVEs. The "lambda-friendly" claim in `lyric-lambda` is
particularly undermined here since Lambda cold-start is
size-sensitive.

**Fix**: prioritise the per-feature `[nuget]` gating work in
`docs/21-nuget-linking.md`. Until then, split each broker into
its own sub-package (`Lyric.Mq.Rabbitmq`, `Lyric.Mq.Sqs`, etc.)
so consumers can pick one.

## F-15 [MEDIUM] `lyric-testing` mocks simulate only the happy path

`lyric-testing/src/testing.l`:

- `MockMailSender.send` (lines 96-111) — always returns `Ok(())`.
- `MockStorageBucket.put`/`delete` (lines 153-201) — always
  succeed.
- `MockMessageQueue.publish` (lines 258-281) — always succeeds.
- `MockSessionStore.create`/`save` (lines 311-338) — always
  succeed.
- `MockFlagStore.refresh` (line 469-471) — always returns `Ok(())`.

There is no way to configure a mock to inject a failure (timeout,
quota exceeded, network down, partial batch, idempotency conflict)
without subclassing. Real test suites need to verify error-handling
paths — those paths are precisely what production breaks on.

`lyric-jobs/src/jobs.l:226` says of `InProcessJobScheduler`:
> Not thread-safe; use in single-threaded test scenarios only.

That's the only failure-mode mention in the entire testing
surface, and it's about concurrency not error injection.

**Fix**: each Mock should expose hooks like
`MockMailSender.failNextN(n: Int, error: MailError)` or
`MockStorageBucket.failOn("put", "users/*", error)`.

## F-16 [MEDIUM] `Validation.email` accepts addresses that fail every other email validator

`lyric-validation/src/validation.l:177-205` requires exactly one
`@` and at least one `.` after `@`. This accepts:

- `"a@b.c"` — single character local-part, single-char host, single-char TLD
- `"@.a"`   — empty local-part (returns ok: 1 `@`, 1 `.` after)
- `" @x.y "` — leading/trailing whitespace
- `"@x.y"`  — empty local-part
- `"x@.y"`  — host starts with `.`
- `"x@y."`  — TLD is empty
- `"x@y..z"` — consecutive dots

The first three are particularly suspect. The docstring at line
171-175 acknowledges this is "not a full RFC 5322 validator", but
the bar should still rule out empty-local-part and whitespace —
those are the easy 80%.

Compare with `Validation.matches` (line 139-149): marked
`@experimental` and explicitly says "full regular-expression
matching is deferred". The `email` validator should probably also
be `@experimental` or `@deprecated since="0.1"` with a recommendation
to use `matches` once it ships.

**Fix**: tighten to require: local-part length ≥ 1, host length ≥ 3,
no leading/trailing whitespace, TLD length ≥ 2. Document the
limitation explicitly: "rejects whitespace and empty local-part
but does not enforce RFC 5322; use server-side confirmation".

## F-17 [MEDIUM] `lyric-cache` is thread-unsafe, mark consistent across the ecosystem

`lyric-cache/src/cache.l:67`, `lyric-feature-flags/src/flags.l:95`,
`lyric-jobs/src/jobs.l:226`, `lyric-session/src/session.l:266`,
`lyric-testing/src/testing.l:89` all carry "Not thread-safe in v1"
disclaimers. Combined, this means an application that uses
`Cache + Flags + Session` plus a `MockMailSender` in a server
context has at least five thread-unsafe components that the user
must coordinate themselves.

`lyric-resilience` carries the same comment shape but defers the
actual thread-safety to the .NET kernel
(`Lyric.Resilience.CircuitStore` uses `ConcurrentDictionary`).
This is the right shape — the inconsistency is that the other
five libraries do not follow it.

**Fix**: either route every in-process store through a kernel-side
`ConcurrentDictionary` (matching resilience), or block on the
`protected type` weaver mentioned in every comment and resolve all
five together. Until either lands, the README of each affected
library should carry a *prominent* "do not use in a multi-threaded
service" warning rather than a docstring buried in the source.

## F-18 [MEDIUM] `Mq.QueueConsumer.consume` requires `timeoutMs > 0` but blocks indefinitely with no upper bound

`lyric-mq/src/mq.l:120` reads `requires: timeoutMs > 0` — so `0` is
forbidden (cannot poll without blocking). And there's no upper
bound — a consumer can request `timeoutMs = Int.maxValue`. The
SQS extern (`mq_kernel.l:126`) maps `timeoutMs` to
`WaitTimeSeconds`, which SQS caps at 20 seconds; any larger value
behaves unexpectedly.

Compare to `lyric-resilience/sleepMs` (line 56) which accepts
`ms >= 0`. The mismatch is small but it bites consumers writing
"poll once, give up if nothing now" code who naturally reach for
`consume(queue, 0, ...)`.

**Fix**: relax to `timeoutMs >= 0` and document that `0` means
"poll without blocking"; add per-broker normalisation (cap SQS at
20 000 ms, etc.) inside `Mq.Kernel.Net`.

## F-19 [LOW] `lyric-otel.Tracing` aspect ignores `sampleRate`

(Counted under F-13 above; mentioned separately for the README to
strike this from the "config knobs" advertisement until the field
actually works.)

## F-20 [LOW] `lyric-storage` `presignedUrl` lacks an upper bound on expiry

`lyric-storage/src/storage.l:130` requires `expiresInSeconds >= 1`
but no upper bound. S3 caps presigned URL lifetime at 7 days
(604 800 s) when using AWS Signature v4; passing a longer value
either silently truncates or fails at runtime depending on SDK
version.

**Fix**: `requires: expiresInSeconds <= 604_800` (or whichever
provider has the lowest cap; document the per-backend cap in
`StorageBucket.presignedUrl` docstring).

## F-21 [LOW] `lyric-grpc` server `start` blocks but offers no graceful-shutdown hook

`lyric-grpc/src/grpc.l:311-322` documents "blocks until SIGTERM / SIGINT".
There is no `Grpc.stop()`, no `Grpc.serveAsync(...)`, no `await`-able
handle. A real service often needs to:

- drain in-flight RPCs before shutdown
- run health-check probes alongside the server
- compose multiple servers (e.g. gRPC + Web) in the same process

`lyric-web/src/web.l` should be checked for the same shape; if both
libraries offer only blocking `start` calls, a process cannot host
both at once.

**Fix**: add `Grpc.start(registry): GrpcServerHandle` and
`Grpc.stop(handle, drainTimeoutMs: Int): Result[Unit, String]`.

## F-22 [LOW] Mixed `pub type … = enum`, `pub enum`, and `pub union` declaration styles

Compare:

- `lyric-proto/src/types.l:12` `pub type WireType = enum { ... }`
- `lyric-mq/src/mq.l:86` `pub enum AckMode { ... }`
- `lyric-jobs/src/jobs.l:49` `pub enum JobStatus { ... }`
- `lyric-lambda/src/lambda.l:74` `pub union LambdaError { ... }`
- `lyric-feature-flags/src/flags.l:51` `pub enum FlagValue { case FlagBool(value: Bool); ... }`
- `lyric-grpc/src/types.l:20` `pub type GrpcStatusCode = enum { ... }`

Per `docs/01-language-reference.md` these are different surface
syntaxes for related concepts (data-carrying vs simple enums), but
the choice across the ecosystem is not principled — `lyric-grpc`
uses `pub type X = enum` for a simple enum, `lyric-mq` uses
`pub enum X` for the same shape; `lyric-feature-flags` uses
`pub enum` for a data-carrying variant where `lyric-lambda` uses
`pub union`.

**Fix**: pick one convention per shape and apply it consistently.
Suggest `pub enum` for simple enums, `pub union` for tagged unions,
`pub type X = enum { ... }` only when an alias name is genuinely
useful.

## F-23 [LOW] README coverage is uneven and several libraries ship without any

Libraries with no README:

- `lyric-auth`, `lyric-aws-secrets`, `lyric-aws-xray`,
  `lyric-grpc`, `lyric-lambda`, `lyric-proto`, `lyric-resilience`

These are some of the highest-stakes libraries in the ecosystem
(auth, AWS secret handling, gRPC, Lambda runtime, the proto wire
format). They each have rich header docstrings, but the README is
the discovery surface for someone browsing the repo. Compare with
`lyric-cache/README.md` and `lyric-mq/README.md` which are concise
and helpful.

**Fix**: add a one-page README per missing library, following the
existing template (intro, packages table, quick start, feature
flags, config envvars).

## F-24 [LOW] `lyric-testing` import surface is large and platform-coupled

`lyric-testing/src/testing.l:27-32` imports `Cache`, `Mail`,
`Storage`, `Mq`, `Session`, `Flags`. A consumer that only wants
`MockMailSender + assertOk` ends up depending transitively on
`Lyric.Storage`, `Lyric.Mq`, `Lyric.Session`, `Lyric.Flags`,
`Lyric.Cache`, `Lyric.Mail` and their NuGet trees (Redis,
StackExchange.Redis, AWS S3 SDK, RabbitMQ, AWS SES, MailKit, etc.).

That's a 200+ MB dependency tree on a *test* library.

**Fix**: split `lyric-testing` into one sub-package per mock
(`Lyric.Testing.Mail`, `Lyric.Testing.Storage`, etc.) so test
runners pull only what they need. Or move the mocks back into the
libraries they mock (each lib provides its own `MockXxx` under a
`Testing` sub-package).

## F-25 [LOW] `lyric-storage` `connect` is `@experimental` but the typed `connectS3`/`connectAzureBlob`/`connectLocal` are `@stable(since="0.1")` — undocumented status mismatch

`lyric-storage/src/storage.l:284` marks the generic `connect(provider)`
as `@experimental`, but the docstring explains the trade-off
clearly ("compile-time safety, prefer calling the typed ...").
The other connect helpers are `@stable`. Good — but the same
pattern doesn't exist in `lyric-search`, `lyric-mq`, `lyric-mail`,
or `lyric-jobs` which only ship one connect path each.

Worth noting: the `@experimental` annotation is also applied to
`Validation.matches` (`validation.l:139`) — and that one is
genuinely experimental in a deeper sense (it doesn't actually
implement regex matching). The annotation is doing two different
jobs: "API may change" (storage) vs. "implementation is a stub"
(validation). Distinguishing these would help consumers.

**Fix**: introduce `@stub` for "compiles, returns sensible defaults
or panics, real implementation pending" vs `@experimental` for "API
shape may change". Update `Validation.matches` to `@stub` and add a
panic-or-todo body so callers fail loud.

## F-26 [LOW] `lyric-otel` imports both `OTel.Kernel.Net` and `OTel.Kernel.Jvm` unconditionally

`lyric-otel/src/otel.l:24-25` imports both kernels regardless of
target. The comment at lines 19-23 explains:

> Both kernel packages are imported unconditionally at the source
> level. Each package is gated by @cfg(feature = ...) in its own
> file, so the manifest resolver emits nothing for inactive features
> — the import resolves to an empty namespace…

This is fine if the resolver behaves that way, but the same shape is
NOT used in `lyric-mq/src/mq.l:46` which guards the JVM kernel
import with `@cfg(feature = "jvm")`. Pick one pattern.

Combined with F-1, this is symptomatic of a broader lack of an
agreed-upon idiom for multi-platform packages. A spec doc (Spec or
checklist in `docs/14-native-stdlib-plan.md`) defining the canonical
shape would fix this once.

**Fix**: document the canonical "multi-platform package layout" in
`docs/14-native-stdlib-plan.md` Decision F appendix and conform all
libs to it.

---

## Positive observations

- **`lyric-proto` decoder defensive style** (`decoding.l:29-46`):
  every malformed input returns `Result.Err`; tracks varint overflow
  past 10 bytes; uses `Result` consistently. Solid.
- **`lyric-grpc` status-code table** (`types.l:20-62`): complete
  canonical mapping with constructor helpers (`grpc.l:222-273`).
  A consumer can reach for the right status without thinking about
  numeric codes.
- **`lyric-validation` toResult lift** (`validation.l:297-302`):
  cleanly bridges the validation domain to the rest of the
  `Result[T, E]` world. The list-of-errors error type still has
  the unification problem (F-10), but the lift itself is nice.
- **`lyric-auth` constant-time API-key comparison** (mentioned in
  docstring at `auth.l:97-99`): the right primitive in the right
  place, surfaced as a separate function rather than buried in
  the JWT path.
- **Aspect template documentation** is uniformly excellent — every
  aspect carries a "Config fields", env-var mapping, and B-mode/
  C-mode classification. This is the kind of consistency that
  should be replicated to the error-type discipline (F-10).
- **`@stable(since="0.1")`** is applied liberally and consistently,
  which gives the stability tracking work in
  `compiler/src/Lyric.Verifier/StabilityCheck.fs` real material to
  enforce against.

---

## Recommendation: REQUEST CHANGES

The CRITICAL findings (F-1 broken manifest, F-2 unspecified parity
gaps) and the HIGH findings (F-3 zero tests, F-4 zigzag semantics,
F-5/F-6 cache correctness, F-7 retry overflow, F-8 circuit state
extern-only) collectively mean the ecosystem is **not ready for v1
adoption**. The good news is that none of the CRITICAL findings
require architectural change — they're either manifest fixes
(F-1), policy documentation (F-2, F-3), or single-function rewrites
(F-4–F-8).

Priority order for the next round:

1. Land F-1 (mq manifest) — actively blocks consumers today.
2. Land F-3 (test scaffold) — protects every subsequent fix.
3. Land F-4, F-5, F-6, F-7 (concrete defects).
4. Land F-10 (error-type discipline) — necessary before v1
   stability commitments lock in.
5. Land F-8 / move circuit state into Lyric — large but unblocks
   the JVM kernel implementation.
