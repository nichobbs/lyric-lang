//! ws_frame.l — pure-Lyric RFC 6455 WebSocket frame codec.
//!
//! Sans-IO, like `Std.HttpEngine` (docs/62-jsonrpc-mcp.md §6): `feedFrames`
//! consumes raw bytes handed to it by a transport driver and returns typed
//! events; `encodeFrame` (and the per-opcode convenience wrappers) serialize
//! an outbound frame. Target-independent — no `extern type`, no kernel file —
//! so a future JVM/native kernel could share this module unchanged, the same
//! way `Std.HttpEngine` is shared across the dotnet/JVM/native HTTP
//! transports.
//!
//! Implements RFC 6455 §5: FIN/RSV/opcode/mask/payload-length (7/16/64-bit),
//! client-to-server masking enforcement (a server MUST reject an unmasked
//! frame — §5.1), control-frame framing rules (unfragmented, <=125-byte
//! payload — §5.5), fragmented-message reassembly capped by
//! `maxMessageSizeBytes`, close-frame status-code validation (§7.4), and
//! UTF-8 validation of reassembled text messages (§8.1). A server never
//! masks outbound frames (§5.1), so `encodeFrame` always emits mask bit 0.
//!
//! `FrameDecoder` is a linear value exactly like `Std.HttpEngine.Connection`:
//! `feedFrames` takes one by `in` and returns a new one inside
//! `FrameFeedResult`; never reuse the value passed into `feedFrames` after
//! the call.
@runtime_checked
package Ws.Frame

import Std.Core
import Std.Collections
import Std.Encoding

// =============================================================================
// §1. Opcodes (RFC 6455 §11.7).
// =============================================================================
val opContinuation: Int = 0

val opText: Int = 1

val opBinary: Int = 2

val opClose: Int = 8

val opPing: Int = 9

val opPong: Int = 10

func isControlOpcode(op: in Int): Bool {
  op == opClose or op == opPing or op == opPong
}

func isKnownOpcode(op: in Int): Bool {
  op == opContinuation or op == opText or op == opBinary or isControlOpcode(op)
}

// =============================================================================
// §2. Events.
// =============================================================================
/// One decoded WebSocket-level event. `FeMessage` carries a fully
/// reassembled message (a single unfragmented data frame, or the
/// concatenation of a fragmented sequence) — `isText` selects which framing
/// it arrived as (a text message's `payload` is already known-valid UTF-8;
/// `Ws.Frame` validated it before emitting the event).
@stable(since = "0.1")
pub union WsFrameEvent {
  case FeMessage(isText: Bool, payload: slice[Byte])
  case FeClose(code: Int, reason: String)
  case FePing(payload: slice[Byte])
  case FePong(payload: slice[Byte])
  case FeProtocolError(message: String)
}

// =============================================================================
// §3. Decoder state machine.
// =============================================================================
/// Internal fragmented-message accumulator. Never exposed — see
/// `FrameDecoder`'s note on why this is nonetheless a plain `record`, not
/// `opaque` (mirrors `Std.HttpEngine.Connection`'s #5937 workaround).
record FragState {
  active: Bool
  isText: Bool
  acc: List[Byte]
}

func freshFrag(): FragState {
  FragState(active = false, isText = false, acc = newList())
}

/// Per-connection frame-decoder state: the unconsumed input buffer, the
/// in-progress fragmented-message accumulator (if any), the configured
/// max-message-size cap, and whether a fatal protocol violation has already
/// been reported. Plain `record`, not `opaque`, for the same self-hosted JVM
/// backend reason `Std.HttpEngine.Connection` documents (#5937): a
/// `slice[Byte]`-typed field on an `opaque type`, accessed `inout` within the
/// declaring package, mis-resolves its field descriptor on that backend.
/// Treat every field as private; construct only via `newFrameDecoder`,
/// observe only via `isFrameDecoderFailed`/`feedFrames`.
@experimental
pub record FrameDecoder {
  maxMessageSizeBytes: Int
  buf: slice[Byte]
  frag: FragState
  failed: Bool
}

func emptyBytes(): slice[Byte] {
  val e: slice[Byte] = []
  e
}

/// A fresh decoder with no buffered input, ready to parse the first frame.
@pure
@experimental
pub func newFrameDecoder(maxMessageSizeBytes: in Int): FrameDecoder
  requires: maxMessageSizeBytes > 0
{
  FrameDecoder(maxMessageSizeBytes = maxMessageSizeBytes, buf = emptyBytes(), frag = freshFrag(), failed = false)
}

/// True once a `FeProtocolError` has been emitted for this decoder; the FSM
/// has no defined next state, so `feedFrames` refuses to run again.
@pure
@experimental
pub func isFrameDecoderFailed(state: in FrameDecoder): Bool {
  state.failed
}

/// What `feedFrames` returns: the decoder's next state plus every event
/// produced by the bytes just fed (possibly empty — unlike
/// `Std.HttpEngine.FeedResult`, an idle call with no complete frame yet
/// legitimately yields zero events; there is no `NeedMore` event here since
/// callers drive their own read loop and don't need a per-call sentinel).
@experimental
pub record FrameFeedResult {
  state: FrameDecoder
  events: List[WsFrameEvent]
}

// =============================================================================
// §4. Byte-level helpers.
// =============================================================================
func appendBytesToList(acc: in List[Byte], bytes: in slice[Byte]): Unit {
  var i = 0
  while i < bytes.length {
    acc.add(bytes[i])
    i = i + 1
  }
}

func pushByte(acc: in List[Byte], v: in Int): Unit {
  acc.add(v.and(255).toByte())
}

/// Append a 64-bit big-endian unsigned value (the 8-byte extended payload
/// length, RFC 6455 §5.2). `v` is always non-negative here (a payload
/// length), so the top bit is always 0, satisfying the spec's "most
/// significant bit MUST be 0" requirement for values this codec emits.
func push64(acc: in List[Byte], v: in Long): Unit {
  pushByte(acc, v.shr(56).and(255i64).toInt())
  pushByte(acc, v.shr(48).and(255i64).toInt())
  pushByte(acc, v.shr(40).and(255i64).toInt())
  pushByte(acc, v.shr(32).and(255i64).toInt())
  pushByte(acc, v.shr(24).and(255i64).toInt())
  pushByte(acc, v.shr(16).and(255i64).toInt())
  pushByte(acc, v.shr(8).and(255i64).toInt())
  pushByte(acc, v.and(255i64).toInt())
}

func read16(p: in slice[Byte], off: in Int): Int {
  p[off].toInt().shl(8).or(p[off + 1].toInt())
}

/// Read a 64-bit big-endian unsigned value starting at `off`. The MSB
/// (`p[off]`'s top bit) must already have been validated as 0 by the caller
/// (RFC 6455 §5.2) — this reader trusts that and never produces a negative
/// `Long`.
func read64(p: in slice[Byte], off: in Int): Long {
  p[off].toInt().toLong().shl(56).or(p[off + 1].toInt().toLong().shl(48)).or(p[off + 2].toInt().toLong().shl(40)).or(p[off + 3].toInt().toLong().shl(32)).or(p[off + 4].toInt().toLong().shl(24)).or(p[off + 5].toInt().toLong().shl(16)).or(p[off + 6].toInt().toLong().shl(8)).or(
    p[off + 7].toInt().toLong()
  )
}

/// Unmask `payload` in place against the 4-byte client masking key (RFC 6455
/// §5.3): `unmasked[i] = payload[i] XOR key[i mod 4]`.
func unmaskPayload(payload: in slice[Byte], key: in slice[Byte]): slice[Byte] {
  val result: List[Byte] = newList()
  var i = 0
  while i < payload.length {
    result.add(payload[i].toInt().xor(key[i % 4].toInt()).and(255).toByte())
    i = i + 1
  }
  result.toArray()
}

// =============================================================================
// §5. Frame-header parsing.
// =============================================================================
/// Outcome of trying to parse one complete frame (header + payload) out of a
/// buffer.
union ParsedFrame {
  case PfNeedMore
  case PfError(message: String)
  case PfFrame(fin: Bool, opcode: Int, payload: slice[Byte], rest: slice[Byte])
}

// Parses the length field (7-bit inline, or the 16-bit / 64-bit extended
// forms) starting at byte 1, returning the payload length and the offset of
// the masking key (== the total non-payload header length, since every
// client frame this server accepts is masked). `NeedMore` when the buffer
// doesn't yet hold the extended-length bytes.
union LenParse {
  case LpNeedMore
  case LpError(message: String)
  case LpOk(payloadLen: Long, keyOffset: Int)
}

func parseLength(buf: in slice[Byte], lenField: in Int): LenParse {
  if lenField <= 125 {
    LpOk(payloadLen = lenField.toLong(), keyOffset = 2)
  } else if lenField == 126 {
    if buf.length < 4 {
      LpNeedMore
    } else {
      LpOk(payloadLen = read16(buf, 2).toLong(), keyOffset = 4)
    }
  } else {
    // lenField == 127: 8-byte extended length.
    if buf.length < 10 {
      LpNeedMore
    } else if buf[2].toInt() >= 128 {
      LpError(message = "64-bit payload length has its reserved most-significant bit set (RFC 6455 5.2)")
    } else {
      LpOk(payloadLen = read64(buf, 2), keyOffset = 10)
    }
  }
}

func tryParseFrame(buf: in slice[Byte], maxMessageSizeBytes: in Int): ParsedFrame {
  if buf.length < 2 {
    return PfNeedMore
  }
  val b0 = buf[0].toInt()
  val b1 = buf[1].toInt()
  val fin = b0.and(128) != 0
  val rsv = b0.shr(4).and(7)
  if rsv != 0 {
    return PfError(message = "RSV bits must be zero (no WebSocket extensions negotiated)")
  }
  val opcode = b0.and(15)
  if not isKnownOpcode(opcode) {
    return PfError(message = "unknown/reserved WebSocket opcode " + opcode.toString())
  }
  val masked = b1.and(128) != 0
  if not masked {
    return PfError(message = "client frame must be masked (RFC 6455 5.1)")
  }
  val lenField = b1.and(127)
  match parseLength(buf, lenField) {
    case LpNeedMore -> PfNeedMore
    case LpError(msg) -> PfError(message = msg)
    case LpOk(payloadLenL, keyOffset) -> {
      if isControlOpcode(opcode) {
        if not fin {
          return PfError(message = "control frames must not be fragmented (RFC 6455 5.5)")
        }
        if payloadLenL > 125i64 {
          return PfError(message = "control frame payload exceeds 125 bytes (RFC 6455 5.5)")
        }
      }
      if payloadLenL > maxMessageSizeBytes.toLong() {
        return PfError(message = "frame payload exceeds the configured max message size")
      }
      val payloadLen = payloadLenL.toInt()
      val payloadStart = keyOffset + 4
      val totalLen = payloadStart + payloadLen
      if buf.length < totalLen {
        return PfNeedMore
      }
      val maskKey = buf.slice(keyOffset, keyOffset + 4)
      val maskedPayload = buf.slice(payloadStart, totalLen)
      val payload = unmaskPayload(maskedPayload, maskKey)
      val rest = buf.slice(totalLen, buf.length)
      PfFrame(fin = fin, opcode = opcode, payload = payload, rest = rest)
    }
  }
}

// =============================================================================
// §6. Close-frame payload (RFC 6455 §5.5.1 / §7.4).
// =============================================================================
// Close codes an endpoint MUST NOT set on the wire (they exist only to
// represent internal/abnormal states to local code): 1004 (reserved),
// 1005 (No Status Rcvd — used only to report an empty Close frame locally),
// 1006 (Abnormal Closure — used only to report a connection drop with no
// Close frame at all), 1015 (TLS handshake failure — not applicable to an
// already-established WebSocket connection).
func isReservedCloseCode(code: in Int): Bool {
  code == 1004 or code == 1005 or code == 1006 or code == 1015
}

func isValidCloseCode(code: in Int): Bool {
  if isReservedCloseCode(code) {
    false
  } else {
    code >= 1000 and code <= 4999
  }
}

record ClosePayload {
  code: Int
  reason: String
}

func parseClosePayload(payload: in slice[Byte]): Result[ClosePayload, String] {
  if payload.length == 0 {
    Ok(value = ClosePayload(code = 1005, reason = ""))
  } else if payload.length == 1 {
    Err(error = "close frame payload must be empty or at least 2 bytes (RFC 6455 5.5.1)")
  } else {
    val code = read16(payload, 0)
    if not isValidCloseCode(code) {
      Err(error = "close frame carries an invalid status code " + code.toString() + " (RFC 6455 7.4)")
    } else {
      val reasonBytes = payload.slice(2, payload.length)
      match tryDecodeUtf8(reasonBytes) {
        case Some(reason) -> Ok(value = ClosePayload(code = code, reason = reason))
        case None -> Err(error = "close frame reason is not valid UTF-8 (RFC 6455 5.5.1)")
      }
    }
  }
}

/// Encode a close-frame payload (2-byte big-endian code + UTF-8 reason). Used
/// by both the outbound `encodeClose` and a kernel echoing a peer's close
/// code back.
@stable(since = "0.1")
pub func encodeClosePayload(code: in Int, reason: in String): slice[Byte] {
  val acc: List[Byte] = newList()
  pushByte(acc, code.shr(8).and(255))
  pushByte(acc, code.and(255))
  appendBytesToList(acc, encodeUtf8(reason))
  acc.toArray()
}

// =============================================================================
// §7. Fragment dispatch (the core `feedFrames` loop body).
// =============================================================================
record DispatchOutcome {
  frag: FragState
  failed: Bool
}

func emitDataFrame(events: in List[WsFrameEvent], isText: in Bool, payload: in slice[Byte]): Bool {
  if isText {
    match tryDecodeUtf8(payload) {
      case Some(_) -> {
        events.add(FeMessage(isText = true, payload = payload))
        false
      }
      case None -> {
        events.add(FeProtocolError(message = "text frame payload is not valid UTF-8 (RFC 6455 8.1)"))
        true
      }
    }
  } else {
    events.add(FeMessage(isText = false, payload = payload))
    false
  }
}

func dispatchFrame(
  events: in List[WsFrameEvent],
  frag: in FragState,
  maxMessageSizeBytes: in Int,
  fin: in Bool,
  opcode: in Int,
  payload: in slice[Byte],
): DispatchOutcome {
  if opcode == opClose {
    match parseClosePayload(payload) {
      case Ok(cp) -> {
        events.add(FeClose(code = cp.code, reason = cp.reason))
        DispatchOutcome(frag = frag, failed = true)
      }
      case Err(msg) -> {
        events.add(FeProtocolError(message = msg))
        DispatchOutcome(frag = frag, failed = true)
      }
    }
  } else if opcode == opPing {
    events.add(FePing(payload = payload))
    DispatchOutcome(frag = frag, failed = false)
  } else if opcode == opPong {
    events.add(FePong(payload = payload))
    DispatchOutcome(frag = frag, failed = false)
  } else if opcode == opText or opcode == opBinary {
    if frag.active {
      events.add(FeProtocolError(message = "new data frame received while a fragmented message is still in progress"))
      DispatchOutcome(frag = frag, failed = true)
    } else if fin {
      val bad = emitDataFrame(events, opcode == opText, payload)
      DispatchOutcome(frag = frag, failed = bad)
    } else {
      val newFrag: List[Byte] = newList()
      appendBytesToList(newFrag, payload)
      DispatchOutcome(frag = FragState(active = true, isText = opcode == opText, acc = newFrag), failed = false)
    }
  } else if opcode == opContinuation {
    if not frag.active {
      events.add(FeProtocolError(message = "continuation frame received with no fragmented message in progress"))
      DispatchOutcome(frag = frag, failed = true)
    } else if frag.acc.count + payload.length > maxMessageSizeBytes {
      events.add(FeProtocolError(message = "reassembled fragmented message exceeds the configured max message size"))
      DispatchOutcome(frag = frag, failed = true)
    } else {
      appendBytesToList(frag.acc, payload)
      if fin {
        val bad = emitDataFrame(events, frag.isText, frag.acc.toArray())
        DispatchOutcome(frag = freshFrag(), failed = bad)
      } else {
        DispatchOutcome(frag = frag, failed = false)
      }
    }
  } else {
    // Unreachable: `tryParseFrame` already rejects unknown opcodes.
    events.add(FeProtocolError(message = "unhandled opcode " + opcode.toString()))
    DispatchOutcome(frag = frag, failed = true)
  }
}

/// Feed newly-read transport bytes into the decoder, returning the decoder's
/// next state plus every event the bytes produced (parses as many complete
/// frames as `state.buf ++ bytes` holds; any trailing partial frame is
/// retained in the returned state's buffer for the next call).
@experimental
pub func feedFrames(state: in FrameDecoder, bytes: in slice[Byte]): FrameFeedResult
  requires: not state.failed
{
  var working = state.buf.concat(bytes)
  var frag = state.frag
  var failed = false
  val events: List[WsFrameEvent] = newList()
  var more = true
  while more and not failed {
    match tryParseFrame(working, state.maxMessageSizeBytes) {
      case PfNeedMore -> {
        more = false
      }
      case PfError(msg) -> {
        events.add(FeProtocolError(message = msg))
        failed = true
      }
      case PfFrame(fin, opcode, payload, rest) -> {
        working = rest
        val outcome = dispatchFrame(events, frag, state.maxMessageSizeBytes, fin, opcode, payload)
        frag = outcome.frag
        failed = outcome.failed
      }
    }
  }
  val newState = FrameDecoder(
    maxMessageSizeBytes = state.maxMessageSizeBytes,
    buf = working,
    frag = frag,
    failed = failed
  )
  FrameFeedResult(state = newState, events = events)
}

// =============================================================================
// §8. Encoding (server -> client; always unmasked, RFC 6455 5.1).
// =============================================================================
/// Encode one unmasked frame with the given opcode/FIN/payload. Exposed
/// (rather than kept private behind the per-opcode wrappers below) so a
/// caller that needs a fragmented outbound message — not currently exercised
/// by `Ws.Kernel.Net`, which only ever sends single-frame messages — can
/// build one directly (`fin = false` for all but the last fragment,
/// `opContinuation` isn't named here as a `pub val` since it's an internal
/// wire detail; use `encodeFrame(Ws.Frame.opcodeContinuation(), ...)`).
@stable(since = "0.1")
pub func encodeFrame(opcode: in Int, fin: in Bool, payload: in slice[Byte]): slice[Byte] {
  val acc: List[Byte] = newList()
  val b0 = (if fin { 128 } else { 0 }).or(opcode.and(15))
  pushByte(acc, b0)
  val len = payload.length
  if len <= 125 {
    pushByte(acc, len)
  } else if len <= 65535 {
    pushByte(acc, 126)
    pushByte(acc, len.shr(8).and(255))
    pushByte(acc, len.and(255))
  } else {
    pushByte(acc, 127)
    push64(acc, len.toLong())
  }
  appendBytesToList(acc, payload)
  acc.toArray()
}

/// The `Continuation` opcode value, for a caller building a fragmented
/// outbound message via `encodeFrame` directly.
@stable(since = "0.1")
pub func opcodeContinuation(): Int {
  opContinuation
}

@stable(since = "0.1")
pub func encodeText(payload: in slice[Byte]): slice[Byte] {
  encodeFrame(opText, true, payload)
}

@stable(since = "0.1")
pub func encodeBinary(payload: in slice[Byte]): slice[Byte] {
  encodeFrame(opBinary, true, payload)
}

@stable(since = "0.1")
pub func encodePing(payload: in slice[Byte]): slice[Byte] {
  encodeFrame(opPing, true, payload)
}

@stable(since = "0.1")
pub func encodePong(payload: in slice[Byte]): slice[Byte] {
  encodeFrame(opPong, true, payload)
}

/// Encode a Close frame carrying `code`/`reason`.
@stable(since = "0.1")
pub func encodeClose(code: in Int, reason: in String): slice[Byte] {
  encodeFrame(opClose, true, encodeClosePayload(code, reason))
}
