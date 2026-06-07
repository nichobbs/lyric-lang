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
//! Scope: in-bundle generic RECORDS and UNIONS.  Unions exercise the case-class
//! hierarchy (each case extends the open base instantiation `Maybe`1<!0>` via a
//! TypeSpec, with TypeSpec-parented base-`.ctor` calls), nullary cases
//! (constructed via `newobj` each time — no per-instantiation singleton,
//! Q-GEN-001), construction + `match` (isinst / castclass / ldfld on closed
//! case TypeSpecs), and partial type-argument inference from the value's
//! declared type.
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

// ─────────────────────────────────────────────────────────────────────────────
// In-bundle generic UNIONS (#2362).  Each case is a generic case class extending
// the open base instantiation; nullary cases carry the union's type parameters
// and are constructed via `newobj` each time (no singleton — Q-GEN-001).
// ─────────────────────────────────────────────────────────────────────────────
// Single-parameter union with a payload case and a nullary case (the Option shape).
union Maybe[T] {
  case Just(value: T)
  case Nothing
}

// Two-parameter union: each case re-declares both parameters (`Either_Lft`2`,
// `Either_Rgt`2`), and a case pins only one of them so the other is inferred
// from the value's declared type.
union Either[L, R] {
  case Lft(l: L)
  case Rgt(r: R)
}

// A multi-field generic case (`Both(a: A, b: B)`): the value-type instantiation
// `Pairish[Int, Int]` exercises the arity-suffixed name + open-self-TypeSpec
// ctor `stfld` that keep both fields at the correct per-instantiation offset.
union Pairish[A, B] {
  case Both(a: A, b: B)
  case Neither
}

func unwrapOr(m: in Maybe[Int], dflt: in Int): Int {
  match m {
    case Just(v) -> v
    case Nothing -> dflt
  }
}

func mkNothing(): Maybe[Int] {
  Nothing
}

func getOrDefault[T](m: in Maybe[T], dflt: in T): T {
  match m {
    case Just(v) -> v
    case Nothing -> dflt
  }
}

test "Maybe[Int] Just constructs and matches its payload" {
  assertEqualInt(unwrapOr(Just(value = 5), 0), 5, "Just(5)")
}

test "Maybe[Int] Nothing matches (nullary, no singleton)" {
  val m: Maybe[Int] = Nothing
  assertEqualInt(unwrapOr(m, 99), 99, "Nothing")
}

test "Maybe Nothing returned from a function matches" {
  assertEqualInt(unwrapOr(mkNothing(), 7), 7, "mkNothing()")
}

test "Bare nullary case as call argument (Nothing without annotation)" {
  assertEqualInt(getOrDefault(Nothing, 42), 42, "Nothing infers [Int]")
  assertEqual(getOrDefault(Nothing, "default"), "default", "Nothing infers [String]")
}

test "Maybe[String] Just binds a reference payload" {
  val m = Just(value = "hi")
  val r = match m { case Just(s) -> s; case Nothing -> "none" }
  assertEqual(r, "hi", "Just(hi)")
}

test "Either[Int,String] infers the unpinned parameter from the annotation" {
  val a: Either[Int, String] = Lft(l = 7)
  val b: Either[Int, String] = Rgt(r = "x")
  assertEqualInt(match a { case Lft(n) -> n; case Rgt(_) -> -1 }, 7, "Lft 7")
  assertEqual(match b { case Lft(_) -> "L"; case Rgt(s) -> s }, "x", "Rgt x")
}

test "Pairish[Int,Int] multi-field value-type case keeps both fields" {
  val p: Pairish[Int, Int] = Both(a = 3, b = 4)
  assertEqualInt(match p { case Both(x, y) -> x + y; case Neither -> 0 }, 7, "Both 3 4")
}

test "Pairish Neither (nullary of a two-parameter union)" {
  val p: Pairish[Int, Int] = Neither
  assertEqualInt(match p { case Both(x, y) -> x + y; case Neither -> -5 }, -5, "Neither")
}

test "Pairish[Int,String] covers heterogeneous type-parameter VAR indices" {
  val p: Pairish[Int, String] = Both(a = 42, b = "answer")
  val result = match p {
    case Both(x, y) -> x.toText() + ": " + y
    case Neither -> "empty"
  }
  assertEqual(result, "42: answer", "Both 42 answer")
}

test "nested generic union Maybe[Maybe[Int]] round-trips" {
  val outer: Maybe[Maybe[Int]] = Just(value = Just(value = 9))
  val r = match outer { case Just(mi) -> match mi { case Just(v) -> v; case Nothing -> -1 }; case Nothing -> -2 }
  assertEqualInt(r, 9, "nested Just(Just(9))")
}
