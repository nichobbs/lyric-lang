//! cli_wasm_npm_project_self_test.l — CLI-level coverage of the `[npm]` checks in
//! a `--target native --triple wasm32-wasi` project build (docs/35 W5): the
//! build restores a stale or missing install itself, a package with no shim is
//! `B0061`, a shim binding a name the package lacks is `B0062`, and an `npm:`
//! import of a package `[npm]` does not declare is `B0064`.
//!
//! Driven through `Lyric.Cli.buildProjectWithNativeFlagsShaped`, the entry point
//! `lyric build --manifest ... --shape module` reaches, so a regression in the
//! CLI layer (the checks never run, run too early, skip the restore) is caught.
//!
//! Requires `WASI_SDK_PATH` and the wasm32 runtime archive, plus `node` and `npm`
//! on PATH.  Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/cli_wasm_npm_project_self_test.l
@test_module
package Lyric.CliWasmNpmProjectSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
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
  val root = Path.join(tempBase(), "lyric-wasm-npm-proj-" + label + "-" + uuidToString(newUuid()))
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

func put(root: in String, rel: in String, text: in String): Unit {
  val full = Path.join(root, rel)
  match File.createDir(Path.dirname(full)) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + Path.dirname(full) + ": " + IOError.message(e))
  }
  match File.writeText(full, text) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write " + full + ": " + IOError.message(e))
  }
}

// A project with one local NPM package (`fakepkg`, exporting `add`), an `[npm]`
// table naming it, an `app` package and, optionally, the shim package.
func writeProject(root: in String, withShim: in Bool, shimSymbol: in String, appBody: in String): String {
  put(
    root,
    "fakepkg/package.json",
    "{ \"name\": \"fakepkg\", \"version\": \"1.0.0\", \"type\": \"module\", \"main\": \"index.js\" }\n"
  )
  put(root, "fakepkg/index.js", "export function add(a, b) { return a + b + 1000; }\n")
  val shimPkg = if withShim { "\"Fakepkg\" = \"_extern_npm/fakepkg.l\"\n" } else { "" }
  put(
    root,
    "lyric.toml",
    "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[project]\nname = \"app\"\n\n[project.packages]\n" + shimPkg +
      "\"App\" = \"src/app.l\"\n\n[npm]\n\"fakepkg\" = \"file:" +
      Path.join(root, "fakepkg") +
      "\"\n"
  )
  if withShim {
    put(
      root,
      "_extern_npm/fakepkg.l",
      "@axiom(\"from npm fakepkg file:" + Path.join(root, "fakepkg") +
        "\")\npackage Fakepkg\n\n@wasmImport(\"npm:fakepkg\")\npub extern func add(a: Int, b: Int): Int = \"" +
        shimSymbol +
        "\"\n"
    )
  }
  put(root, "src/app.l", appBody)
  Path.join(root, "lyric.toml")
}

val appUsingShim: String = "package App\n\nimport Fakepkg\n\npub func viaNpm(x: Int): Int {\n  Fakepkg.add(x, 1)\n}\n"

func build(mfPath: in String, noRestore: in Bool, outPath: in String): Int {
  val noFeatures: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPre: Option[Cli.ResolvedManifestDeps] = None
  Cli.buildProjectWithNativeFlagsShaped(
    mfPath,
    Some(value = outPath),
    Emitter.Native,
    noFeatures,
    false,
    false,
    noRestore,
    None,
    noPre,
    noDefines,
    "wasm32-wasi",
    "2",
    "module"
  )
}

func readOrEmpty(path: in String): String {
  match File.readText(path) {
    case Ok(t) -> t
    case Err(_) -> ""
  }
}

test "wasm32 project build: restores the declared package itself, checks the shim, and builds" {
  val root = freshTempDir("ok")
  defer {
    cleanup(root)
  }
  val mfPath = writeProject(root, true, "add", appUsingShim)
  val wasmOut = Path.join(root, "app.wasm")
  assertEqualInt(build(mfPath, false, wasmOut), 0, "the project builds")
  assertTrue(
    File.fileExists(
      Path.join(Path.join(Path.join(Path.join(root, "target"), "npm"), "node_modules"), "fakepkg/package.json")
    ),
    "the build installed the package"
  )
  assertTrue(File.fileExists(wasmOut), "app.wasm written")
  assertTrue(
    Str.contains(readOrEmpty(Path.join(root, "app.js")), "import(\"fakepkg\")"),
    "the glue imports the package"
  )
}

test "wasm32 project build: --no-restore does not install, so the shim check cannot probe (B0062)" {
  val root = freshTempDir("norestore")
  defer {
    cleanup(root)
  }
  val mfPath = writeProject(root, true, "add", appUsingShim)
  assertTrue(build(mfPath, true, Path.join(root, "app.wasm")) != 0, "an uninstalled package fails the build")
  assertFalse(
    File.fileExists(Path.join(Path.join(Path.join(root, "target"), "npm"), "node_modules")),
    "nothing was installed"
  )
}

test "wasm32 project build: a package with no shim is B0061 when the build may not restore" {
  val root = freshTempDir("noshim")
  defer {
    cleanup(root)
  }
  val mfPath = writeProject(root, false, "add", "package App\n\npub func one(): Int {\n  1\n}\n")
  assertTrue(build(mfPath, true, Path.join(root, "app.wasm")) != 0, "the missing shim fails the build")
  assertFalse(File.fileExists(Path.join(root, "app.wasm")), "nothing was emitted")
}

test "wasm32 project build: the build's own restore scaffolds a missing shim" {
  val root = freshTempDir("scaffold")
  defer {
    cleanup(root)
  }
  val mfPath = writeProject(root, false, "add", "package App\n\npub func one(): Int {\n  1\n}\n")
  assertEqualInt(build(mfPath, false, Path.join(root, "app.wasm")), 0, "the project builds")
  assertTrue(File.fileExists(Path.join(Path.join(root, "_extern_npm"), "fakepkg.l")), "the shim scaffold was written")
}

test "wasm32 project build: a shim binding an export the package lacks is B0062" {
  val root = freshTempDir("badsym")
  defer {
    cleanup(root)
  }
  val mfPath = writeProject(root, true, "nothere", appUsingShim)
  assertTrue(build(mfPath, false, Path.join(root, "app.wasm")) != 0, "the unknown export fails the build")
  assertFalse(File.fileExists(Path.join(root, "app.wasm")), "nothing was emitted")
}

test "wasm32 project build: an npm: import of an undeclared package is B0064" {
  val root = freshTempDir("undeclared")
  defer {
    cleanup(root)
  }
  val body = "package App\n\n@wasmImport(\"npm:stranger\")\nextern func s(a: Int): Int = \"s\"\n\npub func viaStranger(x: Int): Int {\n  s(x)\n}\n"
  val mfPath = writeProject(root, true, "add", body)
  assertTrue(build(mfPath, false, Path.join(root, "app.wasm")) != 0, "the undeclared package fails the build")
  assertFalse(File.fileExists(Path.join(root, "app.wasm")), "nothing was emitted")
}
