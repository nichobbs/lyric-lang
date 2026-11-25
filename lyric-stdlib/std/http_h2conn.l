//! std/http_h2conn.l — pure-Lyric, sans-IO HTTP/2 connection and stream
//! state machine with flow control (RFC 9113 §3/§5/§6, D128; phase 4.3 of
//! epic #5874, issue #5888).
//!
//! `Std.HttpEngine.H2Conn` is the top of the pure-Lyric HTTP/2 stack, for both
//! connection roles. It composes the two shipped building blocks — the frame codec
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
//! ## Scope (issue #5888, docs/72 slice 1)
//!
//! One connection/stream FSM serves both roles, chosen at construction:
//! `newServerConnection` and `newClientConnection` return the same
//! `H2Connection` type with an `H2Role` recorded in its `H2RoleState`. Every
//! role-neutral rule (frame codec, HPACK, SETTINGS, flow control, PING,
//! CONTINUATION assembly, field validation) is shared; the role gates only
//! which side may open streams, which header block is a request, a response
//! or a trailer section, which ids are idle, the GOAWAY semantics, and whether
//! the Rapid-Reset mitigation applies (it is server-side: a client sees
//! server-sent `RST_STREAM` as routine). It implements, per RFC 9113:
//!
//!   - the §3.4 connection-preface exchange (a server's decoder matches the
//!     24-octet client preface and its initial `SETTINGS` frame is
//!     `serverInitialFrame`; a client writes `clientInitialBytes`, the preface
//!     plus its `SETTINGS`, and requires a `SETTINGS` frame first from the
//!     server);
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
//!     one for graceful shutdown. A client additionally records the peer's
//!     last-stream-id (it may only decrease), refuses to open new streams, and
//!     closes every stream above that id with `H2StreamUnprocessed` (safe to
//!     retry elsewhere, RFC 9113 §8.7);
//!   - client request/response messaging (§8.1, §8.3.2): `openStream` allocates
//!     the next odd stream id under the peer's `SETTINGS_MAX_CONCURRENT_STREAMS`
//!     and frames the request HEADERS; response blocks are validated
//!     (`malformedResponseReason`) and surfaced as `H2InformationalHeaders`,
//!     `H2ResponseHeaders`, `H2ResponseData` and `H2ResponseTrailers`;
//!   - the RFC's error classification (§5.4): a connection error appends a
//!     `GOAWAY` and poisons the connection; a stream error appends a
//!     `RST_STREAM` and closes just that stream.
//!
//! Deliberately **out of scope** (per the issue and RFC 9113): no server push
//! (`PUSH_PROMISE` is a `PROTOCOL_ERROR` for a server, and for a client, which
//! always advertises `SETTINGS_ENABLE_PUSH = 0`, §6.6), and no
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
//! FSM internals — construct one only via `newServerConnection` or
//! `newClientConnection`, and observe
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
//!   - **Closed streams are retained only within a bounded trailing window.**
//!     A late WINDOW_UPDATE/RST_STREAM on a just-closed stream is correctly
//!     treated as a harmless no-op rather than an idle-stream error; this
//!     holds for *any* closed stream, pruned or not, because `isIdleStreamId`
//!     classifies a lookup miss as "forgotten, not idle" for any id at or
//!     below `lastPeerStreamId` regardless of whether a record for it
//!     survives (RFC 9113 section 5.1). `pruneClosedStreams` reclaims a
//!     `H2SClosed` record once its id has scrolled
//!     `h2ClosedStreamRetentionWindow()` stream-slots behind
//!     `lastPeerStreamId`, bounding `H2Connection.streams` growth on a
//!     long-lived connection (#6064) — the window exists to keep a
//!     recently-closed stream's exact terminal event (e.g. a late
//!     `RST_STREAM`'s `H2PeerReset`) observable for longer, not because
//!     pruning any sooner would be unsafe.
//!   - **A codec-detected stream-level frame fault is escalated to a
//!     connection error.** The two such faults (`PRIORITY` of the wrong length,
//!     a zero `WINDOW_UPDATE` increment on a stream) do not carry a stream id
//!     through `H2Frame.FrameError`, so the FSM cannot target a `RST_STREAM`;
//!     it sends a `GOAWAY` instead. RFC 9113 §5.4 permits treating a stream
//!     error more severely, and `PRIORITY` is ignored/deprecated regardless.
//!   - **A duplicate/late HEADERS reusing an already-used stream id is a
//!     connection `PROTOCOL_ERROR`, whether or not the target stream's
//!     record is still retained — except the one case RFC 9113 itself
//!     singles out for per-stream leniency.** `handleHeaders` used to
//!     dispatch purely on whether `findStream` still held a record — a
//!     pruning-introduced divergence where the identical wire frame got a
//!     different error *severity* depending only on internal bookkeeping
//!     the peer cannot observe (#6562). Resolved (D-progress-816): a
//!     retained `H2SHalfClosedRemote` stream still routes through
//!     `beginTrailerHeaders` to a per-stream `streamFail` (RFC 9113 section
//!     5.1's half-closed (remote) state is explicit that anything but
//!     WINDOW_UPDATE/PRIORITY/RST_STREAM there "MUST" get a stream error,
//!     not a connection error — a deliberate spec carve-out, unaffected by
//!     pruning since a half-closed-remote record is always retained; #6075
//!     predates #6064's pruning work). Every other way the target id can be
//!     "already used" — a retained, fully `H2SClosed` record, or a
//!     pruned/never-retained id at or below `lastPeerStreamId` — now
//!     produces a connection `connFail` with `H2ProtocolError`: RFC 9113
//!     section 5.1.1's "unexpected stream identifier" rule treats the frame
//!     as indistinguishable from an attempt to open a new stream whose id
//!     violates the monotonic ordering already established, and section
//!     5.1's general catch-all independently backs a connection error for
//!     any frame type a closed stream's state does not explicitly permit.
//!     Never misclassifies a lookup miss as an *idle* (never-opened) stream
//!     either way. See `http_h2conn_tests.l`'s "duplicate HEADERS against a
//!     pruned stream id" case and its retained-`H2SClosed` mirror.
//!   - **`streamState`'s `H2SIdle` result is ambiguous between "never seen"
//!     and "closed and pruned."** Unlike the internal frame-dispatch path
//!     (which distinguishes the two via `isIdleStreamId`), the public query
//!     function reports `H2SIdle` for both a genuinely never-opened stream id
//!     and one that was opened, closed, and later reclaimed by
//!     `pruneClosedStreams`. See `streamState`'s own doc comment and #6572.
@runtime_checked
@pure
package Std.HttpEngine.H2Conn

import Std.Core
import Std.Collections
import Std.Char as Ch
import Std.String as Str
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
pub ref record H2Settings {
  var headerTableSize: Int
  var enablePush: Int
  var maxConcurrentStreams: Int
  var initialWindowSize: Int
  var maxFrameSize: Int
  var maxHeaderListSize: Int
}

/// True when `settings` is something this endpoint may advertise (RFC 9113
/// §6.5.2): a frame size in 16384..16777215, an initial window in
/// 0..2^31-1, push disabled (a server never enables it and a client, which
/// cannot accept it, must advertise 0), and non-negative
/// table, stream and header-list limits. Peer settings are validated as
/// data when a SETTINGS frame arrives; this guards the local configuration.
@pure
@experimental
pub func isValidLocalSettings(settings: in H2Settings): Bool {
  settings.maxFrameSize >= 16384 and settings.maxFrameSize <= 16777215 and settings.initialWindowSize >= 0 and
    settings.enablePush == 0 and
    settings.headerTableSize >= 0 and
    settings.maxConcurrentStreams >= 0 and
    settings.maxHeaderListSize >= 0
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

/// The default settings a client advertises: RFC-default header table and
/// frame size, push disabled (`enablePush = 0`, which is what lets a
/// `PUSH_PROMISE` be a connection error), a 1 MiB initial stream window so a
/// response is not throttled to 64 KiB per round trip, a concurrent-streams
/// ceiling of 100 (it caps only streams the peer initiates, so with push off it
/// is advisory), and a 32 KiB advisory header-list cap. The connection-level
/// receive window is not a setting; raise it with `grantConnectionWindow`.
@pure
@experimental
pub func h2DefaultClientSettings(): H2Settings {
  H2Settings(
    headerTableSize = 4096,
    enablePush = 0,
    maxConcurrentStreams = 100,
    initialWindowSize = 1048576,
    maxFrameSize = 16384,
    maxHeaderListSize = 32768
  )
}

/// The default settings assumed for the peer before its `SETTINGS` frame
/// arrives (RFC 9113 §6.5.2 initial values): 4096 header table, push enabled
/// (never acted on: this FSM does not implement push in either role), no
/// concurrent-stream limit applied to us, 65535 initial window, 16384 frame
/// size.
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
/// The per-stream lifecycle states tracked (RFC 9113 §5.1), from this
/// endpoint's point of view: "local" is this endpoint's sending side, "remote"
/// the peer's. The two reserved states are omitted: push is not implemented, so
/// `reserved (local)` never occurs, and a `PUSH_PROMISE` is never valid, so
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
///   - `H2RequestData(streamId, data, endStream, wireLength)` — a slice of
///     request-body payload (padding already stripped by the frame layer).
///     `wireLength` is the full on-wire DATA payload length (padding
///     included) that was debited from the receive windows; a consumer that
///     grants window credit back MUST replenish by `wireLength`, not
///     `data.length`, or padded frames drift the windows (RFC 9113 §6.9.1).
///   - `H2PingReceived(opaqueData)` — the peer sent a `PING`; a `PING` ACK has
///     been queued in `outbound`.
///   - `H2PingAcknowledged(opaqueData)` — the peer acknowledged our `PING`.
///   - `H2WindowUpdated(streamId)` — a peer `WINDOW_UPDATE` replenished a send
///     window (`streamId = 0` is the connection window); the driver may resume
///     sending.
///   - `H2PeerReset(streamId, errorCode)` — the peer reset a stream.
///   - `H2GoAwayReceived(lastStreamId, errorCode)` — the peer is shutting the
///     connection down gracefully.
///
/// Client-role events (a server-role connection never emits them, and a
/// client-role connection never emits `H2RequestHeaders`/`H2RequestData`):
///
///   - `H2InformationalHeaders(streamId, status, headers)` — a 1xx header block
///     (never final, never ends the stream, may repeat); the final response
///     still follows.
///   - `H2ResponseHeaders(streamId, status, headers, endStream)` — the final
///     response header block, `headers` being the whole validated list
///     including `:status` (as `H2RequestHeaders` includes its pseudo-headers).
///     `endStream` is a Trailers-Only response: gRPC `grpc-status` and
///     `grpc-message` then arrive in `headers`.
///   - `H2ResponseData(streamId, data, endStream, wireLength)` — response body
///     payload, with the same `wireLength` rule as `H2RequestData`.
///   - `H2ResponseTrailers(streamId, headers)` — a trailer section (always
///     carries END_STREAM; no pseudo-headers).
///   - `H2StreamUnprocessed(streamId)` — a peer `GOAWAY` named a last-stream-id
///     below this locally opened stream, so the peer did not and will not act
///     on it: the stream is closed and the request is safe to retry on another
///     connection. Distinct from `H2PeerReset`, whose `H2RefusedStream` is also
///     retry-safe (RFC 9113 §8.7) but arrives as a reset.
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
  case H2RequestData(streamId: Int, data: slice[Byte], endStream: Bool, wireLength: Int)
  case H2PingReceived(opaqueData: slice[Byte])
  case H2PingAcknowledged(opaqueData: slice[Byte])
  case H2WindowUpdated(streamId: Int)
  case H2PeerReset(streamId: Int, errorCode: H2ErrorCode)
  case H2GoAwayReceived(lastStreamId: Int, errorCode: H2ErrorCode)
  case H2InformationalHeaders(streamId: Int, status: Int, headers: List[HeaderField])
  case H2ResponseHeaders(streamId: Int, status: Int, headers: List[HeaderField], endStream: Bool)
  case H2ResponseData(streamId: Int, data: slice[Byte], endStream: Bool, wireLength: Int)
  case H2ResponseTrailers(streamId: Int, headers: List[HeaderField])
  case H2StreamUnprocessed(streamId: Int)
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
///     permits this endpoint to send DATA (unknown, idle, half-closed-local, or
///     closed).
@experimental
pub union H2FlowError {
  case WindowExceeded(available: Int, requested: Int)
  case StreamNotWritable(streamId: Int)
}

/// The error returned by `encodeResponseHeaders`.
///
///   - `HeaderStreamNotWritable(streamId)` — the stream is not in a state that
///     permits this endpoint to send HEADERS (unknown, idle, half-closed-local,
///     closed, or the connection is failed).
///   - `HeaderEncodingFailed(error)` — HPACK encoding failed (a pending encoder
///     table resize that exceeds the negotiated size).
@experimental
pub union H2SendError {
  case HeaderStreamNotWritable(streamId: Int)
  case HeaderEncodingFailed(error: HpackError)
}

/// Which side of the connection this FSM plays. Fixed at construction.
@experimental
pub enum H2Role {
  case H2Server
  case H2Client
}

/// Where a stream is in the response message sequence (RFC 9113 §8.1), tracked
/// for a client: `H2PhaseAwaitFinal` until the final (non-1xx) header block,
/// `H2PhaseBody` after it (DATA and then optionally one trailer section),
/// `H2PhaseDone` once the trailers or END_STREAM ended the message.
@experimental
pub enum H2HeaderPhase {
  case H2PhaseAwaitFinal
  case H2PhaseBody
  case H2PhaseDone
}

/// The error returned by `openStream` when a request cannot be started.
///
///   - `OpenConnectionFailed` — a connection-level error poisoned the connection.
///   - `OpenConnectionDraining` — a `GOAWAY` was received or sent: open the
///     request on another connection.
///   - `OpenStreamLimitReached(active, limit)` — `active` locally opened streams
///     already meet the peer's `SETTINGS_MAX_CONCURRENT_STREAMS` `limit`
///     (§5.1.2); queue and retry once a stream closes.
///   - `OpenStreamIdsExhausted` — the 2^31-1 stream-id space is used up (§5.1.1);
///     open a new connection.
///   - `OpenHeaderListTooLarge(size, limit)` — the header list (name + value + 32
///     octets per field, §6.5.2) exceeds the peer's advertised
///     `SETTINGS_MAX_HEADER_LIST_SIZE`.
///   - `OpenHeaderEncodingFailed(error)` — HPACK encoding failed.
@experimental
pub union H2OpenError {
  case OpenConnectionFailed
  case OpenConnectionDraining
  case OpenStreamLimitReached(active: Int, limit: Int)
  case OpenStreamIdsExhausted
  case OpenHeaderListTooLarge(size: Int, limit: Int)
  case OpenHeaderEncodingFailed(error: HpackError)
}

/// What `openStream` returns: the allocated stream id and the serialized
/// HEADERS (+ CONTINUATION) frames to write, in order, on the connection.
@experimental
pub record H2OpenResult {
  streamId: Int
  bytes: slice[Byte]
}

// =============================================================================
// §3. Internal FSM state.
// =============================================================================
/// One tracked stream. `sendWindow` is how many DATA bytes this endpoint may
/// still send (governed by the peer's initial window + `WINDOW_UPDATE`);
/// `recvWindow` is how many the peer may still send us (governed by our
/// advertised initial window + the `WINDOW_UPDATE`s we emit via `grant*`).
/// Reference semantics: a stream fetched from `H2Connection.streams` and
/// mutated in place updates the tracked value.
///
/// The last four fields are client bookkeeping: the response `phase`, the
/// request method (a HEAD response carries no body whatever its
/// `content-length`), the final `responseStatus`, and `resetLocal`, set when
/// this endpoint sent `RST_STREAM`, so frames the peer had already queued for
/// the stream are discarded rather than treated as errors (RFC 9113 §5.1,
/// "closed").
@experimental
pub ref record H2Stream {
  id: Int
  var state: H2StreamState
  var sendWindow: Int
  var recvWindow: Int
  var expectedContentLength: Long = -1i64
  var receivedDataBytes: Long = 0i64
  var phase: H2HeaderPhase = H2PhaseAwaitFinal
  var requestMethod: String = ""
  var responseStatus: Int = 0
  var resetLocal: Bool = false
}

/// In-progress HEADERS + CONTINUATION reassembly (§6.10). `accepted` is false
/// for a refused stream whose block must still be HPACK-decoded to keep the
/// compression context in sync (§4.3), then discarded. `contFrames` counts the
/// CONTINUATION frames seen so far, bounding the "CONTINUATION flood" DoS (a
/// peer that never sets END_HEADERS and sends endless zero-length fragments,
/// which the byte-budget guard alone would never stop) — see
/// `maxContinuationFrames`.
@experimental
pub ref record ContinuationState {
  streamId: Int
  buffer: List[Byte]
  endStream: Bool
  accepted: Bool
  // A trailer block (HEADERS after the request's first header block) is
  // validated as trailers: no pseudo-header fields (RFC 9113 section 8.1).
  isTrailer: Bool = false
  var contFrames: Int
}

/// The connection's shutdown / abuse-mitigation bookkeeping, grouped into a
/// sub-record. `goAwaySent`/`goAwayLastStreamId` drive the post-GOAWAY
/// new-stream refusal (§6.8); `goAwayReceived` records a peer GOAWAY;
/// `rapidResetCount`/`serverCompletedCount` are the Rapid-Reset
/// (CVE-2023-44487) counter and its completion credit (a server-role
/// mitigation: a client never advances either).
///
/// This is a separate record purely to keep `H2Connection`'s constructor arity
/// low: the self-hosted JVM backend under-computes a record constructor's
/// `max_stack` at ~15+ fields, so a flat 17-field `H2Connection` fails
/// bytecode verification (`Operand stack overflow` in `newServerConnection`).
/// Grouping five fields here keeps the arity safely under that threshold.
/// Filed as #6089.
@experimental
pub ref record H2ShutdownState {
  var goAwaySent: Bool
  var goAwayLastStreamId: Int
  var goAwayReceived: Bool
  var rapidResetCount: Int
  var serverCompletedCount: Int
}

/// The connection's role and the stream-id bookkeeping that depends on it,
/// kept in a sub-record for the same arity reason as `H2ShutdownState`
/// (#6089): `H2Connection` stays at 13 fields.
///
///   - `role` — fixed at construction.
///   - `nextLocalStreamId` — the id `openStream` allocates next (odd, client
///     only), as a `Long` because the id after 2^31-1 does not fit `Int`; a
///     value above 2^31-1 means the id space is exhausted.
///   - `highestPeerStreamId` — the highest peer-initiated stream id seen: the
///     server's client-stream high-water mark. Always 0 for a client, whose
///     peer cannot initiate streams (push is disabled).
///   - `expectPeerSettings` — the peer's first frame must be a non-ACK
///     `SETTINGS` (RFC 9113 §3.4); cleared once it arrives.
///   - `peerGoAwayLastStreamId` — the lowest last-stream-id of any `GOAWAY`
///     received (2^31-1 before one arrives; RFC 9113 §6.8 forbids raising it).
@experimental
pub ref record H2RoleState {
  role: H2Role
  var nextLocalStreamId: Long
  var highestPeerStreamId: Int
  var expectPeerSettings: Bool
  var peerGoAwayLastStreamId: Int
}

/// Per-connection FSM state. A reference value threaded through `feed` and the
/// send/grant helpers; construct only via `newServerConnection` or
/// `newClientConnection`, observe only via the query functions and `feed`'s
/// events. See the module header for its lifecycle contract.
@experimental
pub ref record H2Connection {
  var dec: FrameDecoder
  hpackDec: HpackDecoder
  hpackEnc: HpackEncoder
  localSettings: H2Settings
  remoteSettings: H2Settings
  var connSendWindow: Int
  var connRecvWindow: Int
  var streams: List[H2Stream]
  // The same `H2Stream` records as `streams`, keyed by id, so the per-frame
  // stream lookup is O(1) (#7269). `streams` keeps the id-ordered sequence
  // the iteration and pruning passes need; both are updated together.
  streamIndex: Map[Int, H2Stream]
  var cont: Option[ContinuationState]
  roleState: H2RoleState
  var fatal: Bool
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
pub func newServerConnection(localSettings: in H2Settings): H2Connection
  requires: isValidLocalSettings(localSettings)
{
  H2Connection(
    dec = newFrameDecoderWithMaxSize(true, localSettings.maxFrameSize),
    hpackDec = newDecoder(localSettings.headerTableSize),
    hpackEnc = newEncoder(4096, true),
    localSettings = localSettings,
    remoteSettings = h2DefaultPeerSettings(),
    connSendWindow = h2InitialWindow(),
    connRecvWindow = h2InitialWindow(),
    streams = newList(),
    streamIndex = newMap(),
    cont = noContinuation(),
    roleState = H2RoleState(
      role = H2Server,
      nextLocalStreamId = 2i64,
      highestPeerStreamId = 0,
      expectPeerSettings = true,
      peerGoAwayLastStreamId = h2MaxWindow()
    ),
    fatal = false,
    shutdown = newShutdownState()
  )
}

func newShutdownState(): H2ShutdownState {
  H2ShutdownState(
    goAwaySent = false,
    goAwayLastStreamId = 0,
    goAwayReceived = false,
    rapidResetCount = 0,
    serverCompletedCount = 0
  )
}

/// A fresh client-side connection. `localSettings` is what the client
/// advertises (see `h2DefaultClientSettings`; `enablePush` must be 0); the
/// peer's settings default to RFC initial values until the server's `SETTINGS`
/// frame arrives. Write `clientInitialBytes(conn)` to the peer before anything
/// else; request HEADERS may follow immediately (RFC 9113 §3.4), without
/// waiting for the server's `SETTINGS`. The first stream id is 1.
@pure
@experimental
pub func newClientConnection(localSettings: in H2Settings): H2Connection
  requires: isValidLocalSettings(localSettings)
{
  newClientConnectionAt(localSettings, 1)
}

/// `newClientConnection` whose first stream id is `firstStreamId` (odd, at
/// least 1, RFC 9113 §5.1.1 allows any odd start). It exists so a caller can
/// exercise `OpenStreamIdsExhausted`, which a real connection reaches only
/// after 2^30 requests.
@pure
@experimental
pub func newClientConnectionAt(localSettings: in H2Settings, firstStreamId: in Int): H2Connection
  requires: isValidLocalSettings(localSettings)
  requires: firstStreamId >= 1 and firstStreamId % 2 == 1
{
  H2Connection(
    // A client never receives the 24-octet preface: it sends it.
    dec = newFrameDecoderWithMaxSize(false, localSettings.maxFrameSize),
    hpackDec = newDecoder(localSettings.headerTableSize),
    hpackEnc = newEncoder(4096, true),
    localSettings = localSettings,
    remoteSettings = h2DefaultPeerSettings(),
    connSendWindow = h2InitialWindow(),
    connRecvWindow = h2InitialWindow(),
    streams = newList(),
    streamIndex = newMap(),
    cont = noContinuation(),
    roleState = H2RoleState(
      role = H2Client,
      nextLocalStreamId = firstStreamId.toLong(),
      highestPeerStreamId = 0,
      expectPeerSettings = true,
      peerGoAwayLastStreamId = h2MaxWindow()
    ),
    fatal = false,
    shutdown = newShutdownState()
  )
}

func isClientRole(state: in H2Connection): Bool {
  match state.roleState.role {
    case H2Client -> true
    case H2Server -> false
  }
}

/// This connection's role.
@pure
@experimental
pub func connectionRole(conn: in H2Connection): H2Role {
  conn.roleState.role
}

/// True for a connection built by `newClientConnection`.
@pure
@experimental
pub func isClientConnection(conn: in H2Connection): Bool {
  isClientRole(conn)
}

/// True for a connection built by `newServerConnection`.
@pure
@experimental
pub func isServerConnection(conn: in H2Connection): Bool {
  not isClientRole(conn)
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
pub func serverInitialFrame(conn: in H2Connection): slice[Byte]
  requires: isServerConnection(conn)
{
  buildSettingsFrame(conn.localSettings)
}

/// The client's initial bytes (RFC 9113 §3.4): the 24-octet connection preface
/// followed by the client's `SETTINGS` frame, in one slice. The client MUST
/// write these before anything else on the connection. To also widen the
/// connection-level receive window (a setting cannot), append
/// `grantConnectionWindow(conn, n)`.
@pure
@experimental
pub func clientInitialBytes(conn: in H2Connection): slice[Byte]
  requires: isClientConnection(conn)
{
  val outb: List[Byte] = newList()
  appendBytes(outb, connectionPreface())
  appendBytes(outb, buildSettingsFrame(conn.localSettings))
  outb.toArray()
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
  mapGet(state.streamIndex, streamId)
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
    recvWindow = state.localSettings.initialWindowSize,
    expectedContentLength = -1i64,
    receivedDataBytes = 0i64,
    phase = H2PhaseAwaitFinal,
    requestMethod = "",
    responseStatus = 0,
    resetLocal = false
  )
  state.streams.add(st)
  state.streamIndex[streamId] = st
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

/// This endpoint sent END_STREAM: it will send nothing further on this stream.
/// On a server, a stream whose response it completes counts toward
/// `serverCompletedCount`, the "legitimate work" credit that offsets the
/// Rapid-Reset counter (§ `maxRapidResets`); a client keeps no such count.
func markEndStreamSent(state: inout H2Connection, streamId: in Int): Unit {
  val credit = if isClientRole(state) { 0 } else { 1 }
  match findStream(state, streamId) {
    case None -> ()
    case Some(st) -> {
      val s: H2Stream = st
      match s.state {
        case H2SOpen -> {
          s.state = H2SHalfClosedLocal
          state.shutdown.serverCompletedCount = state.shutdown.serverCompletedCount + credit
        }
        case H2SHalfClosedRemote -> {
          s.state = H2SClosed
          state.shutdown.serverCompletedCount = state.shutdown.serverCompletedCount + credit
        }
        case H2SIdle -> ()
        case H2SHalfClosedLocal -> ()
        case H2SClosed -> ()
      }
    }
  }
}

/// This endpoint is sending `RST_STREAM` on `streamId`: frames the peer had
/// already queued for it are expected and discarded (RFC 9113 §5.1, "closed").
func markResetLocal(state: inout H2Connection, streamId: in Int): Unit {
  match findStream(state, streamId) {
    case None -> ()
    case Some(st) -> {
      val s: H2Stream = st
      s.resetLocal = true
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
/// id is a server-initiated (push) id that neither role ever opens, so it is
/// always idle. Server: an odd id above the client high-water mark has not been
/// opened yet, and one at or below it is a client stream that was
/// opened-and-closed (or implicitly closed by a higher id, §5.1.1) and since
/// forgotten. Client: an odd id at or above `nextLocalStreamId` has not been
/// allocated yet; a lower one was opened here and has since closed.
func isIdleStreamId(state: in H2Connection, streamId: in Int): Bool {
  if streamId % 2 == 0 {
    return true
  }
  if isClientRole(state) {
    streamId.toLong() >= state.roleState.nextLocalStreamId
  } else {
    streamId > state.roleState.highestPeerStreamId
  }
}

/// The highest stream id this endpoint has seen opened, which anchors closed
/// stream pruning: the peer's high-water mark for a server, the last id this
/// client allocated for a client.
func streamIdHighWater(state: in H2Connection): Int {
  if isClientRole(state) {
    val last = state.roleState.nextLocalStreamId - 2i64
    if last <= 0i64 {
      0
    } else if last > 2147483647i64 {
      2147483647
    } else {
      last.toInt()
    }
  } else {
    state.roleState.highestPeerStreamId
  }
}

/// How many trailing client stream-id slots (each 2 apart — client ids are
/// odd) a `H2SClosed` record is kept for after closing, before
/// `pruneClosedStreams` reclaims it (#6064). Bounds `H2Connection.streams`
/// growth on a connection that opens many streams over its lifetime while
/// keeping a generous margin over the default concurrent-streams ceiling
/// (128, `h2DefaultServerSettings`) so a closed stream's exact terminal
/// event stays observable well past any realistic close/reopen race.
/// Pruning past this window is a bookkeeping choice, not a safety boundary:
/// see the module header note above `isIdleStreamId` for why a lookup miss
/// on *any* id at or below `lastPeerStreamId` — pruned or never retained —
/// is always classified as "forgotten, not idle".
@pure
@experimental
pub func h2ClosedStreamRetentionWindow(): Int {
  200
}

func isClosedState(s: in H2StreamState): Bool {
  match s {
    case H2SClosed -> true
    case _ -> false
  }
}

/// Drop `H2SClosed` records whose id has scrolled more than
/// `h2ClosedStreamRetentionWindow()` stream-slots behind
/// `streamIdHighWater(state)`. Never touches an idle/open/half-closed record —
/// only fully `H2SClosed` entries are eligible — so an active stream's flow-
/// control bookkeeping is never disturbed, and `isIdleStreamId`'s
/// id-and-high-water-mark-only test still classifies a pruned id exactly as
/// it would an unpruned one (see `h2ClosedStreamRetentionWindow`).
func pruneClosedStreams(state: inout H2Connection): Unit {
  // Cheap escape hatch: the total retained-stream count is an upper bound on
  // how many *closed* records could possibly be prunable, so there is
  // nothing to do until it exceeds the window. This bound is by *count*, not
  // by id-distance — a client whose HEADERS skip large id ranges (e.g. every
  // refused/idle id in between is never retained at all) can have a small
  // `streams.count` while some of those few entries are already past the
  // id-distance threshold below. That only delays reclaiming them a little
  // longer, never grows them unboundedly: the next stream this connection
  // opens pushes `streams.count` up again, and pruning catches up once it
  // crosses the window. Not a safety concern, just an imprecise trigger.
  if state.streams.count <= h2ClosedStreamRetentionWindow() {
    return
  }
  val threshold = streamIdHighWater(state) - h2ClosedStreamRetentionWindow() * 2
  if threshold <= 0 {
    return
  }
  // `streams` is in ascending id order (peer stream ids only increase, RFC
  // 9113 section 5.1.1, and `createStream` appends), so only the prefix below
  // `threshold` can hold prunable records. Scan just that prefix and rebuild
  // the list only when it holds one: without this, every `feed` past the
  // retention count rebuilt the whole list (#7269).
  var j = 0
  var anyPrunable = false
  while j < state.streams.count and not anyPrunable {
    val st: H2Stream = state.streams[j]
    if st.id >= threshold {
      return
    }
    anyPrunable = isClosedState(st.state)
    j = j + 1
  }
  if not anyPrunable {
    return
  }
  val kept: List[H2Stream] = newList()
  var i = 0
  while i < state.streams.count {
    val st: H2Stream = state.streams[i]
    if isClosedState(st.state) and st.id < threshold {
      state.streamIndex.remove(st.id)
    } else {
      kept.add(st)
    }
    i = i + 1
  }
  state.streams = kept
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
    serializeFrame(
      GoAwayFrame(lastStreamId = state.roleState.highestPeerStreamId, errorCode = code, debugData = emptyBytes())
    )
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
  // Rapid Reset is a server-side mitigation: a client resets its own streams
  // routinely (deadlines, cancellation) and never counts them.
  val incomplete = match findStream(state, streamId) {
    case None -> false
    case Some(st) -> {
      val s: H2Stream = st
      match s.state {
        case H2SOpen -> true
        case H2SHalfClosedRemote -> true
        case _ -> false
      }
    }
  }
  val serverIncomplete = incomplete and not isClientRole(state)
  closeStream(state, streamId)
  markResetLocal(state, streamId)
  appendBytes(outb, serializeFrame(RstStreamFrame(streamId = streamId, errorCode = code)))
  events.add(H2StreamErr(streamId = streamId, errorCode = code, message = message))
  if serverIncomplete {
    state.shutdown.rapidResetCount = state.shutdown.rapidResetCount + 1
    if state.shutdown.rapidResetCount > maxRapidResets() and state.shutdown.rapidResetCount > state.shutdown.serverCompletedCount {
      connFail(
        state,
        events,
        outb,
        H2EnhanceYourCalm,
        "excessive stream errors before completion (RFC 9113; Rapid Reset / CVE-2023-44487 mitigation)"
      )
    }
  }
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
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  lastStreamId: in Int,
  errorCode: in H2ErrorCode,
): Unit {
  if not isClientRole(state) {
    state.shutdown.goAwayReceived = true
    events.add(H2GoAwayReceived(lastStreamId = lastStreamId, errorCode = errorCode))
    return
  }
  // RFC 9113 section 6.8: an endpoint may send further GOAWAY frames only with a
  // last-stream-id no higher than the previous one.
  if lastStreamId > state.roleState.peerGoAwayLastStreamId {
    connFail(
      state,
      events,
      outb,
      H2ProtocolError,
      "GOAWAY raises the last-stream-id of an earlier GOAWAY (RFC 9113 section 6.8)"
    )
    return
  }
  state.shutdown.goAwayReceived = true
  state.roleState.peerGoAwayLastStreamId = lastStreamId
  events.add(H2GoAwayReceived(lastStreamId = lastStreamId, errorCode = errorCode))
  // Every stream this client opened above the last-stream-id was not and will
  // not be processed: close it and tell the driver it is safe to retry
  // elsewhere (section 6.8, section 8.7).
  var i = 0
  while i < state.streams.count {
    val st: H2Stream = state.streams[i]
    if st.id > lastStreamId and isActiveState(st.state) {
      st.state = H2SClosed
      st.resetLocal = true
      events.add(H2StreamUnprocessed(streamId = st.id))
    }
    i = i + 1
  }
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
      // The mitigation is server-side: a server-sent reset is routine to a client.
      val wasActive = isActiveState(s.state)
      val incomplete = match s.state { case H2SOpen -> true; case H2SHalfClosedRemote -> true; case _ -> false }
      val serverIncomplete = incomplete and not isClientRole(state)
      s.state = H2SClosed
      // A client that already closed the stream (its own reset, or the end of
      // the exchange) has nothing left to learn from the peer's reset.
      if wasActive or not isClientRole(state) {
        events.add(H2PeerReset(streamId = streamId, errorCode = errorCode))
      }
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
  wireLength: in Int,
): Unit {
  // Flow control accounts the full on-wire DATA payload (pad-length octet +
  // content + padding, §6.9.1), not just the decoded/unpadded `data` a padded
  // frame yields — `wireLength` carries that (#6063); `data` itself is only
  // ever used for its content below.
  if wireLength > state.connRecvWindow {
    connFail(
      state,
      events,
      outb,
      H2FlowControlError,
      "DATA overruns the connection receive window (RFC 9113 section 6.9.1)"
    )
    return
  }
  state.connRecvWindow = state.connRecvWindow - wireLength
  match findStream(state, streamId) {
    case None -> {
      if isIdleStreamId(state, streamId) {
        // A stream that was never opened: DATA before HEADERS is a connection
        // PROTOCOL_ERROR (RFC 9113 section 5.1 idle state).
        connFail(state, events, outb, H2ProtocolError, "DATA on an idle stream (RFC 9113 section 6.1)")
      } else if isClientRole(state) {
        // A stream this client opened, closed, and has since forgotten: the
        // server's DATA was queued before it saw our reset (or this is a stale
        // frame); discard it and give the connection window back.
        reclaimConnectionWindow(state, outb, wireLength)
      } else {
        // A recently-closed or just-refused stream (odd id at/below the client
        // high-water mark): a client that pipelined DATA before seeing our
        // RST_STREAM/refusal is racing an RFC-anticipated, retryable outcome
        // (SETTINGS_MAX_CONCURRENT_STREAMS refusal, or a close). Reject just the
        // stream and reclaim the connection flow-control window the frame
        // consumed — do NOT kill the whole connection.
        reclaimAndStreamFail(state, events, outb, streamId, wireLength)
      }
    }
    case Some(st) -> dispatchDataToStream(state, events, outb, st, data, endStream, wireLength)
  }
}

func dispatchDataToStream(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  st: in H2Stream,
  data: in slice[Byte],
  endStream: in Bool,
  wireLength: in Int,
): Unit {
  match st.state {
    case H2SOpen -> receiveData(state, events, outb, st, data, endStream, wireLength)
    case H2SHalfClosedLocal -> receiveData(state, events, outb, st, data, endStream, wireLength)
    case H2SIdle -> reclaimAndStreamFail(state, events, outb, st.id, wireLength)
    case H2SHalfClosedRemote -> reclaimAndStreamFail(state, events, outb, st.id, wireLength)
    case H2SClosed -> {
      if isClientRole(state) and st.resetLocal {
        reclaimConnectionWindow(state, outb, wireLength)
      } else {
        reclaimAndStreamFail(state, events, outb, st.id, wireLength)
      }
    }
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
  wireLength: in Int,
): Unit {
  if isClientRole(state) and phaseAwaitsFinal(st.phase) {
    reclaimConnectionWindow(state, outb, wireLength)
    streamFail(
      state,
      events,
      outb,
      st.id,
      H2ProtocolError,
      "DATA before the final response HEADERS (RFC 9113 section 8.1)"
    )
  } else if wireLength > st.recvWindow {
    // The connection window was already debited for this DATA (in handleData);
    // the stream is being reset, so give those octets back to the connection
    // window rather than leaking them (#6074) — matches the reclaim the
    // closed-stream path already performs.
    reclaimConnectionWindow(state, outb, wireLength)
    streamFail(
      state,
      events,
      outb,
      st.id,
      H2FlowControlError,
      "DATA overruns a stream receive window (RFC 9113 section 6.9.1)"
    )
  } else {
    val nextBytes = st.receivedDataBytes + data.length.toLong()
    val clMismatch = st.expectedContentLength >= 0i64 and
      (nextBytes > st.expectedContentLength or (endStream and nextBytes != st.expectedContentLength))
    if clMismatch {
      reclaimConnectionWindow(state, outb, wireLength)
      streamFail(
        state,
        events,
        outb,
        st.id,
        H2ProtocolError,
        "DATA payload length does not match content-length (RFC 9113 section 8.1.1)"
      )
    } else {
      st.recvWindow = st.recvWindow - wireLength
      st.receivedDataBytes = nextBytes
      if isClientRole(state) {
        events.add(H2ResponseData(streamId = st.id, data = data, endStream = endStream, wireLength = wireLength))
        if endStream {
          st.phase = H2PhaseDone
        }
      } else {
        events.add(H2RequestData(streamId = st.id, data = data, endStream = endStream, wireLength = wireLength))
      }
      if endStream {
        markEndStreamReceived(state, st.id)
      }
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
    val why = if isClientRole(state) {
      "HEADERS on a server-initiated (push) stream id, but push is disabled (RFC 9113 sections 5.1.1 and 6.6)"
    } else {
      "HEADERS with an even (server-initiated) stream id (RFC 9113 section 5.1.1)"
    }
    connFail(state, events, outb, H2ProtocolError, why)
    return
  }
  if isClientRole(state) {
    handleClientHeaders(state, events, outb, streamId, fragment, endStream, endHeaders)
    return
  }
  match findStream(state, streamId) {
    case None -> beginNewStreamHeaders(state, events, outb, streamId, fragment, endStream, endHeaders)
    case Some(st) -> beginTrailerHeaders(state, events, outb, st, fragment, endStream, endHeaders)
  }
}

func phaseAwaitsFinal(p: in H2HeaderPhase): Bool {
  match p {
    case H2PhaseAwaitFinal -> true
    case H2PhaseBody -> false
    case H2PhaseDone -> false
  }
}

/// A HEADERS frame arrived on an odd stream id at a client. Only a stream this
/// client opened can carry one: an id it has not allocated yet is HEADERS on an
/// idle stream (a connection error), and one it opened and has since forgotten
/// is a frame the server queued before it saw our reset, so its block is
/// decoded (to keep the HPACK context in sync, RFC 9113 section 4.3) and
/// discarded.
func handleClientHeaders(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  fragment: in slice[Byte],
  endStream: in Bool,
  endHeaders: in Bool,
): Unit {
  match findStream(state, streamId) {
    case Some(st) -> beginResponseHeaders(state, events, outb, st, fragment, endStream, endHeaders)
    case None -> {
      if isIdleStreamId(state, streamId) {
        connFail(state, events, outb, H2ProtocolError, "HEADERS on an idle stream (RFC 9113 section 5.1)")
      } else {
        beginAssembly(state, events, outb, streamId, fragment, endStream, endHeaders, false, false)
      }
    }
  }
}

/// Route a HEADERS frame on a retained client stream by where the stream's
/// response is: a block before the final status is a response (or 1xx) block,
/// a block after it is the trailer section and must end the stream.
func beginResponseHeaders(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  st: in H2Stream,
  fragment: in slice[Byte],
  endStream: in Bool,
  endHeaders: in Bool,
): Unit {
  val sid = st.id
  match st.state {
    case H2SOpen -> routeResponseBlock(state, events, outb, st, fragment, endStream, endHeaders)
    case H2SHalfClosedLocal -> routeResponseBlock(state, events, outb, st, fragment, endStream, endHeaders)
    case H2SHalfClosedRemote -> {
      // RFC 9113 section 5.1: more frames than WINDOW_UPDATE/PRIORITY/RST_STREAM
      // after the server's END_STREAM are a STREAM_CLOSED stream error. The
      // block is still decoded so the shared HPACK context stays in sync.
      streamFail(
        state,
        events,
        outb,
        sid,
        H2StreamClosed,
        "HEADERS on a half-closed (remote) stream (RFC 9113 section 5.1)"
      )
      beginAssembly(state, events, outb, sid, fragment, endStream, endHeaders, false, true)
    }
    case H2SClosed -> {
      if st.resetLocal {
        beginAssembly(state, events, outb, sid, fragment, endStream, endHeaders, false, false)
      } else {
        connFail(state, events, outb, H2StreamClosed, "HEADERS on a closed stream (RFC 9113 section 5.1)")
      }
    }
    case H2SIdle -> connFail(state, events, outb, H2ProtocolError, "HEADERS on an idle stream (RFC 9113 section 5.1)")
  }
}

func routeResponseBlock(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  st: in H2Stream,
  fragment: in slice[Byte],
  endStream: in Bool,
  endHeaders: in Bool,
): Unit {
  val sid = st.id
  match st.phase {
    case H2PhaseAwaitFinal -> beginAssembly(state, events, outb, sid, fragment, endStream, endHeaders, true, false)
    case H2PhaseBody -> {
      if endStream {
        beginAssembly(state, events, outb, sid, fragment, endStream, endHeaders, true, true)
      } else {
        streamFail(state, events, outb, sid, H2ProtocolError, "trailer HEADERS must carry END_STREAM (RFC 9113 section 8.1)")
        beginAssembly(state, events, outb, sid, fragment, endStream, endHeaders, false, true)
      }
    }
    case H2PhaseDone -> connFail(state, events, outb, H2ProtocolError, "HEADERS after the end of the response")
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
  if streamId <= state.roleState.highestPeerStreamId {
    connFail(
      state,
      events,
      outb,
      H2ProtocolError,
      "HEADERS opens a stream id that is not greater than all previous (RFC 9113 section 5.1.1)"
    )
    return
  }
  state.roleState.highestPeerStreamId = streamId
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
  beginAssembly(state, events, outb, streamId, fragment, endStream, endHeaders, accepted, false)
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
    match st.state {
      case H2SHalfClosedRemote -> {
        // RFC 9113 section 5.1's half-closed (remote) state is explicit and
        // narrow: "If an endpoint receives additional frames, other than
        // WINDOW_UPDATE, PRIORITY, or RST_STREAM, for a stream that is in
        // this state, it MUST respond with a stream error ... of type
        // STREAM_CLOSED" — a per-stream error, not a connection error. This
        // is a deliberate spec carve-out (unlike the H2SClosed/pruned-id
        // case below, RFC 9113 does not treat a HEADERS on a half-closed
        // (remote) stream as a monotonic-id violation), it is unaffected by
        // pruning (a half-closed-remote record is always retained — only
        // fully `H2SClosed` records are ever reclaimed by
        // `pruneClosedStreams`), and it predates #6064's pruning work
        // (#6075). Reject the stream, but STILL run the block through the
        // HPACK decoder (accepted = false → decode-and-discard) so the
        // connection's shared compression context stays in sync (RFC 9113
        // §4.3) — otherwise every subsequent header block on the
        // connection mis-decodes (#6082). This mirrors the
        // new-stream-refusal path.
        val sid = st.id
        streamFail(
          state,
          events,
          outb,
          sid,
          H2StreamClosed,
          "HEADERS on a half-closed (remote) stream (RFC 9113 section 5.1)"
        )
        beginAssembly(state, events, outb, sid, fragment, endStream, endHeaders, false, true)
      }
      case _ -> {
        // `H2SClosed` (both directions done — via clean END_STREAM or a
        // prior RST_STREAM), or, defensively, `H2SIdle` (unreachable in
        // practice: `findStream` only ever returns a retained record, and
        // `createStream` always creates one already `H2SOpen`). RFC 9113
        // section 5.1's general catch-all governs here — a frame type not
        // among the state's explicitly-permitted ones "SHOULD" be a
        // connection PROTOCOL_ERROR — and critically, this HEADERS is
        // wire-indistinguishable from an attempt to reuse an already-used
        // stream id, which section 5.1.1's monotonic-id rule always treats
        // as a connection error. #6562: this must match the severity a
        // HEADERS against this exact id gets once its record is reclaimed
        // by `pruneClosedStreams` and the lookup misses entirely
        // (`beginNewStreamHeaders`'s `streamId <= lastPeerStreamId` check,
        // a few lines below) — that path has always been a connFail, so
        // this one now is too, closing the pruning-introduced severity gap
        // between "retained and closed" vs. "pruned or never retained" for
        // the exact same wire-level violation. No HPACK decode-and-discard
        // here (matching the pruned-id path): the connection is about to be
        // poisoned and no further frame on it will be processed, so keeping
        // the compression context in sync is moot.
        connFail(
          state,
          events,
          outb,
          H2ProtocolError,
          "HEADERS reusing an already-used, now-closed stream id (RFC 9113 section 5.1.1)"
        )
      }
    }
    return
  }
  if not endStream {
    connFail(state, events, outb, H2ProtocolError, "trailer HEADERS must carry END_STREAM (RFC 9113 section 8.1)")
    return
  }
  beginAssembly(state, events, outb, st.id, fragment, endStream, endHeaders, true, true)
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
  isTrailer: in Bool,
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
    finalizeHeaders(state, events, outb, streamId, buffer, endStream, accepted, isTrailer)
  } else {
    state.cont = Some(
      value = ContinuationState(
        streamId = streamId,
        buffer = buffer,
        endStream = endStream,
        accepted = accepted,
        isTrailer = isTrailer,
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
    case None -> connFail(
      state,
      events,
      outb,
      H2ProtocolError,
      "CONTINUATION with no preceding HEADERS (RFC 9113 section 6.10)"
    )
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
        val trailer = cs.isTrailer
        state.cont = noContinuation()
        finalizeHeaders(state, events, outb, sid, buf, es, acc, trailer)
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
  isTrailer: in Bool,
): Unit {
  match decodeHeaderBlockLimited(state.hpackDec, buffer.toArray(), state.localSettings.maxHeaderListSize) {
    // The compressed-size check above does not bound the DECODED list: one
    // dynamic-table entry referenced by thousands of one-byte fields expands
    // a small block into a huge list (#7265). Decoding stopped part-way, so
    // the compression context is out of sync and the connection must fail.
    case Err(HeaderListTooLarge(_, _)) -> connFail(
      state,
      events,
      outb,
      H2EnhanceYourCalm,
      "decoded header list exceeds SETTINGS_MAX_HEADER_LIST_SIZE (RFC 9113 section 6.5.2)"
    )
    case Err(_) -> connFail(state, events, outb, H2CompressionError, "HPACK decoding failed (RFC 9113 section 4.3)")
    case Ok(headers) -> {
      if accepted and isClientRole(state) {
        finalizeResponseHeaders(state, events, outb, streamId, headers, endStream, isTrailer)
      } else if accepted {
        val problem = if isTrailer { malformedTrailerReason(headers) } else { malformedRequestReason(headers) }
        match problem {
          case Some(reason) -> streamFail(state, events, outb, streamId, H2ProtocolError, reason)
          case None -> {
            val clProblem = if isTrailer {
              match findStream(state, streamId) {
                case Some(st) -> {
                  val s: H2Stream = st
                  if s.expectedContentLength >= 0i64 and s.receivedDataBytes != s.expectedContentLength {
                    Some(value = "DATA payload length does not match content-length before trailers (RFC 9113 section 8.1.1)")
                  } else {
                    noHeaderProblem()
                  }
                }
                case None -> noHeaderProblem()
              }
            } else {
              val cl = extractRequestContentLength(headers)
              if endStream and cl > 0i64 {
                Some(value = "request HEADERS with END_STREAM has non-zero content-length (RFC 9113 section 8.1.1)")
              } else {
                if cl >= 0i64 {
                  match findStream(state, streamId) {
                    case Some(st) -> {
                      val s: H2Stream = st
                      s.expectedContentLength = cl
                    }
                    case None -> ()
                  }
                }
                noHeaderProblem()
              }
            }
            match clProblem {
              case Some(reason) -> streamFail(state, events, outb, streamId, H2ProtocolError, reason)
              case None -> {
                events.add(H2RequestHeaders(streamId = streamId, headers = headers, endStream = endStream))
                if endStream {
                  markEndStreamReceived(state, streamId)
                }
              }
            }
          }
        }
      }
    }
  }
}

/// A decoded response header block on a client stream: validate it, then
/// surface it as 1xx, final response headers, or trailers, advancing the
/// stream's response phase.
func finalizeResponseHeaders(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  streamId: in Int,
  headers: in List[HeaderField],
  endStream: in Bool,
  isTrailer: in Bool,
): Unit {
  match findStream(state, streamId) {
    case None -> ()
    case Some(found) -> {
      val st: H2Stream = found
      if isTrailer {
        finalizeResponseTrailers(state, events, outb, st, headers)
      } else {
        match malformedResponseReason(headers) {
          case Some(reason) -> streamFail(state, events, outb, streamId, H2ProtocolError, reason)
          case None -> finalizeValidResponse(state, events, outb, st, headers, endStream)
        }
      }
    }
  }
}

func finalizeResponseTrailers(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  st: in H2Stream,
  headers: in List[HeaderField],
): Unit {
  val streamId = st.id
  match malformedTrailerReason(headers) {
    case Some(reason) -> streamFail(state, events, outb, streamId, H2ProtocolError, reason)
    case None -> {
      if st.expectedContentLength >= 0i64 and st.receivedDataBytes != st.expectedContentLength {
        streamFail(
          state,
          events,
          outb,
          streamId,
          H2ProtocolError,
          "DATA payload length does not match content-length before trailers (RFC 9113 section 8.1.1)"
        )
      } else {
        st.phase = H2PhaseDone
        events.add(H2ResponseTrailers(streamId = streamId, headers = headers))
        markEndStreamReceived(state, streamId)
      }
    }
  }
}

func finalizeValidResponse(
  state: inout H2Connection,
  events: in List[H2Event],
  outb: in List[Byte],
  st: in H2Stream,
  headers: in List[HeaderField],
  endStream: in Bool,
): Unit {
  val streamId = st.id
  val status = responseStatusOf(headers)
  if status >= 100 and status < 200 {
    if endStream {
      streamFail(
        state,
        events,
        outb,
        streamId,
        H2ProtocolError,
        "an informational (1xx) response must not carry END_STREAM (RFC 9113 section 8.1)"
      )
    } else {
      events.add(H2InformationalHeaders(streamId = streamId, status = status, headers = headers))
    }
    return
  }
  // A HEAD response, 204 and 304 carry no content whatever `content-length`
  // says (RFC 9110 section 6.4.1), so any DATA on them is a length mismatch.
  val noContent = st.requestMethod == "HEAD" or status == 204 or status == 304
  val cl = extractRequestContentLength(headers)
  if endStream and not noContent and cl > 0i64 {
    streamFail(
      state,
      events,
      outb,
      streamId,
      H2ProtocolError,
      "response HEADERS with END_STREAM has non-zero content-length (RFC 9113 section 8.1.1)"
    )
    return
  }
  st.responseStatus = status
  st.expectedContentLength = if noContent { 0i64 } else { cl }
  st.phase = if endStream { H2PhaseDone } else { H2PhaseBody }
  events.add(H2ResponseHeaders(streamId = streamId, status = status, headers = headers, endStream = endStream))
  if endStream {
    markEndStreamReceived(state, streamId)
  }
}

/// The value of the `:status` pseudo-header of an already-validated response
/// block, or 0 if absent.
func responseStatusOf(headers: in List[HeaderField]): Int {
  var i = 0
  while i < headers.count {
    val h = headers[i]
    if h.name == ":status" and isStatusDigits(h.value) {
      return (charCodeAt(h.value, 0) - 48) * 100 + (charCodeAt(h.value, 1) - 48) * 10 + (charCodeAt(h.value, 2) - 48)
    }
    i = i + 1
  }
  0
}

/// Why a decoded response header block is malformed under RFC 9113 sections
/// 8.2 and 8.3.2, or `None`: exactly one `:status` of three digits (100 to
/// 599, and not 101, which HTTP/2 has no use for, RFC 9113 section 8.6) ahead
/// of every regular field and no other pseudo-header; lowercase token field
/// names; values with no CR, LF or NUL and no surrounding whitespace; no
/// connection-specific field; a well-formed, consistent `content-length`. A
/// malformed response is a stream error `PROTOCOL_ERROR` (section 8.1.1).
@experimental
pub func malformedResponseReason(headers: in List[HeaderField]): Option[String] {
  var sawRegular = false
  var sawStatus = false
  var sawContentLength = false
  var contentLengthVal = ""
  var i = 0
  while i < headers.count {
    val h = headers[i]
    val name = h.name
    if name.length == 0 {
      return Some(value = "empty header field name")
    }
    if not isValidH2FieldValue(h.value) {
      return Some(value = "header field '" + name + "' has an invalid value (CR, LF, NUL or surrounding whitespace)")
    }
    if name.substring(0, 1) == ":" {
      if sawRegular {
        return Some(value = "pseudo-header '" + name + "' after a regular header field")
      }
      if name == ":status" {
        if sawStatus {
          return Some(value = "duplicate :status")
        }
        if not isStatusDigits(h.value) {
          return Some(value = ":status is not three digits")
        }
        val code = (charCodeAt(h.value, 0) - 48) * 100 + (charCodeAt(h.value, 1) - 48) * 10 + (charCodeAt(h.value, 2) - 48)
        if code < 100 or code > 599 {
          return Some(value = ":status outside 100 to 599")
        }
        if code == 101 {
          return Some(value = "101 (Switching Protocols) is not valid in HTTP/2 (RFC 9113 section 8.6)")
        }
        sawStatus = true
      } else {
        return Some(value = "request or unknown pseudo-header '" + name + "' in a response")
      }
    } else {
      sawRegular = true
      if not isValidH2FieldName(name) {
        return Some(value = "header field name '" + name + "' is not a lowercase token")
      }
      if isConnectionSpecificField(name) {
        return Some(value = "connection-specific header field '" + name + "'")
      }
      if name == "content-length" {
        if parseH2ContentLength(h.value) < 0i64 {
          return Some(value = "invalid content-length header field")
        }
        if sawContentLength and contentLengthVal != h.value {
          return Some(value = "conflicting content-length header fields")
        }
        sawContentLength = true
        contentLengthVal = h.value
      }
    }
    i = i + 1
  }
  if not sawStatus {
    return Some(value = "missing :status")
  }
  None
}

/// Why a decoded request header list is malformed under RFC 9113 sections
/// 8.2 and 8.3.1, or `None` when it is well-formed.  A malformed request is
/// a stream error `PROTOCOL_ERROR` (section 8.1.1), never delivered to the
/// application: header values reaching an HTTP/1 intermediary with CR/LF,
/// or a request missing its method or path, are request-smuggling vectors
/// (#7231).
@experimental
pub func malformedRequestReason(headers: in List[HeaderField]): Option[String] {
  var sawRegular = false
  var method = ""
  var sawMethod = false
  var sawScheme = false
  var sawPath = false
  var sawAuthority = false
  var authorityVal = ""
  var sawHost = false
  var hostVal = ""
  var sawContentLength = false
  var contentLengthVal = ""
  var sawProtocol = false
  var i = 0
  while i < headers.count {
    val h = headers[i]
    val name = h.name
    if name.length == 0 {
      return Some(value = "empty header field name")
    }
    if not isValidH2FieldValue(h.value) {
      return Some(value = "header field '" + name + "' has an invalid value (CR, LF, NUL or surrounding whitespace)")
    }
    if name.substring(0, 1) == ":" {
      if sawRegular {
        return Some(value = "pseudo-header '" + name + "' after a regular header field")
      }
      if name == ":method" {
        if sawMethod {
          return Some(value = "duplicate :method")
        }
        sawMethod = true
        method = h.value
      } else if name == ":scheme" {
        if sawScheme {
          return Some(value = "duplicate :scheme")
        }
        sawScheme = true
      } else if name == ":path" {
        if sawPath {
          return Some(value = "duplicate :path")
        }
        if h.value.length == 0 {
          return Some(value = "empty :path")
        }
        sawPath = true
      } else if name == ":authority" {
        if sawAuthority {
          return Some(value = "duplicate :authority")
        }
        sawAuthority = true
        authorityVal = h.value
      } else if name == ":protocol" {
        if sawProtocol {
          return Some(value = "duplicate :protocol")
        }
        sawProtocol = true
      } else {
        return Some(value = "unknown or response pseudo-header '" + name + "'")
      }
    } else {
      sawRegular = true
      if not isValidH2FieldName(name) {
        return Some(value = "header field name '" + name + "' is not a lowercase token")
      }
      if isConnectionSpecificField(name) {
        return Some(value = "connection-specific header field '" + name + "'")
      }
      if name == "te" and h.value != "trailers" {
        return Some(value = "te header field other than 'trailers'")
      }
      if name == "host" {
        if sawHost and Str.toLower(hostVal) != Str.toLower(h.value) {
          return Some(value = "conflicting host header fields")
        }
        sawHost = true
        hostVal = h.value
      }
      if name == "content-length" {
        if parseH2ContentLength(h.value) < 0i64 {
          return Some(value = "invalid content-length header field")
        }
        if sawContentLength and contentLengthVal != h.value {
          return Some(value = "conflicting content-length header fields")
        }
        sawContentLength = true
        contentLengthVal = h.value
      }
    }
    i = i + 1
  }
  if sawAuthority and sawHost and Str.toLower(authorityVal) != Str.toLower(hostVal) {
    return Some(value = "conflicting :authority and host header fields (RFC 9113 section 8.3.1)")
  }
  if not sawMethod {
    return Some(value = "missing :method")
  }
  if method != "CONNECT" and not (sawScheme and sawPath) {
    return Some(value = "missing :scheme or :path")
  }
  None
}

func noHeaderProblem(): Option[String] {
  val p: Option[String] = None
  p
}

func parseH2ContentLength(v: in String): Long {
  if v.length == 0 {
    return -1i64
  }
  val maxBeforeMul = 922337203685477580i64
  var acc = 0i64
  var i = 0
  while i < v.length {
    val c = charCodeAt(v, i)
    if not isAsciiDigit(c) {
      return -1i64
    }
    val d = (c - 48).toLong()
    if acc > maxBeforeMul or (acc == maxBeforeMul and d > 7i64) {
      return -1i64
    }
    acc = acc * 10i64 + d
    i = i + 1
  }
  acc
}

func extractRequestContentLength(headers: in List[HeaderField]): Long {
  var i = 0
  while i < headers.count {
    val h = headers[i]
    if h.name == "content-length" {
      return parseH2ContentLength(h.value)
    }
    i = i + 1
  }
  -1i64
}

/// Why a decoded trailer block is malformed (RFC 9113 sections 8.1 and
/// 8.2), or `None`: trailers carry no pseudo-header fields, and every field
/// follows the same name and value rules as request headers.
@experimental
pub func malformedTrailerReason(headers: in List[HeaderField]): Option[String] {
  var i = 0
  while i < headers.count {
    val h = headers[i]
    if h.name.length > 0 and h.name.substring(0, 1) == ":" {
      return Some(value = "pseudo-header '" + h.name + "' in a trailer block")
    }
    if not isValidH2FieldName(h.name) {
      return Some(value = "header field name '" + h.name + "' is not a lowercase token")
    }
    if not isValidH2FieldValue(h.value) {
      return Some(value = "header field '" + h.name + "' has an invalid value (CR, LF, NUL or surrounding whitespace)")
    }
    if isConnectionSpecificField(h.name) {
      return Some(value = "connection-specific header field '" + h.name + "'")
    }
    i = i + 1
  }
  None
}

// A regular field name: one or more lowercase tchar characters (RFC 9110
// section 5.6.2; RFC 9113 section 8.2.1 forbids uppercase).
func isValidH2FieldName(name: in String): Bool {
  var i = 0
  while i < name.length {
    val c = charCodeAt(name, i)
    val ok = (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 33 or c == 35 or c == 36 or c == 37 or c == 38 or
      c == 39 or
      c == 42 or
      c == 43 or
      c == 45 or
      c == 46 or
      c == 94 or
      c == 95 or
      c == 96 or
      c == 124 or
      c == 126
    if not ok {
      return false
    }
    i = i + 1
  }
  name.length > 0
}

// No CTL bytes (0x00..0x1f except HTAB 0x09, or DEL 0x7f), and no leading or
// trailing SP/HTAB (RFC 9113 section 8.2.1 / RFC 9110 section 5.5).
func isValidH2FieldValue(v: in String): Bool {
  var i = 0
  while i < v.length {
    val c = charCodeAt(v, i)
    if (c < 32 and c != 9) or c == 127 {
      return false
    }
    i = i + 1
  }
  if v.length == 0 {
    return true
  }
  val first = charCodeAt(v, 0)
  val last = charCodeAt(v, v.length - 1)
  not (first == 32 or first == 9 or last == 32 or last == 9)
}

/// True when `name`/`value` is a regular field an HTTP/2 response may carry
/// (RFC 9113 §8.2): a lowercase token name that is not a connection-specific
/// field (`connection`, `keep-alive`, `proxy-connection`,
/// `transfer-encoding`, `upgrade`), and a value with no CR, LF or NUL and no
/// leading or trailing space or tab.
@pure
@experimental
pub func isH2ResponseFieldSafe(name: in String, value: in String): Bool {
  isValidH2FieldName(name) and not isConnectionSpecificField(name) and isValidH2FieldValue(value)
}

/// `encodeResponseHeaders`'s precondition: exactly one `:status`
/// pseudo-header, three ASCII digits, before every regular field (RFC 9113
/// §8.3.2 allows no other response pseudo-header), and every regular field
/// `isH2ResponseFieldSafe`.
@pure
@experimental
pub func isH2ResponseHeaderListSafe(headers: in List[HeaderField]): Bool {
  var statusCount = 0
  var i = 0
  while i < headers.count {
    val h = headers[i]
    if h.name == ":status" {
      if statusCount > 0 or i > 0 or not isStatusDigits(h.value) {
        return false
      }
      statusCount = 1
    } else if not isH2ResponseFieldSafe(h.name, h.value) {
      return false
    }
    i = i + 1
  }
  statusCount == 1
}

func isStatusDigits(v: in String): Bool {
  v.length == 3 and isAsciiDigit(charCodeAt(v, 0)) and isAsciiDigit(charCodeAt(v, 1)) and isAsciiDigit(charCodeAt(v, 2))
}

func isAsciiDigit(c: in Int): Bool {
  c >= 48 and c <= 57
}

func isConnectionSpecificField(name: in String): Bool {
  name == "connection" or name == "proxy-connection" or name == "keep-alive" or name == "transfer-encoding" or
    name == "upgrade"
}

// The code unit at `i`.  Header strings decoded from the wire are Latin-1
// octets (Std.HttpEngine.Hpack), so a unit is the octet value; a header an
// application supplies may hold any text, and every check here only accepts
// ASCII, so reading raw units (never a `Char`, which a surrogate half is
// not) classifies it correctly on every target.
func charCodeAt(s: in String, i: in Int): Int {
  Str.codeUnitAt(s, i)
}

func handlePushPromise(state: inout H2Connection, events: in List[H2Event], outb: in List[Byte]): Unit {
  if isClientRole(state) {
    // This client always advertises SETTINGS_ENABLE_PUSH = 0, so any
    // PUSH_PROMISE is a connection PROTOCOL_ERROR (RFC 9113 section 6.6). The
    // codec has already decoded the frame, so no HPACK state is skipped.
    connFail(
      state,
      events,
      outb,
      H2ProtocolError,
      "PUSH_PROMISE received although SETTINGS_ENABLE_PUSH is 0 (RFC 9113 section 6.6)"
    )
  } else {
    connFail(state, events, outb, H2ProtocolError, "a server must not receive PUSH_PROMISE (RFC 9113 section 8.4)")
  }
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
    case _ -> connFail(
      state,
      events,
      outb,
      H2ProtocolError,
      "expected CONTINUATION for the open HEADERS block (RFC 9113 section 6.10)"
    )
  }
}

func dispatchNormal(state: inout H2Connection, events: in List[H2Event], outb: in List[Byte], frame: in H2Frame): Unit {
  match frame {
    case DataFrame(streamId, data, endStream, wireLength) -> handleData(
      state,
      events,
      outb,
      streamId,
      data,
      endStream,
      wireLength
    )
    case HeadersFrame(streamId, fragment, endStream, endHeaders, _) -> handleHeaders(
      state,
      events,
      outb,
      streamId,
      fragment,
      endStream,
      endHeaders
    )
    case ContinuationFrame(_, _, _) -> connFail(
      state,
      events,
      outb,
      H2ProtocolError,
      "CONTINUATION with no preceding HEADERS (RFC 9113 section 6.10)"
    )
    case PriorityFrame(_, _) -> ()
    case RstStreamFrame(streamId, errorCode) -> handleRstStream(state, events, outb, streamId, errorCode)
    case SettingsFrame(settings, ack) -> handleSettings(state, events, outb, settings, ack)
    case PushPromiseFrame(_, _, _, _) -> handlePushPromise(state, events, outb)
    case PingFrame(opaqueData, ack) -> handlePing(state, events, outb, opaqueData, ack)
    case GoAwayFrame(lastStreamId, errorCode, _) -> handleGoAway(state, events, outb, lastStreamId, errorCode)
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
  if state.roleState.expectPeerSettings {
    if not isNonAckSettings(frame) {
      val why = if isClientRole(state) {
        "the first frame from the server must be a non-ACK SETTINGS frame (RFC 9113 section 3.4)"
      } else {
        "the first frame after the connection preface must be a non-ACK SETTINGS frame (RFC 9113 section 3.4)"
      }
      connFail(state, events, outb, H2ProtocolError, why)
      return
    }
    state.roleState.expectPeerSettings = false
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
  pruneClosedStreams(state)
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

/// The highest peer-initiated stream id opened (or implicitly closed by a
/// higher id, RFC 9113 section 5.1.1) so far on this connection — 0 before any
/// HEADERS has been received, and always 0 on a client connection, whose peer
/// cannot open streams (push is disabled). Exposed so a caller layered on top of this FSM (e.g.
/// `Std.HttpServer`'s own bounded-growth bookkeeping, #6566) can mirror
/// `pruneClosedStreams`'s id-distance-behind-the-high-water-mark pruning
/// shape for its own per-stream state without needing a second copy of the
/// monotonic-id tracking this FSM already keeps.
@pure
@experimental
pub func lastPeerStreamId(conn: in H2Connection): Int {
  conn.roleState.highestPeerStreamId
}

/// The id `openStream` will allocate next on a client connection (a `Long`
/// because the id after 2^31-1 does not fit `Int`; a value above 2^31-1 means
/// the id space is exhausted). On a server it is 2 and meaningless.
@pure
@experimental
pub func nextLocalStreamId(conn: in H2Connection): Long {
  conn.roleState.nextLocalStreamId
}

/// The peer's advertised `SETTINGS_MAX_CONCURRENT_STREAMS` (2^31-1 until its
/// `SETTINGS` frame arrives): how many streams a client may have open at once.
@pure
@experimental
pub func peerMaxConcurrentStreams(conn: in H2Connection): Int {
  conn.remoteSettings.maxConcurrentStreams
}

/// The lowest last-stream-id of any `GOAWAY` received (2^31-1 while none has
/// arrived; check `goAwayWasReceived`).
@pure
@experimental
pub func peerGoAwayLastStreamId(conn: in H2Connection): Int {
  conn.roleState.peerGoAwayLastStreamId
}

/// The current state of `streamId` (`H2SIdle` if never seen). Caveat: once a
/// closed stream's record has been reclaimed by `pruneClosedStreams` (#6064),
/// it is indistinguishable at this query surface from a truly never-opened
/// id — both report `H2SIdle` — even though the internal frame-dispatch path
/// (`isIdleStreamId`) correctly tells the two apart for its own no-op-vs-error
/// decisions. A caller using `streamState` as an observability/diagnostic
/// check ("was this stream properly closed?") on a long-lived connection can
/// therefore get a false "never seen" for a stream that really was opened and
/// cleanly closed, once it ages out of the retention window. Tracked as
/// #6572.
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
  if block.length <= maxFrameSize {
    // The common case, one HEADERS frame: returned as serialized, with no
    // pass through a byte list and back (#7269).
    return serializeFrame(
      HeadersFrame(
        streamId = streamId,
        headerBlockFragment = block,
        endStream = endStream,
        endHeaders = true,
        priority = noPriority()
      )
    )
  }
  val outb: List[Byte] = newList()
  appendBytes(
    outb,
    serializeFrame(
      HeadersFrame(
        streamId = streamId,
        headerBlockFragment = block.slice(0, maxFrameSize),
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
  outb.toArray()
}

/// HPACK-encode `headers` and frame them as a HEADERS (+ CONTINUATION when the
/// block exceeds the peer's max frame size) response on `streamId`, updating
/// the stream state for `endStream`. The returned bytes are ready to write.
/// Fails with `HeaderStreamNotWritable` if the connection is poisoned or the
/// stream is not in a state that can send HEADERS (#6084/#6085), or
/// `HeaderEncodingFailed` if HPACK encoding fails.
///
/// # Contract
/// `headers` must satisfy `isH2ResponseHeaderListSafe` (#7251): the caller
/// builds this list, so a field that would make the response malformed
/// (RFC 9113 §8.2) is a programmer error. Filter handler-supplied fields
/// through `isH2ResponseFieldSafe` first.
@experimental
pub func encodeResponseHeaders(
  conn: in H2Connection,
  streamId: in Int,
  headers: in List[HeaderField],
  endStream: in Bool,
): Result[slice[Byte], H2SendError]
  requires: isH2ResponseHeaderListSafe(headers)
{
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

/// `encodeResponseTrailers`'s precondition: every field `isH2ResponseFieldSafe`
/// and no pseudo-header (RFC 9113 §8.1: a trailer section carries none).
@pure
@experimental
pub func isH2ResponseTrailerListSafe(trailers: in List[HeaderField]): Bool {
  var i = 0
  while i < trailers.count {
    val h = trailers[i]
    if h.name.startsWith(":") or not isH2ResponseFieldSafe(h.name, h.value) {
      return false
    }
    i = i + 1
  }
  true
}

/// Frame `trailers` as the final HEADERS block of a response on `streamId`
/// (RFC 9113 §8.1): it carries END_STREAM and closes the server's half of the
/// stream, so DATA must already have been sent. gRPC delivers `grpc-status`
/// and `grpc-message` this way. Fails with `HeaderStreamNotWritable` if the
/// connection is poisoned or the stream cannot send HEADERS, or
/// `HeaderEncodingFailed` if HPACK encoding fails.
///
/// # Contract
/// `trailers` satisfies `isH2ResponseTrailerListSafe`.
@experimental
pub func encodeResponseTrailers(
  conn: in H2Connection, streamId: in Int, trailers: in List[HeaderField]
): Result[slice[Byte], H2SendError]
  requires: isH2ResponseTrailerListSafe(trailers)
{
  encodeTrailersOn(conn, streamId, trailers)
}

/// `encodeRequestTrailers`'s precondition: every field `isH2ResponseFieldSafe`
/// and no pseudo-header (RFC 9113 §8.1). The same rule as
/// `isH2ResponseTrailerListSafe`: a trailer section is role-neutral.
@pure
@experimental
pub func isH2RequestTrailerListSafe(trailers: in List[HeaderField]): Bool {
  isH2ResponseTrailerListSafe(trailers)
}

/// Frame `trailers` as the final HEADERS block of a request on `streamId`
/// (RFC 9113 §8.1), the client counterpart of `encodeResponseTrailers`: it
/// carries END_STREAM and closes this client's half of the stream, so the body
/// must already have been sent.
///
/// # Contract
/// `trailers` satisfies `isH2RequestTrailerListSafe`.
@experimental
pub func encodeRequestTrailers(
  conn: in H2Connection, streamId: in Int, trailers: in List[HeaderField]
): Result[slice[Byte], H2SendError]
  requires: isH2RequestTrailerListSafe(trailers)
{
  encodeTrailersOn(conn, streamId, trailers)
}

func encodeTrailersOn(
  conn: in H2Connection, streamId: in Int, trailers: in List[HeaderField]
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
        encodeResponseHeadersOn(state, streamId, trailers, true)
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
/// (split and retry after a `H2WindowUpdated`).
///
/// # Contract
/// `data` fits in one frame the peer accepts (`peerMaxFrameSize`, #7251): a
/// larger frame is a `FRAME_SIZE_ERROR` that tears down the whole connection
/// (RFC 9113 §4.2), so the caller must split first.
@experimental
pub func sendData(
  conn: in H2Connection, streamId: in Int, data: in slice[Byte], endStream: in Bool
): Result[slice[Byte], H2FlowError]
  requires: data.length <= peerMaxFrameSize(conn)
{
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

// `st` is the same `H2Stream` object `findStream` returned from `conn`'s own
// stream table — records are reference types here, so writing `st.sendWindow`
// through this `in`-bound parameter mutates the live stream state reachable
// from the caller's `conn`, exactly like `state.connSendWindow` does through
// `state: inout H2Connection`. Callers therefore see both debits reflected
// immediately via the same `conn` value, with no reassignment needed.
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
      val bytes = serializeFrame(DataFrame(streamId = streamId, data = data, endStream = endStream, wireLength = len))
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

/// Produce a `GOAWAY` for graceful shutdown (RFC 9113 section 6.8), naming the
/// highest peer stream id processed so far as the last one this endpoint will
/// act on. A client's peer opens none (push is disabled), so a client's
/// `GOAWAY` always names stream 0 and, once sent, `openStream` refuses. Marks `goAwayWasSent` and records that last-stream-id, so
/// the FSM subsequently refuses new peer streams above it (#6086 / §6.8). Does
/// not poison the connection — streams at or below the advertised id may still
/// complete.
@experimental
pub func sendGoAway(conn: in H2Connection, errorCode: in H2ErrorCode): slice[Byte] {
  var state = conn
  state.shutdown.goAwaySent = true
  state.shutdown.goAwayLastStreamId = state.roleState.highestPeerStreamId
  serializeFrame(
    GoAwayFrame(lastStreamId = state.roleState.highestPeerStreamId, errorCode = errorCode, debugData = emptyBytes())
  )
}

/// Produce a `RST_STREAM` (RFC 9113 section 6.4) carrying `errorCode`, closing
/// `streamId` and returning the serialized frame to write. A server uses this
/// to abort a single stream it can no longer serve (e.g. a response whose
/// headers cannot be encoded — `H2InternalError`) without tearing down the whole
/// connection, so a stream is never left hanging with no response and no reset;
/// a client uses it to cancel a call (`H2Cancel`, a deadline expiring), and
/// anything the server had already queued for the stream is then discarded. A
/// no-op empty grant if the connection is already poisoned or the stream is
/// unknown.
@experimental
pub func sendRstStream(conn: in H2Connection, streamId: in Int, errorCode: in H2ErrorCode): slice[Byte] {
  var state = conn
  if isFailed(state) {
    return emptyBytes()
  }
  match findStream(state, streamId) {
    case None -> emptyBytes()
    case Some(_) -> {
      closeStream(state, streamId)
      markResetLocal(state, streamId)
      serializeFrame(RstStreamFrame(streamId = streamId, errorCode = errorCode))
    }
  }
}

/// Produce a `PING` frame (RFC 9113 section 6.7, no ACK flag) carrying the
/// eight `opaqueData` octets; the peer's reply surfaces as
/// `H2PingAcknowledged` with the same data. The FSM keeps no timers: sending
/// keepalive pings and deciding when an unanswered one fails the connection is
/// the driver's job. An empty slice if the connection is already poisoned.
@experimental
pub func sendPing(conn: in H2Connection, opaqueData: in slice[Byte]): slice[Byte]
  requires: opaqueData.length == 8
{
  if isFailed(conn) {
    return emptyBytes()
  }
  serializeFrame(PingFrame(opaqueData = opaqueData, ack = false))
}

/// `openStream`'s precondition (RFC 9113 sections 8.2 and 8.3.1): the
/// pseudo-headers come first, each at most once; `:method` is present, and
/// either the method is `CONNECT` (with `:authority`, and neither `:scheme` nor
/// `:path`) or `:scheme` and a non-empty `:path` are present; no other
/// pseudo-header; every regular field `isH2ResponseFieldSafe` (lowercase token
/// name, clean value, not connection-specific); `te` only `trailers`; `host`,
/// if present, equal to `:authority`; and a well-formed `content-length`.
@pure
@experimental
pub func isH2RequestHeaderListSafe(headers: in List[HeaderField]): Bool {
  var sawRegular = false
  var method = ""
  var sawMethod = false
  var sawScheme = false
  var sawPath = false
  var sawAuthority = false
  var authorityVal = ""
  var i = 0
  while i < headers.count {
    val h = headers[i]
    val name = h.name
    if name.startsWith(":") {
      if sawRegular or not isValidH2FieldValue(h.value) {
        return false
      }
      if name == ":method" and not sawMethod {
        sawMethod = true
        method = h.value
      } else if name == ":scheme" and not sawScheme {
        sawScheme = true
      } else if name == ":path" and not sawPath and h.value.length > 0 {
        sawPath = true
      } else if name == ":authority" and not sawAuthority {
        sawAuthority = true
        authorityVal = h.value
      } else {
        return false
      }
    } else {
      sawRegular = true
      if not isH2ResponseFieldSafe(name, h.value) {
        return false
      }
      if name == "te" and h.value != "trailers" {
        return false
      }
      if name == "host" and sawAuthority and Str.toLower(authorityVal) != Str.toLower(h.value) {
        return false
      }
      if name == "content-length" and parseH2ContentLength(h.value) < 0i64 {
        return false
      }
    }
    i = i + 1
  }
  if not sawMethod or method.length == 0 {
    return false
  }
  if method == "CONNECT" {
    sawAuthority and not sawScheme and not sawPath
  } else {
    sawScheme and sawPath
  }
}

func requestMethodOf(headers: in List[HeaderField]): String {
  var i = 0
  while i < headers.count {
    val h = headers[i]
    if h.name == ":method" {
      return h.value
    }
    i = i + 1
  }
  ""
}

/// The RFC 9113 section 6.5.2 size of a header list: name length plus value
/// length plus 32 octets of overhead per field.
func headerListSize(headers: in List[HeaderField]): Int {
  var total = 0
  var i = 0
  while i < headers.count {
    val h = headers[i]
    total = total + h.name.length + h.value.length + 32
    i = i + 1
  }
  total
}

/// Start a request on a client connection: allocate the next odd stream id,
/// create the stream (open, or half-closed (local) when `endStream`), and
/// HPACK-encode and frame the request HEADERS (+ CONTINUATION when the block
/// exceeds the peer's max frame size). Write the returned bytes, then the body
/// with `sendData`; HEADERS may be sent before the server's `SETTINGS` arrive
/// (the stream starts with the default 65535 window and is corrected by
/// `SETTINGS_INITIAL_WINDOW_SIZE`, RFC 9113 section 6.9.2).
///
/// # Contract
/// The connection is a client connection, `headers` satisfies
/// `isH2RequestHeaderListSafe`, and the caller serialises this call and the
/// write of its bytes with every other call on the connection: ids and HPACK
/// state must reach the wire in the order they were allocated (RFC 9113
/// sections 4.3 and 5.1.1), and the FSM is a single mutable value.
///
/// Refusals leave the connection untouched: see `H2OpenError`. The driver
/// queues on `OpenStreamLimitReached` and retries when a stream closes, and
/// moves to a new connection on `OpenConnectionDraining`,
/// `OpenStreamIdsExhausted` and `OpenConnectionFailed`.
@experimental
pub func openStream(
  conn: in H2Connection, headers: in List[HeaderField], endStream: in Bool
): Result[H2OpenResult, H2OpenError]
  requires: isClientConnection(conn)
  requires: isH2RequestHeaderListSafe(headers)
{
  var state = conn
  if isFailed(state) {
    return Err(error = OpenConnectionFailed)
  }
  if state.shutdown.goAwaySent or state.shutdown.goAwayReceived {
    return Err(error = OpenConnectionDraining)
  }
  if state.roleState.nextLocalStreamId > 2147483647i64 {
    return Err(error = OpenStreamIdsExhausted)
  }
  val active = countActiveStreams(state)
  val limit = state.remoteSettings.maxConcurrentStreams
  if active >= limit {
    return Err(error = OpenStreamLimitReached(active = active, limit = limit))
  }
  val size = headerListSize(headers)
  if size > state.remoteSettings.maxHeaderListSize {
    return Err(error = OpenHeaderListTooLarge(size = size, limit = state.remoteSettings.maxHeaderListSize))
  }
  match encodeHeaderList(state.hpackEnc, headers) {
    case Err(e) -> Err(error = OpenHeaderEncodingFailed(error = e))
    case Ok(block) -> {
      val streamId = state.roleState.nextLocalStreamId.toInt()
      state.roleState.nextLocalStreamId = state.roleState.nextLocalStreamId + 2i64
      val st = createStream(state, streamId)
      st.requestMethod = requestMethodOf(headers)
      val frames = headerBlockToFrames(streamId, block, endStream, state.remoteSettings.maxFrameSize)
      if endStream {
        markEndStreamSent(state, streamId)
      }
      Ok(value = H2OpenResult(streamId = streamId, bytes = frames))
    }
  }
}
