//! std/_kernel/tls_host.l - host boundary for Std.Tls (X.509 certificate /
//! private-key loading, docs/61 §3.1, D128).
//!
//! Every public function takes already-validated bytes (`Std.Tls` reads the
//! file or owns the caller's content string before calling in, so this
//! boundary never has to classify a missing-file error itself) and returns
//! `Result[CertHandle, HostLoadError]` rather than throwing, mirroring how
//! `_kernel/http_host.l`'s `*Safe` wrappers turn host exceptions into data.
//!
//! Certificate parsing uses `X509CertificateLoader` (the non-obsolete
//! .NET 9+ replacement for the `X509Certificate2` byte[]/string
//! constructors, SYSLIB0057) rather than `X509Certificate2.CreateFromPem`:
//! `X509CertificateLoader.LoadCertificate`/`LoadCertificateFromFile` both
//! auto-detect PEM vs DER and take a plain `byte[]`/`string`, so they
//! resolve cleanly through the auto-FFI metadata binder. `CreateFromPem`
//! (cert-only) takes `ReadOnlySpan<char>`, which the binder cannot resolve
//! from a Lyric `String` argument (no case in `scoreSigType`,
//! `lyric-compiler/msil/metadata_reader.l`, for a generic value-type span)
//! — verified empirically (`dotnet run` against a throwaway harness) before
//! choosing `X509CertificateLoader` over it.
//!
//! Identity (cert + private key) loading is the one case that genuinely
//! needs the span-blocked API: .NET's only PEM-pair combinator,
//! `X509Certificate2.CreateFromPem(ReadOnlySpan<char> certPem,
//! ReadOnlySpan<char> keyPem)` / `CreateFromPemFile(string, string)`, has no
//! byte[]/string overload for the *content* form (only `CreateFromPemFile`'s
//! file-path parameters are plain strings). Every modern key-import API
//! (`RSA.ImportPkcs8PrivateKey`, `AsymmetricAlgorithm.ImportPkcs8PrivateKey`,
//! `X509Certificate2.CopyWithPrivateKey`'s key-construction side) is
//! `ReadOnlySpan<byte>` + `out int`-shaped too — also unreachable. Until the
//! compiler gains span-parameter binding, `hostIdentityFromPemBytes` bridges
//! by writing both PEM blocks to per-call, randomly-named temp files
//! (`Path.GetRandomFileName()`, not sequential) and delegating to
//! `CreateFromPemFile`, deleting both files immediately after (success or
//! failure) so the exposure window is as short as a `WriteAllBytes` +
//! `CreateFromPemFile` pair. The temp files inherit the OS temp directory's
//! default permissions for that window — callers with stricter requirements
//! should prefer `Std.Tls.Identity.fromPemFiles` (loads real file paths,
//! whose permissions are entirely the caller's own choice) over
//! `Identity.fromPem` (in-memory content) when that matters. `Std.Tls`
//! funnels every entry point (`fromPemFile` and `fromPem`) through the same
//! bytes-taking kernel functions below for symmetry: `hostCertFromPemBytes`
//! never needs the bridge (cert-only has no span-blocked API), and unifying
//! the shape keeps this file's surface to two functions instead of four.
//!
//! Key-mismatch classification: .NET's `CreateFromPemFile` throws the
//! *identical* `CryptographicException` message ("The key contents do not
//! contain a PEM, the content is malformed, or the key does not match the
//! certificate.") for a missing key section, a malformed key file, AND a
//! same-algorithm wrong-key pairing — verified empirically; there is no way
//! to distinguish "malformed" from "mismatched" from that message alone, so
//! `classifyIdentityError` conservatively maps it to `HostMalformed` rather
//! than guessing `HostMismatch`. A *cross-algorithm* mismatch (e.g. an EC key
//! paired with an RSA certificate) raises a distinct, reliably-matchable
//! message ("Key is not a valid public or private key.") and DOES map to
//! `HostMismatch`. `Std.Tls`'s doc comments and self-test describe this
//! asymmetry honestly rather than claiming full same-algorithm mismatch
//! detection on this target (the JVM twin, `_kernel_jvm/tls_host.l`, detects
//! both shapes via a sign/verify round-trip).
@axiom("System.Security.Cryptography.X509Certificates operations conform to their documented .NET contracts")
package Std.TlsHost

import Std.Core

extern type CertHandle = "System.Security.Cryptography.X509Certificates.X509Certificate2"

extern type X509CertLoader = "System.Security.Cryptography.X509Certificates.X509CertificateLoader"

extern type NetFile = "System.IO.File"

extern type NetPath = "System.IO.Path"

/// Kernel-local classification of a load failure. `Std.Tls` maps
/// `HostMalformed` to `TlsError.PemMalformed` and `HostMismatch` to
/// `TlsError.KeyMismatch`; see the module header for what this target can
/// and cannot tell apart.
pub union HostLoadError {
  case HostMalformed(message: String)
  case HostMismatch(message: String)
}

func newTempPath(): String {
  NetPath.Combine(NetPath.GetTempPath(), NetPath.GetRandomFileName())
}

func deleteTempQuietly(path: in String): Unit {
  try {
    NetFile.Delete(path)
  } catch Bug as _ {
    ()
  }
}

/// Cross-algorithm key/cert pairings raise this exact message; everything
/// else (missing key, malformed key, same-algorithm wrong key) is
/// deliberately ambiguous on this target — see the module header.
func classifyIdentityError(message: in String): HostLoadError {
  if message.contains("Key is not a valid public or private key") {
    HostMismatch(message = message)
  } else {
    HostMalformed(message = message)
  }
}

/// Parse a certificate (no private key) from raw bytes — PEM or DER,
/// auto-detected by `X509CertificateLoader`.
pub func hostCertFromPemBytes(bytes: in slice[Byte]): Result[CertHandle, HostLoadError] {
  try {
    Ok(value = X509CertLoader.LoadCertificate(bytes))
  } catch Bug as b {
    Err(error = HostMalformed(message = b.message))
  }
}

/// Combine a certificate and private key from raw PEM bytes into one
/// identity handle. Bridges the `ReadOnlySpan<char>`-only
/// `CreateFromPem(certPem, keyPem)` overload via per-call temp files (module
/// header); both are deleted immediately after this call returns, on every
/// path.
pub func hostIdentityFromPemBytes(certBytes: in slice[Byte], keyBytes: in slice[Byte]): Result[CertHandle, HostLoadError] {
  val certPath = newTempPath()
  val keyPath = newTempPath()
  try {
    NetFile.WriteAllBytes(certPath, certBytes)
    NetFile.WriteAllBytes(keyPath, keyBytes)
    val handle = CertHandle.CreateFromPemFile(certPath, keyPath)
    deleteTempQuietly(certPath)
    deleteTempQuietly(keyPath)
    Ok(value = handle)
  } catch Bug as b {
    deleteTempQuietly(certPath)
    deleteTempQuietly(keyPath)
    Err(error = classifyIdentityError(b.message))
  }
}
