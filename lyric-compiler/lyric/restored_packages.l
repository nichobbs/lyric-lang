//! lyric/restored_packages.l — Lyric.RestoredPackages bootstrap package.
//!
//! Walks a restored-dependency DLL on disk and returns its embedded
//! `Lyric.Contract` surface(s) as structured artifacts the
//! self-hosted MSIL bridge will consume to resolve cross-package
//! references against compiled deps without re-parsing source.
//!
//! Mirrors `bootstrap/src/Lyric.Emitter/RestoredPackages.fs::loadRestoredPackage`:
//!
//!   * Single-package DLL (one `Lyric.Contract` resource) → one
//!     `RestoredArtifact` with `packageName` taken from the contract
//!     JSON's own `packageName` field (since the legacy resource is
//!     unnamed).
//!   * Project-as-DLL bundle (N `Lyric.Contract.<Pkg>` resources) →
//!     one artifact per resource, keyed by the suffix.
//!
//! Used by the bridge (Phase A.3.2+) to thread restored types and
//! functions into `CodegenCtx`'s symbol tables so a consumer package
//! importing a restored dep can resolve its `pub` surface without
//! the dep's source.
@runtime_checked
package Lyric.RestoredPackages

import Std.Core
import Std.Collections
import Std.File as File
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.ContractMeta as Meta

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public types
// ─────────────────────────────────────────────────────────────────────────────
/// One restored package's externally-visible contract surface,
/// resolved from a compiled `.dll` on disk.
///
/// `dllPath` is the absolute path the DLL was loaded from — the
/// bridge uses it as the `AssemblyRef` target when emitting
/// cross-assembly `TypeRef` / `MemberRef` rows.  `contract` is the
/// fully-parsed `Lyric.ContractMeta.Contract` (records / functions /
/// unions etc. with their public signatures).
@stable(since = "0.1")
pub record RestoredArtifact {
  packageName: String
  version: String
  dllPath: String
  contract: Meta.Contract
}

/// Errors that surface from `loadRestoredPackage`.  Each carries
/// enough info to render a useful diagnostic at the caller's site.
@stable(since = "0.1")
pub union RestoredLoadError {
  /// The path provided doesn't exist on disk.
  case DllMissing(path: String)
  /// The DLL exists but doesn't carry any `Lyric.Contract` /
  /// `Lyric.Contract.<Pkg>` resource — likely a non-Lyric assembly
  /// or an older Lyric build that pre-dates the contract carrier.
  case NoContractResource(path: String)
  /// A `Lyric.Contract` resource is present but its JSON fails to
  /// parse (`Lyric.ContractMeta.parseFromJson` returned `None`).
  /// `pkgKey` is the resource's package-suffix ("" for the legacy
  /// single-package form).
  case MalformedContract(path: String, pkgKey: String)
  /// The synthesised contract source failed to parse or type-check.
  /// `diags` carries the diagnostics so the caller can render them.
  case SynthesisDiagnostics(path: String, diags: List[Diagnostic])
}

/// Render a `RestoredLoadError` as a short single-line string for
/// CLI diagnostics / error propagation.
@stable(since = "0.1")
pub func errorMessage(e: in RestoredLoadError): String {
  match e {
    case DllMissing(p) -> "restored DLL not found: " + p
    case NoContractResource(p) -> "restored DLL has no Lyric.Contract resource (not a Lyric assembly?): " + p
    case MalformedContract(p, k) -> "restored DLL " + p + ": Lyric.Contract" + (if Str.isEmpty(k) { "" } else { "." + k }) + " resource is not valid JSON"
    case SynthesisDiagnostics(p, ds) -> "restored DLL " + p + ": synthesised contract source did not type-check (" + Str.fromInt(ds.count) + " diagnostic" + (if ds.count == 1 { "" } else { "s" }) + ")" + (if ds.count > 0 { "; first: " + ds[0].message } else { "" })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Loader
// ─────────────────────────────────────────────────────────────────────────────
/// Load every `Lyric.Contract` / `Lyric.Contract.<Pkg>` resource
/// from `dllPath`, parse each into a `RestoredArtifact`, and return
/// the list.  Returns `Err(DllMissing)` when the file doesn't exist,
/// `Err(NoContractResource)` when the DLL has none of the expected
/// resources, and `Err(MalformedContract)` if any one resource
/// parses to None.
///
/// Single-package DLLs surface as a one-element list; project-as-DLL
/// bundles surface one artifact per package.
@stable(since = "0.1")
pub func loadRestoredPackage(dllPath: in String): Result[List[RestoredArtifact], RestoredLoadError] {
  // The pre-flight `fileExists` check carries a narrow TOCTOU window —
  // the file could be deleted between the check and the read — but
  // `readAllContractsFromFile` throws on a vanished file, which would
  // surface here as an unhandled exception.  Living with the race for
  // now because Lyric's `catch Exception` shape changes the try
  // expression's value in a way that requires inlining the rest of
  // the function into the success arm; tracked in #1255.
  if not File.fileExists(dllPath) {
    return Err(error = DllMissing(path = dllPath))
  }

  val entries = Meta.readAllContractsFromFile(dllPath)
  if entries.count == 0 {
    return Err(error = NoContractResource(path = dllPath))
  }

  val artifacts: List[RestoredArtifact] = newList()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    match Meta.parseFromJson(e.json) {
      case None -> return Err(error = MalformedContract(path = dllPath, pkgKey = e.packageName))
      case Some(c) -> {
        // For the legacy single-package form the resource name's
        // package suffix is "" — recover the canonical package name
        // from the contract JSON's own `packageName` field.  For
        // the project-as-DLL form, the resource-suffix name and
        // the contract's `packageName` should match; prefer the
        // contract's (it's the source of truth).
        val pkgName = if Str.isNotEmpty(c.packageName) { c.packageName } else { e.packageName }
        artifacts.add(RestoredArtifact(packageName = pkgName, version = c.version, dllPath = dllPath, contract = c))
      }
    }
    i = i + 1
  }

  Ok(value = artifacts)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Source synthesis
// ─────────────────────────────────────────────────────────────────────────────
//
// Walk a parsed `Contract` and re-emit the source-level shape of its
// public surface as a single Lyric source string.  Each declaration's
// `Repr` field already IS the source-level form, so synthesis is
// mostly concatenation.
//
// `preamble` carries extern-type / opaque-type / interface decls from
// sibling packages whose types appear in this package's signatures —
// without them, the standalone re-typecheck of the synthesised source
// would fail with `T0010 unknown type name 'X'`.
//
// Mirrors `bootstrap/src/Lyric.Emitter/RestoredPackages.fs::synthesiseSource`.
// Render one decl's source-level form.  Interface reprs arrive in two
// shapes depending on which contract writer produced the DLL: the
// self-hosted writer (`contract_meta.l::reprForInterface`) emits the
// full `pub interface I { ...method sigs... }` body, while the legacy
// F# writer (`ContractMeta.fs`) emits only the head `pub interface I`.
// Append an empty block ONLY for the head-only form — doing so for a
// repr that already carries its body produces `... } {}`, a bare
// trailing block that fails to re-parse as an item declaration (#1596).
// Every non-interface decl kind already includes its full shape.
//
// Detection assumption: an interface head never contains `{` (no inline
// type-parameter bounds or `where` clauses are emitted into the head by
// either writer today).  An explicit `hasBody: Bool` field on `ContractDecl`
// would be more robust if a future repr extension puts braces in the
// head — tracked alongside other contract-metadata refactors.
func renderDecl(d: in Meta.ContractDecl): String {
  if d.kind == "interface" and d.repr.indexOf("{") < 0 {
    d.repr + " {}\n"
  } else {
    d.repr + "\n"
  }
}

// Render a preamble decl — a sibling package's type used only so this
// package's signatures resolve its name.  Enums and unions are emitted
// WITHOUT their cases (`pub enum Name {}` / `pub union Name[T, E] {}`): a
// signature references only the type's NAME, never its variants, and a
// bare case name (`case Header`, `case Ok`) would otherwise be registered
// as a package-level symbol that collides — once every package is
// flattened into one synthesised source (#2514) — with an unrelated
// sibling type of the same name (`Web.Header` record vs
// `Web.OpenApi.ParameterLocation.Header` case) or with another package's
// case of the same name (`Std.Core.Result.Ok` vs
// `Grpc.Types.GrpcStatusCode.Ok`).  The head (including any generic
// parameter list) is preserved by cutting the repr at its first `{`; the
// owning package keeps its full cases via `renderDecl` on `contract.decls`.
func renderPreambleDecl(d: in Meta.ContractDecl): String {
  if d.kind == "enum" or d.kind == "union" {
    val braceIdx = d.repr.indexOf("{")
    if braceIdx >= 0 {
      return Str.substring(d.repr, 0, braceIdx) + "{}\n"
    }
    return d.repr + " {}\n"
  }
  renderDecl(d)
}

/// Synthesise a Lyric source file from a `Contract` + optional
/// preamble.  The result is parseable by the standard
/// `Lyric.Parser.parse` and type-checkable in isolation.  Function
/// bodies in the contract are stubs (`= ()` axiom-style); every
/// public type and signature is preserved verbatim from the contract's
/// `Repr` strings.
@stable(since = "0.1")
pub func synthesiseSource(contract: in Meta.Contract, preamble: in List[Meta.ContractDecl]): String {
  var sb = "package " + contract.packageName + "\n\n"
  // Preamble decls first — typically extern types / opaques from
  // sibling packages whose names appear in this package's signatures.
  var pi = 0
  while pi < preamble.count {
    sb = sb + renderPreambleDecl(preamble[pi])
    pi = pi + 1
  }
  // Blank line between preamble and own-decls when both are non-empty,
  // so the re-parsed source visually separates the two sections (#1260).
  if preamble.count > 0 and contract.decls.count > 0 {
    sb = sb + "\n"
  }
  // Then the contract's own decls.
  var di = 0
  while di < contract.decls.count {
    sb = sb + renderDecl(contract.decls[di])
    di = di + 1
  }
  sb
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Synthesise + re-parse + re-typecheck (#1229 Phase A.3.3.b)
// ─────────────────────────────────────────────────────────────────────────────
//
// Compose `synthesiseSource` with `Lyric.Parser.parse` and
// `Lyric.TypeChecker.check` so a `RestoredArtifact` (the contract +
// path pair produced by `loadRestoredPackage`) becomes a fully-
// typed `SynthesisedArtifact` carrying the parsed `SourceFile` and
// `CheckResult` the bridge will plumb into `CodegenCtx` in Phase
// A.3.3.c.
//
// Mirrors `bootstrap/src/Lyric.Emitter/RestoredPackages.fs::artifactOfContract`.
/// One restored package augmented with its parsed Lyric source and
/// type-checker output.  `source` is the synthesised `SourceFile`
/// (`Lyric.Parser` AST shape); `checkResult` carries the
/// `SymbolTable` + signatures consumers need to resolve cross-
/// package references against this package.
@stable(since = "0.1")
pub record SynthesisedArtifact {
  packageName: String
  version: String
  dllPath: String
  contract: Meta.Contract
  source: SourceFile
  checkResult: CheckResult
  // Known stdlib type anchors that legitimately appear unresolved in a
  // standalone contract type-check.  T0010 "unknown type name 'X'" for
  // one of these is expected — the imports inside the contract aren't
  // preserved by the synthesised source (the contract Repr loses
  // cross-package qualifications), so we whitelist the names that
  // every Lyric stdlib consumer would have in scope.  Matches
  // `bootstrap/src/Lyric.Emitter/RestoredPackages.fs::knownStdlibTypeNames`.
}

func isWhitelistedStdlibType(name: in String): Bool {
  name == "Option" or name == "Result" or name == "List" or name == "Map" or name == "Set" or name == "Iter" or
    name == "Slice" or
    name == "String" or
    name == "Int" or
    name == "Bool" or
    name == "Double" or
    name == "Long" or
    name == "Byte" or
    name == "Char" or
    name == "Unit" or
    name == "Never" or
    name == "Float" or
    name == "IOError" or
    name == "ParseError" or
    name == "ParseResult" or
    name == "Instant" or
    name == "Duration" or
    name == "Clock" or
    name == "Uuid" or
    name == "JsonValue" or
    name == "Diagnostic"
}

// Extract the name from a T0010 message of shape `unknown type name 'X'`.
// Returns "" when the message doesn't carry quoted text in the
// expected positions.  Couples to the diagnostic-message format from
// `Lyric.TypeChecker.Resolver`.
func extractT0010Name(msg: in String): String {
  val openQ = msg.indexOf("'")
  if openQ < 0 {
    return ""
  }
  // Scan for the next quote AFTER openQ.
  var i = openQ + 1
  while i < msg.length {
    if msg.substring(i, 1) == "'" {
      return msg.substring(openQ + 1, i - openQ - 1)
    }
    i = i + 1
  }
  ""
}

// True iff `d` is a T0010 about a whitelisted stdlib anchor.
func isWhitelistedT0010(d: in Diagnostic): Bool {
  if d.code != "T0010" {
    return false
  }
  val name = extractT0010Name(d.message)
  if Str.isEmpty(name) {
    return false
  }
  isWhitelistedStdlibType(name)
}

// True iff `d` is one of the diagnostic codes that cannot meaningfully apply
// to a synthesised contract source — these are whitelisted so they do not turn
// a successful synthesis into a failure.  The synthesised source reconstructs a
// restored package's public API from metadata: `impl` blocks are bare type
// anchors and function bodies are stubs, so checks that depend on real bodies /
// call sites legitimately "fail" here even though the package compiled cleanly
// originally.
//
//   T0085 — `out`/`inout` argument must be a mutable l-value (call sites)
//   T0086 — `out` parameter never assigned (stub bodies assign nothing)
//   T0087 — reassigning an immutable binding
//   T0098 — `impl` missing an interface method (anchor impls omit them)
//   T0099 — `impl` method arity mismatch
//   T0100 — opaque construction outside its package
//   T0101 — constructor names an unknown field
//   T0102 — opaque representation pattern-match outside its package
func isSynthesizedBodyDiag(d: in Diagnostic): Bool {
  d.code == "T0085" or d.code == "T0086" or d.code == "T0087" or d.code == "T0098" or d.code == "T0099" or
    d.code == "T0100" or
    d.code == "T0101" or
    d.code == "T0102"
}

// True iff `d` is a DiagError (vs DiagWarning).
func isErrorDiag(d: in Diagnostic): Bool {
  var isErr = false
  match d.severity {
    case DiagError -> {
      isErr = true
    }
    case DiagWarning -> ()
  }
  isErr
}

// Keep error diagnostics that are NOT whitelisted T0010 stdlib
// anchors.  Warnings are dropped — the bridge only cares whether a
// real (non-whitelisted) error fired; warning-only sets count as
// "synthesise succeeded" (#1264).
func filterRealErrors(diags: in List[Diagnostic]): List[Diagnostic] {
  val kept: List[Diagnostic] = newList()
  var i = 0
  while i < diags.count {
    val d = diags[i]
    if isErrorDiag(d) and not isWhitelistedT0010(d) and not isSynthesizedBodyDiag(d) {
      kept.add(d)
    }
    i = i + 1
  }
  kept
}

/// Synthesise a `RestoredArtifact` into a fully-parsed + type-checked
/// `SynthesisedArtifact`.  Returns `Err(SynthesisDiagnostics)` if
/// either parsing or type-checking surfaces real errors (whitelisted
/// stdlib-anchor `T0010`s are filtered out — see
/// `isWhitelistedStdlibType` for the rationale).
///
/// `preamble` carries extern-type / opaque decls from sibling
/// packages whose names appear in this package's signatures.  Pass
/// an empty list for single-package DLLs (no siblings); the bundled-
/// DLL caller (#1229 Phase A.3.3.c) will pass the union of every
/// sibling's type-declaring decls.
@stable(since = "0.1")
pub func synthesiseArtifact(
  art: in RestoredArtifact, preamble: in List[Meta.ContractDecl]
): Result[SynthesisedArtifact, RestoredLoadError] {
  // Validation source includes the sibling-type `preamble` so the
  // standalone re-typecheck resolves cross-package references in this
  // package's signatures (e.g. `originX(p: Point)` where `Point` is
  // declared by a sibling restored DLL).
  val src = synthesiseSource(art.contract, preamble)
  val pr = parse(src)

  // Parse errors are always real — contract Repr should be valid
  // Lyric source by construction.
  val parseErrors = filterRealErrors(pr.diagnostics)
  if parseErrors.count > 0 {
    return Err(error = SynthesisDiagnostics(path = art.dllPath, diags = parseErrors))
  }

  // Contract-surface check: skips declaration-position type validation
  // (#1228) because the sibling-type preamble is deliberately partial —
  // see `Lyric.TypeChecker.checkContractSurface`.
  val cr = checkContractSurface(pr.file)
  val checkErrors = filterRealErrors(cr.diagnostics)
  if checkErrors.count > 0 {
    return Err(error = SynthesisDiagnostics(path = art.dllPath, diags = checkErrors))
  }

  // The STORED `source` carries only this package's OWN declarations —
  // the preamble was a validation aid, not part of this package's
  // surface.  Including it would double-register the sibling types in
  // the consuming bridge's item pool (one copy here, one in the
  // sibling's own artifact), corrupting type resolution.  When
  // `preamble` is empty (every caller before cross-DLL preamble
  // support) this is byte-identical to `pr.file`, so the change is
  // backward-compatible.  Cross-package references in the own decls
  // resolve at bundle time against the sibling artifacts' items.
  val ownSrc = synthesiseSource(art.contract, emptyPreamble())
  val ownPr = parse(ownSrc)

  // The own-source parse should always succeed (it is the same content that
  // type-checked cleanly above, minus the preamble header).  Defensively
  // check for parse errors before storing the AST, so a future edge case
  // does not silently register a malformed file in the bundle's item pool.
  if ownPr.diagnostics.count > 0 {
    return Err(error = SynthesisDiagnostics(path = art.dllPath, diags = ownPr.diagnostics))
  }

  Ok(
    value = SynthesisedArtifact(
      packageName = art.packageName,
      version = art.version,
      dllPath = art.dllPath,
      contract = art.contract,
      source = ownPr.file,
      checkResult = cr
    )
  )
}

// Empty preamble — a fresh list each call so no caller can alias it.
func emptyPreamble(): List[Meta.ContractDecl] {
  val e: List[Meta.ContractDecl] = newList()
  e
}
