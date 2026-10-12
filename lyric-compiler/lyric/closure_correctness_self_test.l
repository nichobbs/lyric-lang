//! closure_correctness_self_test.l — regression tests for two CRITICAL closure
//! correctness fixes:
//!
//!   1. Multi-level nested closure capture (#1479): a lambda inside a lambda
//!      can now read names captured by the outer lambda.  Previously the inner
//!      lambda's `lambdaCaptureNamesMsil` only inspected `fctx.slots` (the
//!      enclosing lambda's *own* locals) and silently ignored names that were
//!      accessible only via `fctx.captureNameToIndex` (the outer lambda's own
//!      captured set).  This led to silent wrong-value reads or runtime panics.
//!
//!   2. Lambdas in @test_module bodies (#1854): `assertPanics` / `assertPanicsWith`
//!      receive a `() -> Unit` lambda.  The self-hosted MSIL emitter was calling
//!      `assertPanics(String, Object)` but the F#-built `Std.Testing` DLL declares
//!      `assertPanics(String, System.Action)`.  The fix corrects
//!      `typeExprToMsilCtx` to map `TFunction([], TUnit)` → `MClass("System.Action")`
//!      so the MemberRef signature matches the F#-compiled method.
//!
//!   3. A lambda's own parameter captured by an inner lambda (#8317): on dotnet
//!      the parameter arrives boxed under the uniform `Func` ABI and was stored
//!      into the inner closure's typed field without being unboxed, so a
//!      curried `{ a: Int -> { b: Int -> a + b } }` read the object reference
//!      as an `Int`.
//!
//! Run with:
//!   lyric test --target dotnet lyric-compiler/lyric/closure_correctness_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/closure_correctness_self_test.l
//!   lyric test --target native lyric-compiler/lyric/closure_correctness_self_test.l
//!
//! The cases that call a lambda writing a captured `var` are not run on
//! native, whose closures capture a variable's value (#7891), nor are the
//! `assertPanics` cases (native has no unwinding, D-N-003).
//! `scripts/ilverify-selfhosted.sh` verifies the dotnet test DLL.  Imports
//! only `Std.*`.
@test_module
package ClosureCorrectnessTest

import Std.Core
import Std.Testing

// ─── #1479 multi-level closure capture ──────────────────────────────────────
test "two-level immutable capture" {
  val x = 42
  val outer = { -> val inner = { -> x }; inner() }
  assertEqualInt(outer(), 42, "two-level immutable capture")
}

test "three-level immutable capture" {
  val y = 100
  val f1 = { -> val f2 = { -> val f3 = { -> y }; f3() }; f2() }
  assertEqualInt(f1(), 100, "three-level immutable capture")
}

test "inner closure uses outer closure captured name twice" {
  val base = 7
  val adder = { -> val doubler = { -> base + base }; doubler() }
  assertEqualInt(adder(), 14, "captured name used twice in inner body")
}

@cfg(not(target = "native"))
test "nested closure captures mutable (cell) from outer scope" {
  var counter = 0
  val inc = { -> val check = { -> counter }; counter = counter + 1; check() }
  val afterFirst = inc()
  val _ = inc()
  assertEqualInt(afterFirst, 1, "mutable cell: value after first increment")
  assertEqualInt(counter, 2, "mutable cell: outer counter updated")
}

test "multiple distinct captured values at two levels" {
  val a = 3
  val b = 5
  val outer = { -> val inner = { -> a + b }; inner() }
  assertEqualInt(outer(), 8, "two distinct captured values")
}

// ─── #1854 lambdas in @test_module (#1877 uniform ABI) ──────────────────────
@cfg(not(target = "native"))
test "assertPanics compiles and runs in test_module" {
  assertPanics("explicit panic", { -> panic("expected") })
}

@cfg(not(target = "native"))
test "assertPanicsWith compiles and runs in test_module" {
  assertPanicsWith("panic with substring", "expected", { -> panic("expected panic message") })
}

@cfg(not(target = "native"))
test "assertPanics fails when fn does not panic" {
  val didFail = try {
    assertPanics("should fail", { -> () })
    false
  } catch Bug as _ {
    true
  }
  assertTrue(didFail, "assertPanics should itself panic when fn is normal")
}

// ─── Calling a captured function value inside a lambda ──────────────────────
// On --target dotnet a call THROUGH a function value that the lambda body
// captured (rather than a local/param slot of the body itself) fell through
// to static function resolution and failed the build with T0123
// "unresolved call to 'g'".  JVM always handled it.
func composeCaptured(outer: in (Int) -> Int, inner: in (String) -> Int): (String) -> Int {
  return { s: String -> outer(inner(s)) }
}

func applyTwiceCaptured(f: in (Int) -> Int): (Int) -> Int {
  val once: (Int) -> Int = { x: Int -> f(x) }
  return { x: Int -> once(once(x)) }
}

func composeGeneric[A](outer: in (A) -> Int, inner: in (String) -> A): (String) -> Int {
  return { s: String -> outer(inner(s)) }
}

func forEachCaptured(xs: in List[Int], sink: in (Int) -> Unit): () -> Unit {
  return { -> for x in xs { sink(x) } }
}

test "lambda calls a captured function parameter" {
  val h = composeCaptured({ x: Int -> x * 10 }, { s: String -> s.length })
  assertEqualInt(h("abcd"), 40, "outer(inner(s))")
}

test "lambda calls a captured function-valued local" {
  val g = applyTwiceCaptured({ x: Int -> x + 3 })
  assertEqualInt(g(1), 7, "once(once(x))")
}

test "generic function's lambda calls a captured function parameter" {
  val h = composeGeneric({ n: Int -> n + 1 }, { s: String -> s.length })
  assertEqualInt(h("abc"), 4, "generic outer(inner(s))")
}

test "lambda calls a captured Unit-returning function parameter" {
  val seen: List[Int] = newList()
  val xs: List[Int] = newList()
  xs.add(2)
  xs.add(5)
  val run = forEachCaptured(xs, { x: Int -> seen.add(x) })
  run()
  assertEqualInt(seen.count, 2, "sink called for each element")
  assertEqualInt(seen[1], 5, "second element")
}

test "nested lambda calls a function captured two levels up" {
  val double: (Int) -> Int = { x: Int -> x * 2 }
  val outer = { -> val inner = { y: Int -> double(y) + 1 }; inner(20) }
  assertEqualInt(outer(), 41, "double(y) + 1 through two capture levels")
}

// ─── #8317 a lambda's own parameter captured by an inner lambda ─────────────
// On --target dotnet a lambda's parameters arrive boxed (`object`) under the
// uniform `Func` ABI.  An inner lambda capturing one stored the boxed
// reference into its closure's typed field without unboxing it, so a curried
// `{ a: Int -> { b: Int -> a + b } }` read the object pointer as an `Int`.
record CurryPoint {
  x: Int
  y: Int
}

func runCurryThunk(f: in () -> Unit): Unit {
  f()
}

func applyCurried(f: in (Int) -> (Int) -> Int, a: in Int, b: in Int): Int = f(a)(b)

test "curried Int lambda (#8317)" {
  val add: (Int) -> (Int) -> Int = { a: Int -> { b: Int -> a + b } }
  assertEqualInt(add(3)(4), 7, "add(3)(4)")
  val add3 = add(3)
  assertEqualInt(add3(10) + add3(20), 36, "a partial application reused")
}

test "an inner closure captures the enclosing lambda's parameter (#8317)" {
  val log: List[String] = newList()
  val start = { n: Int -> runCurryThunk({ -> log.add("s" + toString(n)) }) }
  start(1)
  start(-2)
  assertEqual(log[0], "s1", "first call")
  assertEqual(log[1], "s-2", "second call")
}

test "three levels of curried parameters (#8317)" {
  val f: (Int) -> (Int) -> (Int) -> Int = { a: Int -> { b: Int -> { c: Int -> a * 100 + b * 10 + c } } }
  assertEqualInt(f(1)(2)(3), 123, "f(1)(2)(3)")
  assertEqualInt(applyCurried({ a: Int -> { b: Int -> a - b } }, 9, 4), 5, "passed to a function")
}

test "curried Long, Double, Bool and String parameters (#8317)" {
  val f: (Long) -> (Double) -> (Bool) -> (String) -> String = { a: Long ->
    { b: Double -> { c: Bool -> { d: String -> toString(a) + "/" + toString(b) + "/" + toString(c) + "/" + d } } }
  }
  assertEqual(f(5000000000i64)(2.5)(true)("z"), "5000000000/2.5/true/z", "four parameter types")
  val big: (Long) -> (Long) -> Long = { a: Long -> { b: Long -> a * b } }
  assertTrue(big(3000000000i64)(3i64) == 9000000000i64, "Long arithmetic on the captured parameter")
  val half: (Double) -> (Double) -> Double = { a: Double -> { b: Double -> a / b } }
  assertTrue(half(7.0)(2.0) == 3.5, "Double arithmetic on the captured parameter")
  val both: (Bool) -> (Bool) -> Bool = { a: Bool -> { b: Bool -> a and not b } }
  assertTrue(both(true)(false), "Bool logic on the captured parameter")
}

test "a curried record parameter (#8317)" {
  val scale: (CurryPoint) -> (Int) -> Int = { p: CurryPoint -> { k: Int -> p.x * k + p.y } }
  assertEqualInt(scale(CurryPoint(x = 3, y = 1))(5), 16, "p.x * k + p.y")
}

test "curried functions in a List (#8317)" {
  val add: (Int) -> (Int) -> Int = { a: Int -> { b: Int -> a + b } }
  val adders: List[(Int) -> Int] = [add(1), add(10), add(100)]
  assertEqualInt(adders[0](5) + adders[1](5) + adders[2](5), 126, "each adder keeps its own captured parameter")
}

@cfg(not(target = "native"))
test "a captured parameter beside a mutated var (#8317)" {
  val counted: (Int) -> Int = { n: Int -> var acc = n; val bump = { -> acc = acc + n }; bump(); bump(); acc }
  assertEqualInt(counted(7), 21, "acc = n + n + n")
}

func curryLogger(log: in List[String]): (String) -> () -> Unit {
  { tag: String -> { -> log.add(tag) } }
}

test "a curried Unit-returning lambda called in place (#8317)" {
  val log: List[String] = newList()
  curryLogger(log)("a")()
  val pick = true;
  (if pick { curryLogger(log)("b") } else { curryLogger(log)("c") })()
  assertEqualInt(log.count, 2, "both calls ran")
  assertEqual(log[0] + log[1], "ab", "each call kept its own captured tag")
}
