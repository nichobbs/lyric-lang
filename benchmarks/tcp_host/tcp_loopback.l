//! benchmarks/tcp_host/tcp_loopback.l - Std.TcpHost loopback transport microbenchmark (docs/73 B1).
//!
//! Measures the transport alone, with no HTTP above it: a server task echoes every chunk it reads
//! and the main thread is the client, over `127.0.0.1` on an ephemeral port.
//!
//!   - latency: 1-byte ping-pong, mean round-trip time in microseconds;
//!   - throughput: for each message size, the client writes one message and reads the whole echo
//!     back, repeated until `bytesPerSize` bytes have gone each way; reported as MiB/s of echoed
//!     payload.
//!
//! The measurement runs twice: `tcp.*` with no I/O timeout and `tcp_timeout.*` with a 30 s I/O timeout
//! on both ends (on the JVM that arms the write watchdog around every write).
//!
//! Each figure is the best of `rounds` rounds after one warm-up pass, so JIT compilation (dotnet,
//! JVM) is out of the number. Output is one `key=value` line per measurement so a script can
//! compare targets:
//!
//!   lyric run benchmarks/tcp_host/tcp_loopback.l --target dotnet
//!   lyric run benchmarks/tcp_host/tcp_loopback.l --target jvm
//!   lyric run benchmarks/tcp_host/tcp_loopback.l --target native
//!
//! Not part of CI (see README.md). The acceptance of docs/73 S1 is that the JVM figures are no
//! worse than twice the dotnet figures.
package Bench.TcpLoopback

import Std.Core
import Std.Collections
import Std.Console
import Std.Encoding
import Std.String
import Std.Task as Task
import Std.TcpHost
import Std.Time as Time

val pingCount: Int = 20000

val rounds: Int = 3

val bytesPerSize: Int = 32000000

func listenLoopback(): Listener {
  match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
}

// Echo every chunk until the client closes its half.
func echoServer(l: in Listener, ioTimeoutMs: in Int): Unit {
  match hostAccept(l) {
    case Err(_) -> ()
    case Ok(conn) -> {
      hostSetIoTimeout(conn, ioTimeoutMs)
      var open = true
      while open {
        match hostRead(conn, 65536) {
          case Err(_) -> {
            open = false
          }
          case Ok(chunk) -> if chunk.length == 0 {
            open = false
          } else {
            match hostWrite(conn, chunk) {
              case Ok(_) -> ()
              case Err(_) -> {
                open = false
              }
            }
          }
        }
      }
      hostClose(conn)
    }
  }
}

func readCount(conn: in Conn, expected: in Int): Unit {
  var got = 0
  while got < expected {
    match hostRead(conn, 65536) {
      case Err(e) -> panic("read failed: " + TcpError.message(e))
      case Ok(chunk) -> {
        if chunk.length == 0 {
          panic("end of stream after " + got.toString() + " of " + expected.toString())
        }
        got = got + chunk.length
      }
    }
  }
}

func send(conn: in Conn, bytes: in slice[Byte]): Unit {
  match hostWrite(conn, bytes) {
    case Ok(_) -> ()
    case Err(e) -> panic("write failed: " + TcpError.message(e))
  }
}

func millisSince(started: in Long): Double {
  (Time.monotonicNanos() - started).toDouble() / 1000000.0
}

// Mean round trip of a 1-byte message, in microseconds.
func pingMicros(conn: in Conn): Double {
  val one = encodeUtf8("x")
  val started = Time.monotonicNanos()
  var i = 0
  while i < pingCount {
    send(conn, one)
    readCount(conn, 1)
    i = i + 1
  };
  (Time.monotonicNanos() - started).toDouble() / 1000.0 / pingCount.toDouble()
}

// MiB/s of payload echoed with messages of `size` bytes.
func echoMiBPerSecond(conn: in Conn, size: in Int): Double {
  val message = encodeUtf8(repeat("0123456789abcdef", size / 16))
  val count = bytesPerSize / size
  val started = Time.monotonicNanos()
  var i = 0
  while i < count {
    send(conn, message)
    readCount(conn, size)
    i = i + 1
  }
  val seconds = millisSince(started) / 1000.0;
  (count * size).toDouble() / 1048576.0 / seconds
}

func best(values: in List[Double], higherIsBetter: in Bool): Double {
  var b = values[0]
  var i = 1
  while i < values.count {
    if higherIsBetter {
      if values[i] > b {
        b = values[i]
      }
    } else if values[i] < b {
      b = values[i]
    }
    i = i + 1
  }
  b
}

// One full measurement over a fresh connection pair; `ioTimeoutMs` > 0 sets the I/O timeout on both
// ends, which on the JVM arms the write watchdog around every write.
func measure(prefix: in String, ioTimeoutMs: in Int): Unit {
  val l = listenLoopback()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> echoServer(l, ioTimeoutMs) })
  val conn = match hostConnect("127.0.0.1", hostLocalPort(l), 5000) {
    case Ok(c) -> c
    case Err(e) -> panic("connect failed: " + TcpError.message(e))
  }
  hostSetIoTimeout(conn, ioTimeoutMs)
  val sizes: List[Int] = newList()
  sizes.add(64)
  sizes.add(1024)
  sizes.add(16384)
  sizes.add(262144)
  // Warm-up pass: reaches steady state before anything is timed.
  val warm = pingMicros(conn)
  var wi = 0
  while wi < sizes.count {
    val _ = echoMiBPerSecond(conn, sizes[wi])
    wi = wi + 1
  }
  val pings: List[Double] = newList()
  var r = 0
  while r < rounds {
    pings.add(pingMicros(conn))
    r = r + 1
  }
  println(prefix + ".ping_us=" + best(pings, false).toString())
  var si = 0
  while si < sizes.count {
    val samples: List[Double] = newList()
    var k = 0
    while k < rounds {
      samples.add(echoMiBPerSecond(conn, sizes[si]))
      k = k + 1
    }
    println(prefix + ".echo_" + sizes[si].toString() + "_mib_s=" + best(samples, true).toString())
    si = si + 1
  }
  hostClose(conn)
  val _ = await Task.awaitAll(sc)
  hostStopListener(l)
}

func main(): Int {
  measure("tcp", 0)
  measure("tcp_timeout", 30000)
  0
}
