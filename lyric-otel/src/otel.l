// Lyric OpenTelemetry library — platform-dispatch wrappers and pub aspect
// templates.
//
// Each wrapper function has two @cfg-gated implementations (dotnet / jvm)
// so the aspect templates remain platform-neutral.  Consumers bind a
// `matches:` selector and optionally override config defaults:
//
//   aspect HttpTracing from OTel.Tracing {
//     matches: name like "*/Http/*"
//     config {
//       spanKind: SpanKind = SpanKind.Server
//     }
//   }
//
// See docs/26-aspects.md §18 and docs/27-aspect-libraries.md.
package OTel

import OTel.Types
// Both kernel packages are imported unconditionally at the source level.
// Each package is gated by @cfg(feature = ...) in its own file, so the
// manifest resolver emits nothing for inactive features — the import
// resolves to an empty namespace and the @cfg-gated wrapper functions
// below provide the only bindings actually used at call sites.
import OTel.Kernel.Net
import OTel.Kernel.Jvm
import Std.Char
import Std.Log

// ─── Source / meter name used across all OTel emissions ──────────────────────

val sourceName: String = "lyric.otel"

// ─── Tracing wrappers ────────────────────────────────────────────────────────

/// Start a new tracing span.  `kind` is the integer value of `SpanKind`.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func startSpan(operationName: String, kind: Int): Span {
  netStartSpan(sourceName, operationName, kind)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func startSpan(operationName: String, kind: Int): Span {
  jvmStartSpan(sourceName, operationName, kind)
}

/// Record an error on the span (does not end it).
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func setSpanError(span: Span, message: String): Unit {
  netSetSpanError(span, message)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func setSpanError(span: Span, message: String): Unit {
  jvmSetSpanError(span, message)
}

/// Attach a string attribute to the span.  Call before endSpan.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func setSpanAttribute(span: Span, key: String, value: String): Unit {
  netSetSpanAttribute(span, key, value)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func setSpanAttribute(span: Span, key: String, value: String): Unit {
  jvmSetSpanAttribute(span, key, value)
}

/// End the span.  Must be called even when an error was recorded.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func endSpan(span: Span): Unit {
  netEndSpan(span)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func endSpan(span: Span): Unit {
  jvmEndSpan(span)
}

// ─── Metrics wrappers ────────────────────────────────────────────────────────

@stable(since="0.1")
@cfg(feature = "dotnet")
pub func incrementCounter(name: String, delta: Int, unit: String): Unit {
  netIncrementCounter(sourceName, name, delta, unit)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func incrementCounter(name: String, delta: Int, unit: String): Unit {
  jvmIncrementCounter(sourceName, name, delta, unit)
}

@stable(since="0.1")
@cfg(feature = "dotnet")
pub func recordHistogram(name: String, value: Float, unit: String): Unit {
  netRecordHistogram(sourceName, name, value, unit)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func recordHistogram(name: String, value: Float, unit: String): Unit {
  jvmRecordHistogram(sourceName, name, value, unit)
}

// ─── Aspect templates ────────────────────────────────────────────────────────

/// Wrap every matched call in an OTel trace span.
/// Config fields:
///   enabled    — gate the whole aspect at startup; default true.
///   sampleRate — fraction of calls to trace (0.0–1.0); default 1.0.
///   spanKind   — OTel SpanKind for every span; default Internal.
/// Map `SpanKind` to its OTel integer ordinal.
/// OTel SDK convention: Internal=0, Server=1, Client=2, Producer=3, Consumer=4.
func spanKindToInt(k: SpanKind): Int {
  match k {
    case SpanKind.Internal  -> 0
    case SpanKind.Server    -> 1
    case SpanKind.Client    -> 2
    case SpanKind.Producer  -> 3
    case SpanKind.Consumer  -> 4
  }
}

@stable(since="0.1")
pub aspect Tracing {
  config {
    enabled:    Bool      = true
    // sampleRate controls what fraction of calls are traced (0.0–1.0).
    // Values below 1.0 are applied via a simple hash gate on the call
    // name; use OTel SDK env vars (OTEL_TRACES_SAMPLER,
    // OTEL_TRACES_SAMPLER_ARG) for head-based sampling at the exporter
    // level when more sophisticated strategies are needed.
    sampleRate: Float     = 1.0
    spanKind:   SpanKind  = SpanKind.Internal
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      // Deterministic sampling: hash the call name to [0,1) and skip
      // the span when the hash exceeds sampleRate.
      var shouldTrace = true
      if sampleRate < 1.0 {
        // FNV-1a-style polynomial hash for better distribution across functions
        // sharing a long common prefix (e.g. all functions in a package).
        var hashSum = 0
        var hi = 0
        while hi < call.qualifiedName.length {
          hashSum = (hashSum * 31 + Std.Char.toInt(call.qualifiedName.charAt(hi))) % 1000
          hi = hi + 1
        }
        val hashFraction: Float = hashSum.toFloat() / 1000.0
        shouldTrace = hashFraction < sampleRate
      }
      if not shouldTrace {
        ret = call.proceed()
      } else {
        val span = startSpan(call.qualifiedName, spanKindToInt(spanKind))
        match call.proceed() {
          case Ok(v) -> {
            endSpan(span)
            ret = Ok(v)
          }
          case Err(e) -> {
            setSpanError(span, e.message)
            endSpan(span)
            ret = Err(e)
          }
        }
      }
    }
  }
}

/// Emit a call counter and a latency histogram for every matched call.
/// Config fields:
///   enabled — gate the whole aspect at startup; default true.
@stable(since="0.1")
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
      val elapsed = call.elapsed.unwrapOr(0)
      recordHistogram(call.qualifiedName + ".latency", elapsed.toFloat(), "ms")
    }
  }
}

/// Log entry / exit for every matched call at a configurable level.
/// Config fields:
///   enabled — gate the whole aspect; default true.
///   level   — log level string ("debug" | "info" | "warn"); default "debug".
@stable(since="0.1")
pub aspect RequestLogging {
  config {
    enabled: Bool   = true
    level:   String = "debug"
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      Std.Log.log(level, "enter: " + call.qualifiedName, [])
      ret = call.proceed()
      val elapsed = call.elapsed.unwrapOr(0)
      Std.Log.log(level, "exit: " + call.qualifiedName + " (" + elapsed.toString() + "ms)", [])
    }
  }
}
