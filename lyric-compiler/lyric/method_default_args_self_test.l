//! A method call that omits a defaulted argument splices the declared
//! default, like a free-function call (#7820).
//!
//! Every method-call shape used to lower only the arguments written at the
//! call, so `acc.add()` for `func add(self: in Acc, x: in Int = 5)` left the
//! callee one argument short: an `InvalidProgramException` on dotnet, a
//! stackmap underflow (J008) on JVM.  Each backend now pairs the arguments
//! with the callee's parameters (named ones by name, the rest in order) and
//! fills each omitted parameter from its default, the same step a free call
//! takes, for record, `impl`, interface, protected, dot-named and generic
//! record methods and a bare call to a sibling method.  A default comes from
//! the declaration the call resolves through: the interface member's for a
//! call on an interface-typed value, the `impl` method's for a call on the
//! concrete type.  A default that widens (`x: in ULong = someUInt`)
//! zero-extends.
//!
//! A call that leaves out a defaulted argument binds the overload the type
//! checker resolved, on both targets (#7828): the backends used to look a
//! method up by the number of arguments written, so `o.m(1)` with
//! `m(x: Int, y: Int = 2)` and `m(x: String)` called `m(x: String)` on
//! dotnet and failed verification on the JVM.  An overload taking exactly
//! the written arguments wins over one that fills the rest from defaults.
@test_module
package MethodDefaultArgsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

val bigU: UInt = 4000000000u32

val base: Int = 100

record Acc {
  n: Int

  func add(self: in Acc, x: in Int = 5): Int {
    self.n + x
  }

  func mix(self: in Acc, a: in Int, b: in Int = 10, c: in Int = 100): Int {
    self.n + a * 1 + b * 2 + c * 3
  }

  func wide(self: in Acc, x: in ULong = bigU): ULong {
    x
  }

  func fromModule(self: in Acc, x: in Int = base + 1): Int {
    self.n + x
  }

  func viaSibling(self: in Acc): Int {
    add()
  }

  func viaSelf(self: in Acc): Int {
    self.mix(1)
  }
}

func Acc.scaled(self: in Acc, k: in Int = 3): Int {
  self.n * k
}

interface Shape {
  func area(self: in Self, scale: in Int = 2): Int

  func describe(self: in Self, prefix: in String = "shape:"): String {
    prefix + toString(self.area())
  }
}

record Sq {
  s: Int
}

impl Shape for Sq {
  func area(self: in Sq, scale: in Int = 3): Int {
    self.s * scale
  }
}

record Tri {
  b: Int
}

impl Shape for Tri {
  func area(self: in Tri, scale: in Int = 2): Int {
    self.b * scale + 1
  }

  func describe(self: in Tri, prefix: in String = "tri:"): String {
    prefix + toString(self.b)
  }
}

func areaOf(sh: in Shape): Int {
  sh.area()
}

func describeOf(sh: in Shape): String {
  sh.describe()
}

record Box[T] {
  v: T

  func orElse(self: in Box[T], extra: in Int = 7): Int {
    extra
  }
}

protected type Counter {
  var total: Int = 0
  entry bump(by: in Int = 1): Int {
    total = total + by
    total
  }
}

record Ov {
  n: Int

  func m(self: in Ov, x: in Int, y: in Int = 2): Int {
    1000 + x * 10 + y
  }

  func m(self: in Ov, x: in Int): Int {
    2000 + x
  }
}

record Ov2 {
  n: Int

  func m(self: in Ov2, x: in String): Int {
    3000
  }

  func m(self: in Ov2, x: in Int, y: in Int = 2): Int {
    4000 + x * 10 + y
  }

  func viaSibling(self: in Ov2): Int {
    m(1)
  }

  func viaSelf(self: in Ov2): Int {
    self.m(1)
  }
}

record Ov3 {
  n: Int

  func m(self: in Ov3, x: in Int): Int {
    2000 + x
  }

  func m(self: in Ov3, x: in Int, y: in Int = 2, z: in Int = 3): Int {
    5000 + x * 100 + y * 10 + z
  }
}

record GOv[T] {
  v: T

  func m(self: in GOv[T], x: in String): Int {
    3000
  }

  func m(self: in GOv[T], x: in Int, y: in Int = 2): Int {
    4000 + x * 10 + y
  }
}

func free(a: in Int, b: in Int = 10, c: in Int = 100): Int {
  a + b * 2 + c * 3
}

test "record method: an omitted defaulted argument takes its default" {
  val a = Acc(n = 1)
  assertEqualInt(a.add(), 6, "add() = 1 + 5")
  assertEqualInt(a.add(10), 11, "add(10) = 1 + 10")
  assertEqualInt(Acc(n = 1).add(), 6, "call on a construction")
}

test "record method: named and mixed arguments fill the gaps" {
  val a = Acc(n = 0)
  assertEqualInt(a.mix(1), 1 + 20 + 300, "mix(1)")
  assertEqualInt(a.mix(1, 2), 1 + 4 + 300, "mix(1, 2)")
  assertEqualInt(a.mix(1, c = 3), 1 + 20 + 9, "mix(1, c = 3) skips b")
  assertEqualInt(a.mix(c = 3, a = 1), 1 + 20 + 9, "named out of order")
  assertEqualInt(a.mix(b = 2, c = 3, a = 1), 1 + 4 + 9, "all named, out of order")
}

test "free function: a mixed call fills the gap too" {
  assertEqualInt(free(1, c = 3), 1 + 20 + 9, "free(1, c = 3)")
  assertEqualInt(free(c = 3, a = 1), 1 + 20 + 9, "free named out of order")
}

test "record method: a widening default zero-extends" {
  val w = Acc(n = 0).wide()
  assertTrue(w == 4000000000u64, "ULong default from a UInt module value: " + toString(w))
}

test "record method: a default reading a module value" {
  assertEqualInt(Acc(n = 1).fromModule(), 102, "1 + (100 + 1)")
}

test "a bare or self call to a sibling method fills its defaults" {
  assertEqualInt(Acc(n = 2).viaSibling(), 7, "add() from inside a method")
  assertEqualInt(Acc(n = 0).viaSelf(), 1 + 20 + 300, "self.mix(1)")
}

test "dot-named function called as a method or statically" {
  val a = Acc(n = 4)
  assertEqualInt(a.scaled(), 12, "a.scaled()")
  assertEqualInt(a.scaled(k = 2), 8, "a.scaled(k = 2)")
  assertEqualInt(Acc.scaled(a), 12, "Acc.scaled(a)")
}

test "impl method on the concrete type uses the impl's default" {
  val q = Sq(s = 4)
  assertEqualInt(q.area(), 12, "Sq.area default 3")
  assertEqualInt(q.area(5), 20, "explicit argument")
  assertEqualInt(Tri(b = 4).area(), 9, "Tri.area default 2")
}

test "interface call uses the interface member's default" {
  assertEqualInt(areaOf(Sq(s = 4)), 8, "Shape.area default 2 dispatches to Sq.area")
  assertEqualInt(areaOf(Tri(b = 4)), 9, "Shape.area default 2 dispatches to Tri.area")
}

test "interface default method with a defaulted parameter" {
  assertEqual(Sq(s = 4).describe(), "shape:12", "inherited default method on the concrete type")
  assertEqual(describeOf(Sq(s = 4)), "shape:12", "inherited default method through the interface")
  assertEqual(Tri(b = 4).describe(), "tri:4", "override's own default on the concrete type")
  assertEqual(describeOf(Tri(b = 4)), "shape:4", "interface's default through the interface")
  assertEqual(describeOf(Tri(b = 4)), Tri(b = 4).describe("shape:"), "same as passing it")
}

test "generic record method" {
  val b = Box(v = "x")
  assertEqualInt(b.orElse(), 7, "Box[String].orElse()")
  assertEqualInt(Box(v = 1).orElse(extra = 2), 2, "named")
}

test "protected entry" {
  val c = Counter()
  assertEqualInt(c.bump(), 1, "bump()")
  assertEqualInt(c.bump(5), 6, "bump(5)")
  assertEqualInt(c.bump(by = 2), 8, "bump(by = 2)")
}

test "an overload taking exactly the written arguments wins (#7828)" {
  val o = Ov(n = 0)
  assertEqualInt(o.m(1), 2001, "m(x) over m(x, y = 2)")
  assertEqualInt(o.m(1, 3), 1013, "both arguments written")
}

test "an omitted default binds the overload the checker resolved (#7828)" {
  val p = Ov2(n = 0)
  assertEqualInt(p.m(1), 4012, "m(Int, y = 2), not the one-parameter m(String)")
  assertEqualInt(p.m("s"), 3000, "m(String)")
  assertEqualInt(p.viaSibling(), 4012, "a bare call to the sibling method")
  assertEqualInt(p.viaSelf(), 4012, "self.m(1)")
}

test "an omitted default binds an overload of no written arity (#7828)" {
  val q = Ov3(n = 0)
  assertEqualInt(q.m(1), 2001, "m(x)")
  assertEqualInt(q.m(1, 5), 5153, "m(x, y, z = 3) with two arguments written")
  assertEqualInt(q.m(1, z = 9), 5129, "m(x, y = 2, z) named")
}

test "a generic record's overloads (#7828)" {
  val g = GOv(v = 1)
  assertEqualInt(g.m(1), 4012, "GOv[Int].m(Int, y = 2)")
  assertEqualInt(g.m("s"), 3000, "GOv[Int].m(String)")
}
