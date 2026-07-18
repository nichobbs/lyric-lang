//! stdlib/tests/http_hpack_tests.l — RFC 7541 conformance corpus for
//! `Std.HttpEngine.Hpack` (docs/61-https-tls-http-versions.md §6.4, D128;
//! phase 4.1 of epic #5874, issue #5886).
//!
//! This corpus is the HPACK codec's conformance spec, not illustration: it
//! asserts the codec against the **exact byte vectors of RFC 7541 Appendix C**
//! — C.1 (integer representations), C.2 (the four literal representations),
//! C.3/C.4 (request sequences without/with Huffman, sharing one dynamic table
//! across three blocks), and C.5/C.6 (response sequences without/with Huffman
//! at `SETTINGS_HEADER_TABLE_SIZE = 256`, exercising eviction) — checking both
//! the decoded header lists *and* the documented dynamic-table state
//! (entry order, count, size) after each block, in both directions
//! (decode(vector) and encode(list) == vector). It adds encode∘decode
//! round-trip property tests and the adversarial cases issue #5886 names:
//! integer/table-size bombs, an embedded EOS, and invalid Huffman padding.
//!
//! Runs via native `lyric test` on both targets (`--target dotnet` and
//! `--target jvm`) — the codec is pure Lyric with zero externs, so both must
//! produce byte-identical results (a divergence would be a compiler bug, not a
//! codec bug — the `http_engine_tests.l` precedent).
@test_module
package Std.HttpEngine.Hpack.Tests

import Std.Core
import Std.Collections
import Std.String
import Std.Char as Char
import Std.Encoding
import Std.HttpEngine
import Std.HttpEngine.Hpack
import Std.Testing

// ---------------------------------------------------------------------------
// Test infrastructure.
// ---------------------------------------------------------------------------
func hexNibble(c: in Char): Int {
  val v = toInt(c)
  if v >= 48 and v <= 57 {
    v - 48
  } else if v >= 97 and v <= 102 {
    v - 97 + 10
  } else if v >= 65 and v <= 70 {
    v - 65 + 10
  } else {
    -1
  }
}

/// Parse a continuous lowercase/uppercase hex string into bytes.
func hx(s: in String): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i + 1 < s.length {
    match charAt(s, i) {
      case None -> ()
      case Some(hi) -> match charAt(s, i + 1) { case None -> (); case Some(lo) -> acc.add((hexNibble(hi) * 16 + hexNibble(lo)).toByte()) }
    }
    i = i + 2
  }
  acc.toArray()
}

/// ASCII/Latin-1 text to its octet bytes (every Appendix C string is ASCII).
func oc(s: in String): slice[Byte] {
  encodeUtf8(s)
}

func toHexString(bytes: in slice[Byte]): String {
  var acc = ""
  var i = 0
  while i < bytes.length {
    val v = bytes[i].toInt()
    acc = acc + ("" + Char.fromInt(hexDigit(v / 16))) + ("" + Char.fromInt(hexDigit(v % 16)))
    i = i + 1
  }
  acc
}

func hexDigit(v: in Int): Int {
  if v < 10 {
    48 + v
  } else {
    97 + (v - 10)
  }
}

func bytesEqual(a: in slice[Byte], b: in slice[Byte]): Bool {
  if a.length != b.length {
    return false
  }
  var i = 0
  while i < a.length {
    if a[i].toInt() != b[i].toInt() {
      return false
    }
    i = i + 1
  }
  true
}

func assertBytesHex(actual: in slice[Byte], expectedHex: in String, label: in String): Unit {
  assertTrue(bytesEqual(actual, hx(expectedHex)), label + ": expected " + expectedHex + " got " + toHexString(actual))
}

func errName(e: in HpackError): String {
  match e {
    case IncompleteInput -> "IncompleteInput"
    case IntegerOverflow -> "IntegerOverflow"
    case InvalidIndex(_) -> "InvalidIndex"
    case InvalidHuffmanPadding -> "InvalidHuffmanPadding"
    case InvalidHuffmanCode -> "InvalidHuffmanCode"
    case HuffmanEosSymbol -> "HuffmanEosSymbol"
    case TableSizeUpdateTooLarge(_, _) -> "TableSizeUpdateTooLarge"
    case SizeUpdateAfterHeader -> "SizeUpdateAfterHeader"
    case NonOctetValue(_) -> "NonOctetValue"
  }
}

func decodeBlock(decoder: inout HpackDecoder, block: in slice[Byte], label: in String): List[HeaderField] {
  match decodeHeaderBlock(decoder, block) {
    case Ok(hs) -> hs
    case Err(e) -> panic(label + ": unexpected decode error " + errName(e))
  }
}

func encodeList(encoder: inout HpackEncoder, headers: in List[HeaderField], label: in String): slice[Byte] {
  match encodeHeaderList(encoder, headers) {
    case Ok(b) -> b
    case Err(e) -> panic(label + ": unexpected encode error " + errName(e))
  }
}

func assertHeader(headers: in List[HeaderField], idx: in Int, name: in String, value: in String, label: in String): Unit {
  assertTrue(idx < headers.count, label + ": header index " + toString(idx) + " in range")
  val h = headers[idx]
  assertEqual(h.name, name, label + ": name[" + toString(idx) + "]")
  assertEqual(h.value, value, label + ": value[" + toString(idx) + "]")
}

func assertDynEntry(table: in DynamicTable, i: in Int, name: in String, value: in String, label: in String): Unit {
  match dynamicTableEntry(table, i) {
    case Some(hf) -> {
      assertEqual(hf.name, name, label + ": dyn[" + toString(i) + "] name")
      assertEqual(hf.value, value, label + ": dyn[" + toString(i) + "] value")
    }
    case None -> panic(label + ": expected dynamic entry at " + toString(i))
  }
}

func h(name: in String, value: in String): HeaderField {
  HeaderField(name = name, value = value)
}

func assertDecodeErr(block: in slice[Byte], maxSize: in Int, expected: in String, label: in String): Unit {
  var decoder = newDecoder(maxSize)
  match decodeHeaderBlock(decoder, block) {
    case Ok(_) -> panic(label + ": expected error " + expected)
    case Err(e) -> assertEqual(errName(e), expected, label)
  }
}

// ---------------------------------------------------------------------------
// C.1 — Integer representation examples.
// ---------------------------------------------------------------------------
test "C.1.1 encode 10 with a 5-bit prefix is 0x0a" {
  assertBytesHex(encodeInteger(10, 5), "0a", "C.1.1")
}

test "C.1.2 encode 1337 with a 5-bit prefix is 0x1f9a0a" {
  assertBytesHex(encodeInteger(1337, 5), "1f9a0a", "C.1.2")
}

test "C.1.3 encode 42 with an 8-bit prefix is 0x2a" {
  assertBytesHex(encodeInteger(42, 8), "2a", "C.1.3")
}

test "C.1 integer decode round-trips the three examples with correct offsets" {
  match decodeIntegerAt(hx("0a"), 0, 5) {
    case Ok(r) -> {
      assertEqualInt(r.value, 10, "C.1.1 decode value")
      assertEqualInt(r.offset, 1, "C.1.1 decode offset")
    }
    case Err(_) -> panic("C.1.1 decode failed")
  }
  match decodeIntegerAt(hx("1f9a0a"), 0, 5) {
    case Ok(r) -> {
      assertEqualInt(r.value, 1337, "C.1.2 decode value")
      assertEqualInt(r.offset, 3, "C.1.2 decode offset")
    }
    case Err(_) -> panic("C.1.2 decode failed")
  }
  match decodeIntegerAt(hx("2a"), 0, 8) {
    case Ok(r) -> assertEqualInt(r.value, 42, "C.1.3 decode value")
    case Err(_) -> panic("C.1.3 decode failed")
  }
}

test "integer encode-then-decode is identity across prefixes and magnitudes" {
  val vals: List[Int] = newList()
  vals.add(0)
  vals.add(1)
  vals.add(30)
  vals.add(31)
  vals.add(127)
  vals.add(128)
  vals.add(255)
  vals.add(1337)
  vals.add(16384)
  vals.add(1000000)
  val prefixes: List[Int] = newList()
  prefixes.add(5)
  prefixes.add(6)
  prefixes.add(7)
  prefixes.add(8)
  var pi = 0
  while pi < prefixes.count {
    val p = prefixes[pi]
    var vi = 0
    while vi < vals.count {
      val v = vals[vi]
      match decodeIntegerAt(encodeInteger(v, p), 0, p) {
        case Ok(r) -> assertEqualInt(r.value, v, "int round-trip v=" + toString(v) + " p=" + toString(p))
        case Err(e) -> panic("int round-trip decode failed: " + errName(e))
      }
      vi = vi + 1
    }
    pi = pi + 1
  }
}

// ---------------------------------------------------------------------------
// Huffman coding — known Appendix C substrings + round trip.
// ---------------------------------------------------------------------------
test "huffmanEncode matches the RFC 7541 Appendix C Huffman substrings" {
  assertBytesHex(huffmanEncode(oc("www.example.com")), "f1e3c2e5f23a6ba0ab90f4ff", "huff www.example.com")
  assertBytesHex(huffmanEncode(oc("no-cache")), "a8eb10649cbf", "huff no-cache")
  assertBytesHex(huffmanEncode(oc("custom-key")), "25a849e95ba97d7f", "huff custom-key")
  assertBytesHex(huffmanEncode(oc("custom-value")), "25a849e95bb8e8b4bf", "huff custom-value")
  assertBytesHex(huffmanEncode(oc("private")), "aec3771a4b", "huff private")
  assertBytesHex(huffmanEncode(oc("302")), "6402", "huff 302")
  assertBytesHex(huffmanEncode(oc("307")), "640eff", "huff 307")
  assertBytesHex(huffmanEncode(oc("gzip")), "9bd9ab", "huff gzip")
  assertBytesHex(huffmanEncode(oc("https://www.example.com")), "9d29ad171863c78f0b97c8e9ae82ae43d3", "huff location")
  assertBytesHex(
    huffmanEncode(oc("Mon, 21 Oct 2013 20:13:21 GMT")),
    "d07abe941054d444a8200595040b8166e082a62d1bff",
    "huff date"
  )
}

test "huffmanDecode inverts the known substrings" {
  match huffmanDecode(hx("f1e3c2e5f23a6ba0ab90f4ff")) {
    case Ok(d) -> assertEqual(octetsToString(d), "www.example.com", "huff decode www.example.com")
    case Err(e) -> panic("huff decode failed: " + errName(e))
  }
  match huffmanDecode(hx("9d29ad171863c78f0b97c8e9ae82ae43d3")) {
    case Ok(d) -> assertEqual(octetsToString(d), "https://www.example.com", "huff decode location")
    case Err(e) -> panic("huff decode failed: " + errName(e))
  }
}

test "huffman round-trips every octet value 0..255" {
  val all: List[Byte] = newList()
  var i = 0
  while i < 256 {
    all.add(i.toByte())
    i = i + 1
  }
  val src = all.toArray()
  match huffmanDecode(huffmanEncode(src)) {
    case Ok(d) -> assertTrue(bytesEqual(d, src), "all-256-octet huffman round trip")
    case Err(e) -> panic("all-256 huffman decode failed: " + errName(e))
  }
}

// ---------------------------------------------------------------------------
// String literal representation.
// ---------------------------------------------------------------------------
test "encodeStringLiteral raw and Huffman forms match the wire" {
  assertBytesHex(encodeStringLiteral(oc("custom-key"), false), "0a637573746f6d2d6b6579", "raw string literal")
  assertBytesHex(
    encodeStringLiteral(oc("www.example.com"), true),
    "8cf1e3c2e5f23a6ba0ab90f4ff",
    "huffman string literal"
  )
}

test "decodeStringLiteralAt inverts both forms with correct offsets" {
  match decodeStringLiteralAt(hx("0a637573746f6d2d6b6579"), 0) {
    case Ok(r) -> {
      assertEqual(octetsToString(r.octets), "custom-key", "raw string decode")
      assertEqualInt(r.offset, 11, "raw string decode offset")
    }
    case Err(e) -> panic("raw string decode failed: " + errName(e))
  }
  match decodeStringLiteralAt(hx("8cf1e3c2e5f23a6ba0ab90f4ff"), 0) {
    case Ok(r) -> assertEqual(octetsToString(r.octets), "www.example.com", "huffman string decode")
    case Err(e) -> panic("huffman string decode failed: " + errName(e))
  }
}

// ---------------------------------------------------------------------------
// Static table (RFC 7541 Appendix A).
// ---------------------------------------------------------------------------
test "static table has the documented entries and size" {
  assertEqualInt(staticTableSize(), 61, "static table size")
  match staticTableEntry(1) {
    case Some(hf) -> {
      assertEqual(hf.name, ":authority", "static[1] name")
      assertEqual(hf.value, "", "static[1] value")
    }
    case None -> panic("static[1] missing")
  }
  match staticTableEntry(2) {
    case Some(hf) -> assertEqual(hf.value, "GET", "static[2] value")
    case None -> panic("static[2] missing")
  }
  match staticTableEntry(16) {
    case Some(hf) -> assertEqual(hf.value, "gzip, deflate", "static[16] value")
    case None -> panic("static[16] missing")
  }
  match staticTableEntry(61) {
    case Some(hf) -> assertEqual(hf.name, "www-authenticate", "static[61] name")
    case None -> panic("static[61] missing")
  }
  match staticTableEntry(62) {
    case Some(_) -> panic("static[62] should not exist")
    case None -> assertTrue(true, "static[62] absent")
  }
  match staticTableEntry(0) {
    case Some(_) -> panic("static[0] should not exist")
    case None -> assertTrue(true, "static[0] absent")
  }
}

// ---------------------------------------------------------------------------
// C.2 — the four header-field representations.
// ---------------------------------------------------------------------------
test "C.2.1 literal with incremental indexing (literal name) decodes and re-encodes" {
  val block = hx("400a637573746f6d2d6b65790d637573746f6d2d686561646572")
  var decoder = newDecoder(4096)
  val hs = decodeBlock(decoder, block, "C.2.1")
  assertEqualInt(hs.count, 1, "C.2.1 count")
  assertHeader(hs, 0, "custom-key", "custom-header", "C.2.1")
  val table = decoderDynamicTable(decoder)
  assertEqualInt(dynamicTableCount(table), 1, "C.2.1 table count")
  assertEqualInt(dynamicTableSize(table), 55, "C.2.1 table size")
  assertDynEntry(table, 0, "custom-key", "custom-header", "C.2.1")

  var encoder = newEncoder(4096, false)
  val hl: List[HeaderField] = newList()
  hl.add(h("custom-key", "custom-header"))
  assertBytesHex(
    encodeList(encoder, hl, "C.2.1 encode"),
    "400a637573746f6d2d6b65790d637573746f6d2d686561646572",
    "C.2.1 encode"
  )
}

test "C.2.2 literal without indexing (indexed name) decodes; low-level encoder reproduces it" {
  val block = hx("040c2f73616d706c652f70617468")
  var decoder = newDecoder(4096)
  val hs = decodeBlock(decoder, block, "C.2.2")
  assertHeader(hs, 0, ":path", "/sample/path", "C.2.2")
  assertEqualInt(dynamicTableCount(decoderDynamicTable(decoder)), 0, "C.2.2 table stays empty")

  val enc = encodeLiteralWithoutIndexing(Some(value = 4), oc(""), oc("/sample/path"), false)
  assertBytesHex(enc, "040c2f73616d706c652f70617468", "C.2.2 encode")
}

test "C.2.3 literal never indexed (literal name) decodes; low-level encoder reproduces it" {
  val block = hx("100870617373776f726406736563726574")
  var decoder = newDecoder(4096)
  val hs = decodeBlock(decoder, block, "C.2.3")
  assertHeader(hs, 0, "password", "secret", "C.2.3")
  assertEqualInt(dynamicTableCount(decoderDynamicTable(decoder)), 0, "C.2.3 table stays empty")

  val enc = encodeLiteralNeverIndexed(None, oc("password"), oc("secret"), false)
  assertBytesHex(enc, "100870617373776f726406736563726574", "C.2.3 encode")
}

test "C.2.4 indexed header field decodes; encodeIndexedField reproduces it" {
  val block = hx("82")
  var decoder = newDecoder(4096)
  val hs = decodeBlock(decoder, block, "C.2.4")
  assertHeader(hs, 0, ":method", "GET", "C.2.4")
  assertEqualInt(dynamicTableCount(decoderDynamicTable(decoder)), 0, "C.2.4 table stays empty")
  assertBytesHex(encodeIndexedField(2), "82", "C.2.4 encode")
}

// ---------------------------------------------------------------------------
// C.3 — request sequence without Huffman (one shared dynamic table).
// ---------------------------------------------------------------------------
func req1(): List[HeaderField] {
  val hl: List[HeaderField] = newList()
  hl.add(h(":method", "GET"))
  hl.add(h(":scheme", "http"))
  hl.add(h(":path", "/"))
  hl.add(h(":authority", "www.example.com"))
  hl
}

func req2(): List[HeaderField] {
  val hl: List[HeaderField] = newList()
  hl.add(h(":method", "GET"))
  hl.add(h(":scheme", "http"))
  hl.add(h(":path", "/"))
  hl.add(h(":authority", "www.example.com"))
  hl.add(h("cache-control", "no-cache"))
  hl
}

func req3(): List[HeaderField] {
  val hl: List[HeaderField] = newList()
  hl.add(h(":method", "GET"))
  hl.add(h(":scheme", "https"))
  hl.add(h(":path", "/index.html"))
  hl.add(h(":authority", "www.example.com"))
  hl.add(h("custom-key", "custom-value"))
  hl
}

test "C.3 request sequence decodes with the documented dynamic-table evolution" {
  var decoder = newDecoder(4096)

  val h1 = decodeBlock(decoder, hx("828684410f7777772e6578616d706c652e636f6d"), "C.3.1")
  assertEqualInt(h1.count, 4, "C.3.1 count")
  assertHeader(h1, 3, ":authority", "www.example.com", "C.3.1")
  var t = decoderDynamicTable(decoder)
  assertEqualInt(dynamicTableCount(t), 1, "C.3.1 table count")
  assertEqualInt(dynamicTableSize(t), 57, "C.3.1 table size")
  assertDynEntry(t, 0, ":authority", "www.example.com", "C.3.1")

  val h2 = decodeBlock(decoder, hx("828684be58086e6f2d6361636865"), "C.3.2")
  assertHeader(h2, 4, "cache-control", "no-cache", "C.3.2")
  t = decoderDynamicTable(decoder)
  assertEqualInt(dynamicTableCount(t), 2, "C.3.2 table count")
  assertEqualInt(dynamicTableSize(t), 110, "C.3.2 table size")
  assertDynEntry(t, 0, "cache-control", "no-cache", "C.3.2")
  assertDynEntry(t, 1, ":authority", "www.example.com", "C.3.2")

  val h3 = decodeBlock(decoder, hx("828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565"), "C.3.3")
  assertHeader(h3, 2, ":path", "/index.html", "C.3.3")
  assertHeader(h3, 4, "custom-key", "custom-value", "C.3.3")
  t = decoderDynamicTable(decoder)
  assertEqualInt(dynamicTableCount(t), 3, "C.3.3 table count")
  assertEqualInt(dynamicTableSize(t), 164, "C.3.3 table size")
  assertDynEntry(t, 0, "custom-key", "custom-value", "C.3.3")
  assertDynEntry(t, 2, ":authority", "www.example.com", "C.3.3")
}

test "C.3 request sequence encodes byte-for-byte" {
  var encoder = newEncoder(4096, false)
  assertBytesHex(encodeList(encoder, req1(), "C.3.1 enc"), "828684410f7777772e6578616d706c652e636f6d", "C.3.1 enc")
  assertBytesHex(encodeList(encoder, req2(), "C.3.2 enc"), "828684be58086e6f2d6361636865", "C.3.2 enc")
  assertBytesHex(
    encodeList(encoder, req3(), "C.3.3 enc"),
    "828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565",
    "C.3.3 enc"
  )
}

// ---------------------------------------------------------------------------
// C.4 — request sequence with Huffman.
// ---------------------------------------------------------------------------
test "C.4 request sequence encodes byte-for-byte with Huffman literals" {
  var encoder = newEncoder(4096, true)
  assertBytesHex(encodeList(encoder, req1(), "C.4.1 enc"), "828684418cf1e3c2e5f23a6ba0ab90f4ff", "C.4.1 enc")
  assertBytesHex(encodeList(encoder, req2(), "C.4.2 enc"), "828684be5886a8eb10649cbf", "C.4.2 enc")
  assertBytesHex(
    encodeList(encoder, req3(), "C.4.3 enc"),
    "828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf",
    "C.4.3 enc"
  )
}

test "C.4 request sequence decodes back to the original header lists" {
  var decoder = newDecoder(4096)
  val h1 = decodeBlock(decoder, hx("828684418cf1e3c2e5f23a6ba0ab90f4ff"), "C.4.1")
  assertHeader(h1, 3, ":authority", "www.example.com", "C.4.1")
  val h2 = decodeBlock(decoder, hx("828684be5886a8eb10649cbf"), "C.4.2")
  assertHeader(h2, 4, "cache-control", "no-cache", "C.4.2")
  val h3 = decodeBlock(decoder, hx("828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf"), "C.4.3")
  assertHeader(h3, 4, "custom-key", "custom-value", "C.4.3")
  assertEqualInt(dynamicTableSize(decoderDynamicTable(decoder)), 164, "C.4 final table size")
}

// ---------------------------------------------------------------------------
// C.5 — response sequence without Huffman, table size 256 (eviction).
// ---------------------------------------------------------------------------
func resp1(): List[HeaderField] {
  val hl: List[HeaderField] = newList()
  hl.add(h(":status", "302"))
  hl.add(h("cache-control", "private"))
  hl.add(h("date", "Mon, 21 Oct 2013 20:13:21 GMT"))
  hl.add(h("location", "https://www.example.com"))
  hl
}

func resp2(): List[HeaderField] {
  val hl: List[HeaderField] = newList()
  hl.add(h(":status", "307"))
  hl.add(h("cache-control", "private"))
  hl.add(h("date", "Mon, 21 Oct 2013 20:13:21 GMT"))
  hl.add(h("location", "https://www.example.com"))
  hl
}

func resp3(): List[HeaderField] {
  val hl: List[HeaderField] = newList()
  hl.add(h(":status", "200"))
  hl.add(h("cache-control", "private"))
  hl.add(h("date", "Mon, 21 Oct 2013 20:13:22 GMT"))
  hl.add(h("location", "https://www.example.com"))
  hl.add(h("content-encoding", "gzip"))
  hl.add(h("set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"))
  hl
}

val c51: String = "4803333032580770726976617465611d4d6f6e2c203231204f637420323031332032303a31333a323120474d546e1768747470733a2f2f7777772e6578616d706c652e636f6d"

val c52: String = "4803333037c1c0bf"

val c53: String = "88c1611d4d6f6e2c203231204f637420323031332032303a31333a323220474d54c05a04677a69707738666f6f3d4153444a4b48514b425a584f5157454f50495541585157454f49553b206d61782d6167653d333630303b2076657273696f6e3d31"

test "C.5 response sequence decodes with eviction and the documented table states" {
  var decoder = newDecoder(256)

  val r1 = decodeBlock(decoder, hx(c51), "C.5.1")
  assertEqualInt(r1.count, 4, "C.5.1 count")
  assertHeader(r1, 0, ":status", "302", "C.5.1")
  assertHeader(r1, 3, "location", "https://www.example.com", "C.5.1")
  var t = decoderDynamicTable(decoder)
  assertEqualInt(dynamicTableCount(t), 4, "C.5.1 table count")
  assertEqualInt(dynamicTableSize(t), 222, "C.5.1 table size")
  assertDynEntry(t, 0, "location", "https://www.example.com", "C.5.1")
  assertDynEntry(t, 3, ":status", "302", "C.5.1")

  val r2 = decodeBlock(decoder, hx(c52), "C.5.2")
  assertHeader(r2, 0, ":status", "307", "C.5.2")
  assertHeader(r2, 1, "cache-control", "private", "C.5.2")
  t = decoderDynamicTable(decoder)
  assertEqualInt(dynamicTableCount(t), 4, "C.5.2 table count")
  assertEqualInt(dynamicTableSize(t), 222, "C.5.2 table size")
  assertDynEntry(t, 0, ":status", "307", "C.5.2")
  assertDynEntry(t, 3, "cache-control", "private", "C.5.2")

  val r3 = decodeBlock(decoder, hx(c53), "C.5.3")
  assertEqualInt(r3.count, 6, "C.5.3 count")
  assertHeader(r3, 0, ":status", "200", "C.5.3")
  assertHeader(r3, 5, "set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1", "C.5.3")
  t = decoderDynamicTable(decoder)
  assertEqualInt(dynamicTableCount(t), 3, "C.5.3 table count")
  assertEqualInt(dynamicTableSize(t), 215, "C.5.3 table size")
  assertDynEntry(t, 0, "set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1", "C.5.3")
  assertDynEntry(t, 1, "content-encoding", "gzip", "C.5.3")
  assertDynEntry(t, 2, "date", "Mon, 21 Oct 2013 20:13:22 GMT", "C.5.3")
}

test "C.5 response sequence encodes byte-for-byte with eviction" {
  var encoder = newEncoder(256, false)
  assertBytesHex(encodeList(encoder, resp1(), "C.5.1 enc"), c51, "C.5.1 enc")
  assertBytesHex(encodeList(encoder, resp2(), "C.5.2 enc"), c52, "C.5.2 enc")
  assertBytesHex(encodeList(encoder, resp3(), "C.5.3 enc"), c53, "C.5.3 enc")
}

// ---------------------------------------------------------------------------
// C.6 — response sequence with Huffman, table size 256 (same evictions).
// ---------------------------------------------------------------------------
val c61: String = "488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3"

val c62: String = "4883640effc1c0bf"

val c63: String = "88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007"

test "C.6 response sequence encodes byte-for-byte with Huffman literals" {
  var encoder = newEncoder(256, true)
  assertBytesHex(encodeList(encoder, resp1(), "C.6.1 enc"), c61, "C.6.1 enc")
  assertBytesHex(encodeList(encoder, resp2(), "C.6.2 enc"), c62, "C.6.2 enc")
  assertBytesHex(encodeList(encoder, resp3(), "C.6.3 enc"), c63, "C.6.3 enc")
}

test "C.6 response sequence decodes with the documented eviction states" {
  var decoder = newDecoder(256)
  val r1 = decodeBlock(decoder, hx(c61), "C.6.1")
  assertHeader(r1, 0, ":status", "302", "C.6.1")
  assertHeader(r1, 2, "date", "Mon, 21 Oct 2013 20:13:21 GMT", "C.6.1")
  assertEqualInt(dynamicTableSize(decoderDynamicTable(decoder)), 222, "C.6.1 table size")

  val r2 = decodeBlock(decoder, hx(c62), "C.6.2")
  assertHeader(r2, 0, ":status", "307", "C.6.2")
  assertEqualInt(dynamicTableSize(decoderDynamicTable(decoder)), 222, "C.6.2 table size")

  val r3 = decodeBlock(decoder, hx(c63), "C.6.3")
  assertEqualInt(r3.count, 6, "C.6.3 count")
  assertHeader(r3, 5, "set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1", "C.6.3")
  val t = decoderDynamicTable(decoder)
  assertEqualInt(dynamicTableCount(t), 3, "C.6.3 table count")
  assertEqualInt(dynamicTableSize(t), 215, "C.6.3 table size")
}

// ---------------------------------------------------------------------------
// Encode ∘ decode round-trip property tests.
// ---------------------------------------------------------------------------
func assertRoundTrip(headers: in List[HeaderField], huffman: in Bool, label: in String): Unit {
  var encoder = newEncoder(4096, huffman)
  var decoder = newDecoder(4096)
  val block = encodeList(encoder, headers, label + " enc")
  val decoded = decodeBlock(decoder, block, label + " dec")
  assertEqualInt(decoded.count, headers.count, label + ": count")
  var i = 0
  while i < headers.count {
    assertHeader(decoded, i, headers[i].name, headers[i].value, label)
    i = i + 1
  }
}

test "encode then decode is identity (raw and Huffman) for a varied header list" {
  val hl: List[HeaderField] = newList()
  hl.add(h(":method", "POST"))
  hl.add(h(":scheme", "https"))
  hl.add(h(":path", "/api/v1/resource?q=1"))
  hl.add(h(":authority", "api.example.org"))
  hl.add(h("content-type", "application/json"))
  hl.add(h("content-length", "1024"))
  hl.add(h("x-request-id", "abc-123-DEF-456"))
  hl.add(h("accept", "*/*"))
  hl.add(h("user-agent", "lyric-hpack/1.0 (test)"))
  assertRoundTrip(hl, false, "roundtrip raw")
  assertRoundTrip(hl, true, "roundtrip huffman")
}

test "encode then decode is identity across a multi-block session with eviction" {
  var encoder = newEncoder(128, true)
  var decoder = newDecoder(128)
  var blockNo = 0
  while blockNo < 5 {
    val hl: List[HeaderField] = newList()
    hl.add(h(":method", "GET"))
    hl.add(h(":path", "/p/" + toString(blockNo)))
    hl.add(h("x-token", "value-" + toString(blockNo)))
    val block = encodeList(encoder, hl, "session enc " + toString(blockNo))
    val decoded = decodeBlock(decoder, block, "session dec " + toString(blockNo))
    assertEqualInt(decoded.count, 3, "session block count " + toString(blockNo))
    assertHeader(decoded, 0, ":method", "GET", "session " + toString(blockNo))
    assertHeader(decoded, 1, ":path", "/p/" + toString(blockNo), "session " + toString(blockNo))
    assertHeader(decoded, 2, "x-token", "value-" + toString(blockNo), "session " + toString(blockNo))
    blockNo = blockNo + 1
  }
}

// ---------------------------------------------------------------------------
// SETTINGS_HEADER_TABLE_SIZE interaction / dynamic table size updates.
// ---------------------------------------------------------------------------
test "a dynamic table size update in a block resizes the decoder table" {
  var decoder = newDecoder(4096)
  // Size update to 100, then :method GET indexed.
  val block = hx("3f4582")
  val hs = decodeBlock(decoder, block, "size update")
  assertHeader(hs, 0, ":method", "GET", "size update header")
  assertEqualInt(dynamicTableMaxSize(decoderDynamicTable(decoder)), 100, "table max resized to 100")
}

test "encoderSetMaxTableSize queues a size update emitted at the head of the next block" {
  var encoder = newEncoder(256, false)
  match encoderSetMaxTableSize(encoder, 100) {
    case Ok(_) -> assertTrue(true, "resize accepted")
    case Err(e) -> panic("resize rejected: " + errName(e))
  }
  val hl: List[HeaderField] = newList()
  hl.add(h(":method", "GET"))
  // 0x3f 0x45 = dynamic table size update to 100; 0x82 = :method GET.
  assertBytesHex(encodeList(encoder, hl, "queued update"), "3f4582", "queued size update")
}

test "a size update above the negotiated ceiling is rejected" {
  // Size update to 300 with a ceiling of 256.
  assertDecodeErr(hx("3f8d02"), 256, "TableSizeUpdateTooLarge", "size update over ceiling")
}

test "a size update after a header field is rejected" {
  // 0x82 (:method GET) then 0x20 (size update to 0).
  assertDecodeErr(hx("8220"), 4096, "SizeUpdateAfterHeader", "size update after header")
}

test "an entry larger than the whole table empties it without being added" {
  var decoder = newDecoder(40)
  // Literal incremental indexing, literal name "aa" value "bb": cost 2+2+32=36 <= 40, fits.
  val fits = decodeBlock(decoder, hx("40026161026262"), "small entry fits")
  assertHeader(fits, 0, "aa", "bb", "small entry")
  assertEqualInt(dynamicTableCount(decoderDynamicTable(decoder)), 1, "small entry present")
  // Now a bigger entry name "aaaaa" value "bbbbb": cost 5+5+32=42 > 40 -> table emptied, not added.
  val big = decodeBlock(decoder, hx("40056161616161056262626262"), "oversized entry empties table")
  assertHeader(big, 0, "aaaaa", "bbbbb", "oversized entry still decoded")
  assertEqualInt(dynamicTableCount(decoderDynamicTable(decoder)), 0, "table emptied by oversized entry")
}

// ---------------------------------------------------------------------------
// Adversarial / malformed input (issue #5886).
// ---------------------------------------------------------------------------
test "an integer with an unterminated continuation run is IntegerOverflow" {
  // 5-bit prefix all ones, then five 0xff continuation bytes -> overflow guard.
  match decodeIntegerAt(hx("1fffffffffff"), 0, 5) {
    case Ok(_) -> panic("expected IntegerOverflow")
    case Err(e) -> assertEqual(errName(e), "IntegerOverflow", "integer bomb")
  }
}

test "a truncated integer continuation is IncompleteInput" {
  match decodeIntegerAt(hx("1fff"), 0, 5) {
    case Ok(_) -> panic("expected IncompleteInput")
    case Err(e) -> assertEqual(errName(e), "IncompleteInput", "truncated integer")
  }
}

test "an indexed field with index 0 is InvalidIndex" {
  assertDecodeErr(hx("80"), 4096, "InvalidIndex", "indexed zero")
}

test "an out-of-range dynamic index is InvalidIndex" {
  // 0xbf = indexed 63, but the dynamic table is empty.
  assertDecodeErr(hx("bf"), 4096, "InvalidIndex", "dynamic index out of range")
}

test "a Huffman string containing the EOS symbol is HuffmanEosSymbol" {
  // 32 one-bits: the 30-bit EOS code completes before the input ends.
  match huffmanDecode(hx("ffffffff")) {
    case Ok(_) -> panic("expected HuffmanEosSymbol")
    case Err(e) -> assertEqual(errName(e), "HuffmanEosSymbol", "eos in input")
  }
}

test "Huffman padding that is not all ones is InvalidHuffmanPadding" {
  // 0x00 = symbol '0' (00000) then trailing 000 padding, which is not all-ones.
  match huffmanDecode(hx("00")) {
    case Ok(_) -> panic("expected InvalidHuffmanPadding")
    case Err(e) -> assertEqual(errName(e), "InvalidHuffmanPadding", "non-ones padding")
  }
}

test "Huffman padding longer than 7 bits is InvalidHuffmanPadding" {
  // 0x07 = '0' (00000) + 3 ones; 0xff = 8 more ones => 11 trailing bits.
  match huffmanDecode(hx("07ff")) {
    case Ok(_) -> panic("expected InvalidHuffmanPadding")
    case Err(e) -> assertEqual(errName(e), "InvalidHuffmanPadding", "over-long padding")
  }
}

test "a string literal claiming more bytes than remain is IncompleteInput" {
  // 0x05 = raw literal length 5, but only 2 bytes follow.
  match decodeStringLiteralAt(hx("056161"), 0) {
    case Ok(_) -> panic("expected IncompleteInput")
    case Err(e) -> assertEqual(errName(e), "IncompleteInput", "truncated string literal")
  }
}

test "stringToOctets rejects a code point above 255" {
  // U+0100 (code point 256) exceeds the 0..255 octet range.
  val s = "x" + ("" + Char.fromInt(256))
  match stringToOctets(s) {
    case Ok(_) -> panic("expected NonOctetValue")
    case Err(e) -> assertEqual(errName(e), "NonOctetValue", "non-octet code point")
  }
}
