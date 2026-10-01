//! list_insert_self_test.l — runtime regression test for the two-argument
//! `List[T].add(index, item)`, which inserts `item` before position `index`
//! (#7797).
//!
//! The MSIL backend chose between `List.Add` and `Dictionary.Add` by the
//! call's arity, so `xs.add(0, 1)` on a list emitted `Dictionary.Add` against
//! a `List` receiver: invalid IL (`InvalidProgramException`).  It now lowers
//! to `List`1<T>::Insert(int32, !0)`, the element widened to the slot's type
//! like every other collection argument (#7785); the JVM's
//! `ArrayList.add(int, E)` already had these semantics.  An index outside
//! `0 ..= count` raises on both targets.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/list_insert_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/list_insert_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ListInsertSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Tag {
  name: String
}

func render(xs: in List[Int]): String {
  var acc = ""
  for x in xs {
    acc = acc + toString(x) + ","
  }
  acc
}

func insertFirst[T](xs: in List[T], item: in T): Unit {
  xs.add(0, item)
}

test "insert at the front, in the middle and at the end" {
  val xs: List[Int] = newList()
  xs.add(2)
  xs.add(0, 1)
  assertEqual(render(xs), "1,2,", "front")
  xs.add(xs.count, 4)
  assertEqual(render(xs), "1,2,4,", "end")
  xs.add(2, 3)
  assertEqual(render(xs), "1,2,3,4,", "middle")
  assertEqualInt(xs.count, 4, "count after three inserts")
}

test "insert into an empty list" {
  val xs: List[Int] = newList()
  xs.add(0, 7)
  assertEqualInt(xs.count, 1, "one element")
  assertEqualInt(xs[0], 7, "the inserted element")
}

test "an index past the end raises" {
  val xs: List[Int] = newList()
  xs.add(1)
  assertPanics("index count + 1", { -> xs.add(2, 9) })
  assertEqualInt(xs.count, 1, "list unchanged")
}

test "a negative index raises" {
  val xs: List[Int] = newList()
  xs.add(1)
  assertPanics("index -1", { -> xs.add(-1, 9) })
  assertEqualInt(xs.count, 1, "list unchanged")
}

test "an Int element is widened to a Long list's element type" {
  val ls: List[Long] = newList()
  ls.add(0, 5)
  ls.add(0, 4)
  assertEqualLong(ls[0] + ls[1], 9, "4 + 5 as Long")
}

// `Int` to `Double` crosses the widening chains, so it is explicit (#7969).
test "an Int element converted with toDouble is inserted into a Double list" {
  val ds: List[Double] = newList()
  ds.add(1.5)
  ds.add(0, 1.toDouble())
  assertTrue(ds[0] + ds[1] == 2.5, "1 + 1.5 as Double")
}

test "insert a record" {
  val ts: List[Tag] = newList()
  ts.add(Tag(name = "b"))
  ts.add(0, Tag(name = "a"))
  assertEqual(ts[0].name + ts[1].name, "ab", "record order")
}

test "insert through a generic function" {
  val xs: List[String] = newList()
  xs.add("y")
  insertFirst(xs, "x")
  assertEqual(xs[0] + xs[1], "xy", "generic insert")
}

test "a map's two-argument add still adds a key" {
  val m: Map[String, Int] = newMap()
  m.add("k", 3)
  assertEqualInt(m["k"], 3, "map add")
}
