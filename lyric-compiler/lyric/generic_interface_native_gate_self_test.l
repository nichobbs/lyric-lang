//! generic_interface_native_gate_self_test.l - an impl of a generic interface is
//! lowered on `--target dotnet` and `--target jvm` and rejected with T0217 on
//! `--target native` until native lowers it (#7791, D860).  The checker accepts
//! the construct on every target; the gate is per target
//! (`MiddleEndOptions.genericInterfaces`), so a construct no backend lowers is
//! never miscompiled.  Spawns the just-built `./bin/lyric` (the diagnostic is
//! printed by `Lyric.Pipeline`), so CWD is the repo root.
@test_module
package Lyric.GenericInterfaceNativeGateSelfTest

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

func tempDir(label: in String): String {
  val base = Environment.getVarOrDefault(
    "TMPDIR",
    Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp"))
  )
  val root = Path.join(base, "lyric-gi-gate-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func source(): String {
  "package App\n" + "import Std.Core\n" + "interface Holder[T] { func get(self: in Self): T }\n" +
    "record IntBox { v: Int }\n" +
    "impl Holder[Int] for IntBox { func get(self: in IntBox): Int = self.v }\n" +
    "func main(): Int {\n  val h: Holder[Int] = IntBox(v = 1)\n  h.get() - 1\n}\n"
}

func buildFor(target: in String, outName: in String): Capture.CaptureResult {
  val dir = tempDir(target)
  defer {
    match File.deleteDirRecursive(dir) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }
  val srcPath = Path.join(dir, "app.l")
  match File.writeText(srcPath, source()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val args: List[String] = newList()
  args.add("build")
  args.add(srcPath)
  args.add("--target")
  args.add(target)
  args.add("-o")
  args.add(Path.join(dir, outName))
  val result = Capture.runCaptureWithDiagnosticsTimeout(
    Path.join(Environment.currentDirectory(), "bin/lyric"),
    args,
    "",
    300000
  )
  assertTrue(not result.timedOut, "lyric build timed out after 300 s")
  result
}

test "native reports T0217 for an impl of a generic interface" {
  val r = buildFor("native", "app")
  assertTrue(r.exitCode != 0, "the native build fails")
  assertTrue(Str.contains(r.stderr, "error[T0217]"), "T0217 is reported, got:\n" + r.stderr)
}

test "dotnet builds an impl of a generic interface" {
  val r = buildFor("dotnet", "app.dll")
  assertEqualInt(r.exitCode, 0, "the dotnet build succeeds:\n" + r.stderr)
  assertFalse(Str.contains(r.stderr, "T0217"), "no T0217 on dotnet")
}

test "jvm builds an impl of a generic interface" {
  val r = buildFor("jvm", "app.jar")
  assertEqualInt(r.exitCode, 0, "the jvm build succeeds:\n" + r.stderr)
  assertFalse(Str.contains(r.stderr, "T0217"), "no T0217 on the JVM")
}
