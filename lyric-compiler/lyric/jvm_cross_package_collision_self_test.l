//! jvm_cross_package_collision_self_test.l — end-to-end tests for the
//! self-hosted multi-package JVM bridge (`Jvm.Bridge.compileProjectToJarBundledWithFeatures`)
//! pinning two bare-name cross-package collision fixes (#5455, #5976).
//!
//! Each test bundles multiple Lyric packages into one runnable JAR via the
//! in-process self-hosted `Jvm.Bridge` pipeline, runs it via `java -jar`, and
//! asserts on stdout — the JVM analogue of `msil_project_bridge_self_test.l`.
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-stdlib/tests/`) so it can
//! import `Jvm.Bridge` without overflowing the F# bootstrap emitter's
//! transitive-closure limit (there is none any more — F# is gone — but the
//! self-hosted stage-1 bundle DLLs still resolve the compiler-package
//! imports the same way `msil_project_bridge_self_test.l` does, #2364).
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/jvm_cross_package_collision_self_test.l
@test_module
package Lyric.JvmCrossPackageCollisionSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.Bridge

// ─── Helpers ────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-xpkg-" + label + "-" + uuidToString(newUuid()))
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

// Compile `pkgSrcs` (one source string per package, the entry package being
// the one that declares `func main`) into a runnable JAR and execute it via
// `java -jar`.  Mirrors `msil_project_bridge_self_test.l`'s `compileAndRun`.
func compileAndRunJvm(label: in String, pkgSrcs: in List[String], entryPkgName: in String): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val jarPath = Path.join(dir, label + ".jar")
  val stdlibSources: List[String] = newList()
  val noFeatures: List[String] = newList()
  val noDepTemplateSrcs: List[String] = newList()
  val noDefines: List[String] = newList()
  val ok = compileProjectToJarBundledWithFeatures(
    pkgSrcs,
    jarPath,
    entryPkgName,
    stdlibSources,
    noFeatures,
    noFeatures,
    noDepTemplateSrcs,
    noDefines,
    "0.1.0"
  )
  if not ok {
    cleanup(dir)
    panic(label + ": compileProjectToJarBundledWithFeatures returned false")
  }
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val result = Capture.runCaptureWithDiagnostics("java", args, "")
  cleanup(dir)
  result
}

// ─── #5455: cross-package impl of a native interface with a third-package
// union parameter must not emit a wrong class reference ─────────────────────
// `ImplPkg` implements `IfacePkg.Handler` (declared in a THIRD package,
// `IfacePkg`) whose method parameter is `IfacePkg.Msg`, a union ALSO declared
// in `IfacePkg`.  Before the fix, `ImplPkg.main`'s bare package-qualified
// construction `IfacePkg.Text(value = ...)` resolved through the bundle-wide
// first-wins `ctors` bare-name entry instead of the full dotted path, so it
// could pick up an unrelated same-named case from any other bundled package
// (the live repro hit `Std.Xml.XmlNode$Text`) — `NoClassDefFoundError` at
// runtime with no compile error.
test "cross-package impl method with third-package union parameter dispatches correctly" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package IfacePkg\n" + "\n" + "pub union Msg {\n" + "  case Text(value: String)\n" + "  case Ping\n" + "}\n" + "\n" +
      "pub interface Handler {\n" +
      "  func onMessage(msg: in Msg): String\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package ImplPkg\n" + "\n" + "import IfacePkg\n" + "\n" + "pub record EchoHandler {\n" + "}\n" + "\n" +
      "impl IfacePkg.Handler for EchoHandler {\n" +
      "  func onMessage(msg: in IfacePkg.Msg): String {\n" +
      "    match msg {\n" +
      "      case IfacePkg.Text(v) -> \"text:\" + v\n" +
      "      case IfacePkg.Ping -> \"ping\"\n" +
      "    }\n" +
      "  }\n" +
      "}\n" +
      "\n" +
      "func main(): Int {\n" +
      "  val h = EchoHandler()\n" +
      "  println(h.onMessage(msg = IfacePkg.Text(value = \"hello\")))\n" +
      "  println(h.onMessage(msg = IfacePkg.Ping))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("xpkg-impl-iface", pkgSrcs, "ImplPkg")
  assertEqualInt(result.exitCode, 0, "cross_package_impl_third_package_union: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "text:hello\nping",
    "cross_package_impl_third_package_union: onMessage dispatches to the real IfacePkg.Msg cases"
  )
}

// A package-qualified bare construction (`IfacePkg.Text(value = ...)`) must
// resolve through the full dotted path even with NO impl/interface involved
// — the minimal repro that isolated #5455 from the impl-method machinery.
test "package-qualified case construction resolves to the declaring package, not a same-named bundled case" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add("package QualCtorPkg\n" + "\n" + "pub union Msg {\n" + "  case Text(value: String)\n" + "}\n")
  pkgSrcs.add(
    "package QualCtorApp\n" + "\n" + "import QualCtorPkg\n" + "\n" + "func main(): Int {\n" +
      "  val m = QualCtorPkg.Text(value = \"hi\")\n" +
      "  match m {\n" +
      "    case QualCtorPkg.Text(v) -> println(v)\n" +
      "  }\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("xpkg-qual-ctor", pkgSrcs, "QualCtorApp")
  assertEqualInt(result.exitCode, 0, "qualified_construction_resolves: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "hi",
    "qualified_construction_resolves: constructs and matches QualCtorPkg's own case"
  )
}

// ─── #5976: a file that both IMPORTS a package and declares its OWN type of
// the identical simple name must resolve its own bare references to its OWN
// declaration, not the import's ─────────────────────────────────────────────
// Mirrors the real-world `Std.RegexSafe` shape: `SafePkg` imports `BasePkg`
// (which declares its own `AppError` union) while ALSO declaring its own
// `AppError` union sharing a case name (`TimedOut`) with `BasePkg`'s.
// Before the fix, `SafePkg.errorMessage`'s OWN signature (`e: AppError`)
// resolved the bare `AppError` reference through the import's declared-type
// seed instead of `SafePkg`'s own declaration, so the emitted method
// descriptor named `BasePkg`'s class — a cross-package type mismatch
// surfacing as `ClassCastException`/`NoSuchMethodError` at runtime.
test "a file's own declared type is not shadowed by a same-named type it imports" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package BasePkg\n" + "\n" + "pub union AppError {\n" + "  case TimedOut(message: String)\n" +
      "  case BaseBug(message: String)\n" +
      "}\n" +
      "\n" +
      "pub func baseErrorMessage(e: in AppError): String {\n" +
      "  match e {\n" +
      "    case TimedOut(m) -> \"base-timeout: \" + m\n" +
      "    case BaseBug(m) -> \"base-bug: \" + m\n" +
      "  }\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package SafePkg\n" + "\n" + "import BasePkg\n" + "\n" + "pub union AppError {\n" +
      "  case TimedOut(message: String)\n" +
      "  case SafeBug(message: String)\n" +
      "}\n" +
      "\n" +
      "pub func errorMessage(e: in AppError): String {\n" +
      "  match e {\n" +
      "    case TimedOut(m) -> \"safe-timeout: \" + m\n" +
      "    case SafeBug(m) -> \"safe-bug: \" + m\n" +
      "  }\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package XPkgApp\n" + "\n" + "import SafePkg as Safe\n" + "\n" + "func main(): Int {\n" +
      "  println(Safe.errorMessage(TimedOut(message = \"x\")))\n" +
      "  println(Safe.errorMessage(SafeBug(message = \"y\")))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("xpkg-own-shadow", pkgSrcs, "XPkgApp")
  assertEqualInt(result.exitCode, 0, "own_type_not_shadowed_by_import: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "safe-timeout: x\nsafe-bug: y",
    "own_type_not_shadowed_by_import: SafePkg.errorMessage resolves its OWN AppError, not BasePkg's"
  )
}
