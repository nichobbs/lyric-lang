//! tests/otel_types_tests.l — tests for the pure-Lyric surface of lyric-otel.
//!
//! Covers SpanKind and MetricUnit enum matching.
//! Span is opaque and cannot be constructed directly; tracing, metrics, and
//! logging functions require the OTel SDK and are not exercised here.
@test_module
package OTel.OTelTypesTests

import Std.Core
import Std.Testing
import OTel.Types

// ─── SpanKind ─────────────────────────────────────────────────────────────────
test "SpanKind.Internal: can be matched" {
  val k = SpanKind.Internal
  match k {
    case SpanKind.Internal -> ()
    case _ -> assertTrue(false, "expected Internal")
  }
}

test "SpanKind.Server: can be matched" {
  val k = SpanKind.Server
  match k {
    case SpanKind.Server -> ()
    case _ -> assertTrue(false, "expected Server")
  }
}

test "SpanKind.Client: can be matched" {
  val k = SpanKind.Client
  match k {
    case SpanKind.Client -> ()
    case _ -> assertTrue(false, "expected Client")
  }
}

test "SpanKind.Producer: can be matched" {
  val k = SpanKind.Producer
  match k {
    case SpanKind.Producer -> ()
    case _ -> assertTrue(false, "expected Producer")
  }
}

test "SpanKind.Consumer: can be matched" {
  val k = SpanKind.Consumer
  match k {
    case SpanKind.Consumer -> ()
    case _ -> assertTrue(false, "expected Consumer")
  }
}

// ─── MetricUnit ───────────────────────────────────────────────────────────────
test "MetricUnit.Dimensionless: can be matched" {
  val u = MetricUnit.Dimensionless
  match u {
    case MetricUnit.Dimensionless -> ()
    case _ -> assertTrue(false, "expected Dimensionless")
  }
}

test "MetricUnit.Milliseconds: can be matched" {
  val u = MetricUnit.Milliseconds
  match u {
    case MetricUnit.Milliseconds -> ()
    case _ -> assertTrue(false, "expected Milliseconds")
  }
}

test "MetricUnit.Bytes: can be matched" {
  val u = MetricUnit.Bytes
  match u {
    case MetricUnit.Bytes -> ()
    case _ -> assertTrue(false, "expected Bytes")
  }
}

test "MetricUnit.Requests: can be matched" {
  val u = MetricUnit.Requests
  match u {
    case MetricUnit.Requests -> ()
    case _ -> assertTrue(false, "expected Requests")
  }
}
