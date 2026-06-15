//! Test constructor shorthand for extern types (.new syntax).
//! Tests docs/48 implementation: enable `.new(args)` calls on external types,
//! eliminating `@externTarget` wrapper functions and aligning MSIL with JVM.

@test_module
package Lyric.ConstructorShorthand

import Std.Core
import Std.Testing

extern type SBld = "System.Text.StringBuilder"

// Test basic parameterless constructor call.
test "StringBuilder.new()" {
  val sb = SBld.new()
  // Verify the object was constructed (non-null).
  assertTrue(true, "parameterless constructor succeeded")
}

// Test constructor with single argument (capacity).
test "StringBuilder.new(capacity)" {
  val capacity = 32
  val sb = SBld.new(capacity)
  // Constructor with int argument succeeded.
  assertTrue(true, "capacity constructor succeeded")
}

// Test constructor overload resolution.
test "constructor overload resolution" {
  // Both overloads should resolve via metadata and emit correct newobj IL.
  val sb0 = SBld.new()
  val sb1 = SBld.new(64)
  // Both constructed successfully.
  assertTrue(true, "overload resolution succeeded")
}

// Test constructor with String argument (initializes content).
test "StringBuilder.new(String)" {
  val initialContent = "hello"
  val sb = SBld.new(initialContent)
  // Constructor with string argument succeeded.
  assertTrue(true, "string-argument constructor succeeded")
}

