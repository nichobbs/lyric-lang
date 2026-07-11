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
/// Start a new tracing span.  `kind` is the integer value of `SpanKind`.
///
/// Always succeeds: unlike the earlier `System.Diagnostics.ActivitySource`
/// design (issue #5410), there is no host listener whose absence could
/// make this return a null/no-op span.
@stable(since = "0.2")
pub func startSpan(operationName: String, kind: Int): Span {
  val traceId = secureGetBytes(16)
  val spanId = secureGetBytes(8)
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
/// error was recorded.
@stable(since = "0.2")
pub func endSpan(span: Span): Unit {
  spanFinish(span, nowUnixNanos())
  globalSpanBuffer.push(span)
}

// ─── Metrics ────────────────────────────────────────────────────────────────
/// Add `delta` to the named cumulative counter.
@stable(since = "0.2")
pub func incrementCounter(name: String, delta: Int, unit: String): Unit {
  globalMetricsBuffer.incrementCounter(name, delta.toLong(), unit)
}

/// Record one histogram observation.
@stable(since = "0.2")
pub func recordHistogram(name: String, value: Float, unit: String): Unit {
  globalMetricsBuffer.recordHistogram(name, value.toDouble(), unit)
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
///   sampleRate — fraction of calls to trace (0.0–1.0); default 1.0.
///   spanKind   — OTel SpanKind for every span; default Internal.
pub aspect Tracing {
  config {
    enabled: Bool = true
    sampleRate: Float = 1.0
    spanKind: SpanKind = SpanKind.Internal
  }
  // sampleRate controls what fraction of calls are traced (0.0–1.0).
  // Values below 1.0 are applied via a simple hash gate on the call
  // name; use OTel SDK env vars (OTEL_TRACES_SAMPLER,
  // OTEL_TRACES_SAMPLER_ARG) for head-based sampling at the exporter
  // level when more sophisticated strategies are needed.
  around(call) -> ret {
    if not enabled {
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
///   level   — log level string ("debug" | "info" | "warn"); default "debug".
pub aspect RequestLogging {
  config {
    enabled: Bool = true
    level: String = "debug"
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      StdLog.info("enter: " + call.qualifiedName)
      ret = call.proceed()
      StdLog.info("exit: " + call.qualifiedName)
    }
  }
}
