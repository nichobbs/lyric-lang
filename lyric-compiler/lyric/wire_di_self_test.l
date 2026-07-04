//! Regression test for wire/DI: WMProvided, WMBind, cycle detection,
//! topological ordering (#1502).
//!
//! Also pins the addPackageTokens IWire MethodDef-token-reservation fix:
//! without it, IWire silently displaced the PE entry point by one row,
//! causing the test binary to exit 0 with no TAP output.
//!
//! Real bootstrap()-invoking assertions (#5020, #5022): the two JVM-side
//! blockers that made this file's `bootstrap()` call unusable are both
//! fixed — #5020 (registerStaticWireSig always registered `bootstrap` as
//! zero-arg, so any `@provided` member made every call site resolve
//! against the wrong descriptor) and #5022 (a record implementing an
//! interface with an empty-bodied method — this file's own
//! `WireConsoleLogger.log`, whose body is intentionally empty — failed
//! class load with `ClassFormatError: Arguments can't fit into locals`,
//! since `inferMaxLocals` only scanned load/store instructions and never
//! accounted for the parameter frame itself when the body touches none of
//! its parameters).
//!
//! CI wiring: `--target jvm` only. `--target dotnet` still fails at
//! runtime — MSIL has no equivalent of `registerStaticWireSig` or its
//! `lowerMethodCall` lookup fast path at all, so `<Wire>.bootstrap()` /
//! exposed-accessor calls have never resolved on that target for *any*
//! wire (tracked separately as #5021, out of scope here).
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
  if debug {
    WireConsoleLogger(prefix = "DEBUG")
  } else {
    WireConsoleLogger(prefix = "LOG")
  }
}

wire TestWire {
  @provided config: WireAppConfig
  singleton logger: WireConsoleLogger = makeWireConsoleLogger(config.debug)
  expose logger
}

test "wire singleton is constructible" {
  TestWire.bootstrap(WireAppConfig(debug = false))
  val logger = TestWire.logger()
  assertEqual(logger.prefix, "LOG", "singleton constructed via non-debug provided config")
}

test "wire provided param referenced in singleton init" {
  TestWire.bootstrap(WireAppConfig(debug = true))
  val logger = TestWire.logger()
  assertEqual(logger.prefix, "DEBUG", "singleton init reads the @provided config's field")
}
