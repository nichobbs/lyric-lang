//! println_extern_struct_dotnet_self_test.l — dotnet runtime regression test
//! for `println` of an extern .NET value type reached through auto-FFI
//! (#7858).
//!
//! `println`'s catch-all handed any value it had no `Console.WriteLine`
//! overload for to `WriteLine(string)` unconverted. For a struct such as
//! `System.TimeSpan`, `System.DateTime`, `System.Guid`, `System.Decimal`,
//! `System.IntPtr` or a `System.Single` (which auto-FFI maps to the extern
//! value type, not to `Double`) that was invalid IL, and the method threw
//! `InvalidProgramException`. It now prints what `toString(x)` returns.
//!
//! Each case prints the value and then its `toString` between the
//! `println-pairs-begin` and `println-pairs-end` markers;
//! `scripts/ci/println-stringify-e2e.sh` checks the pairs are equal, and
//! `scripts/ilverify-selfhosted.sh` verifies the test DLL. dotnet-only: the
//! extern types are BCL types.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/println_extern_struct_dotnet_self_test.l
@test_module
package Lyric.PrintlnExternStructDotnetSelfTest

import Std.Core
import Std.Testing

extern type Ts = "System.TimeSpan"

extern type Dt = "System.DateTime"

extern type Gd = "System.Guid"

extern type Dec = "System.Decimal"

extern type Fl = "System.Single"

extern type Ip = "System.IntPtr"

test "toString of an extern struct" {
  assertEqual(toString(Ts.FromMinutes(90.0)), "01:30:00", "TimeSpan")
  assertEqual(toString(Dt.new(2020, 1, 2, 3, 4, 5)), "2020-01-02T03:04:05.0000000", "DateTime")
  assertEqual(
    toString(Gd.Parse("0f8fad5b-d9cb-469f-a165-70867728950e")),
    "0f8fad5b-d9cb-469f-a165-70867728950e",
    "Guid"
  )
  assertEqual(toString(Ip.new(5)), "5", "IntPtr")
}

test "println of an extern struct" {
  val span = Ts.FromMinutes(90.0)
  val stamp = Dt.new(2020, 1, 2, 3, 4, 5)
  val id = Gd.Parse("0f8fad5b-d9cb-469f-a165-70867728950e")
  val amount = Dec.Parse("1.25")
  val single = Fl.Parse("1.5")
  val ptr = Ip.new(5)
  println("println-pairs-begin")
  println(span)
  println(toString(span))
  println(stamp)
  println(toString(stamp))
  println(id)
  println(toString(id))
  println(amount)
  println(toString(amount))
  println(single)
  println(toString(single))
  println(ptr)
  println(toString(ptr))
  println(Ts.FromSeconds(5.0))
  println(toString(Ts.FromSeconds(5.0)))
  println("println-pairs-end")
  assertTrue(true, "printing an extern struct does not throw")
}
