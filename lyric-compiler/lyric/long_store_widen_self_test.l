//! An `Int` stored into a `Long` location widens to 64 bits (#7783).
//!
//! The type checker accepts `Int` where `Long` is declared (the lossless
//! `Byte < Int < Long` chain, docs/01 "Numeric / character conversions") on
//! every assignment form, but the dotnet backend stored the int32 straight
//! into the int64 local/field/cell/byref, and the compound forms (`l += i`)
//! combined an int64 with an int32 — unverifiable IL (ECMA-335 III.1.5) that
//! only worked because CoreCLR's JIT sign-extends implicitly.  Each case uses
//! a negative `Int` and a result outside the Int32 range, so any truncation
//! or zero-extension shows up.  Also covers a `Byte`-backed range subtype,
//! whose `from`/`tryFrom` bounds were pushed as int64 against the int32 byte.
//! Runs on dotnet and JVM; the dotnet test DLL is verified by
//! `scripts/ilverify-selfhosted.sh` phase 4.
@test_module
package LongStoreWidenSelfTest

import Std.Core
import Std.Testing

record LongCell {
  var v: Long
}

record Box[T] {
  var value: T
}

type Level = Byte range 10 ..= 250

func big(): Long = 3000000000i64

func levelOk(r: in Result[Level, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

func bumpInout(x: inout Long, by: in Int): Unit {
  x += by
  x *= by
}

func setInout(x: inout Long, to: in Int): Unit {
  x = to
}

test "a local: plain and compound stores of a negative Int" {
  val neg: Int = -5
  var l: Long = big()
  l += neg
  assertEqual(toString(l), "2999999995", "Long += negative Int")
  l *= neg
  assertEqual(toString(l), "-14999999975", "Long *= negative Int")
  l = neg
  assertEqual(toString(l), "-5", "Long = negative Int")
  l -= neg
  assertEqual(toString(l), "0", "Long -= negative Int")
}

test "a record field: plain and compound stores" {
  val neg: Int = -5
  val c = LongCell(v = big())
  c.v += neg
  assertEqual(toString(c.v), "2999999995", "field += negative Int")
  c.v *= 2
  assertEqual(toString(c.v), "5999999990", "field *= Int literal")
  c.v = neg
  assertEqual(toString(c.v), "-5", "field = negative Int")
}

test "a generic record field instantiated at Long" {
  val neg: Int = -5
  val b = Box(value = big())
  b.value += neg
  assertEqual(toString(b.value), "2999999995", "Box[Long].value += negative Int")
  b.value *= 3
  assertEqual(toString(b.value), "8999999985", "Box[Long].value *= Int literal")
  b.value = neg
  assertEqual(toString(b.value), "-5", "Box[Long].value = negative Int")
}

test "an inout Long parameter" {
  var l: Long = big()
  bumpInout(l, -2)
  assertEqual(toString(l), "-5999999996", "inout += then *= negative Int")
  setInout(l, -7)
  assertEqual(toString(l), "-7", "inout = negative Int")
}

test "a var captured and assigned by a closure" {
  val neg: Int = -5
  var l: Long = big()
  val bump = { -> l += neg }
  bump()
  assertEqual(toString(l), "2999999995", "captured Long += negative Int")
  val reset = { -> l = neg }
  reset()
  assertEqual(toString(l), "-5", "captured Long = negative Int")
}

test "a Byte-backed range subtype checks its bounds as bytes" {
  assertTrue(levelOk(Level.tryFrom(10u8)), "lower bound inclusive")
  assertTrue(levelOk(Level.tryFrom(200u8)), "200 is in range")
  assertTrue(levelOk(Level.tryFrom(250u8)), "upper bound inclusive")
  assertFalse(levelOk(Level.tryFrom(9u8)), "below the lower bound")
  assertFalse(levelOk(Level.tryFrom(251u8)), "above the upper bound")
  val _ = Level.from(42u8)
  assertPanics("Level.from(251) panics above the upper bound", { -> val _ = Level.from(251u8) })
}
