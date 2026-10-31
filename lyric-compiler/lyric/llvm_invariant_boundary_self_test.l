//! llvm_invariant_boundary_self_test.l - runs the public-boundary and `inout`
//! record invariant re-checks (#7222, D284) on `--target native` (#8656).
//!
//! `examples/invariant-boundary` is the dotnet/JVM fixture; `lyric test
//! --manifest` is not available on native for multi-package suites (#6815
//! item 3b), so this builds the fixture's two packages plus a small entry
//! package as a native project and runs the binary once per case. A native
//! panic ends the process, so each case is its own run and asserts a non-zero
//! exit with the `InvariantViolated` message on stderr.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_invariant_boundary_self_test.l
@test_module
package Lyric.LlvmInvariantBoundarySelfTest

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

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func fixtureSource(file: in String): String {
  val path = Path.join("examples/invariant-boundary/src", file)
  match File.readText(path) {
    case Ok(text) -> text
    case Err(_) -> panic("cannot read " + path + " (run from the repository root)")
  }
}

func entrySource(): String {
  "package Inv.App\n" + "import Std.Core\n" + "import Std.Console as Console\n" +
    "import Std.Environment as Environment\n" +
    "import Inv.Types\n" +
    "import Inv.Api\n" +
    "func pick(): String {\n" +
    "  val a = Environment.args()\n" +
    "  if a.length == 0 {\n    return \"\"\n  }\n" +
    "  a[a.length - 1]\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val which = pick()\n" +
    "  if which == \"valid\" {\n" +
    "    var d = newCounter(3)\n" +
    "    Console.println(\"read=\" + readCount(d).toString() + \" untouched=\" + untouched(d).toString())\n" +
    "  }\n" +
    "  if which == \"in\" {\n" +
    "    val b = newCounter(1)\n    b.count = -1\n" +
    "    Console.println(\"unreachable \" + readCount(b).toString())\n" +
    "  }\n" +
    "  if which == \"result\" {\n" +
    "    Console.println(\"unreachable \" + readCount(makeBroken()).toString())\n" +
    "  }\n" +
    "  if which == \"inout\" {\n" +
    "    var d = newCounter(1)\n    breakInPlace(d)\n" +
    "    Console.println(\"unreachable \" + d.count.toString())\n" +
    "  }\n" +
    "  if which == \"local-inout\" {\n" +
    "    var d = newCounter(1)\n    breakLocal(d)\n" +
    "    Console.println(\"unreachable \" + d.count.toString())\n" +
    "  }\n" +
    "  0\n" +
    "}\n"
}

func buildFixture(): String {
  val pkgs: List[NativeSourcePackage] = newList()
  pkgs.add(NativeSourcePackage(name = "Inv.App", sources = [entrySource()]))
  pkgs.add(NativeSourcePackage(name = "Inv.Types", sources = [fixtureSource("types.l")]))
  pkgs.add(NativeSourcePackage(name = "Inv.Api", sources = [fixtureSource("api.l")]))
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-invariant-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + Uuid.uuidToString(Uuid.newUuid()))
  val flags: List[String] = newList()
  flags.add("-fsanitize=address")
  val noFeatures: List[String] = newList()
  if not compileProjectToNativeWithFlags(pkgs, stem, stdlib, "", "0", flags, newList(), noFeatures, noFeatures, "", true) {
    panic("native project compilation failed")
  }
  stem
}

record Ran {
  exitCode: Int
  stdout: String
  stderr: String
}

func runCase(exe: in String, which: in String): Ran {
  val args: List[String] = newList()
  args.add(which)
  match Process.runCapture(exe, args, 60000) {
    case Ok(res) -> Ran(exitCode = nativeExitStatus(res.exitCode), stdout = res.stdout, stderr = res.stderr)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

test "native: the invariant boundary checks hold on every boundary (ASan, #8656)" {
  val exe = buildFixture()

  val ok = runCase(exe, "valid")
  assertEqualInt(ok.exitCode, 0, "a valid value crosses every boundary")
  assertTrue(Str.contains(ok.stdout, "read=3 untouched=3"), "valid run output")

  val inArg = runCase(exe, "in")
  assertTrue(inArg.exitCode != 0, "a broken `in` argument panics before the body")
  assertTrue(Str.contains(inArg.stderr, "InvariantViolated: Inv.Types.Counter"), "in argument message: " + inArg.stderr)
  assertFalse(Str.contains(inArg.stdout, "unreachable"), "the body of readCount did not run")

  val result = runCase(exe, "result")
  assertTrue(result.exitCode != 0, "a broken result panics")
  assertTrue(Str.contains(result.stderr, "InvariantViolated: Inv.Types.Counter"), "result message: " + result.stderr)

  val inoutRun = runCase(exe, "inout")
  assertTrue(inoutRun.exitCode != 0, "an inout parameter written to a broken value panics on exit")
  assertTrue(
    Str.contains(inoutRun.stderr, "InvariantViolated: Inv.Types.Counter invariant count >= 0"),
    "inout message: " + inoutRun.stderr
  )

  val local = runCase(exe, "local-inout")
  assertTrue(local.exitCode != 0, "the declaring package's own inout parameter is re-checked on exit")
  assertTrue(
    Str.contains(local.stderr, "InvariantViolated: Inv.Types.Counter invariant count >= 0"),
    "local inout message: " + local.stderr
  )
}
