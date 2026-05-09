/// JVM OpenTelemetry extern boundary (Phase 6).
/// Wires Lyric's OTel wrapper functions to io.opentelemetry.api.trace.Tracer
/// (tracing) and io.opentelemetry.api.metrics.Meter (metrics).
///
/// Only active when compiled with feature = "jvm".
/// Marked @phase(6) — not compiled today; present to drive API design.
/// See docs/18-jvm-emission.md and docs/14-native-stdlib-plan.md.
@cfg(feature = "jvm")
package OTel.Kernel.Jvm

import OTel.Types

// ─── Tracing ─────────────────────────────────────────────────────────────────

@axiom("io.opentelemetry.api.trace")
extern package io.opentelemetry.api.trace {
  /// Start a new OTel span via the named Tracer.
  pub func jvmStartSpan(
    tracerName: String,
    operationName: String,
    kind: Int
  ): Span

  /// Record an exception attribute on the span and set error status.
  pub func jvmSetSpanError(span: Span, message: String): Unit

  /// End the span (records elapsed time via the OTel SDK).
  pub func jvmEndSpan(span: Span): Unit
}

// ─── Metrics ─────────────────────────────────────────────────────────────────

@axiom("io.opentelemetry.api.metrics")
extern package io.opentelemetry.api.metrics {
  /// Add `delta` to a named counter.
  pub func jvmIncrementCounter(
    meterName: String,
    counterName: String,
    delta: Int,
    unit: String
  ): Unit

  /// Record a histogram observation.
  pub func jvmRecordHistogram(
    meterName: String,
    histogramName: String,
    value: Float,
    unit: String
  ): Unit
}
