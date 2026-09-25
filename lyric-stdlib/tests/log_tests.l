//! stdlib/tests/log_tests.l — Tests for Std.Log.
//!
//! Regression coverage for the structured-fields path (docs/59 §8.1):
//! `escapeLogValue` built its output with `s.substring(i, i + 1)`, but
//! `substring`'s second argument is a COUNT, so any field key or value of
//! length >= 2 violated the `start + count <= s.length` precondition and
//! panicked at runtime. Every test here drives the public `log` entry
//! point end-to-end through `formatFields`/`escapeLogValue` down to the
//! host stderr sink — reaching the assertion after each call proves the
//! fields path ran without panicking.
@test_module
package Std.Log.Tests

import Std.Core
import Std.Log
import Std.Testing

test "log with a multi-char field key and value does not panic" {
  log(Info, "fields path", [field("requestId", "req-12345")])
  assertTrue(true, "single multi-char field logged")
}

test "log with several multi-char fields does not panic" {
  log(
    Debug,
    "fields path",
    [field("component", "billing"), field("operation", "chargeCard"), field("outcome", "declined")]
  )
  assertTrue(true, "three multi-char fields logged")
}

test "log escapes newline, equals, and quote in a field value" {
  log(Warn, "escape path", [field("payload", "line1\nline2=v \"quoted\"")])
  assertTrue(true, "value containing \\n, =, and \" logged")
}

test "log escapes carriage return and backslash in a field value" {
  log(Error, "escape path", [field("payload", "left\rright c:\\temp\\x")])
  assertTrue(true, "value containing \\r and backslash logged")
}

test "log escapes special characters in a field key" {
  log(Info, "escape path", [field("odd=key\"name", "v")])
  assertTrue(true, "key containing = and \" logged")
}

test "log with an empty fields slice does not panic" {
  log(Info, "no fields", [])
  assertTrue(true, "empty fields slice logged")
}

test "every level helper logs without panicking" {
  debug("log_tests: debug line")
  info("log_tests: info line")
  warn("log_tests: warn line")
  error("log_tests: error line")
  assertTrue(true, "all four level helpers ran")
}

test "field carries key and value through the record" {
  val f = field("sessionId", "abc-123")
  assertEqual(f.key, "sessionId", "field key round-trips")
  assertEqual(f.value, "abc-123", "field value round-trips")
}

// #7245: the message itself was written raw, so CR/LF in a message (often
// built from request data) forged extra log lines.
test "renderLogLine escapes line breaks and control characters in the message" {
  assertEqual(
    renderLogLine("user bob\nlevel=error admin login", []),
    "user bob\\nlevel=error admin login",
    "LF is escaped"
  )
  assertEqual(renderLogLine("a\rb", []), "a\\rb", "CR is escaped")
  assertEqual(renderLogLine("nul\u{0000}bell\u{0007}", []), "nul\\u0000bell\\u0007", "other C0 controls are escaped")
  assertEqual(renderLogLine("sep x", []), "sep\\u2028x", "Unicode line separator is escaped")
  assertEqual(
    renderLogLine("tab\tkept = \"as is\"", []),
    "tab\tkept = \"as is\"",
    "tab, = and quotes stay in the message"
  )
}

test "renderLogLine keeps every field on the same line" {
  val line = renderLogLine("m", [field("k", "v1\nv2")])
  assertEqual(line, "m k=v1\\nv2", "field value line break is escaped")
}

test "a LogField with an empty key violates its invariant" {
  assertPanics("empty key", { -> val _ = LogField(key = "", value = "v") })
}
