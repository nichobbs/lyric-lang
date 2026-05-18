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

import OTel.Types
import OTel.Kernel.Net.Otlp
import OTel.Kernel.Jvm.Otlp
import Std.Core
import Std.Collections

// ─── Protocol selection ───────────────────────────────────────────────────────

/// The OTLP transport protocol.
@stable(since="0.1")
pub type OtlpProtocol = enum {
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
@stable(since="0.1")
pub type OtlpHeader = record {
  key:   String
  value: String
}

/// Configuration for an OTLP exporter pipeline.
@stable(since="0.1")
pub type OtlpExporterConfig = record {
  /// Base endpoint URL including scheme and port.
  ///   gRPC:         "http://collector:4317"   (plain-text, no TLS)
  ///                 "https://collector:4317"  (TLS)
  ///   HTTP/protobuf: "http://collector:4318"
  /// The OTel SDK appends the signal-specific path automatically
  /// (/v1/traces, /v1/metrics, /v1/logs) for HTTP/protobuf.
  endpoint: String

  /// Transport protocol.  Defaults to Grpc.
  protocol: OtlpProtocol

  /// Export timeout in milliseconds.  The SDK retries within this window.
  timeoutMs: Int

  /// Extra HTTP/gRPC headers to attach to every export request.
  /// Typically used for authentication: OtlpHeader { key = "Authorization", value = "Bearer <token>" }
  headers: List[OtlpHeader]
}

/// A default OTLP config pointing at a local collector on gRPC.
@stable(since="0.1")
pub func defaultConfig(): OtlpExporterConfig {
  OtlpExporterConfig {
    endpoint  = "http://localhost:4317"
    protocol  = OtlpProtocol.Grpc
    timeoutMs = 10000
    headers   = List.empty()
  }
}

// ─── Internal serialisation ───────────────────────────────────────────────────

// Headers are passed to the kernel as a comma-separated "key=value" string,
// the format the OTel SDK's options.Headers property accepts.
func headersString(cfg: OtlpExporterConfig): String {
  cfg.headers
    .map(func(h) { h.key + "=" + h.value })
    .joinWith(",")
}

// ─── Signal-specific configure functions ──────────────────────────────────────

/// Configure the OTel SDK to export traces via OTLP.
/// Sets up a TracerProvider listening to the "lyric.otel" ActivitySource (on .NET)
/// with a batching OTLP exporter.
///
/// Returns Err if the SDK is already configured for traces, or if the endpoint
/// is unreachable at setup time (applies only when protocol = Grpc and the SDK
/// performs a handshake on open).
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func configureOtlpTraces(cfg: OtlpExporterConfig): Result[Unit, String] {
  netConfigureOtlpTraces(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func configureOtlpTraces(cfg: OtlpExporterConfig): Result[Unit, String] {
  jvmConfigureOtlpTraces(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

/// Configure the OTel SDK to export metrics via OTLP.
/// Sets up a MeterProvider with a periodic OTLP exporter (default interval: 60 s,
/// overridable via OTEL_METRIC_EXPORT_INTERVAL environment variable).
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func configureOtlpMetrics(cfg: OtlpExporterConfig): Result[Unit, String] {
  netConfigureOtlpMetrics(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func configureOtlpMetrics(cfg: OtlpExporterConfig): Result[Unit, String] {
  jvmConfigureOtlpMetrics(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

/// Configure the OTel SDK to export logs via OTLP.
/// Sets up a LoggerProvider that receives log records forwarded from Std.Log.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func configureOtlpLogs(cfg: OtlpExporterConfig): Result[Unit, String] {
  netConfigureOtlpLogs(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func configureOtlpLogs(cfg: OtlpExporterConfig): Result[Unit, String] {
  jvmConfigureOtlpLogs(cfg.endpoint, protocolId(cfg.protocol), headersString(cfg), cfg.timeoutMs)
}

// ─── Convenience: configure all three signals ─────────────────────────────────

/// Configure traces, metrics, and logs to export via OTLP with the same config.
/// Equivalent to calling configureOtlpTraces, configureOtlpMetrics, and
/// configureOtlpLogs in sequence; short-circuits and returns the first Err.
@stable(since="0.1")
pub func configureOtlp(cfg: OtlpExporterConfig): Result[Unit, String] {
  match configureOtlpTraces(cfg) {
    case Err(e) -> Err(e)
    case Ok(_) ->
      match configureOtlpMetrics(cfg) {
        case Err(e) -> Err(e)
        case Ok(_)  -> configureOtlpLogs(cfg)
      }
  }
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────

/// Force-flush all configured OTLP exporters.
/// Blocks for up to `timeoutMs` milliseconds waiting for in-flight batches to
/// be sent.  Returns true if all exporters flushed successfully.
///
/// Call this before process exit in Lambda functions and short-lived containers
/// to ensure the last batch of telemetry reaches the collector.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func flushOtlp(timeoutMs: Int): Bool {
  netFlushOtlp(timeoutMs)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func flushOtlp(timeoutMs: Int): Bool {
  jvmFlushOtlp(timeoutMs)
}

// ─── config block ─────────────────────────────────────────────────────────────

/// Runtime-configurable OTLP defaults.
/// All values can be overridden by the standard OTel environment variables
/// (OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_EXPORTER_OTLP_PROTOCOL, etc.),
/// which the OTel SDK reads at startup and takes precedence over these settings.
@stable(since="0.1")
pub config OtlpDefaults {
  /// Base collector endpoint.
  endpoint:  String  = "http://localhost:4317"
  /// Protocol: "grpc" or "http".
  protocol:  String  = "grpc"
  /// Export timeout in milliseconds.
  timeoutMs: Int     = 10000
}
