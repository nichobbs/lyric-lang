/// Platform-neutral OpenTelemetry types shared across both kernels.
package OTel.Types

/// An active tracing span.  The representation is opaque; consumers
/// interact with it only through functions in `OTel`.
pub opaque type Span

/// OpenTelemetry span kind — maps to `SpanKind` on both .NET and JVM.
pub type SpanKind = enum {
  case Internal
  case Server
  case Client
  case Producer
  case Consumer
}

/// Unit annotation for metrics.
pub type MetricUnit = enum {
  case Dimensionless
  case Milliseconds
  case Bytes
  case Requests
}
