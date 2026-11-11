//! llvm_tir_self_test.l - Lyric.LlvmTir: the native backend lowers hand-built
//! TIR (docs/70 phase 4a, D520).
//!
//! Each case builds a `TFnDecl` directly, lowers it, and asserts on the
//! rendered LLVM IR, or on the fallback reason for a function the slice does
//! not cover.  No checker is involved: this is the property that the lowering
//! reads TIR and nothing else.
//!
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_tir_self_test.l
@test_module
package Lyric.LlvmTirSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.LlvmTir

func sym(n: in Int): SymbolId {
  SymbolId(id = n)
}

func ex(n: in Int, ty: in Ty, kind: in TExprKind): TExpr {
  TExpr(id = NodeId(id = n), ty = ty, span = noSourceSpan(), kind = kind)
}

func intT(): Ty {
  TPrim(TPInt)
}

func local(id: in Int, name: in String, ty: in Ty, mutable: in Bool): LocalDecl {
  LocalDecl(id = LocalId(id = id), name = name, ty = ty, mutable = mutable)
}

func param(d: in LocalDecl): TParamDecl {
  TParamDecl(local = d, mode = TMIn, dflt = None)
}

func inArgs(a: in TExpr, b: in TExpr): List[TArg] {
  val xs: List[TArg] = newList()
  xs.add(TArgIn(value = a))
  xs.add(TArgIn(value = b))
  xs
}

func fnDecl(s: in Int, params: in List[TParamDecl], ret: in Ty, body: in TExpr): TFnDecl {
  TFnDecl(
    sym = sym(s),
    typeParams = newList(),
    params = params,
    ret = ret,
    isAsync = false,
    preconds = newList(),
    postconds = newList(),
    body = Some(body),
    span = noSourceSpan()
  )
}

func envOf(names: in List[String]): TirLowerEnv {
  val m: Map[Int, String] = newMap()
  var i = 0
  while i < names.count {
    m.add(100 + i, names[i])
    i = i + 1
  }
  TirLowerEnv(fnNames = m, panicFile = "P")
}

func render(r: in Result[TirLowered, TirFallback]): String {
  match r {
    case Ok(l) -> emitFuncDefn(l.fn)
    case Err(f) -> "FALLBACK: " + f.reason
  }
}

func addBody(a: in LocalDecl, b: in LocalDecl, op: in IntrinsicOp): TExpr {
  ex(
    3,
    intT(),
    XCall(
      callee = Intrinsic(op = op),
      args = inArgs(ex(1, intT(), XLocal(local = a.id)), ex(2, intT(), XLocal(local = b.id)))
    )
  )
}

test "an Int addition lowers to add i32 and ret i32" {
  val a = local(1, "a", intT(), false)
  val b = local(2, "b", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  ps.add(param(b))
  val names: List[String] = newList()
  names.add("P.add")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), addBody(a, b, IoAdd))))
  assertTrue(Str.contains(ir, "i32 @P.add(i32 %a1, i32 %a2)"), ir)
  assertTrue(Str.contains(ir, "add i32"), ir)
  assertTrue(Str.contains(ir, "ret i32"), ir)
}

test "division carries the zero and overflow guard and a panic" {
  val a = local(1, "a", intT(), false)
  val b = local(2, "b", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  ps.add(param(b))
  val names: List[String] = newList()
  names.add("P.div")
  val r = lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), addBody(a, b, IoDiv)))
  val ir = render(r)
  assertTrue(Str.contains(ir, "sdiv i32"), ir)
  assertTrue(Str.contains(ir, "lyric_panic_msg"), ir)
  match r {
    case Ok(l) -> {
      assertEqualInt(l.externs.count, 1, "the panic runtime declaration is reported")
      assertEqualInt(l.globals.count, 2, "the panic message and file are globals")
    }
    case Err(_) -> assertTrue(false, "lowered")
  }
}

test "an unsigned comparison uses the unsigned predicate" {
  val u = TPrim(TPUInt)
  val a = local(1, "a", u, false)
  val b = local(2, "b", u, false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  ps.add(param(b))
  val body = ex(
    3,
    tyBool(),
    XCall(
      callee = Intrinsic(op = IoLt),
      args = inArgs(ex(1, u, XLocal(local = a.id)), ex(2, u, XLocal(local = b.id)))
    )
  )
  val names: List[String] = newList()
  names.add("P.lt")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, tyBool(), body)))
  assertTrue(Str.contains(ir, "icmp ult i32"), ir)
  assertTrue(Str.contains(ir, "ret i1"), ir)
}

test "a while loop with a mutable local lowers to blocks and a store" {
  // func count(n: Int): Int { var i = 0; while i < n { i += 1 }; i }
  val n = local(1, "n", intT(), false)
  val i = local(2, "i", intT(), true)
  val ps: List[TParamDecl] = newList()
  ps.add(param(n))
  val zero = ex(10, intT(), XLit(lit = TLInt(value = 0i64)))
  val cond = ex(
    11,
    tyBool(),
    XCall(
      callee = Intrinsic(op = IoLt),
      args = inArgs(ex(12, intT(), XLocal(local = i.id)), ex(13, intT(), XLocal(local = n.id)))
    )
  )
  val one = ex(14, intT(), XLit(lit = TLInt(value = 1i64)))
  val step = ex(
    15,
    tyUnit(),
    XAssign(place = TPlace(ty = intT(), kind = PlLocal(local = i.id)), op = AkAdd, value = one)
  )
  val loopBody = ex(16, tyUnit(), XBlock(stmts = newList(), tail = Some(value = step)))
  val stmts: List[TStmt] = newList()
  stmts.add(TStmt(id = NodeId(id = 20), span = noSourceSpan(), kind = TsVar(decl = i, init = Some(value = zero))))
  stmts.add(
    TStmt(id = NodeId(id = 21), span = noSourceSpan(), kind = TsWhile(label = None, cond = cond, body = loopBody))
  )
  val body = ex(17, intT(), XBlock(stmts = stmts, tail = Some(value = ex(18, intT(), XLocal(local = i.id)))))
  val names: List[String] = newList()
  names.add("P.count")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), body)))
  assertTrue(Str.contains(ir, "alloca i32"), ir)
  assertTrue(Str.contains(ir, "icmp slt i32"), ir)
  assertTrue(Str.contains(ir, "while.cond"), ir)
  assertTrue(Str.contains(ir, "store i32"), ir)
  assertTrue(Str.contains(ir, "ret i32"), ir)
}

test "a direct call uses the IR name from the linkage table" {
  val a = local(1, "a", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  val args: List[TArg] = newList()
  args.add(TArgIn(value = ex(2, intT(), XLocal(local = a.id))))
  val call = ex(3, intT(), XCall(callee = Direct(sym = sym(101), typeArgs = newList()), args = args))
  val names: List[String] = newList()
  names.add("P.caller")
  names.add("P.callee")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), call)))
  assertTrue(Str.contains(ir, "call i32 @P.callee(i32"), ir)
}

test "a widening is an explicit sext" {
  val a = local(1, "a", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  val wide = ex(2, TPrim(TPLong), XConvert(kind = CvWiden(to = TPLong), inner = ex(1, intT(), XLocal(local = a.id))))
  val names: List[String] = newList()
  names.add("P.wide")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, TPrim(TPLong), wide)))
  assertTrue(Str.contains(ir, "sext i32"), ir)
  assertTrue(Str.contains(ir, "ret i64"), ir)
}

test "a function outside the slice falls back with the reason" {
  val lit = ex(1, tyString(), XLit(lit = TLString(text = "hi")))
  val names: List[String] = newList()
  names.add("P.s")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, newList(), tyString(), lit)))
  assertTrue(Str.startsWith(ir, "FALLBACK: "), ir)
}

test "a generic function and a function with no IR name fall back" {
  val a = local(1, "a", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  val body = ex(2, intT(), XLocal(local = a.id))
  val tps: List[TTypeParam] = newList()
  tps.add(TTypeParam(name = "T", bounds = newList(), valueTy = None))
  val genericFn = TFnDecl(
    sym = sym(100),
    typeParams = tps,
    params = ps,
    ret = intT(),
    isAsync = false,
    preconds = newList(),
    postconds = newList(),
    body = Some(value = body),
    span = noSourceSpan()
  )
  val names: List[String] = newList()
  names.add("P.g")
  assertEqual(render(lowerTirFunction(envOf(names), genericFn)), "FALLBACK: a generic function", "genericFn")
  val unnamed = render(lowerTirFunction(envOf(newList()), fnDecl(100, ps, intT(), body)))
  assertTrue(Str.startsWith(unnamed, "FALLBACK: no IR name"), unnamed)
}

func pat(n: in Int, ty: in Ty, kind: in TPatKind): TPat {
  TPat(id = NodeId(id = n), ty = ty, span = noSourceSpan(), kind = kind)
}

func arm(p: in TPat, guard: in Option[TExpr], body: in TExpr): TArm {
  TArm(pat = p, guard = guard, body = body)
}

func intLit(n: in Int, v: in Long): TExpr {
  ex(n, intT(), XLit(lit = TLInt(value = v)))
}

test "a match on Int lowers literals, ranges, guards and bindings to a phi" {
  val x = local(1, "x", intT(), false)
  val bound = local(2, "n", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(x))
  val arms: List[TArm] = newList()
  arms.add(arm(pat(10, intT(), TpLit(lit = TLInt(value = 1i64))), None, intLit(11, 10i64)))
  arms.add(
    arm(
      pat(12, intT(), TpRange(lo = TLInt(value = 2i64), hi = TLInt(value = 5i64), inclusive = true)),
      None,
      intLit(13, 20i64)
    )
  )
  val big = ex(
    14,
    tyBool(),
    XCall(
      callee = Intrinsic(op = IoGt),
      args = inArgs(ex(15, intT(), XLocal(local = bound.id)), intLit(16, 100i64))
    )
  )
  arms.add(
    arm(
      pat(17, intT(), TpBind(decl = bound, inner = None)),
      Some(value = big),
      ex(18, intT(), XLocal(local = bound.id))
    )
  )
  arms.add(arm(pat(19, intT(), TpWild), None, intLit(20, 0i64)))
  val m = ex(21, intT(), XMatch(scrutinee = ex(22, intT(), XLocal(local = x.id)), arms = arms, exhaustive = true))
  val names: List[String] = newList()
  names.add("P.m")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), m)))
  assertTrue(Str.contains(ir, "icmp eq i32"), ir)
  assertTrue(Str.contains(ir, "icmp sge i32"), ir)
  assertTrue(Str.contains(ir, "icmp sle i32"), ir)
  assertTrue(Str.contains(ir, "phi i32"), ir)
  assertTrue(Str.contains(ir, "match.end"), ir)
  assertTrue(Str.contains(ir, "[ undef, %dead"), "the panic block is a phi predecessor: " + ir)
}

test "a match not proved exhaustive falls back" {
  val x = local(1, "x", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(x))
  val arms: List[TArm] = newList()
  arms.add(arm(pat(10, intT(), TpLit(lit = TLInt(value = 1i64))), None, intLit(11, 10i64)))
  val m = ex(21, intT(), XMatch(scrutinee = ex(22, intT(), XLocal(local = x.id)), arms = arms, exhaustive = false))
  val names: List[String] = newList()
  names.add("P.m")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), m)))
  assertTrue(Str.startsWith(ir, "FALLBACK: "), ir)
}

test "a for over an inclusive range steps after testing the bound" {
  val n = local(1, "n", intT(), false)
  val i = local(2, "i", intT(), false)
  val acc = local(3, "acc", intT(), true)
  val ps: List[TParamDecl] = newList()
  ps.add(param(n))
  val add = ex(
    30,
    tyUnit(),
    XAssign(
      place = TPlace(ty = intT(), kind = PlLocal(local = acc.id)),
      op = AkAdd,
      value = ex(31, intT(), XLocal(local = i.id))
    )
  )
  val loopBody = ex(32, tyUnit(), XBlock(stmts = newList(), tail = Some(value = add)))
  val range = ex(33, intT(), XRange(lo = intLit(34, 0i64), hi = ex(35, intT(), XLocal(local = n.id)), inclusive = true))
  val stmts: List[TStmt] = newList()
  stmts.add(
    TStmt(id = NodeId(id = 40), span = noSourceSpan(), kind = TsVar(decl = acc, init = Some(value = intLit(36, 0i64))))
  )
  stmts.add(
    TStmt(
      id = NodeId(id = 41),
      span = noSourceSpan(),
      kind = TsFor(label = None, pat = pat(37, intT(), TpBind(decl = i, inner = None)), iter = range, body = loopBody)
    )
  )
  val body = ex(38, intT(), XBlock(stmts = stmts, tail = Some(value = ex(39, intT(), XLocal(local = acc.id)))))
  val names: List[String] = newList()
  names.add("P.sum")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), body)))
  assertTrue(Str.contains(ir, "for.cond"), ir)
  assertTrue(Str.contains(ir, "for.inc"), ir)
  assertTrue(Str.contains(ir, "icmp sle i32"), ir)
  assertTrue(Str.contains(ir, "ret i32"), ir)
}

test "a UInt literal above the signed maximum renders as its two's-complement value" {
  val u = TPrim(TPUInt)
  val lit = ex(1, u, XLit(lit = TLInt(value = 4294967295i64)))
  val names: List[String] = newList()
  names.add("P.u")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, newList(), u, lit)))
  assertTrue(Str.contains(ir, "ret i32 -1"), ir)
}

test "a Bool widens by zero extension" {
  val b = local(1, "b", tyBool(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(b))
  val wide = ex(2, intT(), XConvert(kind = CvWiden(to = TPInt), inner = ex(1, tyBool(), XLocal(local = b.id))))
  val names: List[String] = newList()
  names.add("P.w")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), wide)))
  assertTrue(Str.contains(ir, "zext i1"), ir)
}
