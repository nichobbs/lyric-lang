//! std/encoding.l - Byte-level encoding: Base64, hexadecimal, and UTF-8.
//!
//! All operations are pure Lyric; no host externs remain.
//!
//! encodeHex produces uppercase two-hex-chars-per-byte output (e.g. "DEAD").
//! tryDecodeHex accepts both upper and lower-case hex.
//!
//! encodeBase64 / tryDecodeBase64 implement RFC 4648 §4 standard Base64
//! (alphabet A–Z a–z 0–9 + /, with = padding).  tryDecodeBase64 validates
//! every character and the padding structure; any malformed input returns None.
//!
//! encodeUtf8 / tryDecodeUtf8 implement UTF-8 per RFC 3629.  Lyric strings
//! are UTF-16 internally; surrogate pairs are encoded as 4-byte UTF-8
//! sequences (the correct Unicode encoding, not CESU-8).  tryDecodeUtf8
//! rejects overlong sequences, lone surrogates, and code points > U+10FFFF.
package Std.Encoding

import Std.Core
import Std.Char
import Std.Collections

// =====================================================================
// Hexadecimal.
// =====================================================================
/// Encode `bytes` as an uppercase hexadecimal string (two characters per
/// byte, no separator).  Example: [0xDE, 0xAD] → "DEAD".
@stable(since = "1.0")
pub func encodeHex(bytes: in slice[Byte]): String {
  val digits = "0123456789ABCDEF"
  var result = ""
  var i = 0
  while i < bytes.length {
    val b = bytes[i]
    result = result + ("" + digits[b / 16u8]) + ("" + digits[b % 16u8])
    i += 1
  }
  result
}

/// Decode a hexadecimal string (upper or lower case, no prefix required).
/// Returns `Some(bytes)` on success, `None` for any malformed input
/// (odd length, non-hex characters).
@stable(since = "1.0")
pub func tryDecodeHex(s: in String): Option[slice[Byte]] {
  val len = s.length
  if len % 2 != 0 {
    return None
  }
  if len == 0 {
    return Some(value = [])
  }
  val result: List[Byte] = newList()
  var i = 0
  while i < len {
    val hi = hexDigitValue(s[i])
    val lo = hexDigitValue(s[i + 1])
    match (hi, lo) {
      case (Some(h), Some(l)) -> result.add(h * 16 + l)
      case _ -> return None
    }
    i += 2
  }
  Some(value = result.toArray())
}

// =====================================================================
// Base64.
// =====================================================================
// Returns the Base64 sextet value (0-63) for a character, or -1 if invalid.
// '=' is not handled here; callers check for it explicitly.
func base64CharValue(c: in Char): Int {
  val cp = toInt(c)
  if cp >= 65 and cp <= 90 {
    return cp - 65
  }
  // A-Z → 0-25
  if cp >= 97 and cp <= 122 {
    return cp - 97 + 26
  }
  // a-z → 26-51
  if cp >= 48 and cp <= 57 {
    return cp - 48 + 52
  }
  // 0-9 → 52-61
  if cp == 43 {
    return 62
  }
  // +  → 62
  if cp == 47 {
    return 63
  }
  // /  → 63
  return -1
}

/// Encode `bytes` as a standard Base64 string (RFC 4648 §4).
/// Output may include "=" padding characters at the end.
@stable(since = "1.0")
pub func encodeBase64(bytes: in slice[Byte]): String {
  val BASE64_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var result = ""
  val len = bytes.length
  var i = 0
  while i + 3 <= len {
    val b0 = bytes[i]
    val b1 = bytes[i + 1]
    val b2 = bytes[i + 2]
    result = result + ("" + BASE64_ALPHA[b0 / 4u8]) + ("" + BASE64_ALPHA[(b0 % 4u8) * 16u8 + b1 / 16u8]) +
      ("" + BASE64_ALPHA[(b1 % 16u8) * 4u8 + b2 / 64u8]) +
      ("" + BASE64_ALPHA[b2 % 64u8])
    i += 3
  }
  val rem = len - i
  if rem == 1 {
    val b0 = bytes[i]
    result = result + ("" + BASE64_ALPHA[b0 / 4u8]) + ("" + BASE64_ALPHA[(b0 % 4u8) * 16u8]) + "=="
  } else if rem == 2 {
    val b0 = bytes[i]
    val b1 = bytes[i + 1]
    result = result + ("" + BASE64_ALPHA[b0 / 4u8]) + ("" + BASE64_ALPHA[(b0 % 4u8) * 16u8 + b1 / 16u8]) +
      ("" + BASE64_ALPHA[(b1 % 16u8) * 4u8]) +
      "="
  }
  result
}

/// Decode a Base64 string (RFC 4648 §4).
/// Returns `Some(bytes)` on success, `None` for any malformed input
/// (invalid characters, wrong padding, length not a multiple of 4).
@stable(since = "1.0")
pub func tryDecodeBase64(s: in String): Option[slice[Byte]] {
  val len = s.length
  if len == 0 {
    return Some(value = [])
  }
  if len % 4 != 0 {
    return None
  }
  val result: List[Byte] = newList()
  var i = 0
  while i < len {
    val c0 = base64CharValue(s[i])
    val c1 = base64CharValue(s[i + 1])
    if c0 < 0 or c1 < 0 {
      return None
    }
    val ch2 = s[i + 2]
    val ch3 = s[i + 3]
    if ch2 == '=' {
      if ch3 != '=' {
        return None
      }
      if i + 4 != len {
        return None
      }
      // padding only valid in last group
      result.add(c0 * 4 + c1 / 16)
    } else {
      val c2 = base64CharValue(ch2)
      if c2 < 0 {
        return None
      }
      if ch3 == '=' {
        if i + 4 != len {
          return None
        }
        result.add(c0 * 4 + c1 / 16)
        result.add(c1 % 16 * 16 + c2 / 4)
      } else {
        val c3 = base64CharValue(ch3)
        if c3 < 0 {
          return None
        }
        result.add(c0 * 4 + c1 / 16)
        result.add(c1 % 16 * 16 + c2 / 4)
        result.add(c2 % 4 * 64 + c3)
      }
    }
    i += 4
  }
  Some(value = result.toArray())
}

// =====================================================================
// UTF-8.
// =====================================================================
/// Encode a `String` as a UTF-8 byte slice.  All Lyric strings are valid
/// Unicode so this operation always succeeds.  Surrogate pairs in the
/// source string are encoded as the corresponding supplementary-plane
/// 4-byte UTF-8 sequence.
@stable(since = "1.0")
pub func encodeUtf8(s: in String): slice[Byte] {
  val result: List[Byte] = newList()
  val len = s.length
  var i = 0
  while i < len {
    val cu = toInt(s[i])
    if cu >= 55296 and cu <= 56319 and i + 1 < len {
      // High surrogate: check for low surrogate pair
      val cu2 = toInt(s[i + 1])
      if cu2 >= 56320 and cu2 <= 57343 {
        val cp = 65536 + (cu - 55296) * 1024 + (cu2 - 56320)
        result.add(240 + cp / 262144)
        result.add(128 + (cp / 4096) % 64)
        result.add(128 + (cp / 64) % 64)
        result.add(128 + cp % 64)
        i += 2
      } else {
        // Lone high surrogate: encode as 3-byte sequence
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

/// Decode a UTF-8 byte slice to a `String`.  Returns `Some(s)` when the
/// bytes are valid UTF-8, `None` otherwise.  Rejects overlong sequences,
/// lone surrogate code points, and code points above U+10FFFF.
@stable(since = "1.0")
pub func tryDecodeUtf8(bytes: in slice[Byte]): Option[String] {
  var result = ""
  val len = bytes.length
  var i = 0
  while i < len {
    val b0 = bytes[i]
    if b0 < 128u8 {
      // 1-byte sequence: U+0000..U+007F
      result = result + ("" + fromInt(b0))
      i += 1
    } else if b0 / 32u8 == 6u8 {
      // 2-byte sequence: 110xxxxx 10xxxxxx → U+0080..U+07FF
      if i + 1 >= len {
        return None
      }
      val b1 = bytes[i + 1]
      if b1 / 64u8 != 2u8 {
        return None
      }
      // continuation byte check
      val cp = (b0 % 32u8) * 64 + b1 % 64u8
      if cp < 128 {
        return None
      }
      // overlong
      result = result + ("" + fromInt(cp))
      i += 2
    } else if b0 / 16u8 == 14u8 {
      // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx → U+0800..U+FFFF
      if i + 2 >= len {
        return None
      }
      val b1 = bytes[i + 1]
      val b2 = bytes[i + 2]
      if b1 / 64u8 != 2u8 or b2 / 64u8 != 2u8 {
        return None
      }
      val cp = (b0 % 16u8) * 4096 + (b1 % 64u8) * 64 + b2 % 64u8
      if cp < 2048 {
        return None
      }
      // overlong
      if cp >= 55296 and cp <= 57343 {
        return None
      }
      // surrogates invalid in UTF-8
      result = result + ("" + fromInt(cp))
      i += 3
    } else if b0 / 8u8 == 30u8 {
      // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx → U+10000..U+10FFFF
      if i + 3 >= len {
        return None
      }
      val b1 = bytes[i + 1]
      val b2 = bytes[i + 2]
      val b3 = bytes[i + 3]
      if b1 / 64u8 != 2u8 or b2 / 64u8 != 2u8 or b3 / 64u8 != 2u8 {
        return None
      }
      val cp = (b0 % 8u8) * 262144 + (b1 % 64u8) * 4096 + (b2 % 64u8) * 64 + b3 % 64u8
      if cp < 65536 {
        return None
      }
      // overlong
      if cp > 1114111 {
        return None
      }
      // above U+10FFFF
      // Encode as surrogate pair
      val cp1 = cp - 65536
      val high = 55296 + cp1 / 1024
      val low = 56320 + cp1 % 1024
      result = result + ("" + fromInt(high)) + ("" + fromInt(low))
      i += 4
    } else {
      return None
      // invalid leading byte (continuation byte or 0xFF/0xFE)
    }
  }
  Some(value = result)
}
