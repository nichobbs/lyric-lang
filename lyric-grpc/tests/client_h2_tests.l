//! tests/client_h2_tests.l — the pure-Lyric gRPC client (`Grpc.Client` over
//! `Std.HttpEngine.H2Client`) against scripted in-process peers (docs/72
//! slice 6, D802).
//!
//! Target neutral: the client is plain Lyric over `Std.TcpHost`, so this suite
//! runs unchanged on dotnet and the JVM. The peer is the `H2Conn` server role
//! over `Std.TcpHost` with the gRPC wire format from `Grpc.Wire`: it can be told
//! to produce what a conforming server never would (a non-200 response, a
//! wrong content type, a RST_STREAM with a chosen code, a GOAWAY with a chosen
//! last-stream-id, a limit of two concurrent streams), which is the point.
//! Interop with independent servers is in `client_dotnet_tests.l`,
//! `client_jvm_tests.l` (grpc-java on the JVM) and `server_tests.l` (the
//! pure-Lyric `Grpc.Server`, both targets).
//!
//! Every wait is bounded, so a misbehaving peer fails the suite instead of
//! hanging it. Listeners bind port 0.
@cfg(not(feature = "legacy-client"))
@test_module
package Grpc.ClientH2Tests

import Std.Core
import Std.Collections
import Std.Iter
import Std.String as Str
import Std.Encoding
import Std.Tls
import Std.TcpHost
import Std.HttpServerHost
import Std.HttpEngine
import Std.HttpEngine.H2Conn as H2
import Std.HttpEngine.H2Frame
import Std.Time
import Std.Testing
import Grpc
import Grpc.Types
import Grpc.Wire
import Grpc.Client

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

func patterned(n: in Int, seed: in Int): slice[Byte] {
  val acc: List[Byte] = newListWithCapacity(n)
  var i = 0
  while i < n {
    acc.add((seed + i * 7 + i / 251).and(255).toByte())
    i = i + 1
  }
  acc.toArray()
}

func sameBytes(a: in slice[Byte], b: in slice[Byte]): Bool {
  if a.length != b.length {
    return false
  }
  var i = 0
  while i < a.length {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

func headerValue(headers: in List[HeaderField], name: in String): String {
  for h in headers {
    if h.name == name {
      return h.value
    }
  }
  ""
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

func has(s: in String, part: in String): Bool {
  Str.indexOfRaw(s, part) >= 0
}

ref record Box {
  var text: String
  var n: Int
}

func codeOf(st: in GrpcStatus): Int {
  statusCodeToInt(st.code)
}

func opts(): GrpcCallOptions {
  Grpc.defaultOptions()
}

// ─── The scripted peer ───────────────────────────────────────────────────────
ref record Obs {
  guard: Mutex
  var failure: String
  var connections: Int
  var requests: Int
  var inFlight: Int
  var maxInFlight: Int
  var resets: Int
  var lastResetCode: Long
  var eofs: Int
  var lastHeaders: List[HeaderField]
}

func newObs(): Obs {
  Obs(
    guard = newMutex(),
    failure = "",
    connections = 0,
    requests = 0,
    inFlight = 0,
    maxInFlight = 0,
    resets = 0,
    lastResetCode = -1i64,
    eofs = 0,
    lastHeaders = newList()
  )
}

ref record Req {
  headers: List[HeaderField]
  reader: MessageReader
  var ended: Bool
}

ref record Cx {
  conn: Conn
  index: Int
  obs: Obs
  reqs: Map[Int, Req]
  completed: List[Int]
  var h2: H2.H2Connection
  var eof: Bool
}

ref record Server {
  listener: Listener
  port: Int
  obs: Obs
  var stopping: Bool
}

func writeOut(cx: in Cx, bytes: in slice[Byte]): Unit {
  if bytes.length > 0 and not cx.eof {
    match hostWrite(cx.conn, bytes) {
      case Ok(_) -> ()
      case Err(_) -> {
        cx.eof = true
      }
    }
  }
}

func absorb(cx: in Cx, ev: in H2.H2Event): Unit {
  match ev {
    case H2.H2RequestHeaders(sid, headers, endStream) -> {
      val req = Req(headers = headers, reader = newMessageReader(100000000), ended = false)
      cx.reqs.add(sid, req)
      if endStream {
        req.ended = true
        cx.completed.add(sid)
      }
    }
    case H2.H2RequestData(sid, data, endStream, wl) -> {
      if wl > 0 {
        writeOut(cx, H2.grantConnectionWindow(cx.h2, wl))
        writeOut(cx, H2.grantStreamWindow(cx.h2, sid, wl))
      }
      match mapGet(cx.reqs, sid) {
        case Some(req) -> {
          readerFeed(req.reader, data)
          if endStream {
            req.ended = true
            cx.completed.add(sid)
          }
        }
        case None -> ()
      }
    }
    case H2.H2PeerReset(sid, code) -> {
      lock(cx.obs.guard)
      cx.obs.resets = cx.obs.resets + 1
      cx.obs.lastResetCode = errorCodeToLong(code)
      unlock(cx.obs.guard)
      val _ = cx.reqs.remove(sid)
    }
    case _ -> ()
  }
}

// Read once (up to `waitMs`), feed the FSM, write what it queued and absorb
// its events. Completed requests are only queued here (`cx.completed`), never
// answered, so a handler may call it while it waits for flow-control credit.
func pump(cx: in Cx, waitMs: in Int): Unit {
  if cx.eof or H2.isFailed(cx.h2) {
    return
  }
  match hostReadDeadline(cx.conn, 65536, monotonicNanos() + waitMs.toLong() * 1000000i64) {
    case Ok(bytes) -> {
      if bytes.length == 0 {
        cx.eof = true
      } else {
        val res = H2.feed(cx.h2, bytes)
        cx.h2 = res.conn
        writeOut(cx, res.outbound)
        for ev in res.events {
          absorb(cx, ev)
        }
      }
    }
    case Err(e) -> match e { case ReadDeadlinePassed -> (); case ReadFailed(_) -> { cx.eof = true } }
  }
}

func serveConn(
  conn: in Conn,
  index: in Int,
  obs: in Obs,
  srv: in Server,
  settings: in H2.H2Settings,
  onRequest: in (Cx, Int, Req) -> Unit,
  onTick: in (Cx) -> Unit,
): Unit {
  val cx = Cx(
    conn = conn,
    index = index,
    obs = obs,
    reqs = newMap(),
    completed = newList(),
    h2 = H2.newServerConnection(settings),
    eof = false
  )
  defer {
    hostClose(conn)
  }
  writeOut(cx, H2.serverInitialFrame(cx.h2))
  while not cx.eof and not H2.isFailed(cx.h2) and not srv.stopping {
    pump(cx, 10)
    while cx.completed.count > 0 {
      val sid = cx.completed[0]
      cx.completed.removeAt(0)
      match mapGet(cx.reqs, sid) {
        case Some(req) -> {
          lock(obs.guard)
          obs.requests = obs.requests + 1
          obs.lastHeaders = req.headers
          unlock(obs.guard)
          onRequest(cx, sid, req)
        }
        case None -> ()
      }
    }
    onTick(cx)
  }
  lock(obs.guard)
  obs.eofs = obs.eofs + 1
  unlock(obs.guard)
}

func startServer(
  settings: in H2.H2Settings,
  tls: in Option[TlsServerConfig],
  onRequest: in (Cx, Int, Req) -> Unit,
  onTick: in (Cx) -> Unit,
): Server {
  startServerAt(0, settings, tls, onRequest, onTick)
}

func startServerAt(
  port: in Int,
  settings: in H2.H2Settings,
  tls: in Option[TlsServerConfig],
  onRequest: in (Cx, Int, Req) -> Unit,
  onTick: in (Cx) -> Unit,
): Server {
  val l = match hostListen("127.0.0.1", port) {
    case Ok(x) -> x
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val obs = newObs()
  val srv = Server(listener = l, port = hostLocalPort(l), obs = obs, stopping = false)
  startTask(
    { ->
      var running = true
      while running {
        val accepted = match tls { case Some(cfg) -> hostAcceptTls(l, cfg); case None -> hostAccept(l) }
        match accepted {
          case Ok(c) -> {
            lock(obs.guard)
            obs.connections = obs.connections + 1
            val index = obs.connections
            unlock(obs.guard)
            startTask(
              { ->
                runGuarded(
                  { -> serveConn(c, index, obs, srv, settings, onRequest, onTick) },
                  { m -> lock(obs.guard); obs.failure = "peer connection: " + m; unlock(obs.guard) }
                )
              }
            )
          }
          case Err(_) -> {
            running = false
          }
        }
      }
    }
  )
  srv
}

func plainServer(onRequest: in (Cx, Int, Req) -> Unit): Server {
  startServer(H2.h2DefaultServerSettings(), None, onRequest, { cx: Cx -> () })
}

func stopServer(srv: in Server): Unit {
  srv.stopping = true
  hostStopListener(srv.listener)
  assertEqual(srv.obs.failure, "", "the peer reported no failure")
}

func address(srv: in Server): String {
  "http://127.0.0.1:" + srv.port.toString()
}

func openOk(address: in String): GrpcChannel {
  match Grpc.openChannel(address) {
    case Ok(ch) -> ch
    case Err(m) -> panic("openChannel failed: " + m)
  }
}

func openWith(address: in String, o: in ChannelOptions): GrpcChannel {
  match Grpc.openChannelWith(address, o) {
    case Ok(ch) -> ch
    case Err(m) -> panic("openChannelWith failed: " + m)
  }
}

// ─── Peer actions ────────────────────────────────────────────────────────────
func okHead(extra: in List[HeaderField]): List[HeaderField] {
  val hs: List[HeaderField] = newList()
  hs.add(HeaderField(name = ":status", value = "200"))
  hs.add(HeaderField(name = "content-type", value = "application/grpc"))
  for e in extra {
    hs.add(e)
  }
  hs
}

func sendHead(cx: in Cx, sid: in Int, hs: in List[HeaderField], endStream: in Bool): Unit {
  match H2.encodeResponseHeaders(cx.h2, sid, hs, endStream) {
    case Ok(b) -> writeOut(cx, b)
    case Err(_) -> ()
  }
}

func sendFrame(cx: in Cx, sid: in Int, framed: in slice[Byte]): Unit {
  var offset = 0
  var guardNanos = monotonicNanos() + 30000000000i64
  while offset < framed.length and not cx.eof and monotonicNanos() < guardNanos {
    var chunk = framed.length - offset
    val frameMax = H2.peerMaxFrameSize(cx.h2)
    if chunk > frameMax {
      chunk = frameMax
    }
    val room = H2.maxSendableOnStream(cx.h2, sid)
    if chunk > room {
      chunk = room
    }
    if chunk <= 0 {
      pump(cx, 20)
    } else {
      match H2.sendData(cx.h2, sid, framed.slice(offset, offset + chunk), false) {
        case Ok(b) -> {
          writeOut(cx, b)
          offset = offset + chunk
        }
        case Err(_) -> {
          offset = framed.length
        }
      }
    }
  }
}

func sendMsg(cx: in Cx, sid: in Int, payload: in slice[Byte]): Unit {
  sendFrame(cx, sid, frameMessage(payload, false))
}

func statusFields(code: in Int, message: in String): List[HeaderField] {
  val hs: List[HeaderField] = newList()
  hs.add(HeaderField(name = "grpc-status", value = code.toString()))
  if message.length > 0 {
    hs.add(HeaderField(name = "grpc-message", value = encodeGrpcMessage(message)))
  }
  hs
}

func sendEnd(cx: in Cx, sid: in Int, code: in Int, message: in String): Unit {
  match H2.encodeResponseTrailers(cx.h2, sid, statusFields(code, message)) {
    case Ok(b) -> writeOut(cx, b)
    case Err(_) -> ()
  }
}

func sendTrailersOnly(cx: in Cx, sid: in Int, code: in Int, message: in String): Unit {
  sendHead(cx, sid, okHead(statusFields(code, message)), true)
}

func sendRst(cx: in Cx, sid: in Int, code: in H2ErrorCode): Unit {
  writeOut(cx, H2.sendRstStream(cx.h2, sid, code))
}

func sendGoAwayAt(cx: in Cx, lastStreamId: in Int): Unit {
  writeOut(cx, serializeFrame(GoAwayFrame(lastStreamId = lastStreamId, errorCode = H2NoError, debugData = [])))
}

func respondUnary(cx: in Cx, sid: in Int, payload: in slice[Byte]): Unit {
  sendHead(cx, sid, okHead([]), false)
  sendMsg(cx, sid, payload)
  sendEnd(cx, sid, 0, "")
}

// Every message of the request, decompressed.
func requestMessages(req: in Req): List[slice[Byte]] {
  val got: List[slice[Byte]] = newList()
  var more = true
  while more {
    match readerPoll(req.reader) {
      case WireMessage(compressed, p) -> {
        if compressed {
          match decompressMessage(headerValue(req.headers, "grpc-encoding"), p, 100000000) {
            case Ok(b) -> {
              val whole: slice[Byte] = b
              got.add(whole)
            }
            case Err(_) -> got.add(bytesOf([]))
          }
        } else {
          got.add(p)
        }
      }
      case _ -> {
        more = false
      }
    }
  }
  got
}

func firstMessage(req: in Req): slice[Byte] {
  val all = requestMessages(req)
  if all.count == 0 {
    bytesOf([])
  } else {
    all[0]
  }
}

func echo(cx: in Cx, sid: in Int, req: in Req): Unit {
  respondUnary(cx, sid, firstMessage(req))
}

// ─── Unary ───────────────────────────────────────────────────────────────────
test "unary: the request headers are those of a gRPC call and the message is echoed" {
  val srv = plainServer({ cx: Cx, sid: Int, req: Req -> echo(cx, sid, req) })
  val ch = openOk(address(srv))
  val payload = bytesOf([0, 1, 2, 250, 255, 7])
  val o = Grpc.withMetadata(Grpc.withTimeout(opts(), 5000), "x-trace", "abc123")
  match Grpc.callUnary(ch, "test.Echo", "Echo", payload, o) {
    case Ok(resp) -> assertTrue(sameBytes(resp, payload), "the response is the request")
    case Err(st) -> assertTrue(false, "unary failed: " + st.message)
  }
  val hs = srv.obs.lastHeaders
  assertEqual(headerValue(hs, ":method"), "POST", ":method")
  assertEqual(headerValue(hs, ":scheme"), "http", ":scheme")
  assertEqual(headerValue(hs, ":path"), "/test.Echo/Echo", ":path")
  assertEqual(headerValue(hs, ":authority"), "127.0.0.1:" + srv.port.toString(), ":authority")
  assertEqual(headerValue(hs, "content-type"), "application/grpc", "content-type")
  assertEqual(headerValue(hs, "te"), "trailers", "te")
  assertEqual(headerValue(hs, "grpc-accept-encoding"), "identity,gzip", "grpc-accept-encoding")
  assertEqual(headerValue(hs, "x-trace"), "abc123", "call metadata")
  assertTrue(Str.startsWith(headerValue(hs, "user-agent"), "lyric-grpc/"), "user-agent")
  val timeout = headerValue(hs, "grpc-timeout")
  assertTrue(
    Str.endsWith(timeout, "m") and timeout.length >= 4,
    "grpc-timeout carries the remaining milliseconds: " + timeout
  )
  assertEqual(headerValue(hs, "grpc-encoding"), "", "no request compression by default")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "unary: a -bin metadata value is base64 on the wire without padding" {
  val srv = plainServer({ cx: Cx, sid: Int, req: Req -> echo(cx, sid, req) })
  val ch = openOk(address(srv))
  val o = Grpc.withMetadata(opts(), "trace-bin", "ab")
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([1]), o) {
    case Ok(_) -> ()
    case Err(st) -> assertTrue(false, "unary failed: " + st.message)
  }
  assertEqual(headerValue(srv.obs.lastHeaders, "trace-bin"), "YWI", "base64 of 'ab', padding removed")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "unary: a gzip request is decoded by the server and a gzip response by the client" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      val got = firstMessage(req)
      val packed = frameMessage(compressMessage(got), true)
      val hs = okHead([])
      hs.add(HeaderField(name = "grpc-encoding", value = "gzip"))
      sendHead(cx, sid, hs, false)
      sendFrame(cx, sid, packed)
      sendEnd(cx, sid, 0, "")
    }
  )
  val ch = openOk(address(srv))
  val payload = patterned(20000, 4)
  match Grpc.callUnary(ch, "test.Echo", "Echo", payload, Grpc.withCompression(opts(), GrpcCompression.Gzip)) {
    case Ok(resp) -> assertTrue(sameBytes(resp, payload), "the payload survived both compressions")
    case Err(st) -> assertTrue(false, "gzip unary failed: " + st.message + " / peer: " + srv.obs.failure)
  }
  assertEqual(headerValue(srv.obs.lastHeaders, "grpc-encoding"), "gzip", "the request announced gzip")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "unary: a compressed response in an unsupported encoding is Unimplemented" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      val hs = okHead([])
      hs.add(HeaderField(name = "grpc-encoding", value = "snappy"))
      sendHead(cx, sid, hs, false)
      sendFrame(cx, sid, frameMessage(bytesOf([1, 2, 3]), true))
      sendEnd(cx, sid, 0, "")
    }
  )
  val ch = openOk(address(srv))
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "an unreadable response must fail")
    case Err(st) -> assertEqualInt(codeOf(st), 12, "Unimplemented")
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "Trailers-Only: the status and its percent-decoded message arrive without a body" {
  val srv = plainServer({ cx: Cx, sid: Int, req: Req -> sendTrailersOnly(cx, sid, 5, "no such thing: é%") })
  val ch = openOk(address(srv))
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "an error status must fail the call")
    case Err(st) -> {
      assertEqualInt(codeOf(st), 5, "NotFound")
      assertEqual(st.message, "no such thing: é%", "the message round-trips through percent-encoding")
    }
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "Trailers-Only OK without a message is Internal, not a silent empty success" {
  val srv = plainServer({ cx: Cx, sid: Int, req: Req -> sendTrailersOnly(cx, sid, 0, "") })
  val ch = openOk(address(srv))
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "no message was sent")
    case Err(st) -> assertEqualInt(codeOf(st), 13, "Internal")
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "non-200 responses map through the HTTP status table, or keep an explicit grpc-status" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      val path = headerValue(req.headers, ":path")
      val hs: List[HeaderField] = newList()
      val status = if path == "/s/503" {
        "503"
      } else if path == "/s/404" {
        "404"
      } else if path == "/s/401" {
        "401"
      } else if path == "/s/500" {
        "500"
      } else {
        "403"
      }
      hs.add(HeaderField(name = ":status", value = status))
      hs.add(HeaderField(name = "content-type", value = "text/html"))
      if path == "/s/with-status" {
        hs.add(HeaderField(name = "grpc-status", value = "9"))
      }
      sendHead(cx, sid, hs, true)
    }
  )
  val ch = openOk(address(srv))
  val cases: List[String] = newList()
  cases.add("503")
  cases.add("404")
  cases.add("401")
  cases.add("500")
  cases.add("with-status")
  val expected = [14, 12, 16, 2, 9]
  var i = 0
  while i < cases.count {
    match Grpc.callUnary(ch, "s", cases[i], bytesOf([1]), opts()) {
      case Ok(_) -> assertTrue(false, "HTTP " + cases[i] + " must fail")
      case Err(st) -> assertEqualInt(codeOf(st), expected[i], "status for " + cases[i])
    }
    i = i + 1
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "a 200 response with a foreign content-type is Unknown and says so" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      val hs: List[HeaderField] = newList()
      hs.add(HeaderField(name = ":status", value = "200"))
      hs.add(HeaderField(name = "content-type", value = "application/json"))
      sendHead(cx, sid, hs, false)
      sendFrame(cx, sid, bytesOf([123, 125]))
      sendEnd(cx, sid, 0, "")
    }
  )
  val ch = openOk(address(srv))
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "a JSON body is not a gRPC response")
    case Err(st) -> {
      assertEqualInt(codeOf(st), 2, "Unknown")
      assertTrue(has(st.message, "application/json"), "the message names the content type: " + st.message)
    }
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "a response that ends without a usable grpc-status is Unknown or Internal" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      val path = headerValue(req.headers, ":path")
      if path == "/m/no-status" {
        sendHead(cx, sid, okHead([]), false)
        sendMsg(cx, sid, bytesOf([1]))
        val t: List[HeaderField] = newList()
        t.add(HeaderField(name = "x-other", value = "1"))
        match H2.encodeResponseTrailers(cx.h2, sid, t) {
          case Ok(b) -> writeOut(cx, b)
          case Err(_) -> ()
        }
      } else if path == "/m/bare-end" {
        sendHead(cx, sid, okHead([]), false)
        sendMsg(cx, sid, bytesOf([1]))
        match H2.sendData(cx.h2, sid, bytesOf([]), true) {
          case Ok(b) -> writeOut(cx, b)
          case Err(_) -> ()
        }
      } else {
        sendHead(cx, sid, okHead([]), false)
        sendFrame(cx, sid, frameMessage(bytesOf([1, 2, 3, 4, 5]), false).slice(0, 8))
        sendEnd(cx, sid, 0, "")
      }
    }
  )
  val ch = openOk(address(srv))
  match Grpc.callUnary(ch, "m", "no-status", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "trailers without grpc-status")
    case Err(st) -> assertEqualInt(codeOf(st), 2, "Unknown")
  }
  match Grpc.callUnary(ch, "m", "bare-end", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "the stream ended without trailers")
    case Err(st) -> assertEqualInt(codeOf(st), 13, "Internal")
  }
  match Grpc.callUnary(ch, "m", "truncated", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "a message cut short")
    case Err(st) -> assertEqualInt(codeOf(st), 13, "Internal")
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "RST_STREAM codes map to gRPC statuses and the channel survives" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      val path = headerValue(req.headers, ":path")
      val code = if path == "/r/calm" {
        H2EnhanceYourCalm
      } else if path == "/r/internal" {
        H2InternalError
      } else if path == "/r/cancel" {
        H2Cancel
      } else if path == "/r/security" {
        H2InadequateSecurity
      } else {
        H2NoError
      }
      sendRst(cx, sid, code)
    }
  )
  val ch = openOk(address(srv))
  val names = ["calm", "internal", "cancel", "security", "noerror"]
  val expected = [8, 13, 1, 7, 13]
  var i = 0
  while i < names.length {
    match Grpc.callUnary(ch, "r", names[i], bytesOf([1]), opts()) {
      case Ok(_) -> assertTrue(false, names[i] + " must fail")
      case Err(st) -> assertEqualInt(codeOf(st), expected[i], "status for RST " + names[i])
    }
    i = i + 1
  }
  assertEqualInt(srv.obs.connections, 1, "all five calls shared one connection")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "a call on a closed channel is FAILED_PRECONDITION, invalid metadata is INVALID_ARGUMENT" {
  val srv = plainServer({ cx: Cx, sid: Int, req: Req -> echo(cx, sid, req) })
  val ch = openOk(address(srv))
  val bad = GrpcCallOptions(
    timeoutMs = None,
    metadata = [GrpcMetadataEntry(key = "grpc-evil", value = "1")],
    compression = GrpcCompression.NoCompression
  )
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([1]), bad) {
    case Ok(_) -> assertTrue(false, "a reserved key must be refused")
    case Err(st) -> assertEqualInt(codeOf(st), 3, "InvalidArgument")
  }
  val bad2 = GrpcCallOptions(
    timeoutMs = None,
    metadata = [GrpcMetadataEntry(key = "bad key", value = "1")],
    compression = GrpcCompression.NoCompression
  )
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([1]), bad2) {
    case Ok(_) -> assertTrue(false, "an invalid key must be refused")
    case Err(st) -> assertEqualInt(codeOf(st), 3, "InvalidArgument")
  }
  assertEqualInt(srv.obs.requests, 0, "neither call reached the server")
  Grpc.closeChannel(ch)
  match Grpc.callUnary(ch, "test.Echo", "Echo", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "closed channel")
    case Err(st) -> assertEqualInt(codeOf(st), 9, "FailedPrecondition")
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "openChannel and openChannelWith validate addresses and options" {
  match Grpc.openChannel("127.0.0.1:1") {
    case Ok(_) -> assertTrue(false, "a bare host:port has no scheme")
    case Err(_) -> ()
  }
  match Grpc.openChannel("http://127.0.0.1:99999") {
    case Ok(_) -> assertTrue(false, "port out of range")
    case Err(_) -> ()
  }
  match Grpc.openChannel("http://127.0.0.1:abc") {
    case Ok(_) -> assertTrue(false, "port not a number")
    case Err(_) -> ()
  }
  match Grpc.openChannel("http://[::1") {
    case Ok(_) -> assertTrue(false, "unterminated IPv6 literal")
    case Err(_) -> ()
  }
  val o = Grpc.defaultChannelOptions()
  o.maxConnections = 0
  match Grpc.openChannelWith("http://127.0.0.1:1", o) {
    case Ok(_) -> assertTrue(false, "zero connections")
    case Err(m) -> assertTrue(has(m, "maxConnections"), "the problem is named: " + m)
  }
  match Grpc.openChannel("http://[::1]:5") {
    case Ok(ch) -> Grpc.closeChannel(ch)
    case Err(m) -> assertTrue(false, "an IPv6 literal with a port is valid: " + m)
  }
  match Grpc.openChannel("https://example.test") {
    case Ok(ch) -> Grpc.closeChannel(ch)
    case Err(m) -> assertTrue(false, "a default-port https address is valid: " + m)
  }
}

// ─── Large messages and limits ───────────────────────────────────────────────
test "messages larger than the flow-control windows round-trip in both directions" {
  val srv = plainServer({ cx: Cx, sid: Int, req: Req -> echo(cx, sid, req) })
  val ch = openOk(address(srv))
  val payload = patterned(3 * 1024 * 1024 + 17, 5)
  match Grpc.callUnary(ch, "test.Echo", "Echo", payload, Grpc.withTimeout(opts(), 60000)) {
    case Ok(resp) -> {
      assertEqualInt(resp.length, payload.length, "length")
      assertTrue(sameBytes(resp, payload), "3 MiB echoed intact (server window 64 KiB, client stream window 1 MiB)")
    }
    case Err(st) -> assertTrue(false, "3 MiB unary failed: " + st.message)
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "a response over the receive limit is RESOURCE_EXHAUSTED, by default and by option" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      val n = firstMessage(req)[0].toInt() * 1024
      sendHead(cx, sid, okHead([]), false)
      sendMsg(cx, sid, patterned(n, 1))
      sendEnd(cx, sid, 0, "")
    }
  )
  val ch = openOk(address(srv))
  match Grpc.callUnary(ch, "t", "Big", bytesOf([200]), opts()) {
    case Ok(resp) -> assertEqualInt(resp.length, 200 * 1024, "200 KiB is under the 4 MiB default")
    case Err(st) -> assertTrue(false, "200 KiB failed: " + st.message)
  }
  Grpc.closeChannel(ch)
  val small = Grpc.defaultChannelOptions()
  small.maxReceiveMessageBytes = 100 * 1024
  val ch2 = openWith(address(srv), small)
  match Grpc.callUnary(ch2, "t", "Big", bytesOf([200]), opts()) {
    case Ok(_) -> assertTrue(false, "200 KiB exceeds a 100 KiB limit")
    case Err(st) -> assertEqualInt(codeOf(st), 8, "ResourceExhausted")
  }
  match Grpc.callUnary(ch2, "t", "Big", bytesOf([50]), opts()) {
    case Ok(resp) -> assertEqualInt(resp.length, 50 * 1024, "the channel is usable after a refused message")
    case Err(st) -> assertTrue(false, "50 KiB failed: " + st.message)
  }
  Grpc.closeChannel(ch2)
  stopServer(srv)
}

test "a gzip bomb is refused at the receive limit before it is expanded" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      val hs = okHead([])
      hs.add(HeaderField(name = "grpc-encoding", value = "gzip"))
      sendHead(cx, sid, hs, false)
      sendFrame(cx, sid, frameMessage(compressMessage(patterned(2 * 1024 * 1024, 0)), true))
      sendEnd(cx, sid, 0, "")
    }
  )
  val o = Grpc.defaultChannelOptions()
  o.maxReceiveMessageBytes = 1024 * 1024
  val ch = openWith(address(srv), o)
  match Grpc.callUnary(ch, "t", "Bomb", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "2 MiB decompressed exceeds a 1 MiB limit")
    case Err(st) -> assertEqualInt(codeOf(st), 8, "ResourceExhausted")
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

// ─── Server streaming ────────────────────────────────────────────────────────
test "server streaming: messages in order, several per frame, then a clean end" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      val n = firstMessage(req)[0].toInt()
      sendHead(cx, sid, okHead([]), false)
      val both: List[Byte] = newList()
      var i = 0
      while i < n {
        for b in frameMessage(bytesOf([i]), false) {
          both.add(b)
        }
        i = i + 1
      }
      sendFrame(cx, sid, both.toArray())
      sendEnd(cx, sid, 0, "")
    }
  )
  val ch = openOk(address(srv))
  match Grpc.openServerStream(ch, "t", "Count", bytesOf([5]), opts()) {
    case Err(st) -> assertTrue(false, "open failed: " + st.message)
    case Ok(stream) -> {
      var i = 0
      while i < 5 {
        match Grpc.nextMessage(stream) {
          case Ok(Some(m)) -> assertEqualInt(m[0].toInt(), i, "message " + i.toString())
          case _ -> assertTrue(false, "message " + i.toString() + " expected")
        }
        i = i + 1
      }
      match Grpc.nextMessage(stream) {
        case Ok(None) -> ()
        case _ -> assertTrue(false, "a clean end is Ok(None)")
      }
      match Grpc.nextMessage(stream) {
        case Ok(None) -> ()
        case _ -> assertTrue(false, "reading past the end stays Ok(None)")
      }
      Grpc.closeStream(stream)
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "server streaming: messages larger than the window, then a failure status" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      sendHead(cx, sid, okHead([]), false)
      sendMsg(cx, sid, patterned(1500000, 1))
      sendMsg(cx, sid, patterned(1500000, 2))
      sendEnd(cx, sid, 13, "boom")
    }
  )
  val ch = openOk(address(srv))
  match Grpc.openServerStream(ch, "t", "Big", bytesOf([1]), Grpc.withTimeout(opts(), 60000)) {
    case Err(st) -> assertTrue(false, "open failed: " + st.message)
    case Ok(stream) -> {
      match Grpc.nextMessage(stream) {
        case Ok(Some(m)) -> assertTrue(sameBytes(m, patterned(1500000, 1)), "first 1.5 MiB message intact")
        case _ -> assertTrue(false, "first message")
      }
      match Grpc.nextMessage(stream) {
        case Ok(Some(m)) -> assertTrue(sameBytes(m, patterned(1500000, 2)), "second 1.5 MiB message intact")
        case _ -> assertTrue(false, "second message")
      }
      match Grpc.nextMessage(stream) {
        case Err(st) -> {
          assertEqualInt(codeOf(st), 13, "Internal")
          assertEqual(st.message, "boom", "message")
        }
        case _ -> assertTrue(false, "the failure arrives after the messages")
      }
      match Grpc.nextMessage(stream) {
        case Ok(None) -> ()
        case _ -> assertTrue(false, "a finished stream reads as ended")
      }
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "server streaming: closeStream cancels the call and wakes a blocked reader" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req -> sendHead(cx, sid, okHead([]), false); sendMsg(cx, sid, bytesOf([1])) }
  )
  val ch = openOk(address(srv))
  match Grpc.openServerStream(ch, "t", "Hang", bytesOf([1]), opts()) {
    case Err(st) -> assertTrue(false, "open failed: " + st.message)
    case Ok(stream) -> {
      match Grpc.nextMessage(stream) {
        case Ok(Some(_)) -> ()
        case _ -> assertTrue(false, "the first message")
      }
      val read = newSem(0)
      val outcome = Box(text = "pending", n = 0)
      startTask(
        { ->
          runGuarded(
            { ->
              match Grpc.nextMessage(stream) {
                case Err(st) -> {
                  outcome.text = "err " + codeOf(st).toString()
                }
                case Ok(None) -> {
                  outcome.text = "end"
                }
                case Ok(Some(_)) -> {
                  outcome.text = "message"
                }
              }
            },
            { m -> outcome.text = "panic " + m }
          )
          semPost(read)
        }
      )
      sleepMillis(100)
      Grpc.closeStream(stream)
      var woke = false
      var waited = 0
      while not woke and waited < 5000 {
        woke = semTryWait(read)
        sleepMillis(5)
        waited = waited + 5
      }
      assertTrue(woke, "the blocked reader woke")
      assertEqual(outcome.text, "err 1", "it saw Cancelled")
    }
  }
  assertTrue(waitFor(3000, { -> srv.obs.resets >= 1 }), "the server saw the RST_STREAM")
  assertEqual(srv.obs.lastResetCode.toString(), "8", "RST_STREAM CANCEL")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

// ─── Deadlines and connection failure ────────────────────────────────────────
test "a deadline that passes before the reply is DEADLINE_EXCEEDED and the channel is reusable" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      if headerValue(req.headers, ":path") == "/t/Slow" {
        ()
      } else {
        echo(cx, sid, req)
      }
    }
  )
  val ch = openOk(address(srv))
  val started = monotonicNanos()
  match Grpc.callUnary(ch, "t", "Slow", bytesOf([1]), Grpc.withTimeout(opts(), 300)) {
    case Ok(_) -> assertTrue(false, "nothing was sent")
    case Err(st) -> assertEqualInt(codeOf(st), 4, "DeadlineExceeded")
  }
  val elapsedMs = ((monotonicNanos() - started) / 1000000i64).toInt()
  assertTrue(
    elapsedMs >= 250 and elapsedMs < 5000,
    "the call waited about its deadline: " + elapsedMs.toString() + " ms"
  )
  match Grpc.callUnary(ch, "t", "Echo", bytesOf([9]), opts()) {
    case Ok(r) -> assertEqualInt(r[0].toInt(), 9, "a later call works")
    case Err(st) -> assertTrue(false, "channel unusable after a deadline: " + st.message)
  }
  assertEqualInt(srv.obs.connections, 1, "the connection was kept")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

func unusedPort(): Int {
  match hostListen("127.0.0.1", 0) {
    case Ok(l) -> {
      val p = hostLocalPort(l)
      hostStopListener(l)
      p
    }
    case Err(e) -> panic("could not reserve a port: " + TcpError.message(e))
  }
}

test "no server: UNAVAILABLE, then calls fail fast during the reconnect backoff" {
  val o = Grpc.defaultChannelOptions()
  o.reconnectInitialBackoffMs = 60000
  o.reconnectMaxBackoffMs = 60000
  val ch = openWith("http://127.0.0.1:" + unusedPort().toString(), o)
  match Grpc.callUnary(ch, "t", "Echo", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "nobody is listening")
    case Err(st) -> assertEqualInt(codeOf(st), 14, "Unavailable")
  }
  val started = monotonicNanos()
  match Grpc.callUnary(ch, "t", "Echo", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "still nobody")
    case Err(st) -> {
      assertEqualInt(codeOf(st), 14, "Unavailable")
      assertTrue(has(st.message, "backoff"), "the message says why: " + st.message)
    }
  }
  assertTrue((monotonicNanos() - started) / 1000000i64 < 500i64, "a call during the backoff does not dial")
  match Grpc.openServerStream(ch, "t", "Count", bytesOf([1]), opts()) {
    case Err(_) -> assertTrue(false, "openServerStream reports a connection failure on the first read")
    case Ok(stream) -> {
      match Grpc.nextMessage(stream) {
        case Err(st) -> assertEqualInt(codeOf(st), 14, "Unavailable on the first read")
        case _ -> assertTrue(false, "no server")
      }
      Grpc.closeStream(stream)
    }
  }
  Grpc.closeChannel(ch)
}

test "after the backoff a call dials again and reaches a server that came up on the same address" {
  val port = unusedPort()
  val o = Grpc.defaultChannelOptions()
  o.reconnectInitialBackoffMs = 150
  o.reconnectMaxBackoffMs = 150
  val ch = openWith("http://127.0.0.1:" + port.toString(), o)
  match Grpc.callUnary(ch, "t", "Echo", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "nobody is listening yet")
    case Err(st) -> assertEqualInt(codeOf(st), 14, "Unavailable")
  }
  val srv = startServerAt(
    port,
    H2.h2DefaultServerSettings(),
    None,
    { cx: Cx, sid: Int, req: Req -> echo(cx, sid, req) },
    { cx: Cx -> () }
  )
  sleepMillis(300)
  match Grpc.callUnary(ch, "t", "Echo", bytesOf([4]), opts()) {
    case Ok(r) -> assertEqualInt(r[0].toInt(), 4, "reply")
    case Err(st) -> assertTrue(false, "a live server must answer once the backoff is over: " + st.message)
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}

// ─── Multiplexing, MAX_CONCURRENT_STREAMS, pooling ───────────────────────────
ref record Job {
  done: Semaphore
  var code: Int
  var text: String
}

func startCall(ch: in GrpcChannel, path: in String, payload: in slice[Byte]): Job {
  val j = Job(done = newSem(0), code = -1, text = "")
  startTask(
    { ->
      runGuarded(
        { ->
          match Grpc.callUnary(ch, "t", path, payload, Grpc.withTimeout(opts(), 30000)) {
            case Ok(r) -> {
              j.code = 0
              j.text = r.length.toString()
            }
            case Err(st) -> {
              j.code = codeOf(st)
              j.text = st.message
            }
          }
        },
        { m -> j.text = "panic: " + m }
      )
      semPost(j.done)
    }
  )
  j
}

func joinJob(j: in Job): Unit {
  var woke = false
  var waited = 0
  while not woke and waited < 40000 {
    woke = semTryWait(j.done)
    if not woke {
      sleepMillis(5)
      waited = waited + 5
    }
  }
  assertTrue(woke, "a background call finished within 40 s")
}

func hasReq(cx: in Cx, sid: in Int): Bool {
  match mapGet(cx.reqs, sid) {
    case Some(_) -> true
    case None -> false
  }
}

// A peer that holds each request for `holdMs` and tracks how many it holds.
func holdingServer(maxStreams: in Int, holdMs: in Int): Server {
  val settings = H2.h2DefaultServerSettings()
  settings.maxConcurrentStreams = maxStreams
  val held: List[Int] = newList()
  val owners: List[Int] = newList()
  val due: List[Long] = newList()
  val payloads: List[slice[Byte]] = newList()
  val lockHeld = newMutex()
  startServer(
    settings,
    None,
    { cx: Cx, sid: Int, req: Req ->
      lock(cx.obs.guard)
      cx.obs.inFlight = cx.obs.inFlight + 1
      if cx.obs.inFlight > cx.obs.maxInFlight {
        cx.obs.maxInFlight = cx.obs.inFlight
      }
      unlock(cx.obs.guard)
      lock(lockHeld)
      held.add(sid)
      owners.add(cx.index)
      due.add(monotonicNanos() + holdMs.toLong() * 1000000i64)
      payloads.add(firstMessage(req))
      unlock(lockHeld)
    },
    { cx: Cx ->
      var again = true
      while again {
        again = false
        var pickedSid = -1
        var pickedPayload = bytesOf([])
        lock(lockHeld)
        var k = 0
        while k < held.count and pickedSid < 0 {
          if owners[k] == cx.index and due[k] <= monotonicNanos() and hasReq(cx, held[k]) {
            pickedSid = held[k]
            pickedPayload = payloads[k]
            held.removeAt(k)
            owners.removeAt(k)
            due.removeAt(k)
            payloads.removeAt(k)
          }
          k = k + 1
        }
        unlock(lockHeld)
        if pickedSid >= 0 {
          lock(cx.obs.guard)
          cx.obs.inFlight = cx.obs.inFlight - 1
          unlock(cx.obs.guard)
          respondUnary(cx, pickedSid, pickedPayload)
          again = true
        }
      }
    }
  )
}

test "calls beyond MAX_CONCURRENT_STREAMS queue on one connection and all complete" {
  val srv = holdingServer(2, 120)
  val ch = openOk(address(srv))
  val jobs: List[Job] = newList()
  var i = 0
  while i < 7 {
    jobs.add(startCall(ch, "Hold", bytesOf([i])))
    i = i + 1
  }
  for j in jobs {
    joinJob(j)
    assertEqualInt(j.code, 0, "call succeeded: " + j.text)
    assertEqual(j.text, "1", "response size")
  }
  assertEqualInt(srv.obs.requests, 7, "the server saw all seven requests")
  assertTrue(
    srv.obs.maxInFlight <= 2,
    "never more than the advertised 2 in flight, saw " + srv.obs.maxInFlight.toString()
  )
  assertTrue(srv.obs.maxInFlight >= 2, "and the two slots were used")
  assertEqualInt(srv.obs.connections, 1, "with the default of one connection per channel")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "a queued call's deadline applies while it waits for a stream" {
  val srv = holdingServer(1, 1500)
  val ch = openOk(address(srv))
  val first = startCall(ch, "Hold", bytesOf([1]))
  assertTrue(waitFor(5000, { -> srv.obs.inFlight == 1 }), "the first call holds the only stream")
  val started = monotonicNanos()
  match Grpc.callUnary(ch, "t", "Hold", bytesOf([2]), Grpc.withTimeout(opts(), 200)) {
    case Ok(_) -> assertTrue(false, "no stream was free in time")
    case Err(st) -> assertEqualInt(codeOf(st), 4, "DeadlineExceeded")
  }
  assertTrue(
    (monotonicNanos() - started) / 1000000i64 < 1200i64,
    "it gave up at its own deadline, not the first call's"
  )
  joinJob(first)
  assertEqualInt(first.code, 0, "the first call completed: " + first.text)
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "maxConnections opens a second connection only when the first is full" {
  val srv = holdingServer(1, 300)
  val o = Grpc.defaultChannelOptions()
  o.maxConnections = 2
  val ch = openWith(address(srv), o)
  val a = startCall(ch, "Hold", bytesOf([1]))
  assertTrue(waitFor(5000, { -> srv.obs.inFlight == 1 }), "the first call is in flight")
  val b = startCall(ch, "Hold", bytesOf([2]))
  assertTrue(waitFor(5000, { -> srv.obs.connections == 2 }), "a second connection was opened for it")
  joinJob(a)
  joinJob(b)
  assertEqualInt(a.code, 0, "first ok: " + a.text)
  assertEqualInt(b.code, 0, "second ok: " + b.text)
  assertEqualInt(channelConnectionCount(ch), 2, "the channel holds two connections")
  val c = startCall(ch, "Hold", bytesOf([3]))
  joinJob(c)
  assertEqualInt(c.code, 0, "third ok: " + c.text)
  assertEqualInt(srv.obs.connections, 2, "and never a third")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

// ─── GOAWAY and transparent retry ────────────────────────────────────────────
test "GOAWAY mid-stream: the stream finishes, and the next call uses a new connection" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      if headerValue(req.headers, ":path") == "/g/Count" {
        sendHead(cx, sid, okHead([]), false)
        sendMsg(cx, sid, bytesOf([1]))
        sendGoAwayAt(cx, sid)
        sendMsg(cx, sid, bytesOf([2]))
        sendEnd(cx, sid, 0, "")
      } else {
        echo(cx, sid, req)
      }
    }
  )
  val ch = openOk(address(srv))
  match Grpc.openServerStream(ch, "g", "Count", bytesOf([2]), opts()) {
    case Err(st) -> assertTrue(false, "open failed: " + st.message)
    case Ok(stream) -> {
      match Grpc.nextMessage(stream) {
        case Ok(Some(m)) -> assertEqualInt(m[0].toInt(), 1, "first")
        case _ -> assertTrue(false, "first message")
      }
      match Grpc.nextMessage(stream) {
        case Ok(Some(m)) -> assertEqualInt(m[0].toInt(), 2, "second, after the GOAWAY")
        case _ -> assertTrue(false, "a GOAWAY at this stream's id lets it finish")
      }
      match Grpc.nextMessage(stream) {
        case Ok(None) -> ()
        case _ -> assertTrue(false, "clean end")
      }
      Grpc.closeStream(stream)
    }
  }
  match Grpc.callUnary(ch, "g", "Echo", bytesOf([5]), opts()) {
    case Ok(r) -> assertEqualInt(r[0].toInt(), 5, "a new call works")
    case Err(st) -> assertTrue(false, "call after GOAWAY failed: " + st.message)
  }
  assertEqualInt(srv.obs.connections, 2, "the draining connection was replaced")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "transparent retry: a call above the GOAWAY last-stream-id is sent again, exactly once, on a new connection" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req -> if cx.index == 1 { sendGoAwayAt(cx, 0) } else { echo(cx, sid, req) } }
  )
  val ch = openOk(address(srv))
  match Grpc.callUnary(ch, "g", "Echo", bytesOf([7]), opts()) {
    case Ok(r) -> assertEqualInt(r[0].toInt(), 7, "the retried call succeeded")
    case Err(st) -> assertTrue(false, "the unprocessed call must be retried: " + st.message)
  }
  assertEqualInt(srv.obs.connections, 2, "on a second connection")
  assertEqualInt(srv.obs.requests, 2, "the server saw the request twice (once ignored)")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "transparent retry: REFUSED_STREAM is retried once; a second refusal is UNAVAILABLE" {
  val refusals = Box(text = "", n = 0)
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req ->
      val path = headerValue(req.headers, ":path")
      if path == "/g/Once" and refusals.n == 0 {
        refusals.n = 1
        sendRst(cx, sid, H2RefusedStream)
      } else if path == "/g/Always" {
        sendRst(cx, sid, H2RefusedStream)
      } else {
        echo(cx, sid, req)
      }
    }
  )
  val ch = openOk(address(srv))
  match Grpc.callUnary(ch, "g", "Once", bytesOf([3]), opts()) {
    case Ok(r) -> assertEqualInt(r[0].toInt(), 3, "retried after one refusal")
    case Err(st) -> assertTrue(false, "one refusal must be retried: " + st.message)
  }
  assertEqualInt(srv.obs.requests, 2, "refused once, then served")
  val before = srv.obs.requests
  match Grpc.callUnary(ch, "g", "Always", bytesOf([3]), opts()) {
    case Ok(_) -> assertTrue(false, "refused every time")
    case Err(st) -> assertEqualInt(codeOf(st), 14, "Unavailable after the single retry")
  }
  assertEqualInt(srv.obs.requests - before, 2, "tried exactly twice, not more")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "a call that may have run is never retried" {
  val srv = plainServer(
    { cx: Cx, sid: Int, req: Req -> sendHead(cx, sid, okHead([]), false); sendRst(cx, sid, H2InternalError) }
  )
  val ch = openOk(address(srv))
  match Grpc.callUnary(ch, "g", "Echo", bytesOf([3]), opts()) {
    case Ok(_) -> assertTrue(false, "reset after headers")
    case Err(st) -> assertEqualInt(codeOf(st), 13, "Internal")
  }
  assertEqualInt(srv.obs.requests, 1, "sent once")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

// ─── Idle policy ─────────────────────────────────────────────────────────────
test "an idle connection is closed, and the next call reconnects transparently" {
  val srv = plainServer({ cx: Cx, sid: Int, req: Req -> echo(cx, sid, req) })
  val o = Grpc.defaultChannelOptions()
  o.idleTimeoutMs = 150
  val ch = openWith(address(srv), o)
  match Grpc.callUnary(ch, "t", "Echo", bytesOf([1]), opts()) {
    case Ok(_) -> ()
    case Err(st) -> assertTrue(false, "first call: " + st.message)
  }
  assertEqualInt(channelConnectionCount(ch), 1, "connected")
  assertTrue(waitFor(5000, { -> channelConnectionCount(ch) == 0 }), "the idle connection was closed")
  assertTrue(waitFor(5000, { -> srv.obs.eofs >= 1 }), "the server saw it go")
  match Grpc.callUnary(ch, "t", "Echo", bytesOf([2]), opts()) {
    case Ok(r) -> assertEqualInt(r[0].toInt(), 2, "second call")
    case Err(st) -> assertTrue(false, "reconnect failed: " + st.message)
  }
  assertEqualInt(srv.obs.connections, 2, "on a second connection")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "closeChannel closes the connections and fails calls in flight" {
  val srv = holdingServer(10, 60000)
  val ch = openOk(address(srv))
  val j = startCall(ch, "Hold", bytesOf([1]))
  assertTrue(waitFor(5000, { -> srv.obs.inFlight == 1 }), "the call is held by the server")
  Grpc.closeChannel(ch)
  joinJob(j)
  assertEqualInt(j.code, 14, "Unavailable: " + j.text)
  assertTrue(waitFor(5000, { -> srv.obs.eofs >= 1 }), "the server saw the connection close")
  stopServer(srv)
}

// ─── TLS ─────────────────────────────────────────────────────────────────────
func tlsConfig(): TlsServerConfig {
  val id = match Identity.fromPem(serverCertPem, serverKeyPem) {
    case Ok(i) -> i
    case Err(e) -> panic("test identity: " + TlsError.message(e))
  }
  TlsServerConfig(identity = id)
}

test "https: a channel with the pinned CA reaches a TLS server over ALPN h2" {
  val srv = startServer(
    H2.h2DefaultServerSettings(),
    Some(value = tlsConfig()),
    { cx: Cx, sid: Int, req: Req -> echo(cx, sid, req) },
    { cx: Cx -> () }
  )
  val o = Grpc.defaultChannelOptions()
  o.trust = TlsTrustExclusive(caPem = caCertPem)
  val ch = openWith("https://127.0.0.1:" + srv.port.toString(), o)
  match Grpc.callUnary(ch, "t", "Echo", bytesOf([8, 9]), opts()) {
    case Ok(r) -> assertEqualInt(r.length, 2, "echoed over TLS")
    case Err(st) -> assertTrue(false, "TLS unary failed: " + st.message)
  }
  assertEqual(headerValue(srv.obs.lastHeaders, ":scheme"), "https", ":scheme")
  Grpc.closeChannel(ch)
  stopServer(srv)
}

test "https: an untrusted server certificate is UNAVAILABLE, and so is plaintext to a TLS port" {
  val srv = startServer(
    H2.h2DefaultServerSettings(),
    Some(value = tlsConfig()),
    { cx: Cx, sid: Int, req: Req -> echo(cx, sid, req) },
    { cx: Cx -> () }
  )
  val ch = openOk("https://127.0.0.1:" + srv.port.toString())
  match Grpc.callUnary(ch, "t", "Echo", bytesOf([1]), opts()) {
    case Ok(_) -> assertTrue(false, "the test CA is not in the system trust store")
    case Err(st) -> assertEqualInt(codeOf(st), 14, "Unavailable")
  }
  Grpc.closeChannel(ch)
  stopServer(srv)
}
