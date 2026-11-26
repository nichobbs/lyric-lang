//! generic_interface_native_gate_self_test.l - an impl of a generic interface is
//! lowered on `--target dotnet`, `--target jvm` and `--target native` (#7791, D860,
//! D863).  The checker accepts the construct on every target and no target reports
//! T0217 any more (the gate is per target, `MiddleEndOptions.genericInterfaces`);
//! what native cannot lay out is `N0105`, so a construct is lowered or rejected,
//! never miscompiled.  Spawns the just-built `./bin/lyric`, so CWD is the repo root.
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

test "native builds an impl of a generic interface" {
  val r = buildFor("native", "app")
  assertEqualInt(r.exitCode, 0, "the native build succeeds:\n" + r.stderr)
  assertFalse(Str.contains(r.stderr, "T0217"), "no T0217 on native")
}

func unionTargetSource(): String {
  "package App\n" + "import Std.Core\n" + "interface Holder[T] { func get(self: in Self): T }\n" +
    "union Wrap[T] {\n  case Full(v: T)\n  case Empty\n}\n" +
    "impl[T] Holder[T] for Wrap[T] {\n  func get(self: in Wrap[T]): T = match self {\n    case Full(v) -> v\n    case Empty -> panic(\"empty\")\n  }\n}\n" +
    "func main(): Int {\n  val w: Wrap[Int] = Full(v = 1)\n  w.get() - 1\n}\n"
}

test "native reports N0105 for an impl of a generic interface for a generic union" {
  val dir = tempDir("union")
  defer {
    match File.deleteDirRecursive(dir) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }
  val srcPath = Path.join(dir, "app.l")
  match File.writeText(srcPath, unionTargetSource()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val args: List[String] = newList()
  args.add("build")
  args.add(srcPath)
  args.add("--target")
  args.add("native")
  args.add("-o")
  args.add(Path.join(dir, "app"))
  val r = Capture.runCaptureWithDiagnosticsTimeout(
    Path.join(Environment.currentDirectory(), "bin/lyric"),
    args,
    "",
    300000
  )
  assertTrue(r.exitCode != 0, "the native build fails")
  assertTrue(Str.contains(r.stderr, "N0105"), "N0105 is reported, got:\n" + r.stderr)
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
