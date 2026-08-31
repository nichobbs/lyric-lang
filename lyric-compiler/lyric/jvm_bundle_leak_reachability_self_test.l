//! jvm_bundle_leak_reachability_self_test.l — end-to-end tests for two
//! `Jvm.Bridge` multi-package bundling bugs found in review of PR #6631:
//!
//!   #6766 — a J003-skipped (unreachable + codegen-panicked) package's
//!   signature/case/ctor registrations were never rolled back, so a LATER
//!   bundled package could resolve a bare call/construction into a class
//!   that was never written to the JAR.
//!
//!   #6767 — call-reachability resolved a bare call name through the raw,
//!   non-import-aware registry, while codegen resolves the SAME bare name
//!   through `importAwareRegistry(file, registry)` (own-imports-last-wins).
//!   When the two disagreed, reachability could mark the WRONG package
//!   "referenced", silently J003-skipping the package codegen ACTUALLY
//!   calls into — shipping an incomplete JAR that throws
//!   `NoClassDefFoundError` at runtime on an otherwise-"successful" build.
//!
//! J003-skip (a codegen failure silently dropped instead of failing the
//! build) applies ONLY to packages bundled via the `stdlibSources` list of
//! the SINGLE-FILE bridge (`compileToJarBundledWithFeatures`) — a "sibling
//! project package" passed through the multi-package project bridge
//! (`compileProjectToJarBundledWithFeatures`, `pkgSrcs`) is always fatal on
//! codegen failure regardless of reachability (see that function's own doc
//! comment).  So every fixture package below rides `stdlibSources`, with a
//! single `source` entry package, mirroring how a real multi-package build
//! bundles the transitive stdlib-import closure.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/jvm_bundle_leak_reachability_self_test.l
@test_module
package Lyric.JvmBundleLeakReachabilitySelfTest

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

// ─── Helpers (mirrors jvm_cross_package_collision_self_test.l) ───────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-leak-" + label + "-" + uuidToString(newUuid()))
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

// Compile `source` (the entry package) plus `stdlibSources` (bundled,
// J003-skip-eligible packages) into a JAR, WITHOUT panicking on a build
// failure — callers that expect the build itself to (correctly) fail use
// this instead of `compileAndRunSingleJvm`.
func compileSingleJvm(label: in String, source: in String, stdlibSources: in List[String]): Bool {
  val dir = freshTempDir(label)
  val jarPath = Path.join(dir, label + ".jar")
  val ok = compileToJarBundled(source, jarPath, label, stdlibSources, "0.1.0")
  cleanup(dir)
  ok
}

// As `compileSingleJvm`, but compiles into a runnable JAR and executes it via
// `java -jar`.  Mirrors `jvm_cross_package_collision_self_test.l`'s
// `compileAndRunJvm`.
func compileAndRunSingleJvm(label: in String, source: in String, stdlibSources: in List[String]): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val jarPath = Path.join(dir, label + ".jar")
  val ok = compileToJarBundled(source, jarPath, label, stdlibSources, "0.1.0")
  if not ok {
    cleanup(dir)
    panic(label + ": compileToJarBundled returned false")
  }
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val result = Capture.runCaptureWithDiagnostics("java", args, "")
  cleanup(dir)
  result
}

// ─── #6767: call-reachability must resolve a bare call the same way codegen
// does ──────────────────────────────────────────────────────────────────────
//
// `PkgA` and `PkgB` both export a bare `choose(): Int`.  `PkgA` is bundled
// FIRST (baseline `collectFileSigsSeeded` runs over `stdlibSources` in list
// order), so the raw, non-import-aware registry's bare-key winner is `PkgA`.
// `VictimPkg` imports `PkgA` THEN `PkgB` and calls `choose()` unqualified —
// codegen's `importAwareRegistry` re-points the bare key to whichever import
// was scanned LAST (`PkgB`, since imports are scanned in declaration order
// and each match overwrites the previous one), so the REAL emitted bytecode
// is `invokestatic PkgB.choose()`.  `PkgB.choose()` deliberately panics in
// JVM codegen (`old(...)` is unsupported there — "EOld not supported in JVM
// codegen").  The entry package imports `VictimPkg` and calls `run()`.
//
// Before the fix: reachability resolves `choose()` through the raw registry
// (bare-key first-wins winner `PkgA`), so `PkgA` is marked "referenced" and
// `PkgB` is NOT — `PkgB`'s panic is silently J003-skipped, and the JAR ships
// without `PkgB`'s class even though `VictimPkg`'s REAL bytecode invokes it
// — `NoClassDefFoundError` at runtime on a build that reported success.
//
// After the fix: reachability resolves `choose()` through the SAME
// import-aware view codegen uses, correctly marking `PkgB` referenced —
// `PkgB`'s panic becomes FATAL, and `compileToJarBundled` returns `false`
// instead of shipping a broken JAR.
test "reachability must mark the package codegen actually calls into as referenced (#6767)" {
  val stdlibSources: List[String] = newList()
  stdlibSources.add("package PkgA\n" + "\n" + "pub func choose(): Int {\n" + "  1\n" + "}\n")
  stdlibSources.add("package PkgB\n" + "\n" + "pub func choose(): Int {\n" + "  old(2)\n" + "}\n")
  stdlibSources.add(
    "package VictimPkg\n" + "\n" + "import PkgA\n" + "import PkgB\n" + "\n" + "pub func run(): Int {\n" + "  choose()\n" +
      "}\n"
  )
  val source = "package EntryPkg\n" + "\n" + "import VictimPkg\n" + "\n" + "func main(): Int {\n" +
    "  println(VictimPkg.run())\n" +
    "  0\n" +
    "}\n"
  val ok = compileSingleJvm("reach-mismatch", source, stdlibSources)
  assertFalse(
    ok,
    "reachability_matches_codegen: PkgB.choose() is genuinely invoked (per codegen's own import-aware " +
      "resolution) so its codegen panic must FAIL the build, not be silently J003-skipped into a broken JAR"
  )
}

// A companion test isolating the SAME collision on the SUCCESS path: when
// neither `PkgC` nor `PkgD` panics, both bare-name-colliding packages must
// still bundle correctly and the REAL call must land on whichever import was
// declared LAST (`PkgD`) — pins the codegen-side resolution this whole class
// of bug depends on, independent of the reachability mismatch above.
test "bare call to a colliding import resolves to the LAST-declared import at runtime" {
  val stdlibSources: List[String] = newList()
  stdlibSources.add("package PkgC\n" + "\n" + "pub func choose(): String {\n" + "  \"from-C\"\n" + "}\n")
  stdlibSources.add("package PkgD\n" + "\n" + "pub func choose(): String {\n" + "  \"from-D\"\n" + "}\n")
  stdlibSources.add(
    "package VictimPkg2\n" + "\n" + "import PkgC\n" + "import PkgD\n" + "\n" + "pub func run(): String {\n" +
      "  choose()\n" +
      "}\n"
  )
  val source = "package EntryPkg2\n" + "\n" + "import VictimPkg2\n" + "\n" + "func main(): Int {\n" +
    "  println(VictimPkg2.run())\n" +
    "  0\n" +
    "}\n"
  val result = compileAndRunSingleJvm("bare-collision-success", source, stdlibSources)
  assertEqualInt(result.exitCode, 0, "bare_collision_success: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "from-D",
    "bare_collision_success: unqualified choose() resolves to the last import, PkgD"
  )
}
