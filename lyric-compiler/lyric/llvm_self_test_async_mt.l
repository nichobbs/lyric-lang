//! llvm_self_test_async_mt.l — end-to-end self-test for the multi-threaded
//! native coroutine scheduler (docs/67 G8, D217).  Each case compiles a small
//! async program through the full native bridge, then runs the binary with
//! `LYRIC_ASYNC_THREADS` set, so `spawn`ed tasks start on worker threads
//! and awaiting coroutines resume on whichever thread finished the awaited
//! task.
//!
//! What the cases prove:
//!   - real parallelism: three spawned tasks rendezvous at a gate that only
//!     opens when all three are inside their bodies at once, which the
//!     single-threaded scheduler can never satisfy (the task bodies spin on
//!     the gate without ever suspending);
//!   - fork-join correctness under contention: a recursive `fib` that spawns
//!     and awaits at every level, a protected counter hammered from many
//!     tasks, and sleep-driven tasks resumed on other threads;
//!   - the default stays cooperative: with the variable unset the same
//!     programs run on one thread and give the same answers;
//!   - AddressSanitizer is clean on the fork-join and sleeper programs
//!     (frames, task refcounts and the protected counter balance across
//!     threads).  ThreadSanitizer runs from `scripts/ci/async-mt-e2e.sh`.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_self_test_async_mt.l
@test_module
package Lyric.LlvmSelfTestAsyncMt

import Std.Core
import Std.Collections
import Std.Testing
import Std.Environment as Environment
import Std.Process as Process
import Std.Path as Path
import Std.Uuid as Uuid
import Lyric.Parser
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.LlvmCodegen
import Lyric.LlvmLowering
import Lyric.Emitter
import Lyric.LlvmBridge

record RunOutcome {
  exitCode: Int
  stdout: String
}

// Compile with the full bridge (so `Std.Time` resolves to its native kernel),
// then run the binary with LYRIC_ASYNC_THREADS = `threads` (the child inherits
// the environment; "1" is the default cooperative scheduler).
func compileAndRunWith(source: in String, sanitize: in Bool, threads: in String): RunOutcome {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = nativeScratchDir("lyric-llvm-async-mt-selftest")
  val stem = Path.join(dir, "t_" + Uuid.uuidToString(Uuid.newUuid()))
  val flags: List[String] = newList()
  if sanitize {
    flags.add("-fsanitize=address")
  }
  if not compileToNativeWithFlags(source, stem, stdlib, "", "0", flags, newList(), "", true) {
    panic("native compilation failed for a multi-threaded async self-test program")
  }
  Environment.setVar("LYRIC_ASYNC_THREADS", threads)
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 120000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

// Three tasks that each wait, without ever suspending, for the other two to
// arrive.  Needs three threads running task bodies at the same moment.
func rendezvousSrc(waitMs: in Int): String {
  "package T\n" + "import Std.Time as Time\n" +
    "protected type Gate {\n  var arrived: Int = 0\n  entry arrive() {\n    arrived = arrived + 1\n  }\n  entry count(): Int {\n    return arrived\n  }\n}\n" +
    "async func meet(g: in Gate): Int {\n" +
    "  g.arrive()\n" +
    "  val deadline = Time.nowEpochMillis() + " +
    waitMs.toString() +
    "\n" +
    "  var spins = 0\n" +
    "  while g.count() < 3 and Time.nowEpochMillis() < deadline {\n    spins = spins + 1\n  }\n" +
    "  return g.count()\n" +
    "}\n" +
    "async func run(g: in Gate): Int {\n" +
    "  scope {\n    val a = spawn meet(g)\n    val b = spawn meet(g)\n    val c = spawn meet(g)\n    return await a + await b + await c\n  }\n" +
    "}\n" +
    "func main(): Int {\n  val g = Gate()\n  val total = await run(g)\n  if total == 9 {\n    77\n  } else {\n    1\n  }\n}\n"
}

// Fork-join at every level: ~1,200 tasks spawned and awaited across threads.
val fibSrc: String = "package T\n" + "async func fib(n: in Int): Int {\n  if n < 2 {\n    return n\n  }\n" + "  scope {\n    val a = spawn fib(n - 1)\n    val b = spawn fib(n - 2)\n    return await a + await b\n  }\n}\n" + "func main(): Int {\n  val v = await fib(14)\n  if v == 377 {\n    77\n  } else {\n    1\n  }\n}\n"

// Sleeping tasks resumed on other threads, each adding to one protected total.
val sleepersSrc: String = "package T\n" + "import Std.Time as Time\n" + "protected type Total {\n  var sum: Int = 0\n  entry add(n: in Int) {\n    sum = sum + n\n  }\n  entry get(): Int {\n    return sum\n  }\n}\n" + "async func napper(t: in Total, n: in Int, ms: in Int): Unit {\n" + "  Time.sleepMillis(ms)\n  t.add(n)\n  Time.sleepMillis(ms)\n  t.add(n * 100)\n}\n" + "async func run(t: in Total): Unit {\n" + "  scope {\n" + "    val a = spawn napper(t, 1, 5)\n    val b = spawn napper(t, 2, 15)\n    val c = spawn napper(t, 3, 10)\n    val d = spawn napper(t, 4, 1)\n" + "    await a\n    await b\n    await c\n    await d\n" + "  }\n}\n" + "func main(): Int {\n  val t = Total()\n  await run(t)\n  if t.get() == 1010 {\n    77\n  } else {\n    1\n  }\n}\n"

// Many tasks adding to one protected counter, then a sum check.
val counterSrc: String = "package T\n" + "protected type Counter {\n  var n: Int = 0\n  entry bump() {\n    n = n + 1\n  }\n  entry get(): Int {\n    return n\n  }\n}\n" + "async func hammer(c: in Counter, times: in Int): Int {\n" + "  var i = 0\n  while i < times {\n    c.bump()\n    i = i + 1\n  }\n  return times\n}\n" + "async func run(c: in Counter): Int {\n" + "  scope {\n" + "    val a = spawn hammer(c, 5000)\n    val b = spawn hammer(c, 5000)\n    val d = spawn hammer(c, 5000)\n    val e = spawn hammer(c, 5000)\n" + "    return await a + await b + await d + await e\n" + "  }\n}\n" + "func main(): Int {\n  val c = Counter()\n  val done = await run(c)\n  if done == 20000 and c.get() == 20000 {\n    77\n  } else {\n    1\n  }\n}\n"

test "three spawned tasks run at once: a rendezvous only a multi-threaded scheduler can satisfy" {
  val r = compileAndRunWith(rendezvousSrc(8000), false, "4")
  assertEqualInt(r.exitCode, 77, "all three bodies were inside the gate together")
}

test "without LYRIC_ASYNC_THREADS the rendezvous cannot complete: the default scheduler is cooperative" {
  // Same program, one thread: each body runs to completion on the spawner before the next starts,
  // so none sees all three arrivals and the sum is 1 + 2 + 3, not 9.
  val r = compileAndRunWith(rendezvousSrc(300), false, "1")
  assertEqualInt(r.exitCode, 1, "one thread: the first task times out waiting for the others")
}

test "recursive fork-join across threads computes fib" {
  val r = compileAndRunWith(fibSrc, false, "4")
  assertEqualInt(r.exitCode, 77, "fib(14) == 377 with every level spawned and awaited")
}

test "recursive fork-join gives the same answer on the default scheduler" {
  val r = compileAndRunWith(fibSrc, false, "1")
  assertEqualInt(r.exitCode, 77, "fib(14) == 377 on one thread")
}

test "sleeping tasks resume on other threads and share a protected total" {
  val r = compileAndRunWith(sleepersSrc, false, "3")
  assertEqualInt(r.exitCode, 77, "1 + 2 + 3 + 4 plus 100 times each == 1010")
}

test "a protected counter hammered from four tasks loses no update" {
  val r = compileAndRunWith(counterSrc, false, "4")
  assertEqualInt(r.exitCode, 77, "4 x 5000 bumps == 20000")
}

test "fork-join is clean under AddressSanitizer with several threads" {
  val r = compileAndRunWith(fibSrc, true, "4")
  assertEqualInt(r.exitCode, 77, "no leak, double free or use after free across threads")
}

test "sleepers and a protected total are clean under AddressSanitizer with several threads" {
  val r = compileAndRunWith(sleepersSrc, true, "3")
  assertEqualInt(r.exitCode, 77, "frames and task refs balance when resumed on other threads")
}

test "rendezvous is clean under AddressSanitizer" {
  val r = compileAndRunWith(rendezvousSrc(8000), true, "4")
  assertEqualInt(r.exitCode, 77, "parallel bodies leave no leak")
}
