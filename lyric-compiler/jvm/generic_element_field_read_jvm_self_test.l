//! generic_element_field_read_jvm_self_test.l — executable regression test
//! for #6708: a field read on an indexed element of a `slice[Rec[K, V]]` /
//! `List[Rec[K, V]]` container, where `Rec` is a generic record instantiated
//! over the ENCLOSING generic function's own type parameters, failing with
//! `error[J007]: member '<f>' cannot be resolved on an erased (statically
//! Object) receiver`.
//!
//! Before the fix, `indexedElemTypeOverride`'s general arm resolved the
//! indexed element's declared type via `resolveConcreteTypeExpr`, which fell
//! through to `typeExprToJvmExtern`'s blanket erasure for any non-bare-
//! List/Map `TGenericApp` — so a nested generic-record arg (`Entry[K, V]`)
//! erased straight to `java/lang/Object`, leaving the indexed element
//! statically `Object` regardless of how the container itself was declared.
//! A following field read then panicked with J007 rather than resolving
//! against the record's real class.
//!
//! The fix (`Jvm.Codegen.recordParamClassOf`, shared with #6691's parameter
//! fix) adds a `TGenericApp` arm to `resolveConcreteTypeExpr` that resolves
//! a bare generic head through `ctorClassFor` (the SAME `ctx.ctors` registry
//! a `RecordName(field = value, …)` construction call already resolves
//! against) — cross-package aware, which is the reported shape's actual
//! motivating case: `Std.Collections.MapEntry` consumed from an unrelated
//! package (`Std.Collections.Persistent`'s `PersistentMap[K, V]`, #6570,
//! whose `pmapLookup`/`pmapInsert`/`pmapDelete` do exactly `m[i].key` on a
//! `slice[MapEntry[K, V]]` parameter — this module's own `Entry[K, V]`
//! record exercises the identical shape without depending on stdlib
//! internals).
//!
//! A DISTINCT, separate gap remains open and is deliberately NOT covered
//! here: reading a field directly on a plain local bound to a *cross-file*
//! generic function's call RESULT (`val e = someGenericFn(x); e.field`) —
//! that path resolves the callee's return CLASS at signature-collection
//! time, before the bundle-wide constructor registry is fully built for a
//! cross-package record, and is tracked as a follow-up (see the fix's PR
//! description). The shapes below are exactly the ones this fix closes:
//! direct in-body indexing (a generic function's own parameter or a locally
//! built container) and an ANNOTATED local bound to a call result, then
//! indexed — the shape `Std.Collections.Persistent`'s own test suite
//! (`collections_persistent_map_tests.l`) uses and that is now dual-target
//! because of this fix.
//!
//! Run in CI via native `lyric test --target jvm`. Imports only `Std.*`, so
//! no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//!   lyric test --target jvm lyric-compiler/jvm/generic_element_field_read_jvm_self_test.l
@test_module
package Lyric.GenericElementFieldReadJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Entry[K, V] {
  key: K
  value: V
}

// Direct in-body indexing of a `slice[Entry[K, V]]` PARAMETER, field-read in
// the SAME expression — the exact shape `pmapLookup`/`pmapInsert`/
// `pmapDelete` use.
func firstKeyFromSlice[K, V](xs: in slice[Entry[K, V]]): K {
  xs[0].key
}

func firstValueFromSlice[K, V](xs: in slice[Entry[K, V]]): V {
  xs[0].value
}

// Direct in-body indexing of a `List[Entry[K, V]]` PARAMETER.
func firstKeyFromList[K, V](xs: in List[Entry[K, V]]): K {
  xs[0].key
}

// A locally-built `List[Entry[K, V]]`, indexed and field-read within the
// SAME generic function body (no call-boundary involved).
func buildAndReadFirstKey[K, V](k: in K, v: in V): K {
  val xs: List[Entry[K, V]] = newList()
  xs.add(Entry(key = k, value = v))
  xs[0].key
}

// An ANNOTATED local bound to a generic function's call result, then
// indexed — the `Std.Collections.Persistent` test-suite shape
// (`val asList: List[MapEntry[Int, String]] = pmapToList(m)`-style bind,
// `asList[0].key`).
func makeEntries[K, V](k: in K, v: in V): List[Entry[K, V]] {
  val result: List[Entry[K, V]] = newList()
  result.add(Entry(key = k, value = v))
  result
}

func firstKeyViaAnnotatedBind(): Int {
  val asList: List[Entry[Int, String]] = makeEntries(1, "one")
  asList[0].key
}

test "field read on an indexed slice[Entry[K, V]] PARAMETER, direct in-body (#6708)" {
  val xs: slice[Entry[Int, String]] = [Entry(key = 7, value = "seven")]
  assertEqualInt(firstKeyFromSlice(xs), 7, "firstKeyFromSlice == 7")
  assertEqual(firstValueFromSlice(xs), "seven", "firstValueFromSlice == \"seven\"")
}

test "field read on an indexed List[Entry[K, V]] PARAMETER, direct in-body (#6708)" {
  val xs: List[Entry[Int, String]] = newList()
  xs.add(Entry(key = 3, value = "three"))
  assertEqualInt(firstKeyFromList(xs), 3, "firstKeyFromList == 3")
}

test "field read on an indexed locally-built List[Entry[K, V]] inside a generic function body" {
  assertEqualInt(buildAndReadFirstKey(9, "nine"), 9, "buildAndReadFirstKey == 9")
}

test "field read on an indexed element of an ANNOTATED local bound to a generic call result (#6708, PersistentMap shape)" {
  assertEqualInt(firstKeyViaAnnotatedBind(), 1, "firstKeyViaAnnotatedBind == 1")
}
