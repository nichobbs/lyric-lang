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

// Returns the .NET UTF-8 encoding singleton (System.Text.Encoding.UTF8).
// Bound to the static property getter get_UTF8 on System.Text.Encoding.
@externTarget("System.Text.Encoding.get_UTF8")
pub func hostGetUtf8Enc(): Enc = ()

// Encodes a string to UTF-8 bytes.  Binds to the BCL instance method
// Encoding.GetBytes(string) — `enc` is the receiver, `s` is the argument.
// Returns a genuine byte[] (not List<object> or object[]).
@externTarget("System.Text.Encoding.GetBytes")
pub func hostEncodeUtf8(enc: in Enc, s: in String): slice[Byte] = ()

// Decodes a standard Base64 string (RFC 4648 §4) to raw bytes.
// Binds to System.Convert.FromBase64String(string).
// Throws System.FormatException (caught by `catch Bug`) on malformed input.
// Returns a genuine byte[] on success.
@externTarget("System.Convert.FromBase64String")
pub func hostFromBase64(s: in String): slice[Byte] = ()
