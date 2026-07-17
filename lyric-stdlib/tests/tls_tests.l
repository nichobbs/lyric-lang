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
//! Runs via native `lyric test` on both targets (`--target dotnet` and
//! `--target jvm`), verified manually against the published `lyric` NuGet
//! tool (0.4.32) in this sandbox (no source-buildable `./bin/lyric` was
//! available; see the PR description).
//!
//! `TlsServerConfig` is covered separately in `tls_server_config_tests.l`
//! (both targets). Its default-field-omission behavior has no test on any
//! target: omitted-default construction currently miscompiles on JVM
//! (#5908) and dotnet (#5920) — see that file's header and D-progress-689.
@test_module
package Std.Tls.Tests

import Std.Core
import Std.File
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
      case CertFileNotFound(path) ->
        assertEqual(path, missingKey, "the missing KEY path is the one reported")
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
      case PemMalformed(path, _) ->
        assertEqual(path, certFile, "the CERT path is the one reported for a malformed cert")
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
  assertTrue(TlsError.message(CertFileNotFound(path = "/x")).contains("/x"), "CertFileNotFound message carries the path")
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
