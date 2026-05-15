/// Pure-Lyric Protocol Buffer decoder.
///
/// The decoder reads a binary proto3 message byte-by-byte, producing a
/// List[DecodedField] that the caller can pattern-match on.  Unknown fields
/// are decoded by wire type and included in the output (proto3 unknown-field
/// forwarding behaviour).
///
/// Decoding is safe: every out-of-bounds or malformed input returns
/// Result.Err rather than panicking.
package Proto.Decoding

import Proto.Types
import Proto.Kernel.Net
import Proto.Kernel.Jvm
import Std.Core
import Std.Collections

// ─── VarInt decoding ─────────────────────────────────────────────────────────

/// Result of reading one varint: the value and the offset past the last byte.
type VarintResult = record {
  value:      Long
  nextOffset: Int
}

/// Attempt to read a varint starting at `offset` in `data`.
/// Returns Err if the input is truncated or exceeds 10 bytes (the maximum
/// for a 64-bit varint).
func readVarint(data: in slice[Byte], offset: Int): Result[VarintResult, String] {
  var result: Long = 0L
  var shift: Int   = 0
  var pos: Int     = offset
  while pos < data.length {
    val b = byteAt(data, pos)
    pos = pos + 1
    result = result | ((b & 0x7F).toLong() << shift)
    shift = shift + 7
    if (b & 0x80) == 0 {
      return Ok(VarintResult { value = result, nextOffset = pos })
    }
    if shift >= 70 {
      return Err("varint overflow: more than 10 continuation bytes at offset " + offset.toString())
    }
  }
  Err("truncated varint at offset " + offset.toString())
}

// ─── Field decoding ───────────────────────────────────────────────────────────

/// Attempt to decode one field starting at `offset`.
/// Returns Err on truncation or an unrecognised wire type.
pub func decodeStep(data: in slice[Byte], offset: Int): Result[DecodeStep, String] {
  if offset >= data.length {
    return Err("end of input at offset " + offset.toString())
  }
  // Read the field tag (varint: field number << 3 | wire type id).
  match readVarint(data, offset) {
    case Err(e) -> Err("tag read failed: " + e)
    case Ok(tagResult) -> {
      val tag        = tagResult.value
      val fieldNum   = (tag >> 3).toInt()
      val wireTypeId = (tag & 7L).toInt()
      val afterTag   = tagResult.nextOffset
      match wireTypeId {
        // Varint
        case 0 ->
          match readVarint(data, afterTag) {
            case Err(e) -> Err("varint field " + fieldNum.toString() + ": " + e)
            case Ok(vr) ->
              Ok(DecodeStep {
                field      = DecodedField.DecodedVarint(fieldNum, vr.value)
                nextOffset = vr.nextOffset
              })
          }
        // 64-bit fixed
        case 1 -> {
          if afterTag + 8 > data.length {
            Err("truncated fixed64 at field " + fieldNum.toString())
          } else {
            Ok(DecodeStep {
              field      = DecodedField.DecodedFixed64(fieldNum, int64LE(data, afterTag))
              nextOffset = afterTag + 8
            })
          }
        }
        // Length-delimited
        case 2 ->
          match readVarint(data, afterTag) {
            case Err(e) -> Err("length prefix at field " + fieldNum.toString() + ": " + e)
            case Ok(lenResult) -> {
              val length  = lenResult.value.toInt()
              val dataStart = lenResult.nextOffset
              if dataStart + length > data.length {
                Err("truncated bytes field " + fieldNum.toString())
              } else {
                Ok(DecodeStep {
                  field      = DecodedField.DecodedBytes(fieldNum, sliceCopy(data, dataStart, length))
                  nextOffset = dataStart + length
                })
              }
            }
          }
        // 32-bit fixed
        case 5 -> {
          if afterTag + 4 > data.length {
            Err("truncated fixed32 at field " + fieldNum.toString())
          } else {
            Ok(DecodeStep {
              field      = DecodedField.DecodedFixed32(fieldNum, int32LE(data, afterTag))
              nextOffset = afterTag + 4
            })
          }
        }
        // Deprecated group types (3, 4) and anything else
        case _ ->
          Err("unsupported wire type " + wireTypeId.toString() + " at field " + fieldNum.toString())
      }
    }
  }
}

/// Decode all fields in `data`, returning them in order.
/// Stops at end-of-input; returns Err on the first malformed field.
pub func decodeMessage(data: in slice[Byte]): Result[List[DecodedField], String] {
  var offset: Int                 = 0
  var fields: List[DecodedField]  = List.empty()
  while offset < data.length {
    match decodeStep(data, offset) {
      case Err(e) -> return Err(e)
      case Ok(step) -> {
        fields = fields.append(step.field)
        offset = step.nextOffset
      }
    }
  }
  Ok(fields)
}

// ─── Typed field extraction helpers ──────────────────────────────────────────

/// Find the first varint field with the given field number, or None.
pub func findVarint(fields: in List[DecodedField], number: Int): Option[Long] {
  fields.find(func(f) {
    match f {
      case DecodedField.DecodedVarint(n, _) -> n == number
      case _ -> false
    }
  }).map(func(f) {
    match f {
      case DecodedField.DecodedVarint(_, v) -> v
      case _ -> 0L
    }
  })
}

/// Find the first bytes field with the given field number, or None.
pub func findBytes(fields: in List[DecodedField], number: Int): Option[slice[Byte]] {
  fields.find(func(f) {
    match f {
      case DecodedField.DecodedBytes(n, _) -> n == number
      case _ -> false
    }
  }).map(func(f) {
    match f {
      case DecodedField.DecodedBytes(_, data) -> data
      case _ -> sliceCopy(data, 0, 0)
    }
  })
}

/// Collect all bytes fields with the given field number (repeated field).
pub func collectBytes(fields: in List[DecodedField], number: Int): List[slice[Byte]] {
  fields.filterMap(func(f) {
    match f {
      case DecodedField.DecodedBytes(n, data) ->
        if n == number { Option.Some(data) } else { Option.None }
      case _ -> Option.None
    }
  })
}
