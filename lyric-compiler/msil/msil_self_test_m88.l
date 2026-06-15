//! Test constructor shorthand for extern types (.new syntax).
//! Tests docs/48 implementation: enable `.new(args)` calls on external types,
//! eliminating `@externTarget` wrapper functions and aligning MSIL with JVM.

@test_module
package Lyric.ConstructorShorthand

import Std.Core
import Std.Testing

extern type SBld = "System.Text.StringBuilder"

@externTarget("System.Text.StringBuilder.get_Length")
@externInstance
func sbLength(sb: in SBld): Int = ()

@externTarget("System.Text.StringBuilder.get_Capacity")
@externInstance
func sbCapacity(sb: in SBld): Int = ()

test "StringBuilder.new()" {
  val sb = SBld.new()
  assertEqualInt(sbLength(sb), 0, "newly constructed StringBuilder is empty")
}

test "StringBuilder.new(capacity)" {
  val capacity = 32
  val sb = SBld.new(capacity)
  assertTrue(sbCapacity(sb) >= capacity, "capacity constructor respects size")
}

test "constructor overload resolution" {
  val sb0 = SBld.new()
  val sb1 = SBld.new(64)

  assertEqualInt(sbLength(sb0), 0, "zero-arg constructor produces empty StringBuilder")
  assertTrue(sbCapacity(sb1) >= 64, "capacity constructor respects requested size")
}

test "StringBuilder.new(String)" {
  val initialContent = "hello"
  val sb = SBld.new(initialContent)
  assertEqualInt(sbLength(sb), 5, "string-argument constructor initializes length correctly")
}

