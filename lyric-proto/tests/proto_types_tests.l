//! tests/proto_types_tests.l — test suite for the Proto package.
//! Covers: zigzag32/64 + unzigzag32/64 round-trips (exercising the native
//! bitwise helpers), and end-to-end encodeMessage/decodeMessage round-trips
//! plus a known-byte varint vector (exercising the byte-write/read helpers).
@test_module
package Proto.ProtoTypesTests

import Std.Core
import Std.Testing
import Proto

// ─── zigzag32 ─────────────────────────────────────────────────────────────────
test "zigzag32 maps signed ints to the proto sint32 zig-zag sequence" {
  assertTrue(zigzag32(0) == 0i64, "zigzag32(0) = 0")
  assertTrue(zigzag32(-1) == 1i64, "zigzag32(-1) = 1")
  assertTrue(zigzag32(1) == 2i64, "zigzag32(1) = 2")
  assertTrue(zigzag32(-2) == 3i64, "zigzag32(-2) = 3")
  assertTrue(zigzag32(2) == 4i64, "zigzag32(2) = 4")
  assertTrue(zigzag32(100) == 200i64, "zigzag32(100) = 200")
  assertTrue(zigzag32(-100) == 199i64, "zigzag32(-100) = 199")
}

test "zigzag64 maps signed longs to the proto sint64 zig-zag sequence" {
  assertTrue(zigzag64(0i64) == 0i64, "zigzag64(0) = 0")
  assertTrue(zigzag64(-1i64) == 1i64, "zigzag64(-1) = 1")
  assertTrue(zigzag64(1i64) == 2i64, "zigzag64(1) = 2")
  assertTrue(zigzag64(-100i64) == 199i64, "zigzag64(-100) = 199")
}

// ─── zig-zag round-trips ────────────────────────────────────────────────────
test "unzigzag32 inverts zigzag32" {
  assertEqualInt(unzigzag32(zigzag32(0)), 0, "0")
  assertEqualInt(unzigzag32(zigzag32(-1)), -1, "-1")
  assertEqualInt(unzigzag32(zigzag32(1)), 1, "1")
  assertEqualInt(unzigzag32(zigzag32(-12345)), -12345, "-12345")
  assertEqualInt(unzigzag32(zigzag32(2147483647)), 2147483647, "Int max")
  // INT_MIN exercises the unsigned-overflow wrap in the zigzag formula.
  assertEqualInt(unzigzag32(zigzag32(-2147483648)), -2147483648, "Int min")
}

test "unzigzag64 inverts zigzag64" {
  assertTrue(unzigzag64(zigzag64(0i64)) == 0i64, "0")
  assertTrue(unzigzag64(zigzag64(-1i64)) == -1i64, "-1")
  assertTrue(unzigzag64(zigzag64(9000000000i64)) == 9000000000i64, "large positive")
  assertTrue(unzigzag64(zigzag64(-9000000000i64)) == -9000000000i64, "large negative")
}

// ─── known-byte varint vector ────────────────────────────────────────────────
// Field 1 (tag = (1<<3)|0 = 0x08), varint value 300 = 0xAC 0x02 (canonical
// protobuf encoding).  Validates the byte-write + varint paths produce the
// exact wire bytes the spec mandates.
test "encodeMessage emits the canonical varint wire bytes" {
  val bytes = encodeMessage([VarField(number = 1, v = 300i64)])
  assertEqualInt(bytes.length, 3, "three bytes: tag + 2-byte varint")
  assertEqualInt(byteAt(bytes, 0), 8, "tag byte = (1<<3)|0")
  assertEqualInt(byteAt(bytes, 1), 172, "low varint byte 0xAC")
  assertEqualInt(byteAt(bytes, 2), 2, "high varint byte 0x02")
}

// ─── encode/decode round-trips ────────────────────────────────────────────────
test "VarField round-trips through encode/decode" {
  val bytes = encodeMessage([VarField(number = 1, v = 300i64)])
  match decodeMessage(bytes) {
    case Err(e) -> assertTrue(false, "decode failed: " + e)
    case Ok(fields) -> match findVarint(fields, 1) { case Some(v) -> assertTrue(v == 300i64, "field 1 round-trips to 300"); case None -> assertTrue(false, "field 1 not found after decode") }
  }
}

test "multiple varint fields round-trip independently" {
  val bytes = encodeMessage([VarField(number = 1, v = 7i64), VarField(number = 2, v = 1000000i64)])
  match decodeMessage(bytes) {
    case Err(e) -> assertTrue(false, "decode failed: " + e)
    case Ok(fields) -> {
      match findVarint(fields, 1) {
        case Some(v) -> assertTrue(v == 7i64, "field 1 = 7")
        case None -> assertTrue(false, "field 1 missing")
      }
      match findVarint(fields, 2) {
        case Some(v) -> assertTrue(v == 1000000i64, "field 2 = 1000000")
        case None -> assertTrue(false, "field 2 missing")
      }
    }
  }
}

// proto3 encodes a negative int64 as the full 10-byte varint of its two's-
// complement bit pattern.  -1 → tag (0x08) + FF×9 + 01 = 11 bytes.  This pins
// the negative-varint path end to end (encode emits 11 bytes; decode recovers
// the exact value) — the signed-comparison + arithmetic-shift bug produced one
// wrong byte and lost the value (#3372).
test "negative VarField round-trips as a 10-byte varint" {
  val bytes = encodeMessage([VarField(number = 1, v = -1i64)])
  assertEqualInt(bytes.length, 11, "tag + 10-byte negative varint")
  assertEqualInt(byteAt(bytes, 1), 255, "first varint byte is 0xFF")
  assertEqualInt(byteAt(bytes, 10), 1, "final varint byte is 0x01")
  match decodeMessage(bytes) {
    case Err(e) -> assertTrue(false, "decode failed: " + e)
    case Ok(fields) -> match findVarint(fields, 1) { case Some(v) -> assertTrue(v == -1i64, "negative field round-trips to -1"); case None -> assertTrue(false, "field 1 not found after decode") }
  }
}

test "large negative int64 round-trips through encode/decode" {
  val bytes = encodeMessage([VarField(number = 2, v = -9000000000i64)])
  match decodeMessage(bytes) {
    case Err(e) -> assertTrue(false, "decode failed: " + e)
    case Ok(fields) -> match findVarint(fields, 2) { case Some(v) -> assertTrue(v == -9000000000i64, "large negative round-trips"); case None -> assertTrue(false, "field 2 not found after decode") }
  }
}

test "BytesField round-trips through encode/decode" {
  val payload: slice[Byte] = [1u8, 2u8, 3u8, 254u8, 255u8]
  val bytes = encodeMessage([BytesField(number = 4, data = payload)])
  match decodeMessage(bytes) {
    case Err(e) -> assertTrue(false, "decode failed: " + e)
    case Ok(fields) -> match findBytes(fields, 4) { case Some(got) -> { assertEqualInt(got.length, 5, "length-delimited payload length"); assertEqualInt(byteAt(got, 0), 1, "byte 0"); assertEqualInt(byteAt(got, 3), 254, "byte 3"); assertEqualInt(byteAt(got, 4), 255, "byte 4") }; case None -> assertTrue(false, "field 4 not found after decode") }
  }
}

// Fixed64 (wire type 1): tag = (3<<3)|1 = 0x19, then the value as 8 little-endian
// bytes.  Asserts the exact wire bytes — exercising the int64 little-endian write
// path.  (The decode side is covered by the VarField/BytesField round-trips; a
// `for f in fields` loop over the decoded `List[DecodedField]` here is avoided
// because iterating a cross-package generic list returned from a `Result` erases
// to `List<Object>` and the loop's element cast faults — a separate generics gap.)
test "Fix64Field emits tag + 8 little-endian bytes" {
  val bytes = encodeMessage([Fix64Field(number = 3, bits = 0x0102030405060708i64)])
  assertEqualInt(bytes.length, 9, "tag + 8 fixed bytes")
  assertEqualInt(byteAt(bytes, 0), 25, "tag = (3<<3)|1")
  assertEqualInt(byteAt(bytes, 1), 8, "little-endian byte 0 = 0x08")
  assertEqualInt(byteAt(bytes, 2), 7, "little-endian byte 1 = 0x07")
  assertEqualInt(byteAt(bytes, 8), 1, "little-endian byte 7 = 0x01")
}

// Fixed32 (wire type 5): tag = (field<<3)|5.  For field 2: tag = (2<<3)|5 = 0x15 = 21.
test "Fix32Field emits tag + 4 little-endian bytes" {
  val bytes = encodeMessage([Fix32Field(number = 2, bits = 0x01020304)])
  assertEqualInt(bytes.length, 5, "tag + 4 fixed bytes")
  assertEqualInt(byteAt(bytes, 0), 21, "tag = (2<<3)|5")
  assertEqualInt(byteAt(bytes, 1), 4, "little-endian byte 0 = 0x04")
  assertEqualInt(byteAt(bytes, 2), 3, "little-endian byte 1 = 0x03")
  assertEqualInt(byteAt(bytes, 3), 2, "little-endian byte 2 = 0x02")
  assertEqualInt(byteAt(bytes, 4), 1, "little-endian byte 3 = 0x01")
}

// Round-trip via the in-package `findFixed32` extractor (#3383).  Extraction
// must happen inside the Proto package: iterating the decoded
// `List[DecodedField]` directly from a consumer package erases the element
// type to `Object` and traps on the cast (the cross-package generic-list gap,
// #2932/#3267), which is why `findFixed32`/`findFixed64` are pub helpers.
test "Fix32Field round-trips through encode/decode" {
  val bytes = encodeMessage([Fix32Field(number = 2, bits = 0x01020304)])
  match decodeMessage(bytes) {
    case Err(e) -> assertTrue(false, "decode failed: " + e)
    case Ok(fields) -> match findFixed32(fields, 2) { case Some(b) -> assertEqualInt(b, 0x01020304, "fixed32 field 2 round-trips"); case None -> assertTrue(false, "fixed32 field 2 not found after decode") }
  }
}

test "Fix64Field round-trips through encode/decode" {
  val bytes = encodeMessage([Fix64Field(number = 3, bits = 0x0102030405060708i64)])
  match decodeMessage(bytes) {
    case Err(e) -> assertTrue(false, "decode failed: " + e)
    case Ok(fields) -> match findFixed64(fields, 3) { case Some(b) -> assertTrue(b == 0x0102030405060708i64, "fixed64 field 3 round-trips"); case None -> assertTrue(false, "fixed64 field 3 not found after decode") }
  }
}

// Convenience-constructor coverage (#3383): doubleField builds a Fix64 field,
// so it round-trips through findFixed64.  (floatField's round-trip is blocked
// by a separate Float->BitConverter.SingleToInt32Bits(Double) extern
// miscompile, tracked separately, so it is not asserted here.)
test "doubleField round-trips through Fix64 and decodes to the original bits" {
  val bits = doubleToInt64Bits(2.5)
  val bytes = encodeMessage([doubleField(5, 2.5)])
  match decodeMessage(bytes) {
    case Err(e) -> assertTrue(false, "decode failed: " + e)
    case Ok(fields) -> match findFixed64(fields, 5) { case Some(b) -> assertTrue(b == bits, "doubleField round-trips to its IEEE-754 bits"); case None -> assertTrue(false, "doubleField field 5 not found after decode") }
  }
}

// ─── Convenience constructor encoding ────────────────────────────────────────
// boolField is a VarField with value 1 (true) or 0 (false).
// Field 1 true → tag 0x08 + varint 0x01 = 2 bytes.
test "boolField encodes true as varint 1" {
  val bytes = encodeMessage([boolField(1, true)])
  assertEqualInt(bytes.length, 2, "tag + 1-byte varint")
  assertEqualInt(byteAt(bytes, 0), 8, "tag = (1<<3)|0")
  assertEqualInt(byteAt(bytes, 1), 1, "varint = 1")
}

test "boolField encodes false as varint 0" {
  val bytes = encodeMessage([boolField(1, false)])
  assertEqualInt(bytes.length, 2, "tag + 1-byte varint")
  assertEqualInt(byteAt(bytes, 0), 8, "tag = (1<<3)|0")
  assertEqualInt(byteAt(bytes, 1), 0, "varint = 0")
}

// sint32Field zig-zag encodes -1 → 1, which produces a 1-byte varint.
// Field 1 → tag 0x08 + varint 0x01.
test "sint32Field zig-zag encodes negative values" {
  val bytes = encodeMessage([sint32Field(1, -1)])
  assertEqualInt(bytes.length, 2, "tag + 1-byte zigzag")
  assertEqualInt(byteAt(bytes, 0), 8, "tag = (1<<3)|0")
  assertEqualInt(byteAt(bytes, 1), 1, "zigzag32(-1) = 1")
}

// ─── Error path: decodeStep on truncated input ───────────────────────────────
// An empty slice (offset == length) returns Err immediately.
test "decodeStep on empty input returns Err" {
  val empty: slice[Byte] = []
  match decodeStep(empty, 0) {
    case Ok(_) -> assertTrue(false, "expected Err on empty input")
    case Err(_) -> assertTrue(true, "Err on empty input")
  }
}

// A valid tag byte (field 1 varint, 0x08) with no following value bytes
// returns Err for the truncated varint body.
test "decodeStep on truncated varint field returns Err" {
  val truncated: slice[Byte] = [8u8]
  match decodeStep(truncated, 0) {
    case Ok(_) -> assertTrue(false, "expected Err on truncated varint")
    case Err(_) -> assertTrue(true, "Err on truncated varint")
  }
}

// Repeated fixed-width fields collected via the in-package collectFixed32
// helper (#3618): two fixed32 fields share field number 7; collectFixed32
// returns both in encounter order.
test "collectFixed32 gathers repeated fixed32 fields" {
  val bytes = encodeMessage([Fix32Field(number = 7, bits = 0x0A0B0C0D), Fix32Field(number = 7, bits = 0x11223344)])
  match decodeMessage(bytes) {
    case Err(e) -> assertTrue(false, "decode failed: " + e)
    case Ok(fields) -> {
      val got = collectFixed32(fields, 7)
      assertEqualInt(got.length, 2, "two fixed32 fields collected")
      assertEqualInt(got[0], 0x0A0B0C0D, "first repeated fixed32")
      assertEqualInt(got[1], 0x11223344, "second repeated fixed32")
    }
  }
}

test "collectFixed64 gathers repeated fixed64 fields" {
  val bytes = encodeMessage(
    [
      Fix64Field(number = 8, bits = 0x0102030405060708i64),
      Fix64Field(number = 8, bits = 0x1122334455667788i64)
    ]
  )
  match decodeMessage(bytes) {
    case Err(e) -> assertTrue(false, "decode failed: " + e)
    case Ok(fields) -> {
      val got = collectFixed64(fields, 8)
      assertEqualInt(got.length, 2, "two fixed64 fields collected")
      assertTrue(got[0] == 0x0102030405060708i64, "first repeated fixed64")
      assertTrue(got[1] == 0x1122334455667788i64, "second repeated fixed64")
    }
  }
}
