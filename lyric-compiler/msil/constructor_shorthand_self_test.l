//! Test constructor shorthand for extern types (.new syntax).
//! Tests docs/48 implementation: enable `.new(args)` calls on external types,
//! eliminating `@externTarget` wrapper functions and aligning MSIL with JVM.

@test_module
package Lyric.ConstructorShorthand

import Std.Core
import Std.Testing

// Test basic constructor call on a BCL type.
test "StringBuilder.new()" {
  extern type SBld = "System.Text.StringBuilder"

  val sb = SBld.new()
  assertTrue(true, "Constructor shorthand .new() compiles")
}

// Test constructor with arguments.
test "StringBuilder.new(capacity)" {
  extern type SBld = "System.Text.StringBuilder"

  val sb = SBld.new(16)
  assertTrue(true, "Constructor shorthand .new(args) compiles")
}

// Test overload resolution with different argument counts.
test "Constructor overload resolution" {
  extern type SBld = "System.Text.StringBuilder"

  val sb0 = SBld.new()
  val sb1 = SBld.new(32)
  assertTrue(true, "Constructor overload resolution works")
}
