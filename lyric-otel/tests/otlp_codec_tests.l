//! tests/otlp_codec_tests.l — byte-level tests for lyric-otel's OTLP
//! protobuf encoder (issue #5410).
//!
//! Every message here is asserted against exact, hand-computed wire
//! bytes, following the varint / tag / length-delimited rules
//! `lyric-proto`'s own test suite uses
//! (`lyric-proto/tests/proto_types_tests.l`) — including the deeply
//! nested `Export*ServiceRequest` wrappers, which peel their layers
//! apart with a small local wire-type-2 parser (`readWireType2Field`
//! below) rather than `Proto.decodeMessage`.
//!
//! That's a deliberate departure from the original design: calling
//! almost any `lyric-proto` function from a *different compiled
//! assembly* (this test's, or `otlp_codec.l`'s) crashes the .NET JIT
//! with `System.InvalidProgramException` — reproduced even for the
//! simplest non-generic functions (`zigzag32`), not just `decodeMessage`/
//! `findVarint`/`findBytes`/`findFixed64`/`collectBytes`. Only
//! `Proto.encodeMessage` and the raw `ProtoField` union-case
//! constructors survive the assembly boundary — see `otlp_codec.l`'s
//! module doc for the full story (this is a self-hosted compiler bug in
//! restored-dependency symbol resolution, not a `lyric-proto` or
//! `lyric-otel` semantic issue). This file therefore never imports
//! `Proto` at all: every assertion here is either an exact byte-array
//! comparison or a decode performed by the local parser below.
@test_module
package OTel.OtlpCodecTests

import Std.Core
import Std.Testing
import Std.Encoding
import OTel.Types
import OTel.Otlp.Codec

// ─── Local test helpers ───────────────────────────────────────────────────────
func bytesEqual(a: in slice[Byte], b: in slice[Byte]): Bool {
  if a.length != b.length {
    return false
  }
  var i = 0
  while i < a.length {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

// Minimal local varint reader (tag/length only), reimplemented here —
// not imported from `lyric-proto` — for the reason explained in the
// module doc above. Returns (value, nextOffset).
func readVarintLocal(data: in slice[Byte], offset: in Int): (Long, Int) {
  var result = 0i64
  var shift = 0
  var pos = offset
  var more = true
  while more {
    val b = data[pos].toInt()
    pos = pos + 1
    result = result.or(b.and(127).toLong().shl(shift))
    shift = shift + 7
    if b.and(128) == 0 {
      more = false
    }
  };
  (result, pos)
}

// Reads one wire-type-2 (length-delimited) field starting at `offset`.
// Every wrapper message this encoder produces (Resource, ScopeSpans,
// ResourceSpans, ExportTraceServiceRequest, and the metrics
// equivalents) only ever contains embedded-message fields, so this is
// sufficient to peel apart every nesting level under test. Returns
// (fieldNumber, payload, nextOffset); panics on any other wire type.
func readWireType2Field(data: in slice[Byte], offset: in Int): (Int, slice[Byte], Int) {
  val (tag, afterTag) = readVarintLocal(data, offset)
  val fieldNum = (tag.shr(3)).toInt()
  val wireType = (tag.and(7i64)).toInt()
  if wireType != 2 {
    panic(
      "readWireType2Field: expected wire type 2 (length-delimited), got " + wireType.toString() + " at offset " +
        offset.toString()
    )
  }
  val (lenL, afterLen) = readVarintLocal(data, afterTag)
  val len = lenL.toInt()
  var payload: List[Byte] = newList()
  var i = 0
  while i < len {
    payload.add(data[afterLen + i])
    i = i + 1
  };
  (fieldNum, payload.toArray(), afterLen + len)
}

// ─── kindToOtlpWire ────────────────────────────────────────────────────────────
test "kindToOtlpWire offsets every Lyric SpanKind ordinal by one" {
  assertEqualInt(kindToOtlpWire(0), 1, "Internal -> SPAN_KIND_INTERNAL")
  assertEqualInt(kindToOtlpWire(1), 2, "Server -> SPAN_KIND_SERVER")
  assertEqualInt(kindToOtlpWire(2), 3, "Client -> SPAN_KIND_CLIENT")
  assertEqualInt(kindToOtlpWire(3), 4, "Producer -> SPAN_KIND_PRODUCER")
  assertEqualInt(kindToOtlpWire(4), 5, "Consumer -> SPAN_KIND_CONSUMER")
}

// ─── KeyValue / AnyValue (common/v1/common.proto) ─────────────────────────────
// AnyValue{string_value=1}("v"): tag(1<<3|2=10),len(1),'v'(118) = 3 bytes.
// KeyValue{key=1,value=2}("k","v"):
//   key field:   tag(1<<3|2=10),len(1),'k'(107)                = 3 bytes
//   value field: tag(2<<3|2=18),len(3),<AnyValue bytes above>  = 5 bytes
test "encodeKeyValue emits the exact wire bytes for a string attribute" {
  val bytes = encodeKeyValue("k", "v")
  val expected: slice[Byte] = [10u8, 1u8, 107u8, 18u8, 3u8, 10u8, 1u8, 118u8]
  assertEqualInt(bytes.length, 8, "KeyValue(\"k\",\"v\") is 8 bytes")
  assertTrue(bytesEqual(bytes, expected), "KeyValue(\"k\",\"v\") exact bytes")
}

// ─── Status (trace/v1/trace.proto) ─────────────────────────────────────────────
// Status{message=2,code=3}("boom", STATUS_CODE_ERROR=2):
//   message field: tag(2<<3|2=18),len(4),"boom"(98,111,111,109) = 6 bytes
//   code field:    tag(3<<3|0=24),varint(2)                     = 2 bytes
test "encodeStatusError emits the exact wire bytes for an error status" {
  val bytes = encodeStatusError("boom")
  val expected: slice[Byte] = [18u8, 4u8, 98u8, 111u8, 111u8, 109u8, 24u8, 2u8]
  assertEqualInt(bytes.length, 8, "Status(\"boom\") is 8 bytes")
  assertTrue(bytesEqual(bytes, expected), "Status(\"boom\") exact bytes")
}

// ─── Span (trace/v1/trace.proto) ───────────────────────────────────────────────
// A span with 16-byte trace id [1..16], 8-byte span id [1..8], name "op",
// kind=1 (Server) -> wire 2, start=1000ns, end=2000ns, no attributes, no
// error.  Field-by-field (see otlp_codec.l's field-number comment table):
//   trace_id (1, bytes):  tag=10,  len=16, <16 bytes>            = 18 bytes
//   span_id  (2, bytes):  tag=18,  len=8,  <8 bytes>             = 10 bytes
//   name     (5, string): tag=42,  len=2,  'o'(111) 'p'(112)     = 4 bytes
//   kind     (6, varint): tag=48,  2                             = 2 bytes
//   start    (7, fixed64):tag=57,  LE(1000)=E8,03,00,00,00,00,00,00 = 9 bytes
//   end      (8, fixed64):tag=65,  LE(2000)=D0,07,00,00,00,00,00,00 = 9 bytes
// Total = 18+10+4+2+9+9 = 52 bytes.
test "encodeSpanMessage emits the exact wire bytes for a known span" {
  val traceId: slice[Byte] = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8, 9u8, 10u8, 11u8, 12u8, 13u8, 14u8, 15u8, 16u8]
  val spanId: slice[Byte] = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8]
  val span = newSpanRecord(traceId, spanId, "op", 1, 1000i64)
  spanFinish(span, 2000i64)
  val bytes = encodeSpanMessage(span)
  val expected: slice[Byte] = [
    10u8,
    16u8,
    1u8,
    2u8,
    3u8,
    4u8,
    5u8,
    6u8,
    7u8,
    8u8,
    9u8,
    10u8,
    11u8,
    12u8,
    13u8,
    14u8,
    15u8,
    16u8,
    18u8,
    8u8,
    1u8,
    2u8,
    3u8,
    4u8,
    5u8,
    6u8,
    7u8,
    8u8,
    42u8,
    2u8,
    111u8,
    112u8,
    48u8,
    2u8,
    57u8,
    232u8,
    3u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    65u8,
    208u8,
    7u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8
  ]
  assertEqualInt(bytes.length, 52, "minimal span message is 52 bytes")
  assertTrue(bytesEqual(bytes, expected), "minimal span message exact bytes")
}

// Same span, plus one attribute ("k","v") and an error ("boom").
// Attribute field (9, embedded KeyValue, 8 bytes from the KeyValue test
// above): tag=(9<<3|2)=74, len=8, <8 bytes>                   = 10 bytes
// Status field (15, embedded Status, 8 bytes from the Status test
// above):    tag=(15<<3|2)=122, len=8, <8 bytes>              = 10 bytes
// Total = 52 (base) + 10 (attribute) + 10 (status) = 72 bytes.
test "encodeSpanMessage emits exact wire bytes for a span with an attribute and an error" {
  val traceId: slice[Byte] = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8, 9u8, 10u8, 11u8, 12u8, 13u8, 14u8, 15u8, 16u8]
  val spanId: slice[Byte] = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8]
  val span = newSpanRecord(traceId, spanId, "op", 1, 1000i64)
  spanAddAttribute(span, "k", "v")
  spanSetError(span, "boom")
  spanFinish(span, 2000i64)
  val bytes = encodeSpanMessage(span)
  val expected: slice[Byte] = [
    10u8,
    16u8,
    1u8,
    2u8,
    3u8,
    4u8,
    5u8,
    6u8,
    7u8,
    8u8,
    9u8,
    10u8,
    11u8,
    12u8,
    13u8,
    14u8,
    15u8,
    16u8,
    18u8,
    8u8,
    1u8,
    2u8,
    3u8,
    4u8,
    5u8,
    6u8,
    7u8,
    8u8,
    42u8,
    2u8,
    111u8,
    112u8,
    48u8,
    2u8,
    57u8,
    232u8,
    3u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    65u8,
    208u8,
    7u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    74u8,
    8u8,
    10u8,
    1u8,
    107u8,
    18u8,
    3u8,
    10u8,
    1u8,
    118u8,
    122u8,
    8u8,
    18u8,
    4u8,
    98u8,
    111u8,
    111u8,
    109u8,
    24u8,
    2u8
  ]
  assertEqualInt(bytes.length, 72, "span with attribute + error is 72 bytes")
  assertTrue(bytesEqual(bytes, expected), "span with attribute + error exact bytes")
}

// ─── NumberDataPoint (metrics/v1/metrics.proto) ────────────────────────────────
// NumberDataPoint{time_unix_nano=3,as_int=6}(timeNanos=1000, value=7):
//   time field:  tag=(3<<3|1=25), LE(1000)=E8,03,00,00,00,00,00,00 = 9 bytes
//   as_int field:tag=(6<<3|1=49), LE(7)   =07,00,00,00,00,00,00,00 = 9 bytes
test "encodeNumberDataPointInt emits the exact wire bytes" {
  val bytes = encodeNumberDataPointInt(7i64, 1000i64)
  val expected: slice[Byte] = [
    25u8,
    232u8,
    3u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    49u8,
    7u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8
  ]
  assertEqualInt(bytes.length, 18, "NumberDataPoint is 18 bytes")
  assertTrue(bytesEqual(bytes, expected), "NumberDataPoint exact bytes")
}

// ─── Sum metric ("ctr","u",total=7,time=1000) ──────────────────────────────────
// NumberDataPoint (18 bytes, from the test above): tag=57(time)... — reused
// inline here rather than called, to keep this test self-contained.
//   dp = [25,232,3,0,0,0,0,0,0, 49,7,0,0,0,0,0,0,0]                (18 bytes)
// Sum{data_points=1,aggregation_temporality=2,is_monotonic=3}:
//   dp field:          tag=10, len=18, <dp>                        = 20 bytes
//   temporality field: tag=16, varint(2)  [CUMULATIVE]             =  2 bytes
//   monotonic field:   tag=24, varint(1)  [true]                   =  2 bytes
//   sum = 24 bytes
// Metric{name=1,unit=3,sum=7}("ctr","u",sum):
//   name field: tag=10, len=3, "ctr"(99,116,114)                   =  5 bytes
//   unit field: tag=26, len=1, "u"(117)                            =  3 bytes
//   sum field:  tag=58, len=24, <sum>                               = 26 bytes
//   metric = 34 bytes
test "encodeSumMetric emits the exact wire bytes for a monotonic cumulative counter" {
  val bytes = encodeSumMetric("ctr", "u", 7i64, 1000i64)
  val expected: slice[Byte] = [
    10u8,
    3u8,
    99u8,
    116u8,
    114u8,
    26u8,
    1u8,
    117u8,
    58u8,
    24u8,
    10u8,
    18u8,
    25u8,
    232u8,
    3u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    49u8,
    7u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    16u8,
    2u8,
    24u8,
    1u8
  ]
  assertEqualInt(bytes.length, 34, "Sum metric is 34 bytes")
  assertTrue(bytesEqual(bytes, expected), "Sum metric exact bytes")
}

// ─── Histogram metric ("hist","ms",count=2,sum=30.0,time=1000) ─────────────────
// 30.0 as IEEE-754 double = 0x403E000000000000 (sign=0, exponent=1027,
// mantissa=0xE0000000000): little-endian bytes = 00,00,00,00,00,00,3E,40
// (0x3E=62, 0x40=64).
// HistogramDataPoint{time_unix_nano=3,count=4,sum=5,bucket_counts=6}:
//   time field:   tag=25, LE(1000)                                  = 9 bytes
//   count field:  tag=(4<<3|1=33), LE(2)                             = 9 bytes
//   sum field:    tag=(5<<3|1=41), LE(0x403E000000000000)            = 9 bytes
//   bucket field: tag=49, LE(2)  [single implicit bucket == count]   = 9 bytes
//   dp = 36 bytes
// Histogram{data_points=1,aggregation_temporality=2}:
//   dp field:          tag=10, len=36, <dp>                          = 38 bytes
//   temporality field: tag=16, varint(2)                             =  2 bytes
//   hist = 40 bytes
// Metric{name=1,unit=3,histogram=9}("hist","ms",hist):
//   name field: tag=10, len=4, "hist"(104,105,115,116)               =  6 bytes
//   unit field: tag=26, len=2, "ms"(109,115)                         =  4 bytes
//   hist field: tag=(9<<3|2=74), len=40, <hist>                       = 42 bytes
//   metric = 52 bytes
test "encodeHistogramMetric emits the exact wire bytes for a single-bucket cumulative histogram" {
  val bytes = encodeHistogramMetric("hist", "ms", 2i64, 30.0, 1000i64)
  val expected: slice[Byte] = [
    10u8,
    4u8,
    104u8,
    105u8,
    115u8,
    116u8,
    26u8,
    2u8,
    109u8,
    115u8,
    74u8,
    40u8,
    10u8,
    36u8,
    25u8,
    232u8,
    3u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    33u8,
    2u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    41u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    62u8,
    64u8,
    49u8,
    2u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    0u8,
    16u8,
    2u8
  ]
  assertEqualInt(bytes.length, 52, "Histogram metric is 52 bytes")
  assertTrue(bytesEqual(bytes, expected), "Histogram metric exact bytes")
}

// ─── ExportTraceServiceRequest wrapping ────────────────────────────────────────
// Peels ExportTraceServiceRequest -> ResourceSpans -> ScopeSpans -> spans
// apart with the local wire-type-2 parser and checks (a) every wrapper
// field number matches the spec table in otlp_codec.l and (b) the two
// leaf Span messages byte-match `encodeSpanMessage` called directly
// (already exact-byte-tested above).
test "encodeExportTraceServiceRequest wraps every span under one Resource/ScopeSpans" {
  val traceId1: slice[Byte] = [1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8]
  val spanId1: slice[Byte] = [1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8]
  val traceId2: slice[Byte] = [2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8]
  val spanId2: slice[Byte] = [2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8, 2u8]
  val span1 = newSpanRecord(traceId1, spanId1, "op1", 0, 1000i64)
  spanFinish(span1, 1500i64)
  val span2 = newSpanRecord(traceId2, spanId2, "op2", 1, 2000i64)
  spanFinish(span2, 2500i64)
  var spans: List[Span] = newList()
  spans.add(span1)
  spans.add(span2)

  val requestMsg = encodeExportTraceServiceRequest(spans)

  val (reqFieldNum, resourceSpansBytes, reqNext) = readWireType2Field(requestMsg, 0)
  assertEqualInt(reqFieldNum, 1, "ExportTraceServiceRequest.resource_spans field number")
  assertEqualInt(reqNext, requestMsg.length, "no trailing bytes after resource_spans")

  val (rsField1Num, _resourceBytes, rsOffset1) = readWireType2Field(resourceSpansBytes, 0)
  assertEqualInt(rsField1Num, 1, "ResourceSpans.resource field number")
  val (rsField2Num, scopeSpansBytes, rsOffset2) = readWireType2Field(resourceSpansBytes, rsOffset1)
  assertEqualInt(rsField2Num, 2, "ResourceSpans.scope_spans field number")
  assertEqualInt(rsOffset2, resourceSpansBytes.length, "no trailing bytes after scope_spans")

  val (ssField1Num, _scopeBytes, ssOffset1) = readWireType2Field(scopeSpansBytes, 0)
  assertEqualInt(ssField1Num, 1, "ScopeSpans.scope field number")
  val (ssField2Num, span1Bytes, ssOffset2) = readWireType2Field(scopeSpansBytes, ssOffset1)
  assertEqualInt(ssField2Num, 2, "ScopeSpans.spans[0] field number")
  val (ssField3Num, span2Bytes, ssOffset3) = readWireType2Field(scopeSpansBytes, ssOffset2)
  assertEqualInt(ssField3Num, 2, "ScopeSpans.spans[1] field number")
  assertEqualInt(ssOffset3, scopeSpansBytes.length, "no trailing bytes after both spans")

  assertTrue(bytesEqual(span1Bytes, encodeSpanMessage(span1)), "first nested span matches encodeSpanMessage(span1)")
  assertTrue(bytesEqual(span2Bytes, encodeSpanMessage(span2)), "second nested span matches encodeSpanMessage(span2)")
}

// ─── ExportMetricsServiceRequest wrapping ──────────────────────────────────────
test "encodeExportMetricsServiceRequest wraps every metric message under one Resource/ScopeMetrics" {
  val counterMsg = encodeSumMetric("ctr", "requests", 3i64, 1000i64)
  val histMsg = encodeHistogramMetric("hist", "ms", 1i64, 10.0, 1000i64)
  var metrics: List[slice[Byte]] = newList()
  metrics.add(counterMsg)
  metrics.add(histMsg)

  val requestMsg = encodeExportMetricsServiceRequest(metrics)

  val (reqFieldNum, resourceMetricsBytes, reqNext) = readWireType2Field(requestMsg, 0)
  assertEqualInt(reqFieldNum, 1, "ExportMetricsServiceRequest.resource_metrics field number")
  assertEqualInt(reqNext, requestMsg.length, "no trailing bytes after resource_metrics")

  val (rmField1Num, _resourceBytes, rmOffset1) = readWireType2Field(resourceMetricsBytes, 0)
  assertEqualInt(rmField1Num, 1, "ResourceMetrics.resource field number")
  val (rmField2Num, scopeMetricsBytes, rmOffset2) = readWireType2Field(resourceMetricsBytes, rmOffset1)
  assertEqualInt(rmField2Num, 2, "ResourceMetrics.scope_metrics field number")
  assertEqualInt(rmOffset2, resourceMetricsBytes.length, "no trailing bytes after scope_metrics")

  val (smField1Num, _scopeBytes, smOffset1) = readWireType2Field(scopeMetricsBytes, 0)
  assertEqualInt(smField1Num, 1, "ScopeMetrics.scope field number")
  val (smField2Num, metric1Bytes, smOffset2) = readWireType2Field(scopeMetricsBytes, smOffset1)
  assertEqualInt(smField2Num, 2, "ScopeMetrics.metrics[0] field number")
  val (smField3Num, metric2Bytes, smOffset3) = readWireType2Field(scopeMetricsBytes, smOffset2)
  assertEqualInt(smField3Num, 2, "ScopeMetrics.metrics[1] field number")
  assertEqualInt(smOffset3, scopeMetricsBytes.length, "no trailing bytes after both metrics")

  assertTrue(bytesEqual(metric1Bytes, counterMsg), "first nested metric matches the Sum metric")
  assertTrue(bytesEqual(metric2Bytes, histMsg), "second nested metric matches the Histogram metric")
}
