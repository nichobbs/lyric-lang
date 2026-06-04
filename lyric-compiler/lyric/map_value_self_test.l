// map_value_self_test.l — #1835: `Map[K, ValueType]` values read correctly in
// positions with no expected-type hint.
//
// `Map[K, V]` lowers to `Dictionary<object, object>`; before the fix the value
// type was erased, so `mapGet(m, k)` in a hint-less position (e.g. a `match`
// scrutinee) defaulted `V` to `object` and built an `Option<object>` whose
// boxed-value-type payload faulted when bound and used as the value type
// (`InvalidProgramException`).  The codegen now tracks `Map[K, ValueType]` as
// `MMapOf(_, valTy)` (value types only), `mapGet` falls back to that value
// type, and the `m[k]` read `unbox.any`s it — so value-type map values work in
// `match`, `val`, and direct-index positions without an annotation.
//
// Run in CI via native `lyric test --target dotnet`.  Imports only `Std.*`.
// MSIL target only (epic #1470 defers JVM).

@test_module
package Lyric.MapValueSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Key { a: Int }

test "match mapGet Map[String,Int] (no context hint)" {
  val m: Map[String, Int] = newMap()
  m["k"] = 42
  match mapGet(m, "k") {
    case Some(v) -> assertEqualInt(v, 42, "got 42")
    case None    -> assertTrue(false, "should find")
  }
  match mapGet(m, "absent") {
    case Some(_) -> assertTrue(false, "absent")
    case None    -> assertTrue(true, "absent -> None")
  }
}

test "mapGet over a record-keyed Int map" {
  val m: Map[Key, Int] = newMap()
  val k = Key(a = 7)
  m[k] = 100
  match mapGet(m, k) {
    case Some(v) -> assertEqualInt(v, 100, "got 100")
    case None    -> assertTrue(false, "should find")
  }
}

test "direct m[k] index read of a value-type map value" {
  val m: Map[String, Int] = newMap()
  m["n"] = 5
  val v = m["n"]
  assertEqualInt(v + 1, 6, "5 + 1 = 6 (unboxed)")
}

test "direct m[k] index read: Map[String,Long]" {
  val m: Map[String, Long] = newMap()
  m["x"] = 9000000000i64
  val v = m["x"]
  assertTrue(v == 9000000000i64, "long unboxed via m[k]")
}

test "direct m[k] index read: Map[String,Double]" {
  val m: Map[String, Double] = newMap()
  m["pi"] = 3.5
  val v = m["pi"]
  assertTrue(v > 3.0, "double unboxed via m[k]")
}

test "direct m[k] index read: Map[String,Bool]" {
  val m: Map[String, Bool] = newMap()
  m["on"] = true
  val v = m["on"]
  assertTrue(v, "bool unboxed via m[k]")
}

test "mapGet Map[String,Long]" {
  val m: Map[String, Long] = newMap()
  m["x"] = 9000000000i64
  match mapGet(m, "x") {
    case Some(v) -> assertTrue(v == 9000000000i64, "got the long")
    case None    -> assertTrue(false, "should find")
  }
}

test "mapGet Map[String,Double]" {
  val m: Map[String, Double] = newMap()
  m["pi"] = 3.5
  match mapGet(m, "pi") {
    case Some(v) -> assertTrue(v > 3.0, "got > 3.0")
    case None    -> assertTrue(false, "should find")
  }
}

test "mapGet Map[String,Bool]" {
  val m: Map[String, Bool] = newMap()
  m["on"] = true
  match mapGet(m, "on") {
    case Some(v) -> assertTrue(v, "got true")
    case None    -> assertTrue(false, "should find")
  }
}

test "reference-valued map still works (no regression)" {
  val m: Map[String, String] = newMap()
  m["greet"] = "hello"
  match mapGet(m, "greet") {
    case Some(v) -> assertEqual(v, "hello", "string value")
    case None    -> assertTrue(false, "should find")
  }
}
