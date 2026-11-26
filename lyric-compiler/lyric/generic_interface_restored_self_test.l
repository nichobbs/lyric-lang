//! generic_interface_restored_self_test.l - a generic interface declared in one package is implemented and
//! called from another (#7791, D860): on dotnet the dependency is a restored DLL whose interface the consumer
//! reads back from its contract metadata, on the JVM it is compiled with the consumer.  Spawns the just-built
//! `./bin/lyric` (`lyric run --manifest`), so CWD is the repo root.
@test_module
package Lyric.GenericInterfaceRestoredSelfTest

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
  val root = Path.join(base, "lyric-gi-restored-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func write(path: in String, text: in String): Unit {
  match File.createDir(Path.dirname(path)) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  match File.writeText(path, text) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write " + path + ": " + IOError.message(e))
  }
}

func libToml(): String {
  "[package]\nname = \"hlib\"\nversion = \"0.1.0\"\n[project]\nname = \"HLib\"\n[project.packages]\n\"HLib\" = \"src\"\n"
}

func appToml(): String {
  "[package]\nname = \"happ\"\nversion = \"0.1.0\"\n[project]\nname = \"HApp\"\n[project.packages]\n\"App\" = \"src\"\n[dependencies]\nhlib = { path = \"../lib\" }\n"
}

func libSource(): String {
  "package HLib\npub interface Holder[T] {\n  func get(self: in Self): T\n  func put(self: in Self, x: in T): Unit\n}\npub func readIt(h: in Holder[Int]): Int = h.get()\n"
}

func appSource(): String {
  "package App\nimport HLib\nimport Std.Core\nref record IntBox { var v: Int }\nimpl Holder[Int] for IntBox {\n  func get(self: in IntBox): Int = self.v\n  func put(self: in IntBox, x: in Int): Unit { self.v = x }\n}\nref record Box[T] { var v: T }\nimpl[T] Holder[T] for Box[T] {\n  func get(self: in Box[T]): T = self.v\n  func put(self: in Box[T], x: in T): Unit { self.v = x }\n}\nfunc bump(h: in Holder[Int]): Int {\n  h.put(h.get() + 1)\n  h.get()\n}\nfunc main(): Int {\n  val b = IntBox(v = 3)\n  println(toString(readIt(b)))\n  println(toString(bump(b)))\n  val g = Box(v = 10)\n  println(toString(bump(g)))\n  0\n}\n"
}

func runFor(target: in String): Capture.CaptureResult {
  val dir = tempDir(target)
  defer {
    match File.deleteDirRecursive(dir) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }
  write(Path.join(dir, "lib/lyric.toml"), libToml())
  write(Path.join(dir, "lib/src/h.l"), libSource())
  write(Path.join(dir, "app/lyric.toml"), appToml())
  write(Path.join(dir, "app/src/main.l"), appSource())
  val build: List[String] = newList()
  build.add("build")
  build.add("--target")
  build.add(target)
  build.add("--manifest")
  build.add(Path.join(dir, "lib/lyric.toml"))
  val lyric = Path.join(Environment.currentDirectory(), "bin/lyric")
  val built = Capture.runCaptureWithDiagnosticsTimeout(lyric, build, "", 300000)
  assertEqualInt(built.exitCode, 0, "the library builds:\n" + built.stderr)
  val args: List[String] = newList()
  args.add("run")
  args.add("--target")
  args.add(target)
  args.add("--manifest")
  args.add(Path.join(dir, "app/lyric.toml"))
  val r = Capture.runCaptureWithDiagnosticsTimeout(lyric, args, "", 300000)
  assertFalse(r.timedOut, "lyric run timed out")
  r
}

func expectOutput(target: in String): Unit {
  val r = runFor(target)
  assertEqualInt(r.exitCode, 0, "the consumer runs on " + target + ":\n" + r.stderr)
  assertTrue(Str.contains(r.stdout, "3\n4\n11\n"), "the consumer's output on " + target + ", got:\n" + r.stdout)
}

test "a generic interface of another package is implemented and called on dotnet" {
  expectOutput("dotnet")
}

test "a generic interface of another package is implemented and called on the JVM" {
  expectOutput("jvm")
}
