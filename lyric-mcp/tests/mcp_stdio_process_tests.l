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
//! `@cfg(target = "dotnet")`: the JVM piped-process kernel
//! (`lyric-stdlib/std/_kernel_jvm/process_piped_host.l`) has a real,
//! precisely documented, unresolved read-side gap (see that file's module
//! doc) — spawning and writing are fine, but reading a line back from a
//! live pipe is not, sometimes blocking well past any reasonable test
//! deadline. Registering this file unconditionally would make `lyric test
//! --manifest lyric-mcp/lyric.toml --target jvm` *hang* rather than fail,
//! which is a worse CI citizen than a documented gap. Gating the whole
//! file to the target it is proven on via `@cfg` (docs/24-build-features.md
//! "Whole-file gating") is the standard, visible way to express that in
//! this codebase — it stays registered in `[project.tests]` and simply
//! compiles to nothing on `--target jvm`, rather than needing a separate
//! manual-run note (the approach `lyric-ws/tests/ws_jvm_e2e_test.l` uses
//! for an analogous real, unresolved JVM gap, by omitting the file from
//! `[project.tests]` entirely).
@cfg(target = "dotnet")
@test_module
package Mcp.McpStdioProcessTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.Process
import JsonRpc
import JsonRpc.Json
import Mcp.Stdio

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
            case Ok(v) -> match getString(v, "method") { case Some(m) -> assertEqual(m, "ping", "round-tripped method field"); case None -> assertTrue(false, "expected a 'method' field") }
          }
        }
      }
      transport.close()
    }
  }
}
