//! tests/ws_dotnet_e2e_tests.l — loopback integration tests for the real
//! dotnet WebSocket server (`Ws.Kernel.Net`, docs/62-jsonrpc-mcp.md §6,
//! #778): `Ws.startServer` bound to `127.0.0.1` on an ephemeral port, and a
//! minimal hand-rolled RFC 6455 client built directly on `Std.TcpHost` (the
//! same raw-socket approach `lyric-stdlib/tests/http_server_dotnet_tests.l`
//! uses for its own protocol-level assertions) — deliberately NOT reusing
//! `Ws.Frame`'s codec, so these tests exercise the server's real byte-level
//! wire output independently of the module that produces it.
//!
//! Covers: connect + handshake (status line and `Sec-WebSocket-Accept`
//! verified against `Ws.Handshake.computeAcceptKey`), text echo, binary
//! echo, a fragmented text message reassembled server-side, ping answered
//! with pong by the application handler (the kernel itself does not
//! auto-pong — see `Ws.Kernel.Net`'s module header), a clean close with an
//! explicit code, `connectionCount`/`isConnected` registry-state assertions,
//! and `send`/`broadcast` pushed from outside any handler callback.
//!
//! dotnet-only (`Ws.Kernel.Net` is `@cfg(feature = "dotnet")`); the JVM
//! Undertow path has its own established test coverage
//! (`tests/ws_tests.l`/`ws_security_aspect_weaving_tests.l` run on both
//! targets today) which this file does not touch or regress.
@test_module
package Ws.WsDotnetE2eTests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.String
import Std.TcpHost
import Std.Testing
import Ws
import Ws.Frame
import Ws.Handshake

// ─── Concurrency externs (mirrors lyric-stdlib/tests/http_server_dotnet_tests.l) ──
// `spawn` is degenerate-synchronous on `--target dotnet` (D119/D120); a real
// background thread for the client side of this loopback isn't actually
// needed here (the server itself is the one running in the background, via
// `Ws.Kernel.Net`'s own `Task.Run` accept/read loops) — this test's client
// calls are all synchronous, blocking `Std.TcpHost` reads/writes on the
// caller's own thread.
extern type Thread = "System.Threading.Thread"

@externStatic
@externTarget("System.Threading.Thread.Sleep")
func threadSleep(ms: in Int): Unit = ()

// ─── Test handler ───────────────────────────────────────────────────────────────
// The handler needs the registry (to reply from inside onMessage) but the
// registry is only returned by `startServer` *after* the handler is
// constructed — the same chicken-and-egg `Ws.startServer` always has. A
// mutable holder record, set immediately after `startServer` returns and
// read-back inside `onMessage`, breaks the cycle (both are the same shared
// reference; by the time any client message can possibly arrive, the test
// has already populated the holder).
record RegistryHolder {
  var registry: Option[NativeRegistry] = None
  var lastConnId: Option[String] = None
}

record EchoHandler {
  holder: RegistryHolder
}

impl WsHandler for EchoHandler {
  func onOpen(ctx: in WsContext): Result[Unit, WsError] {
    self.holder.lastConnId = Some(value = ctx.connectionId)
    Ok(())
  }

  func onMessage(ctx: in WsContext, msg: in WsMessage): Result[Unit, WsError] {
    match self.holder.registry {
      case None -> Ok(())
      case Some(registry) -> {
        match msg {
          case Text(text) -> {
            val _ = registry.send(ctx.connectionId, Text(text = "echo:" + text))
            Ok(())
          }
          case Binary(dataBase64) -> {
            val _ = registry.send(ctx.connectionId, Binary(dataBase64 = dataBase64))
            Ok(())
          }
          // The kernel delivers Ping to onMessage but does not auto-reply
          // (Ws.Kernel.Net's module header) — replying is this handler's
          // job, exercising the same app-level contract the JVM/Undertow
          // kernel establishes.
          case Ping -> {
            val _ = registry.send(ctx.connectionId, Pong)
            Ok(())
          }
          case Pong -> Ok(())
          case Close(code, reason) -> Ok(())
        }
      }
    }
  }

  func onClose(ctx: in WsContext, code: in WsCloseCode): Unit {
    ()
  }

  func onError(ctx: in WsContext, error: in WsError): Unit {
    ()
  }
}

record StartedServer {
  registry: NativeRegistry
  holder: RegistryHolder
}

func startEchoServer(port: in Int): StartedServer {
  val holder = RegistryHolder()
  val handler = EchoHandler(holder = holder)
  val registry = match startServer("127.0.0.1", port, "/ws", handler) {
    case Ok(r) -> r
    case Err(e) -> panic("startServer failed: " + e.message)
  }
  holder.registry = Some(registry)
  threadSleep(100)
  StartedServer(registry = registry, holder = holder)
}

// ─── Minimal RFC 6455 client (independent of Ws.Frame) ─────────────────────────
val clientKey: String = "dGhlIHNhbXBsZSBub25jZQ=="

func dial(host: in String, port: in Int): Conn {
  match hostConnect(host, port) {
    case Ok(c) -> c
    case Err(e) -> panic("client connect failed: " + TcpError.message(e))
  }
}

record HandshakeOutcome {
  statusLine: String
  acceptHeader: String
}

// Reads bytes until the response header terminator, returning the status
// line and the (lower-cased-name-matched) Sec-WebSocket-Accept header value.
func clientHandshake(conn: in Conn, path: in String): HandshakeOutcome {
  val req = "GET " + path + " HTTP/1.1\r\n" + "Host: 127.0.0.1\r\n" + "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\n" +
    "Sec-WebSocket-Key: " +
    clientKey +
    "\r\n" +
    "Sec-WebSocket-Version: 13\r\n\r\n"
  val _ = hostWrite(conn, encodeUtf8(req))
  val acc: List[Byte] = newList()
  var found = false
  var tries = 0
  while not found and tries < 200 {
    match hostRead(conn, 4096) {
      case Ok(b) -> {
        var i = 0
        while i < b.length {
          acc.add(b[i])
          i = i + 1
        }
      }
      case Err(_) -> ()
    }
    match findHeaderTerminator(acc.toArray()) {
      case Some(_) -> {
        found = true
      }
      case None -> ()
    }
    tries = tries + 1
  }
  if not found {
    panic("client handshake: server never completed the response header block")
  }
  val text = match tryDecodeUtf8(acc.toArray()) {
    case Some(t) -> t
    case None -> panic("client handshake: response headers are not valid UTF-8")
  }
  val lines = splitCrlf(text)
  val statusLine = lines[0]
  var accept = ""
  var i = 1
  while i < lines.length {
    val line = lines[i]
    if startsWithCi(line, "sec-websocket-accept:") {
      accept = trimLeadingSpace(substringAfterColon(line))
    }
    i = i + 1
  }
  HandshakeOutcome(statusLine = statusLine, acceptHeader = accept)
}

func splitCrlf(text: in String): slice[String] {
  split(text, "\r\n")
}

func toLowerAscii(s: in String): String {
  toLower(s)
}

func startsWithCi(s: in String, prefix: in String): Bool {
  startsWith(toLowerAscii(s), toLowerAscii(prefix))
}

func substringAfterColon(line: in String): String {
  match indexOf(line, ":") {
    case Some(idx) -> substring(line, idx + 1)
    case None -> ""
  }
}

func trimLeadingSpace(s: in String): String {
  trim(s)
}

// Mask `payload` with a fixed 4-byte client key and write one complete
// frame. `opcode`/`fin` select the wire shape; used for both data and
// control frames since every frame this test client sends is short
// (<=125-byte payload, so only the 7-bit inline length form is needed).
func clientSendMasked(conn: in Conn, opcode: in Int, fin: in Bool, payload: in slice[Byte]): Unit {
  val acc: List[Byte] = newList()
  val b0 = (if fin { 128 } else { 0 }) + opcode
  acc.add(b0.toByte())
  acc.add((128 + payload.length).toByte())
  val k0 = 17
  val k1 = 34
  val k2 = 51
  val k3 = 68
  acc.add(k0.toByte())
  acc.add(k1.toByte())
  acc.add(k2.toByte())
  acc.add(k3.toByte())
  val keys = maskKeyBytes(k0, k1, k2, k3)
  var i = 0
  while i < payload.length {
    acc.add(payload[i].toInt().xor(keys[i % 4].toInt()).toByte())
    i = i + 1
  }
  val _ = hostWrite(conn, acc.toArray());
  ()
}

func maskKeyBytes(k0: in Int, k1: in Int, k2: in Int, k3: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  acc.add(k0.toByte())
  acc.add(k1.toByte())
  acc.add(k2.toByte())
  acc.add(k3.toByte())
  acc.toArray()
}

// Mutable per-connection read buffer shared across `clientReadFrame` calls
// (a real client's TCP stream doesn't align frame boundaries with `Read`
// calls, so leftover bytes from one read must carry over to the next).
record ClientReader {
  var buf: List[Byte] = newList()
}

record ClientFrame {
  fin: Bool
  opcode: Int
  payload: slice[Byte]
}

// Blocking read of exactly one complete (unmasked — the server never masks,
// RFC 6455 5.1) frame, buffering across `hostRead` calls as needed.
func clientReadFrame(conn: in Conn, reader: in ClientReader): ClientFrame {
  var tries = 0
  while tries < 200 {
    match tryParseUnmaskedFrame(reader.buf.toArray()) {
      case Some(parsed) -> {
        reader.buf = bytesToList(parsed.rest)
        return ClientFrame(fin = parsed.fin, opcode = parsed.opcode, payload = parsed.payload)
      }
      case None -> {
        match hostRead(conn, 65536) {
          case Ok(b) -> {
            var i = 0
            while i < b.length {
              reader.buf.add(b[i])
              i = i + 1
            }
          }
          case Err(_) -> ()
        }
      }
    }
    tries = tries + 1
  }
  panic("client read: server never sent a complete frame within the read budget")
}

func bytesToList(bytes: in slice[Byte]): List[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < bytes.length {
    acc.add(bytes[i])
    i = i + 1
  }
  acc
}

record ParsedUnmaskedFrame {
  fin: Bool
  opcode: Int
  payload: slice[Byte]
  rest: slice[Byte]
}

func tryParseUnmaskedFrame(buf: in slice[Byte]): Option[ParsedUnmaskedFrame] {
  if buf.length < 2 {
    return None
  }
  val b0 = buf[0].toInt()
  val b1 = buf[1].toInt()
  val fin = b0.and(128) != 0
  val opcode = b0.and(15)
  val lenField = b1.and(127)
  var headerLen = 2
  var payloadLen = 0
  if lenField <= 125 {
    payloadLen = lenField
  } else if lenField == 126 {
    if buf.length < 4 {
      return None
    }
    payloadLen = buf[2].toInt().shl(8).or(buf[3].toInt())
    headerLen = 4
  } else {
    if buf.length < 10 {
      return None
    }
    // Test payloads never exceed the 16-bit range, so only the low 4 bytes
    // of the 8-byte extended length are consulted.
    payloadLen = buf[6].toInt().shl(24).or(buf[7].toInt().shl(16)).or(buf[8].toInt().shl(8)).or(buf[9].toInt())
    headerLen = 10
  }
  val totalLen = headerLen + payloadLen
  if buf.length < totalLen {
    return None
  }
  Some(
    value = ParsedUnmaskedFrame(
      fin = fin,
      opcode = opcode,
      payload = buf.slice(headerLen, totalLen),
      rest = buf.slice(totalLen, buf.length)
    )
  )
}

func payloadText(f: in ClientFrame): String {
  match tryDecodeUtf8(f.payload) {
    case Some(t) -> t
    case None -> ""
  }
}

func bytesOf3(a: in Int, b: in Int, c: in Int): slice[Byte] {
  val acc: List[Byte] = newList()
  acc.add(a.toByte())
  acc.add(b.toByte())
  acc.add(c.toByte())
  acc.toArray()
}

func lastConnIdOrPanic(holder: in RegistryHolder): String {
  match holder.lastConnId {
    case Some(id) -> id
    case None -> panic("handler onOpen never ran (unreachable — the handshake already completed)")
  }
}

// ─── Tests ──────────────────────────────────────────────────────────────────────
test "loopback: connect, handshake, text echo, and registry state" {
  val started = startEchoServer(19501)
  val registry = started.registry
  val conn = dial("127.0.0.1", 19501)
  val outcome = clientHandshake(conn, "/ws")
  assertTrue(contains(outcome.statusLine, "101"), "handshake response is 101: " + outcome.statusLine)
  assertEqual(outcome.acceptHeader, computeAcceptKey(clientKey), "Sec-WebSocket-Accept matches the RFC 6455 derivation")

  val reader = ClientReader()
  clientSendMasked(conn, 1, true, encodeUtf8("hello"))
  val echoed = clientReadFrame(conn, reader)
  assertEqualInt(echoed.opcode, 1, "echoed frame is a text frame")
  assertEqual(payloadText(echoed), "echo:hello", "text message echoed by the handler")

  threadSleep(50)
  assertEqualInt(connectionCount(registry), 1, "one open connection")
  assertTrue(isConnected(registry, lastConnIdOrPanic(started.holder)), "isConnected is true for the live connection")

  clientSendMasked(conn, 8, true, encodeClosePayload(1000, "bye"))
  val closeFrame = clientReadFrame(conn, reader)
  assertEqualInt(closeFrame.opcode, 8, "server echoes a close frame")
  val closeCode = closeFrame.payload[0].toInt().shl(8).or(closeFrame.payload[1].toInt())
  assertEqualInt(closeCode, 1000, "echoed close code matches")

  threadSleep(150)
  assertEqualInt(connectionCount(registry), 0, "connection count drops to 0 after the close handshake completes")
  assertFalse(
    isConnected(registry, lastConnIdOrPanic(started.holder)),
    "isConnected is false once the connection has closed"
  )

  hostClose(conn)
  val _ = stopServer(registry)
}

test "loopback: binary echo and a fragmented text message" {
  val started = startEchoServer(19502)
  val conn = dial("127.0.0.1", 19502)
  val _ = clientHandshake(conn, "/ws")
  val reader = ClientReader()

  val binaryPayload = bytesOf3(1, 2, 3)
  clientSendMasked(conn, 2, true, binaryPayload)
  val binEcho = clientReadFrame(conn, reader)
  assertEqualInt(binEcho.opcode, 2, "echoed frame is binary")
  assertEqualInt(binEcho.payload.length, 3, "binary payload length round-trips")
  assertEqualInt(binEcho.payload[0].toInt(), 1, "binary byte 0")
  assertEqualInt(binEcho.payload[1].toInt(), 2, "binary byte 1")
  assertEqualInt(binEcho.payload[2].toInt(), 3, "binary byte 2")

  // Fragmented text message: "Hel" (fin=0) + "lo" (opcode=continuation, fin=1).
  clientSendMasked(conn, 1, false, encodeUtf8("Hel"))
  clientSendMasked(conn, 0, true, encodeUtf8("lo"))
  val fragEcho = clientReadFrame(conn, reader)
  assertEqualInt(fragEcho.opcode, 1, "reassembled fragmented message echoed as text")
  assertEqual(payloadText(fragEcho), "echo:Hello", "fragments reassembled server-side before the handler saw them")

  hostClose(conn)
  val _ = stopServer(started.registry)
}

test "loopback: ping is answered with pong by the application handler" {
  val started = startEchoServer(19503)
  val conn = dial("127.0.0.1", 19503)
  val _ = clientHandshake(conn, "/ws")
  val reader = ClientReader()

  clientSendMasked(conn, 9, true, encodeUtf8("ping-data"))
  val pong = clientReadFrame(conn, reader)
  assertEqualInt(pong.opcode, 10, "server replies with a pong frame (opcode 10)")

  hostClose(conn)
  val _ = stopServer(started.registry)
}

test "loopback: send and broadcast pushed from outside any handler callback" {
  val started = startEchoServer(19504)
  val registry = started.registry
  val conn1 = dial("127.0.0.1", 19504)
  val hs1 = clientHandshake(conn1, "/ws")
  val reader1 = ClientReader()
  threadSleep(50)
  // Captured before connection 2 dials — `RegistryHolder.lastConnId` holds
  // whichever connection's onOpen ran most recently, so this must be read
  // while connection 1 is still the only one open.
  val conn1Id = lastConnIdOrPanic(started.holder)
  val conn2 = dial("127.0.0.1", 19504)
  val hs2 = clientHandshake(conn2, "/ws")
  val reader2 = ClientReader()
  threadSleep(50)
  assertEqualInt(connectionCount(registry), 2, "two open connections")

  val _ = sendText(registry, conn1Id, "direct-to-conn1")
  val direct1 = clientReadFrame(conn1, reader1)
  assertEqual(
    payloadText(direct1),
    "direct-to-conn1",
    "Ws.sendText pushed to a specific connection id from outside the handler"
  )

  val _ = broadcastText(registry, "hello-all")
  val b1 = clientReadFrame(conn1, reader1)
  val b2 = clientReadFrame(conn2, reader2)
  assertEqualInt(b1.opcode, 1, "broadcast delivered as a text frame to connection 1")
  assertEqual(payloadText(b1), "hello-all", "broadcast payload delivered to connection 1")
  assertEqualInt(b2.opcode, 1, "broadcast delivered as a text frame to connection 2")
  assertEqual(payloadText(b2), "hello-all", "broadcast payload delivered to connection 2")

  hostClose(conn1)
  hostClose(conn2)
  val _ = stopServer(registry)
}
