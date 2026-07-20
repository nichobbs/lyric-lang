//! std/_kernel_native/tls_host.l — native-target host boundary for
//! Std.Tls (X.509 certificate / private-key loading, docs/61 §3.1/§7,
//! D128; issue #6103 item B, gating N9.2's `Std.TcpHost` native port).
//!
//! Mirrors `_kernel/tls_host.l` (.NET) / `_kernel_jvm/tls_host.l` (JVM):
//! same `HostLoadError` union, same two-function surface
//! (`hostCertFromPemBytes` / `hostIdentityFromPemBytes`), so
//! `std/tls.l` — which is target-independent and imports only
//! `Std.TlsHost as Host` — compiles and behaves identically once this
//! file is the one the native source loader picks up.
//!
//! ## Representation: `CertHandle` holds PEM text, not a parsed object
//!
//! Unlike the .NET twin (`X509Certificate2` handle) and the JVM twin
//! (`java.security.cert.Certificate` + `java.security.PrivateKey`), the
//! `lyric_tls_*` seam (`lyric-rt/src/lyric_tls.c`, N9.1) never hands back
//! a standalone parsed-certificate object — it only accepts PEM text
//! directly as arguments to its context constructors
//! (`lyric_tls_server_new`/`lyric_tls_client_new`/
//! `lyric_tls_client_set_identity`). There is no `lyric_tls_load_cert_pem`
//! -shaped standalone parse function in the shipped N9.1 seam (verified
//! by reading the full `lyric_rt.h` TLS section before writing this
//! file — the plan text in issue #6103 speculating such a function might
//! exist does not hold). So the native `CertHandle` is simply the PEM
//! text itself (`certPem`, and `keyPem` for an `Identity`) — exactly what
//! `_kernel_native/tcp_host.l`'s `hostAcceptTls`/`hostUpgradeServerTls`
//! need to hand straight to `lyric_tls_server_new`. No OpenSSL object
//! persists between this file's calls and tcp_host.l's.
//!
//! ## Eager validation without a persisted OpenSSL object
//!
//! `Std.Tls`'s contract is to validate PEM structure (and, for an
//! identity, the certificate/key pairing) at LOAD time
//! (`Certificate.fromPem*`/`Identity.fromPem*`), not lazily at first TLS
//! use — matching the dotnet/JVM twins. Rather than skip that guarantee
//! on native (deferring all validation to `Std.TcpHost`'s first real
//! `lyric_tls_server_new` call, which would make a malformed PEM succeed
//! at `Certificate.fromPem` and only fail much later at accept time), this
//! adds three small validate-only entry points to the seam itself
//! (`lyric_tls_validate_cert_pem`/`_key_pem`/`_identity_pem`,
//! `lyric-rt/src/lyric_tls.c`) that reuse the seam's own internal
//! `read_cert`/`read_key`/`use_identity` parse path — the exact parsing
//! `lyric_tls_server_new` already does — to answer "is this well-formed"
//! without allocating a socket-facing context. Certificate/key MATCH
//! detection goes through `SSL_CTX_check_private_key` (the same
//! primitive `lyric_tls_server_new`'s `use_identity` uses), which — like
//! the JVM twin's sign/verify round-trip, and UNLIKE the .NET twin's
//! ambiguous same-algorithm case (see `_kernel/tls_host.l`'s module
//! header) — reliably detects a same-algorithm wrong-key pairing, not
//! just a cross-algorithm one.
@axiom("lyric_tls_validate_cert_pem/_key_pem/_identity_pem (lyric-rt/src/lyric_tls.c) conform to their documented contracts")
package Std.TlsHost

import Std.Core
import Std.Encoding

/// See the two other targets' twins for the discriminator this maps to
/// (`Std.Tls` treats all three kernels identically from here).
pub union HostLoadError {
  case HostMalformed(message: String)
  case HostMismatch(message: String)
}

/// The PEM text this identity/certificate was loaded from (module
/// header). `keyPem` is `None` for a certificate-only load. `pub` fields:
/// `_kernel_native/tcp_host.l` (a different package) reads them through
/// `Std.Tls`'s `internal Identity.rawHandle`/`Certificate.rawHandle`
/// kernel-boundary accessors, the same cross-package reach the JVM twin's
/// module header documents for its own `pub cert`/`pub key` fields.
pub record CertHandle {
  pub certPem: String
  pub keyPem: Option[String]
}

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

extern func rtValidateCertPem(pem: NativePtr[Byte]): Int = "lyric_tls_validate_cert_pem"

extern func rtValidateKeyPem(pem: NativePtr[Byte]): Int = "lyric_tls_validate_key_pem"

extern func rtValidateIdentityPem(certPem: NativePtr[Byte], keyPem: NativePtr[Byte]): Int = "lyric_tls_validate_identity_pem"

extern func rtLastErrorString(): String = "lyric_tls_last_error_string"

/// Parse (validate) a certificate (no private key) from raw PEM bytes.
@unsafe_ffi
pub func hostCertFromPemBytes(bytes: in slice[Byte]): Result[CertHandle, HostLoadError] {
  match tryDecodeUtf8(bytes) {
    case None -> Err(error = HostMalformed(message = "certificate PEM is not valid UTF-8"))
    case Some(pemText) -> {
      val c = toC(pemText)
      val ok = rtValidateCertPem(c)
      freeC(c)
      if ok == 1 {
        Ok(value = CertHandle(certPem = pemText, keyPem = None))
      } else {
        Err(error = HostMalformed(message = rtLastErrorString()))
      }
    }
  }
}

/// Combine a certificate and private key from raw PEM bytes, verifying
/// the pairing via `lyric_tls_validate_identity_pem` (module header).
@unsafe_ffi
pub func hostIdentityFromPemBytes(certBytes: in slice[Byte], keyBytes: in slice[Byte]): Result[CertHandle, HostLoadError] {
  val certTextOpt = tryDecodeUtf8(certBytes)
  val keyTextOpt = tryDecodeUtf8(keyBytes)
  match certTextOpt {
    case None -> return Err(error = HostMalformed(message = "certificate PEM is not valid UTF-8"))
    case Some(_) -> ()
  }
  match keyTextOpt {
    case None -> return Err(error = HostMalformed(message = "private key PEM is not valid UTF-8"))
    case Some(_) -> ()
  }
  val certText = match certTextOpt {
    case Some(t) -> t
    case None -> ""
  }
  val keyText = match keyTextOpt {
    case Some(t) -> t
    case None -> ""
  }
  // Cert-only validation first, so a malformed CERTIFICATE (as opposed to
  // a malformed key, or a mismatched pairing) is reported distinctly —
  // std/tls.l's identityFromBytes relies on exactly this ordering to
  // attribute the error to the right file path.
  val certC = toC(certText)
  val certOk = rtValidateCertPem(certC)
  if certOk != 1 {
    freeC(certC)
    return Err(error = HostMalformed(message = rtLastErrorString()))
  }
  val keyC = toC(keyText)
  val keyOk = rtValidateKeyPem(keyC)
  if keyOk != 1 {
    freeC(keyC)
    freeC(certC)
    return Err(error = HostMalformed(message = rtLastErrorString()))
  }
  val matchOk = rtValidateIdentityPem(certC, keyC)
  freeC(keyC)
  freeC(certC)
  if matchOk == 1 {
    Ok(value = CertHandle(certPem = certText, keyPem = Some(value = keyText)))
  } else {
    Err(error = HostMismatch(message = rtLastErrorString()))
  }
}
