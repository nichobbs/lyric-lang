//! Inline range refinements are checked at runtime (#7226).
//!
//! `Int range 0 ..= 9` erased to `Int` and only a literal initializer was
//! checked (T0015).  A refined parameter, return value, binding or `var`
//! assignment is now a runtime contract that fails with `RangeViolated`.
//! So is a value reaching a range type anywhere else (#8031): a record or
//! union field, a `.copy` argument, a field or element assignment, a
//! collection element and an argument through a function value.
//! Runs on dotnet and JVM (native has no `assertPanics`;
//! `scripts/ci/range-refinement-e2e.sh` runs the panics on every target).
@test_module
package RangeRefinementSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func double(d: in Int range 0 ..= 9): Int = d * 2

func tenth(x: in Int): Int range 0 .. 10 {
  x
}

func probability(p: in Double range 0.0 ..= 1.0): Double = p

func bigCount(n: in Long range 0i64 ..= 5000000000i64): Long = n

func bindNonLiteral(n: in Int): Int {
  val v: Int range 1 ..= 5 = n
  v
}

func countTo(limit: in Int): Int {
  var c: Int range 0 ..= 3 = 0
  var i = 0
  while i < limit {
    c = c + 1
    i = i + 1
  }
  c
}

func compoundAdd(k: in Int): Int {
  var c: Int range 0 ..= 3 = 0
  c += k
  c
}

func shadowed(): Int {
  var c: Int range 0 ..= 3 = 0
  if c == 0 {
    var c = 100
    c = 200
    return c
  }
  c
}

func viaLambda(v: in Int): Int {
  var c: Int range 0 ..= 3 = 0
  val set = { -> c = v }
  set()
  c
}

// The same assignment through a lambda held in a list: the pass used to skip
// list, tuple, index and interpolation forms entirely (#7398).
func viaListedLambda(v: in Int): Int {
  var c: Int range 0 ..= 3 = 0
  val hs = [{ -> c = v }]
  hs[0]()
  c
}

// A name redeclared in the same block must not break the pass: the second
// `var` replaces the first (the self-hosted MSIL writer does exactly this).
func redeclared(): Int {
  var k = 1
  k = k + 1
  var k = 10
  k = k + 1
  k
}

func redeclaredRefined(): Int {
  var k: Int range 0 ..= 3 = 1
  var k = 100
  k = 200
  k
}

test "a name redeclared in the same block" {
  assertTrue(redeclared() == 11, "second var replaces the first")
  assertTrue(redeclaredRefined() == 200, "an unrefined redeclaration drops the range")
}

test "a refined parameter is checked on entry" {
  assertTrue(double(9) == 18, "9 is in 0 ..= 9")
  assertPanics("10 is outside 0 ..= 9", { -> val _ = double(10) })
  assertPanics("-1 is outside 0 ..= 9", { -> val _ = double(-1) })
}

test "a refined return type is checked" {
  assertTrue(tenth(9) == 9, "9 is in 0 .. 10")
  assertPanics("10 is outside the half-open 0 .. 10", { -> val _ = tenth(10) })
}

test "Double and Long refinements" {
  assertTrue(probability(0.5) == 0.5, "0.5 is in 0.0 ..= 1.0")
  assertPanics("1.5 is outside 0.0 ..= 1.0", { -> val _ = probability(1.5) })
  assertPanics("NaN is in no range", { -> val _ = probability(0.0 / 0.0) })
  assertTrue(bigCount(4000000000i64) == 4000000000i64, "Long in range")
  assertPanics("Long above range", { -> val _ = bigCount(6000000000i64) })
}

test "a refined binding with a non-literal initializer is checked" {
  assertTrue(bindNonLiteral(5) == 5, "5 is in 1 ..= 5")
  assertPanics("6 is outside 1 ..= 5", { -> val _ = bindNonLiteral(6) })
}

test "every assignment to a refined var is checked" {
  assertTrue(countTo(3) == 3, "three increments stay in 0 ..= 3")
  assertPanics("the fourth increment leaves 0 ..= 3", { -> val _ = countTo(4) })
  assertTrue(compoundAdd(2) == 2, "c += 2")
  assertPanics("c += 5 leaves 0 ..= 3", { -> val _ = compoundAdd(5) })
}

test "a shadowing binding is not checked against the outer range" {
  assertTrue(shadowed() == 200, "inner unrefined var")
}

test "a lambda assigning a captured refined var is checked" {
  assertTrue(viaLambda(2) == 2, "2 is in range")
  assertPanics("9 is outside 0 ..= 3", { -> val _ = viaLambda(9) })
}

test "an assignment inside a list literal is checked (#7398)" {
  assertTrue(viaListedLambda(3) == 3, "3 is in range")
  assertPanics("99 is outside 0 ..= 3 (list)", { -> val _ = viaListedLambda(99) })
}

val maxSteps: Int = 3

record Slot {
  i: Int range 0 ..= 3
}

record Dial {
  var level: Int range 0 ..= 3
}

record Bounded {
  n: Int range 0 ..= maxSteps
  big: Long range 0i64 ..= 5000000000i64
  p: Double range 0.0 ..= 1.0
}

union Cmd {
  case Move(steps: Int range 0 ..= 3)
  case Stop
}

func ten(): Int = 10

func two(): Int = 2

func stepsOf(c: in Cmd): Int {
  match c {
    case Move(s) -> s
    case Stop -> 0
  }
}

test "a record field is checked at construction (#8031)" {
  assertTrue(Slot(i = two()).i == 2, "2 is in 0 ..= 3")
  assertPanics("10 is outside 0 ..= 3 (named)", { -> val _ = Slot(i = ten()) })
  assertPanics("a named bound is folded", { -> val _ = Bounded(n = ten(), big = 1i64, p = 0.5) })
  assertPanics("a Long field", { -> val _ = Bounded(n = 1, big = 6000000000i64, p = 0.5) })
  assertPanics("a Double field", { -> val _ = Bounded(n = 1, big = 1i64, p = 1.5) })
  assertTrue(Bounded(n = 3, big = 5000000000i64, p = 1.0).n == 3, "every bound is inclusive")
}

test "a copy argument is checked (#8031)" {
  val s = Slot(i = 1)
  assertTrue(s.copy(i = two()).i == 2, "2 is in range")
  assertPanics("10 is outside 0 ..= 3 (copy)", { -> val _ = s.copy(i = ten()) })
}

test "a var field assignment is checked (#8031)" {
  val d = Dial(level = 0)
  d.level = two()
  d.level += 1
  assertTrue(d.level == 3, "2 + 1 is in range")
  assertPanics("assigning 10", { -> d.level = ten() })
  assertPanics("3 + 1 leaves 0 ..= 3", { -> d.level += 1 })
}

test "a union case payload is checked (#8031)" {
  assertTrue(stepsOf(Move(steps = two())) == 2, "2 is in range")
  assertPanics("10 is outside 0 ..= 3 (payload)", { -> val _ = Move(steps = ten()) })
}

test "an argument through a function value is checked (#8031)" {
  val f = { k: Int range 0 ..= 3 -> k * 2 }
  assertTrue(f(two()) == 4, "2 is in range")
  assertPanics("10 is outside 0 ..= 3 (lambda)", { -> val _ = f(ten()) })
}

test "collection elements are checked (#8031)" {
  var xs: List[Int range 0 ..= 3] = [1, two()]
  xs.add(3)
  assertTrue(xs.count == 3, "three elements in range")
  assertPanics("adding 10", { -> xs.add(ten()) })
  assertPanics("assigning 10 to an element", { -> xs[0] = ten() })
  assertPanics("a literal element", { -> val ys: List[Int range 0 ..= 3] = [ten()]; val _ = ys.count })
}

test "a generic payload is checked against a range instantiation (#8031)" {
  val ok: Option[Int range 0 ..= 3] = Some(two())
  assertTrue(ok == Some(2), "2 is in range")
  assertPanics(
    "Some(10) for Option[Int range 0 ..= 3]",
    { -> val bad: Option[Int range 0 ..= 3] = Some(ten()); val _ = bad }
  )
  var m: Map[String, Int range 0 ..= 3] = newMap()
  m.add("a", two())
  assertPanics("a map value", { -> m.add("b", ten()) })
}

test "a tuple element is checked against its range (#8031)" {
  val ok: (Int range 0 ..= 3, String) = (two(), "a")
  val (n, _) = ok
  assertTrue(n == 2, "2 is in range")
  assertPanics("a tuple element of 10", { -> val bad: (Int range 0 ..= 3, String) = (ten(), "a"); val _ = bad })
}

record Duo[A, B] {
  wide: A
  narrow: B
}

func okLong(r: in Result[Long, Int range 0 ..= 3]): Long {
  match r {
    case Ok(v) -> v
    case Err(_) -> -1i64
  }
}

test "a construction that widens one slot checks the range of another (#7813, #8031)" {
  val ok: (Long, Int range 0 ..= 3) = (two(), two())
  val (w, n) = ok
  assertTrue(w == 2i64 and n == 2, "the Int widens and the range holds")
  assertPanics(
    "a tuple element of 10 beside a widened one",
    { -> val bad: (Long, Int range 0 ..= 3) = (two(), ten()); val _ = bad }
  )
  val duo: Duo[Long, Int range 0 ..= 3] = Duo(wide = two(), narrow = two())
  assertTrue(duo.wide == 2i64 and duo.narrow == 2, "a generic record field widens beside a range")
  assertPanics(
    "a generic record field of 10 beside a widened one",
    { -> val bad: Duo[Long, Int range 0 ..= 3] = Duo(wide = two(), narrow = ten()); val _ = bad }
  )
  val r: Result[Long, Int range 0 ..= 3] = Ok(two())
  assertTrue(okLong(r) == 2i64, "an Ok payload widens where the Err type is a range")
  assertPanics(
    "an Err payload of 10 where Ok widens",
    { -> val bad: Result[Long, Int range 0 ..= 3] = Err(ten()); val _ = bad }
  )
  val q: Result[Long, Int range 0 ..= 3] = Result.Ok(two())
  assertTrue(okLong(q) == 2i64, "a qualified Ok payload widens")
  assertPanics(
    "a qualified Err payload of 10",
    { -> val bad: Result[Long, Int range 0 ..= 3] = Result.Err(ten()); val _ = bad }
  )
}
