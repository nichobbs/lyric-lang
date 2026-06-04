// lyric-compiler/lyric/auto_ffi_jvm_self_test.l
//
// @test_module covering self-hosted metadata-based auto-FFI resolution for the
// JVM target (epic #1622, Phase 3c JVM analog).  Exercises `extern type` aliases
// whose method calls are resolved from JDK .jmod metadata at compile time and
// emitted as correctly-typed `invokestatic` instead of the legacy
// `([Object…])Object` guess.
//
// Run via `lyric test --target jvm` so the self-hosted Jvm.Bridge pipeline
// (compileToJarBundled) is exercised end-to-end with `buildAutoFfiCtx()`.
//
// Manual run (from repo root, after `make lyric`):
//   ./bin/lyric test --target jvm \
//     lyric-compiler/lyric/auto_ffi_jvm_self_test.l
//
// If the JDK jmods directory is not found (JAVA_HOME unset, non-standard
// install), the auto-FFI context falls back to the Object-typed guess.
// The fallback still links at runtime for methods whose return type is
// upcast-compatible with Object, but typed arithmetic comparisons would fail.

@test_module
package Lyric.AutoFfiJvmSelfTest

import Std.Core
import Std.Testing

extern type JMath    = "java.lang.Math"
extern type JInteger = "java.lang.Integer"

// ── Math int overloads ────────────────────────────────────────────────────────

test "Math.max(int, int) returns larger value" {
  assertEqualInt(JMath.max(3, 7),   7, "max(3,7)")
  assertEqualInt(JMath.max(7, 3),   7, "max(7,3)")
  assertEqualInt(JMath.max(0, 0),   0, "max(0,0)")
  assertEqualInt(JMath.max(-5, -2), -2, "max(-5,-2)")
}

test "Math.min(int, int) returns smaller value" {
  assertEqualInt(JMath.min(3, 7),   3, "min(3,7)")
  assertEqualInt(JMath.min(7, 3),   3, "min(7,3)")
  assertEqualInt(JMath.min(0, 0),   0, "min(0,0)")
  assertEqualInt(JMath.min(-5, -2), -5, "min(-5,-2)")
}

test "Math.abs(int) returns absolute value" {
  assertEqualInt(JMath.abs(-42), 42, "abs(-42)")
  assertEqualInt(JMath.abs(42),  42, "abs(42)")
  assertEqualInt(JMath.abs(0),   0,  "abs(0)")
}

// ── Math long overloads ───────────────────────────────────────────────────────

test "Math.max(long, long) returns larger value" {
  val a: Long = 100i64
  val b: Long = 200i64
  assertEqualLong(JMath.max(a, b), 200i64, "max(100L,200L)")
  assertEqualLong(JMath.max(b, a), 200i64, "max(200L,100L)")
}

test "Math.abs(long) returns absolute value" {
  val v: Long = -99i64
  assertEqualLong(JMath.abs(v), 99i64, "abs(-99L)")
  val w: Long = 99i64
  assertEqualLong(JMath.abs(w), 99i64, "abs(99L)")
}

// ── Math double overloads ─────────────────────────────────────────────────────

test "Math.floor rounds down" {
  assertTrue(JMath.floor(3.7) == 3.0, "floor(3.7)==3.0")
  assertTrue(JMath.floor(-3.2) == -4.0, "floor(-3.2)==-4.0")
}

test "Math.ceil rounds up" {
  assertTrue(JMath.ceil(3.2) == 4.0, "ceil(3.2)==4.0")
  assertTrue(JMath.ceil(-3.7) == -3.0, "ceil(-3.7)==-3.0")
}

// ── Integer static helpers ────────────────────────────────────────────────────

test "Integer.max returns larger int" {
  assertEqualInt(JInteger.max(10, 20), 20, "Integer.max(10,20)")
  assertEqualInt(JInteger.max(20, 10), 20, "Integer.max(20,10)")
}

test "Integer.min returns smaller int" {
  assertEqualInt(JInteger.min(10, 20), 10, "Integer.min(10,20)")
  assertEqualInt(JInteger.min(20, 10), 10, "Integer.min(20,10)")
}

test "Integer.sum adds two ints" {
  assertEqualInt(JInteger.sum(5, 6), 11, "Integer.sum(5,6)")
  assertEqualInt(JInteger.sum(0, 0),  0, "Integer.sum(0,0)")
}
