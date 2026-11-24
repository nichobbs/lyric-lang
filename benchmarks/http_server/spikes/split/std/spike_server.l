//! SPIKE (docs/73 S0 spike a), not shipped: the reduced driver of the shared `Std.HttpServer` plan.
//!
//! An accept loop, a mutex-guarded FIFO of ready contexts with a counting semaphore, a per-request
//! one-shot semaphore, and one HTTP/1.1 keep-alive connection loop, all in shared Lyric over the
//! `Std.SpikeServerHost` seam (startTask, counting semaphore). It uses what the real driver needs and the
//! plan assumed but had not compiled on every target: `ref record`s with `var` fields, closures
//! handed to the seam's `startTask`, no `try`/`catch`, no `inout`, no `String[i]`.
package Std.SpikeServer

import Std.Core
import Std.Collections
import Std.Encoding
import Std.String
import Std.TcpHost
import Std.SpikeServerHost as Host

pub ref record SpikeContext {
  path: String
  done: Host.Sem
  var body: String
}

pub ref record SpikeListener {
  listener: Listener
  lock: Host.Sem
  available: Host.Sem
  items: List[SpikeContext]
  var stopping: Bool
}

func enqueue(q: in SpikeListener, ctx: in SpikeContext): Unit {
  Host.semWait(q.lock)
  q.items.add(ctx)
  Host.semPost(q.available)
  Host.semPost(q.lock)
}

// Reads one request head; returns the request path, or "" at headEnd of stream or on error.
func readRequestPath(conn: in Conn): String {
  var head = ""
  var path = ""
  var done = false
  while not done {
    match hostRead(conn, 16384) {
      case Err(_) -> {
        done = true
      }
      case Ok(chunk) -> {
        if chunk.length == 0 {
          done = true
        } else {
          match tryDecodeUtf8(chunk) {
            case None -> {
              done = true
            }
            case Some(text) -> {
              head = head + text
              val headEnd = indexOfRaw(head, "\r\n\r\n")
              if headEnd >= 0 {
                val firstSpace = indexOfRaw(head, " ")
                val rest = substring(head, firstSpace + 1)
                val secondSpace = indexOfRaw(rest, " ")
                path = substring(rest, 0, secondSpace)
                done = true
              }
            }
          }
        }
      }
    }
  }
  path
}

func connectionLoop(q: in SpikeListener, conn: in Conn): Unit {
  var open = true
  while open {
    val path = readRequestPath(conn)
    if path.length == 0 {
      open = false
    } else {
      val ctx = SpikeContext(path = path, done = Host.newSem(0), body = "")
      enqueue(q, ctx)
      Host.semWait(ctx.done)
      val wire = "HTTP/1.1 200 OK\r\nContent-Length: " + ctx.body.length.toString() + "\r\n\r\n" + ctx.body
      match hostWrite(conn, encodeUtf8(wire)) {
        case Ok(_) -> ()
        case Err(_) -> {
          open = false
        }
      }
    }
  }
  hostClose(conn)
}

func acceptLoop(q: in SpikeListener): Unit {
  var running = true
  while running {
    match hostAccept(q.listener) {
      case Err(_) -> {
        running = false
      }
      case Ok(conn) -> {
        Host.startTask({ -> connectionLoop(q, conn) })
      }
    }
  }
}

pub func spikeStart(): SpikeListener {
  val l = match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val items: List[SpikeContext] = newList()
  val q = SpikeListener(
    listener = l,
    lock = Host.newSem(1),
    available = Host.newSem(0),
    items = items,
    stopping = false
  )
  Host.startTask({ -> acceptLoop(q) })
  q
}

pub func spikePort(q: in SpikeListener): Int {
  hostLocalPort(q.listener)
}

pub func spikeNext(q: in SpikeListener): SpikeContext {
  Host.semWait(q.available)
  Host.semWait(q.lock)
  val ctx = q.items[0]
  q.items.removeAt(0)
  Host.semPost(q.lock)
  ctx
}

pub func spikePath(c: in SpikeContext): String {
  c.path
}

pub func spikeRespond(c: in SpikeContext, body: in String): Unit {
  c.body = body
  Host.semPost(c.done)
}

pub func spikeStop(q: in SpikeListener): Unit {
  q.stopping = true
  hostStopListener(q.listener)
}
