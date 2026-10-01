//! Std.Hash tests anchored to FIPS 180-4 vectors (regression net for kernel/hex changes).
package Std.Hash.Tests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.File
import Std.Hash
import Std.Testing
import Std.Uuid as Uuid

// FIPS 180-4 test vectors (uppercase). Wrapped because top-level val isn't supported by the bootstrap parser.
func sha1Abc(): String {
  "A9993E364706816ABA3E25717850C26C9CD0D89D"
}

func sha1Empty(): String {
  "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709"
}

func sha256Abc(): String {
  "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
}

func sha256Empty(): String {
  "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
}

func sha512Abc(): String {
  "DDAF35A193617ABACC417349AE20413112E6FA4E89A97EA20A9EEEE64B55D39A" +
    "2192992A274FC1A836BA3C23A3FEEBBD454D4423643CE80E2A9AC94FA54CA49F"
}

func sha512Empty(): String {
  "CF83E1357EEFB8BDF1542850D66D8007D620E4050B5715DC83F4A921D36CE9CE" +
    "47D0D13C5D85F2B0FF8318D2877EEC2F63B931BD47417A81A538327AF927DA3E"
}

func bytesAbc(): slice[Byte] {
  // ASCII codepoints 0x61 0x62 0x63.
  [97u8, 98u8, 99u8]
}

func testSha1OfBytesKnownVector(): Unit {
  val hex = sha1OfBytes(bytesAbc())
  assertEqual(hex, sha1Abc(), "sha1('abc') matches FIPS 180-4 vector")
}

func testSha1OfBytesEmpty(): Unit {
  val empty: slice[Byte] = []
  val hex = sha1OfBytes(empty)
  assertEqual(hex, sha1Empty(), "sha1('') matches FIPS 180-4 vector")
}

// RFC 6455 section 1.3's worked handshake example: hashing the client's
// Sec-WebSocket-Key concatenated with the magic GUID and Base64-encoding the
// raw digest yields Sec-WebSocket-Accept. This exercises sha1OfBytes' output
// through the same hex-decode -> Base64-encode path `Ws.Handshake` uses (a
// stdlib-level regression net independent of lyric-ws's own tests).
func testSha1SupportsRfc6455HandshakeExample(): Unit {
  val key = "dGhlIHNhbXBsZSBub25jZQ=="
  val guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  val digestHex = sha1OfBytes(encodeUtf8(key + guid))
  match tryDecodeHex(digestHex) {
    case Some(bytes) -> assertEqual(
      encodeBase64(bytes),
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
      "RFC 6455 1.3 Sec-WebSocket-Accept example"
    )
    case None -> assertTrue(false, "sha1OfBytes returned malformed hex")
  }
}

func testSha256OfBytesKnownVector(): Unit {
  val hex = sha256OfBytes(bytesAbc())
  assertEqual(hex, sha256Abc(), "sha256('abc') matches FIPS 180-4 vector")
}

func testSha256OfBytesEmpty(): Unit {
  val empty: slice[Byte] = []
  val hex = sha256OfBytes(empty)
  assertEqual(hex, sha256Empty(), "sha256('') matches FIPS 180-4 vector")
}

func testSha512OfBytesKnownVector(): Unit {
  val hex = sha512OfBytes(bytesAbc())
  assertEqual(hex, sha512Abc(), "sha512('abc') matches NIST vector")
}

func testSha512OfBytesEmpty(): Unit {
  val empty: slice[Byte] = []
  val hex = sha512OfBytes(empty)
  assertEqual(hex, sha512Empty(), "sha512('') matches NIST vector")
}

func testSha512OfFileNotFound(): Unit {
  // Unreachable path: asserts Err surface fires rather than panic.
  match sha512OfFile("/this/path/should/never/exist.lyric-hash-test") {
    case Ok(_) -> assertTrue(false, "expected Err for non-existent file")
    case Err(_) -> ()
  }
}

func testSha512OfFileKnownVector(): Unit {
  // Per-invocation UUID-suffixed temp path so parallel CI runs of the
  // stdlib suite can't collide on the same `/tmp/<name>` (#833).
  val path = "/tmp/lyric-hash-test-abc-" + Uuid.uuidToString(Uuid.newUuid()) + ".txt"
  match writeText(path, "abc") {
    case Ok(_) -> ()
    case Err(_) -> {
      assertTrue(false, "could not write temp file")
      return
    }
  }
  match sha512OfFile(path) {
    case Ok(hex) -> assertEqual(hex, sha512Abc(), "sha512OfFile('abc') matches NIST vector")
    case Err(_) -> assertTrue(false, "expected Ok for readable file")
  }
  // Best-effort cleanup (#845); ignore failures — `/tmp` files are
  // OS-swept eventually and the test has already asserted what it needs.
  match deleteFile(path) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

// The file digest streams in 64 KiB chunks (#7284): a file spanning several
// chunks, with a partial last one, and an empty file must digest exactly as
// the in-memory bytes do.
func assertFileDigestMatchesBytes(size: in Int, label: in String): Unit {
  val bytes: List[Byte] = newListWithCapacity(size)
  var i = 0
  while i < size {
    bytes.add((i * 31 + 7).toByte())
    i = i + 1
  }
  val path = "/tmp/lyric-hash-test-stream-" + Uuid.uuidToString(Uuid.newUuid()) + ".bin"
  match writeBytes(path, bytes.toArray()) {
    case Ok(_) -> ()
    case Err(_) -> {
      assertTrue(false, "could not write temp file for " + label)
      return
    }
  }
  match sha512OfFile(path) {
    case Ok(hex) -> assertEqual(hex, sha512OfBytes(bytes.toArray()), "sha512OfFile matches sha512OfBytes: " + label)
    case Err(e) -> assertTrue(false, "expected Ok for " + label + ", got: " + e)
  }
  match deleteFile(path) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func testSha512OfFileStreamsChunks(): Unit {
  assertFileDigestMatchesBytes(200000, "three full 64 KiB chunks plus a partial one")
  assertFileDigestMatchesBytes(65536, "exactly one chunk")
  assertFileDigestMatchesBytes(0, "empty file")
}

func hexBytes(hex: in String): slice[Byte] {
  match tryDecodeHex(hex) {
    case Some(b) -> b
    case None -> panic("bad hex in test vector: " + hex)
  }
}

func repeatByte(v: in Int, n: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < n {
    acc.add(v.toByte())
    i = i + 1
  }
  acc.toArray()
}

// RFC 4231 HMAC-SHA-256 test cases 1, 2, 4 and 6 (6 has a key longer than
// the 64-byte block, which must be hashed first).
func testHmacSha256Rfc4231(): Unit {
  assertEqual(
    encodeHex(hmacSha256(repeatByte(0x0b, 20), encodeUtf8("Hi There"))),
    "B0344C61D8DB38535CA8AFCEAF0BF12B881DC200C9833DA726E9376C2E32CFF7",
    "RFC 4231 case 1"
  )
  assertEqual(
    encodeHex(hmacSha256(encodeUtf8("Jefe"), encodeUtf8("what do ya want for nothing?"))),
    "5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843",
    "RFC 4231 case 2"
  )
  assertEqual(
    encodeHex(hmacSha256(hexBytes("0102030405060708090A0B0C0D0E0F10111213141516171819"), repeatByte(0xcd, 50))),
    "82558A389A443C0EA4CC819899F2083A85F0FAA3E578F8077A2E3FF46729665B",
    "RFC 4231 case 4"
  )
  assertEqual(
    encodeHex(hmacSha256(repeatByte(0xaa, 131), encodeUtf8("Test Using Larger Than Block-Size Key - Hash Key First"))),
    "60E431591EE0B67F0D8A26AACBF5B77F8E0BC6213728C5140546040F0EE37F54",
    "RFC 4231 case 6 (key longer than the block)"
  )
}

func testSha256Digest(): Unit {
  assertEqual(encodeHex(sha256Digest(bytesAbc())), sha256Abc(), "raw digest matches the hex form")
  assertEqualInt(sha256Digest(bytesAbc()).length, 32, "32 bytes")
}

func testConstantTimeEquals(): Unit {
  val a = hexBytes("00112233")
  assertTrue(constantTimeEquals(a, hexBytes("00112233")), "equal bytes")
  assertTrue(not constantTimeEquals(a, hexBytes("00112234")), "last byte differs")
  assertTrue(not constantTimeEquals(a, hexBytes("80112233")), "first byte differs")
  assertTrue(not constantTimeEquals(a, hexBytes("001122")), "different lengths")
  assertTrue(constantTimeEquals(hexBytes(""), hexBytes("")), "two empty slices")
}

func main(): Int {
  testSha1OfBytesKnownVector()
  testSha1OfBytesEmpty()
  testSha1SupportsRfc6455HandshakeExample()
  testSha256OfBytesKnownVector()
  testSha256OfBytesEmpty()
  testSha512OfBytesKnownVector()
  testSha512OfBytesEmpty()
  testSha512OfFileNotFound()
  testSha512OfFileKnownVector()
  testSha512OfFileStreamsChunks()
  testSha256Digest()
  testHmacSha256Rfc4231()
  testConstantTimeEquals()
  println("hash tests: ok")
  return 0
}
