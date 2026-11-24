//! SPIKE (docs/73 S0 spike a), not shipped: exercises the reduced `Std.SpikeServer` driver.
//!
//! A puller task answers `/a`, `/b`, `/c` with "hello:<path>"; the main thread is an HTTP/1.1 client
//! that sends the three requests down ONE keep-alive connection and checks each reply, then stops the
//! listener. Prints `SPIKE-OK` or panics.
package Spike.Driver

import Std.Core
import Std.Collections
import Std.Console
import Std.Encoding
import Std.String
import Std.Task as Task
import Std.TcpHost
import Std.SpikeServer

func pull(q: in SpikeListener): Unit {
  var i = 0
  while i < 3 {
    val ctx = spikeNext(q)
    spikeRespond(ctx, "hello:" + spikePath(ctx))
    i = i + 1
  }
}

func request(conn: in Conn, path: in String): String {
  match hostWrite(conn, encodeUtf8("GET " + path + " HTTP/1.1\r\nHost: x\r\n\r\n")) {
    case Err(e) -> panic("write: " + TcpError.message(e))
    case Ok(_) -> ()
  }
  val want = "hello:" + path
  var got = ""
  while indexOfRaw(got, "\r\n\r\n") < 0 or got.length < indexOfRaw(got, "\r\n\r\n") + 4 + want.length {
    match hostRead(conn, 4096) {
      case Err(e) -> panic("read: " + TcpError.message(e))
      case Ok(chunk) -> {
        if chunk.length == 0 {
          panic("eof")
        }
        match tryDecodeUtf8(chunk) {
          case Some(t) -> {
            got = got + t
          }
          case None -> panic("utf8")
        }
      }
    }
  }
  substring(got, indexOfRaw(got, "\r\n\r\n") + 4)
}

func main(): Int {
  val q = spikeStart()
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, { -> pull(q) })
  val conn = match hostConnect("127.0.0.1", spikePort(q), 5000) {
    case Ok(c) -> c
    case Err(e) -> panic("connect: " + TcpError.message(e))
  }
  val paths = ["/a", "/b", "/c"]
  var i = 0
  while i < paths.length {
    val body = request(conn, paths[i])
    if body != "hello:" + paths[i] {
      panic("wrong body for " + paths[i] + ": " + body)
    }
    i = i + 1
  }
  hostClose(conn)
  val _ = await Task.awaitAll(sc)
  spikeStop(q)
  println("SPIKE-OK")
  0
}
