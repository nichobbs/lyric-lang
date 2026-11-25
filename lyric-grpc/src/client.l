//! Grpc.Client — the pure-Lyric gRPC client over `Std.HttpEngine.H2Client`
//! (docs/72 section 4.2, slice 6, D802).
//!
//! One implementation serves dotnet and the JVM: sockets and TLS come from
//! `Std.TcpHost` through the `H2Client` driver, the wire format and the status
//! mapping from `Grpc.Wire`, so there is no extern here and no SDK behind it.
//! `Grpc` (the public API) calls this package unless the `legacy-client`
//! feature selects the SDK kernels (`Grpc.Kernel.Net`, `Grpc.Kernel.Jvm`).
//!
//! ## Channels and pooling
//!
//! A channel owns up to `ChannelOptions.maxConnections` HTTP/2 connections to
//! one server (one by default), dialed on demand. A call takes the first open
//! connection with a free stream (the server's `SETTINGS_MAX_CONCURRENT_STREAMS`
//! bounds them); when all are full a further connection is dialed if the limit
//! allows, otherwise the call waits for a stream to free up. Waiting calls are
//! served first-in first-out (a ticket queue) and re-check every 2 ms, so a
//! deadline applies while a call waits. A connection whose server sent GOAWAY
//! is retired (its calls finish) and replaced by the next call. A connection
//! idle for `idleTimeoutMs` is closed by the channel's janitor task, which
//! exists only when that is non-zero and ends when the channel is closed.
//! After a failed dial, calls fail with `Unavailable` (no connection to wait
//! for) until a jittered exponential backoff elapses.
//!
//! ## Transparent retry
//!
//! A call that fails with `REFUSED_STREAM` or because it lay above a GOAWAY's
//! last-stream-id never reached the server application (RFC 9113 section 8.7)
//! and is sent once more, on another connection if need be. Nothing else is
//! retried: a call that may have run is never repeated.
//!
//! ## Streams
//!
//! A `GrpcStream` is read by one thread at a time; `closeStream` may be called
//! from any thread and wakes a blocked reader with `Cancelled`.
@io
package Grpc.Client

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Time
import Std.Parse
import Std.Random
import Std.Encoding
import Std.Tls
import Std.HttpEngine
import Std.HttpEngine.H2Conn as H2
import Std.HttpEngine.H2Client
import Std.HttpServerHost
import Grpc.Types
import Grpc.Wire

// ─── State ───────────────────────────────────────────────────────────────────
ref record PooledConn {
  conn: H2ClientConnection
  var idleSinceNanos: Long
}

ref record Backoff {
  var failures: Int
  var retryAtNanos: Long
  var lastError: String
}

ref record ChannelState {
  guard: Mutex
  secure: Bool
  host: String
  port: Int
  authority: String
  opts: ChannelOptions
  conns: List[PooledConn]
  retired: List[H2ClientConnection]
  waiters: List[Int]
  backoff: Backoff
  var closed: Bool
  var nextTicket: Int
}

ref record RespState {
  reader: MessageReader
  maxBytes: Int
  var sawHeaders: Bool
  var encoding: String
  var done: Bool
  var status: GrpcStatus
  var failure: Option[H2CallFailure]
}

ref record Rpc {
  pool: ChannelState
  base: List[HeaderField]
  framed: slice[Byte]
  deadlineNanos: Long
  var call: Option[H2Call]
  var rs: RespState
  var attempts: Int
  var delivered: Int
  var finished: Bool
}

ref record Registry {
  guard: Mutex
  channels: Map[Int, ChannelState]
  streams: Map[Int, Rpc]
  var nextId: Int
}

val registry: Registry = Registry(guard = newMutex(), channels = newMap(), streams = newMap(), nextId = 0)

func newRespState(maxBytes: in Int): RespState {
  RespState(
    reader = newMessageReader(maxBytes),
    maxBytes = maxBytes,
    sawHeaders = false,
    encoding = "",
    done = false,
    status = GrpcStatus(code = GrpcStatusCode.Ok, message = ""),
    failure = None
  )
}

func status(code: in GrpcStatusCode, message: in String): GrpcStatus {
  GrpcStatus(code = code, message = message)
}

func nowNanos(): Long {
  monotonicNanos()
}

// ─── Addresses ───────────────────────────────────────────────────────────────
record Target {
  secure: Bool
  host: String
  port: Int
  authority: String
}

func parseTarget(address: in String): Result[Target, String] {
  val parsed: GrpcAddress = match parseAddress(address) { case Ok(a) -> a; case Err(m) -> return Err(error = m) }
  val auth = parsed.authority
  var host = auth
  var portText = ""
  if Str.startsWith(auth, "[") {
    val close = Str.indexOfRaw(auth, "]")
    if close < 0 {
      return Err(error = "gRPC address has an unterminated IPv6 literal: " + address)
    }
    host = Str.substring(auth, 1, close - 1)
    val rest = Str.substring(auth, close + 1)
    if rest.length > 0 {
      if not Str.startsWith(rest, ":") {
        return Err(error = "gRPC address has junk after the IPv6 literal: " + address)
      }
      portText = Str.substring(rest, 1)
    }
  } else {
    val colon = Str.indexOfRaw(auth, ":")
    if colon >= 0 {
      host = Str.substring(auth, 0, colon)
      portText = Str.substring(auth, colon + 1)
    }
  }
  if host.length == 0 {
    return Err(error = "gRPC address has no host: " + address)
  }
  var port = if parsed.secure { 443 } else { 80 }
  if portText.length > 0 {
    match tryParseInt(portText) {
      case Ok(p) -> {
        if p < 1 or p > 65535 {
          return Err(error = "gRPC address port is out of range: " + address)
        }
        port = p
      }
      case Err(_) -> return Err(error = "gRPC address port is not a number: " + address)
    }
  }
  Ok(value = Target(secure = parsed.secure, host = host, port = port, authority = auth))
}

// ─── Channel lifecycle ───────────────────────────────────────────────────────
func copyOptions(o: in ChannelOptions): ChannelOptions {
  ChannelOptions(
    trust = o.trust,
    identity = o.identity,
    minVersion = o.minVersion,
    maxReceiveMessageBytes = o.maxReceiveMessageBytes,
    maxConnections = o.maxConnections,
    connectTimeoutMs = o.connectTimeoutMs,
    keepAliveIntervalMs = o.keepAliveIntervalMs,
    keepAliveTimeoutMs = o.keepAliveTimeoutMs,
    keepAliveWithoutCalls = o.keepAliveWithoutCalls,
    idleTimeoutMs = o.idleTimeoutMs,
    userAgent = o.userAgent,
    reconnectInitialBackoffMs = o.reconnectInitialBackoffMs,
    reconnectMaxBackoffMs = o.reconnectMaxBackoffMs
  )
}

/// Open a channel to `address` (`http://host[:port]` is h2c with prior
/// knowledge, `https://host[:port]` TLS with ALPN `h2`). Nothing is dialed
/// until the first call. `Err` for a malformed address or invalid options.
pub func openChannel(address: in String, options: in ChannelOptions): Result[GrpcChannel, String] {
  val problem = channelOptionsProblem(options)
  if problem != "" {
    return Err(error = "invalid channel options: " + problem)
  }
  val t: Target = match parseTarget(address) { case Ok(t) -> t; case Err(m) -> return Err(error = m) }
  val pool = ChannelState(
    guard = newMutex(),
    secure = t.secure,
    host = t.host,
    port = t.port,
    authority = t.authority,
    opts = copyOptions(options),
    conns = newList(),
    retired = newList(),
    waiters = newList(),
    backoff = Backoff(failures = 0, retryAtNanos = 0i64, lastError = ""),
    closed = false,
    nextTicket = 0
  )
  lock(registry.guard)
  registry.nextId = registry.nextId + 1
  val id = registry.nextId
  registry.channels.add(id, pool)
  unlock(registry.guard)
  if pool.opts.idleTimeoutMs > 0 {
    startTask({ -> janitor(pool) })
  }
  Ok(value = Types.wrapChannelHandle(id))
}

func lookupPool(channel: in GrpcChannel): Option[ChannelState] {
  lock(registry.guard)
  val p = mapGet(registry.channels, Types.channelHandleId(channel))
  unlock(registry.guard)
  p
}

// A pattern-bound `Option[ChannelState]` value loses its record type on the JVM
// backend, so a field store through it fails at run time (a compiler bug, see
// D802); the store happens on a parameter of the declared type instead.
func detachConnections(pool: in ChannelState): List[H2ClientConnection] {
  val victims: List[H2ClientConnection] = newList()
  lock(pool.guard)
  pool.closed = true
  for pc in pool.conns {
    victims.add(pc.conn)
  }
  for c in pool.retired {
    victims.add(c)
  }
  pool.conns.clear()
  pool.retired.clear()
  unlock(pool.guard)
  victims
}

/// Close the channel: its connections are closed (calls in flight fail with
/// `Unavailable`) and its handle stops working. Closing twice is a no-op.
pub func closeChannel(channel: in GrpcChannel): Unit {
  lock(registry.guard)
  val found = mapGet(registry.channels, Types.channelHandleId(channel))
  val _ = registry.channels.remove(Types.channelHandleId(channel))
  unlock(registry.guard)
  match found {
    case None -> ()
    case Some(pool) -> {
      for c in detachConnections(pool) {
        h2Close(c)
      }
    }
  }
}

func janitorTickMs(idleTimeoutMs: in Int): Int {
  var t = idleTimeoutMs / 4
  if t < 20 {
    t = 20
  }
  if t > 1000 {
    t = 1000
  }
  t
}

func janitor(pool: in ChannelState): Unit {
  val tick = janitorTickMs(pool.opts.idleTimeoutMs)
  val idleNanos = pool.opts.idleTimeoutMs.toLong() * 1000000i64
  var running = true
  while running {
    sleepMillis(tick)
    val victims: List[H2ClientConnection] = newList()
    lock(pool.guard)
    if pool.closed {
      running = false
    } else {
      val keep: List[PooledConn] = newList()
      val now = nowNanos()
      for pc in pool.conns {
        val st = h2ClientStatus(pc.conn)
        if st == H2ClientClosed {
          ()
        } else if st == H2ClientOpen and h2ClientActiveCalls(pc.conn) == 0 {
          if pc.idleSinceNanos == 0i64 {
            pc.idleSinceNanos = now
            keep.add(pc)
          } else if now - pc.idleSinceNanos >= idleNanos {
            victims.add(pc.conn)
          } else {
            keep.add(pc)
          }
        } else {
          pc.idleSinceNanos = 0i64
          keep.add(pc)
        }
      }
      pool.conns.clear()
      for pc in keep {
        pool.conns.add(pc)
      }
      val stillRetired: List[H2ClientConnection] = newList()
      for c in pool.retired {
        if h2ClientStatus(c) != H2ClientClosed {
          stillRetired.add(c)
        }
      }
      pool.retired.clear()
      for c in stillRetired {
        pool.retired.add(c)
      }
    }
    unlock(pool.guard)
    for c in victims {
      h2Close(c)
    }
  }
}

// ─── Dialing and connection choice ───────────────────────────────────────────
func clientOptions(o: in ChannelOptions): H2ClientOptions {
  val base = h2ClientDefaults()
  H2ClientOptions(
    connectTimeoutMs = o.connectTimeoutMs,
    handshakeTimeoutMs = if o.connectTimeoutMs > 0 { o.connectTimeoutMs } else { base.handshakeTimeoutMs },
    writeTimeoutMs = base.writeTimeoutMs,
    pollIntervalMs = base.pollIntervalMs,
    keepAliveIntervalMs = o.keepAliveIntervalMs,
    keepAliveTimeoutMs = o.keepAliveTimeoutMs,
    keepAliveWithoutCalls = o.keepAliveWithoutCalls,
    streamWindow = base.streamWindow,
    connectionWindow = base.connectionWindow
  )
}

func dial(pool: in ChannelState): Result[H2ClientConnection, String] {
  val target = if pool.secure {
    H2Secure(
      host = pool.host,
      port = pool.port,
      trust = pool.opts.trust,
      identity = pool.opts.identity,
      minVersion = pool.opts.minVersion
    )
  } else {
    H2Plain(host = pool.host, port = pool.port)
  }
  match h2Connect(target, clientOptions(pool.opts)) {
    case Ok(c) -> Ok(value = c)
    case Err(e) -> Err(error = H2DialError.message(e))
  }
}

func backoffMs(opts: in ChannelOptions, failures: in Int): Int {
  var d = opts.reconnectInitialBackoffMs.toDouble()
  val cap = opts.reconnectMaxBackoffMs.toDouble()
  var i = 1
  while i < failures and d < cap {
    d = d * 1.6
    i = i + 1
  }
  if d > cap {
    d = cap
  }
  val jitter = 0.8 + 0.4 * nextDouble(sharedRandom())
  val ms = (d * jitter).toInt()
  if ms < 1 {
    1
  } else {
    ms
  }
}

union Started {
  case StartedCall(call: H2Call)
  case StartedFull
  case StartedGone
  case StartedFatal(status: GrpcStatus)
}

func attemptHeaders(base: in List[HeaderField], remainingMs: in Int): List[HeaderField] {
  val hs: List[HeaderField] = newList()
  for h in base {
    hs.add(h)
  }
  if remainingMs > 0 {
    hs.add(HeaderField(name = "grpc-timeout", value = encodeTimeout(remainingMs)))
  }
  hs
}

func tryStart(conn: in H2ClientConnection, base: in List[HeaderField], deadlineNanos: in Long): Started {
  var remaining = 0
  if deadlineNanos > 0i64 {
    remaining = ((deadlineNanos - nowNanos()) / 1000000i64).toInt()
    if remaining < 1 {
      return StartedFatal(status = status(GrpcStatusCode.DeadlineExceeded, "deadline exceeded"))
    }
  }
  match h2StartCall(conn, attemptHeaders(base, remaining), false, remaining) {
    case Ok(call) -> StartedCall(call = call)
    case Err(e) -> match e {
      case H2StartStreamLimit(_, _) -> StartedFull
      case H2StartClosed -> StartedGone
      case H2StartDraining -> StartedGone
      case H2StartIdsExhausted -> StartedGone
      case H2StartWriteFailed(_) -> StartedGone
      case H2StartHeaderListTooLarge(size, limit) -> StartedFatal(
        status = status(
          GrpcStatusCode.ResourceExhausted,
          "request metadata (" + size.toString() +
            " bytes) exceeds the server's header list limit of " +
            limit.toString()
        )
      )
      case H2StartEncodingFailed(m) -> StartedFatal(
        status = status(
          GrpcStatusCode.Internal,
          "request headers cannot be encoded: " + m
        )
      )
    }
  }
}

union Head {
  case HeadCall(call: H2Call)
  case HeadFail(status: GrpcStatus)
  case HeadWait
  case HeadRetry
}

func closedStatus(): GrpcStatus {
  status(GrpcStatusCode.FailedPrecondition, "gRPC channel is closed")
}

// The queue head's turn; `pool.guard` is held on entry and on return, and
// released only around the dial.
func headTurn(pool: in ChannelState, base: in List[HeaderField], deadlineNanos: in Long): Head {
  val live: List[PooledConn] = newList()
  for pc in pool.conns {
    val st = h2ClientStatus(pc.conn)
    if st == H2ClientOpen {
      live.add(pc)
    } else if st == H2ClientDraining {
      pool.retired.add(pc.conn)
    }
  }
  pool.conns.clear()
  for pc in live {
    pool.conns.add(pc)
  }
  var i = 0
  while i < pool.conns.count {
    val pc = pool.conns[i]
    match tryStart(pc.conn, base, deadlineNanos) {
      case StartedCall(call) -> {
        pc.idleSinceNanos = 0i64
        return HeadCall(call = call)
      }
      case StartedFatal(st) -> return HeadFail(status = st)
      case StartedGone -> {
        pool.conns.removeAt(i)
        pool.retired.add(pc.conn)
        i = i - 1
      }
      case StartedFull -> ()
    }
    i = i + 1
  }
  if pool.conns.count >= pool.opts.maxConnections {
    return HeadWait
  }
  if pool.conns.count == 0 and nowNanos() < pool.backoff.retryAtNanos {
    return HeadFail(status = status(GrpcStatusCode.Unavailable, pool.backoff.lastError + " (reconnecting after backoff)"))
  }
  unlock(pool.guard)
  val dialed = dial(pool)
  lock(pool.guard)
  match dialed {
    case Ok(c) -> {
      if pool.closed {
        unlock(pool.guard)
        h2Close(c)
        lock(pool.guard)
        return HeadFail(status = closedStatus())
      }
      pool.backoff.failures = 0
      pool.backoff.lastError = ""
      pool.conns.add(PooledConn(conn = c, idleSinceNanos = 0i64))
      HeadRetry
    }
    case Err(m) -> {
      pool.backoff.failures = pool.backoff.failures + 1
      pool.backoff.lastError = m
      pool.backoff.retryAtNanos = nowNanos() + backoffMs(pool.opts, pool.backoff.failures).toLong() * 1000000i64
      if pool.conns.count == 0 {
        HeadFail(status = status(GrpcStatusCode.Unavailable, m))
      } else {
        HeadWait
      }
    }
  }
}

union Acquired {
  case AcquiredCall(call: H2Call)
  case AcquiredFail(status: GrpcStatus)
}

func acquireCall(pool: in ChannelState, base: in List[HeaderField], deadlineNanos: in Long): Acquired {
  lock(pool.guard)
  val ticket = pool.nextTicket
  pool.nextTicket = pool.nextTicket + 1
  pool.waiters.add(ticket)
  unlock(pool.guard)
  var result: Acquired = AcquiredFail(status = status(GrpcStatusCode.Internal, "no connection attempt was made"))
  var decided = false
  while not decided {
    var pause = 2
    if deadlineNanos > 0i64 and nowNanos() >= deadlineNanos {
      result = AcquiredFail(
        status = status(GrpcStatusCode.DeadlineExceeded, "deadline exceeded while waiting for a connection")
      )
      decided = true
    } else {
      lock(pool.guard)
      if pool.closed {
        result = AcquiredFail(status = closedStatus())
        decided = true
      } else if pool.waiters[0] == ticket {
        match headTurn(pool, base, deadlineNanos) {
          case HeadCall(call) -> {
            result = AcquiredCall(call = call)
            decided = true
          }
          case HeadFail(st) -> {
            result = AcquiredFail(status = st)
            decided = true
          }
          case HeadRetry -> {
            pause = 1
          }
          case HeadWait -> ()
        }
      }
      unlock(pool.guard)
    }
    if not decided {
      sleepMillis(pause)
    }
  }
  lock(pool.guard)
  val at = pool.waiters.indexOf(ticket)
  if at >= 0 {
    pool.waiters.removeAt(at)
  }
  unlock(pool.guard)
  result
}

// ─── One RPC ─────────────────────────────────────────────────────────────────
func finishRpc(rpc: in Rpc, st: in GrpcStatus): Unit {
  rpc.rs.done = true
  rpc.rs.status = st
  match rpc.call {
    case Some(c) -> h2Cancel(c)
    case None -> ()
  }
}

// A server that enforces the deadline it was told (grpc-timeout) resets the
// stream with CANCEL a hair before or after the client's own poll notices it, so
// a CANCEL at or past the deadline is the deadline, not a cancellation.
func failRpc(rpc: in Rpc, f: in H2CallFailure): Unit {
  val rs = rpc.rs
  rs.done = true
  rs.failure = Some(value = f)
  rs.status = statusFromFailure(f)
  match f {
    case H2FailReset(H2Cancel) -> {
      if rpc.deadlineNanos > 0i64 and nowNanos() + 100000000i64 >= rpc.deadlineNanos {
        rs.status = status(GrpcStatusCode.DeadlineExceeded, "deadline exceeded")
      }
    }
    case _ -> ()
  }
}

func startAttempt(rpc: in Rpc): Unit {
  rpc.attempts = rpc.attempts + 1
  rpc.rs = newRespState(rpc.pool.opts.maxReceiveMessageBytes)
  rpc.call = None
  match acquireCall(rpc.pool, rpc.base, rpc.deadlineNanos) {
    case AcquiredFail(st) -> {
      rpc.rs.done = true
      rpc.rs.status = st
    }
    case AcquiredCall(call) -> {
      rpc.call = Some(value = call)
      match h2SendBody(call, rpc.framed, true) {
        case Ok(_) -> ()
        case Err(H2BodyCallFailed(f)) -> failRpc(rpc, f)
        case Err(H2BodyStreamClosed) -> ()
        case Err(H2BodyWriteFailed(m)) -> failRpc(rpc, H2FailConnectionLost(message = m))
      }
    }
  }
}

func handleHeaders(rpc: in Rpc, httpStatus: in Int, headers: in List[HeaderField]): Unit {
  val rs = rpc.rs
  rs.sawHeaders = true
  val carried = statusFromFields(headers)
  if httpStatus != 200 {
    match carried {
      case Some(st) -> finishRpc(rpc, st)
      case None -> finishRpc(rpc, statusFromHttpStatus(httpStatus))
    }
    return
  }
  match carried {
    case Some(st) -> finishRpc(rpc, st)
    case None -> {
      val ct = headerOrEmpty(headers, "content-type")
      if not isGrpcContentType(ct) {
        val shown = if ct == "" { "(none)" } else { ct }
        finishRpc(rpc, status(GrpcStatusCode.Unknown, "unexpected content-type '" + shown + "' on an HTTP 200 response"))
      } else {
        rs.encoding = headerOrEmpty(headers, "grpc-encoding")
      }
    }
  }
}

func handleEvent(rpc: in Rpc, ev: in H2CallEvent): Unit {
  val rs = rpc.rs
  match ev {
    case H2CallInformational(_, _) -> ()
    case H2CallHeaders(s, headers) -> handleHeaders(rpc, s, headers)
    case H2CallData(d) -> readerFeed(rs.reader, d)
    case H2CallTrailers(headers) -> {
      match statusFromFields(headers) {
        case Some(st) -> {
          if st.code == GrpcStatusCode.Ok and readerBuffered(rs.reader) > 0 {
            finishRpc(rpc, status(GrpcStatusCode.Internal, "the response ended in the middle of a message"))
          } else {
            finishRpc(rpc, st)
          }
        }
        case None -> finishRpc(rpc, status(GrpcStatusCode.Unknown, "the server's trailers carry no grpc-status"))
      }
    }
    case H2CallEnded -> {
      if rs.sawHeaders {
        finishRpc(rpc, status(GrpcStatusCode.Internal, "the server ended the stream without a grpc-status"))
      } else {
        finishRpc(rpc, status(GrpcStatusCode.Internal, "the server ended the stream without a response"))
      }
    }
    case H2CallFailed(f) -> failRpc(rpc, f)
  }
}

union Step {
  case StepMessage(payload: slice[Byte])
  case StepEnd(status: GrpcStatus)
}

func canRetry(rpc: in Rpc): Bool {
  match rpc.rs.failure {
    case Some(f) -> h2FailureIsRetrySafe(f) and rpc.attempts < 2 and rpc.delivered == 0 and not rpc.finished
    case None -> false
  }
}

// The next response message, or the call's final status. A call that failed
// retry-safely before delivering anything is started once more.
func rpcNext(rpc: in Rpc): Step {
  while true {
    if rpc.rs.done {
      if canRetry(rpc) {
        startAttempt(rpc)
      } else {
        return StepEnd(status = rpc.rs.status)
      }
    } else {
      var progressed = false
      match readerPoll(rpc.rs.reader) {
        case WireMessage(compressed, payload) -> {
          if compressed {
            match decompressMessage(rpc.rs.encoding, payload, rpc.rs.maxBytes) {
              case Ok(bytes) -> {
                rpc.delivered = rpc.delivered + 1
                return StepMessage(payload = bytes)
              }
              case Err(st) -> {
                finishRpc(rpc, st)
                progressed = true
              }
            }
          } else {
            rpc.delivered = rpc.delivered + 1
            return StepMessage(payload = payload)
          }
        }
        case WireTooLarge(length) -> {
          finishRpc(
            rpc,
            status(
              GrpcStatusCode.ResourceExhausted,
              "received message larger than the maximum (" + length.toString() + " vs. " + rpc.rs.maxBytes.toString() +
                " bytes)"
            )
          )
          progressed = true
        }
        case WireBadFlag(flag) -> {
          finishRpc(rpc, status(GrpcStatusCode.Internal, "invalid message compression flag " + flag.toString()))
          progressed = true
        }
        case WireNeedMore -> ()
      }
      if not progressed {
        match rpc.call {
          case Some(call) -> handleEvent(rpc, h2NextEvent(call))
          case None -> finishRpc(rpc, status(GrpcStatusCode.Internal, "call has no stream"))
        }
      }
    }
  }
  StepEnd(status = rpc.rs.status)
}

func rpcFinished(rpc: in Rpc): Bool {
  rpc.finished
}

func releaseRpc(rpc: in Rpc): Unit {
  rpc.finished = true
  match rpc.call {
    case Some(c) -> h2Cancel(c)
    case None -> ()
  }
}

// ─── Request construction ────────────────────────────────────────────────────
func isReservedRequestKey(k: in String): Bool {
  Str.startsWith(k, "grpc-") or k == "content-type" or k == "te" or k == "user-agent" or k == "host" or
    k == "content-length"
}

func buildBase(
  pool: in ChannelState, service: in String, method: in String, opts: in GrpcCallOptions
): Result[List[HeaderField], GrpcStatus] {
  if service.length == 0 or method.length == 0 {
    return Err(error = status(GrpcStatusCode.InvalidArgument, "the service and method names must not be empty"))
  }
  val hs: List[HeaderField] = newList()
  hs.add(HeaderField(name = ":method", value = "POST"))
  hs.add(HeaderField(name = ":scheme", value = if pool.secure { "https" } else { "http" }))
  hs.add(HeaderField(name = ":path", value = "/" + service + "/" + method))
  hs.add(HeaderField(name = ":authority", value = pool.authority))
  hs.add(HeaderField(name = "content-type", value = "application/grpc"))
  hs.add(HeaderField(name = "te", value = "trailers"))
  hs.add(HeaderField(name = "user-agent", value = pool.opts.userAgent))
  hs.add(HeaderField(name = "grpc-accept-encoding", value = "identity,gzip"))
  if opts.compression == GrpcCompression.Gzip {
    hs.add(HeaderField(name = "grpc-encoding", value = "gzip"))
  }
  for e in opts.metadata {
    if isReservedRequestKey(e.key) {
      return Err(error = status(GrpcStatusCode.InvalidArgument, "metadata key '" + e.key + "' is reserved by the protocol"))
    }
    if Str.endsWith(e.key, "-bin") {
      var enc = encodeBase64(encodeUtf8(e.value))
      while Str.endsWith(enc, "=") {
        enc = Str.substring(enc, 0, enc.length - 1)
      }
      hs.add(HeaderField(name = e.key, value = enc))
    } else {
      hs.add(HeaderField(name = e.key, value = e.value))
    }
  }
  if not H2.isH2RequestHeaderListSafe(hs) {
    return Err(
      error = status(
        GrpcStatusCode.InvalidArgument,
        "the call's metadata or method name is not valid in HTTP/2 headers"
      )
    )
  }
  Ok(value = hs)
}

func newRpc(
  pool: in ChannelState,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions,
): Result[Rpc, GrpcStatus] {
  val base: List[HeaderField] = match buildBase(pool, service, method, opts) {
    case Ok(b) -> b
    case Err(st) -> return Err(error = st)
  }
  val framed = if opts.compression == GrpcCompression.Gzip {
    frameMessage(compressMessage(payload), true)
  } else {
    frameMessage(payload, false)
  }
  var deadline = 0i64
  match opts.timeoutMs {
    case Some(ms) -> {
      deadline = nowNanos() + ms.toLong() * 1000000i64
    }
    case None -> ()
  }
  Ok(
    value = Rpc(
      pool = pool,
      base = base,
      framed = framed,
      deadlineNanos = deadline,
      call = None,
      rs = newRespState(pool.opts.maxReceiveMessageBytes),
      attempts = 0,
      delivered = 0,
      finished = false
    )
  )
}

// ─── Unary ───────────────────────────────────────────────────────────────────
/// A blocking unary call.
pub func callUnary(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions,
): Result[slice[Byte], GrpcStatus] {
  val pool: ChannelState = match lookupPool(channel) {
    case Some(p) -> p
    case None -> return Err(error = closedStatus())
  }
  val rpc: Rpc = match newRpc(pool, service, method, payload, opts) {
    case Ok(r) -> r
    case Err(st) -> return Err(error = st)
  }
  startAttempt(rpc)
  val outcome: Result[slice[Byte], GrpcStatus] = match rpcNext(rpc) {
    case StepMessage(first) -> match rpcNext(rpc) {
      case StepMessage(_) -> {
        finishRpc(rpc, status(GrpcStatusCode.Internal, "the server sent more than one response message"))
        Err(error = rpc.rs.status)
      }
      case StepEnd(st) -> {
        if st.code == GrpcStatusCode.Ok {
          Ok(value = first)
        } else {
          Err(error = st)
        }
      }
    }
    case StepEnd(st) -> {
      if st.code == GrpcStatusCode.Ok {
        Err(error = status(GrpcStatusCode.Internal, "the server finished with OK but sent no response message"))
      } else {
        Err(error = st)
      }
    }
  }
  releaseRpc(rpc)
  outcome
}

// ─── Server streaming ────────────────────────────────────────────────────────
/// Start a server-streaming call. The request is sent now; a failure that
/// only shows once a message is awaited (an unreachable server, a deadline)
/// comes from the first `nextMessage`.
pub func openServerStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions,
): Result[GrpcStream, GrpcStatus] {
  val pool: ChannelState = match lookupPool(channel) {
    case Some(p) -> p
    case None -> return Err(error = closedStatus())
  }
  val rpc: Rpc = match newRpc(pool, service, method, payload, opts) {
    case Ok(r) -> r
    case Err(st) -> return Err(error = st)
  }
  startAttempt(rpc)
  lock(registry.guard)
  registry.nextId = registry.nextId + 1
  val id = registry.nextId
  registry.streams.add(id, rpc)
  unlock(registry.guard)
  Ok(value = Types.wrapStreamHandle(id))
}

/// The next message of a server-streaming response: `Ok(Some)` per message,
/// `Ok(None)` at a clean end, `Err` with the call's final status otherwise
/// (once; later reads are `Ok(None)`).
pub func nextMessage(stream: in GrpcStream): Result[Option[slice[Byte]], GrpcStatus] {
  lock(registry.guard)
  val found = mapGet(registry.streams, Types.streamHandleId(stream))
  unlock(registry.guard)
  match found {
    case None -> Ok(value = None)
    case Some(rpc) -> {
      if rpcFinished(rpc) {
        return Ok(value = None)
      }
      match rpcNext(rpc) {
        case StepMessage(m) -> Ok(value = Some(value = m))
        case StepEnd(st) -> {
          releaseRpc(rpc)
          if st.code == GrpcStatusCode.Ok {
            Ok(value = None)
          } else {
            Err(error = st)
          }
        }
      }
    }
  }
}

/// Cancel (if still running) and release the call; closing twice is a no-op.
pub func closeStream(stream: in GrpcStream): Unit {
  lock(registry.guard)
  val found = mapGet(registry.streams, Types.streamHandleId(stream))
  val _ = registry.streams.remove(Types.streamHandleId(stream))
  unlock(registry.guard)
  match found {
    case Some(rpc) -> releaseRpc(rpc)
    case None -> ()
  }
}

/// How many HTTP/2 connections the channel holds open (test and diagnostic
/// aid).
pub func channelConnectionCount(channel: in GrpcChannel): Int {
  match lookupPool(channel) {
    case None -> 0
    case Some(pool) -> {
      lock(pool.guard)
      var n = 0
      for pc in pool.conns {
        if h2ClientStatus(pc.conn) == H2ClientOpen {
          n = n + 1
        }
      }
      unlock(pool.guard)
      n
    }
  }
}
