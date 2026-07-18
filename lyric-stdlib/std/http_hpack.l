//! std/http_hpack.l — pure-Lyric HPACK (RFC 7541) header-compression codec
//! (docs/61-https-tls-http-versions.md §6.4, D128; phase 4.1 of epic #5874,
//! issue #5886).
//!
//! `Std.HttpEngine.Hpack` is the header-field compression layer HTTP/2 uses:
//! it encodes and decodes a *header block* — the compressed representation of
//! an ordered list of `(name, value)` header fields — against a static table
//! (RFC 7541 Appendix A, 61 fixed entries), a per-connection dynamic table
//! (with FIFO eviction and size management), the integer (§5.1) and string
//! (§5.2) primitives, and the RFC 7541 Appendix B Huffman code. Like
//! `Std.HttpEngine` (the sans-IO HTTP/1.1 engine this sits beside) and the
//! `Std.Xml`/`Std.Yaml` pure parsers (D065), this file is **pure Lyric**: no
//! `extern type`, no `import extern`, no kernel file — every byte is plain
//! computation over `slice[Byte]`/`String`, so it is exhaustively unit-testable
//! with zero I/O and reusable unchanged by every target's transport.
//!
//! ## Octet model
//!
//! HPACK header names and values are sequences of *octets*, not Unicode text.
//! This codec models each octet string as a Lyric `String` under a **Latin-1
//! (ISO-8859-1) mapping**: code point `i` (0..255) is octet `i`. For the ASCII
//! header names/values that dominate real traffic (and every RFC 7541
//! Appendix C example) this is exactly ASCII; for the rare non-ASCII octet it
//! round-trips faithfully octet-for-octet. Encoding a `String` whose code
//! point exceeds 255 is rejected with `NonOctetValue` rather than silently
//! truncated — a codec must never corrupt the bytes it is asked to carry.
//! Header fields reuse `Std.HttpEngine.HeaderField` so the h2 path feeds the
//! same request pipeline the HTTP/1.1 path does.
//!
//! ## Dynamic table and SETTINGS_HEADER_TABLE_SIZE
//!
//! The dynamic table is a FIFO of recently-seen fields; each entry costs
//! `len(name) + len(value) + 32` octets (RFC 7541 §4.1). Inserting evicts the
//! oldest entries until the new entry fits under the table's current maximum,
//! and an entry larger than the whole maximum empties the table without being
//! added (§4.4). `SETTINGS_HEADER_TABLE_SIZE` is the protocol ceiling on that
//! maximum: a "Dynamic Table Size Update" representation (§6.3) in the header
//! block resizes the table, and any update exceeding the negotiated ceiling is
//! rejected (`TableSizeUpdateTooLarge`). Per §4.2 a size update may only appear
//! at the start of a header block, before any header-field representation —
//! `SizeUpdateAfterHeader` otherwise. On the encoder, `encoderSetMaxTableSize`
//! resizes the table and queues the required update to be emitted at the head
//! of the next block.
//!
//! ## Encoder policy (deterministic, RFC-vector-reproducing)
//!
//! The stateful encoder is deliberately deterministic so its output byte-matches
//! the RFC 7541 Appendix C reference vectors: a field whose exact `(name, value)`
//! is already in the static or dynamic table is emitted as an *Indexed Header
//! Field*; otherwise it is emitted as a *Literal Header Field with Incremental
//! Indexing* (referencing an indexed name when the name alone is in a table,
//! else a literal name) and added to the dynamic table. When the encoder is
//! constructed with `huffman = true` every literal is Huffman-coded; with
//! `huffman = false` none are. A size-optimal "shorter-of-{raw, Huffman}" per
//! literal policy and a never-index policy for sensitive fields are valid
//! future refinements — not correctness gaps, since any conforming decoder
//! accepts this output — tracked for a follow-up. The low-level
//! per-representation encoders (`encodeLiteralWithoutIndexing`,
//! `encodeLiteralNeverIndexed`, `encodeDynamicTableSizeUpdate`, …) are exposed
//! for callers that need explicit control, and the decoder accepts every
//! representation regardless of which encoder produced it.
@runtime_checked
package Std.HttpEngine.Hpack

import Std.Core
import Std.Collections
import Std.String
import Std.Char as Char
import Std.HttpEngine

// =============================================================================
// §1. Error vocabulary.
// =============================================================================
/// Every way encoding or decoding an HPACK header block can fail. Decode
/// errors are fatal to the HPACK context for the connection (RFC 7541 §4.1 /
/// RFC 9113 §4.3 make a decoding error a connection error); the caller should
/// tear the h2 connection down with `COMPRESSION_ERROR`.
@experimental
pub union HpackError {
  case IncompleteInput
  case IntegerOverflow
  case InvalidIndex(index: Int)
  case InvalidHuffmanPadding
  case InvalidHuffmanCode
  case HuffmanEosSymbol
  case TableSizeUpdateTooLarge(requested: Int, maxAllowed: Int)
  case SizeUpdateAfterHeader
  case NonOctetValue(codepoint: Int)
}

// =============================================================================
// §2. Small numeric helper.
// =============================================================================
/// `2^n` for small non-negative `n`. Used for bit extraction and prefix masks;
/// every call site keeps `n <= 30`, well inside `Int` range.
func pow2(n: in Int): Int {
  var r = 1
  var i = 0
  while i < n {
    r = r * 2
    i = i + 1
  }
  r
}

func appendSlice(acc: in List[Byte], s: in slice[Byte]): Unit {
  var i = 0
  while i < s.length {
    acc.add(s[i])
    i = i + 1
  }
}

// =============================================================================
// §3. Integer representation (RFC 7541 §5.1).
// =============================================================================
/// The decoded value plus the offset one past the last byte consumed.
@experimental
pub record IntResult {
  value: Int
  offset: Int
}

/// Encode `value` with an `prefixBits`-bit prefix and no high flag bits set
/// (the standalone form shown in RFC 7541 §5.1 / Appendix C.1).
@experimental
pub func encodeInteger(value: in Int, prefixBits: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  encodeIntegerInto(acc, value, prefixBits, 0)
  acc.toArray()
}

/// Encode `value` into `acc` with an `prefixBits`-bit prefix, OR-ing `flags`
/// (already positioned in the high `8 - prefixBits` bits) into the first byte.
/// `flags` and the prefix never overlap, so integer `+` composes them.
func encodeIntegerInto(acc: in List[Byte], value: in Int, prefixBits: in Int, flags: in Int): Unit {
  val maxPrefix = pow2(prefixBits) - 1
  if value < maxPrefix {
    acc.add((flags + value).toByte())
  } else {
    acc.add((flags + maxPrefix).toByte())
    var v = value - maxPrefix
    while v >= 128 {
      acc.add(((v % 128) + 128).toByte())
      v = v / 128
    }
    acc.add(v.toByte())
  }
}

/// Decode an integer with an `prefixBits`-bit prefix starting at `offset`.
/// Bounds the value to keep intermediate arithmetic inside `Int` — a
/// continuation run that would overflow is rejected as `IntegerOverflow`
/// rather than silently wrapping (a classic HPACK-bomb defense).
@experimental
pub func decodeIntegerAt(bytes: in slice[Byte], offset: in Int, prefixBits: in Int): Result[IntResult, HpackError] {
  if offset >= bytes.length {
    return Err(error = IncompleteInput)
  }
  val maxPrefix = pow2(prefixBits) - 1
  val firstByte = bytes[offset].toInt()
  val prefixVal = firstByte % (maxPrefix + 1)
  if prefixVal < maxPrefix {
    return Ok(value = IntResult(value = prefixVal, offset = offset + 1))
  }
  var result = maxPrefix
  var mult = 1
  var pos = offset + 1
  var more = true
  while more {
    if pos >= bytes.length {
      return Err(error = IncompleteInput)
    }
    val b = bytes[pos].toInt()
    pos = pos + 1
    result = result + (b % 128) * mult
    if result < 0 or result > 268435455 {
      return Err(error = IntegerOverflow)
    }
    if b < 128 {
      more = false
    } else {
      mult = mult * 128
      if mult > 2097152 {
        return Err(error = IntegerOverflow)
      }
    }
  }
  Ok(value = IntResult(value = result, offset = pos))
}

// =============================================================================
// §4. Huffman coding (RFC 7541 §5.2 + Appendix B).
// =============================================================================
/// Huffman-encode an octet string: each symbol's code is appended MSB-first to
/// a bit stream, then the final partial byte is padded with the most
/// significant bits of the EOS code (all ones), per RFC 7541 §5.2.
@experimental
pub func huffmanEncode(octets: in slice[Byte]): slice[Byte] {
  val codes = buildHuffCodes()
  val lens = buildHuffLens()
  val acc: List[Byte] = newList()
  var cur = 0
  var nbits = 0
  var i = 0
  while i < octets.length {
    val sym = octets[i].toInt()
    val code = codes[sym]
    val len = lens[sym]
    var b = len - 1
    while b >= 0 {
      val bit = (code / pow2(b)) % 2
      cur = cur * 2 + bit
      nbits = nbits + 1
      if nbits == 8 {
        acc.add(cur.toByte())
        cur = 0
        nbits = 0
      }
      b = b - 1
    }
    i = i + 1
  }
  if nbits > 0 {
    var pad = 8 - nbits
    while pad > 0 {
      cur = cur * 2 + 1
      pad = pad - 1
    }
    acc.add(cur.toByte())
  }
  acc.toArray()
}

/// A decoding trie over the Appendix B code, held as parallel arrays: `zero`/
/// `one` are the child node index for a 0/1 bit (`-1` = no child), and `sym`
/// is the symbol decoded at that node (`-1` = internal node).
record HuffTrie {
  zero: List[Int]
  one: List[Int]
  sym: List[Int]
}

func buildHuffTrie(): HuffTrie {
  val codes = buildHuffCodes()
  val lens = buildHuffLens()
  val zero: List[Int] = newList()
  val one: List[Int] = newList()
  val sym: List[Int] = newList()
  zero.add(-1)
  one.add(-1)
  sym.add(-1)
  var s = 0
  while s <= 256 {
    val code = codes[s]
    val len = lens[s]
    var node = 0
    var b = len - 1
    while b >= 0 {
      val bit = (code / pow2(b)) % 2
      val child = if bit == 0 { zero[node] } else { one[node] }
      if child == -1 {
        val newIdx = zero.count
        zero.add(-1)
        one.add(-1)
        sym.add(-1)
        if bit == 0 {
          zero[node] = newIdx
        } else {
          one[node] = newIdx
        }
        node = newIdx
      } else {
        node = child
      }
      b = b - 1
    }
    sym[node] = s
    s = s + 1
  }
  HuffTrie(zero = zero, one = one, sym = sym)
}

/// Huffman-decode a byte string. Rejects an embedded EOS symbol
/// (`HuffmanEosSymbol`), a bit run that leaves the code tree (`InvalidHuffmanCode`),
/// and trailing padding that is not the (<= 7-bit, all-ones) most-significant
/// bits of EOS (`InvalidHuffmanPadding`) — the RFC 7541 §5.2 conformance rules
/// and the adversarial-padding surface issue #5886 calls outList.
@experimental
pub func huffmanDecode(bytes: in slice[Byte]): Result[slice[Byte], HpackError] {
  val trie = buildHuffTrie()
  val outList: List[Byte] = newList()
  var node = 0
  var bitsSinceBoundary = 0
  var allOnesSinceBoundary = true
  var i = 0
  while i < bytes.length {
    val byteVal = bytes[i].toInt()
    var b = 7
    while b >= 0 {
      val bit = (byteVal / pow2(b)) % 2
      if bit == 0 {
        allOnesSinceBoundary = false
      }
      val child = if bit == 0 { trie.zero[node] } else { trie.one[node] }
      if child == -1 {
        return Err(error = InvalidHuffmanCode)
      }
      node = child
      bitsSinceBoundary = bitsSinceBoundary + 1
      val s = trie.sym[node]
      if s >= 0 {
        if s == 256 {
          return Err(error = HuffmanEosSymbol)
        }
        outList.add(s.toByte())
        node = 0
        bitsSinceBoundary = 0
        allOnesSinceBoundary = true
      }
      b = b - 1
    }
    i = i + 1
  }
  if node == 0 {
    Ok(value = outList.toArray())
  } else if bitsSinceBoundary <= 7 and allOnesSinceBoundary {
    Ok(value = outList.toArray())
  } else {
    Err(error = InvalidHuffmanPadding)
  }
}

// =============================================================================
// §5. String literal representation (RFC 7541 §5.2).
// =============================================================================
/// The decoded octets plus the offset one past the last byte consumed.
@experimental
pub record StrResult {
  octets: slice[Byte]
  offset: Int
}

/// Encode an octet string as a length-prefixed literal, Huffman-coded iff
/// `huffman` is set (the H bit in the length prefix records which form).
@experimental
pub func encodeStringLiteral(octets: in slice[Byte], huffman: in Bool): slice[Byte] {
  val acc: List[Byte] = newList()
  if huffman {
    val enc = huffmanEncode(octets)
    encodeIntegerInto(acc, enc.length, 7, 128)
    appendSlice(acc, enc)
  } else {
    encodeIntegerInto(acc, octets.length, 7, 0)
    appendSlice(acc, octets)
  }
  acc.toArray()
}

/// Decode a length-prefixed string literal (Huffman or raw) at `offset`.
@experimental
pub func decodeStringLiteralAt(bytes: in slice[Byte], offset: in Int): Result[StrResult, HpackError] {
  if offset >= bytes.length {
    return Err(error = IncompleteInput)
  }
  val huffman = bytes[offset].toInt() >= 128
  val ir = decodeIntegerAt(bytes, offset, 7)?
  val len = ir.value
  val start = ir.offset
  if start + len > bytes.length {
    return Err(error = IncompleteInput)
  }
  val raw = bytes.slice(start, start + len)
  if huffman {
    val decoded = huffmanDecode(raw)?
    Ok(value = StrResult(octets = decoded, offset = start + len))
  } else {
    Ok(value = StrResult(octets = raw, offset = start + len))
  }
}

// =============================================================================
// §6. Octet <-> String (Latin-1) bridge.
// =============================================================================
/// Interpret an octet string as a Latin-1 `String` (code point i == octet i).
@pure
@experimental
pub func octetsToString(octets: in slice[Byte]): String {
  var acc = ""
  var i = 0
  while i < octets.length {
    acc = acc + ("" + Char.fromInt(octets[i].toInt()))
    i = i + 1
  }
  acc
}

/// Convert a `String` to its Latin-1 octets, rejecting any code point above
/// 255 (`NonOctetValue`) rather than corrupting the carried bytes.
@experimental
pub func stringToOctets(s: in String): Result[slice[Byte], HpackError] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < s.length {
    match charAt(s, i) {
      case None -> return Err(error = NonOctetValue(codepoint = -1))
      case Some(c) -> {
        val cp = toInt(c)
        if cp > 255 or cp < 0 {
          return Err(error = NonOctetValue(codepoint = cp))
        }
        acc.add(cp.toByte())
      }
    }
    i = i + 1
  }
  Ok(value = acc.toArray())
}

// =============================================================================
// §7. Static table (RFC 7541 Appendix A).
// =============================================================================
/// The RFC 7541 Appendix A static-table entry at 1-based `index`, or `None`
/// if `index` is outside 1..61.
@pure
@experimental
pub func staticTableEntry(index: in Int): Option[HeaderField] {
  staticEntry(index)
}

/// The number of static-table entries (RFC 7541 Appendix A defines 61).
@pure
@experimental
pub func staticTableSize(): Int {
  61
}

func staticEntry(index: in Int): Option[HeaderField] {
  match index {
    case 1 -> Some(value = HeaderField(name = ":authority", value = ""))
    case 2 -> Some(value = HeaderField(name = ":method", value = "GET"))
    case 3 -> Some(value = HeaderField(name = ":method", value = "POST"))
    case 4 -> Some(value = HeaderField(name = ":path", value = "/"))
    case 5 -> Some(value = HeaderField(name = ":path", value = "/index.html"))
    case 6 -> Some(value = HeaderField(name = ":scheme", value = "http"))
    case 7 -> Some(value = HeaderField(name = ":scheme", value = "https"))
    case 8 -> Some(value = HeaderField(name = ":status", value = "200"))
    case 9 -> Some(value = HeaderField(name = ":status", value = "204"))
    case 10 -> Some(value = HeaderField(name = ":status", value = "206"))
    case 11 -> Some(value = HeaderField(name = ":status", value = "304"))
    case 12 -> Some(value = HeaderField(name = ":status", value = "400"))
    case 13 -> Some(value = HeaderField(name = ":status", value = "404"))
    case 14 -> Some(value = HeaderField(name = ":status", value = "500"))
    case 15 -> Some(value = HeaderField(name = "accept-charset", value = ""))
    case 16 -> Some(value = HeaderField(name = "accept-encoding", value = "gzip, deflate"))
    case 17 -> Some(value = HeaderField(name = "accept-language", value = ""))
    case 18 -> Some(value = HeaderField(name = "accept-ranges", value = ""))
    case 19 -> Some(value = HeaderField(name = "accept", value = ""))
    case 20 -> Some(value = HeaderField(name = "access-control-allow-origin", value = ""))
    case 21 -> Some(value = HeaderField(name = "age", value = ""))
    case 22 -> Some(value = HeaderField(name = "allow", value = ""))
    case 23 -> Some(value = HeaderField(name = "authorization", value = ""))
    case 24 -> Some(value = HeaderField(name = "cache-control", value = ""))
    case 25 -> Some(value = HeaderField(name = "content-disposition", value = ""))
    case 26 -> Some(value = HeaderField(name = "content-encoding", value = ""))
    case 27 -> Some(value = HeaderField(name = "content-language", value = ""))
    case 28 -> Some(value = HeaderField(name = "content-length", value = ""))
    case 29 -> Some(value = HeaderField(name = "content-location", value = ""))
    case 30 -> Some(value = HeaderField(name = "content-range", value = ""))
    case 31 -> Some(value = HeaderField(name = "content-type", value = ""))
    case 32 -> Some(value = HeaderField(name = "cookie", value = ""))
    case 33 -> Some(value = HeaderField(name = "date", value = ""))
    case 34 -> Some(value = HeaderField(name = "etag", value = ""))
    case 35 -> Some(value = HeaderField(name = "expect", value = ""))
    case 36 -> Some(value = HeaderField(name = "expires", value = ""))
    case 37 -> Some(value = HeaderField(name = "from", value = ""))
    case 38 -> Some(value = HeaderField(name = "host", value = ""))
    case 39 -> Some(value = HeaderField(name = "if-match", value = ""))
    case 40 -> Some(value = HeaderField(name = "if-modified-since", value = ""))
    case 41 -> Some(value = HeaderField(name = "if-none-match", value = ""))
    case 42 -> Some(value = HeaderField(name = "if-range", value = ""))
    case 43 -> Some(value = HeaderField(name = "if-unmodified-since", value = ""))
    case 44 -> Some(value = HeaderField(name = "last-modified", value = ""))
    case 45 -> Some(value = HeaderField(name = "link", value = ""))
    case 46 -> Some(value = HeaderField(name = "location", value = ""))
    case 47 -> Some(value = HeaderField(name = "max-forwards", value = ""))
    case 48 -> Some(value = HeaderField(name = "proxy-authenticate", value = ""))
    case 49 -> Some(value = HeaderField(name = "proxy-authorization", value = ""))
    case 50 -> Some(value = HeaderField(name = "range", value = ""))
    case 51 -> Some(value = HeaderField(name = "referer", value = ""))
    case 52 -> Some(value = HeaderField(name = "refresh", value = ""))
    case 53 -> Some(value = HeaderField(name = "retry-after", value = ""))
    case 54 -> Some(value = HeaderField(name = "server", value = ""))
    case 55 -> Some(value = HeaderField(name = "set-cookie", value = ""))
    case 56 -> Some(value = HeaderField(name = "strict-transport-security", value = ""))
    case 57 -> Some(value = HeaderField(name = "transfer-encoding", value = ""))
    case 58 -> Some(value = HeaderField(name = "user-agent", value = ""))
    case 59 -> Some(value = HeaderField(name = "vary", value = ""))
    case 60 -> Some(value = HeaderField(name = "via", value = ""))
    case 61 -> Some(value = HeaderField(name = "www-authenticate", value = ""))
    case _ -> None
  }
}

// =============================================================================
// §8. Dynamic table (RFC 7541 §4).
// =============================================================================
/// One dynamic-table entry plus its precomputed cost
/// (`len(name) + len(value) + 32`, RFC 7541 §4.1).
@experimental
pub record DynEntry {
  name: String
  value: String
  cost: Int
}

/// A dynamic table: `entries` newest-first (index 0 is the most recent
/// insertion), `size` the summed cost of all entries, `maxSize` the current
/// maximum this table may occupy. Modeled as an immutable value — the table
/// operations return a new `DynamicTable` rather than mutating in place,
/// mirroring the linear-value style `Std.HttpEngine.Connection` uses.
@experimental
pub record DynamicTable {
  entries: List[DynEntry]
  size: Int
  maxSize: Int
}

/// An empty dynamic table with the given maximum size (octets).
@pure
@experimental
pub func newDynamicTable(maxSize: in Int): DynamicTable {
  val entries: List[DynEntry] = newList()
  DynamicTable(entries = entries, size = 0, maxSize = maxSize)
}

func copyEntries(src: in List[DynEntry]): List[DynEntry] {
  val outList: List[DynEntry] = newList()
  var i = 0
  while i < src.count {
    outList.add(src[i])
    i = i + 1
  }
  outList
}

/// Insert `(name, value)` at the front, evicting the oldest entries until it
/// fits under `maxSize`. An entry larger than the whole table empties it and
/// is not added (RFC 7541 §4.4).
@experimental
pub func dynamicTableInsert(table: in DynamicTable, name: in String, value: in String): DynamicTable {
  val cost = name.length + value.length + 32
  val kept = copyEntries(table.entries)
  var newSize = table.size
  while kept.count > 0 and newSize + cost > table.maxSize {
    val last = kept[kept.count - 1]
    newSize = newSize - last.cost
    kept.removeAt(kept.count - 1)
  }
  if cost > table.maxSize {
    newDynamicTable(table.maxSize)
  } else {
    val outList: List[DynEntry] = newList()
    outList.add(DynEntry(name = name, value = value, cost = cost))
    var i = 0
    while i < kept.count {
      outList.add(kept[i])
      i = i + 1
    }
    DynamicTable(entries = outList, size = newSize + cost, maxSize = table.maxSize)
  }
}

/// Set a new maximum size, evicting the oldest entries until the table fits
/// (RFC 7541 §4.3).
@experimental
pub func dynamicTableResize(table: in DynamicTable, newMax: in Int): DynamicTable {
  val kept = copyEntries(table.entries)
  var newSize = table.size
  while kept.count > 0 and newSize > newMax {
    val last = kept[kept.count - 1]
    newSize = newSize - last.cost
    kept.removeAt(kept.count - 1)
  }
  DynamicTable(entries = kept, size = newSize, maxSize = newMax)
}

@pure
@experimental
pub func dynamicTableCount(table: in DynamicTable): Int {
  table.entries.count
}

@pure
@experimental
pub func dynamicTableSize(table: in DynamicTable): Int {
  table.size
}

@pure
@experimental
pub func dynamicTableMaxSize(table: in DynamicTable): Int {
  table.maxSize
}

/// The dynamic-table entry at 0-based `i` (newest first), or `None`.
@pure
@experimental
pub func dynamicTableEntry(table: in DynamicTable, i: in Int): Option[HeaderField] {
  if i >= 0 and i < table.entries.count {
    val e = table.entries[i]
    Some(value = HeaderField(name = e.name, value = e.value))
  } else {
    None
  }
}

/// Resolve a combined HPACK index (RFC 7541 §2.3.3: 1..61 static, 62.. dynamic
/// newest-first) to its header field.
@experimental
pub func resolveIndex(table: in DynamicTable, index: in Int): Result[HeaderField, HpackError] {
  if index >= 1 and index <= 61 {
    match staticEntry(index) {
      case Some(hf) -> Ok(value = hf)
      case None -> Err(error = InvalidIndex(index = index))
    }
  } else if index >= 62 {
    val di = index - 62
    if di < table.entries.count {
      val e = table.entries[di]
      Ok(value = HeaderField(name = e.name, value = e.value))
    } else {
      Err(error = InvalidIndex(index = index))
    }
  } else {
    Err(error = InvalidIndex(index = index))
  }
}

// =============================================================================
// §9. Low-level representation encoders (RFC 7541 §6).
// =============================================================================
/// An Indexed Header Field (§6.1): the whole field is one table index.
@experimental
pub func encodeIndexedField(index: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  encodeIntegerInto(acc, index, 7, 128)
  acc.toArray()
}

/// A Literal Header Field with Incremental Indexing (§6.2.1): the decoder adds
/// the field to its dynamic table. `nameIndex` is `Some` for an indexed name,
/// `None` for a literal name.
@experimental
pub func encodeLiteralIncrementalIndexed(
  nameIndex: in Option[Int],
  nameOctets: in slice[Byte],
  valueOctets: in slice[Byte],
  huffman: in Bool,
): slice[Byte] {
  encodeLiteralWith(nameIndex, nameOctets, valueOctets, huffman, 6, 64)
}

/// A Literal Header Field without Indexing (§6.2.2): not added to the table.
@experimental
pub func encodeLiteralWithoutIndexing(
  nameIndex: in Option[Int],
  nameOctets: in slice[Byte],
  valueOctets: in slice[Byte],
  huffman: in Bool,
): slice[Byte] {
  encodeLiteralWith(nameIndex, nameOctets, valueOctets, huffman, 4, 0)
}

/// A Literal Header Field Never Indexed (§6.2.3): not added, and intermediaries
/// must preserve the never-indexed form.
@experimental
pub func encodeLiteralNeverIndexed(
  nameIndex: in Option[Int],
  nameOctets: in slice[Byte],
  valueOctets: in slice[Byte],
  huffman: in Bool,
): slice[Byte] {
  encodeLiteralWith(nameIndex, nameOctets, valueOctets, huffman, 4, 16)
}

func encodeLiteralWith(
  nameIndex: in Option[Int],
  nameOctets: in slice[Byte],
  valueOctets: in slice[Byte],
  huffman: in Bool,
  prefixBits: in Int,
  flags: in Int,
): slice[Byte] {
  val acc: List[Byte] = newList()
  match nameIndex {
    case Some(n) -> encodeIntegerInto(acc, n, prefixBits, flags)
    case None -> {
      encodeIntegerInto(acc, 0, prefixBits, flags)
      appendSlice(acc, encodeStringLiteral(nameOctets, huffman))
    }
  }
  appendSlice(acc, encodeStringLiteral(valueOctets, huffman))
  acc.toArray()
}

/// A Dynamic Table Size Update (§6.3).
@experimental
pub func encodeDynamicTableSizeUpdate(newSize: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  encodeIntegerInto(acc, newSize, 5, 32)
  acc.toArray()
}

// =============================================================================
// §10. Stateful decoder.
// =============================================================================
/// A per-connection HPACK decoder: its dynamic `table` plus the protocol
/// ceiling `maxProtocolSize` (the negotiated `SETTINGS_HEADER_TABLE_SIZE`) that
/// any Dynamic Table Size Update in a block must not exceed.
@experimental
pub record HpackDecoder {
  table: DynamicTable
  maxProtocolSize: Int
}

/// A decoder whose dynamic table starts empty at `maxProtocolSize` octets.
@pure
@experimental
pub func newDecoder(maxProtocolSize: in Int): HpackDecoder {
  HpackDecoder(table = newDynamicTable(maxProtocolSize), maxProtocolSize = maxProtocolSize)
}

/// Lower the protocol ceiling (called when this endpoint advertises a smaller
/// `SETTINGS_HEADER_TABLE_SIZE`); the peer's next block must carry a size
/// update at or below it.
@experimental
pub func decoderSetMaxProtocolSize(decoder: inout HpackDecoder, newMax: in Int): Unit {
  decoder.maxProtocolSize = newMax
}

@pure
@experimental
pub func decoderDynamicTable(decoder: in HpackDecoder): DynamicTable {
  decoder.table
}

/// Decode a complete header block into its ordered header-field list, updating
/// the decoder's dynamic table as a side effect. A malformed block leaves the
/// decoder poisoned for the connection (the caller must not continue on error).
@experimental
pub func decodeHeaderBlock(decoder: inout HpackDecoder, block: in slice[Byte]): Result[List[HeaderField], HpackError] {
  val outList: List[HeaderField] = newList()
  var offset = 0
  var sawHeader = false
  while offset < block.length {
    val b0 = block[offset].toInt()
    if b0 >= 128 {
      val ir = decodeIntegerAt(block, offset, 7)?
      if ir.value == 0 {
        return Err(error = InvalidIndex(index = 0))
      }
      val hf = resolveIndex(decoder.table, ir.value)?
      outList.add(hf)
      offset = ir.offset
      sawHeader = true
    } else if b0 >= 64 {
      offset = decodeLiteralField(decoder, block, offset, 6, true, outList)?
      sawHeader = true
    } else if b0 >= 32 {
      if sawHeader {
        return Err(error = SizeUpdateAfterHeader)
      }
      val ir = decodeIntegerAt(block, offset, 5)?
      if ir.value > decoder.maxProtocolSize {
        return Err(error = TableSizeUpdateTooLarge(requested = ir.value, maxAllowed = decoder.maxProtocolSize))
      }
      decoder.table = dynamicTableResize(decoder.table, ir.value)
      offset = ir.offset
    } else {
      offset = decodeLiteralField(decoder, block, offset, 4, false, outList)?
      sawHeader = true
    }
  }
  Ok(value = outList)
}

func decodeLiteralField(
  decoder: inout HpackDecoder,
  block: in slice[Byte],
  offset: in Int,
  prefixBits: in Int,
  addToTable: in Bool,
  outList: in List[HeaderField],
): Result[Int, HpackError] {
  val ir = decodeIntegerAt(block, offset, prefixBits)?
  val nameIndex = ir.value
  var nameStr = ""
  var noff = ir.offset
  if nameIndex == 0 {
    val sr = decodeStringLiteralAt(block, noff)?
    nameStr = octetsToString(sr.octets)
    noff = sr.offset
  } else {
    val hf = resolveIndex(decoder.table, nameIndex)?
    nameStr = hf.name
  }
  val vr = decodeStringLiteralAt(block, noff)?
  val valueStr = octetsToString(vr.octets)
  outList.add(HeaderField(name = nameStr, value = valueStr))
  if addToTable {
    decoder.table = dynamicTableInsert(decoder.table, nameStr, valueStr)
  }
  Ok(value = vr.offset)
}

// =============================================================================
// §11. Stateful encoder.
// =============================================================================
/// A per-connection HPACK encoder: its dynamic `table`, the peer's advertised
/// `maxProtocolSize` ceiling, the fixed `huffman` literal policy, and whether a
/// size update is queued to be emitted at the head of the next block.
@experimental
pub record HpackEncoder {
  table: DynamicTable
  maxProtocolSize: Int
  huffman: Bool
  pendingUpdate: Bool
}

/// An encoder whose dynamic table starts empty at `maxDynamicTableSize`
/// octets; `huffman` fixes whether literals are Huffman-coded (see the module
/// header's "Encoder policy" section).
@pure
@experimental
pub func newEncoder(maxDynamicTableSize: in Int, huffman: in Bool): HpackEncoder {
  HpackEncoder(
    table = newDynamicTable(maxDynamicTableSize),
    maxProtocolSize = maxDynamicTableSize,
    huffman = huffman,
    pendingUpdate = false
  )
}

@pure
@experimental
pub func encoderDynamicTable(encoder: in HpackEncoder): DynamicTable {
  encoder.table
}

/// Resize the encoder's dynamic table (RFC 7541 §4.3) and queue the Dynamic
/// Table Size Update that the next `encodeHeaderList` must emit first. Rejects
/// a size above the peer's advertised ceiling.
@experimental
pub func encoderSetMaxTableSize(encoder: inout HpackEncoder, newSize: in Int): Result[Unit, HpackError] {
  if newSize > encoder.maxProtocolSize {
    return Err(error = TableSizeUpdateTooLarge(requested = newSize, maxAllowed = encoder.maxProtocolSize))
  }
  encoder.table = dynamicTableResize(encoder.table, newSize)
  encoder.pendingUpdate = true
  Ok(value = ())
}

/// Encode an ordered header list into one header block, emitting a queued size
/// update first (if any) and updating the dynamic table for every
/// incrementally-indexed field.
@experimental
pub func encodeHeaderList(encoder: inout HpackEncoder, headers: in List[HeaderField]): Result[slice[Byte], HpackError] {
  val acc: List[Byte] = newList()
  if encoder.pendingUpdate {
    appendSlice(acc, encodeDynamicTableSizeUpdate(encoder.table.maxSize))
    encoder.pendingUpdate = false
  }
  var i = 0
  while i < headers.count {
    val h = headers[i]
    encodeHeaderField(encoder, acc, h)?
    i = i + 1
  }
  Ok(value = acc.toArray())
}

func encodeHeaderField(encoder: inout HpackEncoder, acc: in List[Byte], h: in HeaderField): Result[Unit, HpackError] {
  val nameOctets = stringToOctets(h.name)?
  val valueOctets = stringToOctets(h.value)?
  match findExactIndex(encoder.table, h.name, h.value) {
    case Some(idx) -> {
      appendSlice(acc, encodeIndexedField(idx))
      Ok(value = ())
    }
    case None -> {
      val nameIndex = findNameIndex(encoder.table, h.name)
      appendSlice(acc, encodeLiteralIncrementalIndexed(nameIndex, nameOctets, valueOctets, encoder.huffman))
      encoder.table = dynamicTableInsert(encoder.table, h.name, h.value)
      Ok(value = ())
    }
  }
}

func findExactIndex(table: in DynamicTable, name: in String, value: in String): Option[Int] {
  var i = 1
  while i <= 61 {
    match staticEntry(i) {
      case Some(e) -> if e.name == name and e.value == value { return Some(value = i) }
      case None -> ()
    }
    i = i + 1
  }
  var j = 0
  while j < table.entries.count {
    val e = table.entries[j]
    if e.name == name and e.value == value {
      return Some(value = 62 + j)
    }
    j = j + 1
  }
  None
}

func findNameIndex(table: in DynamicTable, name: in String): Option[Int] {
  var i = 1
  while i <= 61 {
    match staticEntry(i) {
      case Some(e) -> if e.name == name { return Some(value = i) }
      case None -> ()
    }
    i = i + 1
  }
  var j = 0
  while j < table.entries.count {
    val e = table.entries[j]
    if e.name == name {
      return Some(value = 62 + j)
    }
    j = j + 1
  }
  None
}

// =============================================================================
// §12. RFC 7541 Appendix B Huffman code table (generated, do not hand-edit).
// =============================================================================
func buildHuffCodes(): List[Int] {
  val c: List[Int] = newList()
  c.add(8184)
  c.add(8388568)
  c.add(268435426)
  c.add(268435427)
  c.add(268435428)
  c.add(268435429)
  c.add(268435430)
  c.add(268435431)
  c.add(268435432)
  c.add(16777194)
  c.add(1073741820)
  c.add(268435433)
  c.add(268435434)
  c.add(1073741821)
  c.add(268435435)
  c.add(268435436)
  c.add(268435437)
  c.add(268435438)
  c.add(268435439)
  c.add(268435440)
  c.add(268435441)
  c.add(268435442)
  c.add(1073741822)
  c.add(268435443)
  c.add(268435444)
  c.add(268435445)
  c.add(268435446)
  c.add(268435447)
  c.add(268435448)
  c.add(268435449)
  c.add(268435450)
  c.add(268435451)
  c.add(20)
  c.add(1016)
  c.add(1017)
  c.add(4090)
  c.add(8185)
  c.add(21)
  c.add(248)
  c.add(2042)
  c.add(1018)
  c.add(1019)
  c.add(249)
  c.add(2043)
  c.add(250)
  c.add(22)
  c.add(23)
  c.add(24)
  c.add(0)
  c.add(1)
  c.add(2)
  c.add(25)
  c.add(26)
  c.add(27)
  c.add(28)
  c.add(29)
  c.add(30)
  c.add(31)
  c.add(92)
  c.add(251)
  c.add(32764)
  c.add(32)
  c.add(4091)
  c.add(1020)
  c.add(8186)
  c.add(33)
  c.add(93)
  c.add(94)
  c.add(95)
  c.add(96)
  c.add(97)
  c.add(98)
  c.add(99)
  c.add(100)
  c.add(101)
  c.add(102)
  c.add(103)
  c.add(104)
  c.add(105)
  c.add(106)
  c.add(107)
  c.add(108)
  c.add(109)
  c.add(110)
  c.add(111)
  c.add(112)
  c.add(113)
  c.add(114)
  c.add(252)
  c.add(115)
  c.add(253)
  c.add(8187)
  c.add(524272)
  c.add(8188)
  c.add(16380)
  c.add(34)
  c.add(32765)
  c.add(3)
  c.add(35)
  c.add(4)
  c.add(36)
  c.add(5)
  c.add(37)
  c.add(38)
  c.add(39)
  c.add(6)
  c.add(116)
  c.add(117)
  c.add(40)
  c.add(41)
  c.add(42)
  c.add(7)
  c.add(43)
  c.add(118)
  c.add(44)
  c.add(8)
  c.add(9)
  c.add(45)
  c.add(119)
  c.add(120)
  c.add(121)
  c.add(122)
  c.add(123)
  c.add(32766)
  c.add(2044)
  c.add(16381)
  c.add(8189)
  c.add(268435452)
  c.add(1048550)
  c.add(4194258)
  c.add(1048551)
  c.add(1048552)
  c.add(4194259)
  c.add(4194260)
  c.add(4194261)
  c.add(8388569)
  c.add(4194262)
  c.add(8388570)
  c.add(8388571)
  c.add(8388572)
  c.add(8388573)
  c.add(8388574)
  c.add(16777195)
  c.add(8388575)
  c.add(16777196)
  c.add(16777197)
  c.add(4194263)
  c.add(8388576)
  c.add(16777198)
  c.add(8388577)
  c.add(8388578)
  c.add(8388579)
  c.add(8388580)
  c.add(2097116)
  c.add(4194264)
  c.add(8388581)
  c.add(4194265)
  c.add(8388582)
  c.add(8388583)
  c.add(16777199)
  c.add(4194266)
  c.add(2097117)
  c.add(1048553)
  c.add(4194267)
  c.add(4194268)
  c.add(8388584)
  c.add(8388585)
  c.add(2097118)
  c.add(8388586)
  c.add(4194269)
  c.add(4194270)
  c.add(16777200)
  c.add(2097119)
  c.add(4194271)
  c.add(8388587)
  c.add(8388588)
  c.add(2097120)
  c.add(2097121)
  c.add(4194272)
  c.add(2097122)
  c.add(8388589)
  c.add(4194273)
  c.add(8388590)
  c.add(8388591)
  c.add(1048554)
  c.add(4194274)
  c.add(4194275)
  c.add(4194276)
  c.add(8388592)
  c.add(4194277)
  c.add(4194278)
  c.add(8388593)
  c.add(67108832)
  c.add(67108833)
  c.add(1048555)
  c.add(524273)
  c.add(4194279)
  c.add(8388594)
  c.add(4194280)
  c.add(33554412)
  c.add(67108834)
  c.add(67108835)
  c.add(67108836)
  c.add(134217694)
  c.add(134217695)
  c.add(67108837)
  c.add(16777201)
  c.add(33554413)
  c.add(524274)
  c.add(2097123)
  c.add(67108838)
  c.add(134217696)
  c.add(134217697)
  c.add(67108839)
  c.add(134217698)
  c.add(16777202)
  c.add(2097124)
  c.add(2097125)
  c.add(67108840)
  c.add(67108841)
  c.add(268435453)
  c.add(134217699)
  c.add(134217700)
  c.add(134217701)
  c.add(1048556)
  c.add(16777203)
  c.add(1048557)
  c.add(2097126)
  c.add(4194281)
  c.add(2097127)
  c.add(2097128)
  c.add(8388595)
  c.add(4194282)
  c.add(4194283)
  c.add(33554414)
  c.add(33554415)
  c.add(16777204)
  c.add(16777205)
  c.add(67108842)
  c.add(8388596)
  c.add(67108843)
  c.add(134217702)
  c.add(67108844)
  c.add(67108845)
  c.add(134217703)
  c.add(134217704)
  c.add(134217705)
  c.add(134217706)
  c.add(134217707)
  c.add(268435454)
  c.add(134217708)
  c.add(134217709)
  c.add(134217710)
  c.add(134217711)
  c.add(134217712)
  c.add(67108846)
  c.add(1073741823)
  c
}

func buildHuffLens(): List[Int] {
  val n: List[Int] = newList()
  n.add(13)
  n.add(23)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(24)
  n.add(30)
  n.add(28)
  n.add(28)
  n.add(30)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(30)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(28)
  n.add(6)
  n.add(10)
  n.add(10)
  n.add(12)
  n.add(13)
  n.add(6)
  n.add(8)
  n.add(11)
  n.add(10)
  n.add(10)
  n.add(8)
  n.add(11)
  n.add(8)
  n.add(6)
  n.add(6)
  n.add(6)
  n.add(5)
  n.add(5)
  n.add(5)
  n.add(6)
  n.add(6)
  n.add(6)
  n.add(6)
  n.add(6)
  n.add(6)
  n.add(6)
  n.add(7)
  n.add(8)
  n.add(15)
  n.add(6)
  n.add(12)
  n.add(10)
  n.add(13)
  n.add(6)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(8)
  n.add(7)
  n.add(8)
  n.add(13)
  n.add(19)
  n.add(13)
  n.add(14)
  n.add(6)
  n.add(15)
  n.add(5)
  n.add(6)
  n.add(5)
  n.add(6)
  n.add(5)
  n.add(6)
  n.add(6)
  n.add(6)
  n.add(5)
  n.add(7)
  n.add(7)
  n.add(6)
  n.add(6)
  n.add(6)
  n.add(5)
  n.add(6)
  n.add(7)
  n.add(6)
  n.add(5)
  n.add(5)
  n.add(6)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(7)
  n.add(15)
  n.add(11)
  n.add(14)
  n.add(13)
  n.add(28)
  n.add(20)
  n.add(22)
  n.add(20)
  n.add(20)
  n.add(22)
  n.add(22)
  n.add(22)
  n.add(23)
  n.add(22)
  n.add(23)
  n.add(23)
  n.add(23)
  n.add(23)
  n.add(23)
  n.add(24)
  n.add(23)
  n.add(24)
  n.add(24)
  n.add(22)
  n.add(23)
  n.add(24)
  n.add(23)
  n.add(23)
  n.add(23)
  n.add(23)
  n.add(21)
  n.add(22)
  n.add(23)
  n.add(22)
  n.add(23)
  n.add(23)
  n.add(24)
  n.add(22)
  n.add(21)
  n.add(20)
  n.add(22)
  n.add(22)
  n.add(23)
  n.add(23)
  n.add(21)
  n.add(23)
  n.add(22)
  n.add(22)
  n.add(24)
  n.add(21)
  n.add(22)
  n.add(23)
  n.add(23)
  n.add(21)
  n.add(21)
  n.add(22)
  n.add(21)
  n.add(23)
  n.add(22)
  n.add(23)
  n.add(23)
  n.add(20)
  n.add(22)
  n.add(22)
  n.add(22)
  n.add(23)
  n.add(22)
  n.add(22)
  n.add(23)
  n.add(26)
  n.add(26)
  n.add(20)
  n.add(19)
  n.add(22)
  n.add(23)
  n.add(22)
  n.add(25)
  n.add(26)
  n.add(26)
  n.add(26)
  n.add(27)
  n.add(27)
  n.add(26)
  n.add(24)
  n.add(25)
  n.add(19)
  n.add(21)
  n.add(26)
  n.add(27)
  n.add(27)
  n.add(26)
  n.add(27)
  n.add(24)
  n.add(21)
  n.add(21)
  n.add(26)
  n.add(26)
  n.add(28)
  n.add(27)
  n.add(27)
  n.add(27)
  n.add(20)
  n.add(24)
  n.add(20)
  n.add(21)
  n.add(22)
  n.add(21)
  n.add(21)
  n.add(23)
  n.add(22)
  n.add(22)
  n.add(25)
  n.add(25)
  n.add(24)
  n.add(24)
  n.add(26)
  n.add(23)
  n.add(26)
  n.add(27)
  n.add(26)
  n.add(26)
  n.add(27)
  n.add(27)
  n.add(27)
  n.add(27)
  n.add(27)
  n.add(28)
  n.add(27)
  n.add(27)
  n.add(27)
  n.add(27)
  n.add(27)
  n.add(26)
  n.add(30)
  n
}
