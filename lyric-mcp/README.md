# lyric-mcp

Model Context Protocol (MCP) client and server for Lyric, built on
[`lyric-jsonrpc`](../lyric-jsonrpc). Implements protocol revision
`2026-07-28` (primary), accepting `2025-06-18` during version negotiation
— the stateless-core revision (see "Migrating from 2025-06-18" below).
See `docs/62-jsonrpc-mcp.md` §5 and
`docs/64-mcp-2026-stateless-migration.md` for the agreed build spec this
library implements. First consumer: `nichobbs/cloud-agents`' in-container
permission-callback MCP server.

> **Status**: `@experimental`. Implemented and tested on both
> `--target dotnet` and `--target jvm` (`lyric test --manifest
> lyric-mcp/lyric.toml [--target jvm --no-default-features --features
> jvm]`), including real spawned-child-process round trips and call
> deadlines against silent and late servers. See "Known JVM gaps" for the
> history of the JVM target.

## Migrating from `2025-06-18` (stateless core, docs/64)

The `initialize`/`notifications/initialized` handshake is no longer
required before anything else works — every request (`tools/list`,
`tools/call`, ...) is answerable from the very first message. `initialize`
remains answerable (for legacy-peer tolerance) but no longer gates
readiness, and `Mcp.serverNotInitialized` / the `-32002` "not initialized"
error no longer exist — there is no more "not initialized" state to report.
`server/discover` is the stateless replacement for capability discovery;
`Mcp.Client.connectTransport`/`connectStdio` no longer perform any round
trip (call `Mcp.Client.discoverServer` afterward if you want
`client.serverInfo` populated). `McpClient` no longer carries a
`protocolVersion` field — there is nothing to negotiate per-connection
anymore. See `docs/64-mcp-2026-stateless-migration.md` §3 and §6 for the
full design and breaking-change notes.

A tool that needs mid-call user input instead of finishing in one round
trip (the permission-prompt case this library exists for) registers via
the new `Mcp.Server.addResumableTool`/`Mcp.McpResumableToolHandler`
instead of `addTool`/`McpToolHandler` — see docs/64 §3.1 and the Quick
start section below.

## Platform parity

| Package | `.NET` | JVM |
|---|---|---|
| `Mcp` (types, encode/decode) | 36/36 serialization tests | 36/36 |
| `Mcp.Server` (`serveStdio`) | in-memory lifecycle tests (`tests/mcp_tests.l`, 31/31 with the client cases) | 31/31 |
| `Mcp.Client` (`connectStdio`, call deadlines) | tested against real spawned processes (7/7 process tests) | 7/7 |
| `Mcp.Stdio` (`PipedNdjsonTransport`) | full | full |
| `Std.Process` piped seam (`spawnPiped`, `pipedReadLine`, `pipedReadLineWithin`, `pipedWriteLine`, ...) | tested with real `cat`/`sh` children | same, plus `lyric-compiler/jvm/piped_process_jvm_main.l` |

`Mcp.Server`'s protocol logic (`server/discover` capability derivation,
tools/resources/prompts dispatch, resumable-tool `input_required`/resume
handling, batch handling) is exercised end-to-end by `tests/mcp_tests.l`
over an in-memory transport pair — no process or socket involved.

## Call deadlines

Every `Mcp.Client` operation waits at most the client's call timeout for
its response — 60 s by default (`JsonRpc.defaultCallTimeoutMs`), changed
with `setClientCallTimeout(client, ms)` (1 ms to 24 h). A server that
never answers, and never exits, can no longer hang the client (#7451).
The tool-call operations, which a slow tool can legitimately stretch,
also take a per-call timeout:

```lyric
pub func setClientCallTimeout(client: inout McpClient, timeoutMs: in Int): Unit
pub func callToolWithin(client: inout McpClient, name: in String, args: in Option[JsonValue], timeoutMs: in Int): Result[McpToolResult, String]
pub func callResumableToolWithin(client: inout McpClient, name: in String, args: in Option[JsonValue], timeoutMs: in Int): Result[McpToolCallOutcome, String]
pub func resumeToolCallWithin(client: inout McpClient, name: in String, requestState: in String, inputResponses: in JsonValue, timeoutMs: in Int): Result[McpToolCallOutcome, String]
```

A timed-out call returns `Err("'<method>' failed: timed out after N ms
awaiting response to '<method>'")`. Over the stdio transport the wait is
`Std.Process.pipedReadLineWithin`; the child is left running (call
`disconnect` to stop it), and if its answer arrives later it is dropped
rather than handed to the next call. A tool that waits on a person
should answer `input_required` (docs/64 §3.1) rather than hold the call
open past the deadline.

## Known JVM gaps

All three gaps below are resolved; they are kept as a record of what was
investigated.

### 1. `Std.Process`'s piped-spawn kernel: reads didn't reliably work on JVM — FIXED (#6135)

The JVM kernel's `pipedReadLine` originally went through
`BufferedReader.readLine()` and failed unreliably against a live child (a
spurious immediate end of stream, or a block past any deadline). It now
drains stdout with the `InputStream.available()`-polled,
`readNBytes`-into-a-`ByteArrayOutputStream` technique
`process_capture_host.l` uses, never calling a blocking `Reader` method;
see `lyric-stdlib/std/_kernel_jvm/process_piped_host.l`'s module header.
The same loop carries the deadline for `pipedReadLineWithin` (#7451).

### 2. `lyric-jsonrpc`'s JVM gap: `JObject`/`JArray` results over `runLoop` — no longer reproduces

`lyric-jsonrpc/README.md` documented `runLoop` failing on the JVM to
thread a container-shaped result back through dispatch (#6123). Every
`lyric-jsonrpc` and `lyric-mcp` test now passes under `--target jvm`, and
CI runs both suites on the JVM.

### 3. The test suite failed to type-check under `--target jvm` — no longer reproduces

Every cross-package name from the `Lyric.JsonRpc` workspace dependency
and from this project's own packages used to come back `T0010`/`T0020`
unknown when compiling the test files for the JVM. It does not reproduce
with the CLI as CI runs it (`dotnet lyric.dll`); `tests/
mcp_stdio_process_tests.l`, once gated to `--target dotnet` on account of
gaps #1 and #3, now runs on both targets.

## Upstream compiler bugs found and worked around (`.NET`)

Two new, real, self-hosted-compiler bugs were found and root-caused while
building `Mcp.Server` — both `--target dotnet`-specific, both distinct
from anything `lyric-jsonrpc/README.md` already documents, and both
worked around in this library's own source (not papered over with a test
change). Filed upstream against the compiler, not against this library's
logic.

**1. A package-qualified constant reference used *inside* an `impl ...
for McpServer { }` method body crashes the whole type at JIT time.**
`RpcError(code = JsonRpc.invalidParams, ...)` written directly inside
`impl RpcHandler for McpServer { func onRequest(...) { ... } }` compiled
cleanly but crashed **every** call to `onRequest` at runtime — even
requests whose dispatch never reached the line with the qualified
reference — with `System.InvalidProgramException`, surfaced by
`JsonRpc.dispatchRequest`'s `catch Bug` as a `-32603 Internal error`
response. Root-caused by bisection in a from-scratch two-file minimal
repro outside this library (removing pieces of `onRequest` one at a time
until the crash disappeared, then re-adding pieces one at a time until it
reappeared): a same-shape `impl` block using bare `Int` literals instead
of qualified constants works fine, and a plain top-level `func` (not
inside any `impl` block) using the *exact same* qualified references also
works fine — the trigger is specifically a package-qualified constant
textually inside an `impl` method body. **Workaround**: `server.l` and
`client.l` route every such reference through a same-package,
unqualified `func` (`invalidParamsCode()`, `methodNotFoundCode()` in
`server.l`; see their doc comments for the full account) called from
inside the `impl` block, rather than writing the qualified form there
directly.

**2. A `pub val Int` read from a workspace-restored cross-DLL dependency
silently evaluates to `0` at runtime — no compile error, no exception.**
Confirmed by direct experiment: `handleToolsCall`'s "unknown tool" branch,
using `code = JsonRpc.invalidParams` even *outside* an `impl` block (i.e.
with bug #1 above worked around), measurably produced a wire response
with `"code":0` instead of `-32602`. The same pattern reading
`Mcp.protocolVersionLatest` — a `pub val` from `Mcp`, a *sibling package
compiled together in the same project*, not a separately-restored
workspace DLL — works correctly. Only the cross-DLL case (reading a
`pub val` from `Lyric.JsonRpc`, resolved via `{ workspace = true }` and
compiled to a separate assembly) exhibits this. **Workaround**:
`invalidParamsCode()` / `methodNotFoundCode()` (`server.l`) and
`clientMethodNotFoundCode` (`client.l`) return **hardcoded `Int`
literals** (`-32602`, `-32601`) instead of reading `JsonRpc`'s `pub val`s
at all — safe because JSON-RPC 2.0's standard error codes are fixed by
spec and will never change. This is a narrower, `.NET`-side, silent-value
cousin of the `T0020 unknown name` compile-time symptom noted in
"Local dependency mechanism" below (also a workspace cross-DLL `pub val`
resolution issue, but a *compile-time* failure there rather than this
*run-time* silent-zero) — both point at the same general area
(workspace-restored-dependency constant resolution) being under-tested
upstream, without a single shared root cause established.

## Local dependency mechanism

`lyric-mcp/lyric.toml` depends on the sibling `lyric-jsonrpc` package via
the workspace form (docs/38-workspace.md §3.1), the same mechanism every
other in-repo ecosystem library uses for a sibling dependency (e.g.
`lyric-ws` -> `Lyric.Auth`, `lyric-jobs` -> `Lyric.Resilience`):

```toml
[dependencies]
"Lyric.JsonRpc" = { workspace = true }
```

This repository's root `lyric.toml` declares `[workspace]` with an
`exclude` list that does **not** mention `lyric-jsonrpc` or `lyric-mcp`,
so both are auto-discovered workspace members by walking the directory
tree for `lyric.toml` files (docs/38 §2.2) — no explicit member listing
is needed. `lyric build`/`lyric test` resolve `Lyric.JsonRpc` to
`../lyric-jsonrpc`'s compiled source directly; there is no `path = "..."`
dependency anywhere in this manifest (the workspace form is preferred
over `path` inside a workspace per docs/38 §3.1, and is what actually
builds cleanly with `lyric build --manifest lyric-mcp/lyric.toml` —
verified directly, not assumed).

**A related, separate compile-time symptom of the same general area**
(also found while building this library, distinct from the two runtime
bugs in "Upstream compiler bugs found and worked around" above): an
*unqualified* reference to a `pub val` from `Lyric.JsonRpc` (e.g. plain
`invalidParams` instead of `JsonRpc.invalidParams`) sometimes fails to
resolve at all (`T0020 unknown name`), even with the defining package
correctly `import`ed, in a project that consumes `Lyric.JsonRpc` via
`{ workspace = true }` — reproduced in a from-scratch minimal repro
(a single-package project depending only on `Lyric.JsonRpc`) where
*all five* of `JsonRpc`'s standard error-code constants failed to
resolve unqualified, while the fully-qualified form (`JsonRpc.invalidParams`)
resolved without error every time. Not fully root-caused (the same
unqualified form resolves fine for *some* call sites and not others in
ways that were not isolated to a single pattern), but qualifying every
`JsonRpc`-defined constant reference with its package name
(`JsonRpc.invalidParams`, `JsonRpc.methodNotFound`, ...) reliably avoids
the compile error — used throughout `lyric-mcp/src/server.l` and
`client.l` (outside `impl` bodies; see bug #1 above for why not inside
them) wherever such a constant is still read via `JsonRpc.*` rather than
hardcoded per bug #2.

## Packages

| Package | Purpose |
|---|---|
| `Mcp` | Shared types: protocol version negotiation, content blocks (`McpContent`), tool/resource/prompt wire shapes, the `McpToolCallOutcome`/`McpResumableToolHandler` `input_required` shapes, and every JSON encode/decode helper both the server and client use |
| `Mcp.Server` | `McpServer` builder (`newServer` / `addTool` / `addResumableTool` / `addResource` / `addPrompt`) + `serveStdio` |
| `Mcp.Client` | `McpClient`, `connectStdio` (and the lower-level `connectTransport`), `discoverServer`, `listTools` / `callTool` / `callResumableTool` / `resumeToolCall` / `listResources` / `readResource` / `listPrompts` / `getPrompt` / `ping` / `disconnect`; deadlines: `setClientCallTimeout`, `callToolWithin` / `callResumableToolWithin` / `resumeToolCallWithin` |
| `Mcp.Stdio` | Client-side piped-child-process NDJSON transport (`Std.Process.PipedProcess` wrapped as a `JsonRpc.RpcTransport`, reusing `JsonRpc.Stdio`'s framing helpers rather than re-implementing them) |

## Installation

```toml
[dependencies]
"Lyric.Mcp" = { path = "../lyric-mcp" }        # outside this workspace
# or, inside this workspace:
"Lyric.Mcp" = { workspace = true }
```

## Quick start

### Serving tools/resources/prompts over stdio (server)

```lyric
import Std.Core
import Std.Collections
import JsonRpc.Json
import Mcp
import Mcp.Server

record EchoToolHandler {
}

impl McpToolHandler for EchoToolHandler {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    match args {
      case Some(a) -> match getString(a, "text") {
        case Some(t) -> Ok(value = toolTextResult(t))
        case None -> Err(error = "missing 'text' argument")
      }
      case None -> Err(error = "missing 'text' argument")
    }
  }
}

func main(): Unit {
  val server = newServer(McpImplementation(name = "my-server", version = "0.1.0"))
  val schema = JObject(fields = [JsonField(name = "type", value = JString(value = "object"))])
  addTool(server, McpToolDef(name = "echo", description = "Echoes text back", inputSchema = schema, handler = EchoToolHandler()))
  match serveStdio(server) {
    case Ok(_) -> ()
    case Err(e) -> println("serveStdio ended: " + e)
  }
}
```

### A resumable tool (permission-prompt pattern, docs/64 §3.1)

```lyric
import Std.Time

// `stateKey` is 32+ random bytes that never leave the server (load it from
// a secret store; rotating it invalidates every outstanding token).
record DeleteFileHandler {
  stateKey: slice[Byte]
}

impl McpResumableToolHandler for DeleteFileHandler {
  func call(args: in Option[JsonValue]): Result[McpToolCallOutcome, String] {
    val path = match args { case Some(a) -> match getString(a, "path") { case Some(p) -> p; case None -> "" }; case None -> "" }
    // Bind the pending action to this tool and a five-minute deadline.
    match sealRequestState(self.stateKey, "delete_file", path, nowEpochMillis() + 300000i64) {
      case Err(e) -> Err(error = e)
      case Ok(token) -> {
        val inputRequests = JObject(fields = [JsonField(name = "confirm", value = JBool(value = true))])
        Ok(value = InputRequired(value = McpInputRequired(inputRequests = inputRequests, requestState = token)))
      }
    }
  }

  func resume(requestState: in String, inputResponses: in JsonValue): Result[McpToolCallOutcome, String] {
    // A peer can send any requestState it likes; only a token this server
    // sealed, for this tool, before its deadline gets past here.
    match openRequestState(self.stateKey, "delete_file", requestState, nowEpochMillis()) {
      case Err(e) -> Ok(value = ToolResult(value = toolErrorResult("invalid requestState: " + e)))
      case Ok(path) -> {
        val confirmed = match getBool(inputResponses, "confirm") { case Some(b) -> b; case None -> false }
        if confirmed {
          Ok(value = ToolResult(value = toolTextResult("deleted " + path)))
        } else {
          Ok(value = ToolResult(value = toolErrorResult("not confirmed")))
        }
      }
    }
  }
}

// registered with addResumableTool(server, McpResumableToolDef(name = "delete_file", ...))
// alongside the plain addTool registrations above — both dispatch through
// the same tools/call method and appear together in tools/list.
```

`requestState` travels through the peer, which can fabricate, alter or
replay it: `Mcp.Server` only checks that it is 1 to
`maxRequestStateLength` (8192) characters before routing to `resume`.
`sealRequestState(key, toolName, payload, expiresAtEpochMillis)` produces
`v1.<base64 payload>.<expiry>.<hex HMAC-SHA-256>`, and
`openRequestState(key, toolName, token, nowEpochMillis)` returns the
payload only when the MAC matches (compared in constant time) for the same
key and tool name and the deadline has not passed. The payload is
authenticated, not encrypted, so keep secrets out of it. Sealing does not
stop the same peer from replaying a live token before it expires; a tool
whose action must happen at most once should also record the tokens it
has consumed. A handler whose `requestState` carries nothing
security-relevant can still use a plain string.

On the client side, `callResumableTool`/`resumeToolCall` return `Err` for
an `input_required` result whose `requestState` is missing, not a string,
empty or longer than `maxRequestStateLength`.

### Connecting to a server (client)

```lyric
import Std.Core
import Std.Collections
import JsonRpc.Json
import Mcp.Client

func main(): Unit {
  match connectStdio("my-mcp-server", newList()) {
    case Err(e) -> println("connect failed: " + e)
    case Ok(clientVal) -> {
      var client = clientVal
      // Optional (docs/64 §3.3) — populates client.serverInfo and returns
      // serverInfo + capabilities.
      match discoverServer(client) {
        case Ok(discovered) -> {
          println("connected to " + discovered.serverInfo.name + " " + discovered.serverInfo.version)
          if discovered.capabilities.hasTools {
            println("server advertises tools")
          }
        }
        case Err(e) -> println("server/discover failed: " + e)
      }
      match listTools(client) {
        case Ok(tools) -> {
          var i = 0
          while i < tools.count {
            println(tools[i].name + ": " + tools[i].description)
            i = i + 1
          }
        }
        case Err(e) -> println("listTools failed: " + e)
      }
      val args = JObject(fields = [JsonField(name = "text", value = JString(value = "hello"))])
      match callTool(client, "echo", Some(value = args)) {
        case Ok(result) -> println("isError=" + result.isError.toString())
        case Err(e) -> println("callTool failed: " + e)
      }
      disconnect(client)
    }
  }
}
```

## Spec deviations

- **`McpToolDef`/`McpResourceDef`/`McpPromptDef` carry an interface-typed
  `handler` field**, not the function-typed field
  (`(Option[JsonValue]) -> Result[McpToolResult, String]`)
  docs/62-jsonrpc-mcp.md §5.1 specs. `lyric-jsonrpc/README.md` "Known
  upstream issues" #3 documents a real self-hosted-compiler bug: a
  closure stored in a record field (or passed as a function-typed
  parameter) from a *different* package than the field's declaring
  package fails at runtime on the JVM backend. Every application
  registering a handler necessarily lives in a different package than
  `Mcp`, so the function-typed field is exactly the buggy shape.
  `McpToolHandler`/`McpResourceHandler`/`McpPromptHandler` interfaces
  sidestep it — the same fix `JsonRpc`'s own `RpcHandler`/`RpcTransport`
  and `lyric-cache/src/cache.l`'s `Clock` already apply for the identical
  reason.
- **Whole-batch rejection is not implemented as a distinct MCP-level
  error**, though docs/62-jsonrpc-mcp.md §5.1 specs "the MCP layer never
  emits batches and rejects inbound ones." The shipped `lyric-jsonrpc`
  `RpcHandler`/`RpcTransport` boundary already implements JSON-RPC 2.0 §6
  batching *generically* inside `runLoop`, fanning a batch array out into
  independent `onRequest`/`onNotification` calls before `McpServer` ever
  sees anything — there is no hook in the current `RpcHandler` interface
  for a handler to detect "this call is part of an inbound batch" and
  reject the envelope as a whole. Adding one would be a new cross-cutting
  feature in `lyric-jsonrpc`, out of scope for this track's "small,
  test-proven fix only" boundary on that library.
- **Resource contents are text-only** (`McpResourceContent` has no
  `BlobResourceContents`/base64 binary variant), and **prompt message
  content omits the `AudioContent` block** (only `text`/`image`/`resource`
  are modeled, matching `McpContent`). Both are scope cuts, not
  intentional protocol restrictions — extending `McpContent` and
  `McpResourceContent` to cover the remaining schema variants is
  straightforward follow-up work.
- **Milestone 2 (streamable HTTP transport, docs/62 §5.3, updated for
  `2026-07-28` in docs/64 §4) is not implemented** — see "Sequencing"
  below.
- **The Tasks extension (docs/64 §5) is not implemented** — poll-based
  long-running (but non-interactive) work has no dedicated support yet;
  use a resumable tool (`addResumableTool`) for interactive long-blocking
  work instead.

## Out of scope, per docs/64 §1/§7

`2026-07-28` deprecates Roots, Sampling, and Logging outright — these were
already unimplemented (docs/62 §5.3 "out of scope v1"), so there is
nothing to migrate off. OAuth 2.1 resource-server support on the
streamable HTTP transport is still fully out of scope (docs/64 §7,
Q-MCP-003) — building it is its own epic, orthogonal to this library's
wire-protocol migration.

## Sequencing

Phase A (docs/64 §3, stateless core: no more `initialize` gate,
`server/discover`, `input_required` multi-round-trip via
`addResumableTool`/`McpResumableToolHandler`) is implemented and tested on
`--target dotnet` and `--target jvm`. **Streamable HTTP (docs/64 §4, Phase B) and the Tasks
extension (docs/64 §5, Phase C) are not attempted in this track** — each
is left for a dedicated follow-up PR per docs/64 §2's phasing.

## Package layout

```
lyric-mcp/
  lyric.toml                 package manifest
  README.md                  this file
  src/
    mcp.l                     Mcp        (shared types, encode/decode)
    server.l                  Mcp.Server (McpServer, serveStdio)
    client.l                  Mcp.Client (McpClient, connectStdio, ...)
    stdio.l                   Mcp.Stdio  (client-side piped NDJSON transport)
  tests/
    mcp_tests.l                       Mcp.McpTests (in-memory lifecycle)
    mcp_serialization_tests.l         Mcp.McpSerializationTests (pure JSON shapes)
    mcp_stdio_process_tests.l         Mcp.McpStdioProcessTests (real spawned processes, both targets)
```

## See also

- `docs/62-jsonrpc-mcp.md` — the agreed build spec (§5 covers this library)
- `lyric-jsonrpc/README.md` — the JSON-RPC 2.0 peer this library builds on, including call deadlines and its JVM history
- [Model Context Protocol specification](https://modelcontextprotocol.io/specification/2025-06-18) (external reference)
