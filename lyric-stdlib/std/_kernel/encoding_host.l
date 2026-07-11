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

// Opaque handle for the BCL System.Text.Encoding type.
extern type Enc = "System.Text.Encoding"

extern type NetConvert = "System.Convert"

// Returns the .NET UTF-8 encoding singleton (System.Text.Encoding.UTF8).
pub func hostGetUtf8Enc(): Enc {
  Enc.UTF8
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
