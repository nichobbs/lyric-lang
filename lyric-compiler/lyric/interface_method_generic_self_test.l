//! Interface methods with type parameters of their own (#7791 item 2).
//!
//! The conformance check puts the interface method's type parameters in scope
//! on both sides (an impl may rename them), and the JVM erases them in the
//! abstract method's descriptor instead of naming a class `U`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/interface_method_generic_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/interface_method_generic_self_test.l
//!
//! Generic interface methods are not lowered on `--target native` (N0007).
@test_module
package Lyric.InterfaceMethodGenericSelfTest

import Std.Core
import Std.Testing

interface Echo {
  func id[U](self: in Self, x: in U): U
}

record R {
  n: Int
}

impl Echo for R {
  func id[V](self: in R, x: in V): V = x
}

test "an interface method generic over its own type parameter runs on both Int and String" {
  val e: Echo = R(n = 1)
  assertEqualInt(e.id(5), 5, "Int")
  assertEqual(e.id("s"), "s", "String")
}
