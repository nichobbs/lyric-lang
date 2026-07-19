//! stdlib/tests/tcp_host_tls_tests.l — runtime tests for the dotnet TCP +
//! server-side TLS transport kernel `Std.TcpHost`
//! (docs/61-https-tls-http-versions.md §6.1/§6.3, phase 3.1 of epic #5874,
//! issue #5882).
//!
//! dotnet-only: `Std.TcpHost` is the `--target dotnet` transport kernel
//! (`System.Net.Sockets.TcpListener` + `System.Net.Security.SslStream`). The
//! JVM/native transports are separate later issues, so this suite runs only
//! on `--target dotnet`.
//!
//! Coverage: `TcpError.message`, a `hostListen` bind-failure, a plain
//! loopback echo round trip (accept/connect/read/write/close + `hostAlpn ==
//! ""` for a plain connection), a full server-side TLS handshake + HTTP/1.1
//! request/response byte round trip against the REAL Lyric HTTPS client
//! (`HttpClientBuilder.withExclusiveCaCertificate`, #5877), and both mTLS
//! outcomes (a client cert that chains to `clientCa` is accepted; a client
//! that presents no cert with `requireClientCert` is rejected at the
//! handshake). The transport advertises `h2` + `http/1.1` (phase 4.4), but
//! `serveOneTls` is a raw HTTP/1.1 echo server, so the round-trip tests pin the
//! client to HTTP/1.1 (`withHttpVersion(Http11)`) — a .NET HttpClient pinned to
//! 1.1 sends no ALPN, so the server reports `hostAlpn == ""`; the h2 ALPN
//! end-to-end path is covered by `http_server_dotnet_tests.l`. The server echoes
//! its own `hostAlpn` in the response body, so
//! a main-thread assertion confirms the negotiated protocol end to end.
//!
//! Concurrency: an in-process loopback needs the server accept loop and the
//! client to run on separate OS threads (Lyric `spawn` is degenerate-
//! synchronous on `--target dotnet`, D119/D120), so the server side runs on a
//! `System.Threading.Tasks.Task`. Declaring those `extern`s in a test file
//! mirrors `tls_server_jvm_tests.l`, which reaches the handshake layer through
//! the same `extern` surface the kernel itself uses — a documented
//! test-only exception to the `_kernel/`-only extern rule for driving the
//! opposite side of a real protocol.
//!
//! Fixtures: a self-signed CA, a server leaf with `SAN=DNS:localhost,IP:
//! 127.0.0.1` signed by it (so the .NET client's hostname check passes when
//! connecting to `https://localhost`), and a client leaf signed by the same
//! CA for the mTLS-accept case. All are embedded PEM (self-contained, as in
//! `tls_tests.l`), valid 2026-07-18..2036-07-15.
@test_module
package Std.TcpHost.TlsTests

import Std.Core
import Std.Encoding
import Std.String
import Std.Tls
import Std.TcpHost
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

extern type Task = "System.Threading.Tasks.Task"

// `Task.Run(Action)` on a background thread gives the in-process loopback the
// real concurrency `spawn` cannot on this target (module header). The Lyric
// `() -> Unit` closure binds to `System.Action` through the D122 delegate
// bridge, exactly as the client kernel's validation-callback lambda does.
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

func httpOkResponse(body: in String): slice[Byte] {
  encodeUtf8(
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " + toString(body.length) +
      "\r\nConnection: close\r\n\r\n" +
      body
  )
}

// Bounded wait for the server task to signal it has started (`ready` is
// non-empty) before the client connects — replaces a fixed-duration
// `threadSleep`, which is a latent CI flake under slow scheduling (#6032).
// Correctness does not actually depend on this timing: the listener is bound
// (`hostListen` returns) BEFORE the server task is spawned, so a client
// connection always lands in the accept backlog and the TLS handshake / read
// blocks until the server task processes it. This poll only tightens the
// window (and lets the test fail fast if the task never starts). `ready` is
// written on the server thread and read here on the main thread; a torn read
// merely spins one more iteration, and the bound guarantees termination.
func waitReady(ready: in List[String], maxTries: in Int): Unit {
  var i = 0
  while i < maxTries and ready.count == 0 {
    threadSleep(50)
    i = i + 1
  }
}

// Accept one TLS connection, reply with a body echoing the negotiated ALPN,
// then close. Signals `ready` before blocking on accept. The handshake outcome
// is appended to `outcome` (read on the main thread after `taskWait`, which is
// a memory barrier).
func serveOneTls(listener: in Listener, cfg: in TlsServerConfig, ready: in List[String], outcome: in List[String]): Unit {
  ready.add("go")
  match hostAcceptTls(listener, cfg) {
    case Err(e) -> outcome.add("ERR:" + TcpError.message(e))
    case Ok(conn) -> {
      outcome.add("OK:" + hostAlpn(conn))
      match hostRead(conn, 4096) {
        case Ok(_) -> {
          val _ = hostWrite(conn, httpOkResponse("alpn=" + hostAlpn(conn)));
          ()
        }
        case Err(_) -> ()
      }
      hostClose(conn)
    }
  }
}

func plainEchoServer(listener: in Listener, ready: in List[String]): Unit {
  ready.add("go")
  match hostAccept(listener) {
    case Err(_) -> ()
    case Ok(conn) -> {
      match hostRead(conn, 1024) {
        case Ok(bytes) -> {
          val _ = hostWrite(conn, bytes);
          ()
        }
        case Err(_) -> ()
      }
      hostClose(conn)
    }
  }
}

test "TcpError.message renders every case" {
  assertEqual(TcpError.message(BindFailed(message = "x")), "bind failed: x", "bind")
  assertEqual(TcpError.message(AcceptFailed(message = "x")), "accept failed: x", "accept")
  assertEqual(TcpError.message(TlsHandshakeFailed(message = "x")), "TLS handshake failed: x", "tls")
  assertEqual(TcpError.message(TransportFailed(message = "x")), "I/O error: x", "io")
  assertEqual(TcpError.message(TlsConfigInvalid(message = "x")), "TLS configuration invalid: x", "config")
}

test "hostListen rejects a malformed address as BindFailed" {
  match hostListen("not-an-ip", 18921) {
    case Ok(_) -> panic("expected BindFailed for a malformed address")
    case Err(e) -> match e { case BindFailed(_) -> assertTrue(true, "malformed address rejected"); case _ -> panic("expected BindFailed, got " + TcpError.message(e)) }
  }
}

test "plain loopback echo round trip" {
  val listener = match hostListen("127.0.0.1", 18921) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val ready: List[String] = newList()
  val server = taskRun({ -> plainEchoServer(listener, ready) })
  waitReady(ready, 100)
  val conn = match hostConnect("127.0.0.1", 18921) {
    case Ok(c) -> c
    case Err(e) -> panic("connect failed: " + TcpError.message(e))
  }
  assertEqual(hostAlpn(conn), "", "a plain connection has no ALPN")
  val _ = hostWrite(conn, encodeUtf8("ping"))
  val echoed = match hostRead(conn, 1024) {
    case Ok(b) -> b
    case Err(e) -> panic("read failed: " + TcpError.message(e))
  }
  hostClose(conn)
  taskWait(server)
  hostStopListener(listener)
  match tryDecodeUtf8(echoed) {
    case Some(s) -> assertEqual(s, "ping", "echo round trip returns the sent bytes")
    case None -> panic("echoed bytes were not valid UTF-8")
  }
}

test "server TLS terminates and round-trips bytes with an http/1.1 client" {
  val listener = match hostListen("127.0.0.1", 18922) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val outcome: List[String] = newList()
  val ready: List[String] = newList()
  val server = taskRun({ -> serveOneTls(listener, cfg, ready, outcome) })
  waitReady(ready, 100)

  // Pin HTTP/1.1: the transport now advertises `h2` too (phase 4.4), and the
  // default h2-or-lower client would negotiate h2 — but `serveOneTls` is a raw
  // HTTP/1.1 echo server, not an h2 endpoint. (h2 end-to-end is covered by
  // `http_server_dotnet_tests.l`.) A .NET HttpClient pinned to HTTP/1.1 sends no
  // ALPN extension, so the server negotiates no protocol and `hostAlpn` reports
  // `""` — this verifies the server correctly reports "no ALPN" and still
  // round-trips the raw bytes.
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withHttpVersion(
      HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate()),
      Http11
    )
  )
  val resp = match await client.get("https://localhost:18922/") {
    case Ok(r) -> r
    case Err(e) -> panic("client GET failed: " + HttpError.message(e))
  }
  val body = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  taskWait(server)
  hostStopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "TLS-terminated response carries the 200 status")
  assertTrue(body.startsWith("alpn="), "server echoed its ALPN report over the TLS byte round trip: " + body)
  assertTrue(not body.contains("alpn=h2"), "an http/1.1-pinned client is not served as h2: " + body)
}

test "mTLS accepts a client whose certificate chains to clientCa" {
  val listener = match hostListen("127.0.0.1", 18923) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val cfg = TlsServerConfig(
    identity = serverIdentity(),
    minVersion = Tls12,
    clientCa = Some(value = caCertificate()),
    requireClientCert = true
  )
  val outcome: List[String] = newList()
  val ready: List[String] = newList()
  val server = taskRun({ -> serveOneTls(listener, cfg, ready, outcome) })
  waitReady(ready, 100)

  // Pin HTTP/1.1 (see the http/1.1 round-trip test): `serveOneTls` speaks raw
  // HTTP/1.1, so the default h2-or-lower client (which would now negotiate the
  // newly-advertised h2) must pin http/1.1 here.
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withHttpVersion(
      HttpClientBuilder.withClientIdentity(
        HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate()),
        clientIdentity()
      ),
      Http11
    )
  )
  val result = await client.get("https://localhost:18923/")
  taskWait(server)
  hostStopListener(listener)
  match result {
    case Ok(r) -> assertEqualInt(r.statusCode(), 200, "mTLS client accepted; 200 returned")
    case Err(e) -> panic("mTLS accept: client GET failed: " + HttpError.message(e))
  }
}

test "mTLS rejects a client presenting no certificate when requireClientCert is set" {
  val listener = match hostListen("127.0.0.1", 18924) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val cfg = TlsServerConfig(
    identity = serverIdentity(),
    minVersion = Tls12,
    clientCa = Some(value = caCertificate()),
    requireClientCert = true
  )
  val outcome: List[String] = newList()
  val ready: List[String] = newList()
  val server = taskRun({ -> serveOneTls(listener, cfg, ready, outcome) })
  waitReady(ready, 100)

  // No client identity -> the server must reject the handshake.
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val result = await client.get("https://localhost:18924/")
  taskWait(server)
  hostStopListener(listener)
  assertTrue(startsWith(outcome[0], "ERR"), "server rejected the certless client at the handshake: " + outcome[0])
  match result {
    case Ok(_) -> panic("expected the client GET to fail against a rejecting mTLS server")
    case Err(_) -> assertTrue(true, "client GET failed as expected")
  }
}

// #6042: requireClientCert with no clientCa is a mutual-TLS misconfiguration —
// without a client CA to pin trust to, the kernel would otherwise fall back to
// the system trust store and accept any publicly-trusted client certificate.
// hostAcceptTls must reject it up front (before any accept), so no client or
// background task is needed here.
test "mTLS config with requireClientCert but no clientCa is rejected as invalid" {
  val listener = match hostListen("127.0.0.1", 18925) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = true)
  val result = hostAcceptTls(listener, cfg)
  hostStopListener(listener)
  match result {
    case Ok(_) -> panic("expected TlsConfigInvalid for requireClientCert without clientCa")
    case Err(e) -> match e { case TlsConfigInvalid(_) -> assertTrue(true, "mTLS misconfiguration rejected before any accept"); case _ -> panic("expected TlsConfigInvalid, got " + TcpError.message(e)) }
  }
}

// #6033: exercise the Tls13 branch of buildServerOptions (minVersion = Tls13
// pins EnabledSslProtocols to TLS 1.3). The real Lyric HTTPS client negotiates
// TLS 1.3 with a 1.3-only server, so the handshake + round trip still succeed.
test "TLS 1.3 minVersion still completes the handshake and round trip" {
  val listener = match hostListen("127.0.0.1", 18926) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls13, clientCa = None, requireClientCert = false)
  val outcome: List[String] = newList()
  val ready: List[String] = newList()
  val server = taskRun({ -> serveOneTls(listener, cfg, ready, outcome) })
  waitReady(ready, 100)

  // Pin HTTP/1.1 (see the http/1.1 round-trip test): raw `serveOneTls` + the
  // newly-advertised h2 would otherwise negotiate h2 against a non-h2 server.
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withHttpVersion(
      HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate()),
      Http11
    )
  )
  val resp = match await client.get("https://localhost:18926/") {
    case Ok(r) -> r
    case Err(e) -> panic("client GET failed under Tls13: " + HttpError.message(e))
  }
  val body = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  taskWait(server)
  hostStopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "Tls13 server completes the round trip with 200")
  assertTrue(body.startsWith("alpn="), "Tls13 server echoed its ALPN report over the round trip: " + body)
  assertTrue(not body.contains("alpn=h2"), "an http/1.1-pinned client is not served as h2 under Tls13: " + body)
}
