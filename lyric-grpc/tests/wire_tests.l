//! tests/wire_tests.l — `Grpc.Wire`: framing, message reassembly, gzip,
//! `grpc-timeout` encoding and the status mapping tables (docs/72 slice 6,
//! D802). Pure functions over bytes, so this suite needs no socket and runs
//! unchanged on every target.
@test_module
package Grpc.WireTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.Iter
import Std.HttpEngine
import Std.HttpEngine.H2Frame
import Std.HttpEngine.H2Client
import Grpc.Types
import Grpc.Wire

func bytesOf(xs: in List[Int]): slice[Byte] {
  val acc: List[Byte] = newList()
  for x in xs {
    acc.add(x.toByte())
  }
  acc.toArray()
}

func repeated(n: in Int, v: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < n {
    acc.add((v + i).and(255).toByte())
    i = i + 1
  }
  acc.toArray()
}

func codeOf(st: in GrpcStatus): Int {
  statusCodeToInt(st.code)
}

func fields(pairs: in List[String]): List[HeaderField] {
  val hs: List[HeaderField] = newList()
  var i = 0
  while i + 1 < pairs.count {
    hs.add(HeaderField(name = pairs[i], value = pairs[i + 1]))
    i = i + 2
  }
  hs
}

// ─── Framing and reassembly ──────────────────────────────────────────────────
test "frameMessage: flag, big-endian length, then the payload" {
  val framed = frameMessage(bytesOf([7, 8, 9]), false)
  assertEqualInt(framed.length, 8, "length")
  assertEqualInt(framed[0].toInt(), 0, "flag")
  assertEqualInt(framed[4].toInt(), 3, "length low byte")
  assertEqualInt(framed[5].toInt(), 7, "payload")
  assertEqualInt(frameMessage(bytesOf([]), true)[0].toInt(), 1, "compressed flag")
  val big = frameMessage(repeated(70000, 0), false)
  assertEqualInt(big[2].toInt(), 1, "70000 = 0x00011170, byte 2")
  assertEqualInt(big[3].toInt(), 17, "byte 3")
  assertEqualInt(big[4].toInt(), 112, "byte 4")
}

func pollPayload(r: in MessageReader): Int {
  match readerPoll(r) {
    case WireMessage(_, p) -> p.length
    case WireNeedMore -> -1
    case WireTooLarge(_) -> -2
    case WireBadFlag(_) -> -3
  }
}

test "MessageReader: one message arriving a byte at a time" {
  val r = newMessageReader(1000)
  val framed = frameMessage(repeated(40, 3), false)
  var i = 0
  while i < framed.length - 1 {
    readerFeed(r, framed.slice(i, i + 1))
    assertEqualInt(pollPayload(r), -1, "incomplete after " + (i + 1).toString() + " bytes")
    i = i + 1
  }
  readerFeed(r, framed.slice(framed.length - 1, framed.length))
  match readerPoll(r) {
    case WireMessage(c, p) -> {
      assertFalse(c, "not compressed")
      assertEqualInt(p.length, 40, "payload length")
      assertEqualInt(p[0].toInt(), 3, "first byte")
      assertEqualInt(p[39].toInt(), 42, "last byte")
    }
    case _ -> assertTrue(false, "a whole message must be returned")
  }
  assertEqualInt(readerBuffered(r), 0, "nothing left")
}

test "MessageReader: several messages in one chunk, and a message spanning chunks" {
  val r = newMessageReader(1000)
  val a = frameMessage(bytesOf([1, 2]), false)
  val b = frameMessage(bytesOf([3]), false)
  val c = frameMessage(repeated(300, 0), true)
  val all = concat(concat(a, b), c)
  readerFeed(r, all.slice(0, 10))
  assertEqualInt(pollPayload(r), 2, "first message")
  assertEqualInt(pollPayload(r), -1, "second is incomplete (8 bytes of it are held)")
  readerFeed(r, all.slice(10, 200))
  assertEqualInt(pollPayload(r), 1, "second message")
  assertEqualInt(pollPayload(r), -1, "third spans chunks")
  readerFeed(r, all.slice(200, all.length))
  match readerPoll(r) {
    case WireMessage(compressed, p) -> {
      assertTrue(compressed, "third is flagged compressed")
      assertEqualInt(p.length, 300, "third length")
    }
    case _ -> assertTrue(false, "third message")
  }
  assertEqualInt(readerBuffered(r), 0, "all consumed")
}

test "MessageReader: many chunks are compacted and every message survives" {
  val r = newMessageReader(100000)
  var i = 0
  var total = 0
  while i < 200 {
    readerFeed(r, frameMessage(repeated(10 + i, i), false))
    i = i + 1
  }
  i = 0
  while i < 200 {
    val n = pollPayload(r)
    assertEqualInt(n, 10 + i, "message " + i.toString())
    total = total + n
    i = i + 1
  }
  assertEqualInt(pollPayload(r), -1, "drained")
  assertEqualInt(readerBuffered(r), 0, "no bytes buffered")
  assertTrue(total > 0, "read something")
}

test "MessageReader: an oversize prefix is refused before its payload arrives" {
  val r = newMessageReader(10)
  readerFeed(r, bytesOf([0, 0, 0, 0, 11]))
  match readerPoll(r) {
    case WireTooLarge(n) -> assertEqualLong(n, 11i64, "announced length")
    case _ -> assertTrue(false, "11 > 10 must be refused on the prefix alone")
  }
  val r2 = newMessageReader(10)
  readerFeed(r2, bytesOf([0, 255, 255, 255, 255]))
  match readerPoll(r2) {
    case WireTooLarge(n) -> assertEqualLong(n, 4294967295i64, "a 4 GiB prefix is a Long, not a negative Int")
    case _ -> assertTrue(false, "4 GiB prefix")
  }
  val r3 = newMessageReader(10)
  readerFeed(r3, bytesOf([0, 0, 0, 0, 10]))
  assertEqualInt(pollPayload(r3), -1, "exactly the limit is accepted and waits for its payload")
}

test "MessageReader: a flag other than 0 or 1 is rejected" {
  val r = newMessageReader(10)
  readerFeed(r, bytesOf([2, 0, 0, 0, 0]))
  match readerPoll(r) {
    case WireBadFlag(f) -> assertEqualInt(f, 2, "flag")
    case _ -> assertTrue(false, "flag 2")
  }
}

// ─── Compression ─────────────────────────────────────────────────────────────
test "gzip: a message round-trips, and the output bound is enforced" {
  val payload = repeated(5000, 9)
  val packed = compressMessage(payload)
  match decompressMessage("gzip", packed, 10000) {
    case Ok(back) -> {
      assertEqualInt(back.length, 5000, "length")
      assertEqualInt(back[4999].toInt(), payload[4999].toInt(), "last byte")
    }
    case Err(st) -> assertTrue(false, "round trip failed: " + st.message)
  }
  match decompressMessage("gzip", packed, 4999) {
    case Ok(_) -> assertTrue(false, "a bomb must be refused")
    case Err(st) -> assertEqualInt(codeOf(st), 8, "ResourceExhausted")
  }
}

test "gzip: corrupt data is Internal, unknown encodings Unimplemented, a flag without encoding Internal" {
  match decompressMessage("gzip", bytesOf([1, 2, 3, 4]), 100) {
    case Ok(_) -> assertTrue(false, "garbage is not gzip")
    case Err(st) -> assertEqualInt(codeOf(st), 13, "Internal")
  }
  match decompressMessage("snappy", bytesOf([1]), 100) {
    case Ok(_) -> assertTrue(false, "snappy is not implemented")
    case Err(st) -> assertEqualInt(codeOf(st), 12, "Unimplemented")
  }
  match decompressMessage("", bytesOf([1]), 100) {
    case Ok(_) -> assertTrue(false, "no encoding")
    case Err(st) -> assertEqualInt(codeOf(st), 13, "Internal")
  }
  match decompressMessage("identity", bytesOf([1]), 100) {
    case Ok(_) -> assertTrue(false, "identity with a compressed flag")
    case Err(st) -> assertEqualInt(codeOf(st), 13, "Internal")
  }
}

// ─── grpc-timeout ────────────────────────────────────────────────────────────
test "encodeTimeout: milliseconds, then coarser units rounded up, never over 8 digits" {
  assertEqual(encodeTimeout(1), "1m", "1 ms")
  assertEqual(encodeTimeout(2500), "2500m", "2.5 s")
  assertEqual(encodeTimeout(99999999), "99999999m", "the last millisecond value")
  assertEqual(encodeTimeout(100000000), "100000S", "rounds to seconds")
  assertEqual(encodeTimeout(100000001), "100001S", "rounds up")
  assertEqual(encodeTimeout(2147483647), "2147484S", "the largest Int")
}

func timeoutMs(v: in String): Long {
  match parseTimeout(v) {
    case Some(ms) -> ms
    case None -> -1i64
  }
}

test "parseTimeout: every unit, rounded up to a millisecond, and round-trips encodeTimeout" {
  assertEqualLong(timeoutMs("1H"), 3600000i64, "hours")
  assertEqualLong(timeoutMs("2M"), 120000i64, "minutes")
  assertEqualLong(timeoutMs("3S"), 3000i64, "seconds")
  assertEqualLong(timeoutMs("250m"), 250i64, "milliseconds")
  assertEqualLong(timeoutMs("1500u"), 2i64, "microseconds round up")
  assertEqualLong(timeoutMs("1000u"), 1i64, "an exact microsecond multiple")
  assertEqualLong(timeoutMs("1n"), 1i64, "a nanosecond is one millisecond")
  assertEqualLong(timeoutMs("0m"), 0i64, "zero")
  assertEqualLong(timeoutMs("99999999H"), 99999999i64 * 3600000i64, "eight digits of hours does not overflow")
  assertEqualLong(timeoutMs(encodeTimeout(2500)), 2500i64, "round trip ms")
  assertEqualLong(timeoutMs(encodeTimeout(100000001)), 100001000i64, "round trip rounds up with the encoder")
}

test "parseTimeout: anything that is not digits and a unit is None" {
  assertTrue(parseTimeout("").isNone(), "empty")
  assertTrue(parseTimeout("m").isNone(), "no digits")
  assertTrue(parseTimeout("10").isNone(), "no unit")
  assertTrue(parseTimeout("10x").isNone(), "unknown unit")
  assertTrue(parseTimeout("-1S").isNone(), "sign")
  assertTrue(parseTimeout("+1S").isNone(), "plus sign")
  assertTrue(parseTimeout("1 S").isNone(), "space")
  assertTrue(parseTimeout("123456789S").isNone(), "nine digits")
  assertTrue(parseTimeout("1s").isNone(), "lowercase seconds is not a unit")
}

// ─── Content type ────────────────────────────────────────────────────────────
test "isGrpcContentType: application/grpc and its suffixed forms only" {
  assertTrue(isGrpcContentType("application/grpc"), "bare")
  assertTrue(isGrpcContentType("application/grpc+proto"), "+proto")
  assertTrue(isGrpcContentType("application/grpc+json"), "+json")
  assertTrue(isGrpcContentType("Application/GRPC"), "case-insensitive")
  assertTrue(isGrpcContentType("application/grpc; charset=utf-8"), "parameter")
  assertFalse(isGrpcContentType("application/grpc-web"), "grpc-web is a different protocol")
  assertFalse(isGrpcContentType("application/json"), "json")
  assertFalse(isGrpcContentType("text/html"), "html")
  assertFalse(isGrpcContentType(""), "empty")
}

// ─── Status mapping tables ───────────────────────────────────────────────────
test "statusFromHttpStatus: the gRPC HTTP status table" {
  assertEqualInt(codeOf(statusFromHttpStatus(400)), 13, "400 Internal")
  assertEqualInt(codeOf(statusFromHttpStatus(401)), 16, "401 Unauthenticated")
  assertEqualInt(codeOf(statusFromHttpStatus(403)), 7, "403 PermissionDenied")
  assertEqualInt(codeOf(statusFromHttpStatus(404)), 12, "404 Unimplemented")
  assertEqualInt(codeOf(statusFromHttpStatus(429)), 14, "429 Unavailable")
  assertEqualInt(codeOf(statusFromHttpStatus(502)), 14, "502 Unavailable")
  assertEqualInt(codeOf(statusFromHttpStatus(503)), 14, "503 Unavailable")
  assertEqualInt(codeOf(statusFromHttpStatus(504)), 14, "504 Unavailable")
  assertEqualInt(codeOf(statusFromHttpStatus(500)), 2, "500 Unknown")
  assertEqualInt(codeOf(statusFromHttpStatus(302)), 2, "302 Unknown")
  assertTrue(statusFromHttpStatus(503).message.length > 0, "the message names the HTTP status")
}

test "statusFromFailure: the HTTP/2 failure table" {
  assertEqualInt(codeOf(statusFromFailure(H2FailDeadlineExceeded)), 4, "deadline")
  assertEqualInt(codeOf(statusFromFailure(H2FailCancelled)), 1, "cancelled")
  assertEqualInt(codeOf(statusFromFailure(H2FailRefused)), 14, "refused")
  assertEqualInt(codeOf(statusFromFailure(H2FailUnprocessed)), 14, "unprocessed")
  assertEqualInt(codeOf(statusFromFailure(H2FailConnectionLost(message = "eof"))), 14, "connection lost")
  assertEqualInt(
    codeOf(statusFromFailure(H2FailProtocol(errorCode = H2ProtocolError, message = "bad"))),
    13,
    "protocol"
  )
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2NoError))), 13, "RST NO_ERROR")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2ProtocolError))), 13, "RST PROTOCOL_ERROR")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2InternalError))), 13, "RST INTERNAL_ERROR")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2FlowControlError))), 13, "RST FLOW_CONTROL_ERROR")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2StreamClosed))), 13, "RST STREAM_CLOSED")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2FrameSizeError))), 13, "RST FRAME_SIZE_ERROR")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2CompressionError))), 13, "RST COMPRESSION_ERROR")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2UnknownError(code = 99i64)))), 13, "RST unknown")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2RefusedStream))), 14, "RST REFUSED_STREAM")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2Cancel))), 1, "RST CANCEL")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2EnhanceYourCalm))), 8, "RST ENHANCE_YOUR_CALM")
  assertEqualInt(codeOf(statusFromFailure(H2FailReset(errorCode = H2InadequateSecurity))), 7, "RST INADEQUATE_SECURITY")
}

test "statusFromFields: grpc-status, percent-decoded grpc-message, and the invalid forms" {
  match statusFromFields(fields(["content-type", "application/grpc"])) {
    case Some(_) -> assertTrue(false, "no grpc-status is None")
    case None -> ()
  }
  match statusFromFields(fields(["grpc-status", "5", "grpc-message", "not%20found%0A"])) {
    case Some(st) -> {
      assertEqualInt(codeOf(st), 5, "NotFound")
      assertEqual(st.message, "not found\n", "decoded message")
    }
    case None -> assertTrue(false, "grpc-status present")
  }
  match statusFromFields(fields(["grpc-status", "0"])) {
    case Some(st) -> {
      assertEqualInt(codeOf(st), 0, "Ok")
      assertEqual(st.message, "", "no message")
    }
    case None -> assertTrue(false, "OK status")
  }
  match statusFromFields(fields(["grpc-status", "abc"])) {
    case Some(st) -> assertEqualInt(codeOf(st), 13, "a non-integer is Internal")
    case None -> assertTrue(false, "present but invalid")
  }
  match statusFromFields(fields(["grpc-status", "99"])) {
    case Some(st) -> assertEqualInt(codeOf(st), 2, "an out-of-range integer is Unknown")
    case None -> assertTrue(false, "present but out of range")
  }
}
