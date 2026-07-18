# lyric-jsonrpc

JSON-RPC 2.0 peer for Lyric: a strict RFC 8259 JSON value model
(`JsonRpc.Json`), a transport-agnostic envelope + peer (`JsonRpc`), and
NDJSON / Content-Length stdio framings (`JsonRpc.Stdio`). Pure Lyric,
identical on both targets except where noted below.

First consumer: `nichobbs/cloud-agents`' in-container permission-callback
MCP server. See `docs/62-jsonrpc-mcp.md` §§1-4 for the agreed build spec
this library implements; `lyric-mcp` (a follow-on track) builds the Model
Context Protocol client/server on top of this library.

> **Status**: `@experimental`. All three packages compile and have full
> test coverage. `.NET` is fully green (79/79 tests). JVM has real,
> precisely-diagnosed gaps in the self-hosted compiler (68/79 tests) — see
> "Platform parity" and "Known upstream issues" below before depending on
> the JVM target for this library.

## Platform parity

| Package | `.NET` | JVM |
|---|---|---|
| `JsonRpc.Json` (parser, writer, accessors) | 46/46 tests | 46/46 tests |
| `JsonRpc` (envelope, `RpcPeer`) | 18/18 tests | 14/18 tests — see below |
| `JsonRpc.Stdio` (NDJSON, Content-Length) | 15/15 tests | 8/15 tests — see below |

The JSON value model (`JsonRpc.Json`) is fully cross-target: every parse,
write, escape, depth-limit, and duplicate-key test passes identically on
both backends. The gaps are entirely in the self-hosted **JVM** backend's
handling of specific `while`-loop / interface-dispatch / union-nesting
shapes that the peer and framing logic happen to need; none are gaps in
this library's own design or in the MSIL backend.

## Known upstream issues

Filed against the self-hosted compiler (`lyric-compiler/`), not against
this library. Each was reproduced in isolation with a minimal two-package
repro before being routed around (or, where no safe workaround was found,
left as a documented, deterministic test failure) in this library's code —
see the referenced file/function for the in-code repro notes.

1. **Union case field named `result` fails to parse (`P0050` "expected a
   type").** Filed as [#6118](https://github.com/nichobbs/lyric-lang/issues/6118). `pub union RpcResponse { case RpcSuccess(id: RpcId, result:
   JsonValue) ... }` — the exact shape `docs/62-jsonrpc-mcp.md` §3 specs —
   fails to parse. Reproduced in isolation: a bare `case Bar(result: Int)`
   union case field fails the same way, while `result` is unremarkable as
   a record field, a function parameter, or a match-arm binding name.
   Presumably `result` collides with the reserved word available inside
   `ensures:` contract clauses, but only in this one grammar production.
   **Workaround**: the field is named `value` instead (`jsonrpc.l`'s
   `RpcResponse` union, see its NOTE comment) — matches `Std.Core`'s own
   `Ok(value: T)` convention. The wire JSON field is still `"result"` per
   the JSON-RPC 2.0 spec; only the internal Lyric identifier differs from
   the doc.

2. **A lambda literal inside an `impl` method body crashes the self-hosted
   MSIL backend.** Filed as [#6119](https://github.com/nichobbs/lyric-lang/issues/6119). `Msil.Codegen: lambda token missing for __lambda_0 —
   liftLambdasMsil pre-pass was not run`. Reproduced in isolation with a
   two-line `impl Iface for Record { func f(): T { someHigherOrderCall({
   -> ... }) } }`. The lambda-lifting pre-pass that ordinary function
   bodies get does not run for `impl` method bodies. **Workaround**:
   `stdio.l`'s `RpcTransport` impls call plain top-level functions
   (`ndjsonProductionReceive`, etc. — see the NOTE above `NdjsonTransport`'s
   `impl` block) instead of writing the lambda inline.

3. **A cross-package closure argument crashes at runtime on the JVM
   backend.** Same root-cause family as [#5329](https://github.com/nichobbs/lyric-lang/issues/5329) (its bug 3). `ClassCastException: <CallerPkg>$Lambda$N cannot be cast to
   class <CalleePkg>.Lyric$Lambda`. A function-typed parameter (`in () ->
   Int`, etc.) works fine when the lambda argument is written in the same
   package as the callee, but a lambda passed in from a *different*
   package gets wrapped in a lambda-adapter class scoped to the *caller's*
   package, which the *callee's* generated interface type then fails to
   downcast. `.NET` is unaffected. **Workaround**: `JsonRpc.Stdio`'s
   sans-IO seams (`CharReader`/`LineReader`/`StringWriter`/`LineWriter`)
   are plain interfaces, not function-typed parameters — cross-package
   `impl` dispatch on an interface does not hit this bug. This mirrors
   `lyric-cache/src/cache.l`'s own documented reason for using a
   record-of-interface `Clock` instead of a stored closure (a different,
   also-real bug with a closure captured in a record field).

4. **`Option[T] == Option[T]` does not compare structurally.** Filed as [#6120](https://github.com/nichobbs/lyric-lang/issues/6120). Two
   independently-built `Some(value = 1)` values of the same `Option[Int]`
   compare `false` with `==` — reproduced in isolation on `.NET`.
   **Workaround**: every `Option`-valued test assertion in this library
   goes through `match` instead of `== Some(...)` (see `json_tests.l`'s
   module-level NOTE).

5. **Calling a generic `Std.Core` function (`isSome`/`isNone`/
   `unwrapOption`) with several different concrete type arguments across
   one file intermittently crashes at runtime**. Filed as [#6121](https://github.com/nichobbs/lyric-lang/issues/6121). with `Msil.Codegen: match
   not exhaustive in <Pkg>.isSome__Object` / an analogous JVM message —
   even though each individual call type-checks and the same call
   sometimes runs correctly in a different `lyric test` invocation of the
   *identical* source (non-deterministic across runs, not across calls
   within one run). Reproducible enough to catch in this library's own
   CI-shaped test loop but not narrowed to a single minimal trigger.
   **Workaround**: `json_tests.l` uses fully concrete (non-generic),
   single-purpose assertion helpers (`assertIsNoneString`,
   `assertIsSomeArray`, ...) instead of one generic `assertIsSome[T]` —
   see its module-level NOTE for the full account, including the JVM-only
   `M0002 could not be monomorphised` compile error a bare generic call
   hit before the type argument was pinned via an explicitly-typed local.

6. **A `while` loop whose `match` arms mix loop-continuing and
   loop-ending control flow breaks on the self-hosted JVM backend.** Filed as [#6122](https://github.com/nichobbs/lyric-lang/issues/6122).
   `while running { match transport.receive() { case Err(e) -> { running =
   false }; case Ok(None) -> { running = false }; case Ok(Some(text)) -> {
   ... /* running stays true */ } } }` — silently stops after exactly one
   iteration on JVM regardless of which arm actually matched (reordering
   the arms instead throws `ClassCastException: Option$None cannot be cast
   to Option$Class$Some` on the *second* iteration). `.NET` is unaffected.
   Reproduced in isolation with a minimal two-package interface +
   `while`/`match`/`break` repro. **Workaround**: `jsonrpc.l`'s `runLoop`/
   `call` and `stdio.l`'s `clReadHeaders` bind the call result to an
   explicitly-typed local and match it in two separate steps (`Result`,
   then `Option`) instead of one flattened three-arm `match` — see each
   function's NOTE comment. This closed most, but not all, of the
   downstream test failures (see below).

### Remaining JVM-only test failures (not yet root-caused to a single fix)

Tracked as [#6123](https://github.com/nichobbs/lyric-lang/issues/6123) (JsonRpcTests cluster) and [#6124](https://github.com/nichobbs/lyric-lang/issues/6124) (StdioTests cluster).

After applying the workarounds above, four `JsonRpc` tests and seven
`JsonRpc.Stdio` tests still fail **only** on `--target jvm` (`.NET` is
100% green for both suites). Both clusters were narrowed by isolated
repro but not fully root-caused to one single, safely-workaroundable
compiler bug within this session's scope — documented here per this
repo's "document the gap, don't silently skip the test" convention (the
tests stay registered in `[project.tests]` and run on both targets; the
JVM failures are real, deterministic signal, not flakiness — verified
stable across repeated `lyric test --target jvm` runs):

- **`JsonRpcTests`** (4 failures: `runLoop: a request gets a matching-id
  success response`, `... methodNotFound ...`, `... invalidParams ...`,
  `... a handler panic maps to -32603 ...`): every failing case is a
  `runLoop`-dispatched request whose **result value is a `JObject` or
  `JArray`** (i.e. a JSON container, not a scalar) — reproduced in
  isolation down to a *freshly-constructed*, non-echoed `JObject`/`JArray`
  result (so it is not specific to passing params through unchanged).
  Scalar results (`JInt`, `JString`, ...) work correctly through the
  identical dispatch path, including across multiple messages in one
  `runLoop` call and across a full batch. The runtime error is
  `Jvm.Codegen: match not exhaustive` with no further detail available
  from the test harness. Removing the `try`/`catch Bug` wrapper and
  bypassing the `RpcResponse` union entirely (building the response
  `JsonValue` directly) did not change the outcome, so the fault is not in
  either of those specifically — it is somewhere in how a container-shaped
  `JsonValue` returned from a cross-package `RpcHandler.onRequest` call
  survives being threaded back through `runLoop`'s own dispatch machinery
  on JVM.
- **`StdioTests`** (7 `Content-Length` failures; all 4 `NDJSON` tests and
  the 3 non-body-reading `Content-Length` tests pass): failures show
  symptoms consistent with a `CharSource` test double's `var pos: Int`
  field not reliably surviving across separate top-level
  `clReceiveVia(reader)` calls on the same `reader` value (e.g. a second
  call appears to re-read from the start, or a `contentLength == 0`
  short-circuit path returns header text instead of an empty body).
  Binding `self.text`/`self.pos` to local `val`s at the top of the
  `CharReader.next()` implementation (the fix that resolved the unrelated
  `M0002` monomorphization issue elsewhere in this session) did not change
  the outcome. `.NET` passes all 15 cases against the identical test
  double, so the fault is JVM-specific record/interface state handling,
  not a logic bug in the framing code itself (confirmed independently by
  the JSON-level round-trip tests in `JsonTests`, which pass 46/46 on
  JVM with no interface-dispatch or loop-based state involved).

If you hit either of these clusters again while building on this library,
start from the isolated two-package repros described above rather than
re-deriving them.

## Packages

| Package | Purpose |
|---|---|
| `JsonRpc.Json` | Strict RFC 8259 JSON value model: `JsonValue` union, `parseValue`/`writeValue`, accessor helpers (`getField`, `asString`, ...) |
| `JsonRpc` | JSON-RPC 2.0 envelope types, standard error codes, `RpcHandler`/`RpcTransport` interfaces, `RpcPeer` (`runLoop`/`call`/`notify`) |
| `JsonRpc.Stdio` | NDJSON and Content-Length stdio framings over `Std.Console`/`Std.ConsoleHost` |

## Installation

```toml
[dependencies]
"Lyric.JsonRpc" = { path = "../lyric-jsonrpc" }
```

## Quick start

### Serving requests over stdio (NDJSON — the MCP transport)

```lyric
import Std.Core
import JsonRpc.Json
import JsonRpc
import JsonRpc.Stdio

record EchoHandler {
}

impl RpcHandler for EchoHandler {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    match params {
      case Some(p) -> Ok(value = p)
      case None -> Ok(value = JNull)
    }
  }

  func onNotification(method: in String, params: in Option[JsonValue]): Unit {
    // no response is ever sent for a notification
  }
}

func main(): Unit {
  val transport = newNdjsonTransport()
  var peer = newPeer(transport, EchoHandler())
  match runLoop(peer) {
    case Ok(_) -> ()
    case Err(e) -> println("runLoop ended: " + e)
  }
}
```

Swap `newNdjsonTransport()` for `newContentLengthTransport()` to speak the
LSP-style `Content-Length: N\r\n\r\n` framing instead.

### Calling out (client side)

```lyric
match call(peer, "tools/list", None) {
  case Ok(result) -> // JsonValue response
  case Err(e) -> println("rpc error " + e.code.toString() + ": " + e.message)
}

// Fire-and-forget:
notify(peer, "notifications/progress", Some(value = progressPayload))
```

### Working with the JSON value model directly

```lyric
import JsonRpc.Json

match parseValue("{\"name\":\"lyric\",\"tags\":[\"fast\",\"safe\"]}") {
  case Ok(doc) -> {
    val name = getString(doc, "name")   // Option[String]
    val tags = getArray(doc, "tags")    // Option[List[JsonValue]]
  }
  case Err(e) -> println(e.message())
}

val payload = writeValue(JObject(fields = [
  JsonField(name = "ok", value = JBool(value = true)),
]))
```

## `JsonRpc.Json` — the value model

```lyric
pub union JsonValue {
  case JNull
  case JBool(value: Bool)
  case JInt(value: Long)      // integral numbers, i64 range
  case JFloat(value: Double)  // non-integral, out-of-i64-range, or written with an exponent
  case JString(value: String)
  case JArray(items: List[JsonValue])
  case JObject(fields: List[JsonField])  // insertion-ordered; duplicates preserved
}
pub record JsonField { name: String, value: JsonValue }

pub func parseValue(src: in String): Result[JsonValue, JsonParseError]
pub func parseValueWithDepthLimit(src: in String, maxDepth: in Int): Result[JsonValue, JsonParseError]
pub func writeValue(v: in JsonValue): String   // compact, no trailing newline
```

Strictness relative to `Std.Yaml.parseJson` (the closest existing
cross-target parser in this repo, deliberately lenient since YAML 1.2 is a
JSON superset):

- Only the four RFC 8259 insignificant-whitespace characters are skipped.
- Numbers follow the RFC 8259 grammar exactly: no leading zeros, a `.`
  must be followed by a digit, an exponent must be followed by a digit.
- Strings reject raw (unescaped) control characters and lone UTF-16
  surrogates in `\uXXXX` escapes (a high surrogate not immediately
  followed by a matching low surrogate escape, or vice versa).
- Object keys must be double-quoted strings.
- Duplicate object keys are preserved on parse (not rejected); `getField`
  and friends resolve them last-wins, matching `JSON.parse`'s convention.
- The default recursion depth limit is 128 (`defaultMaxDepth`),
  configurable via `parseValueWithDepthLimit`.

`i64` integers round-trip exactly; an integer literal beyond `Long` range
(or written with a fractional part or an exponent) is classified `JFloat`
instead of silently wrapping.

## `JsonRpc` — envelope and peer

```lyric
pub union RpcId { case IntId(value: Long); case StringId(value: String); case NullId }
pub record RpcRequest { id: Option[RpcId], method: String, params: Option[JsonValue] }
pub record RpcError { code: Int, message: String, data: Option[JsonValue] }
pub union RpcResponse { case RpcSuccess(id: RpcId, value: JsonValue); case RpcFailure(id: RpcId, error: RpcError) }
// NOTE: `value`, not `result` — see "Known upstream issues" #1.

pub val parseError: Int = -32700
pub val invalidRequest: Int = -32600
pub val methodNotFound: Int = -32601
pub val invalidParams: Int = -32602
pub val internalError: Int = -32603

pub interface RpcHandler {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]
  func onNotification(method: in String, params: in Option[JsonValue]): Unit
}

pub interface RpcTransport {
  func receive(): Result[Option[String], String]   // None = clean EOF
  func send(payload: in String): Result[Unit, String]
  func close(): Unit
}

pub func newPeer(transport: in RpcTransport, handler: in RpcHandler): RpcPeer
pub func runLoop(peer: inout RpcPeer): Result[Unit, String]
pub func call(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]
pub func notify(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[Unit, String]
```

The peer is symmetric — JSON-RPC has no client/server asymmetry, and MCP
uses requests in both directions. Dispatch is single-threaded: `runLoop`
reads one message, dispatches it, writes the response, repeats, until the
transport reports clean EOF or a transport-level error. `call` issued from
inside a handler (an outbound request mid-dispatch) reads the transport
inline until the matching response id arrives; any request/notification
that arrives interleaved is queued and dispatched by the next `runLoop`
iteration (or the next `call`, which drains the queue first) — the same
discipline LSP servers use.

Batch requests (JSON-RPC 2.0 §6) are supported: an array envelope maps
over dispatch, order-preserving; notifications are skipped in the
response array; an empty batch is `-32600 Invalid Request`; a batch whose
every element is a notification produces no response at all (per spec,
not even an empty array).

Handler panics (a `Bug` raised inside `onRequest`/`onNotification`) are
caught at the dispatch boundary — `onRequest` panics map to `-32603
Internal error`; `onNotification` panics are discarded (no response is
ever possible for a notification). Neither kills `runLoop`.

The LSP server (`lyric-compiler/lyric/lsp.l`) is **not** migrated onto
this library in v1 — it predates it and works; migration is a tracked
follow-up (docs/62-jsonrpc-mcp.md Q-RPC-002) once `JsonRpc.Stdio` is
proven in a real deployment.

## `JsonRpc.Stdio` — framing

```lyric
pub func newNdjsonTransport(): NdjsonTransport               // one JSON message per '\n'-terminated line
pub func newContentLengthTransport(): ContentLengthTransport // "Content-Length: N\r\n\r\n" + N bytes
```

Both frame over `Std.Console`/`Std.ConsoleHost` — the same seam
`lsp.l` reads today. `ContentLengthTransport` is byte-accurate on UTF-8:
`Std.ConsoleHost.hostConsoleRead()` returns UTF-16 code units, not bytes,
so the body reader tracks UTF-8 byte length incrementally per code unit
(or per surrogate pair, when a code unit is one half of one) rather than
naively reading N *characters* — the exact gap `lsp.l`'s own module doc
flags as a known limitation of its hand-rolled framing.

The framing math itself is implemented sans-IO, parameterized over the
`CharReader`/`LineReader`/`StringWriter`/`LineWriter` interfaces (see
"Known upstream issues" #3 for why these are interfaces and not function
values) — `tests/stdio_tests.l` drives it against in-memory
implementations, no real pipe required.

## Package layout

```
lyric-jsonrpc/
  lyric.toml                package manifest
  README.md                 this file
  src/
    json.l                  JsonRpc.Json  (value model, parser, writer)
    jsonrpc.l                JsonRpc       (envelope, RpcPeer)
    stdio.l                  JsonRpc.Stdio (NDJSON + Content-Length framing)
  tests/
    json_tests.l             JsonRpc.Json.JsonTests
    jsonrpc_tests.l          JsonRpc.JsonRpcTests
    stdio_tests.l            JsonRpc.Stdio.StdioTests
```

## See also

- `docs/62-jsonrpc-mcp.md` — the agreed build spec (§§1-4 cover this
  library; §5 specs the follow-on `lyric-mcp` track)
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification) (external reference)
- [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259) — the JSON grammar `JsonRpc.Json` implements strictly
- `lyric-compiler/lyric/lsp.l` — the LSP server this library's Content-Length framing is modeled on, and (per Q-RPC-002) a future migration target
