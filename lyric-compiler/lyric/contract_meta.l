// lyric/contract_meta.l — Lyric.ContractMeta bootstrap package.
//
// Public surface:
//   readFromFile(path)             — extract the `Lyric.Contract`
//                                    JSON resource from a DLL.
//   readAllContractsFromFile(path) — every `Lyric.Contract.<Pkg>`
//                                    resource in a bundled DLL.
//   parseFromJson(json)            — structured Contract / ContractDecl.
//   diffContracts(oldJson, newJson)— rendered diff entries.
//   hasBreakingChanges(entries)    — pure check on the diff entries.
//
// IN-PROCESS RESOURCE READS (#1229 Phase A.3): `readFromFile` and
// `readAllContractsFromFile` now use `Std.AssemblyResources` to walk
// embedded resources directly via `System.Reflection.Assembly`, with
// `Std.Encoding.tryDecodeUtf8` converting the bytes to JSON strings
// in-process.  Replaces the `lyric --internal-contract-meta read`
// subprocess shellout that the previous versions used.  Mirrors
// `bootstrap/src/Lyric.Emitter/ContractMeta.fs::readFromAssembly` and
// `readAllContractsFromAssembly`.
//
// IN-PROCESS PARSER (#1229 Phase A.1): `parseFromJson(json)` parses
// the JSON blob into structured records using `Std.Json` directly.
//
// SUBPROCESS RESIDUE: `diffContracts` is the only subprocess hop
// remaining in this package — porting the diff logic to Lyric is
// tracked under #1229 follow-ups.

@runtime_checked
package Lyric.ContractMeta

import Std.Core
import Std.Collections
import Std.Errors
import Std.File
import Std.Process
import Std.ProcessCapture
import Std.Environment as Environment
import Std.String as Str
import Std.Json
import Std.Encoding as Encoding
import Lyric.Lexer
import Lyric.Parser
import Std.AssemblyResources as AsmRes
import Lyric.CliShell as CliShell

// ─────────────────────────────────────────────────────────────────────────────
// §1. Subprocess helpers — thin wrappers over Lyric.CliShell.
// ─────────────────────────────────────────────────────────────────────────────
//
// Wrapper names are deliberately distinct from CliShell's public
// surface: when the local function and the cross-package alias share
// a name, the bootstrap resolver shadows the call site with the
// enclosing module's symbol, producing infinite recursion at runtime.

func cliShellExe(): String { CliShell.lyrExe() }

func cliShellArgs(subcmd: in List[String]): List[String] {
  CliShell.lyrArgs(subcmd)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. readFromFile / readAllContractsFromFile (in-process)
// ─────────────────────────────────────────────────────────────────────────────

/// One entry from a bundled DLL's per-package contract resources.
/// Single-package assemblies surface as one entry with
/// `packageName = ""` (legacy `Lyric.Contract` resource form).
/// Project-as-DLL bundles surface one entry per package
/// (`Lyric.Contract.<PackageName>` resources).
@stable(since="0.1")
pub record ContractEntry {
  packageName: String
  json:        String
}

// Decode a UTF-8 byte slice to a string, or None when the bytes aren't
// valid UTF-8.  The slice is a Lyric.Contract resource payload — JSON
// in practice — but this helper does no JSON-aware parsing; the name
// reflects the byte-level operation (#1251).
func decodeUtf8Resource(bytes: in slice[Byte]): Option[String] {
  Encoding.tryDecodeUtf8(bytes)
}

/// Read the embedded `Lyric.Contract` JSON resource from `dllPath`.
/// Returns `Some(json)` if the resource is present, `None` otherwise.
///
/// Walks the assembly's manifest resources directly via
/// `Std.AssemblyResources` — no subprocess.  When the assembly is a
/// project-as-DLL bundle (no top-level `Lyric.Contract`, only
/// `Lyric.Contract.<Pkg>` resources), callers should use
/// `readAllContractsFromFile` instead.
///
/// **Throws** on missing or unreadable `path` (the underlying BCL
/// `Assembly.LoadFrom` raises `FileNotFoundException` /
/// `BadImageFormatException`); callers that need a typed-error shape
/// should wrap the call in `try` (#1252).
@stable(since="0.1")
pub func readFromFile(path: in String): Option[String] {
  val ar = AsmRes.openAssembly(path)
  match AsmRes.tryReadResource(ar, "Lyric.Contract") {
    case None        -> None
    case Some(bytes) -> decodeUtf8Resource(bytes)
  }
}

/// Walk every `Lyric.Contract` / `Lyric.Contract.<Pkg>` resource in
/// `dllPath` and return each as a `ContractEntry`.  Single-package
/// assemblies surface as `[ContractEntry(packageName = "", json)]`;
/// project-as-DLL bundles surface one entry per package.  Returns
/// an empty list when no contract resources are present (e.g. a
/// non-Lyric assembly).
///
/// In-process via `Std.AssemblyResources`.  Mirrors F#
/// `Lyric.Emitter.ContractMeta.readAllContractsFromAssembly`.
@stable(since="0.1")
pub func readAllContractsFromFile(path: in String): List[ContractEntry] {
  val ar     = AsmRes.openAssembly(path)
  val names  = AsmRes.resourceNames(ar)
  val result: List[ContractEntry] = newList()

  // 1. Legacy single-package form: a bare `Lyric.Contract`.
  match AsmRes.tryReadResource(ar, "Lyric.Contract") {
    case Some(bytes) -> {
      match decodeUtf8Resource(bytes) {
        case Some(json) -> result.add(ContractEntry(packageName = "", json = json))
        case None       -> ()
      }
    }
    case None -> ()
  }

  // 2. Per-package form: `Lyric.Contract.<Pkg>`.  Strip the prefix to
  //    recover the package name.  Both forms can co-exist in
  //    pathological assemblies; we surface both.
  val prefix = "Lyric.Contract."
  var i = 0
  while i < names.length {
    val name = names[i]
    if Str.startsWith(name, prefix) {
      val pkgName = name.substring(prefix.length, name.length - prefix.length)
      match AsmRes.tryReadResource(ar, name) {
        case Some(bytes) -> {
          match decodeUtf8Resource(bytes) {
            case Some(json) ->
              result.add(ContractEntry(packageName = pkgName, json = json))
            case None -> ()
          }
        }
        case None -> ()
      }
    }
    i = i + 1
  }

  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. diffContracts
// ─────────────────────────────────────────────────────────────────────────────

/// Diff two Lyric.Contract JSON blobs.
/// Returns a list of rendered diff entries (each entry may be multi-line).
/// Entries are separated by blank lines in the subprocess output;
/// this function splits on `\n\n` and returns one entry per element.
@stable(since="0.1")
pub func diffContracts(oldJson: in String, newJson: in String): List[String] {
  val subcmd: List[String] = newList()
  subcmd.add("--internal-contract-meta")
  subcmd.add("diff")
  val stdin = oldJson + "\n---\n" + newJson
  val output = runCapture(cliShellExe(), cliShellArgs(subcmd), stdin)

  // Entries are separated by blank lines (\n\n).
  val rawParts = Str.split(output, "\n\n")
  val result: List[String] = newList()
  var i = 0
  while i < rawParts.length {
    val item = Str.trim(rawParts[i])
    if Str.isNotEmpty(item) {
      result.add(item)
    }
    i += 1
  }
  result
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. hasBreakingChanges
// ─────────────────────────────────────────────────────────────────────────────

/// Return true if any rendered entry represents a breaking change.
///
/// Breaking entries are those that:
///   - start with "  - " (removed item) and are not @experimental
///   - start with "  ~ " (changed signature) and are not @experimental
///   - contain "[breaking]" (contract-clause breaking change)
@stable(since="0.1")
pub func hasBreakingChanges(entries: in List[String]): Bool {
  var breaking = false
  for e in entries.toArray() {
    val isStructuralBreak =
      (Str.startsWith(e, "  - ") or Str.startsWith(e, "  ~ "))
      and not Str.contains(e, "[experimental]")
    val isContractBreak = Str.contains(e, "[breaking]")
    if isStructuralBreak or isContractBreak {
      breaking = true
    }
  }
  breaking
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. In-process JSON parser (#1229 Phase A)
// ─────────────────────────────────────────────────────────────────────────────
//
// Structured contract types mirroring the F# `Lyric.Emitter.ContractMeta`
// record shape (see `bootstrap/src/Lyric.Emitter/ContractMeta.fs`).
// `parseFromJson` produces these directly from a JSON string via
// `Std.Json`, with no subprocess hop, so the self-hosted MSIL bridge can
// consume restored-dependency contract surfaces in-process.

/// One serialised public declaration.  Mirrors F#
/// `Lyric.Emitter.ContractMeta.ContractDecl`.
@stable(since="0.1")
pub record ContractParam {
  name: String
  /// Signature type-string (e.g. "Int", "in slice[Byte]").
  ty:   String
}

@stable(since="0.1")
pub record ContractDecl {
  /// "func" | "record" | "union" | "enum" | "extern_type" | …
  kind:           String
  name:           String
  /// Canonical signature / shape, free-form.
  repr:           String
  /// @pure annotation present on this declaration.
  isPure:         Bool
  /// Stability level (D040 / Q011):
  ///   ""               — unannotated (treated as stable for enforcement).
  ///   "stable:X.Y"     — `@stable(since="X.Y")`.
  ///   "experimental"   — `@experimental`.
  stability:      String
  /// Source-level strings of the function's `requires:` clauses.
  /// Field name is `requiresClauses` (not `requires`) because
  /// `requires` is a Lyric reserved word.
  requiresClauses: List[String]
  /// Source-level strings of the function's `ensures:` clauses.
  /// Field name is `ensuresClauses` (not `ensures`) for the same reason.
  ensuresClauses:  List[String]
  /// Source-level string of the function's body (only populated when
  /// `isPure = true` and the body is an expression form suitable for
  /// one-level unfolding).
  body:            Option[String]
  /// Structured parameters: (name, type-string).
  params:          List[ContractParam]
}

/// Serialised contract for one emitted assembly.  Mirrors F#
/// `Lyric.Emitter.ContractMeta.Contract`.
@stable(since="0.1")
pub record Contract {
  packageName:   String
  version:       String
  /// Verification level: `runtime_checked` / `proof_required` /
  /// `proof_required(unsafe_blocks_allowed)` /
  /// `proof_required(checked_arithmetic)` / `axiom`.
  level:         String
  formatVersion: Int
  decls:         List[ContractDecl]
}

// JsonValueKind ordinals (matches `System.Text.Json.JsonValueKind`):
//   0=Undefined  1=Object  2=Array  3=String  4=Number  5=True  6=False  7=Null
val JK_OBJECT = 1
val JK_ARRAY  = 2
val JK_STRING = 3
val JK_NUMBER = 4
val JK_TRUE   = 5

func getStr(elem: in JsonElement, name: in String, fallback: in String): String {
  match tryGetProperty(elem, name) {
    case None    -> fallback
    case Some(e) -> {
      if valueKind(e) == JK_STRING { getString(e) } else { fallback }
    }
  }
}

func getOptStr(elem: in JsonElement, name: in String): Option[String] {
  match tryGetProperty(elem, name) {
    case None    -> None
    case Some(e) -> {
      if valueKind(e) == JK_STRING { Some(value = getString(e)) } else { None }
    }
  }
}

func getBool(elem: in JsonElement, name: in String): Bool {
  match tryGetProperty(elem, name) {
    case None    -> false
    case Some(e) -> valueKind(e) == JK_TRUE
  }
}

func getInt(elem: in JsonElement, name: in String, fallback: in Int): Int {
  match tryGetProperty(elem, name) {
    case None    -> fallback
    case Some(e) -> {
      if valueKind(e) == JK_NUMBER {
        match tryGetInt(e) {
          case Some(v) -> v
          case None    -> fallback
        }
      } else { fallback }
    }
  }
}

// Non-string elements coerce to "" — matches the F# `safeStr
// (inner.GetString()) ""` so format-1/2 round-trips stay byte-stable
// across the F# and self-hosted implementations.
func getStrArray(elem: in JsonElement, name: in String): List[String] {
  val result: List[String] = newList()
  match tryGetProperty(elem, name) {
    case None    -> result
    case Some(a) -> {
      if valueKind(a) == JK_ARRAY {
        var en = enumerateArray(a)
        while arrayMoveNext(en) {
          val v = arrayCurrent(en)
          if valueKind(v) == JK_STRING { result.add(getString(v)) }
          else                          { result.add("") }
        }
      }
      result
    }
  }
}

func getParams(elem: in JsonElement): List[ContractParam] {
  val result: List[ContractParam] = newList()
  match tryGetProperty(elem, "params") {
    case None    -> result
    case Some(a) -> {
      if valueKind(a) == JK_ARRAY {
        var en = enumerateArray(a)
        while arrayMoveNext(en) {
          val v = arrayCurrent(en)
          if valueKind(v) == JK_OBJECT {
            result.add(ContractParam(
              name = getStr(v, "name", ""),
              ty   = getStr(v, "type", "")))
          }
        }
      }
      result
    }
  }
}

func parseDecl(el: in JsonElement): ContractDecl {
  ContractDecl(
    kind            = getStr(el, "kind", ""),
    name            = getStr(el, "name", ""),
    repr            = getStr(el, "repr", ""),
    isPure          = getBool(el, "pure"),
    stability       = getStr(el, "stability", ""),
    requiresClauses = getStrArray(el, "requires"),
    ensuresClauses  = getStrArray(el, "ensures"),
    body            = getOptStr(el, "body"),
    params          = getParams(el))
}

// Walk the parsed root.  Returns None when the root isn't a JSON object
// (mirrors F# `_ -> None` for non-Object kinds).  Factored out so the
// `defer { disposeJson(doc) }` lives at function-body top level — the
// bootstrap emitter does not currently hoist defers from inside try
// blocks.
func parseFromRoot(root: in JsonElement): Option[Contract] {
  if valueKind(root) != JK_OBJECT { return None }

  val decls: List[ContractDecl] = newList()
  match tryGetProperty(root, "decls") {
    case None    -> ()
    case Some(a) -> {
      if valueKind(a) == JK_ARRAY {
        var en = enumerateArray(a)
        while arrayMoveNext(en) {
          val el = arrayCurrent(en)
          if valueKind(el) == JK_OBJECT { decls.add(parseDecl(el)) }
        }
      }
    }
  }

  Some(value = Contract(
    packageName   = getStr(root, "packageName", ""),
    version       = getStr(root, "version", "0.0.0"),
    level         = getStr(root, "level", "runtime_checked"),
    formatVersion = getInt(root, "formatVersion", 1),
    decls         = decls))
}

// Parse + walk + dispose, with no try/catch.  Caller wraps in try.
// Split off from `parseFromJson` to dodge a bootstrap-emitter limitation
// where `defer { ... }` inside `try { ... }` re-uses the same control-
// flow slot for the disposed value, producing a `null` deref at runtime.
// Tracked in #1241.
func parseAndWalk(json: in String): Option[Contract] {
  val doc = parseJson(json)
  defer { disposeJson(doc) }
  parseFromRoot(rootElement(doc))
}

/// Parse a `Lyric.Contract` JSON blob into a structured `Contract`.
/// Returns `None` if the JSON is malformed (syntactically invalid, root
/// not an object, empty/whitespace).  Mirrors F#
/// `Lyric.Emitter.ContractMeta.parseFromJson`; field defaults match
/// exactly so format-1 and format-2 payloads round-trip identically.
///
/// Used by the self-hosted MSIL bridge's restored-dependency loader.
@stable(since="0.1")
pub func parseFromJson(json: in String): Option[Contract] {
  if Str.isEmpty(Str.trim(json)) { return None }
  // `parseJson` is backed by `System.Text.Json.JsonDocument.Parse`,
  // which throws on syntactically invalid input — surface those as
  // `None` so callers don't need their own try/catch (matches the F#
  // `with _ -> None` clause).
  return try {
    parseAndWalk(json)
  } catch Bug as _ {
    None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. JSON serialisation
// ─────────────────────────────────────────────────────────────────────────────
//
// Render a parsed `Contract` back to the canonical JSON shape that
// `parseFromJson` accepts.  Mirrors F#
// `bootstrap/src/Lyric.Emitter/ContractMeta.fs::toJson`.  Used by the
// bridge to build the `Lyric.Contract` resource that gets embedded in
// every emitted assembly.

// Escape one character for inclusion in a JSON string literal.  Returns
// the escaped sequence (length ≥ 1).  Handles `"`, `\`, `\n`, `\r`, `\t`;
// every other character passes through verbatim.  Control characters
// below 0x20 are NOT escaped today — the contract JSON in practice
// only carries identifier-shaped strings (package / type / field
// names), so a full `\u00XX` escaper is unnecessary.  Matches the F#
// `ContractMeta.toJson` minimal-set policy (#1338).
func escapeJsonChar(c: in String): String {
  if c.length == 0 { return "" }
  if c == "\"" { return "\\\"" }
  if c == "\\" { return "\\\\" }
  if c == "\n" { return "\\n" }
  if c == "\r" { return "\\r" }
  if c == "\t" { return "\\t" }
  c
}

// Escape a string for inclusion in a JSON string literal.  Walks
// the characters via `Std.String.substring(i, 1)`.
@stable(since="0.1")
pub func escapeJson(s: in String): String {
  var result = ""
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    result = result + escapeJsonChar(c)
    i = i + 1
  }
  result
}

// Render `xs` as a JSON array of strings.
func renderStringArray(xs: in List[String]): String {
  var sb = "["
  var i = 0
  while i < xs.count {
    if i > 0 { sb = sb + "," }
    sb = sb + "\"" + escapeJson(xs[i]) + "\""
    i = i + 1
  }
  sb + "]"
}

// Render a `params` array as JSON.
func renderParams(ps: in List[ContractParam]): String {
  var sb = "["
  var i = 0
  while i < ps.count {
    if i > 0 { sb = sb + "," }
    sb = sb + "{\"name\":\"" + escapeJson(ps[i].name) + "\""
    sb = sb + ",\"type\":\"" + escapeJson(ps[i].ty) + "\"}"
    i = i + 1
  }
  sb + "]"
}

// Render one `ContractDecl` as a JSON object.  Mirrors F#
// `renderDecl`: only emits the optional fields when they carry
// non-empty content, so the JSON stays byte-stable against the
// F# producer.
func renderDecl(d: in ContractDecl): String {
  var sb = "{\"kind\":\"" + escapeJson(d.kind) + "\""
  sb = sb + ",\"name\":\"" + escapeJson(d.name) + "\""
  sb = sb + ",\"repr\":\"" + escapeJson(d.repr) + "\""
  if Str.isNotEmpty(d.stability) {
    sb = sb + ",\"stability\":\"" + escapeJson(d.stability) + "\""
  }
  if d.isPure {
    sb = sb + ",\"pure\":true"
  }
  if d.requiresClauses.count > 0 {
    sb = sb + ",\"requires\":" + renderStringArray(d.requiresClauses)
  }
  if d.ensuresClauses.count > 0 {
    sb = sb + ",\"ensures\":" + renderStringArray(d.ensuresClauses)
  }
  match d.body {
    case Some(body) -> { sb = sb + ",\"body\":\"" + escapeJson(body) + "\"" }
    case None       -> ()
  }
  if d.params.count > 0 {
    sb = sb + ",\"params\":" + renderParams(d.params)
  }
  sb + "}"
}

/// Render a `Contract` as JSON, preserving `c.formatVersion` (format-1
/// or format-2) so the output round-trips byte-stably through
/// `parseFromJson` without loss.  Mirrors
/// `bootstrap/src/Lyric.Emitter/ContractMeta.fs::toJson`.
@stable(since="0.1")
pub func contractToJson(c: in Contract): String {
  var sb = "{\n"
  sb = sb + "  \"formatVersion\": " + toString(c.formatVersion) + ",\n"
  sb = sb + "  \"packageName\": \"" + escapeJson(c.packageName) + "\",\n"
  sb = sb + "  \"version\": \"" + escapeJson(c.version) + "\",\n"
  sb = sb + "  \"level\": \"" + escapeJson(c.level) + "\",\n"
  sb = sb + "  \"decls\": [\n"
  var i = 0
  while i < c.decls.count {
    if i > 0 { sb = sb + ",\n" }
    sb = sb + "    " + renderDecl(c.decls[i])
    i = i + 1
  }
  sb + "\n  ]\n}\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Build a Contract from a parsed SourceFile
// ─────────────────────────────────────────────────────────────────────────────
//
// Walks a `Lyric.Parser.SourceFile` and produces a `Contract` describing
// its public surface.  The contract is what gets serialised via
// `contractToJson` and embedded as the `Lyric.Contract` resource in
// every Lyric-emitted assembly.
//
// Mirrors `bootstrap/src/Lyric.Emitter/ContractMeta.fs::buildContract`,
// but only handles the decl kinds the bootstrap parser currently emits
// at the source level: records, functions, unions, enums, interfaces,
// opaques, distinct types, type aliases.  `pub`-only filter matches the
// F# convention; non-pub items don't surface in the contract.
//
// `repr` is the source-level shape that `synthesiseSource` re-emits
// during restored-dep loading: a parseable Lyric declaration that the
// type-checker can re-consume.  For the bootstrap, we hand-render each
// kind (proper formatter integration is a follow-up).

// True iff `vis` is `Some(VisPub(_))`.
func isPubVis(vis: in Option[Visibility]): Bool {
  var isPub = false
  match vis {
    case Some(v) -> {
      match v {
        case VisPub(_)      -> { isPub = true }
        case VisInternal(_) -> ()
      }
    }
    case None -> ()
  }
  isPub
}

// Render a TypeExpr as a source-level string.  Coverage matches what
// the bootstrap parser accepts at the top level of a contract repr:
// every kind round-trips through `parse(synthesiseSource(...))`
// cleanly.
func renderTypeExpr(te: in TypeExpr): String {
  match te.kind {
    case TUnit              -> "Unit"
    case TNever             -> "Never"
    case TSelf              -> "Self"
    case TRef(path)         -> joinDots(path.segments)
    case TGenericApp(h, args) ->
      joinDots(h.segments) + "[" + renderTypeArgList(args) + "]"
    case TSlice(elem)       -> "slice[" + renderTypeExpr(elem) + "]"
    case TNullable(inner)   -> renderTypeExpr(inner) + "?"
    case TParen(inner)      -> renderTypeExpr(inner)
    case TArray(size, elem) ->
      "array[" + renderTypeArg(size) + ", " + renderTypeExpr(elem) + "]"
    case TTuple(ts)         -> "(" + renderTypeExprList(ts) + ")"
    case TFunction(ps, r)   ->
      "(" + renderTypeExprList(ps) + ") -> " + renderTypeExpr(r)
    case TRefined(p, _)     -> joinDots(p.segments)
    case TError             -> "Unit"
  }
}

// Render a comma-separated TypeExpr list.
func renderTypeExprList(ts: in List[TypeExpr]): String {
  var s = ""
  var i = 0
  while i < ts.count {
    if i > 0 { s = s + ", " }
    s = s + renderTypeExpr(ts[i])
    i = i + 1
  }
  s
}

// Render one `TypeArg` (either a type or a value-level expression).
// Integer literals (`array[4, Byte]` form) render faithfully so the
// repr round-trips through the parser; non-literal value expressions
// (rare in public APIs since they require const-foldable inputs)
// fall back to a `0` placeholder that at least parses.
func renderTypeArg(a: in TypeArg): String {
  match a {
    case TAType(te) -> renderTypeExpr(te)
    case TAValue(e) -> renderConstExpr(e)
  }
}

// Render a value-level expression used as a generic argument.  Only
// integer literals are supported today (`array[N, T]` size); other
// forms fall back to `0`.
func renderConstExpr(e: in Expr): String {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, _) -> toString(v)
        case _          -> "0"
      }
    }
    case _ -> "0"
  }
}

// Render a comma-separated TypeArg list.
func renderTypeArgList(args: in List[TypeArg]): String {
  var s = ""
  var i = 0
  while i < args.count {
    if i > 0 { s = s + ", " }
    s = s + renderTypeArg(args[i])
    i = i + 1
  }
  s
}

// Join dotted segments with ".".
func joinDots(segs: in List[String]): String {
  var s = ""
  var i = 0
  while i < segs.count {
    if i > 0 { s = s + "." }
    s = s + segs[i]
    i = i + 1
  }
  s
}

// Render one parameter as `<mode> <name>: <type>` (or just
// `<name>: <type>` when mode is the default `in` for safety: the
// bootstrap parser is happy with either form, and the contract
// surface is read-only anyway).
func renderParam(p: in Param): String {
  val modeStr = match p.mode {
    case PMIn    -> "in "
    case PMOut   -> "out "
    case PMInout -> "inout "
  }
  p.name + ": " + modeStr + renderTypeExpr(p.ty)
}

// Render one `GenericParam` as a source-level fragment:
// `GPType` → bare name; `GPValue` → `name: constraint`.
func renderGenericParam(gp: in GenericParam): String {
  match gp {
    case GPType(name, _)             -> name
    case GPValue(name, constraint, _) -> name + ": " + renderTypeExpr(constraint)
  }
}

// Render `Option[GenericParams]` as `""` (absent) or `"[T, U: Int]"`
// (one or more params).  Empty `params` list also collapses to `""`
// so the head form stays `pub record Name { … }` rather than
// `pub record Name[] { … }`.
func renderGenerics(g: in Option[GenericParams]): String {
  match g {
    case None -> ""
    case Some(gp) -> {
      if gp.params.count == 0 { return "" }
      var s = "["
      var i = 0
      while i < gp.params.count {
        if i > 0 { s = s + ", " }
        s = s + renderGenericParam(gp.params[i])
        i = i + 1
      }
      s + "]"
    }
  }
}

// Build the `pub record Name[T] { field1: T1, field2: T2 }` repr for
// a record decl.  Records with no fields emit `pub record Name {}`.
func reprForRecord(decl: in RecordDecl): String {
  var fields = ""
  var i = 0
  var emittedAny = false
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(f) -> {
        if emittedAny { fields = fields + ", " }
        fields = fields + f.name + ": " + renderTypeExpr(f.ty)
        emittedAny = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  "pub record " + decl.name + renderGenerics(decl.generics) + " { " + fields + " }"
}

// Build the `pub func name(p1: T1, p2: T2): Ret` repr for a function.
// Bodies are omitted — the parser accepts a bodyless head (treated as
// abstract / extern-style by the typechecker, which is sufficient for
// the synth+typecheck round-trip the bridge does).
func reprForFunc(fn: in FunctionDecl): String {
  var params = ""
  var i = 0
  while i < fn.params.count {
    if i > 0 { params = params + ", " }
    params = params + renderParam(fn.params[i])
    i = i + 1
  }
  val retStr = match fn.ret {
    case Some(t) -> ": " + renderTypeExpr(t)
    case None    -> ""
  }
  "pub func " + fn.name + renderGenerics(fn.generics) +
    "(" + params + ")" + retStr
}

// Build the `pub union Name { case A, case B(x: T) }` repr for a union.
func reprForUnion(decl: in UnionDecl): String {
  var cases = ""
  var i = 0
  while i < decl.cases.count {
    if i > 0 { cases = cases + ", " }
    val c = decl.cases[i]
    if c.fields.count == 0 {
      cases = cases + "case " + c.name
    } else {
      var fs = ""
      var j = 0
      while j < c.fields.count {
        if j > 0 { fs = fs + ", " }
        match c.fields[j] {
          case UFNamed(n, ty, _) -> { fs = fs + n + ": " + renderTypeExpr(ty) }
          case UFPos(ty, _)      -> { fs = fs + renderTypeExpr(ty) }
        }
        j = j + 1
      }
      cases = cases + "case " + c.name + "(" + fs + ")"
    }
    i = i + 1
  }
  "pub union " + decl.name + renderGenerics(decl.generics) + " { " + cases + " }"
}

// Build the `pub enum Name { A, B, C }` repr.  EnumDecls carry just
// case names in the bootstrap parser.
func reprForEnum(decl: in EnumDecl): String {
  var cases = ""
  var i = 0
  while i < decl.cases.count {
    if i > 0 { cases = cases + ", " }
    cases = cases + decl.cases[i].name
    i = i + 1
  }
  "pub enum " + decl.name + " { " + cases + " }"
}

// Build the head-only `impl <Iface> for <Target> {}` repr for a restored
// impl block.  The empty body re-parses + re-typechecks in isolation; the
// consumer recovers the impl's method signatures from the package's already-
// emitted `interface` decl (#1602).  Returns `None` when the impl target is
// not a plain type reference (e.g. an inherent impl on a generic application)
// — those don't contribute a cross-package interface binding the current
// registration handles, so they are omitted rather than emitting a malformed
// repr.
func reprForImplHead(decl: in ImplDecl): Option[String] {
  val targetName = implTargetSimpleName(decl)
  if Str.isEmpty(targetName) { return None }
  val ifaceName = joinDots(decl.iface.head.segments)
  if Str.isEmpty(ifaceName) { return None }
  Some(value = "impl " + ifaceName + " for " + targetName + " {}")
}

// The contract-decl `name` for an impl: the simple target type name (the type
// whose method table the consumer needs to populate).
func implReprName(decl: in ImplDecl): String {
  val t = implTargetSimpleName(decl)
  if Str.isEmpty(t) { "__impl" } else { t }
}

// Extract the simple (last-segment) name of an impl's target type, or "" when
// the target is not a plain `TRef` / `TGenericApp` head.
func implTargetSimpleName(decl: in ImplDecl): String {
  match decl.target.kind {
    case TRef(path)          -> lastSegOf(path.segments)
    case TGenericApp(h, _)   -> lastSegOf(h.segments)
    case _                   -> ""
  }
}

func lastSegOf(segs: in List[String]): String {
  if segs.count == 0 { "" } else { segs[segs.count - 1] }
}

// Build the `pub interface Name { ... }` repr with each abstract
// method signature.  Default-method bodies and associated types are
// elided (their full form requires walking ImplMember).
func reprForInterface(decl: in InterfaceDecl): String {
  var members = ""
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMSig(sig) -> {
        if Str.isNotEmpty(members) { members = members + "; " }
        members = members + reprForFunctionSig(sig)
      }
      case _ -> ()
    }
    i = i + 1
  }
  "pub interface " + decl.name + renderGenerics(decl.generics) +
    " { " + members + " }"
}

// Render a FunctionSig (interface-method head form, no body).
func reprForFunctionSig(sig: in FunctionSig): String {
  var params = ""
  var i = 0
  while i < sig.params.count {
    if i > 0 { params = params + ", " }
    params = params + renderParam(sig.params[i])
    i = i + 1
  }
  val retStr = match sig.ret {
    case Some(t) -> ": " + renderTypeExpr(t)
    case None    -> ""
  }
  "func " + sig.name + renderGenerics(sig.generics) +
    "(" + params + ")" + retStr
}

// `pub type Name = <underlying>` for distinct types.  Renders the
// declared underlying type rather than guessing `Int`.
func reprForDistinct(decl: in DistinctTypeDecl): String {
  "pub type " + decl.name + renderGenerics(decl.generics) +
    " = " + renderTypeExpr(decl.underlying)
}

// `pub opaque type Name { f1: T1, ... }` — emits the structural
// payload so cross-package consumers see the same field set the
// emitter encoded.  Opaque types without a body emit
// `pub opaque type Name {}`.
func reprForOpaque(decl: in OpaqueTypeDecl): String {
  var fields = ""
  var emittedAny = false
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case OMField(f) -> {
        if emittedAny { fields = fields + ", " }
        fields = fields + f.name + ": " + renderTypeExpr(f.ty)
        emittedAny = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  "pub opaque type " + decl.name + renderGenerics(decl.generics) +
    " { " + fields + " }"
}

// `pub alias Name = <rhs>` — renders the actual aliased TypeExpr.
func reprForTypeAlias(decl: in TypeAliasDecl): String {
  "pub alias " + decl.name + renderGenerics(decl.generics) +
    " = " + renderTypeExpr(decl.rhs)
}

// Construct a default ContractDecl with the three required fields and
// everything else zeroed.  Mirrors F# `ContractDecl.basic`.
func basicDecl(kind: in String, name: in String, repr: in String): ContractDecl {
  ContractDecl(
    kind            = kind,
    name            = name,
    repr            = repr,
    isPure          = false,
    stability       = "",
    requiresClauses = newList(),
    ensuresClauses  = newList(),
    body            = None,
    params          = newList())
}

// Find a single-segment file-level annotation by name.  Returns the
// first matching annotation (file-level `@axiom`, `@proof_required`,
// `@runtime_checked` are mutually exclusive in practice but we
// surface the first hit per the F# convention).
func findFileAnnotation(file: in SourceFile, name: in String): Option[Annotation] {
  val anns = file.fileAnnotations
  var i = 0
  while i < anns.count {
    val a = anns[i]
    if a.name.segments.count == 1 and a.name.segments[0] == name {
      return Some(value = a)
    }
    i = i + 1
  }
  None
}

// Inspect a `@proof_required(...)` annotation for one of the two
// recognised bare-identifier modifiers (`unsafe_blocks_allowed`,
// `checked_arithmetic`).  Returns "" when no recognised modifier
// is present.  Mirrors F# `levelOfFile`'s nested match.
func proofRequiredModifier(ann: in Annotation): String {
  var modifier = ""
  var i = 0
  while i < ann.args.count {
    if Str.isEmpty(modifier) {
      match ann.args[i] {
        case ABare(name, _) -> { modifier = name }
        case _              -> ()
      }
    }
    i = i + 1
  }
  modifier
}

/// Determine the verification level for a SourceFile from its file-
/// level annotations.  Mirrors `bootstrap/src/Lyric.Emitter/ContractMeta.fs::levelOfFile`:
/// `@axiom` wins → "axiom"; otherwise `@proof_required(modifier?)`
/// → "proof_required" or "proof_required(<modifier>)"; otherwise
/// "runtime_checked" (the default for both `@runtime_checked` and
/// unannotated files).
@stable(since="0.1")
pub func levelOfFile(file: in SourceFile): String {
  match findFileAnnotation(file, "axiom") {
    case Some(_) -> "axiom"
    case None -> {
      match findFileAnnotation(file, "proof_required") {
        case Some(ann) -> {
          val m = proofRequiredModifier(ann)
          if m == "unsafe_blocks_allowed" { "proof_required(unsafe_blocks_allowed)" }
          else if m == "checked_arithmetic" { "proof_required(checked_arithmetic)" }
          else { "proof_required" }
        }
        case None -> "runtime_checked"
      }
    }
  }
}

/// Build a `Contract` from a parsed `SourceFile`.  Walks each
/// top-level item and emits a `ContractDecl` for every `pub` item
/// of a supported kind (record, func, union, enum, interface,
/// opaque, distinct, alias).  Non-pub items are filtered out.
///
/// `version` is the manifest-declared semver string for this
/// package — the bridge sources it from `Lyric.Manifest` when one
/// is available, and passes `"0.0.0"` for ad-hoc compiles where no
/// manifest is in scope.  `level` is computed from the source's
/// file-level annotations via `levelOfFile` so every emitted DLL
/// records its declared verification level accurately.
///
/// Used by the self-hosted MSIL bridge to build the `Lyric.Contract`
/// resource payload before assembly emission.
@stable(since="0.1")
pub func buildContractFromFile(file: in SourceFile, version: in String): Contract {
  val decls: List[ContractDecl] = newList()
  var i = 0
  while i < file.items.count {
    val it = file.items[i]
    if isPubVis(it.visibility) {
      match it.kind {
        case IRecord(r) ->
          decls.add(basicDecl("record", r.name, reprForRecord(r)))
        case IFunc(f) ->
          decls.add(basicDecl("func", f.name, reprForFunc(f)))
        case IUnion(u) ->
          decls.add(basicDecl("union", u.name, reprForUnion(u)))
        case IEnum(e) ->
          decls.add(basicDecl("enum", e.name, reprForEnum(e)))
        case IInterface(ix) ->
          decls.add(basicDecl("interface", ix.name, reprForInterface(ix)))
        case IDistinctType(d) ->
          decls.add(basicDecl("distinct", d.name, reprForDistinct(d)))
        case IOpaque(o) ->
          decls.add(basicDecl("opaque", o.name, reprForOpaque(o)))
        case ITypeAlias(a) ->
          decls.add(basicDecl("alias", a.name, reprForTypeAlias(a)))
        case _ -> ()
      }
    }
    // `impl` blocks carry no visibility token (they are not pub/private), so
    // they sit outside the `isPubVis` guard above.  Record the impl→interface
    // binding so a cross-package consumer learns which interface a public
    // record satisfies — the consumer needs it to register the record's
    // instance methods (it dispatches `store.set(...)` on the concrete record
    // type, keyed `<pkg>.<Record>/<method>`, which is absent from the type
    // surface otherwise) (#1602).  The repr is the head-only `impl I for T {}`
    // form: an empty body re-parses + re-typechecks cleanly, and the method
    // signatures are recovered from the already-emitted `interface` decl.
    match it.kind {
      case IImpl(idecl) -> {
        match reprForImplHead(idecl) {
          case Some(repr) -> decls.add(basicDecl("impl", implReprName(idecl), repr))
          case None       -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  Contract(
    packageName   = joinDots(file.packageDecl.path.segments),
    version       = version,
    level         = levelOfFile(file),
    formatVersion = 2,
    decls         = decls)
}
