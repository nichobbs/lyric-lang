//! tests/ws_frame_tests.l — unit tests for the pure-Lyric RFC 6455 frame
//! codec `Ws.Frame` (docs/62-jsonrpc-mcp.md §6).
//!
//! Covers: masking round-trips, all three payload-length encodings
//! (7/16/64-bit), fragmented-message reassembly, oversize rejection,
//! a control frame interleaved mid-fragmentation, invalid-UTF-8 text-frame
//! rejection, and the RFC 6455 §5.7 example frames (byte-for-byte).
@test_module
package Ws.WsFrameTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Testing
import Ws.Frame

// ─── Helpers ───────────────────────────────────────────────────────────────
func assertBytesEqual(actual: in slice[Byte], expected: in slice[Byte], label: in String): Unit {
  assertEqual(encodeHex(actual), encodeHex(expected), label)
}

func bytesOf(values: in List[Int]): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < values.count {
    acc.add(values[i].toByte())
    i = i + 1
  }
  acc.toArray()
}

func ints(
  a: in Int,
  b: in Int,
  c: in Int,
  d: in Int,
  e: in Int,
  f: in Int,
  g: in Int,
  h: in Int,
  i: in Int,
  j: in Int,
  k: in Int,
): List[Int] {
  val acc: List[Int] = newList()
  acc.add(a)
  acc.add(b)
  acc.add(c)
  acc.add(d)
  acc.add(e)
  acc.add(f)
  acc.add(g)
  acc.add(h)
  acc.add(i)
  acc.add(j)
  acc.add(k)
  acc
}

// Mask `payload` with `key` (4 bytes), producing the wire bytes a real
// client would send: `0x81 0x8L <key(4)> <masked payload>` for a single-frame
// text message no longer than 125 bytes. Used to build synthetic
// client-masked test frames.
func maskedTextFrame(payload: in String, key0: in Int, key1: in Int, key2: in Int, key3: in Int): slice[Byte] {
  val raw = encodeUtf8(payload)
  val acc: List[Byte] = newList()
  acc.add((129).toByte())
  acc.add((128 + raw.length).toByte())
  acc.add(key0.toByte())
  acc.add(key1.toByte())
  acc.add(key2.toByte())
  acc.add(key3.toByte())
  val keys = bytesOf(ints(key0, key1, key2, key3, 0, 0, 0, 0, 0, 0, 0))
  var i = 0
  while i < raw.length {
    acc.add(raw[i].toInt().xor(keys[i % 4].toInt()).toByte())
    i = i + 1
  }
  acc.toArray()
}

func expectSingleMessage(events: in List[WsFrameEvent]): WsFrameEvent {
  assertEqualInt(events.count, 1, "exactly one event produced")
  events[0]
}

// ─── Masking round-trip ────────────────────────────────────────────────────
test "decoder unmasks a client text frame correctly" {
  val frame = maskedTextFrame("hi", 1, 2, 3, 4)
  val dec = newFrameDecoder(65536)
  val result = feedFrames(dec, frame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeMessage(isText, payload) -> {
      assertTrue(isText, "text message")
      assertEqual(unwrapUtf8(payload), "hi", "unmasked payload round-trips")
    }
    case _ -> assertTrue(false, "expected FeMessage")
  }
}

func unwrapUtf8(bytes: in slice[Byte]): String {
  match tryDecodeUtf8(bytes) {
    case Some(s) -> s
    case None -> {
      assertTrue(false, "payload was not valid UTF-8")
      ""
    }
  }
}

test "decoder rejects an unmasked client frame" {
  // 0x81 0x02 'h' 'i' — mask bit clear.
  val frame = bytesOf(ints(129, 2, 104, 105, 0, 0, 0, 0, 0, 0, 0)).slice(0, 4)
  val dec = newFrameDecoder(65536)
  val result = feedFrames(dec, frame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeProtocolError(_) -> assertTrue(isFrameDecoderFailed(result.state), "decoder marks itself failed")
    case _ -> assertTrue(false, "expected FeProtocolError for an unmasked frame")
  }
}

// ─── Payload-length encodings ──────────────────────────────────────────────
test "7-bit inline length round-trips through encode/decode" {
  val payload = encodeUtf8("short")
  val encoded = encodeText(payload)
  assertEqualInt(encoded[1].toInt(), payload.length, "7-bit length byte matches payload length")
  assertTrue(payload.length <= 125, "sanity: within 7-bit inline range")
}

test "16-bit extended length (126) encodes a 200-byte payload" {
  val payload = zeroBytes(200)
  val encoded = encodeBinary(payload)
  assertEqualInt(encoded[1].toInt(), 126, "length field selector is 126")
  val hi = encoded[2].toInt()
  val lo = encoded[3].toInt()
  assertEqualInt(hi * 256 + lo, 200, "16-bit big-endian length is 200")
  assertEqualInt(encoded.length, 4 + 200, "total frame length is header + payload")
}

test "256-byte binary message matches the RFC 6455 5.7 16-bit-length header shape" {
  val payload = zeroBytes(256)
  val encoded = encodeBinary(payload)
  // RFC 6455 5.7: 0x82 0x7E 0x01 0x00 <256 bytes>
  assertBytesEqual(
    encoded.slice(0, 4),
    bytesOf(ints(130, 126, 1, 0, 0, 0, 0, 0, 0, 0, 0)).slice(0, 4),
    "256-byte binary frame header"
  )
}

test "64-bit extended length (127) encodes a 65536-byte payload" {
  val payload = zeroBytes(65536)
  val encoded = encodeBinary(payload)
  // RFC 6455 5.7: 0x82 0x7F 0x00 0x00 0x00 0x00 0x00 0x01 0x00 0x00 <65536 bytes>
  assertBytesEqual(
    encoded.slice(0, 10),
    bytesOf(ints(130, 127, 0, 0, 0, 0, 0, 1, 0, 0, 0)).slice(0, 10),
    "65536-byte binary frame 10-byte extended-length header"
  )
  assertEqualInt(encoded.length, 10 + 65536, "total frame length is header + payload")
}

test "64-bit extended length round-trips through the decoder" {
  val payload = zeroBytes(70000)
  val serverFrame = encodeBinary(payload)
  // Re-mask the server-encoded frame's payload as if a client sent it, to
  // exercise the decoder's 64-bit length path end to end.
  val clientFrame = remaskAsClient(serverFrame)
  val dec = newFrameDecoder(200000)
  val result = feedFrames(dec, clientFrame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeMessage(isText, decodedPayload) -> {
      assertFalse(isText, "binary message")
      assertEqualInt(decodedPayload.length, 70000, "70000-byte payload round-trips through the 64-bit length path")
    }
    case _ -> assertTrue(false, "expected FeMessage")
  }
}

func zeroBytes(n: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < n {
    acc.add((i % 256).toByte())
    i = i + 1
  }
  acc.toArray()
}

// Take an unmasked server-encoded frame (fin+opcode+length+payload, no mask
// key) and re-encode it as a masked client frame with a fixed key, keeping
// the same fin/opcode/length-encoding bytes and masking only the payload.
func remaskAsClient(serverFrame: in slice[Byte]): slice[Byte] {
  val b1 = serverFrame[1].toInt()
  val lenField = b1
  var headerLen = 2
  if lenField == 126 {
    headerLen = 4
  } else if lenField == 127 {
    headerLen = 10
  }
  val header = serverFrame.slice(0, headerLen)
  val payload = serverFrame.slice(headerLen, serverFrame.length)
  val acc: List[Byte] = newList()
  var i = 0
  while i < header.length {
    if i == 1 {
      acc.add((header[i].toInt() + 128).toByte())
    } else {
      acc.add(header[i])
    }
    i = i + 1
  }
  val key = bytesOf(ints(9, 8, 7, 6, 0, 0, 0, 0, 0, 0, 0))
  acc.add(key[0])
  acc.add(key[1])
  acc.add(key[2])
  acc.add(key[3])
  var j = 0
  while j < payload.length {
    acc.add(payload[j].toInt().xor(key[j % 4].toInt()).toByte())
    j = j + 1
  }
  acc.toArray()
}

// ─── Fragmentation reassembly ──────────────────────────────────────────────
test "fragmented text message reassembles across two continuation frames" {
  // First fragment: text, fin=0, "Hel"
  val f1 = maskFrame(1, false, "Hel")
  val f2 = maskFrame(0, true, "lo")
  val dec = newFrameDecoder(65536)
  val r1 = feedFrames(dec, f1)
  assertEqualInt(r1.events.count, 0, "no message yet after the first fragment")
  val r2 = feedFrames(r1.state, f2)
  val ev = expectSingleMessage(r2.events)
  match ev {
    case FeMessage(isText, payload) -> {
      assertTrue(isText, "reassembled text message")
      assertEqual(unwrapUtf8(payload), "Hello", "fragments reassembled in order")
    }
    case _ -> assertTrue(false, "expected FeMessage")
  }
}

test "fragmented message split across separate feedFrames calls with a control frame interleaved" {
  val f1 = maskFrame(1, false, "AB")
  val ping = maskControlFrame(9, "")
  val f2 = maskFrame(0, true, "CD")
  val dec = newFrameDecoder(65536)
  val r1 = feedFrames(dec, f1)
  assertEqualInt(r1.events.count, 0, "no message yet")
  val r2 = feedFrames(r1.state, ping)
  val pingEv = expectSingleMessage(r2.events)
  match pingEv {
    case FePing(_) -> ()
    case _ -> assertTrue(false, "expected FePing interleaved mid-fragmentation")
  }
  val r3 = feedFrames(r2.state, f2)
  val msgEv = expectSingleMessage(r3.events)
  match msgEv {
    case FeMessage(isText, payload) -> {
      assertTrue(isText, "text message")
      assertEqual(unwrapUtf8(payload), "ABCD", "fragments reassembled around the interleaved control frame")
    }
    case _ -> assertTrue(false, "expected FeMessage")
  }
}

test "a data frame arriving mid-fragmentation is a protocol error" {
  val f1 = maskFrame(1, false, "AB")
  val badFrame = maskFrame(2, true, "oops")
  val dec = newFrameDecoder(65536)
  val r1 = feedFrames(dec, f1)
  assertEqualInt(r1.events.count, 0, "no message yet")
  val r2 = feedFrames(r1.state, badFrame)
  val ev = expectSingleMessage(r2.events)
  match ev {
    case FeProtocolError(_) -> assertTrue(isFrameDecoderFailed(r2.state), "decoder fails on interleaved data frame")
    case _ -> assertTrue(false, "expected FeProtocolError")
  }
}

// Mask a single data/continuation frame with opcode `opcode`, fin `fin`, and
// UTF-8 text payload `text`.
func maskFrame(opcode: in Int, fin: in Bool, text: in String): slice[Byte] {
  val payload = encodeUtf8(text)
  val acc: List[Byte] = newList()
  val b0 = (if fin { 128 } else { 0 }) + opcode
  acc.add(b0.toByte())
  acc.add((128 + payload.length).toByte())
  val key = bytesOf(ints(5, 6, 7, 8, 0, 0, 0, 0, 0, 0, 0))
  acc.add(key[0])
  acc.add(key[1])
  acc.add(key[2])
  acc.add(key[3])
  var i = 0
  while i < payload.length {
    acc.add(payload[i].toInt().xor(key[i % 4].toInt()).toByte())
    i = i + 1
  }
  acc.toArray()
}

func maskControlFrame(opcode: in Int, text: in String): slice[Byte] {
  maskFrame(opcode, true, text)
}

// ─── Oversize rejection ────────────────────────────────────────────────────
test "a single frame exceeding maxMessageSizeBytes is rejected" {
  val payload = zeroBytes(2000)
  val serverFrame = encodeBinary(payload)
  val clientFrame = remaskAsClient(serverFrame)
  val dec = newFrameDecoder(1024)
  val result = feedFrames(dec, clientFrame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeProtocolError(_) -> assertTrue(isFrameDecoderFailed(result.state), "decoder fails on oversize single frame")
    case _ -> assertTrue(false, "expected FeProtocolError for an oversize frame")
  }
}

test "a reassembled fragmented message exceeding maxMessageSizeBytes is rejected" {
  val f1 = maskFrame(2, false, "01234567890123456789")
  val f2 = maskFrame(0, true, "01234567890123456789")
  val dec = newFrameDecoder(30)
  val r1 = feedFrames(dec, f1)
  assertEqualInt(r1.events.count, 0, "no message yet after fragment 1 (20 bytes, under the 30-byte cap)")
  val r2 = feedFrames(r1.state, f2)
  val ev = expectSingleMessage(r2.events)
  match ev {
    case FeProtocolError(_) -> assertTrue(isFrameDecoderFailed(r2.state), "decoder fails once reassembly exceeds the cap")
    case _ -> assertTrue(false, "expected FeProtocolError for oversize reassembly")
  }
}

// ─── Invalid UTF-8 ──────────────────────────────────────────────────────────
test "a text frame with invalid UTF-8 payload is rejected" {
  // 0xC0 0x80 is an overlong encoding of NUL — always invalid.
  val badPayload = bytesOf(ints(192, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0)).slice(0, 2)
  val acc: List[Byte] = newList()
  acc.add((129).toByte())
  acc.add((128 + 2).toByte())
  val key = bytesOf(ints(1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0))
  acc.add(key[0])
  acc.add(key[1])
  acc.add(key[2])
  acc.add(key[3])
  var i = 0
  while i < badPayload.length {
    acc.add(badPayload[i].toInt().xor(key[i % 4].toInt()).toByte())
    i = i + 1
  }
  val frame = acc.toArray()
  val dec = newFrameDecoder(65536)
  val result = feedFrames(dec, frame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeProtocolError(_) -> assertTrue(isFrameDecoderFailed(result.state), "decoder fails on invalid UTF-8 text frame")
    case _ -> assertTrue(false, "expected FeProtocolError for invalid UTF-8")
  }
}

test "a reassembled fragmented text message with invalid UTF-8 is rejected" {
  // Split a valid 2-byte UTF-8 sequence (U+00E9, 0xC3 0xA9) across a
  // fragment boundary — legal per RFC 6455 8.1 — then corrupt the second
  // byte so the reassembled message is invalid.
  val f1 = maskRawFrame(1, false, bytesOf(ints(195, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)).slice(0, 1))
  val f2 = maskRawFrame(0, true, bytesOf(ints(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)).slice(0, 1))
  val dec = newFrameDecoder(65536)
  val r1 = feedFrames(dec, f1)
  assertEqualInt(r1.events.count, 0, "no message yet")
  val r2 = feedFrames(r1.state, f2)
  val ev = expectSingleMessage(r2.events)
  match ev {
    case FeProtocolError(_) -> assertTrue(isFrameDecoderFailed(r2.state), "decoder fails on invalid reassembled UTF-8")
    case _ -> assertTrue(false, "expected FeProtocolError")
  }
}

func maskRawFrame(opcode: in Int, fin: in Bool, payload: in slice[Byte]): slice[Byte] {
  val acc: List[Byte] = newList()
  val b0 = (if fin { 128 } else { 0 }) + opcode
  acc.add(b0.toByte())
  acc.add((128 + payload.length).toByte())
  val key = bytesOf(ints(3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0))
  acc.add(key[0])
  acc.add(key[1])
  acc.add(key[2])
  acc.add(key[3])
  var i = 0
  while i < payload.length {
    acc.add(payload[i].toInt().xor(key[i % 4].toInt()).toByte())
    i = i + 1
  }
  acc.toArray()
}

// ─── RFC 6455 §5.7 example frames ──────────────────────────────────────────
test "RFC 6455 5.7: unmasked single-frame text message 'Hello'" {
  val encoded = encodeText(encodeUtf8("Hello"))
  assertBytesEqual(
    encoded,
    bytesOf(ints(129, 5, 72, 101, 108, 108, 111, 0, 0, 0, 0)).slice(0, 7),
    "unmasked 'Hello' text frame"
  )
}

test "RFC 6455 5.7: masked single-frame text message 'Hello' decodes correctly" {
  val frame = bytesOf(ints(129, 133, 55, 250, 33, 61, 127, 159, 77, 81, 88))
  val dec = newFrameDecoder(65536)
  val result = feedFrames(dec, frame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeMessage(isText, payload) -> {
      assertTrue(isText, "text message")
      assertEqual(unwrapUtf8(payload), "Hello", "RFC 6455 5.7 masked example decodes to 'Hello'")
    }
    case _ -> assertTrue(false, "expected FeMessage")
  }
}

test "RFC 6455 5.7: unmasked Ping request with body 'Hello'" {
  val encoded = encodePing(encodeUtf8("Hello"))
  assertBytesEqual(
    encoded,
    bytesOf(ints(137, 5, 72, 101, 108, 108, 111, 0, 0, 0, 0)).slice(0, 7),
    "unmasked Ping('Hello') frame"
  )
}

test "RFC 6455 5.7: unmasked Pong response with body 'Hello'" {
  val encoded = encodePong(encodeUtf8("Hello"))
  assertBytesEqual(
    encoded,
    bytesOf(ints(138, 5, 72, 101, 108, 108, 111, 0, 0, 0, 0)).slice(0, 7),
    "unmasked Pong('Hello') frame"
  )
}

// ─── Close frame ────────────────────────────────────────────────────────────
test "close frame payload round-trips code and reason" {
  val payload = encodeClosePayload(1000, "bye")
  val frame = maskCloseFrame(payload)
  val dec = newFrameDecoder(65536)
  val result = feedFrames(dec, frame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeClose(code, reason) -> {
      assertEqualInt(code, 1000, "close code round-trips")
      assertEqual(reason, "bye", "close reason round-trips")
    }
    case _ -> assertTrue(false, "expected FeClose")
  }
}

test "close frame with a reserved status code is rejected" {
  val payload = encodeClosePayload(1005, "")
  // encodeClosePayload doesn't itself validate — a real peer could still
  // send the reserved 1005 on the wire, which the decoder must reject.
  val frame = maskCloseFrame(payload)
  val dec = newFrameDecoder(65536)
  val result = feedFrames(dec, frame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeProtocolError(_) -> assertTrue(isFrameDecoderFailed(result.state), "decoder fails on reserved close code 1005")
    case _ -> assertTrue(false, "expected FeProtocolError for reserved close code")
  }
}

test "empty close frame reports code 1005 (No Status Rcvd)" {
  val emptyPayload: slice[Byte] = []
  val frame = maskCloseFrame(emptyPayload)
  val dec = newFrameDecoder(65536)
  val result = feedFrames(dec, frame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeClose(code, reason) -> {
      assertEqualInt(code, 1005, "empty close frame reports 1005 locally")
      assertEqual(reason, "", "empty close reason")
    }
    case _ -> assertTrue(false, "expected FeClose")
  }
}

func maskCloseFrame(payload: in slice[Byte]): slice[Byte] {
  val acc: List[Byte] = newList()
  acc.add((136).toByte())
  acc.add((128 + payload.length).toByte())
  val key = bytesOf(ints(2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0))
  acc.add(key[0])
  acc.add(key[1])
  acc.add(key[2])
  acc.add(key[3])
  var i = 0
  while i < payload.length {
    acc.add(payload[i].toInt().xor(key[i % 4].toInt()).toByte())
    i = i + 1
  }
  acc.toArray()
}

// ─── Reserved bits / bad opcode ─────────────────────────────────────────────
test "a frame with a nonzero RSV bit is rejected" {
  // 0x81 with RSV1 set would be 0xC1.
  val frame = bytesOf(ints(193, 130, 1, 1, 1, 1, 104, 105, 0, 0, 0)).slice(0, 8)
  val dec = newFrameDecoder(65536)
  val result = feedFrames(dec, frame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeProtocolError(_) -> assertTrue(isFrameDecoderFailed(result.state), "decoder fails on RSV bit set")
    case _ -> assertTrue(false, "expected FeProtocolError for RSV bit set")
  }
}

test "a frame with a reserved opcode is rejected" {
  // 0x83 = FIN + opcode 3 (reserved, non-control).
  val frame = bytesOf(ints(131, 130, 1, 1, 1, 1, 104, 105, 0, 0, 0)).slice(0, 8)
  val dec = newFrameDecoder(65536)
  val result = feedFrames(dec, frame)
  val ev = expectSingleMessage(result.events)
  match ev {
    case FeProtocolError(_) -> assertTrue(isFrameDecoderFailed(result.state), "decoder fails on reserved opcode")
    case _ -> assertTrue(false, "expected FeProtocolError for reserved opcode")
  }
}

// ─── Partial-frame buffering ────────────────────────────────────────────────
test "feedFrames buffers a partial header across two calls" {
  val frame = maskedTextFrame("hi", 1, 2, 3, 4)
  val part1 = frame.slice(0, 3)
  val part2 = frame.slice(3, frame.length)
  val dec = newFrameDecoder(65536)
  val r1 = feedFrames(dec, part1)
  assertEqualInt(r1.events.count, 0, "no event yet from a partial header")
  val r2 = feedFrames(r1.state, part2)
  val ev = expectSingleMessage(r2.events)
  match ev {
    case FeMessage(isText, payload) -> {
      assertTrue(isText, "text message")
      assertEqual(unwrapUtf8(payload), "hi", "message completes once the rest of the header/payload arrives")
    }
    case _ -> assertTrue(false, "expected FeMessage")
  }
}
