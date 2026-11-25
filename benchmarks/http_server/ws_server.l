//! benchmarks/http_server/ws_server.l - WebSocket fan-out server (docs/73 S0, B7).
//!
//! Serves `/ws` through `Ws.startServer` and broadcasts one text message of `WS_BYTES` (default 1024) bytes
//! to every connected client `WS_HZ` (default 10) times a second. A message starts with the 13-digit epoch
//! millisecond timestamp at which the broadcast began, so `ws_clients.l` can compute delivery latency
//! on the same machine. It must be built from inside the lyric-ws manifest directory so the target's backend
//! resolves (a path outside it fails with T0211), so copy it in for the build and remove it again:
//!
//!   cp benchmarks/http_server/ws_server.l lyric-ws/tests/zz_bench_ws_server.l
//!   (cd lyric-ws && lyric build --target dotnet tests/zz_bench_ws_server.l -o ws_server.dll)   # pure-Lyric RFC 6455
//!   lyric restore --manifest lyric-ws/lyric.toml                                               # JVM: Maven Central
//!   (cd lyric-ws && lyric build --target jvm --features jvm tests/zz_bench_ws_server.l -o ws_server.jar)  # Undertow
//!   rm lyric-ws/tests/zz_bench_ws_server.l
//!
//! Environment: `WS_PORT` (8190), `WS_BYTES` (1024), `WS_HZ` (10), `WS_SECONDS` (run time, 40), and the server
//! prints `WS-BROADCAST connections=<n> sent=<n> worst_call_ms=<n>` every second, `worst_call_ms` being the longest
//! `broadcastText` call since the last line (a stalled consumer shows up here). Not part of CI (see README.md).
package Ws.BenchServer

import Std.Core
import Std.Collections
import Std.Console
import Std.Environment
import Std.Parse
import Std.String
import Std.Time as Time
import Ws

record SilentHandler {
}

impl WsHandler for SilentHandler {
  func onOpen(ctx: in WsContext): Result[Unit, WsError] {
    Ok(())
  }

  func onMessage(ctx: in WsContext, msg: in WsMessage): Result[Unit, WsError] {
    Ok(())
  }

  func onClose(ctx: in WsContext, code: in WsCloseCode): Unit {
    ()
  }

  func onError(ctx: in WsContext, error: in WsError): Unit {
    ()
  }
}

func intVar(name: in String, fallback: in Int): Int {
  match getVar(name) {
    case Err(_) -> fallback
    case Ok(s) -> match parseOptInt(s) { case Some(n) -> n; case None -> fallback }
  }
}

func main(): Int {
  val port = intVar("WS_PORT", 8190)
  val bytes = intVar("WS_BYTES", 1024)
  val hz = intVar("WS_HZ", 10)
  val seconds = intVar("WS_SECONDS", 40)
  val registry = match startServerWithConfig("127.0.0.1", port, "/ws", 1048576, SilentHandler()) {
    case Ok(r) -> r
    case Err(e) -> panic("startServer failed: " + e.message)
  }
  println("listening " + port.toString())
  val padding = repeat("x", bytes - 13)
  val periodMs = 1000 / hz
  val endAt = Time.nowEpochMillis() + seconds.toLong() * 1000
  var lastReport = Time.nowEpochMillis()
  var broadcasts = 0
  var worstCallMs = 0i64
  while Time.nowEpochMillis() < endAt {
    val tick = Time.nowEpochMillis()
    val _ = broadcastText(registry, tick.toString() + padding)
    val callMs = Time.nowEpochMillis() - tick
    if callMs > worstCallMs {
      worstCallMs = callMs
    }
    broadcasts = broadcasts + 1
    if tick - lastReport >= 1000 {
      println(
        "WS-BROADCAST connections=" + connectionCount(registry).toString() + " sent=" + broadcasts.toString() +
          " worst_call_ms=" +
          worstCallMs.toString()
      )
      worstCallMs = 0i64
      lastReport = tick
    }
    val spent = (Time.nowEpochMillis() - tick).toInt()
    if periodMs > spent {
      Time.sleepMillis(periodMs - spent)
    }
  }
  println("WS-DONE broadcasts=" + broadcasts.toString())
  val _ = stopServer(registry)
  0
}
