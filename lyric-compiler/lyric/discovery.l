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
import Std.Collections
import Std.String as Str
// before Path so Path.join/2 wins over Str.join (overload resolution)
import Std.File as File
import Std.Path as Path
import Std.Environment as Env
import Std.Errors
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
  case FoundBrokenManifest(path: String, error: Mf.ManifestError)
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
pub func brokenManifestWarning(path: in String, error: in Mf.ManifestError): String {
  "warning: ignoring lyric.toml at '" + path + "': " + Mf.ManifestError.message(error) +
    " (treating as no manifest found)"
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

// ─────────────────────────────────────────────────────────────────────────────
// The files of a package
// ─────────────────────────────────────────────────────────────────────────────
/// The source files a `[project.packages]` (or `[project.tests]`) entry
/// compiles, as the build reads them: an explicit list in its order, a
/// single file, or every `.l` file under a directory, recursively, sorted.
/// A directory entry leaves out what another entry of `proj` names inside
/// it: a subdirectory that is another entry's path is that entry's package
/// (a sub-package, docs/01 §9.1), and a file another entry lists is that
/// entry's.
/// `problems` says why the set is incomplete (no prefix; each caller adds
/// its own); `emptyDir` names a directory entry that yielded no `.l` file,
/// which the build reports and a listing command tolerates.  `lyric build` and `lyric prove` both take an entry's files
/// from here, so they cannot disagree on what a package is (#8108).
pub record EntryFiles {
  paths: List[String]
  problems: List[String]
  emptyDir: String
}

pub func projectEntryFiles(pkgEntry: in Mf.PackageEntry, mfDir: in String, proj: in Mf.ProjectSection): EntryFiles {
  val paths: List[String] = newList()
  val problems: List[String] = newList()
  if pkgEntry.paths.count > 0 {
    var fi = 0
    while fi < pkgEntry.paths.count {
      paths.add(if Path.isAbsolute(pkgEntry.paths[fi]) { pkgEntry.paths[fi] } else { Path.join(mfDir, pkgEntry.paths[fi]) })
      fi = fi + 1
    }
    return EntryFiles(paths = paths, problems = problems, emptyDir = "")
  }
  val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
  var emptyDir = ""
  if File.fileExists(abs) {
    paths.add(abs)
  } else if File.dirExists(abs) {
    match File.listFilesRecursive(abs) {
      case Ok(fs) -> {
        val claimed = otherEntriesWithin(pkgEntry, mfDir, proj, abs)
        val lFiles: List[String] = newList()
        for f in fs.toArray() {
          if Str.endsWith(f, ".l") and not claimedByOther(f, claimed) {
            lFiles.add(f)
          }
        }
        if lFiles.count == 0 {
          emptyDir = abs
        }
        for f in sortPaths(lFiles) {
          paths.add(f)
        }
      }
      case Err(e) -> {
        problems.add(IOError.message(e))
        emptyDir = abs
      }
    }
  } else {
    problems.add("path not found: " + abs)
  }
  EntryFiles(paths = paths, problems = problems, emptyDir = emptyDir)
}

// The paths (normalized, case kept) that entries of `proj` other than
// `pkgEntry` name strictly inside `dir`: directories and files alike.  Not
// `pathKey`: folding case here would take files out of a package, so on a
// case-sensitive filesystem a sibling differing only in case would be lost.
func otherEntriesWithin(
  pkgEntry: in Mf.PackageEntry, mfDir: in String, proj: in Mf.ProjectSection, dir: in String
): List[String] {
  val dirKey = normalizePath(dir) + "/"
  val claimed: List[String] = newList()
  val entries: List[Mf.PackageEntry] = newList()
  for e in proj.packages.toArray() {
    entries.add(e)
  }
  for e in proj.tests.toArray() {
    entries.add(e)
  }
  for e in entries.toArray() {
    val same = e.name == pkgEntry.name and e.path == pkgEntry.path and e.paths.count == pkgEntry.paths.count
    if not same {
      val ps: List[String] = newList()
      if e.paths.count > 0 {
        for p in e.paths.toArray() {
          ps.add(p)
        }
      } else {
        ps.add(e.path)
      }
      for p in ps.toArray() {
        val key = normalizePath(if Path.isAbsolute(p) { p } else { Path.join(mfDir, p) })
        if Str.startsWith(key, dirKey) {
          claimed.add(key)
        }
      }
    }
  }
  claimed
}

// Whether `file` is, or lies under, one of the `claimed` paths.
func claimedByOther(file: in String, claimed: in List[String]): Bool {
  val key = normalizePath(file)
  for c in claimed.toArray() {
    if key == c or Str.startsWith(key, c + "/") {
      return true
    }
  }
  false
}

/// `xs` in ascending order.
pub func sortPaths(xs: in List[String]): List[String] {
  val remaining: List[String] = newList()
  var c = 0
  while c < xs.count {
    remaining.add(xs[c])
    c = c + 1
  }
  val sorted: List[String] = newList()
  while remaining.count > 0 {
    var bestIdx = 0
    var k = 1
    while k < remaining.count {
      if remaining[k] < remaining[bestIdx] {
        bestIdx = k
      }
      k = k + 1
    }
    sorted.add(remaining[bestIdx])
    remaining.removeAt(bestIdx)
  }
  sorted
}

/// `path` absolute, with `.` and `..` segments resolved, for comparing two
/// spellings of one file.
pub func normalizePath(path: in String): String {
  val absPath = if Path.isAbsolute(path) { path } else { Path.join(Env.currentDirectory(), path) }
  val unified = Str.replace(absPath, "\\", "/")
  val parts = Str.split(unified, "/")
  val kept: List[String] = newList()
  var i = 0
  while i < parts.length {
    val seg = parts[i]
    if seg == ".." {
      if kept.count > 0 {
        kept.removeAt(kept.count - 1)
      }
    } else if seg != "." and seg != "" {
      kept.add(seg)
    }
    i = i + 1
  }
  val absolute = Str.startsWith(unified, "/")
  var joined = ""
  var j = 0
  while j < kept.count {
    if j > 0 or absolute {
      joined = joined + "/"
    }
    joined = joined + kept[j]
    j = j + 1
  }
  if joined == "" and absolute {
    "/"
  } else {
    joined
  }
}

/// `path` as `normalizePath` gives it, lower-cased: two spellings of one
/// file on a case-insensitive filesystem share a key, and on a
/// case-sensitive one a collision only puts more files in a package, which
/// is conservative.  Use it only where a match adds files; where a match
/// removes them (`otherEntriesWithin`), compare `normalizePath` exactly.  Symbolic links are not resolved (Std has no
/// canonical-path call yet): a file reached through one is not matched to
/// its target's spelling.
pub func pathKey(path: in String): String {
  Str.toLower(normalizePath(path))
}

/// The files of a package as `packageFileSetForSource` finds them.
pub record PackageFileSet {
  pub files: List[String]
  pub fromManifest: Bool
}

/// The files the package of the source file at `sourcePath` is built from,
/// normalized: a single-file proof holds relative to the builds its
/// ancestor manifests define.  Every `lyric.toml` from the file's directory
/// up to the filesystem root is read, and the files of each
/// `[project.packages]`/`[project.tests]` entry of any of them that contains
/// the file are united.  With no such entry, the file's only builds are a
/// standalone one or one a manifest outside its tree defines (which cannot
/// be found from the file — prove that package with `--manifest`), and the
/// set is every `.l` file under its directory, recursively, whatever its
/// `package` line (an over-approximation), except under a subdirectory that
/// is a project of its own.  `None` when the set cannot be known: a broken
/// ancestor manifest, a containing entry that cannot be fully listed, an
/// unlistable directory.  `fromManifest` says the files are a manifest
/// entry's, which its build merges whatever their `package` lines, rather
/// than the directory-tree fallback, whose own build is the file alone.
pub func packageFileSetForSource(sourcePath: in String): Option[PackageFileSet] {
  val own = normalizePath(sourcePath)
  val ownKey = pathKey(own)
  val dir = Path.dirname(own)
  val files: List[String] = newList()
  var found = false
  var current = dir
  var walking = true
  while walking {
    val tomlPath = Path.join(current, "lyric.toml")
    if File.fileExists(tomlPath) {
      val text = match File.readText(tomlPath) { case Ok(t) -> t; case Err(_) -> { return None } }
      match Mf.parseManifest(text, tomlPath) {
        case Ok(mf) -> match mf.project {
          case Some(proj) -> {
            val mfDir = Path.dirname(tomlPath)
            val entries: List[Mf.PackageEntry] = newList()
            for e in proj.packages.toArray() {
              entries.add(e)
            }
            for e in proj.tests.toArray() {
              entries.add(e)
            }
            for entry in entries.toArray() {
              val ef = projectEntryFiles(entry, mfDir, proj)
              var contains = false
              for p in ef.paths.toArray() {
                if pathKey(p) == ownKey {
                  contains = true
                }
              }
              if contains {
                if ef.problems.count > 0 or ef.emptyDir.length > 0 {
                  return None
                }
                found = true
                for p in ef.paths.toArray() {
                  files.add(normalizePath(p))
                }
              }
            }
          }
          case None -> ()
        }
        case Err(e) -> match e {
          // A `[workspace]` root with no `[package]` is not broken
          // (`findNearestManifestDetailed`): it defines no package entry.
          case MissingField(_, _) -> {
            if Mf.textHasPackageSection(text) {
              return None
            }
          }
          case _ -> {
            return None
          }
        }
      }
    }
    val parent = Path.dirname(current)
    if parent == current or parent == "." {
      walking = false
    } else {
      current = parent
    }
  }
  if found {
    return Some(value = PackageFileSet(files = files, fromManifest = true))
  }
  match File.listFilesRecursive(dir) {
    case Ok(fs) -> {
      val scanned: List[String] = newList()
      for f in fs.toArray() {
        val nf = normalizePath(f)
        if Str.endsWith(nf, ".l") and not insideNestedProject(nf, dir) {
          scanned.add(nf)
        }
      }
      Some(value = PackageFileSet(files = scanned, fromManifest = false))
    }
    case Err(_) -> None
  }
}

// Whether `file` lies in a subdirectory of `root` that has a lyric.toml of
// its own: another project, never part of a build of a file in `root`.
func insideNestedProject(file: in String, root: in String): Bool {
  var d = Path.dirname(file)
  while d.length > root.length {
    if File.fileExists(Path.join(d, "lyric.toml")) {
      return true
    }
    val parent = Path.dirname(d)
    if parent == d {
      return false
    }
    d = parent
  }
  false
}
