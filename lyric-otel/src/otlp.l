//! OTLP (OpenTelemetry Protocol) exporter for lyric-otel.
//!
//! Call `configureOtlpTraces`/`configureOtlpMetrics` (or the
//! `configureOtlp` convenience wrapper) once at application startup, then
//! call `flushOtlpAsync` periodically (or at least once before process
//! exit) to POST every span/metric buffered by `OTel.startSpan`/
//! `OTel.endSpan`/`OTel.incrementCounter`/`OTel.recordHistogram` since
//! the last flush to the collector as OTLP/HTTP protobuf:
//!
//!   import OTel.Otlp
//!
//!   func main(): Unit {
//!     val _ = configureOtlp(defaultConfig())
//!     // ... application code calling OTel.startSpan/endSpan/... ...
//!     val ok = await flushOtlpAsync(5000)
//!   }
//!
//! Transport: OTLP/HTTP with protobuf bodies (`Content-Type:
//! application/x-protobuf`), built by `OTel.Otlp.Codec` (pure Lyric, on
//! top of `lyric-proto`) and sent via `_kernel/net/otlp_kernel.l`'s
//! `netPostProtobuf` — a dedicated `HttpClient`/`ByteArrayContent`
//! binding, not `Std.Http` (whose public POST/PUT/PATCH surface only
//! builds UTF-8 `StringContent` bodies and would corrupt arbitrary
//! protobuf bytes >= 0x80).
//!
//! `OtlpProtocol.Grpc` is declared for API-shape parity with real OTel
//! SDKs but is **not implemented**: OTLP/gRPC needs HTTP/2 trailers-based
//! framing, well beyond what this redesign (issue #5410) scoped in.
//! `configureOtlpTraces`/`configureOtlpMetrics` return `Err` immediately
//! for `OtlpProtocol.Grpc` rather than silently ignoring it.
//!
//! There is no OTLP **logs** exporter: `configureOtlpLogs` always
//! returns `Err` — see "Known limitations" in README.md.
//!
//! `jvm`: every `configureOtlp*` function returns `Err` — OTLP/HTTP
//! export is dotnet-only today (see `_kernel/jvm/otlp_kernel.l`).
package OTel.Otlp

import OTel.Types
import OTel.Otlp.Codec as Codec
import OTel.Kernel.Net.Otlp as OtelNetOtlp
import OTel.Kernel.Jvm.Otlp as OtelJvmOtlp
import Std.Core
import Std.Collections

// ─── Protocol selection ───────────────────────────────────────────────────────
/// The OTLP transport protocol.
pub enum OtlpProtocol {
  /// gRPC + protobuf (OTLP/gRPC) — **not implemented**, see module doc.
  case Grpc
  /// HTTP/1.1 + protobuf (OTLP/HTTP) — the only implemented transport.
  /// Default collector port 4318, paths `/v1/traces` and `/v1/metrics`
  /// appended automatically to the configured `endpoint`.
  case HttpProtobuf
}

// ─── Exporter configuration ───────────────────────────────────────────────────
/// A key-value header to attach to every OTLP request.
/// Useful for authentication tokens or tenant routing headers.
pub record OtlpHeader {
  key: String
  value: String
}

/// Configuration for an OTLP exporter pipeline.
pub record OtlpExporterConfig {
  endpoint: String
  protocol: OtlpProtocol
  timeoutMs: Int
  headers: slice[OtlpHeader]
}

/// A default OTLP config pointing at a local collector's OTLP/HTTP
/// endpoint (port 4318 — the OTLP/HTTP default; port 4317 is OTLP/gRPC,
/// which this library does not implement, see module doc).
@stable(since = "0.2")
pub func defaultConfig(): OtlpExporterConfig {
  OtlpExporterConfig(
    endpoint = "http://localhost:4318",
    protocol = OtlpProtocol.HttpProtobuf,
    timeoutMs = 10000,
    headers = []
  )
}

// ─── Configured-signal state ──────────────────────────────────────────────────
/// Thread-safe holder for the traces/metrics exporter configuration.
/// Traces and metrics may be configured independently (and with
/// different endpoints/headers), matching `configureOtlpTraces`/
/// `configureOtlpMetrics`'s independent signatures.
pub protected type ExporterConfigState {
  var tracesConfig: Option[OtlpExporterConfig]
  var metricsConfig: Option[OtlpExporterConfig]
  entry setTraces(cfg: in OtlpExporterConfig): Unit {
    tracesConfig = Some(value = cfg)
  }
  entry setMetrics(cfg: in OtlpExporterConfig): Unit {
    metricsConfig = Some(value = cfg)
  }
  func traces(): Option[OtlpExporterConfig] {
    return tracesConfig
  }
  func metrics(): Option[OtlpExporterConfig] {
    return metricsConfig
  }
}

func newExporterConfigState(): ExporterConfigState {
  ExporterConfigState(tracesConfig = None, metricsConfig = None)
}

val exporterState: ExporterConfigState = newExporterConfigState()

// ─── Signal-specific configure functions ──────────────────────────────────────
/// Configure OTLP/HTTP trace export.  Returns `Err` for
/// `OtlpProtocol.Grpc` (not implemented — see module doc).
@stable(since = "0.2")
pub func configureOtlpTraces(cfg: OtlpExporterConfig): Result[Unit, String] {
  match cfg.protocol {
    case OtlpProtocol.Grpc -> Err(error = "OTLP/gRPC is not implemented; set protocol = OtlpProtocol.HttpProtobuf (see lyric-otel/README.md)")
    case OtlpProtocol.HttpProtobuf -> {
      exporterState.setTraces(cfg)
      Ok(value = ())
    }
  }
}

/// Configure OTLP/HTTP metrics export.  Returns `Err` for
/// `OtlpProtocol.Grpc` (not implemented — see module doc).
@stable(since = "0.2")
pub func configureOtlpMetrics(cfg: OtlpExporterConfig): Result[Unit, String] {
  match cfg.protocol {
    case OtlpProtocol.Grpc -> Err(error = "OTLP/gRPC is not implemented; set protocol = OtlpProtocol.HttpProtobuf (see lyric-otel/README.md)")
    case OtlpProtocol.HttpProtobuf -> {
      exporterState.setMetrics(cfg)
      Ok(value = ())
    }
  }
}

/// OTLP log export is not implemented (traces and metrics only).
/// Always returns `Err`.
@stable(since = "0.2")
pub func configureOtlpLogs(cfg: OtlpExporterConfig): Result[Unit, String] {
  Err(error = "lyric-otel does not implement OTLP log export (traces and metrics only); see README.md")
}

/// Configure traces then metrics with the same config.  Stops at the
/// first error (logs are not included — `configureOtlpLogs` always
/// fails, so folding it in here would always mask the traces/metrics
/// result).
@stable(since = "0.2")
pub func configureOtlp(cfg: OtlpExporterConfig): Result[Unit, String] {
  match configureOtlpTraces(cfg) {
    case Err(e) -> Err(error = e)
    case Ok(_) -> configureOtlpMetrics(cfg)
  }
}

// ─── Transport dispatch ───────────────────────────────────────────────────────
@cfg(feature = "dotnet")
async func postProtobuf(
  url: String,
  payload: slice[Byte],
  headerKeys: slice[String],
  headerValues: slice[String],
  timeoutMs: Int,
): Result[Int, String] {
  await OtelNetOtlp.netPostProtobuf(url, payload, headerKeys, headerValues, timeoutMs)
}

@cfg(feature = "jvm")
async func postProtobuf(
  url: String,
  payload: slice[Byte],
  headerKeys: slice[String],
  headerValues: slice[String],
  timeoutMs: Int,
): Result[Int, String] {
  await OtelJvmOtlp.jvmPostProtobuf(url, payload, headerKeys, headerValues, timeoutMs)
}

func joinUrl(base: in String, path: in String): String {
  if base.length > 0 and base.substring(base.length - 1, 1) == "/" {
    base.substring(0, base.length - 1) + path
  } else {
    base + path
  }
}

func headerKeysOf(headers: in slice[OtlpHeader]): slice[String] {
  var ks: List[String] = newList()
  var i = 0
  while i < headers.length {
    ks.add(headers[i].key)
    i = i + 1
  }
  ks.toArray()
}

func headerValuesOf(headers: in slice[OtlpHeader]): slice[String] {
  var vs: List[String] = newList()
  var i = 0
  while i < headers.length {
    vs.add(headers[i].value)
    i = i + 1
  }
  vs.toArray()
}

func isSuccessStatus(status: in Int): Bool {
  status >= 200 and status < 300
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────
/// Drain every buffered span (if traces are configured) and snapshot
/// every counter/histogram (if metrics are configured), encode each as
/// an OTLP/HTTP protobuf export request, and POST them to the
/// corresponding `/v1/traces` / `/v1/metrics` path under the configured
/// endpoint.  Returns `true` only if every configured, non-empty export
/// completed with a 2xx response — `false` on any transport failure or
/// non-2xx status.  A signal that was never configured is skipped (not
/// counted as a failure); an empty buffer for a configured signal is
/// also skipped (no request sent).
///
/// Spans are drained (removed from the buffer) on flush.  Counters and
/// histograms are only snapshotted (not drained): OTLP reports them
/// with `AGGREGATION_TEMPORALITY_CUMULATIVE`, so re-sending the running
/// total on every flush is correct, not a duplicate.
///
/// Call this before process exit (Lambda / short-lived containers) and
/// periodically otherwise — there is no background flush thread.
@stable(since = "0.2")
pub async func flushOtlpAsync(timeoutMs: Int): Bool {
  var allOk = true
  match exporterState.traces() {
    case None -> {
    }
    case Some(cfg) -> {
      val spans = globalSpanBuffer.drain()
      if spans.length > 0 {
        val payload = Codec.encodeExportTraceServiceRequest(spans)
        val url = joinUrl(cfg.endpoint, "/v1/traces")
        match await postProtobuf(url, payload, headerKeysOf(cfg.headers), headerValuesOf(cfg.headers), timeoutMs) {
          case Err(_) -> {
            allOk = false
          }
          case Ok(status) -> if not isSuccessStatus(status) { allOk = false }
        }
      }
    }
  }
  match exporterState.metrics() {
    case None -> {
    }
    case Some(cfg) -> {
      val counters = globalMetricsBuffer.snapshotCounters().toArray()
      val histograms = globalMetricsBuffer.snapshotHistograms().toArray()
      if counters.length > 0 or histograms.length > 0 {
        val nowNanos = nowUnixNanos()
        var metricMessages: List[slice[Byte]] = newList()
        for c in counters {
          metricMessages.add(Codec.encodeSumMetric(c.name, c.unit, c.total, nowNanos))
        }
        for h in histograms {
          metricMessages.add(Codec.encodeHistogramMetric(h.name, h.unit, h.count, h.sum, nowNanos))
        }
        val payload = Codec.encodeExportMetricsServiceRequest(metricMessages)
        val url = joinUrl(cfg.endpoint, "/v1/metrics")
        match await postProtobuf(url, payload, headerKeysOf(cfg.headers), headerValuesOf(cfg.headers), timeoutMs) {
          case Err(_) -> {
            allOk = false
          }
          case Ok(status) -> if not isSuccessStatus(status) { allOk = false }
        }
      }
    }
  }
  allOk
}
