// lsp.l — self-hosted LSP server for Lyric.
//
// Replaces compiler/src/Lyric.Lsp/Server.fs + JsonRpc.fs.
// Implements the Language Server Protocol 3.17 subset consumed by
// the Lyric VS Code extension: hover, completion, definition,
// signatureHelp, codeAction, rename, and document/workspace sync.
//
// Architecture
// ─────────────
// `lspInit()` returns an LspState whose mutable BCL-Dictionary fields
// carry per-session document and workspace state.  `lspHandle(state,json)`
// processes one JSON-RPC message and returns a list of outbound JSON
// strings.  `lspRunLoop()` drives the stdin→dispatch→stdout loop.
//
// Known limitation: Content-Length is measured in UTF-8 bytes but
// Console.Read() returns UTF-16 code units.  For the ASCII-heavy JSON
// that normal LSP traffic contains the counts are identical; high-Unicode
// source names would cause a short read on the message body.  A proper
// binary reader would require a new kernel extern.

package Lyric.Lsp

import Std.Core
import Std.Collections
import Std.Json
import Std.Char
import Std.Parse
import Std.ConsoleHost
import Std.FileHost
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.ModeChecker
import Lyric.Verifier

// ─────────────────────────────────────────────────────────────────────────────
// §1. State types.
// ─────────────────────────────────────────────────────────────────────────────

pub record CachedDoc {
  source:      String
  checkResult: CheckResult
  proofSummary: Option[ProofSummary]
}

// wsRoot / exitFlag are single-element Lists used as mutable boxes because
// Lyric records do not support `var` fields — a List<T> element serves the
// same purpose with in-place mutation.
pub record LspState {
  store:   Map[String, CachedDoc]
  wsRoot:  List[String]           // box[String]
  wsIndex: Map[String, String]    // pkgName → absPath
  wsKeys:  List[String]           // ordered mirror of wsIndex keys, for clearing
  revDeps: Map[String, List[String]] // importedURI → [consumerURI]
  exit:    List[Bool]             // box[Bool], true after "exit"
}

pub func lspInit(): LspState {
  val wsRoot: List[String] = newList()
  wsRoot.add("")
  val exit: List[Bool] = newList()
  exit.add(false)
  LspState(
    store   = newMap(),
    wsRoot  = wsRoot,
    wsIndex = newMap(),
    wsKeys  = newList(),
    revDeps = newMap(),
    exit    = exit)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. JSON-RPC framing.
// ─────────────────────────────────────────────────────────────────────────────

func readLspFrame(): Option[String] {
  var contentLength = -1
  var headerDone    = false
  var eof           = false
  while not headerDone and not eof {
    var line = ""
    var lineDone = false
    while not lineDone and not eof {
      val c = hostConsoleRead()       // System.Console.Read() — UTF-16 code unit or -1
      if c < 0       { eof = true }
      else if c == 10 { lineDone = true }   // LF
      else if c == 13 { }                   // CR — skip
      else { line = line + ("" + fromInt(c)) }  // fromInt: Std.Char → Char; "" + Char → String
    }
    if eof { }
    else if line.length == 0 { headerDone = true }
    else {
      val colon = line.indexOf(":")    // BCL String.IndexOf → Int
      if colon > 0 {
        val key   = line.substring(0, colon).trim()    // BCL Substring / Trim
        val value = line.substring(colon + 1).trim()
        if key.toLower() == "content-length" {
          match parseOptInt(value) {
            case None    -> {}
            case Some(n) -> { contentLength = n }
          }
        }
      }
    }
  }
  if eof or contentLength < 0 { return None }
  var body = ""
  var rem  = contentLength
  while rem > 0 {
    val c = hostConsoleRead()
    if c < 0 { return Some(value = body) }
    body = body + ("" + fromInt(c))
    rem  = rem - 1
  }
  Some(value = body)
}

func writeLspFrame(json: in String): Unit {
  val header = "Content-Length: " + ("" + json.length) + "\r\n\r\n"
  hostConsoleWrite(header + json)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. JSON building helpers.
// ─────────────────────────────────────────────────────────────────────────────

func jStr(s: in String): String { encodeString(s) }
func jInt(n: in Int): String { "" + n }
func jBool(b: in Bool): String { if b { "true" } else { "false" } }

func jPair(key: in String, v: in String): String {
  encodeString(key) + ":" + v
}

func jJoin(items: in List[String]): String {
  var r = ""
  var i = 0
  while i < items.count {
    if i > 0 { r = r + "," }
    r = r + items[i]
    i = i + 1
  }
  r
}

func jObj(fs: in List[String]): String { "{" + jJoin(fs) + "}" }
func jArr(es: in List[String]): String { "[" + jJoin(es) + "]" }

// ─────────────────────────────────────────────────────────────────────────────
// §4. JSON-RPC message builders.
// ─────────────────────────────────────────────────────────────────────────────

func mkResponse(id: in String, result: in String): String {
  val fs: List[String] = newList()
  fs.add(jPair("jsonrpc", jStr("2.0")))
  fs.add(jPair("id", id))
  fs.add(jPair("result", result))
  jObj(fs)
}

func mkErrorResponse(id: in String, code: in Int, message: in String): String {
  val ef: List[String] = newList()
  ef.add(jPair("code", jInt(code)))
  ef.add(jPair("message", jStr(message)))
  val fs: List[String] = newList()
  fs.add(jPair("jsonrpc", jStr("2.0")))
  fs.add(jPair("id", id))
  fs.add(jPair("error", jObj(ef)))
  jObj(fs)
}

func mkNotif(method: in String, params: in String): String {
  val fs: List[String] = newList()
  fs.add(jPair("jsonrpc", jStr("2.0")))
  fs.add(jPair("method", jStr(method)))
  fs.add(jPair("params", params))
  jObj(fs)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. JSON extraction helpers.
// ─────────────────────────────────────────────────────────────────────────────

func jRootStr(json: in String, field: in String): String {
  val doc  = parseJson(json)
  val root = rootElement(doc)
  match tryGetProperty(root, field) {
    case None    -> ""
    case Some(e) -> getString(e)
  }
}

func jRootInt(json: in String, field: in String): Int {
  val doc  = parseJson(json)
  val root = rootElement(doc)
  match tryGetProperty(root, field) {
    case None    -> 0
    case Some(e) -> match tryGetInt(e) { case None -> 0 case Some(n) -> n }
  }
}

func jRaw(json: in String, field: in String): String {
  val doc  = parseJson(json)
  val root = rootElement(doc)
  match tryGetProperty(root, field) {
    case None    -> "null"
    case Some(e) -> getRawText(e)
  }
}

func jNested2Str(doc: in JsonDoc, p1: in String, p2: in String): String {
  val root = rootElement(doc)
  match tryGetProperty(root, p1) {
    case None    -> ""
    case Some(e1) -> match tryGetProperty(e1, p2) {
      case None    -> ""
      case Some(e2) -> getString(e2)
    }
  }
}

func jNested2Int(doc: in JsonDoc, p1: in String, p2: in String): Int {
  val root = rootElement(doc)
  match tryGetProperty(root, p1) {
    case None    -> 0
    case Some(e1) -> match tryGetProperty(e1, p2) {
      case None    -> 0
      case Some(e2) -> match tryGetInt(e2) { case None -> 0 case Some(n) -> n }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. LSP position/range/diagnostic serialisation.
// ─────────────────────────────────────────────────────────────────────────────

func toLspPos(p: in Position): String {
  val fs: List[String] = newList()
  fs.add(jPair("line",      jInt(p.line - 1)))
  fs.add(jPair("character", jInt(p.column - 1)))
  jObj(fs)
}

func toLspRange(s: in Span): String {
  val fs: List[String] = newList()
  fs.add(jPair("start", toLspPos(s.startPos)))
  fs.add(jPair("end",   toLspPos(s.endPos)))
  jObj(fs)
}

func toLspDiag(d: in Diagnostic): String {
  val sev = match d.severity { case DiagError -> 1 case DiagWarning -> 2 }
  val fs: List[String] = newList()
  fs.add(jPair("range",    toLspRange(d.span)))
  fs.add(jPair("severity", jInt(sev)))
  fs.add(jPair("code",     jStr(d.code)))
  fs.add(jPair("source",   jStr("lyric")))
  fs.add(jPair("message",  jStr(d.message)))
  jObj(fs)
}

func pushDiagnostics(uri: in String, diags: in List[Diagnostic]): String {
  val arr: List[String] = newList()
  var i = 0
  while i < diags.count { arr.add(toLspDiag(diags[i])); i = i + 1 }
  val fs: List[String] = newList()
  fs.add(jPair("uri",         jStr(uri)))
  fs.add(jPair("diagnostics", jArr(arr)))
  mkNotif("textDocument/publishDiagnostics", jObj(fs))
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. File-system helpers.
// ─────────────────────────────────────────────────────────────────────────────

func uriToPath(uri: in String): String {
  if uri.startsWith("file:///") { uri.substring(7) }
  else if uri.startsWith("file://") { uri.substring(7) }
  else { uri }
}

func pathToUri(path: in String): String {
  if path.startsWith("/") { "file://" + path }
  else { "file:///" + path }
}

func enumLyricFilesRec(dir: in String, acc: in List[String]): Unit {
  if not hostDirectoryExists(dir) { return }
  val fs = hostEnumerateFiles(dir)
  for f in fs { if f.endsWith(".l") { acc.add(f) } }
  val ds = hostEnumerateDirectories(dir)
  for d in ds { enumLyricFilesRec(d, acc) }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Workspace index management.
// ─────────────────────────────────────────────────────────────────────────────

func wsIndexClear(state: in LspState): Unit {
  var i = 0
  while i < state.wsKeys.count {
    state.wsIndex.remove(state.wsKeys[i])
    i = i + 1
  }
  state.wsKeys.clear()   // BCL List.Clear()
}

func wsIndexSet(state: in LspState, pkgName: in String, filePath: in String): Unit {
  if not state.wsIndex.containsKey(pkgName) {
    state.wsKeys.add(pkgName)
  }
  // Dictionary.Remove is safe on absent keys (returns false; does not throw).
  // Calling it unconditionally keeps the bool return as a standalone statement
  // so the emitter's pop is correctly generated (avoids if-branch stack imbalance).
  state.wsIndex.remove(pkgName)
  state.wsIndex.add(pkgName, filePath)
}

func rebuildWsIndex(state: in LspState): Unit {
  val root = state.wsRoot[0]
  if root.length == 0 { return }
  wsIndexClear(state)
  val files: List[String] = newList()
  enumLyricFilesRec(root, files)
  var i = 0
  while i < files.count {
    val fp = files[i]
    if hostFileExists(fp) {
      val text   = hostReadAllText(fp)
      val parsed     = parse(text)
      val parsedFile = parsed.file
      val pkgDecl    = parsedFile.packageDecl
      val pkgPath    = pkgDecl.path
      val segs       = pkgPath.segments
      var pkg    = ""
      var si = 0
      while si < segs.count {
        if si > 0 { pkg = pkg + "." }
        pkg = pkg + segs[si]
        si = si + 1
      }
      if pkg.length > 0 { wsIndexSet(state, pkg, fp) }
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Document analysis.
// ─────────────────────────────────────────────────────────────────────────────

func collectDiags(src: in List[Diagnostic], dst: in List[Diagnostic]): Unit {
  var i = 0
  while i < src.count { dst.add(src[i]); i = i + 1 }
}

func buildImportedItems(state: in LspState, file: in SourceFile): List[Item] {
  val items: List[Item] = newList()
  val fileImports = file.imports
  var i = 0
  while i < fileImports.count {
    val imp     = fileImports[i]
    val impPath = imp.path
    val impSegs = impPath.segments
    var pkg = ""
    var si = 0
    while si < impSegs.count {
      if si > 0 { pkg = pkg + "." }
      pkg = pkg + impSegs[si]
      si = si + 1
    }
    match mapGet(state.wsIndex, pkg) {
      case None    -> {}
      case Some(fp) -> {
        if hostFileExists(fp) {
          val impParsed = parse(hostReadAllText(fp))
          val impFile   = impParsed.file
          val impItems  = impFile.items
          var ki = 0
          while ki < impItems.count {
            items.add(impItems[ki])
            ki = ki + 1
          }
        }
      }
    }
    i = i + 1
  }
  items
}

func addRevDep(state: in LspState, importedUri: in String, consumerUri: in String): Unit {
  match mapGet(state.revDeps, importedUri) {
    case None -> {
      val cs: List[String] = newList()
      cs.add(consumerUri)
      state.revDeps.add(importedUri, cs)
    }
    case Some(cs) -> {
      var found = false
      var i = 0
      while i < cs.count { if cs[i] == consumerUri { found = true }; i = i + 1 }
      if not found { cs.add(consumerUri) }
    }
  }
}

func analyzeAndStore(state: in LspState, uri: in String, text: in String): List[String] {
  val acc: List[String] = newList()
  val parsed        = parse(text)
  val parsedFile    = parsed.file
  val importedItems = buildImportedItems(state, parsedFile)
  val cr            = checkWithImports(parsedFile, importedItems)

  // Update rev-deps: for each import in this file, register uri as a consumer.
  val parsedImports = parsedFile.imports
  var ii = 0
  while ii < parsedImports.count {
    val imp     = parsedImports[ii]
    val impPath = imp.path
    val impSegs = impPath.segments
    var pkg = ""
    var si = 0
    while si < impSegs.count {
      if si > 0 { pkg = pkg + "." }
      pkg = pkg + impSegs[si]
      si = si + 1
    }
    match mapGet(state.wsIndex, pkg) {
      case None    -> {}
      case Some(fp) -> { addRevDep(state, pathToUri(fp), uri) }
    }
    ii = ii + 1
  }

  val allDiags: List[Diagnostic] = newList()
  collectDiags(parsed.diagnostics, allDiags)
  collectDiags(cr.diagnostics,     allDiags)

  // Run verifier (allow-unverified so unknowns become warnings, not errors).
  val proofOpt: Option[ProofSummary] = None  // will overwrite below
  val proofResult = proveSourceWithOptions(text, true)
  var pi = 0
  while pi < proofResult.diagnostics.count {
    val d = proofResult.diagnostics[pi]
    if d.code.startsWith("V") {
      var dup = false
      var di = 0
      while di < allDiags.count {
        if allDiags[di].code == d.code and
           allDiags[di].span.startPos.line == d.span.startPos.line and
           allDiags[di].span.startPos.column == d.span.startPos.column {
          dup = true
        }
        di = di + 1
      }
      if not dup { allDiags.add(d) }
    }
    pi = pi + 1
  }
  val proofSummary = Some(value = proofResult)

  val doc = CachedDoc(source = text, checkResult = cr, proofSummary = proofSummary)
  state.store.remove(uri)   // safe on absent key; avoids if-branch stack imbalance
  state.store.add(uri, doc)
  acc.add(pushDiagnostics(uri, allDiags))
  acc
}

// Helper: re-analyze one consumer URI and append notifications to acc.
// Separate Unit-returning function so mapGet(state.store, ...) generic
// inference is not confused by the List[String] return type of the caller.
func analyzeConsumer(state: in LspState, consumerUri: in String, acc: in List[String]): Unit {
  match mapGet(state.store, consumerUri) {
    case None    -> {}
    case Some(d) -> {
      val msgs = analyzeAndStore(state, consumerUri, d.source)
      collectMsgs(msgs, acc)
    }
  }
}

func reAnalyzeConsumers(state: in LspState, changedUri: in String): List[String] {
  val acc: List[String] = newList()
  // Use containsKey + [] instead of mapGet so the List[String] return type
  // of this function does not spuriously bind mapGet's generic V = String.
  if state.revDeps.containsKey(changedUri) {
    val consumers = state.revDeps[changedUri]
    var i = 0
    while i < consumers.count {
      analyzeConsumer(state, consumers[i], acc)
      i = i + 1
    }
  }
  acc
}

func collectMsgs(src: in List[String], dst: in List[String]): Unit {
  var i = 0
  while i < src.count { dst.add(src[i]); i = i + 1 }
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Identifier/call-context helpers.
// ─────────────────────────────────────────────────────────────────────────────

func isIdChar(c: in Char): Bool {
  isLetterOrDigit(c) or c == '_'     // Std.Char.isLetterOrDigit
}

func identAtLine(line: in String, zeroCol: in Int): Option[String] {
  if zeroCol < 0 or zeroCol > line.length { return None }
  var start = zeroCol
  var scanning = true
  while scanning and start > 0 {
    val c = line[start - 1]          // BCL String indexer → Char
    if isIdChar(c) { start = start - 1 }
    else { scanning = false }
  }
  var stopPos = zeroCol
  var scanning2 = true
  while scanning2 and stopPos < line.length {
    val c = line[stopPos]
    if isIdChar(c) { stopPos = stopPos + 1 }
    else { scanning2 = false }
  }
  if start >= stopPos { return None }
  val ident = line.substring(start, stopPos - start)   // BCL String.Substring(start, length)
  if ident.length == 0 { return None }
  val first = ident[0]
  if isLetter(first) or first == '_' { Some(value = ident) } else { None }
}

func identAtPos(text: in String, oneLine: in Int, oneCol: in Int): Option[String] {
  val lines = text.split("\n")    // BCL String.Split → string[]
  if oneLine < 1 or oneLine > lines.length { return None }
  identAtLine(lines[oneLine - 1], oneCol - 1)
}

// Scan backwards from offset for the function name before the nearest
// un-matched open paren, plus count how many commas at nesting 0 precede
// the offset.  Returns (funcName, paramIndex) or None.
func callContextAt(text: in String, offset: in Int): Option[String] {
  var i     = offset - 1
  var depth = 0
  var found = -1
  var loop  = true
  while loop and i >= 0 {
    val c = text[i]
    if c == ')' or c == ']' { depth = depth + 1 }
    else if c == '(' or c == '[' {
      if depth == 0 { found = i; loop = false }
      else { depth = depth - 1 }
    }
    i = i - 1
  }
  if found < 0 { return None }
  // Trim whitespace to find identifier end.
  var j = found - 1
  while j >= 0 and (text[j] == ' ' or text[j] == '\t') { j = j - 1 }
  val endJ = j + 1
  while j >= 0 and isIdChar(text[j]) { j = j - 1 }
  val funcName = text.substring(j + 1, endJ - (j + 1))
  if funcName.length == 0 { return None }
  if isDigit(funcName[0]) { return None }
  Some(value = funcName)
}

func lineColToOffset(text: in String, line: in Int, col: in Int): Int {
  val lines = text.split("\n")
  var off = 0
  var li  = 0
  while li < line - 1 and li < lines.length {
    off = off + lines[li].length + 1
    li = li + 1
  }
  off + (col - 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Symbol/type rendering.
// ─────────────────────────────────────────────────────────────────────────────

func renderType(cr: in CheckResult, ty: in Type): String {
  match ty {
    case TyPrim(pt)          -> primName(pt)
    case TyTuple(elems)      -> {
      var s = "("
      var i = 0
      while i < elems.count {
        if i > 0 { s = s + ", " }
        s = s + renderType(cr, elems[i])
        i = i + 1
      }
      s + ")"
    }
    case TyNullable(inner)   -> renderType(cr, inner) + "?"
    case TyFunction(ps, ret, isAsync) -> {
      val pref = if isAsync { "async " } else { "" }
      var s = pref + "("
      var i = 0
      while i < ps.count {
        if i > 0 { s = s + ", " }
        s = s + renderType(cr, ps[i])
        i = i + 1
      }
      s + ") -> " + renderType(cr, ret)
    }
    case TyArray(sizeOpt, elem) -> {
      match sizeOpt {
        case None    -> "array[?, " + renderType(cr, elem) + "]"
        case Some(n) -> "array[" + ("" + n) + ", " + renderType(cr, elem) + "]"
      }
    }
    case TySlice(elem)       -> "slice[" + renderType(cr, elem) + "]"
    case TyUser(id, args)    -> {
      // Look up user-defined type name in symbol table.
      var name = "<type>"
      val crSymTable = cr.symbols
      val crSymList  = crSymTable.symbols
      var si = 0
      while si < crSymList.count {
        val sym = crSymList[si]
        match symbolTypeIdOpt(sym) {
          case Some(tid) -> { if tid.id == id.id { name = sym.name } }
          case None      -> {}
        }
        si = si + 1
      }
      if args.count == 0 { name }
      else {
        var s = name + "["
        var i = 0
        while i < args.count {
          if i > 0 { s = s + ", " }
          s = s + renderType(cr, args[i])
          i = i + 1
        }
        s + "]"
      }
    }
    case TySelf  -> "Self"
    case TyVar(n) -> n
    case TyError -> "<error>"
  }
}

func renderMode(m: in ParamMode): String {
  match m { case PMIn -> "in" case PMOut -> "out" case PMInout -> "inout" }
}

func renderSig(cr: in CheckResult, sig: in ResolvedSignature, name: in String): String {
  var s = ""
  if sig.isAsync { s = s + "async " }
  s = s + "func " + name
  if sig.generics.count > 0 {
    s = s + "["
    var i = 0
    while i < sig.generics.count {
      if i > 0 { s = s + ", " }
      s = s + sig.generics[i]
      i = i + 1
    }
    s = s + "]"
  }
  s = s + "("
  var pi = 0
  while pi < sig.params.count {
    if pi > 0 { s = s + ", " }
    val p = sig.params[pi]
    s = s + renderMode(p.mode) + " " + p.name + ": " + renderType(cr, p.ty)
    pi = pi + 1
  }
  s + "): " + renderType(cr, sig.returnTy)
}

func itemSummary(item: in Item): String {
  val v = match item.visibility { case Some(_) -> "pub " case None -> "" }
  match item.kind {
    case IFunc(fd)         -> v + "func " + fd.name + "(...)"
    case IRecord(rd)       -> v + "record " + rd.name
    case IExposedRec(rd)   -> v + "exposed record " + rd.name
    case IUnion(ud)        -> v + "union " + ud.name
    case IEnum(ed)         -> v + "enum " + ed.name
    case IOpaque(od)       -> v + "opaque type " + od.name
    case IInterface(id)    -> v + "interface " + id.name
    case IConst(cd)        -> v + "const " + cd.name
    case ITypeAlias(ta)    -> v + "alias " + ta.name
    case IDistinctType(dt) -> v + "distinct type " + dt.name
    case IExternType(et)   -> "extern type " + et.name
    case _                 -> "(item)"
  }
}

func itemName(item: in Item): Option[String] {
  match item.kind {
    case IFunc(fd)         -> Some(value = fd.name)
    case IRecord(rd)       -> Some(value = rd.name)
    case IExposedRec(rd)   -> Some(value = rd.name)
    case IUnion(ud)        -> Some(value = ud.name)
    case IEnum(ed)         -> Some(value = ed.name)
    case IOpaque(od)       -> Some(value = od.name)
    case IInterface(id)    -> Some(value = id.name)
    case IConst(cd)        -> Some(value = cd.name)
    case ITypeAlias(ta)    -> Some(value = ta.name)
    case IDistinctType(dt) -> Some(value = dt.name)
    case IExternType(et)   -> Some(value = et.name)
    case _                 -> None
  }
}

func symKind(sym: in Symbol): Int {
  match sym.kind {
    case DKFunc(_)           ->  3
    case DKRecord(_,_)       -> 22
    case DKExposedRec(_,_)   -> 22
    case DKUnion(_,_)        ->  7
    case DKEnum(_,_)         -> 13
    case DKOpaque(_,_)       -> 22
    case DKProtected(_,_)    -> 22
    case DKDistinctType(_,_) -> 22
    case DKTypeAlias(_)      ->  7
    case DKInterface(_,_)    ->  8
    case DKConst(_)          -> 21
    case DKVal(_)            ->  6
    case _                   ->  1
  }
}

func symDetail(sym: in Symbol): String {
  val v = match sym.visibility { case Some(_) -> "pub " case None -> "" }
  match sym.kind {
    case DKFunc(_)           -> v + "func " + sym.name + "(...)"
    case DKRecord(_,_)       -> v + "record " + sym.name
    case DKExposedRec(_,_)   -> v + "exposed record " + sym.name
    case DKUnion(_,_)        -> v + "union " + sym.name
    case DKEnum(_,_)         -> v + "enum " + sym.name
    case DKOpaque(_,_)       -> v + "opaque type " + sym.name
    case DKInterface(_,_)    -> v + "interface " + sym.name
    case DKConst(_)          -> v + "const " + sym.name
    case DKTypeAlias(_)      -> v + "alias " + sym.name
    case DKDistinctType(_,_) -> v + "distinct type " + sym.name
    case DKExternType(_,_)   -> "extern type " + sym.name
    case _                   -> sym.name
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §12. Occurrence finder (for rename).
// ─────────────────────────────────────────────────────────────────────────────

func occurrences(text: in String, name: in String): List[Span] {
  val result: List[Span] = newList()
  val lines = text.split("\n")
  var li = 0
  while li < lines.length {
    val line = lines[li]
    var ci = 0
    while ci <= line.length - name.length {
      if line.substring(ci, name.length) == name {
        val before = ci == 0 or not isIdChar(line[ci - 1])
        val after  = ci + name.length >= line.length or not isIdChar(line[ci + name.length])
        if before and after {
          val sp = Span(
            startPos = Position(offset = 0, line = li + 1, column = ci + 1),
            endPos   = Position(offset = 0, line = li + 1, column = ci + name.length + 1))
          result.add(sp)
        }
      }
      ci = ci + 1
    }
    li = li + 1
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §13. Initialize capabilities.
// ─────────────────────────────────────────────────────────────────────────────

func initResult(): String {
  val caps: List[String] = newList()
  val sync: List[String] = newList()
  sync.add(jPair("openClose", jBool(true)))
  sync.add(jPair("change", jInt(1)))
  caps.add(jPair("textDocumentSync", jObj(sync)))
  caps.add(jPair("hoverProvider", jBool(true)))
  val comp: List[String] = newList()
  comp.add(jPair("resolveProvider", jBool(false)))
  val trig: List[String] = newList()
  trig.add(jStr("."))
  comp.add(jPair("triggerCharacters", jArr(trig)))
  caps.add(jPair("completionProvider", jObj(comp)))
  caps.add(jPair("definitionProvider", jBool(true)))
  val sh: List[String] = newList()
  val shTrig: List[String] = newList()
  shTrig.add(jStr("("))
  shTrig.add(jStr(","))
  sh.add(jPair("triggerCharacters", jArr(shTrig)))
  val shRetrig: List[String] = newList()
  shRetrig.add(jStr(","))
  sh.add(jPair("retriggerCharacters", jArr(shRetrig)))
  caps.add(jPair("signatureHelpProvider", jObj(sh)))
  caps.add(jPair("codeActionProvider", jBool(true)))
  caps.add(jPair("renameProvider", jBool(true)))
  val info: List[String] = newList()
  info.add(jPair("name",    jStr("lyric-lsp")))
  info.add(jPair("version", jStr("0.1.0")))
  val r: List[String] = newList()
  r.add(jPair("capabilities", jObj(caps)))
  r.add(jPair("serverInfo",   jObj(info)))
  jObj(r)
}

// ─────────────────────────────────────────────────────────────────────────────
// §14. Handler implementations.
// ─────────────────────────────────────────────────────────────────────────────

func handleInitialize(state: in LspState, id: in String, params: in String): List[String] {
  val acc: List[String] = newList()
  acc.add(mkResponse(id, initResult()))
  // Extract workspace root — rootUri/rootPath are top-level fields of `params`.
  val rootUri  = jRootStr(params, "rootUri")
  val rootPath = jRootStr(params, "rootPath")
  val wsRoot =
    if rootUri.length > 0   { uriToPath(rootUri) }
    else if rootPath.length > 0 { rootPath }
    else { "" }
  state.wsRoot[0] = wsRoot   // mutate the box
  if wsRoot.length > 0 {
    rebuildWsIndex(state)
    // Pre-analyse all workspace files and push their diagnostics.
    val files: List[String] = newList()
    enumLyricFilesRec(wsRoot, files)
    var i = 0
    while i < files.count {
      val fp = files[i]
      if hostFileExists(fp) {
        val msgs = analyzeAndStore(state, pathToUri(fp), hostReadAllText(fp))
        collectMsgs(msgs, acc)
      }
      i = i + 1
    }
  }
  acc
}

func handleDocOpen(state: in LspState, params: in String): List[String] {
  val acc: List[String] = newList()
  val pdoc = parseJson(params)
  val uri  = jNested2Str(pdoc, "textDocument", "uri")
  // 'text' is nested inside 'textDocument'.
  val root = rootElement(pdoc)
  val text = match tryGetProperty(root, "textDocument") {
    case None -> ""
    case Some(td) -> match tryGetProperty(td, "text") {
      case None -> ""
      case Some(e) -> getString(e)
    }
  }
  if uri.length > 0 {
    collectMsgs(analyzeAndStore(state, uri, text), acc)
    collectMsgs(reAnalyzeConsumers(state, uri), acc)
  }
  acc
}

func handleDocChange(state: in LspState, params: in String): List[String] {
  val acc: List[String] = newList()
  val pdoc = parseJson(params)
  val root = rootElement(pdoc)
  val uri = match tryGetProperty(root, "textDocument") {
    case None -> ""
    case Some(td) -> match tryGetProperty(td, "uri") { case None -> "" case Some(e) -> getString(e) }
  }
  var newText = ""
  match tryGetProperty(root, "contentChanges") {
    case None -> {}
    case Some(changesElem) -> {
      var en = enumerateArray(changesElem)
      var more = arrayMoveNext(en)
      while more {
        val ch = arrayCurrent(en)
        match tryGetProperty(ch, "text") {
          case None -> {}
          case Some(te) -> { newText = getString(te) }
        }
        more = arrayMoveNext(en)
      }
    }
  }
  if uri.length > 0 and newText.length > 0 {
    collectMsgs(analyzeAndStore(state, uri, newText), acc)
    collectMsgs(reAnalyzeConsumers(state, uri), acc)
  }
  acc
}

func handleDocClose(state: in LspState, params: in String): List[String] {
  val acc: List[String] = newList()
  val pdoc = parseJson(params)
  val uri  = jNested2Str(pdoc, "textDocument", "uri")
  if uri.length > 0 {
    state.store.remove(uri)
    val empty: List[Diagnostic] = newList()
    acc.add(pushDiagnostics(uri, empty))
  }
  acc
}

func handleHover(state: in LspState, params: in String): String {
  val pdoc    = parseJson(params)
  val uri     = jNested2Str(pdoc, "textDocument", "uri")
  val lineNum = jNested2Int(pdoc, "position", "line")
  val colNum  = jNested2Int(pdoc, "position", "character")
  match mapGet(state.store, uri) {
    case None -> { return "{}" }
    case Some(cached) -> {
      match identAtPos(cached.source, lineNum + 1, colNum + 1) {
        case None      -> { return "{}" }
        case Some(ident) -> {
          val cr = cached.checkResult
          val crFile  = cr.file
          val crItems = crFile.items
          var foundIt: Option[Item] = None
          var i = 0
          while i < crItems.count {
            match itemName(crItems[i]) {
              case Some(n) -> { if n == ident and isNone(foundIt) { foundIt = Some(value = crItems[i]) } }
              case None    -> {}
            }
            i = i + 1
          }
          match foundIt {
            case None    -> { return "{}" }
            case Some(it) -> {
              val body = match it.kind {
                case IFunc(fd) -> {
                  val arityKey = fd.name + "/" + ("" + fd.params.count)
                  val sigOpt = match mapGet(cr.sigs, arityKey) {
                    case None    -> mapGet(cr.sigs, fd.name)
                    case Some(s) -> Some(value = s)
                  }
                  match sigOpt {
                    case None    -> itemSummary(it)
                    case Some(s) -> renderSig(cr, s, fd.name)
                  }
                }
                case _ -> itemSummary(it)
              }
              var fullBody = body
              var di = 0
              while di < it.docComments.count {
                if di == 0 { fullBody = fullBody + "\n\n" }
                fullBody = fullBody + it.docComments[di].text.trim() + "\n"
                di = di + 1
              }
              val fs: List[String] = newList()
              val contents: List[String] = newList()
              contents.add(jPair("kind",  jStr("markdown")))
              contents.add(jPair("value", jStr("```lyric\n" + fullBody + "\n```")))
              fs.add(jPair("contents", jObj(contents)))
              fs.add(jPair("range",    toLspRange(it.span)))
              return jObj(fs)
            }
          }
        }
      }
    }
  }
  "{}"
}

func handleCompletion(state: in LspState, params: in String): String {
  val pdoc = parseJson(params)
  val uri  = jNested2Str(pdoc, "textDocument", "uri")
  match mapGet(state.store, uri) {
    case None -> "[]"
    case Some(cached) -> {
      val items: List[String] = newList()
      val seen: Set[String]   = newSet()
      val cachedCr2  = cached.checkResult
      val symTable2  = cachedCr2.symbols
      val syms       = symTable2.symbols
      var i = 0
      while i < syms.count {
        val s = syms[i]
        if seen.add(s.name) {
          val compItem: List[String] = newList()
          compItem.add(jPair("label",  jStr(s.name)))
          compItem.add(jPair("kind",   jInt(symKind(s))))
          compItem.add(jPair("detail", jStr(symDetail(s))))
          items.add(jObj(compItem))
        }
        i = i + 1
      }
      jArr(items)
    }
  }
}

func handleDefinition(state: in LspState, params: in String): String {
  val pdoc    = parseJson(params)
  val uri     = jNested2Str(pdoc, "textDocument", "uri")
  val lineNum = jNested2Int(pdoc, "position", "line")
  val colNum  = jNested2Int(pdoc, "position", "character")
  match mapGet(state.store, uri) {
    case None -> { return "[]" }
    case Some(cached) -> {
      match identAtPos(cached.source, lineNum + 1, colNum + 1) {
        case None      -> { return "[]" }
        case Some(ident) -> {
          val cr      = cached.checkResult
          val crFile  = cr.file
          val crItems = crFile.items
          var foundSpan: Option[Span]   = None
          var foundUri:  String         = uri
          // Local search first.
          var i = 0
          var localDone = false
          while i < crItems.count and not localDone {
            match itemName(crItems[i]) {
              case Some(n) -> { if n == ident { foundSpan = Some(value = crItems[i].span); localDone = true } }
              case None    -> {}
            }
            i = i + 1
          }
          // Workspace search.
          if isNone(foundSpan) and state.wsRoot[0].length > 0 {
            val files: List[String] = newList()
            enumLyricFilesRec(state.wsRoot[0], files)
            var fi = 0
            var wsDone = false
            while fi < files.count and not wsDone {
              val fp  = files[fi]
              val fUri = pathToUri(fp)
              if fUri != uri and hostFileExists(fp) {
                val impParsed = parse(hostReadAllText(fp))
                val impFile   = impParsed.file
                val impItems  = impFile.items
                var ki = 0
                var fileDone = false
                while ki < impItems.count and not fileDone {
                  match itemName(impItems[ki]) {
                    case Some(n) -> {
                      if n == ident {
                        foundSpan = Some(value = impItems[ki].span)
                        foundUri  = fUri
                        fileDone  = true
                        wsDone    = true
                      }
                    }
                    case None -> {}
                  }
                  ki = ki + 1
                }
              }
              fi = fi + 1
            }
          }
          match foundSpan {
            case None -> { return "[]" }
            case Some(span) -> {
              val fs: List[String] = newList()
              fs.add(jPair("uri",   jStr(foundUri)))
              fs.add(jPair("range", toLspRange(span)))
              return jObj(fs)
            }
          }
        }
      }
    }
  }
  "[]"
}

// Extract the source text covered by a JSON range object
// {"start":{"line":L,"character":C},"end":{"line":L2,"character":C2}}.
// Line/character are 0-based (LSP convention).
func textAtJsonRange(source: in String, rangeJson: in String): String {
  val rdoc      = parseJson(rangeJson)
  val startLine = jNested2Int(rdoc, "start", "line")
  val startChar = jNested2Int(rdoc, "start", "character")
  val endLine   = jNested2Int(rdoc, "end",   "line")
  val endChar   = jNested2Int(rdoc, "end",   "character")
  val lines     = source.split("\n")
  if startLine >= lines.length { return "" }
  if startLine == endLine {
    val line = lines[startLine]
    if startChar >= line.length { return "" }
    val len = endChar - startChar
    if len <= 0 { return "" }
    val safeLen = if startChar + len > line.length { line.length - startChar } else { len }
    line.substring(startChar, safeLen)
  } else {
    var resultStr = lines[startLine].substring(startChar)
    var li = startLine + 1
    while li < endLine and li < lines.length {
      resultStr = resultStr + "\n" + lines[li]
      li = li + 1
    }
    if endLine < lines.length {
      val lastLine = lines[endLine]
      val ec = if endChar > lastLine.length { lastLine.length } else { endChar }
      resultStr = resultStr + "\n" + lastLine.substring(0, ec)
    }
    resultStr
  }
}

// Scan backwards from offset to find the opening paren of the nearest call,
// then count top-level commas between that paren and the cursor.
func callParamIndexAt(text: in String, offset: in Int): Int {
  var i     = offset - 1
  var depth = 0
  var found = -1
  var loop  = true
  while loop and i >= 0 {
    val c = text[i]
    if c == ')' or c == ']' { depth = depth + 1 }
    else if c == '(' or c == '[' {
      if depth == 0 { found = i; loop = false }
      else { depth = depth - 1 }
    }
    i = i - 1
  }
  if found < 0 { return 0 }
  var commas = 0
  var j  = found + 1
  var d2 = 0
  while j < offset {
    val c = text[j]
    if c == '(' or c == '[' { d2 = d2 + 1 }
    else if c == ')' or c == ']' { d2 = d2 - 1 }
    else if c == ',' and d2 == 0 { commas = commas + 1 }
    j = j + 1
  }
  commas
}

func handleSignatureHelp(state: in LspState, params: in String): String {
  val pdoc    = parseJson(params)
  val uri     = jNested2Str(pdoc, "textDocument", "uri")
  val lineNum = jNested2Int(pdoc, "position", "line")
  val colNum  = jNested2Int(pdoc, "position", "character")
  match mapGet(state.store, uri) {
    case None -> "{}"
    case Some(cached) -> {
      val off = lineColToOffset(cached.source, lineNum + 1, colNum + 1)
      match callContextAt(cached.source, off) {
        case None -> "{}"
        case Some(funcName) -> {
          val cr         = cached.checkResult
          val crSymTable = cr.symbols
          val crSymList  = crSymTable.symbols
          var sigOpt: Option[ResolvedSignature] = None
          match mapGet(cr.sigs, funcName) {
            case Some(s) -> { sigOpt = Some(value = s) }
            case None    -> {
              // Try name/N keys via symbol table.
              var si = 0
              var sigFound = false
              while si < crSymList.count and not sigFound {
                val sym = crSymList[si]
                if sym.name == funcName {
                  match sym.kind {
                    case DKFunc(fd) -> {
                      val key = funcName + "/" + ("" + fd.params.count)
                      match mapGet(cr.sigs, key) {
                        case Some(s) -> { sigOpt = Some(value = s); sigFound = true }
                        case None    -> {}
                      }
                    }
                    case _ -> {}
                  }
                }
                si = si + 1
              }
            }
          }
          match sigOpt {
            case None    -> "{}"
            case Some(sg) -> {
              val pArr: List[String] = newList()
              var pi = 0
              while pi < sg.params.count {
                val p = sg.params[pi]
                val lbl = renderMode(p.mode) + " " + p.name + ": " + renderType(cr, p.ty)
                val pm: List[String] = newList()
                pm.add(jPair("label", jStr(lbl)))
                pArr.add(jObj(pm))
                pi = pi + 1
              }
              val sigLabel = renderSig(cr, sg, funcName)
              val sigObj: List[String] = newList()
              sigObj.add(jPair("label",      jStr(sigLabel)))
              sigObj.add(jPair("parameters", jArr(pArr)))
              val sigsArr: List[String] = newList()
              sigsArr.add(jObj(sigObj))
              val activeParam = callParamIndexAt(cached.source, off)
              val r: List[String] = newList()
              r.add(jPair("signatures",     jArr(sigsArr)))
              r.add(jPair("activeSignature", jInt(0)))
              r.add(jPair("activeParameter", jInt(activeParam)))
              jObj(r)
            }
          }
        }
      }
    }
  }
}

func findProofRequiredAnn(anns: in List[Annotation]): Option[Annotation] {
  var i = 0
  while i < anns.count {
    val a    = anns[i]
    val aName = a.name
    val aSegs = aName.segments
    if aSegs.count == 1 and aSegs[0] == "proof_required" {
      return Some(value = a)
    }
    i = i + 1
  }
  None
}

func handleCodeAction(state: in LspState, params: in String): String {
  val pdoc = parseJson(params)
  val root = rootElement(pdoc)
  val uri = match tryGetProperty(root, "textDocument") {
    case None -> ""
    case Some(td) -> match tryGetProperty(td, "uri") { case None -> "" case Some(e) -> getString(e) }
  }
  val actions: List[String] = newList()
  match mapGet(state.store, uri) {
    case None -> {}
    case Some(cached) -> {
      val cachedCr   = cached.checkResult
      val cachedFile = cachedCr.file
      val fileAnns   = cachedFile.fileAnnotations
      match tryGetProperty(root, "context") {
        case None -> {}
        case Some(ctx) -> {
          match tryGetProperty(ctx, "diagnostics") {
            case None -> {}
            case Some(diagsArr) -> {
              var en = enumerateArray(diagsArr)
              var more = arrayMoveNext(en)
              while more {
                val diag     = arrayCurrent(en)
                val diagCode = match tryGetProperty(diag, "code") {
                  case None -> ""
                  case Some(e) -> getString(e)
                }
                val diagRange = match tryGetProperty(diag, "range") {
                  case None -> "{}"
                  case Some(e) -> getRawText(e)
                }
                if diagCode == "V0009" {
                  val original  = textAtJsonRange(cached.source, diagRange)
                  val newTextV9 = if original.length > 0 { "unsafe { " + original + " }" } else { "unsafe { }" }
                  actions.add(mkCodeAction(uri, "Wrap in unsafe { }", diagRange, newTextV9))
                }
                if diagCode == "V0003" {
                  match findProofRequiredAnn(fileAnns) {
                    case None -> {}
                    case Some(ann) -> {
                      val annRange = toLspRange(ann.span)
                      actions.add(mkCodeAction(uri,
                        "Allow unsafe blocks (@proof_required(unsafe_blocks_allowed))",
                        annRange, "@proof_required(unsafe_blocks_allowed)"))
                    }
                  }
                }
                if diagCode == "V0007" or diagCode == "V0008" {
                  match findProofRequiredAnn(fileAnns) {
                    case None -> {}
                    case Some(ann) -> {
                      val annRange = toLspRange(ann.span)
                      actions.add(mkCodeAction(uri, "Downgrade to @runtime_checked", annRange, "@runtime_checked"))
                    }
                  }
                }
                more = arrayMoveNext(en)
              }
            }
          }
        }
      }
    }
  }
  jArr(actions)
}

func mkCodeAction(uri: in String, title: in String, range: in String, newText: in String): String {
  val te: List[String] = newList()
  te.add(jPair("range",   range))
  te.add(jPair("newText", jStr(newText)))
  val edits: List[String] = newList()
  edits.add(jObj(te))
  val changes: List[String] = newList()
  changes.add(encodeString(uri) + ":" + jArr(edits))
  val edit: List[String] = newList()
  edit.add(jPair("changes", jObj(changes)))
  val action: List[String] = newList()
  action.add(jPair("title", jStr(title)))
  action.add(jPair("kind",  jStr("quickfix")))
  action.add(jPair("edit",  jObj(edit)))
  jObj(action)
}

func handleRename(state: in LspState, params: in String): String {
  val pdoc    = parseJson(params)
  val root    = rootElement(pdoc)
  val uri     = jNested2Str(pdoc, "textDocument", "uri")
  val lineNum = jNested2Int(pdoc, "position", "line")
  val colNum  = jNested2Int(pdoc, "position", "character")
  val newName = jRootStr(params, "newName")
  match mapGet(state.store, uri) {
    case None    -> "{}"
    case Some(cached) -> {
      match identAtPos(cached.source, lineNum + 1, colNum + 1) {
        case None      -> "{}"
        case Some(ident) -> {
          // Collect open URIs to rename across: current doc + its consumers.
          val uris: List[String] = newList()
          uris.add(uri)
          match mapGet(state.revDeps, uri) {
            case None    -> {}
            case Some(cs) -> {
              var ci = 0
              while ci < cs.count { uris.add(cs[ci]); ci = ci + 1 }
            }
          }
          val changes: List[String] = newList()
          var ui = 0
          while ui < uris.count {
            val openUri = uris[ui]
            match mapGet(state.store, openUri) {
              case None    -> {}
              case Some(od) -> {
                val spans = occurrences(od.source, ident)
                if spans.count > 0 {
                  val edits: List[String] = newList()
                  var si = 0
                  while si < spans.count {
                    val te: List[String] = newList()
                    te.add(jPair("range",   toLspRange(spans[si])))
                    te.add(jPair("newText", jStr(newName)))
                    edits.add(jObj(te))
                    si = si + 1
                  }
                  changes.add(encodeString(openUri) + ":" + jArr(edits))
                }
              }
            }
            ui = ui + 1
          }
          val edit: List[String] = newList()
          edit.add(jPair("changes", jObj(changes)))
          jObj(edit)
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §15. Main dispatch.
// ─────────────────────────────────────────────────────────────────────────────

pub func lspHandle(state: in LspState, json: in String): List[String] {
  val acc: List[String] = newList()
  val pdoc   = parseJson(json)
  val root   = rootElement(pdoc)
  val method = match tryGetProperty(root, "method") {
    case None -> ""
    case Some(e) -> getString(e)
  }
  val id = jRaw(json, "id")
  val params = jRaw(json, "params")

  if method == "initialize" {
    collectMsgs(handleInitialize(state, id, params), acc)
  } else if method == "initialized" {
    // no-op
  } else if method == "shutdown" {
    acc.add(mkResponse(id, "{}"))
  } else if method == "exit" {
    state.exit[0] = true
  } else if method == "textDocument/didOpen" {
    collectMsgs(handleDocOpen(state, params), acc)
  } else if method == "textDocument/didChange" {
    collectMsgs(handleDocChange(state, params), acc)
  } else if method == "textDocument/didClose" {
    collectMsgs(handleDocClose(state, params), acc)
  } else if method == "workspace/didChangeWatchedFiles" {
    rebuildWsIndex(state)
  } else if method == "textDocument/hover" {
    acc.add(mkResponse(id, handleHover(state, params)))
  } else if method == "textDocument/completion" {
    acc.add(mkResponse(id, handleCompletion(state, params)))
  } else if method == "textDocument/definition" {
    acc.add(mkResponse(id, handleDefinition(state, params)))
  } else if method == "textDocument/signatureHelp" {
    acc.add(mkResponse(id, handleSignatureHelp(state, params)))
  } else if method == "textDocument/codeAction" {
    acc.add(mkResponse(id, handleCodeAction(state, params)))
  } else if method == "textDocument/rename" {
    acc.add(mkResponse(id, handleRename(state, params)))
  } else {
    if id != "null" and id.length > 0 {
      acc.add(mkErrorResponse(id, -32601, "method not found: " + method))
    }
  }

  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §16. Test helper — workspace index snapshot.
// ─────────────────────────────────────────────────────────────────────────────

// Build a workspace index for `dir` and return the pkgName → absPath map.
// Used by the F# test bridge to verify workspace indexing without running the
// full server loop.
pub func lspBuildWorkspaceIndex(dir: in String): Map[String, String] {
  val state = lspInit()
  state.wsRoot[0] = dir
  rebuildWsIndex(state)
  state.wsIndex
}

// ─────────────────────────────────────────────────────────────────────────────
// §17. Run loop.
// ─────────────────────────────────────────────────────────────────────────────

pub func lspRunLoop(): Unit {
  val state     = lspInit()
  var keepGoing = true
  while keepGoing {
    match readLspFrame() {
      case None -> { keepGoing = false }
      case Some(json) -> {
        val responses = lspHandle(state, json)
        var i = 0
        while i < responses.count {
          writeLspFrame(responses[i])
          i = i + 1
        }
        if state.exit[0] { keepGoing = false }
      }
    }
  }
}
