//! record_field_closure_self_test.l — regression test for #5511: a closure
//! stored in a record field, invoked later through an inferred local
//! binding (`val fld = h.f; val v = fld()`), returned a corrupted value for
//! `Long`-returning closures once the result flowed into arithmetic (`Int`
//! only "looked" correct because `.toString()` on the still-boxed value
//! dispatches virtually and prints the right thing regardless).
//!
//! Root cause: `Msil.Codegen`'s uniform-ABI local-invoke path
//! (`fctx.funcValRetTypes`) only registers a function-valued local's real
//! return type when the BINDING carries a literal `(A,...) -> R` type
//! annotation (`LBLet`/`LBVar` — and, critically, `val` bindings parse as
//! `LBVal`, which had NO such registration at all). `val fld = h.f` has no
//! annotation of its own, so the invoke site fell back to `MObject` and
//! never unboxed the `Func::Invoke` result — harmless for `.toString()`,
//! corrupting for arithmetic (the general class of bug tracked in #5366).
//!
//! Fixed by `recordFieldFuncKeyMsil`/`registerFieldFuncValTypesMsil`: when a
//! local binds directly from a record-field read whose field was declared
//! function-typed, pull the field's real return/param types (recorded at
//! record registration time in `cctx.fieldFuncRetTypes`/
//! `fieldFuncParamTypes`) and register them for the binding — wired into
//! all three binding forms (`LBVal`, `LBLet`, `LBVar`).
//!
//!   lyric test lyric-compiler/lyric/record_field_closure_self_test.l
@test_module
package Lyric.RecordFieldClosureSelfTest

import Std.Core
import Std.Testing

record LongHolder {
  f: () -> Long
}

record IntHolder {
  f: () -> Int
}

record TwoFieldHolder {
  a: () -> Long
  b: () -> Int
}

test "#5511: Long closure in a record field survives arithmetic on its result" {
  val h = LongHolder(f = { -> 1234567890123i64 })
  val fld = h.f
  val v = fld()
  val v2 = v + 1i64
  assertEqualLong(v2, 1234567890124i64, "Long closure result should be usable in arithmetic without corruption")
}

test "#5511: Int closure in a record field survives arithmetic on its result" {
  val h = IntHolder(f = { -> 42 })
  val fld = h.f
  val v = fld()
  val v2 = v + 1
  assertEqualInt(v2, 43, "Int closure result should be usable in arithmetic without corruption")
}

test "#5511: two function-typed fields on the same record both invoke correctly" {
  val h = TwoFieldHolder(a = { -> 1234567890123i64 }, b = { -> 99 })
  val fa = h.a
  val fb = h.b
  val va = fa()
  val vb = fb()
  assertEqualLong(va + 1i64, 1234567890124i64, "first field's Long closure result should be correct")
  assertEqualInt(vb + 1, 100, "second field's Int closure result should be correct")
}

test "#5511: Long closure in a record field works via a var binding too" {
  val h = LongHolder(f = { -> 1234567890123i64 })
  var fld = h.f
  val v = fld()
  assertEqualLong(v + 1i64, 1234567890124i64, "var-bound Long closure result should be usable in arithmetic")
}
