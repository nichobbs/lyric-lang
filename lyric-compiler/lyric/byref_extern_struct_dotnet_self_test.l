//! byref_extern_struct_dotnet_self_test.l — dotnet runtime regression test
//! for `out`/`inout` parameters of an extern .NET value type (#8206).
//!
//! An assignment to an `out`/`inout` parameter whose type is an
//! `extern type` over a BCL struct stored through the managed pointer with
//! `stind.ref`, which is only defined for object references, so the method
//! failed with `InvalidProgramException` the first time it ran.  It now
//! stores with `stobj` and reads with `ldobj`.  dotnet-only: the extern types
//! are BCL types (`byref_value_type_self_test.l` covers the stdlib struct
//! types and generic type parameters on all three targets).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/byref_extern_struct_dotnet_self_test.l
//!
//! `scripts/ilverify-selfhosted.sh` verifies the test DLL.
@test_module
package Lyric.ByrefExternStructDotnetSelfTest

import Std.Core
import Std.Testing

extern type TimeSpan = "System.TimeSpan"

extern type Guid = "System.Guid"

func setTs(t: inout TimeSpan, ms: in Double): Unit {
  t = TimeSpan.FromMilliseconds(ms)
}

func addTs(t: inout TimeSpan, ms: in Double): Unit {
  t = t.Add(TimeSpan.FromMilliseconds(ms))
}

func outTs(t: out TimeSpan): Unit {
  t = TimeSpan.FromMilliseconds(7.0)
}

func forwardTs(t: inout TimeSpan): Unit {
  setTs(t, 99.0)
}

func outGuid(g: out Guid): Unit {
  g = Guid.Parse("0f8fad5b-d9cb-469f-a165-70867728950e")
}

test "inout TimeSpan is written through the pointer" {
  var t = TimeSpan.FromMilliseconds(1.0)
  setTs(t, 250.0)
  assertTrue(t.TotalMilliseconds == 250.0, "setTs")
}

test "inout TimeSpan is read and written through the pointer" {
  var t = TimeSpan.FromMilliseconds(10.0)
  addTs(t, 5.0)
  addTs(t, 5.0)
  assertTrue(t.TotalMilliseconds == 20.0, "addTs twice")
}

test "out TimeSpan and a forwarded inout TimeSpan" {
  var t = TimeSpan.FromMilliseconds(0.0)
  outTs(t)
  assertTrue(t.TotalMilliseconds == 7.0, "outTs")
  forwardTs(t)
  assertTrue(t.TotalMilliseconds == 99.0, "forwardTs")
}

test "out Guid" {
  var g = Guid.Parse("00000000-0000-0000-0000-000000000000")
  outGuid(g)
  assertEqual(g.ToString(), "0f8fad5b-d9cb-469f-a165-70867728950e", "outGuid")
}
