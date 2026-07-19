//! std/_kernel/hash_host.l — host boundary for cryptographic hashing
//! primitives.
//!
//! Four .NET externs:
//!   * `System.Security.Cryptography.SHA1.HashData(byte[]) -> byte[]`
//!   * `System.Security.Cryptography.SHA256.HashData(byte[]) -> byte[]`
//!   * `System.Security.Cryptography.SHA512.HashData(byte[]) -> byte[]`
//!   * `System.Convert.ToHexString(byte[]) -> string`
//!
//! Composed by `Std.Hash.sha1OfBytes`, `sha256OfBytes`, and `sha512OfBytes`
//! into public helpers. Internal: only `Std.Hash` should import this.
@axiom("System.Security.Cryptography.SHA1.HashData + System.Security.Cryptography.SHA256.HashData + System.Security.Cryptography.SHA512.HashData + System.Convert.ToHexString conform to documented .NET semantics; all are pure functions")
package Std.HashHost

extern type NetSha1 = "System.Security.Cryptography.SHA1"

extern type NetSha256 = "System.Security.Cryptography.SHA256"

extern type NetSha512 = "System.Security.Cryptography.SHA512"

extern type NetConvert = "System.Convert"

/// Compute the SHA-1 digest of `bytes` and return the raw 20-byte digest.
@stable(since = "1.0")
pub func hostSha1Bytes(bytes: in slice[Byte]): slice[Byte] {
  NetSha1.HashData(bytes)
}

/// Compute the SHA-256 digest of `bytes` and return the raw 32-byte digest.
@stable(since = "1.0")
pub func hostSha256Bytes(bytes: in slice[Byte]): slice[Byte] {
  NetSha256.HashData(bytes)
}

/// Compute the SHA-512 digest of `bytes` and return the raw 64-byte digest.
@stable(since = "1.0")
pub func hostSha512Bytes(bytes: in slice[Byte]): slice[Byte] {
  NetSha512.HashData(bytes)
}

/// Convert a byte slice to an uppercase hexadecimal string (one `[0-9A-F]`
/// pair per byte; no separator).
pub func hostBytesToHex(bytes: in slice[Byte]): String {
  NetConvert.ToHexString(bytes)
}
