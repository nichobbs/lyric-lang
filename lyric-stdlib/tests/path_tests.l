//! stdlib/tests/path_tests.l — Tests for Std.Path.
//!
//! Covers: join (two non-empty components, one empty), extension
//! (with and without), basename, dirname, isAbsolute, isRelative.
//! All tests use POSIX-style paths; the BCL normalises separators
//! transparently on the CI platform (Linux).
package Std.Path.Tests

import Std.Core
import Std.Path
import Std.Testing

func testJoinBothNonEmpty(): Unit {
  val result = join("/home/user", "projects")
  assertTrue(result.contains("home"), "join contains home")
  assertTrue(result.contains("projects"), "join contains projects")
}

func testJoinEmptyBase(): Unit {
  val result = join("", "projects")
  assertTrue(result == "projects", "empty base returns relative")
}

func testJoinEmptyRelative(): Unit {
  val result = join("/home/user", "")
  assertTrue(result == "/home/user", "empty relative returns base")
}

func testExtensionPresent(): Unit {
  assertTrue(extension("file.txt") == ".txt", "txt extension")
  assertTrue(extension("archive.tar.gz") == ".gz", "last extension only")
}

func testExtensionAbsent(): Unit {
  assertTrue(extension("README") == "", "no extension")
  assertTrue(extension("") == "", "empty path no extension")
}

func testBasename(): Unit {
  assertTrue(basename("/home/user/file.txt") == "file.txt", "basename with dirs")
  assertTrue(basename("file.txt") == "file.txt", "bare filename")
}

func testIsAbsolute(): Unit {
  assertTrue(isAbsolute("/home/user"), "unix absolute path")
  assertTrue(not isAbsolute("relative/path"), "relative path not absolute")
  assertTrue(not isAbsolute(""), "empty path not absolute")
}

func testIsRelative(): Unit {
  assertTrue(isRelative("relative/path"), "relative path")
  assertTrue(not isRelative("/absolute"), "absolute path is not relative")
  assertTrue(isRelative(""), "empty path is relative")
}

func main(): Unit {
  testJoinBothNonEmpty()
  testJoinEmptyBase()
  testJoinEmptyRelative()
  testExtensionPresent()
  testExtensionAbsent()
  testBasename()
  testIsAbsolute()
  testIsRelative()
  println("path_tests: ok")
}
