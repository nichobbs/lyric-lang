//! llvm_self_test_async.l — end-to-end self-test for native `async func` /
//! `await` / `spawn` (D-N-019, D-N-021, D-N-022).  Parses small programs,
//! lowers them via `codegenNativePackage` + `lowerNativePackage`,
//! clang-compiles against `lyric-rt/build/lyric_rt.a`, runs the binary, and
//! asserts its exit code / stdout.
//!
//! Per D-N-022 (stage B2), an `async func` compiles to a real LLVM
//! coroutine: the define returns its LyricTask*, runs hot until the first
//! genuine suspension (an await on an incomplete task, or a
//! `Std.Time.sleepMillis` call — the async leaf, which parks the task on
//! the scheduler's timer list instead of blocking), and interleaves with
//! other spawned tasks under the lyric-rt cooperative scheduler.  A task
//! that never suspends completes inside the ramp, which reproduces the
//! earlier passthrough behavior (D-N-019/D-N-021) as the degenerate case —
//! so the pre-coroutine cases below double as a regression net for the
//! coroutine path, and the sleep-driven cases prove genuine concurrency
//! (effect interleaving that a sequential execution cannot produce).
//! The D-N-023 cases cover the async process leaf: in-coroutine
//! `Std.Process.runCapture` redirects to the kernel's nonblocking
//! capture op, so subprocess captures overlap and honor `timeoutMs`.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_self_test_async.l
@test_module
package Lyric.LlvmSelfTestAsync

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
import Lyric.Emitter
import Lyric.LlvmBridge

// ─────────────────────────────────────────────────────────────────────────────
// Harness (mirrors llvm_self_test_n34.l): compile source to a native binary
// (optionally under ASan) and run it.
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

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
  val dir = Path.join(tempBase(), "lyric-llvm-async-selftest")
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

// The full bridge pipeline (`compileToNativeWithFlags` with the
// `_kernel_native/` stdlib twins loaded, exactly like `lyric build
// --target native`) — needed by the sleep-driven cases, whose sources
// import `Std.Time`.
func compileAndRunBundledWith(source: in String, sanitize: in Bool): RunOutcome {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-async-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val flags: List[String] = newList()
  if sanitize {
    flags.add("-fsanitize=address")
  }
  if not compileToNativeWithFlags(source, stem, stdlib, "", "0", flags) {
    panic("native compilation failed for an async self-test program")
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

func compileAndRunBundled(source: in String): RunOutcome {
  compileAndRunBundledWith(source, false)
}

func compileAndRunBundledAsan(source: in String): RunOutcome {
  compileAndRunBundledWith(source, true)
}

// Compiling a source that should FAIL at codegen (panic inside
// codegenNativePackage/lowerNativePackage).  `Process.runCapture` isn't
// involved here since the panic happens in-process; instead this drives
// codegen directly and asserts it panics with the expected message
// substring, mirroring how other self-tests assert negative diagnostics
// without spawning a child process for an in-process failure.
func assertNativeCodegenPanics(source: in String, expectSubstring: in String, label: in String): Unit {
  val pr = parse(source)
  if pr.diagnostics.count > 0 {
    panic("test source has parse diagnostics")
  }
  assertPanicsWith(
    label,
    expectSubstring,
    { -> val pkg = codegenNativePackage(pr.file, ""); val _ = lowerNativePackage(pkg) }
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Cases.
// ─────────────────────────────────────────────────────────────────────────────
test "basic async function: async func called via await returns its value" {
  val src = "package T\n" + "async func computeAnswer(): Int {\n  return 42\n}\n" +
    "func main(): Int {\n  await computeAnswer()\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "await of a simple async func yields its return value")
}

test "async func without an explicit await: bare call also yields the value" {
  // A bare call to an async function awaits at the call site (only `spawn`
  // defers consumption), matching the front end where `spawn`/`await` are
  // type-transparent; the `await` keyword adds nothing to a direct call.
  val src = "package T\n" + "async func computeAnswer(): Int {\n  return 7\n}\n" +
    "func main(): Int {\n  computeAnswer()\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 7, "a bare (un-awaited) call to an async func still yields its value")
}

test "chained awaits: an async func awaits another async func" {
  val src = "package T\n" + "async func inner(): Int {\n  return 10\n}\n" +
    "async func outer(): Int {\n  val x = await inner()\n  return x + 5\n}\n" +
    "func main(): Int {\n  await outer()\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 15, "outer awaits inner and adds 5: 10 + 5 == 15")
}

test "nested awaits: three levels of async func chained together" {
  val src = "package T\n" + "async func level3(): Int {\n  return 1\n}\n" +
    "async func level2(): Int {\n  val x = await level3()\n  return x + 1\n}\n" +
    "async func level1(): Int {\n  val x = await level2()\n  return x + 1\n}\n" +
    "func main(): Int {\n  await level1()\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 3, "three chained levels each add 1, starting from 1: 3")
}

test "async in a loop: await called repeatedly accumulates correctly" {
  val src = "package T\n" + "async func square(n: in Int): Int {\n  return n * n\n}\n" + "func main(): Int {\n" +
    "  var sum = 0\n  var i = 1\n" +
    "  while i <= 5 {\n    sum = sum + await square(i)\n    i = i + 1\n  }\n" +
    "  sum\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 55, "1^2+2^2+3^2+4^2+5^2 == 55")
}

test "async with a branch: await inside an if/else expression" {
  val src = "package T\n" + "async func doubleIt(n: in Int): Int {\n  return n * 2\n}\n" +
    "async func pick(flag: in Bool, n: in Int): Int {\n" +
    "  if flag {\n    await doubleIt(n)\n  } else {\n    n\n  }\n" +
    "}\n" +
    "func main(): Int {\n  await pick(true, 21)\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "the true branch awaits doubleIt(21) == 42")
}

// ARC: an async func chain returning and concatenating Strings must not
// leak or double-release the intermediate results (D-N-019's passthrough
// model means these strings flow through completely ordinary ARC codegen).
test "async with String captures/returns is leak-free under ASan" {
  val src = "package T\n" + "async func greet(name: in String): String {\n  return \"hi \" + name\n}\n" +
    "async func greetTwice(name: in String): String {\n  val a = await greet(name)\n  val b = await greet(name)\n  return a + \", \" + b\n}\n" +
    "func main(): Int {\n" +
    "  var i = 0\n  var lastLen = 0\n" +
    "  while i < 20 {\n    val s = await greetTwice(\"world\")\n    lastLen = s.length\n    i = i + 1\n  }\n" +
    "  lastLen\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 18, "\"hi world, hi world\" has length 18, leak-free across 20 iterations")
}

test "async generators (yield inside async func) are rejected with a distinct diagnostic" {
  val src = "package T\n" +
    "async func naturals(limit: in Int): Int {\n  var i = 0\n  while i < limit {\n    yield i\n    i = i + 1\n  }\n}\n" +
    "func main(): Int {\n  0\n}\n"
  assertNativeCodegenPanics(
    src,
    "async generators",
    "a yield-bearing async func must panic naming generators specifically, not the generic async-unsupported message"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// spawn / scope (D-N-021): passthrough parity with MSIL's own lowering.
// ─────────────────────────────────────────────────────────────────────────────
test "spawn binds a value that a later await reads back" {
  val src = "package T\n" + "async func compute(n: in Int): Int {\n  return n * 3\n}\n" +
    "async func run(): Int {\n  val t = spawn compute(4)\n  val more = 8\n  val v = await t\n  return v + more\n}\n" +
    "func main(): Int {\n  await run()\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 20, "spawn compute(4) == 12, held across other work, awaited later: 12 + 8")
}

// The language reference's own §7.4 shape: several spawns inside a scope,
// each awaited, the aggregate returned from inside the scope block.
test "scope with multiple spawns and awaits: the section 7.4 dashboard shape" {
  val src = "package T\n" + "async func loadA(n: in Int): Int {\n  return n + 1\n}\n" +
    "async func loadB(n: in Int): Int {\n  return n + 2\n}\n" +
    "async func loadC(n: in Int): Int {\n  return n + 3\n}\n" +
    "async func dashboard(n: in Int): Int {\n" +
    "  scope {\n" +
    "    val a = spawn loadA(n)\n    val b = spawn loadB(n)\n    val c = spawn loadC(n)\n" +
    "    return await a + await b + await c\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n  await dashboard(10)\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 36, "11 + 12 + 13 == 36, returned from inside the scope block")
}

// A scope block is a real lexical scope on native: a defer registered
// inside it runs at scope exit (before statements after the scope), and
// scope-local bindings do not leak.
test "scope interacts with defer as an ordinary lexical scope" {
  val src = "package T\n" + "import Std.Collections\n" + "func run(log: in List[Int]): Unit {\n" +
    "  scope {\n    defer {\n      log.add(2)\n    }\n    log.add(1)\n  }\n" +
    "  log.add(3)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  run(log)\n" +
    "  log[0] * 100 + log[1] * 10 + log[2]\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 123, "body, then scope-exit defer, then the statement after the scope: 1,2,3")
}

// Early return from inside a scope that also registered a defer: the
// scope's defer drains on the return path (D-N-020's return handling
// composed with D-N-021's scope boundary) and the return value is
// captured before it runs.
test "early return from a scope drains the scope's defer, value preserved" {
  val src = "package T\n" + "import Std.Collections\n" + "func run(log: in List[Int], flag: in Bool): Int {\n" +
    "  scope {\n" +
    "    defer {\n      log.add(2)\n    }\n" +
    "    log.add(1)\n" +
    "    if flag {\n      return 5\n    }\n" +
    "  }\n" +
    "  log.add(9)\n" +
    "  0\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  val v = run(log, true)\n" +
    "  if v == 5 and log.count == 2 and log[0] == 1 and log[1] == 2 {\n    77\n  } else {\n    1\n  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(
    r.exitCode,
    77,
    "returned 5 with exactly [1, 2] logged: body, then the scope's defer on the return path (9 never runs)"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Real concurrency (stage B2, D-N-022): sleep-driven interleaving.
// ─────────────────────────────────────────────────────────────────────────────
// Two spawned workers log around their sleeps; the observed order
// 1,2,11,12 (worker 2's first wake lands BETWEEN worker 1's two wakes)
// is only producible if both tasks genuinely interleave — a sequential
// (passthrough) execution would log 1,11,2,12.  Sleep points: worker 1
// wakes at ~20ms and ~80ms, worker 2 at ~40ms and ~130ms; each adjacent
// pair of ideal deadlines is >= 20ms apart and every second deadline is
// computed from the task's ACTUAL first wake, so scheduler jitter far
// below 20ms cannot reorder the events.
test "two spawned sleepers interleave: effect order proves genuine concurrency" {
  val src = "package T\n" + "import Std.Collections\n" + "import Std.Time as Time\n" +
    "async func worker(log: in List[Int], tag: in Int, d1: in Int, d2: in Int): Unit {\n" +
    "  Time.sleepMillis(d1)\n  log.add(tag)\n  Time.sleepMillis(d2)\n  log.add(tag + 10)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  val a = spawn worker(log, 1, 20, 60)\n" +
    "  val b = spawn worker(log, 2, 40, 90)\n" +
    "  await a\n  await b\n" +
    "  if log.count == 4 and log[0] == 1 and log[1] == 2 and log[2] == 11 and log[3] == 12 {\n    77\n  } else {\n    1\n  }\n" +
    "}\n"
  val r = compileAndRunBundled(src)
  assertEqualInt(r.exitCode, 77, "log order 1,2,11,12: worker 2's first wake lands between worker 1's wakes")
}

// The same interleaving program under ASan: coroutine frame alloc/free,
// task refcounts, and the List shared across suspended frames must all
// balance.
test "interleaving sleepers are leak-free under ASan" {
  val src = "package T\n" + "import Std.Collections\n" + "import Std.Time as Time\n" +
    "async func worker(log: in List[Int], tag: in Int, d1: in Int, d2: in Int): Unit {\n" +
    "  Time.sleepMillis(d1)\n  log.add(tag)\n  Time.sleepMillis(d2)\n  log.add(tag + 10)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  val a = spawn worker(log, 1, 20, 60)\n" +
    "  val b = spawn worker(log, 2, 40, 90)\n" +
    "  await a\n  await b\n" +
    "  if log.count == 4 and log[0] == 1 and log[1] == 2 and log[2] == 11 and log[3] == 12 {\n    77\n  } else {\n    1\n  }\n" +
    "}\n"
  val r = compileAndRunBundledAsan(src)
  assertEqualInt(r.exitCode, 77, "the interleaving run is clean under AddressSanitizer")
}

// An await chain through a genuinely-sleeping leaf: mid's await on leaf
// parks mid (WAITING), leaf's sleep parks leaf (SLEEPING), and the
// synchronous main drives the scheduler through both wakes.
test "await chain through a sleeping leaf resumes through the scheduler" {
  val src = "package T\n" + "import Std.Time as Time\n" +
    "async func leaf(): Int {\n  Time.sleepMillis(30)\n  return 7\n}\n" +
    "async func mid(): Int {\n  val v = await leaf()\n  return v + 1\n}\n" +
    "func main(): Int {\n  await mid()\n}\n"
  val r = compileAndRunBundled(src)
  assertEqualInt(r.exitCode, 8, "leaf sleeps then yields 7; mid resumes with 7 + 1")
}

// Ref-typed results and arguments crossing a suspend point: the task
// owns its String result until released, and a borrowed String argument
// (heap-allocated at the call site, released by the caller while the
// task is parked) survives the suspension because coroutine entry
// retains ref params (ARC Rule 5 does not hold across suspends).
test "String args and results across suspends are leak-free under ASan" {
  val src = "package T\n" + "import Std.String as Str\n" + "import Std.Time as Time\n" +
    "async func tagIt(s: in String, ms: in Int): String {\n  Time.sleepMillis(ms)\n  return s + \"!\"\n}\n" +
    "async func run(): Int {\n" +
    "  val a = spawn tagIt(\"le\" + \"ft\", 20)\n" +
    "  val b = spawn tagIt(\"ri\" + \"ght\", 40)\n" +
    "  val joined = await a + \"|\" + await b\n" +
    "  return joined.length\n" +
    "}\n" +
    "func main(): Int {\n  await run()\n}\n"
  val r = compileAndRunBundledAsan(src)
  assertEqualInt(r.exitCode, 12, "\"left!|right!\" has length 12 with all task/arg/result refs balanced")
}

// A spawned task value must be awaited before its result can flow into a
// value position; the un-awaited task flowing into an Int parameter is a
// named codegen diagnostic, not an IR type error.
test "an un-awaited spawned task in a value position is a named diagnostic" {
  val src = "package T\n" + "async func f(): Int {\n  return 1\n}\n" + "func g(n: in Int): Int {\n  n\n}\n" +
    "func main(): Int {\n  val t = spawn f()\n  g(t)\n}\n"
  assertNativeCodegenPanics(
    src,
    "without being awaited",
    "a task flowing into an Int-typed argument must name the missing await, not dump an IR type mismatch"
  )
}

// ARC: String results held in spawn bindings inside a scope release
// cleanly across iterations.
test "spawn/scope with String-typed task bindings is leak-free under ASan" {
  val src = "package T\n" + "async func part(s: in String): String {\n  return s + \"!\"\n}\n" +
    "async func joinParts(): Int {\n" +
    "  scope {\n" +
    "    val a = spawn part(\"left\")\n    val b = spawn part(\"right\")\n" +
    "    val joined = await a + \"|\" + await b\n" +
    "    return joined.length\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var i = 0\n  var last = 0\n" +
    "  while i < 25 {\n    last = await joinParts()\n    i = i + 1\n  }\n" +
    "  last\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 12, "\"left!|right!\" has length 12, leak-free across 25 iterations")
}

// `async func main` (#5088): the C-ABI wrapper drives the returned task
// through lyric_task_block_on, reads the Int result slot as the exit
// code, and drops the caller's task ref.
test "async func main returning Int: exit code read from the completed task" {
  val src = "package T\n" + "import Std.Time as Time\n" +
    "async func step(n: in Int): Int {\n  Time.sleepMillis(10)\n  return n + 1\n}\n" +
    "async func main(): Int {\n  val a = spawn step(20)\n  val b = spawn step(30)\n  await a + await b\n}\n"
  val r = compileAndRunBundled(src)
  assertEqualInt(r.exitCode, 52, "async main's task result (21 + 31) becomes the process exit code")
}

// The Unit-returning variant takes synthCMain's other async arm (no
// result read; exit 0 after the task completes).
test "async func main returning Unit: process exits 0 after the task completes" {
  val src = "package T\n" + "import Std.Time as Time\n" + "async func main(): Unit {\n  Time.sleepMillis(10)\n}\n"
  val r = compileAndRunBundled(src)
  assertEqualInt(r.exitCode, 0, "a Unit async main drives to completion and exits 0")
}

// ─────────────────────────────────────────────────────────────────────────────
// The async process leaf (D-N-023): `Std.Process.runCapture` inside a
// coroutine redirects to the kernel's nonblocking capture op and parks
// only the calling task between pumps.
// ─────────────────────────────────────────────────────────────────────────────
test "async runCapture: coroutine capture returns the child's output through the async seam" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Process as Process\n" +
    "async func run(): Int {\n" +
    "  val args: List[String] = newList()\n" +
    "  args.add(\"async-leaf\")\n" +
    "  match Process.runCapture(\"/bin/echo\", args, 5000) {\n" +
    "    case Ok(r) -> {\n" +
    "      if r.stdout == \"async-leaf\\n\" and r.exitCode == 0 and not r.timedOut {\n        42\n      } else {\n        3\n      }\n" +
    "    }\n" +
    "    case Err(_) -> 4\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n  run()\n}\n"
  val r = compileAndRunBundled(src)
  assertEqualInt(r.exitCode, 42, "captured stdout, exit code, and timedOut all round-trip through the async op")
}

// Two spawned subprocess captures overlap: the 0.1s child finishes (and
// logs) before the 0.35s child spawned FIRST — impossible if either
// capture blocked the scheduler thread.
test "two spawned runCaptures interleave: the shorter child completes first" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Process as Process\n" +
    "async func worker(log: in List[Int], tag: in Int, secs: in String): Unit {\n" +
    "  val args: List[String] = newList()\n" +
    "  args.add(\"-c\")\n" +
    "  args.add(\"sleep \" + secs)\n" +
    "  val _ = Process.runCapture(\"/bin/sh\", args, 10000)\n" +
    "  log.add(tag)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  val a = spawn worker(log, 1, \"0.35\")\n" +
    "  val b = spawn worker(log, 2, \"0.1\")\n" +
    "  await a\n  await b\n" +
    "  if log.count == 2 and log[0] == 2 and log[1] == 1 {\n    77\n  } else {\n    1\n  }\n" +
    "}\n"
  val r = compileAndRunBundled(src)
  assertEqualInt(r.exitCode, 77, "the 0.1s capture completes before the 0.35s capture spawned first")
}

// The same overlap run under ASan: op buffers, task refs, and captured
// Strings crossing the pump-loop suspends must all balance.
test "interleaved runCaptures are leak-free under ASan" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Process as Process\n" +
    "async func worker(log: in List[Int], tag: in Int, secs: in String): Unit {\n" +
    "  val args: List[String] = newList()\n" +
    "  args.add(\"-c\")\n" +
    "  args.add(\"sleep \" + secs + \"; echo t\" + tag.toString())\n" +
    "  val _ = Process.runCapture(\"/bin/sh\", args, 10000)\n" +
    "  log.add(tag)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val log: List[Int] = newList()\n" +
    "  val a = spawn worker(log, 1, \"0.35\")\n" +
    "  val b = spawn worker(log, 2, \"0.1\")\n" +
    "  await a\n  await b\n" +
    "  if log.count == 2 and log[0] == 2 and log[1] == 1 {\n    77\n  } else {\n    1\n  }\n" +
    "}\n"
  val r = compileAndRunBundledAsan(src)
  assertEqualInt(r.exitCode, 77, "overlapped captures are clean under AddressSanitizer")
}

// timeoutMs is honored on the async path (the sync native seam still
// ignores it, #4752): the child is killed at the deadline, partial
// output is preserved, and the managed-twin contract (timedOut = true,
// exit code -2) is reported.
test "async runCapture timeout kills the child and reports the managed-twin contract" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Process as Process\n" +
    "async func run(): Int {\n" +
    "  val args: List[String] = newList()\n" +
    "  args.add(\"-c\")\n" +
    "  args.add(\"echo early; sleep 5\")\n" +
    "  match Process.runCapture(\"/bin/sh\", args, 300) {\n" +
    "    case Ok(r) -> {\n" +
    "      if r.timedOut and r.exitCode == 0 - 2 and r.stdout == \"early\\n\" {\n        77\n      } else {\n        2\n      }\n" +
    "    }\n" +
    "    case Err(_) -> 3\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n  run()\n}\n"
  val r = compileAndRunBundled(src)
  assertEqualInt(r.exitCode, 77, "the deadline kill preserves pre-timeout output and reports timedOut/-2")
}

// An execvp failure inside the child is exit 127 (shell convention),
// not an Err — matching the sync seam and lyric_process_run.
test "async runCapture of a missing binary reports exit 127 through the async seam" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Process as Process\n" +
    "async func run(): Int {\n" +
    "  val args: List[String] = newList()\n" +
    "  match Process.runCapture(\"/nonexistent-lyric-async-binary\", args, 5000) {\n" +
    "    case Ok(r) -> {\n" +
    "      if r.exitCode == 127 and not r.timedOut {\n        77\n      } else {\n        2\n      }\n" +
    "    }\n" +
    "    case Err(_) -> 3\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n  run()\n}\n"
  val r = compileAndRunBundled(src)
  assertEqualInt(r.exitCode, 77, "exec failure surfaces as exit 127 with Ok, matching the sync seam")
}
