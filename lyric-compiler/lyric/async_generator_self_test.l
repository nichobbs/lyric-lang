//! async_generator_self_test.l — regression tests for `async func` generator
//! synthesis via IAsyncEnumerable<object> (Phase 5, Epic #2070, D092).
//!
//! Each `async func` whose body contains `yield` is compiled into a synthesised
//! generator class `<FuncName>__Gen_N` that implements:
//!   IAsyncEnumerable<object>, IAsyncEnumerator<object>, IAsyncDisposable.
//!
//! Eager-producer pattern: the kickoff function allocates the generator,
//! initialises `_values = new List<object>()`, copies user params to fields,
//! calls `RunBody()` to eagerly collect all yields, then returns `this` as
//! `IAsyncEnumerable<object>`.  Consumers use `for x in gen() { ... }`.
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
