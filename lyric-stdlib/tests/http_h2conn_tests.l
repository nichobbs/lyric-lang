//! stdlib/tests/http_h2conn_tests.l — behavioural corpus for
//! `Std.HttpEngine.H2Conn` (docs/61-https-tls-http-versions.md §6.4, D128;
//! phase 4.3 of epic #5874, issue #5888).
//!
//! This corpus is the HTTP/2 connection/stream state machine's executable
//! spec. Unlike the frame-codec corpus (`http_h2frame_tests.l`, byte vectors)
//! it drives the FSM end to end by composing the two real building blocks —
//! `Std.HttpEngine.H2Frame` (frame codec) and `Std.HttpEngine.Hpack` (HPACK) —
//! to synthesise client wire bytes, feeds them through `feed`, and asserts on
//! the semantic events, the serialized control frames the FSM emits in
//! response (decoded back through the frame codec), and the per-stream flow
//! control and lifecycle state. Because both layers are pure Lyric with zero
//! externs, the agreement between them is itself under test: a request encoded
//! by the HPACK encoder must decode through the server's HPACK decoder, and a
//! frame the FSM emits must parse through the frame decoder.
//!
//! Coverage: the connection-preface + SETTINGS handshake; a full
//! request/response exchange (HEADERS + DATA in, response HEADERS + DATA out);
//! HEADERS + CONTINUATION reassembly through HPACK (single-feed and split
//! across feeds); the stream lifecycle FSM and its illegal-transition
//! rejections; connection- and stream-level flow control on the receive side
//! (window exhaustion, overflow) and the send side (`sendData` exhaustion,
//! `WINDOW_UPDATE` replenishment, `SETTINGS_INITIAL_WINDOW_SIZE`-change window
//! adjustment); RST_STREAM (peer-initiated, mid-stream); PING auto-ACK;
//! GOAWAY (received and server-initiated); the concurrent-streams limit; and
//! the RFC's connection-vs-stream error classification (GOAWAY vs RST_STREAM),
//! including the malformed-sequence causes that force a GOAWAY.
//!
//! Runs via native `lyric test` on both targets (`--target dotnet` and
//! `--target jvm`): the whole stack is pure Lyric, so both must produce
//! identical results.
@test_module
package Std.HttpEngine.H2Conn.Tests

import Std.Core
import Std.Collections
import Std.HttpEngine
import Std.HttpEngine.H2Frame
import Std.HttpEngine.Hpack
import Std.HttpEngine.H2Conn as H2
import Std.Testing

// ---------------------------------------------------------------------------
// Byte / frame construction helpers (client side).
// ---------------------------------------------------------------------------
func emptyBytesT(): slice[Byte] {
  val e: slice[Byte] = []
  e
}

func mkBytes(n: in Int, fill: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < n {
    acc.add(fill.and(255).toByte())
    i = i + 1
  }
  acc.toArray()
}

func hf(name: in String, value: in String): HeaderField {
  HeaderField(name = name, value = value)
}

/// A minimal request pseudo-header set, HPACK-encoded with a fresh client
/// encoder (never dynamic-index-references, so any decoder decodes it).
func requestHeaders(): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":method", "GET"))
  h.add(hf(":scheme", "https"))
  h.add(hf(":path", "/"))
  h.add(hf(":authority", "example.com"))
  h
}

func responseHeaders(): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":status", "200"))
  h.add(hf("content-type", "text/plain"))
  h
}

func encodeBlock(headers: in List[HeaderField]): slice[Byte] {
  var enc = newEncoder(4096, false)
  encodeBlockWith(enc, headers)
}

/// Encode a header block with a caller-supplied (persistent) encoder, so a test
/// can exercise dynamic-table indexing across several requests — the same
/// paired HPACK context a real client keeps for the whole connection.
func encodeBlockWith(enc: inout HpackEncoder, headers: in List[HeaderField]): slice[Byte] {
  match encodeHeaderList(enc, headers) {
    case Ok(b) -> {
      // Typed local before returning the union-case value: on the JVM backend
      // returning a `Result`-bound value directly merges an `Object[]` frame
      // against the declared `[B` return type and trips a VerifyError
      // (inconsistent stackmap, #5936). Do not inline `block` back to `b`.
      val block: slice[Byte] = b
      block
    }
    case Err(_) -> emptyBytesT()
  }
}

/// A request with the three static-table pseudo-headers plus one custom header
/// (no `:authority`, which would add an extra dynamic-table entry and muddy the
/// index reasoning in the compression-context-sync test).
func customReq(name: in String, value: in String): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":method", "GET"))
  h.add(hf(":path", "/"))
  h.add(hf(":scheme", "https"))
  h.add(hf(name, value))
  h
}

/// A string of at least `minLen` characters, built by doubling so the test
/// stays fast (no O(n^2) per-char concatenation).
func bigString(minLen: in Int): String {
  var acc = "x"
  while acc.length < minLen {
    acc = acc + acc
  }
  acc
}

/// The value of the first header named `name` in a decoded header list, or the
/// empty string if absent.
func headerValueIn(headers: in List[HeaderField], name: in String): String {
  var i = 0
  var found = ""
  while i < headers.count {
    val h: HeaderField = headers[i]
    if h.name == name {
      found = h.value
    }
    i = i + 1
  }
  found
}

func settingsFrame(params: in List[SettingsParam]): slice[Byte] {
  serializeFrame(SettingsFrame(settings = params, ack = false))
}

func emptySettingsFrame(): slice[Byte] {
  val p: List[SettingsParam] = newList()
  settingsFrame(p)
}

func settingsAckFrame(): slice[Byte] {
  val p: List[SettingsParam] = newList()
  serializeFrame(SettingsFrame(settings = p, ack = true))
}

func oneSetting(id: in SettingsId, value: in Long): List[SettingsParam] {
  val p: List[SettingsParam] = newList()
  p.add(SettingsParam(id = id, value = value))
  p
}

func headersFrame(streamId: in Int, block: in slice[Byte], endStream: in Bool, endHeaders: in Bool): slice[Byte] {
  val none: Option[PriorityInfo] = None
  serializeFrame(
    HeadersFrame(
      streamId = streamId,
      headerBlockFragment = block,
      endStream = endStream,
      endHeaders = endHeaders,
      priority = none
    )
  )
}

func continuationFrame(streamId: in Int, block: in slice[Byte], endHeaders: in Bool): slice[Byte] {
  serializeFrame(ContinuationFrame(streamId = streamId, headerBlockFragment = block, endHeaders = endHeaders))
}

func dataFrame(streamId: in Int, data: in slice[Byte], endStream: in Bool): slice[Byte] {
  serializeFrame(DataFrame(streamId = streamId, data = data, endStream = endStream))
}

func windowUpdateFrame(streamId: in Int, increment: in Int): slice[Byte] {
  serializeFrame(WindowUpdateFrame(streamId = streamId, windowSizeIncrement = increment))
}

func rstFrame(streamId: in Int, code: in H2ErrorCode): slice[Byte] {
  serializeFrame(RstStreamFrame(streamId = streamId, errorCode = code))
}

func pingFrame(data: in slice[Byte], ack: in Bool): slice[Byte] {
  serializeFrame(PingFrame(opaqueData = data, ack = ack))
}

func goawayFrame(lastStreamId: in Int, code: in H2ErrorCode): slice[Byte] {
  serializeFrame(GoAwayFrame(lastStreamId = lastStreamId, errorCode = code, debugData = emptyBytesT()))
}

// ---------------------------------------------------------------------------
// Event / outbound inspection.
// ---------------------------------------------------------------------------
func hasConnError(events: in List[H2.H2Event]): Bool {
  var found = false
  var i = 0
  while i < events.count {
    match events[i] {
      case H2ConnError(_, _) -> {
        found = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func connErrorCodeLong(events: in List[H2.H2Event]): Long {
  var code = -1i64
  var i = 0
  while i < events.count {
    match events[i] {
      case H2ConnError(c, _) -> {
        code = errorCodeToLong(c)
      }
      case _ -> ()
    }
    i = i + 1
  }
  code
}

func expectConnError(events: in List[H2.H2Event], expected: in H2ErrorCode, label: in String): Unit {
  assertTrue(hasConnError(events), label + ": expected a connection error")
  assertEqualLong(connErrorCodeLong(events), errorCodeToLong(expected), label + ": connection error code")
}

func streamErrorCodeLong(events: in List[H2.H2Event], streamId: in Int): Long {
  var code = -1i64
  var i = 0
  while i < events.count {
    match events[i] {
      case H2StreamErr(sid, c, _) -> {
        if sid == streamId {
          code = errorCodeToLong(c)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  code
}

func expectStreamError(events: in List[H2.H2Event], streamId: in Int, expected: in H2ErrorCode, label: in String): Unit {
  assertEqualLong(streamErrorCodeLong(events, streamId), errorCodeToLong(expected), label + ": stream error code")
}

func findRequestHeaders(events: in List[H2.H2Event], streamId: in Int): Option[List[HeaderField]] {
  var i = 0
  while i < events.count {
    match events[i] {
      case H2RequestHeaders(sid, headers, _) -> {
        if sid == streamId {
          return Some(value = headers)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

func countRequestHeaders(events: in List[H2.H2Event]): Int {
  var n = 0
  var i = 0
  while i < events.count {
    match events[i] {
      case H2RequestHeaders(_, _, _) -> {
        n = n + 1
      }
      case _ -> ()
    }
    i = i + 1
  }
  n
}

func hasDataEvent(events: in List[H2.H2Event], streamId: in Int): Bool {
  var found = false
  var i = 0
  while i < events.count {
    match events[i] {
      case H2RequestData(sid, _, _) -> {
        if sid == streamId {
          found = true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func hasPeerReset(events: in List[H2.H2Event], streamId: in Int): Bool {
  var found = false
  var i = 0
  while i < events.count {
    match events[i] {
      case H2PeerReset(sid, _) -> {
        if sid == streamId {
          found = true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func hasWindowUpdated(events: in List[H2.H2Event], streamId: in Int): Bool {
  var found = false
  var i = 0
  while i < events.count {
    match events[i] {
      case H2WindowUpdated(sid) -> {
        if sid == streamId {
          found = true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func hasGoAwayReceived(events: in List[H2.H2Event]): Bool {
  var found = false
  var i = 0
  while i < events.count {
    match events[i] {
      case H2GoAwayReceived(_, _) -> {
        found = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func hasPingReceived(events: in List[H2.H2Event]): Bool {
  var found = false
  var i = 0
  while i < events.count {
    match events[i] {
      case H2PingReceived(_) -> {
        found = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func hasSettingsAcknowledged(events: in List[H2.H2Event]): Bool {
  var found = false
  var i = 0
  while i < events.count {
    match events[i] {
      case H2SettingsAcknowledged -> {
        found = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func hasSettingsReceived(events: in List[H2.H2Event]): Bool {
  var found = false
  var i = 0
  while i < events.count {
    match events[i] {
      case H2SettingsReceived(_) -> {
        found = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

// Decode the server's outbound bytes back into frames through the real codec.
func decodeFrames(bytes: in slice[Byte]): List[H2Frame] {
  var dec = newFrameDecoder(false)
  val r = feedFrames(dec, bytes)
  val acc: List[H2Frame] = newList()
  var i = 0
  while i < r.events.count {
    match r.events[i] {
      case FrameDecoded(f) -> acc.add(f)
      case _ -> ()
    }
    i = i + 1
  }
  acc
}

func outHasSettingsAck(frames: in List[H2Frame]): Bool {
  var found = false
  var i = 0
  while i < frames.count {
    match frames[i] {
      case SettingsFrame(_, ack) -> {
        if ack {
          found = true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func outHasPingAck(frames: in List[H2Frame]): Bool {
  var found = false
  var i = 0
  while i < frames.count {
    match frames[i] {
      case PingFrame(_, ack) -> {
        if ack {
          found = true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func outHasGoAway(frames: in List[H2Frame]): Bool {
  var found = false
  var i = 0
  while i < frames.count {
    match frames[i] {
      case GoAwayFrame(_, _, _) -> {
        found = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func outHasRst(frames: in List[H2Frame], streamId: in Int): Bool {
  var found = false
  var i = 0
  while i < frames.count {
    match frames[i] {
      case RstStreamFrame(sid, _) -> {
        if sid == streamId {
          found = true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func outHasWindowUpdate(frames: in List[H2Frame], streamId: in Int): Bool {
  var found = false
  var i = 0
  while i < frames.count {
    match frames[i] {
      case WindowUpdateFrame(sid, _) -> {
        if sid == streamId {
          found = true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func stateIs(s: in H2.H2StreamState, expected: in String): Bool {
  match s {
    case H2SIdle -> expected == "idle"
    case H2SOpen -> expected == "open"
    case H2SHalfClosedLocal -> expected == "hcl"
    case H2SHalfClosedRemote -> expected == "hcr"
    case H2SClosed -> expected == "closed"
  }
}

func outCountHeadersFrames(frames: in List[H2Frame]): Int {
  var n = 0
  var i = 0
  while i < frames.count {
    match frames[i] {
      case HeadersFrame(_, _, _, _, _) -> {
        n = n + 1
      }
      case _ -> ()
    }
    i = i + 1
  }
  n
}

func outCountContinuationFrames(frames: in List[H2Frame]): Int {
  var n = 0
  var i = 0
  while i < frames.count {
    match frames[i] {
      case ContinuationFrame(_, _, _) -> {
        n = n + 1
      }
      case _ -> ()
    }
    i = i + 1
  }
  n
}

/// The first frame is a HEADERS frame whose END_HEADERS flag is `false` — the
/// shape of a header block that spills into CONTINUATION frames.
func outFirstHeadersNotEndHeaders(frames: in List[H2Frame]): Bool {
  if frames.count == 0 {
    return false
  }
  match frames[0] {
    case HeadersFrame(_, _, _, endHeaders, _) -> not endHeaders
    case _ -> false
  }
}

/// The last frame is a CONTINUATION frame whose END_HEADERS flag is `true` —
/// the terminator of a split header block.
func outLastContinuationEndHeaders(frames: in List[H2Frame]): Bool {
  if frames.count == 0 {
    return false
  }
  match frames[frames.count - 1] {
    case ContinuationFrame(_, _, endHeaders) -> endHeaders
    case _ -> false
  }
}

// ---------------------------------------------------------------------------
// Handshake setup.
// ---------------------------------------------------------------------------
/// Create a server connection with the given local settings and complete the
/// client preface + SETTINGS handshake, returning the post-handshake
/// connection. Client `SETTINGS` are supplied by the caller (empty for the
/// default).
func setup(local: in H2.H2Settings, clientSettings: in slice[Byte]): H2.H2Connection {
  var conn = H2.newServerConnection(local)
  val input = connectionPreface().concat(clientSettings)
  val r = H2.feed(conn, input)
  r.conn
}

func setupDefault(): H2.H2Connection {
  setup(H2.h2DefaultServerSettings(), emptySettingsFrame())
}

func customSettings(
  headerTable: in Int, maxConc: in Int, initWin: in Int, maxFrame: in Int, maxHdrList: in Int
): H2.H2Settings {
  H2.H2Settings(
    headerTableSize = headerTable,
    enablePush = 0,
    maxConcurrentStreams = maxConc,
    initialWindowSize = initWin,
    maxFrameSize = maxFrame,
    maxHeaderListSize = maxHdrList
  )
}

// ===========================================================================
// Handshake.
// ===========================================================================
test "client preface + SETTINGS is applied and acknowledged" {
  var conn = H2.newServerConnection(H2.h2DefaultServerSettings())
  val input = connectionPreface().concat(emptySettingsFrame())
  val r = H2.feed(conn, input)
  assertTrue(hasSettingsReceived(r.events), "SETTINGS received event")
  assertTrue(outHasSettingsAck(decodeFrames(r.outbound)), "server queued a SETTINGS ACK")
  assertFalse(H2.isFailed(r.conn), "connection is healthy after handshake")
}

test "serverInitialFrame is a non-ACK SETTINGS frame the client can parse" {
  val conn = H2.newServerConnection(H2.h2DefaultServerSettings())
  val frames = decodeFrames(H2.serverInitialFrame(conn))
  assertEqualInt(frames.count, 1, "one frame")
  match frames[0] {
    case SettingsFrame(_, ack) -> assertFalse(ack, "server initial SETTINGS is not an ACK")
    case _ -> panic("expected a SETTINGS frame")
  }
}

test "the first frame after the preface must be SETTINGS (else GOAWAY)" {
  var conn = H2.newServerConnection(H2.h2DefaultServerSettings())
  val input = connectionPreface().concat(pingFrame(mkBytes(8, 1), false))
  val r = H2.feed(conn, input)
  expectConnError(r.events, H2ProtocolError, "non-SETTINGS first frame")
  assertTrue(H2.isFailed(r.conn), "connection poisoned")
  assertTrue(outHasGoAway(decodeFrames(r.outbound)), "GOAWAY queued")
}

test "a client SETTINGS ACK surfaces H2SettingsAcknowledged" {
  var conn = setupDefault()
  val r = H2.feed(conn, settingsAckFrame())
  assertTrue(hasSettingsAcknowledged(r.events), "settings-acknowledged event")
}

// ===========================================================================
// Full request/response exchange.
// ===========================================================================
test "a full GET request (HEADERS + DATA) surfaces headers then body" {
  var conn = setupDefault()
  val block = encodeBlock(requestHeaders())
  val r1 = H2.feed(conn, headersFrame(1, block, false, true))
  match findRequestHeaders(r1.events, 1) {
    case None -> panic("expected request headers on stream 1")
    case Some(hs) -> {
      assertEqualInt(hs.count, 4, "four request headers")
      // Typed local for the List-element deref (JVM erased-generics receiver).
      val h0: HeaderField = hs[0]
      assertEqual(h0.name, ":method", "first header name")
      assertEqual(h0.value, "GET", "first header value")
    }
  }
  assertTrue(stateIs(H2.streamState(r1.conn, 1), "open"), "stream open after headers")
  val r2 = H2.feed(r1.conn, dataFrame(1, mkBytes(5, 65), true))
  assertTrue(hasDataEvent(r2.events, 1), "data event on stream 1")
  assertTrue(stateIs(H2.streamState(r2.conn, 1), "hcr"), "half-closed (remote) after END_STREAM data")
}

test "server response HEADERS + DATA closes the stream and frames on the wire" {
  var conn = setupDefault()
  val block = encodeBlock(requestHeaders())
  val r1 = H2.feed(conn, headersFrame(1, block, true, true))
  var c = r1.conn
  assertTrue(stateIs(H2.streamState(c, 1), "hcr"), "half-closed (remote) after END_STREAM headers")
  match H2.encodeResponseHeaders(c, 1, responseHeaders(), false) {
    case Err(_) -> panic("response header encoding failed")
    case Ok(bytes) -> {
      val frames = decodeFrames(bytes)
      assertTrue(frames.count >= 1, "at least one HEADERS frame emitted")
    }
  }
  match H2.sendData(c, 1, mkBytes(11, 66), true) {
    case Err(_) -> panic("sendData failed")
    case Ok(bytes) -> {
      val frames = decodeFrames(bytes)
      assertEqualInt(frames.count, 1, "one DATA frame")
    }
  }
  assertTrue(stateIs(H2.streamState(c, 1), "closed"), "stream closed after server END_STREAM")
}

// ===========================================================================
// HEADERS + CONTINUATION reassembly.
// ===========================================================================
test "HEADERS + CONTINUATION reassemble into one decoded header list" {
  var conn = setupDefault()
  val block = encodeBlock(requestHeaders())
  val half = block.length / 2
  val first = block.slice(0, half)
  val second = block.slice(half, block.length)
  val bytes = headersFrame(1, first, false, false).concat(continuationFrame(1, second, true))
  val r = H2.feed(conn, bytes)
  assertEqualInt(countRequestHeaders(r.events), 1, "exactly one header event from HEADERS+CONTINUATION")
  match findRequestHeaders(r.events, 1) {
    case None -> panic("expected reassembled headers")
    case Some(hs) -> assertEqualInt(hs.count, 4, "all four headers reassembled")
  }
}

test "HEADERS + CONTINUATION split across feed calls reassemble correctly" {
  var conn = setupDefault()
  val block = encodeBlock(requestHeaders())
  val half = block.length / 2
  val r1 = H2.feed(conn, headersFrame(1, block.slice(0, half), false, false))
  assertEqualInt(countRequestHeaders(r1.events), 0, "no header event until END_HEADERS")
  val r2 = H2.feed(r1.conn, continuationFrame(1, block.slice(half, block.length), true))
  assertEqualInt(countRequestHeaders(r2.events), 1, "header event after the CONTINUATION completes it")
}

test "a non-CONTINUATION frame during header assembly is a connection error" {
  var conn = setupDefault()
  val block = encodeBlock(requestHeaders())
  val bytes = headersFrame(1, block, false, false).concat(dataFrame(1, mkBytes(1, 65), false))
  val r = H2.feed(conn, bytes)
  expectConnError(r.events, H2ProtocolError, "interleaved DATA during header assembly")
}

test "a CONTINUATION for a different stream is a connection error" {
  var conn = setupDefault()
  val block = encodeBlock(requestHeaders())
  val half = block.length / 2
  val bytes = headersFrame(1, block.slice(0, half), false, false).concat(
    continuationFrame(3, block.slice(half, block.length), true)
  )
  val r = H2.feed(conn, bytes)
  expectConnError(r.events, H2ProtocolError, "CONTINUATION for wrong stream")
}

test "an HPACK-undecodable header block is a COMPRESSION_ERROR connection error" {
  var conn = setupDefault()
  val bad: slice[Byte] = [128u8]
  val r = H2.feed(conn, headersFrame(1, bad, true, true))
  expectConnError(r.events, H2CompressionError, "invalid HPACK index 0")
}

// ===========================================================================
// Stream lifecycle & illegal transitions.
// ===========================================================================
test "HEADERS with an even (server-initiated) stream id is a connection error" {
  var conn = setupDefault()
  val r = H2.feed(conn, headersFrame(2, encodeBlock(requestHeaders()), true, true))
  expectConnError(r.events, H2ProtocolError, "even client stream id")
}

test "a non-increasing new stream id is a connection error" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(3, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  expectConnError(r2.events, H2ProtocolError, "stream id 1 after 3")
}

test "DATA on an idle (never-opened) stream is a connection error" {
  var conn = setupDefault()
  val r = H2.feed(conn, dataFrame(1, mkBytes(3, 65), false))
  expectConnError(r.events, H2ProtocolError, "DATA before HEADERS")
}

test "DATA after END_STREAM (half-closed remote) is a stream error, connection survives" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), true, true))
  val r2 = H2.feed(r1.conn, dataFrame(1, mkBytes(3, 65), false))
  expectStreamError(r2.events, 1, H2StreamClosed, "DATA on half-closed-remote stream")
  assertTrue(outHasRst(decodeFrames(r2.outbound), 1), "RST_STREAM queued for the stream")
  assertFalse(H2.isFailed(r2.conn), "connection still usable after a stream error")
}

test "RST_STREAM mid-stream closes just that stream and surfaces H2PeerReset" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, rstFrame(1, H2Cancel))
  assertTrue(hasPeerReset(r2.events, 1), "peer reset event")
  assertTrue(stateIs(H2.streamState(r2.conn, 1), "closed"), "stream closed after RST_STREAM")
  assertFalse(H2.isFailed(r2.conn), "connection survives a stream reset")
}

test "RST_STREAM on an idle stream is a connection error" {
  var conn = setupDefault()
  val r = H2.feed(conn, rstFrame(5, H2Cancel))
  expectConnError(r.events, H2ProtocolError, "RST_STREAM before the stream existed")
}

// ===========================================================================
// Concurrent-streams limit.
// ===========================================================================
test "opening more streams than SETTINGS_MAX_CONCURRENT_STREAMS refuses the excess" {
  var conn = setup(customSettings(4096, 2, 65535, 16384, 32768), emptySettingsFrame())
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, headersFrame(3, encodeBlock(requestHeaders()), false, true))
  val r3 = H2.feed(r2.conn, headersFrame(5, encodeBlock(requestHeaders()), false, true))
  expectStreamError(r3.events, 5, H2RefusedStream, "third concurrent stream refused")
  assertTrue(outHasRst(decodeFrames(r3.outbound), 5), "RST_STREAM(REFUSED_STREAM) queued")
  assertFalse(H2.isFailed(r3.conn), "refusal is a stream error, not a connection error")
  assertEqualInt(H2.activeStreamCount(r3.conn), 2, "still only two active streams")
}

// ===========================================================================
// Receive-side flow control.
// ===========================================================================
test "DATA exceeding a stream receive window is a stream FLOW_CONTROL_ERROR" {
  var conn = setup(customSettings(4096, 128, 10, 16384, 32768), emptySettingsFrame())
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, dataFrame(1, mkBytes(20, 65), false))
  expectStreamError(r2.events, 1, H2FlowControlError, "20 bytes into a 10-byte stream window")
  assertFalse(H2.isFailed(r2.conn), "stream flow error does not poison the connection")
}

test "DATA is debited from the stream receive window" {
  var conn = setup(customSettings(4096, 128, 100, 16384, 32768), emptySettingsFrame())
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  assertEqualInt(H2.streamReceiveWindow(r1.conn, 1), 100, "initial stream receive window")
  val r2 = H2.feed(r1.conn, dataFrame(1, mkBytes(30, 65), false))
  assertEqualInt(H2.streamReceiveWindow(r2.conn, 1), 70, "receive window debited by 30")
}

test "DATA exceeding the connection receive window is a connection FLOW_CONTROL_ERROR" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  var c = r1.conn
  // Default connection receive window is 65535; four 16384-byte frames overrun it.
  val d = mkBytes(16384, 65)
  val a = H2.feed(c, dataFrame(1, d, false))
  val b = H2.feed(a.conn, dataFrame(1, d, false))
  val cc = H2.feed(b.conn, dataFrame(1, d, false))
  val dd = H2.feed(cc.conn, dataFrame(1, d, false))
  expectConnError(dd.events, H2FlowControlError, "connection receive window overrun")
  assertTrue(H2.isFailed(dd.conn), "connection poisoned by a connection flow error")
}

test "grantConnectionWindow / grantStreamWindow emit WINDOW_UPDATE and replenish" {
  var conn = setup(customSettings(4096, 128, 50, 16384, 32768), emptySettingsFrame())
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  var c = r1.conn
  val cbytes = H2.grantConnectionWindow(c, 1000)
  assertTrue(outHasWindowUpdate(decodeFrames(cbytes), 0), "connection WINDOW_UPDATE emitted")
  val sbytes = H2.grantStreamWindow(c, 1, 25)
  assertTrue(outHasWindowUpdate(decodeFrames(sbytes), 1), "stream WINDOW_UPDATE emitted")
  assertEqualInt(H2.streamReceiveWindow(c, 1), 75, "stream receive window replenished to 75")
}

// ===========================================================================
// Send-side flow control.
// ===========================================================================
test "sendData is bounded by the peer's stream window and replenished by WINDOW_UPDATE" {
  var conn = setup(H2.h2DefaultServerSettings(), settingsFrame(oneSetting(SettingsInitialWindowSize, 5i64)))
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  var c = r1.conn
  assertEqualInt(H2.streamSendWindow(c, 1), 5, "stream send window follows the peer initial window")
  match H2.sendData(c, 1, mkBytes(5, 66), false) {
    case Err(_) -> panic("sendData of 5 bytes should fit the window")
    case Ok(_) -> assertEqualInt(H2.streamSendWindow(c, 1), 0, "send window exhausted")
  }
  match H2.sendData(c, 1, mkBytes(1, 66), false) {
    case Ok(_) -> panic("sendData past the window must fail")
    case Err(e) -> match e { case WindowExceeded(avail, req) -> { assertEqualInt(avail, 0, "no window available"); assertEqualInt(req, 1, "1 byte requested") }; case StreamNotWritable(_) -> panic("expected WindowExceeded, not StreamNotWritable") }
  }
  val r2 = H2.feed(c, windowUpdateFrame(1, 10))
  assertTrue(hasWindowUpdated(r2.events, 1), "WINDOW_UPDATE surfaced")
  assertEqualInt(H2.streamSendWindow(r2.conn, 1), 10, "send window replenished")
  match H2.sendData(r2.conn, 1, mkBytes(1, 66), false) {
    case Err(_) -> panic("sendData should succeed after replenishment")
    case Ok(_) -> assertEqualInt(H2.streamSendWindow(r2.conn, 1), 9, "send window debited after resend")
  }
}

test "sendData on a non-writable stream returns StreamNotWritable" {
  var conn = setupDefault()
  match H2.sendData(conn, 7, mkBytes(1, 66), false) {
    case Ok(_) -> panic("sending on an unknown stream must fail")
    case Err(e) -> match e { case StreamNotWritable(sid) -> assertEqualInt(sid, 7, "reports the unwritable stream id"); case WindowExceeded(_, _) -> panic("expected StreamNotWritable") }
  }
}

test "a SETTINGS_INITIAL_WINDOW_SIZE change adjusts existing stream send windows" {
  var conn = setup(H2.h2DefaultServerSettings(), settingsFrame(oneSetting(SettingsInitialWindowSize, 100i64)))
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  assertEqualInt(H2.streamSendWindow(r1.conn, 1), 100, "initial send window is 100")
  val r2 = H2.feed(r1.conn, settingsFrame(oneSetting(SettingsInitialWindowSize, 250i64)))
  assertEqualInt(H2.streamSendWindow(r2.conn, 1), 250, "send window grew by the +150 delta")
  val r3 = H2.feed(r2.conn, settingsFrame(oneSetting(SettingsInitialWindowSize, 60i64)))
  assertEqualInt(H2.streamSendWindow(r3.conn, 1), 60, "send window shrank by the -190 delta")
}

test "a WINDOW_UPDATE overflowing a stream send window is a stream FLOW_CONTROL_ERROR" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, windowUpdateFrame(1, 2147483647))
  expectStreamError(r2.events, 1, H2FlowControlError, "stream send window overflow")
}

test "a WINDOW_UPDATE overflowing the connection send window is a connection FLOW_CONTROL_ERROR" {
  var conn = setupDefault()
  val r = H2.feed(conn, windowUpdateFrame(0, 2147483647))
  expectConnError(r.events, H2FlowControlError, "connection send window overflow")
}

test "a WINDOW_UPDATE on the connection replenishes the send window" {
  var conn = setupDefault()
  val r = H2.feed(conn, windowUpdateFrame(0, 1000))
  assertTrue(hasWindowUpdated(r.events, 0), "connection window-updated event")
  assertEqualInt(H2.connectionSendWindow(r.conn), 66535, "connection send window grew from 65535 by 1000")
}

test "a negative stream send window recovers via WINDOW_UPDATE without Int overflow (#6066)" {
  // Peer initial window 100; server sends 80 (window -> 20); peer then SHRINKS
  // the initial window to 10 (RFC 9113 6.9.2 permits this) driving the stream
  // window negative (20 - 90 = -70). A subsequent legit WINDOW_UPDATE must
  // apply — the pre-fix guard `increment > h2MaxWindow() - sendWindow` overflows
  // 32-bit Int when sendWindow is negative — and the stream must recover.
  var conn = setup(H2.h2DefaultServerSettings(), settingsFrame(oneSetting(SettingsInitialWindowSize, 100i64)))
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  var c = r1.conn
  match H2.sendData(c, 1, mkBytes(80, 66), false) {
    case Err(_) -> panic("initial 80-byte send should fit the 100-byte window")
    case Ok(_) -> assertEqualInt(H2.streamSendWindow(c, 1), 20, "window after the 80-byte send")
  }
  val r2 = H2.feed(c, settingsFrame(oneSetting(SettingsInitialWindowSize, 10i64)))
  assertEqualInt(H2.streamSendWindow(r2.conn, 1), -70, "stream send window is negative after the shrink")
  assertFalse(H2.isFailed(r2.conn), "the legitimate shrink is not an error")
  val r3 = H2.feed(r2.conn, windowUpdateFrame(1, 100))
  assertTrue(hasWindowUpdated(r3.events, 1), "window-updated event on the recovery")
  assertFalse(H2.isFailed(r3.conn), "no overflow/panic on the recovery WINDOW_UPDATE")
  assertEqualInt(H2.streamSendWindow(r3.conn, 1), 30, "stream window recovered to -70 + 100 = 30")
  match H2.sendData(r3.conn, 1, mkBytes(30, 66), false) {
    case Err(_) -> panic("stream should be able to send again after recovery")
    case Ok(_) -> assertEqualInt(H2.streamSendWindow(r3.conn, 1), 0, "window exhausted after the 30-byte resend")
  }
}

test "grantStreamWindow rejects an increment that would overflow the receive window (#6067)" {
  var conn = setup(customSettings(4096, 128, 100, 16384, 32768), emptySettingsFrame())
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val c = r1.conn
  // Stream receive window is 100, so the largest legal increment is
  // h2MaxWindow() - 100; one larger violates the contract and must panic.
  assertPanics("grantStreamWindow overflow", { -> val ignored = H2.grantStreamWindow(c, 1, 2147483647) })
}

test "WINDOW_UPDATE on an idle even (push) stream id below the high-water mark is a connection error (#6068)" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(3, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, windowUpdateFrame(2, 10))
  expectConnError(r2.events, H2ProtocolError, "WINDOW_UPDATE on idle even stream 2")
}

test "RST_STREAM on an idle even (push) stream id is a connection error (#6068)" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(3, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, rstFrame(2, H2Cancel))
  expectConnError(r2.events, H2ProtocolError, "RST_STREAM on idle even stream 2")
}

test "WINDOW_UPDATE on a skipped (implicitly closed) odd stream id is a tolerated no-op (#6068)" {
  // Opening stream 5 implicitly closes 1 and 3 (RFC 9113 5.1.1). A late
  // WINDOW_UPDATE on the never-materialised, now-closed stream 3 (odd, below the
  // high-water mark) is a flow-control race the server must tolerate, not error.
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(5, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, windowUpdateFrame(3, 10))
  assertFalse(H2.isFailed(r2.conn), "late WINDOW_UPDATE on a closed odd stream is a no-op")
  assertFalse(hasConnError(r2.events), "no connection error from the tolerated race")
}

test "DATA pipelined for a refused stream is a stream RST_STREAM, not a connection GOAWAY (#6073)" {
  // The client refuses race: it opened stream 3 (refused by the concurrency
  // limit) and pipelined DATA before seeing the RST. That DATA must reset only
  // the stream and reclaim the connection window — killing the whole connection
  // with a GOAWAY would break an RFC-anticipated, retryable outcome.
  var conn = setup(customSettings(4096, 1, 65535, 16384, 32768), emptySettingsFrame())
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, headersFrame(3, encodeBlock(requestHeaders()), false, true))
  expectStreamError(r2.events, 3, H2RefusedStream, "stream 3 refused by the concurrency limit")
  val before = H2.connectionReceiveWindow(r2.conn)
  val r3 = H2.feed(r2.conn, dataFrame(3, mkBytes(12, 65), false))
  assertFalse(H2.isFailed(r3.conn), "DATA for a refused stream does not kill the connection")
  assertFalse(hasConnError(r3.events), "no connection error")
  expectStreamError(r3.events, 3, H2StreamClosed, "DATA for the refused stream is a stream error")
  assertTrue(outHasRst(decodeFrames(r3.outbound), 3), "RST_STREAM queued for the refused stream")
  assertEqualInt(
    H2.connectionReceiveWindow(r3.conn),
    before,
    "connection receive window reclaimed for the dropped DATA"
  )
}

test "a stream-level DATA FLOW_CONTROL_ERROR reclaims the connection receive window (#6074)" {
  var conn = setup(customSettings(4096, 128, 10, 16384, 32768), emptySettingsFrame())
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val before = H2.connectionReceiveWindow(r1.conn)
  val r2 = H2.feed(r1.conn, dataFrame(1, mkBytes(20, 65), false))
  expectStreamError(r2.events, 1, H2FlowControlError, "20 bytes into a 10-byte stream window")
  assertTrue(outHasWindowUpdate(decodeFrames(r2.outbound), 0), "connection WINDOW_UPDATE reclaims the dropped DATA")
  assertEqualInt(H2.connectionReceiveWindow(r2.conn), before, "connection receive window fully reclaimed")
  assertFalse(H2.isFailed(r2.conn), "stream flow error does not poison the connection")
}

// ===========================================================================
// Trailer HEADERS (#6075).
// ===========================================================================
test "trailer HEADERS after body data end the request and surface a second header list (#6075)" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  var c = r1.conn
  val r2 = H2.feed(c, dataFrame(1, mkBytes(4, 65), false))
  assertTrue(stateIs(H2.streamState(r2.conn, 1), "open"), "still open after non-final DATA")
  val trailer: List[HeaderField] = newList()
  trailer.add(hf("x-checksum", "abc"))
  val r3 = H2.feed(r2.conn, headersFrame(1, encodeBlock(trailer), true, true))
  match findRequestHeaders(r3.events, 1) {
    case None -> panic("expected a trailer header event on stream 1")
    case Some(hs) -> assertEqual(headerValueIn(hs, "x-checksum"), "abc", "trailer field value")
  }
  assertTrue(stateIs(H2.streamState(r3.conn, 1), "hcr"), "half-closed (remote) after END_STREAM trailers")
}

test "trailer HEADERS without END_STREAM is a connection error (#6075)" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val trailer: List[HeaderField] = newList()
  trailer.add(hf("x-checksum", "abc"))
  val r2 = H2.feed(r1.conn, headersFrame(1, encodeBlock(trailer), false, true))
  expectConnError(r2.events, H2ProtocolError, "trailer HEADERS lacking END_STREAM")
}

test "HEADERS on a half-closed (remote) stream is a stream error (#6075)" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), true, true))
  assertTrue(stateIs(H2.streamState(r1.conn, 1), "hcr"), "half-closed (remote) after END_STREAM headers")
  val trailer: List[HeaderField] = newList()
  trailer.add(hf("x-late", "1"))
  val r2 = H2.feed(r1.conn, headersFrame(1, encodeBlock(trailer), true, true))
  expectStreamError(r2.events, 1, H2StreamClosed, "HEADERS after the peer already ended the stream")
  assertFalse(H2.isFailed(r2.conn), "a late-HEADERS stream error does not poison the connection")
}

// ===========================================================================
// Header-list limit, settings-race overflow, response split, HPACK sync,
// CONTINUATION flood (#6077/#6076/#6078).
// ===========================================================================
test "a header block exceeding SETTINGS_MAX_HEADER_LIST_SIZE is ENHANCE_YOUR_CALM (#6077)" {
  var conn = setup(customSettings(4096, 128, 65535, 16384, 4), emptySettingsFrame())
  val r = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  expectConnError(r.events, H2EnhanceYourCalm, "header block over the 4-byte list budget")
}

test "a SETTINGS_INITIAL_WINDOW_SIZE increase that overflows a stream window is a connection error (#6077)" {
  // Peer initial window 1; open a stream; WINDOW_UPDATE it to the maximum
  // (2^31-1); then a SETTINGS increase (delta +99) would push it past the max.
  var conn = setup(H2.h2DefaultServerSettings(), settingsFrame(oneSetting(SettingsInitialWindowSize, 1i64)))
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  assertEqualInt(H2.streamSendWindow(r1.conn, 1), 1, "initial stream send window is 1")
  val r2 = H2.feed(r1.conn, windowUpdateFrame(1, 2147483646))
  assertEqualInt(H2.streamSendWindow(r2.conn, 1), 2147483647, "stream send window at the maximum")
  val r3 = H2.feed(r2.conn, settingsFrame(oneSetting(SettingsInitialWindowSize, 100i64)))
  expectConnError(r3.events, H2FlowControlError, "initial-window increase overflows the stream window")
}

test "a response header block larger than the peer max frame size splits into HEADERS + CONTINUATION (#6077)" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), true, true))
  var c = r1.conn
  val big: List[HeaderField] = newList()
  big.add(hf(":status", "200"))
  big.add(hf("x-big", bigString(60000)))
  match H2.encodeResponseHeaders(c, 1, big, false) {
    case Err(_) -> panic("encoding a large response header block should succeed")
    case Ok(bytes) -> {
      val frames = decodeFrames(bytes)
      assertEqualInt(outCountHeadersFrames(frames), 1, "exactly one HEADERS frame")
      assertTrue(outFirstHeadersNotEndHeaders(frames), "HEADERS frame does not set END_HEADERS")
      assertTrue(outCountContinuationFrames(frames) >= 1, "at least one CONTINUATION frame")
      assertTrue(outLastContinuationEndHeaders(frames), "final CONTINUATION sets END_HEADERS")
    }
  }
}

test "a refused stream's header block is HPACK-decoded so the compression context stays in sync (#6076)" {
  // maxConcurrentStreams = 1, and ONE persistent client encoder (the paired
  // HPACK context). Stream 1 inserts x-a:1; stream 3 (refused by the limit)
  // inserts x-b:2 — the server MUST still decode it (RFC 9113 4.3) so its
  // decoder's dynamic table gains x-b:2. After stream 1 is reset, stream 5
  // references x-b:2 by its dynamic index; it only resolves correctly if the
  // refused block was decoded.
  var conn = setup(customSettings(4096, 1, 65535, 16384, 32768), emptySettingsFrame())
  var enc = newEncoder(4096, false)
  val b1 = encodeBlockWith(enc, customReq("x-a", "1"))
  val r1 = H2.feed(conn, headersFrame(1, b1, false, true))
  var c = r1.conn
  val b3 = encodeBlockWith(enc, customReq("x-b", "2"))
  val r3 = H2.feed(c, headersFrame(3, b3, true, true))
  expectStreamError(r3.events, 3, H2RefusedStream, "stream 3 refused by the concurrency limit")
  val r4 = H2.feed(r3.conn, rstFrame(1, H2Cancel))
  assertTrue(stateIs(H2.streamState(r4.conn, 1), "closed"), "stream 1 closed, freeing capacity")
  val b5 = encodeBlockWith(enc, customReq("x-b", "2"))
  val r5 = H2.feed(r4.conn, headersFrame(5, b5, true, true))
  assertFalse(H2.isFailed(r5.conn), "no COMPRESSION_ERROR — the dynamic index resolved")
  match findRequestHeaders(r5.events, 5) {
    case None -> panic("expected request headers on stream 5")
    case Some(hs) -> assertEqual(headerValueIn(hs, "x-b"), "2", "dynamic-indexed header resolved via the synced context")
  }
}

test "a CONTINUATION flood without END_HEADERS is bounded and terminated with ENHANCE_YOUR_CALM (#6078)" {
  var conn = setupDefault()
  val head = headersFrame(1, encodeBlock(requestHeaders()), false, false)
  var input = head
  val empty: slice[Byte] = []
  var i = 0
  while i <= 1024 {
    input = input.concat(continuationFrame(1, empty, false))
    i = i + 1
  }
  val r = H2.feed(conn, input)
  expectConnError(r.events, H2EnhanceYourCalm, "CONTINUATION-flood mitigation")
}

// ===========================================================================
// Trailer-rejection compression sync, Rapid Reset, send-guards (#6082–#6087).
// ===========================================================================
test "a REJECTED trailer HEADERS block is still HPACK-decoded so the context stays in sync (#6082)" {
  // One persistent client encoder. Stream 1 (ended) inserts x-a:1; a trailer
  // HEADERS on the now-half-closed-remote stream 1 is rejected, but must still
  // be decoded — it inserts x-b:2. Stream 3 then references x-b:2 by its dynamic
  // index; it only resolves if the rejected trailer block was decoded.
  var conn = setupDefault()
  var enc = newEncoder(4096, false)
  val b1 = encodeBlockWith(enc, customReq("x-a", "1"))
  val r1 = H2.feed(conn, headersFrame(1, b1, true, true))
  assertTrue(stateIs(H2.streamState(r1.conn, 1), "hcr"), "stream 1 half-closed (remote)")
  // A "trailer" on the half-closed-remote stream 1 is rejected (stream error),
  // yet must advance the shared HPACK context.
  val bt: List[HeaderField] = newList()
  bt.add(hf("x-b", "2"))
  val rt = H2.feed(r1.conn, headersFrame(1, encodeBlockWith(enc, bt), true, true))
  expectStreamError(rt.events, 1, H2StreamClosed, "trailer on a half-closed-remote stream is rejected")
  assertFalse(H2.isFailed(rt.conn), "the rejection is a stream error, connection survives")
  // Now stream 3 references x-b:2 by dynamic index.
  val b3 = encodeBlockWith(enc, customReq("x-b", "2"))
  val r3 = H2.feed(rt.conn, headersFrame(3, b3, true, true))
  assertFalse(H2.isFailed(r3.conn), "no COMPRESSION_ERROR — the rejected block kept the context synced")
  match findRequestHeaders(r3.events, 3) {
    case None -> panic("expected request headers on stream 3")
    case Some(hs) -> assertEqual(headerValueIn(hs, "x-b"), "2", "dynamic-indexed header resolved via the synced context")
  }
}

test "a Rapid Reset flood (HEADERS + immediate RST_STREAM) terminates the connection (#6083)" {
  // maxRapidResets() is 100; 101 open+reset pairs cross it. serverCompletedCount
  // is 0 (nothing was completed), so the ratio guard also trips.
  var conn = setupDefault()
  var input: slice[Byte] = []
  var i = 0
  var id = 1
  while i <= 100 {
    input = input.concat(headersFrame(id, encodeBlock(requestHeaders()), false, true))
    input = input.concat(rstFrame(id, H2Cancel))
    id = id + 2
    i = i + 1
  }
  val r = H2.feed(conn, input)
  expectConnError(r.events, H2EnhanceYourCalm, "Rapid Reset mitigation")
  assertTrue(H2.isFailed(r.conn), "connection poisoned after the reset flood")
  assertTrue(outHasGoAway(decodeFrames(r.outbound)), "GOAWAY queued")
}

func runCompletions(conn: in H2.H2Connection, startOddId: in Int, count: in Int): H2.H2Connection {
  var c = conn
  var i = 0
  var id = startOddId
  while i < count {
    val r = H2.feed(c, headersFrame(id, encodeBlock(requestHeaders()), true, true))
    c = r.conn
    match H2.encodeResponseHeaders(c, id, responseHeaders(), true) {
      case Err(_) -> panic("completion response should succeed")
      case Ok(_) -> ()
    }
    id = id + 2
    i = i + 1
  }
  c
}

test "a busy connection that completes as many streams as it resets is NOT falsely terminated (#6083 ratio guard)" {
  // 101 completed streams give a completion credit of 101; a following 101
  // open+reset pushes rapidResetCount to 101 (> 100) but not past the credit, so
  // the ratio guard keeps the connection alive.
  var conn = setupDefault()
  var c = runCompletions(conn, 1, 101)
  assertFalse(H2.isFailed(c), "healthy after 101 completed streams")
  var input: slice[Byte] = []
  var i = 0
  var id = 203
  while i <= 100 {
    input = input.concat(headersFrame(id, encodeBlock(requestHeaders()), false, true))
    input = input.concat(rstFrame(id, H2Cancel))
    id = id + 2
    i = i + 1
  }
  val r = H2.feed(c, input)
  assertFalse(H2.isFailed(r.conn), "ratio guard: resets do not exceed completions, connection survives")
  assertFalse(hasConnError(r.events), "no connection error from the balanced workload")
}

test "encodeResponseHeaders on a non-writable stream returns HeaderStreamNotWritable (#6084)" {
  var conn = setupDefault()
  match H2.encodeResponseHeaders(conn, 9, responseHeaders(), false) {
    case Ok(_) -> panic("encoding headers on an unknown stream must fail")
    case Err(e) -> match e { case HeaderStreamNotWritable(sid) -> assertEqualInt(sid, 9, "reports the unwritable stream id"); case HeaderEncodingFailed(_) -> panic("expected HeaderStreamNotWritable") }
  }
}

test "driver send/grant helpers are no-ops on a poisoned connection (#6085)" {
  // Poison the connection with a protocol error, then confirm every driver-facing
  // send/grant helper refuses to act.
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  var c = r1.conn
  val rp = H2.feed(c, pingFrame(mkBytes(8, 1), false))
  // (ping is fine) — poison via an even-stream-id HEADERS.
  val rf = H2.feed(rp.conn, headersFrame(2, encodeBlock(requestHeaders()), false, true))
  assertTrue(H2.isFailed(rf.conn), "connection poisoned")
  var f = rf.conn
  match H2.sendData(f, 1, mkBytes(3, 66), false) {
    case Ok(_) -> panic("sendData must not act on a poisoned connection")
    case Err(_) -> ()
  }
  match H2.encodeResponseHeaders(f, 1, responseHeaders(), false) {
    case Ok(_) -> panic("encodeResponseHeaders must not act on a poisoned connection")
    case Err(_) -> ()
  }
  assertEqualInt(
    H2.grantConnectionWindow(f, 100).length,
    0,
    "grantConnectionWindow is a no-op on a poisoned connection"
  )
  assertEqualInt(H2.grantStreamWindow(f, 1, 100).length, 0, "grantStreamWindow is a no-op on a poisoned connection")
}

test "new peer streams above the advertised last-stream-id are refused after the server GOAWAY (#6086)" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  var c = r1.conn
  // Server begins graceful shutdown; last-stream-id advertised is 1.
  val goaway = H2.sendGoAway(c, H2NoError)
  assertTrue(H2.goAwayWasSent(c), "goAwayWasSent set")
  // A brand-new stream 3 (above the advertised last-stream-id) is refused, not
  // accepted — but the connection stays open for the in-flight stream 1.
  val r3 = H2.feed(c, headersFrame(3, encodeBlock(requestHeaders()), false, true))
  expectStreamError(r3.events, 3, H2RefusedStream, "new stream after GOAWAY refused")
  assertFalse(H2.isFailed(r3.conn), "GOAWAY-draining does not poison the connection")
  assertTrue(stateIs(H2.streamState(r3.conn, 3), "idle"), "the refused stream was not created")
}

test "a PING ACK from the peer surfaces H2PingAcknowledged (#6087)" {
  var conn = setupDefault()
  val r = H2.feed(conn, pingFrame(mkBytes(8, 9), true))
  var found = false
  var i = 0
  while i < r.events.count {
    match r.events[i] {
      case H2PingAcknowledged(_) -> {
        found = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  assertTrue(found, "ping-acknowledged event")
}

test "a multi-parameter SETTINGS with a mid-list invalid parameter aborts the whole frame (#6087)" {
  var conn = setupDefault()
  val params: List[SettingsParam] = newList()
  params.add(SettingsParam(id = SettingsMaxConcurrentStreams, value = 50i64))
  params.add(SettingsParam(id = SettingsEnablePush, value = 5i64))
  params.add(SettingsParam(id = SettingsInitialWindowSize, value = 200i64))
  val r = H2.feed(conn, settingsFrame(params))
  expectConnError(r.events, H2ProtocolError, "invalid ENABLE_PUSH mid-list")
  assertTrue(H2.isFailed(r.conn), "the whole SETTINGS frame is rejected")
}

test "DATA on a peer-reset (closed) stream is a stream error with window reclaim (#6087)" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, rstFrame(1, H2Cancel))
  assertTrue(stateIs(H2.streamState(r2.conn, 1), "closed"), "stream closed by peer RST")
  val before = H2.connectionReceiveWindow(r2.conn)
  val r3 = H2.feed(r2.conn, dataFrame(1, mkBytes(6, 65), false))
  expectStreamError(r3.events, 1, H2StreamClosed, "DATA on the peer-reset stream")
  assertFalse(H2.isFailed(r3.conn), "connection survives")
  assertEqualInt(H2.connectionReceiveWindow(r3.conn), before, "connection window reclaimed for the dropped DATA")
}

// ===========================================================================
// Retained closed streams are inert for flow control (#6090/#6091).
// ===========================================================================
test "a SETTINGS_INITIAL_WINDOW_SIZE change does not tear down the connection over a CLOSED stream's window (#6090)" {
  // Peer initial window 1. Stream 1 grows its send window to the maximum via
  // ordinary WINDOW_UPDATE, then closes (retained with sendWindow = 2^31-1). A
  // later, perfectly legal INITIAL_WINDOW_SIZE increase must skip the dead
  // stream (RFC 9113 6.9.2 scopes the adjustment to active windows) rather than
  // trip its overflow guard and kill every live stream on the connection.
  var conn = setup(H2.h2DefaultServerSettings(), settingsFrame(oneSetting(SettingsInitialWindowSize, 1i64)))
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val r2 = H2.feed(r1.conn, windowUpdateFrame(1, 2147483646))
  assertEqualInt(H2.streamSendWindow(r2.conn, 1), 2147483647, "stream 1 send window at the maximum")
  val r3 = H2.feed(r2.conn, rstFrame(1, H2Cancel))
  assertTrue(stateIs(H2.streamState(r3.conn, 1), "closed"), "stream 1 closed but retained")
  // A second, live stream that must keep working after the settings change.
  val r4 = H2.feed(r3.conn, headersFrame(3, encodeBlock(requestHeaders()), false, true))
  assertEqualInt(H2.streamSendWindow(r4.conn, 3), 1, "live stream 3 starts at the current initial window")
  val r5 = H2.feed(r4.conn, settingsFrame(oneSetting(SettingsInitialWindowSize, 100i64)))
  assertFalse(H2.isFailed(r5.conn), "the closed stream's max window must NOT trip the overflow tear-down")
  assertFalse(hasConnError(r5.events), "no connection error")
  assertEqualInt(H2.streamSendWindow(r5.conn, 3), 100, "the live stream's window is adjusted by the +99 delta")
  assertEqualInt(H2.streamSendWindow(r5.conn, 1), 2147483647, "the closed stream's window is left untouched")
}

test "WINDOW_UPDATE on a retained CLOSED stream is a true no-op (#6091)" {
  var conn = setupDefault()
  val r1 = H2.feed(conn, headersFrame(1, encodeBlock(requestHeaders()), false, true))
  val before = H2.streamSendWindow(r1.conn, 1)
  val r2 = H2.feed(r1.conn, rstFrame(1, H2Cancel))
  assertTrue(stateIs(H2.streamState(r2.conn, 1), "closed"), "stream 1 closed")
  val r3 = H2.feed(r2.conn, windowUpdateFrame(1, 100))
  assertFalse(hasWindowUpdated(r3.events, 1), "no H2WindowUpdated event for the dead stream")
  assertFalse(hasConnError(r3.events), "no connection error")
  assertFalse(H2.isFailed(r3.conn), "connection survives")
  assertEqualInt(H2.streamSendWindow(r3.conn, 1), before, "the closed stream's send window is not mutated")
}

// ===========================================================================
// SETTINGS validation.
// ===========================================================================
test "SETTINGS_ENABLE_PUSH other than 0/1 is a connection error" {
  var conn = setupDefault()
  val r = H2.feed(conn, settingsFrame(oneSetting(SettingsEnablePush, 2i64)))
  expectConnError(r.events, H2ProtocolError, "ENABLE_PUSH = 2")
}

test "SETTINGS_INITIAL_WINDOW_SIZE above 2^31-1 is a connection error" {
  var conn = setupDefault()
  val r = H2.feed(conn, settingsFrame(oneSetting(SettingsInitialWindowSize, 4294967295i64)))
  expectConnError(r.events, H2FlowControlError, "initial window above the max")
}

test "SETTINGS_MAX_FRAME_SIZE outside the allowed range is a connection error" {
  var conn = setupDefault()
  val r = H2.feed(conn, settingsFrame(oneSetting(SettingsMaxFrameSize, 100i64)))
  expectConnError(r.events, H2ProtocolError, "max frame size below 2^14")
}

// ===========================================================================
// PING / GOAWAY / PUSH_PROMISE.
// ===========================================================================
test "a PING is answered with a PING ACK carrying the same opaque data" {
  var conn = setupDefault()
  val payload = mkBytes(8, 7)
  val r = H2.feed(conn, pingFrame(payload, false))
  assertTrue(hasPingReceived(r.events), "ping received event")
  assertTrue(outHasPingAck(decodeFrames(r.outbound)), "PING ACK queued")
}

test "a received GOAWAY is surfaced and flags the connection" {
  var conn = setupDefault()
  val r = H2.feed(conn, goawayFrame(0, H2NoError))
  assertTrue(hasGoAwayReceived(r.events), "goaway received event")
  assertTrue(H2.goAwayWasReceived(r.conn), "goAwayWasReceived flag set")
  assertFalse(H2.isFailed(r.conn), "a peer GOAWAY does not poison the connection")
}

test "sendGoAway produces a parseable GOAWAY and sets the flag" {
  var conn = setupDefault()
  val bytes = H2.sendGoAway(conn, H2NoError)
  assertTrue(outHasGoAway(decodeFrames(bytes)), "GOAWAY frame emitted")
  assertTrue(H2.goAwayWasSent(conn), "goAwayWasSent flag set")
}

test "a server receiving PUSH_PROMISE is a connection error" {
  var conn = setupDefault()
  val block = encodeBlock(requestHeaders())
  val pp = serializeFrame(
    PushPromiseFrame(streamId = 1, promisedStreamId = 2, headerBlockFragment = block, endHeaders = true)
  )
  val r = H2.feed(conn, pp)
  expectConnError(r.events, H2ProtocolError, "server must not receive PUSH_PROMISE")
}

test "PRIORITY frames are accepted and ignored" {
  var conn = setupDefault()
  val prio = PriorityInfo(exclusive = false, streamDependency = 0, weight = 16)
  val r = H2.feed(conn, serializeFrame(PriorityFrame(streamId = 1, priority = prio)))
  assertFalse(H2.isFailed(r.conn), "PRIORITY does not fault the connection")
  assertFalse(hasConnError(r.events), "no error from PRIORITY")
}
