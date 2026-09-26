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
//!
//! Sessions outlive their connection (D138, Q-UI-007).  Each session gets an
//! unguessable id, sent to the browser when it starts; a browser that
//! reconnects quotes it in `hello` and resumes the same session within
//! `reconnectGraceMs`.  A disconnected session keeps only its model (the
//! tree is rebuilt on resume).  At most `maxSessions` sessions are live:
//! when a new session would exceed that, expired and then the longest
//! disconnected sessions are evicted, and if every session is connected the
//! new browser gets a "server busy" page instead.  Expired sessions are
//! removed whenever a session is created or resumed.
@runtime_checked
package Ui.Host.Web

import Std.Core
import Std.Collections
import Std.Console
import Std.String
import Std.Encoding as Enc
import Std.SecureRandom as SecureRandom
import Std.Time as Time
import Web
import Web.{Request, Response, Handler}
import Ws
import Ws.{WsHandler, WsContext, WsMessage, WsError, WsCloseCode, NativeRegistry}
import Ui.Protocol.{ClientMessage, Hello, EventMsg, Sync, decodeClient, encodeSession, protocolVersion}
import Ui.Host.{Instance, Outbox, SessionRegistry, ResumedSession, Unknown, staticPage}
import Ui.Host.Assets

/// Where and how to serve.  `wsPath` is the WebSocket path on `wsPort`.
/// `publicWsUrl`, when not empty, is the socket URL browsers are told to
/// open, for a deployment whose proxy routes the socket elsewhere; when
/// empty it is derived from the request (see `sessionSocketUrl`).
/// `reconnectGraceMs` is how long a disconnected session can be resumed;
/// `maxSessions` bounds the sessions held in memory.
pub record HostConfig {
  title: String
  host: String
  port: Int
  wsPort: Int
  wsPath: String
  publicWsUrl: String
  reconnectGraceMs: Long
  maxSessions: Int
}

/// Serve on all interfaces, HTTP on 8080 and WebSocket on 8081; resume a
/// disconnected session for two minutes; hold at most 10000 sessions.
pub func defaultConfig(title: in String): HostConfig {
  return HostConfig(
    title = title,
    host = "0.0.0.0",
    port = 8080,
    wsPort = 8081,
    wsPath = "/_ui",
    publicWsUrl = "",
    reconnectGraceMs = 120_000,
    maxSessions = 10_000
  )
}

/// Starts the WebSocket listener, then serves HTTP until the process ends.
/// `route` maps the page URL (path and query) a browser opened to the
/// screen instance for it, or `None` for "not found".
pub func serve(cfg: in HostConfig, route: in (String) -> Option[Instance]): Result[Unit, String]
  requires: cfg.reconnectGraceMs >= 0 and cfg.maxSessions > 0
{
  val regs = RegistryCell()
  val socket = UiSocket(
    route = route,
    sessions = SessionRegistry(),
    registry = regs,
    graceMs = cfg.reconnectGraceMs,
    maxSessions = cfg.maxSessions
  )
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
  val shell = Shell(title = cfg.title, wsPort = cfg.wsPort, wsPath = cfg.wsPath, publicWsUrl = cfg.publicWsUrl)
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
  publicWsUrl: String
}

impl Handler for Shell {
  func handle(req: in Request): Response {
    val hostHeader = match Web.header(req, "host") { case Some(h) -> h; case None -> "localhost" }
    val wsUrl = sessionSocketUrl(
      self.publicWsUrl,
      Web.header(req, "x-forwarded-proto"),
      hostHeader,
      self.wsPort,
      self.wsPath
    )
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

/// The session socket URL for a page requested with `hostHeader`:
/// `publicWsUrl` when set, otherwise `wsPort`/`wsPath` on the page's host.
/// The scheme is `wss` when the page was served over HTTPS by a
/// TLS-terminating proxy (`X-Forwarded-Proto: https`, first value when the
/// header lists several proxies), because a browser refuses a plain `ws`
/// socket from an HTTPS page; `ws` otherwise.
pub func sessionSocketUrl(
  publicWsUrl: in String,
  forwardedProto: in Option[String],
  hostHeader: in String,
  wsPort: in Int,
  wsPath: in String,
): String {
  if publicWsUrl.length > 0 {
    return publicWsUrl
  }
  val secure = match forwardedProto {
    case Some(p) -> {
      val first = match indexOf(p, ",") { case Some(comma) -> substring(p, 0, comma); case None -> p }
      toLower(trim(first)) == "https"
    }
    case None -> false
  }
  val scheme = if secure { "wss" } else { "ws" }
  return scheme + "://" + hostnameOf(hostHeader) + ":" + wsPort.toString() + wsPath
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
protected type RegistryCell {
  var handle: Int = -1
  entry set(h: in Int): Unit {
    handle = h
  }
  entry get(): Int {
    return handle
  }
}

func sendTo(registry: in RegistryCell, connectionId: in String, text: in String): Unit {
  val h = registry.get()
  if h >= 0 {
    match Ws.sendText(NativeRegistry(registryHandle = h), connectionId, text) {
      case Ok(_) -> ()
      // The browser went away mid-step; the close callback detaches the
      // session, so there is nothing further to do here.
      case Err(_) -> ()
    }
  }
}

/// Sends to whichever connection a session is attached to when the message
/// is sent, so the output of a step that was running when the browser
/// reconnected reaches the new connection.
record SessionOutbox {
  registry: RegistryCell
  sessions: SessionRegistry
  sessionId: String
}

impl Outbox for SessionOutbox {
  func send(text: in String): Unit {
    match self.sessions.connectionOf(self.sessionId) {
      case Some(c) -> sendTo(self.registry, c, text)
      case None -> ()
    }
  }
}

/// Sends to one connection (pages that hold no session).
record ConnectionOutbox {
  registry: RegistryCell
  connectionId: String
}

impl Outbox for ConnectionOutbox {
  func send(text: in String): Unit {
    sendTo(self.registry, self.connectionId, text)
  }
}

record UiSocket {
  route: (String) -> Option[Instance]
  sessions: SessionRegistry
  registry: RegistryCell
  graceMs: Long
  maxSessions: Int
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
    release(self.sessions, ctx.connectionId)
  }

  func onError(ctx: in WsContext, error: in WsError): Unit {
    Console.error("lyric-ui: connection " + ctx.connectionId + ": " + error.message)
  }
}

func receiveText(s: in UiSocket, connectionId: in String, text: in String): Unit {
  match decodeClient(text) {
    case Err(e) -> Console.error("lyric-ui: dropped message from " + connectionId + ": " + e)
    case Ok(Hello(pv, url, sid)) -> hello(s, connectionId, pv, url, sid)
    case Ok(m) -> match s.sessions.sessionOf(connectionId) {
      case Some(id) -> match s.sessions.instanceOf(id) {
        case Some(inst) -> inst.receive(
          m,
          SessionOutbox(
            registry = s.registry,
            sessions = s.sessions,
            sessionId = id
          )
        )
        case None -> Console.error(
          "lyric-ui: message for an evicted session from " + connectionId
        )
      }
      case None -> Console.error("lyric-ui: message before hello from " + connectionId)
    }
  }
}

func hello(s: in UiSocket, connectionId: in String, pv: in Int, url: in String, sid: in String): Unit {
  // A second hello on one connection starts over: whatever session it
  // carried is detached like on a close.
  release(s.sessions, connectionId)
  val direct = ConnectionOutbox(registry = s.registry, connectionId = connectionId)
  if pv != protocolVersion {
    staticPage("Please reload", "This page was loaded from an older version of the application.").start(direct)
    return
  }
  val now = Time.nowEpochMillis()
  if sid.length > 0 {
    match s.sessions.attach(sid, connectionId, now, s.graceMs) {
      case ResumedSession(inst) -> {
        inst.resume(SessionOutbox(registry = s.registry, sessions = s.sessions, sessionId = sid))
        return
      }
      case Unknown -> ()
    }
  }
  val inst = match s.route(url) {
    case Some(i) -> i
    case None -> staticPage("Not found", "There is no page at " + url + ".")
  }
  val id = newSessionId()
  if not s.sessions.admit(id, inst, connectionId, now, s.graceMs, s.maxSessions) {
    staticPage("Server busy", "The server is at capacity. Please try again in a few minutes.").start(direct)
    return
  }
  direct.send(encodeSession(id))
  inst.start(SessionOutbox(registry = s.registry, sessions = s.sessions, sessionId = id))
}

// Detaches the session `connectionId` carries.  The instance drops its tree
// only if the session is still disconnected once it holds the instance lock:
// a reconnect may have resumed it in between.
func release(sessions: in SessionRegistry, connectionId: in String): Unit {
  match sessions.release(connectionId, Time.nowEpochMillis()) {
    case Some(d) -> {
      val id = d.sessionId
      d.instance.detach({ -> sessions.isDetached(id) })
    }
    case None -> ()
  }
}

/// 128 random bits from the operating system's secure generator, as hex.
/// The id is the only credential for resuming a session, so it must not be
/// guessable.
func newSessionId(): String {
  return Enc.encodeHex(SecureRandom.secureGetBytes(16))
}
