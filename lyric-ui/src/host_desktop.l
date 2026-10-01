//! Ui.Host.Desktop — the desktop host (docs/65-ui-library-sketch.md §10.2).
//! Stability: @experimental — Phase U5 of docs/65.
//!
//! Runs an application in its own window instead of a browser tab:
//!
//!   func route(url: in String): Option[Instance] { ... }   // app-defined
//!   func main(): Unit {
//!     Desktop.run(Desktop.defaultConfig("Customers"), route)
//!   }
//!
//! The window is a system webview (the C `webview` library: WebKitGTK on
//! Linux, WebKit on macOS, WebView2 on Windows), and the application is
//! served to it exactly as the web host serves a browser (`Ui.Host.Web`):
//! the same shell, runtime and session protocol, so a screen behaves the
//! same in both.  The page server listens on the loopback interface only,
//! on a free port, and admits only the window: the host makes a fresh
//! random access token for each run and hands it to the window alone, so
//! other programs on the machine that find the port get `403`.
//!
//! The window first shows a small local page that waits for the server to
//! answer and then opens the application, so it appears at once.  Closing
//! the window, or calling `close()` from anywhere in the program (a
//! "Quit" command's effect, say), ends the program.
//!
//! Needs the `webview` shared library at run time (`libwebview.so` on
//! Linux; `scripts/ci/install-webview.sh` builds and installs it) and, on
//! the JVM, JDK 22 or later (D158).
@runtime_checked
@io
package Ui.Host.Desktop

import Std.Core
import Std.Console
import Std.Environment as Env
import Std.Random as Random
import Std.SecureRandom as SecureRandom
import Std.Encoding as Enc
import Std.String
import Std.HttpServer as HttpServer
import Std.Task as Task
import Web
import Ui.Host.{Instance}
import Ui.Host.Web as WebHost
import Ui.Kernel.Webview as Webview

/// The window and its page server.  `port` 0 picks a free loopback port.
/// `startPath` is the first page shown (a path and optional query, as a
/// screen's `route` receives it).  `reconnectGraceMs` is how long a
/// session survives its page reloading.  `devTools` enables the webview's
/// developer tools.
pub record DesktopConfig {
  title: String
  width: Int
  height: Int
  port: Int
  startPath: String
  reconnectGraceMs: Long
  devTools: Bool
  invariant: width > 0 and height > 0
  invariant: port >= 0 and port <= 65535
}

/// A 1024 by 768 window titled `title`, opening `/`, on a free port.
pub func defaultConfig(title: in String): DesktopConfig {
  return DesktopConfig(
    title = title,
    width = 1024,
    height = 768,
    port = 0,
    startPath = "/",
    reconnectGraceMs = 120_000,
    devTools = false
  )
}

// The one window a desktop program has.
val window: Webview.CloseSignal = Webview.CloseSignal()

/// Closes the window, which ends the program.  Callable from any thread,
/// before or while the window is open.
pub func close(): Unit {
  window.request()
}

/// Serves the application on the loopback interface and shows it in a
/// window; `route` maps a page URL to its screen as for the web host.
/// When the window closes the program ends with exit status 0.  When the
/// window or its server cannot start, the reason is written to standard
/// error and the program ends with exit status 1.
pub func run(cfg: in DesktopConfig, route: in (String) -> Option[Instance]): Never
  requires: startsWith(cfg.startPath, "/")
{
  match openWindow(cfg, route) {
    case Ok(_) -> Env.exitCode(0)
    case Err(e) -> {
      Console.error("lyric-ui desktop: " + e)
      Env.exitCode(1)
    }
  }
}

func openWindow(cfg: in DesktopConfig, route: in (String) -> Option[Instance]): Result[Unit, String] {
  val port = if cfg.port > 0 { cfg.port } else { freeLoopbackPort()? }
  val token = Enc.encodeHex(SecureRandom.secureGetBytes(32))
  val webCfg = WebHost.HostConfig(
    title = cfg.title,
    host = loopback,
    port = port,
    wsPath = "/_ui",
    publicWsUrl = "",
    reconnectGraceMs = cfg.reconnectGraceMs,
    // One window holds one session; the rest are its reloads.
    maxSessions = 16,
    prerender = true,
    accessToken = token
  )
  val router = WebHost.router(webCfg, route)?
  val server = Task.makeScope()
  Task.scopeSpawn(server, { -> Web.serve(router, loopback, port) })
  val origin = "http://" + loopback + ":" + port.toString()
  val separator = if contains(cfg.startPath, "?") { "&" } else { "?" }
  val appUrl = origin + cfg.startPath + separator + WebHost.accessQueryName + "=" + token
  val spec = Webview.WindowSpec(
    title = cfg.title,
    width = cfg.width,
    height = cfg.height,
    html = loaderHtml(cfg.title, origin + "/_ui/theme.css", appUrl),
    devTools = cfg.devTools
  )
  return Webview.runWindow(spec, window)
}

val loopback: String = "127.0.0.1"

// A port in the dynamic range (RFC 6335) that nothing listens on.  The
// server binds it moments later; another program taking it in between is
// reported by the loader page.
func freeLoopbackPort(): Result[Int, String] {
  val rng = Random.sharedRandom()
  var attempt = 0
  while attempt < 32 {
    val p = Random.nextIntRange(rng, 49152, 65535)
    if canBind(p) {
      return Ok(value = p)
    }
    attempt = attempt + 1
  }
  return Err(error = "found no free loopback port")
}

func canBind(port: in Int): Bool {
  try {
    val l = HttpServer.startListener("http://" + loopback + ":" + port.toString() + "/")
    HttpServer.stopListener(l)
    return true
  } catch Bug as e {
    return false
  }
}

/// The page the window shows first: it polls `probeUrl` until the server
/// answers, then replaces itself with `appUrl`.  After 15 seconds without
/// an answer it says the application could not start.
pub func loaderHtml(title: in String, probeUrl: in String, appUrl: in String): String {
  return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>" + WebHost.escapeHtml(title) +
    "</title>\n</head>\n<body style=\"font-family: system-ui, sans-serif\">\n<script>\n" +
    "const probe = " +
    jsString(probeUrl) +
    ";\nconst app = " +
    jsString(appUrl) +
    ";\nconst deadline = Date.now() + 15000;\n" +
    "function attempt() {\n" +
    "  fetch(probe, { mode: \"no-cors\", cache: \"no-store\" })\n" +
    "    .then(() => location.replace(app))\n" +
    "    .catch(() => {\n" +
    "      if (Date.now() > deadline) {\n" +
    "        document.body.textContent = \"The application could not start its page server.\";\n" +
    "      } else {\n" +
    "        setTimeout(attempt, 50);\n" +
    "      }\n" +
    "    });\n" +
    "}\n" +
    "attempt();\n" +
    "</script>\n</body>\n</html>\n"
}

/// `s` as a double-quoted JavaScript string literal that is also safe
/// inside an HTML `<script>` element.
pub func jsString(s: in String): String {
  var escaped = replace(s, "\\", "\\\\")
  escaped = replace(escaped, "\"", "\\\"")
  escaped = replace(escaped, "<", "\\u003c")
  escaped = replace(escaped, ">", "\\u003e")
  escaped = replace(escaped, "\n", "\\n")
  escaped = replace(escaped, "\r", "\\r")
  escaped = replace(escaped, " ", "\\u2028")
  escaped = replace(escaped, " ", "\\u2029")
  return "\"" + escaped + "\""
}
