//! Unsigned operations follow the checked type, not the operand's shape (#7812).
//!
//! `UInt` and `ULong` lower to the same representation as `Int` and `Long` on
//! both targets, so stringification, `<`/`<=`/`>`/`>=`, `/` and `%` must be
//! told an operand is unsigned.  The backends used to guess it from the
//! operand's shape (a bare local, a suffixed literal), so a field read, an
//! element, a call result or a match binding with its top bit set printed,
//! compared and divided as a negative number.  The type checker now marks
//! every such operand.  Every value below is at least 2^31 (`UInt`) or 2^63
//! (`ULong`).  Native has no unsigned integer types yet, so this runs on
//! dotnet and JVM.
@test_module
package UnsignedTypedOpsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Holder {
  var v: ULong
  var u: UInt

  func getV(self: in Holder): ULong {
    self.v
  }
}

record Box[T] {
  value: T
}

union Size {
  case Known(n: ULong)
  case Unknown
}

// 2^64 - 1 and 2^63, computed: a `u64` literal above `Long`'s range is
// rejected by the lexer (L0010).
func maxU64(): ULong {
  9223372036854775807u64 * 2u64 + 1u64
}

func signBitU64(): ULong {
  9223372036854775807u64 + 1u64
}

func bigU32(): UInt {
  4000000000u32
}

func idOf[T](x: in T): T {
  x
}

func showOf[T](x: in T): String = "${x}"

func firstShown[T](xs: in List[T]): String {
  toString(xs[0])
}

func holder(): Holder {
  Holder(v = maxU64(), u = 4000000000u32)
}

test "a record field read" {
  val h = holder()
  assertEqual(toString(h.v), "18446744073709551615", "toString(ULong field)")
  assertEqual("${h.v}", "18446744073709551615", "interpolated ULong field")
  assertEqual(h.v.toString(), "18446744073709551615", ".toString() on a ULong field")
  assertEqual("v=" + h.v, "v=18446744073709551615", "String + ULong field")
  assertEqual(toString(h.u), "4000000000", "toString(UInt field)")
  assertEqual("${h.u}", "4000000000", "interpolated UInt field")
  assertEqual(h.u.toString(), "4000000000", ".toString() on a UInt field")
  assertTrue(h.v > 1u64, "ULong field >")
  assertFalse(h.v < 1u64, "ULong field <")
  assertTrue(h.v >= signBitU64(), "ULong field >=")
  assertFalse(h.v <= 1u64, "ULong field <=")
  assertTrue(1u64 < h.v, "ULong field on the right of <")
  assertTrue(h.u > 1u32, "UInt field >")
  assertFalse(h.u < 1u32, "UInt field <")
  assertTrue(h.u >= 2147483648u32, "UInt field >=")
  assertFalse(h.u <= 1u32, "UInt field <=")
  assertEqual(toString(h.v / 10u64), "1844674407370955161", "ULong field /")
  assertEqual(toString(h.v % 10u64), "5", "ULong field %")
  assertEqual(toString(h.u / 10u32), "400000000", "UInt field /")
  assertEqual(toString(h.u % 7u32), "3", "UInt field %")
  assertEqual(toString(h.v / h.v), "1", "ULong field / ULong field")
}

test "an unsuffixed literal beside an unsigned field" {
  val h = holder()
  assertTrue(h.v > 1, "ULong field > literal")
  assertTrue(h.u > 1, "UInt field > literal")
  assertEqual(toString(h.v / 10), "1844674407370955161", "ULong field / literal")
  assertEqual(toString(h.u % 7), "3", "UInt field % literal")
}

test "compound division and remainder on an unsigned field" {
  val h = holder()
  h.v /= 10u64
  assertEqual(toString(h.v), "1844674407370955161", "ULong field /=")
  h.v = maxU64()
  h.v %= 10u64
  assertEqual(toString(h.v), "5", "ULong field %=")
  h.u /= 10u32
  assertEqual(toString(h.u), "400000000", "UInt field /=")
  h.u = bigU32()
  h.u %= 7u32
  assertEqual(toString(h.u), "3", "UInt field %=")
  val h2 = holder()
  h.v = maxU64()
  h.v /= h2.v
  assertEqual(toString(h.v), "1", "ULong field /= ULong field")
  h.u = 3000000000u32
  h.u %= h2.u
  assertEqual(toString(h.u), "3000000000", "UInt field %= UInt field")
  var s = "v="
  s += h2.v
  assertEqual(s, "v=18446744073709551615", "String += ULong field")
}

// #7841: an unsuffixed literal assigned or compound-assigned to a `Byte`,
// `UInt` or `ULong` takes the target's type.
test "an unsuffixed literal on the right of an assignment (#7841)" {
  var u: UInt = 4000000000u32
  u %= 7
  assertEqual(toString(u), "3", "UInt %= 7")
  u = 4000000000
  assertEqual(toString(u), "4000000000", "UInt = 4000000000")
  u /= 3
  assertEqual(toString(u), "1333333333", "UInt /= 3")
  u = 3000000000
  u += 1000000000
  assertEqual(toString(u), "4000000000", "UInt += 1000000000")
  u -= 5
  assertEqual(toString(u), "3999999995", "UInt -= 5")
  u = 2000000000
  u *= 2
  assertEqual(toString(u), "4000000000", "UInt *= 2")
  assertTrue(u > 2147483648u32, "an assigned UInt above 2^31 compares unsigned")
  var l: ULong = maxU64()
  l %= 10
  assertEqual(toString(l), "5", "ULong %= 10")
  l = 9
  l += 9223372036854775807
  assertEqual(toString(l), "9223372036854775816", "ULong += 9223372036854775807")
  l /= 2
  assertEqual(toString(l), "4611686018427387908", "ULong /= 2")
  l -= 8
  l *= 2
  assertEqual(toString(l), "9223372036854775800", "ULong -= 8, *= 2")
  var b: Byte = 200u8
  b += 50
  assertEqual(toString(b), "250", "Byte += 50")
  b -= 100
  assertEqual(toString(b), "150", "Byte -= 100")
  b /= 7
  assertEqual(toString(b), "21", "Byte /= 7")
  b %= 4
  assertEqual(toString(b), "1", "Byte %= 4")
  b *= 3
  assertEqual(toString(b), "3", "Byte *= 3")
  b = 255
  assertEqual(toString(b), "255", "Byte = 255")
  val h = holder()
  h.u %= 7
  assertEqual(toString(h.u), "3", "UInt field %= 7")
  h.v /= 10
  assertEqual(toString(h.v), "1844674407370955161", "ULong field /= 10")
  var i = 10
  i %= 7
  assertEqual(toString(i), "3", "Int %= 7")
  var lg: Long = 10
  lg += 7
  assertEqual(toString(lg), "17", "Long += 7")
}

test "a slice element" {
  val xs: slice[ULong] = [maxU64(), 10u64]
  val us: slice[UInt] = [4000000000u32, 7u32]
  assertEqual(toString(xs[0]), "18446744073709551615", "toString(ULong element)")
  assertEqual("${xs[0]}", "18446744073709551615", "interpolated ULong element")
  assertEqual(xs[0].toString(), "18446744073709551615", ".toString() on a ULong element")
  assertTrue(xs[0] > xs[1], "ULong element >")
  assertTrue(xs[1] < xs[0], "ULong element <")
  assertTrue(xs[0] >= xs[1], "ULong element >=")
  assertTrue(xs[1] <= xs[0], "ULong element <=")
  assertEqual(toString(xs[0] / xs[1]), "1844674407370955161", "ULong element /")
  assertEqual(toString(xs[0] % xs[1]), "5", "ULong element %")
  assertEqual("${us[0]}", "4000000000", "interpolated UInt element")
  assertTrue(us[0] > us[1], "UInt element >")
  assertEqual(toString(us[0] / us[1]), "571428571", "UInt element /")
  assertEqual(toString(us[0] % us[1]), "3", "UInt element %")
}

test "a function and a method result" {
  val h = holder()
  assertEqual(toString(maxU64()), "18446744073709551615", "toString(ULong call)")
  assertEqual("${maxU64()}", "18446744073709551615", "interpolated ULong call")
  assertTrue(maxU64() > 1u64, "ULong call >")
  assertTrue(maxU64() >= signBitU64(), "ULong call >=")
  assertEqual(toString(maxU64() / 10u64), "1844674407370955161", "ULong call /")
  assertEqual(toString(maxU64() % 10u64), "5", "ULong call %")
  assertEqual("${bigU32()}", "4000000000", "interpolated UInt call")
  assertTrue(bigU32() > 1u32, "UInt call >")
  assertEqual(toString(bigU32() % 7u32), "3", "UInt call %")
  assertEqual(toString(h.getV()), "18446744073709551615", "toString(ULong method)")
  assertEqual("${h.getV()}", "18446744073709551615", "interpolated ULong method")
  assertTrue(h.getV() > 1u64, "ULong method >")
  assertFalse(h.getV() <= 1u64, "ULong method <=")
  assertEqual(toString(h.getV() / 10u64), "1844674407370955161", "ULong method /")
}

test "a generic instance's value and a generic call's result" {
  val b = Box(value = maxU64())
  val bu = Box(value = 4000000000u32)
  assertEqual(toString(b.value), "18446744073709551615", "toString(Box[ULong].value)")
  assertEqual("${b.value}", "18446744073709551615", "interpolated Box[ULong].value")
  assertTrue(b.value > 1u64, "Box[ULong].value >")
  assertEqual(toString(b.value / 10u64), "1844674407370955161", "Box[ULong].value /")
  assertEqual(toString(b.value % 10u64), "5", "Box[ULong].value %")
  assertEqual("${bu.value}", "4000000000", "interpolated Box[UInt].value")
  assertTrue(bu.value >= 2147483648u32, "Box[UInt].value >=")
  assertEqual(toString(idOf(maxU64())), "18446744073709551615", "toString(generic call)")
  assertTrue(idOf(maxU64()) > 1u64, "generic call >")
  assertEqual(toString(idOf(maxU64()) % 10u64), "5", "generic call %")
}

test "a List element and a Map value" {
  val ls: List[ULong] = newList()
  ls.add(maxU64())
  val m: Map[String, ULong] = newMap()
  m.add("k", maxU64())
  val lu: List[UInt] = newList()
  lu.add(4000000000u32)
  assertEqual(toString(ls[0]), "18446744073709551615", "toString(List element)")
  assertEqual("${ls[0]}", "18446744073709551615", "interpolated List element")
  assertTrue(ls[0] > 1u64, "List element >")
  assertEqual(toString(ls[0] / 10u64), "1844674407370955161", "List element /")
  assertEqual(toString(m["k"]), "18446744073709551615", "toString(Map value)")
  assertEqual("v=" + m["k"], "v=18446744073709551615", "String + Map value")
  assertTrue(m["k"] >= signBitU64(), "Map value >=")
  assertEqual(toString(m["k"] % 10u64), "5", "Map value %")
  assertEqual("${lu[0]}", "4000000000", "interpolated List[UInt] element")
  assertTrue(lu[0] > 1u32, "List[UInt] element >")
}

test "a tuple element and a match binding" {
  val t: (ULong, UInt) = (maxU64(), 4000000000u32)
  match t {
    case (a, c) -> {
      assertEqual(toString(a), "18446744073709551615", "toString(tuple ULong)")
      assertEqual("${c}", "4000000000", "interpolated tuple UInt")
      assertTrue(a > 1u64, "tuple ULong >")
      assertTrue(c > 1u32, "tuple UInt >")
      assertEqual(toString(a / 10u64), "1844674407370955161", "tuple ULong /")
      assertEqual(toString(c % 7u32), "3", "tuple UInt %")
    }
  }
  val s: Size = Known(n = maxU64())
  match s {
    case Known(n) -> {
      assertEqual(toString(n), "18446744073709551615", "toString(match binding)")
      assertEqual("${n}", "18446744073709551615", "interpolated match binding")
      assertTrue(n > 1u64, "match binding >")
      assertFalse(n < 1u64, "match binding <")
      assertEqual(toString(n / 10u64), "1844674407370955161", "match binding /")
      assertEqual(toString(n % 10u64), "5", "match binding %")
    }
    case Unknown -> assertTrue(false, "Known expected")
  }
}

test "a function value's result" {
  val f: () -> ULong = { -> maxU64() }
  val g: () -> UInt = { -> 4000000000u32 }
  assertEqual(toString(f()), "18446744073709551615", "toString(function value result)")
  assertEqual("${f()}", "18446744073709551615", "interpolated function value result")
  assertTrue(f() > 1u64, "function value result >")
  assertEqual(toString(f() / 10u64), "1844674407370955161", "function value result /")
  assertEqual("${g()}", "4000000000", "interpolated UInt function value result")
  assertTrue(g() >= 2147483648u32, "UInt function value result >=")
  assertEqual(toString(g() % 7u32), "3", "UInt function value result %")
}

test "toUInt widens a Byte and is the identity on a UInt" {
  val b: Byte = 200.toByte()
  assertEqual(toString(b.toUInt()), "200", "Byte.toUInt()")
  val u: UInt = bigU32()
  assertEqual(toString(u.toUInt()), "4000000000", "UInt.toUInt()")
  val widen: (UInt) -> UInt = { x: UInt -> x }
  assertEqual(toString(widen(b)), "200", "a Byte argument to a function value's UInt parameter")
}

test "a signed value stays signed" {
  val xs: slice[Long] = [-1, 10]
  assertEqual(toString(xs[0]), "-1", "Long element")
  assertTrue(xs[0] < xs[1], "Long element <")
  assertEqual(toString(xs[0] / xs[1]), "0", "Long element /")
}

test "a monomorphised generic body" {
  val ls: List[ULong] = newList()
  ls.add(maxU64())
  assertEqual(showOf(maxU64()), "18446744073709551615", "interpolated T = ULong")
  assertEqual(showOf(bigU32()), "4000000000", "interpolated T = UInt")
  assertEqual(firstShown(ls), "18446744073709551615", "toString of a List[T] element, T = ULong")
}

test "a variable a closure captures" {
  var acc: ULong = maxU64()
  val halve = { -> acc = acc / 2u64 }
  halve()
  assertEqual("${acc}", "9223372036854775807", "captured ULong var /")
  assertTrue(acc > 1u64, "captured ULong var >")
}
