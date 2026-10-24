//! inout_aliasing_closure_self_test.l — an `out`/`inout` parameter refers to
//! the caller's place (D183, #8263) when a closure also reaches the place, or
//! when the callee panics after writing it, on `--target dotnet` and
//! `--target jvm`.
//!
//! A local passed by reference is one location the caller, the callee and
//! every closure capturing the local share: a closure the callee calls sees
//! the callee's write, and the callee sees the closure's.  A write made
//! before a panic stays made, since nothing is copied back.  Native closures
//! capture a variable's value (#7891), and native has no `try` (D-N-003), so
//! this file is not run there; `inout_aliasing_self_test.l` covers every
//! other place kind on all three targets.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/inout_aliasing_closure_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inout_aliasing_closure_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.InoutAliasingClosureSelfTest

import Std.Core
import Std.Testing

ref record R {
  var f: Int
}

func callThen(x: inout Int, k: in () -> Unit): Int {
  x = x + 1
  k()
  x
}

func writeOutThen(x: out Int, k: in () -> Int): Int {
  x = 4
  k()
}

func genericCallThen[T](x: inout T, v: in T, k: in () -> Unit): T {
  x = v
  k()
  x
}

func passOn(x: inout Int, k: in () -> Unit): Int {
  callThen(x, k)
}

func setThenPanic(x: inout Int): Unit {
  x = 42
  panic("after the write")
}

func fieldThenPanic(x: inout Int): Unit {
  x = x + 1
  panic("after the write")
}

test "a closure the callee calls writes the caller's local" {
  var x = 1
  val r = callThen(x, { -> x = x * 100 })
  assertEqualInt(r, 200, "the callee sees the closure's write")
  assertEqualInt(x, 200, "the caller sees both")
}

test "a closure the callee calls reads the callee's write" {
  var x = 0
  var seen = 0
  writeOutThen(x, { -> seen = x; x + 1 })
  assertEqualInt(seen, 4, "the closure sees the out write")
  assertEqualInt(x, 4, "the caller")
}

test "a generic parameter and a closure share the local" {
  var s = "a"
  val r = genericCallThen(s, "b", { -> s = s + "c" })
  assertEqual(r, "bc", "the callee sees the closure's write")
  assertEqual(s, "bc", "the caller")
}

test "a parameter passed on keeps the closure's local" {
  var x = 1
  assertEqualInt(passOn(x, { -> x = x + 10 }), 12, "forwarded")
  assertEqualInt(x, 12, "the caller")
}

test "a local the closure captures, written from inside the closure" {
  var x = 1
  val k = { -> callThen(x, { -> x = x * 2 }) }
  assertEqualInt(k(), 4, "inner call")
  assertEqualInt(x, 4, "the caller")
}

test "a write before a panic stays made" {
  var x = 0
  var caught = false
  try {
    setThenPanic(x)
  } catch Bug as b {
    caught = true
  }
  assertTrue(caught, "the panic was caught")
  assertEqualInt(x, 42, "a local")
  val r = R(f = 1)
  try {
    fieldThenPanic(r.f)
  } catch Bug as b2 {
    caught = true
  }
  assertEqualInt(r.f, 2, "a field")
}
