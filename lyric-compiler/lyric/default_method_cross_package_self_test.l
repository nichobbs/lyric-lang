//! default_method_cross_package_self_test.l - a default method of an interface declared in another package is
//! called on a concrete implementor (#9428, D861), for a plain interface: on dotnet the dependency
//! is a restored DLL, on the JVM it is compiled with the consumer.  Spawns the just-built
//! `./bin/lyric` (`lyric run --manifest`), so CWD is the repo root.
@test_module
package Lyric.DefaultMethodCrossPackageSelfTest

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
  val root = Path.join(base, "lyric-dm-xpkg-" + label + "-" + uuidToString(newUuid()))
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
  "package HLib\npub interface Named {\n  func label(self: in Self): String\n  func tagged(self: in Self, n: in Int): String = label() + \":\" + toString(n)\n}\n"
}

func appSource(): String {
  "package App\nimport HLib\nimport Std.Core\nrecord L { s: String }\nimpl Named for L { func label(self: in L): String = self.s }\nfunc main(): Int {\n  println(L(s = \"x\").tagged(2))\n  val n: Named = L(s = \"y\")\n  println(n.tagged(3))\n  0\n}\n"
}

func runFor(target: in String, lib: in String, app: in String): Capture.CaptureResult {
  val dir = tempDir(target)
  defer {
    match File.deleteDirRecursive(dir) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }
  write(Path.join(dir, "lib/lyric.toml"), libToml())
  write(Path.join(dir, "lib/src/h.l"), lib)
  write(Path.join(dir, "app/lyric.toml"), appToml())
  write(Path.join(dir, "app/src/main.l"), app)
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

func genericLibSource(): String {
  "package HLib\npub interface Holder[T] {\n  func get(self: in Self): T\n  func twice(self: in Self, x: in T): T = x\n}\n"
}

func genericAppSource(): String {
  "package App\nimport HLib\nimport Std.Core\nrecord IntBox { v: Int }\nimpl Holder[Int] for IntBox { func get(self: in IntBox): Int = self.v }\nfunc main(): Int {\n  println(toString(IntBox(v = 1).twice(9)))\n  val h: Holder[Int] = IntBox(v = 2)\n  println(toString(h.twice(5)))\n  0\n}\n"
}

func expectGenericOutput(target: in String): Unit {
  val r = runFor(target, genericLibSource(), genericAppSource())
  assertEqualInt(r.exitCode, 0, "the generic consumer runs on " + target + ":\n" + r.stderr)
  assertTrue(Str.contains(r.stdout, "9\n5\n"), "the generic consumer's output on " + target + ", got:\n" + r.stdout)
}

func genericImplAppSource(): String {
  "package App\nimport HLib\nimport Std.Core\nrecord Box[T] { v: T }\nimpl[T] Holder[T] for Box[T] { func get(self: in Box[T]): T = self.v }\nfunc main(): Int {\n  val b: Box[Int] = Box(v = 1)\n  println(toString(b.twice(9)))\n  val s: Box[String] = Box(v = \"a\")\n  println(s.twice(\"z\"))\n  0\n}\n"
}

func expectGenericImplOutput(target: in String): Unit {
  val r = runFor(target, genericLibSource(), genericImplAppSource())
  assertEqualInt(r.exitCode, 0, "the generic-implementor consumer runs on " + target + ":\n" + r.stderr)
  assertTrue(
    Str.contains(r.stdout, "9\nz\n"),
    "the generic-implementor consumer's output on " + target + ", got:\n" + r.stdout
  )
}

func expectOutput(target: in String): Unit {
  val r = runFor(target, libSource(), appSource())
  assertEqualInt(r.exitCode, 0, "the consumer runs on " + target + ":\n" + r.stderr)
  assertTrue(Str.contains(r.stdout, "x:2\ny:3\n"), "the consumer's output on " + target + ", got:\n" + r.stdout)
}

test "a default method of another package's interface is called on a concrete implementor on dotnet" {
  expectOutput("dotnet")
}

test "a default method of another package's interface is called on a concrete implementor on the JVM" {
  expectOutput("jvm")
}

test "a default method of another package's generic interface is called on a concrete implementor on dotnet" {
  expectGenericOutput("dotnet")
}

test "a default method of another package's generic interface is called on a concrete implementor on the JVM" {
  expectGenericOutput("jvm")
}

test "a default method of another package's generic interface is called on a generic implementor on dotnet" {
  expectGenericImplOutput("dotnet")
}

test "a default method of another package's generic interface is called on a generic implementor on the JVM" {
  expectGenericImplOutput("jvm")
}
