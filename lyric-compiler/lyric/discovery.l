//! discovery.l — project/manifest discovery for the Lyric CLI.
//!
//! `findNearestManifest` is the primitive behind the project-aware CLI
//! defaults: bare `lyric` builds the discovered project, and build/restore
//! find the project's lyric.toml by walking up from the working directory.
//!
//! This lives in its own small package (rather than in Lyric.Workspace)
//! because it is a distinct concern — locating the nearest *package*
//! manifest, as opposed to Lyric.Workspace's `[workspace]`-root discovery
//! and member resolution — and because keeping its dependency set minimal
//! (Std.File/Path + Lyric.Manifest, with no Std.String/Std.Regex overload
//! surface) lets it be unit-tested in isolation via discovery_self_test.l.
package Lyric.Discovery

import Std.Core
import Std.String as Str
// before Path so Path.join/2 wins over Str.join (overload resolution)
import Std.File as File
import Std.Path as Path
import Lyric.Manifest as Mf

/// Outcome of `findNearestManifestDetailed`'s upward walk.  Distinguishes
/// "nothing looked like a package manifest anywhere above `startDir`" from
/// "found an existing lyric.toml that failed to parse as one" (#4881) — the
/// latter is a signal worth surfacing, not silently swallowing: a project's
/// own lyric.toml with a typo'd `[native] opt_level` or a malformed
/// `[dependencies]` entry should not quietly behave as if there were no
/// manifest at all.
pub union FindManifestResult {
  /// Found a lyric.toml that parsed successfully as a package manifest.
  case FoundManifest(path: String)
  /// Found a lyric.toml that exists and is readable but failed to parse as
  /// a package manifest with a real error: a `ParseError`/`InvalidField`,
  /// or a `MissingField` on a file that DOES carry a `[package]` header
  /// (#5862 — an incomplete `[package]` table, or a broken other section
  /// like `[nuget]`, is a real manifest with an error, not a workspace
  /// root).  Only a `MissingField` on a file with no `[package]` header at
  /// all (e.g. a virtual workspace root) keeps the walk climbing.  The walk
  /// stops here rather than continuing past it to some unrelated ancestor
  /// manifest: silently adopting a grandparent's config while ignoring a
  /// real error in the nearest candidate would be worse than reporting "no
  /// manifest found".
  case FoundBrokenManifest(path: String, error: ManifestError)
  /// No lyric.toml (broken or otherwise) was found before the filesystem root.
  case NoManifestFound
}

/// Walk up from startDir looking for the nearest lyric.toml that parses as a
/// package manifest (i.e. has a `[package]` section), reporting the outcome
/// as a `FindManifestResult` rather than collapsing every non-success case
/// into "not found".
///
/// Unlike `Lyric.Workspace.findWorkspaceRoot`, this matches an ordinary
/// project/package manifest rather than only a `[workspace]` root — it is the
/// discovery primitive that lets the CLI run a command from any subdirectory
/// of a project.  A pure `[workspace]` root (no `[package]`) fails to parse
/// with `MissingField` and is skipped, so the walk continues past it exactly
/// as before; a `ParseError`/`InvalidField` (an existing lyric.toml that is
/// genuinely broken) stops the walk and is reported via `FoundBrokenManifest`
/// instead of being skipped.
pub func findNearestManifestDetailed(startDir: in String): FindManifestResult {
  var current = startDir
  var keepWalking = true
  var result: FindManifestResult = NoManifestFound
  while keepWalking {
    val tomlPath = Path.join(current, "lyric.toml")
    if File.fileExists(tomlPath) {
      match File.readText(tomlPath) {
        case Err(_) -> ()
        // unreadable; keep walking up
        case Ok(text) -> match Mf.parseManifest(text, tomlPath) {
          case Ok(_) -> {
            result = FoundManifest(path = tomlPath)
            keepWalking = false
          }
          case Err(e) -> match e {
            // `MissingField` alone is ambiguous (#5862): `assemblePackage`
            // emits the same MissingField("package", "name") for "no
            // [package] table at all" (e.g. a virtual workspace root — the
            // pre-#4881 keep-walking case) and "a [package] table that
            // exists but is missing a required field" (a real, broken
            // package manifest — walking past it silently misroutes the
            // build to an ancestor, the exact bug class #4881 fixed for
            // ParseError). Other sections' MissingField errors (e.g. a
            // [nuget] entry missing a field) can also surface here and
            // always mean a real-but-broken package manifest. Disambiguate
            // on whether the file has a [package] header at all.
            case MissingField(_, _) -> {
              if Mf.textHasPackageSection(text) {
                result = FoundBrokenManifest(path = tomlPath, error = e)
                keepWalking = false
              }
            }
            case ParseError(_, _, _, _) -> {
              result = FoundBrokenManifest(path = tomlPath, error = e)
              keepWalking = false
            }
            case InvalidField(_, _, _) -> {
              result = FoundBrokenManifest(path = tomlPath, error = e)
              keepWalking = false
            }
          }
        }
      }
    }
    if keepWalking {
      // Advance to parent directory; stop when we reach the filesystem root.
      val parent = Path.dirname(current)
      if parent == current or parent == "." {
        keepWalking = false
      } else {
        current = parent
      }
    }
  }
  result
}

/// Canonical user-facing warning for a `FoundBrokenManifest` outcome (#5858):
/// every auto-discovery call site prints the same message, so it lives here
/// beside the union rather than being rebuilt per-caller.
pub func brokenManifestWarning(path: in String, error: in ManifestError): String {
  "warning: ignoring lyric.toml at '" + path + "': " + ManifestError.message(error) + " (treating as no manifest found)"
}

/// Backward-compatible `Option[String]` view of `findNearestManifestDetailed`
/// for callers that only care about "did we find a usable manifest" — a
/// `FoundBrokenManifest` collapses to `None` here (same fallback shape every
/// existing caller already handles for "no manifest found"), but callers
/// that want to warn the user about the broken manifest should call
/// `findNearestManifestDetailed` directly (see `Lyric.Cli.discoverManifest`).
pub func findNearestManifest(startDir: in String): Option[String] {
  match findNearestManifestDetailed(startDir) {
    case FoundManifest(path) -> Some(value = path)
    case FoundBrokenManifest(_, _) -> None
    case NoManifestFound -> None
  }
}
