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
//! the server keeps serving), and the `startListenerTls` mTLS-misconfiguration
//! guard (`requireClientCert` with no `clientCa` → `InvalidConfig`).
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
import Std.Encoding
import Std.String
import Std.Tls
import Std.TcpHost
import Std.HttpServer
import Std.Http
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

// One concurrent raw client: GET /<tag>, record "ok:/<tag>" on success.
func concurrentClient(port: in Int, tag: in String, results: in List[String]): Unit {
  val marker = "path=/" + tag
  val body = rawRequest("127.0.0.1", port, "GET /" + tag + " HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", marker)
  if body.contains(marker) {
    results.add("ok:" + tag)
  } else {
    results.add("bad:" + tag)
  }
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
  val results: List[String] = newList()
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
  val all = joined(results)
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

test "startListenerTls rejects requireClientCert without clientCa" {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = true)
  match startListenerTls("127.0.0.1", 19408, cfg) {
    case Ok(_) -> panic("expected InvalidConfig for requireClientCert without clientCa")
    case Err(e) -> match e { case InvalidConfig(_) -> assertTrue(true, "mTLS misconfiguration rejected before binding"); case NotSupportedOnTarget(_) -> panic("unexpected NotSupportedOnTarget on dotnet") }
  }
}
