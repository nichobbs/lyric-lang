# Lyric Generator Protocol

Complete specification for the Lyric code generator interface, including the JSON contract between the compiler and generator implementations.

## Overview

Lyric's `@generate` annotation enables compile-time code generation. When the compiler encounters a `@generate` annotation on a type, it:

1. **Discovers** the generator binary (named in the annotation argument)
2. **Spawns** the generator as a subprocess
3. **Sends** a JSON-serialized `GeneratorRequest` on stdin
4. **Receives** a JSON-serialized `GeneratorResponse` on stdout
5. **Incorporates** the generated code into the compilation unit

This protocol defines the JSON contract and the Lyric types used in that contract.

## Generator Implementation

A generator is a Lyric program that exports a `generate` function and a `main` entry point:

```lyric
import Lyric.GeneratorSdk

pub func generate(req: GeneratorRequest): GeneratorResponse {
  // Inspect req.typeDescriptor, req.generatorArg, etc.
  // Generate Lyric source code
  GeneratorResponse(
    lyricSource = "pub func generated(): Unit {}",
    additionalImports = ["import Std.Json"],
    diagnostics = []
  )
}

pub func main(): Int {
  runGenerator(generate)
}
```

Build with `lyric build` to produce a binary, e.g., `my-generator.exe`.

### Usage in Lyric Code

```lyric
@generate("my-generator")
pub record Order {
  id: Int
  items: slice[String]
}
```

The compiler:
1. Serializes a `GeneratorRequest` with type=`Order`, packageName=`MyApp`, etc.
2. Spawns `my-generator.exe` with stdin/stdout
3. Writes the JSON request to stdin
4. Reads the JSON response from stdout
5. Parses `lyricSource` and inserts it into the compilation unit
6. Imports any modules from `additionalImports`
7. Reports any `diagnostics`

## Request Protocol

### GeneratorRequest (sent by compiler → received by generator)

```json
{
  "schemaVersion": "1",
  "generatorArg": "Proto.Derive",
  "packageName": "MyApp",
  "sourceFile": "order.l",
  "typeDescriptor": {
    "kind": "Record",
    "name": "Order",
    "packageName": "MyApp.Models",
    "typeParams": [],
    "fields": [
      {
        "name": "id",
        "fieldType": {
          "kind": "Primitive",
          "name": "Int",
          "typeArgs": []
        },
        "isPublic": true,
        "annotations": [
          {
            "name": "required",
            "args": []
          }
        ]
      },
      {
        "name": "items",
        "fieldType": {
          "kind": "Slice",
          "name": "slice[String]",
          "typeArgs": ["String"]
        },
        "isPublic": true,
        "annotations": []
      }
    ],
    "annotations": [
      {
        "name": "derive",
        "args": ["Eq", "Show"]
      }
    ]
  }
}
```

### Request Fields

- **schemaVersion** (`"1"`): Protocol version for forward compatibility
- **generatorArg** (string): The argument to `@generate`, e.g., `"Proto.Derive"`
- **packageName** (string): Package currently being compiled, e.g., `"MyApp"`
- **sourceFile** (string): Source file path for diagnostics, e.g., `"order.l"`
- **typeDescriptor** (TypeDescriptor): Full type information (see below)

### TypeDescriptor Structure

- **kind** (ItemKind): One of `"Record"`, `"ExposedRecord"`, `"Union"`, `"Interface"`
- **name** (string): Unqualified type name, e.g., `"Order"`
- **packageName** (string): Fully qualified package, e.g., `"MyApp.Models"`
- **typeParams** (string[]): Generic type parameters, e.g., `["T", "E"]`
- **fields** (FieldDescriptor[]): Field list (empty for unions/interfaces)
- **annotations** (AnnotationDescriptor[]): Annotations on the type

### FieldDescriptor Structure

- **name** (string): Field name
- **fieldType** (FieldType): Resolved type information
- **isPublic** (boolean): Public vs. private visibility
- **annotations** (AnnotationDescriptor[]): Per-field annotations

### FieldType Structure

- **kind** (FieldTypeKind): One of:
  - `"Primitive"` — Bool, Int, Long, UInt, ULong, Float, Double, Char, String
  - `"Slice"` — slice[T]
  - `"OptionType"` — Option[T]
  - `"ResultType"` — Result[T, E]
  - `"Named"` — Single-segment name (record, union, alias, distinct)
  - `"Generic"` — Multi-argument or type-param reference
- **name** (string): Display form, e.g., `"Int"`, `"Option[String]"`, `"MyRecord"`
- **typeArgs** (string[]): Inner type names, e.g., `["String"]` for `slice[String]`

### AnnotationDescriptor Structure

- **name** (string): Annotation name, e.g., `"required"`, `"since"`
- **args** (string[]): Rendered argument expressions, e.g., `["\"1.0\"", "Json"]`

## Response Protocol

### GeneratorResponse (sent by generator → received by compiler)

```json
{
  "lyricSource": "pub func protoSerialize(o: Order): slice[Byte] { ... }",
  "additionalImports": [
    "import Std.Json",
    "import Std.Collections"
  ],
  "diagnostics": [
    {
      "severity": "Warning",
      "message": "Generic constructor not derived",
      "code": "PD042"
    }
  ]
}
```

### Response Fields

- **lyricSource** (string): Generated Lyric source code fragment. Must be complete items only (types, functions, etc.). Will be inserted into the current compilation unit.
- **additionalImports** (string[]): Import statements to inject into the file if not already present, e.g., `["import Std.Json"]`
- **diagnostics** (GeneratorDiagnostic[]): Warnings, errors, or informational messages

### GeneratorDiagnostic Structure

- **severity** (string): One of `"Error"`, `"Warning"`, `"Info"`
- **message** (string): Human-readable diagnostic message
- **code** (string | null): Machine-readable diagnostic code, e.g., `"PD001"` (optional)

### JSON Escaping

Generator implementations must properly escape strings in the response:

- `"` → `\"`
- `\` → `\\`
- `\n` → `\\n` (literal newline)
- `\r` → `\\r` (carriage return)
- `\t` → `\\t` (tab)

The SDK's `jsonEscape()` function handles this automatically.

## Error Handling

### Generator Process Errors

If the generator process:
- **Exits with non-zero code**: Compilation fails with an error mentioning the exit code
- **Produces invalid JSON**: Compiler attempts lenient parsing (parseResponse is lenient)
- **Writes to stderr**: Output is captured and logged at compile time
- **Times out**: Compilation fails with a timeout error (subject to configuration)

### Diagnostic Reporting

Generators should emit diagnostics for:
- **Unsupported type combinations** — e.g., "cannot derive Eq for generics"
- **Configuration issues** — e.g., missing required annotations
- **Warnings** — e.g., "field X lacks documentation"

## Lyric SDK API

The `Lyric.GeneratorSdk` package provides all types needed:

### Public Types

```lyric
pub record GeneratorRequest {
  generatorArg: String
  typeDescriptor: TypeDescriptor
  packageName: String
  sourceFile: String
}

pub record TypeDescriptor {
  kind: ItemKind
  name: String
  packageName: String
  typeParams: slice[String]
  fields: slice[FieldDescriptor]
  annotations: slice[AnnotationDescriptor]
}

pub record FieldDescriptor {
  name: String
  fieldType: FieldType
  isPublic: Bool
  annotations: slice[AnnotationDescriptor]
}

pub record FieldType {
  kind: FieldTypeKind
  name: String
  typeArgs: slice[String]
}

pub record AnnotationDescriptor {
  name: String
  args: slice[String]
}

pub record GeneratorResponse {
  lyricSource: String
  additionalImports: slice[String]
  diagnostics: slice[GeneratorDiagnostic]
}

pub record GeneratorDiagnostic {
  severity: GeneratorDiagnosticSeverity
  message: String
  code: Option[String]
}

pub enum ItemKind { Record | ExposedRecord | Union | Interface }
pub enum FieldTypeKind { Primitive | Slice | OptionType | ResultType | Named | Generic }
pub enum GeneratorDiagnosticSeverity { Error | Warning | Info }
```

### Public Functions

```lyric
// Serialize a request to JSON for subprocess communication
pub func serializeRequest(req: in GeneratorRequest): String

// Parse a response from JSON (lenient parsing)
pub func parseResponse(json: in String): Result[GeneratorResponse, String]

// Entry point: reads stdin, calls generate, writes stdout
pub func runGenerator(generate: (GeneratorRequest) -> GeneratorResponse): Int
```

### Helper Functions (private)

- `parseJsonString`, `jsonEscape`, `skipJsonWhitespace`
- `jsonGetString`, `parseJsonStringArray`, `extractJsonBlock`, `jsonFindBlock`
- `serializeResponseForOutput` (used by `runGenerator`)

## Full Round-Trip Example

### Compiler Side

```lyric
@generate("proto-generator")
pub record Message {
  id: Int
  text: String
}
```

### Protocol Handshake

**Compiler sends:**
```json
{
  "schemaVersion": "1",
  "generatorArg": "proto-generator",
  "packageName": "myapp",
  "sourceFile": "message.l",
  "typeDescriptor": {
    "kind": "Record",
    "name": "Message",
    "packageName": "myapp",
    "typeParams": [],
    "fields": [
      {"name": "id", "fieldType": {"kind": "Primitive", "name": "Int", "typeArgs": []}, "isPublic": true, "annotations": []},
      {"name": "text", "fieldType": {"kind": "Primitive", "name": "String", "typeArgs": []}, "isPublic": true, "annotations": []}
    ],
    "annotations": []
  }
}
```

**Generator processes request:**
```lyric
val resp = generate(req)
// → TypeDescriptor has kind=Record, name="Message", with 2 fields
```

**Generator sends:**
```json
{
  "lyricSource": "pub func protoSerialize(m: Message): slice[Byte] { ... }\npub func protoDeserialize(bytes: slice[Byte]): Result[Message, String] { ... }",
  "additionalImports": ["import Std.Json"],
  "diagnostics": []
}
```

**Compiler incorporates:**
- Inserts generated functions into compilation unit
- Adds `import Std.Json` if not present
- Reports zero diagnostics
- Compilation proceeds with both `protoSerialize` and `protoDeserialize` available

## Testing

See `lyric-generator-sdk/tests/generator_sdk_tests.l` for comprehensive test coverage:

- **Request serialization**: All type kinds, field types, annotations
- **Response deserialization**: Parsing imports, source code, diagnostics
- **Round-trip consistency**: Full request/response cycle with realistic payloads
- **Edge cases**: Escaped strings, multiple imports, empty arrays

Run tests with: `lyric test --manifest lyric-generator-sdk/lyric.toml`

## Stability and Versioning

- **Schema version 1** is the current protocol
- Backward compatibility is NOT guaranteed across major versions
- Generators should validate `schemaVersion` before processing
- Compiler version mismatch with generator may cause errors

## Performance Considerations

- Generators are spawned **once per annotated type**
- Request/response JSON is human-readable but not optimized for size
- Large types (100+ fields) produce multi-KB JSON payloads
- No streaming; entire request/response fits in memory

For high-volume generation, consider batching logic into the generator's `generate` function rather than requesting multiple types separately.
