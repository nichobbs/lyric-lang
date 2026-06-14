//! tests/ws_tests.l — tests for the pure-Lyric surface of the Ws package.
//!
//! Covers WsError, WsCloseCode, and WsMessage type construction.
//! Connection lifecycle and registry functions require a running WebSocket
//! server and are not exercised here.
@test_module
package Ws.WsTests

import Std.Core
import Std.Testing
import Ws

// ─── WsError ─────────────────────────────────────────────────────────────────
test "WsError: fields are accessible" {
  val e = WsError(message = "frame too large", code = "FRAME_TOO_LARGE", connectionId = "conn-1")
  assertEqual(e.message, "frame too large", "message field")
  assertEqual(e.code, "FRAME_TOO_LARGE", "code field")
  assertEqual(e.connectionId, "conn-1", "connectionId field")
}

test "WsError: empty code is valid" {
  val e = WsError(message = "connection closed", code = "", connectionId = "conn-42")
  assertEqual(e.code, "", "empty code is valid")
}

// ─── WsCloseCode ─────────────────────────────────────────────────────────────
test "WsCloseCode.Normal: carries close code integer" {
  val c: WsCloseCode = Normal(1000)
  match c {
    case WsCloseCode.Normal(n) -> assertEqualInt(n, 1000, "normal close code 1000")
    case _ -> assertTrue(false, "expected Normal")
  }
}

test "WsCloseCode.GoingAway: can be matched" {
  val c = WsCloseCode.GoingAway
  match c {
    case WsCloseCode.GoingAway -> ()
    case _ -> assertTrue(false, "expected GoingAway")
  }
}

test "WsCloseCode.ProtocolError: can be matched" {
  val c = WsCloseCode.ProtocolError
  match c {
    case WsCloseCode.ProtocolError -> ()
    case _ -> assertTrue(false, "expected ProtocolError")
  }
}

test "WsCloseCode.Normal: custom application close code" {
  val c: WsCloseCode = Normal(4000)
  match c {
    case WsCloseCode.Normal(n) -> assertTrue(n == 4000, "application close code 4000")
    case _ -> assertTrue(false, "expected Normal with code 4000")
  }
}
