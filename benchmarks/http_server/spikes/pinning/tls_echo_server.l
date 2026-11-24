//! SPIKE (docs/73 S0 spike b), not shipped: a TLS echo server over `Std.TcpHost`, one task per connection.
//!
//! Used by `pinning.sh` to check that a JDK 21 virtual thread blocked in an `SSLSocket` read does not
//! pin its carrier. Environment: `SPIKE_PORT`, `SPIKE_CERT`, `SPIKE_KEY` (PEM files).
package Spike.TlsEcho

import Std.Core
import Std.Collections
import Std.Console
import Std.Environment
import Std.Parse
import Std.Task as Task
import Std.TcpHost
import Std.Tls

func echo(conn: in Conn): Unit {
  var open = true
  while open {
    match hostRead(conn, 4096) {
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

func handle(plain: in Conn, cfg: in TlsServerConfig): Unit {
  match hostUpgradeServerTls(plain, cfg) {
    case Err(_) -> hostClose(plain)
    case Ok(tls) -> echo(tls)
  }
}

func main(): Int {
  val port = match parseOptInt(getVarOrDefault("SPIKE_PORT", "9443")) { case Some(n) -> n; case None -> 9443 }
  val identity = match Identity.fromPemFiles(getVarOrDefault("SPIKE_CERT", ""), getVarOrDefault("SPIKE_KEY", "")) {
    case Ok(id) -> id
    case Err(e) -> panic("identity: " + TlsError.message(e))
  }
  val cfg = TlsServerConfig(identity = identity)
  val l = match hostListen("127.0.0.1", port) {
    case Ok(l) -> l
    case Err(e) -> panic("listen: " + TcpError.message(e))
  }
  println("listening " + port.toString())
  val sc = Task.makeScope()
  var running = true
  while running {
    match hostAccept(l) {
      case Err(_) -> {
        running = false
      }
      case Ok(conn) -> {
        Task.scopeSpawn(sc, { -> handle(conn, cfg) })
      }
    }
  }
  0
}
