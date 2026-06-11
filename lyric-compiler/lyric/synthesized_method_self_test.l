//! synthesized_method_self_test.l — regression tests for compiler-synthesized
//! named method dispatch (#1499, #1507).
//!
//! Two classes of methods previously failed with "unsupported method" at the
//! call site even though the MethodDef was correctly emitted:
//!
//!   #1499 — protected-type entry methods (Monitor-locked): `c.bump()` panicked
//!            because `addPackageTokens` counted the PMEntry row but never
//!            registered it in `methodTokens`, so `lowerMethodCallMsil` fell
//!            through to the error stub.
//!
//!   #1507 — compiler-synthesized free functions (derives): `p.equals(q)` / `p.show()`
//!            panicked because the synthesized IFuncs live in `funcTokens` (keyed
//!            `cls + "." + memberName`) while `lowerMethodCallMsil` only searched
//!            `methodTokens` (keyed `cls + "/" + memberName`).  The `==` operator
//!            worked because `BEq` has a dedicated `derivedEqualsTokenMsil` path
//!            that reads `funcTokens` directly.
//!
//! Both fixes are in `lyric-compiler/msil/codegen.l`:
//!   — `addPackageTokens` IProtected arm now registers PMEntry/PMFunc in methodTokens.
//!   — `lowerMethodCallMsil` MClass arm now falls back to funcTokens on miss.
//!
//! The JVM counterpart fix is in `lyric-compiler/jvm/codegen/04_calls.l`:
//!   — `lowerMethodCall` JRef arm now tries the free-function key `cls + "." + memberName`
//!     after the instance-method `cls + "#" + memberName` lookup misses.
//!
//! Compile and run via native `lyric test`:
//!   lyric test lyric-compiler/lyric/synthesized_method_self_test.l
//!
//! No LYRIC_LOAD_COMPILER=1 needed — imports only Std.*.
@test_module
package Lyric.SynthesizedMethodSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// §1. Protected-type entry dispatch (#1499)
// ─────────────────────────────────────────────────────────────────────────────
// A minimal counter wrapped in a protected type.  The `bump` entry is emitted
// with Monitor.Enter/Exit locking by `lowerProtectedMsil`.  Before the fix,
// calling `c.bump()` threw at runtime with "unsupported method 'bump'".

protected type Counter {
  var count: Int = 0

  entry bump(): Unit {
    count = count + 1
  }

  entry get(): Int {
    count
  }
}

test "protected entry: bump increments counter" {
  val c = Counter(count = 0)
  c.bump()
  assertEqualInt(c.get(), 1, "bump once -> count == 1")
}

test "protected entry: multiple bumps accumulate" {
  val c = Counter(count = 0)
  c.bump()
  c.bump()
  c.bump()
  assertEqualInt(c.get(), 3, "bump three times -> count == 3")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Protected-type helper func dispatch
// ─────────────────────────────────────────────────────────────────────────────
// A PMFunc (non-entry helper) registered alongside an entry.

protected type Accumulator {
  var total: Int = 0

  entry add(n: in Int): Unit {
    total = total + n
  }

  func value(): Int {
    total
  }
}

test "protected func: value() dispatches" {
  val a = Accumulator(total = 0)
  a.add(10)
  a.add(5)
  assertEqualInt(a.value(), 15, "add(10)+add(5) -> 15")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. @derive(Equals) — explicit .equals() call (#1507)
// ─────────────────────────────────────────────────────────────────────────────
// `p.equals(q)` calls the synthesized free function `Point.equals(self, other)`
// registered in funcTokens.  Before the fix it fell through to the "unsupported
// method" stub.

@derive(Equals)
record Point { x: Int; y: Int }

test "derive Equals: equals() same values" {
  val p = Point(x = 1, y = 2)
  val q = Point(x = 1, y = 2)
  assertTrue(p.equals(q), "equals: same field values -> true")
}

test "derive Equals: equals() different values" {
  val p = Point(x = 1, y = 2)
  val q = Point(x = 3, y = 4)
  assertFalse(p.equals(q), "equals: different field values -> false")
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. @derive(Show) — explicit .show() call (#1507)
// ─────────────────────────────────────────────────────────────────────────────

@derive(Show)
record Color { r: Int; g: Int; b: Int }

test "derive Show: show() returns non-empty string" {
  val c = Color(r = 255, g = 128, b = 0)
  val s = c.show()
  assertTrue(s.length > 0, "show: non-empty result for Color(255, 128, 0)")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. @derive(Equals) consistency: == agrees with .equals() (#1507)
// ─────────────────────────────────────────────────────────────────────────────

test "derive Equals: == agrees with .equals()" {
  val p = Point(x = 7, y = 9)
  val q = Point(x = 7, y = 9)
  val r = Point(x = 1, y = 2)
  assertTrue(p.equals(q), "equals: same values agrees with ==")
  assertFalse(p.equals(r), "equals: different values agrees with !=")
}
