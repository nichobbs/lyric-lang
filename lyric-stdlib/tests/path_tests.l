//! stdlib/tests/path_tests.l — Tests for Std.Path.
//!
//! Covers: join (two non-empty components, one empty), extension
//! (with and without), basename, isAbsolute, isRelative, and the
//! confinement helpers joinWithin and isFilesystemRoot (#7246, #7318,
//! #7328).  Most tests use POSIX-style paths; the BCL normalises separators
//! transparently on the CI platform (Linux).  joinWithin and
//! isFilesystemRoot are syntactic, so their Windows-form cases run on every
//! host.
@test_module
package Std.Path.Tests

import Std.Core
import Std.Path
import Std.Errors
import Std.Testing

func rejected(r: in Result[String, IOError]): Bool {
  match r {
    case Ok(_) -> false
    case Err(_) -> true
  }
}

test "join: two non-empty components" {
  val result = join("/home/user", "projects")
  assertTrue(result.contains("home"), "join contains home")
  assertTrue(result.contains("projects"), "join contains projects")
}

test "join: empty base returns the relative component" {
  assertTrue(join("", "projects") == "projects", "empty base returns relative")
}

test "join: empty relative returns the base" {
  assertTrue(join("/home/user", "") == "/home/user", "empty relative returns base")
}

test "join: does not confine an absolute component" {
  assertTrue(join("/srv/www", "/etc/passwd") == "/etc/passwd", "an absolute component replaces base")
}

test "extension: present" {
  assertTrue(extension("file.txt") == ".txt", "txt extension")
  assertTrue(extension("archive.tar.gz") == ".gz", "last extension only")
}

test "extension: absent" {
  assertTrue(extension("README") == "", "no extension")
  assertTrue(extension("") == "", "empty path no extension")
}

test "basename" {
  assertTrue(basename("/home/user/file.txt") == "file.txt", "basename with dirs")
  assertTrue(basename("file.txt") == "file.txt", "bare filename")
}

test "isAbsolute" {
  assertTrue(isAbsolute("/home/user"), "unix absolute path")
  assertTrue(not isAbsolute("relative/path"), "relative path not absolute")
  assertTrue(not isAbsolute(""), "empty path not absolute")
}

test "isRelative" {
  assertTrue(isRelative("relative/path"), "relative path")
  assertTrue(not isRelative("/absolute"), "absolute path is not relative")
  assertTrue(isRelative(""), "empty path is relative")
}

test "joinWithin: accepts a plain relative path" {
  match joinWithin("/srv/www", "css/site.css") {
    case Ok(p) -> assertTrue(p.contains("css") and p.contains("srv"), "a plain relative path joins")
    case Err(_) -> assertTrue(false, "a plain relative path must be accepted")
  }
  assertTrue(not rejected(joinWithin("/srv/www", "a..b/c")), "dots inside a segment are fine")
  assertTrue(not rejected(joinWithin("/srv/www", ".hidden/x")), "a leading dot in a name is fine")
}

test "joinWithin: rejects rooted and parent-climbing components" {
  assertTrue(rejected(joinWithin("/srv/www", "../etc/passwd")), "leading ..")
  assertTrue(rejected(joinWithin("/srv/www", "a/../../b")), "embedded ..")
  assertTrue(rejected(joinWithin("/srv/www", "a\\..\\..\\b")), "backslash-separated ..")
  assertTrue(rejected(joinWithin("/srv/www", "/etc/passwd")), "rooted")
  assertTrue(rejected(joinWithin("/srv/www", "C:\\Windows")), "drive letter")
  assertTrue(rejected(joinWithin("/srv/www", "a\u{0000}b")), "NUL")
}

test "joinWithin: rejects Windows trailing dot and space forms of .." {
  assertTrue(rejected(joinWithin("C:\\srv\\www", ".. \\secret.txt")), "'.. ' is '..' on Windows")
  assertTrue(rejected(joinWithin("C:\\srv\\www", "..  /secret.txt")), "'..  ' is '..' on Windows")
  assertTrue(rejected(joinWithin("C:\\srv\\www", ".../secret.txt")), "'...'")
  assertTrue(rejected(joinWithin("C:\\srv\\www", "a/. /b")), "'. '")
  assertTrue(rejected(joinWithin("/srv/www", "./a")), "'.'")
}

test "joinWithin: rejects an empty base" {
  assertTrue(rejected(joinWithin("", "a.txt")), "an empty base confines nothing")
}

test "isFilesystemRoot: separators and drives" {
  assertTrue(isFilesystemRoot("/"), "/")
  assertTrue(isFilesystemRoot("//"), "//")
  assertTrue(isFilesystemRoot("C:\\"), "C:\\")
  assertTrue(isFilesystemRoot("C:"), "C:")
  assertTrue(isFilesystemRoot("C:/"), "C:/")
  assertTrue(not isFilesystemRoot("/tmp"), "/tmp")
  assertTrue(not isFilesystemRoot("C:\\Windows"), "C:\\Windows")
  assertTrue(not isFilesystemRoot(""), "empty")
  assertTrue(not isFilesystemRoot("build/out"), "relative directory")
}

test "isFilesystemRoot: dot segments that resolve to a root" {
  assertTrue(isFilesystemRoot("/var/lib/myapp/../../.."), "/var/lib/myapp/../../..")
  assertTrue(isFilesystemRoot("/tmp/.."), "/tmp/..")
  assertTrue(isFilesystemRoot("/tmp/../"), "/tmp/../")
  assertTrue(isFilesystemRoot("/."), "/.")
  assertTrue(isFilesystemRoot("/../.."), "/../..")
  assertTrue(isFilesystemRoot("C:\\Windows\\.."), "C:\\Windows\\..")
  assertTrue(isFilesystemRoot("C:\\Windows\\.. "), "trailing space")
  assertTrue(not isFilesystemRoot("/var/lib/myapp/.."), "/var/lib is not a root")
  assertTrue(not isFilesystemRoot("/../tmp"), "/../tmp is /tmp")
}

test "isFilesystemRoot: relative paths that climb above their start" {
  assertTrue(isFilesystemRoot(".."), "..")
  assertTrue(isFilesystemRoot("a/../.."), "a/../..")
  assertTrue(isFilesystemRoot("C:.."), "C:..")
  assertTrue(not isFilesystemRoot("a/.."), "a/.. is the working directory")
  assertTrue(not isFilesystemRoot("a/b/.."), "a/b/..")
}

test "isFilesystemRoot: UNC shares and device prefixes" {
  assertTrue(isFilesystemRoot("\\\\fileserver\\share"), "UNC share root")
  assertTrue(isFilesystemRoot("\\\\fileserver\\share\\"), "UNC share root with trailing separator")
  assertTrue(isFilesystemRoot("\\\\fileserver\\share\\dir\\.."), "UNC share root via ..")
  assertTrue(isFilesystemRoot("//fileserver/share"), "forward-slash UNC share root")
  assertTrue(isFilesystemRoot("\\\\fileserver"), "UNC server")
  assertTrue(not isFilesystemRoot("\\\\fileserver\\share\\dir"), "a directory on a share")
  assertTrue(isFilesystemRoot("\\\\?\\C:\\"), "device path to a drive root")
  assertTrue(isFilesystemRoot("\\\\.\\C:\\"), "device path via \\\\.\\")
  assertTrue(not isFilesystemRoot("\\\\?\\C:\\Windows"), "device path to a directory")
}
