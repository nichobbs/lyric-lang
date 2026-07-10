//! deflate_zip_self_test.l — adversarial-input regression tests for the JVM
//! auto-FFI DEFLATE decoder (`Jvm.Deflate`) and ZIP central-directory reader
//! (`Jvm.ZipReader`) hardened in D-progress-639 (#5477, review finding #5489).
//!
//! These readers process genuinely untrusted binary data during a build: every
//! byte of `java.base.jmod` and every entry named in `LYRIC_FFI_JARS` flows
//! through `readZipEntries` → `extractEntry` → `inflate` when the JVM emitter
//! resolves an `extern type` from JDK / third-party class metadata.  A crafted
//! archive must therefore terminate, fail closed, and never index out of
//! bounds — the hardening added EOF (-1) signalling in the bit reader, an
//! output cap, back-reference distance validation, and saturating / Long-math
//! bounds checks throughout the ZIP walk.  The happy path (real JDK jmod
//! decoding) is covered by `auto_ffi_jvm_self_test.l`; this module drives the
//! decoders directly with malformed input, the coverage gap #5489 flagged.
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-compiler/jvm/`) and run on the
//! default `dotnet` target so `lyric test` resolves the `Jvm.Deflate` /
//! `Jvm.ZipReader` imports from the pre-compiled stage-1 bundle DLLs in-process
//! (the same pattern as `jvm_auto_ffi_bridge_self_test.l`).  No
//! `LYRIC_LOAD_COMPILER=1` recompile is needed.  Byte fixtures are built via
//! `List[Byte].toArray()` rather than `Std.Encoding.tryDecodeHex` to avoid
//! matching a stdlib-returned generic `Option` from a self-hosted-compiled
//! `@test_module`.
//!
//! Run via:
//!   lyric test lyric-compiler/lyric/deflate_zip_self_test.l
@test_module
package Lyric.DeflateZipSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Jvm.Deflate
import Jvm.ZipReader

// ── Fixture builders ──────────────────────────────────────────────────────────
// Materialise a List[Int] of 0-255 byte values as a genuine slice[Byte].
func toSlice(vals: in List[Int]): slice[Byte] {
  val l: List[Byte] = newList()
  var i = 0
  while i < vals.count {
    l.add(vals[i])
    i = i + 1
  }
  l.toArray()
}

// Append a value as a little-endian pair / quad, mirroring the ZIP wire format.
func putU16(l: in List[Int], v: in Int): Unit {
  l.add(v % 256)
  l.add((v / 256) % 256)
}

func putU32(l: in List[Int], v: in Int): Unit {
  l.add(v % 256)
  l.add((v / 256) % 256)
  l.add((v / 65536) % 256)
  l.add((v / 16777216) % 256)
}

// ── DEFLATE bit reader: EOF signalling (the anti-hang fix) ────────────────────
test "readBit on an exhausted reader returns -1, not a phantom 0" {
  val empty: List[Int] = newList()
  val br = newBitReader(toSlice(empty), 0, 0)
  assertEqualInt(readBit(br), -1, "empty stream signals EOF")
  assertEqualInt(readBit(br), -1, "still EOF on a second read")
}

test "readBits returns -1 when the stream is exhausted mid-read" {
  val empty: List[Int] = newList()
  val br = newBitReader(toSlice(empty), 0, 0)
  assertEqualInt(readBits(br, 5), -1, "cannot read 5 bits from nothing")
}

test "readBits actually decodes a valid short read (EOF path is not vacuous)" {
  val v: List[Int] = newList()
  v.add(5)   // 0b00000101: bit0=1, bit1=0, bit2=1 -> readBits(3) = 1 + 0*2 + 1*4 = 5
  val br = newBitReader(toSlice(v), 0, 1)
  assertEqualInt(readBits(br, 3), 5, "LSB-first read of 0x05")
}

test "newBitReader clamps a start past end to an immediately-exhausted reader" {
  val v: List[Int] = newList()
  v.add(1)
  v.add(2)
  v.add(3)
  // startOff 100 and compressedLen 10 both exceed a 3-byte buffer; the window
  // clamps to [len, len] instead of driving an out-of-bounds refill.
  val br = newBitReader(toSlice(v), 100, 10)
  assertEqualInt(readBit(br), -1, "clamped reader is exhausted, no OOB read")
}

test "huffDecode on an empty (maxLen 0) table returns -1" {
  val noLengths: List[Int] = newList()
  val table = buildHuffTable(noLengths)
  val v: List[Int] = newList()
  v.add(255)
  val br = newBitReader(toSlice(v), 0, 1)
  assertEqualInt(huffDecode(table, br), -1, "no codes -> decode error, not a spin")
}

// ── inflate: termination on malformed / truncated streams ─────────────────────
test "inflate on empty input terminates with empty output" {
  val empty: List[Int] = newList()
  val res = inflate(toSlice(empty), 0, 0)
  assertEqualInt(res.count, 0, "nothing in, nothing out")
}

test "inflate on garbage (reserved block type) terminates, bounded" {
  val v: List[Int] = newList()
  v.add(255)
  v.add(255)
  v.add(255)
  v.add(255)
  // First bit -> bfinal=1; next two bits -> btype=3 (reserved) -> done.
  val res = inflate(toSlice(v), 0, 4)
  assertEqualInt(res.count, 0, "reserved-type garbage emits nothing and stops")
}

test "inflate on a truncated fixed-Huffman block terminates instead of hanging" {
  val v: List[Int] = newList()
  v.add(2)   // 0b010: bfinal=0, btype=01 (fixed) — opens a block, then runs out
  // Without EOF (-1) signalling the decoder drained the buffer and matched a
  // phantom literal forever; the fix stops at the first -1 from readBit.  The
  // 5 leftover bits after the block header are too few for any fixed-Huffman
  // code (min length 7), so no symbol decodes: exactly 0 bytes out.  The test
  // COMPLETING at all also proves no infinite loop.
  val res = inflate(toSlice(v), 0, 1)
  assertEqualInt(res.count, 0, "truncated fixed block decodes nothing and terminates")
}

test "inflate rejects a back-reference pointing before the output start" {
  val v: List[Int] = newList()
  v.add(139)
  v.add(0)
  v.add(98)
  // Fixed-Huffman: literal 'X' (88), then a length-3 / distance-4 match while
  // only 1 byte of output exists -> startPos = 1 - 4 = -3 < 0.  The distance
  // guard stops the block; the pre-fix code indexed buf[-3] and threw.
  val res = inflate(toSlice(v), 0, 3)
  assertEqualInt(res.count, 1, "only the single literal survives the rejected match")
  assertEqualInt(res[0], 88, "literal 'X' decoded before the bad back-reference")
}

// ── ZIP central directory: malformed-archive handling ─────────────────────────
test "readZipEntries on empty data returns no entries" {
  val empty: List[Int] = newList()
  assertEqualInt(readZipEntries(toSlice(empty)).count, 0, "empty -> no entries")
}

test "readZipEntries on a buffer shorter than an EOCD record returns no entries" {
  val v: List[Int] = newList()
  v.add(0)
  v.add(17)
  v.add(34)
  v.add(51)
  v.add(68)   // 5 bytes < the 22-byte minimum EOCD
  assertEqualInt(readZipEntries(toSlice(v)).count, 0, "too short -> no entries")
}

test "readZipEntries with no EOCD signature returns no entries" {
  val v: List[Int] = newList()
  var i = 0
  while i < 32 {
    v.add(0)   // 32 zero bytes: long enough to scan, but no 0x06054B50 anywhere
    i = i + 1
  }
  assertEqualInt(readZipEntries(toSlice(v)).count, 0, "no EOCD sig -> no entries")
}

// A 22-byte EOCD whose central-directory-size field carries the four given
// bytes (little-endian).  Everything else is a minimal valid EOCD at offset 0.
func eocdWithCdSizeBytes(b0: in Int, b1: in Int, b2: in Int, b3: in Int): slice[Byte] {
  val v: List[Int] = newList()
  v.add(80)
  v.add(75)
  v.add(5)
  v.add(6)          // EOCD signature 0x06054B50
  putU16(v, 0)      // disk number
  putU16(v, 0)      // disk with central directory
  putU16(v, 1)      // entries on this disk
  putU16(v, 1)      // total entries
  v.add(b0)
  v.add(b1)
  v.add(b2)
  v.add(b3)         // cdSize (little-endian)
  putU32(v, 0)      // cd offset
  putU16(v, 0)      // comment length
  toSlice(v)
}

test "readZipEntries with a cdSize larger than the file fails closed (#5486)" {
  // rdU32Le reads the cdSize field; when the top byte (b3) is >= 128 the full
  // u32 exceeds Int32.maxValue, so `low + b3 * 16777216` would overflow the
  // checked Int multiply and panic.  The #5486 guard returns Int.maxValue from
  // a saturation branch instead, and the saturated size drives
  // cdStart = eocd - cdSize negative so the walk bails cleanly.  The clean,
  // panic-free empty return is what only the saturation branch produces — a
  // pre-#5486 build crashes on this exact input.  The bytes are written raw,
  // not via putU32, because putU32 cannot carry a value past Int32 and a top
  // byte >= 128 is precisely what makes rdU32Le take the branch under test.
  //
  // 0xFFFFFFFF (b3 = 255) and 0x80000000 (b3 = 128, the smallest saturating
  // value) both exercise the branch, at the top and the boundary respectively.
  assertEqualInt(
    readZipEntries(eocdWithCdSizeBytes(255, 255, 255, 255)).count,
    0,
    "cdSize 0xFFFFFFFF saturates -> no entries, no panic"
  )
  assertEqualInt(
    readZipEntries(eocdWithCdSizeBytes(0, 0, 0, 128)).count,
    0,
    "cdSize 0x80000000 (b3 == 128 boundary) saturates -> no entries, no panic"
  )
}

test "readZipEntries rejects an out-of-range local-header offset (dataOffset -1)" {
  // A well-formed central directory whose single entry points its local file
  // header far past EOF.  The entry parses, but the lhOffset bounds check
  // leaves dataOffset at -1 rather than reading out of bounds; extractEntry
  // then bails.
  val v: List[Int] = newList()
  v.add(80)
  v.add(75)
  v.add(1)
  v.add(2)          // central-directory entry signature 0x02014B50
  putU16(v, 0)      // version made by
  putU16(v, 0)      // version needed
  putU16(v, 0)      // flags
  putU16(v, 8)      // method = DEFLATE
  putU16(v, 0)      // mod time
  putU16(v, 0)      // mod date
  putU32(v, 0)      // crc32
  putU32(v, 10)     // compressed size
  putU32(v, 20)     // uncompressed size
  putU16(v, 1)      // name length
  putU16(v, 0)      // extra length
  putU16(v, 0)      // comment length
  putU16(v, 0)      // disk number start
  putU16(v, 0)      // internal attrs
  putU32(v, 0)      // external attrs
  putU32(v, 16777215)  // local-header offset (0x00FFFFFF, far past EOF)
  v.add(65)         // name "A"
  val cdSize = v.count
  v.add(80)
  v.add(75)
  v.add(5)
  v.add(6)          // EOCD signature
  putU16(v, 0)      // disk number
  putU16(v, 0)      // disk with central directory
  putU16(v, 1)      // entries on this disk
  putU16(v, 1)      // total entries
  putU32(v, cdSize) // central-directory size
  putU32(v, 0)      // central-directory offset (base shift 0)
  putU16(v, 0)      // comment length
  val data = toSlice(v)
  val entries = readZipEntries(data)
  assertEqualInt(entries.count, 1, "the entry parses")
  val e = entries[0]
  assertEqualInt(e.dataOffset, -1, "out-of-range lhOffset -> dataOffset rejected")
  assertEqualInt(extractEntry(data, e).count, 0, "extractEntry bails on dataOffset -1")
}

// ── extractEntry: bounds on the untrusted size / offset pair ───────────────────
test "extractEntry on a DEFLATE entry with an out-of-range dataOffset returns empty" {
  val small: List[Int] = newList()
  small.add(1)
  small.add(2)
  small.add(3)
  small.add(4)
  val ent = ZipEntry(
    name = "x",
    method = 8,
    compressedSize = 50,
    uncompressedSize = 50,
    dataOffset = 99999,
    hasDataDescriptor = false,
    crc32 = 0
  )
  assertEqualInt(extractEntry(toSlice(small), ent).count, 0, "OOB dataOffset -> empty")
}

test "extractEntry STORED copy is bounded by the real buffer, not the claimed size" {
  val small: List[Int] = newList()
  small.add(10)
  small.add(20)
  small.add(30)
  small.add(40)
  small.add(50)   // 5-byte buffer
  val ent = ZipEntry(
    name = "x",
    method = 0,
    compressedSize = 0,
    uncompressedSize = 1000,
    // lies: claims 1000 bytes
    dataOffset = 2,
    hasDataDescriptor = false,
    crc32 = 0
  )
  // Copy stops when dataOffset + i reaches the buffer length: offsets 2,3,4 -> 3 bytes.
  assertEqualInt(extractEntry(toSlice(small), ent).count, 3, "STORED copy clamped to buffer")
}
