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

// Create a buffer to accumulate encoded bytes
val buffer = Proto.createBuffer()

// Encode field 1 (varint) with value 42
buffer = Proto.encodeVarint(buffer, fieldNumber = 1, wireType = 0, value = 42)

// Encode field 2 (string) with value "hello"
buffer = Proto.encodeString(buffer, fieldNumber = 2, wireType = 2, value = "hello")

// Get the encoded bytes
val encoded = Proto.bufferBytes(buffer)
```

### Decoding a message

```lyric
import Proto
import Std.Core

val encoded = ...  // slice[Byte] from wire

// Create a decoder
val decoder = Proto.createDecoder(encoded)

// Read fields
match Proto.decodeVarint(decoder) {
  case Ok((fieldNumber, value)) -> {
    // Decoded field fieldNumber with value
  }
  case Err(e) -> {
    // Decode error
  }
}
```

## Wire format essentials

### Varint encoding

Protocol Buffers encode unsigned integers as varints (variable-length little-endian integers). Each byte encodes 7 bits of data plus a continuation bit.

```lyric
// Encode a 64-bit unsigned integer
val encoded = Proto.encodeVarint(buffer, fieldNumber, wireType, value)

// Decode a varint
match Proto.decodeVarint(decoder) {
  case Ok((fieldNumber, value)) -> // value is 0..=0xFFFFFFFFFFFFFFFF
  case Err(e)                   -> // Decode error
}
```

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

### Buffer operations

#### `createBuffer`

Create a new empty buffer for encoding.

```lyric
pub func createBuffer(): ProtoBuffer
```

#### `bufferBytes`

Extract the encoded bytes from a buffer.

```lyric
pub func bufferBytes(buffer: in ProtoBuffer): slice[Byte]
```

### Encoding

#### `encodeVarint`

Encode a 64-bit unsigned integer as a varint.

```lyric
pub func encodeVarint(
  buffer: in ProtoBuffer,
  fieldNumber: in Long,
  wireType: in Int,
  value: in Long
): ProtoBuffer
```

#### `encodeString`

Encode a length-delimited string.

```lyric
pub func encodeString(
  buffer: in ProtoBuffer,
  fieldNumber: in Long,
  wireType: in Int,
  value: in String
): ProtoBuffer
```

#### `encodeBytes`

Encode a length-delimited byte slice.

```lyric
pub func encodeBytes(
  buffer: in ProtoBuffer,
  fieldNumber: in Long,
  wireType: in Int,
  value: in slice[Byte]
): ProtoBuffer
```

#### `encodeFloat`

Encode a 32-bit float.

```lyric
pub func encodeFloat(
  buffer: in ProtoBuffer,
  fieldNumber: in Long,
  wireType: in Int,
  value: in Float
): ProtoBuffer
```

#### `encodeDouble`

Encode a 64-bit double.

```lyric
pub func encodeDouble(
  buffer: in ProtoBuffer,
  fieldNumber: in Long,
  wireType: in Int,
  value: in Double
): ProtoBuffer
```

### Decoding

#### `createDecoder`

Create a new decoder from encoded bytes.

```lyric
pub func createDecoder(bytes: in slice[Byte]): ProtoDecoder
```

#### `decodeVarint`

Decode a varint and return the field number and value.

```lyric
pub func decodeVarint(decoder: in ProtoDecoder): Result[(Long, Long), ProtoError]
```

#### `decodeString`

Decode a length-delimited string.

```lyric
pub func decodeString(decoder: in ProtoDecoder): Result[(Long, String), ProtoError]
```

#### `decodeBytes`

Decode a length-delimited byte slice.

```lyric
pub func decodeBytes(decoder: in ProtoDecoder): Result[(Long, slice[Byte]), ProtoError]
```

#### `decodeFloat`

Decode a 32-bit float.

```lyric
pub func decodeFloat(decoder: in ProtoDecoder): Result[(Long, Float), ProtoError]
```

#### `decodeDouble`

Decode a 64-bit double.

```lyric
pub func decodeDouble(decoder: in ProtoDecoder): Result[(Long, Double), ProtoError]
```

## Usage with gRPC and OTLP

This library is commonly used with `lyric-grpc` for payload framing and with OpenTelemetry for OTLP exporting:

```lyric
import Proto
import Std.Core

// Construct a protobuf message manually
val buf = Proto.createBuffer()
buf = Proto.encodeVarint(buf, 1, 0, 42)          // field 1: varint
buf = Proto.encodeString(buf, 2, 2, "message")   // field 2: string

// Send via gRPC or store in OTLP batch
val payload = Proto.bufferBytes(buf)
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
