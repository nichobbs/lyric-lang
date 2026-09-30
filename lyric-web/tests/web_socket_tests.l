//! tests/web_socket_tests.l — a `lyric-ws` endpoint served on a `Web.serve`
//! router's own port (`Web.addWebSocket`, #7831).
//!
//! Drives a real `Web.serve` listener in-process (the background-`Task.Run`
//! pattern of `serve_crash_isolation_tests.l`) with a hand-rolled RFC 6455
//! client over `Std.TcpHost`, so the assertions cover the whole handover:
//! the HTTP server parses the upgrade request, `Std.HttpServer.
//! takeConnection` detaches the connection, and `Ws.Kernel.Net` answers
//! `101` and serves frames on it.  Ordinary routes keep working on the same
//! port, including on a keep-alive connection that later upgrades.
//!
//! dotnet-only (the client dials `Std.TcpHost`, which has no JVM kernel), so
//! the module is gated on the `dotnet` feature and a `--target jvm` run of
//! this manifest skips it.  The JVM mount is covered by the browser
//! end-to-end test of `examples/ui-customers` (`scripts/ci/ui-browser-e2e.sh`),
//! whose page and socket share one port.
@cfg(feature = "dotnet")
@test_module
package Web.WebSocketTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.String
import Std.Parse
import Std.TcpHost
import Std.Testing
import Web
import Ws
import Ws.Handshake

extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externStatic
@externTarget("System.Threading.Thread.Sleep")
func threadSleep(ms: in Int): Unit = ()

// ─── Server side ────────────────────────────────────────────────────────────
record RegistryHolder {
  var registry: Option[NativeRegistry] = None
  var lastPath: String = ""
}

record EchoHandler {
  holder: RegistryHolder
}

impl WsHandler for EchoHandler {
  func onOpen(ctx: in WsContext): Result[Unit, WsError] {
    self.holder.lastPath = ctx.path
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

record PageHandler {
}

impl Web.Handler for PageHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, "page:" + req.path)
  }
}

record Started {
  holder: RegistryHolder
}

func startServer(port: in Int): Started {
  val holder = RegistryHolder()
  val endpoint = match Ws.createEndpoint("/live", Ws.WsServerOptions(), EchoHandler(holder = holder)) {
    case Ok(ep) -> ep
    case Err(e) -> panic("createEndpoint failed: " + e.message)
  }
  holder.registry = Some(value = endpoint.registry)
  var r = Web.addWebSocket(Web.create(), endpoint)
  r = Web.addGet(r, "/", PageHandler())
  r = Web.addGet(r, "/{*path}", PageHandler())
  val _ = taskRun({ -> Web.serve(r, "127.0.0.1", port) })
  threadSleep(300)
  Started(holder = holder)
}

// ─── Client side ────────────────────────────────────────────────────────────
val clientKey: String = "dGhlIHNhbXBsZSBub25jZQ=="

func dial(port: in Int): Conn {
  var attempt = 0
  while attempt < 40 {
    match hostConnect("127.0.0.1", port) {
      case Ok(c) -> return c
      case Err(_) -> {
        threadSleep(50)
        attempt = attempt + 1
      }
    }
  }
  panic("could not connect to 127.0.0.1:" + port.toString())
}

func upgradeRequest(path: in String, host: in String, origin: in String): String {
  val originLine = if origin.length > 0 { "Origin: " + origin + "\r\n" } else { "" }
  "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\n" + originLine + "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\nSec-WebSocket-Key: " +
    clientKey +
    "\r\nSec-WebSocket-Version: 13\r\n\r\n"
}

// Read until the header terminator, returning the header block as text.
func readHead(conn: in Conn): String {
  val acc: List[Byte] = newList()
  var tries = 0
  while tries < 200 {
    match findHeaderTerminator(acc.toArray()) {
      case Some(_) -> return match tryDecodeUtf8(acc.toArray()) { case Some(t) -> t; case None -> "" }
      case None -> ()
    }
    match hostRead(conn, 4096) {
      case Ok(b) -> {
        if b.length == 0 {
          return match tryDecodeUtf8(acc.toArray()) { case Some(t) -> t; case None -> "" }
        }
        var i = 0
        while i < b.length {
          acc.add(b[i])
          i = i + 1
        }
      }
      case Err(_) -> return match tryDecodeUtf8(acc.toArray()) { case Some(t) -> t; case None -> "" }
    }
    tries = tries + 1
  }
  panic("the server never completed a response head")
}

// Read one HTTP/1.1 response with a Content-Length body (the page routes).
func readResponse(conn: in Conn): String {
  val acc: List[Byte] = newList()
  var tries = 0
  while tries < 200 {
    val text = match tryDecodeUtf8(acc.toArray()) { case Some(t) -> t; case None -> "" }
    if completeBody(text) {
      return text
    }
    match hostRead(conn, 4096) {
      case Ok(b) -> {
        var i = 0
        while i < b.length {
          acc.add(b[i])
          i = i + 1
        }
      }
      case Err(_) -> return text
    }
    tries = tries + 1
  }
  panic("the server never completed a page response")
}

// Whether `text` holds the whole body its Content-Length announces.
func completeBody(text: in String): Bool {
  match indexOf(text, "\r\n\r\n") {
    case None -> false
    case Some(headEnd) -> {
      val head = toLower(substring(text, 0, headEnd))
      match indexOf(head, "content-length:") {
        case None -> false
        case Some(at) -> {
          val rest = substring(head, at + 15)
          val lineEnd = match indexOf(rest, "\r\n") { case Some(e) -> e; case None -> rest.length }
          match parseOptInt(trim(substring(rest, 0, lineEnd))) {
            case Some(n) -> substring(text, headEnd + 4).length >= n
            case None -> false
          }
        }
      }
    }
  }
}

func sendMaskedText(conn: in Conn, text: in String): Unit {
  val payload = encodeUtf8(text)
  val acc: List[Byte] = newList()
  acc.add(129.toByte())
  acc.add((128 + payload.length).toByte())
  val keys = [17, 34, 51, 68]
  for k in keys {
    acc.add(k.toByte())
  }
  var i = 0
  while i < payload.length {
    acc.add(payload[i].toInt().xor(keys[i % 4]).toByte())
    i = i + 1
  }
  val _ = hostWrite(conn, acc.toArray());
  ()
}

// Read one short unmasked text frame (payload <= 125 bytes).
func readTextFrame(conn: in Conn): String {
  val acc: List[Byte] = newList()
  var tries = 0
  while tries < 200 {
    if acc.count >= 2 {
      val len = acc[1].toInt().and(127)
      if acc.count >= 2 + len {
        val bytes = acc.toArray()
        return match tryDecodeUtf8(bytes.slice(2, 2 + len)) { case Some(t) -> t; case None -> "" }
      }
    }
    match hostRead(conn, 4096) {
      case Ok(b) -> {
        var i = 0
        while i < b.length {
          acc.add(b[i])
          i = i + 1
        }
      }
      case Err(_) -> return ""
    }
    tries = tries + 1
  }
  panic("the server never sent a complete frame")
}

// ─── Tests ──────────────────────────────────────────────────────────────────
test "a WebSocket endpoint and ordinary routes share the router's port" {
  val started = startServer(19621)
  val conn = dial(19621)
  val _ = hostWrite(conn, encodeUtf8(upgradeRequest("/live", "127.0.0.1:19621", "http://127.0.0.1:19621")))
  val head = readHead(conn)
  assertTrue(head.startsWith("HTTP/1.1 101"), "upgrade answered 101: " + head)
  assertTrue(
    toLower(head).contains("sec-websocket-accept: " + toLower(computeAcceptKey(clientKey))),
    "accept key: " + head
  )
  sendMaskedText(conn, "hi")
  assertEqual(readTextFrame(conn), "echo:hi", "the endpoint's handler serves the socket")
  assertEqual(started.holder.lastPath, "/live", "handler sees the endpoint path")
  hostClose(conn)

  val page = dial(19621)
  val _ = hostWrite(page, encodeUtf8("GET /customers HTTP/1.1\r\nHost: 127.0.0.1:19621\r\nConnection: close\r\n\r\n"))
  val resp = readResponse(page)
  hostClose(page)
  assertTrue(resp.contains("page:/customers"), "ordinary routes still dispatch: " + resp)
}

test "a keep-alive connection can upgrade after an ordinary request" {
  val _ = startServer(19622)
  val conn = dial(19622)
  val _ = hostWrite(conn, encodeUtf8("GET / HTTP/1.1\r\nHost: 127.0.0.1:19622\r\n\r\n"))
  val first = readResponse(conn)
  assertTrue(first.contains("page:/"), "first request served: " + first)
  val _ = hostWrite(conn, encodeUtf8(upgradeRequest("/live", "127.0.0.1:19622", "")))
  val head = readHead(conn)
  assertTrue(head.startsWith("HTTP/1.1 101"), "second request upgrades: " + head)
  sendMaskedText(conn, "again")
  assertEqual(readTextFrame(conn), "echo:again", "socket served on the reused connection")
  hostClose(conn)
}

test "a cross-site handshake is refused before the upgrade" {
  val _ = startServer(19623)
  val conn = dial(19623)
  val _ = hostWrite(conn, encodeUtf8(upgradeRequest("/live", "127.0.0.1:19623", "https://evil.example")))
  val head = readHead(conn)
  hostClose(conn)
  assertTrue(head.startsWith("HTTP/1.1 403"), "cross-site origin refused: " + head)
}

test "a GET to the endpoint without upgrade headers is answered 400" {
  val _ = startServer(19624)
  val conn = dial(19624)
  val _ = hostWrite(conn, encodeUtf8("GET /live HTTP/1.1\r\nHost: 127.0.0.1:19624\r\n\r\n"))
  val head = readHead(conn)
  hostClose(conn)
  assertTrue(head.startsWith("HTTP/1.1 400"), "plain GET refused: " + head)
}
