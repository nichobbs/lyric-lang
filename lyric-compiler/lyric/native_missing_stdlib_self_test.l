//! native_missing_stdlib_self_test.l -- #8455: a `--target native` build that
//! cannot find the standard library fails before codegen with a dedicated
//! diagnostic (`N0029`, naming every location searched) instead of an
//! unrelated `N0007` "cannot resolve call target 'Std.Console.println/1'".  An
//! import of a `Std.*` package the found stdlib does not declare is `N0030`.
//!
//! Drives `Lyric.LlvmBridge.compileToNativeWithFlags` in-process.  No `clang`
//! or `lyric-rt` is needed: both failures stop before any IR is emitted.
@test_module
package Lyric.NativeMissingStdlibSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Uuid as Uuid
import Std.String as Str
import Lyric.Emitter
import Lyric.LlvmBridge

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func buildStem(): String {
  val dir = Path.join(tempBase(), "lyric-native-missing-stdlib-selftest")
  val _ = File.createDir(dir)
  Path.join(dir, "t_" + Uuid.uuidToString(Uuid.newUuid()))
}

func helloSource(): String {
  "package MissingStdlibHello\nimport Std.Console\nfunc main(): Unit {\n  println(\"hi\")\n}\n"
}

test "an empty LYRIC_STD_PATH fails the build before codegen (#8455)" {
  val emptyDir = Path.join(tempBase(), "lyric-native-empty-stdlib-" + Uuid.uuidToString(Uuid.newUuid()))
  val _ = File.createDir(emptyDir)
  val saved = Environment.getVarOrDefault("LYRIC_STD_PATH", "")
  Environment.setVar("LYRIC_STD_PATH", emptyDir)
  val stdlib = findStdlibSourcesNative()
  Environment.setVar("LYRIC_STD_PATH", saved)
  assertEqualInt(stdlib.count, 0, "an empty LYRIC_STD_PATH directory yields no stdlib sources")
  val noFlags: List[String] = newList()
  var panicked = false
  val ok = try {
    compileToNativeWithFlags(helloSource(), buildStem(), stdlib, "", "0", noFlags, newList(), "", true)
  } catch Bug as _b {
    panicked = true
    false
  }
  assertFalse(ok, "the build must fail")
  assertFalse(panicked, "the failure is a reported diagnostic, not a codegen panic")
}

test "the no-stdlib message names the locations searched (#8455)" {
  val msg = missingStdlibMessage("Std.Console", 0, "/nowhere")
  assertTrue(Str.contains(msg, "N0029"), "code: " + msg)
  assertTrue(Str.contains(msg, "'Std.Console'"), "names the import: " + msg)
  assertTrue(Str.contains(msg, "LYRIC_STD_PATH") and Str.contains(msg, "'/nowhere'"), "names the override: " + msg)
  assertTrue(Str.contains(msg, "lyric-stdlib/std"), "names the walk-up roots: " + msg)
  assertTrue(Str.contains(missingStdlibMessage("Std.Console", 0, ""), "unset"), "unset override is stated")
  assertFalse(Str.contains(msg, "N0007"), "never the codegen code")
}

test "a Std package missing from the found stdlib is N0030 (#8455)" {
  val msg = missingStdlibMessage("Std.Nope", 12, "")
  assertTrue(Str.contains(msg, "N0030") and Str.contains(msg, "'Std.Nope'"), msg)
  val stdlib = findStdlibSourcesNative()
  assertTrue(stdlib.count > 0, "native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  val noFlags: List[String] = newList()
  var panicked = false
  val src = "package MissingStdPkg\nimport Std.Nope\nfunc main(): Unit {\n}\n"
  val ok = try {
    compileToNativeWithFlags(src, buildStem(), stdlib, "", "0", noFlags, newList(), "", true)
  } catch Bug as _b {
    panicked = true
    false
  }
  assertFalse(ok, "importing a nonexistent Std package must fail the build")
  assertFalse(panicked, "reported as a diagnostic, not a codegen panic")
}
