//! tests/mcp_tests.l — full-lifecycle test suite: a real `Mcp.Server`
//! (`McpServer`) driven over an in-memory transport pair connected
//! back-to-back, no real process or socket involved.
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
//! (`"a real McpClient round-trips initialize + tools/list against a real
//! McpServer"` below) gets there by *pre-staging* each response the
//! client's `JsonRpc.call()` will need — computed via the same safe
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
//! scope for a "small, test-proven fix" to that library. What IS verified
//! here (`"a batch is not exempt from the initialization gate"` below) is
//! that MCP's own per-request rules (`serverNotInitialized`, unknown
//! method, ...) still apply independently to every element of an inbound
//! batch, so a batch can never be used to bypass them — a batch is not
//! *specially* rejected, but it cannot get further than a single message
//! could.
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

// Runs the full initialize handshake directly against `serverPeer`
// (non-recursive) and returns the negotiated protocol version. Leaves the
// server `ready`.
func handshake(serverPeer: inout RpcPeer, box: in Mailbox, requestedVersion: in String): String {
  stage(
    serverPeer,
    box,
    reqText(
      1i64,
      "initialize",
      Some(value = encodeInitializeParams(requestedVersion, McpImplementation(name = "c", version = "1")))
    )
  )
  val resp = popResponse(box, "initialize")
  val result = assertResultField(resp, "initialize")
  stage(serverPeer, box, notifyText("notifications/initialized", None))
  match getString(result, "protocolVersion") {
    case Some(v) -> v
    case None -> ""
  }
}

// ── Lifecycle: initialize / notifications/initialized ──────────────────────
test "initialize negotiation: a supported version is echoed back" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val negotiated = handshake(serverPeer, box, protocolVersionLatest)
  assertEqual(negotiated, protocolVersionLatest, "primary version echoed back")
}

test "initialize negotiation: the legacy version is also echoed back" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val negotiated = handshake(serverPeer, box, protocolVersionLegacy)
  assertEqual(negotiated, protocolVersionLegacy, "legacy version echoed back")
}

test "initialize negotiation: an unsupported version is refused (server responds with its own primary version)" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val negotiated = handshake(serverPeer, box, "1999-01-01")
  assertEqual(
    negotiated,
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

test "request before initialize completes gets serverNotInitialized" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(serverPeer, box, reqText(1i64, "tools/list", None))
  assertErrorCode(popResponse(box, "tools/list"), 0i64 - 32002i64, "serverNotInitialized")
}

test "ping before initialize also gets serverNotInitialized" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(serverPeer, box, reqText(1i64, "ping", None))
  assertErrorCode(popResponse(box, "ping"), 0i64 - 32002i64, "serverNotInitialized")
}

// ── Tools ────────────────────────────────────────────────────────────────────
test "tools/list: returns every registered tool" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  handshake(serverPeer, box, protocolVersionLatest)
  stage(serverPeer, box, reqText(2i64, "tools/list", None))
  val result = assertResultField(popResponse(box, "tools/list"), "tools/list")
  match getArray(result, "tools") {
    case None -> assertTrue(false, "expected a 'tools' array")
    case Some(tools) -> assertEqualInt(tools.count, 3, "three tools registered")
  }
}

test "tools/call: a successful call returns content with isError: false" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  handshake(serverPeer, box, protocolVersionLatest)
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
  stage(serverPeer, box, reqText(2i64, "tools/call", Some(value = callParams)))
  val result = assertResultField(popResponse(box, "tools/call"), "tools/call")
  val toolResult = decodeToolResult(result)
  assertFalse(toolResult.isError, "successful call is not an error")
  assertEqualInt(toolResult.content.count, 1, "one content block")
  match toolResult.content[0] {
    case TextContent(t) -> assertEqual(t, "hi there", "echoed text")
    case _ -> assertTrue(false, "expected TextContent")
  }
}

test "tools/call: a handler Err becomes a result with isError: true, not a protocol error" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  handshake(serverPeer, box, protocolVersionLatest)
  val callParams = JObject(fields = [JsonField(name = "name", value = JString(value = "fail"))])
  stage(serverPeer, box, reqText(2i64, "tools/call", Some(value = callParams)))
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
  handshake(serverPeer, box, protocolVersionLatest)
  val callParams = JObject(fields = [JsonField(name = "name", value = JString(value = "boom"))])
  stage(serverPeer, box, reqText(2i64, "tools/call", Some(value = callParams)))
  val resp = popResponse(box, "tools/call")
  match getField(resp, "error") {
    case Some(_) -> assertTrue(false, "expected a successful (isError-true) result, not a protocol error")
    case None -> assertTrue(decodeToolResult(assertResultField(resp, "tools/call")).isError, "panic surfaces as isError, not a crash")
  }
  // The connection must still be usable afterward.
  stage(serverPeer, box, reqText(3i64, "tools/list", None))
  match getArray(assertResultField(popResponse(box, "tools/list"), "tools/list"), "tools") {
    case Some(tools) -> assertEqualInt(tools.count, 3, "still three tools after the panic")
    case None -> assertTrue(false, "expected a 'tools' array")
  }
}

test "tools/call: an unknown tool name is a protocol error (-32602)" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  handshake(serverPeer, box, protocolVersionLatest)
  val callParams = JObject(fields = [JsonField(name = "name", value = JString(value = "does-not-exist"))])
  stage(serverPeer, box, reqText(2i64, "tools/call", Some(value = callParams)))
  assertErrorCode(popResponse(box, "tools/call"), 0i64 - 32602i64, "invalidParams for an unknown tool")
}

// ── Resources ────────────────────────────────────────────────────────────────
test "resources/list and resources/read: round-trip a registered resource" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  handshake(serverPeer, box, protocolVersionLatest)
  stage(serverPeer, box, reqText(2i64, "resources/list", None))
  val listResult = assertResultField(popResponse(box, "resources/list"), "resources/list")
  match getArray(listResult, "resources") {
    case Some(resources) -> assertEqualInt(resources.count, 1, "one resource registered")
    case None -> assertTrue(false, "expected a 'resources' array")
  }
  val readParams = JObject(fields = [JsonField(name = "uri", value = JString(value = "test:///greeting"))])
  stage(serverPeer, box, reqText(3i64, "resources/read", Some(value = readParams)))
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
  handshake(serverPeer, box, protocolVersionLatest)
  val readParams = JObject(fields = [JsonField(name = "uri", value = JString(value = "test:///does-not-exist"))])
  stage(serverPeer, box, reqText(2i64, "resources/read", Some(value = readParams)))
  assertErrorCode(popResponse(box, "resources/read"), 0i64 - 32602i64, "invalidParams for an unknown resource")
}

// ── Prompts ──────────────────────────────────────────────────────────────────
test "prompts/list and prompts/get: round-trip a registered prompt" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  handshake(serverPeer, box, protocolVersionLatest)
  stage(serverPeer, box, reqText(2i64, "prompts/list", None))
  match getArray(assertResultField(popResponse(box, "prompts/list"), "prompts/list"), "prompts") {
    case Some(prompts) -> assertEqualInt(prompts.count, 1, "one prompt registered")
    case None -> assertTrue(false, "expected a 'prompts' array")
  }
  val getParams = JObject(fields = [JsonField(name = "name", value = JString(value = "greet"))])
  stage(serverPeer, box, reqText(3i64, "prompts/get", Some(value = getParams)))
  val result = decodePromptResult(assertResultField(popResponse(box, "prompts/get"), "prompts/get"))
  assertEqual(result.description, "A greeting prompt", "prompt description")
  assertEqualInt(result.messages.count, 1, "one message")
  assertEqual(result.messages[0].role, "user", "message role")
}

// ── Ping ─────────────────────────────────────────────────────────────────────
test "ping: succeeds once initialized" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  handshake(serverPeer, box, protocolVersionLatest)
  stage(serverPeer, box, reqText(2i64, "ping", None))
  val ignored = assertResultField(popResponse(box, "ping"), "ping")
}

// ── Batch handling ───────────────────────────────────────────────────────────
test "a batch is not exempt from the initialization gate (see module doc's spec-deviation note)" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  stage(
    serverPeer,
    box,
    "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}]"
  )
  match asArray(popResponse(box, "batch")) {
    case None -> assertTrue(false, "expected a JSON array")
    case Some(items) -> {
      assertEqualInt(items.count, 2, "both batch elements produced a response")
      var i = 0
      while i < items.count {
        assertErrorCode(items[i], 0i64 - 32002i64, "batch element " + i.toString() + " gets serverNotInitialized")
        i = i + 1
      }
    }
  }
}

test "batch: once initialized, every batch element is handled normally" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  handshake(serverPeer, box, protocolVersionLatest)
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
        case Some(tools) -> assertEqualInt(tools.count, 3, "three tools listed")
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
test "a real McpClient round-trips initialize + tools/list against a real McpServer" {
  val box = newMailbox()
  var serverPeer = newPeer(ServerSideTransport(box = box), newTestServer())
  val clientInfo = McpImplementation(name = "real-client", version = "1.0.0")

  // Pre-stage the "initialize" response `connectTransport`'s internal
  // `call()` (id 1, deterministic — the peer's first call) will read.
  stage(
    serverPeer,
    box,
    reqText(1i64, "initialize", Some(value = encodeInitializeParams(protocolVersionLatest, clientInfo)))
  )

  match connectTransport(ClientSideTransport(box = box)) {
    case Err(e) -> assertTrue(false, "connectTransport failed: " + e)
    case Ok(clientVal) -> {
      var client = clientVal
      assertEqual(client.protocolVersion, protocolVersionLatest, "negotiated protocol version")
      assertEqual(client.serverInfo.name, "test-server", "serverInfo.name")

      // `connectTransport` also sent `notifications/initialized`, still
      // sitting unread in `box.toServer` alongside the harmless duplicate
      // "initialize" `call()` itself sent — sweep both up now.
      runLoop(serverPeer)

      // Pre-stage the "tools/list" response the next `call()` (id 2) will
      // read.
      stage(serverPeer, box, reqText(2i64, "tools/list", None))
      match listTools(client) {
        case Err(e) -> assertTrue(false, "listTools failed: " + e)
        case Ok(tools) -> {
          assertEqualInt(tools.count, 3, "three tools registered")
          assertEqual(tools[0].name, "echo", "first tool name")
        }
      }
    }
  }
}
