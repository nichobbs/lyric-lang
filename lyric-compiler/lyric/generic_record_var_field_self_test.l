//! generic_record_var_field_self_test.l — dual-target runtime regression
//! test for a `var` field write on a generic record instance silently
//! dropped on `--target dotnet` (#7663).
//!
//! `box.value = other` on `box: MyBox[T]` (a `record MyBox[T] { var value: T }`
//! instance) compiled clean but the write never happened: `overwrite` kept
//! returning the ORIGINAL field value, never the one just assigned. Root
//! cause: `lowerAssignExprMsil`'s `EMember` (`recv.field = value`) arm in
//! `lyric-compiler/msil/codegen.l` only handled an `MClass` (plain, non-generic
//! record) or `MClassRef` (extern instance) receiver type. Every generic
//! record instance receiver — `MGenericInst` (cross-assembly, e.g. a stdlib
//! generic) or `MGenericInstByName` (in-bundle, e.g. `MyBox[T]` here) — fell
//! through to the default arm, which lowers the value expression for its
//! side effects and then pops BOTH the value and the receiver off the
//! stack, emitting no `stfld` at all: a silent no-op write. The read side
//! already special-cased both generic-instantiation receiver kinds (see the
//! matching `EMember` READ arms in the same file) via a closed GENERICINST
//! TypeSpec + TypeSpec-parented MemberRef (`MCastclassGeneric` +
//! `MLdfldGeneric`, docs/43); there was no write-side analog
//! (`MStfldGeneric`) until this fix, added alongside `MLdfldGeneric` in
//! `lyric-compiler/msil/lowering.l`.
//!
//! The bug was MSIL-only: `Jvm.Codegen`'s field-assignment lowering
//! (`lyric-compiler/jvm/codegen/*.l`) already resolved the field's `putfield`
//! descriptor from the record's own declaration regardless of how the
//! receiver type was classified, so `--target jvm` was never affected — this
//! file's dotnet run is the load-bearing regression check; the jvm run
//! guards against ever reintroducing target-specific behaviour here.
//!
//! Both `val`- and `var`-bound bindings are covered: per docs/01, a record
//! with `var` fields is mutable THROUGH the binding regardless of whether
//! the binding itself is `val` or `var` (the binding controls whether the
//! LOCAL NAME can be reassigned to a different record value, not whether the
//! record's own `var` fields can be mutated) — a non-generic record's `var`
//! field is writable through a `val` binding today, so a generic record must
//! behave identically.
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_record_var_field_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generic_record_var_field_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//! NOT covered here: a closure that only READS a generic record's `Int`
//! field it captured (no write through the closure at all) returns garbage
//! on `--target dotnet` — confirmed pre-existing on `main` before this fix
//! (the read path this file's fix does not touch) and out of scope for
//! #7663. Filed separately; see this task's final report.
@test_module
package Lyric.GenericRecordVarFieldSelfTest

import Std.Core
import Std.Testing

record MyBox[T] {
  var value: T
}

func overwriteVal[T](seed: in T, other: in T): T {
  val box = MyBox(value = seed)
  box.value = other
  box.value
}

func overwriteVar[T](seed: in T, other: in T): T {
  var box = MyBox(value = seed)
  box.value = other
  box.value
}

func overwriteViaClosure[T](seed: in T, other: in T): T {
  val box = MyBox(value = seed)
  val setter = { -> box.value = other }
  setter()
  box.value
}

func overwriteTwice[T](a: in T, b: in T, c: in T): T {
  val box = MyBox(value = a)
  box.value = b
  box.value = c
  box.value
}

// ── Int type argument ────────────────────────────────────────────────────
test "val-bound generic record: Int field write is observed" {
  assertEqualInt(overwriteVal(1, 2), 2, "overwriteVal(1, 2)")
}

test "var-bound generic record: Int field write is observed" {
  assertEqualInt(overwriteVar(1, 2), 2, "overwriteVar(1, 2)")
}

test "generic record: Int field write through a captured closure is observed" {
  assertEqualInt(overwriteViaClosure(1, 2), 2, "overwriteViaClosure(1, 2)")
}

test "generic record: two sequential Int writes both take effect" {
  assertEqualInt(overwriteTwice(1, 2, 3), 3, "overwriteTwice(1, 2, 3)")
}

// ── String type argument ─────────────────────────────────────────────────
test "val-bound generic record: String field write is observed" {
  assertEqual(overwriteVal("a", "b"), "b", "overwriteVal(a, b)")
}

test "var-bound generic record: String field write is observed" {
  assertEqual(overwriteVar("a", "b"), "b", "overwriteVar(a, b)")
}

test "generic record: String field write through a captured closure is observed" {
  assertEqual(overwriteViaClosure("a", "b"), "b", "overwriteViaClosure(a, b)")
}

test "generic record: two sequential String writes both take effect" {
  assertEqual(overwriteTwice("a", "b", "c"), "c", "overwriteTwice(a, b, c)")
}

// ── Non-generic function, generic record (isolate the field-write path
// from the `Lyric.Mono` monomorphizer, #7663) ────────────────────────────
func overwriteConcrete(seed: in Int, other: in Int): Int {
  val box = MyBox(value = seed)
  box.value = other
  box.value
}

test "generic record instantiated inside a NON-generic function still writes" {
  assertEqualInt(overwriteConcrete(1, 2), 2, "overwriteConcrete(1, 2)")
}
