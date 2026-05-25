// lyric/contract_meta.l — Lyric.ContractMeta bootstrap package.
//
// Implements the three functions that cli.l's `cmdPublicApiDiff` needs:
//   readFromFile(path)          — extract the Lyric.Contract JSON from a DLL
//   diffContracts(old, new)     — diff two JSON blobs; return rendered entries
//   hasBreakingChanges(entries) — pure check on the rendered entry list
//
// readFromFile and diffContracts shell out to `lyric --internal-contract-meta`
// which is handled by the F# bootstrap CLI.  ProcessCapture.runCapture is
// used so stdout can be captured without spawning a shell.
//
// Protocol:
//   read  <dll>                       → JSON string or "" (no contract)
//   diff  (old JSON and new JSON in
//          stdin, separated by \n---\n) → rendered entries separated by \n\n
//
// IN-PROCESS PARSER (#1229 Phase A): the `parseFromJson(json)`
// function parses the same Lyric.Contract JSON blob into structured
// `Contract` / `ContractDecl` records using `Std.Json` directly,
// without any subprocess hop.  Used by the self-hosted MSIL bridge's
// restored-dependency loader to consume a dep's contract surface
// without round-tripping through F#.  Mirrors
// `bootstrap/src/Lyric.Emitter/ContractMeta.fs::parseFromJson`.

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
// §2. readFromFile
// ─────────────────────────────────────────────────────────────────────────────

/// Read the embedded `Lyric.Contract` JSON resource from `dllPath`.
/// Returns `Some(json)` if the resource is present, `None` otherwise.
@stable(since="0.1")
pub func readFromFile(path: in String): Option[String] {
  val subcmd: List[String] = newList()
  subcmd.add("--internal-contract-meta")
  subcmd.add("read")
  subcmd.add(path)
  val output = runCapture(cliShellExe(), cliShellArgs(subcmd), "")
  val trimmed = Str.trim(output)
  if Str.isEmpty(trimmed) {
    None
  } else {
    Some(value = trimmed)
  }
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
