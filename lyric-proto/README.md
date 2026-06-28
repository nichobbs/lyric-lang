# lyric-proto

Pure-Lyric Protocol Buffer (proto3) wire-format encoder and decoder for [Lyric](https://github.com/nichobbs/lyric-lang). Ships low-level `slice[Byte]` marshalling suitable for manual message construction and as a foundation for higher-level code generators.

> **Status**: Library source is complete. Both `.NET` and JVM targets are supported.

## Platform parity

| Target | Status |
|---|---|
| `.NET` | Available |
| JVM | Available |

## Packages

| Package | Description |
|---|---|
| `Proto` | Core: field encoders/decoders, varint encoding, message framing |
| `Proto.Kernel` | Target-specific extern boundary (common for both targets) |

## Installation

```toml
[dependencies]
"Lyric.Proto" = { path = "../lyric-proto" }
```

## Quick start

### Encoding a message

```lyric
import Proto
import Std.Core

// Construct fields using helper functions and union cases
val fields = [
  Proto.VarField(1, 42i64),              // field 1: varint (42)
  Proto.stringField(2, "hello".bytes()), // field 2: string ("hello")
]

// Encode the message
val encoded = Proto.encodeMessage(fields)
```

### Decoding a message

```lyric
import Proto
import Std.Core

val encoded = ...  // slice[Byte] from wire

// Decode all fields
match Proto.decodeMessage(encoded) {
  case Ok(fields) -> {
    for field in fields {
      match field {
        case DecodedVarint(number, value) -> {
          // Field number with varint value
        }
        case DecodedBytes(number, data) -> {
          // Field number with bytes (string or embedded message)
        }
        case DecodedFixed32(number, bits) -> {
          // Field number with 32-bit fixed value
        }
        case DecodedFixed64(number, bits) -> {
          // Field number with 64-bit fixed value
        }
      }
    }
  }
  case Err(e) -> {
    // Decode error
  }
}
```

## Wire format essentials

### Varint encoding

Protocol Buffers encode unsigned integers as varints (variable-length little-endian integers). Each byte encodes 7 bits of data plus a continuation bit. Create varint fields using the `VarField` union case constructor:

```lyric
val field = Proto.VarField(fieldNumber, value)
```

For signed integers, use `sint32Field` or `sint64Field` which apply zigzag encoding before creating a varint field.

### Wire types

| Wire type | Meaning | Example |
|---|---|---|
| 0 | Varint | int32, int64, uint32, uint64, bool, enum |
| 1 | 64-bit | fixed64, double |
| 2 | Length-delimited | string, bytes, embedded message |
| 5 | 32-bit | fixed32, float |

### Field encoding

Each field begins with a tag: `(field_number << 3) | wire_type`

```lyric
// Tag for field 1 (wire type 0 = varint)
val tag = (1 << 3) | 0

// Tag for field 2 (wire type 2 = length-delimited)
val tag = (2 << 3) | 2
```

## Low-level API

### Encoding

#### `encodeMessage`

Encode a proto3 message from a list of fields.

```lyric
pub func encodeMessage(fields: List[ProtoField]): slice[Byte]
```

| Parameter | Description |
|---|---|
| `fields` | List of `ProtoField` union values to encode |

**Returns**: Protobuf wire-format bytes.

### ProtoField union

A discriminated union representing a single encoded field. Construct using the convenience helpers below, or directly via union cases.

```lyric
pub union ProtoField {
  case VarField(number: Int, v: Long)
  case Fix32Field(number: Int, bits: Int)
  case Fix64Field(number: Int, bits: Long)
  case BytesField(number: Int, data: slice[Byte])
}
```

### Field constructors

Convenience helpers for common field types. For varint fields, construct the `VarField` union case directly: `Proto.VarField(number, value)`.

#### `floatField`

Create a 32-bit float field.

```lyric
pub func floatField(number: Int, v: Float): ProtoField
```

#### `doubleField`

Create a 64-bit double field.

```lyric
pub func doubleField(number: Int, v: Double): ProtoField
```

#### `boolField`

Create a boolean field (encoded as varint 0 or 1).

```lyric
pub func boolField(number: Int, v: Bool): ProtoField
```

#### `enumField`

Create an enum field (encoded as varint ordinal).

```lyric
pub func enumField(number: Int, ordinal: Int): ProtoField
```

#### `stringField`

Create a string field (length-delimited bytes).

```lyric
pub func stringField(number: Int, utf8: slice[Byte]): ProtoField
```

#### `embeddedField`

Create an embedded message field (length-delimited bytes).

```lyric
pub func embeddedField(number: Int, inner: slice[Byte]): ProtoField
```

#### `sint32Field`

Create a signed 32-bit integer field (zigzag-encoded varint).

```lyric
pub func sint32Field(number: Int, v: Int): ProtoField
```

#### `sint64Field`

Create a signed 64-bit integer field (zigzag-encoded varint).

```lyric
pub func sint64Field(number: Int, v: Long): ProtoField
```

### Decoding

#### `decodeMessage`

Decode all fields from protobuf wire-format bytes.

```lyric
pub func decodeMessage(data: in slice[Byte]): Result[List[DecodedField], String]
```

| Parameter | Description |
|---|---|
| `data` | Protobuf wire-format bytes |

**Returns**: A list of decoded fields on success; `Err(message)` on parse error.

#### `decodeStep`

Decode a single field starting at the given offset.

```lyric
pub func decodeStep(data: in slice[Byte], offset: Int): Result[DecodeStep, String]
```

| Parameter | Description |
|---|---|
| `data` | Protobuf wire-format bytes |
| `offset` | Byte offset to start decoding |

**Returns**: `Ok(DecodeStep)` with the decoded field and next offset; `Err(message)` on error.

### DecodedField union

The result of decoding a single field.

```lyric
pub union DecodedField {
  case DecodedVarint(number: Int, v: Long)
  case DecodedFixed32(number: Int, bits: Int)
  case DecodedFixed64(number: Int, bits: Long)
  case DecodedBytes(number: Int, data: slice[Byte])
}
```

### DecodeStep record

A single step in decoding; returned by `decodeStep`.

```lyric
pub record DecodeStep {
  field: DecodedField
  nextOffset: Int
}
```

| Field | Description |
|---|---|
| `field` | The decoded field |
| `nextOffset` | Byte offset to continue decoding from |

## Usage with gRPC and OTLP

This library is commonly used with `lyric-grpc` for payload framing and with OpenTelemetry for OTLP exporting:

```lyric
import Proto
import Std.Core

// Construct a protobuf message from fields
val fields = [
  Proto.varField(1, 42i64),
  Proto.stringField(2, "message".bytes()),
]

val payload = Proto.encodeMessage(fields)

// Send via gRPC or store in OTLP batch
```

## Package layout

```
lyric-proto/
  lyric.toml                package manifest
  README.md                 this file
  src/
    proto_main.l            Proto  (encoding/decoding, buffer management)
    _kernel/
      proto_kernel.l        Proto.Kernel  (extern boundary)
  tests/
    *_tests.l               test modules
```

## See also

- [Protocol Buffers Language Guide](https://developers.google.com/protocol-buffers/docs/proto3) (external reference)
- `lyric-grpc` — gRPC client library using Proto for payloads
- `lyric-otel` — OpenTelemetry integration using Proto for OTLP
- `docs/03-decision-log.md` D067 — design decisions for this library
