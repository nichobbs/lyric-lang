//! benchmarks/http_server/loadgen.l - HTTP/1.1 load generator for the docs/73 baseline (B1, B2, B3, B5, B6).
//!
//! `wrk` and `h2load` are not available on every CI image (docs/73 section 4.4, spike d), so the
//! generator is a small Lyric program over `Std.TcpHost` and `Std.Task`. It speaks plain HTTP/1.1
//! (no TLS, no h2; the h2 scenario B4 is driven by `curl --http2` from the driver script) and runs on
//! dotnet, where `Std.Task` workers are real OS threads and the transport is the fastest of the three
//! targets, so the generator is the least likely bottleneck. Run it against the server of any target.
//!
//! Configuration is by environment variable:
//!
//!   LG_MODE      keepalive | connclose | echo | idle | soak
//!   LG_PORT      target port on 127.0.0.1 (default 8180)
//!   LG_CONNS     concurrent worker connections (default 64)
//!   LG_SECONDS   measured duration in seconds (default 10)
//!   LG_WARMUP    warm-up seconds before measuring (default 3; same mode, results discarded)
//!   LG_BODY      echo mode: request body bytes (default 65536)
//!   LG_IDLE      idle mode: idle keep-alive connections to hold open (default 10000)
//!   LG_RATE      soak mode: total requests per second to offer (default 1000)
//!
//! Output is one `key=value` line per figure:
//!
//!   requests, errors, seconds, rps, mib_s (echo), p50_ms, p99_ms, max_ms
//!   idle: idle_open, idle_failed, idle_alive_after
//!
//! Latency is measured per request from the write to the last response byte (plus connect time in
//! `connclose` mode). An error is any failed connect, read, write, non-200 status or response
//! without a Content-Length.
//!
//!   lyric run benchmarks/http_server/loadgen.l --target dotnet
//!
//! Not part of CI (see README.md).
package Bench.LoadGen

import Std.Core
import Std.Collections
import Std.Console
import Std.Encoding
import Std.Environment
import Std.Parse
import Std.Sort
import Std.String
import Std.Task as Task
import Std.TcpHost
import Std.Time as Time

func intVar(name: in String, fallback: in Int): Int {
  match getVar(name) {
    case Err(_) -> fallback
    case Ok(s) -> match parseOptInt(s) { case Some(n) -> n; case None -> fallback }
  }
}

func requestBytes(method: in String, body: in String, close: in Bool): slice[Byte] {
  val conn = if close { "Connection: close\r\n" } else { "Connection: keep-alive\r\n" }
  if method == "POST" {
    encodeUtf8(
      "POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\n" + conn + "Content-Type: application/octet-stream\r\nContent-Length: " +
        body.length.toString() +
        "\r\n\r\n" +
        body
    )
  } else {
    encodeUtf8("GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\n" + conn + "\r\n")
  }
}

func dial(port: in Int): Option[Conn] {
  match hostConnect("127.0.0.1", port, 5000) {
    case Ok(c) -> {
      hostSetIoTimeout(c, 30000)
      Some(value = c)
    }
    case Err(_) -> None
  }
}

// Reads one response (no pipelining, so the connection holds exactly one). Returns 200 on a
// complete 200 response and a negative number for every failure.
func readResponse(conn: in Conn): Int {
  var head = ""
  var headerEnd = -1
  var contentLength = -1
  var total = 0
  var status = -2
  var chunked = false
  var tail = ""
  var done = false
  var result = -1
  while not done {
    match hostRead(conn, 65536) {
      case Err(_) -> {
        done = true
        result = -1
      }
      case Ok(chunk) -> {
        if chunk.length == 0 {
          done = true
          result = -1
        } else {
          total = total + chunk.length
          if headerEnd < 0 {
            match tryDecodeUtf8(chunk) {
              case None -> {
                done = true
                result = -3
              }
              case Some(text) -> {
                head = head + text
                val idx = indexOfRaw(head, "\r\n\r\n")
                if idx >= 0 {
                  headerEnd = idx + 4
                  val lower = toLower(substring(head, 0, idx))
                  status = match parseOptInt(substring(lower, 9, 3)) { case Some(n) -> n; case None -> -2 }
                  val cl = indexOfRaw(lower, "content-length:")
                  if cl >= 0 {
                    val rest = substring(lower, cl + 15)
                    val eol = indexOfRaw(rest, "\r\n")
                    val raw = if eol >= 0 { substring(rest, 0, eol) } else { rest }
                    contentLength = match parseOptInt(trim(raw)) { case Some(n) -> n; case None -> -1 }
                  }
                  if indexOfRaw(lower, "transfer-encoding: chunked") >= 0 {
                    chunked = true
                    tail = substring(head, headerEnd)
                  } else if contentLength < 0 {
                    done = true
                    result = -4
                  }
                }
              }
            }
          } else if chunked {
            match tryDecodeUtf8(chunk) {
              case None -> {
                done = true
                result = -3
              }
              case Some(text) -> {
                tail = tail + text
                if tail.length > 16 {
                  tail = substring(tail, tail.length - 16)
                }
              }
            }
          }
          if not done and chunked {
            // The last chunk is "0\r\n\r\n"; the tail keeps the last bytes across reads.
            if tail.length >= 5 and substring(tail, tail.length - 5) == "0\r\n\r\n" {
              done = true
              result = if status == 200 { 200 } else { -5 }
            }
          } else if not done and headerEnd >= 0 and total - headerEnd >= contentLength {
            done = true
            result = if status == 200 { 200 } else { -5 }
          }
        }
      }
    }
  }
  result
}

func exchange(conn: in Conn, request: in slice[Byte]): Bool {
  match hostWrite(conn, request) {
    case Err(_) -> false
    case Ok(_) -> readResponse(conn) == 200
  }
}

// One keep-alive worker: requests back to back until `endNanos`, reconnecting after any error.
// `lat` receives one entry per request: elapsed nanoseconds, or -1 for an error. `startNanos`
// is when measuring begins; earlier requests (warm-up) are not recorded.
func keepAliveWorker(
  port: in Int,
  startNanos: in Long,
  endNanos: in Long,
  request: in slice[Byte],
  intervalMs: in Int,
  lat: in List[Long],
): Unit {
  var conn = dial(port)
  while Time.monotonicNanos() < endNanos {
    match conn {
      case None -> {
        lat.add(-1)
        Time.sleepMillis(50)
        conn = dial(port)
      }
      case Some(c) -> {
        val t0 = Time.monotonicNanos()
        val ok = exchange(c, request)
        val t1 = Time.monotonicNanos()
        if t0 >= startNanos {
          if ok {
            lat.add(t1 - t0)
          } else {
            lat.add(-1)
          }
        }
        if not ok {
          hostClose(c)
          conn = dial(port)
        }
        if intervalMs > 0 {
          val spent = ((t1 - t0) / 1000000).toInt()
          if intervalMs > spent {
            Time.sleepMillis(intervalMs - spent)
          }
        }
      }
    }
  }
  match conn {
    case Some(c) -> hostClose(c)
    case None -> ()
  }
}

// One connection-per-request worker (B2): connect, request with `Connection: close`, read, close.
func connCloseWorker(
  port: in Int, startNanos: in Long, endNanos: in Long, request: in slice[Byte], lat: in List[Long]
): Unit {
  while Time.monotonicNanos() < endNanos {
    val t0 = Time.monotonicNanos()
    val ok = match dial(port) { case None -> false; case Some(c) -> { val r = exchange(c, request); hostClose(c); r } }
    val t1 = Time.monotonicNanos()
    if t0 >= startNanos {
      if ok {
        lat.add(t1 - t0)
      } else {
        lat.add(-1)
      }
    }
  }
}

func runWorkers(
  mode: in String,
  port: in Int,
  conns: in Int,
  startNanos: in Long,
  endNanos: in Long,
  request: in slice[Byte],
  intervalMs: in Int,
): List[List[Long]] {
  val all: List[List[Long]] = newList()
  val sc = Task.makeScope()
  var i = 0
  while i < conns {
    val lat: List[Long] = newList()
    all.add(lat)
    if mode == "connclose" {
      Task.scopeSpawn(sc, { -> connCloseWorker(port, startNanos, endNanos, request, lat) })
    } else {
      Task.scopeSpawn(sc, { -> keepAliveWorker(port, startNanos, endNanos, request, intervalMs, lat) })
    }
    i = i + 1
  }
  val _ = await Task.awaitAll(sc)
  all
}

func percentileMs(sorted: in slice[Long], p: in Double): Double {
  if sorted.length == 0 {
    return 0.0
  }
  var idx = (p * sorted.length.toDouble()).toInt()
  if idx >= sorted.length {
    idx = sorted.length - 1
  }
  sorted[idx].toDouble() / 1000000.0
}

func report(all: in List[List[Long]], seconds: in Double, bodyBytes: in Int): Unit {
  val ok: List[Long] = newList()
  var errors = 0
  var wi = 0
  while wi < all.count {
    val lat = all[wi]
    var i = 0
    while i < lat.count {
      if lat[i] < 0 {
        errors = errors + 1
      } else {
        ok.add(lat[i])
      }
      i = i + 1
    }
    wi = wi + 1
  }
  val sorted = sortLongs(ok.toArray())
  println("requests=" + sorted.length.toString())
  println("errors=" + errors.toString())
  println("seconds=" + seconds.toString())
  println("rps=" + (sorted.length.toDouble() / seconds).toString())
  if bodyBytes > 0 {
    println("mib_s=" + (sorted.length.toDouble() * bodyBytes.toDouble() / 1048576.0 / seconds).toString())
  }
  println("p50_ms=" + percentileMs(sorted, 0.5).toString())
  println("p99_ms=" + percentileMs(sorted, 0.99).toString())
  println("max_ms=" + percentileMs(sorted, 0.99999).toString())
}

// B5: hold `idleCount` idle keep-alive connections while a few connections trickle requests, then
// check that the idle connections still answer.
func runIdle(port: in Int, idleCount: in Int, seconds: in Int): Unit {
  val held: List[Conn] = newList()
  var failed = 0
  var consecutiveFailures = 0
  var i = 0
  // Stop after 20 failures in a row (a server at its connection cap leaves every further connect
  // hanging for the 5 s connect timeout); `idle_failed` counts the connections never opened.
  while i < idleCount and consecutiveFailures < 20 {
    match dial(port) {
      case Some(c) -> {
        held.add(c)
        consecutiveFailures = 0
      }
      case None -> {
        failed = failed + 1
        consecutiveFailures = consecutiveFailures + 1
      }
    }
    i = i + 1
  }
  failed = failed + (idleCount - i)
  println("idle_open=" + held.count.toString())
  println("idle_failed=" + failed.toString())
  println("IDLE_READY")
  val request = requestBytes("GET", "", false)
  val startNanos = Time.monotonicNanos()
  val endNanos = startNanos + seconds.toLong() * 1000000000
  val all = runWorkers("keepalive", port, 8, startNanos, endNanos, request, 20)
  report(all, seconds.toDouble(), 0)
  var alive = 0
  var j = 0
  while j < held.count {
    if exchange(held[j], request) {
      alive = alive + 1
    }
    hostClose(held[j])
    j = j + 1
  }
  println("idle_alive_after=" + alive.toString())
}

func main(): Int {
  val mode = getVarOrDefault("LG_MODE", "keepalive")
  val port = intVar("LG_PORT", 8180)
  val conns = intVar("LG_CONNS", 64)
  val seconds = intVar("LG_SECONDS", 10)
  val warmup = intVar("LG_WARMUP", 3)
  val bodyBytes = intVar("LG_BODY", 65536)
  if mode == "idle" {
    runIdle(port, intVar("LG_IDLE", 10000), seconds)
    return 0
  }
  val request = if mode == "echo" {
    requestBytes("POST", repeat("a", bodyBytes), false)
  } else if mode == "connclose" {
    requestBytes("GET", "", true)
  } else {
    requestBytes("GET", "", false)
  }
  val intervalMs = if mode == "soak" {
    // total offered rate split over `conns` workers
    val perWorker = intVar("LG_RATE", 1000) / conns
    if perWorker > 0 {
      1000 / perWorker
    } else {
      1000
    }
  } else {
    0
  }
  val startNanos = Time.monotonicNanos() + warmup.toLong() * 1000000000
  val endNanos = startNanos + seconds.toLong() * 1000000000
  val all = runWorkers(mode, port, conns, startNanos, endNanos, request, intervalMs)
  report(all, seconds.toDouble(), if mode == "echo" { bodyBytes } else { 0 })
  0
}
