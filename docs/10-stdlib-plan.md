# 10 — Standard Library Implementation Plan

## Overview

The Lyric standard library is designed to be safety-oriented, minimal, and composable. It prioritizes:

- **Result-based error handling** over exceptions
- **Explicit effect surfaces** (io, http, clock, env)
- **Opaque wrappers** around host runtime objects where needed
- **Contract-driven APIs** with preconditions, postconditions, invariants
- **Small, focused modules** rather than monolithic subsystems

The BCL serves as runtime implementation support only; the stdlib's surface API is pure Lyric.

## Design Principles

1. **No reflection**. The stdlib is source-generated or hand-written; reflection is not an option.
2. **Error model**: All IO and network operations return `Result<T, E>` where E is a domain-specific error union.
3. **Effect model**: Operations with side effects (console, file, network) are marked explicitly in the API.
4. **Contracts first**: Public functions declare preconditions and postconditions; contracts are checked at runtime in `@runtime_checked` modules.
5. **Opaque domain types**: Core domain abstractions (File, Path, HttpResponse) are opaque; DTOs for wire transfer are exposed records.

## Phase 1 — Spec and shape (shipped)

**Goal**: Define stdlib source layout and decide what stays in Lyric source vs. F# shim.

### Deliverables

1. **Source layout**

   ```
   lyric-stdlib/std/
     ├── core.l          (primitives, Option, Result, slice helpers)
     ├── errors.l        (ParseError, IOError, HttpError)
     ├── parse.l         (safe primitive parsing)
     ├── string.l        (string helpers)
     ├── io.l            (FFI boundary: System.Console/System.IO extern declarations)
     ├── console.l       (safe console wrappers)
     ├── file.l          (safe file wrappers)
     ├── directory.l     (safe directory wrappers)
     ├── path.l          (platform-aware path helpers)
     ├── stream.l        (stream interfaces)
     ├── http_host.l     (FFI boundary: System.Net.Http extern declarations)
     ├── http.l          (safe HTTP client/request/response wrappers)
     ├── rest.l          (typed REST client: RestClient, RestAuth, RestError)
     ├── environment_host.l (FFI boundary: process environment)
     ├── environment.l   (safe env/args/process helpers)
     ├── time_host.l     (FFI boundary: clocks/timers)
     ├── time.l          (Instant, Duration, Clock, Timer)
     ├── log_host.l      (FFI boundary: diagnostic sinks)
     ├── log.l           (Logger interface and Log helpers)
     ├── task.l          (Task/Cancellation source shapes)
     └── app.l           (minimal app host/config wrapper)
   ```

2. **API surface decisions**
   - `Option[T]` and `Result[T, E]` as generic unions
   - Safe constructors: `tryFrom`, `from` (panics), `unwrapOr` combinators
   - `TryParse`-style parsing functions for primitives
   - Slice operations: `map`, `filter` (Phase 2 once higher-order functions work)

3. **Error model**
   - Define `IOError` union (NotFound, PermissionDenied, IoError, etc.)
   - Define `HttpError` union (ConnectionFailed, Timeout, BadStatus, etc.)
   - Define `ParseError` for string/number parsing

4. **F# shim boundaries**
   - `Lyric.Stdlib.Console` (Println, Print, PrintlnAny) ✅ exists
   - `Lyric.Stdlib.Contracts` (Expect, Assert, Panic) ✅ exists
   - Future: `Lyric.Stdlib.IO`, `Lyric.Stdlib.Http` (hand-curated wrappers)

### Status

- ✅ Generic Option/Result unions in core.l
- ✅ IO and Http FFI boundary stubs created
- ✅ Test harness updated to inline all stdlib files
- ✅ Error model unions defined (`IOError`, `HttpError`, `ParseError`)
- ✅ Parse error handling shipped — `Std.Parse.tryParse{Int,Long,Double,Bool}`
  return `Result[T, ParseError]` with explicit `Empty / NotANumber / OutOfRange`
  variants (D-progress-014; subsequent collapse onto BCL's `TryParse`)

---

## Phase 2 — Core coverage (shipped)

**Goal**: Flesh out primitives, containers, and safe parsing.

### Deliverables

1. **Primitive runtime types** (already in emitter)
   - `String`, `Char`, `Int`, `Long`, `Float`, `Decimal`
   - `Bool`, `Unit`
   - `Range` / `Subrange` type support

2. **Generic container types**
   - `Option[T]` with `some`, `none`, `unwrapOr`, `map` (Phase 2.5 once higher-order works)
   - `Result[T, E]` with `ok`, `err`, `unwrapOr`, `unwrapErrOr`, `mapResult` (Phase 2.5)
   - `List[T]` / `Seq[T]` stubs (Phase 3 when collections have real CLR shape)
   - `Map[K, V]` stubs (Phase 3)
   - `Set[T]` stubs (Phase 3)

3. **Safe constructors and parsing**
   - `Int.tryParse(s: in String): Result[Int, ParseError]`
   - `Long.tryParse(s: in String): Result[Long, ParseError]`
   - `Double.tryParse(s: in String): Result[Double, ParseError]`
   - `Guid.tryParse(s: in String): Result[Guid, ParseError]`
   - `String.toInt()`, `String.toLong()`, `String.toDouble()` (panic on failure)
   - `String.trim()`, `String.startsWith()`, `String.endsWith()`, `String.substring()`

4. **Contract-safe slice and collection operations**
   - `List.map`, `List.filter`, `List.fold` (when higher-order functions work)
   - `Map.get`, `Map.add`, `Map.remove`
   - `String` concatenation, comparison, encoding helpers

5. **Standard error unions**

   ```lyric
   pub union ParseError {
     case InvalidFormat(input: String, expected: String)
     case OutOfRange(value: String, bounds: String)
   }

   pub union IOError {
     case FileNotFound(path: String)
     case PermissionDenied(path: String)
     case IoError(path: String, message: String)
   }
   ```

### Milestones

- **P2.1**: Option/Result with all combinators
- **P2.2**: Safe parsing for all numeric types
- **P2.3**: String operations and error unions finalized
- **P2.4**: Slice/basic collection helpers

---

## Phase 3 — IO foundation (shipped)

**Goal**: Safe, `Result`-based file and console I/O.

### Deliverables

1. **Console I/O** (build on F# shim)
   - `Console.print(s: in String): Unit`
   - `Console.println(s: in String): Unit`
   - `Console.readLine(): Result[String, IOError]`
   - `Console.error(s: in String): Unit` (stderr)

2. **File operations**
   - `File.readText(path: in String): Result[String, IOError]`
   - `File.writeText(path: in String, text: in String): Result[Unit, IOError]`
   - `File.readBytes(path: in String): Result[slice[Byte], IOError]`
   - `File.writeBytes(path: in String, bytes: in slice[Byte]): Result[Unit, IOError]`
   - `File.exists(path: in String): Bool`

3. **Path operations**
   - `Path.join(base: in String, relative: in String): String`
   - `Path.extension(path: in String): String`
   - `Path.basename(path: in String): String`
   - `Path.dirname(path: in String): String`
   - `Path.isAbsolute(path: in String): Bool`
   - `Path.isRelative(path: in String): Bool`

4. **Directory operations**
   - `Directory.exists(path: in String): Bool`
   - `Directory.create(path: in String): Result[Unit, IOError]`
   - `Directory.createRecursive(path: in String): Result[Unit, IOError]`
   - `Directory.enumerate(path: in String): Result[slice[String], IOError]`
   - `Directory.enumerateFiles(path: in String): Result[slice[String], IOError]`
   - `Directory.enumerateDirectories(path: in String): Result[slice[String], IOError]`
   - `Directory.delete(path: in String): Result[Unit, IOError]`
   - `Directory.deleteRecursive(path: in String): Result[Unit, IOError]`

5. **Stream abstractions** (lightweight wrappers)
   - Simple byte/text stream interfaces
   - Explicit buffer / size control
   - Resource cleanup with explicit `close()` and `defer`

6. **Error model refinement**
   - All fallible IO returns `Result<T, IOError>`
   - No hidden exceptions from stdlib code
   - Boundary between safe stdlib and unsafe BCL is explicit

### Milestones

- **P3.1**: Console I/O source API drafted (`print`, `println`, `error`, `readLine`)
- **P3.2**: File read/write source API drafted with `Result[T, IOError]`
- **P3.3**: Path and directory source APIs drafted
- **P3.4**: Stream interfaces drafted; concrete stream handles still pending

---

## Phase 4 — HTTP / networking (shipped)

**Goal**: Safe, `Result`-based HTTP client and server foundations.

### Deliverables

1. **HTTP types**
   - `HttpMethod` enum: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS ✅
   - `Headers` (opaque wrapper around BCL headers) ✅ marker type drafted
   - `HttpRequest` opaque type ✅
   - `HttpResponse` opaque type ✅

2. **HTTP client APIs**
   - `Http.sendAsync(request: in HttpRequest): Result[HttpResponse, HttpError]` ✅
   - `Http.getAsync(url: in String): Result[HttpResponse, HttpError]` ✅
   - `Http.postAsync(url: in String, body: in String): Result[HttpResponse, HttpError]` ✅
   - `Http.withJsonBody(request: in HttpRequest, json: in String): HttpRequest` ✅
   - `Http.withHeader(request: in HttpRequest, key: in String, value: in String): HttpRequest` ✅

3. **Response parsing**
   - `HttpResponse.statusCode: Int` (accessor function) ✅
   - `HttpResponse.bodyText(): Result[String, IOError]` ✅ async source shape
   - `HttpResponse.bodyBytes(): Result[slice[Byte], IOError]` ✅ async source shape
   - Status code helpers: `isSuccess()`, `isClientError()`, `isServerError()` ✅

4. **Domain-friendly request/response modeling**
   - `Url` opaque wrapper with parsing ✅
   - `Uri` (same as Url, alias) ✅
   - Explicit status-code handling (no implicit exceptions) ✅
   - JSON serialization built on source generators

5. **Error model**

   ```lyric
   pub union HttpError {
     case ConnectionFailed(url: String, message: String)
     case Timeout(url: String, durationMs: Long)
     case BadStatus(url: String, statusCode: Int)
     case IoError(url: String, error: IOError)
   }
   ```

6. **High-level helpers**
   - `Http.retry(request, maxAttempts, backoffMs): Result[HttpResponse, HttpError]` ✅ immediate retry shape
   - `Http.timeout(request, durationMs): Result[HttpResponse, HttpError]` ✅ shipped via D-progress-070 (real BCL timeout threading)
   - `Http.followRedirects(response): Result[HttpResponse, HttpError]` ✅ shipped via D-progress-070 (configurable redirect policy)
   - Cancellation tokens threaded through every `*Async` entry ✅ shipped via D-progress-070 (gated on the C2 async chain)

### Milestones

- **P4.1**: Basic HTTP client drafted (GET, POST with string bodies)
- **P4.2**: Response parsing and error handling drafted
- **P4.3**: Retry source shape drafted; timeout / redirects / cancellation shipped via D-progress-070
- **P4.4**: JSON serialization integration ✅ shipped via D-progress-030 / D-progress-043..046 / D-progress-060

---

## Phase 5 — Application basis and runtime support (shipped)

**Goal**: Environment, time, logging, and minimal app host.

### Deliverables

1. **Environment and process**
   - `Environment.getVar(key: in String): Result[String, IOError]` ✅
   - `Environment.getVarOrDefault(key: in String, default: in String): String` ✅
   - `Environment.args(): slice[String]` ✅
   - `Environment.exitCode(code: in Int): Never` ✅

2. **Time and scheduling**
   - `Clock` interface (trait for injecting time in tests) ✅
   - `Clock.now(): Instant` ✅ interface shape
   - `Duration` opaque type ✅
   - `Duration.seconds(n: in Long): Duration` ✅
   - `Duration.millis(n: in Long): Duration` ✅
   - `Timer.sleepAsync(d: in Duration): Unit` (async) ✅
   - ISO 8601 parsing for `Instant` ✅

3. **Logging / diagnostics**
   - `Logger` interface (trait-based) ✅
   - `Log.info(msg: in String): Unit` ✅
   - `Log.error(msg: in String): Unit` ✅
   - `Log.debug(msg: in String): Unit` ✅
   - `Log.warn(msg: in String): Unit` ✅
   - Structured logging helpers (key-value pairs) ✅

4. **Concurrency support**
   - `async`-friendly APIs on stdlib types
   - `Task` / promise wrappers (lightweight over .NET Task) ✅ source shape
   - `protected type` examples around shared state
   - Cancellation token integration ✅ source shape

5. **Minimal app host**
   - `App.run(main: func Unit): Int` (entry point wrapper) ✅
   - `App.withConfig(configPath: in String): Result[Config, IOError]` ✅
   - `Config` opaque type (raw config loaded; JSON decoding later) ✅
   - Optional dependency injection via wire blocks (Phase 3)

### Milestones

- **P5.1**: Environment access and process control drafted
- **P5.2**: Time APIs and Clock interface drafted
- **P5.3**: Logging framework drafted
- **P5.4**: App host and raw configuration drafted

---

## Phase 6 — Examples and documentation

**Goal**: Flesh out worked examples and demonstrate all stdlib capabilities.

Status: started in `docs/11-stdlib-examples.md`.

### Deliverables

1. **Worked examples expansion**
   - Console application (args, env, logging) ✅
   - File-processing utility (read, parse, filter, write) ✅ first pass
   - Simple HTTP client (GET/POST, error handling, retry) ✅ first pass
   - REST handler sketch (with wire DI) — see `Std.Rest` and `lyric openapi` (D-progress-232) ✅
   - Concurrent task executor (async, cancellation)

2. **Stdlib-focused test coverage**
   - Ensure all public APIs are exercisable
   - Error path testing (file not found, network timeout, etc.)
   - Contract testing (preconditions, postconditions)

3. **Documentation**
   - Stdlib API reference (generated or hand-written)
   - "How to handle errors" guide (Result vs. exceptions) ✅ first pass
   - "How to do IO safely" guide ✅ first pass
   - "How to call .NET BCL" guide (extern boundaries) ✅ checklist started
   - Samples for each major module ✅ partial

---

## Implementation roadmap

```
Phase 1 ✅
├─ Generic Option/Result ✅
├─ IO/Http FFI boundaries ✅
├─ Error model definitions ✅
└─ Test harness updates ✅

Phase 2 ✅
├─ Safe parsing for primitives ✅ (Std.Parse on BCL TryParse)
├─ Container helpers ✅ (map / filter / take / drop / concat on slice[T])
├─ Error unions finalized ✅
└─ String operations ✅

Phase 3 ✅
├─ Console I/O ✅
├─ File operations ✅ (Result[Unit, IOError] surface)
├─ Path/Directory helpers ✅
└─ Stream interfaces ✅; concrete handles still source-API-only

Phase 4 ✅
├─ HTTP client basics ✅
├─ Response parsing ✅
├─ High-level helpers ✅ (retry / timeout / redirect / cancellation; D-progress-070)
└─ JSON integration ✅ (@generate(Json) source-gen; D-progress-030..060)

Phase 5 ✅
├─ Environment & process ✅
├─ Time & scheduling ✅ (Std.Time expansion D-progress-027/039)
├─ Logging framework ✅
└─ App host ✅

Phase 6 (examples & docs)
├─ Worked examples 🔄 first pass in docs/11
├─ Test coverage ✅ (Std.Testing + Property + Snapshot — D-progress-063/064)
└─ Documentation ✅ tutorial shipped (docs/13; D-progress-065)
```

## Parallel work

**Not blocking stdlib**:

- Phase 1 M1.4 (contracts, async, FFI) continues in parallel
- Phase 2 type system features (range subtypes, distinct types, opaque types) can start once M1.4 foundation is solid

**Blocking stdlib progress**:

- Higher-order functions (map, filter) — needs Phase 2.5 (function types as parameters)
- Collections (Map, Set, List) — needs Phase 2 (opaque types, interfaces)
- Protected types — needs Phase 3 (concurrency primitives)

---

## Success criteria by phase

**Phase 1**: Stdlib can express the core abstractions (Option, Result, basic IO)
**Phase 2**: Safe parsing and slice operations work end-to-end
**Phase 3**: A file-processing utility is expressible in pure Lyric
**Phase 4**: A simple HTTP client is expressible; no .NET BCL calls in user code
**Phase 5**: A complete application (with env, logging, DI) is feasible
**Phase 6**: Every public API has a worked example and clear error-handling pattern

---

## Notes

- **Monomorphisation caveat**: Phase 1 Option/Result work because their payloads are reference-typed (obj in M1.4). Value-typed payloads require reified generics (Phase 2 / Phase 4 work).
- **FFI strategy**: `extern package` declarations in `.l` files list the BCL surface; the F# emitter hand-routes calls to the appropriate static methods. Curated, not reflection-driven.
- **Error propagation**: The `?` operator (if implemented) will turn `Result` failures into early returns; currently explicit `unwrapOr` or pattern matching.
- **Async boundaries**: All async stdlib functions use `async func` and return `Task[T]`.  Real `IAsyncStateMachine` synthesis shipped during the C2 chain (D-progress-033..076); the M1.4 blocking shim only fires for shapes the SM emit doesn't cover (today: generic instance impl methods only).


---

## Stability cut (Q011 / D040)

Every `pub` item in `lyric-stdlib/std/` carries either `@stable(since="1.0")` or `@experimental`.  This table is the authoritative cut list for v1.0.

| Module | Stability | Rationale |
|--------|-----------|-----------|
| `Std.Errors` (`errors.l`) | `@stable` | Core error types used everywhere; stable from day one. |
| `Std.Parse` (`parse.l`) | `@stable` | Primitive parsing is foundational; well-exercised. |
| `Std.Core` (`core.l`) | no `pub` items | Option/Result are compiler-intrinsic; accessed by all importers without `pub`. |
| `Std.Collections` (`collections.l`) | `@stable` | `mapGet` is the only pub item; maps are fundamental. |
| `Std.String` (`string.l`) | `@stable` | All string helpers; well-tested, stable API. |
| `Std.Console` (`console.l`) | `@stable` | `print`, `println`, `error`, `readLine` — basic I/O. |
| `Std.File` (`file.l`) | `@stable` | `readText`, `writeText`, `fileExists`, `dirExists`, `createDir`. |
| `Std.Directory` (`directory.l`) | `@stable` | `exists`, `create`, `createRecursive`, `enumerate`, `delete`, `deleteRecursive`. |
| `Std.Iter` (`iter.l`) | `@stable` | All slice combinators (`map`, `filter`, `fold`, `find`, etc.). |
| `Std.Math` (`math.l`) | `@stable` | All math helpers: `pi`, `e`, trig, `abs`, `min`/`max`, `gcd`, `lcm`, `pow`, `sqrt`, etc. |
| `Std.Stream` (`stream.l`) | `@stable` | `ByteReader`, `ByteWriter`, `TextReader`, `TextWriter`, `Closable` interfaces. |
| `Std.Log` (`log.l`) | `@stable` | `LogLevel`, `LogField`, `Logger`, `log`/`debug`/`info`/`warn`/`error`. |
| `Std.Path` (`path.l`) | `@stable` | `join`, `extension`, `basename`, `dirname`, `isAbsolute`, `isRelative`. |
| `Std.Environment` (`environment.l`) | `@stable` | `getVar`, `getVarOrDefault`, `args`, `exitCode`. |
| `Std.App` (`app.l`) | `@stable` | `Config`, `run`, `withConfig`, `Config.path`, `Config.rawText`. |
| `Std.Json` (`json.l`) | `@stable` | `parseJson`, `rootElement`, `getProperty`, `tryGetProperty`, scalar getters, `encodeString`. |
| `Std.Time` — core (`time.l`) | `@stable` | `now`, `zeroDuration`, duration constructors, `since`, `plus`, `totalMillis`/`Seconds`, `addMonths`/`Years`/`Days`, `fromEpochMillis`/`Seconds`, `parseOptInstant`, comparison/arithmetic helpers, `toIsoString`. |
| `Std.Time` — DTO/TZ helpers (`time.l`) | `@experimental` | `dtoFromEpochMillis`, `dtoFromEpochSeconds`, `dtoUtcDateTime`, `findTimeZone` — bootstrap-grade; full DateTimeOffset/TimeZone API to settle in Phase 2. |
| `Std.Http` — core (`http.l`) | `@stable` | `HttpMethod`, `Url`/`Uri`, `HttpRequest`, `HttpResponse`, `Headers`, core constructors, `request`, `withHeader`, `withJsonBody`/`withTextBody`, `sendAsync`, `getAsync`, `postAsync`, `HttpResponse.*` status helpers, `bodyText`/`bodyBytes`, `HttpResponse.header`. |
| `Std.Http` — advanced (`http.l`) | `@experimental` | `retry`, cancel/timeout variants (`sendWithCancelAsync`, `getWithCancelAsync`, `postWithCancelAsync`, `sendWithTimeoutAsync`, `getWithTimeoutAsync`, `postWithTimeoutAsync`, `HttpResponse.bodyTextWithCancel`), `clientWithRedirects`, `clientNoRedirects` — bootstrap-grade; cancellation and retry contracts to be redesigned in Phase 2. |
| `Std.Rest` (`rest.l`) | `@stable` | `RestError` union, `RestAuth` enum, `RestClient` opaque type; `create`, `withAuth`; `get`, `post`, `put`, `patch`, `delete`; `bodyText`, `jsonBody`, `jsonString`, `jsonInt`, `jsonBool`; `statusCode`, `isSuccess`, `ensureSuccess`. |
| `Std.Testing` (`testing.l`) | `@stable` | `assertEqual`, `assertEqualInt`, `assertTrue` — the basic assert API. |
| `Std.Testing.Property` (`testing_property.l`) | `@experimental` | No shrinking, no `Gen[T]` type-class; bootstrap-grade. Full property-test harness is Phase 3 work. |
| `Std.Testing.Snapshot` (`testing_snapshot.l`) | `@experimental` | No inline diff, no snapshot update workflow; bootstrap-grade. |
| `Std.CoreProof` (`core_proof.l`) | `@experimental` | Proof scaffolding helpers (`identity`, `trueLit`, `assertEq`, etc.); internal to the Phase 4 test suite. |
| `Std.Char` (`char.l`) | `@stable` | Unicode character classification and conversion helpers (`isLetter`, `isDigit`, `isWhitespace`, `toLower`, `toUpper`, `toInt`, `fromInt`). |
| `Std.Encoding` (`encoding.l`) | `@stable` | UTF-8 encode/decode (`toUtf8Bytes`, `fromUtf8Bytes`, NFC normalization via `_kernel/unicode_host.l`). |
| `Std.Format` (`format.l`) | `@stable` | `format1`–`format6` string interpolation helpers; backing for the `format` builtin. |
| `Std.Sort` (`sort.l`) | `@stable` | In-place list sort (`sortBy`, `sortAscBy`, `sortDescBy`) with comparator. |
| `Std.Set` (`set.l`) | `@stable` | Immutable set backed by `Dictionary<object,object>` (`newSet`, `setAdd`, `setContains`, `setRemove`, `setUnion`, `setIntersect`). |
| `Std.Uuid` (`uuid.l`) | `@stable` | UUID v4 generation (`newUuid`) and string round-trip. |
| `Std.Process` (`process.l`) | `@stable` | Subprocess launch and wait (`spawn`, `spawnCaptured`, `runCapture`); backed by `_kernel/process_host.l`. |
| `Std.Regex` (`std/regex.l`) | `@stable` | Primary public regex API: `CompiledRegex` opaque type, `compile` / `compileWithTimeout` (throwing), `tryCompile` / `tryIsMatch` / `tryReplace` (Result-based, typed `RegexError`).  `matchOne` / `tryMatchOne` are deferred to a follow-up PR (#330 Phase 2) pending `@externTarget` field-extractor externs for `.NET Match` in the kernel.  Every compiled pattern carries a 1-second match timeout by default.  **ReDoS posture — .NET**: `Regex(string, RegexOptions, TimeSpan)` in `_kernel/regex_host.l`; adversarial input throws `RegexMatchTimeoutException` instead of hanging.  **ReDoS posture — JVM**: `lyric.stdlib.jvm.RegexHost` shim (Phase 6) wraps `java.util.regex.Pattern` in a `JvmPattern` envelope with a daemon-thread interrupt; timeout throws `RuntimeException` with "time-out" in the message.  Backed by `Std.RegexHost` (`_kernel/regex_host.l` / `_kernel_jvm/regex_host.l`).  Resolves #330. |
| `Std.RegexHost` (`_kernel/regex_host.l`) | internal | Raw BCL / JVM regex kernel boundary.  All public functions use `host*` prefix (`hostCompile`, `hostCompileWithTimeout`, `hostIsMatch`, `hostMatchOne`, `hostReplace`) to avoid name-shadowing recursion in the emitter.  Used by `Std.Regex` and `Std.RegexSafe`; import directly only in stdlib kernel code. |
| `Std.RegexSafe` (`regex_safe.l`) | `@stable` | Backward-compatible Result wrappers around `Std.RegexHost` (`tryCompile`, `tryIsMatch`, `tryMatchOne`, `tryReplace`) returning `Result[T, RegexError]` where `RegexError` carries `TimedOut` / `RegexBug`.  Retained for existing callers; new code should prefer `Std.Regex` which provides the same surface with a cleaner `CompiledRegex` opaque type. |
| `Std.Random` (`_kernel/random.l`) | `@stable` | Cryptographically-seeded RNG (`randomInt`, `randomDouble`, `randomBool`); kernel-only — no `lyric-stdlib/std/random.l` shim (package opens as `Std.Random` directly from `_kernel/`). |
| `Std.Testing.Mocking` (`testing_mocking.l`) | `@experimental` | Lightweight mock-object helpers for unit tests; bootstrap-grade. |

### Enforcement summary

- The compiler emits **S0001** when a non-experimental `pub` function calls an `@experimental` callee in the same source file.
- `lyric public-api-diff` treats `@experimental` removals/changes as **SemVer no-ops**; only `@stable` (or unannotated) removals/changes trigger a **major-bump warning**.
- Cross-package stability (stable package importing experimental package) is a deferred follow-up that requires extending `Lyric.Verifier.Imports` to carry per-decl stability from the embedded `Lyric.Contract` resource.
