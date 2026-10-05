//! Structural equality (D172): records that compare field by field, unions,
//! tuples and arrays use one relation, under which a `Float`/`Double` leaf is
//! equal when `==` holds or both are `NaN`.  Union payloads and generic `==`
//! follow it.  Run on dotnet, the JVM and native; the host collections are
//! covered by `structural_equality_collections_self_test.l`.
@test_module
package Lyric.StructuralEqualitySelfTest

import Std.Core
import Std.Testing

record P {
  x: Int
  y: Int
}

record F {
  d: Double
}

record G {
  f: Float
}

record W {
  inner: F
  label: String
}

record Cell {
  var n: Int
}

@derive(Equals)
record Counter {
  var n: Int
}

union U {
  case A(v: P)
  case B(d: Double)
  case Z
}

union Holder {
  case H(w: W)
  case None2
}

func nanOf(z: in Double): Double = z / z

func same[T](a: in T, b: in T): Bool = a == b

func differ[T](a: in T, b: in T): Bool = a != b

test "a NaN field equals a NaN field, and zero equals negative zero" {
  val nan = nanOf(0.0)
  assertTrue(F(d = nan) == F(d = nan), "two separately built NaN records")
  assertFalse(F(d = nan) != F(d = nan), "!= agrees")
  assertFalse(F(d = nan) == F(d = 1.0), "NaN against a number")
  assertTrue(F(d = 0.0) == F(d = -0.0), "the zeros")
  assertTrue(G(f = nanOf(0.0).toFloat()) == G(f = nanOf(0.0).toFloat()), "a Float field")
  assertTrue(W(inner = F(d = nan), label = "a") == W(inner = F(d = nan), label = "a"), "a nested record")
  assertFalse(nan == nan, "a bare NaN is not equal to itself")
}

test "a union payload compares by structure" {
  assertTrue(U.A(v = P(x = 1, y = 2)) == U.A(v = P(x = 1, y = 2)), "a record payload")
  assertFalse(U.A(v = P(x = 1, y = 2)) == U.A(v = P(x = 1, y = 3)), "a different record payload")
  val nan = nanOf(0.0)
  assertTrue(U.B(d = nan) == U.B(d = nan), "a NaN payload")
  assertTrue(U.B(d = 0.0) == U.B(d = -0.0), "zero payloads")
  assertFalse(U.B(d = 1.0) == U.Z, "different cases")
  assertTrue(Some(value = P(x = 3, y = 4)) == Some(value = P(x = 3, y = 4)), "an Option of a record")
  assertTrue(
    Holder.H(w = W(inner = F(d = nan), label = "h")) == Holder.H(w = W(inner = F(d = nan), label = "h")),
    "a payload record holding a NaN"
  )
}

test "tuples and arrays follow the same rule" {
  val nan = nanOf(0.0)
  val t1 = (nan, 1)
  val t2 = (nan, 1)
  assertTrue(t1 == t2, "a NaN tuple element")
  assertTrue((0.0, 1) == (-0.0, 1), "zero tuple elements")
  assertFalse((1.0, 1) == (1.0, 2), "a different element")
  val a1: array[2, Double] = [nan, 1.0]
  val a2: array[2, Double] = [nan, 1.0]
  assertTrue(a1 == a2, "a NaN array element")
}

test "== through a type parameter compares like the bound type" {
  assertTrue(same(P(x = 1, y = 2), P(x = 1, y = 2)), "a value record")
  assertTrue(differ(P(x = 1, y = 2), P(x = 2, y = 2)), "!= on a value record")
  assertTrue(same(Counter(n = 5), Counter(n = 5)), "a record deriving Equals")
  val c = Cell(n = 1)
  assertFalse(same(c, Cell(n = 1)), "a mutable record keeps identity")
  assertTrue(same(c, c), "the same instance")
  assertTrue(same(U.A(v = P(x = 1, y = 1)), U.A(v = P(x = 1, y = 1))), "a union")
  assertTrue(same(F(d = nanOf(0.0)), F(d = nanOf(0.0))), "a NaN record")
  assertFalse(same(nanOf(0.0), nanOf(0.0)), "a bare Double keeps IEEE ==")
}
