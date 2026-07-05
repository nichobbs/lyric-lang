//! stdlib/tests/directory_tests.l — Tests for Std.Directory.
//!
//! Covers the core I/O surface flagged as untested in
//! docs/57-stdlib-ecosystem-library-review.md §5.1: existence probes,
//! creation (including idempotent re-creation), enumeration variants
//! (all entries, files only, directories only), and both delete forms
//! (empty-only vs. recursive). Each test creates its own scratch
//! subdirectory under $TMPDIR to avoid cross-test interference.
@test_module
package Std.Directory.Tests

import Std.Core
import Std.Errors
import Std.Directory
import Std.File
import Std.Environment
import Std.Testing

func scratchDir(label: in String): String {
  val base = Environment.getVarOrDefault("TMPDIR", "/tmp")
  base + "/lyric_directory_tests_" + label
}

test "exists reflects presence and absence, including empty path" {
  val dir = scratchDir("exists")
  assertFalse(exists(dir), "does not exist before create")
  val _ = create(dir)
  assertTrue(exists(dir), "exists after create")
  assertFalse(exists(""), "empty path is never an existing directory")
  val _ = deleteRecursive(dir)
}

test "create makes a new directory and is idempotent on an existing one" {
  val dir = scratchDir("create_idempotent")
  match create(dir) {
    case Ok(_) -> assertTrue(exists(dir), "directory exists after first create")
    case Err(e) -> panic("create failed: " + IOError.message(e))
  }
  match create(dir) {
    case Ok(_) -> ()
    case Err(e) -> panic("re-creating an existing directory should be Ok, got: " + IOError.message(e))
  }
  val _ = deleteRecursive(dir)
}

test "create on an empty path returns InvalidPath" {
  match create("") {
    case Ok(_) -> panic("expected InvalidPath, got Ok")
    case Err(InvalidPath(_, _)) -> ()
    case Err(other) -> panic("expected InvalidPath, got: " + IOError.message(other))
  }
}

test "createRecursive creates missing parent directories" {
  val dir = scratchDir("create_recursive")
  val nested = dir + "/a/b/c"
  match createRecursive(nested) {
    case Ok(_) -> assertTrue(exists(nested), "deeply nested directory exists")
    case Err(e) -> panic("createRecursive failed: " + IOError.message(e))
  }
  val _ = deleteRecursive(dir)
}

test "enumerate lists both files and subdirectories" {
  val dir = scratchDir("enumerate")
  val _ = create(dir)
  val _ = writeText(dir + "/a.txt", "a")
  val _ = create(dir + "/sub")

  match enumerate(dir) {
    case Ok(entries) -> assertEqualInt(entries.count, 2, "enumerate finds the file and the subdirectory")
    case Err(e) -> panic("enumerate failed: " + IOError.message(e))
  }
  val _ = deleteRecursive(dir)
}

test "enumerate on a missing directory returns DirectoryNotFound" {
  val dir = scratchDir("enumerate_missing")
  match enumerate(dir + "/does-not-exist") {
    case Ok(_) -> panic("expected DirectoryNotFound, got Ok")
    case Err(DirectoryNotFound(_)) -> ()
    case Err(other) -> panic("expected DirectoryNotFound, got: " + IOError.message(other))
  }
}

test "enumerateFiles excludes subdirectories" {
  val dir = scratchDir("enumerate_files")
  val _ = create(dir)
  val _ = writeText(dir + "/a.txt", "a")
  val _ = writeText(dir + "/b.txt", "b")
  val _ = create(dir + "/sub")

  match enumerateFiles(dir) {
    case Ok(files) -> assertEqualInt(files.count, 2, "enumerateFiles excludes the subdirectory")
    case Err(e) -> panic("enumerateFiles failed: " + IOError.message(e))
  }
  val _ = deleteRecursive(dir)
}

test "enumerateDirectories excludes files" {
  val dir = scratchDir("enumerate_dirs")
  val _ = create(dir)
  val _ = writeText(dir + "/a.txt", "a")
  val _ = create(dir + "/sub1")
  val _ = create(dir + "/sub2")

  match enumerateDirectories(dir) {
    case Ok(dirs) -> assertEqualInt(dirs.count, 2, "enumerateDirectories excludes the file")
    case Err(e) -> panic("enumerateDirectories failed: " + IOError.message(e))
  }
  val _ = deleteRecursive(dir)
}

test "delete removes an empty directory" {
  val dir = scratchDir("delete_empty")
  val _ = create(dir)
  match delete(dir) {
    case Ok(_) -> assertFalse(exists(dir), "directory gone after delete")
    case Err(e) -> panic("delete of an empty directory failed: " + IOError.message(e))
  }
}

test "delete on a missing directory returns DirectoryNotFound" {
  val dir = scratchDir("delete_missing")
  match delete(dir + "/does-not-exist") {
    case Ok(_) -> panic("expected DirectoryNotFound, got Ok")
    case Err(DirectoryNotFound(_)) -> ()
    case Err(other) -> panic("expected DirectoryNotFound, got: " + IOError.message(other))
  }
}

test "delete on a non-empty directory surfaces IoError rather than silently recursing" {
  val dir = scratchDir("delete_nonempty")
  val _ = create(dir)
  val _ = writeText(dir + "/a.txt", "a")
  match delete(dir) {
    case Ok(_) -> panic("delete() on a non-empty directory should fail, not silently recurse")
    case Err(_) -> ()
  }
  val _ = deleteRecursive(dir)
}

test "deleteRecursive removes a populated directory tree" {
  val dir = scratchDir("delete_recursive")
  val _ = create(dir)
  val _ = writeText(dir + "/a.txt", "a")
  val _ = create(dir + "/sub")
  val _ = writeText(dir + "/sub/b.txt", "b")

  match deleteRecursive(dir) {
    case Ok(_) -> assertFalse(exists(dir), "directory tree gone after recursive delete")
    case Err(e) -> panic("deleteRecursive failed: " + IOError.message(e))
  }
}

test "deleteRecursive on a missing directory returns DirectoryNotFound" {
  val dir = scratchDir("delete_recursive_missing")
  match deleteRecursive(dir + "/does-not-exist") {
    case Ok(_) -> panic("expected DirectoryNotFound, got Ok")
    case Err(DirectoryNotFound(_)) -> ()
    case Err(other) -> panic("expected DirectoryNotFound, got: " + IOError.message(other))
  }
}
