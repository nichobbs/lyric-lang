//! std/http.l - safe HTTP client foundation.
//!
//! Public HTTP APIs are Result-based: connection, timeout, invalid URL,
//! and response-body failures are data, not exceptions. The only place
//! host failures are caught is this stdlib boundary.
@runtime_checked
package Std.Http

import Std.Errors
import Std.HttpHost as HostHttp
import Std.Task

// ---------------------------------------------------------------------------
// HTTP request and response types.
// ---------------------------------------------------------------------------
@stable(since = "1.0")
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
@stable(since = "1.0")
pub opaque type Url {
  value: String
  invariant: value.length > 0
}

/// Alias for callers that prefer URI terminology.
@stable(since = "1.0")
pub alias Uri = Url

/// Opaque request wrapper.
///
/// The host request handle is hidden so callers compose requests via
/// Std.Http helpers instead of mutating host objects directly.
@stable(since = "1.0")
pub opaque type HttpRequest {
  handle: HostHttp.HttpRequestMessage
  url: String
}

/// Opaque response wrapper.
///
/// Body reads remain explicit and fallible through `bodyText` and
/// `bodyBytes`; status inspection itself is total.
@stable(since = "1.0")
pub opaque type HttpResponse {
  handle: HostHttp.HttpResponseMessage
  url: String
}

/// Header collection marker reserved for future request/response header
/// iteration. Phase 4 exposes mutation through `withHeader`.
@stable(since = "1.0")
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
@stable(since = "1.0")
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
@stable(since = "1.0")
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
@stable(since = "1.0")
pub func request(method: in HttpMethod, url: in Url): HttpRequest {
  return HttpRequest(handle = HostHttp.hostMakeRequest(methodName(method), url.value), url = url.value)
}

/// Add or replace one request header.
///
/// # Preconditions
/// - `key` must be non-empty. Empty header names are caller bugs.
@stable(since = "1.0")
pub func withHeader(request: in HttpRequest, key: in String, value: in String): HttpRequest
  requires: key.length > 0
{
  return HttpRequest(handle = HostHttp.hostWithHeader(request.handle, key, value), url = request.url)
}

/// Attach a JSON string body and set the request content type.
///
/// This helper does not validate that `json` is syntactically valid
/// JSON. Source-generated JSON encoders will feed this in later phases.
@stable(since = "1.0")
pub func withJsonBody(request: in HttpRequest, json: in String): HttpRequest {
  return HttpRequest(handle = HostHttp.hostWithStringBody(request.handle, "application/json", json), url = request.url)
}

/// Attach a plain UTF-8 text body.
@stable(since = "1.0")
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
@stable(since = "1.0")
pub async func sendAsync(request: in HttpRequest): Result[HttpResponse, HttpError] {
  val result = await HostHttp.hostSendSafe(HostHttp.hostDefaultClient(), request.handle)
  match result {
    case Err(message) -> return Err(error = ConnectionFailed(url = request.url, message = message))
    case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = request.url))
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
@stable(since = "1.0")
pub async func getAsync(url: in String): Result[HttpResponse, HttpError] {
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = e)
    case Ok(parsed) -> {
      val result = await HostHttp.hostGetSafe(HostHttp.hostDefaultClient(), parsed.value)
      match result {
        case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
        case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
      }
    }
  }
}

/// POST a UTF-8 text body to a URL.
///
/// This is the Phase 4 string-body convenience. JSON callers should use
/// `request(POST, url) |> withJsonBody(...) |> sendAsync(...)` once pipe
/// style is available, or the explicit nested-call equivalent.
@stable(since = "1.0")
pub async func postAsync(url: in String, body: in String): Result[HttpResponse, HttpError] {
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = e)
    case Ok(parsed) -> {
      val result = await HostHttp.hostPostStringSafe(HostHttp.hostDefaultClient(), parsed.value, body, "text/plain; charset=utf-8")
      match result {
        case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
        case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Response inspection and body reads.
// ---------------------------------------------------------------------------
/// Return the numeric HTTP status code.
@pure
@stable(since = "1.0")
pub func HttpResponse.statusCode(response: in HttpResponse): Int {
  return HostHttp.hostStatusCode(response.handle)
}

/// Return true for 2xx status codes.
@pure
@stable(since = "1.0")
pub func HttpResponse.isSuccess(response: in HttpResponse): Bool {
  val code = HttpResponse.statusCode(response)
  return code >= 200 and code <= 299
}

/// Return true for 4xx status codes.
@pure
@stable(since = "1.0")
pub func HttpResponse.isClientError(response: in HttpResponse): Bool {
  val code = HttpResponse.statusCode(response)
  return code >= 400 and code <= 499
}

/// Return true for 5xx status codes.
@pure
@stable(since = "1.0")
pub func HttpResponse.isServerError(response: in HttpResponse): Bool {
  val code = HttpResponse.statusCode(response)
  return code >= 500 and code <= 599
}

/// Convert non-success HTTP status into `HttpError.BadStatus`.
///
/// Use this when the caller wants a transport-style error for any
/// non-2xx response. Otherwise inspect status codes explicitly.
@stable(since = "1.0")
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
@stable(since = "1.0")
pub async func HttpResponse.bodyText(response: in HttpResponse): Result[String, IOError] {
  val result = await HostHttp.hostReadBodyTextSafe(response.handle)
  match result {
    case Err(message) -> return Err(error = IoError(path = response.url, message = message))
    case Ok(text) -> return Ok(value = text)
  }
}

/// Read the response body as bytes.
///
/// # Errors
/// - `IoError`: host body read, cancellation, or stream failures.
@stable(since = "1.0")
pub async func HttpResponse.bodyBytes(response: in HttpResponse): Result[slice[Byte], IOError] {
  val result = await HostHttp.hostReadBodyBytesSafe(response.handle)
  match result {
    case Err(message) -> return Err(error = IoError(path = response.url, message = message))
    case Ok(bytes) -> return Ok(value = bytes)
  }
}

// ---------------------------------------------------------------------------
// Higher-level helpers.
// ---------------------------------------------------------------------------
/// Retry a request up to maxAttempts times, with optional delay between
/// attempts.  Passing `backoffMs = 0` retries immediately.  Returns the
/// first successful response, or the last error if all attempts fail.
@stable(since = "1.0")
pub async func retry(request: in HttpRequest, maxAttempts: in Int, backoffMs: in Long): Result[HttpResponse, HttpError]
  requires: maxAttempts > 0
  requires: backoffMs >= 0
{
  var attempts: Int = 0
  var last: Result[HttpResponse, HttpError] = Err(
    error = ConnectionFailed(url = request.url, message = "not attempted")
  )
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

// ---------------------------------------------------------------------------
// Phase C cancellation / timeout / redirect (D-progress-070).
// ---------------------------------------------------------------------------
/// Send a request with explicit cancellation.  Pass a token from
/// `Std.Task.makeCancelSource()` (or a structured-concurrency
/// `Std.Task.Scope`) so the host honours cancellation requests
/// while the request is in flight.
///
/// # Errors
/// - `ConnectionFailed`: classified for cancellations as well as
///   transport failures (the message includes "cancelled" when
///   the token signalled).
@stable(since = "1.0")
pub async func sendWithCancelAsync(
  request: in HttpRequest, token: in CancellationToken
): Result[HttpResponse, HttpError] {
  val result = await HostHttp.hostSendWithCancelSafe(HostHttp.hostDefaultClient(), request.handle, token)
  match result {
    case Err(message) -> return Err(error = ConnectionFailed(url = request.url, message = message))
    case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = request.url))
  }
}

/// Send a request with a timeout in milliseconds.  An auto-cancelling
/// `CancellationTokenSource` fires after `timeoutMs`; the request is
/// cancelled, surfacing as `ConnectionFailed` with a "cancelled"
/// message.  The source is disposed when the call returns.
@stable(since = "1.0")
pub async func sendWithTimeoutAsync(request: in HttpRequest, timeoutMs: in Int): Result[HttpResponse, HttpError]
  requires: timeoutMs > 0
{
  val src = makeCancelSourceTimeout(timeoutMs)
  val tok = sourceToken(src)
  defer {
    disposeSource(src)
  }
  val result = await HostHttp.hostSendWithCancelSafe(HostHttp.hostDefaultClient(), request.handle, tok)
  match result {
    case Err(message) -> return Err(error = ConnectionFailed(url = request.url, message = message))
    case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = request.url))
  }
}

/// GET a URL with explicit cancellation.
@stable(since = "1.0")
pub async func getWithCancelAsync(url: in String, token: in CancellationToken): Result[HttpResponse, HttpError] {
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = e)
    case Ok(parsed) -> {
      val result = await HostHttp.hostGetWithCancelSafe(HostHttp.hostDefaultClient(), parsed.value, token)
      match result {
        case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
        case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
      }
    }
  }
}

/// GET a URL with a timeout.  Same shape as `sendWithTimeoutAsync`.
@stable(since = "1.0")
pub async func getWithTimeoutAsync(url: in String, timeoutMs: in Int): Result[HttpResponse, HttpError]
  requires: timeoutMs > 0
{
  val src = makeCancelSourceTimeout(timeoutMs)
  val tok = sourceToken(src)
  defer {
    disposeSource(src)
  }
  return await getWithCancelAsync(url, tok)
}

/// POST a UTF-8 text body to a URL with explicit cancellation.
@stable(since = "1.0")
pub async func postWithCancelAsync(
  url: in String, body: in String, token: in CancellationToken
): Result[HttpResponse, HttpError] {
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = e)
    case Ok(parsed) -> {
      val result = await HostHttp.hostPostStringWithCancelSafe(HostHttp.hostDefaultClient(), parsed.value, body, "text/plain; charset=utf-8", token)
      match result {
        case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
        case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
      }
    }
  }
}

/// POST a UTF-8 text body to a URL with a timeout.
@stable(since = "1.0")
pub async func postWithTimeoutAsync(url: in String, body: in String, timeoutMs: in Int): Result[HttpResponse, HttpError]
  requires: timeoutMs > 0
{
  val src = makeCancelSourceTimeout(timeoutMs)
  val tok = sourceToken(src)
  defer {
    disposeSource(src)
  }
  return await postWithCancelAsync(url, body, tok)
}

/// Read the response body as text, honouring cancellation.  Same
/// `IoError` discipline as `bodyText`.
@stable(since = "1.0")
pub async func HttpResponse.bodyTextWithCancel(
  response: in HttpResponse, token: in CancellationToken
): Result[String, IOError] {
  val result = await HostHttp.hostReadBodyTextWithCancelSafe(response.handle, token)
  match result {
    case Err(message) -> return Err(error = IoError(path = response.url, message = message))
    case Ok(text) -> return Ok(value = text)
  }
}

/// Look up a single response header by name.  Returns `None` when
/// the header isn't present.  Both response-level and content-level
/// header collections are consulted.
@stable(since = "1.0")
pub func HttpResponse.header(response: in HttpResponse, name: in String): Option[String] {
  val v = HostHttp.hostResponseHeader(response.handle, name)
  if v.length == 0 {
    None
  } else {
    Some(value = v)
  }
}

/// Construct an `HttpClient` that follows up to `maxRedirects`
/// redirects automatically.  Pair with `sendAsync` / `sendWithCancelAsync`
/// when the caller wants follow-redirect behaviour without
/// inspecting 3xx responses themselves.
@stable(since = "1.0")
pub func clientWithRedirects(maxRedirects: in Int): HostHttp.HttpClient
  requires: maxRedirects >= 0
{
  return HostHttp.hostClientWithRedirects(maxRedirects)
}

/// Construct an `HttpClient` that does NOT follow redirects.
/// Useful for callers that want to inspect 3xx responses
/// themselves (e.g. capturing the `Location` header via
/// `HttpResponse.header(...)`).
@stable(since = "1.0")
pub func clientNoRedirects(): HostHttp.HttpClient {
  return HostHttp.hostClientNoRedirects()
}

// Future: scoped HttpClient (per-Scope cancellation flow) needs the
// AsyncLocal<T> propagation from D-progress-059's Phase 4 follow-up;
// today users thread tokens explicitly via `sendWithCancelAsync`.
