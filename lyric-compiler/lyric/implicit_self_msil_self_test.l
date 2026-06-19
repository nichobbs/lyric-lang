//! implicit_self_msil_self_test.l — @test_module for implicit self injection
//! inside record instance methods on the self-hosted MSIL backend.
//!
//! When a record method lacks an explicit first parameter named "self", the parser
//! automatically injects `self: in Self`. This test suite verifies that such methods
//! parse, typecheck, compile, and run correctly without explicit self on the MSIL
//! target, mirroring implicit_self_jvm_self_test.l.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/implicit_self_msil_self_test.l
@test_module
package Lyric.ImplicitSelfMsilSelfTest

import Std.Core
import Std.Testing

// 1. Basic record method without explicit self.
record Counter {
  n: Int
  func get(): Int {
    return self.n
  }
  func inc(): Int {
    return self.n + 1
  }
}

// 2. Record method taking arguments and combining with a field.
record Accumulator {
  base: Int
  func add(x: in Int): Int {
    return self.base + x
  }
  func fma(a: in Int, b: in Int): Int {
    return self.base + a * b
  }
}

// 3. Record method with explicit self mixed with implicit self.
record Rect {
  width: Int
  height: Int
  // Implicit self
  func area(): Int {
    return self.width * self.height
  }
  // Explicit self
  func perimeter(self: in Rect): Int {
    return 2 * (self.width + self.height)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────
test "implicit self: get field" {
  val c = Counter(n = 42)
  assertEqualInt(c.get(), 42, "Counter(42).get() == 42")
}

test "implicit self: compute field" {
  val c = Counter(n = 10)
  assertEqualInt(c.inc(), 11, "Counter(10).inc() == 11")
}

test "implicit self: add argument to field" {
  val a = Accumulator(base = 100)
  assertEqualInt(a.add(20), 120, "Accumulator(100).add(20) == 120")
}

test "implicit self: fma" {
  val a = Accumulator(base = 5)
  assertEqualInt(a.fma(6, 7), 47, "Accumulator(5).fma(6, 7) == 47")
}

test "implicit self vs explicit self" {
  val r = Rect(width = 5, height = 10)
  assertEqualInt(r.area(), 50, "Rect(5, 10).area() == 50")
  assertEqualInt(r.perimeter(), 30, "Rect(5, 10).perimeter() == 30")
}
