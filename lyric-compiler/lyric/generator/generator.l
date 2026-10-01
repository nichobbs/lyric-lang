//! generator/generator.l — Lyric.Generator
//!
//! Source-text pre-processor for custom `@generate(Pkg.Name)` annotations
//! (docs/40, D075, D150).
//!
//! `Lyric.Cli` reads each source file of a project and calls `preprocess`
//! before parsing.  For each `@generate(X.Y)` annotation (dotted names only;
//! a bare built-in like `@generate(Json)` is `Lyric.Derives`'s) it:
//!
//!   1. Checks the generator is declared in the consumer's `[dependencies]`
//!      and is a built `kind = "source-generator"` package (the CLI builds
//!      each one for dotnet and passes its DLL in a `GeneratorSet`).
//!   2. Runs it as `dotnet exec <dll>` with the GeneratorRequest JSON on
//!      stdin and decodes the GeneratorResponse on stdout.
//!   3. Checks the generated code parses, then appends it, and places its
//!      `additionalImports` after the `package` line.
//!
//! Failures are X-series diagnostics carrying the annotation's position.
package Lyric.Generator

import Std.Core
import Std.Collections
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.ProcessCapture as ProcessCapture
import Std.JsonValue as Jv
import Lyric.Manifest as Manifest
import Lyric.Parser as Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Lightweight source scanner
// ─────────────────────────────────────────────────────────────────────────────
// A detected @generate(X.Y) annotation with the type that follows it.
// `pub`: this record appears in a `pub` return type; a non-`pub` type in a
// `pub` signature is invisible to external consumers and fails the contract
// round-trip.
pub record GenerateDirective {
  generatorArg: String
  // e.g. "Proto.Derive"
  typeName: String
  // e.g. "Order"
  typeKind: String
  // "record" | "exposed record" | "union" | "interface"
  rawFields: String
  // raw field block text (empty for unions/interfaces)
  packageName: String
  // package header of the source file
  line: Int
  column: Int
  // 1-based position of the `@` of `@generate`
}

func charIsIdent(c: in Char): Bool {
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'
}

func charIsIdentStart(c: in Char): Bool {
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'
}

func charToString(c: in Char): String {
  "" + c
}

// Skip whitespace (spaces and tabs only — not newlines).
func skipWs(src: in String, pos: inout Int): Unit {
  while pos < src.length and (Str.charAtOrReplacement(src, pos) == ' ' or Str.charAtOrReplacement(src, pos) == '\t') {
    pos += 1
  }
}

// Skip whitespace including newlines.
func skipWsAll(src: in String, pos: inout Int): Unit {
  while pos < src.length and (Str.charAtOrReplacement(src, pos) == ' ' or Str.charAtOrReplacement(src, pos) == '\t' or Str.charAtOrReplacement(src, pos) == '\n' or Str.charAtOrReplacement(src, pos) == '\r') {
    pos += 1
  }
}

// Read an identifier (letters, digits, underscores) starting at `pos`.
func readIdent(src: in String, pos: inout Int): String {
  var id = ""
  while pos < src.length and charIsIdent(Str.charAtOrReplacement(src, pos)) {
    id = id + Str.substring(src, pos, 1)
    pos += 1
  }
  id
}

// Read a dotted identifier (e.g. "Proto.Derive", "MyOrg.MyPkg.Generator").
func readDottedIdent(src: in String, pos: inout Int): String {
  var result = ""
  while pos < src.length and (charIsIdent(Str.charAtOrReplacement(src, pos)) or Str.charAtOrReplacement(src, pos) == '.') {
    result = result + Str.substring(src, pos, 1)
    pos += 1
  }
  result
}

// Check that `src` contains `needle` starting at `pos` (case-sensitive).
func matchAt(src: in String, pos: in Int, needle: in String): Bool {
  if src.length - pos < needle.length {
    return false
  }
  var i = 0
  while i < needle.length {
    if Str.codeUnitAt(src, pos + i) != Str.codeUnitAt(needle, i) {
      return false
    }
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
      if afterKw < src.length and (Str.charAtOrReplacement(src, afterKw) == ' ' or Str.charAtOrReplacement(src, afterKw) == '\t') {
        var pos = afterKw
        skipWs(src, pos)
        return readDottedIdent(src, pos)
      }
    }
    // Skip to next line
    while i < src.length and Str.charAtOrReplacement(src, i) != '\n' {
      i += 1
    }
    i += 1
  }
  ""
}

// Skip a block comment `/* ... */` starting at `pos` (positioned at `/*`).
func skipBlockComment(src: in String, pos: inout Int): Unit {
  pos += 2
  // skip /*
  while pos + 1 < src.length {
    if Str.charAtOrReplacement(src, pos) == '*' and Str.charAtOrReplacement(src, pos + 1) == '/' {
      pos += 2
      return ()
    }
    pos += 1
  }
}

// Skip a line comment `// ...` up to but not including the newline.
func skipLineComment(src: in String, pos: inout Int): Unit {
  while pos < src.length and Str.charAtOrReplacement(src, pos) != '\n' {
    pos += 1
  }
}

// Read the content of a `{ ... }` block (balanced braces), returning the
// inner text.  `pos` must be positioned at the opening `{`.
// Returns the inner text (excluding the outermost braces).
func readBracedBlock(src: in String, pos: inout Int): String {
  pos += 1
  // skip {
  var depth = 1
  var content = ""
  while pos < src.length and depth > 0 {
    val c = Str.charAtOrReplacement(src, pos)
    if c == '{' {
      depth += 1
      content = content + charToString(c)
      pos += 1
    } else if c == '}' {
      depth -= 1
      if depth > 0 {
        content = content + charToString(c)
      }
      pos += 1
    } else if c == '/' and pos + 1 < src.length and Str.charAtOrReplacement(src, pos + 1) == '*' {
      val start = pos
      skipBlockComment(src, pos)
      // preserve comment text in content
      var ci = start
      while ci < pos {
        content = content + Str.substring(src, ci, 1)
        ci += 1
      }
    } else if c == '/' and pos + 1 < src.length and Str.charAtOrReplacement(src, pos + 1) == '/' {
      val start = pos
      skipLineComment(src, pos)
      var ci = start
      while ci < pos {
        content = content + Str.substring(src, ci, 1)
        ci += 1
      }
    } else {
      // The raw code unit: `c` is U+FFFD for a surrogate half.
      content = content + Str.substring(src, pos, 1)
      pos += 1
    }
  }
  content
}

// The 1-based line and column of offset `at` in `src`.
func lineAndColumn(src: in String, at: in Int): (Int, Int) {
  var line = 1
  var lineStart = 0
  var i = 0
  while i < at {
    if Str.charAtOrReplacement(src, i) == '\n' {
      line += 1
      lineStart = i + 1
    }
    i += 1
  };
  (line, at - lineStart + 1)
}

// Scan `src` for all @generate(X.Y) directives where the argument contains a dot
// (custom generator).  Returns a list of GenerateDirective values.
//
// Comments AND double-quoted string literals are skipped so a `@generate(X.Y)`
// embedded in a string (e.g. a help-text constant or a documentation example)
// does not trigger a spurious generator invocation (#702).
pub func scanDirectives(src: in String, packageName: in String): List[GenerateDirective] {
  val results: List[GenerateDirective] = newList()
  var i = 0
  while i < src.length {
    // Skip line comments
    if Str.charAtOrReplacement(src, i) == '/' and i + 1 < src.length and Str.charAtOrReplacement(src, i + 1) == '/' {
      skipLineComment(src, i)
    } else if Str.charAtOrReplacement(src, i) == '/' and i + 1 < src.length and Str.charAtOrReplacement(src, i + 1) == '*' {
      // Skip block comments
      skipBlockComment(src, i)
    } else if Str.charAtOrReplacement(src, i) == '"' {
      // Skip double-quoted string literals (including \" escapes).  Triple-
      // quoted (`"""..."""`) and raw (`r"..."`) string literals are NOT
      // skipped today — a `@generate(X.Y)` embedded in either form would
      // still trigger a directive.  These forms are uncommon in
      // source-generator-decorated files; extending the scanner to honour
      // them requires either re-using the full lexer or maintaining a
      // shadow state machine here.  See PR #830 review #840 for the
      // status; once `scanDirectives` consumers complain (or a fuzz pass
      // surfaces a real false positive) the scanner gains a triple-quoted
      // arm and the same `\\` escape treatment.
      i = i + 1
      while i < src.length and Str.charAtOrReplacement(src, i) != '"' {
        // Skip escaped character (\", \\, etc.) so a closing-`"`
        // is not consumed inside the escape pair.
        if Str.charAtOrReplacement(src, i) == '\\' and i + 1 < src.length {
          i = i + 2
        } else {
          i = i + 1
        }
      }
      if i < src.length {
        i = i + 1
      }
      // consume closing `"`
    } else if Str.charAtOrReplacement(src, i) == '@' and matchAt(src, i + 1, "generate(") {
      // Look for @generate(
      val (atLine, atColumn) = lineAndColumn(src, i)
      var pos = i + 10
      // past "@generate("
      val arg = readDottedIdent(src, pos)
      // Skip closing ) if present
      if pos < src.length and Str.charAtOrReplacement(src, pos) == ')' {
        pos += 1
      }
      // Only custom generators (dotted names) go through this pipeline
      if Str.contains(arg, ".") {
        // Skip whitespace and look for the type declaration
        skipWsAll(src, pos)
        // Optional extra annotations between @generate(...) and the type decl
        while pos < src.length and Str.charAtOrReplacement(src, pos) == '@' {
          pos += 1
          while pos < src.length and charIsIdent(Str.charAtOrReplacement(src, pos)) {
            pos += 1
          }
          if pos < src.length and Str.charAtOrReplacement(src, pos) == '(' {
            var depth = 1
            pos += 1
            while pos < src.length and depth > 0 {
              if Str.charAtOrReplacement(src, pos) == '(' {
                depth += 1
              } else if Str.charAtOrReplacement(src, pos) == ')' {
                depth -= 1
              }
              pos += 1
            }
          }
          skipWsAll(src, pos)
        }
        // Visibility keywords
        if matchAt(src, pos, "pub") {
          pos += 3
          skipWs(src, pos)
        }
        // Type kind
        var typeKind = ""
        var typeName = ""
        var rawFields = ""
        if matchAt(src, pos, "exposed record") {
          typeKind = "exposed record"
          pos += 14
          skipWs(src, pos)
          typeName = readIdent(src, pos)
        } else if matchAt(src, pos, "record") {
          typeKind = "record"
          pos += 6
          skipWs(src, pos)
          typeName = readIdent(src, pos)
        } else if matchAt(src, pos, "union") {
          typeKind = "union"
          pos += 5
          skipWs(src, pos)
          typeName = readIdent(src, pos)
        } else if matchAt(src, pos, "interface") {
          typeKind = "interface"
          pos += 9
          skipWs(src, pos)
          typeName = readIdent(src, pos)
        }
        // A directive that annotates no type is kept with an empty
        // `typeName`, so the caller reports it (X0001).
        if typeName == "" {
          results.add(
            GenerateDirective(
              generatorArg = arg,
              typeName = "",
              typeKind = "",
              rawFields = "",
              packageName = packageName,
              line = atLine,
              column = atColumn
            )
          )
        } else {
          // Skip to opening brace
          while pos < src.length and Str.charAtOrReplacement(src, pos) != '{' and Str.charAtOrReplacement(src, pos) != '\n' {
            pos += 1
          }
          if pos < src.length and Str.charAtOrReplacement(src, pos) == '{' {
            rawFields = readBracedBlock(src, pos)
          }
          results.add(
            GenerateDirective(
              generatorArg = arg,
              typeName = typeName,
              typeKind = typeKind,
              rawFields = rawFields,
              packageName = packageName,
              line = atLine,
              column = atColumn
            )
          )
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
    if i >= block.length {
      return fields
    }
    // Skip comments
    if Str.charAtOrReplacement(block, i) == '/' and i + 1 < block.length and Str.charAtOrReplacement(block, i + 1) == '/' {
      skipLineComment(block, i)
    } else if Str.charAtOrReplacement(block, i) == '/' and i + 1 < block.length and Str.charAtOrReplacement(block, i + 1) == '*' {
      skipBlockComment(block, i)
    } else if charIsIdentStart(Str.charAtOrReplacement(block, i)) {
      // Read field name
      val name = readIdent(block, i)
      skipWs(block, i)
      if i < block.length and Str.charAtOrReplacement(block, i) == ':' {
        i += 1
        skipWs(block, i)
        // Read type text up to newline, comma, or closing brace
        var typeText = ""
        while i < block.length and Str.charAtOrReplacement(block, i) != '\n' and Str.charAtOrReplacement(block, i) != ',' and Str.charAtOrReplacement(block, i) != '}' {
          typeText = typeText + Str.substring(block, i, 1)
          i += 1
        }
        fields.add(StringPair(first = name, second = Str.trim(typeText)))
      } else {
        // Not a field — skip to next line
        while i < block.length and Str.charAtOrReplacement(block, i) != '\n' {
          i += 1
        }
      }
    } else {
      i += 1
    }
  }
  fields
}

/// A pair of strings: a field's name and type text, or a type's kind and
/// type-argument text.
pub record StringPair {
  first: String
  second: String
  // Classify a type text string into FieldTypeKind + inner args.
  // The `second` field carries the inner type-args text (everything
  // between the outer brackets) so callers can re-split as needed —
  // `Result[Order, String]` returns `("ResultType", "Order, String")`,
  // and `Map[K, V]` returns `("Generic", "K, V")`.
}

func classifyType(typeText: in String): StringPair {
  // slice[String] literal — use .length, not .count
  val primitives: slice[String] = ["Bool", "Int", "Long", "UInt", "ULong", "Float", "Double", "Char", "String"]
  var pi = 0
  while pi < primitives.length {
    if primitives[pi] == typeText {
      return StringPair(first = "Primitive", second = "")
    }
    pi += 1
  }
  // substring(start, count): subtract prefix length + 1 for the closing ']'
  if matchAt(typeText, 0, "slice[") {
    return StringPair(first = "Slice", second = typeText.substring(6, typeText.length - 7))
  }
  if matchAt(typeText, 0, "Option[") {
    return StringPair(first = "OptionType", second = typeText.substring(7, typeText.length - 8))
  }
  if matchAt(typeText, 0, "Result[") {
    return StringPair(first = "ResultType", second = typeText.substring(7, typeText.length - 8))
  }
  if Str.contains(typeText, "[") {
    // Generic[arg1, arg2, ...] — capture the inner text between the
    // first `[` and the last `]` so source generators can see the
    // applied arguments (#703).
    match Str.indexOf(typeText, "[") {
      case Some(openIx) -> match Str.lastIndexOf(typeText, "]") {
        case Some(closeIx) -> if closeIx > openIx {
          return StringPair(first = "Generic", second = typeText.substring(openIx + 1, closeIx - openIx - 1))
        }
        case None -> {
        }
      }
      case None -> {
      }
    }
    return StringPair(first = "Generic", second = "")
  }
  StringPair(first = "Named", second = "")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. JSON serialisation for GeneratorRequest
// ─────────────────────────────────────────────────────────────────────────────
func jsonEscape(s: in String): String {
  var buf = ""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    if c == '"' {
      buf = buf + "\\\""
    } else if c == '\\' {
      buf = buf + "\\\\"
    } else if c == '\n' {
      buf = buf + "\\n"
    } else if c == '\r' {
      buf = buf + "\\r"
    } else if c == '\t' {
      buf = buf + "\\t"
    } else {
      buf = buf + Str.substring(s, i, 1)
    }
    i += 1
  }
  buf
}

// Split a comma-separated type-args text at the top level (i.e. ignoring
// commas nested inside `[ ]` brackets so `Result[Map[K,V], Err]` produces
// two args, not three).  Whitespace around each split element is trimmed.
func splitTopLevelTypeArgs(s: in String): List[String] {
  val parts: List[String] = newList()
  var i = 0
  var depth = 0
  var start = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    if c == '[' {
      depth = depth + 1
    } else if c == ']' {
      depth = depth - 1
    } else if c == ',' and depth == 0 {
      parts.add(Str.trim(s.substring(start, i - start)))
      start = i + 1
    }
    i = i + 1
  }
  if s.length > start {
    parts.add(Str.trim(s.substring(start, s.length - start)))
  }
  parts
}

func buildRequestJson(dir: in GenerateDirective, sourceFile: in String): String {
  val itemKindStr = if dir.typeKind == "exposed record" {
    "ExposedRecord"
  } else if dir.typeKind == "union" {
    "Union"
  } else if dir.typeKind == "interface" {
    "Interface"
  } else {
    "Record"
  }

  val fields = parseFields(dir.rawFields)
  var fieldsJson = "["
  var fi = 0
  while fi < fields.count {
    val f = fields[fi]
    if fi > 0 {
      fieldsJson = fieldsJson + ","
    }
    val classified = classifyType(f.second)
    // Split the inner type-args text on top-level commas so that
    // `Result[Order, String]` produces ["Order","String"] rather
    // than a single combined element (#703).
    var typeArgsJson = "[]"
    if classified.second != "" {
      val args = splitTopLevelTypeArgs(classified.second)
      var ta = "["
      var ai = 0
      while ai < args.count {
        if ai > 0 {
          ta = ta + ","
        }
        ta = ta + "\"" + jsonEscape(args[ai]) + "\""
        ai = ai + 1
      }
      ta = ta + "]"
      typeArgsJson = ta
    }
    fieldsJson = fieldsJson + "{\"name\":\"" + jsonEscape(f.first) + "\"" + ",\"fieldType\":{" + "\"kind\":\"" +
      classified.first +
      "\"" +
      ",\"name\":\"" +
      jsonEscape(f.second) +
      "\"" +
      ",\"typeArgs\":" +
      typeArgsJson +
      "}" +
      ",\"isPublic\":true" +
      ",\"annotations\":[]}"
    fi += 1
  }
  fieldsJson = fieldsJson + "]"

  "{\"schemaVersion\":\"1\"" + ",\"generatorArg\":\"" + jsonEscape(dir.generatorArg) + "\"" + ",\"packageName\":\"" +
    jsonEscape(dir.packageName) +
    "\"" +
    ",\"sourceFile\":\"" +
    jsonEscape(sourceFile) +
    "\"" +
    ",\"typeDescriptor\":{" +
    "\"kind\":\"" +
    itemKindStr +
    "\"" +
    ",\"name\":\"" +
    jsonEscape(dir.typeName) +
    "\"" +
    ",\"packageName\":\"" +
    jsonEscape(dir.packageName) +
    "\"" +
    ",\"typeParams\":[]" +
    ",\"fields\":" +
    fieldsJson +
    ",\"annotations\":[]}}"
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Generator response parsing
// ─────────────────────────────────────────────────────────────────────────────
/// How long one generator invocation may run before it is stopped.
pub val generatorTimeoutMs: Int = 60000

func isGeneratorIdentifier(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    val letter = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'
    val digit = c >= '0' and c <= '9'
    if not letter and not (digit and i > 0) {
      return false
    }
    i += 1
  }
  true
}

func isGeneratorQualifiedName(s: in String): Bool {
  val segments = Str.split(s, ".")
  var i = 0
  while i < segments.length {
    if not isGeneratorIdentifier(segments[i]) {
      return false
    }
    i += 1
  }
  segments.length > 0
}

/// True when `stmt` is exactly one `import <QualifiedName>` or
/// `import extern <QualifiedName>` statement, optionally `as <Identifier>`.
/// A generator is an untrusted subprocess and its `additionalImports`
/// entries are placed in the file's import section, so anything else
/// (a second statement, a declaration, a newline) is rejected rather than
/// spliced (#7490).  Mirrors `Lyric.GeneratorSdk.isValidImportStatement`.
pub func isValidGeneratorImport(stmt: in String): Bool {
  var rest = ""
  if Str.startsWith(stmt, "import extern ") {
    rest = stmt.substring(14)
  } else if Str.startsWith(stmt, "import ") {
    rest = stmt.substring(7)
  } else {
    return false
  }
  match Str.indexOf(rest, " as ") {
    case None -> isGeneratorQualifiedName(rest)
    case Some(idx) -> isGeneratorQualifiedName(rest.substring(0, idx)) and
      isGeneratorIdentifier(rest.substring(idx + 4))
  }
}

/// One diagnostic a generator reported (`GeneratorDiagnostic` in
/// `Lyric.GeneratorSdk`).  `severity` is "Error", "Warning" or "Info".
pub record ReportedDiagnostic {
  severity: String
  message: String
  code: String
}

/// A generator's decoded `GeneratorResponse`.
pub record GeneratorResult {
  lyricSource: String
  imports: List[String]
  diagnostics: List[ReportedDiagnostic]
}

/// Decodes a generator's stdout as a `GeneratorResponse`.  `stderr`,
/// `exitCode` and `timedOut` come from the capture and explain an empty or
/// malformed response.  An `additionalImports` entry that is not a single
/// import statement fails the response.  The Err text describes why the
/// generator could not be used; the caller reports it as X0009.
pub func parseResponseJson(
  json: in String, stderr: in String, exitCode: in Int, timedOut: in Bool
): Result[GeneratorResult, String] {
  if timedOut {
    return Err(error = "it did not finish within " + Str.fromInt(generatorTimeoutMs / 1000) + " s and was stopped")
  }
  val trimmed = Str.trim(json)
  if trimmed == "" {
    val exitText = if exitCode != 0 { "it exited with code " + Str.fromInt(exitCode) } else { "it wrote no response" }
    val stderrText = if Str.trim(stderr) != "" { ": " + Str.trim(stderr) } else { "" }
    return Err(error = exitText + stderrText)
  }
  val root = match Jv.parseValue(trimmed) {
    case Ok(v) -> v
    case Err(e) -> return Err(error = "its response is not valid JSON (" + e.message() + ")")
  }
  val lyricSource = match Jv.getString(root, "lyricSource") {
    case Some(src) -> src
    case None -> return Err(error = "its response has no \"lyricSource\" string")
  }
  val imports: List[String] = newList()
  match Jv.getArray(root, "additionalImports") {
    case Some(items) -> {
      for item in items {
        match Jv.asString(item) {
          case Some(stmt) -> if isValidGeneratorImport(stmt) {
            imports.add(stmt)
          } else {
            return Err(error = "its additionalImports entry is not a single import statement: " + stmt)
          }
          case None -> return Err(error = "its additionalImports holds a value that is not a string")
        }
      }
    }
    case None -> ()
  }
  val diags: List[ReportedDiagnostic] = newList()
  match Jv.getArray(root, "diagnostics") {
    case Some(items) -> {
      for item in items {
        val severity = unwrapOr(Jv.getString(item, "severity"), "Error")
        val message = unwrapOr(Jv.getString(item, "message"), "")
        val code = unwrapOr(Jv.getString(item, "code"), "")
        diags.add(ReportedDiagnostic(severity = severity, message = message, code = code))
      }
    }
    case None -> ()
  }
  Ok(value = GeneratorResult(lyricSource = lyricSource, imports = imports, diagnostics = diags))
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Generator dependencies (docs/40 §3.1, §5.1; D150)
// ─────────────────────────────────────────────────────────────────────────────
/// Why a declared generator dependency cannot be run, with the diagnostic
/// code to report it under (X0003 or X0009).
pub record GeneratorFailure {
  code: String
  message: String
}

/// What a consumer's manifest offers `@generate(Pkg.Name)`: each generator
/// dependency's built DLL by package name, the declared dependencies that
/// are not generators (name to their `[package].kind`, "" when unset), and
/// the generator dependencies that could not be built.  `Lyric.Cli` builds
/// it from the manifest before any source is read.
pub record GeneratorSet {
  dlls: Map[String, String]
  libraries: Map[String, String]
  failures: Map[String, GeneratorFailure]
}

pub func emptyGeneratorSet(): GeneratorSet {
  GeneratorSet(dlls = newMap(), libraries = newMap(), failures = newMap())
}

/// The X0008 check: `generatorArg` must name a package declared in
/// `[dependencies]`, so no generator runs that the manifest did not opt into.
pub func checkGeneratorDeclaredIn(
  consumerMf: in Manifest.Manifest, generatorArg: in String
): Result[Manifest.DependencyEntry, String] {
  var i = 0
  while i < consumerMf.deps.count {
    if consumerMf.deps[i].name == generatorArg {
      return Ok(value = consumerMf.deps[i])
    }
    i = i + 1
  }
  Err(
    error = "X0008: @generate(" + generatorArg + ") names a package that is not declared in [dependencies] of " +
      consumerMf.filePath +
      "; a generator runs only when the manifest declares it"
  )
}

/// The X0002 check: a package named by `@generate` must declare
/// `[package].kind = "source-generator"` in its manifest at `depMfPath`.
/// Ok("") when it does.
pub func checkGeneratorKind(
  generatorArg: in String, depMfPath: in String, depMf: in Manifest.Manifest
): Result[String, String] {
  match depMf.packageSection.kind {
    case Some(k) -> if k == "source-generator" {
      Ok(value = "")
    } else {
      Err(error = notAGeneratorMessage(generatorArg, k, depMfPath))
    }
    case None -> Err(error = notAGeneratorMessage(generatorArg, "", depMfPath))
  }
}

pub func notAGeneratorMessage(generatorArg: in String, kind: in String, depMfPath: in String): String {
  val declared = if kind == "" { "declares no [package].kind" } else { "declares [package].kind = \"" + kind + "\"" }
  "X0002: @generate(" + generatorArg + ") names a package that is not a source generator: " + depMfPath + " " + declared +
    ", and only kind = \"source-generator\" may be run"
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Public entry point
// ─────────────────────────────────────────────────────────────────────────────
// `["exec", dllPath]` as a typed `List[String]` (#867).
func buildCaptureArgs(dllPath: in String): List[String] {
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  args
}

/// A source file after its custom generators have run: the augmented text,
/// and the warnings to print (generator-reported warnings and notes).
pub record PreprocessOutput {
  source: String
  warnings: List[String]
}

// `<file>: <severity>[<code>] <line>:<column>: <message>`, the CLI's
// diagnostic line shape.
func generatorDiag(
  file: in String,
  severity: in String,
  code: in String,
  line: in Int,
  column: in Int,
  message: in String,
): String {
  file + ": " + severity + "[" + code + "] " + Str.fromInt(line) + ":" + Str.fromInt(column) + ": " + message
}

// The packages `source` imports by `import <name>` (with or without an alias
// or selective list), each with its 1-based line.
func importedPackages(source: in String): List[(String, Int)] {
  val result: List[(String, Int)] = newList()
  val lines = Str.split(source, "\n")
  var li = 0
  while li < lines.length {
    val t = Str.trim(lines[li])
    if Str.startsWith(t, "import ") and not Str.startsWith(t, "import extern ") {
      var pos = 7
      skipWs(t, pos)
      val name = readDottedIdent(t, pos)
      if name != "" {
        result.add((name, li + 1))
      }
    }
    li += 1
  }
  result
}

// The parse diagnostics of `fragment` when spliced into `pkgName` with
// `imports`, as text; "" when it parses.
func fragmentParseErrors(pkgName: in String, imports: in List[String], fragment: in String): String {
  var header = "package " + pkgName + "\n"
  for imp in imports {
    header = header + imp + "\n"
  }
  val headerLines = Str.split(header, "\n").length - 1
  val pr = Parser.parse(header + fragment)
  var text = ""
  var n = 0
  for d in pr.diagnostics {
    if n < 3 {
      if text != "" {
        text = text + "; "
      }
      val fragLine = d.span.startPos.line - headerLines
      text = text + "line " + Str.fromInt(fragLine) + " of the generated code: " + d.message
    }
    n += 1
  }
  if n > 3 {
    text = text + " (and " + Str.fromInt(n - 3) + " more)"
  }
  text
}

/// Runs the custom generators `source` names with `@generate(Pkg.Name)` and
/// splices their output into it (docs/40 §4.2).  `consumerMf` is the
/// manifest that declares the generators, `gens` what it offers (built by
/// `Lyric.Cli`), and `sourceFilePath` the file, for diagnostics.
///
/// Errors are reported together, one per line in the CLI's diagnostic
/// shape: X0001 (an annotation on something that is not a record, union or
/// interface), X0002, X0003, X0004 (generated code that does not parse),
/// X0005 (an error the generator reported), X0006 (an `import` of a
/// generator package), X0008 and X0009 (a generator that could not be built
/// or run).
pub func preprocess(
  source: in String,
  consumerMf: in Option[Manifest.Manifest],
  sourceFilePath: in String,
  gens: in GeneratorSet,
): Result[PreprocessOutput, String] {
  val pkgName = extractPackageName(source)
  val directives = scanDirectives(source, pkgName)
  val warnings: List[String] = newList()
  val errors: List[String] = newList()

  // X0006: a generator package is run, never imported.
  for (name, line) in importedPackages(source) {
    if gens.dlls.containsKey(name) or gens.failures.containsKey(name) {
      errors.add(
        generatorDiag(
          sourceFilePath,
          "error",
          "X0006",
          line,
          1,
          "'" + name + "' is a source generator and cannot be imported; use it as @generate(" + name + ") on a type"
        )
      )
    }
  }

  if directives.count == 0 {
    if errors.count > 0 {
      return Err(error = Str.joinList("\n", errors))
    }
    return Ok(value = PreprocessOutput(source = source, warnings = warnings))
  }

  val mf = match consumerMf {
    case Some(m) -> m
    case None -> {
      val d = directives[0]
      errors.add(
        generatorDiag(
          sourceFilePath,
          "error",
          "X0008",
          d.line,
          d.column,
          "@generate(" + d.generatorArg +
            ") needs a lyric.toml that declares the generator in [dependencies]; none was found for this file"
        )
      )
      return Err(error = Str.joinList("\n", errors))
    }
  }

  var augmented = source
  val extraImports: List[String] = newList()
  for dir in directives {
    val here = "@generate(" + dir.generatorArg + ")"
    if dir.typeName == "" {
      errors.add(
        generatorDiag(
          sourceFilePath,
          "error",
          "X0001",
          dir.line,
          dir.column,
          here + " must annotate a record, exposed record, union or interface"
        )
      )
      continue
    }
    match checkGeneratorDeclaredIn(mf, dir.generatorArg) {
      case Err(e) -> {
        errors.add(generatorDiag(sourceFilePath, "error", "X0008", dir.line, dir.column, Str.substring(e, 7, e.length - 7)))
        continue
      }
      case Ok(_) -> ()
    }
    val dllPath = match mapGet(gens.dlls, dir.generatorArg) {
      case Some(p) -> p
      case None -> {
        match mapGet(gens.failures, dir.generatorArg) {
          case Some(f) -> errors.add(generatorDiag(sourceFilePath, "error", f.code, dir.line, dir.column, f.message))
          case None -> match mapGet(gens.libraries, dir.generatorArg) {
            case Some(kind) -> {
              val m = notAGeneratorMessage(dir.generatorArg, kind, dir.generatorArg + "'s lyric.toml")
              errors.add(generatorDiag(sourceFilePath, "error", "X0002", dir.line, dir.column, Str.substring(m, 7, m.length - 7)))
            }
            case None -> errors.add(
              generatorDiag(
                sourceFilePath,
                "error",
                "X0009",
                dir.line,
                dir.column,
                here +
                  " cannot be run: a generator must be a path = \"...\" or workspace = true dependency, which the compiler builds; a registry or git generator is not supported"
              )
            )
          }
        }
        continue
      }
    }

    val captured = ProcessCapture.runCaptureWithDiagnosticsTimeout(
      "dotnet",
      buildCaptureArgs(dllPath),
      buildRequestJson(dir, sourceFilePath),
      generatorTimeoutMs
    )
    val result = match parseResponseJson(captured.stdout, captured.stderr, captured.exitCode, captured.timedOut) {
      case Ok(r) -> r
      case Err(why) -> {
        errors.add(
          generatorDiag(
            sourceFilePath,
            "error",
            "X0009",
            dir.line,
            dir.column,
            "generator '" + dir.generatorArg + "' failed for " + dir.typeName + ": " + why
          )
        )
        continue
      }
    }
    var reportedError = false
    for d in result.diagnostics {
      val codeText = if d.code != "" { " [" + d.code + "]" } else { "" }
      val text = "generator '" + dir.generatorArg + "' on " + dir.typeName + codeText + ": " + d.message
      if d.severity == "Error" {
        reportedError = true
        errors.add(generatorDiag(sourceFilePath, "error", "X0005", dir.line, dir.column, text))
      } else {
        val sev = if d.severity == "Warning" { "warning" } else { "note" }
        warnings.add(generatorDiag(sourceFilePath, sev, "X0005", dir.line, dir.column, text))
      }
    }
    if reportedError {
      continue
    }
    if result.lyricSource != "" {
      val parseErrors = fragmentParseErrors(pkgName, result.imports, result.lyricSource)
      if parseErrors != "" {
        errors.add(
          generatorDiag(
            sourceFilePath,
            "error",
            "X0004",
            dir.line,
            dir.column,
            "generator '" + dir.generatorArg + "' produced code for " + dir.typeName + " that does not parse: " + parseErrors
          )
        )
        continue
      }
      augmented = augmented + "\n// @generate(" + dir.generatorArg + ") generated for " + dir.typeName + "\n" +
        result.lyricSource
    }
    for imp in result.imports {
      if not extraImports.contains(imp) {
        extraImports.add(imp)
      }
    }
  }

  if errors.count > 0 {
    return Err(error = Str.joinList("\n", errors))
  }
  Ok(value = PreprocessOutput(source = insertImports(augmented, pkgName, extraImports), warnings = warnings))
}

// `source` with `imports` placed after its `package` line.
func insertImports(source: in String, pkgName: in String, imports: in List[String]): String {
  if imports.count == 0 {
    return source
  }
  var importText = ""
  for imp in imports {
    importText = importText + imp + "\n"
  }
  val pkgLine = "package " + pkgName
  var i = 0
  while i < source.length {
    if matchAt(source, i, pkgLine) {
      var lineEnd = i + pkgLine.length
      while lineEnd < source.length and Str.charAtOrReplacement(source, lineEnd) != '\n' {
        lineEnd += 1
      }
      if lineEnd < source.length {
        lineEnd += 1
      }
      return source.substring(0, lineEnd) + importText + source.substring(lineEnd, source.length - lineEnd)
    }
    i += 1
  }
  source
}
