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
import Std.Environment
import Std.Format
import Std.Http
import Std.Parse
import Std.String
import Std.Task

/// Docker Engine API version this client targets, without a host. Unix-socket
/// clients use this directly with the placeholder host "docker" (ignored by
/// the socket ConnectCallback); TCP clients (`makeDockerClientTcp`) build
/// their own `apiBase` against the real host:port instead, since a
/// real-transport HttpClient DOES resolve/connect to the URL's host.
val dockerApiVersion: String = "/v1.40"

/// Opaque handle to a Docker daemon connection. Wraps the underlying HTTP
/// client so callers never touch the extern transport type. `apiBase` is
/// per-client (not a shared constant) because a TCP-connected client needs
/// requests addressed to its real host:port, unlike a Unix-socket client
/// whose placeholder host is ignored by the socket ConnectCallback.
pub opaque type DockerClient {
  handle: Std.Http.HttpClient
  apiBase: String
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
    case BadStatus(_, statusCode) -> DockerError(
      statusCode = Some(value = statusCode),
      message = "HTTP " + toString(statusCode),
      details = details
    )
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
/// Unix socket. Non-panicking form of `makeDockerClient`.
///
/// A `tcp://host:port` DOCKER_HOST routes to `makeDockerClientTcp` rather
/// than being silently ignored in favour of the default Unix socket — the
/// previous behaviour when DOCKER_HOST named a transport `parseDockerHost`
/// doesn't understand. DOCKER_HOST is environment input, not a programming
/// error, so a malformed `tcp://` value (one that fails `isHostPort`) is
/// reported as `Err` naming DOCKER_HOST and the bad value, rather than
/// tripping `makeDockerClientTcp`'s `requires: isHostPort(hostPort)`
/// precondition and crashing the process.
@stable(since = "0.1")
pub func tryMakeDockerClient(): Result[DockerClient, DockerError] {
  match Std.Environment.getVar("DOCKER_HOST") {
    case Ok(dockerHost) -> match Lyric.Docker.Sockets.parseTcpDockerHost(dockerHost) {
      case Some(hostPort) -> {
        if not isHostPort(hostPort) {
          return Err(
            error = DockerError(
              statusCode = None,
              message = "DOCKER_HOST is not a valid tcp:// host:port",
              details = "DOCKER_HOST=" + dockerHost
            )
          )
        }
        return Ok(value = makeDockerClientTcp(hostPort))
      }
      case None -> ()
    }
    case Err(_) -> ()
  }
  val socketPath = match Lyric.Docker.Sockets.parseDockerHost() {
    case Some(p) -> p
    case None -> Lyric.Docker.Sockets.unixSocketPath()
  }
  return Ok(
    value = DockerClient(
      handle = Std.Http.clientWithUnixSocket(socketPath),
      apiBase = "http://docker" + dockerApiVersion
    )
  )
}

/// Connect to the Docker daemon, honouring DOCKER_HOST then the default
/// Unix socket.
///
/// Panics on a malformed `tcp://` DOCKER_HOST (a value that fails
/// `isHostPort` after the `tcp://` prefix) — use `tryMakeDockerClient` for
/// the non-panicking form that reports a malformed DOCKER_HOST as `Err`
/// instead.
@stable(since = "0.1")
pub func makeDockerClient(): DockerClient {
  match tryMakeDockerClient() {
    case Ok(client) -> client
    case Err(e) -> panic(e.message + ": " + e.details)
  }
}

/// Connect to the Docker daemon in rootless mode ($XDG_RUNTIME_DIR/docker.sock).
pub func makeRootlessDockerClient(): Result[DockerClient, DockerError] {
  match Lyric.Docker.Sockets.resolveRootlessSocket() {
    case Ok(socketPath) -> Ok(
      value = DockerClient(
        handle = Std.Http.clientWithUnixSocket(socketPath),
        apiBase = "http://docker" + dockerApiVersion
      )
    )
    case Err(message) -> Err(error = DockerError(statusCode = None, message = message, details = ""))
  }
}

/// Connect to the Docker daemon at a custom socket path.
pub func makeDockerClientAt(socketPath: in String): DockerClient
  requires: socketPath.length > 0
{
  DockerClient(handle = Std.Http.clientWithUnixSocket(socketPath), apiBase = "http://docker" + dockerApiVersion)
}

/// True when `c` is an ASCII hexadecimal digit (`0`-`9`, `a`-`f`, `A`-`F`).
@pure
func isHexDigitChar(c: in Char): Bool {
  (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')
}

/// True when `s` is a plausible IPv6 literal's *interior* (between the `[`
/// and `]` of a bracketed address): non-empty, at least one `:`, and every
/// character a hex digit, `:`, or `.` (the latter for an IPv4-mapped tail
/// like `::ffff:192.0.2.1`). Not a full IPv6 grammar — just enough to reject
/// injected path/query/scheme characters.
@pure
func isPlausibleIpv6Literal(s: in String): Bool {
  val len = s.length
  if len == 0 {
    return false
  }
  var i = 0
  var ok = true
  var hasColon = false
  while i < len and ok {
    val c = s[i]
    if c == ':' {
      hasColon = true
    } else if not (isHexDigitChar(c) or c == '.') {
      ok = false
    }
    i = i + 1
  }
  ok and hasColon
}

/// True when `s` is a plausible hostname or IPv4 literal: non-empty,
/// every character alphanumeric, `.`, or `-`, and both the first and last
/// character alphanumeric. Not a full RFC 1123 grammar — just enough to
/// reject `/`, `?`, `@`, and other characters that would inject into a URL.
@pure
func isPlausibleHostLiteral(s: in String): Bool {
  val len = s.length
  if len == 0 {
    return false
  }
  var i = 0
  var ok = true
  while i < len and ok {
    val c = s[i]
    if not (Std.Char.isAsciiLetterOrDigit(c) or c == '.' or c == '-') {
      ok = false
    }
    i = i + 1
  }
  ok and Std.Char.isAsciiLetterOrDigit(s[0]) and Std.Char.isAsciiLetterOrDigit(s[len - 1])
}

/// True when `s` is 1-5 ASCII digits spelling an integer in `1..=65535`.
@pure
func isValidPortDigits(s: in String): Bool {
  val len = s.length
  if len == 0 or len > 5 {
    return false
  }
  var i = 0
  var value = 0
  var ok = true
  while i < len and ok {
    val c = s[i]
    if c < '0' or c > '9' {
      ok = false
    } else {
      value = value * 10 + (Std.Char.toInt(c) - Std.Char.toInt('0'))
    }
    i = i + 1
  }
  ok and value >= 1 and value <= 65535
}

/// True when `hostPort` has the shape `makeDockerClientTcp` requires: a
/// hostname or IPv4 literal, or a bracketed IPv6 literal (`[::1]`),
/// followed by `:` and a port `1..=65535`. Rejects `/`, `?`, `@`, embedded
/// scheme text, or anything else that would inject into `apiBase`.
@pure
@stable(since = "0.1")
pub func isHostPort(hostPort: in String): Bool {
  val len = hostPort.length
  if len == 0 {
    return false
  }
  if hostPort[0] == '[' {
    match Std.String.indexOf(hostPort, "]") {
      case None -> false
      case Some(closeIdx) -> {
        if closeIdx <= 1 or closeIdx + 1 >= len or hostPort[closeIdx + 1] != ':' {
          false
        } else {
          isPlausibleIpv6Literal(hostPort.substring(1, closeIdx - 1)) and
            isValidPortDigits(hostPort.substring(closeIdx + 2, len - closeIdx - 2))
        }
      }
    }
  } else {
    match Std.String.lastIndexOf(hostPort, ":") {
      case None -> false
      case Some(colonIdx) -> {
        if colonIdx == 0 or colonIdx == len - 1 {
          false
        } else {
          isPlausibleHostLiteral(hostPort.substring(0, colonIdx)) and
            isValidPortDigits(hostPort.substring(colonIdx + 1, len - colonIdx - 1))
        }
      }
    }
  }
}

/// Connect to the Docker daemon over plain TCP (`host:port`, e.g.
/// `"127.0.0.1:2375"`) instead of a Unix socket. Unlike the Unix-socket
/// constructors, this uses `Std.Http.defaultClient()` — a real HttpClient
/// that resolves and connects to `hostPort` directly — since there is no
/// socket ConnectCallback to hide the host behind.
///
/// A general alternative for daemons exposed over TCP (`dockerd -H
/// tcp://host:port`), not a workaround: `Std.Http.clientWithUnixSocket`
/// (used by every other constructor here) is pure Lyric (D-progress-686,
/// `lyric-stdlib/std/_kernel/http_host.l`) and works the same in any
/// standalone compiled program, not only inside the `lyric` CLI's own
/// process — the earlier CLI-host-assembly dependency this doc comment used
/// to describe (docs/59-compiler-stdlib-deep-review.md §7.3) no longer
/// applies.
pub func makeDockerClientTcp(hostPort: in String): DockerClient
  requires: hostPort.length > 0
  requires: isHostPort(hostPort)
{
  DockerClient(handle = Std.Http.defaultClient(), apiBase = "http://" + hostPort + dockerApiVersion)
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

/// Like `sendAndReadBody`, but bounds the wait for a response with
/// `timeoutSec` (converted to milliseconds) via the client's own
/// `sendWithCancel` — honouring the same per-client configuration (Unix
/// socket, redirects, etc.) that `send` does, unlike the free
/// `Std.Http.sendWithTimeoutAsync` (currently `@experimental` and known to
/// throw at runtime on `--target dotnet`, #6367; not used here). Cancels the
/// pending HTTP request once `timeoutSec` elapses — it does not, and
/// cannot, bound how long the Docker daemon itself takes to respond. Used by
/// `waitContainer`, whose `/wait` endpoint otherwise blocks server-side for
/// as long as the container runs.
async func sendAndReadBodyWithTimeout(
  client: in DockerClient,
  request: in Std.Http.HttpRequest,
  urlStr: in String,
  failMsg: in String,
  timeoutSec: in Int,
): Result[String, DockerError]
  requires: timeoutSec > 0
{
  val src = Std.Task.makeCancelSourceTimeout(timeoutSec * 1000)
  val token = Std.Task.sourceToken(src)
  val sent = await client.handle.sendWithCancel(request, token)
  Std.Task.disposeSource(src)
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

/// Send a request and return the response body bytes on success, or a
/// `DockerError` (carrying the status code and body text) on failure.
/// Mirrors `sendAndReadBody` for endpoints (like `getContainerLogs`) that
/// need the raw byte stream on success but the same text-body error-wrapping
/// on failure. Does not surface the response's `Content-Type` header: it was
/// previously used by `getContainerLogs` to guess raw-vs-multiplexed, but
/// that header is not a reliable signal for that decision (see
/// `getContainerLogs`'s doc comment) and every current caller only needs the
/// bytes.
async func sendAndReadBytes(
  client: in DockerClient,
  request: in Std.Http.HttpRequest,
  urlStr: in String,
  failMsg: in String,
): Result[slice[Byte], DockerError] {
  val sent = await client.handle.send(request)
  val response = match sent { case Err(e) -> return Err(error = fromHttpError(e, "")); case Ok(r) -> r }

  if response.isSuccess() {
    val bodyResult = await response.bodyBytes()
    match bodyResult {
      case Ok(bytes) -> Ok(value = bytes)
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
/// Docker's tiny `/_ping` payload, and arguably the more honest behavior
/// (a response whose body can't be read isn't a clean success either way).
pub async func ping(client: in DockerClient): Result[String, DockerError] {
  match await fetchBodyText(client, client.apiBase + "/_ping", "Ping failed") {
    case Ok(_) -> Ok(value = "connected")
    case Err(e) -> Err(error = e)
  }
}

/// Get Docker system information (JSON-formatted).
pub async func systemInfo(client: in DockerClient): Result[String, DockerError] {
  await fetchBodyText(client, client.apiBase + "/info", "System info failed")
}

/// List all containers (Phase 1 placeholder: returns the JSON array).
pub async func listContainers(client: in DockerClient): Result[String, DockerError] {
  await fetchBodyText(client, client.apiBase + "/containers/json", "List containers failed")
}

/// List all images (Phase 1 placeholder: returns the JSON array).
pub async func listImages(client: in DockerClient): Result[String, DockerError] {
  await fetchBodyText(client, client.apiBase + "/images/json", "List images failed")
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
    val code = Std.Char.toInt(s[i])
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

/// True when every entry of `env` contains a `=` (the shape Docker's
/// `HostConfig.Env`/top-level `Env` expects: `KEY=VALUE`). Vacuously true
/// for an empty slice.
@pure
func allEnvEntriesHaveEquals(env: in slice[String]): Bool {
  var i = 0
  var ok = true
  while i < env.length and ok {
    if not env[i].contains("=") {
      ok = false
    }
    i = i + 1
  }
  ok
}

/// True when `bind` has the shape Docker's `HostConfig.Binds` expects:
/// `src:dst` or `src:dst:mode`, with every colon-separated part non-empty.
@pure
func isValidBindShape(bindSpec: in String): Bool {
  val parts = bindSpec.split(":")
  if parts.length != 2 and parts.length != 3 {
    return false
  }
  var i = 0
  var ok = true
  while i < parts.length and ok {
    if parts[i].length == 0 {
      ok = false
    }
    i = i + 1
  }
  ok
}

/// True when every entry of `binds` satisfies `isValidBindShape`. Vacuously
/// true for an empty slice.
@pure
func allBindsValid(binds: in slice[String]): Bool {
  var i = 0
  var ok = true
  while i < binds.length and ok {
    if not isValidBindShape(binds[i]) {
      ok = false
    }
    i = i + 1
  }
  ok
}

/// Build the JSON body for POST /containers/create, optionally pinning the
/// container's NetworkMode (e.g. "none" for full isolation, or a named
/// Docker network). NetworkMode is only emitted when set, so callers that
/// don't care keep the Docker default (bridge) — an empty networkMode omits
/// the field entirely rather than emitting `"NetworkMode":""`.
/// Public so tests can exercise `jsonEscapeValue`'s control-character and
/// named-escape branches without a live Docker daemon (#4535).
pub func createContainerBodyWithNetwork(
  image: in String,
  env: in slice[String],
  binds: in slice[String],
  networkMode: in String,
): String
  requires: image.length > 0
  requires: allEnvEntriesHaveEquals(env)
  requires: allBindsValid(binds)
{
  var hostConfig = "\"Binds\":" + jsonStringArray(binds)
  if networkMode.length > 0 {
    hostConfig = hostConfig + ",\"NetworkMode\":\"" + jsonEscapeValue(networkMode) + "\""
  }
  return "{\"Image\":\"" + jsonEscapeValue(image) + "\",\"Env\":" + jsonStringArray(env) + ",\"HostConfig\":{" +
    hostConfig +
    "}}"
}

/// Build the JSON body for POST /containers/create with the Docker default
/// network. Public so tests can exercise `jsonEscapeValue`'s control-character
/// and named-escape branches without a live Docker daemon (#4535).
pub func createContainerBody(image: in String, env: in slice[String], binds: in slice[String]): String {
  return createContainerBodyWithNetwork(image, env, binds, "")
}

/// Parse a 4-character hexadecimal string into its integer value, or
/// `None` if any character isn't a valid hex digit. Decodes a `\uXXXX`
/// JSON escape's payload; Lyric's stdlib has no radix-aware integer
/// parser, so this composes `Std.Char.hexDigitValue` per digit.
func parseHex4Digits(hex: in String): Option[Int] {
  if hex.length != 4 {
    return None
  }
  var value = 0
  var i = 0
  while i < 4 {
    match Std.Char.hexDigitValue(hex[i]) {
      case Some(d) -> {
        value = value * 16 + d
      }
      case None -> return None
    }
    i = i + 1
  }
  Some(value = value)
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
        val codeOpt = parseHex4Digits(hexStr)
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

/// Like `.indexOf`, but resumes scanning at `from` instead of allocating a
/// substring of the tail on every call. `.indexOf` on the tail costs a fresh
/// O(remaining-length) copy per call site; a caller re-scanning past false
/// positions in a loop (see `extractJsonField`) turns that into O(n^2) over
/// the whole string. This scans char-by-char from `from`, so each candidate
/// position only costs O(target.length) instead of O(remaining json length).
func indexOfFrom(s: in String, target: in String, from: in Int): Int {
  val sLen = s.length
  val tLen = target.length
  if tLen == 0 {
    return from
  }
  var i = from
  while i + tLen <= sLen {
    var j = 0
    var matched = true
    while j < tLen {
      if s[i + j] != target[j] {
        matched = false
        j = tLen
      } else {
        j = j + 1
      }
    }
    if matched {
      return i
    }
    i = i + 1
  }
  -1
}

/// Extract a quoted string field's value from a JSON object, or "" if absent.
/// Returns the unescaped value. Skips occurrences of the quoted field name
/// that fall inside an earlier string value (not at a key position).
/// Public so tests can exercise `jsonUnescapeValue`'s `\uXXXX` decode branch
/// against hand-built response bodies without a live Docker daemon (#4535).
pub func extractJsonField(json: in String, field: in String): String {
  val target = "\"" + field + "\""
  val jsonLen = json.length
  var searchFrom = 0
  while searchFrom < jsonLen {
    val pos = indexOfFrom(json, target, searchFrom)
    if pos < 0 {
      return ""
    }
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

/// `true` for the four JSON insignificant-whitespace characters (RFC 8259
/// §2: space, tab, LF, CR). Shared by `extractJsonIntField` and
/// `jsonFieldIsObject` so both tolerate the same whitespace between a
/// field's colon and its value — Docker returns compact JSON on `/wait` so
/// this rarely matters in practice, but a pretty-printed response or a
/// proxy in between shouldn't silently break field extraction.
func isJsonWhitespace(c: in String): Bool {
  c == " " or c == "\t" or c == "\n" or c == "\r"
}

/// Extract an integer field's value from a JSON object, or `None` if the
/// field is absent or not a well-formed JSON number. Mirrors
/// `extractJsonField`'s key-position disambiguation (`isFieldKeyPosition`)
/// but reads a bare number instead of a quoted string, for endpoints like
/// `/wait` that respond `{"StatusCode":0,"Error":null}`.
/// Public so tests can exercise it directly against hand-built response
/// bodies without a live Docker daemon (same rationale as `extractJsonField`, #4535).
pub func extractJsonIntField(json: in String, field: in String): Option[Int] {
  val target = "\"" + field + "\""
  val jsonLen = json.length
  var searchFrom = 0
  while searchFrom < jsonLen {
    val pos = indexOfFrom(json, target, searchFrom)
    if pos < 0 {
      return None
    }
    if isFieldKeyPosition(json, pos) {
      var i = pos + target.length
      while i < jsonLen and json.substring(i, 1) != ":" {
        i = i + 1
      }
      if i >= jsonLen {
        return None
      }
      i = i + 1
      while i < jsonLen and isJsonWhitespace(json.substring(i, 1)) {
        i = i + 1
      }
      var digits = ""
      if i < jsonLen and json.substring(i, 1) == "-" {
        digits = "-"
        i = i + 1
      }
      var scanning = true
      while scanning and i < jsonLen {
        val c = json.substring(i, 1)
        if c >= "0" and c <= "9" {
          digits = digits + c
          i = i + 1
        } else {
          scanning = false
        }
      }
      if digits.length == 0 or digits == "-" {
        return None
      }
      match Std.Parse.tryParseInt(digits) {
        case Ok(n) -> return Some(value = n)
        case Err(_) -> return None
      }
    }
    searchFrom = pos + 1
  }
  None
}

/// Extract a boolean field's value from a JSON object, or `None` if the
/// field is absent or its value is neither the bare literal `true` nor
/// `false`. Mirrors `extractJsonIntField`'s key-position disambiguation and
/// whitespace handling. Public for the same testability reason as
/// `extractJsonIntField`.
pub func extractJsonBoolField(json: in String, field: in String): Option[Bool] {
  val target = "\"" + field + "\""
  val jsonLen = json.length
  var searchFrom = 0
  while searchFrom < jsonLen {
    val pos = indexOfFrom(json, target, searchFrom)
    if pos < 0 {
      return None
    }
    if isFieldKeyPosition(json, pos) {
      var i = pos + target.length
      while i < jsonLen and json.substring(i, 1) != ":" {
        i = i + 1
      }
      if i >= jsonLen {
        return None
      }
      i = i + 1
      while i < jsonLen and isJsonWhitespace(json.substring(i, 1)) {
        i = i + 1
      }
      if i + 4 <= jsonLen and json.substring(i, 4) == "true" {
        return Some(value = true)
      }
      if i + 5 <= jsonLen and json.substring(i, 5) == "false" {
        return Some(value = false)
      }
      return None
    }
    searchFrom = pos + 1
  }
  None
}

/// `true` iff `field`'s value in `json` begins with `{` (a JSON object).
/// Used to detect a non-null `Error` object in Docker's `/wait` response
/// (`{"StatusCode":0,"Error":{"Message":"..."}|null}`) without a full JSON
/// parser: both an absent field and an explicit `null` value correctly read
/// as "no error object present" — only a `{` immediately after the value
/// position reads as `true`.
/// Public for the same testability reason as `extractJsonIntField`.
pub func jsonFieldIsObject(json: in String, field: in String): Bool {
  match jsonFieldObjectStart(json, field) {
    case Some(_) -> true
    case None -> false
  }
}

/// Position of the `{` beginning `field`'s object value in `json`, or
/// `None` if the field is absent or its value isn't an object. Pair with
/// `jsonObjectEnd(json, pos)` (or the `scopeJsonObject` helper) to bound the
/// resulting slice to just that nested object instead of re-scanning the
/// whole (possibly much larger) enclosing document, where a same-named
/// field elsewhere could otherwise be picked up by mistake (#5780). Public
/// for the same testability reason as `extractJsonIntField`.
pub func jsonFieldObjectStart(json: in String, field: in String): Option[Int] {
  val target = "\"" + field + "\""
  val jsonLen = json.length
  var searchFrom = 0
  while searchFrom < jsonLen {
    val pos = indexOfFrom(json, target, searchFrom)
    if pos < 0 {
      return None
    }
    if isFieldKeyPosition(json, pos) {
      var i = pos + target.length
      while i < jsonLen and json.substring(i, 1) != ":" {
        i = i + 1
      }
      if i >= jsonLen {
        return None
      }
      i = i + 1
      while i < jsonLen and isJsonWhitespace(json.substring(i, 1)) {
        i = i + 1
      }
      if i < jsonLen and json.substring(i, 1) == "{" {
        return Some(value = i)
      }
      return None
    }
    searchFrom = pos + 1
  }
  None
}

/// Position of the `}` matching the `{` at `openPos` in `json` (as returned
/// by `jsonFieldObjectStart`), or `None` if `json` has no balanced closing
/// brace at or after `openPos`. Tracks brace depth and skips over string
/// contents (so a `{`/`}` or an escaped `"` inside a string *value* doesn't
/// perturb the count), unlike `jsonFieldObjectStart`'s own doc comment,
/// which already flags "no depth tracking / no closing-brace bound" as a
/// known limitation. Lets a caller scope a nested-object slice to exactly
/// `json.substring(openPos, closePos + 1 - openPos)` instead of an
/// unbounded slice to the end of the document, where a same-named field in
/// a later sibling section could otherwise be picked up by mistake (#5780).
pub func jsonObjectEnd(json: in String, openPos: in Int): Option[Int] {
  val jsonLen = json.length
  var i = openPos
  var depth = 0
  var inString = false
  while i < jsonLen {
    val c = json.substring(i, 1)
    if inString {
      if c == "\\" {
        i = i + 2
      } else if c == "\"" {
        inString = false
        i = i + 1
      } else {
        i = i + 1
      }
    } else {
      if c == "\"" {
        inString = true
        i = i + 1
      } else if c == "{" {
        depth = depth + 1
        i = i + 1
      } else if c == "}" {
        depth = depth - 1
        i = i + 1
        if depth == 0 {
          return Some(value = i - 1)
        }
      } else {
        i = i + 1
      }
    }
  }
  None
}

/// Slice `json` to just the object beginning at `pos` (a position returned
/// by `jsonFieldObjectStart`), bounded by `jsonObjectEnd`'s matching closing
/// brace. Falls back to a slice through the end of `json` if the object is
/// unbalanced (defensive; should not happen against well-formed API
/// responses). Shared by `waitContainer`'s `Error` lookup and
/// `containerIsTty`'s `Config` lookup so a same-named field in a later
/// sibling section can't be picked up by mistake (#5780).
func scopeJsonObject(json: in String, pos: in Int): String {
  match jsonObjectEnd(json, pos) {
    case Some(closePos) -> json.substring(pos, closePos + 1 - pos)
    case None -> json.substring(pos, json.length - pos)
  }
}

/// Validate a Docker container ID: must be a lowercase hex string of length 12
/// (short form) or 64 (full SHA-256), as returned by the Docker API.  Rejects
/// values containing path-separator or query characters that would silently
/// reach unintended API endpoints.
///
/// @deprecated Superseded by `ContainerId`/`ContainerId.tryFrom` (#7255): this
/// check also rejects a valid unique hex prefix of any other length and a
/// valid container name — `ContainerId.tryFrom` accepts the full shape Docker
/// itself accepts. Kept for source compatibility; prefer `ContainerId`.
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

/// True when `s` is 1-64 lowercase hex characters — a full 64-character
/// SHA-256 container ID or any unique prefix of one, exactly the shape the
/// Docker Engine API accepts wherever a container ID is expected.
@pure
func isHexContainerId(s: in String): Bool {
  val len = s.length
  if len == 0 or len > 64 {
    return false
  }
  var i = 0
  var ok = true
  while i < len and ok {
    val c = s[i]
    if not ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f')) {
      ok = false
    }
    i = i + 1
  }
  ok
}

/// True when `s` matches Docker's container-name shape: a leading
/// alphanumeric character followed by one or more alphanumeric, `_`, `.`, or
/// `-` characters (`[a-zA-Z0-9][a-zA-Z0-9_.-]+`, per the Docker Engine API).
@pure
func isContainerNameShape(s: in String): Bool {
  val len = s.length
  if len < 2 or not Std.Char.isAsciiLetterOrDigit(s[0]) {
    return false
  }
  var i = 1
  var ok = true
  while i < len and ok {
    val c = s[i]
    if not (Std.Char.isAsciiLetterOrDigit(c) or c == '_' or c == '.' or c == '-') {
      ok = false
    }
    i = i + 1
  }
  ok
}

/// True when `s` is a shape the Docker Engine API accepts as a container
/// reference: a full 64-hex ID, a unique hex prefix of any length 1-64, or a
/// container name (`isContainerNameShape`).
@pure
@stable(since = "0.1")
pub func isValidContainerIdOrName(s: in String): Bool {
  isHexContainerId(s) or isContainerNameShape(s)
}

/// A validated container identifier — either a full 64-hex ID, a unique hex
/// prefix, or a container name — accepted by `start`/`stop`/`wait`/`remove`.
/// Opaque so a caller can only obtain one through `ContainerId.tryFrom` (or
/// as the result of `createContainer`), never by constructing an unvalidated
/// string directly.
@stable(since = "0.1")
pub opaque type ContainerId {
  value: String
  invariant: isValidContainerIdOrName(value)
}

/// Validate and wrap a caller-supplied container ID or name — from user
/// input, a config file, or a prior `docker ps` — before it reaches
/// `startContainer`/`stopContainer`/`waitContainer`/`removeContainer`/
/// `getContainerLogs`.
@stable(since = "0.1")
pub func ContainerId.tryFrom(raw: in String): Result[ContainerId, DockerError] {
  if isValidContainerIdOrName(raw) {
    return Ok(value = ContainerId(value = raw))
  }
  return Err(error = DockerError(statusCode = None, message = "Invalid container ID or name", details = raw))
}

/// The validated string this `ContainerId` wraps (its full ID, hex prefix, or
/// name), for building request paths or for display.
@stable(since = "0.1")
pub func ContainerId.toString(id: in ContainerId): String {
  id.value
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

/// Create a container from an image with environment variables and volume
/// binds, additionally pinning the container's NetworkMode (e.g. "none" for
/// full isolation, or a named Docker network). An empty networkMode keeps
/// the Docker default (bridge). Returns the new container's validated id.
pub async func createContainerWithNetwork(
  client: in DockerClient,
  image: in String,
  env: in slice[String],
  binds: in slice[String],
  networkMode: in String,
): Result[ContainerId, DockerError] {
  val urlStr = client.apiBase + "/containers/create"
  val url = resolveDockerUrl(urlStr)?
  val request = Std.Http.withJsonBody(
    Std.Http.request(Std.Http.POST, url),
    createContainerBodyWithNetwork(image, env, binds, networkMode)
  )
  match await sendAndReadBody(client, request, urlStr, "Create container failed") {
    case Ok(body) -> {
      val id = extractJsonField(body, "Id")
      if id.length == 0 {
        Err(error = DockerError(statusCode = None, message = "Create container returned no Id", details = body))
      } else {
        ContainerId.tryFrom(id)
      }
    }
    case Err(e) -> Err(error = e)
  }
}

/// Create a container from an image with environment variables and volume
/// binds, using the Docker default network. Returns the new container's
/// validated id.
pub async func createContainer(
  client: in DockerClient, image: in String, env: in slice[String], binds: in slice[String]
): Result[ContainerId, DockerError] {
  await createContainerWithNetwork(client, image, env, binds, "")
}

/// Start a created container.
pub async func startContainer(client: in DockerClient, containerId: in ContainerId): Result[Unit, DockerError] {
  await sendExpectSuccess(client, client.apiBase + "/containers/" + containerId.value + "/start", Std.Http.POST, "Start container failed")
}

/// Block until a container exits, then return its exit code.
///
/// Calls the Docker Engine `/containers/{id}/wait` endpoint, which blocks
/// server-side until the container stops (Docker's default
/// `condition=not-running`) before responding with
/// `{"StatusCode":<int>,"Error":{"Message":<string>}|null}`. Surfaces the
/// exit code rather than collapsing to `Unit` on success — a caller
/// orchestrating a run-to-completion container needs to know whether the
/// process it waited on actually exited cleanly.
///
/// A non-null `Error` object is a daemon-level failure distinct from the
/// container's own exit code (e.g. the daemon lost track of the container
/// while waiting) and can be present even when `StatusCode` reads `0` —
/// checked first and reported as `Err` rather than silently returning
/// `Ok(0)` as if the wait had gone cleanly.
///
/// `/wait` blocks server-side for as long as the container runs, so the only
/// honest bound is a client-side cancellation: `timeoutSec` is passed to the
/// underlying client's own `sendWithCancel` (see `sendAndReadBodyWithTimeout`),
/// which cancels the pending request — not the container itself — once
/// `timeoutSec` elapses, surfacing as `Err` with a "cancelled" message.
pub async func waitContainer(
  client: in DockerClient, containerId: in ContainerId, timeoutSec: in Int
): Result[Int, DockerError]
  requires: timeoutSec > 0
{
  val urlStr = client.apiBase + "/containers/" + containerId.value + "/wait"
  val url = resolveDockerUrl(urlStr)?
  match await sendAndReadBodyWithTimeout(client, Std.Http.request(Std.Http.POST, url), urlStr, "Wait for container failed", timeoutSec) {
    case Ok(body) -> match jsonFieldObjectStart(body, "Error") {
      case Some(errStart) -> {
        // Scope the Message lookup to the Error object itself, not the
        // whole response body — a same-named field elsewhere in the body
        // (unlikely in this response shape today, but not guaranteed by the
        // API contract) must not be picked up by mistake (#4929).
        val errorObj = scopeJsonObject(body, errStart)
        val message = extractJsonField(errorObj, "Message")
        val details = if message.length > 0 { message } else { body }
        Err(
          error = DockerError(
            statusCode = None,
            message = "Docker reported an error while waiting for the container",
            details = details
          )
        )
      }
      case None -> match extractJsonIntField(body, "StatusCode") {
        case Some(code) -> Ok(value = code)
        case None -> Err(
          error = DockerError(
            statusCode = None,
            message = "Wait for container returned no StatusCode",
            details = body
          )
        )
      }
    }
    case Err(e) -> Err(error = e)
  }
}

/// Stop a running container.
///
/// `timeoutSec` is Docker's own graceful-stop grace period (the `/stop`
/// endpoint's `t` query parameter, in seconds): Docker sends SIGTERM,
/// waits up to `timeoutSec` for the container to exit, then sends SIGKILL.
pub async func stopContainer(
  client: in DockerClient, containerId: in ContainerId, timeoutSec: in Int
): Result[Unit, DockerError]
  requires: timeoutSec > 0
{
  await sendExpectSuccess(client, client.apiBase + "/containers/" + containerId.value + "/stop?t=" + timeoutSec.toString(), Std.Http.POST, "Stop container failed")
}

/// Remove a container.
pub async func removeContainer(client: in DockerClient, containerId: in ContainerId): Result[Unit, DockerError] {
  await sendExpectSuccess(client, client.apiBase + "/containers/" + containerId.value + "?force=true", Std.Http.DELETE, "Remove container failed")
}

/// Maximum total decoded bytes `demultiplexDockerStream` accumulates before
/// giving up with `Err`. Docker's own frame-size field is bounded only by the
/// remaining input buffer, so a very large (or maliciously crafted) response
/// could otherwise drive unbounded memory use.
val maxDemultiplexedStreamBytes: Int = 67108864

// 64 MiB
/// Demultiplex a raw Docker multiplexed stream into a UTF-8 String.
/// Accepts the raw bytes of a multiplexed stream and decodes combined stdout/stderr.
///
/// `Err` when:
/// - the decoded bytes are not valid UTF-8;
/// - the buffer ends with a partial frame (a header shorter than 8 bytes, or
///   a header whose declared size runs past the end of the buffer) — a
///   truncated trailing frame previously decoded whatever bytes preceded it
///   as if the stream were complete;
/// - a frame's stream-type byte is neither `1` (stdout) nor `2` (stderr) —
///   previously any other stream type (including `0`, stdin) was silently
///   skipped rather than treated as malformed input;
/// - the accumulated stdout/stderr bytes exceed `maxDemultiplexedStreamBytes`.
///
/// An empty stream decodes to `Ok("")`.
pub func demultiplexDockerStream(bytes: in slice[Byte]): Result[String, String] {
  val len = bytes.length
  val outBytes: List[Byte] = newList()
  var i = 0
  var errMsg = ""
  var failed = false
  while i + 8 <= len and not failed {
    val streamType = bytes[i]

    val size_b3 = bytes[i + 4]
    val size_b2 = bytes[i + 5]
    val size_b1 = bytes[i + 6]
    val size_b0 = bytes[i + 7]

    // The frame size is an UNSIGNED 32-bit big-endian field, so a value with
    // the top bit set (>= 2^31) overflows a signed Int and would wrap to a
    // negative size — defeating the bounds check below and then driving `i`
    // negative into an out-of-range index.  Accumulate in Long and validate
    // against the remaining buffer before narrowing back to Int.
    val sizeL: Long = size_b3.toInt().toLong() * 16777216i64 + size_b2.toInt().toLong() * 65536i64 +
      size_b1.toInt().toLong() * 256i64 +
      size_b0.toInt().toLong()

    if sizeL < 0i64 {
      failed = true
      errMsg = "Demultiplexed Docker stream ends with a truncated frame"
    } else if streamType != 1u8 and streamType != 2u8 {
      failed = true
      errMsg = "Demultiplexed Docker stream contains an unrecognized stream type"
    } else if outBytes.count.toLong() + sizeL > maxDemultiplexedStreamBytes.toLong() {
      // Checked against the declared size directly, before the remaining-buffer
      // bound below: a caller passing a maliciously large declared frame size
      // should not have to actually supply that many bytes to trigger the cap.
      failed = true
      errMsg = "Demultiplexed Docker stream exceeds the " + maxDemultiplexedStreamBytes.toString() + "-byte cap"
    } else if i.toLong() + 8i64 + sizeL > len.toLong() {
      failed = true
      errMsg = "Demultiplexed Docker stream ends with a truncated frame"
    } else {
      val size = sizeL.toInt()
      var j = 0
      while j < size {
        outBytes.add(bytes[i + 8 + j])
        j = j + 1
      }
      i = i + 8 + size
    }
  }

  if failed {
    return Err(error = errMsg)
  }
  if i != len {
    // Fewer than 8 bytes remain: not enough for another frame header, and
    // not zero either — a partial header at the very end of the stream.
    return Err(error = "Demultiplexed Docker stream ends with a truncated frame header")
  }

  match Std.Encoding.tryDecodeUtf8(outBytes.toArray()) {
    case Some(s) -> Ok(value = s)
    case None -> Err(error = "Demultiplexed Docker stream bytes are not valid UTF-8")
  }
}

/// Whether `containerId` was created with an interactive pseudo-TTY
/// (`Config.Tty`), read from `GET /containers/{id}/json`. This is the only
/// reliable way to know whether `/logs` returns a raw byte stream or the
/// framed multiplexed stdout/stderr format — see `getContainerLogs`'s doc
/// comment for why the `/logs` response's own `Content-Type` header cannot
/// be used for this. Defaults to `false` (multiplexed) if `Config.Tty` is
/// absent or malformed, matching the Docker API's own default when a
/// container is created without an explicit `Tty` field.
async func containerIsTty(client: in DockerClient, containerId: in ContainerId): Result[Bool, DockerError] {
  val bodyResult = await fetchBodyText(client, client.apiBase + "/containers/" + containerId.value + "/json", "Inspect container failed")
  val body = match bodyResult { case Err(e) -> return Err(error = e); case Ok(b) -> b }
  match jsonFieldObjectStart(body, "Config") {
    case None -> Ok(value = false)
    case Some(pos) -> {
      val configJson = scopeJsonObject(body, pos)
      match extractJsonBoolField(configJson, "Tty") {
        case Some(v) -> Ok(value = v)
        case None -> Ok(value = false)
      }
    }
  }
}

/// Fetch a container's combined stdout/stderr logs.
///
/// A container started with a pseudo-TTY (`Tty: true`) gets a raw byte
/// stream from `/logs`; otherwise the stream is framed (an 8-byte header
/// per chunk identifying stdout/stderr and length) and must be run through
/// `demultiplexDockerStream` first. The `/logs` response's own
/// `Content-Type` header cannot be used to distinguish these: verified
/// against a live daemon (Docker Engine 29.3), it reports
/// `application/vnd.docker.raw-stream` unconditionally for every
/// container, TTY or not, while the body is genuinely framed-multiplexed
/// whenever `Config.Tty` is false. Trusting that header (as a prior version
/// of this function did) silently fed the 8-byte frame headers into UTF-8
/// decoding for every non-TTY container — the overwhelmingly common case,
/// since `createContainer`/`createContainerWithNetwork` never set `Tty` —
/// producing a "Failed to decode container logs as UTF-8" error on every
/// call. `containerIsTty` queries the container's actual `Config.Tty`
/// setting instead, which is authoritative.
pub async func getContainerLogs(client: in DockerClient, containerId: in ContainerId): Result[String, DockerError] {
  val isTtyResult = await containerIsTty(client, containerId)
  val isTty = match isTtyResult { case Err(e) -> return Err(error = e); case Ok(v) -> v }

  val urlStr = client.apiBase + "/containers/" + containerId.value + "/logs?stdout=true&stderr=true"
  val url = resolveDockerUrl(urlStr)?
  val bytesResult = await sendAndReadBytes(client, Std.Http.request(Std.Http.GET, url), urlStr, "Get container logs failed")
  val bytes = match bytesResult { case Err(e) -> return Err(error = e); case Ok(b) -> b }

  if isTty {
    match Std.Encoding.tryDecodeUtf8(bytes) {
      case Some(s) -> Ok(value = s)
      case None -> Err(
        error = DockerError(
          statusCode = None,
          message = "Failed to decode container logs as UTF-8",
          details = ""
        )
      )
    }
  } else {
    match demultiplexDockerStream(bytes) {
      case Ok(s) -> Ok(value = s)
      case Err(reason) -> Err(
        error = DockerError(
          statusCode = None,
          message = "Failed to decode container logs as UTF-8",
          details = reason
        )
      )
    }
  }
}
