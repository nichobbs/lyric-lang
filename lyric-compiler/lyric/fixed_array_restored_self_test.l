//! `array[N, T]` in the public surface of a dependency (#8042): a function
//! that takes and returns arrays, a record with an array field the consumer
//! leaves out (zero filled where it is built), and a generic record whose
//! element type a bracket literal binds.  On dotnet the dependency is built
//! to its own DLL first and the consumer reads it back through its
//! `Lyric.Contract` metadata (a restored package), where an array is a
//! `List`; on the JVM a path dependency is compiled into the consumer's
//! bundle.  `lyric run --manifest` runs the consumer and its exit code
//! carries the answer.
//!
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/fixed_array_restored_self_test.l
@test_module
package Lyric.FixedArrayRestoredSelfTest

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
  val root = Path.join(tempBase(), "lyric-fixedarray-restored-" + label + "-" + uuidToString(newUuid()))
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

func mkDirOrPanic(path: in String): Unit {
  match File.createDir(path) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + path + ": " + IOError.message(e))
  }
}

func depSource(): String {
  "package Arr.Dep\n\n" + "pub record Grid {\n  var cells: array[3, Int]\n  var n: Int\n}\n\n" +
    "pub record Pair[T] {\n  var items: array[2, T]\n}\n\n" +
    "pub func total(a: in array[3, Int]): Int {\n  var t = 0\n  for x in a {\n    t = t + x\n  }\n  t\n}\n\n" +
    "pub func counting(): array[3, Int] {\n  [1, 2, 3]\n}\n\n" +
    "pub func gridTotal(g: in Grid): Int {\n  total(g.cells) + g.n\n}\n"
}

// 6 (an array returned by the dependency) + 10 (an array passed to it) +
// 9 (a Grid whose cells are zero filled here, then written) + 11 (a Pair[Int]
// a bracket literal binds) = 36.
func appSource(): String {
  "package Arr.Consumer\n\n" + "import Arr.Dep\n\n" + "func main(): Int {\n" + "  val c = counting()\n" +
    "  val a: array[3, Int] = [2, 3, 5]\n" +
    "  val g = Grid(n = 2)\n" +
    "  g.cells[1] = 7\n" +
    "  val p: Pair[Int] = Pair(items = [4, 7])\n" +
    "  total(c) + total(a) + gridTotal(g) + p.items[0] + p.items[1]\n" +
    "}\n"
}

func project(name: in String, pkg: in String, deps: in String): String {
  "[package]\nname = \"" + name + "\"\nversion = \"0.1.0\"\n\n[project]\nname = \"" + name + "\"\noutput_assembly = \"" +
    name +
    ".dll\"\n\n[project.packages]\n\"" +
    pkg +
    "\" = \"src/main.l\"\n" +
    deps
}

// Writes the dependency and the consumer under `root`; the consumer's
// manifest path.
func writeProjects(root: in String): String {
  val depDir = Path.join(root, "Dep")
  mkDirOrPanic(depDir)
  mkDirOrPanic(Path.join(depDir, "src"))
  writeFileOrPanic(Path.join(depDir, "lyric.toml"), project("Arr.Dep", "Arr.Dep", ""))
  writeFileOrPanic(Path.join(depDir, "src/main.l"), depSource())
  val appDir = Path.join(root, "App")
  mkDirOrPanic(appDir)
  mkDirOrPanic(Path.join(appDir, "src"))
  writeFileOrPanic(
    Path.join(appDir, "lyric.toml"),
    project("Arr.Consumer", "Arr.Consumer", "\n[dependencies]\n\"Arr.Dep\" = { path = \"../Dep\" }\n")
  )
  writeFileOrPanic(Path.join(appDir, "src/main.l"), appSource())
  Path.join(appDir, "lyric.toml")
}

func buildDep(root: in String, target: in Emitter.CompileTarget): Int {
  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  Cli.buildProject(
    Path.join(Path.join(root, "Dep"), "lyric.toml"),
    None,
    target,
    noFeatures,
    false,
    false,
    true,
    None,
    noPre,
    noDefines
  )
}

test "a restored dotnet dependency's arrays cross into the consumer" {
  val root = freshTempDir("dotnet")
  defer {
    cleanup(root)
  }
  val appManifest = writeProjects(root)
  assertEqualInt(buildDep(root, Emitter.Dotnet), 0, "the dependency builds to its DLL")
  val noArgs: List[String] = newList()
  assertEqualInt(Cli.runProjectOnce(appManifest, noArgs, Emitter.Dotnet), 36, "the exit code")
}

test "a JVM path dependency's arrays cross into the consumer" {
  val root = freshTempDir("jvm")
  defer {
    cleanup(root)
  }
  val appManifest = writeProjects(root)
  val noArgs: List[String] = newList()
  assertEqualInt(Cli.runProjectOnce(appManifest, noArgs, Emitter.Jvm), 36, "the exit code")
}
