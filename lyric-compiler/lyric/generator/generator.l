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
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Directives
// ─────────────────────────────────────────────────────────────────────────────
/// A custom `@generate(X.Y)` annotation found in a source file.
/// `requestJson` is the generator request's type descriptor (schema 2),
/// built from the parsed declaration; it is empty when the annotation is not
/// on a record, exposed record, opaque type, union, enum or interface
/// (`typeName` is then empty too, and X0001 is reported).
pub record GenerateDirective {
  generatorArg: String
  typeName: String
  typeKind: String
  packageName: String
  line: Int
  column: Int
  descriptorJson: String
  /// The same-file enum, distinct and alias declarations the annotated
  /// type's source names, as request JSON (schema 2).
  declarationsJson: String = "[]"
}

func charIsIdent(c: in Char): Bool {
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'
}

// Skip spaces and tabs.
func skipWs(src: in String, pos: inout Int): Unit {
  while pos < src.length and (Str.charAtOrReplacement(src, pos) == ' ' or Str.charAtOrReplacement(src, pos) == '\t') {
    pos += 1
  }
}

// Read a dotted identifier (e.g. "Proto.Derive") starting at `pos`.
func readDottedIdent(src: in String, pos: inout Int): String {
  var result = ""
  while pos < src.length and (charIsIdent(Str.charAtOrReplacement(src, pos)) or Str.charAtOrReplacement(src, pos) == '.') {
    result = result + Str.substring(src, pos, 1)
    pos += 1
  }
  result
}

// True when `src` contains `needle` at `pos`.
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

// The source text a span covers.
func spanText(src: in String, sp: in Span): String {
  val start = sp.startPos.offset
  val stop = sp.endPos.offset
  if start < 0 or stop > src.length or stop < start {
    return ""
  }
  Str.substring(src, start, stop - start)
}

// The custom generator an annotation names, when it is `@generate(X.Y)`.
func customGeneratorOf(ann: in Annotation): Option[String] {
  if modulePathJoin(ann.name.segments) != "generate" or ann.args.count != 1 {
    return None
  }
  match ann.args[0] {
    case ABare(name, _) -> if Str.contains(name, ".") { Some(value = name) } else { None }
    case _ -> None
  }
}

/// The custom `@generate(X.Y)` directives in `src`, each with its type
/// descriptor.  Comments and string literals never produce a directive: the
/// file is parsed, not scanned.  A bare built-in name such as
/// `@generate(Json)` is `Lyric.Derives`'s, not a custom generator's.
pub func scanDirectives(src: in String, packageName: in String): List[GenerateDirective] {
  directivesIn(src, packageName, parse(src).file)
}

// The custom directives of `file`, parsed from `src`.
func directivesIn(src: in String, packageName: in String, file: in SourceFile): List[GenerateDirective] {
  val results: List[GenerateDirective] = newList()
  for item in file.items {
    for ann in item.annotations {
      match customGeneratorOf(ann) {
        case None -> ()
        case Some(arg) -> {
          val (typeName, typeKind, descriptor) = describeItem(src, packageName, item)
          results.add(
            GenerateDirective(
              generatorArg = arg,
              typeName = typeName,
              typeKind = typeKind,
              packageName = packageName,
              line = ann.span.startPos.line,
              column = ann.span.startPos.column,
              descriptorJson = descriptor,
              declarationsJson = declarationsFor(src, file, item)
            )
          )
        }
      }
    }
  }
  results
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Type descriptors (generator request schema 2, D151)
// ─────────────────────────────────────────────────────────────────────────────
/// A pair of strings: a type's kind and its type-argument text.
pub record StringPair {
  first: String
  second: String
}

// Classify a type's source text into a FieldTypeKind name and the text of
// its type arguments: `Result[Order, String]` is ("ResultType",
// "Order, String"); `T?` is ("OptionType", "T").
func classifyType(typeText: in String): StringPair {
  if Str.endsWith(typeText, "?") {
    return StringPair(first = "OptionType", second = Str.trim(typeText.substring(0, typeText.length - 1)))
  }
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
// §3. JSON
// ─────────────────────────────────────────────────────────────────────────────
// Escape a string for a JSON string literal (RFC 8259 §7).
func jsonEscape(s: in String): String {
  var buf = ""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    val code = Str.codeUnitAt(s, i)
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
    } else if code < 32 {
      buf = buf + "\\u00" + hexByte(code)
    } else {
      buf = buf + Str.substring(s, i, 1)
    }
    i += 1
  }
  buf
}

func hexByte(n: in Int): String {
  val digits = "0123456789abcdef"
  Str.substring(digits, n / 16, 1) + Str.substring(digits, n % 16, 1)
}

func jsonStr(s: in String): String {
  "\"" + jsonEscape(s) + "\""
}

func jsonArray(items: in List[String]): String {
  var acc = "["
  var i = 0
  while i < items.count {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + items[i]
    i += 1
  }
  acc + "]"
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

func fieldTypeJson(src: in String, ty: in TypeExpr): String {
  val text = spanText(src, ty.span)
  val classified = classifyType(text)
  val args: List[String] = newList()
  if classified.second != "" {
    for a in splitTopLevelTypeArgs(classified.second) {
      args.add(jsonStr(a))
    }
  }
  "{\"kind\":\"" + classified.first + "\",\"name\":" + jsonStr(text) + ",\"typeArgs\":" + jsonArray(args) + "}"
}

// An annotation as {name, args}: each argument as its source text.
func annotationJson(src: in String, ann: in Annotation): String {
  val args: List[String] = newList()
  for arg in ann.args {
    val sp = match arg { case AAName(_, _, s) -> s; case ABare(_, s) -> s; case ALiteral(_, s) -> s }
    args.add(jsonStr(spanText(src, sp)))
  }
  "{\"name\":" + jsonStr(modulePathJoin(ann.name.segments)) + ",\"args\":" + jsonArray(args) + "}"
}

func annotationsJson(src: in String, anns: in List[Annotation]): String {
  val acc: List[String] = newList()
  for a in anns {
    acc.add(annotationJson(src, a))
  }
  jsonArray(acc)
}

func fieldJson(src: in String, f: in FieldDecl, isPublic: in Bool): String {
  val dflt = match f.dflt { case Some(e) -> ",\"default\":" + jsonStr(spanText(src, e.span)); case None -> "" }
  "{\"name\":" + jsonStr(f.name) + ",\"fieldType\":" + fieldTypeJson(src, f.ty) + ",\"isPublic\":" +
    (if isPublic { "true" } else { "false" }) +
    ",\"annotations\":" +
    annotationsJson(src, f.annotations) +
    dflt +
    "}"
}

func invariantJson(src: in String, inv: in InvariantClause): String {
  val msg = match inv.message { case Some(m) -> jsonStr(m); case None -> "null" }
  "{\"source\":" + jsonStr(spanText(src, inv.expr.span)) + ",\"message\":" + msg + ",\"line\":" +
    Str.fromInt(inv.span.startPos.line) +
    ",\"column\":" +
    Str.fromInt(inv.span.startPos.column) +
    "}"
}

func typeParamsJson(generics: in Option[GenericParams]): String {
  val acc: List[String] = newList()
  match generics {
    case Some(gp) -> {
      for p in gp.params {
        match p {
          case GPType(n, _) -> acc.add(jsonStr(n))
          case GPValue(n, _, _) -> acc.add(jsonStr(n))
        }
      }
    }
    case None -> ()
  }
  jsonArray(acc)
}

func isPubField(f: in FieldDecl): Bool {
  match f.visibility {
    case Some(_) -> true
    case None -> false
  }
}

// The type descriptor of `item`: its name, kind label and request JSON.
// `("", "", "")` for an item that is not a type a generator can describe.
func describeItem(src: in String, packageName: in String, item: in Item): (String, String, String) {
  val fields: List[String] = newList()
  val cases: List[String] = newList()
  val invariants: List[String] = newList()
  val anns: List[Annotation] = newList()
  for a in item.annotations {
    anns.add(a)
  }
  var name = ""
  var kind = ""
  var label = ""
  var typeParams = "[]"
  match item.kind {
    case IRecord(d) -> {
      name = d.name
      kind = "Record"
      label = "record"
      typeParams = typeParamsJson(d.generics)
      for m in d.members {
        match m {
          case RMField(f) -> fields.add(fieldJson(src, f, true))
          case RMInvariant(inv) -> invariants.add(invariantJson(src, inv))
          case RMFunc(_) -> ()
        }
      }
    }
    case IExposedRec(d) -> {
      name = d.name
      kind = "ExposedRecord"
      label = "exposed record"
      typeParams = typeParamsJson(d.generics)
      for m in d.members {
        match m {
          case RMField(f) -> fields.add(fieldJson(src, f, true))
          case RMInvariant(inv) -> invariants.add(invariantJson(src, inv))
          case RMFunc(_) -> ()
        }
      }
    }
    case IOpaque(d) -> {
      name = d.name
      kind = "Opaque"
      label = "opaque type"
      typeParams = typeParamsJson(d.generics)
      for a in d.annotations {
        anns.add(a)
      }
      for m in d.members {
        match m {
          case OMField(f) -> fields.add(fieldJson(src, f, isPubField(f)))
          case OMInvariant(inv) -> invariants.add(invariantJson(src, inv))
          case _ -> ()
        }
      }
    }
    case IUnion(d) -> {
      name = d.name
      kind = "Union"
      label = "union"
      typeParams = typeParamsJson(d.generics)
      for c in d.cases {
        val cfields: List[String] = newList()
        for uf in c.fields {
          match uf {
            case UFNamed(n, ty, _) -> cfields.add(
              "{\"name\":" + jsonStr(n) + ",\"fieldType\":" + fieldTypeJson(src, ty) +
                ",\"isPublic\":true,\"annotations\":[]}"
            )
            case UFPos(ty, _) -> cfields.add(
              "{\"name\":\"\",\"fieldType\":" + fieldTypeJson(src, ty) +
                ",\"isPublic\":true,\"annotations\":[]}"
            )
          }
        }
        cases.add(
          "{\"name\":" + jsonStr(c.name) + ",\"annotations\":" + annotationsJson(src, c.annotations) + ",\"fields\":" +
            jsonArray(cfields) +
            "}"
        )
      }
    }
    case IEnum(d) -> {
      name = d.name
      kind = "Enum"
      label = "enum"
      for c in d.cases {
        cases.add(
          "{\"name\":" + jsonStr(c.name) + ",\"annotations\":" + annotationsJson(src, c.annotations) + ",\"fields\":[]}"
        )
      }
    }
    case IInterface(d) -> {
      name = d.name
      kind = "Interface"
      label = "interface"
      typeParams = typeParamsJson(d.generics)
    }
    case _ -> return ("", "", "")
  }
  val descriptor = "{\"kind\":\"" + kind + "\",\"name\":" + jsonStr(name) + ",\"packageName\":" + jsonStr(packageName) +
    ",\"typeParams\":" +
    typeParams +
    ",\"fields\":" +
    jsonArray(fields) +
    ",\"annotations\":" +
    annotationsJson(src, anns) +
    ",\"cases\":" +
    jsonArray(cases) +
    ",\"invariants\":" +
    jsonArray(invariants) +
    "}";
  (name, label, descriptor)
}

// The identifiers in `text`, each once.
func identifiersIn(text: in String): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < text.length {
    val c = Str.charAtOrReplacement(text, i)
    if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' {
      var j = i + 1
      while j < text.length and charIsIdent(Str.charAtOrReplacement(text, j)) {
        j += 1
      }
      val word = text.substring(i, j - i)
      if not acc.contains(word) {
        acc.add(word)
      }
      i = j
    } else {
      i += 1
    }
  }
  acc
}

func optionalTextJson(e: in Option[Expr], src: in String): String {
  match e {
    case Some(x) -> jsonStr(spanText(src, x.span))
    case None -> "null"
  }
}

// A distinct type's range as {min, max, maxInclusive}, each bound as source
// text or null when the range is open on that side.
func rangeJson(src: in String, rb: in RangeBound): String {
  val inclusive = match rb { case RBHalfOpen(_, _, _) -> false; case _ -> true }
  "{\"min\":" + optionalTextJson(rangeLowerExpr(rb), src) + ",\"max\":" + optionalTextJson(rangeUpperExpr(rb), src) +
    ",\"maxInclusive\":" +
    (if inclusive { "true" } else { "false" }) +
    "}"
}

// `item` as a declaration descriptor, when it is an enum, distinct type or
// alias.
func declarationJson(src: in String, item: in Item): Option[String] {
  match item.kind {
    case IEnum(d) -> {
      val cases: List[String] = newList()
      for c in d.cases {
        cases.add(
          "{\"name\":" + jsonStr(c.name) + ",\"annotations\":" + annotationsJson(src, c.annotations) + ",\"fields\":[]}"
        )
      }
      Some(
        value = "{\"name\":" + jsonStr(d.name) + ",\"kind\":\"Enum\",\"underlying\":null,\"range\":null,\"cases\":" +
          jsonArray(cases) +
          "}"
      )
    }
    case IDistinctType(d) -> {
      val range = match d.rangeClause { case Some(rb) -> rangeJson(src, rb); case None -> "null" }
      Some(
        value = "{\"name\":" + jsonStr(d.name) + ",\"kind\":\"Distinct\",\"underlying\":" +
          jsonStr(spanText(src, d.underlying.span)) +
          ",\"range\":" +
          range +
          ",\"cases\":[]}"
      )
    }
    case ITypeAlias(d) -> Some(
      value = "{\"name\":" + jsonStr(d.name) + ",\"kind\":\"Alias\",\"underlying\":" +
        jsonStr(spanText(src, d.rhs.span)) +
        ",\"range\":null,\"cases\":[]}"
    )
    case _ -> None
  }
}

// The name an enum, distinct type or alias declares, or "" for any other
// item.
func declaredName(item: in Item): String {
  match item.kind {
    case IEnum(d) -> d.name
    case IDistinctType(d) -> d.name
    case ITypeAlias(d) -> d.name
    case _ -> ""
  }
}

// The enum, distinct and alias declarations in `file` whose names appear in
// the source of `annotated`, so a generator can tell an enum field's cases or
// a range type's bounds without seeing the rest of the file (D151).
func declarationsFor(src: in String, file: in SourceFile, annotated: in Item): String {
  val names = identifiersIn(spanText(src, annotated.span))
  val acc: List[String] = newList()
  for item in file.items {
    val n = declaredName(item)
    if n != "" and names.contains(n) {
      match declarationJson(src, item) {
        case Some(j) -> acc.add(j)
        case None -> ()
      }
    }
  }
  jsonArray(acc)
}

// The generator request (schema 2) for `dir`.
func buildRequestJson(dir: in GenerateDirective, sourceFile: in String): String {
  "{\"schemaVersion\":\"2\",\"generatorArg\":" + jsonStr(dir.generatorArg) + ",\"packageName\":" +
    jsonStr(dir.packageName) +
    ",\"sourceFile\":" +
    jsonStr(sourceFile) +
    ",\"typeDescriptor\":" +
    dir.descriptorJson +
    ",\"declarations\":" +
    dir.declarationsJson +
    "}"
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
  val pr = parse(header + fragment)
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
/// shape: X0001 (an annotation on something that is not a type a generator
/// can describe), X0002, X0003, X0004 (generated code that does not parse),
/// X0005 (an error the generator reported), X0006 (an `import` of a
/// generator package), X0008 and X0009 (a generator that could not be built
/// or run).
pub func preprocess(
  source: in String,
  consumerMf: in Option[Manifest.Manifest],
  sourceFilePath: in String,
  gens: in GeneratorSet,
): Result[PreprocessOutput, String] {
  // A file without `@generate(` has no directive; it is not parsed here.
  val pr = if Str.contains(source, "@generate(") { Some(value = parse(source)) } else { None }
  val pkgName = match pr { case Some(p) -> modulePathJoin(p.file.packageDecl.path.segments); case None -> "" }
  val pkgEnd = match pr { case Some(p) -> p.file.packageDecl.span.endPos.offset; case None -> 0 }
  val directives = match pr { case Some(p) -> directivesIn(source, pkgName, p.file); case None -> newList() }
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
          here + " must annotate a record, exposed record, opaque type, union, enum or interface"
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
  Ok(value = PreprocessOutput(source = spliceGeneratedImports(augmented, pkgEnd, extraImports), warnings = warnings))
}

// `source` with `imports` appended to its `package` declaration, which ends
// at offset `pkgEnd`, as `; import A; import B`.  Keeping them on that line
// leaves every line of the consumer's own code where it was, so a
// diagnostic in it still names the line the author wrote.
pub func spliceGeneratedImports(source: in String, pkgEnd: in Int, imports: in List[String]): String {
  if imports.count == 0 {
    return source
  }
  var importText = ""
  for imp in imports {
    importText = importText + "; " + imp
  }
  source.substring(0, pkgEnd) + importText + source.substring(pkgEnd, source.length - pkgEnd)
}
