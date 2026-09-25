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
//! `self.<genericRecordField>.<field>` (or `<recordParam>.<genericRecordField>
//! .<field>`) on a record whose OWN FIELD (not a parameter or an indexed
//! container element) is declared as a generic-record instantiation — was
//! found while developing this test and was NOT fixed here (tracked
//! separately as #6959): it needs the field-DECLARATION-typing path
//! (`collectFileCasesExtern`/`lowerRecord`'s own field-type computation), a
//! different call site than `setupStaticParamSlotsAndHolders`/
//! `setupInstanceParamSlotsAndHolders`.
//!
//! #6959 turned out to already be fixed as a side effect of #4870/#6882
//! (`Jvm.Codegen.typeExprToJvmErasedExternL`, landed after this file and
//! #6959 were filed): `collectFileCasesExtern` and `lowerRecord` both resolve
//! a same-file bare `TGenericApp` field type (e.g. `box: Box[Int]` on
//! `Holder`) to its raw erased class via the shared `localTypeNames` table,
//! not the blanket `Object` erasure — so the field DESCRIPTOR and the case-
//! field REGISTRY agree on `Holder.box`'s real class, and a chained read
//! (`self.box.value`) resolves directly against `Box`'s own field registry
//! instead of falling through the erased-receiver bundle-wide `field:<name>`
//! fallback. The `Holder`/`readHolderBoxValue`/`HolderMethod` declarations
//! and their tests below lock this in.
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

// #6959: `Holder`'s OWN field (not a parameter) is a generic-record
// instantiation (`Box[Int]`). A chained read through it — `h.box.value` from
// a free function, `self.box.value` from an instance method — must resolve
// against `Box`'s real class, not the erased-`Object` bundle-wide fallback
// (which would land on `OtherRec.value` above, a `String`, if it fired).
record Holder {
  box: Box[Int]
  func selfBoxValue(self: in Holder): Int {
    self.box.value
  }
}

pub func readHolderBoxValue(h: in Holder): Int {
  h.box.value
}

test "a record's OWN generic-record field resolves via field access from a free function (#6959)" {
  val h = Holder(box = Box(value = 7))
  assertEqualInt(readHolderBoxValue(h), 7, "readHolderBoxValue(Holder(Box(7))) == 7")
}

test "a record's OWN generic-record field resolves via self-access from an instance method (#6959)" {
  val h = Holder(box = Box(value = 13))
  assertEqualInt(h.selfBoxValue(), 13, "Holder(Box(13)).selfBoxValue() == 13")
}

// An ANNOTATED LOCAL of a generic-record type (`val b: Box[Int] = f(...)`)
// used to erase to `Object` too, so a field read on it hit the erased-
// receiver path: J007 at compile time, or, for a field named `count`, the
// `__lyricCount` helper casting the record to `Object[]` at run time.
// `localAnnotatedJvmType` now recovers the record's class like a parameter.
record Tally[T] {
  items: List[T]
  count: Int
}

func makeBox[T](v: in T): Box[T] {
  Box(value = v)
}

func makeTally[T](xs: in List[T]): Tally[T] {
  Tally(items = xs, count = xs.count)
}

test "an annotated val of a generic-record type reads its field" {
  val b: Box[Int] = makeBox(21)
  assertEqualInt(b.value, 21, "val b: Box[Int]")
}

test "an annotated var and let of a generic-record type read their fields" {
  var v: Box[String] = makeBox("first")
  v = makeBox("second")
  let l: Box[Int] = makeBox(8)
  assertEqual(v.value, "second", "var v: Box[String]")
  assertEqualInt(l.value, 8, "let l: Box[Int]")
}

test "a generic record's own field named count is read as the field" {
  val xs: List[String] = newList()
  xs.add("a")
  xs.add("b")
  val t: Tally[String] = makeTally(xs)
  assertEqualInt(t.count, 2, "Tally.count field, not a collection length")
}
