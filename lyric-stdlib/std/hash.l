//! std/hash.l — cryptographic hash helpers.
//!
//! Currently exposes SHA-512 only (sufficient for lock-file content
//! integrity per docs/39 §5.2).  Returns uppercase hex strings so the
//! output is filesystem-safe and matches the wire format used by NuGet
//! signing manifests.
package Std.Hash

import Std.Core
import Std.HashHost
import Std.FileHost

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
