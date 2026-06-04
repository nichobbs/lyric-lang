// jvm/class_reader.l — Java class-file parser for auto-FFI method extraction.
//
// Parses the JVMS §4 class-file format from a List[Int] (bytes 0-255, as
// produced by Jvm.Deflate.inflate / Jvm.ZipReader.extractEntry) and returns
// the public-method surface of the class: names, JVM descriptors, and
// static/instance flags.  Skips non-public classes, interfaces, and enums.
//
// Constant pool tags handled:
//   1  CONSTANT_Utf8       — method names and descriptors
//   7  CONSTANT_Class      — this_class name
//   3,4,5,6,8,9,10,11,12  — skipped but stepped over correctly
//   15,16,17,18,19,20      — skipped
// Long (5) and Double (6) entries occupy two pool slots (JVMS §4.4.5).
//
// Bitwise operations are expressed as arithmetic so this file compiles cleanly
// under both the self-hosted compiler and the F# stage-0 bootstrap emitter
// (which lacks support for the .and/.or/.shl/.shr method forms on Int).

package Jvm.ClassReader

import Std.Core
import Std.Collections
import Std.Char

// ── Big-endian u2/u4 readers ──────────────────────────────────────────────────

// Bytes in List[Int] are already 0-255 (produced by inflate/extractEntry).
func rdU8(b: in List[Int], o: in Int): Int  { b[o] }
func rdU16(b: in List[Int], o: in Int): Int { rdU8(b, o) * 256 + rdU8(b, o + 1) }
func rdU32(b: in List[Int], o: in Int): Int {
  rdU8(b, o) * 16777216 + rdU8(b, o + 1) * 65536 + rdU8(b, o + 2) * 256 + rdU8(b, o + 3)
}

// ── Output types ─────────────────────────────────────────────────────────────

pub record ClassMethod {
  name:       String
  descriptor: String   // JVM method descriptor, e.g. "(II)I"
  isStatic:   Bool
}

pub record ClassInfo {
  binaryName:   String             // JVM binary name, e.g. "java/lang/Math"
  methods:      List[ClassMethod]  // public non-synthetic non-constructor methods
  constructors: List[ClassMethod]  // public <init> constructors (isStatic=false)
}

// ── Constant pool helpers ─────────────────────────────────────────────────────

// Mutable-map state helpers.
func getS(m: in Map[String, Int], k: in String): Int {
  match mapGet(m, k) { case Some(v) -> v; case None -> 0 }
}
func setS(m: in Map[String, Int], k: in String, v: in Int): Unit {
  if m.containsKey(k) { m.remove(k) }
  m.add(k, v)
}
func getSStr(m: in Map[String, String], k: in String): String {
  match mapGet(m, k) { case Some(v) -> v; case None -> "" }
}
func setSStr(m: in Map[String, String], k: in String, v: in String): Unit {
  if m.containsKey(k) { m.remove(k) }
  m.add(k, v)
}

// Read a CONSTANT_Utf8 entry starting at `pos` (after the tag byte).
// Returns (string, nextPos).  Modified UTF-8 is treated as standard UTF-8;
// the difference only matters for null bytes (0xC0 0x80 = U+0000) and
// supplementary-plane characters via the CESU-8 six-byte encoding, neither
// of which appear in class/method names or JVM descriptors.
func readUtf8Entry(b: in List[Int], pos: in Int): String {
  val len = rdU16(b, pos)
  var s = ""
  var i = 0
  while i < len {
    val c0 = rdU8(b, pos + 2 + i)
    if c0 < 128 {
      // 1-byte ASCII
      s = s + ("" + fromInt(c0))
      i = i + 1
    } else if c0 / 32 == 6 and i + 1 < len {
      // 2-byte sequence: first byte 0xC0..0xDF (c0/32 == 6)
      val c1 = rdU8(b, pos + 2 + i + 1)
      val cp = (c0 % 32) * 64 + c1 % 64
      s = s + ("" + fromInt(cp))
      i = i + 2
    } else if c0 / 16 == 14 and i + 2 < len {
      // 3-byte sequence: first byte 0xE0..0xEF (c0/16 == 14)
      val c1 = rdU8(b, pos + 2 + i + 1)
      val c2 = rdU8(b, pos + 2 + i + 2)
      val cp = (c0 % 16) * 4096 + (c1 % 64) * 64 + c2 % 64
      s = s + ("" + fromInt(cp))
      i = i + 3
    } else {
      i = i + 1   // skip invalid/unhandled byte
    }
  }
  s
}

// Return the byte offset after a constant pool entry starting at `pos`
// (pos points at the tag byte).  Also returns whether this entry consumes
// an extra pool slot (Long/Double).
record PoolStep {
  nextPos:  Int
  isDouble: Bool   // true for Long (tag 5) and Double (tag 6): consume two pool slots
}

func poolEntryEnd(b: in List[Int], pos: in Int): PoolStep {
  val tag = rdU8(b, pos)
  if tag == 1 {
    // CONSTANT_Utf8: tag + 2-byte length + length bytes
    PoolStep(nextPos = pos + 3 + rdU16(b, pos + 1), isDouble = false)
  } else if tag == 5 or tag == 6 {
    // Long / Double: 8-byte data, consumes two pool slots
    PoolStep(nextPos = pos + 9, isDouble = true)
  } else if tag == 7 or tag == 8 or tag == 16 or tag == 19 or tag == 20 {
    // 2-byte index
    PoolStep(nextPos = pos + 3, isDouble = false)
  } else if tag == 15 {
    // CONSTANT_MethodHandle: 1-byte kind + 2-byte index
    PoolStep(nextPos = pos + 4, isDouble = false)
  } else {
    // Tags 3,4,9,10,11,12,17,18: 4-byte data
    PoolStep(nextPos = pos + 5, isDouble = false)
  }
}

// ── Class-file parser ─────────────────────────────────────────────────────────

// Access-flag bit positions as powers-of-2 for arithmetic flag tests.
// ACC_PUBLIC    = 0x0001 = 1
// ACC_STATIC    = 0x0008 = 8
// ACC_BRIDGE    = 0x0040 = 64
// ACC_SYNTHETIC = 0x1000 = 4096
// ACC_INTERFACE = 0x0200 = 512
// ACC_ABSTRACT  = 0x0400 = 1024
// ACC_ENUM      = 0x4000 = 16384
// ACC_ANNOTATION= 0x2000 = 8192

/// Parse a Java class file (bytes as List[Int]) and return its public-method
/// surface.  Returns None if the class is non-public, an interface, an enum,
/// an annotation, or the data is too short to be a valid class file.
pub func parseClass(b: in List[Int]): Option[ClassInfo] {
  if b.count < 8 { return None }

  // Magic check: 0xCAFEBABE (checked byte-by-byte to avoid 32-bit overflow)
  if rdU8(b, 0) != 0xCA or rdU8(b, 1) != 0xFE or rdU8(b, 2) != 0xBA or rdU8(b, 3) != 0xBE {
    return None
  }

  // Skip minor_version (2) + major_version (2).
  val cpCount = rdU16(b, 8)   // constant_pool_count (1-based)

  // First pass over the constant pool: store Utf8 strings and Class name indices.
  // Pool indices are 1-based; index 0 is unused.
  val utf8Map:   Map[String, String] = newMap()   // toString(idx) → string
  val classMap:  Map[String, Int]    = newMap()   // toString(idx) → name_index

  var pos  = 10   // byte offset after constant_pool_count
  var idx  = 1
  while idx < cpCount {
    val tag = rdU8(b, pos)
    if tag == 1 {
      setSStr(utf8Map, toString(idx), readUtf8Entry(b, pos + 1))
    } else if tag == 7 {
      setS(classMap, toString(idx), rdU16(b, pos + 1))
    }
    val step = poolEntryEnd(b, pos)
    pos = step.nextPos
    if step.isDouble { idx = idx + 2 } else { idx = idx + 1 }
  }

  // access_flags, this_class, super_class
  if pos + 6 > b.count { return None }
  val accessFlags  = rdU16(b, pos)
  val thisClassIdx = rdU16(b, pos + 2)
  pos = pos + 6   // skip super_class too

  // Skip if not public or if interface/enum/annotation.
  // ACC_PUBLIC=1: accessFlags % 2 == 0 means not public
  if accessFlags % 2 == 0 { return None }
  // ACC_INTERFACE=512: (accessFlags/512) % 2 != 0 means interface
  if (accessFlags / 512) % 2 != 0 { return None }
  // ACC_ENUM=16384: (accessFlags/16384) % 2 != 0 means enum
  if (accessFlags / 16384) % 2 != 0 { return None }
  // ACC_ANNOTATION=8192: (accessFlags/8192) % 2 != 0 means annotation
  if (accessFlags / 8192) % 2 != 0 { return None }

  // Resolve this class's binary name.
  val classNameIdx = getS(classMap, toString(thisClassIdx))
  val binaryName   = getSStr(utf8Map, toString(classNameIdx))

  // Skip interfaces.
  if pos + 2 > b.count { return None }
  val ifaceCount = rdU16(b, pos)
  pos = pos + 2 + ifaceCount * 2

  // Skip fields (each field_info: access(2) + name(2) + desc(2) + attCount(2) + attrs).
  if pos + 2 > b.count { return None }
  val fieldCount = rdU16(b, pos)
  pos = pos + 2
  var fi = 0
  while fi < fieldCount {
    if pos + 8 > b.count { return None }
    val attrCount = rdU16(b, pos + 6)
    pos = pos + 8
    var ai = 0
    while ai < attrCount {
      if pos + 6 > b.count { return None }
      val attrLen = rdU32(b, pos + 2)
      pos = pos + 6 + attrLen
      ai = ai + 1
    }
    fi = fi + 1
  }

  // Parse methods.
  if pos + 2 > b.count { return None }
  val methodCount = rdU16(b, pos)
  pos = pos + 2
  val methods:      List[ClassMethod] = newList()
  val constructors: List[ClassMethod] = newList()

  var mi = 0
  while mi < methodCount {
    if pos + 8 > b.count { return None }
    val mAccess   = rdU16(b, pos)
    val nameIdx   = rdU16(b, pos + 2)
    val descIdx   = rdU16(b, pos + 4)
    val attrCount = rdU16(b, pos + 6)
    pos = pos + 8

    // Skip attributes.
    var ai = 0
    while ai < attrCount {
      if pos + 6 > b.count { return Some(value = ClassInfo(binaryName = binaryName, methods = methods, constructors = constructors)) }
      val attrLen = rdU32(b, pos + 2)
      pos = pos + 6 + attrLen
      ai = ai + 1
    }

    // Keep only public, non-synthetic, non-bridge, non-constructor methods.
    // ACC_PUBLIC=1, ACC_SYNTHETIC=4096, ACC_BRIDGE=64, ACC_STATIC=8
    val isPublic    = mAccess % 2 != 0
    val isSynthetic = (mAccess / 4096) % 2 != 0
    val isBridge    = (mAccess / 64) % 2 != 0
    val isStatic    = (mAccess / 8) % 2 != 0
    if isPublic and not isSynthetic and not isBridge {
      val mName = getSStr(utf8Map, toString(nameIdx))
      val mDesc = getSStr(utf8Map, toString(descIdx))
      if mName == "<init>" {
        constructors.add(ClassMethod(name = "<init>", descriptor = mDesc, isStatic = false))
      } else if mName != "<clinit>" and mName.length > 0 {
        methods.add(ClassMethod(name = mName, descriptor = mDesc, isStatic = isStatic))
      }
    }

    mi = mi + 1
  }

  Some(value = ClassInfo(binaryName = binaryName, methods = methods, constructors = constructors))
}
