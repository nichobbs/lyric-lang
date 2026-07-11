//! Platform-neutral OpenTelemetry types and in-process telemetry state.
//!
//! `Span` used to be a bare handle bound to `System.Diagnostics.Activity`
//! via an `@axiom`-trusted kernel that was a confirmed no-op (issue
//! #5410): `ActivitySource.StartActivity` returns `null` whenever no
//! `ActivityListener` is registered — the normal state absent full OTel
//! SDK setup — so every span/metric call silently did nothing.
//!
//! `Span` is now a plain in-process record: no BCL dependency, so
//! `startSpan` always succeeds (the null-`Activity` problem the issue
//! flagged cannot occur here — there is no `Activity` to be null).
//! Recording (`OTel.startSpan`/`setSpanAttribute`/`setSpanError`/`endSpan`,
//! `OTel.incrementCounter`/`recordHistogram`) is therefore fully
//! platform-neutral; only the OTLP/HTTP *export* step
//! (`OTel.Otlp.flushOtlpAsync`) is platform-specific, because it needs a
//! real HTTP transport (see `_kernel/net/otlp_kernel.l`).
package OTel.Types

import Std.Core
import Std.Collections
import Std.Time

// ─── Span ─────────────────────────────────────────────────────────────────
/// A single string key/value attribute attached to a span.
pub record SpanAttribute {
  key: String
  value: String
}

/// An active or completed tracing span.  The representation is opaque;
/// consumers interact with it only through functions in `OTel`.
///
/// Each span carries its own 16-byte trace ID and 8-byte span ID
/// (`Std.SecureRandom`-generated in `OTel.startSpan`) rather than
/// inheriting one from an enclosing trace context: this library does not
/// yet propagate trace context across nested `startSpan` calls, so every
/// span is presently exported as the root of its own single-span trace.
/// Parent/child linkage (via OTLP's `parent_span_id`) is tracked as a
/// follow-up — see `README.md` "Known limitations".
pub opaque type Span {
  // `hasError`/`errorText` (rather than a single `var errorMessage:
  // Option[String]` field) is a deliberate workaround: the self-hosted
  // MSIL codegen mishandles `Option[T]`-typed fields stored *inside an
  // opaque type* — matching one panics with "match not exhaustive" at
  // runtime even though both `Some`/`None` arms are present (reproduced
  // in isolation; a plain, non-opaque `record` with the identical
  // `Option[String]` field matches correctly). Storing the discriminant
  // as a plain `Bool` + `String` and constructing the `Option` value only
  // at the `spanErrorMessage` accessor boundary (never stored) sidesteps
  // the bug entirely.
  traceId: slice[Byte]
  spanId: slice[Byte]
  name: String
  kind: Int
  startNanos: Long
  var endNanos: Long
  var attributes: List[SpanAttribute]
  var hasError: Bool
  var errorText: String
}

/// Construct a new span record.  Only `OTel.startSpan` should call this;
/// exposed `pub` so tests can build spans with fixed IDs/timestamps for
/// exact byte-level protobuf assertions.
pub func newSpanRecord(
  traceId: in slice[Byte],
  spanId: in slice[Byte],
  name: in String,
  kind: in Int,
  startNanos: in Long,
): Span {
  Span(
    traceId = traceId,
    spanId = spanId,
    name = name,
    kind = kind,
    startNanos = startNanos,
    endNanos = startNanos,
    attributes = newList(),
    hasError = false,
    errorText = ""
  )
}

pub func spanTraceId(s: in Span): slice[Byte] {
  s.traceId
}

pub func spanSpanId(s: in Span): slice[Byte] {
  s.spanId
}

pub func spanName(s: in Span): String {
  s.name
}

pub func spanKind(s: in Span): Int {
  s.kind
}

pub func spanStartNanos(s: in Span): Long {
  s.startNanos
}

pub func spanEndNanos(s: in Span): Long {
  s.endNanos
}

pub func spanAttributes(s: in Span): List[SpanAttribute] {
  s.attributes
}

pub func spanErrorMessage(s: in Span): Option[String] {
  if s.hasError {
    Some(value = s.errorText)
  } else {
    None
  }
}

/// Attach a string attribute.  Mutation is visible through every other
/// reference to the same `Span` (records are reference types).
pub func spanAddAttribute(s: inout Span, key: in String, value: in String): Unit {
  s.attributes.add(SpanAttribute(key = key, value = value))
}

/// Record an error message on the span (does not end it).
pub func spanSetError(s: inout Span, message: in String): Unit {
  s.hasError = true
  s.errorText = message
}

/// Stamp the end timestamp.  Idempotent-ish: calling it twice just
/// overwrites `endNanos` with the later value.
pub func spanFinish(s: inout Span, endNanos: in Long): Unit {
  s.endNanos = endNanos
}

// ─── Span buffer ────────────────────────────────────────────────────────────
// Upper bound on buffered-but-unexported spans so a process that never
// calls `flushOtlpAsync` (or has no exporter configured) cannot grow this
// buffer without bound.  Spans beyond the cap are dropped silently — the
// same trade-off every fire-and-forget telemetry buffer makes; callers
// that care should flush regularly (see OTel.Otlp module doc).
val MAX_BUFFERED_SPANS: Int = 2048

/// Thread-safe buffer of completed spans awaiting OTLP export.
pub protected type SpanBuffer {
  var spans: List[Span]
  entry push(span: in Span): Unit {
    if spans.length < MAX_BUFFERED_SPANS {
      spans.add(span)
    }
  }
  // Remove and return every buffered span.
  entry drain(): List[Span] {
    val taken = spans
    spans = newList()
    return taken
  }
  // Non-destructive read of every currently-buffered span. Callers that
  // must know an export *succeeded* before discarding spans (see
  // `OTel.Otlp.flushOtlpAsync`, #5588) snapshot here, encode/POST, and only
  // call `removeExported` on success — never `drain`, which would drop the
  // batch unconditionally before the export result is known.
  func snapshot(): List[Span] {
    return spans
  }
  // Remove the first `n` spans (the ones a caller already exported
  // successfully, per `snapshot`'s FIFO order) rather than clearing
  // whatever happens to be buffered `n` calls later — any span pushed
  // after `snapshot()` was taken (e.g. while an export POST was in
  // flight) is preserved for the next flush.
  entry removeExported(n: in Int): Unit {
    if n <= 0 {
      // no-op: nothing exported, nothing to remove.
    } else if n >= spans.length {
      spans = newList()
    } else {
      val remaining: List[Span] = newList()
      var i = n
      while i < spans.length {
        remaining.add(spans[i])
        i = i + 1
      }
      spans = remaining
    }
  }
  func count(): Int {
    return spans.length
  }
}

func newSpanBuffer(): SpanBuffer {
  SpanBuffer(spans = newList())
}

/// Process-wide span buffer.  `OTel.endSpan` pushes into it;
/// `OTel.Otlp.flushOtlpAsync` drains it.
pub val globalSpanBuffer: SpanBuffer = newSpanBuffer()

// ─── Metrics state ──────────────────────────────────────────────────────────
/// A monotonic counter's current cumulative total.  OTLP reports counters
/// with `AGGREGATION_TEMPORALITY_CUMULATIVE`, so the exporter re-sends the
/// running total on every flush rather than a delta since the last flush.
pub record CounterPoint {
  name: String
  unit: String
  var total: Long
}

/// A histogram's aggregate statistics.  Bucketing is not implemented
/// (see README "Known limitations"): every observation falls into a
/// single implicit bucket spanning `(-Inf, +Inf)`, which is a spec-valid
/// `HistogramDataPoint` (`explicit_bounds` empty, one `bucket_counts`
/// entry) but does not support percentile queries in the collector —
/// only `count`/`sum`/`avg`.
pub record HistogramPoint {
  name: String
  unit: String
  var count: Long
  var sum: Double
}

/// Thread-safe registry of named counters and histograms.  Look-up is a
/// linear scan — fine for the bounded, small set of distinct metric names
/// a process typically registers (this is not a per-request-cardinality
/// store).
pub protected type MetricsBuffer {
  var counters: List[CounterPoint]
  var histograms: List[HistogramPoint]
  entry incrementCounter(name: in String, delta: in Long, unit: in String): Unit {
    var i = 0
    var found = false
    while i < counters.length {
      if counters[i].name == name {
        counters[i].total = counters[i].total + delta
        found = true
      }
      i = i + 1
    }
    if not found {
      counters.add(CounterPoint(name = name, unit = unit, total = delta))
    }
  }
  entry recordHistogram(name: in String, value: in Double, unit: in String): Unit {
    var i = 0
    var found = false
    while i < histograms.length {
      if histograms[i].name == name {
        histograms[i].count = histograms[i].count + 1i64
        histograms[i].sum = histograms[i].sum + value
        found = true
      }
      i = i + 1
    }
    if not found {
      histograms.add(HistogramPoint(name = name, unit = unit, count = 1i64, sum = value))
    }
  }
  func snapshotCounters(): List[CounterPoint] {
    return counters
  }
  func snapshotHistograms(): List[HistogramPoint] {
    return histograms
  }
}

func newMetricsBuffer(): MetricsBuffer {
  MetricsBuffer(counters = newList(), histograms = newList())
}

/// Process-wide metrics registry.  `OTel.incrementCounter`/
/// `OTel.recordHistogram` write into it; `OTel.Otlp.flushOtlpAsync` reads
/// a snapshot (not a drain — cumulative temporality resends totals).
pub val globalMetricsBuffer: MetricsBuffer = newMetricsBuffer()

// ─── Time helpers ───────────────────────────────────────────────────────────
/// Convert Unix epoch milliseconds to Unix epoch nanoseconds.  Pure and
/// exposed so tests can assert the conversion without a live clock.
///
/// Note: the resulting nanosecond value only ever carries millisecond
/// resolution (`Std.Time.nowEpochMillis` is the only cross-platform clock
/// source lyric-otel is allowed to depend on) — the low six decimal
/// digits are always zero.  This is spec-valid (OTLP's `fixed64` time
/// fields do not mandate any particular resolution) but coarser than a
/// true nanosecond clock.
pub func millisToNanos(ms: in Long): Long {
  ms * 1000000i64
}

/// Current Unix time in nanoseconds (millisecond resolution — see
/// `millisToNanos`).
pub func nowUnixNanos(): Long {
  millisToNanos(nowEpochMillis())
}
