//! list_of_slice_construction_jvm_self_test.l — regression test for
//! constructing a `List[slice[T]]` (a `List` whose elements are arrays) on
//! `--target jvm` (#6546).
//!
//! Two separate, pre-existing bugs made this shape unusable at all before
//! this fix:
//!
//! Bug 1 — a bare slice-literal argument to `.add()` stores a
//! `java.util.ArrayList` instead of a real array.  `[1, 2, 3]` (an `EList`
//! node) always lowers to an `ArrayList` first (02_exprs.l); only a call
//! site with a KNOWN DECLARED `slice[T]` parameter type converts it into a
//! real array (`coerceArgTo`'s `JArray` arm).  `List[T].add(value: T)` has
//! no such declared param type to consult — it fell through to the generic
//! JDK auto-FFI path, whose only known signature is the real
//! `ArrayList.add(Object)`, genuinely opaque to Lyric's `slice[T]` vs
//! `List[T]` distinction, so the `ArrayList` reached storage unconverted.
//! Reading it back and iterating (`for row in xs { for v in row { ... } }`)
//! crashed: `ClassCastException: class java.util.ArrayList cannot be cast
//! to class [Ljava.lang.Object;`.  Fixed in `04_calls.l`'s `lowerMethodCall`
//! by intercepting `.add` before the auto-FFI dispatch whenever the
//! receiver's recorded element type resolves to `slice[Elem]`.
//!
//! Bug 2 — routing the same literal through a pass-through helper with an
//! explicit `slice[Int]` return type failed EARLIER, at COMPILE time:
//! `error[J008]: JVM auto-FFI: no matching instance or inherited method for
//! 'java.util.ArrayList.add([Ljava/lang/Object;)'`.  Once the argument's
//! static type was precisely `slice[Int]`, `ffiScoreDescFor` narrowed its
//! score descriptor to a primitive-array shape (`[I`) for JDK overload
//! scoring (#6745's mechanism, meant for real primitive-array JDK
//! parameters) — but `scoreParamMatch` had no rule accepting a narrowed
//! primitive-array descriptor against a bare `Object` parameter (only
//! against `Object[]`), so the ONLY real overload,
//! `ArrayList.add(Ljava/lang/Object;)Z`, never scored and the call panicked
//! at compile time.  Fixed in `auto_ffi.l`'s `scoreParamMatch` by adding the
//! missing reverse-compatibility arm.
//!
//! Both fixes are independent and both required: Bug 1 is invisible to
//! auto-FFI scoring (bare `EList` literal, not an array-shaped argument at
//! all — it "successfully" resolves the wrong runtime representation), and
//! Bug 2 is a pure compile-time scoring gap unrelated to Bug 1's coercion.
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed. Run via
//! native `lyric test --target jvm`:
//!   lyric test --target jvm lyric-compiler/jvm/list_of_slice_construction_jvm_self_test.l
@test_module
package Lyric.ListOfSliceConstructionJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func intRow(vals: in slice[Int]): slice[Int] {
  vals
}

func sumListOfSlice(xs: in List[slice[Int]]): Int {
  var total = 0
  for row in xs {
    for v in row {
      total = total + v
    }
  }
  total
}

test "Bug 1: a bare slice literal added to a List[slice[Int]] round-trips as a real array" {
  val xs: List[slice[Int]] = newList()
  xs.add([1, 2, 3])
  assertEqualInt(xs.count, 1, "one row was added")
  assertEqualInt(sumListOfSlice(xs), 6, "row sums correctly after round-trip")
  val row = xs[0]
  assertEqualInt(row.length, 3, "row keeps its real length")
  assertEqualInt(row[0], 1, "row[0]")
  assertEqualInt(row[1], 2, "row[1]")
  assertEqualInt(row[2], 3, "row[2]")
}

test "Bug 2: an explicitly slice[Int]-typed argument compiles and round-trips" {
  val xs: List[slice[Int]] = newList()
  xs.add(intRow([4, 5, 6]))
  assertEqualInt(sumListOfSlice(xs), 15, "typed-argument row sums correctly")
  assertEqualInt(xs[0][1], 5, "nested index xs[0][1] reads the real array")
}

test "an empty slice element added to a List[slice[Int]] does not crash" {
  val xs: List[slice[Int]] = newList()
  xs.add([])
  xs.add([9])
  assertEqualInt(xs.count, 2, "both rows were added")
  assertEqualInt(xs[0].length, 0, "first row is empty")
  assertEqualInt(sumListOfSlice(xs), 9, "sum skips the empty row correctly")
}

test "a List[slice[Int]] with more than one row iterates and indexes every row correctly" {
  val xs: List[slice[Int]] = newList()
  xs.add([1, 2])
  xs.add(intRow([3, 4, 5]))
  xs.add([6])
  assertEqualInt(xs.count, 3, "three rows were added")
  assertEqualInt(sumListOfSlice(xs), 21, "sum across every row")
  assertEqualInt(xs[0][1], 2, "nested index xs[0][1]")
  assertEqualInt(xs[1][2], 5, "nested index xs[1][2]")
  assertEqualInt(xs[2][0], 6, "nested index xs[2][0]")
}
