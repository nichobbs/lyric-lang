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

// ---------------------------------------------------------------------------
// HttpClient interface — the public contract for outbound HTTP transport.
//
// Callers receive an HttpClient from the factory functions or from
// HttpClientBuilder.build(); they never construct HttpClientImpl directly.
// Holding the interface rather than a concrete type allows dependency
// injection, test doubles, and alternative transport implementations.
// ---------------------------------------------------------------------------
/// Contract for outbound HTTP transport.
///
/// All methods accept the URL as a plain `String`; validation and
/// `InvalidUrl` errors are surfaced through the `Result` return type.
/// For requests that need custom headers or non-string bodies, use
/// `send` with a pre-built `HttpRequest`.
@stable(since = "1.1")
pub interface HttpClient {
  /// Send a pre-built HTTP request.
  async func send(request: in HttpRequest): Result[HttpResponse, HttpError]

  /// Send a pre-built HTTP request with explicit cancellation, honouring
  /// *this* client's own configuration (redirects, Unix socket, etc.) —
  /// unlike the free `sendWithCancelAsync`/`getWithCancelAsync`/
  /// `postWithCancelAsync` functions, which always operate on the global
  /// default client and so cannot be used by callers holding an injected
  /// `HttpClient` built via `clientWithRedirects`/`clientWithUnixSocket`/
  /// `HttpClientBuilder`. Compose with `request`/`withJsonBody`/
  /// `withStringBody` to cancel PUT/DELETE/PATCH calls; there is no
  /// separate `getWithCancel`/`postWithCancel` on this interface since
  /// `sendWithCancel` covers every verb. Added in the interface's 1.2 slice
  /// (#4014).
  async func sendWithCancel(request: in HttpRequest, token: in CancellationToken): Result[HttpResponse, HttpError]

  /// GET the given URL.
  async func get(url: in String): Result[HttpResponse, HttpError]

  /// POST a UTF-8 text body to the given URL.
  ///
  /// Content-Type is fixed at `text/plain; charset=utf-8`. For a JSON
  /// body, build the request explicitly instead:
  /// `send(withJsonBody(request(POST, url), json))`.
  async func post(url: in String, body: in String): Result[HttpResponse, HttpError]

  /// PUT a UTF-8 text body to the given URL.
  ///
  /// Content-Type is fixed at `text/plain; charset=utf-8` (see `post`).
  async func put(url: in String, body: in String): Result[HttpResponse, HttpError]

  /// DELETE the resource at the given URL.
  async func delete(url: in String): Result[HttpResponse, HttpError]

  /// PATCH a UTF-8 text body to the given URL.
  ///
  /// Content-Type is fixed at `text/plain; charset=utf-8` (see `post`).
  async func patch(url: in String, body: in String): Result[HttpResponse, HttpError]
}

// Private concrete implementation backed by a kernel HttpClientHandle.
// Constructed only by the factory functions and HttpClientBuilder.build().
record HttpClientImpl {
  handle: HostHttp.HttpClientHandle
}

impl HttpClient for HttpClientImpl {
  async func send(request: in HttpRequest): Result[HttpResponse, HttpError] {
    val result = await HostHttp.hostSendSafe(self.handle, request.handle)
    match result {
      case Err(message) -> return Err(error = ConnectionFailed(url = request.url, message = message))
      case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = request.url))
    }
  }

  async func sendWithCancel(request: in HttpRequest, token: in CancellationToken): Result[HttpResponse, HttpError] {
    val result = await HostHttp.hostSendWithCancelSafe(self.handle, request.handle, token)
    match result {
      case Err(message) -> return Err(error = ConnectionFailed(url = request.url, message = message))
      case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = request.url))
    }
  }

  async func get(url: in String): Result[HttpResponse, HttpError] {
    match Url.tryFrom(url) {
      case Err(e) -> return Err(error = e)
      case Ok(parsed) -> {
        val result = await HostHttp.hostGetSafe(self.handle, parsed.value)
        match result {
          case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
          case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
        }
      }
    }
  }

  async func post(url: in String, body: in String): Result[HttpResponse, HttpError] {
    match Url.tryFrom(url) {
      case Err(e) -> return Err(error = e)
      case Ok(parsed) -> {
        val result = await HostHttp.hostPostStringSafe(self.handle, parsed.value, body, "text/plain; charset=utf-8")
        match result {
          case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
          case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
        }
      }
    }
  }

  async func put(url: in String, body: in String): Result[HttpResponse, HttpError] {
    match Url.tryFrom(url) {
      case Err(e) -> return Err(error = e)
      case Ok(parsed) -> {
        val req = HttpRequest(
          handle = HostHttp.hostWithStringBody(
            HostHttp.hostMakeRequest("PUT", parsed.value),
            "text/plain; charset=utf-8",
            body
          ),
          url = parsed.value
        )
        val result = await HostHttp.hostSendSafe(self.handle, req.handle)
        match result {
          case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
          case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
        }
      }
    }
  }

  async func delete(url: in String): Result[HttpResponse, HttpError] {
    match Url.tryFrom(url) {
      case Err(e) -> return Err(error = e)
      case Ok(parsed) -> {
        val req = HttpRequest(handle = HostHttp.hostMakeRequest("DELETE", parsed.value), url = parsed.value)
        val result = await HostHttp.hostSendSafe(self.handle, req.handle)
        match result {
          case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
          case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
        }
      }
    }
  }

  async func patch(url: in String, body: in String): Result[HttpResponse, HttpError] {
    match Url.tryFrom(url) {
      case Err(e) -> return Err(error = e)
      case Ok(parsed) -> {
        val req = HttpRequest(
          handle = HostHttp.hostWithStringBody(
            HostHttp.hostMakeRequest("PATCH", parsed.value),
            "text/plain; charset=utf-8",
            body
          ),
          url = parsed.value
        )
        val result = await HostHttp.hostSendSafe(self.handle, req.handle)
        match result {
          case Err(message) -> return Err(error = ConnectionFailed(url = parsed.value, message = message))
          case Ok(response) -> return Ok(value = HttpResponse(handle = response, url = parsed.value))
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// HttpClientBuilder — fluent configuration for HttpClient instances.
//
// Each with* method returns a new builder value; call build() to obtain
// the configured HttpClient.  The factory convenience functions
// (defaultClient, clientWithUnixSocket, etc.) cover the common cases.
// ---------------------------------------------------------------------------
/// Builder for configuring an HttpClient.
///
/// ```lyric
/// val client = HttpClientBuilder.new()
///     .withUnixSocket("/var/run/docker.sock")
///     .withNoRedirects()
///     .build()
/// ```
@stable(since = "1.1")
pub record HttpClientBuilder {
  socketPath: Option[String]
  maxRedirects: Option[Int]
  noRedirects: Bool
}

/// Construct a default builder (TCP transport, redirect-following, process-wide singleton).
@stable(since = "1.1")
pub func HttpClientBuilder.new(): HttpClientBuilder {
  HttpClientBuilder(socketPath = None, maxRedirects = None, noRedirects = false)
}

/// Route all requests through the Unix domain socket at `path`.
///
/// Common paths: Docker at `/var/run/docker.sock`, systemd at
/// `/run/systemd/private/io.systemd.Journal`.
@stable(since = "1.1")
pub func HttpClientBuilder.withUnixSocket(b: in HttpClientBuilder, path: in String): HttpClientBuilder
  requires: path.length > 0
{
  HttpClientBuilder(socketPath = Some(value = path), maxRedirects = b.maxRedirects, noRedirects = b.noRedirects)
}

/// Follow up to `max` redirects automatically.
@stable(since = "1.1")
pub func HttpClientBuilder.withRedirects(b: in HttpClientBuilder, max: in Int): HttpClientBuilder
  requires: max >= 0
{
  HttpClientBuilder(socketPath = b.socketPath, maxRedirects = Some(value = max), noRedirects = false)
}

/// Do not follow redirects.  3xx responses are returned to the caller as-is.
@stable(since = "1.1")
pub func HttpClientBuilder.withNoRedirects(b: in HttpClientBuilder): HttpClientBuilder {
  HttpClientBuilder(socketPath = b.socketPath, maxRedirects = None, noRedirects = true)
}

/// Build the configured `HttpClient`.
@stable(since = "1.1")
pub func HttpClientBuilder.build(b: in HttpClientBuilder): HttpClient {
  val handle = match b.socketPath {
    case Some(path) ->
      if b.noRedirects {
        HostHttp.hostClientWithUnixSocketNoRedirects(path)
      } else {
        match b.maxRedirects {
          case Some(n) -> HostHttp.hostClientWithUnixSocketAndRedirects(path, n)
          case None -> HostHttp.hostClientWithUnixSocket(path)
        }
      }
    case None ->
      if b.noRedirects {
        HostHttp.hostClientNoRedirects()
      } else {
        match b.maxRedirects {
          case Some(n) -> HostHttp.hostClientWithRedirects(n)
          case None -> HostHttp.hostDefaultClient()
        }
      }
  }
  HttpClientImpl(handle = handle)
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
// Free-function HTTP operations — use the process-wide default client.
//
// These remain for callers that don't need per-call client configuration.
// For custom transport (Unix sockets, redirect policy, etc.) use
// HttpClientBuilder.build() and call methods on the resulting HttpClient.
// ---------------------------------------------------------------------------
/// Send a prepared HTTP request using the default client.
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

/// GET a URL string using the default client.
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

/// POST a UTF-8 text body to a URL using the default client.
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

// ---------------------------------------------------------------------------
// HttpClient factory convenience functions.
//
// These wrap HttpClientBuilder for the common single-option cases.
// For composite configuration, use HttpClientBuilder directly.
// ---------------------------------------------------------------------------
/// Return the process-wide default HttpClient (TCP, follows redirects).
///
/// Prefer this over constructing a new client per request.  The singleton
/// handle avoids TCP socket-pool exhaustion from repeated construction.
@stable(since = "1.1")
pub func defaultClient(): HttpClient {
  HttpClientImpl(handle = HostHttp.hostDefaultClient())
}

/// Construct an `HttpClient` that follows up to `maxRedirects`
/// redirects automatically.
@stable(since = "1.0")
pub func clientWithRedirects(maxRedirects: in Int): HttpClient
  requires: maxRedirects >= 0
{
  HttpClientImpl(handle = HostHttp.hostClientWithRedirects(maxRedirects))
}

/// Construct an `HttpClient` that does NOT follow redirects.
/// Useful for callers that want to inspect 3xx responses
/// themselves (e.g. capturing the `Location` header via
/// `HttpResponse.header(...)`).
@stable(since = "1.0")
pub func clientNoRedirects(): HttpClient {
  HttpClientImpl(handle = HostHttp.hostClientNoRedirects())
}

// ---------------------------------------------------------------------------
// Unix domain socket support for local protocol access (Docker, systemd, etc).
// ---------------------------------------------------------------------------
/// Construct an `HttpClient` connected to a Unix domain socket.
///
/// Unix domain sockets are used for local inter-process communication on
/// Unix-like systems (Linux, macOS). Common applications include Docker
/// (at `/var/run/docker.sock`), systemd, and dbus.
///
/// # Preconditions as data
/// - `socketPath` must be a valid path to an accessible Unix socket.
///
/// Connection failures are represented as `ConnectionFailed` by `send`.
@stable(since = "1.1")
pub func clientWithUnixSocket(socketPath: in String): HttpClient
  requires: socketPath.length > 0
{
  HttpClientImpl(handle = HostHttp.hostClientWithUnixSocket(socketPath))
}

/// Construct an `HttpClient` connected to a Unix domain socket with redirect following.
///
/// # Preconditions as data
/// - `socketPath` must be a valid path to an accessible Unix socket.
/// - `maxRedirects` must be non-negative.
@stable(since = "1.1")
pub func clientWithUnixSocketAndRedirects(socketPath: in String, maxRedirects: in Int): HttpClient
  requires: socketPath.length > 0
  requires: maxRedirects >= 0
{
  HttpClientImpl(handle = HostHttp.hostClientWithUnixSocketAndRedirects(socketPath, maxRedirects))
}

/// Construct an `HttpClient` connected to a Unix domain socket without redirect following.
///
/// Useful when the caller wants to inspect 3xx responses directly.
///
/// # Preconditions as data
/// - `socketPath` must be a valid path to an accessible Unix socket.
@stable(since = "1.1")
pub func clientWithUnixSocketNoRedirects(socketPath: in String): HttpClient
  requires: socketPath.length > 0
{
  HttpClientImpl(handle = HostHttp.hostClientWithUnixSocketNoRedirects(socketPath))
}

// Future: scoped HttpClient (per-Scope cancellation flow) needs the
// AsyncLocal<T> propagation from D-progress-059's Phase 4 follow-up;
// today users thread tokens explicitly via `sendWithCancelAsync`.
