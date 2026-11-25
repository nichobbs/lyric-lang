//! tests/ws_hardening_tests.l - loopback tests for the lyric-ws hardening of
//! docs/73 S8 (D792, D793, D794): a bounded outbound path with a write
//! timeout so a client that stops reading cannot stall anyone else, a
//! connection cap, a handshake timeout and an idle timeout tied to ping
//! liveness, and `startServerTls` (wss).
//!
//! The clients are hand-rolled on `Std.TcpHost`, as in `ws_e2e_tests.l`, so
//! they check what the server really puts on the wire. A "stalled" client
//! completes the upgrade and then never calls `hostRead` again; its socket
//! buffers fill and the server's writes to it block, which is the failure
//! the outbound path exists to contain.
//!
//! Runs on every target `lyric-ws` claims: dotnet, the JVM and native. The wss
//! tests drive the TLS server with `Std.Http`'s client on every target (it
//! checks that TLS terminates and the WebSocket server answers through it,
//! including mutual TLS); the full WebSocket echo over TLS runs on native
//! only, because `Std.TcpHost` has a client TLS connect only there.
@test_module
package Ws.WsHardeningTests

import Std.Core
import Std.Collections
import Std.Console
import Std.Encoding
import Std.Environment
import Std.Parse
import Std.String
import Std.TcpHost
import Std.Tls
import Std.Http
import Std.Errors
import Std.Task as Task
import Std.Testing
import Std.Time
import Ws
import Ws.Frame
import Ws.Handshake

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

// ─── Handler and log ────────────────────────────────────────────────────────────
ref record HardenLog {
  var registry: Option[NativeRegistry] = None
  opens: List[String] = newList()
  errors: List[String] = newList()
  closeCodes: List[Int] = newList()
}

record LogHandler {
  log: HardenLog
}

func closeCodeInt(code: in WsCloseCode): Int {
  match code {
    case Normal(c) -> c
    case GoingAway -> 1001
    case ProtocolError -> 1002
    case PolicyViolation -> 1008
    case InternalError -> 1011
  }
}

impl WsHandler for LogHandler {
  func onOpen(ctx: in WsContext): Result[Unit, WsError] {
    self.log.opens.add(ctx.connectionId)
    Ok(())
  }

  func onMessage(ctx: in WsContext, msg: in WsMessage): Result[Unit, WsError] {
    match self.log.registry {
      case None -> Ok(())
      case Some(registry) -> match msg {
        case Text(text) -> {
          val _ = registry.send(ctx.connectionId, Text(text = "echo:" + text))
          Ok(())
        }
        case _ -> Ok(())
      }
    }
  }

  func onClose(ctx: in WsContext, code: in WsCloseCode): Unit {
    self.log.closeCodes.add(closeCodeInt(code))
  }

  func onError(ctx: in WsContext, error: in WsError): Unit {
    self.log.errors.add(error.message)
  }
}

record Started {
  registry: NativeRegistry
  log: HardenLog
}

func startPlain(port: in Int, options: in WsServerOptions): Started {
  val log = HardenLog()
  val registry = match startServerWithOptions("127.0.0.1", port, "/ws", options, LogHandler(log = log)) {
    case Ok(r) -> r
    case Err(e) -> panic("startServerWithOptions failed: " + e.message)
  }
  log.registry = Some(registry)
  sleepMillis(100)
  Started(registry = registry, log = log)
}

func startSecure(port: in Int, cfg: in TlsServerConfig, options: in WsServerOptions): Started {
  val log = HardenLog()
  val registry = match startServerTls("127.0.0.1", port, "/ws", cfg, options, LogHandler(log = log)) {
    case Ok(r) -> r
    case Err(e) -> panic("startServerTls failed: " + e.message)
  }
  log.registry = Some(registry)
  sleepMillis(100)
  Started(registry = registry, log = log)
}

func waitForCount(registry: in NativeRegistry, expected: in Int, maxMs: in Int): Bool {
  var waited = 0
  while connectionCount(registry) != expected and waited < maxMs {
    sleepMillis(10)
    waited = waited + 10
  }
  connectionCount(registry) == expected
}

func listHas(items: in List[String], needle: in String): Bool {
  var found = false
  var i = 0
  while i < items.count {
    if contains(items[i], needle) {
      found = true
    }
    i = i + 1
  }
  found
}

func intsHave(items: in List[Int], wanted: in Int): Bool {
  var found = false
  var i = 0
  while i < items.count {
    if items[i] == wanted {
      found = true
    }
    i = i + 1
  }
  found
}

func waitForOpen(log: in HardenLog, maxMs: in Int): Bool {
  var waited = 0
  while log.opens.count == 0 and waited < maxMs {
    sleepMillis(10)
    waited = waited + 10
  }
  log.opens.count > 0
}

func waitForClose(log: in HardenLog, maxMs: in Int): Bool {
  var waited = 0
  while log.closeCodes.count == 0 and waited < maxMs {
    sleepMillis(10)
    waited = waited + 10
  }
  log.closeCodes.count > 0
}

// ─── Minimal RFC 6455 client (independent of Ws.Frame) ─────────────────────────
val clientKey: String = "dGhlIHNhbXBsZSBub25jZQ=="

func dial(port: in Int): Conn {
  match hostConnect("127.0.0.1", port, 0) {
    case Ok(c) -> c
    case Err(e) -> panic("client connect failed: " + TcpError.message(e))
  }
}

func upgradeRequest(path: in String): String {
  "GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
    "Sec-WebSocket-Key: " +
    clientKey +
    "\r\nSec-WebSocket-Version: 13\r\n\r\n"
}

// The first line of the response head ("" when the peer closed first).
func readStatusLine(conn: in Conn): String {
  val acc: List[Byte] = newList()
  var done = false
  var tries = 0
  while not done and tries < 400 {
    match hostRead(conn, 4096) {
      case Ok(b) -> {
        if b.length == 0 {
          done = true
        } else {
          var i = 0
          while i < b.length {
            acc.add(b[i])
            i = i + 1
          }
        }
      }
      case Err(_) -> {
        done = true
      }
    }
    match findHeaderTerminator(acc.toArray()) {
      case Some(_) -> {
        done = true
      }
      case None -> ()
    }
    tries = tries + 1
  }
  match tryDecodeUtf8(acc.toArray()) {
    case Some(text) -> {
      val lines = split(text, "\r\n")
      if lines.length > 0 {
        lines[0]
      } else {
        ""
      }
    }
    case None -> ""
  }
}

func handshakeStatus(conn: in Conn): String {
  val _ = hostWrite(conn, encodeUtf8(upgradeRequest("/ws")))
  readStatusLine(conn)
}

func open101(port: in Int): Conn {
  val conn = dial(port)
  hostSetIoTimeout(conn, 10000)
  val status = handshakeStatus(conn)
  assertTrue(contains(status, "101"), "the upgrade is accepted: " + status)
  conn
}

// One masked client frame; payloads are at most 125 bytes.
func clientSend(conn: in Conn, opcode: in Int, payload: in slice[Byte]): Unit {
  val acc: List[Byte] = newList()
  acc.add((128 + opcode).toByte())
  acc.add((128 + payload.length).toByte())
  val keys: List[Int] = newList()
  keys.add(17)
  keys.add(34)
  keys.add(51)
  keys.add(68)
  var k = 0
  while k < 4 {
    acc.add(keys[k].toByte())
    k = k + 1
  }
  var i = 0
  while i < payload.length {
    acc.add(payload[i].toInt().xor(keys[i % 4]).toByte())
    i = i + 1
  }
  val _ = hostWrite(conn, acc.toArray());
  ()
}

ref record FrameReader {
  var buf: List[Byte] = newList()
  var pos: Int = 0
}

record FrameInfo {
  opcode: Int
  length: Int
  head: String
  code: Int
}

record Shape {
  headerLen: Int
  payloadLen: Int
}

func peekShape(r: in FrameReader): Option[Shape] {
  val avail = r.buf.count - r.pos
  if avail < 2 {
    return None
  }
  val b1 = r.buf[r.pos + 1].toInt().and(127)
  if b1 <= 125 {
    Some(value = Shape(headerLen = 2, payloadLen = b1))
  } else if b1 == 126 {
    if avail < 4 {
      None
    } else {
      Some(value = Shape(headerLen = 4, payloadLen = r.buf[r.pos + 2].toInt().shl(8).or(r.buf[r.pos + 3].toInt())))
    }
  } else {
    if avail < 10 {
      None
    } else {
      val len = r.buf[r.pos + 6].toInt().shl(24).or(r.buf[r.pos + 7].toInt().shl(16)).or(r.buf[r.pos + 8].toInt().shl(8)).or(
        r.buf[r.pos + 9].toInt()
      )
      Some(value = Shape(headerLen = 10, payloadLen = len))
    }
  }
}

func takeFrame(r: in FrameReader, shape: in Shape): FrameInfo {
  val start = r.pos + shape.headerLen
  val headBytes: List[Byte] = newList()
  var i = 0
  while i < 8 and i < shape.payloadLen {
    headBytes.add(r.buf[start + i])
    i = i + 1
  }
  val head = match tryDecodeUtf8(headBytes.toArray()) { case Some(t) -> t; case None -> "" }
  var code = 0
  if shape.payloadLen >= 2 {
    code = r.buf[start].toInt().shl(8).or(r.buf[start + 1].toInt())
  }
  val info = FrameInfo(opcode = r.buf[r.pos].toInt().and(15), length = shape.payloadLen, head = head, code = code)
  r.pos = r.pos + shape.headerLen + shape.payloadLen
  if r.pos >= r.buf.count {
    r.buf.clear()
    r.pos = 0
  } else if r.pos > 262144 {
    val rest: List[Byte] = newList()
    var j = r.pos
    while j < r.buf.count {
      rest.add(r.buf[j])
      j = j + 1
    }
    r.buf = rest
    r.pos = 0
  }
  info
}

// Blocks for one whole frame; `None` once the peer has closed or the read
// failed (the connection's I/O timeout included).
func readFrame(conn: in Conn, r: in FrameReader): Option[FrameInfo] {
  var result: Option[FrameInfo] = None
  var live = true
  while live and isNone(result) {
    match peekShape(r) {
      case Some(shape) -> {
        if r.buf.count - r.pos >= shape.headerLen + shape.payloadLen {
          result = Some(value = takeFrame(r, shape))
        }
      }
      case None -> ()
    }
    if live and isNone(result) {
      match hostRead(conn, 65536) {
        case Err(_) -> {
          live = false
        }
        case Ok(chunk) -> {
          if chunk.length == 0 {
            live = false
          } else {
            var i = 0
            while i < chunk.length {
              r.buf.add(chunk[i])
              i = i + 1
            }
          }
        }
      }
    }
  }
  result
}

func nowMs(): Long {
  monotonicNanos() / 1000000i64
}

func spawnTask(work: in () -> Unit): Task.Scope {
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, work)
  sc
}

// ─── (i) A client that stops reading ────────────────────────────────────────────
val frameChars: Int = 131072

val totalFrames: Int = 200

ref record FastResult {
  var frames: Int = 0
  var inOrder: Bool = true
  var done: Bool = false
}

func fastReader(conn: in Conn, res: in FastResult, total: in Int): Unit {
  val r = FrameReader()
  var running = true
  while running {
    match readFrame(conn, r) {
      case None -> {
        running = false
      }
      case Some(f) -> {
        if f.opcode == 1 {
          val idx = match parseOptInt(f.head) { case Some(n) -> n; case None -> 0 - 1 }
          if idx != res.frames {
            res.inOrder = false
          }
          res.frames = res.frames + 1
          if res.frames >= total {
            running = false
          }
        }
      }
    }
  }
  res.done = true
}

func numbered(i: in Int): String {
  val digits = i.toString()
  repeat("0", 8 - digits.length) + digits + repeat("x", frameChars - 8)
}

test "a client that stops reading is dropped and does not stall a broadcast to the others" {
  val started = startPlain(19601, WsServerOptions(maxOutboundBytes = 2097152, writeTimeoutMs = 5000))
  val registry = started.registry
  val fast = open101(19601)
  val slow = open101(19601)
  assertTrue(waitForCount(registry, 2, 3000), "both clients are connected")
  val res = FastResult()
  val reading = spawnTask({ -> fastReader(fast, res, totalFrames) })

  var worstMs = 0i64
  var sawErr = false
  var sent = 0
  var stalled = false
  while sent < totalFrames and not stalled {
    // The healthy client is flow-controlled to a few frames behind, so only the
    // stopped one can ever exceed its backlog bound.
    var waited = 0
    while sent - res.frames > 8 and waited < 20000 {
      sleepMillis(1)
      waited = waited + 1
    }
    if waited >= 20000 {
      stalled = true
    } else {
      val t0 = nowMs()
      match broadcastText(registry, numbered(sent)) {
        case Ok(_) -> ()
        case Err(_) -> {
          sawErr = true
        }
      }
      val spent = nowMs() - t0
      if spent > worstMs {
        worstMs = spent
      }
      sent = sent + 1
    }
  }
  assertFalse(stalled, "the healthy client received every frame the producer was waiting on")
  var waitedDone = 0
  while not res.done and waitedDone < 20000 {
    sleepMillis(10)
    waitedDone = waitedDone + 10
  }
  println("slow-consumer: worst broadcast call " + worstMs.toString() + " ms, frames " + res.frames.toString())
  assertEqualInt(res.frames, totalFrames, "the healthy client got every frame")
  assertTrue(res.inOrder, "in order")
  assertTrue(worstMs < 1500i64, "no broadcast call waited on the stopped client: worst " + worstMs.toString() + " ms")
  assertTrue(sawErr, "the broadcast reported the connection it dropped")
  assertTrue(waitForCount(registry, 1, 5000), "the stopped client's connection was dropped")
  assertTrue(waitForClose(started.log, 3000), "onClose ran for it")
  assertTrue(intsHave(started.log.closeCodes, 1008), "with close code 1008")
  assertTrue(listHas(started.log.errors, "slow consumer"), "onError named a slow consumer")
  val _ = await Task.awaitAll(reading)
  hostClose(fast)
  hostClose(slow)
  val _ = stopServer(registry)
}

test "write timeout: a write that makes no progress ends the connection even with room in the queue" {
  val started = startPlain(
    19602,
    WsServerOptions(maxOutboundBytes = 67108864, writeTimeoutMs = 4000, idleTimeoutMs = 0)
  )
  val registry = started.registry
  val slow = open101(19602)
  assertTrue(waitForCount(registry, 1, 3000), "the client is connected")
  assertTrue(waitForOpen(started.log, 3000), "onOpen ran")
  val id = started.log.opens[0]
  val big = repeat("y", 1048576)
  val t0 = nowMs()
  var allQueued = true
  var i = 0
  while i < 16 {
    match sendText(registry, id, big) {
      case Ok(_) -> ()
      case Err(_) -> {
        allQueued = false
      }
    }
    i = i + 1
  }
  val spent = nowMs() - t0
  println("write-timeout: 16 MiB queued in " + spent.toString() + " ms")
  assertTrue(allQueued, "send queued every frame")
  assertTrue(spent < 3800i64, "send returned without waiting for the peer: " + spent.toString() + " ms")
  assertTrue(waitForCount(registry, 0, 8000), "the stalled connection was ended")
  assertTrue(waitForClose(started.log, 3000), "onClose ran")
  assertTrue(intsHave(started.log.closeCodes, 1008), "with close code 1008")
  assertTrue(listHas(started.log.errors, "no progress"), "onError named the stalled write")
  hostClose(slow)
  val _ = stopServer(registry)
}

test "a send to a connection already dropped is an error, not a hang" {
  val started = startPlain(19603, WsServerOptions(maxOutboundBytes = 1024, writeTimeoutMs = 600, idleTimeoutMs = 0))
  val registry = started.registry
  val slow = open101(19603)
  assertTrue(waitForCount(registry, 1, 3000), "the client is connected")
  assertTrue(waitForOpen(started.log, 3000), "onOpen ran")
  val id = started.log.opens[0]
  val big = repeat("z", 65536)
  var dropped = false
  var i = 0
  while i < 400 and not dropped {
    match sendText(registry, id, big) {
      case Ok(_) -> ()
      case Err(e) -> {
        dropped = contains(e.message, "slow consumer")
      }
    }
    i = i + 1
  }
  assertTrue(dropped, "with a 1 KiB backlog bound a stopped client is reported as a slow consumer")
  match sendText(registry, id, "again") {
    case Ok(_) -> assertTrue(false, "a send after the drop must fail")
    case Err(e) -> assertTrue(
      contains(e.message, "closed") or contains(e.message, "unknown") or contains(e.message, "closing"),
      "the later send fails: " + e.message
    )
  }
  hostClose(slow)
  val _ = stopServer(registry)
}

// ─── (ii) Connection cap, handshake timeout, idle timeout ──────────────────────
test "connection cap: the connection over the cap is answered 503 and a freed slot is reusable" {
  val started = startPlain(19604, WsServerOptions(maxConnections = 2))
  val registry = started.registry
  val c1 = open101(19604)
  val c2 = open101(19604)
  assertTrue(waitForCount(registry, 2, 3000), "two connections are open")
  val c3 = dial(19604)
  hostSetIoTimeout(c3, 10000)
  val refused = handshakeStatus(c3)
  assertTrue(contains(refused, "503"), "the third is refused with 503: " + refused)
  assertEqualInt(connectionCount(registry), 2, "the refused connection is not counted")
  hostClose(c3)

  clientSend(c1, 8, encodeClosePayload(1000, ""))
  val reader = FrameReader()
  match readFrame(c1, reader) {
    case Some(f) -> assertEqualInt(f.opcode, 8, "the server answers the close")
    case None -> assertTrue(false, "no close reply")
  }
  assertTrue(waitForCount(registry, 1, 3000), "the closed connection freed its slot")
  var admitted = false
  var tries = 0
  while not admitted and tries < 40 {
    val c4 = dial(19604)
    hostSetIoTimeout(c4, 10000)
    admitted = contains(handshakeStatus(c4), "101")
    if not admitted {
      hostClose(c4)
      sleepMillis(50)
    }
    tries = tries + 1
  }
  assertTrue(admitted, "a new connection is admitted once a slot is free")
  hostClose(c1)
  hostClose(c2)
  val _ = stopServer(registry)
}

test "handshake timeout: a peer that sends nothing is closed" {
  val started = startPlain(19605, WsServerOptions(handshakeTimeoutMs = 500))
  val conn = dial(19605)
  hostSetIoTimeout(conn, 5000)
  val t0 = nowMs()
  val outcome = hostRead(conn, 16)
  val spent = nowMs() - t0
  match outcome {
    case Ok(bytes) -> assertEqualInt(bytes.length, 0, "the server closed the connection")
    case Err(_) -> ()
  }
  assertTrue(spent < 4000i64, "closed by the handshake timeout, not the client's own: " + spent.toString() + " ms")
  assertEqualInt(connectionCount(started.registry), 0, "it never became a connection")
  hostClose(conn)
  val _ = stopServer(started.registry)
}

test "idle timeout: a connection that sends nothing is closed with 1001" {
  val started = startPlain(19606, WsServerOptions(idleTimeoutMs = 700))
  val conn = open101(19606)
  assertTrue(waitForCount(started.registry, 1, 3000), "connected")
  hostSetIoTimeout(conn, 6000)
  val t0 = nowMs()
  val reader = FrameReader()
  match readFrame(conn, reader) {
    case Some(f) -> {
      assertEqualInt(f.opcode, 8, "the server starts the close handshake")
      assertEqualInt(f.code, 1001, "with going away")
    }
    case None -> assertTrue(false, "the server never closed an idle connection")
  }
  val spent = nowMs() - t0
  assertTrue(spent < 4000i64, "after about the idle timeout: " + spent.toString() + " ms")
  hostClose(conn)
  assertTrue(waitForClose(started.log, 8000), "onClose ran")
  assertTrue(intsHave(started.log.closeCodes, 1001), "reporting 1001")
  assertTrue(waitForCount(started.registry, 0, 3000), "the connection is gone")
  val _ = stopServer(started.registry)
}

ref record PongClient {
  var pings: Int = 0
  var closed: Bool = false
  var ended: Bool = false
}

func pongClient(conn: in Conn, state: in PongClient, answer: in Bool): Unit {
  val r = FrameReader()
  var running = true
  while running {
    match readFrame(conn, r) {
      case None -> {
        running = false
      }
      case Some(f) -> {
        if f.opcode == 9 {
          state.pings = state.pings + 1
          if answer {
            clientSend(conn, 10, emptyPayload())
          }
        } else if f.opcode == 8 {
          state.closed = true
          clientSend(conn, 8, encodeClosePayload(f.code, ""))
          running = false
        }
      }
    }
  }
  state.ended = true
}

func emptyPayload(): slice[Byte] {
  val e: slice[Byte] = []
  e
}

test "idle timeout is tied to ping liveness: pongs keep a connection, silence does not" {
  setVar("LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS", "200")
  val started = startPlain(19607, WsServerOptions(idleTimeoutMs = 800))
  setVar("LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS", "30000")
  val alive = open101(19607)
  val silent = open101(19607)
  assertTrue(waitForCount(started.registry, 2, 3000), "both are connected")
  val aliveState = PongClient()
  val silentState = PongClient()
  val a = spawnTask({ -> pongClient(alive, aliveState, true) })
  val s = spawnTask({ -> pongClient(silent, silentState, false) })
  sleepMillis(3000)
  assertTrue(aliveState.pings >= 5, "the keepalive pinged the answering client: " + aliveState.pings.toString())
  assertFalse(aliveState.closed, "a client that answers every ping stays connected well past the idle timeout")
  assertTrue(silentState.closed, "a client that never answers is closed")
  assertTrue(waitForCount(started.registry, 1, 3000), "one connection is left")
  hostShutdown(alive)
  hostShutdown(silent)
  val _ = await Task.awaitAll(a)
  val _ = await Task.awaitAll(s)
  hostClose(alive)
  hostClose(silent)
  val _ = stopServer(started.registry)
}

// ─── (iii) wss ──────────────────────────────────────────────────────────────────
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

func httpsClient(): HttpClient {
  HttpClientBuilder.build(
    HttpClientBuilder.withHttpVersion(
      HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate()),
      Http11
    )
  )
}

func httpsClientWithIdentity(): HttpClient {
  HttpClientBuilder.build(
    HttpClientBuilder.withHttpVersion(
      HttpClientBuilder.withClientIdentity(
        HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate()),
        clientIdentity()
      ),
      Http11
    )
  )
}

test "wss: TLS terminates and the WebSocket server answers through it" {
  val started = startSecure(19620, TlsServerConfig(identity = serverIdentity()), WsServerOptions())
  val client = httpsClient()
  match await client.get("https://localhost:19620/ws") {
    case Ok(r) -> assertEqualInt(r.statusCode(), 400, "a plain GET of the upgrade path is refused 400, over TLS")
    case Err(e) -> assertTrue(false, "GET over TLS failed: " + HttpError.message(e))
  }
  assertEqualInt(connectionCount(started.registry), 0, "no upgrade, no connection")
  val _ = stopServer(started.registry)
}

test "wss: a client that does not trust the server certificate fails the handshake" {
  val started = startSecure(19621, TlsServerConfig(identity = serverIdentity()), WsServerOptions())
  val untrusting = HttpClientBuilder.build(HttpClientBuilder.withHttpVersion(HttpClientBuilder.new(), Http11))
  match await untrusting.get("https://localhost:19621/ws") {
    case Ok(_) -> assertTrue(false, "an unknown CA must not be trusted")
    case Err(_) -> assertTrue(true, "the handshake failed as it should")
  }
  val _ = stopServer(started.registry)
}

test "wss: mutual TLS refuses a client without a certificate and admits one that chains to the CA" {
  val cfg = TlsServerConfig(
    identity = serverIdentity(),
    minVersion = Tls12,
    clientCa = Some(value = caCertificate()),
    requireClientCert = true
  )
  val started = startSecure(19622, cfg, WsServerOptions())
  match await httpsClient().get("https://localhost:19622/ws") {
    case Ok(_) -> assertTrue(false, "a client without a certificate must be refused")
    case Err(_) -> assertTrue(true, "refused at the handshake")
  }
  match await httpsClientWithIdentity().get("https://localhost:19622/ws") {
    case Ok(r) -> assertEqualInt(r.statusCode(), 400, "a client the CA signed reaches the WebSocket server")
    case Err(e) -> assertTrue(false, "mutual TLS client failed: " + HttpError.message(e))
  }
  val _ = stopServer(started.registry)
}

test "wss: a TLS configuration that cannot work is refused before the port is bound" {
  val broken = TlsServerConfig(
    identity = serverIdentity(),
    minVersion = Tls12,
    clientCa = None,
    requireClientCert = true
  )
  match startServerTls("127.0.0.1", 19623, "/ws", broken, WsServerOptions(), LogHandler(log = HardenLog())) {
    case Ok(_) -> assertTrue(false, "requireClientCert with no clientCa must be refused")
    case Err(e) -> assertEqual(e.code, "SERVER_START_FAILED", "reported as a start failure: " + e.message)
  }
  val again = startPlain(19623, WsServerOptions())
  assertEqualInt(connectionCount(again.registry), 0, "the port was never taken")
  val _ = stopServer(again.registry)
}

test "wss: a peer that never finishes the TLS handshake is closed by the handshake timeout" {
  val started = startSecure(
    19624,
    TlsServerConfig(identity = serverIdentity()),
    WsServerOptions(handshakeTimeoutMs = 500)
  )
  val conn = dial(19624)
  hostSetIoTimeout(conn, 5000)
  val t0 = nowMs()
  // The server may send a TLS alert before it closes, so read until the end.
  var ended = false
  while not ended and nowMs() - t0 < 4500i64 {
    match hostRead(conn, 64) {
      case Ok(bytes) -> {
        ended = bytes.length == 0
      }
      case Err(_) -> {
        ended = true
      }
    }
  }
  val spent = nowMs() - t0
  assertTrue(ended, "the server closed the connection")
  assertTrue(spent < 4000i64, "closed by the server's handshake timeout: " + spent.toString() + " ms")
  hostClose(conn)
  val _ = stopServer(started.registry)
}

// `Std.TcpHost` has a client TLS connect on native only, so the frames of a
// wss connection are exchanged there; on dotnet and the JVM the tests above
// reach the same server through `Std.Http`'s TLS client.
@cfg(target = "native")
test "wss (native): a WebSocket echo over TLS, then a clean close" {
  val started = startSecure(19625, TlsServerConfig(identity = serverIdentity()), WsServerOptions())
  val conn = match hostConnectTls("localhost", 19625, TlsTrustExclusive(caPem = caCertPem), None, Tls12, "http/1.1") {
    case Ok(c) -> c
    case Err(e) -> panic("TLS connect failed: " + TcpError.message(e))
  }
  hostSetIoTimeout(conn, 10000)
  val status = handshakeStatus(conn)
  assertTrue(contains(status, "101"), "the upgrade is accepted over TLS: " + status)
  clientSend(conn, 1, encodeUtf8("secure"))
  val reader = FrameReader()
  match readFrame(conn, reader) {
    case Some(f) -> {
      assertEqualInt(f.opcode, 1, "a text frame comes back")
      assertEqual(f.head, "echo:sec", "carrying the echo")
    }
    case None -> assertTrue(false, "no echo over TLS")
  }
  clientSend(conn, 8, encodeClosePayload(1000, ""))
  match readFrame(conn, reader) {
    case Some(f) -> assertEqualInt(f.opcode, 8, "the close is answered over TLS")
    case None -> assertTrue(false, "no close reply over TLS")
  }
  assertTrue(waitForCount(started.registry, 0, 3000), "the connection ended")
  hostClose(conn)
  val _ = stopServer(started.registry)
}
