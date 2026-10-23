//! jvm_erased_types_self_test.l — dual-target runtime regression test for
//! element and field types the JVM backend erases to `Object` (J008 on `+`,
//! VerifyError at a join), read back through module-level vals, nested
//! arrays, unannotated generic-record bindings and `?` bindings.
//!
//! Covers #8281 (module-level `List`), #8237 (nested `array`), #8132 and
//! #8162 (unannotated generic record: `List[T]` field, bare `T` field,
//! named constructor arguments), #8078 (overloaded methods), #7630 (`?`
//! bindings), #7298 (a `slice[Byte]` match join).  The curried generic-union
//! case (#8351) is in `jvm/curried_generic_union_jvm_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/jvm_erased_types_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/jvm_erased_types_self_test.l
@test_module
package Lyric.JvmErasedTypesSelfTest

import Std.Core
import Std.Collections
import Std.Testing

val moduleStrings: List[String] = ["a", "b"]

val moduleInts: List[Int] = [1, 2]

val moduleLongs: List[Long] = [3i64, 4i64]

record Holder[T] {
  xs: List[T]
  tag: Int
}

record Twin[T] {
  first: T
  second: T
}

record Mixed[A, B] {
  left: A
  right: B
}

record Person {
  name: String
  age: Int
}

func decodePerson(s: in String): Result[Person, String] {
  if s == "" {
    Err(error = "empty")
  } else {
    Ok(value = Person(name = s, age = 3))
  }
}

func findPerson(s: in String): Option[Person] {
  Some(value = Person(name = s, age = 4))
}

func personName(s: in String): Result[String, String] {
  val p = decodePerson(s)?
  Ok(value = p.name + "/" + toString(p.age))
}

func personAge(s: in String): Option[Int] {
  val q = findPerson(s)?
  Some(value = q.age + 1)
}

record Src {
  n: Int

  func make(self: in Src): List[String] {
    val acc: List[String] = newList()
    acc.add("a" + toString(self.n))
    acc.add("b")
    acc
  }

  func make(self: in Src, k: in Int): List[Int] {
    val acc: List[Int] = newList()
    acc.add(self.n + k)
    acc.add(k)
    acc
  }

  func viaBare(self: in Src): Int {
    val xs = make(5)
    xs[0] + xs[1]
  }
}

func orElse[T](o: in Option[T], d: in T): T {
  match o {
    case Some(v) -> v
    case None -> d
  }
}

func someBytes(): Option[slice[Byte]] {
  val l: List[Byte] = newList()
  l.add(10.toByte())
  l.add(255.toByte())
  Some(value = l.toArray())
}

test "module-level List elements keep their declared type" {
  assertEqual(moduleStrings[0] + moduleStrings[1], "ab", "String")
  assertEqualInt(moduleInts[0] + moduleInts[1], 3, "Int")
  assertEqualLong(moduleLongs[0] + moduleLongs[1], 7i64, "Long")
}

test "nested array of String" {
  var s: array[2, array[2, String]] = [["a", "b"], ["c", "d"]]
  assertEqual(s[0][0] + s[1][1], "ad", "nested read")
}

test "unannotated generic record with a List[T] field" {
  val ys: List[String] = ["a", "b"]
  val h = Holder(xs = ys, tag = 0)
  assertEqual(h.xs[0] + h.xs[1], "ab", "List[T] field element")
}

test "unannotated generic record with bare T fields" {
  val t = Twin(first = "x", second = "y")
  assertEqual(t.first + t.second, "xy", "String")
  val n = Twin(first = 1, second = 2)
  assertEqualInt(n.first + n.second, 3, "Int")
}

test "constructor arguments pair by name and by position" {
  val m = Mixed(right = 9, left = "n")
  assertEqual(m.left + toString(m.right + 1), "n10", "named")
  val p = Mixed("m", 7)
  assertEqual(p.left + toString(p.right + 1), "m8", "positional")
}

test "bindings from ? keep their payload type" {
  match personName("ann") {
    case Ok(v) -> assertEqual(v, "ann/3", "Result")
    case Err(e) -> assertTrue(false, e)
  }
  match personAge("bob") {
    case Some(v) -> assertEqualInt(v, 5, "Option")
    case None -> assertTrue(false, "none")
  }
}

test "match join of a slice[Byte] payload and its default" {
  val got = orElse(someBytes(), [])
  assertEqualInt(got.length, 2, "Some arm")
  val none: Option[slice[Byte]] = None
  val dflt: slice[Byte] = [1.toByte(), 2.toByte(), 3.toByte()]
  assertEqualInt(orElse(none, dflt).length, 3, "None arm")
}

test "overloaded methods keep each overload's generic return type" {
  val s = Src(n = 1)
  val a = s.make()
  assertEqual(a[0] + a[1], "a1b", "zero-argument overload")
  val b = s.make(2)
  assertEqualInt(b[0] + b[1], 5, "one-argument overload")
  assertEqualInt(s.viaBare(), 11, "bare sibling call")
}
