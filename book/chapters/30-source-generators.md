# Source Generators

When you annotate an `exposed record` with `@generate(Json)`, the compiler synthesises `toJson` and `fromJson` for you. No hand-written serialisation code, no runtime reflection, no startup cost — just generated functions that look and behave exactly like code you wrote yourself. This is Lyric's source generator model.

The built-in generators (`Json`, `Sql`, `Proto`) cover the most common structured-output needs. But the same mechanism is open to any package in the ecosystem. A generator is a normal Lyric package that the compiler calls at build time to produce more Lyric code. If you are writing a library that needs to inspect a user's record type and emit boilerplate — custom serializers, schema documentation, mapper functions, audit helpers — a source generator is the right tool.

This chapter covers both sides: how to use generators as a consumer, and how to write one as a library author.

---

## §30.1 The `@generate` annotation

`@generate` takes a single argument that names the generator to invoke. The argument is either a **bare name** (built-in) or a **dotted package reference** (custom):

```lyric
@generate(Json)           // built-in — no dot
@generate(Csv.Derive)     // custom — package "Csv.Derive"
```

The rule is mechanical: if the argument contains a dot, the compiler resolves it as a source-generator package; if not, it matches against the built-in set.

Multiple generators may be applied to the same type — each produces independent output and the results are all injected before type checking:

```lyric
@generate(Json)
@generate(Csv.Derive)
pub exposed record SalesRow {
  region:     String
  product:    String
  unitsSold:  Int
  revenueCents: Long
}
```

After synthesis, the type gains `toJson`, `fromJson` (from the built-in), and `toCsv`, `fromCsv` (from the custom generator). From the type checker's perspective all four are ordinary functions.

### §30.1.1 Where `@generate` is permitted

`@generate` may appear on `record`, `exposed record`, `opaque type`, `union`, `enum` and `interface`. It is not permitted on functions, `wire` blocks, or `config` blocks — those are not structural types and generators cannot meaningfully inspect their shape (diagnostic X0001).

### §30.1.2 Built-in generators

| Name | What it generates |
|------|-------------------|
| `Json` | `toJson(self): String`, `fromJson(s: String): Result[T, String]`, and `fromJsonElement(elem: JsonElement): Result[T, String]` |
| `Sql` | Column mappers and `INSERT`/`SELECT` query builders (Phase 2) |
| `Proto` | `toProto(self): slice[Byte]` and `fromProto(bytes: slice[Byte]): Option[T]` (Phase 2) |
| `Equals` | Structural `==` / `!=` — auto-applied on `record` and `union` types |

The built-in set is closed. New built-ins require a compiler change and a decision log entry. The custom generator API is the correct path for everything else.

---

## §30.2 Consuming a custom generator

From the consumer's perspective, a source generator is an ordinary local dependency: a `path` dependency, or a `workspace = true` one when both projects are in a workspace. Add it to `lyric.toml`:

```toml
[package]
name    = "Sales.Reports"
version = "0.1.0"

[dependencies]
"Csv.Derive" = { path = "../csv-derive" }
```

Nothing else is needed. When you build, the compiler sees that `Csv.Derive`'s own manifest says `kind = "source-generator"`, builds it (skipping that when it is up to date), and runs it over every type you annotate. It is built for .NET and run with `dotnet exec` whatever `--target` you build for, so the same generator serves a JVM or native build. A generator registered in a package registry or fetched from git cannot be used yet (diagnostic X0009). Annotate types as needed:

```lyric
package Sales.Reports

import Std.Core

@generate(Csv.Derive)
pub exposed record SalesRow {
  region:     String
  product:    String
  unitsSold:  Int
  revenueCents: Long
}
```

There is no `import Csv.Derive` — source-generator packages cannot be imported; they are only invocable via `@generate` (attempting an import produces diagnostic X0006). The generated functions appear in the same namespace as your type and are visible to the rest of the package like any other member.

### §30.2.1 What the generated code looks like

The compiler injects the generator's output as plain Lyric items before type checking. Assuming `Csv.Derive` emits a `toCsv` and `fromCsv` pair, the type checker sees something equivalent to:

```lyric
pub func SalesRow.toCsv(self): String {
  format4("{0},{1},{2},{3}",
    self.region, self.product,
    toString(self.unitsSold), toString(self.revenueCents))
}

pub func SalesRow.fromCsv(line: in String): Option[SalesRow] {
  // ... field splitting and parsing ...
}
```

Because generated items go through the full type checker, a generator that emits a type mismatch or uses an undefined function produces a normal compiler diagnostic — the error message points at the generator package name so you know where to look.

---

## §30.3 Writing a generator

### §30.3.1 Package manifest

A source generator declares itself with `kind = "source-generator"` in its `lyric.toml`:

```toml
[package]
name    = "Csv.Derive"
version = "1.0.0"
authors = ["You <you@example.com>"]
kind    = "source-generator"

[dependencies]
"Lyric.GeneratorSdk" = "^1.0"
```

`kind = "source-generator"` is what tells the compiler to treat this package as a generator rather than an importable library. When a consumer's build prepares the generator, the compiler checks that it declares `generate` and a `main` that runs it (diagnostic X0003 if either is missing).

### §30.3.2 The entry point

Every generator exports exactly one function:

```lyric
import Lyric.GeneratorSdk

pub func generate(req: GeneratorRequest): GeneratorResponse { ... }
```

The name `generate` is fixed. The compiler locates it by name and signature after loading the package.

### §30.3.3 `GeneratorRequest`

The `GeneratorRequest` type describes the annotated type in full:

```lyric
type GeneratorRequest = record {
  generatorArg:   String         // "Csv.Derive" — the annotation argument
  typeDescriptor: TypeDescriptor // the annotated type
  packageName:    String         // package being compiled, e.g. "Sales.Reports"
  sourceFile:     String         // source file path, for diagnostic messages
  declarations:   slice[DeclarationDescriptor]  // same-file types it names
}

type TypeDescriptor = record {
  kind:        ItemKind                 // Record | ExposedRecord | Opaque | Union | Enum | Interface
  name:        String                   // unqualified name, e.g. "SalesRow"
  packageName: String                   // fully qualified package
  typeParams:  slice[String]            // type parameters, e.g. ["T", "E"]
  fields:      slice[FieldDescriptor]
  annotations: slice[AnnotationDescriptor]
  cases:       slice[CaseDescriptor]    // a union's or enum's cases
  invariants:  slice[InvariantDescriptor]  // each as {source, message, line, column}
}

type FieldDescriptor = record {
  name:      String
  fieldType: FieldType
  isPublic:  Bool
  annotations: slice[AnnotationDescriptor]  // each argument as its source text
  defaultSource: Option[String]             // the field default, as source text
}

type FieldType = record {
  kind:     FieldTypeKind  // Primitive | Slice | OptionType | ResultType | Named | Generic
  name:     String         // display form: "Int", "Option[String]", "SalesRow"
  typeArgs: slice[String]  // inner type names for Slice, Option, Result, Generic
}
```

### §30.3.4 `GeneratorResponse`

```lyric
type GeneratorResponse = record {
  lyricSource:       String          // Lyric source items to inject
  additionalImports: slice[String]   // e.g. ["import Std.String"]
  diagnostics:       slice[GeneratorDiagnostic]
}

type GeneratorDiagnostic = record {
  severity: GeneratorDiagnosticSeverity  // Error | Warning | Info
  message:  String
  code:     Option[String]               // e.g. Some("CSV001")
}
```

`lyricSource` must contain complete, parseable Lyric items — function declarations, `impl` blocks, type aliases. Partial statements are not valid. If `lyricSource` fails to parse, the compiler emits X0004 at the `@generate` annotation, naming the generator and the line within the generated code.

Any `Error`-severity diagnostic in `diagnostics` fails the build; each is reported as its own X0005 error. `Warning` and `Info` diagnostics surface in compiler output without failing the build.

---

## §30.4 A complete example: CSV generator

Here is a complete `Csv.Derive` source generator that emits `toCsv` and `fromCsv` for records whose fields are all primitives.

```lyric
package Csv.Derive

import Lyric.GeneratorSdk
import Std.Core
import Std.String
import Std.Collections

pub func generate(req: GeneratorRequest): GeneratorResponse {
  val td = req.typeDescriptor
  val typeName = td.name

  // Validate: only supported on records and exposed records
  match td.kind {
    case Union | Interface ->
      return GeneratorResponse {
        lyricSource       = ""
        additionalImports = []
        diagnostics       = [GeneratorDiagnostic {
          severity = GeneratorDiagnosticSeverity.Error
          message  = "@generate(Csv.Derive) only supports record and exposed record types"
          code     = Some("CSV001")
        }]
      }
    case _ -> ()
  }

  // Check all fields are primitives we can handle
  val unsupported = td.fields
    |> filter(func(f): Bool = not isSupportedField(f))
  if List.length(unsupported) > 0 {
    val names = unsupported |> map(func(f): String = f.name) |> String.join(", ")
    return GeneratorResponse {
      lyricSource       = ""
      additionalImports = []
      diagnostics       = [GeneratorDiagnostic {
        severity = GeneratorDiagnosticSeverity.Error
        message  = "unsupported field types in @generate(Csv.Derive): " + names
        code     = Some("CSV002")
      }]
    }
  }

  val toCsvBody   = buildToCsv(typeName, td.fields)
  val fromCsvBody = buildFromCsv(typeName, td.fields)

  return GeneratorResponse {
    lyricSource       = toCsvBody + "\n\n" + fromCsvBody
    additionalImports = ["import Std.String", "import Std.Core"]
    diagnostics       = []
  }
}

func isSupportedField(f: FieldDescriptor): Bool =
  match f.fieldType.kind {
    case Primitive -> true
    case _         -> false
  }

func buildToCsv(typeName: String, fields: slice[FieldDescriptor]): String {
  val fieldExprs = fields
    |> map(func(f): String = csvRenderExpr(f))
    |> String.join(" + \",\" + ")
  return "pub func " + typeName + ".toCsv(self): String =\n  " + fieldExprs
}

func csvRenderExpr(f: FieldDescriptor): String =
  match f.fieldType.name {
    case "String" -> "self." + f.name
    case _        -> "toString(self." + f.name + ")"
  }

func buildFromCsv(typeName: String, fields: slice[FieldDescriptor]): String {
  val n = List.length(fields)
  var body = "pub func " + typeName + ".fromCsv(line: in String): Option[" + typeName + "] {\n"
  body = body + "  val parts = String.split(line, \",\")\n"
  body = body + "  if List.length(parts) != " + toString(n) + " { return None }\n"
  var i = 0
  for f in fields {
    body = body + "  val " + f.name + " = " + parseExpr(f, i) + "\n"
    i = i + 1
  }
  val fieldInits = fields
    |> map(func(f): String = f.name + " = " + f.name)
    |> String.join(", ")
  body = body + "  Some(" + typeName + "(" + fieldInits + "))\n}"
  return body
}

func parseExpr(f: FieldDescriptor, idx: Int): String =
  match f.fieldType.name {
    case "String" -> "parts[" + toString(idx) + "]"
    case "Int"    -> "Std.Parse.parseInt(parts[" + toString(idx) + "]) ?? 0"
    case "Long"   -> "Std.Parse.parseLong(parts[" + toString(idx) + "]) ?? 0"
    case _        -> "parts[" + toString(idx) + "]"
  }
```

This is a bootstrap-quality implementation — it handles the happy path but is not production-hardened (no CSV quoting, limited numeric types). A real generator would be more thorough, but this illustrates all the key patterns.

---

## §30.5 Generator diagnostics in practice

Every generator problem is reported at the `@generate` annotation, in the same form as any other build error. When a generator returns an `Error` diagnostic:

```
src/models.l: error[X0005] 14:1: generator 'Csv.Derive' on SalesRow [CSV002]: unsupported field types in @generate(Csv.Derive): tags
```

`CSV002` is the code the generator chose to emit; it can be anything that helps the user understand what went wrong. Providing a code is optional but recommended — it makes it easy to search for in the generator's documentation. A `Warning` or `Info` diagnostic is printed the same way as `warning[X0005]` or `note[X0005]` and does not fail the build.

The full set:

| Code | Meaning |
|---|---|
| X0001 | `@generate(Pkg.Name)` on something that is not a record, exposed record, opaque type, union, enum or interface. |
| X0002 | The named dependency's manifest does not declare `kind = "source-generator"`. |
| X0003 | The generator declares no `generate` entry point, or no `main` that calls `runGenerator(generate)`. |
| X0004 | The generator returned code that does not parse; the message gives the line within the generated code. |
| X0005 | The generator reported a diagnostic. |
| X0006 | A source-generator package is imported. |
| X0008 | The generator is not declared in `[dependencies]`. |
| X0009 | The generator could not be built or run: its build failed, it exited non-zero, wrote no or malformed JSON, ran longer than 60 seconds, or is a registry or git dependency. |

If a file has several failing annotations, all of them are reported.

---

## §30.6 Testing a generator

A generator is a regular Lyric package and can be tested with `lyric test`. The simplest approach is to call `generate` directly with a hand-constructed `GeneratorRequest` and assert on the response:

```lyric
@test_module
package Csv.Derive.Tests

import Lyric.GeneratorSdk
import Csv.Derive
import Std.Testing

@test
func test_generates_toCsv_for_simple_record(): Unit {
  val req = GeneratorRequest {
    generatorArg   = "Csv.Derive"
    packageName    = "TestPkg"
    sourceFile     = "test.l"
    typeDescriptor = TypeDescriptor {
      kind        = ItemKind.ExposedRecord
      name        = "Row"
      packageName = "TestPkg"
      typeParams  = []
      annotations = []
      fields      = [
        FieldDescriptor {
          name      = "region"
          isPublic  = true
          annotations = []
          fieldType = FieldType { kind = FieldTypeKind.Primitive, name = "String", typeArgs = [] }
        },
        FieldDescriptor {
          name      = "sales"
          isPublic  = true
          annotations = []
          fieldType = FieldType { kind = FieldTypeKind.Primitive, name = "Int", typeArgs = [] }
        }
      ]
    }
  }
  val resp = generate(req)
  assertEq(resp.diagnostics, [])
  assertTrue(String.contains(resp.lyricSource, "func Row.toCsv"))
  assertTrue(String.contains(resp.lyricSource, "func Row.fromCsv"))
}
```

Testing at this level verifies the generator logic in isolation, without invoking the full compiler. For end-to-end verification, create a small consumer package in a test fixture, annotate a record, build it, and assert on the compiled output.

---

## §30.7 Publishing a generator

Publishing is identical to any other Lyric package:

```sh
lyric publish
```

`lyric publish` checks that the entry point exists and has the correct signature before allowing publication. The package appears on NuGet with `kind = source-generator` recorded in its metadata, so `lyric search` and the LSP can identify generator packages distinctly from library packages.

Consuming a published generator from the registry is not supported yet: the compiler needs a generator's source to build it, so today a consumer depends on it by path or as a workspace member (X0009 otherwise).

---

## §30.8 What generators can and cannot see

**Can see:**
- The annotated type's name, kind, fields, field types, defaults, cases, invariants (as source text, with their `@message`), and annotations (each argument as source text)
- The enum, distinct and alias declarations in the same file that the annotated type names (`req.declarations`; `declarationNamed(req, name)` finds one), so an enum field's cases and a range type's bounds are visible
- The annotation argument (`req.generatorArg`)
- The source file path and package name (for error messages)

**Cannot see:**
- Any other type: records, unions and interfaces, and every declaration in another file
- The full file AST
- The compiler's internal representation
- Other generators' output

This is intentional. Generators receive the minimal information needed to generate code for their annotated type. If you need cross-type information — for example, generating a registry of all types that carry a particular annotation — that is a multi-pass concern that belongs in a different tool (post-build analysis, a custom CLI step, etc.).

---

## §30.9 Design notes

**Why not macros?** A macro system would provide more power — a macro can rewrite arbitrary syntax, not just append items to a type. The power is also the problem: macros degrade tooling (the LSP has to understand macro expansion), make code harder to read, and create a parallel language that learners must also master. Source generators are deliberately less powerful. They receive a structured descriptor and return source text; they cannot observe the surrounding code or rewrite anything they did not generate. This constraint makes generators composable, auditable, and tool-friendly.

**Why not runtime reflection?** Runtime reflection is incompatible with opaque types (it can crack open the internal representation) and incompatible with Native AOT (which requires a closed world at build time). Source generators are the compile-time substitute: they produce the same result — functions that know the type's shape — but at build time, as typed code that the compiler can check and the AOT toolchain can include.

**AOT safety.** Generator output goes through the full compiler pipeline. A generator that emits an `@externTarget` outside the kernel boundary, uses an undefined function, or produces a type mismatch will be rejected at the same checkpoints as hand-written code. No special exemptions are granted to generated items.
