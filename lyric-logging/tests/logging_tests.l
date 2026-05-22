// tests/logging_tests.l — test suite for the Std.Logging package.
// Covers: getLogger, field, and isEnabled against the default Info level.
// Log emission functions (info/warn/error/etc.) call the host sink and are
// safe to invoke in tests but their output is not captured here.

@test_module
package Std.Logging.LoggingTests

import Std.Core
import Std.Testing
import Std.Logging

// ─── getLogger ────────────────────────────────────────────────────────────────

test "getLogger returns a Logger with the requested name" {
  val logger = Std.Logging.getLogger("myapp")
  assertEqual(logger.name, "myapp", "logger name")
}

test "getLogger with a multi-segment name preserves the full name" {
  val logger = Std.Logging.getLogger("myapp.service.handler")
  assertEqual(logger.name, "myapp.service.handler", "dotted logger name")
}

test "getLogger is pure: calling it twice with the same name yields the same name" {
  val a = Std.Logging.getLogger("server")
  val b = Std.Logging.getLogger("server")
  assertEqual(a.name, b.name, "same name both times")
}

test "multiple loggers with different names are independent" {
  val logA = Std.Logging.getLogger("alpha")
  val logB = Std.Logging.getLogger("beta")
  assertEqual(logA.name, "alpha", "first logger name")
  assertEqual(logB.name, "beta",  "second logger name")
  assertTrue(logA.name != logB.name, "loggers have distinct names")
}

// ─── field ────────────────────────────────────────────────────────────────────

test "field returns a LogField with the correct key" {
  val f = Std.Logging.field("request_id", "abc-123")
  assertEqual(f.key, "request_id", "field key")
}

test "field returns a LogField with the correct value" {
  val f = Std.Logging.field("user", "alice")
  assertEqual(f.value, "alice", "field value")
}

test "field with an empty value is valid" {
  val f = Std.Logging.field("optional", "")
  assertEqual(f.key,   "optional", "field key with empty value")
  assertEqual(f.value, "",         "field value is empty string")
}

test "two distinct fields have independent key/value pairs" {
  val f1 = Std.Logging.field("env",  "prod")
  val f2 = Std.Logging.field("host", "web-01")
  assertEqual(f1.key,   "env",    "f1 key")
  assertEqual(f1.value, "prod",   "f1 value")
  assertEqual(f2.key,   "host",   "f2 key")
  assertEqual(f2.value, "web-01", "f2 value")
}

// ─── isEnabled (default level = Info, ordinal 2) ─────────────────────────────

test "isEnabled(Info) returns true at the default level" {
  assertTrue(Std.Logging.isEnabled(LogLevel.Info), "Info must be enabled by default")
}

test "isEnabled(Warn) returns true (above the default level)" {
  assertTrue(Std.Logging.isEnabled(LogLevel.Warn), "Warn must be enabled by default")
}

test "isEnabled(Error) returns true (above the default level)" {
  assertTrue(Std.Logging.isEnabled(LogLevel.Error), "Error must be enabled by default")
}

test "isEnabled(Fatal) returns true (above the default level)" {
  assertTrue(Std.Logging.isEnabled(LogLevel.Fatal), "Fatal must be enabled by default")
}

test "isEnabled(Debug) returns false (below the default level)" {
  assertTrue(not Std.Logging.isEnabled(LogLevel.Debug), "Debug must be disabled by default")
}

test "isEnabled(Trace) returns false (below the default level)" {
  assertTrue(not Std.Logging.isEnabled(LogLevel.Trace), "Trace must be disabled by default")
}
