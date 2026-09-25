//! std/path.l - platform-aware path utilities.
//!
//! Path helpers are pure string/path computations over the host path
//! rules. They do not touch the filesystem and therefore do not return
//! IOError.
@runtime_checked
package Std.Path

import Std.PathHost
import Std.Errors

/// Join two path components with the host separator.
///
/// Empty components preserve the non-empty side. This is string/path
/// syntax work only; it does not check whether either component exists,
/// and it does NOT normalize or confine the result: `..` segments are kept,
/// and an absolute `relative` replaces `base` entirely
/// (`join("/srv/www", "/etc/passwd")` is `"/etc/passwd"`).  To build a path
/// from an untrusted component that must stay under `base`, use
/// `joinWithin`.
///
/// # Example
/// ```
/// let root = "/home/user"
/// let sub = "projects"
/// let result = join(root, sub)  // "/home/user/projects" on Unix
/// ```
@stable(since = "1.0")
pub func join(base: in String, relative: in String): String {
  if base.length == 0 {
    return relative
  }
  if relative.length == 0 {
    return base
  }
  return hostPathCombine(base, relative)
}

/// Join `relative` under `base`, refusing any `relative` that could leave it.
///
/// For a component that comes from outside the program (a URL path, an
/// upload name).  Returns `Err(InvalidPath)` when `base` is empty, or when
/// `relative`:
/// - is rooted (a leading `/` or `\`, a drive letter, or anything
///   `isAbsolute` accepts);
/// - has a segment (split on `/` or `\`) made only of dots and spaces,
///   such as `.`, `..`, `...` or `.. `.  Windows strips trailing dots and
///   spaces from each segment, so `.. ` is `..` to the OS; or
/// - contains a NUL.
///
/// Otherwise returns `join(base, relative)`.  The check is syntactic: it does
/// not resolve symbolic links, so a symlink inside `base` can still point
/// elsewhere.
@stable(since = "1.2")
pub func joinWithin(base: in String, relative: in String): Result[String, IOError] {
  if base.length == 0 {
    return Err(
      error = InvalidPath(path = relative, reason = "the base directory is empty, so nothing confines the result")
    )
  }
  if relative.contains("\u{0000}") {
    return Err(error = InvalidPath(path = relative, reason = "contains a NUL character"))
  }
  if isAbsolute(relative) or relative.startsWith("/") or relative.startsWith("\\") or hasDriveLetter(relative) {
    return Err(error = InvalidPath(path = relative, reason = "must be a relative path"))
  }
  val segs = pathSegments(relative)
  var i = 0
  while i < segs.count {
    if isDotSegment(segs[i]) {
      return Err(error = InvalidPath(path = relative, reason = "must not contain '.' or '..' segments"))
    }
    i = i + 1
  }
  Ok(value = join(base, relative))
}

func hasDriveLetter(p: in String): Bool {
  p.length >= 2 and p.substring(1, 1) == ":"
}

func isSeparator(c: in String): Bool {
  c == "/" or c == "\\"
}

// `p` split on `/` and `\`, keeping empty segments.
func pathSegments(p: in String): List[String] {
  val segs: List[String] = newList()
  var segStart = 0
  var i = 0
  while i <= p.length {
    if i == p.length or isSeparator(p.substring(i, 1)) {
      segs.add(p.substring(segStart, i - segStart))
      segStart = i + 1
    }
    i = i + 1
  }
  segs
}

// A non-empty segment made only of dots and spaces that contains a dot.
// Windows strips trailing dots and spaces from a segment, so every such
// segment means `.` or `..` to some host.
func isDotSegment(seg: in String): Bool {
  if seg.length == 0 {
    return false
  }
  var sawDot = false
  var i = 0
  while i < seg.length {
    val c = seg.substring(i, 1)
    if c == "." {
      sawDot = true
    } else if c != " " {
      return false
    }
    i = i + 1
  }
  sawDot
}

// For a dot segment, whether it climbs a level: two or more leading dots.
// Windows versions have differed on `...`, so it is treated as `..`.
func isParentSegment(seg: in String): Bool {
  isDotSegment(seg) and seg.length >= 2 and seg.substring(0, 2) == ".."
}

// Walks `segs` from `from` after `.`/`..` resolution.  Returns the final
// depth below the starting point.  Under a root (`rooted`), `..` at the top
// stays there, as the OS does; otherwise a `..` climbing above the start
// returns -1.
func resolvedDepth(segs: in List[String], from: in Int, rooted: in Bool): Int {
  var depth = 0
  var i = from
  while i < segs.count {
    val seg = segs[i]
    if isParentSegment(seg) {
      if depth > 0 {
        depth = depth - 1
      } else if not rooted {
        return -1
      }
    } else if seg.length > 0 and not isDotSegment(seg) {
      depth = depth + 1
    }
    i = i + 1
  }
  depth
}

/// True when `path` names, or may name, a filesystem root.  Recursive
/// deletes refuse such paths, so a configuration value that comes out empty
/// after a join cannot wipe a volume.  Covers:
/// - separators only (`/`, `//`, `\`);
/// - a drive (`C:`, `C:\`, `C:/`);
/// - a UNC share root (`\\server\share`) with nothing below it;
/// - Win32 device prefixes (`\\?\C:\`, `\\.\C:\`);
/// - any of these reached through `.`/`..` segments (`/tmp/..`, `/.`,
///   `C:\Windows\..`), treating dot-and-space segments as Windows does;
/// - a relative path whose `..` segments climb above its starting point
///   (`..`, `a/../..`), since that can reach a root depending on the
///   working directory.
@pure
@stable(since = "1.2")
pub func isFilesystemRoot(path: in String): Bool {
  if path.length == 0 {
    return false
  }
  var p = path
  if p.length >= 4 and isSeparator(p.substring(0, 1)) and isSeparator(p.substring(1, 1)) and (p.substring(2, 1) == "?" or p.substring(2, 1) == ".") and isSeparator(p.substring(3, 1)) {
    p = p.substring(4, p.length - 4)
    if p.length == 0 {
      return true
    }
  }
  val segs = pathSegments(p)
  if hasDriveLetter(p) {
    // `C:rest`: the drive letter is segment 0's first two characters.
    val first = segs[0].substring(2, segs[0].length - 2)
    if first.length > 0 {
      // `C:dir\...` is relative to the drive's current directory.
      val rest: List[String] = newList()
      rest.add(first)
      var k = 1
      while k < segs.count {
        rest.add(segs[k])
        k = k + 1
      }
      return resolvedDepth(rest, 0, false) < 0
    }
    return resolvedDepth(segs, 1, true) == 0
  }
  if isSeparator(p.substring(0, 1)) {
    val isUnc = p.length >= 2 and isSeparator(p.substring(1, 1)) and segs.count >= 3 and segs[2].length > 0
    if isUnc {
      // segs: "", "", server, share, rest...
      if segs.count <= 4 {
        return true
      }
      return resolvedDepth(segs, 4, true) == 0
    }
    return resolvedDepth(segs, 0, true) == 0
  }
  resolvedDepth(segs, 0, false) < 0
}

/// Extract the final extension, including the leading dot when present.
///
/// # Example
/// ```
/// extension("file.txt")       // ".txt"
/// extension("archive.tar.gz") // ".gz"
/// extension("README")         // ""
/// ```
@stable(since = "1.0")
pub func extension(path: in String): String {
  return hostPathGetExtension(path)
}

/// Extract the final path component.
///
/// # Example
/// ```
/// basename("/home/user/file.txt") // "file.txt"
/// basename("file.txt")            // "file.txt"
/// ```
///
/// For paths ending in a separator, the host boundary decides whether
/// this is empty or normalized first.
@stable(since = "1.0")
pub func basename(path: in String): String {
  return hostPathGetFileName(path)
}

/// Extract the containing directory.
///
/// # Example
/// ```
/// dirname("/home/user/file.txt") // "/home/user"
/// dirname("file.txt")            // "."
/// ```
///
/// Paths with no directory component use "." so callers can compose
/// with relative paths without handling null.
@stable(since = "1.0")
pub func dirname(path: in String): String {
  val dir = hostPathGetDirectoryName(path) ?? ""
  if dir == "" {
    "."
  } else {
    dir
  }
}

/// Check whether a path is absolute under the host platform's path
/// rules.
///
/// This is a syntax check only; it does not verify existence.
@stable(since = "1.0")
pub func isAbsolute(path: in String): Bool {
  if path.length == 0 {
    return false
  }
  return hostPathIsRooted(path)
}

/// Check whether a path is relative under the host platform's path
/// rules.
///
/// Empty paths are treated as relative by convention.
@stable(since = "1.0")
pub func isRelative(path: in String): Bool {
  return not isAbsolute(path)
}

// Future: normalize, canonicalize, relativize, resolve, glob patterns,
// symlink detection, and platform-specific policies around case
// sensitivity and invalid characters.
