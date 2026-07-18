//! stdlib/tests/http_server_dotnet_tests.l — runtime tests for the dotnet
//! HTTP/1.1 server assembly `Std.HttpServer`
//! (docs/61-https-tls-http-versions.md §6.1/§6.2/§6.3, phase 3.3 of epic
//! #5874, issue #5884).
//!
//! dotnet-only: `Std.HttpServer` on `--target dotnet` is now built on the
//! `Std.TcpHost` (`System.Net.Sockets`/`SslStream`) transport + the sans-IO
//! `Std.HttpEngine`, replacing the retired `System.Net.HttpListener` server.
//! The JVM server is a separate kernel (`_kernel_jvm/http_server.l`) with its
//! own suite (`tls_server_jvm_tests.l`), so this suite runs only on
//! `--target dotnet`.
//!
//! Coverage: a plaintext GET round trip against the REAL Lyric HTTP client
//! (path/query/method observed by the handler), a POST whose body reaches the
//! handler, keep-alive reuse of one connection for two requests, a
//! concurrent-connection case (four simultaneous raw clients all served), a
//! full server-side TLS handshake + HTTP round trip against the real Lyric
//! HTTPS client, both mTLS outcomes (a client cert that chains to `clientCa`
//! is accepted; a client presenting no cert is rejected at the handshake and
//! the server keeps serving), the `startListenerTls` mTLS-misconfiguration
//! guard (`requireClientCert` with no `clientCa` → `InvalidConfig`), and — the
//! phase-4.4 h2 end-to-end (issue #5889) — HTTP/2 negotiation over ALPN driven
//! through the pure-Lyric `Std.HttpEngine.H2Conn` FSM: a GET and a POST each
//! asserting `HttpResponse.negotiatedVersion() == Http2` with the routed
//! request observed by the handler, plus two multiplexed streams on one h2
//! connection. Both directions of our own stack (the .NET-backed HTTPS client
//! and the pure-Lyric h2 server) verify each other; a `curl --http2` CI smoke
//! (`dotnet_h2_smoke.l`) is the independent implementation cross-check.
//!
//! Concurrency: the pull-model server needs its accept loop and the request
//! driver to run on separate OS threads (Lyric `spawn` is degenerate-
//! synchronous on `--target dotnet`, D119/D120), so the server's `nextContext`
//! puller runs on a `System.Threading.Tasks.Task`, exactly as
//! `tcp_host_tls_tests.l` runs its loopback server. Declaring those `extern`s
//! in a test file mirrors that suite — a documented test-only exception to the
//! `_kernel/`-only extern rule for driving the opposite side of a real
//! protocol. The raw-client helpers reuse `Std.TcpHost` directly.
//!
//! Fixtures: the same self-signed CA / server leaf (SAN localhost + 127.0.0.1)
//! / client leaf as `tcp_host_tls_tests.l`, embedded PEM, valid
//! 2026-07-18..2036-07-15.
@test_module
package Std.HttpServer.DotnetTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.String
import Std.Tls
import Std.TcpHost
import Std.HttpServer
import Std.Http
import Std.Testing
// Aliased to name `EngineLimits` for the maxBodyBytes-cap tests without pulling
// `Std.HttpEngine`'s `HttpVersion` cases into scope alongside `Std.Http`'s.
import Std.HttpEngine as Eng

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

val clientCertPem = """
-----BEGIN CERTIFICATE-----
MIICuzCCAaMCFC1kZ/YIfDTe+RFaZ+UIHxEueT3EMA0GCSqGSIb3DQEBCwUAMBgx
FjAUBgNVBAMMDWx5cmljLXRlc3QtY2EwHhcNMjYwNzE4MDc0MjMyWhcNMzYwNzE1
MDc0MjMyWjAcMRowGAYDVQQDDBFseXJpYy10ZXN0LWNsaWVudDCCASIwDQYJKoZI
hvcNAQEBBQADggEPADCCAQoCggEBANGf5N8qES33noFWxMoIUj/lMLR2Cvj8DBge
gog1e0VlPXVMcAtFl4+6rkbhEADG7EBMH+sSCXA0uLAoS/ZjZ7lwL+boRf8R84sH
sUiCeLcvz7Grqzusgu2z8xqfXPVnU5s0W1l6mOe6djBouWQPOb2jv+ENH6cz7Udn
9mTbGTw8tm30P2RJBSNd++ahcLeiEHH9yT2WIznlMbdjMeM1txkcp9rx9wOCkgYv
sDtqW0R8vJBU7eYvOg3rQhJYG+36pG4aSGN0hk5ToXr1KXUqBfG5bihkIXtRmyUz
RkdbAcHcNgpw6MWReqkKo5S3fyNbPkBfsdTiy8UX3bcAHObVC1cCAwEAATANBgkq
hkiG9w0BAQsFAAOCAQEAX/DpZQz7RRocRV2pdmlYTv1C94DMVMjFx7yhqwVUwq1o
C6wRQbF0hftejS96lp+yvGho8xqSiXNoMpvYrKJ6irs04CdvbPA5EKfBpGkX67C9
XMnnoy33NNHuHXWgFdaNcQu0RexClCNdrt7GhZhSdHMaFqShapxM6IRga7mAaLoH
aoSVJHUqcvSp6emabapa1mBQGDmQvChIlId8goTyT7jiMLEGHIkx6UU5lOGpoaNw
sKS14qcf1mfWrCj7x55Q+FZyBhZMNhYwTk3TgmcHyNF9iuuUYWrzYwMa6HIUCFOM
obXTzZgP3SUsl/eCQ4VUOxHGhgJk3QeWkU3Q/EpqbA==
-----END CERTIFICATE-----
"""

val clientKeyPem = """
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDRn+TfKhEt956B
VsTKCFI/5TC0dgr4/AwYHoKINXtFZT11THALRZePuq5G4RAAxuxATB/rEglwNLiw
KEv2Y2e5cC/m6EX/EfOLB7FIgni3L8+xq6s7rILts/Man1z1Z1ObNFtZepjnunYw
aLlkDzm9o7/hDR+nM+1HZ/Zk2xk8PLZt9D9kSQUjXfvmoXC3ohBx/ck9liM55TG3
YzHjNbcZHKfa8fcDgpIGL7A7altEfLyQVO3mLzoN60ISWBvt+qRuGkhjdIZOU6F6
9Sl1KgXxuW4oZCF7UZslM0ZHWwHB3DYKcOjFkXqpCqOUt38jWz5AX7HU4svFF923
ABzm1QtXAgMBAAECggEAZ6n8W5Yol8RYONsJh2W1Ew8K1nt3sqimbHkOEUDtfKRz
z6Gk2RYpvPTTQY8ERHYbGDLtJ+ksDLatzMOoyShgf5ZowfaEwv6EI3GC7PpEq0a0
Hcdo7yJBPz7ZzoUXye42rM6oDChyHEqcLxVi9QYIhm1Hswoz6JJn2YOimD63jI8O
bCUJvkj1RDnXo1Ps4ZFz9dCHPxwjSnPci86Xhoj6YTM8bu4P1Sckt9BOC02busi4
2esHJaltCZrUrWTV9WKGMR0JD1haLblKS9zFO9fxHadEXOdsue+LxbnorTlr4sM1
I9aXCn7v0GiuIM965YwOzzn29mXRtY6TQqEATJvmXQKBgQDuTuWwmONbfQ1yau5e
iWMK7877OH+mi+U33TpxEpTwMOmIbLSbx7fICylQ5/Kd83yhUlGDawUsNYNnIPlR
kBnW8RsoIdV8+9V9ClA5l3acDt3sCnAvnBq8CIcqoGbaneZh5u9YGuMJObut+v20
Fa619R1kmbMOhkHuqZ0F3neiJQKBgQDhL9uxjx5vDNJrh3blOVhwpLWHOoptmphS
izpomUzO5jpedW+FNOuXG6CjrbEh/zMYyNmB+ZX8vnJp83SawhiGZp8AsHKc2otB
H60HVjWUiR5nceiClc24MBwvwPzfV3/+TYG9ZcqKgtm0HlgCxaz4z9QNEL9QJohL
+TsdNnQYywKBgCPT7spvIfd2RJhIJVBHPYG+bhLs+pwSekK82vV3Ardd0y50kW6+
Rw4nR23ngV1n5vvmAWVNqLhtzzSpC3LMxGXBWADfnVYuEnm7HDacY/OwdILxSs6N
nKNacN/iv7Pse1+Ktb88Q5f2exX8Hzp87AhlMqcWSIpNewojq/ze5oOVAoGAJ60B
/V/lEdXlgTKl/S9EaNxsa34iA7u4WNrVGLbh9JZV9GymkIbJd59Th2NEEWRggV5q
DF+IULbRe998TQQjxBJys3FjUEWlQX0uRFupJxmdtMY6HD/+thQr8zICm+tTzt+j
G1bC//KcHwM1qI9hsZkUmJS50Ippe1FXXAdLH08CgYBO41JwRNJaZCoE3ybo3XKh
tbYCFT458nxl/ZrHZjr3kjUBZEimCluZAUlwIeEhQmzwug2Xf2VhK9yMWEKhuCde
NtEFaGPfi4wMI6uEgimdwdqxDiEFEZtjYcFOvClHVH9nAT7ZyYZzjOvpC+PJ1rPz
BYr/w9ucuC11rYllBCEkxQ==
-----END PRIVATE KEY-----
"""

// `Task.Run(Action)` runs the server's request-puller loop on a background
// thread; `spawn` is degenerate-synchronous on this target (module header).
extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWait(t: in Task): Unit = ()

@externStatic
@externTarget("System.Threading.Thread.Sleep")
func threadSleep(ms: in Int): Unit = ()

// Thread-safe accumulator for the concurrent-connections test: four background
// `Task.Run` clients record their outcome here, so it must not be a plain
// (non-thread-safe) `List`. `ConcurrentQueue` is the same primitive the server
// kernel uses for its pull queue; results are drained single-threaded after the
// clients join (#6079).
extern type ConcQueue[T] = "System.Collections.Concurrent.ConcurrentQueue`1"

@externTarget("System.Collections.Concurrent.ConcurrentQueue`1..ctor")
func newConcQueue[T](): ConcQueue[T] = ()

@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentQueue`1.Enqueue")
func concEnqueue[T](q: in ConcQueue[T], item: in T): Unit = ()

@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentQueue`1.TryDequeue")
func concTryDequeue[T](q: in ConcQueue[T], result: out T): Bool = ()

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

func clientIdentity(): Identity {
  match Identity.fromPem(clientCertPem, clientKeyPem) {
    case Ok(id) -> id
    case Err(e) -> panic("client identity load failed: " + TlsError.message(e))
  }
}

// The request-puller loop: serve exactly `n` requests, echoing the observed
// method/path/query/body so the client can assert them, then return.
func serveN(l: in HttpListener, n: in Int): Unit {
  var i = 0
  while i < n {
    val ctx = nextContext(l)
    val reply = "m=" + requestMethod(ctx) + ";path=" + requestPath(ctx) + ";q=" + requestQuery(ctx) + ";body=" +
      requestBody(ctx)
    respondText(ctx, 200, reply)
    i = i + 1
  }
}

// A small `EngineLimits` capping request bodies at `maxBodyBytes` bytes (other
// limits at their defaults) for the h2 body-cap tests.
func smallBodyLimits(maxBodyBytes: in Int): Eng.EngineLimits {
  Eng.EngineLimits(
    maxRequestLineLength = 8192,
    maxHeaderCount = 100,
    maxHeaderLineLength = 8192,
    maxTotalHeaderBytes = 65536,
    maxBodyBytes = maxBodyBytes
  )
}

// A deterministic ASCII string of exactly `n` bytes: the digit cycle 0-9 repeated.
func makeBody(n: in Int): String {
  var s = ""
  while s.length < n {
    s = s + "0123456789"
  }
  s.substring(0, n)
}

// Puller that serves one request with a large plaintext body, exercising the
// multi-frame DATA split + flow-control window pump on the send side.
func serveLargeBody(l: in HttpListener, body: in String): Unit {
  val ctx = nextContext(l)
  respondText(ctx, 200, body)
}

// Puller that serves one request as a chunked response of three chunks (buffered
// then flushed as one h2 response, #6107), exercising the h2 chunked path.
func serveChunked(l: in HttpListener): Unit {
  val ctx = nextContext(l)
  val headers: Map[String, String] = newMap()
  val s = beginChunkedResponse(ctx, 200, "text/plain; charset=utf-8", headers)
  val _1 = streamWriteChunk(s, encodeUtf8("chunk-A;"), 0, 8)
  val _2 = streamWriteChunk(s, encodeUtf8("chunk-B;"), 0, 8)
  val _3 = streamWriteChunk(s, encodeUtf8("chunk-C"), 0, 7)
  endChunkedResponse(ctx, s)
}

func joined(parts: in List[String]): String {
  var s = ""
  var i = 0
  while i < parts.count {
    s = s + parts[i]
    i = i + 1
  }
  s
}

// Read from a raw connection until `marker` appears (bounded).
func readInto(conn: in Conn, acc: in List[String], marker: in String): Bool {
  var tries = 0
  var done = false
  while tries < 400 and not done {
    val r = hostRead(conn, 4096)
    match r {
      case Ok(b) -> {
        if b.length == 0 {
          done = true
        }
        val dec = tryDecodeUtf8(b)
        match dec {
          case Some(s) -> acc.add(s)
          case None -> ()
        }
      }
      case Err(_) -> {
        done = true
      }
    }
    if joined(acc).contains(marker) {
      done = true
    }
    tries = tries + 1
  }
  joined(acc).contains(marker)
}

func dial(host: in String, port: in Int): Conn {
  val r = hostConnect(host, port)
  match r {
    case Ok(c) -> c
    case Err(e) -> panic("connect failed: " + TcpError.message(e))
  }
}

func rawRequest(host: in String, port: in Int, reqText: in String, marker: in String): String {
  val conn = dial(host, port)
  val _ = hostWrite(conn, encodeUtf8(reqText))
  val acc: List[String] = newList()
  val _ = readInto(conn, acc, marker)
  hostClose(conn)
  joined(acc)
}

// One concurrent raw client: GET /<tag>, record "ok:<tag>" on success. Writes
// to a thread-safe `ConcurrentQueue` since this runs on a background task
// alongside the other clients (#6079).
func concurrentClient(port: in Int, tag: in String, results: in ConcQueue[String]): Unit {
  val marker = "path=/" + tag
  val body = rawRequest("127.0.0.1", port, "GET /" + tag + " HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", marker)
  if body.contains(marker) {
    concEnqueue(results, "ok:" + tag)
  } else {
    concEnqueue(results, "bad:" + tag)
  }
}

// Drain a ConcurrentQueue[String] into a single-threaded joined string (called
// only after all producer tasks have joined).
func drainConcQueue(results: in ConcQueue[String]): String {
  var acc = ""
  var more = true
  while more {
    var item = ""
    if concTryDequeue(results, item) {
      acc = acc + item + ";"
    } else {
      more = false
    }
  }
  acc
}

test "plaintext GET round trip via the Lyric HTTP client" {
  val listener = startListener("http://127.0.0.1:19401/")
  val server = taskRun({ -> serveN(listener, 1) })
  threadSleep(100)
  val client = HttpClientBuilder.build(HttpClientBuilder.new())
  val resp = match await client.get("http://127.0.0.1:19401/hello?name=lyric") {
    case Ok(r) -> r
    case Err(e) -> panic("client GET failed: " + HttpError.message(e))
  }
  val body = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  taskWait(server)
  stopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "plaintext response is 200")
  assertTrue(body.contains("m=GET"), "method observed: " + body)
  assertTrue(body.contains("path=/hello"), "path observed: " + body)
  assertTrue(body.contains("q=name=lyric"), "query observed: " + body)
}

test "POST body reaches the handler" {
  val listener = startListener("http://127.0.0.1:19402/")
  val server = taskRun({ -> serveN(listener, 1) })
  threadSleep(100)
  val postResp = rawRequest(
    "127.0.0.1",
    19402,
    "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world",
    "body=hello world"
  )
  taskWait(server)
  stopListener(listener)
  assertTrue(postResp.contains("m=POST"), "method POST observed: " + postResp)
  assertTrue(postResp.contains("body=hello world"), "request body delivered: " + postResp)
}

test "keep-alive reuses one connection for two requests" {
  val listener = startListener("http://127.0.0.1:19403/")
  val server = taskRun({ -> serveN(listener, 2) })
  threadSleep(100)
  val conn = dial("127.0.0.1", 19403)
  val acc: List[String] = newList()
  val _ = hostWrite(conn, encodeUtf8("GET /first HTTP/1.1\r\nHost: x\r\n\r\n"))
  val got1 = readInto(conn, acc, "path=/first")
  val _ = hostWrite(conn, encodeUtf8("GET /second HTTP/1.1\r\nHost: x\r\n\r\n"))
  val got2 = readInto(conn, acc, "path=/second")
  hostClose(conn)
  taskWait(server)
  stopListener(listener)
  assertTrue(got1, "first response received on the connection")
  assertTrue(got2, "second response received on the SAME (kept-alive) connection")
}

test "concurrent connections are all served" {
  val listener = startListener("http://127.0.0.1:19404/")
  val server = taskRun({ -> serveN(listener, 4) })
  threadSleep(100)
  val results: ConcQueue[String] = newConcQueue()
  val c0 = taskRun({ -> concurrentClient(19404, "c0", results) })
  val c1 = taskRun({ -> concurrentClient(19404, "c1", results) })
  val c2 = taskRun({ -> concurrentClient(19404, "c2", results) })
  val c3 = taskRun({ -> concurrentClient(19404, "c3", results) })
  taskWait(c0)
  taskWait(c1)
  taskWait(c2)
  taskWait(c3)
  taskWait(server)
  stopListener(listener)
  val all = drainConcQueue(results)
  assertTrue(
    all.contains("ok:c0") and all.contains("ok:c1") and all.contains("ok:c2") and all.contains("ok:c3"),
    "all four concurrent connections served: " + all
  )
}

test "TLS GET round trip via the Lyric HTTPS client" {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val listener = match startListenerTls("127.0.0.1", 19405, cfg) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTls failed: " + TlsListenError.message(e))
  }
  val server = taskRun({ -> serveN(listener, 1) })
  threadSleep(100)
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val resp = match await client.get("https://localhost:19405/secure") {
    case Ok(r) -> r
    case Err(e) -> panic("HTTPS GET failed: " + HttpError.message(e))
  }
  val body = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  taskWait(server)
  stopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "TLS-terminated response is 200")
  assertTrue(body.contains("path=/secure"), "path observed over TLS: " + body)
}

test "mTLS accepts a client whose certificate chains to clientCa" {
  val cfg = TlsServerConfig(
    identity = serverIdentity(),
    minVersion = Tls12,
    clientCa = Some(value = caCertificate()),
    requireClientCert = true
  )
  val listener = match startListenerTls("127.0.0.1", 19406, cfg) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTls failed: " + TlsListenError.message(e))
  }
  val server = taskRun({ -> serveN(listener, 1) })
  threadSleep(100)
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withClientIdentity(
      HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate()),
      clientIdentity()
    )
  )
  val result = await client.get("https://localhost:19406/")
  taskWait(server)
  stopListener(listener)
  match result {
    case Ok(r) -> assertEqualInt(r.statusCode(), 200, "mTLS client accepted; 200 returned")
    case Err(e) -> panic("mTLS accept: client GET failed: " + HttpError.message(e))
  }
}

test "mTLS rejects a client presenting no certificate" {
  val cfg = TlsServerConfig(
    identity = serverIdentity(),
    minVersion = Tls12,
    clientCa = Some(value = caCertificate()),
    requireClientCert = true
  )
  val listener = match startListenerTls("127.0.0.1", 19407, cfg) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTls failed: " + TlsListenError.message(e))
  }
  // No puller task: the handshake fails at the accept loop, so no request is
  // ever delivered — the accept loop drops the bad connection and keeps serving.
  threadSleep(100)
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val result = await client.get("https://localhost:19407/")
  stopListener(listener)
  match result {
    case Ok(_) -> panic("expected the certless client to be rejected by the mTLS server")
    case Err(_) -> assertTrue(true, "certless client rejected at the TLS handshake")
  }
}

test "HTTP/2 GET negotiates h2 over ALPN and round-trips via the Lyric HTTPS client" {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val listener = match startListenerTls("127.0.0.1", 19409, cfg) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTls failed: " + TlsListenError.message(e))
  }
  val server = taskRun({ -> serveN(listener, 1) })
  threadSleep(100)
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val resp = match await client.get("https://localhost:19409/h2get?x=1") {
    case Ok(r) -> r
    case Err(e) -> panic("h2 GET failed: " + HttpError.message(e))
  }
  val body = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  taskWait(server)
  stopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "h2 response is 200")
  match HttpResponse.negotiatedVersion(resp) {
    case Http2 -> assertTrue(true, "negotiated HTTP/2 over ALPN")
    case _ -> panic("expected HTTP/2 negotiation but got a lower version; body=" + body)
  }
  assertTrue(body.contains("m=GET"), "method observed over h2: " + body)
  assertTrue(body.contains("path=/h2get"), "path observed over h2: " + body)
  assertTrue(body.contains("q=x=1"), "query observed over h2: " + body)
}

test "HTTP/2 POST body reaches the handler and negotiates h2" {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val listener = match startListenerTls("127.0.0.1", 19410, cfg) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTls failed: " + TlsListenError.message(e))
  }
  val server = taskRun({ -> serveN(listener, 1) })
  threadSleep(100)
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val resp = match await client.post("https://localhost:19410/h2post", "hello h2 body") {
    case Ok(r) -> r
    case Err(e) -> panic("h2 POST failed: " + HttpError.message(e))
  }
  val body = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  taskWait(server)
  stopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "h2 POST response is 200")
  match HttpResponse.negotiatedVersion(resp) {
    case Http2 -> assertTrue(true, "negotiated HTTP/2 for the POST")
    case _ -> panic("expected HTTP/2 negotiation for POST; body=" + body)
  }
  assertTrue(body.contains("m=POST"), "method POST observed over h2: " + body)
  assertTrue(body.contains("body=hello h2 body"), "POST body delivered over h2: " + body)
}

test "HTTP/2 serves multiple request streams on one connection" {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val listener = match startListenerTls("127.0.0.1", 19411, cfg) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTls failed: " + TlsListenError.message(e))
  }
  val server = taskRun({ -> serveN(listener, 2) })
  threadSleep(100)
  // A single client instance reuses one h2 connection for both requests, so this
  // exercises two multiplexed streams driven through the same H2Conn FSM.
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val resp1 = match await client.get("https://localhost:19411/first") {
    case Ok(r) -> r
    case Err(e) -> panic("h2 stream 1 failed: " + HttpError.message(e))
  }
  val body1 = match await resp1.bodyText() { case Ok(t) -> t; case Err(_) -> panic("stream 1 body read failed") }
  val resp2 = match await client.get("https://localhost:19411/second") {
    case Ok(r) -> r
    case Err(e) -> panic("h2 stream 2 failed: " + HttpError.message(e))
  }
  val body2 = match await resp2.bodyText() { case Ok(t) -> t; case Err(_) -> panic("stream 2 body read failed") }
  taskWait(server)
  stopListener(listener)
  assertEqualInt(resp1.statusCode(), 200, "stream 1 is 200")
  assertEqualInt(resp2.statusCode(), 200, "stream 2 is 200")
  match HttpResponse.negotiatedVersion(resp1) {
    case Http2 -> assertTrue(true, "stream 1 is h2")
    case _ -> panic("stream 1 not h2")
  }
  match HttpResponse.negotiatedVersion(resp2) {
    case Http2 -> assertTrue(true, "stream 2 is h2")
    case _ -> panic("stream 2 not h2")
  }
  assertTrue(body1.contains("path=/first"), "stream 1 path: " + body1)
  assertTrue(body2.contains("path=/second"), "stream 2 path: " + body2)
}

test "HTTP/2 request body exceeding maxBodyBytes is rejected (413), not buffered unboundedly" {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val listener = match startListenerTlsWithLimits("127.0.0.1", 19412, cfg, smallBodyLimits(1024)) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTlsWithLimits failed: " + TlsListenError.message(e))
  }
  // No puller task: an over-limit request is rejected by the connection task
  // (413, END_STREAM) and never dispatched to `nextContext`.
  threadSleep(100)
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val resp = match await client.post("https://localhost:19412/big", makeBody(4096)) {
    case Ok(r) -> r
    case Err(e) -> panic("over-limit POST should return 413, not a transport error: " + HttpError.message(e))
  }
  stopListener(listener)
  assertEqualInt(resp.statusCode(), 413, "over-limit h2 request body rejected with 413")
}

test "HTTP/2 request body just under maxBodyBytes is accepted" {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val listener = match startListenerTlsWithLimits("127.0.0.1", 19413, cfg, smallBodyLimits(1024)) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTlsWithLimits failed: " + TlsListenError.message(e))
  }
  val server = taskRun({ -> serveN(listener, 1) })
  threadSleep(100)
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val underBody = makeBody(500)
  val resp = match await client.post("https://localhost:19413/ok", underBody) {
    case Ok(r) -> r
    case Err(e) -> panic("under-cap POST failed: " + HttpError.message(e))
  }
  val body = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  taskWait(server)
  stopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "under-cap h2 request body accepted")
  assertTrue(body.contains("body=" + underBody), "the full under-cap body reached the handler")
}

test "HTTP/2 large response body spans multiple DATA frames and arrives intact" {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val listener = match startListenerTls("127.0.0.1", 19414, cfg) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTls failed: " + TlsListenError.message(e))
  }
  // 200000 bytes > the 16 KiB max frame size (many DATA frames) and > the 65535
  // initial send window (drives sendH2Body's pumpForWindow + WINDOW_UPDATE).
  val bigResp = makeBody(200000)
  val server = taskRun({ -> serveLargeBody(listener, bigResp) })
  threadSleep(100)
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val resp = match await client.get("https://localhost:19414/large") {
    case Ok(r) -> r
    case Err(e) -> panic("large-body GET failed: " + HttpError.message(e))
  }
  val body = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  taskWait(server)
  stopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "large h2 response is 200")
  match HttpResponse.negotiatedVersion(resp) {
    case Http2 -> assertTrue(true, "h2")
    case _ -> panic("expected h2 for large body")
  }
  assertEqualInt(body.length, 200000, "full multi-frame body length received")
  assertTrue(body == bigResp, "multi-frame body content is intact and in order")
}

test "HTTP/2 chunked response body arrives fully" {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val listener = match startListenerTls("127.0.0.1", 19415, cfg) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTls failed: " + TlsListenError.message(e))
  }
  val server = taskRun({ -> serveChunked(listener) })
  threadSleep(100)
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val resp = match await client.get("https://localhost:19415/chunked") {
    case Ok(r) -> r
    case Err(e) -> panic("chunked GET failed: " + HttpError.message(e))
  }
  val body = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  taskWait(server)
  stopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "chunked h2 response is 200")
  match HttpResponse.negotiatedVersion(resp) {
    case Http2 -> assertTrue(true, "h2")
    case _ -> panic("expected h2 for chunked")
  }
  assertTrue(body == "chunk-A;chunk-B;chunk-C", "all chunks arrive concatenated in order: " + body)
}

test "startListenerTls rejects requireClientCert without clientCa" {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = true)
  match startListenerTls("127.0.0.1", 19408, cfg) {
    case Ok(_) -> panic("expected InvalidConfig for requireClientCert without clientCa")
    case Err(e) -> match e { case InvalidConfig(_) -> assertTrue(true, "mTLS misconfiguration rejected before binding"); case NotSupportedOnTarget(_) -> panic("unexpected NotSupportedOnTarget on dotnet") }
  }
}
