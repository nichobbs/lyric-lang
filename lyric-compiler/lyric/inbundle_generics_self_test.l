//! inbundle_generics_self_test.l — executable regression test for in-bundle
//! generic *records* in the self-hosted MSIL backend (#2362, docs/43).
//!
//! Why this lives here and not in `lyric-stdlib/tests/*_tests.l`: those files
//! are compiled by the F# stage-0 emitter, which erases in-bundle generic
//! types entirely.  The self-hosted MSIL backend now emits a `record Box[T]`
//! as a *truly generic* TypeDef — GenericParam metadata rows (table 0x2A) +
//! VAR-typed fields (`value: T` → `FIELD VAR(0)`) + AutoLayout — and routes
//! construction through a closed-instantiation TypeSpec `.ctor` MemberRef and
//! field reads through a TypeSpec-parented `ldfld` (a direct MethodDef/FieldDef
//! token on a generic TypeDef faults at load with a TypeLoadException).  This
//! is the make-or-break load test for that wire format: a malformed generic
//! TypeDef fails at *load*, so a green run proves the GenericParam serializer,
//! the VAR field signatures, and the by-name generic instructions are correct.
//!
//! Run via the native `lyric test`, which synthesises a program from the
//! `test` blocks and compiles it in-process through the self-hosted
//! `Msil.Bridge`, then executes it and asserts every runtime value:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/inbundle_generics_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//! Scope: in-bundle generic RECORDS.  In-bundle generic UNIONS (the nullary
//! case-singleton / per-instantiation static-field interaction, Q-GEN-001 in
//! docs/43) are a tracked follow-up and are NOT exercised here.
@test_module
package Lyric.InbundleGenericsSelfTest

import Std.Core
import Std.Testing

// A generic record with a single type-parameter field: `value: T` lowers to
// `FIELD VAR(0)` and the TypeDef carries one GenericParam row.
record Box[T] {
  value: T
}

// Two type parameters: `first: A` → VAR(0), `second: B` → VAR(1); two
// GenericParam rows, numbered 0 and 1.
record Pair[A, B] {
  first: A
  second: B
}

// Mixed: a type-parameter field (VAR(0)) alongside a concrete primitive field
// (`tag: String` → `FIELD String`), so the ctor signature interleaves a VAR and
// a concrete element type.
record Tagged[T] {
  value: T
  tag: String
}

// Function whose parameter and return reference an in-bundle generic
// instantiation, exercising the signature-encoding path
// (`Box[Int]` → GENERICINST CLASS <TypeDef> Int32 in the method sig).
func unboxInt(b: in Box[Int]): Int {
  b.value
}

test "Box[Int] constructs and reads its generic field" {
  val b = Box(value = 5)
  assertEqualInt(b.value, 5, "Box[Int].value")
}

test "Box[Long] reads a 64-bit generic field" {
  val b = Box(value = 42i64)
  assertEqualLong(b.value, 42i64, "Box[Long].value")
}

test "Box[String] reads a reference-typed generic field" {
  val b = Box(value = "hello")
  assertEqual(b.value, "hello", "Box[String].value")
}

test "Box[Bool] reads a value-typed generic field" {
  val b = Box(value = true)
  assertTrue(b.value, "Box[Bool].value")
}

test "Pair[Int, String] reads both generic fields" {
  val p = Pair(first = 7, second = "seven")
  assertEqualInt(p.first, 7, "Pair.first")
  assertEqual(p.second, "seven", "Pair.second")
}

test "Tagged[Int] interleaves a VAR field and a concrete String field" {
  val t = Tagged(value = 99, tag = "answer")
  assertEqualInt(t.value, 99, "Tagged.value")
  assertEqual(t.tag, "answer", "Tagged.tag")
}

test "generic record flows through a function signature" {
  val b = Box(value = 11)
  assertEqualInt(unboxInt(b), 11, "unboxInt(Box[Int])")
}

test "nested generic Box[Box[Int]] round-trips" {
  val inner = Box(value = 3)
  val outer = Box(value = inner)
  assertEqualInt(outer.value.value, 3, "Box[Box[Int]].value.value")
}
