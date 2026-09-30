//! byte_stringify_dotnet_self_test.l — `format1`/`format2` of a `Byte`
//! (#7852), the dotnet-only companion of `byte_stringify_self_test.l`.
//!
//! `String.Format` boxes each argument; a `Byte` must box as `System.Byte` so
//! 128..255 render unsigned.  This is dotnet-only because the JVM `format*`
//! builtins are unimplemented stubs that return the template unformatted
//! (#7367/#7840); move these cases into `byte_stringify_self_test.l` when that
//! lands.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/byte_stringify_dotnet_self_test.l
@test_module
package Lyric.ByteStringifyDotnetSelfTest

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

test "format1 of a Byte" {
  val d: Byte = 255u8
  val h = ByteHolder(b = 128u8)
  val xs = sample()
  val bx = Box(value = 200u8)
  assertEqual(format1("{0}", d), "255", "local")
  assertEqual(format1("{0}", h.b), "128", "field")
  assertEqual(format1("{0}", xs[0]), "0", "slice element 0")
  assertEqual(format1("{0}", xs[1]), "127", "slice element 127")
  assertEqual(format1("{0}", byteId(255u8)), "255", "call result")
  assertEqual(format1("{0}", bx.value), "200", "generic field")
}

test "format2 of Bytes" {
  val d: Byte = 255u8
  val h = ByteHolder(b = 128u8)
  assertEqual(format2("{0} {1}", d, h.b), "255 128", "local and field")
  assertEqual(format2("{0}/{1}", byteId(0u8), byteId(127u8)), "0/127", "call results")
}
