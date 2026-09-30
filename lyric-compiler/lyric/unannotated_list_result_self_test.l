//! unannotated_list_result_self_test.l — runtime regression test for a local
//! built by `newList()`, `newMap()` or `None` with no type annotation, whose
//! type arguments only its later uses fix (#7755 review, #7788).
//!
//! `val seeds = newList()` says nothing about the element type where the
//! list is constructed.  The MSIL backend, whose generics are reified, built
//! such a list as `List<object>` and stored it where a `List<Seed>` was
//! declared: unverifiable IL, and an `InvalidCastException` at a consumer
//! that uses the value as the `List<Seed>` its type says it is (`.count`
//! through a typed binding, `for`, indexing).  An erased `None` returned as
//! an `Option[Pt]` payload was `Option_None<object>`, which a `match` on
//! `Option[Pt]` does not recognise ("match not exhaustive").  `lyric-proto`'s
//! `decodeMessage` (`Ok(value = fields)`) was a real instance.
//!
//! The type checker now records the type the binding's uses agree on — the
//! type of the position it flows into, else the type of what is stored into
//! it — and it becomes the binding's annotation, so the value is built with
//! its checked type.  The cases below cover each kind of use.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/unannotated_list_result_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/unannotated_list_result_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.UnannotatedListResultSelfTest

import Std.Core
import Std.Collections
import Std.CollectionsHost as Host
import Std.Testing

record Seed {
  n: Int
}

record Pt {
  x: Int
}

record Bag {
  items: List[Seed]
}

func buildSeeds(): Result[List[Seed], String] {
  val seeds = newList()
  seeds.add(Seed(n = 1))
  seeds.add(Seed(n = 2))
  Ok(value = seeds)
}

func sumSeeds(seeds: in List[Seed]): Int {
  var t = 0
  val arr = seeds.toArray()
  for s in arr {
    t = t + s.n
  }
  t
}

func countTyped(seeds: in List[Seed]): Int {
  val typed: List[Seed] = seeds
  typed.count
}

func sumFor(seeds: in List[Seed]): Int {
  var t = 0
  for s in seeds {
    t = t + s.n
  }
  t
}

func firstN(seeds: in List[Seed]): Int = seeds[0].n

func noPt(): Result[Option[Pt], String] {
  val o = None
  Ok(value = o)
}

func somePtLater(): Option[Pt] {
  var o = None
  o = Some(value = Pt(x = 5))
  o
}

func returnedDirectly(): List[Seed] {
  val xs = newList()
  xs.add(Seed(n = 4))
  return xs
}

func passedAsArgument(): Int {
  val xs = newList()
  xs.add(Seed(n = 6))
  xs.add(Seed(n = 7))
  sumFor(xs)
}

func inRecordField(): Bag {
  val xs = newList()
  xs.add(Seed(n = 8))
  Bag(items = xs)
}

func nestedPayload(): Result[Option[List[Seed]], String] {
  val xs = newList()
  xs.add(Seed(n = 9))
  Ok(value = Some(value = xs))
}

func storesOnly(): Int {
  var xs = newList()
  xs.add(Seed(n = 10))
  xs.add(Seed(n = 11))
  var t = 0
  for s in xs {
    t = t + s.n
  }
  t
}

func buildMap(): Map[String, Int] {
  val m = newMap()
  m.add("a", 1)
  m["b"] = 2
  m
}

func withCapacity(): List[Seed] {
  val xs = newListWithCapacity(4)
  xs.add(Seed(n = 12))
  xs
}

func longs(): List[Long] {
  val xs = newList()
  xs.add(1)
  xs.add(2)
  xs
}

func sumLongs(xs: in List[Long]): Long {
  var t: Long = 0
  for v in xs {
    t = t + v
  }
  t
}

func wrapOne[T](x: in T): List[T] {
  val xs = newList()
  xs.add(x)
  xs
}

func qualified(): List[Seed] {
  val xs = Host.newList()
  xs.add(Seed(n = 14))
  xs
}

test "an unannotated list returned inside a Result[List[Seed], String]" {
  match buildSeeds() {
    case Ok(seeds) -> assertEqualInt(sumSeeds(seeds), 3, "summed through a List[Seed] parameter")
    case Err(e) -> assertTrue(false, e)
  }
}

test "the returned list is a List[Seed] at a typed binding, a for loop and an index" {
  match buildSeeds() {
    case Ok(seeds) -> {
      assertEqualInt(countTyped(seeds), 2, ".count through a typed binding")
      assertEqualInt(sumFor(seeds), 3, "for over the parameter")
      assertEqualInt(firstN(seeds), 1, "indexed element")
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "an unannotated None returned inside a Result[Option[Pt], String]" {
  match noPt() {
    case Ok(o) -> match o {
      case Some(p) -> assertTrue(false, "expected None, got " + toString(p.x))
      case None -> assertTrue(true, "None")
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "an unannotated None var later assigned Some" {
  match somePtLater() {
    case Some(p) -> assertEqualInt(p.x, 5, "assigned payload")
    case None -> assertTrue(false, "expected Some")
  }
}

test "an unannotated list returned, passed and stored in a field" {
  assertEqualInt(countTyped(returnedDirectly()), 1, "return")
  assertEqualInt(passedAsArgument(), 13, "argument")
  assertEqualInt(sumFor(inRecordField().items), 8, "record field")
}

test "an unannotated list inside a nested payload" {
  match nestedPayload() {
    case Ok(o) -> match o {
      case Some(xs) -> assertEqualInt(firstN(xs), 9, "nested payload")
      case None -> assertTrue(false, "expected Some")
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "an unannotated list whose only uses are stores" {
  assertEqualInt(storesOnly(), 21, "for over the local")
}

test "an unannotated map and a list built with a capacity" {
  val m = buildMap()
  assertEqualInt(m["a"] + m["b"], 3, "map entries")
  assertEqualInt(countTyped(withCapacity()), 1, "capacity list")
}

test "an Int stored into a list returned as List[Long]" {
  assertEqualLong(sumLongs(longs()), 3, "widened elements")
}

test "an unannotated list in a generic function, stored a value of its type parameter" {
  val ints: List[Int] = wrapOne(15)
  assertEqualInt(ints[0], 15, "List[Int]")
  assertEqualInt(countTyped(wrapOne(Seed(n = 16))), 1, "List[Seed]")
}

test "a qualified newList() through an aliased import" {
  assertEqualInt(firstN(qualified()), 14, "Host.newList()")
}
