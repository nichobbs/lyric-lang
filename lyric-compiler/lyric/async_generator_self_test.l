//! async_generator_self_test.l — regression tests for `async func` generator
//! synthesis via IAsyncEnumerable<object> (Phase 5, Epic #2070, D092).
//!
//! Each `async func` whose body contains `yield` is compiled into a synthesised
//! generator class `<FuncName>__Gen_N` that implements:
//!   IAsyncEnumerable<object>, IAsyncEnumerator<object>, IAsyncDisposable.
//!
//! Lazy-producer state machine (D119, verified): the kickoff allocates the
//! generator (state = -1) and copies user params to fields.  Each `MoveNextAsync`
//! creates a fresh `TaskCompletionSource<bool>`, drives `MoveNext` one step, and
//! returns `new ValueTask<bool>(_tcs.Task)`; each `yield e` stores `box(e)` in
//! `__current`, updates `_state`, calls `_tcs.SetResult(true)`, and leaves the
//! try — so only one value is materialised at a time and infinite/large
//! yield-only sequences stream without buffering.  Consumers use
//! `for x in gen() { ... }`.  (The earlier eager "RunBody collects all yields"
//! model is legacy/dead; see D119.)
//!
//!   lyric test lyric-compiler/lyric/async_generator_self_test.l
@test_module
package Lyric.AsyncGeneratorSelfTest

import Std.Core
import Std.Testing

// ── Basic: zero-param generator with three yields ─────────────────────────────
async func genThree(): Int {
  yield 1
  yield 2
  yield 3
}

test "generator: for-loop collects all three yielded values" {
  var sum = 0
  for x in genThree() {
    sum = sum + 1
  }
  assertEqualInt(sum, 3, "genThree() should yield exactly 3 items")
}

test "generator: yielded values are integers 1..3" {
  val result: List[Int] = newList()
  for x in genThree() {
    result.add(x)
  }
  assertEqualInt(result.count, 3, "should have 3 items")
  assertEqualInt(result[0], 1, "first yield should be 1")
  assertEqualInt(result[1], 2, "second yield should be 2")
  assertEqualInt(result[2], 3, "third yield should be 3")
}

// ── Generator with one parameter ──────────────────────────────────────────────
async func genUpTo(n: in Int): Int {
  var i = 1
  while i <= n {
    yield i
    i = i + 1
  }
}

test "generator with param: genUpTo(4) yields 1..4" {
  val result: List[Int] = newList()
  for x in genUpTo(4) {
    result.add(x)
  }
  assertEqualInt(result.count, 4, "genUpTo(4) should yield 4 items")
  assertEqualInt(result[0], 1, "first should be 1")
  assertEqualInt(result[3], 4, "last should be 4")
}

test "generator with param: genUpTo(0) yields nothing" {
  var count = 0
  for x in genUpTo(0) {
    count = count + 1
  }
  assertEqualInt(count, 0, "genUpTo(0) should yield nothing")
}

// ── Generator with two params ─────────────────────────────────────────────────
async func genRange(from: in Int, to: in Int): Int {
  var i = from
  while i <= to {
    yield i
    i = i + 1
  }
}

test "generator with two params: genRange(3, 6) yields 3..6" {
  val result: List[Int] = newList()
  for x in genRange(3, 6) {
    result.add(x)
  }
  assertEqualInt(result.count, 4, "genRange(3,6) should yield 4 items")
  assertEqualInt(result[0], 3, "first should be 3")
  assertEqualInt(result[3], 6, "last should be 6")
}

// ── String generator ──────────────────────────────────────────────────────────
async func genWords(): String {
  yield "alpha"
  yield "beta"
  yield "gamma"
}

test "generator: string values yielded correctly" {
  val words: List[String] = newList()
  for w in genWords() {
    words.add(w)
  }
  assertEqualInt(words.count, 3, "genWords() should yield 3 strings")
  assertEqual(words[0], "alpha", "first word should be alpha")
  assertEqual(words[1], "beta", "second word should be beta")
  assertEqual(words[2], "gamma", "third word should be gamma")
}

// ── Sum via for-in loop over generator ───────────────────────────────────────
test "generator: sum of genUpTo(5) is 15" {
  var total = 0
  for x in genUpTo(5) {
    total = total + x
  }
  assertEqualInt(total, 15, "1+2+3+4+5 should be 15")
}

// ── #2480: mixed generator + non-generator async in the same package ──────────
// A package that contains both a yield-bearing async func (generator) and a
// non-yield async func (state-machine) in the same file.  If the SM and
// generator MethodDef pre-scan counts are computed in the wrong order, or the
// generator/SM distinction changes, IFunc token assignments shift silently.
// This test exercises both paths in the same package and asserts their output.
async func asyncAddTwo2(n: in Int): Int {
  val a = n + 1
  val b = a + 1
  b
}

async func genEvens(n: in Int): Int {
  var i = 0
  while i < n {
    yield i * 2
    i = i + 1
  }
}

test "#2480: SM async func and generator in the same package both work" {
  // Non-generator path: asyncAddTwo2 resolves as a state-machine async
  val sm = await asyncAddTwo2(5)
  assertEqualInt(sm, 7, "asyncAddTwo2(5) should return 7")
  // Generator path: genEvens yields 0, 2, 4 for n=3
  val evens: List[Int] = newList()
  for x in genEvens(3) {
    evens.add(x)
  }
  assertEqualInt(evens.count, 3, "genEvens(3) should yield 3 items")
  assertEqualInt(evens[0], 0, "genEvens first item = 0")
  assertEqualInt(evens[1], 2, "genEvens second item = 2")
  assertEqualInt(evens[2], 4, "genEvens third item = 4")
}

// ── #4259: generator FieldDef ordering — generator func before record ────────
// Regression: Pass 1's `isGenP1` branch in `addPackageTokens` advanced
// `methodDefRow` (+7) for a generator class's synthesised methods but never
// advanced `fieldDefRow` for its FieldDef rows (`_state`, `_tcs`, `__current`,
// `__pN` params, hoisted body locals) — the generator analog of #4187 (async
// state-machine classes).  Any `IRecord` defined AFTER a generator function in
// source order received wrong `cctx.fieldTokens` entries, mis-binding its
// field reads/writes to the generator class's own fields instead.
async func genBeforeRecordHelper(n: in Int): Int {
  var i = 0
  while i < n {
    yield i
    i = i + 1
  }
}

record RecordAfterGen {
  x: Int
  y: Int
}

async func genAfterRecord(n: in Int): Int {
  var i = 0
  while i < n {
    yield i * 2
    i = i + 1
  }
}

record SecondRecordAfterGen {
  a: Int
  b: String
}

test "#4259: record field access after generator class in source order" {
  val r = RecordAfterGen(x = 3, y = 7)
  assertEqualInt(r.x, 3, "RecordAfterGen.x = 3")
  assertEqualInt(r.y, 7, "RecordAfterGen.y = 7")
}

test "#4259: second record field access after two generator classes" {
  val s = SecondRecordAfterGen(a = 42, b = "hello")
  assertEqualInt(s.a, 42, "SecondRecordAfterGen.a = 42")
  assertEqual(s.b, "hello", "SecondRecordAfterGen.b = hello")
}

test "#4259: record fields remain correct alongside generator functions" {
  val r = RecordAfterGen(x = 100, y = 200)
  val s = SecondRecordAfterGen(a = r.x + r.y, b = "sum")
  assertEqualInt(s.a, 300, "sum of RecordAfterGen fields = 300")
  assertEqual(s.b, "sum", "SecondRecordAfterGen.b = sum")
}

test "#4259: generator function between records still yields correctly" {
  val result: List[Int] = newList()
  for x in genAfterRecord(3) {
    result.add(x)
  }
  assertEqualInt(result.count, 3, "genAfterRecord(3) should yield 3 items")
  assertEqualInt(result[0], 0, "first item = 0")
  assertEqualInt(result[2], 4, "third item = 4")
}

test "#4259: generator function preceding a record executes correctly" {
  val result: List[Int] = newList()
  for x in genBeforeRecordHelper(3) {
    result.add(x)
  }
  assertEqualInt(result.count, 3, "genBeforeRecordHelper(3) should yield 3 items")
  assertEqualInt(result[0], 0, "first item = 0")
  assertEqualInt(result[2], 2, "third item = 2")
}

// ── #5582: generator body using plain `val` bindings, then a record ──────────
// The #4259 field-count predictor (`countGenLocalsStmt`) originally counted
// `let`/`var` slots but not `val` slots, so a generator whose body binds with
// the common `val` form under-predicted its hoisted `__local_` fields and
// tripped the field-count cross-check panic at build time.  Generator
// synthesis hoists every body slot by index regardless of binding form, so
// this generator (three `val`s) plus a following record must build and run.
async func genWithVals(n: in Int): Int {
  val base = n * 10
  val step = 2
  val cap = base + step + step
  var i = base
  while i <= cap {
    yield i
    i = i + step
  }
}

record RecordAfterValGen {
  p: Int
  q: String
}

test "#5582: generator with val bindings builds and yields, record after it is correct" {
  val result: List[Int] = newList()
  for x in genWithVals(1) {
    result.add(x)
  }
  assertEqualInt(result.count, 3, "genWithVals(1) yields 10, 12, 14")
  assertEqualInt(result[0], 10, "first yielded value = base = 10")
  assertEqualInt(result[2], 14, "third yielded value = cap = 14")
  val r = RecordAfterValGen(p = 5, q = "ok")
  assertEqualInt(r.p, 5, "RecordAfterValGen.p reads correctly after a val-using generator")
  assertEqual(r.q, "ok", "RecordAfterValGen.q reads correctly after a val-using generator")
}
