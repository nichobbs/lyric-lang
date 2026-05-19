// generator/generator.l — Lyric.Generator
//
// Source-text pre-processor for custom @generate(Pkg.Name) annotations.
//
// Called by Lyric.Cli.buildOne before the source is handed to the emitter.
// For each @generate(X.Y) annotation found in the source text (dotted names
// only — bare names like @generate(Json) are handled by the F# bootstrap's
// Generate.synthesizeItems pass), the pre-processor:
//
//   1. Resolves the generator package DLL from restored packages next to the
//      manifest.
//   2. Invokes it via `dotnet exec <dll>` with the GeneratorRequest JSON on
//      stdin.
//   3. Appends the returned lyricSource and additionalImports to the source.
//
// See docs/40-source-generators.md and D075.

package Lyric.Generator

import Std.Core
import Std.Collections
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.ProcessCapture as ProcessCapture

// ─────────────────────────────────────────────────────────────────────────────
// §1. Lightweight source scanner
// ─────────────────────────────────────────────────────────────────────────────

// A detected @generate(X.Y) annotation with the type that follows it.
record GenerateDirective {
    generatorArg:  String   // e.g. "Proto.Derive"
    typeName:      String   // e.g. "Order"
    typeKind:      String   // "record" | "exposed record" | "union" | "interface"
    rawFields:     String   // raw field block text (empty for unions/interfaces)
    packageName:   String   // package header of the source file
}

func charIsIdent(c: in Char): Bool {
    (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
    (c >= '0' and c <= '9') or c == '_'
}

func charIsIdentStart(c: in Char): Bool {
    (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'
}

func charToString(c: in Char): String { "" + c }

// Skip whitespace (spaces and tabs only — not newlines).
func skipWs(src: in String, pos: inout Int): Unit {
    while pos < src.length and (src[pos] == ' ' or src[pos] == '\t') {
        pos += 1
    }
}

// Skip whitespace including newlines.
func skipWsAll(src: in String, pos: inout Int): Unit {
    while pos < src.length and
          (src[pos] == ' ' or src[pos] == '\t' or src[pos] == '\n' or src[pos] == '\r') {
        pos += 1
    }
}

// Read an identifier (letters, digits, underscores) starting at `pos`.
func readIdent(src: in String, pos: inout Int): String {
    var id = ""
    while pos < src.length and charIsIdent(src[pos]) {
        id = id + charToString(src[pos])
        pos += 1
    }
    id
}

// Read a dotted identifier (e.g. "Proto.Derive", "MyOrg.MyPkg.Generator").
func readDottedIdent(src: in String, pos: inout Int): String {
    var result = ""
    while pos < src.length and (charIsIdent(src[pos]) or src[pos] == '.') {
        result = result + charToString(src[pos])
        pos += 1
    }
    result
}

// Check that `src` contains `needle` starting at `pos` (case-sensitive).
func matchAt(src: in String, pos: in Int, needle: in String): Bool {
    if src.length - pos < needle.length { return false }
    var i = 0
    while i < needle.length {
        if src[pos + i] != needle[i] { return false }
        i += 1
    }
    true
}

// Extract the `package X.Y` declaration from a source file.
func extractPackageName(src: in String): String {
    var i = 0
    while i < src.length {
        if matchAt(src, i, "package") {
            val afterKw = i + 7
            if afterKw < src.length and (src[afterKw] == ' ' or src[afterKw] == '\t') {
                var pos = afterKw
                skipWs(src, pos)
                return readDottedIdent(src, pos)
            }
        }
        // Skip to next line
        while i < src.length and src[i] != '\n' { i += 1 }
        i += 1
    }
    ""
}

// Skip a block comment `/* ... */` starting at `pos` (positioned at `/*`).
func skipBlockComment(src: in String, pos: inout Int): Unit {
    pos += 2  // skip /*
    while pos + 1 < src.length {
        if src[pos] == '*' and src[pos + 1] == '/' {
            pos += 2
            return ()
        }
        pos += 1
    }
}

// Skip a line comment `// ...` up to but not including the newline.
func skipLineComment(src: in String, pos: inout Int): Unit {
    while pos < src.length and src[pos] != '\n' { pos += 1 }
}

// Read the content of a `{ ... }` block (balanced braces), returning the
// inner text.  `pos` must be positioned at the opening `{`.
// Returns the inner text (excluding the outermost braces).
func readBracedBlock(src: in String, pos: inout Int): String {
    pos += 1  // skip {
    var depth = 1
    var content = ""
    while pos < src.length and depth > 0 {
        val c = src[pos]
        if c == '{' { depth += 1; content = content + charToString(c); pos += 1 }
        else if c == '}' {
            depth -= 1
            if depth > 0 { content = content + charToString(c) }
            pos += 1
        } else if c == '/' and pos + 1 < src.length and src[pos + 1] == '*' {
            val start = pos
            skipBlockComment(src, pos)
            // preserve comment text in content
            var ci = start
            while ci < pos { content = content + charToString(src[ci]); ci += 1 }
        } else if c == '/' and pos + 1 < src.length and src[pos + 1] == '/' {
            val start = pos
            skipLineComment(src, pos)
            var ci = start
            while ci < pos { content = content + charToString(src[ci]); ci += 1 }
        } else {
            content = content + charToString(c)
            pos += 1
        }
    }
    content
}

// Scan `src` for all @generate(X.Y) directives where the argument contains a dot
// (custom generator).  Returns a list of GenerateDirective values.
func scanDirectives(src: in String, packageName: in String): List[GenerateDirective] {
    val results: List[GenerateDirective] = newList()
    var i = 0
    while i < src.length {
        // Skip line comments
        if src[i] == '/' and i + 1 < src.length and src[i + 1] == '/' {
            skipLineComment(src, i)
        }
        // Skip block comments
        else if src[i] == '/' and i + 1 < src.length and src[i + 1] == '*' {
            skipBlockComment(src, i)
        }
        // Look for @generate(
        else if src[i] == '@' and matchAt(src, i + 1, "generate(") {
            var pos = i + 10  // past "@generate("
            val arg = readDottedIdent(src, pos)
            // Skip closing ) if present
            if pos < src.length and src[pos] == ')' { pos += 1 }
            // Only custom generators (dotted names) go through this pipeline
            if Str.contains(arg, ".") {
                // Skip whitespace and look for the type declaration
                skipWsAll(src, pos)
                // Optional extra annotations between @generate(...) and the type decl
                while pos < src.length and src[pos] == '@' {
                    pos += 1
                    while pos < src.length and charIsIdent(src[pos]) { pos += 1 }
                    if pos < src.length and src[pos] == '(' {
                        var depth = 1; pos += 1
                        while pos < src.length and depth > 0 {
                            if src[pos] == '(' { depth += 1 }
                            else if src[pos] == ')' { depth -= 1 }
                            pos += 1
                        }
                    }
                    skipWsAll(src, pos)
                }
                // Visibility keywords
                if matchAt(src, pos, "pub") { pos += 3; skipWs(src, pos) }
                // Type kind
                var typeKind = ""
                var typeName = ""
                var rawFields = ""
                if matchAt(src, pos, "exposed record") {
                    typeKind = "exposed record"
                    pos += 14; skipWs(src, pos)
                    typeName = readIdent(src, pos)
                } else if matchAt(src, pos, "record") {
                    typeKind = "record"
                    pos += 6; skipWs(src, pos)
                    typeName = readIdent(src, pos)
                } else if matchAt(src, pos, "union") {
                    typeKind = "union"
                    pos += 5; skipWs(src, pos)
                    typeName = readIdent(src, pos)
                } else if matchAt(src, pos, "interface") {
                    typeKind = "interface"
                    pos += 9; skipWs(src, pos)
                    typeName = readIdent(src, pos)
                }
                if typeName != "" {
                    // Skip to opening brace
                    while pos < src.length and src[pos] != '{' and src[pos] != '\n' { pos += 1 }
                    if pos < src.length and src[pos] == '{' {
                        rawFields = readBracedBlock(src, pos)
                    }
                    results.add(GenerateDirective(
                        generatorArg = arg,
                        typeName     = typeName,
                        typeKind     = typeKind,
                        rawFields    = rawFields,
                        packageName  = packageName))
                }
            }
            i = pos
        } else {
            i += 1
        }
    }
    results
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Field parser (lightweight)
// ─────────────────────────────────────────────────────────────────────────────

// Parse the field block content (everything inside `{ }` of a record).
// Returns a list of (name, typeText) pairs for public fields.
func parseFields(block: in String): List[StringPair] {
    val fields: List[StringPair] = newList()
    var i = 0
    while i < block.length {
        skipWsAll(block, i)
        if i >= block.length { return fields }
        // Skip comments
        if block[i] == '/' and i + 1 < block.length and block[i + 1] == '/' {
            skipLineComment(block, i)
        } else if block[i] == '/' and i + 1 < block.length and block[i + 1] == '*' {
            skipBlockComment(block, i)
        } else if charIsIdentStart(block[i]) {
            // Read field name
            val name = readIdent(block, i)
            skipWs(block, i)
            if i < block.length and block[i] == ':' {
                i += 1
                skipWs(block, i)
                // Read type text up to newline, comma, or closing brace
                var typeText = ""
                while i < block.length and block[i] != '\n' and block[i] != ',' and block[i] != '}' {
                    typeText = typeText + charToString(block[i])
                    i += 1
                }
                fields.add(StringPair(first = name, second = Str.trim(typeText)))
            } else {
                // Not a field — skip to next line
                while i < block.length and block[i] != '\n' { i += 1 }
            }
        } else {
            i += 1
        }
    }
    fields
}

record StringPair {
    first:  String
    second: String
}

// Classify a type text string into FieldTypeKind + inner args.
func classifyType(typeText: in String): StringPair {
    // slice[String] literal — use .length, not .count
    val primitives: slice[String] = ["Bool", "Int", "Long", "UInt", "ULong", "Float", "Double", "Char", "String"]
    var pi = 0
    while pi < primitives.length {
        if primitives[pi] == typeText { return StringPair(first = "Primitive", second = "") }
        pi += 1
    }
    // substring(start, count): subtract prefix length + 1 for the closing ']'
    if matchAt(typeText, 0, "slice[") { return StringPair(first = "Slice", second = typeText.substring(6, typeText.length - 7)) }
    if matchAt(typeText, 0, "Option[") { return StringPair(first = "OptionType", second = typeText.substring(7, typeText.length - 8)) }
    if matchAt(typeText, 0, "Result[") { return StringPair(first = "ResultType", second = typeText.substring(7, typeText.length - 8)) }
    if Str.contains(typeText, "[") { return StringPair(first = "Generic", second = "") }
    StringPair(first = "Named", second = "")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. JSON serialisation for GeneratorRequest
// ─────────────────────────────────────────────────────────────────────────────

func jsonEscape(s: in String): String {
    var buf = ""
    var i = 0
    while i < s.length {
        val c = s[i]
        if c == '"'  { buf = buf + "\\\"" }
        else if c == '\\' { buf = buf + "\\\\" }
        else if c == '\n' { buf = buf + "\\n" }
        else if c == '\r' { buf = buf + "\\r" }
        else if c == '\t' { buf = buf + "\\t" }
        else { buf = buf + charToString(c) }
        i += 1
    }
    buf
}

func buildRequestJson(dir: in GenerateDirective, sourceFile: in String): String {
    val itemKindStr = if dir.typeKind == "exposed record" { "ExposedRecord" }
                     else if dir.typeKind == "union"     { "Union" }
                     else if dir.typeKind == "interface" { "Interface" }
                     else                                { "Record" }

    val fields = parseFields(dir.rawFields)
    var fieldsJson = "["
    var fi = 0
    while fi < fields.count {
        val f = fields[fi]
        if fi > 0 { fieldsJson = fieldsJson + "," }
        val classified = classifyType(f.second)
        fieldsJson = fieldsJson +
            "{\"name\":\"" + jsonEscape(f.first) + "\"" +
            ",\"fieldType\":{" +
                "\"kind\":\"" + classified.first + "\"" +
                ",\"name\":\"" + jsonEscape(f.second) + "\"" +
                ",\"typeArgs\":[]}" +
            ",\"isPublic\":true" +
            ",\"annotations\":[]}"
        fi += 1
    }
    fieldsJson = fieldsJson + "]"

    "{\"schemaVersion\":\"1\"" +
    ",\"generatorArg\":\"" + jsonEscape(dir.generatorArg) + "\"" +
    ",\"packageName\":\"" + jsonEscape(dir.packageName) + "\"" +
    ",\"sourceFile\":\"" + jsonEscape(sourceFile) + "\"" +
    ",\"typeDescriptor\":{" +
        "\"kind\":\"" + itemKindStr + "\"" +
        ",\"name\":\"" + jsonEscape(dir.typeName) + "\"" +
        ",\"packageName\":\"" + jsonEscape(dir.packageName) + "\"" +
        ",\"typeParams\":[]" +
        ",\"fields\":" + fieldsJson +
        ",\"annotations\":[]}}"
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Generator response parsing
// ─────────────────────────────────────────────────────────────────────────────

func skipJsonWs(src: in String, pos: inout Int): Unit {
    while pos < src.length and
          (src[pos] == ' ' or src[pos] == '\t' or src[pos] == '\n' or src[pos] == '\r') {
        pos += 1
    }
}

func parseJsonStringValue(src: in String, pos: inout Int): String {
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

// Find a top-level string value by key in a JSON object.
func jsonGetString(json: in String, key: in String): Option[String] {
    val needle = "\"" + key + "\""
    var i = 0
    while i <= json.length - needle.length {
        var ok = true
        var k = 0
        while k < needle.length {
            if json[i + k] != needle[k] { ok = false }
            k += 1
        }
        if ok {
            var pos = i + needle.length
            skipJsonWs(json, pos)
            if pos < json.length and json[pos] == ':' {
                pos += 1
                skipJsonWs(json, pos)
                if pos < json.length and json[pos] == '"' {
                    val s = parseJsonStringValue(json, pos)
                    return Some(value = s)
                }
            }
        }
        i += 1
    }
    None
}

func parseJsonStringArray(json: in String, pos: inout Int): List[String] {
    val items: List[String] = newList()
    pos += 1  // skip [
    skipJsonWs(json, pos)
    while pos < json.length and json[pos] != ']' {
        if json[pos] == '"' {
            items.add(parseJsonStringValue(json, pos))
        } else {
            pos += 1
        }
        skipJsonWs(json, pos)
        if pos < json.length and json[pos] == ',' { pos += 1 }
        skipJsonWs(json, pos)
    }
    if pos < json.length { pos += 1 }  // skip ]
    items
}

// Parse the response JSON: extract lyricSource, additionalImports, and any
// Error-severity diagnostics.
func parseResponseJson(json: in String): Result[StringPair, String] {
    // Guard: empty/non-JSON output means the generator process crashed or exited non-zero.
    if json == "" {
        return Err(error = "generator produced no output (process may have crashed)")
    }
    if not Str.contains(json, "lyricSource") {
        return Err(error = "generator output is not a valid GeneratorResponse")
    }

    val lyricSource = unwrapOr(jsonGetString(json, "lyricSource"), "")

    // Parse additionalImports — find the key then the array
    var importsText = ""
    val imKey = "\"additionalImports\""
    var ki = 0
    while ki <= json.length - imKey.length {
        var ok = true
        var m = 0
        while m < imKey.length {
            if json[ki + m] != imKey[m] { ok = false }
            m += 1
        }
        if ok {
            var pos = ki + imKey.length
            skipJsonWs(json, pos)
            if pos < json.length and json[pos] == ':' {
                pos += 1
                skipJsonWs(json, pos)
                if pos < json.length and json[pos] == '[' {
                    val items = parseJsonStringArray(json, pos)
                    var ii = 0
                    while ii < items.count {
                        if ii > 0 { importsText = importsText + "\n" }
                        importsText = importsText + items[ii]
                        ii += 1
                    }
                }
            }
            ki = json.length  // found — done
        } else {
            ki += 1
        }
    }

    // Check for Error-severity diagnostics.
    // Match "severity":"Error" as a literal substring — the generator SDK emits
    // compact JSON (no spaces), so this is safe.  Generated source text goes
    // through jsonEscape, so a type named Error becomes \"Error\" in the JSON
    // and cannot produce a false match here.
    if Str.contains(json, "\"severity\":\"Error\"") {
        return Err(error = unwrapOr(jsonGetString(json, "message"), "generator error"))
    }

    // Return lyricSource and imports as a pair (separator "\n---imports---\n")
    Ok(value = StringPair(first = lyricSource, second = importsText))
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Generator DLL resolution
// ─────────────────────────────────────────────────────────────────────────────

// Find the restored DLL for a generator package.
// `manifestPath` is the path to the consumer's lyric.toml.
// `generatorPkg` is the package name (e.g. "Proto.Derive").
//
// Convention: restored packages live in `.lyric/packages/<name>/` relative to
// the manifest directory.  The build DLL is `<name>.dll` inside that directory.
func resolveGeneratorDll(manifestPath: in String, generatorPkg: in String): Result[String, String] {
    val manifestDir = Path.dirname(manifestPath)
    // Sanitise package name to a filesystem-safe directory name
    // (replace dots and other punctuation with dashes, lowercase).
    var dirName = ""
    var i = 0
    while i < generatorPkg.length {
        val c = generatorPkg[i]
        if c == '.' { dirName = dirName + "-" }
        else if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' {
            dirName = dirName + charToString(c)
        }
        i += 1
    }
    val pkgDir = Path.join(Path.join(Path.join(manifestDir, ".lyric"), "packages"), dirName)
    val dllPath = Path.join(pkgDir, generatorPkg + ".dll")
    if File.fileExists(dllPath) {
        Ok(value = dllPath)
    } else {
        // Fall back: look for any .dll in the package directory
        Err(error =
            "generator package '" + generatorPkg +
            "' not found at " + dllPath +
            " — run `lyric restore` first")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Public entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Scan `source` for custom @generate(X.Y) directives and invoke the
/// generator subprocess for each annotated type.  Returns augmented source
/// with the generated Lyric fragments appended, or Err with a diagnostic
/// message if any generator fails.
///
/// `manifestPath` must be `Some` when the source contains custom generators;
/// if it is `None` and custom generators are present, the function returns Err.
pub func preprocess(source: in String, manifestPath: in Option[String], sourceFilePath: in String): Result[String, String] {
    val pkgName = extractPackageName(source)
    val directives = scanDirectives(source, pkgName)

    if directives.count == 0 { return Ok(value = source) }

    val mfPath = match manifestPath {
        case None ->
            return Err(error =
                "custom @generate(...) requires --manifest to locate generator packages")
        case Some(p) -> p
    }

    var augmented = source
    var extraImports = ""

    // Iterate over directives with a while loop (for-over-slice is not supported).
    var di = 0
    while di < directives.count {
        val dir = directives[di]

        val dllPath = match resolveGeneratorDll(mfPath, dir.generatorArg) {
            case Err(e) -> return Err(error = e)
            case Ok(p)  -> p
        }

        val requestJson = buildRequestJson(dir, sourceFilePath)
        // Build args as List[String] using newList + add (slice literals can't be passed as List[String]).
        val captureArgs = newList()
        captureArgs.add("exec")
        captureArgs.add(dllPath)
        val responseJson = ProcessCapture.runCapture("dotnet", captureArgs, requestJson)

        match parseResponseJson(responseJson) {
            case Err(e)    -> return Err(error = "generator '" + dir.generatorArg + "': " + e)
            case Ok(parts) -> {
                val generatedSource = parts.first
                val importsLine     = parts.second
                if generatedSource != "" {
                    augmented = augmented + "\n// @generate(" + dir.generatorArg +
                                ") generated for " + dir.typeName + "\n" +
                                generatedSource
                }
                if importsLine != "" {
                    extraImports = extraImports + "\n" + importsLine
                }
            }
        }

        di += 1
    }

    // Inject additional imports after the package declaration line.
    if extraImports != "" {
        val pkgLine = "package " + pkgName
        var insertAt = 0
        var i = 0
        while i < augmented.length {
            if matchAt(augmented, i, pkgLine) {
                // Find the end of this line ('end' is a keyword — use 'lineEnd').
                var lineEnd = i + pkgLine.length
                while lineEnd < augmented.length and augmented[lineEnd] != '\n' { lineEnd += 1 }
                if lineEnd < augmented.length { lineEnd += 1 }  // include the newline
                insertAt = lineEnd
                i = augmented.length  // stop scanning
            } else {
                i += 1
            }
        }
        if insertAt > 0 {
            augmented =
                augmented.substring(0, insertAt) +
                extraImports + "\n" +
                augmented.substring(insertAt, augmented.length - insertAt)
        }
    }

    Ok(value = augmented)
}
