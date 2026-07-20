//! llvm_tls_self_test.l — end-to-end self-test for N9.2's native
//! `Std.TcpHost`/`Std.TlsHost`/`Std.EncodingHost` twins (issue #6103): real
//! programs importing `Std.Tls`/`Std.TcpHost` compile through the full
//! bridge pipeline (`Lyric.LlvmBridge.compileToNativeWithFlags` with the
//! `_kernel_native/` twins loaded, exactly like `lyric build --target
//! native`) and run with a genuine loopback TLS handshake over real
//! OpenSSL (the `lyric_tls_*` seam, N9.1/D-progress-703).
//!
//! The TLS scenario needs REAL concurrency (a bare TCP connect completes
//! into the listen backlog without either side present, but a TLS
//! handshake requires both peers to actively exchange handshake records
//! over the socket) — so the client runs on a genuine second OS thread
//! (`pthread_create`, the same N4.5 callback-trampoline mechanism
//! `llvm_ffi_self_test.l`'s "closure trampoline runs on a pthread" case
//! already verifies) driving the raw `lyric_tls_client_*` seam directly
//! (there is no `Std.TcpHost` client-TLS surface yet — that is N9.4,
//! `Std.Http`'s native client, issue #6105), while the server thread (the
//! test binary's `main`) drives the real N9.2 deliverable,
//! `Std.TcpHost.hostAcceptTls`. Every scenario compiles with
//! `-fsanitize=address`, so a leaked SSL_CTX/SSL/fd, a leaked LyricList
//! byte buffer, or a leaked CertHandle string fails the run.
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

test "Std.Tls native PEM loading: cert/identity ok, malformed key rejected (item B)" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Tls\n" + "func main(): Int {\n" + "  val certPem = \"" +
    luQuote(certPemLines) +
    "\"\n" +
    "  val keyPem = \"" +
    luQuote(keyPemLines) +
    "\"\n" +
    "  val badKeyPem = \"" +
    luQuote(badKeyPemLines) +
    "\"\n" +
    "  match Certificate.fromPem(certPem) {\n" +
    "    case Err(_) -> {\n" +
    "      return 1\n" +
    "    }\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  match Identity.fromPem(certPem, keyPem) {\n" +
    "    case Err(_) -> {\n" +
    "      return 2\n" +
    "    }\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  var rejectedMalformed = false\n" +
    "  match Identity.fromPem(certPem, badKeyPem) {\n" +
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
    "  match Certificate.fromPem(\"not a certificate\") {\n" +
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
  assertEqualInt(r.exitCode, 42, "Std.Tls PEM loading")
}

test "Std.TcpHost native plain round-trip: listen/connect/accept/read/write/close" {
  // No TLS, no threads needed: `hostConnect` completes into the listen
  // backlog even before `hostAccept` runs (ordinary TCP semantics), so a
  // single thread suffices -- unlike the TLS scenario below, which needs
  // both peers to actively drive handshake I/O concurrently.
  val src = "package T\n" + "import Std.Core\n" + "import Std.TcpHost\n" + "func main(): Int {\n" +
    "  val port = 19443\n" +
    "  val listener = match hostListen(\"127.0.0.1\", port) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
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

// The generated program's own `import Std.Tls`/`import Std.TcpHost` +
// certPem/keyPem literals + raw-seam client + pthread trampoline (items
// A+B+C together, real loopback handshake, ASan). Embeds the PEM text via
// escaped-newline string-literal concatenation (`"...\n" +`), the same
// generated-string-literal idiom `llvm_ffi_self_test.l` /
// `llvm_stdlib_self_test.l` already use, rather than a triple-quoted
// literal (nesting a real `"""` inside an already-`"`-quoted outer harness
// string has no clean escaping path).
test "Std.TcpHost native TLS handshake: hostAcceptTls real loopback (items A+B+C, ASan)" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Tls\n" + "import Std.TcpHost\n" +
    "val port: Int = 19543\n" +
    "val requestText: String = \"ping-from-native-tls-client\"\n" +
    "val responseText: String = \"pong-from-native-tls-server\"\n" +
    "val certPem: String = \"" +
    luQuote(certPemLines) +
    "\"\n" +
    "val keyPem: String = \"" +
    luQuote(keyPemLines) +
    "\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "extern func cStrlen(s: NativePtr[Byte]): Long = \"strlen\"\n" +
    "extern func rtSockConnect(host: NativePtr[Byte], port: Int): Int = \"lyric_sock_connect\"\n" +
    "extern func rtTlsClientNew(caPem: NativePtr[Byte], minVersion: Int, insecure: Int): Long = \"lyric_tls_client_new\"\n" +
    "extern func rtTlsClientConnect(ctx: Long, fd: Int, sniHost: NativePtr[Byte], alpnCsv: NativePtr[Byte]): Long = \"lyric_tls_client_connect\"\n" +
    "extern func rtTlsAlpnString(conn: Long): String = \"lyric_tls_alpn_string\"\n" +
    "extern func rtTlsWriteRaw(conn: Long, buf: NativePtr[Byte], n: Long): Long = \"lyric_tls_write\"\n" +
    "extern func rtTlsReadBytes(conn: Long, maxBytes: Long, okOut: NativePtr[Int]): slice[Byte] = \"lyric_tls_read_bytes\"\n" +
    "extern func rtTlsShutdown(conn: Long): Unit = \"lyric_tls_shutdown\"\n" +
    "extern func rtTlsFree(conn: Long): Unit = \"lyric_tls_free\"\n" +
    "extern func rtTlsCtxFree(ctx: Long): Unit = \"lyric_tls_ctx_free\"\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "@unsafe_ffi\n" +
    "func clientRun(): NativePtr[Byte] {\n" +
    "  val hostC = toC(\"127.0.0.1\")\n" +
    "  val fd = rtSockConnect(hostC, port)\n" +
    "  freeC(hostC)\n" +
    "  if fd < 0 {\n" +
    "    return toC(\"ERR_CONNECT\")\n" +
    "  }\n" +
    "  val caC = toC(\"\")\n" +
    "  val ctx = rtTlsClientNew(caC, 12, 1)\n" +
    "  freeC(caC)\n" +
    "  if ctx == 0i64 {\n" +
    "    return toC(\"ERR_CTX\")\n" +
    "  }\n" +
    "  val sniC = toC(\"localhost\")\n" +
    "  val alpnC = toC(\"h2,http/1.1\")\n" +
    "  val conn = rtTlsClientConnect(ctx, fd, sniC, alpnC)\n" +
    "  freeC(alpnC)\n" +
    "  freeC(sniC)\n" +
    "  if conn == 0i64 {\n" +
    "    rtTlsCtxFree(ctx)\n" +
    "    return toC(\"ERR_HANDSHAKE\")\n" +
    "  }\n" +
    "  val negotiated = rtTlsAlpnString(conn)\n" +
    "  if negotiated != \"h2\" {\n" +
    "    rtTlsShutdown(conn)\n" +
    "    rtTlsFree(conn)\n" +
    "    rtTlsCtxFree(ctx)\n" +
    "    return toC(\"ERR_ALPN\")\n" +
    "  }\n" +
    "  val reqC = toC(requestText)\n" +
    "  val reqLen = requestText.length.toLong()\n" +
    "  val wrote = rtTlsWriteRaw(conn, reqC, reqLen)\n" +
    "  freeC(reqC)\n" +
    "  if wrote != reqLen {\n" +
    "    rtTlsShutdown(conn)\n" +
    "    rtTlsFree(conn)\n" +
    "    rtTlsCtxFree(ctx)\n" +
    "    return toC(\"ERR_WRITE\")\n" +
    "  }\n" +
    "  var ok: Int = 0\n" +
    "  val respBytes = rtTlsReadBytes(conn, 256, nativeAddrOf(ok))\n" +
    "  rtTlsShutdown(conn)\n" +
    "  rtTlsFree(conn)\n" +
    "  rtTlsCtxFree(ctx)\n" +
    "  if ok != 1 {\n" +
    "    return toC(\"ERR_READ\")\n" +
    "  }\n" +
    "  var respText = \"\"\n" +
    "  var decodeOk = false\n" +
    "  match tryDecodeUtf8(respBytes) {\n" +
    "    case Some(t) -> {\n" +
    "      respText = t\n" +
    "      decodeOk = true\n" +
    "    }\n" +
    "    case None -> {\n" +
    "    }\n" +
    "  }\n" +
    "  if not decodeOk {\n" +
    "    return toC(\"ERR_DECODE\")\n" +
    "  }\n" +
    "  if respText != responseText {\n" +
    "    return toC(\"ERR_MISMATCH\")\n" +
    "  }\n" +
    "  toC(\"OK\")\n" +
    "}\n" +
    "@unsafe_ffi\n" +
    "func serverMain(): Int {\n" +
    "  var resultCode = 0\n" +
    "  match Identity.fromPem(certPem, keyPem) {\n" +
    "    case Err(_) -> {\n" +
    "      resultCode = 1\n" +
    "    }\n" +
    "    case Ok(identity) -> {\n" +
    "      val cfg = TlsServerConfig(identity = identity, minVersion = Tls12, clientCa = None, requireClientCert = false)\n" +
    "      match hostListen(\"127.0.0.1\", port) {\n" +
    "        case Err(_) -> {\n" +
    "          resultCode = 2\n" +
    "        }\n" +
    "        case Ok(listener) -> {\n" +
    "          val clientFn: () -> NativePtr[Byte] = { -> clientRun() }\n" +
    "          var tid: Long = 0\n" +
    "          val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), clientFn, clientFn)\n" +
    "          if rc != 0 {\n" +
    "            resultCode = 3\n" +
    "          } else {\n" +
    "            match hostAcceptTls(listener, cfg) {\n" +
    "              case Err(_) -> {\n" +
    "                resultCode = 4\n" +
    "              }\n" +
    "              case Ok(conn) -> {\n" +
    "                if hostAlpn(conn) != \"h2\" {\n" +
    "                  resultCode = 5\n" +
    "                }\n" +
    "                var serverSawRequest = false\n" +
    "                match hostRead(conn, 256) {\n" +
    "                  case Err(_) -> {\n" +
    "                  }\n" +
    "                  case Ok(reqBytes) -> {\n" +
    "                    match tryDecodeUtf8(reqBytes) {\n" +
    "                      case Some(t) -> {\n" +
    "                        if t == requestText {\n" +
    "                          serverSawRequest = true\n" +
    "                        }\n" +
    "                      }\n" +
    "                      case None -> {\n" +
    "                      }\n" +
    "                    }\n" +
    "                  }\n" +
    "                }\n" +
    "                if not serverSawRequest and resultCode == 0 {\n" +
    "                  resultCode = 6\n" +
    "                }\n" +
    "                if resultCode == 0 {\n" +
    "                  match hostWrite(conn, encodeUtf8(responseText)) {\n" +
    "                    case Err(_) -> {\n" +
    "                      resultCode = 7\n" +
    "                    }\n" +
    "                    case Ok(_) -> {\n" +
    "                    }\n" +
    "                  }\n" +
    "                }\n" +
    "                hostClose(conn)\n" +
    "                hostStopListener(listener)\n" +
    "                var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "                val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "                if resultCode == 0 {\n" +
    "                  if rj != 0 {\n" +
    "                    resultCode = 8\n" +
    "                  } else {\n" +
    "                    val n = cStrlen(outp)\n" +
    "                    freeC(outp)\n" +
    "                    if n != 2i64 {\n" +
    "                      resultCode = 9\n" +
    "                    }\n" +
    "                  }\n" +
    "                } else {\n" +
    "                  freeC(outp)\n" +
    "                }\n" +
    "              }\n" +
    "            }\n" +
    "          }\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  resultCode\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  serverMain()\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 0, "TLS handshake round-trip (0 = full success)")
}
