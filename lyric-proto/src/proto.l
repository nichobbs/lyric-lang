/// lyric-proto public API.
///
/// Consumers import this package and use encodeMessage / decodeMessage.
/// Import Proto.Types for the field value constructors (ProtoField, DecodedField).
/// Import Proto.Encoding for convenience constructors (floatField, boolField, …).
/// Import Proto.Decoding for typed extraction helpers (findVarint, findBytes, …).
///
/// Quick start:
///
///   import Proto
///   import Proto.Types
///   import Proto.Encoding
///
///   // Encode a message with two fields: field 1 = int64 42, field 2 = "hello"
///   val helloUtf8: slice[Byte] = ...
///   val payload = Proto.encodeMessage([
///     ProtoField.VarField(1, 42L),
///     ProtoField.BytesField(2, helloUtf8),
///   ])
///
///   // Decode a response
///   match Proto.decodeMessage(responseBytes) {
///     case Err(e) -> log("decode error: " + e)
///     case Ok(fields) -> {
///       val v = Proto.findVarint(fields, 1).unwrapOr(0L)
///     }
///   }
package Proto

import Proto.Types
import Proto.Encoding
import Proto.Decoding
import Std.Core
import Std.Collections

// ─── Re-export the primary encode/decode entry points ─────────────────────────

/// Encode a proto3 message from a list of fields.
/// Fields are written in list order; proto3 does not require field ordering.
pub func encodeMessage(fields: List[ProtoField]): slice[Byte] {
  Proto.Encoding.encodeMessage(fields)
}

/// Decode all fields from a proto3-encoded byte slice.
/// Returns Err on the first malformed field; unknown fields are included.
pub func decodeMessage(data: in slice[Byte]): Result[List[DecodedField], String] {
  Proto.Decoding.decodeMessage(data)
}

// ─── Re-export convenience constructors from Proto.Encoding ──────────────────

pub func floatField(number: Int, v: Float): ProtoField {
  Proto.Encoding.floatField(number, v)
}

pub func doubleField(number: Int, v: Float): ProtoField {
  Proto.Encoding.doubleField(number, v)
}

pub func boolField(number: Int, v: Bool): ProtoField {
  Proto.Encoding.boolField(number, v)
}

pub func enumField(number: Int, ordinal: Int): ProtoField {
  Proto.Encoding.enumField(number, ordinal)
}

pub func stringField(number: Int, utf8: slice[Byte]): ProtoField {
  Proto.Encoding.stringField(number, utf8)
}

pub func embeddedField(number: Int, inner: slice[Byte]): ProtoField {
  Proto.Encoding.embeddedField(number, inner)
}

pub func sint32Field(number: Int, v: Int): ProtoField {
  Proto.Encoding.sint32Field(number, v)
}

pub func sint64Field(number: Int, v: Long): ProtoField {
  Proto.Encoding.sint64Field(number, v)
}

// ─── Re-export typed extraction helpers from Proto.Decoding ──────────────────

pub func findVarint(fields: in List[DecodedField], number: Int): Option[Long] {
  Proto.Decoding.findVarint(fields, number)
}

pub func findBytes(fields: in List[DecodedField], number: Int): Option[slice[Byte]] {
  Proto.Decoding.findBytes(fields, number)
}

pub func collectBytes(fields: in List[DecodedField], number: Int): List[slice[Byte]] {
  Proto.Decoding.collectBytes(fields, number)
}
