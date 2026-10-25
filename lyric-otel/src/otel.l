//! Lyric OpenTelemetry library — span/metric recording API and pub aspect
//! templates.
//! Stability: @experimental. Span/metric recording (this file) is
//! platform-neutral pure Lyric; OTLP/HTTP export (`OTel.Otlp`) is
//! implemented for the `dotnet` target (see `docs/03-decision-log.md`
//! issue #5410) and honestly not-implemented on `jvm`.
//!
//! Consumers bind a `matches:` selector and optionally override config
//! defaults:
//!
//!   aspect HttpTracing from OTel.Tracing {
//!     matches: name like "*/Http/*"
//!     config {
//!       spanKind: SpanKind = SpanKind.Server
//!     }
//!   }
//!
//! See docs/26-aspects.md §18 and docs/27-aspect-libraries.md.
@io
package OTel

import OTel.Types
import Std.Core
import Std.SecureRandom
import Std.Log as StdLog

// ─── OTel enum types (must be in same package for pattern matching) ───────────
/// OpenTelemetry span kind.  Declaration order is the ordinal `startSpan`'s
/// `kind: Int` expects (`Internal`=0 .. `Consumer`=4); `OTel.Otlp.Codec`
/// maps these onto the OTLP wire `Span.SpanKind` enum, which reserves 0
/// for "unspecified" and so is offset by one.
pub enum SpanKind {
  case Internal
  case Server
  case Client
  case Producer
  case Consumer
}

/// Unit annotation for metrics.
pub enum MetricUnit {
  case Dimensionless
  case Milliseconds
  case Bytes
  case Requests
}

// ─── Tracing ─────────────────────────────────────────────────────────────────
/// Random bytes with at least one non-zero byte, as W3C Trace Context requires
/// of trace and span ids (an all-zero draw has probability 2^-64 or less, so
/// the retry loop effectively never repeats).
func nonZeroRandomBytes(count: in Int): slice[Byte] {
  var bytes = secureGetBytes(count)
  while not hasNonZeroByte(bytes) {
    bytes = secureGetBytes(count)
  }
  bytes
}

/// Start a new tracing span.  `kind` is the integer value of `SpanKind`.
///
/// Always succeeds: unlike the earlier `System.Diagnostics.ActivitySource`
/// design (issue #5410), there is no host listener whose absence could
/// make this return a null/no-op span.
@stable(since = "0.2")
pub func startSpan(operationName: String, kind: Int): Span
  requires: kind >= 0 and kind <= 4
{
  val traceId = nonZeroRandomBytes(16)
  val spanId = nonZeroRandomBytes(8)
  newSpanRecord(traceId, spanId, operationName, kind, nowUnixNanos())
}

/// Record an error on the span (does not end it).
@stable(since = "0.2")
pub func setSpanError(span: Span, message: String): Unit {
  spanSetError(span, message)
}

/// Attach a string attribute to the span.  Call before endSpan.
@stable(since = "0.2")
pub func setSpanAttribute(span: Span, key: String, value: String): Unit {
  spanAddAttribute(span, key, value)
}

/// End the span: stamps the end timestamp and enqueues it for OTLP
/// export via `OTel.Otlp.flushOtlpAsync`.  Must be called even when an
/// error was recorded.  Ending a span that has already ended is a no-op, so a
/// span is never exported twice.
@stable(since = "0.2")
pub func endSpan(span: Span): Unit {
  if spanMarkEnded(span) {
    spanFinish(span, nowUnixNanos())
    globalSpanBuffer.push(span)
  }
}

// ─── Metrics ────────────────────────────────────────────────────────────────
/// Add `delta` to the named cumulative counter.  A counter only grows, so a
/// negative `delta` is ignored rather than corrupting the running total (and
/// telemetry must not take the service down over a bad number).
@stable(since = "0.2")
pub func incrementCounter(name: String, delta: Int, unit: String): Unit {
  if delta >= 0 {
    globalMetricsBuffer.incrementCounter(name, delta.toLong(), unit)
  }
}

/// Record one histogram observation.  A NaN or infinite `value` is ignored:
/// either one would poison the histogram's `sum` for the life of the process.
@stable(since = "0.2")
pub func recordHistogram(name: String, value: Double, unit: String): Unit {
  if value - value == 0.0 {
    globalMetricsBuffer.recordHistogram(name, value, unit)
  }
}

// ─── Sampling and log levels ────────────────────────────────────────────────
/// Head-based sampling decision: a draw `unit` in `[0, 1)` is sampled when it
/// is below `rate`, so `rate` 1.0 samples everything and 0.0 nothing.
@stable(since = "0.2")
pub func shouldSample(rate: Float, unit: Float): Bool {
  unit < rate
}

/// A uniform draw in `[0, 1)` from the secure random source (24 bits).
func randomUnit(): Float {
  val b = secureGetBytes(3)
  val n = b[0].toInt() * 65536 + b[1].toInt() * 256 + b[2].toInt()
  n.toFloat() / 16777216.0
}

/// Map a `RequestLogging.level` string onto a log level.  `"debug"`, `"info"`
/// and `"warn"` are the documented values; anything else logs at `Info`.
@stable(since = "0.2")
pub func logLevelFor(level: String): StdLog.LogLevel {
  match level {
    case "debug" -> StdLog.LogLevel.Debug
    case "warn" -> StdLog.LogLevel.Warn
    case _ -> StdLog.LogLevel.Info
  }
}

// ─── Aspect templates ────────────────────────────────────────────────────────
/// Map `SpanKind` to its ordinal (also its OTel-wire-mappable value —
/// see `OTel.Otlp.Codec.kindToOtlpWire`).
func spanKindToInt(k: SpanKind): Int {
  match k {
    case SpanKind.Internal -> 0
    case SpanKind.Server -> 1
    case SpanKind.Client -> 2
    case SpanKind.Producer -> 3
    case SpanKind.Consumer -> 4
  }
}

/// Wrap every matched call in an OTel trace span.
/// Config fields:
///   enabled    — gate the whole aspect at startup; default true.
///   sampleRate — probability that a call is traced, 0.0..=1.0; default 1.0.
///   spanKind   — OTel SpanKind for every span; default Internal.
pub aspect Tracing {
  config {
    enabled: Bool = true
    sampleRate: Float range 0.0 ..= 1.0 = 1.0
    spanKind: SpanKind = SpanKind.Internal
  }
  // sampleRate is the probability that a call is traced: each call draws
  // independently, so 0.5 traces about half of them and 0.0 none.  An
  // unsampled call runs untraced.
  around(call) -> ret {
    if not enabled or (sampleRate < 1.0 and not shouldSample(sampleRate, randomUnit())) {
      ret = call.proceed()
    } else {
      val span = startSpan(call.qualifiedName, spanKindToInt(spanKind))
      ret = call.proceed()
      endSpan(span)
    }
  }
}

/// Emit a call counter and a latency histogram for every matched call.
/// Config fields:
///   enabled — gate the whole aspect at startup; default true.
pub aspect Metrics {
  config {
    enabled: Bool = true
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      incrementCounter(call.qualifiedName, 1, "requests")
      ret = call.proceed()
    }
  }
}

/// Log entry / exit for every matched call at a configurable level.
/// Config fields:
///   enabled — gate the whole aspect; default true.
///   level   — log level string ("debug" | "info" | "warn"; anything else logs
///             at info); default "debug".
pub aspect RequestLogging {
  config {
    enabled: Bool = true
    level: String = "debug"
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val lvl = logLevelFor(level)
      StdLog.log(lvl, "enter: " + call.qualifiedName, [])
      ret = call.proceed()
      StdLog.log(lvl, "exit: " + call.qualifiedName, [])
    }
  }
}
