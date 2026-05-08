# lyric-otel

OpenTelemetry instrumentation for [Lyric](https://github.com/nichobbs/lyric-lang) via
aspect templates.  Ships three reusable `pub aspect` templates — `Tracing`,
`Metrics`, and `RequestLogging` — that consumers bind to their own call-site
selectors without modifying the instrumented code.

> **Status**: The library source and aspect template definitions are complete.
> The aspect weaver (which performs the actual call-site rewriting at compile
> time) is a planned compiler milestone.  The library can be imported and
> instantiated today; weaving takes effect once the weaver ships.

## Platform support

| Feature flag    | Backend                                          | Status       |
|-----------------|--------------------------------------------------|--------------|
| `dotnet`        | `System.Diagnostics.ActivitySource` + `Metrics` | Available    |
| `jvm`           | `io.opentelemetry.api` (Phase 6)                 | Planned      |

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
"Lyric.OTel" = "0.1.0"
```

## Usage

### 1. Instantiate a template aspect

Import the package and declare a local aspect that binds the template to a
`matches:` selector.  The aspect lives in your package; the advice body comes
from the template.

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

### 2. Override config defaults

Each template exposes a `config { }` block with typed fields and default
values.  Override any field in the instantiation:

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

### 3. Runtime overrides via environment variables

Any config field can be overridden at startup without recompiling.  The
variable name is `LYRIC_ASPECT_<INSTANTIATION_NAME>_<FIELD>` (upper-cased):

```sh
LYRIC_ASPECT_HTTPRACING_ENABLED=false      # disable tracing entirely
LYRIC_ASPECT_HTTPRACING_SAMPLERATE=0.05    # 5 % sampling
LYRIC_ASPECT_HANDLERLOGGING_LEVEL=warn     # only warn-level logs
```

## Aspect template reference

### `OTel.Tracing`

Wraps each matched call in an OTel trace span.  On success the span ends
cleanly; on error the exception message is recorded and the span is marked
failed before it ends.

| Field        | Type       | Default              | Description                              |
|--------------|------------|----------------------|------------------------------------------|
| `enabled`    | `Bool`     | `true`               | Master switch; `false` skips all tracing |
| `sampleRate` | `Float`    | `1.0`                | Fraction of calls to trace (0.0–1.0)     |
| `spanKind`   | `SpanKind` | `SpanKind.Internal`  | OTel span kind for every span            |

`SpanKind` values: `Internal`, `Server`, `Client`, `Producer`, `Consumer`.

### `OTel.Metrics`

Increments a call counter and records a latency histogram (in milliseconds)
for each matched call.

| Field     | Type   | Default | Description                               |
|-----------|--------|---------|-------------------------------------------|
| `enabled` | `Bool` | `true`  | Master switch; `false` skips all metrics  |

Metric names emitted:
- `<qualifiedFunctionName>` — counter, unit `requests`
- `<qualifiedFunctionName>.latency` — histogram, unit `ms`

### `OTel.RequestLogging`

Logs function entry and exit via `Std.Log`, including elapsed time on exit.

| Field     | Type     | Default   | Description                                        |
|-----------|----------|-----------|----------------------------------------------------|
| `enabled` | `Bool`   | `true`    | Master switch; `false` skips all logging           |
| `level`   | `String` | `"debug"` | Log level: `"debug"` \| `"info"` \| `"warn"`       |

## Low-level API

The platform-dispatch wrapper functions are also exported if you need to
instrument code manually without aspects:

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

| Function                                         | Description                        |
|--------------------------------------------------|------------------------------------|
| `startSpan(name: String, kind: Int): Span`       | Start a new trace span             |
| `setSpanError(span: Span, msg: String): Unit`    | Record an error; does not end span |
| `endSpan(span: Span): Unit`                      | End the span                       |
| `incrementCounter(name, delta, unit): Unit`      | Add to a named counter             |
| `recordHistogram(name, value, unit): Unit`       | Record a histogram observation     |

## Package layout

```
lyric-otel/
  lyric.toml                        package manifest
  README.md                         this file
  src/
    types.l                         Span, SpanKind, MetricUnit
    otel.l                          platform wrappers + pub aspect templates
    _kernel/
      net/otel_kernel.l             .NET extern boundary (@cfg dotnet)
      jvm/otel_kernel.l             JVM extern boundary (@cfg jvm, Phase 6)
```

## See also

- `docs/26-aspects.md` §18 — aspect template design and instantiation rules
- `docs/27-aspect-libraries.md` — cross-package aspect distribution design
- `docs/03-decision-log.md` D050/D051 — design decisions backing this library
