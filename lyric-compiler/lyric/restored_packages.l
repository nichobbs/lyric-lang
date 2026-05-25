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
