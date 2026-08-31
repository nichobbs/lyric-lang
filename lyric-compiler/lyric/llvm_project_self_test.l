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
//! `Proj3.Model` declares); and the empty-package-list failure path.
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
  if not compileProjectToNativeWithFlags(packages, stem, stdlib, "", "0", flags, newList()) {
    panic("native project compilation failed")
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
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

test "project build with no packages fails loudly rather than compiling an empty binary" {
  val pkgs: List[NativeSourcePackage] = newList()
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(tempBase(), "lyric-llvm-project-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val noFlags: List[String] = newList()
  val ok = compileProjectToNativeWithFlags(pkgs, stem, stdlib, "", "0", noFlags, newList())
  assertFalse(ok, "an empty package list must fail rather than silently produce an empty binary")
}
