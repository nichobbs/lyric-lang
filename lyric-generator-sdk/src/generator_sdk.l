//! generator_sdk.l — Lyric.GeneratorSdk
//!
//! Contract types and stdin/stdout driver for custom source generators.
//! Generator packages import this and implement:
//!
//!   pub func generate(req: GeneratorRequest): GeneratorResponse { ... }
//!
//! The Lyric compiler discovers that entry point by name and invokes it
//! once per annotated type per generator.  See docs/40-source-generators.md.
@io
package Lyric.GeneratorSdk

import Std.Char as Ch
import Std.Core
import Std.Encoding
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.JsonValue as Jv

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

// ─────────────────────────────────────────────────────────────────────────────
// §3. Driver — stdin/stdout JSON I/O bridge
// ─────────────────────────────────────────────────────────────────────────────
// Parse a 4-character hexadecimal string into its integer value, or `None`
// if any character isn't a valid hex digit. Decodes a `\uXXXX` JSON escape's
// payload.
func parseHex4(hex: in String): Option[Int] {
  if hex.length != 4 {
    return None
  }
  var value = 0
  var i = 0
  while i < 4 {
    match Ch.hexDigitValue(Str.charAtOrReplacement(hex, i)) {
      case Some(d) -> {
        value = value * 16 + d
      }
      case None -> return None
    }
    i += 1
  }
  Some(value = value)
}

// The code unit of a `\uXXXX` low-surrogate escape (U+DC00..U+DFFF)
// starting at `at` (the backslash), or `None` if there is none there.
func lowSurrogateEscapeAt(src: in String, at: in Int): Option[Int] {
  if at + 5 >= src.length or Str.charAtOrReplacement(src, at) != '\\' or Str.charAtOrReplacement(src, at + 1) != 'u' {
    return None
  }
  match parseHex4(src.substring(at + 2, 4)) {
    case Some(low) -> if low >= 0xDC00 and low <= 0xDFFF { Some(value = low) } else { None }
    case None -> None
  }
}

// Parse a JSON string value from `src` starting at position `pos`.
// Advances `pos` past the closing quote and returns the unescaped content.
//
// Decodes every RFC 8259 §7 escape: the six named escapes plus `\/`
// (previously only `\n`/`\t`/`\r`/`\"`/`\\` were handled, and `\uXXXX` was
// left as a literal backslash-u sequence). A `\uXXXX` escape decodes to one
// Unicode scalar value via `Std.Encoding.codepointToString`; a high+low
// surrogate escape pair (`\ud83d\ude00`) combines into one supplementary-
// plane code point. A lone or reversed surrogate escape names no character
// and decodes to U+FFFD, keeping the reader total without producing an
// unpaired UTF-16 surrogate (#7252).
func parseJsonString(src: in String, pos: inout Int): String {
  pos += 1  // skip opening "
  var s = ""
  while pos < src.length and Str.charAtOrReplacement(src, pos) != '"' {
    if Str.charAtOrReplacement(src, pos) == '\\' and pos + 1 < src.length {
      pos += 1
      val esc = Str.charAtOrReplacement(src, pos)
      if esc == 'n' {
        s = s + "\n"
      } else if esc == 't' {
        s = s + "\t"
      } else if esc == 'r' {
        s = s + "\r"
      } else if esc == '"' {
        s = s + "\""
      } else if esc == '\\' {
        s = s + "\\"
      } else if esc == '/' {
        s = s + "/"
      } else if esc == 'b' {
        s = s + "\u{0008}"
      } else if esc == 'f' {
        s = s + "\u{000c}"
      } else if esc == 'u' and pos + 4 < src.length {
        match parseHex4(src.substring(pos + 1, 4)) {
          case Some(code) -> {
            if code >= 0xD800 and code <= 0xDBFF {
              match lowSurrogateEscapeAt(src, pos + 5) {
                case Some(low) -> {
                  s = s + codepointToString(0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00))
                  pos += 10
                }
                case None -> {
                  s = s + "�"
                  pos += 4
                }
              }
            } else if code >= 0xDC00 and code <= 0xDFFF {
              s = s + "�"
              pos += 4
            } else {
              s = s + codepointToString(code)
              pos += 4
            }
          }
          case None -> {
            s = s + "\\" + charToString(esc)
          }
        }
      } else {
        s = s + "\\" + Str.substring(src, pos, 1)
      }
    } else {
      s = s + Str.substring(src, pos, 1)
    }
    pos += 1
  }
  if pos < src.length {
    pos += 1
  }  // skip closing "
  s
}

func charToString(c: in Char): String {
  "" + c
}

func skipJsonWhitespace(src: in String, pos: inout Int): Unit {
  while pos < src.length and (Str.charAtOrReplacement(src, pos) == ' ' or Str.charAtOrReplacement(src, pos) == '\t' or Str.charAtOrReplacement(src, pos) == '\n' or Str.charAtOrReplacement(src, pos) == '\r') {
    pos += 1
  }
}

// Minimal JSON reader: find a top-level string field by key and return its value.
func jsonGetString(json: in String, key: in String): Option[String] {
  val needle = "\"" + key + "\""
  var i = 0
  while i < json.length {
    // Look for "key"
    if json.length - i >= needle.length {
      var ok = true
      var k = 0
      while k < needle.length {
        if Str.codeUnitAt(json, i + k) != Str.codeUnitAt(needle, k) {
          ok = false
        }
        k += 1
      }
      if ok {
        var pos = i + needle.length
        skipJsonWhitespace(json, pos)
        if pos < json.length and Str.charAtOrReplacement(json, pos) == ':' {
          pos += 1
          skipJsonWhitespace(json, pos)
          if pos < json.length and Str.charAtOrReplacement(json, pos) == '"' {
            val s = parseJsonString(json, pos)
            return Some(value = s)
          }
        }
      }
    }
    i += 1
  }
  None
}

// Collect a JSON array of strings starting at `pos` (positioned at `[`).
func parseJsonStringArray(src: in String, pos: inout Int): List[String] {
  val items: List[String] = newList()
  pos += 1  // skip [
  skipJsonWhitespace(src, pos)
  while pos < src.length and Str.charAtOrReplacement(src, pos) != ']' {
    if Str.charAtOrReplacement(src, pos) == '"' {
      items.add(parseJsonString(src, pos))
    } else {
      pos += 1
    }
    skipJsonWhitespace(src, pos)
    if pos < src.length and Str.charAtOrReplacement(src, pos) == ',' {
      pos += 1
    }
    skipJsonWhitespace(src, pos)
  }
  if pos < src.length {
    pos += 1
  }  // skip ]
  items
}

// Escape a string for embedding in a JSON value (RFC 8259 §7).
func jsonEscape(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    if c == '"' {
      acc = acc + "\\\""
    } else if c == '\\' {
      acc = acc + "\\\\"
    } else if c == '\n' {
      acc = acc + "\\n"
    } else if c == '\r' {
      acc = acc + "\\r"
    } else if c == '\t' {
      acc = acc + "\\t"
    } else {
      acc = acc + Str.substring(s, i, 1)
    }
    i += 1
  }
  acc
}

func serializeAnnotations(anns: in slice[AnnotationDescriptor]): String {
  var acc = "["
  val arr = anns.toArray()
  var i = 0
  while i < arr.count {
    val a = arr[i]
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + "{\"name\":\"" + jsonEscape(a.name) + "\",\"args\":["
    val argArr = a.args.toArray()
    var j = 0
    while j < argArr.count {
      if j > 0 {
        acc = acc + ","
      }
      acc = acc + "\"" + jsonEscape(argArr[j]) + "\""
      j += 1
    }
    acc = acc + "]}"
    i += 1
  }
  acc + "]"
}

// A JSON string literal for `s`.
func jsonStr(s: in String): String {
  "\"" + jsonEscape(s) + "\""
}

func jsonStrs(xs: in slice[String]): String {
  var acc = "["
  var i = 0
  while i < xs.length {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + jsonStr(xs[i])
    i += 1
  }
  acc + "]"
}

func serializeFields(fields: in slice[FieldDescriptor]): String {
  var acc = "["
  var fi = 0
  while fi < fields.length {
    val fd = fields[fi]
    if fi > 0 {
      acc = acc + ","
    }
    val ftKind = match fd.fieldType.kind {
      case Primitive -> "Primitive"
      case Slice -> "Slice"
      case OptionType -> "OptionType"
      case ResultType -> "ResultType"
      case Named -> "Named"
      case Generic -> "Generic"
    }
    val dflt = match fd.defaultSource { case Some(d) -> ",\"default\":" + jsonStr(d); case None -> "" }
    acc = acc + "{\"name\":" + jsonStr(fd.name) + ",\"fieldType\":{\"kind\":\"" + ftKind + "\",\"name\":" +
      jsonStr(fd.fieldType.name) +
      ",\"typeArgs\":" +
      jsonStrs(fd.fieldType.typeArgs) +
      "},\"isPublic\":" +
      (if fd.isPublic { "true" } else { "false" }) +
      ",\"annotations\":" +
      serializeAnnotations(fd.annotations) +
      dflt +
      "}"
    fi += 1
  }
  acc + "]"
}

func serializeCases(cases: in slice[CaseDescriptor]): String {
  var acc = "["
  var i = 0
  while i < cases.length {
    val c = cases[i]
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + "{\"name\":" + jsonStr(c.name) + ",\"annotations\":" + serializeAnnotations(c.annotations) +
      ",\"fields\":" +
      serializeFields(c.fields) +
      "}"
    i += 1
  }
  acc + "]"
}

func serializeInvariants(invs: in slice[InvariantDescriptor]): String {
  var acc = "["
  var i = 0
  while i < invs.length {
    val inv = invs[i]
    if i > 0 {
      acc = acc + ","
    }
    val msg = match inv.message { case Some(m) -> jsonStr(m); case None -> "null" }
    acc = acc + "{\"source\":" + jsonStr(inv.source) + ",\"message\":" + msg + ",\"line\":" + Str.fromInt(inv.line) +
      ",\"column\":" +
      Str.fromInt(inv.column) +
      "}"
    i += 1
  }
  acc + "]"
}

/// Encode a request as the compiler sends it (schema 2).  The inverse of
/// `parseRequest`; generator tests use it to build a request by hand.
pub func serializeRequest(req: in GeneratorRequest): String {
  val td = req.typeDescriptor
  val itemKindStr = match td.kind {
    case Record -> "Record"
    case ExposedRecord -> "ExposedRecord"
    case Union -> "Union"
    case Interface -> "Interface"
    case Opaque -> "Opaque"
    case Enum -> "Enum"
  }
  "{\"schemaVersion\":\"2\",\"generatorArg\":" + jsonStr(req.generatorArg) + ",\"packageName\":" +
    jsonStr(req.packageName) +
    ",\"sourceFile\":" +
    jsonStr(req.sourceFile) +
    ",\"typeDescriptor\":{\"kind\":\"" +
    itemKindStr +
    "\",\"name\":" +
    jsonStr(td.name) +
    ",\"packageName\":" +
    jsonStr(td.packageName) +
    ",\"typeParams\":" +
    jsonStrs(td.typeParams) +
    ",\"fields\":" +
    serializeFields(td.fields) +
    ",\"annotations\":" +
    serializeAnnotations(td.annotations) +
    ",\"cases\":" +
    serializeCases(td.cases) +
    ",\"invariants\":" +
    serializeInvariants(td.invariants) +
    "},\"declarations\":" +
    serializeDeclarations(req.declarations) +
    "}"
}

func optJsonStr(o: in Option[String]): String {
  match o {
    case Some(v) -> jsonStr(v)
    case None -> "null"
  }
}

func serializeDeclarations(decls: in slice[DeclarationDescriptor]): String {
  var acc = "["
  var i = 0
  while i < decls.length {
    val d = decls[i]
    if i > 0 {
      acc = acc + ","
    }
    val kind = match d.kind {
      case DeclaredEnum -> "Enum"
      case DeclaredDistinct -> "Distinct"
      case DeclaredAlias -> "Alias"
    }
    val range = match d.range {
      case Some(r) -> "{\"min\":" + optJsonStr(r.min) + ",\"max\":" + optJsonStr(r.max) + ",\"maxInclusive\":" +
        (if r.maxInclusive { "true" } else { "false" }) +
        "}"
      case None -> "null"
    }
    acc = acc + "{\"name\":" + jsonStr(d.name) + ",\"kind\":\"" + kind + "\",\"underlying\":" + optJsonStr(d.underlying) +
      ",\"range\":" +
      range +
      ",\"cases\":" +
      serializeCases(d.cases) +
      "}"
    i += 1
  }
  acc + "]"
}

// True when every character of `s` is valid in a Lyric identifier at
// position `isFirst` (letters/underscore first, plus digits thereafter).
func isValidIdentifierChar(c: in Char, isFirst: in Bool): Bool {
  if isFirst {
    Ch.isAsciiLetter(c) or c == '_'
  } else {
    Ch.isAsciiLetterOrDigit(c) or c == '_'
  }
}

// True when `s` is a single valid Lyric identifier (non-empty, starts with
// a letter or underscore, continues with letters/digits/underscores).
func isValidIdentifier(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  var ok = true
  while i < s.length and ok {
    if not isValidIdentifierChar(Str.charAtOrReplacement(s, i), i == 0) {
      ok = false
    }
    i += 1
  }
  ok
}

// True when `s` is a dotted chain of valid identifiers (e.g. "Std.Json",
// "MyApp.Models.Order"), and non-empty.
func isValidQualifiedName(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  val segments = s.split(".")
  if segments.length == 0 {
    return false
  }
  var i = 0
  var ok = true
  while i < segments.length and ok {
    if not isValidIdentifier(segments[i]) {
      ok = false
    }
    i += 1
  }
  ok
}

// True when `stmt` is exactly a single `import <QualifiedName>` or
// `import extern <QualifiedName>` statement, optionally followed by
// `as <Identifier>` — the only shapes an `additionalImports` entry is
// allowed to take.
//
// A generator is an untrusted subprocess (docs/40-source-generators.md
// §"Security and trust"): its `additionalImports` entries are spliced
// verbatim into the compiled program's source. Without this check, any
// string at all — including multiple statements, or non-import source —
// was accepted, letting a malicious or buggy generator inject arbitrary
// source rather than just the header line it claims to be.
func isValidImportStatement(stmt: in String): Bool {
  var rest = stmt
  var matchedPrefix = false
  if Str.startsWith(rest, "import extern ") {
    rest = rest.substring(14)
    matchedPrefix = true
  } else if Str.startsWith(rest, "import ") {
    rest = rest.substring(7)
    matchedPrefix = true
  }
  if not matchedPrefix or rest.length == 0 {
    return false
  }
  match Str.indexOf(rest, " as ") {
    case None -> isValidQualifiedName(rest)
    case Some(idx) -> {
      val namePart = rest.substring(0, idx)
      val aliasPart = rest.substring(idx + 4)
      isValidQualifiedName(namePart) and isValidIdentifier(aliasPart)
    }
  }
}

// Parse a slice of GeneratorDiagnostic from the inner content of the
// diagnostics JSON array (the text between `[` and `]`). An entry whose
// "severity" is missing or unrecognized defaults to Error (fail safe: an
// unparseable diagnostic should not be silently downgraded to Info).
func parseGeneratorDiagnostics(diagContent: in String): slice[GeneratorDiagnostic] {
  val result: List[GeneratorDiagnostic] = newList()
  var pos = 0
  skipJsonWhitespace(diagContent, pos)
  while pos < diagContent.length {
    if Str.charAtOrReplacement(diagContent, pos) == '{' {
      val objContent = extractJsonBlock(diagContent, pos)
      val sevStr = unwrapOr(jsonGetString(objContent, "severity"), "Error")
      val message = unwrapOr(jsonGetString(objContent, "message"), "")
      val code = jsonGetString(objContent, "code")
      val severity = if sevStr == "Warning" { Warning } else if sevStr == "Info" { Info } else { Error }
      result.add(GeneratorDiagnostic(severity = severity, message = message, code = code))
    } else {
      pos += 1
    }
    skipJsonWhitespace(diagContent, pos)
    if pos < diagContent.length and Str.charAtOrReplacement(diagContent, pos) == ',' {
      pos += 1
    }
    skipJsonWhitespace(diagContent, pos)
  }
  result.toArray()
}

// Parse a GeneratorResponse from JSON returned by the subprocess.
//
// Returns `Err` for a malformed `additionalImports` entry (anything other
// than a single clean `import <QualifiedName>` statement, per
// `isValidImportStatement`) rather than accepting it — see that function's
// doc comment. Otherwise lenient: a missing or malformed top-level field
// (including a missing `additionalImports`/`diagnostics` key entirely, or
// unparseable overall JSON) degrades to an empty/default value rather than
// failing the whole response.
pub func parseResponse(json: in String): Result[GeneratorResponse, String] {
  val lyricSource = unwrapOr(jsonGetString(json, "lyricSource"), "")

  // Parse and validate additionalImports.
  val additionalImports: List[String] = newList()
  val importsBlockPos = jsonFindBlock(json, "additionalImports")
  if importsBlockPos >= 0 {
    var importsPos = importsBlockPos
    val items = parseJsonStringArray(json, importsPos)
    var ii = 0
    while ii < items.count {
      val entry = items[ii]
      if not isValidImportStatement(entry) {
        return Err(
          error = "GeneratorSdk: malformed additionalImports entry (expected a single " +
            "'import <QualifiedName>' statement): " +
            entry
        )
      }
      additionalImports.add(entry)
      ii += 1
    }
  }

  // Parse diagnostics.
  var diagnostics: slice[GeneratorDiagnostic] = []
  val diagBlockPos = jsonFindBlock(json, "diagnostics")
  if diagBlockPos >= 0 {
    var diagPos = diagBlockPos
    val diagContent = extractJsonBlock(json, diagPos)
    diagnostics = parseGeneratorDiagnostics(diagContent)
  }

  Ok(
    value = GeneratorResponse(
      lyricSource = lyricSource,
      additionalImports = additionalImports.toArray(),
      diagnostics = diagnostics
    )
  )
}

// Extract the content of a balanced JSON block ({...} or [...]) starting at
// `pos` (positioned at the opening delimiter).  Advances `pos` to after the
// closing delimiter and returns the inner text (without the outer delimiters).
func extractJsonBlock(src: in String, pos: inout Int): String {
  pos += 1  // skip opener
  var depth = 1
  var content = ""
  while pos < src.length and depth > 0 {
    val c = Str.charAtOrReplacement(src, pos)
    if (c == '{') or (c == '[') {
      depth += 1
      content = content + charToString(c)
      pos += 1
    } else if (c == '}') or (c == ']') {
      depth -= 1
      if depth > 0 {
        content = content + charToString(c)
      }
      pos += 1
    } else if c == '"' {
      content = content + "\""
      pos += 1
      while pos < src.length and Str.charAtOrReplacement(src, pos) != '"' {
        if Str.charAtOrReplacement(src, pos) == '\\' and pos + 1 < src.length {
          content = content + Str.substring(src, pos, 1) + Str.substring(src, pos + 1, 1)
          pos += 2
        } else {
          content = content + Str.substring(src, pos, 1)
          pos += 1
        }
      }
      if pos < src.length {
        content = content + "\""
        pos += 1
      }
    } else {
      content = content + Str.substring(src, pos, 1)
      pos += 1
    }
  }
  content
}

// Find the position of a JSON array or object value for `key` in `json`.
// Returns the index of the opening `{` or `[`, or -1 if not found.
func jsonFindBlock(json: in String, key: in String): Int {
  val needle = "\"" + key + "\""
  var i = 0
  while i < json.length {
    if json.length - i >= needle.length {
      var ok = true
      var k = 0
      while k < needle.length {
        if Str.codeUnitAt(json, i + k) != Str.codeUnitAt(needle, k) {
          ok = false
        }
        k += 1
      }
      if ok {
        var pos = i + needle.length
        skipJsonWhitespace(json, pos)
        if pos < json.length and Str.charAtOrReplacement(json, pos) == ':' {
          pos += 1
          skipJsonWhitespace(json, pos)
          if pos < json.length and ((Str.charAtOrReplacement(json, pos) == '{') or (Str.charAtOrReplacement(json, pos) == '[')) {
            return pos
          }
        }
      }
    }
    i += 1
  }
  -1
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Entry-point wiring — reads stdin, calls `generate`, writes stdout
// ─────────────────────────────────────────────────────────────────────────────
// Generator packages call `runGenerator(generate)` from their `main`:
//
//   pub func main(): Int {
//     runGenerator(generate)
//   }
//
// `runGenerator` reads the JSON request from stdin, deserialises it into a
// GeneratorRequest, calls `generate`, and writes the GeneratorResponse JSON
// to stdout.  Exit code 0 = success; 1 = parse failure (message on stderr).
/// Decode the compiler's request JSON (the inverse of `serializeRequest`).
/// `runGenerator` reads it from stdin; exposed so generators and tests can
/// decode a request without a subprocess round trip.  Schema 1 and schema 2
/// requests are accepted: 2 adds cases, invariants, annotations, type
/// parameters and field defaults, which are empty in a schema 1 request.
pub func parseRequest(json: in String): Result[GeneratorRequest, String] {
  val root = match Jv.parseValue(json) {
    case Ok(v) -> v
    case Err(e) -> return Err(error = "malformed request: " + e.message())
  }
  val version = match Jv.getString(root, "schemaVersion") {
    case None -> return Err(error = "missing schemaVersion in request")
    case Some(v) -> v
  }
  if version != "1" and version != "2" {
    return Err(error = "unsupported schemaVersion " + version)
  }
  val td = match Jv.getField(root, "typeDescriptor") {
    case Some(v) -> v
    case None -> return Err(error = "malformed request: missing typeDescriptor")
  }
  val tdName = textOf(td, "name")
  if tdName.length == 0 {
    return Err(error = "malformed request: missing or empty typeDescriptor.name")
  }
  val kind = match itemKindOf(textOf(td, "kind")) {
    case Some(k) -> k
    case None -> return Err(error = "malformed request: unknown typeDescriptor.kind " + textOf(td, "kind"))
  }
  Ok(
    value = GeneratorRequest(
      generatorArg = textOf(root, "generatorArg"),
      typeDescriptor = TypeDescriptor(
        kind = kind,
        name = tdName,
        packageName = textOf(td, "packageName"),
        typeParams = stringsOf(td, "typeParams"),
        fields = fieldsOf(td, "fields"),
        annotations = annotationsOf(td),
        cases = casesOf(td),
        invariants = invariantsOf(td)
      ),
      packageName = textOf(root, "packageName"),
      sourceFile = textOf(root, "sourceFile"),
      declarations = declarationsOf(root)
    )
  )
}

func declarationKindOf(s: in String): Option[DeclarationKind] {
  if s == "Enum" {
    Some(value = DeclaredEnum)
  } else if s == "Distinct" {
    Some(value = DeclaredDistinct)
  } else if s == "Alias" {
    Some(value = DeclaredAlias)
  } else {
    None
  }
}

// A declaration of a kind this SDK does not know is skipped rather than
// failing the request, so a newer compiler can describe more kinds.
func declarationsOf(root: in Jv.JsonValue): slice[DeclarationDescriptor] {
  val acc: List[DeclarationDescriptor] = newList()
  for d in itemsOf(root, "declarations") {
    match declarationKindOf(textOf(d, "kind")) {
      case None -> ()
      case Some(k) -> {
        val range = match Jv.getField(d, "range") {
          case Some(r) -> match Jv.getBool(r, "maxInclusive") {
            case Some(incl) -> Some(
              value = RangeDescriptor(
                min = Jv.getString(r, "min"),
                max = Jv.getString(r, "max"),
                maxInclusive = incl
              )
            )
            case None -> None
          }
          case None -> None
        }
        acc.add(
          DeclarationDescriptor(
            name = textOf(d, "name"),
            kind = k,
            underlying = Jv.getString(d, "underlying"),
            range = range,
            cases = casesOf(d)
          )
        )
      }
    }
  }
  acc.toArray()
}

func textOf(v: in Jv.JsonValue, key: in String): String {
  unwrapOr(Jv.getString(v, key), "")
}

func itemsOf(v: in Jv.JsonValue, key: in String): List[Jv.JsonValue] {
  match Jv.getArray(v, key) {
    case Some(items) -> items
    case None -> newList()
  }
}

func stringsOf(v: in Jv.JsonValue, key: in String): slice[String] {
  val acc: List[String] = newList()
  for item in itemsOf(v, key) {
    match Jv.asString(item) {
      case Some(s) -> acc.add(s)
      case None -> ()
    }
  }
  acc.toArray()
}

func itemKindOf(s: in String): Option[ItemKind] {
  if s == "Record" {
    Some(value = Record)
  } else if s == "ExposedRecord" {
    Some(value = ExposedRecord)
  } else if s == "Union" {
    Some(value = Union)
  } else if s == "Interface" {
    Some(value = Interface)
  } else if s == "Opaque" {
    Some(value = Opaque)
  } else if s == "Enum" {
    Some(value = Enum)
  } else {
    None
  }
}

func fieldTypeKindOf(s: in String): FieldTypeKind {
  if s == "Primitive" {
    Primitive
  } else if s == "Slice" {
    Slice
  } else if s == "OptionType" {
    OptionType
  } else if s == "ResultType" {
    ResultType
  } else if s == "Generic" {
    Generic
  } else {
    Named
  }
}

func annotationsOf(v: in Jv.JsonValue): slice[AnnotationDescriptor] {
  val acc: List[AnnotationDescriptor] = newList()
  for a in itemsOf(v, "annotations") {
    acc.add(AnnotationDescriptor(name = textOf(a, "name"), args = stringsOf(a, "args")))
  }
  acc.toArray()
}

func fieldsOf(v: in Jv.JsonValue, key: in String): slice[FieldDescriptor] {
  val acc: List[FieldDescriptor] = newList()
  for f in itemsOf(v, key) {
    val ft = match Jv.getField(f, "fieldType") {
      case Some(t) -> FieldType(
        kind = fieldTypeKindOf(textOf(t, "kind")),
        name = textOf(t, "name"),
        typeArgs = stringsOf(t, "typeArgs")
      )
      case None -> FieldType(kind = Named, name = "", typeArgs = [])
    }
    acc.add(
      FieldDescriptor(
        name = textOf(f, "name"),
        fieldType = ft,
        isPublic = unwrapOr(Jv.getBool(f, "isPublic"), true),
        annotations = annotationsOf(f),
        defaultSource = Jv.getString(f, "default")
      )
    )
  }
  acc.toArray()
}

func casesOf(v: in Jv.JsonValue): slice[CaseDescriptor] {
  val acc: List[CaseDescriptor] = newList()
  for c in itemsOf(v, "cases") {
    acc.add(CaseDescriptor(name = textOf(c, "name"), annotations = annotationsOf(c), fields = fieldsOf(c, "fields")))
  }
  acc.toArray()
}

func invariantsOf(v: in Jv.JsonValue): slice[InvariantDescriptor] {
  val acc: List[InvariantDescriptor] = newList()
  for i in itemsOf(v, "invariants") {
    acc.add(
      InvariantDescriptor(
        source = textOf(i, "source"),
        message = Jv.getString(i, "message"),
        line = unwrapOr(Jv.getInt(i, "line"), 0).toInt(),
        column = unwrapOr(Jv.getInt(i, "column"), 0).toInt()
      )
    )
  }
  acc.toArray()
}

pub func runGenerator(generate: (GeneratorRequest) -> GeneratorResponse): Int {
  val json = match Console.readAll() {
    case Ok(s) -> s
    case Err(e) -> {
      Console.error("GeneratorSdk: failed to read request from stdin: " + e.message())
      return 1
    }
  }
  val req = match parseRequest(json) {
    case Ok(r) -> r
    case Err(msg) -> {
      Console.error("GeneratorSdk: " + msg)
      return 1
    }
  }

  val resp = generate(req)

  val jsonOut = serializeResponseForOutput(resp)
  Console.print(jsonOut)
  0
}

// Serialize a GeneratorResponse for stdout output.
func serializeResponseForOutput(resp: in GeneratorResponse): String {
  var acc = "{\"lyricSource\":\"" + jsonEscape(resp.lyricSource) + "\""
  acc = acc + ",\"additionalImports\":["
  val impArr = resp.additionalImports.toArray()
  var i = 0
  while i < impArr.count {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + "\"" + jsonEscape(impArr[i]) + "\""
    i += 1
  }
  acc = acc + "],\"diagnostics\":["
  val diagArr = resp.diagnostics.toArray()
  var di = 0
  while di < diagArr.count {
    val d = diagArr[di]
    if di > 0 {
      acc = acc + ","
    }
    val sevStr = match d.severity { case Error -> "Error"; case Warning -> "Warning"; case Info -> "Info" }
    acc = acc + "{\"severity\":\"" + sevStr + "\""
    acc = acc + ",\"message\":\"" + jsonEscape(d.message) + "\""
    val codeStr = match d.code { case None -> "null"; case Some(c) -> "\"" + jsonEscape(c) + "\"" }
    acc = acc + ",\"code\":" + codeStr + "}"
    di += 1
  }
  acc + "]}"
}
