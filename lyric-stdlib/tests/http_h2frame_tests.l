//! stdlib/tests/http_h2frame_tests.l — byte-level corpus for
//! `Std.HttpEngine.H2Frame` (docs/61-https-tls-http-versions.md §6.4, D128;
//! phase 4.2 of epic #5874, issue #5887).
//!
//! This corpus is the HTTP/2 frame codec's wire-format spec, exercised with
//! explicit RFC 9113 byte vectors: a serialize↔parse round-trip for every §6
//! frame type, known-good vectors (a SETTINGS parameter, a PING with its
//! 8-octet opaque data, a GOAWAY with last-stream-id + error code), flag and
//! padding permutations, malformed-frame rejection asserting the exact
//! `FrameError` (oversized vs SETTINGS_MAX_FRAME_SIZE, bad pad length, wrong
//! fixed-frame length, forbidden stream ids, reserved-bit masking), unknown-
//! type pass-through, connection-preface detection/emission, and two
//! boundary-split torture tests (every 2-way split, and byte-at-a-time) that
//! prove the streaming decoder is agnostic to how the transport chops the
//! wire bytes across `feedFrames` calls.
//!
//! Runs via native `lyric test` on both targets (`--target dotnet` and
//! `--target jvm`): the codec is pure Lyric with zero externs, so both must
//! produce identical results (a divergence would be a compiler bug, not an
//! `H2Frame` bug — see `http_engine_tests.l`'s precedent).
@test_module
package Std.HttpEngine.H2Frame.Tests

import Std.Core
import Std.Collections
import Std.HttpEngine.H2Frame
import Std.Testing

// ---------------------------------------------------------------------------
// Byte-vector infrastructure.
// ---------------------------------------------------------------------------
/// Build a `slice[Byte]` from a `List[Byte]` accumulator built in the caller.
func toBytes(acc: in List[Byte]): slice[Byte] {
  acc.toArray()
}

func pushI(acc: in List[Byte], v: in Int): Unit {
  acc.add(v.and(255).toByte())
}

func pushSlice(acc: in List[Byte], s: in slice[Byte]): Unit {
  var i = 0
  while i < s.length {
    acc.add(s[i])
    i = i + 1
  }
}

/// Assemble raw frame bytes (9-octet header + payload) directly, bypassing the
/// codec's serializer — used to feed hand-built (including malformed) vectors
/// into the parser.
func rawFrame(frameType: in Int, flags: in Int, streamId: in Int, payload: in slice[Byte]): slice[Byte] {
  val acc: List[Byte] = newList()
  val len = payload.length
  pushI(acc, len.shr(16))
  pushI(acc, len.shr(8))
  pushI(acc, len)
  pushI(acc, frameType)
  pushI(acc, flags)
  pushI(acc, streamId.shr(24))
  pushI(acc, streamId.shr(16))
  pushI(acc, streamId.shr(8))
  pushI(acc, streamId)
  pushSlice(acc, payload)
  toBytes(acc)
}

func bytesEqual(a: in slice[Byte], b: in slice[Byte]): Bool {
  if a.length != b.length {
    return false
  }
  var i = 0
  while i < a.length {
    if a[i].toInt() != b[i].toInt() {
      return false
    }
    i = i + 1
  }
  true
}

func hexOf(bytes: in slice[Byte]): String {
  val digits = "0123456789abcdef"
  var acc = ""
  var i = 0
  while i < bytes.length {
    val v = bytes[i].toInt()
    acc = acc + ("" + digits[v / 16]) + ("" + digits[v % 16])
    i = i + 1
  }
  acc
}

func assertBytesEqual(actual: in slice[Byte], expected: in slice[Byte], label: in String): Unit {
  assertTrue(bytesEqual(actual, expected), label + ": expected " + hexOf(expected) + " got " + hexOf(actual))
}

// ---------------------------------------------------------------------------
// Frame-error inspection.
// ---------------------------------------------------------------------------
func assertParseErr(
  header: in H2FrameHeader,
  payload: in slice[Byte],
  expectedCode: in H2ErrorCode,
  expectedConn: in Bool,
  label: in String,
): Unit {
  match parseFrame(header, payload) {
    case Ok(_) -> panic(label + ": expected a FrameError, parsed successfully")
    case Err(e) -> {
      assertEqualLong(errorCodeToLong(e.code), errorCodeToLong(expectedCode), label + ": error code")
      assertTrue(e.connectionError == expectedConn, label + ": connection-error flag (" + e.message + ")")
    }
  }
}

func hdr(frameType: in Int, flags: in Int, streamId: in Int, length: in Int): H2FrameHeader {
  H2FrameHeader(length = length, frameType = frameType, flags = flags, streamId = streamId)
}

// ---------------------------------------------------------------------------
// Streaming-decoder helpers (mirror http_engine_tests.l's feed helpers).
// ---------------------------------------------------------------------------
func appendAll(acc: in List[FrameDecodeEvent], events: in List[FrameDecodeEvent]): Unit {
  var i = 0
  while i < events.count {
    acc.add(events[i])
    i = i + 1
  }
}

func dropNeedMore(events: in List[FrameDecodeEvent]): List[FrameDecodeEvent] {
  val acc: List[FrameDecodeEvent] = newList()
  var i = 0
  while i < events.count {
    match events[i] {
      case FrameNeedMore -> ()
      case _ -> acc.add(events[i])
    }
    i = i + 1
  }
  acc
}

func decodeWhole(expectPreface: in Bool, full: in slice[Byte]): List[FrameDecodeEvent] {
  val decoder = newFrameDecoder(expectPreface)
  val result = feedFrames(decoder, full)
  result.events
}

func decodeSplitAt(expectPreface: in Bool, full: in slice[Byte], splitAt: in Int): List[FrameDecodeEvent] {
  var decoder = newFrameDecoder(expectPreface)
  val acc: List[FrameDecodeEvent] = newList()
  val r1 = feedFrames(decoder, full.slice(0, splitAt))
  decoder = r1.decoder
  appendAll(acc, r1.events)
  val r2 = feedFrames(decoder, full.slice(splitAt, full.length))
  decoder = r2.decoder
  appendAll(acc, r2.events)
  acc
}

func decodeByteByByte(expectPreface: in Bool, full: in slice[Byte]): List[FrameDecodeEvent] {
  var decoder = newFrameDecoder(expectPreface)
  val acc: List[FrameDecodeEvent] = newList()
  var i = 0
  while i < full.length {
    val result = feedFrames(decoder, full.slice(i, i + 1))
    decoder = result.decoder
    appendAll(acc, result.events)
    i = i + 1
  }
  acc
}

/// Assert `events` holds exactly one `FrameDecoded` and return its frame.
func singleDecoded(events: in List[FrameDecodeEvent], label: in String): H2Frame {
  val substantive = dropNeedMore(events)
  assertEqualInt(substantive.count, 1, label + ": exactly one decode event")
  match substantive[0] {
    case FrameDecoded(frame) -> frame
    case _ -> panic(label + ": expected FrameDecoded")
  }
}

// ---------------------------------------------------------------------------
// Frame header round-trip (RFC 9113 §4.1).
// ---------------------------------------------------------------------------
test "9-octet frame header parses length/type/flags/streamId" {
  // length=0x010203, type=4, flags=0x08, streamId=0x090A0B0C.
  val bytes: slice[Byte] = [1u8, 2u8, 3u8, 4u8, 8u8, 9u8, 10u8, 11u8, 12u8]
  match parseFrameHeader(bytes) {
    case None -> panic("expected a header")
    case Some(h) -> {
      assertEqualInt(h.length, 66051, "length 0x010203")
      assertEqualInt(h.frameType, 4, "type")
      assertEqualInt(h.flags, 8, "flags")
      assertEqualInt(h.streamId, 151653132, "streamId 0x090A0B0C")
    }
  }
}

test "parseFrameHeader returns None for fewer than 9 octets" {
  val bytes: slice[Byte] = [0u8, 0u8, 0u8, 0u8]
  match parseFrameHeader(bytes) {
    case None -> assertTrue(true, "short header rejected")
    case Some(_) -> panic("expected None for a short header")
  }
}

test "the reserved high bit of the stream id is masked off on parse (RFC 9113 4.1)" {
  // streamId field 0xFFFFFFFF: the reserved R bit must be ignored, leaving
  // 0x7FFFFFFF.
  val bytes: slice[Byte] = [0u8, 0u8, 0u8, 6u8, 0u8, 255u8, 255u8, 255u8, 255u8]
  match parseFrameHeader(bytes) {
    case None -> panic("expected a header")
    case Some(h) -> assertEqualInt(h.streamId, 2147483647, "R bit masked -> 0x7FFFFFFF")
  }
}

test "serializeFrameHeader writes the reserved stream-id bit as 0" {
  val h = hdr(0, 0, 2147483647, 0)
  val wire = serializeFrameHeader(h)
  val expected: slice[Byte] = [0u8, 0u8, 0u8, 0u8, 0u8, 127u8, 255u8, 255u8, 255u8]
  assertBytesEqual(wire, expected, "header with max stream id")
}

// ---------------------------------------------------------------------------
// SETTINGS (RFC 9113 §6.5) — known-good vector + round-trip + rejections.
// ---------------------------------------------------------------------------
test "SETTINGS frame with one parameter parses to a known value" {
  // MAX_CONCURRENT_STREAMS (id 3) = 100; on a connection (stream 0).
  val payload: slice[Byte] = [0u8, 3u8, 0u8, 0u8, 0u8, 100u8]
  val frame = singleDecoded(decodeWhole(false, rawFrame(4, 0, 0, payload)), "settings")
  match frame {
    case SettingsFrame(settings, ack) -> {
      assertFalse(ack, "not an ACK")
      assertEqualInt(settings.count, 1, "one parameter")
      val p0: SettingsParam = settings[0]
      assertEqualInt(settingsIdToInt(p0.id), 3, "id = MAX_CONCURRENT_STREAMS")
      assertEqualLong(p0.value, 100i64, "value = 100")
    }
    case _ -> panic("expected SettingsFrame")
  }
}

test "SETTINGS with a large 32-bit value stays exact (Long, not Int)" {
  // HEADER_TABLE_SIZE (id 1) = 0xFFFFFFFF = 4294967295, beyond Int range.
  val payload: slice[Byte] = [0u8, 1u8, 255u8, 255u8, 255u8, 255u8]
  val frame = singleDecoded(decodeWhole(false, rawFrame(4, 0, 0, payload)), "settings-large")
  match frame {
    case SettingsFrame(settings, _) -> {
      val p0: SettingsParam = settings[0]
      assertEqualLong(p0.value, 4294967295i64, "0xFFFFFFFF preserved")
    }
    case _ -> panic("expected SettingsFrame")
  }
}

test "SETTINGS round-trips through serialize and parse" {
  val params: List[SettingsParam] = newList()
  params.add(SettingsParam(id = SettingsInitialWindowSize, value = 65535i64))
  params.add(SettingsParam(id = SettingsMaxFrameSize, value = 16384i64))
  params.add(SettingsParam(id = SettingsUnknown(id = 4096), value = 1i64))
  val wire = serializeFrame(SettingsFrame(settings = params, ack = false))
  val frame = singleDecoded(decodeWhole(false, wire), "settings-roundtrip")
  match frame {
    case SettingsFrame(settings, ack) -> {
      assertFalse(ack, "not ACK")
      assertEqualInt(settings.count, 3, "three params")
      val p0: SettingsParam = settings[0]
      val p1: SettingsParam = settings[1]
      val p2: SettingsParam = settings[2]
      assertEqualInt(settingsIdToInt(p0.id), 4, "param 0 id")
      assertEqualLong(p1.value, 16384i64, "param 1 value")
      assertEqualInt(settingsIdToInt(p2.id), 4096, "unknown id preserved")
    }
    case _ -> panic("expected SettingsFrame")
  }
}

test "SETTINGS ACK carries an empty payload and round-trips" {
  val empty: List[SettingsParam] = newList()
  val wire = serializeFrame(SettingsFrame(settings = empty, ack = true))
  // length must be 0, flags ACK (0x1).
  val expected: slice[Byte] = [0u8, 0u8, 0u8, 4u8, 1u8, 0u8, 0u8, 0u8, 0u8]
  assertBytesEqual(wire, expected, "SETTINGS ACK wire form")
  val frame = singleDecoded(decodeWhole(false, wire), "settings-ack")
  match frame {
    case SettingsFrame(settings, ack) -> {
      assertTrue(ack, "is ACK")
      assertEqualInt(settings.count, 0, "no params")
    }
    case _ -> panic("expected SettingsFrame")
  }
}

test "SETTINGS ACK with a non-empty payload is FRAME_SIZE_ERROR" {
  val payload: slice[Byte] = [0u8, 3u8, 0u8, 0u8, 0u8, 100u8]
  assertParseErr(hdr(4, 1, 0, 6), payload, H2FrameSizeError, true, "settings ack non-empty")
}

test "SETTINGS payload not a multiple of 6 is FRAME_SIZE_ERROR" {
  val payload: slice[Byte] = [0u8, 3u8, 0u8, 0u8, 0u8]
  assertParseErr(hdr(4, 0, 0, 5), payload, H2FrameSizeError, true, "settings length % 6")
}

test "SETTINGS on a non-zero stream is PROTOCOL_ERROR" {
  val payload: slice[Byte] = [0u8, 3u8, 0u8, 0u8, 0u8, 100u8]
  assertParseErr(hdr(4, 0, 1, 6), payload, H2ProtocolError, true, "settings non-zero stream")
}

// ---------------------------------------------------------------------------
// PING (RFC 9113 §6.7).
// ---------------------------------------------------------------------------
test "PING carries 8 octets of opaque data and round-trips" {
  val opq: slice[Byte] = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8]
  val wire = serializeFrame(PingFrame(opaqueData = opq, ack = false))
  val expected: slice[Byte] = [0u8, 0u8, 8u8, 6u8, 0u8, 0u8, 0u8, 0u8, 0u8, 1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8]
  assertBytesEqual(wire, expected, "PING wire form")
  val frame = singleDecoded(decodeWhole(false, wire), "ping")
  match frame {
    case PingFrame(data, ack) -> {
      assertFalse(ack, "not ACK")
      assertBytesEqual(data, opq, "opaque data preserved")
    }
    case _ -> panic("expected PingFrame")
  }
}

test "PING ACK sets the ACK flag" {
  val opq: slice[Byte] = [8u8, 7u8, 6u8, 5u8, 4u8, 3u8, 2u8, 1u8]
  val frame = singleDecoded(decodeWhole(false, serializeFrame(PingFrame(opaqueData = opq, ack = true))), "ping-ack")
  match frame {
    case PingFrame(_, ack) -> assertTrue(ack, "ACK set")
    case _ -> panic("expected PingFrame")
  }
}

test "PING with a payload other than 8 octets is FRAME_SIZE_ERROR" {
  val payload: slice[Byte] = [1u8, 2u8, 3u8, 4u8]
  assertParseErr(hdr(6, 0, 0, 4), payload, H2FrameSizeError, true, "ping wrong length")
}

test "PING on a non-zero stream is PROTOCOL_ERROR" {
  val payload: slice[Byte] = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8]
  assertParseErr(hdr(6, 0, 1, 8), payload, H2ProtocolError, true, "ping non-zero stream")
}

// ---------------------------------------------------------------------------
// GOAWAY (RFC 9113 §6.8).
// ---------------------------------------------------------------------------
test "GOAWAY parses last-stream-id, error code, and debug data" {
  // lastStreamId=0x0000000F, errorCode=ENHANCE_YOUR_CALM (0x0B), debug="x".
  val payload: slice[Byte] = [0u8, 0u8, 0u8, 15u8, 0u8, 0u8, 0u8, 11u8, 120u8]
  val frame = singleDecoded(decodeWhole(false, rawFrame(7, 0, 0, payload)), "goaway")
  match frame {
    case GoAwayFrame(lastStreamId, errorCode, debugData) -> {
      val dbg: slice[Byte] = debugData
      assertEqualInt(lastStreamId, 15, "last stream id")
      assertEqualLong(errorCodeToLong(errorCode), 11i64, "error code ENHANCE_YOUR_CALM")
      assertEqualInt(dbg.length, 1, "one debug octet")
      val d0: Byte = dbg[0]
      assertEqualInt(d0.toInt(), 120, "debug byte 'x'")
    }
    case _ -> panic("expected GoAwayFrame")
  }
}

test "GOAWAY round-trips with empty debug data" {
  val empty: slice[Byte] = []
  val wire = serializeFrame(GoAwayFrame(lastStreamId = 42, errorCode = H2NoError, debugData = empty))
  val frame = singleDecoded(decodeWhole(false, wire), "goaway-roundtrip")
  match frame {
    case GoAwayFrame(lastStreamId, errorCode, debugData) -> {
      val dbg: slice[Byte] = debugData
      assertEqualInt(lastStreamId, 42, "last stream id")
      assertEqualLong(errorCodeToLong(errorCode), 0i64, "NO_ERROR")
      assertEqualInt(dbg.length, 0, "no debug data")
    }
    case _ -> panic("expected GoAwayFrame")
  }
}

test "GOAWAY shorter than 8 octets is FRAME_SIZE_ERROR" {
  val payload: slice[Byte] = [0u8, 0u8, 0u8, 15u8, 0u8, 0u8, 0u8]
  assertParseErr(hdr(7, 0, 0, 7), payload, H2FrameSizeError, true, "goaway too short")
}

test "GOAWAY on a non-zero stream is PROTOCOL_ERROR" {
  val payload: slice[Byte] = [0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8]
  assertParseErr(hdr(7, 0, 3, 8), payload, H2ProtocolError, true, "goaway non-zero stream")
}

// ---------------------------------------------------------------------------
// WINDOW_UPDATE (RFC 9113 §6.9).
// ---------------------------------------------------------------------------
test "WINDOW_UPDATE parses the 31-bit increment and round-trips" {
  val wire = serializeFrame(WindowUpdateFrame(streamId = 1, windowSizeIncrement = 65535))
  val expected: slice[Byte] = [0u8, 0u8, 4u8, 8u8, 0u8, 0u8, 0u8, 0u8, 1u8, 0u8, 0u8, 255u8, 255u8]
  assertBytesEqual(wire, expected, "WINDOW_UPDATE wire form")
  val frame = singleDecoded(decodeWhole(false, wire), "window-update")
  match frame {
    case WindowUpdateFrame(streamId, increment) -> {
      assertEqualInt(streamId, 1, "stream id")
      assertEqualInt(increment, 65535, "increment")
    }
    case _ -> panic("expected WindowUpdateFrame")
  }
}

test "WINDOW_UPDATE with a length other than 4 is FRAME_SIZE_ERROR" {
  val payload: slice[Byte] = [0u8, 0u8, 1u8]
  assertParseErr(hdr(8, 0, 1, 3), payload, H2FrameSizeError, true, "window-update wrong length")
}

test "WINDOW_UPDATE with a 0 increment on a stream is a stream PROTOCOL_ERROR" {
  val payload: slice[Byte] = [0u8, 0u8, 0u8, 0u8]
  assertParseErr(hdr(8, 0, 1, 4), payload, H2ProtocolError, false, "window-update 0 on stream")
}

test "WINDOW_UPDATE with a 0 increment on the connection is a connection PROTOCOL_ERROR" {
  val payload: slice[Byte] = [0u8, 0u8, 0u8, 0u8]
  assertParseErr(hdr(8, 0, 0, 4), payload, H2ProtocolError, true, "window-update 0 on connection")
}

// ---------------------------------------------------------------------------
// RST_STREAM (RFC 9113 §6.4).
// ---------------------------------------------------------------------------
test "RST_STREAM parses its error code and round-trips" {
  val wire = serializeFrame(RstStreamFrame(streamId = 5, errorCode = H2Cancel))
  val expected: slice[Byte] = [0u8, 0u8, 4u8, 3u8, 0u8, 0u8, 0u8, 0u8, 5u8, 0u8, 0u8, 0u8, 8u8]
  assertBytesEqual(wire, expected, "RST_STREAM wire form")
  val frame = singleDecoded(decodeWhole(false, wire), "rst-stream")
  match frame {
    case RstStreamFrame(streamId, errorCode) -> {
      assertEqualInt(streamId, 5, "stream id")
      assertEqualLong(errorCodeToLong(errorCode), 8i64, "CANCEL")
    }
    case _ -> panic("expected RstStreamFrame")
  }
}

test "RST_STREAM with a length other than 4 is FRAME_SIZE_ERROR" {
  val payload: slice[Byte] = [0u8, 0u8, 0u8]
  assertParseErr(hdr(3, 0, 5, 3), payload, H2FrameSizeError, true, "rst-stream wrong length")
}

test "RST_STREAM on stream 0 is PROTOCOL_ERROR" {
  val payload: slice[Byte] = [0u8, 0u8, 0u8, 0u8]
  assertParseErr(hdr(3, 0, 0, 4), payload, H2ProtocolError, true, "rst-stream stream 0")
}

// ---------------------------------------------------------------------------
// DATA (RFC 9113 §6.1) — flags and padding.
// ---------------------------------------------------------------------------
test "DATA frame carries payload and the END_STREAM flag, round-trips" {
  val body: slice[Byte] = [104u8, 105u8]
  val wire = serializeFrame(DataFrame(streamId = 1, data = body, endStream = true))
  val expected: slice[Byte] = [0u8, 0u8, 2u8, 0u8, 1u8, 0u8, 0u8, 0u8, 1u8, 104u8, 105u8]
  assertBytesEqual(wire, expected, "DATA wire form")
  val frame = singleDecoded(decodeWhole(false, wire), "data")
  match frame {
    case DataFrame(streamId, data, endStream) -> {
      assertEqualInt(streamId, 1, "stream id")
      assertTrue(endStream, "END_STREAM")
      assertBytesEqual(data, body, "payload")
    }
    case _ -> panic("expected DataFrame")
  }
}

test "a PADDED DATA frame strips the pad length and trailing padding (RFC 9113 6.1)" {
  // PADDED flag (0x8). Payload: padLen=3, data="hi", then 3 pad octets.
  val payload: slice[Byte] = [3u8, 104u8, 105u8, 0u8, 0u8, 0u8]
  val frame = singleDecoded(decodeWhole(false, rawFrame(0, 8, 1, payload)), "data-padded")
  match frame {
    case DataFrame(_, data, _) -> {
      val expected: slice[Byte] = [104u8, 105u8]
      assertBytesEqual(data, expected, "padding stripped, data preserved")
    }
    case _ -> panic("expected DataFrame")
  }
}

test "a PADDED DATA frame with pad length >= payload is PROTOCOL_ERROR (RFC 9113 6.1)" {
  // padLen=5 but only 4 payload octets total (1 pad-length + 3): 1+5 > 4.
  val payload: slice[Byte] = [5u8, 104u8, 105u8, 0u8]
  assertParseErr(hdr(0, 8, 1, 4), payload, H2ProtocolError, true, "bad pad length")
}

test "DATA on stream 0 is PROTOCOL_ERROR" {
  val payload: slice[Byte] = [104u8]
  assertParseErr(hdr(0, 0, 0, 1), payload, H2ProtocolError, true, "data stream 0")
}

// ---------------------------------------------------------------------------
// HEADERS (RFC 9113 §6.2) — flags, priority prefix, padding.
// ---------------------------------------------------------------------------
test "HEADERS frame carries the opaque block fragment and flags, round-trips" {
  val block: slice[Byte] = [130u8, 132u8]
  val none: Option[PriorityInfo] = None
  val wire = serializeFrame(
    HeadersFrame(
      streamId = 1,
      headerBlockFragment = block,
      endStream = true,
      endHeaders = true,
      priority = none
    )
  )
  // length=2, type=1, flags=END_STREAM|END_HEADERS (0x5), stream 1.
  val expected: slice[Byte] = [0u8, 0u8, 2u8, 1u8, 5u8, 0u8, 0u8, 0u8, 1u8, 130u8, 132u8]
  assertBytesEqual(wire, expected, "HEADERS wire form")
  val frame = singleDecoded(decodeWhole(false, wire), "headers")
  match frame {
    case HeadersFrame(streamId, fragment, endStream, endHeaders, priority) -> {
      assertEqualInt(streamId, 1, "stream id")
      assertTrue(endStream, "END_STREAM")
      assertTrue(endHeaders, "END_HEADERS")
      assertBytesEqual(fragment, block, "fragment")
      match priority {
        case None -> assertTrue(true, "no priority")
        case Some(_) -> panic("expected no priority")
      }
    }
    case _ -> panic("expected HeadersFrame")
  }
}

test "HEADERS with the PRIORITY prefix parses (and re-serializes) its priority fields" {
  val block: slice[Byte] = [130u8]
  val prio = PriorityInfo(exclusive = true, streamDependency = 3, weight = 16)
  val wire = serializeFrame(
    HeadersFrame(
      streamId = 5,
      headerBlockFragment = block,
      endStream = false,
      endHeaders = true,
      priority = Some(value = prio)
    )
  )
  val frame = singleDecoded(decodeWhole(false, wire), "headers-priority")
  match frame {
    case HeadersFrame(_, fragment, _, endHeaders, priority) -> {
      assertTrue(endHeaders, "END_HEADERS")
      assertBytesEqual(fragment, block, "fragment after 5-octet priority prefix")
      match priority {
        case None -> panic("expected priority")
        case Some(p) -> {
          val pr: PriorityInfo = p
          assertTrue(pr.exclusive, "exclusive bit")
          assertEqualInt(pr.streamDependency, 3, "stream dependency")
          assertEqualInt(pr.weight, 16, "weight (wire bias undone)")
        }
      }
    }
    case _ -> panic("expected HeadersFrame")
  }
}

test "a PADDED HEADERS frame strips padding around the fragment" {
  // PADDED (0x8): padLen=2, fragment="AB", 2 pad octets.
  val payload: slice[Byte] = [2u8, 65u8, 66u8, 0u8, 0u8]
  val frame = singleDecoded(decodeWhole(false, rawFrame(1, 12, 1, payload)), "headers-padded")
  match frame {
    case HeadersFrame(_, fragment, _, endHeaders, _) -> {
      assertTrue(endHeaders, "END_HEADERS (0x4) also set")
      val expected: slice[Byte] = [65u8, 66u8]
      assertBytesEqual(fragment, expected, "fragment with padding stripped")
    }
    case _ -> panic("expected HeadersFrame")
  }
}

test "HEADERS on stream 0 is PROTOCOL_ERROR" {
  val payload: slice[Byte] = [130u8]
  assertParseErr(hdr(1, 4, 0, 1), payload, H2ProtocolError, true, "headers stream 0")
}

// ---------------------------------------------------------------------------
// PRIORITY (RFC 9113 §6.3) — deprecated but parsed.
// ---------------------------------------------------------------------------
test "PRIORITY frame parses its 5 octets and round-trips" {
  val prio = PriorityInfo(exclusive = false, streamDependency = 1, weight = 256)
  val wire = serializeFrame(PriorityFrame(streamId = 3, priority = prio))
  // length=5, type=2, flags=0, stream 3, dep=1, weight-1=255.
  val expected: slice[Byte] = [0u8, 0u8, 5u8, 2u8, 0u8, 0u8, 0u8, 0u8, 3u8, 0u8, 0u8, 0u8, 1u8, 255u8]
  assertBytesEqual(wire, expected, "PRIORITY wire form")
  val frame = singleDecoded(decodeWhole(false, wire), "priority")
  match frame {
    case PriorityFrame(streamId, p) -> {
      val pr: PriorityInfo = p
      assertEqualInt(streamId, 3, "stream id")
      assertFalse(pr.exclusive, "not exclusive")
      assertEqualInt(pr.streamDependency, 1, "dependency")
      assertEqualInt(pr.weight, 256, "weight 256 (max)")
    }
    case _ -> panic("expected PriorityFrame")
  }
}

test "PRIORITY with a length other than 5 is a stream FRAME_SIZE_ERROR" {
  val payload: slice[Byte] = [0u8, 0u8, 0u8, 1u8]
  assertParseErr(hdr(2, 0, 3, 4), payload, H2FrameSizeError, false, "priority wrong length")
}

// ---------------------------------------------------------------------------
// PUSH_PROMISE (RFC 9113 §6.6).
// ---------------------------------------------------------------------------
test "PUSH_PROMISE parses the promised stream id and fragment, round-trips" {
  val block: slice[Byte] = [130u8, 135u8]
  val wire = serializeFrame(
    PushPromiseFrame(streamId = 1, promisedStreamId = 2, headerBlockFragment = block, endHeaders = true)
  )
  val frame = singleDecoded(decodeWhole(false, wire), "push-promise")
  match frame {
    case PushPromiseFrame(streamId, promisedStreamId, fragment, endHeaders) -> {
      assertEqualInt(streamId, 1, "stream id")
      assertEqualInt(promisedStreamId, 2, "promised stream id")
      assertTrue(endHeaders, "END_HEADERS")
      assertBytesEqual(fragment, block, "fragment")
    }
    case _ -> panic("expected PushPromiseFrame")
  }
}

test "a PADDED PUSH_PROMISE strips padding around the fragment" {
  // PADDED (0x8) | END_HEADERS (0x4) = 0xC. padLen=1, promised=2, frag="Z", 1 pad.
  val payload: slice[Byte] = [1u8, 0u8, 0u8, 0u8, 2u8, 90u8, 0u8]
  val frame = singleDecoded(decodeWhole(false, rawFrame(5, 12, 1, payload)), "push-promise-padded")
  match frame {
    case PushPromiseFrame(_, promisedStreamId, fragment, _) -> {
      assertEqualInt(promisedStreamId, 2, "promised id after pad octet")
      val expected: slice[Byte] = [90u8]
      assertBytesEqual(fragment, expected, "fragment with padding stripped")
    }
    case _ -> panic("expected PushPromiseFrame")
  }
}

test "PUSH_PROMISE on stream 0 is PROTOCOL_ERROR" {
  val payload: slice[Byte] = [0u8, 0u8, 0u8, 2u8]
  assertParseErr(hdr(5, 4, 0, 4), payload, H2ProtocolError, true, "push-promise stream 0")
}

// ---------------------------------------------------------------------------
// CONTINUATION (RFC 9113 §6.10).
// ---------------------------------------------------------------------------
test "CONTINUATION carries a fragment and END_HEADERS, round-trips" {
  val block: slice[Byte] = [64u8, 65u8, 66u8]
  val wire = serializeFrame(ContinuationFrame(streamId = 1, headerBlockFragment = block, endHeaders = false))
  val frame = singleDecoded(decodeWhole(false, wire), "continuation")
  match frame {
    case ContinuationFrame(streamId, fragment, endHeaders) -> {
      assertEqualInt(streamId, 1, "stream id")
      assertFalse(endHeaders, "END_HEADERS not set")
      assertBytesEqual(fragment, block, "fragment")
    }
    case _ -> panic("expected ContinuationFrame")
  }
}

test "CONTINUATION on stream 0 is PROTOCOL_ERROR" {
  val payload: slice[Byte] = [64u8]
  assertParseErr(hdr(9, 4, 0, 1), payload, H2ProtocolError, true, "continuation stream 0")
}

// ---------------------------------------------------------------------------
// Unknown frame types — pass-through (RFC 9113 §4.1/§5.1).
// ---------------------------------------------------------------------------
test "an unknown frame type is passed through as UnknownFrame, not rejected" {
  val payload: slice[Byte] = [1u8, 2u8, 3u8]
  val frame = singleDecoded(decodeWhole(false, rawFrame(99, 0, 7, payload)), "unknown-type")
  match frame {
    case UnknownFrame(header, body) -> {
      val hh: H2FrameHeader = header
      assertEqualInt(hh.frameType, 99, "raw type preserved")
      assertEqualInt(hh.streamId, 7, "stream id preserved")
      assertBytesEqual(body, payload, "payload preserved verbatim")
    }
    case _ -> panic("expected UnknownFrame")
  }
}

test "an UnknownFrame re-serializes to its original bytes" {
  val payload: slice[Byte] = [9u8, 9u8]
  val original = rawFrame(200, 3, 4, payload)
  val header = hdr(200, 3, 4, 2)
  val wire = serializeFrame(UnknownFrame(header = header, payload = payload))
  assertBytesEqual(wire, original, "unknown frame round-trips byte-for-byte")
}

// ---------------------------------------------------------------------------
// Error-code and settings-id mapping.
// ---------------------------------------------------------------------------
test "every registered error code round-trips through Long" {
  var code = 0i64
  while code <= 13i64 {
    assertEqualLong(errorCodeToLong(errorCodeFromLong(code)), code, "error code " + toString(code))
    code = code + 1i64
  }
}

test "an out-of-registry error code becomes H2UnknownError preserving its value" {
  val c = errorCodeFromLong(999i64)
  match c {
    case H2UnknownError(value) -> assertEqualLong(value, 999i64, "unknown code preserved")
    case _ -> panic("expected H2UnknownError")
  }
  assertEqualLong(errorCodeToLong(c), 999i64, "round-trips back out")
}

test "settings ids round-trip and unknown ids are preserved" {
  var id = 1
  while id <= 6 {
    assertEqualInt(settingsIdToInt(settingsIdFromInt(id)), id, "settings id " + toString(id))
    id = id + 1
  }
  assertEqualInt(settingsIdToInt(settingsIdFromInt(0)), 0, "unknown id 0 preserved")
  assertEqualInt(settingsIdToInt(settingsIdFromInt(255)), 255, "unknown id 255 preserved")
}

// ---------------------------------------------------------------------------
// Connection preface (RFC 9113 §3.4).
// ---------------------------------------------------------------------------
test "connectionPreface emits the 24-octet magic" {
  val pf = connectionPreface()
  assertEqualInt(pf.length, 24, "preface length")
  // "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".
  val expected: slice[Byte] = [
    80u8,
    82u8,
    73u8,
    32u8,
    42u8,
    32u8,
    72u8,
    84u8,
    84u8,
    80u8,
    47u8,
    50u8,
    46u8,
    48u8,
    13u8,
    10u8,
    13u8,
    10u8,
    83u8,
    77u8,
    13u8,
    10u8,
    13u8,
    10u8
  ]
  assertBytesEqual(pf, expected, "preface bytes")
  assertTrue(isConnectionPreface(pf), "isConnectionPreface accepts its own output")
}

test "isConnectionPreface rejects short or divergent input" {
  val short: slice[Byte] = [80u8, 82u8, 73u8]
  assertFalse(isConnectionPreface(short), "short input rejected")
  val bad: slice[Byte] = [
    80u8,
    82u8,
    73u8,
    32u8,
    42u8,
    32u8,
    72u8,
    84u8,
    84u8,
    80u8,
    47u8,
    51u8,
    46u8,
    48u8,
    13u8,
    10u8,
    13u8,
    10u8,
    83u8,
    77u8,
    13u8,
    10u8,
    13u8,
    10u8
  ]
  assertFalse(isConnectionPreface(bad), "HTTP/3.0 preface rejected")
}

test "a preface-expecting decoder consumes the preface then the initial SETTINGS" {
  val settings: slice[Byte] = rawFrame(4, 0, 0, [])
  val stream = connectionPreface().concat(settings)
  val events = dropNeedMore(decodeWhole(true, stream))
  assertEqualInt(events.count, 2, "PrefaceReceived + one frame")
  match events[0] {
    case PrefaceReceived -> assertTrue(true, "preface received")
    case _ -> panic("expected PrefaceReceived first")
  }
  match events[1] {
    case FrameDecoded(frame) -> match frame { case SettingsFrame(_, _) -> assertTrue(true, "SETTINGS follows preface"); case _ -> panic("expected a SETTINGS frame after the preface") }
    case _ -> panic("expected FrameDecoded after preface")
  }
}

test "a preface-expecting decoder fails on a bad preface and poisons itself" {
  val bad: slice[Byte] = [
    71u8,
    69u8,
    84u8,
    32u8,
    42u8,
    32u8,
    72u8,
    84u8,
    84u8,
    80u8,
    47u8,
    50u8,
    46u8,
    48u8,
    13u8,
    10u8,
    13u8,
    10u8,
    83u8,
    77u8,
    13u8,
    10u8,
    13u8,
    10u8
  ]
  val decoder = newFrameDecoder(true)
  val result = feedFrames(decoder, bad)
  assertTrue(isDecoderFailed(result.decoder), "decoder poisoned after bad preface")
  val events = dropNeedMore(result.events)
  assertEqualInt(events.count, 1, "one failure event")
  match events[0] {
    case FrameFailed(e) -> {
      assertEqualLong(errorCodeToLong(e.code), 1i64, "PROTOCOL_ERROR")
      assertTrue(e.connectionError, "connection error")
    }
    case _ -> panic("expected FrameFailed")
  }
}

// ---------------------------------------------------------------------------
// Streaming decoder — truncation, oversize, multi-frame, split torture.
// ---------------------------------------------------------------------------
test "a truncated frame yields FrameNeedMore, not an error" {
  // A DATA frame header claiming 4 payload octets, but only 2 supplied.
  val partial: slice[Byte] = [0u8, 0u8, 4u8, 0u8, 0u8, 0u8, 0u8, 0u8, 1u8, 104u8, 105u8]
  val events = decodeWhole(false, partial)
  assertEqualInt(events.count, 1, "single event")
  match events[0] {
    case FrameNeedMore -> assertTrue(true, "need more")
    case _ -> panic("expected FrameNeedMore for a truncated frame")
  }
}

test "a frame length exceeding SETTINGS_MAX_FRAME_SIZE is FRAME_SIZE_ERROR and poisons the decoder" {
  // Claim a 0x010000 (65536) payload, one octet over the 16384 default.
  val header: slice[Byte] = [1u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 1u8]
  val decoder = newFrameDecoder(false)
  val result = feedFrames(decoder, header)
  assertTrue(isDecoderFailed(result.decoder), "decoder poisoned by oversize frame")
  val events = dropNeedMore(result.events)
  assertEqualInt(events.count, 1, "one failure event")
  match events[0] {
    case FrameFailed(e) -> {
      assertEqualLong(errorCodeToLong(e.code), 6i64, "FRAME_SIZE_ERROR")
      assertTrue(e.connectionError, "connection error")
    }
    case _ -> panic("expected FrameFailed")
  }
}

test "a raised max-frame-size lets a larger frame through" {
  // The same 16385-octet DATA frame that the default ceiling rejects.
  val body: List[Byte] = newList()
  var i = 0
  while i < 16385 {
    body.add(97u8)
    i = i + 1
  }
  val wire = serializeFrame(DataFrame(streamId = 1, data = body.toArray(), endStream = false))
  val decoder = newFrameDecoderWithMaxSize(false, 16777215)
  val result = feedFrames(decoder, wire)
  assertFalse(isDecoderFailed(result.decoder), "not poisoned with a raised ceiling")
  val frame = singleDecoded(result.events, "large-data")
  match frame {
    case DataFrame(_, data, _) -> {
      val d: slice[Byte] = data
      assertEqualInt(d.length, 16385, "full payload decoded")
    }
    case _ -> panic("expected DataFrame")
  }
}

test "several frames buffered together decode in order" {
  val ping: slice[Byte] = serializeFrame(PingFrame(opaqueData = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8], ack = false))
  val wu: slice[Byte] = serializeFrame(WindowUpdateFrame(streamId = 1, windowSizeIncrement = 100))
  val data: slice[Byte] = serializeFrame(DataFrame(streamId = 1, data = [120u8], endStream = true))
  val stream = ping.concat(wu).concat(data)
  val events = dropNeedMore(decodeWhole(false, stream))
  assertEqualInt(events.count, 3, "three frames")
  match events[0] {
    case FrameDecoded(f) -> match f { case PingFrame(_, _) -> assertTrue(true, "ping"); case _ -> panic("expected ping") }
    case _ -> panic("expected decode")
  }
  match events[2] {
    case FrameDecoded(f) -> match f { case DataFrame(_, _, _) -> assertTrue(true, "data"); case _ -> panic("expected data") }
    case _ -> panic("expected decode")
  }
}

test "boundary-split torture: every 2-way split of a multi-frame stream decodes identically" {
  val ping: slice[Byte] = serializeFrame(PingFrame(opaqueData = [8u8, 7u8, 6u8, 5u8, 4u8, 3u8, 2u8, 1u8], ack = true))
  val settings: slice[Byte] = serializeFrame(RstStreamFrame(streamId = 3, errorCode = H2RefusedStream))
  val stream = ping.concat(settings)
  var splitAt = 1
  while splitAt < stream.length {
    val events = dropNeedMore(decodeSplitAt(false, stream, splitAt))
    val label = "split at " + toString(splitAt)
    assertEqualInt(events.count, 2, label + ": two frames")
    match events[0] {
      case FrameDecoded(f) -> match f { case PingFrame(_, ack) -> assertTrue(ack, label + ": ping ack"); case _ -> panic(label + ": expected ping") }
      case _ -> panic(label + ": expected decode 0")
    }
    match events[1] {
      case FrameDecoded(f) -> match f { case RstStreamFrame(sid, _) -> assertEqualInt(sid, 3, label + ": rst stream id"); case _ -> panic(label + ": expected rst_stream") }
      case _ -> panic(label + ": expected decode 1")
    }
    splitAt = splitAt + 1
  }
}

test "byte-at-a-time feeding decodes a multi-frame stream identically" {
  val a: slice[Byte] = serializeFrame(SettingsFrame(settings = newList(), ack = true))
  val b: slice[Byte] = serializeFrame(WindowUpdateFrame(streamId = 0, windowSizeIncrement = 32768))
  val stream = a.concat(b)
  val events = dropNeedMore(decodeByteByByte(false, stream))
  assertEqualInt(events.count, 2, "two frames byte-fed")
  match events[1] {
    case FrameDecoded(f) -> match f { case WindowUpdateFrame(sid, inc) -> { assertEqualInt(sid, 0, "connection-level window update"); assertEqualInt(inc, 32768, "increment") }; case _ -> panic("expected window update") }
    case _ -> panic("expected decode")
  }
}

test "a stream-level frame error does not poison the decoder; the next frame still decodes" {
  // A PRIORITY frame with a wrong length is a STREAM error (non-fatal); a
  // valid PING after it must still decode.
  val badPriority: slice[Byte] = rawFrame(2, 0, 3, [0u8, 0u8, 0u8, 1u8])
  val ping: slice[Byte] = serializeFrame(PingFrame(opaqueData = [1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8, 1u8], ack = false))
  val result = feedFrames(newFrameDecoder(false), badPriority.concat(ping))
  assertFalse(isDecoderFailed(result.decoder), "stream error keeps the connection alive")
  val events = dropNeedMore(result.events)
  assertEqualInt(events.count, 2, "failure then a decoded ping")
  match events[0] {
    case FrameFailed(e) -> assertFalse(e.connectionError, "stream-level, not connection-level")
    case _ -> panic("expected FrameFailed first")
  }
  match events[1] {
    case FrameDecoded(f) -> match f { case PingFrame(_, _) -> assertTrue(true, "ping decoded after stream error"); case _ -> panic("expected ping") }
    case _ -> panic("expected FrameDecoded second")
  }
}

test "an idle feed returns exactly FrameNeedMore" {
  val empty: slice[Byte] = []
  val events = decodeWhole(false, empty)
  assertEqualInt(events.count, 1, "single event")
  match events[0] {
    case FrameNeedMore -> assertTrue(true, "idle -> need more")
    case _ -> panic("expected FrameNeedMore")
  }
}
