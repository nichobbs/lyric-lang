# 62 — JSON-RPC 2.0 and Model Context Protocol libraries

Status: specced in D129. lyric-jsonrpc, lyric-mcp (stdio transport),
the stdlib seams, and the lyric-ws dotnet backend (#778) are implemented;
streamable HTTP (§5.3 milestone 2) and the open questions remain. JVM
gaps are tracked in #6118–#6124, #6127, #6133–#6136; the lyric-jsonrpc
and lyric-mcp suites pass on the JVM and run there in CI since #7451,
which also added call deadlines (§3, D-progress-1007). First consumer:
`nichobbs/cloud-agents`' in-container permission-callback MCP server
(see that repo's `docs/phase6-mcp-callbacks.md`). This sketch is the
agreed build spec for three coordinated tracks; each track lands as its
own PR series and cites this doc.

**Superseding note (2026-07-30):** MCP spec revision `2026-07-28`
shipped — the largest protocol revision since MCP launched (stateless
core, removed `initialize` handshake, extensions framework). §5.3's
still-open "milestone 2" (streamable HTTP) and Q-MCP-001/Q-MCP-002 below
are addressed by targeting the new revision directly rather than
`2025-06-18`; see `docs/64-mcp-2026-stateless-migration.md` for the
migration plan. Q-MCP-003 (OAuth) stays open and unaddressed by either doc.

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

_Moved to the stdlib as `Std.JsonValue` (D145, #7832); the section below is
the original design, which the stdlib module keeps unchanged._

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

pub union ReceiveOutcome { case RpcMessage(text: String); case RpcEndOfStream; case RpcTimedOut }

pub interface RpcTransport {
  /// Block until the next complete message arrives. None ⇒ clean EOF.
  func receive(): Result[Option[String], String]
  /// Wait at most timeoutMs for the next complete message; a timeout loses
  /// nothing (a partly received message stays buffered). (#7451)
  func receiveWithin(timeoutMs: in Int): Result[ReceiveOutcome, String]
  func send(payload: in String): Result[Unit, String]
  func close(): Unit
}

pub record RpcPeer { ... }   // constructed over an RpcTransport + RpcHandler
pub func newPeer(transport: in RpcTransport, handler: in RpcHandler): RpcPeer          // call timeout 60 s
pub func newPeerWithTimeout(transport: in RpcTransport, handler: in RpcHandler, callTimeoutMs: in Int): RpcPeer
pub func setCallTimeout(peer: inout RpcPeer, callTimeoutMs: in Int): Unit
pub func runLoop(peer: inout RpcPeer): Result[Unit, String]
pub func call(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]
pub func callWithin(peer: inout RpcPeer, method: in String, params: in Option[JsonValue], timeoutMs: in Int): Result[JsonValue, RpcError]
pub func notify(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[Unit, String]
```

**Call deadlines (#7451, D-progress-1007).** Every outbound call is
bounded. `call` applies the peer's call timeout (`defaultCallTimeoutMs`
= 60 000 ms, the MCP SDKs' default request timeout, unless changed with
`newPeerWithTimeout`/`setCallTimeout`); `callWithin` takes one per call.
Timeouts range over 1 ms to `maxCallTimeoutMs` (24 h), enforced by
`requires: isValidCallTimeout(...)`. The deadline is fixed when the
request is sent: each wait gives `receiveWithin` only the time left, and
inbound requests/notifications queued meanwhile do not extend it. When it
passes, the call fails with a local `RpcError` of code `requestTimedOut`
(`-32001`, in JSON-RPC's implementation-defined server-error range, as
the MCP SDKs use it) whose `data` carries `timeoutMs`; `isTimeoutError`
tests for it — this is a match on the wire-level `-32001` code alone,
not a local-vs-remote marker: a peer can legitimately send its own
`-32001` failure for an unrelated reason, and `isTimeoutError` cannot
tell the two apart (#7522 tracks typed `Mcp.Client` errors that would).
Nothing is sent to the peer — JSON-RPC 2.0 has no
cancellation. The request id is never reused, so a response that arrives
after its call timed out matches no pending call: `runLoop` and later
calls drop it as an unsolicited response rather than mis-delivering it.

`call`/`callWithin` queue any request/notification the peer sends while
they wait, in `RpcPeer.pendingQueue`, for a later `runLoop` to dispatch —
past `maxPendingMessages` (4096) queued, the in-progress call itself
fails rather than growing the queue without limit. A caller whose peer
never runs `runLoop` (`Mcp.Client`, which only ever calls
`call`/`callWithin`) must drain that queue some other way, or entries
left by one call accumulate toward the limit across every later call
(#7520 review); `JsonRpc.drainPendingQueue(peer)` dispatches or discards every
queued entry exactly as `runLoop` would, and `Mcp.Client` calls it after
every operation (§5.2).

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
the library and works; migration is Q-RPC-002 (do it once `JsonRpc.Stdio`
is proven, delete the hand-rolled framing in `lsp.l`). Its own
Content-Length framing no longer carries the UTF-8-length caveat this
paragraph used to note here: `lsp.l`'s hand-rolled framing measured
Content-Length in `String.length` (UTF-16 code units) instead of UTF-8
bytes, corrupting the stream on any non-ASCII content; #7510 rewrote it
to the same byte-exact discipline described below — `lspEncodeFrame`/
`lspScanFrame` are pure functions over `slice[Byte]`, driven against real
stdio by `lspReadFrame`/`writeLspFrame` through `Std.Console`'s
`StdinReader`/`writeStdoutBytes` (#7451).

## 4. `JsonRpc.Stdio` — framing

Two framings, one module:

- `NdjsonFraming` — one JSON message per `\n`-terminated line (the MCP
  stdio transport). Messages must not contain embedded newlines
  (`writeValue` is compact, so they never do).
- `ContentLengthFraming` — `Content-Length: N\r\n\r\n` + N bytes
  (the LSP framing), byte-accurate on UTF-8.

Both implement `RpcTransport` over this process's stdin/stdout. Inbound
framing is byte-level (#7451): the transports read raw stdin bytes
through a `ByteSource` seam — in production `Std.Console`'s
`StdinReader`, whose `readStdinWithin` bounds the wait on `dotnet` (a
dedicated `Task.Factory.StartNew(..., TaskCreationOptions.LongRunning)`
thread + `Task.Wait(int)`, not the shared thread-pool `Task.Run`, which
under pool pressure could delay the read enough to report a spurious
timeout — #7520 review) and `jvm` (a daemon platform thread + `Thread.join(long)`)
— into a `FrameBuffer`, and cut a frame at each `\n` byte (NDJSON) or after
exactly the declared body bytes (Content-Length), decoding UTF-8 only once
a frame is complete. `FrameBuffer.bytes` is a `List[Byte]` (amortised-O(1)
append), not a `slice[Byte]` — accumulating one large message split across
many small reads costs O(message size) total, not O(message size²)
(#7520 review). So `receiveWithin` can give up at its deadline without losing or
splitting a message: the bytes read so far stay in the `FrameBuffer`, and
the next receive returns the message whole. An EOF-terminated final NDJSON
line is capped at the same `MAX_MESSAGE_BYTES` (16 MiB) bound a
`\n`-terminated line is. The client side of the MCP stdio transport
(`Mcp.Stdio`, §5.2) frames a child process's piped stdout instead, bounded
by `Std.Process.pipedReadLineWithin` on all three targets — the `jvm`
kernel's deadline arithmetic runs on `System.nanoTime()` (monotonic), not
`System.currentTimeMillis()` (#7520 review). In-memory
`ByteSource`/`CharReader`/`LineReader` stand-ins cover framing round-trips
including multi-byte UTF-8 payloads, split reads, and timeouts that fall
mid-frame.

## 5. `lyric-mcp` — protocol layer

Protocol revision: `2026-07-28` primary, `2025-06-18` accepted from
peers during version negotiation (respond with the newest mutually
supported revision; refuse others per spec) — see docs/64 for the
`2026-07-28` stateless-core migration this superseded the original
`2025-06-18`/`2025-03-26` scheme with.

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
errors per spec. **Superseded by docs/64 §3.2**: the readiness gate and
`-32002` error described here were deleted as part of the `2026-07-28`
stateless-core migration — every request is now answerable immediately,
with no `initialize`/`initialized` handshake required first.

### 5.2 Client surface

```lyric
pub record McpClient { ... }
pub func connectStdio(command: in String, args: in List[String]): Result[McpClient, String]
   // spawns the server process; per docs/64 §3.3 (2026-07-28 stateless
   // core, superseding this passage), performs no initialize/initialized
   // round trip at all — call discoverServer afterward if you want
   // serverInfo populated
pub func listTools(client: inout McpClient): Result[List[McpToolInfo], String]
pub func callTool(client: inout McpClient, name: in String, args: in Option[JsonValue]): Result[McpToolResult, String]
pub func listResources / readResource / listPrompts / getPrompt / ping / disconnect
pub func setClientCallTimeout(client: inout McpClient, timeoutMs: in Int): Unit      // #7451
pub func callToolWithin / callResumableToolWithin / resumeToolCallWithin               // per-call timeout
```

Every client operation is bounded by the client's call timeout (the
`JsonRpc` peer's, 60 s unless `setClientCallTimeout` changes it); the
tool-call operations, which a slow tool can legitimately stretch, also
take a per-call timeout through their `...Within` forms. Over the stdio
transport the wait is `Std.Process.pipedReadLineWithin`, so a server
process that never answers ends the call at its deadline (#7451); the
timed-out response, if it ever arrives, is dropped.

`McpClient` never runs `JsonRpc.runLoop` — every operation is a plain
`call`/`callWithin` round trip through a `NullHandler` (sampling/
elicitation are out of scope, docs/64 §1). A server-sent
request/notification the client sees interleaved with a call's own
response is queued (`RpcPeer.pendingQueue`, §3), so every operation
drains it right after its `callWithin` returns
(`JsonRpc.drainPendingQueue`) — otherwise entries left by one call would
accumulate across later calls toward `maxPendingMessages` and every
later call would start failing (#7520 review). A queued request gets the
ordinary dispatched answer sent back (`NullHandler` refuses every
method, so ordinarily `-32601 Method not found`); a queued notification
is dropped.

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
  _Resolved in D145: it moved into the stdlib as `Std.JsonValue`, beside
  the unchanged `Std.Json` cursor._
- Q-RPC-002: migrate `lsp.l` onto `JsonRpc` + `ContentLengthFraming`?
- Q-MCP-001: sampling/elicitation (server→client requests) — needs
  interleaved dispatch beyond the v1 single-threaded loop. _Superseded
  by docs/64 §1: MCP `2026-07-28` deprecates sampling outright, so this
  is now moot rather than resolved._
- Q-MCP-002: `notifications/cancelled` + progress tokens — required
  before long-blocking tools (permission prompts) are polite citizens.
  _Addressed by docs/64 §3 (Phase A): `2026-07-28`'s `input_required`
  multi-round-trip result shape replaces this need structurally rather
  than via cancellation/progress notifications._
- Q-WS-001: JVM kernel fragmentation/ping-keepalive parity follow-up.
- Q-MCP-003: OAuth 2.1 resource-server support on streamable HTTP.
  _Still open — docs/64 §7 explicitly keeps this out of its scope too._
