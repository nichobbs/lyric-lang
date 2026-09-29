//! generator_for_loop_self_test.l — dual-target runtime regression test for
//! `for` loops inside an async generator body (#7718).
//!
//! A `for` loop in a generator body failed on both backends, with or without
//! closures:
//!
//!   * `--target dotnet` panicked at compile time in `synthesizeGeneratorMsil`'s
//!     field-count cross-check: Pass 1's `countGeneratorFieldsMsil` counted
//!     neither the loop protocol's hidden temporaries (counter, bound, list,
//!     element, ...) nor the loop pattern's bindings, all of which the generator
//!     hoists to fields.  The protocol temporaries are now declared once in
//!     `forProtocolTempSlotsMsil`, checked against the real allocation on every
//!     `for` the compiler lowers, and the prediction is an upper bound the
//!     generator class is padded up to (the collection protocol follows the
//!     iterable's lowered type, which Pass 1 does not have).
//!   * `--target jvm` built, then failed class verification
//!     (`VerifyError: Expecting to find integer on stack` in `$Gen.run`): the
//!     generator body never recorded its parameters' declared element types, so
//!     a `for x in items` over a `List[Int]` parameter bound `x` as erased
//!     `Object`, and `yield x` handed that reference to the `Integer.valueOf(I)`
//!     box the generator applies by its declared element type.  The generator
//!     body now records parameter metadata as an ordinary function does, and
//!     `yield` coerces its operand to the element type before boxing.
//!
//! The cases cover a `for` over a `List[Int]` and a `List[String]` parameter,
//! half-open and closed ranges, nested loops, `break` after a yield,
//! `continue`, a tuple pattern, loops over a map's keys and entries, a loop over
//! another generator, a loop-carried accumulator, and a record declared after
//! every generator (its field tokens are only right if each generator's Pass-1
//! prediction held).
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generator_for_loop_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generator_for_loop_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GeneratorForLoopSelfTest

import Std.Core
import Std.Collections
import Std.Testing

async func genFromInts(items: in List[Int]): Int {
  for it in items {
    yield it * 2
  }
}

async func genFromStrings(words: in List[String]): String {
  for w in words {
    yield w + "!"
  }
}

async func genHalfOpen(n: in Int): Int {
  for i in 0 ..< n {
    yield i
  }
}

async func genClosed(lo: in Int, hi: in Int): Int {
  for i in lo ..= hi {
    yield i * i
  }
}

async func genNested(rows: in List[Int], cols: in Int): Int {
  for r in rows {
    for c in 0 ..< cols {
      yield r * 10 + c
    }
  }
}

async func genBreakAfterYield(items: in List[Int], stop: in Int): Int {
  for it in items {
    yield it
    if it == stop {
      break
    }
  }
  yield -1
}

async func genSkipOdd(n: in Int): Int {
  for i in 1 ..= n {
    if i % 2 == 1 {
      continue
    }
    yield i
  }
}

func addPair(a: in Int, b: in Int): Int {
  a + b
}

async func genTuplePattern(pairs: in List[(Int, Int)]): Int {
  for (a, b) in pairs {
    yield addPair(a, b)
  }
}

async func genMapKeys(m: in Map[String, Int]): String {
  for k in mapKeys(m) {
    yield k
  }
}

async func genMapEntries(m: in Map[String, Int]): Int {
  for e in mapEntries(m) {
    yield e.value
  }
}

async func genInner(n: in Int): Int {
  for i in 1 ..= n {
    yield i
  }
}

async func genOverGenerator(n: in Int): Int {
  for v in genInner(n) {
    yield v * 100
  }
}

async func genRunningTotal(items: in List[Int]): Int {
  var total = 0
  for it in items {
    total = total + it
    yield total
  }
  yield total * 10
}

func joinInts(xs: in List[Int]): String {
  var s = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      s = s + ","
    }
    s = s + toString(xs[i])
    i = i + 1
  }
  s
}

func intList(a: in Int, b: in Int, c: in Int): List[Int] {
  val xs: List[Int] = newList()
  xs.add(a)
  xs.add(b)
  xs.add(c)
  xs
}

test "generator for: over a List[Int] parameter" {
  val got: List[Int] = newList()
  for x in genFromInts(intList(1, 2, 3)) {
    got.add(x)
  }
  assertEqual(joinInts(got), "2,4,6", "doubled list elements")
}

test "generator for: over a List[String] parameter" {
  val words: List[String] = newList()
  words.add("a")
  words.add("bc")
  var s = ""
  for w in genFromStrings(words) {
    s = s + w
  }
  assertEqual(s, "a!bc!", "suffixed words in order")
}

test "generator for: half-open range" {
  val got: List[Int] = newList()
  for x in genHalfOpen(4) {
    got.add(x)
  }
  assertEqual(joinInts(got), "0,1,2,3", "0 ..< 4")
}

test "generator for: closed range" {
  val got: List[Int] = newList()
  for x in genClosed(2, 4) {
    got.add(x)
  }
  assertEqual(joinInts(got), "4,9,16", "squares over 2 ..= 4")
}

test "generator for: nested loops" {
  val got: List[Int] = newList()
  for x in genNested(intList(1, 2, 3), 2) {
    got.add(x)
  }
  assertEqual(joinInts(got), "10,11,20,21,30,31", "row-major pairs")
}

test "generator for: break after a yield, then code after the loop" {
  val got: List[Int] = newList()
  for x in genBreakAfterYield(intList(5, 6, 7), 6) {
    got.add(x)
  }
  assertEqual(joinInts(got), "5,6,-1", "stops at 6, then the trailing yield")
}

test "generator for: continue skips to the next iteration" {
  val got: List[Int] = newList()
  for x in genSkipOdd(7) {
    got.add(x)
  }
  assertEqual(joinInts(got), "2,4,6", "even values only")
}

test "generator for: tuple pattern" {
  val pairs: List[(Int, Int)] = newList()
  pairs.add((1, 2))
  pairs.add((30, 40))
  val got: List[Int] = newList()
  for x in genTuplePattern(pairs) {
    got.add(x)
  }
  assertEqual(joinInts(got), "3,70", "pair sums")
}

test "generator for: over a map's keys and entries" {
  val m: Map[String, Int] = newMap()
  m.add("k", 7)
  var keys = ""
  for k in genMapKeys(m) {
    keys = keys + k
  }
  assertEqual(keys, "k", "the single key")
  val got: List[Int] = newList()
  for v in genMapEntries(m) {
    got.add(v)
  }
  assertEqual(joinInts(got), "7", "the single entry's value")
}

test "generator for: over another generator" {
  val got: List[Int] = newList()
  for x in genOverGenerator(3) {
    got.add(x)
  }
  assertEqual(joinInts(got), "100,200,300", "inner values scaled")
}

test "generator for: loop-carried accumulator across yields" {
  val got: List[Int] = newList()
  for x in genRunningTotal(intList(2, 3, 5)) {
    got.add(x)
  }
  assertEqual(joinInts(got), "2,5,10,100", "running total then total * 10")
}

// Declared after every generator above: its field tokens are only right if
// each generator's Pass-1 field-count prediction held.
record AfterForLoopGenerators {
  a: Int
  b: String
}

test "generator for: a record declared after the generators" {
  val rec = AfterForLoopGenerators(a = 11, b = "ok")
  assertEqualInt(rec.a, 11, "record field a after for-loop generators")
  assertEqual(rec.b, "ok", "record field b after for-loop generators")
}
