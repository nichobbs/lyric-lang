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

## Phase 1 — Spec and shape (current)

**Goal**: Define stdlib source layout and decide what stays in Lyric source vs. F# shim.

### Deliverables

1. **Source layout**

   ```
   compiler/lyric/std/
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
- 🔄 Error model unions need definition
- 🔄 Parse error handling needs design

---

## Phase 2 — Core coverage (next)

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

## Phase 3 — IO foundation (in progress)

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

## Phase 4 — HTTP / networking (in progress)

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
   - `Http.timeout(request, durationMs): Result[HttpResponse, HttpError]` (deferred to Phase 5 Clock/Duration)
   - `Http.followRedirects(response): Result[HttpResponse, HttpError]` (deferred to redirect policy design)

### Milestones

- **P4.1**: Basic HTTP client drafted (GET, POST with string bodies)
- **P4.2**: Response parsing and error handling drafted
- **P4.3**: Retry source shape drafted; timeout/redirects deferred to Phase 5 policy/runtime support
- **P4.4**: JSON serialization integration

---

## Phase 5 — Application basis and runtime support (in progress)

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
   - REST handler sketch (with wire DI)
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
Phase 1 (current)
├─ Generic Option/Result ✅
├─ IO/Http FFI boundaries ✅
├─ Error model definitions (in progress)
└─ Test harness updates ✅

Phase 2 (core coverage)
├─ Safe parsing for primitives
├─ Container helpers (map, filter on Phase 2.5)
├─ Error unions finalized
└─ String operations

Phase 3 (IO foundation)
├─ Console I/O source API ✅
├─ File operations source API ✅
├─ Path/Directory helpers source API ✅
└─ Stream interfaces ✅, concrete handles pending

Phase 4 (HTTP/networking)
├─ HTTP client basics ✅ source API drafted
├─ Response parsing ✅ source API drafted
├─ High-level helpers 🔄 retry drafted; timeout/redirects deferred
└─ JSON integration pending source-generator work

Phase 5 (app basis)
├─ Environment & process ✅ source API drafted
├─ Time & scheduling ✅ source API drafted
├─ Logging framework ✅ source API drafted
└─ App host ✅ source API drafted

Phase 6 (examples & docs)
├─ Worked examples 🔄 first pass in docs/11
├─ Test coverage
└─ Documentation 🔄 first pass in docs/11
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
- **Async boundaries**: All async stdlib functions use `async func` and return `Task[T]`; blocking shims exist in M1.4 but will be replaced with real async state machines in Phase 4.
