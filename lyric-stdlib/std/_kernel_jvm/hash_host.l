//! std/_kernel_jvm/hash_host.l — JVM host boundary for cryptographic
//! hashing primitives.
//!
//! JVM counterpart of std/_kernel/hash_host.l.  Mirrors the same public
//! `Std.HashHost` surface (`hostSha1Bytes`, `hostSha256Bytes`, `hostSha512Bytes`,
//! `hostBytesToHex`) so `Std.Hash` compiles unchanged on both targets.
//!
//! SHA-1, SHA-256, and SHA-512 route through `java.security.MessageDigest` via
//! the JVM auto-FFI (`extern type` resolved from JDK metadata at compile time —
//! no F# host shim, no @externTarget).  `getInstance("SHA-1"|"SHA-256"|"SHA-512")`
//! returns a `MessageDigest` and `.digest(byte[])` returns the raw digest
//! (20 bytes for SHA-1, 32 bytes for SHA-256, 64 bytes for SHA-512).
//!
//! Hex conversion routes through `java.util.HexFormat` (JDK 17+, uppercase,
//! two `[0-9A-F]` chars per byte, no separator) to byte-match the .NET
//! `Convert.ToHexString` output the public `Std.Hash` API documents.
//!
//! Internal: only `Std.Hash` should import this.
@axiom("java.security.MessageDigest.getInstance(\"SHA-1\") and getInstance(\"SHA-256\") and getInstance(\"SHA-512\") conform to documented JDK SHA-1/SHA-256/SHA-512 semantics and are pure functions of their input bytes; update() over java.io.FileInputStream.readNBytes chunks digests the file's current contents")
package Std.HashHost

extern type JMessageDigest = "java.security.MessageDigest"

extern type JHexFormat = "java.util.HexFormat"

extern type JFileInput = "java.io.FileInputStream"

/// Compute the SHA-1 digest of `bytes` and return the raw 20-byte digest.
/// The `getInstance(...).digest(...)` call is chained inline so the JVM
/// auto-FFI threads the `MessageDigest` reference type straight from the
/// static call into the instance call (the receiver stays a typed `JRef`).
/// The `slice[Byte]` argument (erased to `Object[]`) is bridged to the JDK
/// primitive `byte[]` parameter by the backend's auto-FFI arg coercion.
@stable(since = "1.0")
pub func hostSha1Bytes(bytes: in slice[Byte]): slice[Byte] {
  JMessageDigest.getInstance("SHA-1").digest(bytes)
}

/// Compute the SHA-256 digest of `bytes` and return the raw 32-byte digest.
/// The `getInstance(...).digest(...)` call is chained inline so the JVM
/// auto-FFI threads the `MessageDigest` reference type straight from the
/// static call into the instance call (the receiver stays a typed `JRef`).
/// The `slice[Byte]` argument (erased to `Object[]`) is bridged to the JDK
/// primitive `byte[]` parameter by the backend's auto-FFI arg coercion.
@stable(since = "1.0")
pub func hostSha256Bytes(bytes: in slice[Byte]): slice[Byte] {
  JMessageDigest.getInstance("SHA-256").digest(bytes)
}

/// Compute the SHA-512 digest of `bytes` and return the raw 64-byte digest.
/// The `getInstance(...).digest(...)` call is chained inline so the JVM
/// auto-FFI threads the `MessageDigest` reference type straight from the
/// static call into the instance call (the receiver stays a typed `JRef`).
/// The `slice[Byte]` argument (erased to `Object[]`) is bridged to the JDK
/// primitive `byte[]` parameter by the backend's auto-FFI arg coercion.
@stable(since = "1.0")
pub func hostSha512Bytes(bytes: in slice[Byte]): slice[Byte] {
  JMessageDigest.getInstance("SHA-512").digest(bytes)
}

/// Stream the file at `path` through SHA-512 in 64 KiB chunks and return the
/// raw 64-byte digest, so hashing a large file never holds it in memory
/// (#7284). Throws when the file cannot be opened or read; the stream is
/// closed on both paths.
pub func hostSha512File(path: in String): slice[Byte] {
  val md = JMessageDigest.getInstance("SHA-512")
  val fis = JFileInput.new(path)
  try {
    var chunk = fis.readNBytes(65536)
    while chunk.length > 0 {
      md.update(chunk)
      chunk = fis.readNBytes(65536)
    }
    fis.close()
    md.digest()
  } catch Bug as b {
    fis.close()
    panic(b.message)
  }
}

/// Convert a byte slice to an uppercase hexadecimal string (one `[0-9A-F]`
/// pair per byte; no separator).  Uses `java.util.HexFormat` (JDK 17+) so
/// the output byte-matches the .NET `Convert.ToHexString` upper-case form.
pub func hostBytesToHex(bytes: in slice[Byte]): String {
  JHexFormat.of().withUpperCase().formatHex(bytes)
}
