//! native_dependency_self_test.l — a `--target native` project build compiles
//! its Lyric `[dependencies]` from source into the same native build (#7833).
//!
//! A path or `workspace = true` dependency's packages, and those of its own
//! path and workspace dependencies, join the project's packages; each is
//! erased with its own manifest's features.  A registry or git dependency
//! has no local source, so a native build refuses it.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/native_dependency_self_test.l
@test_module
package Lyric.NativeDependencySelfTest

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
import Lyric.Cli as Cli
import Lyric.Emitter as Emitter
import Lyric.Manifest as Mf

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-native-deps-" + label + "-" + uuidToString(newUuid()))
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

// A project directory `root/<dir>` with a manifest declaring one package,
// `pkg`, whose single source file is `src/main.l` holding `source`.
// `extra` is appended to the manifest (features, dependencies).
func mkProject(root: in String, dir: in String, pkg: in String, extra: in String, source: in String): String {
  val projDir = Path.join(root, dir)
  match File.createDir(Path.join(projDir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + projDir + ": " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(projDir, "lyric.toml"),
    "[package]\nname = \"" + pkg + "\"\nversion = \"0.1.0\"\n\n[project]\nname = \"" + pkg +
      "\"\n\n[project.packages]\n\"" +
      pkg +
      "\" = \"src/main.l\"\n" +
      extra
  )
  writeFileOrPanic(Path.join(projDir, "src/main.l"), source)
  projDir
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

// The workspace below: `App` depends on `Dep` by path and on `WsDep` as a
// workspace member; `Dep` depends on `Leaf` by path and enables its own
// `loud` feature by default.
func writeWorkspace(root: in String): String {
  writeFileOrPanic(Path.join(root, "lyric.toml"), "[workspace]\nexclude = []\n")
  val _ = mkProject(
    root,
    "Leaf",
    "Fixture.NLeaf",
    "",
    "package Fixture.NLeaf\n\npub func leafWord(): String {\n  \"leaf\"\n}\n"
  )
  val _ = mkProject(
    root,
    "Dep",
    "Fixture.NDep",
    "\n[features]\ndefault = [\"loud\"]\nloud = []\n\n[dependencies]\n\"Fixture.NLeaf\" = { path = \"../Leaf\" }\n",
    "package Fixture.NDep\n\nimport Fixture.NLeaf\n\npub func depGreeting(): String {\n  \"dep+\" + leafWord()\n}\n\n" +
      "@cfg(feature = \"loud\")\npub func depVolume(): String {\n  \"loud\"\n}\n"
  )
  val _ = mkProject(
    root,
    "WsDep",
    "Fixture.NWsDep",
    "",
    "package Fixture.NWsDep\n\npub func wsWord(): String {\n  \"ws\"\n}\n"
  )
  mkProject(
    root,
    "App",
    "Fixture.NApp",
    "\n[dependencies]\n\"Fixture.NDep\" = { path = \"../Dep\" }\n\"Fixture.NWsDep\" = { workspace = true }\n",
    "package Fixture.NApp\n\nimport Std.Console as Console\nimport Fixture.NDep\nimport Fixture.NWsDep\n\n" +
      "func main(): Int {\n  Console.println(depGreeting() + \",\" + depVolume() + \",\" + wsWord())\n  0\n}\n"
  )
}

test "a native project build compiles path, transitive and workspace dependencies from source" {
  val root = freshTempDir("ok")
  defer {
    cleanup(root)
  }
  val appDir = writeWorkspace(root)
  val outPath = Path.join(appDir, "app-native")
  assertEqualInt(buildNative(Path.join(appDir, "lyric.toml"), outPath), 0, "the native build succeeds")
  assertTrue(File.fileExists(outPath), "the native build produced a binary")
  val noArgs: List[String] = newList()
  val run = Capture.runCaptureWithDiagnostics(outPath, noArgs, "")
  assertEqualInt(run.exitCode, 0, "the binary exits 0 (stderr=" + run.stderr + ")")
  // `depVolume` exists only under Dep's own default feature, which App does
  // not declare: it compiles because Dep is erased with Dep's features.
  assertEqual(Str.trim(run.stdout), "dep+leaf,loud,ws", "calls into each dependency")
  assertFalse(
    File.fileExists(Path.join(Path.join(root, "Dep"), "bin")),
    "a native build never builds a dependency's own DLL"
  )
}

test "a native project build refuses a registry dependency" {
  val root = freshTempDir("registry")
  defer {
    cleanup(root)
  }
  val appDir = mkProject(
    root,
    "App",
    "Fixture.NRegApp",
    "\n[dependencies]\n\"Some.Library\" = \"1.0.0\"\n",
    "package Fixture.NRegApp\n\nfunc main(): Int {\n  0\n}\n"
  )
  val mfPath = Path.join(appDir, "lyric.toml")
  val manifest = match Mf.parseManifest(unwrapText(mfPath), mfPath) {
    case Ok(m) -> m
    case Err(e) -> panic("fixture manifest does not parse: " + Mf.ManifestError.message(e))
  }
  val noFeatures: List[String] = newList()
  val resolved = Cli.resolveManifestDependencies(manifest, mfPath, Emitter.Native, noFeatures, false)
  assertTrue(resolved.hadUnsupportedDep, "native flags the registry dependency")
  val onDotnet = Cli.resolveManifestDependencies(manifest, mfPath, Emitter.Dotnet, noFeatures, false)
  assertFalse(onDotnet.hadUnsupportedDep, "dotnet resolves registry dependencies as before")
  assertTrue(buildNative(mfPath, Path.join(appDir, "app-native")) != 0, "the native build fails")
}

test "a native project build accepts a declared Std dependency" {
  // The standard library is compiled from source on native; declaring it is
  // not a registry dependency.
  val root = freshTempDir("std")
  defer {
    cleanup(root)
  }
  val appDir = mkProject(
    root,
    "App",
    "Fixture.NStdApp",
    "\n[dependencies]\nStd = \"*\"\n",
    "package Fixture.NStdApp\n\nfunc main(): Int {\n  0\n}\n"
  )
  val mfPath = Path.join(appDir, "lyric.toml")
  val manifest = match Mf.parseManifest(unwrapText(mfPath), mfPath) {
    case Ok(m) -> m
    case Err(e) -> panic("fixture manifest does not parse: " + Mf.ManifestError.message(e))
  }
  val noFeatures: List[String] = newList()
  val resolved = Cli.resolveManifestDependencies(manifest, mfPath, Emitter.Native, noFeatures, false)
  assertFalse(resolved.hadUnsupportedDep, "a Std dependency is not refused")
}

test "a native project build refuses a registry dependency of a path dependency" {
  val root = freshTempDir("transitive-registry")
  defer {
    cleanup(root)
  }
  val _ = mkProject(
    root,
    "Dep",
    "Fixture.NRegDep",
    "\n[dependencies]\n\"Some.Library\" = \"1.0.0\"\n",
    "package Fixture.NRegDep\n\npub func one(): Int {\n  1\n}\n"
  )
  val appDir = mkProject(
    root,
    "App",
    "Fixture.NRegApp2",
    "\n[dependencies]\n\"Fixture.NRegDep\" = { path = \"../Dep\" }\n",
    "package Fixture.NRegApp2\n\nimport Fixture.NRegDep\n\nfunc main(): Int {\n  one() - 1\n}\n"
  )
  val mfPath = Path.join(appDir, "lyric.toml")
  val manifest = match Mf.parseManifest(unwrapText(mfPath), mfPath) {
    case Ok(m) -> m
    case Err(e) -> panic("fixture manifest does not parse: " + Mf.ManifestError.message(e))
  }
  val noFeatures: List[String] = newList()
  val resolved = Cli.resolveManifestDependencies(manifest, mfPath, Emitter.Native, noFeatures, false)
  assertTrue(resolved.hadUnsupportedDep, "native flags the dependency's registry dependency")
}

func unwrapText(path: in String): String {
  match File.readText(path) {
    case Ok(t) -> t
    case Err(e) -> panic("cannot read " + path + ": " + IOError.message(e))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dependency packages are lowered by reachability (#8429).
//
// A dependency package declares `missingNative`, an extern in a library that
// does not exist.  Naming that library at the link step fails the build, so
// a build that succeeds proves nothing reachable named it, and the control
// test of each pair, whose program does reach it, proves the extern really
// does name the library (the build fails).
// ─────────────────────────────────────────────────────────────────────────────
val missingExtern: String = "@library(\"lyric_no_such_lib_8429\")\nextern func missingNative(x: Int): Int = \"lyric_no_such_symbol\"\n"

record DepBuild {
  exitCode: Int
  stdout: String
}

// Builds `App` (source `appSrc`) against the dependency package
// `Fixture.PDep` (source `depSrc`) for native and runs it.  `exitCode` is the
// build's when it failed, else the program's.
func buildAndRunDep(root: in String, depSrc: in String, appSrc: in String): DepBuild {
  val _ = mkProject(root, "Dep", "Fixture.PDep", "", depSrc)
  val appDir = mkProject(
    root,
    "App",
    "Fixture.PApp",
    "\n[dependencies]\n\"Fixture.PDep\" = { path = \"../Dep\" }\n",
    appSrc
  )
  val outPath = Path.join(appDir, "app-native")
  val built = buildNative(Path.join(appDir, "lyric.toml"), outPath)
  if built != 0 {
    return DepBuild(exitCode = built, stdout = "")
  }
  val noArgs: List[String] = newList()
  val run = Capture.runCaptureWithDiagnostics(outPath, noArgs, "")
  DepBuild(exitCode = run.exitCode, stdout = Str.trim(run.stdout))
}

func appSource(body: in String): String {
  "package Fixture.PApp\n\nimport Std.Console as Console\nimport Fixture.PDep\n\nfunc main(): Int {\n" + body +
    "  0\n}\n"
}

test "an extern of a dependency that nothing reachable calls links no library" {
  val root = freshTempDir("prune-func")
  defer {
    cleanup(root)
  }
  val dep = "package Fixture.PDep\n\n" + missingExtern +
    "\npub func used(x: in Int): Int {\n  x + 1\n}\n\npub func neverCalled(x: in Int): Int {\n  missingNative(x)\n}\n"
  val r = buildAndRunDep(root, dep, appSource("  Console.println(used(41).toString())\n"))
  assertEqualInt(r.exitCode, 0, "the build links without the missing library")
  assertEqual(r.stdout, "42", "the reachable function runs")
}

test "an extern of a dependency that reachable code calls links its library" {
  val root = freshTempDir("prune-func-control")
  defer {
    cleanup(root)
  }
  val dep = "package Fixture.PDep\n\n" + missingExtern +
    "\npub func neverCalled(x: in Int): Int {\n  missingNative(x)\n}\n"
  val r = buildAndRunDep(root, dep, appSource("  Console.println(neverCalled(1).toString())\n"))
  assertTrue(r.exitCode != 0, "the build fails: the reached extern names the missing library")
}

test "a dependency record's methods follow reachability, including through a field chain" {
  val root = freshTempDir("prune-record")
  defer {
    cleanup(root)
  }
  val dep = "package Fixture.PDep\n\n" + missingExtern +
    "\npub record Meter {\n  n: Int\n\n  func reading(self: in Meter): Int {\n    self.n + 1\n  }\n}\n" +
    "\npub record Unused {\n  n: Int\n\n  func boom(self: in Unused): Int {\n    missingNative(self.n)\n  }\n}\n" +
    "\npub func makeMeter(n: in Int): Meter {\n  Meter(n = n)\n}\n"
  val app = "package Fixture.PApp\n\nimport Std.Console as Console\nimport Fixture.PDep\n\n" +
    "record Holder {\n  m: Meter\n}\n\n" +
    "func main(): Int {\n  val h = Holder(m = makeMeter(40))\n  Console.println(h.m.reading().toString())\n  0\n}\n"
  val r = buildAndRunDep(root, dep, app)
  assertEqualInt(r.exitCode, 0, "the unused record's method is not lowered")
  assertEqual(r.stdout, "41", "the method called through a field chain ran")
}

test "a dependency record's method that reachable code calls links its library" {
  val root = freshTempDir("prune-record-control")
  defer {
    cleanup(root)
  }
  val dep = "package Fixture.PDep\n\n" + missingExtern +
    "\npub record Unused {\n  n: Int\n\n  func boom(self: in Unused): Int {\n    missingNative(self.n)\n  }\n}\n"
  val r = buildAndRunDep(root, dep, appSource("  Console.println(Unused(n = 1).boom().toString())\n"))
  assertTrue(r.exitCode != 0, "the build fails: the called method names the missing library")
}

test "a dependency protected type is lowered only when reachable code uses it" {
  val root = freshTempDir("prune-protected")
  defer {
    cleanup(root)
  }
  val dep = "package Fixture.PDep\n\n" + missingExtern +
    "\npub protected type Tally {\n  var n: Int = 0\n\n  entry bump(): Unit {\n    n = n + 1\n  }\n\n  func read(): Int {\n    n\n  }\n}\n" +
    "\npub protected type DeadTally {\n  var n: Int = 0\n\n  entry boom(): Unit {\n    n = missingNative(n)\n  }\n}\n"
  val r = buildAndRunDep(
    root,
    dep,
    appSource("  val t = Tally()\n  t.bump()\n  t.bump()\n  Console.println(t.read().toString())\n")
  )
  assertEqualInt(r.exitCode, 0, "the unused protected type's entry is not lowered")
  assertEqual(r.stdout, "2", "the used protected type works")
}

test "a dependency protected type that reachable code constructs links its library" {
  val root = freshTempDir("prune-protected-control")
  defer {
    cleanup(root)
  }
  val dep = "package Fixture.PDep\n\n" + missingExtern +
    "\npub protected type DeadTally {\n  var n: Int = 0\n\n  entry boom(): Unit {\n    n = missingNative(n)\n  }\n}\n"
  val r = buildAndRunDep(root, dep, appSource("  val t = DeadTally()\n  Console.println(\"made\")\n"))
  assertTrue(r.exitCode != 0, "the build fails: constructing the type lowers its entries")
}

test "a dependency impl is lowered only when its record is constructed by reachable code" {
  val root = freshTempDir("prune-impl")
  defer {
    cleanup(root)
  }
  val dep = "package Fixture.PDep\n\n" + missingExtern + "\npub interface Shape {\n  func area(): Int\n}\n" +
    "\npub record Sq {\n  side: Int\n}\n\nimpl Shape for Sq {\n  func area(): Int {\n    self.side * self.side\n  }\n}\n" +
    "\npub record Dead {\n  n: Int\n}\n\nimpl Shape for Dead {\n  func area(): Int {\n    missingNative(self.n)\n  }\n}\n" +
    "\npub func makeShape(s: in Int): Shape {\n  Sq(side = s)\n}\n"
  val r = buildAndRunDep(root, dep, appSource("  Console.println(makeShape(6).area().toString())\n"))
  assertEqualInt(r.exitCode, 0, "the impl of the record nothing constructs is not lowered")
  assertEqual(r.stdout, "36", "the impl of the constructed record dispatches")
}

test "a dependency module val's initializer runs only when the val is read" {
  val root = freshTempDir("prune-modval")
  defer {
    cleanup(root)
  }
  val dep = "package Fixture.PDep\n\n" + missingExtern +
    "\npub protected type Gate {\n  var on: Int = 0\n\n  entry open(): Unit {\n    on = missingNative(1)\n  }\n}\n" +
    "\nval gate: Gate = Gate()\n\npub func openGate(): Unit {\n  gate.open()\n}\n\npub func plain(): Int {\n  7\n}\n"
  val r = buildAndRunDep(root, dep, appSource("  Console.println(plain().toString())\n"))
  assertEqualInt(r.exitCode, 0, "the val nothing reads pulls in nothing")
  assertEqual(r.stdout, "7", "the plain function runs")
}

test "a dependency module val that reachable code reads links its library" {
  val root = freshTempDir("prune-modval-control")
  defer {
    cleanup(root)
  }
  val dep = "package Fixture.PDep\n\n" + missingExtern +
    "\npub protected type Gate {\n  var on: Int = 0\n\n  entry open(): Unit {\n    on = missingNative(1)\n  }\n}\n" +
    "\nval gate: Gate = Gate()\n\npub func openGate(): Unit {\n  gate.open()\n}\n"
  val r = buildAndRunDep(root, dep, appSource("  openGate()\n  Console.println(\"opened\")\n"))
  assertTrue(r.exitCode != 0, "the build fails: reading the val builds the gate and its entries")
}

test "what a dependency's generic record method and default argument call is reachable" {
  val root = freshTempDir("prune-generic")
  defer {
    cleanup(root)
  }
  val dep = "package Fixture.PDep\n\n" + missingExtern +
    "\nfunc offset(): Int {\n  10\n}\n\nfunc scale(): Int {\n  3\n}\n" +
    "\npub record Cell[T] {\n  v: T\n\n  func shifted(self: in Cell[T]): Int {\n    offset() + 1\n  }\n}\n" +
    "\npub func scaled(x: in Int = scale()): Int {\n  x * 2\n}\n"
  val r = buildAndRunDep(
    root,
    dep,
    appSource(
      "  val c = Cell(v = 5)\n  Console.println(c.shifted().toString() + \",\" + scaled().toString())\n"
    )
  )
  assertEqualInt(r.exitCode, 0, "the build succeeds (stdout=" + r.stdout + ")")
  assertEqual(r.stdout, "11,6", "the generic method and the default argument reached their callees")
}
