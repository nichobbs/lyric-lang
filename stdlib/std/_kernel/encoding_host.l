// std/_kernel/encoding_host.l — host boundary for Base64, hex, and UTF-8
// byte-level encoding.
//
// Four of the six operations route through Lyric.Stdlib.EncodingHost
// shims because they either can throw (and need try/catch wrapping) or
// go through a non-static class instance (Encoding.UTF8):
//
//   hostTryFromBase64   — System.Convert.FromBase64String throws
//                         FormatException on invalid input; shim wraps.
//   hostTryFromHex      — System.Convert.FromHexString throws on bad
//                         input; shim wraps.
//   hostEncodeUtf8      — System.Text.Encoding.UTF8.GetBytes(string);
//                         instance access via the static property.
//   hostTryDecodeUtf8   — System.Text.Encoding.UTF8.GetString(byte[])
//                         throws DecoderFallbackException on invalid bytes.
//
// `hostToBase64String` and `hostToHexString` target BCL statics directly
// because they never throw on valid byte-array input.
//
// Internal: only Std.Encoding should import this.

@axiom("System.Convert and System.Text.Encoding encoding operations conform to their documented .NET contracts")
package Std.EncodingHost

// =====================================================================
// Base64.
// =====================================================================

// Encode a byte slice as a Base64 string.
// System.Convert.ToBase64String(byte[]) — never throws on valid input.
@externTarget("System.Convert.ToBase64String")
pub func hostToBase64String(bytes: in slice[Byte]): String = ()

// Decode a Base64 string.  Returns true and writes the decoded bytes
// on success; returns false on any format error (no exception escapes).
@externTarget("Lyric.Stdlib.EncodingHost.TryFromBase64")
pub func hostTryFromBase64(s: in String, value: out slice[Byte]): Bool = ()

// =====================================================================
// Hexadecimal.
// =====================================================================

// Encode a byte slice as an uppercase hex string (2 chars per byte).
// System.Convert.ToHexString(byte[]) — added in .NET 5+, never throws.
@externTarget("System.Convert.ToHexString")
pub func hostToHexString(bytes: in slice[Byte]): String = ()

// Decode a hex string (upper or lower case).  Returns true on success;
// returns false on any format error (no exception escapes).
@externTarget("Lyric.Stdlib.EncodingHost.TryFromHex")
pub func hostTryFromHex(s: in String, value: out slice[Byte]): Bool = ()

// =====================================================================
// UTF-8.
// =====================================================================

// Encode a String as a UTF-8 byte slice.  All Lyric strings are valid
// Unicode so this never fails.
@externTarget("Lyric.Stdlib.EncodingHost.EncodeUtf8")
pub func hostEncodeUtf8(s: in String): slice[Byte] = ()

// Decode a UTF-8 byte slice.  Returns true and writes the string on
// success; returns false when the bytes are not valid UTF-8.
@externTarget("Lyric.Stdlib.EncodingHost.TryDecodeUtf8")
pub func hostTryDecodeUtf8(bytes: in slice[Byte], value: out String): Bool = ()
