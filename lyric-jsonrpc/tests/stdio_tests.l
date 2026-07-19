//! tests/stdio_tests.l — test suite for JsonRpc.Stdio.
//! Covers NDJSON and Content-Length round-trips (including multi-byte
//! UTF-8 payloads) against the sans-IO core functions
//! (`ndjsonReceiveVia`/`ndjsonSendVia`/`clReceiveVia`/`clSendVia`), fed
//! from in-memory implementations of the `CharReader`/`LineReader`/
//! `StringWriter`/`LineWriter` interfaces — no real pipes are needed (see
//! stdio.l's module doc for why the framing logic is parameterized this
//! way over interfaces rather than closures, and why
//! `newNdjsonTransport`/`newContentLengthTransport` themselves — which
//! bind to the real console — are not exercised here).
@test_module
package JsonRpc.Stdio.StdioTests

import Std.Core
import Std.Collections
import Std.Char
import Std.Encoding
import Std.Errors
import Std.Testing
import JsonRpc.Stdio

// ── In-memory stand-ins ──────────────────────────────────────────────────────
pub record CharSource {
  var text: String
  var pos: Int
}

impl CharReader for CharSource {
  func next(): Int {
    val text = self.text
    val pos = self.pos
    if pos < text.length {
      val c = toInt(text[pos])
      self.pos = pos + 1
      c
    } else {
      0 - 1
    }
  }
}

pub record LineSource {
  var lines: List[String]
  var pos: Int
}

impl LineReader for LineSource {
  func nextLine(): Result[String, IOError] {
    if self.pos < self.lines.count {
      val line = self.lines[self.pos]
      self.pos = self.pos + 1
      Ok(value = line)
    } else {
      Err(error = EndOfInput(source = "test"))
    }
  }
}

pub record Sink {
  var written: String
}

impl StringWriter for Sink {
  func write(s: in String): Unit {
    self.written = self.written + s
  }
}

pub record LineSink {
  var lines: List[String]
}

impl LineWriter for LineSink {
  func writeLine(s: in String): Unit {
    self.lines.add(s)
  }
}

// ── Content-Length framing: round-trip via clSendVia -> clReceiveVia ───────
test "Content-Length: a simple ASCII message round-trips" {
  val sink = Sink(written = "")
  match clSendVia("{\"a\":1}", sink) {
    case Err(e) -> assertTrue(false, "unexpected send error: " + e)
    case Ok(_) -> ()
  }
  assertEqual(sink.written, "Content-Length: 7\r\n\r\n{\"a\":1}", "exact framed bytes for a 7-byte ASCII body")
  val src = CharSource(text = sink.written, pos = 0)
  match clReceiveVia(src) {
    case Err(e) -> assertTrue(false, "unexpected receive error: " + e)
    case Ok(None) -> assertTrue(false, "unexpected clean EOF")
    case Ok(Some(body)) -> assertEqual(body, "{\"a\":1}", "round-trips exactly")
  }
}

test "Content-Length: the declared length is the UTF-8 byte count, not the UTF-16 char count" {
  // "café" is 4 UTF-16 code units but 5 UTF-8 bytes (é is 2 bytes).
  val payload = "\"café\""
  val expectedBytes = encodeUtf8(payload).length
  assertEqualInt(expectedBytes, 7, "the JSON string literal is 7 UTF-8 bytes")
  val sink = Sink(written = "")
  match clSendVia(payload, sink) {
    case Err(e) -> assertTrue(false, "unexpected send error: " + e)
    case Ok(_) -> ()
  }
  assertEqual(
    sink.written,
    "Content-Length: 7\r\n\r\n\"café\"",
    "header declares the byte count, body is the char text"
  )
}

test "Content-Length: a multi-byte UTF-8 body (including a supplementary-plane emoji) round-trips exactly" {
  val payload = "\"café 😀 中文\""
  val sink = Sink(written = "")
  match clSendVia(payload, sink) {
    case Err(e) -> assertTrue(false, "unexpected send error: " + e)
    case Ok(_) -> ()
  }
  val src = CharSource(text = sink.written, pos = 0)
  match clReceiveVia(src) {
    case Err(e) -> assertTrue(false, "unexpected receive error: " + e)
    case Ok(None) -> assertTrue(false, "unexpected clean EOF")
    case Ok(Some(body)) -> assertEqual(body, payload, "round-trips exactly, surrogate pair included")
  }
}

test "Content-Length: two consecutive messages on the same stream both read back correctly" {
  val sink = Sink(written = "")
  match clSendVia("{\"n\":1}", sink) {
    case Err(e) -> assertTrue(false, "unexpected send error: " + e)
    case Ok(_) -> ()
  }
  match clSendVia("{\"n\":2}", sink) {
    case Err(e) -> assertTrue(false, "unexpected send error: " + e)
    case Ok(_) -> ()
  }
  val src = CharSource(text = sink.written, pos = 0)
  match clReceiveVia(src) {
    case Ok(Some(body)) -> assertEqual(body, "{\"n\":1}", "first message")
    case _ -> assertTrue(false, "expected the first message")
  }
  match clReceiveVia(src) {
    case Ok(Some(body)) -> assertEqual(body, "{\"n\":2}", "second message")
    case _ -> assertTrue(false, "expected the second message")
  }
  match clReceiveVia(src) {
    case Ok(None) -> ()
    case _ -> assertTrue(false, "expected clean EOF after both messages")
  }
}

test "Content-Length: a zero-length body is a valid empty message" {
  val src = CharSource(text = "Content-Length: 0\r\n\r\n", pos = 0)
  match clReceiveVia(src) {
    case Ok(Some(body)) -> assertEqual(body, "", "empty body")
    case _ -> assertTrue(false, "expected an empty message, not an error")
  }
}

test "Content-Length: an empty stream is a clean EOF, not an error" {
  val src = CharSource(text = "", pos = 0)
  match clReceiveVia(src) {
    case Ok(None) -> ()
    case Ok(Some(b)) -> assertTrue(false, "expected clean EOF, not a message")
    case Err(e) -> assertTrue(false, "expected clean EOF, not an error: " + e)
  }
}

test "Content-Length: a header block truncated mid-line is an error, not a clean EOF" {
  val src = CharSource(text = "Content-Len", pos = 0)
  match clReceiveVia(src) {
    case Ok(None) -> assertTrue(false, "a partial header line must not read as clean EOF")
    case Ok(Some(b)) -> assertTrue(false, "unexpected success")
    case Err(e) -> ()
  }
}

test "Content-Length: a body truncated before the declared length is an error" {
  val src = CharSource(text = "Content-Length: 10\r\n\r\n{\"a\":1}", pos = 0)
  match clReceiveVia(src) {
    case Ok(v) -> assertTrue(false, "expected an error for a short body")
    case Err(e) -> ()
  }
}

test "Content-Length: a missing Content-Length header is an error" {
  val src = CharSource(text = "X-Other: 1\r\n\r\nbody", pos = 0)
  match clReceiveVia(src) {
    case Ok(v) -> assertTrue(false, "expected an error: no Content-Length header")
    case Err(e) -> ()
  }
}

test "Content-Length: the header key is matched case-insensitively" {
  val sink = Sink(written = "")
  sink.written = "content-LENGTH: 2\r\n\r\nok"
  val src = CharSource(text = sink.written, pos = 0)
  match clReceiveVia(src) {
    case Ok(Some(body)) -> assertEqual(body, "ok", "header key matched case-insensitively")
    case _ -> assertTrue(false, "expected a successful read")
  }
}

// ── NDJSON framing: round-trip via ndjsonSendVia -> ndjsonReceiveVia ───────
test "NDJSON: a message round-trips as exactly one line" {
  val sink = LineSink(lines = newList())
  match ndjsonSendVia("{\"a\":1}", sink) {
    case Err(e) -> assertTrue(false, "unexpected send error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(sink.lines.count, 1, "exactly one line written")
  assertEqual(sink.lines[0], "{\"a\":1}", "unmodified payload")
  val src = LineSource(lines = sink.lines, pos = 0)
  match ndjsonReceiveVia(src) {
    case Ok(Some(body)) -> assertEqual(body, "{\"a\":1}", "round-trips exactly")
    case _ -> assertTrue(false, "expected the message back")
  }
}

test "NDJSON: a multi-byte UTF-8 payload (including a supplementary-plane emoji) round-trips exactly" {
  val payload = "{\"text\":\"café 😀 中文\"}"
  val sink = LineSink(lines = newList())
  match ndjsonSendVia(payload, sink) {
    case Err(e) -> assertTrue(false, "unexpected send error: " + e)
    case Ok(_) -> ()
  }
  val src = LineSource(lines = sink.lines, pos = 0)
  match ndjsonReceiveVia(src) {
    case Ok(Some(body)) -> assertEqual(body, payload, "round-trips exactly, surrogate pair included")
    case _ -> assertTrue(false, "expected the message back")
  }
}

test "NDJSON: multiple lines are consumed in order" {
  val sink = LineSink(lines = newList())
  match ndjsonSendVia("1", sink) {
    case _ -> ()
  }
  match ndjsonSendVia("2", sink) {
    case _ -> ()
  }
  match ndjsonSendVia("3", sink) {
    case _ -> ()
  }
  val src = LineSource(lines = sink.lines, pos = 0)
  match ndjsonReceiveVia(src) {
    case Ok(Some(b)) -> assertEqual(b, "1", "first")
    case _ -> assertTrue(false, "expected '1'")
  }
  match ndjsonReceiveVia(src) {
    case Ok(Some(b)) -> assertEqual(b, "2", "second")
    case _ -> assertTrue(false, "expected '2'")
  }
  match ndjsonReceiveVia(src) {
    case Ok(Some(b)) -> assertEqual(b, "3", "third")
    case _ -> assertTrue(false, "expected '3'")
  }
}

test "NDJSON: end of input maps to a clean Ok(None), not an error" {
  val src = LineSource(lines = newList(), pos = 0)
  match ndjsonReceiveVia(src) {
    case Ok(None) -> ()
    case Ok(Some(b)) -> assertTrue(false, "expected clean EOF")
    case Err(e) -> assertTrue(false, "expected clean EOF, not an error: " + e)
  }
}

// ── Production RpcTransport records exist and construct cleanly ────────────
test "newNdjsonTransport / newContentLengthTransport construct without error" {
  val n = newNdjsonTransport()
  val c = newContentLengthTransport()
  assertTrue(true, "both constructors returned")
}
