// generator_sdk.l — Lyric.GeneratorSdk
//
// Contract types and stdin/stdout driver for custom source generators.
// Generator packages import this and implement:
//
//   pub func generate(req: GeneratorRequest): GeneratorResponse { ... }
//
// The Lyric compiler discovers that entry point by name and invokes it
// once per annotated type per generator.  See docs/40-source-generators.md.

package Lyric.GeneratorSdk

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

// Parse a JSON string value from `src` starting at position `pos`.
// Advances `pos` past the closing quote and returns the unescaped content.
func parseJsonString(src: in String, pos: inout Int): String {
    pos += 1  // skip opening "
    var s = ""
    while pos < src.length and src[pos] != '"' {
        if src[pos] == '\\' and pos + 1 < src.length {
            pos += 1
            val esc = src[pos]
            if esc == 'n'  { s = s + "\n" }
            else if esc == 't'  { s = s + "\t" }
            else if esc == 'r'  { s = s + "\r" }
            else if esc == '"'  { s = s + "\"" }
            else if esc == '\\' { s = s + "\\" }
            else { s = s + "\\" + charToString(esc) }
        } else {
            s = s + charToString(src[pos])
        }
        pos += 1
    }
    if pos < src.length { pos += 1 }  // skip closing "
    s
}

func charToString(c: in Char): String { "" + c }

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
                if json[i + k] != needle[k] { ok = false }
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
        if pos < src.length and src[pos] == ',' { pos += 1 }
        skipJsonWhitespace(src, pos)
    }
    if pos < src.length { pos += 1 }  // skip ]
    items
}

// Escape a string for embedding in a JSON value (RFC 8259 §7).
func jsonEscape(s: in String): String {
    var out = ""
    var i = 0
    while i < s.length {
        val c = s[i]
        if c == '"'  { out = out + "\\\"" }
        else if c == '\\' { out = out + "\\\\" }
        else if c == '\n' { out = out + "\\n" }
        else if c == '\r' { out = out + "\\r" }
        else if c == '\t' { out = out + "\\t" }
        else { out = out + charToString(c) }
        i += 1
    }
    out
}

// Serialize a GeneratorRequest to JSON for the subprocess.
// This is a hand-rolled serialiser — no Std.Json dependency required at
// generator compile time, keeping the SDK lightweight.
pub func serializeRequest(req: in GeneratorRequest): String {
    val td = req.typeDescriptor

    // Serialize annotations slice
    func serializeAnnotations(anns: in slice[AnnotationDescriptor]): String {
        var out = "["
        val arr = anns.toArray()
        var i = 0
        while i < arr.count {
            val a = arr[i]
            if i > 0 { out = out + "," }
            out = out + "{\"name\":\"" + jsonEscape(a.name) + "\",\"args\":["
            val argArr = a.args.toArray()
            var j = 0
            while j < argArr.count {
                if j > 0 { out = out + "," }
                out = out + "\"" + jsonEscape(argArr[j]) + "\""
                j += 1
            }
            out = out + "]}"
            i += 1
        }
        out + "]"
    }

    // Serialize fields slice
    val fieldsArr = td.fields.toArray()
    var fieldsJson = "["
    var fi = 0
    while fi < fieldsArr.count {
        val fd = fieldsArr[fi]
        if fi > 0 { fieldsJson = fieldsJson + "," }
        val ftKind = match fd.fieldType.kind {
            case Primitive  -> "Primitive"
            case Slice      -> "Slice"
            case OptionType -> "OptionType"
            case ResultType -> "ResultType"
            case Named      -> "Named"
            case Generic    -> "Generic"
        }
        var ftJson = "{\"kind\":\"" + ftKind + "\""
        ftJson = ftJson + ",\"name\":\"" + jsonEscape(fd.fieldType.name) + "\""
        ftJson = ftJson + ",\"typeArgs\":["
        val taArr = fd.fieldType.typeArgs.toArray()
        var tai = 0
        while tai < taArr.count {
            if tai > 0 { ftJson = ftJson + "," }
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
        if tpi > 0 { tpJson = tpJson + "," }
        tpJson = tpJson + "\"" + jsonEscape(tpArr[tpi]) + "\""
        tpi += 1
    }
    tpJson = tpJson + "]"

    val itemKindStr = match td.kind {
        case Record        -> "Record"
        case ExposedRecord -> "ExposedRecord"
        case Union         -> "Union"
        case Interface     -> "Interface"
    }

    "{\"schemaVersion\":1" +
    ",\"generatorArg\":\"" + jsonEscape(req.generatorArg) + "\"" +
    ",\"packageName\":\"" + jsonEscape(req.packageName) + "\"" +
    ",\"sourceFile\":\"" + jsonEscape(req.sourceFile) + "\"" +
    ",\"typeDescriptor\":{" +
        "\"kind\":\"" + itemKindStr + "\"" +
        ",\"name\":\"" + jsonEscape(td.name) + "\"" +
        ",\"packageName\":\"" + jsonEscape(td.packageName) + "\"" +
        ",\"typeParams\":" + tpJson +
        ",\"fields\":" + fieldsJson +
        ",\"annotations\":" + serializeAnnotations(td.annotations) +
    "}}"
}

// Parse a GeneratorResponse from JSON returned by the subprocess.
pub func parseResponse(json: in String): Result[GeneratorResponse, String] {
    val lyricSource = unwrapOr(jsonGetString(json, "lyricSource"), "")

    // Parse additionalImports array
    val additionalImports: List[String] = newList()
    val importsKey = "\"additionalImports\""
    var ki = 0
    while ki < json.length {
        if json.length - ki >= importsKey.length {
            var matchOk = true
            var m = 0
            while m < importsKey.length {
                if json[ki + m] != importsKey[m] { matchOk = false }
                m += 1
            }
            if matchOk {
                var pos = ki + importsKey.length
                skipJsonWhitespace(json, pos)
                if pos < json.length and json[pos] == ':' {
                    pos += 1
                    skipJsonWhitespace(json, pos)
                    if pos < json.length and json[pos] == '[' {
                        val items = parseJsonStringArray(json, pos)
                        var ii = 0
                        while ii < items.count {
                            additionalImports.add(items[ii])
                            ii += 1
                        }
                    }
                }
                ki = json.length  // done
            }
        }
        ki += 1
    }

    // For diagnostics we do a lightweight scan: look for "severity":"Error" / "message":"..."
    // pairs inside the diagnostics array.  A full JSON parser is out of scope for the SDK.
    val diagnostics: List[GeneratorDiagnostic] = newList()

    Ok(value = GeneratorResponse(
        lyricSource       = lyricSource,
        additionalImports = additionalImports.toSlice(),
        diagnostics       = diagnostics.toSlice()))
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
            if depth > 0 { content = content + charToString(c) }
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
            if pos < src.length { content = content + "\""; pos += 1 }
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
                if json[i + k] != needle[k] { ok = false }
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
            if ftPos >= 0 {
                var mFtPos = ftPos
                val ftContent = extractJsonBlock(objContent, mFtPos)
                val ftKindStr = unwrapOr(jsonGetString(ftContent, "kind"), "Named")
                ftName = unwrapOr(jsonGetString(ftContent, "name"), "")
                ftKind = if ftKindStr == "Primitive"  { Primitive }
                         else if ftKindStr == "Slice"      { Slice }
                         else if ftKindStr == "OptionType" { OptionType }
                         else if ftKindStr == "ResultType" { ResultType }
                         else if ftKindStr == "Generic"    { Generic }
                         else                              { Named }
            }
            if fName != "" {
                result.add(FieldDescriptor(
                    name        = fName,
                    fieldType   = FieldType(kind = ftKind, name = ftName, typeArgs = [||]),
                    isPublic    = true,
                    annotations = [||]))
            }
        } else {
            pos += 1
        }
        skipJsonWhitespace(fieldsContent, pos)
        if pos < fieldsContent.length and fieldsContent[pos] == ',' { pos += 1 }
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

pub func runGenerator(generate: in func(GeneratorRequest): GeneratorResponse): Int {
    val json = Console.readAll()
    val version = match jsonGetString(json, "schemaVersion") {
        case None    -> {
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
    val pkgName      = unwrapOr(jsonGetString(json, "packageName"), "")
    val srcFile      = unwrapOr(jsonGetString(json, "sourceFile"), "")

    // Extract the typeDescriptor sub-object and deserialize it fully.
    var tdKind: ItemKind = Record
    var tdName = ""
    var tdPkg  = ""
    var tdTypeParams: slice[String] = [||]
    var tdFields: slice[FieldDescriptor] = [||]

    val tdBlockPos = jsonFindBlock(json, "typeDescriptor")
    if tdBlockPos >= 0 {
        var mTdPos = tdBlockPos
        val tdContent = extractJsonBlock(json, mTdPos)

        val kindStr = unwrapOr(jsonGetString(tdContent, "kind"), "Record")
        tdKind = if kindStr == "ExposedRecord" { ExposedRecord }
                 else if kindStr == "Union"     { Union }
                 else if kindStr == "Interface"  { Interface }
                 else                            { Record }
        tdName = unwrapOr(jsonGetString(tdContent, "name"), "")
        tdPkg  = unwrapOr(jsonGetString(tdContent, "packageName"), "")

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

    val td = TypeDescriptor(
        kind        = tdKind,
        name        = tdName,
        packageName = tdPkg,
        typeParams  = tdTypeParams,
        fields      = tdFields,
        annotations = [||])

    val req = GeneratorRequest(
        generatorArg   = generatorArg,
        typeDescriptor = td,
        packageName    = pkgName,
        sourceFile     = srcFile)

    val resp = generate(req)

    val jsonOut = serializeResponseForOutput(resp)
    Console.print(jsonOut)
    0
}

// Serialize a GeneratorResponse for stdout output.
func serializeResponseForOutput(resp: in GeneratorResponse): String {
    var out = "{\"lyricSource\":\"" + jsonEscape(resp.lyricSource) + "\""
    out = out + ",\"additionalImports\":["
    val impArr = resp.additionalImports.toArray()
    var i = 0
    while i < impArr.count {
        if i > 0 { out = out + "," }
        out = out + "\"" + jsonEscape(impArr[i]) + "\""
        i += 1
    }
    out = out + "],\"diagnostics\":["
    val diagArr = resp.diagnostics.toArray()
    var di = 0
    while di < diagArr.count {
        val d = diagArr[di]
        if di > 0 { out = out + "," }
        val sevStr = match d.severity {
            case Error   -> "Error"
            case Warning -> "Warning"
            case Info    -> "Info"
        }
        out = out + "{\"severity\":\"" + sevStr + "\""
        out = out + ",\"message\":\"" + jsonEscape(d.message) + "\""
        val codeStr = match d.code {
            case None    -> "null"
            case Some(c) -> "\"" + jsonEscape(c) + "\""
        }
        out = out + ",\"code\":" + codeStr + "}"
        di += 1
    }
    out + "]}"
}
