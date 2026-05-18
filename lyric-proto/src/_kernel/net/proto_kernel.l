// .NET kernel boundary for lyric-proto.
//
// Provides two families of operations that cannot be expressed in pure Lyric:
//
//   1. IEEE 754 bit extraction (System.BitConverter) for float/double fields.
//      Proto3 float fields carry the 32-bit IEEE 754 bit pattern as a fixed32;
//      double fields carry the 64-bit bit pattern as a fixed64.
//
//   2. ProtoBuffer — an opaque mutable byte-accumulator backed by
//      System.IO.MemoryStream.  The pure Lyric encoder (Proto.Encoding) calls
//      bufWriteByte / bufWriteBytes to append bytes, then bufToBytes to extract
//      the completed message.
//
// Both families are audited at the kernel boundary (D038 Resolution F).
// No .NET types from this file are visible to consumers; Proto.Types provides
// the Lyric-level API.
//
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
package Proto.Kernel.Net

// ─── ProtoBuffer ─────────────────────────────────────────────────────────────

/// An opaque mutable byte accumulator backed by System.IO.MemoryStream.
/// Always created via newProtoBuffer(); never constructed directly.
pub extern type ProtoBuffer = "System.IO.MemoryStream"

@axiom("System.IO.MemoryStream conforms to its documented .NET contract")
extern package System.IO.Proto {
  /// Allocate a fresh empty ProtoBuffer.
  pub func newProtoBuffer(): ProtoBuffer

  /// Append the low byte of `b` (b & 0xFF) to the buffer.
  /// Callers guarantee 0 ≤ b ≤ 255; the kernel truncates unconditionally.
  pub func bufWriteByte(buf: ProtoBuffer, b: in Int): Unit

  /// Append all bytes from `data[0..data.length)` to the buffer.
  pub func bufWriteBytes(buf: ProtoBuffer, data: in slice[Byte]): Unit

  /// Append `count` bytes from `data` starting at `offset`.
  pub func bufWriteSlice(
    buf: ProtoBuffer,
    data: in slice[Byte],
    offset: in Int,
    count: in Int
  ): Unit

  /// Extract the accumulated bytes as an immutable slice.
  /// The buffer may continue to be written after this call.
  pub func bufToBytes(buf: ProtoBuffer): slice[Byte]

  /// Return the number of bytes currently accumulated in the buffer.
  pub func bufLength(buf: ProtoBuffer): Int
}

// ─── IEEE 754 bit extraction ─────────────────────────────────────────────────

@axiom("System.BitConverter conforms to its documented .NET contract")
extern package System.BitConverter.Proto {
  /// Reinterpret a 32-bit float as its IEEE 754 bit pattern (returned as Int).
  /// Used to encode proto3 float fields as Fix32Field.
  pub func floatToInt32Bits(v: in Float): Int

  /// Reinterpret a 64-bit double as its IEEE 754 bit pattern (returned as Long).
  /// Used to encode proto3 double fields as Fix64Field.
  pub func doubleToInt64Bits(v: in Float): Long
}

// ─── Raw byte access for the decoder ─────────────────────────────────────────

@axiom("Byte indexing into slice[Byte] is bounds-safe; callers must check length")
extern package Lyric.Proto.Decode {
  /// Read a single byte from `data[offset]` as an unsigned Int (0–255).
  /// Callers must check offset < data.length before calling.
  pub func byteAt(data: in slice[Byte], offset: in Int): Int

  /// Read four bytes from data[offset..offset+4) as a little-endian Int32.
  pub func int32LE(data: in slice[Byte], offset: in Int): Int

  /// Read eight bytes from data[offset..offset+8) as a little-endian Int64.
  pub func int64LE(data: in slice[Byte], offset: in Int): Long

  /// Copy data[offset..offset+length) into a fresh slice[Byte].
  pub func sliceCopy(data: in slice[Byte], offset: in Int, length: in Int): slice[Byte]
}
