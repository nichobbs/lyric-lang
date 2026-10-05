//! closure_captured_var_byref_self_test.l — dual-target runtime regression
//! test for passing a closure-captured `var` as an `out`/`inout` argument
//! (#8189).
//!
//! A `var` that a closure captures is hoisted to a one-element heap cell
//! shared by the closure and the enclosing scope (docs/01 §5.4: closures
//! capture `var` bindings by reference), so the variable's slot holds the
//! cell, not the value.  The by-reference argument lowering still treated the
//! slot as the value: on `--target dotnet` it passed the address of the slot
//! holding the cell reference as an `int32&`, so the callee's write corrupted
//! memory (`AccessViolationException`); on `--target jvm` it copied the cell
//! array into a holder and stored the callee's `int` result back into the
//! slot holding the cell (`VerifyError`).  The argument now denotes the
//! cell's element: `ldelema` on dotnet, and on the JVM the cell itself is
//! passed as the callee's holder array, so the closure sees each write the
//! callee makes while the call is still running.
//!
//! Every closure-call result is bound with an explicit annotation to stay
//! clear of the unrelated MSIL unannotated-closure-result bug (#7711).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/closure_captured_var_byref_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/closure_captured_var_byref_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ClosureCapturedVarByrefSelfTest

import Std.Core
import Std.Testing

record Box {
  var n: Int
}

func setTo(x: inout Int, v: in Int): Unit {
  x = v
}

func bump(x: inout Int): Unit {
  x = x + 1
}

func produce(x: out Int, v: in Int): Unit {
  x = v
}

func setFrom(v: in Int, x: inout Int): Unit {
  x = v
}

func setLong(x: inout Long, v: in Long): Unit {
  x = v
}

func appendTo(s: inout String, suffix: in String): Unit {
  s = s + suffix
}

func replaceBox(b: inout Box, n: in Int): Unit {
  b = Box(n = n)
}

func flip(b: inout Bool): Unit {
  b = not b
}

func assignAny[T](x: inout T, v: in T): Unit {
  x = v
}

// Writes the argument, then calls `f` while the call is still running.
func setThenRead(x: inout Int, v: in Int, f: in () -> Int): Int {
  x = v
  f()
}

func okInt(v: in Int): Result[Int, String] {
  Ok(v)
}

func propagateCase(): Result[Int, String] {
  var x = 1
  val f = { -> x }
  setFrom(okInt(6)?, x)
  val seen: Int = f()
  Ok(x * 100 + seen)
}

test "inout captured Int: the closure sees the callee's write (#8189)" {
  var x = 1
  val f = { -> x }
  setTo(x, 5)
  val seen: Int = f()
  assertEqualInt(x, 5, "x after setTo")
  assertEqualInt(seen, 5, "f() after setTo")
}

test "out captured Int" {
  var x = 1
  val f = { -> x }
  produce(x, 42)
  val seen: Int = f()
  assertEqualInt(x, 42, "x after produce")
  assertEqualInt(seen, 42, "f() after produce")
}

test "inout captured Int read and written by the callee" {
  var x = 10
  val f = { -> x }
  bump(x)
  bump(x)
  val seen: Int = f()
  assertEqualInt(x, 12, "x after two bumps")
  assertEqualInt(seen, 12, "f() after two bumps")
}

test "mutation through the closure is visible before and after the call" {
  var x = 1
  val read = { -> x }
  val write = { v: Int -> x = v }
  write(2)
  val before: Int = read()
  assertEqualInt(before, 2, "f() after closure write, before the call")
  assertEqualInt(x, 2, "x after closure write, before the call")
  setTo(x, 5)
  val mid: Int = read()
  assertEqualInt(mid, 5, "f() after the call")
  write(7)
  val after: Int = read()
  assertEqualInt(after, 7, "f() after a closure write following the call")
  assertEqualInt(x, 7, "x after a closure write following the call")
}

test "two closures capturing the same var" {
  var x = 1
  val f = { -> x }
  val g = { -> x * 10 }
  setTo(x, 3)
  val a: Int = f()
  val b: Int = g()
  assertEqualInt(a, 3, "first closure")
  assertEqualInt(b, 30, "second closure")
}

test "the callee's write is visible to the closure during the call" {
  var x = 1
  val f = { -> x }
  val seen = setThenRead(x, 8, f)
  assertEqualInt(seen, 8, "closure called inside the callee")
  assertEqualInt(x, 8, "x after the call")
}

test "captured var passed by ref inside the lambda body" {
  var x = 1
  val h = { -> setTo(x, 9) }
  h()
  assertEqualInt(x, 9, "x after the lambda's by-ref call")
  val k = { -> bump(x) }
  k()
  k()
  assertEqualInt(x, 11, "x after two by-ref bumps inside a lambda")
}

test "captured var passed by ref from a nested lambda" {
  var x = 1
  val read = { -> x }
  val outer = { -> val inner = { -> setTo(x, 12) }; inner() }
  outer()
  val seen: Int = read()
  assertEqualInt(x, 12, "x after the nested lambda's by-ref call")
  assertEqualInt(seen, 12, "sibling closure after the nested call")
}

test "lambda-local var captured by a nested closure, passed by ref in the lambda" {
  val h = { -> var y = 1; val r = { -> y }; setTo(y, 4); val seen: Int = r(); y * 10 + seen }
  val got: Int = h()
  assertEqualInt(got, 44, "lambda-local captured var after by-ref call")
}

test "captured Long" {
  var n: Long = 1i64
  val f = { -> n }
  setLong(n, 5000000000i64)
  val seen: Long = f()
  assertEqualLong(n, 5000000000i64, "n after setLong")
  assertEqualLong(seen, 5000000000i64, "f() after setLong")
}

test "captured String" {
  var s = "ab"
  val f = { -> s }
  appendTo(s, "cd")
  val seen: String = f()
  assertEqual(s, "abcd", "s after appendTo")
  assertEqual(seen, "abcd", "f() after appendTo")
}

test "captured Bool" {
  var on = false
  val f = { -> on }
  flip(on)
  val seen: Bool = f()
  assertTrue(on, "on after flip")
  assertTrue(seen, "f() after flip")
}

test "captured vars passed to a generic callee" {
  var s = "a"
  var n = 1
  val f = { -> s + toString(n) }
  assignAny(s, "z")
  assignAny(n, 26)
  val seen: String = f()
  assertEqual(seen, "z26", "f() after the generic callee's writes")
  assertEqual(s, "z", "s after assignAny")
  assertEqualInt(n, 26, "n after assignAny")
}

test "captured record var rebound by the callee" {
  var b = Box(n = 1)
  val f = { -> b.n }
  replaceBox(b, 21)
  val seen: Int = f()
  assertEqualInt(b.n, 21, "b.n after replaceBox")
  assertEqualInt(seen, 21, "f() after replaceBox")
}

test "captured var passed by ref after a `?` argument" {
  match propagateCase() {
    case Ok(v) -> assertEqualInt(v, 606, "x and f() after setFrom(okInt(6)?, x)")
    case Err(e) -> assertTrue(false, "unexpected Err: " + e)
  }
}
