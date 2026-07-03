//! llvm_stdlib_self_test.l — end-to-end self-test for N5's stdlib
//! native kernels: real programs importing `Std.File`, `Std.Environment`,
//! `Std.Process`, and `Std.Time` compile through the full bridge
//! pipeline (`Lyric.LlvmBridge.compileToNativeWithFlags` with the
//! `_kernel_native/` twins loaded, exactly like `lyric build --target
//! native`) and run with their runtime behaviour asserted via exit
//! codes.  Every binary builds with `-fsanitize=address`, so a kernel
//! seam that under- or over-releases an out-param string fails the run.
//!
//! Also pins the two codegen fixes that unblocked the seams:
//! `Result[Unit, E]` (Unit-typed union payload fields) and diverging
//! (`panic`) branches in value-position `if`.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_stdlib_self_test.l
@test_module
package Lyric.LlvmStdlibSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Uuid as Uuid
import Lyric.Emitter
import Lyric.LlvmBridge

// ─────────────────────────────────────────────────────────────────────────────
// Harness.
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

record RunOutcome {
  exitCode: Int
  stdout: String
}

func compileAndRunNative(source: in String): RunOutcome {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-stdlib-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val flags: List[String] = newList()
  flags.add("-fsanitize=address")
  if not compileToNativeWithFlags(source, stem, stdlib, "", "0", flags) {
    panic("native compilation failed for a stdlib self-test program")
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "Std.File seams: round-trip, classification, idempotent delete (ASan)" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Errors\n" + "import Std.File\n" + "func main(): Int {\n" +
    "  val base = \"" +
    tempBase() +
    "/lyric-n59-file\"\n" +
    "  val nested = base + \"/a/b\"\n" +
    "  match createDir(nested) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 1\n" +
    "    }\n" +
    "  }\n" +
    "  if not dirExists(nested) {\n" +
    "    return 2\n" +
    "  }\n" +
    "  val path = nested + \"/probe.txt\"\n" +
    "  match writeText(path, \"native-io\") {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 3\n" +
    "    }\n" +
    "  }\n" +
    "  if not fileExists(path) {\n" +
    "    return 4\n" +
    "  }\n" +
    "  var text = \"\"\n" +
    "  match readText(path) {\n" +
    "    case Ok(t) -> {\n" +
    "      text = t\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 5\n" +
    "    }\n" +
    "  }\n" +
    "  if text != \"native-io\" {\n" +
    "    return 6\n" +
    "  }\n" +
    "  match deleteFile(path) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 7\n" +
    "    }\n" +
    "  }\n" +
    "  if fileExists(path) {\n" +
    "    return 8\n" +
    "  }\n" +
    "  var missingKind = 0\n" +
    "  match readText(path) {\n" +
    "    case Ok(_) -> {\n" +
    "      missingKind = 1\n" +
    "    }\n" +
    "    case Err(e) -> {\n" +
    "      match e {\n" +
    "        case FileNotFound(_) -> {\n" +
    "          missingKind = 2\n" +
    "        }\n" +
    "        case _ -> {\n" +
    "          missingKind = 3\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  if missingKind != 2 {\n" +
    "    return 9\n" +
    "  }\n" +
    "  match deleteFile(path) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 10\n" +
    "    }\n" +
    "  }\n" +
    "  match deleteFile(nested) {\n" +
    "    case Ok(_) -> {\n" +
    "      return 11\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "file seams")
}

test "Std.Environment seams: set/get, missing key, cwd (ASan)" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Errors\n" + "import Std.Environment\n" +
    "func main(): Int {\n" +
    "  setVar(\"LYRIC_N59_ENV\", \"forty-two\")\n" +
    "  var got = \"\"\n" +
    "  match getVar(\"LYRIC_N59_ENV\") {\n" +
    "    case Ok(v) -> {\n" +
    "      got = v\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 1\n" +
    "    }\n" +
    "  }\n" +
    "  if got != \"forty-two\" {\n" +
    "    return 2\n" +
    "  }\n" +
    "  var missingKind = 0\n" +
    "  match getVar(\"LYRIC_N59_MISSING_UNIQUE\") {\n" +
    "    case Ok(_) -> {\n" +
    "      missingKind = 1\n" +
    "    }\n" +
    "    case Err(e) -> {\n" +
    "      match e {\n" +
    "        case KeyNotFound(_) -> {\n" +
    "          missingKind = 2\n" +
    "        }\n" +
    "        case _ -> {\n" +
    "          missingKind = 3\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  if missingKind != 2 {\n" +
    "    return 3\n" +
    "  }\n" +
    "  val cwd = currentDirectory()\n" +
    "  if cwd.length == 0 {\n" +
    "    return 4\n" +
    "  }\n" +
    "  if getVarOrDefault(\"LYRIC_N59_MISSING_UNIQUE\", \"fallback\") != \"fallback\" {\n" +
    "    return 5\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "environment seams")
}

test "Std.Process capture: argv passthrough, exec failure, stdin deferral (ASan)" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Process\n" +
    "func main(): Int {\n" +
    "  val args: List[String] = newList()\n" +
    "  args.add(\"hello\")\n" +
    "  args.add(\"world\")\n" +
    "  match runCapture(\"/bin/echo\", args, 5000) {\n" +
    "    case Ok(res) -> {\n" +
    "      if res.exitCode != 0 {\n" +
    "        return 1\n" +
    "      }\n" +
    "      if res.stdout != \"hello world\\n\" {\n" +
    "        return 2\n" +
    "      }\n" +
    "      if res.timedOut {\n" +
    "        return 3\n" +
    "      }\n" +
    "      if res.stderr != \"\" {\n" +
    "        return 4\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 5\n" +
    "    }\n" +
    "  }\n" +
    "  val noArgs: List[String] = newList()\n" +
    "  match runCapture(\"/definitely-missing-lyric-n59\", noArgs, 5000) {\n" +
    "    case Ok(res2) -> {\n" +
    "      if res2.exitCode != 127 {\n" +
    "        return 6\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 7\n" +
    "    }\n" +
    "  }\n" +
    "  var stdinRejected = false\n" +
    "  match runCaptureWithInput(\"/bin/cat\", noArgs, \"some input\", 5000) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      stdinRejected = true\n" +
    "    }\n" +
    "  }\n" +
    "  if not stdinRejected {\n" +
    "    return 8\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "process capture seams")
}

test "Std.Time seams: epoch, monotonic, sleep (ASan)" {
  val src = "package T\n" + "import Std.Time\n" + "func main(): Int {\n" + "  val t0 = nowEpochMillis()\n" +
    "  if t0 < 1500000000000i64 {\n" +
    "    return 1\n" +
    "  }\n" +
    "  val m0 = monotonicNanos()\n" +
    "  sleepMillis(15)\n" +
    "  val m1 = monotonicNanos()\n" +
    "  if m1 - m0 < 10000000i64 {\n" +
    "    return 2\n" +
    "  }\n" +
    "  val t1 = nowEpochMillis()\n" +
    "  if t1 < t0 {\n" +
    "    return 3\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "clock seams")
}

test "Result[Unit, E] payloads and diverging value-if branches (ASan)" {
  val src = "package T\n" + "import Std.Core\n" + "func mk(flag: Int): Result[Unit, String] {\n" + "  if flag == 0 {\n" +
    "    Ok(value = ())\n" +
    "  } else {\n" +
    "    Err(error = \"boom\")\n" +
    "  }\n" +
    "}\n" +
    "func pick(flag: Int): String {\n" +
    "  if flag == 1 {\n" +
    "    \"chosen\"\n" +
    "  } else {\n" +
    "    panic(\"diverging branch must not run\")\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var score = 0\n" +
    "  match mk(0) {\n" +
    "    case Ok(_) -> {\n" +
    "      score = score + 1\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      score = score + 100\n" +
    "    }\n" +
    "  }\n" +
    "  match mk(1) {\n" +
    "    case Ok(_) -> {\n" +
    "      score = score + 100\n" +
    "    }\n" +
    "    case Err(msg) -> {\n" +
    "      if msg == \"boom\" {\n" +
    "        score = score + 2\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  if pick(1) == \"chosen\" {\n" +
    "    score = score + 39\n" +
    "  }\n" +
    "  score\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Unit payloads + diverging branches: 1+2+39")
}
