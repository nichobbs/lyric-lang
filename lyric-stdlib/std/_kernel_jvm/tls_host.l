//! std/_kernel_jvm/tls_host.l - JVM host boundary for Std.Tls.
//!
//! Mirrors `_kernel/tls_host.l` for the JVM target: certificates parse via
//! `java.security.cert.CertificateFactory` (which, like .NET's
//! `X509CertificateLoader`, accepts PEM bytes directly — no manual armor
//! stripping needed for certs). Private keys have no such convenience on
//! this target: `PKCS8EncodedKeySpec`/`KeyFactory` need raw DER, so the PEM
//! armor is stripped and the base64 body decoded in pure Lyric
//! (`Std.Encoding.tryDecodeBase64`, docs/61 §3.1) before handing the bytes
//! to `KeyFactory`. Only unencrypted PKCS8 ("PRIVATE KEY") blocks are
//! supported — `Std.Tls` itself rejects PKCS1/SEC1/encrypted labels before
//! ever calling in here (see `tls.l`'s `checkKeyPemSupported`), so this file
//! only has to probe RSA vs EC.
//!
//! Representation: unlike .NET's unified `X509Certificate2` (which carries
//! an optional private key on the same object), the JDK keeps certificates
//! (`java.security.cert.Certificate`) and private keys
//! (`java.security.PrivateKey`) as separate objects, so `CertHandle` here is
//! a plain Lyric record pairing them (an `Option[JPrivateKey]`, `None` for a
//! cert-only load) rather than an extern alias.
//!
//! Key-mismatch detection: there is no direct "does this key belong to this
//! cert" JDK call, so `hostIdentityFromPemBytes` performs a sign/verify
//! round-trip — sign a fixed probe message with the parsed private key,
//! then verify the signature against the certificate's public key using the
//! same algorithm. This is the standard technique for this exact question
//! (used identically by both RSA and EC keys via `java.security.Signature`).
//! A same-algorithm wrong-key pairing makes `verify` return false; a
//! cross-algorithm pairing makes `initVerify`/`verify` throw
//! `InvalidKeyException` for the wrong key type — both are normalized to
//! `HostMismatch` (the inner `try` around `keysMatch` folds a thrown
//! exception into `false`) — verified empirically against real
//! matched/mismatched RSA and EC fixtures. This is strictly stronger
//! mismatch detection than the .NET twin can offer for a same-algorithm
//! wrong-key pairing (`_kernel/tls_host.l`'s module header documents why
//! that case is ambiguous there); `Std.Tls`'s self-test and doc comments
//! describe the asymmetry rather than assuming parity.
@axiom("java.security.cert / java.security.KeyFactory / java.security.Signature operations conform to their documented JVM contracts")
package Std.TlsHost

import Std.Core
import Std.Encoding
import Std.String

extern type JCertificateFactory = "java.security.cert.CertificateFactory"

extern type JCertificate = "java.security.cert.Certificate"

extern type JByteArrayInputStream = "java.io.ByteArrayInputStream"

extern type JPKCS8EncodedKeySpec = "java.security.spec.PKCS8EncodedKeySpec"

extern type JKeyFactory = "java.security.KeyFactory"

extern type JPrivateKey = "java.security.PrivateKey"

extern type JSignature = "java.security.Signature"

extern type JString = "java.lang.String"

/// See `_kernel/tls_host.l`'s twin for the discriminator this maps to
/// (`Std.Tls` treats both kernels identically from here).
pub union HostLoadError {
  case HostMalformed(message: String)
  case HostMismatch(message: String)
}

/// A parsed certificate plus an optional private key (module header) — the
/// JVM analog of .NET's `X509Certificate2` handle.
pub record CertHandle {
  cert: JCertificate
  key: Option[JPrivateKey]
}

func parseCert(bytes: in slice[Byte]): JCertificate {
  val cf: JCertificateFactory = JCertificateFactory.getInstance("X.509")
  val ins = JByteArrayInputStream.new(bytes)
  cf.generateCertificate(ins)
}

// Strip the PEM header/footer of an unencrypted PKCS8 "PRIVATE KEY" block
// and decode the remaining base64 body to DER. `Std.Tls` has already
// confirmed the label is "PRIVATE KEY" (not PKCS1/SEC1/encrypted) before
// this is ever called; a malformed body still falls through to
// `tryDecodeBase64`'s `None`, panicking here so the caller's `try`/`catch`
// maps it to `HostMalformed`.
func pkcs8DerBytes(keyPem: in String): slice[Byte] {
  match tryDecodeUtf8(encodeUtf8(keyPem)) {
    case None -> panic("Std.TlsHost: private key PEM is not valid UTF-8")
    case Some(_) -> ()
  }
  var body = ""
  var inBlock = false
  for line in keyPem.split("\n") {
    val trimmed = line.trim()
    if trimmed.startsWith("-----BEGIN") {
      inBlock = true
    } else if trimmed.startsWith("-----END") {
      inBlock = false
    } else if inBlock and trimmed.length > 0 {
      body = body + trimmed
    }
  }
  match tryDecodeBase64(body) {
    case Some(der) -> der
    case None -> panic("Std.TlsHost: private key PEM base64 body is malformed")
  }
}

func parseKey(keyPem: in String): JPrivateKey {
  val der = pkcs8DerBytes(keyPem)
  val spec = JPKCS8EncodedKeySpec.new(der)
  try {
    JKeyFactory.getInstance("RSA").generatePrivate(spec)
  } catch Bug as _ {
    JKeyFactory.getInstance("EC").generatePrivate(spec)
  }
}

// Sign a fixed probe message with `key` and verify it against `cert`'s
// public key (module header). Returns false for a same-algorithm wrong-key
// pairing; throws for a cross-algorithm pairing (caught by the caller).
func signatureAlgorithmFor(key: in JPrivateKey): String {
  if key.getAlgorithm() == "RSA" {
    "SHA256withRSA"
  } else {
    "SHA256withECDSA"
  }
}

func keysMatch(cert: in JCertificate, key: in JPrivateKey): Bool {
  val alg = signatureAlgorithmFor(key)
  val data = encodeUtf8("lyric-tls-key-match-probe")
  val signer: JSignature = JSignature.getInstance(alg)
  signer.initSign(key)
  signer.update(data)
  val sig = signer.sign()
  val verifier: JSignature = JSignature.getInstance(alg)
  verifier.initVerify(cert.getPublicKey())
  verifier.update(data)
  verifier.verify(sig)
}

/// Parse a certificate (no private key) from raw PEM bytes.
pub func hostCertFromPemBytes(bytes: in slice[Byte]): Result[CertHandle, HostLoadError] {
  try {
    Ok(value = CertHandle(cert = parseCert(bytes), key = None))
  } catch Bug as b {
    Err(error = HostMalformed(message = b.message))
  }
}

/// Combine a certificate and private key from raw PEM bytes, verifying the
/// pairing via `keysMatch` (module header).
pub func hostIdentityFromPemBytes(certBytes: in slice[Byte], keyBytes: in slice[Byte]): Result[CertHandle, HostLoadError] {
  try {
    val cert = parseCert(certBytes)
    val keyPem = match tryDecodeUtf8(keyBytes) {
      case Some(text) -> text
      case None -> panic("Std.TlsHost: private key PEM is not valid UTF-8")
    }
    val key = parseKey(keyPem)
    val matched = try {
      keysMatch(cert, key)
    } catch Bug as _ {
      false
    }
    if not matched {
      return Err(error = HostMismatch(message = "the private key does not match the certificate's public key"))
    }
    Ok(value = CertHandle(cert = cert, key = Some(value = key)))
  } catch Bug as b {
    Err(error = HostMalformed(message = b.message))
  }
}
