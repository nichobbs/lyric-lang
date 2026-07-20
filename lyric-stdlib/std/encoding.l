//! std/encoding.l - Byte-level encoding: Base64, hexadecimal, and UTF-8.
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
//!
//! Platform notes:
//!   encodeUtf8 and tryDecodeBase64 use BCL externs on .NET so that the
//!   result is always a genuine byte[] regardless of which emitter compiled
//!   this module.  Both the F# bootstrap emitter and the self-hosted MSIL
//!   emitter represent List[Byte] as List<object>; .toArray() on that type
//!   would produce object[] rather than byte[], breaking any BCL method that
//!   expects byte[].  The JVM versions use the pure-Lyric accumulator path
//!   (the JVM backend's list representation does not have this type-erasure
//!   mismatch).
//!
//! Lone-surrogate behaviour: a Lyric String may contain isolated UTF-16
//! surrogates (U+D800..U+DFFF) that do not form a valid surrogate pair.
//! encodeUtf8 does not validate its input for this case; the resulting
//! byte sequence is platform-specific (.NET replaces lone surrogates with
//! U+FFFD; the JVM accumulator encodes them as WTF-8 3-byte sequences).
//! Callers that need portable round-trip behaviour should reject lone
//! surrogates before encoding.
package Std.Encoding

import Std.Core
import Std.Collections
import Std.EncodingHost

// =====================================================================
// Hexadecimal.
// =====================================================================
/// Encode `bytes` as an uppercase hexadecimal string (two characters per
/// byte, no separator).  Example: [0xDE, 0xAD] → "DEAD".
///
/// Uses `String.substring` rather than `digits[idx]` bracket indexing:
/// the latter is not a supported codegen shape for `--target native`
/// (`Lyric.LlvmCodegen.lowerCollectionIndex` only recognises List/slice/Map
/// receivers, not `String`), while `.substring` is a plain method call
/// that works identically on every target.
@stable(since = "1.0")
pub func encodeHex(bytes: in slice[Byte]): String {
  val digits = "0123456789ABCDEF"
  var result = ""
  var i = 0
  while i < bytes.length {
    val b = bytes[i]
    result = result + digits.substring((b / 16u8).toInt(), 1) + digits.substring((b % 16u8).toInt(), 1)
    i += 1
  }
  result
}

/// Decode a hexadecimal string (upper or lower case, no prefix required).
/// Returns `Some(bytes)` on success, `None` for any malformed input
/// (odd length, non-hex characters).
///
/// Walks `s` via `Std.EncodingHost.hostCharCodeAt` (a per-target code-unit
/// read) rather than `s[i]` bracket indexing, for the same
/// `--target native` codegen reason as `encodeHex` above.
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
    // Two nested single-value matches rather than a `(hi, lo)` tuple match:
    // `--target native` only supports bindings/wildcards inside tuple
    // patterns, not nested constructor patterns like `(Some(h), Some(l))`
    // (confirmed via direct repro, issue #6237).
    match hexCodeUnitValue(hostCharCodeAt(s, i)) {
      case Some(h) -> {
        match hexCodeUnitValue(hostCharCodeAt(s, i + 1)) {
          case Some(l) -> result.add((h * 16 + l).toByte())
          case None -> return None
        }
      }
      case None -> return None
    }
    i += 2
  }
  Some(value = result.toArray())
}

// Same table as Std.Char.hexDigitValue, but over a raw UTF-16/UTF-8
// code-unit Int (see hostCharCodeAt) instead of a Char, so tryDecodeHex
// never needs `s[i]`.
func hexCodeUnitValue(cp: in Int): Option[Int] {
  if cp >= 48 and cp <= 57 {
    return Some(value = cp - 48)
  }
  // '0'-'9'
  if cp >= 97 and cp <= 102 {
    return Some(value = cp - 97 + 10)
  }
  // 'a'-'f'
  if cp >= 65 and cp <= 70 {
    return Some(value = cp - 65 + 10)
  }
  // 'A'-'F'
  None
}

// =====================================================================
// Base64.
// =====================================================================
// Returns the Base64 sextet value (0-63) for a code-unit Int (see
// hostCharCodeAt), or -1 if invalid. '=' (61) is not handled here;
// callers check for it explicitly.  Takes an Int rather than a Char so
// tryDecodeBase64 never needs `s[i]` (see that function's header).
func base64CodeUnitValue(cp: in Int): Int {
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
///
/// Uses `String.substring` rather than `BASE64_ALPHA[idx]` bracket
/// indexing — see `encodeHex`'s header for why.
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
    result = result + BASE64_ALPHA.substring((b0 / 4u8).toInt(), 1) +
      BASE64_ALPHA.substring(((b0 % 4u8) * 16u8 + b1 / 16u8).toInt(), 1) +
      BASE64_ALPHA.substring(((b1 % 16u8) * 4u8 + b2 / 64u8).toInt(), 1) +
      BASE64_ALPHA.substring((b2 % 64u8).toInt(), 1)
    i += 3
  }
  val rem = len - i
  if rem == 1 {
    val b0 = bytes[i]
    result = result + BASE64_ALPHA.substring((b0 / 4u8).toInt(), 1) +
      BASE64_ALPHA.substring(((b0 % 4u8) * 16u8).toInt(), 1) +
      "=="
  } else if rem == 2 {
    val b0 = bytes[i]
    val b1 = bytes[i + 1]
    result = result + BASE64_ALPHA.substring((b0 / 4u8).toInt(), 1) +
      BASE64_ALPHA.substring(((b0 % 4u8) * 16u8 + b1 / 16u8).toInt(), 1) +
      BASE64_ALPHA.substring(((b1 % 16u8) * 4u8).toInt(), 1) +
      "="
  }
  result
}

/// Decode a Base64 string (RFC 4648 §4).
/// Returns `Some(bytes)` on success, `None` for any malformed input
/// (invalid characters, wrong padding, length not a multiple of 4).
///
/// On .NET the BCL `System.Convert.FromBase64String` is used so the result
/// is a genuine byte[].  On JVM and native, a pure-Lyric accumulator is
/// used via the Std.EncodingHost kernel boundary.  Input is validated in
/// pure Lyric on every platform before the host call.
///
/// Walks `s` via `Std.EncodingHost.hostCharCodeAt` rather than `s[i]`
/// bracket indexing — see `tryDecodeHex`'s header for why (the same
/// `--target native` codegen gap applies here).
@stable(since = "1.0")
pub func tryDecodeBase64(s: in String): Option[slice[Byte]] {
  val len = s.length
  if len == 0 {
    return Some(value = [])
  }
  if len % 4 != 0 {
    return None
  }
  var i = 0
  while i < len {
    val c0 = base64CodeUnitValue(hostCharCodeAt(s, i))
    val c1 = base64CodeUnitValue(hostCharCodeAt(s, i + 1))
    if c0 < 0 or c1 < 0 {
      return None
    }
    val cp2 = hostCharCodeAt(s, i + 2)
    val cp3 = hostCharCodeAt(s, i + 3)
    if cp2 == 61 {
      // '='
      if cp3 != 61 {
        return None
      }
      if i + 4 != len {
        return None
      }
    } else {
      val c2 = base64CodeUnitValue(cp2)
      if c2 < 0 {
        return None
      }
      if cp3 == 61 {
        // '='
        if i + 4 != len {
          return None
        }
      } else {
        val c3 = base64CodeUnitValue(cp3)
        if c3 < 0 {
          return None
        }
      }
    }
    i += 4
  }
  Some(value = hostFromBase64(s))
}

// =====================================================================
// UTF-8.
// =====================================================================
/// Encode a `String` as a UTF-8 byte slice.  All Lyric strings are valid
/// Unicode so this operation always succeeds.  Surrogate pairs in the
/// source string are encoded as the corresponding supplementary-plane
/// 4-byte UTF-8 sequence.
///
/// On .NET the BCL `System.Text.Encoding.UTF8.GetBytes` is used so the
/// result is a genuine byte[].  On JVM a pure-Lyric accumulator is used
/// via the Std.EncodingHost kernel boundary.
@stable(since = "1.0")
pub func encodeUtf8(s: in String): slice[Byte] {
  hostEncodeUtf8(hostGetUtf8Enc(), s)
}

/// Decode a UTF-8 byte slice to a `String`.  Returns `Some(s)` when the
/// bytes are valid UTF-8, `None` otherwise.  Rejects overlong sequences,
/// lone surrogate code points, and code points above U+10FFFF.
///
/// Builds `result` via `Std.EncodingHost.hostStringFromCodepoint` rather
/// than `"" + fromInt(cp)`: `String + Char` concatenation is not a
/// supported codegen shape for `--target native` (confirmed via direct
/// repro — `Lyric.LlvmCodegen.lowerStringBinop` requires both operands to
/// already be `String`; issue #6237), and `Char.toString()` is a separate,
/// independently broken path on that backend, so neither is a safe
/// alternative there.
@stable(since = "1.0")
pub func tryDecodeUtf8(bytes: in slice[Byte]): Option[String] {
  var result = ""
  val len = bytes.length
  var i = 0
  while i < len {
    val b0: Byte = bytes[i]
    if b0 < 128u8 {
      // 1-byte sequence: U+0000..U+007F
      result = result + hostStringFromCodepoint(b0.toInt())
      i += 1
    } else if b0 / 32u8 == 6u8 {
      // 2-byte sequence: 110xxxxx 10xxxxxx → U+0080..U+07FF
      if i + 1 >= len {
        return None
      }
      val b1: Byte = bytes[i + 1]
      if b1 / 64u8 != 2u8 {
        return None
      }
      // continuation byte check
      val cp = (b0.toInt() % 32) * 64 + b1.toInt() % 64
      if cp < 128 {
        return None
      }
      // overlong
      result = result + hostStringFromCodepoint(cp)
      i += 2
    } else if b0 / 16u8 == 14u8 {
      // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx → U+0800..U+FFFF
      if i + 2 >= len {
        return None
      }
      val b1: Byte = bytes[i + 1]
      val b2: Byte = bytes[i + 2]
      if b1 / 64u8 != 2u8 or b2 / 64u8 != 2u8 {
        return None
      }
      val cp = (b0.toInt() % 16) * 4096 + (b1.toInt() % 64) * 64 + b2.toInt() % 64
      if cp < 2048 {
        return None
      }
      // overlong
      if cp >= 55296 and cp <= 57343 {
        return None
      }
      // surrogates invalid in UTF-8
      result = result + hostStringFromCodepoint(cp)
      i += 3
    } else if b0 / 8u8 == 30u8 {
      // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx → U+10000..U+10FFFF
      if i + 3 >= len {
        return None
      }
      val b1: Byte = bytes[i + 1]
      val b2: Byte = bytes[i + 2]
      val b3: Byte = bytes[i + 3]
      if b1 / 64u8 != 2u8 or b2 / 64u8 != 2u8 or b3 / 64u8 != 2u8 {
        return None
      }
      val cp = (b0.toInt() % 8) * 262144 + (b1.toInt() % 64) * 4096 + (b2.toInt() % 64) * 64 + b3.toInt() % 64
      if cp < 65536 {
        return None
      }
      // overlong
      if cp > 1114111 {
        return None
      }
      // above U+10FFFF
      // `hostStringFromCodepoint` takes the full scalar value directly and
      // constructs whatever the target's String representation needs (a
      // surrogate pair on .NET/JVM, a 4-byte UTF-8 sequence on native) —
      // no surrogate-pair math needed here.
      result = result + hostStringFromCodepoint(cp)
      i += 4
    } else {
      return None
      // invalid leading byte (continuation byte or 0xFF/0xFE)
    }
  }
  Some(value = result)
}
