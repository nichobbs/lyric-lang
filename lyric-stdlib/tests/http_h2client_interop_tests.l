//! stdlib/tests/http_h2client_interop_tests.l — `Std.HttpEngine.H2Client`
//! against an independent HTTP/2 implementation, `nghttpd` (nghttp2), over
//! cleartext prior knowledge and over TLS with ALPN `h2` (docs/72 slice 5).
//!
//! Not runnable on its own: `scripts/ci/h2conn-tests.sh` starts `nghttpd` on two
//! ports with a document root holding `index.html` and `big.bin`, generates the
//! certificate, and passes the coordinates in the environment:
//!
//!   - `LYRIC_NGHTTPD_H2C_PORT`, `LYRIC_NGHTTPD_TLS_PORT`: the two listeners
//!   - `LYRIC_NGHTTPD_CERT`: the PEM certificate the TLS listener serves, the
//!     only trust anchor the client is given (`localhost`)
//!   - `LYRIC_NGHTTPD_BIG_BYTES`: the size of `big.bin`
//!
//! A missing variable fails the suite: the script is the only caller, so
//! there is nothing to skip.
@test_module
package Std.HttpEngine.H2Client.InteropTests

import Std.Core
import Std.Collections
import Std.String
import Std.Parse
import Std.Encoding
import Std.Tls
import Std.HttpServerHost
import Std.HttpEngine
import Std.HttpEngine.H2Client
import Std.Environment as Env
import Std.File as File
import Std.Time
import Std.Testing

val indexBody = "lyric-h2-interop\n"

func envOrFail(name: in String): String {
  match Env.getVar(name) {
    case Ok(v) -> v
    case Err(_) -> panic("the interop suite needs " + name + "; run it through scripts/ci/h2conn-tests.sh")
  }
}

func envInt(name: in String): Int {
  match tryParseInt(envOrFail(name)) {
    case Ok(n) -> n
    case Err(_) -> panic(name + " is not an integer")
  }
}

func hf(name: in String, value: in String): HeaderField {
  HeaderField(name = name, value = value)
}

func getHeaders(scheme: in String, path: in String): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":method", "GET"))
  h.add(hf(":scheme", scheme))
  h.add(hf(":path", path))
  h.add(hf(":authority", "localhost"))
  h
}

func opts(): H2ClientOptions {
  val d = h2ClientDefaults()
  H2ClientOptions(
    connectTimeoutMs = 5000,
    handshakeTimeoutMs = 5000,
    writeTimeoutMs = 10000,
    pollIntervalMs = 20,
    keepAliveIntervalMs = 0,
    keepAliveTimeoutMs = d.keepAliveTimeoutMs,
    keepAliveWithoutCalls = false,
    streamWindow = d.streamWindow,
    connectionWindow = d.connectionWindow
  )
}

func connectPlain(): H2ClientConnection {
  match h2Connect(H2Plain(host = "127.0.0.1", port = envInt("LYRIC_NGHTTPD_H2C_PORT")), opts()) {
    case Ok(c) -> c
    case Err(e) -> panic("h2c connect failed: " + H2DialError.message(e))
  }
}

func connectTls(): H2ClientConnection {
  val target = H2Secure(
    host = "localhost",
    port = envInt("LYRIC_NGHTTPD_TLS_PORT"),
    trust = TlsTrustExclusive(caPem = File.readTextOrPanic(envOrFail("LYRIC_NGHTTPD_CERT"))),
    identity = None,
    minVersion = Tls12
  )
  match h2Connect(target, opts()) {
    case Ok(c) -> c
    case Err(e) -> panic("TLS connect failed: " + H2DialError.message(e))
  }
}

ref record Result3 {
  var status: Int
  var bodyLen: Int
  var text: String
  var ended: Bool
  var failure: String
}

func fetch(conn: in H2ClientConnection, scheme: in String, path: in String): Result3 {
  val r = Result3(status = 0, bodyLen = 0, text = "", ended = false, failure = "")
  val call = match h2StartCall(conn, getHeaders(scheme, path), true, 60000) {
    case Ok(c) -> c
    case Err(_) -> panic("h2StartCall refused")
  }
  var go = true
  while go {
    match h2NextEvent(call) {
      case H2CallHeaders(st, _) -> {
        r.status = st
      }
      case H2CallData(d) -> {
        if r.bodyLen < 4096 {
          match tryDecodeUtf8(d) {
            case Some(t) -> {
              r.text = r.text + t
            }
            case None -> ()
          }
        }
        r.bodyLen = r.bodyLen + d.length
      }
      case H2CallEnded -> {
        r.ended = true
        go = false
      }
      case H2CallFailed(f) -> {
        r.failure = H2CallFailure.message(f)
        go = false
      }
      case _ -> ()
    }
  }
  r
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
  var waited = 0
  while waited < 60000 and not semTryWait(j.done) {
    sleepMillis(5)
    waited = waited + 5
  }
  if waited >= 60000 {
    panic("job did not finish")
  }
  if j.failure.length > 0 {
    panic("job failed: " + j.failure)
  }
  j.text
}

test "nghttpd h2c: a small GET" {
  val conn = connectPlain()
  val r = fetch(conn, "http", "/index.html")
  assertEqual(r.failure, "", "no failure")
  assertEqualInt(r.status, 200, "status")
  assertEqual(r.text, indexBody, "body")
  assertTrue(r.ended, "ended")
  h2Close(conn)
}

test "nghttpd h2c: a missing path is a 404" {
  val conn = connectPlain()
  val r = fetch(conn, "http", "/does-not-exist")
  assertEqual(r.failure, "", "no failure")
  assertEqualInt(r.status, 404, "status")
  h2Close(conn)
}

test "nghttpd h2c: a multi-MiB body flows under flow control and window credit" {
  val conn = connectPlain()
  val r = fetch(conn, "http", "/big.bin")
  assertEqual(r.failure, "", "no failure")
  assertEqualInt(r.status, 200, "status")
  assertEqualInt(r.bodyLen, envInt("LYRIC_NGHTTPD_BIG_BYTES"), "every byte arrived")
  h2Close(conn)
}

test "nghttpd TLS+ALPN: a small GET" {
  val conn = connectTls()
  val r = fetch(conn, "https", "/index.html")
  assertEqual(r.failure, "", "no failure")
  assertEqualInt(r.status, 200, "status")
  assertEqual(r.text, indexBody, "body")
  h2Close(conn)
}

test "nghttpd TLS+ALPN: the large body" {
  val conn = connectTls()
  val r = fetch(conn, "https", "/big.bin")
  assertEqual(r.failure, "", "no failure")
  assertEqualInt(r.bodyLen, envInt("LYRIC_NGHTTPD_BIG_BYTES"), "every byte arrived")
  h2Close(conn)
}

test "nghttpd TLS+ALPN: concurrent calls share one connection" {
  val conn = connectTls()
  val jobs: List[Job] = newList()
  var i = 0
  while i < 8 {
    jobs.add(
      startJob({ -> val r = fetch(conn, "https", "/index.html"); r.failure + "|" + r.status.toString() + "|" + r.text })
    )
    i = i + 1
  }
  var j = 0
  while j < 8 {
    assertEqual(joinJob(jobs[j]), "|200|" + indexBody, "call " + j.toString())
    j = j + 1
  }
  h2Close(conn)
}
