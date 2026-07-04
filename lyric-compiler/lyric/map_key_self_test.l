//! map_key_self_test.l — #1480: records with `@derive(Equals)` + `@derive(Hash)`
//! work correctly as BCL `Map` (Dictionary) / `java.util.HashMap` keys.
//!
//! `Lyric.Derives` synthesises free `<Type>.equals(self, other)` /
//! `<Type>.hash(self)` helpers; the codegen now also emits real
//! `Object.Equals(object)` / `GetHashCode()` *overrides* on MSIL and
//! `equals(Object)` / `hashCode()` *overrides* on JVM (`Jvm.Lowering`'s
//! `buildDeriveEqualsFunc`/`buildDeriveHashCodeFunc`, wired into
//! `Jvm.Codegen.lowerRecord`'s `IRecord`/`IExposedRec` handling — #4982
//! Finding 1) on the record's TypeDef/classfile (delegating to those
//! helpers).  BCL `Dictionary` / `java.util.HashMap` both dispatch
//! GetHashCode+Equals / hashCode+equals virtually on the key, so two
//! *field-equal* record instances now hash and compare as the same key on
//! both targets — previously they were distinct (identity-based), so a
//! lookup with a fresh-but-equal key missed.
//!
//! Run in CI via native `lyric test` on BOTH targets (in-process through
//! `Msil.Bridge` / `Jvm.Bridge`).  Imports only `Std.*`.
//!
//! NOTE: value-type Map *values* (`Map[Point, Int]`) are blocked by a separate,
//! pre-existing `Map[ObjectKey, ValueTypeValue]` codegen bug (reproduces with a
//! plain record key and no `@derive`); this test uses `String`/record values,
//! which are unaffected.
@test_module
package Lyric.MapKeySelfTest

import Std.Core
import Std.Collections
import Std.Testing

@derive(Equals)
@derive(Hash)
record Point {
  x: Int
  y: Int
}

test "field-equal record instance finds a Map entry (structural key)" {
  val m: Map[Point, String] = newMap()
  m[Point(x = 1, y = 2)] = "a"
  m[Point(x = 3, y = 4)] = "b"
  // containsKey with a *different* instance that is field-equal.
  assertTrue(m.containsKey(Point(x = 1, y = 2)), "field-equal key (1,2) present")
  assertTrue(m.containsKey(Point(x = 3, y = 4)), "field-equal key (3,4) present")
  assertTrue(not m.containsKey(Point(x = 9, y = 9)), "absent key (9,9)")
}

test "mapGet retrieves via a fresh field-equal key" {
  val m: Map[Point, String] = newMap()
  m[Point(x = 7, y = 8)] = "hello"
  match mapGet(m, Point(x = 7, y = 8)) {
    case Some(v) -> assertEqual(v, "hello", "value via a distinct but equal key")
    case None -> assertTrue(false, "should find via equal key")
  }
}

test "equal record keys collapse to one entry (structural GetHashCode + Equals)" {
  val m: Map[Point, String] = newMap()
  m[Point(x = 5, y = 5)] = "first"
  m[Point(x = 5, y = 5)] = "second"
  assertEqualInt(m.count, 1, "two field-equal keys -> one entry")
  match mapGet(m, Point(x = 5, y = 5)) {
    case Some(v) -> assertEqual(v, "second", "second write overwrote the first")
    case None -> assertTrue(false, "should find")
  }
}

test "distinct field values are distinct keys" {
  val m: Map[Point, String] = newMap()
  m[Point(x = 1, y = 1)] = "p"
  m[Point(x = 1, y = 2)] = "q"
  m[Point(x = 2, y = 1)] = "r"
  assertEqualInt(m.count, 3, "three distinct keys")
  match mapGet(m, Point(x = 1, y = 2)) {
    case Some(v) -> assertEqual(v, "q", "(1,2) -> q")
    case None -> assertTrue(false, "should find (1,2)")
  }
}
