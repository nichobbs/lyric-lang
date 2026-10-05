//! Structural equality in host collections (D172): a record that compares
//! field by field, a union and a tuple are found as a `Map` or `Set` key and
//! by `List.contains`/`indexOf` when built separately, under the same rule as
//! `==`.  A mutable record keeps identity.  Run on dotnet and the JVM; native
//! collections are tracked in #8167.
@test_module
package Lyric.StructuralEqualityCollectionsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record P {
  x: Int
  y: Int
}

record F {
  d: Double
}

record K {
  k: array[2, Int]
}

record Grid {
  g: array[2, array[2, Int]]
}

record Vec {
  v: array[3, Double]
}

record Named {
  p: P
  name: String
}

record Box[T] {
  v: T
}

record Cell {
  var n: Int
}

@derive(Equals, Hash)
record Counter {
  var n: Int
  label: String
}

union U {
  case A(v: P)
  case B(d: Double)
  case Z
}

union Arr {
  case Xs(xs: array[2, Int])
}

func nanOf(z: in Double): Double = z / z

test "a value record is found as a Map key" {
  val m: Map[P, String] = newMap()
  m.add(P(x = 1, y = 2), "a")
  assertTrue(m.containsKey(P(x = 1, y = 2)), "a separately built key")
  assertFalse(m.containsKey(P(x = 2, y = 1)), "a different key")
  val n: Map[Named, Int] = newMap()
  n.add(Named(p = P(x = 1, y = 2), name = "q"), 7)
  assertTrue(n.containsKey(Named(p = P(x = 1, y = 2), name = "q")), "a nested record and a String")
}

test "Float fields follow D172 as keys" {
  val m: Map[F, Int] = newMap()
  m.add(F(d = nanOf(0.0)), 1)
  m.add(F(d = 0.0), 2)
  assertTrue(m.containsKey(F(d = nanOf(0.0))), "a NaN key")
  assertTrue(m.containsKey(F(d = -0.0)), "negative zero finds zero")
  assertEqualInt(m.count, 2, "two keys")
}

test "array fields compare and hash element by element" {
  val a1: array[2, Int] = [1, 2]
  val a2: array[2, Int] = [1, 2]
  val m: Map[K, Int] = newMap()
  m.add(K(k = a1), 1)
  assertTrue(m.containsKey(K(k = a2)), "an Int array field")
  val r0: array[2, Int] = [1, 2]
  val r1: array[2, Int] = [3, 4]
  val g1: array[2, array[2, Int]] = [r0, r1]
  val g2: array[2, array[2, Int]] = [r0, r1]
  val gm: Map[Grid, Int] = newMap()
  gm.add(Grid(g = g1), 1)
  assertTrue(gm.containsKey(Grid(g = g2)), "an array of arrays")
  val v1: array[3, Double] = [nanOf(0.0), 0.0, 1.0]
  val v2: array[3, Double] = [nanOf(0.0), -0.0, 1.0]
  val vm: Map[Vec, Int] = newMap()
  vm.add(Vec(v = v1), 1)
  assertTrue(vm.containsKey(Vec(v = v2)), "Double elements with NaN and zeros")
}

test "generic records, unions and derived records as keys" {
  val bm: Map[Box[Int], Int] = newMap()
  bm.add(Box(v = 3), 1)
  assertTrue(bm.containsKey(Box(v = 3)), "a generic record")
  val bp: Map[Box[P], Int] = newMap()
  bp.add(Box(v = P(x = 1, y = 1)), 1)
  assertTrue(bp.containsKey(Box(v = P(x = 1, y = 1))), "a generic record of a record")
  val um: Map[U, Int] = newMap()
  um.add(U.A(v = P(x = 5, y = 6)), 1)
  um.add(U.B(d = nanOf(0.0)), 2)
  assertTrue(um.containsKey(U.A(v = P(x = 5, y = 6))), "a union with a record payload")
  assertTrue(um.containsKey(U.B(d = nanOf(0.0))), "a union with a NaN payload")
  val xs1: array[2, Int] = [1, 2]
  val xs2: array[2, Int] = [1, 2]
  val am: Map[Arr, Int] = newMap()
  am.add(Arr.Xs(xs = xs1), 1)
  assertTrue(am.containsKey(Arr.Xs(xs = xs2)), "a union with an array payload")
  val cm: Map[Counter, Int] = newMap()
  cm.add(Counter(n = 1, label = "c"), 1)
  assertTrue(cm.containsKey(Counter(n = 1, label = "c")), "a mutable record deriving Equals and Hash")
}

test "a mutable record keeps identity as a key" {
  val c = Cell(n = 1)
  val m: Map[Cell, Int] = newMap()
  m.add(c, 1)
  assertTrue(m.containsKey(c), "the same instance")
  assertFalse(m.containsKey(Cell(n = 1)), "an equal but different instance")
}

test "List.contains, indexOf and Set membership" {
  val l: List[P] = newList()
  l.add(P(x = 1, y = 2))
  l.add(P(x = 3, y = 4))
  assertTrue(l.contains(P(x = 3, y = 4)), "contains")
  assertEqualInt(l.indexOf(P(x = 3, y = 4)), 1, "indexOf")
  val s: Set[F] = newSet()
  s.add(F(d = nanOf(0.0)))
  s.add(F(d = nanOf(0.0)))
  assertEqualInt(s.count, 1, "one NaN record in a Set")
}

record Keyed {
  t: (Int, Double)
}

test "a tuple field compares element by element" {
  val m: Map[Keyed, Int] = newMap()
  m.add(Keyed(t = (1, 0.0)), 1)
  assertTrue(m.containsKey(Keyed(t = (1, -0.0))), "negative zero in a tuple field")
  assertFalse(m.containsKey(Keyed(t = (2, 0.0))), "a different tuple")
}
