//! llvm_stdlib_self_test.l — end-to-end self-test for N5's stdlib
//! native kernels: real programs importing `Std.File`, `Std.Environment`,
//! `Std.Process`, `Std.Time`, and `Std.Uuid` compile through the full bridge
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

test "Std.Process capture: argv passthrough, exec failure, stdin round-trip (ASan)" {
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
    "  match runCaptureWithInput(\"/bin/cat\", noArgs, \"some input\", 5000) {\n" +
    "    case Ok(res3) -> {\n" +
    "      if res3.stdout != \"some input\" or res3.exitCode != 0 or res3.timedOut {\n" +
    "        return 8\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 9\n" +
    "    }\n" +
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

test "Std.Uuid seams: v4 generation, formatting, four parse forms (ASan)" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Uuid\n" + "func main(): Int {\n" +
    "  val a = uuidToString(newUuid())\n" +
    "  val b = uuidToString(newUuid())\n" +
    "  if a.length != 36 or b.length != 36 {\n    return 1\n  }\n" +
    "  if a == b {\n    return 2\n  }\n" +
    "  if a.substring(8, 1) != \"-\" or a.substring(13, 1) != \"-\" or a.substring(18, 1) != \"-\" or a.substring(23, 1) != \"-\" {\n    return 3\n  }\n" +
    "  if a.substring(14, 1) != \"4\" {\n    return 4\n  }\n" +
    "  val variant = a.substring(19, 1)\n" +
    "  if variant != \"8\" and variant != \"9\" and variant != \"a\" and variant != \"b\" {\n    return 5\n  }\n" +
    "  if uuidToString(nilUuid()) != \"00000000-0000-0000-0000-000000000000\" {\n    return 6\n  }\n" +
    "  match parseUuidOpt(a) {\n" +
    "    case Some(u) -> {\n      if uuidToString(u) != a {\n        return 7\n      }\n    }\n" +
    "    case None -> {\n      return 8\n    }\n" +
    "  }\n" +
    "  val d = \"550e8400-e29b-41d4-a716-446655440000\"\n" +
    "  match parseUuidOpt(\"{550E8400-E29B-41D4-A716-446655440000}\") {\n" +
    "    case Some(u2) -> {\n      if uuidToString(u2) != d {\n        return 9\n      }\n    }\n" +
    "    case None -> {\n      return 10\n    }\n" +
    "  }\n" +
    "  match parseUuidOpt(\"550e8400e29b41d4a716446655440000\") {\n" +
    "    case Some(u3) -> {\n      if uuidToString(u3) != d {\n        return 11\n      }\n    }\n" +
    "    case None -> {\n      return 12\n    }\n" +
    "  }\n" +
    "  match parseUuidOpt(\"(\" + d + \")\") {\n" +
    "    case Some(_) -> {\n    }\n" +
    "    case None -> {\n      return 13\n    }\n" +
    "  }\n" +
    "  match parseUuidOpt(\"not-a-uuid\") {\n" +
    "    case Some(_) -> {\n      return 14\n    }\n" +
    "    case None -> {\n    }\n" +
    "  }\n" +
    "  match parseUuidOpt(\"550e8400-e29b-41d4-a716\") {\n" +
    "    case Some(_) -> {\n      return 15\n    }\n" +
    "    case None -> {\n    }\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "uuid seams")
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

test "slice[T] via the list repr: bytes round-trip, listFiles, args (ASan)" {
  val src = "package T\n" + "\n" + "import Std.Core\n" + "import Std.Errors\n" + "import Std.Collections\n" +
    "import Std.File\n" +
    "import Std.Environment\n" +
    "\n" +
    "func main(): Int {\n" +
    "  val base = \"" +
    tempBase() +
    "/lyric-n5s\"\n" +
    "  match createDir(base) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 1\n" +
    "    }\n" +
    "  }\n" +
    "  val path = base + \"/bytes.bin\"\n" +
    "  val payload: List[Byte] = newList()\n" +
    "  payload.add(104)\n" +
    "  payload.add(0)\n" +
    "  payload.add(105)\n" +
    "  match writeBytes(path, payload) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 2\n" +
    "    }\n" +
    "  }\n" +
    "  var total = 0\n" +
    "  match readBytes(path) {\n" +
    "    case Ok(got) -> {\n" +
    "      if got.count != 3 {\n" +
    "        return 3\n" +
    "      }\n" +
    "      for b in got {\n" +
    "        total = total + b.toInt()\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 4\n" +
    "    }\n" +
    "  }\n" +
    "  if total != 209 {\n" +
    "    return 5\n" +
    "  }\n" +
    "  var seen = 0\n" +
    "  match listFiles(base) {\n" +
    "    case Ok(files) -> {\n" +
    "      for f in files {\n" +
    "        if f == path {\n" +
    "          seen = seen + 1\n" +
    "        }\n" +
    "        val n = f.length\n" +
    "        if n < 1 {\n" +
    "          return 6\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 7\n" +
    "    }\n" +
    "  }\n" +
    "  if seen != 1 {\n" +
    "    return 8\n" +
    "  }\n" +
    "  val argv = args()\n" +
    "  if argv.length < 1 {\n" +
    "    return 9\n" +
    "  }\n" +
    "  val a0 = argv[0]\n" +
    "  if a0.length < 1 {\n" +
    "    return 10\n" +
    "  }\n" +
    "  match deleteFile(path) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 11\n" +
    "    }\n" +
    "  }\n" +
    "  match deleteDirRecursive(base) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 12\n" +
    "    }\n" +
    "  }\n" +
    "  if dirExists(base) {\n" +
    "    return 13\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "slice seams: bytes + enumeration + args")
}

test "toArray snapshot + listFilesRecursive on native (ASan)" {
  val src = "package T\n" + "\n" + "import Std.Core\n" + "import Std.Errors\n" + "import Std.Collections\n" +
    "import Std.File\n" +
    "\n" +
    "func main(): Int {\n" +
    "  val base = \"" +
    tempBase() +
    "/lyric-n5s2\"\n" +
    "  val nested = base + \"/inner\"\n" +
    "  match createDir(nested) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 1\n" +
    "    }\n" +
    "  }\n" +
    "  match writeText(base + \"/a.txt\", \"A\") {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 2\n" +
    "    }\n" +
    "  }\n" +
    "  match writeText(nested + \"/b.txt\", \"B\") {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 3\n" +
    "    }\n" +
    "  }\n" +
    "  var found = 0\n" +
    "  match listFilesRecursive(base) {\n" +
    "    case Ok(all) -> {\n" +
    "      for f in all {\n" +
    "        found = found + 1\n" +
    "        val n = f.length\n" +
    "        if n < 1 {\n" +
    "          return 4\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 5\n" +
    "    }\n" +
    "  }\n" +
    "  if found != 2 {\n" +
    "    return 6\n" +
    "  }\n" +
    "  var dcount = 0\n" +
    "  var sawInner = false\n" +
    "  match listDirs(base) {\n" +
    "    case Ok(dirs) -> {\n" +
    "      for d in dirs {\n" +
    "        dcount = dcount + 1\n" +
    "        if d == nested {\n" +
    "          sawInner = true\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 11\n" +
    "    }\n" +
    "  }\n" +
    "  if dcount != 1 or not sawInner {\n" +
    "    return 12\n" +
    "  }\n" +
    "  val xs: List[Int] = newList()\n" +
    "  xs.add(20)\n" +
    "  xs.add(22)\n" +
    "  val snap = xs.toArray()\n" +
    "  xs.set(0, 999)\n" +
    "  var sum = 0\n" +
    "  for v in snap {\n" +
    "    sum = sum + v\n" +
    "  }\n" +
    "  if sum != 42 {\n" +
    "    return 7\n" +
    "  }\n" +
    "  match deleteDirRecursive(base) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 8\n" +
    "    }\n" +
    "  }\n" +
    "  if dirExists(base) or fileExists(base + \"/a.txt\") {\n" +
    "    return 9\n" +
    "  }\n" +
    "  match deleteDirRecursive(base) {\n" +
    "    case Ok(_) -> {\n" +
    "      return 10\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "toArray snapshot + recursive traversal + cleanup")
}

test "recursive delete does not traverse a directory symlink (#4833, ASan)" {
  val src = "package T\n" + "\n" + "import Std.Core\n" + "import Std.Errors\n" + "import Std.File\n" +
    "import Std.Process\n" +
    "\n" +
    "func main(): Int {\n" +
    "  val outside = \"" +
    tempBase() +
    "/lyric-n5s-outside\"\n" +
    "  val tree = \"" +
    tempBase() +
    "/lyric-n5s-tree\"\n" +
    "  val _c1 = deleteDirRecursive(outside)\n" +
    "  val _c2 = deleteDirRecursive(tree)\n" +
    "  match createDir(outside) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 1\n" +
    "    }\n" +
    "  }\n" +
    "  match writeText(outside + \"/keep.txt\", \"KEEP\") {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 2\n" +
    "    }\n" +
    "  }\n" +
    "  match createDir(tree) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 3\n" +
    "    }\n" +
    "  }\n" +
    "  match writeText(tree + \"/inner.txt\", \"I\") {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 4\n" +
    "    }\n" +
    "  }\n" +
    "  val argv: List[String] = newList()\n" +
    "  argv.add(\"-s\")\n" +
    "  argv.add(outside)\n" +
    "  argv.add(tree + \"/link\")\n" +
    "  match runCapture(\"ln\", argv, 5000) {\n" +
    "    case Ok(res) -> {\n" +
    "      if res.exitCode != 0 {\n" +
    "        return 5\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 6\n" +
    "    }\n" +
    "  }\n" +
    "  match deleteDirRecursive(tree) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 7\n" +
    "    }\n" +
    "  }\n" +
    "  if dirExists(tree) {\n" +
    "    return 8\n" +
    "  }\n" +
    "  if not dirExists(outside) {\n" +
    "    return 9\n" +
    "  }\n" +
    "  if not fileExists(outside + \"/keep.txt\") {\n" +
    "    return 10\n" +
    "  }\n" +
    "  val _c3 = deleteDirRecursive(outside)\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "directory symlink is unlinked, not traversed")
}
