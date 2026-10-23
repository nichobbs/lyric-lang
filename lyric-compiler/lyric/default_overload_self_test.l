//! A call that resolves only through default arguments binds the overload
//! that fills the fewest defaults, on every target (#8355, #8077).
//!
//! The checker used to overwrite one `sigs[name]` slot, so a call that no
//! overload took exactly bound whichever was declared last, and dotnet then
//! emitted a call to the other overload's token (an `InvalidProgramException`).
//! The rule (decided by the repo owner, 2026-10-23, docs/decisions/D208): among
//! the declarations a call fits (named arguments by name, the rest in order,
//! every parameter left out having a default) whose parameter types the
//! arguments satisfy, a call that supplies every parameter wins, then the
//! declaration that leaves the fewest to their defaults.  The checker records
//! the declaration it chose and every backend calls that one.  Free functions,
//! record and `impl` methods and dot-named functions follow it; the diagnostics
//! (T0200 for a tie) are in `default_overload_diag_self_test.l`.
@test_module
package DefaultOverloadSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func f(x: in Int, y: in Int = 1): Int {
  x + y
}

func f(x: in Int, y: in Int = 10, z: in Int = 100): Int {
  x + y + z
}

func g(a: in Int): Int {
  f(a)
}

// The first declared fills more defaults than the second: the order of
// declaration does not choose.
func h(x: in Int, y: in Int = 10, z: in Int = 100): Int {
  1000 + x + y + z
}

func h(x: in Int, y: in Int = 1): Int {
  2000 + x + y
}

// A call supplying every parameter wins over one that fills defaults.
func k(a: in Int, b: in Int): Int {
  3000 + a + b
}

func k(a: in Int, b: in Int = 1, c: in Int = 2): Int {
  4000 + a + b + c
}

// A name only one candidate has selects it.
func n(a: in Int, b: in Int = 1): Int {
  5000 + a + b
}

func n(a: in Int, c: in Int = 5, d: in Int = 6): Int {
  6000 + a + c + d
}

// A name both have narrows nothing; the fewest defaults decides.
func s(a: in Int, b: in Int = 1, c: in Int = 2): Int {
  7000 + a + b + c
}

func s(a: in Int, b: in Int = 1): Int {
  8000 + a + b
}

// The argument types come before the number of defaults: `gt(1)` fits both,
// but only the second takes an Int.
func gt(x: in String): Int {
  18000
}

func gt(x: in Int, y: in Int = 2): Int {
  18001 + x + y
}

// A mixed call fills what it leaves out: `p(1, c = 9)` fits only the
// declaration naming `c`, `p(1)` the one with fewer defaults.
func p(a: in Int, b: in Int = 2): Int {
  14000 + a + b
}

func p(a: in Int, b: in Int = 2, c: in Int = 3): Int {
  15000 + a + b + c
}

record Acc {
  n: Int

  func m(self: in Acc, x: in Int, y: in Int = 1): Int {
    16000 + self.n + x + y
  }

  func m(self: in Acc, x: in Int, y: in Int = 10, z: in Int = 100): Int {
    17000 + self.n + x + y + z
  }

  func viaSibling(self: in Acc): Int {
    m(1)
  }

  func viaSelf(self: in Acc): Int {
    self.m(1)
  }
}

func Acc.d(self: in Acc, x: in Int, y: in Int = 10, z: in Int = 100): Int {
  20000 + self.n + x + y + z
}

func Acc.d(self: in Acc, x: in Int, y: in Int = 1): Int {
  21000 + self.n + x + y
}

interface Shape {
  func area(self: in Self, scale: in Int = 2): Int
}

record Sq {
  s: Int
}

impl Shape for Sq {
  func area(self: in Sq, scale: in Int = 2): Int {
    self.s * scale
  }
}

func viaBare(a: in Int): Int {
  h(a)
}

func viaNamed(a: in Int): Int {
  n(a, c = 7) + n(a, b = 3)
}

test "a call through defaults binds the overload that fills the fewest" {
  assertEqualInt(g(5), 6, "f(5): f(x, y = 1) fills one default, f(x, y, z) two")
  assertEqualInt(f(5, 2), 7, "f(5, 2) supplies the first in full")
  assertEqualInt(f(5, 2, 3), 10, "f(5, 2, 3) supplies every parameter of the second")
}

test "the order of declaration does not choose" {
  assertEqualInt(viaBare(5), 2006, "h(5) binds the two-parameter declaration declared last")
  assertEqualInt(h(5, 2, 3), 1010, "h(5, 2, 3) supplies the three-parameter declaration in full")
}

test "a call supplying every parameter wins over one filling defaults" {
  assertEqualInt(k(1, 2), 3003, "k(1, 2) supplies every parameter of the first")
  assertEqualInt(k(1), 4004, "k(1) fits only the second")
  assertEqualInt(k(1, 2, 3), 4006, "k(1, 2, 3) supplies every parameter of the second")
}

test "a name only one candidate has selects it" {
  assertEqualInt(n(1, c = 7), 6014, "c is the second declaration's")
  assertEqualInt(n(1, b = 3), 5004, "b is the first declaration's")
  assertEqualInt(viaNamed(1), 6014 + 5004, "the same through a caller")
}

test "the fewest defaults decides between equal prefixes" {
  assertEqualInt(s(1), 8002, "s(1): the two-parameter declaration fills one, the other two")
  assertEqualInt(s(1, 5), 8006, "s(1, 5) fills nothing in the two-parameter declaration")
  assertEqualInt(s(1, 5, 6), 7012, "s(1, 5, 6) supplies the three-parameter declaration in full")
  assertEqualInt(p(1), 14003, "p(1) fills one default of the two-parameter declaration")
  assertEqualInt(p(1, c = 9), 15012, "p(1, c = 9) fits only the declaration naming c")
}

test "the argument types come before the number of defaults" {
  assertEqualInt(gt("abc"), 18000, "gt(String) fits only the String declaration")
  assertEqualInt(gt(1), 18004, "gt(Int) fits only the Int declaration, filling a default")
}

test "a method call binds the overload that fills the fewest defaults" {
  val a = Acc(n = 1)
  assertEqualInt(a.m(2), 16000 + 1 + 2 + 1, "a.m(2)")
  assertEqualInt(a.viaSibling(), 16000 + 1 + 1 + 1, "a bare call to a sibling")
  assertEqualInt(a.viaSelf(), 16000 + 1 + 1 + 1, "self.m(1)")
  assertEqualInt(a.m(2, 3, 4), 17000 + 1 + 2 + 3 + 4, "all parameters of the second")
}

test "a dot-named function binds the overload that fills the fewest defaults" {
  val a = Acc(n = 1)
  assertEqualInt(a.d(2), 21000 + 1 + 2 + 1, "a.d(2)")
  assertEqualInt(Acc.d(a, 2), 21000 + 1 + 2 + 1, "Acc.d(a, 2)")
  assertEqualInt(a.d(2, 3, 4), 20000 + 1 + 2 + 3 + 4, "all parameters")
}

test "an impl method filling its default is unchanged" {
  val q = Sq(s = 4)
  assertEqualInt(q.area(), 8, "the impl's default")
}
