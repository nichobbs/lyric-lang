//! llvm_tls_self_test.l — end-to-end self-test for N9.2's native
//! `Std.TcpHost`/`Std.TlsHost`/`Std.EncodingHost` twins (issue #6103): real
//! programs compile through the full bridge pipeline
//! (`Lyric.LlvmBridge.compileToNativeWithFlags` with the `_kernel_native/`
//! twins loaded, exactly like `lyric build --target native`) and run.
//!
//! Scope actually covered here (three cases, not the originally-planned
//! four — see the item B/D note below):
//!   - item A: `Std.Encoding` native round-trip (base64 + UTF-8, including
//!     a supplementary-plane codepoint).
//!   - item B: `Std.TlsHost` (the kernel boundary this file's twin
//!     implements) exercised DIRECTLY, not through `Std.Tls`'s public
//!     `Certificate`/`Identity` API — see below for why.
//!   - item C: `Std.TcpHost` plain (non-TLS) round-trip:
//!     listen/connect/accept/read/write/close.
//!
//! ## Item B is scoped to the kernel boundary, and item D is deferred
//!
//! `Std.Tls`'s `Certificate`/`Identity` are `pub opaque type` (target-
//! independent, pre-dating N9.2). `Lyric.LlvmCodegen` has NO native
//! codegen case for `opaque type` at all today — not construction, not as
//! a generic type argument (confirmed via direct repro: even
//! `Result[Certificate, TlsError]`, `Certificate.fromPem`'s own return
//! type, panics "generic type 'Result' is not yet supported for --target
//! native" while resolving `Certificate`) — tracked as issue #6234, filed
//! against this same epic before this file's CI-blocking failures were
//! diagnosed. Implementing opaque-type codegen (NType registration,
//! construction, generic-argument resolution, field access, ARC
//! integration) is substantial new compiler work spanning multiple
//! codegen subsystems, well beyond this self-test's scope.
//!
//! Consequences, confirmed by direct repro against the real
//! `_kernel_native/*.l` files (not guessed):
//!   - item B AS ORIGINALLY SPECCED (`Certificate.fromPem`/
//!     `Identity.fromPem` through `Std.Tls`) cannot compile for
//!     `--target native` at all, blocked on #6234 — no amount of
//!     rewriting this test file changes that. What CAN be verified today
//!     is `_kernel_native/tls_host.l`'s actual deliverable,
//!     `Std.TlsHost.hostCertFromPemBytes`/`hostIdentityFromPemBytes`
//!     (both `pub record`-based, no opaque types), called directly. The
//!     test below does exactly that — same PEM fixtures, same assertions,
//!     one layer lower than `Std.Tls`.
//!   - item D (the real loopback TLS handshake through
//!     `Std.TcpHost.hostAcceptTls`) is dropped from this file entirely:
//!     `hostAcceptTls`/`hostUpgradeServerTls` take a `Tls.TlsServerConfig`
//!     whose `identity: Identity` field is unavoidably the opaque type,
//!     by design (matching the dotnet/JVM twins' API shape) — there is no
//!     lower-level bypass the way there is for item B. Re-adding item D
//!     is tracked as a follow-up blocked on #6234; it is not silently
//!     skipped — it simply is not in this file until the blocker clears.
//!
//! Both remaining connection-oriented tests bind an ephemeral port
//! (`hostListen(host, 0)`) and read the kernel-assigned one back via
//! `hostLocalPort` before dialing — the same pattern `lyric_tls_test.c`'s
//! C-level tests already use over `lyric_sock_local_port` — rather than a
//! fixed port number, to avoid CI flakiness from a fixed port being in use
//! on the runner. Every scenario compiles with `-fsanitize=address`, so a
//! leaked fd or byte buffer fails the run.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_tls_self_test.l
@test_module
package Lyric.LlvmTlsSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Uuid as Uuid
import Lyric.Emitter
import Lyric.LlvmBridge

// ─────────────────────────────────────────────────────────────────────────────
// Harness (mirrors llvm_stdlib_self_test.l).
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

record RunOutcome {
  exitCode: Int
  stdout: String
}

func compileAndRunNative(source: in String): RunOutcome {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-tls-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val flags: List[String] = newList()
  flags.add("-fsanitize=address")
  if not compileToNativeWithFlags(source, stem, stdlib, "", "0", flags, newList()) {
    panic("native compilation failed for a TLS self-test program")
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

// Turns text containing real newlines (and, defensively, quotes/backslashes)
// into the escaped form a double-quoted Lyric string literal needs, so a
// `val` built with real newlines (for readability, e.g. `certPemLines`
// below) can be spliced into a GENERATED program's own string literal.
func luQuote(text: in String): String {
  var acc = ""
  var i = 0
  while i < text.length {
    val c = text[i]
    if c == '\n' {
      acc = acc + "\\n"
    } else if c == '"' {
      acc = acc + "\\\""
    } else if c == '\\' {
      acc = acc + "\\\\"
    } else {
      acc = acc + ("" + c)
    }
    i = i + 1
  }
  acc
}

// Self-signed EC (prime256v1) test certificate, CN=localhost, SAN
// DNS:localhost/IP:127.0.0.1, generated offline with `openssl req -new -x509
// -newkey ec -pkeyopt ec_paramgen_curve:prime256v1` (100-year validity,
// matching lyric_tls_test.c's own embedded PKI's date range). PEM bodies
// are single-line (no 64-column wrap) — verified against real OpenSSL 3.0.13
// both as a bare `PEM_read_bio_X509`/`PEM_read_bio_PrivateKey` parse and as
// a genuine `openssl s_server`/`s_client` handshake before committing;
// PEM's base64 body has no column-width requirement, only BEGIN/END framing.
val certPemLines: String = "-----BEGIN CERTIFICATE-----\n" + "MIIBmzCCAUGgAwIBAgIUF53jj5+q9lC62OCpvIcAAI/oVGwwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDcyMDEyNDcyM1oYDzIxMjYwNjI2MTI0NzIzWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQJ8SdTiqgzDXDjrmSwFiYZ6vIFb8j4/U+gcBWLTHcNKAs9xhSJSGtzBV+SWoZJc2pyQHH4tsXSiPPWDKZ1gbivo28wbTAdBgNVHQ4EFgQUUmcOwFa9zuvKBrsN6JsoxNZdoWswHwYDVR0jBBgwFoAUUmcOwFa9zuvKBrsN6JsoxNZdoWswDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwCgYIKoZIzj0EAwIDSAAwRQIhAPm6RpWnf3WDf7EIR57eDUe3SgsXExsm52jbCUfFDX3VAiBD/a8zZCCDP7JRuy3go6c/dQLCU65JFLrWBwG1SEm+Ew==\n" + "-----END CERTIFICATE-----\n"

val keyPemLines: String = "-----BEGIN PRIVATE KEY-----\n" + "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg26Vow8u+QT7bxYY0+4w3zcNiy+eriN9mP+v2VrarMnWhRANCAAQJ8SdTiqgzDXDjrmSwFiYZ6vIFb8j4/U+gcBWLTHcNKAs9xhSJSGtzBV+SWoZJc2pyQHH4tsXSiPPWDKZ1gbiv\n" + "-----END PRIVATE KEY-----\n"

// A malformed private key: valid PKCS8 armor, garbage base64 body.
val badKeyPemLines: String = "-----BEGIN PRIVATE KEY-----\n" + "bm90LWEtdmFsaWQta2V5LWRlci1ib2R5\n" + "-----END PRIVATE KEY-----\n"

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "Std.Encoding native round-trip: base64 + UTF-8 (item A)" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Encoding\n" + "func main(): Int {\n" +
    "  val original = \"hello, native tls \\u{1F512}\"\n" +
    "  val utf8 = encodeUtf8(original)\n" +
    "  var decoded = \"\"\n" +
    "  match tryDecodeUtf8(utf8) {\n" +
    "    case Some(t) -> {\n" +
    "      decoded = t\n" +
    "    }\n" +
    "    case None -> {\n" +
    "      return 1\n" +
    "    }\n" +
    "  }\n" +
    "  if decoded != original {\n" +
    "    return 2\n" +
    "  }\n" +
    "  val b64 = encodeBase64(utf8)\n" +
    "  var roundTripped: slice[Byte] = []\n" +
    "  match tryDecodeBase64(b64) {\n" +
    "    case Some(bytes) -> {\n" +
    "      roundTripped = bytes\n" +
    "    }\n" +
    "    case None -> {\n" +
    "      return 3\n" +
    "    }\n" +
    "  }\n" +
    "  if roundTripped.length != utf8.length {\n" +
    "    return 4\n" +
    "  }\n" +
    "  var i = 0\n" +
    "  while i < utf8.length {\n" +
    "    if roundTripped[i] != utf8[i] {\n" +
    "      return 5\n" +
    "    }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  match tryDecodeBase64(\"not!valid\") {\n" +
    "    case Some(_) -> {\n" +
    "      return 6\n" +
    "    }\n" +
    "    case None -> {\n" +
    "    }\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "encoding round-trip")
}

// Exercises `_kernel_native/tls_host.l`'s actual deliverable,
// `Std.TlsHost.hostCertFromPemBytes`/`hostIdentityFromPemBytes`, directly
// rather than through `Std.Tls`'s opaque `Certificate`/`Identity` wrapper
// (blocked on #6234 — see this file's module header). Same PEM fixtures
// and same four assertions `Std.Tls`'s own PEM-loading test would make;
// this is the kernel boundary one layer below that API.
test "Std.TlsHost native PEM loading (kernel boundary): cert/identity ok, malformed key rejected (item B)" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.TlsHost\n" + "func main(): Int {\n" + "  val certPem = \"" +
    luQuote(certPemLines) +
    "\"\n" +
    "  val keyPem = \"" +
    luQuote(keyPemLines) +
    "\"\n" +
    "  val badKeyPem = \"" +
    luQuote(badKeyPemLines) +
    "\"\n" +
    "  val certBytes = encodeUtf8(certPem)\n" +
    "  val keyBytes = encodeUtf8(keyPem)\n" +
    "  val badKeyBytes = encodeUtf8(badKeyPem)\n" +
    "  match hostCertFromPemBytes(certBytes) {\n" +
    "    case Err(_) -> {\n" +
    "      return 1\n" +
    "    }\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  match hostIdentityFromPemBytes(certBytes, keyBytes) {\n" +
    "    case Err(_) -> {\n" +
    "      return 2\n" +
    "    }\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  var rejectedMalformed = false\n" +
    "  match hostIdentityFromPemBytes(certBytes, badKeyBytes) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      rejectedMalformed = true\n" +
    "    }\n" +
    "  }\n" +
    "  if not rejectedMalformed {\n" +
    "    return 3\n" +
    "  }\n" +
    "  var rejectedGarbage = false\n" +
    "  match hostCertFromPemBytes(encodeUtf8(\"not a certificate\")) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      rejectedGarbage = true\n" +
    "    }\n" +
    "  }\n" +
    "  if not rejectedGarbage {\n" +
    "    return 4\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.TlsHost PEM loading (kernel boundary)")
}

test "Std.TcpHost native plain round-trip: listen/connect/accept/read/write/close" {
  // No TLS, no threads needed: `hostConnect` completes into the listen
  // backlog even before `hostAccept` runs (ordinary TCP semantics). A real
  // TLS handshake needs both peers to actively drive handshake I/O
  // concurrently, but that scenario (item D) is not in this file — see
  // the module header for why (`Std.TcpHost.hostAcceptTls`'s
  // `TlsServerConfig.identity: Identity` is unavoidably `Std.Tls`'s opaque
  // type, blocked on #6234).
  val src = "package T\n" + "import Std.Core\n" + "import Std.TcpHost\n" + "func main(): Int {\n" +
    "  val listener = match hostListen(\"127.0.0.1\", 0) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val port = hostLocalPort(listener)\n" +
    "  val clientConn = match hostConnect(\"127.0.0.1\", port) {\n" +
    "    case Ok(c) -> c\n" +
    "    case Err(_) -> return 2\n" +
    "  }\n" +
    "  val serverConn = match hostAccept(listener) {\n" +
    "    case Ok(c) -> c\n" +
    "    case Err(_) -> return 3\n" +
    "  }\n" +
    "  if hostAlpn(serverConn) != \"\" {\n" +
    "    return 4\n" +
    "  }\n" +
    "  match hostWrite(clientConn, encodeUtf8(\"ping\")) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 5\n" +
    "    }\n" +
    "  }\n" +
    "  var gotPing = false\n" +
    "  match hostRead(serverConn, 64) {\n" +
    "    case Ok(bytes) -> {\n" +
    "      match tryDecodeUtf8(bytes) {\n" +
    "        case Some(t) -> {\n" +
    "          gotPing = t == \"ping\"\n" +
    "        }\n" +
    "        case None -> {\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  if not gotPing {\n" +
    "    return 6\n" +
    "  }\n" +
    "  match hostWrite(serverConn, encodeUtf8(\"pong\")) {\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      return 7\n" +
    "    }\n" +
    "  }\n" +
    "  var gotPong = false\n" +
    "  match hostRead(clientConn, 64) {\n" +
    "    case Ok(bytes) -> {\n" +
    "      match tryDecodeUtf8(bytes) {\n" +
    "        case Some(t) -> {\n" +
    "          gotPong = t == \"pong\"\n" +
    "        }\n" +
    "        case None -> {\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  hostClose(clientConn)\n" +
    "  hostClose(serverConn)\n" +
    "  hostStopListener(listener)\n" +
    "  if not gotPong {\n" +
    "    return 8\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.TcpHost plain round-trip")
}

// Item D (a real loopback TLS handshake through
// `Std.TcpHost.hostAcceptTls`) is deliberately not in this file — see the
// module header's "item B is scoped to the kernel boundary, and item D is
// deferred" section. It needs `Std.Tls`'s opaque `Identity` type, which
// `Lyric.LlvmCodegen` cannot construct or resolve as a generic type
// argument on `--target native` today (issue #6234). Re-add it once that
// lands.
