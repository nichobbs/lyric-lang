//! stdlib/tests/http_tls_client_tests.l — deterministic coverage for
//! `HttpClientBuilder`'s TLS client configuration surface (docs/61 §3.2 +
//! §4, D128; phase 1.2, #5877).
//!
//! Coverage model, and its honest boundary: `Std.HttpServer` has no TLS
//! surface yet (server TLS is phase 2/3 of docs/61, tracked separately)
//! and a test against a public HTTPS endpoint is not CI-acceptable, so
//! there is no live TLS peer available on EITHER target from this file.
//! What is covered here, fully deterministically, with no network touch
//! at all:
//!
//!   - The dual-key insecure-verify policy matrix (docs/61 §4) as a PURE
//!     function (`resolveInsecureVerifyPolicy`) — all four cells.
//!   - The wired path: `setVar` flips the real process
//!     environment variable `build()` reads, so the full policy matrix is
//!     exercised through the real `HttpClientBuilder.build()` call (not
//!     just the pure function in isolation). `build()`'s own infallibility
//!     contract (docs/61 §3.2: "build() stays infallible") is asserted
//!     directly: every combination below returns a client, never panics.
//!   - Builder composition: chaining every TLS `with*` method together,
//!     and combined with the pre-existing Unix-socket/redirect/version
//!     knobs (the "full matrix" `_kernel/http_host.l`'s `hostClientWithTls`
//!     assembles), never panics either.
//!   - The honest per-target design (docs/61 §3.2's JVM support boundary):
//!     `tlsConfigSupported()` is the capability probe `Std.Http` itself
//!     exposes (backed by `_kernel/http_host.l`'s real TLS wiring on
//!     dotnet, `_kernel_jvm/http_host.l`'s `false` stub on jvm, #5878).
//!     This file runs on BOTH targets and branches on that probe's OWN
//!     return value — not on which target compiled it — so the same test
//!     asserts real different things per target honestly: on dotnet it
//!     just confirms the probe reports `true` (the deterministic parts
//!     above already exercise the real wiring); on jvm it confirms a
//!     TLS-configured client fails every request with a typed error
//!     naming #5878, never a silent no-TLS-config connection.
//!   - The MITM-bypass fix (#5950): `_kernel/http_host.l`'s certificate
//!     validation callback (installed by `withCaCertificate`/
//!     `withExclusiveCaCertificate`/`withInsecureSkipVerify`) is a pure
//!     decision core, `resolveTlsValidationDecision`, exhaustively
//!     tested here for every `(hostnameAndAvailabilityOk, chainAlreadyOk,
//!     caMode)` combination. The property under test: whenever
//!     `hostnameAndAvailabilityOk` is `false` (the platform's own hostname
//!     check, or its cert-presence check, failed), the result is ALWAYS
//!     `RejectImmediately` — no CA configuration, however permissive, and
//!     no chain-already-fine signal can override that. This is exactly
//!     the property whose absence made #5950 an MITM bypass (the original
//!     callback only ever re-ran a chain check and never consulted
//!     hostname at all).
//!
//! What this file deliberately does NOT try to prove: that a custom CA
//! certificate is actually honored/rejected during a real TLS handshake,
//! or that `withInsecureSkipVerify()` actually disables peer verification
//! against a live server, or that a REAL certificate issued for the wrong
//! host is rejected over a REAL connection. Those require a real TLS
//! listener trusting (or not) a real client-presented chain and/or
//! presenting a real name-mismatched certificate, which does not exist in
//! CI yet on either target (dotnet: #5884; jvm: #5878/#5880 pending) —
//! `resolveTlsValidationDecision`'s exhaustive coverage above is the
//! strongest CI-safe proof available today that the DECISION LOGIC itself
//! can never accept a hostname mismatch, independent of a live peer. The
//! warning text `build()` prints via `Std.Console.error` is not
//! captured/asserted either — there is no stdout/stderr-capture facility
//! in `Std.Testing` today; the pure `resolveInsecureVerifyPolicy` result
//! (which decides WHETHER the warning fires) is the testable proxy for
//! that decision.
@test_module
package Std.Http.TlsClientTests

import Std.Core
import Std.Environment
import Std.Errors
import Std.Http
// Unaliased deliberately: a qualified case pattern through an ALIASED
// import (`import Std.HttpHost as HostHttp` + `case HostHttp.Foo -> ...`)
// does not discriminate correctly on `--target dotnet` — verified with an
// isolated repro, filed as #5971 (a dotnet-side sibling of the JVM
// qualified-case-resolution family, #5769/#5845/#5943). Bare case names
// after an unaliased import (the shape used everywhere else in this
// codebase's test suite) are unaffected and used below instead.
import Std.HttpHost
import Std.String
import Std.Testing
import Std.Tls

// Self-signed RSA 2048 certificate, CN=test-rsa (same fixture as
// tls_tests.l/tls_server_config_tests.l; duplicated per this directory's
// self-contained-source convention — no shared fixture modules).
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

val insecureAllowVar: String = "LYRIC_TLS_ALLOW_INSECURE"

func ca(): Certificate {
  match Certificate.fromPem(rsaCert) {
    case Ok(cert) -> cert
    case Err(e) -> panic("expected Ok parsing the fixture certificate: " + TlsError.message(e))
  }
}

// ─── Pure dual-key policy resolution (docs/61 §4) ───────────────────────────
test "resolveInsecureVerifyPolicy resolves the full dual-key matrix" {
  match resolveInsecureVerifyPolicy(false, false) {
    case VerificationEnabled -> assertTrue(true, "neither set: verification enabled")
    case other -> panic("expected VerificationEnabled for (false, false)")
  }
  match resolveInsecureVerifyPolicy(false, true) {
    case VerificationEnabled -> assertTrue(true, "env-only: verification enabled (no-op)")
    case other -> panic("expected VerificationEnabled for (false, true) — env alone must be a no-op")
  }
  match resolveInsecureVerifyPolicy(true, false) {
    case VerificationEnabledWarn -> assertTrue(true, "code-only: enabled + warn")
    case other -> panic("expected VerificationEnabledWarn for (true, false)")
  }
  match resolveInsecureVerifyPolicy(true, true) {
    case VerificationDisabled -> assertTrue(true, "both set: verification disabled")
    case other -> panic("expected VerificationDisabled for (true, true)")
  }
}

// ─── Wired path: real setVar drives the real build() ───────────
// Restores the variable to unset via `defer` (#5973) rather than a final
// statement, so a panic partway through (e.g. a future regression that
// makes build() itself panic instead of staying infallible — precisely
// the property this test exists to guard) can't leak
// `LYRIC_TLS_ALLOW_INSECURE=1` into the rest of this process, including
// other tests in this same file or suite sharing the process.
test "build() stays infallible across the full insecure-verify policy matrix" {
  setVar(insecureAllowVar, "")
  defer {
    setVar(insecureAllowVar, "")
  }

  val neither = HttpClientBuilder.build(HttpClientBuilder.new())
  assertTrue(true, "neither configured: build() returned a client")

  setVar(insecureAllowVar, "1")
  val envOnly = HttpClientBuilder.build(HttpClientBuilder.new())
  assertTrue(true, "env-only: build() returned a client")

  setVar(insecureAllowVar, "")
  val codeOnly = HttpClientBuilder.build(HttpClientBuilder.new().withInsecureSkipVerify())
  assertTrue(true, "code-only: build() returned a client (warning path)")

  setVar(insecureAllowVar, "1")
  val both = HttpClientBuilder.build(HttpClientBuilder.new().withInsecureSkipVerify())
  assertTrue(true, "both configured: build() returned a client")
}

// ─── Builder composition: every TLS with* method, alone and combined ───────
test "build() stays infallible for every TLS with* method individually" {
  val withCa = HttpClientBuilder.build(HttpClientBuilder.new().withCaCertificate(ca()))
  assertTrue(true, "withCaCertificate alone builds")

  val withExclusiveCa = HttpClientBuilder.build(HttpClientBuilder.new().withExclusiveCaCertificate(ca()))
  assertTrue(true, "withExclusiveCaCertificate alone builds")

  val withMinVersion = HttpClientBuilder.build(HttpClientBuilder.new().withMinTlsVersion(Tls13))
  assertTrue(true, "withMinTlsVersion(Tls13) alone builds")

  val withMinVersion12 = HttpClientBuilder.build(HttpClientBuilder.new().withMinTlsVersion(Tls12))
  assertTrue(true, "withMinTlsVersion(Tls12) alone builds")

  val withInsecure = HttpClientBuilder.build(HttpClientBuilder.new().withInsecureSkipVerify())
  assertTrue(true, "withInsecureSkipVerify alone builds")
}

test "build() composes TLS options with redirects, unix socket, and HTTP version" {
  val withRedirectsAndCa = HttpClientBuilder.build(
    HttpClientBuilder.new().withRedirects(3).withCaCertificate(ca())
  )
  assertTrue(true, "withRedirects + withCaCertificate builds")

  val withNoRedirectsAndCa = HttpClientBuilder.build(
    HttpClientBuilder.new().withNoRedirects().withExclusiveCaCertificate(ca())
  )
  assertTrue(true, "withNoRedirects + withExclusiveCaCertificate builds")

  val withHttp11AndCa = HttpClientBuilder.build(
    HttpClientBuilder.new().withHttpVersion(Http11).withCaCertificate(ca()).withMinTlsVersion(Tls13)
  )
  assertTrue(true, "withHttpVersion(Http11) + withCaCertificate + withMinTlsVersion builds")

  val withEverything = HttpClientBuilder.build(
    HttpClientBuilder.new()
      .withRedirects(5)
      .withHttpVersion(Http2)
      .withCaCertificate(ca())
      .withMinTlsVersion(Tls12)
      .withInsecureSkipVerify()
  )
  assertTrue(true, "every non-unix-socket knob combined builds")
}

// ─── Per-target honest design: tlsConfigSupported() capability probe ───────
// #2663-style: constructing a Unix-socket client is unsupported on the JVM
// target regardless of TLS configuration (pre-existing gap), so this test
// deliberately never combines withUnixSocket with a TLS option — that
// combination would panic on jvm for a reason unrelated to this feature.
val deadUrl: String = "http://127.0.0.1:1/"

test "tlsConfigSupported() capability probe matches this target's design" {
  if tlsConfigSupported() {
    // dotnet: the deterministic tests above already exercise the real
    // kernel wiring end-to-end (build() never panics with TLS options
    // configured); this assertion just pins the probe's own value.
    assertTrue(true, "TLS client configuration is supported on this target")

    // Unix sockets + TLS options is the one combination this target still
    // can't honor (`_kernel/http_host.l`'s TLS section header: Unix
    // sockets require `SocketsHttpHandler`, whose only certificate-
    // validation hook is a custom .NET delegate type the current FFI
    // delegate-bridge cannot bind to, #5947). Guarded behind
    // `tlsConfigSupported()` so `--target jvm` never reaches this branch
    // at runtime — combining `withUnixSocket` with anything is
    // unconditionally unsupported there for the unrelated, pre-existing
    // #2663 reason, which would panic rather than return a typed error.
    val unixWithCa = HttpClientBuilder.build(
      HttpClientBuilder.new().withUnixSocket("/tmp/lyric-tls-test.sock").withCaCertificate(ca())
    )
    match await unixWithCa.get(deadUrl) {
      case Ok(_) -> panic("expected the Unix-socket+TLS-unsupported error, got Ok")
      case Err(e) -> match e {
        case ConnectionFailed(_, message) ->
          assertTrue(contains(message, "#5947"), "message should name #5947, got: " + message)
        case other -> panic("expected ConnectionFailed, got a different HttpError case")
      }
    }
  } else {
    // jvm (#5878 not yet shipped): a TLS-configured client must still
    // build (infallible) but fail every request with a typed error
    // naming the tracking issue — never a silent no-TLS-config connection.
    val client = HttpClientBuilder.build(HttpClientBuilder.new().withCaCertificate(ca()))
    match await client.get(deadUrl) {
      case Ok(_) -> panic("expected the TLS-unsupported error on jvm, got Ok")
      case Err(e) -> match e {
        case ConnectionFailed(_, message) ->
          assertTrue(contains(message, "#5878"), "message should name #5878, got: " + message)
        case other -> panic("expected ConnectionFailed, got a different HttpError case")
      }
    }
  }
}

// ─── #5950 regression: hostname mismatch is never overridable ──────────────
// `resolveTlsValidationDecision` is `_kernel/http_host.l`'s pure decision
// core for the certificate-validation callback — extracted specifically so
// this property is testable without a live TLS peer (target-neutral, no
// `Std.Tls`/extern types involved). Runs on both targets: the function
// itself has no target-specific behavior (it's plain Lyric logic), so this
// is not gated on `tlsConfigSupported()` the way the wired-client tests
// above are.
test "resolveTlsValidationDecision rejects a hostname mismatch regardless of CA mode or chain state" {
  // The headline #5950 property: hostnameAndAvailabilityOk = false must
  // ALWAYS reject, no matter what chainAlreadyOk or caMode say. This is
  // the exact case the original buggy callback got wrong — it never
  // looked at hostname at all, so a chain-valid cert for the WRONG host
  // was silently accepted whenever a CA option was configured. All six
  // combinations of (chainAlreadyOk, caMode) are asserted explicitly
  // (rather than looped) so a failing case names itself directly.
  match resolveTlsValidationDecision(false, false, NoCaConfigured) {
    case RejectImmediately -> assertTrue(true, "hostname bad, chain bad, no CA: rejects")
    case other -> panic("MITM bypass regression: hostname bad, chain bad, no CA did not reject")
  }
  match resolveTlsValidationDecision(false, false, AdditiveCa) {
    case RejectImmediately -> assertTrue(true, "hostname bad, chain bad, additive CA: rejects")
    case other -> panic("MITM bypass regression: hostname bad, chain bad, additive CA did not reject")
  }
  match resolveTlsValidationDecision(false, false, ExclusiveCa) {
    case RejectImmediately -> assertTrue(true, "hostname bad, chain bad, exclusive CA: rejects")
    case other -> panic("MITM bypass regression: hostname bad, chain bad, exclusive CA did not reject")
  }
  match resolveTlsValidationDecision(false, true, NoCaConfigured) {
    case RejectImmediately -> assertTrue(true, "hostname bad, chain ALREADY OK, no CA: still rejects")
    case other -> panic("MITM bypass regression: hostname bad, chain ok, no CA did not reject")
  }
  match resolveTlsValidationDecision(false, true, AdditiveCa) {
    case RejectImmediately -> assertTrue(true, "hostname bad, chain ALREADY OK, additive CA: still rejects")
    case other -> panic("MITM bypass regression: hostname bad, chain ok, additive CA did not reject — this is #5950 exactly")
  }
  match resolveTlsValidationDecision(false, true, ExclusiveCa) {
    case RejectImmediately -> assertTrue(true, "hostname bad, chain ALREADY OK, exclusive CA: still rejects")
    case other -> panic("MITM bypass regression: hostname bad, chain ok, exclusive CA did not reject — this is #5950 exactly")
  }
}

test "resolveTlsValidationDecision: exclusive CA always re-checks, even when the platform already trusted the chain" {
  // Exclusive mode must ignore the platform's own trust conclusion — a
  // cert that chains via the public store but not via the configured CA
  // must still be rejected, so `chainAlreadyOk = true` must NOT
  // short-circuit to acceptance under ExclusiveCa.
  match resolveTlsValidationDecision(true, true, ExclusiveCa) {
    case TryCustomChain -> assertTrue(true, "exclusive CA re-checks even when chain already trusted")
    case other -> panic("expected TryCustomChain for exclusive CA with chainAlreadyOk=true")
  }
  match resolveTlsValidationDecision(true, false, ExclusiveCa) {
    case TryCustomChain -> assertTrue(true, "exclusive CA re-checks when chain failed via platform")
    case other -> panic("expected TryCustomChain for exclusive CA with chainAlreadyOk=false")
  }
}

test "resolveTlsValidationDecision: additive CA accepts platform trust directly, falls back only on chain failure" {
  match resolveTlsValidationDecision(true, true, AdditiveCa) {
    case AcceptWithoutCustomChain -> assertTrue(true, "additive CA accepts an already-trusted chain directly")
    case other -> panic("expected AcceptWithoutCustomChain for additive CA with chainAlreadyOk=true")
  }
  match resolveTlsValidationDecision(true, false, AdditiveCa) {
    case TryCustomChain -> assertTrue(true, "additive CA falls back to the custom chain on platform chain failure")
    case other -> panic("expected TryCustomChain for additive CA with chainAlreadyOk=false")
  }
}

test "resolveTlsValidationDecision: no CA configured mirrors the platform's own chain verdict" {
  match resolveTlsValidationDecision(true, true, NoCaConfigured) {
    case AcceptWithoutCustomChain -> assertTrue(true, "no CA + chain already ok: accept")
    case other -> panic("expected AcceptWithoutCustomChain for NoCaConfigured with chainAlreadyOk=true")
  }
  match resolveTlsValidationDecision(true, false, NoCaConfigured) {
    case RejectImmediately -> assertTrue(true, "no CA + chain not ok: reject (nothing to fall back to)")
    case other -> panic("expected RejectImmediately for NoCaConfigured with chainAlreadyOk=false")
  }
}

// ─── #5975 regression: withExclusiveCaCertificate always wins ──────────────
// `resolveCaMode` is `_kernel/http_host.l`'s extracted precedence rule for
// when both `withCaCertificate` and `withExclusiveCaCertificate` are
// configured on the same builder — documented in both methods' doc
// comments in `Std.Http`. Exclusive wins unconditionally, regardless of
// which `Option` slot is populated with which certificate.
test "resolveCaMode: withExclusiveCaCertificate always wins when both are configured" {
  match resolveCaMode(Some(value = ca()), Some(value = ca())) {
    case ExclusiveCa -> assertTrue(true, "both configured: exclusive wins")
    case other -> panic("expected ExclusiveCa when both caCertificate and exclusiveCaCertificate are set")
  }
  match resolveCaMode(Some(value = ca()), None) {
    case AdditiveCa -> assertTrue(true, "additive only: additive mode")
    case other -> panic("expected AdditiveCa when only caCertificate is set")
  }
  match resolveCaMode(None, Some(value = ca())) {
    case ExclusiveCa -> assertTrue(true, "exclusive only: exclusive mode")
    case other -> panic("expected ExclusiveCa when only exclusiveCaCertificate is set")
  }
  match resolveCaMode(None, None) {
    case NoCaConfigured -> assertTrue(true, "neither configured: no CA mode")
    case other -> panic("expected NoCaConfigured when neither is set")
  }
}

// Same precedence proven through the real public API: a builder with
// BOTH CA options configured must build successfully (build() stays
// infallible regardless of this combination) and, per the exclusive-wins
// rule above, behaves as if only withExclusiveCaCertificate had been
// called.
test "build() accepts both CA options configured on the same builder without panicking" {
  val bothConfigured = HttpClientBuilder.build(
    HttpClientBuilder.new().withCaCertificate(ca()).withExclusiveCaCertificate(ca())
  )
  assertTrue(true, "withCaCertificate + withExclusiveCaCertificate together builds without panicking")

  val reverseOrder = HttpClientBuilder.build(
    HttpClientBuilder.new().withExclusiveCaCertificate(ca()).withCaCertificate(ca())
  )
  assertTrue(true, "call-site order does not change the outcome — also builds without panicking")
}
