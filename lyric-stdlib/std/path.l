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
/// upload name).  Returns `Err(InvalidPath)` when `relative` is rooted (a
/// leading `/` or `\`, a drive letter, or anything `isAbsolute` accepts),
/// contains a `..` segment (with either separator), or contains a NUL.
/// Otherwise returns `join(base, relative)`.  The check is syntactic: it does
/// not resolve symbolic links, so a symlink inside `base` can still point
/// elsewhere.
@stable(since = "1.2")
pub func joinWithin(base: in String, relative: in String): Result[String, IOError] {
  if relative.contains("\u{0000}") {
    return Err(error = InvalidPath(path = relative, reason = "contains a NUL character"))
  }
  if isAbsolute(relative) or relative.startsWith("/") or relative.startsWith("\\") or hasDriveLetter(relative) {
    return Err(error = InvalidPath(path = relative, reason = "must be a relative path"))
  }
  if hasDotDotSegment(relative) {
    return Err(error = InvalidPath(path = relative, reason = "must not contain '..' segments"))
  }
  Ok(value = join(base, relative))
}

func hasDriveLetter(p: in String): Bool {
  p.length >= 2 and p.substring(1, 1) == ":"
}

// True when `p`, split on either `/` or `\`, has a segment that is exactly `..`.
func hasDotDotSegment(p: in String): Bool {
  var segStart = 0
  var i = 0
  while i <= p.length {
    val atEnd = i == p.length
    val isSep = if atEnd { false } else { p.substring(i, 1) == "/" or p.substring(i, 1) == "\\" }
    if atEnd or isSep {
      if i - segStart == 2 and p.substring(segStart, 2) == ".." {
        return true
      }
      segStart = i + 1
    }
    i = i + 1
  }
  false
}

/// True when `path` names a filesystem root: only separators (`/`, `\\`),
/// a drive root (`C:`, `C:\\`, `C:/`), or a UNC share root with nothing
/// below it.  Recursive deletes refuse such paths, so a configuration value
/// that comes out empty after a join cannot wipe a volume.
@pure
@stable(since = "1.2")
pub func isFilesystemRoot(path: in String): Bool {
  var p = path
  // Strip one drive prefix (`C:`), then look at what is left.
  if hasDriveLetter(p) {
    p = p.substring(2, p.length - 2)
  }
  var i = 0
  while i < p.length {
    val c = p.substring(i, 1)
    if c != "/" and c != "\\" {
      return false
    }
    i = i + 1
  }
  path.length > 0
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
