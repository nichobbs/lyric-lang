//! slice_compound_assign_eval_order_self_test.l — #7005: `slice[T]`
//! compound indexed assignment (`xs[i] op= e`) evaluated the RHS `e` AFTER
//! reading the container's current element on `--target jvm`, while every
//! other receiver kind (`List[T]`, `Map[K, V]`) on JVM, and `slice[T]`
//! itself on `--target dotnet` and `--target native`, evaluate the RHS
//! BEFORE the container read.
//!
//! `slice[T]` is a genuine JVM array (`JArray`), a distinct representation
//! from `List[T]`'s `java.util.ArrayList` (`jvm/codegen/05_stmts.l`'s
//! `JArray` vs `JRef("java/util/HashMap")` dispatch in the `EIndex`
//! compound-assign arm). The `JArray` arm alone read the array element
//! (`emitArrayLoad`) BEFORE lowering the RHS — every other arm (the `JRef`
//! Map arm here, and MSIL's single unified List/Map/`slice[T]` path in
//! `msil/codegen.l`, and the native `Lyric.LlvmCodegen.lowerIndexAssign`
//! path, D-progress-886) evaluates the RHS first. For `xs[i] op= f()` where
//! `f()` itself mutates `xs[i]`, the two orders are observably different:
//! RHS-first sees `f()`'s write when it reads the container back (so the
//! write is silently clobbered by the compound store); read-first captures
//! the pre-mutation value and combines with `f()`'s return, silently
//! discarding what `f()` wrote to that same slot instead. Fixed by
//! reordering the `JArray` compound-assign arm to spill the RHS to a local
//! BEFORE emitting the two-array-load-plus-index sequence, mirroring the
//! `JRef` Map arm immediately below it — no change to the plain `AssEq`
//! arm, which already evaluated the RHS after the receiver/index but that
//! ordering has no read-then-combine step to invert.
//!
//! Run by the native `lyric test` on BOTH targets (like
//! `inout_slice_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/slice_compound_assign_eval_order_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/slice_compound_assign_eval_order_self_test.l
//! `lyric test` synthesises a program from the `test` blocks and compiles it
//! in-process through the self-hosted `Msil.Bridge` / `Jvm.Bridge`, then
//! asserts every embedded value. Imports only `Std.*` (no
//! `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.SliceCompoundAssignEvalOrderSelfTest

import Std.Core
import Std.Testing

// Mutates the SAME slot (`xs[0]`) the caller is about to compound-assign,
// then returns a fixed addend — the only way to make the two possible
// evaluation orders produce different final values. RHS-first (correct,
// uniform order): reads `xs[0]` back AFTER this call already stored `999`,
// so the container read observes `999`, combined with `5` -> `1004`.
// Read-first (the pre-fix `JArray` bug): reads `xs[0]`'s PRE-mutation value
// (`10`) before this call runs, so the eventual store combines the stale
// `10` with `5` -> `15`, silently overwriting the `999` this function wrote.
func mutateSameSlotAndReturn(xs: inout slice[Int]): Int {
  xs[0] = 999
  5
}

test "slice[Int] compound-assign evaluates the RHS before the container read (#7005)" {
  var xs: slice[Int] = [10, 20, 30]
  xs[0] += mutateSameSlotAndReturn(xs)
  assertEqualInt(xs[0], 1004, "xs[0] must reflect the RHS's own same-slot write, not a stale pre-call read")
}

// A second value-element width (`Long`), explicitly annotated so the
// local's tracked JVM type is unambiguously a primitive `long[]` rather
// than `int[]`, confirming the fix isn't specific to `Int`'s storage width.
// (A reference-element `slice[String]` compound-assign is not covered here:
// `emitCompoundCombineJvm`'s String arm dispatches on the array's tracked
// element type, which erases to `java/lang/Object` for a reference-typed
// `slice[T]` today (#5257's uniform boxed-array ABI) rather than the real
// declared `String` element `indexedElemTypeOverride` resolves for the
// plain-`AssEq` arm — a separate, pre-existing gap unrelated to this
// eval-order fix, not attempted here.)
func mutateSameSlotAndReturnLong(xs: inout slice[Long]): Long {
  xs[0] = 999i64
  5i64
}

test "slice[Long] compound-assign evaluates the RHS before the container read (#7005)" {
  var xs: slice[Long] = [10i64, 20i64, 30i64]
  xs[0] += mutateSameSlotAndReturnLong(xs)
  assertEqualLong(xs[0], 1004i64, "xs[0] must reflect the RHS's own same-slot write, not a stale pre-call read")
}
