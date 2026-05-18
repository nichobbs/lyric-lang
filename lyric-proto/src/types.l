// Platform-neutral Protocol Buffer types (proto3 subset).
//
// Wire types follow the protobuf binary encoding specification.  Types 3 and 4
// (StartGroup / EndGroup) are deprecated in proto3 and are not supported.
package Proto.Types

import Std.Core
import Std.Math

// ─── Wire types ──────────────────────────────────────────────────────────────

/// The four active protobuf wire types.
@stable(since="0.1")
pub type WireType = enum {
  case Varint          // id 0 — int32, int64, uint32, uint64, sint32, sint64, bool, enum
  case Fixed64         // id 1 — fixed64, sfixed64, double
  case LengthDelimited // id 2 — string, bytes, embedded messages, packed repeated fields
  case Fixed32         // id 5 — fixed32, sfixed32, float
}

/// Integer wire-type identifier used when encoding field tags.
@stable(since="0.1")
pub func wireTypeId(w: WireType): Int {
  match w {
    case WireType.Varint          -> 0
    case WireType.Fixed64         -> 1
    case WireType.LengthDelimited -> 2
    case WireType.Fixed32         -> 5
  }
}

// ─── Field values for encoding ───────────────────────────────────────────────

/// A field value ready to be written to a ProtoBuffer.
/// The field number is carried alongside the value so the encoder can emit
/// the tag and value together in a single pass over the field list.
@stable(since="0.1")
pub type ProtoField = enum {
  /// Variable-length integer.  Covers bool, enum, int32, int64, uint32, uint64.
  /// Callers pass the raw bit pattern (for sint32/sint64, ZigZag-encode first).
  case VarField(number: Int, v: Long)

  /// 32-bit little-endian word.  Covers float, fixed32, sfixed32.
  /// For float: pass `floatToInt32Bits(f)` as the bits value.
  case Fix32Field(number: Int, bits: Int)

  /// 64-bit little-endian word.  Covers double, fixed64, sfixed64.
  /// For double: pass `doubleToInt64Bits(d)` as the bits value.
  case Fix64Field(number: Int, bits: Long)

  /// Length-delimited bytes.  Covers string (UTF-8), bytes, embedded messages,
  /// and packed repeated fields.  For strings, encode to UTF-8 bytes first.
  /// For embedded messages, encode them with encodeMessage first.
  case BytesField(number: Int, data: slice[Byte])
}

// ─── Field values for decoding ───────────────────────────────────────────────

/// A field decoded from a raw protobuf byte stream.  The caller inspects the
/// field number and wire type to decide how to interpret the raw bits.
@stable(since="0.1")
pub type DecodedField = enum {
  case DecodedVarint(number: Int, v: Long)
  case DecodedFixed32(number: Int, bits: Int)
  case DecodedFixed64(number: Int, bits: Long)
  case DecodedBytes(number: Int, data: slice[Byte])
}

/// One step of the streaming decoder: the field that was read and the byte
/// offset immediately past it (ready for the next decodeStep call).
@stable(since="0.1")
pub type DecodeStep = record {
  field:      DecodedField
  nextOffset: Int
}

// ─── Helpers for proto3 default filtering ────────────────────────────────────

/// ZigZag-encode a signed 32-bit integer for sint32 fields.
///
/// Maps signed integers to unsigned values so that small-magnitude
/// negative numbers encode compactly in protobuf varint form.
/// Encoding: n ≥ 0 → 2n; n < 0 → -2n - 1.
/// This is equivalent to (n << 1) ^ (n >> 31) with arithmetic
/// right shift, but expressed using only portable arithmetic since
/// Lyric's bitwise-shift operators (.shl/.shr) are not yet available
/// in the bootstrap compiler.
@stable(since="0.1")
pub func zigzag32(n: Int): Long {
  val longN = intToLong(n)
  if n >= 0 { longN * 2i64 } else { longN * -2i64 - 1i64 }
}

/// ZigZag-encode a signed 64-bit integer for sint64 fields.
///
/// Same mapping as zigzag32 extended to 64-bit range.
/// Equivalent to (n << 1) ^ (n >> 63) with arithmetic right shift.
@stable(since="0.1")
pub func zigzag64(n: Long): Long {
  if n >= 0i64 { n * 2i64 } else { n * -2i64 - 1i64 }
}

/// ZigZag-decode a sint32 value.
///
/// Reverses zigzag32: even inputs map to non-negative, odd inputs to
/// negative integers.  Input must be non-negative (valid ZigZag output).
/// Equivalent to (n >> 1) ^ -(n & 1) with logical right shift on the
/// non-negative encoded value.
@stable(since="0.1")
pub func unzigzag32(n: Long): Int {
  if n % 2i64 == 0i64 { longToInt(n / 2i64) } else { longToInt(-((n + 1i64) / 2i64)) }
}

/// ZigZag-decode a sint64 value.
///
/// Reverses zigzag64.  Input must be non-negative.
@stable(since="0.1")
pub func unzigzag64(n: Long): Long {
  if n % 2i64 == 0i64 { n / 2i64 } else { -((n + 1i64) / 2i64) }
}
