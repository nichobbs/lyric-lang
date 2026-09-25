//! native_string_normalize_panic_self_test.l — #7304: `Std.String.isNormalized`/
//! `normalize`'s pure-layer bodies call `s.isNormalized()`/`s.normalize()` via
//! UFCS, exactly like every other wrapper in that file (`trim`, `toLower`, ...).
//! That pattern is only safe on MSIL/JVM because both backends recognize the
//! method name as a hardcoded intrinsic. Native had no such intrinsic and no
//! explicit guard, so before this fix the call fell through to the generic
//! UFCS resolver, which looks up `<currentPackage>.<name>/<arity>` — while
//! lowering `Std.String.isNormalized`'s own body, that key is
//! `Std.String.isNormalized/1`, the very function being compiled. The result
//! was silent infinite self-recursion (a runtime stack overflow) instead of
//! the clean compile-time "not yet supported for --target native" panic every
//! other un-ported String method gives (see `lowerMember`'s `.length`-only
//! string-member panic and `lowerScalarMethodCall`'s fallthrough).
//!
//! Fixed by explicitly intercepting `isNormalized`/`normalize` in
//! `Lyric.LlvmCodegen.lowerScalarMethodCall` with a named panic, mirroring the
//! `indexOf`/`lastIndexOf` self-package recursion guard `indexof_native_self_test.l`
//! already covers for the same hazard class (#6752).
//!
//! Drives `Lyric.LlvmBridge.compileToNativeWithFlags` in-process against a
//! real bundled program that imports `Std.String` (pulling the real
//! `lyric-stdlib/std/string.l` source into the bundle) and calls
//! `.isNormalized()` / `.normalize()`, and asserts the compile FAILS with a
//! `Bug` panic naming the method — not that it silently succeeds (which would
//! ship a program that stack-overflows at runtime the first time either
//! method is called).
//!
//! No `clang` / `lyric-rt` build required — this only exercises the
//! codegen-time panic, never links or runs a binary.
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/native_string_normalize_panic_self_test.l
@test_module
package Lyric.NativeStringNormalizePanicSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.String as Str
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Uuid as Uuid
import Lyric.Emitter
import Lyric.LlvmBridge

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

record CompileOutcome {
  panicked: Bool
  panicMsg: String
}

func attemptCompile(source: in String, stem: in String): CompileOutcome {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val noFlags: List[String] = newList()
  var panicked = false
  var panicMsg = ""
  try {
    val _ = compileToNativeWithFlags(source, stem, stdlib, "", "0", noFlags, newList(), "")
  } catch Bug as b {
    panicked = true
    panicMsg = b.message
  }
  CompileOutcome(panicked = panicked, panicMsg = panicMsg)
}

test "s.isNormalized() panics at native compile time instead of self-recursing (#7304)" {
  val dir = Path.join(tempBase(), "lyric-native-normalize-panic-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val source = "package NativeIsNormalizedRepro\n" + "import Std.String\n" + "func main(): Unit {\n" +
    "  val s = \"cafe\"\n" +
    "  val _ = s.isNormalized()\n" +
    "}\n"
  val outcome = attemptCompile(source, stem)
  assertTrue(outcome.panicked, "s.isNormalized() must panic at compile time on --target native, not compile silently")
  assertTrue(
    Str.contains(outcome.panicMsg, "isNormalized") and Str.contains(outcome.panicMsg, "not yet supported"),
    "panic must name the unsupported method (got: " + outcome.panicMsg + ")"
  )
}

test "s.normalize() panics at native compile time instead of self-recursing (#7304)" {
  val dir = Path.join(tempBase(), "lyric-native-normalize-panic-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val source = "package NativeNormalizeRepro\n" + "import Std.String\n" + "func main(): Unit {\n" +
    "  val s = \"cafe\"\n" +
    "  val _ = s.normalize()\n" +
    "}\n"
  val outcome = attemptCompile(source, stem)
  assertTrue(outcome.panicked, "s.normalize() must panic at compile time on --target native, not compile silently")
  assertTrue(
    Str.contains(outcome.panicMsg, "normalize") and Str.contains(outcome.panicMsg, "not yet supported"),
    "panic must name the unsupported method (got: " + outcome.panicMsg + ")"
  )
}

test "other native String methods unaffected by the isNormalized/normalize guard (#7304)" {
  val dir = Path.join(tempBase(), "lyric-native-normalize-panic-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val source = "package NativeStringUnaffectedRepro\n" + "func main(): Unit {\n" + "  val s = \"  hi  \"\n" +
    "  val _ = s.trim()\n" +
    "  val _ = s.toLower()\n" +
    "}\n"
  val outcome = attemptCompile(source, stem)
  assertTrue(
    not outcome.panicked,
    "unrelated String methods must still compile cleanly (got panic: " + outcome.panicMsg + ")"
  )
}
