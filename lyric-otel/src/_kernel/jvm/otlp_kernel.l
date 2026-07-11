//! JVM kernel boundary for OTLP/HTTP export — not implemented.
//!
//! Issue #5410 scoped the OTLP/HTTP-over-protobuf redesign to the
//! `dotnet` target only (see `_kernel/net/otlp_kernel.l`).  The prior
//! version of this file bound the OTel Java SDK's gRPC exporter
//! (`io.opentelemetry.exporter.otlp`), which was never wired up (no
//! `[maven]` table entries existed for it) and was Phase-6/"not compiled
//! today" scaffolding.  Rather than carry forward another inert
//! placeholder, this file is now a genuine, honestly-failing stub: no
//! BCL/JDK binding at all, just a real function that always reports
//! "not implemented" instead of silently no-oping.
//!
//! Tracked in docs/44-jvm-production-readiness-plan.md.  A real JVM
//! OTLP/HTTP transport would mirror `_kernel/net/otlp_kernel.l` using
//! `java.net.http.HttpClient` (JDK 11+, already used by
//! `_kernel_jvm/http_host.l`'s `lyric.stdlib.jvm.HttpClientHost`).
@cfg(feature = "jvm")
package OTel.Kernel.Jvm.Otlp

import Std.Core

/// Always fails: JVM OTLP/HTTP export is not implemented.
pub async func jvmPostProtobuf(
  url: in String,
  payload: in slice[Byte],
  headerKeys: in slice[String],
  headerValues: in slice[String],
  timeoutMs: in Int,
): Result[Int, String] {
  Err(
    error = "lyric-otel's JVM OTLP/HTTP transport is not implemented (dotnet-only today); see lyric-otel/README.md and docs/44-jvm-production-readiness-plan.md"
  )
}

/// Never reachable in practice (no JVM caller can get a histogram past
/// `jvmPostProtobuf`'s permanent failure above), but `OTel.Otlp.Codec`
/// needs a `jvm`-feature counterpart to `netDoubleToInt64Bits` to
/// compile under `--features jvm`.  Panics rather than returning a wrong
/// bit pattern.
pub func jvmDoubleToInt64Bits(v: in Double): Long {
  panic(
    "lyric-otel: histogram sum encoding is not implemented on the jvm feature (OTLP export is dotnet-only today); see README.md"
  )
}
