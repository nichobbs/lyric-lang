//! examples/native-web/src/main.l — an HTTP and WebSocket service on the native
//! backend: routes with path parameters and a request body, and a WebSocket
//! endpoint on the same port that echoes text frames.
//!
//!   GET  /              -> "hello native"
//!   GET  /echo/{name}   -> "echo:<name>"
//!   POST /post          -> "post:<request body>"
//!   WS   /live          -> each text message is answered "echo:<text>"
package NativeWeb

import Std.Core
import Std.Collections
import Std.Console as Console
import Web
import Ws

record HelloHandler {
}

impl Web.Handler for HelloHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, "hello native")
  }
}

record EchoPathHandler {
}

impl Web.Handler for EchoPathHandler {
  func handle(req: in Web.Request): Web.Response {
    val name = match Web.pathParam(req, "name") { case Some(n) -> n; case None -> "" }
    Web.text(200, "echo:" + name)
  }
}

record PostHandler {
}

impl Web.Handler for PostHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, "post:" + req.body)
  }
}

record RegistryHolder {
  var registry: Option[NativeRegistry] = None
}

record EchoSocket {
  holder: RegistryHolder
}

impl WsHandler for EchoSocket {
  func onOpen(ctx: in WsContext): Result[Unit, WsError] {
    Ok(())
  }

  func onMessage(ctx: in WsContext, msg: in WsMessage): Result[Unit, WsError] {
    match self.holder.registry {
      case Some(registry) -> match msg {
        case Text(text) -> {
          val _ = registry.send(ctx.connectionId, Text(text = "echo:" + text))
          Ok(())
        }
        case _ -> Ok(())
      }
      case None -> Ok(())
    }
  }

  func onClose(ctx: in WsContext, code: in WsCloseCode): Unit {
    ()
  }

  func onError(ctx: in WsContext, error: in WsError): Unit {
    ()
  }
}

func main(): Int {
  val holder = RegistryHolder()
  val endpoint = match Ws.createEndpoint("/live", Ws.WsServerOptions(), EchoSocket(holder = holder)) {
    case Ok(ep) -> ep
    case Err(e) -> {
      Console.println("createEndpoint failed: " + e.message)
      return 1
    }
  }
  holder.registry = Some(value = endpoint.registry)
  var router = Web.addWebSocket(Web.create(), endpoint)
  router = Web.addGet(router, "/", HelloHandler())
  router = Web.addGet(router, "/echo/{name}", EchoPathHandler())
  router = Web.addPost(router, "/post", PostHandler())
  Web.serve(router, "127.0.0.1", 18480)
  0
}
