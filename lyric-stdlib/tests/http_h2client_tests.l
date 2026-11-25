//! stdlib/tests/http_h2client_tests.l — behavioural corpus for the
//! `Std.HttpEngine.H2Client` driver (docs/72 slice 5, D800).
//!
//! Target neutral: the driver is pure Lyric over `Std.TcpHost` and
//! `Std.HttpServerHost`, so this suite runs unchanged on dotnet, the JVM and
//! native. Peers are in-process:
//!
//!   - **A scripted h2c peer** built from the `H2Conn` server role over
//!     `Std.TcpHost` (the shared `Std.HttpServer` driver speaks h2 over TLS
//!     only, D128 decision 7). It makes the behaviours a real server cannot be
//!     told to produce deterministic: GOAWAY with a chosen last-stream-id,
//!     REFUSED_STREAM, a connection dropped mid-response, a withheld window, a
//!     silent peer, a protocol violation.
//!   - **The real `Std.HttpServer`** over TLS with ALPN `h2`, driven end to end:
//!     GET, a 1 MiB request body under flow control, concurrent calls on one
//!     connection, and the trust failure.
//!
//! Interop against an independent implementation (`nghttpd`) is
//! `http_h2client_interop_tests.l`, run by `scripts/ci/h2conn-tests.sh`.
//!
//! Every wait on another thread is bounded, so a misbehaving peer fails the
//! suite instead of hanging it. Listeners bind port 0.
@test_module
package Std.HttpEngine.H2Client.Tests

import Std.Core
import Std.Collections
import Std.String
import Std.Encoding
import Std.Tls
import Std.TcpHost
import Std.HttpServerHost
import Std.HttpServer
import Std.HttpEngine
import Std.HttpEngine.H2Conn as H2
import Std.HttpEngine.H2Frame
import Std.HttpEngine.H2Client
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

val caBPem = """
-----BEGIN CERTIFICATE-----
MIIC/jCCAeagAwIBAgIUE20WHXyI7R9k+k0b5pmFmAcFZr0wDQYJKoZIhvcNAQEL
BQAwHzEdMBsGA1UEAwwUbHlyaWMtY2xpZW50LXRlc3QtY2EwHhcNMjYwNzE4MDAw
MDAwWhcNMzYwNzE1MDAwMDAwWjAfMR0wGwYDVQQDDBRseXJpYy1jbGllbnQtdGVz
dC1jYTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMmy+bDc0CGBhLwA
LUc6J45qLTogMZCjf7g8X1cnepfBmc9f49JRx+EWub4dkE8l6xmz8kS9yH5FvtZ3
AueK3oaHrXvIP3M8G2CSbW3Oswpu1pYHCa/iAHmhef4j2Lnp4qEw5iCmAHn8D7Mv
PRzNi8Zja3zPo72fZi6LR0Upfr+HEXwxA2kTaFKKfn7pOaVOtv9Rmb2OXMt2RTb6
Es1fq3KKBp8Aux6ssimJ8a0eFWgYiGez/chqFyzyVWEBU/3rHY1Wsa+tAH1Pyqqr
oOv5V1/Bun3Pt3esRyYfsWJBUvK9m6ySD69CfUEwEcaSKKNc4pFEKbNz0PHPbzUa
n1jrzpMCAwEAAaMyMDAwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUo7CO7QTr
fjBPTvP3j7WblFzX4LQwDQYJKoZIhvcNAQELBQADggEBAEdZ6X7P/lOtTFTuzKy0
H5qrkxCW1e8HCnGUgh68waRbqqgEjBamRaSb1O1KtkgYYAVYMFHxnIbG+hhvvchH
PlnbnLdZYsKsr2wFfwv1A+YRTEmwu/lm3g+wEV00t2oT4eWaTBdk9HJKSb7dnKa5
Vkbk1O49Mfzxp64SMNdU9cZRdsYwflv80OQ8/RFtZ+PyNGOJe3VvQlB78okLe/Dc
BMnlfOrfiYD1F+JtuDgdmxeqHWyeqiY1QHSfQDl1YNn9tJ5cLgeRCUr5xI9MR89P
MP5kdgJUV//c8xFE40VdH/1JFRkjpKGSwjqpqigQY6Of3pa45/RM5X3ZSuGCQErE
wyg=
-----END CERTIFICATE-----
"""

// ---------------------------------------------------------------------------
// Threads, semaphores and a scripted peer.
// ---------------------------------------------------------------------------
func nowNanos(): Long {
  monotonicNanos()
}

func elapsedMs(startNanos: in Long): Long {
  (monotonicNanos() - startNanos) / 1000000i64
}

// Wait up to `ms` for a credit; `false` when none came. A test never blocks on
// a semaphore unbounded, so a peer that misbehaves fails the suite instead of
// hanging it.
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
  var text: String
  var failure: String
}

func startJob(work: in () -> String): Job {
  val j = Job(done = newSem(0), text = "", failure = "")
  startTask({ -> runGuarded({ -> j.text = work() }, { m -> j.failure = m }); semPost(j.done) })
  j
}

func joinJob(j: in Job): String {
  if not waitSem(j.done, 30000) {
    panic("a background job did not finish within 30 s")
  }
  if j.failure.length > 0 {
    panic("background job failed: " + j.failure)
  }
  j.text
}

ref record Obs {
  var failure: String
  var n1: Int
  var n2: Int
  var n3: Int
  var flag: Bool
  var text: String
  gate: Semaphore
}

func newObs(): Obs {
  Obs(failure = "", n1 = 0, n2 = 0, n3 = 0, flag = false, text = "", gate = newSem(0))
}

ref record PeerConn {
  conn: Conn
  var h2: H2.H2Connection
  pending: List[H2.H2Event]
  var eof: Bool
  var autoGrant: Bool
}

ref record Peer {
  listener: Listener
  port: Int
  obs: Obs
  done: Semaphore
}

func servePeer(l: in Listener, obs: in Obs, script: in (PeerConn, Obs) -> Unit): Unit {
  match hostAccept(l) {
    case Ok(c) -> {
      val pending: List[H2.H2Event] = newList()
      val pc = PeerConn(
        conn = c,
        h2 = H2.newServerConnection(H2.h2DefaultServerSettings()),
        pending = pending,
        eof = false,
        autoGrant = true
      )
      defer {
        hostClose(c)
      }
      script(pc, obs)
    }
    case Err(e) -> {
      obs.failure = "accept failed: " + TcpError.message(e)
    }
  }
}

func startPeer(script: in (PeerConn, Obs) -> Unit): Peer {
  val l = match hostListen("127.0.0.1", 0) {
    case Ok(x) -> x
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val obs = newObs()
  val done = newSem(0)
  startTask(
    { -> runGuarded({ -> servePeer(l, obs, script) }, { m -> obs.failure = "peer script: " + m }); semPost(done) }
  )
  Peer(listener = l, port = hostLocalPort(l), obs = obs, done = done)
}

func finishPeer(p: in Peer): Unit {
  val finished = waitSem(p.done, 30000)
  hostStopListener(p.listener)
  assertTrue(finished, "the peer script finished")
  assertEqual(p.obs.failure, "", "the peer script reported no failure")
}

func peerWrite(pc: in PeerConn, bytes: in slice[Byte]): Unit {
  if bytes.length > 0 {
    match hostWrite(pc.conn, bytes) {
      case Ok(_) -> ()
      case Err(e) -> panic("peer write failed: " + TcpError.message(e))
    }
  }
}

func peerHello(pc: in PeerConn): Unit {
  peerWrite(pc, H2.serverInitialFrame(pc.h2))
}

// Read once (up to `waitMs`), feed the FSM, write what it queued and, when
// `autoGrant`, return receive credit for request data as it arrives.
func peerPump(pc: in PeerConn, waitMs: in Int): Unit {
  if pc.eof or H2.isFailed(pc.h2) {
    return
  }
  match hostReadDeadline(pc.conn, 65536, monotonicNanos() + waitMs.toLong() * 1000000i64) {
    case Ok(bytes) -> {
      if bytes.length == 0 {
        pc.eof = true
      } else {
        val res = H2.feed(pc.h2, bytes)
        pc.h2 = res.conn
        var wire = res.outbound
        var i = 0
        while i < res.events.count {
          val ev = res.events[i]
          match ev {
            case H2RequestData(sid, _, _, wl) -> {
              if pc.autoGrant and wl > 0 {
                wire = wire.concat(H2.grantConnectionWindow(pc.h2, wl)).concat(H2.grantStreamWindow(pc.h2, sid, wl))
              }
              pc.pending.add(ev)
            }
            case H2NeedMore -> ()
            case _ -> pc.pending.add(ev)
          }
          i = i + 1
        }
        peerWrite(pc, wire)
      }
    }
    case Err(e) -> {
      match e {
        case ReadDeadlinePassed -> ()
        case ReadFailed(te) -> {
          pc.eof = true
        }
      }
    }
  }
}

// The first pending or arriving event satisfying `want`, removed from the
// queue; `None` after `ms` or at end of stream.
func peerNext(pc: in PeerConn, want: in (H2.H2Event) -> Bool, ms: in Int): Option[H2.H2Event] {
  val deadline = monotonicNanos() + ms.toLong() * 1000000i64
  while true {
    var i = 0
    while i < pc.pending.count {
      val ev = pc.pending[i]
      if want(ev) {
        pc.pending.removeAt(i)
        return Some(value = ev)
      }
      i = i + 1
    }
    if pc.eof or monotonicNanos() >= deadline {
      return None
    }
    peerPump(pc, 25)
  }
  None
}

func isReqHeaders(ev: in H2.H2Event): Bool {
  match ev {
    case H2RequestHeaders(_, _, _) -> true
    case _ -> false
  }
}

func isPeerReset(ev: in H2.H2Event): Bool {
  match ev {
    case H2PeerReset(_, _) -> true
    case _ -> false
  }
}

func isWindowUpdate(ev: in H2.H2Event): Bool {
  match ev {
    case H2WindowUpdated(_) -> true
    case _ -> false
  }
}

func isPingAck(ev: in H2.H2Event): Bool {
  match ev {
    case H2PingAcknowledged(_) -> true
    case _ -> false
  }
}

func isDataFor(ev: in H2.H2Event, streamId: in Int): Bool {
  match ev {
    case H2RequestData(sid, _, _, _) -> sid == streamId
    case _ -> false
  }
}

func headerValue(headers: in List[HeaderField], name: in String): String {
  var i = 0
  while i < headers.count {
    if headers[i].name == name {
      return headers[i].value
    }
    i = i + 1
  }
  ""
}

ref record ReqInfo {
  var streamId: Int
  var path: String
  var method: String
  body: List[Byte]
  var complete: Bool
}

func bytesText(bytes: in List[Byte]): String {
  match tryDecodeUtf8(bytes.toArray()) {
    case Some(t) -> t
    case None -> "<binary>"
  }
}

func peerReadRequest(pc: in PeerConn): ReqInfo {
  val body: List[Byte] = newList()
  val r = ReqInfo(streamId = 0, path = "", method = "", body = body, complete = false)
  match peerNext(pc, { ev -> isReqHeaders(ev) }, 10000) {
    case Some(ev) -> {
      match ev {
        case H2RequestHeaders(sid, hs, es) -> {
          r.streamId = sid
          r.path = headerValue(hs, ":path")
          r.method = headerValue(hs, ":method")
          r.complete = es
        }
        case _ -> ()
      }
    }
    case None -> panic("peer: no request HEADERS arrived")
  }
  val sid = r.streamId
  while not r.complete {
    match peerNext(pc, { ev -> isDataFor(ev, sid) }, 10000) {
      case Some(ev) -> {
        match ev {
          case H2RequestData(_, d, es, _) -> {
            var i = 0
            while i < d.length {
              r.body.add(d[i])
              i = i + 1
            }
            if es {
              r.complete = true
            }
          }
          case _ -> ()
        }
      }
      case None -> panic("peer: request body did not complete")
    }
  }
  r
}

func respHeaderList(status: in Int): List[HeaderField] {
  val hs: List[HeaderField] = newList()
  hs.add(HeaderField(name = ":status", value = status.toString()))
  hs
}

func peerHeaders(pc: in PeerConn, sid: in Int, status: in Int, endStream: in Bool): Unit {
  match H2.encodeResponseHeaders(pc.h2, sid, respHeaderList(status), endStream) {
    case Ok(b) -> peerWrite(pc, b)
    case Err(_) -> panic("peer: response HEADERS refused by the FSM")
  }
}

func peerTrailers(pc: in PeerConn, sid: in Int, status: in String): Unit {
  val ts: List[HeaderField] = newList()
  ts.add(HeaderField(name = "grpc-status", value = status))
  match H2.encodeResponseTrailers(pc.h2, sid, ts) {
    case Ok(b) -> peerWrite(pc, b)
    case Err(_) -> panic("peer: trailers refused by the FSM")
  }
}

// Send as much of `data` as the windows allow right now, in frames; returns
// the bytes sent. No waiting.
func peerSendWhatFits(pc: in PeerConn, sid: in Int, data: in slice[Byte], from: in Int): Int {
  var offset = from
  while offset < data.length {
    var chunk = data.length - offset
    val frameMax = H2.peerMaxFrameSize(pc.h2)
    if chunk > frameMax {
      chunk = frameMax
    }
    val room = H2.maxSendableOnStream(pc.h2, sid)
    if chunk > room {
      chunk = room
    }
    if chunk <= 0 {
      return offset - from
    }
    match H2.sendData(pc.h2, sid, data.slice(offset, offset + chunk), false) {
      case Ok(b) -> peerWrite(pc, b)
      case Err(_) -> panic("peer: DATA refused by the FSM")
    }
    offset = offset + chunk
  }
  offset - from
}

// Send all of `data` (waiting for window updates from the client as needed)
// and end the stream.
func peerSendAll(pc: in PeerConn, sid: in Int, data: in slice[Byte]): Unit {
  var offset = 0
  val start = monotonicNanos()
  while offset < data.length {
    val sent = peerSendWhatFits(pc, sid, data, offset)
    offset = offset + sent
    if offset < data.length {
      if elapsedMs(start) > 25000i64 {
        panic("peer: the client never opened its window")
      }
      peerPump(pc, 25)
    }
  }
  match H2.sendData(pc.h2, sid, data.slice(0, 0), true) {
    case Ok(b) -> peerWrite(pc, b)
    case Err(_) -> panic("peer: final DATA refused by the FSM")
  }
}

func peerReply(pc: in PeerConn, sid: in Int, body: in String): Unit {
  peerHeaders(pc, sid, 200, false)
  peerSendAll(pc, sid, encodeUtf8(body))
}

// Keep reading until the client closes the connection (or `ms` pass).
func peerUntilEof(pc: in PeerConn, ms: in Int): Unit {
  val deadline = monotonicNanos() + ms.toLong() * 1000000i64
  while not pc.eof and monotonicNanos() < deadline {
    peerPump(pc, 25)
  }
}

// ---------------------------------------------------------------------------
// Client-side helpers.
// ---------------------------------------------------------------------------
func hf(name: in String, value: in String): HeaderField {
  HeaderField(name = name, value = value)
}

func reqHeaders(method: in String, scheme: in String, path: in String): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":method", method))
  h.add(hf(":scheme", scheme))
  h.add(hf(":path", path))
  h.add(hf(":authority", "localhost"))
  h
}

func patternBytes(n: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < n {
    acc.add(((i * 7 + 3) % 251).toByte())
    i = i + 1
  }
  acc.toArray()
}

func checksumStep(cs: in Int, b: in Int): Int {
  (cs * 31 + b) % 1000003
}

func checksumOf(bytes: in slice[Byte]): Int {
  var cs = 0
  var i = 0
  while i < bytes.length {
    cs = checksumStep(cs, bytes[i].toInt())
    i = i + 1
  }
  cs
}

ref record Outcome {
  var status: Int
  var infos: Int
  var bodyLen: Int
  var checksum: Int
  var text: String
  var trailers: String
  var ended: Bool
  var fail: Option[H2CallFailure]
}

func collect(call: in H2Call): Outcome {
  val none: Option[H2CallFailure] = None
  val o = Outcome(
    status = 0,
    infos = 0,
    bodyLen = 0,
    checksum = 0,
    text = "",
    trailers = "",
    ended = false,
    fail = none
  )
  val small: List[Byte] = newList()
  var go = true
  while go {
    match h2NextEvent(call) {
      case H2CallInformational(_, _) -> {
        o.infos = o.infos + 1
      }
      case H2CallHeaders(st, _) -> {
        o.status = st
      }
      case H2CallData(d) -> {
        var i = 0
        while i < d.length {
          o.checksum = checksumStep(o.checksum, d[i].toInt())
          if o.bodyLen + i < 8192 {
            small.add(d[i])
          }
          i = i + 1
        }
        o.bodyLen = o.bodyLen + d.length
      }
      case H2CallTrailers(hs) -> {
        var i = 0
        while i < hs.count {
          o.trailers = o.trailers + hs[i].name + "=" + hs[i].value + ";"
          i = i + 1
        }
      }
      case H2CallEnded -> {
        o.ended = true
        go = false
      }
      case H2CallFailed(f) -> {
        o.fail = Some(value = f)
        go = false
      }
    }
  }
  o.text = bytesText(small)
  o
}

func failureKind(o: in Outcome): String {
  match o.fail {
    case None -> "none"
    case Some(f) -> {
      match f {
        case H2FailDeadlineExceeded -> "deadline"
        case H2FailCancelled -> "cancelled"
        case H2FailReset(_) -> "reset"
        case H2FailRefused -> "refused"
        case H2FailUnprocessed -> "unprocessed"
        case H2FailConnectionLost(_) -> "lost"
        case H2FailProtocol(_, _) -> "protocol"
      }
    }
  }
}

func failureMessage(o: in Outcome): String {
  match o.fail {
    case None -> ""
    case Some(f) -> H2CallFailure.message(f)
  }
}

func fastOpts(): H2ClientOptions {
  val d = h2ClientDefaults()
  H2ClientOptions(
    connectTimeoutMs = 5000,
    handshakeTimeoutMs = 5000,
    writeTimeoutMs = 10000,
    pollIntervalMs = 20,
    keepAliveIntervalMs = d.keepAliveIntervalMs,
    keepAliveTimeoutMs = d.keepAliveTimeoutMs,
    keepAliveWithoutCalls = false,
    streamWindow = d.streamWindow,
    connectionWindow = d.connectionWindow
  )
}

func connectPlain(port: in Int, opts: in H2ClientOptions): H2ClientConnection {
  match h2Connect(H2Plain(host = "127.0.0.1", port = port), opts) {
    case Ok(c) -> c
    case Err(e) -> panic("h2Connect failed: " + H2DialError.message(e))
  }
}

func startOk(conn: in H2ClientConnection, headers: in List[HeaderField], endStream: in Bool, deadlineMs: in Int): H2Call {
  match h2StartCall(conn, headers, endStream, deadlineMs) {
    case Ok(c) -> c
    case Err(_) -> panic("h2StartCall was refused")
  }
}

func sendOk(call: in H2Call, data: in slice[Byte], endStream: in Bool): Unit {
  match h2SendBody(call, data, endStream) {
    case Ok(_) -> ()
    case Err(e) -> {
      val why = match e {
        case H2BodyCallFailed(f) -> "call failed: " + H2CallFailure.message(f)
        case H2BodyStreamClosed -> "stream closed"
        case H2BodyWriteFailed(m) -> "write failed: " + m
      }
      panic("h2SendBody failed: " + why)
    }
  }
}

func statusIs(conn: in H2ClientConnection, want: H2ClientStatus): Bool {
  match h2ClientStatus(conn) {
    case H2ClientOpen -> match want { case H2ClientOpen -> true; case _ -> false }
    case H2ClientDraining -> match want { case H2ClientDraining -> true; case _ -> false }
    case H2ClientClosed -> match want { case H2ClientClosed -> true; case _ -> false }
  }
}

func waitClosed(conn: in H2ClientConnection, ms: in Int): Bool {
  var waited = 0
  while waited < ms {
    if statusIs(conn, H2ClientClosed) {
      return true
    }
    sleepMillis(10)
    waited = waited + 10
  }
  false
}

func retrySafe(o: in Outcome): Bool {
  match o.fail {
    case Some(f) -> h2FailureIsRetrySafe(f)
    case None -> false
  }
}

func isDrainingError(e: in H2StartError): Bool {
  match e {
    case H2StartDraining -> true
    case _ -> false
  }
}

func isClosedError(e: in H2StartError): Bool {
  match e {
    case H2StartClosed -> true
    case _ -> false
  }
}

func isTransportError(e: in H2DialError): Bool {
  match e {
    case H2ConnectTransport(_) -> true
    case _ -> false
  }
}

func isTlsError(e: in H2DialError): Bool {
  match e {
    case H2ConnectTls(_) -> true
    case _ -> false
  }
}

// ---------------------------------------------------------------------------
// Options.
// ---------------------------------------------------------------------------
test "the default options are valid and a bad window is not" {
  assertTrue(h2ClientOptionsValid(h2ClientDefaults()), "defaults are valid")
  val d = h2ClientDefaults()
  val small = H2ClientOptions(
    connectTimeoutMs = d.connectTimeoutMs,
    handshakeTimeoutMs = d.handshakeTimeoutMs,
    writeTimeoutMs = d.writeTimeoutMs,
    pollIntervalMs = d.pollIntervalMs,
    keepAliveIntervalMs = 0,
    keepAliveTimeoutMs = d.keepAliveTimeoutMs,
    keepAliveWithoutCalls = false,
    streamWindow = 100,
    connectionWindow = d.connectionWindow
  )
  assertFalse(h2ClientOptionsValid(small), "a stream window under 65535 is invalid")
  assertEqualInt(d.keepAliveIntervalMs, 0, "keepalive is off by default (OQ-5)")
}

test "failure retry safety" {
  assertTrue(h2FailureIsRetrySafe(H2FailRefused), "REFUSED_STREAM is retry safe")
  assertTrue(h2FailureIsRetrySafe(H2FailUnprocessed), "GOAWAY-unprocessed is retry safe")
  assertFalse(h2FailureIsRetrySafe(H2FailDeadlineExceeded), "a deadline may have been processed")
  assertFalse(h2FailureIsRetrySafe(H2FailConnectionLost(message = "x")), "a lost connection may have been processed")
  assertFalse(h2FailureIsRetrySafe(H2FailCancelled), "a cancel may have been processed")
}

// ---------------------------------------------------------------------------
// h2c against the pure-Lyric H2Conn server role.
// ---------------------------------------------------------------------------
test "h2c unary call: headers, body, data and trailers" {
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      val r = peerReadRequest(pc)
      obs.text = r.method + " " + r.path + " " + bytesText(r.body)
      peerHeaders(pc, r.streamId, 200, false)
      val sent = peerSendWhatFits(pc, r.streamId, encodeUtf8("pong"), 0)
      obs.n1 = sent
      peerTrailers(pc, r.streamId, "0")
      peerUntilEof(pc, 5000)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val call = startOk(conn, reqHeaders("POST", "http", "/echo.Svc/Ping"), false, 0)
  sendOk(call, encodeUtf8("ping"), true)
  val o = collect(call)
  assertEqualInt(o.status, 200, "status")
  assertEqual(o.text, "pong", "response body")
  assertEqual(o.trailers, "grpc-status=0;", "trailers")
  assertTrue(o.ended, "the call ended cleanly")
  assertEqualInt(h2ClientActiveCalls(conn), 0, "no call left in flight")
  h2Close(conn)
  finishPeer(peer)
  assertEqual(peer.obs.text, "POST /echo.Svc/Ping ping", "the peer saw the request")
}

test "h2c Trailers-Only response" {
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      val r = peerReadRequest(pc)
      val ts: List[HeaderField] = newList()
      ts.add(HeaderField(name = ":status", value = "200"))
      ts.add(HeaderField(name = "grpc-status", value = "12"))
      match H2.encodeResponseHeaders(pc.h2, r.streamId, ts, true) {
        case Ok(b) -> peerWrite(pc, b)
        case Err(_) -> panic("encode failed")
      }
      peerUntilEof(pc, 5000)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val call = startOk(conn, reqHeaders("POST", "http", "/x"), true, 0)
  val o = collect(call)
  assertEqualInt(o.status, 200, "status")
  assertEqualInt(o.bodyLen, 0, "no body")
  assertTrue(o.ended, "ended after the headers block")
  h2Close(conn)
  finishPeer(peer)
}

test "h2c informational response precedes the final one" {
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      val r = peerReadRequest(pc)
      peerHeaders(pc, r.streamId, 103, false)
      peerHeaders(pc, r.streamId, 200, false)
      peerSendAll(pc, r.streamId, encodeUtf8("done"))
      peerUntilEof(pc, 5000)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val call = startOk(conn, reqHeaders("GET", "http", "/x"), true, 0)
  val o = collect(call)
  assertEqualInt(o.infos, 1, "one 1xx")
  assertEqualInt(o.status, 200, "final status")
  assertEqual(o.text, "done", "body")
  h2Close(conn)
  finishPeer(peer)
}

test "h2c concurrent calls are multiplexed on one connection" {
  val total = 8
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      var served = 0
      while served < total {
        val r = peerReadRequest(pc)
        peerReply(pc, r.streamId, "echo:" + r.path + ":" + bytesText(r.body))
        served = served + 1
      }
      peerUntilEof(pc, 5000)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val jobs: List[Job] = newList()
  var i = 0
  while i < total {
    val n = i
    jobs.add(
      startJob(
        { ->
          val call = startOk(conn, reqHeaders("POST", "http", "/c" + n.toString()), false, 0)
          sendOk(call, encodeUtf8("body" + n.toString()), true)
          collect(call).text
        }
      )
    )
    i = i + 1
  }
  var j = 0
  while j < total {
    val t = joinJob(jobs[j])
    assertTrue(t.startsWith("echo:/c"), "reply shaped like a call echo: " + t)
    assertTrue(t.contains(":body"), "reply carries the body: " + t)
    j = j + 1
  }
  var seen = ""
  j = 0
  while j < total {
    seen = seen + jobs[j].text + "|"
    j = j + 1
  }
  var k = 0
  while k < total {
    assertTrue(
      seen.contains("echo:/c" + k.toString() + ":body" + k.toString() + "|"),
      "call " + k.toString() + " got its own reply"
    )
    k = k + 1
  }
  h2Close(conn)
  finishPeer(peer)
}

test "sending honours the peer's flow-control window" {
  val bodySize = 200000
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      pc.autoGrant = false
      val got = peerNext(pc, { ev -> isReqHeaders(ev) }, 10000)
      var sid = 0
      match got {
        case Some(ev) -> match ev { case H2RequestHeaders(s, _, _) -> { sid = s }; case _ -> () }
        case None -> panic("no request")
      }
      // Without a grant the client may send exactly the initial window, no more.
      var stalledFor = 0
      var received = 0
      while stalledFor < 600 {
        match peerNext(pc, { ev -> isDataFor(ev, sid) }, 50) {
          case Some(ev) -> {
            match ev {
              case H2RequestData(_, d, _, _) -> {
                received = received + d.length
              }
              case _ -> ()
            }
            stalledFor = 0
          }
          case None -> {
            stalledFor = stalledFor + 50
          }
        }
      }
      obs.n1 = received
      // Grant credit as data arrives until the body ends.
      var ended = false
      while not ended {
        val connRoom = 65535 - H2.connectionReceiveWindow(pc.h2)
        if connRoom > 0 {
          peerWrite(pc, H2.grantConnectionWindow(pc.h2, connRoom))
        }
        val streamRoom = 65535 - H2.streamReceiveWindow(pc.h2, sid)
        if streamRoom > 0 {
          peerWrite(pc, H2.grantStreamWindow(pc.h2, sid, streamRoom))
        }
        match peerNext(pc, { ev -> isDataFor(ev, sid) }, 5000) {
          case Some(ev) -> {
            match ev {
              case H2RequestData(_, d, es, _) -> {
                received = received + d.length
                ended = es
              }
              case _ -> ()
            }
          }
          case None -> panic("body stalled after the grant")
        }
      }
      obs.n2 = received
      peerReply(pc, sid, "ok")
      peerUntilEof(pc, 5000)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val call = startOk(conn, reqHeaders("POST", "http", "/up"), false, 0)
  val sender = startJob({ -> sendOk(call, patternBytes(bodySize), true); "sent" })
  val o = collect(call)
  assertEqual(joinJob(sender), "sent", "the sender finished")
  assertEqual(o.text, "ok", "response")
  h2Close(conn)
  finishPeer(peer)
  assertEqualInt(peer.obs.n1, 65535, "before any grant the client sent exactly the initial window")
  assertEqualInt(peer.obs.n2, bodySize, "after the grants the whole body arrived")
}

test "a consumer that stops reading stalls the peer at the stream window" {
  val total = 1000000
  val data = patternBytes(total)
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      val r = peerReadRequest(pc)
      val sid = r.streamId
      peerHeaders(pc, sid, 200, false)
      val first = peerSendWhatFits(pc, sid, data, 0)
      obs.n1 = first
      // The client is not reading: keep pumping and see whether the stream
      // window reopens without the consumer.
      var waited = 0
      while waited < 500 {
        peerPump(pc, 25)
        waited = waited + 25
      }
      obs.n2 = H2.maxSendableOnStream(pc.h2, sid)
      semPost(obs.gate)
      var offset = first
      val start = monotonicNanos()
      while offset < total {
        offset = offset + peerSendWhatFits(pc, sid, data, offset)
        if offset < total {
          if elapsedMs(start) > 25000i64 {
            panic("peer: the consumer never resumed")
          }
          peerPump(pc, 25)
        }
      }
      match H2.sendData(pc.h2, sid, data.slice(0, 0), true) {
        case Ok(b) -> peerWrite(pc, b)
        case Err(_) -> panic("final DATA refused")
      }
      peerUntilEof(pc, 5000)
    }
  )
  val base = fastOpts()
  val opts = H2ClientOptions(
    connectTimeoutMs = base.connectTimeoutMs,
    handshakeTimeoutMs = base.handshakeTimeoutMs,
    writeTimeoutMs = base.writeTimeoutMs,
    pollIntervalMs = base.pollIntervalMs,
    keepAliveIntervalMs = 0,
    keepAliveTimeoutMs = base.keepAliveTimeoutMs,
    keepAliveWithoutCalls = false,
    streamWindow = 65535,
    connectionWindow = base.connectionWindow
  )
  val conn = connectPlain(peer.port, opts)
  val call = startOk(conn, reqHeaders("GET", "http", "/big"), true, 0)
  // Do not call h2NextEvent until the peer has watched the window stay shut.
  assertTrue(waitSem(peer.obs.gate, 20000), "the peer observed the stall")
  val o = collect(call)
  assertEqualInt(o.bodyLen, total, "the whole body arrived once the consumer resumed")
  assertEqualInt(o.checksum, checksumOf(data), "the body is intact")
  h2Close(conn)
  finishPeer(peer)
  assertEqualInt(peer.obs.n1, 65535, "the peer could send exactly one stream window")
  assertEqualInt(peer.obs.n2, 0, "the window stayed shut while nothing was consumed")
}

test "a call deadline cancels the call, tells the peer, and spares the connection" {
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      val r1 = peerReadRequest(pc)
      obs.n1 = r1.streamId
      match peerNext(pc, { ev -> isPeerReset(ev) }, 10000) {
        case Some(ev) -> match ev {
          case H2PeerReset(sid, code) -> {
            obs.n2 = sid
            obs.flag = errorCodeToLong(code) == 8i64
          }
          case _ -> ()
        }
        case None -> panic("peer: no RST_STREAM arrived")
      }
      val r2 = peerReadRequest(pc)
      peerReply(pc, r2.streamId, "second")
      peerUntilEof(pc, 5000)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val start = monotonicNanos()
  val call1 = startOk(conn, reqHeaders("POST", "http", "/slow"), true, 250)
  val o1 = collect(call1)
  val took = elapsedMs(start)
  assertEqual(failureKind(o1), "deadline", "the first call hit its deadline")
  assertTrue(took >= 200i64, "not before the deadline: " + took.toString() + " ms")
  assertTrue(took < 5000i64, "and promptly after it: " + took.toString() + " ms")
  assertTrue(statusIs(conn, H2ClientOpen), "the connection stayed open")
  val call2 = startOk(conn, reqHeaders("POST", "http", "/fast"), true, 5000)
  val o2 = collect(call2)
  assertEqual(o2.text, "second", "a later call on the same connection succeeds")
  h2Close(conn)
  finishPeer(peer)
  assertEqualInt(peer.obs.n2, peer.obs.n1, "RST_STREAM named the cancelled stream")
  assertTrue(peer.obs.flag, "with error code CANCEL")
}

test "cancel from another thread wakes a blocked reader and resets the stream" {
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      val r = peerReadRequest(pc)
      match peerNext(pc, { ev -> isPeerReset(ev) }, 10000) {
        case Some(ev) -> match ev {
          case H2PeerReset(sid, code) -> {
            obs.flag = sid == r.streamId and errorCodeToLong(code) == 8i64
          }
          case _ -> ()
        }
        case None -> panic("peer: no RST_STREAM arrived")
      }
      peerUntilEof(pc, 5000)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val call = startOk(conn, reqHeaders("POST", "http", "/never"), true, 0)
  val canceller = startJob({ -> sleepMillis(150); h2Cancel(call); "cancelled" })
  val o = collect(call)
  assertEqual(joinJob(canceller), "cancelled", "the canceller ran")
  assertEqual(failureKind(o), "cancelled", "the blocked reader saw the cancel")
  assertEqualInt(h2ClientActiveCalls(conn), 0, "the call left the table")
  h2Cancel(call)
  assertEqual(failureKind(collect(call)), "cancelled", "the terminal event repeats")
  h2Close(conn)
  finishPeer(peer)
  assertTrue(peer.obs.flag, "the peer saw RST_STREAM CANCEL for that stream")
}

test "GOAWAY: streams above last-stream-id are unprocessed, new calls are refused, in-flight calls finish" {
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      val r1 = peerReadRequest(pc)
      val r3 = peerReadRequest(pc)
      peerWrite(pc, serializeFrame(GoAwayFrame(lastStreamId = r1.streamId, errorCode = H2NoError, debugData = [])))
      // Hold the first response until the client has tried (and failed) to start another call.
      if not waitSem(obs.gate, 10000) {
        panic("peer: the client never reported")
      }
      peerReply(pc, r1.streamId, "first")
      peerUntilEof(pc, 5000)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val call1 = startOk(conn, reqHeaders("POST", "http", "/a"), true, 0)
  val call3 = startOk(conn, reqHeaders("POST", "http", "/b"), true, 0)
  val o3 = collect(call3)
  assertEqual(failureKind(o3), "unprocessed", "the stream above last-stream-id is unprocessed")
  assertTrue(retrySafe(o3), "and retry safe")
  assertTrue(statusIs(conn, H2ClientDraining), "the connection is draining")
  match h2StartCall(conn, reqHeaders("POST", "http", "/c"), true, 0) {
    case Ok(_) -> panic("a call started on a draining connection")
    case Err(e) -> assertTrue(isDrainingError(e), "new calls are refused as draining")
  }
  semPost(peer.obs.gate)
  val o1 = collect(call1)
  assertEqual(o1.text, "first", "the in-flight call still completes")
  assertTrue(waitClosed(conn, 5000), "a drained connection closes itself")
  h2Close(conn)
  finishPeer(peer)
}

test "REFUSED_STREAM is retry safe and other resets are reported with their code" {
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      val r1 = peerReadRequest(pc)
      peerWrite(pc, H2.sendRstStream(pc.h2, r1.streamId, H2RefusedStream))
      val r2 = peerReadRequest(pc)
      peerWrite(pc, H2.sendRstStream(pc.h2, r2.streamId, H2InternalError))
      peerUntilEof(pc, 5000)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val c1 = startOk(conn, reqHeaders("POST", "http", "/a"), true, 0)
  val o1 = collect(c1)
  assertEqual(failureKind(o1), "refused", "REFUSED_STREAM")
  val c2 = startOk(conn, reqHeaders("POST", "http", "/b"), true, 0)
  val o2 = collect(c2)
  assertEqual(failureKind(o2), "reset", "INTERNAL_ERROR")
  assertTrue(failureMessage(o2).contains("error code 2"), "carries the code: " + failureMessage(o2))
  assertTrue(statusIs(conn, H2ClientOpen), "a stream reset leaves the connection open")
  h2Close(conn)
  finishPeer(peer)
}

test "a peer that closes the connection mid-response fails the call and the connection" {
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      val r = peerReadRequest(pc)
      peerHeaders(pc, r.streamId, 200, false)
      val _ = peerSendWhatFits(pc, r.streamId, encodeUtf8("partial"), 0)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val call = startOk(conn, reqHeaders("GET", "http", "/x"), true, 0)
  val o = collect(call)
  assertEqual(failureKind(o), "lost", "the call failed as connection lost")
  assertEqualInt(o.status, 200, "the headers that did arrive were delivered first")
  assertEqual(o.text, "partial", "so was the data")
  assertTrue(waitClosed(conn, 5000), "the connection is closed")
  match h2StartCall(conn, reqHeaders("GET", "http", "/y"), true, 0) {
    case Ok(_) -> panic("a call started on a closed connection")
    case Err(e) -> assertTrue(isClosedError(e), "new calls are refused as closed")
  }
  h2Close(conn)
  finishPeer(peer)
}

// A peer that accepts and never speaks HTTP/2: it reads and discards.
func silentPeer(): Peer {
  startPeer(
    { pc, obs ->
      val deadline = monotonicNanos() + 30000i64 * 1000000i64
      var open = true
      while open and monotonicNanos() < deadline {
        match hostReadDeadline(pc.conn, 4096, monotonicNanos() + 25i64 * 1000000i64) {
          case Ok(bytes) -> {
            open = bytes.length > 0
          }
          case Err(e) -> match e { case ReadDeadlinePassed -> (); case ReadFailed(_) -> { open = false } }
        }
      }
    }
  )
}

test "a stalled peer: the deadline fires and the connection survives" {
  val peer = silentPeer()
  val conn = connectPlain(peer.port, fastOpts())
  val start = monotonicNanos()
  val call = startOk(conn, reqHeaders("POST", "http", "/x"), true, 300)
  val o = collect(call)
  val took = elapsedMs(start)
  assertEqual(failureKind(o), "deadline", "deadline exceeded")
  assertTrue(took >= 250i64 and took < 5000i64, "within bounds: " + took.toString() + " ms")
  assertTrue(statusIs(conn, H2ClientOpen), "no keepalive configured: the connection stays open")
  h2Close(conn)
  finishPeer(peer)
}

test "a stalled peer: an unanswered keepalive PING fails the connection and its calls" {
  val peer = silentPeer()
  val base = fastOpts()
  val opts = H2ClientOptions(
    connectTimeoutMs = base.connectTimeoutMs,
    handshakeTimeoutMs = base.handshakeTimeoutMs,
    writeTimeoutMs = base.writeTimeoutMs,
    pollIntervalMs = base.pollIntervalMs,
    keepAliveIntervalMs = 100,
    keepAliveTimeoutMs = 300,
    keepAliveWithoutCalls = false,
    streamWindow = base.streamWindow,
    connectionWindow = base.connectionWindow
  )
  val conn = connectPlain(peer.port, opts)
  val start = monotonicNanos()
  val call = startOk(conn, reqHeaders("POST", "http", "/x"), true, 0)
  val o = collect(call)
  val took = elapsedMs(start)
  assertEqual(failureKind(o), "lost", "the call failed as connection lost")
  assertTrue(failureMessage(o).contains("keepalive"), "naming the keepalive: " + failureMessage(o))
  assertTrue(took >= 350i64 and took < 8000i64, "after interval plus timeout: " + took.toString() + " ms")
  assertTrue(waitClosed(conn, 2000), "the connection closed")
  h2Close(conn)
  finishPeer(peer)
}

test "keepalive PINGs are answered by a live peer and do not disturb calls" {
  val peer = startPeer(
    { pc, obs ->
      peerHello(pc)
      val r = peerReadRequest(pc)
      // Let at least two keepalive intervals pass before answering.
      var waited = 0
      while waited < 500 {
        peerPump(pc, 25)
        waited = waited + 25
      }
      peerReply(pc, r.streamId, "alive")
      peerUntilEof(pc, 5000)
    }
  )
  val base = fastOpts()
  val opts = H2ClientOptions(
    connectTimeoutMs = base.connectTimeoutMs,
    handshakeTimeoutMs = base.handshakeTimeoutMs,
    writeTimeoutMs = base.writeTimeoutMs,
    pollIntervalMs = base.pollIntervalMs,
    keepAliveIntervalMs = 100,
    keepAliveTimeoutMs = 2000,
    keepAliveWithoutCalls = false,
    streamWindow = base.streamWindow,
    connectionWindow = base.connectionWindow
  )
  val conn = connectPlain(peer.port, opts)
  val call = startOk(conn, reqHeaders("POST", "http", "/x"), true, 0)
  val o = collect(call)
  assertEqual(o.text, "alive", "the call completed")
  h2Close(conn)
  finishPeer(peer)
}

test "close interrupts a blocked read at once, whatever the poll interval" {
  val peer = silentPeer()
  val base = fastOpts()
  val opts = H2ClientOptions(
    connectTimeoutMs = base.connectTimeoutMs,
    handshakeTimeoutMs = base.handshakeTimeoutMs,
    writeTimeoutMs = base.writeTimeoutMs,
    pollIntervalMs = 60000,
    keepAliveIntervalMs = 0,
    keepAliveTimeoutMs = base.keepAliveTimeoutMs,
    keepAliveWithoutCalls = false,
    streamWindow = base.streamWindow,
    connectionWindow = base.connectionWindow
  )
  val conn = connectPlain(peer.port, opts)
  val call = startOk(conn, reqHeaders("POST", "http", "/x"), true, 0)
  val waiter = startJob({ -> failureKind(collect(call)) })
  sleepMillis(300)
  val start = monotonicNanos()
  h2Close(conn)
  val took = elapsedMs(start)
  assertTrue(took < 5000i64, "close returned promptly: " + took.toString() + " ms")
  assertEqual(joinJob(waiter), "lost", "the blocked consumer was released with connection lost")
  assertTrue(statusIs(conn, H2ClientClosed), "closed")
  assertEqual(h2ClientCloseReason(conn), "closed by caller", "with the reason")
  h2Close(conn)
  finishPeer(peer)
}

test "connect to a closed port is a transport error" {
  val l = match hostListen("127.0.0.1", 0) { case Ok(x) -> x; case Err(e) -> panic("listen failed") }
  val port = hostLocalPort(l)
  hostStopListener(l)
  match h2Connect(H2Plain(host = "127.0.0.1", port = port), fastOpts()) {
    case Ok(c) -> {
      h2Close(c)
      panic("connected to a closed port")
    }
    case Err(e) -> assertTrue(isTransportError(e), "transport error: " + H2DialError.message(e))
  }
}

test "a peer that violates the protocol fails the connection with a protocol error" {
  val peer = startPeer(
    { pc, obs ->
      // No SETTINGS first: a PING instead.
      peerWrite(pc, serializeFrame(PingFrame(opaqueData = encodeUtf8("12345678"), ack = false)))
      peerUntilEof(pc, 5000)
    }
  )
  val conn = connectPlain(peer.port, fastOpts())
  val call = startOk(conn, reqHeaders("POST", "http", "/x"), true, 0)
  val o = collect(call)
  assertEqual(failureKind(o), "protocol", "protocol error: " + failureMessage(o))
  assertTrue(waitClosed(conn, 3000), "the connection is closed")
  h2Close(conn)
  finishPeer(peer)
}

// ---------------------------------------------------------------------------
// TLS with ALPN against the shared pure-Lyric server driver.
// ---------------------------------------------------------------------------
func serverIdentity(): Identity {
  match Identity.fromPem(serverCertPem, serverKeyPem) {
    case Ok(id) -> id
    case Err(e) -> panic("server identity load failed: " + TlsError.message(e))
  }
}

func startTlsServer(): HttpListener {
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  match startListenerTls("127.0.0.1", 0, cfg) {
    case Ok(l) -> l
    case Err(e) -> panic("startListenerTls failed: " + TlsListenError.message(e))
  }
}

func serveEcho(l: in HttpListener, n: in Int): Job {
  startJob(
    { ->
      var i = 0
      while i < n {
        val ctx = nextContext(l)
        respondText(
          ctx,
          200,
          "m=" + requestMethod(ctx) + ";path=" + requestPath(ctx) + ";len=" + requestBodyBytes(ctx).length.toString()
        )
        i = i + 1
      }
      "served"
    }
  )
}

func tlsTarget(port: in Int): H2Target {
  H2Secure(
    host = "localhost",
    port = port,
    trust = TlsTrustExclusive(caPem = caCertPem),
    identity = None,
    minVersion = Tls12
  )
}

func connectTls(port: in Int): H2ClientConnection {
  match h2Connect(tlsTarget(port), fastOpts()) {
    case Ok(c) -> c
    case Err(e) -> panic("h2Connect (TLS) failed: " + H2DialError.message(e))
  }
}

test "TLS+ALPN h2: a GET round trip against Std.HttpServer" {
  val l = startTlsServer()
  val port = hostLocalPort(l.transport)
  val server = serveEcho(l, 1)
  val conn = connectTls(port)
  val call = startOk(conn, reqHeaders("GET", "https", "/hello?x=1"), true, 5000)
  val o = collect(call)
  assertEqualInt(o.status, 200, "status")
  assertTrue(o.text.contains("m=GET;path=/hello"), "the handler saw the request: " + o.text)
  h2Close(conn)
  val _ = joinJob(server)
  stopListener(l)
}

test "TLS+ALPN h2: a 1 MiB request body flows under flow control" {
  val l = startTlsServer()
  val port = hostLocalPort(l.transport)
  val server = serveEcho(l, 1)
  val conn = connectTls(port)
  val call = startOk(conn, reqHeaders("POST", "https", "/up"), false, 30000)
  sendOk(call, patternBytes(1048576), true)
  val o = collect(call)
  assertEqualInt(o.status, 200, "status")
  assertTrue(o.text.contains("len=1048576"), "the server received every byte: " + o.text)
  h2Close(conn)
  val _ = joinJob(server)
  stopListener(l)
}

test "TLS+ALPN h2: concurrent calls share one connection" {
  val l = startTlsServer()
  val port = hostLocalPort(l.transport)
  val total = 6
  val server = serveEcho(l, total)
  val conn = connectTls(port)
  val jobs: List[Job] = newList()
  var i = 0
  while i < total {
    val n = i
    jobs.add(
      startJob(
        { ->
          val call = startOk(conn, reqHeaders("POST", "https", "/p" + n.toString()), false, 30000)
          sendOk(call, patternBytes(1000 * (n + 1)), true)
          collect(call).text
        }
      )
    )
    i = i + 1
  }
  var all = ""
  var j = 0
  while j < total {
    all = all + joinJob(jobs[j]) + "|"
    j = j + 1
  }
  var k = 0
  while k < total {
    assertTrue(
      all.contains("path=/p" + k.toString() + ";len=" + (1000 * (k + 1)).toString() + "|"),
      "call " + k.toString() + " got its own reply: " + all
    )
    k = k + 1
  }
  h2Close(conn)
  val _ = joinJob(server)
  stopListener(l)
}

test "TLS: an untrusted server certificate is a TLS error" {
  val l = startTlsServer()
  val port = hostLocalPort(l.transport)
  val target = H2Secure(
    host = "localhost",
    port = port,
    trust = TlsTrustExclusive(caPem = caBPem),
    identity = None,
    minVersion = Tls12
  )
  match h2Connect(target, fastOpts()) {
    case Ok(c) -> {
      h2Close(c)
      panic("connected despite an untrusted certificate")
    }
    case Err(e) -> assertTrue(isTlsError(e), "TLS error: " + H2DialError.message(e))
  }
  stopListener(l)
}
