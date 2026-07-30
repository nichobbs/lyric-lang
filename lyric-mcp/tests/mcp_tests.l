//! tests/mcp_tests.l — full-lifecycle test suite: a real `Mcp.Server`
//! (`McpServer`) driven over an in-memory transport pair connected
//! back-to-back, no real process or socket involved.
//!
//! **Stateless core (docs/64-mcp-2026-stateless-migration.md §3.2)**: most
//! tests below deliberately do NOT call `initialize` first — that is the
//! point being tested. `initialize` remains answerable (a couple of tests
//! cover it directly, for legacy-peer tolerance), but no request needs it
//! to precede anything else anymore.
//!
//! Synchronization: `JsonRpc.RpcTransport.receive()` is documented as
//! blocking ("block until the next complete message arrives"), and this
//! suite runs single-threaded with no real concurrency and no transport
//! that recurses into the server's own `runLoop` from inside its own
//! `receive()` — an earlier version of this suite tried exactly that (a
//! `ClientSideTransport.receive()` that called `runLoop` on the server's
//! peer whenever its own inbound queue was empty, giving `JsonRpc.call()`
//! a live server to talk to synchronously) and hit a real, reproducible
//! `.NET` runtime crash: `System.NullReferenceException` deep inside
//! `JsonRpc.Json.writeValue`'s recursive object writer, isolated (in a
//! from-scratch two-file minimal repro outside this library, mirroring
//! `lyric-jsonrpc/README.md`'s own isolation method) to the *combination*
//! of a nested nested-JSON-object result value (`McpServer`'s
//! `InitializeResult`, which nests `capabilities` and `serverInfo`) with
//! that specific recursive-transport shape — a plain scalar result (the
//! isolated repro's own trivial `EchoHandler`) through the identical
//! recursive-transport pattern does not crash. This is a new, narrower
//! cousin of `lyric-jsonrpc/README.md`'s own documented (JVM-only)
//! "container-shaped `JsonValue` corrupted threading back through
//! `runLoop`'s dispatch machinery" issue, now also reproduced on `.NET`
//! given deep enough recursion through two independently-live `RpcPeer`s.
//! Filed as a new upstream finding; not re-attempted here given the depth
//! of investigation already spent isolating it (see the two ruled-out
//! causes documented in `process_piped_host.l`'s JVM module doc for the
//! unrelated but similarly-shaped investigation done for the piped-process
//! kernel).
//!
//! **Workaround used throughout this file**: never let one `RpcPeer`'s
//! dispatch machinery call into another `RpcPeer`'s dispatch machinery.
//! Every test drives the server directly and non-recursively — inject a
//! request string into the shared mailbox, run the server's `runLoop`
//! exactly once at the test's own top level (never nested inside a
//! transport method), then read the response back out and decode/assert
//! it with `Mcp`'s decode functions — the same "feed, then dispatch, then
//! read the outbox" shape `lyric-jsonrpc/tests/jsonrpc_tests.l` already
//! uses successfully. The one test that needs a genuine `Mcp.Client`
//! (`"a real McpClient round-trips tools/list against a real McpServer,
//! no handshake needed"` below) gets there by *pre-staging* each response
//! the client's `JsonRpc.call()` will need — computed via the same safe
//! non-recursive `stage()` helper, using `JsonRpc`'s own deterministic,
//! auto-incrementing request ids (1, 2, 3, ...) to predict exactly which
//! response `call()`'s inline read loop will be looking for — so `call()`
//! never needs a transport that recurses to produce it. Redundant
//! duplicate requests `call()`/`notify()` still send into the mailbox as
//! a side effect are harmless: they sit unread, or get swept up and
//! answered (then silently ignored as non-matching ids) the next time
//! `stage()` runs the server again.
//!
//! Spec deviation — whole-batch rejection (docs/62-jsonrpc-mcp.md §5.1,
//! "the MCP layer never emits batches and rejects inbound ones"): the
//! shipped `JsonRpc.RpcTransport`/`RpcHandler` boundary (`lyric-jsonrpc`)
//! already implements JSON-RPC 2.0 §6 batching *generically* inside
//! `runLoop`'s private dispatch, fanning a batch array out into
//! independent `onRequest`/`onNotification` calls before an `RpcHandler`
//! such as `McpServer` ever sees anything — there is no hook in the
//! current `RpcHandler` interface for a handler to detect "this call is
//! part of an inbound batch" and reject the envelope as a whole. Adding
//! one would be a new cross-cutting feature in `lyric-jsonrpc`, out of
//! scope for a "small, test-proven fix" to that library.
//!
//! NOTE: assertions compare `Option[T]` via `match`, never `==` — see
//! lyric-jsonrpc/README.md "Known upstream issues" #4.
@test_module
package Mcp.McpTests

import Std.Core
import Std.Collections
import Std.Testing
import JsonRpc.Json
import JsonRpc
import Mcp
import Mcp.Server
import Mcp.Client

// ── In-memory transport pair (non-recursive — see module doc) ──────────────
record Mailbox {
  var toServer: List[String]
  var toClient: List[String]
}

func newMailbox(): Mailbox {
  Mailbox(toServer = newList(), toClient = newList())
}

record ServerSideTransport {
  box: Mailbox
}

impl RpcTransport for ServerSideTransport {
  func receive(): Result[Option[String], String] {
    if self.box.toServer.count > 0 {
      val msg = self.box.toServer[0]
      self.box.toServer.removeAt(0)
      Ok(value = Some(value = msg))
    } else {
      Ok(value = None)
    }
  }

  func send(payload: in String): Result[Unit, String] {
    self.box.toClient.add(payload)
    Ok(value = ())
  }

  func close(): Unit {
  }
}

record ClientSideTransport {
  box: Mailbox
}

impl RpcTransport for ClientSideTransport {
  func receive(): Result[Option[String], String] {
    if self.box.toClient.count > 0 {
      val msg = self.box.toClient[0]
      self.box.toClient.removeAt(0)
      Ok(value = Some(value = msg))
    } else {
      Ok(value = None)
    }
  }

  func send(payload: in String): Result[Unit, String] {
    self.box.toServer.add(payload)
    Ok(value = ())
  }

  func close(): Unit {
  }
}

// ── Driving helpers (non-recursive; see module doc) ─────────────────────────
func reqText(id: in Long, method: in String, params: in Option[JsonValue]): String {
  writeValue(encodeRequest(RpcRequest(id = Some(value = IntId(value = id)), method = method, params = params)))
}

func notifyText(method: in String, params: in Option[JsonValue]): String {
  writeValue(encodeRequest(RpcRequest(id = None, method = method, params = params)))
}

// Inject `text` into the server's inbound queue and run its dispatch loop
// exactly once, at this (top-level, non-nested) call site.
func stage(serverPeer: inout RpcPeer, box: in Mailbox, text: in String): Unit {
  box.toServer.add(text)
  match runLoop(serverPeer) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func popResponse(box: in Mailbox, label: in String): JsonValue {
  if box.toClient.count == 0 {
    assertTrue(false, label + ": no response was written")
    JNull
  } else {
    val text = box.toClient[0]
    box.toClient.removeAt(0)
    match parseValue(text) {
      case Ok(v) -> v
      case Err(e) -> {
        assertTrue(false, label + ": response is not valid JSON: " + e.message())
        JNull
      }
    }
  }
}

func assertResultField(v: in JsonValue, label: in String): JsonValue {
  match getField(v, "result") {
    case Some(r) -> r
    case None -> {
      assertTrue(false, label + ": expected a 'result' field, got " + writeValue(v))
      JNull
    }
  }
}

func assertErrorCode(v: in JsonValue, expectedCode: in Long, label: in String): Unit {
  match getField(v, "error") {
    case None -> assertTrue(false, label + ": expected an 'error' field, got " + writeValue(v))
    case Some(errv) -> match getInt(errv, "code") { case Some(code) -> assertTrue(code == expectedCode, label + " (code=" + code.toString() + ")"); case None -> assertTrue(false, label + ": error has no 'code'") }
  }
}

// ── Test tool/resource/prompt handlers ──────────────────────────────────────
record EchoToolHandler {
}

impl McpToolHandler for EchoToolHandler {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    match args {
      case None -> Ok(value = toolTextResult(""))
      case Some(a) -> match getString(a, "text") { case Some(t) -> Ok(value = toolTextResult(t)); case None -> Ok(value = toolTextResult("")) }
    }
  }
}

record FailingToolHandler {
}

impl McpToolHandler for FailingToolHandler {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    Err(error = "deliberate tool failure")
  }
}

record PanickingToolHandler {
}

impl McpToolHandler for PanickingToolHandler {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    panic("deliberate tool panic")
  }
}

record GreetingResourceHandler {
}

impl McpResourceHandler for GreetingResourceHandler {
  func read(uri: in String): Result[McpResourceContent, String] {
    Ok(value = McpResourceContent(uri = uri, mimeType = "text/plain", text = "hello resource"))
  }
}

record GreetPromptHandler {
}

impl McpPromptHandler for GreetPromptHandler {
  func get(args: in Option[JsonValue]): Result[McpPromptResult, String] {
    val messages: List[McpPromptMessage] = newList()
    messages.add(McpPromptMessage(role = "user", content = TextContent(text = "Hello!")))
    Ok(value = McpPromptResult(description = "A greeting prompt", messages = messages))
  }
}

// A resumable "confirm delete" tool: the canonical permission-prompt shape
// docs/64 §1/§3.1 motivate `McpResumableToolHandler` with. `call` always
// asks for confirmation first; `resume` honors whatever the peer answered.
record ConfirmDeleteHandler {
}

impl McpResumableToolHandler for ConfirmDeleteHandler {
  func call(args: in Option[JsonValue]): Result[McpToolCallOutcome, String] {
    val path = match args {
      case Some(a) -> match getString(a, "path") { case Some(p) -> p; case None -> "" }
      case None -> ""
    }
    val inputRequests = JObject(fields = [JsonField(name = "confirm", value = JBool(value = true))])
    Ok(value = InputRequired(value = McpInputRequired(inputRequests = inputRequests, requestState = "delete:" + path)))
  }

  func resume(requestState: in String, inputResponses: in JsonValue): Result[McpToolCallOutcome, String] {
    val confirmed = match getBool(inputResponses, "confirm") { case Some(b) -> b; case None -> false }
    if confirmed {
      Ok(value = ToolResult(value = toolTextResult("deleted (state=" + requestState + ")")))
    } else {
      Ok(value = ToolResult(value = toolErrorResult("deletion not confirmed")))
    }
  }
}

// ── #6341 regression fixtures: a name registered via both addTool and
// addResumableTool, distinguishable by which handler answered ─────────────
record CollisionPlainHandler {
}

impl McpToolHandler for CollisionPlainHandler {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    Ok(value = toolTextResult("plain"))
  }
}

record CollisionResumableHandler {
}

impl McpResumableToolHandler for CollisionResumableHandler {
  func call(args: in Option[JsonValue]): Result[McpToolCallOutcome, String] {
    Ok(value = ToolResult(value = toolTextResult("resumable")))
  }

  func resume(requestState: in String, inputResponses: in JsonValue): Result[McpToolCallOutcome, String] {
    Ok(value = ToolResult(value = toolTextResult("resumable-resume")))
  }
}

func newTestServer(): McpServer {
  val server = newServer(McpImplementation(name = "test-server", version = "1.0.0"))
  val schema = JObject(fields = [JsonField(name = "type", value = JString(value = "object"))])
  addTool(
    server,
    McpToolDef(name = "echo", description = "Echoes text back", inputSchema = schema, handler = EchoToolHandler())
  )
  addTool(
    server,
    McpToolDef(name = "fail", description = "Always fails", inputSchema = schema, handler = FailingToolHandler())
  )
  addTool(
    server,
    McpToolDef(name = "boom", description = "Always panics", inputSchema = schema, handler = PanickingToolHandler())
  )
  addResumableTool(
    server,
    McpResumableToolDef(
      name = "confirm_delete",
      description = "Deletes a path after confirmation",
      inputSchema = schema,
      handler = ConfirmDeleteHandler()
    )
  )
  addResource(
    server,
    McpResourceDef(
      uri = "test:///greeting",
      name = "greeting",
      description = "A greeting resource",
      mimeType = "text/plain",
      handler = GreetingResourceHandler()
    )
  )
  addPrompt(
    server,
    McpPromptDef(name = "greet", description = "Greets the user", arguments = newList(), handler = GreetPromptHandler())
  )
  server
}

// ── Lifecycle: initialize (legacy-peer tolerance, docs/64 §3.2) ────────────
test "initialize negotiation: a supported version is echoed back" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(
    serverPeer,
    box,
    reqText(
      1i64,
      "initialize",
      Some(value = encodeInitializeParams(protocolVersionLatest, McpImplementation(name = "c", version = "1")))
    )
  )
  val result = assertResultField(popResponse(box, "initialize"), "initialize")
  assertEqual(
    match getString(result, "protocolVersion") { case Some(v) -> v; case None -> "" },
    protocolVersionLatest,
    "primary version echoed back"
  )
}

test "initialize negotiation: the legacy version is also echoed back" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(
    serverPeer,
    box,
    reqText(
      1i64,
      "initialize",
      Some(value = encodeInitializeParams(protocolVersionLegacy, McpImplementation(name = "c", version = "1")))
    )
  )
  val result = assertResultField(popResponse(box, "initialize"), "initialize")
  assertEqual(
    match getString(result, "protocolVersion") { case Some(v) -> v; case None -> "" },
    protocolVersionLegacy,
    "legacy version echoed back"
  )
}

test "initialize negotiation: an unsupported version is refused (server responds with its own primary version)" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(
    serverPeer,
    box,
    reqText(
      1i64,
      "initialize",
      Some(value = encodeInitializeParams("1999-01-01", McpImplementation(name = "c", version = "1")))
    )
  )
  val result = assertResultField(popResponse(box, "initialize"), "initialize")
  assertEqual(
    match getString(result, "protocolVersion") { case Some(v) -> v; case None -> "" },
    protocolVersionLatest,
    "server refuses the requested version and responds with its own primary version"
  )
}

test "initialize response includes capabilities derived from registered tools/resources/prompts" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(
    serverPeer,
    box,
    reqText(
      1i64,
      "initialize",
      Some(value = encodeInitializeParams(protocolVersionLatest, McpImplementation(name = "c", version = "1")))
    )
  )
  val result = assertResultField(popResponse(box, "initialize"), "initialize")
  match getField(result, "capabilities") {
    case None -> assertTrue(false, "expected a capabilities object")
    case Some(caps) -> {
      match getField(caps, "tools") {
        case None -> assertTrue(false, "expected tools capability")
        case Some(_) -> ()
      }
      match getField(caps, "resources") {
        case None -> assertTrue(false, "expected resources capability")
        case Some(_) -> ()
      }
      match getField(caps, "prompts") {
        case None -> assertTrue(false, "expected prompts capability")
        case Some(_) -> ()
      }
    }
  }
}

// ── Stateless core (docs/64 §3.2): no handshake required for anything ─────
test "tools/list works immediately, with no prior initialize or server/discover call" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(serverPeer, box, reqText(1i64, "tools/list", None))
  val result = assertResultField(popResponse(box, "tools/list"), "tools/list")
  match getArray(result, "tools") {
    case None -> assertTrue(false, "expected a 'tools' array")
    case Some(tools) -> assertEqualInt(tools.count, 4, "three plain tools plus one resumable tool")
  }
}

test "ping works immediately, with no prior initialize call" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(serverPeer, box, reqText(1i64, "ping", None))
  val ignored = assertResultField(popResponse(box, "ping"), "ping")
}

test "server/discover: returns serverInfo and derived capabilities, answerable immediately" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(serverPeer, box, reqText(1i64, "server/discover", None))
  val result = assertResultField(popResponse(box, "server/discover"), "server/discover")
  match getField(result, "serverInfo") {
    case None -> assertTrue(false, "expected a serverInfo object")
    case Some(si) -> assertEqual(match getString(si, "name") { case Some(n) -> n; case None -> "" }, "test-server", "serverInfo.name")
  }
  match getField(result, "capabilities") {
    case None -> assertTrue(false, "expected a capabilities object")
    case Some(caps) -> match getField(caps, "tools") { case None -> assertTrue(false, "expected tools capability"); case Some(_) -> () }
  }
  match getField(result, "protocolVersion") {
    case None -> ()
    case Some(_) -> assertTrue(false, "server/discover is not a negotiation and must not carry a protocolVersion field")
  }
}

// ── Tools ────────────────────────────────────────────────────────────────────
test "tools/call: a successful call returns content with isError: false" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val callParams = JObject(
    fields = [
      JsonField(name = "name", value = JString(value = "echo")),
      JsonField(
        name = "arguments",
        value = JObject(
          fields = [JsonField(name = "text", value = JString(value = "hi there"))]
        )
      )
    ]
  )
  stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callParams)))
  val result = assertResultField(popResponse(box, "tools/call"), "tools/call")
  val toolResult = decodeToolResult(result)
  assertFalse(toolResult.isError, "successful call is not an error")
  assertEqualInt(toolResult.content.count, 1, "one content block")
  match toolResult.content[0] {
    case TextContent(t) -> assertEqual(t, "hi there", "echoed text")
    case _ -> assertTrue(false, "expected TextContent")
  }
}

// #6341 — a live McpServer, not just the pure encodeAllToolDefsList encoder,
// must dispatch a name registered via both addTool and addResumableTool to
// the resumable handler, matching the tools/list dedup precedence.
test "tools/call: a name registered via both addTool and addResumableTool dispatches to the resumable handler" {
  val box = newMailbox()
  val schema = JObject(fields = [JsonField(name = "type", value = JString(value = "object"))])
  val server = newServer(McpImplementation(name = "collision-server", version = "1.0.0"))
  addTool(
    server,
    McpToolDef(name = "collide", description = "plain", inputSchema = schema, handler = CollisionPlainHandler())
  )
  addResumableTool(
    server,
    McpResumableToolDef(
      name = "collide",
      description = "resumable",
      inputSchema = schema,
      handler = CollisionResumableHandler()
    )
  )
  var serverPeer = newPeer(ServerSideTransport(box = box), server)
  val callParams = JObject(fields = [JsonField(name = "name", value = JString(value = "collide"))])
  stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callParams)))
  val result = assertResultField(popResponse(box, "tools/call"), "tools/call")
  val toolResult = decodeToolResult(result)
  match toolResult.content[0] {
    case TextContent(t) -> assertEqual(t, "resumable", "collision resolves to the resumable handler's answer, not the plain one")
    case _ -> assertTrue(false, "expected TextContent")
  }
}

test "tools/call: a handler Err becomes a result with isError: true, not a protocol error" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val callParams = JObject(fields = [JsonField(name = "name", value = JString(value = "fail"))])
  stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callParams)))
  val resp = popResponse(box, "tools/call")
  match getField(resp, "error") {
    case Some(_) -> assertTrue(false, "expected a successful (isError-true) result, not a protocol error")
    case None -> {
      val toolResult = decodeToolResult(assertResultField(resp, "tools/call"))
      assertTrue(toolResult.isError, "isError is true")
      match toolResult.content[0] {
        case TextContent(t) -> assertEqual(t, "deliberate tool failure", "error message surfaced as text")
        case _ -> assertTrue(false, "expected TextContent")
      }
    }
  }
}

test "tools/call: a handler panic also becomes an isError result, never kills the connection" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val callParams = JObject(fields = [JsonField(name = "name", value = JString(value = "boom"))])
  stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callParams)))
  val resp = popResponse(box, "tools/call")
  match getField(resp, "error") {
    case Some(_) -> assertTrue(false, "expected a successful (isError-true) result, not a protocol error")
    case None -> assertTrue(decodeToolResult(assertResultField(resp, "tools/call")).isError, "panic surfaces as isError, not a crash")
  }
  // The connection must still be usable afterward.
  stage(serverPeer, box, reqText(2i64, "tools/list", None))
  match getArray(assertResultField(popResponse(box, "tools/list"), "tools/list"), "tools") {
    case Some(tools) -> assertEqualInt(tools.count, 4, "still four tools after the panic")
    case None -> assertTrue(false, "expected a 'tools' array")
  }
}

test "tools/call: an unknown tool name is a protocol error (-32602)" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val callParams = JObject(fields = [JsonField(name = "name", value = JString(value = "does-not-exist"))])
  stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callParams)))
  assertErrorCode(popResponse(box, "tools/call"), 0i64 - 32602i64, "invalidParams for an unknown tool")
}

// A tools/call carrying requestState against a name registered only via
// addTool (never addResumableTool) must not silently fall through to an
// ordinary call() — that would ignore requestState entirely and return a
// misleadingly plain success for a peer that thinks it's resuming.
test "tools/call: requestState against a non-resumable tool is a protocol error, not a silent plain call" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val callParams = JObject(
    fields = [
      JsonField(name = "name", value = JString(value = "echo")),
      JsonField(name = "requestState", value = JString(value = "bogus")),
      JsonField(name = "inputResponses", value = JObject(fields = newList()))
    ]
  )
  stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callParams)))
  assertErrorCode(
    popResponse(box, "tools/call"),
    0i64 - 32602i64,
    "invalidParams for requestState against a non-resumable tool"
  )
}

// getString(p, "requestState") alone can't distinguish "absent" from
// "present but not a string" — both decode to None. A malformed resume
// request (requestState present as the wrong JSON type) must be rejected
// explicitly, not silently treated as a brand-new call().
test "tools/call: a non-string requestState against a resumable tool is a protocol error, not a silent fresh call" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val callParams = JObject(
    fields = [
      JsonField(name = "name", value = JString(value = "confirm_delete")),
      JsonField(name = "requestState", value = JInt(value = 123i64)),
      JsonField(name = "inputResponses", value = JObject(fields = newList()))
    ]
  )
  stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callParams)))
  assertErrorCode(popResponse(box, "tools/call"), 0i64 - 32602i64, "invalidParams for a non-string requestState")
}

// ── Resumable tools: input_required multi-round-trip (docs/64 §3.1) ────────
test "tools/call against a resumable tool answers with input_required, not a finished result" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val callParams = JObject(
    fields = [
      JsonField(name = "name", value = JString(value = "confirm_delete")),
      JsonField(
        name = "arguments",
        value = JObject(
          fields = [JsonField(name = "path", value = JString(value = "/tmp/x"))]
        )
      )
    ]
  )
  stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callParams)))
  val result = assertResultField(popResponse(box, "tools/call"), "tools/call")
  match decodeToolCallOutcome(result) {
    case InputRequired(ir) -> assertEqual(ir.requestState, "delete:/tmp/x", "requestState carries the original call's context")
    case ToolResult(_) -> assertTrue(false, "expected InputRequired on the first call")
  }
}

test "tools/call resume: echoing requestState + confirm:true finishes the deletion" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val resumeParams = JObject(
    fields = [
      JsonField(name = "name", value = JString(value = "confirm_delete")),
      JsonField(name = "requestState", value = JString(value = "delete:/tmp/x")),
      JsonField(
        name = "inputResponses",
        value = JObject(fields = [JsonField(name = "confirm", value = JBool(value = true))])
      )
    ]
  )
  stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = resumeParams)))
  val result = assertResultField(popResponse(box, "tools/call"), "tools/call")
  match decodeToolCallOutcome(result) {
    case ToolResult(r) -> {
      assertFalse(r.isError, "confirmed deletion is not an error")
      match r.content[0] {
        case TextContent(t) -> assertEqual(t, "deleted (state=delete:/tmp/x)", "resume used the echoed requestState")
        case _ -> assertTrue(false, "expected TextContent")
      }
    }
    case InputRequired(_) -> assertTrue(false, "expected a finished ToolResult after resume")
  }
}

test "tools/call resume: confirm:false is reported as isError, not a protocol error" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val resumeParams = JObject(
    fields = [
      JsonField(name = "name", value = JString(value = "confirm_delete")),
      JsonField(name = "requestState", value = JString(value = "delete:/tmp/y")),
      JsonField(
        name = "inputResponses",
        value = JObject(
          fields = [JsonField(name = "confirm", value = JBool(value = false))]
        )
      )
    ]
  )
  stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = resumeParams)))
  val result = assertResultField(popResponse(box, "tools/call"), "tools/call")
  match decodeToolCallOutcome(result) {
    case ToolResult(r) -> assertTrue(r.isError, "refused confirmation surfaces as isError")
    case InputRequired(_) -> assertTrue(false, "expected a finished ToolResult after resume")
  }
}

// ── Resources ────────────────────────────────────────────────────────────────
test "resources/list and resources/read: round-trip a registered resource" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(serverPeer, box, reqText(1i64, "resources/list", None))
  val listResult = assertResultField(popResponse(box, "resources/list"), "resources/list")
  match getArray(listResult, "resources") {
    case Some(resources) -> assertEqualInt(resources.count, 1, "one resource registered")
    case None -> assertTrue(false, "expected a 'resources' array")
  }
  val readParams = JObject(fields = [JsonField(name = "uri", value = JString(value = "test:///greeting"))])
  stage(serverPeer, box, reqText(2i64, "resources/read", Some(value = readParams)))
  val readResult = assertResultField(popResponse(box, "resources/read"), "resources/read")
  match getArray(readResult, "contents") {
    case None -> assertTrue(false, "expected a 'contents' array")
    case Some(contents) -> {
      assertEqualInt(contents.count, 1, "one content entry")
      assertEqual(decodeResourceContent(contents[0]).text, "hello resource", "resource content")
    }
  }
}

test "resources/read: an unknown uri is a protocol error" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val readParams = JObject(fields = [JsonField(name = "uri", value = JString(value = "test:///does-not-exist"))])
  stage(serverPeer, box, reqText(1i64, "resources/read", Some(value = readParams)))
  assertErrorCode(popResponse(box, "resources/read"), 0i64 - 32602i64, "invalidParams for an unknown resource")
}

// ── Prompts ──────────────────────────────────────────────────────────────────
test "prompts/list and prompts/get: round-trip a registered prompt" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(serverPeer, box, reqText(1i64, "prompts/list", None))
  match getArray(assertResultField(popResponse(box, "prompts/list"), "prompts/list"), "prompts") {
    case Some(prompts) -> assertEqualInt(prompts.count, 1, "one prompt registered")
    case None -> assertTrue(false, "expected a 'prompts' array")
  }
  val getParams = JObject(fields = [JsonField(name = "name", value = JString(value = "greet"))])
  stage(serverPeer, box, reqText(2i64, "prompts/get", Some(value = getParams)))
  val result = decodePromptResult(assertResultField(popResponse(box, "prompts/get"), "prompts/get"))
  assertEqual(result.description, "A greeting prompt", "prompt description")
  assertEqualInt(result.messages.count, 1, "one message")
  assertEqual(result.messages[0].role, "user", "message role")
}

// ── Batch handling ───────────────────────────────────────────────────────────
test "batch: every element is handled normally, with no prior handshake needed" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(
    serverPeer,
    box,
    "[{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"ping\"},{\"jsonrpc\":\"2.0\",\"id\":101,\"method\":\"tools/list\"}]"
  )
  match asArray(popResponse(box, "batch")) {
    case None -> assertTrue(false, "expected a JSON array")
    case Some(items) -> {
      assertEqualInt(items.count, 2, "both batch elements produced a response")
      assertResultField(items[0], "batch[0] (ping)")
      match getArray(assertResultField(items[1], "batch[1] (tools/list)"), "tools") {
        case Some(tools) -> assertEqualInt(tools.count, 4, "four tools listed")
        case None -> assertTrue(false, "expected a 'tools' array")
      }
    }
  }
}

// ── A real Mcp.Client against a real Mcp.Server ─────────────────────────────
// See the module doc's "Workaround used throughout this file": every
// response `JsonRpc.call()` will look for is pre-staged (computed via the
// same non-recursive `stage()` helper) before the real `Mcp.Client`
// function that triggers the matching `call()` is invoked, so `call()`'s
// own inline read loop finds it immediately without any transport ever
// recursing into the server's dispatch machinery.
test "a real McpClient round-trips server/discover + tools/list against a real McpServer, no handshake needed" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())

  match connectTransport(ClientSideTransport(box = box)) {
    case Err(e) -> assertTrue(false, "connectTransport failed: " + e)
    case Ok(clientVal) -> {
      var client = clientVal
      assertEqual(client.serverInfo.name, "", "serverInfo is empty until discoverServer is called")

      // Pre-stage the "server/discover" response the next `call()` (id 1,
      // deterministic — the peer's first call) will read.
      stage(serverPeer, box, reqText(1i64, "server/discover", None))
      match discoverServer(client) {
        case Err(e) -> assertTrue(false, "discoverServer failed: " + e)
        case Ok(discovered) -> {
          assertEqual(discovered.serverInfo.name, "test-server", "discovered serverInfo.name")
          assertTrue(discovered.capabilities.hasTools, "discovered capabilities.hasTools (server has 4 tools registered)")
        }
      }
      assertEqual(client.serverInfo.name, "test-server", "client.serverInfo updated in place")

      // Pre-stage the "tools/list" response the next `call()` (id 2) will
      // read — no `initialize`/`notifications/initialized` round trip was
      // ever needed for either call above.
      stage(serverPeer, box, reqText(2i64, "tools/list", None))
      match listTools(client) {
        case Err(e) -> assertTrue(false, "listTools failed: " + e)
        case Ok(tools) -> {
          assertEqualInt(tools.count, 4, "four tools registered")
          assertEqual(tools[0].name, "echo", "first tool name")
        }
      }
    }
  }
}

test "a real McpClient drives the full input_required resume loop against a real McpServer" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())

  match connectTransport(ClientSideTransport(box = box)) {
    case Err(e) -> assertTrue(false, "connectTransport failed: " + e)
    case Ok(clientVal) -> {
      var client = clientVal
      val args = JObject(fields = [JsonField(name = "path", value = JString(value = "/tmp/z"))])

      // Pre-stage the exact wire request `callResumableTool` sends, matching
      // its own params construction (see `Mcp.Client.callResumableTool`).
      val callWireParams = JObject(
        fields = [
          JsonField(name = "name", value = JString(value = "confirm_delete")),
          JsonField(name = "arguments", value = args)
        ]
      )
      stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callWireParams)))
      match callResumableTool(client, "confirm_delete", Some(value = args)) {
        case Err(e) -> assertTrue(false, "callResumableTool failed: " + e)
        case Ok(outcome) -> match outcome {
          case InputRequired(ir) -> {
            assertEqual(ir.requestState, "delete:/tmp/z", "requestState from the first call")
            val inputResponses = JObject(fields = [JsonField(name = "confirm", value = JBool(value = true))])
            // Pre-stage the exact wire request `resumeToolCall` sends.
            val resumeWireParams = JObject(
              fields = [
                JsonField(name = "name", value = JString(value = "confirm_delete")),
                JsonField(name = "requestState", value = JString(value = ir.requestState)),
                JsonField(name = "inputResponses", value = inputResponses)
              ]
            )
            stage(serverPeer, box, reqText(2i64, "tools/call", Some(value = resumeWireParams)))
            match resumeToolCall(client, "confirm_delete", ir.requestState, inputResponses) {
              case Err(e) -> assertTrue(false, "resumeToolCall failed: " + e)
              case Ok(resumed) -> match resumed { case ToolResult(r) -> assertFalse(r.isError, "resumed call finished successfully"); case InputRequired(_) -> assertTrue(false, "expected a finished ToolResult after resume") }
            }
          }
          case ToolResult(_) -> assertTrue(false, "expected InputRequired on the first call")
        }
      }
    }
  }
}

// #6334 — a resumable tool's `input_required` answer must never reach the
// plain `callTool`/`decodeToolResult` path silently: before this fix,
// `decodeToolResult`'s lenient defaulting would turn the missing
// `content`/`isError` fields into a false-success `McpToolResult(content =
// [], isError = false)`, indistinguishable from "the tool ran and produced
// no output" — dangerous for a permission-gated tool like `confirm_delete`.
test "callTool against a resumable tool's input_required answer returns Err, not a false-success empty result" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())

  match connectTransport(ClientSideTransport(box = box)) {
    case Err(e) -> assertTrue(false, "connectTransport failed: " + e)
    case Ok(clientVal) -> {
      var client = clientVal
      val args = JObject(fields = [JsonField(name = "path", value = JString(value = "/tmp/z"))])
      val callWireParams = JObject(
        fields = [
          JsonField(name = "name", value = JString(value = "confirm_delete")),
          JsonField(name = "arguments", value = args)
        ]
      )
      stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callWireParams)))
      match callTool(client, "confirm_delete", Some(value = args)) {
        case Err(e) -> assertTrue(e.contains("input_required"), "callTool's Err should reference input_required, got: " + e)
        case Ok(result) -> assertTrue(false, "expected an Err — callTool instead returned Ok(McpToolResult(content.count = " + result.content.count.toString() + ")), a false-success (#6334 regression)")
      }
    }
  }
}

// Happy-path counterpart to the #6334 regression test above: a plain
// (non-resumable) tool's ordinary result has no `resultType` field at all,
// so callTool's resultType guard must not fire on it — confirms the guard
// only rejects a genuine input_required response, not every response.
test "callTool against a plain tool's ordinary result returns Ok with the expected content" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())

  match connectTransport(ClientSideTransport(box = box)) {
    case Err(e) -> assertTrue(false, "connectTransport failed: " + e)
    case Ok(clientVal) -> {
      var client = clientVal
      val args = JObject(fields = [JsonField(name = "text", value = JString(value = "hi there"))])
      val callWireParams = JObject(
        fields = [
          JsonField(name = "name", value = JString(value = "echo")),
          JsonField(name = "arguments", value = args)
        ]
      )
      stage(serverPeer, box, reqText(1i64, "tools/call", Some(value = callWireParams)))
      match callTool(client, "echo", Some(value = args)) {
        case Err(e) -> assertTrue(false, "callTool failed: " + e)
        case Ok(result) -> {
          assertFalse(result.isError, "successful call is not an error")
          match result.content[0] {
            case TextContent(t) -> assertEqual(t, "hi there", "echoed text")
            case _ -> assertTrue(false, "expected TextContent")
          }
        }
      }
    }
  }
}
