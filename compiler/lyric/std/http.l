// std/http.l - safe HTTP client foundation.
//
// Public HTTP APIs are Result-based: connection, timeout, invalid URL,
// and response-body failures are data, not exceptions. The only place
// host failures are caught is this stdlib boundary.

@runtime_checked
package Std.Http

import Std.Errors
import Std.HttpHost as HostHttp

// ---------------------------------------------------------------------------
// HTTP request and response types.
// ---------------------------------------------------------------------------

pub enum HttpMethod {
  case GET
  case POST
  case PUT
  case DELETE
  case PATCH
  case HEAD
  case OPTIONS
}

/// Opaque validated URL wrapper.
///
/// URLs enter the stdlib as strings and are validated once at the
/// boundary. This first slice accepts HTTP and HTTPS URLs only; richer
/// URI decomposition belongs in the future `Std.Net` surface.
pub opaque type Url {
  value: String
  invariant: value.length > 0
}

/// Alias for callers that prefer URI terminology.
pub alias Uri = Url

/// Opaque request wrapper.
///
/// The host request handle is hidden so callers compose requests via
/// Std.Http helpers instead of mutating host objects directly.
pub opaque type HttpRequest {
  handle: HostHttp.HttpRequestMessage
  url: String
}

/// Opaque response wrapper.
///
/// Body reads remain explicit and fallible through `bodyText` and
/// `bodyBytes`; status inspection itself is total.
pub opaque type HttpResponse {
  handle: HostHttp.HttpResponseMessage
  url: String
}

/// Header collection marker reserved for future request/response header
/// iteration. Phase 4 exposes mutation through `withHeader`.
pub opaque type Headers {
  request: HostHttp.HttpRequestMessage
}

@pure
func methodName(method: in HttpMethod): String {
  match method {
    case GET -> "GET"
    case POST -> "POST"
    case PUT -> "PUT"
    case DELETE -> "DELETE"
    case PATCH -> "PATCH"
    case HEAD -> "HEAD"
    case OPTIONS -> "OPTIONS"
  }
}

// ---------------------------------------------------------------------------
// URL construction.
// ---------------------------------------------------------------------------

/// Parse and validate an HTTP(S) URL.
///
/// # Preconditions as data
/// - `raw` must be non-empty.
/// - `raw` must start with `http://` or `https://`.
///
/// # Errors
/// - `InvalidUrl`: empty or unsupported URL syntax.
pub func Url.tryFrom(raw: in String): Result[Url, HttpError] {
  if raw.length == 0 {
    return Err(error = InvalidUrl(url = raw))
  }
  if raw.startsWith("http://") or raw.startsWith("https://") {
    return Ok(value = Url(value = raw))
  }
  return Err(error = InvalidUrl(url = raw))
}

/// Return the original string value for a validated URL.
@pure
pub func Url.toString(url: in Url): String {
  return url.value
}

// ---------------------------------------------------------------------------
// Request construction.
// ---------------------------------------------------------------------------

/// Build a request with the given method and URL.
///
/// # Preconditions as data
/// - `url` must have been constructed by `Url.tryFrom`.
///
/// Host request construction failures are represented as HttpError by
/// `sendAsync`, not by this pure request-shaping helper.
pub func request(method: in HttpMethod, url: in Url): HttpRequest {
  return HttpRequest(
    handle = HostHttp.hostMakeRequest(methodName(method), url.value),
    url = url.value
  )
}

/// Add or replace one request header.
///
/// # Preconditions
/// - `key` must be non-empty. Empty header names are caller bugs.
pub func withHeader(
  request: in HttpRequest,
  key: in String,
  value: in String
): HttpRequest
  requires: key.length > 0
{
  return HttpRequest(
    handle = HostHttp.hostWithHeader(request.handle, key, value),
    url = request.url
  )
}

/// Attach a JSON string body and set the request content type.
///
/// This helper does not validate that `json` is syntactically valid
/// JSON. Source-generated JSON encoders will feed this in later phases.
pub func withJsonBody(request: in HttpRequest, json: in String): HttpRequest {
  return HttpRequest(
    handle = HostHttp.hostWithStringBody(request.handle, "application/json", json),
    url = request.url
  )
}

/// Attach a plain UTF-8 text body.
pub func withTextBody(request: in HttpRequest, text: in String): HttpRequest {
  return HttpRequest(
    handle = HostHttp.hostWithStringBody(request.handle, "text/plain; charset=utf-8", text),
    url = request.url
  )
}

// ---------------------------------------------------------------------------
// HTTP client operations.
// ---------------------------------------------------------------------------

/// Send a prepared HTTP request.
///
/// # Errors
/// - `ConnectionFailed`: DNS, connection, TLS, cancellation, or other
///   host send failures that are not classified more precisely yet.
/// - `Timeout`: reserved for future host timeout classification.
///
/// Non-2xx status codes are returned as successful HttpResponse values.
/// Callers decide whether to treat them as domain errors via status
/// helpers or `ensureSuccess`.
pub async func sendAsync(request: in HttpRequest): Result[HttpResponse, HttpError] {
  return try {
    val response = await HostHttp.hostSend(HostHttp.hostDefaultClient(), request.handle)
    Ok(value = HttpResponse(handle = response, url = request.url))
  } catch Bug as b {
    Err(error = ConnectionFailed(url = request.url, message = b.message))
  }
}

/// GET a URL string.
///
/// # Preconditions as data
/// - `url` must be a valid HTTP(S) URL or `InvalidUrl` is returned.
///
/// # Errors
/// - `InvalidUrl`: URL parsing failed.
/// - `ConnectionFailed` / `Timeout`: host send failures.
pub async func getAsync(url: in String): Result[HttpResponse, HttpError] {
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = e)
    case Ok(parsed) ->
      return try {
        val response = await HostHttp.hostGet(HostHttp.hostDefaultClient(), parsed.value)
        Ok(value = HttpResponse(handle = response, url = parsed.value))
      } catch Bug as b {
        Err(error = ConnectionFailed(url = parsed.value, message = b.message))
      }
  }
}

/// POST a UTF-8 text body to a URL.
///
/// This is the Phase 4 string-body convenience. JSON callers should use
/// `request(POST, url) |> withJsonBody(...) |> sendAsync(...)` once pipe
/// style is available, or the explicit nested-call equivalent.
pub async func postAsync(
  url: in String,
  body: in String
): Result[HttpResponse, HttpError] {
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = e)
    case Ok(parsed) ->
      return try {
        val response = await HostHttp.hostPostString(
          HostHttp.hostDefaultClient(),
          parsed.value,
          body,
          "text/plain; charset=utf-8"
        )
        Ok(value = HttpResponse(handle = response, url = parsed.value))
      } catch Bug as b {
        Err(error = ConnectionFailed(url = parsed.value, message = b.message))
      }
  }
}

// ---------------------------------------------------------------------------
// Response inspection and body reads.
// ---------------------------------------------------------------------------

/// Return the numeric HTTP status code.
@pure
pub func HttpResponse.statusCode(response: in HttpResponse): Int {
  return HostHttp.hostStatusCode(response.handle)
}

/// Return true for 2xx status codes.
@pure
pub func HttpResponse.isSuccess(response: in HttpResponse): Bool {
  val code = HttpResponse.statusCode(response)
  return code >= 200 and code <= 299
}

/// Return true for 4xx status codes.
@pure
pub func HttpResponse.isClientError(response: in HttpResponse): Bool {
  val code = HttpResponse.statusCode(response)
  return code >= 400 and code <= 499
}

/// Return true for 5xx status codes.
@pure
pub func HttpResponse.isServerError(response: in HttpResponse): Bool {
  val code = HttpResponse.statusCode(response)
  return code >= 500 and code <= 599
}

/// Convert non-success HTTP status into `HttpError.BadStatus`.
///
/// Use this when the caller wants a transport-style error for any
/// non-2xx response. Otherwise inspect status codes explicitly.
pub func HttpResponse.ensureSuccess(response: in HttpResponse): Result[HttpResponse, HttpError] {
  if HttpResponse.isSuccess(response) {
    return Ok(value = response)
  }
  return Err(error = BadStatus(url = response.url, statusCode = HttpResponse.statusCode(response)))
}

/// Read the response body as text.
///
/// # Errors
/// - `IoError`: host body read, decoding, cancellation, or stream
///   failures.
pub async func HttpResponse.bodyText(response: in HttpResponse): Result[String, IOError] {
  return try {
    Ok(value = await HostHttp.hostReadBodyText(response.handle))
  } catch Bug as b {
    Err(error = IoError(path = response.url, message = b.message))
  }
}

/// Read the response body as bytes.
///
/// # Errors
/// - `IoError`: host body read, cancellation, or stream failures.
pub async func HttpResponse.bodyBytes(response: in HttpResponse): Result[slice[Byte], IOError] {
  return try {
    Ok(value = await HostHttp.hostReadBodyBytes(response.handle))
  } catch Bug as b {
    Err(error = IoError(path = response.url, message = b.message))
  }
}

// ---------------------------------------------------------------------------
// Higher-level helpers.
// ---------------------------------------------------------------------------

/// Retry a request up to maxAttempts times.
///
/// This first source-level shape retries immediately. Backoff and
/// cancellation need the Phase 5 time/scheduling APIs before they can be
/// implemented without smuggling in hidden effects.
pub async func retry(
  request: in HttpRequest,
  maxAttempts: in Int,
  backoffMs: in Long
): Result[HttpResponse, HttpError]
  requires: maxAttempts > 0
  requires: backoffMs >= 0
{
  var attempts: Int = 0
  var last: Result[HttpResponse, HttpError] =
    Err(error = ConnectionFailed(url = request.url, message = "not attempted"))
  while attempts < maxAttempts {
    last = await sendAsync(request)
    match last {
      case Ok(response) -> return Ok(value = response)
      case Err(e) -> ()
    }
    attempts += 1
  }
  return last
}

// Future: timeout(request, durationMs) and followRedirects(response)
// need Clock/Duration and redirect policy types from Phase 5. Keep
// those out of the Phase 4 core to avoid hidden global timers or
// implicit redirect behavior.
