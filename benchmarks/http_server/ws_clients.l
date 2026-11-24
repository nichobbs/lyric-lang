//! benchmarks/http_server/ws_clients.l - WebSocket fan-out clients (docs/73 S0, B7).
//!
//! Opens `WS_CONNS` (default 1000) WebSocket connections to `ws_server.l`, reads the broadcast frames
//! on one task per connection and records, for each message, the delivery latency: the receiving
//! clock minus the 13-digit epoch-millisecond timestamp the server wrote at the start of the
//! broadcast (same machine, millisecond resolution). Build it for `--target jvm`: 1000 blocked readers
//! are cheap virtual threads there, but on dotnet each `Std.Task` worker is a threadpool thread and
//! the pool grows slowly past its minimum.
//!
//! Environment: `WS_PORT` (8190), `WS_CONNS` (1000), `WS_SECONDS` (30 measured seconds after connecting).
//! Output: `connected`, `failed`, `messages`, `drops` (messages short of connected x broadcasts seen by
//! the fastest connection), `p50_ms`, `p99_ms`, `max_ms`. Not part of CI (see README.md).
package Bench.WsClients

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

// Handshake; returns the bytes already read past the response head (the first frames can arrive with it).
func handshake(conn: in Conn): Option[List[Byte]] {
  val req = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
  match hostWrite(conn, encodeUtf8(req)) {
    case Err(_) -> return None
    case Ok(_) -> ()
  }
  val acc: List[Byte] = newList()
  var headEnd = -1
  while headEnd < 0 {
    match hostRead(conn, 4096) {
      case Err(_) -> return None
      case Ok(chunk) -> {
        if chunk.length == 0 {
          return None
        }
        var i = 0
        while i < chunk.length {
          acc.add(chunk[i])
          i = i + 1
        }
      }
    }
    var j = 3
    while headEnd < 0 and j < acc.count {
      if acc[j].toInt() == 10 and acc[j - 1].toInt() == 13 and acc[j - 2].toInt() == 10 and acc[j - 3].toInt() == 13 {
        headEnd = j + 1
      }
      j = j + 1
    }
  }
  val rest: List[Byte] = newList()
  var k = headEnd
  while k < acc.count {
    rest.add(acc[k])
    k = k + 1
  }
  Some(value = rest)
}

// Reads frames until the connection ends or `endAtMs` passes. Each text frame yields one latency sample.
func reader(port: in Int, endAtMs: in Long, samples: in List[Long], connected: in List[Int]): Unit {
  val conn = match hostConnect("127.0.0.1", port, 10000) {
    case Ok(c) -> c
    case Err(_) -> {
      connected.add(0)
      return
    }
  }
  val buf = match handshake(conn) {
    case None -> {
      connected.add(0)
      hostClose(conn)
      return
    }
    case Some(rest) -> rest
  }
  connected.add(1)
  var pos = 0
  var open = true
  while open and Time.nowEpochMillis() < endAtMs {
    // Parse as many whole frames as the buffer holds.
    var parsing = true
    while parsing {
      val avail = buf.count - pos
      if avail < 2 {
        parsing = false
      } else {
        val b1 = buf[pos + 1].toInt().and(127)
        var headLen = 2
        var payloadLen = b1
        if b1 == 126 {
          headLen = 4
          payloadLen = if avail >= 4 { buf[pos + 2].toInt().shl(8).or(buf[pos + 3].toInt()) } else { 0 }
        }
        if avail < headLen or avail < headLen + payloadLen {
          parsing = false
        } else {
          val opcode = buf[pos].toInt().and(15)
          if opcode == 1 and payloadLen >= 13 {
            var ts = 0i64
            var d = 0
            while d < 13 {
              ts = ts * 10 + (buf[pos + headLen + d].toInt() - 48).toLong()
              d = d + 1
            }
            samples.add(Time.nowEpochMillis() - ts)
          } else if opcode == 8 {
            open = false
          }
          pos = pos + headLen + payloadLen
        }
      }
    }
    if open {
      // Drop consumed bytes so the buffer stays small, then read more.
      if pos > 0 and pos == buf.count {
        buf.clear()
        pos = 0
      }
      match hostRead(conn, 65536) {
        case Err(_) -> {
          open = false
        }
        case Ok(chunk) -> if chunk.length == 0 {
          open = false
        } else {
          var i = 0
          while i < chunk.length {
            buf.add(chunk[i])
            i = i + 1
          }
        }
      }
    }
  }
  hostClose(conn)
}

func main(): Int {
  val port = intVar("WS_PORT", 8190)
  val conns = intVar("WS_CONNS", 1000)
  val seconds = intVar("WS_SECONDS", 30)
  val endAtMs = Time.nowEpochMillis() + seconds.toLong() * 1000
  val all: List[List[Long]] = newList()
  val connected: List[Int] = newList()
  val sc = Task.makeScope()
  var i = 0
  while i < conns {
    val samples: List[Long] = newList()
    all.add(samples)
    Task.scopeSpawn(sc, { -> reader(port, endAtMs, samples, connected) })
    i = i + 1
  }
  val _ = await Task.awaitAll(sc)
  val merged: List[Long] = newList()
  var maxPerConn = 0
  var minPerConn = 1000000000
  var wi = 0
  while wi < all.count {
    val s = all[wi]
    if s.count > 0 {
      if s.count > maxPerConn {
        maxPerConn = s.count
      }
      if s.count < minPerConn {
        minPerConn = s.count
      }
    }
    var k = 0
    while k < s.count {
      merged.add(s[k])
      k = k + 1
    }
    wi = wi + 1
  }
  var ok = 0
  var ci = 0
  while ci < connected.count {
    ok = ok + connected[ci]
    ci = ci + 1
  }
  val sorted = sortLongs(merged.toArray())
  println("connected=" + ok.toString())
  println("failed=" + (conns - ok).toString())
  println("messages=" + sorted.length.toString())
  println("max_per_connection=" + maxPerConn.toString())
  println("min_per_connection=" + minPerConn.toString())
  if sorted.length > 0 {
    println("p50_ms=" + sorted[sorted.length / 2].toString())
    println("p99_ms=" + sorted[(sorted.length * 99) / 100].toString())
    println("max_ms=" + sorted[sorted.length - 1].toString())
  }
  0
}
