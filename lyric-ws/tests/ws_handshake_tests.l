//! tests/ws_handshake_tests.l — unit tests for `Ws.Handshake`, the pure-Lyric
//! RFC 6455 upgrade-handshake parser (docs/62-jsonrpc-mcp.md §6).
//!
//! Covers the RFC 6455 §1.3 accept-key worked example, request-line/header
//! parsing (path/query split, required-header validation), and the
//! leftover-bytes contract `parseHandshakeRequest` exposes for a client that
//! doesn't wait for the `101` response.
@test_module
package Ws.WsHandshakeTests

import Std.Core
import Std.Encoding
import Std.Testing
import Ws.Handshake

func crlf(): String {
  "\r\n"
}

func validRequestText(path: in String): String {
  "GET " + path + " HTTP/1.1" + crlf() + "Host: example.com" + crlf() + "Upgrade: websocket" + crlf() +
    "Connection: Upgrade" +
    crlf() +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" +
    crlf() +
    "Sec-WebSocket-Version: 13" +
    crlf() +
    crlf()
}

// ─── RFC 6455 §1.3 worked example ──────────────────────────────────────────
test "computeAcceptKey matches the RFC 6455 1.3 worked example" {
  val accept = computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==")
  assertEqual(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC 6455 1.3 Sec-WebSocket-Accept example")
}

test "buildAcceptResponse embeds the computed accept key" {
  val resp = buildAcceptResponse("dGhlIHNhbXBsZSBub25jZQ==")
  val text = match tryDecodeUtf8(resp) {
    case Some(t) -> t
    case None -> {
      assertTrue(false, "response is not valid UTF-8")
      ""
    }
  }
  assertTrue(text.startsWith("HTTP/1.1 101 Switching Protocols\r\n"), "101 status line")
  assertTrue(text.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), "accept key header present")
  assertTrue(text.contains("Upgrade: websocket"), "Upgrade header present")
  assertTrue(text.endsWith("\r\n\r\n"), "response terminates with a blank line")
}

// ─── Request parsing (happy path) ──────────────────────────────────────────
test "parseHandshakeRequest parses a well-formed upgrade request" {
  val raw = encodeUtf8(validRequestText("/ws"))
  val result = match parseHandshakeRequest(raw) {
    case Ok(r) -> r
    case Err(e) -> {
      assertTrue(false, "expected Ok, got Err: " + e)
      panic("unreachable")
    }
  }
  assertEqual(result.request.path, "/ws", "path parsed")
  assertEqual(result.request.query, "", "no query string")
  assertEqual(result.request.secWebSocketKey, "dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Key parsed")
  assertEqualInt(result.leftover.length, 0, "no leftover bytes when the buffer ends at the header terminator")
}

test "parseHandshakeRequest splits path and query" {
  val raw = encodeUtf8(validRequestText("/ws?token=abc&x=1"))
  val result = match parseHandshakeRequest(raw) {
    case Ok(r) -> r
    case Err(e) -> {
      assertTrue(false, "expected Ok, got Err: " + e)
      panic("unreachable")
    }
  }
  assertEqual(result.request.path, "/ws", "path excludes the query string")
  assertEqual(result.request.query, "token=abc&x=1", "query string parsed")
}

test "parseHandshakeRequest retains bytes past the header terminator" {
  val extra = "EXTRA-FRAME-BYTES"
  val raw = encodeUtf8(validRequestText("/ws") + extra)
  val result = match parseHandshakeRequest(raw) {
    case Ok(r) -> r
    case Err(e) -> {
      assertTrue(false, "expected Ok, got Err: " + e)
      panic("unreachable")
    }
  }
  val leftoverText = match tryDecodeUtf8(result.leftover) { case Some(t) -> t; case None -> "" }
  assertEqual(leftoverText, extra, "bytes past the header terminator are preserved, not discarded")
}

// ─── Request parsing (rejections) ──────────────────────────────────────────
test "parseHandshakeRequest rejects a non-GET method" {
  val text = "POST /ws HTTP/1.1" + crlf() + "Upgrade: websocket" + crlf() + "Connection: Upgrade" + crlf() +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" +
    crlf() +
    "Sec-WebSocket-Version: 13" +
    crlf() +
    crlf()
  match parseHandshakeRequest(encodeUtf8(text)) {
    case Ok(_) -> assertTrue(false, "expected rejection of a non-GET method")
    case Err(_) -> assertTrue(true, "non-GET rejected")
  }
}

test "parseHandshakeRequest rejects a missing Upgrade header" {
  val text = "GET /ws HTTP/1.1" + crlf() + "Connection: Upgrade" + crlf() +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" +
    crlf() +
    "Sec-WebSocket-Version: 13" +
    crlf() +
    crlf()
  match parseHandshakeRequest(encodeUtf8(text)) {
    case Ok(_) -> assertTrue(false, "expected rejection of a missing Upgrade header")
    case Err(_) -> assertTrue(true, "missing Upgrade rejected")
  }
}

test "parseHandshakeRequest rejects a Connection header without the upgrade token" {
  val text = "GET /ws HTTP/1.1" + crlf() + "Upgrade: websocket" + crlf() + "Connection: keep-alive" + crlf() +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" +
    crlf() +
    "Sec-WebSocket-Version: 13" +
    crlf() +
    crlf()
  match parseHandshakeRequest(encodeUtf8(text)) {
    case Ok(_) -> assertTrue(false, "expected rejection of a Connection header lacking 'upgrade'")
    case Err(_) -> assertTrue(true, "Connection without upgrade token rejected")
  }
}

test "parseHandshakeRequest rejects an unsupported Sec-WebSocket-Version" {
  val text = "GET /ws HTTP/1.1" + crlf() + "Upgrade: websocket" + crlf() + "Connection: Upgrade" + crlf() +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" +
    crlf() +
    "Sec-WebSocket-Version: 8" +
    crlf() +
    crlf()
  match parseHandshakeRequest(encodeUtf8(text)) {
    case Ok(_) -> assertTrue(false, "expected rejection of Sec-WebSocket-Version 8")
    case Err(_) -> assertTrue(true, "unsupported version rejected")
  }
}

test "parseHandshakeRequest rejects a missing Sec-WebSocket-Key" {
  val text = "GET /ws HTTP/1.1" + crlf() + "Upgrade: websocket" + crlf() + "Connection: Upgrade" + crlf() +
    "Sec-WebSocket-Version: 13" +
    crlf() +
    crlf()
  match parseHandshakeRequest(encodeUtf8(text)) {
    case Ok(_) -> assertTrue(false, "expected rejection of a missing Sec-WebSocket-Key")
    case Err(_) -> assertTrue(true, "missing key rejected")
  }
}

test "parseHandshakeRequest rejects a Sec-WebSocket-Key that doesn't decode to 16 bytes" {
  val text = "GET /ws HTTP/1.1" + crlf() + "Upgrade: websocket" + crlf() + "Connection: Upgrade" + crlf() +
    "Sec-WebSocket-Key: dG9vc2hvcnQ=" +
    crlf() +
    "Sec-WebSocket-Version: 13" +
    crlf() +
    crlf()
  match parseHandshakeRequest(encodeUtf8(text)) {
    case Ok(_) -> assertTrue(false, "expected rejection of a wrong-length key")
    case Err(_) -> assertTrue(true, "wrong-length key rejected")
  }
}

test "parseHandshakeRequest rejects a buffer with no header terminator" {
  val text = "GET /ws HTTP/1.1" + crlf() + "Upgrade: websocket" + crlf()
  match parseHandshakeRequest(encodeUtf8(text)) {
    case Ok(_) -> assertTrue(false, "expected rejection of an incomplete header block")
    case Err(_) -> assertTrue(true, "incomplete header block rejected")
  }
}

test "buildRejectResponse produces a bodyless error response" {
  val resp = buildRejectResponse(400, "Bad Request")
  val text = match tryDecodeUtf8(resp) { case Some(t) -> t; case None -> "" }
  assertTrue(text.startsWith("HTTP/1.1 400 Bad Request\r\n"), "400 status line")
  assertTrue(text.contains("Content-Length: 0"), "bodyless response")
}

// ─── findHeaderTerminator ───────────────────────────────────────────────────
test "findHeaderTerminator locates the blank-line terminator" {
  val bytes = encodeUtf8("GET / HTTP/1.1\r\nHost: x\r\n\r\nEXTRA")
  match findHeaderTerminator(bytes) {
    case Some(idx) -> {
      val headerLen = "GET / HTTP/1.1\r\nHost: x\r\n\r\n".length
      assertEqualInt(idx, headerLen, "terminator offset excludes trailing bytes")
    }
    case None -> assertTrue(false, "expected a terminator to be found")
  }
}

test "findHeaderTerminator returns None for an incomplete header block" {
  val bytes = encodeUtf8("GET / HTTP/1.1\r\nHost: x\r\n")
  match findHeaderTerminator(bytes) {
    case Some(_) -> assertTrue(false, "expected None for an incomplete header block")
    case None -> assertTrue(true, "correctly reports incomplete")
  }
}
