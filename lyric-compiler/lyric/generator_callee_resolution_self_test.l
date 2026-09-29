//! generator_callee_resolution_self_test.l — dual-target runtime regression
//! test for how a `for` loop decides it iterates a generator call (#7771).
//!
//! Since #7750 a generator call's type is the loop's element type, so the
//! checker must know whether the call it is looking at really calls a
//! generator.  It used to decide by the callee's bare name and argument count
//! alone, so any call sharing a generator's name and arity -- a method, a
//! type-associated function, a local function value shadowing the generator
//! -- had its `List[Int]` result read as the loop variable's type, and the
//! loops below were rejected (`s + v` with `v: List[Int]`).  The decision now
//! follows the signature the call actually binds to.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generator_callee_resolution_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generator_callee_resolution_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GeneratorCalleeResolutionSelfTest

import Std.Core
import Std.Collections
import Std.Testing

async func each(n: in Int): Int {
  var i = 1
  while i <= n {
    yield i
    i = i + 1
  }
}

record Bag {
  items: List[Int]
}

func Bag.each(self: in Bag, n: in Int): List[Int] {
  val acc: List[Int] = newList()
  for x in self.items {
    acc.add(x * n)
  }
  acc
}

interface Scaler {
  func each(n: in Int): List[Int]
}

record Scale {
  k: Int
}

impl Scaler for Scale {
  func each(n: in Int): List[Int] {
    val acc: List[Int] = newList()
    acc.add(self.k)
    acc.add(self.k * n)
    acc
  }
}

test "generator callee: the generator itself still yields its elements" {
  var s = 0
  for v in each(4) {
    s = s + v
  }
  assertEqualInt(s, 10, "1 + 2 + 3 + 4")
}

test "generator callee: a type-associated function named like the generator" {
  val items: List[Int] = newList()
  items.add(1)
  items.add(5)
  val bag = Bag(items = items)
  var s = 0
  for v in bag.each(3) {
    s = s + v
  }
  assertEqualInt(s, 18, "1*3 + 5*3")
}

test "generator callee: an impl method named like the generator" {
  val sc = Scale(k = 7)
  var s = 0
  var n = 0
  for v in sc.each(2) {
    s = s + v
    n = n + 1
  }
  assertEqualInt(n, 2, "two elements")
  assertEqualInt(s, 21, "7 + 7*2")
}

test "generator callee: a local function value shadowing the generator" {
  val each = { (n: Int) -> val acc: List[Int] = newList(); acc.add(n); acc.add(n * 100); acc }
  var s = 0
  for v in each(3) {
    s = s + v
  }
  assertEqualInt(s, 303, "3 + 300")
}
