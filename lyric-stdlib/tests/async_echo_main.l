//! An `async` TCP echo server for the async I/O reactor (#8494, D405): it
//! accepts `LYRIC_ECHO_CONNECTIONS` connections and serves each from its own
//! spawned task, echoing every read back until the peer closes.  Each idle
//! connection's task is parked on the reactor (the `Std.TcpHost` read twin),
//! not holding a scheduler thread, so a thousand idle connections are served
//! by two threads.  `scripts/ci/async-io-e2e.sh` starts it with
//! `LYRIC_ASYNC_THREADS=2`, reads the port it writes to `LYRIC_ECHO_PORT_FILE`,
//! opens every connection, leaves them idle, then sends on each and checks the
//! echo; the server prints the totals and exits 0 once every peer has closed.
package Std.AsyncIo.EchoMain

import Std.Core
import Std.Console as Console
import Std.Environment as Environment
import Std.File as File
import Std.Parse as Parse
import Std.TcpHost as TcpHost

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

// Echoes until the peer closes; the number of bytes echoed, or -1 on a
// transport error.
async func serve(c: in TcpHost.Conn): Int {
  var total = 0
  while true {
    match TcpHost.hostRead(c, 4096) {
      case Ok(bytes) -> {
        if bytes.length == 0 {
          TcpHost.hostClose(c)
          return total
        }
        match TcpHost.hostWrite(c, bytes) {
          case Ok(_) -> {
            total = total + bytes.length
          }
          case Err(_) -> {
            TcpHost.hostClose(c)
            return 0 - 1
          }
        }
      }
      case Err(_) -> {
        TcpHost.hostClose(c)
        return 0 - 1
      }
    }
  }
  total
}

// Accepts `n` connections, each served by its own task, and returns the bytes
// they echoed in all (-1 if any failed).
async func acceptAll(l: in TcpHost.Listener, n: in Int): Int {
  if n == 0 {
    return 0
  }
  match TcpHost.hostAccept(l) {
    case Ok(c) -> {
      scope {
        val one = spawn serve(c)
        val rest = spawn acceptAll(l, n - 1)
        val a = await one
        val b = await rest
        if a < 0 or b < 0 {
          return 0 - 1
        }
        return a + b
      }
    }
    case Err(e) -> {
      Console.println("accept failed: " + TcpHost.TcpError.message(e))
      return 0 - 1
    }
  }
}

func main(): Int {
  val n = match Parse.tryParseInt(Environment.getVarOrDefault("LYRIC_ECHO_CONNECTIONS", "1000")) {
    case Ok(v) -> v
    case Err(_) -> 1000
  }
  val portFile = Environment.getVarOrDefault("LYRIC_ECHO_PORT_FILE", "")
  match TcpHost.hostListen("127.0.0.1", 0) {
    case Ok(l) -> {
      val port = TcpHost.hostLocalPort(l)
      if portFile.length > 0 {
        match File.writeText(portFile, port.toString()) {
          case Ok(_) -> ()
          case Err(_) -> return fail("cannot write the port file")
        }
      }
      val echoed = await acceptAll(l, n)
      TcpHost.hostCloseListener(l)
      if echoed < 0 {
        return fail("a connection failed")
      }
      Console.println("echo ok: " + n.toString() + " connections, " + echoed.toString() + " bytes")
      0
    }
    case Err(e) -> fail("listen: " + TcpHost.TcpError.message(e))
  }
}
