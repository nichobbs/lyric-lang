//! async_for_loop_suspend_self_test.l — dual-target runtime regression test for
//! `for` loops whose body really suspends inside an `async func` (#7766), and
//! for a `defer` followed by an `await` (#7754's region dispatch).
//!
//! On `--target dotnet` an `async func` is an `IAsyncStateMachine` whose
//! `MoveNext` is re-entered after every real suspension, and every IL local
//! reverts to its default on re-entry.  A `for` loop's hidden temporaries (the
//! counter and bound of a range, the list / index / count of an indexed loop,
//! the enumerator of an `IEnumerable` or generator loop) and its pattern's
//! bindings were IL locals, so an `await` that actually suspended lost them:
//! `for x in gen() { await delay(5) }` threw `NullReferenceException` (a null
//! enumerator after resume) and `for x in [1, 2, 3] { await delay(5); t = t + x }`
//! returned 0 instead of 6 (a silent miscompile).  A loop that can suspend now
//! keeps them in state-machine fields, which Pass 1's `countSmFieldsMsil`
//! reserves per loop before the body is lowered.  An `await` that completes
//! synchronously never exercised this, so every case here suspends for real
//! through `Std.Task.delay`.
//!
//! `--target jvm` lowers `async func` synchronously (an `await` blocks the
//! calling virtual thread), so loop state lives in ordinary locals there; the
//! same cases pin that parity.
//!
//! The record declared after every `async func` reads back correctly only if
//! each state machine's Pass-1 field-count prediction held.
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/async_for_loop_suspend_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/async_for_loop_suspend_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.AsyncForLoopSuspendSelfTest

import Std.Core
import Std.Collections
import Std.Task
import Std.Testing

async func pause(): Unit {
  await Std.Task.delay(5);
  ()
}

async func asyncThree(): Int {
  await Std.Task.delay(5)
  3
}

async func genUpTo(n: in Int): Int {
  var i = 1
  while i <= n {
    yield i
    i = i + 1
  }
}

async func genGuarded(log: in List[String]): Int {
  try {
    yield 1
    yield 2
    yield 3
  } finally {
    log.add("gen finally")
  }
}

async func sumListLiteral(): Int {
  var t = 0
  for x in [1, 2, 3] {
    await Std.Task.delay(5)
    t = t + x
  }
  t
}

async func sumGenerator(): Int {
  var t = 0
  for x in genUpTo(4) {
    await Std.Task.delay(5)
    t = t + x
  }
  t
}

async func sumHalfOpenRange(n: in Int): Int {
  var t = 0
  for i in 0 ..< n {
    await pause()
    t = t + i
  }
  t
}

async func sumClosedRangeAwaitedBound(): Int {
  var t = 0
  for i in 2 ..= await asyncThree() {
    t = t * 10 + i
  }
  t
}

async func joinWords(words: in List[String]): String {
  var acc = ""
  for w in words {
    await pause()
    acc = acc + w + ";"
  }
  acc
}

async func sumSlice(xs: in List[Int]): Int {
  var t = 0
  for x in xs.toArray() {
    await pause()
    t = t + x
  }
  t
}

async func sumSetElements(): Int {
  val s: Set[Int] = newSet()
  s.add(10)
  s.add(20)
  s.add(30)
  var t = 0
  for x in s {
    await pause()
    t = t + x
  }
  t
}

async func sumPairs(pairs: in List[(Int, String)]): String {
  var acc = ""
  for (n, tag) in pairs {
    await pause()
    acc = acc + tag + toString(n)
  }
  acc
}

async func nestedLoops(): Int {
  var t = 0
  for r in [1, 2] {
    await pause()
    for c in 0 ..< 3 {
      await pause()
      t = t + r * 10 + c
    }
  }
  t
}

async func breakAndContinue(): Int {
  var t = 0
  for x in [1, 2, 3, 4, 5, 6] {
    await pause()
    if x == 2 {
      continue
    }
    if x == 5 {
      break
    }
    t = t + x
  }
  t
}

// Two loops bind `x` at different types; each keeps its own field.
async func sameNameDifferentTypes(): String {
  var n = 0
  for x in [4, 5] {
    await pause()
    n = n + x
  }
  var s = ""
  for x in ["a", "b"] {
    await pause()
    s = s + x
  }
  s + toString(n)
}

async func returnFromLoop(): Int {
  for x in [7, 8, 9] {
    await pause()
    if x == 8 {
      return x * 100
    }
  }
  -1
}

async func breakOutOfGuardedGenerator(log: in List[String]): Int {
  var t = 0
  for x in genGuarded(log) {
    await pause()
    log.add("got ${x}")
    t = t + x
    if x == 2 {
      break
    }
  }
  log.add("after loop")
  t
}

// A panic after a real resume leaves the loop by an exception: the disposal
// fault handler marks the loop as unwinding and still disposes the generator.
async func panicAfterResumeInGenerator(log: in List[String]): Int {
  var t = 0
  for x in genGuarded(log) {
    await pause()
    log.add("got ${x}")
    if x == 2 {
      panic("boom at 2")
    }
    t = t + x
  }
  t
}

async func panicAfterResumeInList(log: in List[String]): Int {
  var t = 0
  for x in [1, 2, 3] {
    await pause()
    log.add("got ${x}")
    if x == 2 {
      panic("boom at 2")
    }
    t = t + x
  }
  t
}

// `try` cannot contain an `await` in an `async func` (V0012), so the catching
// frame is an ordinary function, whose `await` blocks until the task settles.
func catchGeneratorLoopPanic(log: in List[String]): String {
  try {
    val _ = await panicAfterResumeInGenerator(log)
    "no panic"
  } catch Bug as e {
    if e.message.contains("boom at 2") {
      "caught"
    } else {
      "wrong message: " + e.message
    }
  }
}

func catchListLoopPanic(log: in List[String]): String {
  try {
    val _ = await panicAfterResumeInList(log)
    "no panic"
  } catch Bug as e {
    if e.message.contains("boom at 2") {
      "caught"
    } else {
      "wrong message: " + e.message
    }
  }
}

// ── `defer` followed by `await` (#7754) ──────────────────────────────────────
// The resume point sits inside the `defer`'s protected region; the region
// dispatch re-enters it, and the deferred block runs once, after the body.
async func deferThenAwait(log: in List[String]): Int {
  defer {
    log.add("deferred")
  }
  log.add("before await")
  await pause()
  log.add("after await")
  42
}

async func twoDefersAroundAwaits(log: in List[String]): String {
  defer {
    log.add("first defer")
  }
  await pause()
  defer {
    log.add("second defer")
  }
  val v = await asyncThree()
  log.add("body ${v}")
  "done"
}

async func deferThenAwaitInLoop(log: in List[String]): Int {
  var t = 0
  for x in [1, 2] {
    defer {
      log.add("defer ${x}")
    }
    await pause()
    t = t + x
  }
  t
}

record AfterAsyncForRecord {
  a: Int
  b: String
}

func joinLog(log: in List[String]): String {
  var s = ""
  var i = 0
  while i < log.count {
    if i > 0 {
      s = s + ","
    }
    s = s + log[i]
    i = i + 1
  }
  s
}

test "for over a list literal: accumulator survives real suspensions (#7766)" {
  val got = await sumListLiteral()
  assertEqualInt(got, 6, "1 + 2 + 3 across a real await per iteration")
}

test "for over a generator: the enumerator survives real suspensions (#7766)" {
  val got = await sumGenerator()
  assertEqualInt(got, 10, "1 + 2 + 3 + 4 across a real await per iteration")
}

test "for over a half-open range: counter and bound survive real suspensions" {
  val got = await sumHalfOpenRange(5)
  assertEqualInt(got, 10, "0 + 1 + 2 + 3 + 4")
}

test "for over a closed range whose bound awaits: the counter survives the bound's suspension" {
  val got = await sumClosedRangeAwaitedBound()
  assertEqualInt(got, 23, "iterates 2, 3 (a lost counter restarts at 0)")
}

test "for over a List[String] parameter: the element binding survives real suspensions" {
  val words: List[String] = newList()
  words.add("alpha")
  words.add("beta")
  words.add("gamma")
  val got = await joinWords(words)
  assertEqual(got, "alpha;beta;gamma;", "every word in order")
}

test "for over a slice: the typed-array fast path survives real suspensions" {
  val xs: List[Int] = newList()
  xs.add(3)
  xs.add(4)
  xs.add(5)
  val got = await sumSlice(xs)
  assertEqualInt(got, 12, "3 + 4 + 5")
}

test "for over a Set: the IEnumerable enumerator survives real suspensions" {
  val got = await sumSetElements()
  assertEqualInt(got, 60, "10 + 20 + 30")
}

test "for with a tuple pattern: both bindings survive real suspensions" {
  val pairs: List[(Int, String)] = newList()
  pairs.add((1, "a"))
  pairs.add((2, "b"))
  val got = await sumPairs(pairs)
  assertEqual(got, "a1b2", "both tuple elements after the await")
}

test "nested for loops each keep their own state across real suspensions" {
  val got = await nestedLoops()
  assertEqualInt(got, 96, "(10+11+12) + (20+21+22)")
}

test "break and continue after a real suspension" {
  val got = await breakAndContinue()
  assertEqualInt(got, 8, "1 + 3 + 4")
}

test "two loops binding the same name at different types keep separate fields" {
  val got = await sameNameDifferentTypes()
  assertEqual(got, "ab9", "String loop then Int loop")
}

test "return from inside a loop after a real suspension" {
  val got = await returnFromLoop()
  assertEqualInt(got, 800, "returns at the second element")
}

test "break out of a generator loop after a real suspension disposes the generator" {
  val log: List[String] = newList()
  val got = await breakOutOfGuardedGenerator(log)
  assertEqualInt(got, 3, "1 + 2")
  assertEqual(joinLog(log), "got 1,got 2,gen finally,after loop", "finally runs once, before the loop is left")
}

test "a panic after a real resume in a generator loop disposes the generator (#7766)" {
  val log: List[String] = newList()
  assertEqual(catchGeneratorLoopPanic(log), "caught", "the panic reaches the caller")
  assertEqual(joinLog(log), "got 1,got 2,gen finally", "the generator's finally ran once, after the panic")
}

test "a panic after a real resume in a list loop propagates" {
  val log: List[String] = newList()
  assertEqual(catchListLoopPanic(log), "caught", "the panic reaches the caller")
  assertEqual(joinLog(log), "got 1,got 2", "the loop stopped at the panic")
}

test "defer followed by a real await runs the deferred block once, after the body (#7754)" {
  val log: List[String] = newList()
  val got = await deferThenAwait(log)
  assertEqualInt(got, 42, "the body's value")
  assertEqual(joinLog(log), "before await,after await,deferred", "event order")
}

test "two defers interleaved with real awaits run in reverse order" {
  val log: List[String] = newList()
  val got = await twoDefersAroundAwaits(log)
  assertEqual(got, "done", "the body's value")
  assertEqual(joinLog(log), "body 3,second defer,first defer", "event order")
}

test "a defer inside a loop body followed by a real await runs every iteration" {
  val log: List[String] = newList()
  val got = await deferThenAwaitInLoop(log)
  assertEqualInt(got, 3, "1 + 2")
  assertEqual(joinLog(log), "defer 1,defer 2", "one defer per iteration")
}

test "a record declared after every async func keeps its field tokens" {
  val r = AfterAsyncForRecord(a = 7, b = "ok")
  assertEqualInt(r.a, 7, "first field")
  assertEqual(r.b, "ok", "second field")
}
