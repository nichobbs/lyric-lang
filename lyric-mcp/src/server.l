//! src/server.l — Mcp.Server: MCP server surface (docs/62-jsonrpc-mcp.md §5.1,
//! docs/64-mcp-2026-stateless-migration.md §3.2).
//!
//! `McpServer` implements `JsonRpc.RpcHandler` directly (rather than
//! wrapping a separate handler record) and is handed straight to
//! `JsonRpc.newPeer`. **Stateless core (docs/64 §3.2)**: there is no more
//! readiness gate — every request is answerable immediately, with no
//! `initialize`/`notifications/initialized` handshake required first.
//! `initialize` remains an answerable method purely for legacy-peer
//! tolerance (subject to protocol-version negotiation,
//! `Mcp.negotiateProtocolVersion`) — it just no longer *does* anything a
//! peer must wait for. `server/discover` is the stateless replacement for
//! capability discovery.
//!
//! Capability derivation (docs/62 §5.1): the `capabilities` object (in
//! both `initialize` and `server/discover` results) includes a
//! `tools`/`resources`/`prompts` entry (each `{"listChanged": false}` — v1
//! never sends list-changed notifications) only when at least one
//! tool/resource/prompt was registered via
//! `addTool`/`addResumableTool`/`addResource`/`addPrompt` before
//! `serveStdio` starts the loop.
@runtime_checked
package Mcp.Server

import Std.Core
import Std.Collections
import JsonRpc.Json
import JsonRpc
import JsonRpc.Stdio
import Mcp

// Same-package accessors standing in for a real self-hosted `--target
// dotnet` compiler bug found while building this library (filed upstream
// against the compiler, not this library's own logic): a package-level
// `pub val Int` read from a *workspace-restored cross-DLL dependency*
// (`JsonRpc`, a separately-published/restored package, unlike `Mcp` which
// is compiled together with `Mcp.Server` in the same project) silently
// evaluates to `0` at runtime instead of its real value, with **no
// compile-time or run-time error at all** — confirmed by direct
// experiment: `handleToolsCall`'s "unknown tool" branch measurably
// produced a wire response with `"code":0` instead of `-32602` until this
// literal-`Int` workaround was applied. JSON-RPC 2.0's standard error
// codes are a fixed part of the spec (never going to change), so
// hardcoding them here is safe.
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
  var resumableTools: List[McpResumableToolDef]
  var resources: List[McpResourceDef]
  var prompts: List[McpPromptDef]
}

/// Construct an empty server. Register tools/resources/prompts with
/// `addTool`/`addResumableTool`/`addResource`/`addPrompt` before calling
/// `serveStdio`. Stateless core (docs/64 §3.2): there is no more
/// `ready`/handshake state to initialize here — every request the server
/// can answer, it can answer starting from the very first message.
@stable(since = "0.1")
pub func newServer(info: in McpImplementation): McpServer {
  McpServer(info = info, tools = newList(), resumableTools = newList(), resources = newList(), prompts = newList())
}

/// Register a tool, reachable via `tools/list` / `tools/call` once the
/// server starts serving. A tool name registers with `addTool` or
/// `addResumableTool`, not both — there is no registration-time diagnostic
/// against double-registering a name, and both `handleToolsCall` dispatch
/// and `tools/list` (`Mcp.encodeAllToolDefsList`) resolve a same-named
/// double-registration to the resumable definition alone, never a
/// duplicate `tools/list` entry.
@stable(since = "0.1")
pub func addTool(server: in McpServer, tool: in McpToolDef): Unit {
  server.tools.add(tool)
}

/// Register a resumable tool — one that may answer `tools/call` with an
/// `input_required` result instead of finishing in one round trip (docs/64
/// §3.1/§3.2). Additive: registering a resumable tool never requires
/// changing any plain `addTool` registration elsewhere. Takes precedence
/// over a same-named plain `addTool` registration — see `addTool`'s doc
/// comment.
@stable(since = "0.2")
pub func addResumableTool(server: in McpServer, tool: in McpResumableToolDef): Unit {
  server.resumableTools.add(tool)
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

func findResumableTool(tools: in List[McpResumableToolDef], name: in String): Option[McpResumableToolDef] {
  var i = 0
  var found: Option[McpResumableToolDef] = None
  while i < tools.count {
    if tools[i].name == name {
      found = Some(value = tools[i])
    }
    i = i + 1
  }
  found
}

func hasAnyTools(server: in McpServer): Bool {
  server.tools.count > 0 or server.resumableTools.count > 0
}

// ── Per-method handlers ─────────────────────────────────────────────────────
// `initialize` remains answerable for legacy-peer tolerance (docs/64 §3.2)
// but no longer gates anything — see `impl RpcHandler for McpServer` below,
// which no longer has a readiness check at all.
func handleInitialize(server: in McpServer, paramsOpt: in Option[JsonValue]): Result[JsonValue, RpcError] {
  match decodeInitializeParams(paramsOpt) {
    case None -> Err(error = RpcError(code = invalidParamsCode(), message = "invalid params: 'initialize' requires a string 'protocolVersion'", data = None))
    case Some(initParams) -> {
      val negotiated = negotiateProtocolVersion(initParams.protocolVersion)
      Ok(
        value = encodeInitializeResult(
          negotiated,
          hasAnyTools(server),
          server.resources.count > 0,
          server.prompts.count > 0,
          server.info
        )
      )
    }
  }
}

func handleServerDiscover(server: in McpServer): Result[JsonValue, RpcError] {
  Ok(
    value = encodeServerDiscoverResult(
      hasAnyTools(server),
      server.resources.count > 0,
      server.prompts.count > 0,
      server.info
    )
  )
}

func handleToolsList(server: in McpServer): Result[JsonValue, RpcError] {
  Ok(
    value = JObject(
      fields = [JsonField(name = "tools", value = encodeAllToolDefsList(server.tools, server.resumableTools))]
    )
  )
}

// A resumed call is an ordinary `tools/call` whose params additionally
// carry `requestState` (echoing what a prior `InputRequired` outcome
// issued) and `inputResponses` (docs/64 §3.1/§3.4 — `JsonRpc` never sees
// the difference, this is purely an `Mcp`-layer data-shape distinction).
func dispatchResumableTool(
  def: in McpResumableToolDef,
  toolName: in String,
  p: in JsonValue,
  argsOpt: in Option[JsonValue],
): Result[JsonValue, RpcError] {
  val outcome: Result[McpToolCallOutcome, String] = match getString(p, "requestState") {
    case Some(state) -> {
      val inputResponses = match getField(p, "inputResponses") {
        case Some(v) -> v
        case None -> JObject(fields = newList())
      }
      try {
        def.handler.resume(state, inputResponses)
      } catch Bug as b {
        Err(error = "tool '" + toolName + "' panicked during resume: " + b.message)
      }
    }
    case None -> try { def.handler.call(argsOpt) } catch Bug as b { Err(error = "tool '" + toolName + "' panicked: " + b.message) }
  }
  match outcome {
    case Ok(result) -> Ok(value = encodeToolCallOutcome(result))
    case Err(msg) -> Ok(value = encodeToolCallOutcome(ToolResult(value = toolErrorResult(msg))))
  }
}

func handleToolsCall(server: in McpServer, paramsOpt: in Option[JsonValue]): Result[JsonValue, RpcError] {
  match paramsOpt {
    case None -> Err(error = RpcError(code = invalidParamsCode(), message = "invalid params: 'tools/call' requires {name}", data = None))
    case Some(p) -> match getString(p, "name") {
      case None -> Err(error = RpcError(code = invalidParamsCode(), message = "invalid params: 'tools/call' requires a string 'name'", data = None))
      case Some(toolName) -> {
        val argsOpt = getField(p, "arguments")
        match findResumableTool(server.resumableTools, toolName) {
          case Some(def) -> dispatchResumableTool(def, toolName, p, argsOpt)
          case None -> match findTool(server.tools, toolName) {
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
  // Stateless core (docs/64 §3.2): no readiness gate. Every method is
  // answerable from the first message the peer sends — `initialize`
  // included, but no longer required before anything else.
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    if method == "initialize" {
      handleInitialize(self, params)
    } else if method == "server/discover" {
      handleServerDiscover(self)
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

  // `notifications/initialized` is accepted (legacy-peer tolerance) but is
  // now a pure no-op — there is no readiness state left to flip.
  func onNotification(method: in String, params: in Option[JsonValue]): Unit {
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
