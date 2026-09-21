//! jvm_generic_call_result_cross_package_self_test.l — regression test for
//! #6929: a field read on a local bound to a CROSS-PACKAGE generic
//! function's call result still erased to `Object`, because the callee's
//! return-type record could be declared in yet a THIRD package.
//!
//! Split out from #6708's fix (D-progress-878) as an explicitly out-of-scope
//! residual gap: `Jvm.Codegen.recordRetClassOf` (`codegen/01_types.l`)
//! resolves a function's declared return type to its raw class only when the
//! record is declared in the SAME FILE as the function — a same-file-only
//! pre-scan run at `collectFileSigsSeeded`'s signature-collection time
//! (`Jvm.Bridge`). A record declared in a DIFFERENT file (its own package,
//! or a third package entirely) was unresolvable there: resolving it would
//! need the bundle-wide constructor registry (`ctorReg`), which was only
//! PARTIALLY populated at that point in the original interleaved
//! sigs-then-ctors-per-file registration order (`Jvm.Bridge`'s
//! `collectFileSigsSeeded(userFile, ...)` ran before ANY `collectFileCtors`
//! call for a cross-package file had a chance to run) — so the field read
//! fell through to the erased-`Object` bundle-wide `field:<name>` fallback,
//! risking a silent wrong-class resolution exactly like #6691/#6708's own
//! failure mode.
//!
//! Fixed by (1) reordering `Jvm.Bridge`'s registration passes so every
//! `collectFileCtors` call across the whole bundle (user + stdlib +
//! restored) runs before any `collectFileSigsSeeded` call, (2) adding
//! `Jvm.Codegen.recordRetClassOfBundle` — a bundle-wide fallback consulted
//! when the same-file scan misses, resolving through the now-fully-populated
//! `ctorReg` the same way `recordParamClassOf`'s `ctorClassFor` lookup
//! already does for parameters — and (3) threading that same `ctorReg`
//! into `Jvm.Bridge.collectMonoSpecializedSigs`, which registers a
//! *mono-specialised* copy of a generic function (see below) and had its
//! own hardcoded `recordRetClass = None`.
//!
//! Repro shape (three packages, so the callee's OWN package doesn't share a
//! file with either the record's declaring package or the caller):
//!   - `EntryPkg` declares `record Entry[K, V] { key: K, value: V }`.
//!   - `MakerPkg` declares a generic `func makeEntry[K, V](...): EntryPkg.Entry[K, V]`.
//!   - `App` (a THIRD package) calls `MakerPkg.makeEntry(...)` with literal
//!     arguments and reads a field on the result.
//!   `Lyric.Mono` DOES monomorphize this call, even across the package
//!   boundary — its call-site walk isn't restricted to the callee's own
//!   file, only to inferring concrete type args from the CALLER's literals —
//!   producing a specialised copy (`makeEntry__Int__Int`) whose signature is
//!   registered via a separate path, `Jvm.Bridge.collectMonoSpecializedSigs`,
//!   not `collectFileSigsSeeded`. Both registration paths needed the
//!   `recordRetClassOfBundle` fix for this repro to resolve correctly.
//!
//! Each test bundles multiple Lyric packages into one runnable JAR via the
//! in-process self-hosted `Jvm.Bridge` pipeline (mirroring
//! `jvm_cross_package_collision_self_test.l`'s `compileAndRunJvm`), runs it
//! via `java -jar`, and asserts on stdout.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/jvm_generic_call_result_cross_package_self_test.l
@test_module
package Lyric.JvmGenericCallResultCrossPackageSelfTest

import Std.Core
import Std.Collections
import Std.File as File
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.Bridge

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-genret-xpkg-" + label + "-" + uuidToString(newUuid()))
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

func compileAndRunJvm(label: in String, pkgSrcs: in List[String], entryPkgName: in String): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val jarPath = Path.join(dir, label + ".jar")
  val stdlibSources: List[String] = newList()
  val noFeatures: List[String] = newList()
  val noDepTemplateSrcs: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPaths: List[String] = newList()
  var pi = 0
  while pi < pkgSrcs.count {
    noPaths.add("")
    pi += 1
  }
  val ok = compileProjectToJarBundledWithFeatures(
    pkgSrcs,
    jarPath,
    entryPkgName,
    stdlibSources,
    noFeatures,
    noFeatures,
    noDepTemplateSrcs,
    noDefines,
    "0.1.0",
    noPaths
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

test "field read on a local bound to a cross-package generic function's call result resolves against the real record class (#6929)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add("package EntryPkg\n" + "\n" + "pub record Entry[K, V] {\n" + "  key: K\n" + "  value: V\n" + "}\n")
  pkgSrcs.add(
    "package MakerPkg\n" + "\n" + "import EntryPkg\n" + "\n" +
      "pub func makeEntry[K, V](k: K, v: V): EntryPkg.Entry[K, V] {\n" +
      "  EntryPkg.Entry(key = k, value = v)\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package App\n" + "\n" + "import MakerPkg\n" + "import EntryPkg\n" + "\n" + "func main(): Int {\n" +
      "  val e = MakerPkg.makeEntry(1, 42)\n" +
      "  println(e.value)\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("genret-basic", pkgSrcs, "App")
  assertEqualInt(result.exitCode, 0, "run must succeed (stderr=" + result.stderr + ")")
  assertEqual(Std.String.trim(result.stdout), "42", "e.value reads the real Int field, not an erased-Object miscompile")
}

test "chained field read on a cross-package generic function's call result resolves through two levels (#6929)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add("package EntryPkg2\n" + "\n" + "pub record Entry[K, V] {\n" + "  key: K\n" + "  value: V\n" + "}\n")
  pkgSrcs.add(
    "package MakerPkg2\n" + "\n" + "import EntryPkg2\n" + "\n" +
      "pub func makeEntry[K, V](k: K, v: V): EntryPkg2.Entry[K, V] {\n" +
      "  EntryPkg2.Entry(key = k, value = v)\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package App2\n" + "\n" + "import MakerPkg2\n" + "import EntryPkg2\n" + "\n" + "func main(): Int {\n" +
      "  val e = MakerPkg2.makeEntry(\"id-1\", 7)\n" +
      "  val k = e.key\n" +
      "  val v = e.value\n" +
      "  println(k)\n" +
      "  println(v)\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("genret-chained", pkgSrcs, "App2")
  assertEqualInt(result.exitCode, 0, "run must succeed (stderr=" + result.stderr + ")")
  val lines = Std.String.split(Std.String.trim(result.stdout), "\n")
  assertEqualInt(lines.length, 2, "expected 2 output lines (stdout=" + result.stdout + ")")
  assertEqual(lines[0], "id-1", "e.key reads the real String field")
  assertEqual(lines[1], "7", "e.value reads the real Int field")
}
