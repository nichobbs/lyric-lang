/// .NET kernel boundary for the OTLP exporter.
///
/// Configures the OpenTelemetry .NET SDK to export traces, metrics, and logs
/// via the OTLP exporter (OpenTelemetry.Exporter.OpenTelemetryProtocol NuGet).
///
/// Architecture:
///   - Traces:  Sdk.CreateTracerProviderBuilder()
///               .AddSource("lyric.otel")
///               .AddOtlpExporter(opts => …)
///               .Build()
///   - Metrics: Sdk.CreateMeterProviderBuilder()
///               .AddMeter("lyric.otel")
///               .AddOtlpExporter(opts => …)
///               .Build()
///   - Logs:    Host.CreateDefaultBuilder()
///               uses OpenTelemetry logging with AddOtlpExporter
///              (simplified: LoggerFactory + OTel logging bridge)
///
/// Each provider is stored in a .NET static field for the process lifetime and
/// can be force-flushed via netFlushOtlp.
///
/// The `protocol` argument: 0 = OtlpExportProtocol.Grpc, 1 = HttpProtobuf.
/// The `headers` argument: comma-separated "key=value" string in the format
///   the OTel SDK accepts for options.Headers.
///
/// These externs are @axiom-trusted because the OTel SDK handles all retry,
/// batching, and protocol negotiation internally.
@cfg(feature = "dotnet")
package OTel.Kernel.Net.Otlp

import Std.Core

@axiom("OpenTelemetry SDK and OpenTelemetry.Exporter.OpenTelemetryProtocol conform to their NuGet contracts")
extern package OpenTelemetry.Otlp.Net {
  /// Configure a TracerProvider with an OTLP trace exporter.
  /// Listens to the "lyric.otel" ActivitySource (the source used by OTel.Kernel.Net).
  /// Returns Err if already configured or on SDK initialisation failure.
  pub func netConfigureOtlpTraces(
    endpoint:  in String,
    protocol:  in Int,
    headers:   in String,
    timeoutMs: in Int
  ): Result[Unit, String]

  /// Configure a MeterProvider with an OTLP metrics exporter.
  /// Listens to the "lyric.otel" Meter.
  pub func netConfigureOtlpMetrics(
    endpoint:  in String,
    protocol:  in Int,
    headers:   in String,
    timeoutMs: in Int
  ): Result[Unit, String]

  /// Configure a LoggerProvider with an OTLP log exporter.
  /// Routes records from the "lyric.otel" logger category.
  pub func netConfigureOtlpLogs(
    endpoint:  in String,
    protocol:  in Int,
    headers:   in String,
    timeoutMs: in Int
  ): Result[Unit, String]

  /// Force-flush all configured providers, waiting up to `timeoutMs` ms.
  /// Returns true if all providers flushed cleanly within the timeout.
  pub func netFlushOtlp(timeoutMs: in Int): Bool
}
