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
  assertTrue(Str.contains(msg, "--release-from-dll"), "warning still names the flag with no positional args, got: " + msg)
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

  cleanup(dir)
}

test "buildOneNative: a library (no main) does NOT colocate Lyric.Stdlib.dll beside the output" {
  val dir = freshTempDir("lib")
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

  cleanup(dir)
}
