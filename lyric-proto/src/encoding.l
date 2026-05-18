// Pure-Lyric Protocol Buffer encoder.
//
// The encoder builds messages by accumulating bytes into a ProtoBuffer
// (an opaque kernel-backed accumulator).  Consumers do not interact with
// ProtoBuffer directly; the public entry point is encodeMessage, which
// takes a List[ProtoField] and returns a slice[Byte].
//
// Field ordering: proto3 does not require fields to be in field-number order,
// but encoding them in ascending order is conventional and produces stable
// output.  encodeMessage preserves the order of the input list.
//
// Embedded messages: encode the inner message with encodeMessage first, then
// wrap the result in a BytesField for the outer message.
//
//   val inner = encodeMessage([VarField(1, 42L)])
//   val outer = encodeMessage([BytesField(1, inner)])
package Proto.Encoding

import Proto.Types
import Proto.Kernel.Net
import Proto.Kernel.Jvm
import Std.Core
import Std.Collections

// ─── VarInt encoding ─────────────────────────────────────────────────────────

/// Append a varint to `buf`.  Treats `v` as an unsigned 64-bit integer.
/// Each output byte carries 7 payload bits; the MSB is 1 if more bytes follow.
func writeVarint(buf: ProtoBuffer, v: Long): Unit {
  var remaining = v
  while remaining >= 128L {
    bufWriteByte(buf, ((remaining & 0x7FL) | 0x80L).toInt())
    remaining = remaining >> 7
  }
  bufWriteByte(buf, (remaining & 0x7FL).toInt())
}

// ─── Field tag encoding ───────────────────────────────────────────────────────

/// Append the field tag for (fieldNumber, wireType) to `buf`.
/// tag = (fieldNumber << 3) | wireTypeId
func writeTag(buf: ProtoBuffer, fieldNumber: Int, wireType: WireType): Unit {
  val tag = ((fieldNumber.toLong() << 3) | wireTypeId(wireType).toLong())
  writeVarint(buf, tag)
}

// ─── Fixed-width encoding ─────────────────────────────────────────────────────

/// Append a 32-bit value in little-endian byte order.
func writeFixed32(buf: ProtoBuffer, bits: Int): Unit {
  bufWriteByte(buf, bits & 0xFF)
  bufWriteByte(buf, (bits >> 8) & 0xFF)
  bufWriteByte(buf, (bits >> 16) & 0xFF)
  bufWriteByte(buf, (bits >> 24) & 0xFF)
}

/// Append a 64-bit value in little-endian byte order.
func writeFixed64(buf: ProtoBuffer, bits: Long): Unit {
  bufWriteByte(buf, (bits & 0xFFL).toInt())
  bufWriteByte(buf, ((bits >> 8) & 0xFFL).toInt())
  bufWriteByte(buf, ((bits >> 16) & 0xFFL).toInt())
  bufWriteByte(buf, ((bits >> 24) & 0xFFL).toInt())
  bufWriteByte(buf, ((bits >> 32) & 0xFFL).toInt())
  bufWriteByte(buf, ((bits >> 40) & 0xFFL).toInt())
  bufWriteByte(buf, ((bits >> 48) & 0xFFL).toInt())
  bufWriteByte(buf, ((bits >> 56) & 0xFFL).toInt())
}

// ─── Single-field encoding ────────────────────────────────────────────────────

/// Append a single ProtoField (tag + value) to `buf`.
func writeField(buf: ProtoBuffer, field: ProtoField): Unit {
  match field {
    case ProtoField.VarField(number, v) -> {
      writeTag(buf, number, WireType.Varint)
      writeVarint(buf, v)
    }
    case ProtoField.Fix32Field(number, bits) -> {
      writeTag(buf, number, WireType.Fixed32)
      writeFixed32(buf, bits)
    }
    case ProtoField.Fix64Field(number, bits) -> {
      writeTag(buf, number, WireType.Fixed64)
      writeFixed64(buf, bits)
    }
    case ProtoField.BytesField(number, data) -> {
      writeTag(buf, number, WireType.LengthDelimited)
      writeVarint(buf, data.length.toLong())
      bufWriteBytes(buf, data)
    }
  }
}

// ─── Message encoding ─────────────────────────────────────────────────────────

/// Encode a proto3 message from a list of fields.
/// Returns the binary protobuf encoding as a byte slice.
///
/// Proto3 default values (0, false, "", empty bytes) are omitted by convention.
/// This function encodes every field it receives; callers should filter defaults
/// before calling if they want proto3-idiomatic output.
@stable(since="0.1")
pub func encodeMessage(fields: List[ProtoField]): slice[Byte] {
  val buf = newProtoBuffer()
  fields.forEach(func(f) { writeField(buf, f) })
  bufToBytes(buf)
}

// ─── Convenience constructors ─────────────────────────────────────────────────

/// Encode a float field (field tag + fixed32 IEEE 754 bits).
@stable(since="0.1")
pub func floatField(number: Int, v: Float): ProtoField {
  ProtoField.Fix32Field(number, floatToInt32Bits(v))
}

/// Encode a double field (field tag + fixed64 IEEE 754 bits).
@stable(since="0.1")
pub func doubleField(number: Int, v: Float): ProtoField {
  ProtoField.Fix64Field(number, doubleToInt64Bits(v))
}

/// Encode a bool field (varint 0 or 1).
@stable(since="0.1")
pub func boolField(number: Int, v: Bool): ProtoField {
  ProtoField.VarField(number, if v { 1L } else { 0L })
}

/// Encode an enum field (varint with the enum's integer ordinal).
@stable(since="0.1")
pub func enumField(number: Int, ordinal: Int): ProtoField {
  ProtoField.VarField(number, ordinal.toLong())
}

/// Encode a string field (UTF-8 bytes, length-delimited).
/// The `utf8` slice must already be UTF-8 encoded.
@stable(since="0.1")
pub func stringField(number: Int, utf8: slice[Byte]): ProtoField {
  ProtoField.BytesField(number, utf8)
}

/// Encode an embedded message field.
/// `inner` should be the output of encodeMessage for the nested message.
@stable(since="0.1")
pub func embeddedField(number: Int, inner: slice[Byte]): ProtoField {
  ProtoField.BytesField(number, inner)
}

/// Encode a sint32 field using ZigZag encoding.
@stable(since="0.1")
pub func sint32Field(number: Int, v: Int): ProtoField {
  ProtoField.VarField(number, zigzag32(v))
}

/// Encode a sint64 field using ZigZag encoding.
@stable(since="0.1")
pub func sint64Field(number: Int, v: Long): ProtoField {
  ProtoField.VarField(number, zigzag64(v))
}
