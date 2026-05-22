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

test "zigzag32(0) returns 0" {
  assertTrue(zigzag32(0) == 0i64, "zigzag32(0) = 0")
}

test "zigzag32(1) returns 2" {
  assertTrue(zigzag32(1) == 2i64, "zigzag32(1) = 2")
}

test "zigzag32(-1) returns 1" {
  assertTrue(zigzag32(-1) == 1i64, "zigzag32(-1) = 1")
}

test "zigzag32(2) returns 4" {
  assertTrue(zigzag32(2) == 4i64, "zigzag32(2) = 4")
}

test "zigzag32(-2) returns 3" {
  assertTrue(zigzag32(-2) == 3i64, "zigzag32(-2) = 3")
}

test "zigzag32(100) returns 200" {
  assertTrue(zigzag32(100) == 200i64, "zigzag32(100) = 200")
}

test "zigzag32(-100) returns 199" {
  assertTrue(zigzag32(-100) == 199i64, "zigzag32(-100) = 199")
}

// ─── zigzag64 ─────────────────────────────────────────────────────────────────

test "zigzag64(0) returns 0" {
  assertTrue(zigzag64(0i64) == 0i64, "zigzag64(0) = 0")
}

test "zigzag64(1) returns 2" {
  assertTrue(zigzag64(1i64) == 2i64, "zigzag64(1) = 2")
}

test "zigzag64(-1) returns 1" {
  assertTrue(zigzag64(-1i64) == 1i64, "zigzag64(-1) = 1")
}

// ─── unzigzag32 ───────────────────────────────────────────────────────────────

test "unzigzag32(0) returns 0" {
  assertEqualInt(unzigzag32(0i64), 0, "unzigzag32(0) = 0")
}

test "unzigzag32(1) returns -1" {
  assertEqualInt(unzigzag32(1i64), -1, "unzigzag32(1) = -1")
}

test "unzigzag32(2) returns 1" {
  assertEqualInt(unzigzag32(2i64), 1, "unzigzag32(2) = 1")
}

test "unzigzag32(3) returns -2" {
  assertEqualInt(unzigzag32(3i64), -2, "unzigzag32(3) = -2")
}

test "unzigzag32(4) returns 2" {
  assertEqualInt(unzigzag32(4i64), 2, "unzigzag32(4) = 2")
}

// ─── unzigzag64 ───────────────────────────────────────────────────────────────

test "unzigzag64(0) returns 0" {
  assertTrue(unzigzag64(0i64) == 0i64, "unzigzag64(0) = 0")
}

test "unzigzag64(1) returns -1" {
  assertTrue(unzigzag64(1i64) == -1i64, "unzigzag64(1) = -1")
}

test "unzigzag64(2) returns 1" {
  assertTrue(unzigzag64(2i64) == 1i64, "unzigzag64(2) = 1")
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

test "roundtrip: unzigzag64(zigzag64(42)) == 42" {
  assertTrue(unzigzag64(zigzag64(42i64)) == 42i64, "roundtrip positive 42")
}

test "roundtrip: unzigzag64(zigzag64(-42)) == -42" {
  assertTrue(unzigzag64(zigzag64(-42i64)) == -42i64, "roundtrip negative -42")
}

test "roundtrip: unzigzag64(zigzag64(0)) == 0" {
  assertTrue(unzigzag64(zigzag64(0i64)) == 0i64, "roundtrip zero long")
}

test "roundtrip: unzigzag64(zigzag64(-1)) == -1" {
  assertTrue(unzigzag64(zigzag64(-1i64)) == -1i64, "roundtrip negative one long")
}

// ─── RFC zigzag vectors (#361) ───────────────────────────────────────────────
//
// Protobuf zigzag encoding is specified at
//   https://protobuf.dev/programming-guides/encoding/#signed-ints
// The encoding maps each signed integer to an unsigned representation
// so that small-magnitude negatives encode in few varint bytes.  The
// vectors below cover the boundary cases — the encoding/decoding
// algorithm is correct iff every roundtrip below holds.

// 32-bit boundary: int.MinValue = -2147483648; int.MaxValue = 2147483647.
// zigzag32(int.MinValue) = 2 * (-int.MinValue) - 1 = 4294967295 = uint.MaxValue.
test "zigzag32(int.MaxValue) returns 0xFFFFFFFE" {
  assertTrue(zigzag32(2147483647) == 4294967294i64,
             "zigzag32(INT_MAX) = 2 * INT_MAX = 0xFFFFFFFE")
}

test "zigzag32(int.MinValue) returns 0xFFFFFFFF" {
  assertTrue(zigzag32(-2147483648) == 4294967295i64,
             "zigzag32(INT_MIN) = -2 * INT_MIN - 1 = 0xFFFFFFFF")
}

test "unzigzag32(0xFFFFFFFE) returns int.MaxValue" {
  assertEqualInt(unzigzag32(4294967294i64), 2147483647,
                 "unzigzag32(2 * INT_MAX) = INT_MAX")
}

test "unzigzag32(0xFFFFFFFF) returns int.MinValue" {
  assertEqualInt(unzigzag32(4294967295i64), -2147483648,
                 "unzigzag32(-2 * INT_MIN - 1) = INT_MIN")
}

test "zigzag32 roundtrip: INT_MAX" {
  assertEqualInt(unzigzag32(zigzag32(2147483647)), 2147483647,
                 "roundtrip INT_MAX")
}

test "zigzag32 roundtrip: INT_MIN" {
  assertEqualInt(unzigzag32(zigzag32(-2147483648)), -2147483648,
                 "roundtrip INT_MIN")
}

// 64-bit boundary: long.MaxValue = 9223372036854775807,
// long.MinValue = -9223372036854775808.  zigzag64 maps these to
// values that overflow to negative when interpreted as Long, which
// is precisely the wire encoding of ulong.MaxValue and ulong.MaxValue - 1.
test "zigzag64 roundtrip: LONG_MAX" {
  val v = 9223372036854775807i64
  assertTrue(unzigzag64(zigzag64(v)) == v, "roundtrip LONG_MAX")
}

test "zigzag64 roundtrip: LONG_MIN" {
  val v = -9223372036854775807i64 - 1i64   // LONG_MIN — split to dodge parser limits
  assertTrue(unzigzag64(zigzag64(v)) == v, "roundtrip LONG_MIN")
}

test "zigzag64 roundtrip: -1" {
  assertTrue(unzigzag64(zigzag64(-1i64)) == -1i64, "roundtrip -1")
}

test "zigzag64 roundtrip: 1" {
  assertTrue(unzigzag64(zigzag64(1i64)) == 1i64, "roundtrip 1")
}
