//! tests/server_h2_tests.l — `Grpc.Server`, the pure-Lyric gRPC server, on both
//! targets (docs/72 slice 8, D804): request compression, `grpc-timeout`
//! enforcement, handler panic isolation, TLS and drain.
//!
//! Two peers drive it. The pure-Lyric client (`Grpc.Client`) covers what a normal
//! caller does. A raw HTTP/2 caller (`Std.HttpEngine.H2Client`, headers and
//! bytes chosen by the test) covers what a conforming client never sends: an
//! unknown `grpc-encoding`, a gzip bomb, a malformed `grpc-timeout`, a
//! `grpc-timeout` with no client-side deadline, so the server's enforcement is
//! what ends the call. Independent clients (grpc-java, `Grpc.Net.Client`) are
//! in `server_interop_jvm_tests.l` and `server_interop_dotnet_tests.l`.
//!
//! Every wait is bounded. Listeners bind port 0.
@cfg(not(feature = "legacy-client"))
@cfg(not(feature = "native"))
@test_module
package Grpc.ServerH2Tests

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Encoding
import Std.Tls
import Std.HttpServerHost
import Std.HttpEngine
import Std.HttpEngine.H2Client
import Std.Time
import Std.Parse
import Std.Testing
import Grpc
import Grpc.Server
import Grpc.Types
import Grpc.Wire

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

// ─── Helpers ─────────────────────────────────────────────────────────────────
func bytesOf(xs: in List[Int]): slice[Byte] {
  val acc: List[Byte] = newList()
  for x in xs {
    acc.add(x.toByte())
  }
  acc.toArray()
}

func repeated(n: in Int, v: in Int): slice[Byte] {
  val acc: List[Byte] = newListWithCapacity(n)
  var i = 0
  while i < n {
    acc.add(((v + i) % 251).toByte())
    i = i + 1
  }
  acc.toArray()
}

func waitFor(ms: in Int, cond: in () -> Bool): Bool {
  var waited = 0
  while waited < ms {
    if cond() {
      return true
    }
    sleepMillis(5)
    waited = waited + 5
  }
  cond()
}

func codeOf(st: in GrpcStatus): Int {
  statusCodeToInt(st.code)
}

/// What the handlers record, so a test can see what the server did after the
/// client's call had already ended.
ref record Probe {
  var slowDone: Bool
  var ticks: Int
  var sawCancel: Bool
  var lastLength: Int
}

val probe: Probe = Probe(slowDone = false, ticks = 0, sawCancel = false, lastLength = -1)

val resultsGuard: Mutex = newMutex()

func resetProbe(): Unit {
  probe.slowDone = false
  probe.ticks = 0
  probe.sawCancel = false
  probe.lastLength = -1
}

// ─── Handlers (service `t`) ──────────────────────────────────────────────────
func echo(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  Std.Core.Ok(req)
}

func lengthOf(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  probe.lastLength = req.length
  Std.Core.Ok(encodeUtf8(req.length.toString()))
}

func slow(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  sleepMillis(1200)
  probe.slowDone = true
  Std.Core.Ok(req)
}

func drain(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  sleepMillis(600)
  Std.Core.Ok(req)
}

func timeoutSeen(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  val text = match Grpc.requestTimeoutMs(meta) { case Some(ms) -> ms.toString(); case None -> "none" }
  Std.Core.Ok(encodeUtf8(text))
}

func boom(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  panic("secret internal detail")
}

func ticker(
  req: in slice[Byte], meta: in slice[GrpcMetadataEntry], emit: in (slice[Byte]) -> Bool
): Result[Unit, GrpcStatus] {
  var i = 0
  while i < 100 {
    if not emit(bytesOf([i])) {
      probe.sawCancel = true
      return Std.Core.Ok(())
    }
    probe.ticks = probe.ticks + 1
    sleepMillis(50)
    i = i + 1
  }
  Std.Core.Ok(())
}

func boomStream(
  req: in slice[Byte], meta: in slice[GrpcMetadataEntry], emit: in (slice[Byte]) -> Bool
): Result[Unit, GrpcStatus] {
  val _ = emit(bytesOf([1]))
  panic("secret stream detail")
}

func buildRegistry(): ServiceRegistry {
  var r = Grpc.create()
  r = Grpc.addUnary(r, "t", "Echo", echo)
  r = Grpc.addUnary(r, "t", "Length", lengthOf)
  r = Grpc.addUnary(r, "t", "Slow", slow)
  r = Grpc.addUnary(r, "t", "Drain", drain)
  r = Grpc.addUnary(r, "t", "Timeout", timeoutSeen)
  r = Grpc.addUnary(r, "t", "Boom", boom)
  r = Grpc.addServerStreaming(r, "t", "Ticker", ticker)
  r = Grpc.addServerStreaming(r, "t", "BoomStream", boomStream)
  r
}

func startPlain(): GrpcServerHandle {
  resetProbe()
  Grpc.startHandleAt(buildRegistry(), "127.0.0.1", 0)
}

func addressOf(server: in GrpcServerHandle, scheme: in String): String {
  scheme + "://127.0.0.1:" + Grpc.serverPort(server).toString()
}

func openOk(address: in String): GrpcChannel {
  match Grpc.openChannel(address) {
    case Std.Core.Ok(ch) -> ch
    case Std.Core.Err(m) -> panic("openChannel failed: " + m)
  }
}

func openWith(address: in String, o: in ChannelOptions): GrpcChannel {
  match Grpc.openChannelWith(address, o) {
    case Std.Core.Ok(ch) -> ch
    case Std.Core.Err(m) -> panic("openChannelWith failed: " + m)
  }
}

func callText(ch: in GrpcChannel, method: in String, payload: in slice[Byte], o: in GrpcCallOptions): String {
  match Grpc.callUnary(ch, "t", method, payload, o) {
    case Std.Core.Ok(r) -> match tryDecodeUtf8(r) { case Some(t) -> t; case None -> "<not utf8>" }
    case Std.Core.Err(st) -> "ERR " + codeOf(st).toString() + " " + st.message
  }
}

// ─── A raw HTTP/2 caller ─────────────────────────────────────────────────────
ref record Raw {
  var status: Int
  var message: String
  var headers: List[HeaderField]
  var messages: Int
  var failure: String
  var elapsedMs: Long
}

func headerOf(fields: in List[HeaderField], name: in String): String {
  for f in fields {
    if f.name == name {
      return f.value
    }
  }
  ""
}

/// One call on a fresh connection with exactly the headers `extra` adds to a
/// well-formed gRPC request, and `body` as the request (already framed).
func rawCall(port: in Int, path: in String, extra: in List[HeaderField], body: in slice[Byte]): Raw {
  val r = Raw(status = -1, message = "", headers = newList(), messages = 0, failure = "", elapsedMs = 0i64)
  val started = Std.Time.nowEpochMillis()
  match h2Connect(H2Plain(host = "127.0.0.1", port = port), h2ClientDefaults()) {
    case Std.Core.Err(e) -> {
      r.failure = "connect: " + H2DialError.message(e)
    }
    case Std.Core.Ok(conn) -> {
      val hs: List[HeaderField] = newList()
      hs.add(HeaderField(name = ":method", value = "POST"))
      hs.add(HeaderField(name = ":scheme", value = "http"))
      hs.add(HeaderField(name = ":path", value = path))
      hs.add(HeaderField(name = ":authority", value = "127.0.0.1:" + port.toString()))
      hs.add(HeaderField(name = "content-type", value = "application/grpc"))
      hs.add(HeaderField(name = "te", value = "trailers"))
      for f in extra {
        hs.add(f)
      }
      match h2StartCall(conn, hs, false, 20000) {
        case Std.Core.Err(_) -> {
          r.failure = "start"
        }
        case Std.Core.Ok(call) -> {
          val _ = h2SendBody(call, body, true)
          val reader = newMessageReader(67108864)
          var running = true
          while running {
            match h2NextEvent(call) {
              case H2CallHeaders(_, headers) -> {
                for f in headers {
                  r.headers.add(f)
                }
              }
              case H2CallData(d) -> {
                readerFeed(reader, d)
                var more = true
                while more {
                  match readerPoll(reader) {
                    case WireMessage(_, _) -> {
                      r.messages = r.messages + 1
                    }
                    case _ -> {
                      more = false
                    }
                  }
                }
              }
              case H2CallTrailers(headers) -> {
                for f in headers {
                  r.headers.add(f)
                }
              }
              case H2CallEnded -> {
                running = false
              }
              case H2CallFailed(f) -> {
                r.failure = H2CallFailure.message(f)
                running = false
              }
              case _ -> ()
            }
          }
        }
      }
      h2Close(conn)
    }
  }
  val s = headerOf(r.headers, "grpc-status")
  if s != "" {
    r.status = parseInt(s)
  }
  r.message = headerOf(r.headers, "grpc-message")
  r.elapsedMs = Std.Time.nowEpochMillis() - started
  r
}

func fields(pairs: in List[String]): List[HeaderField] {
  val acc: List[HeaderField] = newList()
  var i = 0
  while i + 1 < pairs.count {
    acc.add(HeaderField(name = pairs[i], value = pairs[i + 1]))
    i = i + 2
  }
  acc
}

func noFields(): List[HeaderField] {
  val acc: List[HeaderField] = newList()
  acc
}

// ─── Request compression ─────────────────────────────────────────────────────
test "compression: a gzip request message is decoded before the handler sees it" {
  val server = startPlain()
  val ch = openOk(addressOf(server, "http"))
  val payload = repeated(100000, 7)
  match Grpc.callUnary(ch, "t", "Echo", payload, Grpc.withCompression(Grpc.defaultOptions(), GrpcCompression.Gzip)) {
    case Std.Core.Ok(r) -> {
      assertEqualInt(r.length, 100000, "the handler echoed the whole decompressed message")
      assertEqualInt(r[99999].toInt(), payload[99999].toInt(), "and the bytes are intact")
    }
    case Std.Core.Err(st) -> assertTrue(false, "gzip call failed: " + st.message)
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "compression: a gzip request over the limit once decompressed is RESOURCE_EXHAUSTED, and never reaches the handler" {
  val server = startPlain()
  val bomb = Wire.frameMessage(Wire.compressMessage(repeated(5000000, 0)), true)
  val r = rawCall(Grpc.serverPort(server), "/t/Length", fields(["grpc-encoding", "gzip"]), bomb)
  assertEqualInt(r.status, 8, "RESOURCE_EXHAUSTED: " + r.message + r.failure)
  assertEqualInt(probe.lastLength, -1, "the handler was not called")
  Grpc.stop(server, 1000)
}

test "compression: an unknown grpc-encoding is UNIMPLEMENTED and lists what is supported" {
  val server = startPlain()
  val r = rawCall(
    Grpc.serverPort(server),
    "/t/Echo",
    fields(["grpc-encoding", "br"]),
    Wire.frameMessage(bytesOf([1]), false)
  )
  assertEqualInt(r.status, 12, "UNIMPLEMENTED: " + r.failure)
  assertEqual(headerOf(r.headers, "grpc-accept-encoding"), "identity,gzip", "grpc-accept-encoding")
  Grpc.stop(server, 1000)
}

test "compression: a compressed flag with no grpc-encoding, and a body that is not gzip, are INTERNAL" {
  val server = startPlain()
  val noEncoding = rawCall(Grpc.serverPort(server), "/t/Echo", noFields(), Wire.frameMessage(bytesOf([1, 2, 3]), true))
  assertEqualInt(noEncoding.status, 13, "flag without encoding: " + noEncoding.message + noEncoding.failure)
  val garbage = rawCall(
    Grpc.serverPort(server),
    "/t/Echo",
    fields(["grpc-encoding", "gzip"]),
    Wire.frameMessage(bytesOf([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]), true)
  )
  assertEqualInt(garbage.status, 13, "not gzip: " + garbage.message + garbage.failure)
  assertEqualInt(probe.lastLength, -1, "no handler ran")
  Grpc.stop(server, 1000)
}

test "compression: a message of exactly 4 MiB is served, one byte more is RESOURCE_EXHAUSTED" {
  val server = startPlain()
  val ch = openOk(addressOf(server, "http"))
  assertEqual(callText(ch, "Length", repeated(4194304, 1), Grpc.defaultOptions()), "4194304", "4 MiB is accepted")
  val over = rawCall(Grpc.serverPort(server), "/t/Length", noFields(), Wire.frameMessage(repeated(4194305, 1), false))
  assertEqualInt(over.status, 8, "4 MiB + 1: " + over.message + over.failure)
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

// ─── grpc-timeout ────────────────────────────────────────────────────────────
test "deadline: the server ends a unary call at grpc-timeout while the handler is still running" {
  val server = startPlain()
  val r = rawCall(
    Grpc.serverPort(server),
    "/t/Slow",
    fields(["grpc-timeout", "250m"]),
    Wire.frameMessage(bytesOf([1]), false)
  )
  assertEqualInt(r.status, 4, "DEADLINE_EXCEEDED: " + r.message + r.failure)
  assertTrue(
    r.elapsedMs >= 200i64 and r.elapsedMs < 1000i64,
    "answered at the deadline, not after the handler: " + r.elapsedMs.toString() + " ms"
  )
  assertFalse(probe.slowDone, "the handler had not finished when the call ended")
  assertTrue(waitFor(5000, { -> probe.slowDone }), "the handler runs to completion in the background")
  val ch = openOk(addressOf(server, "http"))
  assertEqual(
    callText(ch, "Echo", bytesOf([9]), Grpc.defaultOptions()).length.toString(),
    "1",
    "the server keeps serving"
  )
  Grpc.closeChannel(ch)
  Grpc.stop(server, 2000)
}

test "deadline: a streaming call ends at grpc-timeout, after some messages, and emit starts returning false" {
  val server = startPlain()
  val r = rawCall(
    Grpc.serverPort(server),
    "/t/Ticker",
    fields(["grpc-timeout", "400m"]),
    Wire.frameMessage(bytesOf([1]), false)
  )
  assertEqualInt(r.status, 4, "DEADLINE_EXCEEDED: " + r.message + r.failure)
  assertTrue(r.messages >= 3 and r.messages < 20, "some messages arrived first: " + r.messages.toString())
  assertTrue(
    r.elapsedMs >= 350i64 and r.elapsedMs < 2000i64,
    "ended near the deadline: " + r.elapsedMs.toString() + " ms"
  )
  assertTrue(waitFor(3000, { -> probe.sawCancel }), "the handler saw emit return false")
  assertTrue(probe.ticks < 30, "and stopped producing")
  Grpc.stop(server, 2000)
}

test "deadline: a call that finishes before its deadline is not touched by it" {
  val server = startPlain()
  val r = rawCall(
    Grpc.serverPort(server),
    "/t/Echo",
    fields(["grpc-timeout", "5S"]),
    Wire.frameMessage(bytesOf([1, 2]), false)
  )
  assertEqualInt(r.status, 0, "OK: " + r.message + r.failure)
  assertEqualInt(r.messages, 1, "one message")
  assertTrue(r.elapsedMs < 2000i64, "no waiting for the deadline")
  Grpc.stop(server, 1000)
}

test "deadline: the handler sees the time left, and none when the caller set no deadline" {
  val server = startPlain()
  val ch = openOk(addressOf(server, "http"))
  assertEqual(callText(ch, "Timeout", bytesOf([1]), Grpc.defaultOptions()), "none", "no deadline")
  val withDeadline = callText(ch, "Timeout", bytesOf([1]), Grpc.withTimeout(Grpc.defaultOptions(), 5000))
  val left = parseLong(withDeadline)
  assertTrue(left > 0i64 and left <= 5000i64, "time left is within the 5 s the client sent: " + withDeadline)
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "deadline: a client deadline shorter than the handler is DEADLINE_EXCEEDED from both ends" {
  val server = startPlain()
  val ch = openOk(addressOf(server, "http"))
  val started = Std.Time.nowEpochMillis()
  match Grpc.callUnary(ch, "t", "Slow", bytesOf([1]), Grpc.withTimeout(Grpc.defaultOptions(), 300)) {
    case Std.Core.Ok(_) -> assertTrue(false, "expected DEADLINE_EXCEEDED")
    case Std.Core.Err(st) -> assertEqualInt(codeOf(st), 4, "DEADLINE_EXCEEDED: " + st.message)
  }
  assertTrue(Std.Time.nowEpochMillis() - started < 1100i64, "the call did not wait for the handler")
  Grpc.closeChannel(ch)
  Grpc.stop(server, 2000)
}

test "deadline: a malformed grpc-timeout is INTERNAL and no handler runs" {
  val server = startPlain()
  val r = rawCall(
    Grpc.serverPort(server),
    "/t/Length",
    fields(["grpc-timeout", "soon"]),
    Wire.frameMessage(bytesOf([1]), false)
  )
  assertEqualInt(r.status, 13, "INTERNAL: " + r.message + r.failure)
  assertEqualInt(probe.lastLength, -1, "the handler was not called")
  Grpc.stop(server, 1000)
}

// ─── Panic isolation ─────────────────────────────────────────────────────────
test "panic: a unary handler panic is INTERNAL without its text, repeatedly, and the connection survives" {
  val server = startPlain()
  val ch = openOk(addressOf(server, "http"))
  var i = 0
  while i < 10 {
    match Grpc.callUnary(ch, "t", "Boom", bytesOf([1]), Grpc.defaultOptions()) {
      case Std.Core.Ok(_) -> assertTrue(false, "expected INTERNAL")
      case Std.Core.Err(st) -> {
        assertEqualInt(codeOf(st), 13, "INTERNAL on attempt " + i.toString())
        assertFalse(st.message.contains("secret"), "the panic text is not leaked")
      }
    }
    i = i + 1
  }
  assertEqual(
    callText(ch, "Echo", bytesOf([7]), Grpc.defaultOptions()).length.toString(),
    "1",
    "the same channel still works"
  )
  assertEqualInt(trackedConnections(server), 1, "on one connection")
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "panic: a streaming handler that panics after a message ends the stream INTERNAL, text withheld" {
  val server = startPlain()
  val r = rawCall(Grpc.serverPort(server), "/t/BoomStream", noFields(), Wire.frameMessage(bytesOf([1]), false))
  assertEqualInt(r.messages, 1, "the message sent before the panic arrived")
  assertEqualInt(r.status, 13, "INTERNAL: " + r.message + r.failure)
  assertFalse(r.message.contains("secret"), "the panic text is not leaked")
  val ch = openOk(addressOf(server, "http"))
  assertEqual(
    callText(ch, "Echo", bytesOf([7]), Grpc.defaultOptions()).length.toString(),
    "1",
    "the server still serves"
  )
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "panic: concurrent panicking and healthy calls do not disturb each other" {
  val server = startPlain()
  val ch = openOk(addressOf(server, "http"))
  val done = newSem(0)
  val results: List[Bool] = newList()
  var i = 0
  while i < 12 {
    val bad = i % 2 == 0
    startTask(
      { ->
        runGuarded(
          { ->
            val method = if bad { "Boom" } else { "Echo" }
            val outcome = match Grpc.callUnary(ch, "t", method, bytesOf([1]), Grpc.defaultOptions()) {
              case Std.Core.Ok(_) -> not bad
              case Std.Core.Err(st) -> bad and codeOf(st) == 13
            }
            lock(resultsGuard)
            results.add(outcome)
            unlock(resultsGuard)
          },
          { _ -> () }
        )
        semPost(done)
      }
    )
    i = i + 1
  }
  var joined = 0
  var waited = 0
  while joined < 12 and waited < 30000 {
    if semTryWait(done) {
      joined = joined + 1
    } else {
      sleepMillis(5)
      waited = waited + 5
    }
  }
  assertEqualInt(joined, 12, "every call finished")
  var good = 0
  for ok in results {
    if ok {
      good = good + 1
    }
  }
  assertEqualInt(good, 12, "every call got its own answer")
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

// ─── Concurrency and drain ───────────────────────────────────────────────────
test "stop: a call in flight is allowed to finish within the drain time" {
  val server = startPlain()
  val ch = openOk(addressOf(server, "http"))
  val outcome: Probe = Probe(slowDone = false, ticks = 0, sawCancel = false, lastLength = -1)
  startTask(
    { ->
      runGuarded(
        { ->
          match Grpc.callUnary(ch, "t", "Drain", bytesOf([4, 5]), Grpc.defaultOptions()) {
            case Std.Core.Ok(r) -> {
              outcome.lastLength = r.length
            }
            case Std.Core.Err(st) -> {
              outcome.lastLength = -100 - codeOf(st)
            }
          }
          outcome.slowDone = true
        },
        { _ -> outcome.slowDone = true }
      )
    }
  )
  sleepMillis(200)
  val started = Std.Time.nowEpochMillis()
  Grpc.stop(server, 5000)
  val took = Std.Time.nowEpochMillis() - started
  assertTrue(waitFor(5000, { -> outcome.slowDone }), "the call returned")
  assertEqualInt(outcome.lastLength, 2, "with its answer, not a cancellation")
  assertTrue(
    took >= 300i64 and took < 4000i64,
    "stop waited for the handler, not the full drain time: " + took.toString() + " ms"
  )
  Grpc.closeChannel(ch)
}

test "stop: a client is sent GOAWAY at once, and the call it has in flight still completes" {
  val server = startPlain()
  match h2Connect(H2Plain(host = "127.0.0.1", port = Grpc.serverPort(server)), h2ClientDefaults()) {
    case Std.Core.Err(e) -> assertTrue(false, "connect: " + H2DialError.message(e))
    case Std.Core.Ok(conn) -> {
      val hs = fields(
        [
          ":method",
          "POST",
          ":scheme",
          "http",
          ":path",
          "/t/Drain",
          ":authority",
          "127.0.0.1",
          "content-type",
          "application/grpc",
          "te",
          "trailers"
        ]
      )
      match h2StartCall(conn, hs, false, 20000) {
        case Std.Core.Err(_) -> assertTrue(false, "start")
        case Std.Core.Ok(call) -> {
          val _ = h2SendBody(call, Wire.frameMessage(bytesOf([1]), false), true)
          sleepMillis(150)
          startTask({ -> runGuarded({ -> Grpc.stop(server, 5000) }, { _ -> () }) })
          assertTrue(
            waitFor(1500, { -> h2ClientStatus(conn) == H2ClientDraining }),
            "the client received GOAWAY while its call was running"
          )
          var grpcStatus = ""
          var running = true
          while running {
            match h2NextEvent(call) {
              case H2CallTrailers(headers) -> {
                grpcStatus = headerOf(headers, "grpc-status")
              }
              case H2CallEnded -> {
                running = false
              }
              case H2CallFailed(f) -> {
                grpcStatus = "failed: " + H2CallFailure.message(f)
                running = false
              }
              case _ -> ()
            }
          }
          assertEqual(grpcStatus, "0", "the call in flight finished OK")
        }
      }
      h2Close(conn)
    }
  }
}

test "stop: with no drain time a call in flight is cut off, and the port is released" {
  val server = startPlain()
  val port = Grpc.serverPort(server)
  val ch = openOk(addressOf(server, "http"))
  val outcome: Probe = Probe(slowDone = false, ticks = 0, sawCancel = false, lastLength = 0)
  startTask(
    { ->
      runGuarded(
        { ->
          match Grpc.callUnary(ch, "t", "Slow", bytesOf([1]), Grpc.defaultOptions()) {
            case Std.Core.Ok(_) -> {
              outcome.lastLength = 1
            }
            case Std.Core.Err(st) -> {
              outcome.lastLength = -codeOf(st)
            }
          }
          outcome.slowDone = true
        },
        { _ -> outcome.slowDone = true }
      )
    }
  )
  sleepMillis(200)
  Grpc.stop(server, 0)
  assertTrue(waitFor(5000, { -> outcome.slowDone }), "the call returned")
  assertEqualInt(outcome.lastLength, -14, "UNAVAILABLE: the connection was closed under it")
  assertEqualInt(Grpc.serverPort(server), 0, "serverPort is 0 after stop")
  assertTrue(port > 0, "it had a port")
  Grpc.closeChannel(ch)
}

test "concurrency: calls on one connection run in parallel" {
  val server = startPlain()
  val ch = openOk(addressOf(server, "http"))
  val done = newSem(0)
  val started = Std.Time.nowEpochMillis()
  var i = 0
  while i < 8 {
    startTask(
      { ->
        runGuarded({ -> val _ = Grpc.callUnary(ch, "t", "Drain", bytesOf([1]), Grpc.defaultOptions()) }, { _ -> () })
        semPost(done)
      }
    )
    i = i + 1
  }
  var joined = 0
  var waited = 0
  while joined < 8 and waited < 30000 {
    if semTryWait(done) {
      joined = joined + 1
    } else {
      sleepMillis(5)
      waited = waited + 5
    }
  }
  assertEqualInt(joined, 8, "every call finished")
  assertTrue(Std.Time.nowEpochMillis() - started < 3000i64, "eight 600 ms handlers ran together, not one after another")
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

// ─── TLS ─────────────────────────────────────────────────────────────────────
func tlsConfig(): TlsServerConfig {
  val id = match Identity.fromPem(serverCertPem, serverKeyPem) {
    case Std.Core.Ok(i) -> i
    case Std.Core.Err(e) -> panic("test identity: " + TlsError.message(e))
  }
  TlsServerConfig(identity = id)
}

func startTlsServer(): GrpcServerHandle {
  resetProbe()
  Grpc.startHandleTlsAt(buildRegistry(), "127.0.0.1", 0, tlsConfig())
}

test "tls: a client that pins the CA reaches the server over ALPN h2: unary, streaming, compression" {
  val server = startTlsServer()
  val o = Grpc.defaultChannelOptions()
  o.trust = TlsTrustExclusive(caPem = caCertPem)
  val ch = openWith(addressOf(server, "https"), o)
  assertEqual(callText(ch, "Echo", bytesOf([1, 2, 3]), Grpc.defaultOptions()).length.toString(), "3", "unary")
  val gz = Grpc.withCompression(Grpc.defaultOptions(), GrpcCompression.Gzip)
  assertEqual(callText(ch, "Length", repeated(50000, 3), gz), "50000", "gzip request over TLS")
  match Grpc.openServerStream(ch, "t", "Ticker", bytesOf([1]), Grpc.withTimeout(Grpc.defaultOptions(), 5000)) {
    case Std.Core.Err(st) -> assertTrue(false, "stream failed to open: " + st.message)
    case Std.Core.Ok(stream) -> {
      var got = 0
      while got < 3 {
        match Grpc.nextMessage(stream) {
          case Std.Core.Ok(Some(_)) -> {
            got = got + 1
          }
          case _ -> {
            got = 99
          }
        }
      }
      assertEqualInt(got, 3, "three streamed messages over TLS")
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
  Grpc.stop(server, 2000)
}

test "tls: an untrusted certificate and a plaintext client are both UNAVAILABLE, and the server survives" {
  val server = startTlsServer()
  val untrusted = openOk(addressOf(server, "https"))
  match Grpc.callUnary(untrusted, "t", "Echo", bytesOf([1]), Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> assertTrue(false, "the test CA is not in the system trust store")
    case Std.Core.Err(st) -> assertEqualInt(codeOf(st), 14, "untrusted: UNAVAILABLE")
  }
  Grpc.closeChannel(untrusted)
  val plain = openOk(addressOf(server, "http"))
  match Grpc.callUnary(plain, "t", "Echo", bytesOf([1]), Grpc.withTimeout(Grpc.defaultOptions(), 3000)) {
    case Std.Core.Ok(_) -> assertTrue(false, "plaintext must not be served on a TLS port")
    case Std.Core.Err(st) -> assertTrue(
      codeOf(st) == 14 or codeOf(st) == 4,
      "plaintext: UNAVAILABLE or DEADLINE_EXCEEDED, got " + st.message
    )
  }
  Grpc.closeChannel(plain)
  val o = Grpc.defaultChannelOptions()
  o.trust = TlsTrustExclusive(caPem = caCertPem)
  val ch = openWith(addressOf(server, "https"), o)
  assertEqual(
    callText(ch, "Echo", bytesOf([1, 2]), Grpc.defaultOptions()).length.toString(),
    "2",
    "a good client is still served"
  )
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "tls: the deadline and panic rules hold over TLS" {
  val server = startTlsServer()
  val o = Grpc.defaultChannelOptions()
  o.trust = TlsTrustExclusive(caPem = caCertPem)
  val ch = openWith(addressOf(server, "https"), o)
  match Grpc.callUnary(ch, "t", "Boom", bytesOf([1]), Grpc.defaultOptions()) {
    case Std.Core.Ok(_) -> assertTrue(false, "expected INTERNAL")
    case Std.Core.Err(st) -> assertEqualInt(codeOf(st), 13, "INTERNAL")
  }
  assertTrue(
    Str.startsWith(callText(ch, "Timeout", bytesOf([1]), Grpc.withTimeout(Grpc.defaultOptions(), 4000)), "ERR") == false,
    "timeout metadata over TLS"
  )
  Grpc.closeChannel(ch)
  Grpc.stop(server, 1000)
}

test "tls: mutual TLS without a client CA is refused when the server starts, not on every handshake" {
  val cfg = TlsServerConfig(identity = tlsConfig().identity, requireClientCert = true)
  assertPanics(
    "startHandleTlsAt with requireClientCert and no clientCa",
    { -> val _ = Grpc.startHandleTlsAt(buildRegistry(), "127.0.0.1", 0, cfg) }
  )
}
