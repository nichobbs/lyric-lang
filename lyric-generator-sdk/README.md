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

## Type descriptors

### `TypeDescriptor`

```lyric
record TypeDescriptor {
  kind: ItemKind                      // Record, ExposedRecord, Union, Interface
  name: String                        // unqualified name, e.g. "Order"
  packageName: String                 // fully qualified, e.g. "MyApp.Models"
  typeParams: slice[String]           // ["T", "E"] for generic types
  fields: slice[FieldDescriptor]      // empty for unions and interfaces
  annotations: slice[AnnotationDescriptor]
}
```

### `ItemKind`

```lyric
union ItemKind {
  case Record        // regular record
  case ExposedRecord // exposed record (host-visible)
  case Union         // union (discriminated type)
  case Interface     // interface (trait)
}
```

### `FieldDescriptor`

```lyric
record FieldDescriptor {
  name: String
  fieldType: FieldType
  isPublic: Bool
  annotations: slice[AnnotationDescriptor]
}
```

| Field | Description |
|---|---|
| `name` | Field name, e.g. `"orderId"` |
| `fieldType` | Type information (see below) |
| `isPublic` | `true` if declared `pub` |
| `annotations` | Annotations on this field |

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
2. Resolves `MyOrg.JsonGen` to your generator package (must be declared as a `kind = "source-generator"` dependency)
3. Calls `MyOrg.JsonGen.generate(req)` with the `TypeDescriptor` for `Order`
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

Parse errors in generated source are fatal (compiler diagnostic G0004 points at your generator package).

### 5. Keep generators pure

Generators run at compile time. Avoid:
- Side effects (file I/O, network, environment)
- Non-deterministic output (relying on `Math.random`, `Date.now`)
- Dependencies on type-checking state (generators can't call the type checker)

## Generator discovery

The compiler locates your generator by:

1. **Package name**: resolving `@generate(MyOrg.Proto.Derive)` to a dependency
2. **Kind**: verifying the dependency has `kind = "source-generator"`
3. **Entry point**: looking for `pub func generate(req: GeneratorRequest): GeneratorResponse`

If the entry point is missing or mismatched, diagnostic **G0003** is reported at build time.

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
