//! .NET kernel boundary for OTLP/HTTP export.
//!
//! Issue #5410: the previous version of this file bound the OTel .NET
//! SDK's fluent provider-builder API
//! (`Sdk.CreateTracerProviderBuilder().AddSource(...).AddOtlpExporter(opts
//! => …).Build()`) — a confirmed no-op, because that API needs `Action<T>`
//! delegate construction that auto-FFI cannot express (the fluent-builder
//! FFI gap docs/50 stops short of; see docs/03-decision-log.md D122).
//!
//! Per the issue's recommended redesign, this kernel now does the OTLP
//! export itself instead of delegating to the SDK: it POSTs pre-encoded
//! OTLP protobuf bytes (built by `OTel.Otlp.Codec`, pure Lyric, no BCL)
//! directly to a collector's OTLP/HTTP endpoint using
//! `System.Net.Http.HttpClient` + `ByteArrayContent`.  `Std.Http` cannot
//! be reused here: its public surface only builds `StringContent` bodies
//! (`Std.Http.withTextBody`/`withJsonBody`, `Std.HttpHost.hostWithStringBody`
//! — all hard-coded to `System.Text.Encoding.UTF8`), which corrupts any
//! byte >= 0x80 on the way through — fatal for protobuf, whose trace/span
//! IDs and varints are arbitrary bytes.  This is therefore its own
//! audited `_kernel/net/` extern boundary (docs/14-native-stdlib-plan.md
//! Decision F's per-library kernel pattern — the same shape `lyric-proto`
//! uses for `BitConverter`), not a "hand-routed BCL extern to plug a
//! stdlib gap": raw byte-body HTTP POST is a real capability `Std.Http`
//! does not expose today.  If `Std.Http` grows a byte-body POST, this
//! kernel should shrink to reuse it.
@cfg(feature = "dotnet")
@axiom("System.Net.Http operations conform to their documented .NET contracts")
package OTel.Kernel.Net.Otlp

import Std.Core

// =====================================================================
// Extern types.
// =====================================================================
extern type NetHttpClient = "System.Net.Http.HttpClient"

extern type NetHttpMethod = "System.Net.Http.HttpMethod"

extern type NetHttpRequestMessage = "System.Net.Http.HttpRequestMessage"

extern type NetHttpResponseMessage = "System.Net.Http.HttpResponseMessage"

extern type NetHttpHeaders = "System.Net.Http.Headers.HttpHeaders"

extern type NetHttpContentHeaders = "System.Net.Http.Headers.HttpContentHeaders"

extern type NetByteArrayContent = "System.Net.Http.ByteArrayContent"

extern type NetTimeSpan = "System.TimeSpan"

// =====================================================================
// Primitive externs.
// =====================================================================
@externTarget("System.Net.Http.HttpClient..ctor")
func newHttpClient(): NetHttpClient = ()

@externTarget("System.TimeSpan.FromMilliseconds")
func timeSpanFromMillis(ms: in Double): NetTimeSpan = ()

@externTarget("System.Net.Http.HttpClient.set_Timeout")
func setClientTimeout(client: in NetHttpClient, t: in NetTimeSpan): Unit = ()

@externTarget("System.Net.Http.HttpMethod..ctor")
func newHttpMethod(name: in String): NetHttpMethod = ()

@externTarget("System.Net.Http.HttpRequestMessage..ctor")
func newRequest(method: in NetHttpMethod, url: in String): NetHttpRequestMessage = ()

@externTarget("System.Net.Http.HttpRequestMessage.Headers")
func requestHeaders(req: in NetHttpRequestMessage): NetHttpHeaders = ()

@externTarget("System.Net.Http.Headers.HttpHeaders.TryAddWithoutValidation")
func headersTryAdd(h: in NetHttpHeaders, name: in String, value: in String): Bool = ()

@externTarget("System.Net.Http.ByteArrayContent..ctor")
func newByteArrayContent(data: in slice[Byte]): NetByteArrayContent = ()

@externTarget("System.Net.Http.HttpContent.Headers")
func contentHeadersOf(c: in NetByteArrayContent): NetHttpContentHeaders = ()

@externTarget("System.Net.Http.Headers.HttpHeaders.TryAddWithoutValidation")
func contentHeadersTryAdd(h: in NetHttpContentHeaders, name: in String, value: in String): Bool = ()

@externTarget("System.Net.Http.HttpRequestMessage.set_Content")
func setRequestContent(req: in NetHttpRequestMessage, content: in NetByteArrayContent): Unit = ()

// `@externInstance` is required here even though `Std.HttpHost`'s
// identically-shaped `clientSendAsync` (same target, same signature)
// omits it: without it, this package's build succeeds but the call
// throws `MissingMethodException` at runtime ("Method not found:
// ...HttpClient.SendAsync(HttpClient, HttpRequestMessage)"), i.e. the
// emitter resolved a *static* two-argument overload that doesn't exist
// instead of the real instance method — reproduced and confirmed fixed
// against a live local HTTP listener. Worth revisiting why the
// resolution differs between this package and `Std.HttpHost`.
@externInstance
@externTarget("System.Net.Http.HttpClient.SendAsync")
async func clientSendAsync(client: in NetHttpClient, request: in NetHttpRequestMessage): NetHttpResponseMessage = ()

@externTarget("System.Net.Http.HttpResponseMessage.StatusCode")
func responseStatusInt(response: in NetHttpResponseMessage): Int = ()

// =====================================================================
// Public boundary — the single entry point `OTel.Otlp` calls.
// =====================================================================
/// POST `payload` (already-encoded OTLP protobuf bytes) to `url` with
/// `Content-Type: application/x-protobuf` plus every `headerKeys[i]` =
/// `headerValues[i]` pair, using a fresh `HttpClient` with `Timeout` set
/// to `timeoutMs`.
///
/// A fresh client per call (rather than the pooled-singleton pattern
/// `Std.HttpHost.hostDefaultClient` uses) is deliberate: OTLP export
/// happens at most once per flush call, not per application request, so
/// the socket-pool-exhaustion concern that pattern guards against does
/// not apply, and a fresh client lets each flush honour its own
/// `timeoutMs` from `OtlpExporterConfig`.
///
/// Returns `Ok(statusCode)` on any completed HTTP exchange (including
/// non-2xx — the caller decides what counts as export success) or
/// `Err(message)` for connection/timeout/transport failures.
pub async func netPostProtobuf(
  url: in String,
  payload: in slice[Byte],
  headerKeys: in slice[String],
  headerValues: in slice[String],
  timeoutMs: in Int,
): Result[Int, String] {
  return try {
    val client = newHttpClient()
    setClientTimeout(client, timeSpanFromMillis(timeoutMs.toDouble()))
    val req = newRequest(newHttpMethod("POST"), url)
    var i = 0
    while i < headerKeys.length {
      val _ = headersTryAdd(requestHeaders(req), headerKeys[i], headerValues[i])
      i = i + 1
    }
    val content = newByteArrayContent(payload)
    val _ = contentHeadersTryAdd(contentHeadersOf(content), "Content-Type", "application/x-protobuf")
    setRequestContent(req, content)
    val resp = await clientSendAsync(client, req)
    Ok(value = responseStatusInt(resp))
  } catch Bug as b {
    Err(error = b.message)
  }
}

// =====================================================================
// IEEE-754 double bit pattern (for the OTLP `HistogramDataPoint.sum`
// field — a `fixed64` wire value).  `lyric-proto` has its own
// `doubleToInt64Bits`, but calling most `lyric-proto` functions (this
// one included) from a *different compiled assembly* currently crashes
// the .NET JIT with `InvalidProgramException` — a restored-dependency
// cross-assembly call bug (only `Proto.encodeMessage` and the raw
// `ProtoField` union-case constructors were found to survive the
// assembly boundary; every other `lyric-proto` function tested,
// including plain non-generic ones like `zigzag32`, reproduces the
// crash). `OTel.Otlp.Codec` avoids every other `lyric-proto` helper for
// exactly this reason (see its module doc). This extern, by contrast,
// is intra-assembly (`lyric-otel`'s own `_kernel/net/`, not a separate
// DLL), so it is unaffected.
@externTarget("System.BitConverter.DoubleToInt64Bits")
pub func netDoubleToInt64Bits(v: in Double): Long = ()
