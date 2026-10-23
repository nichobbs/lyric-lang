# lyric-generator-sdk

Source generator SDK for [Lyric](https://github.com/nichobbs/lyric-lang): the API
package of the `SourceGenerator` plugin point (docs/40, docs/69 §15, D207). It
declares the type descriptors the compiler sends, the response a generator
returns, the point itself and the `ProjectRead` capability. A generator is a
plugin; the compiler is its host.

## Packages

| Package | Description |
|---|---|
| `Lyric.GeneratorSdk` | `SourceGenerator` (point version 3.0), `ProjectRead`, the request and response types, `declarationNamed`, `projectPathWithin` |

## Installation

A generator package declares `kind = "source-generator"` and depends on the SDK
by path or as a workspace member:

```toml
[package]
name = "Acme.Describe"
version = "0.1.0"
kind = "source-generator"

[dependencies]
"Lyric.GeneratorSdk" = { path = "../lyric-generator-sdk" }
```

## Quick start

A generator is a `@plugin` record implementing `SourceGenerator`.
`Lyric.PluginExpand` generates the package's `main`, its manifest, the
dispatcher and the JSON codecs, so the package declares no `main` of its own.

```lyric
package Acme.Describe

import Std.Core
import Std.Collections
import Lyric.GeneratorSdk

pub func generateSource(req: in GeneratorRequest): GeneratorResponse {
  val td = req.typeDescriptor
  val src = "pub func " + td.name + ".describe(v: in " + td.name + "): String {\n  \"" + td.name + "\"\n}\n"
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

Keeping the generation in an ordinary function (`generateSource` here) lets a
`@test_module` call it directly with a hand-built `GeneratorRequest`, as
`lyric-forms/derive` and `lyric-ui/routes` do. `examples/generators/describe/`
is the complete example, with a consumer in `examples/generators/app/`.

### Diagnostics and refusals

A problem with the annotated type is a diagnostic in the response:

```lyric
if td.fields.length == 0 {
  val diags: List[GeneratorDiagnostic] = newList()
  diags.add(GeneratorDiagnostic(severity = Error, message = "cannot generate for an empty type", code = Some(value = "GEN001")))
  return GeneratorResponse(lyricSource = "", additionalImports = [], diagnostics = diags.toArray())
}
```

`Err(GeneratorError(message = ...))` from `generate` is for a request the
generator cannot handle at all; the compiler reports it as X0009.

### Reading project files

The `ProjectRead` capability reads text files of the project being compiled,
below the roots the generator asks for (relative to the consuming project's
directory; `"."` is the whole project). Add a client field and a request
function:

```lyric
@plugin(id = "acme.schemas", version = "0.1.0", publisher = "acme", implements(SourceGenerator))
pub record SchemaPlugin {
  files: ProjectReadClient              // Option[ProjectReadClient] to make it optional
}

@plugin_request(ProjectRead)
func schemaRoots(): ProjectReadGrant = ProjectReadGrant(roots = ["schemas"])

impl SourceGenerator for SchemaPlugin {
  func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError] {
    match files.readText("schemas/" + req.typeDescriptor.name + ".json") {
      case Ok(text) -> ...
      case Err(CallError.App(e)) -> ...        // the file could not be read
      case Err(CallError.Boundary(b)) -> ...   // Denied: outside the granted roots
    }
  }
}
```

A path outside the roots, absolute, or with an empty, `.` or `..` segment, a
backslash or a colon is denied before anything is read (`projectPathWithin`).
`ProjectRead` is the route a generator should use for files, but a generator
runs as a dotnet process and is not sandboxed (docs/40 §7).

## The point and the capability

```lyric
@capability(grant = ProjectReadGrant)
pub interface ProjectRead {
  func readText(path: in String): Result[String, String]
    requires: projectPathWithin(path, grant.roots)
}

@plugin_point(version = "3.0", allows(ProjectRead))
pub interface SourceGenerator {
  func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError]
}

pub exposed record ProjectReadGrant { roots: List[String] }
pub record GeneratorError { message: String }
```

`PROTOCOL.md` describes the JSON-RPC exchange and the request and response JSON.

## Generator request/response

### `GeneratorRequest`

```lyric
record GeneratorRequest {
  generatorArg: String          // the argument to @generate, e.g. "Proto.Derive"
  typeDescriptor: TypeDescriptor
  packageName: String           // package currently being compiled
  sourceFile: String            // source file path (for diagnostic spans)
  declarations: slice[DeclarationDescriptor] = []  // same-file declarations
}
```

### `GeneratorResponse`

```lyric
record GeneratorResponse {
  lyricSource: String               // Lyric source fragment (complete items only)
  additionalImports: slice[String]  // e.g. ["import Std.Json"]
  diagnostics: slice[GeneratorDiagnostic]
}
```

| Field | Description |
|---|---|
| `lyricSource` | Generated Lyric items (functions, `impl` blocks, type aliases). Must parse (X0004). Appended to the file before type checking. |
| `additionalImports` | Import statements to add, each exactly one `import <QualifiedName>` or `import extern <QualifiedName>`, optionally `as <Identifier>`. Any other entry fails the response (X0009), since entries are spliced into the consumer's source. |
| `diagnostics` | Errors, warnings and notes, reported under X0005 with their own codes |

## Type descriptors

### `TypeDescriptor`

```lyric
record TypeDescriptor {
  kind: ItemKind                      // Record, ExposedRecord, Union, Interface, Opaque, Enum
  name: String                        // unqualified name, e.g. "Order"
  packageName: String                 // fully qualified, e.g. "MyApp.Models"
  typeParams: slice[String]           // ["T", "E"] for generic types
  fields: slice[FieldDescriptor]      // empty for unions, enums and interfaces
  annotations: slice[AnnotationDescriptor]
  cases: slice[CaseDescriptor] = []            // a union's or enum's cases
  invariants: slice[InvariantDescriptor] = []  // each invariant as source text
  invariant: name.length > 0
}
```

`name` must be non-empty; constructing a `TypeDescriptor` with an empty name
panics. The compiler always sends a name, and the generated decoder rejects a
request with a missing member or an unknown `kind`.

### `ItemKind`

```lyric
enum ItemKind {
  case Record        // regular record
  case ExposedRecord // exposed record (host-visible)
  case Union         // union (discriminated type)
  case Interface     // interface (trait)
  case Opaque        // opaque type
  case Enum          // enum
}
```

### `CaseDescriptor` and `InvariantDescriptor`

```lyric
record CaseDescriptor {
  name: String
  annotations: slice[AnnotationDescriptor]
  fields: slice[FieldDescriptor]     // a positional union field has an empty name
}

record InvariantDescriptor {
  source: String                     // the invariant's expression, as written
  message: Option[String]            // its @message("..."), if any
  line: Int
  column: Int
}
```

A generator can copy `source` into code where each field is bound to a
local of the same name; `Forms.Derive` does this to check invariants before
construction (docs/65 §11.4).

### Same-file declarations

`GeneratorRequest.declarations` lists the enum, distinct and alias
declarations in the annotated type's file that its source names, so a
generator can read an enum field's cases or a range type's bounds.
`declarationNamed(req, name)` finds one:

```lyric
record DeclarationDescriptor {
  name: String
  kind: DeclarationKind              // DeclaredEnum, DeclaredDistinct, DeclaredAlias
  underlying: Option[String]         // a distinct type's or alias's right-hand side
  range: Option[RangeDescriptor]     // {min, max, maxInclusive}, bounds as source text
  cases: slice[CaseDescriptor]       // an enum's cases
}
```

### `FieldDescriptor`

```lyric
record FieldDescriptor {
  name: String
  fieldType: FieldType
  isPublic: Bool
  annotations: slice[AnnotationDescriptor]
  defaultSource: Option[String] = None
}
```

| Field | Description |
|---|---|
| `name` | Field name, e.g. `"orderId"` |
| `fieldType` | Type information (see below) |
| `isPublic` | `true` if declared `pub` |
| `annotations` | Annotations on this field |
| `defaultSource` | The field default's source text, if it has one |

### `FieldType`

```lyric
record FieldType {
  kind: FieldTypeKind
  name: String              // display form, e.g. "Int", "Option[String]", "MyRecord"
  typeArgs: slice[String]   // inner type names for Slice, Option, Result, Generic
}
```

### `FieldTypeKind`

```lyric
enum FieldTypeKind {
  case Primitive    // Bool, Int, Long, UInt, ULong, Float, Double, Char, String
  case Slice        // slice[T]
  case OptionType   // Option[T]
  case ResultType   // Result[T, E]
  case Named        // any other single-segment name (record, union, alias, distinct)
  case Generic      // multi-argument or type-param reference
}
```

### `AnnotationDescriptor`

```lyric
record AnnotationDescriptor {
  name: String
  args: slice[String]    // rendered args, e.g. ["since=\"1.0\"", "Json"]
}
```

Each argument is its source text: `@label("Name")` has the single argument
`"\"Name\""`, a string literal a generator can paste into generated code.

## Diagnostic severity

### `GeneratorDiagnosticSeverity`

```lyric
enum GeneratorDiagnosticSeverity {
  case Error      // fails the build
  case Warning    // reported but build continues
  case Info       // printed as a note
}
```

### `GeneratorDiagnostic`

```lyric
record GeneratorDiagnostic {
  severity: GeneratorDiagnosticSeverity
  message: String
  code: Option[String]    // e.g. Some("PD001")
}
```

| Field | Description |
|---|---|
| `severity` | `Error` fails the build; `Warning` and `Info` are printed |
| `message` | Human-readable message, e.g. `"Cannot generate for empty type"` |
| `code` | Optional diagnostic code for documentation / suppression, e.g. `Some("GEN001")` |

## Usage in user code

```lyric
package MyApp.Models

@generate(Acme.Describe)
pub record Order {
  id: Int
  note: String
}
```

The consumer declares `"Acme.Describe" = { path = "..." }` in `[dependencies]`.
The compiler:

1. Finds `@generate(Acme.Describe)` and checks the generator is a declared
   dependency (X0008) with `kind = "source-generator"` (X0002) and a `@plugin`
   record (X0003).
2. Builds it for dotnet and loads it as a plugin: it probes its manifest, then
   starts one process for the build.
3. Calls `generate` once per annotated type and reports the diagnostics.
4. Checks the returned source parses, appends it to the file and adds the
   imports.
5. Type-checks the file, generated code included.

## Best practices

- **Validate the input.** Check `req.typeDescriptor.kind` and report a
  diagnostic for kinds the generator does not handle.
- **Emit complete items.** `lyricSource` is parsed as top-level items.
- **Use `additionalImports`** rather than writing `import` lines into
  `lyricSource`.
- **Keep generators deterministic.** The same request should give the same
  response: no clocks, random numbers or environment. Read files only through
  `ProjectRead`.
- **Log to stderr.** Stdout carries the protocol.

## Package layout

```
lyric-generator-sdk/
  lyric.toml              package manifest
  README.md               this file
  PROTOCOL.md             the JSON-RPC exchange and the request/response JSON
  src/
    generator_sdk.l       Lyric.GeneratorSdk
  tests/
    generator_sdk_tests.l the types, the generated codecs, projectPathWithin
```

## See also

- `docs/40-source-generators.md`: the generator design
- `docs/69-plugins.md`: plugin points and capabilities
- `docs/decisions/D207-plugin-surface-and-protocol.md`: the plugin surface and wire protocol
