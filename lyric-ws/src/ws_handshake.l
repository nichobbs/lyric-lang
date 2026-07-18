//! ws_handshake.l — pure-Lyric RFC 6455 WebSocket upgrade handshake.
//!
//! A minimal HTTP/1.1 GET parser scoped to exactly the WebSocket upgrade
//! request shape (request line + headers, no body) — not a general HTTP
//! parser (that's `Std.HttpEngine`'s job; a full request/response FSM with
//! chunked bodies is unneeded overhead for a handshake that is always a
//! small, header-only GET). Target-independent except for the RFC 6455
//! `Sec-WebSocket-Accept` derivation, which routes through the cross-target
//! `Std.Hash.sha1OfBytes` (docs/62-jsonrpc-mcp.md §6).
//!
//! `Sec-WebSocket-Accept` is `Base64(SHA-1(Sec-WebSocket-Key + GUID))`
//! (RFC 6455 §1.3). `Std.Hash.sha1OfBytes` returns a hex string (matching
//! `sha256OfBytes`/`sha512OfBytes`'s shape), so `computeAcceptKey` hex-decodes
//! it back to the raw 20-byte digest before Base64-encoding — SHA-1's own
//! weaknesses don't matter here (see `Std.Hash.sha1OfBytes`'s doc comment).
@runtime_checked
package Ws.Handshake

import Std.Core
import Std.Collections
import Std.String
import Std.Encoding
import Std.Hash

// The RFC 6455 §1.3 magic GUID appended to the client's Sec-WebSocket-Key
// before hashing.
val wsGuid: String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

/// A parsed, validated WebSocket upgrade request.
@stable(since = "0.1")
pub record HandshakeRequest {
  path: String
  query: String
  secWebSocketKey: String
}

/// `parseHandshakeRequest`'s result plus any bytes read past the header
/// terminator (`\r\n\r\n`) — a client that doesn't wait for the `101`
/// response before sending WebSocket frames (or a `hostRead` call that
/// simply returned more than the header block) leaves those bytes here so
/// the caller feeds them into the frame decoder instead of discarding them.
@stable(since = "0.1")
pub record HandshakeResult {
  request: HandshakeRequest
  leftover: slice[Byte]
}

/// Compute `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key`
/// (RFC 6455 §1.3 / §4.2.2 item 5.4).
@stable(since = "0.1")
pub func computeAcceptKey(secWebSocketKey: in String): String {
  val digestHex = sha1OfBytes(encodeUtf8(secWebSocketKey + wsGuid))
  match tryDecodeHex(digestHex) {
    case Some(bytes) -> encodeBase64(bytes)
    case None -> panic("Ws.Handshake.computeAcceptKey: sha1OfBytes returned malformed hex (unreachable)")
  }
}

/// The successful `101 Switching Protocols` upgrade response.
@stable(since = "0.1")
pub func buildAcceptResponse(secWebSocketKey: in String): slice[Byte] {
  val accept = computeAcceptKey(secWebSocketKey)
  val text = "HTTP/1.1 101 Switching Protocols\r\n" + "Upgrade: websocket\r\n" + "Connection: Upgrade\r\n" +
    "Sec-WebSocket-Accept: " +
    accept +
    "\r\n\r\n"
  encodeUtf8(text)
}

/// A minimal bodyless error response for a rejected handshake.
@stable(since = "0.1")
pub func buildRejectResponse(status: in Int, reason: in String): slice[Byte] {
  val text = "HTTP/1.1 " + status.toString() + " " + reason + "\r\n" + "Connection: close\r\n" +
    "Content-Length: 0\r\n\r\n"
  encodeUtf8(text)
}

/// Find the end (exclusive) of the header block — the byte offset just past
/// the terminating `\r\n\r\n` — or `None` if `bytes` doesn't yet contain one.
/// A transport driver uses this to know when to stop accumulating reads and
/// hand the buffer to `parseHandshakeRequest`.
@stable(since = "0.1")
pub func findHeaderTerminator(bytes: in slice[Byte]): Option[Int] {
  var i = 0
  while i + 3 < bytes.length {
    if bytes[i].toInt() == 13 and bytes[i + 1].toInt() == 10 and bytes[i + 2].toInt() == 13 and bytes[i + 3].toInt() == 10 {
      return Some(value = i + 4)
    }
    i = i + 1
  }
  None
}

func splitTargetPathQuery(target: in String): HandshakeRequest {
  match indexOf(target, "?") {
    case Some(q) -> HandshakeRequest(path = substring(target, 0, q), query = substring(target, q + 1), secWebSocketKey = "")
    case None -> HandshakeRequest(path = target, query = "", secWebSocketKey = "")
  }
}

// Every header value this parser needs is looked up by a lower-cased name
// (HTTP header names are case-insensitive, RFC 9110 5.1) — `headers` stores
// lower-cased keys, matching the case-insensitive lookup contract.
func requireHeaderContains(
  headers: in Map[String, String],
  name: in String,
  mustContainLower: in String,
  what: in String,
): Option[String] {
  match mapGet(headers, name) {
    case None -> Some(value = "missing required header: " + what)
    case Some(value) -> {
      if contains(toLower(value), mustContainLower) {
        None
      } else {
        Some(value = "malformed " + what + " header: " + value)
      }
    }
  }
}

func parseHeaderLines(lines: in slice[String], startAt: in Int): Result[Map[String, String], String] {
  val headers: Map[String, String] = newMap()
  var i = startAt
  var done = false
  while i < lines.length and not done {
    val line = lines[i]
    if line == "" {
      done = true
    } else {
      match indexOf(line, ":") {
        case None -> return Err(error = "malformed header line: " + line)
        case Some(idx) -> {
          val name = toLower(trim(substring(line, 0, idx)))
          val value = trim(substring(line, idx + 1))
          if name.length == 0 {
            return Err(error = "empty header field-name in line: " + line)
          }
          headers.add(name, value)
        }
      }
    }
    i = i + 1
  }
  if not done {
    return Err(error = "handshake request is missing its terminating blank line")
  }
  Ok(value = headers)
}

func validateWebSocketHeaders(headers: in Map[String, String]): Result[String, String] {
  match requireHeaderContains(headers, "upgrade", "websocket", "Upgrade") {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }
  match requireHeaderContains(headers, "connection", "upgrade", "Connection") {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }
  match mapGet(headers, "sec-websocket-version") {
    case None -> return Err(error = "missing required header: Sec-WebSocket-Version")
    case Some(v) -> {
      if v != "13" {
        return Err(error = "unsupported Sec-WebSocket-Version: " + v + " (only 13 is supported)")
      }
    }
  }
  match mapGet(headers, "sec-websocket-key") {
    case None -> Err(error = "missing required header: Sec-WebSocket-Key")
    case Some(key) -> {
      match tryDecodeBase64(key) {
        case None -> Err(error = "Sec-WebSocket-Key is not valid Base64")
        case Some(raw) -> {
          if raw.length != 16 {
            Err(error = "Sec-WebSocket-Key must decode to exactly 16 bytes")
          } else {
            Ok(value = key)
          }
        }
      }
    }
  }
}

func parseRequestLine(line: in String): Result[String, String] {
  val parts = split(line, " ")
  if parts.length != 3 {
    return Err(error = "malformed request line: " + line)
  }
  if parts[0] != "GET" {
    return Err(error = "WebSocket upgrade request must use GET, got: " + parts[0])
  }
  if parts[2] != "HTTP/1.1" {
    return Err(error = "WebSocket upgrade request must be HTTP/1.1, got: " + parts[2])
  }
  Ok(value = parts[1])
}

/// Parse and validate a WebSocket upgrade request out of `bytes` — the
/// header block INCLUDING the terminating `\r\n\r\n` (as located by
/// `findHeaderTerminator`), plus any bytes that follow it. Validates the
/// request line (`GET <target> HTTP/1.1`), `Upgrade: websocket`,
/// a `Connection` header containing the `upgrade` token,
/// `Sec-WebSocket-Version: 13`, and a `Sec-WebSocket-Key` that Base64-decodes
/// to exactly 16 bytes (RFC 6455 §4.2.1). Returns `Err` with a human-readable
/// reason for any violation — the caller writes `buildRejectResponse` and
/// closes the connection rather than surfacing this as a WebSocket-level
/// error (the connection was never upgraded).
@stable(since = "0.1")
pub func parseHandshakeRequest(bytes: in slice[Byte]): Result[HandshakeResult, String] {
  val terminatorEnd = match findHeaderTerminator(bytes) {
    case Some(stop) -> stop
    case None -> return Err(error = "handshake request is missing its terminating blank line")
  }
  val headerBytes = bytes.slice(0, terminatorEnd)
  val leftover = bytes.slice(terminatorEnd, bytes.length)
  val text = match tryDecodeUtf8(headerBytes) {
    case Some(t) -> t
    case None -> return Err(error = "handshake request headers are not valid UTF-8/ASCII")
  }
  val lines = split(text, "\r\n")
  if lines.length < 1 {
    return Err(error = "empty handshake request")
  }
  val target = parseRequestLine(lines[0])?
  val headers = parseHeaderLines(lines, 1)?
  val key = validateWebSocketHeaders(headers)?
  val pathQuery = splitTargetPathQuery(target)
  Ok(
    value = HandshakeResult(
      request = HandshakeRequest(path = pathQuery.path, query = pathQuery.query, secWebSocketKey = key),
      leftover = leftover
    )
  )
}
