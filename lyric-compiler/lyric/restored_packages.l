// lyric/restored_packages.l — Lyric.RestoredPackages bootstrap package.
//
// Walks a restored-dependency DLL on disk and returns its embedded
// `Lyric.Contract` surface(s) as structured artifacts the
// self-hosted MSIL bridge will consume to resolve cross-package
// references against compiled deps without re-parsing source.
//
// Mirrors `bootstrap/src/Lyric.Emitter/RestoredPackages.fs::loadRestoredPackage`:
//
//   * Single-package DLL (one `Lyric.Contract` resource) → one
//     `RestoredArtifact` with `packageName` taken from the contract
//     JSON's own `packageName` field (since the legacy resource is
//     unnamed).
//   * Project-as-DLL bundle (N `Lyric.Contract.<Pkg>` resources) →
//     one artifact per resource, keyed by the suffix.
//
// Used by the bridge (Phase A.3.2+) to thread restored types and
// functions into `CodegenCtx`'s symbol tables so a consumer package
// importing a restored dep can resolve its `pub` surface without
// the dep's source.

@runtime_checked
package Lyric.RestoredPackages

import Std.Core
import Std.Collections
import Std.File as File
import Std.String as Str
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
@stable(since="0.1")
pub record RestoredArtifact {
  packageName: String
  version:     String
  dllPath:     String
  contract:    Meta.Contract
}

/// Errors that surface from `loadRestoredPackage`.  Each carries
/// enough info to render a useful diagnostic at the caller's site.
@stable(since="0.1")
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
}

/// Render a `RestoredLoadError` as a short single-line string for
/// CLI diagnostics / error propagation.
@stable(since="0.1")
pub func errorMessage(e: in RestoredLoadError): String {
  match e {
    case DllMissing(p) ->
      "restored DLL not found: " + p
    case NoContractResource(p) ->
      "restored DLL has no Lyric.Contract resource (not a Lyric assembly?): " + p
    case MalformedContract(p, k) ->
      "restored DLL " + p + ": Lyric.Contract" +
      (if Str.isEmpty(k) { "" } else { "." + k }) +
      " resource is not valid JSON"
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
@stable(since="0.1")
pub func loadRestoredPackage(dllPath: in String): Result[List[RestoredArtifact], RestoredLoadError] {
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
      case None ->
        return Err(error = MalformedContract(path = dllPath, pkgKey = e.packageName))
      case Some(c) -> {
        // For the legacy single-package form the resource name's
        // package suffix is "" — recover the canonical package name
        // from the contract JSON's own `packageName` field.  For
        // the project-as-DLL form, the resource-suffix name and
        // the contract's `packageName` should match; prefer the
        // contract's (it's the source of truth).
        val pkgName =
          if Str.isNotEmpty(c.packageName) { c.packageName } else { e.packageName }
        artifacts.add(RestoredArtifact(
          packageName = pkgName,
          version     = c.version,
          dllPath     = dllPath,
          contract    = c))
      }
    }
    i = i + 1
  }

  Ok(value = artifacts)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Source synthesis (#1229 Phase A.3.3.a)
// ─────────────────────────────────────────────────────────────────────────────
//
// Walk a parsed `Contract` and re-emit the source-level shape of its
// public surface as a single Lyric source string.  The result feeds
// the bridge's parser + type checker (Phase A.3.3.b will wire that
// together) so a restored package's symbols become visible to
// consumers without re-parsing the original source — every
// declaration's `Repr` field already IS the source-level form
// (`pub func add(a: Int, b: Int): Int`, `pub record Point { x: Int }`,
// etc.) so the synthesis is mostly concatenation.
//
// Mirrors `bootstrap/src/Lyric.Emitter/RestoredPackages.fs::synthesiseSource`.
// `preamble` carries extern-type / opaque-type / interface decls
// from sibling packages whose types appear in this package's
// signatures — without them, the standalone re-typecheck of the
// synthesised source would fail with `T0010 unknown type name 'X'`.
// The bundled-DLL caller in `loadRestoredPackage` (Phase A.3.3.b)
// will be responsible for assembling the preamble from every
// contract in the bundle; for the single-package form (and for this
// initial port) the preamble can be the empty list.

// Render one decl's source-level form.  Interfaces declare in source
// as `pub interface I {}` — the contract's `Repr` is just the head
// (`pub interface I`) without the body, so append an empty block.
// Every other decl kind already includes its full source-level shape.
func renderDecl(d: in Meta.ContractDecl): String {
  if d.kind == "interface" {
    d.repr + " {}\n"
  } else {
    d.repr + "\n"
  }
}

/// Synthesise a Lyric source file from a `Contract` + optional
/// preamble.  The result is parseable by the standard
/// `Lyric.Parser.parse` and type-checkable in isolation.  Function
/// bodies in the contract are stubs (`= ()` axiom-style); every
/// public type and signature is preserved verbatim from the contract's
/// `Repr` strings.
@stable(since="0.1")
pub func synthesiseSource(contract: in Meta.Contract,
                          preamble: in List[Meta.ContractDecl]): String {
  var sb = "package " + contract.packageName + "\n\n"
  // Preamble decls first — typically extern types / opaques from
  // sibling packages whose names appear in this package's signatures.
  var pi = 0
  while pi < preamble.count {
    sb = sb + renderDecl(preamble[pi])
    pi = pi + 1
  }
  // Then the contract's own decls.
  var di = 0
  while di < contract.decls.count {
    sb = sb + renderDecl(contract.decls[di])
    di = di + 1
  }
  sb
}
