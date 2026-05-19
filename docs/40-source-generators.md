# 40 — Custom Source Generator API

**Status:** Specced in D075.

This document defines the custom source generator API, the `@generate` annotation
form that replaces `@derive`, the `Lyric.GeneratorSdk` contract, and the
compilation pipeline changes required.

---

## 1. Motivation

`@generate(Json)` (the renamed `@derive(Json)`) ships as a compiler built-in today.
Third-party libraries increasingly need the same capability: generate serializers for
custom wire formats, emit ORM column mappers, produce OpenAPI schemas, generate gRPC
stubs from Lyric types, etc. Without an extension point they must either fork the
compiler or fall back to runtime reflection — the latter violates the AOT-safety
guarantee.

A custom source generator API allows any Lyric package to act as a compile-time code
generator. Generators run at compile time, produce Lyric source text, and that text
goes through the normal type checker and emitter. No runtime reflection escapes into
the generated code.

---

## 2. The `@generate` annotation

### 2.1 Unified form

`@derive` is renamed `@generate`. Both built-in and custom generators share the same
annotation surface:

```
@generate(Json)                   // built-in generator
@generate(Proto.Derive)           // custom generator in package "Proto"
@generate(MyOrg.MyPkg.Generator)  // custom generator in nested package
```

The resolver rule is simple: if the argument is a **bare name** (no dots) it resolves
as a built-in generator name. If it contains a dot it resolves as a
`<package>.<generator>` reference where the package must be declared as a dependency
with `kind = "source-generator"` in the consumer's `lyric.toml`.

Multiple generators may be applied to the same type:

```
@generate(Json)
@generate(Proto.Derive)
exposed record Order {
    id: Int
    amount: Double
}
```

### 2.2 Target restrictions

`@generate` may appear on:

- `exposed record`
- `record`
- `union`
- `interface`

It is rejected (diagnostic G0001) on functions, modules, and `wire` blocks — those
are not structural types and generators cannot meaningfully inspect their shape.

### 2.3 Built-in generator names

| Name | Produces |
|------|----------|
| `Json` | `toJson`/`fromJson` (RFC 8259; current `@derive(Json)` behaviour) |
| `Sql` | Column mappers and `INSERT`/`SELECT` builders (planned; Phase 2) |
| `Proto` | `toProto`/`fromProto` over proto3 wire format (planned; Phase 2) |
| `Equals` | Structural equality (`==` / `!=`) — currently auto-applied on records |

The built-in set is closed. Adding a new built-in requires a decision log entry. The
custom generator API is the correct path for everything not in this table.

---

## 3. The generator package contract

### 3.1 `lyric.toml` declaration

A source generator package declares itself with `kind = "source-generator"`:

```toml
[package]
name = "Proto.Derive"
version = "0.1.0"
kind = "source-generator"

[dependencies]
"Lyric.GeneratorSdk" = ">=1.0.0"
```

`lyric publish` enforces that packages with `kind = "source-generator"` export a
function matching the generator entry-point signature (§3.2). Packages without this
kind declaration are rejected as generator arguments at G0002.

### 3.2 Entry point

Every generator package must export exactly one function with this signature:

```lyric
import Lyric.GeneratorSdk

pub func generate(req: GeneratorRequest): GeneratorResponse { ... }
```

The name `generate` is fixed; the compiler locates it by name and signature. A
missing or mismatched entry point is diagnosed at build time (G0003).

### 3.3 `Lyric.GeneratorSdk` types

`Lyric.GeneratorSdk` is a first-party package (`lyric-generator-sdk/`) that provides
the descriptor and response types. It is published alongside the compiler distribution.

```lyric
// Annotation applied to a type or field, as seen in source.
record AnnotationDescriptor {
    name: String
    args: slice[String]    // rendered args, e.g. ["since=\"1.0\"", "Json"]
}

// How a field's type is categorised.
enum FieldTypeKind {
    case Primitive    // Bool, Int, Long, UInt, ULong, Float, Double, Char, String
    case Slice        // slice[T]
    case OptionType   // Option[T]
    case ResultType   // Result[T, E]
    case Named        // any other single-segment name (record, union, alias, distinct)
    case Generic      // multi-argument or type-param reference
}

// A field's resolved type.
record FieldType {
    kind: FieldTypeKind
    name: String              // display form, e.g. "Int", "Option[String]", "MyRecord"
    typeArgs: slice[String]   // inner type names for Slice, Option, Result, Generic
}

record FieldDescriptor {
    name: String
    fieldType: FieldType
    isPublic: Bool
    annotations: slice[AnnotationDescriptor]
}

// The kind of the annotated item.
enum ItemKind {
    case Record
    case ExposedRecord
    case Union
    case Interface
}

record TypeDescriptor {
    kind: ItemKind
    name: String                    // unqualified name, e.g. "Order"
    packageName: String             // fully qualified package, e.g. "MyApp.Models"
    typeParams: slice[String]       // ["T", "E"] for generic types
    fields: slice[FieldDescriptor]  // empty for unions and interfaces
    annotations: slice[AnnotationDescriptor]
}

// The full request handed to the generator entry point.
record GeneratorRequest {
    generatorArg: String          // the argument to @generate, e.g. "Json", "Proto.Derive"
    typeDescriptor: TypeDescriptor
    packageName: String           // package currently being compiled
    sourceFile: String            // source file path (for diagnostic spans)
}

// Severity of a generator diagnostic.
enum GeneratorDiagnosticSeverity {
    case Error
    case Warning
    case Info
}

record GeneratorDiagnostic {
    severity: GeneratorDiagnosticSeverity
    message: String
    code: Option[String]          // e.g. Some("PD001")
}

// What the generator returns.
record GeneratorResponse {
    lyricSource: String               // Lyric source fragment; complete items only
    additionalImports: slice[String]  // e.g. ["import Std.Json"]
    diagnostics: slice[GeneratorDiagnostic]
}
```

`lyricSource` must contain only complete, parseable Lyric items (function declarations,
`impl` blocks, type aliases). The compiler re-parses this string and injects the
resulting items into the file before type checking. A parse error in `lyricSource`
produces diagnostic G0004 pointing at the generator package, not the user's source.

---

## 4. Compilation pipeline

### 4.1 Position in the synthesis chain

Custom generators run as the last step in the pre-type-check synthesis chain, after
all built-in passes:

```
hoistInlineMethods
  → Stubbable.synthesizeItems
  → Wire.synthesizeItems
  → Generate.synthesizeItems          ← replaces JsonDerive.synthesizeItems
      ├── built-in: Json, Sql, Proto, Equals (inline, no subprocess)
      └── custom: subprocess bridge per generator package
```

`Generate.synthesizeItems` handles all `@generate(...)` annotations in one pass,
routing each to the appropriate handler by name.

### 4.2 Custom generator invocation

Custom generators run as a **source pre-processing step** inside the self-hosted
`Lyric.Cli` pipeline, before the file is handed to the F# bootstrap for compilation.
No new F# shim is needed. The steps are:

1. Resolve the generator package from the lock file (must already be present; `lyric
   restore` is a prerequisite, like any other dependency).
2. Compile the generator DLL with `--internal-build` (cached after first compile in
   the build session).
3. Invoke the compiled DLL as a subprocess via a `Process.run` kernel extern:
   serialise the `GeneratorRequest` to JSON on stdin; read the `GeneratorResponse`
   JSON from stdout.
4. If any `Error`-severity diagnostics are present, fail the build with G0005 (report
   each as a child note).
5. Append the returned `lyricSource` to the source text and add `additionalImports`
   to the import list; pass the augmented source to `--internal-build` as normal.

The F# bootstrap compiles the augmented file like any other Lyric source and never
observes the `@generate(Pkg.Name)` annotation directly.

### 4.3 Invocation granularity

One `generate` call is made **per annotated type per generator**. If three records in
the same file carry `@generate(Proto.Derive)`, the generator is called three times
(once per type). The generator package is loaded once per build session (step 2 above
is cached).

Batched invocation (one call per generator per file, receiving all types at once) is
tracked as Q-SG-001 and may be introduced in a later phase without changing the
`GeneratorRequest`/`GeneratorResponse` contract.

### 4.4 AOT safety guarantee

Generator output is validated by the same type checker and emitter that processes
hand-written code. A generator that emits `@externTarget` outside the kernel boundary
or uses `unsafe` constructs is rejected at the same checkpoints as hand-written code.
No special exemptions are granted to generated items.

---

## 5. Consumer usage

### 5.1 Declaring the dependency

In the consuming package's `lyric.toml`:

```toml
[dependencies]
"Proto.Derive" = "^0.1.0"
```

No special syntax beyond a normal dependency. The `kind = "source-generator"` on the
generator package is what causes the compiler to treat it as a generator rather than
an importable library.

A generator dependency may not be imported with `import`. It is only invocable via
`@generate`. Attempting to `import` a source-generator package produces G0006.

### 5.2 Full example

```lyric
@generate(Json)
@generate(Proto.Derive)
exposed record Order {
    id: Int
    customerId: Int
    amountCents: Long
    note: Option[String]
}
```

After synthesis, the compiler sees (approximately):

```lyric
exposed record Order { ... }                      // original

// From built-in Json generator:
pub func Order.toJson(self): String { ... }
pub func Order.fromJson(s: in String): Result[Order, String] { ... }

// From custom Proto.Derive generator:
pub func Order.toProto(self): slice[Byte] { ... }
pub func Order.fromProto(bytes: in slice[Byte]): Option[Order] { ... }
```

Both function sets go through full type checking. If `Proto.Derive` emits a function
with a wrong signature the type checker surfaces a G0004 diagnostic referencing the
generator.

---

## 6. Writing a generator

A minimal generator that adds a `describe()` method:

```lyric
import Lyric.GeneratorSdk

pub func generate(req: GeneratorRequest): GeneratorResponse {
    val typeName = req.typeDescriptor.name
    val fieldList = req.typeDescriptor.fields
        |> map(func(f): String = "\"" + f.name + "\": " + f.fieldType.name)
        |> String.join(", ")
    val body = "\"" + typeName + " { " + fieldList + " }\""
    val src = "pub func " + typeName + ".describe(self): String = " + body + "\n"
    return GeneratorResponse {
        lyricSource = src
        additionalImports = []
        diagnostics = []
    }
}

pub func main(): Int { runGenerator(generate) }
```

Published to NuGet as a package with `kind = "source-generator"` in its `lyric.toml`.
Consumers add it as a regular dependency and annotate types with `@generate(Acme.Describe)`.

---

## 7. Security and trust model

What is enforced today:

- **Opt-in only.** A user must add the generator as an explicit `lyric.toml`
  dependency and annotate a type with `@generate(...)`. No generator executes
  without a deliberate act by the project author.
- **Lock-file integrity.** The lock file (`lyric.lock`) pins every generator to a
  version and SHA-512 checksum. `lyric restore --locked` (the CI flag) refuses to
  update the lock file and fails on any hash mismatch.
- **Output validation.** Generator output is type-checked and mode-checked by the
  full compiler pipeline. A generator cannot inject AOT-unsafe code that would pass
  the compiler's checks, use `@externTarget` outside the kernel boundary, or produce
  ill-typed functions without triggering a build error.

What is **not** enforced (tracked as Q-SG-005):

- **Runtime sandbox.** A generator is compiled Lyric code; it can import `Std.File`,
  `Std.Http`, or other stdlib modules at build time. The opt-in prevents unexpected
  execution, but does not restrict what an explicitly declared generator may do while
  running. Generator sandboxing — restricting imports to `Lyric.GeneratorSdk` and
  `Std.Core`, enforced at `lyric publish` time — is deferred to a future phase.

---

## 8. `Lyric.GeneratorSdk` package location

`lyric-generator-sdk/` at the repository root, structured as a standard Lyric package:

```
lyric-generator-sdk/
  lyric.toml         [package] name = "Lyric.GeneratorSdk"; kind = "library"
  std/
    generator_sdk.l  — the descriptor types above
    _kernel/
      generator_sdk_host.l  — @externTarget bridges for JSON serialization
```

Published as `Lyric.GeneratorSdk` on NuGet. Versioned alongside compiler releases.
Stable API; breaking changes require a major version bump and a decision log entry.

---

## 9. Phasing

| Phase | Deliverable |
|-------|-------------|
| P1 | Rename `@derive` → `@generate` in spec, language reference, and all docs |
| P1 | `Generate.synthesizeItems` unifying the built-in path (replaces `JsonDerive.synthesizeItems`) |
| P1 | Diagnostics G0001–G0003 (annotation target restriction, kind enforcement, missing entry point) |
| P2 | `Lyric.GeneratorSdk` package (`lyric-generator-sdk/`) |
| P2 | Custom generator subprocess bridge via `Process.run` kernel extern (no new `.fs` file) |
| P2 | Diagnostics G0004–G0006 (parse error, error-severity diagnostic, import restriction) |
| P2 | `lyric.toml` `kind = "source-generator"` enforcement in `Manifest.fs` |
| P3 | `@generate(Sql)` built-in |
| P3 | `@generate(Proto)` built-in (backed by `lyric-proto`) |

P1 is a pure renaming pass with no behaviour change. P2 ships the extensibility API.
P3 expands the built-in set.

---

## 10. Open questions

### Q-SG-001: Per-type vs per-file invocation

**Status:** Open.

**Question:** Should `generate` be called once per annotated type (current spec) or
once per generator per file (batched)?

**Context:** Per-type is simpler: one request, one response, clear error attribution.
Per-file is more efficient when a file has many annotated types — the generator
package DLL is already loaded, so the round-trip cost is subprocess overhead plus
serialization, not DLL loading. With in-process loading (§4.2 step 3) the per-type
cost drops to a function call, making batching less important.

**Recommendation:** Per-type for P2. Revisit batching in P3 once real generator
performance data is available. The `GeneratorRequest` → `GeneratorResponse` contract
can remain unchanged; a future batched variant would be a separate entry point
`generateBatch(reqs: slice[GeneratorRequest]): slice[GeneratorResponse]` with opt-in
by the generator package.

### Q-SG-002: Generator applicability to opaque records

**Status:** Open.

**Question:** Should `@generate(...)` be permitted on `opaque` records, or only
`exposed` and plain records?

**Context:** Opaque types have hidden representations. A `toJson` for an opaque record
would expose the internal structure, which may or may not be the author's intent. On
the other hand, `@generate(Logging.Redact)` on an opaque record could produce a safe
log-safe summary that deliberately omits internal fields.

**Options:**
1. Allow on all record kinds; let the generator decide.
2. Allow only on `exposed` and plain records; reject on `opaque` with G0001.
3. Allow with an explicit opt-in annotation (e.g. `@generate_opaque_ok`).

**Recommendation:** Option 1 for now; add the `@generate_opaque_ok` guard if misuse
patterns emerge.

### Q-SG-003: Generator versioning and the compiler API

**Status:** Open.

**Question:** When the `Lyric.GeneratorSdk` types change in a future compiler release,
how are generators that were compiled against an older SDK handled?

**Context:** `FieldTypeKind`, `TypeDescriptor`, etc. are serialized through a JSON
bridge. Adding fields to `GeneratorRequest` in a new SDK version is backwards-compatible
(old generators ignore unknown fields). Removing or renaming fields is breaking.

**Recommendation:** Adopt semantic versioning on `Lyric.GeneratorSdk`. The compiler
advertises the SDK version it ships. Generators declare a `>=` lower bound. The
compiler emits G0007 if a generator's SDK lower bound is higher than the installed
SDK version.

### Q-SG-004: IDE / LSP integration

**Status:** Open.

**Question:** Should the LSP server run generators eagerly (so autocompletion shows
generated members) or lazily (only on explicit build)?

**Context:** Running generators on every keystroke is expensive if they are subprocesses.
With in-process loading the cost is lower. Generated members (e.g. `Order.toProto`) are
invisible to the LSP until the generator has run.

**Recommendation:** LSP runs generators once on file open and on save (debounced, 500 ms).
Results are cached per generator+type hash until the annotated type's AST changes. Tracked
by the LSP plan (`docs/16-lsp-vscode-plan.md`) as a follow-up to basic symbol resolution.

### Q-SG-005: Generator runtime sandboxing

**Status:** Open.

**Question:** Should generator packages be restricted to a subset of the stdlib at
`lyric publish` time, preventing them from accessing the filesystem, network, or
environment variables during compilation?

**Context:** As noted in §7, a declared generator can currently import any stdlib module
and perform arbitrary I/O at build time. This is the same trust model as build scripts in
Cargo or NPM. For a safety-oriented language, stricter sandboxing (allow only
`Lyric.GeneratorSdk` + `Std.Core` imports in generator packages) would be consistent with
the language's philosophy, but adds complexity to the `lyric publish` and `lyric restore`
pipelines.

**Options:**
1. No sandbox. Trust the opt-in + lock-file model (current approach).
2. Import allowlist enforced at `lyric publish` time (generators that import disallowed
   modules are rejected on publish; consumers get a pre-validated guarantee).
3. OS-level sandbox (seccomp/AppArmor on Linux, sandbox profiles on macOS) applied to
   the generator subprocess. Strongest guarantee; highest implementation cost.

**Recommendation:** Option 1 for v1. Option 2 is the right long-term direction and can be
added to the `lyric publish` validation pass without breaking existing generators.
