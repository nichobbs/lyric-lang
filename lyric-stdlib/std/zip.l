//! std/zip.l - Zip archives and raw DEFLATE (RFC 1951), in pure Lyric.
//!
//! Reads and writes the zip subset plugin artifacts travel in (D248 Decision
//! 9): stored and deflate entries, no encryption, no ZIP64, no multi-disk
//! archives. Everything that would need one of those is refused with
//! `Unsupported`, never misread.
//!
//! The reader treats its input as hostile. Every offset and length is
//! checked against the data before it is used, a central directory entry
//! must agree with its local header, entry names must be valid text and
//! unique, and `readZipEntry` inflates into a bounded buffer and checks the
//! declared size and CRC-32. `ZipLimits` caps the entry count, each entry's
//! size, the total size and the compression ratio, so a zip bomb fails with
//! `LimitExceeded` before it is expanded.
//!
//! The writer emits deterministic archives: a fixed timestamp (1980-01-01),
//! entries in the order given, Unix file modes (0644, or 0755 for an
//! executable entry) and no extra fields. Each entry is deflated (LZ77 with
//! fixed Huffman codes) and stored instead when that is not smaller.
@runtime_checked
@pure
package Std.Zip

import Std.Core
import Std.Collections
import Std.Encoding

/// Why an archive or a DEFLATE stream could not be read.
@experimental
pub union ZipError {
  /// The data is not a well-formed zip archive or DEFLATE stream.
  case Malformed(reason: String)
  /// The archive uses a feature this module does not read (ZIP64,
  /// encryption, a compression method other than stored or deflate).
  case Unsupported(reason: String)
  /// An entry or the archive exceeds a `ZipLimits` bound.
  case LimitExceeded(reason: String)
  /// An entry's contents do not match its declared CRC-32 or size.
  case CorruptEntry(name: String, reason: String)
}

/// A one-line description of a zip error.
@experimental
pub func zipErrorMessage(e: in ZipError): String {
  match e {
    case Malformed(reason) -> "malformed zip: " + reason
    case Unsupported(reason) -> "unsupported zip: " + reason
    case LimitExceeded(reason) -> "zip limit exceeded: " + reason
    case CorruptEntry(name, reason) -> "corrupt zip entry '" + name + "': " + reason
  }
}

/// Bounds on what a reader accepts. The defaults suit plugin artifacts.
@experimental
pub record ZipLimits {
  maxEntries: Int = 10000
  maxEntrySize: Long = 536870912i64
  maxTotalSize: Long = 1073741824i64
  /// The largest allowed ratio of an entry's size to its compressed size.
  maxRatio: Long = 1000i64
}

/// The default limits.
@experimental
pub func defaultZipLimits(): ZipLimits {
  ZipLimits(maxEntries = 10000, maxEntrySize = 536870912i64, maxTotalSize = 1073741824i64, maxRatio = 1000i64)
}

/// One entry of an archive's central directory.
@experimental
pub record ZipEntryInfo {
  name: String
  /// 0 for stored, 8 for deflate.
  method: Int
  compressedSize: Long
  size: Long
  crc32: Long
  /// The entry's name ends in `/`, or its Unix mode says directory.
  isDirectory: Bool
  /// The entry's Unix mode says symbolic link.
  isSymlink: Bool
  /// The entry's Unix mode has an executable bit set.
  isExecutable: Bool
  /// Where the entry's local header starts in the data the directory was
  /// read from.
  localHeaderOffset: Long
}

/// A file to write into an archive.
@experimental
pub record ZipFile {
  name: String
  data: slice[Byte]
  executable: Bool = false
}

// ---- CRC-32 -----------------------------------------------------------------
func crcTable(): List[Long] {
  val table: List[Long] = newList()
  var n = 0
  while n < 256 {
    var c = n.toLong()
    var k = 0
    while k < 8 {
      if c.and(1i64) == 1i64 {
        c = 0xEDB88320i64.xor(c.shr(1))
      } else {
        c = c.shr(1)
      }
      k = k + 1
    }
    table.add(c)
    n = n + 1
  }
  table
}

/// The CRC-32 (ISO 3309, as zip and gzip use it) of `bytes`, as a value in
/// 0..2^32-1.
@experimental
pub func crc32(bytes: in slice[Byte]): Long {
  val table = crcTable()
  var c = 0xFFFFFFFFi64
  var i = 0
  while i < bytes.length {
    val index = c.xor(bytes[i].toLong()).and(255i64).toInt()
    c = table[index].xor(c.shr(8))
    i = i + 1
  }
  c.xor(0xFFFFFFFFi64).and(0xFFFFFFFFi64)
}

// ---- Inflate (RFC 1951) -----------------------------------------------------
// Input bit stream, least significant bit first. `err` is set (and stays
// set) when the stream ends early; readers check it after each symbol.
ref record BitIn {
  data: slice[Byte]
  limit: Int
  var pos: Int
  var bitBuf: Int
  var bitCnt: Int
  var err: String
}

func readBits(s: in BitIn, need: in Int): Int {
  var buf = s.bitBuf
  while s.bitCnt < need {
    if s.pos >= s.limit {
      if s.err.length == 0 {
        s.err = "the DEFLATE stream ends early"
      }
      return 0
    }
    buf = buf.or(s.data[s.pos].toInt().shl(s.bitCnt))
    s.pos = s.pos + 1
    s.bitCnt = s.bitCnt + 8
  }
  s.bitBuf = buf.shr(need)
  s.bitCnt = s.bitCnt - need
  buf.and(1.shl(need) - 1)
}

// A canonical Huffman code as per-length counts and symbols in code order.
record Huffman {
  count: List[Int]
  symbol: List[Int]
}

func zeros(n: in Int): List[Int] {
  val xs: List[Int] = newList()
  var i = 0
  while i < n {
    xs.add(0)
    i = i + 1
  }
  xs
}

// Builds the code for `lengths[0..n)`. Returns the number of unused codes:
// 0 for a complete code, negative for an over-subscribed one, positive for
// an incomplete one.
func buildHuffman(h: in Huffman, lengths: in List[Int], n: in Int): Int {
  var len = 0
  while len <= 15 {
    h.count[len] = 0
    len = len + 1
  }
  var sym = 0
  while sym < n {
    h.count[lengths[sym]] = h.count[lengths[sym]] + 1
    sym = sym + 1
  }
  if h.count[0] == n {
    return 0
  }
  var left = 1
  len = 1
  while len <= 15 {
    left = left * 2
    left = left - h.count[len]
    if left < 0 {
      return left
    }
    len = len + 1
  }
  val offs = zeros(16)
  len = 1
  while len < 15 {
    offs[len + 1] = offs[len] + h.count[len]
    len = len + 1
  }
  sym = 0
  while sym < n {
    if lengths[sym] != 0 {
      h.symbol[offs[lengths[sym]]] = sym
      offs[lengths[sym]] = offs[lengths[sym]] + 1
    }
    sym = sym + 1
  }
  left
}

// Decodes one symbol; -1 for a code that is not in the table.
func decodeSymbol(s: in BitIn, h: in Huffman): Int {
  var code = 0
  var first = 0
  var index = 0
  var len = 1
  while len <= 15 {
    code = code.or(readBits(s, 1))
    val count = h.count[len]
    if code - count < first {
      return h.symbol[index + (code - first)]
    }
    index = index + count
    first = first + count
    first = first * 2
    code = code * 2
    len = len + 1
  }
  -1
}

func lengthBase(): slice[Int] {
  [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
}

func lengthExtra(): slice[Int] {
  [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
}

func distBase(): slice[Int] {
  [
    1,
    2,
    3,
    4,
    5,
    7,
    9,
    13,
    17,
    25,
    33,
    49,
    65,
    97,
    129,
    193,
    257,
    385,
    513,
    769,
    1025,
    1537,
    2049,
    3073,
    4097,
    6145,
    8193,
    12289,
    16385,
    24577
  ]
}

func distExtra(): slice[Int] {
  [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
}

// Decodes one compressed block's symbols into `dst`.
func inflateCodes(
  s: in BitIn, lencode: in Huffman, distcode: in Huffman, dst: in List[Byte], maxOut: in Int
): Option[ZipError] {
  val lbase = lengthBase()
  val lext = lengthExtra()
  val dbase = distBase()
  val dext = distExtra()
  while true {
    val sym = decodeSymbol(s, lencode)
    if s.err.length > 0 {
      return Some(value = Malformed(reason = s.err))
    }
    if sym < 0 {
      return Some(value = Malformed(reason = "an invalid literal/length code"))
    }
    if sym < 256 {
      if dst.count >= maxOut {
        return Some(value = LimitExceeded(reason = "the data inflates to more than " + maxOut.toString() + " bytes"))
      }
      dst.add(sym.toByte())
    } else if sym == 256 {
      return None
    } else {
      val li = sym - 257
      if li >= 29 {
        return Some(value = Malformed(reason = "an invalid length symbol"))
      }
      val len = lbase[li] + readBits(s, lext[li])
      val dsym = decodeSymbol(s, distcode)
      if dsym < 0 or dsym >= 30 {
        return Some(value = Malformed(reason = "an invalid distance code"))
      }
      val dist = dbase[dsym] + readBits(s, dext[dsym])
      if s.err.length > 0 {
        return Some(value = Malformed(reason = s.err))
      }
      if dist > dst.count {
        return Some(value = Malformed(reason = "a distance reaches before the start of the data"))
      }
      if dst.count + len > maxOut {
        return Some(value = LimitExceeded(reason = "the data inflates to more than " + maxOut.toString() + " bytes"))
      }
      var k = 0
      val from = dst.count - dist
      while k < len {
        dst.add(dst[from + k])
        k = k + 1
      }
    }
  }
  None
}

func fixedTables(lencode: in Huffman, distcode: in Huffman): Unit {
  val lengths = zeros(288)
  var sym = 0
  while sym < 288 {
    lengths[sym] = if sym < 144 { 8 } else if sym < 256 { 9 } else if sym < 280 { 7 } else { 8 }
    sym = sym + 1
  }
  val _ = buildHuffman(lencode, lengths, 288)
  val dl = zeros(30)
  sym = 0
  while sym < 30 {
    dl[sym] = 5
    sym = sym + 1
  }
  val _ = buildHuffman(distcode, dl, 30)
}

func newHuffman(symbols: in Int): Huffman = Huffman(count = zeros(16), symbol = zeros(symbols))

func dynamicTables(s: in BitIn, lencode: in Huffman, distcode: in Huffman): Option[ZipError] {
  val nlen = readBits(s, 5) + 257
  val ndist = readBits(s, 5) + 1
  val ncode = readBits(s, 4) + 4
  if s.err.length > 0 {
    return Some(value = Malformed(reason = s.err))
  }
  if nlen > 286 or ndist > 30 {
    return Some(value = Malformed(reason = "too many length or distance codes"))
  }
  val order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
  val lengths = zeros(320)
  var index = 0
  while index < ncode {
    lengths[order[index]] = readBits(s, 3)
    index = index + 1
  }
  val lencodeCodes = newHuffman(19)
  if buildHuffman(lencodeCodes, lengths, 19) != 0 {
    return Some(value = Malformed(reason = "an incomplete code-length code"))
  }
  index = 0
  while index < nlen + ndist {
    var sym = decodeSymbol(s, lencodeCodes)
    if s.err.length > 0 {
      return Some(value = Malformed(reason = s.err))
    }
    if sym < 0 {
      return Some(value = Malformed(reason = "an invalid code-length code"))
    }
    if sym < 16 {
      lengths[index] = sym
      index = index + 1
    } else {
      var len = 0
      var times = 0
      if sym == 16 {
        if index == 0 {
          return Some(value = Malformed(reason = "a repeat with no previous length"))
        }
        len = lengths[index - 1]
        times = 3 + readBits(s, 2)
      } else if sym == 17 {
        times = 3 + readBits(s, 3)
      } else {
        times = 11 + readBits(s, 7)
      }
      if index + times > nlen + ndist {
        return Some(value = Malformed(reason = "code lengths run past the end"))
      }
      while times > 0 {
        lengths[index] = len
        index = index + 1
        times = times - 1
      }
    }
  }
  if lengths[256] == 0 {
    return Some(value = Malformed(reason = "no end-of-block code"))
  }
  val litLeft = buildHuffman(lencode, lengths, nlen)
  if litLeft < 0 or (litLeft > 0 and nlen - lencode.count[0] != 1) {
    return Some(value = Malformed(reason = "an over-subscribed or incomplete literal/length code"))
  }
  val distLengths = zeros(30)
  var d = 0
  while d < ndist {
    distLengths[d] = lengths[nlen + d]
    d = d + 1
  }
  val distLeft = buildHuffman(distcode, distLengths, ndist)
  if distLeft < 0 or (distLeft > 0 and ndist - distcode.count[0] != 1) {
    return Some(value = Malformed(reason = "an over-subscribed or incomplete distance code"))
  }
  None
}

/// Inflates the raw DEFLATE stream in `data[start, start + length)`,
/// refusing to produce more than `maxOutput` bytes.
@experimental
pub func inflateRange(
  data: in slice[Byte], start: in Int, length: in Int, maxOutput: in Int
): Result[slice[Byte], ZipError]
  requires: start >= 0 and length >= 0 and start + length <= data.length and maxOutput >= 0
{
  val s = BitIn(data = data, limit = start + length, pos = start, bitBuf = 0, bitCnt = 0, err = "")
  val dst: List[Byte] = newList()
  var last = 0
  while last == 0 {
    last = readBits(s, 1)
    val kind = readBits(s, 2)
    if s.err.length > 0 {
      return Err(error = Malformed(reason = s.err))
    }
    if kind == 0 {
      // A stored block: align to a byte, then LEN and its complement.
      s.bitBuf = 0
      s.bitCnt = 0
      if s.pos + 4 > s.limit {
        return Err(error = Malformed(reason = "a stored block header runs past the end"))
      }
      val len = data[s.pos].toInt() + data[s.pos + 1].toInt() * 256
      val nlen = data[s.pos + 2].toInt() + data[s.pos + 3].toInt() * 256
      if len != 65535 - nlen {
        return Err(error = Malformed(reason = "a stored block length does not match its complement"))
      }
      s.pos = s.pos + 4
      if s.pos + len > s.limit {
        return Err(error = Malformed(reason = "a stored block runs past the end"))
      }
      if dst.count + len > maxOutput {
        return Err(error = LimitExceeded(reason = "the data inflates to more than " + maxOutput.toString() + " bytes"))
      }
      var k = 0
      while k < len {
        dst.add(data[s.pos + k])
        k = k + 1
      }
      s.pos = s.pos + len
    } else if kind == 1 {
      val lencode = newHuffman(288)
      val distcode = newHuffman(30)
      fixedTables(lencode, distcode)
      match inflateCodes(s, lencode, distcode, dst, maxOutput) {
        case Some(e) -> return Err(error = e)
        case None -> ()
      }
    } else if kind == 2 {
      val lencode = newHuffman(288)
      val distcode = newHuffman(30)
      match dynamicTables(s, lencode, distcode) {
        case Some(e) -> return Err(error = e)
        case None -> ()
      }
      match inflateCodes(s, lencode, distcode, dst, maxOutput) {
        case Some(e) -> return Err(error = e)
        case None -> ()
      }
    } else {
      return Err(error = Malformed(reason = "an invalid block type"))
    }
  }
  Ok(value = dst.toArray())
}

/// Inflates a whole raw DEFLATE stream, refusing to produce more than
/// `maxOutput` bytes.
@experimental
pub func inflate(data: in slice[Byte], maxOutput: in Int): Result[slice[Byte], ZipError]
  requires: maxOutput >= 0
{
  inflateRange(data, 0, data.length, maxOutput)
}

// ---- Deflate ----------------------------------------------------------------
// Output bit stream, least significant bit first.
ref record BitOut {
  bytes: List[Byte]
  var bitBuf: Int
  var bitCnt: Int
}

func putBits(o: in BitOut, value: in Int, count: in Int): Unit {
  o.bitBuf = o.bitBuf.or(value.shl(o.bitCnt))
  o.bitCnt = o.bitCnt + count
  while o.bitCnt >= 8 {
    o.bytes.add(o.bitBuf.and(255).toByte())
    o.bitBuf = o.bitBuf.shr(8)
    o.bitCnt = o.bitCnt - 8
  }
}

func flushBits(o: in BitOut): Unit {
  if o.bitCnt > 0 {
    o.bytes.add(o.bitBuf.and(255).toByte())
    o.bitBuf = 0
    o.bitCnt = 0
  }
}

// `code`'s low `len` bits, most significant first, as a Huffman code goes
// into the least-significant-first bit stream.
func putCode(o: in BitOut, code: in Int, len: in Int): Unit {
  var rev = 0
  var c = code
  var i = 0
  while i < len {
    rev = rev * 2 + c.and(1)
    c = c.shr(1)
    i = i + 1
  }
  putBits(o, rev, len)
}

func putLiteral(o: in BitOut, sym: in Int): Unit {
  if sym < 144 {
    putCode(o, 48 + sym, 8)
  } else if sym < 256 {
    putCode(o, 400 + sym - 144, 9)
  } else if sym < 280 {
    putCode(o, sym - 256, 7)
  } else {
    putCode(o, 192 + sym - 280, 8)
  }
}

func putMatch(o: in BitOut, len: in Int, dist: in Int): Unit {
  val lbase = lengthBase()
  val lext = lengthExtra()
  var li = 28
  while lbase[li] > len {
    li = li - 1
  }
  putLiteral(o, 257 + li)
  if lext[li] > 0 {
    putBits(o, len - lbase[li], lext[li])
  }
  val dbase = distBase()
  val dext = distExtra()
  var di = 29
  while dbase[di] > dist {
    di = di - 1
  }
  putCode(o, di, 5)
  if dext[di] > 0 {
    putBits(o, dist - dbase[di], dext[di])
  }
}

func storedDeflate(data: in slice[Byte]): slice[Byte] {
  val acc: List[Byte] = newList()
  var pos = 0
  while true {
    val n = if data.length - pos > 65535 { 65535 } else { data.length - pos }
    val last = pos + n >= data.length
    acc.add((if last { 1 } else { 0 }).toByte())
    acc.add(n.and(255).toByte())
    acc.add(n.shr(8).toByte())
    acc.add((65535 - n).and(255).toByte())
    acc.add((65535 - n).shr(8).toByte())
    var k = 0
    while k < n {
      acc.add(data[pos + k])
      k = k + 1
    }
    pos = pos + n
    if last {
      return acc.toArray()
    }
  }
  acc.toArray()
}

/// `data` as a raw DEFLATE stream: LZ77 matches (a 32 KiB window, greedy,
/// a bounded hash chain) in one fixed-Huffman block, or stored blocks when
/// that is not smaller.
@experimental
pub func deflate(data: in slice[Byte]): slice[Byte] {
  val n = data.length
  val o = BitOut(bytes = newList(), bitBuf = 0, bitCnt = 0)
  putBits(o, 1, 1)
  putBits(o, 1, 2)
  val hashSize = 32768
  val head: List[Int] = newList()
  var i = 0
  while i < hashSize {
    head.add(-1)
    i = i + 1
  }
  val prev = zeros(32768)
  var pos = 0
  while pos < n {
    var bestLen = 0
    var bestDist = 0
    if pos + 2 < n {
      val h = (data[pos].toInt() * 1024 + data[pos + 1].toInt() * 32 + data[pos + 2].toInt()).and(hashSize - 1)
      var cand = head[h]
      var chain = 0
      while cand >= 0 and chain < 32 and pos - cand <= 32768 {
        var len = 0
        val maxLen = if n - pos < 258 { n - pos } else { 258 }
        while len < maxLen and data[cand + len] == data[pos + len] {
          len = len + 1
        }
        if len > bestLen {
          bestLen = len
          bestDist = pos - cand
          if len == maxLen {
            chain = 32
          }
        }
        val next = prev[cand.and(32767)]
        cand = if next < cand { next } else { -1 }
        chain = chain + 1
      }
      prev[pos.and(32767)] = head[h]
      head[h] = pos
    }
    if bestLen >= 3 {
      putMatch(o, bestLen, bestDist)
      // Index the positions the match covers, so later data can refer to them.
      var k = 1
      while k < bestLen {
        val p = pos + k
        if p + 2 < n {
          val h2 = (data[p].toInt() * 1024 + data[p + 1].toInt() * 32 + data[p + 2].toInt()).and(hashSize - 1)
          prev[p.and(32767)] = head[h2]
          head[h2] = p
        }
        k = k + 1
      }
      pos = pos + bestLen
    } else {
      putLiteral(o, data[pos].toInt())
      pos = pos + 1
    }
  }
  putLiteral(o, 256)
  flushBits(o)
  if o.bytes.count >= n + 5 * (n / 65535 + 1) {
    storedDeflate(data)
  } else {
    o.bytes.toArray()
  }
}

// ---- Archives ---------------------------------------------------------------
func u16(data: in slice[Byte], at: in Int): Int = data[at].toInt() + data[at + 1].toInt() * 256

func u32(data: in slice[Byte], at: in Int): Long {
  data[at].toLong() + data[at + 1].toLong() * 256i64 + data[at + 2].toLong() * 65536i64 +
    data[at + 3].toLong() * 16777216i64
}

func putU16(acc: in List[Byte], v: in Int): Unit {
  acc.add(v.and(255).toByte())
  acc.add(v.shr(8).and(255).toByte())
}

func putU32(acc: in List[Byte], v: in Long): Unit {
  acc.add(v.and(255i64).toByte())
  acc.add(v.shr(8).and(255i64).toByte())
  acc.add(v.shr(16).and(255i64).toByte())
  acc.add(v.shr(24).and(255i64).toByte())
}

// The end-of-central-directory record's offset, searching back over at most
// the largest comment.
func findEndRecord(data: in slice[Byte]): Option[Int] {
  if data.length < 22 {
    return None
  }
  var at = data.length - 22
  val lowest = if data.length - 22 - 65535 > 0 { data.length - 22 - 65535 } else { 0 }
  while at >= lowest {
    if data[at].toInt() == 0x50 and data[at + 1].toInt() == 0x4b and data[at + 2].toInt() == 5 and data[at + 3].toInt() == 6 and at + 22 + u16(data, at + 20) == data.length {
      return Some(value = at)
    }
    at = at - 1
  }
  None
}

/// The entries of an archive's central directory, checked against `limits`
/// and against their local headers.
@experimental
pub func readZipDirectory(data: in slice[Byte], limits: in ZipLimits): Result[List[ZipEntryInfo], ZipError] {
  readDirectory(data, limits, false)
}

/// `readZipDirectory` for an archive that follows a prefix, such as a JDK
/// `.jmod` (a 4-byte header before the zip) or a self-extracting archive.
/// The prefix's length is where the central directory ends up, less where
/// the end record says it starts. Each entry's `localHeaderOffset` is an
/// offset into `data`, so `readZipEntry` reads it as usual.
@experimental
pub func readPrefixedZipDirectory(data: in slice[Byte], limits: in ZipLimits): Result[List[ZipEntryInfo], ZipError] {
  readDirectory(data, limits, true)
}

func readDirectory(
  data: in slice[Byte], limits: in ZipLimits, allowPrefix: in Bool
): Result[List[ZipEntryInfo], ZipError] {
  val eocd = match findEndRecord(data) {
    case Some(at) -> at
    case None -> return Err(error = Malformed(reason = "no end-of-central-directory record"))
  }
  val diskNumber = u16(data, eocd + 4)
  val cdDisk = u16(data, eocd + 6)
  val entriesHere = u16(data, eocd + 8)
  val totalEntries = u16(data, eocd + 10)
  val cdSize = u32(data, eocd + 12)
  val cdOffset = u32(data, eocd + 16)
  if totalEntries == 65535 or cdSize == 0xFFFFFFFFi64 or cdOffset == 0xFFFFFFFFi64 {
    return Err(error = Unsupported(reason = "ZIP64 archives are not read"))
  }
  if diskNumber != 0 or cdDisk != 0 or entriesHere != totalEntries {
    return Err(error = Unsupported(reason = "multi-disk archives are not read"))
  }
  if totalEntries > limits.maxEntries {
    return Err(
      error = LimitExceeded(
        reason = totalEntries.toString() + " entries (the limit is " + limits.maxEntries.toString() + ")"
      )
    )
  }
  if cdOffset + cdSize > eocd.toLong() {
    return Err(error = Malformed(reason = "the central directory overlaps its end record"))
  }
  // The bytes before the archive proper: the directory ends where its end
  // record starts, so its recorded offset falls short by the prefix length
  // (never negative, by the check above).
  val base = if allowPrefix { eocd.toLong() - cdSize - cdOffset } else { 0i64 }
  val entries: List[ZipEntryInfo] = newList()
  val seen: Map[String, Bool] = newMap()
  var at = (base + cdOffset).toInt()
  val cdEnd = (base + cdOffset + cdSize).toInt()
  var total = 0i64
  var i = 0
  while i < totalEntries {
    if at + 46 > cdEnd {
      return Err(error = Malformed(reason = "the central directory is truncated"))
    }
    if u32(data, at) != 0x02014b50i64 {
      return Err(error = Malformed(reason = "a central directory entry has a bad signature"))
    }
    val madeBy = u16(data, at + 4)
    val flags = u16(data, at + 8)
    val method = u16(data, at + 10)
    val crc = u32(data, at + 16)
    val csize = u32(data, at + 20)
    val usize = u32(data, at + 24)
    val nameLen = u16(data, at + 28)
    val extraLen = u16(data, at + 30)
    val commentLen = u16(data, at + 32)
    val external = u32(data, at + 38)
    val localOffset = u32(data, at + 42)
    if at + 46 + nameLen + extraLen + commentLen > cdEnd {
      return Err(error = Malformed(reason = "a central directory entry runs past the directory"))
    }
    if csize == 0xFFFFFFFFi64 or usize == 0xFFFFFFFFi64 or localOffset == 0xFFFFFFFFi64 {
      return Err(error = Unsupported(reason = "ZIP64 entries are not read"))
    }
    if flags.and(1) != 0 or flags.and(64) != 0 {
      return Err(error = Unsupported(reason = "encrypted entries are not read"))
    }
    if method != 0 and method != 8 {
      return Err(error = Unsupported(reason = "compression method " + method.toString() + " is not read"))
    }
    val name = match tryDecodeUtf8(data.slice(at + 46, at + 46 + nameLen)) {
      case Some(s) -> s
      case None -> return Err(error = Malformed(reason = "an entry name is not valid UTF-8"))
    }
    if name.length == 0 {
      return Err(error = Malformed(reason = "an entry has an empty name"))
    }
    if seen.containsKey(name) {
      return Err(error = Malformed(reason = "the entry '" + name + "' appears twice"))
    }
    seen.add(name, true)
    // A Unix "made by" host keeps the file mode in the high 16 bits.
    val unixMode = if madeBy.shr(8) == 3 { external.shr(16).and(65535i64) } else { 0i64 }
    val fileType = unixMode.and(0xF000i64)
    val isDir = name.endsWith("/") or fileType == 0x4000i64
    val isLink = fileType == 0xA000i64
    val isExec = unixMode.and(0x49i64) != 0i64
    if method == 0 and csize != usize {
      return Err(error = Malformed(reason = "the stored entry '" + name + "' has different sizes"))
    }
    if usize > limits.maxEntrySize {
      return Err(error = LimitExceeded(reason = "the entry '" + name + "' is " + usize.toString() + " bytes"))
    }
    val floor = if csize > 0i64 { csize } else { 1i64 }
    if usize > floor * limits.maxRatio {
      return Err(
        error = LimitExceeded(
          reason = "the entry '" + name + "' compresses more than " + limits.maxRatio.toString() + " to 1"
        )
      )
    }
    total = total + usize
    if total > limits.maxTotalSize {
      return Err(
        error = LimitExceeded(
          reason = "the entries add up to more than " + limits.maxTotalSize.toString() + " bytes"
        )
      )
    }
    // The local header must exist, carry the same name, and leave room for
    // the data.
    val lo = (base + localOffset).toInt()
    if localOffset + 30i64 > cdOffset {
      return Err(error = Malformed(reason = "the entry '" + name + "' has a local header outside the data"))
    }
    if u32(data, lo) != 0x04034b50i64 {
      return Err(error = Malformed(reason = "the entry '" + name + "' has a bad local header signature"))
    }
    val localNameLen = u16(data, lo + 26)
    val localExtraLen = u16(data, lo + 28)
    if localNameLen != nameLen {
      return Err(error = Malformed(reason = "the entry '" + name + "' has a different name in its local header"))
    }
    var k = 0
    while k < nameLen {
      if data[lo + 30 + k] != data[at + 46 + k] {
        return Err(error = Malformed(reason = "the entry '" + name + "' has a different name in its local header"))
      }
      k = k + 1
    }
    if localOffset + 30i64 + localNameLen.toLong() + localExtraLen.toLong() + csize > cdOffset {
      return Err(error = Malformed(reason = "the entry '" + name + "' runs past the data"))
    }
    entries.add(
      ZipEntryInfo(
        name = name,
        method = method,
        compressedSize = csize,
        size = usize,
        crc32 = crc,
        isDirectory = isDir,
        isSymlink = isLink,
        isExecutable = isExec,
        localHeaderOffset = base + localOffset
      )
    )
    at = at + 46 + nameLen + extraLen + commentLen
    i = i + 1
  }
  Ok(value = entries)
}

/// The contents of `entry` (from `readZipDirectory(data, ...)`), inflated if
/// need be, with its size and CRC-32 checked.
@experimental
pub func readZipEntry(data: in slice[Byte], entry: in ZipEntryInfo): Result[slice[Byte], ZipError] {
  val lo = entry.localHeaderOffset.toInt()
  if lo + 30 > data.length {
    return Err(error = Malformed(reason = "the entry '" + entry.name + "' has a local header outside the data"))
  }
  val start = lo + 30 + u16(data, lo + 26) + u16(data, lo + 28)
  val csize = entry.compressedSize.toInt()
  if start + csize > data.length {
    return Err(error = Malformed(reason = "the entry '" + entry.name + "' runs past the data"))
  }
  val bytes = if entry.method == 0 {
    data.slice(start, start + csize)
  } else {
    match inflateRange(data, start, csize, entry.size.toInt()) {
      case Ok(b) -> b
      case Err(e) -> return Err(error = e)
    }
  }
  if bytes.length.toLong() != entry.size {
    return Err(
      error = CorruptEntry(
        name = entry.name,
        reason = "its size is " + bytes.length.toString() + ", not " + entry.size.toString()
      )
    )
  }
  if crc32(bytes) != entry.crc32 {
    return Err(error = CorruptEntry(name = entry.name, reason = "its CRC-32 does not match"))
  }
  Ok(value = bytes)
}

/// An archive holding `files`, in order. Names are written as given and
/// must be unique; directory entries are not written.
@experimental
pub func writeZip(files: in List[ZipFile]): slice[Byte] {
  val acc: List[Byte] = newList()
  val central: List[Byte] = newList()
  // 1980-01-01 00:00:00 in DOS date and time.
  val dosTime = 0
  val dosDate = 33
  for f in files {
    val nameBytes = encodeUtf8(f.name)
    val crc = crc32(f.data)
    val deflated = deflate(f.data)
    val useDeflate = deflated.length < f.data.length
    val payload = if useDeflate { deflated } else { f.data }
    val method = if useDeflate { 8 } else { 0 }
    val offset = acc.count.toLong()
    putU32(acc, 0x04034b50i64)
    putU16(acc, 20)
    putU16(acc, 2048)
    putU16(acc, method)
    putU16(acc, dosTime)
    putU16(acc, dosDate)
    putU32(acc, crc)
    putU32(acc, payload.length.toLong())
    putU32(acc, f.data.length.toLong())
    putU16(acc, nameBytes.length)
    putU16(acc, 0)
    for b in nameBytes {
      acc.add(b)
    }
    for b in payload {
      acc.add(b)
    }
    val mode = if f.executable { 0x81EDi64 } else { 0x81A4i64 }
    putU32(central, 0x02014b50i64)
    putU16(central, 3 * 256 + 20)
    putU16(central, 20)
    putU16(central, 2048)
    putU16(central, method)
    putU16(central, dosTime)
    putU16(central, dosDate)
    putU32(central, crc)
    putU32(central, payload.length.toLong())
    putU32(central, f.data.length.toLong())
    putU16(central, nameBytes.length)
    putU16(central, 0)
    putU16(central, 0)
    putU16(central, 0)
    putU16(central, 0)
    putU32(central, mode * 65536i64)
    putU32(central, offset)
    for b in nameBytes {
      central.add(b)
    }
  }
  val cdOffset = acc.count.toLong()
  for b in central {
    acc.add(b)
  }
  putU32(acc, 0x06054b50i64)
  putU16(acc, 0)
  putU16(acc, 0)
  putU16(acc, files.count)
  putU16(acc, files.count)
  putU32(acc, central.count.toLong())
  putU32(acc, cdOffset)
  putU16(acc, 0)
  acc.toArray()
}
