//! generator_sdk.l — Lyric.GeneratorSdk
//!
//! The API package of the `SourceGenerator` plugin point (docs/40, D207):
//! the descriptor types the compiler sends, the response a generator
//! returns, the point itself and the `ProjectRead` capability.  A generator
//! is a `@plugin` record in a `kind = "source-generator"` package:
//!
//!   @plugin(id = "acme.describe", version = "0.1.0", publisher = "acme", implements(SourceGenerator))
//!   pub record DescribePlugin {}
//!
//!   impl SourceGenerator for DescribePlugin {
//!     func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError] { ... }
//!   }
//!
//! `Lyric.PluginExpand` generates the plugin's `main`, the codecs for every
//! type below and the `ProjectReadClient`; the compiler is the host.
package Lyric.GeneratorSdk

import Std.Core
import Std.Collections
import Std.String as Str

// ─────────────────────────────────────────────────────────────────────────────
// §1. Descriptor types (compiler → generator)
// ─────────────────────────────────────────────────────────────────────────────
// An annotation as it appears on the annotated item or one of its fields.
pub record AnnotationDescriptor {
  name: String
  args: slice[String]    // rendered args, e.g. ["since=\"1.0\"", "Json"]
}

// How a field's type is categorised.
pub enum FieldTypeKind {
  case Primitive    // Bool, Int, Long, UInt, ULong, Float, Double, Char, String
  case Slice        // slice[T]
  case OptionType   // Option[T]
  case ResultType   // Result[T, E]
  case Named        // any other single-segment name (record, union, alias, distinct)
  case Generic      // multi-argument or type-param reference
}

// A field's resolved type descriptor.
pub record FieldType {
  kind: FieldTypeKind
  name: String              // display form, e.g. "Int", "Option[String]", "MyRecord"
  typeArgs: slice[String]   // inner type names for Slice, Option, Result, Generic
}

// Describes one field of a record, or one member slot of an interface.
pub record FieldDescriptor {
  name: String
  fieldType: FieldType
  isPublic: Bool
  annotations: slice[AnnotationDescriptor]
  defaultSource: Option[String] = None  // the default value's source text, if any (schema 2)
}

// One case of an annotated union or enum (schema 2).  A positional union
// field has an empty name.
pub record CaseDescriptor {
  name: String
  annotations: slice[AnnotationDescriptor]
  fields: slice[FieldDescriptor]
}

// One `invariant:` of the annotated type, as source text (schema 2): the
// generator can copy it into code that binds each field to a local of the
// same name.  `message` is the invariant's `@message("...")`, if any.
pub record InvariantDescriptor {
  source: String
  message: Option[String]
  line: Int
  column: Int
}

// The kind of the annotated item.
pub enum ItemKind {
  case Record
  case ExposedRecord
  case Union
  case Interface
  case Opaque
  case Enum
}

// Full descriptor for the type that carries the @generate annotation.
pub record TypeDescriptor {
  kind: ItemKind
  name: String                    // unqualified name, e.g. "Order"
  packageName: String             // fully qualified package, e.g. "MyApp.Models"
  typeParams: slice[String]       // ["T", "E"] for generic types
  fields: slice[FieldDescriptor]  // empty for unions, enums and interfaces
  annotations: slice[AnnotationDescriptor]
  cases: slice[CaseDescriptor] = []          // a union's or enum's cases (schema 2)
  invariants: slice[InvariantDescriptor] = []  // the type's invariants (schema 2)
  invariant: name.length > 0
}

// What a same-file declaration named by the annotated type declares
// (schema 2).
pub enum DeclarationKind {
  case DeclaredEnum      // enum E { case A ... }
  case DeclaredDistinct  // type T = U, optionally with a range
  case DeclaredAlias     // alias T = U
}

// A distinct type's range: each bound as source text, `None` when the range
// is open on that side.  `maxInclusive` is false for `lo ..< hi`.
pub record RangeDescriptor {
  min: Option[String]
  max: Option[String]
  maxInclusive: Bool
}

// An enum, distinct type or alias declared in the same file as the
// annotated type and named in its source (schema 2), so a generator can
// see an enum field's cases or a range type's bounds.
pub record DeclarationDescriptor {
  name: String
  kind: DeclarationKind
  underlying: Option[String]      // a distinct type's or alias's right-hand side
  range: Option[RangeDescriptor]  // a range type's bounds
  cases: slice[CaseDescriptor]    // an enum's cases
}

// The full request handed to the generator entry point.
pub record GeneratorRequest {
  generatorArg: String          // the argument to @generate, e.g. "Proto.Derive"
  typeDescriptor: TypeDescriptor
  packageName: String           // package currently being compiled
  sourceFile: String            // source file path (for diagnostic spans)
  declarations: slice[DeclarationDescriptor] = []  // same-file declarations (schema 2)
}

/// The same-file declaration of `name` the request carries, if any.
pub func declarationNamed(req: in GeneratorRequest, name: in String): Option[DeclarationDescriptor] {
  var i = 0
  while i < req.declarations.length {
    if req.declarations[i].name == name {
      return Some(value = req.declarations[i])
    }
    i += 1
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Response types (generator → compiler)
// ─────────────────────────────────────────────────────────────────────────────
pub enum GeneratorDiagnosticSeverity {
  case Error
  case Warning
  case Info
}

pub record GeneratorDiagnostic {
  severity: GeneratorDiagnosticSeverity
  message: String
  code: Option[String]          // e.g. Some("PD001")
}

// What the generator returns.
pub record GeneratorResponse {
  lyricSource: String               // Lyric source fragment; complete items only
  additionalImports: slice[String]  // e.g. ["import Std.Json"]
  diagnostics: slice[GeneratorDiagnostic]
}

/// Why a generator refused a request outright.  A problem with the annotated
/// type is a diagnostic in a `GeneratorResponse`; `GeneratorError` is for a
/// request the generator cannot handle at all.
pub record GeneratorError {
  message: String
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. The plugin point and its capability
// ─────────────────────────────────────────────────────────────────────────────
/// The project-relative directories a generator may read.  `"."` is the
/// whole project.
pub exposed record ProjectReadGrant {
  roots: List[String]
}

/// Whether `path` is a project-relative path inside one of `roots`: no
/// empty, `.` or `..` segment, no backslash or colon, not absolute.  The
/// compiler applies the same rule (`Lyric.Generator.projectPathWithin`)
/// before it reads a file for a generator.
pub func projectPathWithin(path: in String, roots: in List[String]): Bool {
  val segs = projectSegments(path)
  if segs.count == 0 {
    return false
  }
  for rt in roots {
    if rt == "." {
      return true
    }
    val rootSegs = projectSegments(rt)
    if rootSegs.count > 0 and rootSegs.count <= segs.count {
      var same = true
      var i = 0
      while i < rootSegs.count {
        if rootSegs[i] != segs[i] {
          same = false
        }
        i += 1
      }
      if same {
        return true
      }
    }
  }
  false
}

// The `/`-separated segments of a relative path, or none when it is
// absolute, empty or holds a `.`, `..`, empty or backslashed segment.
func projectSegments(path: in String): List[String] {
  val segs: List[String] = newList()
  if path.length == 0 or Str.startsWith(path, "/") or Str.contains(path, "\\") or Str.contains(path, ":") {
    return segs
  }
  val parts = Str.split(path, "/")
  var i = 0
  while i < parts.length {
    val part = parts[i]
    if part == "" or part == "." or part == ".." {
      return newList()
    }
    segs.add(part)
    i += 1
  }
  segs
}

/// Reads a text file of the project being compiled.  The host grants a list
/// of roots; a path outside them is denied before the read.
@capability(grant = ProjectReadGrant)
pub interface ProjectRead {
  func readText(path: in String): Result[String, String]
    requires: projectPathWithin(path, grant.roots)
}

/// A source generator: called once per `@generate(<package>)` annotation.
@plugin_point(version = "3.0", allows(ProjectRead))
pub interface SourceGenerator {
  func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError]
}
