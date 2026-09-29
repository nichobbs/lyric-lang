//! tuple_pattern_binding_self_test.l — the names a tuple pattern binds carry
//! their element types (#7728, #7730).
//!
//! Both backends represent a tuple as a list of boxed elements.  A name a
//! tuple pattern bound was read back as that boxed object whenever the
//! backend could not see the tuple's element types at the pattern:
//!
//!   * `--target dotnet` silently miscompiled every `for (a, b) in pairs`
//!     loop: the loop bound each element as `object`, so `a + b` added the
//!     boxes' object references (`sumPairs` returned -2147378704, not 3) and
//!     `name + toString(n)` printed a reference.
//!   * `--target jvm` bound every tuple-pattern name as `Object` (`for`,
//!     `val (a, b) = ...` without an annotation, `match`), so an operation
//!     with no typed operand to infer from (`a * b`, `a - b`, `yield a + b`)
//!     failed to compile with J008.
//!
//! The type checker now records the element type of each name a tuple pattern
//! binds (`SymbolTable.tuplePatternBindingSites`), and
//! `Lyric.Mono.desugarCheckedFile` binds the pattern position to a fresh name
//! and the source name to a local annotated with that type.  Every case below
//! uses the bindings directly in arithmetic, comparison or string
//! concatenation, with no annotated local or typed parameter in between.
//!
//! Runs on both targets:
//!   lyric test --target dotnet lyric-compiler/lyric/tuple_pattern_binding_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/tuple_pattern_binding_self_test.l
@test_module
package Lyric.TuplePatternBindingSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func sumPairsLocal(): Int {
  val pairs: List[(Int, Int)] = [(1, 2), (30, 40)]
  var t = 0
  for (a, b) in pairs {
    t = t + a + b
  }
  t
}

func sumPairsParam(pairs: in List[(Int, Int)]): Int {
  var t = 0
  for (a, b) in pairs {
    t = t + a * b
  }
  t
}

func countGreater(pairs: in List[(Int, Int)]): Int {
  var n = 0
  for (a, b) in pairs {
    if a > b {
      n = n + 1
    }
  }
  n
}

func joinNamed(pairs: in List[(String, Int)]): String {
  var s = ""
  for (name, n) in pairs {
    s = s + name + "=" + toString(n + 1) + ";"
  }
  s
}

func sumLongDouble(pairs: in List[(Long, Double)]): Double {
  var total = 0.0
  var big = 0i64
  for (l, d) in pairs {
    big = big + l * 2i64
    total = total + d * 2.0
  }
  total + big.toDouble()
}

func sumNestedFor(items: in List[((Int, Int), Int)]): Int {
  var t = 0
  for ((a, b), c) in items {
    t = t + a * 100 + b * 10 + c
  }
  t
}

func destructureVal(pair: in (Int, Int)): Int {
  val (a, b) = pair
  a * 10 + b
}

func destructureValStrInt(pair: in (String, Int)): String {
  val (s, n) = pair
  s + s + toString(n * 3)
}

func destructureValLongDouble(pair: in (Long, Double)): Bool {
  val (l, d) = pair
  l * 3i64 == 30i64 and d + 0.5 > 2.0
}

func destructureNestedVal(v: in ((Int, Int), String)): String {
  val ((a, b), s) = v
  s + toString(a + b)
}

func matchPair(pair: in (Int, Int)): Int {
  match pair {
    case (0, b) -> b + 1000
    case (a, b) -> a - b
  }
}

func matchStrInt(pair: in (String, Int)): String {
  match pair {
    case (s, n) -> s + ":" + toString(n + n)
  }
}

func matchNested(v: in ((Int, Int), Int)): Int {
  match v {
    case ((a, b), c) -> a * b + c
  }
}

func matchGuard(pair: in (Int, Int)): Int {
  match pair {
    case (a, b) if a > b -> a - b
    case (a, b) -> a * b
  }
}

func matchOr(pair: in (Int, Int)): Int {
  match pair {
    case (0, x) | (x, 0) -> x + 1
    case (a, b) -> a + b
  }
}

record Pt {
  x: Int
  y: Int
}

func sumRecordPairs(items: in List[(Pt, Int)]): Int {
  var t = 0
  for (p, k) in items {
    t = t + p.x * k + p.y
  }
  t
}

func sumOptionPairs(items: in List[(Option[Int], Int)]): Int {
  var t = 0
  for (o, k) in items {
    t = t + k + match o { case Some(v) -> v * 10; case None -> 0 }
  }
  t
}

func closureSum(pairs: in List[(Int, Int)]): Int {
  val f = { ps: List[(Int, Int)] -> var t = 0; for (a, b) in ps { t = t + a + b }; t }
  f(pairs)
}

func closureMatch(pair: in (Long, Double)): Double {
  val f = { p: (Long, Double) -> match p { case (l, d) -> (l + 1i64).toDouble() + d } }
  f(pair)
}

async func genPairSums(pairs: in List[(Int, Int)]): Int {
  for (a, b) in pairs {
    yield a + b
  }
}

async func genNamed(pairs: in List[(String, Int)]): String {
  for (name, n) in pairs {
    yield name + toString(n * 2)
  }
}

async func genPairs(n: in Int): (Int, Int) {
  for i in 1 ..= n {
    yield (i, i * 10)
  }
}

func sumGeneratedPairs(n: in Int): Int {
  var t = 0
  for (a, b) in genPairs(n) {
    t = t + a * b
  }
  t
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

test "for (a, b) over a local List[(Int, Int)]" {
  assertEqualInt(sumPairsLocal(), 73, "1 + 2 + 30 + 40")
}

test "for (a, b) over a List[(Int, Int)] parameter" {
  val pairs: List[(Int, Int)] = [(2, 3), (4, 5)]
  assertEqualInt(sumPairsParam(pairs), 26, "2 * 3 + 4 * 5")
}

test "for (a, b): comparison on the bindings" {
  val pairs: List[(Int, Int)] = [(5, 1), (1, 5), (9, 8)]
  assertEqualInt(countGreater(pairs), 2, "two pairs with a > b")
}

test "for (name, n) over a List[(String, Int)]" {
  val pairs: List[(String, Int)] = [("x", 1), ("yy", 41)]
  assertEqual(joinNamed(pairs), "x=2;yy=42;", "concatenation and Int arithmetic")
}

test "for (l, d) over a List[(Long, Double)]" {
  val pairs: List[(Long, Double)] = [(3i64, 0.25), (4i64, 1.5)]
  assertTrue(sumLongDouble(pairs) == 17.5, "(0.25 + 1.5) * 2 + (3 + 4) * 2")
}

test "for ((a, b), c): nested tuple pattern" {
  val items: List[((Int, Int), Int)] = [((1, 2), 3), ((4, 5), 6)]
  assertEqualInt(sumNestedFor(items), 579, "123 + 456")
}

test "val (a, b) = pair" {
  assertEqualInt(destructureVal((4, 2)), 42, "4 * 10 + 2")
}

test "val (s, n) = (String, Int)" {
  assertEqual(destructureValStrInt(("ab", 5)), "abab15", "concatenation and Int arithmetic")
}

test "val (l, d) = (Long, Double)" {
  assertTrue(destructureValLongDouble((10i64, 1.75)), "Long and Double arithmetic")
}

test "val ((a, b), s): nested tuple pattern" {
  assertEqual(destructureNestedVal(((20, 22), "n")), "n42", "nested Int sum")
}

test "match tuple pattern on (Int, Int)" {
  assertEqualInt(matchPair((0, 7)), 1007, "literal arm binds b")
  assertEqualInt(matchPair((9, 4)), 5, "binding arm subtracts")
}

test "match tuple pattern on (String, Int)" {
  assertEqual(matchStrInt(("k", 21)), "k:42", "concatenation and Int arithmetic")
}

test "match nested tuple pattern" {
  assertEqualInt(matchNested(((6, 7), 0)), 42, "6 * 7 + 0")
}

test "match tuple pattern with a guard on the bindings" {
  assertEqualInt(matchGuard((9, 4)), 5, "guard true: 9 - 4")
  assertEqualInt(matchGuard((3, 4)), 12, "guard false: 3 * 4")
}

test "match or-pattern of tuple patterns" {
  assertEqualInt(matchOr((0, 6)), 7, "first alternative")
  assertEqualInt(matchOr((8, 0)), 9, "second alternative")
  assertEqualInt(matchOr((2, 3)), 5, "fallback arm")
}

test "for (p, k) over a List[(Pt, Int)]: record element" {
  val items: List[(Pt, Int)] = [(Pt(x = 2, y = 1), 10), (Pt(x = 3, y = 5), 2)]
  assertEqualInt(sumRecordPairs(items), 32, "2 * 10 + 1 + 3 * 2 + 5")
}

test "for (o, k) over a List[(Option[Int], Int)]: union element" {
  val none: Option[Int] = None
  val items: List[(Option[Int], Int)] = [(Some(value = 4), 1), (none, 2)]
  assertEqualInt(sumOptionPairs(items), 43, "4 * 10 + 1 + 2")
}

test "for (a, b) inside a closure" {
  val pairs: List[(Int, Int)] = [(10, 20), (5, 7)]
  assertEqualInt(closureSum(pairs), 42, "10 + 20 + 5 + 7")
}

test "match tuple pattern inside a closure" {
  assertTrue(closureMatch((2i64, 0.5)) == 3.5, "(2 + 1) + 0.5")
}

test "async generator: yield a + b" {
  val pairs: List[(Int, Int)] = [(1, 2), (30, 40)]
  val got: List[Int] = newList()
  for x in genPairSums(pairs) {
    got.add(x)
  }
  assertEqual(joinInts(got), "3,70", "pair sums")
}

test "async generator: yield name + toString(n * 2)" {
  val pairs: List[(String, Int)] = [("a", 1), ("b", 21)]
  var s = ""
  for w in genNamed(pairs) {
    s = s + w
  }
  assertEqual(s, "a2b42", "concatenation per pair")
}

test "for (a, b) over an async generator yielding tuples" {
  assertEqualInt(sumGeneratedPairs(3), 140, "1 * 10 + 2 * 20 + 3 * 30")
}
