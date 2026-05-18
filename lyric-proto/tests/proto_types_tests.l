// tests/proto_types_tests.l — test suite for the Proto.Types package.
// Covers: wireTypeId for all four WireType variants, zigzag32/64 encoding,
// unzigzag32/64 decoding, and roundtrip identity for several values.

@test_module
package Proto.ProtoTypesTests

import Std.Core
import Std.Testing
import Proto.Types

// ─── wireTypeId ───────────────────────────────────────────────────────────────

test "wireTypeId(Varint) returns 0" {
  assertEqualInt(wireTypeId(WireType.Varint), 0, "Varint wire type id")
}

test "wireTypeId(Fixed64) returns 1" {
  assertEqualInt(wireTypeId(WireType.Fixed64), 1, "Fixed64 wire type id")
}

test "wireTypeId(LengthDelimited) returns 2" {
  assertEqualInt(wireTypeId(WireType.LengthDelimited), 2, "LengthDelimited wire type id")
}

test "wireTypeId(Fixed32) returns 5" {
  assertEqualInt(wireTypeId(WireType.Fixed32), 5, "Fixed32 wire type id")
}

// ─── zigzag32 ─────────────────────────────────────────────────────────────────

test "zigzag32(0) returns 0L" {
  assertTrue(zigzag32(0) == 0L, "zigzag32(0) = 0L")
}

test "zigzag32(1) returns 2L" {
  assertTrue(zigzag32(1) == 2L, "zigzag32(1) = 2L")
}

test "zigzag32(-1) returns 1L" {
  assertTrue(zigzag32(-1) == 1L, "zigzag32(-1) = 1L")
}

test "zigzag32(2) returns 4L" {
  assertTrue(zigzag32(2) == 4L, "zigzag32(2) = 4L")
}

test "zigzag32(-2) returns 3L" {
  assertTrue(zigzag32(-2) == 3L, "zigzag32(-2) = 3L")
}

test "zigzag32(100) returns 200L" {
  assertTrue(zigzag32(100) == 200L, "zigzag32(100) = 200L")
}

test "zigzag32(-100) returns 199L" {
  assertTrue(zigzag32(-100) == 199L, "zigzag32(-100) = 199L")
}

// ─── zigzag64 ─────────────────────────────────────────────────────────────────

test "zigzag64(0L) returns 0L" {
  assertTrue(zigzag64(0L) == 0L, "zigzag64(0L) = 0L")
}

test "zigzag64(1L) returns 2L" {
  assertTrue(zigzag64(1L) == 2L, "zigzag64(1L) = 2L")
}

test "zigzag64(-1L) returns 1L" {
  assertTrue(zigzag64(-1L) == 1L, "zigzag64(-1L) = 1L")
}

// ─── unzigzag32 ───────────────────────────────────────────────────────────────

test "unzigzag32(0L) returns 0" {
  assertEqualInt(unzigzag32(0L), 0, "unzigzag32(0L) = 0")
}

test "unzigzag32(1L) returns -1" {
  assertEqualInt(unzigzag32(1L), -1, "unzigzag32(1L) = -1")
}

test "unzigzag32(2L) returns 1" {
  assertEqualInt(unzigzag32(2L), 1, "unzigzag32(2L) = 1")
}

test "unzigzag32(3L) returns -2" {
  assertEqualInt(unzigzag32(3L), -2, "unzigzag32(3L) = -2")
}

test "unzigzag32(4L) returns 2" {
  assertEqualInt(unzigzag32(4L), 2, "unzigzag32(4L) = 2")
}

// ─── unzigzag64 ───────────────────────────────────────────────────────────────

test "unzigzag64(0L) returns 0L" {
  assertTrue(unzigzag64(0L) == 0L, "unzigzag64(0L) = 0L")
}

test "unzigzag64(1L) returns -1L" {
  assertTrue(unzigzag64(1L) == -1L, "unzigzag64(1L) = -1L")
}

test "unzigzag64(2L) returns 1L" {
  assertTrue(unzigzag64(2L) == 1L, "unzigzag64(2L) = 1L")
}

// ─── Roundtrip: zigzag32 / unzigzag32 ────────────────────────────────────────

test "roundtrip: unzigzag32(zigzag32(42)) == 42" {
  assertEqualInt(unzigzag32(zigzag32(42)), 42, "roundtrip positive 42")
}

test "roundtrip: unzigzag32(zigzag32(-42)) == -42" {
  assertEqualInt(unzigzag32(zigzag32(-42)), -42, "roundtrip negative -42")
}

test "roundtrip: unzigzag32(zigzag32(0)) == 0" {
  assertEqualInt(unzigzag32(zigzag32(0)), 0, "roundtrip zero")
}

test "roundtrip: unzigzag32(zigzag32(1)) == 1" {
  assertEqualInt(unzigzag32(zigzag32(1)), 1, "roundtrip one")
}

test "roundtrip: unzigzag32(zigzag32(-1)) == -1" {
  assertEqualInt(unzigzag32(zigzag32(-1)), -1, "roundtrip negative one")
}

// ─── Roundtrip: zigzag64 / unzigzag64 ────────────────────────────────────────

test "roundtrip: unzigzag64(zigzag64(42L)) == 42L" {
  assertTrue(unzigzag64(zigzag64(42L)) == 42L, "roundtrip positive 42L")
}

test "roundtrip: unzigzag64(zigzag64(-42L)) == -42L" {
  assertTrue(unzigzag64(zigzag64(-42L)) == -42L, "roundtrip negative -42L")
}

test "roundtrip: unzigzag64(zigzag64(0L)) == 0L" {
  assertTrue(unzigzag64(zigzag64(0L)) == 0L, "roundtrip zero long")
}

test "roundtrip: unzigzag64(zigzag64(-1L)) == -1L" {
  assertTrue(unzigzag64(zigzag64(-1L)) == -1L, "roundtrip negative one long")
}
