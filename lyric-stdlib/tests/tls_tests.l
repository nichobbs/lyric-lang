//! stdlib/tests/tls_tests.l — Tests for Std.Tls (docs/61-https-tls-http-versions.md
//! §3.1, D128; phase 1.1 of epic #5874, issue #5876).
//!
//! Fixtures are a self-signed RSA certificate/key pair and a self-signed EC
//! certificate/key pair (both PKCS8, unencrypted, generated once with
//! `openssl req -x509 -newkey rsa:2048 -nodes ...` / `-newkey ec ...` and
//! embedded as string literals — no external fixture files, matching every
//! other `lyric-stdlib/tests/*.l` suite's self-contained-source convention).
//! Both certificates are valid for ten years from generation, so this suite
//! does not depend on wall-clock time.
//!
//! Covers: successful cert load (RSA and EC), successful identity load (RSA
//! and EC, matched cert+key pairs), malformed PEM -> `PemMalformed`, missing
//! file -> `CertFileNotFound` (see `Std.Tls`'s doc comment for why this case
//! isn't named `FileNotFound` — a pre-existing JVM backend cross-package
//! case-name collision, #5903), an unsupported PKCS1 private key ->
//! `Unsupported`, and a certificate/private-key mismatch -> `KeyMismatch`.
//!
//! The mismatch case deliberately uses a CROSS-algorithm pairing (an RSA
//! certificate with an EC private key): `Std.Tls`'s module header explains
//! that this is the only mismatch shape both targets classify identically
//! as `KeyMismatch` — a same-algorithm wrong-key pairing is ambiguous with
//! `PemMalformed` on .NET (verified against the real BCL API; see
//! `_kernel/tls_host.l`). Asserting a same-algorithm mismatch here would
//! require a target-conditional expectation, which is exactly the kind of
//! "lying test" the module's honesty policy is written against — so this
//! suite sticks to the one shape that is genuinely dual-target-reliable.
//!
//! Runs via native `lyric test` on `--target dotnet`, `--target jvm` and
//! `--target native`.
//!
//! `TlsServerConfig` is covered separately in `tls_server_config_tests.l`
//! (both targets). Its default-field-omission behavior has no test on any
//! target: omitted-default construction currently miscompiles on JVM
//! (#5908) and dotnet (#5920) — see that file's header and D-progress-689.
//!
//! CA bundles (#9146, D610), from `ca1Pem` below on: `Certificate` from PEM
//! text with several certificates, on every target. A `Certificate` carries EVERY certificate of the PEM text it was loaded
//! from, and every one is a trust anchor wherever the certificate is used as
//! a CA (`HttpClientBuilder.withCaCertificate`/`withExclusiveCaCertificate`,
//! `TlsServerConfig.clientCa`). Before #9146 dotnet and the JVM used only the
//! first certificate and native trusted all of them.
//!
//! Loading rules covered here: text outside the `CERTIFICATE` blocks
//! (comments, blank lines, other PEM labels) is ignored; a text with no
//! certificate block is `PemMalformed` as before; a malformed or unterminated
//! block anywhere in the text is `PemMalformed` naming its position, never
//! silently skipped.
//!
//! The handshake cases use a real `Std.HttpServer.startListenerTls` listener
//! on a loopback port, served from a `Std.Task` scope thread, and the real
//! `Std.Http` client. The server certificate is signed by the SECOND CA of
//! the two-CA bundle: the client trusts it when given the bundle (exclusive
//! and additive, either order) and rejects it when given only the first CA.
//!
//! Fixtures (test only, embedded so the suite is self-contained): two EC
//! P-256 CAs (`lyric-bundle-test-ca-1`, `-2`) and a server leaf for
//! `localhost` / 127.0.0.1 signed by CA 2, all valid for a hundred years
//! from 2026-11-16. Generated with `openssl req -x509` / `openssl x509 -req`.
//!
@test_module
package Std.Tls.Tests

import Std.Core
import Std.Errors
import Std.File
import Std.Http
import Std.HttpServer
import Std.Task as Task
import Std.Tls
import Std.Testing
import Std.Uuid

// Self-signed RSA 2048 certificate, CN=test-rsa, valid 2026-07-16..2036-07-13.
val rsaCert = """
-----BEGIN CERTIFICATE-----
MIIDBzCCAe+gAwIBAgIUDO4hKdbmesejzWOGU8z7H2gwVQQwDQYJKoZIhvcNAQEL
BQAwEzERMA8GA1UEAwwIdGVzdC1yc2EwHhcNMjYwNzE2MjEzMTUzWhcNMzYwNzEz
MjEzMTUzWjATMREwDwYDVQQDDAh0ZXN0LXJzYTCCASIwDQYJKoZIhvcNAQEBBQAD
ggEPADCCAQoCggEBAMOdR2CrWmdulgLWwwPkz37aEMcm9vJENZ9J6sd9lxkltvSt
glE3EczI1m4f6IJiuUYq7//lwyaowapYCJvc2kbkUOFGDJfxe2ELkMgwops7gDGH
5lDh3CKMCVkGmtuk0FT+rIruwR+XgnDcw5ifPFEFE7vq96CVjyExh/JOyD2IOYOS
hR4oPER/6UAlTcURTZDm+LDxXA8BtiCAwj9XRaITNPsztd4X2rv7+EQUa2So06+b
OYBcCyMLO1wg6yRNVLSrDK9liy0yHoYfwfheswysgUsD2boK5wpw/tm817Sn0bk2
UtzdbHpU7Kbs5lVASsUXVbHw+NhgrpaHBs7Vb18CAwEAAaNTMFEwHQYDVR0OBBYE
FLlqJyx1wcyMlE4DrwcrLleQzmeBMB8GA1UdIwQYMBaAFLlqJyx1wcyMlE4Drwcr
LleQzmeBMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAC/yP0CP
My6At2yb5iCxuTQYE7rgZtv1wPR4/DkMEG06irJFIbOv2V00YmfX/xdnjv7980k+
BTGqdTqdZDP96kjNW/YSc103Y2BUug8DjZTaVil1Dxo3XmVLtjBzLZbvT2vhNjpz
ksKTsW6nzvDpaOxIEe+OkzRQ8/9US9BHIMNjySoLfIYipTSjoYEqt2xBzk6Nww2+
DJCeysBvs+6jNHnvWmbRP3TytQx8tL4i2cnQAbzGj3pIqWw6hyySt/nJq2bQX7AM
qxdPKRzWq4cCAx7gncwiyQsqO53BksnG8uQn/uJsT4lP0txrrwJRClypoKRV6+jq
mPcVDnIORvhyajE=
-----END CERTIFICATE-----
"""

// Matching unencrypted PKCS8 RSA private key.
val rsaKey = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDDnUdgq1pnbpYC
1sMD5M9+2hDHJvbyRDWfSerHfZcZJbb0rYJRNxHMyNZuH+iCYrlGKu//5cMmqMGq
WAib3NpG5FDhRgyX8XthC5DIMKKbO4Axh+ZQ4dwijAlZBprbpNBU/qyK7sEfl4Jw
3MOYnzxRBRO76veglY8hMYfyTsg9iDmDkoUeKDxEf+lAJU3FEU2Q5viw8VwPAbYg
gMI/V0WiEzT7M7XeF9q7+/hEFGtkqNOvmzmAXAsjCztcIOskTVS0qwyvZYstMh6G
H8H4XrMMrIFLA9m6CucKcP7ZvNe0p9G5NlLc3Wx6VOym7OZVQErFF1Wx8PjYYK6W
hwbO1W9fAgMBAAECggEAAIapPxwAc7vAbbe5yx/8sNrvdq5vYCpnQdgZV1vsdyCc
75G0AoI7opZfzgq9UvSzm09Utyd7DNSHrVMoAwlrTPqAh7XANnO4WoP0FGqIiBLM
hVnX52ikm+8KRNyVhMFaeJkbY5tSBW2PcIljtNx10zqd1TOy2iu6p2+yXIYUT5GC
sqTO7L1pimk1wD4RoLhGXSnK8oYXPCPyxWLfDNNw8HR8XhR0Xc9ZZtPap+qVOO6V
g2aVGHqHojwB9C52TS2a3xTW+H9gj6H8Iao8Zd3Wj7GDubslf6iLO/12SUF0/V42
dQ1KDg9eLOox02OP142UlVd7C5bBIYStaqoOha4k+QKBgQD8oCqkhdVoVFaqDcJ1
3aVIBrqaVYJ8RnjFr61ar2CNvh0GhA9iPYUCc86WWNSEkJ0Z9mfV4x9ROqI9Hf9F
ythB9H4zQTz9brdlOsFUJj4nCiaBV1l8u1QVlp1oWWhMawhhjcNCZmvlp4Kv6Lfr
8RfOw7C1YCyzVn3kxhU3QaWJaQKBgQDGOiqrvxply7lBvEJldDmwEgH8LzfU1+ia
Dnhq9LD+o3oxIUKSF8+Yi7EDiqR2qhqrju+OnrOIVCJptDTL+qPrvlGrkffzdh7f
kjUI6JcjFburuwFtyjZ3MgcwvmQqmoe5SbF39nukuWU7XNnamwjcecdK8xrRoMQi
wDbB19oRhwKBgBz40Wsk3iCk63t9MHwL+1STUPs6K0jNXDRvvVXVHyGiV/nTU2BU
5dguJ9ceQOEjJKFBnQ7uiTzrmIeh1RDP/pUx0PdX2ALIm8fEQT/BUwdvJpNWzTB8
21vOdibtegSpkcB+XZJT5LPlzhsWeWFZuP1BfBaQ/Q9kL/P4s54urSlhAoGAaOzt
HU/gpzV48ES4WH928a32gwhzYySOKM20C9lNvtvFmC/kzvPvnO2EWz2N5IoR5/GW
+EUk/uqZ9J3AvKAFGIn7LPfs6WAC45C+peKH7bhZSIOKNBUvU1SV3cVJvAtkAD3z
xG4h8IV6AjwZzM73l8yWIyQfdArHByX7VgvtkA0CgYEA11lPJlkOv3u/g1788zDb
EMHKJlE8t0ACUGfhHcxkvzCDJA0uiZUZNCVnkJPKaq+ITAaCnqa2eGqLqcyFOo5N
cTeg+l0KrzjQe6Q2hOojgqg7mskbY4sZGno7Pv+syl9h0aDjdxCBaX+ROQkm79IR
doONW2QlEIagNnVFFGh2abM=
-----END PRIVATE KEY-----
"""

// Self-signed EC (prime256v1) certificate, CN=test-ec, valid 2026-07-16..2036-07-13.
val ecCert = """
-----BEGIN CERTIFICATE-----
MIIBeTCCAR+gAwIBAgIUEUua1Ln/BdiSuD4kl2EGaAyN3nEwCgYIKoZIzj0EAwIw
EjEQMA4GA1UEAwwHdGVzdC1lYzAeFw0yNjA3MTYyMTMxNTNaFw0zNjA3MTMyMTMx
NTNaMBIxEDAOBgNVBAMMB3Rlc3QtZWMwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC
AASD7YZJxyb68cpqr3VPJ69RXb1hFZ4bhuSMJMRpcgtjTHmxLRxbUBXOHADxiqST
69mISwKPimceHupdredZ2kh8o1MwUTAdBgNVHQ4EFgQUnRDUcAQ670ywcmlYe9O2
EDB7GvEwHwYDVR0jBBgwFoAUnRDUcAQ670ywcmlYe9O2EDB7GvEwDwYDVR0TAQH/
BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiBuADJG1zuxiAlVHUvFwlbeEyGuBlL7
Zy9pRvU1EdkFVwIhAMgYIFE9BjU83squKth3o+i/wJP0c7GBioWQ+JbUAmNR
-----END CERTIFICATE-----
"""

// Matching unencrypted PKCS8 EC private key.
val ecKey = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgbwfYSUX3I8R8PmQ1
j8AeSbsJaob/uzAXOG+sE1b+U5ihRANCAASD7YZJxyb68cpqr3VPJ69RXb1hFZ4b
huSMJMRpcgtjTHmxLRxbUBXOHADxiqST69mISwKPimceHupdredZ2kh8
-----END PRIVATE KEY-----
"""

test "Certificate.fromPem loads a self-signed RSA certificate" {
  match Certificate.fromPem(rsaCert) {
    case Ok(_) -> assertTrue(true, "rsa certificate parses")
    case Err(e) -> panic("expected Ok, got: " + TlsError.message(e))
  }
}

test "Certificate.fromPem loads a self-signed EC certificate" {
  match Certificate.fromPem(ecCert) {
    case Ok(_) -> assertTrue(true, "ec certificate parses")
    case Err(e) -> panic("expected Ok, got: " + TlsError.message(e))
  }
}

test "Identity.fromPem loads a matched RSA certificate/key pair" {
  match Identity.fromPem(rsaCert, rsaKey) {
    case Ok(_) -> assertTrue(true, "rsa identity parses")
    case Err(e) -> panic("expected Ok, got: " + TlsError.message(e))
  }
}

test "Identity.fromPem loads a matched EC certificate/key pair" {
  match Identity.fromPem(ecCert, ecKey) {
    case Ok(_) -> assertTrue(true, "ec identity parses")
    case Err(e) -> panic("expected Ok, got: " + TlsError.message(e))
  }
}

test "Certificate.fromPem rejects malformed PEM as PemMalformed" {
  match Certificate.fromPem("this is not a certificate at all") {
    case Ok(_) -> panic("expected PemMalformed for garbage input")
    case Err(PemMalformed(_, _)) -> assertTrue(true, "garbage input is PemMalformed")
    case Err(e) -> panic("expected PemMalformed, got: " + TlsError.message(e))
  }
}

test "empty PEM text is PemMalformed, not a precondition failure (#7251)" {
  match Certificate.fromPem("") {
    case Err(PemMalformed(_, _)) -> assertTrue(true, "empty certificate PEM")
    case _ -> assertTrue(false, "empty certificate PEM must be PemMalformed")
  }
  match Identity.fromPem(rsaCert, "") {
    case Err(PemMalformed(_, msg)) -> assertTrue(msg.contains("private key"), "names the empty key")
    case _ -> assertTrue(false, "empty key PEM must be PemMalformed")
  }
}

test "Certificate.fromPemFile rejects a missing file as CertFileNotFound" {
  match Certificate.fromPemFile("/nonexistent/path/does-not-exist-lyric-tls-test.pem") {
    case Ok(_) -> panic("expected CertFileNotFound for a missing path")
    case Err(CertFileNotFound(path)) -> assertTrue(
      path == "/nonexistent/path/does-not-exist-lyric-tls-test.pem",
      "CertFileNotFound carries the requested path"
    )
    case Err(e) -> panic("expected CertFileNotFound, got: " + TlsError.message(e))
  }
}

// Per-test unique /tmp paths, following hash_tests.l's uuid-suffix
// precedent (#833) so parallel CI runs can't collide.
func freshTmpPath(stem: in String): String {
  "/tmp/lyric-tls-test-" + stem + "-" + Uuid.uuidToString(Uuid.newUuid()) + ".pem"
}

func writeFixtureOrPanic(path: in String, content: in String): Unit {
  match File.writeText(path, content) {
    case Ok(_) -> ()
    case Err(_) -> panic("could not write test fixture: " + path)
  }
}

func deleteQuietly(path: in String): Unit {
  val _ = File.deleteFile(path)
}

test "Certificate.fromPemFile loads a certificate from a real file" {
  val certFile = freshTmpPath("cert-ok")
  writeFixtureOrPanic(certFile, rsaCert)
  match Certificate.fromPemFile(certFile) {
    case Ok(_) -> assertTrue(true, "file-based certificate load succeeds")
    case Err(e) -> panic("expected Ok, got: " + TlsError.message(e))
  }
  deleteQuietly(certFile)
}

test "Identity.fromPemFiles loads a matched pair from real files" {
  val certFile = freshTmpPath("id-cert-ok")
  val keyFile = freshTmpPath("id-key-ok")
  writeFixtureOrPanic(certFile, rsaCert)
  writeFixtureOrPanic(keyFile, rsaKey)
  match Identity.fromPemFiles(certFile, keyFile) {
    case Ok(_) -> assertTrue(true, "file-based identity load succeeds")
    case Err(e) -> panic("expected Ok, got: " + TlsError.message(e))
  }
  deleteQuietly(certFile)
  deleteQuietly(keyFile)
}

test "Identity.fromPemFiles rejects a missing key file as CertFileNotFound" {
  // The cert file genuinely exists, so this exercises the missing-KEY
  // path specifically (#5915), not the missing-cert path.
  val certFile = freshTmpPath("missing-key-cert")
  writeFixtureOrPanic(certFile, rsaCert)
  val missingKey = freshTmpPath("no-such-key")
  match Identity.fromPemFiles(certFile, missingKey) {
    case Ok(_) -> panic("expected CertFileNotFound for a missing key file")
    case Err(e) -> match e {
      case CertFileNotFound(path) -> assertEqual(
        path,
        missingKey,
        "the missing KEY path is the one reported"
      )
      case _ -> panic("expected CertFileNotFound, got: " + TlsError.message(e))
    }
  }
  deleteQuietly(certFile)
}

test "Identity.fromPemFiles blames the certificate file when the cert is malformed" {
  // Regression for #5912: a malformed CERTIFICATE with a perfectly good key
  // must be reported against the cert path, not the key path.
  val certFile = freshTmpPath("malformed-cert")
  val keyFile = freshTmpPath("good-key")
  writeFixtureOrPanic(certFile, "-----BEGIN CERTIFICATE-----\nnot base64!!\n-----END CERTIFICATE-----\n")
  writeFixtureOrPanic(keyFile, rsaKey)
  match Identity.fromPemFiles(certFile, keyFile) {
    case Ok(_) -> panic("expected PemMalformed for a malformed certificate")
    case Err(e) -> match e {
      case PemMalformed(path, _) -> assertEqual(
        path,
        certFile,
        "the CERT path is the one reported for a malformed cert"
      )
      case _ -> panic("expected PemMalformed, got: " + TlsError.message(e))
    }
  }
  deleteQuietly(certFile)
  deleteQuietly(keyFile)
}

test "Identity.fromPem rejects a PKCS1 private key as Unsupported" {
  val pkcs1Key = "-----BEGIN RSA PRIVATE KEY-----\nAAAAAAAAAAAAAAAAAAAAAAAAAA==\n-----END RSA PRIVATE KEY-----\n"
  match Identity.fromPem(rsaCert, pkcs1Key) {
    case Ok(_) -> panic("expected Unsupported for a PKCS1 key")
    case Err(Unsupported(_, _)) -> assertTrue(true, "PKCS1 key is Unsupported")
    case Err(e) -> panic("expected Unsupported, got: " + TlsError.message(e))
  }
}

test "Identity.fromPem rejects an encrypted PKCS8 private key as Unsupported" {
  val encryptedKey = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAAAAAAAAAAAAAAAAAAAAAAAA==\n-----END ENCRYPTED PRIVATE KEY-----\n"
  match Identity.fromPem(rsaCert, encryptedKey) {
    case Ok(_) -> panic("expected Unsupported for an encrypted key")
    case Err(Unsupported(_, _)) -> assertTrue(true, "encrypted PKCS8 key is Unsupported")
    case Err(e) -> panic("expected Unsupported, got: " + TlsError.message(e))
  }
}

// Cross-algorithm certificate/key mismatch — the one mismatch shape both
// targets classify identically (module doc comment / Std.Tls header).
test "Identity.fromPem rejects a cross-algorithm certificate/key pair as KeyMismatch" {
  match Identity.fromPem(rsaCert, ecKey) {
    case Ok(_) -> panic("expected KeyMismatch for an RSA certificate paired with an EC key")
    case Err(KeyMismatch(_, _)) -> assertTrue(true, "cross-algorithm pairing is KeyMismatch")
    case Err(e) -> panic("expected KeyMismatch, got: " + TlsError.message(e))
  }
}

test "TlsError.message renders every case" {
  assertTrue(
    TlsError.message(CertFileNotFound(path = "/x")).contains("/x"),
    "CertFileNotFound message carries the path"
  )
  assertTrue(
    TlsError.message(PemMalformed(path = "/x", message = "bad")).contains("bad"),
    "PemMalformed message carries the detail"
  )
  assertTrue(
    TlsError.message(KeyMismatch(path = "/x", message = "bad")).contains("bad"),
    "KeyMismatch message carries the detail"
  )
  assertTrue(
    TlsError.message(Unsupported(path = "/x", message = "bad")).contains("bad"),
    "Unsupported message carries the detail"
  )
}

val ca1Pem = """
-----BEGIN CERTIFICATE-----
MIIBqTCCAU+gAwIBAgIUQMSJNbrszCRGfZfUDlXLx4zX6bUwCgYIKoZIzj0EAwIw
ITEfMB0GA1UEAwwWbHlyaWMtYnVuZGxlLXRlc3QtY2EtMTAgFw0yNjExMTYwMDE4
MTdaGA8yMTI2MTAyMzAwMTgxN1owITEfMB0GA1UEAwwWbHlyaWMtYnVuZGxlLXRl
c3QtY2EtMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABEqH7D8su5uvNuR6UVeC
fAX3Qbn+lpYQkimYrRcyKjCH/mXW5V+GuMGKecakoBqrpidY8lisG4Qj/1SytYw1
/PujYzBhMB8GA1UdIwQYMBaAFIRCwQuYgmnPNkuSvVXe1gaHHkuYMA8GA1UdEwEB
/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBSEQsELmIJpzzZLkr1V
3tYGhx5LmDAKBggqhkjOPQQDAgNIADBFAiA+vkLNGRLGwSZn/5XeAy95UpgbZ8Vp
IgcXXFBen5UpDgIhAOIVlkR/ZwPWdMXG3VH8SwI820DGqevb7gIrve6eFcnl
-----END CERTIFICATE-----
"""

val ca2Pem = """
-----BEGIN CERTIFICATE-----
MIIBqjCCAU+gAwIBAgIUNT9Id19t1i97kgYA5nM0ZKpgNnQwCgYIKoZIzj0EAwIw
ITEfMB0GA1UEAwwWbHlyaWMtYnVuZGxlLXRlc3QtY2EtMjAgFw0yNjExMTYwMDE4
MTdaGA8yMTI2MTAyMzAwMTgxN1owITEfMB0GA1UEAwwWbHlyaWMtYnVuZGxlLXRl
c3QtY2EtMjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABMGYMydRUKs3h8nNVOu/
JnB5aBf1DZB3S16ruyu2tR+qk80xNjWDWrQig6kJCJJzjMieelFkD8Ss4i8dQGoE
PIOjYzBhMB8GA1UdIwQYMBaAFChzv1YQfxRSd3A5/c/hTQodInLrMA8GA1UdEwEB
/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBQoc79WEH8UUndwOf3P
4U0KHSJy6zAKBggqhkjOPQQDAgNJADBGAiEApVhrwWiaQ7KZMPturx3sXcWrL0uo
rTah2hjjNPSbRBMCIQCCVTlAyMhEBDjx1Ohug0wt3hfDRvgbPF3vkZ1SBb0tCw==
-----END CERTIFICATE-----
"""

val serverCertPem = """
-----BEGIN CERTIFICATE-----
MIIBxzCCAWygAwIBAgIUHb1bb6Vf0Ybv+2M67K2/nqcoe80wCgYIKoZIzj0EAwIw
ITEfMB0GA1UEAwwWbHlyaWMtYnVuZGxlLXRlc3QtY2EtMjAgFw0yNjExMTYwMDE4
MTdaGA8yMTI2MTAyMzAwMTgxN1owFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYH
KoZIzj0CAQYIKoZIzj0DAQcDQgAEdFkYB9r1fhi5f77ryrU/ofFmAv3o+7Y2B05h
3z0nQ/Kk+abZlOrwwjG3RXveeOevU4x8D2UVcTnw8zBWg3aLA6OBjDCBiTAaBgNV
HREEEzARgglsb2NhbGhvc3SHBH8AAAEwCQYDVR0TBAIwADALBgNVHQ8EBAMCB4Aw
EwYDVR0lBAwwCgYIKwYBBQUHAwEwHQYDVR0OBBYEFOzzVzJKz0sxYTzycf/ATnCW
g4GcMB8GA1UdIwQYMBaAFChzv1YQfxRSd3A5/c/hTQodInLrMAoGCCqGSM49BAMC
A0kAMEYCIQCg6SbDko7PVQcRReBL6u03ALKYG8nBs3o8PATyUTBEjAIhAIhvjEwC
pBUWnQNdiNeqm08UELQdRPGQsSRY8Rw97RTN
-----END CERTIFICATE-----
"""

val serverKeyPem = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgUk3ErC5rXxcn9UIU
jJUn6WT3GZFA2APUjAC9ksbgf8ihRANCAAR0WRgH2vV+GLl/vuvKtT+h8WYC/ej7
tjYHTmHfPSdD8qT5ptmU6vDCMbdFe954569TjHwPZRVxOfDzMFaDdosD
-----END PRIVATE KEY-----
"""

val clientCertPem = """
-----BEGIN CERTIFICATE-----
MIIBtzCCAV2gAwIBAgIUHb1bb6Vf0Ybv+2M67K2/nqcoe84wCgYIKoZIzj0EAwIw
ITEfMB0GA1UEAwwWbHlyaWMtYnVuZGxlLXRlc3QtY2EtMjAgFw0yNjExMTYwMDI2
MjFaGA8yMTI2MTAyMzAwMjYyMVowIzEhMB8GA1UEAwwYbHlyaWMtYnVuZGxlLXRl
c3QtY2xpZW50MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7gWhtMgNwRlqo7xT
3BA1AV0liiHQf9S6338ya4zLq4m0IIQNAIzdg0JPTkfV36p8sL/KDNaXtbrxb1wO
dF/zhaNvMG0wCQYDVR0TBAIwADALBgNVHQ8EBAMCB4AwEwYDVR0lBAwwCgYIKwYB
BQUHAwIwHQYDVR0OBBYEFJ42Wq614YYG3MPzx+rMfoWnPblFMB8GA1UdIwQYMBaA
FChzv1YQfxRSd3A5/c/hTQodInLrMAoGCCqGSM49BAMCA0gAMEUCIDOJIUEtsJsT
rPVN/B0SZNxDfk0JUGRj4XH1jjZm01F+AiEA7EK4JGB6YHVb3/WNGFJmGXeih3th
O3qTCOzizyA4Cmg=
-----END CERTIFICATE-----
"""

val clientKeyPem = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg6w8bz/v9YVTdhzLz
ZT/y2KjkPmy2OeO7jr55MiwMKEyhRANCAATuBaG0yA3BGWqjvFPcEDUBXSWKIdB/
1LrffzJrjMuribQghA0AjN2DQk9OR9Xfqnywv8oM1pe1uvFvXA50X/OF
-----END PRIVATE KEY-----
"""

func bundleOf(first: in String, second: in String): String {
  first.trim() + "\n" + second.trim() + "\n"
}

func certOrPanic(pem: in String): Certificate {
  match Certificate.fromPem(pem) {
    case Ok(c) -> c
    case Err(e) -> panic("Certificate.fromPem failed: " + TlsError.message(e))
  }
}

func serverIdentity(): Identity {
  match Identity.fromPem(serverCertPem, serverKeyPem) {
    case Ok(i) -> i
    case Err(e) -> panic("Identity.fromPem failed: " + TlsError.message(e))
  }
}

func startServer(port: in Int): HttpListener {
  val cfg = TlsServerConfig(identity = serverIdentity())
  match startListenerTls("127.0.0.1", port, cfg) {
    case Ok(l) -> l
    case Err(_) -> panic("startListenerTls failed on port " + port.toString())
  }
}

func serveOne(l: in HttpListener): Unit {
  val ctx = nextContext(l)
  respondText(ctx, 200, "bundle-ok")
}

// "ok" when the TLS exchange and the request succeeded with the expected
// body; otherwise "error: ..." with the client's error text.
func fetchOutcome(client: in HttpClient, port: in Int): String {
  match await client.get("https://localhost:" + port.toString() + "/bundle") {
    case Err(e) -> "error: " + HttpError.message(e)
    case Ok(resp) -> match await resp.bodyText() {
      case Ok(t) -> if resp.statusCode() == 200 and t == "bundle-ok" {
        "ok"
      } else {
        "unexpected response " + t
      }
      case Err(_) -> "error: response body unreadable"
    }
  }
}

// Serve exactly one request when `serve` is set (a client that trusts the
// server connects), and report what the client saw. A client that rejects the
// certificate never delivers a request, so no serving thread is started for
// it (it would block in `nextContext` forever).
func trustOutcome(builder: in HttpClientBuilder, port: in Int, serve: in Bool): String {
  val l = startServer(port)
  val sc = Task.makeScope()
  if serve {
    Task.scopeSpawn(sc, { -> serveOne(l) })
  }
  val outcome = fetchOutcome(builder.build(), port)
  // A serving thread whose request never came (the client rejected the
  // certificate, i.e. the test is about to fail) is abandoned, not awaited:
  // awaiting it would turn a failed assertion into a hang.
  if serve and outcome == "ok" {
    val _ = await Task.awaitAll(sc);
    ()
  }
  stopListener(l)
  outcome
}

test "a bundle's second CA is trusted: exclusive bundle, CA 2 second" {
  val ca = certOrPanic(bundleOf(ca1Pem, ca2Pem))
  assertEqual(trustOutcome(HttpClientBuilder.new().withExclusiveCaCertificate(ca), 19711, true), "ok", "bundle CA1+CA2")
}

test "a bundle's second CA is trusted: exclusive bundle, CA 2 first" {
  val ca = certOrPanic(bundleOf(ca2Pem, ca1Pem))
  assertEqual(trustOutcome(HttpClientBuilder.new().withExclusiveCaCertificate(ca), 19712, true), "ok", "bundle CA2+CA1")
}

test "a bundle's second CA is trusted: additive bundle" {
  val ca = certOrPanic(bundleOf(ca1Pem, ca2Pem))
  assertEqual(trustOutcome(HttpClientBuilder.new().withCaCertificate(ca), 19713, true), "ok", "additive bundle CA1+CA2")
}

test "the server is rejected when only the first CA of the bundle is trusted" {
  val ca = certOrPanic(ca1Pem)
  val outcome = trustOutcome(HttpClientBuilder.new().withExclusiveCaCertificate(ca), 19714, false)
  assertTrue(outcome.startsWith("error:"), "CA 1 alone must not trust a CA 2 leaf: " + outcome)
}

test "the server is rejected when only the first CA is trusted additively" {
  val ca = certOrPanic(ca1Pem)
  val outcome = trustOutcome(HttpClientBuilder.new().withCaCertificate(ca), 19715, false)
  assertTrue(outcome.startsWith("error:"), "CA 1 alone must not trust a CA 2 leaf: " + outcome)
}

test "a single certificate still trusts a server it signed" {
  val ca = certOrPanic(ca2Pem)
  assertEqual(trustOutcome(HttpClientBuilder.new().withExclusiveCaCertificate(ca), 19716, true), "ok", "CA2 alone")
}

test "comments, blank lines and other PEM blocks around the certificates are ignored" {
  val text = "# trust bundle for the tests\n\n" + ca1Pem.trim() + "\n\n# the second one\n   \n" +
    "-----BEGIN PRIVATE KEY-----\nQUJD\n-----END PRIVATE KEY-----\n" +
    ca2Pem.trim() +
    "\n   \n\n"
  val ca = certOrPanic(text)
  assertEqual(
    trustOutcome(HttpClientBuilder.new().withExclusiveCaCertificate(ca), 19717, true),
    "ok",
    "annotated bundle"
  )
}

test "a bundle read from a file trusts its second CA" {
  val path = "/tmp/lyric-tls-bundle-" + Uuid.uuidToString(Uuid.newUuid()) + ".pem"
  match File.writeText(path, bundleOf(ca1Pem, ca2Pem)) {
    case Ok(_) -> ()
    case Err(_) -> panic("could not write the bundle fixture")
  }
  val ca = match Certificate.fromPemFile(path) {
    case Ok(c) -> c
    case Err(e) -> panic("Certificate.fromPemFile failed: " + TlsError.message(e))
  }
  val outcome = trustOutcome(HttpClientBuilder.new().withExclusiveCaCertificate(ca), 19718, true)
  val _ = File.deleteFile(path)
  assertEqual(outcome, "ok", "bundle file CA1+CA2")
}

// A copy of `pem` whose base64 body is replaced by `garbage` characters of
// the same length: still a well-formed PEM block, not a certificate.
func corrupted(pem: in String): String {
  val lines = pem.trim().split("\n")
  var acc = ""
  var i = 0
  for line in lines {
    if i == 3 {
      acc = acc +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".substring(
          0,
          line.length
        ) +
        "\n"
    } else {
      acc = acc + line + "\n"
    }
    i = i + 1
  }
  acc
}

func assertMalformed(r: in Result[Certificate, TlsError], needle: in String, what: in String): Unit {
  match r {
    case Ok(_) -> panic(what + ": expected PemMalformed, the text was accepted")
    case Err(PemMalformed(_, msg)) -> assertTrue(
      msg.contains(needle),
      what + ": message names '" + needle + "': " + msg
    )
    case Err(e) -> panic(what + ": expected PemMalformed, got: " + TlsError.message(e))
  }
}

test "a malformed second certificate is an error, not ignored" {
  val text = ca1Pem.trim() + "\n" + corrupted(ca2Pem)
  assertMalformed(Certificate.fromPem(text), "certificate 2 of 2", "corrupt second")
}

test "a malformed first certificate in a bundle is an error" {
  val text = corrupted(ca1Pem) + ca2Pem.trim() + "\n"
  assertMalformed(Certificate.fromPem(text), "certificate 1 of 2", "corrupt first")
}

test "an unterminated certificate block after a good one is an error" {
  val cut = ca2Pem.trim().replace("-----END CERTIFICATE-----", "")
  assertMalformed(Certificate.fromPem(ca1Pem.trim() + "\n" + cut), "certificate 2", "unterminated second")
}

test "a text with no certificate block is still PemMalformed" {
  assertMalformed(Certificate.fromPem("# only a comment\n"), "", "no certificate")
  assertMalformed(
    Certificate.fromPem("-----BEGIN PRIVATE KEY-----\nQUJD\n-----END PRIVATE KEY-----\n"),
    "",
    "key block only"
  )
}

test "an Identity keeps working with a certificate chain: the first certificate is the leaf" {
  val chainPem = serverCertPem.trim() + "\n" + ca2Pem.trim() + "\n"
  match Identity.fromPem(chainPem, serverKeyPem) {
    case Ok(_) -> assertTrue(true, "leaf + CA certificate text loads as an identity")
    case Err(e) -> panic("Identity.fromPem with a chain failed: " + TlsError.message(e))
  }
}

func clientIdentity(): Identity {
  match Identity.fromPem(clientCertPem, clientKeyPem) {
    case Ok(i) -> i
    case Err(e) -> panic("client Identity.fromPem failed: " + TlsError.message(e))
  }
}

// Mutual TLS: the server pins `clientCa` and requires a client certificate
// signed by CA 2. Every target builds the listener with a client CA (the JVM
// server is the shared driver over `Std.TcpHost` since docs/73 S4, D789, so the
// old `HttpsServer` construction-time rejection, #5930, is gone), so each case
// runs a real handshake.
func mtlsOutcome(clientCa: in Certificate, port: in Int): String {
  val cfg = TlsServerConfig(identity = serverIdentity(), clientCa = Some(value = clientCa), requireClientCert = true)
  match startListenerTls("127.0.0.1", port, cfg) {
    case Err(e) -> panic("startListenerTls with a client CA failed: " + TlsListenError.message(e))
    case Ok(l) -> {
      val sc = Task.makeScope()
      Task.scopeSpawn(sc, { -> serveOne(l) })
      val client = HttpClientBuilder.new().withExclusiveCaCertificate(certOrPanic(ca2Pem)).withClientIdentity(clientIdentity()).build()
      val result = fetchOutcome(client, port)
      if result == "ok" {
        val _ = await Task.awaitAll(sc);
        ()
      }
      stopListener(l)
      result
    }
  }
}

test "mTLS: a client certificate signed by the second CA of the server's clientCa bundle is accepted" {
  val outcome = mtlsOutcome(certOrPanic(bundleOf(ca1Pem, ca2Pem)), 19721)
  assertEqual(outcome, "ok", "mTLS with a clientCa bundle")
}

test "mTLS: a client certificate signed by a CA outside the server's clientCa is rejected" {
  val outcome = mtlsOutcome(certOrPanic(ca1Pem), 19722)
  assertTrue(outcome != "ok", "CA 1 alone must not accept a CA 2 client certificate: " + outcome)
}
