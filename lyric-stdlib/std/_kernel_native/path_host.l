//! std/_kernel_native/path_host.l — native-target host boundary for path
//! manipulation.
//!
//! The `--target native` twin of `_kernel/path_host.l` (System.IO.Path) and
//! `_kernel_jvm/path_host.l`, selected by the native source loader by
//! basename.  Same five-function surface with System.IO.Path's documented
//! semantics, as pure string computation: it never touches the filesystem
//! and never fails.  No normalization is done, so trailing separators keep
//! the .NET behaviour (`GetFileName("/a/b/")` is `""`, `GetDirectoryName`
//! of it is `"/a/b"`), which POSIX `basename(3)`/`dirname(3)` would not give.
//!
//! The platform comes from lyric-rt's `lyric_env_is_windows` (fixed when the
//! runtime is compiled for its triple): on Windows both '/' and '\'
//! separate and an "X:" drive prefix roots a path, as in System.IO.Path on
//! Windows; elsewhere only '/' separates.
//!
//! Internal: only Std.Path should import this.
@axiom("lyric_env_is_windows reports the triple lyric-rt was compiled for")
@pure
package Std.PathHost

import Std.String as Str

extern func rtIsWindows(): Int = "lyric_env_is_windows"

func isWindows(): Bool {
  rtIsWindows() != 0
}

// True when `c` separates path components on this platform.
func isSep(c: in Char): Bool {
  if c == '/' {
    return true
  }
  isWindows() and c == '\\'
}

// A separator, or on Windows the ':' ending a volume prefix.
func endsComponent(c: in Char): Bool {
  isSep(c) or (isWindows() and c == ':')
}

// Length of the path's root prefix, mirroring System.IO.Path.GetPathRoot:
// POSIX "/" → 1; Windows "\" → 1, "X:" → 2, "X:\" → 3, UNC
// "\\server\share" → through the share component; no root → 0.
func rootLength(path: in String): Int {
  val len = path.length
  if len == 0 {
    return 0
  }
  if not isWindows() {
    if Str.charAtOrReplacement(path, 0) == '/' {
      return 1
    }
    return 0
  }
  if isSep(Str.charAtOrReplacement(path, 0)) {
    if len >= 2 and isSep(Str.charAtOrReplacement(path, 1)) {
      var i = 2
      var seenComponents = 0
      while i < len {
        if isSep(Str.charAtOrReplacement(path, i)) {
          seenComponents += 1
          if seenComponents == 2 {
            return i
          }
          while i < len and isSep(Str.charAtOrReplacement(path, i)) {
            i += 1
          }
        } else {
          i += 1
        }
      }
      return len
    }
    return 1
  }
  if len >= 2 and Str.charAtOrReplacement(path, 1) == ':' {
    if len >= 3 and isSep(Str.charAtOrReplacement(path, 2)) {
      return 3
    }
    return 2
  }
  0
}

/// Combine two path components (System.IO.Path.Combine semantics): a rooted
/// `relative` wins outright; otherwise the components join with the platform
/// separator unless `base` already ends in one (or in a Windows volume ':').
/// Empty components preserve the other side.  No normalization.
pub func hostPathCombine(base: in String, relative: in String): String {
  if base.length == 0 {
    return relative
  }
  if relative.length == 0 {
    return base
  }
  if hostPathIsRooted(relative) {
    return relative
  }
  if endsComponent(Str.charAtOrReplacement(base, base.length - 1)) {
    return base + relative
  }
  val sep = if isWindows() { "\\" } else { "/" }
  base + sep + relative
}

/// Final extension including the leading dot ("a.tar.gz" → ".gz"); "" when
/// the last component has no dot, or the dot is its final character
/// ("file." → "").
pub func hostPathGetExtension(path: in String): String {
  var i = path.length - 1
  while i >= 0 {
    val c = Str.charAtOrReplacement(path, i)
    if c == '.' {
      if i == path.length - 1 {
        return ""
      }
      return path.substring(i, path.length - i)
    }
    if endsComponent(c) {
      return ""
    }
    i = i - 1
  }
  ""
}

/// Final path component ("/a/b.txt" → "b.txt"); "" for paths ending in a
/// separator ("/a/b/" → "", matching System.IO.Path.GetFileName).
pub func hostPathGetFileName(path: in String): String {
  var i = path.length - 1
  while i >= 0 {
    if endsComponent(Str.charAtOrReplacement(path, i)) {
      return path.substring(i + 1, path.length - i - 1)
    }
    i = i - 1
  }
  path
}

/// Containing directory (System.IO.Path.GetDirectoryName semantics), with
/// "" where .NET returns null: for "" and for root paths ("/", "C:\"), and
/// for a bare filename; otherwise the text before the last separator, with
/// trailing separators trimmed down to the root ("/a//b" → "/a",
/// "/a/b/" → "/a/b", "/a" → "/").
pub func hostPathGetDirectoryNameOrEmpty(path: in String): String {
  val root = rootLength(path)
  if path.length <= root {
    return ""
  }
  var i = path.length - 1
  while i >= root and not isSep(Str.charAtOrReplacement(path, i)) {
    i = i - 1
  }
  if i < root {
    // No separator past the root: "a" → ""; "/a" → "/"; "C:a" → "C:".
    return path.substring(0, root)
  }
  var cut = i
  while cut > root and isSep(Str.charAtOrReplacement(path, cut - 1)) {
    cut = cut - 1
  }
  path.substring(0, cut)
}

/// Whether the path is absolute under this platform's rules (POSIX: leading
/// '/'; Windows: leading separator or an "X:" drive prefix, matching
/// System.IO.Path.IsPathRooted, where drive-relative "C:x" counts as rooted).
pub func hostPathIsRooted(path: in String): Bool {
  if path.length == 0 {
    return false
  }
  if isSep(Str.charAtOrReplacement(path, 0)) {
    return true
  }
  isWindows() and path.length >= 2 and Str.charAtOrReplacement(path, 1) == ':'
}
