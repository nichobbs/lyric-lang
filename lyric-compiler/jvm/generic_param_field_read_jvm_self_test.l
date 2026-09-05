//! generic_param_field_read_jvm_self_test.l — executable regression test for
//! #6691: a field read on a generic-record FUNCTION PARAMETER resolving by
//! bare NAME across every bundled type instead of by the parameter's own
//! class (a silent miscompile — a wrong-class `checkcast`, not a compile
//! error).
//!
//! Before the fix, `typeExprToJvmExtern`/`typeExprToJvmErasedExtern` erased a
//! generic-record-typed parameter's declared type (`Box[Int]`) straight to
//! `java/lang/Object` (the blanket erasure every non-bare-List/Map
//! `TGenericApp` gets), so `EMember`'s record-field lowering saw `cls ==
//! java/lang/Object` and fell through to the erased-receiver fallback: a
//! bundle-wide `field:<name>` lookup that resolves by bare field NAME across
//! every bundled type, silently landing on an unrelated same-named field
//! (in-tree, that fallback happens to land on `Std.Http`'s `opaque type Url
//! { value: String }` for a field named `value`). This module declares its
//! own second record with a same-named field (`OtherRec.value`) to keep the
//! collision reproducible without relying on which stdlib types happen to be
//! bundled.
//!
//! The fix (`Jvm.Codegen.recordParamClassOf`, backed by `ctx.ctors` — the
//! same registry a `RecordName(field = value, …)` construction call already
//! resolves against) narrows a generic-record-typed parameter's slot to its
//! real class via a "narrow at the bind site" prologue (`checkcast` +
//! rebind to a fresh local slot, mirroring `narrowStaticCallResult`'s #6399
//! return-value narrowing), applied in both `setupStaticParamSlotsAndHolders`
//! (free functions) and `setupInstanceParamSlotsAndHolders` (methods/impls).
//!
//! Scoped strictly to PARAMETER bindings (free-function and instance-method).
//! A DISTINCT, separate manifestation of the same underlying erasure —
//! `self.<genericRecordField>.<field>` on a record whose OWN FIELD (not a
//! parameter or an indexed container element) is declared as a generic-record
//! instantiation — was found while developing this test and is NOT fixed
//! here; it needs the field-DECLARATION-typing path (`collectFileCasesExtern`
//! /`lowerRecord`'s own field-type computation), a different call site than
//! `setupStaticParamSlotsAndHolders`/`setupInstanceParamSlotsAndHolders`.
//! Tracked as a follow-up rather than folded into this fix's scope — see
//! #6959.
//!
//! Run in CI via native `lyric test --target jvm` (compiles this module
//! in-process through the self-hosted `Jvm.Bridge` `compileToJarBundled` and
//! runs it under `java`). Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1`
//! is needed.
//!
//!   lyric test --target jvm lyric-compiler/jvm/generic_param_field_read_jvm_self_test.l
@test_module
package Lyric.GenericParamFieldReadJvmSelfTest

import Std.Core
import Std.Testing

record Box[T] {
  value: T
}

// Same field name as `Box.value`, deliberately, so a bare-name-across-the-
// bundle field-read fallback (the pre-fix behaviour) would land on the WRONG
// class here instead of `Box` — even without any stdlib type sharing the
// name.
record OtherRec {
  value: String
}

pub func unboxInt(b: in Box[Int]): Int {
  b.value
}

pub func unboxString(b: in Box[String]): String {
  b.value
}

// Two generic-record parameters of the SAME instantiation in the same
// function: each must resolve against its own bind-site slot independently
// (the narrow-and-rebind prologue runs once per parameter).
pub func firstBoxValue(a: in Box[Int], b: in Box[Int]): Int {
  a.value
}

pub func secondBoxValue(a: in Box[Int], b: in Box[Int]): Int {
  b.value
}

pub func describeOther(o: in OtherRec): String {
  o.value
}

// A record method whose OWN parameter (not `self`) is a generic-record
// instantiation — exercises `setupInstanceParamSlotsAndHolders`'s matching
// narrow-and-rebind pass (the method-lowering sibling of the free-function
// case above).
record BoxUnwrapper {
  offset: Int
  func unwrapPlusOffset(b: in Box[Int]): Int {
    self.offset + b.value
  }
}

test "generic-record parameter field read resolves against its own class (Int payload, #6691)" {
  assertEqualInt(unboxInt(Box(value = 42)), 42, "unboxInt(Box(42)) == 42")
}

test "generic-record parameter field read resolves against its own class (String payload)" {
  assertEqual(unboxString(Box(value = "hello")), "hello", "unboxString(Box(\"hello\")) == \"hello\"")
}

test "two generic-record parameters of the same instantiation each resolve independently" {
  assertEqualInt(firstBoxValue(Box(value = 3), Box(value = 4)), 3, "firstBoxValue == 3")
  assertEqualInt(secondBoxValue(Box(value = 3), Box(value = 4)), 4, "secondBoxValue == 4")
}

test "a same-field-name non-generic record parameter is unaffected" {
  assertEqual(describeOther(OtherRec(value = "plain")), "plain", "OtherRec field read unaffected")
}

test "a record method's OWN generic-record parameter resolves against its class (#6691, instance method)" {
  val u = BoxUnwrapper(offset = 10)
  assertEqualInt(u.unwrapPlusOffset(Box(value = 5)), 15, "10 + 5 == 15")
}
