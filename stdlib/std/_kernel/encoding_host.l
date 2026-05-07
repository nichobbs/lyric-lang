// std/_kernel/encoding_host.l — host boundary for Base64, hex, and UTF-8
// byte-level encoding.
//
// All operations resolve directly to BCL statics, instance methods, a
// static property, or a constructor via the emitter's type-aware extern
// resolver, eliminating the Lyric.Stdlib.EncodingHost F# shim.
//
//   hostToBase64String   — System.Convert.ToBase64String(byte[])
//   hostFromBase64String — System.Convert.FromBase64String(string)
//                          throws FormatException on bad input; wrapped in
//                          try/catch in encoding.l
//   hostToHexString      — System.Convert.ToHexString(byte[])
//   hostFromHexString    — System.Convert.FromHexString(string)
//                          throws FormatException on bad input; wrapped in
//                          try/catch in encoding.l
//   hostGetUtf8Encoding  — System.Text.Encoding.UTF8 (static property)
//                          resolves via the propGetter() fallback
//   hostGetBytes         — System.Text.Encoding.GetBytes(string)
//                          instance method; exact-typed via instanceTyped
//   newStrictUtf8Encoding — System.Text.UTF8Encoding..ctor(bool, bool)
//                          (emitBom=false, throwOnInvalid=true)
//   hostGetString        — System.Text.UTF8Encoding.GetString(byte[])
//                          instance method; throws DecoderFallbackException
//                          when throwOnInvalid=true; wrapped in encoding.l
//
// Internal: only Std.Encoding should import this.

@axiom("System.Convert and System.Text.Encoding encoding operations conform to their documented .NET contracts")
package Std.EncodingHost

extern type Encoding    = "System.Text.Encoding"
extern type UTF8Encoding = "System.Text.UTF8Encoding"

// =====================================================================
// Base64.
// =====================================================================

// Encode a byte slice as a Base64 string.
// System.Convert.ToBase64String(byte[]) — never throws on valid input.
@externTarget("System.Convert.ToBase64String")
pub func hostToBase64String(bytes: in slice[Byte]): String = ()

// Decode a Base64 string.
// System.Convert.FromBase64String(string) — throws FormatException on bad input.
// Callers must wrap in try/catch.
@externTarget("System.Convert.FromBase64String")
pub func hostFromBase64String(s: in String): slice[Byte] = ()

// =====================================================================
// Hexadecimal.
// =====================================================================

// Encode a byte slice as an uppercase hex string (2 chars per byte).
// System.Convert.ToHexString(byte[]) — added in .NET 5+, never throws.
@externTarget("System.Convert.ToHexString")
pub func hostToHexString(bytes: in slice[Byte]): String = ()

// Decode a hex string (upper or lower case).
// System.Convert.FromHexString(string) — throws FormatException on bad input.
// Callers must wrap in try/catch.
@externTarget("System.Convert.FromHexString")
pub func hostFromHexString(s: in String): slice[Byte] = ()

// =====================================================================
// UTF-8.
// =====================================================================

// System.Text.Encoding.UTF8 (static property) — returns the shared
// UTF-8 encoder/decoder.  Resolves via the propGetter() fallback in
// the extern resolver.
@externTarget("System.Text.Encoding.UTF8")
pub func hostGetUtf8Encoding(): Encoding = ()

// System.Text.Encoding.GetBytes(string) — instance method, never throws
// for valid .NET strings (all Lyric strings are valid Unicode).
@externTarget("System.Text.Encoding.GetBytes")
pub func hostGetBytes(enc: in Encoding, s: in String): slice[Byte] = ()

// System.Text.UTF8Encoding(bool encoderShouldEmitUTF8Identifier,
//                           bool throwOnInvalidBytes) — constructor.
// Use (false, true) to get strict decoding that throws DecoderFallbackException
// on invalid byte sequences rather than substituting U+FFFD.
@externTarget("System.Text.UTF8Encoding..ctor")
pub func newStrictUtf8Encoding(emitBom: in Bool, throwOnInvalid: in Bool): UTF8Encoding = ()

// System.Text.UTF8Encoding.GetString(byte[]) — instance method.
// When created with throwOnInvalidBytes=true, throws DecoderFallbackException
// on invalid byte sequences.  Callers must wrap in try/catch.
@externTarget("System.Text.UTF8Encoding.GetString")
pub func hostGetString(enc: in UTF8Encoding, bytes: in slice[Byte]): String = ()
