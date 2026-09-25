//! Inline range refinements are checked at runtime (#7226).
//!
//! `Int range 0 ..= 9` erased to `Int` and only a literal initializer was
//! checked (T0015).  A refined parameter, return value, binding or `var`
//! assignment is now a runtime contract that fails with `RangeViolated`.
//! Runs on dotnet and JVM (native has no `assertPanics`).
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
