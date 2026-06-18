// JVM kernel boundary for the OTLP exporter (Phase 6).
//
// Mirrors OTel.Kernel.Net.Otlp using the OpenTelemetry Java SDK
// (io.opentelemetry:opentelemetry-exporter-otlp).
//
// Not compiled today — present to drive API parity with the .NET kernel.
@cfg(feature = "jvm")
package OTel.Kernel.Jvm.Otlp

import Std.Core

@axiom("io.opentelemetry.exporter.otlp and OpenTelemetry Java SDK conform to their Maven contracts")
extern package io.opentelemetry.otlp {
  pub func jvmConfigureOtlpTraces(
    endpoint:  in String,
    protocol:  in Int,
    headers:   in String,
    timeoutMs: in Int
  ): Result[Unit, String]

  pub func jvmConfigureOtlpMetrics(
    endpoint:  in String,
    protocol:  in Int,
    headers:   in String,
    timeoutMs: in Int
  ): Result[Unit, String]

  pub func jvmConfigureOtlpLogs(
    endpoint:  in String,
    protocol:  in Int,
    headers:   in String,
    timeoutMs: in Int
  ): Result[Unit, String]

  pub func jvmFlushOtlp(timeoutMs: in Int): Bool
}
