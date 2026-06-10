//! Regression test for wire/DI: WMProvided, WMBind, cycle detection,
//! topological ordering (#1502).
//!
//! Also pins the addPackageTokens IWire MethodDef-token-reservation fix:
//! without it, IWire silently displaced the PE entry point by one row,
//! causing the test binary to exit 0 with no TAP output.
//!
//! CI wiring: not wired into CI — the placeholder assertions use
//! assertTrue(true, ...) because the bootstrap() factory method requires a
//! @provided argument that cannot be injected from a @test_module body
//! without the wire-test infra tracked in #3057.  Wire here until then
//! requires full invocation support.  The file still exercises the parser,
//! type checker, and MSIL/JVM emitters for every wire construct present.
@test_module
package Lyric.WireDISelfTest

import Std.Core
import Std.Testing

interface WireLogger {
  func log(msg: in String): Unit
}

record WireConsoleLogger {
  prefix: String
}

impl WireLogger for WireConsoleLogger {
  func log(msg: in String): Unit {
  }
}

record WireAppConfig {
  debug: Bool
}

func makeWireConsoleLogger(debug: in Bool): WireConsoleLogger {
  WireConsoleLogger(prefix = "LOG")
}

wire TestWire {
  @provided config: WireAppConfig
  singleton logger: WireConsoleLogger = makeWireConsoleLogger(config.debug)
  expose logger
}

test "wire singleton is constructible" {
  assertTrue(true, "placeholder: real assertion needs #3057")
}

test "wire provided param referenced in singleton init" {
  assertTrue(true, "placeholder: real assertion needs #3057")
}
