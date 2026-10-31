# 40 — Custom Source Generator API

**Status:** Specced in D075. The consumer side (local generator dependencies built
and run by the compiler, X-series diagnostics) is implemented in D150; the
diagnostics were renamed from G to X there, keeping their numbers. Request schema 2
(annotations, cases, invariants, same-file declarations; §3.4) is implemented in D151,
with two first-party generators built on it: `Forms.Derive` and `Ui.Routes`
(docs/65 §11.6, §6.1). Since D207 a generator is a plugin: a `@plugin` record
implementing the `SourceGenerator` plugin point (version 3.0) of `Lyric.GeneratorSdk`,
run by the compiler as a docs/69 plugin host over the D207 wire protocol (§3.2, §4.2).
Registry and git generators, restored as signed plugin artifacts with their key pinned
in `lyric.lock`, are implemented in D266 (§4.2, §7).
Q-SG-001 and Q-SG-003 are resolved by D207; Q-SG-004 and Q-SG-005 stay open.

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

It is rejected (diagnostic X0001) on functions, modules, and `wire` blocks — those
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
"Lyric.GeneratorSdk" = { path = "../lyric-generator-sdk" }
```

A package with `kind = "source-generator"` must declare a `@plugin` record that
implements `SourceGenerator` (§3.2); the compiler checks this before building it
(X0003). Packages without this kind declaration are rejected as generator
arguments at X0002.

### 3.2 Entry point: a `SourceGenerator` plugin

`Lyric.GeneratorSdk` is the API package of the `SourceGenerator` plugin point
(docs/69, D207). A generator package declares one `@plugin` record that
implements it:

```lyric
import Lyric.GeneratorSdk

@plugin(id = "acme.describe", version = "0.1.0", publisher = "acme", implements(SourceGenerator))
pub record DescribePlugin {}

impl SourceGenerator for DescribePlugin {
  func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError] { ... }
}
```

`Lyric.PluginExpand` generates the package's `main` (a generator package declares
no `main` of its own, K0012), the manifest it prints for
`--lyric-plugin-manifest`, the dispatcher for `generate`, and the codecs for every
request and response type. A problem with the annotated type belongs in the
response's `diagnostics`; `Err(GeneratorError)` is for a request the generator
cannot handle at all, and the compiler reports it as X0009.

A generator that reads project files adds a `ProjectReadClient` field (or an
`Option[ProjectReadClient]` field, to make it optional) and a
`@plugin_request(ProjectRead)` function returning the roots it wants:

```lyric
@plugin(id = "acme.schemas", version = "0.1.0", publisher = "acme", implements(SourceGenerator))
pub record SchemaPlugin {
  files: ProjectReadClient
}

@plugin_request(ProjectRead)
func schemaRoots(): ProjectReadGrant = ProjectReadGrant(roots = ["schemas"])
```

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
    defaultSource: Option[String] = None   // the default's source text (schema 2)
}

// One case of a union or enum (schema 2); a positional union field has an
// empty name.
record CaseDescriptor {
    name: String
    annotations: slice[AnnotationDescriptor]
    fields: slice[FieldDescriptor]
}

// One `invariant:` as source text, with its `@message` (schema 2).
record InvariantDescriptor {
    source: String
    message: Option[String]
    line: Int
    column: Int
}

// The kind of the annotated item.
enum ItemKind {
    case Record
    case ExposedRecord
    case Union
    case Interface
    case Opaque
    case Enum
}

record TypeDescriptor {
    kind: ItemKind
    name: String                    // unqualified name, e.g. "Order"
    packageName: String             // fully qualified package, e.g. "MyApp.Models"
    typeParams: slice[String]       // ["T", "E"] for generic types
    fields: slice[FieldDescriptor]  // empty for unions, enums and interfaces
    annotations: slice[AnnotationDescriptor]
    cases: slice[CaseDescriptor] = []            // schema 2
    invariants: slice[InvariantDescriptor] = []  // schema 2
}

// A same-file enum, distinct type or alias the annotated type names
// (schema 2).
enum DeclarationKind {
    case DeclaredEnum
    case DeclaredDistinct
    case DeclaredAlias
}

record RangeDescriptor {
    min: Option[String]   // source text; None when open
    max: Option[String]
    maxInclusive: Bool
}

record DeclarationDescriptor {
    name: String
    kind: DeclarationKind
    underlying: Option[String]
    range: Option[RangeDescriptor]
    cases: slice[CaseDescriptor]
}

// The full request handed to the generator entry point.
record GeneratorRequest {
    generatorArg: String          // the argument to @generate, e.g. "Json", "Proto.Derive"
    typeDescriptor: TypeDescriptor
    packageName: String           // package currently being compiled
    sourceFile: String            // source file path (for diagnostic spans)
    declarations: slice[DeclarationDescriptor] = []   // schema 2
}

// The declaration of `name` the request carries, if any.
pub func declarationNamed(req: GeneratorRequest, name: String): Option[DeclarationDescriptor]

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

// Why a generator refused a request outright.
record GeneratorError {
    message: String
}

// The project-relative directories a generator may read; "." is the whole project.
exposed record ProjectReadGrant {
    roots: List[String]
}

// The guard of ProjectRead.readText: a relative path with no empty, "." or ".."
// segment, no backslash or colon, inside one of the roots.
pub func projectPathWithin(path: in String, roots: in List[String]): Bool

@capability(grant = ProjectReadGrant)
interface ProjectRead {
    func readText(path: in String): Result[String, String]
        requires: projectPathWithin(path, grant.roots)
}

@plugin_point(version = "3.0", allows(ProjectRead))
interface SourceGenerator {
    func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError]
}
```

`lyricSource` must contain only complete, parseable Lyric items (function declarations,
`impl` blocks, type aliases). The compiler re-parses this string and injects the
resulting items into the file before type checking. A parse error in `lyricSource`
produces diagnostic X0004 at the `@generate` annotation, naming the generator and the
line within the generated code.

### 3.4 Request versions

Until D207 the request carried a `schemaVersion`. It is gone: the request is
versioned with the `SourceGenerator` point (version 3.0; schemas 1 and 2 were the
two stdin/stdout protocol versions before it). A generator built against `3.x`
runs under a compiler offering `3.y`; a different major version is refused when
the generator is loaded (X0009). The request includes everything schema 2 (D151)
added to schema 1:

- annotations on the type, its fields and its cases, with each argument's
  source text;
- type parameters and field defaults;
- union and enum cases;
- invariants as source text, with their `@message`;
- the `Opaque` and `Enum` kinds;
- `declarations`.

`declarations` lists the enum, distinct and alias declarations in the
same file that the annotated type's source names. With it a generator can
read an enum field's cases or a range type's bounds; the preprocessor runs
on one file before type checking, so nothing outside the file is
described.

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
      └── custom: SourceGenerator plugins (one process per generator per build)
```

`Generate.synthesizeItems` handles all `@generate(...)` annotations in one pass,
routing each to the appropriate handler by name.

### 4.2 Custom generator invocation

Custom generators run as a **source pre-processing step** inside the self-hosted
compiler pipeline, before the file enters the in-process MSIL bridge (or the
stage-0 `--internal-build` path that backs it during the bootstrap transition).
No new F# shim is needed. The steps are:

1. Resolve the generator package: a `path = "..."` or `{ workspace = true }`
   dependency whose manifest declares `kind = "source-generator"`, or a
   registry or git dependency whose restored package carries a signed plugin
   artifact under `lyric-plugin/` (D266). A restored generator is not built
   (steps 2 and the probe in step 3 are skipped): `lyric restore` verified its
   signature and pinned its key id in `lyric.lock`, and it is loaded with
   `Std.Plugin.discoverPlugins` under that key alone, which checks the
   signature and every file again. A changed key needs `lyric restore
   --update <name>`; see §7.
2. Check it declares a `@plugin` record (X0003), and build it for dotnet
   with the normal dependency build, which skips an up-to-date build. Its own
   `path` and `workspace = true` dependencies (such as `Lyric.GeneratorSdk`)
   are built first, bottom-up, and a dependency rebuilt since the generator
   was built makes the generator stale. A
   generator always runs on the build host, so it is built for dotnet whatever
   the consumer's `--target` (D150).
3. Load it as a plugin. The compiler is a `Std.Plugin` host offering the
   `SourceGenerator` point (3.0) and the `ProjectRead` capability. On the first
   `@generate` naming a path or workspace generator it runs `dotnet exec <dll>
   --lyric-plugin-manifest`, checks that the manifest implements
   `Lyric.GeneratorSdk.SourceGenerator`, and registers it with a `dotnet exec`
   payload. The grant policy grants exactly the capabilities the generator
   requests: the compiler only runs generators the manifest declares (X0008),
   and `ProjectRead` cannot reach outside the consuming project's directory.
   The process starts on the first call and serves every annotated type of the
   build; the compiler stops it when the build ends. Each annotation is one
   `Lyric.GeneratorSdk.SourceGenerator/generate` call with params
   `{"req": <GeneratorRequest>}` (`lyric-generator-sdk/PROTOCOL.md`). A failed
   manifest probe, a manifest that does not implement the point, an
   `Err(GeneratorError)`, a malformed response, a crash or a call longer than
   60 s is X0009; a crashed generator is not restarted.
4. Report every diagnostic the generator returned under X0005, with its own
   code: an `Error` fails the build, a `Warning` or `Info` is printed.
5. Check the returned `lyricSource` parses (X0004), then append it to the source
   text and append `additionalImports` to the `package` declaration
   (`package P; import A`), so the consumer's own lines keep their numbers;
   pass the augmented source to the compiler as normal.

The compiler processes the augmented file like any other Lyric source and never
observes the `@generate(Pkg.Name)` annotation directly.

### 4.3 Invocation granularity

One `generate` call is made **per annotated type per generator**. If three records in
the same file carry `@generate(Proto.Derive)`, the generator is called three times
(once per type), on one process: a generator is built once and started once per build.
Batching is not offered (Q-SG-001).

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
`@generate`. Attempting to `import` a source-generator package produces X0006.

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
pub func Order.fromJsonElement(elem: in JsonElement): Result[Order, String] { ... }

// From custom Proto.Derive generator:
pub func Order.toProto(self): slice[Byte] { ... }
pub func Order.fromProto(bytes: in slice[Byte]): Option[Order] { ... }
```

Both function sets go through full type checking. A type error in generated code is
reported against the consumer's file, after the comment line that names the
generator (`// @generate(Proto.Derive) generated for Order`); only a parse error is
attributed to the generator itself (X0004).

---

## 6. Writing a generator

A minimal generator that adds a `describe()` method:

```lyric
package Acme.Describe

import Std.Core
import Std.Collections
import Lyric.GeneratorSdk

pub func generateSource(req: in GeneratorRequest): GeneratorResponse {
  val td = req.typeDescriptor
  var fields = ""
  var i = 0
  while i < td.fields.length {
    if i > 0 {
      fields = fields + ", "
    }
    fields = fields + td.fields[i].name + ": " + td.fields[i].fieldType.name
    i += 1
  }
  val src = "pub func " + td.name + ".describe(v: in " + td.name + "): String {\n  \"" + td.name + " { " + fields +
    " }\"\n}\n"
  val none: List[String] = newList()
  val diags: List[GeneratorDiagnostic] = newList()
  GeneratorResponse(lyricSource = src, additionalImports = none.toArray(), diagnostics = diags.toArray())
}

@plugin(id = "acme.describe", version = "0.1.0", publisher = "acme", implements(SourceGenerator))
pub record DescribePlugin {}

impl SourceGenerator for DescribePlugin {
  func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError] {
    Ok(value = generateSource(req))
  }
}
```

The full example, which also warns on unions and interfaces, is
`examples/generators/describe/`. Consumers add it as a `path` or `workspace = true`
dependency and annotate types with `@generate(Acme.Describe)`.

To share a generator beyond a workspace, publish it: `lyric publish --sign-key
<secret-key-file>` (or `LYRIC_PLUGIN_SIGNING_KEY`) on a `kind =
"source-generator"` package packs it with `lyric plugin pack`, signs the artifact
and pushes a package holding only `lyric-plugin/<id>-<version>/` and
`lyric-plugin/signer.pub` (D266). Consumers then depend on it by version, `"Acme.Describe"
= "0.1.0"`, optionally pinning the publisher key with `{ version = "0.1.0", key =
"lyric-ed25519:..." }`. A git dependency works the same way when the repository
commits that `lyric-plugin/` layout.

---

## 7. Security and trust model

What is enforced today:

- **Opt-in only.** A user must add the generator as an explicit `lyric.toml`
  dependency and annotate a type with `@generate(...)`. No generator executes
  without a deliberate act by the project author.
- **Lock-file integrity.** The lock file (`lyric.lock`) pins every generator to a
  version and SHA-512 checksum. `lyric restore --locked` (the CI flag) refuses to
  update the lock file and fails on any hash mismatch.
- **Signed restored generators (D248 Decision 7, D266).** A registry or git
  generator is a signed plugin artifact, verified by `lyric restore` and again when
  it is loaded. Its key is the one the dependency pins with `key = "..."`, or else
  the one the package ships, trusted on first restore; `lyric.lock` records the key
  id, a different key fails the restore until `lyric restore --update <name>`, and
  `--locked` fails on it. Path and workspace generators are the project's own
  source and are not signed.
- **Output validation.** Generator output is type-checked and mode-checked by the
  full compiler pipeline. A generator cannot inject AOT-unsafe code that would pass
  the compiler's checks, use `@externTarget` outside the kernel boundary, or produce
  ill-typed functions without triggering a build error.
- **Declared file access.** The one capability the compiler offers, `ProjectRead`,
  reads only files under the roots the generator requested, relative to the
  consuming project's directory; a path that is absolute, contains `.` or `..`
  segments, a backslash or a colon, or lies outside the roots is denied before the
  read (`Denied`, JSON-RPC error -32040). The check is also made on the resolved
  path (`Std.File.realPath`): a symbolic link inside a root that leads outside it
  (a file link, a linked directory on the way, a link cycle) is denied the same
  way, and the file that is read is the resolved one.

What is **not** enforced (tracked as Q-SG-005):

- **Runtime sandbox.** A generator runs as a `dotnet` process (D207: generator
  packages are built for dotnet by the compiler, and no wasm payload is built for
  them). It is compiled Lyric code and can import `Std.File`, `Std.Http` or other
  stdlib modules, so `ProjectRead` is the route a well-behaved generator uses, not
  a boundary a hostile one cannot cross. Running generators as wasm payloads, where
  `ProjectRead` would be the only I/O (docs/69 §9.2), is the planned answer.

---

## 8. `Lyric.GeneratorSdk` package location

`lyric-generator-sdk/` at the repository root, structured as a standard Lyric package:

```
lyric-generator-sdk/
  lyric.toml         [package] name = "Lyric.GeneratorSdk"
  src/
    generator_sdk.l  - the descriptor and response types, SourceGenerator, ProjectRead
  tests/
    generator_sdk_tests.l
  PROTOCOL.md        - the JSON-RPC exchange and the request and response JSON
```

The SDK is pure Lyric over `Std.*`; it has no kernel file and no hand-written
protocol code (`Lyric.PluginExpand` generates the codecs). A generator depends on
it by path or as a workspace member. `examples/generators/` holds a working
generator (`Acme.Describe`) and a consumer that CI builds and runs on dotnet and
JVM (`scripts/ci/source-generator-e2e.sh`).

---

## 9. Phasing

| Phase | Deliverable |
|-------|-------------|
| P1 | Rename `@derive` → `@generate` in spec, language reference, and all docs |
| P1 | `Generate.synthesizeItems` unifying the built-in path (replaces `JsonDerive.synthesizeItems`) |
| P1 | Diagnostics X0001–X0003 (annotation target restriction, kind enforcement, missing entry point) |
| P2 | `Lyric.GeneratorSdk` package (`lyric-generator-sdk/`) |
| P2 | Custom generator subprocess bridge via `Process.run` kernel extern (no new `.fs` file) |
| P2 | Diagnostics X0004–X0006 (parse error, error-severity diagnostic, import restriction) |
| P2 | `lyric.toml` `kind = "source-generator"` enforcement in `Manifest.fs` |
| P2 | Diagnostic X0008 (`@generate(Pkg.Name)` references a package not declared in `[dependencies]`) — supply-chain guard so a generator can't run unless the manifest opted into it. |
| P2 | Generators as `SourceGenerator` plugins (docs/69 §15, D207): `Lyric.GeneratorSdk` is the point's API package, the compiler is a `Std.Plugin` host, the `ProjectRead` capability |
| P3 | `@generate(Sql)` built-in |
| P3 | `@generate(Proto)` built-in (backed by `lyric-proto`) |

P1 is a pure renaming pass with no behaviour change. P2 ships the extensibility API.
P3 expands the built-in set.

---

## 10. Open questions

### Q-SG-001: Per-type vs per-file invocation

**Status:** Resolved (D207). Per-type stays. A generator is now a plugin whose one
process serves every annotated type of a build, so a call per type is a request on an
open connection, not a process start, and the cost batching was meant to save is gone.
No `generateBatch` method is added; a minor version of `SourceGenerator` could add one
later without breaking existing generators.

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
2. Allow only on `exposed` and plain records; reject on `opaque` with X0001.
3. Allow with an explicit opt-in annotation (e.g. `@generate_opaque_ok`).

**Recommendation:** Option 1 for now; add the `@generate_opaque_ok` guard if misuse
patterns emerge.

### Q-SG-003: Generator versioning and the compiler API

**Status:** Resolved (D207). The request and response are versioned with the
`SourceGenerator` plugin point (3.0). The plugin handshake reports the point version a
generator was built against; a generator built against another major version is refused
at load (X0009, the docs/69 `K0103` case), a minor version may add methods (a generator
that does not implement one answers `Unsupported`), and the decoders ignore unknown JSON
members. X0007 is not used. The recommendation below was the pre-D207 plan.

**Question:** When the `Lyric.GeneratorSdk` types change in a future compiler release,
how are generators that were compiled against an older SDK handled?

**Context:** `FieldTypeKind`, `TypeDescriptor`, etc. are serialized through a JSON
bridge. Adding fields to `GeneratorRequest` in a new SDK version is backwards-compatible
(old generators ignore unknown fields). Removing or renaming fields is breaking.

**Recommendation:** Adopt semantic versioning on `Lyric.GeneratorSdk`. The compiler
advertises the SDK version it ships. Generators declare a `>=` lower bound. The
compiler emits X0007 if a generator's SDK lower bound is higher than the installed
SDK version.

### Q-SG-004: IDE / LSP integration

**Status:** Open. The language server runs `Lyric.PluginExpand` (D289) but does not run
generators yet; the plugin form gives it a long-lived process to call.

**Question:** Should the LSP server run generators eagerly (so autocompletion shows
generated members) or lazily (only on explicit build)?

**Context:** Running generators on every keystroke is expensive if they are subprocesses.
With in-process loading the cost is lower. Generated members (e.g. `Order.toProto`) are
invisible to the LSP until the generator has run.

**Recommendation:** LSP runs generators once on file open and on save (debounced, 500 ms).
Results are cached per generator+type hash until the annotated type's AST changes. Tracked
by the LSP plan (`docs/16-lsp-vscode-plan.md`) as a follow-up to basic symbol resolution.

### Q-SG-005: Generator runtime sandboxing

**Status:** Open. D207 adds the `ProjectRead` capability, but generators still run as
`dotnet` processes with ambient I/O (§7). The direction is a wasm payload for
generators (docs/69 §9.2), where the granted capabilities are the only I/O.

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

### Related: plugin points (docs/69)

Generators are the first plugin point of `docs/69-plugins.md` (§15 there, D207). The
fixed `generate` entry point and the hand-written stdin/stdout protocol are replaced by
the `SourceGenerator` point, one generator process lives for a whole build (Q-SG-001),
and a wasm payload remains the planned answer to Q-SG-005.
