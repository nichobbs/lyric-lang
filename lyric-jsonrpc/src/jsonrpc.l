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
//! Batch requests (JSON-RPC 2.0 §6) are supported: an array envelope maps
//! over dispatch, order-preserving, notifications are skipped in the
//! response array, and an empty batch is `-32600 Invalid Request`.
package JsonRpc

import Std.Core
import Std.Collections
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

@stable(since = "0.1")
pub interface RpcTransport {
  /// Block until the next complete message arrives. `None` ⇒ clean EOF.
  func receive(): Result[Option[String], String]
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
}

/// Construct a peer over the given transport and handler. `runLoop`/`call`/
/// `notify` all take the peer `inout` since dispatch mutates `nextId` and
/// `pendingQueue`.
@stable(since = "0.1")
pub func newPeer(transport: in RpcTransport, handler: in RpcHandler): RpcPeer {
  RpcPeer(transport = transport, handler = handler, nextId = 1i64, pendingQueue = newList())
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

func decodeErrorFromJson(v: in JsonValue): RpcError {
  val code = match getInt(v, "code") { case Some(n) -> n.toInt(); case None -> internalError }
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
    Err(error = RpcError(code = internalError, message = "Internal error: " + b.message, data = None))
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
    case Some(methodVal) -> match methodVal { case JString(method) -> { val paramsOpt = getField(v, "params"); val paramsValid = match paramsOpt { case None -> true; case Some(p) -> isValidParamsShape(p) }; if not paramsValid { Some(value = encodeResponse(RpcFailure(id = extractIdOrNull(v), error = RpcError(code = invalidRequest, message = "Invalid Request: \"params\" must be an array or object", data = None)))) } else { match getField(v, "id") { case None -> { dispatchNotification(peer.handler, method, paramsOpt); None }; case Some(idv) -> match decodeIdOpt(idv) { case None -> Some(value = encodeResponse(RpcFailure(id = NullId, error = RpcError(code = invalidRequest, message = "Invalid Request: \"id\" must be a string, number, or null", data = None)))); case Some(rid) -> Some(value = encodeResponse(dispatchRequest(peer.handler, rid, method, paramsOpt))) } } } }; case _ -> Some(value = encodeResponse(RpcFailure(id = extractIdOrNull(v), error = RpcError(code = invalidRequest, message = "Invalid Request: \"method\" must be a string", data = None)))) }
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
        // (e.g. arriving after the call it answered already timed out /
        // moved on). Nothing to correlate it against; drop it.
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
    case _ -> Some(value = encodeResponse(RpcFailure(id = NullId, error = RpcError(code = invalidRequest, message = "Invalid Request: expected a JSON object", data = None))))
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
          case Some(idv) -> match decodeIdOpt(idv) { case None -> CallIgnore; case Some(rid) -> { if idEquals(rid, waitId) { if hasField(v, "result") { CallMatch(r = Ok(value = unwrapOption(getField(v, "result")))) } else { CallMatch(r = Err(error = decodeErrorFromJson(unwrapOption(getField(v, "error"))))) } } else { CallIgnore } } }
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
    case _ -> match classifyForCall(v, waitId) { case CallMatch(r) -> Some(value = r); case CallQueue -> { peer.pendingQueue.add(v); None }; case CallIgnore -> None }
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
        case Ok(opt) -> match opt { case None -> { running = false }; case Some(text) -> { val respOpt = match parseValue(text) { case Err(e) -> Some(value = encodeResponse(RpcFailure(id = NullId, error = RpcError(code = parseError, message = "Parse error: " + e.message(), data = None)))); case Ok(parsed) -> dispatchTopLevel(peer, parsed) }; match respOpt { case None -> (); case Some(r) -> trySend(peer, r, running, outcome) } } }
      }
    }
  }
  outcome
}

/// Issue an outbound request and block until its response arrives. Any
/// requests/notifications the peer sends while we wait are queued for
/// `runLoop` (or the next `call()`) to dispatch afterwards — see the
/// module doc.
@stable(since = "0.1")
pub func call(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
  val id = allocateId(peer)
  val reqObj = encodeRequestObject(Some(value = id), method, params)
  match peer.transport.send(writeValue(reqObj)) {
    case Err(e) -> return Err(error = RpcError(code = internalError, message = "transport send failed: " + e, data = None))
    case Ok(_) -> ()
  }
  // See runLoop's NOTE above: the Result[Option[String], String] from
  // `receive()` is matched in two steps, and the loop condition is a plain
  // `Bool` flag (not `isNone(settled)`) for the same reason.
  var settled: Option[Result[JsonValue, RpcError]] = None
  var waiting = true
  while waiting {
    val received: Result[Option[String], String] = peer.transport.receive()
    match received {
      case Err(e) -> {
        settled = Some(
          value = Err(
            error = RpcError(
              code = internalError,
              message = "transport receive failed while awaiting response to '" + method + "': " + e,
              data = None
            )
          )
        )
        waiting = false
      }
      case Ok(opt) -> match opt { case None -> { settled = Some(value = Err(error = RpcError(code = internalError, message = "transport closed while awaiting response to '" + method + "'", data = None))); waiting = false }; case Some(text) -> { match parseValue(text) { case Err(e) -> { settled = Some(value = Err(error = RpcError(code = internalError, message = "malformed message while awaiting response to '" + method + "': " + e.message(), data = None))); waiting = false }; case Ok(v) -> { val found = handleDuringCall(peer, v, id); match found { case None -> (); case Some(r) -> { settled = Some(value = r); waiting = false } } } } } }
    }
  }
  match settled {
    case Some(r) -> r
    case None -> Err(error = RpcError(code = internalError, message = "internal error: call() loop exited without a result", data = None))
  }
}

/// Send a notification (no response is ever expected).
@stable(since = "0.1")
pub func notify(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[Unit, String] {
  val reqObj = encodeRequestObject(None, method, params)
  peer.transport.send(writeValue(reqObj))
}
