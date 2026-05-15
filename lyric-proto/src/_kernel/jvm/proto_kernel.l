/// JVM kernel boundary for lyric-proto (Phase 6).
///
/// Mirrors Proto.Kernel.Net using java.io.ByteArrayOutputStream for the
/// ProtoBuffer accumulator and java.lang.Float / java.lang.Double for the
/// IEEE 754 bit-extraction helpers.
///
/// Not compiled today — present to drive API parity with the .NET kernel.
@cfg(feature = "jvm")
package Proto.Kernel.Jvm

// ─── ProtoBuffer ─────────────────────────────────────────────────────────────

pub extern type ProtoBuffer = "java.io.ByteArrayOutputStream"

@axiom("java.io.ByteArrayOutputStream and java.lang.Float/Double conform to their JVM contracts")
extern package java.proto {
  pub func newProtoBuffer(): ProtoBuffer
  pub func bufWriteByte(buf: ProtoBuffer, b: in Int): Unit
  pub func bufWriteBytes(buf: ProtoBuffer, data: in slice[Byte]): Unit
  pub func bufWriteSlice(buf: ProtoBuffer, data: in slice[Byte], offset: in Int, count: in Int): Unit
  pub func bufToBytes(buf: ProtoBuffer): slice[Byte]
  pub func bufLength(buf: ProtoBuffer): Int
}

// ─── IEEE 754 bit extraction ─────────────────────────────────────────────────

@axiom("java.lang.Float.floatToRawIntBits and java.lang.Double.doubleToRawLongBits conform to their JVM contracts")
extern package java.proto.bits {
  pub func floatToInt32Bits(v: in Float): Int
  pub func doubleToInt64Bits(v: in Float): Long
}

// ─── Raw byte access for the decoder ─────────────────────────────────────────

@axiom("JVM byte indexing is bounds-safe; callers must check length")
extern package java.proto.decode {
  pub func byteAt(data: in slice[Byte], offset: in Int): Int
  pub func int32LE(data: in slice[Byte], offset: in Int): Int
  pub func int64LE(data: in slice[Byte], offset: in Int): Long
  pub func sliceCopy(data: in slice[Byte], offset: in Int, length: in Int): slice[Byte]
}
