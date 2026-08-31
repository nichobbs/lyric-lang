//! llvm_codegen_self_test.l — end-to-end self-test for `Lyric.LlvmCodegen`
//! (N1.2–N1.7): parses small Lyric programs, lowers them to `.ll` via
//! `codegenNativePackage` + `lowerNativePackage`, compiles with clang against
//! `lyric-rt/build/lyric_rt.a`, runs the produced binary, and asserts
//! its exit code and stdout.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1 (the test
//! imports `Lyric.Llvm*` compiler packages):
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_codegen_self_test.l
@test_module
package Lyric.LlvmCodegenSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.String as Str
import Std.Uuid as Uuid
import Lyric.Parser
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.LlvmCodegen
import Lyric.LlvmLowering

// ─────────────────────────────────────────────────────────────────────────────
// Harness: compile source text to a native binary and run it.
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

// Walk up from the CWD to the repo root (identified by lyric-rt/) and
// return the runtime archive path, or "" when not found.
func findLyricRt(): String {
  var dir = Environment.currentDirectory()
  var hop = 0
  while hop < 32 {
    val candidate = Path.join(Path.join(Path.join(dir, "lyric-rt"), "build"), "lyric_rt.a")
    if File.fileExists(candidate) {
      return candidate
    }
    val parent = Path.dirname(dir)
    if parent.length == 0 or parent == dir {
      return ""
    }
    dir = parent
    hop = hop + 1
  }
  ""
}

record RunOutcome {
  exitCode: Int
  stdout: String
}

/// Parse, lower, clang-compile, and run `source`; panics (failing the
/// test) on any stage error so assertion sites stay simple.  `sanitize`
/// links `-fsanitize=address` for ARC-sensitive cases (a leaked, over-, or
/// under-released heap value fails the run) — see `compileAndRun` /
/// `compileAndRunAsan` below.
func compileAndRunWith(source: in String, sanitize: in Bool): RunOutcome {
  val pr = parse(source)
  if pr.diagnostics.count > 0 {
    var msg = "test source has parse diagnostics:"
    var i = 0
    while i < pr.diagnostics.count {
      msg = msg + " " + pr.diagnostics[i].code
      i = i + 1
    }
    panic(msg)
  }
  val pkg = codegenNativePackage(pr.file, "")
  val ll = lowerNativePackage(pkg)
  val rt = findLyricRt()
  if rt.length == 0 {
    panic("lyric_rt.a not found; run `make -C lyric-rt` first")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val llPath = stem + ".ll"
  match File.writeText(llPath, ll) {
    case Ok(_) -> {
    }
    case Err(_) -> panic("cannot write " + llPath)
  }
  val clangArgs: List[String] = newList()
  clangArgs.add("-O0")
  if sanitize {
    clangArgs.add("-fsanitize=address")
  }
  clangArgs.add(llPath)
  clangArgs.add(rt)
  clangArgs.add("-lm")
  clangArgs.add("-lpthread")
  clangArgs.add("-o")
  clangArgs.add(stem)
  match Process.runCapture("clang", clangArgs, 120000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        panic("clang failed on " + llPath + ": " + res.stderr)
      }
    }
    case Err(e) -> panic("clang could not be started: " + e)
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

func compileAndRun(source: in String): RunOutcome {
  compileAndRunWith(source, false)
}

func compileAndRunAsan(source: in String): RunOutcome {
  compileAndRunWith(source, true)
}

// Compile + run a multi-package bundle (units[0] is the entry package) through
// `codegenNativeBundle`, exercising the cross-package resolution path the
// single-unit `codegenNativePackage` never reaches (#6225).
func compileAndRunBundle(sources: in List[String]): RunOutcome {
  val units: List[CodegenUnit] = newList()
  var si = 0
  while si < sources.count {
    val pr = parse(sources[si])
    if pr.diagnostics.count > 0 {
      panic("bundle test source has parse diagnostics")
    }
    units.add(unitOfFile(dottedPkgName(pr.file), pr.file))
    si = si + 1
  }
  val pkg = codegenNativeBundle(units, "")
  val ll = lowerNativePackage(pkg)
  val rt = findLyricRt()
  if rt.length == 0 {
    panic("lyric_rt.a not found; run `make -C lyric-rt` first")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "b_" + uuidToString(newUuid()))
  val llPath = stem + ".ll"
  match File.writeText(llPath, ll) {
    case Ok(_) -> {
    }
    case Err(_) -> panic("cannot write " + llPath)
  }
  val clangArgs: List[String] = newList()
  clangArgs.add("-O0")
  clangArgs.add(llPath)
  clangArgs.add(rt)
  clangArgs.add("-lm")
  clangArgs.add("-lpthread")
  clangArgs.add("-o")
  clangArgs.add(stem)
  match Process.runCapture("clang", clangArgs, 120000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        panic("clang failed on " + llPath + ": " + res.stderr)
      }
    }
    case Err(e) -> panic("clang could not be started: " + e)
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cases.
// ─────────────────────────────────────────────────────────────────────────────
test "exit code from main" {
  val r = compileAndRun("package T\nfunc main(): Int {\n  42\n}\n")
  assertEqualInt(r.exitCode, 42, "main(): Int exit code")
}

// ── module-level val / const references (inlined at use sites, #5977 part 2) ──
test "module-level Int val reference" {
  val r = compileAndRun("package T\nval N: Int = 42\nfunc main(): Int {\n  N\n}\n")
  assertEqualInt(r.exitCode, 42, "module val N inlined")
}

test "module-level String val (the @build_const shape) referenced by length" {
  val r = compileAndRun("package T\nval GREETING: String = \"hello\"\nfunc main(): Int {\n  GREETING.length\n}\n")
  assertEqualInt(r.exitCode, 5, "module String val inlined, .length = 5")
}

test "module-level val with inferred type" {
  val r = compileAndRun("package T\nval TAG = \"hi\"\nfunc main(): Int {\n  TAG.length\n}\n")
  assertEqualInt(r.exitCode, 2, "untyped module val inlined, .length = 2")
}

test "module-level val referenced multiple times" {
  val r = compileAndRun("package T\nval K: Int = 5\nfunc main(): Int {\n  K + K + K\n}\n")
  assertEqualInt(r.exitCode, 15, "module val inlined per use")
}

test "module-level val negated-literal initializer" {
  val r = compileAndRun("package T\nval MIN: Int = -1\nfunc main(): Int {\n  MIN + 43\n}\n")
  assertEqualInt(r.exitCode, 42, "negated-literal module val inlined: -1 + 43")
}

test "cross-package same-named module vals resolve per package (#6225)" {
  // Two packages both declare `val TAG`; each package's own function must read
  // its OWN value. A(TAG)=10, B(TAG)=20 -> main = B.TAG + A.fromA() = 20 + 10.
  // The pre-fix bare-name-only map would inline units[0]'s TAG (20) into A's
  // reference too, giving 40.
  val depA = "package A\nval TAG: Int = 10\npub func fromA(): Int {\n  TAG\n}\n"
  val mainB = "package B\nval TAG: Int = 20\nfunc main(): Int {\n  TAG + fromA()\n}\n"
  val sources: List[String] = newList()
  sources.add(mainB)
  sources.add(depA)
  val r = compileAndRunBundle(sources)
  assertEqualInt(r.exitCode, 30, "each package reads its own TAG: 20 + 10")
}

test "cross-package module val via the bare-name fallback (no collision)" {
  // B references a name only A declares (no B.ONLY_A), so the self-package
  // qualified lookup misses and the bare-name fallback resolves it to A's val.
  val depA = "package A\nval ONLY_A: Int = 7\n"
  val mainB = "package B\nfunc main(): Int {\n  ONLY_A\n}\n"
  val sources: List[String] = newList()
  sources.add(mainB)
  sources.add(depA)
  val r = compileAndRunBundle(sources)
  assertEqualInt(r.exitCode, 7, "bare-name fallback resolves B's ONLY_A ref to A's val")
}

test "integer arithmetic" {
  // The result binds to a local first: a trailing line that begins with
  // '(' would otherwise continue the previous statement as a call.
  val src = "package T\n" + "func main(): Int {\n" + "  val a = 7\n" + "  val b = 3\n" +
    "  val r = (a + b) * 2 - a / b - a % b + 1\n" +
    "  r\n" +
    "}\n"
  // (7+3)*2 - 2 - 1 + 1 = 18
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 18, "int arithmetic")
}

test "comparisons and booleans" {
  val src = "package T\n" + "func main(): Int {\n" +
    "  val t = 3 < 5 and 5 <= 5 and 7 > 2 and 2 >= 2 and 1 == 1 and 1 != 2\n" +
    "  val f = not t\n" +
    "  if t and not f {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 0, "comparison chain")
}

test "short-circuit evaluation skips rhs" {
  // Module-level vars are unsupported; use a helper returning a marker
  // exit code instead: rhs would panic if evaluated.
  val src2 = "package T\n" + "func boom(): Bool {\n" + "  panic(\"rhs evaluated\")\n" + "  true\n" + "}\n" +
    "func main(): Int {\n" +
    "  val a = false and boom()\n" +
    "  val b = true or boom()\n" +
    "  if not a and b {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src2)
  assertEqualInt(r.exitCode, 0, "short circuit")
}

test "while loop with break and continue" {
  val src = "package T\n" + "func main(): Int {\n" + "  var sum = 0\n" + "  var i = 0\n" + "  while true {\n" +
    "    i = i + 1\n" +
    "    if i > 10 {\n" +
    "      break\n" +
    "    }\n" +
    "    if i % 2 == 0 {\n" +
    "      continue\n" +
    "    }\n" +
    "    sum = sum + i\n" +
    "  }\n" +
    "  sum\n" +
    "}\n"
  // 1+3+5+7+9 = 25
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 25, "while/break/continue")
}

test "functions call each other" {
  val src = "package T\n" + "func add(a: in Int, b: in Int): Int {\n" + "  a + b\n" + "}\n" +
    "func twice(x: in Int): Int {\n" +
    "  add(x, x)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  twice(add(3, 4))\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 14, "nested calls")
}

test "recursion" {
  val src = "package T\n" + "func fib(n: in Int): Int {\n" + "  if n < 2 {\n" + "    n\n" + "  } else {\n" +
    "    fib(n - 1) + fib(n - 2)\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  fib(10)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 55, "fib(10)")
}

test "long arithmetic and conversions" {
  val src = "package T\n" + "func main(): Int {\n" + "  val big: Long = 1i64.shl(40)\n" +
    "  val back = (big / 1099511627776i64).toInt()\n" +
    "  val f = 2.toFloat() * 2.5\n" +
    "  val fi = f.toInt()\n" +
    "  back + fi\n" +
    "}\n"
  // 1 + 5 = 6
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 6, "long/float conversions")
}

test "bitwise methods" {
  val src = "package T\n" + "func main(): Int {\n" + "  val a = 5.xor(3).and(6).or(8)\n" + "  val b = 1.shl(4)\n" +
    "  val c = -8 / 2\n" +
    "  a + b + 0 - c\n" +
    "}\n"
  // (5^3)&6|8 = 14; 16; -(-4) → 14+16+4 = 34
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 34, "bitwise")
}

test "byte unsigned shr, compare, div, mod" {
  // 200 as i8 is 0xC8: signed readings would give shr=252 (ashr), the
  // comparison false (-56 > 100), div=238 (sdiv wraps) and mod=0 — the
  // expected 83 only falls out of the unsigned lowerings (#4628).
  val src = "package T\n" + "func main(): Int {\n" + "  val hi = 200.toByte()\n" + "  val lo = 100.toByte()\n" +
    "  val sh = hi.shr(4).toInt()\n" +
    "  val cmp = if hi > lo {\n" +
    "    1\n" +
    "  } else {\n" +
    "    0\n" +
    "  }\n" +
    "  val q = (hi / 3.toByte()).toInt()\n" +
    "  val m = (hi % 7.toByte()).toInt()\n" +
    "  sh + cmp + q + m\n" +
    "}\n"
  // 12 + 1 + 66 + 4 = 83
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 83, "byte unsigned semantics")
}

test "division by zero panics" {
  val src = "package T\n" + "func den(): Int {\n" + "  0\n" + "}\n" + "func main(): Int {\n" + "  7 / den()\n" + "}\n"
  val r = compileAndRun(src)
  assertTrue(r.exitCode != 0, "div by zero must abort")
}

test "string printing and concatenation" {
  val src = "package T\n" + "import Std.Console as Console\n" + "func main(): Int {\n" + "  val a = \"Hello\"\n" +
    "  val b = a + \", \" + \"world!\"\n" +
    "  Console.println(b)\n" +
    "  Console.println(b.length.toString())\n" +
    "  0\n" +
    "}\n"
  // Console.println resolves through the bundled stdlib in the full
  // bridge; at the codegen layer the test provides a same-package shim.
  val shim = "package T\n" + "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "extern func consoleNewlineFd(fd: Int): Unit = \"lyric_console_write_newline\"\n" +
    "func println(s: in String): Unit {\n" +
    "  consoleWriteFd(1, s)\n" +
    "  consoleNewlineFd(1)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val a = \"Hello\"\n" +
    "  val b = a + \", \" + \"world!\"\n" +
    "  println(b)\n" +
    "  println(b.length.toString())\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRun(shim)
  assertEqualInt(r.exitCode, 0, "string program exit")
  assertEqual(r.stdout, "Hello, world!\n13\n", "string program output")
}

test "string equality and comparison" {
  val src = "package T\n" + "func main(): Int {\n" + "  val a = \"abc\"\n" + "  val b = \"ab\" + \"c\"\n" +
    "  if a == b and a != \"abd\" and a < \"abd\" and \"abd\" > a {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 0, "string eq/cmp")
}

test "string interpolation" {
  val shim = "package T\n" + "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "extern func consoleNewlineFd(fd: Int): Unit = \"lyric_console_write_newline\"\n" +
    "func println(s: in String): Unit {\n" +
    "  consoleWriteFd(1, s)\n" +
    "  consoleNewlineFd(1)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val n = 6\n" +
    "  val who = \"world\"\n" +
    "  println(\"n=\${n * 7}, hi \${who}, flag=\${n > 2}\")\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRun(shim)
  assertEqual(r.stdout, "n=42, hi world, flag=true\n", "interpolation")
}

test "float arithmetic prints" {
  val shim = "package T\n" + "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "extern func consoleNewlineFd(fd: Int): Unit = \"lyric_console_write_newline\"\n" +
    "func println(s: in String): Unit {\n" +
    "  consoleWriteFd(1, s)\n" +
    "  consoleNewlineFd(1)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val x = 1.5 + 2.25\n" +
    "  val y = x * 2.0 - 0.5\n" +
    "  println(y.toString())\n" +
    "  if y == 7.0 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(shim)
  assertEqualInt(r.exitCode, 0, "float compare exit")
  assertEqual(r.stdout, "7\n", "float print")
}

test "explicit return paths" {
  val src = "package T\n" + "func classify(n: in Int): Int {\n" + "  if n < 0 {\n" + "    return 1\n" + "  }\n" +
    "  if n == 0 {\n" +
    "    return 2\n" +
    "  }\n" +
    "  3\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  classify(-5) * 100 + classify(0) * 10 + classify(9)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 123, "early returns")
}

test "unit main and substring" {
  val shim = "package T\n" + "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "func main(): Unit {\n" +
    "  val s = \"native backend\"\n" +
    "  consoleWriteFd(1, s.substring(0, 6))\n" +
    "}\n"
  val r = compileAndRun(shim)
  assertEqualInt(r.exitCode, 0, "unit main exit 0")
  assertEqual(r.stdout, "native", "substring")
}

// ─────────────────────────────────────────────────────────────────────────────
// String.trim/toLower/indexOf/startsWith/contains/endsWith (#6588).
// trim/toLower allocate a fresh heap String, so they run under ASan; the
// boolean predicates and indexOf don't allocate but are included alongside
// for a single coherent block covering every method the issue lists.
// ─────────────────────────────────────────────────────────────────────────────
test "string trim strips ASCII and Unicode whitespace (ASan)" {
  val shim = "package T\n" + "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "func main(): Int {\n" +
    // U+00A0 NO-BREAK SPACE flanks the ASCII spaces on each side — trim must
    // strip both kinds, matching Std.Char.isWhiteSpace's code-point set.
    "  val padded = \"  \\u{00A0}hi there\\u{00A0}  \"\n" +
    "  val trimmed = padded.trim()\n" +
    "  consoleWriteFd(1, trimmed)\n" +
    "  trimmed.length\n" +
    "}\n"
  val r = compileAndRunAsan(shim)
  assertEqualInt(r.exitCode, 8, "trim: \"hi there\".length")
  assertEqual(r.stdout, "hi there", "trim result")
}

test "string trim: all-whitespace collapses to empty, no-padding is unchanged (ASan)" {
  val src = "package T\n" + "func main(): Int {\n" + "  val allSpace = \"   \\u{00A0} \"\n" +
    "  val noPad = \"clean\"\n" +
    "  val empty = \"\"\n" +
    "  allSpace.trim().length * 100 + noPad.trim().length * 10 + empty.trim().length\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 50, "trim edges: 0*100 + 5*10 + 0")
}

test "string toLower folds ASCII, Latin-1, Greek, and Cyrillic (ASan)" {
  val shim = "package T\n" + "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "func main(): Int {\n" +
    "  val s = \"CAFÉ ΑΒΓ АБВ\"\n" +
    "  consoleWriteFd(1, s.toLower())\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRunAsan(shim)
  assertEqualInt(r.exitCode, 0, "toLower exit")
  assertEqual(r.stdout, "café αβγ абв", "toLower: Latin-1 + Greek + Cyrillic")
}

test "string toLower leaves already-lowercase text and punctuation unchanged (ASan)" {
  val src = "package T\n" + "func main(): Int {\n" + "  val s = \"already-lower! 123\"\n" + "  if s.toLower() == s {\n" +
    "    1\n" +
    "  } else {\n" +
    "    0\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 1, "toLower: no-op on already-lowercase/punctuation")
}

// U+0130 (İ, LATIN CAPITAL LETTER I WITH DOT ABOVE) has no case partner in
// Latin Extended-A's otherwise-uniform even/odd pairing: its unconditional
// simple lowercase mapping is U+0069 (plain ASCII "i"), not U+0131 (a
// wholly separate letter). Also the one mapping that shrinks the UTF-8
// byte length (2 bytes -> 1 byte), exercising the ASan-checked compacting
// write path end to end (#6758).
test "string toLower maps U+0130 (İ) to plain ASCII i, not U+0131 dotless i (#6758, ASan)" {
  val shim = "package T\n" + "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "func main(): Int {\n" +
    "  val s = \"İstanbul\"\n" +
    "  val lowered = s.toLower()\n" +
    "  consoleWriteFd(1, lowered)\n" +
    "  lowered.length\n" +
    "}\n"
  val r = compileAndRunAsan(shim)
  assertEqualInt(r.exitCode, 8, "\"istanbul\".length (byte length shrinks from 9 to 8)")
  assertEqual(r.stdout, "istanbul", "toLower: U+0130 -> U+0069 (plain i), not U+0131 (dotless i)")
}

test "string indexOf: found offset, -1 sentinel, and empty-needle/-haystack" {
  val shim = "package T\n" + "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "extern func consoleNewlineFd(fd: Int): Unit = \"lyric_console_write_newline\"\n" +
    "func println(s: in String): Unit {\n" +
    "  consoleWriteFd(1, s)\n" +
    "  consoleNewlineFd(1)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val s = \"hello world\"\n" +
    "  println(s.indexOf(\"world\").toString())\n" +
    "  println(s.indexOf(\"xyz\").toString())\n" +
    "  println(s.indexOf(\"\").toString())\n" +
    "  println(\"\".indexOf(\"\").toString())\n" +
    "  println(s.indexOf(\"hello\").toString())\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRun(shim)
  assertEqualInt(r.exitCode, 0, "indexOf exit")
  assertEqual(r.stdout, "6\n-1\n0\n0\n0\n", "indexOf: found, missing (-1), empty needle/haystack, offset 0")
}

test "string startsWith/contains/endsWith: match, mismatch, and empty-argument edge cases" {
  val shim = "package T\n" + "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "extern func consoleNewlineFd(fd: Int): Unit = \"lyric_console_write_newline\"\n" +
    "func println(s: in String): Unit {\n" +
    "  consoleWriteFd(1, s)\n" +
    "  consoleNewlineFd(1)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val s = \"hello world\"\n" +
    "  println(s.startsWith(\"hello\").toString())\n" +
    "  println(s.startsWith(\"world\").toString())\n" +
    "  println(s.startsWith(\"\").toString())\n" +
    "  println(s.startsWith(\"hello world!\").toString())\n" +
    "  println(s.contains(\"lo wo\").toString())\n" +
    "  println(s.contains(\"xyz\").toString())\n" +
    "  println(s.contains(\"\").toString())\n" +
    "  println(s.endsWith(\"world\").toString())\n" +
    "  println(s.endsWith(\"hello\").toString())\n" +
    "  println(s.endsWith(\"\").toString())\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRun(shim)
  assertEqualInt(r.exitCode, 0, "predicates exit")
  assertEqual(
    r.stdout,
    "true\nfalse\ntrue\nfalse\ntrue\nfalse\ntrue\ntrue\nfalse\ntrue\n",
    "startsWith/contains/endsWith across match, mismatch, over-length, and empty-argument cases"
  )
}

test "string trim().toLower() under repeated allocation (ASan)" {
  val shim = "package T\n" + "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "func main(): Int {\n" +
    "  var total = 0\n" +
    "  var i = 0\n" +
    "  while i < 200 {\n" +
    "    val s = \"  MiXeD Case \" + i.toString() + \"  \"\n" +
    "    val t = s.trim().toLower()\n" +
    "    total = total + t.length\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  consoleWriteFd(1, total.toString())\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRunAsan(shim)
  assertEqualInt(r.exitCode, 0, "repeated trim/toLower exit")
  // 200 * len("mixed case ") [11] + sum(len(str(i)) for i in 0..199) [10*1 + 90*2 + 100*3 = 490]
  assertEqual(r.stdout, "2690", "repeated trim/toLower: total length across 200 allocations")
}
