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

// Unquoted dotted path declarations
extern type UnquotedJMath = java.lang.Math
extern type UnquotedJInteger = java.lang.Integer
extern type UnquotedMapEntry = java.util.Map.Entry

test "UnquotedJMath and UnquotedJInteger resolve and compile correctly" {
  assertEqualInt(UnquotedJMath.max(20, 50), 50, "UnquotedJMath.max(20,50)")
  assertEqualInt(UnquotedJInteger.sum(5, 6), 11, "UnquotedJInteger.sum(5,6)")
}


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

// ── Inherited java.lang.Object method resolution (M-15 part 2, #2219) ────────
//
// `findBestInstanceMethod` used to stop walking the superclass chain one
// step before `java/lang/Object`, so a method declared ONLY on `Object` and
// never overridden anywhere in a class's superclass chain (`getClass()`,
// `notify()`, `notifyAll()`, `wait()` — all `final`, so no subclass can ever
// override them) was invisible to auto-FFI instance-method resolution.
// `ArrayList` -> `AbstractList` -> `AbstractCollection` -> `Object`: none of
// the first three declare `getClass()`, so resolving it exercises the walk
// all the way to Object.  Chaining `.getName()` on the returned
// `java.lang.Class` also exercises instance auto-FFI resolution against the
// JvmType returned by a prior auto-FFI call (same chaining shape as
// `Integer.valueOf(42).intValue()` above).
test "getClass() resolves through the superclass chain to java.lang.Object (#2219)" {
  val name = JArrayList.new().getClass().getName()
  assertEqual(name, "java.util.ArrayList", "ArrayList.getClass().getName() == \"java.util.ArrayList\"")
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
// whose last path segment happens to be "List" or "Map" — including a
// package-qualified user type like `MyPkg.List[T]` — would be mis-mapped to
// `java/util/ArrayList` or `java/util/HashMap`.  At runtime, the slot declared
// as ArrayList/HashMap would hold a non-ArrayList/HashMap user instance, and the
// JVM bytecode verifier would reject the class with a VerifyError.
//
// Single-file coverage: the tests below exercise the `else → Object` path by
// using user-defined generic records whose names are not "List" or "Map".  If
// the codegen incorrectly mapped any generic to ArrayList/HashMap, the JVM
// verifier would reject the class when loading it (user records are not
// assignable to ArrayList/HashMap), failing both tests before they can run.
//
// Deferred (multi-package setup required): the `isBare` guard's primary purpose
// — preventing a package-qualified user type `Pkg.List[T]` with `segments.count
// > 1` from being mis-mapped to ArrayList — cannot be tested in a single-file
// `@test_module` because all user types in one file share a single package
// (head.segments.count == 1 for every locally-defined type).  Tracked in #3455.

record Container[T] {
  item: T
}

record Pair[A, B] {
  first: A
  second: B
}

test "single-param user generic erases to Object, not ArrayList — isBare guard (#3455)" {
  val box: Container[Int] = Container(item = 99)
  // If Container[Int] were mis-mapped to ArrayList the bytecode verifier
  // rejects the class (Container is not assignable to ArrayList).
  val sb = JStringBuilder.new("")
  sb.append(box)
  val result = sb.toString()
  assertTrue(result.length > 0, "Container[Int] accepted as Object by StringBuilder.append")
}

test "two-param user generic erases to Object, not HashMap — isBare guard Map arm (#3455)" {
  val p: Pair[Int, String] = Pair(first = 1, second = "hello")
  // If Pair[Int,String] were mis-mapped to HashMap the bytecode verifier
  // rejects the class (Pair is not assignable to HashMap).
  val sb = JStringBuilder.new("")
  sb.append(p)
  val result = sb.toString()
  assertTrue(result.length > 0, "Pair[Int,String] accepted as Object by StringBuilder.append")
}

// ── Primitive-array return/argument coercion, generalized beyond byte[] ───────
//
// Before this fix, the JVM backend's raw-primitive-array <-> erased
// `slice[T]` (`[Ljava/lang/Object;`) marshaling only handled `byte[]`, via a
// hardcoded loop, and even that byte[] path only fired for an IMPLICIT
// tail-expression return — an explicit `return` statement on ANY primitive
// array (including byte[]) skipped the coercion entirely, so the value
// crossing the function boundary didn't match its declared `[Ljava/lang/
// Object;` descriptor.  `Character.toChars(int)` (a real static JDK method
// returning `char[]`) exercises a non-byte element type through both return
// forms; `String(char[])`'s constructor exercises the mirrored argument-side
// unbox (a Lyric `slice[Char]` literal, never touched by JDK code, passed
// into a JDK API expecting a real primitive array).
extern type JCharacter = "java.lang.Character"
extern type JString = "java.lang.String"

// Tail-expression (implicit) return of a raw JDK `char[]`.
func charsOfTail(codePoint: in Int): slice[Char] {
  JCharacter.toChars(codePoint)
}

// Explicit `return` of the same raw JDK `char[]` — the path that used to
// skip the primitive-array-to-slice coercion entirely.
func charsOfExplicit(codePoint: in Int): slice[Char] {
  return JCharacter.toChars(codePoint)
}

test "Character.toChars(int) char[] tail-expression return coerces to slice[Char]" {
  val cs = charsOfTail(65)
  assertEqualInt(cs.count, 1, "toChars(65) yields one char")
  // Round-trip back through the argument-side unbox (String.copyValueOf(char[]),
  // NOT the String(char[]) constructor -- String also declares String(byte[]),
  // so a slice[Char] argument ties both overloads at equal score and is
  // correctly rejected as ambiguous by `checkPrimitiveArraySliceAmbiguity`;
  // copyValueOf has exactly one arity-1 overload, char[], so it is
  // unambiguous) rather than indexing + a Char method call, so this test
  // exercises only the return-side coercion under test, not slice-element
  // method dispatch.
  val s = JString.copyValueOf(cs)
  assertEqual(s, "A", "toChars(65) round-trips through String.copyValueOf(char[]) as \"A\"")
}

test "Character.toChars(int) char[] explicit return coerces to slice[Char]" {
  val cs = charsOfExplicit(66)
  assertEqualInt(cs.count, 1, "toChars(66) yields one char")
  val s = JString.copyValueOf(cs)
  assertEqual(s, "B", "toChars(66) round-trips through String.copyValueOf(char[]) as \"B\"")
}

test "slice[Char] literal argument unboxes to a real JDK char[] — String.copyValueOf(char[])" {
  val letters: slice[Char] = ['h', 'i']
  val s = JString.copyValueOf(letters)
  assertEqual(s, "hi", "String.copyValueOf(char[]) built from a Lyric slice[Char] literal")
}
