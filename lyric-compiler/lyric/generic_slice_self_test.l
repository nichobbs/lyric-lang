//! generic_slice_self_test.l — regression test for #2557: user-defined generic
//! functions whose parameters / returns / typed locals mention `slice[T]` (or a
//! bare type variable `T`).
//!
//! Before #2557 a call such as `glen([1,2,3])` did not monomorphise (the list/
//! slice literal `[...]` inferred no element type, so the generic call survived
//! to codegen), and the surviving generic `slice[T]` parameter lowered to a
//! `slice<Pkg.T>` over a non-existent CLR type — the JIT rejected the body with
//! "Common Language Runtime detected an invalid program."  A typed body local
//! (`val acc: List[T]`) hit the same wall because `specializeFunc` shared the
//! body verbatim and never substituted `T` in the local's annotation.
//!
//! The fix (see docs/03-decision-log.md D095) makes the monomorphiser:
//!   * infer `slice[ElemType]` from a list/slice literal (`inferExprTE`),
//!   * unify a `slice[T]` parameter against a `slice[Int]` argument (`unifyTE`),
//!   * substitute type variables inside the specialised body's annotations
//!     (`substTypesFunctionBody`),
//! so `glen[T]` / `gidx[T]` / `gcopy[T]` specialise into concrete `__Int`
//! copies that reuse the (post-#2558) List-backed slice path.  Bare-`T` returns
//! and `slice[T]` returns are erased to the List-backed representation when a
//! call genuinely cannot be monomorphised, so they still execute correctly.
//!
//! Why this lives here and not in `lyric-stdlib/tests/*_tests.l`: those files are
//! compiled and run by the F# stage-0 emitter, which emits generic functions as
//! real CLR generic methods over genuine arrays and so never exercises the
//! self-hosted List-backed generic-slice path these fixes live in.  `lyric test`
//! compiles this `@test_module` IN-PROCESS through the self-hosted `Msil.Bridge`,
//! then runs it.  Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//! Run via:
//!
//!   lyric test lyric-compiler/lyric/generic_slice_self_test.l
@test_module
package Lyric.GenericSliceSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// A generic function over a `slice[T]` parameter returning a non-generic Int.
func glen[T](xs: in slice[T]): Int {
  xs.length
}

// A generic function whose RETURN type is the bare type variable `T`.
func gidx[T](xs: in slice[T], i: in Int): T {
  xs[i]
}

// A generic function with a `slice[T]` return AND a typed `List[T]` body local —
// the case that surfaced "invalid program" from the verbatim-body copy (#2557).
func gcopy[T](xs: in slice[T], lo: in Int, hi: in Int): slice[T] {
  val acc: List[T] = newList()
  var i = lo
  while i < hi {
    acc.add(xs[i])
    i = i + 1
  }
  return acc.toArray()
}

// A generic identity over `slice[T]` returning `slice[T]` (return = parameter).
func gid[T](xs: in slice[T]): slice[T] {
  xs
}

test "generic slice .length (value element)" {
  assertEqualInt(glen([10, 20, 30]), 3, "length 3")
  assertEqualInt(glen([7]), 1, "length 1")
}

test "generic slice .length (reference element)" {
  assertEqualInt(glen(["a", "b", "c", "d"]), 4, "string length 4")
}

test "generic slice indexing returns bare-T element" {
  assertEqualInt(gidx([10, 20, 30], 0), 10, "idx 0")
  assertEqualInt(gidx([10, 20, 30], 2), 30, "idx 2")
  assertEqual(gidx(["x", "y", "z"], 1), "y", "string idx 1")
}

test "generic slice copy (slice[T] return + List[T] local)" {
  val c = gcopy([10, 20, 30, 40], 1, 3)
  assertEqualInt(c.length, 2, "copy length 2")
  assertEqualInt(c[0], 20, "copy[0] = 20")
  assertEqualInt(c[1], 30, "copy[1] = 30")
}

test "generic slice copy preserves reference elements" {
  val c = gcopy(["alpha", "bravo", "charlie"], 0, 2)
  assertEqualInt(c.length, 2, "ref copy length 2")
  assertEqual(c[0], "alpha", "ref copy[0]")
  assertEqual(c[1], "bravo", "ref copy[1]")
}

test "generic slice identity round-trips through .length / index" {
  val r = gid([100, 200, 300])
  assertEqualInt(r.length, 3, "identity length")
  assertEqualInt(r[2], 300, "identity[2]")
}
