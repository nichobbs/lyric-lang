//! std/_kernel/encoding_host.l — .NET host boundary for byte-level encoding.
//!
//! Provides BCL-backed implementations of the critical encoding operations that
//! would otherwise accumulate bytes in List<object> and produce object[] instead
//! of byte[].  Both the F# bootstrap emitter and the self-hosted MSIL emitter
//! represent List[Byte] as List<object> at runtime; .toArray() on List<object>
//! returns object[], not byte[].  These externs bypass the accumulator pattern
//! and obtain genuine byte[] results directly from the BCL.
//!
//! Internal: only Std.Encoding should import this.
@axiom(".NET Encoding.GetBytes and Convert.FromBase64String conform to their documented .NET contracts and return genuine byte[] arrays")
package Std.EncodingHost

import Std.Char

// Opaque handle for the BCL System.Text.Encoding type.
extern type Enc = "System.Text.Encoding"

extern type NetConvert = "System.Convert"

extern type NetChar = "System.Char"

// Returns the .NET UTF-8 encoding singleton (System.Text.Encoding.UTF8).
pub func hostGetUtf8Enc(): Enc {
  Enc.UTF8
}

// Returns the UTF-16 code-unit integer value of `s[i]`.  Trivial on .NET
// (String indexing is fully supported); exists so `Std.Encoding`'s
// alphabet-walking loops (tryDecodeHex/tryDecodeBase64/encodeHex/
// encodeBase64) can call one cross-target primitive instead of `s[i]`
// directly — the native twin (`_kernel_native/encoding_host.l`) cannot
// support `s[i]` (its `String` is a UTF-8 byte buffer, not indexable by
// the current native codegen; see that file's header), so this Std.EncodingHost
// surface exists precisely for the native twin's sake even though this
// (.NET) implementation is a one-line passthrough.
pub func hostCharCodeAt(s: in String, i: in Int): Int {
  toInt(s[i])
}

// Returns the String representation of a full Unicode scalar value
// (0..0x10FFFF, already validated by the caller), correctly encoded as a
// surrogate pair when `cp` is outside the BMP.  `Char.ConvertFromUtf32` is
// the exact BCL primitive for this; the native twin needs this
// cross-target surface because neither `String + Char` concatenation nor
// `Char.toString()` is a supported codegen shape there (see that file's
// header) and native's `lyric_string_from_char` seam takes a full scalar
// value directly rather than a UTF-16 Char.
pub func hostStringFromCodepoint(cp: in Int): String {
  NetChar.ConvertFromUtf32(cp)
}

// Encodes a string to UTF-8 bytes via the BCL instance method
// Encoding.GetBytes(string).  Returns a genuine byte[] (not
// List<object> or object[]).
pub func hostEncodeUtf8(enc: in Enc, s: in String): slice[Byte] {
  enc.GetBytes(s)
}

// Decodes a standard Base64 string (RFC 4648 §4) to raw bytes.
// Throws System.FormatException (caught by `catch Bug`) on malformed input.
// Returns a genuine byte[] on success.
pub func hostFromBase64(s: in String): slice[Byte] {
  NetConvert.FromBase64String(s)
}
