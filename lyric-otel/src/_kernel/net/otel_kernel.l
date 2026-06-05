//! .NET OpenTelemetry extern boundary.
//! Wires Lyric's OTel wrapper functions to System.Diagnostics.ActivitySource
//! (tracing) and System.Diagnostics.Metrics.Meter (metrics).
//!
//! Only active when compiled with feature = "dotnet".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
package OTel.Kernel.Net

import OTel.Types

// ─── Tracing ─────────────────────────────────────────────────────────────────
@axiom("System.Diagnostics")
extern package System.Diagnostics {
  /// Start a new Activity (OTel span) under the given source name.
  /// Returns an opaque span handle; callers must pass it to
  /// `netEndSpan` regardless of outcome.
  pub func netStartSpan(sourceName: String, operationName: String, kind: Int): Span

  /// Record an exception on the span and mark it as failed, then stop it.
  pub func netSetSpanError(span: Span, message: String): Unit

  /// Attach a string tag to the span via Activity.SetTag.
  pub func netSetSpanAttribute(span: Span, key: String, value: String): Unit

  /// Stop the span and record elapsed time.
  pub func netEndSpan(span: Span): Unit
  // ─── Metrics ─────────────────────────────────────────────────────────────────
}

@axiom("System.Diagnostics.Metrics")
extern package System.Diagnostics.Metrics {
  /// Increment a named counter by `delta` (default 1).
  pub func netIncrementCounter(meterName: String, counterName: String, delta: Int, unit: String): Unit

  /// Record a histogram observation.
  pub func netRecordHistogram(meterName: String, histogramName: String, value: Float, unit: String): Unit
}
