//! std/_kernel/hash_host.l — host boundary for cryptographic hashing
//! primitives.
//!
//! Three .NET externs:
//!   * `System.Security.Cryptography.SHA256.HashData(byte[]) -> byte[]`
//!   * `System.Security.Cryptography.SHA512.HashData(byte[]) -> byte[]`
//!   * `System.Convert.ToHexString(byte[]) -> string`
//!
//! Composed by `Std.Hash.sha256OfBytes` and `sha512OfBytes` into public helpers.
//! Internal: only `Std.Hash` should import this.
@axiom("System.Security.Cryptography.SHA256.HashData + System.Security.Cryptography.SHA512.HashData + System.Convert.ToHexString conform to documented .NET semantics; all are pure functions")
package Std.HashHost

/// Compute the SHA-256 digest of `bytes` and return the raw 32-byte digest.
@externTarget("System.Security.Cryptography.SHA256.HashData")
@stable(since = "1.0")
pub func hostSha256Bytes(bytes: in slice[Byte]): slice[Byte] = ()

/// Compute the SHA-512 digest of `bytes` and return the raw 64-byte digest.
@externTarget("System.Security.Cryptography.SHA512.HashData")
@stable(since = "1.0")
pub func hostSha512Bytes(bytes: in slice[Byte]): slice[Byte] = ()

/// Convert a byte slice to an uppercase hexadecimal string (one `[0-9A-F]`
/// pair per byte; no separator).
@externTarget("System.Convert.ToHexString")
pub func hostBytesToHex(bytes: in slice[Byte]): String = ()
