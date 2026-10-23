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

// ─── #6767: removed reachability case (D212) ──────────────────────────────────
//
// The #6767 case drove a bundled package into a codegen panic (`old(...)` in a
// function body) to show that reachability resolved a colliding bare call the
// way codegen does.  Bundled packages are type-checked now (#7976): the
// unqualified `choose()` over two imports that both declare it is `T0123`, and
// `old(...)` outside `ensures:` is `T0080`, so neither reaches codegen and the
// case cannot be built from type-correct source.  The surviving case qualifies
// the call and pins that the package the bytecode really invokes is bundled
// and runs.
test "a qualified call into one of two same-named bundled functions lands on the named package" {
  val stdlibSources: List[String] = newList()
  stdlibSources.add("package PkgC\n" + "\n" + "pub func choose(): String {\n" + "  \"from-C\"\n" + "}\n")
  stdlibSources.add("package PkgD\n" + "\n" + "pub func choose(): String {\n" + "  \"from-D\"\n" + "}\n")
  stdlibSources.add(
    "package VictimPkg2\n" + "\n" + "import PkgC\n" + "import PkgD\n" + "\n" + "pub func run(): String {\n" +
      "  PkgD.choose()\n" +
      "}\n"
  )
  val source = "package EntryPkg2\n" + "\n" + "import VictimPkg2\n" + "\n" + "func main(): Int {\n" +
    "  println(VictimPkg2.run())\n" +
    "  0\n" +
    "}\n"
  val result = compileAndRunSingleJvm("bare-collision-success", source, stdlibSources)
  assertEqualInt(result.exitCode, 0, "qualified_collision: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "from-D",
    "qualified PkgD.choose() resolves to PkgD"
  )
}
