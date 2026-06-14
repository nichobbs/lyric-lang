//! const_pattern_self_test.l — regression tests for const patterns in match arms
//! (`@Ident` syntax, docs/46-const-patterns.md, Q-MP-001).
//!
//! Run on both targets:
//!   lyric test lyric-compiler/lyric/const_pattern_self_test.l
//!   lyric test lyric-compiler/lyric/const_pattern_self_test.l --target jvm
//!
//! Covers: Int, Long, String, Char, Bool, and Float const patterns; const
//! patterns inside or-patterns; and the matching fall-through to the wildcard arm.
//!
//! ERROR CASES (T0068, T0069, T0071, T0072): Type-checker validation errors are
//! compile-time diagnostics and cannot be tested in a runtime @test_module. Error
//! cases are validated by the type-checker test suite (typechecker_self_test.l) and
//! PR code review which verifies checkConstRefPattern recursion and diagnostic logic.
@test_module
package Lyric.ConstPatternSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Module-level val constants used as pattern references.
// ─────────────────────────────────────────────────────────────────────────────
val WIRE_VARINT = 0

val WIRE_FIXED64 = 1

val WIRE_LENGTH_DELIMITED = 2

val WIRE_FIXED32 = 5

val MAX_RETRIES = 3

val SENTINEL_LONG = 9999999999i64

val GREETING = "hello"

val FAREWELL = "goodbye"

val NEWLINE_CHAR = '\n'

val TAB_CHAR = '\t'

val FLAG_ENABLED = true

val FLAG_DISABLED = false

val THRESHOLD = 0.5

// ─────────────────────────────────────────────────────────────────────────────
// Int const patterns
// ─────────────────────────────────────────────────────────────────────────────
func describeWireType(n: in Int): String {
  match n {
    case @WIRE_VARINT -> "0"
    case @WIRE_FIXED64 -> "1"
    case @WIRE_LENGTH_DELIMITED -> "2"
    case @WIRE_FIXED32 -> "5"
    case _ -> "other"
  }
}

test "Int const pattern matches the constant value" {
  val wireType = 0
  val result = match wireType {
    case @WIRE_VARINT -> "varint"
    case @WIRE_FIXED64 -> "fixed64"
    case @WIRE_LENGTH_DELIMITED -> "length-delimited"
    case @WIRE_FIXED32 -> "fixed32"
    case _ -> "unknown"
  }
  assertEqual(result, "varint", "match 0 against @WIRE_VARINT")
}

test "Int const pattern selects correct arm" {
  val wireType = 5
  val result = match wireType {
    case @WIRE_VARINT -> "varint"
    case @WIRE_FIXED64 -> "fixed64"
    case @WIRE_LENGTH_DELIMITED -> "length-delimited"
    case @WIRE_FIXED32 -> "fixed32"
    case _ -> "unknown"
  }
  assertEqual(result, "fixed32", "match 5 against @WIRE_FIXED32")
}

test "Int const pattern falls through to wildcard when no match" {
  val wireType = 99
  val result = match wireType { case @WIRE_VARINT -> "varint"; case @WIRE_FIXED64 -> "fixed64"; case _ -> "unknown" }
  assertEqual(result, "unknown", "no const match -> wildcard")
}

test "Int const pattern respects all arms" {
  assertEqual(describeWireType(0), "0", "wire 0")
  assertEqual(describeWireType(1), "1", "wire 1")
  assertEqual(describeWireType(2), "2", "wire 2")
  assertEqual(describeWireType(5), "5", "wire 5")
  assertEqual(describeWireType(3), "other", "wire 3 -> other")
}

test "Int const pattern in expression returns value" {
  val retries = 3
  val description = match retries { case @MAX_RETRIES -> "at limit"; case _ -> "not at limit" }
  assertEqual(description, "at limit", "@MAX_RETRIES = 3")
}

// ─────────────────────────────────────────────────────────────────────────────
// Long const patterns
// ─────────────────────────────────────────────────────────────────────────────
test "Long const pattern matches sentinel value" {
  val n = 9999999999i64
  val result = match n { case @SENTINEL_LONG -> "sentinel"; case _ -> "other" }
  assertEqual(result, "sentinel", "long const match")
}

test "Long const pattern misses non-sentinel value" {
  val n = 42i64
  val result = match n { case @SENTINEL_LONG -> "sentinel"; case _ -> "other" }
  assertEqual(result, "other", "long const no-match")
}

// ─────────────────────────────────────────────────────────────────────────────
// String const patterns
// ─────────────────────────────────────────────────────────────────────────────
test "String const pattern matches greeting" {
  val msg = "hello"
  val result = match msg { case @GREETING -> "hi back"; case @FAREWELL -> "bye"; case _ -> "unknown" }
  assertEqual(result, "hi back", "@GREETING match")
}

test "String const pattern matches farewell" {
  val msg = "goodbye"
  val result = match msg { case @GREETING -> "hi back"; case @FAREWELL -> "bye"; case _ -> "unknown" }
  assertEqual(result, "bye", "@FAREWELL match")
}

test "String const pattern falls through on no match" {
  val msg = "hey"
  val result = match msg { case @GREETING -> "hi back"; case @FAREWELL -> "bye"; case _ -> "unknown" }
  assertEqual(result, "unknown", "string wildcard")
}

// ─────────────────────────────────────────────────────────────────────────────
// Char const patterns
// ─────────────────────────────────────────────────────────────────────────────
test "Char const pattern matches newline" {
  val c = '\n'
  val result = match c { case @NEWLINE_CHAR -> "newline"; case @TAB_CHAR -> "tab"; case _ -> "other" }
  assertEqual(result, "newline", "@NEWLINE_CHAR match")
}

test "Char const pattern matches tab" {
  val c = '\t'
  val result = match c { case @NEWLINE_CHAR -> "newline"; case @TAB_CHAR -> "tab"; case _ -> "other" }
  assertEqual(result, "tab", "@TAB_CHAR match")
}

// ─────────────────────────────────────────────────────────────────────────────
// Bool const patterns
// ─────────────────────────────────────────────────────────────────────────────
test "Bool const pattern matches true flag" {
  val flag = true
  val result = match flag { case @FLAG_ENABLED -> "on"; case @FLAG_DISABLED -> "off"; case _ -> "unknown" }
  assertEqual(result, "on", "@FLAG_ENABLED match")
}

test "Bool const pattern matches false flag" {
  val flag = false
  val result = match flag { case @FLAG_ENABLED -> "on"; case @FLAG_DISABLED -> "off"; case _ -> "unknown" }
  assertEqual(result, "off", "@FLAG_DISABLED match")
}

// ─────────────────────────────────────────────────────────────────────────────
// Float const patterns
// ─────────────────────────────────────────────────────────────────────────────
test "Float const pattern matches threshold value" {
  val x = 0.5
  val result = match x { case @THRESHOLD -> "at threshold"; case _ -> "other" }
  assertEqual(result, "at threshold", "@THRESHOLD match")
}

test "Float const pattern misses different value" {
  val x = 0.75
  val result = match x { case @THRESHOLD -> "at threshold"; case _ -> "other" }
  assertEqual(result, "other", "float const no-match")
}

// ─────────────────────────────────────────────────────────────────────────────
// Const pattern inside or-pattern
// ─────────────────────────────────────────────────────────────────────────────
func isVarintOrFixed64(n: in Int): Bool {
  match n {
    case @WIRE_VARINT | @WIRE_FIXED64 -> true
    case _ -> false
  }
}

test "Const pattern in or-pattern arm" {
  assertTrue(isVarintOrFixed64(0), "or-pattern arm hit for 0")
  assertTrue(isVarintOrFixed64(1), "or-pattern arm hit for 1")
  assertFalse(isVarintOrFixed64(2), "or-pattern arm miss for 2")
}

// ─────────────────────────────────────────────────────────────────────────────
// Const pattern mixed with literals and wildcards
// ─────────────────────────────────────────────────────────────────────────────
func labelWireOrLiteral(n: in Int): String {
  match n {
    case 0 -> "literal zero"
    case @WIRE_FIXED64 -> "const fixed64 (1)"
    case 2 -> "literal two"
    case _ -> "rest"
  }
}

test "Const pattern coexists with literal patterns" {
  assertEqual(labelWireOrLiteral(0), "literal zero", "literal 0 wins over @WIRE_VARINT (both = 0)")
  assertEqual(labelWireOrLiteral(1), "const fixed64 (1)", "@WIRE_FIXED64 = 1")
  assertEqual(labelWireOrLiteral(2), "literal two", "literal 2")
  assertEqual(labelWireOrLiteral(7), "rest", "wildcard")
}
