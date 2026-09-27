//! std/hash.l — cryptographic hash helpers.
//!
//! Exposes SHA-256 and SHA-512 (sufficient for lock-file content
//! integrity per docs/39 §5.2, and contract metadata integrity per
//! docs/45 §2–§3), plus SHA-1 (`sha1OfBytes`) for the RFC 6455 WebSocket
//! handshake's `Sec-WebSocket-Accept` derivation — not a security boundary,
//! see that function's doc comment.  Returns uppercase hex strings so the
//! output is filesystem-safe and matches the wire format used by NuGet
//! signing manifests.
@runtime_checked
package Std.Hash

import Std.Core
import Std.HashHost
import Std.Collections

/// Compute the SHA-1 of `bytes` and return the digest as an uppercase
/// 40-character hex string.
///
/// SHA-1 is cryptographically broken for collision resistance and MUST NOT
/// be used for content integrity or signing (use `sha256OfBytes` /
/// `sha512OfBytes` for that). It is provided here only because the RFC 6455
/// WebSocket upgrade handshake's `Sec-WebSocket-Accept` derivation mandates
/// SHA-1 by spec — that computation is not a security boundary (the value
/// merely proves the peer echoed a nonce it was handed in plaintext over the
/// same connection), so SHA-1's weaknesses are irrelevant to that use.
@stable(since = "1.0")
pub func sha1OfBytes(bytes: in slice[Byte]): String
  ensures: result.length == 40
{
  hostBytesToHex(hostSha1Bytes(bytes))
}

/// Compute the SHA-256 of `bytes` and return the digest as an uppercase
/// 64-character hex string.
@stable(since = "1.0")
pub func sha256OfBytes(bytes: in slice[Byte]): String
  ensures: result.length == 64
{
  hostBytesToHex(hostSha256Bytes(bytes))
}

/// Compute the SHA-512 of `bytes` and return the digest as an uppercase
/// 128-character hex string.
@stable(since = "1.0")
pub func sha512OfBytes(bytes: in slice[Byte]): String
  ensures: result.length == 128
{
  hostBytesToHex(hostSha512Bytes(bytes))
}

/// Compute the SHA-512 of the file at `path`.  Returns `Err(message)`
/// when the file cannot be read (missing, permission denied, etc.) —
/// the caller decides whether that's fatal.  The file is streamed through
/// the digest rather than read into memory.
@stable(since = "1.0")
pub func sha512OfFile(path: in String): Result[String, String] {
  try {
    Ok(value = hostBytesToHex(hostSha512File(path)))
  } catch Bug as b {
    Err(error = b.message)
  }
}

/// The raw 32-byte SHA-256 digest of `bytes`.
@experimental
pub func sha256Digest(bytes: in slice[Byte]): slice[Byte]
  ensures: result.length == 32
{
  hostSha256Bytes(bytes)
}

/// HMAC-SHA-256 of `message` under `key` (RFC 2104), as the raw 32-byte
/// tag.  A key longer than the 64-byte block is hashed first, as the RFC
/// requires.  Use `constantTimeEquals` to compare a computed tag against a
/// received one.
@experimental
pub func hmacSha256(key: in slice[Byte], message: in slice[Byte]): slice[Byte]
  ensures: result.length == 32
{
  val blockKey: slice[Byte] = if key.length > 64 { hostSha256Bytes(key) } else { key }
  val inner: List[Byte] = newList()
  val outer: List[Byte] = newList()
  var i = 0
  while i < 64 {
    val k = if i < blockKey.length { blockKey[i].toInt() } else { 0 }
    inner.add(k.xor(0x36).and(255).toByte())
    outer.add(k.xor(0x5c).and(255).toByte())
    i = i + 1
  }
  val innerDigest = hostSha256Bytes(inner.toArray().concat(message))
  hostSha256Bytes(outer.toArray().concat(innerDigest))
}

/// Whether `a` and `b` hold the same bytes, in time that depends only on
/// their lengths, not on where they first differ.  Compare MAC tags with
/// this, never with `==`, so a forger cannot find the tag byte by byte
/// from response timings.  Lengths are not secret: differing lengths
/// return `false` at once.
@experimental
pub func constantTimeEquals(a: in slice[Byte], b: in slice[Byte]): Bool {
  if a.length != b.length {
    return false
  }
  var diff = 0
  var i = 0
  while i < a.length {
    diff = diff.or(a[i].toInt().xor(b[i].toInt()))
    i = i + 1
  }
  diff == 0
}
