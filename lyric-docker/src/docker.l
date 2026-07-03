//! Docker client — High-level API for Docker daemon operations.
//!
//! Provides convenience functions and types for interacting with the Docker
//! daemon. Abstracts away HTTP details and provides typed results via
//! Result[T, DockerError].
//!
//! The connection is exposed as the opaque `DockerClient` handle so the
//! underlying transport never crosses the package boundary.
//!
//! ```lyric
//! val client = Docker.makeDockerClient()
//! match await Docker.ping(client) {
//!   case Ok(version) -> println("Docker API version: " + version)
//!   case Err(e) -> println("Error: " + e.message)
//! }
//! ```
@runtime_checked
package Lyric.Docker

import Lyric.Docker.Sockets
import Std.Char
import Std.Collections
import Std.Core
import Std.Encoding
import Std.Format
import Std.Http
import Std.String

/// Docker Engine API version this client targets. All request paths are
/// built from this constant so upgrading the API version is a single-place
/// edit instead of a grep-and-replace across every URL literal.
val dockerApiBase: String = "http://docker/v1.40"

/// Opaque handle to a Docker daemon connection. Wraps the underlying HTTP
/// client so callers never touch the extern transport type.
pub opaque type DockerClient {
  handle: Std.Http.HttpClient
}

/// Docker error type — encapsulates HTTP errors with Docker-specific context.
pub record DockerError {
  /// HTTP status code (if available).
  pub statusCode: Option[Int]
  /// Error message.
  pub message: String
  /// Docker error details from response body (if available).
  pub details: String
}

/// Create a new Docker error from an HTTP error.
func fromHttpError(httpError: in HttpError, details: in String): DockerError {
  match httpError {
    case ConnectionFailed(_, message) -> DockerError(statusCode = None, message = message, details = details)
    case BadStatus(_, statusCode) -> DockerError(statusCode = Some(value = statusCode), message = "HTTP " + toString(statusCode), details = details)
    case InvalidUrl(url) -> DockerError(statusCode = None, message = "Invalid Docker URL: " + url, details = details)
    case _ -> DockerError(statusCode = None, message = "Unknown Docker error", details = details)
  }
}

/// Parse `urlStr` into a `Std.Http.Url`, wrapping a parse failure as a
/// `DockerError`. Callers use `resolveDockerUrl(urlStr)?` to collapse the
/// parse-and-propagate boilerplate that was previously repeated at every
/// call site.
func resolveDockerUrl(urlStr: in String): Result[Std.Http.Url, DockerError] {
  match Std.Http.Url.tryFrom(urlStr) {
    case Err(e) -> Err(error = fromHttpError(e, ""))
    case Ok(u) -> Ok(value = u)
  }
}

/// Connect to the Docker daemon, honouring DOCKER_HOST then the default
/// Unix socket.
pub func makeDockerClient(): DockerClient {
  val socketPath = match Lyric.Docker.Sockets.parseDockerHost() {
    case Some(p) -> p
    case None -> Lyric.Docker.Sockets.unixSocketPath()
  }
  DockerClient(handle = Std.Http.clientWithUnixSocket(socketPath))
}

/// Connect to the Docker daemon in rootless mode ($XDG_RUNTIME_DIR/docker.sock).
pub func makeRootlessDockerClient(): Result[DockerClient, DockerError] {
  match Lyric.Docker.Sockets.resolveRootlessSocket() {
    case Ok(socketPath) -> Ok(value = DockerClient(handle = Std.Http.clientWithUnixSocket(socketPath)))
    case Err(message) -> Err(error = DockerError(statusCode = None, message = message, details = ""))
  }
}

/// Connect to the Docker daemon at a custom socket path.
pub func makeDockerClientAt(socketPath: in String): DockerClient
  requires: socketPath.length > 0
{
  DockerClient(handle = Std.Http.clientWithUnixSocket(socketPath))
}

/// Send a request and return the response body text on success, or a
/// `DockerError` (carrying the status code and body) on failure. Shared by
/// every request/response endpoint so the fetch-and-return-body pattern
/// lives in exactly one place.
async func sendAndReadBody(
  client: in DockerClient,
  request: in Std.Http.HttpRequest,
  urlStr: in String,
  failMsg: in String,
): Result[String, DockerError] {
  val sent = await client.handle.send(request)
  val response = match sent { case Err(e) -> return Err(error = fromHttpError(e, "")); case Ok(r) -> r }

  val bodyResult = await response.bodyText()
  val body = match bodyResult {
    case Ok(b) -> b
    case Err(_) -> return Err(error = fromHttpError(ConnectionFailed(url = urlStr, message = "IO error reading response"), ""))
  }

  if response.isSuccess() {
    Ok(value = body)
  } else {
    Err(error = DockerError(statusCode = Some(value = response.statusCode()), message = failMsg, details = body))
  }
}

/// Send a GET request to `urlStr` and return the response body text.
async func fetchBodyText(client: in DockerClient, urlStr: in String, failMsg: in String): Result[String, DockerError] {
  val url = resolveDockerUrl(urlStr)?
  await sendAndReadBody(client, Std.Http.request(Std.Http.GET, url), urlStr, failMsg)
}

/// Raw response bytes paired with the response's `Content-Type` header (if
/// present). `getContainerLogs` uses the header to distinguish a TTY-mode
/// raw byte stream (`application/vnd.docker.raw-stream`) from the framed
/// multiplexed format (`application/vnd.docker.multiplexed-stream`) before
/// deciding whether to run `demultiplexDockerStream`.
record BytesWithContentType {
  bytes: slice[Byte]
  contentType: Option[String]
}

/// Send a request and return the response body bytes (and Content-Type
/// header) on success, or a `DockerError` (carrying the status code and
/// body text) on failure. Mirrors `sendAndReadBody` for endpoints (like
/// `getContainerLogs`) that need the raw byte stream on success but the
/// same text-body error-wrapping on failure.
async func sendAndReadBytes(
  client: in DockerClient,
  request: in Std.Http.HttpRequest,
  urlStr: in String,
  failMsg: in String,
): Result[BytesWithContentType, DockerError] {
  val sent = await client.handle.send(request)
  val response = match sent { case Err(e) -> return Err(error = fromHttpError(e, "")); case Ok(r) -> r }

  if response.isSuccess() {
    val bodyResult = await response.bodyBytes()
    match bodyResult {
      case Ok(bytes) -> Ok(value = BytesWithContentType(bytes = bytes, contentType = response.header("Content-Type")))
      case Err(_) -> Err(error = fromHttpError(ConnectionFailed(url = urlStr, message = "IO error reading response"), ""))
    }
  } else {
    val bodyResult = await response.bodyText()
    val details = match bodyResult { case Ok(b) -> b; case Err(_) -> "" }
    Err(error = DockerError(statusCode = Some(value = response.statusCode()), message = failMsg, details = details))
  }
}

/// Ping the Docker daemon to verify connectivity. Note: unlike the pre-#4503
/// inline implementation (which only read the response body on failure),
/// this routes through `fetchBodyText`/`sendAndReadBody`, which reads the
/// body unconditionally. A body-read IO failure on an otherwise-successful
/// (200) response therefore now surfaces as `Err` instead of the prior
/// `Ok("connected")` -- an edge case that's effectively unreachable against
/// Docker's tiny `/ping` payload, and arguably the more honest behavior
/// (a response whose body can't be read isn't a clean success either way).
pub async func ping(client: in DockerClient): Result[String, DockerError] {
  match await fetchBodyText(client, dockerApiBase + "/ping", "Ping failed") {
    case Ok(_) -> Ok(value = "connected")
    case Err(e) -> Err(error = e)
  }
}

/// Get Docker system information (JSON-formatted).
pub async func systemInfo(client: in DockerClient): Result[String, DockerError] {
  await fetchBodyText(client, dockerApiBase + "/info", "System info failed")
}

/// List all containers (Phase 1 placeholder: returns the JSON array).
pub async func listContainers(client: in DockerClient): Result[String, DockerError] {
  await fetchBodyText(client, dockerApiBase + "/containers/json", "List containers failed")
}

/// List all images (Phase 1 placeholder: returns the JSON array).
pub async func listImages(client: in DockerClient): Result[String, DockerError] {
  await fetchBodyText(client, dockerApiBase + "/images/json", "List images failed")
}

// ─── Container lifecycle ──────────────────────────────────────────────────────
//
// Operations the cloud-agents runner needs: create a container from an image
// with env + volume binds, start/stop/remove it, and fetch its logs. Bodies are
// built as JSON by hand (no reflection); responses are parsed with a small
// field scanner.
/// Escape a string for embedding in a JSON string literal (RFC 8259).
func jsonEscapeValue(s: in String): String {
  val parts: List[String] = newList()
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    val code = c.codePointAt(0)
    if c == "\"" {
      parts.add("\\\"")
    } else if c == "\\" {
      parts.add("\\\\")
    } else if c == "\n" {
      parts.add("\\n")
    } else if c == "\r" {
      parts.add("\\r")
    } else if c == "\t" {
      parts.add("\\t")
    } else if c == "\u{0008}" {
      parts.add("\\b")
    } else if c == "\u{000c}" {
      parts.add("\\f")
    } else if code >= 0 and code < 32 {
      parts.add("\\u00" + Std.Format.hexPad(code, 2))
    } else {
      parts.add(c)
    }
    i = i + 1
  }
  return Std.String.joinList("", parts)
}

/// Render a slice of strings as a JSON array: ["a","b"].
func jsonStringArray(items: in slice[String]): String {
  var acc = "["
  var i = 0
  while i < items.length {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + "\"" + jsonEscapeValue(items[i]) + "\""
    i = i + 1
  }
  return acc + "]"
}

/// Build the JSON body for POST /containers/create.
func createContainerBody(image: in String, env: in slice[String], binds: in slice[String]): String {
  return "{\"Image\":\"" + jsonEscapeValue(image) + "\",\"Env\":" + jsonStringArray(env) + ",\"HostConfig\":{\"Binds\":" +
    jsonStringArray(binds) +
    "}}"
}

/// Unescape a JSON string value (reverse of RFC 8259 escape sequences).
func jsonUnescapeValue(s: in String): String {
  val parts: List[String] = newList()
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if c == "\\" and i + 1 < s.length {
      val next = s.substring(i + 1, 1)
      if next == "\"" {
        parts.add("\"")
        i = i + 2
      } else if next == "\\" {
        parts.add("\\")
        i = i + 2
      } else if next == "/" {
        parts.add("/")
        i = i + 2
      } else if next == "b" {
        parts.add("\u{0008}")
        i = i + 2
      } else if next == "f" {
        parts.add("\u{000c}")
        i = i + 2
      } else if next == "n" {
        parts.add("\n")
        i = i + 2
      } else if next == "r" {
        parts.add("\r")
        i = i + 2
      } else if next == "t" {
        parts.add("\t")
        i = i + 2
      } else if next == "u" and i + 5 < s.length {
        val hexStr = s.substring(i + 2, 4)
        val codeOpt = Int.parse(hexStr, 16)
        match codeOpt {
          case Some(code) -> {
            parts.add("" + Std.Char.fromInt(code))
            i = i + 6
          }
          case None -> {
            parts.add(c)
            i = i + 1
          }
        }
      } else {
        parts.add(c)
        i = i + 1
      }
    } else {
      parts.add(c)
      i = i + 1
    }
  }
  return Std.String.joinList("", parts)
}

/// `true` iff `pos` is a field-key position in `json`: the nearest
/// non-whitespace character before `pos` is `{` or `,`. Used to reject
/// matches of a quoted field name that occur inside an earlier string
/// value rather than at an actual key position. Known limitation: a `,`
/// separating array elements (e.g. `["retry", "Id"]`) also satisfies this
/// check, since there's no depth tracking to distinguish it from an
/// object-key comma. `extractJsonField`'s only caller searches for `"Id"`
/// in a flat container-create response body, where this collision doesn't
/// arise; a caller extracting a field name that could plausibly also
/// appear as an array element would need a depth-tracking rewrite first.
func isFieldKeyPosition(json: in String, pos: in Int): Bool {
  var i = pos - 1
  while i >= 0 {
    val c = json.substring(i, 1)
    if c == " " or c == "\t" or c == "\n" or c == "\r" {
      i = i - 1
    } else {
      return c == "{" or c == ","
    }
  }
  false
}

/// Extract a quoted string field's value from a JSON object, or "" if absent.
/// Returns the unescaped value. Skips occurrences of the quoted field name
/// that fall inside an earlier string value (not at a key position).
func extractJsonField(json: in String, field: in String): String {
  val target = "\"" + field + "\""
  val jsonLen = json.length
  var searchFrom = 0
  while searchFrom < jsonLen {
    val relPos = json.substring(searchFrom).indexOf(target)
    if relPos < 0 {
      return ""
    }
    val pos = searchFrom + relPos
    if isFieldKeyPosition(json, pos) {
      var i = pos + target.length
      var inValue = false
      var start = 0
      while i < jsonLen {
        val c = json.substring(i, 1)
        if not inValue {
          if c == "\"" {
            inValue = true
            start = i + 1
          }
          i = i + 1
        } else {
          if c == "\"" {
            val rawValue = json.substring(start, i - start)
            return jsonUnescapeValue(rawValue)
          } else if c == "\\" {
            i = i + 2
          } else {
            i = i + 1
          }
        }
      }
      return ""
    }
    searchFrom = pos + 1
  }
  ""
}

/// Validate a Docker container ID: must be a lowercase hex string of length 12
/// (short form) or 64 (full SHA-256), as returned by the Docker API.  Rejects
/// values containing path-separator or query characters that would silently
/// reach unintended API endpoints. Public so callers can validate a
/// caller-supplied container ID (e.g. from user input or a config file)
/// before it reaches startContainer/stopContainer/removeContainer/
/// getContainerLogs, unlike jsonEscapeValue/jsonUnescapeValue which are
/// internal JSON-serialization plumbing with no meaning outside this file.
pub func isValidContainerId(id: in String): Bool {
  val len = id.length
  if len != 12 and len != 64 {
    return false
  }
  var i = 0
  while i < len {
    val c = id.substring(i, 1)
    if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f")) {
      return false
    }
    i = i + 1
  }
  true
}

/// Send a request expecting only success/failure (no useful body on success).
async func sendExpectSuccess(
  client: in DockerClient,
  urlStr: in String,
  method: in Std.Http.HttpMethod,
  failMsg: in String,
): Result[Unit, DockerError] {
  val url = resolveDockerUrl(urlStr)?
  val sent = await client.handle.send(Std.Http.request(method, url))
  val response = match sent { case Err(e) -> return Err(error = fromHttpError(e, "")); case Ok(r) -> r }

  if response.isSuccess() {
    Ok(value = ())
  } else {
    val statusCode = response.statusCode()
    val bodyResult = await response.bodyText()
    val details = match bodyResult { case Ok(b) -> b; case Err(_) -> "" }
    Err(error = DockerError(statusCode = Some(value = statusCode), message = failMsg, details = details))
  }
}

/// Create a container from an image with environment variables and volume binds.
/// Returns the new container id.
pub async func createContainer(
  client: in DockerClient, image: in String, env: in slice[String], binds: in slice[String]
): Result[String, DockerError] {
  val urlStr = dockerApiBase + "/containers/create"
  val url = resolveDockerUrl(urlStr)?
  val request = Std.Http.withJsonBody(Std.Http.request(Std.Http.POST, url), createContainerBody(image, env, binds))
  match await sendAndReadBody(client, request, urlStr, "Create container failed") {
    case Ok(body) -> {
      val id = extractJsonField(body, "Id")
      if id.length > 0 {
        Ok(value = id)
      } else {
        Err(error = DockerError(statusCode = None, message = "Create container returned no Id", details = body))
      }
    }
    case Err(e) -> Err(error = e)
  }
}

/// Start a created container.
pub async func startContainer(client: in DockerClient, containerId: in String): Result[Unit, DockerError] {
  if not isValidContainerId(containerId) {
    return Err(error = DockerError(statusCode = None, message = "Invalid container ID", details = containerId))
  }
  await sendExpectSuccess(client, dockerApiBase + "/containers/" + containerId + "/start", Std.Http.POST, "Start container failed")
}

/// Stop a running container.
pub async func stopContainer(client: in DockerClient, containerId: in String): Result[Unit, DockerError] {
  if not isValidContainerId(containerId) {
    return Err(error = DockerError(statusCode = None, message = "Invalid container ID", details = containerId))
  }
  await sendExpectSuccess(client, dockerApiBase + "/containers/" + containerId + "/stop", Std.Http.POST, "Stop container failed")
}

/// Remove a container.
pub async func removeContainer(client: in DockerClient, containerId: in String): Result[Unit, DockerError] {
  if not isValidContainerId(containerId) {
    return Err(error = DockerError(statusCode = None, message = "Invalid container ID", details = containerId))
  }
  await sendExpectSuccess(client, dockerApiBase + "/containers/" + containerId + "?force=true", Std.Http.DELETE, "Remove container failed")
}

/// Demultiplex a raw Docker multiplexed stream into a UTF-8 String.
/// Accepts the raw bytes of a multiplexed stream and decodes combined stdout/stderr.
/// `Err` carries a description when the demultiplexed bytes are not valid
/// UTF-8; an empty (or entirely-non-stdout/stderr) stream decodes to `Ok("")`.
pub func demultiplexDockerStream(bytes: in slice[Byte]): Result[String, String] {
  val len = bytes.length
  val outBytes: List[Byte] = newList()
  var i = 0
  while i + 8 <= len {
    val streamType = bytes[i]

    val size_b3 = bytes[i + 4]
    val size_b2 = bytes[i + 5]
    val size_b1 = bytes[i + 6]
    val size_b0 = bytes[i + 7]

    val size = size_b3.toInt() * 16777216 + size_b2.toInt() * 65536 + size_b1.toInt() * 256 + size_b0.toInt()

    if i + 8 + size > len {
      break
    }

    if streamType == 1u8 or streamType == 2u8 {
      var j = 0
      while j < size {
        outBytes.add(bytes[i + 8 + j])
        j = j + 1
      }
    }

    i = i + 8 + size
  }

  match Std.Encoding.tryDecodeUtf8(outBytes.toArray()) {
    case Some(s) -> Ok(value = s)
    case None -> Err(error = "Demultiplexed Docker stream bytes are not valid UTF-8")
  }
}

/// Fetch a container's combined stdout/stderr logs.
///
/// Docker sets the response `Content-Type` to
/// `application/vnd.docker.raw-stream` when the container was started with
/// a pseudo-TTY (`Tty: true`) and to
/// `application/vnd.docker.multiplexed-stream` otherwise. A TTY-mode
/// response is a raw byte stream and must not be run through
/// `demultiplexDockerStream`, which would misinterpret the bytes as
/// 8-byte framing headers; it is decoded as UTF-8 directly instead.
pub async func getContainerLogs(client: in DockerClient, containerId: in String): Result[String, DockerError] {
  if not isValidContainerId(containerId) {
    return Err(error = DockerError(statusCode = None, message = "Invalid container ID", details = containerId))
  }
  val urlStr = dockerApiBase + "/containers/" + containerId + "/logs?stdout=true&stderr=true"
  val url = resolveDockerUrl(urlStr)?
  val responseResult = await sendAndReadBytes(client, Std.Http.request(Std.Http.GET, url), urlStr, "Get container logs failed")
  val response = match responseResult { case Err(e) -> return Err(error = e); case Ok(r) -> r }

  // A prefix match rather than exact equality (#4767): a future Docker
  // Engine API version could add media-type parameters (e.g. "; version=1.41")
  // to this Content-Type header, and an exact match would silently fall
  // through to demultiplexDockerStream, misinterpreting a raw TTY byte
  // stream as framed multiplexed data.
  val isRawStream = match response.contentType {
    case Some(ct) -> ct.startsWith("application/vnd.docker.raw-stream")
    case None -> false
  }

  if isRawStream {
    match Std.Encoding.tryDecodeUtf8(response.bytes) {
      case Some(s) -> Ok(value = s)
      case None -> Err(error = DockerError(statusCode = None, message = "Failed to decode container logs as UTF-8", details = ""))
    }
  } else {
    match demultiplexDockerStream(response.bytes) {
      case Ok(s) -> Ok(value = s)
      case Err(reason) -> Err(error = DockerError(statusCode = None, message = "Failed to decode container logs as UTF-8", details = reason))
    }
  }
}
