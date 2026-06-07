//! std/_kernel_jvm/hash_host.l — JVM host boundary for cryptographic
//! hashing primitives.
//!
//! JVM counterpart of std/_kernel/hash_host.l.  Mirrors the same public
//! `Std.HashHost` surface (`hostSha512Bytes`, `hostBytesToHex`) so
//! `Std.Hash` compiles unchanged on both targets.
//!
//! SHA-512 routes through `java.security.MessageDigest` via the JVM
//! auto-FFI (`extern type` resolved from JDK metadata at compile time —
//! no F# host shim, no @externTarget).  `getInstance("SHA-512")` returns
//! a `MessageDigest` and `.digest(byte[])` returns the raw 64-byte digest.
//!
//! Hex conversion routes through `java.util.HexFormat` (JDK 17+, uppercase,
//! two `[0-9A-F]` chars per byte, no separator) to byte-match the .NET
//! `Convert.ToHexString` output the public `Std.Hash` API documents.
//!
//! Internal: only `Std.Hash` should import this.
@axiom("java.security.MessageDigest.getInstance(\"SHA-512\").digest conforms to documented JDK SHA-512 semantics and is a pure function of its input bytes")
package Std.HashHost

extern type JMessageDigest = "java.security.MessageDigest"

extern type JHexFormat = "java.util.HexFormat"

/// Compute the SHA-512 digest of `bytes` and return the raw 64-byte digest.
/// The `getInstance(...).digest(...)` call is chained inline so the JVM
/// auto-FFI threads the `MessageDigest` reference type straight from the
/// static call into the instance call (the receiver stays a typed `JRef`).
/// The `slice[Byte]` argument (erased to `Object[]`) is bridged to the JDK
/// primitive `byte[]` parameter by the backend's auto-FFI arg coercion.
pub func hostSha512Bytes(bytes: in slice[Byte]): slice[Byte] {
  JMessageDigest.getInstance("SHA-512").digest(bytes)
}

/// Convert a byte slice to an uppercase hexadecimal string (one `[0-9A-F]`
/// pair per byte; no separator).  Uses `java.util.HexFormat` (JDK 17+) so
/// the output byte-matches the .NET `Convert.ToHexString` upper-case form.
pub func hostBytesToHex(bytes: in slice[Byte]): String {
  JHexFormat.of().withUpperCase().formatHex(bytes)
}
