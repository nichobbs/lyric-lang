//! lyric-compiler/lyric/auto_ffi_jvm_self_test.l
//!
//! @test_module covering self-hosted metadata-based auto-FFI resolution for the
//! JVM target (epic #1622, Phase 3c JVM analog).  Exercises `extern type` aliases
//! whose method calls are resolved from JDK .jmod metadata at compile time and
//! emitted as correctly-typed bytecode (`invokestatic` for static methods,
//! `invokevirtual` for instance dispatch, `invokespecial <init>` for `T.new(args)`)
//! instead of the legacy `([Object…])Object` guess.
//!
//! Run via `lyric test --target jvm` so the self-hosted Jvm.Bridge pipeline
//! (compileToJarBundled) is exercised end-to-end with `buildAutoFfiCtx()`.
//!
//! Manual run (from repo root, after `make lyric`):
//!   ./bin/lyric test --target jvm \
//!     lyric-compiler/lyric/auto_ffi_jvm_self_test.l
//!
//! If the JDK jmods directory is not found (JAVA_HOME unset, non-standard
//! install), the auto-FFI context falls back to the Object-typed guess.
//! The fallback still links at runtime for methods whose return type is
//! upcast-compatible with Object, but typed arithmetic comparisons would fail.
@test_module
package Lyric.AutoFfiJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

extern type JMath = "java.lang.Math"

extern type JInteger = "java.lang.Integer"

extern type JStringBuilder = "java.lang.StringBuilder"

extern type JArrayList = "java.util.ArrayList"

// ── Math int overloads ────────────────────────────────────────────────────────
test "Math.max(int, int) returns larger value" {
  assertEqualInt(JMath.max(3, 7), 7, "max(3,7)")
  assertEqualInt(JMath.max(7, 3), 7, "max(7,3)")
  assertEqualInt(JMath.max(0, 0), 0, "max(0,0)")
  assertEqualInt(JMath.max(-5, -2), -2, "max(-5,-2)")
}

test "Math.min(int, int) returns smaller value" {
  assertEqualInt(JMath.min(3, 7), 3, "min(3,7)")
  assertEqualInt(JMath.min(7, 3), 3, "min(7,3)")
  assertEqualInt(JMath.min(0, 0), 0, "min(0,0)")
  assertEqualInt(JMath.min(-5, -2), -5, "min(-5,-2)")
}

test "Math.abs(int) returns absolute value" {
  assertEqualInt(JMath.abs(-42), 42, "abs(-42)")
  assertEqualInt(JMath.abs(42), 42, "abs(42)")
  assertEqualInt(JMath.abs(0), 0, "abs(0)")
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
  assertEqualInt(JInteger.sum(0, 0), 0, "Integer.sum(0,0)")
}

// ── Instance method dispatch ──────────────────────────────────────────────────
//
// Exercises lowerAutoFfiInstanceCall: JInteger.valueOf(n) is a static auto-FFI
// call that returns JRef("java/lang/Integer"); the subsequent .intValue() call
// is resolved as an instance method via the new instance auto-FFI path.
// The assertEqualInt wrapper constrains the return type to Int, which is how
// the type-checker accepts the chained extern call.
test "Integer.valueOf then intValue (instance method dispatch)" {
  assertEqualInt(JInteger.valueOf(42).intValue(), 42, "Integer.valueOf(42).intValue()==42")
  assertEqualInt(JInteger.valueOf(-7).intValue(), -7, "Integer.valueOf(-7).intValue()==-7")
  assertEqualInt(JInteger.valueOf(0).intValue(), 0, "Integer.valueOf(0).intValue()==0")
}

// ── Constructor binding ───────────────────────────────────────────────────────
//
// Exercises lowerAutoFfiConstructorCall: `T.new(args)` maps to the JVM
// sequence `new <class>; dup; <args>; invokespecial <init>`.  The produced
// reference is a `JRef("java/lang/StringBuilder")` so subsequent instance
// calls on the result are routed through `lowerAutoFfiInstanceCall`.
test "StringBuilder.new(String) constructor binding" {
  val sb = JStringBuilder.new("hello")
  assertEqualInt(sb.length(), 5, "length of StringBuilder(\"hello\")")
  assertEqual(sb.toString(), "hello", "toString() of StringBuilder(\"hello\")")
}

test "StringBuilder.new() no-arg constructor binding" {
  val sb = JStringBuilder.new()
  assertEqualInt(sb.length(), 0, "empty StringBuilder length")
}

// ── Verified reference assignability in overload resolution (#3409) ────────────
//
// `ArrayList` declares three constructors: `ArrayList()`, `ArrayList(int)`, and
// `ArrayList(Collection)`.  Passing a Lyric `List[String]` (a `java.util.ArrayList`
// at runtime) must select the copy constructor `ArrayList(Collection)`: the arg
// is verified IS-A `java.util.Collection` by walking ArrayList's superclass chain
// to `AbstractCollection`, which directly declares the `Collection` interface.
// The scorer ranks that verified match (4) above the blind reference fallback (1),
// and rejects `ArrayList(int)` (a reference arg never matches an `int` parameter).
test "ArrayList(Collection) copy constructor — verified reference assignability (#3409)" {
  val src: List[String] = newList()
  src.add("alpha")
  src.add("beta")
  src.add("gamma")
  val copy = JArrayList.new(src)
  assertEqualInt(copy.size(), 3, "copied ArrayList preserves element count")
}

// Phase 5 (F0015-J): @externTarget with metadata-verified signature.
// The function names follow the Maven TypeName_methodName convention so
// isStaticExternByName returns true, matching the emitted invokestatic.
@externTarget("java.lang.Math.abs")
func Math_abs(x: in Int): Int = ()

@externTarget("java.lang.Math.max")
func Math_max(a: in Int, b: in Int): Int = ()

@externTarget("java.lang.Integer.toString")
func Integer_toString(x: in Int): String = ()

test "@externTarget with verified JVM signatures compile and run correctly" {
  assertEqualInt(Math_abs(-12), 12, "Math_abs(-12)")
  assertEqualInt(Math_abs(7), 7, "Math_abs(7)")
  assertEqualInt(Math_max(3, 9), 9, "Math_max(3, 9)")
  assertEqualInt(Math_max(100, 2), 100, "Math_max(100, 2)")
  assertEqual(Integer_toString(42), "42", "Integer_toString(42)")
}

// ── isBare guard regression test (typeExprToJvm TGenericApp, #3445/#3455) ──────
//
// `typeExprToJvm` maps `TGenericApp` heads to concrete JVM types:
//   * bare `List[T]`  (head.segments.count == 1, seg == "List") → ArrayList
//   * bare `Map[K,V]` (head.segments.count == 1, seg == "Map")  → HashMap
//   * everything else                                            → Object
//
// Without the `isBare = head.segments.count == 1` guard, any generic type
// whose last path segment happens to be "List" — including a package-qualified
// user type like `MyPkg.List[T]` — would be mis-mapped to `java/util/ArrayList`.
// At runtime, the slot declared as ArrayList would hold a non-ArrayList user
// instance, and the JVM bytecode verifier would reject the class with a
// VerifyError.
//
// Testing the `MyPkg.List[T]` scenario fully requires a multi-package setup
// (the user type and this test file in separate packages).  The test below
// exercises the adjacent invariant that is testable in a single file: a
// user-defined generic record (`Container[T]`) must erase to Object, NOT to
// ArrayList.  If the codegen incorrectly mapped any generic type to ArrayList,
// the JVM verifier would reject the class when loading it, failing this test.

record Container[T] {
  item: T
}

test "user generic erases to Object, not ArrayList — isBare regression guard (#3455)" {
  val box: Container[Int] = Container(item = 99)
  // Pass `box` to StringBuilder.append(Object).  If Container[Int] were
  // mis-mapped to ArrayList, the bytecode verifier would reject the class
  // (Container is not assignable to ArrayList) before the test can run.
  val sb = JStringBuilder.new("")
  sb.append(box)
  val result = sb.toString()
  assertTrue(result.length > 0, "Container[Int] accepted as Object by StringBuilder.append")
}
