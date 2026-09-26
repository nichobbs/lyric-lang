//! std/rest.l - Typed REST client built on top of Std.Http.
//!
//! RestClient holds a base URL, default headers, and an optional auth
//! strategy.  Every operation returns Result[T, RestError] where T is the
//! caller's expected response type.  JSON bodies are read via Std.Json;
//! non-JSON response bodies surface as RestError.Deserialize.
@runtime_checked
package Std.Rest

import Std.Core
import Std.Errors
import Std.Http
import Std.Json

// ---------------------------------------------------------------------------
// RestError — all failures a REST call can produce.
// ---------------------------------------------------------------------------
/// Every failure a REST operation can produce.
///
/// - `Http`: underlying transport / status failure (wraps HttpError).
/// - `Deserialize`: response body could not be parsed as JSON or
///   the expected shape was missing.
@stable(since = "1.0")
pub union RestError {
  case Http(error: HttpError)
  case Deserialize(url: String, reason: String)
}

/// Human-readable message for a RestError.
@pure
@stable(since = "1.0")
pub func RestError.message(e: in RestError): String {
  match e {
    case Http(error) -> HttpError.message(error)
    case Deserialize(url, reason) -> "deserialize error from " + url + ": " + reason
  }
}

// ---------------------------------------------------------------------------
// Authentication strategies.
// ---------------------------------------------------------------------------
/// Authentication strategy carried by a RestClient.
///
/// - `None_`: no authentication header is attached.
/// - `Bearer`: `Authorization: Bearer <token>` header.
/// - `Basic`: `Authorization: Basic <base64>` header (pre-encoded).
/// - `ApiKey`: arbitrary header name / value pair (e.g. `X-Api-Key`).
///
/// Declared as `union` (not `enum`) because three of the four cases
/// carry payload data — `pub enum` is reserved for tag-only
/// alternatives.  Switching this declaration to `union` aligns the
/// type with the rest of `Std.Errors` (`HttpError`, `IOError`, …) and
/// keeps the case-pattern emit path on the same codegen branch used
/// elsewhere; the surface is binary-identical at the call sites
/// (`Bearer(token = ...)`, `Basic(credentials = ...)`,
/// `ApiKey(headerName = ..., headerValue = ...)`).
@stable(since = "1.0")
pub union RestAuth {
  case None_
  case Bearer(token: String)
  case Basic(credentials: String)
  case ApiKey(headerName: String, headerValue: String)
}

// ---------------------------------------------------------------------------
// RestClient — stateful base-URL client.
// ---------------------------------------------------------------------------
/// Opaque REST client.
///
/// Construct via `RestClient.create`, customise with `withAuth`,
/// `withHeader`, then call `get`, `post`, `put`, `delete`, or `patch`.
@stable(since = "1.0")
pub opaque type RestClient {
  baseUrl: String
  auth: RestAuth
  defaultHeaders: String
}

/// Construct a RestClient with a base URL and no auth.
///
/// `baseUrl` is validated on each request, not here: an empty or invalid
/// base makes every call return `Http(InvalidUrl)`.  So does a request
/// `path` that could leave the base (`..`/`.` segments, an absolute
/// `//host` or `scheme://` path, CR/LF/NUL).
@stable(since = "1.0")
pub func RestClient.create(baseUrl: in String): RestClient {
  return RestClient(baseUrl = baseUrl, auth = None_, defaultHeaders = "")
}

/// Attach an authentication strategy to a RestClient.
@pure
@stable(since = "1.0")
pub func RestClient.withAuth(client: in RestClient, auth: in RestAuth): RestClient {
  return RestClient(baseUrl = client.baseUrl, auth = auth, defaultHeaders = client.defaultHeaders)
}

// ---------------------------------------------------------------------------
// Internal helpers.
// ---------------------------------------------------------------------------
func toRestResult(r: in Result[HttpRequest, HttpError]): Result[HttpRequest, RestError] {
  match r {
    case Ok(v) -> Ok(value = v)
    case Err(e) -> Err(error = Http(error = e))
  }
}

// `Authorization` is never a reserved framing header, so these calls
// cannot fail on the `Bearer`/`Basic` arms; `ApiKey` carries a
// caller-chosen name, so its `Err` is propagated rather than assumed
// away.
func applyAuth(req: in HttpRequest, auth: in RestAuth): Result[HttpRequest, RestError] {
  match auth {
    case None_ -> return Ok(value = req)
    case Bearer(token) -> return toRestResult(withHeader(req, "Authorization", "Bearer " + token))
    case Basic(credentials) -> return toRestResult(withHeader(req, "Authorization", "Basic " + credentials))
    case ApiKey(headerName, headerValue) -> return toRestResult(withHeader(req, headerName, headerValue))
  }
}

// `baseUrl` joined with the caller's `path`, or `Err(InvalidUrl)` when the
// join could leave the base: an empty base, a `path` that is itself absolute
// (`//host`, `scheme://`), one with a `.`/`..` segment before any `?`/`#`
// (also percent-encoded), or one carrying CR, LF or NUL.  `path` is often
// built from request data, so these are errors, not preconditions (#7251).
func fullUrl(client: in RestClient, path: in String): Result[String, RestError] {
  val base = client.baseUrl
  if base.length == 0 {
    return Err(error = Http(error = InvalidUrl(url = path)))
  }
  if path.length == 0 {
    return Ok(value = base)
  }
  if not isSafeRelativePath(path) {
    return Err(error = Http(error = InvalidUrl(url = base + path)))
  }
  val baseEndsSlash = base[base.length - 1] == '/'
  val pathStartsSlash = path[0] == '/'
  if baseEndsSlash and pathStartsSlash {
    return Ok(value = base + path.substring(1, path.length - 1))
  }
  if baseEndsSlash or pathStartsSlash {
    return Ok(value = base + path)
  }
  Ok(value = base + "/" + path)
}

func isSafeRelativePath(path: in String): Bool {
  if path.contains("\r") or path.contains("\n") or path.contains("\u{0000}") {
    return false
  }
  // Only the path part: a `..` or a `://` in a query string is data
  // (`/callback?next=https://example.com/x`).
  var pathEnd = path.length
  var i = 0
  while i < path.length {
    if path[i] == '?' or path[i] == '#' {
      pathEnd = i
      i = path.length
    } else {
      i = i + 1
    }
  }
  val pathPart = path.substring(0, pathEnd)
  if pathPart.startsWith("//") or pathPart.contains("://") {
    return false
  }
  // A percent-encoded `/` or `\` separates segments too: a server that
  // decodes it would otherwise see `..%2f..` as two dot-segments.
  var segStart = 0
  var j = 0
  while j <= pathEnd {
    val sepLen = separatorLengthAt(path, j, pathEnd)
    if sepLen > 0 {
      if isDotSegment(path.substring(segStart, j - segStart)) {
        return false
      }
      segStart = j + sepLen
      j = j + sepLen
    } else {
      j = j + 1
    }
  }
  true
}

// The length of the segment separator at `j` (the path end counts as one of
// length 1), or 0: `/`, `\`, or a percent-encoded `%2f`/`%5c`.
func separatorLengthAt(path: in String, j: in Int, pathEnd: in Int): Int {
  if j == pathEnd or path[j] == '/' or path[j] == '\\' {
    return 1
  }
  if path[j] == '%' and j + 3 <= pathEnd {
    val code = path.substring(j, 3).toLower()
    if code == "%2f" or code == "%5c" {
      return 3
    }
  }
  0
}

func isDotSegment(seg: in String): Bool {
  val lower = seg.toLower()
  lower == "." or lower == ".." or lower == "%2e" or lower == "%2e%2e" or lower == ".%2e" or lower == "%2e."
}

async func sendRequest(
  client: in RestClient, method: in HttpMethod, path: in String, body: in Option[String]
): Result[HttpResponse, RestError] {
  val url = match fullUrl(client, path) { case Ok(u) -> u; case Err(e) -> return Err(error = e) }
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = Http(error = e))
    case Ok(parsed) -> {
      var req = match applyAuth(request(method, parsed), client.auth) {
        case Ok(r) -> r
        case Err(e) -> return Err(error = e)
      }
      // `withJsonBody` sets `Content-Type: application/json`
      // unconditionally, so there is no separate content-type header to
      // set here (and, since #6658, `withHeader(req, "Content-Type",
      // ...)` would reject it as a reserved framing header anyway).
      match body {
        case None -> ()
        case Some(json) -> {
          req = withJsonBody(req, json)
        }
      }
      match await sendAsync(req) {
        case Err(e) -> return Err(error = Http(error = e))
        case Ok(response) -> return Ok(value = response)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// HTTP verb operations.
// ---------------------------------------------------------------------------
/// Send a GET to `path` relative to `client.baseUrl`.
///
/// Path may be absolute (starts with `http://` or `https://`) or
/// relative to the base URL (e.g. `/users/42`).
@stable(since = "1.0")
pub async func RestClient.get(client: in RestClient, path: in String): Result[HttpResponse, RestError] {
  return await sendRequest(client, GET, path, None)
}

/// Send a POST with a JSON body to `path`.
@stable(since = "1.0")
pub async func RestClient.post(client: in RestClient, path: in String, body: in String): Result[HttpResponse, RestError] {
  return await sendRequest(client, POST, path, Some(value = body))
}

/// Send a PUT with a JSON body to `path`.
@stable(since = "1.0")
pub async func RestClient.put(client: in RestClient, path: in String, body: in String): Result[HttpResponse, RestError] {
  return await sendRequest(client, PUT, path, Some(value = body))
}

/// Send a PATCH with a JSON body to `path`.
@stable(since = "1.0")
pub async func RestClient.patch(
  client: in RestClient, path: in String, body: in String
): Result[HttpResponse, RestError] {
  return await sendRequest(client, PATCH, path, Some(value = body))
}

/// Send a DELETE to `path`.
@stable(since = "1.0")
pub async func RestClient.delete(client: in RestClient, path: in String): Result[HttpResponse, RestError] {
  return await sendRequest(client, DELETE, path, None)
}

// ---------------------------------------------------------------------------
// Response body helpers.
// ---------------------------------------------------------------------------
/// Read the response body as a raw string.
@stable(since = "1.0")
pub async func RestClient.bodyText(response: in HttpResponse): Result[String, RestError] {
  match await HttpResponse.bodyText(response) {
    case Err(e) -> return Err(error = Http(error = Transport(url = "", error = e)))
    case Ok(text) -> return Ok(value = text)
  }
}

/// Return the HTTP status code from a REST response.
@pure
@stable(since = "1.0")
pub func RestClient.statusCode(response: in HttpResponse): Int {
  return HttpResponse.statusCode(response)
}

/// Return true if the response had a 2xx status.
@pure
@stable(since = "1.0")
pub func RestClient.isSuccess(response: in HttpResponse): Bool {
  return HttpResponse.isSuccess(response)
}

/// Lift a non-2xx response into `RestError.Http(BadStatus(...))`.
///
/// Use this when any non-2xx response is a caller error rather than
/// domain data.
@stable(since = "1.0")
pub func RestClient.ensureSuccess(response: in HttpResponse, url: in String): Result[HttpResponse, RestError] {
  match HttpResponse.ensureSuccess(response) {
    case Err(e) -> return Err(error = Http(error = e))
    case Ok(r) -> return Ok(value = r)
  }
}

// ---------------------------------------------------------------------------
// JSON scalar extractors
// ---------------------------------------------------------------------------
/// Read a top-level string field from a JSON response body.
///
/// # Cost
/// Re-parses the full response body on every call.  When reading more
/// than one field from the same response, prefer `RestClient.json` —
/// it parses once and returns a `JsonDoc` you can walk repeatedly,
/// turning N field reads from O(N^2) into O(N).
///
/// # Errors
/// - `Deserialize`: body is not valid JSON or the field is absent / not a string.
@stable(since = "1.0")
pub async func RestClient.jsonString(response: in HttpResponse, field: in String): Result[String, RestError] {
  val url = ""
  match await HttpResponse.bodyText(response) {
    case Err(e) -> return Err(error = Http(error = Transport(url = url, error = e)))
    case Ok(text) -> {
      try {
        var value: String = ""
        if lyricJsonGetString(text, field, value) {
          return Ok(value = value)
        }
        return Err(error = Deserialize(url = url, reason = "field '" + field + "' missing or not a string"))
      } catch Bug as b {
        return Err(error = Deserialize(url = url, reason = "Failed to parse JSON response: " + b.message))
      }
    }
  }
}

/// Read a top-level integer field from a JSON response body.
///
/// Re-parses the body per call.  Prefer `RestClient.json` when reading
/// more than one field from the same response.
@stable(since = "1.0")
pub async func RestClient.jsonInt(response: in HttpResponse, field: in String): Result[Int, RestError] {
  val url = ""
  match await HttpResponse.bodyText(response) {
    case Err(e) -> return Err(error = Http(error = Transport(url = url, error = e)))
    case Ok(text) -> {
      try {
        var value: Int = 0
        if lyricJsonGetInt(text, field, value) {
          return Ok(value = value)
        }
        return Err(error = Deserialize(url = url, reason = "field '" + field + "' missing or not an integer"))
      } catch Bug as b {
        return Err(error = Deserialize(url = url, reason = "Failed to parse JSON response: " + b.message))
      }
    }
  }
}

/// Read a top-level boolean field from a JSON response body.
///
/// Re-parses the body per call.  Prefer `RestClient.json` when reading
/// more than one field from the same response.
@stable(since = "1.0")
pub async func RestClient.jsonBool(response: in HttpResponse, field: in String): Result[Bool, RestError] {
  val url = ""
  match await HttpResponse.bodyText(response) {
    case Err(e) -> return Err(error = Http(error = Transport(url = url, error = e)))
    case Ok(text) -> {
      try {
        var value: Bool = false
        if lyricJsonGetBool(text, field, value) {
          return Ok(value = value)
        }
        return Err(error = Deserialize(url = url, reason = "field '" + field + "' missing or not a boolean"))
      } catch Bug as b {
        return Err(error = Deserialize(url = url, reason = "Failed to parse JSON response: " + b.message))
      }
    }
  }
}

/// Read the entire response body as a raw JSON string for further
/// inspection via Std.Json.
@stable(since = "1.0")
pub async func RestClient.jsonBody(response: in HttpResponse): Result[String, RestError] {
  val url = ""
  match await HttpResponse.bodyText(response) {
    case Err(e) -> return Err(error = Http(error = Transport(url = url, error = e)))
    case Ok(text) -> return Ok(value = text)
  }
}

/// Read the response body and parse it as JSON exactly once, returning
/// the resulting `JsonDoc`.
///
/// # Cost
/// One parse per call, independent of how many fields you read.  This is
/// the amortized alternative to `jsonString` / `jsonInt` / `jsonBool`,
/// each of which re-parses the body on every invocation (O(N^2) reads).
///
/// # Ownership
/// The returned `JsonDoc` owns a pooled byte buffer; the caller MUST
/// release it via `Std.Json.disposeJson(doc)` — typically with
/// `defer { disposeJson(doc) }` immediately after pattern-matching the
/// `Ok` case.  Leaking the document keeps the buffer out of the array
/// pool until the next GC cycle.
///
/// # Malformed input
/// A malformed JSON body or empty response (such as from 204 No Content)
/// is handled gracefully: any parsing or empty-input exceptions are
/// caught and wrapped as an `Err(Deserialize)` variant.
///
/// # Errors
/// - `Http`: transport / status failure (body could not be read).
/// - `Deserialize`: the response body is not valid JSON or a requested field is missing/mismatched.
///
/// # Usage
/// ```
/// match await RestClient.json(response) {
///   case Ok(doc) -> {
///     defer { disposeJson(doc) }
///     val root = rootElement(doc)
///     val name = getString(getProperty(root, "name"))
///     val age  = getInt32(getProperty(root, "age"))
///     // ... read as many fields as needed from the single parse ...
///   }
///   case Err(e) -> // transport failure
/// }
/// ```
@stable(since = "1.0")
pub async func RestClient.json(response: in HttpResponse): Result[JsonDoc, RestError] {
  val url = ""
  match await HttpResponse.bodyText(response) {
    case Err(e) -> return Err(error = Http(error = Transport(url = url, error = e)))
    case Ok(text) -> {
      try {
        Ok(value = parseJson(text))
      } catch Bug as b {
        Err(error = Deserialize(url = url, reason = "Failed to parse JSON response: " + b.message))
      }
    }
  }
}
