//! tests/mcp_stdio_process_tests.l — end-to-end real-child-process tests
//! for `Std.Process.spawnPiped` / `Mcp.Stdio.newPipedNdjsonTransport`.
//!
//! Spawns real OS processes (`cat`) and drives genuine bidirectional
//! piped stdio, at two levels: the raw `Std.Process` piped API directly,
//! and `Mcp.Stdio`'s NDJSON-framed `RpcTransport` on top of it (using
//! `cat` as a trivial echo peer — it never speaks JSON-RPC, so this
//! exercises real process I/O and real NDJSON framing, not a full MCP
//! handshake; `mcp_tests.l` covers the full MCP lifecycle in-memory).
//!
//! Level 3 (#7451) points `Mcp.Client` at real child processes that stay
//! silent (`sleep`) or answer late (`sh`), and checks that a call ends at
//! its deadline and that a late answer is not delivered to the next call.
//!
//! Runs on both targets. It was once gated to `--target dotnet` because the
//! JVM piped-process kernel's line reads were unreliable; its read side was
//! rewritten as a byte-level, `available()`-polled drain (#6135, see
//! `lyric-stdlib/std/_kernel_jvm/process_piped_host.l`'s module doc), and
//! every case here passes under `--target jvm`.
@test_module
package Mcp.McpStdioProcessTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.Process
import JsonRpc
import Std.JsonValue
import Mcp
import Mcp.Stdio
import Mcp.Client

// ── Level 1: raw Std.Process.spawnPiped round-trip through `cat` ───────────
test "Std.Process.spawnPiped: a real cat subprocess echoes a written line back" {
  match spawnPiped("cat", newList()) {
    case Err(e) -> assertTrue(false, "spawn failed: " + IOError.message(e))
    case Ok(p) -> {
      assertTrue(pipedIsAlive(p), "cat is alive right after spawn")
      match pipedWriteLine(p, "hello from lyric-mcp") {
        case Err(e) -> assertTrue(false, "write failed: " + e)
        case Ok(_) -> ()
      }
      match pipedReadLine(p) {
        case Err(e) -> assertTrue(false, "read failed: " + e)
        case Ok(None) -> assertTrue(false, "unexpected EOF")
        case Ok(Some(line)) -> assertEqual(line, "hello from lyric-mcp", "cat echoed the line back unchanged")
      }
      pipedKill(p)
      assertTrue(pipedWaitExit(p, 3000), "process exited after kill")
      pipedClose(p)
    }
  }
}

test "Std.Process.spawnPiped: multiple lines round-trip in order" {
  match spawnPiped("cat", newList()) {
    case Err(e) -> assertTrue(false, "spawn failed: " + IOError.message(e))
    case Ok(p) -> {
      pipedWriteLine(p, "one")
      pipedWriteLine(p, "two")
      pipedWriteLine(p, "three")
      match pipedReadLine(p) {
        case Ok(Some(line)) -> assertEqual(line, "one", "first line")
        case _ -> assertTrue(false, "expected 'one'")
      }
      match pipedReadLine(p) {
        case Ok(Some(line)) -> assertEqual(line, "two", "second line")
        case _ -> assertTrue(false, "expected 'two'")
      }
      match pipedReadLine(p) {
        case Ok(Some(line)) -> assertEqual(line, "three", "third line")
        case _ -> assertTrue(false, "expected 'three'")
      }
      pipedKill(p)
      pipedWaitExit(p, 3000)
      pipedClose(p)
    }
  }
}

test "Std.Process.spawnPiped: pipedCloseStdin signals EOF and the child exits cleanly" {
  match spawnPiped("cat", newList()) {
    case Err(e) -> assertTrue(false, "spawn failed: " + IOError.message(e))
    case Ok(p) -> {
      pipedWriteLine(p, "last line")
      pipedCloseStdin(p)
      val exited = pipedWaitExit(p, 3000)
      assertTrue(exited, "cat exits on its own once stdin reaches EOF")
      match pipedReadLine(p) {
        case Ok(Some(line)) -> assertEqual(line, "last line", "the line written before EOF is still readable")
        case Ok(None) -> assertTrue(false, "expected the buffered line, not immediate EOF")
        case Err(e) -> assertTrue(false, "read failed: " + e)
      }
      pipedClose(p)
    }
  }
}

test "Std.Process.spawnPiped: spawning a nonexistent executable returns Err" {
  match spawnPiped("lyric-mcp-nonexistent-executable-xyz", newList()) {
    case Ok(_) -> assertTrue(false, "expected spawn to fail")
    case Err(_) -> ()
  }
}

// ── Level 2: Mcp.Stdio's NDJSON RpcTransport over a real `cat` process ─────
// `cat` never speaks JSON-RPC, so this drives the framing layer only (one
// JSON message per line, both directions), not a full MCP handshake.
test "Mcp.Stdio.newPipedNdjsonTransport: NDJSON framing round-trips through a real cat subprocess" {
  match newPipedNdjsonTransport("cat", newList()) {
    case Err(e) -> assertTrue(false, "failed to spawn transport: " + e)
    case Ok(transport) -> {
      val payload = writeValue(
        JObject(
          fields = [
            JsonField(name = "jsonrpc", value = JString(value = "2.0")),
            JsonField(name = "id", value = JInt(value = 1i64)),
            JsonField(name = "method", value = JString(value = "ping"))
          ]
        )
      )
      match transport.send(payload) {
        case Err(e) -> assertTrue(false, "send failed: " + e)
        case Ok(_) -> ()
      }
      match transport.receive() {
        case Err(e) -> assertTrue(false, "receive failed: " + e)
        case Ok(None) -> assertTrue(false, "unexpected EOF")
        case Ok(Some(line)) -> {
          assertEqual(line, payload, "cat echoed the exact NDJSON-framed message back")
          match parseValue(line) {
            case Err(e) -> assertTrue(false, "echoed line is not valid JSON: " + e.message())
            case Ok(v) -> match getString(v, "method") {
              case Some(m) -> assertEqual(m, "ping", "round-tripped method field")
              case None -> assertTrue(false, "expected a 'method' field")
            }
          }
        }
      }
      transport.close()
    }
  }
}

// ── Level 3: deadlines against real child processes (#7451) ────────────────
func shArgs(script: in String): List[String] {
  val args: List[String] = newList()
  args.add("-c")
  args.add(script)
  args
}

test "Mcp.Client over a real silent server process: a tool call times out instead of hanging" {
  // `sleep` reads nothing and writes nothing: a server that never answers.
  match connectStdio("sleep", oneArg("30")) {
    case Err(e) -> assertTrue(false, "connectStdio failed: " + e)
    case Ok(clientVal) -> {
      var client = clientVal
      match callToolWithin(client, "anything", None, 300) {
        case Ok(_) -> assertTrue(false, "a silent server must not produce a result")
        case Err(e) -> assertTrue(e.contains("timed out after 300 ms"), "the call ends at its deadline: " + e)
      }
      disconnect(client)
    }
  }
}

func oneArg(arg: in String): List[String] {
  val args: List[String] = newList()
  args.add(arg)
  args
}

test "Mcp.Client over a real server process: a late answer is dropped, the next call gets its own" {
  // Answers the first request only after the client's deadline, then answers
  // the second request promptly.
  val script = "read first; sleep 1; " + "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"stale\"}'; " +
    "read second; " +
    "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"fresh\"}],\"isError\":false}}'; " +
    "sleep 5"
  match connectStdio("sh", shArgs(script)) {
    case Err(e) -> assertTrue(false, "connectStdio failed: " + e)
    case Ok(clientVal) -> {
      var client = clientVal
      match callToolWithin(client, "slow", None, 200) {
        case Ok(_) -> assertTrue(false, "the first call must time out")
        case Err(e) -> assertTrue(e.contains("timed out"), "first call timed out: " + e)
      }
      match callToolWithin(client, "fast", None, 10000) {
        case Err(e) -> assertTrue(false, "the second call failed (was the stale answer delivered to it?): " + e)
        case Ok(result) -> match result.content[0] {
          case TextContent(t) -> assertEqual(t, "fresh", "the second call got its own answer")
          case _ -> assertTrue(false, "expected TextContent")
        }
      }
      disconnect(client)
    }
  }
}
