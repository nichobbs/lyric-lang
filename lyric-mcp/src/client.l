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
//! Sampling/elicitation (server -> client requests) are out of scope —
//! `2026-07-28` deprecates both outright (docs/64 §1), so this is now moot
//! rather than merely deferred — so the peer's `RpcHandler` is a
//! `NullHandler` that refuses any inbound request and ignores inbound
//! notifications.
@runtime_checked
package Mcp.Client

import Std.Core
import Std.Collections
import JsonRpc.Json
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
  match call(client.peer, "server/discover", None) {
    case Ok(v) -> {
      val discovered = decodeServerDiscoverResult(v)
      client.serverInfo = discovered.serverInfo
      Ok(value = discovered)
    }
    case Err(e) -> Err(error = "'server/discover' failed: " + e.message)
  }
}

@stable(since = "0.1")
pub func listTools(client: inout McpClient): Result[List[McpToolInfo], String] {
  match call(client.peer, "tools/list", None) {
    case Ok(v) -> Ok(value = decodeToolInfoList(v))
    case Err(e) -> Err(error = "'tools/list' failed: " + e.message)
  }
}

// #6334 — a resumable tool (registered via `addResumableTool`) can answer
// `tools/call` with an `input_required` object instead of a plain result,
// indistinguishable from a normal tool at the wire level until the
// response itself arrives. `decodeToolResult` has no concept of
// `resultType` and (following this file's own lenient-decoder pattern)
// would silently default `content`/`isError` to an empty success — a
// dangerous false-success for a permission-gated tool. Detect the
// `input_required` shape here and surface it as an explicit `Err` instead
// of ever reaching `decodeToolResult` with it.
@stable(since = "0.1")
pub func callTool(client: inout McpClient, name: in String, args: in Option[JsonValue]): Result[McpToolResult, String] {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "name", value = JString(value = name)))
  match args {
    case Some(a) -> fields.add(JsonField(name = "arguments", value = a))
    case None -> ()
  }
  match call(client.peer, "tools/call", Some(value = JObject(fields = fields))) {
    case Ok(v) -> {
      match getString(v, "resultType") {
        case Some(rt) -> {
          if rt == "input_required" {
            Err(
              error = "'" + name +
                "' is a resumable tool waiting for more input (resultType: input_required) — call it with Mcp.Client.callResumableTool/resumeToolCall instead of callTool"
            )
          } else {
            Ok(value = decodeToolResult(v))
          }
        }
        case None -> Ok(value = decodeToolResult(v))
      }
    }
    case Err(e) -> Err(error = "'tools/call' failed: " + e.message)
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
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "name", value = JString(value = name)))
  match args {
    case Some(a) -> fields.add(JsonField(name = "arguments", value = a))
    case None -> ()
  }
  match call(client.peer, "tools/call", Some(value = JObject(fields = fields))) {
    case Ok(v) -> Ok(value = decodeToolCallOutcome(v))
    case Err(e) -> Err(error = "'tools/call' failed: " + e.message)
  }
}

/// Answer a prior `InputRequired` outcome by reissuing `tools/call` with
/// the echoed `requestState` and the caller's `inputResponses` (docs/64
/// §3.1). May itself answer with another `InputRequired` outcome if the
/// tool needs a further round trip.
@stable(since = "0.2")
pub func resumeToolCall(
  client: inout McpClient, name: in String, requestState: in String, inputResponses: in JsonValue
): Result[McpToolCallOutcome, String] {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "name", value = JString(value = name)))
  fields.add(JsonField(name = "requestState", value = JString(value = requestState)))
  fields.add(JsonField(name = "inputResponses", value = inputResponses))
  match call(client.peer, "tools/call", Some(value = JObject(fields = fields))) {
    case Ok(v) -> Ok(value = decodeToolCallOutcome(v))
    case Err(e) -> Err(error = "'tools/call' failed: " + e.message)
  }
}

@stable(since = "0.1")
pub func listResources(client: inout McpClient): Result[List[McpResourceInfo], String] {
  match call(client.peer, "resources/list", None) {
    case Ok(v) -> Ok(value = decodeResourceInfoList(v))
    case Err(e) -> Err(error = "'resources/list' failed: " + e.message)
  }
}

@stable(since = "0.1")
pub func readResource(client: inout McpClient, uri: in String): Result[McpResourceContent, String] {
  val params = JObject(fields = [JsonField(name = "uri", value = JString(value = uri))])
  match call(client.peer, "resources/read", Some(value = params)) {
    case Ok(v) -> match getArray(v, "contents") { case None -> Err(error = "'resources/read' response missing 'contents'"); case Some(items) -> { if items.count == 0 { Err(error = "'resources/read' response has an empty 'contents' array") } else { Ok(value = decodeResourceContent(items[0])) } } }
    case Err(e) -> Err(error = "'resources/read' failed: " + e.message)
  }
}

@stable(since = "0.1")
pub func listPrompts(client: inout McpClient): Result[List[McpPromptInfo], String] {
  match call(client.peer, "prompts/list", None) {
    case Ok(v) -> Ok(value = decodePromptInfoList(v))
    case Err(e) -> Err(error = "'prompts/list' failed: " + e.message)
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
  match call(client.peer, "prompts/get", Some(value = JObject(fields = fields))) {
    case Ok(v) -> Ok(value = decodePromptResult(v))
    case Err(e) -> Err(error = "'prompts/get' failed: " + e.message)
  }
}

@stable(since = "0.1")
pub func ping(client: inout McpClient): Result[Unit, String] {
  match call(client.peer, "ping", None) {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "'ping' failed: " + e.message)
  }
}

/// Close the underlying transport (kills the child process; see
/// `Mcp.Stdio.PipedNdjsonTransport.close`).
@stable(since = "0.1")
pub func disconnect(client: in McpClient): Unit {
  closePeer(client.peer)
}
