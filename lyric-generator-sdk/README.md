# lyric-generator-sdk

Source generator SDK for [Lyric](https://github.com/nichobbs/lyric-lang). Provides the type descriptors and response types needed to build custom code generators that run at compile time and emit Lyric source.

> **Status**: Library source is complete. Use this to build custom `@generate` plugins for your applications.

## Packages

| Package | Description |
|---|---|
| `Lyric.GeneratorSdk` | Generator request/response types, type descriptors, annotation introspection |

## Installation

```toml
[dependencies]
"Lyric.GeneratorSdk" = { path = "../lyric-generator-sdk" }
```

Generator packages declare themselves with `kind = "source-generator"`:

```toml
[package]
name = "MyOrg.Proto.Generator"
version = "0.1.0"
kind = "source-generator"

[dependencies]
"Lyric.GeneratorSdk" = ">=1.0.0"
```

## Quick start

### Minimal generator

```lyric
import Lyric.GeneratorSdk
import Std.Core

pub func generate(req: GeneratorRequest): GeneratorResponse {
  val typeName = req.typeDescriptor.name
  
  val source = "
    pub func toString(item: in " + typeName + "): String {
      return \"" + typeName + "\"
    }
  "
  
  GeneratorResponse(
    lyricSource = source,
    additionalImports = [],
    diagnostics = []
  )
}
```

### Generator with diagnostics

```lyric
import Lyric.GeneratorSdk
import Std.Core

pub func generate(req: GeneratorRequest): GeneratorResponse {
  // Check that the type has at least one field
  if req.typeDescriptor.fields.length == 0 {
    return GeneratorResponse(
      lyricSource = "",
      additionalImports = [],
      diagnostics = [
        GeneratorDiagnostic(
          severity = GeneratorDiagnosticSeverity.Error,
          message = "Cannot generate for empty type",
          code = Some("GEN001")
        )
      ]
    )
  }
  
  // Generate code...
  GeneratorResponse(
    lyricSource = "...",
    additionalImports = [],
    diagnostics = []
  )
}
```

## Generator request/response

### `GeneratorRequest`

The compiler passes this to your generator's `generate()` function:

```lyric
record GeneratorRequest {
  generatorArg: String          // the argument to @generate, e.g. "Json", "Proto.Derive"
  typeDescriptor: TypeDescriptor
  packageName: String           // package currently being compiled
  sourceFile: String            // source file path (for diagnostic spans)
}
```

| Field | Description |
|---|---|
| `generatorArg` | The full argument to `@generate`, e.g. `"Proto.Derive"` (used to identify which generator in your package is being invoked) |
| `typeDescriptor` | Full introspection of the type being generated |
| `packageName` | Package name of the file containing `@generate` |
| `sourceFile` | Source file path (for diagnostic attribution) |

### `GeneratorResponse`

Your generator returns this:

```lyric
record GeneratorResponse {
  lyricSource: String               // Lyric source fragment (complete items only)
  additionalImports: slice[String]  // e.g. ["import Std.Json"]
  diagnostics: slice[GeneratorDiagnostic]
}
```

| Field | Description |
|---|---|
| `lyricSource` | Generated Lyric source (functions, `impl` blocks, type aliases). Must be syntactically complete. Parsed and injected into the file before type-checking. |
| `additionalImports` | Import statements to prepend (e.g., `"import Std.Json"`). Deduplicated with existing imports. |
| `diagnostics` | Errors, warnings, and info messages reported by the generator |

### Parsing a subprocess response: `parseResponse`

`parseResponse(json: in String): Result[GeneratorResponse, String]` deserializes
the JSON a generator subprocess writes to stdout. Each `additionalImports`
entry must be exactly a single `import <QualifiedName>` or
`import extern <QualifiedName>` statement, optionally followed by
`as <Identifier>` — `parseResponse` returns `Err` for any entry that isn't
(a missing `import ` prefix, a malformed qualified name, or extra text such
as an embedded newline or `;`-separated second statement). A generator
subprocess is untrusted, and every `additionalImports` entry is spliced
verbatim into the compiled program's source, so this rejects an entry that
could otherwise inject arbitrary source disguised as an import line.

`diagnostics` entries are fully deserialized (severity, message, and an
optional `code`) — previously they were dropped unconditionally, so a
generator's `Error`-severity diagnostics never reached the caller.

`parseResponse` is otherwise lenient: a missing or malformed top-level
field (including an unparseable request overall) degrades to an
empty/default value rather than failing.

### Decoding a request: `parseRequest`

```lyric
pub func parseRequest(json: in String): Result[GeneratorRequest, String]
```

`parseRequest` is the inverse of `serializeRequest`, and is what
`runGenerator` uses to decode the request it reads from stdin. It returns
`Err` for an unsupported `schemaVersion` (it accepts `"1"` and `"2"`; the
compiler sends `"2"`, D151) or a missing
`typeDescriptor.name`; `runGenerator` prints that message prefixed with
`GeneratorSdk:` and exits with code 1. Call it directly to decode a request
in a test without a subprocess round trip.

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
panics. `parseRequest` (and so `runGenerator`) checks this explicitly
before construction (a missing `typeDescriptor` block, or an unrecognized
`kind`, used to silently fall through to an empty-named `Record` rather than
failing): a malformed request now exits with code 1 and a clear message on
stderr instead.

### `ItemKind`

```lyric
union ItemKind {
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
union FieldTypeKind {
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
union GeneratorDiagnosticSeverity {
  case Error      // fails the build
  case Warning    // reported but build continues
  case Info       // informational, not reported by default
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
| `severity` | Error stops the build; Warning is reported; Info is usually silent |
| `message` | Human-readable message, e.g. `"Cannot generate for empty type"` |
| `code` | Optional diagnostic code for documentation / suppression, e.g. `Some("GEN001")` |

## Example: JSON serializer generator

```lyric
import Lyric.GeneratorSdk
import Std.Core

pub func generate(req: GeneratorRequest): GeneratorResponse {
  val typeName = req.typeDescriptor.name
  val fields = req.typeDescriptor.fields
  
  if fields.length == 0 {
    return GeneratorResponse(
      lyricSource = "",
      additionalImports = [],
      diagnostics = [
        GeneratorDiagnostic(
          severity = GeneratorDiagnosticSeverity.Error,
          message = "Cannot generate serializer for empty type",
          code = Some("JSON001")
        )
      ]
    )
  }
  
  // Generate toJson function
  var toJsonBody = ""
  for field in fields {
    toJsonBody = toJsonBody + "    \"" + field.name + "\": " + field.fieldType.name + ".toJson(item." + field.name + "),\n"
  }
  
  val toJson = "
    pub func toJson(item: in " + typeName + "): String {
      return \"{\\n" + toJsonBody + "    }\"
    }
  "
  
  // Generate fromJson function (simplified)
  val fromJson = "
    pub func fromJson(json: in String): Result[" + typeName + ", String] {
      // Parse and validate JSON...
      Ok(" + typeName + "(...))
    }
  "
  
  GeneratorResponse(
    lyricSource = toJson + "\n\n" + fromJson,
    additionalImports = ["import Std.Json"],
    diagnostics = []
  )
}
```

## Usage in user code

Apply the generator with `@generate`:

```lyric
package MyApp.Models

import Std.Core

@generate(MyOrg.JsonGen)
pub record Order {
  id: Int
  customerId: Int
  amount: Double
  status: String
}
```

The compiler:

1. Parses the file and finds `@generate(MyOrg.JsonGen)`
2. Resolves `MyOrg.JsonGen` to your generator package (a `path` or `workspace = true` dependency whose manifest declares `kind = "source-generator"`) and builds it
3. Runs it as `dotnet exec`, sending the request for `Order` on stdin; your `main` calls `runGenerator(generate)`
4. Injects the returned source into the file
5. Re-parses and type-checks the file (now including generated code)

## Best practices

### 1. Validate input

Check that the type is appropriate for code generation:

```lyric
match req.typeDescriptor.kind {
  case Record | ExposedRecord -> {}  // OK
  case Union | Interface -> {
    return GeneratorResponse(
      lyricSource = "",
      additionalImports = [],
      diagnostics = [GeneratorDiagnostic(
        severity = GeneratorDiagnosticSeverity.Error,
        message = "Cannot generate for " + req.typeDescriptor.kind.toString(),
        code = Some("GEN001")
      )]
    )
  }
}
```

### 2. Emit complete items

The `lyricSource` must contain complete, parseable Lyric items:

```lyric
// Good: complete func
"
pub func fromJson(json: in String): Result[Order, String] {
  ...
}
"

// Bad: incomplete fragment
"
if isValid {
  return Ok(order)
}
"
```

### 3. Use `additionalImports`

Let the compiler deduplicate imports:

```lyric
GeneratorResponse(
  lyricSource = "...",
  additionalImports = ["import Std.Json", "import Std.Core"],
  diagnostics = []
)
```

The compiler deduplicates against existing imports in the file.

### 4. Report errors vs. warnings

Use `Error` for validation failures, `Warning` for suspicious patterns, `Info` for notices:

```lyric
GeneratorDiagnostic(
  severity = GeneratorDiagnosticSeverity.Error,
  message = "Type must have at least one field",
  code = Some("GEN001")
)
```

Parse errors in generated source are fatal (compiler diagnostic X0004 points at your generator package).

### 5. Keep generators pure

Generators run at compile time. Avoid:
- Side effects (file I/O, network, environment)
- Non-deterministic output (relying on `Std.Uuid.newUuid`, `Std.Time.now`, or any other runtime-state-dependent function)
- Dependencies on type-checking state (generators can't call the type checker)

## Generator discovery

The compiler locates your generator by:

1. **Package name**: resolving `@generate(MyOrg.Proto.Derive)` to a dependency
2. **Kind**: verifying the dependency has `kind = "source-generator"`
3. **Entry point**: looking for `pub func generate(req: GeneratorRequest): GeneratorResponse` and a `main` that calls `runGenerator(generate)`

If the entry point is missing or mismatched, diagnostic **X0003** is reported at build time.

## Package layout

```
lyric-generator-sdk/
  lyric.toml              package manifest
  README.md               this file
  src/
    generator_sdk.l       Lyric.GeneratorSdk  (types, descriptors, responses)
  tests/
    *_tests.l             test modules
```

## See also

- `docs/40-source-generators.md` — complete design specification
- `docs/03-decision-log.md` D075 — design decisions
