# 62 — JSON-RPC 2.0 and Model Context Protocol libraries

Status: specced in D129. lyric-jsonrpc, lyric-mcp (stdio transport),
the stdlib seams, and the lyric-ws dotnet backend (#778) are implemented;
streamable HTTP (§5.3 milestone 2) and the open questions remain. JVM
gaps are tracked in #6118–#6124, #6127, #6133–#6136. First consumer:
`nichobbs/cloud-agents`' in-container permission-callback MCP server
(see that repo's `docs/phase6-mcp-callbacks.md`). This sketch is the
agreed build spec for three coordinated tracks; each track lands as its
own PR series and cites this doc.

Extends: `docs/16-lsp-vscode-plan.md` (the only existing JSON-RPC
implementation, embedded in `lyric-compiler/lyric/lsp.l`),
`docs/57-stdlib-ecosystem-library-review.md` (lyric-ws / lyric-web
maturity findings), `docs/61-https-tls-http-versions.md` (the
`Std.HttpServer` / `Std.TcpHost` stack the WebSocket work builds on).

## 1. Motivation and scope

MCP (Model Context Protocol) is JSON-RPC 2.0 over two standard
transports: stdio (newline-delimited JSON) and streamable HTTP
(POST + SSE). Lyric has no reusable JSON-RPC library — the LSP server
hand-rolls Content-Length framing and envelope construction inside
`lsp.l` — and no MCP support at all. The cloud-agents application needs
an MCP server it can ship inside agent containers so coding agents can
call back to the host (permission prompts, progress, user questions).

Three tracks, layered:

1. **lyric-jsonrpc** (`lyric-jsonrpc/`, package head `JsonRpc`,
   artifact `Lyric.JsonRpc`) — transport-agnostic JSON-RPC 2.0 peer +
   a strict cross-target JSON value model + stdio framing.
2. **lyric-mcp** (`lyric-mcp/`, package head `Mcp`, artifact
   `Lyric.Mcp`) — MCP client and server on top of `JsonRpc`.
3. **lyric-ws dotnet completion** (#778) — not on the MCP critical
   path (WebSocket is not a standard MCP transport), but part of the
   same production-hardening push: `Ws.startServer` must stop returning
   `NOT_IMPLEMENTED` on `--target dotnet`.

Naming follows the ecosystem convention (`lyric-ws` → package `Ws`,
artifact `Lyric.Ws`): source packages are `JsonRpc`, `JsonRpc.Json`,
`JsonRpc.Stdio`, `Mcp`, `Mcp.Stdio`, `Mcp.Http`.

## 2. `JsonRpc.Json` — the value model

JSON-RPC needs a cross-target JSON tree with both a parser and a
writer. Neither existing stdlib option fits:

- `Std.Json` is a read-only cursor API over the BCL `JsonDocument` —
  dotnet-only, and it cannot construct or serialize a document.
- `Std.Yaml.parseJson` is cross-target but deliberately lenient (YAML
  1.2 is a JSON superset): a malformed-JSON frame that happens to be
  valid YAML would parse instead of producing the JSON-RPC `-32700`
  parse error a conforming peer must return. It also has no writer.

So `JsonRpc.Json` ships its own strict RFC 8259 value model, pure
Lyric, identical on both targets:

```lyric
pub union JsonValue {
  case JNull
  case JBool(value: Bool)
  case JInt(value: Long)          // integral numbers, i64 range
  case JFloat(value: Double)      // non-integral / out-of-i64-range
  case JString(value: String)
  case JArray(items: List[JsonValue])
  case JObject(fields: List[JsonField])   // insertion-ordered
}
pub record JsonField { name: String, value: JsonValue }

pub func parseValue(src: in String): Result[JsonValue, JsonParseError]
pub func writeValue(v: in JsonValue): String        // compact, no trailing newline
```

Requirements: full string-escape handling both directions (`\uXXXX`
incl. surrogate pairs, control-character escaping on write), duplicate
object keys preserved on parse (last-wins accessor helpers), depth
limit (default 128, configurable) so a hostile peer cannot stack-crash
the process, and number round-tripping that keeps i64 integers exact.
Accessor helpers mirror `Std.Yaml`'s shape (`getField`, `asString`,
`getString`, …) so the two APIs feel alike. Object field insertion
order is preserved on write.

Open question Q-RPC-001: whether this model later migrates into a
cross-target `Std.Json` v2 (docs/59 catalogues the current module's
issues). Out of scope here; `JsonRpc.Json` is the canonical model for
the RPC/MCP stack either way.

## 3. `JsonRpc` core — envelope and peer

Envelope types (all `@stable(since = "0.1")` on landing):

```lyric
pub union RpcId { case IntId(value: Long); case StringId(value: String); case NullId }
pub record RpcRequest  { id: Option[RpcId], method: String, params: Option[JsonValue] }
                        // id = None ⇒ notification
pub record RpcError    { code: Int, message: String, data: Option[JsonValue] }
pub union RpcResponse  { case RpcSuccess(id: RpcId, result: JsonValue)
                         case RpcFailure(id: RpcId, error: RpcError) }
```

Standard codes as `pub val`s: `parseError = -32700`,
`invalidRequest = -32600`, `methodNotFound = -32601`,
`invalidParams = -32602`, `internalError = -32603`.

The peer is symmetric (JSON-RPC has no client/server asymmetry; MCP
uses requests in both directions):

```lyric
pub interface RpcHandler {
  /// Handle an incoming request; return the result value or an error.
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]
  /// Handle an incoming notification (no response is ever sent).
  func onNotification(method: in String, params: in Option[JsonValue]): Unit
}

pub interface RpcTransport {
  /// Block until the next complete message arrives. None ⇒ clean EOF.
  func receive(): Result[Option[String], String]
  func send(payload: in String): Result[Unit, String]
  func close(): Unit
}

pub record RpcPeer { ... }   // constructed over an RpcTransport + RpcHandler
pub func runLoop(peer: inout RpcPeer): Result[Unit, String]
pub func call(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]
pub func notify(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[Unit, String]
```

Dispatch model v1: single-threaded. `runLoop` reads a message,
dispatches to the handler, writes the response, repeats. `call` issued
from inside a handler (outbound request mid-dispatch) reads the
transport inline until the matching response id arrives, queueing any
interleaved incoming requests for dispatch after the call returns —
the same discipline LSP servers use. Ids are auto-assigned
monotonically (`IntId`). Malformed inbound JSON produces a `-32700`
response with `id: null`; unknown methods `-32601`; handler panics
must be caught at the dispatch boundary and mapped to `-32603` (never
kill the loop).

Batch requests (JSON-RPC 2.0 §6) are supported in the core (an array
envelope maps over dispatch, order-preserving, notifications skipped in
the response array; empty batch ⇒ `-32600`). The MCP layer never emits
batches and rejects inbound ones (the 2025-06-18 MCP revision removed
batch support).

The LSP server is **not** migrated onto `JsonRpc` in v1 — it predates
the library, works, and its Content-Length framing carries a documented
UTF-8-length caveat; migration is Q-RPC-002 (do it once `JsonRpc.Stdio`
is proven, delete the hand-rolled framing in `lsp.l`).

## 4. `JsonRpc.Stdio` — framing

Two framings, one module:

- `NdjsonFraming` — one JSON message per `\n`-terminated line (the MCP
  stdio transport). Messages must not contain embedded newlines
  (`writeValue` is compact, so they never do).
- `ContentLengthFraming` — `Content-Length: N\r\n\r\n` + N bytes
  (the LSP framing), byte-accurate on UTF-8.

Both implement `RpcTransport` over `Std.Console` /
`Std.ConsoleHost` primitives (the same seam `lsp.l` reads today).
Loopback pipe tests cover framing round-trips including multi-byte
UTF-8 payloads and split reads.

## 5. `lyric-mcp` — protocol layer

Protocol revision: `2025-06-18` primary, `2025-03-26` accepted from
peers during version negotiation (respond with the newest mutually
supported revision; refuse others per spec).

### 5.1 Server surface

```lyric
pub record McpToolDef {
  name: String
  description: String
  inputSchema: JsonValue          // JSON Schema object
  handler: (Option[JsonValue]) -> Result[McpToolResult, String]
}
pub union McpContent {
  case TextContent(text: String)
  case ImageContent(dataBase64: String, mimeType: String)
  case EmbeddedResource(uri: String, mimeType: String, text: String)
}
pub record McpToolResult { content: List[McpContent], isError: Bool }

pub record McpServerInfo { name: String, version: String }
pub record McpServer { ... }    // builder: newServer(info) / addTool / addResource / addPrompt
pub func serveStdio(server: in McpServer): Result[Unit, String]
```

Implements: `initialize` (capability derivation from what was
registered — `tools`, `resources`, `prompts`, each with
`listChanged: false` in v1), `notifications/initialized`, `ping`,
`tools/list`, `tools/call`, `resources/list`, `resources/read`,
`prompts/list`, `prompts/get`. Pagination cursors accepted and ignored
(single page) in v1. Tool-execution failures are **results with
`isError: true`**, not protocol errors; protocol errors (`-32602` on
unknown tool, etc.) follow the spec. Requests arriving before
`initialize` completes get `-32002`-style server-not-initialized
errors per spec.

### 5.2 Client surface

```lyric
pub record McpClient { ... }
pub func connectStdio(command: in String, args: in List[String]): Result[McpClient, String]
   // spawns the server process, performs initialize/initialized
pub func listTools(client: inout McpClient): Result[List[McpToolInfo], String]
pub func callTool(client: inout McpClient, name: in String, args: in Option[JsonValue]): Result[McpToolResult, String]
pub func listResources / readResource / listPrompts / getPrompt / ping / disconnect
```

`connectStdio` needs child-process pipes with **long-lived
bidirectional stdio** — `Std.Process.runCapture` (batch, write-then-
read) is insufficient. Extending the `Std.Process` kernel with a
spawn-with-piped-stdio seam (spawn / writeLine / readLine / kill,
kernel-backed on both targets) is in scope for this track and lands in
`lyric-stdlib/std/_kernel/` per the extern rules.

### 5.3 Transports

- **stdio** (v1, required — cloud-agents only needs this).
- **streamable HTTP** (milestone 2, same track): server side on
  `lyric-web`'s chunked/SSE response support (`text/event-stream`),
  client side on `Std.Http`. POST for client→server messages
  (response either `application/json` or an SSE stream), GET opens the
  server→client SSE stream, DELETE ends the session,
  `Mcp-Session-Id` header for session binding, `MCP-Protocol-Version`
  header on subsequent requests. Origin validation and localhost-bind
  guidance per the spec's security section.

Out of scope v1 (tracked as open questions): sampling and elicitation
(server→client requests), `listChanged`/resource-subscription
notifications, roots, OAuth on the HTTP transport, cancellation and
progress notifications (Q-MCP-002 — cancellation matters for
long-blocking permission prompts; design the `notifications/cancelled`
handling before the HTTP transport ships).

## 6. lyric-ws dotnet backend (#778)

Design: pure-Lyric RFC 6455 on top of the `Std.TcpHost` transport
kernel (the same seam `Std.HttpServer`/`Std.HttpEngine` ride since
docs/61 phase 3.3), not ASP.NET Core — no new NuGet dependency, and
the frame codec is target-independent Lyric that a future JVM/native
kernel could share. Components:

1. **Upgrade handshake**: minimal HTTP/1.1 GET parser for the upgrade
   request (request line, headers; reject anything but a well-formed
   upgrade), `Sec-WebSocket-Accept` = Base64(SHA-1(key + RFC 6455
   GUID)). `Std.Hash` gains `sha1OfBytes` (kernel-backed both targets,
   same shape as `sha256OfBytes`; SHA-1 is fine here — the accept key
   is not a security boundary, note this in the doc comment).
2. **Frame codec**: pure-Lyric encode/decode — FIN/opcode/mask/length
   (7/16/64-bit), client-to-server masking enforced, control frames
   (ping/pong/close with code+reason), fragmented message reassembly
   with a max-message-size cap (the existing
   `maxMessageSizeBytes` config), UTF-8 validation on text frames.
3. **Kernel**: `Ws.Kernel.Net.startServer` accepts on `Std.TcpHost`,
   runs the handshake, then a per-connection read loop delivering the
   same primitive callback contract the Undertow kernel uses
   (`onOpen(connId, path, query, remoteAddr)`, `onMessage(connId,
   type, data)`, `onClose(connId, code, reason)`, `onError`), plus
   send/broadcast/close/connectionCount/isConnected against the
   registry bookkeeping that already exists in
   `lyric-ws/src/_kernel/net/ws_kernel.l`. Periodic ping keepalive per
   `pingIntervalMs`.

Parity note: the JVM kernel's documented gaps (fragmented multi-frame
messages, automatic pings) should not be replicated — the dotnet
kernel implements both, and closing the JVM gaps becomes a tracked
follow-up so the targets converge (Q-WS-001).

Tests: loopback integration (`startServer` + a minimal in-repo test
client over `Std.TcpHost` — connect, handshake, exchange text/binary/
fragmented/ping/close, assert callbacks and registry state), plus pure
codec unit tests over the frame encoder/decoder including RFC 6455
example vectors.

## 7. Testing and CI

Per repo standard: every new library gets `@test_module` suites wired
into its `lyric.toml` `[project.tests]`, runnable via
`./bin/lyric test --manifest <lib>/lyric.toml`, on **both** targets
where the runtime seams exist on both (the JSON model, envelope, and
framing logic are pure Lyric — both targets; process-spawn and TCP
integration tests run where the kernel seam is real, with the other
target's gap tracked, never silently skipped). READMEs follow the
existing library README shape (status header, feature matrix per
target, usage example).

## 8. Sequencing

PR-1 (unblocks everything): this sketch + `Std.Hash.sha1OfBytes` +
`Std.Process` piped-spawn seam.
PR-2: lyric-jsonrpc (Json model → envelope/peer → stdio framing), one
PR, fully tested.
PR-3: lyric-ws dotnet backend (#778) — independent of PR-2, parallel.
PR-4: lyric-mcp stdio (server + client) on PR-2.
PR-5: lyric-mcp streamable HTTP (server on lyric-web SSE, client on
`Std.Http`).
Docs/book/decision-log updates land with each PR per the working
conventions; the decision-log entry that backs this sketch lands with
PR-4 (when the MCP surface is real).

## 9. Open questions

- Q-RPC-001: migrate `JsonRpc.Json` into a cross-target `Std.Json` v2?
- Q-RPC-002: migrate `lsp.l` onto `JsonRpc` + `ContentLengthFraming`?
- Q-MCP-001: sampling/elicitation (server→client requests) — needs
  interleaved dispatch beyond the v1 single-threaded loop.
- Q-MCP-002: `notifications/cancelled` + progress tokens — required
  before long-blocking tools (permission prompts) are polite citizens.
- Q-WS-001: JVM kernel fragmentation/ping-keepalive parity follow-up.
- Q-MCP-003: OAuth 2.1 resource-server support on streamable HTTP.
