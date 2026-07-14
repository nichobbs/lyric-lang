//! jvm_trycatch_bridge_self_test.l — regression test for the `error[J004]`
//! diagnostic's package-name locator (#3310).
//!
//! `lowerTryCatchExpr` (`lyric-compiler/jvm/codegen/05_stmts.l`) aborts JVM
//! codegen under `error[J004]` when a try-catch used in expression position
//! has a catch arm that yields Unit while the try body yields a value — the
//! JVM backend cannot route an absent value through the shared result slot
//! (documented type-checker gap #2042).  The panic message used to carry
//! only a bare `line:col` prefix, unhelpful once a build bundles dozens of
//! files together (no way to tell which package's catch arm the failure
//! named).  #3310 fixed this by splicing the dotted form of `ctx.pkgName`
//! (the JVM package currently being lowered) into the message right after
//! the `error[J004]` code, matching the same package-name identifier
//! `Jvm.Bridge`'s `error[J002]` wrapper already reports for a
//! referenced-package codegen failure — and keeping the code at the very
//! front so `Jvm.Bridge`'s `b.message.startsWith("error[J0")` passthrough
//! guard (added to avoid double-wrapping, #3311) still recognises it.
//!
//! For a NON-generic function, T0067 (#2355/#3262) now rejects a
//! Unit-catch-arm/value-try-body mismatch at type-check time whenever the
//! `try` is genuinely in value position, so a source-level repro of this
//! shape must reach for a case T0067 cannot see: a **generic** function
//! whose try body yields the abstract type parameter and whose catch arm
//! yields Unit.  The type checker treats the still-unbound type parameter
//! leniently (it can unify with anything), so no T0067 fires at the
//! generic definition; `Lyric.Mono`'s monomorphizer then specialises the
//! function for a concrete call-site type argument (e.g. `Int`), and it is
//! only that specialised copy the JVM codegen sees a genuine value/Unit
//! mismatch in — confirmed against `./bin/lyric build --target jvm` while
//! developing this fix (see the issue for the exact repro and stack trace).
//!
//! Compiling is itself the observable behaviour under test (the abort
//! happens mid-codegen, before any bytecode could run), so — mirroring
//! `jvm_auto_ffi_bridge_self_test.l`'s pattern for `error[J005]` — this
//! drives `Jvm.Bridge.compileToJarBundled` in-process and asserts on the
//! `Bug` raised, rather than asserting on a compiled program's runtime
//! output.
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-compiler/jvm/`), matching
//! `jvm_auto_ffi_bridge_self_test.l`, so it can import `Jvm.Bridge` without
//! overflowing the F# bootstrap emitter's transitive-closure limit.  Run on
//! the default (`dotnet`) target — the pipeline under test (`Jvm.Bridge`)
//! runs in-process regardless of which target the OUTER test binary itself
//! is compiled for.
//!
//! Run via:
//!   lyric test lyric-compiler/lyric/jvm_trycatch_bridge_self_test.l
@test_module
package Lyric.JvmTryCatchBridgeSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.Bridge

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-trycatch-bridge-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

test "generic fn: Unit-yielding catch arm survives type-check on the abstract type param, then aborts monomorphized codegen under error[J004] naming the owning package (#3310)" {
  val dir = freshTempDir("unit-catch-arm")
  val outPath = Path.join(dir, "TryCatchJ004.jar")
  val source = "package TryCatchJ004.App\n" + "\n" + "func wrap[T](n: Int, v: T): T {\n" + "  val r = try {\n" +
    "    v\n" +
    "  } catch Bug as _ {\n" +
    "    println(0)\n" +
    "  }\n" +
    "  r\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(wrap(1, 42))\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  try {
    compileToJarBundled(source, outPath, "TryCatchJ004", noStdlib)
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
  }
  cleanup(dir)
  assertTrue(
    panicked,
    "the Int-specialised copy of wrap[T] must abort codegen once T is resolved to a concrete, mismatching type"
  )
  assertTrue(
    Str.contains(caughtMessage, "error[J004]: TryCatchJ004.App:"),
    "diagnostic names the owning package (dotted) right after the code, ahead of line:col (got: " + caughtMessage + ")"
  )
  assertTrue(
    Str.contains(caughtMessage, "try-catch used as an expression"),
    "diagnostic keeps its original explanation text (got: " + caughtMessage + ")"
  )
}

test "generic fn: try/catch where every arm yields the type param still compiles fine (no false-positive J004)" {
  val dir = freshTempDir("value-catch-arm")
  val outPath = Path.join(dir, "TryCatchOk.jar")
  val source = "package TryCatchOk.App\n" + "\n" + "func wrap[T](n: Int, v: T): T {\n" + "  val r = try {\n" + "    v\n" +
    "  } catch Bug as _ {\n" +
    "    v\n" +
    "  }\n" +
    "  r\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(wrap(1, 42))\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  val ok = try {
    compileToJarBundled(source, outPath, "TryCatchOk", noStdlib)
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
    false
  }
  cleanup(dir)
  assertTrue(not panicked, "a value-yielding catch arm must not raise J004 (message: " + caughtMessage + ")")
  assertTrue(ok, "try-catch expression with matching-type arms compiles successfully")
}
