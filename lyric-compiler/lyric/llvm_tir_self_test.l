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
  val elems: List[Ty] = newList()
  elems.add(intT())
  elems.add(intT())
  val pair = TTuple(elems = elems)
  val parts: List[TExpr] = newList()
  parts.add(intLit(2, 1i64))
  parts.add(intLit(3, 2i64))
  val tup = ex(1, pair, XTuple(elems = parts))
  val names: List[String] = newList()
  names.add("P.s")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, newList(), pair, tup)))
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

test "a top-level function key gives its package, name and parameter count" {
  match tirTopLevelFn("Pkg.Sub::add(Int,Int)") {
    case Some(n) -> {
      assertEqual(n.pkg, "Pkg.Sub", "package")
      assertEqual(n.name, "add", "name")
      assertEqualInt(n.arity, 2, "arity")
    }
    case None -> assertTrue(false, "a function key")
  }
  match tirTopLevelFn("P::none()") {
    case Some(n) -> assertEqualInt(n.arity, 0, "no parameters")
    case None -> assertTrue(false, "a nullary function key")
  }
  match tirTopLevelFn("P::f(Map[String,Int],Int)") {
    case Some(n) -> assertEqualInt(n.arity, 2, "a comma inside brackets is not a separator")
    case None -> assertTrue(false, "a generic parameter key")
  }
  assertTrue(isNone(tirTopLevelFn("P::Type")), "a type is not a function")
  assertTrue(isNone(tirTopLevelFn("P::Type::method(Int)")), "a method is not a top-level function")
}

test "the census counts lowered functions and groups fallbacks by reason" {
  val c = newTirCensus()
  c.lowered.add("a")
  c.lowered.add("b")
  c.fallbacks.add("c: expression XLambda")
  c.fallbacks.add("d: expression XLambda")
  c.fallbacks.add("e: a string literal")
  val lines = tirCensusLines(c)
  assertEqual(lines[0], "native via-TIR: 2 of 5 functions lowered from TIR", "totals")
  assertEqual(lines[1], "  fallback: expression XLambda x 2", "most frequent first")
  assertEqual(lines[2], "  fallback: a string literal x 1", "then the rest")
}

test "continue in a for over an exclusive range jumps to the step" {
  val n = local(1, "n", intT(), false)
  val i = local(2, "i", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(n))
  val cont = TStmt(id = NodeId(id = 50), span = noSourceSpan(), kind = TsContinue(label = None))
  val stmts0: List[TStmt] = newList()
  stmts0.add(cont)
  val loopBody = ex(32, tyUnit(), XBlock(stmts = stmts0, tail = None))
  val range = ex(
    33,
    intT(),
    XRange(lo = intLit(34, 0i64), hi = ex(35, intT(), XLocal(local = n.id)), inclusive = false)
  )
  val stmts: List[TStmt] = newList()
  stmts.add(
    TStmt(
      id = NodeId(id = 41),
      span = noSourceSpan(),
      kind = TsFor(label = None, pat = pat(37, intT(), TpBind(decl = i, inner = None)), iter = range, body = loopBody)
    )
  )
  val body = ex(38, intT(), XBlock(stmts = stmts, tail = Some(value = intLit(39, 0i64))))
  val names: List[String] = newList()
  names.add("P.skip")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), body)))
  assertTrue(Str.contains(ir, "icmp slt i32"), "an exclusive bound: " + ir)
  assertTrue(Str.contains(ir, "br label %for.step"), "continue targets the step block: " + ir)
  assertFalse(Str.contains(ir, "for.inc"), "an exclusive range has no inclusive guard: " + ir)
}

test "an or-pattern that binds falls back" {
  val x = local(1, "x", intT(), false)
  val b = local(2, "b", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(x))
  val alts: List[TPat] = newList()
  alts.add(pat(10, intT(), TpBind(decl = b, inner = None)))
  alts.add(pat(11, intT(), TpLit(lit = TLInt(value = 1i64))))
  val arms: List[TArm] = newList()
  arms.add(arm(pat(12, intT(), TpOr(alts = alts)), None, intLit(13, 1i64)))
  arms.add(arm(pat(14, intT(), TpWild), None, intLit(15, 0i64)))
  val m = ex(21, intT(), XMatch(scrutinee = ex(22, intT(), XLocal(local = x.id)), arms = arms, exhaustive = true))
  val names: List[String] = newList()
  names.add("P.o")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), m)))
  assertTrue(Str.startsWith(ir, "FALLBACK: "), ir)
}

func strT(): Ty {
  tyString()
}

func strLit(n: in Int, text: in String): TExpr {
  ex(n, strT(), XLit(lit = TLString(text = text)))
}

func plus(n: in Int, a: in TExpr, b: in TExpr): TExpr {
  ex(n, strT(), XCall(callee = Intrinsic(op = IoAdd), args = inArgs(a, b)))
}

func letStmt(n: in Int, d: in LocalDecl, init: in TExpr): TStmt {
  TStmt(id = NodeId(id = n), span = noSourceSpan(), kind = TsVar(decl = d, init = Some(value = init)))
}

test "a concatenation of a literal and a parameter is returned owned, with nothing to release" {
  val name = local(1, "name", strT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(name))
  val body = plus(3, strLit(2, "Hello, "), ex(4, strT(), XLocal(local = name.id)))
  val names: List[String] = newList()
  names.add("P.greet")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, strT(), body)))
  assertTrue(Str.contains(ir, "call %LyricString* @lyric_string_concat("), ir)
  assertTrue(Str.contains(ir, "ret %LyricString*"), ir)
  assertFalse(Str.contains(ir, "lyric_release"), "the result moves to the caller and the operands are borrowed: " + ir)
  assertFalse(Str.contains(ir, "lyric_retain"), ir)
}

test "a string local is owned by its scope and a returned borrow is retained first" {
  // func f(a: String): String { var t = a + "!"; t }
  val a = local(1, "a", strT(), false)
  val t = local(2, "t", strT(), true)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  val stmts: List[TStmt] = newList()
  stmts.add(letStmt(20, t, plus(3, ex(4, strT(), XLocal(local = a.id)), strLit(5, "!"))))
  val body = ex(6, strT(), XBlock(stmts = stmts, tail = Some(value = ex(7, strT(), XLocal(local = t.id)))))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, strT(), body)))
  assertTrue(
    Str.contains(ir, "call void @lyric_retain("),
    "the tail borrows t, so it is retained before t is released: " + ir
  )
  assertTrue(Str.contains(ir, "call void @lyric_release("), "the scope releases t: " + ir)
}

test "an owned temporary passed to println is released after the statement" {
  // func show(n: Int): Unit { println(toString(n)) }
  val n = local(1, "n", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(n))
  val str = ex(
    2,
    strT(),
    XCall(
      callee = Intrinsic(op = IoBuiltin(name = "toString")),
      args = inArgs1(ex(3, intT(), XLocal(local = n.id)))
    )
  )
  val say = ex(4, tyUnit(), XCall(callee = Intrinsic(op = IoBuiltin(name = "println")), args = inArgs1(str)))
  val body = ex(5, tyUnit(), XBlock(stmts = newList(), tail = Some(value = say)))
  val names: List[String] = newList()
  names.add("P.show")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, tyUnit(), body)))
  assertTrue(Str.contains(ir, "@lyric_string_from_int("), ir)
  assertTrue(Str.contains(ir, "@lyric_console_write_line(i32 1,"), ir)
  assertTrue(Str.contains(ir, "call void @lyric_release("), "the toString result is released: " + ir)
  assertTrue(Str.contains(ir, "ret void"), ir)
}

test "a return inside a branch releases the locals live at that point" {
  // func g(s: String): String { var t = s + "!"; if t.length > 3 { return t }; "short" }
  val s0 = local(1, "s", strT(), false)
  val t = local(2, "t", strT(), true)
  val ps: List[TParamDecl] = newList()
  ps.add(param(s0))
  val len = ex(
    10,
    intT(),
    XCall(
      callee = Intrinsic(op = IoBuiltin(name = "String.length")),
      args = inArgs1(ex(11, strT(), XLocal(local = t.id)))
    )
  )
  val cond = ex(12, tyBool(), XCall(callee = Intrinsic(op = IoGt), args = inArgs(len, intLit(13, 3i64))))
  val ret = TStmt(
    id = NodeId(id = 30),
    span = noSourceSpan(),
    kind = TsReturn(value = Some(value = ex(14, strT(), XLocal(local = t.id))))
  )
  val thenB = ex(15, tyUnit(), XBlock(stmts = list1(ret), tail = None))
  val ifE = ex(16, tyUnit(), XIf(cond = cond, thenBranch = thenB, elseBranch = None))
  val stmts: List[TStmt] = newList()
  stmts.add(letStmt(20, t, plus(3, ex(4, strT(), XLocal(local = s0.id)), strLit(5, "!"))))
  stmts.add(TStmt(id = NodeId(id = 31), span = noSourceSpan(), kind = TsExpr(expr = ifE)))
  val body = ex(6, strT(), XBlock(stmts = stmts, tail = Some(value = strLit(7, "short"))))
  val names: List[String] = newList()
  names.add("P.g")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, strT(), body)))
  assertTrue(Str.contains(ir, "@lyric_string_len("), ir)
  // t is retained for the return and released with the scope, in the branch and at the end.
  assertTrue(countOf(ir, "call void @lyric_release(") >= 2, "released on both exits: " + ir)
}

func inArgs1(a: in TExpr): List[TArg] {
  val xs: List[TArg] = newList()
  xs.add(TArgIn(value = a))
  xs
}

func list1(s: in TStmt): List[TStmt] {
  val xs: List[TStmt] = newList()
  xs.add(s)
  xs
}

func countOf(hay: in String, needle: in String): Int {
  var n = 0
  var from = 0
  var go = true
  while go {
    match Str.indexOfFrom(hay, needle, from) {
      case Some(i) -> {
        n = n + 1
        from = i + needle.length
      }
      case None -> {
        go = false
      }
    }
  }
  n
}

test "the method form of toString on an Int and on a Bool is the same built-in" {
  val n = local(1, "n", intT(), false)
  val b = local(2, "b", tyBool(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(n))
  ps.add(param(b))
  val ns = ex(
    3,
    strT(),
    XCall(
      callee = Intrinsic(op = IoBuiltin(name = "Int.toString")),
      args = inArgs1(ex(4, intT(), XLocal(local = n.id)))
    )
  )
  val bs = ex(
    5,
    strT(),
    XCall(
      callee = Intrinsic(op = IoBuiltin(name = "Bool.toString")),
      args = inArgs1(ex(6, tyBool(), XLocal(local = b.id)))
    )
  )
  val body = plus(7, ns, bs)
  val names: List[String] = newList()
  names.add("P.both")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, strT(), body)))
  assertTrue(Str.contains(ir, "@lyric_string_from_int("), ir)
  assertTrue(Str.contains(ir, "@lyric_string_from_bool("), ir)
  assertTrue(countOf(ir, "call void @lyric_release(") == 2, "both owned temporaries are released: " + ir)
}

test "a reference local with no initializer starts null and is released with its scope" {
  // func f(): Int { var s: String; 0 }
  val sv = local(1, "s", strT(), true)
  val stmts: List[TStmt] = newList()
  stmts.add(TStmt(id = NodeId(id = 20), span = noSourceSpan(), kind = TsVar(decl = sv, init = None)))
  val body = ex(2, intT(), XBlock(stmts = stmts, tail = Some(value = intLit(3, 0i64))))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, newList(), intT(), body)))
  assertTrue(Str.contains(ir, "store %LyricString* null"), "the slot starts null: " + ir)
  assertTrue(Str.contains(ir, "call void @lyric_release("), "and is released when its scope closes: " + ir)
}

test "an if whose reference result has a branch that returns joins both with a string phi" {
  // func g(c: Bool, s: String): String { if c { return "x" } else { s } }
  val cnd = local(1, "c", tyBool(), false)
  val s0 = local(2, "s", strT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(cnd))
  ps.add(param(s0))
  val ret = TStmt(id = NodeId(id = 30), span = noSourceSpan(), kind = TsReturn(value = Some(value = strLit(4, "x"))))
  val thenB = ex(5, strT(), XBlock(stmts = list1(ret), tail = None))
  val elseB = ex(6, strT(), XBlock(stmts = newList(), tail = Some(value = ex(7, strT(), XLocal(local = s0.id)))))
  val ifE = ex(
    8,
    strT(),
    XIf(cond = ex(9, tyBool(), XLocal(local = cnd.id)), thenBranch = thenB, elseBranch = Some(value = elseB))
  )
  val names: List[String] = newList()
  names.add("P.g")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, strT(), ifE)))
  assertTrue(Str.contains(ir, "phi %LyricString*"), ir)
  assertTrue(Str.contains(ir, "undef,"), "the returning branch contributes an undef edge: " + ir)
}

func pointEnv(names: in List[String]): TirLowerEnv {
  val m: Map[Int, String] = newMap()
  var i = 0
  while i < names.count {
    m.add(100 + i, names[i])
    i = i + 1
  }
  val recs: Map[Int, TirRecLayout] = newMap()
  val fts: List[NType] = newList()
  fts.add(NI32)
  fts.add(NI32)
  val fieldTys: List[NType] = newList()
  fieldTys.add(NI32)
  fieldTys.add(NI32)
  recs.add(7, TirRecLayout(ty = NStruct(name = "P.Point", fields = fts), fieldTys = fieldTys))
  TirLowerEnv(fnNames = m, panicFile = "P", recs = recs)
}

func pointT(): Ty {
  TNamed(sym = sym(7), args = newList())
}

func fieldRef(name: in String, index: in Int): FieldRef {
  FieldRef(owner = sym(7), name = name, index = index)
}

test "a by-value record is built with insertvalue and read with extractvalue" {
  // func f(a: Int, b: Int): Int { val p = Point(a, b); p.y }
  val a = local(1, "a", intT(), false)
  val b = local(2, "b", intT(), false)
  val p = local(3, "p", pointT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  ps.add(param(b))
  val fields: List[TExpr] = newList()
  fields.add(ex(4, intT(), XLocal(local = a.id)))
  fields.add(ex(5, intT(), XLocal(local = b.id)))
  val stmts: List[TStmt] = newList()
  stmts.add(letStmt(20, p, ex(6, pointT(), XConstruct(sym = sym(7), fields = fields))))
  val tail = ex(8, intT(), XField(recv = ex(9, pointT(), XLocal(local = p.id)), field = fieldRef("y", 1)))
  val body = ex(10, intT(), XBlock(stmts = stmts, tail = Some(value = tail)))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(pointEnv(names), fnDecl(100, ps, intT(), body)))
  assertTrue(Str.contains(ir, "insertvalue %P.Point undef, i32"), ir)
  assertTrue(Str.contains(ir, ", 1"), "the second field is inserted at index 1: " + ir)
  assertTrue(Str.contains(ir, "extractvalue %P.Point"), ir)
  assertFalse(Str.contains(ir, "lyric_alloc"), "a by-value record allocates nothing: " + ir)
  assertFalse(Str.contains(ir, "lyric_release"), "and needs no ARC: " + ir)
}

test "a copy inserts the updated fields into the base" {
  // func f(p: Point): Point { p.copy(x = 9) }
  val p = local(1, "p", pointT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(p))
  val ups: List[TFieldUpdate] = newList()
  ups.add(TFieldUpdate(field = fieldRef("x", 0), value = intLit(3, 9i64)))
  val body = ex(4, pointT(), XCopy(base = ex(2, pointT(), XLocal(local = p.id)), updates = ups))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(pointEnv(names), fnDecl(100, ps, pointT(), body)))
  assertTrue(Str.contains(ir, "%P.Point @P.f(%P.Point %a1)"), ir)
  assertTrue(Str.contains(ir, "insertvalue %P.Point"), ir)
  assertTrue(Str.contains(ir, "ret %P.Point"), ir)
}

test "a record the code generator did not register by value falls back" {
  // func f(): Point { Point(1, 2) } with an environment that has no layout
  val fields: List[TExpr] = newList()
  fields.add(intLit(2, 1i64))
  fields.add(intLit(3, 2i64))
  val body = ex(4, pointT(), XConstruct(sym = sym(7), fields = fields))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, newList(), pointT(), body)))
  assertTrue(Str.startsWith(ir, "FALLBACK:"), ir)
}

test "an operator on a by-value record falls back" {
  // func f(a: Point, b: Point): Bool { a == b }
  val a = local(1, "a", pointT(), false)
  val b = local(2, "b", pointT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  ps.add(param(b))
  val body = ex(
    3,
    tyBool(),
    XCall(
      callee = Intrinsic(op = IoEq),
      args = inArgs(ex(4, pointT(), XLocal(local = a.id)), ex(5, pointT(), XLocal(local = b.id)))
    )
  )
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(pointEnv(names), fnDecl(100, ps, tyBool(), body)))
  assertTrue(Str.startsWith(ir, "FALLBACK:"), ir)
}

func personEnv(names: in List[String]): TirLowerEnv {
  val m: Map[Int, String] = newMap()
  var i = 0
  while i < names.count {
    m.add(100 + i, names[i])
    i = i + 1
  }
  val body: List[NType] = newList()
  addArcHeader(body)
  body.add(lyricStringNType())
  body.add(NI32)
  val fieldTys: List[NType] = newList()
  fieldTys.add(lyricStringNType())
  fieldTys.add(NI32)
  val recs: Map[Int, TirRecLayout] = newMap()
  recs.add(
    8,
    TirRecLayout(
      ty = NPtr(pointee = NStruct(name = "P.Person", fields = body)),
      fieldTys = fieldTys,
      byValue = false,
      dtor = "P.Person.dtor"
    )
  )
  TirLowerEnv(fnNames = m, panicFile = "P", recs = recs)
}

func personT(): Ty {
  TNamed(sym = sym(8), args = newList())
}

func personField(name: in String, index: in Int): FieldRef {
  FieldRef(owner = sym(8), name = name, index = index)
}

test "a heap record is allocated with its destructor, owns its reference fields and is returned owned" {
  // func make(n: String, a: Int): Person { Person(n, a) }
  val n = local(1, "n", strT(), false)
  val a = local(2, "a", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(n))
  ps.add(param(a))
  val fields: List[TExpr] = newList()
  fields.add(ex(3, strT(), XLocal(local = n.id)))
  fields.add(ex(4, intT(), XLocal(local = a.id)))
  val body = ex(5, personT(), XConstruct(sym = sym(8), fields = fields))
  val names: List[String] = newList()
  names.add("P.make")
  val ir = render(lowerTirFunction(personEnv(names), fnDecl(100, ps, personT(), body)))
  assertTrue(Str.contains(ir, "call i8* @lyric_alloc("), ir)
  assertTrue(Str.contains(ir, "@P.Person.dtor"), "the destructor pointer is stored in the header: " + ir)
  assertTrue(Str.contains(ir, "call void @lyric_weak_init("), ir)
  assertTrue(Str.contains(ir, "call void @lyric_retain("), "the object owns the string field, so it is retained: " + ir)
  assertTrue(Str.contains(ir, "ret %P.Person*"), ir)
}

test "a heap record field read is a load through the field pointer and is borrowed" {
  // func name(p: Person): String { p.name }
  val p = local(1, "p", personT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(p))
  val body = ex(2, strT(), XField(recv = ex(3, personT(), XLocal(local = p.id)), field = personField("name", 0)))
  val names: List[String] = newList()
  names.add("P.name")
  val ir = render(lowerTirFunction(personEnv(names), fnDecl(100, ps, strT(), body)))
  assertTrue(Str.contains(ir, "getelementptr inbounds %P.Person, %P.Person* %"), ir)
  assertTrue(Str.contains(ir, "i32 3"), "the first field follows the three header slots: " + ir)
  assertTrue(Str.contains(ir, "call void @lyric_retain("), "returning the borrowed field retains it first: " + ir)
}

test "a heap record copy is a new object that retains the base's reference fields" {
  // func older(p: Person): Person { p.copy(age = 9) }
  val p = local(1, "p", personT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(p))
  val ups: List[TFieldUpdate] = newList()
  ups.add(TFieldUpdate(field = personField("age", 1), value = intLit(3, 9i64)))
  val body = ex(4, personT(), XCopy(base = ex(2, personT(), XLocal(local = p.id)), updates = ups))
  val names: List[String] = newList()
  names.add("P.older")
  val ir = render(lowerTirFunction(personEnv(names), fnDecl(100, ps, personT(), body)))
  assertTrue(Str.contains(ir, "call i8* @lyric_alloc("), ir)
  assertTrue(Str.contains(ir, "call void @lyric_retain("), "the copy shares the name string, so it is retained: " + ir)
}

test "a heap record local is released when its scope closes" {
  // func f(n: String): Int { val p = Person(n, 1); p.age }
  val n = local(1, "n", strT(), false)
  val p = local(2, "p", personT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(n))
  val fields: List[TExpr] = newList()
  fields.add(ex(3, strT(), XLocal(local = n.id)))
  fields.add(intLit(4, 1i64))
  val stmts: List[TStmt] = newList()
  stmts.add(letStmt(20, p, ex(5, personT(), XConstruct(sym = sym(8), fields = fields))))
  val tail = ex(6, intT(), XField(recv = ex(7, personT(), XLocal(local = p.id)), field = personField("age", 1)))
  val body = ex(8, intT(), XBlock(stmts = stmts, tail = Some(value = tail)))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(personEnv(names), fnDecl(100, ps, intT(), body)))
  assertTrue(Str.contains(ir, "call void @lyric_release("), "the scope releases p: " + ir)
}

test "an operator on a heap record falls back" {
  val a = local(1, "a", personT(), false)
  val b = local(2, "b", personT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  ps.add(param(b))
  val body = ex(
    3,
    tyBool(),
    XCall(
      callee = Intrinsic(op = IoEq),
      args = inArgs(ex(4, personT(), XLocal(local = a.id)), ex(5, personT(), XLocal(local = b.id)))
    )
  )
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(personEnv(names), fnDecl(100, ps, tyBool(), body)))
  assertTrue(Str.startsWith(ir, "FALLBACK:"), ir)
}

func unitFieldEnv(names: in List[String]): TirLowerEnv {
  val m: Map[Int, String] = newMap()
  var i = 0
  while i < names.count {
    m.add(100 + i, names[i])
    i = i + 1
  }
  val fts: List[NType] = newList()
  fts.add(NI32)
  fts.add(NI8)
  val fieldTys: List[NType] = newList()
  fieldTys.add(NI32)
  fieldTys.add(NVoid)
  val recs: Map[Int, TirRecLayout] = newMap()
  recs.add(9, TirRecLayout(ty = NStruct(name = "P.Tagged", fields = fts), fieldTys = fieldTys))
  TirLowerEnv(fnNames = m, panicFile = "P", recs = recs)
}

test "a Unit field stores nothing and reads as Unit; an index outside the layout falls back" {
  val taggedT = TNamed(sym = sym(9), args = newList())
  val fields: List[TExpr] = newList()
  fields.add(intLit(2, 5i64))
  fields.add(ex(3, tyUnit(), XLit(lit = TLUnit)))
  val body = ex(4, taggedT, XConstruct(sym = sym(9), fields = fields))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(unitFieldEnv(names), fnDecl(100, newList(), taggedT, body)))
  assertTrue(Str.contains(ir, "insertvalue %P.Tagged undef, i32 5, 0"), ir)
  assertFalse(Str.contains(ir, "insertvalue %P.Tagged %t1, i8"), "the placeholder byte is left undef: " + ir)
  val p = local(1, "p", taggedT, false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(p))
  val bad = ex(
    5,
    intT(),
    XField(
      recv = ex(6, taggedT, XLocal(local = p.id)),
      field = FieldRef(owner = sym(9), name = "ghost", index = 7)
    )
  )
  val ir2 = render(lowerTirFunction(unitFieldEnv(names), fnDecl(100, ps, intT(), bad)))
  assertTrue(Str.startsWith(ir2, "FALLBACK:"), ir2)
}

func shapeT(): Ty {
  TNamed(sym = sym(11), args = newList())
}

func caseL(name: in String, fts: in List[NType]): TirCaseLayout {
  TirCaseLayout(payloadTy = NStruct(name = "P.Shape." + name, fields = fts), fieldTys = fts)
}

func tys1(a: in NType): List[NType] {
  val xs: List[NType] = newList()
  xs.add(a)
  xs
}

func tys2(a: in NType, b: in NType): List[NType] {
  val xs: List[NType] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

/// `union Shape { Circle(r: Int), Rect(w: Int, h: Int), Empty }` as an inline tagged value, or as
/// a heap object with a `Label(s: String)` case when `heap`.
func shapeEnv(names: in List[String], heap: in Bool): TirLowerEnv {
  val m: Map[Int, String] = newMap()
  var i = 0
  while i < names.count {
    m.add(100 + i, names[i])
    i = i + 1
  }
  val cases: List[TirCaseLayout] = newList()
  cases.add(caseL("Circle", tys1(NI32)))
  cases.add(caseL("Rect", tys2(NI32, NI32)))
  cases.add(caseL("Empty", newList()))
  val fields: List[NType] = newList()
  var structTy: NType = NStruct(name = "P.Shape", fields = fields)
  var ty: NType = structTy
  if heap {
    cases.add(caseL("Label", tys1(lyricStringNType())))
    addArcHeader(fields)
    fields.add(NI32)
    fields.add(NI32)
    fields.add(NArray(elem = NI64, size = 2))
    structTy = NStruct(name = "P.Shape", fields = fields)
    ty = NPtr(pointee = structTy)
  } else {
    fields.add(NI32)
    fields.add(NI32)
    fields.add(NArray(elem = NI64, size = 2))
    structTy = NStruct(name = "P.Shape", fields = fields)
    ty = structTy
  }
  val unions: Map[Int, TirUnionLayout] = newMap()
  unions.add(
    11,
    TirUnionLayout(
      ty = ty,
      structTy = structTy,
      inline = not heap,
      payloadWords = 2,
      discIdx = if heap { 3 } else { 0 },
      payloadIdx = if heap { 5 } else { 2 },
      dtor = if heap { "P.Shape.dtor" } else { "" },
      cases = cases
    )
  )
  val cm: Map[Int, TirCaseRef] = newMap()
  cm.add(12, TirCaseRef(unionId = 11, index = 0))
  cm.add(13, TirCaseRef(unionId = 11, index = 1))
  cm.add(14, TirCaseRef(unionId = 11, index = 2))
  cm.add(15, TirCaseRef(unionId = 11, index = 3))
  TirLowerEnv(fnNames = m, panicFile = "P", unions = unions, cases = cm)
}

test "an inline union case is built in a stack slot with its discriminant and payload, then loaded" {
  // func f(a: Int, b: Int): Shape { Rect(a, b) }
  val a = local(1, "a", intT(), false)
  val b = local(2, "b", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  ps.add(param(b))
  val fields: List[TExpr] = newList()
  fields.add(ex(3, intT(), XLocal(local = a.id)))
  fields.add(ex(4, intT(), XLocal(local = b.id)))
  val body = ex(5, shapeT(), XConstruct(sym = sym(13), fields = fields))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(shapeEnv(names, false), fnDecl(100, ps, shapeT(), body)))
  assertTrue(Str.contains(ir, "alloca %P.Shape"), ir)
  assertTrue(Str.contains(ir, "store i32 1, i32*"), "the Rect discriminant is 1: " + ir)
  assertTrue(Str.contains(ir, "bitcast [2 x i64]*"), "the payload area is viewed as the case struct: " + ir)
  assertTrue(Str.contains(ir, "load %P.Shape"), ir)
  assertFalse(Str.contains(ir, "lyric_alloc"), "an inline union allocates nothing: " + ir)
}

test "a match on an inline union tests the discriminant and binds the payload fields" {
  // func area(s: Shape): Int { match s { Circle(r) -> r; Rect(w, h) -> w * h; Empty -> 0 } }
  val s = local(1, "s", shapeT(), false)
  val r = local(2, "r", intT(), false)
  val w = local(3, "w", intT(), false)
  val h = local(4, "h", intT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(s))
  val arms: List[TArm] = newList()
  val circleArgs: List[TPat] = newList()
  circleArgs.add(pat(30, intT(), TpBind(decl = r, inner = None)))
  arms.add(arm(pat(31, shapeT(), TpCtor(sym = sym(12), args = circleArgs)), None, ex(32, intT(), XLocal(local = r.id))))
  val rectArgs: List[TPat] = newList()
  rectArgs.add(pat(33, intT(), TpBind(decl = w, inner = None)))
  rectArgs.add(pat(34, intT(), TpBind(decl = h, inner = None)))
  val area = ex(
    35,
    intT(),
    XCall(
      callee = Intrinsic(op = IoMul),
      args = inArgs(ex(36, intT(), XLocal(local = w.id)), ex(37, intT(), XLocal(local = h.id)))
    )
  )
  arms.add(arm(pat(38, shapeT(), TpCtor(sym = sym(13), args = rectArgs)), None, area))
  arms.add(arm(pat(39, shapeT(), TpCtor(sym = sym(14), args = newList())), None, intLit(40, 0i64)))
  val m = ex(41, intT(), XMatch(scrutinee = ex(42, shapeT(), XLocal(local = s.id)), arms = arms, exhaustive = true))
  val names: List[String] = newList()
  names.add("P.area")
  val ir = render(lowerTirFunction(shapeEnv(names, false), fnDecl(100, ps, intT(), m)))
  assertTrue(Str.contains(ir, "i32 @P.area(%P.Shape %a1)"), ir)
  assertTrue(Str.contains(ir, "icmp eq i32"), "the discriminant is tested: " + ir)
  assertTrue(Str.contains(ir, "mul i32"), ir)
  assertTrue(Str.contains(ir, "phi i32"), ir)
  assertTrue(Str.contains(ir, "iu.scrut"), "an inline scrutinee is spilled to read its payload: " + ir)
}

test "a heap union case owns its reference payload and a bound field is a borrow" {
  // func f(t: String): Shape { Label(t) }  and  func g(s: Shape): String { match s { Label(x) -> x; _ -> "" } }
  val t = local(1, "t", strT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(t))
  val fields: List[TExpr] = newList()
  fields.add(ex(2, strT(), XLocal(local = t.id)))
  val body = ex(3, shapeT(), XConstruct(sym = sym(15), fields = fields))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(shapeEnv(names, true), fnDecl(100, ps, shapeT(), body)))
  assertTrue(Str.contains(ir, "call i8* @lyric_alloc("), ir)
  assertTrue(Str.contains(ir, "@P.Shape.dtor"), ir)
  assertTrue(Str.contains(ir, "call void @lyric_retain("), "the object owns the string payload: " + ir)
  assertTrue(Str.contains(ir, "ret %P.Shape*"), ir)
  val s = local(4, "s", shapeT(), false)
  val x = local(5, "x", strT(), false)
  val ps2: List[TParamDecl] = newList()
  ps2.add(param(s))
  val arms: List[TArm] = newList()
  val labelArgs: List[TPat] = newList()
  labelArgs.add(pat(6, strT(), TpBind(decl = x, inner = None)))
  arms.add(arm(pat(7, shapeT(), TpCtor(sym = sym(15), args = labelArgs)), None, ex(8, strT(), XLocal(local = x.id))))
  arms.add(arm(pat(9, shapeT(), TpWild), None, strLit(10, "")))
  val m = ex(11, strT(), XMatch(scrutinee = ex(12, shapeT(), XLocal(local = s.id)), arms = arms, exhaustive = true))
  val names2: List[String] = newList()
  names2.add("P.g")
  val ir2 = render(lowerTirFunction(shapeEnv(names2, true), fnDecl(100, ps2, strT(), m)))
  assertTrue(Str.contains(ir2, "icmp eq i32"), ir2)
  assertTrue(Str.contains(ir2, "phi %LyricString*"), ir2)
  assertFalse(Str.contains(ir2, "iu.scrut"), "a heap union is read through its own pointer: " + ir2)
}

test "a literal sub-pattern on a case field is tested under the discriminant" {
  // func f(s: Shape): Int { match s { Circle(0) -> 1; _ -> 2 } }
  val s = local(1, "s", shapeT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(s))
  val arms: List[TArm] = newList()
  val args: List[TPat] = newList()
  args.add(pat(2, intT(), TpLit(lit = TLInt(value = 0i64))))
  arms.add(arm(pat(3, shapeT(), TpCtor(sym = sym(12), args = args)), None, intLit(4, 1i64)))
  arms.add(arm(pat(5, shapeT(), TpWild), None, intLit(6, 2i64)))
  val m = ex(7, intT(), XMatch(scrutinee = ex(8, shapeT(), XLocal(local = s.id)), arms = arms, exhaustive = true))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(shapeEnv(names, false), fnDecl(100, ps, intT(), m)))
  assertTrue(Str.contains(ir, "and i1"), "the field test is combined with the discriminant test: " + ir)
}

test "an operator on a union and a case outside the registered unions fall back" {
  val a = local(1, "a", shapeT(), false)
  val b = local(2, "b", shapeT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(a))
  ps.add(param(b))
  val eq = ex(
    3,
    tyBool(),
    XCall(
      callee = Intrinsic(op = IoEq),
      args = inArgs(ex(4, shapeT(), XLocal(local = a.id)), ex(5, shapeT(), XLocal(local = b.id)))
    )
  )
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(shapeEnv(names, false), fnDecl(100, ps, tyBool(), eq)))
  assertTrue(Str.startsWith(ir, "FALLBACK:"), ir)
  val unknown = ex(6, shapeT(), XConstruct(sym = sym(99), fields = newList()))
  val ir2 = render(lowerTirFunction(shapeEnv(names, false), fnDecl(100, newList(), shapeT(), unknown)))
  assertTrue(Str.startsWith(ir2, "FALLBACK:"), ir2)
}

test "a string interpolation is a left fold of concatenations that releases each intermediate" {
  // func f(n: Int, s: String): String { "n=${n} s=${s}" }
  val n = local(1, "n", intT(), false)
  val s = local(2, "s", strT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(n))
  ps.add(param(s))
  val parts: List[TExpr] = newList()
  parts.add(strLit(3, "n="))
  parts.add(
    ex(
      4,
      strT(),
      XCall(
        callee = Intrinsic(op = IoBuiltin(name = "Int.toString")),
        args = list1Arg(ex(5, intT(), XLocal(local = n.id)))
      )
    )
  )
  parts.add(strLit(6, " s="))
  parts.add(ex(7, strT(), XLocal(local = s.id)))
  val body = ex(8, strT(), XInterp(parts = parts))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, strT(), body)))
  assertTrue(Str.contains(ir, "call %LyricString* @lyric_string_concat("), ir)
  assertTrue(Str.contains(ir, "call void @lyric_release("), "an intermediate string is released: " + ir)
  assertTrue(Str.contains(ir, "ret %LyricString*"), ir)
}

func list1Arg(a: in TExpr): List[TArg] {
  val xs: List[TArg] = newList()
  xs.add(TArgIn(value = a))
  xs
}

test "a match on a string tests literal patterns with the runtime comparison" {
  // func f(s: String): Int { match s { "a" -> 1; _ -> 0 } }
  val s = local(1, "s", strT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(s))
  val arms: List[TArm] = newList()
  arms.add(arm(pat(2, strT(), TpLit(lit = TLString(text = "a"))), None, intLit(3, 1i64)))
  arms.add(arm(pat(4, strT(), TpWild), None, intLit(5, 0i64)))
  val m = ex(6, intT(), XMatch(scrutinee = ex(7, strT(), XLocal(local = s.id)), arms = arms, exhaustive = true))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), m)))
  assertTrue(Str.contains(ir, "call i32 @lyric_string_eq("), ir)
  assertTrue(Str.contains(ir, "phi i32"), ir)
}

test "a float literal pattern compares with fcmp oeq" {
  val x = local(1, "x", TPrim(TPDouble), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(x))
  val arms: List[TArm] = newList()
  arms.add(arm(pat(2, TPrim(TPDouble), TpLit(lit = TLFloat(value = 1.0))), None, intLit(3, 1i64)))
  arms.add(arm(pat(4, TPrim(TPDouble), TpWild), None, intLit(5, 0i64)))
  val m = ex(
    6,
    intT(),
    XMatch(scrutinee = ex(7, TPrim(TPDouble), XLocal(local = x.id)), arms = arms, exhaustive = true)
  )
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), m)))
  assertTrue(Str.contains(ir, "fcmp oeq double"), ir)
}

test "indexing a string reads the scalar value at a byte offset; other indexing falls back" {
  val s = local(1, "s", strT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(s))
  val body = ex(
    2,
    TPrim(TPChar),
    XIndex(recv = ex(3, strT(), XLocal(local = s.id)), idx = intLit(4, 0i64), how = IkString)
  )
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(envOf(names), fnDecl(100, ps, TPrim(TPChar), body)))
  assertTrue(Str.contains(ir, "call i32 @lyric_string_char_at("), ir)
  val bad = ex(5, intT(), XIndex(recv = ex(6, strT(), XLocal(local = s.id)), idx = intLit(7, 0i64), how = IkList))
  val ir2 = render(lowerTirFunction(envOf(names), fnDecl(100, ps, intT(), bad)))
  assertTrue(Str.startsWith(ir2, "FALLBACK:"), ir2)
}

func colorT(): Ty {
  TNamed(sym = sym(20), args = newList())
}

func enumEnv(names: in List[String]): TirLowerEnv {
  val m: Map[Int, String] = newMap()
  var i = 0
  while i < names.count {
    m.add(100 + i, names[i])
    i = i + 1
  }
  val enums: Map[Int, Bool] = newMap()
  enums.add(20, true)
  val cases: Map[Int, Int] = newMap()
  cases.add(21, 0)
  cases.add(22, 1)
  cases.add(23, 2)
  TirLowerEnv(fnNames = m, panicFile = "P", enums = enums, enumCases = cases)
}

test "an enum case is its ordinal and a case pattern compares the ordinal" {
  // func f(c: Color): Int { match c { Red -> 1; Green -> 2; Blue -> 3 } }  and  func g(): Color { Green }
  val c = local(1, "c", colorT(), false)
  val ps: List[TParamDecl] = newList()
  ps.add(param(c))
  val arms: List[TArm] = newList()
  arms.add(arm(pat(2, colorT(), TpCtor(sym = sym(21), args = newList())), None, intLit(3, 1i64)))
  arms.add(arm(pat(4, colorT(), TpCtor(sym = sym(22), args = newList())), None, intLit(5, 2i64)))
  arms.add(arm(pat(6, colorT(), TpCtor(sym = sym(23), args = newList())), None, intLit(7, 3i64)))
  val m = ex(8, intT(), XMatch(scrutinee = ex(9, colorT(), XLocal(local = c.id)), arms = arms, exhaustive = true))
  val names: List[String] = newList()
  names.add("P.f")
  val ir = render(lowerTirFunction(enumEnv(names), fnDecl(100, ps, intT(), m)))
  assertTrue(Str.contains(ir, "i32 @P.f(i32 %a1)"), "an enum is an i32: " + ir)
  assertTrue(Str.contains(ir, "icmp eq i32 %t"), ir)
  assertTrue(Str.contains(ir, ", 2"), "the Blue ordinal is 2: " + ir)
  val g = ex(10, colorT(), XConstruct(sym = sym(22), fields = newList()))
  val names2: List[String] = newList()
  names2.add("P.g")
  val ir2 = render(lowerTirFunction(enumEnv(names2), fnDecl(100, newList(), colorT(), g)))
  assertTrue(Str.contains(ir2, "ret i32 1"), "Green is ordinal 1: " + ir2)
}
