# lyric-otel

OpenTelemetry instrumentation for [Lyric](https://github.com/nichobbs/lyric-lang):
span/metric recording plus OTLP/HTTP export, and three reusable `pub aspect`
templates — `Tracing`, `Metrics`, and `RequestLogging` — that consumers bind
to their own call-site selectors without modifying the instrumented code.

> **Status** (issue #5410): span/metric recording (`OTel.startSpan`/
> `endSpan`/`setSpanAttribute`/`setSpanError`/`incrementCounter`/
> `recordHistogram`) and OTLP/HTTP export (`OTel.Otlp`) are genuinely
> functional on the `dotnet` target — not a no-op. Earlier versions of
> this library bound `System.Diagnostics.ActivitySource`/`Meter` for
> recording and the OTel .NET SDK's fluent `AddOtlpExporter(...)` builder
> for export; both were confirmed no-ops (`ActivitySource.StartActivity`
> returns `null` without a registered `ActivityListener`, and the fluent
> builder needs `Action<T>` delegate construction auto-FFI cannot express
> — see `docs/03-decision-log.md` D122). This library no longer depends
> on the OTel .NET SDK at all: span/metric state is a plain in-process
> Lyric record, and OTLP export builds protobuf directly with
> `lyric-proto` and POSTs it over a dedicated `HttpClient`/
> `ByteArrayContent` kernel. See "Known limitations" below for what is
> still out of scope, and "Platform support" for JVM's honest status.
>
> The aspect weaver (which performs the call-site rewriting the `Tracing`/
> `Metrics`/`RequestLogging` templates rely on) has shipped since D047/
> D050/D-progress-292/D114/D115 — it is not a "planned compiler milestone".

## Platform support

| Feature flag | Recording (span/metric bookkeeping) | OTLP/HTTP export       |
|--------------|--------------------------------------|-------------------------|
| `dotnet`     | Available (pure Lyric, no BCL)        | Available (protobuf/HTTP via `HttpClient`) |
| `jvm`        | Available (same pure-Lyric code)      | **Not implemented** — every `configureOtlp*` call returns `Err`; see `docs/44-jvm-production-readiness-plan.md` |

Recording (`OTel.startSpan`/`endSpan`/`setSpanAttribute`/`setSpanError`/
`incrementCounter`/`recordHistogram`) has no BCL dependency at all — it
works identically on both targets. Only the OTLP/HTTP *export* step needs
a real HTTP transport, which today exists for `dotnet` only. On `jvm`,
spans/metrics still get recorded into the in-process buffer, but nothing
ever drains it — `flushOtlpAsync` is effectively a no-op on that target.

OTLP/**gRPC** transport (`OtlpProtocol.Grpc`) is declared for API-shape
parity with real OTel SDKs but is **not implemented on either target** —
it needs HTTP/2 trailers-based framing, well beyond what this redesign
scoped in. `configureOtlpTraces`/`configureOtlpMetrics` return `Err`
immediately for `OtlpProtocol.Grpc` rather than silently ignoring it;
`defaultConfig()` returns an `OtlpProtocol.HttpProtobuf` config for
exactly this reason.

Select a platform by declaring the feature in your `lyric.toml`:

```toml
[features]
dotnet = []
```

## Installation

Add `Lyric.OTel` as a dependency in your project manifest:

```toml
[dependencies]
"Lyric.OTel" = { path = "../lyric-otel" }
```

Or, once the package is published to the Lyric registry:

```toml
[dependencies]
"Lyric.OTel" = "0.2.0"
```

## Usage

### 1. Record spans and metrics directly

```lyric
import OTel

pub func processRequest(req: Request): Response {
  val span = OTel.startSpan("processRequest", SpanKind.Server.toInt())
  match doWork(req) {
    case Ok(resp) -> {
      OTel.endSpan(span)
      Ok(resp)
    }
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(e)
    }
  }
}
```

### 2. Configure and flush OTLP/HTTP export

```lyric
import OTel.Otlp

func main(): Unit {
  val _ = configureOtlp(defaultConfig())
  // ... application code calling OTel.startSpan/endSpan/incrementCounter/... ...
  val ok = await flushOtlpAsync(5000)
}
```

`flushOtlpAsync` drains every buffered span (POSTed to
`<endpoint>/v1/traces`) and snapshots every counter/histogram (POSTed to
`<endpoint>/v1/metrics`) as OTLP protobuf. There is no background flush
thread — call it periodically, and always before process exit in
short-lived processes (Lambda, batch jobs) so the last batch isn't lost.

### 3. Instantiate a template aspect

Import the package and declare a local aspect that binds the template to
a `matches:` selector. The aspect lives in your package; the advice body
comes from the template.

```lyric
import OTel

// Trace every function under the Http namespace.
aspect HttpTracing from OTel.Tracing {
  matches: name like "*/Http/*"
}

// Emit metrics for every public service entry point.
aspect ServiceMetrics from OTel.Metrics {
  matches: name like "*/Service/*"
}

// Log entry/exit for all request handlers.
aspect HandlerLogging from OTel.RequestLogging {
  matches: name like "*/Handler/*"
}
```

### 4. Override config defaults

Each template exposes a `config { }` block with typed fields and default
values. Override any field in the instantiation:

```lyric
import OTel

aspect HttpTracing from OTel.Tracing {
  matches: name like "*/Http/*"
  config {
    spanKind:   SpanKind = SpanKind.Server
    sampleRate: Float    = 0.25
  }
}

aspect HandlerLogging from OTel.RequestLogging {
  matches: name like "*/Handler/*"
  config {
    level: String = "info"
  }
}
```

### 5. Runtime overrides via environment variables

Any config field can be overridden at startup without recompiling. The
variable name is `LYRIC_ASPECT_<INSTANTIATION_NAME>_<FIELD>` (upper-cased):

```sh
LYRIC_ASPECT_HTTPRACING_ENABLED=false      # disable tracing entirely
LYRIC_ASPECT_HTTPRACING_SAMPLERATE=0.05    # 5 % sampling
LYRIC_ASPECT_HANDLERLOGGING_LEVEL=warn     # only warn-level logs
```

## Aspect template reference

### `OTel.Tracing`

Wraps each matched call in an OTel trace span. On success the span ends
cleanly; on error the exception message is recorded and the span is marked
failed before it ends.

| Field        | Type       | Default              | Description                              |
|--------------|------------|----------------------|------------------------------------------|
| `enabled`    | `Bool`     | `true`               | Master switch; `false` skips all tracing |
| `sampleRate` | `Float`    | `1.0`                | Fraction of calls to trace (0.0–1.0)     |
| `spanKind`   | `SpanKind` | `SpanKind.Internal`  | OTel span kind for every span            |

`SpanKind` values: `Internal`, `Server`, `Client`, `Producer`, `Consumer`.

### `OTel.Metrics`

Increments a call counter for each matched call.

| Field     | Type   | Default | Description                               |
|-----------|--------|---------|--------------------------------------------|
| `enabled` | `Bool` | `true`  | Master switch; `false` skips all metrics  |

Metric names emitted:
- `<qualifiedFunctionName>` — counter, unit `requests`

### `OTel.RequestLogging`

Logs function entry and exit via `Std.Log`.

| Field     | Type     | Default   | Description                                        |
|-----------|----------|-----------|-----------------------------------------------------|
| `enabled` | `Bool`   | `true`    | Master switch; `false` skips all logging           |
| `level`   | `String` | `"debug"` | Log level: `"debug"` \| `"info"` \| `"warn"`       |

## Low-level API

| Function                                          | Description                                    |
|----------------------------------------------------|-------------------------------------------------|
| `startSpan(name: String, kind: Int): Span`        | Start a new trace span (always succeeds)       |
| `setSpanError(span: Span, msg: String): Unit`     | Record an error; does not end the span         |
| `setSpanAttribute(span, key, value): Unit`        | Attach a string attribute; call before `endSpan`|
| `endSpan(span: Span): Unit`                       | End the span; enqueues it for OTLP export       |
| `incrementCounter(name, delta, unit): Unit`       | Add to a named cumulative counter               |
| `recordHistogram(name, value, unit): Unit`        | Record a histogram observation                  |

`OTel.Otlp`:

| Function                                              | Description                                       |
|--------------------------------------------------------|-----------------------------------------------------|
| `defaultConfig(): OtlpExporterConfig`                 | `http://localhost:4318`, `OtlpProtocol.HttpProtobuf` |
| `configureOtlpTraces(cfg): Result[Unit, String]`      | Configure the traces exporter                      |
| `configureOtlpMetrics(cfg): Result[Unit, String]`     | Configure the metrics exporter                     |
| `configureOtlpLogs(cfg): Result[Unit, String]`        | Always `Err` — not implemented (see below)         |
| `configureOtlp(cfg): Result[Unit, String]`            | Configure traces then metrics                      |
| `flushOtlpAsync(timeoutMs): Bool`                     | POST every buffered span/metric; `true` iff every configured, non-empty signal got a 2xx response |

## Known limitations

These are deliberate scope cuts, not silent gaps — each is a candidate
follow-up, not a promise this library doesn't yet keep:

- **No trace-context propagation.** Every `startSpan` call generates its
  own fresh 16-byte trace ID and 8-byte span ID (via
  `Std.SecureRandom.secureGetBytes`) rather than inheriting one from an
  enclosing span. Every exported span is therefore the root of its own
  single-span trace — nested `startSpan` calls do not appear as parent/
  child in the collector today. Parent/child linkage (OTLP's
  `parent_span_id`) is a natural follow-up once this library threads a
  "current span" through call context.
- **No OTLP logs exporter.** `configureOtlpLogs` always returns `Err`.
  Traces and metrics only.
- **OTLP/gRPC is not implemented** (either target). Only OTLP/HTTP
  (`Content-Type: application/x-protobuf`) is supported.
- **JVM OTLP/HTTP export is not implemented.** Span/metric recording
  works on `jvm` (it's pure Lyric), but nothing ever exports it — see
  the platform-support table above.
- **No background flush.** `flushOtlpAsync` is call-driven only; there
  is no timer or size-triggered auto-export thread. The span buffer is
  capped at 2048 entries (older spans silently dropped) so an
  application that never flushes cannot grow it unbounded.
- **Histograms have a single implicit bucket.** `recordHistogram`
  aggregates `count`/`sum` per metric name but does not bucket by value,
  so the exported `HistogramDataPoint` supports `count`/`sum`/average in
  the collector, not percentile queries.
- **Fixed Resource/InstrumentationScope identity.** Every export carries
  a hard-coded `service.name = "lyric.otel"` resource attribute and
  `lyric-otel`/`0.2.0` instrumentation scope — there is no per-application
  resource-attribute configuration yet.
- **Millisecond timestamp resolution.** OTLP's `fixed64` time fields are
  populated from `Std.Time.nowEpochMillis() * 1_000_000`, so the low six
  decimal digits of every nanosecond timestamp are always zero. This is
  spec-valid (OTLP does not mandate a resolution) but coarser than a
  true nanosecond clock.

## Package layout

```
lyric-otel/
  lyric.toml                        package manifest
  README.md                         this file
  src/
    types.l                         Span, SpanAttribute, span/metric buffers (OTel.Types)
    otlp_codec.l                    pure-Lyric OTLP protobuf encoder (OTel.Otlp.Codec)
    otel.l                          span/metric recording API + pub aspect templates (OTel)
    otlp.l                          OTLP exporter configuration and lifecycle (OTel.Otlp)
    _kernel/
      net/otlp_kernel.l             .NET OTLP/HTTP transport kernel (@cfg dotnet)
      jvm/otlp_kernel.l             JVM stub — always Err (@cfg jvm)
  tests/
    otel_types_tests.l              SpanKind/MetricUnit enum matching
    otel_span_tests.l               span/metric recording + buffering behaviour
    otlp_codec_tests.l              byte-exact + decode-based OTLP protobuf encoder tests
    otlp_transport_tests.l          env-gated live-collector transport test (no-op in CI)
```

## See also

- `docs/26-aspects.md` §18 — aspect template design and instantiation rules
- `docs/27-aspect-libraries.md` — cross-package aspect distribution design
- `docs/03-decision-log.md` D050/D051/D122 — design decisions backing this library
- `lyric-proto/README.md` — the pure-Lyric protobuf encoder this library builds on
- `docs/44-jvm-production-readiness-plan.md` — JVM OTLP export tracking
