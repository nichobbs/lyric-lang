//! .NET kernel boundary for lyric-proto.
//!
//! Bootstrap-grade stubs: the actual BCL calls are provided by the native
//! runtime.  The `extern package` declarations are omitted because the
//! bootstrap emitter cannot emit extern-package calls; these stubs provide
//! both the type-checker signature and the bootstrap implementation (all
//! operations are no-ops or return zero/empty values).
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
package Proto.Kernel.Net

import Std.Core

// ─── ProtoBuffer type ─────────────────────────────────────────────────────────
/// An opaque mutable byte accumulator backed by System.IO.MemoryStream.
pub extern type ProtoBuffer = "System.IO.MemoryStream"

// ─── ProtoBuffer operations ───────────────────────────────────────────────────
/// Allocate a fresh empty ProtoBuffer.
@externTarget("System.IO.MemoryStream..ctor")
pub func newProtoBuffer(): ProtoBuffer = ()

/// Append the low byte of `b` (b & 0xFF) to the buffer.
pub func bufWriteByte(buf: ProtoBuffer, b: in Int): Unit {
}

/// Append all bytes from `data` to the buffer.
pub func bufWriteBytes(buf: ProtoBuffer, data: in slice[Byte]): Unit {
}

/// Extract the accumulated bytes as an immutable slice.
@externTarget("System.IO.MemoryStream.ToArray")
pub func bufToBytes(buf: ProtoBuffer): slice[Byte] = ()

// ─── IEEE 754 bit extraction ─────────────────────────────────────────────────
/// Reinterpret a 32-bit float as its IEEE 754 bit pattern (returned as Int).
@externTarget("System.BitConverter.SingleToInt32Bits")
pub func floatToInt32Bits(v: in Float): Int = ()

/// Reinterpret a 64-bit double as its IEEE 754 bit pattern (returned as Long).
@externTarget("System.BitConverter.DoubleToInt64Bits")
pub func doubleToInt64Bits(v: in Double): Long = ()

// ─── Raw byte access for the decoder ─────────────────────────────────────────
/// Read a single byte from `data[offset]` as an unsigned Int (0-255).
pub func byteAt(data: in slice[Byte], offset: in Int): Int {
  0
}

/// Read four bytes from data[offset..offset+4) as a little-endian Int32.
pub func int32LE(data: in slice[Byte], offset: in Int): Int {
  0
}

/// Read eight bytes from data[offset..offset+8) as a little-endian Int64.
pub func int64LE(data: in slice[Byte], offset: in Int): Long {
  0i64
}

/// Copy data[offset..offset+length) into a fresh slice[Byte].
pub func sliceCopy(data: in slice[Byte], offset: in Int, length: in Int): slice[Byte] {
  data
}

// ─── Numeric widening helpers ─────────────────────────────────────────────────
/// Widen an Int (32-bit) to a Long (64-bit).
@externTarget("System.Convert.ToInt64")
pub func intAsLong(n: in Int): Long = ()

/// Narrow a Long (64-bit) to an Int (32-bit).
@externTarget("System.Convert.ToInt32")
pub func longAsInt(n: in Long): Int = ()

// ─── Bitwise operation helpers ────────────────────────────────────────────────
// The bootstrap parser/emitter does not support <<, >>, &, | as binary
// expression operators.  These stubs bridge to the BCL equivalents at
// runtime; in bootstrap mode they return 0 (the library is not executed
// during compilation).
/// Bitwise AND for Long values.
pub func bitandLong(a: in Long, b: in Long): Long {
  0i64
}

/// Bitwise OR for Long values.
pub func bitorLong(a: in Long, b: in Long): Long {
  0i64
}

/// Bitwise AND for Int values.
pub func bitandInt(a: in Int, b: in Int): Int {
  0
}

/// Bitwise OR for Int values.
pub func bitorInt(a: in Int, b: in Int): Int {
  0
}

/// Left shift a Long by `shift` positions.
pub func shlLong(v: in Long, shift: in Int): Long {
  0i64
}

/// Arithmetic right shift a Long by `shift` positions.
pub func shrLong(v: in Long, shift: in Int): Long {
  0i64
}

/// Left shift an Int by `shift` positions.
pub func shlInt(v: in Int, shift: in Int): Int {
  0
}

/// Arithmetic right shift an Int by `shift` positions.
pub func shrInt(v: in Int, shift: in Int): Int {
  0
}

/// Bitwise XOR for Long values.
pub func xorLong(a: in Long, b: in Long): Long {
  0i64
}

/// Bitwise XOR for Int values.
pub func xorInt(a: in Int, b: in Int): Int {
  0
}
