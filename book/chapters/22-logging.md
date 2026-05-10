# Structured Logging

Every program eventually needs to write diagnostic output. The simplest option is `Std.Log` — the four-function minimal logger that ships in the standard library. It covers the single-file script and the prototype service well. But `Std.Log` has no named loggers, no structured fields, no JSON output, and no level filtering beyond what the underlying runtime provides. When you are running a multi-service backend and piping logs into a centralised aggregator, those limitations become real costs.

`Std.Logging`, from the `lyric-logging` library, is the production-grade answer. It adds named loggers so each module's output is identifiable in the aggregator, structured key-value fields so downstream search and alerting can query on data rather than grepping text, a `config` block that maps deployment environment variables to log level and format, and a companion `Std.Logging.Aspects` package that lets you attach call logging, slow-call alerts, and error logging to entire families of functions without touching their bodies.

::: note
**Implementation status.** The `Std.Logging` API (types, functions, `getLogger`, `field`, level helpers) is importable and usable today. The `config Defaults` block — and its runtime env-var behaviour — is gated on the config-block emitter milestone (Chapter 20). The `Std.Logging.Aspects` templates compile and type-check today; the runtime weaver that actually applies them is gated on the aspect weaver milestone (Chapter 21). Code you write today will work correctly once both milestones ship without any source changes.
:::

## §22.1 Installation

`Std.Logging` is not part of the standard library bundle — it lives in a separate `lyric-logging` package. Add it to your `lyric.toml`:

```toml
[dependencies]
"Lyric.Logging" = { path = "../lyric-logging" }
```

For projects that pull from a registry instead of a local path, replace the `path` value with a version constraint:

```toml
[dependencies]
"Lyric.Logging" = "^1.0"
```

The `lyric-logging` package exposes two Lyric packages: `Std.Logging` and `Std.Logging.Aspects`. They are independent imports — you can use the core API without the aspect templates, and you can import the aspects without using the API directly in your own functions.

After adding the dependency, run `lyric restore` to fetch and cache the package, then `lyric build` to verify the manifest resolves correctly.

## §22.2 Getting a logger and writing messages

The first thing to do in any module that logs is request a named logger. Named loggers appear in every log line, so your aggregator can filter to all output from `MyApp.Checkout` without touching `MyApp.Inventory` or `MyApp.Auth`.

```lyric
import Std.Logging

val log = Std.Logging.getLogger("MyApp.Checkout")
```

`getLogger` takes a single `String` name and returns a `Logger` value. The `requires: name.length > 0` precondition on `getLogger` is checked at runtime in `@runtime_checked` packages and as a proof obligation in `@proof_required` packages — passing an empty string is a bug, not a configuration option. The returned `Logger` is a plain `record { name: String }` with no mutable state; you can store it in a `val`, pass it to functions, or embed it in a `wire` binding without ceremony.

Once you have a logger, the level-specific helpers cover the common cases:

```lyric
Std.Logging.info(log, "checkout started")
Std.Logging.warn(log, "cart is empty, proceeding anyway")
Std.Logging.error(log, "payment processor returned 503")
```

The six level helpers are `trace`, `debug`, `info`, `warn`, `error`, and `fatal`, each with the same signature:

```lyric
// level helpers — all have this shape:
Std.Logging.info(logger: in Logger, message: in String): Unit
```

If you need to pass the level dynamically, use the `logMsg` function, which takes a `LogLevel` argument:

```lyric
val level = Std.Logging.LogLevel.Warn
Std.Logging.logMsg(log, level, "this came from somewhere dynamic")
```

Or use `log` for the full call with level and structured fields at once (§22.4).

::: sidebar
**`Std.Log` vs `Std.Logging`.** The two names are easy to confuse. `Std.Log` (no dependency required, always available) is a four-function minimal logger: `Std.Log.info`, `Std.Log.warn`, `Std.Log.error`, and `Std.Log.debug`. It writes to stderr, is best-effort, has no named loggers, and produces human-readable text regardless of the deployment environment. Use it in scripts, in test helpers, and during rapid prototyping. Switch to `Std.Logging` when you need any of: named loggers, structured fields, JSON output, or level-filtering from an env var.
:::

## §22.3 Level filtering and the `Defaults` config block

Writing a log line at `Debug` level is cheap when the message is a literal string. It becomes expensive when constructing the message requires allocating intermediate values — formatting a large map, serialising a request body, running a diagnostic query. For those cases you want to check the effective level before doing the work:

```lyric
if Std.Logging.isEnabled(Std.Logging.LogLevel.Debug) {
  val summary = buildExpensiveDiagnostic(order)
  Std.Logging.debug(log, summary)
}
```

`isEnabled(level)` returns `true` if the effective level is at or below the given level — that is, if the message would actually be emitted. No allocation happens inside the `if` block when `Debug` is above the configured threshold.

The effective level is controlled by the `Defaults` config block that `Std.Logging` declares internally:

```lyric
// inside Std.Logging (shown for reference — you do not write this):
config Defaults {
  level:  LogLevel = LogLevel.Info
  format: String   = "text"
}
```

Two environment variables control it at deployment time:

| Env var | Default | Accepted values |
|---|---|---|
| `LYRIC_CONFIG_STD_LOGGING_DEFAULTS_LEVEL` | `Info` | `Trace`, `Debug`, `Info`, `Warn`, `Error`, `Fatal` |
| `LYRIC_CONFIG_STD_LOGGING_DEFAULTS_FORMAT` | `text` | `text`, `json` |

Setting `LYRIC_CONFIG_STD_LOGGING_DEFAULTS_LEVEL=Debug` lowers the threshold so `debug` calls are emitted. Setting it to `Error` suppresses everything below `Error`. The level name is matched case-insensitively.

The `format` field switches the output shape. `text` produces human-readable lines suitable for a developer terminal:

```
2026-05-10T14:22:31Z [INFO ] MyApp.Checkout  checkout started
2026-05-10T14:22:31Z [WARN ] MyApp.Checkout  cart is empty, proceeding anyway
```

`json` produces one JSON object per line, suitable for Elasticsearch, Datadog, Loki, and similar aggregators:

```json
{"ts":"2026-05-10T14:22:31Z","level":"INFO","logger":"MyApp.Checkout","msg":"checkout started"}
{"ts":"2026-05-10T14:22:31Z","level":"WARN","logger":"MyApp.Checkout","msg":"cart is empty, proceeding anyway"}
```

In JSON mode, structured fields (§22.4) appear as additional keys on the same object rather than as appended text.

::: note
**Config block scoping.** `config` blocks are package-private (Chapter 20 §20.1.1), so `Defaults` belongs to `Std.Logging` and is only writable via its own env vars. Your application does not declare or override `Defaults` directly. If you need per-module log levels — which `Defaults` does not support — that is a planned v2 feature; for now, use `isEnabled` guards around verbose calls.
:::

## §22.4 Structured fields

Structured logging means attaching typed key-value pairs to a log entry so downstream tooling can query and aggregate on them. In `Std.Logging` you build field values with `Std.Logging.field` and pass them as a list to the `log` function:

```lyric
Std.Logging.log(log, Std.Logging.LogLevel.Info, "order placed",
  [Std.Logging.field("orderId",  orderId.toString()),
   Std.Logging.field("amount",   amount.toString()),
   Std.Logging.field("currency", currency.code)])
```

`field(key, value)` returns a `LogField` record:

```lyric
pub record LogField {
  key:   String
  value: String
}
```

Both sides are `String`. This is intentional: log field values are always rendered, never interpreted as numbers or booleans inside the logging library. Formatting is your responsibility — call `.toString()` on numeric values and format dates before passing them in. The `requires: key.length > 0` precondition on `field` guards against accidentally creating a field with no name, which would produce a silent structural inconsistency in JSON output.

In `text` format the fields are appended after the message:

```
2026-05-10T14:22:31Z [INFO ] MyApp.Checkout  order placed  orderId=7192 amount=49.99 currency=USD
```

In `json` format they become peer keys:

```json
{"ts":"2026-05-10T14:22:31Z","level":"INFO","logger":"MyApp.Checkout","msg":"order placed","orderId":"7192","amount":"49.99","currency":"USD"}
```

When you have no fields to attach — the common case for simple informational messages — use the level helpers directly (§22.2) rather than passing an empty list to `log`. The level helpers resolve to `logMsg` internally, which takes no fields parameter and incurs no list allocation.

::: sidebar
**String-only fields and structured logging best practices.** A mature structured logging library might accept typed fields (`IntField`, `DurationField`, `BoolField`) so the aggregator sees native JSON types. `Std.Logging` v1 keeps everything as `String` for the same reason Lyric's `config` blocks restrict field types: a uniform flat representation is trivially serialisable, roundtrips without schema negotiation, and does not require the log consumer to know your domain types. If you need numeric aggregation — sum of `amount` across orders — emit the value as a string and configure your aggregator to cast at query time, which every major platform supports.
:::

## §22.5 Aspect templates overview

The `Std.Logging.Aspects` package ships three `pub aspect` templates (Chapter 21 §21.7) that you can instantiate in your own packages to attach logging behaviour to function families without writing any call-site code.

**`CallLogging`** (B-mode) logs function entry and exit with the elapsed time. It is the aspect equivalent of writing `Std.Logging.debug(log, "→ funcName")` and `Std.Logging.debug(log, "← funcName (N ms)")` at the top and bottom of every matched function.

```lyric
// Config fields with their defaults:
// enabled:    Bool     = true
// level:      LogLevel = LogLevel.Debug
// loggerName: String   = ""   // empty → uses call.modulePath
```

When `loggerName` is empty, the aspect acquires a logger named after the module that contains the matched function — so output from `MyApp.Checkout` functions appears under the `MyApp.Checkout` logger automatically.

**`SlowCallAlert`** (B-mode) emits a warning when a call exceeds a configurable elapsed-time threshold. It is useful for detecting unexpectedly slow database queries or external HTTP calls without instrumenting each function individually.

```lyric
// Config fields with their defaults:
// enabled:     Bool     = true
// thresholdMs: Int      = 1000
// alertLevel:  LogLevel = LogLevel.Warn
// loggerName:  String   = ""
```

The comparison is `call.elapsed.unwrapOr(0) > thresholdMs`. When the elapsed time exceeds the threshold, the aspect logs at `alertLevel` with the function's qualified name and the actual elapsed value. When under the threshold it emits nothing.

**`ErrorResultLogging`** (`@inline_template`, C-mode) logs when a function's return value is `Err(...)`. Because it needs to inspect the actual return value — not just timing metadata — it is a C-mode template that is recompiled in the consumer's package. It matches functions that return a `Result` type and emits at the configured level when the result is an error, including the error's string representation.

```lyric
// Config fields with their defaults:
// enabled:    Bool     = true
// level:      LogLevel = LogLevel.Error
// loggerName: String   = ""
```

All three templates default `loggerName` to the empty string, which causes the aspect to derive the logger name from `call.modulePath`. Override it in your instantiation's `config {}` block only when you want all matched functions to share a single named logger regardless of which module they live in.

## §22.6 Composing all three aspects

A realistic service instantiates all three templates together and relies on composition ordering to produce coherent output. Here is a checkout service that applies call logging, slow-call alerting, and error-result logging to every handler function:

```lyric
package MyApp.Checkout

import Std.Logging
import Std.Logging.Aspects

// Standard entry/exit logging at Debug level for all handlers.
aspect HandleCallLogging from Std.Logging.Aspects.CallLogging {
  matches:
    name like "handle*"

  config {
    level: Std.Logging.LogLevel = Std.Logging.LogLevel.Debug
  }
}

// Warn when any handler takes more than 500 ms.
aspect HandleSlowCallAlert from Std.Logging.Aspects.SlowCallAlert {
  matches:
    name like "handle*"

  config {
    thresholdMs: Int = 500
    alertLevel:  Std.Logging.LogLevel = Std.Logging.LogLevel.Warn
  }
}

// Log errors returned by any handler.
aspect HandleErrorResultLogging from Std.Logging.Aspects.ErrorResultLogging {
  matches:
    name like "handle*"

  config {
    level: Std.Logging.LogLevel = Std.Logging.LogLevel.Error
  }
}
```

With the default B-mode composition order (lexical declaration), `HandleCallLogging` wraps the outermost layer, `HandleSlowCallAlert` sits inside it, and `HandleErrorResultLogging` sits closest to the original function. The outermost advice records the full round-trip time including the slow-call check; the slow-call check sees the time after the function returns; the error check sees the return value before it is handed back to `HandleSlowCallAlert`.

If you need explicit ordering — for example if you add an `Auth` aspect from another library and need `Auth` to be outermost — use `wraps:` and `inside:` declarations (Chapter 21 §21.4):

```lyric
aspect HandleCallLogging from Std.Logging.Aspects.CallLogging {
  matches:
    name like "handle*"

  inside: Auth   // Auth is outside CallLogging

  config {
    level: Std.Logging.LogLevel = Std.Logging.LogLevel.Debug
  }
}
```

The three aspects, combined with a named logger in each handler for business-level events, give you a complete picture in your aggregator: every entry and exit, every slow call flagged, every error surfaced, and every significant business event tagged with structured fields.

A complete handler that uses both direct logging and benefits from the aspects:

```lyric
pub func handlePlaceOrder(req: PlaceOrderRequest): Result[OrderId, OrderError] {
  val log = Std.Logging.getLogger("MyApp.Checkout")

  Std.Logging.info(log, "processing order",
    [Std.Logging.field("customerId", req.customerId.toString()),
     Std.Logging.field("itemCount",  req.items.length.toString())])

  val result = OrderProcessor.submit(req)

  match result {
    Ok(id) ->
      Std.Logging.info(log, "order confirmed",
        [Std.Logging.field("orderId", id.toString())])
    Err(e) ->
      // ErrorResultLogging will also fire here via the aspect,
      // but an explicit log adds the request context.
      Std.Logging.warn(log, "order rejected",
        [Std.Logging.field("reason", e.toString())])
  }

  return result
}
```

The function body logs business events with structured fields. The three aspects, woven around it, handle the infrastructure concerns — entry, exit, elapsed time, slow-call threshold, and error propagation — without any code in the function body.

::: note
**Aspect weaver timing.** The aspect declarations above compile and type-check today. The woven execution — where the three `around` bodies actually wrap `handlePlaceOrder` at runtime — takes effect once the aspect weaver milestone ships. Until then, `handlePlaceOrder` runs unwrapped: the direct `Std.Logging` calls inside its body produce output, but the entry/exit/slow-call/error-result wrapping does not. No source changes are needed to activate the aspects when the weaver lands.
:::

## Exercises

1. Add `Std.Logging` to a project's `lyric.toml`, call `Std.Logging.getLogger("MyApp.Demo")`, and write one `info` and one `warn` call. Derive the two env-var names needed to switch the output to JSON and lower the level to `Debug`. What happens if you pass an empty string to `getLogger`?

2. Write a function `logRequestSummary` that accepts a `Logger`, a request path as a `String`, a status code as an `Int`, and an elapsed time in milliseconds as an `Int`. Use `Std.Logging.log` with three `field` values — `path`, `status`, and `elapsedMs` — at `Info` level. What does the output look like in `text` format? In `json` format?

3. Wrap a `Std.Logging.debug` call inside an `isEnabled` guard and inside a direct call without a guard. Explain when the guarded form matters and when the difference is negligible.

4. Instantiate `Std.Logging.Aspects.CallLogging` in a package against all functions whose names start with `fetch`. Override the `level` config default to `Std.Logging.LogLevel.Info`. What env-var name would you set to disable the aspect at deployment time without recompiling?

5. Declare all three aspect templates from §22.6 in a single package. Add a fourth aspect — `Auth` from a hypothetical `Std.Auth.Aspects` library — and use `wraps:` to place `Auth` outside all three logging aspects. Verify that the ordering declarations compile without a cycle error.

6. The `ErrorResultLogging` template is C-mode (`@inline_template`) while `CallLogging` and `SlowCallAlert` are B-mode. Explain in your own words why `ErrorResultLogging` requires C-mode while the other two do not. What capability does C-mode unlock, and what trade-off does it introduce compared to B-mode? (Consult Chapter 21 §21.7 if needed.)
