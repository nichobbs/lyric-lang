/// Platform-neutral OpenTelemetry types shared across both kernels.
package OTel.Types

/// An active tracing span.  The representation is opaque; consumers
/// interact with it only through functions in `OTel`.
@stable(since="0.1")
pub opaque type Span

/// OpenTelemetry span kind — maps to `SpanKind` on both .NET and JVM.
@stable(since="0.1")
pub type SpanKind = enum {
  case Internal
  case Server
  case Client
  case Producer
  case Consumer
}

/// Unit annotation for metrics.
@stable(since="0.1")
pub type MetricUnit = enum {
  case Dimensionless
  case Milliseconds
  case Bytes
  case Requests
}
