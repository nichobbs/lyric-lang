// stdlib/tests/hash_tests.l — Tests for Std.Hash (SHA-512).
//
// Anchors the digest output against the canonical NIST test vector
// (`abc` → DDAF...A38B) so any future regression in the kernel or
// hex formatting surfaces immediately.

package Std.Hash.Tests

import Std.Core
import Std.Hash
import Std.Testing

// SHA-512("abc") — canonical NIST FIPS 180-4 test vector, uppercase.
// Wrapped in a function because top-level `val` constants are not
// supported by the bootstrap parser today.
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
  // Path that cannot exist on any sane host — confirms the Err
  // surface fires rather than panicking.
  match sha512OfFile("/this/path/should/never/exist.lyric-hash-test") {
    case Ok(_)  -> assertTrue(false, "expected Err for non-existent file")
    case Err(_) -> ()
  }
}

func main(): Int {
  testSha512OfBytesKnownVector()
  testSha512OfBytesEmpty()
  testSha512OfFileNotFound()
  println("hash tests: ok")
  return 0
}
