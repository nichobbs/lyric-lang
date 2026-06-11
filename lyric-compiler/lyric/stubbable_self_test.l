//! stubbable_self_test.l — end-to-end tests for `@stubbable` counter synthesis.
//! Run in CI via native `lyric test`.
//!
//! Verifies that `stubbableRewriteFile` (Lyric.Stubbable):
//!   - Adds `pub <method>_counter: StubCounter = makeStubCounter()` for every
//!     supported method (including Unit-returning ones).
//!   - Injects `import Std.Testing.Mocking` automatically — this file omits
//!     that import on purpose so the auto-injection is the only way it resolves.
//!   - The synthesised impl increments the counter on every call.
//!   - Counters are independent across methods.
//!   - `makeStubCounter()` default means construction without specifying the
//!     counter field just works.
//!   - Deduplication guard: when `import Std.Testing.Mocking` is already
//!     present in the file, `buildImports` does NOT inject a second copy
//!     (#3014).
@test_module
package Lyric.Stubbable.SelfTest

import Std.Core
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Stubbable

// Two-method interface: one value-returning, one Unit-returning.
// `import Std.Testing.Mocking` is NOT listed here; the synthesis injects it.
@stubbable
pub interface Greeter {
  func greet(name: in String): String
  func farewell(name: in String): Unit
}

// Single-method interface to verify the simple case.
@stubbable
pub interface Ticker {
  func value(): Int
}

// ─────────────────────────────────────────────────────────────────────────────
test "value field works" {
  val g = GreeterStub(greet_value = "hello")
  assertEqual(g.greet("Alice"), "hello", "greet returns configured value")
}

test "counter starts at zero" {
  val g = GreeterStub(greet_value = "hi")
  assertEqualInt(stubCounterGet(g.greet_counter), 0, "greet counter starts at 0")
  assertEqualInt(stubCounterGet(g.farewell_counter), 0, "farewell counter starts at 0")
}

test "value method counter increments" {
  val g = GreeterStub(greet_value = "hi")
  val _ = g.greet("Alice")
  val _ = g.greet("Bob")
  assertEqualInt(stubCounterGet(g.greet_counter), 2, "greet called twice")
}

test "unit method counter increments" {
  val g = GreeterStub(greet_value = "hi")
  g.farewell("Alice")
  g.farewell("Bob")
  g.farewell("Carol")
  assertEqualInt(stubCounterGet(g.farewell_counter), 3, "farewell called 3 times")
}

test "counters are independent" {
  val g = GreeterStub(greet_value = "hello")
  val _ = g.greet("A")
  val _ = g.greet("B")
  g.farewell("C")
  assertEqualInt(stubCounterGet(g.greet_counter), 2, "greet counter = 2")
  assertEqualInt(stubCounterGet(g.farewell_counter), 1, "farewell counter = 1")
}

test "counter reset" {
  val g = GreeterStub(greet_value = "hi")
  val _ = g.greet("X")
  val _ = g.greet("Y")
  assertEqualInt(stubCounterGet(g.greet_counter), 2, "before reset: 2")
  stubCounterReset(g.greet_counter)
  assertEqualInt(stubCounterGet(g.greet_counter), 0, "after reset: 0")
}

test "default counter works without explicit init" {
  val t = TickerStub(value_value = 42)
  assertEqualInt(stubCounterGet(t.value_counter), 0, "counter starts at 0")
  assertEqualInt(t.value(), 42, "value returns configured value")
  assertEqualInt(stubCounterGet(t.value_counter), 1, "counter incremented by call")
}

test "farewell does not affect greet counter" {
  val g = GreeterStub(greet_value = "bye")
  g.farewell("D")
  g.farewell("E")
  assertEqualInt(stubCounterGet(g.greet_counter), 0, "greet counter untouched")
  assertEqualInt(stubCounterGet(g.farewell_counter), 2, "farewell counter = 2")
}

// ── hasMockingImport deduplication guard (#3014) ─────────────────────────────
// When a file that already has `import Std.Testing.Mocking` also contains a
// `@stubbable` interface, `buildImports` must return the original import list
// unchanged — not inject a second `import Std.Testing.Mocking`.  Without the
// guard a file would compile with a duplicate import and fail at type-check.
test "no duplicate import when Mocking already present (#3014)" {
  val src = "package P\n" + "import Std.Testing.Mocking\n" +
    "@stubbable\npub interface Logger {\n  func log(msg: in String): Unit\n}\n"
  val pr = parse(src)
  val rewritten = stubbableRewriteFile(pr.file)
  // Count how many imports in the rewritten file match `Std.Testing.Mocking`.
  var mockingCount = 0
  var i = 0
  while i < rewritten.imports.count {
    val imp = rewritten.imports[i]
    // The import path segments are ["Std", "Testing", "Mocking"].
    if imp.path.segments.count == 3 {
      val s0 = imp.path.segments[0]
      val s1 = imp.path.segments[1]
      val s2 = imp.path.segments[2]
      if s0 == "Std" and s1 == "Testing" and s2 == "Mocking" {
        mockingCount = mockingCount + 1
      }
    }
    i = i + 1
  }
  assertEqualInt(mockingCount, 1, "exactly one Std.Testing.Mocking import after rewrite (no duplicate)")
}
