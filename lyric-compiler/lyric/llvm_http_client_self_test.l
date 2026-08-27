//! llvm_http_client_self_test.l — end-to-end self-test for N9.4's native
//! `Std.HttpHost` client twin (issue #6105): a real HTTPS round trip
//! compiled through the full bridge pipeline
//! (`Lyric.LlvmBridge.compileToNativeWithFlags` with the `_kernel_native/`
//! twins loaded, exactly like `lyric build --target native`) and run.
//!
//! ## Why this drives `Std.HttpHost` directly, not `Std.Http`
//!
//! `Std.Http`'s own public surface for a TLS-configured client
//! (`HttpClientBuilder.build()`, and every other function returning the
//! `HttpClient` interface — `defaultClient()`, `clientWithRedirects`, …) does
//! not work on `--target native` today: `Std.Http.HttpClient` declares seven
//! `async func` methods, and `Lyric.LlvmCodegen`'s interface-dispatch
//! lowering only supports non-generic, non-async abstract methods (N3.2) —
//! verified directly against this exact interface:
//!
//! ```text
//! $ lyric build --target native repro.l   # val c = defaultClient()
//! Unhandled exception. System.Exception: Lyric.LlvmCodegen: type
//! 'HttpClient' is not yet supported for --target native (Phase N1 lowers
//! scalars and String only)
//! ```
//!
//! and, isolating the general shape with a same-signature custom interface
//! (proving this is a pre-existing, general async-interface gap, not
//! `HttpClient`- or bundled-stdlib-specific):
//!
//! ```text
//! Unhandled exception. System.Exception: Lyric.LlvmCodegen: interface
//! method '.greet' on 'T.Greeter' is not yet lowerable for --target native
//! — only non-generic abstract interface methods dispatch through the
//! vtable; default, generic, async, and Self-returning interface methods
//! are deferred (N3.2).
//! ```
//!
//! `_kernel_native/http_host.l`'s own module header documents this in full
//! (including why it is out of THIS issue's scope — a compiler-level
//! interface-dispatch fix, not a kernel-boundary one). This test therefore
//! calls `Std.HttpHost` (the kernel — plain records and free functions,
//! none of it touching the `HttpClient` interface) exactly the way
//! `llvm_tls_self_test.l` calls `Std.TcpHost` directly for N9.2, which is
//! both the only currently-reachable way to exercise `hostClientWithTls`'s
//! TLS-option surface on native AND the real, substantive deliverable this
//! issue asks for — `Std.Http`'s free functions (`getAsync`/`postAsync`/
//! `sendAsync`, which never touch the `HttpClient` interface) already call
//! straight into this same kernel and work today with zero test-harness
//! changes needed once the interface gap above closes.
//!
//! ## Why the server runs on a second thread
//!
//! Unlike a bare TCP `connect` (which completes into the listen backlog
//! before `accept` runs — see `llvm_tls_self_test.l`'s plain round-trip
//! case), a TLS handshake needs both peers actively exchanging handshake
//! records at once, and `Std.HttpHost.hostSendSafe` internally connects,
//! writes the request, AND blocks reading the full response in one call —
//! there is no point to interleave a single-threaded server's `accept`
//! between those steps. The server therefore runs on a genuine second
//! `pthread_create`d OS thread (the same N4.5 callback-trampoline mechanism
//! `llvm_ffi_self_test.l`'s pthread case verifies, and the same shape
//! `D-progress-712`'s item-D writeup anticipated for exactly this file),
//! driving `Std.TcpHost.hostAcceptTls`/`hostRead`/`hostWrite` directly per
//! the issue's own instruction — no `Std.HttpServer` involved (that is the
//! separate, not-yet-shipped N9.3/#6104).
//!
//! ## What one round trip covers
//!
//! The server accepts TWO sequential TLS connections over the SAME
//! listener (this kernel never keeps a connection alive — module header
//! item 2, always `Connection: close`, so a redirect hop is a fresh TCP+TLS
//! connection): the first request gets a 302 redirect to a second path,
//! the second gets a 200 response with a CHUNKED (`Transfer-Encoding:
//! chunked`) body split across two chunks. One client call
//! (`hostSendSafe`) is asserted to: complete the TLS handshake against a
//! self-signed certificate pinned via `hostClientWithTls`'s
//! `exclusiveCaCertificate` (real chain + hostname verification, not
//! `withInsecureSkipVerify`), follow the 301/302/303/307/308 redirect loop
//! to the second URL, and dechunk the reassembled body back to
//! `"Hello, world!"`.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`). Run
//! via native `lyric test` with `LYRIC_LOAD_COMPILER=1`:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_http_client_self_test.l
@test_module
package Lyric.LlvmHttpClientSelfTest

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
// Harness (mirrors llvm_tls_self_test.l).
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
  val dir = Path.join(tempBase(), "lyric-llvm-http-client-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
  val flags: List[String] = newList()
  flags.add("-fsanitize=address")
  if not compileToNativeWithFlags(source, stem, stdlib, "", "0", flags, newList()) {
    panic("native compilation failed for an HTTP client self-test program")
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
// DNS:localhost/IP:127.0.0.1 — the SAME fixture `llvm_tls_self_test.l` uses
// (see that file's header for provenance and verification notes). Reused
// verbatim rather than re-generated: it is already verified against real
// OpenSSL 3.0.13 both as a bare parse and as a genuine
// `openssl s_server`/`s_client` handshake.
val certPemLines: String = "-----BEGIN CERTIFICATE-----\n" + "MIIBmzCCAUGgAwIBAgIUF53jj5+q9lC62OCpvIcAAI/oVGwwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDcyMDEyNDcyM1oYDzIxMjYwNjI2MTI0NzIzWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQJ8SdTiqgzDXDjrmSwFiYZ6vIFb8j4/U+gcBWLTHcNKAs9xhSJSGtzBV+SWoZJc2pyQHH4tsXSiPPWDKZ1gbivo28wbTAdBgNVHQ4EFgQUUmcOwFa9zuvKBrsN6JsoxNZdoWswHwYDVR0jBBgwFoAUUmcOwFa9zuvKBrsN6JsoxNZdoWswDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwCgYIKoZIzj0EAwIDSAAwRQIhAPm6RpWnf3WDf7EIR57eDUe3SgsXExsm52jbCUfFDX3VAiBD/a8zZCCDP7JRuy3go6c/dQLCU65JFLrWBwG1SEm+Ew==\n" + "-----END CERTIFICATE-----\n"

val keyPemLines: String = "-----BEGIN PRIVATE KEY-----\n" + "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg26Vow8u+QT7bxYY0+4w3zcNiy+eriN9mP+v2VrarMnWhRANCAAQJ8SdTiqgzDXDjrmSwFiYZ6vIFb8j4/U+gcBWLTHcNKAs9xhSJSGtzBV+SWoZJc2pyQHH4tsXSiPPWDKZ1gbiv\n" + "-----END PRIVATE KEY-----\n"

// ─────────────────────────────────────────────────────────────────────────────
// Test.
// ─────────────────────────────────────────────────────────────────────────────
test "Std.HttpHost native HTTPS round trip: TLS handshake + redirect + chunked body (item E)" {
  val src = "package T\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Tls\n" +
    "import Std.TcpHost\n" +
    "import Std.HttpHost\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "extern func cStrlen(s: NativePtr[Byte]): Long = \"strlen\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "val certPem: String = \"" +
    luQuote(certPemLines) +
    "\"\n" +
    "val keyPem: String = \"" +
    luQuote(keyPemLines) +
    "\"\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val listener = match hostListen(\"127.0.0.1\", 0) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val port = hostLocalPort(listener)\n" +
    "  val worker: () -> NativePtr[Byte] = { ->\n" +
    "    match Identity.fromPem(certPem, keyPem) {\n" +
    "      case Err(_) -> toC(\"identity_failed\")\n" +
    "      case Ok(identity) -> {\n" +
    "        val cfg = TlsServerConfig(identity = identity, minVersion = TlsVersion.Tls12, clientCa = None, requireClientCert = false)\n" +
    "        match hostAcceptTls(listener, cfg) {\n" +
    "          case Err(_) -> toC(\"accept1_failed\")\n" +
    "          case Ok(conn1) -> {\n" +
    "            var req1Ok = false\n" +
    "            match hostRead(conn1, 8192) {\n" +
    "              case Ok(_) -> { req1Ok = true }\n" +
    "              case Err(_) -> ()\n" +
    "            }\n" +
    "            if not req1Ok {\n" +
    "              hostClose(conn1)\n" +
    "              toC(\"read1_failed\")\n" +
    "            } else {\n" +
    "              val resp1 = \"HTTP/1.1 302 Found\\r\\nLocation: /final\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n\"\n" +
    "              var write1Ok = false\n" +
    "              match hostWrite(conn1, encodeUtf8(resp1)) {\n" +
    "                case Ok(_) -> { write1Ok = true }\n" +
    "                case Err(_) -> ()\n" +
    "              }\n" +
    "              hostClose(conn1)\n" +
    "              if not write1Ok {\n" +
    "                toC(\"write1_failed\")\n" +
    "              } else {\n" +
    "                match hostAcceptTls(listener, cfg) {\n" +
    "                  case Err(_) -> toC(\"accept2_failed\")\n" +
    "                  case Ok(conn2) -> {\n" +
    "                    var req2Ok = false\n" +
    "                    match hostRead(conn2, 8192) {\n" +
    "                      case Ok(_) -> { req2Ok = true }\n" +
    "                      case Err(_) -> ()\n" +
    "                    }\n" +
    "                    if not req2Ok {\n" +
    "                      hostClose(conn2)\n" +
    "                      toC(\"read2_failed\")\n" +
    "                    } else {\n" +
    "                      val resp2 = \"HTTP/1.1 200 OK\\r\\nTransfer-Encoding: chunked\\r\\nConnection: close\\r\\n\\r\\n\" +\n" +
    "                        \"7\\r\\nHello, \\r\\n6\\r\\nworld!\\r\\n0\\r\\n\\r\\n\"\n" +
    "                      var write2Ok = false\n" +
    "                      match hostWrite(conn2, encodeUtf8(resp2)) {\n" +
    "                        case Ok(_) -> { write2Ok = true }\n" +
    "                        case Err(_) -> ()\n" +
    "                      }\n" +
    "                      hostClose(conn2)\n" +
    "                      if write2Ok {\n" +
    "                        toC(\"ok\")\n" +
    "                      } else {\n" +
    "                        toC(\"write2_failed\")\n" +
    "                      }\n" +
    "                    }\n" +
    "                  }\n" +
    "                }\n" +
    "              }\n" +
    "            }\n" +
    "          }\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  var tid: Long = 0\n" +
    "  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)\n" +
    "  if rc != 0 {\n" +
    "    hostStopListener(listener)\n" +
    "    return 2\n" +
    "  }\n" +
    "  val cert = match Certificate.fromPem(certPem) {\n" +
    "    case Ok(c) -> c\n" +
    "    case Err(_) -> return 3\n" +
    "  }\n" +
    "  val client = hostClientWithTls(None, false, false, None, Some(value = cert), None, None, false)\n" +
    "  val url = \"https://localhost:\" + port.toString() + \"/redirect\"\n" +
    "  val request = hostMakeRequest(\"GET\", url)\n" +
    "  var finalStatus = 0\n" +
    "  var finalBody = \"\"\n" +
    "  var sendOk = false\n" +
    "  match await hostSendSafe(client, request) {\n" +
    "    case Ok(response) -> {\n" +
    "      finalStatus = hostStatusCode(response)\n" +
    "      match await hostReadBodyTextSafe(response) {\n" +
    "        case Ok(text) -> { finalBody = text; sendOk = true }\n" +
    "        case Err(_) -> ()\n" +
    "      }\n" +
    "    }\n" +
    "    case Err(_) -> ()\n" +
    "  }\n" +
    "  var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "  val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "  var serverOk = false\n" +
    "  if rj == 0 {\n" +
    "    val n = cStrlen(outp)\n" +
    "    if n == 2 {\n" +
    "      serverOk = true\n" +
    "    }\n" +
    "    freeC(outp)\n" +
    "  }\n" +
    "  hostStopListener(listener)\n" +
    "  if not serverOk {\n" +
    "    return 4\n" +
    "  }\n" +
    "  if not sendOk {\n" +
    "    return 5\n" +
    "  }\n" +
    "  if finalStatus != 200 {\n" +
    "    return 6\n" +
    "  }\n" +
    "  if finalBody != \"Hello, world!\" {\n" +
    "    return 7\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpHost native HTTPS round trip (TLS + redirect + chunked)")
}

test "Std.HttpHost native redirect strips Authorization on a cross-authority hop (item F)" {
  // Plain HTTP (no TLS) on two distinct listeners so "cross-authority"
  // means an actual different port, exercised end to end: the first
  // request carries `Authorization`, the 302 response's `Location` is an
  // ABSOLUTE url pointing at the SECOND listener's port (a genuine
  // different authority, not just a different path on the same one like
  // item E's redirect), and the server thread asserts the second request
  // does NOT carry the header. No TLS/pthread-FFI trampoline is needed for
  // the plain-HTTP transport itself (item C's reasoning), but the full
  // client-request/server-response round trip still blocks on I/O both
  // sides must drive concurrently, so the server runs on a second
  // `pthread_create`d thread exactly like item E.
  val src = "package T\n" + "import Std.Core\n" + "import Std.Encoding\n" + "import Std.TcpHost\n" +
    "import Std.HttpHost\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "extern func cStrlen(s: NativePtr[Byte]): Long = \"strlen\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "func containsAt(s: String, needle: String, start: Int): Bool {\n" +
    "  if start + needle.length > s.length { false } else { s.substring(start, needle.length) == needle }\n" +
    "}\n" +
    "func containsSubstring(s: String, needle: String): Bool {\n" +
    "  var i = 0\n" +
    "  var found = false\n" +
    "  while i <= s.length - needle.length {\n" +
    "    if containsAt(s, needle, i) { found = true }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  found\n" +
    "}\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val listener1 = match hostListen(\"127.0.0.1\", 0) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val port1 = hostLocalPort(listener1)\n" +
    "  val listener2 = match hostListen(\"127.0.0.1\", 0) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 2\n" +
    "  }\n" +
    "  val port2 = hostLocalPort(listener2)\n" +
    "  val worker: () -> NativePtr[Byte] = { ->\n" +
    "    match hostAccept(listener1) {\n" +
    "      case Err(_) -> toC(\"accept1_failed\")\n" +
    "      case Ok(conn1) -> {\n" +
    "        var authOnFirst = false\n" +
    "        match hostRead(conn1, 8192) {\n" +
    "          case Ok(bytes) -> match tryDecodeUtf8(bytes) {\n" +
    "            case Some(t) -> { authOnFirst = containsSubstring(t, \"Authorization: Bearer secret-token\") }\n" +
    "            case None -> ()\n" +
    "          }\n" +
    "          case Err(_) -> ()\n" +
    "        }\n" +
    "        val loc = \"http://127.0.0.1:\" + port2.toString() + \"/final\"\n" +
    "        val resp1 = \"HTTP/1.1 302 Found\\r\\nLocation: \" + loc + \"\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n\"\n" +
    "        val _ = hostWrite(conn1, encodeUtf8(resp1))\n" +
    "        hostClose(conn1)\n" +
    "        if not authOnFirst {\n" +
    "          toC(\"auth_missing_on_first\")\n" +
    "        } else {\n" +
    "          match hostAccept(listener2) {\n" +
    "            case Err(_) -> toC(\"accept2_failed\")\n" +
    "            case Ok(conn2) -> {\n" +
    "              var authLeakedOnSecond = false\n" +
    "              match hostRead(conn2, 8192) {\n" +
    "                case Ok(bytes2) -> match tryDecodeUtf8(bytes2) {\n" +
    "                  case Some(t2) -> { authLeakedOnSecond = containsSubstring(t2, \"Authorization:\") }\n" +
    "                  case None -> ()\n" +
    "                }\n" +
    "                case Err(_) -> ()\n" +
    "              }\n" +
    "              val resp2 = \"HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nOK\"\n" +
    "              val _ = hostWrite(conn2, encodeUtf8(resp2))\n" +
    "              hostClose(conn2)\n" +
    "              if authLeakedOnSecond {\n" +
    "                toC(\"leaked\")\n" +
    "              } else {\n" +
    "                toC(\"ok\")\n" +
    "              }\n" +
    "            }\n" +
    "          }\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  var tid: Long = 0\n" +
    "  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)\n" +
    "  if rc != 0 {\n" +
    "    hostStopListener(listener1)\n" +
    "    hostStopListener(listener2)\n" +
    "    return 3\n" +
    "  }\n" +
    "  val client = hostDefaultClient()\n" +
    "  val url = \"http://127.0.0.1:\" + port1.toString() + \"/start\"\n" +
    "  val baseRequest = hostMakeRequest(\"GET\", url)\n" +
    "  val request = hostWithHeader(baseRequest, \"Authorization\", \"Bearer secret-token\")\n" +
    "  var finalStatus = 0\n" +
    "  var sendOk = false\n" +
    "  match await hostSendSafe(client, request) {\n" +
    "    case Ok(response) -> {\n" +
    "      finalStatus = hostStatusCode(response)\n" +
    "      sendOk = true\n" +
    "    }\n" +
    "    case Err(_) -> ()\n" +
    "  }\n" +
    "  var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "  val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "  var serverOk = false\n" +
    "  if rj == 0 {\n" +
    "    val n = cStrlen(outp)\n" +
    "    if n == 2 {\n" +
    "      serverOk = true\n" +
    "    }\n" +
    "    freeC(outp)\n" +
    "  }\n" +
    "  hostStopListener(listener1)\n" +
    "  hostStopListener(listener2)\n" +
    "  if not serverOk {\n" +
    "    return 4\n" +
    "  }\n" +
    "  if not sendOk {\n" +
    "    return 5\n" +
    "  }\n" +
    "  if finalStatus != 200 {\n" +
    "    return 6\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpHost native redirect strips Authorization on cross-authority hop")
}

test "Std.HttpHost native client rejects a header value with an embedded CRLF (item G, #6635)" {
  // No server thread needed: a plain TCP `hostConnect` completes into the
  // listen backlog before `hostAccept` ever runs (item C's reasoning), and
  // `buildRequestBytes`'s CR/LF validation runs client-side, before any
  // bytes are written to the wire — so a listener that never accepts is
  // enough to prove the request is rejected locally, not merely refused
  // by a peer.
  val src = "package T\n" + "import Std.Core\n" + "import Std.TcpHost\n" + "import Std.HttpHost\n" +
    "func main(): Int {\n" +
    "  val listener = match hostListen(\"127.0.0.1\", 0) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val port = hostLocalPort(listener)\n" +
    "  val client = hostDefaultClient()\n" +
    "  val url = \"http://127.0.0.1:\" + port.toString() + \"/x\"\n" +
    "  val base = hostMakeRequest(\"GET\", url)\n" +
    "  val poisoned = hostWithHeader(base, \"X-Evil\", \"value\\r\\nX-Injected: yes\")\n" +
    "  var rejected = false\n" +
    "  match await hostSendSafe(client, poisoned) {\n" +
    "    case Err(_) -> { rejected = true }\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  hostStopListener(listener)\n" +
    "  if not rejected {\n" +
    "    return 2\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpHost native client rejects an embedded CRLF in a header value")
}

test "Std.HttpHost native client rejects a response Content-Length beyond the size cap (item H, #6636)" {
  // The server declares an absurd Content-Length and Connection: close,
  // then closes immediately without sending any body — proving the
  // client rejects the DECLARED size before attempting to buffer it
  // (the fix's whole point: no multi-megabyte transfer is needed to
  // trigger or verify this, since the check runs against the parsed
  // Content-Length header value alone, before any body bytes are read).
  val src = "package T\n" + "import Std.Core\n" + "import Std.Encoding\n" + "import Std.TcpHost\n" +
    "import Std.HttpHost\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "extern func cStrlen(s: NativePtr[Byte]): Long = \"strlen\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "func containsAt(s: String, needle: String, start: Int): Bool {\n" +
    "  if start + needle.length > s.length { false } else { s.substring(start, needle.length) == needle }\n" +
    "}\n" +
    "func containsSubstring(s: String, needle: String): Bool {\n" +
    "  var i = 0\n" +
    "  var found = false\n" +
    "  while i <= s.length - needle.length {\n" +
    "    if containsAt(s, needle, i) { found = true }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  found\n" +
    "}\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val listener = match hostListen(\"127.0.0.1\", 0) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val port = hostLocalPort(listener)\n" +
    "  val worker: () -> NativePtr[Byte] = { ->\n" +
    "    match hostAccept(listener) {\n" +
    "      case Err(_) -> toC(\"accept_failed\")\n" +
    "      case Ok(conn) -> {\n" +
    "        var reqOk = false\n" +
    "        match hostRead(conn, 8192) {\n" +
    "          case Ok(_) -> { reqOk = true }\n" +
    "          case Err(_) -> ()\n" +
    "        }\n" +
    "        val resp = \"HTTP/1.1 200 OK\\r\\nContent-Length: 99999999\\r\\nConnection: close\\r\\n\\r\\n\"\n" +
    "        val _ = hostWrite(conn, encodeUtf8(resp))\n" +
    "        hostClose(conn)\n" +
    "        if reqOk { toC(\"ok\") } else { toC(\"leaked\") }\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  var tid: Long = 0\n" +
    "  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)\n" +
    "  if rc != 0 {\n" +
    "    hostStopListener(listener)\n" +
    "    return 2\n" +
    "  }\n" +
    "  val client = hostDefaultClient()\n" +
    "  val url = \"http://127.0.0.1:\" + port.toString() + \"/x\"\n" +
    "  val request = hostMakeRequest(\"GET\", url)\n" +
    "  var rejected = false\n" +
    // Check the SPECIFIC error message, not merely that some `Err` came
    // back — the pre-existing "connection closed before response body
    // was fully received" error (a server closing without sending the
    // full declared body) is ALSO an `Err` and would otherwise make this
    // test pass even with the size cap removed, since this server never
    // sends 99999999 bytes of body either way.
    "  match await hostSendSafe(client, request) {\n" +
    "    case Err(e) -> { rejected = containsSubstring(e, \"maximum allowed size\") }\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "  val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "  var serverOk = false\n" +
    "  if rj == 0 {\n" +
    "    val n = cStrlen(outp)\n" +
    "    if n == 2 {\n" +
    "      serverOk = true\n" +
    "    }\n" +
    "    freeC(outp)\n" +
    "  }\n" +
    "  hostStopListener(listener)\n" +
    "  if not serverOk {\n" +
    "    return 3\n" +
    "  }\n" +
    "  if not rejected {\n" +
    "    return 4\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpHost native client rejects an oversized Content-Length")
}

test "Std.HttpHost native redirect strips Authorization on an https-to-http downgrade at the SAME host:port (item I, #6646)" {
  // The exact scenario #6646 found inverted: a redirect that changes
  // SCHEME (https -> http) but stays on the identical host AND port is a
  // genuine cross-authority hop for credential-stripping purposes (a
  // passive network observer can now read the plaintext request), even
  // though `host == host and port == port`. One listener serves both legs
  // — `hostAcceptTls` for the first (TLS) connection, then plain
  // `hostAccept` for the second (the client reconnects in cleartext after
  // the downgrade) — since a TCP listen socket doesn't care which accept
  // function a given incoming connection is handled with.
  val src = "package T\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Tls\n" +
    "import Std.TcpHost\n" +
    "import Std.HttpHost\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "extern func cStrlen(s: NativePtr[Byte]): Long = \"strlen\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "val certPem: String = \"" +
    luQuote(certPemLines) +
    "\"\n" +
    "val keyPem: String = \"" +
    luQuote(keyPemLines) +
    "\"\n" +
    "func containsAt(s: String, needle: String, start: Int): Bool {\n" +
    "  if start + needle.length > s.length { false } else { s.substring(start, needle.length) == needle }\n" +
    "}\n" +
    "func containsSubstring(s: String, needle: String): Bool {\n" +
    "  var i = 0\n" +
    "  var found = false\n" +
    "  while i <= s.length - needle.length {\n" +
    "    if containsAt(s, needle, i) { found = true }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  found\n" +
    "}\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val listener = match hostListen(\"127.0.0.1\", 0) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val port = hostLocalPort(listener)\n" +
    "  val worker: () -> NativePtr[Byte] = { ->\n" +
    "    match Identity.fromPem(certPem, keyPem) {\n" +
    "      case Err(_) -> toC(\"identity_failed\")\n" +
    "      case Ok(identity) -> {\n" +
    "        val cfg = TlsServerConfig(identity = identity, minVersion = TlsVersion.Tls12, clientCa = None, requireClientCert = false)\n" +
    "        match hostAcceptTls(listener, cfg) {\n" +
    "          case Err(_) -> toC(\"accept1_failed\")\n" +
    "          case Ok(conn1) -> {\n" +
    "            var authOnFirst = false\n" +
    "            match hostRead(conn1, 8192) {\n" +
    "              case Ok(bytes) -> match tryDecodeUtf8(bytes) {\n" +
    "                case Some(t) -> { authOnFirst = containsSubstring(t, \"Authorization: Bearer secret-token\") }\n" +
    "                case None -> ()\n" +
    "              }\n" +
    "              case Err(_) -> ()\n" +
    "            }\n" +
    "            val loc = \"http://127.0.0.1:\" + port.toString() + \"/final\"\n" +
    "            val resp1 = \"HTTP/1.1 302 Found\\r\\nLocation: \" + loc + \"\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n\"\n" +
    "            val _ = hostWrite(conn1, encodeUtf8(resp1))\n" +
    "            hostClose(conn1)\n" +
    "            if not authOnFirst {\n" +
    "              toC(\"auth_missing_on_first\")\n" +
    "            } else {\n" +
    "              match hostAccept(listener) {\n" +
    "                case Err(_) -> toC(\"accept2_failed\")\n" +
    "                case Ok(conn2) -> {\n" +
    "                  var authLeakedOnSecond = false\n" +
    "                  match hostRead(conn2, 8192) {\n" +
    "                    case Ok(bytes2) -> match tryDecodeUtf8(bytes2) {\n" +
    "                      case Some(t2) -> { authLeakedOnSecond = containsSubstring(t2, \"Authorization:\") }\n" +
    "                      case None -> ()\n" +
    "                    }\n" +
    "                    case Err(_) -> ()\n" +
    "                  }\n" +
    "                  val resp2 = \"HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nOK\"\n" +
    "                  val _ = hostWrite(conn2, encodeUtf8(resp2))\n" +
    "                  hostClose(conn2)\n" +
    "                  if authLeakedOnSecond { toC(\"leaked\") } else { toC(\"ok\") }\n" +
    "                }\n" +
    "              }\n" +
    "            }\n" +
    "          }\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  var tid: Long = 0\n" +
    "  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)\n" +
    "  if rc != 0 {\n" +
    "    hostStopListener(listener)\n" +
    "    return 2\n" +
    "  }\n" +
    "  val cert = match Certificate.fromPem(certPem) {\n" +
    "    case Ok(c) -> c\n" +
    "    case Err(_) -> return 3\n" +
    "  }\n" +
    "  val client = hostClientWithTls(None, false, false, None, Some(value = cert), None, None, false)\n" +
    // Same host string ("127.0.0.1") as the redirect target below — the
    // whole point of this test is isolating the SCHEME change alone; a
    // different host string (e.g. "localhost" here vs "127.0.0.1" there)
    // would make `isSameRedirectAuthority`'s host comparison alone strip
    // the header regardless of whether the scheme clause is correct,
    // masking the exact bug #6646 was about (caught by disabling the fix
    // and confirming this test failed to catch the reintroduced bug,
    // before fixing the host mismatch here).
    "  val url = \"https://127.0.0.1:\" + port.toString() + \"/start\"\n" +
    "  val baseRequest = hostMakeRequest(\"GET\", url)\n" +
    "  val request = hostWithHeader(baseRequest, \"Authorization\", \"Bearer secret-token\")\n" +
    "  var finalStatus = 0\n" +
    "  var sendOk = false\n" +
    "  match await hostSendSafe(client, request) {\n" +
    "    case Ok(response) -> {\n" +
    "      finalStatus = hostStatusCode(response)\n" +
    "      sendOk = true\n" +
    "    }\n" +
    "    case Err(_) -> ()\n" +
    "  }\n" +
    "  var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "  val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "  var serverOk = false\n" +
    "  if rj == 0 {\n" +
    "    val n = cStrlen(outp)\n" +
    "    if n == 2 {\n" +
    "      serverOk = true\n" +
    "    }\n" +
    "    freeC(outp)\n" +
    "  }\n" +
    "  hostStopListener(listener)\n" +
    "  if not serverOk {\n" +
    "    return 4\n" +
    "  }\n" +
    "  if not sendOk {\n" +
    "    return 5\n" +
    "  }\n" +
    "  if finalStatus != 200 {\n" +
    "    return 6\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpHost native https-to-http downgrade at same host:port strips Authorization")
}

test "Std.HttpHost native client rejects an overflowing hex chunk-size line rather than reading past the buffer (item J, #6647)" {
  // A malicious "8000000F" chunk-size line overflows Int32 on the final
  // base-16 fold if the overflow guard uses the wrong (base-10) threshold
  // — wrapping to a large NEGATIVE size that drives `dataStart`/`pos`
  // negative in `readChunkedBody`, an out-of-bounds buffer index on the
  // next read. This asserts the client rejects the response with an
  // error instead (whether by failing to parse the chunk-size line at
  // all, or by some other clean `Err`), and specifically that it does
  // NOT crash/hang — the real risk #6647 was about.
  val src = "package T\n" + "import Std.Core\n" + "import Std.Encoding\n" + "import Std.TcpHost\n" +
    "import Std.HttpHost\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "extern func cStrlen(s: NativePtr[Byte]): Long = \"strlen\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val listener = match hostListen(\"127.0.0.1\", 0) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val port = hostLocalPort(listener)\n" +
    "  val worker: () -> NativePtr[Byte] = { ->\n" +
    "    match hostAccept(listener) {\n" +
    "      case Err(_) -> toC(\"accept_failed\")\n" +
    "      case Ok(conn) -> {\n" +
    "        var reqOk = false\n" +
    "        match hostRead(conn, 8192) {\n" +
    "          case Ok(_) -> { reqOk = true }\n" +
    "          case Err(_) -> ()\n" +
    "        }\n" +
    "        val resp = \"HTTP/1.1 200 OK\\r\\nTransfer-Encoding: chunked\\r\\nConnection: close\\r\\n\\r\\n\" + \"8000000F\\r\\n\"\n" +
    "        val _ = hostWrite(conn, encodeUtf8(resp))\n" +
    "        hostClose(conn)\n" +
    "        if reqOk { toC(\"ok\") } else { toC(\"leaked\") }\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  var tid: Long = 0\n" +
    "  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)\n" +
    "  if rc != 0 {\n" +
    "    hostStopListener(listener)\n" +
    "    return 2\n" +
    "  }\n" +
    "  val client = hostDefaultClient()\n" +
    "  val url = \"http://127.0.0.1:\" + port.toString() + \"/x\"\n" +
    "  val request = hostMakeRequest(\"GET\", url)\n" +
    "  var rejected = false\n" +
    "  match await hostSendSafe(client, request) {\n" +
    "    case Err(_) -> { rejected = true }\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "  val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "  var serverOk = false\n" +
    "  if rj == 0 {\n" +
    "    val n = cStrlen(outp)\n" +
    "    if n == 2 {\n" +
    "      serverOk = true\n" +
    "    }\n" +
    "    freeC(outp)\n" +
    "  }\n" +
    "  hostStopListener(listener)\n" +
    "  if not serverOk {\n" +
    "    return 3\n" +
    "  }\n" +
    "  if not rejected {\n" +
    "    return 4\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpHost native client rejects an overflowing hex chunk-size line")
}

test "Std.HttpHost native client rejects a chunked body whose cumulative size overflows Int32 (item K, #6656)" {
  // A first small chunk leaves `acc.count > 0`, then a second chunk
  // declares a size near `Int32.MaxValue` — bounded by #6647's own guard
  // so it parses fine on its own, but `acc.count + size` (the naive sum)
  // overflows Int32 and wraps NEGATIVE, which would silently bypass
  // `maxResponseBodyBytes` entirely. The server never needs to send any
  // of that huge second chunk's data: the fixed check runs on the
  // DECLARED size, before any attempt to read chunk data.
  val src = "package T\n" + "import Std.Core\n" + "import Std.Encoding\n" + "import Std.TcpHost\n" +
    "import Std.HttpHost\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "extern func cStrlen(s: NativePtr[Byte]): Long = \"strlen\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "func containsAt(s: String, needle: String, start: Int): Bool {\n" +
    "  if start + needle.length > s.length { false } else { s.substring(start, needle.length) == needle }\n" +
    "}\n" +
    "func containsSubstring(s: String, needle: String): Bool {\n" +
    "  var i = 0\n" +
    "  var found = false\n" +
    "  while i <= s.length - needle.length {\n" +
    "    if containsAt(s, needle, i) { found = true }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  found\n" +
    "}\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val listener = match hostListen(\"127.0.0.1\", 0) {\n" +
    "    case Ok(l) -> l\n" +
    "    case Err(_) -> return 1\n" +
    "  }\n" +
    "  val port = hostLocalPort(listener)\n" +
    "  val worker: () -> NativePtr[Byte] = { ->\n" +
    "    match hostAccept(listener) {\n" +
    "      case Err(_) -> toC(\"accept_failed\")\n" +
    "      case Ok(conn) -> {\n" +
    "        var reqOk = false\n" +
    "        match hostRead(conn, 8192) {\n" +
    "          case Ok(_) -> { reqOk = true }\n" +
    "          case Err(_) -> ()\n" +
    "        }\n" +
    "        val resp = \"HTTP/1.1 200 OK\\r\\nTransfer-Encoding: chunked\\r\\nConnection: close\\r\\n\\r\\n\" +\n" +
    "          \"1\\r\\nX\\r\\n\" + \"7FFFFFFF\\r\\n\"\n" +
    "        val _ = hostWrite(conn, encodeUtf8(resp))\n" +
    "        hostClose(conn)\n" +
    "        if reqOk { toC(\"ok\") } else { toC(\"leaked\") }\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "  var tid: Long = 0\n" +
    "  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)\n" +
    "  if rc != 0 {\n" +
    "    hostStopListener(listener)\n" +
    "    return 2\n" +
    "  }\n" +
    "  val client = hostDefaultClient()\n" +
    "  val url = \"http://127.0.0.1:\" + port.toString() + \"/x\"\n" +
    "  val request = hostMakeRequest(\"GET\", url)\n" +
    "  var rejected = false\n" +
    "  match await hostSendSafe(client, request) {\n" +
    "    case Err(e) -> { rejected = containsSubstring(e, \"maximum allowed size\") }\n" +
    "    case Ok(_) -> {\n" +
    "    }\n" +
    "  }\n" +
    "  var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "  val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "  var serverOk = false\n" +
    "  if rj == 0 {\n" +
    "    val n = cStrlen(outp)\n" +
    "    if n == 2 {\n" +
    "      serverOk = true\n" +
    "    }\n" +
    "    freeC(outp)\n" +
    "  }\n" +
    "  hostStopListener(listener)\n" +
    "  if not serverOk {\n" +
    "    return 3\n" +
    "  }\n" +
    "  if not rejected {\n" +
    "    return 4\n" +
    "  }\n" +
    "  42\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "Std.HttpHost native client rejects a cumulative-overflow chunked body")
}
