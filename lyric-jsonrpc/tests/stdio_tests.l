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

// ── Framing limits (#7245) ──────────────────────────────────────────────────
// Every byte these readers consume comes from the peer, so an oversized or
// ambiguous frame must be a framing error, never an unbounded read.
func expectFramingError(text: in String, label: in String): Unit {
  val src = CharSource(text = text, pos = 0)
  match clReceiveVia(src) {
    case Ok(_) -> assertTrue(false, label + ": expected a framing error")
    case Err(_) -> ()
  }
}

test "Content-Length: a declared length above the 16 MiB limit is rejected before reading the body" {
  expectFramingError("Content-Length: 16777217\r\n\r\n{}", "oversized Content-Length")
}

test "Content-Length: a duplicate Content-Length header is rejected" {
  expectFramingError("Content-Length: 2\r\nContent-Length: 5\r\n\r\n{}", "duplicate Content-Length")
}

test "Content-Length: a malformed Content-Length value is rejected" {
  expectFramingError("Content-Length: 12abc\r\n\r\n{}", "malformed Content-Length")
}

test "Content-Length: a header line longer than 8192 characters is rejected" {
  var long = "X-Pad: "
  var i = 0
  while i < 8200 {
    long = long + "a"
    i = i + 1
  }
  expectFramingError(long + "\r\nContent-Length: 2\r\n\r\n{}", "over-long header line")
}

test "Content-Length: more than 64 header lines is rejected" {
  var headers = ""
  var i = 0
  while i < 70 {
    headers = headers + "X-H" + i.toString() + ": v\r\n"
    i = i + 1
  }
  expectFramingError(headers + "Content-Length: 2\r\n\r\n{}", "too many header lines")
}

test "NDJSON: a line above the 16 MiB limit is rejected" {
  var chunk = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  while chunk.length <= 16777216 {
    chunk = chunk + chunk
  }
  val lines: List[String] = newList()
  lines.add(chunk)
  match ndjsonReceiveVia(LineSource(lines = lines, pos = 0)) {
    case Ok(_) -> assertTrue(false, "expected a framing error for an oversized NDJSON line")
    case Err(_) -> ()
  }
}

// ── Surrogate code units from the reader (#7252) ───────────────────────────
// A `CharReader` yields raw UTF-16 code units, so it can hand the framing
// layer a surrogate pair, or a malformed lone or reversed surrogate.  A pair
// decodes to one supplementary-plane code point; an unpaired surrogate
// becomes U+FFFD (3 UTF-8 bytes) instead of an invalid UTF-16 string.
pub record CodeUnitSource {
  var units: List[Int]
  var pos: Int
}

impl CharReader for CodeUnitSource {
  func next(): Int {
    if self.pos < self.units.count {
      val c = self.units[self.pos]
      self.pos = self.pos + 1
      c
    } else {
      0 - 1
    }
  }
}

// A reader that yields `prefix`'s code units, then each of `middle`, then
// `suffix`'s code units.
func codeUnitSource(prefix: in String, middle: in slice[Int], suffix: in String): CodeUnitSource {
  val units: List[Int] = newList()
  addCodeUnits(units, prefix)
  var j = 0
  while j < middle.length {
    units.add(middle[j])
    j = j + 1
  }
  addCodeUnits(units, suffix)
  CodeUnitSource(units = units, pos = 0)
}

func addCodeUnits(units: in List[Int], s: in String): Unit {
  var i = 0
  while i < s.length {
    units.add(toInt(s[i]))
    i = i + 1
  }
}

func expectBody(src: in CodeUnitSource, expected: in String, label: in String): Unit {
  match clReceiveVia(src) {
    case Err(e) -> assertTrue(false, label + ": unexpected receive error: " + e)
    case Ok(None) -> assertTrue(false, label + ": unexpected clean EOF")
    case Ok(Some(body)) -> assertEqual(body, expected, label)
  }
}

test "Content-Length: a BMP code unit decodes to its character" {
  expectBody(codeUnitSource("Content-Length: 2\r\n\r\n", [233], ""), "é", "U+00E9 is 2 UTF-8 bytes")
}

test "Content-Length: a surrogate pair decodes to one supplementary-plane character" {
  expectBody(codeUnitSource("Content-Length: 4\r\n\r\n", [55357, 56832], ""), "😀", "U+1F600 is 4 UTF-8 bytes")
}

test "Content-Length: a lone high surrogate becomes U+FFFD" {
  expectBody(codeUnitSource("Content-Length: 4\r\n\r\n", [55357, 97], ""), "�a", "unpaired high surrogate")
}

test "Content-Length: a lone low surrogate becomes U+FFFD" {
  expectBody(codeUnitSource("Content-Length: 4\r\n\r\n", [56832, 97], ""), "�a", "unpaired low surrogate")
}

test "Content-Length: a reversed surrogate pair becomes two U+FFFD" {
  expectBody(
    codeUnitSource("Content-Length: 7\r\n\r\n", [56832, 55357, 97], ""),
    "��a",
    "low surrogate before high surrogate"
  )
}

test "Content-Length: a body ending on a high surrogate is a framing error" {
  match clReceiveVia(codeUnitSource("Content-Length: 3\r\n\r\n", [55357], "")) {
    case Ok(_) -> assertTrue(false, "expected a framing error for a body ending mid-surrogate-pair")
    case Err(_) -> ()
  }
}

test "Content-Length: a surrogate code unit in an unrelated header line does not abort the frame" {
  expectBody(
    codeUnitSource("X-Name: ", [55296], "\r\nContent-Length: 1\r\n\r\na"),
    "a",
    "header surrogate is replaced, the body still reads"
  )
}
