// Std.Hash tests anchored to FIPS 180-4 vectors (regression net for kernel/hex changes).

package Std.Hash.Tests

import Std.Core
import Std.File
import Std.Hash
import Std.Testing

// FIPS 180-4 "abc" vector (uppercase). Wrapped because top-level val isn't supported by the bootstrap parser.
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
  // Unreachable path: asserts Err surface fires rather than panic.
  match sha512OfFile("/this/path/should/never/exist.lyric-hash-test") {
    case Ok(_)  -> assertTrue(false, "expected Err for non-existent file")
    case Err(_) -> ()
  }
}

func testSha512OfFileKnownVector(): Unit {
  val path = "/tmp/lyric-hash-test-abc.txt"
  match writeText(path, "abc") {
    case Ok(_)  -> ()
    case Err(_) -> { assertTrue(false, "could not write temp file"); return }
  }
  match sha512OfFile(path) {
    case Ok(hex) -> assertEqual(hex, sha512Abc(), "sha512OfFile('abc') matches NIST vector")
    case Err(_)  -> assertTrue(false, "expected Ok for readable file")
  }
}

func main(): Int {
  testSha512OfBytesKnownVector()
  testSha512OfBytesEmpty()
  testSha512OfFileNotFound()
  testSha512OfFileKnownVector()
  println("hash tests: ok")
  return 0
}
