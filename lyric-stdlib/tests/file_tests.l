//! stdlib/tests/file_tests.l — Tests for Std.File.
//!
//! Covers the core I/O surface flagged as untested in
//! docs/57-stdlib-ecosystem-library-review.md §5.1: read/write
//! round-trips (text and bytes), existence probes, delete semantics
//! (idempotent file delete vs. error-surfacing directory delete),
//! listing, recursive listing, and stat(). Each test creates its own
//! scratch subdirectory under $TMPDIR to avoid cross-test interference
//! and cleans up afterward.
@test_module
package Std.File.Tests

import Std.Core
import Std.Errors
import Std.File
import Std.Environment
import Std.Testing

func scratchDir(label: in String): String {
  val base = Environment.getVarOrDefault("TMPDIR", "/tmp")
  base + "/lyric_file_tests_" + label
}

test "writeText/readText round-trips UTF-8 content" {
  val dir = scratchDir("text_roundtrip")
  val _ = createDir(dir)
  val path = dir + "/hello.txt"
  match writeText(path, "hello, world") {
    case Ok(_) -> ()
    case Err(e) -> panic("writeText failed: " + IOError.message(e))
  }
  match readText(path) {
    case Ok(text) -> assertEqual(text, "hello, world", "round-tripped text matches")
    case Err(e) -> panic("readText failed: " + IOError.message(e))
  }
  val _ = deleteDirRecursive(dir)
}

test "writeBytes/readBytes round-trips raw bytes" {
  val dir = scratchDir("bytes_roundtrip")
  val _ = createDir(dir)
  val path = dir + "/data.bin"
  val bytes: List[Byte] = newList()
  bytes.add(0)
  bytes.add(1)
  bytes.add(255)
  match writeBytes(path, bytes) {
    case Ok(_) -> ()
    case Err(e) -> panic("writeBytes failed: " + IOError.message(e))
  }
  match readBytes(path) {
    case Ok(readBack) -> {
      assertEqualInt(readBack.count, 3, "byte count round-trips")
      assertEqualInt(readBack[0], 0, "byte 0 round-trips")
      assertEqualInt(readBack[1], 1, "byte 1 round-trips")
      assertEqualInt(readBack[2], 255, "byte 2 round-trips")
    }
    case Err(e) -> panic("readBytes failed: " + IOError.message(e))
  }
  val _ = deleteDirRecursive(dir)
}

test "fileExists reflects presence and absence" {
  val dir = scratchDir("exists")
  val _ = createDir(dir)
  val path = dir + "/present.txt"
  assertFalse(fileExists(path), "does not exist before write")
  val _ = writeText(path, "x")
  assertTrue(fileExists(path), "exists after write")
  assertFalse(fileExists(""), "empty path is never an existing file")
  val _ = deleteDirRecursive(dir)
}

test "readText on a missing file returns FileNotFound" {
  val dir = scratchDir("missing_read")
  val _ = createDir(dir)
  match readText(dir + "/does-not-exist.txt") {
    case Ok(_) -> panic("expected FileNotFound, got Ok")
    case Err(FileNotFound(_)) -> ()
    case Err(other) -> panic("expected FileNotFound, got: " + IOError.message(other))
  }
  val _ = deleteDirRecursive(dir)
}

test "readText/writeText on an empty path return InvalidPath" {
  match readText("") {
    case Ok(_) -> panic("expected InvalidPath, got Ok")
    case Err(InvalidPath(_, _)) -> ()
    case Err(other) -> panic("expected InvalidPath, got: " + IOError.message(other))
  }
  match writeText("", "x") {
    case Ok(_) -> panic("expected InvalidPath, got Ok")
    case Err(InvalidPath(_, _)) -> ()
    case Err(other) -> panic("expected InvalidPath, got: " + IOError.message(other))
  }
}

test "deleteFile is idempotent on a missing file" {
  val dir = scratchDir("delete_idempotent")
  val _ = createDir(dir)
  match deleteFile(dir + "/never-existed.txt") {
    case Ok(_) -> ()
    case Err(e) -> panic("deleteFile on a missing file should be Ok, got: " + IOError.message(e))
  }
  val _ = deleteDirRecursive(dir)
}

test "deleteFile actually removes an existing file" {
  val dir = scratchDir("delete_real")
  val _ = createDir(dir)
  val path = dir + "/to-delete.txt"
  val _ = writeText(path, "x")
  assertTrue(fileExists(path), "file exists before delete")
  match deleteFile(path) {
    case Ok(_) -> assertFalse(fileExists(path), "file gone after delete")
    case Err(e) -> panic("deleteFile failed: " + IOError.message(e))
  }
  val _ = deleteDirRecursive(dir)
}

test "listFiles and listDirs enumerate direct children only" {
  val dir = scratchDir("list_direct")
  val _ = createDir(dir)
  val _ = writeText(dir + "/a.txt", "a")
  val _ = writeText(dir + "/b.txt", "b")
  val _ = createDir(dir + "/sub")
  val _ = writeText(dir + "/sub/nested.txt", "nested")

  match listFiles(dir) {
    case Ok(files) -> assertEqualInt(files.count, 2, "two direct files listed")
    case Err(e) -> panic("listFiles failed: " + IOError.message(e))
  }
  match listDirs(dir) {
    case Ok(dirs) -> assertEqualInt(dirs.count, 1, "one direct subdirectory listed")
    case Err(e) -> panic("listDirs failed: " + IOError.message(e))
  }
  val _ = deleteDirRecursive(dir)
}

test "listFilesRecursive walks nested subdirectories" {
  val dir = scratchDir("list_recursive")
  val _ = createDir(dir)
  val _ = writeText(dir + "/top.txt", "top")
  val _ = createDir(dir + "/sub")
  val _ = writeText(dir + "/sub/nested.txt", "nested")
  val _ = createDir(dir + "/sub/deeper")
  val _ = writeText(dir + "/sub/deeper/deepest.txt", "deepest")

  match listFilesRecursive(dir) {
    case Ok(files) -> assertEqualInt(files.count, 3, "all three nested files found")
    case Err(e) -> panic("listFilesRecursive failed: " + IOError.message(e))
  }
  val _ = deleteDirRecursive(dir)
}

test "stat succeeds for an existing file and fails for a missing one" {
  val dir = scratchDir("stat")
  val _ = createDir(dir)
  val path = dir + "/stated.txt"
  val _ = writeText(path, "x")

  match stat(path) {
    case Ok(_) -> ()
    case Err(e) -> panic("stat on an existing file failed: " + IOError.message(e))
  }
  match stat(dir + "/missing.txt") {
    case Ok(_) -> panic("expected FileNotFound for stat on a missing file")
    case Err(FileNotFound(_)) -> ()
    case Err(other) -> panic("expected FileNotFound, got: " + IOError.message(other))
  }
  val _ = deleteDirRecursive(dir)
}

test "deleteDirRecursive removes a populated directory tree" {
  val dir = scratchDir("delete_recursive")
  val _ = createDir(dir)
  val _ = writeText(dir + "/a.txt", "a")
  val _ = createDir(dir + "/sub")
  val _ = writeText(dir + "/sub/b.txt", "b")

  match deleteDirRecursive(dir) {
    case Ok(_) -> assertFalse(dirExists(dir), "directory gone after recursive delete")
    case Err(e) -> panic("deleteDirRecursive failed: " + IOError.message(e))
  }
}
