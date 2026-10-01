//! std/_kernel_jvm/encoding_host.l — JVM host boundary for byte-level encoding.
//!
//! JVM counterpart of std/_kernel/encoding_host.l.  On JVM, List[Byte].toArray()
//! produces a properly-typed array (no List<object>/object[] type-erasure
//! mismatch), so pure-Lyric accumulator paths are safe and preferred.
//!
//! hostGetUtf8Enc returns a sentinel String (unused by the accumulator).
//! hostEncodeUtf8 ignores its first argument; it encodes through the JDK's
//! UTF-8 encoder unless the string holds a lone surrogate (see there).
//! hostFromBase64 assumes the caller (Std.Encoding.tryDecodeBase64) has already
//! validated the input; it only decodes without re-validating.
//!
//! Internal: only Std.Encoding should import this.
@axiom("JVM List[Byte].toArray() produces a properly typed byte array and java.lang.String.getBytes(\"UTF-8\") conforms to its documented JVM contract; pure-Lyric accumulators are safe on JVM")
@pure
package Std.EncodingHost

import Std.Core
import Std.Char
import Std.Collections

extern type JChar = "java.lang.Character"

// Sentinel charset name; the JVM accumulator in hostEncodeUtf8 ignores it.
pub func hostGetUtf8Enc(): String {
  "utf-8"
}

// Returns the UTF-16 code unit at `i` as an `Int` (`s.codeUnitAt(i)`,
// surrogate halves included — `s[i]` rejects those, since a surrogate half is
// not a `Char`, and the input here is untrusted text).  `Std.Encoding` calls
// this one cross-target primitive; the native twin
// (`_kernel_native/encoding_host.l`) reads a UTF-8 byte instead.
pub func hostCharCodeAt(s: in String, i: in Int): Int {
  s.codeUnitAt(i)
}

// Returns the String representation of a full Unicode scalar value
// (0..0x10FFFF, already validated by the caller), correctly encoded as a
// surrogate pair when `cp` is outside the BMP.  `Character.toString(int)`
// is the exact JDK primitive for this; the native twin needs this
// cross-target surface because neither `String + Char` concatenation nor
// `Char.toString()` is a supported codegen shape there (see that file's
// header) and native's `lyric_string_from_char` seam takes a full scalar
// value directly rather than a UTF-16 Char.
pub func hostStringFromCodepoint(cp: in Int): String {
  JChar.toString(cp)
}

// Pure-Lyric UTF-8 encoder (JVM path).  `enc` is a sentinel and is unused.
// Mirrors the original encoding.l accumulator path.  Surrogate pairs are
// encoded as the corresponding 4-byte supplementary-plane sequence; a lone
// surrogate (either half, unpaired) is replaced with U+FFFD (EF BF BD) —
// matching .NET's `Encoding.UTF8` fallback behaviour so the two targets
// agree on this input shape (#7252; previously this path emitted WTF-8).
pub func hostEncodeUtf8(enc: in String, s: in String): slice[Byte] {
  // A string with no lone surrogate encodes identically through the JDK's
  // own UTF-8 encoder, which fills a byte[] directly instead of boxing each
  // byte into a List (#7271). The JDK would replace a lone surrogate with
  // '?', so those strings keep the loop below (the documented, now
  // .NET-matching, JVM behaviour, std/encoding.l).
  if not hasLoneSurrogate(s) {
    return s.getBytes("UTF-8")
  }
  val result: List[Byte] = newListWithCapacity(s.length * 3)
  val len = s.length
  var i = 0
  while i < len {
    val cu = s.codeUnitAt(i)
    if cu >= 55296 and cu <= 56319 and i + 1 < len {
      val cu2 = s.codeUnitAt(i + 1)
      if cu2 >= 56320 and cu2 <= 57343 {
        val cp = 65536 + (cu - 55296) * 1024 + (cu2 - 56320)
        result.add((240 + cp / 262144).toByte())
        result.add((128 + (cp / 4096) % 64).toByte())
        result.add((128 + (cp / 64) % 64).toByte())
        result.add((128 + cp % 64).toByte())
        i += 2
      } else {
        // Lone high surrogate: U+FFFD.
        result.add(239u8)
        result.add(191u8)
        result.add(189u8)
        i += 1
      }
    } else if cu >= 55296 and cu <= 57343 {
      // Lone surrogate (a high surrogate at the end of the string, or any
      // low surrogate not preceded by a matching high one): U+FFFD.
      result.add(239u8)
      result.add(191u8)
      result.add(189u8)
      i += 1
    } else if cu <= 127 {
      result.add(cu.toByte())
      i += 1
    } else if cu <= 2047 {
      result.add((192 + cu / 64).toByte())
      result.add((128 + cu % 64).toByte())
      i += 1
    } else {
      result.add((224 + cu / 4096).toByte())
      result.add((128 + (cu / 64) % 64).toByte())
      result.add((128 + cu % 64).toByte())
      i += 1
    }
  }
  result.toArray()
}

// True when `s` has a high surrogate not followed by a low one, or a low
// surrogate not preceded by a high one.
func hasLoneSurrogate(s: in String): Bool {
  val len = s.length
  var i = 0
  while i < len {
    val cu = s.codeUnitAt(i)
    if cu >= 55296 and cu <= 56319 {
      if i + 1 >= len {
        return true
      }
      val cu2 = s.codeUnitAt(i + 1)
      if cu2 < 56320 or cu2 > 57343 {
        return true
      }
      i += 2
    } else if cu >= 56320 and cu <= 57343 {
      return true
    } else {
      i += 1
    }
  }
  false
}

// Pure-Lyric Base64 decoder (JVM path).
// Assumes the caller has already validated the input (via tryDecodeBase64).
pub func hostFromBase64(s: in String): slice[Byte] {
  val len = s.length
  if len == 0 {
    return []
  }
  val result: List[Byte] = newListWithCapacity(len / 4 * 3)
  var i = 0
  while i < len {
    val c0 = b64v(s[i])
    val c1 = b64v(s[i + 1])
    val ch2 = s[i + 2]
    val ch3 = s[i + 3]
    if ch2 == '=' {
      result.add((c0 * 4 + c1 / 16).toByte())
    } else {
      val c2 = b64v(ch2)
      result.add((c0 * 4 + c1 / 16).toByte())
      if ch3 == '=' {
        result.add((c1 % 16 * 16 + c2 / 4).toByte())
      } else {
        val c3 = b64v(ch3)
        result.add((c1 % 16 * 16 + c2 / 4).toByte())
        result.add((c2 % 4 * 64 + c3).toByte())
      }
    }
    i += 4
  }
  result.toArray()
}

// Local copy of base64CharValue (avoids a circular import from Std.Encoding).
func b64v(c: in Char): Int {
  val cp = toInt(c)
  if cp >= 65 and cp <= 90 {
    return cp - 65
  }       // A-Z → 0-25
  if cp >= 97 and cp <= 122 {
    return cp - 97 + 26
  }  // a-z → 26-51
  if cp >= 48 and cp <= 57 {
    return cp - 48 + 52
  }  // 0-9 → 52-61
  if cp == 43 {
    return 62
  }                           // +  → 62
  if cp == 47 {
    return 63
  }                           // /  → 63
  return -1
}
