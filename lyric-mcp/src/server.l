//! src/server.l — Mcp.Server: MCP server surface (docs/62-jsonrpc-mcp.md §5.1).
//!
//! `McpServer` implements `JsonRpc.RpcHandler` directly (rather than
//! wrapping a separate handler record) and is handed straight to
//! `JsonRpc.newPeer`. Lifecycle: `initialize` is always accepted (subject
//! to protocol-version negotiation, `Mcp.negotiateProtocolVersion`); every
//! other request is rejected with `Mcp.serverNotInitialized` until the
//! client's `notifications/initialized` notification has been received —
//! see `onNotification` below.
//!
//! Capability derivation (docs/62 §5.1): the `InitializeResult`'s
//! `capabilities` object includes a `tools`/`resources`/`prompts` entry
//! (each `{"listChanged": false}` — v1 never sends list-changed
//! notifications) only when at least one tool/resource/prompt was
//! registered via `addTool`/`addResource`/`addPrompt` before `serveStdio`
//! starts the loop.
@runtime_checked
package Mcp.Server

import Std.Core
import Std.Collections
import JsonRpc.Json
import JsonRpc
import JsonRpc.Stdio
import Mcp

// Same-package accessors standing in for two real, distinct self-hosted
// `--target dotnet` bugs found while building this library (both filed
// upstream against the compiler, not this library's own logic):
//
// 1. A package-qualified constant reference (`Mcp.serverNotInitialized`,
//    `JsonRpc.invalidParams`, `JsonRpc.methodNotFound`) used *textually
//    inside an `impl ... for McpServer { }` block* reproducibly crashed
//    the whole type's JIT verification (`System.InvalidProgramException`,
//    surfaced by `JsonRpc.dispatchRequest`'s `catch Bug` as `-32603
//    Internal error` on *every* request, even ones whose handling never
//    reached the qualified reference) — isolated in a from-scratch
//    two-file minimal repro by bisecting `onRequest` piece by piece; a
//    same-shape `impl` block using bare `Int` literals instead of
//    qualified constants, and a plain top-level `func` using the exact
//    same qualified references outside any `impl` block, both work fine.
//    Routing every reference through a same-package (unqualified) `func`
//    avoids it (`notInitializedCode()` below, called from `onRequest`).
//
// 2. Separately — and this is the reason `invalidParamsCode()` /
//    `methodNotFoundCode()` below return *literal* `Int`s rather than
//    reading `JsonRpc.invalidParams` / `JsonRpc.methodNotFound` the same
//    way `notInitializedCode()` reads `Mcp.serverNotInitialized` — a
//    package-level `pub val Int` read from a *workspace-restored
//    cross-DLL dependency* (`JsonRpc`, a separately-published/restored
//    package, unlike `Mcp` which is compiled together with `Mcp.Server`
//    in the same project) silently evaluates to `0` at runtime instead of
//    its real value, with **no compile-time or run-time error at all** —
//    confirmed by direct experiment: `handleToolsCall`'s "unknown tool"
//    branch measurably produced a wire response with `"code":0` instead
//    of `-32602` until this literal-`Int` workaround was applied.
//    `Mcp.serverNotInitialized` (same-project sibling package, not a
//    restored DLL) does not exhibit this — only the cross-DLL case does.
//    JSON-RPC 2.0's standard error codes are a fixed part of the spec
//    (never going to change), so hardcoding them here is safe; `Mcp`'s
//    own `serverNotInitialized` (an MCP-specific, not JSON-RPC-standard,
//    code) still reads from its real source since that path is unaffected.
func notInitializedCode(): Int {
  Mcp.serverNotInitialized
}

func invalidParamsCode(): Int {
  0 - 32602
}

func methodNotFoundCode(): Int {
  0 - 32601
}

// ── Builder ──────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record McpServer {
  info: McpImplementation
  var tools: List[McpToolDef]
  var resources: List[McpResourceDef]
  var prompts: List[McpPromptDef]
  // Set once `notifications/initialized` is received (see `onNotification`).
  // Every request other than `initialize` is rejected with
  // `Mcp.serverNotInitialized` while this is `false`.
  var ready: Bool
}

/// Construct an empty server. Register tools/resources/prompts with
/// `addTool`/`addResource`/`addPrompt` before calling `serveStdio`.
@stable(since = "0.1")
pub func newServer(info: in McpImplementation): McpServer {
  McpServer(info = info, tools = newList(), resources = newList(), prompts = newList(), ready = false)
}

/// Register a tool, reachable via `tools/list` / `tools/call` once the
/// server starts serving.
@stable(since = "0.1")
pub func addTool(server: in McpServer, tool: in McpToolDef): Unit {
  server.tools.add(tool)
}

/// Register a resource, reachable via `resources/list` / `resources/read`.
@stable(since = "0.1")
pub func addResource(server: in McpServer, resource: in McpResourceDef): Unit {
  server.resources.add(resource)
}

/// Register a prompt, reachable via `prompts/list` / `prompts/get`.
@stable(since = "0.1")
pub func addPrompt(server: in McpServer, prompt: in McpPromptDef): Unit {
  server.prompts.add(prompt)
}

// ── Lookup helpers (explicit, non-generic — see lyric-jsonrpc/README.md
// "Known upstream issues" #5 for why this library avoids a shared generic
// `find[T]` helper called with several different concrete type arguments) ──
func findTool(tools: in List[McpToolDef], name: in String): Option[McpToolDef] {
  var i = 0
  var found: Option[McpToolDef] = None
  while i < tools.count {
    if tools[i].name == name {
      found = Some(value = tools[i])
    }
    i = i + 1
  }
  found
}

func findResource(resources: in List[McpResourceDef], uri: in String): Option[McpResourceDef] {
  var i = 0
  var found: Option[McpResourceDef] = None
  while i < resources.count {
    if resources[i].uri == uri {
      found = Some(value = resources[i])
    }
    i = i + 1
  }
  found
}

func findPrompt(prompts: in List[McpPromptDef], name: in String): Option[McpPromptDef] {
  var i = 0
  var found: Option[McpPromptDef] = None
  while i < prompts.count {
    if prompts[i].name == name {
      found = Some(value = prompts[i])
    }
    i = i + 1
  }
  found
}

// ── Per-method handlers ─────────────────────────────────────────────────────
func handleInitialize(server: in McpServer, paramsOpt: in Option[JsonValue]): Result[JsonValue, RpcError] {
  match decodeInitializeParams(paramsOpt) {
    case None -> Err(error = RpcError(code = invalidParamsCode(), message = "invalid params: 'initialize' requires a string 'protocolVersion'", data = None))
    case Some(initParams) -> {
      val negotiated = negotiateProtocolVersion(initParams.protocolVersion)
      Ok(
        value = encodeInitializeResult(
          negotiated,
          server.tools.count > 0,
          server.resources.count > 0,
          server.prompts.count > 0,
          server.info
        )
      )
    }
  }
}

func handleToolsList(server: in McpServer): Result[JsonValue, RpcError] {
  Ok(value = JObject(fields = [JsonField(name = "tools", value = encodeToolDefList(server.tools))]))
}

func handleToolsCall(server: in McpServer, paramsOpt: in Option[JsonValue]): Result[JsonValue, RpcError] {
  match paramsOpt {
    case None -> Err(error = RpcError(code = invalidParamsCode(), message = "invalid params: 'tools/call' requires {name}", data = None))
    case Some(p) -> match getString(p, "name") {
      case None -> Err(error = RpcError(code = invalidParamsCode(), message = "invalid params: 'tools/call' requires a string 'name'", data = None))
      case Some(toolName) -> {
        val argsOpt = getField(p, "arguments")
        match findTool(server.tools, toolName) {
          case None -> Err(error = RpcError(code = invalidParamsCode(), message = "unknown tool: '" + toolName + "'", data = None))
          case Some(def) -> {
            // Per docs/62 §5.1: a tool-execution failure — whether returned
            // as `Err` or raised as a panic — is reported as a successful
            // `CallToolResult` with `isError: true`, never a protocol
            // error.
            val outcome: Result[McpToolResult, String] = try {
              def.handler.call(argsOpt)
            } catch Bug as b {
              Err(error = "tool '" + toolName + "' panicked: " + b.message)
            }
            match outcome {
              case Ok(result) -> Ok(value = encodeToolResult(result))
              case Err(msg) -> Ok(value = encodeToolResult(toolErrorResult(msg)))
            }
          }
        }
      }
    }
  }
}

func handleResourcesList(server: in McpServer): Result[JsonValue, RpcError] {
  Ok(value = JObject(fields = [JsonField(name = "resources", value = encodeResourceDefList(server.resources))]))
}

func handleResourcesRead(server: in McpServer, paramsOpt: in Option[JsonValue]): Result[JsonValue, RpcError] {
  match paramsOpt {
    case None -> Err(error = RpcError(code = invalidParamsCode(), message = "invalid params: 'resources/read' requires {uri}", data = None))
    case Some(p) -> match getString(p, "uri") {
      case None -> Err(error = RpcError(code = invalidParamsCode(), message = "invalid params: 'resources/read' requires a string 'uri'", data = None))
      case Some(uri) -> match findResource(server.resources, uri) {
        case None -> Err(error = RpcError(code = invalidParamsCode(), message = "unknown resource: '" + uri + "'", data = None))
        case Some(def) -> {
          // Unlike tools, a resource-read failure IS a protocol error —
          // there is no `isError` result shape for resources in the spec.
          val outcome: Result[McpResourceContent, String] = try {
            def.handler.read(uri)
          } catch Bug as b {
            Err(error = "resource '" + uri + "' handler panicked: " + b.message)
          }
          match outcome {
            case Ok(content) -> Ok(value = JObject(fields = [JsonField(name = "contents", value = JArray(items = [encodeResourceContent(content)]))]))
            case Err(msg) -> Err(error = RpcError(code = invalidParamsCode(), message = msg, data = None))
          }
        }
      }
    }
  }
}

func handlePromptsList(server: in McpServer): Result[JsonValue, RpcError] {
  Ok(value = JObject(fields = [JsonField(name = "prompts", value = encodePromptDefList(server.prompts))]))
}

func handlePromptsGet(server: in McpServer, paramsOpt: in Option[JsonValue]): Result[JsonValue, RpcError] {
  match paramsOpt {
    case None -> Err(error = RpcError(code = invalidParamsCode(), message = "invalid params: 'prompts/get' requires {name}", data = None))
    case Some(p) -> match getString(p, "name") {
      case None -> Err(error = RpcError(code = invalidParamsCode(), message = "invalid params: 'prompts/get' requires a string 'name'", data = None))
      case Some(name) -> {
        val argsOpt = getField(p, "arguments")
        match findPrompt(server.prompts, name) {
          case None -> Err(error = RpcError(code = invalidParamsCode(), message = "unknown prompt: '" + name + "'", data = None))
          case Some(def) -> {
            // Like resources: `Err` is a protocol error, not an isError result.
            val outcome: Result[McpPromptResult, String] = try {
              def.handler.get(argsOpt)
            } catch Bug as b {
              Err(error = "prompt '" + name + "' handler panicked: " + b.message)
            }
            match outcome {
              case Ok(result) -> Ok(value = encodePromptResult(result))
              case Err(msg) -> Err(error = RpcError(code = invalidParamsCode(), message = msg, data = None))
            }
          }
        }
      }
    }
  }
}

// ── RpcHandler ───────────────────────────────────────────────────────────────
impl RpcHandler for McpServer {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    if not self.ready and method != "initialize" {
      Err(
        error = RpcError(
          code = notInitializedCode(),
          message = "server not initialized: 'initialize' and its follow-up 'notifications/initialized' must complete before other requests",
          data = None
        )
      )
    } else if method == "initialize" {
      handleInitialize(self, params)
    } else if method == "ping" {
      Ok(value = JObject(fields = newList()))
    } else if method == "tools/list" {
      handleToolsList(self)
    } else if method == "tools/call" {
      handleToolsCall(self, params)
    } else if method == "resources/list" {
      handleResourcesList(self)
    } else if method == "resources/read" {
      handleResourcesRead(self, params)
    } else if method == "prompts/list" {
      handlePromptsList(self)
    } else if method == "prompts/get" {
      handlePromptsGet(self, params)
    } else {
      Err(error = RpcError(code = methodNotFoundCode(), message = "method not found: " + method, data = None))
    }
  }

  func onNotification(method: in String, params: in Option[JsonValue]): Unit {
    if method == "notifications/initialized" {
      self.ready = true
    }
  }
}

// ── Transport entry point ───────────────────────────────────────────────────
/// Serve `server` over the MCP stdio transport (NDJSON-framed JSON-RPC over
/// stdin/stdout). Blocks until the peer disconnects (clean EOF) or a
/// transport-level failure occurs.
@stable(since = "0.1")
pub func serveStdio(server: in McpServer): Result[Unit, String] {
  val transport = newNdjsonTransport()
  var peer = newPeer(transport, server)
  runLoop(peer)
}
