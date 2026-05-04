// std/path.l - platform-aware path utilities.
//
// Path helpers are pure string/path computations over the host path
// rules. They do not touch the filesystem and therefore do not return
// IOError.

@runtime_checked
package Std.Path

import System.IO as HostIO

/// Join two path components into a normalized host path.
///
/// Empty components preserve the non-empty side. This is string/path
/// syntax work only; it does not check whether either component exists.
///
/// # Example
/// ```
/// let root = "/home/user"
/// let sub = "projects"
/// let result = join(root, sub)  // "/home/user/projects" on Unix
/// ```
@stable(since="1.0")
pub func join(base: in String, relative: in String): String {
  if base.length == 0 {
    return relative
  }
  if relative.length == 0 {
    return base
  }
  return HostIO.combine(base, relative)
}

/// Extract the final extension, including the leading dot when present.
///
/// # Example
/// ```
/// extension("file.txt")       // ".txt"
/// extension("archive.tar.gz") // ".gz"
/// extension("README")         // ""
/// ```
@stable(since="1.0")
pub func extension(path: in String): String {
  return HostIO.getExtension(path)
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
@stable(since="1.0")
pub func basename(path: in String): String {
  return HostIO.getFileName(path)
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
@stable(since="1.0")
pub func dirname(path: in String): String {
  match HostIO.getDirectoryName(path) {
    case null -> "."
    case dir when dir.length == 0 -> "."
    case dir -> dir
  }
}

/// Check whether a path is absolute under the host platform's path
/// rules.
///
/// This is a syntax check only; it does not verify existence.
@stable(since="1.0")
pub func isAbsolute(path: in String): Bool {
  if path.length == 0 {
    return false
  }
  return HostIO.isPathRooted(path)
}

/// Check whether a path is relative under the host platform's path
/// rules.
///
/// Empty paths are treated as relative by convention.
@stable(since="1.0")
pub func isRelative(path: in String): Bool {
  return not isAbsolute(path)
}

// Future: normalize, canonicalize, relativize, resolve, glob patterns,
// symlink detection, and platform-specific policies around case
// sensitivity and invalid characters.
