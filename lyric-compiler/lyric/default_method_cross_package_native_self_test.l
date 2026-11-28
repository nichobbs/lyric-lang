//! default_method_cross_package_native_self_test.l - an interface declared in another package, on `--target native`
//! (#7791, D863, #9451).  An impl of a generic interface that defines every method runs, and an impl that omits a
//! default method of another package's interface runs (#9451, D867): the declaring package holds the default's body in
//! a function of its own and the impl calls it.  A default native cannot express that way (a `Self` in a parameter)
//! is still `N0106`.  The dotnet and JVM cases are in `default_method_cross_package_self_test.l`; these two build a native executable, so they run in the
//! native lane (`scripts/ci/native-backend-self-tests.sh`), which has the runtime library.  Spawns the just-built
//! `./bin/lyric`, so CWD is the repo root.
@test_module
package Lyric.DefaultMethodCrossPackageNativeSelfTest

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
  val root = Path.join(base, "lyric-dm-xpkg-native-" + label + "-" + uuidToString(newUuid()))
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

func genericLibSource(): String {
  "package HLib\npub interface Holder[T] {\n  func get(self: in Self): T\n  func twice(self: in Self, x: in T): T = x\n}\n"
}

func genericOverrideAppSource(): String {
  "package App\nimport HLib\nimport Std.Core\nrecord IntBox { v: Int }\nimpl Holder[Int] for IntBox {\n  func get(self: in IntBox): Int = self.v\n  func twice(self: in IntBox, x: in Int): Int = x + x\n}\nfunc main(): Int {\n  println(toString(IntBox(v = 1).twice(9)))\n  val h: Holder[Int] = IntBox(v = 2)\n  println(toString(h.twice(5)))\n  println(toString(h.get()))\n  0\n}\n"
}

func richLibSource(): String {
  "package HLib\npub interface Named {\n  func label(self: in Self): String\n  func tagged(self: in Self, n: in Int): String = decorate(label()) + \":\" + toString(n)\n  func twiceTagged(self: in Self, n: in Int): String = tagged(n) + tagged(n + 1)\n}\nfunc decorate(s: in String): String = \"<\" + s + \">\"\n"
}

func richAppSource(): String {
  "package App\nimport HLib\nimport Std.Core\nrecord L { s: String }\nimpl Named for L { func label(self: in L): String = self.s }\nfunc show(n: in Named): String = n.twiceTagged(7)\nfunc main(): Int {\n  println(L(s = \"x\").tagged(2))\n  println(show(L(s = \"y\")))\n  0\n}\n"
}

func genericDefaultAppSource(): String {
  "package App\nimport HLib\nimport Std.Core\nrecord IntBox { v: Int }\nimpl Holder[Int] for IntBox { func get(self: in IntBox): Int = self.v }\nfunc main(): Int {\n  println(toString(IntBox(v = 1).twice(9)))\n  val h: Holder[Int] = IntBox(v = 2)\n  println(toString(h.twice(5)))\n  0\n}\n"
}

func selfParamLibSource(): String {
  "package HLib\npub interface Named {\n  func label(self: in Self): String\n  func same(self: in Self, other: in Self): Bool = true\n}\n"
}

func selfParamAppSource(): String {
  "package App\nimport HLib\nimport Std.Core\nrecord L { s: String }\nimpl Named for L { func label(self: in L): String = self.s }\nfunc main(): Int {\n  println(L(s = \"x\").label())\n  0\n}\n"
}

// The `lyric` this test spawns: the repo's `bin/lyric` where `make lyric` made it, else the AOT binary the CI lane builds
// (`bootstrap/src/Lyric.Cli.Aot/bin/<config>/lyric`).
func lyricBinary(): String {
  val root = Environment.currentDirectory()
  val candidates: List[String] = newList()
  candidates.add("bin/lyric")
  candidates.add("bootstrap/src/Lyric.Cli.Aot/bin/Debug/lyric")
  candidates.add("bootstrap/src/Lyric.Cli.Aot/bin/Release/lyric")
  for rel in candidates {
    val p = Path.join(root, rel)
    if File.fileExists(p) {
      return p
    }
  }
  Path.join(root, "bin/lyric")
}

func runFor(lib: in String, app: in String): Capture.CaptureResult {
  val dir = tempDir("native")
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
  val lyric = lyricBinary()
  val args: List[String] = newList()
  args.add("run")
  args.add("--target")
  args.add("native")
  args.add("--manifest")
  args.add(Path.join(dir, "app/lyric.toml"))
  // A native build compiles a path dependency from source, so the library is not built first.
  val r = Capture.runCaptureWithDiagnosticsTimeout(lyric, args, "", 300000)
  assertFalse(r.timedOut, "lyric run timed out")
  r
}

test "an impl of another package's generic interface that defines every method runs on native" {
  val r = runFor(genericLibSource(), genericOverrideAppSource())
  assertEqualInt(r.exitCode, 0, "the overriding consumer runs on native:\n" + r.stderr)
  assertTrue(Str.contains(r.stdout, "18\n10\n2\n"), "the overriding consumer's output on native, got:\n" + r.stdout)
}

test "an impl inherits a default method of another package's interface on native" {
  val r = runFor(libSource(), appSource())
  assertEqualInt(r.exitCode, 0, "the consumer runs on native:\n" + r.stderr)
  assertTrue(
    Str.contains(r.stdout, "x:2\ny:3\n"),
    "the default runs on the concrete type and through the interface, got:\n" + r.stdout
  )
}

test "an inherited default resolves its own names in the declaring package and may call another default" {
  val r = runFor(richLibSource(), richAppSource())
  assertEqualInt(r.exitCode, 0, "the consumer runs on native:\n" + r.stderr)
  assertTrue(
    Str.contains(r.stdout, "<x>:2\n<y>:7<y>:8\n"),
    "the helper of the declaring package and the nested default run, got:\n" + r.stdout
  )
}

test "an impl inherits a default method of another package's generic interface on native" {
  val r = runFor(genericLibSource(), genericDefaultAppSource())
  assertEqualInt(r.exitCode, 0, "the consumer runs on native:\n" + r.stderr)
  assertTrue(
    Str.contains(r.stdout, "9\n5\n"),
    "the inherited generic default runs on the concrete type and through the interface, got:\n" + r.stdout
  )
}

test "native names a default method it cannot inherit" {
  val r = runFor(selfParamLibSource(), selfParamAppSource())
  assertTrue(r.exitCode != 0, "the build stops")
  assertTrue(Str.contains(r.stderr, "N0106"), "the diagnostic is N0106, got:\n" + r.stderr)
  assertTrue(Str.contains(r.stderr, "same"), "it names the method, got:\n" + r.stderr)
}
