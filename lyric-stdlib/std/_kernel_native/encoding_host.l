//! std/_kernel_native/encoding_host.l — native-target host boundary for
//! byte-level encoding.
//!
//! The `--target native` twin of `_kernel/encoding_host.l` /
//! `_kernel_jvm/encoding_host.l`, selected by the native source loader by
//! basename (issue #6103 item A, gating N9.2's `Std.TcpHost`/`Std.Tls`
//! native port).
//!
//! Ports the JVM twin's pure-Lyric accumulator path, not the .NET twin's
//! BCL-backed one: the .NET twin exists ONLY because the F#/self-hosted
//! MSIL emitter represents `List[Byte]` as `List<object>`, so
//! `.toArray()` there produces `object[]` instead of a genuine `byte[]`
//! (see `_kernel/encoding_host.l`'s header) — a BCL-specific type-erasure
//! artifact that has no counterpart on native. `Lyric.LlvmCodegen` lowers
//! `List[Byte]`/`slice[Byte]` to the real `lyric_rt` List/slice kernels
//! (D-N-015; verified by `llvm_collections_self_test.l`, N5.8), which are
//! genuinely byte-typed end to end, so the JVM twin's rationale — "no
//! List<object> erasure mismatch here, pure-Lyric accumulators are safe" —
//! applies unchanged to native. No new `lyric-rt` C code is needed for
//! this file: `libc.l` already exposes `malloc`/`free`, and OpenSSL's own
//! `EVP_DecodeBlock` was considered and rejected (it would pull the
//! dlopen'd OpenSSL seam into a path — Base64 decoding — that has nothing
//! to do with TLS, and it doesn't validate padding/charset the way
//! `Std.Encoding.tryDecodeBase64` already does in pure Lyric before ever
//! calling in here).
//!
//! Internal: only Std.Encoding should import this.
@axiom("native List[Byte].toArray() produces a properly typed byte array; pure-Lyric accumulators are safe on native")
package Std.EncodingHost

import Std.Core
import Std.Collections

// `LyricString` is UTF-8 internally on native (docs/09-msil-emission.md
// N/A here; see lyric_rt.h's LyricString comment), so `[]` bracket
// indexing on a String receiver is not a supported codegen shape yet
// (`Lyric.LlvmCodegen.lowerCollectionIndex` only recognises List/slice/Map
// receivers — confirmed via direct repro, issue #6237).  `rtByteAt` reads
// one byte of the UTF-8 buffer directly through the pre-existing
// `lyric_string_byte_at` runtime accessor (used since N0.4's ARC/string
// work; no new lyric-rt C code needed).  `hostCharCodeAt` is the
// `Std.EncodingHost` cross-target surface `Std.Encoding` calls instead of
// `s[i]`: on .NET/JVM (where `String` indexing is fully supported) the
// twin is a trivial `toInt(s[i])`; here it is byte-at-index.  This is
// exact for the ASCII-only alphabets `Std.Encoding` walks a code unit at a
// time (hex digits, Base64 alphabet, '=' padding): every character in
// those alphabets is a single UTF-8 byte, so byte offset and code-unit
// offset coincide, and any multi-byte (non-ASCII) input byte trips the
// alphabet's own range check and correctly yields `None`/`-1` either way.
extern func rtByteAt(s: String, idx: Int): Int = "lyric_string_byte_at"

// `String + Char` concatenation (the `"" + Std.Char.fromInt(cp)` idiom
// `Std.Encoding.tryDecodeUtf8` uses to build its result one code unit at a
// time) is ALSO not a supported native codegen shape: `lowerStringBinop`
// requires both operands to already be `String` (confirmed via direct
// repro — the "mixed String/non-String operands" panic; issue #6237), and
// `Char.toString()` independently mis-resolves on this codegen (routes to
// a nonexistent `CharConvert.ToChar` call target rather than
// `emitToString`'s NI32 case, itself wrong for Char since it would call
// `lyric_string_from_int`, i.e. produce the decimal digits, not the
// character).  `rtStrFromChar` sidesteps both bugs by going straight from
// the codepoint Int to a `LyricString*` through the pre-existing
// `lyric_string_from_char` runtime encoder (declared, but never actually
// called, by `Lyric.LlvmCodegen`'s own runtime-decl table — see that
// file's `mkDecl1("lyric_string_from_char", ...)` line).
extern func rtStrFromChar(cp: Int): String = "lyric_string_from_char"

// Sentinel charset name; the accumulator in hostEncodeUtf8 ignores it.
pub func hostGetUtf8Enc(): String {
  "utf-8"
}

// Returns the UTF-8 byte value at `i` as an Int 0..255.  See the file
// header for why this stands in for `toInt(s[i])` on native.
pub func hostCharCodeAt(s: in String, i: in Int): Int {
  rtByteAt(s, i)
}

// Returns the String representation of a full Unicode scalar value
// (0..0x10FFFF, already validated by the caller) — what
// `Std.Encoding.tryDecodeUtf8` needs at each decoded codepoint, BMP or
// supplementary-plane alike.  `lyric_string_from_char` already takes a
// full scalar value (not a UTF-16 code unit) and correctly emits the 1-4
// byte UTF-8 sequence for it directly (see lyric_string.c), so unlike the
// .NET/JVM twins (which must ask the BCL/JDK to construct a surrogate pair
// for anything outside the BMP), this one needs no special-casing at all.
pub func hostStringFromCodepoint(cp: in Int): String {
  rtStrFromChar(cp)
}

// UTF-8 "encoder". `enc` is a sentinel and is unused. Unlike the .NET/JVM
// twins (whose `String` is UTF-16 internally and must re-encode each code
// unit / surrogate pair to UTF-8), native's `LyricString` is ALREADY a
// UTF-8 byte buffer (see lyric_rt.h), so this is a straight byte copy —
// no surrogate-pair decoding is meaningful here, since there is no UTF-16
// form to decode from.
pub func hostEncodeUtf8(enc: in String, s: in String): slice[Byte] {
  val result: List[Byte] = newList()
  val len = s.length
  var i = 0
  while i < len {
    result.add(hostCharCodeAt(s, i).toByte())
    i += 1
  }
  result.toArray()
}

// Pure-Lyric Base64 decoder, byte-at-a-time (see hostCharCodeAt above).
// Assumes the caller has already validated the input (via tryDecodeBase64).
pub func hostFromBase64(s: in String): slice[Byte] {
  val len = s.length
  if len == 0 {
    return []
  }
  val result: List[Byte] = newList()
  var i = 0
  while i < len {
    val c0 = b64v(hostCharCodeAt(s, i))
    val c1 = b64v(hostCharCodeAt(s, i + 1))
    val cp2 = hostCharCodeAt(s, i + 2)
    val cp3 = hostCharCodeAt(s, i + 3)
    if cp2 == 61 {
      // '='
      result.add((c0 * 4 + c1 / 16).toByte())
    } else {
      val c2 = b64v(cp2)
      result.add((c0 * 4 + c1 / 16).toByte())
      if cp3 == 61 {
        // '='
        result.add((c1 % 16 * 16 + c2 / 4).toByte())
      } else {
        val c3 = b64v(cp3)
        result.add((c1 % 16 * 16 + c2 / 4).toByte())
        result.add((c2 % 4 * 64 + c3).toByte())
      }
    }
    i += 4
  }
  result.toArray()
}

// Local copy of base64CharValue, over a raw code-unit Int rather than a
// Char (avoids both a circular import from Std.Encoding and `s[i]`
// indexing at every call site).
func b64v(cp: in Int): Int {
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
