//! byte_stringify_self_test.l — dual-target runtime regression test for
//! printing and stringifying a `Byte` (#7852).
//!
//! `Byte` is unsigned (0..255).  On dotnet, `println(<Byte>)` had no `Byte`
//! arm, so it fell through to `Console.WriteLine(string)` with an int32 on the
//! stack and threw `InvalidProgramException`; it now uses the int32 overload,
//! which prints the zero-extended value.  On the JVM, `toString(<Byte>)` boxed
//! to a signed `java.lang.Byte` and printed 128..255 as negatives, `.toString()`
//! and `println` did not re-mask a non-canonical byte, and a call returning
//! `Byte` handed back the signed byte `ireturn` narrows to.  Every case reads a
//! `Byte` from a local, a record field, a slice element, a call result and a
//! generic `Box[Byte]` field, with values 0, 127, 128 and 255.
//!
//! `println` output cannot be captured in-process; the println test proves it
//! runs (and, under `scripts/ilverify-selfhosted.sh`, verifies), and
//! `scripts/ci/byte-println-e2e.sh` checks the printed text on both targets.
//! `format1`/`format2` are covered by `byte_stringify_dotnet_self_test.l`
//! (the JVM `format*` builtins are unimplemented stubs, #7367/#7840).
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/byte_stringify_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/byte_stringify_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ByteStringifySelfTest

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

test "toString of a Byte local" {
  val a: Byte = 0u8
  val b: Byte = 127u8
  val c: Byte = 128u8
  val d: Byte = 255u8
  assertEqual(toString(a), "0", "0")
  assertEqual(toString(b), "127", "127")
  assertEqual(toString(c), "128", "128")
  assertEqual(toString(d), "255", "255")
}

test "toString of a Byte field, slice element and call result" {
  val h = ByteHolder(b = 128u8)
  val xs = sample()
  assertEqual(toString(h.b), "128", "field")
  assertEqual(toString(xs[0]), "0", "slice element 0")
  assertEqual(toString(xs[1]), "127", "slice element 127")
  assertEqual(toString(xs[2]), "128", "slice element 128")
  assertEqual(toString(xs[3]), "255", "slice element 255")
  assertEqual(toString(byteId(255u8)), "255", "call result")
  val r = byteId(128u8)
  assertEqual(toString(r), "128", "local bound from a call result")
}

test "method toString of a Byte" {
  val c: Byte = 128u8
  val d: Byte = 255u8
  assertEqual(c.toString(), "128", "local 128")
  assertEqual(d.toString(), "255", "local 255")
  assertEqual(byteId(200u8).toString(), "200", "call result")
  val h = ByteHolder(b = 255u8)
  val xs = sample()
  assertEqual(h.b.toString(), "255", "field")
  assertEqual(xs[2].toString(), "128", "slice element")
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
  val v: Byte = bx.value
  assertEqual(toString(v), "255", "toString")
  assertEqual("${bx.value}", "255", "interpolation")
  assertEqual(toString(bx.value), "255", "toString of the field")
  assertEqual("v=" + bx.value, "v=255", "String + the field")
  val small = Box(value = 127u8)
  assertEqual(toString(small.value), "127", "127")
}

// #7860 review: a `Byte` read back out of an erased position (a generic
// payload, a list element, a function-value result) is a boxed
// `java.lang.Byte` on the JVM; widening it with `.toUInt()`/`.toULong()`
// must unbox and mask it, so 200 stays 200 rather than -56.
test "a Byte from an erased position widens unsigned" {
  val bx = Box(value = 200u8)
  val xs: List[Byte] = newList()
  xs.add(255u8)
  val f: () -> Byte = { -> 128u8 }
  assertEqual(toString(bx.value.toUInt()), "200", "generic payload to UInt")
  assertEqual(toString(bx.value.toULong()), "200", "generic payload to ULong")
  assertEqual(toString(xs[0].toUInt()), "255", "list element to UInt")
  assertEqual(toString(f().toUInt()), "128", "function-value result to UInt")
  assertTrue(bx.value.toUInt() > 127u32, "compares unsigned")
  assertEqual(toString(xs[0].toULong() / 5u64), "51", "divides unsigned")
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
