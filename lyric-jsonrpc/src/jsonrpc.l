//! src/jsonrpc.l — JsonRpc: transport-agnostic JSON-RPC 2.0 peer.
//!
//! Envelope types, the standard JSON-RPC 2.0 error codes, the
//! `RpcHandler` / `RpcTransport` interfaces application code implements,
//! and the symmetric `RpcPeer` (JSON-RPC has no client/server asymmetry —
//! MCP uses requests in both directions, see docs/62-jsonrpc-mcp.md §3).
//!
//! Dispatch model v1 is single-threaded: `runLoop` reads a message,
//! dispatches it to the handler, writes the response, repeats. `call`
//! issued from inside a handler (an outbound request mid-dispatch) reads
//! the transport inline until the matching response id arrives, queueing
//! any interleaved incoming requests/notifications for dispatch after the
//! call returns — the same discipline LSP servers use.
//!
//! Every outbound call has a deadline (#7451): `call` applies the peer's
//! call timeout (`defaultCallTimeoutMs` unless set with `newPeerWithTimeout`
//! or `setCallTimeout`), and `callWithin` takes one per call. The wait uses
//! `RpcTransport.receiveWithin`, so a peer that never answers fails the call
//! with `requestTimedOut` instead of blocking it forever. The request's id is
//! never reused, so a response that arrives after its call timed out matches
//! nothing: `runLoop` and later calls drop it like any unsolicited response.
//!
//! Batch requests (JSON-RPC 2.0 §6) are supported: an array envelope maps
//! over dispatch, order-preserving, notifications are skipped in the
//! response array, and an empty batch is `-32600 Invalid Request`. A batch
//! longer than `maxBatchSize` is rejected whole with one `-32600` response.
package JsonRpc

import Std.Core
import Std.Collections
import Std.Time
import JsonRpc.Json

// ── Envelope types ─────────────────────────────────────────────────────────
@stable(since = "0.1")
pub union RpcId {
  case IntId(value: Long)
  case StringId(value: String)
  case NullId
}

/// `id = None` marks a notification (no response is ever expected).
@stable(since = "0.1")
pub record RpcRequest {
  id: Option[RpcId]
  method: String
  params: Option[JsonValue]
}

@stable(since = "0.1")
pub record RpcError {
  code: Int
  message: String
  data: Option[JsonValue]
}

// NOTE: the field is named `value`, not `result` as docs/62-jsonrpc-mcp.md §3
// specs it. The self-hosted parser rejects `result` as a union case payload
// field name specifically (reproduced in isolation: a bare union case field
// named `result` fails with "expected a type" — P0050 — even though `result`
// is unremarkable as a record field, a function parameter, or a match-arm
// binding name; only this one production trips over it, presumably because
// `result` is *also* the reserved word available inside `ensures:` contract
// clauses). Filed upstream; see the README's "Known upstream issues" section.
@stable(since = "0.1")
pub union RpcResponse {
  case RpcSuccess(id: RpcId, value: JsonValue)
  case RpcFailure(id: RpcId, error: RpcError)
}

// ── Standard error codes (JSON-RPC 2.0 §5.1) ────────────────────────────────
@stable(since = "0.1")
pub val parseError: Int = -32700

@stable(since = "0.1")
pub val invalidRequest: Int = -32600

@stable(since = "0.1")
pub val methodNotFound: Int = -32601

@stable(since = "0.1")
pub val invalidParams: Int = -32602

@stable(since = "0.1")
pub val internalError: Int = -32603

/// True when `code` lies in -32768..-32000, the range JSON-RPC 2.0 §5.1
/// reserves for predefined errors. Application errors must stay outside it.
@pure
pub func isReservedErrorCode(code: in Int): Bool {
  code >= -32768 and code <= -32000
}

/// An application-defined error. The precondition keeps handlers from
/// passing off their own failures as protocol errors (a reserved code such
/// as `-32601` would tell the peer the method does not exist).
@stable(since = "0.2")
pub func applicationError(code: in Int, message: in String, data: in Option[JsonValue]): RpcError
  requires: not isReservedErrorCode(code)
{
  RpcError(code = code, message = message, data = data)
}

/// True when `method` may be sent by `call`/`notify`: non-empty and not in
/// the `rpc.` namespace, which JSON-RPC 2.0 §4 reserves for rpc-internal
/// methods and extensions.
@pure
pub func isValidOutboundMethod(method: in String): Bool {
  method.length > 0 and not method.startsWith("rpc.")
}

/// Upper bound on the number of elements in an inbound batch. A larger batch
/// is answered with a single `-32600 Invalid Request` instead of being
/// dispatched element by element.
@stable(since = "0.2")
pub val maxBatchSize: Int = 1024

/// Error code of the local failure `call`/`callWithin` return when no
/// response arrives before the deadline. `-32001` lies in the range JSON-RPC
/// 2.0 §5.1 leaves to implementation-defined server errors, and is the code
/// MCP SDKs use for a request timeout. It is never sent to the peer.
@stable(since = "0.2")
pub val requestTimedOut: Int = -32001

/// The call timeout a peer from `newPeer` applies to `call`, in milliseconds.
@stable(since = "0.2")
pub val defaultCallTimeoutMs: Int = 60000

/// Upper bound on a call timeout: 24 hours.
@stable(since = "0.2")
pub val maxCallTimeoutMs: Int = 86400000

/// True when `timeoutMs` is an accepted call timeout: 1 ms to
/// `maxCallTimeoutMs`.
@pure
pub func isValidCallTimeout(timeoutMs: in Int): Bool {
  timeoutMs >= 1 and timeoutMs <= maxCallTimeoutMs
}

/// True when `e` is the local failure of a call whose deadline passed.
@pure
pub func isTimeoutError(e: in RpcError): Bool {
  e.code == requestTimedOut
}

/// Upper bound on the inbound requests/notifications `call` will queue while
/// it waits for its own response. A peer that floods past it fails the
/// pending `call` rather than growing the queue without limit.
@stable(since = "0.2")
pub val maxPendingMessages: Int = 4096

// ── Handler / transport interfaces ──────────────────────────────────────────
@stable(since = "0.1")
pub interface RpcHandler {
  /// Handle an incoming request; return the result value or an error.
  /// A `Bug` raised here is caught at the dispatch boundary and mapped to
  /// `internalError` — the loop is never killed by a handler panic.
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]

  /// Handle an incoming notification (no response is ever sent). A `Bug`
  /// raised here is caught and discarded, same rationale as `onRequest`.
  func onNotification(method: in String, params: in Option[JsonValue]): Unit
}

/// Outcome of `RpcTransport.receiveWithin`: one complete message, clean end
/// of stream, or no complete message within the timeout.
@stable(since = "0.2")
pub union ReceiveOutcome {
  case RpcMessage(text: String)
  case RpcEndOfStream
  case RpcTimedOut
}

@stable(since = "0.1")
pub interface RpcTransport {
  /// Block until the next complete message arrives. `None` ⇒ clean EOF.
  func receive(): Result[Option[String], String]

  /// Wait at most `timeoutMs` milliseconds (`timeoutMs >= 0`) for the next
  /// complete message. A timeout must lose nothing: bytes of a partly
  /// received message stay buffered, and the message is returned whole by a
  /// later `receive` or `receiveWithin`.
  func receiveWithin(timeoutMs: in Int): Result[ReceiveOutcome, String]

  func send(payload: in String): Result[Unit, String]
  func close(): Unit
}

// ── Peer ────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record RpcPeer {
  transport: RpcTransport
  handler: RpcHandler
  var nextId: Long
  // Single-message (never batch-array) values de-batched out of a
  // `call()`'s inline read loop, awaiting dispatch by the next `runLoop`
  // iteration (or the next `call()`, which drains this queue first — see
  // `runLoop`'s pending-queue check).
  var pendingQueue: List[JsonValue]
  // The deadline `call` applies, in milliseconds (`isValidCallTimeout`).
  var callTimeoutMs: Int
}

/// Construct a peer over the given transport and handler, with
/// `defaultCallTimeoutMs` as its call timeout. `runLoop`/`call`/`notify` all
/// take the peer `inout` since dispatch mutates `nextId` and `pendingQueue`.
@stable(since = "0.1")
pub func newPeer(transport: in RpcTransport, handler: in RpcHandler): RpcPeer {
  RpcPeer(
    transport = transport,
    handler = handler,
    nextId = 1i64,
    pendingQueue = newList(),
    callTimeoutMs = defaultCallTimeoutMs
  )
}

/// Construct a peer whose `call` waits at most `callTimeoutMs` milliseconds
/// for each response.
@stable(since = "0.2")
pub func newPeerWithTimeout(transport: in RpcTransport, handler: in RpcHandler, callTimeoutMs: in Int): RpcPeer
  requires: isValidCallTimeout(callTimeoutMs)
{
  RpcPeer(
    transport = transport,
    handler = handler,
    nextId = 1i64,
    pendingQueue = newList(),
    callTimeoutMs = callTimeoutMs
  )
}

/// Change the deadline `call` applies to later calls on this peer.
@stable(since = "0.2")
pub func setCallTimeout(peer: inout RpcPeer, callTimeoutMs: in Int): Unit
  requires: isValidCallTimeout(callTimeoutMs)
{
  peer.callTimeoutMs = callTimeoutMs
}

/// Close the peer's underlying transport.
@stable(since = "0.1")
pub func closePeer(peer: in RpcPeer): Unit {
  peer.transport.close()
}

// ── Envelope encode/decode ──────────────────────────────────────────────────
func encodeId(id: in RpcId): JsonValue {
  match id {
    case IntId(n) -> JInt(value = n)
    case StringId(s) -> JString(value = s)
    case NullId -> JNull
  }
}

/// Decode a JSON value as an `RpcId`: a JSON-RPC id must be a string, an
/// integral number, or null (JSON-RPC 2.0 §5: "Numbers SHOULD NOT contain
/// fractional parts" — this module treats a fractional numeric id as
/// invalid rather than silently truncating it).
func decodeIdOpt(v: in JsonValue): Option[RpcId] {
  match v {
    case JInt(n) -> Some(value = IntId(value = n))
    case JString(s) -> Some(value = StringId(value = s))
    case JNull -> Some(value = NullId)
    case _ -> None
  }
}

func idEquals(a: in RpcId, b: in RpcId): Bool {
  match a {
    case IntId(x) -> match b { case IntId(y) -> x == y; case _ -> false }
    case StringId(x) -> match b { case StringId(y) -> x == y; case _ -> false }
    case NullId -> match b { case NullId -> true; case _ -> false }
  }
}

func hasField(v: in JsonValue, name: in String): Bool {
  isSome(getField(v, name))
}

func isVersion2(v: in JsonValue): Bool {
  match getString(v, "jsonrpc") {
    case Some(s) -> s == "2.0"
    case None -> false
  }
}

// If detecting the id in a malformed Request/batch element fails (parse
// error, missing/invalid id), JSON-RPC 2.0 §5.1 requires the error
// Response's id to be `null` — this recovers a *valid* id when one is
// present, and falls back to `NullId` otherwise.
func extractIdOrNull(v: in JsonValue): RpcId {
  match getField(v, "id") {
    case None -> NullId
    case Some(idv) -> match decodeIdOpt(idv) { case Some(rid) -> rid; case None -> NullId }
  }
}

func isValidParamsShape(p: in JsonValue): Bool {
  match p {
    case JArray(_) -> true
    case JObject(_) -> true
    case _ -> false
  }
}

func encodeRequestObject(id: in Option[RpcId], method: in String, params: in Option[JsonValue]): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "jsonrpc", value = JString(value = "2.0")))
  fields.add(JsonField(name = "method", value = JString(value = method)))
  match params {
    case Some(p) -> fields.add(JsonField(name = "params", value = p))
    case None -> ()
  }
  match id {
    case Some(rid) -> fields.add(JsonField(name = "id", value = encodeId(rid)))
    case None -> ()
  }
  JObject(fields = fields)
}

/// Encode an `RpcRequest` envelope (a request when `id` is `Some`, a
/// notification when `id` is `None`) to its wire `JsonValue`.
@stable(since = "0.1")
pub func encodeRequest(req: in RpcRequest): JsonValue {
  encodeRequestObject(req.id, req.method, req.params)
}

func encodeErrorObject(e: in RpcError): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "code", value = JInt(value = e.code.toLong())))
  fields.add(JsonField(name = "message", value = JString(value = e.message)))
  match e.data {
    case Some(d) -> fields.add(JsonField(name = "data", value = d))
    case None -> ()
  }
  JObject(fields = fields)
}

/// Encode an `RpcResponse` envelope to its wire `JsonValue`.
@stable(since = "0.1")
pub func encodeResponse(resp: in RpcResponse): JsonValue {
  match resp {
    case RpcSuccess(id, resultValue) -> {
      val fields: List[JsonField] = newList()
      fields.add(JsonField(name = "jsonrpc", value = JString(value = "2.0")))
      fields.add(JsonField(name = "id", value = encodeId(id)))
      fields.add(JsonField(name = "result", value = resultValue))
      JObject(fields = fields)
    }
    case RpcFailure(id, error) -> {
      val fields: List[JsonField] = newList()
      fields.add(JsonField(name = "jsonrpc", value = JString(value = "2.0")))
      fields.add(JsonField(name = "id", value = encodeId(id)))
      fields.add(JsonField(name = "error", value = encodeErrorObject(error)))
      JObject(fields = fields)
    }
  }
}

// The peer's `code` is untrusted: a value outside the Int range is mapped to
// `internalError` rather than truncated into an unrelated code.
func decodeErrorFromJson(v: in JsonValue): RpcError {
  val code = match getInt(v, "code") {
    case Some(n) -> if n >= -2147483648i64 and n <= 2147483647i64 { n.toInt() } else { internalError }
    case None -> internalError
  }
  val msg = match getString(v, "message") { case Some(s) -> s; case None -> "" }
  RpcError(code = code, message = msg, data = getField(v, "data"))
}

// ── Dispatch (inbound message → outbound response, or none) ────────────────
func dispatchNotification(handler: in RpcHandler, method: in String, params: in Option[JsonValue]): Unit {
  try {
    handler.onNotification(method, params)
  } catch Bug as b {
    // Per the interface doc: a handler panic here is discarded, never
    // surfaced (no response is possible for a notification, and there is
    // no safe side-channel to report on generically for every RpcTransport).
  }
}

func dispatchRequest(handler: in RpcHandler, id: in RpcId, method: in String, params: in Option[JsonValue]): RpcResponse {
  val outcome: Result[JsonValue, RpcError] = try {
    handler.onRequest(method, params)
  } catch Bug as b {
    // The panic message can carry internal state (paths, values, stack
    // context); it is never sent to the peer.
    Err(error = RpcError(code = internalError, message = "Internal error", data = None))
  }
  match outcome {
    case Ok(v) -> RpcSuccess(id = id, value = v)
    case Err(e) -> RpcFailure(id = id, error = e)
  }
}

func dispatchAsRequestOrNotification(peer: inout RpcPeer, v: in JsonValue): Option[JsonValue] {
  match getField(v, "method") {
    case None -> None
    // unreachable: caller only invokes this branch when hasField(v, "method")
    case Some(methodVal) -> match methodVal {
      case JString(method) -> {
        val paramsOpt = getField(v, "params")
        val paramsValid = match paramsOpt { case None -> true; case Some(p) -> isValidParamsShape(p) }
        if not paramsValid {
          Some(
            value = encodeResponse(
              RpcFailure(
                id = extractIdOrNull(v),
                error = RpcError(
                  code = invalidRequest,
                  message = "Invalid Request: \"params\" must be an array or object",
                  data = None
                )
              )
            )
          )
        } else {
          match getField(v, "id") {
            case None -> {
              dispatchNotification(peer.handler, method, paramsOpt)
              None
            }
            case Some(idv) -> match decodeIdOpt(idv) {
              case None -> Some(
                value = encodeResponse(
                  RpcFailure(
                    id = NullId,
                    error = RpcError(
                      code = invalidRequest,
                      message = "Invalid Request: \"id\" must be a string, number, or null",
                      data = None
                    )
                  )
                )
              )
              case Some(rid) -> Some(
                value = encodeResponse(
                  dispatchRequest(peer.handler, rid, method, paramsOpt)
                )
              )
            }
          }
        }
      }
      case _ -> Some(
        value = encodeResponse(
          RpcFailure(
            id = extractIdOrNull(v),
            error = RpcError(
              code = invalidRequest,
              message = "Invalid Request: \"method\" must be a string",
              data = None
            )
          )
        )
      )
    }
  }
}

// Dispatch a single (already de-batched) top-level JSON value. Returns the
// response to send, or `None` (notification, unsolicited response object,
// or a batch element that produced no response).
func dispatchSingle(peer: inout RpcPeer, v: in JsonValue): Option[JsonValue] {
  match v {
    case JObject(_) -> {
      if not isVersion2(v) {
        Some(
          value = encodeResponse(
            RpcFailure(
              id = extractIdOrNull(v),
              error = RpcError(
                code = invalidRequest,
                message = "Invalid Request: missing or wrong \"jsonrpc\" version (expected \"2.0\")",
                data = None
              )
            )
          )
        )
      } else if hasField(v, "method") {
        dispatchAsRequestOrNotification(peer, v)
      } else if hasField(v, "result") or hasField(v, "error") {
        // An unsolicited Response object seen outside `call`'s inline read
        // (e.g. arriving after the call it answered already timed out).
        // Nothing to correlate it against; drop it.
        None
      } else {
        Some(
          value = encodeResponse(
            RpcFailure(
              id = extractIdOrNull(v),
              error = RpcError(code = invalidRequest, message = "Invalid Request: missing \"method\"", data = None)
            )
          )
        )
      }
    }
    case _ -> Some(
      value = encodeResponse(
        RpcFailure(
          id = NullId,
          error = RpcError(
            code = invalidRequest,
            message = "Invalid Request: expected a JSON object",
            data = None
          )
        )
      )
    )
  }
}

// Dispatch a raw top-level parsed value, which may be a JSON-RPC 2.0 §6
// batch array. Returns the exact wire payload to send (a single response
// object, or a response array), or `None` to send nothing at all.
func dispatchTopLevel(peer: inout RpcPeer, v: in JsonValue): Option[JsonValue] {
  match v {
    case JArray(items) -> {
      if items.count == 0 {
        Some(
          value = encodeResponse(
            RpcFailure(
              id = NullId,
              error = RpcError(code = invalidRequest, message = "Invalid Request: empty batch", data = None)
            )
          )
        )
      } else if items.count > maxBatchSize {
        Some(
          value = encodeResponse(
            RpcFailure(
              id = NullId,
              error = RpcError(
                code = invalidRequest,
                message = "Invalid Request: batch of " + items.count.toString() + " exceeds the limit of " +
                  maxBatchSize.toString(),
                data = None
              )
            )
          )
        )
      } else {
        val responses: List[JsonValue] = newList()
        var i = 0
        while i < items.count {
          match dispatchSingle(peer, items[i]) {
            case Some(r) -> responses.add(r)
            case None -> ()
          }
          i = i + 1
        }
        if responses.count == 0 {
          None
        } else {
          Some(value = JArray(items = responses))
        }
      }
    }
    case _ -> dispatchSingle(peer, v)
  }
}

// ── call()'s inline-read classification ─────────────────────────────────────
union CallItemOutcome {
  case CallMatch(r: Result[JsonValue, RpcError])
  case CallQueue
  case CallIgnore
}

func classifyForCall(v: in JsonValue, waitId: in RpcId): CallItemOutcome {
  match v {
    case JObject(_) -> {
      if hasField(v, "method") {
        CallQueue
      } else if hasField(v, "result") or hasField(v, "error") {
        match getField(v, "id") {
          case None -> CallIgnore
          case Some(idv) -> match decodeIdOpt(idv) {
            case None -> CallIgnore
            case Some(rid) -> {
              if idEquals(rid, waitId) {
                if hasField(v, "result") {
                  CallMatch(r = Ok(value = unwrapOption(getField(v, "result"))))
                } else {
                  CallMatch(r = Err(error = decodeErrorFromJson(unwrapOption(getField(v, "error")))))
                }
              } else {
                CallIgnore
              }
            }
          }
        }
      } else {
        CallIgnore
      }
    }
    case _ -> CallIgnore
  }
}

func handleDuringCall(peer: inout RpcPeer, v: in JsonValue, waitId: in RpcId): Option[Result[JsonValue, RpcError]] {
  match v {
    case JArray(items) -> {
      var found: Option[Result[JsonValue, RpcError]] = None
      var i = 0
      while i < items.count {
        match classifyForCall(items[i], waitId) {
          case CallMatch(r) -> {
            found = Some(value = r)
          }
          case CallQueue -> peer.pendingQueue.add(items[i])
          case CallIgnore -> ()
        }
        i = i + 1
      }
      found
    }
    case _ -> match classifyForCall(v, waitId) {
      case CallMatch(r) -> Some(value = r)
      case CallQueue -> {
        peer.pendingQueue.add(v)
        None
      }
      case CallIgnore -> None
    }
  }
}

func allocateId(peer: inout RpcPeer): RpcId {
  val n = peer.nextId
  peer.nextId = peer.nextId + 1i64
  IntId(value = n)
}

// ── Public API ──────────────────────────────────────────────────────────────
func trySend(peer: inout RpcPeer, payload: in JsonValue, running: inout Bool, outcome: inout Result[Unit, String]): Unit {
  match peer.transport.send(writeValue(payload)) {
    case Err(e) -> {
      running = false
      outcome = Err(error = e)
    }
    case Ok(_) -> ()
  }
}

/// Drive the peer's inbound loop: read a message, dispatch it to the
/// handler, write the response, repeat, until the transport reports clean
/// EOF (`Ok(None)`) or a transport-level failure (`Err`). Drains any
/// messages queued by an in-flight `call()` first, on every iteration,
/// before reading a new one from the transport.
@stable(since = "0.1")
pub func runLoop(peer: inout RpcPeer): Result[Unit, String] {
  var running = true
  var outcome: Result[Unit, String] = Ok(value = ())
  while running {
    if peer.pendingQueue.count > 0 {
      val v = peer.pendingQueue[0]
      peer.pendingQueue.removeAt(0)
      match dispatchTopLevel(peer, v) {
        case None -> ()
        case Some(r) -> trySend(peer, r, running, outcome)
      }
    } else {
      // NOTE: `peer.transport.receive()`'s `Result[Option[String], String]`
      // is deliberately bound to an explicitly-typed local and matched in
      // two separate steps (Result, then Option) rather than as one
      // `match … { case Err(e) -> …; case Ok(None) -> …; case Ok(Some(t))
      // -> … }` directly on the call expression. The flattened three-arm
      // form — where some arms end the `while` loop and others don't —
      // reproducibly breaks on the self-hosted JVM backend: with `Err`/
      // `Ok(None)` (loop-ending) listed before `Ok(Some(_))`
      // (loop-continuing), the loop silently stops after exactly one
      // iteration regardless of which arm actually matched; reordering
      // `Ok(Some(_))` first instead throws a runtime `ClassCastException`
      // (`Option$None cannot be cast to Option$Some`) on the *second*
      // iteration. Both reproduced in isolation with a minimal two-package
      // interface + `while`/`match`/`break` repro, .NET unaffected either
      // way. Filed upstream; see the README's "Known upstream issues"
      // section.
      val received: Result[Option[String], String] = peer.transport.receive()
      match received {
        case Err(e) -> {
          running = false
          outcome = Err(error = e)
        }
        case Ok(opt) -> match opt {
          case None -> {
            running = false
          }
          case Some(text) -> {
            val respOpt = match parseValue(text) {
              case Err(e) -> Some(
                value = encodeResponse(
                  RpcFailure(
                    id = NullId,
                    error = RpcError(
                      code = parseError,
                      message = "Parse error: " + e.message(),
                      data = None
                    )
                  )
                )
              )
              case Ok(parsed) -> dispatchTopLevel(peer, parsed)
            }
            match respOpt {
              case None -> ()
              case Some(r) -> trySend(peer, r, running, outcome)
            }
          }
        }
      }
    }
  }
  outcome
}

/// Issue an outbound request and wait for its response, for at most the
/// peer's call timeout (`callWithin` with `peer.callTimeoutMs`).
@stable(since = "0.1")
pub func call(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]
  requires: isValidOutboundMethod(method)
{
  callWithin(peer, method, params, peer.callTimeoutMs)
}

func callFailure(message: in String): Result[JsonValue, RpcError] {
  Err(error = RpcError(code = internalError, message = message, data = None))
}

func callTimedOut(method: in String, timeoutMs: in Int): Result[JsonValue, RpcError] {
  val detail: List[JsonField] = newList()
  detail.add(JsonField(name = "timeoutMs", value = JInt(value = timeoutMs.toLong())))
  Err(
    error = RpcError(
      code = requestTimedOut,
      message = "timed out after " + timeoutMs.toString() + " ms awaiting response to '" + method + "'",
      data = Some(value = JObject(fields = detail))
    )
  )
}

// Milliseconds left before `deadlineNanos` (a `monotonicNanos` instant),
// rounded up; zero or less once it has passed.
func remainingMs(deadlineNanos: in Long): Int {
  val left = deadlineNanos - monotonicNanos()
  if left <= 0i64 {
    0
  } else {
    ((left + 999999i64) / 1000000i64).toInt()
  }
}

/// Issue an outbound request and wait at most `timeoutMs` milliseconds for
/// its response. Any requests/notifications the peer sends while we wait
/// are queued for `runLoop` (or the next call) to dispatch afterwards — see
/// the module doc; they do not extend the deadline.
///
/// Fails with a local `RpcError` (never sent to the peer): `requestTimedOut`
/// when the deadline passes first (`data` carries `timeoutMs`), otherwise
/// `internalError` — the transport failed or closed, a malformed message
/// arrived, or more than `maxPendingMessages` inbound messages queued up.
/// Queued messages stay queued for `runLoop` in every case, and a response
/// that arrives after a timeout is dropped when it is later read.
@stable(since = "0.2")
pub func callWithin(
  peer: inout RpcPeer, method: in String, params: in Option[JsonValue], timeoutMs: in Int
): Result[JsonValue, RpcError]
  requires: isValidOutboundMethod(method) and isValidCallTimeout(timeoutMs)
{
  val deadline = monotonicNanos() + timeoutMs.toLong() * 1000000i64
  val id = allocateId(peer)
  val reqObj = encodeRequestObject(Some(value = id), method, params)
  match peer.transport.send(writeValue(reqObj)) {
    case Err(e) -> return callFailure("transport send failed: " + e)
    case Ok(_) -> ()
  }
  // See runLoop's NOTE above: the transport's result is bound to a typed
  // local and matched in two steps, and the loop condition is a plain `Bool`
  // flag (not `isNone(settled)`) for the same reason.
  var settled: Option[Result[JsonValue, RpcError]] = None
  var waiting = true
  while waiting {
    val budget = remainingMs(deadline)
    if budget <= 0 {
      settled = Some(value = callTimedOut(method, timeoutMs))
      waiting = false
    } else {
      val received: Result[ReceiveOutcome, String] = peer.transport.receiveWithin(budget)
      match received {
        case Err(e) -> {
          settled = Some(value = callFailure("transport receive failed while awaiting response to '" + method + "': " + e))
          waiting = false
        }
        case Ok(outcome) -> match outcome {
          case RpcTimedOut -> {
            settled = Some(value = callTimedOut(method, timeoutMs))
            waiting = false
          }
          case RpcEndOfStream -> {
            settled = Some(value = callFailure("transport closed while awaiting response to '" + method + "'"))
            waiting = false
          }
          case RpcMessage(text) -> {
            match parseValue(text) {
              case Err(e) -> {
                settled = Some(value = callFailure("malformed message while awaiting response to '" + method + "': " + e.message()))
                waiting = false
              }
              case Ok(v) -> {
                val found = handleDuringCall(peer, v, id)
                match found {
                  case None -> {
                    if peer.pendingQueue.count > maxPendingMessages {
                      settled = Some(
                        value = callFailure(
                          "more than " + maxPendingMessages.toString() +
                            " unanswered inbound messages queued while awaiting response to '" +
                            method +
                            "'"
                        )
                      )
                      waiting = false
                    }
                  }
                  case Some(r) -> {
                    settled = Some(value = r)
                    waiting = false
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  match settled {
    case Some(r) -> r
    case None -> callFailure("internal error: call() loop exited without a result")
  }
}

/// Send a notification (no response is ever expected).
@stable(since = "0.1")
pub func notify(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[Unit, String]
  requires: isValidOutboundMethod(method)
{
  val reqObj = encodeRequestObject(None, method, params)
  peer.transport.send(writeValue(reqObj))
}
