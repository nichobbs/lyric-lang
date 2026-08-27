//! jvm_sourcefile_attr_self_test.l — regression coverage for docs/63 §9.7
//! slice 2 (issue #6284): the self-hosted JVM backend now emits a real
//! JVMS §4.7.10 `SourceFile` attribute naming the real on-disk source file,
//! for both the plain single-file build path (`lyric build <file>.l
//! --target jvm`) and the manifest single-package-project path (the common
//! shape: most `[project.packages]` entries name exactly one file).
//! `Jvm.Classfile.makeSourceFileAttr` existed with zero call sites before
//! this fix; `scripts/assert-jvm-line-numbers.sh` covers the same mechanism
//! against a more elaborate (aspect-woven, contract-elaborated) fixture.
//!
//! Spawns the real, just-built `./bin/lyric` to produce a JAR, then shells
//! out to `javap -v` (already a hard CI dependency for every JVM self-test
//! that runs the produced JAR under `java`) to read the attribute back —
//! mirroring `scripts/assert-jvm-line-numbers.sh`'s own technique.
//!
//! Assumes CWD is the repo root (see source_path_diagnostics_self_test.l).
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/jvm_sourcefile_attr_self_test.l
@test_module
package Lyric.JvmSourcefileAttrSelfTest

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

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvmsf-" + label + "-" + uuidToString(newUuid()))
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

func lyricBinPath(): String {
  Path.join(Environment.currentDirectory(), "bin/lyric")
}

// Extract `entryClassName.class` from `jarPath` into `extractDir` and
// return `javap -v`'s output for it, or "" on any failure (the caller
// asserts on emptiness so a missing tool surfaces as a clear failure
// message rather than a silent pass).
func javapVerboseForEntry(jarPath: in String, extractDir: in String, entryClassName: in String): String {
  match File.createDir(extractDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  val unzipArgs: List[String] = newList()
  unzipArgs.add("-o")
  unzipArgs.add(jarPath)
  unzipArgs.add(entryClassName + ".class")
  unzipArgs.add("-d")
  unzipArgs.add(extractDir)
  val unzipResult = Capture.runCaptureWithDiagnostics("unzip", unzipArgs, "")
  if unzipResult.exitCode != 0 {
    return ""
  }
  val classFile = Path.join(extractDir, entryClassName + ".class")
  val javapArgs: List[String] = newList()
  javapArgs.add("-v")
  javapArgs.add("-p")
  javapArgs.add(classFile)
  val javapResult = Capture.runCaptureWithDiagnostics("javap", javapArgs, "")
  if javapResult.exitCode != 0 {
    return ""
  }
  javapResult.stdout
}

// The `SourceFile: "..."` line's quoted payload, or "" if absent.
func extractSourceFileName(javapOutput: in String): String {
  val lines = Str.split(javapOutput, "\n")
  var i = 0
  while i < lines.length {
    val line = Str.trim(lines[i])
    if Str.startsWith(line, "SourceFile:") {
      val q1 = Str.indexOfRaw(line, "\"")
      if q1 >= 0 {
        val rest = line.substring(q1 + 1, line.length - q1 - 1)
        val q2 = Str.indexOfRaw(rest, "\"")
        if q2 >= 0 {
          return rest.substring(0, q2)
        }
      }
    }
    i = i + 1
  }
  ""
}

test "single-file jvm build: the entry class carries a SourceFile attribute naming the real path" {
  val dir = freshTempDir("plain")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "hello.l")
  match File.writeText(srcPath, "package SfPlain\nimport Std.Core\n\nfunc main(): Unit {\n  println(\"hi\")\n}\n") {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val jarPath = Path.join(dir, "hello.jar")
  val args: List[String] = newList()
  args.add("build")
  args.add(srcPath)
  args.add("--target")
  args.add("jvm")
  args.add("-o")
  args.add(jarPath)
  val buildResult = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertEqualInt(buildResult.exitCode, 0, "jvm build must succeed (stderr=" + buildResult.stderr + ")")

  val javapOut = javapVerboseForEntry(jarPath, Path.join(dir, "extracted"), "SfPlain")
  assertTrue(javapOut.length > 0, "javap produced no output — is 'unzip'/'javap' on PATH?")
  // #6608: JVMS §4.7.10 requires a bare file name, never a directory/path.
  assertEqual(
    extractSourceFileName(javapOut),
    Path.basename(srcPath),
    "SourceFile must name the bare source file name, not the absolute path"
  )
}

test "manifest single-package jvm build: the entry class carries a SourceFile attribute naming the real path" {
  val dir = freshTempDir("proj")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "lines.l")
  match File.writeText(srcPath, "package SfProj\nimport Std.Core\n\nfunc main(): Unit {\n  println(\"hi\")\n}\n") {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"SfProj\"\n" + "version = \"0.0.1\"\n" + "\n" + "[project]\n" +
    "name = \"SfProj\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"SfProj\" = \"lines.l\"\n" +
    "\n" +
    "[dependencies]\n" +
    "Std = \"*\"\n"
  val mfPath = Path.join(dir, "lyric.toml")
  match File.writeText(mfPath, manifest) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write lyric.toml: " + IOError.message(e))
  }
  val jarPath = Path.join(dir, "out.jar")
  val args: List[String] = newList()
  args.add("build")
  args.add("--manifest")
  args.add(mfPath)
  args.add("--target")
  args.add("jvm")
  args.add("-o")
  args.add(jarPath)
  val buildResult = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertEqualInt(buildResult.exitCode, 0, "jvm manifest build must succeed (stderr=" + buildResult.stderr + ")")

  val javapOut = javapVerboseForEntry(jarPath, Path.join(dir, "extracted"), "SfProj")
  assertTrue(javapOut.length > 0, "javap produced no output — is 'unzip'/'javap' on PATH?")
  // #6608: JVMS §4.7.10 requires a bare file name, never a directory/path.
  assertEqual(
    extractSourceFileName(javapOut),
    Path.basename(srcPath),
    "SourceFile must name the bare source file name, not the absolute path"
  )
}
