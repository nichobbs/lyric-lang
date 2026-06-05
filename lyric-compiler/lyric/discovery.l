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

// parseManifest(text, filePath) -> Result[Manifest, ManifestError]
/// Walk up from startDir looking for the nearest lyric.toml that parses as a
/// package manifest (i.e. has a `[package]` section).  Returns the absolute
/// path to that lyric.toml, or None when none is found before the filesystem
/// root.
///
/// Unlike `Lyric.Workspace.findWorkspaceRoot`, this matches an ordinary
/// project/package manifest rather than only a `[workspace]` root — it is the
/// discovery primitive that lets the CLI run a command from any subdirectory
/// of a project.  A pure `[workspace]` root (no `[package]`) does not parse
/// via `parseManifest` and is skipped, so the walk continues past it.
pub func findNearestManifest(startDir: in String): Option[String] {
  var current = startDir
  var keepWalking = true
  while keepWalking {
    val tomlPath = Path.join(current, "lyric.toml")
    if File.fileExists(tomlPath) {
      match File.readText(tomlPath) {
        case Err(_) -> ()
        // unreadable; keep walking up
        case Ok(text) -> match Mf.parseManifest(text, tomlPath) { case Err(_) -> (); case Ok(_) -> return Some(value = tomlPath) }
      }
      // not a package manifest (e.g. virtual workspace root); keep walking
    }
    // Advance to parent directory; stop when we reach the filesystem root.
    val parent = Path.dirname(current)
    if parent == current or parent == "." {
      keepWalking = false
    } else {
      current = parent
    }
  }
  None
}
