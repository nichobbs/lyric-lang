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
  // Verify the object was constructed and has expected initial state.
  assertEqual(sb.Length, 0, "newly constructed StringBuilder should be empty")
}

// Test constructor with single argument (capacity).
test "StringBuilder.new(capacity)" {
  val capacity = 32
  val sb = SBld.new(capacity)
  // Verify the constructor was called with the argument.
  assertTrue(sb.Capacity >= capacity, "StringBuilder capacity should match or exceed requested size")
}

// Test constructor overload resolution.
test "constructor overload resolution" {
  // Both overloads should resolve via metadata and emit correct newobj IL.
  val sb0 = SBld.new()
  val sb1 = SBld.new(64)

  assertEqual(sb0.Length, 0, "zero-arg constructor produces empty StringBuilder")
  assertTrue(sb1.Capacity >= 64, "capacity constructor respects requested size")
}

// Test constructor with String argument (initializes content).
test "StringBuilder.new(String)" {
  val initialContent = "hello"
  val sb = SBld.new(initialContent)
  // Verify the string argument was passed and applied.
  assertEqual(sb.Length, 5, "StringBuilder initialized with string should have correct length")
}

