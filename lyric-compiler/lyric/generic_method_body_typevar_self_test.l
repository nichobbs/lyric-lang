//! generic_method_body_typevar_self_test.l — dual-target runtime regression
//! test for a BODY-local `val`/`var`/`let` type annotation naming the
//! enclosing generic record/union's own type parameter (#7695, #7705).
//!
//! Inside a method of a generic record (`Box[T]`), the method's own
//! params/return/`self.<field>` reads already resolve a bare `T` correctly
//! on both targets — `lowerRecordMethodMsil` (dotnet) reifies it as the real
//! CLR generic parameter `MTypeVar`/`!0` (docs/43), and `lowerRecordMethod`
//! (jvm) erases it to `Object` (JVM has no reified generics, docs/44 M-1).
//! But neither backend threaded that same resolution into BODY-local type
//! annotations: `var x: T`, `val y: T = ...`, a `List[T]`/`Option[T]` local
//! annotation.
//!
//! On `--target dotnet`, `typeExprToMsilBodyCtx` (`lyric-compiler/msil/
//! codegen.l`) only consulted `FuncCtx.generics` — a generic FUNCTION's own
//! type params, erased to `MObject` via `typeExprToMsilGenBody` — which a
//! record/union method never populates. A body annotation naming `T` fell
//! through to `typeExprToMsilCtx`'s catch-all, which treats a bare
//! unqualified name as an in-package class reference: `MClass("<pkg>.T")`, a
//! type that does not exist. The emitted local's `.locals` signature then
//! disagreed with the real `!0`-typed value flowing from `self.value` /
//! params — `ilverify` reports `StackUnexpected ... found Int32 ...
//! expected ref 'object'` in `Box`1::pick` (the program still ran: the CLR
//! JIT does not itself verify CIL at load time, so this was silent until
//! caught by `ilverify`). Fixed by adding a new `FuncCtx.reifiedGenerics`
//! field — set by `lowerRecordMethodMsil` to the enclosing type's own
//! generic-parameter names — that `typeExprToMsilBodyCtx` prefers over
//! `fctx.generics`, resolving through the VAR-form-aware `typeExprToMsilG`
//! (the same helper the method's signature and fields already use) instead
//! of the MObject-erasing `typeExprToMsilGenBody`.
//!
//! On `--target jvm`, `localAnnotatedJvmType` (`lyric-compiler/jvm/codegen/
//! 05_stmts.l`) resolved a body annotation via the typeParams-BLIND
//! `typeExprToJvmExtern`, so a bare `T` resolved as an unqualified in-package
//! class reference too (`<pkg>/T`) — a class that is never emitted, so the
//! JVM verifier's class loader crashed with `NoClassDefFoundError: <pkg>/T`
//! the first time the method ran (not at compile time — the JVM loads a
//! referenced class lazily, the first time a `checkcast`/`new`/etc.
//! targeting it actually executes). Fixed by threading the method's own
//! type-parameter names (already computed by `lowerRecordMethod` for its own
//! params/return, `typeExprToJvmErasedExtern`) through a new
//! `FuncCtx.typeParams` field into `localAnnotatedJvmType`, so it resolves
//! `T` the SAME typeParams-aware way the method's own signature already does
//! — erasing to `Object` (JVM has no reified generics for any type, concrete
//! or parameter, so no further box/unbox distinction is needed the way the
//! MSIL fix above needs `MTypeVar`).
//!
//! `Box[T].pick` is the ORIGINAL issue repro shape: a no-initialiser `var x: T`
//! assigned on both branches of an `if`/`else` (the no-init `LBVar` path
//! added by #7691's `pushDefaultValueMsil`/`MTypeVar` arm must still be
//! reachable through the now-correctly-resolved annotation type).
//! `Box[T].fromField` covers a `val y: T = self.value` WITH-initialiser
//! annotation. `Box[T].firstOfTwo` covers a `List[T]` local annotation;
//! `Box[T].maybeSelf` an `Option[T]` local annotation (both nested-generic
//! annotation shapes docs/43's `typeExprToMsilG`/`typeExprToMsilGApp` already
//! handle for FIELDS — this file exercises them reachable from a BODY local
//! too). `Box[T].captureThenReturn` is the closure case #7690's tests
//! deferred to this issue (see `method_closure_var_capture_self_test.l`'s
//! own header note): a closure capturing (and reassigning) a `var x: T`
//! declared inside a generic record method — on dotnet this additionally
//! exercises the hoisted-cell `box`/`unbox.any` fix `boxIfNeededMsil`/
//! `castObjectToMsil` needed for an open `MTypeVar` element (#7695), since
//! `T` may be instantiated with a value type (`Int`) where the cell's
//! storage erases to `object[]`.
//!
//! `Box[T].closureLocals` and `Box[T].tupleSecond`/`tupleFirst` cover the two
//! remaining annotation sites #7705 found. An annotation declared INSIDE a
//! closure body: the lifted closure is a separate function, so on jvm its
//! fresh `FuncCtx` lacked the enclosing method's `typeParams`
//! (`NoClassDefFoundError: <pkg>/T`), and on dotnet the lifted `__lambda_*`
//! (a static method of the non-generic package class) resolved `T` as a
//! nonexistent in-package class that only happened to encode as `object`;
//! both now erase `T` to `object`/`Object` there. A tuple-pattern annotation
//! `val (p, q): (T, T)`: jvm resolved each element typeParams-blind (the same
//! `NoClassDefFoundError`), and dotnet's `typeExprToMsilG` had no tuple arm,
//! so each element was `castclass`ed to the nonexistent class (dropped with
//! W0003) and a boxed `Int` element was read back as a raw pointer.
//!
//! Every case below is instantiated with a value type (`Int`), a reference
//! type (`String`), and an in-bundle record (`Pair`), per the issue's test
//! matrix.
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_method_body_typevar_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generic_method_body_typevar_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GenericMethodBodyTypevarSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Pair {
  a: Int
  b: String
}

record Box[T] {
  value: T

  // The original #7695 repro shape: a no-initialiser `var x: T` assigned on
  // both branches of an `if`/`else`.
  func pick(useValue: in Bool, other: in T): T {
    var x: T
    if useValue {
      x = self.value
    } else {
      x = other
    }
    x
  }

  // `val y: T = self.value` — a WITH-initialiser body annotation.
  func fromField(): T {
    val y: T = self.value
    y
  }

  // `List[T]` local annotation.
  func firstOfTwo(other: in T): T {
    val xs: List[T] = newList()
    xs.add(self.value)
    xs.add(other)
    xs[0]
  }

  // `Option[T]` local annotation.
  func maybeSelf(present: in Bool): Option[T] {
    val o: Option[T] = if present { Some(value = self.value) } else { None }
    o
  }

  // A closure capturing (and reassigning) a `var x: T` local — #7690's
  // deferred generic-record-method case.
  func captureThenReturn(other: in T): T {
    var x: T = self.value
    val f = { -> x = other }
    f()
    x
  }

  // Annotations naming `T` declared INSIDE a closure body (#7705): a
  // no-initialiser `var z: T` and a `List[T]` local.
  func closureLocals(useOther: in Bool, other: in T): T {
    var r: T = self.value
    val f = { -> var z: T; if useOther { z = other } else { z = r }; val zs: List[T] = newList(); zs.add(z); r = zs[0] }
    f()
    r
  }

  // A tuple-pattern annotation naming `T` (#7705).
  func tupleSecond(other: in T): T {
    val (p, q): (T, T) = (self.value, other)
    q
  }

  func tupleFirst(other: in T): T {
    val (p, q): (T, T) = (self.value, other)
    p
  }
}

test "Box[Int].pick: no-init var x: T assigned on both if/else branches" {
  val b = Box(value = 41)
  assertEqualInt(b.pick(true, 99), 41, "pick(true, 99) returns self.value")
  assertEqualInt(b.pick(false, 99), 99, "pick(false, 99) returns other")
}

test "Box[String].pick: no-init var x: T assigned on both if/else branches" {
  val b = Box(value = "hello")
  assertEqual(b.pick(true, "other"), "hello", "pick(true, other) returns self.value")
  assertEqual(b.pick(false, "other"), "other", "pick(false, other) returns other")
}

test "Box[Pair].pick: no-init var x: T assigned on both if/else branches" {
  val b = Box(value = Pair(a = 1, b = "one"))
  val other = Pair(a = 2, b = "two")
  val picked1 = b.pick(true, other)
  assertEqualInt(picked1.a, 1, "pick(true, other).a")
  assertEqual(picked1.b, "one", "pick(true, other).b")
  val picked2 = b.pick(false, other)
  assertEqualInt(picked2.a, 2, "pick(false, other).a")
  assertEqual(picked2.b, "two", "pick(false, other).b")
}

test "Box[Int].fromField: val y: T = self.value" {
  val b = Box(value = 7)
  assertEqualInt(b.fromField(), 7, "fromField() returns self.value")
}

test "Box[String].fromField: val y: T = self.value" {
  val b = Box(value = "abc")
  assertEqual(b.fromField(), "abc", "fromField() returns self.value")
}

test "Box[Pair].fromField: val y: T = self.value" {
  val b = Box(value = Pair(a = 5, b = "five"))
  val f = b.fromField()
  assertEqualInt(f.a, 5, "fromField().a")
  assertEqual(f.b, "five", "fromField().b")
}

test "Box[Int].firstOfTwo: List[T] local annotation" {
  val b = Box(value = 10)
  assertEqualInt(b.firstOfTwo(20), 10, "firstOfTwo(20) returns xs[0] == self.value")
}

test "Box[String].firstOfTwo: List[T] local annotation" {
  val b = Box(value = "first")
  assertEqual(b.firstOfTwo("second"), "first", "firstOfTwo(second) returns xs[0] == self.value")
}

test "Box[Pair].firstOfTwo: List[T] local annotation" {
  val b = Box(value = Pair(a = 3, b = "three"))
  val other = Pair(a = 4, b = "four")
  val first = b.firstOfTwo(other)
  assertEqualInt(first.a, 3, "firstOfTwo(other).a")
  assertEqual(first.b, "three", "firstOfTwo(other).b")
}

test "Box[Int].maybeSelf: Option[T] local annotation, Some branch" {
  val b = Box(value = 3)
  match b.maybeSelf(true) {
    case Some(v) -> assertEqualInt(v, 3, "maybeSelf(true) == Some(self.value)")
    case None -> assertTrue(false, "maybeSelf(true) should not be None")
  }
}

test "Box[Int].maybeSelf: Option[T] local annotation, None branch" {
  val b = Box(value = 3)
  match b.maybeSelf(false) {
    case Some(_) -> assertTrue(false, "maybeSelf(false) should not be Some")
    case None -> assertTrue(true, "maybeSelf(false) == None")
  }
}

test "Box[String].maybeSelf: Option[T] local annotation, Some branch" {
  val b = Box(value = "opt")
  match b.maybeSelf(true) {
    case Some(v) -> assertEqual(v, "opt", "maybeSelf(true) == Some(self.value)")
    case None -> assertTrue(false, "maybeSelf(true) should not be None")
  }
}

test "Box[Pair].maybeSelf: Option[T] local annotation, Some branch" {
  val b = Box(value = Pair(a = 8, b = "eight"))
  match b.maybeSelf(true) {
    case Some(v) -> {
      assertEqualInt(v.a, 8, "maybeSelf(true) -> Some(v).a")
      assertEqual(v.b, "eight", "maybeSelf(true) -> Some(v).b")
    }
    case None -> assertTrue(false, "maybeSelf(true) should not be None")
  }
}

test "Box[Int].captureThenReturn: closure captures and reassigns var x: T" {
  val b = Box(value = 1)
  assertEqualInt(b.captureThenReturn(2), 2, "captureThenReturn(2) returns the closure-reassigned value")
}

test "Box[String].captureThenReturn: closure captures and reassigns var x: T" {
  val b = Box(value = "old")
  assertEqual(b.captureThenReturn("new"), "new", "captureThenReturn(new) returns the closure-reassigned value")
}

test "Box[Pair].captureThenReturn: closure captures and reassigns var x: T" {
  val b = Box(value = Pair(a = 1, b = "one"))
  val other = Pair(a = 9, b = "nine")
  val r = b.captureThenReturn(other)
  assertEqualInt(r.a, 9, "captureThenReturn(other).a")
  assertEqual(r.b, "nine", "captureThenReturn(other).b")
}

test "Box[Int].closureLocals: var z: T and List[T] declared inside a closure" {
  val b = Box(value = 1)
  assertEqualInt(b.closureLocals(true, 2), 2, "closureLocals(true, 2)")
  assertEqualInt(b.closureLocals(false, 2), 1, "closureLocals(false, 2)")
}

test "Box[String].closureLocals: var z: T and List[T] declared inside a closure" {
  val b = Box(value = "mine")
  assertEqual(b.closureLocals(true, "theirs"), "theirs", "closureLocals(true, theirs)")
  assertEqual(b.closureLocals(false, "theirs"), "mine", "closureLocals(false, theirs)")
}

test "Box[Pair].closureLocals: var z: T and List[T] declared inside a closure" {
  val b = Box(value = Pair(a = 1, b = "one"))
  val r = b.closureLocals(true, Pair(a = 2, b = "two"))
  assertEqualInt(r.a, 2, "closureLocals(true, other).a")
  assertEqual(b.closureLocals(false, Pair(a = 2, b = "two")).b, "one", "closureLocals(false, other).b")
}

test "Box[Int].tupleSecond/tupleFirst: val (p, q): (T, T)" {
  val b = Box(value = 1)
  assertEqualInt(b.tupleSecond(2), 2, "tupleSecond(2)")
  assertEqualInt(b.tupleFirst(2), 1, "tupleFirst(2)")
}

test "Box[String].tupleSecond/tupleFirst: val (p, q): (T, T)" {
  val b = Box(value = "a")
  assertEqual(b.tupleSecond("b"), "b", "tupleSecond(b)")
  assertEqual(b.tupleFirst("b"), "a", "tupleFirst(b)")
}

test "Box[Pair].tupleSecond/tupleFirst: val (p, q): (T, T)" {
  val b = Box(value = Pair(a = 1, b = "one"))
  val other = Pair(a = 2, b = "two")
  assertEqualInt(b.tupleSecond(other).a, 2, "tupleSecond(other).a")
  assertEqual(b.tupleFirst(other).b, "one", "tupleFirst(other).b")
}
