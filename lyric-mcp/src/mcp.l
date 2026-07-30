//! src/mcp.l — Mcp: shared types for the Model Context Protocol.
//!
//! Protocol revision 2026-07-28 (primary) with 2025-06-18 accepted during
//! version negotiation — see `negotiateProtocolVersion`. This is the
//! stateless-core revision (docs/64-mcp-2026-stateless-migration.md):
//! there is no more `initialize`/`initialized` lifecycle gate — every
//! request is answerable immediately (`Mcp.Server` still *answers*
//! `initialize` for legacy-peer tolerance, it just no longer requires it
//! before serving anything else). `server/discover` replaces the
//! handshake's capability-discovery role for peers that want it without
//! pinning a version. `McpToolCallOutcome`/`McpResumableToolHandler`
//! implement the `input_required` multi-round-trip pattern that resolves
//! docs/62's Q-MCP-002 (long-blocking permission-prompt tools) — the
//! reason this library exists per docs/62 §1.
//!
//! Everything both `Mcp.Server` and `Mcp.Client` need lives here: protocol
//! constants, content blocks, tool/resource/prompt wire shapes, and the
//! JSON encode/decode helpers for every MCP message shape this library
//! implements (docs/62-jsonrpc-mcp.md §5, docs/64 §3).
//!
//! Spec deviation: `McpToolDef`/`McpResourceDef`/`McpPromptDef` carry an
//! interface-typed `handler` field (`McpToolHandler`/`McpResourceHandler`/
//! `McpPromptHandler`), not the function-typed field
//! (`(Option[JsonValue]) -> Result[McpToolResult, String]`) docs/62 §5.1
//! specs. `lyric-jsonrpc/README.md` "Known upstream issues" #3 documents a
//! real self-hosted-compiler bug: a closure stored in a record field (or
//! passed as a function-typed parameter) from a *different* package than
//! the field's declaring package fails at runtime on the JVM backend
//! (`ClassCastException` — a caller-package lambda-adapter class the
//! callee's package fails to downcast). Every application registering a
//! tool/resource/prompt handler necessarily lives in a different package
//! than `Mcp`, so the function-typed field is exactly the buggy shape.
//! Interfaces sidestep it (cross-package `impl` dispatch on a plain
//! interface is unaffected) — the same fix `JsonRpc`'s own
//! `RpcHandler`/`RpcTransport` and `lyric-cache/src/cache.l`'s `Clock`
//! already apply for the identical reason.
@runtime_checked
package Mcp

import Std.Core
import Std.Collections
import JsonRpc.Json

// ── Protocol version ────────────────────────────────────────────────────────
/// This library's primary protocol revision.
@stable(since = "0.2")
pub val protocolVersionLatest: String = "2026-07-28"

/// Older revision accepted during negotiation (the previous primary —
/// `2025-03-26` support was dropped: `2026-07-28`'s stateless core is not
/// wire-compatible with a peer old enough to still need `2025-03-26`).
@stable(since = "0.2")
pub val protocolVersionLegacy: String = "2025-06-18"

@stable(since = "0.1")
pub func isSupportedProtocolVersion(v: in String): Bool {
  v == protocolVersionLatest or v == protocolVersionLegacy
}

/// Negotiate the protocol version an `initialize` response should carry,
/// given the version the peer requested. Echoes the requested version back
/// when this library accepts it (`protocolVersionLatest` or
/// `protocolVersionLegacy`); otherwise responds with `protocolVersionLatest`
/// and refuses the requested one. MCP version negotiation is soft — there
/// is no wire-level error for a mismatch, only a response whose
/// `protocolVersion` does not echo what was requested, which the peer is
/// responsible for noticing and disconnecting on if it cannot continue.
/// Only meaningful for a legacy peer that still sends `initialize` — under
/// `2026-07-28` there is no per-connection version to pin, since there is
/// no more connection lifecycle (docs/64 §3.1).
@stable(since = "0.1")
pub func negotiateProtocolVersion(requested: in String): String {
  if isSupportedProtocolVersion(requested) {
    requested
  } else {
    protocolVersionLatest
  }
}

// ── Implementation info (clientInfo / serverInfo) ───────────────────────────
@stable(since = "0.1")
pub record McpImplementation {
  name: String
  version: String
}

func encodeImplementation(info: in McpImplementation): JsonValue {
  JObject(
    fields = [
      JsonField(name = "name", value = JString(value = info.name)),
      JsonField(name = "version", value = JString(value = info.version))
    ]
  )
}

func decodeImplementation(v: in JsonValue): McpImplementation {
  val name = match getString(v, "name") { case Some(s) -> s; case None -> "" }
  val version = match getString(v, "version") { case Some(s) -> s; case None -> "" }
  McpImplementation(name = name, version = version)
}

// ── Content blocks ──────────────────────────────────────────────────────────
@stable(since = "0.1")
pub union McpContent {
  case TextContent(text: String)
  case ImageContent(dataBase64: String, mimeType: String)
  case EmbeddedResource(uri: String, mimeType: String, text: String)
}

func encodeContent(c: in McpContent): JsonValue {
  match c {
    case TextContent(text) -> JObject(fields = [JsonField(name = "type", value = JString(value = "text")), JsonField(name = "text", value = JString(value = text))])
    case ImageContent(data, mimeType) -> JObject(fields = [JsonField(name = "type", value = JString(value = "image")), JsonField(name = "data", value = JString(value = data)), JsonField(name = "mimeType", value = JString(value = mimeType))])
    case EmbeddedResource(uri, mimeType, text) -> JObject(fields = [JsonField(name = "type", value = JString(value = "resource")), JsonField(name = "resource", value = JObject(fields = [JsonField(name = "uri", value = JString(value = uri)), JsonField(name = "mimeType", value = JString(value = mimeType)), JsonField(name = "text", value = JString(value = text))]))])
  }
}

/// Decode one content block. Unrecognized `"type"` values (a future
/// content kind this library does not yet model, e.g. `"audio"`) decode to
/// `None` rather than failing the whole parse — forward-compatible per the
/// spec's general extensibility stance.
func decodeContent(v: in JsonValue): Option[McpContent] {
  match getString(v, "type") {
    case None -> None
    case Some(kind) -> {
      if kind == "text" {
        match getString(v, "text") {
          case Some(t) -> Some(value = TextContent(text = t))
          case None -> None
        }
      } else if kind == "image" {
        val data = match getString(v, "data") { case Some(s) -> s; case None -> "" }
        val mimeType = match getString(v, "mimeType") { case Some(s) -> s; case None -> "" }
        Some(value = ImageContent(dataBase64 = data, mimeType = mimeType))
      } else if kind == "resource" {
        match getField(v, "resource") {
          case None -> None
          case Some(r) -> {
            val uri = match getString(r, "uri") { case Some(s) -> s; case None -> "" }
            val mimeType = match getString(r, "mimeType") { case Some(s) -> s; case None -> "" }
            val text = match getString(r, "text") { case Some(s) -> s; case None -> "" }
            Some(value = EmbeddedResource(uri = uri, mimeType = mimeType, text = text))
          }
        }
      } else {
        None
      }
    }
  }
}

func encodeContentList(items: in List[McpContent]): JsonValue {
  val acc: List[JsonValue] = newList()
  var i = 0
  while i < items.count {
    acc.add(encodeContent(items[i]))
    i = i + 1
  }
  JArray(items = acc)
}

/// Decode a JSON array of content blocks, silently dropping any element
/// that fails to decode (see `decodeContent`).
func decodeContentList(v: in JsonValue): List[McpContent] {
  val acc: List[McpContent] = newList()
  match asArray(v) {
    case None -> ()
    case Some(items) -> {
      var i = 0
      while i < items.count {
        match decodeContent(items[i]) {
          case Some(c) -> acc.add(c)
          case None -> ()
        }
        i = i + 1
      }
    }
  }
  acc
}

func singleTextContentList(text: in String): List[McpContent] {
  val items: List[McpContent] = newList()
  items.add(TextContent(text = text))
  items
}

// ── Tools ────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record McpToolResult {
  content: List[McpContent]
  isError: Bool
}

/// Build an `isError: true` result carrying a single text block — the
/// shape a tool-execution failure (`McpToolHandler.call` returning `Err`)
/// is reported in, per docs/62 §5.1 ("tool-execution failures are results
/// with `isError: true`, not protocol errors").
@stable(since = "0.1")
pub func toolErrorResult(message: in String): McpToolResult {
  McpToolResult(content = singleTextContentList(message), isError = true)
}

/// Build a successful result carrying a single text block — the common
/// case for a tool that returns plain text.
@stable(since = "0.1")
pub func toolTextResult(text: in String): McpToolResult {
  McpToolResult(content = singleTextContentList(text), isError = false)
}

pub func encodeToolResult(r: in McpToolResult): JsonValue {
  JObject(
    fields = [
      JsonField(name = "content", value = encodeContentList(r.content)),
      JsonField(name = "isError", value = JBool(value = r.isError))
    ]
  )
}

pub func decodeToolResult(v: in JsonValue): McpToolResult {
  val content = match getField(v, "content") { case Some(c) -> decodeContentList(c); case None -> newList() }
  val isError = match getBool(v, "isError") { case Some(b) -> b; case None -> false }
  McpToolResult(content = content, isError = isError)
}

@stable(since = "0.1")
pub interface McpToolHandler {
  /// Handle a `tools/call` invocation. An `Err` here is NOT a protocol
  /// error — it is reported to the peer as a successful `CallToolResult`
  /// with `isError: true` (see `toolErrorResult`), per spec.
  func call(args: in Option[JsonValue]): Result[McpToolResult, String]
}

/// A registered tool: its wire-visible name/description/input schema, plus
/// the handler invoked on `tools/call`.
@stable(since = "0.1")
pub record McpToolDef {
  name: String
  description: String
  inputSchema: JsonValue
  handler: McpToolHandler
}

func encodeToolDef(t: in McpToolDef): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "name", value = JString(value = t.name)))
  if t.description.length > 0 {
    fields.add(JsonField(name = "description", value = JString(value = t.description)))
  }
  fields.add(JsonField(name = "inputSchema", value = t.inputSchema))
  JObject(fields = fields)
}

pub func encodeToolDefList(tools: in List[McpToolDef]): JsonValue {
  val acc: List[JsonValue] = newList()
  var i = 0
  while i < tools.count {
    acc.add(encodeToolDef(tools[i]))
    i = i + 1
  }
  JArray(items = acc)
}

/// Client-side view of a registered tool, decoded from `tools/list`.
@stable(since = "0.1")
pub record McpToolInfo {
  name: String
  description: String
  inputSchema: JsonValue
}

func decodeToolInfo(v: in JsonValue): McpToolInfo {
  val name = match getString(v, "name") { case Some(s) -> s; case None -> "" }
  val description = match getString(v, "description") { case Some(s) -> s; case None -> "" }
  val inputSchema = match getField(v, "inputSchema") { case Some(s) -> s; case None -> JObject(fields = newList()) }
  McpToolInfo(name = name, description = description, inputSchema = inputSchema)
}

pub func decodeToolInfoList(v: in JsonValue): List[McpToolInfo] {
  val acc: List[McpToolInfo] = newList()
  match getArray(v, "tools") {
    case None -> ()
    case Some(items) -> {
      var i = 0
      while i < items.count {
        acc.add(decodeToolInfo(items[i]))
        i = i + 1
      }
    }
  }
  acc
}

// ── Resumable tools (input_required multi-round-trip, docs/64 §3.1) ────────
/// The server's answer to `tools/call` when the tool needs the peer to
/// supply more input mid-call (the permission-prompt case). `requestState`
/// is an opaque token the caller must echo back verbatim on the follow-up
/// `tools/call` (see `Mcp.Client.resumeToolCall`); this library never
/// interprets it, only carries it.
@stable(since = "0.2")
pub record McpInputRequired {
  inputRequests: JsonValue
  requestState: String
}

/// What a resumable tool call answers with: either a normal finished
/// result, or a request for more input. Additive to the plain
/// `McpToolResult` shape (docs/64 §3.1) — a non-resumable tool never
/// produces this union at all.
@stable(since = "0.2")
pub union McpToolCallOutcome {
  //
  // NOTE: `ToolResult`'s payload field is named `value`, not `result` — see
  // `jsonrpc.l`'s `RpcResponse.RpcSuccess` for why: the self-hosted parser
  // rejects `result` as a union case payload field name specifically (a
  // bare union case field named `result` fails with "expected a type" —
  // P0050). Filed upstream; see `lyric-jsonrpc/README.md` "Known upstream
  // issues".
  case ToolResult(value: McpToolResult)
  case InputRequired(value: McpInputRequired)
}

pub func encodeToolCallOutcome(outcome: in McpToolCallOutcome): JsonValue {
  match outcome {
    case ToolResult(result) -> encodeToolResult(result)
    case InputRequired(ir) -> JObject(fields = [JsonField(name = "resultType", value = JString(value = "input_required")), JsonField(name = "inputRequests", value = ir.inputRequests), JsonField(name = "requestState", value = JString(value = ir.requestState))])
  }
}

/// Decode a `tools/call` result that may be either shape: an
/// `input_required` object (`"resultType": "input_required"`) or a plain
/// `CallToolResult`.
pub func decodeToolCallOutcome(v: in JsonValue): McpToolCallOutcome {
  match getString(v, "resultType") {
    case Some(rt) -> {
      if rt == "input_required" {
        val inputRequests = match getField(v, "inputRequests") { case Some(x) -> x; case None -> JObject(fields = newList()) }
        // A missing `requestState` on a genuine `input_required` response is
        // a malformed/buggy server, not a case this client tries to detect —
        // consistent with this decoder's lenient philosophy elsewhere, the
        // empty-string default is echoed back verbatim by a later `resume`
        // call, which the server is free to reject on its own terms.
        val requestState = match getString(v, "requestState") { case Some(s) -> s; case None -> "" }
        InputRequired(value = McpInputRequired(inputRequests = inputRequests, requestState = requestState))
      } else {
        ToolResult(value = decodeToolResult(v))
      }
    }
    case None -> ToolResult(value = decodeToolResult(v))
  }
}

/// Implemented by a tool that may need mid-call input instead of finishing
/// in one round trip — the permission-prompt shape docs/62 §1 motivated
/// this whole library with. Registered via `Mcp.Server.addResumableTool`
/// alongside (never instead of — see that function's doc) plain
/// `McpToolHandler` registrations, so no existing `McpToolDef`/
/// `McpToolHandler` caller needs to change.
@stable(since = "0.2")
pub interface McpResumableToolHandler {
  /// Handle the initial `tools/call` invocation.
  func call(args: in Option[JsonValue]): Result[McpToolCallOutcome, String]
  /// Handle a follow-up `tools/call` carrying a `requestState` string and
  /// the peer's `inputResponses` answering the earlier `inputRequests`.
  /// `requestState` is an unauthenticated, unvalidated opaque echo token
  /// — the dispatcher (`Mcp.Server`) routes to `resume` purely because
  /// the incoming params include a `requestState` field, with no check
  /// that this (or any) handler ever issued it. A peer can call `resume`
  /// directly with a fabricated `requestState`, skipping `call` entirely.
  /// A handler encoding a security-sensitive target in `requestState`
  /// must independently verify/authorize inside `resume` itself before
  /// acting — never assume the runtime already validated provenance.
  func resume(requestState: in String, inputResponses: in JsonValue): Result[McpToolCallOutcome, String]
}

/// A registered resumable tool: same wire-visible shape as `McpToolDef`,
/// but dispatched through `McpResumableToolHandler` instead of
/// `McpToolHandler` (see that interface's doc for why this is a separate
/// registration rather than a field added to `McpToolDef`).
@stable(since = "0.2")
pub record McpResumableToolDef {
  name: String
  description: String
  inputSchema: JsonValue
  handler: McpResumableToolHandler
}

func encodeResumableToolDef(t: in McpResumableToolDef): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "name", value = JString(value = t.name)))
  if t.description.length > 0 {
    fields.add(JsonField(name = "description", value = JString(value = t.description)))
  }
  fields.add(JsonField(name = "inputSchema", value = t.inputSchema))
  JObject(fields = fields)
}

func hasResumableToolNamed(resumableTools: in List[McpResumableToolDef], name: in String): Bool {
  var i = 0
  var found = false
  while i < resumableTools.count {
    if resumableTools[i].name == name {
      found = true
    }
    i = i + 1
  }
  found
}

/// Encode the `tools` array for `tools/list`, combining plain and
/// resumable tool registrations (the wire shape is identical either way —
/// only dispatch differs, see `Mcp.Server.handleToolsCall`). A name
/// registered via both `addTool` and `addResumableTool` (see `addTool`'s
/// doc comment) contributes exactly one entry here — the resumable one —
/// matching `handleToolsCall`'s own resumable-first dispatch precedence,
/// rather than shipping two same-named entries in `tools/list`.
@stable(since = "0.2")
pub func encodeAllToolDefsList(tools: in List[McpToolDef], resumableTools: in List[McpResumableToolDef]): JsonValue {
  val acc: List[JsonValue] = newList()
  var i = 0
  while i < tools.count {
    if not hasResumableToolNamed(resumableTools, tools[i].name) {
      acc.add(encodeToolDef(tools[i]))
    }
    i = i + 1
  }
  var j = 0
  while j < resumableTools.count {
    acc.add(encodeResumableToolDef(resumableTools[j]))
    j = j + 1
  }
  JArray(items = acc)
}

// ── server/discover (docs/64 §3.1) ──────────────────────────────────────────
/// Encode a `server/discover` result: the same `serverInfo`/`capabilities`
/// shape `initialize` used to return, minus the lifecycle bookkeeping —
/// answerable at any time, not gated on anything, and not itself a
/// negotiation (no `protocolVersion` field; see the module doc).
@stable(since = "0.2")
pub func encodeServerDiscoverResult(
  hasTools: in Bool,
  hasResources: in Bool,
  hasPrompts: in Bool,
  serverInfo: in McpImplementation,
): JsonValue {
  JObject(
    fields = [
      JsonField(name = "serverInfo", value = encodeImplementation(serverInfo)),
      JsonField(name = "capabilities", value = encodeCapabilities(hasTools, hasResources, hasPrompts))
    ]
  )
}

/// Decoded `capabilities` shape from `server/discover` (or `initialize`):
/// which of `tools`/`resources`/`prompts` the server advertises at least
/// one registration for. Mirrors `encodeCapabilities` — each field is
/// present on the wire object only when the server has a registration
/// for it (docs/62 §5.1), so decoding is presence-of-key, not a nested
/// value read.
@stable(since = "0.2")
pub record McpCapabilities {
  hasTools: Bool
  hasResources: Bool
  hasPrompts: Bool
}

func decodeCapabilities(v: in JsonValue): McpCapabilities {
  val hasTools = match getField(v, "tools") { case Some(_) -> true; case None -> false }
  val hasResources = match getField(v, "resources") { case Some(_) -> true; case None -> false }
  val hasPrompts = match getField(v, "prompts") { case Some(_) -> true; case None -> false }
  McpCapabilities(hasTools = hasTools, hasResources = hasResources, hasPrompts = hasPrompts)
}

/// Decoded `server/discover` result (client-side).
@stable(since = "0.2")
pub record McpDiscoverResult {
  serverInfo: McpImplementation
  capabilities: McpCapabilities
}

pub func decodeServerDiscoverResult(v: in JsonValue): McpDiscoverResult {
  val serverInfo = match getField(v, "serverInfo") {
    case Some(si) -> decodeImplementation(si)
    case None -> McpImplementation(name = "", version = "")
  }
  val capabilities = match getField(v, "capabilities") {
    case Some(c) -> decodeCapabilities(c)
    case None -> McpCapabilities(hasTools = false, hasResources = false, hasPrompts = false)
  }
  McpDiscoverResult(serverInfo = serverInfo, capabilities = capabilities)
}

// ── Resources ────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record McpResourceContent {
  uri: String
  mimeType: String
  text: String
}

pub func encodeResourceContent(c: in McpResourceContent): JsonValue {
  JObject(
    fields = [
      JsonField(name = "uri", value = JString(value = c.uri)),
      JsonField(name = "mimeType", value = JString(value = c.mimeType)),
      JsonField(name = "text", value = JString(value = c.text))
    ]
  )
}

pub func decodeResourceContent(v: in JsonValue): McpResourceContent {
  val uri = match getString(v, "uri") { case Some(s) -> s; case None -> "" }
  val mimeType = match getString(v, "mimeType") { case Some(s) -> s; case None -> "" }
  val text = match getString(v, "text") { case Some(s) -> s; case None -> "" }
  McpResourceContent(uri = uri, mimeType = mimeType, text = text)
}

@stable(since = "0.1")
pub interface McpResourceHandler {
  /// Handle a `resources/read` invocation. Unlike tools, a resource-read
  /// failure IS a protocol-level error (there is no `isError` result shape
  /// for resources in the spec) — `Err` maps to a JSON-RPC error response.
  func read(uri: in String): Result[McpResourceContent, String]
}

@stable(since = "0.1")
pub record McpResourceDef {
  uri: String
  name: String
  description: String
  mimeType: String
  handler: McpResourceHandler
}

func encodeResourceDef(r: in McpResourceDef): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "uri", value = JString(value = r.uri)))
  fields.add(JsonField(name = "name", value = JString(value = r.name)))
  if r.description.length > 0 {
    fields.add(JsonField(name = "description", value = JString(value = r.description)))
  }
  if r.mimeType.length > 0 {
    fields.add(JsonField(name = "mimeType", value = JString(value = r.mimeType)))
  }
  JObject(fields = fields)
}

pub func encodeResourceDefList(resources: in List[McpResourceDef]): JsonValue {
  val acc: List[JsonValue] = newList()
  var i = 0
  while i < resources.count {
    acc.add(encodeResourceDef(resources[i]))
    i = i + 1
  }
  JArray(items = acc)
}

/// Client-side view of a registered resource, decoded from `resources/list`.
@stable(since = "0.1")
pub record McpResourceInfo {
  uri: String
  name: String
  description: String
  mimeType: String
}

func decodeResourceInfo(v: in JsonValue): McpResourceInfo {
  val uri = match getString(v, "uri") { case Some(s) -> s; case None -> "" }
  val name = match getString(v, "name") { case Some(s) -> s; case None -> "" }
  val description = match getString(v, "description") { case Some(s) -> s; case None -> "" }
  val mimeType = match getString(v, "mimeType") { case Some(s) -> s; case None -> "" }
  McpResourceInfo(uri = uri, name = name, description = description, mimeType = mimeType)
}

pub func decodeResourceInfoList(v: in JsonValue): List[McpResourceInfo] {
  val acc: List[McpResourceInfo] = newList()
  match getArray(v, "resources") {
    case None -> ()
    case Some(items) -> {
      var i = 0
      while i < items.count {
        acc.add(decodeResourceInfo(items[i]))
        i = i + 1
      }
    }
  }
  acc
}

// ── Prompts ──────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record McpPromptArgument {
  name: String
  description: String
  required: Bool
}

func encodePromptArgument(a: in McpPromptArgument): JsonValue {
  JObject(
    fields = [
      JsonField(name = "name", value = JString(value = a.name)),
      JsonField(name = "description", value = JString(value = a.description)),
      JsonField(name = "required", value = JBool(value = a.required))
    ]
  )
}

func decodePromptArgument(v: in JsonValue): McpPromptArgument {
  val name = match getString(v, "name") { case Some(s) -> s; case None -> "" }
  val description = match getString(v, "description") { case Some(s) -> s; case None -> "" }
  val required = match getBool(v, "required") { case Some(b) -> b; case None -> false }
  McpPromptArgument(name = name, description = description, required = required)
}

func encodePromptArgumentList(args: in List[McpPromptArgument]): JsonValue {
  val acc: List[JsonValue] = newList()
  var i = 0
  while i < args.count {
    acc.add(encodePromptArgument(args[i]))
    i = i + 1
  }
  JArray(items = acc)
}

func decodePromptArgumentList(v: in JsonValue): List[McpPromptArgument] {
  val acc: List[McpPromptArgument] = newList()
  match asArray(v) {
    case None -> ()
    case Some(items) -> {
      var i = 0
      while i < items.count {
        acc.add(decodePromptArgument(items[i]))
        i = i + 1
      }
    }
  }
  acc
}

/// One message in a `prompts/get` result. `role` is `"user"` or
/// `"assistant"` per spec.
@stable(since = "0.1")
pub record McpPromptMessage {
  role: String
  content: McpContent
}

func encodePromptMessage(m: in McpPromptMessage): JsonValue {
  JObject(
    fields = [
      JsonField(name = "role", value = JString(value = m.role)),
      JsonField(name = "content", value = encodeContent(m.content))
    ]
  )
}

func decodePromptMessage(v: in JsonValue): Option[McpPromptMessage] {
  match getString(v, "role") {
    case None -> None
    case Some(role) -> match getField(v, "content") { case None -> None; case Some(cv) -> match decodeContent(cv) { case None -> None; case Some(c) -> Some(value = McpPromptMessage(role = role, content = c)) } }
  }
}

func encodePromptMessageList(messages: in List[McpPromptMessage]): JsonValue {
  val acc: List[JsonValue] = newList()
  var i = 0
  while i < messages.count {
    acc.add(encodePromptMessage(messages[i]))
    i = i + 1
  }
  JArray(items = acc)
}

func decodePromptMessageList(v: in JsonValue): List[McpPromptMessage] {
  val acc: List[McpPromptMessage] = newList()
  match asArray(v) {
    case None -> ()
    case Some(items) -> {
      var i = 0
      while i < items.count {
        match decodePromptMessage(items[i]) {
          case Some(m) -> acc.add(m)
          case None -> ()
        }
        i = i + 1
      }
    }
  }
  acc
}

@stable(since = "0.1")
pub record McpPromptResult {
  description: String
  messages: List[McpPromptMessage]
}

pub func encodePromptResult(r: in McpPromptResult): JsonValue {
  val fields: List[JsonField] = newList()
  if r.description.length > 0 {
    fields.add(JsonField(name = "description", value = JString(value = r.description)))
  }
  fields.add(JsonField(name = "messages", value = encodePromptMessageList(r.messages)))
  JObject(fields = fields)
}

pub func decodePromptResult(v: in JsonValue): McpPromptResult {
  val description = match getString(v, "description") { case Some(s) -> s; case None -> "" }
  val messages = match getField(v, "messages") { case Some(m) -> decodePromptMessageList(m); case None -> newList() }
  McpPromptResult(description = description, messages = messages)
}

@stable(since = "0.1")
pub interface McpPromptHandler {
  /// Handle a `prompts/get` invocation. Like resources, `Err` is a
  /// protocol-level error (no `isError` result shape exists for prompts).
  func get(args: in Option[JsonValue]): Result[McpPromptResult, String]
}

@stable(since = "0.1")
pub record McpPromptDef {
  name: String
  description: String
  arguments: List[McpPromptArgument]
  handler: McpPromptHandler
}

func encodePromptDef(p: in McpPromptDef): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "name", value = JString(value = p.name)))
  if p.description.length > 0 {
    fields.add(JsonField(name = "description", value = JString(value = p.description)))
  }
  if p.arguments.count > 0 {
    fields.add(JsonField(name = "arguments", value = encodePromptArgumentList(p.arguments)))
  }
  JObject(fields = fields)
}

pub func encodePromptDefList(prompts: in List[McpPromptDef]): JsonValue {
  val acc: List[JsonValue] = newList()
  var i = 0
  while i < prompts.count {
    acc.add(encodePromptDef(prompts[i]))
    i = i + 1
  }
  JArray(items = acc)
}

/// Client-side view of a registered prompt, decoded from `prompts/list`.
@stable(since = "0.1")
pub record McpPromptInfo {
  name: String
  description: String
  arguments: List[McpPromptArgument]
}

func decodePromptInfo(v: in JsonValue): McpPromptInfo {
  val name = match getString(v, "name") { case Some(s) -> s; case None -> "" }
  val description = match getString(v, "description") { case Some(s) -> s; case None -> "" }
  val arguments = match getField(v, "arguments") { case Some(a) -> decodePromptArgumentList(a); case None -> newList() }
  McpPromptInfo(name = name, description = description, arguments = arguments)
}

pub func decodePromptInfoList(v: in JsonValue): List[McpPromptInfo] {
  val acc: List[McpPromptInfo] = newList()
  match getArray(v, "prompts") {
    case None -> ()
    case Some(items) -> {
      var i = 0
      while i < items.count {
        acc.add(decodePromptInfo(items[i]))
        i = i + 1
      }
    }
  }
  acc
}

// ── Capabilities + initialize ───────────────────────────────────────────────
func encodeCapabilities(hasTools: in Bool, hasResources: in Bool, hasPrompts: in Bool): JsonValue {
  val fields: List[JsonField] = newList()
  if hasTools {
    fields.add(
      JsonField(name = "tools", value = JObject(fields = [JsonField(name = "listChanged", value = JBool(value = false))]))
    )
  }
  if hasResources {
    fields.add(
      JsonField(
        name = "resources",
        value = JObject(fields = [JsonField(name = "listChanged", value = JBool(value = false))])
      )
    )
  }
  if hasPrompts {
    fields.add(
      JsonField(
        name = "prompts",
        value = JObject(fields = [JsonField(name = "listChanged", value = JBool(value = false))])
      )
    )
  }
  JObject(fields = fields)
}

/// Encode an `InitializeResult` (server -> client).
@stable(since = "0.1")
pub func encodeInitializeResult(
  protocolVersion: in String,
  hasTools: in Bool,
  hasResources: in Bool,
  hasPrompts: in Bool,
  serverInfo: in McpImplementation,
): JsonValue {
  JObject(
    fields = [
      JsonField(name = "protocolVersion", value = JString(value = protocolVersion)),
      JsonField(name = "capabilities", value = encodeCapabilities(hasTools, hasResources, hasPrompts)),
      JsonField(name = "serverInfo", value = encodeImplementation(serverInfo))
    ]
  )
}

/// Decoded `InitializeResult` (client-side). No `Mcp.Client` function
/// calls this today — `connectTransport`/`connectStdio` no longer
/// perform the `initialize` round-trip at all (docs/64 §3.3). Kept
/// `@stable` (not dead code to remove) for a consumer that hand-rolls
/// legacy `initialize` support against a peer that still requires it;
/// `Mcp.Server.handleInitialize` still answers the method server-side.
@stable(since = "0.1")
pub record McpInitializeResult {
  protocolVersion: String
  serverInfo: McpImplementation
}

pub func decodeInitializeResult(v: in JsonValue): McpInitializeResult {
  val protocolVersion = match getString(v, "protocolVersion") { case Some(s) -> s; case None -> "" }
  val serverInfo = match getField(v, "serverInfo") {
    case Some(si) -> decodeImplementation(si)
    case None -> McpImplementation(name = "", version = "")
  }
  McpInitializeResult(protocolVersion = protocolVersion, serverInfo = serverInfo)
}

/// Decoded `InitializeRequest` params (server-side).
pub record McpInitializeParams {
  protocolVersion: String
  clientInfo: McpImplementation
}

pub func decodeInitializeParams(paramsOpt: in Option[JsonValue]): Option[McpInitializeParams] {
  match paramsOpt {
    case None -> None
    case Some(p) -> match getString(p, "protocolVersion") { case None -> None; case Some(pv) -> { val clientInfo = match getField(p, "clientInfo") { case Some(ci) -> decodeImplementation(ci); case None -> McpImplementation(name = "", version = "") }; Some(value = McpInitializeParams(protocolVersion = pv, clientInfo = clientInfo)) } }
  }
}

/// Encode an `InitializeRequest` params object (client -> server).
@stable(since = "0.1")
pub func encodeInitializeParams(protocolVersion: in String, clientInfo: in McpImplementation): JsonValue {
  JObject(
    fields = [
      JsonField(name = "protocolVersion", value = JString(value = protocolVersion)),
      JsonField(name = "capabilities", value = JObject(fields = newList())),
      JsonField(name = "clientInfo", value = encodeImplementation(clientInfo))
    ]
  )
}
