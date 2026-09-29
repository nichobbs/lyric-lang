//! erased_receiver_narrowing_self_test.l — runtime regression test for values
//! whose MSIL stack type was erased to `object` (or mis-widened) where a typed
//! value is required (#7755).  Each case ran correctly under the JIT, which does
//! not verify IL, but emitted unverifiable IL that `ilverify` rejects; the
//! compiled output of this file is ilverified in CI by
//! `scripts/ilverify-selfhosted.sh`, so a regression fails there, and the
//! runtime assertions here pin the behaviour on both targets.
//!
//! Shapes covered:
//!   - a `List[(Int, Int)]` (tuple elements stay on the legacy `List<object>`
//!     storage, whose locals and parameters are `object`) used as a method
//!     receiver: `add`, `contains`, `removeAt`, `count`, indexing;
//!   - a `Map[String, (Int, Int)]` (legacy `Dictionary<object,object>`) used as
//!     a receiver: `add`, `containsKey`, `count`, `remove`;
//!   - a `Long` local bound from a 32-bit integer literal (`var t: Long = 0`);
//!   - an uninitialized reference-typed `var` (`var s: String`);
//!   - a record whose name contains `_` passed as a typed argument;
//!   - a `Self`-returning interface method's result used as a receiver and as
//!     a typed argument.
//!
//! The converse — a value that must NOT be narrowed — is in
//! `unannotated_list_result_self_test.l`.
//!
//! The `Set[T]` receiver cases are in
//! `erased_receiver_narrowing_dotnet_self_test.l` (`Std.Set` is dotnet-only,
//! #7312).
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/erased_receiver_narrowing_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/erased_receiver_narrowing_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ErasedReceiverNarrowingSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func sumPairs(pairs: in List[(Int, Int)]): Int {
  var t = 0
  for (a, b) in pairs {
    t = t + a + b
  }
  t
}

func pairCount(pairs: in List[(Int, Int)]): Int {
  pairs.count
}

func addPair(pairs: in List[(Int, Int)], a: in Int, b: in Int): Unit {
  pairs.add((a, b))
}

test "List of tuples as a local receiver" {
  val pairs: List[(Int, Int)] = newList()
  pairs.add((1, 2))
  pairs.add((30, 40))
  assertEqualInt(pairs.count, 2, "two pairs added")
  assertEqualInt(sumPairs(pairs), 73, "pairs iterate after add")
  val (a, b) = pairs[1]
  assertEqualInt(a + b, 70, "indexed pair")
  pairs.removeAt(0)
  assertEqualInt(pairs.count, 1, "removeAt drops one pair")
}

test "List of tuples as a parameter receiver" {
  val pairs: List[(Int, Int)] = newList()
  addPair(pairs, 5, 6)
  addPair(pairs, 7, 8)
  assertEqualInt(pairCount(pairs), 2, "count through a parameter")
  assertEqualInt(sumPairs(pairs), 26, "adds through a parameter")
}

func pointsFor(m: in Map[String, (Int, Int)], key: in String): Int {
  if m.containsKey(key) {
    1
  } else {
    0
  }
}

test "Map with tuple values as a receiver" {
  val m: Map[String, (Int, Int)] = newMap()
  m.add("a", (1, 2))
  m.add("b", (3, 4))
  assertEqualInt(m.count, 2, "two entries")
  assertEqualInt(pointsFor(m, "a"), 1, "containsKey through a parameter")
  assertEqualInt(pointsFor(m, "z"), 0, "absent key")
  m.remove("a")
  assertEqualInt(m.count, 1, "one entry left after remove")
  assertEqualInt(pointsFor(m, "a"), 0, "the removed key is gone")
}

func sumLongs(xs: in List[Long]): Long {
  var total: Long = 0
  for x in xs {
    total = total + x
  }
  total
}

test "Long locals bound from an Int literal" {
  var total: Long = 0
  val step: Long = 3
  total = total + step
  total = total + 7000000000
  assertEqualLong(total, 7000000003, "the widened initial value accumulates")
  val xs: List[Long] = newList()
  xs.add(4000000000)
  xs.add(5i64)
  assertEqualLong(sumLongs(xs), 4000000005, "a Long accumulator in a helper")
}

func pickLabel(n: in Int): String {
  var label: String
  if n > 0 {
    label = "positive"
  } else {
    label = "not positive"
  }
  label
}

test "uninitialized reference-typed var" {
  assertEqual(pickLabel(1), "positive", "assigned in the then branch")
  assertEqual(pickLabel(0), "not positive", "assigned in the else branch")
}

record Point_2D {
  x: Int
  y: Int
}

func manhattan(p: in Point_2D): Int {
  p.x + p.y
}

test "record whose name contains an underscore" {
  val p = Point_2D(x = 3, y = 4)
  assertEqualInt(manhattan(p), 7, "passed as a typed argument")
  val q = Point_2D(x = p.x * 2, y = p.y * 2)
  assertEqualInt(manhattan(q), 14, "a second construction")
}

interface Grower {
  func grown(): Self
  func size(): Int
}

record Seed {
  n: Int
}

impl Grower for Seed {
  func grown(): Self {
    Seed(n = n + 1)
  }
  func size(): Int {
    n
  }
}

func seedSize(s: in Seed): Int {
  s.n
}

func growTwice(g: in Grower): Int {
  val once = g.grown()
  once.grown().size()
}

test "Self-returning method result used as a typed value" {
  val s = Seed(n = 1)
  val s2 = s.grown()
  assertEqualInt(seedSize(s2), 2, "a Self result passed to a Seed parameter")
  assertEqualInt(s2.grown().size(), 3, "a Self result used as a receiver")
  assertEqualInt(growTwice(Seed(n = 10)), 12, "Self results through an interface receiver")
}
