//! inflate.l - Game.Inflate: DEFLATE (RFC 1951) and zlib (RFC 1950) decompression in Lyric
//! (docs/67 G7), for PNG images.  Follows the structure of zlib's `puff`: canonical Huffman codes
//! decoded bit by bit, stored, fixed and dynamic blocks, and the Adler-32 check of the zlib
//! wrapper.  A malformed stream is an `Err` naming the fault, never a panic.
package Game.Inflate

import Std.Core
import Std.Collections
import Std.Buffer as Buf

ref record Inflater {
  data: slice[Byte]
  stop: Int
  limit: Int
  var pos: Int
  var bitBuf: Int
  var bitCnt: Int
  var produced: List[Byte]
  var error: String
}

record Huffman {
  counts: buffer[Int]
  symbols: buffer[Int]
  /// Unused code space: 0 for a complete code, positive when incomplete, negative when
  /// over-subscribed (more codes of a length than the length can hold).
  left: Int
}

func fail(s: Inflater, message: String): Unit {
  if s.error == "" {
    s.error = message
  }
}

func getBits(s: Inflater, need: Int): Int {
  while s.bitCnt < need {
    if s.pos >= s.stop {
      fail(s, "unexpected end of compressed data")
      return 0
    }
    s.bitBuf = s.bitBuf.or(s.data[s.pos].toInt().shl(s.bitCnt))
    s.pos = s.pos + 1
    s.bitCnt = s.bitCnt + 8
  }
  val v = s.bitBuf.and(1.shl(need) - 1)
  s.bitBuf = s.bitBuf.shr(need)
  s.bitCnt = s.bitCnt - need
  v
}

func buildHuffman(lengths: buffer[Int], n: Int): Huffman {
  var counts = Buf.filled(16, 0)
  var i = 0
  while i < n {
    counts[lengths[i]] = counts[lengths[i]] + 1
    i = i + 1
  }
  var offs = Buf.filled(16, 0)
  var len = 1
  while len < 15 {
    offs[len + 1] = offs[len] + counts[len]
    len = len + 1
  }
  var left = 1
  var l = 1
  while l <= 15 {
    left = left.shl(1) - counts[l]
    l = l + 1
  }
  var symbols = Buf.filled(if n > 0 { n } else { 1 }, 0)
  var sym = 0
  while sym < n {
    val l = lengths[sym]
    if l != 0 {
      symbols[offs[l]] = sym
      offs[l] = offs[l] + 1
    }
    sym = sym + 1
  }
  Huffman(counts = counts, symbols = symbols, left = left)
}

func decodeSymbol(s: Inflater, h: Huffman): Int {
  var code = 0
  var first = 0
  var index = 0
  var len = 1
  while len <= 15 {
    code = code.or(getBits(s, 1))
    if s.error != "" {
      return -1
    }
    val count = h.counts[len]
    if code - count < first {
      return h.symbols[index + (code - first)]
    }
    index = index + count
    first = (first + count).shl(1)
    code = code.shl(1)
    len = len + 1
  }
  fail(s, "invalid Huffman code")
  return -1
}

func lengthBase(): buffer[Int] {
  Buf.fromSlice(
    [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  )
}

func lengthExtra(): buffer[Int] {
  Buf.fromSlice([0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0])
}

func distBase(): buffer[Int] {
  Buf.fromSlice(
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
  )
}

func distExtra(): buffer[Int] {
  Buf.fromSlice([0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13])
}

func codes(s: Inflater, lit: Huffman, dist: Huffman): Unit {
  val lbase = lengthBase()
  val lext = lengthExtra()
  val dbase = distBase()
  val dext = distExtra()
  while s.error == "" {
    var sym = decodeSymbol(s, lit)
    if s.error != "" {
      return
    }
    if s.produced.count > s.limit {
      fail(s, "output exceeds the expected size")
      return
    }
    if sym < 256 {
      s.produced.add(sym.toByte())
    } else if sym == 256 {
      return
    } else {
      sym = sym - 257
      if sym >= 29 {
        fail(s, "invalid length symbol")
        return
      }
      val len = lbase[sym] + getBits(s, lext[sym])
      val dsym = decodeSymbol(s, dist)
      if s.error != "" {
        return
      }
      if dsym < 0 or dsym >= 30 {
        fail(s, "invalid distance symbol")
        return
      }
      val d = dbase[dsym] + getBits(s, dext[dsym])
      if s.error != "" {
        return
      }
      if d > s.produced.count {
        fail(s, "distance reaches before the start of the output")
        return
      }
      if s.produced.count + len > s.limit + 258 {
        fail(s, "output exceeds the expected size")
        return
      }
      var k = 0
      while k < len {
        s.produced.add(s.produced[s.produced.count - d])
        k = k + 1
      }
    }
  }
}

func stored(s: Inflater): Unit {
  s.bitBuf = 0
  s.bitCnt = 0
  if s.pos + 4 > s.stop {
    fail(s, "unexpected end of compressed data")
    return
  }
  val len = s.data[s.pos].toInt().or(s.data[s.pos + 1].toInt().shl(8))
  val nlen = s.data[s.pos + 2].toInt().or(s.data[s.pos + 3].toInt().shl(8))
  if len != nlen.xor(65535) {
    fail(s, "stored block length check failed")
    return
  }
  s.pos = s.pos + 4
  if s.pos + len > s.stop {
    fail(s, "unexpected end of compressed data")
    return
  }
  if s.produced.count + len > s.limit {
    fail(s, "output exceeds the expected size")
    return
  }
  var i = 0
  while i < len {
    s.produced.add(s.data[s.pos + i])
    i = i + 1
  }
  s.pos = s.pos + len
}

func fixedCodes(s: Inflater): Unit {
  var lengths = Buf.filled(288, 8)
  var i = 144
  while i < 256 {
    lengths[i] = 9
    i = i + 1
  }
  while i < 280 {
    lengths[i] = 7
    i = i + 1
  }
  val lit = buildHuffman(lengths, 288)
  val dist = buildHuffman(Buf.filled(30, 5), 30)
  codes(s, lit, dist)
}

func dynamicCodes(s: Inflater): Unit {
  val nlen = getBits(s, 5) + 257
  val ndist = getBits(s, 5) + 1
  val ncode = getBits(s, 4) + 4
  if s.error != "" {
    return
  }
  if nlen > 286 or ndist > 30 {
    fail(s, "too many length or distance codes")
    return
  }
  val order = Buf.fromSlice([16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15])
  var lengths = Buf.filled(320, 0)
  var i = 0
  while i < ncode {
    lengths[order[i]] = getBits(s, 3)
    i = i + 1
  }
  if s.error != "" {
    return
  }
  val lencode = buildHuffman(lengths, 19)
  if lencode.left != 0 {
    fail(s, "over-subscribed or incomplete code length code")
    return
  }
  var index = 0
  var all = Buf.filled(320, 0)
  while index < nlen + ndist {
    val sym = decodeSymbol(s, lencode)
    if s.error != "" {
      return
    }
    if sym < 16 {
      all[index] = sym
      index = index + 1
    } else {
      var repeatValue = 0
      var repeatCount = 0
      if sym == 16 {
        if index == 0 {
          fail(s, "repeat with no previous length")
          return
        }
        repeatValue = all[index - 1]
        repeatCount = 3 + getBits(s, 2)
      } else if sym == 17 {
        repeatCount = 3 + getBits(s, 3)
      } else {
        repeatCount = 11 + getBits(s, 7)
      }
      if s.error != "" {
        return
      }
      if index + repeatCount > nlen + ndist {
        fail(s, "repeat overflows the code lengths")
        return
      }
      var k = 0
      while k < repeatCount {
        all[index] = repeatValue
        index = index + 1
        k = k + 1
      }
    }
  }
  if all[256] == 0 {
    fail(s, "no end-of-block code")
    return
  }
  var litLengths = Buf.filled(288, 0)
  var distLengths = Buf.filled(30, 0)
  var j = 0
  while j < nlen {
    litLengths[j] = all[j]
    j = j + 1
  }
  j = 0
  while j < ndist {
    distLengths[j] = all[nlen + j]
    j = j + 1
  }
  val lit = buildHuffman(litLengths, nlen)
  val dist = buildHuffman(distLengths, ndist)
  if lit.left < 0 or dist.left < 0 {
    fail(s, "over-subscribed Huffman code")
    return
  }
  // An incomplete code is accepted only for the single-code case DEFLATE allows (zlib's puff).
  if (lit.left > 0 and not (lit.counts[1] == 1 and nlen == lit.counts[0] + 1)) or (dist.left > 0 and not (dist.counts[1] == 1 and ndist == dist.counts[0] + 1)) {
    fail(s, "incomplete Huffman code")
    return
  }
  codes(s, lit, dist)
}

/// Decompresses the raw DEFLATE stream in `data[from ..< to]`.  `maxOutput` bounds the output
/// (a stream that would produce more is an error, not an allocation): pass the size the format
/// promises, so a small hostile stream cannot expand without limit.
pub func inflateRange(data: in slice[Byte], from: in Int, to: in Int, maxOutput: in Int): Result[buffer[Byte], String]
  requires: from >= 0 and from <= to and to <= data.length and maxOutput >= 0
{
  val s = Inflater(
    data = data,
    stop = to,
    limit = maxOutput,
    pos = from,
    bitBuf = 0,
    bitCnt = 0,
    produced = newList(),
    error = ""
  )
  var last = 0
  while last == 0 and s.error == "" {
    last = getBits(s, 1)
    val kind = getBits(s, 2)
    if s.error == "" {
      if kind == 0 {
        stored(s)
      } else if kind == 1 {
        fixedCodes(s)
      } else if kind == 2 {
        dynamicCodes(s)
      } else {
        fail(s, "invalid block type")
      }
    }
  }
  if s.error != "" {
    return Err(error = "inflate: " + s.error)
  }
  if s.produced.count > maxOutput {
    return Err(error = "inflate: output exceeds the expected size")
  }
  Ok(value = Buf.fromSlice(s.produced.toArray()))
}

/// Decompresses a raw DEFLATE stream, producing at most `maxOutput` bytes.
pub func inflate(data: in slice[Byte], maxOutput: in Int): Result[buffer[Byte], String]
  requires: maxOutput >= 0
{
  inflateRange(data, 0, data.length, maxOutput)
}

/// The Adler-32 checksum of `data`.
pub func adler32(data: in buffer[Byte]): Long {
  var a = 1
  var b = 0
  var i = 0
  while i < data.length {
    a = (a + data[i].toInt()) % 65521
    b = (b + a) % 65521
    i = i + 1
  }
  b.toLong().shl(16).or(a.toLong())
}

/// Decompresses a zlib stream: the two-byte header, DEFLATE data, and the Adler-32 check, producing
/// at most `maxOutput` bytes.
pub func zlibDecompress(data: in slice[Byte], maxOutput: in Int): Result[buffer[Byte], String]
  requires: maxOutput >= 0
{
  if data.length < 6 {
    return Err(error = "zlib: stream too short")
  }
  val cmf = data[0].toInt()
  val flg = data[1].toInt()
  if cmf.and(15) != 8 or (cmf * 256 + flg) % 31 != 0 {
    return Err(error = "zlib: bad header")
  }
  if flg.and(32) != 0 {
    return Err(error = "zlib: preset dictionaries are not supported")
  }
  val plain = match inflateRange(data, 2, data.length - 4, maxOutput) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = e)
  }
  val n = data.length
  val expected = data[n - 4].toLong().shl(24).or(data[n - 3].toLong().shl(16)).or(data[n - 2].toLong().shl(8)).or(
    data[n - 1].toLong()
  )
  if adler32(plain) != expected {
    return Err(error = "zlib: Adler-32 mismatch")
  }
  Ok(value = plain)
}
