//! lyric-proto — Pure-Lyric Protocol Buffer (proto3) wire-format encoder and decoder.
//!
//! This file merges Proto.Types, Proto.Encoding, Proto.Decoding, Proto, and the
//! .NET kernel boundary into a single package for bootstrap compatibility.
//! Cross-package union/enum access and TypeId alignment across intra-artifact
//! packages are not supported by the bootstrap emitter; everything must be in
//! one package.
package Proto

import Std.Core
import Std.Collections

// ═══════════════════════════════════════════════════════════════════════════════
// ─── .NET kernel boundary (inlined from Proto.Kernel.Net) ────────────────────
// ═══════════════════════════════════════════════════════════════════════════════
/// A mutable byte accumulator.  Backed by a pure-Lyric `List[Byte]` rather than
/// a `System.IO.MemoryStream`: the BCL stream forced fragile instance-method FFI
/// (`WriteByte(byte)` / `ToArray()`) whose hand-routed `@externTarget` form
/// mis-binds the receiver as a leading parameter, and whose auto-FFI form fails
/// to resolve a zero-arg instance method.  A `List[Byte]` accumulator is fully
/// portable (no `.NET`-only boundary) and records are reference types, so writes
/// through the `in` borrow persist.
pub record ProtoBuffer {
  var bytes: List[Byte]
}

/// Allocate a fresh empty ProtoBuffer.
pub func newProtoBuffer(): ProtoBuffer {
  return ProtoBuffer(bytes = newList())
}

/// Append the low byte of `b` (b & 0xFF) to the buffer.
pub func bufWriteByte(buf: ProtoBuffer, b: in Int): Unit {
  buf.bytes.add(b.and(255).toByte())
}

/// Append all bytes from `data` to the buffer.
pub func bufWriteBytes(buf: ProtoBuffer, data: in slice[Byte]): Unit {
  var i = 0
  while i < data.length {
    buf.bytes.add(data[i])
    i = i + 1
  }
}

/// Extract the accumulated bytes as an immutable slice.
pub func bufToBytes(buf: ProtoBuffer): slice[Byte] {
  return buf.bytes.toArray()
}

/// Reinterpret a 32-bit float as its IEEE 754 bit pattern (returned as Int).
@externTarget("System.BitConverter.SingleToInt32Bits")
pub func floatToInt32Bits(v: in Float): Int = ()

/// Reinterpret a 64-bit double as its IEEE 754 bit pattern (returned as Long).
@externTarget("System.BitConverter.DoubleToInt64Bits")
pub func doubleToInt64Bits(v: in Double): Long = ()

/// Read a single byte from `data[offset]` as an unsigned Int (0-255).
pub func byteAt(data: in slice[Byte], offset: in Int): Int {
  data[offset].toInt()
}

/// Read four bytes from data[offset..offset+4) as a little-endian Int32.
pub func int32LE(data: in slice[Byte], offset: in Int): Int {
  val b0 = byteAt(data, offset)
  val b1 = byteAt(data, offset + 1)
  val b2 = byteAt(data, offset + 2)
  val b3 = byteAt(data, offset + 3)
  b0.or(b1.shl(8)).or(b2.shl(16)).or(b3.shl(24))
}

/// Read eight bytes from data[offset..offset+8) as a little-endian Int64.
pub func int64LE(data: in slice[Byte], offset: in Int): Long {
  var result = 0i64
  var i = 0
  while i < 8 {
    val bi = intAsLong(byteAt(data, offset + i))
    result = result.or(bi.shl(i * 8))
    i = i + 1
  }
  result
}

/// Copy data[offset..offset+length) into a fresh slice[Byte].
pub func sliceCopy(data: in slice[Byte], offset: in Int, length: in Int): slice[Byte] {
  var acc: List[Byte] = newList()
  var i = 0
  while i < length {
    acc.add(data[offset + i])
    i = i + 1
  }
  acc.toArray()
}

/// Widen an Int (32-bit) to a Long (64-bit).
@externTarget("System.Convert.ToInt64")
pub func intAsLong(n: in Int): Long = ()

/// Narrow a Long (64-bit) to an Int (32-bit).
@externTarget("System.Convert.ToInt32")
pub func longAsInt(n: in Long): Int = ()

/// Bitwise AND for Long values.
pub func bitandLong(a: in Long, b: in Long): Long {
  a.and(b)
}

/// Bitwise OR for Long values.
pub func bitorLong(a: in Long, b: in Long): Long {
  a.or(b)
}

/// Bitwise AND for Int values.
pub func bitandInt(a: in Int, b: in Int): Int {
  a.and(b)
}

/// Bitwise OR for Int values.
pub func bitorInt(a: in Int, b: in Int): Int {
  a.or(b)
}

/// Left shift a Long by `shift` positions.
pub func shlLong(v: in Long, shift: in Int): Long {
  v.shl(shift)
}

/// Arithmetic right shift a Long by `shift` positions.
pub func shrLong(v: in Long, shift: in Int): Long {
  v.shr(shift)
}

/// Left shift an Int by `shift` positions.
pub func shlInt(v: in Int, shift: in Int): Int {
  v.shl(shift)
}

/// Arithmetic right shift an Int by `shift` positions.
pub func shrInt(v: in Int, shift: in Int): Int {
  v.shr(shift)
}

/// Bitwise XOR for Long values.
pub func xorLong(a: in Long, b: in Long): Long {
  a.xor(b)
}

/// Bitwise XOR for Int values.
pub func xorInt(a: in Int, b: in Int): Int {
  a.xor(b)
}

// ═══════════════════════════════════════════════════════════════════════════════
// ─── Wire types ──────────────────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════════
// Wire type constants (replaces pub enum WireType).
// Bootstrap limitation: cross-package enum access is unsupported; use Int
// constants directly to avoid the cross-package restriction.
val WIRE_VARINT: Int = 0

val WIRE_FIXED64: Int = 1

val WIRE_LENGTH_DELIMITED: Int = 2

val WIRE_FIXED32: Int = 5

// ═══════════════════════════════════════════════════════════════════════════════
// ─── Field values for encoding ───────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════════
/// A field value ready to be written to a ProtoBuffer.
pub union ProtoField {
  case VarField(number: Int, v: Long)
  case Fix32Field(number: Int, bits: Int)
  case Fix64Field(number: Int, bits: Long)
  case BytesField(number: Int, data: slice[Byte])
  // ─── Field values for decoding ───────────────────────────────────────────────
}

/// A field decoded from a raw protobuf byte stream.
pub union DecodedField {
  case DecodedVarint(number: Int, v: Long)
  case DecodedFixed32(number: Int, bits: Int)
  case DecodedFixed64(number: Int, bits: Long)
  case DecodedBytes(number: Int, data: slice[Byte])
}

/// One step of the streaming decoder.
pub record DecodeStep {
  field: DecodedField
  nextOffset: Int
  // ─── Varint decode scratch record ─────────────────────────────────────────────
}

record VarintResult {
  value: Long
  nextOffset: Int
  // ═══════════════════════════════════════════════════════════════════════════════
  // ─── ZigZag helpers ──────────────────────────────────────────────────────────
  // ═══════════════════════════════════════════════════════════════════════════════
}

/// ZigZag-encode a signed 32-bit integer for sint32 fields.
pub func zigzag32(n: Int): Long {
  val nL = intAsLong(n)
  val sh1 = shlLong(nL, 1)
  val sh2 = shrLong(nL, 31)
  xorLong(sh1, sh2)
}

/// ZigZag-encode a signed 64-bit integer for sint64 fields.
pub func zigzag64(n: Long): Long {
  xorLong(shlLong(n, 1), shrLong(n, 63))
}

/// ZigZag-decode a sint32 value.
pub func unzigzag32(n: Long): Int {
  val shifted = shrLong(n, 1)
  val mask = -(bitandLong(n, 1i64))
  longAsInt(xorLong(shifted, mask))
}

/// ZigZag-decode a sint64 value.
pub func unzigzag64(n: Long): Long {
  xorLong(shrLong(n, 1), -(bitandLong(n, 1i64)))
}

// ═══════════════════════════════════════════════════════════════════════════════
// ─── VarInt encoding ─────────────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════════
func writeVarint(buf: ProtoBuffer, v: Long): Unit {
  var remaining = v
  // proto3 encodes a negative int32/int64 as the full 10-byte varint of its
  // 64-bit two's-complement bit pattern.  Loop on the *unsigned* value: a
  // negative `remaining` has the high bit set (so `< 0` under signed compare),
  // and the shift must be LOGICAL — an arithmetic `shr` sign-extends and never
  // terminates.  Simulate logical shift-by-7 by masking off the 7 high bits the
  // arithmetic shift sign-extended (`& 0x01FF…FF` keeps the low 57 bits).
  while remaining < 0i64 or remaining >= 128i64 {
    val lo7 = bitandLong(remaining, 127i64)
    bufWriteByte(buf, longAsInt(bitorLong(lo7, 128i64)))
    remaining = bitandLong(shrLong(remaining, 7), 0x01FFFFFFFFFFFFFFi64)
  }
  bufWriteByte(buf, longAsInt(bitandLong(remaining, 127i64)))
}

// ─── Field tag encoding ───────────────────────────────────────────────────────
func writeTag(buf: ProtoBuffer, fieldNumber: Int, wireTypeId: Int): Unit {
  val fnL = intAsLong(fieldNumber)
  val wtL = intAsLong(wireTypeId)
  val tag = bitorLong(shlLong(fnL, 3), wtL)
  writeVarint(buf, tag)
}

// ─── Fixed-width encoding ─────────────────────────────────────────────────────
func writeFixed32(buf: ProtoBuffer, bits: Int): Unit {
  bufWriteByte(buf, bitandInt(bits, 255))
  bufWriteByte(buf, bitandInt(shrInt(bits, 8), 255))
  bufWriteByte(buf, bitandInt(shrInt(bits, 16), 255))
  bufWriteByte(buf, bitandInt(shrInt(bits, 24), 255))
}

func writeFixed64(buf: ProtoBuffer, bits: Long): Unit {
  bufWriteByte(buf, longAsInt(bitandLong(bits, 255i64)))
  bufWriteByte(buf, longAsInt(bitandLong(shrLong(bits, 8), 255i64)))
  bufWriteByte(buf, longAsInt(bitandLong(shrLong(bits, 16), 255i64)))
  bufWriteByte(buf, longAsInt(bitandLong(shrLong(bits, 24), 255i64)))
  bufWriteByte(buf, longAsInt(bitandLong(shrLong(bits, 32), 255i64)))
  bufWriteByte(buf, longAsInt(bitandLong(shrLong(bits, 40), 255i64)))
  bufWriteByte(buf, longAsInt(bitandLong(shrLong(bits, 48), 255i64)))
  bufWriteByte(buf, longAsInt(bitandLong(shrLong(bits, 56), 255i64)))
}

// ─── Single-field encoding ────────────────────────────────────────────────────
func writeField(buf: ProtoBuffer, field: ProtoField): Unit {
  match field {
    case VarField(number, v) -> {
      writeTag(buf, number, WIRE_VARINT)
      writeVarint(buf, v)
    }
    case Fix32Field(number, bits) -> {
      writeTag(buf, number, WIRE_FIXED32)
      writeFixed32(buf, bits)
    }
    case Fix64Field(number, bits) -> {
      writeTag(buf, number, WIRE_FIXED64)
      writeFixed64(buf, bits)
    }
    case BytesField(number, data) -> {
      writeTag(buf, number, WIRE_LENGTH_DELIMITED)
      val lenL = intAsLong(data.length)
      writeVarint(buf, lenL)
      bufWriteBytes(buf, data)
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ─── Message encoding ────────────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════════
/// Encode a proto3 message from a list of fields.
pub func encodeMessage(fields: List[ProtoField]): slice[Byte] {
  val buf = newProtoBuffer()
  for f in fields {
    writeField(buf, f)
  }
  bufToBytes(buf)
}

// ─── Convenience constructors ─────────────────────────────────────────────────
pub func floatField(number: Int, v: Float): ProtoField {
  Fix32Field(number, floatToInt32Bits(v))
}

pub func doubleField(number: Int, v: Double): ProtoField {
  Fix64Field(number, doubleToInt64Bits(v))
}

pub func boolField(number: Int, v: Bool): ProtoField {
  VarField(number, if v { 1i64 } else { 0i64 })
}

pub func enumField(number: Int, ordinal: Int): ProtoField {
  VarField(number, intAsLong(ordinal))
}

pub func stringField(number: Int, utf8: slice[Byte]): ProtoField {
  BytesField(number, utf8)
}

pub func embeddedField(number: Int, inner: slice[Byte]): ProtoField {
  BytesField(number, inner)
}

pub func sint32Field(number: Int, v: Int): ProtoField {
  VarField(number, zigzag32(v))
}

pub func sint64Field(number: Int, v: Long): ProtoField {
  VarField(number, zigzag64(v))
}

// ═══════════════════════════════════════════════════════════════════════════════
// ─── VarInt decoding ─────────────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════════
func readVarint(data: in slice[Byte], offset: Int): Result[VarintResult, String] {
  var acc: Long = 0i64
  var shift: Int = 0
  var pos: Int = offset
  while pos < data.length {
    val b = byteAt(data, pos)
    pos = pos + 1
    val lo7 = intAsLong(bitandInt(b, 127))
    acc = bitorLong(acc, shlLong(lo7, shift))
    shift = shift + 7
    if bitandInt(b, 128) == 0 {
      return Ok(value = VarintResult(value = acc, nextOffset = pos))
    }
    if shift >= 70 {
      return Err(error = "varint overflow: more than 10 continuation bytes at offset " + offset.toString())
    }
  }
  Err(error = "truncated varint at offset " + offset.toString())
}

// ═══════════════════════════════════════════════════════════════════════════════
// ─── Field decoding ──────────────────────────────────────────────────────────
// ═══════════════════════════════════════════════════════════════════════════════
/// Attempt to decode one field starting at `offset`.
pub func decodeStep(data: in slice[Byte], offset: Int): Result[DecodeStep, String] {
  if offset >= data.length {
    return Err(error = "end of input at offset " + offset.toString())
  }
  match readVarint(data, offset) {
    case Err(e) -> Err(error = "tag read failed: " + e)
    case Ok(tagResult) -> {
      val tag = tagResult.value
      val fieldNum = longAsInt(shrLong(tag, 3))
      val wireTypeId = longAsInt(bitandLong(tag, 7i64))
      val afterTag = tagResult.nextOffset
      // Raw literals because Lyric match requires literal patterns (val constants
      // cannot be used as arms): 0=WIRE_VARINT, 1=WIRE_FIXED64, 2=WIRE_LENGTH_DELIMITED, 5=WIRE_FIXED32.
      match wireTypeId {
        case 0 -> match readVarint(data, afterTag) { case Err(e) -> Err(error = "varint field " + fieldNum.toString() + ": " + e); case Ok(vr) -> Ok(value = DecodeStep(field = DecodedVarint(fieldNum, vr.value), nextOffset = vr.nextOffset)) }
        case 1 -> {
          if afterTag + 8 > data.length {
            Err(error = "truncated fixed64 at field " + fieldNum.toString())
          } else {
            Ok(value = DecodeStep(field = DecodedFixed64(fieldNum, int64LE(data, afterTag)), nextOffset = afterTag + 8))
          }
        }
        case 2 -> match readVarint(data, afterTag) { case Err(e) -> Err(error = "length prefix at field " + fieldNum.toString() + ": " + e); case Ok(lenResult) -> { val length = longAsInt(lenResult.value); val dataStart = lenResult.nextOffset; if dataStart + length > data.length { Err(error = "truncated bytes field " + fieldNum.toString()) } else { Ok(value = DecodeStep(field = DecodedBytes(fieldNum, sliceCopy(data, dataStart, length)), nextOffset = dataStart + length)) } } }
        case 5 -> {
          if afterTag + 4 > data.length {
            Err(error = "truncated fixed32 at field " + fieldNum.toString())
          } else {
            Ok(value = DecodeStep(field = DecodedFixed32(fieldNum, int32LE(data, afterTag)), nextOffset = afterTag + 4))
          }
        }
        case _ -> Err(error = "unsupported wire type " + wireTypeId.toString() + " at field " + fieldNum.toString())
      }
    }
  }
}

/// Decode all fields in `data`, returning them in order.
pub func decodeMessage(data: in slice[Byte]): Result[List[DecodedField], String] {
  var offset: Int = 0
  val fields = newList()
  while offset < data.length {
    match decodeStep(data, offset) {
      case Err(e) -> return Err(error = e)
      case Ok(step) -> {
        fields.add(step.field)
        offset = step.nextOffset
      }
    }
  }
  Ok(value = fields)
}

// ─── Typed field extraction helpers ──────────────────────────────────────────
/// Find the first varint field with the given field number, or None.
pub func findVarint(fields: in List[DecodedField], number: Int): Option[Long] {
  val arr = fields.toArray()
  for f in arr {
    match f {
      case DecodedVarint(n, v) -> {
        if n == number {
          return Some(value = v)
        }
      }
      case _ -> ()
    }
  }
  None
}

/// Find the first bytes field with the given field number, or None.
pub func findBytes(fields: in List[DecodedField], number: Int): Option[slice[Byte]] {
  val arr = fields.toArray()
  for f in arr {
    match f {
      case DecodedBytes(n, data) -> {
        if n == number {
          return Some(value = data)
        }
      }
      case _ -> ()
    }
  }
  None
}

/// Collect all bytes fields with the given field number (repeated field).
pub func collectBytes(fields: in List[DecodedField], number: Int): List[slice[Byte]] {
  val res = newList()
  val arr = fields.toArray()
  for f in arr {
    match f {
      case DecodedBytes(n, data) -> {
        if n == number {
          res.add(data)
        }
      }
      case _ -> ()
    }
  }
  res
}
