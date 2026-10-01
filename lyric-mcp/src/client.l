//! src/client.l — Mcp.Client: MCP client surface (docs/62-jsonrpc-mcp.md §5.2,
//! docs/64-mcp-2026-stateless-migration.md §3.3).
//!
//! **Stateless core (docs/64 §3.3)**: `connectStdio`/`connectTransport` no
//! longer perform any handshake — wrapping a transport is a pure local
//! operation. Call `discoverServer` afterward (recommended, not required)
//! to fetch `serverInfo` via `server/discover`. Every other operation
//! (`listTools`, `callTool`, ...) is a thin `JsonRpc.call` wrapper that
//! encodes params with `Mcp`'s encoders and decodes the result with
//! `Mcp`'s decoders. `callResumableTool`/`resumeToolCall` drive the
//! `input_required` multi-round-trip pattern (docs/64 §3.1) against a
//! resumable tool.
//!
//! **Deadlines (#7451).** Every operation waits for its response for at
//! most the client's call timeout — `JsonRpc.defaultCallTimeoutMs` (60 s)
//! unless changed with `setClientCallTimeout` — and fails with a message
//! naming the timeout when the server does not answer in time. The
//! tool-call operations, which a slow tool can legitimately stretch, also
//! come in `...Within` forms taking a per-call timeout. A response that
//! arrives after its call timed out is discarded when it is later read.
//!
//! Sampling/elicitation (server -> client requests) are out of scope —
//! `2026-07-28` deprecates both outright (docs/64 §1), so this is now moot
//! rather than merely deferred — so the peer's `RpcHandler` is a
//! `NullHandler` that refuses any inbound request and ignores inbound
//! notifications.
@runtime_checked
@io
package Mcp.Client

import Std.Core
import Std.Collections
import Std.JsonValue
import JsonRpc
import Mcp
import Mcp.Stdio

// Literal, not `JsonRpc.methodNotFound` — see server.l's `invalidParamsCode`/
// `methodNotFoundCode` for why: a package-level `pub val Int` read from a
// workspace-restored cross-DLL dependency (`JsonRpc`) silently evaluates to
// `0` at runtime with no compile- or run-time error. JSON-RPC 2.0's
// standard codes are fixed by spec, so hardcoding is safe.
val clientMethodNotFoundCode: Int = 0 - 32601

// ── Inbound handler (client receives no requests in v1) ────────────────────
record NullHandler {
}

impl RpcHandler for NullHandler {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    Err(
      error = RpcError(
        code = clientMethodNotFoundCode,
        message = "client does not handle inbound requests: " + method,
        data = None
      )
    )
  }

  func onNotification(method: in String, params: in Option[JsonValue]): Unit {
  }
}

val unknownServerInfo: McpImplementation = McpImplementation(name = "", version = "")

// ── Client ───────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record McpClient {
  var peer: RpcPeer
  var serverInfo: McpImplementation
}

/// Wrap an already-constructed transport in an `McpClient`. Stateless core
/// (docs/64 §3.3): this is now a pure local operation — no handshake, no
/// round trip, cannot fail on its own (still `Result`-returning for
/// signature stability with `connectStdio`, which can fail on spawn).
/// `serverInfo` starts empty; call `discoverServer` to populate it.
@stable(since = "0.1")
pub func connectTransport(transport: in RpcTransport): Result[McpClient, String] {
  val peer = newPeer(transport, NullHandler())
  Ok(value = McpClient(peer = peer, serverInfo = unknownServerInfo))
}

/// Spawn `command args...` and connect its piped stdin/stdout as the MCP
/// stdio transport (`Mcp.Stdio.newPipedNdjsonTransport`). No handshake is
/// performed — see `connectTransport`.
@stable(since = "0.1")
pub func connectStdio(command: in String, args: in List[String]): Result[McpClient, String] {
  match newPipedNdjsonTransport(command, args) {
    case Err(e) -> Err(error = "failed to spawn '" + command + "': " + e)
    case Ok(transport) -> connectTransport(transport)
  }
}

/// Change the deadline every later operation on this client waits for its
/// response, in milliseconds (1 ms to 24 hours).
@stable(since = "0.2")
pub func setClientCallTimeout(client: inout McpClient, timeoutMs: in Int): Unit
  requires: isValidCallTimeout(timeoutMs)
{
  setCallTimeout(client.peer, timeoutMs)
}

// Every operation's JSON-RPC round trip, under the client's call timeout.
// The failure text names the method and, for a timeout, says so.
func request(client: inout McpClient, method: in String, params: in Option[JsonValue]): Result[JsonValue, String] {
  requestWithin(client, method, params, client.peer.callTimeoutMs)
}

// `callWithin` queues any server-sent request/notification it sees while
// waiting for this call's own response (`JsonRpc`'s "Dispatch model" doc);
// `Mcp.Client` never runs `runLoop`, so every operation drains that queue
// itself right after its `callWithin` returns (#7520 review) — otherwise queued
// entries accumulate across calls toward `maxPendingMessages` and every
// later call starts failing. `NullHandler` answers a queued request with
// the standard `-32601 Method not found` and drops a queued notification
// (see `NullHandler`'s own doc and `JsonRpc.drainPendingQueue`). The drain
// result itself is best-effort here: a transport failure surfaces on this
// or a later call's own `callWithin` regardless, so it must not shadow the
// result this call already obtained.
func requestWithin(
  client: inout McpClient, method: in String, params: in Option[JsonValue], timeoutMs: in Int
): Result[JsonValue, String] {
  val result = callWithin(client.peer, method, params, timeoutMs)
  val _: Result[Unit, String] = drainPendingQueue(client.peer)
  match result {
    case Ok(v) -> Ok(value = v)
    case Err(e) -> Err(error = "'" + method + "' failed: " + e.message)
  }
}

/// Fetch the server's identity and capability summary via `server/discover`,
/// record `serverInfo` on `client.serverInfo`, and return the full result
/// (`serverInfo` + `capabilities`) so a caller can inspect which of
/// `tools`/`resources`/`prompts` the server advertises. Optional (docs/64
/// §3.3) — every other `Mcp.Client` function works without ever calling
/// this — but recommended before the first `listTools`/`callTool` if the
/// caller wants to display or log which server it is talking to, or branch
/// on capabilities before calling tools/resources/prompts.
@stable(since = "0.2")
pub func discoverServer(client: inout McpClient): Result[McpDiscoverResult, String] {
  match request(client, "server/discover", None) {
    case Ok(v) -> {
      val discovered = decodeServerDiscoverResult(v)
      client.serverInfo = discovered.serverInfo
      Ok(value = discovered)
    }
    case Err(e) -> Err(error = e)
  }
}

@stable(since = "0.1")
pub func listTools(client: inout McpClient): Result[List[McpToolInfo], String] {
  match request(client, "tools/list", None) {
    case Ok(v) -> Ok(value = decodeToolInfoList(v))
    case Err(e) -> Err(error = e)
  }
}

// #6334 — a resumable tool (registered via `addResumableTool`) can answer
// `tools/call` with an `input_required` object instead of a plain result,
// indistinguishable from a normal tool at the wire level until the
// response itself arrives. `decodeToolResult` has no concept of
// `resultType` and (following this file's own lenient-decoder pattern)
// would silently default `content`/`isError` to an empty success — a
// dangerous false-success for a permission-gated tool. Decode via
// `decodeToolCallOutcome` (the same decoder `callResumableTool` uses)
// rather than re-deriving the `resultType == "input_required"` check
// here, so the sentinel string lives in exactly one place.
@stable(since = "0.1")
pub func callTool(client: inout McpClient, name: in String, args: in Option[JsonValue]): Result[McpToolResult, String] {
  callToolWithin(client, name, args, client.peer.callTimeoutMs)
}

/// `callTool`, waiting at most `timeoutMs` milliseconds for the result
/// instead of the client's call timeout.
@stable(since = "0.2")
pub func callToolWithin(
  client: inout McpClient, name: in String, args: in Option[JsonValue], timeoutMs: in Int
): Result[McpToolResult, String]
  requires: isValidCallTimeout(timeoutMs)
{
  match requestWithin(client, "tools/call", Some(value = toolCallParams(name, args)), timeoutMs) {
    case Ok(v) -> {
      match decodeToolCallOutcome(v) {
        case Err(e) -> Err(error = "'tools/call' returned a malformed result: " + e)
        case Ok(outcome) -> match outcome {
          case ToolResult(result) -> Ok(value = result)
          case InputRequired(_) -> Err(
            error = "'" + name +
              "' is a resumable tool waiting for more input (resultType: input_required) — call it with Mcp.Client.callResumableTool/resumeToolCall instead of callTool"
          )
        }
      }
    }
    case Err(e) -> Err(error = e)
  }
}

func toolCallParams(name: in String, args: in Option[JsonValue]): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "name", value = JString(value = name)))
  match args {
    case Some(a) -> fields.add(JsonField(name = "arguments", value = a))
    case None -> ()
  }
  JObject(fields = fields)
}

func decodeOutcome(response: in Result[JsonValue, String]): Result[McpToolCallOutcome, String] {
  match response {
    case Ok(v) -> match decodeToolCallOutcome(v) {
      case Ok(outcome) -> Ok(value = outcome)
      case Err(e) -> Err(error = "'tools/call' returned a malformed result: " + e)
    }
    case Err(e) -> Err(error = e)
  }
}

/// Call a resumable tool's initial `tools/call` and decode whichever shape
/// it answers with — a finished `ToolResult` or an `InputRequired` request
/// for more input (docs/64 §3.1). Use `resumeToolCall` to answer an
/// `InputRequired` outcome.
@stable(since = "0.2")
pub func callResumableTool(
  client: inout McpClient, name: in String, args: in Option[JsonValue]
): Result[McpToolCallOutcome, String] {
  callResumableToolWithin(client, name, args, client.peer.callTimeoutMs)
}

/// `callResumableTool`, waiting at most `timeoutMs` milliseconds.
@stable(since = "0.2")
pub func callResumableToolWithin(
  client: inout McpClient, name: in String, args: in Option[JsonValue], timeoutMs: in Int
): Result[McpToolCallOutcome, String]
  requires: isValidCallTimeout(timeoutMs)
{
  decodeOutcome(requestWithin(client, "tools/call", Some(value = toolCallParams(name, args)), timeoutMs))
}

/// Answer a prior `InputRequired` outcome by reissuing `tools/call` with
/// the echoed `requestState` and the caller's `inputResponses` (docs/64
/// §3.1). May itself answer with another `InputRequired` outcome if the
/// tool needs a further round trip.
@stable(since = "0.2")
pub func resumeToolCall(
  client: inout McpClient, name: in String, requestState: in String, inputResponses: in JsonValue
): Result[McpToolCallOutcome, String] {
  resumeToolCallWithin(client, name, requestState, inputResponses, client.peer.callTimeoutMs)
}

/// `resumeToolCall`, waiting at most `timeoutMs` milliseconds.
@stable(since = "0.2")
pub func resumeToolCallWithin(
  client: inout McpClient,
  name: in String,
  requestState: in String,
  inputResponses: in JsonValue,
  timeoutMs: in Int,
): Result[McpToolCallOutcome, String]
  requires: isValidCallTimeout(timeoutMs)
{
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "name", value = JString(value = name)))
  fields.add(JsonField(name = "requestState", value = JString(value = requestState)))
  fields.add(JsonField(name = "inputResponses", value = inputResponses))
  decodeOutcome(requestWithin(client, "tools/call", Some(value = JObject(fields = fields)), timeoutMs))
}

@stable(since = "0.1")
pub func listResources(client: inout McpClient): Result[List[McpResourceInfo], String] {
  match request(client, "resources/list", None) {
    case Ok(v) -> Ok(value = decodeResourceInfoList(v))
    case Err(e) -> Err(error = e)
  }
}

@stable(since = "0.1")
pub func readResource(client: inout McpClient, uri: in String): Result[McpResourceContent, String] {
  val params = JObject(fields = [JsonField(name = "uri", value = JString(value = uri))])
  match request(client, "resources/read", Some(value = params)) {
    case Ok(v) -> match getArray(v, "contents") {
      case None -> Err(error = "'resources/read' response missing 'contents'")
      case Some(items) -> {
        if items.count == 0 {
          Err(error = "'resources/read' response has an empty 'contents' array")
        } else {
          Ok(value = decodeResourceContent(items[0]))
        }
      }
    }
    case Err(e) -> Err(error = e)
  }
}

@stable(since = "0.1")
pub func listPrompts(client: inout McpClient): Result[List[McpPromptInfo], String] {
  match request(client, "prompts/list", None) {
    case Ok(v) -> Ok(value = decodePromptInfoList(v))
    case Err(e) -> Err(error = e)
  }
}

@stable(since = "0.1")
pub func getPrompt(
  client: inout McpClient, name: in String, args: in Option[JsonValue]
): Result[McpPromptResult, String] {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "name", value = JString(value = name)))
  match args {
    case Some(a) -> fields.add(JsonField(name = "arguments", value = a))
    case None -> ()
  }
  match request(client, "prompts/get", Some(value = JObject(fields = fields))) {
    case Ok(v) -> Ok(value = decodePromptResult(v))
    case Err(e) -> Err(error = e)
  }
}

@stable(since = "0.1")
pub func ping(client: inout McpClient): Result[Unit, String] {
  match request(client, "ping", None) {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = e)
  }
}

/// Close the underlying transport (kills the child process; see
/// `Mcp.Stdio.PipedNdjsonTransport.close`).
@stable(since = "0.1")
pub func disconnect(client: in McpClient): Unit {
  closePeer(client.peer)
}
