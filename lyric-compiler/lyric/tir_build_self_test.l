//! tir_build_self_test.l - Lyric.Tir.Build (docs/70 §6.3, D360).
//!
//! The checker records a type per expression under its `NodeId`, and the
//! builder's conversion turns it into `Lyric.Tir.Ty` or reports I0002: for a
//! node with no entry, a `TyError`, an unsolved `TyInfer`, or a generic
//! parameter whose binder is not registered.
@test_module
package Lyric.TirBuildSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Resolve
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir as TirT
import Lyric.Tir.Build

func checkNumbered(src: in String): CheckResult {
  check(renumberNodeIds(parse(src).file).file)
}

func countWhere(ctx: in TyConvCtx, ids: in List[Int], want: in Ty): Int {
  var n = 0
  for id in ids {
    match exprTy(ctx, id) {
      case Ok(t) -> if tyEq(t, want) { n = n + 1 }
      case Err(_) -> ()
    }
  }
  n
}

test "every expression of a checked function has a recorded type" {
  val src = "package App\nfunc f(x: Int): Int { x + 1 }\n"
  val cr = checkNumbered(src)
  assertEqualInt(cr.diagnostics.count, 0, "checks clean")
  val ctx = newTyConvCtx(cr.symbols)
  val ids = exprNodeIds(renumberNodeIds(parse(src).file).file)
  assertTrue(ids.count >= 3, "x, 1 and x + 1 are expressions")
  assertEqualInt(exprTypeCensus(ctx, ids).count, 0, "no I0002")
  assertTrue(countWhere(ctx, ids, TPrim(kind = TPInt)) >= 3, "all three are Int")
}

test "a node the checker never typed is an I0002" {
  val cr = checkNumbered("package App\nfunc f(): Int { 1 }\n")
  val ctx = newTyConvCtx(cr.symbols)
  val ids: List[Int] = newList()
  ids.add(999999)
  val bad = exprTypeCensus(ctx, ids)
  assertEqualInt(bad.count, 1, "one missing entry")
  assertTrue(bad[0].startsWith("I0002"), "reported as I0002")
}

test "an unnumbered file records nothing" {
  val cr = check(parse("package App\nfunc f(): Int { 1 }\n").file)
  assertEqualInt(cr.symbols.exprTypes.count, 0, "node id 0 has no entry")
}

test "a type the checker could not give is an I0002, not a wildcard" {
  val ctx = newTyConvCtx(check(parse("package App\n").file).symbols)
  assertTrue(tyOfType(ctx, tyErrorSilent()).isErr(), "TyError")
  assertTrue(tyOfType(ctx, TyInfer(id = 3)).isErr(), "TyInfer")
  assertTrue(tyOfType(ctx, TySelf).isErr(), "Self outside an interface")
}

test "composite types convert structurally" {
  val ctx = newTyConvCtx(check(parse("package App\n").file).symbols)
  val elems: List[Type] = newList()
  elems.add(TyPrim(pt = PtInt))
  elems.add(TyNullable(inner = TyPrim(pt = PtString)))
  match tyOfType(ctx, TyTuple(elems = elems)) {
    case Ok(t) -> match t {
      case TirT.TTuple(xs) -> {
        assertEqualInt(xs.count, 2, "two elements")
        assertTrue(tyEq(xs[0], TPrim(kind = TPInt)), "first is Int")
      }
      case _ -> assertTrue(false, "expected a tuple")
    }
    case Err(e) -> assertTrue(false, e)
  }
  match tyOfType(ctx, TyPrim(pt = PtNever)) {
    case Ok(t) -> assertTrue(tyEq(t, TirT.TNever), "Never")
    case Err(e) -> assertTrue(false, e)
  }
}

test "a type parameter converts through its registered binder" {
  val ctx = newTyConvCtx(check(parse("package App\n").file).symbols)
  val p = TyParam(name = "T", owner = "id")
  assertTrue(tyOfType(ctx, p).isErr(), "unregistered binder")
  val names: List[String] = newList()
  names.add("U")
  names.add("T")
  tyConvBind(ctx, "id", SymbolId(id = 77), names)
  match tyOfType(ctx, p) {
    case Ok(t) -> assertTrue(tyEq(t, TParam(owner = SymbolId(id = 77), index = 1)), "T is the second parameter")
    case Err(e) -> assertTrue(false, e)
  }
  assertTrue(tyOfType(ctx, TyParam(name = "V", owner = "id")).isErr(), "not declared by its binder")
}

test "a call to a declared function has its callee recorded under the call's node id" {
  val src = "package App\nfunc g(): Int { 1 }\nfunc f(): Int { g() }\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  assertEqualInt(cr.diagnostics.count, 0, "checks clean")
  val ctx = newTyConvCtx(cr.symbols)
  val calls = callSitesOf(file)
  assertEqualInt(calls.count, 1, "one call")
  assertEqualInt(calleeCensus(ctx, calls).count, 0, "its callee is recorded")
  assertEqualInt(cr.symbols.calleeByNode.count, 1, "one entry")
}

test "a call through a function value is marked indirect" {
  val src = "package App\nfunc f(h: in (Int) -> Int): Int { h(1) }\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  val ctx = newTyConvCtx(cr.symbols)
  val calls = callSitesOf(file)
  assertEqualInt(calls.count, 1, "one call")
  assertEqualInt(calleeCensus(ctx, calls).count, 0, "the indirect call is covered")
  assertEqualInt(cr.symbols.indirectByNode.count, 1, "marked indirect")
  assertEqualInt(cr.symbols.calleeByNode.count, 0, "and has no declared callee")
}

test "a method call has its callee recorded under the call's node id" {
  val src = "package App\nrecord P { x: Int }\nfunc P.get(self: in P): Int { self.x }\nfunc f(p: in P): Int { p.get() }\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  assertEqualInt(cr.diagnostics.count, 0, "checks clean")
  val ctx = newTyConvCtx(cr.symbols)
  val calls = callSitesOf(file)
  assertEqualInt(calls.count, 1, "one call")
  assertEqualInt(calleeCensus(ctx, calls).count, 0, "its callee is recorded")
}

test "nested calls and a call inside a lambda argument each have their callee recorded" {
  val src = "package App\nfunc g(x: Int): Int { x }\nfunc apply(f: in (Int) -> Int): Int { f(1) }\nfunc f(): Int { apply({ y: Int -> g(g(y)) }) }\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  assertEqualInt(cr.diagnostics.count, 0, "checks clean")
  val ctx = newTyConvCtx(cr.symbols)
  val calls = callSitesOf(file)
  val missing = calleeCensus(ctx, calls)
  assertEqualInt(calls.count, 4, "f(1), apply(..) and the lambda's outer and inner g calls")
  assertEqualInt(missing.count, 0, "the call through the function value f(1) is marked indirect")
}

test "record and union-case constructor calls have their callee recorded" {
  val src = "package App\nrecord P { x: Int }\nunion U {\n  case A(n: Int)\n  case B\n}\nfunc f(): Int {\n  val p = P(x = 1)\n  val u = A(n = 2)\n  3\n}\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  assertEqualInt(cr.diagnostics.count, 0, "checks clean")
  val ctx = newTyConvCtx(cr.symbols)
  val calls = callSitesOf(file)
  assertEqualInt(calls.count, 2, "P(..) and A(..)")
  assertEqualInt(calleeCensus(ctx, calls).count, 0, "both constructors are recorded")
}

test "built-in functions and built-in members have their name recorded" {
  val src = "package App\nfunc f(s: in slice[Int]): slice[Int] {\n  println(\"a\")\n  s.append(1)\n}\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  assertEqualInt(cr.diagnostics.count, 0, "checks clean")
  val ctx = newTyConvCtx(cr.symbols)
  val calls = callSitesOf(file)
  assertEqualInt(calls.count, 2, "println and append")
  assertEqualInt(calleeCensus(ctx, calls).count, 0, "both are covered")
  assertEqualInt(cr.symbols.builtinByNode.count, 2, "recorded by name")
  assertTrue(
    mapGet(cr.symbols.builtinByNode, calls[1].id) == Some(value = "slice.append"),
    "a member is named by its receiver"
  )
}

test "numeric conversions and string members have their name recorded" {
  val src = "package App\nfunc f(n: in Int, s: in String): Bool {\n  val l = n.toLong()\n  s.startsWith(\"a\")\n}\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  assertEqualInt(cr.diagnostics.count, 0, "checks clean")
  val ctx = newTyConvCtx(cr.symbols)
  val calls = callSitesOf(file)
  assertEqualInt(calls.count, 2, "toLong and startsWith")
  assertEqualInt(calleeCensus(ctx, calls).count, 0, "both are covered")
  assertTrue(
    mapGet(cr.symbols.builtinByNode, calls[0].id) == Some(value = "Int.toLong"),
    "a conversion is named by its receiver"
  )
  assertTrue(mapGet(cr.symbols.builtinByNode, calls[1].id) == Some(value = "String.startsWith"), "a string member too")
}

test "an integer's bitwise method has its name recorded" {
  val src = "package App\nfunc f(n: in Int): Int { n.shl(2) }\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  assertEqualInt(cr.diagnostics.count, 0, "checks clean")
  val ctx = newTyConvCtx(cr.symbols)
  val calls = callSitesOf(file)
  assertEqualInt(calleeCensus(ctx, calls).count, 0, "the call is covered")
  assertTrue(mapGet(cr.symbols.builtinByNode, calls[0].id) == Some(value = "Int.shl"), "named by its receiver")
}

test "interface and impl method calls have their callee recorded" {
  val src = "package App\ninterface Feed {\n  func priceOf(s: in String): Int\n}\nrecord R { x: Int }\nimpl Feed for R {\n  func priceOf(s: in String): Int { self.x }\n}\nrecord T { stub: R }\nimpl Feed for T {\n  func priceOf(s: in String): Int { self.stub.priceOf(s) }\n}\nfunc use(f: in Feed): Int { f.priceOf(\"a\") }\nfunc viaRecord(t: in T): Int { t.stub.priceOf(\"b\") }\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  assertEqualInt(cr.diagnostics.count, 0, "checks clean")
  val ctx = newTyConvCtx(cr.symbols)
  val calls = callSitesOf(file)
  assertEqualInt(calls.count, 2, "the impl method call and the interface call")
  assertEqualInt(calleeCensus(ctx, calls).count, 0, "both are covered")
  assertEqualInt(cr.symbols.calleeByNode.count, 2, "each has a declared callee")
}

record FnBuilt {
  env: BuildEnv
  body: Option[TExpr]
  diagnostics: Int
}

func buildFirstFn(src: in String): FnBuilt {
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  val env = newBuildEnv(newTyConvCtx(cr.symbols))
  var body: Option[TExpr] = None
  var found = false
  for it in file.items {
    match it.kind {
      case IFunc(decl) -> if not found {
        found = true
        body = buildFnBody(env, decl, cr.symbols)
      }
      case _ -> ()
    }
  }
  FnBuilt(env = env, body = body, diagnostics = cr.diagnostics.count)
}

test "a function over locals and primitive operators builds" {
  val r = buildFirstFn("package App\nfunc f(a: Int, b: Int): Int {\n  val c = a + b\n  c * 2\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  match r.body {
    case Some(b) -> match b.kind {
      case XBlock(stmts, tail) -> {
        assertEqualInt(stmts.count, 1, "the val is a statement")
        assertTrue(tail.isSome(), "the last expression is the value")
        assertTrue(tyEq(b.ty, tyInt()), "the block is an Int")
      }
      case _ -> assertTrue(false, "a block")
    }
    case None -> assertTrue(false, "a body")
  }
}

test "if, short-circuit operators and comparisons build" {
  val r = buildFirstFn("package App\nfunc g(x: Int): Bool {\n  if x > 1 and x < 9 { true } else { false }\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  assertTrue(r.body.isSome(), "a body")
}

test "loops and string interpolation build" {
  val r = buildFirstFn("package App\nfunc h(n: Int): String {\n  var i = 0\n  loop {\n    break\n  }\n  \"n={n}\"\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  assertTrue(r.body.isSome(), "a body")
}

test "a call is counted as uncovered, fails with I0002 and builds no body" {
  val r = buildFirstFn("package App\nfunc m(): Int { k() }\nfunc k(): Int { 1 }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(not r.body.isSome(), "no body for a call the builder has no case for")
  assertEqualInt(r.env.errors.count, 1, "one I0002")
  assertTrue(r.env.errors[0].startsWith("I0002"), "reported as I0002")
  assertEqualInt(mapGetOr0(r.env.uncovered, "a call"), 1, "counted by kind")
}

func mapGetOr0(m: in Map[String, Int], k: in String): Int {
  match mapGet(m, k) {
    case Some(n) -> n
    case None -> 0
  }
}
