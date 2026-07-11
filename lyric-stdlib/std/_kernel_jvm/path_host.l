//! std/_kernel_jvm/path_host.l — JVM host boundary for path manipulation.
//!
//! Mirrors _kernel/path_host.l for the JVM target: the same five-function
//! surface with System.IO.Path's documented semantics, implemented as pure
//! string computation (never touches the filesystem, never throws).  The
//! previous version routed through a phantom `lyric.stdlib.jvm.PathHost`
//! class that never existed at runtime, which left Std.Path non-functional
//! on this target (docs/59 F-1c).
//!
//! Pure Lyric rather than java.nio.file / java.io.File delegation, for two
//! reasons:
//!   - `Paths.get` / `Path.of` are String... varargs, which the auto-FFI
//!     call shapes here don't produce; and
//!   - java.io.File NORMALIZES ("/a/b/".getParent() → "/a" where
//!     System.IO.Path.GetDirectoryName returns "/a/b"; "/a/b/".getName()
//!     → "b" where GetFileName returns ""), so delegating would silently
//!     diverge from the .NET twin on trailing-separator inputs.
//!
//! Platform awareness comes from java.io.File.separatorChar: on Windows
//! JVMs both '/' and '\' separate and "X:" drive prefixes root a path,
//! matching System.IO.Path on Windows; elsewhere only '/' does.  Every
//! output below is byte-identical to a `--target dotnet` run of the .NET
//! twin over the same inputs (verified for the combine / extension /
//! filename / directory-name / rooted cases in
//! stdlib_jvm_kernels_self_test.l).
//!
//! Internal: only Std.Path should import this.
@axiom("java.io.File.separatorChar and java.io.File.getParent conform to their documented JVM contracts")
package Std.PathHost

extern type JFile = "java.io.File"

// Platform primary separator ('/' on POSIX, '\' on Windows).
func separatorChar(): Char {
  JFile.separatorChar
}

func isWindows(): Bool {
  separatorChar() == '\\'
}

// True when `c` separates path components on this platform.  Windows
// treats both '\' and '/' as separators (like System.IO.Path); POSIX
// treats only '/' (a backslash is an ordinary filename character).
func isSep(c: in Char): Bool {
  if c == '/' {
    return true
  }
  isWindows() and c == '\\'
}

// Lyric has no null literal; the only way to produce a null String? from
// pure Lyric is an extern call that returns null.  java.io.File("x") has
// no parent component, so getParent() is documented to return null.
func nullString(): String? {
  val f = JFile.new("x")
  f.getParent()
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
    if path[0] == '/' {
      return 1
    }
    return 0
  }
  if isSep(path[0]) {
    if len >= 2 and isSep(path[1]) {
      // UNC \\server\share: the root spans the server and share components.
      var i = 2
      var seenComponents = 0
      while i < len {
        if isSep(path[i]) {
          seenComponents += 1
          if seenComponents == 2 {
            return i
          }
          while i < len and isSep(path[i]) {
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
  if len >= 2 and path[1] == ':' {
    if len >= 3 and isSep(path[2]) {
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
  val last = base[base.length - 1]
  if isSep(last) or (isWindows() and last == ':') {
    return base + relative
  }
  base + ("" + separatorChar()) + relative
}

/// Final extension including the leading dot ("a.tar.gz" → ".gz"); "" when
/// the last component has no dot, or the dot is its final character
/// ("file." → "").
pub func hostPathGetExtension(path: in String): String {
  var i = path.length - 1
  while i >= 0 {
    val c = path[i]
    if c == '.' {
      if i == path.length - 1 {
        return ""
      }
      return path.substring(i, path.length - i)
    }
    if isSep(c) or (isWindows() and c == ':') {
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
    val c = path[i]
    if isSep(c) or (isWindows() and c == ':') {
      return path.substring(i + 1, path.length - i - 1)
    }
    i = i - 1
  }
  path
}

/// Containing directory (System.IO.Path.GetDirectoryName semantics):
/// null for "" and for root paths ("/", "C:\"); "" for a bare filename;
/// otherwise the text before the last separator, with trailing separators
/// trimmed down to the root ("/a//b" → "/a", "/a/b/" → "/a/b", "/a" → "/").
pub func hostPathGetDirectoryName(path: in String): String? {
  if path.length == 0 {
    return nullString()
  }
  val root = rootLength(path)
  if path.length <= root {
    return nullString()
  }
  var i = path.length - 1
  while i >= root and not isSep(path[i]) {
    i = i - 1
  }
  if i < root {
    // No separator past the root: "a" → ""; "/a" → "/"; "C:a" → "C:".
    return path.substring(0, root)
  }
  var cut = i
  while cut > root and isSep(path[cut - 1]) {
    cut = cut - 1
  }
  path.substring(0, cut)
}

/// Whether the path is absolute under this platform's rules (POSIX: leading
/// '/'; Windows: leading separator or an "X:" drive prefix — matching
/// System.IO.Path.IsPathRooted, where drive-relative "C:x" counts as rooted).
pub func hostPathIsRooted(path: in String): Bool {
  if path.length == 0 {
    return false
  }
  if isSep(path[0]) {
    return true
  }
  isWindows() and path.length >= 2 and path[1] == ':'
}
