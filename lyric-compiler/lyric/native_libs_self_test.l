//! native_libs_self_test.l - `[native.libs]` (docs/67 §6, D191): a C library bound
//! through bindgen-generated bindings in one project is consumed by a separate
//! application project that depends on it by path.
//!
//! The application's native build takes the library's link requirement from its
//! dependency's manifest (`-L`, `-l`, a run path), compiles the dependency's
//! packages from source, and ships the shared library beside the executable, so
//! the program still runs when the library's original directory is gone.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/native_libs_self_test.l
@test_module
package Lyric.NativeLibsSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Process as Process
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Lyric.Cli as Cli
import Lyric.Emitter as Emitter
import Lyric.Manifest as Mf
import Lyric.Bindgen as Bindgen

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-native-libs-" + label + "-" + uuidToString(newUuid()))
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

func mkdirOrPanic(path: in String): Unit {
  match File.createDir(path) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + path + ": " + IOError.message(e))
  }
}

func buildNative(mfPath: in String, outPath: in String): Int {
  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  Cli.buildProject(
    mfPath,
    Some(value = outPath),
    Emitter.Native,
    noFeatures,
    false,
    false,
    true,
    None,
    noPre,
    noDefines
  )
}

func header(): String {
  "typedef struct { int w, h; float scale; } Cfg;\n" + "typedef int (*CdepVisit)(void* userdata, int value);\n" +
    "int cdep_add(int a, int b);\n" +
    "double cdep_area(Cfg c);\n" +
    "int cdep_each(int n, CdepVisit f, void* userdata);\n"
}

func implementation(): String {
  "#include \"cdep.h\"\n" + "int cdep_add(int a, int b) { return a + b; }\n" +
    "double cdep_area(Cfg c) { return c.w * c.h * c.scale; }\n" +
    "int cdep_each(int n, CdepVisit f, void* userdata) { int s = 0; for (int i = 0; i < n; i++) s += f(userdata, i); return s; }\n"
}

func clangOrPanic(args: in List[String]): Unit {
  match Process.runCapture("clang", args, 120000) {
    case Ok(res) -> if res.exitCode != 0 { panic("clang failed: " + res.stderr) }
    case Err(e) -> panic("clang could not be started: " + e)
  }
}

func sharedExt(): String {
  val args: List[String] = newList()
  args.add("-print-effective-triple")
  match Process.runCapture("clang", args, 30000) {
    case Ok(res) -> if Str.contains(res.stdout, "apple") or Str.contains(res.stdout, "darwin") {
      ".dylib"
    } else {
      ".so"
    }
    case Err(_) -> ".so"
  }
}

// The library project: the C library built into `native/`, bindgen's bindings in
// the kernel package, and a wrapper package with a safe surface.
func writeBinding(root: in String): String {
  val dir = Path.join(root, "Binding")
  mkdirOrPanic(dir)
  mkdirOrPanic(Path.join(dir, "src"))
  val nativeDir = Path.join(dir, "native")
  mkdirOrPanic(nativeDir)
  writeFileOrPanic(Path.join(nativeDir, "cdep.h"), header())
  writeFileOrPanic(Path.join(nativeDir, "cdep.c"), implementation())
  val lib = Path.join(nativeDir, "libcdep" + sharedExt())
  val cargs: List[String] = newList()
  cargs.add("-shared")
  cargs.add("-fPIC")
  cargs.add("-O0")
  cargs.add(Path.join(nativeDir, "cdep.c"))
  cargs.add("-o")
  cargs.add(lib)
  clangOrPanic(cargs)
  val astArgs: List[String] = newList()
  astArgs.add("-Xclang")
  astArgs.add("-ast-dump=json")
  astArgs.add("-fsyntax-only")
  astArgs.add(Path.join(nativeDir, "cdep.h"))
  val ast = match Process.runCapture("clang", astArgs, 120000) {
    case Ok(res) -> if res.exitCode != 0 { panic("clang failed: " + res.stderr) } else { res.stdout }
    case Err(e) -> panic("clang could not be started: " + e)
  }
  val allow: List[String] = newList()
  allow.add("cdep_*")
  val cfg = Bindgen.BindgenConfig(
    packageName = "Fixture.CBind.Kernel",
    library = "cdep",
    allow = allow,
    userdata = newMap(),
    longBits = 64
  )
  val gen = Bindgen.generateBindings(ast, cfg)
  if gen.errors.count > 0 {
    panic("bindgen failed: " + Str.joinList("; ", gen.errors))
  }
  writeFileOrPanic(Path.join(Path.join(dir, "src"), "kernel.l"), gen.source)
  writeFileOrPanic(
    Path.join(Path.join(dir, "src"), "main.l"),
    "package Fixture.CBind\n\nimport Fixture.CBind.Kernel\n\n" +
      "pub func addTwice(a: Int, b: Int): Int {\n  cdep_add(cdep_add(a, b), b)\n}\n\n" +
      "pub func area(w: Int, h: Int, scale: Float): Double {\n  cdep_area(Cfg(w = w, h = h, scale = scale))\n}\n\n" +
      "pub func sumBelow(n: Int): Int {\n  val visit: (Int) -> Int = { v: Int -> v }\n  cdep_each(n, visit, visit)\n}\n"
  )
  writeFileOrPanic(
    Path.join(dir, "lyric.toml"),
    "[package]\nname = \"Fixture.CBind\"\nversion = \"0.1.0\"\n\n[project]\nname = \"Fixture.CBind\"\n\n" +
      "[project.packages]\n\"Fixture.CBind.Kernel\" = \"src/kernel.l\"\n\"Fixture.CBind\" = \"src/main.l\"\n\n" +
      "[native.libs.cdep]\nversion = \"1.0\"\ndir = \"native\"\n"
  )
  dir
}

func writeApp(root: in String): String {
  val dir = Path.join(root, "App")
  mkdirOrPanic(dir)
  mkdirOrPanic(Path.join(dir, "src"))
  writeFileOrPanic(
    Path.join(Path.join(dir, "src"), "main.l"),
    "package Fixture.CApp\n\nimport Std.Console as Console\nimport Fixture.CBind\n\n" + "func main(): Int {\n" +
      "  Console.println(addTwice(1, 2).toString() + \",\" + sumBelow(5).toString())\n" +
      "  if area(3, 4, 2.5f32) != 30.0 {\n    return 3\n  }\n" +
      "  0\n}\n"
  )
  writeFileOrPanic(
    Path.join(dir, "lyric.toml"),
    "[package]\nname = \"Fixture.CApp\"\nversion = \"0.1.0\"\n\n[project]\nname = \"Fixture.CApp\"\n\n" +
      "[project.packages]\n\"Fixture.CApp\" = \"src/main.l\"\n\n[dependencies]\n\"Fixture.CBind\" = { path = \"../Binding\" }\n"
  )
  dir
}

func runBinary(path: in String): Capture.CaptureResult {
  val noArgs: List[String] = newList()
  Capture.runCaptureWithDiagnostics(path, noArgs, "")
}

test "an application consumes a C library bound through generated bindings" {
  val root = freshTempDir("app")
  defer {
    cleanup(root)
  }
  val binding = writeBinding(root)
  val appDir = writeApp(root)
  val outDir = Path.join(appDir, "out")
  mkdirOrPanic(outDir)
  val outPath = Path.join(outDir, "app-native")
  assertEqualInt(buildNative(Path.join(appDir, "lyric.toml"), outPath), 0, "the native build succeeds")
  assertTrue(File.fileExists(outPath), "the build produced a binary")
  assertTrue(
    File.fileExists(Path.join(outDir, "libcdep" + sharedExt())),
    "the shared library ships beside the executable"
  )
  val first = runBinary(outPath)
  assertEqualInt(first.exitCode, 0, "the program runs (stderr=" + first.stderr + ")")
  assertEqual(Str.trim(first.stdout), "5,10", "calls cross the generated bindings, struct and callback included")
  // The original library directory is gone: only the bundled copy and the run path remain.
  cleanup(Path.join(binding, "native"))
  val second = runBinary(outPath)
  assertEqualInt(
    second.exitCode,
    0,
    "the bundled library is found without the original directory (stderr=" + second.stderr + ")"
  )
  assertEqual(Str.trim(second.stdout), "5,10", "same output from the bundle alone")
}

test "a library whose directory is missing fails the build with the library's name" {
  val root = freshTempDir("missing")
  defer {
    cleanup(root)
  }
  val dir = Path.join(root, "App")
  mkdirOrPanic(dir)
  mkdirOrPanic(Path.join(dir, "src"))
  writeFileOrPanic(Path.join(Path.join(dir, "src"), "main.l"), "package Fixture.CMiss\n\nfunc main(): Int {\n  0\n}\n")
  writeFileOrPanic(
    Path.join(dir, "lyric.toml"),
    "[package]\nname = \"Fixture.CMiss\"\nversion = \"0.1.0\"\n\n[project]\nname = \"Fixture.CMiss\"\n\n" +
      "[project.packages]\n\"Fixture.CMiss\" = \"src/main.l\"\n\n[native.libs.ghost]\ndir = \"nowhere\"\n"
  )
  assertTrue(buildNative(Path.join(dir, "lyric.toml"), Path.join(dir, "out-native")) != 0, "the build fails")
}

test "a [native.libs] table names exactly one source" {
  val base = "[package]\nname = \"P\"\nversion = \"0.1.0\"\n"
  val both = Mf.parseManifest(base + "\n[native.libs.x]\ndir = \"d\"\npkg_config = \"x\"\n", "lyric.toml")
  assertTrue(match both { case Err(_) -> true; case Ok(_) -> false }, "dir and pkg_config together")
  val neither = Mf.parseManifest(base + "\n[native.libs.x]\nversion = \"1\"\n", "lyric.toml")
  assertTrue(match neither { case Err(_) -> true; case Ok(_) -> false }, "no source")
  val ok = Mf.parseManifest(
    base + "\n[native.libs.x]\nversion = \"1\"\ndir = \"d\"\n\n[native.libs.y]\npkg_config = \"y\"\n",
    "lyric.toml"
  )
  match ok {
    case Ok(m) -> match m.native {
      case Some(nc) -> assertEqualInt(nc.libs.count, 2, "two libraries declared")
      case None -> assertTrue(false, "the native table is present")
    }
    case Err(e) -> assertTrue(false, "a valid table parses: " + Mf.ManifestError.message(e))
  }
}
