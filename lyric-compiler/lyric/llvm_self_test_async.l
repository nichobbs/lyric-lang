//! llvm_self_test_async.l — end-to-end self-test for native `async func` /
//! `await` (D-N-019).  Parses small programs using `async func` and `await`,
//! lowers them via `codegenNativePackage` + `lowerNativePackage`,
//! clang-compiles against `lyric-rt/build/lyric_rt.a`, runs the binary, and
//! asserts its exit code / stdout.
//!
//! Per D-N-019, native compiles a non-generator `async func` through the
//! exact same codegen path as a plain `func` and lowers `await expr` as a
//! pure passthrough; per D-N-021, `spawn expr` is the same passthrough
//! (matching MSIL's own ESpawn lowering) and `scope { }` is a real lexical
//! scope. With no async leaf primitive on this target, a spawned call
//! always completes at the spawn site, so these semantics are
//! observationally equivalent to the reference backend's for every
//! compilable program. These tests exercise both slices: basic
//! async functions, chained/nested awaits, async inside a loop, ARC-managed
//! captures under ASan, spawn-bind-then-await, the language reference's
//! section 7.4 dashboard shape, and scope/defer interplay.
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
  // D-N-019: `await` is a pure passthrough for native, so a bare call to an
  // async function (no `await` keyword at all) is equally legal and yields
  // the same value directly -- there is no wrapped Task[T] to unwrap either
  // way.
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
