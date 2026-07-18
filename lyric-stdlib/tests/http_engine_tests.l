//! stdlib/tests/http_engine_tests.l — byte-level corpus for `Std.HttpEngine`
//! (docs/61-https-tls-http-versions.md §6.1/§6.4, D128; phase 3.2 of epic
//! #5874, issue #5883).
//!
//! This corpus is the sans-IO engine's security boundary spec, not
//! illustration: every RFC 9112 strictness decision documented in
//! `Std.HttpEngine`'s module header has a dedicated rejection test here
//! asserting the *exact* `ProtocolErrorKind`, plus framing/limits/keep-alive
//! coverage and two boundary-split torture tests (arbitrary 2-way splits,
//! and byte-at-a-time feeding) proving the parser is agnostic to how the
//! transport chops the wire bytes across `feed` calls.
//!
//! Runs via native `lyric test` on both targets (`--target dotnet` and
//! `--target jvm`) — the engine is pure Lyric with zero externs, so both
//! must produce identical results (a divergence would be a compiler bug,
//! not a `Std.HttpEngine` bug — see PR #5909's precedent for #5903/#5908).
@test_module
package Std.HttpEngine.Tests

import Std.Core
import Std.Collections
import Std.String
import Std.Encoding
import Std.HttpEngine
import Std.Testing

// ---------------------------------------------------------------------------
// Test infrastructure.
// ---------------------------------------------------------------------------
func bytesOf(s: in String): slice[Byte] {
  encodeUtf8(s)
}

func textOf(bytes: in slice[Byte]): String {
  match tryDecodeUtf8(bytes) {
    case Some(s) -> s
    case None -> panic("test fixture produced invalid UTF-8 body bytes")
  }
}

func appendAll(acc: in List[HttpEvent], events: in List[HttpEvent]): Unit {
  var i = 0
  while i < events.count {
    acc.add(events[i])
    i = i + 1
  }
}

/// Drive `full` through a fresh connection in one `feed` call.
func feedWhole(limits: in EngineLimits, full: in slice[Byte]): List[HttpEvent] {
  val conn = newConnection(limits)
  val result = feed(conn, full)
  result.events
}

/// Drive `full` through a fresh connection split at `splitAt` (two `feed`
/// calls: `[0, splitAt)` then `[splitAt, full.length)`).
func feedSplitAt(limits: in EngineLimits, full: in slice[Byte], splitAt: in Int): List[HttpEvent] {
  var conn = newConnection(limits)
  val acc: List[HttpEvent] = newList()
  val r1 = feed(conn, full.slice(0, splitAt))
  conn = r1.conn
  appendAll(acc, r1.events)
  val r2 = feed(conn, full.slice(splitAt, full.length))
  conn = r2.conn
  appendAll(acc, r2.events)
  acc
}

/// Drive `full` through a fresh connection one byte at a time.
func feedByteByByte(limits: in EngineLimits, full: in slice[Byte]): List[HttpEvent] {
  var conn = newConnection(limits)
  val acc: List[HttpEvent] = newList()
  var i = 0
  while i < full.length {
    val result = feed(conn, full.slice(i, i + 1))
    conn = result.conn
    appendAll(acc, result.events)
    i = i + 1
  }
  acc
}

/// Every event in `events` that is not `NeedMore` — byte-at-a-time feeding
/// produces many `NeedMore`s interspersed with the substantive events.
func dropNeedMore(events: in List[HttpEvent]): List[HttpEvent] {
  val acc: List[HttpEvent] = newList()
  var i = 0
  while i < events.count {
    match events[i] {
      case NeedMore -> ()
      case _ -> acc.add(events[i])
    }
    i = i + 1
  }
  acc
}

func assertRequestHead(e: in HttpEvent, expectedMethod: in String, expectedTarget: in String, label: in String): Unit {
  match e {
    case RequestHead(method, target, _, _) -> {
      assertEqual(method, expectedMethod, label + ": method")
      assertEqual(target, expectedTarget, label + ": target")
    }
    case _ -> panic(label + ": expected RequestHead")
  }
}

func assertBodyChunkText(e: in HttpEvent, expectedText: in String, label: in String): Unit {
  match e {
    case BodyChunk(bytes) -> assertEqual(textOf(bytes), expectedText, label + ": chunk text")
    case _ -> panic(label + ": expected BodyChunk")
  }
}

func assertRequestComplete(e: in HttpEvent, label: in String): Unit {
  match e {
    case RequestComplete -> assertTrue(true, label)
    case _ -> panic(label + ": expected RequestComplete")
  }
}

func assertExpectContinue(e: in HttpEvent, label: in String): Unit {
  match e {
    case ExpectContinue -> assertTrue(true, label)
    case _ -> panic(label + ": expected ExpectContinue")
  }
}

func kindEquals(a: in ProtocolErrorKind, b: in ProtocolErrorKind): Bool {
  match a {
    case MalformedRequestLine -> match b { case MalformedRequestLine -> true; case _ -> false }
    case RequestLineTooLong -> match b { case RequestLineTooLong -> true; case _ -> false }
    case UnsupportedRequestTarget -> match b { case UnsupportedRequestTarget -> true; case _ -> false }
    case UnsupportedVersion -> match b { case UnsupportedVersion -> true; case _ -> false }
    case MalformedHeaderLine -> match b { case MalformedHeaderLine -> true; case _ -> false }
    case WhitespaceBeforeColon -> match b { case WhitespaceBeforeColon -> true; case _ -> false }
    case ObsoleteLineFolding -> match b { case ObsoleteLineFolding -> true; case _ -> false }
    case HeaderLineTooLong -> match b { case HeaderLineTooLong -> true; case _ -> false }
    case TooManyHeaders -> match b { case TooManyHeaders -> true; case _ -> false }
    case HeadersTooLarge -> match b { case HeadersTooLarge -> true; case _ -> false }
    case ConflictingContentLength -> match b { case ConflictingContentLength -> true; case _ -> false }
    case InvalidContentLength -> match b { case InvalidContentLength -> true; case _ -> false }
    case ContentLengthWithTransferEncoding -> match b { case ContentLengthWithTransferEncoding -> true; case _ -> false }
    case InvalidTransferEncoding -> match b { case InvalidTransferEncoding -> true; case _ -> false }
    case NonFinalChunkedEncoding -> match b { case NonFinalChunkedEncoding -> true; case _ -> false }
    case UnsupportedTransferCoding -> match b { case UnsupportedTransferCoding -> true; case _ -> false }
    case MalformedChunkSize -> match b { case MalformedChunkSize -> true; case _ -> false }
    case ChunkSizeOverflow -> match b { case ChunkSizeOverflow -> true; case _ -> false }
    case BareCr -> match b { case BareCr -> true; case _ -> false }
    case BareLf -> match b { case BareLf -> true; case _ -> false }
    case MissingHost -> match b { case MissingHost -> true; case _ -> false }
    case MultipleHost -> match b { case MultipleHost -> true; case _ -> false }
    case BodyTooLarge -> match b { case BodyTooLarge -> true; case _ -> false }
  }
}

func assertProtocolError(e: in HttpEvent, expectedKind: in ProtocolErrorKind, label: in String): Unit {
  match e {
    case ProtocolError(kind, message) -> assertTrue(kindEquals(kind, expectedKind), label + ": got " + message)
    case _ -> panic(label + ": expected ProtocolError")
  }
}

/// Feed `full` to a fresh connection and assert the single resulting
/// `ProtocolError` has `expectedKind`. Only valid for rejections that fire
/// before headers finish (request-line, header-section, and framing-header
/// errors) — those are the only cases where no `RequestHead` precedes the
/// error. Body/chunk-framing errors fire after `RequestHead` has already
/// been emitted; use `assertRejectsAfterHead` for those.
func assertRejects(full: in slice[Byte], expectedKind: in ProtocolErrorKind, label: in String): Unit {
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), full))
  assertEqualInt(events.count, 1, label + ": event count")
  assertProtocolError(events[0], expectedKind, label)
}

/// Feed `full` to a fresh connection and assert the *last* event is a
/// `ProtocolError` of `expectedKind` — for rejections discovered while
/// parsing the body/chunk framing, after `RequestHead` (and possibly some
/// `BodyChunk`s) have already been emitted.
func assertRejectsAfterHead(full: in slice[Byte], expectedKind: in ProtocolErrorKind, label: in String): Unit {
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), full))
  assertTrue(events.count >= 1, label + ": at least one event")
  assertProtocolError(events[events.count - 1], expectedKind, label)
}

/// Concatenate the text of every `BodyChunk` event in `events`, in order —
/// a sans-IO engine may split one logical body across any number of
/// `BodyChunk` events depending on how the input bytes were fed, so tests
/// that care about the reconstructed body (not the exact chunk boundaries)
/// use this rather than indexing a specific event.
func reconstructBody(events: in List[HttpEvent]): String {
  var acc = ""
  var i = 0
  while i < events.count {
    match events[i] {
      case BodyChunk(bytes) -> {
        acc = acc + textOf(bytes)
      }
      case _ -> ()
    }
    i = i + 1
  }
  acc
}

// ---------------------------------------------------------------------------
// Happy path: simple GET, no body.
// ---------------------------------------------------------------------------
test "simple GET request yields RequestHead then RequestComplete" {
  val req = bytesOf("GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n")
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertEqualInt(events.count, 2, "GET event count")
  assertRequestHead(events[0], "GET", "/hello", "GET")
  assertRequestComplete(events[1], "GET")
}

test "RequestHead carries headers in wire order and case" {
  val req = bytesOf("GET / HTTP/1.1\r\nHost: example.com\r\nX-Trace-Id: abc123\r\n\r\n")
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  match events[0] {
    case RequestHead(_, _, _, headers) -> {
      assertEqualInt(headers.count, 2, "header count")
      match headerValue(headers, "host") {
        case Some(v) -> assertEqual(v, "example.com", "Host value (case-insensitive lookup)")
        case None -> panic("expected Host header")
      }
      match headerValue(headers, "X-Trace-Id") {
        case Some(v) -> assertEqual(v, "abc123", "X-Trace-Id value")
        case None -> panic("expected X-Trace-Id header")
      }
    }
    case _ -> panic("expected RequestHead")
  }
}

test "asterisk-form request-target is accepted for OPTIONS" {
  val req = bytesOf("OPTIONS * HTTP/1.1\r\nHost: example.com\r\n\r\n")
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertRequestHead(events[0], "OPTIONS", "*", "OPTIONS *")
}

test "absolute-form request-target is accepted" {
  val req = bytesOf("GET http://example.com/path HTTP/1.1\r\nHost: example.com\r\n\r\n")
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertRequestHead(events[0], "GET", "http://example.com/path", "absolute-form")
}

// ---------------------------------------------------------------------------
// Fixed-length (Content-Length) bodies.
// ---------------------------------------------------------------------------
test "POST with Content-Length body yields head, body chunk, then complete" {
  val req = bytesOf("POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 11\r\n\r\nhello world")
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertEqualInt(events.count, 3, "POST event count")
  assertRequestHead(events[0], "POST", "/submit", "POST")
  assertBodyChunkText(events[1], "hello world", "POST body")
  assertRequestComplete(events[2], "POST")
}

test "Content-Length: 0 yields no BodyChunk event" {
  val req = bytesOf("POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n")
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertEqualInt(events.count, 2, "zero-length body event count")
  assertRequestHead(events[0], "POST", "/submit", "POST")
  assertRequestComplete(events[1], "POST")
}

test "Expect: 100-continue emits ExpectContinue before the body" {
  val req = bytesOf(
    "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\nabcd"
  )
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertEqualInt(events.count, 4, "100-continue event count")
  assertRequestHead(events[0], "POST", "/submit", "100-continue")
  assertExpectContinue(events[1], "100-continue")
  assertBodyChunkText(events[2], "abcd", "100-continue body")
  assertRequestComplete(events[3], "100-continue")
}

// ---------------------------------------------------------------------------
// Chunked bodies: extensions and trailers.
// ---------------------------------------------------------------------------
test "chunked body with extensions and trailers parses payload and discards trailers" {
  val req = bytesOf(
    "POST /upload HTTP/1.1\r\n" + "Host: example.com\r\n" + "Transfer-Encoding: chunked\r\n" + "\r\n" +
      "5;ext=1\r\n" +
      "Hello\r\n" +
      "6\r\n" +
      " World\r\n" +
      "0\r\n" +
      "X-Trailer: discarded\r\n" +
      "\r\n"
  )
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertEqualInt(events.count, 4, "chunked event count")
  assertRequestHead(events[0], "POST", "/upload", "chunked")
  assertBodyChunkText(events[1], "Hello", "chunked chunk 1")
  assertBodyChunkText(events[2], " World", "chunked chunk 2")
  assertRequestComplete(events[3], "chunked")
}

// ---------------------------------------------------------------------------
// Keep-alive pipelining and boundary-split torture.
// ---------------------------------------------------------------------------
test "keep-alive pipeline of two sequential requests fed in one buffer" {
  val req = bytesOf(
    "GET /first HTTP/1.1\r\nHost: example.com\r\n\r\n" + "GET /second HTTP/1.1\r\nHost: example.com\r\n\r\n"
  )
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertEqualInt(events.count, 4, "pipelined event count")
  assertRequestHead(events[0], "GET", "/first", "pipeline request 1")
  assertRequestComplete(events[1], "pipeline request 1")
  assertRequestHead(events[2], "GET", "/second", "pipeline request 2")
  assertRequestComplete(events[3], "pipeline request 2")
}

test "the pipelined buffer re-fed one byte at a time parses identically" {
  val req = bytesOf(
    "GET /first HTTP/1.1\r\nHost: example.com\r\n\r\n" + "GET /second HTTP/1.1\r\nHost: example.com\r\n\r\n"
  )
  val events = dropNeedMore(feedByteByByte(EngineLimits.defaults(), req))
  assertEqualInt(events.count, 4, "byte-at-a-time pipelined event count")
  assertRequestHead(events[0], "GET", "/first", "byte-fed request 1")
  assertRequestComplete(events[1], "byte-fed request 1")
  assertRequestHead(events[2], "GET", "/second", "byte-fed request 2")
  assertRequestComplete(events[3], "byte-fed request 2")
}

test "boundary-split torture: every 2-way split of a representative request parses correctly" {
  val req = bytesOf(
    "POST /submit HTTP/1.1\r\n" + "Host: example.com\r\n" + "Content-Length: 11\r\n" + "\r\n" + "hello world"
  )
  // A split landing mid-body produces two `BodyChunk` events instead of
  // one (each `feed` call only emits the bytes it was actually handed) —
  // that is correct sans-IO behavior, not a bug, so this asserts the
  // reconstructed body text rather than a fixed event count/shape.
  var splitAt = 1
  while splitAt < req.length {
    val events = dropNeedMore(feedSplitAt(EngineLimits.defaults(), req, splitAt))
    val label = "split at byte " + toString(splitAt)
    assertRequestHead(events[0], "POST", "/submit", label)
    assertEqual(reconstructBody(events), "hello world", label + ": reconstructed body")
    assertRequestComplete(events[events.count - 1], label)
    splitAt = splitAt + 1
  }
}

test "boundary-split torture over a chunked request" {
  val req = bytesOf(
    "POST /upload HTTP/1.1\r\n" + "Host: example.com\r\n" + "Transfer-Encoding: chunked\r\n" + "\r\n" +
      "5\r\n" +
      "Hello\r\n" +
      "0\r\n" +
      "\r\n"
  )
  var splitAt = 1
  while splitAt < req.length {
    val events = dropNeedMore(feedSplitAt(EngineLimits.defaults(), req, splitAt))
    val label = "chunked split at byte " + toString(splitAt)
    assertRequestHead(events[0], "POST", "/upload", label)
    assertEqual(reconstructBody(events), "Hello", label + ": reconstructed body")
    assertRequestComplete(events[events.count - 1], label)
    splitAt = splitAt + 1
  }
}

// ---------------------------------------------------------------------------
// Rejections — request line.
// ---------------------------------------------------------------------------
test "request line with no spaces is MalformedRequestLine" {
  assertRejects(bytesOf("GARBAGE\r\n\r\n"), MalformedRequestLine, "no-spaces request line")
}

test "request line with only one space is MalformedRequestLine" {
  assertRejects(bytesOf("GET /only-one-space\r\n\r\n"), MalformedRequestLine, "one-space request line")
}

test "empty method token is MalformedRequestLine" {
  assertRejects(bytesOf(" / HTTP/1.1\r\n\r\n"), MalformedRequestLine, "empty method")
}

test "request line exceeding the configured limit is RequestLineTooLong" {
  val hugeTarget = "/" + repeat("a", 9000)
  assertRejects(bytesOf("GET " + hugeTarget + " HTTP/1.1\r\n\r\n"), RequestLineTooLong, "oversized request line")
}

test "authority-form request-target is UnsupportedRequestTarget" {
  assertRejects(bytesOf("GET example.com:80 HTTP/1.1\r\n\r\n"), UnsupportedRequestTarget, "authority-form target")
}

test "asterisk-form request-target with a non-OPTIONS method is UnsupportedRequestTarget" {
  assertRejects(bytesOf("GET * HTTP/1.1\r\n\r\n"), UnsupportedRequestTarget, "asterisk-form with GET")
}

test "unrecognized HTTP version token is UnsupportedVersion" {
  assertRejects(bytesOf("GET / HTTP/2.0\r\n\r\n"), UnsupportedVersion, "HTTP/2.0 request line")
}

test "bare LF in the request line is BareLf" {
  assertRejects(bytesOf("GET / HTTP/1.1\n\r\n"), BareLf, "bare LF request line")
}

test "bare CR in the request line is BareCr" {
  assertRejects(bytesOf("GET / HTTP/1.1\rX"), BareCr, "bare CR request line")
}

// ---------------------------------------------------------------------------
// Rejections — header section.
// ---------------------------------------------------------------------------
test "header line with no colon is MalformedHeaderLine" {
  assertRejects(bytesOf("GET / HTTP/1.1\r\nNotAHeader\r\n\r\n"), MalformedHeaderLine, "no-colon header")
}

test "whitespace between header field-name and colon is WhitespaceBeforeColon" {
  assertRejects(bytesOf("GET / HTTP/1.1\r\nHost : example.com\r\n\r\n"), WhitespaceBeforeColon, "space before colon")
}

test "obs-fold header continuation is ObsoleteLineFolding" {
  assertRejects(bytesOf("GET / HTTP/1.1\r\nX-Multi: one\r\n two\r\n\r\n"), ObsoleteLineFolding, "obs-fold continuation")
}

test "non-ASCII (obs-text) bytes in a header value are MalformedHeaderLine" {
  // encodeUtf8("café") produces a two-byte UTF-8 sequence (0xC3 0xA9) for
  // "e", both bytes > 0x7E — outside field-vchar, rejected per RFC 9110
  // section 5.5 (see Std.HttpEngine's module header).
  assertRejects(bytesOf("GET / HTTP/1.1\r\nX-Name: café\r\n\r\n"), MalformedHeaderLine, "non-ASCII header value")
}

test "bare LF inside the header section is BareLf" {
  assertRejects(bytesOf("GET / HTTP/1.1\r\nHost: example.com\nX-Bad: 1\r\n\r\n"), BareLf, "bare LF header")
}

test "too many headers is TooManyHeaders" {
  val limits = EngineLimits(
    maxRequestLineLength = 8192,
    maxHeaderCount = 2,
    maxHeaderLineLength = 8192,
    maxTotalHeaderBytes = 65536,
    maxBodyBytes = 10485760
  )
  val req = bytesOf("GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n")
  val events = dropNeedMore(feedWhole(limits, req))
  assertEqualInt(events.count, 1, "too-many-headers event count")
  assertProtocolError(events[0], TooManyHeaders, "too many headers")
}

test "a single oversized header line is HeaderLineTooLong" {
  val limits = EngineLimits(
    maxRequestLineLength = 8192,
    maxHeaderCount = 100,
    maxHeaderLineLength = 32,
    maxTotalHeaderBytes = 65536,
    maxBodyBytes = 10485760
  )
  val req = bytesOf("GET / HTTP/1.1\r\nX-Long: " + repeat("a", 100) + "\r\n\r\n")
  val events = dropNeedMore(feedWhole(limits, req))
  assertEqualInt(events.count, 1, "oversized header line event count")
  assertProtocolError(events[0], HeaderLineTooLong, "oversized header line")
}

test "total header bytes exceeding the configured limit is HeadersTooLarge" {
  // Each header line below ("A: 111111\r\n" etc.) is 11 bytes; the limit
  // (15) is deliberately set to admit the first header (11 <= 15) but
  // reject the second (22 > 15), so this exercises the cumulative-total
  // check rather than the per-line check (`HeaderLineTooLong`, covered
  // separately above).
  val limits = EngineLimits(
    maxRequestLineLength = 8192,
    maxHeaderCount = 100,
    maxHeaderLineLength = 8192,
    maxTotalHeaderBytes = 15,
    maxBodyBytes = 10485760
  )
  val req = bytesOf("GET / HTTP/1.1\r\nA: 111111\r\nB: 222222\r\nC: 333333\r\n\r\n")
  val events = dropNeedMore(feedWhole(limits, req))
  assertEqualInt(events.count, 1, "total header bytes event count")
  assertProtocolError(events[0], HeadersTooLarge, "total header bytes exceeded")
}

// ---------------------------------------------------------------------------
// Rejections — framing (Content-Length / Transfer-Encoding), RFC 9112 6.3.
// ---------------------------------------------------------------------------
test "conflicting Content-Length values are ConflictingContentLength" {
  assertRejects(
    bytesOf("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello"),
    ConflictingContentLength,
    "conflicting Content-Length"
  )
}

test "identical repeated Content-Length values are tolerated" {
  val req = bytesOf("POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello")
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertEqualInt(events.count, 3, "repeated identical Content-Length event count")
  assertBodyChunkText(events[1], "hello", "repeated identical Content-Length body")
}

test "a non-digit Content-Length value is InvalidContentLength" {
  assertRejects(
    bytesOf("POST / HTTP/1.1\r\nContent-Length: five\r\n\r\nhello"),
    InvalidContentLength,
    "non-digit Content-Length"
  )
}

test "Content-Length together with Transfer-Encoding is rejected (RFC 9112 6.3)" {
  assertRejects(
    bytesOf("POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"),
    ContentLengthWithTransferEncoding,
    "Content-Length + Transfer-Encoding"
  )
}

test "an empty Transfer-Encoding header is InvalidTransferEncoding" {
  assertRejects(
    bytesOf("POST / HTTP/1.1\r\nTransfer-Encoding: \r\n\r\n"),
    InvalidTransferEncoding,
    "empty Transfer-Encoding"
  )
}

test "chunked not the final transfer-coding is NonFinalChunkedEncoding" {
  assertRejects(
    bytesOf("POST / HTTP/1.1\r\nTransfer-Encoding: chunked, gzip\r\n\r\n"),
    NonFinalChunkedEncoding,
    "chunked not final"
  )
}

test "Transfer-Encoding ending in chunked after another coding is accepted" {
  val req = bytesOf(
    "POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip, chunked\r\n\r\n5\r\nHello\r\n0\r\n\r\n"
  )
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertEqualInt(events.count, 3, "gzip-then-chunked event count")
  assertBodyChunkText(events[1], "Hello", "gzip-then-chunked body")
}

test "a Transfer-Encoding with no chunked coding present is UnsupportedTransferCoding" {
  assertRejects(
    bytesOf("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n"),
    UnsupportedTransferCoding,
    "no chunked coding present"
  )
}

// ---------------------------------------------------------------------------
// Rejections — chunk framing.
// ---------------------------------------------------------------------------
// These three rejections are discovered while parsing the chunk framing,
// which happens after the request line and headers already parsed
// successfully — so `RequestHead` (and any complete chunks) precede the
// `ProtocolError`; `assertRejectsAfterHead` checks only the last event.
test "a chunk-size line with no hex digits is MalformedChunkSize" {
  assertRejectsAfterHead(
    bytesOf("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\nZZZ\r\n\r\n"),
    MalformedChunkSize,
    "non-hex chunk size"
  )
}

test "a chunk size with more than 7 hex digits is ChunkSizeOverflow" {
  assertRejectsAfterHead(
    bytesOf("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFF\r\n\r\n"),
    ChunkSizeOverflow,
    "overflow chunk size"
  )
}

test "chunk data not followed by CRLF is MalformedChunkSize" {
  assertRejectsAfterHead(
    bytesOf("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHelloXX0\r\n\r\n"),
    MalformedChunkSize,
    "chunk data missing CRLF"
  )
}

test "bare LF in a chunk-size line is BareLf" {
  assertRejectsAfterHead(
    bytesOf("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\nHello\r\n0\r\n\r\n"),
    BareLf,
    "bare LF chunk-size line"
  )
}

// ---------------------------------------------------------------------------
// Rejections — Host header (RFC 9112 3.2).
// ---------------------------------------------------------------------------
test "an HTTP/1.1 request without a Host header is MissingHost" {
  assertRejects(bytesOf("GET / HTTP/1.1\r\n\r\n"), MissingHost, "missing Host")
}

test "an HTTP/1.1 request with duplicate Host headers is MultipleHost" {
  assertRejects(
    bytesOf("GET / HTTP/1.1\r\nHost: a.example.com\r\nHost: b.example.com\r\n\r\n"),
    MultipleHost,
    "duplicate Host"
  )
}

test "an HTTP/1.0 request without a Host header is accepted" {
  val req = bytesOf("GET / HTTP/1.0\r\n\r\n")
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), req))
  assertEqualInt(events.count, 2, "HTTP/1.0 no-Host event count")
  assertRequestHead(events[0], "GET", "/", "HTTP/1.0 no-Host")
  assertRequestComplete(events[1], "HTTP/1.0 no-Host")
}

// ---------------------------------------------------------------------------
// Rejections — body size limit (`EngineLimits.maxBodyBytes`).
// ---------------------------------------------------------------------------
test "a fixed-length body exceeding maxBodyBytes is BodyTooLarge" {
  val limits = EngineLimits(
    maxRequestLineLength = 8192,
    maxHeaderCount = 100,
    maxHeaderLineLength = 8192,
    maxTotalHeaderBytes = 65536,
    maxBodyBytes = 4
  )
  val req = bytesOf("POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 11\r\n\r\nhello world")
  val events = dropNeedMore(feedWhole(limits, req))
  // The oversized-body check runs after `RequestHead` is already emitted
  // (the length is only known once framing has been analyzed), so this
  // asserts the *last* event rather than a single-event rejection.
  assertTrue(events.count >= 1, "oversized fixed-length body: at least one event")
  assertProtocolError(events[events.count - 1], BodyTooLarge, "oversized fixed-length body")
}

test "a chunked body whose cumulative size exceeds maxBodyBytes is BodyTooLarge" {
  val limits = EngineLimits(
    maxRequestLineLength = 8192,
    maxHeaderCount = 100,
    maxHeaderLineLength = 8192,
    maxTotalHeaderBytes = 65536,
    maxBodyBytes = 8
  )
  val req = bytesOf(
    "POST /upload HTTP/1.1\r\n" + "Host: example.com\r\n" + "Transfer-Encoding: chunked\r\n" + "\r\n" +
      "5\r\n" +
      "Hello\r\n" +
      "5\r\n" +
      "World\r\n" +
      "0\r\n" +
      "\r\n"
  )
  val events = dropNeedMore(feedWhole(limits, req))
  assertTrue(events.count >= 1, "cumulative chunked body too large: at least one event")
  assertProtocolError(events[events.count - 1], BodyTooLarge, "cumulative chunked body too large")
}

// ---------------------------------------------------------------------------
// HTTP/1.0 semantics and keep-alive.
// ---------------------------------------------------------------------------
test "HTTP/1.0 without Content-Length has zero body and defaults to close" {
  val req = bytesOf("GET / HTTP/1.0\r\nHost: example.com\r\n\r\n")
  val conn0 = newConnection(EngineLimits.defaults())
  val result = feed(conn0, req)
  val events = dropNeedMore(result.events)
  assertEqualInt(events.count, 2, "HTTP/1.0 event count")
  assertRequestHead(events[0], "GET", "/", "HTTP/1.0")
  assertRequestComplete(events[1], "HTTP/1.0")
  assertTrue(shouldClose(result.conn), "HTTP/1.0 defaults to Connection: close")
}

test "HTTP/1.0 with Connection: keep-alive stays open" {
  val req = bytesOf("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
  val conn0 = newConnection(EngineLimits.defaults())
  val result = feed(conn0, req)
  assertFalse(shouldClose(result.conn), "HTTP/1.0 keep-alive opt-in stays open")
}

test "HTTP/1.1 defaults to keep-alive" {
  val req = bytesOf("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
  val conn0 = newConnection(EngineLimits.defaults())
  val result = feed(conn0, req)
  assertFalse(shouldClose(result.conn), "HTTP/1.1 defaults to keep-alive")
}

test "HTTP/1.1 with Connection: close closes" {
  val req = bytesOf("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
  val conn0 = newConnection(EngineLimits.defaults())
  val result = feed(conn0, req)
  assertTrue(shouldClose(result.conn), "HTTP/1.1 Connection: close closes")
}

test "a ProtocolError marks the connection failed and closed" {
  val req = bytesOf("GARBAGE\r\n\r\n")
  val conn0 = newConnection(EngineLimits.defaults())
  val result = feed(conn0, req)
  assertTrue(isFailed(result.conn), "connection is failed after ProtocolError")
  assertTrue(shouldClose(result.conn), "connection closes after ProtocolError")
}

// ---------------------------------------------------------------------------
// protocolErrorStatus.
// ---------------------------------------------------------------------------
test "protocolErrorStatus maps known kinds to their documented status codes" {
  assertEqualInt(protocolErrorStatus(MalformedRequestLine), 400, "MalformedRequestLine status")
  assertEqualInt(protocolErrorStatus(RequestLineTooLong), 414, "RequestLineTooLong status")
  assertEqualInt(protocolErrorStatus(UnsupportedVersion), 505, "UnsupportedVersion status")
  assertEqualInt(protocolErrorStatus(HeaderLineTooLong), 431, "HeaderLineTooLong status")
  assertEqualInt(protocolErrorStatus(TooManyHeaders), 431, "TooManyHeaders status")
  assertEqualInt(protocolErrorStatus(HeadersTooLarge), 431, "HeadersTooLarge status")
  assertEqualInt(protocolErrorStatus(ContentLengthWithTransferEncoding), 400, "smuggling-defense status")
  assertEqualInt(protocolErrorStatus(UnsupportedTransferCoding), 400, "UnsupportedTransferCoding status")
  assertEqualInt(protocolErrorStatus(MissingHost), 400, "MissingHost status")
  assertEqualInt(protocolErrorStatus(MultipleHost), 400, "MultipleHost status")
  assertEqualInt(protocolErrorStatus(BodyTooLarge), 413, "BodyTooLarge status")
}

// ---------------------------------------------------------------------------
// Response serialization.
// ---------------------------------------------------------------------------
test "serializeResponseHead formats a status line, headers, and blank line" {
  val headers: List[HeaderField] = newList()
  headers.add(HeaderField(name = "Content-Type", value = "text/plain"))
  headers.add(HeaderField(name = "Content-Length", value = "5"))
  val head = serializeResponseHead(Http1_1, 200, "OK", headers)
  assertEqual(
    textOf(head),
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\n",
    "response head bytes"
  )
}

test "serializeResponseHead accepts an empty reason-phrase and HTAB in a header value" {
  // RFC 9112 section 4 permits an empty reason-phrase; RFC 9110 section 5.5
  // permits HTAB inside a field-value. Neither is a response-splitting risk
  // (only CR/LF/NUL are), so both are accepted rather than rejected by the
  // `requires:` contract.
  val headers: List[HeaderField] = newList()
  headers.add(HeaderField(name = "X-Note", value = "a\tb"))
  val head = serializeResponseHead(Http1_1, 204, "", headers)
  assertEqual(textOf(head), "HTTP/1.1 204 \r\nX-Note: a\tb\r\n\r\n", "empty reason + HTAB header value")
}

test "HEAD-response serialization has a head but no body bytes written" {
  // Std.HttpEngine does not special-case HEAD: the driver (which knows the
  // request method) is responsible for withholding the body. What this
  // engine guarantees is that serializeResponseHead never itself emits
  // body bytes — only status line, headers, and the terminating blank line.
  val headers: List[HeaderField] = newList()
  headers.add(HeaderField(name = "Content-Length", value = "12"))
  val head = serializeResponseHead(Http1_1, 200, "OK", headers)
  assertTrue(endsWith(textOf(head), "\r\n\r\n"), "response head ends with the blank-line terminator")
  assertFalse(contains(textOf(head), "Hello"), "no body bytes are present in the serialized head")
}

test "serializeFixedLengthBody is the identity function" {
  val body = bytesOf("hello world")
  val passthrough = serializeFixedLengthBody(body)
  assertEqual(textOf(passthrough), "hello world", "fixed-length body passthrough")
}

test "chunked response serialization round-trips through the request parser" {
  // The chunked wire grammar is directionally symmetric (RFC 9112 section
  // 7.1 applies identically to requests and responses), so feeding the
  // serializer's own output back through the request-body chunk parser is
  // a genuine round-trip check that the two halves agree on the wire format.
  val chunk1 = serializeChunk(bytesOf("Hello, "))
  val chunk2 = serializeChunk(bytesOf("chunked world!"))
  val last = serializeLastChunk()
  val body = chunk1.concat(chunk2).concat(last)
  val head = bytesOf("POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n")
  val full = head.concat(body)
  val events = dropNeedMore(feedWhole(EngineLimits.defaults(), full))
  assertEqualInt(events.count, 4, "round-trip event count")
  assertRequestHead(events[0], "POST", "/upload", "round-trip")
  assertBodyChunkText(events[1], "Hello, ", "round-trip chunk 1")
  assertBodyChunkText(events[2], "chunked world!", "round-trip chunk 2")
  assertRequestComplete(events[3], "round-trip")
}

test "EngineLimits.defaults() returns sane production values" {
  val d = EngineLimits.defaults()
  assertEqualInt(d.maxRequestLineLength, 8192, "default max request-line length")
  assertEqualInt(d.maxHeaderCount, 100, "default max header count")
  assertEqualInt(d.maxHeaderLineLength, 8192, "default max header line length")
  assertEqualInt(d.maxTotalHeaderBytes, 65536, "default max total header bytes")
  assertEqualInt(d.maxBodyBytes, 10485760, "default max body bytes")
}

test "httpVersionToken renders the wire tokens" {
  assertEqual(httpVersionToken(Http1_1), "HTTP/1.1", "HTTP/1.1 token")
  assertEqual(httpVersionToken(Http1_0), "HTTP/1.0", "HTTP/1.0 token")
}
