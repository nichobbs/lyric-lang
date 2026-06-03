// OTLP (OpenTelemetry Protocol) exporter for lyric-otel.
//
// Configures the OTel SDK to export telemetry to an OTLP endpoint.
// Call one or more of configureOtlpTraces / configureOtlpMetrics /
// configureOtlpLogs once at application startup, before any spans or metrics
// are created.  The existing OTel.startSpan / OTel.endSpan / OTel.incrementCounter
// calls continue to work unchanged — the SDK pipeline picks them up and
// batches them for export.
//
// Exports via gRPC+protobuf (default port 4317) or HTTP+protobuf (port 4318):
//
//   OTel.Otlp.configureOtlp(OtlpExporterConfig {
//     endpoint  = "http://collector:4317"
//     protocol  = OtlpProtocol.Grpc
//     timeoutMs = 10000
//     headers   = []
//   })
//
// Before process exit, call flushOtlp(timeoutMs) to ensure buffered data is
// sent.  Unregistered providers are flushed on garbage collection, but an
// explicit flush is strongly recommended in Lambda / short-lived contexts.
//
// Implementation note: on .NET, the kernel calls
//   Sdk.CreateTracerProviderBuilder()
//     .AddSource("lyric.otel")
//     .AddOtlpExporter(…)
//     .Build()
// The returned provider is kept alive in a .NET static field for the process
// lifetime.  On JVM (Phase 6), the equivalent OTel Java SDK APIs are used.
package OTel.Otlp

import OTel.Kernel.Net.Otlp as OtelNetOtlp
import OTel.Kernel.Jvm.Otlp as OtelJvmOtlp
import Std.Core

// ─── Protocol selection ───────────────────────────────────────────────────────

/// The OTLP transport protocol.
pub enum OtlpProtocol {
  /// gRPC + protobuf (OTLP/gRPC) — default collector port 4317.
  case Grpc
  /// HTTP/1.1 + protobuf (OTLP/HTTP) — default collector port 4318.
  /// Useful when the runtime environment blocks HTTP/2 or gRPC traffic.
  case HttpProtobuf
}

func protocolId(p: OtlpProtocol): Int {
  match p {
    case OtlpProtocol.Grpc         -> 0
    case OtlpProtocol.HttpProtobuf -> 1
  }
}

// ─── Exporter configuration ───────────────────────────────────────────────────

/// A key-value header to attach to every OTLP request.
/// Useful for authentication tokens or tenant routing headers.
pub record OtlpHeader {
  key:   String
  value: String
}

/// Configuration for an OTLP exporter pipeline.
pub record OtlpExporterConfig {
  endpoint:  String
  protocol:  OtlpProtocol
  timeoutMs: Int
  headers:   slice[OtlpHeader]
}

/// A default OTLP config pointing at a local collector on gRPC.
pub func defaultConfig(): OtlpExporterConfig {
  OtlpExporterConfig(
    endpoint  = "http://localhost:4317",
    protocol  = OtlpProtocol.Grpc,
    timeoutMs = 10000,
    headers   = []
  )
}

// ─── Internal serialisation ───────────────────────────────────────────────────

// Headers are passed to the kernel as a comma-separated "key=value" string,
// the format the OTel SDK's options.Headers property accepts.
func headersString(cfg: OtlpExporterConfig): String {
  var buf = ""
  var i = 0
  while i < cfg.headers.length {
    val h = cfg.headers[i]
    if i > 0 { buf = buf + "," }
    buf = buf + h.key + "=" + h.value
    i = i + 1
  }
  return buf
}

// ─── Signal-specific configure functions ──────────────────────────────────────

/// Configure the OTel SDK to export traces via OTLP.
/// Sets up a TracerProvider listening to the "lyric.otel" ActivitySource (on .NET)
/// with a batching OTLP exporter.
///
/// Returns Err if the SDK is already configured for traces, or if the endpoint
/// is unreachable at setup time (applies only when protocol = Grpc and the SDK
/// performs a handshake on open).
@cfg(feature = "dotnet")
pub func configureOtlpTraces(cfg: OtlpExporterConfig): Result[Unit, String] {
  OtelNetOtlp.netConfigureOtlpTraces(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

@cfg(feature = "jvm")
pub func configureOtlpTraces(cfg: OtlpExporterConfig): Result[Unit, String] {
  OtelJvmOtlp.jvmConfigureOtlpTraces(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

/// Configure the OTel SDK to export metrics via OTLP.
/// Sets up a MeterProvider with a periodic OTLP exporter (default interval: 60 s,
/// overridable via OTEL_METRIC_EXPORT_INTERVAL environment variable).
@cfg(feature = "dotnet")
pub func configureOtlpMetrics(cfg: OtlpExporterConfig): Result[Unit, String] {
  OtelNetOtlp.netConfigureOtlpMetrics(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

@cfg(feature = "jvm")
pub func configureOtlpMetrics(cfg: OtlpExporterConfig): Result[Unit, String] {
  OtelJvmOtlp.jvmConfigureOtlpMetrics(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

/// Configure the OTel SDK to export logs via OTLP.
/// Sets up a LoggerProvider that receives log records forwarded from Std.Log.
@cfg(feature = "dotnet")
pub func configureOtlpLogs(cfg: OtlpExporterConfig): Result[Unit, String] {
  OtelNetOtlp.netConfigureOtlpLogs(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

@cfg(feature = "jvm")
pub func configureOtlpLogs(cfg: OtlpExporterConfig): Result[Unit, String] {
  OtelJvmOtlp.jvmConfigureOtlpLogs(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

// ─── Convenience: configure all three signals ─────────────────────────────────

/// Configure traces, metrics, and logs to export via OTLP with the same config.
@cfg(feature = "dotnet")
pub func configureOtlp(cfg: OtlpExporterConfig): Result[Unit, String] {
  val r = configureOtlpTraces(cfg)
  configureOtlpMetrics(cfg)
  configureOtlpLogs(cfg)
  return r
}

@cfg(feature = "jvm")
pub func configureOtlp(cfg: OtlpExporterConfig): Result[Unit, String] {
  val r = configureOtlpTraces(cfg)
  configureOtlpMetrics(cfg)
  configureOtlpLogs(cfg)
  return r
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────

/// Force-flush all configured OTLP exporters.
/// Blocks for up to `timeoutMs` milliseconds waiting for in-flight batches to
/// be sent.  Returns true if all exporters flushed successfully.
///
/// Call this before process exit in Lambda functions and short-lived containers
/// to ensure the last batch of telemetry reaches the collector.
@cfg(feature = "dotnet")
pub func flushOtlp(timeoutMs: Int): Bool {
  OtelNetOtlp.netFlushOtlp(timeoutMs)
}

@cfg(feature = "jvm")
pub func flushOtlp(timeoutMs: Int): Bool {
  OtelJvmOtlp.jvmFlushOtlp(timeoutMs)
}

// ─── config block ─────────────────────────────────────────────────────────────

// OtlpDefaults config block (compile-time DI, Phase 5+): endpoint, protocol, timeoutMs.
