//! std/hash.l — cryptographic hash helpers.
//!
//! Exposes SHA-256 and SHA-512 (sufficient for lock-file content
//! integrity per docs/39 §5.2, and contract metadata integrity per
//! docs/45 §2–§3), plus SHA-1 (`sha1OfBytes`) for the RFC 6455 WebSocket
//! handshake's `Sec-WebSocket-Accept` derivation — not a security boundary,
//! see that function's doc comment.  Returns uppercase hex strings so the
//! output is filesystem-safe and matches the wire format used by NuGet
//! signing manifests.
package Std.Hash

import Std.Core
import Std.HashHost
import Std.FileHost

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
pub func sha1OfBytes(bytes: in slice[Byte]): String {
  hostBytesToHex(hostSha1Bytes(bytes))
}

/// Compute the SHA-256 of `bytes` and return the digest as an uppercase
/// 64-character hex string.
@stable(since = "1.0")
pub func sha256OfBytes(bytes: in slice[Byte]): String {
  hostBytesToHex(hostSha256Bytes(bytes))
}

/// Compute the SHA-512 of `bytes` and return the digest as an uppercase
/// 128-character hex string.
@stable(since = "1.0")
pub func sha512OfBytes(bytes: in slice[Byte]): String {
  hostBytesToHex(hostSha512Bytes(bytes))
}

/// Compute the SHA-512 of the file at `path`.  Returns `Err(message)`
/// when the file cannot be read (missing, permission denied, etc.) —
/// the caller decides whether that's fatal.
@stable(since = "1.0")
pub func sha512OfFile(path: in String): Result[String, String] {
  try {
    val bytes = hostReadAllBytes(path)
    Ok(value = sha512OfBytes(bytes))
  } catch Bug as b {
    Err(error = b.message)
  }
}
