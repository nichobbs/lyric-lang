//! std/http_h2client.l — pure-Lyric HTTP/2 client driver over `Std.TcpHost` and
//! the `Std.HttpEngine.H2Conn` client role (docs/72 section 3.5, slice 5, D800).
//!
//! `Std.HttpEngine.H2Client` owns one connection: it dials (cleartext prior
//! knowledge, or TLS with ALPN `h2`), writes the client preface, runs one
//! reader task, and multiplexes any number of concurrent calls over it. It is
//! plain Lyric over `Std.TcpHost` (sockets, TLS) and `Std.HttpServerHost` (the
//! thread, lock and semaphore seam the shared server driver is written over),
//! so one implementation serves dotnet, the JVM and native with no extern and
//! no `@cfg`.
//!
//! ## Concurrency contract (docs/72 OQ-7)
//!
//! The primitives are exactly those of `Std.HttpServerHost`, whose contracts the
//! shared tests pin on every target: `startTask` (a real thread on all three
//! targets, unlike `spawn`, which is synchronous on MSIL), the reentrant
//! `Mutex`, and the counting `Semaphore` (a post before a wait is not lost).
//! There is no condition variable and no timed wait, and the driver needs
//! neither:
//!
//!   - **One lock per connection** covers the FSM, the call table, every
//!     call's queue and every socket write. `H2Connection` is one mutable
//!     value and frames must reach the wire in the order their HPACK state and
//!     stream ids were allocated (RFC 9113 sections 4.3 and 5.1.1), so one lock
//!     is the simplest correct choice. A write holds it, so a peer that stops
//!     reading is bounded by `writeTimeoutMs` (the transport's I/O timeout): a
//!     timed-out write fails the whole connection instead of freezing every
//!     call forever.
//!   - **A mailbox per call**: a queue under the connection lock plus a
//!     semaphore that holds one credit per queued event (extra credits are
//!     harmless, the consumer re-checks the queue). `h2NextEvent` blocks on it.
//!     A second per-call semaphore wakes a sender blocked on flow control.
//!   - **Deadlines are the reader's job**, not a timed wait. The reader never
//!     blocks longer than `pollIntervalMs` (`hostReadDeadline`), and each wake
//!     it expires calls whose deadline passed (RST_STREAM CANCEL, then a
//!     terminal `H2FailDeadlineExceeded` event), sends or checks keepalive
//!     PINGs and closes a drained connection. A deadline therefore fires within
//!     one poll interval of its time. The same tick is what makes a blocked
//!     consumer's `h2NextEvent` always terminate: every call gets exactly one
//!     terminal event (`H2CallEnded` or `H2CallFailed`).
//!   - **Close interrupts a blocked read** on every target: `h2Close` calls
//!     `hostShutdown` (a socket shutdown from another thread, which makes the
//!     blocked read return end of stream or an error, and a blocked write
//!     fail), then waits for the reader to exit. It does not depend on the
//!     poll interval; the tests set a 60 s interval to prove it.
//!
//! The reader also owns `hostClose`: the socket is released exactly once, by
//! the reader, after it observed the connection closed.
//!
//! ## Flow control and backpressure
//!
//! The connection receive window is credited when bytes arrive (so one slow
//! call cannot starve its neighbours of connection window), the per-stream
//! window only when the consumer takes the bytes out of the mailbox
//! (`h2NextEvent`). A consumer that stops reading therefore stalls the peer at
//! `streamWindow` bytes per call, and the memory a call can hold is bounded by
//! that. Sending honours the peer's windows: `h2SendBody` splits the body into
//! frames of at most the peer's maximum frame size, and when a window is
//! empty it blocks until a WINDOW_UPDATE (or a terminal event) wakes it.
//!
//! ## Failure model
//!
//! `H2CallFailure` separates the outcomes a caller must treat differently:
//! `H2FailRefused` and `H2FailUnprocessed` (REFUSED_STREAM, and streams above a
//! GOAWAY's last-stream-id) never reached the application and are safe to retry
//! on another connection (RFC 9113 section 8.7, `h2FailureIsRetrySafe`);
//! `H2FailDeadlineExceeded` may have been processed; `H2FailConnectionLost`
//! and `H2FailProtocol` end every call still in flight on the connection.
//!
//! ## Not in this module (slice 6)
//!
//! Pooling, queueing of calls beyond `SETTINGS_MAX_CONCURRENT_STREAMS`
//! (`h2StartCall` returns `H2StartStreamLimit`), idle policy, transparent retry
//! and reconnect backoff.
@io
package Std.HttpEngine.H2Client

import Std.Core
import Std.Collections
import Std.Tls
import Std.HttpEngine
import Std.HttpEngine.H2Conn as H2
import Std.HttpEngine.H2Frame
import Std.TcpHost
import Std.HttpServerHost
import Std.Time

// =====================================================================
// Public types.
// =====================================================================
/// Where to connect. `H2Plain` is HTTP/2 over cleartext TCP with prior
/// knowledge (RFC 9113 section 3.3: the client preface is written straight
/// after the connect); `H2Secure` is TLS with ALPN `h2`, the host name doubling
/// as SNI and the name the certificate is verified against. `trust` is the
/// caller's resolved trust decision (`Std.Tls.TlsClientTrust`, the dual-key
/// insecure policy of docs/61 section 4 is resolved before it is built),
/// `identity` the mTLS identity to present and `minVersion` the protocol floor.
@experimental
pub union H2Target {
  case H2Plain(host: String, port: Int)
  case H2Secure(host: String, port: Int, trust: TlsClientTrust, identity: Option[Identity], minVersion: TlsVersion)
}

/// Driver tuning, all in milliseconds or bytes. `h2ClientDefaults()` is the
/// recommended baseline.
///
///   - `connectTimeoutMs`: bounds the TCP connect (0 is the operating system's).
///   - `handshakeTimeoutMs`: bounds each socket operation of the TLS handshake.
///   - `writeTimeoutMs`: bounds every socket write after the handshake (0 is no
///     limit); a timed-out write fails the connection.
///   - `pollIntervalMs`: the longest the reader blocks, and so the resolution of
///     call deadlines and keepalive. Each wake is cheap but not free (one
///     timed-out read), so raise it for a connection that is mostly idle.
///   - `keepAliveIntervalMs`: send a PING after this long without receiving
///     anything (0 is no keepalive, the default: servers such as grpc-java
///     answer pings sent too often with GOAWAY `too_many_pings`, docs/72 OQ-5).
///     `keepAliveTimeoutMs`: fail the connection when the PING is unanswered
///     that long. `keepAliveWithoutCalls`: also ping while no call is active.
///   - `streamWindow`: the per-call receive window, which is also the most one
///     call can buffer. `connectionWindow`: the connection receive window.
@experimental
pub record H2ClientOptions {
  connectTimeoutMs: Int
  handshakeTimeoutMs: Int
  writeTimeoutMs: Int
  pollIntervalMs: Int
  keepAliveIntervalMs: Int
  keepAliveTimeoutMs: Int
  keepAliveWithoutCalls: Bool
  streamWindow: Int
  connectionWindow: Int
}

/// The recommended options: 10 s connect and handshake, 30 s write timeout, a
/// 50 ms poll, no keepalive (20 s ping timeout once enabled), a 1 MiB stream
/// window and a 16 MiB connection window.
@experimental
pub func h2ClientDefaults(): H2ClientOptions {
  H2ClientOptions(
    connectTimeoutMs = 10000,
    handshakeTimeoutMs = 10000,
    writeTimeoutMs = 30000,
    pollIntervalMs = 50,
    keepAliveIntervalMs = 0,
    keepAliveTimeoutMs = 20000,
    keepAliveWithoutCalls = false,
    streamWindow = 1048576,
    connectionWindow = 16777216
  )
}

/// True when `opts` can be used: non-negative timeouts, a positive poll, and
/// windows between the protocol's initial 65535 and its 2^31-1 maximum.
@pure
@experimental
pub func h2ClientOptionsValid(opts: in H2ClientOptions): Bool {
  opts.connectTimeoutMs >= 0 and opts.handshakeTimeoutMs >= 0 and opts.writeTimeoutMs >= 0 and opts.pollIntervalMs >= 1 and
    opts.keepAliveIntervalMs >= 0 and
    opts.keepAliveTimeoutMs >= 1 and
    opts.streamWindow >= 65535 and
    opts.streamWindow <= H2.h2MaxWindow() and
    opts.connectionWindow >= 65535 and
    opts.connectionWindow <= H2.h2MaxWindow()
}

/// Why `h2Connect` failed.
///
///   - `H2ConnectTransport`: the dial, or the preface write, failed.
///   - `H2ConnectTls`: the TLS handshake failed (untrusted or expired
///     certificate, hostname mismatch, rejected client identity).
///   - `H2ConnectTlsConfig`: the trust PEM or identity is unusable.
///   - `H2ConnectAlpnNotH2`: the server selected another protocol (`negotiated`,
///     `""` when none). There is no silent downgrade: a caller that can speak
///     HTTP/1.1 chooses that itself.
@experimental
pub union H2DialError {
  case H2ConnectTransport(message: String)
  case H2ConnectTls(message: String)
  case H2ConnectTlsConfig(message: String)
  case H2ConnectAlpnNotH2(negotiated: String)
}

/// Human-readable message for an `H2DialError`.
@pure
@experimental
pub func H2DialError.message(e: in H2DialError): String {
  match e {
    case H2ConnectTransport(m) -> "connect failed: " + m
    case H2ConnectTls(m) -> "TLS handshake failed: " + m
    case H2ConnectTlsConfig(m) -> "TLS configuration invalid: " + m
    case H2ConnectAlpnNotH2(n) -> "server did not negotiate h2 (selected '" + n + "')"
  }
}

/// Why `h2StartCall` refused. Every case leaves the connection and its other
/// calls untouched except `H2StartWriteFailed`, which means the connection is
/// gone.
///
///   - `H2StartClosed`: the connection is closed (its `h2ClientCloseReason`).
///   - `H2StartDraining`: the peer sent GOAWAY or the connection is closing;
///     start the call on another connection.
///   - `H2StartStreamLimit`: `active` calls already meet the peer's
///     `SETTINGS_MAX_CONCURRENT_STREAMS` `limit`; retry once a call ends.
///   - `H2StartIdsExhausted`: the 2^31-1 stream-id space is used up.
///   - `H2StartHeaderListTooLarge`: the request headers exceed the peer's
///     advertised `SETTINGS_MAX_HEADER_LIST_SIZE`.
///   - `H2StartEncodingFailed`: the headers cannot be HPACK-encoded.
@experimental
pub union H2StartError {
  case H2StartClosed
  case H2StartDraining
  case H2StartStreamLimit(active: Int, limit: Int)
  case H2StartIdsExhausted
  case H2StartHeaderListTooLarge(size: Int, limit: Int)
  case H2StartEncodingFailed(message: String)
  case H2StartWriteFailed(message: String)
}

/// Why `h2SendBody` could not send.
///
///   - `H2BodyCallFailed`: the call already ended in failure (cancelled, past
///     its deadline, reset, or the connection is lost).
///   - `H2BodyStreamClosed`: the stream is no longer writable, typically the
///     server finished its response before the request body ended or the
///     request already carried END_STREAM.
///   - `H2BodyWriteFailed`: the socket write failed; the connection is gone.
@experimental
pub union H2BodyError {
  case H2BodyCallFailed(failure: H2CallFailure)
  case H2BodyStreamClosed
  case H2BodyWriteFailed(message: String)
}

/// How a call failed. See the module header for which are retry-safe.
@experimental
pub union H2CallFailure {
  case H2FailDeadlineExceeded
  case H2FailCancelled
  case H2FailReset(errorCode: H2ErrorCode)
  case H2FailRefused
  case H2FailUnprocessed
  case H2FailConnectionLost(message: String)
  case H2FailProtocol(errorCode: H2ErrorCode, message: String)
}

/// True when the call provably never reached the server application
/// (REFUSED_STREAM, or a stream above a GOAWAY's last-stream-id) and may be
/// retried on another connection (RFC 9113 section 8.7).
@pure
@experimental
pub func h2FailureIsRetrySafe(f: in H2CallFailure): Bool {
  match f {
    case H2FailRefused -> true
    case H2FailUnprocessed -> true
    case _ -> false
  }
}

/// Human-readable message for an `H2CallFailure`.
@pure
@experimental
pub func H2CallFailure.message(f: in H2CallFailure): String {
  match f {
    case H2FailDeadlineExceeded -> "deadline exceeded"
    case H2FailCancelled -> "cancelled"
    case H2FailReset(code) -> "stream reset by peer, error code " + errorCodeToLong(code).toString()
    case H2FailRefused -> "stream refused by peer (REFUSED_STREAM)"
    case H2FailUnprocessed -> "stream not processed (peer sent GOAWAY)"
    case H2FailConnectionLost(m) -> "connection lost: " + m
    case H2FailProtocol(code, m) -> "protocol error " + errorCodeToLong(code).toString() + ": " + m
  }
}

/// What `h2NextEvent` delivers, in message order: zero or more
/// `H2CallInformational`, one `H2CallHeaders`, `H2CallData` chunks, optionally
/// `H2CallTrailers`, then the terminal `H2CallEnded`. A failed call delivers
/// `H2CallFailed` instead of (never after) `H2CallEnded`, and data already
/// queued when the connection is lost is delivered before it. Once a terminal
/// event has been returned, every further `h2NextEvent` returns it again.
@experimental
pub union H2CallEvent {
  case H2CallInformational(status: Int, headers: List[HeaderField])
  case H2CallHeaders(status: Int, headers: List[HeaderField])
  case H2CallData(data: slice[Byte])
  case H2CallTrailers(headers: List[HeaderField])
  case H2CallEnded
  case H2CallFailed(failure: H2CallFailure)
}

/// The lifecycle of a connection: open, draining (GOAWAY sent or received: no
/// new calls, in-flight calls finish) and closed.
@experimental
pub enum H2ClientStatus {
  case H2ClientOpen
  case H2ClientDraining
  case H2ClientClosed
}

/// A call's mailbox and flow-control bookkeeping. Internal: observe a call only
/// through the functions below. Every field is guarded by the connection lock.
@experimental
pub ref record H2CallState {
  streamId: Int
  signal: Semaphore
  windowWake: Semaphore
  deadlineNanos: Long
  var queue: List[H2CallEvent]
  var head: Int
  var finished: Bool
  var drained: Bool
  var terminal: H2CallEvent
  var unacked: Int
}

/// One HTTP/2 connection. Internal: observe it only through the functions
/// below. Every mutable field is guarded by `guard`.
@experimental
pub ref record H2ClientConnection {
  guard: Mutex
  transport: Conn
  options: H2ClientOptions
  calls: Map[Int, H2CallState]
  readerDone: Semaphore
  var h2: H2.H2Connection
  var status: H2ClientStatus
  var lastReceiveNanos: Long
  var pingSentNanos: Long
  var pingCounter: Int
  var closeReason: String
}

/// A started call. Send the body with `h2SendBody` (unless `endStream` was
/// true), read the response with `h2NextEvent` until a terminal event, and
/// `h2Cancel` to abandon it.
@experimental
pub ref record H2Call {
  conn: H2ClientConnection
  state: H2CallState
}

// =====================================================================
// Internal helpers (the lock is held by the caller unless stated).
// =====================================================================
func h2cEmpty(): slice[Byte] {
  val e: slice[Byte] = []
  e
}

func h2cIsClosed(conn: in H2ClientConnection): Bool {
  match conn.status {
    case H2ClientClosed -> true
    case _ -> false
  }
}

func h2cNewCall(streamId: in Int, deadlineNanos: in Long): H2CallState {
  val q: List[H2CallEvent] = newList()
  H2CallState(
    streamId = streamId,
    signal = newSem(0),
    windowWake = newSem(0),
    deadlineNanos = deadlineNanos,
    queue = q,
    head = 0,
    finished = false,
    drained = false,
    terminal = H2CallEnded,
    unacked = 0
  )
}

func h2cPush(st: in H2CallState, ev: in H2CallEvent): Unit {
  if not st.finished {
    st.queue.add(ev)
    semPost(st.signal)
  }
}

// End a call with its one terminal event and take it off the connection's
// table. `discard` drops queued events first, for a call that is abandoned
// (cancelled, past its deadline); a call that ends because the peer or the
// connection ended keeps what it already received.
func h2cFinishCall(conn: in H2ClientConnection, st: in H2CallState, ev: in H2CallEvent, discard: in Bool): Unit {
  if st.finished {
    return
  }
  if discard {
    st.queue.clear()
    st.head = 0
  }
  st.queue.add(ev)
  st.terminal = ev
  st.finished = true
  conn.calls.remove(st.streamId)
  semPost(st.signal)
  semPost(st.windowWake)
}

func h2cWakeSenders(conn: in H2ClientConnection): Unit {
  val live = mapValues(conn.calls)
  var i = 0
  while i < live.count {
    semPost(live[i].windowWake)
    i = i + 1
  }
}

// Fail every call, mark the connection closed and interrupt the reader.
// Idempotent. `failure` is what each unfinished call reports; `reason` is
// what `h2ClientCloseReason` reports.
func h2cTeardown(conn: in H2ClientConnection, reason: in String, failure: in H2CallFailure): Unit {
  lock(conn.guard)
  if h2cIsClosed(conn) {
    unlock(conn.guard)
    return
  }
  conn.status = H2ClientClosed
  conn.closeReason = reason
  val live = mapValues(conn.calls)
  var i = 0
  while i < live.count {
    h2cFinishCall(conn, live[i], H2CallFailed(failure = failure), false)
    i = i + 1
  }
  unlock(conn.guard)
  hostShutdown(conn.transport)
}

// Write under the lock. A failed write tears the connection down.
func h2cWrite(conn: in H2ClientConnection, bytes: in slice[Byte]): Bool {
  if bytes.length == 0 {
    return true
  }
  match hostWrite(conn.transport, bytes) {
    case Ok(_) -> true
    case Err(e) -> {
      val m = "write failed: " + TcpError.message(e)
      h2cTeardown(conn, m, H2FailConnectionLost(message = m))
      false
    }
  }
}

// Return stream-window credit for bytes the consumer has taken (`unacked`),
// once at least half a window is owed so a read of a small chunk does not cost
// a frame of its own.
func h2cCreditStream(conn: in H2ClientConnection, st: in H2CallState): Unit {
  if st.finished or h2cIsClosed(conn) {
    return
  }
  val half = conn.options.streamWindow / 2
  if st.unacked >= half and st.unacked > 0 {
    val room = H2.h2MaxWindow() - H2.streamReceiveWindow(conn.h2, st.streamId)
    var grant = st.unacked
    if grant > room {
      grant = room
    }
    if grant > 0 {
      val frame = H2.grantStreamWindow(conn.h2, st.streamId, grant)
      st.unacked = st.unacked - grant
      val _ = h2cWrite(conn, frame)
    }
  }
}

func h2cFailureOfReset(code: in H2ErrorCode): H2CallFailure {
  match code {
    case H2RefusedStream -> H2FailRefused
    case _ -> H2FailReset(errorCode = code)
  }
}

func h2cIsEndedEvent(ev: in H2CallEvent): Bool {
  match ev {
    case H2CallEnded -> true
    case H2CallFailed(_) -> true
    case _ -> false
  }
}

// Route one FSM event. Returns the connection error it carries, if any (the
// caller writes the GOAWAY the FSM queued and then tears the connection down).
func h2cDispatch(conn: in H2ClientConnection, ev: in H2.H2Event): Option[H2CallEvent] {
  match ev {
    case H2NeedMore -> None
    case H2SettingsReceived(_) -> {
      h2cWakeSenders(conn)
      None
    }
    case H2SettingsAcknowledged -> None
    case H2WindowUpdated(streamId) -> {
      if streamId == 0 {
        h2cWakeSenders(conn)
      } else {
        match mapGet(conn.calls, streamId) {
          case Some(st) -> semPost(st.windowWake)
          case None -> ()
        }
      }
      None
    }
    case H2PingReceived(_) -> None
    case H2PingAcknowledged(_) -> {
      conn.pingSentNanos = 0i64
      None
    }
    case H2GoAwayReceived(_, _) -> {
      match conn.status {
        case H2ClientOpen -> {
          conn.status = H2ClientDraining
        }
        case _ -> ()
      }
      None
    }
    case H2InformationalHeaders(streamId, status, headers) -> {
      match mapGet(conn.calls, streamId) {
        case Some(st) -> h2cPush(st, H2CallInformational(status = status, headers = headers))
        case None -> ()
      }
      None
    }
    case H2ResponseHeaders(streamId, status, headers, endStream) -> {
      match mapGet(conn.calls, streamId) {
        case Some(st) -> {
          h2cPush(st, H2CallHeaders(status = status, headers = headers))
          if endStream {
            h2cFinishCall(conn, st, H2CallEnded, false)
          }
        }
        case None -> ()
      }
      None
    }
    case H2ResponseData(streamId, data, endStream, _) -> {
      match mapGet(conn.calls, streamId) {
        case Some(st) -> {
          if data.length > 0 {
            h2cPush(st, H2CallData(data = data))
          }
          if endStream {
            h2cFinishCall(conn, st, H2CallEnded, false)
          }
        }
        case None -> ()
      }
      None
    }
    case H2ResponseTrailers(streamId, headers) -> {
      match mapGet(conn.calls, streamId) {
        case Some(st) -> {
          h2cPush(st, H2CallTrailers(headers = headers))
          h2cFinishCall(conn, st, H2CallEnded, false)
        }
        case None -> ()
      }
      None
    }
    case H2PeerReset(streamId, code) -> {
      match mapGet(conn.calls, streamId) {
        case Some(st) -> h2cFinishCall(conn, st, H2CallFailed(failure = h2cFailureOfReset(code)), false)
        case None -> ()
      }
      None
    }
    case H2StreamUnprocessed(streamId) -> {
      match mapGet(conn.calls, streamId) {
        case Some(st) -> h2cFinishCall(conn, st, H2CallFailed(failure = H2FailUnprocessed), false)
        case None -> ()
      }
      None
    }
    case H2StreamErr(streamId, code, message) -> {
      match mapGet(conn.calls, streamId) {
        case Some(st) -> h2cFinishCall(
          conn,
          st,
          H2CallFailed(failure = H2FailProtocol(errorCode = code, message = message)),
          false
        )
        case None -> ()
      }
      None
    }
    case H2ConnError(code, message) -> Some(
      value = H2CallFailed(
        failure = H2FailProtocol(errorCode = code, message = message)
      )
    )
    case H2RequestHeaders(_, _, _) -> None
    case H2RequestData(_, _, _, _) -> None
  }
}

// A draining connection with nothing left in flight has finished its job.
func h2cFinishDrain(conn: in H2ClientConnection): Unit {
  match conn.status {
    case H2ClientDraining -> {
      if mapSize(conn.calls) == 0 {
        h2cTeardown(conn, "drained after GOAWAY", H2FailConnectionLost(message = "drained after GOAWAY"))
      }
    }
    case _ -> ()
  }
}

// Feed received bytes to the FSM, route its events, write what it queued (the
// connection window is credited here, on receipt) and apply a connection error.
func h2cOnBytes(conn: in H2ClientConnection, bytes: in slice[Byte]): Unit {
  lock(conn.guard)
  conn.lastReceiveNanos = monotonicNanos()
  if h2cIsClosed(conn) or H2.isFailed(conn.h2) {
    unlock(conn.guard)
    return
  }
  val res = H2.feed(conn.h2, bytes)
  conn.h2 = res.conn
  var fatal: Option[H2CallEvent] = None
  var i = 0
  while i < res.events.count {
    match h2cDispatch(conn, res.events[i]) {
      case Some(fe) -> {
        val keep = fe
        fatal = Some(value = keep)
      }
      case None -> ()
    }
    i = i + 1
  }
  var pending = res.outbound
  match fatal {
    case None -> {
      val target = conn.options.connectionWindow
      val w = H2.connectionReceiveWindow(conn.h2)
      if w <= target / 2 {
        pending = pending.concat(H2.grantConnectionWindow(conn.h2, target - w))
      }
    }
    case Some(_) -> ()
  }
  if h2cWrite(conn, pending) {
    match fatal {
      case Some(e) -> {
        match e {
          case H2CallFailed(f) -> h2cTeardown(conn, H2CallFailure.message(f), f)
          case _ -> ()
        }
      }
      case None -> h2cFinishDrain(conn)
    }
  }
  unlock(conn.guard)
}

// Expire call deadlines, run keepalive, finish a drained connection.
func h2cTick(conn: in H2ClientConnection): Unit {
  lock(conn.guard)
  if h2cIsClosed(conn) {
    unlock(conn.guard)
    return
  }
  val now = monotonicNanos()
  val live = mapValues(conn.calls)
  var pending = h2cEmpty()
  var i = 0
  while i < live.count {
    val st = live[i]
    if st.deadlineNanos != 0i64 and now >= st.deadlineNanos and not st.finished {
      pending = pending.concat(H2.sendRstStream(conn.h2, st.streamId, H2Cancel))
      h2cFinishCall(conn, st, H2CallFailed(failure = H2FailDeadlineExceeded), true)
    }
    i = i + 1
  }
  val interval = conn.options.keepAliveIntervalMs
  if interval > 0 {
    if conn.pingSentNanos != 0i64 {
      val waited = (now - conn.pingSentNanos) / 1000000i64
      if waited >= conn.options.keepAliveTimeoutMs.toLong() {
        unlock(conn.guard)
        val m = "keepalive PING unanswered for " + waited.toString() + " ms"
        h2cTeardown(conn, m, H2FailConnectionLost(message = m))
        return
      }
    } else {
      val idle = (now - conn.lastReceiveNanos) / 1000000i64
      val eligible = mapSize(conn.calls) > 0 or conn.options.keepAliveWithoutCalls
      if eligible and idle >= interval.toLong() {
        conn.pingCounter = conn.pingCounter + 1
        val data: List[Byte] = newList()
        var b = 0
        while b < 8 {
          data.add((conn.pingCounter.shr(8 * (7 - b)).and(255)).toByte())
          b = b + 1
        }
        pending = pending.concat(H2.sendPing(conn.h2, data.toArray()))
        conn.pingSentNanos = now
      }
    }
  }
  if h2cWrite(conn, pending) {
    h2cFinishDrain(conn)
  }
  unlock(conn.guard)
}

func h2cReaderLoop(conn: in H2ClientConnection): Unit {
  val pollNanos = conn.options.pollIntervalMs.toLong() * 1000000i64
  var running = true
  while running {
    if h2cIsClosed(conn) {
      running = false
    } else {
      match hostReadDeadline(conn.transport, 65536, monotonicNanos() + pollNanos) {
        case Ok(bytes) -> {
          if bytes.length == 0 {
            h2cTeardown(conn, "connection closed by peer", H2FailConnectionLost(message = "connection closed by peer"))
            running = false
          } else {
            h2cOnBytes(conn, bytes)
          }
        }
        case Err(e) -> {
          match e {
            case ReadDeadlinePassed -> ()
            case ReadFailed(te) -> {
              val m = "read failed: " + TcpError.message(te)
              h2cTeardown(conn, m, H2FailConnectionLost(message = m))
              running = false
            }
          }
        }
      }
      if running {
        h2cTick(conn)
      }
    }
  }
  hostClose(conn.transport)
  semPost(conn.readerDone)
}

func h2cMapTcpError(e: in TcpError): H2DialError {
  match e {
    case TlsHandshakeFailed(m) -> H2ConnectTls(message = m)
    case TlsConfigInvalid(m) -> H2ConnectTlsConfig(message = m)
    case _ -> H2ConnectTransport(message = TcpError.message(e))
  }
}

// =====================================================================
// Public API.
// =====================================================================
/// Dial `target`, write the client preface and start the reader. For
/// `H2Secure` the server must select ALPN `h2` (`H2ConnectAlpnNotH2`
/// otherwise; the socket is closed on every failure path).
///
/// The reader runs on its own thread (`Std.HttpServerHost.startTask`) until the
/// connection closes; `h2Close` ends it. Calls may be started and driven from
/// any number of threads.
@experimental
pub func h2Connect(target: in H2Target, opts: in H2ClientOptions): Result[H2ClientConnection, H2DialError]
  requires: h2ClientOptionsValid(opts)
{
  val transport = match target {
    case H2Plain(host, port) -> {
      match hostConnect(host, port, opts.connectTimeoutMs) {
        case Ok(c) -> c
        case Err(e) -> return Err(error = h2cMapTcpError(e))
      }
    }
    case H2Secure(host, port, trust, identity, minVersion) -> {
      val plain = match hostConnect(host, port, opts.connectTimeoutMs) {
        case Ok(c) -> c
        case Err(e) -> return Err(error = h2cMapTcpError(e))
      }
      hostSetIoTimeout(plain, opts.handshakeTimeoutMs)
      val secured = match hostUpgradeClientTls(plain, host, trust, identity, minVersion, "h2") {
        case Ok(c) -> c
        case Err(e) -> return Err(error = h2cMapTcpError(e))
      }
      if hostAlpn(secured) != "h2" {
        val negotiated = hostAlpn(secured)
        hostClose(secured)
        return Err(error = H2ConnectAlpnNotH2(negotiated = negotiated))
      }
      secured
    }
  }
  h2cStart(transport, opts)
}

/// Run HTTP/2 on a connection the caller has already established: write the
/// client preface and start the reader. For TLS the caller has completed the
/// handshake and checked that ALPN selected `h2` (`Std.TcpHost.hostAlpn`); a
/// cleartext connection is prior knowledge. This is how a client that offers
/// `h2,http/1.1` (`Std.Http` on native) keeps one connection whichever
/// protocol the server picks: it speaks HTTP/1.1 itself on `http/1.1` and
/// hands the connection here on `h2`.
///
/// Ownership of `transport` passes to the driver on success (`h2Close`
/// releases it) and on failure (it is closed here), so the caller never
/// closes it after calling this. `opts.connectTimeoutMs` and
/// `opts.handshakeTimeoutMs` are not used: the connection already exists.
@experimental
pub func h2ConnectOn(transport: in Conn, opts: in H2ClientOptions): Result[H2ClientConnection, H2DialError]
  requires: h2ClientOptionsValid(opts)
{
  h2cStart(transport, opts)
}

func h2cStart(transport: in Conn, opts: in H2ClientOptions): Result[H2ClientConnection, H2DialError] {
  hostSetIoTimeout(transport, opts.writeTimeoutMs)
  val settings = H2.h2DefaultClientSettings()
  settings.initialWindowSize = opts.streamWindow
  val fsm = H2.newClientConnection(settings)
  var first = H2.clientInitialBytes(fsm)
  val connWindow = H2.connectionReceiveWindow(fsm)
  if opts.connectionWindow > connWindow {
    first = first.concat(H2.grantConnectionWindow(fsm, opts.connectionWindow - connWindow))
  }
  match hostWrite(transport, first) {
    case Err(e) -> {
      hostClose(transport)
      return Err(error = H2ConnectTransport(message = TcpError.message(e)))
    }
    case Ok(_) -> ()
  }
  val table: Map[Int, H2CallState] = newMap()
  val conn = H2ClientConnection(
    guard = newMutex(),
    transport = transport,
    options = opts,
    calls = table,
    readerDone = newSem(0),
    h2 = fsm,
    status = H2ClientOpen,
    lastReceiveNanos = monotonicNanos(),
    pingSentNanos = 0i64,
    pingCounter = 0,
    closeReason = ""
  )
  val started = tryStartTask(
    { ->
      runGuarded(
        { -> h2cReaderLoop(conn) },
        { msg ->
          h2cTeardown(conn, "client fault: " + msg, H2FailConnectionLost(message = "client fault: " + msg))
          hostClose(conn.transport)
          semPost(conn.readerDone)
        }
      )
    }
  )
  if not started {
    hostClose(transport)
    return Err(error = H2ConnectTransport(message = "could not start the reader task"))
  }
  Ok(value = conn)
}

/// Start a call: allocate the next stream id and send the request HEADERS.
/// `endStream` true ends the request there (no body); otherwise send the body
/// with `h2SendBody`. `deadlineMs` bounds the whole call from now (0 is none):
/// when it passes the call is cancelled (RST_STREAM CANCEL) and ends with
/// `H2FailDeadlineExceeded`, the connection staying up for other calls.
///
/// # Contract
/// `headers` satisfies `Std.HttpEngine.H2Conn.isH2RequestHeaderListSafe`:
/// pseudo-headers first, `:method`, `:scheme`, `:path` (and `:authority`), only
/// lowercase connection-neutral fields.
@experimental
pub func h2StartCall(
  conn: in H2ClientConnection, headers: in List[HeaderField], endStream: in Bool, deadlineMs: in Int
): Result[H2Call, H2StartError]
  requires: deadlineMs >= 0
  requires: H2.isH2RequestHeaderListSafe(headers)
{
  lock(conn.guard)
  match conn.status {
    case H2ClientClosed -> {
      unlock(conn.guard)
      return Err(error = H2StartClosed)
    }
    case H2ClientDraining -> {
      unlock(conn.guard)
      return Err(error = H2StartDraining)
    }
    case H2ClientOpen -> ()
  }
  match H2.openStream(conn.h2, headers, endStream) {
    case Err(e) -> {
      unlock(conn.guard)
      Err(
        error = match e {
          case OpenConnectionFailed -> H2StartClosed
          case OpenConnectionDraining -> H2StartDraining
          case OpenStreamLimitReached(active, limit) -> H2StartStreamLimit(active = active, limit = limit)
          case OpenStreamIdsExhausted -> H2StartIdsExhausted
          case OpenHeaderListTooLarge(size, limit) -> H2StartHeaderListTooLarge(size = size, limit = limit)
          case OpenHeaderEncodingFailed(_) -> H2StartEncodingFailed(
            message = "request headers cannot be HPACK-encoded"
          )
        }
      )
    }
    case Ok(opened) -> {
      val deadline = if deadlineMs > 0 { monotonicNanos() + deadlineMs.toLong() * 1000000i64 } else { 0i64 }
      val st = h2cNewCall(opened.streamId, deadline)
      conn.calls[opened.streamId] = st
      val ok = h2cWrite(conn, opened.bytes)
      val reason = conn.closeReason
      unlock(conn.guard)
      if ok {
        Ok(value = H2Call(conn = conn, state = st))
      } else {
        Err(error = H2StartWriteFailed(message = reason))
      }
    }
  }
}

/// Send request body bytes on `call`, framed within the peer's maximum frame
/// size and its connection and stream windows. When a window is empty this
/// blocks until the peer grants more (or the call ends, or the connection
/// fails), so a large body is delivered as fast as the peer reads it.
/// `endStream` true ends the request after `data`; an empty `data` with
/// `endStream` is the way to end a request whose headers did not.
@experimental
pub func h2SendBody(call: in H2Call, data: in slice[Byte], endStream: in Bool): Result[Unit, H2BodyError] {
  val conn = call.conn
  val st = call.state
  val total = data.length
  var offset = 0
  var more = total > 0 or endStream
  while more {
    lock(conn.guard)
    if st.finished {
      unlock(conn.guard)
      return Err(error = h2cBodyEnded(st))
    }
    val remaining = total - offset
    var chunk = remaining
    val frameMax = H2.peerMaxFrameSize(conn.h2)
    if chunk > frameMax {
      chunk = frameMax
    }
    val room = H2.maxSendableOnStream(conn.h2, st.streamId)
    if chunk > room {
      chunk = room
    }
    if chunk == 0 and remaining > 0 {
      unlock(conn.guard)
      semWait(st.windowWake)
    } else {
      val last = endStream and offset + chunk == total
      match H2.sendData(conn.h2, st.streamId, data.slice(offset, offset + chunk), last) {
        case Ok(frame) -> {
          if not h2cWrite(conn, frame) {
            val m = conn.closeReason
            unlock(conn.guard)
            return Err(error = H2BodyWriteFailed(message = m))
          }
          offset = offset + chunk
          if offset >= total {
            more = false
          }
          unlock(conn.guard)
        }
        case Err(e) -> {
          unlock(conn.guard)
          match e {
            case WindowExceeded(_, _) -> semWait(st.windowWake)
            case StreamNotWritable(_) -> return Err(error = H2BodyStreamClosed)
          }
        }
      }
    }
  }
  Ok(value = ())
}

func h2cBodyEnded(st: in H2CallState): H2BodyError {
  match st.terminal {
    case H2CallFailed(f) -> H2BodyCallFailed(failure = f)
    case _ -> H2BodyStreamClosed
  }
}

/// The next event of `call`'s response, blocking until one is available. Always
/// terminates: every call ends with exactly one terminal event, whatever the
/// peer or the network does, within one poll interval of the cause (deadline,
/// close, loss). Taking `H2CallData` out returns its stream-window credit
/// (batched, once half a window is owed), which is what lets the peer send
/// more: a consumer that stops calling this stalls the peer at `streamWindow`
/// bytes.
@experimental
pub func h2NextEvent(call: in H2Call): H2CallEvent {
  val conn = call.conn
  val st = call.state
  var result: H2CallEvent = H2CallEnded
  var got = false
  while not got {
    lock(conn.guard)
    if st.head < st.queue.count {
      result = st.queue[st.head]
      st.head = st.head + 1
      if st.head == st.queue.count {
        st.queue.clear()
        st.head = 0
      }
      match result {
        case H2CallData(d) -> {
          st.unacked = st.unacked + d.length
          h2cCreditStream(conn, st)
        }
        case _ -> ()
      }
      if h2cIsEndedEvent(result) {
        st.drained = true
      }
      got = true
      unlock(conn.guard)
    } else if st.drained {
      result = st.terminal
      got = true
      unlock(conn.guard)
    } else {
      unlock(conn.guard)
      semWait(st.signal)
    }
  }
  result
}

/// Abandon `call`: send RST_STREAM CANCEL and end it with `H2FailCancelled`
/// (queued events are dropped, a thread blocked in `h2NextEvent` or
/// `h2SendBody` wakes). A no-op once the call has ended. The connection stays
/// up for other calls.
@experimental
pub func h2Cancel(call: in H2Call): Unit {
  val conn = call.conn
  val st = call.state
  lock(conn.guard)
  if not st.finished and not h2cIsClosed(conn) {
    val frame = H2.sendRstStream(conn.h2, st.streamId, H2Cancel)
    h2cFinishCall(conn, st, H2CallFailed(failure = H2FailCancelled), true)
    val _ = h2cWrite(conn, frame)
  }
  unlock(conn.guard)
}

/// Close the connection and wait for its reader to exit. Every call still in
/// flight ends with `H2FailConnectionLost`. A read or write blocked on the
/// socket is interrupted at once (`hostShutdown`), so this returns promptly on
/// every target whatever the poll interval; no GOAWAY is sent (RFC 9113
/// section 5.4.1 allows closing without one). Safe to call more than once and
/// from any thread, but not from the reader (there is no callback that runs on
/// it).
@experimental
pub func h2Close(conn: in H2ClientConnection): Unit {
  h2cTeardown(conn, "closed by caller", H2FailConnectionLost(message = "connection closed by caller"))
  semWait(conn.readerDone)
  semPost(conn.readerDone)
}

/// The connection's lifecycle state.
@experimental
pub func h2ClientStatus(conn: in H2ClientConnection): H2ClientStatus {
  lock(conn.guard)
  val s = conn.status
  unlock(conn.guard)
  s
}

/// Why the connection closed, `""` while it has not.
@experimental
pub func h2ClientCloseReason(conn: in H2ClientConnection): String {
  lock(conn.guard)
  val r = conn.closeReason
  unlock(conn.guard)
  r
}

/// How many calls are in flight (started and not yet ended).
@experimental
pub func h2ClientActiveCalls(conn: in H2ClientConnection): Int {
  lock(conn.guard)
  val n = mapSize(conn.calls)
  unlock(conn.guard)
  n
}

/// The call's HTTP/2 stream id.
@pure
@experimental
pub func h2CallStreamId(call: in H2Call): Int {
  call.state.streamId
}
