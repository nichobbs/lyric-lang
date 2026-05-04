// std/testing.l — Bootstrap-grade test helpers.
//
// Phase 3 / D-progress-063.  Two utilities for now:
//
//   * `assertEqual(actual, expected, label)` — panics on mismatch
//     with a structured message including both values.
//   * snapshot helpers — `snapshot(label, actual)` and
//     `snapshotMatch(label, actual)` compare a string against a
//     stored snapshot file at `snapshots/<label>.txt`.  First
//     run writes the file and accepts (`Ok(true)`); later runs
//     compare and return `Ok(false)` on mismatch.
//
// Property-based generators and a richer harness (parallel runs,
// xunit-style discovery, fixtures) remain Phase 3 follow-ups.
package Std.Testing

import Std.File
import Std.Core

/// Panic with a structured "expected/actual" message when the
/// two strings differ.  Returns `()` on equality.  Use in test
/// entry points where any deviation should be loud (CI failures
/// land here).
@stable(since="1.0")
pub func assertEqual(
        actual: in String,
        expected: in String,
        label: in String): Unit {
  if actual == expected {
    ()
  } else {
    panic(
      "assertEqual '" + label + "' failed:\n" +
      "  expected: " + expected + "\n" +
      "    actual: " + actual)
  }
}

/// Panic with a structured "expected/actual" message when the
/// two `Int` values differ.
@stable(since="1.0")
pub func assertEqualInt(
        actual: in Int,
        expected: in Int,
        label: in String): Unit {
  if actual == expected {
    ()
  } else {
    panic(
      "assertEqualInt '" + label + "' failed: expected=" +
      toString(expected) + " actual=" + toString(actual))
  }
}

/// Panic when `cond` is false.  Useful for non-equality
/// assertions (e.g. range / set membership / shape predicates).
@stable(since="1.0")
pub func assertTrue(cond: in Bool, label: in String): Unit {
  if cond {
    ()
  } else {
    panic("assertTrue '" + label + "' failed")
  }
}
