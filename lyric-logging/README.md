# lyric-logging

Structured, named, runtime-configurable logging for [Lyric](https://github.com/nichobbs/lyric-lang), with aspect templates for automatic call instrumentation.

> **Status**: Library source is complete.  The aspect weaver (call-site rewriting) and config-block emitter (env-var startup hook) are planned compiler milestones.  The library can be imported and instantiated today; weaving and runtime config take effect once those features ship.

## Packages

| Package | Description |
|---|---|
| `Std.Logging` | Core: `Logger`, `LogLevel`, `LogField`, level filter, text/JSON formatting |
| `Std.Logging.Aspects` | Template aspects: `CallLogging`, `SlowCallAlert`, `ErrorResultLogging` |

## Installation

```toml
[dependencies]
"Std.Logging" = { path = "../lyric-logging" }
```

## Quick start

```lyric
import Std.Logging

val log = Std.Logging.getLogger("MyApp.Service")

Std.Logging.info(log, "server starting")
Std.Logging.log(log, LogLevel.Warn, "pool low", [Std.Logging.field("size", poolSize.toString())])
```

## Runtime configuration

```sh
export LYRIC_CONFIG_STD_LOGGING_DEFAULTS_LEVEL=Debug   # Trace | Debug | Info | Warn | Error | Fatal
export LYRIC_CONFIG_STD_LOGGING_DEFAULTS_FORMAT=json   # text (default) | json
```

All config is read once at startup before `main` runs.  Missing required fields abort with exit code 78; both fields have defaults so no env var is required for a working installation.

## Output formats

**Text** (default):

```
[INFO] [MyApp.Service] server starting
[WARN] [MyApp.Service] pool low size=3
```

**JSON** (`LYRIC_CONFIG_STD_LOGGING_DEFAULTS_FORMAT=json`):

```json
{"level":"info","logger":"MyApp.Service","msg":"server starting"}
{"level":"warn","logger":"MyApp.Service","msg":"pool low","size":"3"}
```

## LogLevel

Six levels in ascending severity order:

| Level | Ordinal | Host key | Typical use |
|---|---|---|---|
| `Trace` | 0 | `trace` | Fine-grained loop / per-call tracing |
| `Debug` | 1 | `debug` | Development diagnostics |
| `Info`  | 2 | `info`  | Normal operational events (default filter) |
| `Warn`  | 3 | `warn`  | Degraded but continuing |
| `Error` | 4 | `error` | Operation failed; service continues |
| `Fatal` | 5 | `fatal` | Unrecoverable; process will exit |

`Trace` and `Fatal` map to `debug` and `error` respectively at the host diagnostic sink (`Std.LogHost`).

## Aspect templates

Import `Std.Logging.Aspects` and bind a template to a `matches:` selector in your package.

### `Std.Logging.Aspects.CallLogging`

Logs function entry and exit for every matched call.

```lyric
import Std.Logging.Aspects

aspect ApiLogging from Std.Logging.Aspects.CallLogging {
  matches: name like "handle*"
  except name in { handleHealthcheck }
  config {
    level: LogLevel = LogLevel.Info   // override from Debug
  }
}
```

Output (at `Info` with no filter):

```
[INFO] [MyApp.Handlers] → handleCreateOrder
[INFO] [MyApp.Handlers] ← handleCreateOrder (42ms)
```

| Config field | Type | Default | Env var (using local name `ApiLogging`) |
|---|---|---|---|
| `enabled` | `Bool` | `true` | `LYRIC_ASPECT_APILOGGING_ENABLED` |
| `level` | `LogLevel` | `LogLevel.Debug` | `LYRIC_ASPECT_APILOGGING_LEVEL` |
| `loggerName` | `String` | `""` (→ `call.modulePath`) | `LYRIC_ASPECT_APILOGGING_LOGGERNAME` |

### `Std.Logging.Aspects.SlowCallAlert`

Logs a warning when a call exceeds a latency threshold.  Proceeds unconditionally; only emits when the measured elapsed time exceeds `thresholdMs`.

```lyric
aspect ApiSlowAlert from Std.Logging.Aspects.SlowCallAlert {
  matches: name like "handle*"
  inside: ApiLogging          // nest inside CallLogging
  config {
    thresholdMs: Int = 500
  }
}
```

Output when a call takes 750ms against a 500ms threshold:

```
[WARN] [MyApp.Handlers] SLOW: handleCreateOrder took 750ms (threshold: 500ms)
```

The template declares `ensures: call.elapsed.unwrapOr(0) >= 0`, which propagates to every matched function's composed contract so downstream verifiers can reason about the timing measurement.

| Config field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `thresholdMs` | `Int` | `1000` | Alert threshold in milliseconds |
| `alertLevel` | `LogLevel` | `LogLevel.Warn` | Severity of the alert record |
| `loggerName` | `String` | `""` | Logger name; empty → `call.modulePath` |

### `Std.Logging.Aspects.ErrorResultLogging`

Logs when a matched function returns `Err(...)`.  This is a **C-mode** template (`@inline_template`): the body is re-compiled inside your package so it can read `ret.isErr` on the concrete return type.  Apply only to functions returning `Result[T, E]`; the compiler reports a shape error otherwise.

```lyric
import Std.Logging.Aspects

aspect ApiErrors from Std.Logging.Aspects.ErrorResultLogging {
  matches: name like "handle*"
  inside: ApiSlowAlert
}
```

Output on `Err`:

```
[ERROR] [MyApp.Handlers] ERROR: handleCreateOrder failed after 12ms
```

| Config field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `level` | `LogLevel` | `LogLevel.Error` | Severity of the error record |
| `loggerName` | `String` | `""` | Logger name; empty → `call.modulePath` |

## Full example — three aspects composed

```lyric
package MyApp.Handlers

import Std.Core
import Std.Logging.Aspects

// Outer → inner: ApiLogging > ApiSlowAlert > ApiErrors > target
aspect ApiLogging from Std.Logging.Aspects.CallLogging {
  matches: name like "handle*"
  except name in { handleHealthcheck }
  config {
    level: LogLevel = LogLevel.Info
  }
}

aspect ApiSlowAlert from Std.Logging.Aspects.SlowCallAlert {
  matches: name like "handle*"
  inside: ApiLogging
  config {
    thresholdMs: Int = 200
  }
}

aspect ApiErrors from Std.Logging.Aspects.ErrorResultLogging {
  matches: name like "handle*" and visibility: pub
  inside: ApiSlowAlert
}
```

Operator env vars:

```sh
export LYRIC_CONFIG_STD_LOGGING_DEFAULTS_LEVEL=Info
export LYRIC_ASPECT_APISLOWALER_THRESHOLDMS=100     # tighten SLO in production
export LYRIC_ASPECT_APIERRORS_LEVEL=Fatal           # escalate in production
```

## Low-level API

The `Std.Logging` functions are also available for direct use without aspects:

```lyric
import Std.Logging

val log = Std.Logging.getLogger("MyApp.Database")

pub func query(sql: in String): Result[Rows, DbError] {
  Std.Logging.debug(log, "executing query")
  val result = Db.exec(sql)
  match result {
    case Ok(rows) -> {
      Std.Logging.log(log, LogLevel.Debug, "query ok", [Std.Logging.field("rows", rows.count.toString())])
      Ok(rows)
    }
    case Err(e) -> {
      Std.Logging.log(log, LogLevel.Error, "query failed", [Std.Logging.field("error", e.message)])
      Err(e)
    }
  }
}
```

| Function | Signature | Description |
|---|---|---|
| `getLogger` | `(name: String) → Logger` | Return a named logger (pure) |
| `isEnabled` | `(level: LogLevel) → Bool` | Test the global level filter |
| `log` | `(logger, level, msg, fields) → Unit` | Emit with structured fields |
| `logMsg` | `(logger, level, msg) → Unit` | Emit with no fields |
| `trace/debug/info/warn/error/fatal` | `(logger, msg) → Unit` | Level-specific shorthands |
| `field` | `(key, value: String) → LogField` | Build a structured field |

## Package layout

```
lyric-logging/
  lyric.toml                    package manifest
  README.md                     this file
  src/
    logging.l                   Std.Logging  (core types + API)
    logging_aspects.l           Std.Logging.Aspects  (pub aspect templates)
```

## See also

- `docs/26-aspects.md` §18 — aspect template design and instantiation rules
- `docs/27-aspect-libraries.md` — cross-package aspect distribution design
- `docs/25-config-blocks.md` — config block semantics (D046)
- `docs/03-decision-log.md` D052 — design decisions for this library
