// std/rest.l - Typed REST client built on top of Std.Http.
//
// RestClient holds a base URL, default headers, and an optional auth
// strategy.  Every operation returns Result[T, RestError] where T is the
// caller's expected response type.  JSON bodies are read via Std.Json;
// non-JSON response bodies surface as RestError.Deserialize.
//
// This is bootstrap-grade: generic typed body deserialization is
// hand-rolled per scalar field.  A derive(Json)-based approach lands
// when the derive pipeline is complete.

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
@stable(since="1.0")
pub union RestError {
  case Http(error: HttpError)
  case Deserialize(url: String, reason: String)
}

/// Human-readable message for a RestError.
@pure
@stable(since="1.0")
pub func RestError.message(e: in RestError): String {
  match e {
    case Http(error) -> HttpError.message(error)
    case Deserialize(url, reason) ->
      "deserialize error from " + url + ": " + reason
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
@stable(since="1.0")
pub enum RestAuth {
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
@stable(since="1.0")
pub opaque type RestClient {
  baseUrl: String
  auth: RestAuth
  defaultHeaders: String
}

/// Construct a RestClient with a base URL and no auth.
///
/// # Preconditions
/// - `baseUrl` must be a valid HTTP(S) URL (validated by `Url.tryFrom`
///   at call time, not here — eagerly-constructed clients avoid
///   redundant validation on each request).
@stable(since="1.0")
pub func RestClient.create(baseUrl: in String): RestClient {
  return RestClient(
    baseUrl = baseUrl,
    auth = None_,
    defaultHeaders = ""
  )
}

/// Attach an authentication strategy to a RestClient.
@pure
@stable(since="1.0")
pub func RestClient.withAuth(client: in RestClient, auth: in RestAuth): RestClient {
  return RestClient(
    baseUrl = client.baseUrl,
    auth = auth,
    defaultHeaders = client.defaultHeaders
  )
}

// ---------------------------------------------------------------------------
// Internal helpers.
// ---------------------------------------------------------------------------

func applyAuth(req: in HttpRequest, auth: in RestAuth): HttpRequest {
  match auth {
    case None_ -> req
    case Bearer(token) ->
      withHeader(req, "Authorization", "Bearer " + token)
    case Basic(credentials) ->
      withHeader(req, "Authorization", "Basic " + credentials)
    case ApiKey(headerName, headerValue) ->
      withHeader(req, headerName, headerValue)
  }
}

func fullUrl(client: in RestClient, path: in String): String {
  val base = client.baseUrl
  if path.length == 0 {
    return base
  }
  val lastBase = base.length - 1
  val baseEndsSlash = base.charAt(lastBase) == '/'
  val pathStartsSlash = path.charAt(0) == '/'
  if baseEndsSlash and pathStartsSlash {
    return base + path.substring(1, path.length)
  }
  if baseEndsSlash or pathStartsSlash {
    return base + path
  }
  return base + "/" + path
}

async func sendRequest(
  client: in RestClient,
  method: in HttpMethod,
  path: in String,
  body: in Option[String],
  contentType: in String
): Result[HttpResponse, RestError] {
  val url = fullUrl(client, path)
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = Http(error = e))
    case Ok(parsed) ->
      var req = request(method, parsed)
      req = applyAuth(req, client.auth)
      match body {
        case None -> ()
        case Some(json) ->
          req = withHeader(req, "Content-Type", contentType)
          req = withJsonBody(req, json)
      }
      match await sendAsync(req) {
        case Err(e) -> return Err(error = Http(error = e))
        case Ok(response) -> return Ok(value = response)
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
@stable(since="1.0")
pub async func RestClient.get(
  client: in RestClient,
  path: in String
): Result[HttpResponse, RestError] {
  return await sendRequest(client, GET, path, None, "")
}

/// Send a POST with a JSON body to `path`.
@stable(since="1.0")
pub async func RestClient.post(
  client: in RestClient,
  path: in String,
  body: in String
): Result[HttpResponse, RestError] {
  return await sendRequest(client, POST, path, Some(value = body), "application/json")
}

/// Send a PUT with a JSON body to `path`.
@stable(since="1.0")
pub async func RestClient.put(
  client: in RestClient,
  path: in String,
  body: in String
): Result[HttpResponse, RestError] {
  return await sendRequest(client, PUT, path, Some(value = body), "application/json")
}

/// Send a PATCH with a JSON body to `path`.
@stable(since="1.0")
pub async func RestClient.patch(
  client: in RestClient,
  path: in String,
  body: in String
): Result[HttpResponse, RestError] {
  return await sendRequest(client, PATCH, path, Some(value = body), "application/json")
}

/// Send a DELETE to `path`.
@stable(since="1.0")
pub async func RestClient.delete(
  client: in RestClient,
  path: in String
): Result[HttpResponse, RestError] {
  return await sendRequest(client, DELETE, path, None, "")
}

// ---------------------------------------------------------------------------
// Response body helpers.
// ---------------------------------------------------------------------------

/// Read the response body as a raw string.
@stable(since="1.0")
pub async func RestClient.bodyText(
  response: in HttpResponse
): Result[String, RestError] {
  match await HttpResponse.bodyText(response) {
    case Err(e) ->
      return Err(error = Http(error = Transport(url = "", error = e)))
    case Ok(text) -> return Ok(value = text)
  }
}

/// Return the HTTP status code from a REST response.
@pure
@stable(since="1.0")
pub func RestClient.statusCode(response: in HttpResponse): Int {
  return HttpResponse.statusCode(response)
}

/// Return true if the response had a 2xx status.
@pure
@stable(since="1.0")
pub func RestClient.isSuccess(response: in HttpResponse): Bool {
  return HttpResponse.isSuccess(response)
}

/// Lift a non-2xx response into `RestError.Http(BadStatus(...))`.
///
/// Use this when any non-2xx response is a caller error rather than
/// domain data.
@stable(since="1.0")
pub func RestClient.ensureSuccess(
  response: in HttpResponse,
  url: in String
): Result[HttpResponse, RestError] {
  match HttpResponse.ensureSuccess(response) {
    case Err(e) -> return Err(error = Http(error = e))
    case Ok(r) -> return Ok(value = r)
  }
}

// ---------------------------------------------------------------------------
// JSON scalar extractors — bootstrap-grade until derive(Json) lands.
// ---------------------------------------------------------------------------

/// Read a top-level string field from a JSON response body.
///
/// # Errors
/// - `Deserialize`: body is not valid JSON or the field is absent / not a string.
@stable(since="1.0")
pub async func RestClient.jsonString(
  response: in HttpResponse,
  field: in String
): Result[String, RestError] {
  val url = ""
  match await HttpResponse.bodyText(response) {
    case Err(e) ->
      return Err(error = Http(error = Transport(url = url, error = e)))
    case Ok(text) ->
      var value: String = ""
      if lyricJsonGetString(text, field, value) {
        return Ok(value = value)
      }
      return Err(error = Deserialize(url = url, reason = "field '" + field + "' missing or not a string"))
  }
}

/// Read a top-level integer field from a JSON response body.
@stable(since="1.0")
pub async func RestClient.jsonInt(
  response: in HttpResponse,
  field: in String
): Result[Int, RestError] {
  val url = ""
  match await HttpResponse.bodyText(response) {
    case Err(e) ->
      return Err(error = Http(error = Transport(url = url, error = e)))
    case Ok(text) ->
      var value: Int = 0
      if lyricJsonGetInt(text, field, value) {
        return Ok(value = value)
      }
      return Err(error = Deserialize(url = url, reason = "field '" + field + "' missing or not an integer"))
  }
}

/// Read a top-level boolean field from a JSON response body.
@stable(since="1.0")
pub async func RestClient.jsonBool(
  response: in HttpResponse,
  field: in String
): Result[Bool, RestError] {
  val url = ""
  match await HttpResponse.bodyText(response) {
    case Err(e) ->
      return Err(error = Http(error = Transport(url = url, error = e)))
    case Ok(text) ->
      var value: Bool = false
      if lyricJsonGetBool(text, field, value) {
        return Ok(value = value)
      }
      return Err(error = Deserialize(url = url, reason = "field '" + field + "' missing or not a boolean"))
  }
}

/// Read the entire response body as a raw JSON string for further
/// inspection via Std.Json.
@stable(since="1.0")
pub async func RestClient.jsonBody(
  response: in HttpResponse
): Result[String, RestError] {
  val url = ""
  match await HttpResponse.bodyText(response) {
    case Err(e) ->
      return Err(error = Http(error = Transport(url = url, error = e)))
    case Ok(text) ->
      return Ok(value = text)
  }
}
