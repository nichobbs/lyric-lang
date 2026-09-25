//! Ui.Host.Web — the server-driven web host (docs/65-ui-library-sketch.md §10.1).
//! Stability: @experimental — Phase U2 of docs/65.
//!
//! Serves the HTML shell and the embedded host runtime over `lyric-web`, and
//! runs one session per WebSocket connection over `lyric-ws`:
//!
//!   func route(url: in String): Option[Instance] { ... }   // app-defined
//!   func main(): Unit {
//!     match WebHost.serve(WebHost.defaultConfig("Customers"), route) {
//!       case Ok(_) -> ()
//!       case Err(e) -> println("could not start: " + e)
//!     }
//!   }
//!
//! `lyric-ws` runs its own listener, so the WebSocket endpoint is on
//! `wsPort`, next to the HTTP `port` (docs/65 §15, finding F-11).  The shell
//! page derives the socket URL from the request's `Host` header.
@runtime_checked
package Ui.Host.Web

import Std.Core
import Std.Collections
import Std.Console
import Std.String
import Std.Encoding as Enc
import Web
import Web.{Request, Response, Handler}
import Ws
import Ws.{WsHandler, WsContext, WsMessage, WsError, WsCloseCode, NativeRegistry}
import Ui.Protocol.{ClientMessage, Hello, EventMsg, Sync, decodeClient, protocolVersion}
import Ui.Host.{Instance, Outbox, staticPage}
import Ui.Host.Assets

/// Where and how to serve.  `wsPath` is the WebSocket path on `wsPort`.
pub record HostConfig {
  title: String
  host: String
  port: Int
  wsPort: Int
  wsPath: String
}

/// Serve on all interfaces, HTTP on 8080 and WebSocket on 8081.
pub func defaultConfig(title: in String): HostConfig {
  return HostConfig(title = title, host = "0.0.0.0", port = 8080, wsPort = 8081, wsPath = "/_ui")
}

/// Starts the WebSocket listener, then serves HTTP until the process ends.
/// `route` maps the page URL (path and query) a browser opened to the
/// screen instance for it, or `None` for "not found".
pub func serve(cfg: in HostConfig, route: in (String) -> Option[Instance]): Result[Unit, String] {
  val regs = RegistryCell()
  val socket = UiSocket(route = route, conns = Connections(), registry = regs)
  val registry = match Ws.startServer(cfg.host, cfg.wsPort, cfg.wsPath, socket) {
    case Ok(r) -> r
    case Err(e) -> return Err(error = "WebSocket listener on port " + cfg.wsPort.toString() + ": " + e.message)
  }
  regs.set(registry.registryHandle)
  Web.serve(router(cfg), cfg.host, cfg.port)
  return Ok(value = ())
}

/// The HTTP routes: runtime assets, theme, and the shell for every other
/// path.  Exposed so an application can merge them into its own router.
pub func router(cfg: in HostConfig): Web.Router {
  var r = Web.create()
  r = Web.addGet(
    r,
    "/_ui/runtime/main.js",
    Asset(body = Assets.runtimeMainJs, contentType = "text/javascript; charset=utf-8")
  )
  r = Web.addGet(
    r,
    "/_ui/runtime/tree.js",
    Asset(body = Assets.runtimeTreeJs, contentType = "text/javascript; charset=utf-8")
  )
  r = Web.addGet(
    r,
    "/_ui/runtime/render.js",
    Asset(body = Assets.runtimeRenderJs, contentType = "text/javascript; charset=utf-8")
  )
  r = Web.addGet(r, "/_ui/theme.css", Asset(body = Assets.themeCss, contentType = "text/css; charset=utf-8"))
  val shell = Shell(title = cfg.title, wsPort = cfg.wsPort, wsPath = cfg.wsPath)
  r = Web.addGet(r, "/", shell)
  r = Web.addGet(r, "/{*path}", shell)
  return r
}

// ─── HTTP ─────────────────────────────────────────────────────────────────────
record Asset {
  body: String
  contentType: String
}

impl Handler for Asset {
  func handle(req: in Request): Response {
    val resp = Web.bytesResponse(200, self.contentType, Enc.encodeUtf8(self.body))
    return Web.withResponseHeader(resp, "Cache-Control", "no-cache")
  }
}

record Shell {
  title: String
  wsPort: Int
  wsPath: String
}

impl Handler for Shell {
  func handle(req: in Request): Response {
    val hostHeader = match Web.header(req, "host") { case Some(h) -> h; case None -> "localhost" }
    val wsUrl = "ws://" + hostnameOf(hostHeader) + ":" + self.wsPort.toString() + self.wsPath
    return Web.html(200, shellHtml(self.title, wsUrl))
  }
}

/// The page shell: mount point, theme and runtime module.
pub func shellHtml(title: in String, wsUrl: in String): String {
  return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n" +
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" +
    "<title>" +
    escapeHtml(title) +
    "</title>\n" +
    "<link rel=\"stylesheet\" href=\"/_ui/theme.css?v=" +
    Assets.assetVersion +
    "\">\n" +
    "</head>\n<body>\n" +
    "<div id=\"lyric-ui\" aria-busy=\"true\" data-ws=\"" +
    escapeHtml(wsUrl) +
    "\"></div>\n" +
    "<script type=\"module\" src=\"/_ui/runtime/main.js?v=" +
    Assets.assetVersion +
    "\"></script>\n" +
    "</body>\n</html>\n"
}

/// `host` without its port (`example.com:8080` -> `example.com`), keeping a
/// bracketed IPv6 literal intact.
pub func hostnameOf(host: in String): String {
  if startsWith(host, "[") {
    return match indexOf(host, "]") { case Some(close) -> substring(host, 0, close + 1); case None -> host }
  }
  return match indexOf(host, ":") { case Some(colon) -> substring(host, 0, colon); case None -> host }
}

/// `s` safe for HTML text and double-quoted attribute values.
pub func escapeHtml(s: in String): String {
  var outbox = replace(s, "&", "&amp;")
  outbox = replace(outbox, "<", "&lt;")
  outbox = replace(outbox, ">", "&gt;")
  outbox = replace(outbox, "\"", "&quot;")
  return replace(outbox, "'", "&#39;")
}

// ─── WebSocket ────────────────────────────────────────────────────────────────
protected type Connections {
  var byId: Map[String, Instance] = newMap()
  entry put(id: in String, inst: in Instance): Unit {
    if byId.containsKey(id) {
      byId.remove(id)
    }
    byId.add(id, inst)
  }
  entry drop(id: in String): Unit {
    if byId.containsKey(id) {
      byId.remove(id)
    }
  }
  func find(id: in String): Option[Instance] {
    return mapGet(byId, id)
  }
}

protected type RegistryCell {
  var handle: Int = -1
  entry set(h: in Int): Unit {
    handle = h
  }
  func get(): Int {
    return handle
  }
}

record SocketOutbox {
  registry: RegistryCell
  connectionId: String
}

impl Outbox for SocketOutbox {
  func send(text: in String): Unit {
    val h = self.registry.get()
    if h >= 0 {
      match Ws.sendText(NativeRegistry(registryHandle = h), self.connectionId, text) {
        case Ok(_) -> ()
        // The browser went away mid-step; the close callback drops the
        // session, so there is nothing further to do here.
        case Err(_) -> ()
      }
    }
  }
}

record UiSocket {
  route: (String) -> Option[Instance]
  conns: Connections
  registry: RegistryCell
}

impl WsHandler for UiSocket {
  func onOpen(ctx: in WsContext): Result[Unit, WsError] {
    return Ok(value = ())
  }

  func onMessage(ctx: in WsContext, msg: in WsMessage): Result[Unit, WsError] {
    match msg {
      case Ws.Text(text) -> receiveText(self, ctx.connectionId, text)
      case _ -> ()
    }
    return Ok(value = ())
  }

  func onClose(ctx: in WsContext, code: in WsCloseCode): Unit {
    self.conns.drop(ctx.connectionId)
  }

  func onError(ctx: in WsContext, error: in WsError): Unit {
    Console.error("lyric-ui: connection " + ctx.connectionId + ": " + error.message)
  }
}

func receiveText(s: in UiSocket, connectionId: in String, text: in String): Unit {
  val outbox = SocketOutbox(registry = s.registry, connectionId = connectionId)
  match decodeClient(text) {
    case Err(e) -> Console.error("lyric-ui: dropped message from " + connectionId + ": " + e)
    case Ok(Hello(pv, url)) -> {
      val inst = if pv != protocolVersion then staticPage("Please reload", "This page was loaded from an older version of the application.") else match s.route(url) { case Some(i) -> i; case None -> staticPage("Not found", "There is no page at " + url + ".") }
      s.conns.put(connectionId, inst)
      inst.start(outbox)
    }
    case Ok(m) -> match s.conns.find(connectionId) {
      case Some(inst) -> inst.receive(m, outbox)
      case None -> Console.error("lyric-ui: message before hello from " + connectionId)
    }
  }
}
