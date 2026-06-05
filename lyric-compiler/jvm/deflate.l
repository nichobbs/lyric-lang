//! jvm/deflate.l — Pure-Lyric DEFLATE (RFC 1951) decompressor.
//!
//! Implements all three DEFLATE block types needed to inflate .class entries
//! from JDK .jmod archives: STORED (00), fixed-Huffman (01), dynamic-Huffman (10).
//! Input: slice[Byte] with an explicit start offset and compressed-byte count.
//! Output: List[Int] with values 0-255 (one entry per decompressed byte).
//!
//! Bit ordering follows RFC 1951 §3.1.1: bits are packed LSB-first within each
//! byte; Huffman code symbols are accumulated MSB-first for table lookup.
//! Back-references (length/distance pairs) copy from the already-emitted output
//! list, which supports the run-length-extension case (distance < length).
//!
//! Bitwise operations are expressed as arithmetic so this file compiles cleanly
//! under both the self-hosted compiler and the F# stage-0 bootstrap emitter
//! (which lacks support for the .and/.or/.shl/.shr method forms on Int).
package Jvm.Deflate

import Std.Core
import Std.Collections

// ── Mutable-map helpers ───────────────────────────────────────────────────────
func getS(m: in Map[String, Int], k: in String): Int {
  match mapGet(m, k) {
    case Some(v) -> v
    case None -> 0
  }
}

func setS(m: in Map[String, Int], k: in String, v: in Int): Unit {
  if m.containsKey(k) {
    m.remove(k)
  }
  m.add(k, v)
}

// ── Arithmetic bit-operation helpers ─────────────────────────────────────────
// 2^n for n in 0..16 (covers all DEFLATE bit-count needs).
func pow2(n: in Int): Int {
  if n == 0 {
    return 1
  }
  if n == 1 {
    return 2
  }
  if n == 2 {
    return 4
  }
  if n == 3 {
    return 8
  }
  if n == 4 {
    return 16
  }
  if n == 5 {
    return 32
  }
  if n == 6 {
    return 64
  }
  if n == 7 {
    return 128
  }
  if n == 8 {
    return 256
  }
  if n == 9 {
    return 512
  }
  if n == 10 {
    return 1024
  }
  if n == 11 {
    return 2048
  }
  if n == 12 {
    return 4096
  }
  if n == 13 {
    return 8192
  }
  if n == 14 {
    return 16384
  }
  if n == 15 {
    return 32768
  }
  if n == 16 {
    return 65536
  }
  1
}

// Convert a (possibly signed) raw byte read to an unsigned 0-255 value.
func toU8(raw: in Int): Int {
  if raw < 0 {
    raw + 256
  } else {
    raw
  }
}

// ── Bit reader ────────────────────────────────────────────────────────────────
// Bit stream reader over a byte slice.
// State keys: "p"=current byte offset, "b"=bit buffer (LSB-first), "n"=bits
// remaining in buffer, "e"=exclusive end offset (startOff + compressedLen).
pub record BitReader {
  data: slice[Byte]
  state: Map[String, Int]
}

pub func newBitReader(data: in slice[Byte], startOff: in Int, compressedLen: in Int): BitReader {
  val st: Map[String, Int] = newMap()
  setS(st, "p", startOff)
  setS(st, "b", 0)
  setS(st, "n", 0)
  setS(st, "e", startOff + compressedLen)
  BitReader(data = data, state = st)
}

// Fill the bit buffer from the next input byte (only called when n == 0).
func refillBits(br: in BitReader): Unit {
  val p = getS(br.state, "p")
  if p < getS(br.state, "e") {
    val by = toU8(br.data[p] * 1)
    setS(br.state, "p", p + 1)
    setS(br.state, "b", by)
    // n was 0, so b was 0; just store new byte
    setS(br.state, "n", 8)
  }
}

// Read one bit (0 or 1) from the stream, LSB first.
pub func readBit(br: in BitReader): Int {
  if getS(br.state, "n") == 0 {
    refillBits(br)
  }
  val b = getS(br.state, "b")
  val bit = b % 2
  // extract LSB
  setS(br.state, "b", b / 2)
  setS(br.state, "n", getS(br.state, "n") - 1)
  bit
}

// Read `count` bits, returning them as an integer (bit 0 = first bit read).
pub func readBits(br: in BitReader, count: in Int): Int {
  var result = 0
  var i = 0
  while i < count {
    result = result + readBit(br) * pow2(i)
    i = i + 1
  }
  result
}

// Discard any unread bits in the current byte, aligning to the next byte boundary.
pub func byteAlign(br: in BitReader): Unit {
  setS(br.state, "b", 0)
  setS(br.state, "n", 0)
}

// Read one full byte from the byte-aligned stream (no bit-buffer involvement).
func readRawByte(br: in BitReader): Int {
  val p = getS(br.state, "p")
  if p >= getS(br.state, "e") {
    return 0
  }
  setS(br.state, "p", p + 1)
  toU8(br.data[p] * 1)
}

// Read a little-endian u16 from the byte-aligned stream.
func readRawU16Le(br: in BitReader): Int {
  val lo = readRawByte(br)
  val hi = readRawByte(br)
  lo + hi * 256
}

// ── Canonical Huffman table ───────────────────────────────────────────────────
// Canonical Huffman code table built from a code-length array.
// Decode algorithm: accumulate bits MSB-first; test against the first canonical
// code of each bit length.  See RFC 1951 §3.2.2.
pub record HuffTable {
  maxLen: Int
  count: Map[String, Int]
  // toString(len) → number of symbols with that length
  firstCode: Map[String, Int]
  // toString(len) → first canonical code at that length
  firstSym: Map[String, Int]
  // toString(len) → index into sortedSyms for this length
  sortedSyms: List[Int]
  // symbols in canonical order (by length, then symbol value)
  // Build a canonical Huffman table from a code-length array.
  // `lengths[i]` is the bit-length for symbol `i`; length 0 means "no code assigned".
}

pub func buildHuffTable(lengths: in List[Int]): HuffTable {
  var maxLen = 0
  var i = 0
  while i < lengths.count {
    if lengths[i] > maxLen {
      maxLen = lengths[i]
    }
    i = i + 1
  }
  if maxLen == 0 {
    return HuffTable(maxLen = 0, count = newMap(), firstCode = newMap(), firstSym = newMap(), sortedSyms = newList())
  }

  val count: Map[String, Int] = newMap()
  val firstCode: Map[String, Int] = newMap()
  val firstSym: Map[String, Int] = newMap()
  val sorted: List[Int] = newList()

  i = 0
  while i < lengths.count {
    val l = lengths[i]
    if l > 0 {
      setS(count, toString(l), getS(count, toString(l)) + 1)
    }
    i = i + 1
  }

  // Compute first canonical code for each length (RFC 1951 §3.2.2).
  // code = (code + bl_count[bits-1]) << 1; bl_count[0] = 0.
  var code = 0
  var prevCnt = 0
  var l = 1
  while l <= maxLen {
    code = (code + prevCnt) * 2
    setS(firstCode, toString(l), code)
    prevCnt = getS(count, toString(l))
    l = l + 1
  }

  // Build sortedSyms: symbols grouped by length (ascending), then by symbol value.
  l = 1
  while l <= maxLen {
    setS(firstSym, toString(l), sorted.count)
    i = 0
    while i < lengths.count {
      if lengths[i] == l {
        sorted.add(i)
      }
      i = i + 1
    }
    l = l + 1
  }

  HuffTable(maxLen = maxLen, count = count, firstCode = firstCode, firstSym = firstSym, sortedSyms = sorted)
}

// Build a HuffTable from a Map[String, Int] acting as an indexed lengths array.
// Symbols are 0..maxSym inclusive; missing map entries default to length 0.
pub func buildHuffTableFromMap(m: in Map[String, Int], maxSym: in Int): HuffTable {
  val lengths: List[Int] = newList()
  var i = 0
  while i <= maxSym {
    lengths.add(getS(m, toString(i)))
    i = i + 1
  }
  buildHuffTable(lengths)
}

// Decode one symbol from the stream using `table`.  Returns -1 on error.
pub func huffDecode(table: in HuffTable, br: in BitReader): Int {
  if table.maxLen == 0 {
    return -1
  }
  var code = 0
  var l = 1
  while l <= table.maxLen {
    code = code * 2 + readBit(br)
    val k = toString(l)
    val fc = getS(table.firstCode, k)
    val ct = getS(table.count, k)
    if ct > 0 and code >= fc and code < fc + ct {
      val fs = getS(table.firstSym, k)
      return table.sortedSyms[fs + (code - fc)]
    }
    l = l + 1
  }
  -1
}

// ── Fixed Huffman tables (RFC 1951 §3.2.6) ────────────────────────────────────
pub func makeFixedLitLenTable(): HuffTable {
  val lengths: List[Int] = newList()
  var i = 0
  while i < 288 {
    if i <= 143 {
      lengths.add(8)
    } else if i <= 255 {
      lengths.add(9)
    } else if i <= 279 {
      lengths.add(7)
    } else {
      lengths.add(8)
    }
    i = i + 1
  }
  buildHuffTable(lengths)
}

pub func makeFixedDistTable(): HuffTable {
  val lengths: List[Int] = newList()
  var i = 0
  while i < 32 {
    lengths.add(5)
    i = i + 1
  }
  buildHuffTable(lengths)
}

// ── Length/distance extra-bit tables (RFC 1951 §3.2.5) ───────────────────────
func lengthExtraBits(code: in Int): Int {
  if code <= 264 {
    return 0
  }
  if code <= 268 {
    return 1
  }
  if code <= 272 {
    return 2
  }
  if code <= 276 {
    return 3
  }
  if code <= 280 {
    return 4
  }
  if code <= 284 {
    return 5
  }
  0
}

func lengthBase(code: in Int): Int {
  if code == 257 {
    return 3
  }
  if code == 258 {
    return 4
  }
  if code == 259 {
    return 5
  }
  if code == 260 {
    return 6
  }
  if code == 261 {
    return 7
  }
  if code == 262 {
    return 8
  }
  if code == 263 {
    return 9
  }
  if code == 264 {
    return 10
  }
  if code == 265 {
    return 11
  }
  if code == 266 {
    return 13
  }
  if code == 267 {
    return 15
  }
  if code == 268 {
    return 17
  }
  if code == 269 {
    return 19
  }
  if code == 270 {
    return 23
  }
  if code == 271 {
    return 27
  }
  if code == 272 {
    return 31
  }
  if code == 273 {
    return 35
  }
  if code == 274 {
    return 43
  }
  if code == 275 {
    return 51
  }
  if code == 276 {
    return 59
  }
  if code == 277 {
    return 67
  }
  if code == 278 {
    return 83
  }
  if code == 279 {
    return 99
  }
  if code == 280 {
    return 115
  }
  if code == 281 {
    return 131
  }
  if code == 282 {
    return 163
  }
  if code == 283 {
    return 195
  }
  if code == 284 {
    return 227
  }
  258
}

func distExtraBits(code: in Int): Int {
  if code <= 3 {
    return 0
  }
  val sub = code - 2
  sub / 2
}

func distBase(code: in Int): Int {
  if code == 0 {
    return 1
  }
  if code == 1 {
    return 2
  }
  if code == 2 {
    return 3
  }
  if code == 3 {
    return 4
  }
  if code == 4 {
    return 5
  }
  if code == 5 {
    return 7
  }
  if code == 6 {
    return 9
  }
  if code == 7 {
    return 13
  }
  if code == 8 {
    return 17
  }
  if code == 9 {
    return 25
  }
  if code == 10 {
    return 33
  }
  if code == 11 {
    return 49
  }
  if code == 12 {
    return 65
  }
  if code == 13 {
    return 97
  }
  if code == 14 {
    return 129
  }
  if code == 15 {
    return 193
  }
  if code == 16 {
    return 257
  }
  if code == 17 {
    return 385
  }
  if code == 18 {
    return 513
  }
  if code == 19 {
    return 769
  }
  if code == 20 {
    return 1025
  }
  if code == 21 {
    return 1537
  }
  if code == 22 {
    return 2049
  }
  if code == 23 {
    return 3073
  }
  if code == 24 {
    return 4097
  }
  if code == 25 {
    return 6145
  }
  if code == 26 {
    return 8193
  }
  if code == 27 {
    return 12289
  }
  if code == 28 {
    return 16385
  }
  24577
}

// ── Block decoders ────────────────────────────────────────────────────────────
// Decode a Huffman-compressed literal/length/distance stream, appending to `buf`.
func decodeBlock(br: in BitReader, litlenTab: in HuffTable, distTab: in HuffTable, buf: in List[Int]): Unit {
  var done = false
  while not done {
    val sym = huffDecode(litlenTab, br)
    if sym < 0 {
      done = true
    } else if sym < 256 {
      buf.add(sym)
    } else if sym == 256 {
      done = true
    } else {
      val extraLen = lengthExtraBits(sym)
      val length = lengthBase(sym) + readBits(br, extraLen)
      val distSym = huffDecode(distTab, br)
      if distSym < 0 {
        done = true
      } else {
        val extraDist = distExtraBits(distSym)
        val distance = distBase(distSym) + readBits(br, extraDist)
        val startPos = buf.count - distance
        var ci = 0
        // Copy overlapping correctly: read buf[startPos+ci] which grows with appends.
        while ci < length {
          buf.add(buf[startPos + ci])
          ci = ci + 1
        }
      }
    }
  }
}

// STORED (uncompressed) block.
func inflateStored(br: in BitReader, buf: in List[Int]): Unit {
  byteAlign(br)
  val len = readRawU16Le(br)
  val nlen = readRawU16Le(br)
  // one's complement of len; not validated
  var i = 0
  while i < len {
    buf.add(readRawByte(br))
    i = i + 1
  }
}

// Fixed-Huffman block (RFC 1951 §3.2.6).
func inflateFixed(br: in BitReader, buf: in List[Int]): Unit {
  decodeBlock(br, makeFixedLitLenTable(), makeFixedDistTable(), buf)
}

// CLC alphabet ordering (RFC 1951 §3.2.7).
func clcOrder(i: in Int): Int {
  if i == 0 {
    return 16
  }
  if i == 1 {
    return 17
  }
  if i == 2 {
    return 18
  }
  if i == 3 {
    return 0
  }
  if i == 4 {
    return 8
  }
  if i == 5 {
    return 7
  }
  if i == 6 {
    return 9
  }
  if i == 7 {
    return 6
  }
  if i == 8 {
    return 10
  }
  if i == 9 {
    return 5
  }
  if i == 10 {
    return 11
  }
  if i == 11 {
    return 4
  }
  if i == 12 {
    return 12
  }
  if i == 13 {
    return 3
  }
  if i == 14 {
    return 13
  }
  if i == 15 {
    return 2
  }
  if i == 16 {
    return 14
  }
  if i == 17 {
    return 1
  }
  15
}

// Dynamic-Huffman block (RFC 1951 §3.2.7).
func inflateDynamic(br: in BitReader, buf: in List[Int]): Unit {
  val hlit = readBits(br, 5) + 257
  val hdist = readBits(br, 5) + 1
  val hclen = readBits(br, 4) + 4

  // Read code-length code lengths (CLC).  Symbols 0-18; unset → 0.
  val clcMap: Map[String, Int] = newMap()
  var i = 0
  while i < hclen {
    setS(clcMap, toString(clcOrder(i)), readBits(br, 3))
    i = i + 1
  }
  val clcTab = buildHuffTableFromMap(clcMap, 18)

  // Decode all hlit + hdist code lengths using the CLC Huffman table.
  val allMap: Map[String, Int] = newMap()
  var j = 0
  val total = hlit + hdist
  while j < total {
    val sym = huffDecode(clcTab, br)
    if sym >= 0 and sym <= 15 {
      setS(allMap, toString(j), sym)
      j = j + 1
    } else if sym == 16 {
      val prev = getS(allMap, toString(j - 1))
      val rep = readBits(br, 2) + 3
      var k = 0
      while k < rep {
        setS(allMap, toString(j), prev)
        j = j + 1
        k = k + 1
      }
    } else if sym == 17 {
      val rep = readBits(br, 3) + 3
      var k = 0
      while k < rep {
        setS(allMap, toString(j), 0)
        j = j + 1
        k = k + 1
      }
    } else if sym == 18 {
      val rep = readBits(br, 7) + 11
      var k = 0
      while k < rep {
        setS(allMap, toString(j), 0)
        j = j + 1
        k = k + 1
      }
    } else {
      j = total
      // invalid symbol: stop early
    }
  }

  val litlenTab = buildHuffTableFromMap(allMap, hlit - 1)

  val distMap: Map[String, Int] = newMap()
  var di = 0
  while di < hdist {
    setS(distMap, toString(di), getS(allMap, toString(hlit + di)))
    di = di + 1
  }
  val distTab = buildHuffTableFromMap(distMap, hdist - 1)

  decodeBlock(br, litlenTab, distTab, buf)
}

// ── Public entry point ────────────────────────────────────────────────────────
/// Decompress DEFLATE-compressed data at `data[startOff .. startOff + compressedLen)`.
/// Returns the decompressed bytes as a `List[Int]` with values 0-255.
pub func inflate(data: in slice[Byte], startOff: in Int, compressedLen: in Int): List[Int] {
  val buf: List[Int] = newList()
  val br = newBitReader(data, startOff, compressedLen)
  var done = false
  while not done {
    val bfinal = readBit(br)
    val btype = readBits(br, 2)
    if btype == 0 {
      inflateStored(br, buf)
    } else if btype == 1 {
      inflateFixed(br, buf)
    } else if btype == 2 {
      inflateDynamic(br, buf)
    }
    if bfinal == 1 or btype == 3 {
      done = true
    }
  }
  buf
}
