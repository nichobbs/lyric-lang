//! src/client.l — Mcp.Client: MCP client surface (docs/62-jsonrpc-mcp.md §5.2).
//!
//! `connectStdio` spawns the server process over `Std.Process.spawnPiped`
//! (via `Mcp.Stdio.newPipedNdjsonTransport`) and performs the
//! `initialize` / `notifications/initialized` handshake before returning.
//! Every other operation (`listTools`, `callTool`, ...) is a thin
//! `JsonRpc.call` wrapper that encodes params with `Mcp`'s encoders and
//! decodes the result with `Mcp`'s decoders.
//!
//! v1 has no server -> client requests (sampling/elicitation are out of
//! scope per docs/62 §5.3), so the peer's `RpcHandler` is a `NullHandler`
//! that refuses any inbound request and ignores inbound notifications.
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

val clientImplementationName: String = "lyric-mcp"

val clientImplementationVersion: String = "0.1.0"

// ── Client ───────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record McpClient {
  var peer: RpcPeer
  serverInfo: McpImplementation
  protocolVersion: String
}

/// Perform the `initialize` / `notifications/initialized` lifecycle
/// handshake over an already-constructed transport and return the
/// resulting `McpClient`. `connectStdio` is a thin wrapper of this over
/// `Mcp.Stdio.newPipedNdjsonTransport`; exposed directly so tests (and any
/// caller with a non-stdio `RpcTransport`, e.g. a future streamable-HTTP
/// transport) can drive the same handshake without spawning a process.
@stable(since = "0.1")
pub func connectTransport(transport: in RpcTransport): Result[McpClient, String] {
  var peer = newPeer(transport, NullHandler())
  val clientInfo = McpImplementation(name = clientImplementationName, version = clientImplementationVersion)
  match call(peer, "initialize", Some(value = encodeInitializeParams(protocolVersionLatest, clientInfo))) {
    case Err(e) -> Err(error = "'initialize' failed: " + e.message)
    case Ok(resultValue) -> {
      val initResult = decodeInitializeResult(resultValue)
      match notify(peer, "notifications/initialized", None) {
        case Err(e) -> Err(error = "'notifications/initialized' failed: " + e)
        case Ok(_) -> Ok(value = McpClient(peer = peer, serverInfo = initResult.serverInfo, protocolVersion = initResult.protocolVersion))
      }
    }
  }
}

/// Spawn `command args...`, connect its piped stdin/stdout as the MCP
/// stdio transport, and perform the `initialize` / `notifications/initialized`
/// lifecycle handshake before returning.
@stable(since = "0.1")
pub func connectStdio(command: in String, args: in List[String]): Result[McpClient, String] {
  match newPipedNdjsonTransport(command, args) {
    case Err(e) -> Err(error = "failed to spawn '" + command + "': " + e)
    case Ok(transport) -> connectTransport(transport)
  }
}

@stable(since = "0.1")
pub func listTools(client: inout McpClient): Result[List[McpToolInfo], String] {
  match call(client.peer, "tools/list", None) {
    case Ok(v) -> Ok(value = decodeToolInfoList(v))
    case Err(e) -> Err(error = "'tools/list' failed: " + e.message)
  }
}

@stable(since = "0.1")
pub func callTool(client: inout McpClient, name: in String, args: in Option[JsonValue]): Result[McpToolResult, String] {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "name", value = JString(value = name)))
  match args {
    case Some(a) -> fields.add(JsonField(name = "arguments", value = a))
    case None -> ()
  }
  match call(client.peer, "tools/call", Some(value = JObject(fields = fields))) {
    case Ok(v) -> Ok(value = decodeToolResult(v))
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
