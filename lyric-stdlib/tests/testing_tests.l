// stdlib/tests/testing_tests.l — Tests for Std.Testing's panic-catching
// helpers (`assertPanics`, `assertPanicsWith`).
//
// These pin #1176's resolution: a function that documents its panic
// behaviour can have that behaviour exercised by a test, so a refactor
// that silently regresses to a returning-Ok stub is caught by CI.
package Std.Testing.Tests

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Test fixtures — small functions whose panic / non-panic behaviour is
// known and stable.  `panickingFn` always panics with the same message
// substring; `nonPanickingFn` always returns Unit.
// ─────────────────────────────────────────────────────────────────────────────

func panickingFn(): Unit {
  panic("test fixture: this is the expected message")
}

func nonPanickingFn(): Unit {
  ()
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

func testAssertPanicsCatchesPanic(): Unit {
  // Happy path — `panickingFn()` panics, `assertPanics` returns.
  assertPanics("panicking fn caught", { -> panickingFn() })
}

func testAssertPanicsWithMatchesSubstring(): Unit {
  // The runtime envelope prefixes "panic: " to the user message; the
  // substring we match is the user-supplied portion.
  assertPanicsWith(
    "panicking fn caught with substring",
    "this is the expected message",
    { -> panickingFn() })
}

func testAssertPanicsRoundTripsThroughANonPanickingHelper(): Unit {
  // `assertPanics` itself panics when the inner function returns
  // normally.  Verify that by wrapping it in another `assertPanics`
  // — the outer one catches the inner's "expected a panic" panic.
  assertPanicsWith(
    "outer catches inner's missing-panic panic",
    "function returned normally",
    { -> assertPanics("inner should panic on success", { -> nonPanickingFn() }) })
}

func testAssertPanicsWithRejectsWrongSubstring(): Unit {
  // When the substring does not match, `assertPanicsWith` panics with
  // its own message.  Verify via a second-level wrapper.
  assertPanicsWith(
    "wrong-substring case panics with diagnostic",
    "panic message did not contain expected substring",
    { ->
      assertPanicsWith(
        "inner should fail substring check",
        "substring that is definitely not in the message",
        { -> panickingFn() })
    })
}

func main(): Unit {
  testAssertPanicsCatchesPanic()
  testAssertPanicsWithMatchesSubstring()
  testAssertPanicsRoundTripsThroughANonPanickingHelper()
  testAssertPanicsWithRejectsWrongSubstring()
  println("testing: ok")
}
