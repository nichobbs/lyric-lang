//! cli_copydll_self_test.l — regression coverage for `Lyric.Cli.copyDllBeside`
//! (cli/cli_shared.l), the single-file primitive `copyRestoredDepDlls` /
//! `copyNugetAssembliesBeside` / `copyNugetNativeAssetsBeside` all reduce to
//! (#5078). Before this file, none of `copyDllBeside`'s three distinct
//! best-effort no-op branches (empty path, missing source, unreadable/write
//! failure) — nor the actual byte-for-byte copy — had a direct test; a
//! regression could only have surfaced indirectly through an end-to-end
//! `buildOneNative`/`buildProject` colocation test failing for an unrelated-
//! looking reason.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_copydll_self_test.l
@test_module
package Lyric.CliCopyDllSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Uuid
import Std.Testing
import Lyric.Cli as Cli

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-cli-copydll-" + label + "-" + uuidToString(newUuid()))
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

func readTextOrPanic(path: in String): String {
  match File.readText(path) {
    case Ok(t) -> t
    case Err(e) -> panic("cannot read " + path + ": " + IOError.message(e))
  }
}

test "copyDllBeside: a valid source DLL lands beside outPath" {
  val dir = freshTempDir("valid-copy")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "Fixture.Dep.dll")
  writeFileOrPanic(srcPath, "fixture dll bytes")
  val outPath = Path.join(dir, "App.dll")

  Cli.copyDllBeside(outPath, srcPath)

  val destPath = Path.join(dir, "Fixture.Dep.dll")
  assertTrue(File.fileExists(destPath), "copyDllBeside: the source DLL is copied beside outPath")
  // Same directory in this fixture, so destPath == srcPath — check content
  // round-trips through the read/write instead (a distinct-directory variant
  // follows below to prove it isn't merely a no-op self-copy).
  assertEqual(readTextOrPanic(destPath), "fixture dll bytes", "copyDllBeside: copied content matches the source")
}

test "copyDllBeside: copies into outPath's own directory, distinct from the source directory" {
  val srcDir = freshTempDir("valid-copy-src")
  defer {
    cleanup(srcDir)
  }
  val destDir = freshTempDir("valid-copy-dest")
  defer {
    cleanup(destDir)
  }
  val srcPath = Path.join(srcDir, "Dep.dll")
  writeFileOrPanic(srcPath, "dep bytes")
  val outPath = Path.join(destDir, "App.dll")

  Cli.copyDllBeside(outPath, srcPath)

  val destPath = Path.join(destDir, "Dep.dll")
  assertTrue(File.fileExists(destPath), "copyDllBeside: source DLL lands in outPath's directory, not its own")
  assertEqual(readTextOrPanic(destPath), "dep bytes", "copyDllBeside: copied content matches the source")
}

test "copyDllBeside: an empty dllPath is a no-op" {
  val dir = freshTempDir("empty-path")
  defer {
    cleanup(dir)
  }
  val outPath = Path.join(dir, "App.dll")

  Cli.copyDllBeside(outPath, "")

  match File.listFiles(dir) {
    case Ok(fs) -> assertEqualInt(fs.count, 0, "copyDllBeside: an empty dllPath copies nothing into outPath's directory")
    case Err(e) -> panic("cannot list " + dir + ": " + IOError.message(e))
  }
}

test "copyDllBeside: a missing source path is a no-op" {
  val dir = freshTempDir("missing-source")
  defer {
    cleanup(dir)
  }
  val outPath = Path.join(dir, "App.dll")
  val missingSrc = Path.join(dir, "DoesNotExist.dll")

  Cli.copyDllBeside(outPath, missingSrc)

  assertTrue(
    not File.fileExists(Path.join(dir, "DoesNotExist.dll")),
    "copyDllBeside: a nonexistent source path produces no destination file"
  )
}

test "copyDllBeside: overwrites an existing destination with the source's current bytes" {
  val srcDir = freshTempDir("overwrite-src")
  defer {
    cleanup(srcDir)
  }
  val destDir = freshTempDir("overwrite-dest")
  defer {
    cleanup(destDir)
  }
  // Source and destination are DIFFERENT directories sharing only the same
  // basename ("Dep.dll") — otherwise the pre-seeded "stale" destination file
  // below would silently overwrite the source fixture itself, since
  // copyDllBeside's destination is Path.dirname(outPath) + basename(srcPath).
  val srcPath = Path.join(srcDir, "Dep.dll")
  writeFileOrPanic(srcPath, "updated bytes")
  val outPath = Path.join(destDir, "App.dll")
  // A stale copy from a previous build, at the exact destination
  // copyDllBeside computes (Path.dirname(outPath) + basename(srcPath)).
  val destPath = Path.join(destDir, "Dep.dll")
  writeFileOrPanic(destPath, "stale bytes")

  Cli.copyDllBeside(outPath, srcPath)

  assertEqual(
    readTextOrPanic(destPath),
    "updated bytes",
    "copyDllBeside: an existing destination is overwritten with the source's current bytes, not left stale"
  )
}
