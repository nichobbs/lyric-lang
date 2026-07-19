//! tests/mcp_serialization_tests.l — pure JSON-shape tests for every MCP
//! message this library encodes/decodes. Each case asserts the *exact*
//! wire text (field names, nesting, discriminator values) against a
//! hand-written fixture — not just "it round-trips" — per
//! docs/62-jsonrpc-mcp.md §5 and the MCP 2025-06-18 schema. No transport,
//! no process, no peer: pure `Mcp` encode/decode functions over
//! `JsonRpc.Json` values, so this suite is expected to pass identically on
//! both targets.
//!
//! NOTE: assertions compare `Option[T]` via `match`, never `==` — see
//! lyric-jsonrpc/README.md "Known upstream issues" #4 (`Option[T] ==
//! Option[T]` does not compare structurally on the current backend).
@test_module
package Mcp.McpSerializationTests

import Std.Core
import Std.Collections
import Std.Testing
import JsonRpc.Json
import Mcp

// ── Test-only handler doubles (never invoked here — only used to satisfy
// McpToolDef/McpResourceDef/McpPromptDef's mandatory `handler` field so
// defs can be constructed for encoding) ─────────────────────────────────────
record NoopToolHandler {
}

impl McpToolHandler for NoopToolHandler {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    Ok(value = toolTextResult(""))
  }
}

record NoopResourceHandler {
}

impl McpResourceHandler for NoopResourceHandler {
  func read(uri: in String): Result[McpResourceContent, String] {
    Ok(value = McpResourceContent(uri = uri, mimeType = "text/plain", text = ""))
  }
}

record NoopPromptHandler {
}

impl McpPromptHandler for NoopPromptHandler {
  func get(args: in Option[JsonValue]): Result[McpPromptResult, String] {
    Ok(value = McpPromptResult(description = "", messages = newList()))
  }
}

func assertJsonEqual(actual: in JsonValue, expected: in String, label: in String): Unit {
  assertEqual(writeValue(actual), expected, label)
}

func oneToolList(): List[McpToolDef] {
  val schema = JObject(fields = [JsonField(name = "type", value = JString(value = "object"))])
  val tools: List[McpToolDef] = newList()
  tools.add(McpToolDef(name = "echo", description = "Echo back", inputSchema = schema, handler = NoopToolHandler()))
  tools
}

// ── initialize ───────────────────────────────────────────────────────────────
test "encodeInitializeResult: exact field names and capability derivation" {
  val serverInfo = McpImplementation(name = "test-server", version = "1.0.0")
  val encoded = encodeInitializeResult(protocolVersionLatest, true, false, true, serverInfo)
  assertJsonEqual(
    encoded,
    "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{\"listChanged\":false},\"prompts\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"test-server\",\"version\":\"1.0.0\"}}",
    "initialize result shape"
  )
}

test "encodeInitializeResult: no capabilities registered -> empty capabilities object" {
  val serverInfo = McpImplementation(name = "s", version = "0.0.1")
  val encoded = encodeInitializeResult(protocolVersionLatest, false, false, false, serverInfo)
  assertJsonEqual(
    encoded,
    "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"s\",\"version\":\"0.0.1\"}}",
    "empty capabilities"
  )
}

test "encodeInitializeParams: exact field names" {
  val clientInfo = McpImplementation(name = "test-client", version = "0.1.0")
  val encoded = encodeInitializeParams(protocolVersionLatest, clientInfo)
  assertJsonEqual(
    encoded,
    "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test-client\",\"version\":\"0.1.0\"}}",
    "initialize params shape"
  )
}

test "decodeInitializeResult: parses protocolVersion and serverInfo" {
  val text = "{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"srv\",\"version\":\"2.0.0\"}}"
  match parseValue(text) {
    case Err(e) -> assertTrue(false, "fixture failed to parse: " + e.message())
    case Ok(v) -> {
      val result = decodeInitializeResult(v)
      assertEqual(result.protocolVersion, "2025-03-26", "protocolVersion decoded")
      assertEqual(result.serverInfo.name, "srv", "serverInfo.name decoded")
      assertEqual(result.serverInfo.version, "2.0.0", "serverInfo.version decoded")
    }
  }
}

test "decodeInitializeParams: requires protocolVersion" {
  match parseValue("{\"clientInfo\":{\"name\":\"c\",\"version\":\"1\"}}") {
    case Err(e) -> assertTrue(false, "fixture failed to parse: " + e.message())
    case Ok(v) -> match decodeInitializeParams(Some(value = v)) { case Some(_) -> assertTrue(false, "expected None when protocolVersion is missing"); case None -> () }
  }
}

test "decodeInitializeParams: decodes protocolVersion and clientInfo" {
  match parseValue("{\"protocolVersion\":\"2025-06-18\",\"clientInfo\":{\"name\":\"c\",\"version\":\"1.2.3\"}}") {
    case Err(e) -> assertTrue(false, "fixture failed to parse: " + e.message())
    case Ok(v) -> match decodeInitializeParams(Some(value = v)) { case None -> assertTrue(false, "expected Some"); case Some(p) -> { assertEqual(p.protocolVersion, "2025-06-18", "protocolVersion"); assertEqual(p.clientInfo.name, "c", "clientInfo.name"); assertEqual(p.clientInfo.version, "1.2.3", "clientInfo.version") } }
  }
}

test "negotiateProtocolVersion: echoes a supported version, refuses an unsupported one" {
  assertEqual(negotiateProtocolVersion("2025-06-18"), "2025-06-18", "latest echoed")
  assertEqual(negotiateProtocolVersion("2025-03-26"), "2025-03-26", "legacy echoed")
  assertEqual(
    negotiateProtocolVersion("2024-01-01"),
    protocolVersionLatest,
    "unsupported version refused, responds with latest"
  )
}

// ── tools ────────────────────────────────────────────────────────────────────
test "encodeToolDefList: exact field names, description omitted when empty" {
  val tools = oneToolList()
  assertJsonEqual(
    encodeToolDefList(tools),
    "[{\"name\":\"echo\",\"description\":\"Echo back\",\"inputSchema\":{\"type\":\"object\"}}]",
    "tools/list tools array"
  )
  val noDescTools: List[McpToolDef] = newList()
  noDescTools.add(
    McpToolDef(name = "bare", description = "", inputSchema = JObject(fields = newList()), handler = NoopToolHandler())
  )
  assertJsonEqual(
    encodeToolDefList(noDescTools),
    "[{\"name\":\"bare\",\"inputSchema\":{}}]",
    "empty description omitted"
  )
}

test "decodeToolInfoList: parses the tools/list result shape" {
  val text = "{\"tools\":[{\"name\":\"a\",\"description\":\"A\",\"inputSchema\":{\"type\":\"object\"}},{\"name\":\"b\",\"inputSchema\":{}}]}"
  match parseValue(text) {
    case Err(e) -> assertTrue(false, "fixture failed to parse: " + e.message())
    case Ok(v) -> {
      val infos = decodeToolInfoList(v)
      assertEqualInt(infos.count, 2, "two tools decoded")
      assertEqual(infos[0].name, "a", "first tool name")
      assertEqual(infos[0].description, "A", "first tool description")
      assertEqual(infos[1].name, "b", "second tool name")
      assertEqual(infos[1].description, "", "missing description defaults to empty")
    }
  }
}

test "encodeToolResult: content array with type discriminators, isError flag" {
  val content: List[McpContent] = newList()
  content.add(TextContent(text = "hi"))
  content.add(ImageContent(dataBase64 = "QUJD", mimeType = "image/png"))
  content.add(EmbeddedResource(uri = "file:///x", mimeType = "text/plain", text = "hello"))
  val result = McpToolResult(content = content, isError = false)
  assertJsonEqual(
    encodeToolResult(result),
    "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"},{\"type\":\"image\",\"data\":\"QUJD\",\"mimeType\":\"image/png\"},{\"type\":\"resource\",\"resource\":{\"uri\":\"file:///x\",\"mimeType\":\"text/plain\",\"text\":\"hello\"}}],\"isError\":false}",
    "content discriminators"
  )
}

test "toolErrorResult: isError true with a single text block" {
  assertJsonEqual(
    encodeToolResult(toolErrorResult("boom")),
    "{\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}",
    "tool error result shape"
  )
}

test "decodeToolResult: parses content and isError" {
  val text = "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"isError\":true}"
  match parseValue(text) {
    case Err(e) -> assertTrue(false, "fixture failed to parse: " + e.message())
    case Ok(v) -> {
      val result = decodeToolResult(v)
      assertTrue(result.isError, "isError decoded true")
      assertEqualInt(result.content.count, 1, "one content block")
      match result.content[0] {
        case TextContent(t) -> assertEqual(t, "ok", "text content decoded")
        case _ -> assertTrue(false, "expected TextContent")
      }
    }
  }
}

test "decodeToolResult: unrecognized content type is dropped, not fatal" {
  val text = "{\"content\":[{\"type\":\"audio\",\"data\":\"x\"},{\"type\":\"text\",\"text\":\"kept\"}],\"isError\":false}"
  match parseValue(text) {
    case Err(e) -> assertTrue(false, "fixture failed to parse: " + e.message())
    case Ok(v) -> {
      val result = decodeToolResult(v)
      assertEqualInt(result.content.count, 1, "unrecognized block dropped")
      match result.content[0] {
        case TextContent(t) -> assertEqual(t, "kept", "the recognized block survives")
        case _ -> assertTrue(false, "expected TextContent")
      }
    }
  }
}

// ── resources ────────────────────────────────────────────────────────────────
test "encodeResourceDefList: exact field names, optional fields omitted when empty" {
  val resources: List[McpResourceDef] = newList()
  resources.add(
    McpResourceDef(
      uri = "file:///a.txt",
      name = "a",
      description = "",
      mimeType = "text/plain",
      handler = NoopResourceHandler()
    )
  )
  assertJsonEqual(
    encodeResourceDefList(resources),
    "[{\"uri\":\"file:///a.txt\",\"name\":\"a\",\"mimeType\":\"text/plain\"}]",
    "resources/list resources array"
  )
}

test "decodeResourceInfoList: parses the resources/list result shape" {
  val text = "{\"resources\":[{\"uri\":\"file:///a\",\"name\":\"a\",\"description\":\"D\",\"mimeType\":\"text/plain\"}]}"
  match parseValue(text) {
    case Err(e) -> assertTrue(false, "fixture failed to parse: " + e.message())
    case Ok(v) -> {
      val infos = decodeResourceInfoList(v)
      assertEqualInt(infos.count, 1, "one resource decoded")
      assertEqual(infos[0].uri, "file:///a", "uri")
      assertEqual(infos[0].description, "D", "description")
    }
  }
}

test "encodeResourceContent / decodeResourceContent: uri/mimeType/text round-trip" {
  val content = McpResourceContent(uri = "file:///a.txt", mimeType = "text/plain", text = "hello world")
  assertJsonEqual(
    encodeResourceContent(content),
    "{\"uri\":\"file:///a.txt\",\"mimeType\":\"text/plain\",\"text\":\"hello world\"}",
    "resource content shape"
  )
  match parseValue("{\"uri\":\"file:///a.txt\",\"mimeType\":\"text/plain\",\"text\":\"hello world\"}") {
    case Err(e) -> assertTrue(false, "fixture failed to parse: " + e.message())
    case Ok(v) -> {
      val decoded = decodeResourceContent(v)
      assertEqual(decoded.uri, content.uri, "uri round-trip")
      assertEqual(decoded.text, content.text, "text round-trip")
    }
  }
}

// ── prompts ──────────────────────────────────────────────────────────────────
test "encodePromptDefList: exact field names including nested arguments" {
  val args: List[McpPromptArgument] = newList()
  args.add(McpPromptArgument(name = "who", description = "name", required = true))
  val prompts: List[McpPromptDef] = newList()
  prompts.add(McpPromptDef(name = "greet", description = "Greets", arguments = args, handler = NoopPromptHandler()))
  assertJsonEqual(
    encodePromptDefList(prompts),
    "[{\"name\":\"greet\",\"description\":\"Greets\",\"arguments\":[{\"name\":\"who\",\"description\":\"name\",\"required\":true}]}]",
    "prompts/list prompts array"
  )
}

test "decodePromptInfoList: parses the prompts/list result shape" {
  val text = "{\"prompts\":[{\"name\":\"greet\",\"description\":\"Greets\",\"arguments\":[{\"name\":\"who\",\"description\":\"\",\"required\":false}]}]}"
  match parseValue(text) {
    case Err(e) -> assertTrue(false, "fixture failed to parse: " + e.message())
    case Ok(v) -> {
      val infos = decodePromptInfoList(v)
      assertEqualInt(infos.count, 1, "one prompt decoded")
      assertEqual(infos[0].name, "greet", "prompt name")
      assertEqualInt(infos[0].arguments.count, 1, "one argument decoded")
      assertEqual(infos[0].arguments[0].name, "who", "argument name")
      assertFalse(infos[0].arguments[0].required, "argument required decoded")
    }
  }
}

test "encodePromptResult: description, messages with role/content" {
  val messages: List[McpPromptMessage] = newList()
  messages.add(McpPromptMessage(role = "user", content = TextContent(text = "Hello")))
  val result = McpPromptResult(description = "A greeting", messages = messages)
  assertJsonEqual(
    encodePromptResult(result),
    "{\"description\":\"A greeting\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"Hello\"}}]}",
    "prompts/get result shape"
  )
}

test "decodePromptResult: parses description and messages" {
  val text = "{\"description\":\"A greeting\",\"messages\":[{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"Hi there\"}}]}"
  match parseValue(text) {
    case Err(e) -> assertTrue(false, "fixture failed to parse: " + e.message())
    case Ok(v) -> {
      val result = decodePromptResult(v)
      assertEqual(result.description, "A greeting", "description decoded")
      assertEqualInt(result.messages.count, 1, "one message decoded")
      assertEqual(result.messages[0].role, "assistant", "role decoded")
      match result.messages[0].content {
        case TextContent(t) -> assertEqual(t, "Hi there", "message content decoded")
        case _ -> assertTrue(false, "expected TextContent")
      }
    }
  }
}

// ── MCP-specific error code ─────────────────────────────────────────────────
test "serverNotInitialized is a distinct, negative, non-standard JSON-RPC code" {
  assertTrue(serverNotInitialized == 0 - 32002, "serverNotInitialized value")
}
