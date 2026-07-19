//! tests/jvm_server_smoke.l — real end-to-end HTTP round trip against the
//! Undertow-backed `Web.Kernel.Runtime` server on `--target jvm`.
//!
//! Mirrors `examples/rest_service.l`'s CI smoke-test shape (`.github/
//! workflows/ci.yml`'s "smoke examples/rest_service.l" step): start the
//! server as a background process, `curl` it, assert on the response, kill
//! it.  Unlike `dispatch_tests.l` (which exercises `Web.dispatch` directly,
//! no real socket), this file starts a *real* Undertow listener and drives
//! it with a real HTTP client, proving routing, status codes, headers, a
//! path parameter, and the request body round trip through actual
//! `io.undertow.server.HttpServerExchange` I/O — not just the pure
//! dispatch core.
//!
//! Endpoints:
//!   GET  /hello/{name}   -> 200 text, greets `name` (path param)
//!   GET  /echo-header    -> 200 JSON echoing the `X-Test` request header
//!   POST /echo-body      -> 200 text echoing the request body
//!   GET  /nope           -> 404 (no matching route)
//!
//! HTTPS/h2 self-check (issue #5881, TLS phase 2.2): before starting the
//! plaintext listener, `main` also starts a SECOND, TLS-terminated Undertow
//! listener on :8100 via `Web.serveTls` (on a background thread) and drives
//! it with an in-process `Std.Http` client that trusts the fixture cert as
//! its own CA.  It asserts a 200 response AND that the connection negotiated
//! HTTP/2 over ALPN (`HttpResponse.negotiatedVersion() == Http2`, the
//! phase-1.4 accessor), then prints a single `HTTPS-H2-SELFCHECK: PASS`
//! (or `FAIL ...`) line the CI step greps for.  The h2 assertion is done in
//! Lyric rather than by curl precisely because `negotiatedVersion()` is a
//! Lyric client accessor.  A SAN cert (IP:127.0.0.1) is used so the client's
//! hostname verification passes without an insecure escape hatch.
//!
//! Run:
//!   lyric run --target jvm tests/jvm_server_smoke.l &
//!   curl -s http://localhost:8099/hello/Ada
//!   curl -s -H 'X-Test: abc' http://localhost:8099/echo-header
//!   curl -s -X POST --data 'ping' http://localhost:8099/echo-body
//!   curl -s -o /dev/null -w '%{http_code}' http://localhost:8099/nope
//!
//! **Wired into CI**: the `lyric-web Undertow smoke on JVM` step of the
//! `compiler-self-tests-jvm` job runs `make maven-resolver`, restores this
//! manifest (a single-file jvm build reads the restored
//! `target/restore/jvm-classpath.txt`, and the bundle jar's manifest
//! `Class-Path` carries the restored Undertow jar paths so `java -jar`
//! needs no `-cp`), builds this file, and asserts all four endpoints.
//! Since #5571 the build resolves everything outside JVM codegen (workspace
//! deps with target-normalized features, `[project.packages]` bundling into
//! the single-file bundle), and the same command on `--target dotnet`
//! compiles and serves identically.  The JVM codegen blockers this header
//! used to document are fixed:
//!   - #5610 — an impl-method parameter typed with another package's record
//!     registered under the declaring file's own package (`req.body` here
//!     panicked with receiver `'Web/JvmServerSmoke/Request' has no known
//!     field or member 'body'`); instance-method parameter slots now resolve
//!     through the extern/imported-type seed, in lockstep with descriptors.
//!     This smoke is also #5610's regression pin — a two-package bundled
//!     compile with a cross-package impl param is not expressible in a
//!     single-file self-test.
//!   - #5444 — `self.mws[self.idx]` (a record FIELD of `slice[Middleware]`)
//!     erased its element to `Object`, so `mw.wrap(req, next)` fell through
//!     to auto-FFI on `java.lang.Object`; field elements now narrow via the
//!     `elem:<class>#<field>` registry (single-file regression cases live in
//!     `lyric-compiler/jvm/erased_element_checkcast_jvm_self_test.l` §6).
//!   - #5458 — a generic `extern type` alias (`JvmConcurrentDict[K, V]`)
//!     erased to `Object`, so `dict.get(key)` had no receiver class for
//!     auto-FFI.
//! #5443's general `[project.packages]` alias-collision bug remains open;
//! this library works around it via the `JvmConcurrentDict` rename (see
//! `_kernel/jvm/web_kernel.l`).
package Web.JvmServerSmoke

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Tls
import Std.Http
import Web

record HelloHandler {
}

impl Web.Handler for HelloHandler {
  func handle(req: in Web.Request): Web.Response {
    match Web.pathParam(req, "name") {
      case Some(name) -> Web.text(200, "Hello, " + name + "!")
      case None -> Web.errorResponse(Web.badRequest("missing name"))
    }
  }
}

record EchoHeaderHandler {
}

impl Web.Handler for EchoHeaderHandler {
  func handle(req: in Web.Request): Web.Response {
    val value = match Web.header(req, "X-Test") { case Some(v) -> v; case None -> "" }
    Web.json(200, "{\"xTest\":\"" + value + "\"}")
  }
}

record EchoBodyHandler {
}

impl Web.Handler for EchoBodyHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, req.body)
  }
}

extern type JThread = "java.lang.Thread"

// Self-signed RSA-2048 cert with subjectAltName IP:127.0.0.1 + DNS:localhost,
// so the in-process Std.Http client's hostname verification passes when it
// connects to https://127.0.0.1:8100. Matching unencrypted PKCS8 key below.
// Fixtures are test-only and carry no secret value.
val httpsCertPem = """-----BEGIN CERTIFICATE-----
MIIDNTCCAh2gAwIBAgIUb4NMb9lelfz9FhkutEWaItQgtmgwDQYJKoZIhvcNAQEL
BQAwHDEaMBgGA1UEAwwRbHlyaWMtdGVzdC1zZXJ2ZXIwHhcNMjYwNzE4MDczMDA2
WhcNMzYwNzE1MDczMDA2WjAcMRowGAYDVQQDDBFseXJpYy10ZXN0LXNlcnZlcjCC
ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALlQ6kMPMzH5HawqSRL83fUc
8bIbxmEnu9Mr4sUYq7QZhizddj7slYwXoOsLkU/LFbGD39uwpNrpqsAZmvTs9BBa
NAQQNxJAMOIPAxI7HULQXrb+z2FDKkwhXR3Rp9YoHjgaNpwaCuzbI2LxtnJAiVcp
AJ5moTcz5ALgZyyQ2D/Z/IvJPQZnEAF0GnVM+JG/yg+3dqN+9Blu9JaZWgK6IfG3
7pEVvmYPpdNkc+1pWCDRG26MqNezo3JviJHlyfnnGhkeJLIxt3N4eUoYwf/KA8jV
2I9zCgcQGGPljAJuKe1cWEgSaH7XZAq+5eEQumx7DaYvdNtXz4NTnVxfvGXJ6fMC
AwEAAaNvMG0wHQYDVR0OBBYEFL9/OZMVlv9mWuYIUpF4icpjcSB1MB8GA1UdIwQY
MBaAFL9/OZMVlv9mWuYIUpF4icpjcSB1MA8GA1UdEwEB/wQFMAMBAf8wGgYDVR0R
BBMwEYcEfwAAAYIJbG9jYWxob3N0MA0GCSqGSIb3DQEBCwUAA4IBAQA/1GMpM+17
ITrUjDRYRWFMvpSNMDzrKifG2pZbwRWpjmVMQlJf3OVif/Qlvb8mPsxWArlQGRrH
OsHdwa9JUzpRoptNVQf63d8SFz4VHcMIF3h/9Iq88LjXMV1MyiObVZLLOAiiSW+j
piF0DjxFPTuCe5WB5VKUUwOtEEN9xIg5W1LNgWK0dvKwAScUiqG1qVPk9WD6IlYW
lbcCkesNrKyWmR4OYe2Cg3ZuXo6Tbd54/kfOFF5/LTRpYZVt7w2pzGX23y4/grrd
glYQptAz1EEgWcpiSkgIVZEBjIntcMrlPE6XDiRDkZovezHMBno47l0w3CgcYXSK
9pV5q75Q4+gt
-----END CERTIFICATE-----"""

val httpsKeyPem = """-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC5UOpDDzMx+R2s
KkkS/N31HPGyG8ZhJ7vTK+LFGKu0GYYs3XY+7JWMF6DrC5FPyxWxg9/bsKTa6arA
GZr07PQQWjQEEDcSQDDiDwMSOx1C0F62/s9hQypMIV0d0afWKB44GjacGgrs2yNi
8bZyQIlXKQCeZqE3M+QC4GcskNg/2fyLyT0GZxABdBp1TPiRv8oPt3ajfvQZbvSW
mVoCuiHxt+6RFb5mD6XTZHPtaVgg0RtujKjXs6Nyb4iR5cn55xoZHiSyMbdzeHlK
GMH/ygPI1diPcwoHEBhj5YwCbintXFhIEmh+12QKvuXhELpsew2mL3TbV8+DU51c
X7xlyenzAgMBAAECggEAB3+6uxP2YmNOTBU598a7xJtzPF3bXTsaYqU3+/nPmO4f
e9lKW6l/M7gRDvHc43m4WwKXIHC5exJRkox2tMqR5ceAq1lsoRRv5fXtjeNOf9Gm
w4j0I19warw+5GIDhKsC7gpBg3eaUZNcjzhwxZbO9/P0znQgufcjluo1wpvp5EuA
Q+oQBGjIEpaeMeYE7E/iZbddWHh5g4ESa31CMmDMjWkEEnZC4SaSLs/kKAQ+P36N
JgEpqoxhsOnoSEtsU8r3oPbC1+mBZXWNF+DJFvN/h9V0rVnnPjoPFpmyrGUNFeRB
rOUkzoIEVyqbPGjmUzsxs23Eg82sBo77sYEy7aTroQKBgQDjQQO7jSNgOqzk0/5V
GAU/uZF5je3zk+dlwD00BKhHNdm1P+F1O82m/x4BPgYwo933ZmwCjLS5q2ybkI2P
m49sfSx8UZCQuUMUiCX989UKDp1UBqzw0WquF9Uyse1g457go7VOly3FoGGO4iWY
RM5u61vu3o1OdLDVdhszl0XThQKBgQDQwdvoVIFrflA1MbJfSu4E+CZ3HX/SMFUt
GAgyYiw2zd1O/ZOHY0OasI01TOMg8wbFYLZ/UoVC2M/Xjk7mp8YqVXBTLBU/igty
IkxAykJYx0D2jlELrsNn6q9PEr/3eZYf4Xw2gv9zDi7F6IKds7DHBQNofYuVHQSj
jogQcqIVFwKBgQCfkg1O6oHGlizE2N6jXaSB5Ilzsuc8u8QlvGC9X+/RYMyn6l0j
doSnGEg3UxgBm27Gw1JgT/Cu1uICMfRUvERvR02vVY6PMKcbiaYztb0HvM9YKv/Q
cRvZdr6rRCiMeggbcJhkwN7RABbAv6bqTpYtaHI7PmY2itWIbdAX38aWCQKBgQC3
3shO7n+/qlYDRG6TuG/FOLzIldcLzz52pYAywH2pF9IhzP+wdCILkg4OMFatouEH
4JNdudVed5E5j0K3rnbAuthgqadde71xHfyD5KJjh70UbW29GIVMdk1LHHyxAQrV
scmySdeuA4P3FUBWnvrJkQTbeBkFkbWQSe5WbmGMqQKBgBkqMpYI7ee8fxtyZk9S
3K4yzZ3/tw97kXSwTbFm61LXWm1BhOCBawKZ5Cz3uUdLHFgZHxlp40DmooELd8pt
hYdhFWFd5WL7G9O4auVFYU6cSdrQ57iEjyhk9iT/xuPgFC5YIMiJY7pBvyBOBcU1
4A8NKn86cmQezL3EpOkMqP2Q
-----END PRIVATE KEY-----"""

// A second router for the TLS listener (same greet handler as the plaintext
// one; a fresh Router keeps the two servers independent).
func httpsRouter(): Web.Router {
  var r = Web.create()
  r = Web.addGet(r, "/hello/{name}", HelloHandler())
  r
}

// Start the HTTPS listener on a background thread — Web.serveTls blocks
// forever once bound, so it cannot run on the main thread (which goes on to
// run the in-process client and then the plaintext server).
func startHttpsServer(tls: in Std.Tls.TlsServerConfig): Unit {
  val r = httpsRouter()
  val t = JThread.new(
    { ->
      match Web.serveTls(r, "127.0.0.1", 8100, tls) {
        case Ok(_) -> ()
        case Err(e) -> Console.println("HTTPS-H2-SELFCHECK: FAIL serveTls: " + Web.ServeTlsError.message(e))
      };
      ()
    }
  )
  t.start()
}

// Confirm mTLS configs are rejected with a typed error (no listener bound):
// requireClientCert = true must return Err(ServerTlsUnsupported) naming the
// tracking issue, never silently start a plaintext-auth listener (#6040).
// serveTls returns this immediately — it rejects mTLS before binding — so
// this runs on the main thread with no port actually opened.
func runMtlsRejectionCheck(): Unit {
  val id = match Identity.fromPem(httpsCertPem, httpsKeyPem) {
    case Ok(i) -> i
    case Err(e) -> {
      Console.println("MTLS-REJECT-SELFCHECK: FAIL identity load: " + TlsError.message(e))
      return
    }
  }
  val mtls = TlsServerConfig(identity = id, minVersion = Tls12, clientCa = None, requireClientCert = true)
  match Web.serveTls(httpsRouter(), "127.0.0.1", 8101, mtls) {
    case Ok(_) -> Console.println("MTLS-REJECT-SELFCHECK: FAIL mTLS config was not rejected")
    case Err(e) -> {
      val msg = Web.ServeTlsError.message(e)
      if msg.contains("mutual TLS") or msg.contains("6017") {
        Console.println("MTLS-REJECT-SELFCHECK: PASS mTLS rejected with a typed error")
      } else {
        Console.println("MTLS-REJECT-SELFCHECK: FAIL unexpected message: " + msg)
      }
    }
  }
}

// Start a real TLS Undertow listener, then GET it with an h2-capable client
// that trusts the fixture cert, asserting status 200 AND h2 negotiation.
//
// The listener binds asynchronously on its own thread, so instead of a single
// fixed `sleep` (a bind race that flaked under CI scheduling jitter, #6028),
// the client GET is retried in a BOUNDED poll loop: the request fails fast
// with a connection error until the socket is accepting, and each retry waits
// a short interval, up to a total budget.  A genuinely-broken listener still
// fails fast (the budget expires in a few seconds); a slow-to-bind one is
// tolerated.  The FIRST successful response (Ok) is evaluated and ends the
// loop — a wrong status / non-h2 / wrong body is reported as FAIL, not retried.
func runHttpsH2SelfCheck(): Unit {
  val id = match Identity.fromPem(httpsCertPem, httpsKeyPem) {
    case Ok(i) -> i
    case Err(e) -> {
      Console.println("HTTPS-H2-SELFCHECK: FAIL identity load: " + TlsError.message(e))
      return
    }
  }
  val tls = TlsServerConfig(identity = id, minVersion = Tls12, clientCa = None, requireClientCert = false)
  startHttpsServer(tls)

  val caCert = match Certificate.fromPem(httpsCertPem) {
    case Ok(c) -> c
    case Err(e) -> {
      Console.println("HTTPS-H2-SELFCHECK: FAIL ca load: " + TlsError.message(e))
      return
    }
  }
  val client = HttpClientBuilder.new().withCaCertificate(caCert).build()

  var attempt = 0
  var reported = false
  while attempt < 40 and not reported {
    JThread.sleep(150i64)
    match await client.get("https://127.0.0.1:8100/hello/Ada") {
      case Ok(resp) -> {
        val st = HttpResponse.statusCode(resp)
        val ver = HttpResponse.negotiatedVersion(resp)
        val isH2 = match ver { case Http2 -> true; case Http11 -> false; case Http3 -> false }
        val body = match await HttpResponse.bodyText(resp) { case Ok(b) -> b; case Err(_) -> "" }
        if st == 200 and isH2 and body == "Hello, Ada!" {
          Console.println("HTTPS-H2-SELFCHECK: PASS status=200 negotiated=h2 body=Hello,Ada")
        } else {
          val vs = match ver { case Http2 -> "h2"; case Http11 -> "http/1.1"; case Http3 -> "h3" }
          Console.println("HTTPS-H2-SELFCHECK: FAIL status=" + st.toString() + " negotiated=" + vs + " body=" + body)
        }
        reported = true
      }
      case Err(_) -> {
        attempt = attempt + 1
      }
    }
  }
  if not reported {
    Console.println(
      "HTTPS-H2-SELFCHECK: FAIL listener did not accept a connection within budget (" + attempt.toString() + " attempts)"
    )
  }
}

func main(): Unit {
  runMtlsRejectionCheck()
  runHttpsH2SelfCheck()
  var router = Web.create()
  router = Web.addGet(router, "/hello/{name}", HelloHandler())
  router = Web.addGet(router, "/echo-header", EchoHeaderHandler())
  router = Web.addPost(router, "/echo-body", EchoBodyHandler())
  Web.serve(router, "0.0.0.0", 8099)
}
