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

// 10. Shadow declared directly in a `scope { }` body — the one construct D119
//     slice S4 ships real semantics for (#5204).  A bare `scope` (no `spawn`)
//     still opens/closes its executor on the JVM; the enclosing `t` must survive.
func scopeBodyShadow(): Int {
  val t = 7
  scope {
    val t = 99
  }
  t
}

// 11. Match-arm PATTERN BINDING shadowing an outer binding of the SAME frame
//     type (Int payload vs Int outer — the slot-REUSE path, docs/59 §4.1): the
//     helper's declared `Option[Int]` return resolves the payload to a real
//     Int, so before the fix `allocSlot` reused the outer `v`'s slot and the
//     payload clobbered it.
func mkIntOpt(x: in Int): Option[Int] {
  Some(value = x)
}

func matchBindShadowSameType(): Int {
  val v = 7
  val r = match mkIntOpt(100) { case Some(v) -> v + 1; case None -> 0 }
  assertEqualInt(r, 101, "arm binding reads the payload")
  v
}

// 12. Match-arm pattern binding shadowing an outer binding of a DIFFERENT
//     frame type (erased-Object payload vs String outer — the remap-LEAK path):
//     the arm's fresh slot was already taken pre-fix, but the name→slot remap
//     leaked until the enclosing block exit, so the outer read went to the
//     arm's slot.
func matchBindShadowDifferentType(): String {
  val name = "outer"
  val o: Option[Int] = Some(value = 5)
  var seen = 0
  match o {
    case Some(name) -> {
      seen = seen + 1
    }
    case None -> ()
  }
  assertEqualInt(seen, 1, "arm body ran")
  name
}

// 13. Guard expression reads: the guard sees the ARM binding (shadowing the
//     outer `k`) plus an untouched outer `limit`; after the match the outer
//     `k` is intact.
func guardReadsBindingAndOuter(): Int {
  val k = 3
  val limit = 5
  val got = match mkIntOpt(9) { case Some(k) if k > limit -> k; case Some(k) -> 0 - k; case None -> 0 }
  assertEqualInt(got, 9, "guarded arm selected on the ARM k")
  k
}

// 14. Nested match arms re-binding the same name: the inner arm's `p` shadows
//     the outer arm's `p`; after the inner match the outer arm's binding is
//     intact, and after both the function-level `p` is intact.
func nestedMatchArms(): Int {
  val p = 1
  var innerSeen = 0
  var outerAfterInner = 0
  match mkIntOpt(10) {
    case Some(p) -> {
      match mkIntOpt(20) {
        case Some(p) -> {
          innerSeen = p
        }
        case None -> ()
      }
      outerAfterInner = p
    }
    case None -> ()
  }
  assertEqualInt(innerSeen, 20, "inner arm p")
  assertEqualInt(outerAfterInner, 10, "outer arm p survives the inner match")
  p
}

// 15. Range-`for` loop-variable bind shadowing an outer val (same frame type).
func forLoopBindShadow(): Int {
  val i = 42
  var sum = 0
  for i in 0 ..< 5 {
    sum = sum + i
  }
  assertEqualInt(sum, 10, "loop summed its own counter")
  i
}

// 16. Collection-`for` element bind shadowing an outer val.  Iterates a
//     `toArray()` slice: on MSIL the element is a typed Int (slot-reuse path
//     against the outer Int), on the JVM it is an erased Object (remap-leak
//     path) — one case covers both shapes across targets.  (A bare list
//     LITERAL iterable is deliberately not used here: MSIL's erased
//     `List<object>` element arithmetic is a separate pre-existing gap.)
func forElemBindShadow(): Int {
  val x = 100
  val data: List[Int] = newList()
  data.add(1)
  data.add(2)
  data.add(3)
  var total = 0
  for x in data.toArray() {
    total = total + x
  }
  assertEqualInt(total, 6, "loop summed its own elements")
  x
}

// 17. Or-pattern re-binding inside one arm scope: both alternatives populate
//     the same arm-local slot, and the outer same-named binding survives.
func orPatternBindShadow(): Int {
  val x = 55
  val r1: Result[Int, Int] = Ok(value = 4)
  val r2: Result[Int, Int] = Err(error = 9)
  var sum = 0
  match r1 {
    case Ok(x) | Err(x) -> {
      sum = sum + x
    }
  }
  match r2 {
    case Ok(x) | Err(x) -> {
      sum = sum + x
    }
  }
  assertEqualInt(sum, 13, "or-pattern bound from either alternative")
  x
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

test "shadow directly in a scope body leaves the outer binding intact" {
  assertEqualInt(scopeBodyShadow(), 7, "scopeBodyShadow")
}

test "match-arm pattern bind of the same frame type leaves the outer binding intact" {
  assertEqualInt(matchBindShadowSameType(), 7, "matchBindShadowSameType")
}

test "match-arm pattern bind of a different frame type leaves the outer binding intact" {
  assertEqual(matchBindShadowDifferentType(), "outer", "matchBindShadowDifferentType")
}

test "guard reads the arm binding and the outer binding survives the match" {
  assertEqualInt(guardReadsBindingAndOuter(), 3, "guardReadsBindingAndOuter")
}

test "nested match arms shadow independently at each level" {
  assertEqualInt(nestedMatchArms(), 1, "nestedMatchArms")
}

test "range-for loop variable shadow leaves the outer binding intact" {
  assertEqualInt(forLoopBindShadow(), 42, "forLoopBindShadow")
}

test "collection-for element shadow leaves the outer binding intact" {
  assertEqualInt(forElemBindShadow(), 100, "forElemBindShadow")
}

test "or-pattern arm binds shadow and restore the outer binding" {
  assertEqualInt(orPatternBindShadow(), 55, "orPatternBindShadow")
}
