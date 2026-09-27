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
> test coverage, green on both `.NET` and the JVM (CI runs the suites on
> both targets).

## Platform parity

| Package | `.NET` | JVM |
|---|---|---|
| `JsonRpc.Json` (parser, writer, accessors) | 48/48 tests | 48/48 tests |
| `JsonRpc` (envelope, `RpcPeer`, call deadlines) | 31/31 tests | 31/31 tests |
| `JsonRpc.Stdio` (NDJSON, Content-Length, byte-level framing) | 30/30 tests | 30/30 tests |

The production stdio transports read stdin through `Std.Console`'s
`StdinReader`, which bounds a wait on `dotnet` and `jvm`; `--target
native` has no console input yet (see `_kernel_native/console_host.l`).

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

3. **FIXED (#5388/#5251).** ~~A cross-package closure argument crashes at
   runtime on the JVM backend.~~ Same root-cause family as [#5329](https://github.com/nichobbs/lyric-lang/issues/5329) (its bug 3). `ClassCastException: <CallerPkg>$Lambda$N cannot be cast to
   class <CalleePkg>.Lyric$Lambda`. A function-typed parameter (`in () ->
   Int`, etc.) worked fine when the lambda argument was written in the same
   package as the callee, but a lambda passed in from a *different*
   package got wrapped in a lambda-adapter class scoped to the *caller's*
   package, which the *callee's* generated interface type then failed to
   downcast. `.NET` was unaffected. Root-caused via `Std.Testing.assertPanicsWith`'s
   lambda-argument form silently swallowing the real panic message (the
   caught exception was this `ClassCastException`, not the panic — `catch
   Bug` maps broadly to `java/lang/Throwable`, so it happily caught the
   wrong exception). Fixed by unifying the functional interface every
   closure implements into ONE shared binary name (`Lyric/Lyric$Lambda`)
   across the whole bundle instead of one per package — see
   `Jvm.Codegen.lambdaIfaceName` and `Jvm.Bridge.codegenPackageInto`'s
   dedup. The workaround below is no longer required but is left in place
   since it costs nothing to keep. **Former workaround**: `JsonRpc.Stdio`'s
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

5. **FIXED.** Calling a generic `Std.Core` function (`isSome`/`isNone`/
   `unwrapOption`) with several different concrete type arguments across
   one file intermittently crashed at runtime. Filed as [#6121](https://github.com/nichobbs/lyric-lang/issues/6121), with `Msil.Codegen: match
   not exhaustive in <Pkg>.isSome__Object` / an analogous JVM message —
   even though each individual call type-checked and the same call
   sometimes ran correctly in a different `lyric test` invocation of the
   *identical* source (non-deterministic across runs, not across calls
   within one run). Root cause: `Lyric.Mono`'s call-site inference
   environment (`env`) was a single mutable map shared across an entire
   file's monomorphization pass with no scope isolation, so a generic
   call's inferred type argument could leak into and overwrite a sibling
   call's binding depending on visitation order — non-deterministic
   because that order depended on unrelated file state. Fixed by scoping
   `env` per call site via `snapshotEnv`/`restoreEnv` at every
   scope-introducing construct (blocks, loops, `try`/`catch`/`finally`,
   match arms, lambdas). The workaround below is no longer required but
   is left in place since it costs nothing to keep. **Former
   workaround**: `json_tests.l` uses fully concrete (non-generic),
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

### Formerly JVM-only test failures (no longer reproduce)

The two clusters below no longer reproduce: every `JsonRpcTests` and
`StdioTests` case passes under `--target jvm` with the current compiler,
and CI runs both suites on the JVM (#7451). The notes are kept for the
history of #6123/#6124. Tracked as [#6123](https://github.com/nichobbs/lyric-lang/issues/6123) (JsonRpcTests cluster) and [#6124](https://github.com/nichobbs/lyric-lang/issues/6124) (StdioTests cluster).

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
| `JsonRpc` | JSON-RPC 2.0 envelope types, standard error codes, `RpcHandler`/`RpcTransport` interfaces, `RpcPeer` (`runLoop`/`call`/`callWithin`/`notify`) |
| `JsonRpc.Stdio` | NDJSON and Content-Length stdio framings over stdin/stdout, byte-level, with bounded receives |

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
// `call` waits at most the peer's call timeout (60 s unless set with
// newPeerWithTimeout / setCallTimeout); `callWithin` takes one per call.
match callWithin(peer, "tools/list", None, 5000) {
  case Ok(result) -> // JsonValue response
  case Err(e) -> if isTimeoutError(e) {
    println("no answer within 5 s")
  } else {
    println("rpc error " + e.code.toString() + ": " + e.message)
  }
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
- The default recursion depth limit is 128 (`defaultMaxDepth`) nested
  arrays/objects, configurable via `parseValueWithDepthLimit` to any value
  in 1..1024. Each container counts once: a document exactly `maxDepth`
  containers deep parses, one more is `DepthExceeded`.

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

pub func isReservedErrorCode(code: in Int): Bool          // -32768..-32000
pub func applicationError(code: in Int, message: in String, data: in Option[JsonValue]): RpcError
  requires: not isReservedErrorCode(code)
pub func isValidOutboundMethod(method: in String): Bool   // non-empty, not "rpc."
pub val maxBatchSize: Int = 1024
pub val maxPendingMessages: Int = 4096

pub interface RpcHandler {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]
  func onNotification(method: in String, params: in Option[JsonValue]): Unit
}

pub union ReceiveOutcome { case RpcMessage(text: String); case RpcEndOfStream; case RpcTimedOut }

pub interface RpcTransport {
  func receive(): Result[Option[String], String]   // None = clean EOF
  func receiveWithin(timeoutMs: in Int): Result[ReceiveOutcome, String]
  func send(payload: in String): Result[Unit, String]
  func close(): Unit
}

pub val requestTimedOut: Int = -32001
pub val defaultCallTimeoutMs: Int = 60000
pub val maxCallTimeoutMs: Int = 86400000     // 24 h
pub func isValidCallTimeout(timeoutMs: in Int): Bool   // 1 ..= maxCallTimeoutMs
pub func isTimeoutError(e: in RpcError): Bool

pub func newPeer(transport: in RpcTransport, handler: in RpcHandler): RpcPeer
pub func newPeerWithTimeout(transport: in RpcTransport, handler: in RpcHandler, callTimeoutMs: in Int): RpcPeer
  requires: isValidCallTimeout(callTimeoutMs)
pub func setCallTimeout(peer: inout RpcPeer, callTimeoutMs: in Int): Unit
  requires: isValidCallTimeout(callTimeoutMs)
pub func runLoop(peer: inout RpcPeer): Result[Unit, String]
pub func call(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]
  requires: isValidOutboundMethod(method)
pub func callWithin(peer: inout RpcPeer, method: in String, params: in Option[JsonValue], timeoutMs: in Int): Result[JsonValue, RpcError]
  requires: isValidOutboundMethod(method) and isValidCallTimeout(timeoutMs)
pub func notify(peer: inout RpcPeer, method: in String, params: in Option[JsonValue]): Result[Unit, String]
  requires: isValidOutboundMethod(method)
pub func drainPendingQueue(peer: inout RpcPeer): Result[Unit, String]
```

The peer is symmetric — JSON-RPC has no client/server asymmetry, and MCP
uses requests in both directions. Dispatch is single-threaded: `runLoop`
reads one message, dispatches it, writes the response, repeats, until the
transport reports clean EOF or a transport-level error. `call` issued from
inside a handler (an outbound request mid-dispatch) reads the transport
inline until the matching response id arrives; any request/notification
that arrives interleaved is queued and dispatched by the next `runLoop`
iteration (or the next `call`, which drains the queue first) — the same
discipline LSP servers use. If more than `maxPendingMessages` messages
queue up while one `call` waits, that `call` fails with `internalError`
and the queued messages stay queued for `runLoop`.

A caller whose peer never runs `runLoop` — a pure request/response client
like `Mcp.Client` — must drain that queue some other way, or entries left
by one call accumulate across every later call toward
`maxPendingMessages`. `drainPendingQueue(peer)` dispatches (or discards,
for a notification) every currently-queued entry exactly as `runLoop`
would; call it after each `call`/`callWithin` returns.

### Deadlines

No call waits forever (#7451). `call` applies the peer's call timeout —
`defaultCallTimeoutMs` (60 s, the MCP SDKs' default request timeout) for
a peer from `newPeer`, or whatever `newPeerWithTimeout`/`setCallTimeout`
set — and `callWithin` takes one per call; both accept 1 ms to 24 h. The
deadline is fixed when the request goes out: each wait on the transport
(`RpcTransport.receiveWithin`) gets only the time left, and requests or
notifications that arrive meanwhile are queued without extending it. When
it passes, the call returns a local `RpcError` with code `requestTimedOut`
(`-32001`, the implementation-defined server-error range; `data` carries
`{"timeoutMs": N}`), which `isTimeoutError` recognizes. `isTimeoutError`
matches the wire-level `-32001` code alone: a peer can legitimately send
its own `-32001` failure for an unrelated reason, and this does not
distinguish that from a local deadline (#7522 tracks typed `Mcp.Client`
errors that would). Nothing is sent to
the peer. Ids are never reused, so if the response turns up later it
matches no call: `runLoop` and later calls drop it like any unsolicited
response, and it is never handed to a different call.

A transport's `receiveWithin` must not lose data on a timeout — the
built-in transports keep a partly received message buffered and return it
whole on the next receive.

Build application errors with `applicationError`, whose precondition
keeps them out of the range JSON-RPC 2.0 §5.1 reserves for protocol
errors. A peer-supplied error `code` outside the `Int` range decodes as
`internalError` rather than being truncated.

Batch requests (JSON-RPC 2.0 §6) are supported: an array envelope maps
over dispatch, order-preserving; notifications are skipped in the
response array; an empty batch, or one longer than `maxBatchSize`, is a
single `-32600 Invalid Request`; a batch whose
every element is a notification produces no response at all (per spec,
not even an empty array).

Handler panics (a `Bug` raised inside `onRequest`/`onNotification`) are
caught at the dispatch boundary — `onRequest` panics map to `-32603
Internal error` (the panic message itself is never sent to the peer); `onNotification` panics are discarded (no response is
ever possible for a notification). Neither kills `runLoop`.

The LSP server (`lyric-compiler/lyric/lsp.l`) is **not** migrated onto
this library in v1 — it predates it and works; migration is a tracked
follow-up (docs/62-jsonrpc-mcp.md Q-RPC-002) once `JsonRpc.Stdio` is
proven in a real deployment.

## `JsonRpc.Stdio` — framing

```lyric
pub func newNdjsonTransport(): NdjsonTransport               // one JSON message per '\n'-terminated line
pub func newContentLengthTransport(): ContentLengthTransport // "Content-Length: N\r\n\r\n" + N bytes

// The same transports over any byte stream and writer (sans-IO):
pub func newNdjsonTransportOver(source: in ByteSource, writer: in LineWriter): NdjsonTransport
pub func newContentLengthTransportOver(source: in ByteSource, writer: in StringWriter): ContentLengthTransport

pub interface ByteSource {
  func read(): Result[Option[slice[Byte]], String]           // None = end of stream
  func readWithin(timeoutMs: in Int): Result[ByteRead, String]
}
pub func ndjsonReceiveFrom / ndjsonReceiveWithinFrom / clReceiveFrom / clReceiveWithinFrom
pub func ndjsonAcceptLine(line: in String): Result[String, String]   // the 16 MiB line limit
```

Inbound framing is byte-level. The stdin transports read raw bytes
through `Std.Console`'s `StdinReader` (they own stdin — don't mix them
with `Std.Console.readLine`) into a `FrameBuffer`, and cut a frame at each
`\n` byte (NDJSON; a `\r` before it is dropped) or after exactly the
declared body bytes (Content-Length). A frame is decoded as UTF-8 only once
it is complete, so the Content-Length count is exact by construction and
invalid UTF-8 is a framing error. `receiveWithin` gives each wait for more
bytes only the time left before its deadline; on a timeout the bytes read
so far stay in the `FrameBuffer`, so a message that straddles the deadline
is returned whole by the next receive. `FrameBuffer.bytes` is a
`List[Byte]`, not a `slice[Byte]`: since `slice[T]` is immutable,
re-concatenating the whole pending buffer on every append would cost
O(message size²) to accumulate one large message split across many small
reads; `List[Byte].add` is amortised O(1) per byte, so a chunk of size n
costs amortised O(n). An EOF-terminated final NDJSON line is capped at the
same 16 MiB `MAX_MESSAGE_BYTES` bound a `\n`-terminated line is.

The older character- and line-level cores (`clReceiveVia`/
`ndjsonReceiveVia` over `CharReader`/`LineReader`, plus `clSendVia`/
`ndjsonSendVia`) remain for framing other streams — `lyric-mcp`'s piped
client transport reuses `ndjsonReceiveVia` — and `clReceiveVia` still
counts UTF-8 bytes per UTF-16 code unit (or surrogate pair) for an exact
body read.

The framing math is implemented sans-IO, parameterized over the
`ByteSource`/`CharReader`/`LineReader`/`StringWriter`/`LineWriter`
interfaces (see "Known upstream issues" #3 for why these are interfaces
and not function values) — `tests/stdio_tests.l` drives it against
in-memory implementations, including silent sources that time out
mid-frame, with no real pipe required.

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
