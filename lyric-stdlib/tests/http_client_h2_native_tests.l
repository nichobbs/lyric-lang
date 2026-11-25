//! stdlib/tests/http_client_h2_native_tests.l -- `Std.Http` on `--target native`
//! negotiates h2 through ALPN `h2,http/1.1` over `Std.HttpEngine.H2Client` and
//! keeps the D605 token semantics on it (docs/72 slice 7, D803).
//!
//! An `https` send to a server offering h2 and HTTP/1.1 is served over h2
//! (`HttpResponse.negotiatedVersion` is `Http2`) unless the client pins
//! `Http11`; request bodies and large responses flow under HTTP/2 flow
//! control; request headers are delivered; redirects are followed; a deadline
//! ends a send with `HttpError.Timeout`; `cancelSource` from another thread
//! ends one that waits for the response.
//!
//! Native only: the dotnet and JVM kernels delegate to their platform clients,
//! whose behaviour differs on some of these points (the progress note of D803
//! lists them). The peer is the real `Std.HttpServer` over TLS with ALPN.
//! Falling back to HTTP/1.1 when the server selects no protocol, and h2
//! against an independent implementation, are
//! `http_client_h2_interop_tests.l`.
//!
//!   lyric test --target native lyric-stdlib/tests/http_client_h2_native_tests.l
@test_module
package Std.Http.H2ClientNativeTests

import Std.Core
import Std.Collections
import Std.Errors
import Std.String
import Std.Tls
import Std.TcpHost
import Std.HttpServerHost
import Std.HttpServer
import Std.Http
import Std.Task as Task
import Std.Time
import Std.Testing

val caCertPem = """
-----BEGIN CERTIFICATE-----
MIIDETCCAfmgAwIBAgIUHAnWv6jzrCpsNoAYgRNWauQnnr0wDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNbHlyaWMtdGVzdC1jYTAeFw0yNjA3MTgwNzQyMzJaFw0z
NjA3MTUwNzQyMzJaMBgxFjAUBgNVBAMMDWx5cmljLXRlc3QtY2EwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQDd9+G8LLfeYkUd2KAdm0BfTrzVJquwm+/K
XIlei1KvQpjK/CIypyBWaQD5Hy/jMORnK1olPSP0kGGCAZo9+usfQmG/f9oHrZK3
a4tsBwo2NSJ3SGrSweCnHQiBC/F5P7b1SOTqFfC9NR5lQk8zHQnWagxkc7C/lXKU
1UeJavjdEgt4c6zbuXdCYCRsgnFfloIw4ilY9oyzg4oCcT1mLKYW2jPcnZs+Xloc
xyfXnWK60WHrDdlL5rAfGWT6Knu0mzpgXUnCFVkN60uDPRc1EJnpy6xEi6qUYns/
FRE8FHzXoSRKQkfN1z5CMaY+PmQfnvlBbWBJZVVBMKFZdCjo5SFDAgMBAAGjUzBR
MB0GA1UdDgQWBBQIcW5jDzQRQrZlYT7RorEGAkccFzAfBgNVHSMEGDAWgBQIcW5j
DzQRQrZlYT7RorEGAkccFzAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUA
A4IBAQBopXJDnAHpdqv1Psx8vAJ6v8RGJS3zuT63j+j/WFUeGQf7UbGW29za+sxr
yu+4RzKSnf29JCuQSEJ5DGjmh2AwPYSGvR6fO8f+h8++w/Ltw/E1wixE17NsFMLX
wXWMXhO2N49ehfGgJWbUMEL91qx/WOxtf8Z2Ljf3bi+xDFSEuiYba0a8VHSLq2WC
VCgisgaVP7oAYKjK1XaMip+a4ThI9HXZ6DsHJmmxEDBpGmikkBNhPbsVo9uuiNR/
c95c0HA4TUKMHXHLPjZrNCbLjM+fllPEH8thxvSHaYAbSYjGi4gg6drmpdjvcJ5F
H9nUvY6o5f2w41gyG0qTNx0tu4ld
-----END CERTIFICATE-----
"""

val serverCertPem = """
-----BEGIN CERTIFICATE-----
MIIDGDCCAgCgAwIBAgIULWRn9gh8NN75EVpn5QgfES55PcMwDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNbHlyaWMtdGVzdC1jYTAeFw0yNjA3MTgwNzQyMzJaFw0z
NjA3MTUwNzQyMzJaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBAK3jysZKZuOw3iRVHNxhaoKpURK3mq0rNrBiAzGx
5NPDh7UQlSNjIQqWkADKCLe7Yz5EKdPc1GmwY3Lfs9Y9qdxrw9gvFlYWRfXPq4lV
SFPX/OYufRvTlVkDfOuO5SBzZmhFxVJL/ygWeXe9nZRShBQMkpac1daUhsLR57sv
LERej9pT8prMQlGhOBA065OsisOHbiXDA8wCYO6C2ZTZ+WLN/ZdKTfyNoL0lRs/H
mHKNvzjZbRYdjPUyBfqmtFhBgc2mJDSQMrwmntLSh9J2Pe7Nk4fI8snCwucQSgm1
kwMgZYP/rPDaVFn2vagDhCwFIKgE8arb1Zuw77YQAf95EVcCAwEAAaNeMFwwGgYD
VR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMB0GA1UdDgQWBBS394tqWuNElfTcMY6e
ZYEVzqSEmDAfBgNVHSMEGDAWgBQIcW5jDzQRQrZlYT7RorEGAkccFzANBgkqhkiG
9w0BAQsFAAOCAQEAsbKLjP/NLU6nTjZMINgWDh3jmYLYPi1WTza0iQ1/naSDDjRj
StXxbwXLuWAKDAsQEgMqDba86QccWmUrtDMAzVwqr+m20x2fHtI4WWAWbLZdqEje
vgVVRph8ohAXIGbqKzyGBfgoxWmATxJCAM4+MCgU8wHuiz1vndzmEXZ0PQR/aRHm
1YZtwUDbV4T8BKS3RlFn8uk1v5enxUjp+TsrKbdfAfvpRNOhKsIPVhCjOM6RC+QN
li0ylHyST0tfJ7rMv8x4VbqofOQT4QpJuvXWQZHs06VOHU2YvViGfG/bhm/76Ku9
KGnPfvo09kP0A5oO14Q52uRQV5mYBkX5TsZLnw==
-----END CERTIFICATE-----
"""

val serverKeyPem = """
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCt48rGSmbjsN4k
VRzcYWqCqVESt5qtKzawYgMxseTTw4e1EJUjYyEKlpAAygi3u2M+RCnT3NRpsGNy
37PWPanca8PYLxZWFkX1z6uJVUhT1/zmLn0b05VZA3zrjuUgc2ZoRcVSS/8oFnl3
vZ2UUoQUDJKWnNXWlIbC0ee7LyxEXo/aU/KazEJRoTgQNOuTrIrDh24lwwPMAmDu
gtmU2flizf2XSk38jaC9JUbPx5hyjb842W0WHYz1MgX6prRYQYHNpiQ0kDK8Jp7S
0ofSdj3uzZOHyPLJwsLnEEoJtZMDIGWD/6zw2lRZ9r2oA4QsBSCoBPGq29WbsO+2
EAH/eRFXAgMBAAECggEACKrCaBi8QRwHLnNpkVhvqRyMVGz/UiNFwgvYkekGeUGV
KYKulEl0E6WGfuuS/Klj3G4kUZF/qtbmVgrtWT/QkBJ0+/j42YiZqxNTPvCXvsoU
qlpl1PW6S2n/l3QTWoc18vuLRrtP9+0K19uFF6f3OlKYGdauV9gmUV6J+Mv0nmGt
AEKLVROAg2xdML8WlW0HXmPZtg0ACrR2aE4udV4sq2ulCPEeaAHYCZ7w7p4mzKuh
tdm6BE1nQXtUVLiHDrwB1Hi51bsocwC7tEF3fLgHrx6TEWF6d3937JPzUZLtS8pe
qvJDLNc/aMeydY2EBIH3F14wWQ32B69FwM1YzKNYcQKBgQDv1vM+EIrx4MAaz2e3
qy5PWL8F6m+L7HArwSx7rWc2QJ73yLVlCxvavKK+ToCQljeT1ou5nlRonszUhecE
zX3DXnPV0o+7p9Y7OwG2sjkJmgPjdRFnWuOjcnJrPnEw4kTlzd7A9Cvu9sKsI9Gu
nqtPNKI443th6o8Ug+lfTzLOZwKBgQC5m0ID/8kz/3xR3u7gZwPK//INuHfxXzza
Ps6lagEo+Dr6UZtFGRSqLtQ7L+HcGq+306wwJ4oqf6av537ZzYgtNsPHUCxCtvWe
aV4F5P0uwU/YR/d366TSGXECw7lm5Fd8URMAWwHXiH/zy0eJm8XEViucHXGHvlpx
+f1xgwDvkQKBgCaerTJsRYNnVme6yA+6P83FE5VnR6j3XKSfCYOsy3bf9vkdV6A6
prSVNXuBdpBRsAddP8iW5y6li4QZP7b1Q/AGsI5Yxo5IG2YUPVVm42pZY5Dn0/KZ
nxg9oJEGUAG4HbIHcXwOlVh4YaaIagY9RIaPiiOw9bgxpfJ+v0B6p0q3AoGAM2Hu
6aqDKfj9krCz0r3SB/3JJdE+qzyhXQ3sKVDqV0w5D5lN8dgap25lZKlBzqw4nxxj
W8Vmc5N5MtNUg7lpjJLPqjrgtetundcvp1QYXzw2/XoW4UUEEQHoDkre5cQrEAhl
yUBohyGLwpMxD8BnBI6Sbhqclma1JT5+0lDhDnECgYAwzWxRe9KUwT/MuktbYvBr
hc/u/FLNekzSpyBpofYdPxZFA++6tMnfDHzUYj+c8vTimarL/3eg32tlxVjx2awZ
yRV4a3HFSdOFVQOKw57bMaQA8+M8GZ8RsAusrzDS28gubyjOJBpzz8Rg5RFmUZ1M
Ctkm17tiE4Fcz1p3gfUr4A==
-----END PRIVATE KEY-----
"""

func serverIdentity(): Identity {
  match Identity.fromPem(serverCertPem, serverKeyPem) {
    case Ok(id) -> id
    case Err(e) -> panic("server identity load failed: " + TlsError.message(e))
  }
}

func caCertificate(): Certificate {
  match Certificate.fromPem(caCertPem) {
    case Ok(c) -> c
    case Err(e) -> panic("ca load failed: " + TlsError.message(e))
  }
}

func startTlsServer(): HttpListener {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  match startListenerTls("127.0.0.1", 0, cfg) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTls failed: " + TlsListenError.message(e))
  }
}

func clientBuilder(): HttpClientBuilder {
  HttpClientBuilder.new().withExclusiveCaCertificate(caCertificate())
}

func h2Client(): HttpClient {
  clientBuilder().build()
}

func http11Client(): HttpClient {
  clientBuilder().withHttpVersion(Http11).build()
}

func urlText(l: in HttpListener, path: in String): String {
  "https://localhost:" + hostLocalPort(l.transport).toString() + path
}

func urlFor(l: in HttpListener, path: in String): Url {
  match Url.tryFrom(urlText(l, path)) {
    case Ok(u) -> u
    case Err(e) -> panic(HttpError.message(e))
  }
}

// Bounded waits: a peer that misbehaves fails the suite instead of hanging it.
func waitSem(s: in Semaphore, ms: in Int): Bool {
  var waited = 0
  while waited < ms {
    if semTryWait(s) {
      return true
    }
    sleepMillis(5)
    waited = waited + 5
  }
  false
}

ref record Job {
  done: Semaphore
  var failure: String
}

func startJob(work: in () -> Unit): Job {
  val j = Job(done = newSem(0), failure = "")
  startTask({ -> runGuarded({ -> work() }, { m -> j.failure = m }); semPost(j.done) })
  j
}

func joinJob(j: in Job): Unit {
  if not waitSem(j.done, 30000) {
    panic("a background job did not finish within 30 s")
  }
  if j.failure.length > 0 {
    panic("background job failed: " + j.failure)
  }
}

func headerLine(ctx: in HttpContext, name: in String): String {
  val hs = requestHeaders(ctx)
  if hs.containsKey(name) {
    hs[name]
  } else {
    ""
  }
}

func echo(ctx: in HttpContext): Unit {
  val reply = "m=" + requestMethod(ctx) + ";path=" + requestPath(ctx) + ";q=" + requestQuery(ctx) + ";len=" +
    requestBodyBytes(ctx).length.toString() +
    ";x=" +
    headerLine(ctx, "x-lyric-test")
  respondText(ctx, 200, reply)
}

func serve(l: in HttpListener, n: in Int, handler: in (HttpContext) -> Unit): Job {
  startJob({ -> var i = 0; while i < n { handler(nextContext(l)); i = i + 1 } })
}

func bodyOf(resp: in HttpResponse): String {
  match await HttpResponse.bodyText(resp) {
    case Ok(t) -> t
    case Err(e) -> panic("response body read failed: " + IOError.message(e))
  }
}

func getOk(client: in HttpClient, url: in String): HttpResponse {
  match await client.get(url) {
    case Ok(r) -> r
    case Err(e) -> panic("GET failed: " + HttpError.message(e))
  }
}

func assertVersion(resp: in HttpResponse, wantH2: in Bool, what: in String): Unit {
  match HttpResponse.negotiatedVersion(resp) {
    case Http2 -> assertTrue(wantH2, what + ": negotiated h2")
    case Http11 -> assertTrue(not wantH2, what + ": negotiated HTTP/1.1")
    case _ -> assertTrue(false, what + ": unexpected version")
  }
}

func makeBody(n: in Int): String {
  var s = ""
  while s.length < n {
    s = s + "0123456789"
  }
  s.substring(0, n)
}

test "an https GET is served over h2 by default" {
  val l = startTlsServer()
  val server = serve(l, 1, { c -> echo(c) })
  val resp = getOk(h2Client(), urlText(l, "/hello?x=1"))
  assertEqualInt(resp.statusCode(), 200, "status")
  assertVersion(resp, true, "default client")
  val body = bodyOf(resp)
  assertTrue(body.contains("m=GET;path=/hello;q=x=1"), "the handler saw the request: " + body)
  assertTrue(isSome(resp.header("Content-Type")), "a response header is readable, whatever its case on the wire")
  joinJob(server)
  stopListener(l)
}

test "withHttpVersion(Http11) pins HTTP/1.1 and still round-trips" {
  val l = startTlsServer()
  val server = serve(l, 1, { c -> echo(c) })
  val resp = getOk(http11Client(), urlText(l, "/pinned"))
  assertEqualInt(resp.statusCode(), 200, "status")
  assertVersion(resp, false, "pinned client")
  assertTrue(bodyOf(resp).contains("m=GET;path=/pinned"), "body")
  joinJob(server)
  stopListener(l)
}

test "a POST body larger than the initial h2 window is delivered" {
  val l = startTlsServer()
  val server = serve(l, 1, { c -> echo(c) })
  val client = h2Client()
  val resp = match await client.post(urlText(l, "/up"), makeBody(300000)) {
    case Ok(r) -> r
    case Err(e) -> panic("POST failed: " + HttpError.message(e))
  }
  assertVersion(resp, true, "POST")
  val body = bodyOf(resp)
  assertTrue(body.contains("m=POST;path=/up"), "method and path: " + body)
  assertTrue(body.contains("len=300000"), "every request byte arrived: " + body)
  joinJob(server)
  stopListener(l)
}

test "a 1 MiB response body is read in full over h2" {
  val l = startTlsServer()
  val server = serve(l, 1, { c -> respondText(c, 200, makeBody(1048576)) })
  val resp = getOk(h2Client(), urlText(l, "/big"))
  assertVersion(resp, true, "big")
  val body = bodyOf(resp)
  assertEqualInt(body.length, 1048576, "length")
  assertEqual(body.substring(0, 20), "01234567890123456789", "content start")
  joinJob(server)
  stopListener(l)
}

test "a request header reaches the handler over h2" {
  val l = startTlsServer()
  val server = serve(l, 1, { c -> echo(c) })
  val req = match withHeader(request(GET, urlFor(l, "/hdr")), "X-Lyric-Test", "abc") {
    case Ok(r) -> r
    case Err(e) -> panic(HttpError.message(e))
  }
  val resp = match await h2Client().send(req) {
    case Ok(r) -> r
    case Err(e) -> panic("send failed: " + HttpError.message(e))
  }
  assertVersion(resp, true, "header request")
  assertTrue(bodyOf(resp).contains("x=abc"), "the header arrived")
  joinJob(server)
  stopListener(l)
}

test "a redirect is followed over h2" {
  val l = startTlsServer()
  val server = serve(
    l,
    2,
    { c ->
      if requestPath(c) == "/start" {
        val h: Map[String, String] = newMap()
        h["Location"] = "/final"
        respondBytesWithHeaders(c, 302, "text/plain", [], h)
      } else {
        echo(c)
      }
    }
  )
  val resp = getOk(h2Client(), urlText(l, "/start"))
  assertEqualInt(resp.statusCode(), 200, "final status")
  assertVersion(resp, true, "redirected")
  assertTrue(bodyOf(resp).contains("path=/final"), "the redirect target answered")
  joinJob(server)
  stopListener(l)
}

test "sends from several threads each get their own response over h2" {
  val l = startTlsServer()
  val server = serve(l, 4, { c -> echo(c) })
  val client = h2Client()
  val sc = Task.makeScope()
  val results: List[String] = newList()
  var i = 0
  while i < 4 {
    val n = i
    Task.scopeSpawn(
      sc,
      { -> val resp = getOk(client, urlText(l, "/c" + n.toString())); val text = bodyOf(resp); results.add(text) }
    )
    i = i + 1
  }
  val _ = Task.awaitAll(sc)
  assertEqualInt(results.count, 4, "four responses")
  var seen = 0
  var k = 0
  while k < 4 {
    var j = 0
    while j < results.count {
      if results[j].contains("path=/c" + k.toString() + ";") {
        seen = seen + 1
      }
      j = j + 1
    }
    k = k + 1
  }
  assertEqualInt(seen, 4, "each path answered once")
  joinJob(server)
  stopListener(l)
}

// What a send under a token came to.
record Outcome {
  sent: Result[HttpResponse, HttpError]
  elapsedMs: Long
  tokenCancelled: Bool
}

val hangGuardMs: Int = 15000

func sendUnder(client: in HttpClient, url: in Url, src: in Task.CancellationTokenSource): Outcome {
  val tok = Task.sourceToken(src)
  val started = monotonicNanos()
  val work: () -> Result[HttpResponse, HttpError] = { -> await client.sendWithCancel(request(GET, url), tok) }
  val guarded = Task.runWithin(hangGuardMs, work)
  val elapsedMs = (monotonicNanos() - started) / 1000000i64
  match guarded {
    case Some(sent) -> Outcome(sent = sent, elapsedMs = elapsedMs, tokenCancelled = Task.isCancelled(tok))
    case None -> panic("the send was still waiting after " + elapsedMs.toString() + " ms: its token was not honoured")
  }
}

// A handler that answers after `delayMs`, long after the sends below give up.
func slowHandler(delayMs: in Int): (HttpContext) -> Unit {
  { c -> sleepMillis(delayMs); respondText(c, 200, "late") }
}

test "a deadline that passes while the response is awaited over h2 is HttpError.Timeout" {
  val l = startTlsServer()
  val server = serve(l, 1, slowHandler(2500))
  val o = sendUnder(h2Client(), urlFor(l, "/slow"), Task.makeCancelSourceTimeout(400))
  match o.sent {
    case Err(e) -> match e {
      case Timeout(_, _) -> assertTrue(true, "timeout")
      case _ -> assertTrue(false, "expected HttpError.Timeout, got " + HttpError.message(e))
    }
    case Ok(_) -> assertTrue(false, "expected a timeout, got a response")
  }
  assertTrue(o.tokenCancelled, "the token reads as cancelled once the send reports the timeout")
  assertTrue(o.elapsedMs >= 400i64, "not reported before the deadline (" + o.elapsedMs.toString() + " ms)")
  assertTrue(
    o.elapsedMs < 2400i64,
    "reported at the deadline, not when the server answered (" + o.elapsedMs.toString() + " ms)"
  )
  joinJob(server)
  stopListener(l)
}

test "cancelSource from another thread ends a send that waits for the response over h2" {
  val l = startTlsServer()
  val server = serve(l, 1, slowHandler(2500))
  val src = Task.makeCancelSource()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> sleepMillis(300); Task.cancelSource(src) })
  val o = sendUnder(h2Client(), urlFor(l, "/slow"), src)
  match o.sent {
    case Err(e) -> match e {
      case Timeout(_, _) -> assertTrue(false, "an explicit cancel is not a timeout")
      case _ -> assertTrue(true, "failed: " + HttpError.message(e))
    }
    case Ok(_) -> assertTrue(false, "expected the send to fail, got a response")
  }
  assertTrue(o.tokenCancelled, "the token is cancelled")
  assertTrue(
    o.elapsedMs >= 250i64 and o.elapsedMs < 2400i64,
    "ended when cancelled (" + o.elapsedMs.toString() + " ms)"
  )
  val _ = Task.awaitAll(sc)
  joinJob(server)
  stopListener(l)
}

test "a response inside the deadline is delivered over h2" {
  val l = startTlsServer()
  val server = serve(l, 1, { c -> echo(c) })
  val o = sendUnder(h2Client(), urlFor(l, "/fast"), Task.makeCancelSourceTimeout(5000))
  match o.sent {
    case Ok(resp) -> {
      assertVersion(resp, true, "within deadline")
      assertTrue(bodyOf(resp).contains("path=/fast"), "body")
    }
    case Err(e) -> assertTrue(false, "send failed: " + HttpError.message(e))
  }
  assertFalse(o.tokenCancelled, "the token is not cancelled")
  joinJob(server)
  stopListener(l)
}
