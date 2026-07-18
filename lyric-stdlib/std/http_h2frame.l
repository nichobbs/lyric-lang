//! std/http_h2frame.l — pure-Lyric, sans-IO HTTP/2 frame codec (RFC 9113
//! §4/§6, D128; phase 4.2 of epic #5874, issue #5887).
//!
//! `Std.HttpEngine.H2Frame` is the framing layer of the HTTP/2 stack: it
//! serializes and parses the 9-octet frame header (§4.1) and every §6 frame
//! type, detects/emits the connection preface (§3.4), and signals malformed
//! or oversized frames as typed `FrameError`s that map onto the RFC's
//! connection/stream error codes (§4.2/§7). Like `Std.HttpEngine` (the
//! HTTP/1.1 engine it sits beside) it is "sans-IO": it never touches a
//! socket, consuming `slice[Byte]` chunks handed to it by a transport driver
//! and returning typed events, and producing `slice[Byte]` output the driver
//! writes back out. This is what makes the whole layer exhaustively
//! unit-testable with zero network I/O (`http_h2frame_tests.l`) and reusable,
//! unchanged, by the .NET, JVM, and native transports (docs/61 decision 6/8).
//!
//! No `extern type`, no `import extern`, no kernel file: every byte here is
//! plain Lyric computation over `slice[Byte]`/`Int`/`Long`, exactly like the
//! `Std.Xml`/`Std.Yaml` pure-Lyric parsers (D065) and `Std.HttpEngine`. Only
//! `Std.Core`/`Std.Collections` are imported.
//!
//! ## Scope boundary
//!
//! This is the FRAME layer only. Two adjacent slices are deliberately *out*
//! of scope and land in their own files/PRs:
//!
//!   - **HPACK** (RFC 7541 header-block compression, issue #5886) — the
//!     `HEADERS`/`PUSH_PROMISE`/`CONTINUATION` frames carry an opaque
//!     "header block fragment" `slice[Byte]` that this codec passes through
//!     verbatim; decompressing it into name/value pairs is HPACK's job.
//!   - **Connection/stream state machine + flow control** (issue #5888) —
//!     this codec validates a frame's *own* structural well-formedness
//!     (length limits, padding, the fixed per-type stream-id rules of §6),
//!     but it does not track stream states, reassemble a `HEADERS` +
//!     `CONTINUATION` sequence, apply `SETTINGS`, or account flow-control
//!     windows. Those require connection-wide state the FSM owns. A
//!     `FrameError` here reports *what* is malformed and whether the RFC
//!     classifies it as a connection- or stream-level error; the FSM decides
//!     the response (GOAWAY vs RST_STREAM).
//!
//! ## Frame-type coverage (RFC 9113 §6)
//!
//! All ten §6 frame types round-trip through `serializeFrame`/`parseFrame`:
//! `DATA` (§6.1), `HEADERS` (§6.2), `PRIORITY` (§6.3, parsed but deprecated —
//! see below), `RST_STREAM` (§6.4), `SETTINGS` (§6.5), `PUSH_PROMISE` (§6.6),
//! `PING` (§6.7), `GOAWAY` (§6.8), `WINDOW_UPDATE` (§6.9), and `CONTINUATION`
//! (§6.10). An unrecognized frame type is surfaced as `UnknownFrame` rather
//! than rejected, per §4.1/§5.1's "an endpoint that receives an unknown frame
//! type MUST discard it" — the codec hands it to the driver to discard rather
//! than poisoning the connection.
//!
//! `PRIORITY` (and the priority prefix an old client may set on `HEADERS`) is
//! **parsed but semantically ignored**: RFC 9113 deprecates the RFC 7540
//! priority scheme (§5.3.2), so higher layers discard the parsed
//! `PriorityInfo`. The codec still parses it faithfully so a peer that sends
//! it does not trip a spurious error.
//!
//! ## Padding (§6.1)
//!
//! On *parse*, padding is fully handled and security-checked: a `PADDED`
//! frame's leading pad-length octet is read, the trailing pad bytes are
//! stripped, and a pad length that meets or exceeds the payload size is
//! rejected as a connection `PROTOCOL_ERROR` (§6.1: "If the length of the
//! padding is the length of the frame payload or greater, the recipient MUST
//! treat this as a connection error"). Padding is invisible above this layer
//! — a `DataFrame`/`HeadersFrame`/`PushPromiseFrame` carries only the real
//! payload.
//!
//! On *serialize*, this codec emits no padding (an unpadded frame is always
//! valid on the wire, and padding is only a traffic-analysis mitigation the
//! server has no reason to add by default). The frame union therefore has no
//! pad-length field; padding is a pure wire detail. The parse-side padding
//! logic is exercised directly with byte vectors in the test corpus, since a
//! serialize→parse round-trip cannot reach it.
//!
//! ## Integer widths (§4.1/§6)
//!
//! Lengths are 24-bit and stream identifiers are 31-bit (the high "R" bit is
//! reserved and, per §4.1/§5.1, MUST be ignored on receipt — this codec masks
//! it off on parse and writes it as 0 on serialize), so both fit a 32-bit
//! `Int`. Error codes (§7) and `SETTINGS` parameter values (§6.5) are 32-bit
//! *unsigned* and can exceed `Int`'s positive range, so they are carried as
//! `Long`. `PING` opaque data (§6.7) is left as a raw 8-byte `slice[Byte]`
//! rather than decoded to an integer.
@runtime_checked
package Std.HttpEngine.H2Frame

import Std.Core
import Std.Collections

// =============================================================================
// §1. Frame-type and flag codes (RFC 9113 §6, §4.1 flag bits).
// =============================================================================
// Type codes are internal — the parsed `H2Frame` union is the surface a
// consumer matches on; the raw code is only meaningful on the wire (and on an
// `H2FrameHeader`, where it is kept as an `Int` so an `UnknownFrame` can round
// its original type back out).
func typeData(): Int {
  0
}

func typeHeaders(): Int {
  1
}

func typePriority(): Int {
  2
}

func typeRstStream(): Int {
  3
}

func typeSettings(): Int {
  4
}

func typePushPromise(): Int {
  5
}

func typePing(): Int {
  6
}

func typeGoAway(): Int {
  7
}

func typeWindowUpdate(): Int {
  8
}

func typeContinuation(): Int {
  9
}

// Flag bits (§6): END_STREAM/ACK share bit 0 across the frame types that use
// them; END_HEADERS is bit 2; PADDED is bit 3; PRIORITY is bit 5.
func flagEndStream(flags: in Int): Bool {
  flags.and(1) != 0
}

func flagAck(flags: in Int): Bool {
  flags.and(1) != 0
}

func flagEndHeaders(flags: in Int): Bool {
  flags.and(4) != 0
}

func flagPadded(flags: in Int): Bool {
  flags.and(8) != 0
}

func flagPriority(flags: in Int): Bool {
  flags.and(32) != 0
}

// =============================================================================
// §2. Error codes (RFC 9113 §7) and settings identifiers (§6.5).
// =============================================================================
/// The 14 registered HTTP/2 error codes (RFC 9113 §7) plus a catch-all for
/// codes outside the registry (which §7 requires be treated the same as
/// `INTERNAL_ERROR` but preserved for logging). Case names carry an `H2`
/// prefix so they never collide, in a program that imports several
/// `Std.HttpEngine.*` packages at once, with a same-spelled case elsewhere
/// (the cross-package bare-enum-case resolution hazard `Std.HttpEngine`'s own
/// `Http1_1` rename documents, #5995).
@experimental
pub union H2ErrorCode {
  case H2NoError
  case H2ProtocolError
  case H2InternalError
  case H2FlowControlError
  case H2SettingsTimeout
  case H2StreamClosed
  case H2FrameSizeError
  case H2RefusedStream
  case H2Cancel
  case H2CompressionError
  case H2ConnectError
  case H2EnhanceYourCalm
  case H2InadequateSecurity
  case H2Http11Required
  case H2UnknownError(code: Long)
}

/// The registered numeric value (§7) for an error code.
@pure
@experimental
pub func errorCodeToLong(c: in H2ErrorCode): Long {
  match c {
    case H2NoError -> 0i64
    case H2ProtocolError -> 1i64
    case H2InternalError -> 2i64
    case H2FlowControlError -> 3i64
    case H2SettingsTimeout -> 4i64
    case H2StreamClosed -> 5i64
    case H2FrameSizeError -> 6i64
    case H2RefusedStream -> 7i64
    case H2Cancel -> 8i64
    case H2CompressionError -> 9i64
    case H2ConnectError -> 10i64
    case H2EnhanceYourCalm -> 11i64
    case H2InadequateSecurity -> 12i64
    case H2Http11Required -> 13i64
    case H2UnknownError(code) -> code
  }
}

/// Map a wire error-code value back to its `H2ErrorCode`; anything outside
/// `[0, 13]` becomes `H2UnknownError` carrying the raw value.
@pure
@experimental
pub func errorCodeFromLong(v: in Long): H2ErrorCode {
  if v == 0i64 {
    H2NoError
  } else if v == 1i64 {
    H2ProtocolError
  } else if v == 2i64 {
    H2InternalError
  } else if v == 3i64 {
    H2FlowControlError
  } else if v == 4i64 {
    H2SettingsTimeout
  } else if v == 5i64 {
    H2StreamClosed
  } else if v == 6i64 {
    H2FrameSizeError
  } else if v == 7i64 {
    H2RefusedStream
  } else if v == 8i64 {
    H2Cancel
  } else if v == 9i64 {
    H2CompressionError
  } else if v == 10i64 {
    H2ConnectError
  } else if v == 11i64 {
    H2EnhanceYourCalm
  } else if v == 12i64 {
    H2InadequateSecurity
  } else if v == 13i64 {
    H2Http11Required
  } else {
    H2UnknownError(code = v)
  }
}

/// The six registered `SETTINGS` parameters (RFC 9113 §6.5.2) plus a catch-all
/// for unknown identifiers, which §6.5.2 requires a receiver to ignore rather
/// than reject. `Settings`-prefixed for the same cross-package
/// bare-case-collision reason as `H2ErrorCode`.
@experimental
pub union SettingsId {
  case SettingsHeaderTableSize
  case SettingsEnablePush
  case SettingsMaxConcurrentStreams
  case SettingsInitialWindowSize
  case SettingsMaxFrameSize
  case SettingsMaxHeaderListSize
  case SettingsUnknown(id: Int)
}

/// The registered 16-bit identifier (§6.5.2) for a settings parameter.
@pure
@experimental
pub func settingsIdToInt(s: in SettingsId): Int {
  match s {
    case SettingsHeaderTableSize -> 1
    case SettingsEnablePush -> 2
    case SettingsMaxConcurrentStreams -> 3
    case SettingsInitialWindowSize -> 4
    case SettingsMaxFrameSize -> 5
    case SettingsMaxHeaderListSize -> 6
    case SettingsUnknown(id) -> id
  }
}

/// Map a wire identifier back to its `SettingsId`; anything outside `[1, 6]`
/// becomes `SettingsUnknown` (ignored by the FSM, §6.5.2).
@pure
@experimental
pub func settingsIdFromInt(i: in Int): SettingsId {
  if i == 1 {
    SettingsHeaderTableSize
  } else if i == 2 {
    SettingsEnablePush
  } else if i == 3 {
    SettingsMaxConcurrentStreams
  } else if i == 4 {
    SettingsInitialWindowSize
  } else if i == 5 {
    SettingsMaxFrameSize
  } else if i == 6 {
    SettingsMaxHeaderListSize
  } else {
    SettingsUnknown(id = i)
  }
}

/// One `SETTINGS` parameter: a 16-bit identifier and its 32-bit unsigned value
/// (carried as `Long`, §6.5.1).
@experimental
pub record SettingsParam {
  id: SettingsId
  value: Long
}

/// The RFC 7540 stream-priority fields (§6.3): the exclusive bit, a 31-bit
/// stream dependency, and a weight in `1..=256`. Deprecated by RFC 9113
/// §5.3.2 and ignored above the codec, but parsed faithfully.
///
/// `weight` is the *effective* weight (`1..=256`); on the wire the field holds
/// `weight - 1` (§6.3), and this codec adds/subtracts the bias so callers
/// never see the off-by-one wire encoding.
@experimental
pub record PriorityInfo {
  exclusive: Bool
  streamDependency: Int
  weight: Int
}

// =============================================================================
// §3. The frame header and the parsed frame union.
// =============================================================================
/// The decoded 9-octet frame header (RFC 9113 §4.1). `streamId` already has
/// its reserved high bit stripped; `frameType` and `flags` are the raw wire
/// octets so an `UnknownFrame` can be reconstructed verbatim.
@experimental
pub record H2FrameHeader {
  length: Int
  frameType: Int
  flags: Int
  streamId: Int
}

/// Every HTTP/2 frame type (RFC 9113 §6), parsed into its semantic content.
/// Padding (§6.1) is already stripped; header-block fragments are the opaque
/// HPACK-compressed bytes (#5886 owns decompression).
@experimental
pub union H2Frame {
  case DataFrame(streamId: Int, data: slice[Byte], endStream: Bool)
  case HeadersFrame(streamId: Int, headerBlockFragment: slice[Byte], endStream: Bool, endHeaders: Bool, priority: Option[PriorityInfo])
  case PriorityFrame(streamId: Int, priority: PriorityInfo)
  case RstStreamFrame(streamId: Int, errorCode: H2ErrorCode)
  case SettingsFrame(settings: List[SettingsParam], ack: Bool)
  case PushPromiseFrame(streamId: Int, promisedStreamId: Int, headerBlockFragment: slice[Byte], endHeaders: Bool)
  case PingFrame(opaqueData: slice[Byte], ack: Bool)
  case GoAwayFrame(lastStreamId: Int, errorCode: H2ErrorCode, debugData: slice[Byte])
  case WindowUpdateFrame(streamId: Int, windowSizeIncrement: Int)
  case ContinuationFrame(streamId: Int, headerBlockFragment: slice[Byte], endHeaders: Bool)
  case UnknownFrame(header: H2FrameHeader, payload: slice[Byte])
}

/// A malformed or oversized frame. `code` is the RFC 9113 §7 error code a
/// responder should signal, `connectionError` distinguishes a connection-level
/// fault (§5.4.1, respond with GOAWAY and close) from a stream-level one
/// (§5.4.2, respond with RST_STREAM and continue), and `message` is a
/// human-readable diagnostic.
@experimental
pub record FrameError {
  code: H2ErrorCode
  connectionError: Bool
  message: String
}

func mkConnErr(code: in H2ErrorCode, message: in String): FrameError {
  FrameError(code = code, connectionError = true, message = message)
}

func mkStreamErr(code: in H2ErrorCode, message: in String): FrameError {
  FrameError(code = code, connectionError = false, message = message)
}

// =============================================================================
// §4. Byte helpers (big-endian, per §4.1). No externs — pure arithmetic.
// =============================================================================
/// Append the low octet of `v` (`v & 0xFF`) to `acc`.
func pushByte(acc: in List[Byte], v: in Int): Unit {
  acc.add(v.and(255).toByte())
}

func pushBytes(acc: in List[Byte], data: in slice[Byte]): Unit {
  var i = 0
  while i < data.length {
    acc.add(data[i])
    i = i + 1
  }
}

/// Append a 24-bit big-endian value (frame length, §4.1).
func push24(acc: in List[Byte], v: in Int): Unit {
  pushByte(acc, v.shr(16))
  pushByte(acc, v.shr(8))
  pushByte(acc, v)
}

/// Append a 31-bit big-endian value with the reserved high bit written as 0
/// (stream identifiers, §4.1; and §6.3/§6.6/§6.8/§6.9 R-prefixed fields).
func push31(acc: in List[Byte], v: in Int): Unit {
  pushByte(acc, v.shr(24).and(127))
  pushByte(acc, v.shr(16))
  pushByte(acc, v.shr(8))
  pushByte(acc, v)
}

/// Append a 32-bit big-endian unsigned value (error codes §7, settings values
/// §6.5.1) from a `Long`.
func push32(acc: in List[Byte], v: in Long): Unit {
  pushByte(acc, v.shr(24).and(255i64).toInt())
  pushByte(acc, v.shr(16).and(255i64).toInt())
  pushByte(acc, v.shr(8).and(255i64).toInt())
  pushByte(acc, v.and(255i64).toInt())
}

/// Append a 16-bit big-endian value (settings identifiers, §6.5.1).
func push16(acc: in List[Byte], v: in Int): Unit {
  pushByte(acc, v.shr(8))
  pushByte(acc, v)
}

func read16(p: in slice[Byte], off: in Int): Int {
  p[off].toInt().shl(8).or(p[off + 1].toInt())
}

func read24(p: in slice[Byte], off: in Int): Int {
  p[off].toInt().shl(16).or(p[off + 1].toInt().shl(8)).or(p[off + 2].toInt())
}

/// Read a 31-bit big-endian value, masking off the reserved high bit (§4.1).
func read31(p: in slice[Byte], off: in Int): Int {
  p[off].toInt().and(127).shl(24).or(p[off + 1].toInt().shl(16)).or(p[off + 2].toInt().shl(8)).or(p[off + 3].toInt())
}

/// Read a 32-bit big-endian unsigned value into a `Long` (§7 error codes,
/// §6.5.1 settings values). Widening each octet to `Long` before shifting
/// keeps a value in `[2^31, 2^32-1]` positive rather than overflowing `Int`.
func read32(p: in slice[Byte], off: in Int): Long {
  p[off].toInt().toLong().shl(24).or(p[off + 1].toInt().toLong().shl(16)).or(p[off + 2].toInt().toLong().shl(8)).or(
    p[off + 3].toInt().toLong()
  )
}

// =============================================================================
// §5. The connection preface (RFC 9113 §3.4).
// =============================================================================
// The 24-octet client connection preface: the ASCII "PRI * HTTP/2.0\r\n\r\nSM"
// followed by "\r\n\r\n". Built byte-by-byte (no string-encoding dependency)
// so the codec stays free of `Std.String`/`Std.Encoding`.
func prefaceByteAt(i: in Int): Int {
  // "PRI * HTTP/2.0" = 0..13, CRLFCRLF = 14..17, "SM" = 18..19, CRLFCRLF = 20..23.
  if i < 14 {
    prefaceLiteralCode(i)
  } else if i == 14 {
    13
  } else if i == 15 {
    10
  } else if i == 16 {
    13
  } else if i == 17 {
    10
  } else if i == 18 {
    83
  } else if i == 19 {
    77
  } else if i == 20 {
    13
  } else if i == 21 {
    10
  } else if i == 22 {
    13
  } else {
    10
  }
}

// The preface's ASCII prefix "PRI * HTTP/2.0" is fixed and pure-ASCII, so a
// per-index code lookup avoids importing `Std.String` just for `charAt`.
// Codes: P=80 R=82 I=73 SP=32 *=42 SP=32 H=72 T=84 T=84 P=80 /=47 2=50 .=46 0=48.
func prefaceLiteralCode(i: in Int): Int {
  val codes: slice[Byte] = [80u8, 82u8, 73u8, 32u8, 42u8, 32u8, 72u8, 84u8, 84u8, 80u8, 47u8, 50u8, 46u8, 48u8]
  codes[i].toInt()
}

/// The 24-octet HTTP/2 client connection preface (RFC 9113 §3.4). A client
/// sends these bytes (immediately followed by its initial `SETTINGS` frame)
/// before any other traffic; a server matches them before reading frames.
@pure
@experimental
pub func connectionPreface(): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < 24 {
    pushByte(acc, prefaceByteAt(i))
    i = i + 1
  }
  acc.toArray()
}

/// True if the first 24 bytes of `bytes` are exactly the connection preface.
/// `false` if `bytes` is shorter than 24 octets or diverges anywhere.
@pure
@experimental
pub func isConnectionPreface(bytes: in slice[Byte]): Bool {
  if bytes.length < 24 {
    return false
  }
  var i = 0
  while i < 24 {
    if bytes[i].toInt() != prefaceByteAt(i) {
      return false
    }
    i = i + 1
  }
  true
}

// =============================================================================
// §6. Frame-header parse/serialize (RFC 9113 §4.1).
// =============================================================================
/// Parse the 9-octet frame header at the front of `bytes`. `None` if fewer
/// than 9 octets are available. The reserved high bit of the stream identifier
/// is masked off (§4.1).
@pure
@experimental
pub func parseFrameHeader(bytes: in slice[Byte]): Option[H2FrameHeader] {
  if bytes.length < 9 {
    None
  } else {
    Some(
      value = H2FrameHeader(
        length = read24(bytes, 0),
        frameType = bytes[3].toInt(),
        flags = bytes[4].toInt(),
        streamId = read31(bytes, 5)
      )
    )
  }
}

/// Serialize a 9-octet frame header. `length` is the payload length that
/// follows; the reserved stream-id bit is written as 0.
@pure
@experimental
pub func serializeFrameHeader(h: in H2FrameHeader): slice[Byte] {
  val acc: List[Byte] = newList()
  push24(acc, h.length)
  pushByte(acc, h.frameType)
  pushByte(acc, h.flags)
  push31(acc, h.streamId)
  acc.toArray()
}

func assembleFrame(frameType: in Int, flags: in Int, streamId: in Int, payload: in slice[Byte]): slice[Byte] {
  val acc: List[Byte] = newList()
  push24(acc, payload.length)
  pushByte(acc, frameType)
  pushByte(acc, flags)
  push31(acc, streamId)
  pushBytes(acc, payload)
  acc.toArray()
}

// =============================================================================
// §7. Priority-field and padding helpers.
// =============================================================================
func parsePriorityFields(p: in slice[Byte], off: in Int): PriorityInfo {
  val exclusive = p[off].toInt().and(128) != 0
  val dep = read31(p, off)
  val weight = p[off + 4].toInt() + 1
  PriorityInfo(exclusive = exclusive, streamDependency = dep, weight = weight)
}

func pushPriorityFields(acc: in List[Byte], prio: in PriorityInfo): Unit {
  val depHi = prio.streamDependency.shr(24).and(127)
  val hi = if prio.exclusive { depHi.or(128) } else { depHi }
  pushByte(acc, hi)
  pushByte(acc, prio.streamDependency.shr(16))
  pushByte(acc, prio.streamDependency.shr(8))
  pushByte(acc, prio.streamDependency)
  pushByte(acc, prio.weight - 1)
}

/// Strip a `PADDED` frame's leading pad-length octet and trailing padding
/// (§6.1). A pad length equal to or exceeding the payload size (leaving no
/// room for the pad-length octet itself) is a connection `PROTOCOL_ERROR`.
func stripPadding(payload: in slice[Byte], padded: in Bool): Result[slice[Byte], FrameError] {
  if not padded {
    Ok(value = payload)
  } else if payload.length < 1 {
    Err(error = mkConnErr(H2ProtocolError, "PADDED frame is missing its pad-length octet"))
  } else {
    val padLen = payload[0].toInt()
    if 1 + padLen > payload.length {
      Err(error = mkConnErr(H2ProtocolError, "pad length meets or exceeds the frame payload (RFC 9113 section 6.1)"))
    } else {
      Ok(value = payload.slice(1, payload.length - padLen))
    }
  }
}

// =============================================================================
// §8. Per-frame-type parsing (RFC 9113 §6).
// =============================================================================
// Each frame type parses in its own function returning `Result[H2Frame,
// FrameError]`, dispatched from `parseFrameBody` by a flat `if`/`else` chain
// on the type code. This mirrors `Std.HttpEngine`'s "flat chain of
// single-purpose helpers" structure, which sidesteps the self-hosted JVM
// backend's inconsistent-stack-map-frame codegen bug on deeply nested match
// arms that differ in how much work they do (#5936).
func parseDataFrame(h: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  if h.streamId == 0 {
    Err(error = mkConnErr(H2ProtocolError, "DATA frame with stream id 0 (RFC 9113 section 6.1)"))
  } else {
    match stripPadding(payload, flagPadded(h.flags)) {
      case Err(e) -> Err(error = e)
      case Ok(data) -> Ok(value = DataFrame(streamId = h.streamId, data = data, endStream = flagEndStream(h.flags)))
    }
  }
}

func parseHeadersFrame(h: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  if h.streamId == 0 {
    Err(error = mkConnErr(H2ProtocolError, "HEADERS frame with stream id 0 (RFC 9113 section 6.2)"))
  } else {
    match stripPadding(payload, flagPadded(h.flags)) {
      case Err(e) -> Err(error = e)
      case Ok(body) -> finishHeadersFrame(h, body)
    }
  }
}

func finishHeadersFrame(h: in H2FrameHeader, body: in slice[Byte]): Result[H2Frame, FrameError] {
  val es = flagEndStream(h.flags)
  val eh = flagEndHeaders(h.flags)
  if flagPriority(h.flags) {
    if body.length < 5 {
      Err(error = mkConnErr(H2FrameSizeError, "HEADERS frame with PRIORITY flag but fewer than 5 priority octets"))
    } else {
      val prio = parsePriorityFields(body, 0)
      val fragment = body.slice(5, body.length)
      Ok(
        value = HeadersFrame(
          streamId = h.streamId,
          headerBlockFragment = fragment,
          endStream = es,
          endHeaders = eh,
          priority = Some(value = prio)
        )
      )
    }
  } else {
    val none: Option[PriorityInfo] = None
    Ok(
      value = HeadersFrame(
        streamId = h.streamId,
        headerBlockFragment = body,
        endStream = es,
        endHeaders = eh,
        priority = none
      )
    )
  }
}

func parsePriorityFrame(h: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  if h.streamId == 0 {
    Err(error = mkConnErr(H2ProtocolError, "PRIORITY frame with stream id 0 (RFC 9113 section 6.3)"))
  } else if payload.length != 5 {
    // §6.3: a PRIORITY frame of a length other than 5 is a stream error.
    Err(error = mkStreamErr(H2FrameSizeError, "PRIORITY frame payload is not exactly 5 octets"))
  } else {
    Ok(value = PriorityFrame(streamId = h.streamId, priority = parsePriorityFields(payload, 0)))
  }
}

func parseRstStreamFrame(h: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  if h.streamId == 0 {
    Err(error = mkConnErr(H2ProtocolError, "RST_STREAM frame with stream id 0 (RFC 9113 section 6.4)"))
  } else if payload.length != 4 {
    Err(error = mkConnErr(H2FrameSizeError, "RST_STREAM frame payload is not exactly 4 octets"))
  } else {
    Ok(value = RstStreamFrame(streamId = h.streamId, errorCode = errorCodeFromLong(read32(payload, 0))))
  }
}

func parseSettingsFrame(h: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  if h.streamId != 0 {
    Err(error = mkConnErr(H2ProtocolError, "SETTINGS frame with a non-zero stream id (RFC 9113 section 6.5)"))
  } else if flagAck(h.flags) {
    if payload.length != 0 {
      Err(error = mkConnErr(H2FrameSizeError, "SETTINGS ACK frame must carry an empty payload (RFC 9113 section 6.5)"))
    } else {
      val empty: List[SettingsParam] = newList()
      Ok(value = SettingsFrame(settings = empty, ack = true))
    }
  } else if payload.length % 6 != 0 {
    Err(
      error = mkConnErr(H2FrameSizeError, "SETTINGS frame payload is not a multiple of 6 octets (RFC 9113 section 6.5)")
    )
  } else {
    Ok(value = SettingsFrame(settings = parseSettingsParams(payload), ack = false))
  }
}

func parseSettingsParams(payload: in slice[Byte]): List[SettingsParam] {
  val params: List[SettingsParam] = newList()
  var off = 0
  while off + 6 <= payload.length {
    val id = settingsIdFromInt(read16(payload, off))
    val value = read32(payload, off + 2)
    params.add(SettingsParam(id = id, value = value))
    off = off + 6
  }
  params
}

func parsePushPromiseFrame(h: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  if h.streamId == 0 {
    Err(error = mkConnErr(H2ProtocolError, "PUSH_PROMISE frame with stream id 0 (RFC 9113 section 6.6)"))
  } else {
    match stripPadding(payload, flagPadded(h.flags)) {
      case Err(e) -> Err(error = e)
      case Ok(body) -> finishPushPromiseFrame(h, body)
    }
  }
}

func finishPushPromiseFrame(h: in H2FrameHeader, body: in slice[Byte]): Result[H2Frame, FrameError] {
  if body.length < 4 {
    Err(
      error = mkConnErr(H2FrameSizeError, "PUSH_PROMISE frame is missing its promised stream id (RFC 9113 section 6.6)")
    )
  } else {
    val promised = read31(body, 0)
    val fragment = body.slice(4, body.length)
    Ok(
      value = PushPromiseFrame(
        streamId = h.streamId,
        promisedStreamId = promised,
        headerBlockFragment = fragment,
        endHeaders = flagEndHeaders(h.flags)
      )
    )
  }
}

func parsePingFrame(h: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  if h.streamId != 0 {
    Err(error = mkConnErr(H2ProtocolError, "PING frame with a non-zero stream id (RFC 9113 section 6.7)"))
  } else if payload.length != 8 {
    Err(error = mkConnErr(H2FrameSizeError, "PING frame payload is not exactly 8 octets (RFC 9113 section 6.7)"))
  } else {
    Ok(value = PingFrame(opaqueData = payload, ack = flagAck(h.flags)))
  }
}

func parseGoAwayFrame(h: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  if h.streamId != 0 {
    Err(error = mkConnErr(H2ProtocolError, "GOAWAY frame with a non-zero stream id (RFC 9113 section 6.8)"))
  } else if payload.length < 8 {
    Err(error = mkConnErr(H2FrameSizeError, "GOAWAY frame payload is shorter than 8 octets (RFC 9113 section 6.8)"))
  } else {
    val lastStreamId = read31(payload, 0)
    val errorCode = errorCodeFromLong(read32(payload, 4))
    val debugData = payload.slice(8, payload.length)
    Ok(value = GoAwayFrame(lastStreamId = lastStreamId, errorCode = errorCode, debugData = debugData))
  }
}

func parseWindowUpdateFrame(h: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  if payload.length != 4 {
    Err(error = mkConnErr(H2FrameSizeError, "WINDOW_UPDATE frame payload is not exactly 4 octets (RFC 9113 section 6.9)"))
  } else {
    val increment = read31(payload, 0)
    if increment == 0 {
      // §6.9: a 0 increment is a stream error, or a connection error when it
      // targets the connection-level flow-control window (stream id 0).
      if h.streamId == 0 {
        Err(error = mkConnErr(H2ProtocolError, "WINDOW_UPDATE with a 0 increment on the connection (RFC 9113 section 6.9)"))
      } else {
        Err(error = mkStreamErr(H2ProtocolError, "WINDOW_UPDATE with a 0 increment on a stream (RFC 9113 section 6.9)"))
      }
    } else {
      Ok(value = WindowUpdateFrame(streamId = h.streamId, windowSizeIncrement = increment))
    }
  }
}

func parseContinuationFrame(h: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  if h.streamId == 0 {
    Err(error = mkConnErr(H2ProtocolError, "CONTINUATION frame with stream id 0 (RFC 9113 section 6.10)"))
  } else {
    Ok(
      value = ContinuationFrame(
        streamId = h.streamId,
        headerBlockFragment = payload,
        endHeaders = flagEndHeaders(h.flags)
      )
    )
  }
}

/// Parse one frame's payload against its already-decoded header. The payload
/// must be exactly `header.length` octets (the streaming decoder guarantees
/// this; a direct caller must slice accordingly). An unrecognized frame type
/// yields `UnknownFrame` rather than an error (§4.1/§5.1 pass-through).
@experimental
pub func parseFrame(header: in H2FrameHeader, payload: in slice[Byte]): Result[H2Frame, FrameError] {
  val t = header.frameType
  if t == typeData() {
    parseDataFrame(header, payload)
  } else if t == typeHeaders() {
    parseHeadersFrame(header, payload)
  } else if t == typePriority() {
    parsePriorityFrame(header, payload)
  } else if t == typeRstStream() {
    parseRstStreamFrame(header, payload)
  } else if t == typeSettings() {
    parseSettingsFrame(header, payload)
  } else if t == typePushPromise() {
    parsePushPromiseFrame(header, payload)
  } else if t == typePing() {
    parsePingFrame(header, payload)
  } else if t == typeGoAway() {
    parseGoAwayFrame(header, payload)
  } else if t == typeWindowUpdate() {
    parseWindowUpdateFrame(header, payload)
  } else if t == typeContinuation() {
    parseContinuationFrame(header, payload)
  } else {
    Ok(value = UnknownFrame(header = header, payload = payload))
  }
}

// =============================================================================
// §9. Per-frame-type serialization (RFC 9113 §6).
// =============================================================================
// As with parsing, each frame type serializes in its own helper so the
// top-level `serializeFrame` match keeps every arm to a single call (#5936).
// No frame is emitted with padding — an unpadded frame is always wire-valid
// (see the module header's "Padding" section).
func serializeDataFrame(streamId: in Int, data: in slice[Byte], endStream: in Bool): slice[Byte] {
  val flags = if endStream { 1 } else { 0 }
  assembleFrame(typeData(), flags, streamId, data)
}

func serializeHeadersFrame(
  streamId: in Int,
  fragment: in slice[Byte],
  endStream: in Bool,
  endHeaders: in Bool,
  priority: in Option[PriorityInfo],
): slice[Byte] {
  var flags = 0
  if endStream {
    flags = flags.or(1)
  }
  if endHeaders {
    flags = flags.or(4)
  }
  val payload: List[Byte] = newList()
  match priority {
    case Some(prio) -> {
      flags = flags.or(32)
      pushPriorityFields(payload, prio)
    }
    case None -> ()
  }
  pushBytes(payload, fragment)
  assembleFrame(typeHeaders(), flags, streamId, payload.toArray())
}

func serializePriorityFrame(streamId: in Int, priority: in PriorityInfo): slice[Byte] {
  val payload: List[Byte] = newList()
  pushPriorityFields(payload, priority)
  assembleFrame(typePriority(), 0, streamId, payload.toArray())
}

func serializeRstStreamFrame(streamId: in Int, errorCode: in H2ErrorCode): slice[Byte] {
  val payload: List[Byte] = newList()
  push32(payload, errorCodeToLong(errorCode))
  assembleFrame(typeRstStream(), 0, streamId, payload.toArray())
}

func serializeSettingsFrame(settings: in List[SettingsParam], ack: in Bool): slice[Byte] {
  if ack {
    val empty: slice[Byte] = []
    assembleFrame(typeSettings(), 1, 0, empty)
  } else {
    val payload: List[Byte] = newList()
    var i = 0
    while i < settings.count {
      val p = settings[i]
      push16(payload, settingsIdToInt(p.id))
      push32(payload, p.value)
      i = i + 1
    }
    assembleFrame(typeSettings(), 0, 0, payload.toArray())
  }
}

func serializePushPromiseFrame(
  streamId: in Int, promisedStreamId: in Int, fragment: in slice[Byte], endHeaders: in Bool
): slice[Byte] {
  val flags = if endHeaders { 4 } else { 0 }
  val payload: List[Byte] = newList()
  push31(payload, promisedStreamId)
  pushBytes(payload, fragment)
  assembleFrame(typePushPromise(), flags, streamId, payload.toArray())
}

func serializePingFrame(opaqueData: in slice[Byte], ack: in Bool): slice[Byte] {
  val flags = if ack { 1 } else { 0 }
  assembleFrame(typePing(), flags, 0, opaqueData)
}

func serializeGoAwayFrame(lastStreamId: in Int, errorCode: in H2ErrorCode, debugData: in slice[Byte]): slice[Byte] {
  val payload: List[Byte] = newList()
  push31(payload, lastStreamId)
  push32(payload, errorCodeToLong(errorCode))
  pushBytes(payload, debugData)
  assembleFrame(typeGoAway(), 0, 0, payload.toArray())
}

func serializeWindowUpdateFrame(streamId: in Int, windowSizeIncrement: in Int): slice[Byte] {
  val payload: List[Byte] = newList()
  push31(payload, windowSizeIncrement)
  assembleFrame(typeWindowUpdate(), 0, streamId, payload.toArray())
}

func serializeContinuationFrame(streamId: in Int, fragment: in slice[Byte], endHeaders: in Bool): slice[Byte] {
  val flags = if endHeaders { 4 } else { 0 }
  assembleFrame(typeContinuation(), flags, streamId, fragment)
}

func serializeUnknownFrame(header: in H2FrameHeader, payload: in slice[Byte]): slice[Byte] {
  assembleFrame(header.frameType, header.flags, header.streamId, payload)
}

/// Serialize a complete frame (9-octet header + payload) to wire bytes. A
/// `PingFrame`'s opaque data must be exactly 8 octets (§6.7).
///
/// # Contract
/// A `PingFrame`'s opaque data is exactly 8 octets — this is a programmer
/// error (a misconstructed frame), not wire content, so it is a `requires:`.
@experimental
pub func serializeFrame(frame: in H2Frame): slice[Byte]
  requires: pingDataWellSized(frame)
{
  match frame {
    case DataFrame(streamId, data, endStream) -> serializeDataFrame(streamId, data, endStream)
    case HeadersFrame(streamId, fragment, endStream, endHeaders, priority) -> serializeHeadersFrame(streamId, fragment, endStream, endHeaders, priority)
    case PriorityFrame(streamId, priority) -> serializePriorityFrame(streamId, priority)
    case RstStreamFrame(streamId, errorCode) -> serializeRstStreamFrame(streamId, errorCode)
    case SettingsFrame(settings, ack) -> serializeSettingsFrame(settings, ack)
    case PushPromiseFrame(streamId, promisedStreamId, fragment, endHeaders) -> serializePushPromiseFrame(streamId, promisedStreamId, fragment, endHeaders)
    case PingFrame(opaqueData, ack) -> serializePingFrame(opaqueData, ack)
    case GoAwayFrame(lastStreamId, errorCode, debugData) -> serializeGoAwayFrame(lastStreamId, errorCode, debugData)
    case WindowUpdateFrame(streamId, windowSizeIncrement) -> serializeWindowUpdateFrame(streamId, windowSizeIncrement)
    case ContinuationFrame(streamId, fragment, endHeaders) -> serializeContinuationFrame(streamId, fragment, endHeaders)
    case UnknownFrame(header, payload) -> serializeUnknownFrame(header, payload)
  }
}

/// A `PingFrame`'s opaque data must be 8 octets (§6.7); every other frame is
/// trivially well-sized for the `serializeFrame` contract.
@pure
@experimental
pub func pingDataWellSized(frame: in H2Frame): Bool {
  match frame {
    case PingFrame(opaqueData, _) -> opaqueData.length == 8
    case _ -> true
  }
}

// =============================================================================
// §10. The streaming frame decoder (sans-IO, boundary-agnostic).
// =============================================================================
/// The default `SETTINGS_MAX_FRAME_SIZE` (RFC 9113 §6.5.2): 2^14 octets. Every
/// endpoint must accept a frame this large before any `SETTINGS` negotiation.
@pure
@experimental
pub func defaultMaxFrameSize(): Int {
  16384
}

/// Per-connection frame-decoder state: the unconsumed input buffer, the frame
/// size ceiling to enforce (`SETTINGS_MAX_FRAME_SIZE`, §4.2), whether the
/// 24-octet connection preface is still expected, and a poison flag set once a
/// connection-level error is emitted. Like `Std.HttpEngine.Connection`, this
/// is a **linear** value: never reuse the decoder passed into `feedFrames` —
/// always rebind to `result.decoder`.
@experimental
pub record FrameDecoder {
  buf: slice[Byte]
  maxFrameSize: Int
  awaitingPreface: Bool
  fatal: Bool
}

/// A fresh decoder. Set `expectPreface` for a server-side reader (the peer
/// sends the §3.4 preface first); clear it for a client-side reader (the peer
/// sends frames only). Starts at the default 16 KiB frame-size ceiling.
@pure
@experimental
pub func newFrameDecoder(expectPreface: in Bool): FrameDecoder {
  val emptyBuf: slice[Byte] = []
  FrameDecoder(buf = emptyBuf, maxFrameSize = defaultMaxFrameSize(), awaitingPreface = expectPreface, fatal = false)
}

/// A decoder with an explicit frame-size ceiling — used once the peer's
/// `SETTINGS_MAX_FRAME_SIZE` has been received (the FSM, #5888, drives this).
@pure
@experimental
pub func newFrameDecoderWithMaxSize(expectPreface: in Bool, maxFrameSize: in Int): FrameDecoder {
  val emptyBuf: slice[Byte] = []
  FrameDecoder(buf = emptyBuf, maxFrameSize = maxFrameSize, awaitingPreface = expectPreface, fatal = false)
}

/// Return a copy of `decoder` with a new frame-size ceiling. The FSM calls
/// this after applying a peer `SETTINGS` frame; the codec only enforces the
/// value, it never decides it.
@pure
@experimental
pub func withMaxFrameSize(decoder: in FrameDecoder, maxFrameSize: in Int): FrameDecoder {
  FrameDecoder(
    buf = decoder.buf,
    maxFrameSize = maxFrameSize,
    awaitingPreface = decoder.awaitingPreface,
    fatal = decoder.fatal
  )
}

/// True once a connection-level `FrameError` has been emitted; `feedFrames`
/// refuses to run again (`requires: not isDecoderFailed(decoder)`).
@pure
@experimental
pub func isDecoderFailed(decoder: in FrameDecoder): Bool {
  decoder.fatal
}

/// Every event `feedFrames` can produce.
///
///   - `FrameNeedMore` — no complete frame (or preface) is buffered yet.
///   - `PrefaceReceived` — the 24-octet connection preface was consumed (only
///     ever emitted by a decoder created with `expectPreface = true`).
///   - `FrameDecoded(frame)` — one complete, well-formed frame was parsed.
///   - `FrameFailed(error)` — a malformed/oversized frame. A
///     connection-level error additionally poisons the decoder.
@experimental
pub union FrameDecodeEvent {
  case FrameNeedMore
  case PrefaceReceived
  case FrameDecoded(frame: H2Frame)
  case FrameFailed(error: FrameError)
}

/// What `feedFrames` returns: the decoder's next state plus every event the
/// fed bytes produced. Always at least one event (an idle call yields
/// `[FrameNeedMore]`), mirroring `Std.HttpEngine.FeedResult`.
@experimental
pub record FrameFeedResult {
  decoder: FrameDecoder
  events: List[FrameDecodeEvent]
}

func failDecoder(state: inout FrameDecoder, events: in List[FrameDecodeEvent], err: in FrameError): Unit {
  state.fatal = true
  events.add(FrameFailed(error = err))
}

func stepPreface(state: inout FrameDecoder, events: in List[FrameDecodeEvent]): Bool {
  val n = state.buf.length
  val cmp = if n < 24 { n } else { 24 }
  var i = 0
  while i < cmp {
    if state.buf[i].toInt() != prefaceByteAt(i) {
      failDecoder(state, events, mkConnErr(H2ProtocolError, "invalid HTTP/2 connection preface (RFC 9113 section 3.4)"))
      return true
    }
    i = i + 1
  }
  if n < 24 {
    false
  } else {
    // Binding the slice before assigning `state.buf` avoids the self-hosted
    // JVM `state.buf = state.buf.slice(...)` inconsistent-stack-map-frame bug
    // (#5936); `Std.HttpEngine` routes every such site through a local too.
    val remaining = state.buf.slice(24, n)
    state.buf = remaining
    state.awaitingPreface = false
    events.add(PrefaceReceived)
    true
  }
}

func stepFrame(state: inout FrameDecoder, events: in List[FrameDecodeEvent]): Bool {
  if state.buf.length < 9 {
    false
  } else {
    val length = read24(state.buf, 0)
    if length > state.maxFrameSize {
      // §4.2: a frame exceeding SETTINGS_MAX_FRAME_SIZE is FRAME_SIZE_ERROR.
      // Detected from the header alone so an attacker's declared-huge frame is
      // never buffered; the payload is left unconsumed and the decoder is
      // poisoned.
      failDecoder(
        state,
        events,
        mkConnErr(H2FrameSizeError, "frame length exceeds SETTINGS_MAX_FRAME_SIZE (RFC 9113 section 4.2)")
      )
      true
    } else {
      stepFrameWithLength(state, events, length)
    }
  }
}

func stepFrameWithLength(state: inout FrameDecoder, events: in List[FrameDecodeEvent], length: in Int): Bool {
  val total = 9 + length
  if state.buf.length < total {
    false
  } else {
    val header = H2FrameHeader(
      length = length,
      frameType = state.buf[3].toInt(),
      flags = state.buf[4].toInt(),
      streamId = read31(state.buf, 5)
    )
    val payload = state.buf.slice(9, total)
    val remaining = state.buf.slice(total, state.buf.length)
    state.buf = remaining
    match parseFrame(header, payload) {
      case Ok(frame) -> {
        events.add(FrameDecoded(frame = frame))
        true
      }
      case Err(e) -> {
        events.add(FrameFailed(error = e))
        if e.connectionError {
          state.fatal = true
        }
        true
      }
    }
  }
}

func driveDecoder(state: inout FrameDecoder, bytes: in slice[Byte]): List[FrameDecodeEvent] {
  val combined = state.buf.concat(bytes)
  state.buf = combined
  val events: List[FrameDecodeEvent] = newList()
  var progress = true
  while progress {
    if state.fatal {
      progress = false
    } else if state.awaitingPreface {
      progress = stepPreface(state, events)
    } else {
      progress = stepFrame(state, events)
    }
  }
  if events.count == 0 {
    events.add(FrameNeedMore)
  }
  events
}

/// Feed newly-received bytes into `decoder`, returning its next state plus
/// every event (`FrameDecoded`/`PrefaceReceived`/`FrameFailed`/`FrameNeedMore`)
/// the bytes produced. A frame delivered across several `feedFrames` calls is
/// buffered until complete, so the caller may chop the wire stream however the
/// transport hands it over. See the linear-value note on `FrameDecoder`.
///
/// # Contract
/// Calling `feedFrames` after `isDecoderFailed(decoder)` is a programmer error
/// — a connection-level `FrameError` has no defined next state — so it is a
/// `requires:` rather than another `FrameFailed` event.
@experimental
pub func feedFrames(decoder: in FrameDecoder, bytes: in slice[Byte]): FrameFeedResult
  requires: not isDecoderFailed(decoder)
{
  var state = decoder
  val events = driveDecoder(state, bytes)
  FrameFeedResult(decoder = state, events = events)
}
