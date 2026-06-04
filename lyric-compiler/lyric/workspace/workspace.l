// workspace/workspace.l — workspace root discovery and member resolution.
//
// Implements the workspace root-finding algorithm described in
// docs/38-workspace.md §2: walk up from a start directory looking for a
// lyric.toml that contains a [workspace] table, then discover all member
// packages by walking the directory tree.
//
// Public API:
//   pub func findWorkspaceRoot(startDir: in String): Option[WorkspaceContext]
//   pub func findMember(members: in List[WorkspaceMember], name: in String): Option[WorkspaceMember]
//   pub func resolveDep(name: in String, ctx: in WorkspaceContext): Option[String]

package Lyric.Workspace

import Std.Core
import Std.Collections
import Std.String as Str      // before Path so Path.join/2 wins over Str.join/2
import Std.File as File
import Std.Path as Path
import Std.Directory as Directory
import Std.Errors

import Lyric.Manifest as Mf

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public types
// ─────────────────────────────────────────────────────────────────────────────

pub record WorkspaceMember {
  name: String   // from [package].name
  dir:  String   // absolute path to member directory
}

pub record WorkspaceContext {
  rootDir:   String                  // absolute path to workspace root directory
  rootFile:  String                  // absolute path to root lyric.toml
  members:   List[WorkspaceMember]
  overrides: List[Mf.WorkspaceOverride]  // from [workspace.overrides]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Private helpers
// ─────────────────────────────────────────────────────────────────────────────

// Normalise backslashes to forward slashes for cross-platform exclude matching.
func normalizeSeps(s: in String): String {
  Str.replace(s, "\\", "/")
}

// Check whether a directory path should be excluded based on the exclude list.
// A match succeeds when the normalised dir ends with "/" + excludeEntry.
func shouldExclude(dir: in String, excludes: in List[String]): Bool {
  val normDir = normalizeSeps(dir)
  var i = 0
  while i < excludes.count {
    val excl = normalizeSeps(excludes[i])
    if Str.endsWith(normDir, "/" + excl) { return true }
    i += 1
  }
  false
}

// Recursively walk dir, collecting WorkspaceMember records into acc.
// rootDir is passed through so the root itself is not added as a member.
// Directories whose names start with "." or that are known build-output
// directories are silently skipped, as are paths matching the excludes list.
func discoverMembersRec(rootDir: in String, dir: in String, excludes: in List[String], acc: in List[WorkspaceMember]): Unit {
  // Skip excluded paths (does not apply to the root itself).
  if dir != rootDir and shouldExclude(dir, excludes) { return }

  // If there is a lyric.toml in this directory (and it is not the workspace
  // root), try to parse it and register this as a member.
  val tomlPath = Path.join(dir, "lyric.toml")
  if File.fileExists(tomlPath) and dir != rootDir {
    match File.readText(tomlPath) {
      case Err(_) -> ()  // unreadable; skip silently
      case Ok(text) ->
        match Mf.parseManifest(text, tomlPath) {
          case Err(_) -> ()  // unparseable; skip silently
          case Ok(m)  -> acc.add(WorkspaceMember(name = m.packageSection.name, dir = dir))
        }
    }
  }

  // Recurse into subdirectories, skipping hidden and known build-output dirs.
  match Directory.enumerateDirectories(dir) {
    case Err(_)     -> ()  // unreadable directory; skip silently
    case Ok(subdirs) -> {
      var i = 0
      while i < subdirs.length {
        val subdir = subdirs[i]
        val base   = Path.basename(subdir)
        val skip   = Str.startsWith(base, ".") or
                     base == "node_modules" or
                     base == "target" or
                     base == "bin" or
                     base == "obj"
        if not skip {
          discoverMembersRec(rootDir, subdir, excludes, acc)
        }
        i += 1
      }
    }
  }
}

// Build a WorkspaceContext given the root directory, workspace section, and
// already-accumulated members list.
func buildContext(rootDir: in String, rootFile: in String, ws: in Mf.WorkspaceSection, members: in List[WorkspaceMember]): WorkspaceContext {
  // Resolve relative override paths against rootDir.
  val overrides: List[Mf.WorkspaceOverride] = newList()
  var i = 0
  while i < ws.overrides.count {
    val ov = ws.overrides[i]
    val resolvedDir =
      if Path.isAbsolute(ov.dir) { ov.dir }
      else { Path.join(rootDir, ov.dir) }
    overrides.add(Mf.WorkspaceOverride(name = ov.name, dir = resolvedDir))
    i += 1
  }
  WorkspaceContext(
    rootDir   = rootDir,
    rootFile  = rootFile,
    members   = members,
    overrides = overrides)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Public functions
// ─────────────────────────────────────────────────────────────────────────────

/// Walk up from startDir looking for a lyric.toml that declares a
/// [workspace] table.  When found, discover all member packages and return
/// a WorkspaceContext.  Returns None when no workspace root is found (i.e.
/// the project is standalone).
pub func findWorkspaceRoot(startDir: in String): Option[WorkspaceContext] {
  var current = startDir
  var keepWalking = true
  while keepWalking {
    val tomlPath = Path.join(current, "lyric.toml")
    if File.fileExists(tomlPath) {
      match File.readText(tomlPath) {
        case Err(_) -> ()  // unreadable; continue walking up
        case Ok(text) ->
          match Mf.parseWorkspaceRoot(text, tomlPath) {
            case Err(_)          -> ()  // not a valid workspace root; keep walking
            case Ok(None)        -> ()  // lyric.toml exists but has no [workspace]
            case Ok(Some(ws))    -> {
              val members: List[WorkspaceMember] = newList()
              discoverMembersRec(current, current, ws.workspace.exclude, members)
              val ctx = buildContext(current, tomlPath, ws.workspace, members)
              return Some(value = ctx)
            }
          }
      }
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

/// Walk up from startDir looking for the nearest lyric.toml that parses as a
/// package manifest (i.e. has a `[package]` section).  Returns the absolute
/// path to that lyric.toml, or None when none is found before the filesystem
/// root.
///
/// Unlike `findWorkspaceRoot`, this matches an ordinary project/package
/// manifest rather than only a `[workspace]` root — it is the discovery
/// primitive that lets the CLI run a command from any subdirectory of a
/// project.  A pure `[workspace]` root (no `[package]`) does not parse via
/// `parseManifest` and is skipped, so the walk continues past it.
pub func findNearestManifest(startDir: in String): Option[String] {
  var current = startDir
  var keepWalking = true
  while keepWalking {
    val tomlPath = Path.join(current, "lyric.toml")
    if File.fileExists(tomlPath) {
      match File.readText(tomlPath) {
        case Err(_) -> ()  // unreadable; keep walking up
        case Ok(text) ->
          match Mf.parseManifest(text, tomlPath) {
            case Err(_) -> ()  // not a package manifest (e.g. virtual workspace root); keep walking
            case Ok(_)  -> return Some(value = tomlPath)
          }
      }
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

/// Linear scan of a members list by package name.
pub func findMember(members: in List[WorkspaceMember], name: in String): Option[WorkspaceMember] {
  var i = 0
  while i < members.count {
    val m = members[i]
    if m.name == name { return Some(value = m) }
    i += 1
  }
  None
}

/// Resolve a dependency name to an absolute directory path within the
/// workspace.  Overrides are checked before the member index so that
/// [workspace.overrides] entries always win.
pub func resolveDep(name: in String, ctx: in WorkspaceContext): Option[String] {
  // Check overrides first.
  var i = 0
  while i < ctx.overrides.count {
    val ov = ctx.overrides[i]
    if ov.name == name {
      val dir =
        if Path.isAbsolute(ov.dir) { ov.dir }
        else { Path.join(ctx.rootDir, ov.dir) }
      return Some(value = dir)
    }
    i += 1
  }
  // Fall back to the member index.
  match findMember(ctx.members, name) {
    case Some(m) -> Some(value = m.dir)
    case None    -> None
  }
}
