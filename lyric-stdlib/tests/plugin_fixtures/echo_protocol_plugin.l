//! tests/plugin_fixtures/echo_protocol_plugin.l — a protocol plugin for
//! `plugin_protocol_e2e_tests.l`. It speaks a small line protocol of its own
//! on stdin and stdout, the way a language server speaks LSP: the host never
//! sends `plugin/hello` to it (docs/69 §4.3).
//!
//! - `ping <text>` answers `pong <text>`;
//! - `crash` exits with status 3 (a panic on native, #6901), which the host
//!   counts as a crash;
//! - `exit` exits cleanly;
//! - end of input exits cleanly.
//!
//! `scripts/ci/plugin-protocol-e2e.sh` builds it.
package PluginFixture.EchoProtocol

import Std.Core
import Std.Console
import Std.Environment
import Std.String as Str

@cfg(target = "dotnet")
func crashNow(): Unit {
  exitCode(3)
}

@cfg(target = "jvm")
func crashNow(): Unit {
  exitCode(3)
}

@cfg(target = "native")
func crashNow(): Unit {
  panic("echo_protocol_plugin: crashing on request")
}

func main(): Int {
  while true {
    val line = match readLine() { case Ok(l) -> l; case Err(_) -> return 0 }
    if line == "exit" {
      return 0
    } else if line == "crash" {
      crashNow()
    } else if Str.startsWith(line, "ping ") {
      println("pong " + Str.substring(line, 5))
    } else {
      println("error unknown request: " + line)
    }
  }
  0
}
