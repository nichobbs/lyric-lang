//! llvm_project_self_test.l — end-to-end self-test for multi-package native
//! PROJECT builds (#6809): `Lyric.LlvmBridge.compileProjectToNativeWithFlags`
//! compiles several own `NativeSourcePackage` entries plus the bundled
//! stdlib closure into one binary — the same mechanism
//! `Lyric.Emitter.emitNativeProject` / `Lyric.Cli.buildProjectFromManifest`
//! use for `lyric build --manifest ... --target native`'s own
//! `[project.packages]` resolution — and runs the produced binary,
//! asserting its exit code / stdout.
//!
//! Covers: a two-package program where the entry imports a sibling
//! function; the SAME shape with the entry package declared SECOND in the
//! list (the manifest-declaration-order bug this feature's first real build
//! attempt hit — native codegen only scanned `units[0]` for `main`, so a
//! `[project.packages]` table listing the entry package after a sibling
//! silently produced a `main`-less binary; `compileProjectToNativeWithFlags`
//! now reorders so the `func main`-declaring package is always unit 0);
//! cross-package record-type references (`Proj3.Geo` importing a record
//! `Proj3.Model` declares); `[features]`/`@cfg(feature = ...)` gating on a
//! sibling package's item (#6818 — `compileProjectToNativeWithFlags` used
//! to erase every `@cfg(feature = ...)`-gated item unconditionally,
//! ignoring the caller's real `activeFeatures`); a genuinely multi-file
//! `[project.packages]` entry through `Emitter.emitNativeProject`'s own
//! `mergePackageSources` call (every other case here calls
//! `compileProjectToNativeWithFlags` directly with one file per package,
//! bypassing the merge step); and the empty-package-list failure path.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_project_self_test.l
@test_module
package Lyric.LlvmProjectSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.String as Str
import Std.Uuid as Uuid
import Lyric.Emitter
import Lyric.LlvmBridge

// ─────────────────────────────────────────────────────────────────────────────
// Harness.
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

record RunOutcome {
  exitCode: Int
  stdout: String
}

func compileAndRunProject(packages: in List[NativeSourcePackage]): RunOutcome {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-project-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val flags: List[String] = newList()
  flags.add("-fsanitize=address")
  val noFeatures: List[String] = newList()
  if not compileProjectToNativeWithFlags(packages, stem, stdlib, "", "0", flags, newList(), noFeatures, noFeatures) {
    panic("native project compilation failed")
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

// Like `compileAndRunProject` but threads a real `activeFeatures` set
// through to `compileProjectToNativeWithFlags` (#6818) instead of always
// compiling with none active — returns `None` on a compile failure (the
// caller decides whether that's expected) rather than panicking, since the
// #6818 regression test below needs to assert BOTH outcomes.
func compileAndRunProjectWithFeatures(
  packages: in List[NativeSourcePackage], activeFeatures: in List[String]
): Option[RunOutcome] {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-project-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val flags: List[String] = newList()
  flags.add("-fsanitize=address")
  val noDeclared: List[String] = newList()
  if not compileProjectToNativeWithFlags(packages, stem, stdlib, "", "0", flags, newList(), activeFeatures, noDeclared) {
    return None
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> Some(value = RunOutcome(exitCode = res.exitCode, stdout = res.stdout))
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "two-package project: entry package first, imports a sibling function (ASan)" {
  val pkgs: List[NativeSourcePackage] = newList()
  pkgs.add(
    NativeSourcePackage(
      name = "Proj.App",
      source = "package Proj.App\n" + "import Proj.Greeter\n" + "import Std.Console as Console\n" +
        "func main(): Int {\n" +
        "  Console.println(greet(\"native\"))\n" +
        "  0\n" +
        "}\n"
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj.Greeter",
      source = "package Proj.Greeter\n" + "pub func greet(name: in String): String {\n" + "  \"hi \" + name\n" + "}\n"
    )
  )
  val outcome = compileAndRunProject(pkgs)
  assertEqualInt(outcome.exitCode, 0, "two-package project exit code")
  assertTrue(Str.contains(outcome.stdout, "hi native"), "sibling package function output made it to stdout")
}

test "two-package project: entry package declared SECOND still becomes the binary's main (ASan, #6809)" {
  val pkgs: List[NativeSourcePackage] = newList()
  pkgs.add(
    NativeSourcePackage(
      name = "Proj2.Helper",
      source = "package Proj2.Helper\n" + "pub func doubled(n: in Int): Int {\n" + "  n * 2\n" + "}\n"
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj2.App",
      source = "package Proj2.App\n" + "import Proj2.Helper\n" + "func main(): Int {\n" + "  doubled(21)\n" + "}\n"
    )
  )
  val outcome = compileAndRunProject(pkgs)
  assertEqualInt(outcome.exitCode, 42, "entry package declared second still supplies main (doubled(21) == 42)")
}

test "three-package project: a sibling package references another sibling's record type across the bundle (ASan)" {
  val pkgs: List[NativeSourcePackage] = newList()
  pkgs.add(
    NativeSourcePackage(
      name = "Proj3.Model",
      source = "package Proj3.Model\n" + "pub record Point {\n" + "  x: Int\n" + "  y: Int\n" + "}\n"
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj3.Geo",
      source = "package Proj3.Geo\n" + "import Proj3.Model\n" + "pub func sumCoords(p: in Point): Int {\n" +
        "  p.x + p.y\n" +
        "}\n"
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj3.App",
      source = "package Proj3.App\n" + "import Proj3.Model\n" + "import Proj3.Geo\n" + "func main(): Int {\n" +
        "  val p = Point(x = 10, y = 32)\n" +
        "  sumCoords(p)\n" +
        "}\n"
    )
  )
  val outcome = compileAndRunProject(pkgs)
  assertEqualInt(outcome.exitCode, 42, "cross-package record type reference (Point.x + Point.y == 42)")
}

test "project build honors [features]/@cfg(feature = ...) gating on a sibling package's item (#6818)" {
  val pkgs: List[NativeSourcePackage] = newList()
  pkgs.add(
    NativeSourcePackage(
      name = "Proj4.Extra",
      source = "package Proj4.Extra\n" + "\n" + "@cfg(feature = \"extra\")\n" + "pub func value(): Int {\n" + "  42\n" +
        "}\n"
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj4.App",
      source = "package Proj4.App\n" + "import Proj4.Extra\n" + "func main(): Int {\n" + "  value()\n" + "}\n"
    )
  )
  // Native codegen's own resolution failures (as opposed to the explicit,
  // cleanly-`false`-returning validation checks like "no packages")
  // surface as a hard `panic`, not a graceful `Bool` result — matching the
  // single-source native path's identical pre-existing behavior. Assert
  // the panic directly rather than expecting a clean `None`.
  val noFeatures: List[String] = newList()
  assertPanicsWith(
    "@cfg(feature = \"extra\")-gated call must fail to compile when \"extra\" is inactive",
    "cannot resolve call target",
    { -> val _ = compileAndRunProjectWithFeatures(pkgs, noFeatures) }
  )
  val extraOnly: List[String] = newList()
  extraOnly.add("extra")
  val withFeature = compileAndRunProjectWithFeatures(pkgs, extraOnly)
  match withFeature {
    case Some(res) -> assertEqualInt(res.exitCode, 42, "activating \"extra\" includes the gated function (== 42)")
    case None -> panic("compilation must succeed once \"extra\" is active")
  }
}

test "a genuinely multi-file [project.packages] entry merges through Emitter.emitNativeProject" {
  // Exercises the `Emitter.emitNativeProject` -> `mergePackageSources` path
  // directly (every other case in this file calls
  // `LlvmBridge.compileProjectToNativeWithFlags` with one file per
  // `NativeSourcePackage`, bypassing the merge step entirely) — the same
  // multi-file-package shape `lyric-web/lyric.toml`'s `Web.Kernel.Runtime`
  // entry uses (`["src/_kernel/net/web_kernel.l", "src/_kernel/jvm/web_kernel.l"]`).
  // Not ASan-compiled: `emitNativeProject`'s `extraLibs` maps to `-l<name>`
  // link flags only (matching the CLI's own real usage), with no raw-flag
  // hook for `-fsanitize=address` — unlike `compileProjectToNativeWithFlags`'s
  // `extraClangFlags`, which every other case in this file uses directly.
  val helperPkg: List[String] = newList()
  helperPkg.add("package Proj5.Helper\n" + "pub func partOne(): Int {\n" + "  10\n" + "}\n")
  helperPkg.add("package Proj5.Helper\n" + "pub func partTwo(): Int {\n" + "  32\n" + "}\n")
  val pkgs: List[ProjectPackage] = newList()
  pkgs.add(ProjectPackage(name = "Proj5.Helper", sources = helperPkg))
  val appSrc: List[String] = newList()
  appSrc.add(
    "package Proj5.App\n" + "import Proj5.Helper\n" + "func main(): Int {\n" + "  partOne() + partTwo()\n" + "}\n"
  )
  pkgs.add(ProjectPackage(name = "Proj5.App", sources = appSrc))
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-project-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val noLibs: List[String] = newList()
  val noDefines: List[String] = newList()
  val noFeatures: List[String] = newList()
  val result = Emitter.emitNativeProject(pkgs, stem, "", "0", noLibs, noDefines, noFeatures, noFeatures)
  match result.outputPath {
    case None -> panic("multi-file package project compilation failed")
    case Some(_) -> ()
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> assertEqualInt(res.exitCode, 42, "merged two-file package's two functions summed (10 + 32 == 42)")
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

test "project build with no packages fails loudly rather than compiling an empty binary" {
  val pkgs: List[NativeSourcePackage] = newList()
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(tempBase(), "lyric-llvm-project-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val noFlags: List[String] = newList()
  val noFeatures: List[String] = newList()
  val ok = compileProjectToNativeWithFlags(pkgs, stem, stdlib, "", "0", noFlags, newList(), noFeatures, noFeatures)
  assertFalse(ok, "an empty package list must fail rather than silently produce an empty binary")
}
