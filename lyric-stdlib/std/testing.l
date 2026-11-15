//! std/testing.l — Bootstrap-grade test helpers.
//!
//! Phase 3 / D-progress-063.  Utilities:
//!
//!   * `assertEqual(actual, expected, label)` — panics on mismatch
//!     with a structured message including both values.
//!   * `assertEqualInt(actual, expected, label)` — integer variant.
//!   * `assertEqualLong(actual, expected, label)` — long variant.
//!   * `assertTrue(cond, label)` — generic predicate assertion.
//!   * `assertFalse(cond, label)` — panics when condition is true.
//!   * `assertPanics(label, fn)` — runs `fn()` under `Std.PanicTrapHost`
//!     and asserts that it panicked (raised a `Bug`); fails the test
//!     when `fn()` returns normally.  On `--target native`, which cannot
//!     unwind, `fn()` runs in a forked child process (D608): its
//!     in-memory effects are not visible afterwards.
//!   * `assertPanicsWith(label, expectedSubstring, fn)` — like
//!     `assertPanics`, additionally checks that the panic message
//!     contains `expectedSubstring`.
//!   * snapshot helpers — `snapshot(label, actual)` and
//!     `snapshotMatch(label, actual)` compare a string against a
//!     stored snapshot file at `snapshots/<label>.txt`.  First
//!     run writes the file and accepts (`Ok(true)`); later runs
//!     compare and return `Ok(false)` on mismatch.
//!
//! Property-based generators and a richer harness (parallel runs,
//! xunit-style discovery, fixtures) remain Phase 3 follow-ups.
@io
package Std.Testing

import Std.File
import Std.Core
import Std.PanicTrapHost

// Intentionally NOT importing `Std.String` here: it exports `join /
// contains / startsWith / …` symbols that collide with same-named
// helpers in other stdlib modules (notably `Std.Path.join`), and the
// resolver bleeds those into any file that transitively imports
// `Std.Testing`.  `String.contains(substring)` is callable as a
// method directly, so we get the substring check we need without
// the namespace leak.
/// Panic with a structured "expected/actual" message when the
/// two strings differ.  Returns `()` on equality.  Use in test
/// entry points where any deviation should be loud (CI failures
/// land here).
@stable(since = "1.0")
pub func assertEqual(actual: in String, expected: in String, label: in String): Unit {
  if actual == expected {
    ()
  } else {
    panic("assertEqual '" + label + "' failed:\n" + "  expected: " + expected + "\n" + "    actual: " + actual)
  }
}

/// Panic with a structured "expected/actual" message when the
/// two `Int` values differ.
@stable(since = "1.0")
pub func assertEqualInt(actual: in Int, expected: in Int, label: in String): Unit {
  if actual == expected {
    ()
  } else {
    panic("assertEqualInt '" + label + "' failed: expected=" + toString(expected) + " actual=" + toString(actual))
  }
}

/// Panic with a structured "expected/actual" message when the
/// two `Long` values differ.
@stable(since = "1.0")
pub func assertEqualLong(actual: in Long, expected: in Long, label: in String): Unit {
  if actual == expected {
    ()
  } else {
    panic("assertEqualLong '" + label + "' failed: expected=" + toString(expected) + " actual=" + toString(actual))
  }
}

/// Panic when `cond` is false.  Useful for non-equality
/// assertions (e.g. range / set membership / shape predicates).
@stable(since = "1.0")
pub func assertTrue(cond: in Bool, label: in String): Unit {
  if cond {
    ()
  } else {
    panic("assertTrue '" + label + "' failed")
  }
}

/// Panic when `cond` is true.  Companion to `assertTrue`, useful
/// for asserting that a condition is NOT satisfied.
@stable(since = "1.0")
pub func assertFalse(cond: in Bool, label: in String): Unit {
  if cond {
    panic("assertFalse '" + label + "' failed")
  }
}

/// Run `fn()` and panic unless it panicked.  Useful for testing
/// functions that are documented to fail loudly when called outside
/// their supported context (`lyric-health.runChecks` until the
/// kernel dispatcher lands; argument-validation hot paths; etc.).
///
/// Implementation notes:
///   * `panic(msg)` lowers to `throw new System.Exception("panic: " + msg)`,
///     and `try { … } catch Bug as b { … }` catches `System.Exception`
///     (`Codegen.fs` maps the `Bug` exception name to `System.Exception`).
///     The two together let us catch the panic and recover.
///   * On the JVM target the same shape lowers to a Throwable catch via
///     `Std.JvmExceptionHost`; the user-visible contract is identical.
///   * `--target native` cannot unwind (D-N-003), so `Std.PanicTrapHost`'s
///     native twin runs `fn()` in a forked child and reads its verdict from
///     the child's exit (D608).  The pass/fail contract and the panic text
///     are the same; `fn`'s effects on the caller's memory are not (a
///     list it fills stays empty), and Windows and wasm32-wasi,
///     which have no fork, fail the assertion with a message saying so.
@stable(since = "1.0")
pub func assertPanics(label: in String, fn: in () -> Unit): Unit {
  match trapPanic(fn) {
    case PtRan -> {
      panic("assertPanics '" + label + "' failed: function returned normally, expected a panic")
    }
    case PtPanicked(_) -> {
      ()
    }
    case PtFailed(why) -> {
      panic("assertPanics '" + label + "' failed: " + why)
    }
  }
}

/// Variant of `assertPanics` that also checks that the panic's
/// message contains `expectedSubstring`.  The panic prefix `"panic: "`
/// is part of the runtime envelope (see `Codegen.fs:3458-3467`); pass
/// the substring that distinguishes the *user-supplied* panic message
/// (typically a unique identifier from the assertion site).
@stable(since = "1.0")
pub func assertPanicsWith(label: in String, expectedSubstring: in String, fn: in () -> Unit): Unit {
  match trapPanic(fn) {
    case PtRan -> {
      panic("assertPanicsWith '" + label + "' failed: function returned normally, expected a panic")
    }
    case PtFailed(why) -> {
      panic("assertPanicsWith '" + label + "' failed: " + why)
    }
    case PtPanicked(msg) -> {
      if not msg.contains(expectedSubstring) {
        panic(
          "assertPanicsWith '" + label + "' failed: panic message did not contain expected substring\n" +
            "  expected substring: " +
            expectedSubstring +
            "\n" +
            "  actual message:     " +
            msg
        )
      }
    }
  }
}
