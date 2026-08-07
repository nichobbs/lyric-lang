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

// #6233: a generic record's field must be readable through a record PATTERN
// (`case Box{value} -> ...`), not just plain member access (`b.value`).  The
// match-lowering's test/bind paths must cast the scrutinee through a closed
// GENERICINST TypeSpec (`MCastclassGeneric`/`MLdfldGeneric`), mirroring the
// plain-field-read path — a bare `MCastclassByName` against the open generic
// TypeDef faulted at JIT with `TypeLoadException: Could not load type
// 'Ns.Box`1'`.
test "#6233: Box[Int] record-pattern match extracts its generic field" {
  val b = Box(value = 5)
  match b {
    case Box { value } -> assertEqualInt(value, 5, "Box{value} extracted 5")
  }
}

record Rect6233 {
  w: Int
  h: Int
}

test "#6233: generic record instantiated with a user record type constructs and reads its field" {
  val b = Box(value = Rect6233(w = 3, h = 4))
  assertEqualInt(b.value.w, 3, "Box[Rect6233].value.w")
  assertEqualInt(b.value.h, 4, "Box[Rect6233].value.h")
}

test "#6233: Box[Rect6233] record-pattern match extracts a user-record-typed generic field" {
  val b = Box(value = Rect6233(w = 3, h = 4))
  match b {
    case Box { value } -> assertEqualInt(value.w * value.h, 12, "Box{value}.w * value.h == 12")
  }
}

// #6231: a generic record's field type may itself be ANOTHER generic
// instantiation over the SAME enclosing type parameters (`res: Result[T, E]`
// on `Holder[T, E]`), not just a bare parameter (`value: T`). Reading such a
// field previously returned the OPEN generic form (`Result<T,E>`, with
// dangling type-var references) as its static codegen type instead of
// substituting the instantiation's concrete `typeArgs` — downstream generic
// dispatch (e.g. `isOk`) then specialised against the wrong (unsubstituted)
// shape.  `match h.res { ... }` directly on such a field crashed the same way
// (`InvalidProgramException` / `MissingFieldException` depending on shape) —
// both plain field access AND match are covered here; the match crash was the
// deeper half of the same #4870 family (registration never carried the
// nested `MTypeVar` through to `fieldMsilTypes`, so both the field-read
// substitution and the match scrutinee's isinst/pattern-bind TypeSpec
// inherited the same corrupt open shape).
record Holder6231[T, E] {
  res: Result[T, E]
}

func makeHolder6231(): Holder6231[Int, String] {
  val r: Result[Int, String] = Ok(value = 42)
  Holder6231(res = r)
}

test "#6231: generic record field typed by a nested Result[T,E] substitutes concrete args on read" {
  val h = makeHolder6231()
  val r = h.res
  assertTrue(isOk(r), "isOk(h.res) after substitution")
}

test "#6231: match on a generic record field typed by a nested Result[T,E]" {
  val h = makeHolder6231()
  val v = match h.res { case Ok(value) -> value; case Err(_) -> -1 }
  assertEqualInt(v, 42, "match h.res { Ok(value) -> value }")
}

// #4870: a UNION CASE's field type may itself be a USER GENERIC RECORD
// instantiated over the union's OWN type parameter (`left: Box[T]`,
// `right: Box[T]` on `Tree4870[T]`), not just a bare parameter
// (`value: T`, exercised by `Maybe`/`Either` above) or a STDLIB generic
// (`Result[T, E]`, exercised by `Holder6231` above).  Registering such a
// field's type via the generics-blind `typeExprToMsilCtx` resolved the
// nested `T` as an unrecognised same-package identifier (`MClass("Pkg.T")`)
// instead of `MTypeVar` — corrupting both the case class's own FieldDef
// signature (MSIL: MissingFieldException) and the type-argument INFERENCE at
// the case's construction site (which could never pin `T` from a `Box[T]`-
// typed argument, defaulting the enclosing generic to Object and mismatching
// the reified value the CLR actually holds — InvalidProgramException).  This
// also exercises the shape through a SAME-PACKAGE monomorphized generic
// function (`rightItem[T]`), the exact #4870 repro.
union Tree4870[T] {
  case Leaf4870(value: T)
  case Branch4870(left: Box[T], right: Box[T])
}

func rightItem4870[T](t: in Tree4870[T], d: in T): T {
  match t {
    case Leaf4870(v) -> v
    case Branch4870(_, r) -> r.value
  }
}

test "#4870: union case field typed by a nested Box[T] constructs" {
  val t = Branch4870(left = Box(value = 10), right = Box(value = 20))
  match t {
    case Leaf4870(_) -> assertTrue(false, "unreachable")
    case Branch4870(l, r) -> {
      assertEqualInt(l.value, 10, "Branch4870.left.value")
      assertEqualInt(r.value, 20, "Branch4870.right.value")
    }
  }
}

test "#4870: union case field typed by a nested Box[T] flows through a monomorphized generic function" {
  val t = Branch4870(left = Box(value = 10), right = Box(value = 20))
  val v = rightItem4870(t, 0)
  assertEqualInt(v, 20, "rightItem4870(Branch4870(Box(10), Box(20)), 0)")
}

test "#4870: Leaf4870 (bare-T case) still matches alongside the Box[T] case" {
  val t: Tree4870[Int] = Leaf4870(value = 7)
  val v = rightItem4870(t, 0)
  assertEqualInt(v, 7, "rightItem4870(Leaf4870(7), 0)")
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

test "nested generic union Maybe[Maybe[Int]] round-trips" {
  val outer: Maybe[Maybe[Int]] = Just(value = Just(value = 9))
  val r = match outer { case Just(mi) -> match mi { case Just(v) -> v; case Nothing -> -1 }; case Nothing -> -2 }
  assertEqualInt(r, 9, "nested Just(Just(9))")
}

// #2585: bare nullary generic case as a call argument without annotation.
// When the only available type hint comes from the callee's parameter type
// (`m: in Maybe[Int]`) rather than an LBVal/LBVar annotation or a declared
// return type, the MGenericInstByName inference path is not yet taken — the
// nullary case constructs as the uninstantiated `Maybe_Nothing`1` and the
// `isinst` for the match arm silently misses.  The workaround is an explicit
// `val` annotation so the hint flows via LBVal instead of the call-arg path.
// This test documents the current constraint and will become redundant once
// the call-arg hint path is implemented.
test "#2585: bare nullary Nothing via annotated val workaround roundtrips" {
  val n: Maybe[Int] = Nothing
  assertEqualInt(unwrapOr(n, 0), 0, "annotated-val Nothing -> default 0")
}

test "#2585: bare Just as call argument without annotation" {
  assertEqualInt(unwrapOr(Just(value = 7), 0), 7, "bare Just(7) -> 7")
}

// #2587: Pairish[Int, String] — heterogeneous type parameters.
// Confirms that VAR(0) (field `a: A`) and VAR(1) (field `b: B`) are
// independently resolved to the closed-instantiation types `Int` and `String`
// respectively (rather than sharing the same type argument or being mixed up).
test "#2587: Pairish[Int,String] Both keeps fields independently typed" {
  val p: Pairish[Int, String] = Both(a = 10, b = "hello")
  assertEqualInt(match p { case Both(n, _) -> n; case Neither -> -1 }, 10, "Pairish[Int,String] a field")
  assertEqual(match p { case Both(_, s) -> s; case Neither -> "x" }, "hello", "Pairish[Int,String] b field")
}

test "#2587: Pairish[Int,String] Neither still matches the nullary case" {
  val p: Pairish[Int, String] = Neither
  assertEqualInt(match p { case Both(n, _) -> n; case Neither -> -9 }, -9, "Pairish[Int,String] Neither")
}
