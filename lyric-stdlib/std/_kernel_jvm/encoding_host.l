// std/_kernel_jvm/encoding_host.l — JVM host boundary for byte-level encoding.
//
// JVM counterpart of std/_kernel/encoding_host.l.  On JVM, List[Byte].toArray()
// produces a properly-typed array (no List<object>/object[] type-erasure
// mismatch), so pure-Lyric accumulator paths are safe and preferred.
//
// hostGetUtf8Enc returns a sentinel String (unused by the accumulator).
// hostEncodeUtf8 ignores its first argument and encodes the string in pure Lyric.
// hostFromBase64 assumes the caller (Std.Encoding.tryDecodeBase64) has already
// validated the input; it only decodes without re-validating.
//
// Internal: only Std.Encoding should import this.

@axiom("JVM List[Byte].toArray() produces a properly typed byte array; pure-Lyric accumulators are safe on JVM")
package Std.EncodingHost

import Std.Core
import Std.Char
import Std.Collections

// Sentinel charset name; the JVM accumulator in hostEncodeUtf8 ignores it.
pub func hostGetUtf8Enc(): String {
  "utf-8"
}

// Pure-Lyric UTF-8 encoder (JVM path).  `enc` is a sentinel and is unused.
// Mirrors the original encoding.l accumulator path.  Surrogate pairs are
// encoded as the corresponding 4-byte supplementary-plane sequence.
pub func hostEncodeUtf8(enc: in String, s: in String): slice[Byte] {
  val result: List[Byte] = newList()
  val len = s.length
  var i = 0
  while i < len {
    val cu = toInt(s[i])
    if cu >= 55296 and cu <= 56319 and i + 1 < len {
      val cu2 = toInt(s[i + 1])
      if cu2 >= 56320 and cu2 <= 57343 {
        val cp = 65536 + (cu - 55296) * 1024 + (cu2 - 56320)
        result.add(240 + cp / 262144)
        result.add(128 + (cp / 4096) % 64)
        result.add(128 + (cp / 64) % 64)
        result.add(128 + cp % 64)
        i += 2
      } else {
        result.add(224 + cu / 4096)
        result.add(128 + (cu / 64) % 64)
        result.add(128 + cu % 64)
        i += 1
      }
    } else if cu <= 127 {
      result.add(cu)
      i += 1
    } else if cu <= 2047 {
      result.add(192 + cu / 64)
      result.add(128 + cu % 64)
      i += 1
    } else {
      result.add(224 + cu / 4096)
      result.add(128 + (cu / 64) % 64)
      result.add(128 + cu % 64)
      i += 1
    }
  }
  result.toArray()
}

// Pure-Lyric Base64 decoder (JVM path).
// Assumes the caller has already validated the input (via tryDecodeBase64).
pub func hostFromBase64(s: in String): slice[Byte] {
  val len = s.length
  if len == 0 { return [] }
  val result: List[Byte] = newList()
  var i = 0
  while i < len {
    val c0 = b64v(s[i])
    val c1 = b64v(s[i + 1])
    val ch2 = s[i + 2]
    val ch3 = s[i + 3]
    if ch2 == '=' {
      result.add(c0 * 4 + c1 / 16)
    } else {
      val c2 = b64v(ch2)
      result.add(c0 * 4 + c1 / 16)
      if ch3 == '=' {
        result.add(c1 % 16 * 16 + c2 / 4)
      } else {
        val c3 = b64v(ch3)
        result.add(c1 % 16 * 16 + c2 / 4)
        result.add(c2 % 4 * 64 + c3)
      }
    }
    i += 4
  }
  result.toArray()
}

// Local copy of base64CharValue (avoids a circular import from Std.Encoding).
func b64v(c: in Char): Int {
  val cp = toInt(c)
  if cp >= 65 and cp <= 90  { return cp - 65 }       // A-Z → 0-25
  if cp >= 97 and cp <= 122 { return cp - 97 + 26 }  // a-z → 26-51
  if cp >= 48 and cp <= 57  { return cp - 48 + 52 }  // 0-9 → 52-61
  if cp == 43 { return 62 }                           // +  → 62
  if cp == 47 { return 63 }                           // /  → 63
  return -1
}
