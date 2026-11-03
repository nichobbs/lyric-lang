//! tir_self_test.l - Lyric.Tir: the type language and the data model (docs/70
//! §6.2, D319).
//!
//! `Ty` equality treats nothing as a wildcard, `Self` of an interface is a
//! parameter, and a TIR function (generic identity) can be built by hand with
//! every type, callee and conversion explicit.
@test_module
package Lyric.TirSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir

func sym(n: in Int): SymbolId {
  SymbolId(id = n)
}

func nid(n: in Int): NodeId {
  NodeId(id = n)
}

func tys(a: in Ty): List[Ty] {
  val xs: List[Ty] = newList()
  xs.add(a)
  xs
}

func expr(n: in Int, ty: in Ty, kind: in TExprKind): TExpr {
  TExpr(id = nid(n), ty = ty, span = noSourceSpan(), kind = kind)
}

test "a parameter equals only the same parameter" {
  assertTrue(tyEq(TParam(owner = sym(1), index = 0), TParam(owner = sym(1), index = 0)), "same")
  assertFalse(tyEq(TParam(owner = sym(1), index = 0), TParam(owner = sym(1), index = 1)), "index")
  assertFalse(tyEq(TParam(owner = sym(1), index = 0), TParam(owner = sym(2), index = 0)), "owner")
  assertFalse(tyEq(TParam(owner = sym(1), index = 0), tyInt()), "not a wildcard for Int")
  assertFalse(tyEq(tyInt(), TParam(owner = sym(1), index = 0)), "Int is not a wildcard for a parameter")
}

test "a named type equals its symbol at the same arguments" {
  assertTrue(tyEq(TNamed(sym = sym(7), args = tys(tyInt())), TNamed(sym = sym(7), args = tys(tyInt()))), "same")
  assertFalse(tyEq(TNamed(sym = sym(7), args = tys(tyInt())), TNamed(sym = sym(7), args = tys(tyString()))), "argument")
  assertFalse(tyEq(TNamed(sym = sym(7), args = newList()), TNamed(sym = sym(8), args = newList())), "symbol")
  assertFalse(tyEq(TNamed(sym = sym(7), args = tys(tyInt())), TNamed(sym = sym(7), args = newList())), "arity")
}

test "a refinement is not its underlying type" {
  val r09 = TRefined(underlying = tyInt(), lo = Some(0i64), hi = Some(9i64), hiInclusive = true)
  val r09b = TRefined(underlying = tyInt(), lo = Some(0i64), hi = Some(9i64), hiInclusive = true)
  val r010 = TRefined(underlying = tyInt(), lo = Some(0i64), hi = Some(10i64), hiInclusive = true)
  val r09x = TRefined(underlying = tyInt(), lo = Some(0i64), hi = Some(9i64), hiInclusive = false)
  assertTrue(tyEq(r09, r09b), "same bounds")
  assertFalse(tyEq(r09, r010), "different upper bound")
  assertFalse(tyEq(r09, r09x), "different inclusivity")
  assertFalse(tyEq(r09, tyInt()), "needs an explicit CvUnrefine")
}

test "function types compare modes, results and asyncness" {
  val ps = TParamTy(mode = TMIn, ty = tyInt())
  val pl: List[TParamTy] = newList()
  pl.add(ps)
  val pl2: List[TParamTy] = newList()
  pl2.add(TParamTy(mode = TMInout, ty = tyInt()))
  assertTrue(
    tyEq(TFunc(params = pl, ret = tyBool(), isAsync = false), TFunc(params = pl, ret = tyBool(), isAsync = false)),
    "same"
  )
  assertFalse(
    tyEq(TFunc(params = pl, ret = tyBool(), isAsync = false), TFunc(params = pl2, ret = tyBool(), isAsync = false)),
    "mode"
  )
  assertFalse(
    tyEq(TFunc(params = pl, ret = tyBool(), isAsync = false), TFunc(params = pl, ret = tyInt(), isAsync = false)),
    "result"
  )
  assertFalse(
    tyEq(TFunc(params = pl, ret = tyBool(), isAsync = false), TFunc(params = pl, ret = tyBool(), isAsync = true)),
    "async"
  )
}

test "arrays, slices, tuples, nullables and host types" {
  assertTrue(tyEq(TArray(len = ALKnown(3), element = tyInt()), TArray(len = ALKnown(3), element = tyInt())), "array")
  assertFalse(tyEq(TArray(len = ALKnown(3), element = tyInt()), TArray(len = ALKnown(4), element = tyInt())), "length")
  assertFalse(tyEq(TArray(len = ALKnown(3), element = tyInt()), TArray(len = ALUnsized, element = tyInt())), "unsized")
  assertTrue(
    tyEq(
      TArray(len = ALParam(owner = sym(2), index = 1), element = tyInt()),
      TArray(len = ALParam(owner = sym(2), index = 1), element = tyInt())
    ),
    "value parameter length"
  )
  assertFalse(tyEq(TSlice(element = tyInt()), TArray(len = ALUnsized, element = tyInt())), "slice vs array")
  assertFalse(tyEq(TNullable(inner = tyInt()), tyInt()), "nullable vs plain")
  assertTrue(tyEq(TTuple(elems = tys(tyInt())), TTuple(elems = tys(tyInt()))), "tuple")
  assertFalse(tyEq(TTuple(elems = tys(tyInt())), TTuple(elems = newList())), "tuple arity")
  val m1 = TExtern(host = HostTypeRef(name = "System.Math", args = newList()))
  val m2 = TExtern(host = HostTypeRef(name = "System.Math", args = newList()))
  val m3 = TExtern(host = HostTypeRef(name = "System.Text.StringBuilder", args = newList()))
  assertTrue(tyEq(m1, m2), "one host type")
  assertFalse(tyEq(m1, m3), "two host types")
  assertFalse(tyEq(TNever, tyUnit()), "Never is not Unit")
}

test "Self of an interface is a parameter of that interface" {
  val selfTy = tySelfOf(sym(5))
  assertTrue(tyEq(selfTy, TParam(owner = sym(5), index = selfParamIndex())), "self param")
  assertFalse(tyEq(selfTy, tySelfOf(sym(6))), "another interface")
  assertFalse(tyEq(selfTy, TParam(owner = sym(5), index = 0)), "not the first generic parameter")
}

test "types render for diagnostics" {
  assertEqual(renderTy(tyInt()), "Int", "prim")
  assertEqual(renderTy(TNullable(inner = tyString())), "String?", "nullable")
  assertEqual(renderTy(TNamed(sym = sym(7), args = tys(tyInt()))), "#7[Int]", "named")
  assertEqual(renderTy(TSlice(element = tyBool())), "slice[Bool]", "slice")
  assertEqual(renderTy(TArray(len = ALKnown(3), element = tyInt())), "array[3, Int]", "array")
  assertEqual(renderTy(TNever), "Never", "never")
  assertEqual(
    renderTy(TRefined(underlying = tyInt(), lo = Some(0i64), hi = None, hiInclusive = true)),
    "Int range 0 ..= MAX",
    "refined"
  )
}

test "a generic identity function is expressible with every type explicit" {
  val f = sym(10)
  val tp = TParam(owner = f, index = 0)
  val x = LocalId(id = 1)
  val tparams: List[TTypeParam] = newList()
  tparams.add(TTypeParam(name = "T", bounds = newList(), valueTy = None))
  val params: List[TParamDecl] = newList()
  params.add(TParamDecl(local = LocalDecl(id = x, name = "x", ty = tp, mutable = false), mode = TMIn, dflt = None))
  val body = expr(2, tp, XLocal(local = x))
  val fn = TFnDecl(
    sym = f,
    typeParams = tparams,
    params = params,
    ret = tp,
    isAsync = false,
    preconds = newList(),
    postconds = newList(),
    body = Some(body),
    span = noSourceSpan()
  )
  assertEqualInt(fn.params.count, 1, "one parameter")
  assertTrue(tyEq(fn.params[0].local.ty, fn.ret), "identity returns its parameter's type")
  match fn.body {
    case Some(b) -> assertTrue(tyEq(b.ty, tp), "body type")
    case None -> assertTrue(false, "body present")
  }
}

test "a call carries its callee, instantiation and moded arguments" {
  val g = sym(11)
  val one = expr(3, tyInt(), XLit(lit = TLInt(value = 1i64)))
  val args: List[TArg] = newList()
  args.add(TArgIn(value = one))
  val call = expr(4, tyInt(), XCall(callee = Direct(sym = g, typeArgs = tys(tyInt())), args = args))
  match call.kind {
    case XCall(Direct(s, targs), a) -> {
      assertEqualInt(s.id, 11, "callee symbol")
      assertEqualInt(targs.count, 1, "type argument")
      assertEqualInt(a.count, 1, "argument")
    }
    case _ -> assertTrue(false, "an XCall to a Direct callee")
  }
  val widened = expr(5, TPrim(TPLong), XConvert(kind = CvWiden(to = TPLong), inner = one))
  assertEqual(renderTy(widened.ty), "Long", "the widening is a node with its own type")
}
