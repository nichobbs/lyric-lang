//! stdlib/tests/kernel_bcl_tests.l — Tests for the #1493 kernel migrations
//! off Lyric.Emitter.dll to audited BCL externs.
//!
//! Exercises, end-to-end at runtime:
//!   * Std.Log -> Std.LogHost -> Std.ConsoleHost stderr path — now pure Lyric
//!     over System.Console.get_Error + System.IO.TextWriter.WriteLine (no F#
//!     ConsoleHelper/LogHelper shim).  Each level writes to stderr; reaching
//!     the assertions afterwards proves the migrated chain resolves and runs
//!     without throwing.
//!   * Std.VerifierEnvHost.hostGetEnv — null-safe env lookup composed in pure
//!     Lyric over System.Environment.GetEnvironmentVariable (no F# VerifierEnv
//!     shim): an unset variable yields "".
//!   * Std.Console -> Std.ConsoleHost stdout path — hostConsoleWrite /
//!     hostConsoleWriteLine are auto-FFI calls on the System.Console
//!     extern type; reaching the assertion afterwards proves the
//!     migrated chain resolves and runs without throwing.
package Std.KernelBcl.Tests

import Std.Core
import Std.Console
import Std.Log
import Std.VerifierEnvHost
import Std.Testing

func testLogToStderr(): Unit {
  // All four levels route through the migrated console stderr path.
  // Reaching the next test without an uncaught exception proves the
  // chain resolves and runs end-to-end.
  debug("kernel_bcl_tests: debug line")
  info("kernel_bcl_tests: info line")
  warn("kernel_bcl_tests: warn line")
  error("kernel_bcl_tests: error line")
}

func testVerifierEnvMissing(): Unit {
  val missing = hostGetEnv("LYRIC_TEST_DEFINITELY_NONEXISTENT_XYZ123")
  assertTrue(missing == "", "unset env var returns empty string")
}

func testVerifierEnvSet(): Unit {
  // PATH (or DOTNET_ROOT on .NET CI) must be non-empty in every environment
  // where the test suite runs; this confirms the non-null value flows through
  // the hostGetEnv null-coalesce path without being replaced by "".
  val path = hostGetEnv("PATH")
  assertTrue(path != "", "set env var (PATH) must return a non-empty string")
}

func testConsoleStdoutPath(): Unit {
  // Std.Console.print / println route through Std.ConsoleHost's
  // hostConsoleWrite / hostConsoleWriteLine (System.Console.Write /
  // WriteLine resolved via auto-FFI).  Reaching the assertion proves
  // the migrated stdout chain resolves and runs end-to-end.
  print("kernel_bcl_tests: ")
  println("stdout line")
  assertTrue(true, "console stdout chain resolved and ran")
}

func main(): Unit {
  testLogToStderr()
  testVerifierEnvMissing()
  testVerifierEnvSet()
  testConsoleStdoutPath()
  println("ok")
}
