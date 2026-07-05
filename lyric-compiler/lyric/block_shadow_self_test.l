//! block_shadow_self_test.l — runtime regression test for general nested-block
//! variable shadowing on both self-hosted backends (#5191, D-progress-602).
//!
//! Before the fix, a nested `{ … }` block that re-bound a name already live in
//! an enclosing scope reused the enclosing binding's local slot AND never
//! restored the enclosing name→slot mapping on block exit, so the outer binding
//! read the inner (shadow) value after the block.  The bug was spawn-independent
//! and identical on MSIL and JVM: `val t = 7; if c { val t = 99 }; t` returned
//! `99`, not `7`.
//!
//! Run by the native `lyric test` on BOTH targets (like `bitwise_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/block_shadow_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/block_shadow_self_test.l
//! `lyric test` synthesises a program from the `test` blocks and compiles it
//! in-process through the self-hosted `Msil.Bridge` / `Jvm.Bridge`, then asserts
//! every embedded value.  Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.BlockShadowSelfTest

import Std.Core
import Std.Testing

// A runtime-evaluated condition the codegen cannot fold away, so the shadowed
// branch is really emitted.
func cond(x: in Int): Bool {
  x > 0
}

// 1. Plain `val` shadow in an `if`-then; the enclosing `t` must survive.
func plainShadow(): Int {
  val t = 7
  if cond(1) {
    val t = 99
    assertEqualInt(t, 99, "inner t is 99")
  }
  t
}

// 2. Shadow in both arms of an `if`/`else`.
func ifElseShadow(): Int {
  val t = 3
  if cond(1) {
    val t = 50
    assertEqualInt(t, 50, "then-arm t")
  } else {
    val t = 60
  }
  t
}

// 3. Doubly-nested shadow; the middle binding must survive the innermost block.
func nestedShadow(): Int {
  val t = 1
  if cond(1) {
    val t = 2
    if cond(1) {
      val t = 3
      assertEqualInt(t, 3, "innermost t")
    }
    return t
  }
  t
}

// 4. Shadow inside a `while` body; the enclosing `t` survives the loop.
func loopShadow(): Int {
  val t = 11
  var i = 0
  while i < 3 {
    val t = 100
    i = i + 1
  }
  t
}

// 5. `var` reassignment through a nested block still mutates the enclosing var
//    (assignment is not a rebind, so the slot is preserved either way).
func varMutateThroughBlock(): Int {
  var t = 5
  if cond(1) {
    t = 20
  }
  t
}

// 6. Shadow in a `match` arm; the enclosing `t` survives.
func matchArmShadow(): Int {
  val t = 8
  val o: Option[Int] = Some(value = 42)
  match o {
    case Some(v) -> {
      val t = 999
    }
    case None -> ()
  }
  t
}

// 7. Value-producing block (`if`-expression branch) shadow; the enclosing `t`
//    survives while the inner `t` is the branch value.
func valueBlockShadow(): Int {
  val t = 4
  val r = if cond(1) { val t = 77; t + 1 } else { 0 }
  t + r
}

// 8. Reference-typed shadow (`String`); the enclosing binding survives.
func refShadow(): String {
  val s = "outer"
  if cond(1) {
    val s = "inner"
  }
  s
}

// 9. Sibling `match`-arm scopes reusing the same binding name; each arm is
//    independent and both contribute.
func siblingScopes(): Int {
  var total = 0
  val o1: Option[Int] = Some(value = 1)
  match o1 {
    case Some(x) -> {
      total = total + x
    }
    case None -> ()
  }
  val o2: Option[Int] = Some(value = 10)
  match o2 {
    case Some(x) -> {
      total = total + x
    }
    case None -> ()
  }
  total
}

test "plain val shadow in if-then leaves the outer binding intact" {
  assertEqualInt(plainShadow(), 7, "plainShadow")
}

test "shadow in both if/else arms leaves the outer binding intact" {
  assertEqualInt(ifElseShadow(), 3, "ifElseShadow")
}

test "doubly-nested shadow returns the middle binding" {
  assertEqualInt(nestedShadow(), 2, "nestedShadow")
}

test "shadow inside a loop body leaves the outer binding intact" {
  assertEqualInt(loopShadow(), 11, "loopShadow")
}

test "var reassignment through a nested block mutates the outer var" {
  assertEqualInt(varMutateThroughBlock(), 20, "varMutateThroughBlock")
}

test "shadow in a match arm leaves the outer binding intact" {
  assertEqualInt(matchArmShadow(), 8, "matchArmShadow")
}

test "value-producing block shadow leaves the outer binding intact" {
  assertEqualInt(valueBlockShadow(), 82, "valueBlockShadow")
}

test "reference-typed shadow leaves the outer binding intact" {
  assertEqual(refShadow(), "outer", "refShadow")
}

test "sibling match-arm scopes each bind independently" {
  assertEqualInt(siblingScopes(), 11, "siblingScopes")
}
