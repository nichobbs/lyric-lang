//! Pure-Lyric OTLP protobuf encoder — turns buffered `OTel.Types.Span` /
//! `CounterPoint` / `HistogramPoint` values into the exact wire bytes an
//! OTLP/HTTP collector's `/v1/traces` and `/v1/metrics` endpoints expect.
//!
//! Built on `lyric-proto` (`Proto.encodeMessage` and the `ProtoField`
//! union cases directly); no BCL dependency for the encoding itself
//! (the one BCL-backed exception — `HistogramDataPoint.sum`'s IEEE-754
//! bit pattern — is documented at its call site below).  Field numbers
//! are transcribed directly from the `opentelemetry-proto` v1 `.proto`
//! sources (not guessed, not copied from an intermediate description) —
//! see the tables below each message encoder.  Source:
//! `open-telemetry/opentelemetry-proto`,
//! `opentelemetry/proto/{trace,metrics,common,resource,collector/*}/v1/*.proto`.
//!
//! IMPORTANT — restored-dependency cross-assembly call bug: this file
//! calls `Proto.encodeMessage` and constructs `Proto.ProtoField` union
//! cases (`BytesField`/`VarField`/`Fix64Field`) directly, and
//! *deliberately avoids* `lyric-proto`'s convenience functions
//! (`stringField`, `embeddedField`, `enumField`, `boolField`,
//! `doubleField`, `doubleToInt64Bits`, `zigzag32`, `decodeMessage`,
//! `findVarint`/`findBytes`/`findFixed64`, …). lyric-otel is the first
//! real consumer of `lyric-proto` anywhere in the repo (no other
//! ecosystem library actually imports it despite some READMEs claiming
//! otherwise), and calling *almost any* `lyric-proto` function from a
//! different compiled assembly crashes the .NET JIT with
//! `System.InvalidProgramException` — reproduced even for trivial
//! non-generic functions like `zigzag32(n: Int): Long`. Only
//! `Proto.encodeMessage` and the raw `ProtoField` union-case
//! constructors were confirmed to survive the assembly boundary; this
//! looks like a bug in the self-hosted MSIL bridge's restored-package
//! (contract-metadata) symbol resolution, not anything specific to
//! protobuf. Tracked for a compiler-side fix; until then, every
//! `lyric-proto` call site in this file sticks to the confirmed-safe
//! subset. The wire bytes are byte-for-byte identical either way —
//! `stringField(n, b)` and `embeddedField(n, b)` are both just
//! `BytesField(number = n, data = b)` under the hood; `enumField`/
//! `boolField` are just `VarField` with an ordinal or 0/1.
package OTel.Otlp.Codec

import Std.Core
import Std.Collections
import Std.Encoding
import Proto
import OTel.Types
import OTel.Kernel.Net.Otlp as NetOtlp
import OTel.Kernel.Jvm.Otlp as JvmOtlp

// ─── Resource / instrumentation-scope identity ─────────────────────────────
// lyric-otel does not yet expose per-application resource-attribute
// configuration (see README "Known limitations"); every export carries
// the same fixed Resource/InstrumentationScope identity below.
val INSTRUMENTATION_SCOPE_NAME: String = "lyric-otel"

val INSTRUMENTATION_SCOPE_VERSION: String = "0.2.0"

val RESOURCE_SERVICE_NAME: String = "lyric.otel"

/// Map a Lyric `OTel.SpanKind` ordinal (`Internal`=0 .. `Consumer`=4,
/// `OTel.spanKindToInt`'s declaration order) to the OTLP wire
/// `Span.SpanKind` enum, which reserves 0 for `SPAN_KIND_UNSPECIFIED`
/// and shifts every real kind up by one:
///
///   Span.SpanKind          | wire value
///   -----------------------|-----------
///   SPAN_KIND_UNSPECIFIED  | 0
///   SPAN_KIND_INTERNAL     | 1  (Lyric Internal = 0)
///   SPAN_KIND_SERVER       | 2  (Lyric Server   = 1)
///   SPAN_KIND_CLIENT       | 3  (Lyric Client   = 2)
///   SPAN_KIND_PRODUCER     | 4  (Lyric Producer = 3)
///   SPAN_KIND_CONSUMER     | 5  (Lyric Consumer = 4)
@stable(since = "0.2")
pub func kindToOtlpWire(kind: in Int): Int {
  kind + 1
}

// Bytes field helper — length-delimited (wire type 2), the shared shape
// behind proto3 string/bytes/embedded-message fields.  Equivalent to
// `lyric-proto`'s own `stringField`/`embeddedField`, reimplemented here
// via the raw union constructor to stay inside the confirmed-safe
// cross-assembly subset (see module doc).
func bytesField(number: in Int, data: in slice[Byte]): ProtoField {
  BytesField(number = number, data = data)
}

// Varint field helper (wire type 0) for a non-negative small ordinal —
// covers both proto3 `enum` fields and `bool` fields (0/1), equivalent
// to `lyric-proto`'s `enumField`/`boolField`.
func varintField(number: in Int, v: in Int): ProtoField {
  VarField(number = number, v = v.toLong())
}

// ═══════════════════════════════════════════════════════════════════════════
// ─── common/v1/common.proto ─────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════
// AnyValue:  string_value = 1
// KeyValue:  key = 1 (string), value = 2 (AnyValue)
/// Encode a string-valued `AnyValue` (`{ string_value = 1 }`).
@stable(since = "0.2")
pub func encodeAnyValueString(value: in String): slice[Byte] {
  encodeMessage([bytesField(1, encodeUtf8(value))])
}

/// Encode a `KeyValue { key = 1, value = 2 }` with a string `AnyValue`.
@stable(since = "0.2")
pub func encodeKeyValue(key: in String, value: in String): slice[Byte] {
  encodeMessage([bytesField(1, encodeUtf8(key)), bytesField(2, encodeAnyValueString(value))])
}

// InstrumentationScope: name = 1, version = 2
func encodeInstrumentationScope(): slice[Byte] {
  encodeMessage(
    [bytesField(1, encodeUtf8(INSTRUMENTATION_SCOPE_NAME)), bytesField(2, encodeUtf8(INSTRUMENTATION_SCOPE_VERSION))]
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// ─── resource/v1/resource.proto ─────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════
// Resource: attributes = 1 (repeated KeyValue)
func encodeResource(): slice[Byte] {
  encodeMessage([bytesField(1, encodeKeyValue("service.name", RESOURCE_SERVICE_NAME))])
}

// ═══════════════════════════════════════════════════════════════════════════
// ─── trace/v1/trace.proto ───────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════
// Status:               message = 2, code = 3
// Status.StatusCode:    STATUS_CODE_ERROR = 2
/// Encode a `Status { message = 2, code = STATUS_CODE_ERROR(2) }`.
@stable(since = "0.2")
pub func encodeStatusError(message: in String): slice[Byte] {
  encodeMessage([bytesField(2, encodeUtf8(message)), varintField(3, 2)])
}

// Span:
//   trace_id = 1, span_id = 2, name = 5, kind = 6,
//   start_time_unix_nano = 7, end_time_unix_nano = 8,
//   attributes = 9 (repeated KeyValue), status = 15
// (trace_state=3, parent_span_id=4, dropped_attributes_count=10,
//  events=11/dropped_events_count=12, links=13/dropped_links_count=14,
//  flags=16 are all omitted: proto3 default-value fields need not be
//  sent, and lyric-otel does not yet populate any of them.)
/// Encode one `Span` message.  Exposed `pub` so tests can assert its
/// exact wire bytes for a span built with fixed IDs/timestamps.
@stable(since = "0.2")
pub func encodeSpanMessage(s: in Span): slice[Byte] {
  var fields: List[ProtoField] = newList()
  fields.add(BytesField(number = 1, data = spanTraceId(s)))
  fields.add(BytesField(number = 2, data = spanSpanId(s)))
  fields.add(bytesField(5, encodeUtf8(spanName(s))))
  fields.add(varintField(6, kindToOtlpWire(spanKind(s))))
  fields.add(Fix64Field(number = 7, bits = spanStartNanos(s)))
  fields.add(Fix64Field(number = 8, bits = spanEndNanos(s)))
  val attrs = spanAttributes(s).toArray()
  for a in attrs {
    fields.add(bytesField(9, encodeKeyValue(a.key, a.value)))
  }
  match spanErrorMessage(s) {
    case Some(msg) -> fields.add(bytesField(15, encodeStatusError(msg)))
    case None -> {
    }
  }
  encodeMessage(fields)
}

// ScopeSpans:     scope = 1, spans = 2 (repeated Span)
// ResourceSpans:  resource = 1, scope_spans = 2 (repeated ScopeSpans)
// ExportTraceServiceRequest (collector/trace/v1/trace_service.proto):
//   resource_spans = 1 (repeated ResourceSpans)
// TracesData has the identical single field `resource_spans = 1`, so
// there is no separate encoder for it — the bytes are the same shape.
/// Encode a complete `ExportTraceServiceRequest` for one process-wide
/// resource/scope wrapping every buffered span.
@stable(since = "0.2")
pub func encodeExportTraceServiceRequest(spans: in List[Span]): slice[Byte] {
  var scopeSpansFields: List[ProtoField] = newList()
  scopeSpansFields.add(bytesField(1, encodeInstrumentationScope()))
  val arr = spans.toArray()
  for s in arr {
    scopeSpansFields.add(bytesField(2, encodeSpanMessage(s)))
  }
  val scopeSpansMsg = encodeMessage(scopeSpansFields)
  val resourceSpansMsg = encodeMessage([bytesField(1, encodeResource()), bytesField(2, scopeSpansMsg)])
  encodeMessage([bytesField(1, resourceSpansMsg)])
}

// ═══════════════════════════════════════════════════════════════════════════
// ─── metrics/v1/metrics.proto ───────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════
// NumberDataPoint:  time_unix_nano = 3, as_int = 6 (sfixed64, oneof value)
// Sum:              data_points = 1, aggregation_temporality = 2, is_monotonic = 3
// Metric:           name = 1, unit = 3, sum = 7 (oneof data)
// AggregationTemporality: AGGREGATION_TEMPORALITY_CUMULATIVE = 2
val AGGREGATION_TEMPORALITY_CUMULATIVE: Int = 2

/// Encode a `NumberDataPoint { time_unix_nano = 3, as_int = 6 }`.
@stable(since = "0.2")
pub func encodeNumberDataPointInt(value: in Long, timeNanos: in Long): slice[Byte] {
  encodeMessage([Fix64Field(number = 3, bits = timeNanos), Fix64Field(number = 6, bits = value)])
}

/// Encode a cumulative monotonic-counter `Metric { name, unit, sum }`.
@stable(since = "0.2")
pub func encodeSumMetric(name: in String, unit: in String, total: in Long, timeNanos: in Long): slice[Byte] {
  val dp = encodeNumberDataPointInt(total, timeNanos)
  val sum = encodeMessage([bytesField(1, dp), varintField(2, AGGREGATION_TEMPORALITY_CUMULATIVE), varintField(3, 1)])
  encodeMessage([bytesField(1, encodeUtf8(name)), bytesField(3, encodeUtf8(unit)), bytesField(7, sum)])
}

// HistogramDataPoint: time_unix_nano = 3, count = 4 (fixed64), sum = 5
//                      (double/fixed64), bucket_counts = 6 (repeated fixed64)
// Histogram:           data_points = 1, aggregation_temporality = 2
// Metric:              histogram = 9 (oneof data)
//
// No `explicit_bounds` (field 7) is sent, so `bucket_counts` (field 6)
// must carry exactly one entry — the total `count` — per the proto spec's
// `len(bucket_counts) == len(explicit_bounds) + 1` invariant.  This
// yields a single implicit bucket spanning the whole real line: valid,
// but no percentile histogram — see README "Known limitations".
@cfg(feature = "dotnet")
func doubleBits(v: in Double): Long {
  NetOtlp.netDoubleToInt64Bits(v)
}

@cfg(feature = "jvm")
func doubleBits(v: in Double): Long {
  JvmOtlp.jvmDoubleToInt64Bits(v)
}

/// Encode a `HistogramDataPoint { time_unix_nano, count, sum, bucket_counts=[count] }`.
@stable(since = "0.2")
pub func encodeHistogramDataPoint(count: in Long, sumValue: in Double, timeNanos: in Long): slice[Byte] {
  encodeMessage(
    [
      Fix64Field(number = 3, bits = timeNanos),
      Fix64Field(number = 4, bits = count),
      Fix64Field(number = 5, bits = doubleBits(sumValue)),
      Fix64Field(number = 6, bits = count)
    ]
  )
}

/// Encode a cumulative `Metric { name, unit, histogram }`.
@stable(since = "0.2")
pub func encodeHistogramMetric(
  name: in String, unit: in String, count: in Long, sumValue: in Double, timeNanos: in Long
): slice[Byte] {
  val dp = encodeHistogramDataPoint(count, sumValue, timeNanos)
  val hist = encodeMessage([bytesField(1, dp), varintField(2, AGGREGATION_TEMPORALITY_CUMULATIVE)])
  encodeMessage([bytesField(1, encodeUtf8(name)), bytesField(3, encodeUtf8(unit)), bytesField(9, hist)])
}

// ScopeMetrics:    scope = 1, metrics = 2 (repeated Metric)
// ResourceMetrics: resource = 1, scope_metrics = 2 (repeated ScopeMetrics)
// ExportMetricsServiceRequest (collector/metrics/v1/metrics_service.proto):
//   resource_metrics = 1 (repeated ResourceMetrics)
/// Encode a complete `ExportMetricsServiceRequest` wrapping every
/// already-encoded `Metric` message (build each with `encodeSumMetric` /
/// `encodeHistogramMetric` first).
@stable(since = "0.2")
pub func encodeExportMetricsServiceRequest(metricMessages: in List[slice[Byte]]): slice[Byte] {
  var scopeMetricsFields: List[ProtoField] = newList()
  scopeMetricsFields.add(bytesField(1, encodeInstrumentationScope()))
  val arr = metricMessages.toArray()
  for m in arr {
    scopeMetricsFields.add(bytesField(2, m))
  }
  val scopeMetricsMsg = encodeMessage(scopeMetricsFields)
  val resourceMetricsMsg = encodeMessage([bytesField(1, encodeResource()), bytesField(2, scopeMetricsMsg)])
  encodeMessage([bytesField(1, resourceMetricsMsg)])
}
