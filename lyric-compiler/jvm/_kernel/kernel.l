//! jvm/_kernel/kernel.l — pure-Lyric JVM class-file byte buffer and constant pool.
//! Replaces Lyric.Jvm.Hosts.JvmByteBuilder / JvmConstantPool / JvmZipHost F# shims.
//!
//! All implementations use only arithmetic operators (+, -, *, /, %) and audited
//! BCL externs (System.BitConverter, System.Convert, System.Single), so this file
//! compiles through the F# stage-0 emitter.  No bitwise operators (shl/shr/xor)
//! are used — CRC32 XOR is implemented via arithmetic (xorByte), and big-endian
//! byte extraction uses floor-division peeling (shr8/shr16/shr24).
//!
//! Internal: only Jvm.* packages should import this.
package Jvm.Kernel

import Std.Core
import Std.Collections
import Std.Char

// ── ByteWriter ────────────────────────────────────────────────────────────────
/// Mutable big-endian byte buffer for JVM class-file construction.
/// Internal storage is List[Int] so arithmetic results (values in [0,255])
/// can be appended without a Byte cast; writerToList converts at the boundary.
pub record ByteWriter {
  data: List[Int]
}

/// Construct a fresh, empty ByteWriter.
pub func writerNew(): ByteWriter {
  ByteWriter(data = newList())
}

// Floor-division right shifts.  Lyric `/` truncates toward zero, which
// gives wrong results for negative values.  Adding the remainder-based
// correction converts truncation to floor division (arithmetic shift).
func shr8(v: in Int): Int {
  val q = v / 256
  val r = v % 256
  if r < 0 {
    q - 1
  } else {
    q
  }
}

func shr16(v: in Int): Int {
  val q = v / 65536
  val r = v % 65536
  if r < 0 {
    q - 1
  } else {
    q
  }
}

func shr24(v: in Int): Int {
  val q = v / 16777216
  val r = v % 16777216
  if r < 0 {
    q - 1
  } else {
    q
  }
}

/// Append the low byte of v (normalised to [0, 255]).
pub func writerByte(w: in ByteWriter, v: in Int): Unit {
  w.data.add(((v % 256) + 256) % 256)
}

/// Append a 2-byte big-endian unsigned integer.
pub func writerU2(w: in ByteWriter, v: in Int): Unit {
  writerByte(w, shr8(v))
  writerByte(w, v)
}

/// Append a 4-byte big-endian unsigned integer.
pub func writerU4(w: in ByteWriter, v: in Int): Unit {
  writerByte(w, shr24(v))
  writerByte(w, shr16(v))
  writerByte(w, shr8(v))
  writerByte(w, v)
}

// Convert.ToByte(int) truncates to [0..255]; used to materialise List[Int]
// internal buffers into the List[Byte] / slice[Byte] surfaces expected by callers.
@externTarget("System.Convert.ToByte")
func intToByte(v: in Int): Byte = ()

// Floor-division right shifts for Long values.  Lyric `/` truncates toward zero;
// the remainder correction converts truncation to floor division (arithmetic shift).
// Used to extract big-endian bytes from a Long without endian-dependent externs.
func lshr8(v: in Long): Long {
  val q = v / 256i64
  val r = v % 256i64
  if r < 0i64 {
    q - 1i64
  } else {
    q
  }
}

func lshr16(v: in Long): Long {
  val q = v / 65536i64
  val r = v % 65536i64
  if r < 0i64 {
    q - 1i64
  } else {
    q
  }
}

func lshr24(v: in Long): Long {
  val q = v / 16777216i64
  val r = v % 16777216i64
  if r < 0i64 {
    q - 1i64
  } else {
    q
  }
}

func lshr32(v: in Long): Long {
  val q = v / 4294967296i64
  val r = v % 4294967296i64
  if r < 0i64 {
    q - 1i64
  } else {
    q
  }
}

func lshr40(v: in Long): Long {
  val q = v / 1099511627776i64
  val r = v % 1099511627776i64
  if r < 0i64 {
    q - 1i64
  } else {
    q
  }
}

func lshr48(v: in Long): Long {
  val q = v / 281474976710656i64
  val r = v % 281474976710656i64
  if r < 0i64 {
    q - 1i64
  } else {
    q
  }
}

func lshr56(v: in Long): Long {
  val q = v / 72057594037927936i64
  val r = v % 72057594037927936i64
  if r < 0i64 {
    q - 1i64
  } else {
    q
  }
}

// MemoryStream externs used by writerToBytes to materialise internal List[Int]
// storage as a slice[Byte] without an intermediate allocation.
extern type MemStream = "System.IO.MemoryStream"

@externTarget("System.IO.MemoryStream..ctor")
func newMemStream(): MemStream = ()

@externTarget("System.IO.Stream.WriteByte")
func memStreamWriteByte(s: in MemStream, b: in Byte): Unit = ()

@externTarget("System.IO.MemoryStream.ToArray")
func memStreamToArray(s: in MemStream): slice[Byte] = ()

/// Append an 8-byte big-endian long (class-file CONSTANT_Long/Double values).
pub func writerU8(w: in ByteWriter, v: in Long): Unit {
  writerByte(w, lshr56(v).toInt())
  writerByte(w, lshr48(v).toInt())
  writerByte(w, lshr40(v).toInt())
  writerByte(w, lshr32(v).toInt())
  writerByte(w, lshr24(v).toInt())
  writerByte(w, lshr16(v).toInt())
  writerByte(w, lshr8(v).toInt())
  writerByte(w, v.toInt())
}

/// Append a JVMS §4.4.7 modified-UTF-8 encoded string (no length prefix).
/// NUL → 0xC0 0x80; supplementary code points as CESU-8 surrogate pairs.
pub func writerModifiedUtf8(w: in ByteWriter, s: in String): Unit {
  var i = 0
  while i < s.length {
    val c = toInt(s[i])
    if c == 0 {
      writerByte(w, 192)
      writerByte(w, 128)
      i = i + 1
    } else if c <= 127 {
      writerByte(w, c)
      i = i + 1
    } else if c <= 2047 {
      writerByte(w, 192 + (c / 64))
      writerByte(w, 128 + (c % 64))
      i = i + 1
    } else if c >= 55296 and c <= 56319 and i + 1 < s.length {
      val low = toInt(s[i + 1])
      if low >= 56320 and low <= 57343 {
        writerByte(w, 224 + (c / 4096))
        writerByte(w, 128 + ((c / 64) % 64))
        writerByte(w, 128 + (c % 64))
        writerByte(w, 224 + (low / 4096))
        writerByte(w, 128 + ((low / 64) % 64))
        writerByte(w, 128 + (low % 64))
        i = i + 2
      } else {
        writerByte(w, 224 + (c / 4096))
        writerByte(w, 128 + ((c / 64) % 64))
        writerByte(w, 128 + (c % 64))
        i = i + 1
      }
    } else {
      writerByte(w, 224 + (c / 4096))
      writerByte(w, 128 + ((c / 64) % 64))
      writerByte(w, 128 + (c % 64))
      i = i + 1
    }
  }
}

/// Return the byte length of s as modified UTF-8.
/// The w parameter is unused; retained for API compatibility with callers
/// that pass an existing writer to avoid allocating a separate object.
pub func modifiedUtf8Length(w: in ByteWriter, s: in String): Int {
  var n = 0
  var i = 0
  while i < s.length {
    val c = toInt(s[i])
    if c == 0 {
      n = n + 2
      i = i + 1
    } else if c <= 127 {
      n = n + 1
      i = i + 1
    } else if c <= 2047 {
      n = n + 2
      i = i + 1
    } else if c >= 55296 and c <= 56319 and i + 1 < s.length {
      val low = toInt(s[i + 1])
      if low >= 56320 and low <= 57343 {
        n = n + 6
        i = i + 2
      } else {
        n = n + 3
        i = i + 1
      }
    } else {
      n = n + 3
      i = i + 1
    }
  }
  n
}

/// Append a raw slice[Byte].
pub func writerBytes(w: in ByteWriter, bs: in slice[Byte]): Unit {
  var i = 0
  while i < bs.length {
    w.data.add(bs[i].toInt())
    i = i + 1
  }
}

/// Append a List[Byte].
pub func writerByteList(w: in ByteWriter, bs: in List[Byte]): Unit {
  var i = 0
  while i < bs.count {
    w.data.add(bs[i].toInt())
    i = i + 1
  }
}

/// Append all bytes from src into w.
pub func writerAppend(w: in ByteWriter, src: in ByteWriter): Unit {
  var i = 0
  while i < src.data.count {
    w.data.add(src.data[i])
    i = i + 1
  }
}

/// Current byte position (number of bytes written so far).
pub func writerPos(w: in ByteWriter): Int {
  w.data.count
}

/// Patch a previously-written u2 at offset with v (big-endian).
pub func writerPatchU2(w: in ByteWriter, offset: in Int, v: in Int): Unit {
  w.data[offset] = ((shr8(v) % 256) + 256) % 256
  w.data[offset + 1] = ((v % 256) + 256) % 256
}

/// Patch a previously-written u4 at offset with v (big-endian).
pub func writerPatchU4(w: in ByteWriter, offset: in Int, v: in Int): Unit {
  w.data[offset] = ((shr24(v) % 256) + 256) % 256
  w.data[offset + 1] = ((shr16(v) % 256) + 256) % 256
  w.data[offset + 2] = ((shr8(v) % 256) + 256) % 256
  w.data[offset + 3] = ((v % 256) + 256) % 256
}

/// Materialise all written bytes as a slice[Byte].
pub func writerToBytes(w: in ByteWriter): slice[Byte] {
  val ms = newMemStream()
  var i = 0
  while i < w.data.count {
    memStreamWriteByte(ms, intToByte(w.data[i]))
    i = i + 1
  }
  memStreamToArray(ms)
}

/// Append a 2-byte little-endian unsigned integer (ZIP local/central headers).
pub func writerU2Le(w: in ByteWriter, v: in Int): Unit {
  writerByte(w, v)
  writerByte(w, shr8(v))
}

/// Append a 4-byte little-endian unsigned integer (ZIP CRC32/sizes).
/// Handles signed int32 values whose bit pattern represents a uint32
/// (e.g. CRC32 values with MSB set): writerByte normalises each byte to [0,255].
pub func writerU4Le(w: in ByteWriter, v: in Int): Unit {
  writerByte(w, v)
  writerByte(w, shr8(v))
  writerByte(w, shr16(v))
  writerByte(w, shr24(v))
}

/// Materialise all written bytes as a List[Byte] (fresh copy).
pub func writerToList(w: in ByteWriter): List[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < w.data.count {
    acc.add(intToByte(w.data[i]))
    i = i + 1
  }
  acc
}

// ── CRC32 (ISO 3309, reflected polynomial 0xEDB88320) ────────────────────────
//
// XOR is unavailable as a primitive in stage-0 F#-compiled Lyric, so it is
// computed arithmetically on individual bytes (values in [0..255]).  Each bit
// position is extracted via division/modulus, XOR'd via addition-modulo-2, and
// accumulated: xorByte(a, b) = a XOR b for a, b in [0..255].
func xorByte(a: in Int, b: in Int): Int {
  ((a / 128) % 2 + (b / 128) % 2) % 2 * 128 + ((a / 64) % 2 + (b / 64) % 2) % 2 * 64 +
    ((a / 32) % 2 + (b / 32) % 2) % 2 * 32 +
    ((a / 16) % 2 + (b / 16) % 2) % 2 * 16 +
    ((a / 8) % 2 + (b / 8) % 2) % 2 * 8 +
    ((a / 4) % 2 + (b / 4) % 2) % 2 * 4 +
    ((a / 2) % 2 + (b / 2) % 2) % 2 * 2 +
    (a % 2 + b % 2) % 2
}

// Four parallel lookup lists (b0..b3) for the reflected CRC32 table.
// b0[i] is the LSB, b3[i] is the MSB of the table entry for input byte i.
// Polynomial 0xEDB88320 in little-endian bytes: (32, 131, 184, 237).
record CrcTable {
  b0: List[Int]
  b1: List[Int]
  b2: List[Int]
  b3: List[Int]
}

func buildCrcTable(): CrcTable {
  val t0: List[Int] = newList()
  val t1: List[Int] = newList()
  val t2: List[Int] = newList()
  val t3: List[Int] = newList()
  var i = 0
  while i < 256 {
    var c0 = i
    var c1 = 0
    var c2 = 0
    var c3 = 0
    var j = 0
    while j < 8 {
      if c0 % 2 != 0 {
        val n3 = c3 / 2
        val n2 = (c3 % 2) * 128 + c2 / 2
        val n1 = (c2 % 2) * 128 + c1 / 2
        val n0 = (c1 % 2) * 128 + c0 / 2
        c0 = xorByte(n0, 32)
        c1 = xorByte(n1, 131)
        c2 = xorByte(n2, 184)
        c3 = xorByte(n3, 237)
      } else {
        val n3 = c3 / 2
        val n2 = (c3 % 2) * 128 + c2 / 2
        val n1 = (c2 % 2) * 128 + c1 / 2
        val n0 = (c1 % 2) * 128 + c0 / 2
        c0 = n0
        c1 = n1
        c2 = n2
        c3 = n3
      }
      j = j + 1
    }
    t0.add(c0)
    t1.add(c1)
    t2.add(c2)
    t3.add(c3)
    i = i + 1
  }
  CrcTable(b0 = t0, b1 = t1, b2 = t2, b3 = t3)
}

// Process-global CRC table; built once at module load.
val crcTable: CrcTable = buildCrcTable()

/// CRC32 (ISO 3309, reflected polynomial) of a List[Byte].
/// Returns the checksum as a signed Int32 (same bit pattern as the uint32 CRC32).
pub func crc32(data: in List[Byte]): Int {
  var b0 = 255
  var b1 = 255
  var b2 = 255
  var b3 = 255
  var i = 0
  while i < data.count {
    val b = data[i].toInt()
    val idx = xorByte(b0, b)
    val nb0 = xorByte(b1, crcTable.b0[idx])
    val nb1 = xorByte(b2, crcTable.b1[idx])
    val nb2 = xorByte(b3, crcTable.b2[idx])
    val nb3 = crcTable.b3[idx]
    b0 = nb0
    b1 = nb1
    b2 = nb2
    b3 = nb3
    i = i + 1
  }
  val f0 = 255 - b0
  val f1 = 255 - b1
  val f2 = 255 - b2
  val f3 = 255 - b3
  if f3 >= 128 {
    (f3 - 256) * 16777216 + f2 * 65536 + f1 * 256 + f0
  } else {
    f3 * 16777216 + f2 * 65536 + f1 * 256 + f0
  }
}

// ── Constant pool ─────────────────────────────────────────────────────────────
/// JVM constant pool (JVMS §4.4).
/// `entries` is a List[List[Int]] of raw pool entry bytes (values in [0,255]);
/// phantom entries (empty lists) mark the second slot consumed by Long and
/// Double constants.  `nextSlot` is the next available 1-based index
/// (= constant_pool_count).
pub record Pool {
  entries: List[List[Int]]
  cache: Map[String, Int]
  var nextSlot: Int = 1
}

/// Construct a fresh, empty constant pool (slot 0 is reserved; first
/// usable slot is 1).
pub func poolNew(): Pool {
  Pool(entries = newList(), cache = newMap(), nextSlot = 1)
}

// Helpers to build and register pool entries.
func poolAdd(pool: in Pool, key: in String, ent: in List[Int]): Int {
  val slot = pool.nextSlot
  pool.entries.add(ent)
  pool.cache.add(key, slot)
  pool.nextSlot = pool.nextSlot + 1
  slot
}

func poolAdd2(pool: in Pool, key: in String, ent: in List[Int]): Int {
  val slot = pool.nextSlot
  pool.entries.add(ent)
  val phantom: List[Int] = newList()
  pool.entries.add(phantom)
  pool.cache.add(key, slot)
  pool.nextSlot = pool.nextSlot + 2
  slot
}

func poolMakeEntry(tag: in Int): List[Int] {
  val e: List[Int] = newList()
  e.add(tag)
  e
}

func poolAppendU2(ent: in List[Int], v: in Int): Unit {
  ent.add(((shr8(v) % 256) + 256) % 256)
  ent.add(((v % 256) + 256) % 256)
}

func poolAppendU4(ent: in List[Int], v: in Int): Unit {
  ent.add(((shr24(v) % 256) + 256) % 256)
  ent.add(((shr16(v) % 256) + 256) % 256)
  ent.add(((shr8(v) % 256) + 256) % 256)
  ent.add(((v % 256) + 256) % 256)
}

func poolAppendU8(ent: in List[Int], v: in Long): Unit {
  ent.add((((lshr56(v) % 256i64) + 256i64) % 256i64).toInt())
  ent.add((((lshr48(v) % 256i64) + 256i64) % 256i64).toInt())
  ent.add((((lshr40(v) % 256i64) + 256i64) % 256i64).toInt())
  ent.add((((lshr32(v) % 256i64) + 256i64) % 256i64).toInt())
  ent.add((((lshr24(v) % 256i64) + 256i64) % 256i64).toInt())
  ent.add((((lshr16(v) % 256i64) + 256i64) % 256i64).toInt())
  ent.add((((lshr8(v) % 256i64) + 256i64) % 256i64).toInt())
  ent.add((((v % 256i64) + 256i64) % 256i64).toInt())
}

/// Intern a JVMS §4.4.7 Utf8 constant.  Returns the 1-based pool index.
/// Idempotent: the same string always yields the same index.
pub func poolUtf8(pool: in Pool, s: in String): Int {
  val key = "1:" + s
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val tmpW = writerNew()
  writerModifiedUtf8(tmpW, s)
  val byteLen = writerPos(tmpW)
  val e: List[Int] = newList()
  e.add(1)
  e.add(((shr8(byteLen) % 256) + 256) % 256)
  e.add(((byteLen % 256) + 256) % 256)
  var k = 0
  while k < tmpW.data.count {
    e.add(tmpW.data[k])
    k = k + 1
  }
  poolAdd(pool, key, e)
}

/// Intern a CONSTANT_Integer (tag 3).
pub func poolInteger(pool: in Pool, v: in Int): Int {
  val key = "3:" + v.toString()
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val e = poolMakeEntry(3)
  poolAppendU4(e, v)
  poolAdd(pool, key, e)
}

// BCL externs for float/double bit pattern extraction.
extern type Single = "System.Single"

@externTarget("System.Convert.ToSingle")
func dblToSingle(v: in Double): Single = ()

@externTarget("System.BitConverter.SingleToInt32Bits")
func singleToInt32Bits(v: in Single): Int = ()

@externTarget("System.BitConverter.DoubleToInt64Bits")
func doubleToInt64Bits(v: in Double): Long = ()

/// Intern a CONSTANT_Float (tag 4).
pub func poolFloat(pool: in Pool, v: in Double): Int {
  val bits = singleToInt32Bits(dblToSingle(v))
  val key = "4:" + bits.toString()
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val e = poolMakeEntry(4)
  poolAppendU4(e, bits)
  poolAdd(pool, key, e)
}

/// Intern a CONSTANT_Long (tag 5); occupies two consecutive pool slots.
pub func poolLong(pool: in Pool, v: in Long): Int {
  val key = "5:" + v.toString()
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val e = poolMakeEntry(5)
  poolAppendU8(e, v)
  poolAdd2(pool, key, e)
}

/// Intern a CONSTANT_Double (tag 6); occupies two consecutive pool slots.
pub func poolDouble(pool: in Pool, v: in Double): Int {
  val bits = doubleToInt64Bits(v)
  val key = "6:" + bits.toString()
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val e = poolMakeEntry(6)
  poolAppendU8(e, bits)
  poolAdd2(pool, key, e)
}

/// Intern a CONSTANT_Class (tag 7).
pub func poolClass(pool: in Pool, name: in String): Int {
  val key = "7:" + name
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val nIdx = poolUtf8(pool, name)
  val e = poolMakeEntry(7)
  poolAppendU2(e, nIdx)
  poolAdd(pool, key, e)
}

/// Intern a CONSTANT_String (tag 8).
pub func poolString(pool: in Pool, s: in String): Int {
  val key = "8:" + s
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val sIdx = poolUtf8(pool, s)
  val e = poolMakeEntry(8)
  poolAppendU2(e, sIdx)
  poolAdd(pool, key, e)
}

/// Intern a CONSTANT_NameAndType (tag 12).
pub func poolNameAndType(pool: in Pool, name: in String, descriptor: in String): Int {
  val key = "12:" + name + ":" + descriptor
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val nIdx = poolUtf8(pool, name)
  val dIdx = poolUtf8(pool, descriptor)
  val e = poolMakeEntry(12)
  poolAppendU2(e, nIdx)
  poolAppendU2(e, dIdx)
  poolAdd(pool, key, e)
}

/// Intern a CONSTANT_Fieldref (tag 9).
pub func poolFieldref(pool: in Pool, className: in String, name: in String, descriptor: in String): Int {
  val key = "9:" + className + "." + name + ":" + descriptor
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val cIdx = poolClass(pool, className)
  val nIdx = poolNameAndType(pool, name, descriptor)
  val e = poolMakeEntry(9)
  poolAppendU2(e, cIdx)
  poolAppendU2(e, nIdx)
  poolAdd(pool, key, e)
}

/// Intern a CONSTANT_Methodref (tag 10).
pub func poolMethodref(pool: in Pool, className: in String, name: in String, descriptor: in String): Int {
  val key = "10:" + className + "." + name + ":" + descriptor
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val cIdx = poolClass(pool, className)
  val nIdx = poolNameAndType(pool, name, descriptor)
  val e = poolMakeEntry(10)
  poolAppendU2(e, cIdx)
  poolAppendU2(e, nIdx)
  poolAdd(pool, key, e)
}

/// Intern a CONSTANT_InterfaceMethodref (tag 11).
pub func poolIfaceMethodref(pool: in Pool, className: in String, name: in String, descriptor: in String): Int {
  val key = "11:" + className + "." + name + ":" + descriptor
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val cIdx = poolClass(pool, className)
  val nIdx = poolNameAndType(pool, name, descriptor)
  val e = poolMakeEntry(11)
  poolAppendU2(e, cIdx)
  poolAppendU2(e, nIdx)
  poolAdd(pool, key, e)
}

/// Intern a CONSTANT_MethodHandle (tag 15).
/// refKind is one of the REF_* constants (1–9; see JVMS §5.4.3.5).
pub func poolMethodHandle(
  pool: in Pool, refKind: in Int, className: in String, name: in String, descriptor: in String
): Int {
  val key = "15:" + refKind.toString() + ":" + className + "." + name + ":" + descriptor
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val refIdx = poolMethodref(pool, className, name, descriptor)
  val e: List[Int] = poolMakeEntry(15)
  e.add(((refKind % 256) + 256) % 256)
  poolAppendU2(e, refIdx)
  poolAdd(pool, key, e)
}

/// Intern a CONSTANT_MethodType (tag 16).
pub func poolMethodType(pool: in Pool, descriptor: in String): Int {
  val key = "16:" + descriptor
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val dIdx = poolUtf8(pool, descriptor)
  val e = poolMakeEntry(16)
  poolAppendU2(e, dIdx)
  poolAdd(pool, key, e)
}

/// Intern a CONSTANT_InvokeDynamic (tag 18).
/// bmIdx is the 0-based index into the BootstrapMethods attribute.
pub func poolInvokeDynamic(pool: in Pool, bmIdx: in Int, name: in String, descriptor: in String): Int {
  val key = "18:" + bmIdx.toString() + ":" + name + ":" + descriptor
  var slot: Int = default()
  if tryGetValue(pool.cache, key, slot) {
    return slot
  }
  val nIdx = poolNameAndType(pool, name, descriptor)
  val e = poolMakeEntry(18)
  poolAppendU2(e, bmIdx)
  poolAppendU2(e, nIdx)
  poolAdd(pool, key, e)
}

/// Write constant_pool_count (u2) followed by all non-phantom entries to writer.
/// Call this after all pool interns are complete.
pub func poolWriteTo(pool: in Pool, writer: in ByteWriter): Unit {
  writerU2(writer, pool.nextSlot)
  var i = 0
  while i < pool.entries.count {
    val ent: List[Int] = pool.entries[i]
    if ent.count > 0 {
      var j = 0
      while j < ent.count {
        writerByte(writer, ent[j])
        j = j + 1
      }
    }
    i = i + 1
  }
}

/// Number of valid pool entries (= nextSlot - 1).
pub func poolCount(pool: in Pool): Int {
  pool.nextSlot - 1
}
