# 48 — Constructor Shorthand for Extern Types

**Status:** Shipped (self-hosted MSIL backend). Implementation leverages Phase 3c
auto-FFI metadata resolution infrastructure. JVM backend already supports `.new()`
syntax.

**Builds on:** `docs/01-language-reference.md` §11.4 (auto-FFI extern types),
`docs/42-extern-metadata-resolution.md` (metadata-based resolution).

**Decision-log entry:** D-progress-263.

**Goal:** Enable direct constructor calls on external types via `.new(args)`
syntax, eliminating boilerplate `@externTarget` wrapper functions and aligning
MSIL behavior with the JVM backend.

---

## 1. Motivation

**Current state (MSIL):**

Constructing an external type requires explicit `@externTarget` wrappers:

```lyric
extern type HostConfig = "Docker.DotNet.DockerClientConfiguration"

@externTarget("Docker.DotNet.DockerClientConfiguration..ctor")
@externStatic
pub func newConfig(uri: in String): HostConfig = ()

val config = newConfig(uri)  // called as a function
```

**Current state (JVM):**

The JVM backend already supports constructor shorthand (§11.4 in language reference):

```lyric
extern type JStringBuilder = "java.lang.StringBuilder"

val sb = JStringBuilder.new("hello")  // direct constructor call
```

**Desired state (both targets):**

```lyric
extern type HostConfig = "Docker.DotNet.DockerClientConfiguration"

val config = HostConfig.new(uri)  // direct, no wrapper needed
```

**Impact:**

- **Reduces boilerplate** — no need to write `@externTarget` wrappers for constructors.
- **Aligns targets** — MSIL and JVM have consistent ergonomics.
- **Mirrors language conventions** — users familiar with `T.new(...)` patterns
  from other languages (Kotlin, Go, TypeScript).
- **Composable with `import extern`** — when used with docs/47, eliminates
  nearly all wrapper functions for simple external-type usage.

---

## 2. Design

### 2.1 Syntax

```lyric
extern type HostConfig = "Docker.DotNet.DockerClientConfiguration"

// Constructor call via .new(args)
val config = HostConfig.new(uri)
val config2 = HostConfig.new(uri, timeout)  // overload resolution
```

**Parsing:**
- `.new` is recognized as a special method name on types (not a keyword).
- Arguments follow standard method-call rules.
- Overload resolution works identically to other auto-FFI method calls.

**Type checking:**
- `HostConfig.new(uri)` is lowered as a method call on the extern type.
- The argument types are used for overload resolution.
- The return type is `HostConfig` (the type itself, not `Option` or `Result`).

### 2.2 Lowering

**MSIL lowering:**

When the type checker encounters `T.new(args)` where `T` is an `extern type`:

1. Look up the external FQN associated with `T`.
2. Query the metadata index (Phase 3c) for the type's constructors.
3. Use overload scoring to find the best matching constructor.
4. Emit `newobj <ctor>` with the resolved constructor signature.

The mechanics already exist in Phase 3c auto-FFI; `.new()` just routes
constructors through that path instead of requiring `@externTarget` wrappers.

**JVM lowering:**

No change; the existing `T.new()` path (§11.4) already does this.

### 2.3 Error handling

**Unresolved constructor:**

```lyric
val x = HostConfig.new()  // no matching constructor
```

If metadata resolution finds no matching constructor, a compile-time diagnostic
is emitted (same as auto-FFI method-call resolution):

```
error[F0001]: No constructor of Docker.DotNet.DockerClientConfiguration
  matches the arguments (no arguments supplied).
  
Candidates:
  - .ctor(String uri)
  - .ctor(String uri, TimeSpan timeout)
```

---

## 3. Implementation

### 3.1 Parser changes

None. `.new` is already recognized as a method name.

### 3.2 Type checker changes

In `lowerMethodCallMsil` or the auto-FFI handler:

1. Detect when the method name is `"new"` and the receiver is an `extern type`.
2. Treat it as a constructor lookup instead of a method lookup.
3. Feed the resolved constructor signature into overload scoring.

Estimated LOC: ~20–40 lines in the existing auto-FFI scoring path.

### 3.3 Codegen changes

In `emitAutoFfiCallMsil` or the constructor emission path:

1. When lowering a resolved constructor (from Phase 3c), emit `newobj`.
2. This likely already works; the change is ensuring the resolver finds
   constructors when looking for `.new()` calls.

Estimated LOC: 0–10 lines (likely already in place).

---

## 4. Impact analysis

### 4.1 Backwards compatibility

Fully backwards compatible. Existing `@externTarget` constructor declarations
continue to work. New code can use `.new()` shorthand.

### 4.2 Example: refactoring HTTP client initialization

**Before:**

```lyric
@externTarget("System.Net.Http.HttpRequestMessage..ctor")
@externStatic
func newRequest(method: in BclHttpMethod, url: in String): HttpRequestMessage = ()

val req = newRequest(httpMethod, url)
```

**After:**

```lyric
import extern System.Net.Http.{HttpRequestMessage}

val req = HttpRequestMessage.new(httpMethod, url)
```

### 4.3 Interaction with import extern (docs/47)

Combined with `import extern`, the gain is substantial:

```lyric
import extern Docker.DotNet.{
  DockerClientConfiguration as HostConfig,
  DockerClient as HostClient
}

pub func createClient(uri: in String): HostClient {
  val config = HostConfig.new(uri)
  HostClient.new(config)  // if HostClient has a constructor taking config
}
```

No `@externTarget`, no wrapper functions, just direct calls.

---

## 5. Known limitations and deferred work

### Value-type constructor detection

The current implementation (D-progress-NNN) hardcodes `valueType = false` when
building the result type. This means value-type constructors (e.g.,
`System.DateTime.new()`, `System.Guid.new()`) are incorrectly classified as
reference types. A workaround is to use `@externTarget` wrappers for value-type
constructors, or to declare them explicitly as `extern type X = "..."` and use
method-call syntax on a receiver. This limitation is tracked as a future
improvement (Q48-004).

### Out of scope for this proposal

- **Q48-001 — Generic constructors** — `List[T].new(capacity)` where `List` is a generic
  extern type. This requires template instantiation at the call site; tracked
  separately as part of generic-FFI (Q022-4, docs/36).
- **Q48-002 — Async constructors** — `async T.new(...)` is not planned.
- **Q48-003 — Static factory methods** — `TimeSpan.fromMinutes(5.0)` is already
  supported via auto-FFI method calls; no special syntax needed.
- **Q48-004 — Value-type constructor result-type inference** — Automatic detection
  of value vs. reference type constructors from metadata (future enhancement).

---

## 6. References

- `docs/01-language-reference.md` §11.4 (auto-FFI extern types, JVM `.new()` form).
- `docs/42-extern-metadata-resolution.md` (Phase 3c auto-FFI infrastructure).
- Epic #1622, Phase 3c (metadata-based overload resolution).
- Existing JVM constructor implementation in `jvm/codegen/04_calls.l`.
