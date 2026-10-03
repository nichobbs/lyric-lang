//! `array[N, T]` across the packages of one project (D167), on every target:
//! a record with an array field, a function that takes, mutates and returns
//! arrays, a length named by a constant, and `==` on a record holding an
//! array, all crossing a package boundary.  `lyric run --manifest` builds the
//! two packages and the program's exit code carries the answer.
//!
//! Requires `clang` and a built runtime for the native run (`make -C lyric-rt`):
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/fixed_array_project_self_test.l
@test_module
package Lyric.FixedArrayProjectSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.Path as Path
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Lyric.Cli as Cli
import Lyric.Emitter as Emitter

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-fixedarray-proj-" + label + "-" + uuidToString(newUuid()))
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

func mathSource(): String {
  "package Arr.Math\n\n" + "pub val SIZE: Int = 3\n\n" + "pub record Mat {\n  cells: array[4, Float]\n}\n\n" +
    "pub record Reading {\n  var values: array[SIZE, Float]\n}\n\n" +
    "pub record Acc {\n  var hits: array[3, Int]\n  var n: Int\n}\n\n" +
    "pub func identity(): Mat {\n  Mat(cells = [1.0, 0.0, 0.0, 1.0])\n}\n\n" +
    "pub func trace(m: in Mat): Float {\n  m.cells[0] + m.cells[3]\n}\n\n" +
    "pub func total(a: in array[3, Int]): Int {\n  var t = 0\n  for x in a {\n    t = t + x\n  }\n  t\n}\n\n" +
    "pub func fill(a: inout array[3, Int], v: in Int) {\n  a[0] = v\n  a[1] = v\n  a[2] = v\n}\n\n" +
    "pub func zeros(): array[3, Int] {\n  var z: array[3, Int]\n  z\n}\n\n" +
    "pub func makeAcc(): Acc {\n  Acc(hits = [0, 0, 0], n = 0)\n}\n\n" +
    "pub func sumReading(r: in Reading): Float {\n  var t: Float = 0.0\n  for x in r.values {\n    t = t + x\n  }\n  t\n}\n"
}

// A package that never spells an array type and gets one only through
// `zeros()`: its copy of a `var` array is still lowered and built (#8073).
func useSource(): String {
  "package Arr.Use\n\n" + "import Arr.Math\n\n" + "pub func copyCount(): Int {\n" + "  var w = zeros()\n" +
    "  w[0] = 1\n" +
    "  val w2 = w\n" +
    "  w[0] = 5\n" +
    "  w2[0]\n" +
    "}\n"
}

func appSource(): String {
  "package Arr.App\n\n" + "import Arr.Math\n" + "import Arr.Use\n\n" + "func main(): Int {\n" + "  val m = identity()\n" +
    "  var h: array[3, Int] = [1, 2, 3]\n" +
    "  fill(h, 4)\n" +
    "  val z = zeros()\n" +
    "  val acc = makeAcc()\n" +
    "  acc.hits[1] = 6\n" +
    "  val r = Reading(values = [1.0, 2.0, 3.0])\n" +
    "  val mm = Mat(cells = [2.0, 0.0, 0.0, 3.0])\n" +
    "  var same = 0\n" +
    "  if mm == m {\n    same = 100\n  }\n" +
    "  total(h) + total(z) + acc.hits[1] + sumReading(r).toInt() + same + trace(mm).toInt() + copyCount()\n" +
    "}\n"
}

func writeProject(root: in String): String {
  writeFileOrPanic(
    Path.join(root, "lyric.toml"),
    "[package]\nname = \"Arr.App\"\nversion = \"0.1.0\"\n\n[project]\nname = \"Arr.App\"\noutput = \"single\"\noutput_assembly = \"ArrApp.dll\"\n\n[project.packages]\n\"Arr.Math\" = \"src/math.l\"\n\"Arr.Use\" = \"src/use.l\"\n\"Arr.App\" = \"src/main.l\"\n"
  )
  match File.createDir(Path.join(root, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  writeFileOrPanic(Path.join(root, "src/math.l"), mathSource())
  writeFileOrPanic(Path.join(root, "src/use.l"), useSource())
  writeFileOrPanic(Path.join(root, "src/main.l"), appSource())
  Path.join(root, "lyric.toml")
}

func runOn(target: in Emitter.CompileTarget, label: in String): Int {
  val root = freshTempDir(label)
  defer {
    cleanup(root)
  }
  val mfPath = writeProject(root)
  val noArgs: List[String] = newList()
  Cli.runProjectOnce(mfPath, noArgs, target)
}

// 12 (total of the filled array) + 0 (zeros) + 6 (an element written through a
// field) + 6 (a Reading sized by a constant) + 0 (the matrices differ) + 5 +
// 1 (a copy made in a package that never spells an array type).
test "a two-package project with arrays runs on dotnet" {
  assertEqualInt(runOn(Emitter.Dotnet, "dotnet"), 30, "the exit code")
}

test "a two-package project with arrays runs on the JVM" {
  assertEqualInt(runOn(Emitter.Jvm, "jvm"), 30, "the exit code")
}

test "a two-package project with arrays runs on native" {
  assertEqualInt(runOn(Emitter.Native, "native"), 30, "the exit code")
}
