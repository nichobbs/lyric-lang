// stdlib/tests/uuid_tests.l — Tests for Std.Uuid.
//
// Covers: newUuid generates non-nil UUIDs, nilUuid format, uuidToString
// produces the canonical hyphenated form, parseUuidOpt round-trips, and
// parseUuidOpt returns None for invalid input.
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

func testParseRoundTrip(): Unit {
  val u = newUuid()
  val s = uuidToString(u)
  val parsed = parseUuidOpt(s)
  assertTrue(isSome(parsed), "parse round-trip succeeds")
  val parsedStr = uuidToString(unwrapOr(parsed, nilUuid()))
  assertEqual(parsedStr, s, "parse round-trip string matches")
}

func testParseNil(): Unit {
  val nil_ = parseUuidOpt("00000000-0000-0000-0000-000000000000")
  assertTrue(isSome(nil_), "nil uuid parses ok")
  assertEqual(uuidToString(unwrapOr(nil_, newUuid())),
              "00000000-0000-0000-0000-000000000000",
              "parsed nil matches")
}

func testParseInvalid(): Unit {
  assertTrue(isNone(parseUuidOpt("")), "empty string returns None")
  assertTrue(isNone(parseUuidOpt("not-a-uuid")), "garbage returns None")
  assertTrue(isNone(parseUuidOpt("550e8400-e29b-41d4-a716")), "truncated returns None")
}

func main(): Unit {
  testNilUuid()
  testNewUuid()
  testTwoNewUuidsDistinct()
  testParseRoundTrip()
  testParseNil()
  testParseInvalid()
  println("uuid: ok")
}
