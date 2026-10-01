//! stdlib/tests/native_kernel_twins_tests.l — the `_kernel_native/` twins of
//! the managed kernels' entry points that the shared `Std.*` modules call
//! (#7933): `Std.ProcessCapture`'s string-argv capture, and the directory
//! entry points `Std.Directory` calls.  Before #7933 the native kernels did
//! not declare them, which the native bundle type check now reports.
//!
//! `Std.Directory`'s own functions catch a host `Bug`, which `--target
//! native` cannot lower (D-N-003), so the directory entry points are called
//! on `Std.FileHost` directly.  The console stdin twins are covered by
//! `console_stdin_tests.l` (`scripts/ci/console-stdin-test.sh --target
//! native`).
//!
//!   lyric test lyric-stdlib/tests/native_kernel_twins_tests.l --target native
@test_module
package Std.NativeKernelTwinsTests

import Std.Core
import Std.Collections
import Std.Environment
import Std.File
import Std.FileHost
import Std.ProcessCapture
import Std.Testing
import Std.Uuid

func scratchDir(): String {
  val base = match getVar("TMPDIR") { case Ok(dir) -> if dir.length > 0 { dir } else { "/tmp" }; case Err(_) -> "/tmp" }
  base + "/lyric-kernel-twins-" + uuidToString(newUuid())
}

func containsStr(xs: in slice[String], want: in String): Bool {
  for x in xs {
    if x == want {
      return true
    }
  }
  false
}

test "ProcessCapture.runCaptureWithDiagnostics passes every argument through verbatim" {
  val args: List[String] = newList()
  args.add("-c")
  args.add("printf '%s|' \"$@\"; cat")
  args.add("sh")
  args.add("a b")
  args.add("q\"uote")
  args.add("back\\")
  args.add("")
  val r = runCaptureWithDiagnostics("/bin/sh", args, "from-stdin")
  assertEqualInt(r.exitCode, 0, "exit code")
  assertFalse(r.timedOut, "not timed out")
  assertEqual(r.stdout, "a b|q\"uote|back\\||from-stdin", "argv and stdin round-trip")
}

test "ProcessCapture.runCapture returns stdout" {
  val args: List[String] = newList()
  args.add("-c")
  args.add("echo out; echo err 1>&2")
  assertEqual(runCapture("/bin/sh", args, ""), "out\n", "stdout only")
}

test "ProcessCapture.runCaptureWithDiagnosticsTimeout reports a timeout" {
  val args: List[String] = newList()
  args.add("-c")
  args.add("sleep 5")
  val r = runCaptureWithDiagnosticsTimeout("/bin/sh", args, "", 100)
  assertTrue(r.timedOut, "timed out")
  assertEqualInt(r.exitCode, 0 - 2, "a timed-out capture reports exit code -2")
}

test "FileHost directory entry points create, enumerate and delete" {
  val root = scratchDir()
  val nested = root + "/sub/inner"
  hostCreateDirectory(nested)
  assertTrue(hostDirectoryExists(nested), "created with parents")
  // Idempotent, as the managed twins' CreateDirectory/mkdirs are.
  hostCreateDirectory(nested)
  match writeText(root + "/a.txt", "a") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "write a.txt: " + IOError.message(e))
  }

  val files = hostEnumerateFiles(root)
  assertEqualInt(files.length, 1, "one file")
  assertTrue(containsStr(files, root + "/a.txt"), "file path")
  val dirs = hostEnumerateDirectories(root)
  assertEqualInt(dirs.length, 1, "one directory")
  assertTrue(containsStr(dirs, root + "/sub"), "directory path")
  val entries = hostEnumerateFileSystemEntries(root)
  assertEqualInt(entries.length, 2, "files and directories")
  assertTrue(containsStr(entries, root + "/a.txt"), "entry: file")
  assertTrue(containsStr(entries, root + "/sub"), "entry: directory")

  hostDeleteDirectory(nested)
  assertFalse(hostDirectoryExists(nested), "empty directory deleted")
  hostDeleteDirectoryRecursive(root, true)
  assertFalse(hostDirectoryExists(root), "tree deleted")
}
