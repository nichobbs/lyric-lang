//! JVM kernel boundary for OTLP/HTTP export.
//!
//! POSTs pre-encoded OTLP protobuf bytes (built by `OTel.Otlp.Codec`, pure
//! Lyric) to a collector's OTLP/HTTP endpoint with `java.net.http.HttpClient`
//! and `BodyPublishers.ofByteArray`, mirroring `_kernel/net/otlp_kernel.l`.
//! `Std.Http` cannot be reused: its request bodies are `String`s sent as UTF-8
//! (`withTextBody`/`withJsonBody`), which corrupts every byte >= 0x80, and
//! protobuf trace/span IDs and varints are arbitrary bytes.  If `Std.Http`
//! grows a byte-body POST this kernel should shrink to reuse it.
@cfg(feature = "jvm")
@axiom("java.net.http.HttpClient operations conform to their documented JVM contracts")
@io
package OTel.Kernel.Jvm.Otlp

import Std.Core

extern type JHttpClient = "java.net.http.HttpClient"

extern type JHttpRequest = "java.net.http.HttpRequest"

extern type JHttpRequestBuilder = "java.net.http.HttpRequest$Builder"

extern type JBodyPublishers = "java.net.http.HttpRequest$BodyPublishers"

extern type JBodyHandlers = "java.net.http.HttpResponse$BodyHandlers"

extern type JHttpResponse = "java.net.http.HttpResponse"

extern type JURI = "java.net.URI"

extern type JDuration = "java.time.Duration"

extern type JInputStream = "java.io.InputStream"

func isContentType(name: in String): Bool {
  name.length == 12 and name.toLower() == "content-type"
}

func buildPostRequest(
  url: in String,
  payload: in slice[Byte],
  headerKeys: in slice[String],
  headerValues: in slice[String],
  timeoutMs: in Int,
): Result[JHttpRequest, String] {
  return try {
    var b: JHttpRequestBuilder = JHttpRequest.newBuilder()
    b = b.uri(JURI.create(url))
    b = b.timeout(JDuration.ofMillis(timeoutMs.toLong()))
    var i = 0
    while i < headerKeys.length {
      if isContentType(headerKeys[i]) {
        return Err(error = "OTLP header '" + headerKeys[i] + "' was rejected by the HTTP stack")
      }
      b = b.header(headerKeys[i], headerValues[i])
      i = i + 1
    }
    b = b.header("Content-Type", "application/x-protobuf")
    b = b.method("POST", JBodyPublishers.ofByteArray(payload))
    Ok(value = b.build())
  } catch Bug as e {
    Err(error = "OTLP request could not be built: " + e.message)
  }
}

func sendBuilt(req: in JHttpRequest): Result[Int, String] {
  return try {
    val client: JHttpClient = JHttpClient.newHttpClient()
    val resp: JHttpResponse = client.send(req, JBodyHandlers.ofInputStream())
    val ins: JInputStream = resp.body()
    ins.close()
    Ok(value = resp.statusCode())
  } catch Bug as e {
    Err(error = e.message)
  }
}

/// POST `payload` (already-encoded OTLP protobuf bytes) to `url` with
/// `Content-Type: application/x-protobuf` plus every `headerKeys[i]` =
/// `headerValues[i]` pair and a request deadline of `timeoutMs`.
///
/// Returns `Ok(statusCode)` on any completed HTTP exchange (including
/// non-2xx, the caller decides what counts as export success) or
/// `Err(message)` for a rejected header, a malformed URL, or a
/// connection/timeout failure.
pub async func jvmPostProtobuf(
  url: in String,
  payload: in slice[Byte],
  headerKeys: in slice[String],
  headerValues: in slice[String],
  timeoutMs: in Int,
): Result[Int, String] {
  match buildPostRequest(url, payload, headerKeys, headerValues, timeoutMs) {
    case Err(message) -> return Err(error = message)
    case Ok(req) -> return sendBuilt(req)
  }
}
