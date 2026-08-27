//! jvm_manifest_package_cycle_self_test.l — regression coverage for #6024:
//! `lyric build --manifest ... --target jvm` on a project whose
//! `[project.packages]` form a legitimate import cycle used to fail
//! type-checking the entry package's own qualified types.
//!
//! Root cause: `Jvm.Bridge.compileProjectToJarBundledWithFeatures` built its
//! flat cross-package `importedPkgs` list from every STDLIB file plus every
//! NON-entry sibling project package, but never added the ENTRY package's
//! (`pkgSrcs[0]`) own items. A sibling package importing the entry package
//! back — e.g. `Web.Kernel.Runtime` importing `Web` for `Request`/`Response`
//! (a real cycle: `Web` also imports `Web.Kernel.Runtime` for `serve`) — saw
//! the entry package's public types as entirely unknown
//! (`error[T0014] unknown qualified type 'Web.Request'`), even though a
//! non-cyclic multi-package library (whose siblings never reference the
//! entry package) built fine, and the single-file bundled JVM path (which
//! folds the whole transitive import closure into one flat registry, entry
//! package included) resolved the identical cycle correctly.
//!
//! Fixture below mirrors the real `Web` / `Web.Kernel.Runtime` shape at
//! minimal size: `Cycle` (entry, declares `func main`) imports `Cycle.Kernel`
//! for `handle`; `Cycle.Kernel` imports `Cycle` back for the `Request` /
//! `Response` record types its `handle` signature names.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/jvm_manifest_package_cycle_self_test.l
@test_module
package Lyric.JvmManifestPackageCycleSelfTest

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
import Lyric.Cli as Cli
import Lyric.Emitter as Emitter
import Jvm.Bridge

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-pkgcycle-" + label + "-" + uuidToString(newUuid()))
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

func writeFileOrPanic(path: in String, content: in String): Unit {
  match File.writeText(path, content) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write " + path + ": " + IOError.message(e))
  }
}

// `Cycle` (entry) and `Cycle.Kernel` reference each other's declarations:
// `Cycle` imports `Cycle.Kernel` for `handle`; `Cycle.Kernel` imports
// `Cycle` back for the `Request` / `Response` record types `handle`'s
// signature names — a same-manifest import cycle, minimal repro of the
// real `Web` / `Web.Kernel.Runtime` shape.
func cycleEntrySource(): String {
  "package Cycle\n" + "\n" + "import Std.Console as Console\n" + "import Cycle.Kernel\n" + "\n" +
    "pub record Request {\n" +
    "  path: String\n" +
    "}\n" +
    "\n" +
    "pub record Response {\n" +
    "  body: String\n" +
    "}\n" +
    "\n" +
    "pub func serve(): String {\n" +
    "  val resp = handle(Request(path = \"/hello\"))\n" +
    "  resp.body\n" +
    "}\n" +
    "\n" +
    "func main(): Int {\n" +
    "  Console.println(serve())\n" +
    "  0\n" +
    "}\n"
}

func cycleKernelSource(): String {
  "package Cycle.Kernel\n" + "\n" + "import Cycle\n" + "\n" + "pub func handle(req: Cycle.Request): Cycle.Response {\n" +
    "  Cycle.Response(body = \"handled:\" + req.path)\n" +
    "}\n"
}

// ─── Bridge-level test: isolates the fix inside `Jvm.Bridge` directly,
// mirroring `jvm_cross_package_collision_self_test.l`'s `compileAndRunJvm`
// pattern (no manifest / filesystem dependency walk involved).
test "compileProjectToJarBundledWithFeatures: entry package's own types resolve in a sibling that imports it back (#6024)" {
  val dir = freshTempDir("bridge")
  defer {
    cleanup(dir)
  }
  val jarPath = Path.join(dir, "cycle.jar")
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(cycleEntrySource())
  pkgSrcs.add(cycleKernelSource())
  val stdlibSources: List[String] = newList()
  val noFeatures: List[String] = newList()
  val noDepTemplateSrcs: List[String] = newList()
  val noDefines: List[String] = newList()
  val ok = compileProjectToJarBundledWithFeatures(
    pkgSrcs,
    jarPath,
    "Cycle",
    stdlibSources,
    noFeatures,
    noFeatures,
    noDepTemplateSrcs,
    noDefines,
    "0.1.0"
  )
  assertTrue(
    ok,
    "compileProjectToJarBundledWithFeatures: a same-manifest package cycle through the entry package compiles " +
      "(previously error[T0014] unknown qualified type 'Cycle.Request')"
  )
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val result = Capture.runCaptureWithDiagnostics("java", args, "")
  assertEqualInt(result.exitCode, 0, "compileAndRun: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "handled:/hello", "compileAndRun: cycle round-trips through both packages")
}

// ─── Manifest-level test: the exact `--manifest ... --target jvm` path the
// issue reports broken, via `Cli.buildProject` (`buildProjectFromManifest`).
test "buildProject: --manifest --target jvm builds a same-manifest package cycle and it runs correctly (#6024)" {
  val root = freshTempDir("manifest")
  defer {
    cleanup(root)
  }
  writeFileOrPanic(
    Path.join(root, "lyric.toml"),
    "[package]\n" + "name = \"Fixture.Cycle\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.Cycle\"\n" +
      "output_assembly = \"Cycle.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Cycle\" = \"src/cycle.l\"\n" +
      "\"Cycle.Kernel\" = \"src/cycle_kernel.l\"\n"
  )
  match File.createDir(Path.join(root, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(root, "src/cycle.l"), cycleEntrySource())
  writeFileOrPanic(Path.join(root, "src/cycle_kernel.l"), cycleKernelSource())

  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  val rc = Cli.buildProject(
    Path.join(root, "lyric.toml"),
    None,
    Emitter.Jvm,
    noFeatures,
    false,
    false,
    true,
    None,
    noPre,
    noDefines
  )
  assertEqualInt(
    rc,
    0,
    "buildProject: a --manifest --target jvm build of a cyclic-package project succeeds — previously " +
      "error[T0014] unknown qualified type 'Cycle.Request'/'Cycle.Response' (#6024)"
  )
  val jarPath = Path.join(Path.join(root, "bin"), "Cycle.dll")
  assertTrue(File.fileExists(jarPath), "buildProject: the Jvm manifest build produced an output artifact")
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val result = Capture.runCaptureWithDiagnostics("java", args, "")
  assertEqualInt(result.exitCode, 0, "buildProject output: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "handled:/hello",
    "buildProject output: the cyclic-package program runs and round-trips through both packages"
  )
}

// ─── Regression guard: the identical fixture already worked on --target
// dotnet before this fix (the issue's own scope note) — must keep working.
test "buildProject: the same cyclic-package fixture still builds on --target dotnet (regression guard)" {
  val root = freshTempDir("manifest-dotnet")
  defer {
    cleanup(root)
  }
  writeFileOrPanic(
    Path.join(root, "lyric.toml"),
    "[package]\n" + "name = \"Fixture.Cycle\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"Fixture.Cycle\"\n" +
      "output_assembly = \"Cycle.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Cycle\" = \"src/cycle.l\"\n" +
      "\"Cycle.Kernel\" = \"src/cycle_kernel.l\"\n"
  )
  match File.createDir(Path.join(root, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(root, "src/cycle.l"), cycleEntrySource())
  writeFileOrPanic(Path.join(root, "src/cycle_kernel.l"), cycleKernelSource())

  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  val rc = Cli.buildProject(
    Path.join(root, "lyric.toml"),
    None,
    Emitter.Dotnet,
    noFeatures,
    false,
    false,
    true,
    None,
    noPre,
    noDefines
  )
  assertEqualInt(rc, 0, "buildProject: --target dotnet still builds the cyclic-package fixture")
}
