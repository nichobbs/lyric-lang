//! byte_erased_positions_self_test.l — dual-target runtime regression test for
//! a `Byte` (and a literal `Bool`/`Char` module val) that passes through an
//! erased position: a function value's result or argument, a generic
//! function value, a generic record field, `Option`, a `List` (#7852).
//!
//! On dotnet a lambda is a `Func<object,…,object>`, so its result and
//! arguments are boxed, and the reader unboxes by the declared type.  Three
//! `Byte` producers were typed `MInt` and boxed as `System.Int32`, so the
//! reader's `unbox.any System.Byte` threw InvalidCastException:
//!
//! - a `u8` literal;
//! - a `Byte op Byte` sum, difference or product, which also never wrapped
//!   (`toString(200u8 + 100u8)` was "300", on the JVM too);
//! - an inlined literal module val, which read back as `MInt` whatever its
//!   type.  The same held for a `Bool` or `Char` val (`System.Boolean`/
//!   `System.Char` casts).
//!
//! On the JVM a `u8` literal was an `int`, so it boxed as `java.lang.Integer`
//! into a generic position and the `Byte` checkcast failed.  An erased
//! (`Object`) value that holds a boxed `Byte`, such as a lambda parameter typed
//! by a type argument, stringified through `Byte.toString()` and printed
//! 128..255 as negatives.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/byte_erased_positions_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/byte_erased_positions_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ByteErasedPositionsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

val LIT_BYTE = 209u8

val LIT_BYTE_TYPED: Byte = 210u8

val LIT_BOOL = true

val LIT_CHAR = 'Q'

record Box[T] {
  value: T
}

func mkByteFn(): () -> Byte {
  { -> 128u8 }
}

func applyT[T](f: () -> T): T {
  f()
}

func mapT[T, U](x: in T, f: (T) -> U): U {
  f(x)
}

func applyByte(f: (Byte) -> Byte, x: in Byte): Byte {
  f(x)
}

test "a Byte literal as a function value's result" {
  val f: () -> Byte = { -> 128u8 }
  val b: Byte = f()
  assertEqual(toString(b), "128", "local function value")
  assertEqual(toString(mkByteFn()()), "128", "function value returned from a function")
  val r: Byte = applyT({ -> 255u8 })
  assertEqual(toString(r), "255", "generic function value")
  val fs: List[() -> Byte] = newList()
  fs.add({ -> 130u8 })
  assertEqual(toString(fs[0]()), "130", "function value from a list")
}

test "a Byte as a function value's argument" {
  val f: (Byte) -> Byte = { x -> x }
  assertEqual(toString(f(250u8)), "250", "local function value")
  assertEqual(toString(applyByte({ x -> x }, 0u8)), "0", "higher-order parameter")
  assertEqual(toString(mapT(127u8, { b -> b })), "127", "generic Byte -> Byte")
  assertEqual(toString(mapT(7, { i -> 207u8 })), "207", "generic Int -> Byte")
}

test "a captured Byte in a function value" {
  val b: Byte = 250u8
  val c = 251u8
  val f: () -> Byte = { -> b }
  val g: () -> Byte = { -> c }
  assertEqual(toString(f()), "250", "annotated capture")
  assertEqual(toString(g()), "251", "inferred capture")
  var m: Byte = 1u8
  val h: () -> Unit = { -> m = 252u8 }
  h()
  assertEqual(toString(m), "252", "captured var")
}

// D163: plain `+`/`-`/`*` panic on overflow in a debug build, so the in-range
// forms check the result stays an unsigned Byte and `wrapping*` checks the
// 8-bit truncation.
test "Byte arithmetic stays a Byte, wrapping methods wrap" {
  val a: Byte = 200u8
  val b: Byte = 100u8
  assertEqual(toString(a + 50u8), "250", "add stays unsigned")
  assertEqual(toString(a - b), "100", "sub stays unsigned")
  assertEqual(toString(b * 2u8), "200", "mul stays unsigned")
  assertEqual(toString(a + 55u8), "255", "add at the top of the range")
  assertEqual(toString(a.wrappingAdd(b)), "44", "wrappingAdd wraps")
  assertEqual(toString(b.wrappingSub(a)), "156", "wrappingSub wraps")
  assertEqual(toString(a.wrappingMul(2u8)), "144", "wrappingMul wraps")
  val f: (Byte) -> Byte = { x -> x + 1u8 }
  assertEqual(toString(f(200u8)), "201", "in a function value")
  val g: () -> Byte = { -> a.wrappingAdd(b) }
  assertEqual(toString(g()), "44", "wrapped result of a function value")
  val h: () -> Byte = { -> a + 50u8 }
  assertEqual(toString(h()), "250", "unsigned result of a function value")
  val wide: Int = a.toInt() + 100
  assertEqual(toString(wide), "300", "an Int operand widens instead")
}

test "a Byte literal in a generic position" {
  val o: Option[Byte] = Some(200u8)
  match o {
    case Some(v) -> assertEqual(toString(v), "200", "Option payload")
    case None -> assertTrue(false, "expected Some")
  }
  val bx = Box(value = 203u8)
  val f: () -> Byte = { -> bx.value }
  assertEqual(toString(f()), "203", "captured generic field")
  val xs: List[Byte] = newList()
  xs.add(204u8)
  assertEqual(toString(xs[0]), "204", "List element")
}

test "an erased Byte stringifies unsigned" {
  assertEqual(mapT(206u8, { b -> toString(b) }), "206", "toString")
  assertEqual(mapT(208u8, { b -> b.toString() }), "208", "method toString")
  assertEqual(mapT(209u8, { b -> "${b}" }), "209", "interpolation")
  assertEqual(mapT(210u8, { b -> "v" + b }), "v210", "String +")
  mapT(211u8, { b -> println(b) })
}

test "a literal module val through a function value" {
  val fb: () -> Byte = { -> LIT_BYTE }
  val fbt: () -> Byte = { -> LIT_BYTE_TYPED }
  val fz: () -> Bool = { -> LIT_BOOL }
  val fc: () -> Char = { -> LIT_CHAR }
  assertEqual(toString(fb()), "209", "Byte")
  assertEqual(toString(fbt()), "210", "annotated Byte")
  assertTrue(fz(), "Bool")
  assertEqual(toString(fc()), "Q", "Char")
  val bx = Box(value = LIT_BYTE)
  assertEqual(toString(bx.value), "209", "Byte in a generic field")
  val bz = Box(value = LIT_BOOL)
  assertTrue(bz.value, "Bool in a generic field")
  assertEqual(toString(LIT_CHAR), "Q", "Char read directly")
}

test "other primitives through function values" {
  val fu: (UInt) -> UInt = { x -> x }
  assertEqual(toString(fu(4000000000u32)), "4000000000", "UInt")
  val ful: (ULong) -> ULong = { x -> x }
  assertEqual(toString(ful(5u64)), "5", "ULong")
  val fc: (Char) -> Char = { c -> c }
  assertEqual(toString(fc('Z')), "Z", "Char")
  val fz: (Bool) -> Bool = { b -> not b }
  assertTrue(fz(false), "Bool")
  val fd: (Double) -> Double = { d -> d * 2.0 }
  assertEqual(toString(fd(1.25)), "2.5", "Double")
  val fl: () -> Long = { -> 5i64 }
  assertEqual(toString(fl()), "5", "Long")
}
