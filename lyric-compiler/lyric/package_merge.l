//! package_merge.l — merge the files of a multi-file package into one
//! compilation unit (docs/19, #8234).
//!
//! Every backend compiles one source per package, so a package that spans
//! several files is merged first.  The merge works from each file's own
//! parse, never from its text alone: every file must parse on its own, must
//! declare the package it is a file of (B0013), and contributes exactly its
//! parsed items.  The merged unit is
//!
//!     <the union of the files' file-level annotations, @cfg excepted>
//!     package <name>
//!     <the union of the files' imports>
//!     <file 1's items> ... <file N's items>
//!
//! where each file's items are its own text after its header, so they keep
//! their trivia and the lines they had.  The header tokens of each file
//! (module docs, file-level annotations, `package`, imports) are removed
//! token by token from the parse's spans; comments in the header are kept
//! as comments, so a `/* ... */` that hides declarations stays a comment.
//!
//! A file whose file-level `@cfg` is false for the active features
//! contributes no item and no import; the build's target decides its
//! `target = "X"` atoms.
//! The files' other file-level annotations are package-wide, whatever their
//! `@cfg`: they are united, a repeated one is kept once, and two files that
//! disagree are an error (B0014; Y0009 for `@pure` against `@io`).
//!
//! A malformed file-level `@cfg` is F0012 and one naming a feature the
//! manifest does not declare is F0013, as for the items of a file.
//!
//! `mergePackageFiles` also returns, for every line of the merged unit, the
//! file and line it came from, so a diagnostic in the merged unit names the
//! real file (`Lyric.DiagnosticUtil.diagFormatWithOrigin`).
@runtime_checked
package Lyric.PackageMerge

import Std.Core
import Std.Collections
import Std.Char as Char
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser
import Lyric.Cfg as Cfg
import Lyric.DiagnosticUtil as DiagUtil

/// A diagnostic about one file of a package: `path` is the file's path ("" when
/// the caller has none) and `diag`'s span is a position in that file.
pub record MergeDiagnostic {
  path: String
  diag: Diagnostic
}

/// A merged package.  `origins[n - 1]` names the file and line merged line `n`
/// came from (`path = ""` for the synthesised `package` line, and for every
/// line when the caller asked for no origins).  `diagnostics` holds the parse
/// diagnostics of every file that does not parse, and every package mismatch
/// or annotation conflict; when it holds an error, `source` is not usable.
pub record PackageMergeResult {
  source: String
  origins: List[DiagUtil.MergedLineOrigin]
  diagnostics: List[MergeDiagnostic]
}

// A file-level annotation or an import, as written in one file.
record HeaderPiece {
  name: String
  key: String
  /// An import's alias (`import A.B as X`), "" for none and for annotations.
  aliasName: String
  /// What an import's alias names: its path, `extern`-marked.
  aliasTarget: String
  text: String
  fileIndex: Int
  path: String
  line: Int
  column: Int
}

// One file's contribution to the merge: its items' text with one origin per
// line (when origins were asked for).
record FileBody {
  text: String
  origins: List[DiagUtil.MergedLineOrigin]
}

// A half-open range of offsets into a file's text.
record OffsetRange {
  start: Int
  stop: Int
}

/// Merge the files of package `packageName`.  `sources` holds the files' text
/// in the package's order and `paths` their paths, parallel by index (a
/// missing or "" path is unknown).  `activeFeatures` and `targetName` (the
/// build's target, `dotnet` / `jvm` / `native`) decide each file's file-level
/// `@cfg`.  `declaredFeatures` is the manifest's `[features]`, for F0013
/// (none: no F0013).  A package of one file is returned as written: its own
/// parse in the backend reports on it with exact positions.  Its header is
/// still read, so a file that declares another package is B0013 here too.
pub func mergePackageFiles(
  packageName: in String,
  sources: in List[String],
  paths: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  targetName: in String,
): PackageMergeResult {
  val noOrigins: List[DiagUtil.MergedLineOrigin] = newList()
  val diags: List[MergeDiagnostic] = newList()
  if sources.count == 0 {
    return PackageMergeResult(source = "", origins = noOrigins, diagnostics = diags)
  }
  if sources.count == 1 {
    val declared = scanHeader(sources[0]).packageName
    if declared.length > 0 and declared != packageName {
      val path = if paths.count > 0 { paths[0] } else { "" }
      val lexed = lexedPackage(normaliseNewlines(sources[0]))
      diags.add(MergeDiagnostic(path = path, diag = packageMismatch(declared, packageName, lexed.span)))
    }
    return PackageMergeResult(source = sources[0], origins = noOrigins, diagnostics = diags)
  }
  mergeFiles(packageName, sources, paths, activeFeatures, declaredFeatures, targetName, true)
}

/// `mergePackageFiles` for the packages the compiler discovers in its own
/// source trees (the stdlib and the compiler, `Lyric.Emitter`'s per-package
/// builds): a package of one file is rebuilt in the merged shape too, and no
/// origins are computed.
pub func mergeDiscoveredPackage(
  packageName: in String,
  sources: in List[String],
  paths: in List[String],
  targetName: in String,
): PackageMergeResult {
  val noFeatures: List[String] = newList()
  mergeFiles(packageName, sources, paths, noFeatures, noFeatures, targetName, false)
}

func packageMismatch(declared: in String, packageName: in String, sp: in Span): Diagnostic {
  errorDiagnostic(
    "B0013",
    "this file declares package " + declared + ", but it is a file of package " + packageName +
      "; every file of a package declares that package",
    sp
  )
}

// Whether a file's file-level `@cfg` turns it off for the build's features
// and target (`target = "X"` atoms decide against `targetName`).
func fileGatedOut(anns: in List[Annotation], activeFeatures: in List[String], targetName: in String): Bool {
  val noDeclared: List[String] = newList()
  Cfg.isFileCfgGatedOut(Cfg.withTargetFeature(activeFeatures, targetName), noDeclared, anns)
}

/// The file-level annotations that change how the whole merged unit is
/// parsed or compiled, so every file of a package must agree on each of
/// them (B0014): `@contract_source` (block braces, `Lyric.Parser`), the
/// wrapping-arithmetic marker (`Lyric.Pipeline.wrappingArithMarker`),
/// `@test_module` and `@bench_module` (the unit is a test or benchmark
/// module).
pub func unitModeAnnotations(): List[String] {
  val xs: List[String] = newList()
  xs.add(contractSourceAnnotationName())
  xs.add("__lyric_wrapping_arith")
  xs.add("test_module")
  xs.add("bench_module")
  xs
}

/// Whether `r` holds an error: its `source` must then not be compiled.
pub func mergeHasErrors(r: in PackageMergeResult): Bool {
  for d in r.diagnostics {
    if d.diag.severity == DiagError {
      return true
    }
  }
  false
}

/// `d` as `<path>: error[CODE] line:col: message`, the form every backend
/// prints a diagnostic of a file in; `packageLabel` stands in for an unknown
/// path.
pub func mergeDiagnosticText(packageLabel: in String, d: in MergeDiagnostic): String {
  val label = if d.path.length > 0 { d.path } else { packageLabel }
  label + ": " + DiagUtil.diagFormat(d.diag)
}

func mergeFiles(
  packageName: in String,
  sources: in List[String],
  paths: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  targetName: in String,
  withOrigins: Bool,
): PackageMergeResult {
  val diags: List[MergeDiagnostic] = newList()
  // Per file that declares the package: its path, its package span, and the
  // unit-mode annotations it carries (for the agreement check below).
  val modePaths: List[String] = newList()
  val modeSpans: List[Span] = newList()
  val modeNames: List[String] = newList()
  val annotations: List[HeaderPiece] = newList()
  val imports: List[HeaderPiece] = newList()
  var bodies = ""
  val bodyOrigins: List[DiagUtil.MergedLineOrigin] = newList()
  var i = 0
  while i < sources.count {
    val path = if i < paths.count { paths[i] } else { "" }
    val text = normaliseNewlines(sources[i])
    val pr = parse(text)
    var usable = true
    for d in pr.diagnostics {
      if d.severity == DiagError {
        usable = false
      }
    }
    if not usable {
      for d in pr.diagnostics {
        diags.add(MergeDiagnostic(path = path, diag = d))
      }
    }
    // A file whose header does not parse may still name its package: the
    // first `package` declaration among its tokens says which.
    val declaredPkg = if pr.file.packageDecl.path.segments.count > 0 or usable {
      DeclaredPackage(name = modulePathJoin(pr.file.packageDecl.path.segments), span = pr.file.packageDecl.path.span)
    } else {
      lexedPackage(text)
    }
    if declaredPkg.name.length > 0 and declaredPkg.name != packageName {
      usable = false
      diags.add(MergeDiagnostic(path = path, diag = packageMismatch(declaredPkg.name, packageName, declaredPkg.span)))
    }
    // Annotations or imports with no package declaration after them: the
    // parser reports P0020 only when items follow.
    if usable and declaredPkg.name.length == 0 and (pr.file.fileAnnotations.count > 0 or pr.file.imports.count > 0) {
      usable = false
      val at = if pr.file.fileAnnotations.count > 0 { pr.file.fileAnnotations[0].span } else { pr.file.imports[0].span }
      diags.add(
        MergeDiagnostic(
          path = path,
          diag = errorDiagnostic("P0020", "expected 'package' declaration at the head of the file", at)
        )
      )
    }
    if usable and declaredPkg.name.length > 0 {
      var names = ""
      for a in pr.file.fileAnnotations {
        val n = annotationName(a)
        if unitModeAnnotations().contains(n) and not Str.contains(names, "|" + n + "|") {
          names = names + "|" + n + "|"
        }
      }
      modePaths.add(path)
      modeSpans.add(pr.file.packageDecl.span)
      modeNames.add(names)
    }
    if usable {
      for d in Cfg.fileCfgDiagnostics(declaredFeatures, pr.file.fileAnnotations) {
        diags.add(MergeDiagnostic(path = path, diag = d))
      }
    }
    // A file's file-level annotations describe the package, so they count
    // whether or not its `@cfg` keeps its items.
    if usable {
      for a in pr.file.fileAnnotations {
        if not isCfg(a) {
          addAnnotation(
            annotations,
            pieceOf(text, annotationName(a), annotationKey(a), "", "", a.span, i, path),
            packageName,
            diags
          )
        }
      }
    }
    if usable and not fileGatedOut(pr.file.fileAnnotations, activeFeatures, targetName) {
      for d in pr.file.imports {
        val aliasName = match d.asAlias { case Some(al) -> al; case None -> "" }
        val aliasTarget = (if d.isExtern { "extern " } else { "" }) + modulePathJoin(d.path.segments)
        addImport(imports, pieceOf(text, "", importKey(d), aliasName, aliasTarget, d.span, i, path), diags)
      }
      val body = fileBody(text, pr.file, path, withOrigins)
      // A file whose items are empty adds no line of its own unless an earlier
      // file's items precede it: the join below is what makes the line.
      if bodies.length == 0 {
        bodies = body.text
        while bodyOrigins.count > 0 {
          bodyOrigins.removeAt(bodyOrigins.count - 1)
        }
        if body.text.length > 0 {
          appendOrigins(bodyOrigins, body.origins)
        }
      } else {
        bodies = bodies + "\n" + body.text
        if body.origins.count == 0 {
          bodyOrigins.add(DiagUtil.MergedLineOrigin(path = "", originalLine = 0))
        }
        appendOrigins(bodyOrigins, body.origins)
      }
    }
    i = i + 1
  }

  checkUnitModes(modePaths, modeSpans, modeNames, diags)

  val preambleLines: List[String] = newList()
  val origins: List[DiagUtil.MergedLineOrigin] = newList()
  addPieceLines(annotations, true, preambleLines, origins)
  preambleLines.add("package " + packageName)
  origins.add(DiagUtil.MergedLineOrigin(path = "", originalLine = 0))
  val importLines: List[String] = newList()
  addPieceLines(imports, false, importLines, origins)
  if importLines.count == 0 {
    // The empty line `joinList` of no imports leaves before the items.
    origins.add(DiagUtil.MergedLineOrigin(path = "", originalLine = 0))
  }
  val preamble = Str.joinList("\n", preambleLines) + "\n" + Str.joinList("\n", importLines) + "\n"
  appendOrigins(origins, bodyOrigins)
  val noOrigins: List[DiagUtil.MergedLineOrigin] = newList()
  PackageMergeResult(
    source = preamble + bodies,
    origins = if withOrigins { origins } else { noOrigins },
    diagnostics = diags
  )
}

// A package a file names, and where.
record DeclaredPackage {
  name: String
  span: Span
}

// The path of the first `package` declaration among `text`'s tokens ("" when
// there is none), for a file whose parse did not reach it.
func lexedPackage(text: in String): DeclaredPackage {
  val toks = lex(text).tokens
  var i = 0
  while i < toks.count {
    if isKw(toks[i].token, KwPackage) {
      val segs: List[String] = newList()
      var j = i + 1
      var going = true
      while going and j < toks.count {
        match toks[j].token {
          case TIdent(n) -> {
            segs.add(n)
            val nextIsDot = j + 1 < toks.count and isPunct(toks[j + 1].token, Dot)
            j = if nextIsDot { j + 2 } else { j + 1 }
            going = nextIsDot
          }
          case _ -> {
            going = false
          }
        }
      }
      if segs.count > 0 {
        return DeclaredPackage(name = modulePathJoin(segs), span = toks[i + 1].span)
      }
    }
    i = i + 1
  }
  DeclaredPackage(name = "", span = pointSpan(initialPosition()))
}

func appendOrigins(acc: in List[DiagUtil.MergedLineOrigin], more: in List[DiagUtil.MergedLineOrigin]): Unit {
  for o in more {
    acc.add(o)
  }
}

// The lexer's own newline normalisation: every offset in a parse is into the
// normalised text.
func normaliseNewlines(s: in String): String {
  s.replace("\r\n", "\n").replace("\r", "\n")
}

func isCfg(a: in Annotation): Bool {
  a.name.segments.count == 1 and a.name.segments[0] == "cfg"
}

func annotationName(a: in Annotation): String {
  modulePathJoin(a.name.segments)
}

func pieceOf(
  text: in String,
  name: in String,
  key: in String,
  aliasName: in String,
  aliasTarget: in String,
  sp: in Span,
  fileIndex: in Int,
  path: in String,
): HeaderPiece {
  HeaderPiece(
    name = name,
    key = key,
    aliasName = aliasName,
    aliasTarget = aliasTarget,
    text = text.substring(sp.startPos.offset, sp.endPos.offset - sp.startPos.offset),
    fileIndex = fileIndex,
    path = path,
    line = sp.startPos.line,
    column = sp.startPos.column
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// File-level annotations and imports
// ─────────────────────────────────────────────────────────────────────────────
// The two sets of package-level annotations of which a package has at most
// one: its verification level (docs/01 §6.4) and its class (§9.4).
func levelAnnotation(name: in String): Bool {
  name == "runtime_checked" or name == "proof_required" or name == "axiom"
}

func classAnnotation(name: in String): Bool {
  name == "pure" or name == "io"
}

func whereWritten(p: in HeaderPiece): String {
  val file = if p.path.length > 0 { p.path } else { "another file of the package" }
  file + ":" + toString(p.line)
}

// Add `p` to the package's annotations unless an equal one is already there.
// A file that disagrees with an earlier file is reported; disagreement inside
// one file is left to the checks that read the merged unit (V0010, Y0009).
func addAnnotation(
  acc: in List[HeaderPiece], p: in HeaderPiece, packageName: in String, diags: in List[MergeDiagnostic]
): Unit {
  for q in acc {
    if q.fileIndex != p.fileIndex {
      if q.name == p.name and q.key != p.key {
        diags.add(
          MergeDiagnostic(
            path = p.path,
            diag = errorDiagnostic(
              "B0014",
              "file-level annotation " + p.text + " differs from " + q.text + " at " + whereWritten(q) +
                "; the files of a package agree on their file-level annotations",
              spanAt(p)
            )
          )
        )
        return
      }
      if q.name != p.name and levelAnnotation(q.name) and levelAnnotation(p.name) {
        diags.add(
          MergeDiagnostic(
            path = p.path,
            diag = errorDiagnostic(
              "B0014",
              "this file is @" + p.name + ", but " + whereWritten(q) + " is @" + q.name +
                "; the files of a package declare one verification level",
              spanAt(p)
            )
          )
        )
        return
      }
      if q.name != p.name and classAnnotation(q.name) and classAnnotation(p.name) {
        val other = if q.path.length > 0 { q.path } else { "another file of the package" }
        diags.add(
          MergeDiagnostic(
            path = p.path,
            diag = errorDiagnostic(
              "Y0009",
              "package " + packageName + " is @" + p.name + " here but @" + q.name + " in " + other,
              spanAt(p)
            )
          )
        )
        return
      }
    }
    if q.key == p.key {
      return
    }
  }
  acc.add(p)
}

// Add `p` to the package's imports unless an equal one is already there.  An
// alias another file binds to a different package is B0012: the merged unit
// has one scope for both files.
func addImport(acc: in List[HeaderPiece], p: in HeaderPiece, diags: in List[MergeDiagnostic]): Unit {
  for q in acc {
    if p.aliasName.length > 0 and q.aliasName == p.aliasName and q.aliasTarget != p.aliasTarget and q.fileIndex != p.fileIndex {
      diags.add(
        MergeDiagnostic(
          path = p.path,
          diag = errorDiagnostic(
            "B0012",
            "import alias " + p.aliasName + " names " + p.aliasTarget + " here but " + q.aliasTarget + " at " +
              whereWritten(q) +
              "; the files of a package share their imports, so an alias names one package",
            spanAt(p)
          )
        )
      )
      return
    }
    if q.key == p.key {
      return
    }
  }
  acc.add(p)
}

// Every file of a package carries the same unit-mode annotations
// (`unitModeAnnotations`): one that some files carry and others do not would
// change how the others are parsed or compiled.
func checkUnitModes(
  paths: in List[String],
  spans: in List[Span],
  names: in List[String],
  diags: in List[MergeDiagnostic],
): Unit {
  for mode in unitModeAnnotations() {
    val tag = "|" + mode + "|"
    var withIdx = -1
    var i = 0
    while i < names.count {
      if withIdx < 0 and Str.contains(names[i], tag) {
        withIdx = i
      }
      i = i + 1
    }
    if withIdx >= 0 {
      var j = 0
      while j < names.count {
        if not Str.contains(names[j], tag) {
          val other = if paths[withIdx].length > 0 { paths[withIdx] } else { "another file of the package" }
          diags.add(
            MergeDiagnostic(
              path = paths[j],
              diag = errorDiagnostic(
                "B0014",
                "this file is not @" + mode + ", but " + other + " is; @" + mode +
                  " applies to the whole package, so every file of the package carries it or none does",
                spans[j]
              )
            )
          )
        }
        j = j + 1
      }
    }
  }
}

func spanAt(p: in HeaderPiece): Span {
  val start = Position(offset = 0, line = p.line, column = p.column)
  Span(startPos = start, endPos = start)
}

// Lay the pieces out one per line, each at the column it had, so a diagnostic
// on one points at the right column of its file.  Annotations that shared a
// line in their file share one here, as written.
func addPieceLines(
  pieces: in List[HeaderPiece],
  joinSameLine: in Bool,
  lines: in List[String],
  origins: in List[DiagUtil.MergedLineOrigin],
): Unit {
  var cur = ""
  var curFile = -1
  var curLine = 0
  var curPath = ""
  for p in pieces {
    if joinSameLine and curFile == p.fileIndex and curLine == p.line {
      val lastNl = lastNewline(cur)
      val used = cur.length - lastNl - 1
      val pad = p.column - 1 - used
      cur = cur + Str.repeat(" ", if pad > 0 { pad } else { 1 }) + p.text
    } else {
      if curFile >= 0 {
        flushPiece(cur, curPath, curLine, lines, origins)
      }
      cur = Str.repeat(" ", if p.column > 1 { p.column - 1 } else { 0 }) + p.text
      curFile = p.fileIndex
      curLine = p.line
      curPath = p.path
    }
  }
  if curFile >= 0 {
    flushPiece(cur, curPath, curLine, lines, origins)
  }
}

func lastNewline(s: in String): Int {
  Str.lastIndexOfRaw(s, "\n")
}

// A piece written across several lines keeps them, each with its own origin.
func flushPiece(
  text: in String,
  path: in String,
  line: in Int,
  lines: in List[String],
  origins: in List[DiagUtil.MergedLineOrigin],
): Unit {
  val parts = Str.split(text, "\n")
  var j = 0
  while j < parts.length {
    lines.add(parts[j])
    origins.add(DiagUtil.MergedLineOrigin(path = path, originalLine = line + j))
    j = j + 1
  }
}

// An annotation's identity: two annotations with the same key say the same
// thing however they are spaced.
func annotationKey(a: in Annotation): String {
  val name = annotationName(a)
  if a.args.count == 0 {
    return name
  }
  name + "(" + argsKey(a.args) + ")"
}

func argsKey(args: in List[AnnotationArg]): String {
  val parts: List[String] = newList()
  for arg in args {
    parts.add(argKey(arg))
  }
  Str.joinList(", ", parts)
}

func argKey(arg: in AnnotationArg): String {
  match arg {
    case AAName(name, value, _) -> name + " = " + valueKey(value)
    case ABare(name, _) -> name
    case AACall(name, inner, _) -> name + "(" + argsKey(inner) + ")"
    case ALiteral(value, _) -> valueKey(value)
  }
}

func valueKey(v: in AnnotationValue): String {
  match v {
    case AVInt(n, _) -> toString(n)
    case AVString(s, _) -> "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
    case AVBool(b, _) -> if b { "true" } else { "false" }
    case AVIdent(s, _) -> s
  }
}

// An import's identity: what it binds, however it is spaced.
func importKey(d: in ImportDecl): String {
  var k = if d.isPubUse { "pub use " } else { "import " }
  if d.isExtern {
    k = k + "extern "
  }
  k = k + modulePathJoin(d.path.segments)
  match d.selector {
    case Some(sel) -> {
      val items = match sel {
        case ISSingle(item) -> {
          val one: List[ImportItem] = newList()
          one.add(item)
          one
        }
        case ISGroup(group) -> group
      }
      val parts: List[String] = newList()
      for it in items {
        parts.add(match it.asAlias { case Some(al) -> it.name + " as " + al; case None -> it.name })
      }
      k = k + ".{" + Str.joinList(", ", parts) + "}"
    }
    case None -> ()
  }
  match d.asAlias {
    case Some(al) -> k + " as " + al
    case None -> k
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// One file's items
// ─────────────────────────────────────────────────────────────────────────────
// The text of `file`'s items: `text` with its header tokens removed.  A line
// that holds a header token is dropped when nothing but white space and line
// comments is left on it; otherwise (it also holds a piece of a block
// comment, or the start of an item) it is kept with the token blanked to
// spaces, so every comment stays a comment and every item keeps its line and
// column.  Lines with no header token are kept as written; everything after
// the header is kept as one piece.
func fileBody(text: in String, file: in SourceFile, path: in String, withOrigins: in Bool): FileBody {
  val tokens = headerRanges(file)
  var headerEnd = 0
  for r in tokens {
    if r.stop > headerEnd {
      headerEnd = r.stop
    }
  }
  val blocks = blockCommentsBetween(text, tokens, headerEnd)
  val kept: List[String] = newList()
  val origins: List[DiagUtil.MergedLineOrigin] = newList()
  var lineStart = 0
  var lineNo = 1
  var hasRest = true
  while hasRest and lineStart < headerEnd {
    val nl = Str.indexOfFromRaw(text, "\n", lineStart)
    val lineStop = if nl < 0 { text.length } else { nl }
    if overlapsAny(tokens, lineStart, lineStop) {
      val headStop = if lineStop < headerEnd { lineStop } else { headerEnd }
      val tail = if lineStop > headerEnd { text.substring(headerEnd, lineStop - headerEnd) } else { "" }
      if not overlapsAny(blocks, lineStart, headStop) and tailDroppable(tail) {
        ()
      } else {
        kept.add(blankRanges(text, lineStart, headStop, tokens) + tail)
        if withOrigins {
          origins.add(DiagUtil.MergedLineOrigin(path = path, originalLine = lineNo))
        }
      }
    } else {
      kept.add(text.substring(lineStart, lineStop - lineStart))
      if withOrigins {
        origins.add(DiagUtil.MergedLineOrigin(path = path, originalLine = lineNo))
      }
    }
    if nl < 0 {
      hasRest = false
    } else {
      lineStart = nl + 1
      lineNo = lineNo + 1
    }
  }
  if hasRest {
    val rest = text.substring(lineStart, text.length - lineStart)
    kept.add(rest)
    if withOrigins {
      origins.add(DiagUtil.MergedLineOrigin(path = path, originalLine = lineNo))
      var searchFrom = 0
      var more = true
      while more {
        val nlAt = Str.indexOfFromRaw(rest, "\n", searchFrom)
        if nlAt < 0 {
          more = false
        } else {
          lineNo = lineNo + 1
          origins.add(DiagUtil.MergedLineOrigin(path = path, originalLine = lineNo))
          searchFrom = nlAt + 1
        }
      }
    }
  }
  FileBody(text = Str.joinList("\n", kept), origins = origins)
}

// What the rest of the header's last line may hold for the line to be dropped:
// nothing, or a plain line comment (a `///` is the first item's doc comment).
func tailDroppable(tail: in String): Bool {
  val t = Str.trim(tail)
  t.length == 0 or (Str.startsWith(t, "//") and not Str.startsWith(t, "///"))
}

// The offsets every header token of `file` covers, in order: module doc
// comments, file-level annotations, the package declaration and the imports.
func headerRanges(file: in SourceFile): List[OffsetRange] {
  val rs: List[OffsetRange] = newList()
  for d in file.moduleDoc {
    rs.add(rangeOf(d.span))
  }
  for a in file.fileAnnotations {
    rs.add(rangeOf(a.span))
  }
  if file.packageDecl.path.segments.count > 0 {
    rs.add(rangeOf(file.packageDecl.span))
  }
  for d in file.imports {
    rs.add(rangeOf(d.span))
  }
  rs
}

func rangeOf(sp: in Span): OffsetRange {
  OffsetRange(start = sp.startPos.offset, stop = sp.endPos.offset)
}

func overlapsAny(rs: in List[OffsetRange], start: in Int, stop: in Int): Bool {
  for r in rs {
    if r.start < stop and r.stop > start {
      return true
    }
  }
  false
}

// `text[start, stop)` with every offset inside one of `tokens` replaced by a
// space.
func blankRanges(text: in String, start: in Int, stop: in Int, tokens: in List[OffsetRange]): String {
  var blanked = ""
  var pos = start
  for r in tokens {
    if r.stop > pos and r.start < stop {
      val blankFrom = if r.start > pos { r.start } else { pos }
      val blankTo = if r.stop < stop { r.stop } else { stop }
      blanked = blanked + text.substring(pos, blankFrom - pos) + Str.repeat(" ", blankTo - blankFrom)
      pos = blankTo
    }
  }
  blanked + text.substring(pos, stop - pos)
}

// The block comments in the header's trivia: the text between consecutive
// header tokens (and before the first) holds only white space and comments,
// since the parse made every other character part of a token, so a plain scan
// of it finds them.  Block comments nest, as in the lexer.
func blockCommentsBetween(text: in String, tokens: in List[OffsetRange], headerEnd: in Int): List[OffsetRange] {
  val blocks: List[OffsetRange] = newList()
  var gapStart = 0
  for r in tokens {
    scanTrivia(text, gapStart, r.start, blocks)
    if r.stop > gapStart {
      gapStart = r.stop
    }
  }
  if gapStart < headerEnd {
    scanTrivia(text, gapStart, headerEnd, blocks)
  }
  blocks
}

func scanTrivia(text: in String, start: in Int, stop: in Int, blocks: in List[OffsetRange]): Unit {
  var i = start
  while i < stop {
    val two = if i + 1 < stop { text.substring(i, 2) } else { "" }
    if two == "//" {
      val nl = Str.indexOfFromRaw(text, "\n", i)
      i = if nl < 0 or nl > stop { stop } else { nl }
    } else if two == "/*" {
      var depth = 1
      var j = i + 2
      while j < stop and depth > 0 {
        val pair = if j + 1 < stop { text.substring(j, 2) } else { "" }
        if pair == "/*" {
          depth = depth + 1
          j = j + 2
        } else if pair == "*/" {
          depth = depth - 1
          j = j + 2
        } else {
          j = j + 1
        }
      }
      blocks.add(OffsetRange(start = i, stop = j))
      i = j
    } else {
      i = i + 1
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Header scan without a parse
// ─────────────────────────────────────────────────────────────────────────────
/// The package a file declares and the imports it writes, read from its header
/// alone: module docs, comments (block comments nest), file-level annotations
/// (their argument strings included), `package` and the `import` / `pub use`
/// declarations after it.  For finding a package's files and its import
/// closure in a whole source tree without parsing every file; the merge
/// parses the files it keeps and holds them to what they declare.  Each
/// import is its text from its keyword to its end.  `packageName` is ""
/// when the header does not reach a `package` declaration.
pub record HeaderScan {
  packageName: String
  imports: List[String]
}

pub func scanHeader(source: in String): HeaderScan {
  val noImports: List[String] = newList()
  val none = HeaderScan(packageName = "", imports = noImports)
  val s = normaliseNewlines(source)
  var pos = 0
  var name = ""
  while name.length == 0 {
    pos = skipTrivia(s, pos)
    if pos < 0 or pos >= s.length {
      return none
    }
    if s.substring(pos, 1) == "@" {
      pos = skipAnnotation(s, pos)
      if pos < 0 {
        return none
      }
    } else if keywordAt(s, pos, "package") {
      val pathStart = skipBlanks(s, pos + 7)
      val pathStop = pathEnd(s, pathStart)
      if pathStop == pathStart {
        return none
      }
      name = s.substring(pathStart, pathStop - pathStart)
      pos = pathStop
    } else {
      return none
    }
  }
  val imports: List[String] = newList()
  var scanning = true
  while scanning {
    pos = skipTrivia(s, pos)
    if pos < 0 or pos >= s.length {
      scanning = false
    } else if s.substring(pos, 1) == ";" {
      pos = pos + 1
    } else {
      val stop = importEnd(s, pos)
      if stop < 0 {
        scanning = false
      } else {
        imports.add(s.substring(pos, stop - pos))
        pos = stop
      }
    }
  }
  HeaderScan(packageName = name, imports = imports)
}

// Past white space and comments from `pos`; -1 inside an unterminated block
// comment.
func skipTrivia(s: in String, start: in Int): Int {
  var pos = start
  while pos < s.length {
    val c = s.substring(pos, 1)
    val two = if pos + 1 < s.length { s.substring(pos, 2) } else { "" }
    if c == " " or c == "\t" or c == "\n" {
      pos = pos + 1
    } else if two == "//" {
      val nl = Str.indexOfFromRaw(s, "\n", pos)
      pos = if nl < 0 { s.length } else { nl + 1 }
    } else if two == "/*" {
      var depth = 1
      pos = pos + 2
      while depth > 0 {
        if pos + 1 >= s.length {
          return -1
        }
        val pair = s.substring(pos, 2)
        if pair == "/*" {
          depth = depth + 1
          pos = pos + 2
        } else if pair == "*/" {
          depth = depth - 1
          pos = pos + 2
        } else {
          pos = pos + 1
        }
      }
    } else {
      return pos
    }
  }
  pos
}

func skipBlanks(s: in String, start: in Int): Int {
  var pos = start
  while pos < s.length and (s.substring(pos, 1) == " " or s.substring(pos, 1) == "\t") {
    pos = pos + 1
  }
  pos
}

func isIdentAt(s: in String, i: in Int): Bool {
  match Str.charAt(s, i) {
    case Some(c) -> Char.isLetterOrDigit(c) or c == '_'
    case None -> false
  }
}

func keywordAt(s: in String, pos: in Int, kw: in String): Bool {
  pos + kw.length <= s.length and s.substring(pos, kw.length) == kw and not isIdentAt(s, pos + kw.length)
}

// The end of a dotted path starting at `pos` (a `.` that opens a `.{` group is
// not part of it).
func pathEnd(s: in String, start: in Int): Int {
  var pos = start
  var going = true
  while going and pos < s.length {
    if isIdentAt(s, pos) {
      pos = pos + 1
    } else if s.substring(pos, 1) == "." and pos + 1 < s.length and isIdentAt(s, pos + 1) {
      pos = pos + 1
    } else {
      going = false
    }
  }
  pos
}

// Past the annotation at `pos` (`@name`, then a parenthesised argument list,
// strings in it included); -1 when it does not end.
func skipAnnotation(s: in String, at: in Int): Int {
  var pos = pathEnd(s, at + 1)
  val open = skipBlanks(s, pos)
  if open >= s.length or s.substring(open, 1) != "(" {
    return pos
  }
  pos = open
  var depth = 0
  while pos < s.length {
    val c = s.substring(pos, 1)
    if c == "\"" {
      pos = skipString(s, pos)
      if pos < 0 {
        return -1
      }
    } else {
      if c == "(" {
        depth = depth + 1
      } else if c == ")" {
        depth = depth - 1
        if depth == 0 {
          return pos + 1
        }
      }
      pos = pos + 1
    }
  }
  -1
}

// Past the string literal that opens at `pos` (plain or triple-quoted); -1 when
// it does not end.
func skipString(s: in String, at: in Int): Int {
  if at + 3 <= s.length and s.substring(at, 3) == "\"\"\"" {
    val close = Str.indexOfFromRaw(s, "\"\"\"", at + 3)
    return if close < 0 { -1 } else { close + 3 }
  }
  var pos = at + 1
  while pos < s.length {
    val c = s.substring(pos, 1)
    if c == "\\" {
      pos = pos + 2
    } else if c == "\"" {
      return pos + 1
    } else if c == "\n" {
      return -1
    } else {
      pos = pos + 1
    }
  }
  -1
}

// The end of the `import` or `pub use` declaration at `pos`, or -1 when none
// starts there.
func importEnd(s: in String, start: in Int): Int {
  var pos = start
  if keywordAt(s, pos, "import") {
    pos = pos + 6
  } else if keywordAt(s, pos, "pub") {
    val useAt = skipBlanks(s, pos + 3)
    if not keywordAt(s, useAt, "use") {
      return -1
    }
    pos = useAt + 3
  } else {
    return -1
  }
  pos = skipBlanks(s, pos)
  if keywordAt(s, pos, "extern") {
    pos = skipBlanks(s, pos + 6)
  }
  val pathStop = pathEnd(s, pos)
  if pathStop == pos {
    return -1
  }
  pos = pathStop
  if pos + 1 < s.length and s.substring(pos, 2) == ".{" {
    val close = Str.indexOfFromRaw(s, "}", pos)
    if close < 0 {
      return -1
    }
    pos = close + 1
  }
  val afterBlanks = skipBlanks(s, pos)
  if keywordAt(s, afterBlanks, "as") {
    val aliasStart = skipBlanks(s, afterBlanks + 2)
    val aliasStop = pathEnd(s, aliasStart)
    if aliasStop > aliasStart {
      pos = aliasStop
    }
  }
  pos
}
