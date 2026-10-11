//! closure_shadow_self_test.l — runtime regression test for a nested block's
//! binding that shadows a closure-captured `var` (#8201).
//!
//! dotnet and the JVM hoist a `var` that any lambda in the function reads to a
//! heap cell, and kept the name→cell map for the whole function.  A nested
//! block that declared a captured `var` of an enclosing captured `var`'s name
//! crashed codegen with `Map.add`'s "An item with the same key has already been
//! added", and a nested `val`, `for` or match-arm binding of that name read the
//! enclosing cell instead of its own value.  The cell map now follows the same
//! block-scope undo log as the slot map: a new binding hides the enclosing cell
//! and the block's exit brings it back.
//!
//! Every case reads a captured variable only through values that agree on all
//! three targets: native closures capture a `var`'s value rather than the
//! variable (#7891), so no case calls a lambda after writing a variable it
//! captured.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/closure_shadow_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/closure_shadow_self_test.l
//!   lyric test --target native lyric-compiler/lyric/closure_shadow_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ClosureShadowSelfTest

import Std.Core
import Std.Testing

// A runtime-evaluated condition the codegen cannot fold away, so the shadowing
// branch is really emitted.
func cond(x: in Int): Bool {
  x > 0
}

// The issue's repro: the outer `var` is captured, the inner one is not.
func innerVarShadowsCapturedVar(): Int {
  var x = 1
  val f = { -> x }
  var inner = 0
  if cond(1) {
    var x = 100
    x = 5
    inner = x
  }
  val r: Int = f()
  inner * 100 + r * 10 + x
}

// Only the inner `var` is captured; the outer one is assigned after the block.
func capturedInnerVarShadowsVar(): Int {
  var y = 1
  var inner = 0
  if cond(1) {
    var y = 100
    val g = { -> y }
    inner = g()
  }
  y = y + 1
  inner * 10 + y
}

// Both are captured, each by its own lambda.
func capturedVarShadowsCapturedVar(): Int {
  var x = 1
  val f = { -> x }
  var inner = 0
  if cond(1) {
    var x = 100
    x = x + 1
    val g = { -> x }
    inner = g()
  }
  val outer: Int = f()
  inner * 10 + outer
}

// A `val` shadowing a captured `var` is its own binding, read directly and by a
// lambda.
func valShadowsCapturedVar(): Int {
  var x = 1
  val f = { -> x }
  var direct = 0
  var viaLambda = 0
  if cond(1) {
    val x = 100
    direct = x
    val g = { -> x }
    viaLambda = g()
  }
  val outer: Int = f()
  direct + viaLambda + outer
}

// Sibling blocks each declare a captured `var` of the same name.
func siblingCapturedVars(): Int {
  var x = 1
  val f = { -> x }
  var a = 0
  var b = 0
  if cond(1) {
    var x = 10
    val g = { -> x }
    a = g()
  }
  if cond(1) {
    var x = 20
    val h = { -> x }
    b = h()
  }
  val outer: Int = f()
  a + b + outer + x
}

// Two levels of nesting, each with a captured `var` of the outer's name.
func nestedCapturedVars(): Int {
  var x = 1
  val f = { -> x }
  var mid = 0
  var deep = 0
  var midAfter = 0
  if cond(1) {
    var x = 10
    val g = { -> x }
    if cond(1) {
      var x = 100
      val h = { -> x }
      deep = h()
    }
    mid = g()
    midAfter = x
  }
  val outer: Int = f()
  deep + mid + midAfter + outer
}

// A captured `var` in a loop body shadows an enclosing captured `var`.
func loopBodyCapturedVar(): Int {
  var x = 1
  val f = { -> x }
  var sum = 0
  var i = 0
  while i < 3 {
    var x = i * 10
    val g = { -> x }
    sum = sum + g()
    i = i + 1
  }
  val outer: Int = f()
  sum + outer + x
}

// A `for` loop variable and a match-arm binding named like a captured `var`.
func loopAndArmBindings(k: in Int): Int {
  var n = 1
  val f = { -> n }
  var sum = 0
  for n in [10, 20] {
    sum = sum + n
  }
  val armed = match k { case n -> n * 2 }
  val outer: Int = f()
  sum + armed + outer + n
}

// The cells hold values of different types.
func shadowOfAnotherType(): String {
  var s = "outer"
  val f = { -> s }
  var inner = 0
  if cond(1) {
    var s = 41
    s = s + 1
    val g = { -> s }
    inner = g()
  }
  val outer: String = f()
  outer + ":" + toString(inner) + ":" + s
}

// The enclosing `var` is still written through its own cell after the block.
func outerWriteAfterShadow(): Int {
  var x = 1
  val f = { -> x }
  val before: Int = f()
  if cond(1) {
    var x = 100
    val g = { -> x }
    x = g() + 1
  }
  x = x + 10
  before * 100 + x
}

test "a nested var shadows a captured var" {
  assertEqualInt(innerVarShadowsCapturedVar(), 511, "inner 5, lambda 1, outer 1")
}

test "a captured nested var shadows a var" {
  assertEqualInt(capturedInnerVarShadowsVar(), 1002, "inner lambda 100, outer 2")
}

test "a captured nested var shadows a captured var" {
  assertEqualInt(capturedVarShadowsCapturedVar(), 1011, "inner lambda 101, outer lambda 1")
}

test "a nested val shadows a captured var" {
  assertEqualInt(valShadowsCapturedVar(), 201, "direct 100, lambda 100, outer lambda 1")
}

test "sibling blocks each shadow a captured var" {
  assertEqualInt(siblingCapturedVars(), 32, "10 + 20 + outer lambda 1 + outer 1")
}

test "two nested levels of captured vars" {
  assertEqualInt(nestedCapturedVars(), 121, "deep 100, mid 10, mid after 10, outer 1")
}

test "a loop body's captured var shadows a captured var" {
  assertEqualInt(loopBodyCapturedVar(), 32, "0 + 10 + 20, outer lambda 1, outer 1")
}

test "for and match-arm bindings named like a captured var" {
  assertEqualInt(loopAndArmBindings(7), 46, "30 + 14 + outer lambda 1 + outer 1")
}

test "a captured var shadowed by one of another type" {
  assertEqual(shadowOfAnotherType(), "outer:42:outer", "each cell keeps its own type")
}

test "the enclosing var is written after the block" {
  assertEqualInt(outerWriteAfterShadow(), 111, "lambda before 1, outer 11")
}
