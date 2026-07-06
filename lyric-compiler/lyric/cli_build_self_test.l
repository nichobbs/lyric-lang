//! cli_build_self_test.l — exercises pure helpers and the stdlib-colocation
//! behavior in `Lyric.Cli` (cli/cli_build.l):
//!   - `validatePackageVersionArg` (#4426, #4727) — no I/O.
//!   - `filterExtraRefsDlls` / `releaseFromDllIgnoredArgsWarning` (#4282) —
//!     pure logic pulled out of `cmdBuild`'s `--release-from-dll` branch so
//!     it's testable without invoking the native AOT release path.
//!   - `buildOneNative` (#4127) — end-to-end: compiles a temp source file
//!     and asserts `Lyric.Stdlib.dll` is colocated beside the output DLL
//!     for a runnable program (declares `func main()`) and is NOT for a
//!     library (no `main`).
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_build_self_test.l
@test_module
package Lyric.CliBuildSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Uuid
import Std.Testing
import Lyric.Cli as Cli
import Lyric.Emitter as Emitter

test "validatePackageVersionArg: empty string is rejected" {
  match Cli.validatePackageVersionArg("") {
    case None -> assertTrue(false, "empty string should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "non-empty"), "empty-string message mentions non-empty")
  }
}

test "validatePackageVersionArg: whitespace-only string is rejected" {
  match Cli.validatePackageVersionArg("   ") {
    case None -> assertTrue(false, "whitespace-only string should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "non-empty"), "whitespace-only message mentions non-empty")
  }
}

test "validatePackageVersionArg: lowercase v-prefix is rejected" {
  match Cli.validatePackageVersionArg("v1.0.0") {
    case None -> assertTrue(false, "'v1.0.0' should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "1.0.0"), "v-prefix message includes the stripped suggestion")
  }
}

test "validatePackageVersionArg: uppercase V-prefix is rejected" {
  match Cli.validatePackageVersionArg("V2.0.0") {
    case None -> assertTrue(false, "'V2.0.0' should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "2.0.0"), "V-prefix message includes the stripped suggestion")
  }
}

test "validatePackageVersionArg: plain semver is accepted" {
  match Cli.validatePackageVersionArg("1.0.0") {
    case None -> ()
    case Some(msg) -> assertTrue(false, "'1.0.0' should be accepted, got: " + msg)
  }
}

test "validatePackageVersionArg: bare 'v' (length 1, no digit to check) is accepted" {
  match Cli.validatePackageVersionArg("v") {
    case None -> ()
    case Some(msg) -> assertTrue(false, "'v' alone should be accepted, got: " + msg)
  }
}

test "validatePackageVersionArg: 'v' followed by a non-digit is accepted" {
  // Guards against false positives on words that merely start with 'v' —
  // only a v/V immediately followed by an ASCII digit is a git-tag prefix.
  match Cli.validatePackageVersionArg("vendor1.0") {
    case None -> ()
    case Some(msg) -> assertTrue(false, "'vendor1.0' should be accepted, got: " + msg)
  }
}

// ─── releaseFromDllIgnoredArgsWarning (#4282) ───────────────────────────
test "releaseFromDllIgnoredArgsWarning: single positional arg" {
  val positional: List[String] = newList()
  positional.add("foo.l")
  val msg = Cli.releaseFromDllIgnoredArgsWarning(positional)
  assertTrue(
    Str.contains(msg, "--release-from-dll") and Str.contains(msg, "foo.l"),
    "warning mentions the flag and the ignored filename, got: " + msg
  )
}

test "releaseFromDllIgnoredArgsWarning: multiple positional args are comma-joined" {
  val positional: List[String] = newList()
  positional.add("foo.l")
  positional.add("bar.l")
  val msg = Cli.releaseFromDllIgnoredArgsWarning(positional)
  assertTrue(Str.contains(msg, "foo.l, bar.l"), "multiple filenames are comma-joined, got: " + msg)
}

test "releaseFromDllIgnoredArgsWarning: empty list yields a warning with no filenames" {
  val positional: List[String] = newList()
  val msg = Cli.releaseFromDllIgnoredArgsWarning(positional)
  assertTrue(
    Str.contains(msg, "--release-from-dll"),
    "warning still names the flag with no positional args, got: " + msg
  )
}

// ─── filterExtraRefsDlls (#4282) ─────────────────────────────────────────
test "filterExtraRefsDlls: excludes the primary DLL and Lyric.Stdlib.dll, keeps only .dll files, sorted" {
  val files: List[String] = newList()
  files.add("/refs/Zeta.dll")
  files.add("/refs/App.dll")
  files.add("/refs/Lyric.Stdlib.dll")
  files.add("/refs/notes.txt")
  files.add("/refs/Alpha.dll")
  val result = Cli.filterExtraRefsDlls(files, "App.dll")
  assertEqualInt(result.count, 2, "filterExtraRefsDlls: excludes primary DLL, Lyric.Stdlib.dll, and non-DLL files")
  assertEqual(result[0], "/refs/Alpha.dll", "filterExtraRefsDlls: sorted ascending, entry 0")
  assertEqual(result[1], "/refs/Zeta.dll", "filterExtraRefsDlls: sorted ascending, entry 1")
}

test "filterExtraRefsDlls: empty input yields an empty list" {
  val files: List[String] = newList()
  val result = Cli.filterExtraRefsDlls(files, "App.dll")
  assertEqualInt(result.count, 0, "filterExtraRefsDlls: empty input")
}

test "filterExtraRefsDlls: no matches when every file is excluded" {
  val files: List[String] = newList()
  files.add("/refs/App.dll")
  files.add("/refs/Lyric.Stdlib.dll")
  files.add("/refs/readme.md")
  val result = Cli.filterExtraRefsDlls(files, "App.dll")
  assertEqualInt(result.count, 0, "filterExtraRefsDlls: primary DLL, stdlib, and non-DLL all excluded")
}

// ─── buildOneNative colocation (#4127) ──────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-clibuild-" + label + "-" + uuidToString(newUuid()))
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

test "buildOneNative: a runnable program (declares main) colocates Lyric.Stdlib.dll beside the output" {
  val dir = freshTempDir("exe")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "hello.l")
  writeFileOrPanic(srcPath, "package ExeColocationFixture\n\nfunc main(): Unit {\n  println(1)\n}\n")
  val outPath = Path.join(dir, "hello.dll")

  val exitCode = Cli.buildOneNative(srcPath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitCode, 0, "buildOneNative: exe fixture compiles cleanly")
  assertTrue(File.fileExists(outPath), "buildOneNative: output DLL is produced")
  assertTrue(
    File.fileExists(Path.join(dir, "Lyric.Stdlib.dll")),
    "buildOneNative: Lyric.Stdlib.dll is colocated beside a runnable program's output"
  )
}

test "buildOneNative: a library (no main) does NOT colocate Lyric.Stdlib.dll beside the output" {
  val dir = freshTempDir("lib")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "lib.l")
  writeFileOrPanic(srcPath, "package LibColocationFixture\n\npub func helper(): Int {\n  1\n}\n")
  val outPath = Path.join(dir, "lib.dll")

  val exitCode = Cli.buildOneNative(srcPath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitCode, 0, "buildOneNative: library fixture compiles cleanly")
  assertTrue(File.fileExists(outPath), "buildOneNative: output DLL is produced")
  assertTrue(
    not File.fileExists(Path.join(dir, "Lyric.Stdlib.dll")),
    "buildOneNative: a library build must not colocate Lyric.Stdlib.dll (would clobber a stdlib self-build)"
  )
}

// ─── single-file + nearby-manifest dependency resolution (D122) ────────
// Exercises `buildOneNative` auto-discovering a lyric.toml near a loose .l
// file — one that is compiled directly (`lyric build thatfile.l`), NOT via
// that manifest's `[project.packages]` — and resolving a `path = "..."`
// dependency declared there.  The dependency's DLL is produced with a
// direct `buildOneNative` call (mirroring how a real `lyric build
// --manifest dep/lyric.toml` populates `dep/bin/<Name>.dll`) rather than
// pulling in the full project-manifest machinery, keeping the fixture
// self-contained.
func writeManifestOrPanic(path: in String, content: in String): Unit {
  writeFileOrPanic(path, content)
}

func bytesEqual(a: in List[Byte], b: in List[Byte]): Bool {
  if a.count != b.count {
    return false
  }
  var i = 0
  while i < a.count {
    if a[i] != b[i] {
      return false
    }
    i += 1
  }
  true
}

test "buildOneNative: single-file build near a manifest resolves an already-built path dependency" {
  val depDir = freshTempDir("dep")
  defer {
    cleanup(depDir)
  }
  // `resolveManifestDependencies` requires the dependency directory to have
  // its own lyric.toml (to read its output-assembly name) even though this
  // fixture builds the DLL directly via `buildOneNative` rather than
  // `buildProject` — matching what a real `lyric build --manifest
  // dep/lyric.toml` would leave behind.
  writeManifestOrPanic(
    Path.join(depDir, "lyric.toml"),
    "[package]\n" + "name = \"DepD122\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" + "name = \"DepD122Proj\"\n" +
      "output_assembly = \"DepD122.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"DepD122\" = \"dep.l\"\n"
  )
  val depSrcPath = Path.join(depDir, "dep.l")
  writeFileOrPanic(depSrcPath, "package DepD122\n\npub func greet(name: String): String {\n  \"hi \" + name\n}\n")
  val depDllPath = Path.join(Path.join(depDir, "bin"), "DepD122.dll")
  val depExit = Cli.buildOneNative(depSrcPath, depDllPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(depExit, 0, "fixture dependency compiles cleanly")
  assertTrue(File.fileExists(depDllPath), "fixture dependency DLL exists at the expected bin/ path")

  val appDir = freshTempDir("app")
  defer {
    cleanup(appDir)
  }
  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppD122\"\n" + "version = \"0.1.0\"\n" + "\n" + "[dependencies]\n" +
      "DepD122 = { path = \"" +
      depDir +
      "\" }\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(
    looseSrcPath,
    "package AppD122.Loose\n\nimport DepD122\n\npub func run(): String {\n  greet(\"world\")\n}\n"
  )
  val outPath = Path.join(appDir, "loose.dll")

  // manifestPath = None: this is the auto-discovery path, not an explicit
  // --manifest — `loose.l` is never listed in any `[project.packages]`.
  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitCode, 0, "single-file build resolves the nearby manifest's path dependency")
  assertTrue(File.fileExists(outPath), "output DLL is produced")
}

test "buildOneNative: single-file build near a manifest fails loudly on an unbuilt path dependency" {
  val depDir = freshTempDir("dep-unbuilt")
  defer {
    cleanup(depDir)
  }
  // The dependency is a well-formed, buildable package (it has its own
  // lyric.toml) — it has just never been built, so no bin/DepD122b.dll
  // exists yet.  This exercises `Release.localDepNotBuiltMessage`'s branch
  // specifically, distinct from the "no lyric.toml at all" branch.
  writeManifestOrPanic(
    Path.join(depDir, "lyric.toml"),
    "[package]\n" + "name = \"DepD122b\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"DepD122bProj\"\n" +
      "output_assembly = \"DepD122b.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"DepD122b\" = \"dep.l\"\n"
  )
  val depSrcPath = Path.join(depDir, "dep.l")
  writeFileOrPanic(depSrcPath, "package DepD122b\n\npub func greet(name: String): String {\n  \"hi \" + name\n}\n")

  val appDir = freshTempDir("app-unbuilt")
  defer {
    cleanup(appDir)
  }
  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppD122b\"\n" + "version = \"0.1.0\"\n" + "\n" + "[dependencies]\n" +
      "DepD122b = { path = \"" +
      depDir +
      "\" }\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(
    looseSrcPath,
    "package AppD122b.Loose\n\nimport DepD122b\n\npub func run(): String {\n  greet(\"world\")\n}\n"
  )
  val outPath = Path.join(appDir, "loose.dll")

  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Dotnet, None, "", "")
  assertTrue(exitCode != 0, "single-file build fails loudly instead of silently ignoring the unbuilt dependency")
}

// Regression for a review finding on this PR: `emitSingleFileOrProject`
// originally checked `resolvedDeps.hadUnbuiltLocalDep` but never
// `resolvedDeps.hadWorkspaceError`, so a manifest declaring a broken
// `{ workspace = true }` dependency (unlike a `path` dependency, this
// resolves purely from the workspace member index — no DLL-existence
// check) fell through to a silent, dependency-less compile instead of
// failing loud like `buildProject` already does for the same condition.
// `MissingMember` is deliberately never a workspace member, so
// `Ws.resolveDep` returns `None` and `buildWorkspaceDeps` reports
// `hadError = true` purely from manifest resolution — no real package
// build is attempted, keeping this deterministic and fast.
test "buildOneNative: single-file build near a manifest fails loudly on a broken workspace dependency" {
  val wsRoot = freshTempDir("ws-broken")
  defer {
    cleanup(wsRoot)
  }
  writeManifestOrPanic(Path.join(wsRoot, "lyric.toml"), "[workspace]\n")

  val appDir = Path.join(wsRoot, "app")
  match File.createDir(appDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create app dir " + appDir + ": " + IOError.message(e))
  }
  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppD122Ws\"\n" + "version = \"0.1.0\"\n" + "\n" + "[dependencies]\n" +
      "MissingMember = { workspace = true }\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(looseSrcPath, "package AppD122Ws.Loose\n\npub func run(): Int {\n  1\n}\n")
  val outPath = Path.join(appDir, "loose.dll")

  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Dotnet, None, "", "")
  assertTrue(
    exitCode != 0,
    "single-file build fails loudly on a broken workspace dependency instead of silently compiling without it"
  )
}

test "buildOneNative: a manifest with no dependencies/features near a single file is byte-identical to no manifest" {
  val noManifestDir = freshTempDir("nomanifest")
  defer {
    cleanup(noManifestDir)
  }
  val srcA = Path.join(noManifestDir, "plain.l")
  writeFileOrPanic(srcA, "package PlainD122\n\nfunc main(): Unit {\n  println(1)\n}\n")
  val outA = Path.join(noManifestDir, "plain.dll")
  val exitA = Cli.buildOneNative(srcA, outA, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitA, 0, "no-manifest fixture compiles cleanly")

  val bareManifestDir = freshTempDir("baremanifest")
  defer {
    cleanup(bareManifestDir)
  }
  writeManifestOrPanic(
    Path.join(bareManifestDir, "lyric.toml"),
    "[package]\n" + "name = \"BareManifestD122\"\n" + "version = \"0.1.0\"\n"
  )
  val srcB = Path.join(bareManifestDir, "plain.l")
  writeFileOrPanic(srcB, "package PlainD122\n\nfunc main(): Unit {\n  println(1)\n}\n")
  val outB = Path.join(bareManifestDir, "plain.dll")
  val exitB = Cli.buildOneNative(srcB, outB, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitB, 0, "bare-manifest fixture compiles cleanly")

  val bytesA = match File.readBytes(outA) {
    case Ok(b) -> b
    case Err(e) -> panic("cannot read " + outA + ": " + IOError.message(e))
  }
  val bytesB = match File.readBytes(outB) {
    case Ok(b) -> b
    case Err(e) -> panic("cannot read " + outB + ": " + IOError.message(e))
  }
  assertTrue(
    bytesEqual(bytesA, bytesB),
    "a manifest with nothing dependency/feature-relevant does not change the compiled output (byte-for-byte)"
  )
}
