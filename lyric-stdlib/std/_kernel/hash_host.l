//! std/_kernel/hash_host.l — host boundary for cryptographic hashing
//! primitives.
//!
//! Two .NET externs:
//!   * `System.Security.Cryptography.SHA512.HashData(byte[]) -> byte[]`
//!   * `System.Convert.ToHexString(byte[]) -> string`
//!
//! Composed by `Std.Hash.sha512OfBytes` into a single public helper.
//! Internal: only `Std.Hash` should import this.
@axiom("System.Security.Cryptography.SHA512.HashData + System.Convert.ToHexString conform to documented .NET semantics; both are pure functions")
package Std.HashHost

/// Compute the SHA-512 digest of `bytes` and return the raw 64-byte digest.
@externTarget("System.Security.Cryptography.SHA512.HashData")
pub func hostSha512Bytes(bytes: in slice[Byte]): slice[Byte] = ()

/// Convert a byte slice to an uppercase hexadecimal string (one `[0-9A-F]`
/// pair per byte; no separator).
@externTarget("System.Convert.ToHexString")
pub func hostBytesToHex(bytes: in slice[Byte]): String = ()
