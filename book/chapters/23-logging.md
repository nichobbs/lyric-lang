# Chapter 23: Logging

Lyric services use the `Std.Logging` package (from `lyric-logging`) for
structured, named, runtime-configurable logging.  `Std.Logging` adds named
loggers, six severity levels, structured fields, and JSON/text formatting on
top of the stdlib's minimal `Std.Log`.

## Adding the dependency

```toml
# lyric.toml
[dependencies]
"Std.Logging" = { path = "../lyric-logging" }
```

## Basic usage

```lyric
import Std.Logging

val logger = Std.Logging.getLogger("MyService")

Std.Logging.info(logger, "server started")
Std.Logging.warn(logger, "disk usage high")
Std.Logging.error(logger, "unhandled exception: " + e.message)
```

## Log levels

From lowest to highest severity:

| Level | Use case |
|---|---|
| `Trace` | Per-call tracing; very noisy |
| `Debug` | Detailed diagnostic output |
| `Info` | Normal operational messages |
| `Warn` | Recoverable issues |
| `Error` | Failures that affect a request |
| `Fatal` | Unrecoverable conditions |

The minimum enabled level is controlled by the `LYRIC_CONFIG_STD_LOGGING_DEFAULTS_LEVEL`
env var (default: `Info`).  Messages below the configured level are discarded
without any allocation.

## Structured fields

Attach key-value pairs to a log message for structured log queries:

```lyric
Std.Logging.log(logger, Std.Logging.LogLevel.Info,
  "user logged in",
  [Std.Logging.field("userId", userId),
   Std.Logging.field("ip", requestIp)])
```

In JSON format, fields appear alongside the message:

```json
{"level":"INFO","msg":"user logged in","userId":"42","ip":"203.0.113.7"}
```

## Output format

Set `LYRIC_CONFIG_STD_LOGGING_DEFAULTS_FORMAT` to `json` or `text` (default: `text`).

- `text` — human-readable: `2026-05-10T12:00:00Z INFO  [MyService] user logged in`
- `json` — machine-readable: `{"ts":"...","level":"INFO","logger":"MyService","msg":"..."}`

## Convenience functions

```lyric
Std.Logging.trace(logger, msg)
Std.Logging.debug(logger, msg)
Std.Logging.info(logger,  msg)
Std.Logging.warn(logger,  msg)
Std.Logging.error(logger, msg)
Std.Logging.fatal(logger, msg)
```

Each is equivalent to `Std.Logging.log(logger, level, msg, [])`.

## Checking if a level is enabled

```lyric
if Std.Logging.isEnabled(logger, Std.Logging.LogLevel.Debug) {
  Std.Logging.debug(logger, "expensive: " + computeDebugInfo())
}
```

Use `isEnabled` to guard expensive message construction.

## Aspect templates (`Std.Logging.Aspects`)

The `Std.Logging.Aspects` package provides three reusable templates.

### CallLogging

B-mode: logs `→ name` before and `← name (Nms)` after each matched call.

```lyric
import Std.Logging.Aspects

aspect ServiceLogging from Std.Logging.Aspects.CallLogging {
  matches: name like "handle*"
  config { level: Std.Logging.LogLevel = Std.Logging.LogLevel.Debug }
}
```

### SlowCallAlert

B-mode: logs a warning when elapsed time exceeds `thresholdMs`.  Carries
`ensures: call.elapsed.unwrapOr(0) >= 0` for proof-required consumers.

```lyric
aspect SlowAlert from Std.Logging.Aspects.SlowCallAlert {
  matches: name like "handle*"
  inside:  ServiceLogging
  config { thresholdMs: Int = 200 }
}
```

### ErrorResultLogging

B-mode: logs when a matched handler returns `Err`.  Apply only to handlers
whose return type has an `isErr` field.

```lyric
aspect ErrorLog from Std.Logging.Aspects.ErrorResultLogging {
  matches: name like "handle*"
  config { level: Std.Logging.LogLevel = Std.Logging.LogLevel.Error }
}
```

## Config reference

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_CONFIG_STD_LOGGING_DEFAULTS_LEVEL` | `Info` | Minimum log level |
| `LYRIC_CONFIG_STD_LOGGING_DEFAULTS_FORMAT` | `text` | Output format (`text` or `json`) |

Aspect config (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Default | Applies to |
|---|---|---|
| `enabled` | `true` | All three templates |
| `level` | `Debug` | `CallLogging`, `ErrorResultLogging` |
| `loggerName` | `""` (use `call.modulePath`) | All three |
| `thresholdMs` | `500` | `SlowCallAlert` |
| `alertLevel` | `Warn` | `SlowCallAlert` |
