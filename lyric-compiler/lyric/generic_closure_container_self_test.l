//! generic_closure_container_self_test.l — executable regression test for
//! #6569: a self-hosted MSIL backend generic-codegen bug where a generic
//! function calling a closure PARAMETER inside a loop over
//! `slice[UserGenericRecord[K, V]]` monomorphized to a specialization
//! whose FIRST parameter was erased to `Object` instead of the real
//! slice/array type — crashing with `NullReferenceException` on the
//! very first call, even with an empty slice where the loop body never
//! executes at runtime (a compile-time codegen defect, not a data-
//! dependent one).
//!
//! Why this lives here and not in `lyric-stdlib/tests/*_tests.l`: this
//! is a self-hosted-MSIL-backend-specific regression, not a stdlib
//! surface test — it belongs alongside the other backend-codegen
//! self-tests (`bitwise_self_test.l`, `inbundle_generics_self_test.l`).
//! Run via the native `lyric test`, which synthesises a program from the
//! `test` blocks and compiles it in-process through the self-hosted
//! `Msil.Bridge`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_closure_container_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GenericClosureContainerSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// The exact shape `Std.Collections.Persistent.pmapInsert` needs: a
// generic function over `slice[MapEntry[K, V]]` that invokes a closure
// PARAMETER inside a conditional nested in a `while` loop over that
// slice.  Mirrors the issue's minimal bisected repro.
func pmapInsert6569[K, V](
  m: in slice[MapEntry[K, V]], key: in K, value: in V, eq: in (K, K) -> Bool
): slice[MapEntry[K, V]] {
  val acc: List[MapEntry[K, V]] = newList()
  var i = 0
  var replaced = false
  while i < m.length {
    if eq(m[i].key, key) {
      acc.add(MapEntry(key = key, value = value))
      replaced = true
    } else {
      acc.add(m[i])
    }
    i = i + 1
  }
  if not replaced {
    acc.add(MapEntry(key = key, value = value))
  }
  acc.toArray()
}

func intEq6569(a: in Int, b: in Int): Bool {
  a == b
}

test "#6569: first call with an EMPTY slice does not crash (compile-time codegen defect, not data-dependent)" {
  val noEntries: List[MapEntry[Int, String]] = newList()
  val e: slice[MapEntry[Int, String]] = noEntries.toArray()
  val m1 = pmapInsert6569(e, 5, "five", intEq6569)
  assertEqualInt(m1.length, 1, "insert into an empty slice yields a 1-element slice")
}

test "#6569: the closure parameter is genuinely invoked and its result observed" {
  val noEntries: List[MapEntry[Int, String]] = newList()
  val e: slice[MapEntry[Int, String]] = noEntries.toArray()
  val m1 = pmapInsert6569(e, 5, "five", intEq6569)
  val m2 = pmapInsert6569(m1, 6, "six", intEq6569)
  assertEqualInt(m2.length, 2, "two distinct-key inserts yield a 2-element slice")
  // Overwrite: eq(m[i].key, key) must actually match and replace, not just
  // return without crashing.
  val m3 = pmapInsert6569(m2, 5, "FIVE", intEq6569)
  assertEqualInt(m3.length, 2, "overwriting an existing key does not grow the slice")
  assertEqual(m3[0].value, "FIVE", "overwritten entry's value is replaced")
  assertEqual(m3[1].value, "six", "untouched entry's value is unchanged")
}

test "#6569: the specialized function's first parameter keeps its real slice type (not erased to Object)" {
  // A slice indexing / .length read on `m` right after the call — if the
  // specialization's first parameter were still erased to `Object` (the
  // exact #6569 defect), this would already have crashed inside the
  // function body above; reaching here at all is part of the regression
  // coverage.  This test additionally exercises a THIRD chained call
  // (the issue's bisection notes explicitly call out that chaining is
  // NOT the trigger — a single call already crashed — but chained calls
  // are still worth pinning for the fixed backend).
  val noEntries: List[MapEntry[Int, String]] = newList()
  val e: slice[MapEntry[Int, String]] = noEntries.toArray()
  val m1 = pmapInsert6569(e, 1, "a", intEq6569)
  val m2 = pmapInsert6569(m1, 2, "b", intEq6569)
  val m3 = pmapInsert6569(m2, 3, "c", intEq6569)
  assertEqualInt(m3.length, 3, "three distinct-key inserts yield a 3-element slice")
  assertEqual(m3[0].value, "a", "m3[0]")
  assertEqual(m3[1].value, "b", "m3[1]")
  assertEqual(m3[2].value, "c", "m3[2]")
}
