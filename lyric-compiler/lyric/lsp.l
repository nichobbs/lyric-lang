//! lsp.l — self-hosted LSP server for Lyric.
//!
//! Replaces compiler/src/Lyric.Lsp/Server.fs + JsonRpc.fs.
//! Implements the Language Server Protocol 3.17 subset consumed by
//! the Lyric VS Code extension: hover, completion, definition,
//! signatureHelp, codeAction, rename, and document/workspace sync.
//!
//! Architecture
//! ─────────────
//! `lspInit()` returns an LspState whose mutable BCL-Dictionary fields
//! carry per-session document and workspace state.  `lspHandle(state,json)`
//! processes one JSON-RPC message and returns a list of outbound JSON
//! strings.  `lspRunLoop()` drives the stdin→dispatch→stdout loop.
//!
//! Framing (`§2` below) is byte-exact per the LSP base protocol:
//! `Content-Length` is the UTF-8 byte length of the body, not
//! `String.length` (UTF-16 code units) — #7510. `lspEncodeFrame` and
//! `lspScanFrame` are pure functions over `slice[Byte]` with no I/O, driven
//! against real stdin/stdout by `lspReadFrame`/`writeLspFrame` through
//! `Std.Console`'s byte-level `StdinReader`/`writeStdoutBytes` (#7451).
package Lyric.Lsp

import Std.Core
import Std.Collections
import Std.Json
import Std.Char
import Std.Encoding
import Std.Errors
import Std.String as Str
import Std.Parse
import Std.Console
import Std.FileHost
import Std.File as File
import Std.Path as Path
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Pipeline
import Lyric.ModeChecker
import Lyric.Verifier
import Lyric.Discovery as Disc
import Lyric.Cfg as Cfg
import Lyric.Emitter as Emitter
import Lyric.Version as Ver
import Lyric.Fmt
import Msil.MetadataReader as Mdr
import Msil.Bridge as MsilBridge

// ─────────────────────────────────────────────────────────────────────────────
// §1. State types.
// ─────────────────────────────────────────────────────────────────────────────
pub record CachedDoc {
  source: String
  checkResult: CheckResult
  proofSummary: Option[ProofSummary]
  // wsRoot / exitFlag are single-element Lists used as mutable boxes because
  // Lyric records do not support `var` fields — a List<T> element serves the
  // same purpose with in-place mutation.
}

pub record LspState {
  store: Map[String, CachedDoc]
  wsRoot: List[String]
  // box[String]
  wsIndex: Map[String, String]
  // pkgName → absPath
  wsKeys: List[String]
  // ordered mirror of wsIndex keys, for clearing
  revDeps: Map[String, List[String]]
  // importedURI → [consumerURI]
  exit: List[Bool]
  // box[Bool], true after "exit"
  // Lazily-built reference-pack metadata indexes for the "Implement
  // Interface" code action on extern targets.  Both empty until the
  // first request.  Length-1 List[Bool] is used as a one-shot init
  // sentinel (true once `ensureLspMetadataIndex` has run, regardless
  // of whether the reference pack was found).
  ffiTypeIndex: Map[String, String]
  // FQN → assembly simple name
  ffiPathIndex: Map[String, String]
  // assembly simple name → on-disk path
  ffiIndexInit: List[Bool]
  // The standard library's declarations a proof reads (`ImportScope`),
  // read once, on the first proof: empty until then (box[ImportScope]).
  stdlibScope: List[ImportScope]
  // The standard library's packages as a build's type check imports them,
  // read on the first check, then kept (box[List[ImportedPackage]]).
  stdlibPackages: List[List[ImportedPackage]]
  // What a document's builds and proof read from disk, by its path
  // (`lspDocContext`): kept until a watched file changes (#8342).
  docContexts: Map[String, LspDocContext]
  // Whether the client registers watched files on the server's request
  // (`dynamicRegistration`), and whether that request has been sent
  // (box[Bool] each).
  dynamicWatch: List[Bool]
  watchRegistered: List[Bool]
}

// The builds that compile a document and what its proof reads besides the
// document itself, as `lyric prove <file>` finds them: read once per path,
// and again after any watched `.l` or `lyric.toml` file changes
// (`workspace/didChangeWatchedFiles`).
pub record LspDocContext {
  // False when which packages build the file cannot be known (an enclosing
  // `lyric.toml` that cannot be read, a containing package that cannot be
  // listed): `lyric prove` refuses such a file (B0001), and so does the
  // server.
  buildsKnown: Bool
  builds: List[ProveBuildConfig]
  fileSet: Option[Disc.PackageFileSet]
  manifests: List[String]
  // The proof's import scope, read on the first proof (box[ImportScope]).
  imports: List[ImportScope]
  // What on disk the context was read from (`lspDiskSnapshot`): a context
  // whose snapshot no longer matches is read again, whether or not the
  // client reports file changes.
  snapshot: LspDiskSnapshot
}

// The parts of the disk a document's context depends on, cheap to read on
// every analysis: every `lyric.toml` from the document's directory up (its
// path, and its modification time or absence) and the `.l` files of the
// directories its package's files are in (the whole tree under the
// document's directory when no manifest lists it).
pub record LspDiskSnapshot {
  manifests: List[String]
  manifestStats: List[Option[File.FileStat]]
  sources: List[String]
}

pub func lspInit(): LspState {
  val wsRoot: List[String] = newList()
  wsRoot.add("")
  val exit: List[Bool] = newList()
  exit.add(false)
  val ffiInit: List[Bool] = newList()
  ffiInit.add(false)
  LspState(
    store = newMap(),
    wsRoot = wsRoot,
    wsIndex = newMap(),
    wsKeys = newList(),
    revDeps = newMap(),
    exit = exit,
    ffiTypeIndex = newMap(),
    ffiPathIndex = newMap(),
    ffiIndexInit = ffiInit,
    stdlibScope = newList(),
    stdlibPackages = newList(),
    docContexts = newMap(),
    dynamicWatch = newList(),
    watchRegistered = newList()
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. JSON-RPC framing (Content-Length, UTF-8 byte-exact per the LSP base
// protocol — https://microsoft.github.io/language-server-protocol/specification/#headerPart).
// ─────────────────────────────────────────────────────────────────────────────
// Content-Length is defined as the number of UTF-8-encoded BYTES in the
// body, never `String.length` (UTF-16 code units on the managed targets).
// `lspEncodeFrame`/`lspScanFrame` below are pure functions over
// `slice[Byte]` — no stdin/stdout involved — so they are unit-tested
// directly in `lsp_self_test.l`; `lspStdinOpen`/`lspReadFrame`/
// `writeLspFrame` drive them against the process's real stdio through
// `Std.Console`'s byte-level `StdinReader`/`writeStdoutBytes` (#7451).
/// Encode one outbound LSP message: a `Content-Length` header carrying the
/// UTF-8 byte length of `json`, a blank line, then `json` itself as UTF-8
/// bytes. Pure — no I/O.
pub func lspEncodeFrame(json: in String): slice[Byte] {
  val bodyBytes = encodeUtf8(json)
  val header = "Content-Length: " + ("" + bodyBytes.length) + "\r\n\r\n"
  encodeUtf8(header).concat(bodyBytes)
}

/// Outcome of scanning a byte buffer for the next complete LSP frame.
pub union LspFrameScan {
  // Not enough bytes buffered yet; read more from the peer.
  case LspScanNeedMore
  // The header block is malformed, or missing/invalid Content-Length.
  case LspScanBadHeader(message: String)
  // A complete frame: `body` is the message's raw UTF-8 bytes; `consumed`
  // is how many bytes of the input buffer (header block + blank line +
  // body) it occupies, so the caller can drop them and keep any bytes
  // buffered past the frame boundary for the next scan.
  case LspScanFrame(body: slice[Byte], consumed: Int)
}

// Guards against unbounded buffering from a peer that never sends the
// blank line terminating the header block.
val lspMaxHeaderBytes: Int = 65536

// Largest accepted message body, the same 16 MiB cap `JsonRpc.Stdio`'s
// `ContentLengthTransport` applies. Checked before any arithmetic on the
// parsed length, so a `Content-Length` near `Int` max is a bad header
// rather than an overflow panic, and a hostile length cannot make the
// reader buffer without bound.
val lspMaxBodyBytes: Int = 16777216

// Index of the first byte of the first "\r\n\r\n" in `buf`, or -1.
func lspFindHeaderEnd(buf: in slice[Byte]): Int {
  var i = 0
  val stop = buf.length - 4
  while i <= stop {
    if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10 {
      return i
    }
    i = i + 1
  }
  0 - 1
}

// The Content-Length value from a decoded header block (its lines joined
// by "\r\n", with the trailing blank line already stripped). Other header
// fields (e.g. an LSP client's optional `Content-Type`) are accepted and
// ignored, per the base protocol.
func lspParseContentLength(headerText: in String): Result[Int, String] {
  val lines = Str.split(headerText, "\r\n")
  var found: Option[Int] = None
  var i = 0
  while i < lines.length {
    val line = lines[i]
    if line.length > 0 {
      val colon = Str.indexOfRaw(line, ":")
      if colon <= 0 {
        return Err(error = "malformed LSP header line: " + line)
      }
      val key = line.substring(0, colon).trim()
      val value = line.substring(colon + 1, line.length - colon - 1).trim()
      if key.toLower() == "content-length" {
        match parseOptInt(value) {
          case None -> return Err(error = "Content-Length header is not an integer: '" + value + "'")
          case Some(n) -> {
            if n < 0 {
              return Err(error = "Content-Length header is negative: '" + value + "'")
            }
            if n > lspMaxBodyBytes {
              return Err(error = "Content-Length " + value + " exceeds the " + ("" + lspMaxBodyBytes) + "-byte message limit")
            }
            found = Some(value = n)
          }
        }
      }
    }
    i = i + 1
  }
  match found {
    case Some(n) -> Ok(value = n)
    case None -> Err(error = "missing Content-Length header")
  }
}

/// Scan `buf` for one complete LSP frame. Pure: no I/O, so this and
/// `lspEncodeFrame` are unit-testable without real stdin/stdout.
pub func lspScanFrame(buf: in slice[Byte]): LspFrameScan {
  val headerEnd = lspFindHeaderEnd(buf)
  if headerEnd < 0 {
    if buf.length > lspMaxHeaderBytes {
      return LspScanBadHeader(
        message = "LSP header block exceeds " + ("" + lspMaxHeaderBytes) + " bytes with no terminating blank line"
      )
    }
    return LspScanNeedMore
  }
  val headerBytes = buf.slice(0, headerEnd)
  match tryDecodeUtf8(headerBytes) {
    case None -> LspScanBadHeader(message = "LSP header block is not valid UTF-8")
    case Some(headerText) -> match lspParseContentLength(headerText) {
      case Err(msg) -> LspScanBadHeader(message = msg)
      case Ok(contentLength) -> {
        val bodyStart = headerEnd + 4
        val need = bodyStart + contentLength
        if buf.length < need {
          LspScanNeedMore
        } else {
          LspScanFrame(body = buf.slice(bodyStart, need), consumed = need)
        }
      }
    }
  }
}

/// Decode a frame body's raw bytes to the JSON text `lspHandle` expects.
/// `None` if the body is not valid UTF-8.
pub func lspDecodeFrameBody(bytes: in slice[Byte]): Option[String] {
  tryDecodeUtf8(bytes)
}

// ── Driving the pure scanner against a byte source ──────────────────────────
/// Outcome of reading one LSP message.
pub union LspReadOutcome {
  case LspReadFrame(json: String)
  case LspReadEof
  case LspReadError(message: String)
}

/// One read: its outcome plus the bytes buffered past the frame it
/// consumed, which belong to the next read and are never dropped.
pub record LspReadStep {
  buf: slice[Byte]
  outcome: LspReadOutcome
}

/// Where `lspReadFrameVia` pulls more bytes from. `read` blocks until at
/// least one byte arrives (`Ok(Some(bytes))`), the input ends (`Ok(None)`),
/// or the read fails (`Err(message)`). An interface rather than a closure
/// parameter, the same seam `JsonRpc.Stdio.ByteSource` uses.
pub interface LspByteSource {
  func read(): Result[Option[slice[Byte]], String]
}

/// Read the next complete LSP message, starting from the bytes already in
/// `buf` and pulling more from `src` as needed. A clean end of input is
/// only valid strictly between frames: input ending mid-frame is a
/// truncated stream and is reported as `LspReadError`, not swallowed. The
/// byte source is a parameter so this state machine is testable without
/// real stdin; `lspReadFrame` binds it to stdin.
pub func lspReadFrameVia(buf: in slice[Byte], src: in LspByteSource): LspReadStep {
  var cur = buf
  while true {
    match lspScanFrame(cur) {
      case LspScanFrame(body, consumed) -> {
        val rest = cur.slice(consumed, cur.length)
        return match lspDecodeFrameBody(body) {
          case Some(json) -> LspReadStep(buf = rest, outcome = LspReadFrame(json = json))
          case None -> LspReadStep(buf = rest, outcome = LspReadError(message = "LSP message body is not valid UTF-8"))
        }
      }
      case LspScanBadHeader(message) -> {
        return LspReadStep(buf = cur, outcome = LspReadError(message = message))
      }
      case LspScanNeedMore -> {
        match src.read() {
          case Err(message) -> return LspReadStep(buf = cur, outcome = LspReadError(message = message))
          case Ok(None) -> {
            if cur.length > 0 {
              return LspReadStep(
                buf = cur,
                outcome = LspReadError(
                  message = "stdin closed with a truncated LSP frame (" + ("" + cur.length) + " bytes buffered)"
                )
              )
            }
            return LspReadStep(buf = cur, outcome = LspReadEof)
          }
          case Ok(Some(bytes)) -> {
            cur = cur.concat(bytes)
          }
        }
      }
    }
  }
  LspReadStep(buf = cur, outcome = LspReadEof)
}

// Real stdin as an `LspByteSource`.
record LspStdinSource {
  reader: StdinReader
}

impl LspByteSource for LspStdinSource {
  func read(): Result[Option[slice[Byte]], String] {
    match readStdin(self.reader) {
      case Err(e) -> Err(error = e.message())
      case Ok(chunk) -> Ok(value = chunk)
    }
  }
}

// Byte-buffered stdin cursor for the run loop: `buf` holds bytes read from
// the peer that have not yet been consumed into a complete frame.
record LspStdin {
  src: LspStdinSource
  var buf: slice[Byte]
}

func lspStdinOpen(): LspStdin {
  val empty: slice[Byte] = []
  LspStdin(src = LspStdinSource(reader = openStdinReader()), buf = empty)
}

// Read the next message from real stdin, advancing `s.buf`.
func lspReadFrame(s: in LspStdin): LspReadOutcome {
  val step = lspReadFrameVia(s.buf, s.src)
  s.buf = step.buf
  step.outcome
}

func writeLspFrame(json: in String): Unit {
  writeStdoutBytes(lspEncodeFrame(json))
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. JSON building helpers.
// ─────────────────────────────────────────────────────────────────────────────
func jStr(s: in String): String {
  encodeString(s)
}

func jInt(n: in Int): String {
  "" + n
}

func jBool(b: in Bool): String {
  if b {
    "true"
  } else {
    "false"
  }
}

func jPair(key: in String, v: in String): String {
  encodeString(key) + ":" + v
}

func jJoin(items: in List[String]): String {
  var r = ""
  var i = 0
  while i < items.count {
    if i > 0 {
      r = r + ","
    }
    r = r + items[i]
    i = i + 1
  }
  r
}

func jObj(fs: in List[String]): String {
  "{" + jJoin(fs) + "}"
}

func jArr(es: in List[String]): String {
  "[" + jJoin(es) + "]"
}

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
  val doc = parseJson(json)
  val root = rootElement(doc)
  match tryGetProperty(root, field) {
    case None -> ""
    case Some(e) -> getString(e)
  }
}

func jRootInt(json: in String, field: in String): Int {
  val doc = parseJson(json)
  val root = rootElement(doc)
  match tryGetProperty(root, field) {
    case None -> 0
    case Some(e) -> match tryGetInt(e) { case None -> 0; case Some(n) -> n }
  }
}

func jRaw(json: in String, field: in String): String {
  val doc = parseJson(json)
  val root = rootElement(doc)
  match tryGetProperty(root, field) {
    case None -> "null"
    case Some(e) -> getRawText(e)
  }
}

func jNested2Str(doc: in JsonDoc, p1: in String, p2: in String): String {
  val root = rootElement(doc)
  match tryGetProperty(root, p1) {
    case None -> ""
    case Some(e1) -> match tryGetProperty(e1, p2) { case None -> ""; case Some(e2) -> getString(e2) }
  }
}

func jNested2Int(doc: in JsonDoc, p1: in String, p2: in String): Int {
  val root = rootElement(doc)
  match tryGetProperty(root, p1) {
    case None -> 0
    case Some(e1) -> match tryGetProperty(e1, p2) {
      case None -> 0
      case Some(e2) -> match tryGetInt(e2) { case None -> 0; case Some(n) -> n }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. LSP position/range/diagnostic serialisation.
// ─────────────────────────────────────────────────────────────────────────────
func toLspPos(p: in Position): String {
  val fs: List[String] = newList()
  fs.add(jPair("line", jInt(p.line - 1)))
  fs.add(jPair("character", jInt(p.column - 1)))
  jObj(fs)
}

func toLspRange(s: in Span): String {
  val fs: List[String] = newList()
  fs.add(jPair("start", toLspPos(s.startPos)))
  fs.add(jPair("end", toLspPos(s.endPos)))
  jObj(fs)
}

func toLspDiag(d: in Diagnostic): String {
  val sev = match d.severity { case DiagError -> 1; case DiagWarning -> 2 }
  val fs: List[String] = newList()
  fs.add(jPair("range", toLspRange(d.span)))
  fs.add(jPair("severity", jInt(sev)))
  fs.add(jPair("code", jStr(d.code)))
  fs.add(jPair("source", jStr("lyric")))
  fs.add(jPair("message", jStr(d.message)))
  jObj(fs)
}

func pushDiagnostics(uri: in String, diags: in List[Diagnostic]): String {
  val arr: List[String] = newList()
  var i = 0
  while i < diags.count {
    arr.add(toLspDiag(diags[i]))
    i = i + 1
  }
  val fs: List[String] = newList()
  fs.add(jPair("uri", jStr(uri)))
  fs.add(jPair("diagnostics", jArr(arr)))
  mkNotif("textDocument/publishDiagnostics", jObj(fs))
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. File-system helpers.
// ─────────────────────────────────────────────────────────────────────────────
func uriToPath(uri: in String): String {
  // `file:///` starts with `file://`, so a single check covers both forms
  // (the two branches previously here produced an identical substring).
  if uri.startsWith("file://") {
    uri.substring(7, uri.length - 7)
  } else {
    uri
  }
}

func pathToUri(path: in String): String {
  if path.startsWith("/") {
    "file://" + path
  } else {
    "file:///" + path
  }
}

func enumLyricFilesRec(dir: in String, acc: in List[String]): Unit {
  if not hostDirectoryExists(dir) {
    return
  }
  val fs = hostEnumerateFiles(dir)
  for f in fs {
    if f.endsWith(".l") {
      acc.add(f)
    }
  }
  val ds = hostEnumerateDirectories(dir)
  for d in ds {
    enumLyricFilesRec(d, acc)
  }
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
  state.wsKeys.clear()
  // BCL List.Clear()
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
  if root.length == 0 {
    return
  }
  wsIndexClear(state)
  val files: List[String] = newList()
  enumLyricFilesRec(root, files)
  var i = 0
  while i < files.count {
    val fp = files[i]
    if hostFileExists(fp) {
      val text = hostReadAllText(fp)
      val parsed = parse(text)
      val parsedFile = parsed.file
      val pkgDecl = parsedFile.packageDecl
      val pkgPath = pkgDecl.path
      val segs = pkgPath.segments
      var pkg = ""
      var si = 0
      while si < segs.count {
        if si > 0 {
          pkg = pkg + "."
        }
        pkg = pkg + segs[si]
        si = si + 1
      }
      if pkg.length > 0 {
        wsIndexSet(state, pkg, fp)
      }
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Document analysis.
// ─────────────────────────────────────────────────────────────────────────────
func collectDiags(src: in List[Diagnostic], dst: in List[Diagnostic]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

// The packages a document is checked against: the standard library, as
// `lyric build` checks against it, and the workspace packages it imports.
func checkImportedPackages(state: in LspState, file: in SourceFile): List[ImportedPackage] {
  if state.stdlibPackages.count == 0 {
    state.stdlibPackages.add(MsilBridge.stdlibImportedPackagesFromSources(Emitter.findStdlibSources()))
  }
  val packages: List[ImportedPackage] = newList()
  for wp in buildImportedWorkspacePackages(state, file) {
    packages.add(wp)
  }
  for sp in state.stdlibPackages[0] {
    packages.add(sp)
  }
  packages
}

// Each workspace package the document imports, parsed from its indexed file
// and named as the build names it, so a qualified reference into it resolves
// in its own package (and one into a package the workspace lacks is reported).
func buildImportedWorkspacePackages(state: in LspState, file: in SourceFile): List[ImportedPackage] {
  val packages: List[ImportedPackage] = newList()
  val seen: List[String] = newList()
  for imp in file.imports {
    val pkg = modulePathJoin(imp.path.segments)
    if not seen.contains(pkg) {
      seen.add(pkg)
      match mapGet(state.wsIndex, pkg) {
        case None -> ()
        case Some(fp) -> {
          if hostFileExists(fp) {
            val impFile = parse(hostReadAllText(fp)).file
            packages.add(
              ImportedPackage(
                name = pkg,
                items = impFile.items,
                imports = collectImportNames(impFile.imports),
                wholeImports = collectWholeImportNames(impFile.imports)
              )
            )
          }
        }
      }
    }
  }
  packages
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
      while i < cs.count {
        if cs[i] == consumerUri {
          found = true
        }
        i = i + 1
      }
      if not found {
        cs.add(consumerUri)
      }
    }
  }
}

func analyzeAndStore(state: in LspState, uri: in String, text: in String): List[String] {
  val acc: List[String] = newList()
  val parsed = parse(text)
  val parsedFile = parsed.file
  // The same rewrites `lyric build` runs before its type check, so the
  // editor reports what the build reports (#7512).  No `@stubbable`
  // synthesis: its stubs need `Std.Testing.Mocking`, which the server does
  // not load, so they would only add unknown-name reports.
  //
  // The check sees what `@cfg` erasure keeps for each build that compiles
  // the document, as `lyric build` and `lyric prove` do, so two
  // `@cfg`-gated declarations of one name are not a duplicate (#8342).
  val docPath = uriToPath(uri)
  val ctx = lspDocContext(state, docPath)
  val checkDiags: List[Diagnostic] = newList()
  var firstCheck: Option[CheckResult] = None
  var firstPrep: Option[CheckReadyFile] = None
  // A file whose builds cannot be known is refused (B0001, below), as
  // `lyric prove` refuses it: its check would be of a build no command
  // makes, so it is not reported (it still runs, for hover and navigation).
  val checkedBuilds: List[ProveBuildConfig] = if ctx.buildsKnown { ctx.builds } else { newList() }
  for b in checkedBuilds {
    val erasedFile = Cfg.applyCfgErasure(Cfg.withTargetFeature(b.activeFeatures, b.targetName), b.declaredFeatures, parsedFile).file
    val bPrep = pipePrepareForCheck(erasedFile, false)
    val bCheck = checkWithImportedPackages(bPrep.file, checkImportedPackages(state, bPrep.file))
    if not isSome(firstCheck) {
      firstCheck = Some(value = bCheck)
      firstPrep = Some(value = bPrep)
    }
    // After a failed rewrite the build stops before type checking; so does
    // the report here (the check still runs, for hover and navigation).
    val bDiags: List[Diagnostic] = newList()
    collectDiags(bPrep.diagnostics, bDiags)
    if not hasErrorDiagnostic(bPrep.diagnostics) {
      collectDiags(bCheck.diagnostics, bDiags)
    }
    for d in bDiags {
      addDiagOnce(checkDiags, d)
    }
  }
  val prep = match firstPrep { case Some(fp) -> fp; case None -> pipePrepareForCheck(parsedFile, false) }
  val cr = match firstCheck {
    case Some(fc) -> fc
    case None -> checkWithImportedPackages(prep.file, checkImportedPackages(state, prep.file))
  }

  // Update rev-deps: for each import in this file, register uri as a consumer.
  val parsedImports = parsedFile.imports
  var ii = 0
  while ii < parsedImports.count {
    val imp = parsedImports[ii]
    val impPath = imp.path
    val impSegs = impPath.segments
    var pkg = ""
    var si = 0
    while si < impSegs.count {
      if si > 0 {
        pkg = pkg + "."
      }
      pkg = pkg + impSegs[si]
      si = si + 1
    }
    match mapGet(state.wsIndex, pkg) {
      case None -> {
      }
      case Some(fp) -> {
        addRevDep(state, pathToUri(fp), uri)
      }
    }
    ii = ii + 1
  }

  val allDiags: List[Diagnostic] = newList()
  collectDiags(parsed.diagnostics, allDiags)
  collectDiags(checkDiags, allDiags)

  // Run verifier (allow-unverified so unknowns become warnings, not errors).
  // Like `lyric prove`, which proves nothing of a program the build rejects
  // (#8227), nothing is proved of a document whose parse or check reports an
  // error: the diagnostics above are all the editor shows for it (#8304).
  // Otherwise the document is proved as `lyric prove <file>` proves it
  // (#8342): as each build that compiles it erases its `@cfg` items (the
  // manifests that list it, with their default features, for `--target
  // dotnet` — `lyric prove`'s defaults), each goal labelled with its build
  // when there are several, reading the declarations of its package's other
  // files (#8108), the standard library and those manifests' packages; and,
  // like `lyric prove`, not at all when which packages build it cannot be
  // known.
  val rejected = hasErrorDiagnostic(parsed.diagnostics) or hasErrorDiagnostic(checkDiags)
  val inactive = if ctx.buildsKnown and not rejected {
    inactiveItemsForBuilds(text, ctx.builds)
  } else {
    noInactiveItems()
  }
  val proofSummary: Option[ProofSummary] = if rejected {
    None
  } else if not ctx.buildsKnown {
    allDiags.add(
      errorDiagnostic(
        "B0001",
        "cannot tell which packages build this file: an enclosing lyric.toml cannot be read, or a package that lists it cannot be listed; no proof obligation was attempted",
        pointSpan(initialPosition())
      )
    )
    None
  } else {
    val docScope = match ctx.fileSet {
      case Some(fs) -> scopeFromPackageFiles(
        Some(value = fs.files),
        fs.fromManifest,
        Disc.normalizePath(docPath),
        text
      )
      case None -> unknownPackageScope()
    }
    // Only a `@proof_required` document is proved: no other reads them.
    val proofScope = if vlIsProofRequired(sourceVerificationLevel(text)) {
      withImportScope(docScope, lspDocImports(state, ctx))
    } else {
      docScope
    }
    val proofResult = proveSourceForBuilds(text, true, proofScope, ctx.builds)
    for d in proofResult.diagnostics {
      // The verifier's diagnostics, and the `@cfg` erasure's for the builds
      // it proves (F0012/F0013), as `lyric prove` reports them.
      if d.code.startsWith("V") or d.code == "F0012" or d.code == "F0013" {
        addDiagOnce(allDiags, d)
      }
    }
    Some(value = proofResult)
  }

  val doc = CachedDoc(source = text, checkResult = cr, proofSummary = proofSummary)
  state.store.remove(uri)
  // safe on absent key; avoids if-branch stack imbalance
  state.store.add(uri, doc)
  acc.add(pushDiagnosticsWithInactive(uri, allDiags, inactive))
  acc
}

// Whether the `initialize` params say the client registers
// `workspace/didChangeWatchedFiles` dynamically.
func clientRegistersWatchedFiles(params: in String): Bool {
  val root = rootElement(parseJson(params))
  match tryGetProperty(root, "capabilities") {
    case Some(caps) -> match tryGetProperty(caps, "workspace") {
      case Some(ws) -> match tryGetProperty(ws, "didChangeWatchedFiles") {
        case Some(w) -> match tryGetProperty(w, "dynamicRegistration") {
          case Some(d) -> valueKind(d) == 5
          case None -> false
        }
        case None -> false
      }
      case None -> false
    }
    case None -> false
  }
}

// The `client/registerCapability` request for `.l` and `lyric.toml` change
// notifications.
func watchedFilesRegistration(): String {
  val watchers: List[String] = newList()
  val globs: List[String] = newList()
  globs.add("**/*.l")
  globs.add("**/lyric.toml")
  for glob in globs {
    val w: List[String] = newList()
    w.add(jPair("globPattern", jStr(glob)))
    watchers.add(jObj(w))
  }
  val opts: List[String] = newList()
  opts.add(jPair("watchers", jArr(watchers)))
  val reg: List[String] = newList()
  reg.add(jPair("id", jStr("lyric-watched-files")))
  reg.add(jPair("method", jStr("workspace/didChangeWatchedFiles")))
  reg.add(jPair("registerOptions", jObj(opts)))
  val regs: List[String] = newList()
  regs.add(jObj(reg))
  val ps: List[String] = newList()
  ps.add(jPair("registrations", jArr(regs)))
  val fs: List[String] = newList()
  fs.add(jPair("jsonrpc", jStr("2.0")))
  fs.add(jPair("id", jStr("lyric-register-watched-files")))
  fs.add(jPair("method", jStr("client/registerCapability")))
  fs.add(jPair("params", jObj(ps)))
  jObj(fs)
}

// Add `d` to `diags` unless one of its code is already reported at its
// position.
func addDiagOnce(diags: in List[Diagnostic], d: in Diagnostic): Unit {
  for e in diags {
    if e.code == d.code and e.span.startPos.line == d.span.startPos.line and e.span.startPos.column == d.span.startPos.column {
      return ()
    }
  }
  diags.add(d)
}

func noInactiveItems(): InactiveItems {
  val noNames: List[String] = newList()
  val noVariants: List[String] = newList()
  val noSpans: List[Span] = newList()
  val noVariantSpans: List[Span] = newList()
  InactiveItems(unproved = noNames, variants = noVariants, unprovedSpans = noSpans, variantSpans = noVariantSpans)
}

// The builds of the document at `docPath` and what its proof reads from
// disk (`LspDocContext`), read once and kept while the disk it was read
// from is unchanged (`lspDiskSnapshot`) and no watched file is reported
// changed.
func lspDocContext(state: in LspState, docPath: in String): LspDocContext {
  match mapGet(state.docContexts, docPath) {
    case Some(c) -> {
      if sameDiskSnapshot(c.snapshot, lspDiskSnapshot(docPath, c.fileSet)) {
        return c
      }
      val _stale = state.docContexts.remove(docPath)
    }
    case None -> ()
  }
  val noCliFeatures: List[String] = newList()
  val fileSet = Disc.packageFileSetForSource(docPath)
  val c = LspDocContext(
    buildsKnown = isSome(Disc.entriesContainingSource(docPath)),
    builds = proveBuildConfigsForSource(docPath, "dotnet", noCliFeatures, false, false),
    fileSet = fileSet,
    manifests = Disc.manifestsListingSource(docPath),
    imports = newList(),
    snapshot = lspDiskSnapshot(docPath, fileSet)
  )
  state.docContexts.add(docPath, c)
  c
}

func lspDiskSnapshot(docPath: in String, fileSet: in Option[Disc.PackageFileSet]): LspDiskSnapshot {
  val manifests: List[String] = newList()
  val stats: List[Option[File.FileStat]] = newList()
  val docDir = Path.dirname(Disc.normalizePath(docPath))
  var dir = docDir
  var walking = dir.length > 0
  while walking {
    val m = Path.join(dir, "lyric.toml")
    manifests.add(m)
    stats.add(match File.stat(m) { case Ok(st) -> Some(value = st); case Err(_) -> None })
    val parent = Path.dirname(dir)
    walking = parent.length > 0 and parent != dir
    dir = parent
  }
  val sources: List[String] = newList()
  val fromManifest = match fileSet { case Some(fs) -> fs.fromManifest; case None -> false }
  if fromManifest {
    val dirs: List[String] = newList()
    dirs.add(docDir)
    match fileSet {
      case Some(fs) -> {
        for f in fs.files {
          val d = Path.dirname(f)
          if not dirs.contains(d) {
            dirs.add(d)
          }
        }
      }
      case None -> ()
    }
    for d in dirs {
      match File.listFiles(d) {
        case Ok(fs) -> {
          for f in fs.toArray() {
            if Str.endsWith(f, ".l") {
              sources.add(f)
            }
          }
        }
        case Err(_) -> sources.add("!unlistable " + d)
      }
    }
  } else {
    match File.listFilesRecursive(docDir) {
      case Ok(fs) -> {
        for f in fs.toArray() {
          if Str.endsWith(f, ".l") {
            sources.add(f)
          }
        }
      }
      case Err(_) -> sources.add("!unlistable " + docDir)
    }
  }
  LspDiskSnapshot(manifests = manifests, manifestStats = stats, sources = sources)
}

func sameDiskSnapshot(a: in LspDiskSnapshot, b: in LspDiskSnapshot): Bool {
  if a.manifests.count != b.manifests.count or a.sources.count != b.sources.count {
    return false
  }
  var i = 0
  while i < a.manifests.count {
    if a.manifests[i] != b.manifests[i] {
      return false
    }
    val same = match a.manifestStats[i] {
      case Some(x) -> match b.manifestStats[i] {
        case Some(y) -> not File.fileStatIsNewer(x, y) and not File.fileStatIsNewer(y, x)
        case None -> false
      }
      case None -> not isSome(b.manifestStats[i])
    }
    if not same {
      return false
    }
    i = i + 1
  }
  for f in a.sources {
    if not b.sources.contains(f) {
      return false
    }
  }
  true
}

// The declarations a proof of the document reads besides its package's: the
// standard library's and those of the packages of the manifests that list
// it, read on its first proof.
func lspDocImports(state: in LspState, ctx: in LspDocContext): ImportScope {
  if ctx.imports.count == 0 {
    ctx.imports.add(importScopeWithManifests(lspStdlibScope(state), ctx.manifests))
  }
  ctx.imports[0]
}

// The standard library's declarations a proof reads, as `lyric prove`
// reads them for `--target dotnet`: read on the first proof, then kept.
func lspStdlibScope(state: in LspState): ImportScope {
  if state.stdlibScope.count == 0 {
    state.stdlibScope.add(importScopeWithSources(emptyImportScope(), Emitter.findStdlibSources()))
  }
  state.stdlibScope[0]
}

// `diags`, then the items of a `@proof_required` document no build
// compiles, which `lyric prove` lists after its diagnostics (#8342): each
// an Information diagnostic at the declaration.
func pushDiagnosticsWithInactive(uri: in String, diags: in List[Diagnostic], inactive: in InactiveItems): String {
  val arr: List[String] = newList()
  for d in diags {
    arr.add(toLspDiag(d))
  }
  for sp in inactive.unprovedSpans {
    arr.add(toLspInfo(sp, "not proved: inactive under this build (@cfg)"))
  }
  for sp in inactive.variantSpans {
    arr.add(
      toLspInfo(sp, "inactive @cfg variant, not proved; the declaration of the same name this build compiles is proved")
    )
  }
  val fs: List[String] = newList()
  fs.add(jPair("uri", jStr(uri)))
  fs.add(jPair("diagnostics", jArr(arr)))
  mkNotif("textDocument/publishDiagnostics", jObj(fs))
}

// An LSP Information diagnostic (severity 3) at `sp`.
func toLspInfo(sp: in Span, message: in String): String {
  val fs: List[String] = newList()
  fs.add(jPair("range", toLspRange(sp)))
  fs.add(jPair("severity", jInt(3)))
  fs.add(jPair("source", jStr("lyric")))
  fs.add(jPair("message", jStr(message)))
  jObj(fs)
}

// Helper: re-analyze one consumer URI and append notifications to acc.
// Separate Unit-returning function so mapGet(state.store, ...) generic
// inference is not confused by the List[String] return type of the caller.
func analyzeConsumer(state: in LspState, consumerUri: in String, acc: in List[String]): Unit {
  match mapGet(state.store, consumerUri) {
    case None -> {
    }
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
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Identifier/call-context helpers.
// ─────────────────────────────────────────────────────────────────────────────
func isIdChar(c: in Char): Bool {
  isLetterOrDigit(c) or c == '_'
  // Std.Char.isLetterOrDigit
}

func identAtLine(line: in String, zeroCol: in Int): Option[String] {
  if zeroCol < 0 or zeroCol > line.length {
    return None
  }
  var start = zeroCol
  var scanning = true
  while scanning and start > 0 {
    val c = Str.charAtOrReplacement(line, start - 1)
    // BCL String indexer → Char
    if isIdChar(c) {
      start = start - 1
    } else {
      scanning = false
    }
  }
  var stopPos = zeroCol
  var scanning2 = true
  while scanning2 and stopPos < line.length {
    val c = Str.charAtOrReplacement(line, stopPos)
    if isIdChar(c) {
      stopPos = stopPos + 1
    } else {
      scanning2 = false
    }
  }
  if start >= stopPos {
    return None
  }
  val ident = line.substring(start, stopPos - start)
  // BCL String.Substring(start, length)
  if ident.length == 0 {
    return None
  }
  val first = Str.charAtOrReplacement(ident, 0)
  if isLetter(first) or first == '_' {
    Some(value = ident)
  } else {
    None
  }
}

func identAtPos(text: in String, oneLine: in Int, oneCol: in Int): Option[String] {
  val lines = text.split("\n")
  // BCL String.Split → string[]
  if oneLine < 1 or oneLine > lines.length {
    return None
  }
  identAtLine(lines[oneLine - 1], oneCol - 1)
}

// Scan backwards from offset for the function name before the nearest
// un-matched open paren, plus count how many commas at nesting 0 precede
// the offset.  Returns (funcName, paramIndex) or None.
func callContextAt(text: in String, offset: in Int): Option[String] {
  var i = offset - 1
  var depth = 0
  var found = -1
  var loop = true
  while loop and i >= 0 {
    val c = Str.charAtOrReplacement(text, i)
    if c == ')' or c == ']' {
      depth = depth + 1
    } else if c == '(' or c == '[' {
      if depth == 0 {
        found = i
        loop = false
      } else {
        depth = depth - 1
      }
    }
    i = i - 1
  }
  if found < 0 {
    return None
  }
  // Trim whitespace to find identifier end.
  var j = found - 1
  while j >= 0 and (Str.charAtOrReplacement(text, j) == ' ' or Str.charAtOrReplacement(text, j) == '\t') {
    j = j - 1
  }
  val endJ = j + 1
  while j >= 0 and isIdChar(Str.charAtOrReplacement(text, j)) {
    j = j - 1
  }
  val funcName = text.substring(j + 1, endJ - (j + 1))
  if funcName.length == 0 {
    return None
  }
  if isDigit(Str.charAtOrReplacement(funcName, 0)) {
    return None
  }
  Some(value = funcName)
}

func lineColToOffset(text: in String, line: in Int, col: in Int): Int {
  val lines = text.split("\n")
  var off = 0
  var li = 0
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
    case TyPrim(pt) -> primName(pt)
    case TyTuple(elems) -> {
      var s = "("
      var i = 0
      while i < elems.count {
        if i > 0 {
          s = s + ", "
        }
        s = s + renderType(cr, elems[i])
        i = i + 1
      }
      s + ")"
    }
    case TyNullable(inner) -> renderType(cr, inner) + "?"
    case TyFunction(ps, ret, isAsync) -> {
      val pref = if isAsync { "async " } else { "" }
      var s = pref + "("
      var i = 0
      while i < ps.count {
        if i > 0 {
          s = s + ", "
        }
        s = s + renderType(cr, ps[i])
        i = i + 1
      }
      s + ") -> " + renderType(cr, ret)
    }
    case TyArray(sizeOpt, elem, _) -> {
      match sizeOpt {
        case None -> "array[?, " + renderType(cr, elem) + "]"
        case Some(n) -> "array[" + ("" + n) + ", " + renderType(cr, elem) + "]"
      }
    }
    case TySlice(elem) -> "slice[" + renderType(cr, elem) + "]"
    case TyUser(id, declName, args) -> {
      // Prefer the name carried in the type (#425 item 6); fall back
      // to a symbol-table sweep when the constructor lacked context.
      var name = if declName.length > 0 { declName } else { "<type>" }
      if declName.length == 0 {
        val crSymTable = cr.symbols
        val crSymList = crSymTable.symbols
        var si = 0
        while si < crSymList.count {
          val sym = crSymList[si]
          match symbolTypeIdOpt(sym) {
            case Some(tid) -> {
              if tid.id == id.id {
                name = sym.name
              }
            }
            case None -> {
            }
          }
          si = si + 1
        }
      }
      if args.count == 0 {
        name
      } else {
        var s = name + "["
        var i = 0
        while i < args.count {
          if i > 0 {
            s = s + ", "
          }
          s = s + renderType(cr, args[i])
          i = i + 1
        }
        s + "]"
      }
    }
    case TyRefined(u, lo, hi, inc, _) -> {
      // Render lo/hi conditionally so open-ended forms produce
      // `Int range 5 ..` / `Int range ..= 9` instead of trailing-op /
      // leading-double-space output.
      val loStr = match lo { case None -> ""; case Some(v) -> "" + v }
      val hiStr = match hi { case None -> ""; case Some(v) -> "" + v }
      val opBare = if inc { "..=" } else { ".." }
      val left = if loStr.length > 0 { loStr + " " } else { "" }
      val right = if hiStr.length > 0 { " " + hiStr } else { "" }
      renderType(cr, u) + " range " + left + opBare + right
    }
    case TySelf -> "Self"
    case TyLen(n) -> toString(n)
    case TyVar(n) -> n
    case TyError -> "<error>"
    case TyException -> "Exception"
  }
}

func renderMode(m: in ParamMode): String {
  match m {
    case PMIn -> "in"
    case PMOut -> "out"
    case PMInout -> "inout"
  }
}

func renderSig(cr: in CheckResult, sig: in ResolvedSignature, name: in String): String {
  var s = ""
  if sig.isAsync {
    s = s + "async "
  }
  s = s + "func " + name
  if sig.generics.count > 0 {
    s = s + "["
    var i = 0
    while i < sig.generics.count {
      if i > 0 {
        s = s + ", "
      }
      s = s + sig.generics[i]
      i = i + 1
    }
    s = s + "]"
  }
  s = s + "("
  var pi = 0
  while pi < sig.params.count {
    if pi > 0 {
      s = s + ", "
    }
    val p = sig.params[pi]
    s = s + renderMode(p.mode) + " " + p.name + ": " + renderType(cr, p.ty)
    pi = pi + 1
  }
  s + "): " + renderType(cr, sig.returnTy)
}

func itemSummary(item: in Item): String {
  val v = visibilityPrefixStr(item.visibility)
  match item.kind {
    case IFunc(fd) -> v + "func " + fd.name + "(...)"
    case IRecord(rd) -> v + (if rd.isRef { "ref record " } else { "record " }) + rd.name
    case IExposedRec(rd) -> v + "exposed record " + rd.name
    case IUnion(ud) -> v + "union " + ud.name
    case IEnum(ed) -> v + "enum " + ed.name
    case IOpaque(od) -> v + "opaque type " + od.name
    case IInterface(id) -> v + "interface " + id.name
    case IConst(cd) -> v + "const " + cd.name
    case ITypeAlias(ta) -> v + "alias " + ta.name
    case IDistinctType(dt) -> v + "distinct type " + dt.name
    case IExternType(et) -> "extern type " + et.name
    case _ -> "(item)"
  }
}

func itemName(item: in Item): Option[String] {
  match item.kind {
    case IFunc(fd) -> Some(value = fd.name)
    case IRecord(rd) -> Some(value = rd.name)
    case IExposedRec(rd) -> Some(value = rd.name)
    case IUnion(ud) -> Some(value = ud.name)
    case IEnum(ed) -> Some(value = ed.name)
    case IOpaque(od) -> Some(value = od.name)
    case IInterface(id) -> Some(value = id.name)
    case IConst(cd) -> Some(value = cd.name)
    case ITypeAlias(ta) -> Some(value = ta.name)
    case IDistinctType(dt) -> Some(value = dt.name)
    case IExternType(et) -> Some(value = et.name)
    case _ -> None
  }
}

func symKind(sym: in Symbol): Int {
  match sym.kind {
    case DKFunc(_) -> 3
    case DKRecord(_, _) -> 22
    case DKExposedRec(_, _) -> 22
    case DKUnion(_, _) -> 7
    case DKEnum(_, _) -> 13
    case DKOpaque(_, _) -> 22
    case DKProtected(_, _) -> 22
    case DKDistinctType(_, _) -> 22
    case DKTypeAlias(_) -> 7
    case DKInterface(_, _) -> 8
    case DKConst(_) -> 21
    case DKVal(_) -> 6
    case _ -> 1
  }
}

func symDetail(sym: in Symbol): String {
  val v = visibilityPrefixStr(sym.visibility)
  match sym.kind {
    case DKFunc(_) -> v + "func " + sym.name + "(...)"
    case DKRecord(_, rd) -> v + (if rd.isRef { "ref record " } else { "record " }) + sym.name
    case DKExposedRec(_, _) -> v + "exposed record " + sym.name
    case DKUnion(_, _) -> v + "union " + sym.name
    case DKEnum(_, _) -> v + "enum " + sym.name
    case DKOpaque(_, _) -> v + "opaque type " + sym.name
    case DKInterface(_, _) -> v + "interface " + sym.name
    case DKConst(_) -> v + "const " + sym.name
    case DKTypeAlias(_) -> v + "alias " + sym.name
    case DKDistinctType(_, _) -> v + "distinct type " + sym.name
    case DKExternType(_, _) -> "extern type " + sym.name
    case _ -> sym.name
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
        val before = ci == 0 or not isIdChar(Str.charAtOrReplacement(line, ci - 1))
        val after = ci + name.length >= line.length or not isIdChar(Str.charAtOrReplacement(line, ci + name.length))
        if before and after {
          val sp = Span(
            startPos = Position(offset = 0, line = li + 1, column = ci + 1),
            endPos = Position(offset = 0, line = li + 1, column = ci + name.length + 1)
          )
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
  info.add(jPair("name", jStr("lyric-lsp")))
  info.add(jPair("version", jStr(Ver.VERSION())))
  val r: List[String] = newList()
  r.add(jPair("capabilities", jObj(caps)))
  r.add(jPair("serverInfo", jObj(info)))
  jObj(r)
}

// ─────────────────────────────────────────────────────────────────────────────
// §14. Handler implementations.
// ─────────────────────────────────────────────────────────────────────────────
func handleInitialize(state: in LspState, id: in String, params: in String): List[String] {
  val acc: List[String] = newList()
  acc.add(mkResponse(id, initResult()))
  if state.dynamicWatch.count == 0 {
    state.dynamicWatch.add(clientRegistersWatchedFiles(params))
  }
  // Extract workspace root — rootUri/rootPath are top-level fields of `params`.
  val rootUri = jRootStr(params, "rootUri")
  val rootPath = jRootStr(params, "rootPath")
  val wsRoot = if rootUri.length > 0 { uriToPath(rootUri) } else if rootPath.length > 0 { rootPath } else { "" }
  state.wsRoot[0] = wsRoot
  // mutate the box
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
  val uri = jNested2Str(pdoc, "textDocument", "uri")
  // 'text' is nested inside 'textDocument'.
  val root = rootElement(pdoc)
  val text = match tryGetProperty(root, "textDocument") {
    case None -> ""
    case Some(td) -> match tryGetProperty(td, "text") { case None -> ""; case Some(e) -> getString(e) }
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
    case Some(td) -> match tryGetProperty(td, "uri") { case None -> ""; case Some(e) -> getString(e) }
  }
  var newText = ""
  match tryGetProperty(root, "contentChanges") {
    case None -> {
    }
    case Some(changesElem) -> {
      var en = enumerateArray(changesElem)
      var more = arrayMoveNext(en)
      while more {
        val ch = arrayCurrent(en)
        match tryGetProperty(ch, "text") {
          case None -> {
          }
          case Some(te) -> {
            newText = getString(te)
          }
        }
        more = arrayMoveNext(en)
      }
    }
  }
  if uri.length > 0 {
    collectMsgs(analyzeAndStore(state, uri, newText), acc)
    collectMsgs(reAnalyzeConsumers(state, uri), acc)
  }
  acc
}

func handleDocClose(state: in LspState, params: in String): List[String] {
  val acc: List[String] = newList()
  val pdoc = parseJson(params)
  val uri = jNested2Str(pdoc, "textDocument", "uri")
  if uri.length > 0 {
    state.store.remove(uri)
    val empty: List[Diagnostic] = newList()
    acc.add(pushDiagnostics(uri, empty))
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// Method-syntax calls to dot-named functions (#8338).
// ─────────────────────────────────────────────────────────────────────────────
// `b.extra()` calls `func Bag.extra(self: in Bag)`: the item is named
// `Bag.extra`, so a lookup of the bare word `extra` finds nothing.  The
// receiver's type is read from its declaration in the text above the call —
// the editor keeps the check's result, not its per-expression types — and
// the function is bound as the type checker binds it (docs/01 §5.1): the
// type's own package first, then the nearest imported extension.
/// A dot-named function a method call can bind to, with where it lives.
record MethodTarget {
  item: Item
  // The declaring file's URI; "" for a standard-library function, whose
  // source the server has no path for.
  uri: String
  pkg: String
  // The type names its package declares.
  declaresType: List[String]
}

func dottedPackageName(file: in SourceFile): String {
  val segs = file.packageDecl.path.segments
  var pkg = ""
  var i = 0
  while i < segs.count {
    if i > 0 {
      pkg = pkg + "."
    }
    pkg = pkg + segs[i]
    i = i + 1
  }
  pkg
}

func importedPackageName(imp: in ImportDecl): String {
  val segs = imp.path.segments
  var pkg = ""
  var i = 0
  while i < segs.count {
    if i > 0 {
      pkg = pkg + "."
    }
    pkg = pkg + segs[i]
    i = i + 1
  }
  pkg
}

func typeItemNames(items: in List[Item]): List[String] {
  val names: List[String] = newList()
  for it in items {
    match it.kind {
      case IFunc(_) -> ()
      case _ -> match itemName(it) { case Some(n) -> names.add(n); case None -> () }
    }
  }
  names
}

func addMethodTargets(
  acc: in List[MethodTarget],
  items: in List[Item],
  uri: in String,
  pkg: in String,
  suffix: in String,
): Unit {
  val declared = typeItemNames(items)
  for it in items {
    match it.kind {
      case IFunc(fd) -> {
        if fd.name.endsWith(suffix) {
          acc.add(MethodTarget(item = it, uri = uri, pkg = pkg, declaresType = declared))
        }
      }
      case _ -> ()
    }
  }
}

// Every function whose name ends in `.method`, nearest first: this
// document's, its imported workspace packages' in import order, then the
// standard library's.
func methodTargetsFor(state: in LspState, cr: in CheckResult, uri: in String, method: in String): List[MethodTarget] {
  val acc: List[MethodTarget] = newList()
  val suffix = "." + method
  val file = cr.file
  addMethodTargets(acc, file.items, uri, dottedPackageName(file), suffix)
  for imp in file.imports {
    val pkg = importedPackageName(imp)
    match mapGet(state.wsIndex, pkg) {
      case None -> ()
      case Some(fp) -> {
        if hostFileExists(fp) {
          addMethodTargets(acc, parse(hostReadAllText(fp)).file.items, pathToUri(fp), pkg, suffix)
        }
      }
    }
  }
  if state.stdlibPackages.count > 0 {
    for sp in state.stdlibPackages[0] {
      addMethodTargets(acc, sp.items, "", sp.name, suffix)
    }
  }
  acc
}

// The type name that starts at `pos` in `line` (a qualifier's last segment),
// when it is capitalised.
func typeNameAt(line: in String, pos: in Int): Option[String] {
  var p = pos
  while p < line.length and Str.charAtOrReplacement(line, p) == ' ' {
    p = p + 1
  }
  var kw = 0
  while kw < 3 {
    var q = p
    while q < line.length and isIdChar(Str.charAtOrReplacement(line, q)) {
      q = q + 1
    }
    val word = line.substring(p, q - p)
    if (word == "in" or word == "out" or word == "inout") and q < line.length and Str.charAtOrReplacement(line, q) == ' ' {
      p = q
      while p < line.length and Str.charAtOrReplacement(line, p) == ' ' {
        p = p + 1
      }
    }
    kw = kw + 1
  }
  var e = p
  while e < line.length and (isIdChar(Str.charAtOrReplacement(line, e)) or Str.charAtOrReplacement(line, e) == '.') {
    e = e + 1
  }
  if e <= p {
    return None
  }
  val segs = line.substring(p, e - p).split(".")
  val last = segs[segs.length - 1]
  if last.length > 0 and isUpper(Str.charAtOrReplacement(last, 0)) {
    Some(value = last)
  } else {
    None
  }
}

// The type `word` is declared with in `line`: `word: Type` (a parameter or an
// annotated binding), or `val word = Type...` (a constructor call).
func declaredTypeInLine(line: in String, word: in String): Option[String] {
  var from = 0
  while from <= line.length - word.length {
    val at = Str.indexOfFromRaw(line, word, from)
    if at < 0 {
      return None
    }
    val before = if at == 0 { ' ' } else { Str.charAtOrReplacement(line, at - 1) }
    val afterPos = at + word.length
    val after = if afterPos >= line.length { ' ' } else { Str.charAtOrReplacement(line, afterPos) }
    if not isIdChar(before) and before != '.' and not isIdChar(after) {
      val head = line.substring(0, at).trim()
      val isBinding = head.endsWith("val") or head.endsWith("var")
      var p = afterPos
      while p < line.length and Str.charAtOrReplacement(line, p) == ' ' {
        p = p + 1
      }
      if p < line.length and Str.charAtOrReplacement(line, p) == ':' {
        match typeNameAt(line, p + 1) {
          case Some(t) -> return Some(value = t)
          case None -> ()
        }
      } else if p < line.length and Str.charAtOrReplacement(line, p) == '=' and isBinding {
        match typeNameAt(line, p + 1) {
          case Some(t) -> return Some(value = t)
          case None -> ()
        }
      }
    }
    from = at + 1
  }
  None
}

// The type name of the receiver of the method call whose `.` is at `dotCol`
// of `lines[lineIdx]`, when it is a literal or a name declared above with a
// type.
func receiverTypeName(source: in String, lineIdx: in Int, dotCol: in Int): Option[String] {
  val lines = source.split("\n")
  val line = lines[lineIdx]
  if dotCol <= 0 {
    return None
  }
  val last = Str.charAtOrReplacement(line, dotCol - 1)
  if last == '"' {
    return Some(value = "String")
  }
  if not isIdChar(last) {
    return None
  }
  var start = dotCol
  while start > 0 and isIdChar(Str.charAtOrReplacement(line, start - 1)) {
    start = start - 1
  }
  if start > 0 and Str.charAtOrReplacement(line, start - 1) == '.' {
    return None
  }
  val word = line.substring(start, dotCol - start)
  if isDigit(Str.charAtOrReplacement(word, 0)) {
    return Some(value = "Int")
  }
  var li = lineIdx
  while li >= 0 {
    val l = if li == lineIdx { line.substring(0, start) } else { lines[li] }
    match declaredTypeInLine(l, word) {
      case Some(t) -> return Some(value = t)
      case None -> ()
    }
    li = li - 1
  }
  None
}

// The function the method call under the cursor binds to, or None when the
// cursor is not on a method name or the binding cannot be told.
func resolveMethodAt(
  state: in LspState, cached: in CachedDoc, uri: in String, oneLine: in Int, oneCol: in Int
): Option[MethodTarget] {
  val lines = cached.source.split("\n")
  if oneLine < 1 or oneLine > lines.length {
    return None
  }
  val lineIdx = oneLine - 1
  val line = lines[lineIdx]
  var start = oneCol - 1
  if start < 0 or start > line.length {
    return None
  }
  while start > 0 and isIdChar(Str.charAtOrReplacement(line, start - 1)) {
    start = start - 1
  }
  var stop = oneCol - 1
  while stop < line.length and isIdChar(Str.charAtOrReplacement(line, stop)) {
    stop = stop + 1
  }
  if start >= stop or start == 0 or Str.charAtOrReplacement(line, start - 1) != '.' {
    return None
  }
  val method = line.substring(start, stop - start)
  val targets = methodTargetsFor(state, cached.checkResult, uri, method)
  if targets.count == 0 {
    return None
  }
  match receiverTypeName(cached.source, lineIdx, start - 1) {
    case None -> if targets.count == 1 { Some(value = targets[0]) } else { None }
    case Some(tn) -> {
      val wanted = tn + "." + method
      var typeDeclPkg = ""
      for t in targets {
        if typeDeclPkg == "" and t.declaresType.contains(tn) {
          typeDeclPkg = t.pkg
        }
      }
      var best: Option[MethodTarget] = None
      for t in targets {
        match t.item.kind {
          case IFunc(fd) -> {
            if fd.name == wanted {
              if isNone(best) {
                best = Some(value = t)
              } else if typeDeclPkg != "" and t.pkg == typeDeclPkg {
                match best {
                  case Some(b) -> if b.pkg != typeDeclPkg { best = Some(value = t) }
                  case None -> ()
                }
              }
            }
          }
          case _ -> ()
        }
      }
      best
    }
  }
}

func handleHover(state: in LspState, params: in String): String {
  val pdoc = parseJson(params)
  val uri = jNested2Str(pdoc, "textDocument", "uri")
  val lineNum = jNested2Int(pdoc, "position", "line")
  val colNum = jNested2Int(pdoc, "position", "character")
  match mapGet(state.store, uri) {
    case None -> {
      return "{}"
    }
    case Some(cached) -> {
      match identAtPos(cached.source, lineNum + 1, colNum + 1) {
        case None -> {
          return "{}"
        }
        case Some(ident) -> {
          val cr = cached.checkResult
          val crFile = cr.file
          val crItems = crFile.items
          var foundIt: Option[Item] = None
          var foundPkg = ""
          match resolveMethodAt(state, cached, uri, lineNum + 1, colNum + 1) {
            case Some(mt) -> {
              foundIt = Some(value = mt.item)
              foundPkg = mt.pkg
            }
            case None -> ()
          }
          var i = 0
          while i < crItems.count {
            match itemName(crItems[i]) {
              case Some(n) -> {
                if n == ident and isNone(foundIt) {
                  foundIt = Some(value = crItems[i])
                }
              }
              case None -> {
              }
            }
            i = i + 1
          }
          match foundIt {
            case None -> {
              return "{}"
            }
            case Some(it) -> {
              val body = match it.kind {
                case IFunc(fd) -> {
                  val arityKey = fd.name + "/" + ("" + fd.params.count)
                  val sigOpt = match mapGet(cr.sigs, arityKey) {
                    case None -> mapGet(cr.sigs, fd.name)
                    case Some(s) -> Some(value = s)
                  }
                  match sigOpt {
                    case None -> itemSummary(it)
                    case Some(s) -> renderSig(cr, s, fd.name)
                  }
                }
                case _ -> itemSummary(it)
              }
              var fullBody = body
              if foundPkg.length > 0 {
                fullBody = fullBody + "\n// package " + foundPkg
              }
              var di = 0
              while di < it.docComments.count {
                if di == 0 {
                  fullBody = fullBody + "\n\n"
                }
                fullBody = fullBody + it.docComments[di].text.trim() + "\n"
                di = di + 1
              }
              val fs: List[String] = newList()
              val contents: List[String] = newList()
              contents.add(jPair("kind", jStr("markdown")))
              contents.add(jPair("value", jStr("```lyric\n" + fullBody + "\n```")))
              fs.add(jPair("contents", jObj(contents)))
              fs.add(jPair("range", toLspRange(it.span)))
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
  val uri = jNested2Str(pdoc, "textDocument", "uri")
  match mapGet(state.store, uri) {
    case None -> "[]"
    case Some(cached) -> {
      val items: List[String] = newList()
      // Dedup completion labels by name.  A `Map[String, Bool]` is used as the
      // seen-set: `newMap` is a first-class codegen builtin, whereas `newSet`
      // (the `HashSet`1` extern ctor in `Std.CollectionsHost`) is not yet
      // resolved by the self-hosted emitter when its defining package is not a
      // direct import, so a bare `newSet()` here erased and dropped (#3943).
      val seen: Map[String, Bool] = newMap()
      val cachedCr2 = cached.checkResult
      val symTable2 = cachedCr2.symbols
      val syms = symTable2.symbols
      var i = 0
      while i < syms.count {
        val s = syms[i]
        if not seen.containsKey(s.name) {
          seen.add(s.name, true)
          val compItem: List[String] = newList()
          compItem.add(jPair("label", jStr(s.name)))
          compItem.add(jPair("kind", jInt(symKind(s))))
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
  val pdoc = parseJson(params)
  val uri = jNested2Str(pdoc, "textDocument", "uri")
  val lineNum = jNested2Int(pdoc, "position", "line")
  val colNum = jNested2Int(pdoc, "position", "character")
  match mapGet(state.store, uri) {
    case None -> {
      return "[]"
    }
    case Some(cached) -> {
      match identAtPos(cached.source, lineNum + 1, colNum + 1) {
        case None -> {
          return "[]"
        }
        case Some(ident) -> {
          val cr = cached.checkResult
          val crFile = cr.file
          val crItems = crFile.items
          var foundSpan: Option[Span] = None
          var foundUri: String = uri
          var localDone = false
          match resolveMethodAt(state, cached, uri, lineNum + 1, colNum + 1) {
            case Some(mt) -> {
              if mt.uri.length > 0 {
                foundSpan = Some(value = mt.item.span)
                foundUri = mt.uri
                localDone = true
              }
            }
            case None -> ()
          }
          // Local search first.
          var i = 0
          while i < crItems.count and not localDone {
            match itemName(crItems[i]) {
              case Some(n) -> {
                if n == ident {
                  foundSpan = Some(value = crItems[i].span)
                  localDone = true
                }
              }
              case None -> {
              }
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
              val fp = files[fi]
              val fUri = pathToUri(fp)
              if fUri != uri and hostFileExists(fp) {
                val impParsed = parse(hostReadAllText(fp))
                val impFile = impParsed.file
                val impItems = impFile.items
                var ki = 0
                var fileDone = false
                while ki < impItems.count and not fileDone {
                  match itemName(impItems[ki]) {
                    case Some(n) -> {
                      if n == ident {
                        foundSpan = Some(value = impItems[ki].span)
                        foundUri = fUri
                        fileDone = true
                        wsDone = true
                      }
                    }
                    case None -> {
                    }
                  }
                  ki = ki + 1
                }
              }
              fi = fi + 1
            }
          }
          match foundSpan {
            case None -> {
              return "[]"
            }
            case Some(span) -> {
              val fs: List[String] = newList()
              fs.add(jPair("uri", jStr(foundUri)))
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
  val rdoc = parseJson(rangeJson)
  val startLine = jNested2Int(rdoc, "start", "line")
  val startChar = jNested2Int(rdoc, "start", "character")
  val endLine = jNested2Int(rdoc, "end", "line")
  val endChar = jNested2Int(rdoc, "end", "character")
  val lines = source.split("\n")
  if startLine >= lines.length {
    return ""
  }
  if startLine == endLine {
    val line = lines[startLine]
    if startChar >= line.length {
      return ""
    }
    val len = endChar - startChar
    if len <= 0 {
      return ""
    }
    val safeLen = if startChar + len > line.length { line.length - startChar } else { len }
    line.substring(startChar, safeLen)
  } else {
    val firstLine = lines[startLine]
    var resultStr = firstLine.substring(startChar, firstLine.length - startChar)
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
  var i = offset - 1
  var depth = 0
  var found = -1
  var loop = true
  while loop and i >= 0 {
    val c = Str.charAtOrReplacement(text, i)
    if c == ')' or c == ']' {
      depth = depth + 1
    } else if c == '(' or c == '[' {
      if depth == 0 {
        found = i
        loop = false
      } else {
        depth = depth - 1
      }
    }
    i = i - 1
  }
  if found < 0 {
    return 0
  }
  var commas = 0
  var j = found + 1
  var d2 = 0
  while j < offset {
    val c = Str.charAtOrReplacement(text, j)
    if c == '(' or c == '[' {
      d2 = d2 + 1
    } else if c == ')' or c == ']' {
      d2 = d2 - 1
    } else if c == ',' and d2 == 0 {
      commas = commas + 1
    }
    j = j + 1
  }
  commas
}

func handleSignatureHelp(state: in LspState, params: in String): String {
  val pdoc = parseJson(params)
  val uri = jNested2Str(pdoc, "textDocument", "uri")
  val lineNum = jNested2Int(pdoc, "position", "line")
  val colNum = jNested2Int(pdoc, "position", "character")
  match mapGet(state.store, uri) {
    case None -> "{}"
    case Some(cached) -> {
      val off = lineColToOffset(cached.source, lineNum + 1, colNum + 1)
      match callContextAt(cached.source, off) {
        case None -> "{}"
        case Some(funcName) -> {
          val cr = cached.checkResult
          val crSymTable = cr.symbols
          val crSymList = crSymTable.symbols
          var sigOpt: Option[ResolvedSignature] = None
          match mapGet(cr.sigs, funcName) {
            case Some(s) -> {
              sigOpt = Some(value = s)
            }
            case None -> {
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
                        case Some(s) -> {
                          sigOpt = Some(value = s)
                          sigFound = true
                        }
                        case None -> {
                        }
                      }
                    }
                    case _ -> {
                    }
                  }
                }
                si = si + 1
              }
            }
          }
          match sigOpt {
            case None -> "{}"
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
              sigObj.add(jPair("label", jStr(sigLabel)))
              sigObj.add(jPair("parameters", jArr(pArr)))
              val sigsArr: List[String] = newList()
              sigsArr.add(jObj(sigObj))
              val activeParam = callParamIndexAt(cached.source, off)
              val r: List[String] = newList()
              r.add(jPair("signatures", jArr(sigsArr)))
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
    val a = anns[i]
    val aName = a.name
    val aSegs = aName.segments
    if aSegs.count == 1 and aSegs[0] == "proof_required" {
      return Some(value = a)
    }
    i = i + 1
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §15a. "Implement Interface" code-action support (D105 §B).
// ─────────────────────────────────────────────────────────────────────────────
// Lazily build the reference-pack metadata indexes on first use.  Idempotent.
// When the reference pack is unavailable (SDK-less environment), the indexes
// stay empty and the extern-impl scaffolder silently falls back to no-op.
func ensureLspMetadataIndex(state: in LspState): Unit {
  if state.ffiIndexInit[0] {
    return
  }
  state.ffiIndexInit[0] = true
  match Mdr.refPackDir() {
    case None -> {
    }
    case Some(refDir) -> {
      val paths = Mdr.enumRefAssemblies(refDir)
      val ty = Mdr.buildTypeIndex(paths)
      val pa = Mdr.buildPathIndex(paths)
      for k in dictGetKeys(ty) {
        match mapGet(ty, k) {
          case Some(v) -> state.ffiTypeIndex.add(k, v)
          case None -> {
          }
        }
      }
      for k in dictGetKeys(pa) {
        match mapGet(pa, k) {
          case Some(v) -> state.ffiPathIndex.add(k, v)
          case None -> {
          }
        }
      }
    }
  }
}

// Render a TypeExpr back as Lyric source text.  Recursive; handles primitive
// names (`Int`, `String`, …), simple type refs (`Resource`), and generic
// applications (`List[Int]`, `Map[String, Int]`).  Unknown / structural
// shapes fall back to `Any` so the stub still parses; the user can fix up.
func renderTypeExprAsLyricSource(te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> {
      var s = ""
      var i = 0
      while i < path.segments.count {
        if i > 0 {
          s = s + "."
        }
        s = s + path.segments[i]
        i = i + 1
      }
      s
    }
    case TGenericApp(head, args) -> {
      var s = ""
      var hi = 0
      while hi < head.segments.count {
        if hi > 0 {
          s = s + "."
        }
        s = s + head.segments[hi]
        hi = hi + 1
      }
      s = s + "["
      var ai = 0
      while ai < args.count {
        if ai > 0 {
          s = s + ", "
        }
        s = s + match args[ai] { case TAType(t) -> renderTypeExprAsLyricSource(t); case TAValue(_) -> "_" }
        ai = ai + 1
      }
      s = s + "]"
      s
    }
    case _ -> "Any"
  }
}

// Render one Lyric `Param` as `name: mode Type` (or just `name: Type` when
// the mode keyword was omitted in the source).  Used when synthesising
// native-interface method stubs from the iface's `IMSig` members.
func renderParamAsLyricSource(p: in Param): String {
  val modeStr = if p.modeExplicit {
    match p.mode {
      case PMIn -> "in "
      case PMOut -> "out "
      case PMInout -> "inout "
    }
  } else {
    ""
  }
  p.name + ": " + modeStr + renderTypeExprAsLyricSource(p.ty)
}

// True when `s` is contained in (or touches the start of) the impl decl's
// LSP-translated source span.  Used to identify an impl block at the
// caret/selection range of a code-action request.
func lspRangePositionInside(rng: in String, target: in Span): Bool {
  val pdoc = parseJson(rng)
  val r = rootElement(pdoc)
  val sLine = match tryGetProperty(r, "start") {
    case None -> -1
    case Some(sp) -> match tryGetProperty(sp, "line") {
      case None -> -1
      case Some(e) -> match tryGetInt(e) { case None -> -1; case Some(n) -> n + 1 }
    }
  }
  val sCol = match tryGetProperty(r, "start") {
    case None -> -1
    case Some(sp) -> match tryGetProperty(sp, "character") {
      case None -> -1
      case Some(e) -> match tryGetInt(e) { case None -> -1; case Some(n) -> n + 1 }
    }
  }
  if sLine < 0 {
    return false
  }
  val tsLine = target.startPos.line
  val tsCol = target.startPos.column
  val teLine = target.endPos.line
  val teCol = target.endPos.column
  val afterStart = sLine > tsLine or (sLine == tsLine and sCol >= tsCol)
  val beforeEnd = sLine < teLine or (sLine == teLine and sCol <= teCol)
  afterStart and beforeEnd
}

// Find an IImpl block in `file` whose span contains `rng`, or None.  The
// first match wins (impl blocks don't nest).
func findImplDeclAtRange(file: in SourceFile, rng: in String): Option[ImplDecl] {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IImpl(decl) -> {
        if lspRangePositionInside(rng, decl.span) {
          return Some(value = decl)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  None
}

// Names of methods the user has already implemented in this impl block.
// Compared against the iface's required-method list to compute the
// scaffolder's "missing" set.
func implMethodNames(decl: in ImplDecl): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMplFunc(fn) -> names.add(fn.name)
      case IMplAssoc(_) -> {
      }
    }
    i = i + 1
  }
  names
}

func listContainsString(xs: in List[String], s: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == s {
      return true
    }
    i = i + 1
  }
  false
}

// Find the `DKInterface` symbol named `name`, or None.  Mirrors
// `findInterfaceDecl` in `typechecker_checker.l` but lives here so the
// LSP doesn't have to expose its symbol-table walker.
func lspFindInterfaceDecl(tbl: in SymbolTable, name: in String): Option[InterfaceDecl] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKInterface(_, d) -> {
        if tbl.symbols[i].name == name {
          return Some(value = d)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  None
}

// CLR FQN of a `DKExternType` symbol named `name`, or "" when no extern
// type by that name is in scope.  Used by the extern-impl scaffolder to
// route through `Mdr.inspectInterfaceTarget`.
func lspFindExternTypeFqn(tbl: in SymbolTable, name: in String): String {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKExternType(_, decl) -> {
        if tbl.symbols[i].name == name {
          return decl.clrName
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  ""
}

// Map a BCL SigType to its idiomatic Lyric source form.  Primitives use the
// Lyric names (`Int`, `Long`, …); the void return becomes `Unit`.  Named
// types fall through to their CLR FQN — the user can rewrite to a Lyric
// alias.  Unsupported shapes (generics, byref, …) render as `Any` so the
// stub still parses; the validation pass will surface the gap.
func sigTypeToLyricSource(s: in Mdr.SigType): String {
  val pb = Mdr.sigPrimByte(s)
  if pb >= 0 {
    if pb == 0x01 {
      "Unit"
    } else if pb == 0x02 {
      "Bool"
    } else if pb == 0x03 {
      "Char"
    } else if pb == 0x05 {
      "Byte"
    } else if pb == 0x08 {
      "Int"
    } else if pb == 0x0A {
      "Long"
    } else if pb == 0x0D {
      "Double"
    } else if pb == 0x0E {
      "String"
    } else if pb == 0x1C {
      "Any"
    } else {
      "Any"
    }
  } else {
    val fqn = Mdr.sigNamedFqn(s)
    if fqn.length > 0 {
      fqn
    } else {
      "Any"
    }
  }
}

// True when `s` mentions a Var / MVar / GenericInst / ByRef / Array shape
// that the scaffolder can't render cleanly.  Mirrors
// `sigHasGenericOrByRefMsil` in codegen.l; methods whose signature trips
// this are skipped (rather than rendered as `Any`-laden stubs that would
// almost certainly be wrong).
func sigIsRenderable(s: in Mdr.SigType): Bool {
  if Mdr.sigPrimByte(s) >= 0 {
    return true
  }
  if Mdr.sigNamedFqn(s).length > 0 {
    return true
  }
  false
}

// Build a stub `func name(p1: in T1, …): Ret { panic("not implemented") }`
// for one interface method.  `prefix` is the indent (whatever sits before
// the closing brace) so the inserted line aligns visually.
func stubFromNativeSig(sig: in FunctionSig, prefix: in String): String {
  var src = prefix + "func " + sig.name + "("
  var i = 0
  while i < sig.params.count {
    if i > 0 {
      src = src + ", "
    }
    src = src + renderParamAsLyricSource(sig.params[i])
    i = i + 1
  }
  src = src + "): "
  src = src + match sig.ret { case None -> "Unit"; case Some(te) -> renderTypeExprAsLyricSource(te) }
  src = src + " {\n" + prefix + "  panic(\"not implemented\")\n" + prefix + "}\n"
  src
}

// Build a stub from an extern (metadata-resolved) method signature.  The
// parameter names follow the standard `arg<N>` convention; metadata does
// not preserve parameter names on every reference-pack assembly.  Modes
// default to `in` for a value/class type — refining to out/inout is a
// follow-up tied to the existing ByRef gap in the validation pass.
func stubFromExternSig(m: in Mdr.ResolvedMethod, prefix: in String): String {
  var src = prefix + "func " + m.name + "("
  var i = 0
  while i < m.paramTypes.count {
    if i > 0 {
      src = src + ", "
    }
    src = src + "arg" + toString(i + 1) + ": in " + sigTypeToLyricSource(m.paramTypes[i])
    i = i + 1
  }
  src = src + "): " + sigTypeToLyricSource(m.returnType)
  src = src + " {\n" + prefix + "  panic(\"not implemented\")\n" + prefix + "}\n"
  src
}

// Convert a source-text byte offset to a 0-indexed LSP `Position` shape
// (`{"line": …, "character": …}`).  Walks the prefix once; offsets past
// end of source clamp to the EOF position.
func offsetToLspPosJson(source: in String, offset: in Int): String {
  var line = 0
  var col = 0
  var i = 0
  val n = if offset < source.length { offset } else { source.length }
  while i < n {
    if Str.charAtOrReplacement(source, i) == '\n' {
      line = line + 1
      col = 0
    } else {
      col = col + 1
    }
    i = i + 1
  }
  val fs: List[String] = newList()
  fs.add(jPair("line", jInt(line)))
  fs.add(jPair("character", jInt(col)))
  jObj(fs)
}

// LSP range that covers the closing `}` of the impl block AND any
// whitespace on the same line preceding it.  The code action replaces
// the whole range with `<stubs><indent>}` — so the indent before `}`
// isn't doubled in the output (and the single-line `impl … { }` shape
// still works because in that case there's no preceding whitespace on
// the `}`'s line).
func implCloseBraceRange(source: in String, decl: in ImplDecl): String {
  val endOff = decl.span.endPos.offset
  var braceOff = if endOff > 0 { endOff - 1 } else { 0 }
  var startOff = braceOff
  while startOff > 0 and (Str.charAtOrReplacement(source, startOff - 1) == ' ' or Str.charAtOrReplacement(source, startOff - 1) == '\t') {
    startOff = startOff - 1
  }
  val fs: List[String] = newList()
  fs.add(jPair("start", offsetToLspPosJson(source, startOff)))
  fs.add(jPair("end", offsetToLspPosJson(source, endOff)))
  jObj(fs)
}

// Detect the indent of the line that contains the impl block's closing `}`.
// Used so the synthesised stubs and the replacement `}` align visually
// with the rest of the impl body.  Defaults to "" when the line couldn't
// be identified (e.g. malformed source).
func implBodyIndent(source: in String, decl: in ImplDecl): String {
  val braceOff = if decl.span.endPos.offset > 0 { decl.span.endPos.offset - 1 } else { 0 }
  var lineStart = braceOff
  while lineStart > 0 and Str.charAtOrReplacement(source, lineStart - 1) != '\n' {
    lineStart = lineStart - 1
  }
  var p = lineStart
  while p < braceOff and (Str.charAtOrReplacement(source, p) == ' ' or Str.charAtOrReplacement(source, p) == '\t') {
    p = p + 1
  }
  source.substring(lineStart, p - lineStart)
}

// True when at least one `IMSig` member of the native iface lacks an impl.
// Names matched by simple string equality.
func nativeMissingMethods(iface: in InterfaceDecl, impls: in List[String]): List[FunctionSig] {
  val missing: List[FunctionSig] = newList()
  var i = 0
  while i < iface.members.count {
    match iface.members[i] {
      case IMSig(sig) -> {
        if not listContainsString(impls, sig.name) {
          missing.add(sig)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  missing
}

// Build the native-interface stub block for any methods missing from the
// impl.  Returns "" when nothing is missing.
func buildNativeStubBlock(iface: in InterfaceDecl, impls: in List[String], indent: in String): String {
  val missing = nativeMissingMethods(iface, impls)
  if missing.count == 0 {
    return ""
  }
  var block = ""
  var i = 0
  while i < missing.count {
    block = block + stubFromNativeSig(missing[i], indent + "  ")
    i = i + 1
  }
  block
}

// Build the extern-interface stub block for any abstract methods missing
// from the impl.  Reads the iface's metadata via `Mdr.inspectInterfaceTarget`;
// returns "" when the reference pack is absent or every required method is
// already implemented.  Skips methods whose signature mentions a generic /
// byref / array shape (D105 §B v1 covers flat signatures only).
func buildExternStubBlock(state: in LspState, externFqn: in String, impls: in List[String], indent: in String): String {
  ensureLspMetadataIndex(state)
  match mapGet(state.ffiTypeIndex, externFqn) {
    case None -> ""
    case Some(asmName) -> match mapGet(state.ffiPathIndex, asmName) {
      case None -> ""
      case Some(asmPath) -> match Mdr.inspectInterfaceTarget(asmPath, externFqn) {
        case None -> ""
        case Some(insp) -> {
          if not insp.isInterface {
            return ""
          }
          var block = ""
          var i = 0
          while i < insp.methods.count {
            val m = insp.methods[i]
            if m.isAbstract and not m.isStatic and not listContainsString(impls, m.name) {
              var renderable = sigIsRenderable(m.returnType)
              var pj = 0
              while pj < m.paramTypes.count and renderable {
                if not sigIsRenderable(m.paramTypes[pj]) {
                  renderable = false
                }
                pj = pj + 1
              }
              if renderable {
                block = block + stubFromExternSig(m, indent + "  ")
              }
            }
            i = i + 1
          }
          block
        }
      }
    }
  }
}

func handleCodeAction(state: in LspState, params: in String): String {
  val pdoc = parseJson(params)
  val root = rootElement(pdoc)
  val uri = match tryGetProperty(root, "textDocument") {
    case None -> ""
    case Some(td) -> match tryGetProperty(td, "uri") { case None -> ""; case Some(e) -> getString(e) }
  }
  val actions: List[String] = newList()
  match mapGet(state.store, uri) {
    case None -> {
    }
    case Some(cached) -> {
      val cachedCr = cached.checkResult
      val cachedFile = cachedCr.file
      val fileAnns = cachedFile.fileAnnotations
      match tryGetProperty(root, "context") {
        case None -> {
        }
        case Some(ctx) -> {
          match tryGetProperty(ctx, "diagnostics") {
            case None -> {
            }
            case Some(diagsArr) -> {
              var en = enumerateArray(diagsArr)
              var more = arrayMoveNext(en)
              while more {
                val diag = arrayCurrent(en)
                val diagCode = match tryGetProperty(diag, "code") { case None -> ""; case Some(e) -> getString(e) }
                val diagRange = match tryGetProperty(diag, "range") { case None -> "{}"; case Some(e) -> getRawText(e) }
                if diagCode == "V0009" {
                  val original = textAtJsonRange(cached.source, diagRange)
                  val newTextV9 = if original.length > 0 { "unsafe { " + original + " }" } else { "unsafe { }" }
                  actions.add(mkCodeAction(uri, "Wrap in unsafe { }", diagRange, newTextV9))
                }
                if diagCode == "V0003" {
                  match findProofRequiredAnn(fileAnns) {
                    case None -> {
                    }
                    case Some(ann) -> {
                      val annRange = toLspRange(ann.span)
                      actions.add(
                        mkCodeAction(
                          uri,
                          "Allow unsafe blocks (@proof_required(unsafe_blocks_allowed))",
                          annRange,
                          "@proof_required(unsafe_blocks_allowed)"
                        )
                      )
                    }
                  }
                }
                if diagCode == "V0007" or diagCode == "V0008" {
                  match findProofRequiredAnn(fileAnns) {
                    case None -> {
                    }
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
      // ── D105 §B: "Implement <Iface>" proactive code action ───────────────
      // Fires whenever the code-action request range overlaps an `impl Iface
      // for Record { … }` block.  Builds method stubs for any required iface
      // method that the user has not yet supplied:
      //   - Native interfaces (DKInterface): walk IMSig members.
      //   - Extern interfaces (DKExternType): consult the reference-pack
      //     metadata via `Mdr.inspectInterfaceTarget` (lazy index).
      // The replacement range is exactly the closing `}` so the inserted
      // stubs land just before it; the `}` is reprinted at the end of the
      // newText to keep the surrounding source intact.
      val reqRange = match tryGetProperty(root, "range") { case None -> "{}"; case Some(e) -> getRawText(e) }
      match findImplDeclAtRange(cachedFile, reqRange) {
        case None -> {
        }
        case Some(implDecl) -> {
          val ifaceSegs = implDecl.iface.head.segments
          if ifaceSegs.count > 0 {
            val ifaceName = ifaceSegs[ifaceSegs.count - 1]
            val impls = implMethodNames(implDecl)
            val indent = implBodyIndent(cached.source, implDecl)
            val nativeBlock = match lspFindInterfaceDecl(cachedCr.symbols, ifaceName) {
              case None -> ""
              case Some(ifaceDecl) -> buildNativeStubBlock(ifaceDecl, impls, indent)
            }
            val stubBlock = if nativeBlock.length > 0 {
              nativeBlock
            } else {
              val externFqn = lspFindExternTypeFqn(cachedCr.symbols, ifaceName)
              if externFqn.length > 0 {
                buildExternStubBlock(state, externFqn, impls, indent)
              } else {
                ""
              }
            }
            if stubBlock.length > 0 {
              val rng = implCloseBraceRange(cached.source, implDecl)
              val newText = stubBlock + indent + "}"
              actions.add(mkCodeAction(uri, "Implement " + ifaceName, rng, newText))
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
  te.add(jPair("range", range))
  te.add(jPair("newText", jStr(newText)))
  val edits: List[String] = newList()
  edits.add(jObj(te))
  val changes: List[String] = newList()
  changes.add(encodeString(uri) + ":" + jArr(edits))
  val edit: List[String] = newList()
  edit.add(jPair("changes", jObj(changes)))
  val action: List[String] = newList()
  action.add(jPair("title", jStr(title)))
  action.add(jPair("kind", jStr("quickfix")))
  action.add(jPair("edit", jObj(edit)))
  jObj(action)
}

func handleRename(state: in LspState, params: in String): String {
  val pdoc = parseJson(params)
  val root = rootElement(pdoc)
  val uri = jNested2Str(pdoc, "textDocument", "uri")
  val lineNum = jNested2Int(pdoc, "position", "line")
  val colNum = jNested2Int(pdoc, "position", "character")
  val newName = jRootStr(params, "newName")
  match mapGet(state.store, uri) {
    case None -> "{}"
    case Some(cached) -> {
      match identAtPos(cached.source, lineNum + 1, colNum + 1) {
        case None -> "{}"
        case Some(ident) -> {
          // Collect open URIs to rename across: current doc + its consumers.
          val uris: List[String] = newList()
          uris.add(uri)
          match mapGet(state.revDeps, uri) {
            case None -> {
            }
            case Some(cs) -> {
              var ci = 0
              while ci < cs.count {
                uris.add(cs[ci])
                ci = ci + 1
              }
            }
          }
          val changes: List[String] = newList()
          var ui = 0
          while ui < uris.count {
            val openUri = uris[ui]
            match mapGet(state.store, openUri) {
              case None -> {
              }
              case Some(od) -> {
                val spans = occurrences(od.source, ident)
                if spans.count > 0 {
                  val edits: List[String] = newList()
                  var si = 0
                  while si < spans.count {
                    val te: List[String] = newList()
                    te.add(jPair("range", toLspRange(spans[si])))
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
  val pdoc = parseJson(json)
  val root = rootElement(pdoc)
  val method = match tryGetProperty(root, "method") { case None -> ""; case Some(e) -> getString(e) }
  val id = jRaw(json, "id")
  val params = jRaw(json, "params")

  if method == "initialize" {
    collectMsgs(handleInitialize(state, id, params), acc)
  } else if method == "initialized" {
    // A client that registers watched files on request is asked to report
    // `.l` and `lyric.toml` changes (#8342); responses to the request carry
    // no method and are ignored.
    if state.dynamicWatch.count > 0 and state.dynamicWatch[0] and state.watchRegistered.count == 0 {
      state.watchRegistered.add(true)
      acc.add(watchedFilesRegistration())
    }
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
    // A manifest or a package file changed: the documents' builds and what
    // their proofs read are read again.
    for k in mapKeys(state.docContexts) {
      val _dropped = state.docContexts.remove(k)
    }
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
  } else if method.length == 0 {
    // A response to a request of the server's (`client/registerCapability`).
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
  val state = lspInit()
  val stdin = lspStdinOpen()
  var keepGoing = true
  while keepGoing {
    match lspReadFrame(stdin) {
      case LspReadEof -> {
        keepGoing = false
      }
      case LspReadError(message) -> {
        error("lsp: " + message)
        keepGoing = false
      }
      case LspReadFrame(json) -> {
        val responses = lspHandle(state, json)
        var i = 0
        while i < responses.count {
          writeLspFrame(responses[i])
          i = i + 1
        }
        if state.exit[0] {
          keepGoing = false
        }
      }
    }
  }
}
