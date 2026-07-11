//! tests/otel_span_tests.l — tests for lyric-otel's platform-neutral span
//! and metric recording (issue #5410): id generation, attribute/error
//! recording, span-buffer draining, and counter/histogram aggregation.
//! No network — this is the pure in-process bookkeeping `OTel.startSpan`/
//! `endSpan`/`incrementCounter`/`recordHistogram` do before OTLP export.
@test_module
package OTel.SpanTests

import Std.Core
import Std.Testing
import OTel
import OTel.Types

// ─── Span identity ────────────────────────────────────────────────────────────
test "startSpan generates a 16-byte trace id and an 8-byte span id" {
  val span = startSpan("test.op", 0)
  assertEqualInt(spanTraceId(span).length, 16, "trace id is 16 bytes")
  assertEqualInt(spanSpanId(span).length, 8, "span id is 8 bytes")
}

test "startSpan records the operation name, kind, and a positive start timestamp" {
  val span = startSpan("my.operation", 2)
  assertEqual(spanName(span), "my.operation", "name recorded")
  assertEqualInt(spanKind(span), 2, "kind recorded")
  assertTrue(spanStartNanos(span) > 0i64, "start timestamp is a positive unix-nanos value")
}

test "two spans started back-to-back get different trace ids" {
  val a = startSpan("a.op", 0)
  val b = startSpan("b.op", 0)
  val idA = spanTraceId(a)
  val idB = spanTraceId(b)
  var same = true
  var i = 0
  while i < 16 {
    if idA[i] != idB[i] {
      same = false
    }
    i = i + 1
  }
  assertFalse(same, "trace ids differ")
}

// ─── Attributes and errors ────────────────────────────────────────────────────
test "setSpanAttribute appends to the span's attribute list in order" {
  val span = startSpan("attrs.op", 0)
  setSpanAttribute(span, "k1", "v1")
  setSpanAttribute(span, "k2", "v2")
  val attrs = spanAttributes(span).toArray()
  assertEqualInt(attrs.length, 2, "two attributes recorded")
  assertEqual(attrs[0].key, "k1", "first key")
  assertEqual(attrs[0].value, "v1", "first value")
  assertEqual(attrs[1].key, "k2", "second key")
  assertEqual(attrs[1].value, "v2", "second value")
}

test "spanErrorMessage is None before setSpanError is called" {
  val span = startSpan("err.op.before", 0)
  val before = spanErrorMessage(span)
  match before {
    case Some(_) -> assertTrue(false, "expected no error before setSpanError")
    case None -> {
    }
  }
}

test "setSpanError records an error message without ending the span" {
  val span = startSpan("err.op", 0)
  setSpanError(span, "boom")
  val after = spanErrorMessage(span)
  match after {
    case Some(m) -> assertEqual(m, "boom", "error message recorded")
    case None -> assertTrue(false, "expected an error message")
  }
  // setSpanError does not stamp endNanos.
  assertEqualLong(spanEndNanos(span), spanStartNanos(span), "endNanos untouched by setSpanError")
}

// ─── endSpan / buffering ──────────────────────────────────────────────────────
test "endSpan stamps an end timestamp >= the start timestamp and buffers the span" {
  val span = startSpan("finish.op", 0)
  endSpan(span)
  assertTrue(spanEndNanos(span) >= spanStartNanos(span), "end >= start")
  val drained = globalSpanBuffer.drain()
  assertTrue(drained.length >= 1, "at least the span just ended was buffered")
}

test "globalSpanBuffer.drain empties the buffer" {
  val span = startSpan("drain.op", 0)
  endSpan(span)
  val _ = globalSpanBuffer.drain()
  assertEqualInt(globalSpanBuffer.count(), 0, "buffer is empty immediately after drain")
}

// `snapshot`/`removeExported` back the #5588 fix in `OTel.Otlp.flushOtlpAsync`:
// a caller must be able to read the buffer without clearing it (so a failed
// export leaves spans in place for the next flush) and later remove only
// the spans it already exported, never whatever happens to be in the
// buffer at that later point.
test "globalSpanBuffer.snapshot does not clear the buffer" {
  val _ = globalSpanBuffer.drain()
  val span = startSpan("snapshot.op", 0)
  endSpan(span)
  val seen = globalSpanBuffer.snapshot()
  assertTrue(seen.length >= 1, "snapshot sees the buffered span")
  assertTrue(globalSpanBuffer.count() >= 1, "snapshot is non-destructive")
}

test "globalSpanBuffer.removeExported only removes the snapshotted prefix" {
  val _ = globalSpanBuffer.drain()
  val first = startSpan("removeExported.first", 0)
  endSpan(first)
  val exportedCount = globalSpanBuffer.snapshot().length
  // Simulate a span arriving while the (simulated) export POST is in
  // flight — it must survive the removal below.
  val second = startSpan("removeExported.second", 0)
  endSpan(second)
  globalSpanBuffer.removeExported(exportedCount)
  assertEqualInt(globalSpanBuffer.count(), 1, "only the exported prefix was removed")
  val remaining = globalSpanBuffer.snapshot()
  assertEqual(spanName(remaining[0]), "removeExported.second", "the late-arriving span survives")
}

// ─── Counters ─────────────────────────────────────────────────────────────────
test "incrementCounter accumulates across calls with the same name" {
  incrementCounter("otel_span_tests.counter.a", 3, "requests")
  incrementCounter("otel_span_tests.counter.a", 4, "requests")
  val counters = globalMetricsBuffer.snapshotCounters().toArray()
  var found = false
  var i = 0
  while i < counters.length {
    if counters[i].name == "otel_span_tests.counter.a" {
      assertEqualLong(counters[i].total, 7i64, "counter accumulated to 7")
      found = true
    }
    i = i + 1
  }
  assertTrue(found, "counter was registered in the buffer")
}

test "incrementCounter keeps distinct names independent" {
  incrementCounter("otel_span_tests.counter.b1", 1, "requests")
  incrementCounter("otel_span_tests.counter.b2", 100, "requests")
  val counters = globalMetricsBuffer.snapshotCounters().toArray()
  var b1: Long = -1i64
  var b2: Long = -1i64
  var i = 0
  while i < counters.length {
    if counters[i].name == "otel_span_tests.counter.b1" {
      b1 = counters[i].total
    }
    if counters[i].name == "otel_span_tests.counter.b2" {
      b2 = counters[i].total
    }
    i = i + 1
  }
  assertEqualLong(b1, 1i64, "counter b1 unaffected by b2")
  assertEqualLong(b2, 100i64, "counter b2 unaffected by b1")
}

// ─── Histograms ───────────────────────────────────────────────────────────────
test "recordHistogram accumulates count and sum across calls with the same name" {
  recordHistogram("otel_span_tests.hist.a", 10.0f32, "ms")
  recordHistogram("otel_span_tests.hist.a", 20.0f32, "ms")
  val histograms = globalMetricsBuffer.snapshotHistograms().toArray()
  var found = false
  var i = 0
  while i < histograms.length {
    if histograms[i].name == "otel_span_tests.hist.a" {
      assertEqualLong(histograms[i].count, 2i64, "two observations")
      assertTrue(histograms[i].sum == 30.0, "sum accumulated to 30.0")
      found = true
    }
    i = i + 1
  }
  assertTrue(found, "histogram was registered in the buffer")
}

// ─── Time conversion ──────────────────────────────────────────────────────────
test "millisToNanos converts unix-epoch milliseconds to nanoseconds" {
  assertEqualLong(millisToNanos(0i64), 0i64, "0ms -> 0ns")
  assertEqualLong(millisToNanos(1i64), 1000000i64, "1ms -> 1_000_000ns")
  assertEqualLong(millisToNanos(1000i64), 1000000000i64, "1000ms -> 1e9ns")
}

test "nowUnixNanos returns a positive, plausible unix-nanos value" {
  // Sanity bound: any time after 2020-01-01 in unix nanos is > 1.577e18.
  val n = nowUnixNanos()
  assertTrue(n > 1577836800000000000i64, "nowUnixNanos looks like a real post-2020 timestamp")
}
