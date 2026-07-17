//! std/tls.l - PEM certificate and private-key loading shared by TLS
//! client and server configuration (docs/61-https-tls-http-versions.md
//! §3.1, D128; phase 1.1 of epic #5874).
//!
//! `Certificate` wraps a parsed X.509 certificate (no private key);
//! `Identity` wraps a certificate paired with its private key — the shape
//! a TLS server (or an mTLS client) presents as its own credential. Both
//! load exclusively from PEM (D128: PEM is the only file format for v1;
//! PKCS#12 import is open question Q-TLS-006). Loading is `Result`-based
//! like the rest of the stdlib's I/O surface (`Std.File`, `Std.Http`):
//! a missing file, malformed PEM, an unsupported key format, or a
//! certificate/private-key mismatch are data (`TlsError`), not exceptions.
//!
//! Only unencrypted PKCS8 private keys ("-----BEGIN PRIVATE KEY-----") are
//! supported. A PKCS1/SEC1 key ("RSA PRIVATE KEY" / "EC PRIVATE KEY") or an
//! encrypted PKCS8 key ("ENCRYPTED PRIVATE KEY") is rejected as
//! `Unsupported` on BOTH targets even though .NET's own `CreateFromPemFile`
//! would silently accept a PKCS1 key — the JVM kernel's hand-rolled
//! `PKCS8EncodedKeySpec` path cannot parse PKCS1 without a real ASN.1
//! re-wrap, so `checkKeyPemSupported` below enforces the same accepted
//! shape on both targets rather than letting one accept more than the
//! other. Convert with `openssl pkcs8 -topk8 -nocrypt` if needed.
//!
//! Certificate/private-key mismatch detection is asymmetric across targets
//! by construction, not oversight — see `_kernel/tls_host.l` and
//! `_kernel_jvm/tls_host.l`'s module headers for the full explanation:
//!
//!   - **JVM** reliably detects both a same-algorithm wrong-key pairing and
//!     a cross-algorithm pairing (a sign/verify round-trip against the
//!     kernel's parsed key and the certificate's public key).
//!   - **.NET** reliably detects only a cross-algorithm pairing (e.g. an EC
//!     key paired with an RSA certificate); its own `CreateFromPemFile`
//!     raises the identical, deliberately ambiguous exception message for a
//!     same-algorithm wrong-key pairing as it does for a malformed key file,
//!     so that case surfaces as `PemMalformed`, not `KeyMismatch`, on this
//!     target. This is intentional on .NET's part (avoiding a
//!     cert/key-confirmation oracle), not a Std.Tls shortcut.
//!
//! `tls_tests.l` exercises the cross-algorithm case, which both targets
//! classify identically as `KeyMismatch`.
@runtime_checked
package Std.Tls

import Std.Core
import Std.File
import Std.Encoding
import Std.TlsHost as Host

// ---------------------------------------------------------------------------
// Core types.
// ---------------------------------------------------------------------------
/// A parsed X.509 certificate (no private key), loaded from PEM.
@stable(since = "1.2")
pub opaque type Certificate {
  handle: Host.CertHandle
}

/// A certificate plus its private key — a server or client identity.
@stable(since = "1.2")
pub opaque type Identity {
  handle: Host.CertHandle
}

/// Minimum TLS protocol version. TLS 1.2 is the floor; there is no
/// constructor for anything older.
@stable(since = "1.2")
pub enum TlsVersion {
  case Tls12
  case Tls13
}

/// PEM/certificate loading failures. `path` is `"<memory>"` for the
/// content-string constructors (`fromPem`/`Identity.fromPem`), where there
/// is no filesystem path to name.
///
/// The first case is named `CertFileNotFound`, not the shorter
/// `FileNotFound` the issue this module implements (#5876) originally
/// specced: `Std.Errors.IOError` (pulled in transitively via `Std.File`)
/// already declares a case named `FileNotFound`, and the self-hosted JVM
/// backend's pattern-match codegen resolves a bare case name from a global
/// table rather than the statically-known scrutinee type, so a consumer
/// matching `case FileNotFound(_)` against this union compiles cleanly but
/// throws `ClassCastException` at runtime on `--target jvm` only (verified;
/// identical code runs correctly on `--target dotnet`). Filed as #5903 —
/// this rename is the workaround for `Std.Tls` specifically, not a fix for
/// the underlying cross-package case-name collision.
@stable(since = "1.2")
pub union TlsError {
  // Also covers permission-denied and other unreadable-file conditions —
  // `Std.Tls` does not distinguish "absent" from "unreadable" beyond this
  // one case.
  case CertFileNotFound(path: String)
  case PemMalformed(path: String, message: String)
  case KeyMismatch(path: String, message: String)
  case Unsupported(path: String, message: String)
}

/// Human-readable message for a TlsError.
@pure
@stable(since = "1.2")
pub func TlsError.message(e: in TlsError): String {
  match e {
    case CertFileNotFound(path) -> "file not found: " + path
    case PemMalformed(path, msg) -> "malformed PEM at " + path + ": " + msg
    case KeyMismatch(path, msg) -> "certificate/key mismatch at " + path + ": " + msg
    case Unsupported(path, msg) -> "unsupported at " + path + ": " + msg
  }
}

// ---------------------------------------------------------------------------
// Server TLS configuration (docs/61 §6.3; consumed by a future
// `Std.HttpServer.startListenerTls` / `lyric-web` `serveTls`, phase 2).
// ---------------------------------------------------------------------------
/// TLS configuration for a server listener, including mTLS (D128 decision
/// 5: mutual TLS ships from v1, not as a later add-on).
///
/// Construction note: a consumer in a DIFFERENT package that omits a
/// defaulted field (e.g. `TlsServerConfig(identity = id)`, leaning on
/// `minVersion`/`clientCa`/`requireClientCert`'s declared defaults)
/// currently miscompiles on BOTH targets — a pre-existing, general
/// compiler gap in cross-package record-default construction, not specific
/// to this type: `--target jvm` produces an incorrectly-populated field
/// value (#5908), and `--target dotnet` throws
/// `System.InvalidProgramException` for the identical construction shape
/// under the source-built toolchain (#5920, the MSIL sibling of #5908).
/// **Pass every field explicitly at every construction site** (`identity`,
/// `minVersion`, `clientCa`, `requireClientCert`) until both land — the
/// declared defaults are correct as documentation of intent, but relying on
/// omission to fill them in is not yet safe on either target. See
/// `tls_server_config_tests.l` (which, per the same reasoning, has no test
/// for the omitted-defaults shape — only the explicit-fields construction
/// is covered).
@stable(since = "1.2")
pub record TlsServerConfig {
  identity: Identity
  minVersion: TlsVersion = Tls12
  clientCa: Option[Certificate] = None
  requireClientCert: Bool = false
}

// ---------------------------------------------------------------------------
// Shared loading helpers.
// ---------------------------------------------------------------------------
func readBytesOrTls(path: in String): Result[slice[Byte], TlsError] {
  match readBytes(path) {
    case Err(_) -> Err(error = CertFileNotFound(path = path))
    case Ok(list) -> Ok(value = list.toArray())
  }
}

// Recognizes a private-key PEM format this module does not support (module
// header): PKCS1/SEC1 ("RSA PRIVATE KEY" / "EC PRIVATE KEY") and encrypted
// PKCS8 ("ENCRYPTED PRIVATE KEY"). A plain PKCS8 block, or content that
// doesn't look like a key at all, returns `None` — the latter falls
// through to the kernel's own `PemMalformed` classification instead of
// being misreported as `Unsupported`.
func checkKeyPemSupported(pem: in String): Option[String] {
  if pem.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") {
    return Some(
      value = "encrypted PKCS8 private keys are not supported; decrypt to a plain PKCS8 'PRIVATE KEY' block first"
    )
  }
  if pem.contains("-----BEGIN RSA PRIVATE KEY-----") or pem.contains("-----BEGIN EC PRIVATE KEY-----") {
    return Some(
      value = "PKCS1/SEC1 private keys are not supported; convert to PKCS8 with `openssl pkcs8 -topk8 -nocrypt`"
    )
  }
  None
}

// The inner error is matched in a SEPARATE match expression from the outer
// Result, not as a nested `Err(Host.HostMalformed(msg))` pattern — the
// self-hosted JVM backend's pattern-match codegen mis-dispatches a union
// case pattern nested inside another constructor's argument position
// (verified with a minimal, TLS-unrelated two-case-union repro; filed as
// #5903's sibling finding, tracked separately). Unwrapping `Err(e)` first
// and matching `e` on its own line avoids the nested-pattern shape
// entirely and is correct on both targets.
func certFromBytes(path: in String, bytes: in slice[Byte]): Result[Certificate, TlsError] {
  match Host.hostCertFromPemBytes(bytes) {
    case Ok(handle) -> Ok(value = Certificate(handle = handle))
    case Err(hostError) -> match hostError {
      case Host.HostMalformed(msg) -> Err(error = PemMalformed(path = path, message = msg))
      // Unreachable for a cert-only load — only the identity/pairing path
      // produces HostMismatch — but HostLoadError is shared with that path,
      // so this arm exists purely to keep the match exhaustive (#5922).
      case Host.HostMismatch(msg) -> Err(error = PemMalformed(path = path, message = msg))
    }
  }
}

func identityFromBytes(
  certPath: in String, keyPath: in String, certBytes: in slice[Byte], keyBytes: in slice[Byte]
): Result[Identity, TlsError] {
  // Parse the certificate side alone first, so a malformed *certificate* is
  // reported against certPath instead of blaming the key file (#5912). The
  // pairing call below re-parses it; the double parse is the price of
  // correct error attribution, since the host pairing APIs on both targets
  // surface one undifferentiated failure for the pair.
  match Host.hostCertFromPemBytes(certBytes) {
    case Ok(_) -> ()
    case Err(certHostError) -> match certHostError {
      case Host.HostMalformed(msg) -> return Err(error = PemMalformed(path = certPath, message = msg))
      case Host.HostMismatch(msg) -> return Err(error = PemMalformed(path = certPath, message = msg))
    }
  }
  match tryDecodeUtf8(keyBytes) {
    case Some(keyText) -> match checkKeyPemSupported(keyText) {
      case Some(reason) -> return Err(error = Unsupported(path = keyPath, message = reason))
      case None -> ()
    }
    case None -> ()
  }
  match Host.hostIdentityFromPemBytes(certBytes, keyBytes) {
    case Ok(handle) -> Ok(value = Identity(handle = handle))
    case Err(hostError) -> match hostError {
      case Host.HostMismatch(msg) -> Err(error = KeyMismatch(path = keyPath, message = msg))
      case Host.HostMalformed(msg) -> Err(error = PemMalformed(path = keyPath, message = msg))
    }
  }
}

// ---------------------------------------------------------------------------
// Certificate constructors.
// ---------------------------------------------------------------------------
/// Load a certificate (no private key) from a PEM file.
///
/// # Errors
/// - `CertFileNotFound`: the file does not exist or could not be read.
/// - `PemMalformed`: the file does not contain a parseable certificate.
@stable(since = "1.2")
pub func Certificate.fromPemFile(path: in String): Result[Certificate, TlsError]
  requires: path.length > 0
{
  match readBytesOrTls(path) {
    case Err(e) -> Err(error = e)
    case Ok(bytes) -> certFromBytes(path, bytes)
  }
}

/// Load a certificate (no private key) from PEM text already in memory.
///
/// # Errors
/// - `PemMalformed`: `pem` does not contain a parseable certificate.
@stable(since = "1.2")
pub func Certificate.fromPem(pem: in String): Result[Certificate, TlsError]
  requires: pem.length > 0
{
  certFromBytes("<memory>", encodeUtf8(pem))
}

// ---------------------------------------------------------------------------
// Identity constructors.
// ---------------------------------------------------------------------------
/// Load a certificate and its private key from two PEM files.
///
/// # Errors
/// - `CertFileNotFound`: either file does not exist or could not be read.
/// - `Unsupported`: the key is PKCS1/SEC1 or encrypted PKCS8 (module header).
/// - `PemMalformed`: malformed PEM, or (on .NET only) a same-algorithm
///   certificate/key mismatch — see the module header. The error's `path`
///   names the file at fault: a certificate that fails to parse on its own
///   is reported against `certPath`; key and pairing failures against
///   `keyPath`.
/// - `KeyMismatch`: a detected certificate/key mismatch (always on JVM;
///   cross-algorithm mismatches only on .NET — module header).
@stable(since = "1.2")
pub func Identity.fromPemFiles(certPath: in String, keyPath: in String): Result[Identity, TlsError]
  requires: certPath.length > 0
  requires: keyPath.length > 0
{
  match readBytesOrTls(certPath) {
    case Err(e) -> Err(error = e)
    case Ok(certBytes) -> match readBytesOrTls(keyPath) {
      case Err(e) -> Err(error = e)
      case Ok(keyBytes) -> identityFromBytes(certPath, keyPath, certBytes, keyBytes)
    }
  }
}

/// Load a certificate and its private key from PEM text already in memory.
/// Same error discipline as `fromPemFiles`; `path` in the returned error is
/// `"<memory>"`.
@stable(since = "1.2")
pub func Identity.fromPem(certPem: in String, keyPem: in String): Result[Identity, TlsError]
  requires: certPem.length > 0
  requires: keyPem.length > 0
{
  identityFromBytes("<memory>", "<memory>", encodeUtf8(certPem), encodeUtf8(keyPem))
}
