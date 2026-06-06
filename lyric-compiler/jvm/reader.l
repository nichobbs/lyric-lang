//! jvm/reader.l — Stage B9: class-file binary reader (round-trip verification).
//!
//! Parses the JVM class-file format (JVMS §4) from a List[Byte] and returns a
//! ClassSummary containing the magic check, major version, constant-pool count,
//! access flags, and method count.  Used for round-trip smoke tests that write a
//! class file (via Jvm.Classfile + Jvm.Lowering) and then read it back to
//! verify structural correctness without needing `javap` or the JVM.
//!
//! Handles: all 18 standard constant-pool entry tags, field skipping (with
//! attribute scanning), and arbitrary interface counts.
//! Limitation: attribute_length is read as the low 16 bits of the u4, which is
//! correct for all class files whose attributes are < 65536 bytes (true for
//! every method Code attribute, since the JVM caps method bytecode at 65535 bytes).
package Jvm.Reader

import Std.Core
import Std.Collections

// Summary extracted from a class-file header.
pub record ClassSummary {
  magicValid: Bool   // true iff bytes 0-3 == 0xCA 0xFE 0xBA 0xBE
  majorVersion: Int    // class-file major version (65 = Java 21)
  poolCount: Int    // constant_pool_count
  accessFlags: Int    // class access_flags
  methodCount: Int    // number of declared methods
}

// Internal: per-pool-entry scan result.
record PoolStep {
  nextPos: Int   // byte offset of the next pool entry
  extraIdx: Int   // 1 for Long/Double (two pool indices), 0 otherwise
}

// Read big-endian u2 at offset (result: 0..=65535, always fits in Int).
pub func readU2(bytes: in List[Byte], offset: in Int): Int {
  bytes[offset].toInt() * 256 + bytes[offset + 1].toInt()
}

// True iff the first four bytes equal 0xCAFEBABE.
func checkMagic(bytes: in List[Byte]): Bool {
  bytes[0] == 0xCA and bytes[1] == 0xFE and bytes[2] == 0xBA and bytes[3] == 0xBE
}

// Advance one constant-pool entry starting at pos.
// Uses if-else rather than match to avoid emitter issues with large integer-
// literal match expressions returning a record value.
func skipPoolEntry(bytes: in List[Byte], pos: in Int): PoolStep {
  val tag = bytes[pos]
  // Start with the most-common case (4-byte data, one index, tags 3/4/9-12/17/18).
  var nextP = pos + 5
  var extra = 0
  if tag == 1 {
    // CONSTANT_Utf8: 2-byte length field + length data bytes.
    val len = readU2(bytes, pos + 1)
    nextP = pos + 3 + len
  } else if tag == 5 {
    // CONSTANT_Long: 8-byte data, consumes TWO pool indices.
    nextP = pos + 9
    extra = 1
  } else if tag == 6 {
    // CONSTANT_Double: same shape as Long.
    nextP = pos + 9
    extra = 1
  } else if tag == 7 {
    nextP = pos + 3   // CONSTANT_Class: 2-byte name_index
  } else if tag == 8 {
    nextP = pos + 3   // CONSTANT_String: 2-byte string_index
  } else if tag == 15 {
    nextP = pos + 4   // CONSTANT_MethodHandle: 3-byte data
  } else if tag == 16 {
    nextP = pos + 3   // CONSTANT_MethodType: 2-byte descriptor_index
  }
  // tags 3,4,9,10,11,12,17,18 and unknown: default nextP = pos + 5.
  PoolStep(nextPos = nextP, extraIdx = extra)
}

// Skip poolCount - 1 pool entries starting at startPos; return the end offset.
pub func skipPool(bytes: in List[Byte], startPos: in Int, poolCount: in Int): Int {
  var pos = startPos
  var idx = 1
  while idx < poolCount {
    val step = skipPoolEntry(bytes, pos)
    pos = step.nextPos
    idx = idx + 1 + step.extraIdx
  }
  pos
}

// Skip one attribute_info.  Reads the low u2 of the u4 attribute_length
// (correct when attribute_length < 65536, which is always true for Code attrs).
func skipAttribute(bytes: in List[Byte], pos: in Int): Int {
  val attrLen = readU2(bytes, pos + 4)
  pos + 6 + attrLen
}

// Skip one field_info including its attributes.
func skipField(bytes: in List[Byte], pos: in Int): Int {
  val attrCount = readU2(bytes, pos + 6)
  var p = pos + 8
  var ai = 0
  while ai < attrCount {
    p = skipAttribute(bytes, p)
    ai = ai + 1
  }
  p
}

// Skip `count` field_info entries starting at pos.
func skipFields(bytes: in List[Byte], pos: in Int, count: in Int): Int {
  var p = pos
  var i = 0
  while i < count {
    p = skipField(bytes, p)
    i = i + 1
  }
  p
}

// Parse the class-file header from bytes and return a ClassSummary.
pub func parseClassSummary(bytes: in List[Byte]): ClassSummary {
  val magicOk = checkMagic(bytes)
  val major = readU2(bytes, 6)
  val poolCount = readU2(bytes, 8)

  val poolEnd = skipPool(bytes, 10, poolCount)

  // After pool: access_flags(2), this_class(2), super_class(2), interfaces_count(2)
  val accessFlags = readU2(bytes, poolEnd)
  val ifaceCount = readU2(bytes, poolEnd + 6)

  val fieldsPos = poolEnd + 8 + ifaceCount * 2
  val fieldsCount = readU2(bytes, fieldsPos)
  val methodsPos = skipFields(bytes, fieldsPos + 2, fieldsCount)
  val methodCount = readU2(bytes, methodsPos)

  ClassSummary(
    magicValid = magicOk,
    majorVersion = major,
    poolCount = poolCount,
    accessFlags = accessFlags,
    methodCount = methodCount
  )
}
