//! tir_verify_self_test.l - Lyric.Tir.Verify (docs/70 §6.4, D323).
//!
//! Builds well-formed and ill-formed TIR by hand and checks that each rule
//! fires on exactly the node that breaks it, and that well-formed TIR,
//! including a generic call at an instantiation, is accepted.
@test_module
package Lyric.TirVerifySelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Verify

func sym(n: in Int): SymbolId {
  SymbolId(id = n)
}

func nid(n: in Int): NodeId {
  NodeId(id = n)
}

func ex(n: in Int, ty: in Ty, kind: in TExprKind): TExpr {
  TExpr(id = nid(n), ty = ty, span = noSourceSpan(), kind = kind)
}

func lit(n: in Int, v: in Long): TExpr {
  ex(n, tyInt(), XLit(lit = TLInt(value = v)))
}

func str(n: in Int): TExpr {
  ex(n, tyString(), XLit(lit = TLString(text = "s")))
}

func local(id: in Int, name: in String, ty: in Ty, mutable: in Bool): LocalDecl {
  LocalDecl(id = LocalId(id = id), name = name, ty = ty, mutable = mutable)
}

func tys(a: in Ty): List[Ty] {
  val xs: List[Ty] = newList()
  xs.add(a)
  xs
}

func pty(t: in Ty): TParamTy {
  TParamTy(mode = TMIn, ty = t)
}

func sigOf(tp: in Int, ps: in List[TParamTy], ret: in Ty): TSig {
  TSig(typeParamCount = tp, params = ps, ret = ret, isAsync = false)
}

func funcEntry(s: in Int, sg: in TSig): TSymEntry {
  TSymEntry(
    sym = sym(s),
    kind = TSkFunc,
    typeParamCount = sg.typeParamCount,
    sig = Some(sg),
    fields = newList(),
    ty = None,
    mutable = false
  )
}

func fnDecl(s: in Int, tparams: in Int, params: in List[TParamDecl], ret: in Ty, body: in TExpr): TFnDecl {
  val tps: List[TTypeParam] = newList()
  var i = 0
  while i < tparams {
    tps.add(TTypeParam(name = "T", bounds = newList(), valueTy = None))
    i = i + 1
  }
  TFnDecl(
    sym = sym(s),
    typeParams = tps,
    params = params,
    ret = ret,
    isAsync = false,
    preconds = newList(),
    postconds = newList(),
    body = Some(body),
    span = noSourceSpan()
  )
}

func param(l: in LocalDecl): TParamDecl {
  TParamDecl(local = l, mode = TMIn, dflt = None)
}

func params1(l: in LocalDecl): List[TParamDecl] {
  val xs: List[TParamDecl] = newList()
  xs.add(param(l))
  xs
}

func pkgOf(entries: in List[TSymEntry], fns: in List[TFnDecl]): TPackage {
  TPackage(name = "P", symbols = entries, funcs = fns)
}

func oneFn(entries: in List[TSymEntry], f: in TFnDecl): List[VerifyDiag] {
  val fns: List[TFnDecl] = newList()
  fns.add(f)
  verifyPackage(pkgOf(entries, fns), newList())
}

func rulesOf(ds: in List[VerifyDiag]): String {
  var s = ""
  for d in ds {
    if s != "" {
      s = s + ","
    }
    s = s + d.rule
  }
  s
}

func call(n: in Int, ty: in Ty, callee: in Callee, args: in List[TArg]): TExpr {
  ex(n, ty, XCall(callee = callee, args = args))
}

func argsOf(a: in TExpr): List[TArg] {
  val xs: List[TArg] = newList()
  xs.add(TArgIn(value = a))
  xs
}

/// func f(x: Int): Int = x
func identityInt(): TFnDecl {
  val x = local(1, "x", tyInt(), false)
  fnDecl(10, 0, params1(x), tyInt(), ex(2, tyInt(), XLocal(local = x.id)))
}

/// Entries: g(Int): Int (symbol 11) and id[T](T): T (symbol 12).
func entries(): List[TSymEntry] {
  val es: List[TSymEntry] = newList()
  val ps: List[TParamTy] = newList()
  ps.add(pty(tyInt()))
  es.add(funcEntry(11, sigOf(0, ps, tyInt())))
  val tp = TParam(owner = sym(12), index = 0)
  val ps2: List[TParamTy] = newList()
  ps2.add(pty(tp))
  es.add(funcEntry(12, sigOf(1, ps2, tp)))
  es.add(funcEntry(10, sigOf(0, ps, tyInt())))
  es
}

test "a well-formed identity function verifies clean" {
  assertEqualInt(oneFn(entries(), identityInt()).count, 0, "no diagnostics")
}

test "a generic call at an instantiation verifies clean" {
  val x = local(1, "x", tyInt(), false)
  val c = call(2, tyInt(), Direct(sym = sym(12), typeArgs = tys(tyInt())), argsOf(ex(3, tyInt(), XLocal(local = x.id))))
  assertEqual(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), c))), "", "id[Int](x)")
}

test "a type parameter outside its owner's scope is not closed" {
  val x = local(1, "x", tyInt(), false)
  val body = ex(2, TParam(owner = sym(99), index = 0), XLocal(local = x.id))
  val ds = oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), body))
  assertTrue(rulesOf(ds).contains("closed-type"), "closed-type")
}

test "a call argument of the wrong type is reported at the call" {
  val c = call(2, tyInt(), Direct(sym = sym(11), typeArgs = newList()), argsOf(str(3)))
  val x = local(1, "x", tyInt(), false)
  val ds = oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), c))
  assertEqual(rulesOf(ds), "call-arg-type", "rule")
  assertEqualInt(ds[0].node.id, 2, "the call node")
}

test "a generic instantiation that does not match the argument is reported" {
  val x = local(1, "x", tyInt(), false)
  val c = call(
    2,
    tyInt(),
    Direct(sym = sym(12), typeArgs = tys(tyString())),
    argsOf(ex(3, tyInt(), XLocal(local = x.id)))
  )
  assertTrue(
    rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), c))).contains("call-arg-type"),
    "id[String](Int)"
  )
}

test "a wrong number of type arguments is reported" {
  val x = local(1, "x", tyInt(), false)
  val c = call(2, tyInt(), Direct(sym = sym(12), typeArgs = newList()), argsOf(ex(3, tyInt(), XLocal(local = x.id))))
  assertTrue(
    rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), c))).contains("call-type-args"),
    "missing type argument"
  )
}

test "a wrong result type is reported" {
  val c = call(2, tyString(), Direct(sym = sym(11), typeArgs = newList()), argsOf(lit(3, 1i64)))
  val x = local(1, "x", tyInt(), false)
  assertTrue(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyString(), c))).contains("call-result-type"), "result")
}

test "a callee that no package defines is reported" {
  val c = call(2, tyInt(), Direct(sym = sym(77), typeArgs = newList()), argsOf(lit(3, 1i64)))
  val x = local(1, "x", tyInt(), false)
  assertTrue(
    rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), c))).contains("symbol-defined"),
    "undefined callee"
  )
}

test "a local used before it is defined is reported" {
  val x = local(1, "x", tyInt(), false)
  val ghost = local(5, "ghost", tyInt(), false)
  val ds = oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), ex(2, tyInt(), XLocal(local = ghost.id))))
  assertEqual(rulesOf(ds), "local-defined", "rule")
}

test "a NodeId used twice is reported" {
  val x = local(1, "x", tyInt(), false)
  val c = call(2, tyInt(), Direct(sym = sym(11), typeArgs = newList()), argsOf(ex(2, tyInt(), XLocal(local = x.id))))
  assertTrue(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), c))).contains("node-unique"), "duplicate id")
}

test "if branches must have the node's type" {
  val x = local(1, "x", tyInt(), false)
  val cond = ex(2, tyBool(), XLit(lit = TLBool(value = true)))
  val body = ex(5, tyInt(), XIf(cond = cond, thenBranch = lit(3, 1i64), elseBranch = Some(str(4))))
  assertTrue(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), body))).contains("branch-type"), "else branch")
}

test "a branch of type Never is allowed" {
  val x = local(1, "x", tyInt(), false)
  val cond = ex(2, tyBool(), XLit(lit = TLBool(value = true)))
  val thrower = ex(4, TNever, XLit(lit = TLUnit))
  val body = ex(5, tyInt(), XIf(cond = cond, thenBranch = lit(3, 1i64), elseBranch = Some(thrower)))
  assertEqual(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), body))), "", "Never fits any type")
}

test "assigning to an immutable local is reported, to a mutable one is not" {
  val x = local(1, "x", tyInt(), false)
  val place = TPlace(ty = tyInt(), kind = PlLocal(local = x.id))
  val asg = ex(2, tyUnit(), XAssign(place = place, op = AkSet, value = lit(3, 1i64)))
  val body = ex(4, tyUnit(), XBlock(stmts = newList(), tail = Some(asg)))
  assertEqual(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyUnit(), body))), "assign-mutable", "immutable")
  val y = local(1, "y", tyInt(), true)
  val place2 = TPlace(ty = tyInt(), kind = PlLocal(local = y.id))
  val asg2 = ex(2, tyUnit(), XAssign(place = place2, op = AkSet, value = lit(3, 1i64)))
  val body2 = ex(4, tyUnit(), XBlock(stmts = newList(), tail = Some(asg2)))
  assertEqual(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(y), tyUnit(), body2))), "", "mutable")
}

test "a closure must capture the outer locals it uses" {
  val x = local(1, "x", tyInt(), false)
  val fty = TFunc(params = newList(), ret = tyInt(), isAsync = false)
  val inner = ex(3, tyInt(), XLocal(local = x.id))
  val lam = ex(2, fty, XLambda(params = newList(), captures = newList(), body = inner))
  assertTrue(
    rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), fty, lam))).contains("local-captured"),
    "uncaptured use"
  )
  val caps: List[Capture] = newList()
  caps.add(Capture(local = x.id, mode = CmByValue))
  val inner2 = ex(3, tyInt(), XLocal(local = x.id))
  val lam2 = ex(2, fty, XLambda(params = newList(), captures = caps, body = inner2))
  assertEqual(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), fty, lam2))), "", "captured use")
}

test "a function body of the wrong type is reported" {
  val x = local(1, "x", tyInt(), false)
  assertTrue(
    rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyString(), ex(2, tyInt(), XLocal(local = x.id))))).contains(
      "branch-type"
    ),
    "body vs return type"
  )
}

test "a diagnostic renders as I0003 naming the pass and the node" {
  val c = call(2, tyInt(), Direct(sym = sym(11), typeArgs = newList()), argsOf(str(3)))
  val x = local(1, "x", tyInt(), false)
  val ds = oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), c))
  val text = renderVerifyDiag("monomorphise", ds[0])
  assertTrue(text.startsWith("I0003: pass monomorphise produced an ill-formed node #2"), "prefix")
}

func stmt(n: in Int, kind: in TStmtKind): TStmt {
  TStmt(id = nid(n), span = noSourceSpan(), kind = kind)
}

func pat(n: in Int, ty: in Ty, kind: in TPatKind): TPat {
  TPat(id = nid(n), ty = ty, span = noSourceSpan(), kind = kind)
}

func stmts1(a: in TStmt): List[TStmt] {
  val xs: List[TStmt] = newList()
  xs.add(a)
  xs
}

func stmts2(a: in TStmt, b: in TStmt): List[TStmt] {
  val xs: List[TStmt] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

test "a block-local is not usable after its block ends" {
  val x = local(1, "x", tyInt(), false)
  val y = local(5, "y", tyInt(), false)
  val inner = ex(
    10,
    tyUnit(),
    XBlock(stmts = stmts1(stmt(11, TsVar(decl = y, init = Some(lit(12, 1i64))))), tail = None)
  )
  val useY = ex(13, tyInt(), XLocal(local = y.id))
  val body = ex(14, tyInt(), XBlock(stmts = stmts1(stmt(15, TsExpr(expr = inner))), tail = Some(useY)))
  assertEqual(
    rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), body))),
    "local-in-scope",
    "use after the block"
  )
  val useInside = ex(
    14,
    tyInt(),
    XBlock(
      stmts = stmts1(stmt(15, TsVar(decl = y, init = Some(lit(12, 1i64))))),
      tail = Some(ex(13, tyInt(), XLocal(local = y.id)))
    )
  )
  assertEqual(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), useInside))), "", "use inside the block")
}

test "a match-arm binding is not usable after the match" {
  val x = local(1, "x", tyInt(), false)
  val n = local(5, "n", tyInt(), false)
  val arm = TArm(
    pat = pat(20, tyInt(), TpBind(decl = n, inner = None)),
    guard = None,
    body = ex(21, tyInt(), XLocal(local = n.id))
  )
  val arms: List[TArm] = newList()
  arms.add(arm)
  val m = ex(22, tyInt(), XMatch(scrutinee = ex(23, tyInt(), XLocal(local = x.id)), arms = arms, exhaustive = true))
  assertEqual(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), m))), "", "binding used in its arm")
  val after = ex(
    24,
    tyInt(),
    XBlock(stmts = stmts1(stmt(25, TsExpr(expr = m))), tail = Some(ex(26, tyInt(), XLocal(local = n.id))))
  )
  assertEqual(
    rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), after))),
    "local-in-scope",
    "binding used after the match"
  )
}

test "a let initialiser cannot use the binding it introduces" {
  val x = local(1, "x", tyInt(), false)
  val v = local(5, "v", tyInt(), false)
  val letV = stmt(
    30,
    TsLet(
      pat = pat(31, tyInt(), TpBind(decl = v, inner = None)),
      init = ex(32, tyInt(), XLocal(local = v.id))
    )
  )
  val body = ex(33, tyInt(), XBlock(stmts = stmts1(letV), tail = Some(lit(34, 1i64))))
  assertTrue(rulesOf(oneFn(entries(), fnDecl(10, 0, params1(x), tyInt(), body))).contains("local-defined"), "val v = v")
}

test "a record pattern names fields its owner declares" {
  val x = local(1, "x", tyInt(), false)
  val rec = TNamed(sym = sym(40), args = newList())
  val fields: List[TFieldSig] = newList()
  fields.add(TFieldSig(name = "a", ty = tyInt(), mutable = false))
  val es = entries()
  es.add(
    TSymEntry(
      sym = sym(40),
      kind = TSkType,
      typeParamCount = 0,
      sig = None,
      fields = fields,
      ty = None,
      mutable = false
    )
  )
  val fp: List[TFieldPat] = newList()
  fp.add(TFieldPat(field = FieldRef(owner = sym(40), name = "b", index = 0), pat = pat(41, tyInt(), TpWild)))
  val arm = TArm(pat = pat(42, rec, TpRecord(sym = sym(40), fields = fp)), guard = None, body = lit(43, 1i64))
  val arms: List[TArm] = newList()
  arms.add(arm)
  val scrut = ex(44, rec, XConstruct(sym = sym(40), fields = newList()))
  val body = ex(45, tyInt(), XMatch(scrutinee = scrut, arms = arms, exhaustive = true))
  assertTrue(
    rulesOf(oneFn(es, fnDecl(10, 0, params1(x), tyInt(), body))).contains("field-exists"),
    "field name differs from the declaration"
  )
}

test "a constructor pattern on a case with no signature is reported" {
  val x = local(1, "x", tyInt(), false)
  val es = entries()
  es.add(
    TSymEntry(
      sym = sym(50),
      kind = TSkCase,
      typeParamCount = 0,
      sig = None,
      fields = newList(),
      ty = None,
      mutable = false
    )
  )
  val arm = TArm(pat = pat(51, tyInt(), TpCtor(sym = sym(50), args = newList())), guard = None, body = lit(52, 1i64))
  val arms: List[TArm] = newList()
  arms.add(arm)
  val body = ex(53, tyInt(), XMatch(scrutinee = ex(54, tyInt(), XLocal(local = x.id)), arms = arms, exhaustive = true))
  assertTrue(rulesOf(oneFn(es, fnDecl(10, 0, params1(x), tyInt(), body))).contains("pattern-callable"), "no signature")
}

test "a diagnostic names its function" {
  val x = local(1, "x", tyInt(), false)
  val ds = oneFn(entries(), fnDecl(10, 0, params1(x), tyString(), ex(2, tyInt(), XLocal(local = x.id))))
  assertEqualInt(ds[0].fnSym.id, 10, "the function")
  assertTrue(renderVerifyDiag("p", ds[0]).contains("(in function #10)"), "rendered")
}
