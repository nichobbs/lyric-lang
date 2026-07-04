//! file_jvm_self_test.l — `Std.File` end-to-end on `--target jvm` (band J6,
//! epic #2663 / #2669).
//!
//! `Std.File` was one of the two packages the bundled JVM compile skipped
//! since the J003 note first appeared: its `_kernel_jvm/file_host.l` routed
//! every function through a `lyric.stdlib.jvm.FileHost` shim class that never
//! existed at runtime.  The kernel is now pure Lyric over the JVM auto-FFI
//! (`java.io.File` / `FileInputStream` / `FileOutputStream`), and the opaque
//! last-write timestamp crosses the kernel boundary as `FileTime` on both
//! targets (System.DateTime on .NET, boxed epoch-milliseconds here).
//!
//! Exercises the full public `Std.File` surface against a real temp
//! directory: text and byte round-trips, existence probes, directory
//! create/list/delete, `stat` ordering, and the `Result.Err` paths for a
//! missing file.
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`)
//! and runs it under `java`.  Imports only `Std.*`.
@test_module
package Jvm.FileSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File

// Test-fixture-only externs (#4840): create a real directory symlink via
// `ln -s` (no Lyric-level symlink API exists) to exercise the
// `deleteDirRecursive` nofollow guard end-to-end. `ProcessBuilder(List[String])`
// (the `List<String>` constructor, not the `String...` varargs one) accepts a
// Lyric `List[String]` directly — its runtime type genuinely implements
// `java.util.List`, unlike the erased `Object[]` a `.toArray()` call would
// produce, which fails auto-FFI overload resolution against either
// `ProcessBuilder` constructor.
extern type JFile = "java.io.File"

extern type JPath = "java.nio.file.Path"

extern type JFiles = "java.nio.file.Files"

extern type JProcessBuilder = "java.lang.ProcessBuilder"

extern type JProcess = "java.lang.Process"

func isSymlinkFixture(path: in String): Bool {
  val f = JFile.new(path)
  val p: JPath = f.toPath()
  JFiles.isSymbolicLink(p)
}

// Returns `ln -s`'s exit code so the caller can assert fixture setup
// succeeded, distinguishing a broken test fixture from a real fix regression
// at a glance (#5057).
func makeSymlinkFixture(linkPath: in String, targetPath: in String): Int {
  val existing = JFile.new(linkPath)
  existing.delete()
  val args: List[String] = newList()
  args.add("ln")
  args.add("-s")
  args.add(targetPath)
  args.add(linkPath)
  val pb = JProcessBuilder.new(args)
  val proc: JProcess = pb.start()
  proc.waitFor()
}

val root: String = "/tmp/lyric_file_jvm_self_test"

func setupRoot(): Bool {
  deleteDirRecursive(root)
  match createDir(root) {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "text round-trip and existence probes" {
  assertTrue(setupRoot(), "temp root created")
  val p = root + "/hello.txt"
  match writeText(p, "hello jvm file") {
    case Ok(_) -> assertTrue(true, "writeText Ok")
    case Err(_) -> assertTrue(false, "writeText must succeed")
  }
  assertTrue(fileExists(p), "fileExists after write")
  assertTrue(not fileExists(p + ".missing"), "missing file probes false")
  match readText(p) {
    case Ok(s) -> assertEqual(s, "hello jvm file", "readText round-trips")
    case Err(_) -> assertTrue(false, "readText must succeed")
  }
  assertEqual(readTextOrPanic(p), "hello jvm file", "readTextOrPanic round-trips")
}

test "byte round-trip" {
  val p = root + "/bytes.bin"
  // ASCII bytes so the content can be verified through readText without
  // indexing erased list elements (element typing is the J4 gap, #2667).
  val bytes: List[Byte] = newList()
  bytes.add(104)
  bytes.add(105)
  match writeBytes(p, bytes) {
    case Ok(_) -> assertTrue(true, "writeBytes Ok")
    case Err(_) -> assertTrue(false, "writeBytes must succeed")
  }
  match readBytes(p) {
    case Ok(rb) -> assertEqualInt(rb.count, 2, "2 bytes read back")
    case Err(_) -> assertTrue(false, "readBytes must succeed")
  }
  assertEqualInt(readBytesOrPanic(p).count, 2, "slice read has 2 bytes")
  match readText(p) {
    case Ok(s) -> assertEqual(s, "hi", "byte content round-trips (104,105 = \"hi\")")
    case Err(_) -> assertTrue(false, "readText of the byte file must succeed")
  }
}

test "missing file reports Err, not a crash" {
  match readText(root + "/nope.txt") {
    case Ok(_) -> assertTrue(false, "missing file must not read")
    case Err(_) -> assertTrue(true, "missing file is an Err")
  }
}

test "directory create, list, and recursive delete" {
  val sub = root + "/subdir"
  match createDir(sub) {
    case Ok(_) -> assertTrue(true, "createDir Ok")
    case Err(_) -> assertTrue(false, "createDir must succeed")
  }
  assertTrue(dirExists(sub), "dirExists after create")
  match writeText(sub + "/a.txt", "a") {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "write into subdir must succeed")
  }
  match listFiles(sub) {
    case Ok(fs) -> assertEqualInt(fs.count, 1, "one file listed in subdir")
    case Err(_) -> assertTrue(false, "listFiles must succeed")
  }
  match listDirs(root) {
    case Ok(ds) -> assertEqualInt(ds.count, 1, "one subdirectory listed")
    case Err(_) -> assertTrue(false, "listDirs must succeed")
  }
  match deleteDirRecursive(sub) {
    case Ok(_) -> assertTrue(not dirExists(sub), "recursive delete removes the tree")
    case Err(_) -> assertTrue(false, "deleteDirRecursive must succeed")
  }
}

// #4840: recursive delete must not follow a directory symlink into its
// target. A tree containing a symlink to an outside directory is deleted;
// the symlink itself must be gone, but the outside directory (and its
// contents) must survive untouched.
test "recursive delete does not traverse a directory symlink" {
  val outside = root + "_outside"
  val tree = root + "_tree"
  val _c1 = deleteDirRecursive(outside)
  val _c2 = deleteDirRecursive(tree)
  match createDir(outside) {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "outside dir must be created")
  }
  match writeText(outside + "/keep.txt", "KEEP") {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "write into outside dir must succeed")
  }
  match createDir(tree) {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "tree dir must be created")
  }
  val link = tree + "/link"
  assertEqualInt(makeSymlinkFixture(link, outside), 0, "ln -s must succeed")
  assertTrue(isSymlinkFixture(link), "fixture is really a symlink")
  match deleteDirRecursive(tree) {
    case Ok(_) -> assertTrue(not dirExists(tree), "the tree itself is fully removed")
    case Err(_) -> assertTrue(false, "deleteDirRecursive on the tree must succeed")
  }
  assertTrue(dirExists(outside), "the symlink target directory survives")
  match readText(outside + "/keep.txt") {
    case Ok(s) -> assertEqual(s, "KEEP", "the symlink target's contents survive untouched")
    case Err(_) -> assertTrue(false, "outside/keep.txt must still be readable")
  }
  val _c3 = deleteDirRecursive(outside)
}

test "stat orders modification times" {
  val older = root + "/older.txt"
  val newer = root + "/newer.txt"
  match writeText(older, "1") {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "write older must succeed")
  }
  match writeText(newer, "2") {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "write newer must succeed")
  }
  match stat(older) {
    case Ok(a) -> {
      match stat(newer) {
        case Ok(b) -> assertTrue(not fileStatIsNewer(a, b), "older file is not newer than the newer file")
        case Err(_) -> assertTrue(false, "stat(newer) must succeed")
      }
    }
    case Err(_) -> assertTrue(false, "stat(older) must succeed")
  }
  match stat(root + "/nope.txt") {
    case Ok(_) -> assertTrue(false, "stat of a missing file must not succeed")
    case Err(_) -> assertTrue(true, "stat of a missing file is an Err")
  }
}
