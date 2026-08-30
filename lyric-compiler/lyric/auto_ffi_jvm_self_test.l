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
//!
//! The `#6662` instance-method / constructor overload-scoring tests near the
//! end of this file additionally require a small fixture jar on
//! LYRIC_FFI_JARS at compile time — build it with
//! `scripts/ci/build-auto-ffi-fixture.sh` (see that test's header comment).
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

// ── Interface-typed receivers dispatch via invokeinterface (docs/59 §4) ──────
//
// `Collections.emptyList()` / `singletonList(Object)` are static methods on a
// CLASS whose declared return type is the INTERFACE `java.util.List`, so the
// receiver's static type at the chained instance call is an interface.
// `ClassInfo.isInterface` is parsed from the JDK metadata; before this fix it
// was never consulted and instance auto-FFI unconditionally emitted
// `invokevirtual java/util/List.size()` — an IncompatibleClassChangeError at
// run time.  The fix selects `invokeinterface` (with its count operand) when
// the resolved owner is an interface.
extern type JCollections = "java.util.Collections"

test "instance calls through a JDK interface-typed receiver use invokeinterface" {
  val empty = JCollections.emptyList()
  assertEqualInt(empty.size(), 0, "emptyList().size() == 0")
  assertTrue(empty.isEmpty(), "emptyList().isEmpty()")
  val one = JCollections.singletonList("x")
  assertEqualInt(one.size(), 1, "singletonList(\"x\").size() == 1")
  assertTrue(not one.isEmpty(), "singletonList(\"x\") is not empty")
}

// ── Static methods DECLARED on a JDK interface (#5521) ───────────────────────
//
// `List.of(...)` / `Map.of(...)` are `static` methods declared directly on
// the INTERFACE (`java.util.List` / `java.util.Map`), not on some concrete
// class returning the interface type (contrast `JCollections.emptyList()`
// above, where the interface only shows up as the return type).
// `lowerAutoFfiStaticCall` always emitted a plain `invokestatic` serialized
// as `CONSTANT_Methodref` regardless of the owner's kind; the JVM rejects
// that at link time when the owner is actually an interface
// (`IncompatibleClassChangeError`) because a static interface method needs
// `CONSTANT_InterfaceMethodref` (same `invokestatic` opcode, different
// constant-pool tag).  The fix consults `ClassInfo.isInterface` at the
// static-call site too and routes to `LInvokestaticIface`.
// (`Map.entry(...)` — the other JDK-interface-static-method example this bug
// class is normally described with — hits an unrelated, pre-existing parser
// gap: `entry` is only a CONTEXTUAL keyword in binding/statement position
// (`contextualIdentKeyword`, D093), not yet after `.` in member-access
// position, so `JMap.entry(...)` fails to parse with "expected an identifier
// after '.'" independent of auto-FFI. `Map.of(...)` exercises the identical
// static-interface-method codegen path without that unrelated gap.)
extern type JList = "java.util.List"

extern type JMap = "java.util.Map"

test "static methods declared on a JDK interface resolve via invokestatic/InterfaceMethodref" {
  val xs = JList.of(1, 2, 3)
  assertEqualInt(xs.size(), 3, "List.of(1,2,3).size() == 3")
  assertTrue(not xs.isEmpty(), "List.of(1,2,3) is not empty")

  val m = JMap.of("k", 42)
  assertEqualInt(m.size(), 1, "Map.of(\"k\", 42).size() == 1")
  assertEqualInt(m.get("k"), 42, "Map.of(\"k\", 42).get(\"k\") == 42")
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

// #5373: extend the primitive-array coverage above (char[]/byte[] only)
// to two more of PR #5370's generalized 8 primitive element types: int[]
// and double[]. `Arrays.copyOf` exercises the return-side box (a real JDK
// method producing a raw primitive array, both tail-expression and explicit
// `return` forms); `Arrays.toString` exercises the argument-side unbox for
// both a returned array and a bare Lyric slice literal never touched by JDK
// code.
extern type JArrays = "java.util.Arrays"

func copyOfIntsTail(src: in slice[Int], newLen: in Int): slice[Int] {
  JArrays.copyOf(src, newLen)
}

func copyOfIntsExplicit(src: in slice[Int], newLen: in Int): slice[Int] {
  return JArrays.copyOf(src, newLen)
}

// #5526: a growing `Arrays.copyOf` call used to leave its newly-grown
// padding slots as `null` instead of boxed zero (`Arrays.toString` printed
// `[1, 2, 3, null, null]` instead of `[1, 2, 3, 0, 0]`), on BOTH the
// tail-expression and explicit-`return` forms equally — not a tail-vs-
// explicit asymmetry. Root cause: every `slice[T]` erases uniformly to
// `[Ljava/lang/Object;` on the JVM, and `Arrays.copyOf`'s overload set has
// both `int[] copyOf(int[], int)` and the generic `<T> T[] copyOf(T[], int)`
// (itself erased to `[Ljava/lang/Object;`) — scoring the argument's erased
// descriptor against candidate overloads let the generic overload win as an
// "exact match", so the call silently returned a boxed `Object[]` (whose
// freshly-grown slots default to `null`, correct behavior for THAT
// overload) instead of dispatching to the primitive overload
// `emitFfiCoerce`'s `[Ljava/lang/Object; -> primitive[]` argument
// conversion was designed to feed. Fixed by scoring auto-FFI overloads
// against the argument's TRUE declared Lyric element type (from the same
// `indexedElemTypeOverride` declared-type registry `EIndex` narrowing
// already consults) when it resolves to a primitive, rather than the
// argument's erased runtime descriptor alone.
func growIntsTail(src: in slice[Int], newLen: in Int): slice[Int] {
  JArrays.copyOf(src, newLen)
}

func growIntsExplicit(src: in slice[Int], newLen: in Int): slice[Int] {
  return JArrays.copyOf(src, newLen)
}

test "Arrays.copyOf(int[],int) GROWN tail-expression return zero-pads new slots" {
  val src: slice[Int] = [1, 2, 3]
  val grown = growIntsTail(src, 5)
  assertEqualInt(grown.count, 5, "copyOf(int[],5) grows to newLen")
  assertEqualInt(grown[0], 1, "element 0 preserved")
  assertEqualInt(grown[1], 2, "element 1 preserved")
  assertEqualInt(grown[2], 3, "element 2 preserved")
  assertEqualInt(grown[3], 0, "grown element 3 is boxed zero, not null")
  assertEqualInt(grown[4], 0, "grown element 4 is boxed zero, not null")
  val s = JArrays.toString(grown)
  assertEqual(s, "[1, 2, 3, 0, 0]", "copyOf growth round-trips through Arrays.toString(int[])")
}

test "Arrays.copyOf(int[],int) GROWN explicit return zero-pads new slots" {
  val src: slice[Int] = [4, 5]
  val grown = growIntsExplicit(src, 4)
  assertEqualInt(grown.count, 4, "copyOf(int[],4) grows to newLen")
  assertEqualInt(grown[2], 0, "grown element 2 is boxed zero, not null")
  assertEqualInt(grown[3], 0, "grown element 3 is boxed zero, not null")
  val s = JArrays.toString(grown)
  assertEqual(s, "[4, 5, 0, 0]", "copyOf growth round-trips through Arrays.toString(int[])")
}

// Truncating/same-length copyOf, not growing — kept as its own coverage
// (the return-side coercion, independent of the growth-padding case above).
test "Arrays.copyOf(int[],int) tail-expression return coerces to slice[Int]" {
  val src: slice[Int] = [1, 2, 3]
  val copied = copyOfIntsTail(src, 2)
  assertEqualInt(copied.count, 2, "copyOf(int[],2) truncates to newLen")
  val s = JArrays.toString(copied)
  assertEqual(s, "[1, 2]", "copyOf truncation round-trips through Arrays.toString(int[])")
}

test "Arrays.copyOf(int[],int) explicit return coerces to slice[Int]" {
  val src: slice[Int] = [4, 5]
  val copied = copyOfIntsExplicit(src, 2)
  assertEqualInt(copied.count, 2, "copyOf(int[],2) same length")
  val s = JArrays.toString(copied)
  assertEqual(s, "[4, 5]", "copyOf(int[],2) round-trips through Arrays.toString(int[])")
}

test "slice[Int] literal argument unboxes to a real JDK int[] — Arrays.toString(int[])" {
  val nums: slice[Int] = [7, 8, 9]
  val s = JArrays.toString(nums)
  assertEqual(s, "[7, 8, 9]", "Arrays.toString(int[]) built from a Lyric slice[Int] literal")
}

func copyOfDoublesTail(src: in slice[Double], newLen: in Int): slice[Double] {
  JArrays.copyOf(src, newLen)
}

func copyOfDoublesExplicit(src: in slice[Double], newLen: in Int): slice[Double] {
  return JArrays.copyOf(src, newLen)
}

// See the int[] tail-expression test above for why this stays non-growing
// (the same null-padding bug reproduces for double[]).
test "Arrays.copyOf(double[],int) tail-expression return coerces to slice[Double]" {
  val src: slice[Double] = [1.5, 2.5]
  val copied = copyOfDoublesTail(src, 1)
  assertEqualInt(copied.count, 1, "copyOf(double[],1) truncates to newLen")
  val s = JArrays.toString(copied)
  assertEqual(s, "[1.5]", "copyOf truncation round-trips through Arrays.toString(double[])")
}

test "Arrays.copyOf(double[],int) explicit return coerces to slice[Double]" {
  val src: slice[Double] = [3.5]
  val copied = copyOfDoublesExplicit(src, 1)
  assertEqualInt(copied.count, 1, "copyOf(double[],1) same length")
  val s = JArrays.toString(copied)
  assertEqual(s, "[3.5]", "copyOf(double[],1) round-trips through Arrays.toString(double[])")
}

test "slice[Double] literal argument unboxes to a real JDK double[] — Arrays.toString(double[])" {
  val nums: slice[Double] = [1.1, 2.2]
  val s = JArrays.toString(nums)
  assertEqual(s, "[1.1, 2.2]", "Arrays.toString(double[]) built from a Lyric slice[Double] literal")
}

// ── Enum class metadata ──────────────────────────────────────────────────────
//
// Before the Jvm.ClassReader fix that stopped skipping ACC_ENUM class files,
// an enum extern type was unresolvable end-to-end: the constant read
// (`JRoundingMode.HALF_EVEN`) fell through the static-field path to the
// "resolves to no local, parameter, …" codegen panic, and enum-typed
// overloads (`BigDecimal.setScale(int, RoundingMode)`) could not be scored.
// This is what kept the rewritten `_kernel_jvm/format_host.l` (and any user
// FFI against JDK enums) from compiling.
extern type JBigDecimal = "java.math.BigDecimal"

extern type JRoundingMode = "java.math.RoundingMode"

test "enum constant read + enum-typed overload resolve from JDK metadata" {
  val mode = JRoundingMode.HALF_EVEN
  val bd = JBigDecimal.new(0.125)
  val scaled = bd.setScale(2, mode)
  assertEqual(scaled.toPlainString(), "0.12", "setScale(2, HALF_EVEN) over exact 0.125")
}

test "enum instance method resolves through the java.lang.Enum superclass walk" {
  val mode = JRoundingMode.HALF_UP
  assertEqual(mode.name(), "HALF_UP", "Enum.name() on an enum constant")
}

// ── Lambda → functional-interface (SAM) bridging at auto-FFI boundaries ──────
//
// A Lyric lambda lowers to a closure class implementing the package's shared
// `Lyric$Lambda` interface (`invoke(Object[])Object`).  Passing one to a JDK
// method whose parameter is a functional interface (`Runnable`, `Comparator`,
// `Function`, `Consumer`, …) previously either failed overload resolution or
// emitted bytecode the JVM verifier rejects (the raw closure object where the
// nominal interface is expected).  With SAM bridging: the overload scorer
// recognizes a lambda argument as assignable to exactly the
// functional-interface parameters (`Jvm.AutoFfi.findSamMethod`), and
// `emitFfiCoerce` wraps the closure in a synthesized per-interface adapter
// class whose SAM method adapts typed params/return to the boxed
// `invoke(Object[])Object` calling convention.
extern type JThread = "java.lang.Thread"

extern type JHashMap = "java.util.HashMap"

test "Runnable: zero-arg void lambda capturing a var, via Thread(Runnable)" {
  // Thread declares both Thread(Runnable) and Thread(String): the lambda
  // argument must score as assignable to the functional interface and NOT to
  // String, selecting Thread(Runnable) deterministically.
  var ran = 0
  val r = { -> ran = ran + 1 }
  val t = JThread.new(r)
  t.start()
  t.join()
  assertEqualInt(ran, 1, "Runnable lambda ran exactly once on the spawned thread")
}

// #6552: `r` above has no type ANNOTATION, so its slot type comes straight
// from the `ELambda`'s own JvmType (the package's `Lyric$Lambda` interface)
// and always matched `emitFfiCoerce`'s SAM-wrap condition. A `val` declared
// WITH an explicit function-type annotation instead resolved its slot type
// through the general `typeExprToJvm`/`typeExprToJvmExtern` erasure, whose
// `TFunction` arm collapses to `Ljava/lang/Object;` — a descriptor
// `emitFfiCoerce` doesn't recognize as SAM-bridgeable, so the raw
// `Lyric$Lambda`-implementing object was passed directly where `Runnable`
// was expected, surfacing as `IncompatibleClassChangeError` at the JDK's
// first `run()` dispatch on the spawned thread (not a compile-time or
// class-verification failure — the class loads fine, unlike #6551).
test "Runnable: annotated val bound to a lambda, then passed by name (#6552)" {
  var ran = 0
  val action: () -> Unit = { -> ran = ran + 1 }
  val t = JThread.new(action)
  t.start()
  t.join()
  assertEqualInt(ran, 1, "annotated val-bound Runnable lambda ran exactly once on the spawned thread")
}

test "Runnable: inline lambda literal argument" {
  var hits = 0
  val t = JThread.new({ -> hits = hits + 10 })
  t.start()
  t.join()
  assertEqualInt(hits, 10, "inline Runnable lambda literal ran")
}

test "Comparator: two-arg int-returning lambda through Arrays.sort(T[], Comparator)" {
  val words: slice[String] = ["bb", "a", "ccc"]
  // Sort by descending length so the result proves the comparator body ran
  // (natural order would yield ["a", "bb", "ccc"]).
  JArrays.sort(words, { a: String, b: String -> b.length - a.length })
  assertEqual(words[0], "ccc", "longest word first")
  assertEqual(words[1], "bb", "middle word second")
  assertEqual(words[2], "a", "shortest word last")
}

test "Function: value-returning single-arg lambda through Map.computeIfAbsent" {
  val m = JHashMap.new()
  val len = m.computeIfAbsent("answer", { k: String -> k.length })
  assertEqualInt(len, 6, "computeIfAbsent invoked the mapping lambda")
  assertEqualInt(m.size(), 1, "mapped value was stored")
}

test "Function: lambda capturing a local, through Map.computeIfAbsent" {
  val suffix = "!"
  val m = JHashMap.new()
  val v = m.computeIfAbsent("x", { k: String -> k + suffix })
  assertEqual(v, "x!", "capturing Function lambda produced key + captured suffix")
}

test "Consumer: reference-arg void-return lambda through ArrayList.forEach" {
  // The Consumer shape (one reference parameter, void return) is the same SAM
  // shape as com.sun.net.httpserver.HttpHandler.handle(HttpExchange) — the
  // form the _kernel_jvm http kernels need — exercisable network-free here.
  val items = JArrayList.new()
  items.add("alpha")
  items.add("beta")
  var seen = 0
  var joined = ""
  items.forEach({ x: String -> seen = seen + 1; joined = joined + x })
  assertEqualInt(seen, 2, "Consumer lambda visited every element")
  assertEqual(joined, "alphabeta", "Consumer lambda observed element values in order")
}

// ── slice[T] indexing where T is a registered extern alias of Object (#6016) ─
//
// `sameTypeExprElemFallback` (jvm/codegen/02_exprs.l) assumed that any bare
// type name whose resolved JVM type is `java/lang/Object` must be an
// unregistered same-package interface, and guessed `<pkg>/<name>` for the
// indexed element's checkcast target. That guess is wrong when `<name>` is
// instead a REGISTERED extern type genuinely aliased to `java.lang.Object`
// (`extern type JObject = "java.lang.Object"`, the `lyric-web`
// `AllTrustingHandler.invoke(args: in slice[JObject])` shape) — the checkcast
// then targets a class that does not exist, and indexing throws
// `NoClassDefFoundError` at runtime. The fix checks `ctx.externTypes` first
// and leaves a registered extern type's resolution unchanged.
extern type JObject = "java.lang.Object"

func firstObjectToString(xs: in slice[JObject]): String {
  xs[0].toString()
}

test "slice[JObject] parameter: indexed element resolves through the real java.lang.Object (#6016)" {
  val o = JObject.new()
  val xs: slice[JObject] = [o]
  assertTrue(
    firstObjectToString(xs).startsWith("java.lang.Object@"),
    "xs[0].toString() resolves via java.lang.Object, not a NoClassDefFoundError same-package guess"
  )
}

// ── `for`-loop over an EXTERN generic collection types the loop variable as
// the real element type, not Object (#6565) ──────────────────────────────
//
// `extern type JHttpStringCollection[T] = "java.util.Collection"` in
// `lyric-web/src/_kernel/jvm/web_kernel.l`'s `headerNamesOf` is the
// phantom-type-param idiom: the real runtime type is
// `java.util.Collection<HttpString>`, but Lyric's `extern type` grammar has
// no way to spell a fixed JVM generic argument, so the declaration carries a
// Lyric-only type parameter `T` that the AUTHOR instantiates at each call
// site (mirroring `Std.CollectionsHost`'s `MapKeyCollection[K,V]` /
// `MapValueCollection[K,V]`).  Before this fix, `Lyric.TypeChecker`'s
// `SFor` element-type resolution (`typechecker_stmts.l`) only recognized
// the literal name `List` for a single-type-parameter generic — every other
// single-param generic, extern or not, fell through to `TyError`, so the
// loop variable's static type erased to `Object`.  A JVM auto-FFI method
// call on that untyped variable then resolved against `java.lang.Object`
// instead of the real element type and failed to compile
// ("no matching instance or inherited method for 'java.lang.Object.<m>()'")
// — exactly the failure that broke `lyric build --manifest
// lyric-web/lyric.toml --target jvm` end to end.
extern type JCollectionOfString[T] = "java.util.Collection"

// Mirrors `headerNamesOf`: an auto-FFI call (`HashMap.values()`, a real JDK
// method returning `java.util.Collection<V>`) whose result is trusted into
// the declared phantom-generic return type.
func stringValuesOf(m: in JHashMap): JCollectionOfString[JString] {
  m.values()
}

test "for-loop over an extern generic collection types the loop variable as the collection's real element type, not Object (#6565)" {
  val m = JHashMap.new()
  m.put("a", "Alpha")
  m.put("b", "Beta")
  var loweredLen = 0
  for v in stringValuesOf(m) {
    // `v` must be statically typed `JString` (not `Object`) for BOTH of
    // these to resolve: `.toString()` is a JVM auto-FFI instance call on
    // `v` itself, and `.toLower()` is a Lyric stdlib extension method
    // (`Std.String.toLower(s: in String)`) that only exists for `String` —
    // the exact two-hop shape `Web.Kernel.Runtime.buildRequestHeaders` uses
    // (`name.toString().toLower()`).
    val lowered = v.toString().toLower()
    loweredLen = loweredLen + lowered.length
  }
  assertEqualInt(loweredLen, 9, "\"alpha\".length (5) + \"beta\".length (4) == 9")
}

// ── #6662: instance-method / constructor overload scoring (Arrays.copyOf's
// static-call fix extended to the other two auto-FFI call shapes) ───────────
//
// The #5526 fix (`ffiScoreDescFor`, jvm/codegen/04_calls.l) scores auto-FFI
// overloads against a `slice[T]` argument's TRUE declared Lyric element type
// rather than its erased `[Ljava/lang/Object;` runtime descriptor, so a
// primitive-array overload (`int[]`) is no longer shadowed by a sibling
// `Object[]`/generic-array overload that always "exact matches" the erased
// descriptor. That fix originally wired `ffiScoreDescFor` into
// `lowerAutoFfiStaticCall` only (`Arrays.copyOf` above) — the identical bug
// was independently reachable through `lowerAutoFfiInstanceCall` and
// `lowerAutoFfiConstructorCall`, which built their own argDescs and never
// consulted the scoring hint.
//
// The JDK ships no INSTANCE method or CONSTRUCTOR pairing an `int[]`
// overload against an `Object[]` overload on the same name (every such pair
// in the JDK — `Arrays.copyOf`, `Arrays.hashCode`, … — is a STATIC utility,
// already covered above), so this exercises the fix against a small fixture
// class built for exactly this shape:
// lyric-compiler/jvm/testdata/AutoFfiOverloadFixture.java, whose constructor
// and `sumInts` instance method both offer an `int[]` overload beside an
// `Object[]` overload. `kind()`/a `-1` sentinel prove which overload actually
// ran, not just that SOME overload ran.
//
// Requires the fixture jar on LYRIC_FFI_JARS at compile time (the CI step
// "Auto-FFI metadata self-test on JVM" builds it via
// scripts/ci/build-auto-ffi-fixture.sh). To run locally:
//   jar_path="$(bash scripts/ci/build-auto-ffi-fixture.sh)"
//   LYRIC_FFI_JARS="$jar_path" ./bin/lyric test --target jvm \
//     lyric-compiler/lyric/auto_ffi_jvm_self_test.l
extern type OverloadFixture = "lyric.autoffi.fixture.AutoFfiOverloadFixture"

test "constructor overload scoring: slice[Int] argument picks the int[] overload, not Object[] (#6662)" {
  val values: slice[Int] = [1, 2, 3, 4]
  val f = OverloadFixture.new(values)
  assertEqual(f.kind(), "primitive", "OverloadFixture.new(slice[Int]) resolved the int[] constructor")
  assertEqualInt(f.sum(), 10, "int[] constructor computed the real sum, not the Object[] overload's -1 sentinel")
}

test "instance-method overload scoring: slice[Int] argument picks the int[] overload, not Object[] (#6662)" {
  val values: slice[Int] = [5, 6, 7]
  val f = OverloadFixture.new(values)
  val total = f.sumInts(values)
  assertEqualInt(total, 18, "sumInts(slice[Int]) resolved the int[] overload, not the Object[] overload's -1 sentinel")
}

// ── #6696: reverse compatibility for genuinely Object[]-only overloads ──────
//
// `ffiScoreDescFor` (#6662/#5526, above) narrows a `slice[T]` argument's
// SCORE-ONLY descriptor to a primitive-array shape (`[I`, …) when `T` is a
// JVM primitive, so a sibling primitive-array overload outscores a same-named
// `Object[]`-erased generic overload. Some JDK methods declare `Object[]` —
// including a `T...` varargs parameter's erasure — as their ONLY candidate:
// `Arrays.asList(T... a)`, `Objects.hash(Object... values)`,
// `String.format(String, Object...)`. Before the #6696 fix to
// `scoreParamMatch` (`lyric-compiler/jvm/auto_ffi.l`), the narrowed
// primitive-array descriptor matched no parameter on any of these (no rule
// scored a primitive-array argDesc against an `Object[]` paramDesc), so
// `findBestMethod` returned `None` and the call PANICKED AT COMPILE TIME
// instead of resolving to the one overload that always worked before #6662.
// The fix's reverse-compatibility rule recovers this — a Lyric slice's
// runtime representation is ALWAYS `Object[]` (boxed elements) regardless of
// its declared element type — while staying strictly lower-priority than an
// exact primitive-array match, so `OverloadFixture`'s `int[]`-vs-`Object[]`
// disambiguation two tests above is unaffected.
extern type JObjects = "java.util.Objects"

test "Arrays.asList(slice[Int]) resolves the Object[]-only varargs overload (#6696)" {
  val values: slice[Int] = [10, 20, 30]
  val xs = JArrays.asList(values)
  assertEqualInt(xs.size(), 3, "Arrays.asList(slice[Int]).size() == 3")
  assertEqualInt(xs.get(0), 10, "Arrays.asList(slice[Int]).get(0) == 10")
  assertEqualInt(xs.get(2), 30, "Arrays.asList(slice[Int]).get(2) == 30")
}

test "Objects.hash(slice[Int]) resolves the Object[]-only varargs overload (#6696)" {
  val values: slice[Int] = [1, 2, 3]
  // Objects.hash delegates to Arrays.hashCode: result = 1; result = 31*result
  // + boxed-Integer.hashCode() per element -- 31*(31*(31*1+1)+2)+3 == 30817.
  assertEqualInt(JObjects.hash(values), 30817, "Objects.hash(1,2,3) matches Arrays.hashCode's boxed-Integer formula")
}

test "String.format(String, slice[Int]) resolves the Object[]-only varargs overload (#6696)" {
  val values: slice[Int] = [7, 9]
  val s = JString.format("%d and %d", values)
  assertEqual(s, "7 and 9", "String.format with a slice[Int] varargs argument")
}

// ── #6745: reverse-compat arm must not fire for a GENUINE primitive array ──
//
// `scoreParamMatch`'s reverse-compatibility arm (above, #6696) is only valid
// when the argument's descriptor is a SCORE-ONLY narrowing of an actually
// `[Ljava/lang/Object;`-erased `slice[T]` — `emitFfiCoerce` can then safely
// skip coercion, since the real value on the stack already IS an `Object[]`.
// It is NOT valid for a genuinely primitive-array-typed argument: `grown`
// below has REAL JVM storage type `int[]` (`Arrays.copyOf`'s actual resolved
// return type, never re-erased back to `Object[]`), so passing it to an
// `Object[]`-only overload has no correct coercion (`emitFfiCoerce` has no
// rule to box a real primitive array element-by-element into a fresh
// `Object[]`) — before the #6745 fix, the ungated arm still scored this a
// "match" with no coercion emitted, corrupting the emitted bytecode with a
// real `int[]` reference where `Object[]` is expected: `VerifyError` at
// class load.  After the fix this correctly refuses to resolve any overload
// at all — asserted as a `lyric build --target jvm` failure in ci.yml's
// "Genuine primitive-array argument rejected for an Object[]-only overload
// on JVM" step (a compile-time panic inside the compiler process itself is
// not expressible as a `@test_module` runtime assertion).  This test instead
// pins the POSITIVE half: `grown`'s real `int[]` continues to resolve
// correctly against overloads that actually declare `int[]` (unaffected by
// gating the reverse arm, since an exact match always short-circuits before
// that arm is ever reached).
test "genuine primitive array (Arrays.copyOf's real int[] return) still resolves exact primitive overloads (#6745)" {
  val src: slice[Int] = [4, 5, 6]
  val grown = JArrays.copyOf(src, 3)
  // Arrays.hashCode(int[]): r=1; r=31*r+4=35; r=31*r+5=1090; r=31*r+6=33796.
  assertEqualInt(
    JArrays.hashCode(grown),
    33796,
    "Arrays.hashCode(int[]) resolves the exact int[] overload for a genuinely-real primitive array"
  )
  val s = JArrays.toString(grown)
  assertEqual(
    s,
    "[4, 5, 6]",
    "Arrays.toString(int[]) resolves the exact int[] overload for a genuinely-real primitive array"
  )
}

// ── #6745: F0015-J emits the RESOLVED descriptor, not the declared one ─────
//
// `Objects.toString(Object)` is the JDK's ONLY one-argument overload — no
// `Objects.toString(String)` exists.  Declaring this `@externTarget` with a
// Lyric `String` parameter makes `findBestMethod`'s scoring resolve it via
// the reference-widening arm (`String IS-A Object`), which VALIDATES the
// declared signature (F0015-J passes) without the declared descriptor
// (`Ljava/lang/String;`) equaling the resolved one (`Ljava/lang/Object;`).
// Before the #6745 fix, `lowerExternTargetBody` emitted the invoke against
// the DECLARED descriptor regardless — encoding
// `invokestatic java/util/Objects.toString(Ljava/lang/String;)Ljava/lang/String;`,
// a `<clinit>`/method reference `java.util.Objects` does not actually have
// (only `toString(Ljava/lang/Object;)` and the two-arg overload exist),
// which fails at runtime with `NoSuchMethodError`/`VerifyError` despite
// F0015-J having reported the signature "verified".  After the fix, the
// invoke is emitted against the RESOLVED `(Ljava/lang/Object;)` descriptor
// (a `String` argument reference is verifier-compatible with an `Object`
// parameter slot with no coercion needed), so this now actually runs.
@externTarget("java.util.Objects.toString")
func Objects_toStringOfString(x: in String): String = ()

test "F0015-J emits the resolved descriptor for a reference-widened @externTarget signature (#6745)" {
  assertEqual(
    Objects_toStringOfString("hello"),
    "hello",
    "Objects.toString(String) resolves against the real Object-typed overload"
  )
}
