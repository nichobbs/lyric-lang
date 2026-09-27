//! generator_sdk.l — Lyric.GeneratorSdk
//!
//! Contract types and stdin/stdout driver for custom source generators.
//! Generator packages import this and implement:
//!
//!   pub func generate(req: GeneratorRequest): GeneratorResponse { ... }
//!
//! The Lyric compiler discovers that entry point by name and invokes it
//! once per annotated type per generator.  See docs/40-source-generators.md.
package Lyric.GeneratorSdk

import Std.Char as Ch
import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
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
}

// The kind of the annotated item.
pub enum ItemKind {
  case Record
  case ExposedRecord
  case Union
  case Interface
}

// Full descriptor for the type that carries the @generate annotation.
pub record TypeDescriptor {
  kind: ItemKind
  name: String                    // unqualified name, e.g. "Order"
  packageName: String             // fully qualified package, e.g. "MyApp.Models"
  typeParams: slice[String]       // ["T", "E"] for generic types
  fields: slice[FieldDescriptor]  // empty for unions and interfaces
  annotations: slice[AnnotationDescriptor]
  invariant: name.length > 0
}

// The full request handed to the generator entry point.
pub record GeneratorRequest {
  generatorArg: String          // the argument to @generate, e.g. "Proto.Derive"
  typeDescriptor: TypeDescriptor
  packageName: String           // package currently being compiled
  sourceFile: String            // source file path (for diagnostic spans)
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
    match Ch.hexDigitValue(hex[i]) {
      case Some(d) -> {
        value = value * 16 + d
      }
      case None -> return None
    }
    i += 1
  }
  Some(value = value)
}

// Parse a JSON string value from `src` starting at position `pos`.
// Advances `pos` past the closing quote and returns the unescaped content.
//
// Decodes every RFC 8259 §7 escape: the six named escapes plus `\/`
// (previously only `\n`/`\t`/`\r`/`\"`/`\\` were handled, and `\uXXXX` was
// left as a literal backslash-u sequence). A `\uXXXX` escape decodes to its
// raw UTF-16 code unit via `Ch.fromInt`; a surrogate pair (`😀`)
// decodes correctly with no special-case combining logic, since appending
// two UTF-16 code units in sequence reconstructs the pair the same way any
// other UTF-16 string does.
func parseJsonString(src: in String, pos: inout Int): String {
  pos += 1  // skip opening "
  var s = ""
  while pos < src.length and src[pos] != '"' {
    if src[pos] == '\\' and pos + 1 < src.length {
      pos += 1
      val esc = src[pos]
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
            s = s + charToString(Ch.fromInt(code))
            pos += 4
          }
          case None -> {
            s = s + "\\" + charToString(esc)
          }
        }
      } else {
        s = s + "\\" + charToString(esc)
      }
    } else {
      s = s + charToString(src[pos])
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
  while pos < src.length and (src[pos] == ' ' or src[pos] == '\t' or src[pos] == '\n' or src[pos] == '\r') {
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
        if json[i + k] != needle[k] {
          ok = false
        }
        k += 1
      }
      if ok {
        var pos = i + needle.length
        skipJsonWhitespace(json, pos)
        if pos < json.length and json[pos] == ':' {
          pos += 1
          skipJsonWhitespace(json, pos)
          if pos < json.length and json[pos] == '"' {
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
  while pos < src.length and src[pos] != ']' {
    if src[pos] == '"' {
      items.add(parseJsonString(src, pos))
    } else {
      pos += 1
    }
    skipJsonWhitespace(src, pos)
    if pos < src.length and src[pos] == ',' {
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
    val c = s[i]
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
      acc = acc + charToString(c)
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

// Serialize a GeneratorRequest to JSON for the subprocess.
// This is a hand-rolled serialiser — no Std.Json dependency required at
// generator compile time, keeping the SDK lightweight.
pub func serializeRequest(req: in GeneratorRequest): String {
  val td = req.typeDescriptor

  // Serialize fields slice
  val fieldsArr = td.fields.toArray()
  var fieldsJson = "["
  var fi = 0
  while fi < fieldsArr.count {
    val fd = fieldsArr[fi]
    if fi > 0 {
      fieldsJson = fieldsJson + ","
    }
    val ftKind = match fd.fieldType.kind {
      case Primitive -> "Primitive"
      case Slice -> "Slice"
      case OptionType -> "OptionType"
      case ResultType -> "ResultType"
      case Named -> "Named"
      case Generic -> "Generic"
    }
    var ftJson = "{\"kind\":\"" + ftKind + "\""
    ftJson = ftJson + ",\"name\":\"" + jsonEscape(fd.fieldType.name) + "\""
    ftJson = ftJson + ",\"typeArgs\":["
    val taArr = fd.fieldType.typeArgs.toArray()
    var tai = 0
    while tai < taArr.count {
      if tai > 0 {
        ftJson = ftJson + ","
      }
      ftJson = ftJson + "\"" + jsonEscape(taArr[tai]) + "\""
      tai += 1
    }
    ftJson = ftJson + "]}"
    fieldsJson = fieldsJson + "{\"name\":\"" + jsonEscape(fd.name) + "\""
    fieldsJson = fieldsJson + ",\"fieldType\":" + ftJson
    fieldsJson = fieldsJson + ",\"isPublic\":" + (if fd.isPublic { "true" } else { "false" })
    fieldsJson = fieldsJson + ",\"annotations\":" + serializeAnnotations(fd.annotations) + "}"
    fi += 1
  }
  fieldsJson = fieldsJson + "]"

  // Serialize typeParams
  val tpArr = td.typeParams.toArray()
  var tpJson = "["
  var tpi = 0
  while tpi < tpArr.count {
    if tpi > 0 {
      tpJson = tpJson + ","
    }
    tpJson = tpJson + "\"" + jsonEscape(tpArr[tpi]) + "\""
    tpi += 1
  }
  tpJson = tpJson + "]"

  val itemKindStr = match td.kind {
    case Record -> "Record"
    case ExposedRecord -> "ExposedRecord"
    case Union -> "Union"
    case Interface -> "Interface"
  }

  "{\"schemaVersion\":\"1\"" + ",\"generatorArg\":\"" + jsonEscape(req.generatorArg) + "\"" + ",\"packageName\":\"" +
    jsonEscape(req.packageName) +
    "\"" +
    ",\"sourceFile\":\"" +
    jsonEscape(req.sourceFile) +
    "\"" +
    ",\"typeDescriptor\":{" +
    "\"kind\":\"" +
    itemKindStr +
    "\"" +
    ",\"name\":\"" +
    jsonEscape(td.name) +
    "\"" +
    ",\"packageName\":\"" +
    jsonEscape(td.packageName) +
    "\"" +
    ",\"typeParams\":" +
    tpJson +
    ",\"fields\":" +
    fieldsJson +
    ",\"annotations\":" +
    serializeAnnotations(td.annotations) +
    "}}"
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
    if not isValidIdentifierChar(s[i], i == 0) {
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
    if diagContent[pos] == '{' {
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
    if pos < diagContent.length and diagContent[pos] == ',' {
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
    val c = src[pos]
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
      while pos < src.length and src[pos] != '"' {
        if src[pos] == '\\' and pos + 1 < src.length {
          content = content + charToString(src[pos]) + charToString(src[pos + 1])
          pos += 2
        } else {
          content = content + charToString(src[pos])
          pos += 1
        }
      }
      if pos < src.length {
        content = content + "\""
        pos += 1
      }
    } else {
      content = content + charToString(c)
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
        if json[i + k] != needle[k] {
          ok = false
        }
        k += 1
      }
      if ok {
        var pos = i + needle.length
        skipJsonWhitespace(json, pos)
        if pos < json.length and json[pos] == ':' {
          pos += 1
          skipJsonWhitespace(json, pos)
          if pos < json.length and ((json[pos] == '{') or (json[pos] == '[')) {
            return pos
          }
        }
      }
    }
    i += 1
  }
  -1
}

// Parse a slice of FieldDescriptor from the inner content of the fields JSON
// array (i.e. the text between `[` and `]`).
func parseFieldDescriptors(fieldsContent: in String): slice[FieldDescriptor] {
  val result: List[FieldDescriptor] = newList()
  var pos = 0
  skipJsonWhitespace(fieldsContent, pos)
  while pos < fieldsContent.length {
    if fieldsContent[pos] == '{' {
      val objContent = extractJsonBlock(fieldsContent, pos)
      val fName = unwrapOr(jsonGetString(objContent, "name"), "")
      // Parse the nested fieldType object
      val ftPos = jsonFindBlock(objContent, "fieldType")
      var ftKind: FieldTypeKind = Named
      var ftName = ""
      var ftTypeArgs: slice[String] = []
      if ftPos >= 0 {
        var mFtPos = ftPos
        val ftContent = extractJsonBlock(objContent, mFtPos)
        val ftKindStr = unwrapOr(jsonGetString(ftContent, "kind"), "Named")
        ftName = unwrapOr(jsonGetString(ftContent, "name"), "")
        ftKind = if ftKindStr == "Primitive" {
          Primitive
        } else if ftKindStr == "Slice" {
          Slice
        } else if ftKindStr == "OptionType" {
          OptionType
        } else if ftKindStr == "ResultType" {
          ResultType
        } else if ftKindStr == "Generic" {
          Generic
        } else {
          Named
        }
        val taPos = jsonFindBlock(ftContent, "typeArgs")
        if taPos >= 0 {
          var mTaPos = taPos
          val taList = parseJsonStringArray(ftContent, mTaPos)
          ftTypeArgs = taList.toSlice()
        }
      }
      if fName != "" {
        result.add(
          FieldDescriptor(
            name = fName,
            fieldType = FieldType(kind = ftKind, name = ftName, typeArgs = ftTypeArgs),
            isPublic = true,
            annotations = []
          )
        )
      }
    } else {
      pos += 1
    }
    skipJsonWhitespace(fieldsContent, pos)
    if pos < fieldsContent.length and fieldsContent[pos] == ',' {
      pos += 1
    }
    skipJsonWhitespace(fieldsContent, pos)
  }
  result.toSlice()
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
pub func runGenerator(generate: (GeneratorRequest) -> GeneratorResponse): Int {
  val json = match Console.readAll() {
    case Ok(s) -> s
    case Err(e) -> {
      Console.error("GeneratorSdk: failed to read request from stdin: " + e.message())
      return 1
    }
  }
  val version = match jsonGetString(json, "schemaVersion") {
    case None -> {
      Console.error("GeneratorSdk: missing schemaVersion in request")
      return 1
    }
    case Some(v) -> v
  }
  if version != "1" {
    Console.error("GeneratorSdk: unsupported schemaVersion " + version)
    return 1
  }

  val generatorArg = unwrapOr(jsonGetString(json, "generatorArg"), "")
  val pkgName = unwrapOr(jsonGetString(json, "packageName"), "")
  val srcFile = unwrapOr(jsonGetString(json, "sourceFile"), "")

  // Extract the typeDescriptor sub-object and deserialize it fully.
  var tdKind: ItemKind = Record
  var tdName = ""
  var tdPkg = ""
  var tdTypeParams: slice[String] = []
  var tdFields: slice[FieldDescriptor] = []

  val tdBlockPos = jsonFindBlock(json, "typeDescriptor")
  if tdBlockPos >= 0 {
    var mTdPos = tdBlockPos
    val tdContent = extractJsonBlock(json, mTdPos)

    val kindStr = unwrapOr(jsonGetString(tdContent, "kind"), "Record")
    tdKind = if kindStr == "ExposedRecord" {
      ExposedRecord
    } else if kindStr == "Union" {
      Union
    } else if kindStr == "Interface" {
      Interface
    } else {
      Record
    }
    tdName = unwrapOr(jsonGetString(tdContent, "name"), "")
    tdPkg = unwrapOr(jsonGetString(tdContent, "packageName"), "")

    // typeParams
    val tpPos = jsonFindBlock(tdContent, "typeParams")
    if tpPos >= 0 {
      var mTpPos = tpPos
      val tpList = parseJsonStringArray(tdContent, mTpPos)
      tdTypeParams = tpList.toSlice()
    }

    // fields
    val fPos = jsonFindBlock(tdContent, "fields")
    if fPos >= 0 {
      var mFPos = fPos
      val fContent = extractJsonBlock(tdContent, mFPos)
      tdFields = parseFieldDescriptors(fContent)
    }
  }

  // `TypeDescriptor.name` carries an `invariant: name.length > 0` — but a
  // missing `typeDescriptor` block or an unrecognized `kind` used to
  // silently fall through to an empty-named `Record` here rather than
  // failing the build with a message naming the actual problem. Check
  // explicitly (rather than letting the invariant panic escape as an
  // uncaught `Bug`) so the failure is a clean exit code with a clear
  // stderr message, matching every other malformed-request check above.
  if tdName.length == 0 {
    Console.error("GeneratorSdk: malformed request: missing or empty typeDescriptor.name")
    return 1
  }

  val td = TypeDescriptor(
    kind = tdKind,
    name = tdName,
    packageName = tdPkg,
    typeParams = tdTypeParams,
    fields = tdFields,
    annotations = []
  )

  val req = GeneratorRequest(
    generatorArg = generatorArg,
    typeDescriptor = td,
    packageName = pkgName,
    sourceFile = srcFile
  )

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
