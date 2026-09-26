//! tests/ws_jvm_origin_smoke.l — a real Undertow WebSocket server on
//! `--target jvm` for `scripts/ci/lyric-ws-undertow-jvm-smoke.sh`, which
//! drives its handshake with `curl` (#7243).  `Std.TcpHost` has no JVM
//! kernel, so the dotnet loopback tests cannot run here.
//!
//! The server listens on 127.0.0.1:8111 at `/ws` with the default
//! `WsServerOptions` (same-origin handshakes only) and on :8112 with
//! `allowedOrigins = ["https://app.example.com"]`.  Each `onOpen` prints
//! `OPEN user-agent=<value>`, so the script can check that handshake headers
//! reach the handler, and each text message is echoed back as `echo:<text>`.
//! It runs until killed.
package Ws.JvmOriginSmoke

import Std.Core
import Std.Collections
import Ws

record RegistryHolder {
  var registry: Option[NativeRegistry] = None
}

record PrintingHandler {
  holder: RegistryHolder
}

impl WsHandler for PrintingHandler {
  func onOpen(ctx: in WsContext): Result[Unit, WsError] {
    val ua = match mapGet(ctx.headers, "user-agent") { case Some(v) -> v; case None -> "<none>" }
    println("OPEN user-agent=" + ua)
    Ok(())
  }

  func onMessage(ctx: in WsContext, msg: in WsMessage): Result[Unit, WsError] {
    match self.holder.registry {
      case None -> Ok(())
      case Some(r) -> {
        val registry: NativeRegistry = r
        match msg {
          case WsMessage.Text(text) -> Ws.sendText(registry, ctx.connectionId, "echo:" + text)
          case _ -> Ok(())
        }
      }
    }
  }

  func onClose(ctx: in WsContext, code: in WsCloseCode): Unit {
  }

  func onError(ctx: in WsContext, error: in WsError): Unit {
  }
}

extern type JThread = "java.lang.Thread"

func main(): Int {
  val holder = RegistryHolder()
  match Ws.startServer("127.0.0.1", 8111, "/ws", PrintingHandler(holder = holder)) {
    case Err(e) -> {
      println("START-FAILED " + e.message)
      return 1
    }
    case Ok(r) -> {
      holder.registry = Some(value = r)
    }
  }
  val options = WsServerOptions(allowedOrigins = ["https://app.example.com"])
  match Ws.startServerWithOptions("127.0.0.1", 8112, "/ws", options, PrintingHandler(holder = RegistryHolder())) {
    case Err(e) -> {
      println("START-FAILED " + e.message)
      return 1
    }
    case Ok(_) -> ()
  }
  println("READY")
  while true {
    JThread.sleep(1000i64)
  }
  0
}
