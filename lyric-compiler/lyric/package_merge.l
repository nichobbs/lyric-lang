//! package_merge.l — assemble the files of a multi-file package into one
//! package (docs/19 §4, docs/70 §4.1, #8234).
//!
//! Every file of a package is parsed on its own, as file `i` of the package
//! (`Lyric.Lexer.Position.fileId = i`) at its own offset base
//! (`Lyric.Parser.fileOffsetBases`), so every position names its file and
//! carries that file's own line and column, and no two positions of the
//! package share an offset.  Every file must parse, must declare the package
//! it is a file of (B0013), and contributes exactly its parsed items.  The
//! assembled `SourceFile` holds
//!
//!     the files' `//!` module docs, in file order
//!     the union of the files' file-level annotations, @cfg excepted
//!     the package declaration (the first file's)
//!     the union of the files' imports
//!     file 1's items ... file N's items
//!
//! and `files`, one `FileHeader` per file (its path, its own header and its
//! offset base), so a diagnostic names its file through its position.
//!
//! A file whose file-level `@cfg` is false for the active features
//! contributes no item and no import; the build's target decides its
//! `target = "X"` atoms.
//! The files' other file-level annotations are package-wide, whatever their
//! `@cfg`: they are united, one written by two files is kept once, and two
//! files that disagree are an error (B0014; Y0009 for `@pure` against `@io`).
//! The files share one import scope, so an alias two files bind to different
//! packages is an error (B0012).
//!
//! A malformed file-level `@cfg` is F0012 and one naming a feature the
//! manifest does not declare is F0013, as for the items of a file.
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

/// A package assembled from its separately parsed files (docs/70 §4.1).
/// `file.items` holds every kept file's items in file order, `file.files`
/// one header per source (index = `fileId`), and the package-level header
/// fields the union of the files' (see the module doc).  `diagnostics`
/// holds every file's parse diagnostics and every package mismatch, header
/// conflict and file-level `@cfg` diagnostic; when it holds an error,
/// `file` is not usable.
pub record PackageAssembly {
  file: SourceFile
  diagnostics: List[MergeDiagnostic]
  /// Whether some file spells an `array[` type (D167), scanned once per
  /// file as it is parsed; the build lowers `array[N, T]` only then.
  spellsArray: Bool
}

/// The files of package `packageName` (`sources`, in the package's order,
/// with `paths` naming them, parallel by index; a missing or "" path is
/// unknown), each parsed on its own at its own offset base and joined as one
/// `SourceFile`.  `activeFeatures` and `targetName` (the build's target,
/// `dotnet` / `jvm` / `native`) decide each file's file-level `@cfg`;
/// `declaredFeatures` is the manifest's `[features]`, for F0013 (none: no
/// F0013).  `packageName` "" holds the files to no name: for a package of
/// one file whose name the caller took from the file itself.  A package of
/// several files always has a name (a manifest entry's, or a source tree's
/// package grouping), and its files are held to it.
pub func assemblePackageFiles(
  packageName: in String,
  sources: in List[String],
  paths: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  targetName: in String,
): PackageAssembly {
  val diags: List[MergeDiagnostic] = newList()
  // Per file that declares the package: its path, its package span, and the
  // unit-mode annotations it carries (for the agreement check below).
  val modePaths: List[String] = newList()
  val modeSpans: List[Span] = newList()
  val modeNames: List[String] = newList()
  val annotationPieces: List[HeaderPiece] = newList()
  val importPieces: List[HeaderPiece] = newList()
  val annotations: List[Annotation] = newList()
  val imports: List[ImportDecl] = newList()
  val docs: List[DocComment] = newList()
  val items: List[Item] = newList()
  val headers: List[FileHeader] = newList()
  val bases = fileOffsetBases(sources)
  var packageDecl: Option[PackageDecl] = None
  var spellsArray = false
  var i = 0
  while i < sources.count {
    val path = if i < paths.count { paths[i] } else { "" }
    val text = normaliseLineEndings(sources[i])
    if not spellsArray and Str.contains(text, "array[") {
      spellsArray = true
    }
    val fileBase = bases[i]
    val pr = parseFile(text, i, fileBase)
    var usable = true
    for d in pr.diagnostics {
      diags.add(MergeDiagnostic(path = path, diag = d))
      if d.severity == DiagError {
        usable = false
      }
    }
    // A file whose header does not parse may still name its package: the
    // first `package` declaration among its tokens says which.
    val declaredPkg = if pr.file.packageDecl.path.segments.count > 0 or usable {
      DeclaredPackage(name = modulePathJoin(pr.file.packageDecl.path.segments), span = pr.file.packageDecl.path.span)
    } else {
      lexedPackage(text, i, fileBase)
    }
    if packageName.length > 0 and declaredPkg.name.length > 0 and declaredPkg.name != packageName {
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
      match packageDecl {
        case None -> {
          packageDecl = Some(value = pr.file.packageDecl)
        }
        case Some(_) -> ()
      }
    }
    if usable {
      for d in Cfg.fileCfgDiagnostics(declaredFeatures, pr.file.fileAnnotations) {
        diags.add(MergeDiagnostic(path = path, diag = d))
      }
      // A file's file-level annotations describe the package, so they count
      // whether or not its `@cfg` keeps its items.
      for a in pr.file.fileAnnotations {
        if not isCfg(a) {
          val before = annotationPieces.count
          addAnnotation(
            annotationPieces,
            pieceOf(text, fileBase, annotationName(a), annotationKey(a), "", "", a.span, i, path),
            packageName,
            diags
          )
          if annotationPieces.count > before {
            annotations.add(a)
          }
        }
      }
    }
    if usable and not fileGatedOut(pr.file.fileAnnotations, activeFeatures, targetName) {
      for d in pr.file.imports {
        val aliasName = match d.asAlias { case Some(al) -> al; case None -> "" }
        val aliasTarget = (if d.isExtern { "extern " } else { "" }) + modulePathJoin(d.path.segments)
        val before = importPieces.count
        addImport(importPieces, pieceOf(text, fileBase, "", importKey(d), aliasName, aliasTarget, d.span, i, path), diags)
        if importPieces.count > before {
          imports.add(d)
        }
      }
      for doc in pr.file.moduleDoc {
        docs.add(doc)
      }
      for it in pr.file.items {
        items.add(it)
      }
    }
    headers.add(
      FileHeader(
        path = path,
        moduleDoc = pr.file.moduleDoc,
        fileAnnotations = pr.file.fileAnnotations,
        packageDecl = pr.file.packageDecl,
        imports = pr.file.imports,
        span = pr.file.span,
        offsetBase = fileBase
      )
    )
    i = i + 1
  }
  checkUnitModes(modePaths, modeSpans, modeNames, diags)
  val firstSpan = if headers.count > 0 { headers[0].span } else { noSourceSpan() }
  val decl = match packageDecl {
    case Some(d) -> d
    case None -> {
      val segs: List[String] = newList()
      if packageName.length > 0 {
        for seg in Str.split(packageName, ".") {
          segs.add(seg)
        }
      }
      PackageDecl(path = ModulePath(segments = segs, span = firstSpan), span = firstSpan)
    }
  }
  PackageAssembly(
    file = SourceFile(
      moduleDoc = docs,
      files = headers,
      fileAnnotations = annotations,
      packageDecl = decl,
      imports = imports,
      items = items,
      span = firstSpan
    ),
    diagnostics = diags,
    spellsArray = spellsArray
  )
}

/// The path of each file of `file` (an assembled package, or one file's
/// parse), by file id: the table `Lyric.DiagnosticUtil.diagFormatInFiles`
/// names a diagnostic's file through.
pub func packageFilePaths(file: in SourceFile): List[String] {
  val paths: List[String] = newList()
  for h in file.files {
    paths.add(h.path)
  }
  paths
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

/// The file-level annotations that change how the whole package is parsed
/// or compiled, so every file of a package must agree on each of them
/// (B0014): `@contract_source` (block braces, `Lyric.Parser`), the
/// wrapping-arithmetic marker (`Lyric.Pipeline.wrappingArithMarker`),
/// `@test_module` and `@bench_module` (the package is a test or benchmark
/// module).
pub func unitModeAnnotations(): List[String] {
  val xs: List[String] = newList()
  xs.add(contractSourceAnnotationName())
  xs.add("__lyric_wrapping_arith")
  xs.add("test_module")
  xs.add("bench_module")
  xs
}

/// Whether `a` holds an error: its `file` must then not be compiled.
pub func assemblyHasErrors(a: in PackageAssembly): Bool {
  for d in a.diagnostics {
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
  if label.length > 0 {
    label + ": " + DiagUtil.diagFormat(d.diag)
  } else {
    DiagUtil.diagFormat(d.diag)
  }
}

// A package a file names, and where.
record DeclaredPackage {
  name: String
  span: Span
}

// The path of the first `package` declaration among the tokens of `text`,
// file `fileId` of its package lexed at `offsetBase` ("" when there is
// none), for a file whose parse did not reach it.
func lexedPackage(text: in String, fileId: in Int, offsetBase: in Int): DeclaredPackage {
  val toks = lexFile(text, fileId, offsetBase).tokens
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

// The lexer's own newline normalisation, for the header scan below.
func normaliseNewlines(s: in String): String {
  normaliseLineEndings(s)
}

func isCfg(a: in Annotation): Bool {
  a.name.segments.count == 1 and a.name.segments[0] == "cfg"
}

func annotationName(a: in Annotation): String {
  modulePathJoin(a.name.segments)
}

// A header piece of file `fileIndex`, whose normalised text is `text` and
// whose offsets start at `base`: the piece's text is `text` at the span's
// offsets less `base`.
func pieceOf(
  text: in String,
  base: in Int,
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
    text = text.substring(sp.startPos.offset - base, sp.endPos.offset - sp.startPos.offset),
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

// Add `p` to the package's annotations unless another file wrote an equal
// one.  A file that disagrees with an earlier file is reported; within one
// file the annotations are kept as written and disagreement is left to the
// checks that read the package (V0010, Y0009).
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
    if q.key == p.key and q.fileIndex != p.fileIndex {
      return
    }
  }
  acc.add(p)
}

// Add `p` to the package's imports unless another file wrote an equal one.
// An alias another file binds to a different package is B0012: the files of
// a package share one import scope.
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
    if q.key == p.key and q.fileIndex != p.fileIndex {
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
  val start = Position(offset = 0, line = p.line, column = p.column, fileId = p.fileIndex)
  Span(startPos = start, endPos = start)
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
// Header scan without a parse
// ─────────────────────────────────────────────────────────────────────────────
/// The package a file declares and the imports it writes, read from its header
/// alone: module docs, comments (block comments nest), file-level annotations
/// (their argument strings included), `package` and the `import` / `pub use`
/// declarations after it.  For finding a package's files and its import
/// closure in a whole source tree without parsing every file; assembly
/// parses the files it keeps and holds them to what they declare.  Each
/// import is its text from its keyword to its end.  `packageName` is ""
/// when the header does not reach a `package` declaration.
pub record HeaderScan {
  packageName: String
  imports: List[String]
}

pub func scanHeader(source: in String): HeaderScan {
  val noImports: List[String] = newList()
  val s = normaliseNewlines(source)
  val at = packageAt(s)
  if at.stop < 0 {
    return HeaderScan(packageName = "", imports = noImports)
  }
  val name = at.name
  var pos = at.stop
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

// Where a header's `package` declaration ends: its path, and the offset
// just past it (-1 when the header does not reach one).
record PackageAt {
  name: String
  stop: Int
}

func packageAt(s: in String): PackageAt {
  val none = PackageAt(name = "", stop = -1)
  var pos = 0
  while true {
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
      return PackageAt(name = s.substring(pathStart, pathStop - pathStart), stop = pathStop)
    } else {
      return none
    }
  }
  none
}

/// `source` (newlines normalised) up to the end of its `package`
/// declaration: module docs, comments, file-level annotations and the
/// declaration, without imports or items, found as `scanHeader` finds it.
/// "" when the header does not reach a `package` declaration.
pub func headerThroughPackage(source: in String): String {
  val s = normaliseNewlines(source)
  val at = packageAt(s)
  if at.stop < 0 {
    ""
  } else {
    s.substring(0, at.stop) + "\n"
  }
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
