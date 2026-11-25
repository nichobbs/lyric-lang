//! Std.Http on `--target native`: a send runs within its cancellation
//! token's limits (#9090). Every case uses a loopback peer that misbehaves
//! in one way: it accepts and never answers, sends headers and stalls in the
//! body, feeds the header block a byte at a time, never starts or never
//! finishes the TLS exchange, or refuses the connection.
//!
//! What is asserted is the contract the HTTP backends rely on: a deadline
//! that passes ends the send with `HttpError.Timeout` (#9067)
//! and a token that reads as cancelled; `cancelSource` ends it at once with a
//! cause naming the cancellation; a refused connection is neither.
//!
//! The peers are raw `Std.TcpHost` connections on their own threads, since a
//! well-behaved `Std.HttpServer` cannot stall on purpose.
//!
//!   lyric test --target native lyric-stdlib/tests/http_timeout_native_tests.l
@test_module
package Std.Http.TimeoutNativeTests

import Std.Core
import Std.Collections
import Std.Directory as Directory
import Std.Encoding
import Std.Errors
import Std.Http
import Std.Task as Task
import Std.TcpHost as Tcp
import Std.Testing
import Std.Time as Time
import Std.Tls as Tls

// Self-signed EC test certificate for `localhost` / 127.0.0.1 with its key,
// the fixture `llvm_http_client_self_test.l` uses. Test only.
val TEST_ONLY_CERT: String = "-----BEGIN CERTIFICATE-----\n" + "MIIBmzCCAUGgAwIBAgIUF53jj5+q9lC62OCpvIcAAI/oVGwwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDcyMDEyNDcyM1oYDzIxMjYwNjI2MTI0NzIzWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQJ8SdTiqgzDXDjrmSwFiYZ6vIFb8j4/U+gcBWLTHcNKAs9xhSJSGtzBV+SWoZJc2pyQHH4tsXSiPPWDKZ1gbivo28wbTAdBgNVHQ4EFgQUUmcOwFa9zuvKBrsN6JsoxNZdoWswHwYDVR0jBBgwFoAUUmcOwFa9zuvKBrsN6JsoxNZdoWswDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwCgYIKoZIzj0EAwIDSAAwRQIhAPm6RpWnf3WDf7EIR57eDUe3SgsXExsm52jbCUfFDX3VAiBD/a8zZCCDP7JRuy3go6c/dQLCU65JFLrWBwG1SEm+Ew==\n" + "-----END CERTIFICATE-----\n"

val TEST_ONLY_KEY: String = "-----BEGIN PRIVATE KEY-----\n" + "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg26Vow8u+QT7bxYY0+4w3zcNiy+eriN9mP+v2VrarMnWhRANCAAQJ8SdTiqgzDXDjrmSwFiYZ6vIFb8j4/U+gcBWLTHcNKAs9xhSJSGtzBV+SWoZJc2pyQHH4tsXSiPPWDKZ1gbiv\n" + "-----END PRIVATE KEY-----\n"

val timedOutCause: String = "request timed out"

// A send that has not returned after this long is a hang, reported as a
// failure instead of being waited out.
val hangGuardMs: Int = 15000

func listenLoopback(): Tcp.Listener {
  match Tcp.hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic(Tcp.TcpError.message(e))
  }
}

func closeListener(l: in Tcp.Listener): Unit {
  Tcp.hostStopListener(l)
  Tcp.hostCloseListener(l)
}

func urlOf(scheme: in String, l: in Tcp.Listener, path: in String): Url {
  val raw = scheme + "://127.0.0.1:" + Tcp.hostLocalPort(l).toString() + path
  match Url.tryFrom(raw) {
    case Ok(u) -> u
    case Err(e) -> panic(HttpError.message(e))
  }
}

func plainClient(): HttpClient {
  HttpClientBuilder.new().withNoRedirects().build()
}

func tlsClient(): HttpClient {
  val ca = match Tls.Certificate.fromPem(TEST_ONLY_CERT) {
    case Ok(c) -> c
    case Err(e) -> panic(Tls.TlsError.message(e))
  }
  // The raw peers below speak HTTP/1.1 after the handshake, which the shared
  // TLS server would otherwise answer with ALPN h2; the h2 path is covered by
  // http_client_h2_tests.l.
  HttpClientBuilder.new().withNoRedirects().withHttpVersion(Http11).withExclusiveCaCertificate(ca).build()
}

func serverTls(): Tls.TlsServerConfig {
  val identity = match Tls.Identity.fromPem(TEST_ONLY_CERT, TEST_ONLY_KEY) {
    case Ok(i) -> i
    case Err(e) -> panic(Tls.TlsError.message(e))
  }
  Tls.TlsServerConfig(identity = identity)
}

// What one send came to.
record Outcome {
  sent: Result[HttpResponse, HttpError]
  elapsedMs: Long
  tokenCancelled: Bool
}

func sendUnder(client: in HttpClient, url: in Url, src: in Task.CancellationTokenSource): Outcome {
  val tok = Task.sourceToken(src)
  val started = Time.monotonicNanos()
  val work: () -> Result[HttpResponse, HttpError] = { -> await client.sendWithCancel(request(GET, url), tok) }
  val guarded = Task.runWithin(hangGuardMs, work)
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  match guarded {
    case Some(sent) -> Outcome(sent = sent, elapsedMs = elapsedMs, tokenCancelled = Task.isCancelled(tok))
    case None -> panic("the send was still waiting after " + elapsedMs.toString() + " ms: its token was not honoured")
  }
}

func sendWithin(client: in HttpClient, url: in Url, timeoutMs: in Int): Outcome {
  sendUnder(client, url, Task.makeCancelSourceTimeout(timeoutMs))
}

func causeOf(o: in Outcome): String {
  match o.sent {
    case Ok(resp) -> "a response with status " + HttpResponse.statusCode(resp).toString()
    case Err(e) -> match e {
      case ConnectionFailed(_, cause) -> cause
      case Timeout(_, _) -> timedOutCause
      case _ -> "another error: " + HttpError.message(e)
    }
  }
}

func isTimeoutError(r: in Result[HttpResponse, HttpError]): Bool {
  match r {
    case Err(e) -> match e { case Timeout(_, _) -> true; case _ -> false }
    case Ok(_) -> false
  }
}

func assertTimeoutError(e: in HttpError, url: in String, what: in String): Unit {
  match e {
    case Timeout(u, ms) -> {
      assertEqual(u, url, what + ": the url")
      assertTrue(ms >= 250i64 and ms < 3300i64, what + ": the send ran for its timeout (" + ms.toString() + " ms)")
    }
    case _ -> assertTrue(false, what + ": expected HttpError.Timeout, got " + HttpError.message(e))
  }
}

func assertTimedOut(o: in Outcome, timeoutMs: in Int, what: in String): Unit {
  assertTrue(isTimeoutError(o.sent), what + ": the error is HttpError.Timeout")
  assertEqual(causeOf(o), timedOutCause, what + ": cause")
  assertTrue(o.tokenCancelled, what + ": the token reads as cancelled once the send reports the timeout")
  assertTrue(
    o.elapsedMs >= timeoutMs.toLong(),
    what + ": not reported before the deadline (" + o.elapsedMs.toString() + " ms)"
  )
  assertTrue(
    o.elapsedMs < timeoutMs.toLong() + 3000i64,
    what + ": reported at the deadline, not long after (" + o.elapsedMs.toString() + " ms)"
  )
}

func bodyOf(o: in Outcome): String {
  match o.sent {
    case Err(e) -> "error: " + HttpError.message(e)
    case Ok(resp) -> match await HttpResponse.bodyText(resp) { case Ok(t) -> t; case Err(_) -> "unreadable body" }
  }
}

// ── Misbehaving peers ────────────────────────────────────────────────────
// Reads the request, sends `head`, then waits for the client to hang up.
func serveThenStall(c: in Tcp.Conn, head: in String): Unit {
  val _request = Tcp.hostRead(c, 8192)
  if head.length > 0 {
    val _sent = Tcp.hostWrite(c, encodeUtf8(head))
  }
  val _hangup = Tcp.hostRead(c, 8192)
  Tcp.hostClose(c)
}

func acceptThenStall(l: in Tcp.Listener, head: in String): Unit {
  match Tcp.hostAccept(l) {
    case Ok(c) -> serveThenStall(c, head)
    case Err(_) -> ()
  }
}

func acceptTlsThenStall(l: in Tcp.Listener, head: in String): Unit {
  match Tcp.hostAcceptTls(l, serverTls()) {
    case Ok(c) -> serveThenStall(c, head)
    case Err(_) -> ()
  }
}

// Sends a status line, then one header byte every 40 ms for as long as the
// client stays: each read succeeds, so only an overall deadline ends it.
func acceptThenDrip(l: in Tcp.Listener): Unit {
  match Tcp.hostAccept(l) {
    case Err(_) -> ()
    case Ok(c) -> {
      val _request = Tcp.hostRead(c, 8192)
      var open = match Tcp.hostWrite(c, encodeUtf8("HTTP/1.1 200 OK\r\nX-Pad: ")) {
        case Ok(_) -> true
        case Err(_) -> false
      }
      var sent = 0
      while open and sent < 250 {
        Time.sleepMillis(40)
        open = match Tcp.hostWrite(c, encodeUtf8("a")) { case Ok(_) -> true; case Err(_) -> false }
        sent = sent + 1
      }
      Tcp.hostClose(c)
    }
  }
}

func respond(c: in Tcp.Conn, response: in String): Unit {
  val _request = Tcp.hostRead(c, 8192)
  val _sent = Tcp.hostWrite(c, encodeUtf8(response))
  Tcp.hostClose(c)
}

val pongResponse: String = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\npong"

// The open descriptors of this process, to show a send releases all of its own.
func openDescriptors(): Int {
  match Directory.enumerate("/dev/fd") {
    case Ok(entries) -> entries.length
    case Err(_) -> panic("/dev/fd cannot be listed")
  }
}

// ── The deadline, plain HTTP ─────────────────────────────────────────────
test "a server that accepts and never answers: the send ends at the token's deadline" {
  val l = listenLoopback()
  val o = sendWithin(plainClient(), urlOf("http", l, "/silent"), 400)
  assertTimedOut(o, 400, "no answer")
  closeListener(l)
}

test "a server that sends headers and stalls in a Content-Length body" {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> acceptThenStall(l, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial") })
  val o = sendWithin(plainClient(), urlOf("http", l, "/stalled-body"), 400)
  assertTimedOut(o, 400, "stalled Content-Length body")
  val _ = Task.awaitAll(sc)
  closeListener(l)
}

test "a server that stalls in a chunked body" {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(
    sc,
    { -> acceptThenStall(l, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n5\r\nwo") }
  )
  val o = sendWithin(plainClient(), urlOf("http", l, "/stalled-chunks"), 400)
  assertTimedOut(o, 400, "stalled chunked body")
  val _ = Task.awaitAll(sc)
  closeListener(l)
}

test "a server that stalls in a body that runs to the end of the connection" {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> acceptThenStall(l, "HTTP/1.1 200 OK\r\n\r\nsome of it") })
  val o = sendWithin(plainClient(), urlOf("http", l, "/stalled-to-eof"), 400)
  assertTimedOut(o, 400, "stalled close-delimited body")
  val _ = Task.awaitAll(sc)
  closeListener(l)
}

test "a server that keeps sending header bytes: the deadline is for the whole send, not for each read" {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> acceptThenDrip(l) })
  val o = sendWithin(plainClient(), urlOf("http", l, "/drip"), 500)
  assertTimedOut(o, 500, "dripping headers")
  val _ = Task.awaitAll(sc)
  closeListener(l)
}

// ── The deadline, HTTPS ──────────────────────────────────────────────────
test "HTTPS: a server that never answers the ClientHello" {
  val l = listenLoopback()
  val o = sendWithin(tlsClient(), urlOf("https", l, "/no-handshake"), 400)
  assertTimedOut(o, 400, "stalled TLS handshake")
  closeListener(l)
}

test "HTTPS: a server that completes the handshake and never answers the request" {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> acceptTlsThenStall(l, "") })
  val o = sendWithin(tlsClient(), urlOf("https", l, "/silent"), 600)
  assertTimedOut(o, 600, "no answer over TLS")
  val _ = Task.awaitAll(sc)
  closeListener(l)
}

test "HTTPS: a server that sends headers and stalls in the body" {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> acceptTlsThenStall(l, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial") })
  val o = sendWithin(tlsClient(), urlOf("https", l, "/stalled-body"), 600)
  assertTimedOut(o, 600, "stalled body over TLS")
  val _ = Task.awaitAll(sc)
  closeListener(l)
}

// ── Explicit cancellation ────────────────────────────────────────────────
test "cancelSource from another thread ends a send that is waiting for the response" {
  val l = listenLoopback()
  val src = Task.makeCancelSource()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> Time.sleepMillis(300); Task.cancelSource(src) })
  val o = sendUnder(plainClient(), urlOf("http", l, "/silent"), src)
  assertEqual(causeOf(o), "request cancelled: cancellation was requested", "cause")
  assertTrue(o.tokenCancelled, "the token is cancelled")
  assertTrue(
    o.elapsedMs >= 250i64 and o.elapsedMs < 3000i64,
    "ended when cancelled (" + o.elapsedMs.toString() + " ms)"
  )
  val _ = Task.awaitAll(sc)
  closeListener(l)
}

test "HTTPS: cancelSource ends a send that is stuck in the TLS handshake" {
  val l = listenLoopback()
  val src = Task.makeCancelSource()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> Time.sleepMillis(300); Task.cancelSource(src) })
  val o = sendUnder(tlsClient(), urlOf("https", l, "/no-handshake"), src)
  assertEqual(causeOf(o), "request cancelled: cancellation was requested", "cause")
  assertTrue(
    o.elapsedMs >= 250i64 and o.elapsedMs < 3000i64,
    "ended when cancelled (" + o.elapsedMs.toString() + " ms)"
  )
  val _ = Task.awaitAll(sc)
  closeListener(l)
}

test "cancelling a scope ends the sends that run under the scope's token" {
  val l = listenLoopback()
  val cancelled = Task.makeScope()
  val helper = Task.makeScope()
  Task.scopeSpawn(helper, { -> Time.sleepMillis(300); Task.cancelScope(cancelled) })
  val tok = Task.scopeToken(cancelled)
  val started = Time.monotonicNanos()
  val sent = await sendWithCancelAsync(request(GET, urlOf("http", l, "/silent")), tok)
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  match sent {
    case Ok(_) -> assertTrue(false, "a response from a server that never answers")
    case Err(e) -> assertTrue(
      elapsedMs < 3000i64,
      "ended when the scope was cancelled (" + elapsedMs.toString() + " ms)"
    )
  }
  assertTrue(Task.isCancelled(tok), "the scope's token is cancelled")
  val _ = Task.awaitAll(helper)
  closeListener(l)
}

test "a token cancelled before the send: no request is made" {
  val l = listenLoopback()
  val src = Task.makeCancelSource()
  Task.cancelSource(src)
  val o = sendUnder(plainClient(), urlOf("http", l, "/never-sent"), src)
  assertEqual(causeOf(o), "request cancelled: cancellation was requested", "cause")
  assertTrue(o.elapsedMs < 1000i64, "fails at once (" + o.elapsedMs.toString() + " ms)")
  closeListener(l)
}

test "a token whose deadline has already passed: the send reports the timeout" {
  val l = listenLoopback()
  val src = Task.makeCancelSourceTimeout(1)
  Time.sleepMillis(20)
  val o = sendUnder(plainClient(), urlOf("http", l, "/never-sent"), src)
  assertTrue(isTimeoutError(o.sent), "the error is HttpError.Timeout")
  assertTrue(o.tokenCancelled, "the token is cancelled")
  closeListener(l)
}

// ── What is not a timeout ────────────────────────────────────────────────
test "a refused connection under a deadline is a connection failure, not a timeout" {
  val l = listenLoopback()
  val url = urlOf("http", l, "/refused")
  closeListener(l)
  val o = sendWithin(plainClient(), url, 5000)
  val cause = causeOf(o)
  assertTrue(isErr(o.sent), "the send fails: " + cause)
  assertTrue(cause != timedOutCause, "not reported as a timeout: " + cause)
  assertFalse(o.tokenCancelled, "the token is not cancelled")
  assertTrue(o.elapsedMs < 3000i64, "fails without waiting for the deadline (" + o.elapsedMs.toString() + " ms)")
}

test "a host name that does not resolve under a deadline is a connection failure" {
  val url = match Url.tryFrom("http://name.invalid:8080/") {
    case Ok(u) -> u
    case Err(e) -> panic(HttpError.message(e))
  }
  val o = sendWithin(plainClient(), url, 20000)
  val cause = causeOf(o)
  assertTrue(isErr(o.sent), "the send fails: " + cause)
  assertTrue(cause != timedOutCause, "not reported as a timeout: " + cause)
  assertFalse(o.tokenCancelled, "the token is not cancelled")
}

test "a response inside the deadline is delivered, over HTTP and HTTPS" {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> match Tcp.hostAccept(l) { case Ok(c) -> respond(c, pongResponse); case Err(_) -> () } })
  val plain = sendWithin(plainClient(), urlOf("http", l, "/pong"), 5000)
  assertEqual(bodyOf(plain), "pong", "plain body")
  assertFalse(plain.tokenCancelled, "the token is not cancelled")
  Task.scopeSpawn(
    sc,
    { -> match Tcp.hostAcceptTls(l, serverTls()) { case Ok(c) -> respond(c, pongResponse); case Err(_) -> () } }
  )
  val secure = sendWithin(tlsClient(), urlOf("https", l, "/pong"), 5000)
  assertEqual(bodyOf(secure), "pong", "TLS body")
  val _ = Task.awaitAll(sc)
  closeListener(l)
}

test "a name that resolves: localhost is reached within the deadline" {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> match Tcp.hostAccept(l) { case Ok(c) -> respond(c, pongResponse); case Err(_) -> () } })
  val raw = "http://localhost:" + Tcp.hostLocalPort(l).toString() + "/pong"
  val url = match Url.tryFrom(raw) { case Ok(u) -> u; case Err(e) -> panic(HttpError.message(e)) }
  val o = sendWithin(plainClient(), url, 5000)
  assertEqual(bodyOf(o), "pong", "body")
  val _ = Task.awaitAll(sc)
  closeListener(l)
}

// ── The other entry points ───────────────────────────────────────────────
test "the free functions honour the token: getWithCancelAsync, postWithCancelAsync, the *WithTimeoutAsync family" {
  val l = listenLoopback()
  val raw = "http://127.0.0.1:" + Tcp.hostLocalPort(l).toString() + "/silent"
  val getSrc = Task.makeCancelSourceTimeout(300)
  match await getWithCancelAsync(raw, Task.sourceToken(getSrc)) {
    case Err(e) -> assertTimeoutError(e, raw, "getWithCancelAsync")
    case Ok(_) -> assertTrue(false, "getWithCancelAsync: a response from a server that never answers")
  }
  val postSrc = Task.makeCancelSourceTimeout(300)
  match await postWithCancelAsync(raw, "body", Task.sourceToken(postSrc)) {
    case Err(e) -> assertTimeoutError(e, raw, "postWithCancelAsync")
    case Ok(_) -> assertTrue(false, "postWithCancelAsync: a response from a server that never answers")
  }
  val started = Time.monotonicNanos()
  match await getWithTimeoutAsync(raw, 300) {
    case Err(e) -> assertTimeoutError(e, raw, "getWithTimeoutAsync")
    case Ok(_) -> assertTrue(false, "getWithTimeoutAsync: a response from a server that never answers")
  }
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  assertTrue(
    elapsedMs >= 300i64 and elapsedMs < 3300i64,
    "getWithTimeoutAsync waits its timeout (" + elapsedMs.toString() + " ms)"
  )
  match await postWithTimeoutAsync(raw, "body", 300) {
    case Err(e) -> assertTimeoutError(e, raw, "postWithTimeoutAsync")
    case Ok(_) -> assertTrue(false, "postWithTimeoutAsync: a response from a server that never answers")
  }
  match await sendWithTimeoutAsync(request(GET, urlOf("http", l, "/silent")), 300) {
    case Err(e) -> assertTimeoutError(e, raw, "sendWithTimeoutAsync")
    case Ok(_) -> assertTrue(false, "sendWithTimeoutAsync: a response from a server that never answers")
  }
  closeListener(l)
}

test "bodyTextWithCancel fails for a cancelled token and reads the body otherwise" {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> match Tcp.hostAccept(l) { case Ok(c) -> respond(c, pongResponse); case Err(_) -> () } })
  val o = sendWithin(plainClient(), urlOf("http", l, "/pong"), 5000)
  val _ = Task.awaitAll(sc)
  match o.sent {
    case Err(e) -> assertTrue(false, HttpError.message(e))
    case Ok(resp) -> {
      match await HttpResponse.bodyTextWithCancel(resp, Task.noCancellation()) {
        case Ok(t) -> assertEqual(t, "pong", "body under a live token")
        case Err(_) -> assertTrue(false, "the body reads under a live token")
      }
      val src = Task.makeCancelSource()
      Task.cancelSource(src)
      assertTrue(
        isErr(await HttpResponse.bodyTextWithCancel(resp, Task.sourceToken(src))),
        "a cancelled token fails the read"
      )
    }
  }
  closeListener(l)
}

test "a Unix-socket client is built, and each request fails with a typed error naming the gap" {
  val client = clientWithUnixSocket("/tmp/lyric-http-timeout-native-tests.sock")
  match await client.get("http://localhost/") {
    case Ok(_) -> assertTrue(false, "a response over a transport that does not exist")
    case Err(e) -> match e {
      case ConnectionFailed(_, cause) -> assertTrue(
        cause ==
          "Unix domain socket clients are not supported on --target native (the native socket layer has no Unix-socket transport)",
        "cause: " + cause
      )
      case _ -> assertTrue(false, "another error: " + HttpError.message(e))
    }
  }
}

// ── Resources ────────────────────────────────────────────────────────────
test "sends that time out, are cancelled or succeed leave no descriptor open" {
  val l = listenLoopback()
  val client = plainClient()
  // The first sends load whatever the process opens once.
  val _warm = sendWithin(client, urlOf("http", l, "/silent"), 20)
  val before = openDescriptors()
  var i = 0
  while i < 40 {
    val timedOut = sendWithin(client, urlOf("http", l, "/silent"), 5)
    assertEqual(causeOf(timedOut), timedOutCause, "cause")
    val src = Task.makeCancelSource()
    Task.cancelSource(src)
    val cancelled = sendUnder(client, urlOf("http", l, "/silent"), src)
    assertTrue(isErr(cancelled.sent), "the cancelled send fails")
    i = i + 1
  }
  assertEqualInt(openDescriptors(), before, "open descriptors after 80 sends")
  closeListener(l)
}
