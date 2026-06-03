// lyric-proto public API.
// Stability: @experimental — the proto3 encoder and decoder have unit-level
// tests, but interop against the canonical Google protobuf tooling has not
// been exercised in CI.
//
// Consumers import this package and use encodeMessage / decodeMessage.
// Import Proto.Types for the field value constructors (ProtoField, DecodedField).
// Import Proto.Encoding for convenience constructors (floatField, boolField, …).
// Import Proto.Decoding for typed extraction helpers (findVarint, findBytes, …).
//
// Quick start:
//
//   import Proto
//   import Proto.Types
//   import Proto.Encoding
//
//   // Encode a message with two fields: field 1 = int64 42, field 2 = "hello"
//   val helloUtf8: slice[Byte] = ...
//   val payload = Proto.encodeMessage([
//     ProtoField.VarField(1, 42L),
//     ProtoField.BytesField(2, helloUtf8),
//   ])
//
//   // Decode a response
//   match Proto.decodeMessage(responseBytes) {
//     case Err(e) -> log("decode error: " + e)
//     case Ok(fields) -> {
//       val v = Proto.findVarint(fields, 1).unwrapOr(0L)
//     }
//   }
package Proto

import Proto.Types
import Proto.Encoding
import Proto.Decoding
import Std.Core
import Std.Collections

// ─── Re-export the primary encode/decode entry points ─────────────────────────

/// Encode a proto3 message from a list of fields.
/// Fields are written in list order; proto3 does not require field ordering.
@stable(since="0.1")
pub func encodeMessage(fields: List[ProtoField]): slice[Byte] {
  Proto.Encoding.encodeMessage(fields)
}

/// Decode all fields from a proto3-encoded byte slice.
/// Returns Err on the first malformed field; unknown fields are included.
@stable(since="0.1")
pub func decodeMessage(data: in slice[Byte]): Result[List[DecodedField], String] {
  Proto.Decoding.decodeMessage(data)
}

// ─── Re-export convenience constructors from Proto.Encoding ──────────────────

@stable(since="0.1")
pub func floatField(number: Int, v: Float): ProtoField {
  Proto.Encoding.floatField(number, v)
}

@stable(since="0.1")
pub func doubleField(number: Int, v: Float): ProtoField {
  Proto.Encoding.doubleField(number, v)
}

@stable(since="0.1")
pub func boolField(number: Int, v: Bool): ProtoField {
  Proto.Encoding.boolField(number, v)
}

@stable(since="0.1")
pub func enumField(number: Int, ordinal: Int): ProtoField {
  Proto.Encoding.enumField(number, ordinal)
}

@stable(since="0.1")
pub func stringField(number: Int, utf8: slice[Byte]): ProtoField {
  Proto.Encoding.stringField(number, utf8)
}

@stable(since="0.1")
pub func embeddedField(number: Int, inner: slice[Byte]): ProtoField {
  Proto.Encoding.embeddedField(number, inner)
}

@stable(since="0.1")
pub func sint32Field(number: Int, v: Int): ProtoField {
  Proto.Encoding.sint32Field(number, v)
}

@stable(since="0.1")
pub func sint64Field(number: Int, v: Long): ProtoField {
  Proto.Encoding.sint64Field(number, v)
}

// ─── Re-export typed extraction helpers from Proto.Decoding ──────────────────

@stable(since="0.1")
pub func findVarint(fields: in List[DecodedField], number: Int): Option[Long] {
  Proto.Decoding.findVarint(fields, number)
}

@stable(since="0.1")
pub func findBytes(fields: in List[DecodedField], number: Int): Option[slice[Byte]] {
  Proto.Decoding.findBytes(fields, number)
}

@stable(since="0.1")
pub func collectBytes(fields: in List[DecodedField], number: Int): List[slice[Byte]] {
  Proto.Decoding.collectBytes(fields, number)
}
