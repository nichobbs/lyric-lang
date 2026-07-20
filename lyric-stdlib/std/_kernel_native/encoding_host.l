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
import Std.Char
import Std.Collections

// Sentinel charset name; the accumulator in hostEncodeUtf8 ignores it.
pub func hostGetUtf8Enc(): String {
  "utf-8"
}

// Pure-Lyric UTF-8 encoder. `enc` is a sentinel and is unused. Mirrors
// the JVM twin's accumulator. Surrogate pairs are encoded as the
// corresponding 4-byte supplementary-plane sequence.
pub func hostEncodeUtf8(enc: in String, s: in String): slice[Byte] {
  val result: List[Byte] = newList()
  val len = s.length
  var i = 0
  while i < len {
    val cu = toInt(s[i])
    if cu >= 55296 and cu <= 56319 and i + 1 < len {
      val cu2 = toInt(s[i + 1])
      if cu2 >= 56320 and cu2 <= 57343 {
        val cp = 65536 + (cu - 55296) * 1024 + (cu2 - 56320)
        result.add(240 + cp / 262144)
        result.add(128 + (cp / 4096) % 64)
        result.add(128 + (cp / 64) % 64)
        result.add(128 + cp % 64)
        i += 2
      } else {
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

// Pure-Lyric Base64 decoder.
// Assumes the caller has already validated the input (via tryDecodeBase64).
pub func hostFromBase64(s: in String): slice[Byte] {
  val len = s.length
  if len == 0 {
    return []
  }
  val result: List[Byte] = newList()
  var i = 0
  while i < len {
    val c0 = b64v(s[i])
    val c1 = b64v(s[i + 1])
    val ch2 = s[i + 2]
    val ch3 = s[i + 3]
    if ch2 == '=' {
      result.add(c0 * 4 + c1 / 16)
    } else {
      val c2 = b64v(ch2)
      result.add(c0 * 4 + c1 / 16)
      if ch3 == '=' {
        result.add(c1 % 16 * 16 + c2 / 4)
      } else {
        val c3 = b64v(ch3)
        result.add(c1 % 16 * 16 + c2 / 4)
        result.add(c2 % 4 * 64 + c3)
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
