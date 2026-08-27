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
//! mTLS self-check (issue #6017, TLS phase 2.3): a THIRD listener on :8102
//! is started with `TlsServerConfig.clientCa`/`requireClientCert` set,
//! proving the Undertow client-CA `TrustManager` + XNIO
//! `SSL_CLIENT_AUTH_MODE` wiring end to end — not just that a config is
//! accepted at the API surface. Two in-process `Std.Http` clients drive it:
//! one presenting `mtlsClientCertPem` (signed by `mtlsCaCertPem`, the
//! configured `clientCa`) must connect and get a 200
//! (`MTLS-ACCEPT-SELFCHECK: PASS`); one presenting `mtlsUnrelatedCertPem`
//! (a self-signed cert NOT signed by that CA) must fail the TLS handshake
//! (`MTLS-REJECT-SELFCHECK: PASS`). A separate, up-front check
//! (`MTLS-MISCONFIG-SELFCHECK`) confirms `requireClientCert = true` with no
//! `clientCa` is still rejected with a typed `ServerTlsUnsupported` before
//! any listener binds (#6040) — `Web.serveTls`'s own config-validation
//! guard, unchanged by #6017.
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
import Web.TlsTestFixtures as TlsFixtures

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

// mTLS fixtures (issue #6017): a self-signed client-CA, a client cert/key
// PAIR signed by that CA (the "trusted" client), and an UNRELATED
// self-signed cert/key with no relation to the CA (the "untrusted" client).
// Generated with `openssl req -x509`/`openssl x509 -req` + `openssl pkcs8
// -topk8 -nocrypt` (Std.Tls only accepts unencrypted PKCS8 keys). Test-only
// fixtures, carry no secret value.
val mtlsCaCertPem = """-----BEGIN CERTIFICATE-----
MIIDHzCCAgegAwIBAgIUPZ8/KrpaL5hQXenqUCKkIuW9tE0wDQYJKoZIhvcNAQEL
BQAwHzEdMBsGA1UEAwwUbHlyaWMtdGVzdC1jbGllbnQtY2EwHhcNMjYwODI2MjM1
OTIyWhcNMzYwODIzMjM1OTIyWjAfMR0wGwYDVQQDDBRseXJpYy10ZXN0LWNsaWVu
dC1jYTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAOLo9zG3SpiHwhN/
RdNK1cq1jSP0/Mih0YfggzDVEuN4M5W2ykDcUrY1QY5qL+jj9JnGJTP72e8dezOS
DTVPVezqmEJcAWV0t6kRjOGGg4StAdvS01jUBLIqhBPcabUiGqEaqWLkxFqOQwzP
bTZfRv4QVxGEcyX9qNdx9FM1NlOIL5ip468hLY+jr0303SItAzaU1DEoDyyia3pK
A4AJMahV5c0sCF0I3GlcSSXtPtbAhzRbkWtyvWJ3uDr8jDzRahg8etue9cJ7VwQk
FNFaTJ+w5vLBNZ2IycjkS6rz2nOUl4Eo5SNGNWbOODuzIUkQiPJpnoROUizkNzBf
E0px+tcCAwEAAaNTMFEwHQYDVR0OBBYEFEJISk7V1khWCGQ/YFUcAUpgoJ89MB8G
A1UdIwQYMBaAFEJISk7V1khWCGQ/YFUcAUpgoJ89MA8GA1UdEwEB/wQFMAMBAf8w
DQYJKoZIhvcNAQELBQADggEBABWLQKx7vt324aMbKwBu1Ae4PsUeGvz5zy1xrTZc
3b5Eeq+lf9If9t77oSX83nbDu6kNOXkcG7bnF8KZgEVr6NS3o5gj0FRzoU5wXxNI
tpS9s/GFQNf6Hv+anNhTprw9YFdD8tKggVJNCnnjSCb4jlTisZO57x7IU9FuEiMl
5KdG6fszr4s2RWpe+Zp648VjDrG0Hh55Jx7RbahjQu38Xt+lERRgdMcvf/JrrWwn
tOGV9UhXr9lZmcLMSL0LVpI3hnUgaBgeYS6jz52EkAXIJw/rkb1Y9gj7xdNQ+b9N
7uUIB07UEMCFW4KKso3d+qHhTyejcn3Ajoi6qrh9B3NrQs4=
-----END CERTIFICATE-----"""

val mtlsClientCertPem = """-----BEGIN CERTIFICATE-----
MIICwjCCAaoCFE32d6edVAwNlUv66Pq5wbOyUt2sMA0GCSqGSIb3DQEBCwUAMB8x
HTAbBgNVBAMMFGx5cmljLXRlc3QtY2xpZW50LWNhMB4XDTI2MDgyNjIzNTkzN1oX
DTM2MDgyMzIzNTkzN1owHDEaMBgGA1UEAwwRbHlyaWMtdGVzdC1jbGllbnQwggEi
MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDDuMZI8ouhPg32svk9tLF4emR/
iu1O6BV/6BOHIudMfH2A+yuozAJZ2c5d79qFu/GMH9qlU6aGDd9kcZyKzcSPCx7q
jskIOQTtvcZItYszHzi+6l3jFHLLLml/5YN1vblp4xb4ptpidz5l2qZQCDxmyxXJ
ASz0vCquXHtKR6whcq7tc7DZEwvLunqA9CuOVTzcRKBSVNLuql7xaDiPCSlYapQk
krcJv0DCUyEi+1nw2DkizTTrypPpexyLWo+LbY8/GxiRRl3ydv/41Je+gPTRfoXh
erp6MauyFZRYOyt3qlScUuHA/vuVrYxPYhmlrTLdkGTj87JdFkJDZsBi8k79AgMB
AAEwDQYJKoZIhvcNAQELBQADggEBAJxHqQuaR+zT7P/vd+njc+/KtDfW9Y8FaOp0
6vT865BMIZWzs1BPV+YFVAKwshVcxbOw9rxDzXV8KZmz51cBakfcaBZXZSme4IBL
drqzxJ1MzHdo6tz2rhPjmFo0U7tYC6QaZZaD0jFllldcS8ZyTf+/zFM8r2mFv9PK
ctNeO/ReNkjpJzV9bAZ+J+hBzwYihqnC6ex9KXV658BynwZmeFE1U0aoVPdLFhi+
kl4t2+QB/R0c+r8VYwWkRIZ3R4yKc7iFR0w7bbpNKZC4FuHKD0b9FmV89lsrU4rA
6J0rS303yXQEgVzP3f7FHE+K1xRYxTpBdDJzlHGNlbLayMx9leA=
-----END CERTIFICATE-----"""

val mtlsClientKeyPem = """-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDDuMZI8ouhPg32
svk9tLF4emR/iu1O6BV/6BOHIudMfH2A+yuozAJZ2c5d79qFu/GMH9qlU6aGDd9k
cZyKzcSPCx7qjskIOQTtvcZItYszHzi+6l3jFHLLLml/5YN1vblp4xb4ptpidz5l
2qZQCDxmyxXJASz0vCquXHtKR6whcq7tc7DZEwvLunqA9CuOVTzcRKBSVNLuql7x
aDiPCSlYapQkkrcJv0DCUyEi+1nw2DkizTTrypPpexyLWo+LbY8/GxiRRl3ydv/4
1Je+gPTRfoXherp6MauyFZRYOyt3qlScUuHA/vuVrYxPYhmlrTLdkGTj87JdFkJD
ZsBi8k79AgMBAAECggEAIHRdUkSrPrDpjoTzAMvGZJyhruc8np8Bdv+RbWaDmufx
xReL5SZJ0C27zfvd7TB9x1Ho5w1N9GC3MGgJIJh/sDCUjynferY/Hk/KYiLTKEZU
bzlcbtvkhSihueGMa6kVkSdk7Gp5QBFXOXszpNsYw6WIFpf+pRPRXVmx4AlZKQUZ
htNGWXIZ0ALbygv3tbxQLo5Ab5wlhJ42T4xCx1cDmzpucCR2KFrYrZNKzhGTtx15
WMAtmRE2v3abwC952BbDqwQPeCeK+Qccd2h0K57IQMs43K/0VXHpH7zLeRmUVm02
zdvP7X1XO6MCaQ2uQe7Op6eCYOi1TLSeow8MAA5riQKBgQDzAhJ26g4YW8FjuCrr
ZqU7jqbF5CatxahJMhUkIZSsfUHCS7PigK4OPJ1kCEi7vyfCaoEacFmWiG1OAkr1
jsZl0IyQNhid0bp8DqprZ4N9AcFvt/60IkZBuScEmQK76pXSZrfiJ61+ukp9dBJH
x8JKB5tsJY3BpF6fLmbSlvDvfwKBgQDOL4TJADyUB5Gp2hUkCQARoZQj4kU0TA0m
hoX8fM2iyueDJ189Q/2W5VnzyXL07gWSUr9But5gWVerCkPNghSMwK6rHvmZu4S+
ny9pqhOBJmSdfYgf6K2uf+oatA+mB7I3WhadMeO+MkJEC+pOWa0FC8XHV9JkHeNT
r/bLmQi/gwKBgHnW8SEUKysFXko8PbC3T2M0G+Qeh1IbR0wjwzvRZnSxfLYJNND9
CcfzlkpgaO9RYYL12XNDH3f9QSiat7C0/D5yOPfZV7BRRnoK9GFTjjawGaeFDjyM
7sLnLWv9t8Q2UxYiEFJg6HkguFZ8SuoYew6ZD9FCZvfPDO4s2rr9mSHLAoGASgvm
tAjRuJe/SDB5xyc0TyCoAvsPv2hQkLVfCP4JG52i5wcMvQPd3oMfet2t2yhf99yf
swtZMWDkixh0oSlGGAZatDm7ieo+Efc5H8lkl80h9S1P5aW6OiDWAiEIPagl6JsB
5BI2p+eExMtCqkCqUlWYAa8Yb7wMF9Hp39Rlv+ECgYBi4Pfa7CDzUrclW5WZzKcz
RJHHptZ/UwIANVDtT5BJ3/0TEjDLrYf+PM620Yg+7EGMl2odmkS6dBXWIKS8tH+f
wfeF7WfqvIoD2dY3U0giXAuP/V3C6Q/bSRZMYSUbiiQs9SmYByY7QWqIvY6mJEFr
BxTRB249L+Dfyn0Nm5wnIg==
-----END PRIVATE KEY-----"""

val mtlsUnrelatedCertPem = """-----BEGIN CERTIFICATE-----
MIIDLTCCAhWgAwIBAgIUJoyT+e5GdcIyV76uO1LRtFxZ0XowDQYJKoZIhvcNAQEL
BQAwJjEkMCIGA1UEAwwbbHlyaWMtdGVzdC11bnJlbGF0ZWQtY2xpZW50MB4XDTI2
MDgyNjIzNTk1MloXDTM2MDgyMzIzNTk1MlowJjEkMCIGA1UEAwwbbHlyaWMtdGVz
dC11bnJlbGF0ZWQtY2xpZW50MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
AQEAtCXzeD9V5zxD/hPGTIEVQOpgFSeD+tuAP4YPUM7fBU0AVtDPfoA1MyVrZVre
IOW6NXCu5nLU8MGHUTT1R7ArZMZfSXN09Ox41L/TTRT8er4VPjiBRDecaMeXrh9O
J36orakwRa6sS3e6sb0VKl2WSGJSqqtrwZzr1rojeW4SKgYW2w3Cv2VvTcLQKXnb
M0gBXXalPRsGy9Xs7uCWYUawcmHD7XMz0FMtTN0FB3mMWWOFm2ShwbkppBqTFo2R
MOWORpaz69T3kkOLWaQtWkyH4zr7+I1Ln3xNYvdC/URht3lZkqBc03cH53FS7yxb
sr45C8Ts+c60CMWT7NCO8q/k9QIDAQABo1MwUTAdBgNVHQ4EFgQUs1QjyE0eWuTb
aT82JUFMYRnYBu0wHwYDVR0jBBgwFoAUs1QjyE0eWuTbaT82JUFMYRnYBu0wDwYD
VR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAEI7dAVhi0mMZ+AxNXREd
rDi0EoCx9JtHDMgPLmNZDm7LivIrDcZ2U2hLeIbSWhrl1aiiFaJhLevo48mMHqpK
83pH/qYgem2HvR6r0IxsgqviSM6wdQwIIREq12BHI1OpjUkuimVTh21yIMn2cM4j
yMnz2erRxPqo39eVwfMA2gEJoQKPdt38lJFfuwYmbjaBFwpsAkj1/Dlb2BkknmA+
BZMPIw1d0C3DlOKdsrTPWVOa1DL6FBvGcvV0wpnq/0+l6nB2CNZtUB7iZNdDkOmN
3hJnn5pZdXMycrOtpWCVZINuMwri3iKVYbAQJhGsy1vWnrmPCdEq8DbU0Kj8wMPy
eg==
-----END CERTIFICATE-----"""

val mtlsUnrelatedKeyPem = """-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC0JfN4P1XnPEP+
E8ZMgRVA6mAVJ4P624A/hg9Qzt8FTQBW0M9+gDUzJWtlWt4g5bo1cK7mctTwwYdR
NPVHsCtkxl9Jc3T07HjUv9NNFPx6vhU+OIFEN5xox5euH04nfqitqTBFrqxLd7qx
vRUqXZZIYlKqq2vBnOvWuiN5bhIqBhbbDcK/ZW9NwtApedszSAFddqU9GwbL1ezu
4JZhRrByYcPtczPQUy1M3QUHeYxZY4WbZKHBuSmkGpMWjZEw5Y5GlrPr1PeSQ4tZ
pC1aTIfjOvv4jUuffE1i90L9RGG3eVmSoFzTdwfncVLvLFuyvjkLxOz5zrQIxZPs
0I7yr+T1AgMBAAECggEABJ/xy6Yg0xSV2wy620Vw+LZ4FUdkHjIyAohd1cpU6R4f
FgYllt7gkIm3ByK7T6G6nfsZnl8XmVSTdXHF9z7f36YS3Mcst5ESOykaGgTMfVBN
/0CfKZrBUvD4lvpofMMF2tXqkgfWTx9X1ys635FBHMnihCLDMRFYty2y/JxDtblg
2uqjj4QUWnHz7rkmLpsicf4fiXWnKx/74aRuC+QjJevseYs4cfIJRcckeGC4kfNN
385KvUGBKyFi42LLyZq8nYRsfJIworVTGVqTOd0w08sUDKjHTtilUZ59cs0ZcCFM
YvAByyLg68kJ/Vr1q/J3HnUQmvvT8yxTcpVfjeRTKQKBgQDlwZOjMdBtuJY/NDOt
mdMcMBu0jeWI53gIuHkGIa9SE55ZFSxMtydYY/XNv3a9tkc7MM33qqUsddEc7FJw
0Iqsn7cW7/yjwjbzYe3PaEdBQEF+I2uSfP3MWi+Uxp/T1XddhW8JoB6bFVmG6IyH
QZT4UFAjCK/wpi03MajjvWxM/QKBgQDIucNBTduPL7tTOAzZt8Ww9rZElzT05mS6
pnRkW3Ee2kDSvlJGH+6vspeBz08EJR5FIh+yM795GK5Hmf3qgb3HmTuKdIicth3g
OCQrgZKDDt5Hg62EqfEs/Zmln3wBis+n9z01dRoOrZtQ55Z46aG7+W2RmSzSjvQW
CuQxCDf1WQKBgQDc+k7+YjX+oc/YYGPn75Ath1POV7/R6hb4BD1amWFfhsEBGy0t
Z+cuy42p4yHYm41tL6aaM4WD+pkywVUVbm5CU6csJ4wNEQn7ElBA8SG/b4bORFD9
ZrxQJNmotVUZ0DFrQKAoWNm2/VTLPbWTjY8zOUOqPnvB8IKCmH/A8vpMHQKBgG++
4xHHC3VyaEITESxf38H+B0i2OTghz3AN3PxF3/sCHFZ2uAzsGBBeR3Rv+hhfpbNt
JOIrZuw+rj+UXkSgiAvHpdsVtzwvMwCxoIlL8EngDCUaDI6voWGfqVsIJ5wgMCzd
Ook5MRF82tu2ohGcV3rziGknMkniZcajt5gIcEa5AoGARWD+wCyWwV+6znLU1XZ5
cESJOM5HZvFRY7ZdBm1WKakVPIy0CukUQ+0JIMlslaipzOPDki1B9lr9DHbfddcF
azPubU36Me5vAkCZFQrBOHQ+FAJ+TNDXMWnm8/6QAWW+T+c6E8jz3UVfl5cDlov3
AZXp8NkckUZ7exc3rOqWVZU=
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

// Start the mTLS-configured HTTPS listener (issue #6017) on a background
// thread, bound to :8102 — separate from the h2 listener's :8100 and the
// misconfig check's never-bound :8101, so all three self-checks coexist.
func startMtlsServer(tls: in Std.Tls.TlsServerConfig): Unit {
  val r = httpsRouter()
  val t = JThread.new(
    { ->
      match Web.serveTls(r, "127.0.0.1", 8102, tls) {
        case Ok(_) -> ()
        case Err(e) -> Console.println("MTLS-ACCEPT-SELFCHECK: FAIL serveTls: " + Web.ServeTlsError.message(e))
      };
      ()
    }
  )
  t.start()
}

// Confirm the one remaining up-front rejection still works (no listener
// bound): requireClientCert = true with NO clientCa configured is a genuine
// misconfiguration (there is no CA to pin trust to) and must return
// Err(ServerTlsUnsupported), never silently start a plaintext-auth listener
// (#6040) or crash. This is unrelated to #6017's TLS-layer accept/reject
// (`runMtlsAcceptRejectSelfCheck` below) — mirrors the dotnet kernel's
// `InvalidConfig` guard (`_kernel/http_server.l`). serveTls returns this
// immediately — it rejects the misconfiguration before binding — so this
// runs on the main thread with no port actually opened.
func runMtlsMisconfigCheck(): Unit {
  val id = match Identity.fromPem(TlsFixtures.certPem, TlsFixtures.keyPem) {
    case Ok(i) -> i
    case Err(e) -> {
      Console.println("MTLS-MISCONFIG-SELFCHECK: FAIL identity load: " + TlsError.message(e))
      return
    }
  }
  val mtls = TlsServerConfig(identity = id, minVersion = Tls12, clientCa = None, requireClientCert = true)
  match Web.serveTls(httpsRouter(), "127.0.0.1", 8101, mtls) {
    case Ok(_) -> Console.println("MTLS-MISCONFIG-SELFCHECK: FAIL misconfigured mTLS was not rejected")
    case Err(e) -> {
      val msg = Web.ServeTlsError.message(e)
      if msg.contains("requireClientCert") {
        Console.println("MTLS-MISCONFIG-SELFCHECK: PASS misconfiguration rejected with a typed error")
      } else {
        Console.println("MTLS-MISCONFIG-SELFCHECK: FAIL unexpected message: " + msg)
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
  val id = match Identity.fromPem(TlsFixtures.certPem, TlsFixtures.keyPem) {
    case Ok(i) -> i
    case Err(e) -> {
      Console.println("HTTPS-H2-SELFCHECK: FAIL identity load: " + TlsError.message(e))
      return
    }
  }
  val tls = TlsServerConfig(identity = id, minVersion = Tls12, clientCa = None, requireClientCert = false)
  startHttpsServer(tls)

  val caCert = match Certificate.fromPem(TlsFixtures.certPem) {
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

// Real end-to-end mTLS accept/reject (issue #6017): a listener configured
// with `clientCa = mtlsCaCertPem` and `requireClientCert = true` must
// accept a client presenting `mtlsClientCertPem` (signed by that CA) and
// reject one presenting `mtlsUnrelatedCertPem` (an unrelated self-signed
// cert) — proving the Undertow client-CA `TrustManager` + XNIO
// `SSL_CLIENT_AUTH_MODE` wiring at the real TLS layer, not just that the
// config is accepted at the API surface.
//
// The accept leg runs first, in the same bounded poll loop as
// `runHttpsH2SelfCheck` (#6028) — it doubles as proof the listener actually
// bound. Only once a trusted-client connection has succeeded does the
// reject leg run (a single attempt, no retry): the listener is confirmed
// live at that point, so a failure there is a genuine TLS-layer rejection,
// not a bind race indistinguishable from one.
func runMtlsAcceptRejectSelfCheck(): Unit {
  val id = match Identity.fromPem(TlsFixtures.certPem, TlsFixtures.keyPem) {
    case Ok(i) -> i
    case Err(e) -> {
      Console.println("MTLS-ACCEPT-SELFCHECK: FAIL server identity load: " + TlsError.message(e))
      return
    }
  }
  val ca = match Certificate.fromPem(mtlsCaCertPem) {
    case Ok(c) -> c
    case Err(e) -> {
      Console.println("MTLS-ACCEPT-SELFCHECK: FAIL client-CA load: " + TlsError.message(e))
      return
    }
  }
  val tls = TlsServerConfig(identity = id, minVersion = Tls12, clientCa = Some(value = ca), requireClientCert = true)
  startMtlsServer(tls)

  val serverTrust = match Certificate.fromPem(TlsFixtures.certPem) {
    case Ok(c) -> c
    case Err(e) -> {
      Console.println("MTLS-ACCEPT-SELFCHECK: FAIL server-trust cert load: " + TlsError.message(e))
      return
    }
  }
  val trustedClientId = match Identity.fromPem(mtlsClientCertPem, mtlsClientKeyPem) {
    case Ok(i) -> i
    case Err(e) -> {
      Console.println("MTLS-ACCEPT-SELFCHECK: FAIL trusted client identity load: " + TlsError.message(e))
      return
    }
  }
  val acceptClient = HttpClientBuilder.new().withCaCertificate(serverTrust).withClientIdentity(trustedClientId).build()

  var attempt = 0
  var accepted = false
  while attempt < 40 and not accepted {
    JThread.sleep(150i64)
    match await acceptClient.get("https://127.0.0.1:8102/hello/Ada") {
      case Ok(resp) -> {
        val st = HttpResponse.statusCode(resp)
        val body = match await HttpResponse.bodyText(resp) { case Ok(b) -> b; case Err(_) -> "" }
        if st == 200 and body == "Hello, Ada!" {
          Console.println("MTLS-ACCEPT-SELFCHECK: PASS status=200 body=Hello,Ada")
        } else {
          Console.println("MTLS-ACCEPT-SELFCHECK: FAIL status=" + st.toString() + " body=" + body)
        }
        accepted = true
      }
      case Err(_) -> {
        attempt = attempt + 1
      }
    }
  }
  if not accepted {
    Console.println(
      "MTLS-ACCEPT-SELFCHECK: FAIL listener did not accept a trusted client within budget (" + attempt.toString() +
        " attempts)"
    )
    return
  }

  val unrelatedId = match Identity.fromPem(mtlsUnrelatedCertPem, mtlsUnrelatedKeyPem) {
    case Ok(i) -> i
    case Err(e) -> {
      Console.println("MTLS-REJECT-SELFCHECK: FAIL unrelated client identity load: " + TlsError.message(e))
      return
    }
  }
  val rejectClient = HttpClientBuilder.new().withCaCertificate(serverTrust).withClientIdentity(unrelatedId).build()
  match await rejectClient.get("https://127.0.0.1:8102/hello/Ada") {
    case Ok(_) -> Console.println("MTLS-REJECT-SELFCHECK: FAIL unrelated client cert was accepted")
    case Err(_) -> Console.println("MTLS-REJECT-SELFCHECK: PASS unrelated client cert rejected at the TLS layer")
  }
}

func main(): Unit {
  runMtlsMisconfigCheck()
  runHttpsH2SelfCheck()
  runMtlsAcceptRejectSelfCheck()
  var router = Web.create()
  router = Web.addGet(router, "/hello/{name}", HelloHandler())
  router = Web.addGet(router, "/echo-header", EchoHeaderHandler())
  router = Web.addPost(router, "/echo-body", EchoBodyHandler())
  Web.serve(router, "0.0.0.0", 8099)
}
