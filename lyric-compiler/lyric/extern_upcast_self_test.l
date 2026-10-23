//! lyric-compiler/lyric/extern_upcast_self_test.l
//!
//! @test_module for the explicit extern upcast `externAsObject(x)` on the .NET
//! target (D212, #7975): extern values reach a `List[Obj]` and an `Obj`-typed
//! parameter through the named upcast, and the value that comes back out is the
//! same object.  A value-typed extern (`System.TimeSpan`) is boxed.  The file
//! declares itself part of the extern boundary with a file-level `@unsafe_ffi`
//! (N0103 elsewhere).
//!
//! Run: ./bin/lyric test lyric-compiler/lyric/extern_upcast_self_test.l
@test_module
@unsafe_ffi
package Lyric.ExternUpcastSelfTest

import Std.Core
import Std.Collections
import Std.Testing

extern type Obj = "System.Object"

extern type Ts = "System.TimeSpan"

extern type Sb = "System.Text.StringBuilder"

func describe(o: in Obj): String = o.ToString()

test "extern values are added to a List[Obj] through the upcast" {
  val sb = Sb.new("hello")
  val ts = Ts.FromSeconds(90.0)
  val items: List[Obj] = newList()
  items.add(externAsObject(sb))
  items.add(externAsObject(ts))
  assertEqualInt(items.count, 2, "two elements")
  assertEqual(describe(items[0]), "hello", "first element is the builder")
  assertEqual(describe(items[1]), "00:01:30", "second element is the boxed TimeSpan")
}

test "an upcast value passes to an Obj parameter and keeps its identity" {
  val sb = Sb.new("a")
  val o: Obj = externAsObject(sb)
  sb.Append("b")
  assertEqual(describe(o), "ab", "the upcast aliases the builder")
  assertEqual(describe(externAsObject(sb)), "ab", "an inline upcast argument")
}

test "upcasting an Obj is the identity" {
  val sb = Sb.new("x")
  val o: Obj = externAsObject(sb)
  val again: Obj = externAsObject(o)
  assertEqual(describe(again), "x", "Obj upcast to Obj")
}
