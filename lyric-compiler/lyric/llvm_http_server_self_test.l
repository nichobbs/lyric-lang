//! llvm_http_server_self_test.l — end-to-end self-test for N9.3's native
//! `Std.HttpServer` twin (issue #6104): real programs compile through the
//! full bridge pipeline (`Lyric.LlvmBridge.compileToNativeWithFlags` with
//! the `_kernel_native/` twins loaded, exactly like `lyric build --target
//! native`) and run, mirroring `llvm_tls_self_test.l`'s and
//! `llvm_http_client_self_test.l`'s harness shape.
//!
//! Six cases:
//!   - item A: a plaintext HTTP/1.1 round trip. A real client
//!     (`Std.TcpHost.hostConnect`, plain TCP) on the SAME thread as the
//!     server's own pull loop — a bare TCP `connect` completes into the
//!     listen backlog before `accept` runs, so no second thread is needed
//!     here (the same reasoning `llvm_tls_self_test.l`'s item C gives for
//!     its own plain-TCP case) — sends a real `GET /hello?x=1` request with
//!     a custom header, asserts `requestMethod`/`requestPath`/
//!     `requestQuery`/`requestHeaders` all observe it correctly, and
//!     asserts the real response bytes the client reads back (built via
//!     `respondText` + `urlDecode`) match.
//!   - item B: a real loopback TLS round trip. Unlike item A, a TLS
//!     handshake needs both peers actively exchanging handshake records at
//!     once, so the client runs on a genuine second `pthread_create`d OS
//!     thread (the same N4.5 callback-trampoline mechanism
//!     `llvm_ffi_self_test.l`'s pthread case and `llvm_tls_self_test.l`'s
//!     item D already verify) driving `Std.TcpHost.hostConnectTls` — the
//!     real N9.4 public client-TLS API, not a hand-rolled raw
//!     `lyric_tls_*` driver (N9.4 postdates this item's own prerequisites,
//!     so there is no need to re-derive what N9.4 already ships). The
//!     server thread (`main`) drives the real N9.3 deliverable under test:
//!     `Std.HttpServer.startListenerTls` + `nextContext` +
//!     `requestMethod`/`requestPath`/`requestBody` + `respondJson`, against
//!     a self-signed EC test certificate (the exact fixture
//!     `llvm_tls_self_test.l` already verified parses with real OpenSSL and
//!     completes a real `openssl s_server`/`s_client` handshake).
//!   - item C: the module header's h2-rejection guard
//!     (`_kernel_native/http_server.l`'s `onAccepted`). The client offers
//!     ONLY `"h2"` ALPN against a real TLS handshake (so it genuinely
//!     negotiates `h2`, not merely claims to), then asserts the server
//!     closed the connection rather than silently mis-parsing h2's binary
//!     frame format as HTTP/1.1 text (D-N-003 has no exceptions/hangs to
//!     rely on as an alternate "it broke" signal, so this checks for an
//!     explicit close/EOF or read error instead).
//!   - item D: a keep-alive round trip — two requests over the SAME
//!     connection, neither one carrying `Connection: close`, so both stay
//!     open under HTTP/1.1's default keep-alive semantics
//!     (`Std.HttpEngine.newConnection`'s `keepAlive = true`). Asserts both
//!     requests are individually observable via `nextContext` (i.e. the
//!     SAME connection-handler thread genuinely loops back to parse a
//!     second request rather than closing after the first) and both
//!     responses arrive correctly on the client's single, still-open
//!     socket.
//!   - item E: the regression case for #6791 — `stopListener` must not
//!     hang when a keep-alive connection is genuinely idle (one request
//!     answered, no `Connection: close`, client sends nothing further and
//!     does not close its own socket). Before the fix, the connection's
//!     handler thread parks forever in `hostRead` waiting for a next
//!     request that never comes, and `stopListener`'s `pthread_join` on
//!     that thread never returns; this case's own pass/fail signal IS
//!     `stopListener` returning at all — the harness's `Process.runCapture`
//!     60-second timeout turns a reintroduced deadlock into a real,
//!     visible test failure rather than a silently-hanging CI job.
//!   - item F: the regression case for #6792 — `spawnHandler` registered a
//!     connection into `ServerQueue.activeConns` AFTER spawning its
//!     handler thread, racing that thread's own `unregisterConn`. A
//!     connection that finishes its whole lifecycle fast enough (the
//!     common "client connects, never sends a byte, disconnects"
//!     health-check/port-scanner pattern) could run `unregisterConn` (a
//!     no-op, since the entry didn't exist yet) and `hostClose` BEFORE the
//!     parent ever registered it — leaving a permanently stale,
//!     already-closed (and potentially fd-reused) entry that `stopListener`
//!     would later `hostShutdown`. This is inherently timing-dependent (no
//!     deterministic single-shot repro exists without an injected
//!     synchronization point this file has no access to), so this case
//!     instead hammers the listener with 200 rapid connect-then-immediate-
//!     disconnect cycles — no bytes sent, maximizing the chance of the
//!     adverse scheduling #6792 describes — then drives one real,
//!     well-behaved request/response round trip and checks it completes
//!     uncorrupted (a stale entry whose fd got reused by this real
//!     connection would have `stopListener` shut down THIS connection out
//!     from under it), and finally asserts `stopListener` itself still
//!     returns promptly.
//!
//! Every scenario compiles with `-fsanitize=address`, so a leaked
//! `malloc`'d mutex/semaphore buffer, a leaked fd, a double-release, or a
//! `pthread_join` failure fails the run — the load-bearing check for
//! `_kernel_native/http_server.l`'s "shutdown drains every spawned thread
//! before freeing the queue" design (its own module header's "Shutdown"
//! section).
//!
//! Every connection-oriented case binds a FIXED port (19720/19721/19722/
//! 19723/19724/19725),
//! matching `lyric-stdlib/tests/http_server_dotnet_tests.l`'s own
//! established convention for testing this exact API — `Std.HttpServer`'s
//! public surface (unlike `Std.TcpHost`'s) has no `hostLocalPort`-style
//! ephemeral-port query, so there is no ephemeral-bind option available
//! here the way `llvm_tls_self_test.l`'s raw-`Std.TcpHost` cases have.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_http_server_self_test.l
@test_module
package Lyric.LlvmHttpServerSelfTest

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
// Harness (mirrors llvm_tls_self_test.l / llvm_http_client_self_test.l).
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
  val dir = Path.join(tempBase(), "lyric-llvm-httpserver-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val flags: List[String] = newList()
  flags.add("-fsanitize=address")
  if not compileToNativeWithFlags(source, stem, stdlib, "", "0", flags, newList()) {
    panic("native compilation failed for an HTTP server self-test program")
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

// The exact self-signed EC (prime256v1) test certificate `llvm_tls_self_test.l`
// already verified parses with real OpenSSL and completes a real
// `openssl s_server`/`s_client` handshake (CN=localhost, SAN
// DNS:localhost/IP:127.0.0.1, 100-year validity). Reused verbatim rather than
// re-generated, so this file carries no new PKI fixture to verify.
val certPemLines: String = "-----BEGIN CERTIFICATE-----\n" + "MIIBmzCCAUGgAwIBAgIUF53jj5+q9lC62OCpvIcAAI/oVGwwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDcyMDEyNDcyM1oYDzIxMjYwNjI2MTI0NzIzWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQJ8SdTiqgzDXDjrmSwFiYZ6vIFb8j4/U+gcBWLTHcNKAs9xhSJSGtzBV+SWoZJc2pyQHH4tsXSiPPWDKZ1gbivo28wbTAdBgNVHQ4EFgQUUmcOwFa9zuvKBrsN6JsoxNZdoWswHwYDVR0jBBgwFoAUUmcOwFa9zuvKBrsN6JsoxNZdoWswDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwCgYIKoZIzj0EAwIDSAAwRQIhAPm6RpWnf3WDf7EIR57eDUe3SgsXExsm52jbCUfFDX3VAiBD/a8zZCCDP7JRuy3go6c/dQLCU65JFLrWBwG1SEm+Ew==\n" + "-----END CERTIFICATE-----\n"

val keyPemLines: String = "-----BEGIN PRIVATE KEY-----\n" + "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg26Vow8u+QT7bxYY0+4w3zcNiy+eriN9mP+v2VrarMnWhRANCAAQJ8SdTiqgzDXDjrmSwFiYZ6vIFb8j4/U+gcBWLTHcNKAs9xhSJSGtzBV+SWoZJc2pyQHH4tsXSiPPWDKZ1gbiv\n" + "-----END PRIVATE KEY-----\n"

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "native Std.HttpServer plaintext HTTP/1.1 round trip: method/path/query/headers/urlDecode (item A)" {
  val src = "package A\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Encoding\n" +
    "import Std.HttpServer\n" +
    "import Std.TcpHost\n" +
    "func joined(parts: in List[String]): String {\n" +
    "  var s = \"\"\n" +
    "  var i = 0\n" +
    "  while i < parts.count {\n" +
    "    s = s + parts[i]\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  s\n" +
    "}\n" +
    "func readInto(conn: in Conn, acc: in List[String], marker: in String): Bool {\n" +
    "  var tries = 0\n" +
    "  var done = false\n" +
    "  while tries < 400 and not done {\n" +
    "    match hostRead(conn, 4096) {\n" +
    "      case Ok(b) -> {\n" +
    "        if b.length == 0 {\n" +
    "          done = true\n" +
    "        }\n" +
    "        match tryDecodeUtf8(b) {\n" +
    "          case Some(s) -> acc.add(s)\n" +
    "          case None -> ()\n" +
    "        }\n" +
    "      }\n" +
    "      case Err(_) -> {\n" +
    "        done = true\n" +
    "      }\n" +
    "    }\n" +
    "    if joined(acc).contains(marker) {\n" +
    "      done = true\n" +
    "    }\n" +
    "    tries = tries + 1\n" +
    "  }\n" +
    "  joined(acc).contains(marker)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val listener = startListener(\"http://127.0.0.1:19720/\")\n" +
    "  val clientConn = match hostConnect(\"127.0.0.1\", 19720) {\n" +
    "    case Ok(c) -> c\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val reqText = \"GET /hello?x=1 HTTP/1.1\\r\\nHost: x\\r\\nX-Test: abc\\r\\nConnection: close\\r\\n\\r\\n\"\n" +
    "  match hostWrite(clientConn, encodeUtf8(reqText)) {\n" +
    "    case Ok(_) -> ()\n" +
    "    case Err(_) -> return 2\n" +
    "  }\n" +
    "  val ctx = nextContext(listener)\n" +
    "  var exitCode = 0\n" +
    "  if requestMethod(ctx) != \"GET\" {\n" +
    "    exitCode = 3\n" +
    "  } else if requestPath(ctx) != \"/hello\" {\n" +
    "    exitCode = 4\n" +
    "  } else if requestQuery(ctx) != \"x=1\" {\n" +
    "    exitCode = 5\n" +
    "  } else {\n" +
    "    val hdrs = requestHeaders(ctx)\n" +
    "    val hv = match mapGet(hdrs, \"X-Test\") { case Some(v) -> v; case None -> \"\" }\n" +
    "    if hv != \"abc\" {\n" +
    "      exitCode = 6\n" +
    "    }\n" +
    "  }\n" +
    "  respondText(ctx, 200, \"hello native \" + urlDecode(\"%68%69\"))\n" +
    "  val acc: List[String] = newList()\n" +
    "  val gotIt = readInto(clientConn, acc, \"hello native hi\")\n" +
    "  hostClose(clientConn)\n" +
    "  stopListener(listener)\n" +
    "  if exitCode != 0 {\n" +
    "    return exitCode\n" +
    "  }\n" +
    "  if not gotIt {\n" +
    "    return 7\n" +
    "  }\n" +
    "  if not joined(acc).startsWith(\"HTTP/1.1 200\") {\n" +
    "    return 8\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpServer native plaintext round trip (item A)")
}

test "native Std.HttpServer TLS round trip: request headers/body, JSON response (item B)" {
  val src = "package B\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Encoding\n" +
    "import Std.Tls\n" +
    "import Std.HttpServer\n" +
    "import Std.TcpHost\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "extern func cStrcmp(a: NativePtr[Byte], b: NativePtr[Byte]): Int = \"strcmp\"\n" +
    "@unsafe_ffi\n" +
    "func clientRoundtrip(certPem: in String): NativePtr[Byte] {\n" +
    "  val conn = match hostConnectTls(\"127.0.0.1\", 19721, TlsTrustExclusive(caPem = certPem), None, TlsVersion.Tls12, \"http/1.1\") {\n" +
    "    case Ok(c) -> c\n" +
    "    case Err(_) -> return toC(\"FAIL:handshake\")\n" +
    "  }\n" +
    "  if hostAlpn(conn) != \"http/1.1\" {\n" +
    "    hostClose(conn)\n" +
    "    return toC(\"FAIL:alpn\")\n" +
    "  }\n" +
    "  val reqText = \"POST /submit HTTP/1.1\\r\\nHost: x\\r\\nContent-Length: 4\\r\\nConnection: close\\r\\n\\r\\nabcd\"\n" +
    "  match hostWrite(conn, encodeUtf8(reqText)) {\n" +
    "    case Ok(_) -> ()\n" +
    "    case Err(_) -> {\n" +
    "      hostClose(conn)\n" +
    "      return toC(\"FAIL:write\")\n" +
    "    }\n" +
    "  }\n" +
    "  var acc = \"\"\n" +
    "  var tries = 0\n" +
    "  var done = false\n" +
    "  while tries < 400 and not done {\n" +
    "    match hostRead(conn, 4096) {\n" +
    "      case Ok(b) -> {\n" +
    "        if b.length == 0 {\n" +
    "          done = true\n" +
    "        }\n" +
    "        match tryDecodeUtf8(b) {\n" +
    "          case Some(s) -> {\n" +
    "            acc = acc + s\n" +
    "          }\n" +
    "          case None -> ()\n" +
    "        }\n" +
    "      }\n" +
    "      case Err(_) -> {\n" +
    "        done = true\n" +
    "      }\n" +
    "    }\n" +
    "    if acc.contains(\"true\") {\n" +
    "      done = true\n" +
    "    }\n" +
    "    tries = tries + 1\n" +
    "  }\n" +
    "  hostClose(conn)\n" +
    "  if acc.startsWith(\"HTTP/1.1 201\") and acc.contains(\"true\") {\n" +
    "    toC(\"PASS\")\n" +
    "  } else {\n" +
    "    toC(\"FAIL:body\")\n" +
    "  }\n" +
    "}\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val certPem = \"" +
    luQuote(certPemLines) +
    "\"\n" +
    "  val keyPem = \"" +
    luQuote(keyPemLines) +
    "\"\n" +
    "  val identity = match Identity.fromPem(certPem, keyPem) {\n" +
    "    case Ok(id) -> id\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val cfg = TlsServerConfig(identity = identity, minVersion = TlsVersion.Tls12)\n" +
    "  val listener = match startListenerTls(\"127.0.0.1\", 19721, cfg) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 2\n" +
    "  }\n" +
    "  var tid: Long = 0\n" +
    "  val worker: () -> NativePtr[Byte] = { -> clientRoundtrip(certPem) }\n" +
    "  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)\n" +
    "  if rc != 0 {\n" +
    "    stopListener(listener)\n" +
    "    return 3\n" +
    "  }\n" +
    "  val ctx = nextContext(listener)\n" +
    "  var exitCode = 0\n" +
    "  if requestMethod(ctx) != \"POST\" {\n" +
    "    exitCode = 4\n" +
    "  } else if requestPath(ctx) != \"/submit\" {\n" +
    "    exitCode = 5\n" +
    "  } else if requestBody(ctx) != \"abcd\" {\n" +
    "    exitCode = 6\n" +
    "  }\n" +
    "  respondJson(ctx, 201, \"{\\\"ok\\\":true}\")\n" +
    "  stopListener(listener)\n" +
    "  var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "  val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "  if rj != 0 {\n" +
    "    return 7\n" +
    "  }\n" +
    "  val passC = toC(\"PASS\")\n" +
    "  val clientOk = cStrcmp(outp, passC) == 0\n" +
    "  freeC(passC)\n" +
    "  freeC(outp)\n" +
    "  if exitCode != 0 {\n" +
    "    return exitCode\n" +
    "  }\n" +
    "  if not clientOk {\n" +
    "    return 8\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpServer native TLS round trip (item B)")
}

test "native Std.HttpServer rejects a negotiated-h2 TLS connection rather than mis-parsing it as HTTP/1.1 (item C)" {
  val src = "package C\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Encoding\n" +
    "import Std.Tls\n" +
    "import Std.HttpServer\n" +
    "import Std.TcpHost\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "extern func cStrcmp(a: NativePtr[Byte], b: NativePtr[Byte]): Int = \"strcmp\"\n" +
    "@unsafe_ffi\n" +
    "func clientOfferH2(certPem: in String): NativePtr[Byte] {\n" +
    "  val conn = match hostConnectTls(\"127.0.0.1\", 19722, TlsTrustExclusive(caPem = certPem), None, TlsVersion.Tls12, \"h2\") {\n" +
    "    case Ok(c) -> c\n" +
    "    case Err(_) -> return toC(\"FAIL:handshake\")\n" +
    "  }\n" +
    "  if hostAlpn(conn) != \"h2\" {\n" +
    "    hostClose(conn)\n" +
    "    return toC(\"FAIL:alpn-not-h2\")\n" +
    "  }\n" +
    "  val _ = hostWrite(conn, encodeUtf8(\"garbage-h2-bytes\"))\n" +
    "  var closedOk = false\n" +
    "  match hostRead(conn, 64) {\n" +
    "    case Ok(bytes) -> {\n" +
    "      closedOk = bytes.length == 0\n" +
    "    }\n" +
    "    case Err(_) -> {\n" +
    "      closedOk = true\n" +
    "    }\n" +
    "  }\n" +
    "  hostClose(conn)\n" +
    "  if closedOk {\n" +
    "    toC(\"PASS\")\n" +
    "  } else {\n" +
    "    toC(\"FAIL:not-closed\")\n" +
    "  }\n" +
    "}\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val certPem = \"" +
    luQuote(certPemLines) +
    "\"\n" +
    "  val keyPem = \"" +
    luQuote(keyPemLines) +
    "\"\n" +
    "  val identity = match Identity.fromPem(certPem, keyPem) {\n" +
    "    case Ok(id) -> id\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val cfg = TlsServerConfig(identity = identity, minVersion = TlsVersion.Tls12)\n" +
    "  val listener = match startListenerTls(\"127.0.0.1\", 19722, cfg) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 2\n" +
    "  }\n" +
    "  var tid: Long = 0\n" +
    "  val worker: () -> NativePtr[Byte] = { -> clientOfferH2(certPem) }\n" +
    "  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)\n" +
    "  if rc != 0 {\n" +
    "    stopListener(listener)\n" +
    "    return 3\n" +
    "  }\n" +
    "  var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "  val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "  if rj != 0 {\n" +
    "    stopListener(listener)\n" +
    "    return 4\n" +
    "  }\n" +
    "  stopListener(listener)\n" +
    "  val passC = toC(\"PASS\")\n" +
    "  val clientOk = cStrcmp(outp, passC) == 0\n" +
    "  freeC(passC)\n" +
    "  freeC(outp)\n" +
    "  if not clientOk {\n" +
    "    return 5\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpServer native h2-rejection guard (item C)")
}

test "native Std.HttpServer keep-alive round trip: two requests over one connection (item D)" {
  val src = "package D\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Encoding\n" +
    "import Std.HttpServer\n" +
    "import Std.TcpHost\n" +
    "func joined(parts: in List[String]): String {\n" +
    "  var s = \"\"\n" +
    "  var i = 0\n" +
    "  while i < parts.count {\n" +
    "    s = s + parts[i]\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  s\n" +
    "}\n" +
    "func readInto(conn: in Conn, acc: in List[String], marker: in String): Bool {\n" +
    "  var tries = 0\n" +
    "  var done = false\n" +
    "  while tries < 400 and not done {\n" +
    "    match hostRead(conn, 4096) {\n" +
    "      case Ok(b) -> {\n" +
    "        if b.length == 0 {\n" +
    "          done = true\n" +
    "        }\n" +
    "        match tryDecodeUtf8(b) {\n" +
    "          case Some(s) -> acc.add(s)\n" +
    "          case None -> ()\n" +
    "        }\n" +
    "      }\n" +
    "      case Err(_) -> {\n" +
    "        done = true\n" +
    "      }\n" +
    "    }\n" +
    "    if joined(acc).contains(marker) {\n" +
    "      done = true\n" +
    "    }\n" +
    "    tries = tries + 1\n" +
    "  }\n" +
    "  joined(acc).contains(marker)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val listener = startListener(\"http://127.0.0.1:19723/\")\n" +
    "  val clientConn = match hostConnect(\"127.0.0.1\", 19723) {\n" +
    "    case Ok(c) -> c\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val req1 = \"GET /first HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n\"\n" +
    "  match hostWrite(clientConn, encodeUtf8(req1)) {\n" +
    "    case Ok(_) -> ()\n" +
    "    case Err(_) -> return 2\n" +
    "  }\n" +
    "  val ctx1 = nextContext(listener)\n" +
    "  var exitCode = 0\n" +
    "  if requestMethod(ctx1) != \"GET\" {\n" +
    "    exitCode = 3\n" +
    "  } else if requestPath(ctx1) != \"/first\" {\n" +
    "    exitCode = 4\n" +
    "  }\n" +
    "  respondText(ctx1, 200, \"resp-one\")\n" +
    "  val acc1: List[String] = newList()\n" +
    "  val got1 = readInto(clientConn, acc1, \"resp-one\")\n" +
    "  if exitCode == 0 and not got1 {\n" +
    "    exitCode = 5\n" +
    "  }\n" +
    "  if exitCode == 0 and not joined(acc1).startsWith(\"HTTP/1.1 200\") {\n" +
    "    exitCode = 6\n" +
    "  }\n" +
    "  val req2 = \"GET /second HTTP/1.1\\r\\nHost: x\\r\\nConnection: close\\r\\n\\r\\n\"\n" +
    "  match hostWrite(clientConn, encodeUtf8(req2)) {\n" +
    "    case Ok(_) -> ()\n" +
    "    case Err(_) -> {\n" +
    "      if exitCode == 0 {\n" +
    "        exitCode = 7\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  val ctx2 = nextContext(listener)\n" +
    "  if exitCode == 0 and requestPath(ctx2) != \"/second\" {\n" +
    "    exitCode = 8\n" +
    "  }\n" +
    "  respondText(ctx2, 200, \"resp-two\")\n" +
    "  val acc2: List[String] = newList()\n" +
    "  val got2 = readInto(clientConn, acc2, \"resp-two\")\n" +
    "  if exitCode == 0 and not got2 {\n" +
    "    exitCode = 9\n" +
    "  }\n" +
    "  hostClose(clientConn)\n" +
    "  stopListener(listener)\n" +
    "  if exitCode != 0 {\n" +
    "    return exitCode\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpServer native keep-alive round trip (item D)")
}

test "native Std.HttpServer stopListener does not hang on an idle keep-alive connection (item E, #6791 regression)" {
  val src = "package E\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Encoding\n" +
    "import Std.HttpServer\n" +
    "import Std.TcpHost\n" +
    "func joined(parts: in List[String]): String {\n" +
    "  var s = \"\"\n" +
    "  var i = 0\n" +
    "  while i < parts.count {\n" +
    "    s = s + parts[i]\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  s\n" +
    "}\n" +
    "func readInto(conn: in Conn, acc: in List[String], marker: in String): Bool {\n" +
    "  var tries = 0\n" +
    "  var done = false\n" +
    "  while tries < 400 and not done {\n" +
    "    match hostRead(conn, 4096) {\n" +
    "      case Ok(b) -> {\n" +
    "        if b.length == 0 {\n" +
    "          done = true\n" +
    "        }\n" +
    "        match tryDecodeUtf8(b) {\n" +
    "          case Some(s) -> acc.add(s)\n" +
    "          case None -> ()\n" +
    "        }\n" +
    "      }\n" +
    "      case Err(_) -> {\n" +
    "        done = true\n" +
    "      }\n" +
    "    }\n" +
    "    if joined(acc).contains(marker) {\n" +
    "      done = true\n" +
    "    }\n" +
    "    tries = tries + 1\n" +
    "  }\n" +
    "  joined(acc).contains(marker)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val listener = startListener(\"http://127.0.0.1:19724/\")\n" +
    "  val clientConn = match hostConnect(\"127.0.0.1\", 19724) {\n" +
    "    case Ok(c) -> c\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val reqText = \"GET /idle HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n\"\n" +
    "  match hostWrite(clientConn, encodeUtf8(reqText)) {\n" +
    "    case Ok(_) -> ()\n" +
    "    case Err(_) -> return 2\n" +
    "  }\n" +
    "  val ctx = nextContext(listener)\n" +
    "  var exitCode = 0\n" +
    "  if requestPath(ctx) != \"/idle\" {\n" +
    "    exitCode = 3\n" +
    "  }\n" +
    "  respondText(ctx, 200, \"idle-response\")\n" +
    "  val acc: List[String] = newList()\n" +
    "  val got = readInto(clientConn, acc, \"idle-response\")\n" +
    "  if not got {\n" +
    "    exitCode = 4\n" +
    "  }\n" +
    "  // The client deliberately never sends another request and never\n" +
    "  // closes its own socket here -- an idle keep-alive connection, the\n" +
    "  // #6791 repro. stopListener must return promptly rather than hang\n" +
    "  // forever pthread_join-ing the still-blocked-in-hostRead handler\n" +
    "  // thread.\n" +
    "  stopListener(listener)\n" +
    "  hostClose(clientConn)\n" +
    "  if exitCode != 0 {\n" +
    "    return exitCode\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpServer native stopListener idle-keep-alive regression (item E, #6791)")
}

test "native Std.HttpServer registry does not go stale under a fast connect-disconnect burst (item F, #6792 regression)" {
  val src = "package F\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Encoding\n" +
    "import Std.HttpServer\n" +
    "import Std.TcpHost\n" +
    "func joined(parts: in List[String]): String {\n" +
    "  var s = \"\"\n" +
    "  var i = 0\n" +
    "  while i < parts.count {\n" +
    "    s = s + parts[i]\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  s\n" +
    "}\n" +
    "func readInto(conn: in Conn, acc: in List[String], marker: in String): Bool {\n" +
    "  var tries = 0\n" +
    "  var done = false\n" +
    "  while tries < 400 and not done {\n" +
    "    match hostRead(conn, 4096) {\n" +
    "      case Ok(b) -> {\n" +
    "        if b.length == 0 {\n" +
    "          done = true\n" +
    "        }\n" +
    "        match tryDecodeUtf8(b) {\n" +
    "          case Some(s) -> acc.add(s)\n" +
    "          case None -> ()\n" +
    "        }\n" +
    "      }\n" +
    "      case Err(_) -> {\n" +
    "        done = true\n" +
    "      }\n" +
    "    }\n" +
    "    if joined(acc).contains(marker) {\n" +
    "      done = true\n" +
    "    }\n" +
    "    tries = tries + 1\n" +
    "  }\n" +
    "  joined(acc).contains(marker)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val listener = startListener(\"http://127.0.0.1:19725/\")\n" +
    "  // Hammer the listener with rapid connect-then-immediate-disconnect\n" +
    "  // cycles, no bytes sent -- the #6792 repro shape (a health-check/\n" +
    "  // port-scanner pattern). Each connection's handler thread should run\n" +
    "  // its whole lifecycle (accept -> immediate EOF -> RoClose ->\n" +
    "  // unregister -> close) essentially instantly, maximizing the chance\n" +
    "  // the accept-loop thread's own registration call races behind it if\n" +
    "  // the #6792 fix were ever reverted.\n" +
    "  var i = 0\n" +
    "  var scanErr = 0\n" +
    "  while i < 200 and scanErr == 0 {\n" +
    "    match hostConnect(\"127.0.0.1\", 19725) {\n" +
    "      case Ok(c) -> {\n" +
    "        hostClose(c)\n" +
    "      }\n" +
    "      case Err(_) -> {\n" +
    "        scanErr = 1\n" +
    "      }\n" +
    "    }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if scanErr != 0 {\n" +
    "    stopListener(listener)\n" +
    "    return 1\n" +
    "  }\n" +
    "  // A real, well-behaved request/response round trip right after the\n" +
    "  // scan burst: if a stale, already-closed entry from the scan burst\n" +
    "  // survived into activeConns (the #6792 bug) and its fd got reused by\n" +
    "  // THIS connection, stopListener's later hostShutdown on that stale\n" +
    "  // entry would hit this live connection's fd instead of a genuinely\n" +
    "  // dead one -- corrupting or prematurely killing it.\n" +
    "  val clientConn = match hostConnect(\"127.0.0.1\", 19725) {\n" +
    "    case Ok(c) -> c\n" +
    "    case Err(_) -> return 2\n" +
    "  }\n" +
    "  val reqText = \"GET /after-scan HTTP/1.1\\r\\nHost: x\\r\\nConnection: close\\r\\n\\r\\n\"\n" +
    "  match hostWrite(clientConn, encodeUtf8(reqText)) {\n" +
    "    case Ok(_) -> ()\n" +
    "    case Err(_) -> return 3\n" +
    "  }\n" +
    "  val ctx = nextContext(listener)\n" +
    "  var exitCode = 0\n" +
    "  if requestPath(ctx) != \"/after-scan\" {\n" +
    "    exitCode = 4\n" +
    "  }\n" +
    "  respondText(ctx, 200, \"post-scan-ok\")\n" +
    "  val acc: List[String] = newList()\n" +
    "  val got = readInto(clientConn, acc, \"post-scan-ok\")\n" +
    "  if not got {\n" +
    "    exitCode = 5\n" +
    "  }\n" +
    "  hostClose(clientConn)\n" +
    "  // The real regression check (#6792): stopListener must still return\n" +
    "  // promptly and cleanly (no crash, no hang) after absorbing the\n" +
    "  // 200-connection scan burst.\n" +
    "  stopListener(listener)\n" +
    "  if exitCode != 0 {\n" +
    "    return exitCode\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpServer native connection-registry race regression (item F, #6792)")
}
