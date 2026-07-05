//! stdlib/tests/uuid_tests.l — Tests for Std.Uuid.
//!
//! Covers: newUuid generates non-nil UUIDs, nilUuid format, uuidToString
//! produces the canonical hyphenated form, parseUuidOpt round-trips
//! (all four cross-target formats, D-N-026), and parseUuidOpt returns
//! None for invalid input.
//!
//! Option[Uuid] results are unwrapped with inline `match` rather than
//! the generic Std.Core helpers (`unwrapOr` / `isSome` / `isNone`):
//! those miscompile on the MSIL uniform-ABI generic path when the type
//! argument is an extern value type like System.Guid (#5196 — missing
//! box/unbox, and a wrong-value return when the Bool flows into an
//! argument position).  Swap back when #5196 is fixed.
package Std.Uuid.Tests

import Std.Core
import Std.Uuid
import Std.Testing

func testNilUuid(): Unit {
  val nil_ = nilUuid()
  val s = uuidToString(nil_)
  assertEqual(s, "00000000-0000-0000-0000-000000000000", "nil uuid string")
}

func testNewUuid(): Unit {
  val u = newUuid()
  val s = uuidToString(u)
  // Canonical hyphenated form: 8-4-4-4-12 hex chars = 36 chars total.
  assertEqualInt(s.length, 36, "uuid string length")
  // Must differ from nil.
  assertTrue(s != "00000000-0000-0000-0000-000000000000", "new uuid is non-nil")
}

func testTwoNewUuidsDistinct(): Unit {
  val a = uuidToString(newUuid())
  val b = uuidToString(newUuid())
  // Collision probability is astronomically small; treat equal as a test failure.
  assertTrue(a != b, "two new uuids are distinct")
}

// Assert that `parseUuidOpt(input)` yields a value formatting back to
// `expect` (inline match, not unwrapOr — see the header and #5196).
func assertParsesTo(input: in String, expect: in String, label: in String): Unit {
  match parseUuidOpt(input) {
    case Some(u) -> assertEqual(uuidToString(u), expect, label)
    case None -> assertTrue(false, label + " (parse unexpectedly failed)")
  }
}

// Assert that `parseUuidOpt(input)` rejects the input.
func assertRejects(input: in String, label: in String): Unit {
  match parseUuidOpt(input) {
    case Some(_) -> assertTrue(false, label + " (parse unexpectedly succeeded)")
    case None -> assertTrue(true, label)
  }
}

func testParseRoundTrip(): Unit {
  val s = uuidToString(newUuid())
  assertParsesTo(s, s, "parse round-trip string matches")
}

func testParseNil(): Unit {
  assertParsesTo("00000000-0000-0000-0000-000000000000", "00000000-0000-0000-0000-000000000000", "parsed nil matches")
}

func testParseInvalid(): Unit {
  assertRejects("", "empty string returns None")
  assertRejects("not-a-uuid", "garbage returns None")
  assertRejects("550e8400-e29b-41d4-a716", "truncated returns None")
}

// The four cross-target formats (D-N-026): D/N/B/P, either hex case,
// leading/trailing whitespace tolerated — canonicalized in shared code
// so every target parses (and re-formats) them identically.
func testParseAlternateForms(): Unit {
  val d = "550e8400-e29b-41d4-a716-446655440000"
  assertParsesTo("550E8400-E29B-41D4-A716-446655440000", d, "uppercase D form lowercases")
  assertParsesTo("550e8400e29b41d4a716446655440000", d, "N form parses")
  assertParsesTo("{550e8400-e29b-41d4-a716-446655440000}", d, "B form parses")
  assertParsesTo("(550e8400-e29b-41d4-a716-446655440000)", d, "P form parses")
  assertParsesTo("  " + d + "\n", d, "surrounding whitespace trimmed")
}

// The .NET-only exotic "X" form is intentionally not part of the
// cross-target surface (D-N-026), and structural mistakes the shared
// canonicalizer must catch stay caught.
func testParseRejectsExoticForms(): Unit {
  assertRejects(
    "{0x550e8400,0xe29b,0x41d4,{0xa7,0x16,0x44,0x66,0x55,0x44,0x00,0x00}}",
    "X form rejected on every target"
  )
  assertRejects("{550e8400-e29b-41d4-a716-446655440000)", "mismatched wrappers rejected")
  assertRejects("550e8400-e29b-41d4-a716-44665544000g", "non-hex digit rejected")
  assertRejects("550e8400-e29b-41d4-a71644-6655440000", "misplaced hyphens rejected")
}

func main(): Unit {
  testNilUuid()
  testNewUuid()
  testTwoNewUuidsDistinct()
  testParseRoundTrip()
  testParseNil()
  testParseInvalid()
  testParseAlternateForms()
  testParseRejectsExoticForms()
  println("uuid: ok")
}
