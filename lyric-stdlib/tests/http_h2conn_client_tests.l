//! stdlib/tests/http_h2conn_client_tests.l — behavioural corpus for the CLIENT
//! role of `Std.HttpEngine.H2Conn` (docs/72 slice 1, D797).
//!
//! Three kinds of test, all sans-IO and pure Lyric, so dotnet and the JVM must
//! agree:
//!
//!   - **Loopback.** A client connection and a server connection are wired
//!     back to back (`Link`), and bytes are pumped between them until both are
//!     quiet. Every flow is exercised in both directions through the real
//!     frame codec and HPACK: handshake, unary and streaming exchanges,
//!     Trailers-Only, 1xx, HEAD, flow control, CONTINUATION, the concurrent
//!     streams limit, GOAWAY, RST_STREAM, PING and stream-id exhaustion.
//!   - **Negative matrix.** Hand-built bytes from a misbehaving server are fed
//!     to a client; each case asserts the RFC 9113 error class (stream error
//!     with RST_STREAM, or connection error with GOAWAY) and the code, and
//!     where the connection survives, that a following exchange still works
//!     (the HPACK context stayed in sync, section 4.3).
//!   - **Pure predicates.** The request and response validators as tables.
//!
//! ## Client conformance table (RFC 9113)
//!
//! Each requirement that binds a client, the action it requires, and the test
//! that pins it. (h2spec is server-oriented and has no client mode, so this
//! table is the client's conformance record.)
//!
//!   - 3.4 server preface (first frame is a non-ACK SETTINGS): connection
//!     PROTOCOL_ERROR. "first server frame must be SETTINGS", "first server
//!     frame cannot be a SETTINGS ACK".
//!   - 3.4 client preface and SETTINGS: "client initial bytes", "handshake".
//!   - 4.2 frame larger than SETTINGS_MAX_FRAME_SIZE: connection
//!     FRAME_SIZE_ERROR. "oversized DATA frame".
//!   - 4.3 undecodable header block: connection COMPRESSION_ERROR.
//!     "undecodable response header block". Header blocks of refused or
//!     reset streams are still decoded: "late frames after a local reset".
//!   - 5.1 frames on idle streams are a connection PROTOCOL_ERROR: "HEADERS
//!     on an idle stream", "DATA on an idle stream", "RST_STREAM on an idle
//!     stream". Frames after END_STREAM: "DATA after the response ended",
//!     "HEADERS after the response ended". Frames after a local reset are
//!     discarded: "late frames after a local reset".
//!   - 5.1.1 stream ids: client ids are odd and increase; the peer cannot
//!     open streams: "stream ids are odd and increase", "even stream id
//!     HEADERS", "even stream id DATA", "stream id exhaustion".
//!   - 5.1.2 SETTINGS_MAX_CONCURRENT_STREAMS is never exceeded:
//!     "concurrent streams limit".
//!   - 6.2/6.10 HEADERS and CONTINUATION: "CONTINUATION response headers",
//!     "CONTINUATION request headers", "CONTINUATION without HEADERS",
//!     "non-CONTINUATION during a header block", "CONTINUATION flood".
//!   - 6.4 RST_STREAM: "client cancel", "server RST_STREAM REFUSED_STREAM",
//!     "RST_STREAM on an idle stream".
//!   - 6.5 SETTINGS validation: "invalid SETTINGS values from the server".
//!   - 6.6 PUSH_PROMISE with ENABLE_PUSH 0: connection PROTOCOL_ERROR.
//!     "PUSH_PROMISE".
//!   - 6.7 PING: "PING both ways".
//!   - 6.8 GOAWAY: last-stream-id may not rise, streams above it are
//!     unprocessed, no new streams: "GOAWAY unprocessed streams", "GOAWAY
//!     last-stream-id cannot rise", "client GOAWAY".
//!   - 6.9 flow control: "response body flow control", "SETTINGS initial
//!     window change", "stream window overrun", "connection window overrun".
//!   - 8.1 message framing: DATA before the final HEADERS, trailers without
//!     END_STREAM, 1xx with END_STREAM, content-length against DATA: the
//!     "DATA before final HEADERS", "trailers without END_STREAM", "1xx with
//!     END_STREAM", "content-length" tests.
//!   - 8.2 field validation: "uppercase field name", "invalid field value",
//!     "connection-specific response field".
//!   - 8.3.2 response pseudo-headers: "response without :status" and the
//!     malformed-response table.
//!   - 8.7 retry-safe refusals: REFUSED_STREAM and GOAWAY-unprocessed are
//!     distinguishable from other failures: "server RST_STREAM
//!     REFUSED_STREAM", "GOAWAY unprocessed streams".
@test_module
package Std.HttpEngine.H2ConnClient.Tests

import Std.Core
import Std.Collections
import Std.HttpEngine
import Std.HttpEngine.H2Frame
import Std.HttpEngine.Hpack
import Std.HttpEngine.H2Conn as H2
import Std.Testing

// ---------------------------------------------------------------------------
// Byte, header and frame helpers.
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

func bigString(n: in Int): String {
  var acc = "x"
  while acc.length < n {
    acc = acc + acc
  }
  acc.substring(0, n)
}

func grpcRequest(path: in String): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":method", "POST"))
  h.add(hf(":scheme", "http"))
  h.add(hf(":path", path))
  h.add(hf(":authority", "localhost:50051"))
  h.add(hf("content-type", "application/grpc"))
  h.add(hf("te", "trailers"))
  h
}

func requestWithMethod(method: in String): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":method", method))
  h.add(hf(":scheme", "https"))
  h.add(hf(":path", "/index"))
  h.add(hf(":authority", "example.com"))
  h
}

func okResponse(): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":status", "200"))
  h.add(hf("content-type", "application/grpc"))
  h
}

func statusOnly(status: in String): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":status", status))
  h
}

func grpcTrailers(code: in String): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf("grpc-status", code))
  h.add(hf("grpc-message", "done"))
  h
}

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

func encodeBlockWith(enc: in HpackEncoder, headers: in List[HeaderField]): slice[Byte] {
  match encodeHeaderList(enc, headers) {
    case Ok(b) -> {
      val block: slice[Byte] = b
      block
    }
    case Err(_) -> emptyBytesT()
  }
}

func freshBlock(headers: in List[HeaderField]): slice[Byte] {
  var enc = newEncoder(4096, false)
  encodeBlockWith(enc, headers)
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
  serializeFrame(DataFrame(streamId = streamId, data = data, endStream = endStream, wireLength = data.length))
}

func rstFrame(streamId: in Int, code: in H2ErrorCode): slice[Byte] {
  serializeFrame(RstStreamFrame(streamId = streamId, errorCode = code))
}

func goawayFrame(lastStreamId: in Int, code: in H2ErrorCode): slice[Byte] {
  serializeFrame(GoAwayFrame(lastStreamId = lastStreamId, errorCode = code, debugData = emptyBytesT()))
}

func pingFrame(data: in slice[Byte], ack: in Bool): slice[Byte] {
  serializeFrame(PingFrame(opaqueData = data, ack = ack))
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

func windowUpdateFrame(streamId: in Int, increment: in Int): slice[Byte] {
  serializeFrame(WindowUpdateFrame(streamId = streamId, windowSizeIncrement = increment))
}

func framesOf(bytes: in slice[Byte]): List[H2Frame] {
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

func hasGoAwayFrame(frames: in List[H2Frame], code: in H2ErrorCode): Bool {
  var found = false
  var i = 0
  while i < frames.count {
    match frames[i] {
      case GoAwayFrame(_, c, _) -> {
        if errorCodeToLong(c) == errorCodeToLong(code) {
          found = true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func goAwayLastId(frames: in List[H2Frame]): Int {
  var last = -1
  var i = 0
  while i < frames.count {
    match frames[i] {
      case GoAwayFrame(l, _, _) -> {
        last = l
      }
      case _ -> ()
    }
    i = i + 1
  }
  last
}

func hasRstFrame(frames: in List[H2Frame], streamId: in Int, code: in H2ErrorCode): Bool {
  var found = false
  var i = 0
  while i < frames.count {
    match frames[i] {
      case RstStreamFrame(sid, c) -> {
        if sid == streamId and errorCodeToLong(c) == errorCodeToLong(code) {
          found = true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func appendAll(dst: in List[Byte], src: in slice[Byte]): Unit {
  var i = 0
  while i < src.length {
    dst.add(src[i])
    i = i + 1
  }
}

func newBytesList(): List[Byte] {
  val l: List[Byte] = newList()
  l
}

func newEventList(): List[H2.H2Event] {
  val l: List[H2.H2Event] = newList()
  l
}

// ---------------------------------------------------------------------------
// Event inspection.
// ---------------------------------------------------------------------------
func kindOf(ev: in H2.H2Event): String {
  match ev {
    case H2NeedMore -> "need"
    case H2SettingsReceived(_) -> "settings"
    case H2SettingsAcknowledged -> "settingsAck"
    case H2RequestHeaders(_, _, _) -> "reqH"
    case H2RequestData(_, _, _, _) -> "reqD"
    case H2PingReceived(_) -> "ping"
    case H2PingAcknowledged(_) -> "pong"
    case H2WindowUpdated(_) -> "win"
    case H2PeerReset(_, _) -> "rst"
    case H2GoAwayReceived(_, _) -> "goaway"
    case H2InformationalHeaders(_, _, _) -> "info"
    case H2ResponseHeaders(_, _, _, _) -> "respH"
    case H2ResponseData(_, _, _, _) -> "respD"
    case H2ResponseTrailers(_, _) -> "respT"
    case H2StreamUnprocessed(_) -> "unprocessed"
    case H2ConnError(_, _) -> "connErr"
    case H2StreamErr(_, _, _) -> "streamErr"
  }
}

/// The event kinds in order, comma separated, ignoring `H2NeedMore`, the
/// SETTINGS and WINDOW_UPDATE bookkeeping events.
func kinds(events: in List[H2.H2Event]): String {
  var acc = ""
  var i = 0
  while i < events.count {
    val k = kindOf(events[i])
    if k != "need" and k != "settings" and k != "settingsAck" and k != "win" {
      if acc.length > 0 {
        acc = acc + ","
      }
      acc = acc + k
    }
    i = i + 1
  }
  acc
}

func countKind(events: in List[H2.H2Event], kind: in String): Int {
  var n = 0
  var i = 0
  while i < events.count {
    if kindOf(events[i]) == kind {
      n = n + 1
    }
    i = i + 1
  }
  n
}

func connErrCode(events: in List[H2.H2Event]): Long {
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

func connErrMessage(events: in List[H2.H2Event]): String {
  var msg = ""
  var i = 0
  while i < events.count {
    match events[i] {
      case H2ConnError(_, m) -> {
        msg = m
      }
      case _ -> ()
    }
    i = i + 1
  }
  msg
}

func streamErrCode(events: in List[H2.H2Event], streamId: in Int): Long {
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

func responseStatus(events: in List[H2.H2Event], streamId: in Int): Int {
  var status = -1
  var i = 0
  while i < events.count {
    match events[i] {
      case H2ResponseHeaders(sid, st, _, _) -> {
        if sid == streamId {
          status = st
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  status
}

func responseHeadersOf(events: in List[H2.H2Event], streamId: in Int): List[HeaderField] {
  val none: List[HeaderField] = newList()
  var found = none
  var i = 0
  while i < events.count {
    match events[i] {
      case H2ResponseHeaders(sid, _, hs, _) -> {
        if sid == streamId {
          found = hs
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func trailersOf(events: in List[H2.H2Event], streamId: in Int): List[HeaderField] {
  val none: List[HeaderField] = newList()
  var found = none
  var i = 0
  while i < events.count {
    match events[i] {
      case H2ResponseTrailers(sid, hs) -> {
        if sid == streamId {
          found = hs
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

/// Total response body bytes carried by `H2ResponseData` events for a stream.
func responseBytes(events: in List[H2.H2Event], streamId: in Int): Int {
  var n = 0
  var i = 0
  while i < events.count {
    match events[i] {
      case H2ResponseData(sid, d, _, _) -> {
        if sid == streamId {
          n = n + d.length
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  n
}

/// Total on-wire length (the replenish amount) of `H2ResponseData` events.
func responseWireBytes(events: in List[H2.H2Event], streamId: in Int): Int {
  var n = 0
  var i = 0
  while i < events.count {
    match events[i] {
      case H2ResponseData(sid, _, _, w) -> {
        if sid == streamId {
          n = n + w
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  n
}

func requestBytes(events: in List[H2.H2Event], streamId: in Int): Int {
  var n = 0
  var i = 0
  while i < events.count {
    match events[i] {
      case H2RequestData(sid, d, _, _) -> {
        if sid == streamId {
          n = n + d.length
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  n
}

func peerResetCode(events: in List[H2.H2Event], streamId: in Int): Long {
  var code = -1i64
  var i = 0
  while i < events.count {
    match events[i] {
      case H2PeerReset(sid, c) -> {
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

// ---------------------------------------------------------------------------
// The loopback link: a client and a server connection wired back to back.
// ---------------------------------------------------------------------------
ref record Link {
  client: H2.H2Connection
  server: H2.H2Connection
  var cEv: List[H2.H2Event]
  var sEv: List[H2.H2Event]
  var toServer: List[Byte]
  var toClient: List[Byte]
}

func addEvents(dst: in List[H2.H2Event], src: in List[H2.H2Event]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

/// Pump bytes between the two ends until both are quiet.
func settle(link: in Link): Unit {
  var guard = 0
  while (link.toServer.count > 0 or link.toClient.count > 0) and guard < 200 {
    if link.toServer.count > 0 {
      val b = link.toServer.toArray()
      link.toServer = newBytesList()
      if not H2.isFailed(link.server) {
        val r = H2.feed(link.server, b)
        addEvents(link.sEv, r.events)
        appendAll(link.toClient, r.outbound)
      }
    }
    if link.toClient.count > 0 {
      val b = link.toClient.toArray()
      link.toClient = newBytesList()
      if not H2.isFailed(link.client) {
        val r = H2.feed(link.client, b)
        addEvents(link.cEv, r.events)
        appendAll(link.toServer, r.outbound)
      }
    }
    guard = guard + 1
  }
}

func clearEvents(link: in Link): Unit {
  link.cEv = newEventList()
  link.sEv = newEventList()
}

func newLinkWith(cs: in H2.H2Settings, ss: in H2.H2Settings): Link {
  val c = H2.newClientConnection(cs)
  val s = H2.newServerConnection(ss)
  val link = Link(
    client = c,
    server = s,
    cEv = newEventList(),
    sEv = newEventList(),
    toServer = newBytesList(),
    toClient = newBytesList()
  )
  appendAll(link.toServer, H2.clientInitialBytes(c))
  appendAll(link.toClient, H2.serverInitialFrame(s))
  settle(link)
  link
}

func newLink(): Link {
  newLinkWith(H2.h2DefaultClientSettings(), H2.h2DefaultServerSettings())
}

/// Open a request on the client and queue its bytes for the server.
func clientOpen(link: in Link, headers: in List[HeaderField], endStream: in Bool): Int {
  match H2.openStream(link.client, headers, endStream) {
    case Ok(r) -> {
      val res: H2.H2OpenResult = r
      appendAll(link.toServer, res.bytes)
      res.streamId
    }
    case Err(_) -> {
      assertTrue(false, "openStream unexpectedly refused")
      0 - 1
    }
  }
}

func openKind(r: in Result[H2.H2OpenResult, H2.H2OpenError]): String {
  match r {
    case Ok(_) -> "ok"
    case Err(e) -> match e {
      case OpenConnectionFailed -> "failed"
      case OpenConnectionDraining -> "draining"
      case OpenStreamLimitReached(_, _) -> "limit"
      case OpenStreamIdsExhausted -> "exhausted"
      case OpenHeaderListTooLarge(_, _) -> "headerList"
      case OpenHeaderEncodingFailed(_) -> "encoding"
    }
  }
}

func clientSend(link: in Link, streamId: in Int, data: in slice[Byte], endStream: in Bool): Unit {
  match H2.sendData(link.client, streamId, data, endStream) {
    case Ok(b) -> appendAll(link.toServer, b)
    case Err(_) -> assertTrue(false, "client sendData refused")
  }
}

func serverHeaders(link: in Link, streamId: in Int, headers: in List[HeaderField], endStream: in Bool): Unit {
  match H2.encodeResponseHeaders(link.server, streamId, headers, endStream) {
    case Ok(b) -> appendAll(link.toClient, b)
    case Err(_) -> assertTrue(false, "server encodeResponseHeaders refused")
  }
}

func serverData(link: in Link, streamId: in Int, data: in slice[Byte], endStream: in Bool): Unit {
  match H2.sendData(link.server, streamId, data, endStream) {
    case Ok(b) -> appendAll(link.toClient, b)
    case Err(_) -> assertTrue(false, "server sendData refused")
  }
}

func serverTrailers(link: in Link, streamId: in Int, trailers: in List[HeaderField]): Unit {
  match H2.encodeResponseTrailers(link.server, streamId, trailers) {
    case Ok(b) -> appendAll(link.toClient, b)
    case Err(_) -> assertTrue(false, "server encodeResponseTrailers refused")
  }
}

/// A complete unary exchange: request body in, 200 + body + trailers out.
/// Returns the stream id; leaves the events in the link for inspection.
func unaryCall(link: in Link, bodyLen: in Int): Int {
  val sid = clientOpen(link, grpcRequest("/test.Echo/Say"), false)
  clientSend(link, sid, mkBytes(bodyLen, 7), true)
  settle(link)
  serverHeaders(link, sid, okResponse(), false)
  serverData(link, sid, mkBytes(bodyLen, 9), false)
  serverTrailers(link, sid, grpcTrailers("0"))
  settle(link)
  sid
}

/// Feed raw bytes (from a hand-made misbehaving server) to the client side of
/// a link and return the result.
func feedClient(link: in Link, bytes: in slice[Byte]): H2.H2FeedResult {
  H2.feed(link.client, bytes)
}

/// A link whose client has one request open (stream 1) with the whole request
/// already sent (half-closed local), the common starting point for a
/// misbehaving-server case.
func linkWithOneRequest(): Link {
  val link = newLink()
  val sid = clientOpen(link, grpcRequest("/svc/Method"), true)
  settle(link)
  assertEqualInt(sid, 1, "first stream id")
  clearEvents(link)
  link
}

/// After a stream error the connection must still carry a clean exchange: the
/// HPACK contexts stayed in sync and no state was poisoned.
func assertStillUsable(link: in Link, label: in String): Unit {
  assertFalse(H2.isFailed(link.client), label + ": client connection healthy")
  val sid = clientOpen(link, grpcRequest("/svc/After"), true)
  settle(link)
  serverHeaders(link, sid, okResponse(), false)
  serverData(link, sid, mkBytes(3, 1), false)
  serverTrailers(link, sid, grpcTrailers("0"))
  settle(link)
  assertEqualInt(responseStatus(link.cEv, sid), 200, label + ": a later response is accepted")
  assertEqualInt(responseBytes(link.cEv, sid), 3, label + ": a later response body arrives")
}

// ===========================================================================
// Construction and handshake.
// ===========================================================================
test "client constructor: role, first stream id, defaults" {
  val c = H2.newClientConnection(H2.h2DefaultClientSettings())
  assertTrue(H2.isClientConnection(c), "client connection")
  assertFalse(H2.isServerConnection(c), "not a server connection")
  assertEqualLong(H2.nextLocalStreamId(c), 1i64, "first stream id is 1")
  assertEqualInt(H2.lastPeerStreamId(c), 0, "a client's peer opens no streams")
  assertEqualInt(H2.activeStreamCount(c), 0, "no streams")
  assertFalse(H2.isFailed(c), "healthy")
  val s = H2.newServerConnection(H2.h2DefaultServerSettings())
  assertTrue(H2.isServerConnection(s), "server connection")
  assertFalse(H2.isClientConnection(s), "a server is not a client")
  assertTrue(H2.isValidLocalSettings(H2.h2DefaultClientSettings()), "default client settings are valid")
  assertEqualInt(H2.h2DefaultClientSettings().enablePush, 0, "a client advertises ENABLE_PUSH = 0")
}

test "client initial bytes: the preface followed by SETTINGS" {
  val c = H2.newClientConnection(H2.h2DefaultClientSettings())
  val bytes = H2.clientInitialBytes(c)
  val preface = connectionPreface()
  assertTrue(bytes.length > preface.length, "preface plus a SETTINGS frame")
  var i = 0
  var same = true
  while i < preface.length {
    if bytes[i] != preface[i] {
      same = false
    }
    i = i + 1
  }
  assertTrue(same, "starts with the 24-octet connection preface")
  val rest = framesOf(bytes.slice(preface.length, bytes.length))
  assertEqualInt(rest.count, 1, "exactly one frame after the preface")
  match rest[0] {
    case SettingsFrame(_, ack) -> assertFalse(ack, "a non-ACK SETTINGS frame")
    case _ -> assertTrue(false, "the frame after the preface is SETTINGS")
  }
}

test "client constructor refuses settings that enable push" {
  val bad = customSettings(4096, 100, 65535, 16384, 32768)
  bad.enablePush = 1
  assertPanics("enablePush = 1", { -> val ignored = H2.newClientConnection(bad) })
}

test "handshake: both ends exchange and acknowledge SETTINGS" {
  val link = newLink()
  assertTrue(countKind(link.cEv, "settings") >= 0, "client handled the server SETTINGS")
  assertFalse(H2.isFailed(link.client), "client healthy")
  assertFalse(H2.isFailed(link.server), "server healthy")
  assertEqualInt(H2.peerMaxConcurrentStreams(link.client), 128, "the server's MAX_CONCURRENT_STREAMS is applied")
  assertEqualInt(H2.peerMaxFrameSize(link.client), 16384, "the server's max frame size is applied")
  assertEqualInt(
    H2.peerMaxConcurrentStreams(H2.newClientConnection(H2.h2DefaultClientSettings())),
    2147483647,
    "unlimited until the server SETTINGS arrive"
  )
  val c2 = H2.newClientConnection(H2.h2DefaultClientSettings())
  val s2 = H2.newServerConnection(H2.h2DefaultServerSettings())
  val rs = H2.feed(s2, H2.clientInitialBytes(c2))
  assertEqualInt(countKind(rs.events, "settings"), 1, "the server saw the client SETTINGS")
  val rc = H2.feed(c2, H2.serverInitialFrame(s2).concat(rs.outbound))
  assertEqualInt(countKind(rc.events, "settings"), 1, "the client saw the server SETTINGS")
  assertEqualInt(countKind(rc.events, "settingsAck"), 1, "the client saw its SETTINGS acknowledged")
}

test "client and server API are role gated" {
  val c = H2.newClientConnection(H2.h2DefaultClientSettings())
  val s = H2.newServerConnection(H2.h2DefaultServerSettings())
  assertPanics("serverInitialFrame on a client", { -> val ignored = H2.serverInitialFrame(c) })
  assertPanics("clientInitialBytes on a server", { -> val ignored = H2.clientInitialBytes(s) })
  assertPanics("openStream on a server", { -> val ignored = H2.openStream(s, grpcRequest("/a/b"), true) })
}

test "first server frame must be SETTINGS" {
  val link = newLink()
  val fresh = H2.newClientConnection(H2.h2DefaultClientSettings())
  val r = H2.feed(fresh, pingFrame(mkBytes(8, 1), false))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2ProtocolError), "PROTOCOL_ERROR")
  assertTrue(hasGoAwayFrame(framesOf(r.outbound), H2ProtocolError), "GOAWAY queued")
  assertTrue(H2.isFailed(fresh), "connection poisoned")
  assertFalse(H2.isFailed(link.client), "an unrelated link is unaffected")
}

test "first server frame cannot be a SETTINGS ACK" {
  val fresh = H2.newClientConnection(H2.h2DefaultClientSettings())
  val r = H2.feed(fresh, settingsAckFrame())
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2ProtocolError), "PROTOCOL_ERROR")
}

// ===========================================================================
// Request / response exchanges.
// ===========================================================================
test "unary round trip: request, then headers, data, trailers" {
  val link = newLink()
  val sid = clientOpen(link, grpcRequest("/test.Echo/Say"), false)
  assertEqualInt(sid, 1, "first stream id")
  clientSend(link, sid, mkBytes(10, 3), true)
  settle(link)
  assertEqual(kinds(link.sEv), "reqH,reqD", "server saw the request headers and body")
  assertEqualInt(requestBytes(link.sEv, sid), 10, "server saw the whole request body")
  assertTrue(H2.streamState(link.client, sid) == H2.H2SHalfClosedLocal, "client half-closed after the request")
  clearEvents(link)
  serverHeaders(link, sid, okResponse(), false)
  serverData(link, sid, mkBytes(5, 4), false)
  serverTrailers(link, sid, grpcTrailers("0"))
  settle(link)
  assertEqual(kinds(link.cEv), "respH,respD,respT", "client saw headers, data, trailers in order")
  assertEqualInt(responseStatus(link.cEv, sid), 200, "status")
  assertEqual(headerValueIn(responseHeadersOf(link.cEv, sid), "content-type"), "application/grpc", "response header")
  assertEqualInt(responseBytes(link.cEv, sid), 5, "body")
  assertEqual(headerValueIn(trailersOf(link.cEv, sid), "grpc-status"), "0", "grpc-status trailer")
  assertEqual(headerValueIn(trailersOf(link.cEv, sid), "grpc-message"), "done", "grpc-message trailer")
  assertTrue(H2.streamState(link.client, sid) == H2.H2SClosed, "client stream closed")
  assertEqualInt(H2.activeStreamCount(link.client), 0, "no active streams")
}

test "stream ids are odd and increase" {
  val link = newLink()
  val a = unaryCall(link, 4)
  val b = unaryCall(link, 4)
  val c = unaryCall(link, 4)
  assertEqualInt(a, 1, "first")
  assertEqualInt(b, 3, "second")
  assertEqualInt(c, 5, "third")
  assertEqualLong(H2.nextLocalStreamId(link.client), 7i64, "next id")
  assertEqualInt(countKind(link.sEv, "reqH"), 3, "the server accepted all three streams")
  assertFalse(H2.isFailed(link.server), "server healthy")
  assertEqualInt(H2.lastPeerStreamId(link.server), 5, "server high-water mark")
}

test "Trailers-Only response: HEADERS with END_STREAM" {
  val link = newLink()
  val sid = clientOpen(link, grpcRequest("/test.Echo/Say"), true)
  settle(link)
  clearEvents(link)
  val h: List[HeaderField] = newList()
  h.add(hf(":status", "200"))
  h.add(hf("content-type", "application/grpc"))
  h.add(hf("grpc-status", "12"))
  h.add(hf("grpc-message", "unimplemented"))
  serverHeaders(link, sid, h, true)
  settle(link)
  assertEqual(kinds(link.cEv), "respH", "a single response headers event")
  assertEqual(headerValueIn(responseHeadersOf(link.cEv, sid), "grpc-status"), "12", "status is in the headers")
  assertTrue(H2.streamState(link.client, sid) == H2.H2SClosed, "stream closed")
}

test "1xx informational headers precede the final response" {
  val link = newLink()
  val sid = clientOpen(link, requestWithMethod("GET"), true)
  settle(link)
  clearEvents(link)
  serverHeaders(link, sid, statusOnly("100"), false)
  serverHeaders(link, sid, statusOnly("103"), false)
  serverHeaders(link, sid, okResponse(), false)
  serverData(link, sid, mkBytes(2, 1), true)
  settle(link)
  assertEqual(kinds(link.cEv), "info,info,respH,respD", "two 1xx then the final response")
  assertEqualInt(responseStatus(link.cEv, sid), 200, "final status")
  assertTrue(H2.streamState(link.client, sid) == H2.H2SClosed, "stream closed by END_STREAM on DATA")
}

test "request without a body: END_STREAM on HEADERS" {
  val link = newLink()
  val sid = clientOpen(link, requestWithMethod("GET"), true)
  assertTrue(H2.streamState(link.client, sid) == H2.H2SHalfClosedLocal, "half-closed local at once")
  settle(link)
  assertEqual(kinds(link.sEv), "reqH", "server saw the headers")
  clearEvents(link)
  serverHeaders(link, sid, okResponse(), true)
  settle(link)
  assertEqual(kinds(link.cEv), "respH", "response")
  assertTrue(H2.streamState(link.client, sid) == H2.H2SClosed, "closed")
}

test "request trailers close the client side" {
  val link = newLink()
  val sid = clientOpen(link, grpcRequest("/svc/M"), false)
  clientSend(link, sid, mkBytes(3, 1), false)
  val t: List[HeaderField] = newList()
  t.add(hf("x-checksum", "abc"))
  match H2.encodeRequestTrailers(link.client, sid, t) {
    case Ok(b) -> appendAll(link.toServer, b)
    case Err(_) -> assertTrue(false, "encodeRequestTrailers refused")
  }
  settle(link)
  assertEqual(kinds(link.sEv), "reqH,reqD,reqH", "server saw headers, data, then the trailer block")
  assertTrue(H2.streamState(link.client, sid) == H2.H2SHalfClosedLocal, "client half-closed after trailers")
  val bad: List[HeaderField] = newList()
  bad.add(hf(":path", "/x"))
  assertPanics(
    "pseudo-header in request trailers",
    { -> val ignored = H2.encodeRequestTrailers(link.client, sid, bad) }
  )
}

test "HEAD response: content-length without a body" {
  val link = newLink()
  val sid = clientOpen(link, requestWithMethod("HEAD"), true)
  settle(link)
  clearEvents(link)
  val h: List[HeaderField] = newList()
  h.add(hf(":status", "200"))
  h.add(hf("content-length", "1000"))
  serverHeaders(link, sid, h, true)
  settle(link)
  assertEqual(kinds(link.cEv), "respH", "accepted: HEAD responses carry no body")
  assertFalse(H2.isFailed(link.client), "healthy")
}

test "HEAD response with DATA is a stream error" {
  val link = newLink()
  val sid = clientOpen(link, requestWithMethod("HEAD"), true)
  settle(link)
  clearEvents(link)
  val h: List[HeaderField] = newList()
  h.add(hf(":status", "200"))
  h.add(hf("content-length", "5"))
  serverHeaders(link, sid, h, false)
  serverData(link, sid, mkBytes(5, 1), true)
  settle(link)
  assertEqualLong(streamErrCode(link.cEv, sid), errorCodeToLong(H2ProtocolError), "DATA on a HEAD response")
  assertFalse(H2.isFailed(link.client), "connection survives")
}

test "204 response with content-length carries no body" {
  val link = newLink()
  val sid = clientOpen(link, requestWithMethod("GET"), true)
  settle(link)
  clearEvents(link)
  val h: List[HeaderField] = newList()
  h.add(hf(":status", "204"))
  h.add(hf("content-length", "9"))
  serverHeaders(link, sid, h, true)
  settle(link)
  assertEqual(kinds(link.cEv), "respH", "204 accepted")
}

// ===========================================================================
// Flow control.
// ===========================================================================
test "response body flow control: windows are replenished by wire length" {
  val link = newLink()
  val sid = clientOpen(link, grpcRequest("/svc/Stream"), true)
  settle(link)
  clearEvents(link)
  serverHeaders(link, sid, okResponse(), false)
  settle(link)
  val total = 300000
  var sent = 0
  var received = 0
  var rounds = 0
  while received < total and rounds < 200 {
    var progressed = true
    while sent < total and progressed {
      val want = minOf(minOf(16384, total - sent), H2.maxSendableOnStream(link.server, sid))
      if want <= 0 {
        progressed = false
      } else {
        serverData(link, sid, mkBytes(want, 5), sent + want == total)
        sent = sent + want
      }
    }
    settle(link)
    val got = responseWireBytes(link.cEv, sid)
    if got > received {
      val credit = got - received
      received = got
      appendAll(link.toServer, H2.grantConnectionWindow(link.client, credit))
      if sent < total {
        appendAll(link.toServer, H2.grantStreamWindow(link.client, sid, credit))
      }
      settle(link)
    }
    rounds = rounds + 1
  }
  assertEqualInt(sent, total, "the server sent everything")
  assertEqualInt(responseBytes(link.cEv, sid), total, "the client received everything")
  assertFalse(H2.isFailed(link.client), "client healthy")
  assertFalse(H2.isFailed(link.server), "server healthy")
}

func minOf(a: in Int, b: in Int): Int {
  if a < b {
    a
  } else {
    b
  }
}

test "client request body is bounded by the server's window and resumed by WINDOW_UPDATE" {
  val link = newLinkWith(H2.h2DefaultClientSettings(), customSettings(4096, 128, 1000, 16384, 32768))
  val sid = clientOpen(link, grpcRequest("/svc/Upload"), false)
  settle(link)
  assertEqualInt(H2.maxSendableOnStream(link.client, sid), 1000, "the server's 1000-octet window applies")
  match H2.sendData(link.client, sid, mkBytes(1500, 1), false) {
    case Ok(_) -> assertTrue(false, "should exceed the window")
    case Err(e) -> match e {
      case WindowExceeded(avail, req) -> {
        assertEqualInt(avail, 1000, "available")
        assertEqualInt(req, 1500, "requested")
      }
      case StreamNotWritable(_) -> assertTrue(false, "stream is writable")
    }
  }
  clientSend(link, sid, mkBytes(1000, 1), false)
  settle(link)
  assertEqualInt(requestBytes(link.sEv, sid), 1000, "server received the first window")
  assertEqualInt(H2.maxSendableOnStream(link.client, sid), 0, "window exhausted")
  appendAll(link.toClient, H2.grantStreamWindow(link.server, sid, 1000))
  appendAll(link.toClient, H2.grantConnectionWindow(link.server, 1000))
  settle(link)
  assertTrue(countKind(link.cEv, "win") >= 0, "window updates processed")
  assertEqualInt(H2.maxSendableOnStream(link.client, sid), 1000, "replenished")
}

test "SETTINGS initial window change adjusts open client streams" {
  val link = newLink()
  val fresh = H2.newClientConnection(H2.h2DefaultClientSettings())
  match H2.openStream(fresh, grpcRequest("/svc/M"), false) {
    case Ok(r) -> {
      val res: H2.H2OpenResult = r
      assertEqualInt(H2.streamSendWindow(fresh, res.streamId), 65535, "starts at the RFC default before SETTINGS arrive")
      val params = oneSetting(SettingsInitialWindowSize, 100000i64)
      val rr = H2.feed(fresh, settingsFrame(params))
      assertEqualInt(countKind(rr.events, "settings"), 1, "the SETTINGS were applied")
      assertEqualInt(H2.streamSendWindow(fresh, res.streamId), 100000, "corrected to the server's initial window")
      val smaller = oneSetting(SettingsInitialWindowSize, 1000i64)
      val r3 = H2.feed(fresh, settingsFrame(smaller))
      assertFalse(H2.isFailed(r3.conn), "a decrease is legal")
      assertEqualInt(H2.streamSendWindow(fresh, res.streamId), 1000, "decreased")
    }
    case Err(_) -> assertTrue(false, "openStream refused")
  }
  assertFalse(H2.isFailed(link.client), "link unaffected")
}

test "connection receive window can be widened after the handshake" {
  val link = newLink()
  appendAll(link.toServer, H2.grantConnectionWindow(link.client, 1000000))
  settle(link)
  assertEqualInt(H2.connectionReceiveWindow(link.client), 1065535, "client window grew")
  assertEqualInt(H2.connectionSendWindow(link.server), 1065535, "server send window grew")
}

// ===========================================================================
// Header blocks: CONTINUATION and HPACK state.
// ===========================================================================
test "CONTINUATION response headers (server to client)" {
  val link = newLinkWith(customSettings(4096, 100, 1048576, 16384, 200000), H2.h2DefaultServerSettings())
  val sid = clientOpen(link, grpcRequest("/svc/M"), true)
  settle(link)
  clearEvents(link)
  val h = okResponse()
  h.add(hf("x-big", bigString(40000)))
  serverHeaders(link, sid, h, false)
  serverTrailers(link, sid, grpcTrailers("0"))
  settle(link)
  assertEqual(kinds(link.cEv), "respH,respT", "assembled across CONTINUATION frames")
  assertEqualInt(headerValueIn(responseHeadersOf(link.cEv, sid), "x-big").length, 40000, "value intact")
}

test "CONTINUATION request headers (client to server)" {
  val link = newLinkWith(H2.h2DefaultClientSettings(), customSettings(4096, 128, 65535, 16384, 200000))
  val h = grpcRequest("/svc/M")
  h.add(hf("x-big", bigString(40000)))
  val sid = clientOpen(link, h, true)
  settle(link)
  assertEqual(kinds(link.sEv), "reqH", "the server reassembled the request headers")
  assertFalse(H2.isFailed(link.server), "server healthy")
  assertEqualInt(sid, 1, "stream id")
}

test "HPACK dynamic table stays in sync across many streams and a table-size change" {
  val link = newLinkWith(H2.h2DefaultClientSettings(), customSettings(0, 128, 65535, 16384, 32768))
  var i = 0
  while i < 6 {
    val h = grpcRequest("/svc/Repeat")
    h.add(hf("x-trace", "trace-value-that-repeats"))
    val sid = clientOpen(link, h, true)
    settle(link)
    val r = okResponse()
    r.add(hf("x-server", "server-value-that-repeats"))
    serverHeaders(link, sid, r, false)
    serverTrailers(link, sid, grpcTrailers("0"))
    settle(link)
    assertEqual(
      headerValueIn(responseHeadersOf(link.cEv, sid), "x-server"),
      "server-value-that-repeats",
      "response header"
    )
    i = i + 1
  }
  assertEqualInt(countKind(link.sEv, "reqH"), 6, "six requests decoded by the server")
  assertFalse(H2.isFailed(link.server), "server healthy")
  assertFalse(H2.isFailed(link.client), "client healthy")
  val link2 = newLink()
  var j = 0
  while j < 6 {
    val h = grpcRequest("/svc/Repeat")
    h.add(hf("x-trace", "trace-value-that-repeats"))
    val sid = clientOpen(link2, h, true)
    settle(link2)
    serverHeaders(link2, sid, okResponse(), true)
    settle(link2)
    j = j + 1
  }
  assertEqualInt(countKind(link2.cEv, "respH"), 6, "dynamic table path: six responses")
}

// ===========================================================================
// Concurrency limit and stream ids.
// ===========================================================================
test "concurrent streams limit" {
  val link = newLinkWith(H2.h2DefaultClientSettings(), customSettings(4096, 2, 65535, 16384, 32768))
  assertEqualInt(H2.peerMaxConcurrentStreams(link.client), 2, "limit is the server's")
  val a = clientOpen(link, grpcRequest("/svc/A"), false)
  val b = clientOpen(link, grpcRequest("/svc/B"), false)
  settle(link)
  assertEqual(openKind(H2.openStream(link.client, grpcRequest("/svc/C"), false)), "limit", "third stream refused")
  assertEqualInt(H2.activeStreamCount(link.client), 2, "the refusal opened nothing")
  assertEqualLong(H2.nextLocalStreamId(link.client), 5i64, "and burned no id")
  match H2.openStream(link.client, grpcRequest("/svc/C"), false) {
    case Err(e) -> match e {
      case OpenStreamLimitReached(active, limit) -> {
        assertEqualInt(active, 2, "active")
        assertEqualInt(limit, 2, "limit")
      }
      case _ -> assertTrue(false, "wrong refusal")
    }
    case Ok(_) -> assertTrue(false, "should refuse")
  }
  clientSend(link, a, mkBytes(1, 1), true)
  settle(link)
  serverHeaders(link, a, okResponse(), true)
  settle(link)
  assertEqualInt(H2.activeStreamCount(link.client), 1, "stream a finished")
  val c = clientOpen(link, grpcRequest("/svc/C"), false)
  assertEqualInt(c, 5, "the next stream takes the next id once a slot frees")
  assertEqualInt(b, 3, "second stream id")
}

test "stream id exhaustion" {
  val c = H2.newClientConnectionAt(H2.h2DefaultClientSettings(), 2147483647)
  assertEqualLong(H2.nextLocalStreamId(c), 2147483647i64, "starts at the last id")
  assertEqual(openKind(H2.openStream(c, grpcRequest("/a/b"), true)), "ok", "the last id is usable")
  assertEqual(openKind(H2.openStream(c, grpcRequest("/a/b"), true)), "exhausted", "then the id space is exhausted")
  val c2 = H2.newClientConnectionAt(H2.h2DefaultClientSettings(), 2147483645)
  assertEqual(openKind(H2.openStream(c2, grpcRequest("/a/b"), true)), "ok", "second to last")
  assertEqual(openKind(H2.openStream(c2, grpcRequest("/a/b"), true)), "ok", "last")
  assertEqual(openKind(H2.openStream(c2, grpcRequest("/a/b"), true)), "exhausted", "exhausted")
  assertPanics("even first stream id", { -> val ignored = H2.newClientConnectionAt(H2.h2DefaultClientSettings(), 2) })
}

test "header list larger than the server's limit is refused before an id is used" {
  val link = newLinkWith(H2.h2DefaultClientSettings(), customSettings(4096, 128, 65535, 16384, 100))
  val h = grpcRequest("/svc/M")
  h.add(hf("x-big", bigString(500)))
  assertEqual(openKind(H2.openStream(link.client, h, true)), "headerList", "over SETTINGS_MAX_HEADER_LIST_SIZE")
  assertEqualLong(H2.nextLocalStreamId(link.client), 1i64, "no id burned")
}

test "openStream refusals: failed and draining connections" {
  val link = newLink()
  appendAll(link.toServer, H2.sendGoAway(link.client, H2NoError))
  assertEqual(openKind(H2.openStream(link.client, grpcRequest("/a/b"), true)), "draining", "after our own GOAWAY")
  val link2 = newLink()
  val r = feedClient(link2, pingFrame(mkBytes(8, 0), false).slice(0, 0))
  assertFalse(H2.isFailed(r.conn), "an empty feed changes nothing")
  val bad = H2.feed(link2.client, rstFrame(99, H2Cancel))
  assertTrue(H2.isFailed(bad.conn), "RST_STREAM on an idle stream failed the connection")
  assertEqual(openKind(H2.openStream(link2.client, grpcRequest("/a/b"), true)), "failed", "failed connection")
}

test "openStream requires a safe request header list" {
  val link = newLink()
  val noPath: List[HeaderField] = newList()
  noPath.add(hf(":method", "POST"))
  noPath.add(hf(":scheme", "http"))
  assertPanics("missing :path", { -> val ignored = H2.openStream(link.client, noPath, true) })
  val upper = grpcRequest("/a/b")
  upper.add(hf("X-Upper", "1"))
  assertPanics("uppercase field name", { -> val ignored = H2.openStream(link.client, upper, true) })
}

// ===========================================================================
// GOAWAY.
// ===========================================================================
test "GOAWAY unprocessed streams" {
  val link = newLink()
  val s1 = clientOpen(link, grpcRequest("/svc/A"), false)
  val s3 = clientOpen(link, grpcRequest("/svc/B"), false)
  val s5 = clientOpen(link, grpcRequest("/svc/C"), false)
  settle(link)
  clearEvents(link)
  val r = feedClient(link, goawayFrame(3, H2NoError))
  assertEqual(kinds(r.events), "goaway,unprocessed", "GOAWAY, then the one stream above the last-stream-id")
  assertTrue(H2.goAwayWasReceived(link.client), "recorded")
  assertEqualInt(H2.peerGoAwayLastStreamId(link.client), 3, "last-stream-id")
  assertTrue(H2.streamState(link.client, s5) == H2.H2SClosed, "stream 5 closed")
  assertTrue(H2.streamState(link.client, s1) == H2.H2SOpen, "stream 1 continues")
  assertTrue(H2.streamState(link.client, s3) == H2.H2SOpen, "stream 3 continues")
  assertEqual(openKind(H2.openStream(link.client, grpcRequest("/svc/D"), true)), "draining", "no new streams")
  assertEqualInt(H2.activeStreamCount(link.client), 2, "two streams still active")
  clientSend(link, s1, mkBytes(1, 1), true)
  clientSend(link, s3, mkBytes(1, 1), true)
  settle(link)
  clearEvents(link)
  serverHeaders(link, s1, okResponse(), true)
  serverHeaders(link, s3, okResponse(), true)
  settle(link)
  assertEqual(kinds(link.cEv), "respH,respH", "both surviving streams complete")
  assertFalse(H2.isFailed(link.client), "healthy")
  assertEqual(openKind(H2.openStream(link.client, grpcRequest("/svc/E"), true)), "draining", "still draining")
}

test "a late frame on an unprocessed stream is discarded" {
  val link = newLink()
  val s1 = clientOpen(link, grpcRequest("/svc/A"), false)
  val s3 = clientOpen(link, grpcRequest("/svc/B"), false)
  settle(link)
  val enc = newEncoder(4096, false)
  val r = feedClient(link, goawayFrame(1, H2NoError))
  assertEqual(kinds(r.events), "goaway,unprocessed", "stream 3 unprocessed")
  val r2 = feedClient(link, headersFrame(s3, encodeBlockWith(enc, okResponse()), true, true))
  assertEqual(kinds(r2.events), "", "frames for it are discarded, not an error")
  assertFalse(H2.isFailed(link.client), "healthy")
  assertTrue(H2.streamState(link.client, s1) == H2.H2SOpen, "stream 1 untouched")
}

test "GOAWAY last-stream-id cannot rise" {
  val link = newLink()
  val ignored = clientOpen(link, grpcRequest("/svc/A"), false)
  settle(link)
  val r1 = feedClient(link, goawayFrame(2147483647, H2NoError))
  assertEqual(kinds(r1.events), "goaway", "an initial maximal GOAWAY is the graceful-shutdown warning")
  val r2 = feedClient(link, goawayFrame(1, H2NoError))
  assertEqual(kinds(r2.events), "goaway", "lowering is allowed")
  val r3 = feedClient(link, goawayFrame(3, H2NoError))
  assertEqualLong(connErrCode(r3.events), errorCodeToLong(H2ProtocolError), "raising it is a PROTOCOL_ERROR")
}

test "client GOAWAY names stream 0 and stops new streams" {
  val link = newLink()
  appendAll(link.toServer, H2.sendGoAway(link.client, H2NoError))
  settle(link)
  assertEqual(kinds(link.sEv), "goaway", "the server saw it")
  assertTrue(H2.goAwayWasSent(link.client), "sent")
  val frames = framesOf(H2.sendGoAway(link.client, H2NoError))
  assertEqualInt(goAwayLastId(frames), 0, "last-stream-id is 0: the peer opened nothing")
}

test "a connection error GOAWAY from a client names stream 0" {
  val link = newLink()
  val r = H2.feed(link.client, rstFrame(7, H2Cancel))
  assertEqualInt(goAwayLastId(framesOf(r.outbound)), 0, "last-stream-id")
}

// ===========================================================================
// RST_STREAM and Rapid Reset gating.
// ===========================================================================
test "client cancel: RST_STREAM reaches the server" {
  val link = newLink()
  val sid = clientOpen(link, grpcRequest("/svc/Slow"), false)
  settle(link)
  clearEvents(link)
  appendAll(link.toServer, H2.sendRstStream(link.client, sid, H2Cancel))
  settle(link)
  assertEqual(kinds(link.sEv), "rst", "the server saw the reset")
  assertEqualLong(peerResetCode(link.sEv, sid), errorCodeToLong(H2Cancel), "CANCEL")
  assertTrue(H2.streamState(link.client, sid) == H2.H2SClosed, "client closed it")
  assertEqual(openKind(H2.openStream(link.client, grpcRequest("/svc/Next"), true)), "ok", "the connection is reusable")
}

test "late frames after a local reset are discarded and HPACK stays in sync" {
  val link = newLink()
  val sid = clientOpen(link, grpcRequest("/svc/Slow"), false)
  settle(link)
  appendAll(link.toServer, H2.sendRstStream(link.client, sid, H2Cancel))
  settle(link)
  clearEvents(link)
  val enc = newEncoder(4096, false)
  val h = okResponse()
  h.add(hf("x-late", "carried-in-the-hpack-table"))
  val late = headersFrame(sid, encodeBlockWith(enc, h), false, true).concat(dataFrame(sid, mkBytes(100, 1), false))
  val r = feedClient(link, late)
  assertEqual(kinds(r.events), "", "no events for a reset stream")
  assertFalse(H2.isFailed(link.client), "not an error")
  assertEqualInt(H2.connectionReceiveWindow(link.client), 65535, "the connection window the DATA used was reclaimed")
  val r2 = feedClient(link, rstFrame(sid, H2Cancel))
  assertEqual(kinds(r2.events), "", "the server's own reset of a closed stream is not news")
  assertFalse(H2.isFailed(link.client), "still healthy")
}

test "server RST_STREAM REFUSED_STREAM is retry-safe and distinguishable" {
  val link = newLink()
  val sid = clientOpen(link, grpcRequest("/svc/A"), true)
  settle(link)
  clearEvents(link)
  val r = feedClient(link, rstFrame(sid, H2RefusedStream))
  assertEqual(kinds(r.events), "rst", "reset")
  assertEqualLong(peerResetCode(r.events, sid), errorCodeToLong(H2RefusedStream), "REFUSED_STREAM")
  assertTrue(H2.streamState(link.client, sid) == H2.H2SClosed, "closed")
}

test "Rapid Reset accounting does not apply to a client" {
  val link = newLinkWith(H2.h2DefaultClientSettings(), customSettings(4096, 1000, 65535, 16384, 32768))
  var i = 0
  while i < 160 {
    val sid = clientOpen(link, grpcRequest("/svc/A"), false)
    settle(link)
    val r = feedClient(link, rstFrame(sid, H2RefusedStream))
    assertEqual(kinds(r.events), "rst", "reset " + sid.toString())
    i = i + 1
  }
  assertFalse(H2.isFailed(link.client), "160 server resets of open streams are routine for a client")
  assertEqual(openKind(H2.openStream(link.client, grpcRequest("/svc/A"), true)), "ok", "still usable")
}

test "RST_STREAM on an idle stream" {
  val link = newLink()
  val r = feedClient(link, rstFrame(5, H2Cancel))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2ProtocolError), "connection PROTOCOL_ERROR")
  val link2 = newLink()
  val r2 = feedClient(link2, rstFrame(2, H2Cancel))
  assertEqualLong(connErrCode(r2.events), errorCodeToLong(H2ProtocolError), "an even (push) id is idle too")
}

test "late frames on a pruned old stream are not errors" {
  val link = newLink()
  var i = 0
  while i < 450 {
    val sid = unaryCall(link, 1)
    assertEqualInt(sid, 2 * i + 1, "id")
    i = i + 1
  }
  assertFalse(H2.isFailed(link.client), "450 exchanges, healthy")
  assertEqualInt(H2.activeStreamCount(link.client), 0, "nothing active")
  assertTrue(H2.streamState(link.client, 1) == H2.H2SIdle, "stream 1's record was pruned")
  val r = feedClient(link, rstFrame(1, H2Cancel))
  assertEqual(kinds(r.events), "", "RST on a forgotten closed stream is ignored")
  val r2 = feedClient(link, dataFrame(3, mkBytes(10, 1), false))
  assertEqual(kinds(r2.events), "", "DATA on a forgotten closed stream is discarded")
  assertFalse(H2.isFailed(link.client), "healthy")
}

// ===========================================================================
// PING.
// ===========================================================================
test "PING both ways" {
  val link = newLink()
  clearEvents(link)
  val payload = mkBytes(8, 42)
  appendAll(link.toServer, H2.sendPing(link.client, payload))
  settle(link)
  assertEqual(kinds(link.sEv), "ping", "the server saw a PING")
  assertEqual(kinds(link.cEv), "pong", "the client saw its ACK")
  clearEvents(link)
  appendAll(link.toClient, H2.sendPing(link.server, mkBytes(8, 9)))
  settle(link)
  assertEqual(kinds(link.cEv), "ping", "the client saw a PING")
  assertEqual(kinds(link.sEv), "pong", "the server saw its ACK")
  assertPanics("PING needs eight octets", { -> val ignored = H2.sendPing(link.client, mkBytes(7, 1)) })
}

// ===========================================================================
// Negative matrix: a misbehaving server.
// ===========================================================================
test "oversized DATA frame" {
  val link = linkWithOneRequest()
  val r = feedClient(link, dataFrame(1, mkBytes(20000, 1), false))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2FrameSizeError), "FRAME_SIZE_ERROR")
  assertTrue(hasGoAwayFrame(framesOf(r.outbound), H2FrameSizeError), "GOAWAY queued")
}

test "undecodable response header block" {
  val link = linkWithOneRequest()
  val bad: slice[Byte] = [128u8, 255u8, 255u8]
  val r = feedClient(link, headersFrame(1, bad, false, true))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2CompressionError), "COMPRESSION_ERROR")
}

test "HEADERS on an idle stream" {
  val link = linkWithOneRequest()
  val r = feedClient(link, headersFrame(3, freshBlock(okResponse()), false, true))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2ProtocolError), "an id this client has not opened")
}

test "DATA on an idle stream" {
  val link = linkWithOneRequest()
  val r = feedClient(link, dataFrame(5, mkBytes(4, 1), false))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2ProtocolError), "DATA on an unopened stream")
}

test "even stream id HEADERS" {
  val link = linkWithOneRequest()
  val r = feedClient(link, headersFrame(2, freshBlock(okResponse()), false, true))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2ProtocolError), "push stream id")
  assertTrue(connErrMessage(r.events).contains("push"), "the message names push")
}

test "even stream id DATA" {
  val link = linkWithOneRequest()
  val r = feedClient(link, dataFrame(2, mkBytes(4, 1), false))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2ProtocolError), "DATA on a push stream id")
}

test "PUSH_PROMISE" {
  val link = linkWithOneRequest()
  val frame = serializeFrame(
    PushPromiseFrame(
      streamId = 1,
      promisedStreamId = 2,
      headerBlockFragment = freshBlock(requestWithMethod("GET")),
      endHeaders = true
    )
  )
  val r = feedClient(link, frame)
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2ProtocolError), "PROTOCOL_ERROR")
  assertTrue(connErrMessage(r.events).contains("PUSH_PROMISE"), "message names the frame")
}

test "DATA before final HEADERS" {
  val link = linkWithOneRequest()
  val r = feedClient(link, dataFrame(1, mkBytes(4, 1), false))
  assertEqualLong(streamErrCode(r.events, 1), errorCodeToLong(H2ProtocolError), "stream PROTOCOL_ERROR")
  assertTrue(hasRstFrame(framesOf(r.outbound), 1, H2ProtocolError), "RST_STREAM queued")
  assertFalse(H2.isFailed(r.conn), "stream error only")
  assertStillUsable(link, "DATA before HEADERS")
}

test "DATA after the response ended" {
  val link = linkWithOneRequest()
  val enc = newEncoder(4096, false)
  val r = feedClient(link, headersFrame(1, encodeBlockWith(enc, okResponse()), true, true))
  assertEqual(kinds(r.events), "respH", "Trailers-Only response")
  val r2 = feedClient(link, dataFrame(1, mkBytes(4, 1), false))
  assertEqualLong(streamErrCode(r2.events, 1), errorCodeToLong(H2StreamClosed), "STREAM_CLOSED")
  assertFalse(H2.isFailed(r2.conn), "stream error only")
  assertEqualInt(H2.connectionReceiveWindow(link.client), 65535, "the connection window was reclaimed")
}

test "HEADERS after the response ended" {
  val link = newLink()
  val sid = clientOpen(link, grpcRequest("/svc/M"), false)
  settle(link)
  clearEvents(link)
  val enc = newEncoder(4096, false)
  val r = feedClient(link, headersFrame(sid, encodeBlockWith(enc, okResponse()), true, true))
  assertEqual(kinds(r.events), "respH", "Trailers-Only response while the request body is still open")
  assertTrue(H2.streamState(link.client, sid) == H2.H2SHalfClosedRemote, "half-closed remote")
  val again = okResponse()
  again.add(hf("x-more", "1"))
  val r2 = feedClient(link, headersFrame(sid, encodeBlockWith(enc, again), true, true))
  assertEqualLong(streamErrCode(r2.events, sid), errorCodeToLong(H2StreamClosed), "STREAM_CLOSED stream error")
  assertFalse(H2.isFailed(r2.conn), "connection survives")
  assertStillUsable(link, "HEADERS on a half-closed (remote) stream")
}

test "HEADERS on a fully closed stream" {
  val link = linkWithOneRequest()
  val enc = newEncoder(4096, false)
  val r = feedClient(link, headersFrame(1, encodeBlockWith(enc, okResponse()), true, true))
  assertEqual(kinds(r.events), "respH", "response ends the exchange")
  assertTrue(H2.streamState(link.client, 1) == H2.H2SClosed, "closed")
  val r2 = feedClient(link, headersFrame(1, encodeBlockWith(enc, okResponse()), true, true))
  assertEqualLong(
    connErrCode(r2.events),
    errorCodeToLong(H2StreamClosed),
    "connection STREAM_CLOSED (RFC 9113 section 5.1)"
  )
}

test "trailers without END_STREAM" {
  val link = linkWithOneRequest()
  val enc = newEncoder(4096, false)
  val r = feedClient(link, headersFrame(1, encodeBlockWith(enc, okResponse()), false, true))
  assertEqual(kinds(r.events), "respH", "response headers")
  val r2 = feedClient(link, headersFrame(1, encodeBlockWith(enc, grpcTrailers("0")), false, true))
  assertEqualLong(streamErrCode(r2.events, 1), errorCodeToLong(H2ProtocolError), "stream PROTOCOL_ERROR")
  assertFalse(H2.isFailed(r2.conn), "connection survives")
  assertStillUsable(link, "trailers without END_STREAM")
}

test "trailers with a pseudo-header" {
  val link = linkWithOneRequest()
  val enc = newEncoder(4096, false)
  val ignored = feedClient(link, headersFrame(1, encodeBlockWith(enc, okResponse()), false, true))
  val bad: List[HeaderField] = newList()
  bad.add(hf(":status", "200"))
  bad.add(hf("grpc-status", "0"))
  val r = feedClient(link, headersFrame(1, encodeBlockWith(enc, bad), true, true))
  assertEqualLong(streamErrCode(r.events, 1), errorCodeToLong(H2ProtocolError), "stream PROTOCOL_ERROR")
  assertStillUsable(link, "trailer pseudo-header")
}

test "1xx with END_STREAM" {
  val link = linkWithOneRequest()
  val enc = newEncoder(4096, false)
  val r = feedClient(link, headersFrame(1, encodeBlockWith(enc, statusOnly("100")), true, true))
  assertEqualLong(streamErrCode(r.events, 1), errorCodeToLong(H2ProtocolError), "stream PROTOCOL_ERROR")
  assertStillUsable(link, "1xx END_STREAM")
}

test "content-length against DATA" {
  val link = linkWithOneRequest()
  val enc = newEncoder(4096, false)
  val h = okResponse()
  h.add(hf("content-length", "5"))
  val ignored = feedClient(link, headersFrame(1, encodeBlockWith(enc, h), false, true))
  val r = feedClient(link, dataFrame(1, mkBytes(3, 1), true))
  assertEqualLong(streamErrCode(r.events, 1), errorCodeToLong(H2ProtocolError), "short body")
  val link2 = linkWithOneRequest()
  val enc2 = newEncoder(4096, false)
  val ignored2 = feedClient(link2, headersFrame(1, encodeBlockWith(enc2, h), false, true))
  val r2 = feedClient(link2, dataFrame(1, mkBytes(9, 1), false))
  assertEqualLong(streamErrCode(r2.events, 1), errorCodeToLong(H2ProtocolError), "long body")
  val link3 = linkWithOneRequest()
  val enc3 = newEncoder(4096, false)
  val ignored3 = feedClient(link3, headersFrame(1, encodeBlockWith(enc3, h), false, true))
  val r3 = feedClient(link3, dataFrame(1, mkBytes(5, 1), true))
  assertEqual(kinds(r3.events), "respD", "an exact body is accepted")
  val link4 = linkWithOneRequest()
  val r4 = feedClient(link4, headersFrame(1, freshBlock(h), true, true))
  assertEqualLong(
    streamErrCode(r4.events, 1),
    errorCodeToLong(H2ProtocolError),
    "END_STREAM HEADERS with a positive content-length"
  )
}

test "uppercase field name" {
  val link = linkWithOneRequest()
  val h = okResponse()
  h.add(hf("X-Upper", "1"))
  val r = feedClient(link, headersFrame(1, freshBlock(h), false, true))
  assertEqualLong(streamErrCode(r.events, 1), errorCodeToLong(H2ProtocolError), "stream PROTOCOL_ERROR")
  assertStillUsable(link, "uppercase field name")
}

test "invalid field value" {
  val link = linkWithOneRequest()
  val h = okResponse()
  h.add(hf("x-evil", "a\nb"))
  val r = feedClient(link, headersFrame(1, freshBlock(h), false, true))
  assertEqualLong(streamErrCode(r.events, 1), errorCodeToLong(H2ProtocolError), "stream PROTOCOL_ERROR")
  assertStillUsable(link, "invalid field value")
}

test "connection-specific response field" {
  val names: List[String] = newList()
  names.add("connection")
  names.add("keep-alive")
  names.add("proxy-connection")
  names.add("transfer-encoding")
  names.add("upgrade")
  var i = 0
  while i < names.count {
    val link = linkWithOneRequest()
    val h = okResponse()
    h.add(hf(names[i], "x"))
    val r = feedClient(link, headersFrame(1, freshBlock(h), false, true))
    assertEqualLong(streamErrCode(r.events, 1), errorCodeToLong(H2ProtocolError), names[i])
    i = i + 1
  }
}

test "response without :status" {
  val cases: List[List[HeaderField]] = newList()
  val noStatus: List[HeaderField] = newList()
  noStatus.add(hf("content-type", "application/grpc"))
  cases.add(noStatus)
  val dup: List[HeaderField] = newList()
  dup.add(hf(":status", "200"))
  dup.add(hf(":status", "200"))
  cases.add(dup)
  cases.add(statusOnly("20"))
  cases.add(statusOnly("abc"))
  cases.add(statusOnly("600"))
  cases.add(statusOnly("099"))
  cases.add(statusOnly("101"))
  val late: List[HeaderField] = newList()
  late.add(hf("content-type", "x"))
  late.add(hf(":status", "200"))
  cases.add(late)
  val reqPseudo: List[HeaderField] = newList()
  reqPseudo.add(hf(":status", "200"))
  reqPseudo.add(hf(":method", "GET"))
  cases.add(reqPseudo)
  val conflictingCl: List[HeaderField] = newList()
  conflictingCl.add(hf(":status", "200"))
  conflictingCl.add(hf("content-length", "1"))
  conflictingCl.add(hf("content-length", "2"))
  cases.add(conflictingCl)
  var i = 0
  while i < cases.count {
    val link = linkWithOneRequest()
    val r = feedClient(link, headersFrame(1, freshBlock(cases[i]), false, true))
    assertEqualLong(streamErrCode(r.events, 1), errorCodeToLong(H2ProtocolError), "case " + i.toString())
    assertFalse(H2.isFailed(r.conn), "case " + i.toString() + ": stream error only")
    i = i + 1
  }
}

test "malformedResponseReason table" {
  assertTrue(noReason(H2.malformedResponseReason(okResponse())), "plain 200")
  assertTrue(noReason(H2.malformedResponseReason(statusOnly("404"))), "404")
  assertTrue(noReason(H2.malformedResponseReason(statusOnly("100"))), "100 is a valid informational block")
  assertTrue(hasReason(H2.malformedResponseReason(statusOnly("101"))), "101")
  assertTrue(hasReason(H2.malformedResponseReason(statusOnly("2000"))), "four digits")
  val none: List[HeaderField] = newList()
  assertTrue(hasReason(H2.malformedResponseReason(none)), "empty block")
  val te = okResponse()
  te.add(hf("te", "trailers"))
  assertTrue(noReason(H2.malformedResponseReason(te)), "te is a request-side rule")
}

func noReason(o: in Option[String]): Bool {
  match o {
    case None -> true
    case Some(_) -> false
  }
}

func hasReason(o: in Option[String]): Bool {
  not noReason(o)
}

test "isH2RequestHeaderListSafe table" {
  assertTrue(H2.isH2RequestHeaderListSafe(grpcRequest("/a/b")), "a gRPC request")
  assertTrue(H2.isH2RequestHeaderListSafe(requestWithMethod("GET")), "GET")
  val connect: List[HeaderField] = newList()
  connect.add(hf(":method", "CONNECT"))
  connect.add(hf(":authority", "example.com:443"))
  assertTrue(H2.isH2RequestHeaderListSafe(connect), "CONNECT with only :authority")
  connect.add(hf(":path", "/"))
  assertFalse(H2.isH2RequestHeaderListSafe(connect), "CONNECT must not carry :path")
  val noScheme: List[HeaderField] = newList()
  noScheme.add(hf(":method", "GET"))
  noScheme.add(hf(":path", "/"))
  assertFalse(H2.isH2RequestHeaderListSafe(noScheme), "missing :scheme")
  val emptyPath = requestWithMethod("GET")
  val ep: List[HeaderField] = newList()
  ep.add(hf(":method", "GET"))
  ep.add(hf(":scheme", "https"))
  ep.add(hf(":path", ""))
  assertFalse(H2.isH2RequestHeaderListSafe(ep), "empty :path")
  assertTrue(H2.isH2RequestHeaderListSafe(emptyPath), "control")
  val dup = requestWithMethod("GET")
  val dupBad: List[HeaderField] = newList()
  dupBad.add(hf(":method", "GET"))
  dupBad.add(hf(":method", "GET"))
  dupBad.add(hf(":scheme", "https"))
  dupBad.add(hf(":path", "/"))
  assertFalse(H2.isH2RequestHeaderListSafe(dupBad), "duplicate :method")
  assertTrue(H2.isH2RequestHeaderListSafe(dup), "control 2")
  val late = requestWithMethod("GET")
  late.add(hf(":protocol", "websocket"))
  assertFalse(H2.isH2RequestHeaderListSafe(late), "pseudo-header after a regular field or unknown")
  val badTe = requestWithMethod("GET")
  badTe.add(hf("te", "gzip"))
  assertFalse(H2.isH2RequestHeaderListSafe(badTe), "te other than trailers")
  val conn = requestWithMethod("GET")
  conn.add(hf("connection", "close"))
  assertFalse(H2.isH2RequestHeaderListSafe(conn), "connection-specific")
  val host = requestWithMethod("GET")
  host.add(hf("host", "other.example"))
  assertFalse(H2.isH2RequestHeaderListSafe(host), "host differing from :authority")
  val hostOk = requestWithMethod("GET")
  hostOk.add(hf("host", "EXAMPLE.com"))
  assertTrue(H2.isH2RequestHeaderListSafe(hostOk), "host equal to :authority, case-insensitively")
  val cl = requestWithMethod("POST")
  cl.add(hf("content-length", "12x"))
  assertFalse(H2.isH2RequestHeaderListSafe(cl), "bad content-length")
  val ctl = requestWithMethod("GET")
  ctl.add(hf("x-a", "b\r\nc"))
  assertFalse(H2.isH2RequestHeaderListSafe(ctl), "CRLF in a value")
}

test "CONTINUATION without HEADERS" {
  val link = linkWithOneRequest()
  val r = feedClient(link, continuationFrame(1, freshBlock(okResponse()), true))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2ProtocolError), "PROTOCOL_ERROR")
}

test "non-CONTINUATION during a header block" {
  val link = linkWithOneRequest()
  val block = freshBlock(okResponse())
  val part = headersFrame(1, block.slice(0, 2), false, false)
  val r = feedClient(link, part.concat(dataFrame(1, mkBytes(1, 1), false)))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2ProtocolError), "PROTOCOL_ERROR")
}

test "CONTINUATION flood" {
  val link = linkWithOneRequest()
  val block = freshBlock(okResponse())
  val acc: List[Byte] = newBytesList()
  appendAll(acc, headersFrame(1, block.slice(0, 1), false, false))
  var i = 0
  while i < 1100 {
    appendAll(acc, continuationFrame(1, emptyBytesT(), false))
    i = i + 1
  }
  val r = feedClient(link, acc.toArray())
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2EnhanceYourCalm), "ENHANCE_YOUR_CALM")
}

test "response header block over the advertised budget" {
  val link = newLinkWith(customSettings(4096, 100, 65535, 16384, 100), H2.h2DefaultServerSettings())
  val sid = clientOpen(link, grpcRequest("/svc/M"), true)
  settle(link)
  clearEvents(link)
  val h = okResponse()
  h.add(hf("x-big", bigString(5000)))
  val r = feedClient(link, headersFrame(sid, freshBlock(h), false, true))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2EnhanceYourCalm), "ENHANCE_YOUR_CALM")
}

test "invalid SETTINGS values from the server" {
  val fresh1 = H2.newClientConnection(H2.h2DefaultClientSettings())
  val r1 = H2.feed(fresh1, settingsFrame(oneSetting(SettingsEnablePush, 2i64)))
  assertEqualLong(connErrCode(r1.events), errorCodeToLong(H2ProtocolError), "ENABLE_PUSH 2")
  val fresh2 = H2.newClientConnection(H2.h2DefaultClientSettings())
  val r2 = H2.feed(fresh2, settingsFrame(oneSetting(SettingsInitialWindowSize, 2147483648i64)))
  assertEqualLong(connErrCode(r2.events), errorCodeToLong(H2FlowControlError), "initial window over 2^31-1")
  val fresh3 = H2.newClientConnection(H2.h2DefaultClientSettings())
  val r3 = H2.feed(fresh3, settingsFrame(oneSetting(SettingsMaxFrameSize, 100i64)))
  assertEqualLong(connErrCode(r3.events), errorCodeToLong(H2ProtocolError), "max frame size below 2^14")
}

test "stream window overrun" {
  val link = newLinkWith(customSettings(4096, 100, 1000, 16384, 32768), H2.h2DefaultServerSettings())
  val sid = clientOpen(link, grpcRequest("/svc/M"), true)
  settle(link)
  val enc = newEncoder(4096, false)
  val ignored = feedClient(link, headersFrame(sid, encodeBlockWith(enc, okResponse()), false, true))
  val r = feedClient(link, dataFrame(sid, mkBytes(2000, 1), false))
  assertEqualLong(streamErrCode(r.events, sid), errorCodeToLong(H2FlowControlError), "stream FLOW_CONTROL_ERROR")
  assertFalse(H2.isFailed(r.conn), "stream error only")
  assertEqualInt(H2.connectionReceiveWindow(link.client), 65535, "the connection window was reclaimed")
}

test "connection window overrun" {
  val link = linkWithOneRequest()
  val enc = newEncoder(4096, false)
  val ignored = feedClient(link, headersFrame(1, encodeBlockWith(enc, okResponse()), false, true))
  val acc: List[Byte] = newBytesList()
  var i = 0
  while i < 5 {
    appendAll(acc, dataFrame(1, mkBytes(16384, 1), false))
    i = i + 1
  }
  val r = feedClient(link, acc.toArray())
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2FlowControlError), "connection FLOW_CONTROL_ERROR")
}

test "WINDOW_UPDATE overflow and idle-stream WINDOW_UPDATE" {
  val link = linkWithOneRequest()
  val r = feedClient(link, windowUpdateFrame(0, 2147483647))
  assertEqualLong(connErrCode(r.events), errorCodeToLong(H2FlowControlError), "connection window overflow")
  val link2 = linkWithOneRequest()
  val r2 = feedClient(link2, windowUpdateFrame(9, 10))
  assertEqualLong(connErrCode(r2.events), errorCodeToLong(H2ProtocolError), "WINDOW_UPDATE on an idle stream")
}

test "unknown frame types and PRIORITY are ignored" {
  val link = linkWithOneRequest()
  val prio = serializeFrame(
    PriorityFrame(
      streamId = 1,
      priority = PriorityInfo(exclusive = false, streamDependency = 0, weight = 16)
    )
  )
  val r = feedClient(link, prio)
  assertEqual(kinds(r.events), "", "PRIORITY ignored")
  assertFalse(H2.isFailed(r.conn), "healthy")
}
