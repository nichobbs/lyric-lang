//! std/http_h2conn.l — pure-Lyric, sans-IO HTTP/2 connection and stream
//! state machine with flow control (RFC 9113 §3/§5/§6, D128; phase 4.3 of
//! epic #5874, issue #5888).
//!
//! `Std.HttpEngine.H2Conn` is the top of the pure-Lyric HTTP/2 server stack.
//! It composes the two shipped building blocks — the frame codec
//! (`Std.HttpEngine.H2Frame`, #5887) and HPACK header compression
//! (`Std.HttpEngine.Hpack`, #5886) — into a single connection- and
//! stream-level finite state machine. Like every other layer of the engine
//! it is **sans-IO**: `feed` consumes `slice[Byte]` chunks handed to it by a
//! transport driver and returns typed `H2Event`s plus a `slice[Byte]` of
//! *outbound* control frames the driver must write back; it never touches a
//! socket. This split (precedent: `Std.HttpEngine` for HTTP/1.1, and the
//! `Std.Xml`/`Std.Yaml` pure-Lyric parsers, D065) makes the whole FSM
//! exhaustively unit-testable with zero network I/O and reusable, unchanged,
//! by the .NET, JVM, and native transports (docs/61 decision 6/8).
//!
//! No `extern type`, no `import extern`, no kernel file: every byte here is
//! plain Lyric computation over `slice[Byte]`/`Int`/`Long`. Only
//! `Std.Core`/`Std.Collections` and the two sibling engine packages are
//! imported.
//!
//! ## Scope (issue #5888)
//!
//! This is the SERVER-side connection/stream FSM. It implements, per
//! RFC 9113:
//!
//!   - the §3.4 connection-preface exchange (the 24-octet client preface is
//!     matched by the frame decoder; the server's initial `SETTINGS` frame is
//!     produced by `serverInitialFrame`);
//!   - `SETTINGS` negotiation and acknowledgement (§6.5): a received peer
//!     `SETTINGS` frame is validated, applied, and acknowledged automatically
//!     (the ACK is appended to the outbound bytes);
//!   - the per-stream lifecycle FSM (§5.1): idle → open → half-closed
//!     (remote/local) → closed, driven by HEADERS / DATA / RST_STREAM and the
//!     END_STREAM flag, with illegal transitions rejected as the RFC's
//!     stream- or connection-level errors;
//!   - HEADERS + CONTINUATION reassembly (§6.2/§6.10) feeding the HPACK
//!     decoder, including the "a header block must be decoded even for a
//!     refused stream, to keep the compression context in sync" rule (§4.3);
//!   - connection- and per-stream flow control (§6.9) on **both** the receive
//!     side (a peer that overruns a window we advertised is a
//!     `FLOW_CONTROL_ERROR`) and the send side (`sendData` refuses to exceed
//!     the peer's advertised window; a peer `WINDOW_UPDATE` replenishes it),
//!     including the `SETTINGS_INITIAL_WINDOW_SIZE`-change window adjustment
//!     (§6.9.2);
//!   - `PING` (§6.7): a non-ack `PING` is answered with a `PING` ACK
//!     automatically;
//!   - `GOAWAY` (§6.8): a received `GOAWAY` is surfaced; `sendGoAway` produces
//!     a server-initiated one for graceful shutdown;
//!   - the RFC's error classification (§5.4): a connection error appends a
//!     `GOAWAY` and poisons the connection; a stream error appends a
//!     `RST_STREAM` and closes just that stream.
//!
//! Deliberately **out of scope** (per the issue and RFC 9113): no server push
//! (`PUSH_PROMISE` received by a server is a `PROTOCOL_ERROR`), and no
//! RFC 7540 priority tree (RFC 9113 §5.3.2 deprecates it — `PRIORITY` frames
//! are accepted and ignored). ALPN wiring and the end-to-end .NET transport
//! are issue #5889, not this sans-IO layer.
//!
//! ## Event vocabulary
//!
//! `feed(conn, bytes)` returns an `H2FeedResult { conn, events, outbound }`:
//! a next connection value, every semantic event the bytes produced, and the
//! control frames (SETTINGS ACK, PING ACK, WINDOW_UPDATE reclaim, RST_STREAM,
//! GOAWAY) the FSM generated in response, already serialized and ready to
//! write. Events never carry control frames the driver must serialize itself
//! — those are always in `outbound`. As with the sibling engines, a `feed`
//! that produced no semantic event yields exactly `[H2NeedMore]` so a caller
//! never special-cases an empty list.
//!
//! ## Connection lifecycle
//!
//! A `H2Connection` is a reference value threaded through `feed` and the
//! send/grant helpers, mirroring `Std.HttpEngine.Connection`. Its fields are
//! FSM internals — construct one only via `newServerConnection`, and observe
//! it only through the query functions (`streamState`, `connectionSendWindow`,
//! …) and the events `feed` returns. Once a connection-level error is emitted
//! `isFailed(conn)` is true and `feed` refuses to run again
//! (`requires: not isFailed(conn)`): the FSM has no defined next state.
//!
//! ## Bundle-unique naming
//!
//! Every union case and type this package introduces is prefixed (`H2…`,
//! `S…`, `Settings…` are reused from `H2Frame`) so it can never collide, in a
//! bundle that imports several `Std.HttpEngine.*` packages at once, with a
//! same-spelled case elsewhere (the cross-package bare-enum-case resolution
//! hazard `Std.HttpEngine`'s `Http1_1` rename and `H2Frame`'s `H2…` error
//! codes already document — #5903/#5995).
//!
//! ## Known bounded characteristics (tracked, not silent)
//!
//!   - **Inbound DATA flow-control counts the decoded (unpadded) payload.**
//!     The frame codec (#5887) strips DATA padding before this layer sees it,
//!     so a padded inbound DATA frame is flow-controlled by its visible
//!     payload length, not its on-wire length. Request bodies are essentially
//!     never padded (padding is a sender-chosen traffic-analysis mitigation),
//!     and this server emits none, so this is exact for all traffic it
//!     realistically sees; a padding-exact variant would require the frame
//!     layer to surface the on-wire frame length. Tracked as #6063.
//!   - **Closed streams are retained for the connection's lifetime** so a late
//!     WINDOW_UPDATE/RST_STREAM on a just-closed stream is correctly treated
//!     as a harmless no-op rather than an idle-stream error. Growth is bounded
//!     by the total number of streams opened on the connection; pruning
//!     fully-closed streams under a long-lived connection is tracked as #6064.
//!   - **A codec-detected stream-level frame fault is escalated to a
//!     connection error.** The two such faults (`PRIORITY` of the wrong length,
//!     a zero `WINDOW_UPDATE` increment on a stream) do not carry a stream id
//!     through `H2Frame.FrameError`, so the FSM cannot target a `RST_STREAM`;
//!     it sends a `GOAWAY` instead. RFC 9113 §5.4 permits treating a stream
//!     error more severely, and `PRIORITY` is ignored/deprecated regardless.
@runtime_checked
package Std.HttpEngine.H2Conn

import Std.Core
import Std.Collections
import Std.HttpEngine
import Std.HttpEngine.H2Frame
import Std.HttpEngine.Hpack

// =============================================================================
// §1. Settings.
// =============================================================================
/// The six RFC 9113 §6.5.2 settings parameters, decoded into `Int`s (the wire
/// form is 32-bit unsigned, but every value this FSM keeps is validated into
/// `Int` range: `initialWindowSize` is bounded to 2^31-1, `maxFrameSize` to
/// [2^14, 2^24-1], and the advisory sizes are clamped). `enablePush` is 0/1.
@experimental
pub record H2Settings {
  headerTableSize: Int
  enablePush: Int
  maxConcurrentStreams: Int
  initialWindowSize: Int
  maxFrameSize: Int
  maxHeaderListSize: Int
}

/// The default settings a server advertises: RFC-default header table (4096)
/// and initial window (65535) and frame size (16384), server push disabled
/// (`enablePush = 0`), a concurrent-streams ceiling of 128, and a 32 KiB
/// advisory header-list cap.
@pure
@experimental
pub func h2DefaultServerSettings(): H2Settings {
  H2Settings(
    headerTableSize = 4096,
    enablePush = 0,
    maxConcurrentStreams = 128,
    initialWindowSize = 65535,
    maxFrameSize = 16384,
    maxHeaderListSize = 32768
  )
}

/// The default settings assumed for the peer before its `SETTINGS` frame
/// arrives (RFC 9113 §6.5.2 initial values): 4096 header table, push enabled
/// (irrelevant to a server that never pushes), no concurrent-stream limit
/// applied to us, 65535 initial window, 16384 frame size.
@pure
@experimental
pub func h2DefaultPeerSettings(): H2Settings {
  H2Settings(
    headerTableSize = 4096,
    enablePush = 1,
    maxConcurrentStreams = 2147483647,
    initialWindowSize = 65535,
    maxFrameSize = 16384,
    maxHeaderListSize = 2147483647
  )
}

// =============================================================================
// §2. Stream state and events.
// =============================================================================
/// The per-stream lifecycle states this server tracks (RFC 9113 §5.1). The
/// two reserved states are omitted: this server never pushes, so `reserved
/// (local)` never occurs, and it never receives a valid `PUSH_PROMISE`, so
/// `reserved (remote)` never occurs.
@experimental
pub enum H2StreamState {
  case H2SIdle
  case H2SOpen
  case H2SHalfClosedLocal
  case H2SHalfClosedRemote
  case H2SClosed
}

/// Every semantic event `feed` can surface. Control frames the FSM emits in
/// response (SETTINGS ACK, PING ACK, WINDOW_UPDATE reclaim, RST_STREAM,
/// GOAWAY) are never events — they are already serialized in
/// `H2FeedResult.outbound`.
///
///   - `H2NeedMore` — no complete event yet; wait for more bytes.
///   - `H2SettingsReceived(settings)` — the peer's `SETTINGS` were applied (an
///     ACK has been queued in `outbound`).
///   - `H2SettingsAcknowledged` — the peer acknowledged our `SETTINGS`.
///   - `H2RequestHeaders(streamId, headers, endStream)` — a complete,
///     HPACK-decoded header block (request headers, or trailers when it
///     follows body data). `endStream` means the peer will send no more on
///     this stream.
///   - `H2RequestData(streamId, data, endStream)` — a slice of request-body
///     payload (padding already stripped by the frame layer).
///   - `H2PingReceived(opaqueData)` — the peer sent a `PING`; a `PING` ACK has
///     been queued in `outbound`.
///   - `H2PingAcknowledged(opaqueData)` — the peer acknowledged our `PING`.
///   - `H2WindowUpdated(streamId)` — a peer `WINDOW_UPDATE` replenished a send
///     window (`streamId = 0` is the connection window); the driver may resume
///     sending.
///   - `H2PeerReset(streamId, errorCode)` — the peer reset a stream.
///   - `H2GoAwayReceived(lastStreamId, errorCode)` — the peer is shutting the
///     connection down gracefully.
///   - `H2ConnError(errorCode, message)` — a connection-level error; a `GOAWAY`
///     has been queued in `outbound` and the connection is poisoned.
///   - `H2StreamErr(streamId, errorCode, message)` — a stream-level error; a
///     `RST_STREAM` has been queued in `outbound` and the stream is closed.
@experimental
pub union H2Event {
  case H2NeedMore
  case H2SettingsReceived(settings: H2Settings)
  case H2SettingsAcknowledged
  case H2RequestHeaders(streamId: Int, headers: List[HeaderField], endStream: Bool)
  case H2RequestData(streamId: Int, data: slice[Byte], endStream: Bool)
  case H2PingReceived(opaqueData: slice[Byte])
  case H2PingAcknowledged(opaqueData: slice[Byte])
  case H2WindowUpdated(streamId: Int)
  case H2PeerReset(streamId: Int, errorCode: H2ErrorCode)
  case H2GoAwayReceived(lastStreamId: Int, errorCode: H2ErrorCode)
  case H2ConnError(errorCode: H2ErrorCode, message: String)
  case H2StreamErr(streamId: Int, errorCode: H2ErrorCode, message: String)
}

/// The error returned by `sendData` when the request cannot be framed under
/// flow control.
///
///   - `WindowExceeded(available, requested)` — fewer than `requested` bytes
///     of send window are available (the min of the connection and stream
///     windows, floored at 0); split the write and retry after a
///     `H2WindowUpdated`.
///   - `StreamNotWritable(streamId)` — the stream is not in a state that
///     permits the server to send DATA (unknown, idle, half-closed-local, or
///     closed).
@experimental
pub union H2FlowError {
  case WindowExceeded(available: Int, requested: Int)
  case StreamNotWritable(streamId: Int)
}

/// The error returned by `encodeResponseHeaders`.
///
///   - `HeaderStreamNotWritable(streamId)` — the stream is not in a state that
///     permits the server to send HEADERS (unknown, idle, half-closed-local,
///     closed, or the connection is failed).
///   - `HeaderEncodingFailed(error)` — HPACK encoding failed (a pending encoder
///     table resize that exceeds the negotiated size).
@experimental
pub union H2SendError {
  case HeaderStreamNotWritable(streamId: Int)
  case HeaderEncodingFailed(error: HpackError)
}

// =============================================================================
// §3. Internal FSM state.
// =============================================================================
/// One tracked stream. `sendWindow` is how many DATA bytes the server may
/// still send (governed by the peer's initial window + `WINDOW_UPDATE`);
/// `recvWindow` is how many the peer may still send us (governed by our
/// advertised initial window + the `WINDOW_UPDATE`s we emit via `grant*`).
/// Reference semantics: a stream fetched from `H2Connection.streams` and
/// mutated in place updates the tracked value.
@experimental
record H2Stream {
  id: Int
  state: H2StreamState
  sendWindow: Int
  recvWindow: Int
}

/// In-progress HEADERS + CONTINUATION reassembly (§6.10). `accepted` is false
/// for a refused stream whose block must still be HPACK-decoded to keep the
/// compression context in sync (§4.3), then discarded. `contFrames` counts the
/// CONTINUATION frames seen so far, bounding the "CONTINUATION flood" DoS (a
/// peer that never sets END_HEADERS and sends endless zero-length fragments,
/// which the byte-budget guard alone would never stop) — see
/// `maxContinuationFrames`.
@experimental
record ContinuationState {
  streamId: Int
  buffer: List[Byte]
  endStream: Bool
  accepted: Bool
  contFrames: Int
}

/// The connection's shutdown / abuse-mitigation bookkeeping, grouped into a
/// sub-record. `goAwaySent`/`goAwayLastStreamId` drive the post-GOAWAY
/// new-stream refusal (§6.8); `goAwayReceived` records a peer GOAWAY;
/// `rapidResetCount`/`serverCompletedCount` are the Rapid-Reset
/// (CVE-2023-44487) counter and its completion credit.
///
/// This is a separate record purely to keep `H2Connection`'s constructor arity
/// low: the self-hosted JVM backend under-computes a record constructor's
/// `max_stack` at ~15+ fields, so a flat 17-field `H2Connection` fails
/// bytecode verification (`Operand stack overflow` in `newServerConnection`).
/// Grouping five fields here keeps the arity safely under that threshold.
/// Filed as #6089.
@experimental
record H2ShutdownState {
  goAwaySent: Bool
  goAwayLastStreamId: Int
  goAwayReceived: Bool
  rapidResetCount: Int
  serverCompletedCount: Int
}

/// Per-connection FSM state. A reference value threaded through `feed` and the
/// send/grant helpers; construct only via `newServerConnection`, observe only
/// via the query functions and `feed`'s events. See the module header for its
/// lifecycle contract.
@experimental
pub record H2Connection {
  dec: FrameDecoder
  hpackDec: HpackDecoder
  hpackEnc: HpackEncoder
  localSettings: H2Settings
  remoteSettings: H2Settings
  connSendWindow: Int
  connRecvWindow: Int
  streams: List[H2Stream]
  cont: Option[ContinuationState]
  lastPeerStreamId: Int
  expectClientSettings: Bool
  fatal: Bool
  shutdown: H2ShutdownState
}

/// What `feed` returns: the connection's next state, every semantic event the
/// fed bytes produced (at least one — an idle call yields `[H2NeedMore]`), and
/// the serialized control frames the FSM generated in response.
@experimental
pub record H2FeedResult {
  conn: H2Connection
  events: List[H2Event]
  outbound: slice[Byte]
}

/// The initial flow-control window for a connection and for every stream
/// before any `SETTINGS`/`WINDOW_UPDATE` (RFC 9113 §6.9.2): 65535 octets.
@pure
@experimental
pub func h2InitialWindow(): Int {
  65535
}

/// The largest value a flow-control window may hold (RFC 9113 §6.9.1):
/// 2^31 - 1. Growing a window past this is a `FLOW_CONTROL_ERROR`.
@pure
@experimental
pub func h2MaxWindow(): Int {
  2147483647
}

/// The most CONTINUATION frames permitted in a single header block before the
/// connection is torn down with `ENHANCE_YOUR_CALM`. This bounds the
/// "CONTINUATION flood" DoS — a peer that withholds END_HEADERS and streams
/// endless *zero-length* fragments, which the byte-budget guard
/// (`SETTINGS_MAX_HEADER_LIST_SIZE`) alone never trips because the buffer never
/// grows. 1024 is far above any legitimate header block (even a 64 KiB header
/// list split at the 16 KiB default frame size is a handful of frames), so it
/// never rejects real traffic while guaranteeing forward progress.
@pure
@experimental
pub func maxContinuationFrames(): Int {
  1024
}

/// The most peer stream resets of *server-incomplete* streams tolerated before
/// the connection is torn down with `ENHANCE_YOUR_CALM` — the HTTP/2 Rapid
/// Reset (CVE-2023-44487) mitigation. A peer that opens a stream with HEADERS
/// and immediately `RST_STREAM`s it forces per-stream work (HPACK decode,
/// dispatch) while the reset frees the concurrency slot instantly, evading
/// `SETTINGS_MAX_CONCURRENT_STREAMS`. 100 is the common industry threshold; it
/// is paired with a ratio guard (a connection is torn down only once its
/// reset-before-completion count *also* exceeds the number of streams the
/// server completed normally) so a busy, legitimate connection that cancels
/// many streams over its lifetime is never falsely terminated.
@pure
@experimental
pub func maxRapidResets(): Int {
  100
}

func noContinuation(): Option[ContinuationState] {
  val c: Option[ContinuationState] = None
  c
}

func noPriority(): Option[PriorityInfo] {
  val p: Option[PriorityInfo] = None
  p
}

func emptyBytes(): slice[Byte] {
  val e: slice[Byte] = []
  e
}

func minInt(a: in Int, b: in Int): Int {
  if a < b {
    a
  } else {
    b
  }
}

func atLeastZero(v: in Int): Int {
  if v < 0 {
    0
  } else {
    v
  }
}

/// Clamp a 32-bit-unsigned settings value (carried as `Long`) into `Int`
/// range for the advisory settings that may legally exceed 2^31-1.
func longToIntClamped(v: in Long): Int {
  if v > 2147483647i64 {
    2147483647
  } else {
    v.toInt()
  }
}

// =============================================================================
// §4. Construction.
// =============================================================================
/// A fresh server-side connection awaiting the client preface. `localSettings`
/// is what the server advertises; the peer's settings default to RFC initial
/// values until its `SETTINGS` frame arrives. Send `serverInitialFrame(conn)`
/// to the peer before feeding any bytes.
@pure
@experimental
pub func newServerConnection(localSettings: in H2Settings): H2Connection {
  H2Connection(
    dec = newFrameDecoderWithMaxSize(true, localSettings.maxFrameSize),
    hpackDec = newDecoder(localSettings.headerTableSize),
    hpackEnc = newEncoder(4096, true),
    localSettings = localSettings,
    remoteSettings = h2DefaultPeerSettings(),
    connSendWindow = h2InitialWindow(),
    connRecvWindow = h2InitialWindow(),
    streams = newList(),
    cont = noContinuation(),
    lastPeerStreamId = 0,
    expectClientSettings = true,
    fatal = false,
    shutdown = H2ShutdownState(
      goAwaySent = false,
      goAwayLastStreamId = 0,
      goAwayReceived = false,
      rapidResetCount = 0,
      serverCompletedCount = 0
    )
  )
}

func buildSettingsFrame(s: in H2Settings): slice[Byte] {
  val params: List[SettingsParam] = newList()
  params.add(SettingsParam(id = SettingsHeaderTableSize, value = s.headerTableSize.toLong()))
  params.add(SettingsParam(id = SettingsEnablePush, value = s.enablePush.toLong()))
  params.add(SettingsParam(id = SettingsMaxConcurrentStreams, value = s.maxConcurrentStreams.toLong()))
  params.add(SettingsParam(id = SettingsInitialWindowSize, value = s.initialWindowSize.toLong()))
  params.add(SettingsParam(id = SettingsMaxFrameSize, value = s.maxFrameSize.toLong()))
  params.add(SettingsParam(id = SettingsMaxHeaderListSize, value = s.maxHeaderListSize.toLong()))
  serializeFrame(SettingsFrame(settings = params, ack = false))
}

/// The server's initial `SETTINGS` frame (RFC 9113 §3.4) — the first bytes a
/// server writes on a new connection, before feeding any peer bytes.
@pure
@experimental
pub func serverInitialFrame(conn: in H2Connection): slice[Byte] {
  buildSettingsFrame(conn.localSettings)
}

/// True once a connection-level error poisoned the connection; `feed` refuses
/// to run again.
@pure
@experimental
pub func isFailed(conn: in H2Connection): Bool {
  conn.fatal
}

/// True once the server has emitted (or been asked to emit via `sendGoAway`) a
/// `GOAWAY`.
@pure
@experimental
pub func goAwayWasSent(conn: in H2Connection): Bool {
  conn.shutdown.goAwaySent
}

/// True once the peer has sent a `GOAWAY`.
@pure
@experimental
pub func goAwayWasReceived(conn: in H2Connection): Bool {
  conn.shutdown.goAwayReceived
}

// =============================================================================
// §5. Stream bookkeeping.
// =============================================================================
func findStream(state: in H2Connection, streamId: in Int): Option[H2Stream] {
  var i = 0
  while i < state.streams.count {
    // Explicit type on a `List`-element bind: on the JVM backend a bare
    // `List[T]` index is a statically-`Object` receiver (erased generics), so
    // `st.id` would not lower without the annotation (the #5934/#5935 class).
    val st: H2Stream = state.streams[i]
    if st.id == streamId {
      return Some(value = st)
    }
    i = i + 1
  }
  None
}

func isActiveState(s: in H2StreamState): Bool {
  match s {
    case H2SIdle -> false
    case H2SOpen -> true
    case H2SHalfClosedLocal -> true
    case H2SHalfClosedRemote -> true
    case H2SClosed -> false
  }
}

func countActiveStreams(state: in H2Connection): Int {
  var n = 0
  var i = 0
  while i < state.streams.count {
    val st: H2Stream = state.streams[i]
    if isActiveState(st.state) {
      n = n + 1
    }
    i = i + 1
  }
  n
}

func createStream(state: inout H2Connection, streamId: in Int): H2Stream {
  val st = H2Stream(
    id = streamId,
    state = H2SOpen,
    sendWindow = state.remoteSettings.initialWindowSize,
    recvWindow = state.localSettings.initialWindowSize
  )
  state.streams.add(st)
  st
}

/// The peer signalled END_STREAM: the stream can receive nothing further.
func markEndStreamReceived(state: inout H2Connection, streamId: in Int): Unit {
  match findStream(state, streamId) {
    case None -> ()
    case Some(st) -> {
      // Bind the union-case value to an explicitly-typed local before any field
      // access: on the JVM backend a value bound from an `Option`/union pattern
      // has a statically-`Object` receiver, so a direct `st.state` read/write
      // fails to lower (the #5934/#5935 erased-receiver class the sibling engine
      // files document). Do not inline `s` back to `st`.
      val s: H2Stream = st
      match s.state {
        case H2SOpen -> {
          s.state = H2SHalfClosedRemote
        }
        case H2SHalfClosedLocal -> {
          s.state = H2SClosed
        }
        case H2SIdle -> ()
        case H2SHalfClosedRemote -> ()
        case H2SClosed -> ()
      }
    }
  }
}

/// The server sent END_STREAM: it will send nothing further on this stream.
/// A stream on which the server completes its response counts toward
/// `serverCompletedCount`, the "legitimate work" credit that offsets the
/// Rapid-Reset counter (§ `maxRapidResets`).
func markEndStreamSent(state: inout H2Connection, streamId: in Int): Unit {
  match findStream(state, streamId) {
    case None -> ()
    case Some(st) -> {
      val s: H2Stream = st
      match s.state {
        case H2SOpen -> {
          s.state = H2SHalfClosedLocal
          state.shutdown.serverCompletedCount = state.shutdown.serverCompletedCount + 1
        }
        case H2SHalfClosedRemote -> {
          s.state = H2SClosed
          state.shutdown.serverCompletedCount = state.shutdown.serverCompletedCount + 1
        }
        case H2SIdle -> ()
        case H2SHalfClosedLocal -> ()
        case H2SClosed -> ()
      }
    }
  }
}

func closeStream(state: inout H2Connection, streamId: in Int): Unit {
  match findStream(state, streamId) {
    case None -> ()
    case Some(st) -> {
      val s: H2Stream = st
      s.state = H2SClosed
    }
  }
}

/// Would adding `increment` to a flow-control `window` push it past the
/// maximum (2^31-1, RFC 9113 §6.9.1)? `increment` is a 31-bit WINDOW_UPDATE
/// value (`0 < increment <= 2^31-1`, the codec rejects 0). Crucially, a stream
/// send window may be **negative** — a `SETTINGS_INITIAL_WINDOW_SIZE` decrease
/// applied after data was already sent (§6.9.2) — in which case
/// `window + increment` cannot exceed 2^31-1 (it is at most `increment`), so no
/// overflow is possible AND the naive guard `increment > 2^31-1 - window` must
/// be skipped: for a negative `window` the subtraction `2^31-1 - window` itself
/// overflows `Int`. Only when `window > 0` is the upper-bound check both
/// necessary and overflow-free.
func windowUpdateOverflows(window: in Int, increment: in Int): Bool {
  window > 0 and increment > h2MaxWindow() - window
}

/// Is `streamId` an *idle* stream (never opened) rather than a
/// closed-and-forgotten one? A late WINDOW_UPDATE/RST_STREAM on an idle stream
/// is a connection `PROTOCOL_ERROR` (RFC 9113 §5.1), whereas the same frame on
/// a closed stream is a tolerated no-op (§5.1 flow-control/reset race). An even
/// id is a server-initiated (push) id this server never creates, so it is
/// always idle; an odd id above the client high-water mark has not been opened
/// yet; an odd id at or below the high-water mark is a client stream that was
/// opened-and-closed (or implicitly closed by a higher id, §5.1.1) and since
/// forgotten.
func isIdleStreamId(state: in H2Connection, streamId: in Int): Bool {
  streamId % 2 == 0 or streamId > state.lastPeerStreamId
}

// =============================================================================
// §6. Error signalling (RFC 9113 §5.4).
// =============================================================================
func appendBytes(outb: in List[Byte], bs: in slice[Byte]): Unit {
  var i = 0
  while i < bs.length {
    outb.add(bs[i])
    i = i + 1
  }
}

/// Emit a connection error: append a `GOAWAY` carrying `code`, poison the
/// connection, and surface an `H2ConnError`. Idempotent — a second call after
/// the connection is already fatal does nothing (no duplicate `GOAWAY`).
func connFail(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  code: in H2ErrorCode,
  message: in String,
): Unit {
  if state.fatal {
    return
  }
  state.fatal = true
  state.shutdown.goAwaySent = true
  appendBytes(
    outb,
    serializeFrame(GoAwayFrame(lastStreamId = state.lastPeerStreamId, errorCode = code, debugData = emptyBytes()))
  )
  events.add(H2ConnError(errorCode = code, message = message))
}

/// Emit a stream error: close the stream, append a `RST_STREAM` carrying
/// `code`, and surface an `H2StreamErr`.
func streamFail(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  code: in H2ErrorCode,
  message: in String,
): Unit {
  closeStream(state, streamId)
  appendBytes(outb, serializeFrame(RstStreamFrame(streamId = streamId, errorCode = code)))
  events.add(H2StreamErr(streamId = streamId, errorCode = code, message = message))
}

// =============================================================================
// §7. SETTINGS application (RFC 9113 §6.5).
// =============================================================================
/// Adjust every existing stream's SEND window by the delta implied by a change
/// to `SETTINGS_INITIAL_WINDOW_SIZE` (§6.9.2). RFC 9113 §6.9.2 scopes this to
/// streams with an **active** flow-control window — open or half-closed
/// (remote); closed / half-closed-local streams are inert. Because closed
/// streams are retained for the connection lifetime (#6064) and can carry a
/// near-max `sendWindow` accumulated via ordinary WINDOW_UPDATE before closing,
/// applying the delta (and its overflow guard) to a dead stream would let a
/// perfectly legal settings change tear down the whole connection (#6090); the
/// `streamWritable` gate excludes them. A change that would push a *live*
/// stream's window past 2^31-1 is still a connection `FLOW_CONTROL_ERROR`.
func applyInitialWindowChange(
  state: inout H2Connection, events: in List[H2Event], outb: in List[Byte], newInit: in Int
): Unit {
  val oldInit = state.remoteSettings.initialWindowSize
  val delta = newInit - oldInit
  state.remoteSettings.initialWindowSize = newInit
  var i = 0
  while i < state.streams.count {
    val st: H2Stream = state.streams[i]
    if streamWritable(st) {
      if delta > 0 and st.sendWindow > h2MaxWindow() - delta {
        connFail(
          state,
          events,
          outb,
          H2FlowControlError,
          "SETTINGS_INITIAL_WINDOW_SIZE change overflows a stream flow-control window (RFC 9113 section 6.9.2)"
        )
        return
      }
      st.sendWindow = st.sendWindow + delta
    }
    i = i + 1
  }
}

func applyOneSetting(
  state: inout H2Connection, events: in List[H2Event], outb: in List[Byte], param: in SettingsParam
): Unit {
  match param.id {
    case SettingsEnablePush -> {
      if param.value != 0i64 and param.value != 1i64 {
        connFail(state, events, outb, H2ProtocolError, "SETTINGS_ENABLE_PUSH must be 0 or 1 (RFC 9113 section 6.5.2)")
      } else {
        state.remoteSettings.enablePush = param.value.toInt()
      }
    }
    case SettingsInitialWindowSize -> {
      if param.value > 2147483647i64 {
        connFail(
          state,
          events,
          outb,
          H2FlowControlError,
          "SETTINGS_INITIAL_WINDOW_SIZE exceeds 2^31-1 (RFC 9113 section 6.5.2)"
        )
      } else {
        applyInitialWindowChange(state, events, outb, param.value.toInt())
      }
    }
    case SettingsMaxFrameSize -> {
      if param.value < 16384i64 or param.value > 16777215i64 {
        connFail(
          state,
          events,
          outb,
          H2ProtocolError,
          "SETTINGS_MAX_FRAME_SIZE outside [2^14, 2^24-1] (RFC 9113 section 6.5.2)"
        )
      } else {
        state.remoteSettings.maxFrameSize = param.value.toInt()
      }
    }
    case SettingsHeaderTableSize -> {
      val v = longToIntClamped(param.value)
      state.remoteSettings.headerTableSize = v
      applyEncoderTableSize(state, v)
    }
    case SettingsMaxConcurrentStreams -> {
      state.remoteSettings.maxConcurrentStreams = longToIntClamped(param.value)
    }
    case SettingsMaxHeaderListSize -> {
      state.remoteSettings.maxHeaderListSize = longToIntClamped(param.value)
    }
    case SettingsUnknown(_) -> ()
  }
}

/// The peer's `SETTINGS_HEADER_TABLE_SIZE` bounds OUR encoder's dynamic table.
func applyEncoderTableSize(state: inout H2Connection, newSize: in Int): Unit {
  match encoderSetMaxTableSize(state.hpackEnc, newSize) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func applySettings(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  params: in List[SettingsParam],
): Unit {
  var i = 0
  while i < params.count {
    if state.fatal {
      return
    }
    applyOneSetting(state, events, outb, params[i])
    i = i + 1
  }
}

// =============================================================================
// §8. Per-frame handlers.
// =============================================================================
func handleSettings(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  params: in List[SettingsParam],
  ack: in Bool,
): Unit {
  if ack {
    events.add(H2SettingsAcknowledged)
  } else {
    applySettings(state, events, outb, params)
    if state.fatal {
      return
    }
    val empty: List[SettingsParam] = newList()
    appendBytes(outb, serializeFrame(SettingsFrame(settings = empty, ack = true)))
    events.add(H2SettingsReceived(settings = state.remoteSettings))
  }
}

func handlePing(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  opaqueData: in slice[Byte],
  ack: in Bool,
): Unit {
  if ack {
    events.add(H2PingAcknowledged(opaqueData = opaqueData))
  } else {
    appendBytes(outb, serializeFrame(PingFrame(opaqueData = opaqueData, ack = true)))
    events.add(H2PingReceived(opaqueData = opaqueData))
  }
}

func handleGoAway(
  state: inout H2Connection, events: in List[H2Event], lastStreamId: in Int, errorCode: in H2ErrorCode
): Unit {
  state.shutdown.goAwayReceived = true
  events.add(H2GoAwayReceived(lastStreamId = lastStreamId, errorCode = errorCode))
}

func handleWindowUpdate(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  increment: in Int,
): Unit {
  if streamId == 0 {
    if windowUpdateOverflows(state.connSendWindow, increment) {
      connFail(
        state,
        events,
        outb,
        H2FlowControlError,
        "WINDOW_UPDATE overflows the connection send window (RFC 9113 section 6.9.1)"
      )
    } else {
      state.connSendWindow = state.connSendWindow + increment
      events.add(H2WindowUpdated(streamId = 0))
    }
  } else {
    handleStreamWindowUpdate(state, events, outb, streamId, increment)
  }
}

func handleStreamWindowUpdate(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  increment: in Int,
): Unit {
  match findStream(state, streamId) {
    case None -> {
      if isIdleStreamId(state, streamId) {
        connFail(state, events, outb, H2ProtocolError, "WINDOW_UPDATE on an idle stream (RFC 9113 section 5.1)")
      }
    }
    case Some(st) -> {
      val s: H2Stream = st
      if not streamWritable(s) {
        // WINDOW_UPDATE on a retained stream with no active send-flow window
        // (closed, or half-closed-local) is a tolerated no-op (§5.1 flow-control
        // race, §6.9): the server will never send DATA on it. Mutating its
        // retained `sendWindow` here is what makes the #6090 SETTINGS overflow
        // reachable, and emitting `H2WindowUpdated` for a dead stream is
        // spurious — so do neither (#6091).
        ()
      } else if windowUpdateOverflows(s.sendWindow, increment) {
        streamFail(
          state,
          events,
          outb,
          streamId,
          H2FlowControlError,
          "WINDOW_UPDATE overflows a stream send window (RFC 9113 section 6.9.1)"
        )
      } else {
        s.sendWindow = s.sendWindow + increment
        events.add(H2WindowUpdated(streamId = streamId))
      }
    }
  }
}

func handleRstStream(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  errorCode: in H2ErrorCode,
): Unit {
  match findStream(state, streamId) {
    case None -> {
      if isIdleStreamId(state, streamId) {
        connFail(state, events, outb, H2ProtocolError, "RST_STREAM on an idle stream (RFC 9113 section 6.4)")
      }
    }
    case Some(st) -> {
      val s: H2Stream = st
      // A reset of a stream the server had not yet completed is the Rapid-Reset
      // (CVE-2023-44487) signal — the peer forced per-stream work (HPACK decode,
      // dispatch) and freed the concurrency slot instantly. A reset of an
      // already-half-closed-local/closed stream is a benign teardown race.
      val serverIncomplete = match s.state { case H2SOpen -> true; case H2SHalfClosedRemote -> true; case _ -> false }
      s.state = H2SClosed
      events.add(H2PeerReset(streamId = streamId, errorCode = errorCode))
      if serverIncomplete {
        state.shutdown.rapidResetCount = state.shutdown.rapidResetCount + 1
        if state.shutdown.rapidResetCount > maxRapidResets() and state.shutdown.rapidResetCount > state.shutdown.serverCompletedCount {
          connFail(
            state,
            events,
            outb,
            H2EnhanceYourCalm,
            "excessive stream resets before completion (RFC 9113; Rapid Reset / CVE-2023-44487 mitigation)"
          )
        }
      }
    }
  }
}

func handleData(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  data: in slice[Byte],
  endStream: in Bool,
): Unit {
  val len = data.length
  if len > state.connRecvWindow {
    connFail(
      state,
      events,
      outb,
      H2FlowControlError,
      "DATA overruns the connection receive window (RFC 9113 section 6.9.1)"
    )
    return
  }
  state.connRecvWindow = state.connRecvWindow - len
  match findStream(state, streamId) {
    case None -> {
      if isIdleStreamId(state, streamId) {
        // A stream that was never opened: DATA before HEADERS is a connection
        // PROTOCOL_ERROR (RFC 9113 section 5.1 idle state).
        connFail(state, events, outb, H2ProtocolError, "DATA on an idle stream (RFC 9113 section 6.1)")
      } else {
        // A recently-closed or just-refused stream (odd id at/below the client
        // high-water mark): a client that pipelined DATA before seeing our
        // RST_STREAM/refusal is racing an RFC-anticipated, retryable outcome
        // (SETTINGS_MAX_CONCURRENT_STREAMS refusal, or a close). Reject just the
        // stream and reclaim the connection flow-control window the frame
        // consumed — do NOT kill the whole connection.
        reclaimAndStreamFail(state, events, outb, streamId, len)
      }
    }
    case Some(st) -> dispatchDataToStream(state, events, outb, st, data, endStream)
  }
}

func dispatchDataToStream(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  st: in H2Stream,
  data: in slice[Byte],
  endStream: in Bool,
): Unit {
  match st.state {
    case H2SOpen -> receiveData(state, events, outb, st, data, endStream)
    case H2SHalfClosedLocal -> receiveData(state, events, outb, st, data, endStream)
    case H2SIdle -> reclaimAndStreamFail(state, events, outb, st.id, data.length)
    case H2SHalfClosedRemote -> reclaimAndStreamFail(state, events, outb, st.id, data.length)
    case H2SClosed -> reclaimAndStreamFail(state, events, outb, st.id, data.length)
  }
}

/// Give back to the connection-level receive window the `len` DATA octets a
/// frame consumed (they were debited up front, before the stream was known),
/// and tell the peer via a connection `WINDOW_UPDATE`. Used whenever DATA is
/// dropped for a stream-level reason (reset/closed/refused stream, or a
/// stream-level flow-control violation) so a stream error can't slowly starve
/// the shared connection window.
func reclaimConnectionWindow(state: inout H2Connection, outb: in List[Byte], len: in Int): Unit {
  if len > 0 {
    state.connRecvWindow = state.connRecvWindow + len
    appendBytes(outb, serializeFrame(WindowUpdateFrame(streamId = 0, windowSizeIncrement = len)))
  }
}

/// DATA landed on a stream that can't receive it (closed/half-closed-remote,
/// or just refused): reclaim the connection-level window the frame consumed,
/// then signal the stream error.
func reclaimAndStreamFail(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  len: in Int,
): Unit {
  reclaimConnectionWindow(state, outb, len)
  streamFail(
    state,
    events,
    outb,
    streamId,
    H2StreamClosed,
    "DATA on a half-closed (remote) or closed stream (RFC 9113 section 5.1)"
  )
}

func receiveData(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  st: in H2Stream,
  data: in slice[Byte],
  endStream: in Bool,
): Unit {
  val len = data.length
  if len > st.recvWindow {
    // The connection window was already debited for this DATA (in handleData);
    // the stream is being reset, so give those octets back to the connection
    // window rather than leaking them (#6074) — matches the reclaim the
    // closed-stream path already performs.
    reclaimConnectionWindow(state, outb, len)
    streamFail(
      state,
      events,
      outb,
      st.id,
      H2FlowControlError,
      "DATA overruns a stream receive window (RFC 9113 section 6.9.1)"
    )
  } else {
    st.recvWindow = st.recvWindow - len
    events.add(H2RequestData(streamId = st.id, data = data, endStream = endStream))
    if endStream {
      markEndStreamReceived(state, st.id)
    }
  }
}

// =============================================================================
// §9. HEADERS / CONTINUATION reassembly (RFC 9113 §6.2/§6.10).
// =============================================================================
func handleHeaders(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  fragment: in slice[Byte],
  endStream: in Bool,
  endHeaders: in Bool,
): Unit {
  if streamId % 2 == 0 {
    connFail(
      state,
      events,
      outb,
      H2ProtocolError,
      "HEADERS with an even (server-initiated) stream id (RFC 9113 section 5.1.1)"
    )
    return
  }
  match findStream(state, streamId) {
    case None -> beginNewStreamHeaders(state, events, outb, streamId, fragment, endStream, endHeaders)
    case Some(st) -> beginTrailerHeaders(state, events, outb, st, fragment, endStream, endHeaders)
  }
}

func beginNewStreamHeaders(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  fragment: in slice[Byte],
  endStream: in Bool,
  endHeaders: in Bool,
): Unit {
  if streamId <= state.lastPeerStreamId {
    connFail(
      state,
      events,
      outb,
      H2ProtocolError,
      "HEADERS opens a stream id that is not greater than all previous (RFC 9113 section 5.1.1)"
    )
    return
  }
  state.lastPeerStreamId = streamId
  // A new stream is refused if the connection is draining after the server's own
  // GOAWAY and this id is above the advertised last-stream-id (RFC 9113 §6.8), or
  // if it would exceed SETTINGS_MAX_CONCURRENT_STREAMS (§5.1.2). Either way the
  // block is still HPACK-decoded (accepted = false) to keep the compression
  // context in sync (§4.3).
  val overGoAway = state.shutdown.goAwaySent and streamId > state.shutdown.goAwayLastStreamId
  val overConcurrency = countActiveStreams(state) >= state.localSettings.maxConcurrentStreams
  val accepted = not overGoAway and not overConcurrency
  if accepted {
    val ignored = createStream(state, streamId)
  } else {
    val refuseMsg = if overGoAway {
      "stream refused: connection is draining after a server GOAWAY (RFC 9113 section 6.8)"
    } else {
      "stream refused: exceeds SETTINGS_MAX_CONCURRENT_STREAMS (RFC 9113 section 5.1.2)"
    }
    appendBytes(outb, serializeFrame(RstStreamFrame(streamId = streamId, errorCode = H2RefusedStream)))
    events.add(H2StreamErr(streamId = streamId, errorCode = H2RefusedStream, message = refuseMsg))
  }
  beginAssembly(state, events, outb, streamId, fragment, endStream, endHeaders, accepted)
}

func beginTrailerHeaders(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  st: in H2Stream,
  fragment: in slice[Byte],
  endStream: in Bool,
  endHeaders: in Bool,
): Unit {
  val receivable = match st.state {
    case H2SOpen -> true
    case H2SHalfClosedLocal -> true
    case H2SIdle -> false
    case H2SHalfClosedRemote -> false
    case H2SClosed -> false
  }
  if not receivable {
    // Reject the stream, but STILL run the block through the HPACK decoder
    // (accepted = false → decode-and-discard) so the connection's shared
    // compression context stays in sync (RFC 9113 §4.3) — otherwise every
    // subsequent header block on the connection mis-decodes (#6082). This
    // mirrors the new-stream-refusal path.
    val sid = st.id
    streamFail(
      state,
      events,
      outb,
      sid,
      H2StreamClosed,
      "HEADERS on a half-closed (remote) or closed stream (RFC 9113 section 5.1)"
    )
    beginAssembly(state, events, outb, sid, fragment, endStream, endHeaders, false)
    return
  }
  if not endStream {
    connFail(state, events, outb, H2ProtocolError, "trailer HEADERS must carry END_STREAM (RFC 9113 section 8.1)")
    return
  }
  beginAssembly(state, events, outb, st.id, fragment, endStream, endHeaders, true)
}

func beginAssembly(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  fragment: in slice[Byte],
  endStream: in Bool,
  endHeaders: in Bool,
  accepted: in Bool,
): Unit {
  val buffer: List[Byte] = newList()
  appendBytes(buffer, fragment)
  if headerBufferTooLarge(state, buffer.count) {
    connFail(
      state,
      events,
      outb,
      H2EnhanceYourCalm,
      "header block exceeds SETTINGS_MAX_HEADER_LIST_SIZE budget (RFC 9113 section 6.5.2)"
    )
    return
  }
  if endHeaders {
    finalizeHeaders(state, events, outb, streamId, buffer, endStream, accepted)
  } else {
    state.cont = Some(
      value = ContinuationState(
        streamId = streamId,
        buffer = buffer,
        endStream = endStream,
        accepted = accepted,
        contFrames = 0
      )
    )
  }
}

func headerBufferTooLarge(state: in H2Connection, size: in Int): Bool {
  size > state.localSettings.maxHeaderListSize
}

func handleContinuation(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  fragment: in slice[Byte],
  endHeaders: in Bool,
): Unit {
  match state.cont {
    case None -> connFail(state, events, outb, H2ProtocolError, "CONTINUATION with no preceding HEADERS (RFC 9113 section 6.10)")
    case Some(c) -> {
      // Typed local before any field access — the erased-receiver JVM fix (see
      // `markEndStreamReceived`). Do not inline `cs` back to `c`.
      val cs: ContinuationState = c
      cs.contFrames = cs.contFrames + 1
      if cs.contFrames > maxContinuationFrames() {
        // CONTINUATION-flood mitigation (#6078): a peer streaming endless
        // zero-length fragments without END_HEADERS never grows the buffer, so
        // the byte-budget guard below can't stop it; bound the frame count.
        connFail(
          state,
          events,
          outb,
          H2EnhanceYourCalm,
          "too many CONTINUATION frames in one header block (RFC 9113 section 6.10; CONTINUATION-flood mitigation)"
        )
        return
      }
      appendBytes(cs.buffer, fragment)
      if headerBufferTooLarge(state, cs.buffer.count) {
        connFail(
          state,
          events,
          outb,
          H2EnhanceYourCalm,
          "header block exceeds SETTINGS_MAX_HEADER_LIST_SIZE budget (RFC 9113 section 6.5.2)"
        )
        return
      }
      if endHeaders {
        val sid = cs.streamId
        val es = cs.endStream
        val acc = cs.accepted
        val buf = cs.buffer
        state.cont = noContinuation()
        finalizeHeaders(state, events, outb, sid, buf, es, acc)
      }
    }
  }
}

/// A header block is complete: HPACK-decode it (a decode error is a connection
/// `COMPRESSION_ERROR`), then either surface the headers (accepted stream) or
/// discard them (refused stream — decoded only to keep the compression
/// context in sync, RFC 9113 section 4.3).
func finalizeHeaders(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  buffer: in List[Byte],
  endStream: in Bool,
  accepted: in Bool,
): Unit {
  match decodeHeaderBlock(state.hpackDec, buffer.toArray()) {
    case Err(_) -> connFail(state, events, outb, H2CompressionError, "HPACK decoding failed (RFC 9113 section 4.3)")
    case Ok(headers) -> {
      if accepted {
        events.add(H2RequestHeaders(streamId = streamId, headers = headers, endStream = endStream))
        if endStream {
          markEndStreamReceived(state, streamId)
        }
      }
    }
  }
}

func handlePushPromise(state: inout H2Connection, events: in List[H2Event], outb: in List[Byte]): Unit {
  connFail(state, events, outb, H2ProtocolError, "a server must not receive PUSH_PROMISE (RFC 9113 section 8.4)")
}

// =============================================================================
// §10. The feed loop.
// =============================================================================
func isNonAckSettings(frame: in H2Frame): Bool {
  match frame {
    case SettingsFrame(_, ack) -> not ack
    case _ -> false
  }
}

/// Route a decoded frame while a HEADERS block is mid-reassembly: only a
/// CONTINUATION for the same stream is legal (§6.10); anything else is a
/// connection `PROTOCOL_ERROR`.
func dispatchDuringContinuation(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  frame: in H2Frame,
  contStreamId: in Int,
): Unit {
  match frame {
    case ContinuationFrame(sid, fragment, endHeaders) -> {
      if sid == contStreamId {
        handleContinuation(state, events, outb, fragment, endHeaders)
      } else {
        connFail(
          state,
          events,
          outb,
          H2ProtocolError,
          "CONTINUATION for a different stream than the open HEADERS block (RFC 9113 section 6.10)"
        )
      }
    }
    case _ -> connFail(state, events, outb, H2ProtocolError, "expected CONTINUATION for the open HEADERS block (RFC 9113 section 6.10)")
  }
}

func dispatchNormal(state: inout H2Connection, events: in List[H2Event], outb: in List[Byte], frame: in H2Frame): Unit {
  match frame {
    case DataFrame(streamId, data, endStream) -> handleData(state, events, outb, streamId, data, endStream)
    case HeadersFrame(streamId, fragment, endStream, endHeaders, _) -> handleHeaders(state, events, outb, streamId, fragment, endStream, endHeaders)
    case ContinuationFrame(_, _, _) -> connFail(state, events, outb, H2ProtocolError, "CONTINUATION with no preceding HEADERS (RFC 9113 section 6.10)")
    case PriorityFrame(_, _) -> ()
    case RstStreamFrame(streamId, errorCode) -> handleRstStream(state, events, outb, streamId, errorCode)
    case SettingsFrame(settings, ack) -> handleSettings(state, events, outb, settings, ack)
    case PushPromiseFrame(_, _, _, _) -> handlePushPromise(state, events, outb)
    case PingFrame(opaqueData, ack) -> handlePing(state, events, outb, opaqueData, ack)
    case GoAwayFrame(lastStreamId, errorCode, _) -> handleGoAway(state, events, lastStreamId, errorCode)
    case WindowUpdateFrame(streamId, increment) -> handleWindowUpdate(state, events, outb, streamId, increment)
    case UnknownFrame(_, _) -> ()
  }
}

func dispatchFrame(state: inout H2Connection, events: in List[H2Event], outb: in List[Byte], frame: in H2Frame): Unit {
  if state.fatal {
    return
  }
  match state.cont {
    case Some(c) -> {
      val cs: ContinuationState = c
      dispatchDuringContinuation(state, events, outb, frame, cs.streamId)
    }
    case None -> dispatchAfterPreface(state, events, outb, frame)
  }
}

func dispatchAfterPreface(
  state: inout H2Connection, events: in List[H2Event], outb: in List[Byte], frame: in H2Frame
): Unit {
  if state.expectClientSettings {
    if not isNonAckSettings(frame) {
      connFail(
        state,
        events,
        outb,
        H2ProtocolError,
        "the first frame after the connection preface must be a non-ACK SETTINGS frame (RFC 9113 section 3.4)"
      )
      return
    }
    state.expectClientSettings = false
  }
  dispatchNormal(state, events, outb, frame)
}

func handleDecodeEvent(
  state: inout H2Connection, events: in List[H2Event], outb: in List[Byte], ev: in FrameDecodeEvent
): Unit {
  match ev {
    case FrameNeedMore -> ()
    case PrefaceReceived -> ()
    case FrameFailed(error) -> connFail(state, events, outb, error.code, error.message)
    case FrameDecoded(frame) -> dispatchFrame(state, events, outb, frame)
  }
}

func driveConnection(
  state: inout H2Connection, bytes: in slice[Byte], events: in List[H2Event], outb: in List[Byte]
): Unit {
  val fr = feedFrames(state.dec, bytes)
  state.dec = fr.decoder
  var i = 0
  while i < fr.events.count {
    if state.fatal {
      return
    }
    handleDecodeEvent(state, events, outb, fr.events[i])
    i = i + 1
  }
}

/// Feed newly received bytes into the connection FSM. Returns the next
/// connection state, every semantic event the bytes produced (at least one),
/// and the serialized control frames (SETTINGS ACK, PING ACK, WINDOW_UPDATE
/// reclaim, RST_STREAM, GOAWAY) the FSM generated in response.
///
/// # Contract
/// Calling `feed` after `isFailed(conn)` is a programmer error — a
/// connection-level error has no defined next state — so it is a `requires:`.
@experimental
pub func feed(conn: in H2Connection, bytes: in slice[Byte]): H2FeedResult
  requires: not isFailed(conn)
{
  var state = conn
  val events: List[H2Event] = newList()
  val outb: List[Byte] = newList()
  driveConnection(state, bytes, events, outb)
  if events.count == 0 {
    events.add(H2NeedMore)
  }
  H2FeedResult(conn = state, events = events, outbound = outb.toArray())
}

// =============================================================================
// §11. Query surface.
// =============================================================================
/// How many DATA octets the server may still send on the connection as a
/// whole (never negative; a `SETTINGS_INITIAL_WINDOW_SIZE` change can only
/// drive a per-stream window negative, not this one).
@pure
@experimental
pub func connectionSendWindow(conn: in H2Connection): Int {
  conn.connSendWindow
}

/// How many DATA octets the peer may still send us on the connection as a
/// whole before it must await a `WINDOW_UPDATE` we emit via
/// `grantConnectionWindow`.
@pure
@experimental
pub func connectionReceiveWindow(conn: in H2Connection): Int {
  conn.connRecvWindow
}

/// The current state of `streamId` (`H2SIdle` if never seen).
@pure
@experimental
pub func streamState(conn: in H2Connection, streamId: in Int): H2StreamState {
  match findStream(conn, streamId) {
    case None -> H2SIdle
    case Some(st) -> {
      val s: H2Stream = st
      s.state
    }
  }
}

/// The server's remaining send window on `streamId` (0 if the stream is
/// unknown; may be reported as a negative value after a
/// `SETTINGS_INITIAL_WINDOW_SIZE` reduction, per RFC 9113 section 6.9.2).
@pure
@experimental
pub func streamSendWindow(conn: in H2Connection, streamId: in Int): Int {
  match findStream(conn, streamId) {
    case None -> 0
    case Some(st) -> {
      val s: H2Stream = st
      s.sendWindow
    }
  }
}

/// The peer's remaining send window on `streamId` as tracked by us (0 if the
/// stream is unknown).
@pure
@experimental
pub func streamReceiveWindow(conn: in H2Connection, streamId: in Int): Int {
  match findStream(conn, streamId) {
    case None -> 0
    case Some(st) -> {
      val s: H2Stream = st
      s.recvWindow
    }
  }
}

/// The largest DATA payload the server may frame right now on `streamId`: the
/// min of the connection and stream send windows, floored at 0.
@pure
@experimental
pub func maxSendableOnStream(conn: in H2Connection, streamId: in Int): Int {
  match findStream(conn, streamId) {
    case None -> 0
    case Some(st) -> {
      val s: H2Stream = st
      atLeastZero(minInt(conn.connSendWindow, s.sendWindow))
    }
  }
}

/// The number of streams currently in an active (non-idle, non-closed) state.
@pure
@experimental
pub func activeStreamCount(conn: in H2Connection): Int {
  countActiveStreams(conn)
}

// =============================================================================
// §12. Server send / flow-control-replenish surface.
// =============================================================================
func headerBlockToFrames(streamId: in Int, block: in slice[Byte], endStream: in Bool, maxFrameSize: in Int): slice[Byte] {
  val outb: List[Byte] = newList()
  if block.length <= maxFrameSize {
    appendBytes(
      outb,
      serializeFrame(
        HeadersFrame(
          streamId = streamId,
          headerBlockFragment = block,
          endStream = endStream,
          endHeaders = true,
          priority = noPriority()
        )
      )
    )
  } else {
    val first = block.slice(0, maxFrameSize)
    appendBytes(
      outb,
      serializeFrame(
        HeadersFrame(
          streamId = streamId,
          headerBlockFragment = first,
          endStream = endStream,
          endHeaders = false,
          priority = noPriority()
        )
      )
    )
    var off = maxFrameSize
    while off < block.length {
      val stop = minInt(off + maxFrameSize, block.length)
      val chunk = block.slice(off, stop)
      val isLast = stop == block.length
      appendBytes(
        outb,
        serializeFrame(ContinuationFrame(streamId = streamId, headerBlockFragment = chunk, endHeaders = isLast))
      )
      off = stop
    }
  }
  outb.toArray()
}

/// HPACK-encode `headers` and frame them as a HEADERS (+ CONTINUATION when the
/// block exceeds the peer's max frame size) response on `streamId`, updating
/// the stream state for `endStream`. The returned bytes are ready to write.
/// Fails with `HeaderStreamNotWritable` if the connection is poisoned or the
/// stream is not in a state that can send HEADERS (#6084/#6085), or
/// `HeaderEncodingFailed` if HPACK encoding fails.
@experimental
pub func encodeResponseHeaders(
  conn: in H2Connection,
  streamId: in Int,
  headers: in List[HeaderField],
  endStream: in Bool,
): Result[slice[Byte], H2SendError] {
  var state = conn
  if isFailed(state) {
    return Err(error = HeaderStreamNotWritable(streamId = streamId))
  }
  match findStream(state, streamId) {
    case None -> Err(error = HeaderStreamNotWritable(streamId = streamId))
    case Some(st) -> {
      val s: H2Stream = st
      if not streamWritable(s) {
        Err(error = HeaderStreamNotWritable(streamId = streamId))
      } else {
        encodeResponseHeadersOn(state, streamId, headers, endStream)
      }
    }
  }
}

func encodeResponseHeadersOn(
  state: inout H2Connection,
  streamId: in Int,
  headers: in List[HeaderField],
  endStream: in Bool,
): Result[slice[Byte], H2SendError] {
  match encodeHeaderList(state.hpackEnc, headers) {
    case Err(e) -> Err(error = HeaderEncodingFailed(error = e))
    case Ok(block) -> {
      val frames = headerBlockToFrames(streamId, block, endStream, state.remoteSettings.maxFrameSize)
      if endStream {
        markEndStreamSent(state, streamId)
      }
      Ok(value = frames)
    }
  }
}

/// Frame `data` as a flow-control-checked DATA response on `streamId`. On
/// success the connection and stream send windows are debited and the
/// serialized frame bytes are returned; on failure nothing is sent and the
/// caller learns whether the stream is unwritable or the window is too small
/// (split and retry after a `H2WindowUpdated`). A caller should keep each
/// `data` within the peer's max frame size (`peerMaxFrameSize`).
@experimental
pub func sendData(
  conn: in H2Connection, streamId: in Int, data: in slice[Byte], endStream: in Bool
): Result[slice[Byte], H2FlowError] {
  var state = conn
  // Never act on a poisoned connection (#6085): a connection-level error has torn
  // it down, so the driver must not keep sending.
  if isFailed(state) {
    return Err(error = StreamNotWritable(streamId = streamId))
  }
  match findStream(state, streamId) {
    case None -> Err(error = StreamNotWritable(streamId = streamId))
    case Some(st) -> sendDataToStream(state, st, streamId, data, endStream)
  }
}

/// A stream in a state from which the server may still send HEADERS or DATA
/// (open, or half-closed on the peer side so only the server is still sending).
func streamWritable(s: in H2Stream): Bool {
  match s.state {
    case H2SOpen -> true
    case H2SHalfClosedRemote -> true
    case H2SIdle -> false
    case H2SHalfClosedLocal -> false
    case H2SClosed -> false
  }
}

func sendDataToStream(
  state: inout H2Connection,
  st: in H2Stream,
  streamId: in Int,
  data: in slice[Byte],
  endStream: in Bool,
): Result[slice[Byte], H2FlowError] {
  if not streamWritable(st) {
    Err(error = StreamNotWritable(streamId = streamId))
  } else {
    val len = data.length
    val sendable = atLeastZero(minInt(state.connSendWindow, st.sendWindow))
    if len > sendable {
      Err(error = WindowExceeded(available = sendable, requested = len))
    } else {
      state.connSendWindow = state.connSendWindow - len
      st.sendWindow = st.sendWindow - len
      val bytes = serializeFrame(DataFrame(streamId = streamId, data = data, endStream = endStream))
      if endStream {
        markEndStreamSent(state, streamId)
      }
      Ok(value = bytes)
    }
  }
}

/// The peer's advertised `SETTINGS_MAX_FRAME_SIZE` — the ceiling a caller must
/// keep each `sendData` payload within.
@pure
@experimental
pub func peerMaxFrameSize(conn: in H2Connection): Int {
  conn.remoteSettings.maxFrameSize
}

/// Replenish the connection-level receive window by `increment` and produce
/// the `WINDOW_UPDATE` (stream 0) frame to send the peer. Call after the
/// application has consumed request-body bytes.
///
/// # Contract
/// `increment` is a positive value that keeps the window within 2^31-1
/// (RFC 9113 section 6.9.1).
@experimental
pub func grantConnectionWindow(conn: in H2Connection, increment: in Int): slice[Byte]
  requires: increment > 0
  requires: increment <= h2MaxWindow() - conn.connRecvWindow
{
  var state = conn
  // Never mutate/act on a poisoned connection (#6085).
  if isFailed(state) {
    return emptyBytes()
  }
  state.connRecvWindow = state.connRecvWindow + increment
  serializeFrame(WindowUpdateFrame(streamId = 0, windowSizeIncrement = increment))
}

/// Replenish a stream-level receive window by `increment` and produce the
/// `WINDOW_UPDATE` frame to send the peer. A no-op grant of empty bytes if the
/// stream is unknown.
///
/// # Contract
/// `increment` is a positive value that keeps the stream receive window within
/// 2^31-1 (RFC 9113 section 6.9.1) — the same overflow bound `grantConnectionWindow`
/// enforces for the connection window. `streamReceiveWindow` returns 0 for an
/// unknown stream, so the bound is trivially satisfied there (and the call is a
/// no-op anyway).
@experimental
pub func grantStreamWindow(conn: in H2Connection, streamId: in Int, increment: in Int): slice[Byte]
  requires: increment > 0
  requires: increment <= h2MaxWindow() - streamReceiveWindow(conn, streamId)
{
  var state = conn
  // Never mutate/act on a poisoned connection (#6085).
  if isFailed(state) {
    return emptyBytes()
  }
  match findStream(state, streamId) {
    case None -> emptyBytes()
    case Some(st) -> {
      val s: H2Stream = st
      s.recvWindow = s.recvWindow + increment
      serializeFrame(WindowUpdateFrame(streamId = streamId, windowSizeIncrement = increment))
    }
  }
}

/// Produce a server-initiated `GOAWAY` for graceful shutdown (RFC 9113 section
/// 6.8), naming the highest peer stream id processed so far as the last one the
/// server will act on. Marks `goAwayWasSent` and records that last-stream-id, so
/// the FSM subsequently refuses new peer streams above it (#6086 / §6.8). Does
/// not poison the connection — streams at or below the advertised id may still
/// complete.
@experimental
pub func sendGoAway(conn: in H2Connection, errorCode: in H2ErrorCode): slice[Byte] {
  var state = conn
  state.shutdown.goAwaySent = true
  state.shutdown.goAwayLastStreamId = state.lastPeerStreamId
  serializeFrame(GoAwayFrame(lastStreamId = state.lastPeerStreamId, errorCode = errorCode, debugData = emptyBytes()))
}
