//! llvm_self_test_defer.l — end-to-end self-test for `defer` on the native
//! (LLVM) backend (P2.D1).  Parses small programs using `defer { }`,
//! compiles them through the full bridge pipeline
//! (`Lyric.LlvmBridge.compileToNativeWithFlags`, exactly like `lyric build
//! --target native` — needed so `Std.Console.println` resolves for the
//! stdout-observation tests below), runs the binary, and asserts its exit
//! code / stdout.
//!
//! Native has no try/finally (D-N-003: no unwinding), so `defer` cannot
//! lean on the msil/jvm `try { rest } finally { D }` recursive lowering.
//! Instead, each lexical scope gets its own list of pending deferred
//! blocks (mirroring the existing ARC scope-exit stack exactly), run in
//! reverse declaration order at every exit from that scope: normal
//! fall-off, `return`, `break`, and `continue`. A `defer` registered
//! before a `panic` does NOT run: `panic` aborts the process immediately
//! with no scope-exit event to trigger it (the last test below verifies
//! this documented gap directly, rather than leaving it unverified).
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_self_test_defer.l
@test_module
package Lyric.LlvmSelfTestDefer

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.String as Str
import Std.Uuid as Uuid
import Lyric.Emitter
import Lyric.LlvmBridge

// ─────────────────────────────────────────────────────────────────────────────
// Harness (mirrors llvm_stdlib_self_test.l): compile source through the
// full bridge pipeline (stdlib bundled, so `Std.Console` resolves) and run
// the resulting binary, optionally under ASan.
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

record RunOutcome {
  exitCode: Int
  stdout: String
}

func compileAndRunWith(source: in String, sanitize: in Bool): RunOutcome {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-defer-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val flags: List[String] = newList()
  if sanitize {
    flags.add("-fsanitize=address")
  }
  if not compileToNativeWithFlags(source, stem, stdlib, "", "0", flags) {
    panic("native compilation failed for a defer self-test program")
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

// ─────────────────────────────────────────────────────────────────────────────
// Cases.  Each program's `main` returns an Int the test asserts on (exit
// code doubles as the observation channel, matching the other native
// self-tests' style).
// ─────────────────────────────────────────────────────────────────────────────
test "multiple defers run in reverse declaration order on fall-off" {
  val src = "package T\n" + "import Std.Collections\n" + "func reverseOrder(log: in List[Int]): Unit {\n" +
    "  defer {\n    log.add(1)\n  }\n" +
    "  defer {\n    log.add(2)\n  }\n" +
    "  log.add(0)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  reverseOrder(log)\n" +
    "  log[0] * 100 + log[1] * 10 + log[2]\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 21, "body appends 0 first, then defers append 2 then 1 (reverse order): 0,2,1")
}

// NOTE: process exit codes truncate to 8 bits on POSIX, so every case
// below prints its observations via Console.println and asserts on
// stdout rather than packing values into the exit code (a value over
// 255 would silently wrap and look like a codegen bug when it is not).
test "defer runs on an early return and the returned value is preserved" {
  val src = "package T\n" + "import Std.Collections\n" + "import Std.Console as Console\n" +
    "func deferOnReturn(log: in List[Int], x: in Int): Int {\n" +
    "  defer {\n    log.add(9)\n  }\n" +
    "  if x > 0 {\n    return 5\n  }\n" +
    "  10\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  val v = deferOnReturn(log, 1)\n" +
    "  Console.println(toString(v) + \" \" + toString(log.count) + \" \" + toString(log[0]))\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqual(Str.trim(r.stdout), "5 1 9", "early-return value 5, one deferred append of 9")
}

test "defer runs on fall-through (no early return) too" {
  val src = "package T\n" + "import Std.Collections\n" + "import Std.Console as Console\n" +
    "func deferOnReturn(log: in List[Int], x: in Int): Int {\n" +
    "  defer {\n    log.add(9)\n  }\n" +
    "  if x > 0 {\n    return 5\n  }\n" +
    "  10\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  val v = deferOnReturn(log, -1)\n" +
    "  Console.println(toString(v) + \" \" + toString(log.count) + \" \" + toString(log[0]))\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqual(Str.trim(r.stdout), "10 1 9", "fall-through value 10, one deferred append of 9")
}

test "defer runs on break out of the enclosing loop" {
  val src = "package T\n" + "import Std.Collections\n" + "import Std.Console as Console\n" +
    "func deferOnBreak(log: in List[Int]): Unit {\n" +
    "  var i = 0\n" +
    "  while i < 5 {\n" +
    "    val mark = 100 + i\n" +
    "    defer {\n      log.add(mark)\n    }\n" +
    "    if i == 2 {\n      break\n    }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  deferOnBreak(log)\n" +
    "  Console.println(toString(log.count) + \" \" + toString(log[0]) + \" \" + toString(log[1]) + \" \" + toString(log[2]))\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRun(src)
  // Iterations i=0,1,2; each body's defer runs at body exit -> log = [100,101,102].
  assertEqual(Str.trim(r.stdout), "3 100 101 102", "three deferred appends: 100, 101, 102 (the break iteration)")
}

test "defer runs on continue" {
  val src = "package T\n" + "import Std.Collections\n" + "import Std.Console as Console\n" +
    "func deferOnContinue(log: in List[Int]): Unit {\n" +
    "  var i = 0\n" +
    "  while i < 3 {\n" +
    "    val cur = i\n" +
    "    i = i + 1\n" +
    "    defer {\n      log.add(200 + cur)\n    }\n" +
    "    if cur == 1 {\n      continue\n    }\n" +
    "    log.add(cur)\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  deferOnContinue(log)\n" +
    "  log.count\n" +
    "}\n"
  val r = compileAndRun(src)
  // i=0: append 0, defer 200; i=1: continue (skips the plain append), defer 201;
  // i=2: append 2, defer 202. Five total appends -- well within a byte.
  assertEqualInt(r.exitCode, 5, "appends + defers: 0,200,201,2,202")
}

test "defer inside a value-producing if-branch runs on block exit, value preserved" {
  val src = "package T\n" + "import Std.Collections\n" + "import Std.Console as Console\n" +
    "func deferInValueBlock(log: in List[Int]): Int {\n" +
    "  val r = if true {\n    defer {\n      log.add(5)\n    }\n    7\n  } else {\n    0\n  }\n" +
    "  r\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  val r = deferInValueBlock(log)\n" +
    "  Console.println(toString(r) + \" \" + toString(log.count) + \" \" + toString(log[0]))\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqual(Str.trim(r.stdout), "7 1 5", "branch value 7 preserved across the deferred block, one append of 5")
}

// ASan: a String-typed local captured by a defer must not leak or
// double-release across many constructions -- proves the defer's own
// lowering (lowerBlockStmts recursion into the deferred Block) shares the
// same ARC discipline as every other block.
test "defer with a String-typed capture is leak-free under ASan" {
  val src = "package T\n" + "func greetLen(name: in String): Int {\n" + "  var total = 0\n" +
    "  defer {\n    val s = \"bye \" + name\n    total = total + s.length\n  }\n" +
    "  val s2 = \"hi \" + name\n" +
    "  total + s2.length\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var sum = 0\n  var i = 0\n" +
    "  while i < 30 {\n    sum = sum + greetLen(\"x\")\n    i = i + 1\n  }\n" +
    "  sum\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  // The tail value (`total + s2.length`) is snapshotted before the defer
  // runs (Rule 6 ordering, same as the other tests above), so the
  // deferred mutation of `total` never reaches the return value: each
  // call returns 0 + "hi x".length == 4, regardless of the defer.
  assertEqualInt(r.exitCode, 30 * 4, "\"hi x\".length == 4 each iteration; the deferred block's own local is leak-free")
}

// D-N-003: a `defer` registered before a `panic` does NOT run -- `panic`
// aborts the process immediately with no scope-exit event. This is not an
// oversight; it is the same "panics abort, no unwinding" model every other
// native construct already has (D-N-018's test-runner precedent). Verified
// directly rather than left as an unverified claim: the deferred block
// would print a marker if it ran, and the process aborts with a nonzero
// exit code either way.
test "a defer before a panic does not run (D-N-003: no unwinding)" {
  val src = "package T\n" + "import Std.Console as Console\n" + "func deferThenPanic(): Unit {\n" +
    "  defer {\n    Console.println(\"DEFER RAN\")\n  }\n" +
    "  panic(\"boom\")\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  deferThenPanic()\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRun(src)
  assertTrue(r.exitCode != 0, "panic aborts the process with a nonzero exit code")
  assertFalse(Str.contains(r.stdout, "DEFER RAN"), "the deferred block never ran: panic bypasses scope exit entirely")
}
