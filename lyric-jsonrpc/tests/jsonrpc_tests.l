//! tests/jsonrpc_tests.l — test suite for JsonRpc (envelope + peer).
//! Covers: request/response/notification round-trips, id correlation, the
//! five standard error-code paths (-32700/-32600/-32601/-32602/-32603),
//! handler-panic-to-internal-error mapping, and batch handling (order
//! preserved, notifications skipped, empty batch -> -32600). Uses an
//! in-memory `RpcTransport` double (`InMemoryTransport` below) so no real
//! pipes are needed.
//!
//! NOTE: `impl` method bodies here deliberately avoid lambda literals — a
//! lambda literal directly inside an `impl` method body crashes the
//! self-hosted MSIL backend (see stdio.l's module doc for the isolated
//! repro and workaround). `InMemoryTransport`/`RecordingHandler` below use
//! only `var`-field mutation and plain control flow, never closures.
@test_module
package JsonRpc.JsonRpcTests

import Std.Core
import Std.Collections
import Std.Testing
import JsonRpc.Json
import JsonRpc

// ── In-memory RpcTransport test double ──────────────────────────────────────
pub record InMemoryTransport {
  var inbox: List[String]
  var outbox: List[String]
  var closed: Bool
}

impl RpcTransport for InMemoryTransport {
  func receive(): Result[Option[String], String] {
    if self.inbox.count > 0 {
      val msg = self.inbox[0]
      self.inbox.removeAt(0)
      Ok(value = Some(value = msg))
    } else {
      Ok(value = None)
    }
  }

  func send(payload: in String): Result[Unit, String] {
    self.outbox.add(payload)
    Ok(value = ())
  }

  func close(): Unit {
    self.closed = true
  }
}

func newInMemoryTransport(): InMemoryTransport {
  InMemoryTransport(inbox = newList(), outbox = newList(), closed = false)
}

func feed(t: in InMemoryTransport, msg: in String): Unit {
  t.inbox.add(msg)
}

// ── In-memory RpcHandler test double ────────────────────────────────────────
// `echo` returns params unchanged; `fail` returns an application-level
// RpcError; `boom` panics (exercises the internalError mapping);
// `unknown-method` returns methodNotFound; `bad-params` returns
// invalidParams. Every request/notification is also recorded for
// assertions (count, last method/params seen).
pub record RecordingHandler {
  var requestCount: Int
  var notificationCount: Int
  var lastMethod: String
  var lastParams: Option[JsonValue]
}

impl RpcHandler for RecordingHandler {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    self.requestCount = self.requestCount + 1
    self.lastMethod = method
    self.lastParams = params
    if method == "echo" {
      match params {
        case Some(p) -> Ok(value = p)
        case None -> Ok(value = JNull)
      }
    } else if method == "fail" {
      Err(error = RpcError(code = 0 - 1, message = "deliberate failure", data = None))
    } else if method == "boom" {
      panic("RecordingHandler: deliberate panic")
    } else if method == "unknown-method" {
      Err(error = RpcError(code = methodNotFound, message = "method not found: " + method, data = None))
    } else if method == "bad-params" {
      Err(error = RpcError(code = invalidParams, message = "bad params", data = None))
    } else {
      Ok(value = JString(value = "handled:" + method))
    }
  }

  func onNotification(method: in String, params: in Option[JsonValue]): Unit {
    self.notificationCount = self.notificationCount + 1
    self.lastMethod = method
    self.lastParams = params
  }
}

func newRecordingHandler(): RecordingHandler {
  RecordingHandler(requestCount = 0, notificationCount = 0, lastMethod = "", lastParams = None)
}

// ── Small assertion helpers over JsonValue (avoids `== Some(...)`, see
// json_tests.l's module doc for why: Option[T] == Option[T] does not
// compare structurally on the current backend) ──────────────────────────────
func assertJString(v: in JsonValue, expected: in String, label: in String): Unit {
  match asString(v) {
    case Some(s) -> assertEqual(s, expected, label)
    case None -> assertTrue(false, label + " (not a JString)")
  }
}

func assertFieldInt(v: in JsonValue, key: in String, expected: in Long, label: in String): Unit {
  match getInt(v, key) {
    case Some(n) -> assertTrue(n == expected, label)
    case None -> assertTrue(false, label + " (field '" + key + "' missing or not an int)")
  }
}

func assertNoField(v: in JsonValue, key: in String, label: in String): Unit {
  match getField(v, key) {
    case None -> ()
    case Some(f) -> assertTrue(false, label + " (unexpected field '" + key + "')")
  }
}

func parseOrFail(text: in String, label: in String): JsonValue {
  match parseValue(text) {
    case Ok(v) -> v
    case Err(e) -> {
      assertTrue(false, label + ": failed to parse own output as JSON: " + e.message())
      JNull
    }
  }
}

// ── Request / response round-trip, id correlation ──────────────────────────
test "runLoop: a request gets a matching-id success response" {
  val t = newInMemoryTransport()
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"echo\",\"params\":{\"x\":1}}")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(t.outbox.count, 1, "one response written")
  val resp = parseOrFail(t.outbox[0], "response")
  assertFieldInt(resp, "id", 7i64, "id echoed back")
  match getField(resp, "result") {
    case None -> assertTrue(false, "expected a result field")
    case Some(r) -> assertFieldInt(r, "x", 1i64, "result echoes params")
  }
  assertNoField(resp, "error", "success response has no error field")
}

test "runLoop: a notification produces no response but reaches the handler" {
  val t = newInMemoryTransport()
  feed(t, "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}")
  val h = newRecordingHandler()
  var peer = newPeer(t, h)
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(t.outbox.count, 0, "no response for a notification")
  assertEqualInt(h.notificationCount, 1, "handler saw the notification")
  assertEqual(h.lastMethod, "ping", "handler recorded the right method")
}

test "runLoop: distinct requests each get their own correctly correlated id" {
  val t = newInMemoryTransport()
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"echo\",\"params\":1}")
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"echo\",\"params\":2}")
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"echo\",\"params\":3}")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(t.outbox.count, 3, "three responses, in order")
  val r0 = parseOrFail(t.outbox[0], "resp0")
  val r1 = parseOrFail(t.outbox[1], "resp1")
  val r2 = parseOrFail(t.outbox[2], "resp2")
  assertFieldInt(r0, "id", 1i64, "resp0 id")
  match getField(r1, "id") {
    case Some(idv) -> match asString(idv) { case Some(s) -> assertEqual(s, "abc", "resp1 has the string id"); case None -> assertTrue(false, "resp1 id should be a string") }
    case None -> assertTrue(false, "resp1 missing id")
  }
  assertFieldInt(r2, "id", 3i64, "resp2 id")
}

// ── Standard error codes ────────────────────────────────────────────────────
test "runLoop: malformed JSON produces -32700 with a null id" {
  val t = newInMemoryTransport()
  feed(t, "{not json")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(t.outbox.count, 1, "one error response")
  val resp = parseOrFail(t.outbox[0], "response")
  match getField(resp, "id") {
    case Some(JNull) -> ()
    case _ -> assertTrue(false, "expected id: null")
  }
  assertFieldInt(unwrapOption(getField(resp, "error")), "code", intToLongForTest(parseError), "-32700")
}

test "runLoop: a non-object top-level value is -32600 Invalid Request" {
  val t = newInMemoryTransport()
  feed(t, "42")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  val resp = parseOrFail(t.outbox[0], "response")
  assertFieldInt(unwrapOption(getField(resp, "error")), "code", intToLongForTest(invalidRequest), "-32600")
}

test "runLoop: missing jsonrpc version is -32600 Invalid Request" {
  val t = newInMemoryTransport()
  feed(t, "{\"id\":1,\"method\":\"echo\"}")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  val resp = parseOrFail(t.outbox[0], "response")
  assertFieldInt(unwrapOption(getField(resp, "error")), "code", intToLongForTest(invalidRequest), "-32600")
  assertFieldInt(resp, "id", 1i64, "the valid id is still echoed back for a recoverable Invalid Request")
}

test "runLoop: a handler-returned methodNotFound (-32601) passes through unchanged" {
  val t = newInMemoryTransport()
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown-method\"}")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  val resp = parseOrFail(t.outbox[0], "response")
  assertFieldInt(unwrapOption(getField(resp, "error")), "code", intToLongForTest(methodNotFound), "-32601")
}

test "runLoop: a handler-returned invalidParams (-32602) passes through unchanged" {
  val t = newInMemoryTransport()
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"bad-params\"}")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  val resp = parseOrFail(t.outbox[0], "response")
  assertFieldInt(unwrapOption(getField(resp, "error")), "code", intToLongForTest(invalidParams), "-32602")
}

test "runLoop: non-array/object params is -32600 Invalid Request" {
  val t = newInMemoryTransport()
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"echo\",\"params\":\"not-array-or-object\"}")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  val resp = parseOrFail(t.outbox[0], "response")
  assertFieldInt(unwrapOption(getField(resp, "error")), "code", intToLongForTest(invalidRequest), "-32600")
}

test "runLoop: a handler panic maps to -32603 internalError, never kills the loop" {
  val t = newInMemoryTransport()
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"boom\"}")
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"echo\",\"params\":{\"n\":42}}")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(t.outbox.count, 2, "the loop survives the panic and keeps processing")
  val r0 = parseOrFail(t.outbox[0], "resp0")
  assertFieldInt(
    unwrapOption(getField(r0, "error")),
    "code",
    intToLongForTest(internalError),
    "-32603 for the panicking request"
  )
  val r1 = parseOrFail(t.outbox[1], "resp1")
  assertNoField(r1, "error", "the request after the panic is handled normally")
}

test "runLoop: a notification handler panic is discarded silently" {
  val t = newInMemoryTransport()
  feed(t, "{\"jsonrpc\":\"2.0\",\"method\":\"boom\"}")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(t.outbox.count, 0, "no response is ever sent for a notification, panic or not")
}

// ── Batch handling (JSON-RPC 2.0 §6) ────────────────────────────────────────
test "runLoop: batch responses preserve request order and skip notifications" {
  val t = newInMemoryTransport()
  feed(
    t,
    "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"echo\",\"params\":\"a\"},{\"jsonrpc\":\"2.0\",\"method\":\"ping\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"echo\",\"params\":\"b\"}]"
  )
  val h = newRecordingHandler()
  var peer = newPeer(t, h)
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(t.outbox.count, 1, "one wire message: a single batch response array")
  assertEqualInt(h.notificationCount, 1, "the notification still reached the handler")
  match parseValue(t.outbox[0]) {
    case Err(e) -> assertTrue(false, "batch response is not valid JSON: " + e.message())
    case Ok(v) -> match asArray(v) { case None -> assertTrue(false, "expected a JSON array"); case Some(items) -> { assertEqualInt(items.count, 2, "two responses (the notification is skipped)"); assertFieldInt(items[0], "id", 1i64, "first response id, in request order"); assertFieldInt(items[1], "id", 2i64, "second response id, in request order") } }
  }
}

test "runLoop: an all-notification batch produces no response at all" {
  val t = newInMemoryTransport()
  feed(t, "[{\"jsonrpc\":\"2.0\",\"method\":\"a\"},{\"jsonrpc\":\"2.0\",\"method\":\"b\"}]")
  val h = newRecordingHandler()
  var peer = newPeer(t, h)
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(t.outbox.count, 0, "JSON-RPC 2.0 §6: no Response array when it would be empty")
  assertEqualInt(h.notificationCount, 2, "both notifications still reached the handler")
}

test "runLoop: an empty batch array is -32600 Invalid Request" {
  val t = newInMemoryTransport()
  feed(t, "[]")
  var peer = newPeer(t, newRecordingHandler())
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(t.outbox.count, 1, "a single (non-batched) error response")
  val resp = parseOrFail(t.outbox[0], "response")
  assertFieldInt(unwrapOption(getField(resp, "error")), "code", intToLongForTest(invalidRequest), "-32600")
  match asArray(resp) {
    case Some(items) -> assertTrue(false, "must not itself be wrapped in an array")
    case None -> ()
  }
}

// ── call() / notify() (outbound side) ───────────────────────────────────────
test "call: sends a well-formed request and resolves on a matching response" {
  val t = newInMemoryTransport()
  var peer = newPeer(t, newRecordingHandler())
  // The transport's receive() is consulted only once call() sends the
  // request, so pre-seed the reply matching the id call() will allocate
  // (ids start at 1 and increment monotonically).
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}")
  match call(peer, "doThing", Some(value = JInt(value = 5i64))) {
    case Err(e) -> assertTrue(false, "unexpected call error: " + e.message)
    case Ok(v) -> match getBool(v, "ok") { case Some(b) -> assertTrue(b, "resolved with the response's result"); case None -> assertTrue(false, "expected {ok: true}") }
  }
  assertEqualInt(t.outbox.count, 1, "exactly one outbound request")
  val req = parseOrFail(t.outbox[0], "outbound request")
  assertJString(unwrapOption(getField(req, "method")), "doThing", "method")
  assertFieldInt(req, "id", 1i64, "auto-assigned id starts at 1")
  assertFieldInt(req, "params", 5i64, "params carried through")
}

test "call: an error response resolves as Err with the wire error" {
  val t = newInMemoryTransport()
  var peer = newPeer(t, newRecordingHandler())
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"nope\"}}")
  match call(peer, "doThing", None) {
    case Ok(v) -> assertTrue(false, "expected Err")
    case Err(e) -> {
      assertEqualInt(e.code, 0 - 32000, "error code carried through")
      assertEqual(e.message, "nope", "error message carried through")
    }
  }
}

test "notify: sends a request object with no id and never blocks on a response" {
  val t = newInMemoryTransport()
  var peer = newPeer(t, newRecordingHandler())
  match notify(peer, "fireAndForget", None) {
    case Err(e) -> assertTrue(false, "unexpected notify error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(t.outbox.count, 1, "one outbound notification")
  val note = parseOrFail(t.outbox[0], "outbound notification")
  assertNoField(note, "id", "a notification carries no id")
  assertJString(unwrapOption(getField(note, "method")), "fireAndForget", "method")
}

test "call: a request/notification arriving from the peer while awaiting a response is queued and dispatched by the next runLoop" {
  val t = newInMemoryTransport()
  val h = newRecordingHandler()
  var peer = newPeer(t, h)
  // Interleaved inbound notification, then the response to our own call.
  feed(t, "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}")
  feed(t, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"pong\"}")
  match call(peer, "ping-remote", None) {
    case Err(e) -> assertTrue(false, "unexpected call error: " + e.message)
    case Ok(v) -> assertJString(v, "pong", "call resolves with its own matching response")
  }
  assertEqualInt(h.notificationCount, 0, "not dispatched yet — queued until runLoop runs")
  match runLoop(peer) {
    case Err(e) -> assertTrue(false, "unexpected runLoop error: " + e)
    case Ok(_) -> ()
  }
  assertEqualInt(h.notificationCount, 1, "the queued notification is dispatched by the next runLoop")
}

// `RpcError.code`'s field type is `Int`, but the standard-code `pub val`s
// (`parseError`, `invalidRequest`, ...) are `Int` too — `assertFieldInt`
// above compares against the wire JSON's `JInt` (`Long`), so this converts.
func intToLongForTest(n: in Int): Long {
  n.toLong()
}
