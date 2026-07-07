//! jvm_auto_ffi_bridge_self_test.l — regression tests for two JVM auto-FFI
//! robustness gaps from `docs/44-jvm-production-readiness-plan.md` (m-7,
//! M-15) that require driving the in-process `Jvm.Bridge` / `Jvm.AutoFfi`
//! pipeline directly rather than compiling ordinary user code (the pattern
//! `auto_ffi_jvm_self_test.l` uses):
//!
//!   * m-7 (#2214): `Jvm.AutoFfi.splitPathListOn` must split `LYRIC_FFI_JARS`
//!     on the platform-correct separator ONLY (`;` on Windows, `:`
//!     elsewhere), never both — splitting on both misparses a Windows
//!     absolute path's drive-letter colon (`C:\foo.jar`).  `splitPathListOn`
//!     takes the "is this host Windows" flag as an explicit parameter (the
//!     same testability pattern `AppHost.launcherName` /
//!     `AppHost.preferHostRid` use for their RID parameter) so the Windows
//!     behaviour is asserted deterministically regardless of the actual CI
//!     host running this suite.
//!   * M-15 part 1 (#2215): `T.new()` on an `extern type` naming an abstract
//!     JDK class must abort compilation with an `error[J005]` diagnostic
//!     instead of producing bytecode that throws `InstantiationError` at
//!     runtime.  Compiling is itself the observable behaviour under test, so
//!     this drives `Jvm.Bridge.compileToJarBundled` in-process and asserts on
//!     the `Bug` raised, rather than asserting on a compiled program's
//!     runtime output.
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-compiler/jvm/`) so it can
//! import `Jvm.AutoFfi` / `Jvm.Bridge` without overflowing the F# bootstrap
//! emitter's transitive-closure limit, mirroring
//! `msil_project_bridge_self_test.l`.  `lyric test` resolves these
//! compiler-package imports from pre-compiled stage-1 bundle DLLs, so no
//! `LYRIC_LOAD_COMPILER=1` recompile is needed.  Run on the default
//! (`dotnet`) target — the pipeline under test runs in-process regardless of
//! which target the OUTER test binary itself is compiled for; M-15 part 2
//! (`findBestInstanceMethod` walking to `java/lang/Object`) is covered
//! end-to-end on the real JVM target by `auto_ffi_jvm_self_test.l` instead,
//! since it needs an actual JVM run to prove the resolved call executes
//! correctly.
//!
//! Run via:
//!   lyric test lyric-compiler/lyric/jvm_auto_ffi_bridge_self_test.l
@test_module
package Lyric.JvmAutoFfiBridgeSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.AutoFfi
import Jvm.Bridge

// ─── m-7 / #2214: splitPathListOn separator handling ─────────────────────────
test "splitPathListOn splits on ':' only when the host is not Windows" {
  val parts = splitPathListOn("/opt/libs/a.jar:/opt/libs/b.jar", false)
  assertEqualInt(parts.count, 2, "two paths split on ':'")
  assertEqual(parts[0], "/opt/libs/a.jar", "first path")
  assertEqual(parts[1], "/opt/libs/b.jar", "second path")
}

test "splitPathListOn preserves Windows drive-letter colons and splits on ';' (#2214)" {
  val parts = splitPathListOn("C:\\libs\\a.jar;C:\\libs\\b.jar", true)
  assertEqualInt(parts.count, 2, "two paths split on ';', drive-letter colons untouched")
  assertEqual(parts[0], "C:\\libs\\a.jar", "first path keeps its drive-letter colon intact")
  assertEqual(parts[1], "C:\\libs\\b.jar", "second path keeps its drive-letter colon intact")
}

test "splitPathListOn on Windows does not split a single drive-letter path into bogus fragments (#2214)" {
  val parts = splitPathListOn("C:\\libs\\a.jar", true)
  assertEqualInt(parts.count, 1, "single path survives unsplit — the pre-fix bug split this into 2")
  assertEqual(parts[0], "C:\\libs\\a.jar", "unsplit, drive-letter colon intact")
}

test "splitPathListOn treats ';' as ordinary text when the host is not Windows" {
  // Guards the "single separator only" property in the other direction: a
  // stray ';' in a non-Windows path list must not be treated as a delimiter.
  val parts = splitPathListOn("/opt/libs/a;b.jar:/opt/libs/c.jar", false)
  assertEqualInt(parts.count, 2, "only ':' delimits on a non-Windows host")
  assertEqual(parts[0], "/opt/libs/a;b.jar", "';' inside the first path is not a separator")
  assertEqual(parts[1], "/opt/libs/c.jar", "second path")
}

// ─── M-15 part 1 / #2215: T.new() on an abstract JDK class ──────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-autoffi-bridge-" + label + "-" + uuidToString(newUuid()))
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

test "T.new() on an abstract JDK class aborts compilation under error[J005], not a runtime InstantiationError (#2215)" {
  val dir = freshTempDir("abstract-ctor")
  val outPath = Path.join(dir, "AbstractCtor.jar")
  val source = "package AbstractCtor.App\n" + "\n" + "extern type JReader = \"java.io.Reader\"\n" + "\n" +
    "func main(): Unit {\n" +
    "  val r = JReader.new()\n" +
    "  println(0)\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  try {
    compileToJarBundled(source, outPath, "AbstractCtor", noStdlib)
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
  }
  cleanup(dir)
  assertTrue(
    panicked,
    "constructing java.io.Reader (abstract) must abort compilation rather than compiling successfully"
  )
  assertTrue(
    Str.contains(caughtMessage, "error[J005]"),
    "diagnostic carries the J005 code (got: " + caughtMessage + ")"
  )
  assertTrue(
    Str.contains(caughtMessage, "abstract"),
    "diagnostic names the abstract-class problem (got: " + caughtMessage + ")"
  )
}

test "T.new() on a concrete JDK class still compiles fine (no false-positive J005)" {
  val dir = freshTempDir("concrete-ctor")
  val outPath = Path.join(dir, "ConcreteCtor.jar")
  val source = "package ConcreteCtor.App\n" + "\n" + "extern type JStringBuilder = \"java.lang.StringBuilder\"\n" + "\n" +
    "func main(): Unit {\n" +
    "  val sb = JStringBuilder.new()\n" +
    "  println(0)\n" +
    "}\n"
  val noStdlib: List[String] = newList()
  var panicked = false
  var caughtMessage = ""
  val ok = try {
    compileToJarBundled(source, outPath, "ConcreteCtor", noStdlib)
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
    false
  }
  cleanup(dir)
  assertTrue(not panicked, "StringBuilder (concrete) must not raise J005 (message: " + caughtMessage + ")")
  assertTrue(ok, "StringBuilder (concrete) construction compiles successfully")
}
