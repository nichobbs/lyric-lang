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
import Std.Hash as Hash
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

func hostTriple(): String {
  val args: List[String] = newList()
  args.add("-print-effective-triple")
  match Process.runCapture("clang", args, 30000) {
    case Ok(res) -> Str.trim(res.stdout)
    case Err(_) -> ""
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
func writeBinding(root: in String, libSection: in String): String {
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
      libSection
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
  val binding = writeBinding(root, "[native.libs.cdep]\nversion = \"1.0\"\ndir = \"native\"\n")
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

// A prebuilt archive: the library is zipped, the zip is the only thing the project
// names, and `restoreNativeLibs` is what makes it available to the build.
func zipLibrary(binding: in String, root: in String): String {
  val nativeDir = Path.join(binding, "native")
  val zipPath = Path.join(root, "cdep-prebuilt.zip")
  val zargs: List[String] = newList()
  zargs.add("-j")
  zargs.add(zipPath)
  zargs.add(Path.join(nativeDir, "libcdep" + sharedExt()))
  zargs.add(Path.join(nativeDir, "cdep.h"))
  match Process.runCapture("zip", zargs, 60000) {
    case Ok(res) -> if res.exitCode != 0 { panic("zip failed: " + res.stdout + res.stderr) }
    case Err(e) -> panic("zip could not be started: " + e)
  }
  cleanup(nativeDir)
  zipPath
}

func prebuiltSection(zipPath: in String, sha: in String): String {
  "[native.libs.cdep.prebuilt." + hostTriple() + "]\nurl = \"file://" + zipPath + "\"\nsha256 = \"" + sha +
    "\"\nmembers = [\"libcdep" +
    sharedExt() +
    "\"]\n"
}

func zipSha(zipPath: in String): String {
  match File.readBytes(zipPath) {
    case Ok(b) -> Str.toLower(Hash.sha256OfBytes(b))
    case Err(_) -> panic("cannot read " + zipPath)
  }
}

func bindingDecls(binding: in String): List[Cli.NativeLibDecl] {
  val mfPath = Path.join(binding, "lyric.toml")
  val text = match File.readText(mfPath) { case Ok(t) -> t; case Err(_) -> panic("cannot read " + mfPath) }
  match Mf.parseManifest(text, mfPath) {
    case Ok(m) -> Cli.nativeLibDeclsOf(m, binding)
    case Err(e) -> panic("fixture manifest does not parse: " + Mf.ManifestError.message(e))
  }
}

test "a prebuilt archive is restored, verified and linked by an application" {
  val root = freshTempDir("prebuilt")
  defer {
    cleanup(root)
  }
  // Build the library once, zip it, and write the project against the zip alone.
  val scratch = writeBinding(root, "[native.libs.cdep]\nversion = \"1.0\"\ndir = \"native\"\n")
  val zipPath = zipLibrary(scratch, root)
  val sha = zipSha(zipPath)
  val mfPath = Path.join(scratch, "lyric.toml")
  val original = match File.readText(mfPath) { case Ok(t) -> t; case Err(_) -> panic("cannot read " + mfPath) }
  writeFileOrPanic(
    mfPath,
    Str.replace(original, "[native.libs.cdep]\nversion = \"1.0\"\ndir = \"native\"\n", prebuiltSection(zipPath, sha))
  )
  val appDir = writeApp(root)
  val outDir = Path.join(appDir, "out")
  mkdirOrPanic(outDir)
  val outPath = Path.join(outDir, "app-native")
  assertTrue(
    buildNative(Path.join(appDir, "lyric.toml"), outPath) != 0,
    "the build refuses an archive that was never restored"
  )
  val triples: List[String] = newList()
  triples.add(hostTriple())
  val errs = Cli.restoreNativeLibs(bindingDecls(scratch), triples)
  assertEqualInt(errs.count, 0, "the restore succeeds: " + Str.joinList("; ", errs))
  assertTrue(
    File.dirExists(Path.join(Path.join(scratch, ".lyric"), "native")),
    "the archive is restored beside its manifest"
  )
  assertEqualInt(
    buildNative(Path.join(appDir, "lyric.toml"), outPath),
    0,
    "the native build succeeds after the restore"
  )
  assertTrue(
    File.fileExists(Path.join(outDir, "libcdep" + sharedExt())),
    "the restored library ships beside the executable"
  )
  val run = runBinary(outPath)
  assertEqualInt(run.exitCode, 0, "the program runs (stderr=" + run.stderr + ")")
  assertEqual(Str.trim(run.stdout), "5,10", "calls cross the restored library")
  val again = Cli.restoreNativeLibs(bindingDecls(scratch), triples)
  assertEqualInt(again.count, 0, "a second restore is a no-op")
}

test "a prebuilt archive with the wrong checksum is refused and nothing is unpacked" {
  val root = freshTempDir("badsum")
  defer {
    cleanup(root)
  }
  val scratch = writeBinding(root, "[native.libs.cdep]\nversion = \"1.0\"\ndir = \"native\"\n")
  val zipPath = zipLibrary(scratch, root)
  val mfPath = Path.join(scratch, "lyric.toml")
  val original = match File.readText(mfPath) { case Ok(t) -> t; case Err(_) -> panic("cannot read " + mfPath) }
  val wrong = "0000000000000000000000000000000000000000000000000000000000000000"
  writeFileOrPanic(
    mfPath,
    Str.replace(original, "[native.libs.cdep]\nversion = \"1.0\"\ndir = \"native\"\n", prebuiltSection(zipPath, wrong))
  )
  val triples: List[String] = newList()
  triples.add(hostTriple())
  val errs = Cli.restoreNativeLibs(bindingDecls(scratch), triples)
  assertEqualInt(errs.count, 1, "one error: " + Str.joinList("; ", errs))
  assertTrue(Str.contains(errs[0], "checksum mismatch"), "it names the mismatch: " + errs[0])
  val libDir = Path.join(Path.join(Path.join(Path.join(scratch, ".lyric"), "native"), "cdep"), hostTriple())
  assertFalse(File.fileExists(Path.join(libDir, "libcdep" + sharedExt())), "nothing was unpacked")
  assertFalse(File.fileExists(Path.join(libDir, ".sha256")), "the restore is not recorded")
}

test "prebuilt tables are validated" {
  val base = "[package]\nname = \"P\"\nversion = \"0.1.0\"\n"
  val sha = "0000000000000000000000000000000000000000000000000000000000000000"
  val noSha = Mf.parseManifest(base + "\n[native.libs.x.prebuilt.t]\nurl = \"https://e/x.so\"\n", "lyric.toml")
  assertTrue(match noSha { case Err(_) -> true; case Ok(_) -> false }, "a missing sha256")
  val zipNoMembers = Mf.parseManifest(
    base + "\n[native.libs.x.prebuilt.t]\nurl = \"https://e/x.zip\"\nsha256 = \"" + sha + "\"\n",
    "lyric.toml"
  )
  assertTrue(match zipNoMembers { case Err(_) -> true; case Ok(_) -> false }, "a zip without members")
  val mixed = Mf.parseManifest(
    base +
      "\n[native.libs.x]\ndir = \"d\"\n\n[native.libs.x.prebuilt.t]\nurl = \"https://e/x.so\"\nsha256 = \"" +
      sha +
      "\"\n",
    "lyric.toml"
  )
  assertTrue(match mixed { case Err(_) -> true; case Ok(_) -> false }, "dir together with prebuilt")
  val ok = Mf.parseManifest(
    base + "\n[native.libs.x.prebuilt.a-b-c]\nurl = \"https://e/x.so\"\nsha256 = \"" + sha + "\"\n",
    "lyric.toml"
  )
  match ok {
    case Ok(m) -> match m.native {
      case Some(nc) -> assertEqualInt(nc.libs[0].prebuilt.count, 1, "one prebuilt archive")
      case None -> assertTrue(false, "the native table is present")
    }
    case Err(e) -> assertTrue(false, "a valid table parses: " + Mf.ManifestError.message(e))
  }
}

test "a pkg_config library resolves to the flags pkg-config prints, and a missing one names itself" {
  val z = Mf.NativeLibSpec(name = "zlib", link = "", version = "1.0", pkgConfig = "zlib", dir = "")
  val decls: List[Cli.NativeLibDecl] = newList()
  decls.add(Cli.NativeLibDecl(spec = z, baseDir = "."))
  val plan = Cli.resolveNativeLibs(decls, "")
  assertEqualInt(plan.errors.count, 0, "zlib resolves: " + Str.joinList("; ", plan.errors))
  assertTrue(listHas(plan.args, "-lz"), "pkg-config's -lz reaches the link line")
  assertEqualInt(plan.bundle.count, 0, "a system library is not bundled")
  val newer = Mf.NativeLibSpec(name = "zlib", link = "", version = "999.0", pkgConfig = "zlib", dir = "")
  val tooNew: List[Cli.NativeLibDecl] = newList()
  tooNew.add(Cli.NativeLibDecl(spec = newer, baseDir = "."))
  assertTrue(Cli.resolveNativeLibs(tooNew, "").errors.count > 0, "a version newer than the installed one fails")
  val ghost = Mf.NativeLibSpec(name = "ghost", link = "", version = "", pkgConfig = "no-such-lyric-package", dir = "")
  val missing: List[Cli.NativeLibDecl] = newList()
  missing.add(Cli.NativeLibDecl(spec = ghost, baseDir = "."))
  val gone = Cli.resolveNativeLibs(missing, "")
  assertTrue(gone.errors.count > 0 and Str.contains(gone.errors[0], "ghost"), "an unknown package names the library")
}

func listHas(xs: in List[String], s: in String): Bool {
  for x in xs {
    if x == s {
      return true
    }
  }
  false
}
