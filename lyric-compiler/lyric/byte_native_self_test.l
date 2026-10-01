//! byte_native_self_test.l — `--target native` runtime regression test for
//! printing, stringifying and doing arithmetic on a `Byte` (#7858, following
//! #7852).
//!
//! `Byte` is unsigned (0..255) and lowers to LLVM `i8`, so every widening must
//! zero-extend and every result must wrap modulo 256. Every stringification
//! case reads a `Byte` from a local, a record field, a slice element, a call
//! result and a generic `Box[Byte]` field, with values 0, 127, 128 and 255.
//!
//! Before #7858, `println(<Byte>)` resolved to `Std.Console.println(String)`
//! whenever `Std.Console` was in the import closure and failed to compile,
//! `String + <Byte>` was rejected as a mixed String/non-String operation, and
//! an unannotated `u8` literal lowered as an `Int`: `200u8 + 100u8` was 300
//! and `Box(value = 255u8)` was a `Box[Int]`.
//!
//! `println` output cannot be captured in-process;
//! `scripts/ci/byte-println-e2e.sh native` checks the six lines printed just
//! before `byte-println-end`.
//!
//!   lyric test --target native lyric-compiler/lyric/byte_native_self_test.l
@test_module
package Lyric.ByteNativeSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record ByteHolder {
  b: Byte
}

record Box[T] {
  value: T
}

func byteId(b: in Byte): Byte {
  b
}

func sample(): slice[Byte] {
  [0u8, 127u8, 128u8, 255u8]
}

test "toString of a Byte" {
  val a: Byte = 0u8
  val b: Byte = 127u8
  val c: Byte = 128u8
  val d: Byte = 255u8
  val h = ByteHolder(b = 128u8)
  val xs = sample()
  assertEqual(toString(a), "0", "0")
  assertEqual(toString(b), "127", "127")
  assertEqual(toString(c), "128", "128")
  assertEqual(toString(d), "255", "255")
  assertEqual(toString(h.b), "128", "field")
  assertEqual(toString(xs[3]), "255", "slice element")
  assertEqual(toString(byteId(209u8)), "209", "call result")
}

test "method toString of a Byte" {
  val d: Byte = 255u8
  val h = ByteHolder(b = 128u8)
  val xs = sample()
  assertEqual(d.toString(), "255", "local")
  assertEqual(h.b.toString(), "128", "field")
  assertEqual(xs[2].toString(), "128", "slice element")
  assertEqual(byteId(200u8).toString(), "200", "call result")
}

test "interpolation of a Byte" {
  val d: Byte = 255u8
  val h = ByteHolder(b = 128u8)
  val xs = sample()
  assertEqual("v=${d}", "v=255", "local")
  assertEqual("v=${h.b}", "v=128", "field")
  assertEqual("v=${xs[3]}", "v=255", "slice element")
  assertEqual("v=${byteId(200u8)}", "v=200", "call result")
}

test "String + Byte" {
  val d: Byte = 255u8
  val h = ByteHolder(b = 128u8)
  val xs = sample()
  assertEqual("v=" + d, "v=255", "local")
  assertEqual("v=" + h.b, "v=128", "field")
  assertEqual("v=" + xs[2], "v=128", "slice element")
  assertEqual("v=" + byteId(200u8), "v=200", "call result")
}

test "generic Box[Byte] field" {
  val bx = Box(value = 255u8)
  assertEqual(toString(bx.value), "255", "toString")
  assertEqual("${bx.value}", "255", "interpolation")
  assertEqual("v=" + bx.value, "v=255", "String +")
}

test "Byte arithmetic wraps modulo 256" {
  val a: Byte = 200u8
  val b: Byte = 100u8
  val sum: Byte = a + b
  val diff: Byte = b - a
  val prod: Byte = 16u8 * 17u8
  assertEqualInt(sum.toInt(), 44, "200 + 100")
  assertEqualInt(diff.toInt(), 156, "100 - 200")
  assertEqualInt(prod.toInt(), 16, "16 * 17")
  assertEqualInt((a / 3u8).toInt(), 66, "200 / 3 is unsigned")
  assertEqualInt((a % 3u8).toInt(), 2, "200 % 3 is unsigned")
  assertTrue(a > b, "200 > 100 compares unsigned")
  var c: Byte = 250u8
  c += 10u8
  assertEqualInt(c.toInt(), 4, "250 += 10")
  c -= 5u8
  assertEqualInt(c.toInt(), 255, "4 -= 5")
}

test "an unannotated u8 literal is a Byte" {
  val a = 200u8
  val sum = a + 100u8
  assertEqualInt(sum.toInt(), 44, "200u8 + 100u8 wraps")
  assertEqual(toString(sum), "44", "toString of the sum")
  val bx = Box(value = 255u8)
  val next: Byte = bx.value + 1u8
  assertEqualInt(next.toInt(), 0, "Box[Byte] payload wraps")
  val typed: Box[Byte] = Box(value = 128u8)
  assertEqual("v=" + typed.value, "v=128", "annotated Box[Byte]")
}

test "println of a Byte" {
  val a: Byte = 0u8
  val d: Byte = 255u8
  val h = ByteHolder(b = 128u8)
  val xs = sample()
  val bx = Box(value = 200u8)
  println(a)
  println(d)
  println(h.b)
  println(xs[1])
  println(byteId(200u8))
  println(bx.value)
  println("byte-println-end")
  assertTrue(true, "printing a Byte does not throw")
}
