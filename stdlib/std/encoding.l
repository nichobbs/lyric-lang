// std/encoding.l - Byte-level encoding: Base64, hexadecimal, and UTF-8.
//
// All operations are safe in the Lyric sense: callers that provide
// well-formed input always get a non-panicking `Ok`/`Some` result, and
// callers that provide malformed input get `None` rather than a thrown
// exception.  The `try*` variants wrap the BCL's throwing overloads in
// Lyric try/catch rather than routing through out-parameter shims.
//
// Hex output from `encodeHex` uses the uppercase format produced by
// `System.Convert.ToHexString` ("FF" not "ff").  Use `Std.String.toLower`
// if lowercase is required.
//
// UTF-8 encoding never fails (all valid Lyric strings are valid Unicode);
// decoding can fail when the byte slice is not valid UTF-8.  A strict
// `UTF8Encoding(false, true)` instance is used so invalid byte sequences
// throw `DecoderFallbackException` (rather than silently substituting
// the U+FFFD replacement character), allowing `tryDecodeUtf8` to return
// `None` for any invalid input.

package Std.Encoding

import Std.Core
import Std.EncodingHost as Host

// =====================================================================
// Base64.
// =====================================================================

/// Encode `bytes` as a standard Base64 string (uses A–Z, a–z, 0–9, +, /).
/// Output may include "=" padding characters at the end.
@stable(since="1.0")
pub func encodeBase64(bytes: in slice[Byte]): String {
  Host.hostToBase64String(bytes)
}

/// Decode a Base64 string.  Returns `Some(bytes)` on success, `None` for
/// any input that is not valid Base64 (illegal characters, wrong padding).
@stable(since="1.0")
pub func tryDecodeBase64(s: in String): Option[slice[Byte]] {
  try {
    Some(value = Host.hostFromBase64String(s))
  } catch Exception {
    None
  }
}

// =====================================================================
// Hexadecimal.
// =====================================================================

/// Encode `bytes` as an uppercase hexadecimal string (two characters per
/// byte, no separator).  Example: [0xDE, 0xAD] → "DEAD".
@stable(since="1.0")
pub func encodeHex(bytes: in slice[Byte]): String {
  Host.hostToHexString(bytes)
}

/// Decode a hexadecimal string (upper or lower case, no prefix required).
/// Returns `Some(bytes)` on success, `None` for any malformed input
/// (odd length, non-hex characters).
@stable(since="1.0")
pub func tryDecodeHex(s: in String): Option[slice[Byte]] {
  try {
    Some(value = Host.hostFromHexString(s))
  } catch Exception {
    None
  }
}

// =====================================================================
// UTF-8.
// =====================================================================

/// Encode a `String` as a UTF-8 byte slice.  All Lyric strings are valid
/// Unicode so this operation always succeeds.
@stable(since="1.0")
pub func encodeUtf8(s: in String): slice[Byte] {
  Host.hostGetBytes(Host.hostGetUtf8Encoding(), s)
}

/// Decode a UTF-8 byte slice to a `String`.  Returns `Some(s)` when the
/// bytes are valid UTF-8, `None` otherwise.
@stable(since="1.0")
pub func tryDecodeUtf8(bytes: in slice[Byte]): Option[String] {
  try {
    val enc = Host.newStrictUtf8Encoding(false, true)
    Some(value = Host.hostGetString(enc, bytes))
  } catch Exception {
    None
  }
}
