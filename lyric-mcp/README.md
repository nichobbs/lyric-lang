# lyric-mcp

Model Context Protocol (MCP) client and server for Lyric, built on
[`lyric-jsonrpc`](../lyric-jsonrpc). Implements protocol revision
`2025-06-18` (primary), accepting `2025-03-26` during version negotiation.
See `docs/62-jsonrpc-mcp.md` §5 for the agreed build spec this library
implements. First consumer: `nichobbs/cloud-agents`' in-container
permission-callback MCP server.

> **Status**: `@experimental`. `.NET` is fully implemented and tested:
> all 44 tests across all three suites pass on `--target dotnet`
> (`./bin/lyric test --manifest lyric-mcp/lyric.toml`), including a real
> spawned-child-process round trip. **JVM is not currently usable for this
> library at all** — every one of this library's own test files fails to
> even type-check under `--target jvm` (see "Known JVM gaps" #3 below), a
> deeper and more fundamental gap than anticipated going in. See "Known
> JVM gaps" before depending on the JVM target for anything in this
> library.

## Platform parity

| Package | `.NET` | JVM |
|---|---|---|
| `Mcp` (types, encode/decode) | full, 21/21 pure-serialization tests pass | pure Lyric, no I/O — but see gap #3: this library's own test suite does not type-check under `--target jvm` at all, so this is unverified in practice, not merely undertested |
| `Mcp.Server` (`serveStdio`) | full, 18/18 in-memory lifecycle tests pass | unverified (gap #3) |
| `Mcp.Client` (`connectStdio`) | full, tested against a real spawned process (5/5 process tests) | unverified (gap #3); the underlying `Std.Process` piped-spawn kernel also has its own separate, real JVM gap (#1) even setting #3 aside |
| `Mcp.Stdio` (`PipedNdjsonTransport`) | full | unverified (gap #3); also gap #1 |
| `Std.Process.spawnPiped` / `pipedReadLine` / `pipedWriteLine` (stdlib seam this library needed and added) | full, tested with a real `cat` subprocess | compiles; **spawning and writing work, reading back a line from the child does not reliably work** — gap #1 |

`Mcp.Server`'s protocol logic (initialize negotiation, capability
derivation, tools/resources/prompts dispatch, the `serverNotInitialized`
lifecycle gate, batch handling) is exercised end-to-end by
`tests/mcp_tests.l` over an in-memory transport pair — no process or
socket involved. It is `.NET`-only in practice today (gap #3), though
nothing about its own design is target-specific.

## Known JVM gaps

### 1. `Std.Process`'s piped-spawn kernel: reads don't reliably work on JVM

This library needed a stdlib seam `Std.Process` did not have: a
long-lived, bidirectional piped child process (`Std.Process.run` blocks
until exit; `Std.Process.runCapture` only returns output after the
process has already finished — neither fits an MCP client that must
write to and read from a server process interleaved, indefinitely). It
was added in this track, in `lyric-stdlib/std/_kernel/process_piped_host.l`
(`.NET`) and `lyric-stdlib/std/_kernel_jvm/process_piped_host.l` (JVM),
with a public `Std.Process` surface: `spawnPiped`, `pipedReadLine`,
`pipedWriteLine`, `pipedIsAlive`, `pipedKill`, `pipedWaitExit`,
`pipedExitCode`, `pipedCloseStdin`, `pipedClose`.

**The `.NET` kernel works correctly and is tested** — `spawnPiped`
followed by `pipedWriteLine`/`pipedReadLine` round-trips real data
through a real `cat` subprocess repeatably (`lyric-mcp/tests/
mcp_stdio_process_tests.l`, and `Std.Process` itself gained no dedicated
stdlib-level test in this track — that's `lyric-mcp`'s job as the first
consumer, tracked as a stdlib test-coverage gap worth closing directly in
`lyric-stdlib/tests/` in a follow-up).

**The JVM kernel spawns and writes correctly but the read side is
unreliable.** `pipedIsAlive` and `pipedWriteLine` behave exactly as
expected (the child process starts, stays alive, and the write call
raises no error), but a subsequent `pipedReadLine` against a process that
is still alive and has real bytes queued on its stdout either returns a
spurious immediate `None` (as if the stream had hit clean EOF) or blocks
past any reasonable deadline, depending on the exact code path taken —
reproduced with the simplest possible case (`cat`, no arguments, one
short line written then read back).

Two specific candidate root causes were investigated and *ruled out* by
direct experiment (see `process_piped_host.l`'s module doc for the full
account):

1. The `ProcessBuilder.redirectError(Redirect.INHERIT)` call interfering
   with the stdout pipe — removing it entirely did not change the
   symptom.
2. The nested `JBufferedReader.new(JInputStreamReader.new(stream))` /
   `JPrintWriter.new(JOutputStreamWriter.new(stream), true)` constructor
   calls — rebinding each inner `.new()` result through an explicit
   intermediate `val` (this repo's standard convention for exactly this
   shape) changed the observed failure mode from "always immediate
   spurious EOF" to "sometimes blocks," but did not fix it.

Not yet tried, and the most promising next step: `process_capture_host.l`'s
JVM kernel already reliably drains a child's stdout via
`InputStream.available()` polling + `readNBytes` into a
`ByteArrayOutputStream` (used by `Std.Process.runCapture`, which works).
A byte-level rewrite of the piped kernel's read side along those lines,
instead of `BufferedReader`, is the most likely fix — tracked as a
follow-up rather than attempted in this track, given the isolation work
above did not point at a single clear root cause within budget.

**Practical consequence:** `Mcp.Client.connectStdio` /
`Mcp.Stdio.newPipedNdjsonTransport` should be treated as `.NET`-only
until this is resolved. `tests/mcp_stdio_process_tests.l` — the real
spawned-process test — is annotated `@cfg(target = "dotnet")`
(docs/24-build-features.md "whole-file gating") specifically because of
this gap: leaving it registered unconditionally would make `lyric test
--manifest lyric-mcp/lyric.toml --target jvm` *hang* rather than fail
(the read call can block past any deadline), which is a worse CI citizen
than a documented, visible gap. This mirrors `lyric-ws/tests/
ws_jvm_e2e_test.l`'s precedent for an analogous real, unresolved JVM
issue, adapted to a `@cfg` gate (which keeps the file registered and
running on the target it's proven on) rather than omitting the file from
`[project.tests]` entirely.

### 2. `lyric-jsonrpc`'s known JVM gap: `JObject`/`JArray` results over `runLoop`

Inherited, not introduced by this library: `lyric-jsonrpc/README.md`
"Known upstream issues" documents that `JsonRpc.runLoop`, on the JVM
backend only, fails to correctly thread a **container-shaped** (`JObject`
or `JArray`) result value from a cross-package `RpcHandler.onRequest`
call back through its own dispatch machinery (`Jvm.Codegen: match not
exhaustive`, no further detail available). Every MCP response that isn't
a bare scalar — which is effectively every MCP response, since
`InitializeResult`, `ListToolsResult`, `CallToolResult`, etc. are all
JSON objects — would hit this if `tests/mcp_tests.l` could even compile
under `--target jvm` (it cannot — see gap #3), so this is documented as
inherited-and-still-applicable rather than independently re-verified
here.

### 3. This library's entire test suite fails to type-check under `--target jvm`

Discovered while trying to verify gap #2 above: `./bin/lyric test
--manifest lyric-mcp/lyric.toml --target jvm` fails all three test files
at the *type-checking* stage, not just at runtime — every cross-package
name from **both** the `Lyric.JsonRpc` workspace dependency (`JsonValue`,
`RpcPeer`, `newPeer`, `writeValue`, `parseValue`, `JsonField`, `JInt`,
`getArray`, `asArray`, `runLoop`, `encodeRequest`, `RpcRequest`, `IntId`,
...) **and** this project's own sibling packages (`Mcp`/`Mcp.Server`/
`Mcp.Client`/`Mcp.Stdio` importing each other) comes back `T0010 unknown
type name` / `T0020 unknown name`. `lyric-mcp/src/*.l` themselves compile
fine (`lyric build --manifest lyric-mcp/lyric.toml --target jvm`
succeeds) — the failure is specific to the *test-file* compilation
pathway. This looks like a deeper, more fundamental gap than the
per-symbol issues below: a project that is itself multi-package *and*
depends on a workspace dependency that is itself multi-package may simply
not have been exercised under `--target jvm` before in this repository
(`lyric-jsonrpc`, the first library to add this kind of workspace
dependency, has no *further* dependency of its own to compose with).
Manually pre-building `lyric-jsonrpc` for `--target jvm`
(`lyric build --manifest lyric-jsonrpc/lyric.toml --target jvm`) before
retrying made no difference, ruling out a stale-artifact explanation.
Not root-caused further within this track's budget — flagged here as the
most consequential JVM finding of this track, superseding gap #2's
narrower scope (a `--target jvm` test run cannot even reach the point
where gap #2 would matter). `--target jvm` runs against `lyric-mcp`
should be treated as **entirely unverified**, not "known-partial," until
this is investigated.

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
unqualified `func` (`notInitializedCode()`, `invalidParamsCode()`,
`methodNotFoundCode()` in `server.l`; see their doc comments for the full
account) called from inside the `impl` block, rather than writing the
qualified form there directly.

**2. A `pub val Int` read from a workspace-restored cross-DLL dependency
silently evaluates to `0` at runtime — no compile error, no exception.**
Confirmed by direct experiment: `handleToolsCall`'s "unknown tool" branch,
using `code = JsonRpc.invalidParams` even *outside* an `impl` block (i.e.
with bug #1 above worked around), measurably produced a wire response
with `"code":0` instead of `-32602`. The same pattern reading
`Mcp.serverNotInitialized` — a `pub val` from `Mcp`, a *sibling package
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
| `Mcp` | Shared types: protocol version negotiation, MCP-specific error codes, content blocks (`McpContent`), tool/resource/prompt wire shapes, and every JSON encode/decode helper both the server and client use |
| `Mcp.Server` | `McpServer` builder (`newServer` / `addTool` / `addResource` / `addPrompt`) + `serveStdio` |
| `Mcp.Client` | `McpClient`, `connectStdio` (and the lower-level `connectTransport`), `listTools` / `callTool` / `listResources` / `readResource` / `listPrompts` / `getPrompt` / `ping` / `disconnect` |
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

### Connecting to a server (client, `.NET` only — see "Known JVM gaps")

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
  test-proven fix only" boundary on that library. What *is* true, and
  verified by `tests/mcp_tests.l`'s batch tests: every element of an
  inbound batch is still independently subject to MCP's own rules (the
  `serverNotInitialized` lifecycle gate, unknown-method/unknown-tool
  errors, ...) — a batch cannot be used to bypass them, it just isn't
  specially rejected as a whole envelope.
- **Resource contents are text-only** (`McpResourceContent` has no
  `BlobResourceContents`/base64 binary variant), and **prompt message
  content omits the `AudioContent` block** (only `text`/`image`/`resource`
  are modeled, matching `McpContent`). Both are scope cuts, not
  intentional protocol restrictions — extending `McpContent` and
  `McpResourceContent` to cover the remaining schema variants is
  straightforward follow-up work.
- **Milestone 2 (streamable HTTP transport, docs/62 §5.3) is not
  implemented** — see "Sequencing" below.

## Out of scope (v1, per docs/62 §5.3)

Sampling and elicitation (server -> client requests), `listChanged` /
resource-subscription notifications, roots, OAuth on the HTTP transport,
and cancellation/progress notifications (`notifications/cancelled`) are
all out of scope for this track, matching the agreed spec.

## Sequencing

This track (PR-4 in docs/62-jsonrpc-mcp.md §8) implements the **stdio
transport only** (v1, required). **Streamable HTTP (milestone 2, PR-5) is
not attempted** — per the task brief, it was explicitly scoped to "attempt
only after stdio is fully done and tested," and stdio (plus the
`Std.Process` piped-spawn stdlib seam it needed, including chasing down
the JVM read-side gap documented above) consumed the available budget for
this track. It is left for a dedicated follow-up PR, building on
`lyric-web`'s SSE support (server side) and `Std.Http` (client side) per
docs/62 §5.3.

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
    mcp_stdio_process_tests.l         Mcp.McpStdioProcessTests (real spawned process, dotnet only)
```

## See also

- `docs/62-jsonrpc-mcp.md` — the agreed build spec (§5 covers this library)
- `lyric-jsonrpc/README.md` — the JSON-RPC 2.0 peer this library builds on, including its own documented JVM gaps
- [Model Context Protocol specification](https://modelcontextprotocol.io/specification/2025-06-18) (external reference)
