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
  Environment.getVarOrDefault("TMPDIR", "/tmp")
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
