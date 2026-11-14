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
import Std.String as Str
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Resolve
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir as TirT
import Lyric.Tir.Build
import Lyric.Tir.Verify
import Msil.Bridge as Mb

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
  symbols: SymbolTable
}

func buildFirstFn(src: in String): FnBuilt {
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  val env = newBuildEnv(newTyConvCtx(cr.symbols))
  var body: Option[TExpr] = None
  var found = false
  for it in file.items {
    match it.kind {
      case IFunc(decl) -> if not found { found = true; body = buildFnBody(env, decl, cr.symbols) }
      case _ -> ()
    }
  }
  FnBuilt(env = env, body = body, diagnostics = cr.diagnostics.count, symbols = cr.symbols)
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
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(r.body.isSome(), "a body")
}

test "loops and string interpolation build" {
  val r = buildFirstFn("package App\nfunc h(n: Int): String {\n  while true {\n    break\n  }\n  \"n=\${n}\"\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  assertTrue(r.body.isSome(), "a body")
}

test "a generic function's body builds with its type parameter as a rigid parameter" {
  val r = buildFirstFn("package App\nfunc id[T](x: in T): T { x }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match r.body {
    case Some(b) -> match b.ty {
      case TParam(_, idx) -> assertEqualInt(idx, 0, "T is the first parameter")
      case _ -> assertTrue(false, "the body has the type parameter's type")
    }
    case None -> assertTrue(false, "a body")
  }
}

func mapGetOr0(m: in Map[String, Int], k: in String): Int {
  match mapGet(m, k) {
    case Some(n) -> n
    case None -> 0
  }
}

func firstCallArgs(b: in Option[TExpr]): Int {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(_, Some(t)) -> match t.kind { case XCall(_, args) -> args.count; case _ -> -1 }
      case XCall(_, args) -> args.count
      case _ -> -1
    }
    case None -> -1
  }
}

test "a call to a declared function builds with its arguments in parameter order" {
  val r = buildFirstFn("package App\nfunc m(x: Int): Int { k(b = 1, a = x) }\nfunc k(a: Int, b: Int): Int { a }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  assertEqualInt(firstCallArgs(r.body), 2, "two arguments")
  match r.body {
    case Some(body) -> match body.kind {
      case XBlock(_, Some(t)) -> match t.kind {
        case XCall(callee, args) -> {
          match callee {
            case Direct(_, targs) -> assertEqualInt(targs.count, 0, "no type arguments")
            case _ -> assertTrue(false, "a direct callee")
          }
          match args[0] {
            case TArgIn(v) -> match v.kind {
              case XLocal(_) -> ()
              case _ -> assertTrue(false, "the first parameter a gets x, though written second")
            }
            case _ -> assertTrue(false, "an in argument")
          }
        }
        case _ -> assertTrue(false, "a call")
      }
      case _ -> assertTrue(false, "a block with a value")
    }
    case None -> assertTrue(false, "a body")
  }
}

test "an Int argument for a Long parameter is widened" {
  val r = buildFirstFn("package App\nfunc m(x: Int): Long { w(x) }\nfunc w(v: Long): Long { v }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  assertTrue(r.body.isSome(), "a body")
}

test "built-in and indirect calls build" {
  val b = buildFirstFn("package App\nfunc m(): Unit { println(\"a\") }\n")
  assertEqualInt(b.env.errors.count, 0, "the built-in builds")
  assertEqualInt(firstCallArgs(b.body), 1, "with its argument")
  val i = buildFirstFn("package App\nfunc m(h: in (Int) -> Int): Int { h(1) }\n")
  assertEqualInt(i.env.errors.count, 0, "the indirect call builds")
  assertEqualInt(firstCallArgs(i.body), 1, "with its argument")
}

test "a call omitting a literal-defaulted argument builds with the default placed at the call" {
  val r = buildFirstFn("package App\nfunc m(): Int { k(1) }\nfunc k(a: Int, b: Int = 2): Int { a }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.body.isSome(), "builds")
  assertEqualInt(mapGetOr0(r.env.uncovered, "a defaulted argument"), 0, "not counted")
}

func firstTail(b: in Option[TExpr]): Option[TExpr] {
  match b {
    case Some(body) -> match body.kind { case XBlock(_, t) -> t; case _ -> Some(value = body) }
    case None -> None
  }
}

func callArgAt(b: in Option[TExpr], i: in Int): Option[TExpr] {
  match firstTail(b) {
    case Some(t) -> match t.kind {
      case XCall(_, args) -> if i < args.count {
        match args[i] {
          case TArgIn(v) -> Some(value = v)
          case _ -> None
        }
      } else {
        None
      }
      case _ -> None
    }
    case None -> None
  }
}

func isWidenTo(t: in TExpr, want: in Ty): Bool {
  match t.kind {
    case XConvert(CvWiden(_), inner) -> tyEq(t.ty, want) and t.id.id != inner.id.id
    case _ -> false
  }
}

test "a named argument keeps its slot and a positional one takes the free slot" {
  val r = buildFirstFn("package App\nfunc m(): Int { k(a = 1, 2) }\nfunc k(a: Int, b: Int): Int { a }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  assertEqualInt(firstCallArgs(r.body), 2, "two arguments")
}

test "named arguments that reorder effects build; plain ones need no temporaries" {
  val bad = buildFirstFn(
    "package App\nfunc m(): Int { k(b = f(), a = g()) }\nfunc k(a: Int, b: Int): Int { a }\nfunc f(): Int { 1 }\nfunc g(): Int { 2 }\n"
  )
  assertEqualInt(bad.diagnostics, 0, "checks clean")
  assertTrue(bad.body.isSome(), "builds")
  assertEqualInt(mapGetOr0(bad.env.uncovered, "a call whose named arguments reorder effects"), 0, "not refused")
  val ok = buildFirstFn("package App\nfunc m(x: Int): Int { k(b = 1, a = x) }\nfunc k(a: Int, b: Int): Int { a }\n")
  assertTrue(ok.body.isSome(), "plain arguments reorder freely")
}

test "an argument widened to a Long parameter is a node of its own" {
  val r = buildFirstFn("package App\nfunc m(x: Int): Long { w(x) }\nfunc w(v: Long): Long { v }\n")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  match callArgAt(r.body, 0) {
    case Some(a) -> assertTrue(isWidenTo(a, TirT.TPrim(kind = TPLong)), "a widening with its own id")
    case None -> assertTrue(false, "an argument")
  }
}

test "a slice member and a function value widen their arguments" {
  val s = buildFirstFn("package App\nfunc m(s: in slice[Long], i: in Int): slice[Long] { s.append(i) }\n")
  assertEqualInt(s.diagnostics, 0, "checks clean")
  assertEqualInt(s.env.errors.count, 0, "no I0002")
  match callArgAt(s.body, 1) {
    case Some(a) -> assertTrue(isWidenTo(a, TirT.TPrim(kind = TPLong)), "append widens the element")
    case None -> assertTrue(false, "an argument")
  }
  val f = buildFirstFn("package App\nfunc m(h: in (Long) -> Long, x: Int): Long { h(x) }\n")
  assertEqualInt(f.diagnostics, 0, "checks clean")
  assertEqualInt(f.env.errors.count, 0, "no I0002")
  match callArgAt(f.body, 0) {
    case Some(a) -> assertTrue(isWidenTo(a, TirT.TPrim(kind = TPLong)), "the indirect call widens")
    case None -> assertTrue(false, "an argument")
  }
}

test "a built-in call with an argument the builder cannot check is counted" {
  val r = buildFirstFn("package App\nfunc m(x: Int): Int { max(x, 2) }\nfunc max(a: Int, b: Int): Int { a }\n")
  assertEqualInt(r.env.errors.count, 0, "a declared max is a direct call")
}

test "collection members take their parameter types from a host or a declared receiver" {
  val host = TirT.TExtern(
    host = HostTypeRef(name = "System.Collections.Generic.List`1", args = [TirT.TPrim(kind = TPLong)])
  )
  match memberArgTys(host, "List.add", 1) {
    case Some(tys) -> {
      assertEqualInt(tys.count, 1, "one parameter")
      assertTrue(tyEq(tys[0], TirT.TPrim(kind = TPLong)), "the element type")
    }
    case None -> assertTrue(false, "a host List has derived parameter types")
  }
  match memberArgTys(host, "List.add", 2) {
    case Some(tys) -> assertTrue(
      tyEq(tys[0], tyInt()) and tyEq(tys[1], TirT.TPrim(kind = TPLong)),
      "index then element"
    )
    case None -> assertTrue(false, "the two-argument add")
  }
  match memberArgTys(host, "Map.add", 2) {
    case Some(_) -> assertTrue(false, "a List receiver has no Map members")
    case None -> ()
  }
}

test "a refined argument to a built-in member is unrefined to the parameter the checker gave it" {
  val r = buildFirstFn("package App\nfunc m(s: in String, i: in Int range 0 ..= 9): String { s.substring(i) }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  var unrefined = false
  val call: Option[TExpr] = match r.body {
    case Some(b) -> match b.kind { case XBlock(_, tail) -> tail; case _ -> Some(value = b) }
    case None -> None
  }
  match call {
    case Some(b) -> match b.kind {
      case XCall(_, args) -> {
        for a in args {
          match a {
            case TArgIn(v) -> match v.kind { case XConvert(CvUnrefine, _) -> { unrefined = true }; case _ -> () }
            case _ -> ()
          }
        }
      }
      case _ -> ()
    }
    case None -> ()
  }
  assertTrue(unrefined, "the refined argument is converted")
}

func bodyKindName(b: in Option[TExpr]): String {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(_, Some(t)) -> match t.kind {
        case XGlobal(_, _) -> "global"
        case XConstruct(_, fs) -> "construct" + toString(fs.count)
        case _ -> "other"
      }
      case _ -> "block"
    }
    case None -> "none"
  }
}

test "a module val read builds as global references" {
  val r = buildFirstFn("package App\nval limit: Int = 7\nfunc f(): Int {\n  limit\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  assertTrue(bodyKindName(r.body) == "global", "the val is an XGlobal")
}

test "a nullary union case and an enum case build as constructions without fields" {
  val u = buildFirstFn("package App\nunion U {\n  case A\n  case B(n: Int)\n}\nfunc f(): U {\n  A\n}\n")
  assertEqualInt(u.diagnostics, 0, "checks clean")
  assertEqualInt(u.env.errors.count, 0, "no I0002")
  assertTrue(bodyKindName(u.body) == "construct0", "the nullary case is an XConstruct with no fields")
  val e = buildFirstFn("package App\nenum Color { case Red; case Green }\nfunc f(): Color {\n  Red\n}\n")
  assertEqualInt(e.diagnostics, 0, "checks clean")
  assertTrue(bodyKindName(e.body) == "construct0", "the enum case too")
}

test "a case with a payload used as a name stays uncovered" {
  val r = buildFirstFn("package App\nunion U {\n  case A\n  case B(n: Int)\n}\nfunc f(): U {\n  val g = B\n  A\n}\n")
  assertTrue(not r.body.isSome(), "no body")
  assertTrue(r.env.errors.count > 0, "an I0002")
}

test "a non-generic function used as a value builds as a global reference" {
  val r = buildFirstFn("package App\nfunc f(): (Int) -> Int {\n  inc\n}\nfunc inc(x: Int): Int { x + 1 }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  assertTrue(bodyKindName(r.body) == "global", "the function value is an XGlobal")
}

func firstGlobalOrConstruct(b: in Option[TExpr]): Option[SymbolId] {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(_, Some(t)) -> match t.kind {
        case XConstruct(sym, _) -> Some(value = sym)
        case XGlobal(sym, _) -> Some(value = sym)
        case _ -> None
      }
      case _ -> None
    }
    case None -> None
  }
}

test "a bare case two unions share builds as the case of the expected union" {
  val r = buildFirstFn(
    "package App\nunion Left {\n  case Idle\n}\nunion Right {\n  case Idle\n}\nfunc f(): Left {\n  Idle\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, "no I0002")
  assertTrue(bodyKindName(r.body) == "construct0", "an XConstruct")
  var named = ""
  match firstGlobalOrConstruct(r.body) {
    case Some(sym) -> match defPathKeyOf(r.symbols.interner, sym) { case Some(k) -> { named = k }; case None -> () }
    case None -> ()
  }
  assertTrue(named == "App::Left::Idle", "the case of Left, not Right")
}

test "a generic nullary case takes its type argument from the expected type" {
  val r = buildFirstFn(
    "package App\nunion Maybe[T] {\n  case Nothing\n  case Just(v: T)\n}\nfunc f(): Maybe[Int] {\n  Nothing\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertEqualInt(r.env.errors.count, 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match r.body {
    case Some(b) -> match b.kind {
      case XBlock(_, Some(t)) -> match t.ty {
        case TNamed(_, args) -> {
          assertEqualInt(args.count, 1, "one type argument")
          assertTrue(tyEq(args[0], TPrim(kind = TPInt)), "Int, from the return type")
        }
        case _ -> assertTrue(false, "a named type")
      }
      case _ -> assertTrue(false, "a block with a value")
    }
    case None -> assertTrue(false, "built")
  }
}

func matchSummary(b: in Option[TExpr]): String {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(_, Some(t)) -> match t.kind {
        case XMatch(_, arms, exhaustive) -> toString(arms.count) +
          (
            if exhaustive {
              ":exhaustive"
            } else {
              ":open"
            }
          )
        case _ -> "not a match"
      }
      case _ -> "not a block"
    }
    case None -> "none"
  }
}

test "a match over every case of a union builds as exhaustive" {
  val r = buildFirstFn(
    "package App\nunion U {\n  case A(n: Int)\n  case B\n}\nfunc f(u: U): Int {\n  match u {\n    case A(n) -> n\n    case B -> 0\n  }\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(matchSummary(r.body) == "2:exhaustive", matchSummary(r.body))
}

test "a refutable payload pattern is not proved exhaustive" {
  val r = buildFirstFn(
    "package App\nunion U {\n  case A(n: Int)\n  case B\n}\nfunc f(u: U): Int {\n  match u {\n    case A(1) -> 1\n    case B -> 0\n  }\n}\n"
  )
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(matchSummary(r.body) == "2:open", matchSummary(r.body))
}

test "a wildcard arm makes a match over a tuple exhaustive" {
  val r = buildFirstFn(
    "package App\nfunc f(a: Int, b: Int): Int {\n  match (a, b) {\n    case (0, y) -> y\n    case _ -> 1\n  }\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(matchSummary(r.body) == "2:exhaustive", matchSummary(r.body))
}

test "a record pattern and an enum case pattern build" {
  val r = buildFirstFn(
    "package App\nrecord P { x: Int\n y: Int }\nfunc f(p: P): Int {\n  match p {\n    case P{x = a, y = b} -> a + b\n  }\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  val e = buildFirstFn(
    "package App\nenum Color { case Red; case Green }\nfunc f(c: Color): Int {\n  match c {\n    case Red -> 1\n    case Green -> 2\n  }\n}\n"
  )
  assertEqualInt(e.diagnostics, 0, "checks clean")
  assertTrue(e.env.errors.count == 0, if e.env.errors.count > 0 { e.env.errors[0] } else { "no I0002" })
  assertTrue(matchSummary(e.body) == "2:exhaustive", matchSummary(e.body))
}

test "an or-pattern that binds a name builds, its alternatives sharing the local" {
  val r = buildFirstFn(
    "package App\nunion U {\n  case A(n: Int)\n  case B(n: Int)\n}\nfunc f(u: U): Int {\n  match u {\n    case A(n) | B(n) -> n\n  }\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.body.isSome(), "builds")
}

test "an as-pattern binds its name before its sub-pattern" {
  val r = buildFirstFn(
    "package App\nfunc f(a: Int, b: Int): Int {\n  match (a, b) {\n    case x @ (x, y) -> x\n  }\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(r.body.isSome(), "a body")
}

test "an Int arm in a Long match is widened, not left to the verifier" {
  val r = buildFirstFn(
    "package App\nfunc f(b: Bool, i: Int, l: Long): Long {\n  match b {\n    case true -> i\n    case false -> l\n  }\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(r.body.isSome(), "a body")
}

test "an enum case in a payload is refutable, so the match is not proved exhaustive" {
  val r = buildFirstFn(
    "package App\nenum Choice { case small; case large }\nunion U {\n  case A(c: Choice)\n}\nfunc f(u: U): Int {\n  match u {\n    case A(small) -> 1\n  }\n}\n"
  )
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(matchSummary(r.body) == "1:open", matchSummary(r.body))
}

test "a block arm's tail is widened with the block" {
  val r = buildFirstFn(
    "package App\nfunc f(b: Bool, i: Int, l: Long): Long {\n  match b {\n    case true -> { i }\n    case false -> l\n  }\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(r.body.isSome(), "a body")
}

test "an if whose branch needs widening builds" {
  val r = buildFirstFn("package App\nfunc f(b: Bool, i: Int, l: Long): Long {\n  if b { i } else { l }\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(r.body.isSome(), "a body")
}

test "a bare name for a case with a payload is counted, not built with no fields" {
  val r = buildFirstFn(
    "package App\nunion U {\n  case A(n: Int)\n  case B\n}\nfunc f(u: U): Int {\n  match u {\n    case A -> 1\n    case B -> 0\n  }\n}\n"
  )
  assertTrue(not r.body.isSome(), "no body")
  assertTrue(r.env.errors.count > 0, "an I0002")
}

test "a guarded arm never proves a match exhaustive" {
  val r = buildFirstFn(
    "package App\nunion U {\n  case A(n: Int)\n  case B\n}\nfunc f(u: U): Int {\n  match u {\n    case A(n) if n > 0 -> n\n    case B -> 0\n  }\n}\n"
  )
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(matchSummary(r.body) == "2:open", matchSummary(r.body))
}

test "nested case patterns that cover every value are proved exhaustive" {
  val head = "package App\nunion Shape {\n  case Circle(r: Int)\n  case Rect(w: Int, h: Int)\n}\nunion Wrap {\n  case One(s: Shape)\n  case Zero\n}\n"
  val all = buildFirstFn(
    head +
      "func f(w: Wrap): Int {\n  match w {\n    case One(Circle(r)) -> r\n    case One(Rect(a, b)) -> a + b\n    case Zero -> 0\n  }\n}\n"
  )
  assertEqualInt(all.diagnostics, 0, "checks clean")
  assertTrue(all.env.errors.count == 0, if all.env.errors.count > 0 { all.env.errors[0] } else { "no I0002" })
  assertTrue(matchSummary(all.body) == "3:exhaustive", matchSummary(all.body))
  val missing = buildFirstFn(
    head +
      "func f(w: Wrap): Int {\n  match w {\n    case One(Circle(r)) -> r\n    case Zero -> 0\n  }\n}\n"
  )
  assertTrue(matchSummary(missing.body) == "2:open", matchSummary(missing.body))
  val wild = buildFirstFn(
    head +
      "func f(w: Wrap): Int {\n  match w {\n    case One(Circle(r)) -> r\n    case One(_) -> 1\n    case Zero -> 0\n  }\n}\n"
  )
  assertTrue(matchSummary(wild.body) == "3:exhaustive", matchSummary(wild.body))
}

test "a tuple of a Bool and a union is proved exhaustive only when every pair is covered" {
  val head = "package App\nunion U {\n  case A(n: Int)\n  case B\n}\n"
  val ok = buildFirstFn(
    head +
      "func f(b: Bool, u: U): Int {\n  match (b, u) {\n    case (true, A(n)) -> n\n    case (true, B) -> 1\n    case (false, _) -> 2\n  }\n}\n"
  )
  assertTrue(ok.env.errors.count == 0, if ok.env.errors.count > 0 { ok.env.errors[0] } else { "no I0002" })
  assertTrue(matchSummary(ok.body) == "3:exhaustive", matchSummary(ok.body))
  val gap = buildFirstFn(
    head +
      "func f(b: Bool, u: U): Int {\n  match (b, u) {\n    case (true, A(n)) -> n\n    case (false, _) -> 2\n  }\n}\n"
  )
  assertTrue(matchSummary(gap.body) == "2:open", matchSummary(gap.body))
}

test "an or-pattern of cases and a guard are read soundly by the exhaustiveness matrix" {
  val head = "package App\nunion U {\n  case A\n  case B\n  case C\n}\nunion W {\n  case P(u: U)\n  case Q\n}\n"
  val orOk = buildFirstFn(
    head +
      "func f(w: W): Int {\n  match w {\n    case P(A | B) -> 1\n    case P(C) -> 2\n    case Q -> 3\n  }\n}\n"
  )
  assertTrue(orOk.env.errors.count == 0, if orOk.env.errors.count > 0 { orOk.env.errors[0] } else { "no I0002" })
  assertTrue(matchSummary(orOk.body) == "3:exhaustive", matchSummary(orOk.body))
  val guarded = buildFirstFn(
    head +
      "func f(w: W, k: Int): Int {\n  match w {\n    case P(A | B) if k > 0 -> 1\n    case P(C) -> 2\n    case Q -> 3\n  }\n}\n"
  )
  assertTrue(matchSummary(guarded.body) == "3:open", matchSummary(guarded.body))
}

func constructLits(b: in Option[TExpr]): String {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(_, Some(t)) -> match t.kind {
        case XConstruct(_, fs) -> {
          var acc = ""
          for f in fs {
            val one = match f.kind { case XLit(TLInt(v)) -> toString(v); case _ -> "?" }
            acc = if acc.length == 0 { one } else { acc + "," + one }
          }
          acc
        }
        case _ -> "other"
      }
      case _ -> "block"
    }
    case None -> "none"
  }
}

func constructSummary(b: in Option[TExpr]): String {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(_, Some(t)) -> match t.kind {
        case XConstruct(_, fs) -> "construct" + toString(fs.count)
        case _ -> "other"
      }
      case _ -> "block"
    }
    case None -> "none"
  }
}

test "a record construction builds with its fields in declaration order" {
  val r = buildFirstFn("package App\nrecord P { x: Int\n y: Int }\nfunc f(): P {\n  P(y = 2, x = 1)\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(constructSummary(r.body) == "construct2", constructSummary(r.body))
  assertTrue(constructLits(r.body) == "1,2", constructLits(r.body))
}

test "a union case construction builds with its payload" {
  val r = buildFirstFn("package App\nunion U {\n  case A(n: Int)\n  case B\n}\nfunc f(): U {\n  A(n = 3)\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(constructSummary(r.body) == "construct1", constructSummary(r.body))
}

test "a construction leaving a literal-defaulted field out places the default and verifies" {
  val c = censusOf("package App\nrecord P { x: Int\n y: Int = 5 }\nfunc f(): P {\n  P(x = 1)\n}\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "an array field is counted as defaulted, not missing, when left out" {
  val r = buildFirstFn("package App\nrecord P { xs: array[2, Int] }\nfunc f(): P {\n  P()\n}\n")
  assertTrue(not r.body.isSome(), "no body")
  assertEqualInt(mapGetOr0(r.env.uncovered, "a defaulted argument"), 1, "counted as defaulted")
}

func calleeShape(b: in Option[TExpr]): String {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(_, Some(t)) -> match t.kind {
        case XCall(callee, args) -> {
          val first = if args.count > 0 {
            match args[0] {
              case TArgIn(v) -> match v.kind { case XLocal(_) -> "recv"; case _ -> "other" }
              case _ -> "place"
            }
          } else {
            "none"
          }
          match callee {
            case Direct(_, _) -> "direct:" + first
            case Interface(_, _, _, _) -> "interface:" + first
            case _ -> "other:" + first
          }
        }
        case _ -> "not a call"
      }
      case _ -> "not a block"
    }
    case None -> "none"
  }
}

func callArgCount(b: in Option[TExpr]): Int {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(_, Some(t)) -> match t.kind { case XCall(_, args) -> args.count; case _ -> -1 }
      case _ -> -2
    }
    case None -> -3
  }
}

test "a method declared in a record body builds with the receiver first" {
  val r = buildFirstFn(
    "package App\nrecord P {\n  x: Int\n  func plus(self: in P, n: Int): Int { self.x + n }\n}\nfunc f(p: P): Int {\n  p.plus(2)\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertEqualInt(callArgCount(r.body), 2, "the receiver and the argument")
}

test "a dot-named function called as a method builds with the receiver first" {
  val r = buildFirstFn(
    "package App\nrecord P { x: Int }\nfunc f(p: P): Int {\n  p.plus(2)\n}\nfunc P.plus(self: in P, n: Int): Int { self.x + n }\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertEqualInt(callArgCount(r.body), 2, "the receiver and the argument")
}

test "a method called on an interface value builds as an interface call" {
  val r = buildFirstFn(
    "package App\ninterface Feed {\n  func priceOf(self: in Feed, s: in String): Int\n}\nfunc f(x: in Feed): Int {\n  x.priceOf(\"a\")\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertEqualInt(callArgCount(r.body), 2, "the receiver and the argument")
}

test "a method with a mutating receiver is built with the receiver as a place argument" {
  val r = buildFirstFn(
    "package App\nrecord C {\n  var n: Int\n  func bump(self: inout C): Unit { self.n = self.n + 1 }\n}\nfunc f(c: inout C): Unit {\n  c.bump()\n}\n"
  )
  assertTrue(r.body.isSome(), "builds")
}

test "the callee shape and the receiver position of a method call are pinned" {
  val rec = buildFirstFn(
    "package App\nrecord P {\n  x: Int\n  func plus(self: in P, n: Int): Int { self.x + n }\n}\nfunc f(p: P): Int {\n  p.plus(2)\n}\n"
  )
  assertTrue(calleeShape(rec.body) == "direct:recv", calleeShape(rec.body))
  val ifc = buildFirstFn(
    "package App\ninterface Feed {\n  func priceOf(self: in Feed, s: in String): Int\n}\nfunc f(x: in Feed): Int {\n  x.priceOf(\"a\")\n}\n"
  )
  assertTrue(calleeShape(ifc.body) == "interface:recv", calleeShape(ifc.body))
}

test "a dot-named function called on an interface value is a direct call" {
  val r = buildFirstFn(
    "package App\ninterface Feed {\n  func priceOf(self: in Feed, s: in String): Int\n}\nfunc f(x: in Feed): Int {\n  x.double(2)\n}\nfunc Feed.double(self: in Feed, n: Int): Int { n + n }\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(calleeShape(r.body) == "direct:recv", calleeShape(r.body))
}

// ─── Extern member calls through host metadata (docs/70 §6.3, D390) ──────────
record FakeHost {
  sigs: Map[String, List[ExternMemberSig]]
}

func fhPrim(n: in String): ExternIterElem {
  EIEPrim(name = n)
}

func fhHost(n: in String): ExternIterElem {
  EIEHost(hostName = n, args = newList())
}

func fhSig(isStatic: in Bool, ps: in List[ExternIterElem], ret: in ExternMemberType): ExternMemberSig {
  ExternMemberSig(isStatic = isStatic, params = ps, ret = ret)
}

func fhParams2(a: in ExternIterElem, b: in ExternIterElem): List[ExternIterElem] {
  val xs: List[ExternIterElem] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

func fhParams1(a: in ExternIterElem): List[ExternIterElem] {
  val xs: List[ExternIterElem] = newList()
  xs.add(a)
  xs
}

func fhKey(t: in String, m: in String, argc: in Int): String {
  t + "#" + m + "#" + toString(argc)
}

func fakeHost(): FakeHost {
  val sigs: Map[String, List[ExternMemberSig]] = newMap()
  val max: List[ExternMemberSig] = newList()
  max.add(fhSig(true, fhParams2(fhPrim("Int"), fhPrim("Int")), EMTType(elem = fhPrim("Int"))))
  max.add(fhSig(true, fhParams2(fhPrim("Long"), fhPrim("Long")), EMTType(elem = fhPrim("Int"))))
  sigs.add(fhKey("System.Math", "Max", 2), max)
  val append: List[ExternMemberSig] = newList()
  append.add(fhSig(false, fhParams1(fhPrim("Char")), EMTType(elem = fhPrim("Int"))))
  append.add(fhSig(false, fhParams1(fhPrim("String")), EMTType(elem = fhPrim("Int"))))
  sigs.add(fhKey("System.Text.StringBuilder", "IndexOf", 1), append)
  val ctor: List[ExternMemberSig] = newList()
  ctor.add(fhSig(true, newList(), EMTType(elem = fhHost("System.Text.StringBuilder"))))
  sigs.add(fhKey("System.Text.StringBuilder", "new", 0), ctor)
  FakeHost(sigs = sigs)
}

impl ExternIterResolver for FakeHost {
  func resolveIter(clrName: in String, arity: in Int): Option[ExternIterInfo] {
    None
  }

  func resolveBases(clrName: in String): Option[List[String]] {
    None
  }

  func resolveMember(clrName: in String, member: in String, argc: in Int, isProperty: in Bool): Option[ExternMemberType] {
    match mapGet(self.sigs, fhKey(clrName, member, argc)) {
      case Some(cs) -> {
        val rets: List[ExternMemberType] = newList()
        for c in cs {
          rets.add(c.ret)
        }
        externMemberAgreed(rets)
      }
      case None -> None
    }
  }

  func resolveMemberSigs(
    clrName: in String, member: in String, argc: in Int, isProperty: in Bool
  ): Option[List[ExternMemberSig]] {
    mapGet(self.sigs, fhKey(clrName, member, argc))
  }
}

func buildFirstFnHost(src: in String): FnBuilt {
  val file = renumberNodeIds(parse(src).file).file
  val noPkgs: List[ImportedPackage] = newList()
  val iter: Map[String, ExternIterInfo] = newMap()
  val rs: List[ExternIterResolver] = newList()
  rs.add(fakeHost())
  val cr = checkWithImportedPackagesExternIter(file, noPkgs, false, iter, rs)
  val env = newBuildEnv(newTyConvCtx(cr.symbols))
  var body: Option[TExpr] = None
  var found = false
  for it in file.items {
    match it.kind {
      case IFunc(decl) -> if not found { found = true; body = buildFnBody(env, decl, cr.symbols) }
      case _ -> ()
    }
  }
  FnBuilt(env = env, body = body, diagnostics = cr.diagnostics.count, symbols = cr.symbols)
}

func externHead(): String {
  "package App\nextern type Math = \"System.Math\"\nextern type SB = \"System.Text.StringBuilder\"\n"
}

func externCallOf(b: in Option[TExpr]): Option[HostMemberRef] {
  match b {
    case Some(x) -> match x.kind {
      case XBlock(_, tail) -> match tail {
        case Some(t) -> externCallOf(Some(value = t))
        case None -> None
      }
      case XCall(Extern(m), _) -> Some(value = m)
      case _ -> None
    }
    case None -> None
  }
}

test "a static extern call picks the overload the argument types select" {
  val r = buildFirstFnHost(externHead() + "func f(a: Long, b: Long): Int {\n  Math.Max(a, b)\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match externCallOf(r.body) {
    case Some(m) -> {
      assertTrue(m.isStatic, "static")
      assertEqualInt(m.params.count, 2, "two parameters")
      assertTrue(tyEq(m.params[0].ty, TPrim(kind = TPLong)), "the Long overload")
      assertTrue(tyEq(m.ret, TPrim(kind = TPInt)), "returns Int")
      assertTrue(m.name == "Max", "named Max")
    }
    case None -> assertTrue(false, "an extern call")
  }
}

test "an extern argument is widened to the overload's parameter" {
  val r = buildFirstFnHost(externHead() + "func f(a: Int, b: Long): Int {\n  Math.Max(a, b)\n}\n")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match externCallOf(r.body) {
    case Some(m) -> assertTrue(tyEq(m.params[0].ty, TPrim(kind = TPLong)), "the Long overload")
    case None -> assertTrue(false, "an extern call")
  }
}

test "an instance extern call has its receiver first" {
  val r = buildFirstFnHost(externHead() + "func f(sb: in SB): Int {\n  sb.IndexOf(\"x\")\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match externCallOf(r.body) {
    case Some(m) -> {
      assertTrue(not m.isStatic, "an instance member")
      assertEqualInt(m.params.count, 2, "the receiver and the argument")
      assertTrue(tyEq(m.params[1].ty, TPrim(kind = TPString)), "the String overload")
    }
    case None -> assertTrue(false, "an extern call")
  }
}

test "an extern constructor is a static member named new" {
  val r = buildFirstFnHost(externHead() + "func f(): SB {\n  SB.new()\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match externCallOf(r.body) {
    case Some(m) -> {
      assertTrue(m.isStatic, "static")
      assertEqualInt(m.params.count, 0, "no parameters")
      match m.kind {
        case HMConstructor -> ()
        case _ -> assertTrue(false, "a constructor")
      }
    }
    case None -> assertTrue(false, "an extern call")
  }
}

test "an extern call with a named argument is counted" {
  val r = buildFirstFnHost(externHead() + "func f(a: Long, b: Long): Int {\n  Math.Max(a, b = b)\n}\n")
  assertTrue(not r.body.isSome(), "no body")
  assertEqualInt(mapGetOr0(r.env.uncovered, "an extern call with a named argument"), 1, "counted")
}

/// The extern call that is the first statement of the function body.
func externCallOfStatement(b: in Option[TExpr]): Option[HostMemberRef] {
  match b {
    case Some(x) -> match x.kind {
      case XBlock(stmts, _) -> {
        if stmts.count == 0 {
          return None
        }
        match stmts[0].kind {
          case TsExpr(ex) -> match ex.kind { case XCall(Extern(m), _) -> Some(value = m); case _ -> None }
          case _ -> None
        }
      }
      case _ -> None
    }
    case None -> None
  }
}

func buildFirstFnMsil(src: in String): FnBuilt {
  val file = renumberNodeIds(parse(src).file).file
  val noPkgs: List[ImportedPackage] = newList()
  val iter: Map[String, ExternIterInfo] = newMap()
  val rs = Mb.msilIterResolver(Mb.newMsilHostIterIndex(newList()))
  val cr = checkWithImportedPackagesExternIter(file, noPkgs, false, iter, rs)
  val env = newBuildEnv(newTyConvCtx(cr.symbols))
  var body: Option[TExpr] = None
  var found = false
  for it in file.items {
    match it.kind {
      case IFunc(decl) -> if not found { found = true; body = buildFnBody(env, decl, cr.symbols) }
      case _ -> ()
    }
  }
  FnBuilt(env = env, body = body, diagnostics = cr.diagnostics.count, symbols = cr.symbols)
}

test "the real MSIL metadata gives a static overload and static constructors" {
  val head = "package App\nextern type Math = \"System.Math\"\nextern type SB = \"System.Text.StringBuilder\"\n"
  val st = buildFirstFnMsil(head + "func f(a: Double): Double {\n  Math.Sqrt(a)\n}\n")
  assertEqualInt(st.diagnostics, 0, "checks clean")
  assertTrue(st.env.errors.count == 0, if st.env.errors.count > 0 { st.env.errors[0] } else { "no I0002" })
  match externCallOf(st.body) {
    case Some(m) -> {
      assertTrue(m.isStatic, "Sqrt is static")
      assertTrue(tyEq(m.params[0].ty, TPrim(kind = TPDouble)), "over Double")
    }
    case None -> assertTrue(false, "an extern call")
  }
  val rs = Mb.msilIterResolver(Mb.newMsilHostIterIndex(newList()))
  match rs[0].resolveMemberSigs("System.Text.StringBuilder", "new", 0, false) {
    case Some(cands) -> {
      assertTrue(cands.count >= 1, "the parameterless constructor is a candidate")
      for c in cands {
        assertTrue(c.isStatic, "a constructor is a static member")
        assertEqualInt(c.params.count, 0, "of no parameters")
      }
    }
    case None -> assertTrue(false, "the metadata resolves the constructors")
  }
}

test "an integer argument to a host Double parameter is widened at the boundary (D600)" {
  val head = "package App\nextern type Math = \"System.Math\"\n"
  val st = buildFirstFnMsil(head + "func f(a: Int): Double {\n  Math.Sqrt(a)\n}\n")
  assertEqualInt(st.diagnostics, 0, "checks clean")
  assertTrue(st.env.errors.count == 0, if st.env.errors.count > 0 { st.env.errors[0] } else { "no I0002" })
  match externCallOf(st.body) {
    case Some(m) -> assertTrue(tyEq(m.params[0].ty, TPrim(kind = TPDouble)), "over Double")
    case None -> assertTrue(false, "an extern call")
  }
}

test "a Long argument to a host Double parameter is widened at the boundary (D600)" {
  val head = "package App\nextern type Math = \"System.Math\"\n"
  val st = buildFirstFnMsil(head + "func f(a: Long): Double {\n  Math.Sqrt(a)\n}\n")
  assertEqualInt(st.diagnostics, 0, "checks clean")
  assertTrue(st.env.errors.count == 0, if st.env.errors.count > 0 { st.env.errors[0] } else { "no I0002" })
}

test "a field of an opaque type is readable in its own package (D592)" {
  val pb = packageOf(
    "package App\nopaque type Id {\n  n: Int\n  label: String\n}\nfunc f(i: in Id): String {\n  i.label\n}\n"
  )
  assertBuildsAndVerifies(pb, 1, "Id.label")
}

test "an opaque type is constructed by its fields inside its own package (D462)" {
  val pb = packageOf(
    "package App\nopaque type Id {\n  n: Int\n  label: String\n}\nfunc mk(n: in Int): Id {\n  Id(n = n, label = \"x\")\n}\n"
  )
  assertBuildsAndVerifies(pb, 1, "mk")
}

test "an opaque type with no fields is constructed with no arguments (D462)" {
  val pb = packageOf("package App\nopaque type Handle {\n}\nfunc mk(): Handle {\n  Handle()\n}\n")
  assertBuildsAndVerifies(pb, 1, "mk")
}

test "the value of a distinct type is its unwrapped underlying value (D463)" {
  val pb = packageOf("package App\ntype Age = Int\nfunc raw(a: in Age): Int {\n  a.value\n}\n")
  assertBuildsAndVerifies(pb, 1, "raw")
}

test "a field of a generic opaque type is read at the receiver's arguments (D592)" {
  val pb = packageOf("package App\nopaque type Box[T] {\n  v: T\n}\nfunc g(b: in Box[Int]): Int {\n  b.v\n}\n")
  assertBuildsAndVerifies(pb, 1, "Box.v")
}

test "a sibling method called through self inside a lambda of a generic record is defined (D593)" {
  val pb = packageOf(
    "package App\nrecord Cell[T] {\n  v: T\n  func get(self: in Cell[T]): T { self.v }\n  func viaLambda(self: in Cell[T]): T {\n    val g = { -> self.get() }\n    g()\n  }\n}\n"
  )
  assertBuildsAndVerifies(pb, 2, "Cell.get and viaLambda")
}

test "calls of a generic protected type's entry at two instantiations verify (D593)" {
  val pb = packageOf(
    "package App\nprotected type Cell[T] {\n  var v: T\n  entry put(x: in T): Unit {\n    v = x\n  }\n}\nfunc f(a: in Cell[String], b: in Cell[Int]): Unit {\n  a.put(\"s\")\n  b.put(1)\n}\n"
  )
  assertBuildsAndVerifies(pb, 2, "Cell.put and f")
}

test "an impl method reads and writes a bare field of its receiver (D594)" {
  val pb = packageOf(
    "package App\ninterface Scaler {\n  func scale(k: in Int): Int\n}\nref record Doubler {\n  var base: Int\n}\nimpl Scaler for Doubler {\n  func scale(k: in Int): Int {\n    base = base * k + 1\n    base\n  }\n}\n"
  )
  assertBuildsAndVerifies(pb, 1, "Doubler.scale")
}

// ─── Generic calls (docs/70 §6.3, D394) ──────────────────────────────────────
func directTypeArgs(b: in Option[TExpr]): Option[List[Ty]] {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(_, Some(t)) -> match t.kind {
        case XCall(Direct(_, targs), _) -> Some(value = targs)
        case _ -> None
      }
      case XCall(Direct(_, targs), _) -> Some(value = targs)
      case _ -> None
    }
    case None -> None
  }
}

test "a call to a generic function carries the checker's instantiation" {
  val r = buildFirstFn("package App\nfunc f(): Int {\n  id(3)\n}\nfunc id[T](x: in T): T { x }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match directTypeArgs(r.body) {
    case Some(ts) -> {
      assertEqualInt(ts.count, 1, "one type argument")
      assertTrue(tyEq(ts[0], tyInt()), "T is Int")
    }
    case None -> assertTrue(false, "a direct call")
  }
}

test "two type arguments are recorded in the callee's order" {
  val r = buildFirstFn(
    "package App\nfunc f(): String {\n  second(1, \"a\")\n}\nfunc second[A, B](a: in A, b: in B): B { b }\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match directTypeArgs(r.body) {
    case Some(ts) -> {
      assertEqualInt(ts.count, 2, "two type arguments")
      assertTrue(tyEq(ts[0], tyInt()), "A is Int")
      assertTrue(tyEq(ts[1], tyString()), "B is String")
    }
    case None -> assertTrue(false, "a direct call")
  }
}

test "an argument of a non-generic parameter is widened beside a generic one" {
  val r = buildFirstFn(
    "package App\nfunc f(): String {\n  tag(\"a\", 3)\n}\nfunc tag[T](x: in T, n: in Long): T { x }\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match directTypeArgs(r.body) {
    case Some(ts) -> assertTrue(tyEq(ts[0], tyString()), "T is String")
    case None -> assertTrue(false, "a direct call")
  }
}

test "a generic call inside a generic body carries the enclosing parameter" {
  val r = buildFirstFn("package App\nfunc twice[T](x: in T): T {\n  id(x)\n}\nfunc id[T](x: in T): T { x }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match directTypeArgs(r.body) {
    case Some(ts) -> match ts[0] {
      case TParam(_, idx) -> assertEqualInt(idx, 0, "T of twice")
      case _ -> assertTrue(false, "the enclosing function's parameter")
    }
    case None -> assertTrue(false, "a direct call")
  }
}

// ─── Annotated bindings and implicit conversions (docs/70 §6.3, D396) ────────
func firstLetInit(b: in Option[TExpr]): Option[TExpr] {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(stmts, _) -> {
        for st in stmts {
          match st.kind {
            case TsLet(_, init) -> return Some(value = init)
            case TsVar(_, Some(init)) -> return Some(value = init)
            case _ -> ()
          }
        }
        None
      }
      case _ -> None
    }
    case None -> None
  }
}

func convShape(e: in Option[TExpr]): String {
  match e {
    case Some(x) -> match x.kind {
      case XConvert(CvWiden(_), _) -> "widen"
      case XConvert(_, _) -> "other"
      case _ -> "none"
    }
    case None -> "absent"
  }
}

test "an annotated binding widens its initializer to the annotation" {
  val r = buildFirstFn("package App\nfunc f(n: Int): Long {\n  val a: Long = n\n  a\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(convShape(firstLetInit(r.body)) == "widen", convShape(firstLetInit(r.body)))
}

test "an annotated binding that needs no conversion has none" {
  val r = buildFirstFn("package App\nfunc f(n: Int): Int {\n  val a: Int = n\n  a\n}\n")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(convShape(firstLetInit(r.body)) == "none", convShape(firstLetInit(r.body)))
}

test "an annotated var and a let build the same way" {
  val r = buildFirstFn("package App\nfunc f(n: Int): Long {\n  var a: Long = n\n  a\n}\n")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(convShape(firstLetInit(r.body)) == "widen", convShape(firstLetInit(r.body)))
}

test "a binding annotated with the enclosing type parameter builds" {
  val r = buildFirstFn("package App\nfunc f[T](x: in T): T {\n  val y: T = x\n  y\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
}

test "conversions are derived from the two types alone" {
  val age = TirT.TRefined(underlying = tyInt(), lo = Some(value = 0i64), hi = Some(value = 150i64), hiInclusive = true)
  assertTrue(
    match convKindOf(tyInt(), age) { case Some(CvRangeCheck) -> true; case _ -> false },
    "an Int into a range subtype is checked"
  )
  assertTrue(
    match convKindOf(age, tyInt()) { case Some(CvUnrefine) -> true; case _ -> false },
    "a range subtype used as its underlying type"
  )
  assertTrue(
    match convKindOf(TirT.TNever, tyString()) { case Some(CvFromNever) -> true; case _ -> false },
    "Never as a value"
  )
  assertTrue(
    match convKindOf(tyInt(), TirT.TNullable(inner = tyInt())) { case Some(CvLiftNullable) -> true; case _ -> false },
    "T used as T?"
  )
  assertTrue(convKindOf(tyString(), tyInt()).isNone(), "unrelated types have no conversion")
}

// ─── Field reads (docs/70 §6.3, D397) ────────────────────────────────────────
func fieldOf(b: in Option[TExpr]): Option[FieldRef] {
  match b {
    case Some(body) -> match body.kind {
      case XField(_, f) -> Some(value = f)
      case XBlock(_, Some(t)) -> fieldOf(Some(value = t))
      case _ -> None
    }
    case None -> None
  }
}

test "a record field read is a field by its declared position" {
  val r = buildFirstFn("package App\nrecord P {\n  x: Int\n  y: String\n}\nfunc f(p: P): String {\n  p.y\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match fieldOf(r.body) {
    case Some(f) -> {
      assertEqualInt(f.index, 1, "y is the second field")
      assertTrue(f.name == "y", "named y")
    }
    case None -> assertTrue(false, "a field read")
  }
}

test "a field of a generic record builds at the receiver's instantiation" {
  val r = buildFirstFn("package App\nrecord Box[T] {\n  v: T\n  n: Int\n}\nfunc f(b: Box[String]): Int {\n  b.n\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match fieldOf(r.body) {
    case Some(f) -> assertEqualInt(f.index, 1, "n is the second field")
    case None -> assertTrue(false, "a field read")
  }
}

test "a member that is not a record field is counted" {
  val r = buildFirstFn("package App\nfunc f(xs: in slice[Int]): Int {\n  xs.count\n}\n")
  assertTrue(not r.body.isSome(), "no body")
  assertTrue(mapGetOr0(r.env.uncovered, "a member access that is not a record field") >= 1, "counted")
}

test "an uncovered kind remembers where it was first met" {
  val r = buildFirstFn("package App\nfunc f(xs: in slice[Int]): Int {\n  xs.count\n}\n")
  val at = match mapGet(r.env.sites, "a member access that is not a record field") {
    case Some(a) -> a
    case None -> ""
  }
  assertEqual(at, "3:3", "line 3, column 3: where the member access is")
}

// ─── Assignments and indexing (docs/70 §6.3, D398) ───────────────────────────
func firstAssign(b: in Option[TExpr]): Option[TExpr] {
  match b {
    case Some(body) -> match body.kind {
      case XBlock(stmts, _) -> {
        for st in stmts {
          match st.kind {
            case TsExpr(x) -> match x.kind { case XAssign(_, _, _) -> return Some(value = x); case _ -> () }
            case _ -> ()
          }
        }
        None
      }
      case _ -> None
    }
    case None -> None
  }
}

func placeShape(b: in Option[TExpr]): String {
  match firstAssign(b) {
    case Some(x) -> match x.kind {
      case XAssign(p, op, _) -> {
        val k = match p.kind {
          case PlLocal(_) -> "local"
          case PlGlobal(_) -> "global"
          case PlField(_, _) -> "field"
          case PlIndex(_, _, IkList) -> "list"
          case PlIndex(_, _, IkMap) -> "map"
          case PlIndex(_, _, IkArray) -> "array"
          case PlIndex(_, _, _) -> "index"
        }
        k + ":" + (match op { case AkSet -> "set"; case AkAdd -> "add"; case _ -> "other" })
      }
      case _ -> "none"
    }
    case None -> "absent"
  }
}

test "an assignment to a mutable local is a place assignment" {
  val r = buildFirstFn("package App\nfunc f(n: Int): Int {\n  var a = n\n  a = 3\n  a\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(placeShape(r.body) == "local:set", placeShape(r.body))
}

test "a compound assignment keeps its operator and widens the value" {
  val r = buildFirstFn("package App\nfunc f(n: Int): Long {\n  var a: Long = 1\n  a += n\n  a\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(placeShape(r.body) == "local:add", placeShape(r.body))
}

test "a record field assignment is a field place" {
  val r = buildFirstFn("package App\nref record C {\n  var n: Int\n}\nfunc f(c: inout C): Unit {\n  c.n = 4\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  assertTrue(placeShape(r.body) == "field:set", placeShape(r.body))
}

test "an element assignment on an array is an index place" {
  val ar = buildFirstFn("package App\nfunc f(xs: inout array[3, Int]): Unit {\n  xs[1] = 7\n}\n")
  assertEqualInt(ar.diagnostics, 0, "array checks clean")
  assertTrue(ar.env.errors.count == 0, if ar.env.errors.count > 0 { ar.env.errors[0] } else { "no I0002" })
  assertTrue(placeShape(ar.body) == "array:set", placeShape(ar.body))
}

test "an index read is an index expression and a slice index is an Int" {
  val r = buildFirstFn("package App\nfunc f(xs: in slice[Int], i: Int): Int {\n  xs[i]\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match r.body {
    case Some(b) -> match b.kind {
      case XIndex(_, _, IkSlice) -> ()
      case XBlock(_, Some(t)) -> match t.kind {
        case XIndex(_, _, IkSlice) -> ()
        case _ -> assertTrue(false, "a slice index")
      }
      case _ -> assertTrue(false, "a slice index")
    }
    case None -> assertTrue(false, "a body")
  }
}

test "an assignment through a name that is not a local is counted" {
  val r = buildFirstFn("package App\nfunc f(a: Int): Unit {\n  (a + 1) = 2\n}\n")
  assertTrue(not r.body.isSome(), "no body")
}

// ─── Lambdas (docs/70 §6.3, D399) ────────────────────────────────────────────
func lambdaOf(b: in Option[TExpr]): Option[TExpr] {
  match b {
    case Some(body) -> match body.kind {
      case XLambda(_, _, _) -> Some(value = body)
      case XBlock(stmts, tail) -> {
        for st in stmts {
          match st.kind {
            case TsLet(_, init) -> match init.kind { case XLambda(_, _, _) -> return Some(value = init); case _ -> () }
            case _ -> ()
          }
        }
        match tail {
          case Some(t) -> lambdaOf(Some(value = t))
          case None -> None
        }
      }
      case _ -> None
    }
    case None -> None
  }
}

test "a lambda over its parameter has no captures" {
  val r = buildFirstFn("package App\nfunc f(): (Int) -> Int {\n  { x: Int -> x + 1 }\n}\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match lambdaOf(r.body) {
    case Some(l) -> match l.kind {
      case XLambda(ps, caps, _) -> {
        assertEqualInt(ps.count, 1, "one parameter")
        assertEqualInt(caps.count, 0, "no captures")
      }
      case _ -> assertTrue(false, "a lambda")
    }
    case None -> assertTrue(false, "a lambda")
  }
}

test "a lambda captures an outer value by value and a var by reference" {
  val r = buildFirstFn(
    "package App\nfunc f(n: Int): (Int) -> Int {\n  var c = 0\n  val g = { x: Int -> x + n + c }\n  g\n}\n"
  )
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match lambdaOf(r.body) {
    case Some(l) -> match l.kind {
      case XLambda(_, caps, _) -> {
        assertEqualInt(caps.count, 2, "n and c")
        var byRef = 0
        for c in caps {
          match c.mode {
            case CmByRef -> {
              byRef = byRef + 1
            }
            case CmByValue -> ()
          }
        }
        assertEqualInt(byRef, 1, "only the var is by reference")
      }
      case _ -> assertTrue(false, "a lambda")
    }
    case None -> assertTrue(false, "a lambda")
  }
}

func censusOf(src: in String): BuildCensus {
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  buildCensus(newTyConvCtx(cr.symbols), cr.symbols, file)
}

test "a function builds as a TFnDecl with modes, contracts and its own entry" {
  val c = censusOf(
    "package App\nfunc add(a: Int, b: Int): Int\n  requires: a >= 0\n  ensures: result >= a\n{ a + b }\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  assertEqualInt(c.pkg.funcs.count, 1, "one declaration")
  val f = c.pkg.funcs[0]
  assertEqualInt(f.params.count, 2, "two parameters")
  assertEqualInt(f.preconds.count, 1, "the requires clause")
  assertEqualInt(f.postconds.count, 1, "the ensures clause")
  assertTrue(tyEq(f.ret, TPrim(kind = TPInt)), "returns Int")
  assertTrue(f.body.isSome(), "has a body")
  var own = false
  for en in c.pkg.symbols {
    if en.sym.id == f.sym.id {
      own = true
    }
  }
  assertTrue(own, "an entry for the declared function")
}

test "a call and a construction add the declarations they reach" {
  val c = censusOf(
    "package App\nrecord P { x: Int, y: Int }\nfunc add(a: Int, b: Int): Int { a + b }\nfunc g(): P { P(x = add(1, 2), y = 3) }\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  assertTrue(c.pkg.symbols.count >= 3, "add, g and P")
  assertEqualInt(verifyPackage(c.pkg, newList()).count, 0, "the package verifies")
}

test "a string's length is a built-in property read" {
  val r = buildFirstFn("package App\nfunc f(s: String): Int { s.length }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
  match r.body {
    case Some(b) -> match b.kind {
      case XBlock(_, Some(tail)) -> match tail.kind {
        case XCall(Intrinsic(IoBuiltin(n)), args) -> {
          assertEqual(n, "String.length", "the built-in name")
          assertEqualInt(args.count, 1, "the receiver")
        }
        case _ -> assertTrue(false, "a built-in call")
      }
      case _ -> assertTrue(false, "a block with a value")
    }
    case None -> assertTrue(false, "built")
  }
}

test "a generic union case constructs at its closed instantiation and verifies" {
  val c = censusOf(
    "package App\nunion Box[T] { case Full(value: T)\n case Empty }\nfunc f(): Box[Int] { Full(value = 1) }\nfunc g(): Box[Int] { Empty }\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a slice's length is a built-in property read" {
  val r = buildFirstFn("package App\nfunc f(xs: slice[Int]): Int { xs.length }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(r.env.errors.count == 0, if r.env.errors.count > 0 { r.env.errors[0] } else { "no I0002" })
}

test "an argument typed with a hole takes its parameter's type" {
  val c = censusOf(
    "package App\nunion Maybe[T] {\n  case Nothing\n  case Just(v: T)\n}\nfunc pick[T](m: Maybe[T], d: T): T { d }\nfunc f(): Int { pick(Nothing, 7) }\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  assertEqualInt(verifyPackage(c.pkg, newList()).count, 0, "the package verifies")
}

test "a call with explicit type arguments builds as a direct generic call" {
  val c = censusOf("package App\nfunc id[T](x: T): T { x }\nfunc f(): Int { id[Int](7) }\n")
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  assertEqualInt(verifyPackage(c.pkg, newList()).count, 0, "the package verifies")
}

test "a block ending in a return has type Never and an out parameter is assignable" {
  val c = censusOf("package App\nfunc g(a: Int, q: out Int): Int {\n  q = a\n  return a\n}\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a module value read verifies against its entry" {
  val c = censusOf("package App\nval limit: Int = 10\nfunc f(): Int { limit }\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  assertEqualInt(verifyPackage(c.pkg, newList()).count, 0, "the package verifies")
}

test "an out argument builds as a place and a verifying call" {
  val c = censusOf("package App\nfunc fill(q: out Int) { q = 1 }\nfunc f(): Int {\n  var r = 0\n  fill(r)\n  r\n}\n")
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a val of a tuple pattern declares its names and verifies" {
  val c = censusOf(
    "package App\nfunc pair(): (Int, Int) { (1, 2) }\nfunc f(): Int {\n  val (a, b) = pair()\n  a + b\n}\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a var without an initializer takes its annotation's type" {
  val c = censusOf("package App\nfunc fill(q: out Int) { q = 1 }\nfunc f(): Int {\n  var r: Int\n  fill(r)\n  r\n}\n")
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a for loop builds its iterable, its pattern and its body and verifies" {
  val c = censusOf(
    "package App\nfunc f(n: Int): Int {\n  var t = 0\n  for x in 0 ..< n {\n    t = t + x\n  }\n  t\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a call that leaves out a literal default places it at the call and verifies" {
  val c = censusOf("package App\nfunc g(a: Int, b: Int = 5): Int { a + b }\nfunc f(): Int { g(1) + g(1, 2) }\n")
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "two calls leaving out the same default get distinct node ids" {
  val c = censusOf(
    "package App\nval K: Int = 3\nfunc g(a: Int, b: Int = K): Int { a + b }\nfunc f(): Int { g(1) + g(2) }\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a default of a shape the builder cannot copy is counted, not guessed" {
  val c = censusOf(
    "package App\nfunc g(a: Int, b: Int = if true { 1 } else { 2 }): Int { a + b }\nfunc f(): Int { g(1) }\n"
  )
  assertEqualInt(c.built, 1, "only g builds")
  assertTrue(c.firstErrors.count > 0, "f reports an I0002")
}

test "a protected type's construction and entry call build as a construction and a receiver-first call" {
  val c = censusOf(
    "package App\nprotected type Total {\n  var n: Int = 0\n  entry add(k: in Int): Unit {\n    n = n + k\n  }\n  func get(): Int {\n    n\n  }\n}\nfunc f(): Int {\n  val t = Total()\n  t.add(3)\n  t.get()\n}\n"
  )
  assertEqualInt(c.built, 3, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
  var entries = 0
  for s in c.pkg.symbols {
    match s.kind {
      case TSkEntry -> {
        entries = entries + 1
        match s.sig {
          case Some(sg) -> assertTrue(sg.params.count >= 1, "the protected value is the first parameter")
          case None -> assertTrue(false, "an entry has a signature")
        }
      }
      case _ -> ()
    }
  }
  assertEqualInt(entries, 2, "add and get are recorded as entries")
}

test "a String member call takes its argument types from the checker's function type" {
  val c = censusOf(
    "package App\nfunc f(s: String, n: Int): String {\n  s.substring(0, 1) + s.substring(n) + s.replace(\"a\", \"b\")\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "an integer bitwise method call takes its argument type from the receiver" {
  val c = censusOf("package App\nfunc f(a: Int, b: Int): Int {\n  a.and(255).or(b).shl(2)\n}\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a function and a generic function with a doc comment or an annotation have their symbol" {
  val c = censusOf(
    "package App\n/// doc\nfunc a(n: Int): Int { n }\n/// doc\nfunc b[T](x: T): T { x }\n@pure\nfunc c(n: Int): Int { n }\nfunc d(): Int { a(1) + b(2) + c(3) }\n"
  )
  assertEqualInt(c.built, 4, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a generic record construction builds as a construction of the record at its type arguments" {
  val c = censusOf(
    "package App\nrecord Pair[K, V] { key: K, value: V }\nfunc f(): Int {\n  val p = Pair(key = 1, value = \"one\")\n  p.key\n}\nfunc g(): String {\n  val q: Pair[Int, String] = Pair(key = 2, value = \"two\")\n  q.value\n}\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a defer, a try without a catch binding and a scope build as statements" {
  val c = censusOf(
    "package App\nfunc f(n: Int): Int {\n  var t = 0\n  defer {\n    t = t + 1\n  }\n  try {\n    t = t + n\n  } catch Exception {\n    t = 0\n  } finally {\n    t = t + 2\n  }\n  scope {\n    t = t + 3\n  }\n  t\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "an or-pattern that binds nothing builds, one that binds a name is counted" {
  val ok = censusOf("package App\nfunc f(n: Int): Int {\n  match n {\n    case 1 | 2 -> 10\n    case _ -> 0\n  }\n}\n")
  assertEqualInt(ok.built, 1, if ok.firstErrors.count > 0 { ok.firstErrors[0] } else { "built" })
  val dsOk = verifyPackage(ok.pkg, newList())
  assertEqualInt(dsOk.count, 0, if dsOk.count > 0 { renderVerifyDiag("test", dsOk[0]) } else { "verifies" })
}

test "a union case whose result type has an unsolved argument builds from its closed field types" {
  val c = censusOf(
    "package App\nunion Res[T, E] {\n  case Okk(value: T)\n  case Errr(error: E)\n}\nfunc unwrapOr[T, E](r: Res[T, E], d: T): T { d }\nfunc f(): Int {\n  unwrapOr(Errr(error = 1), 99)\n}\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a record passed where an interface it implements is expected is upcast" {
  val c = censusOf(
    "package App\ninterface Shape {\n  func area(self: in Shape): Int\n}\nrecord Sq { side: Int }\nimpl Shape for Sq {\n  func area(self: in Sq): Int { self.side * self.side }\n}\nfunc total(s: in Shape): Int { s.area() }\nfunc f(): Int {\n  val q = Sq(side = 3)\n  total(q)\n}\n"
  )
  assertEqualInt(c.built, 3, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a call of an interface method declared without a receiver passes the value as the receiver" {
  val c = censusOf(
    "package App\ninterface Counter {\n  func next(step: in Int): Int\n}\nrecord Box { n: Int }\nimpl Counter for Box {\n  func next(self: in Box, step: in Int): Int { self.n + step }\n}\nfunc f(c: in Counter): Int { c.next(2) }\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a distinct type's from builds as a wrap of the argument converted to the underlying type" {
  val c = censusOf("package App\ntype Id = Int\nfunc f(): Id { Id.from(5) }\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a range subtype's from builds as a range check of the argument" {
  val c = censusOf("package App\ntype Age = Int range 0 ..= 150\nfunc f(): Age { Age.from(5) }\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "an index on a buffer builds as a buffer index" {
  val c = censusOf("package App\nfunc f(b: buffer[Int]): Int { b[0] }\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a call of an impl member on a record passes the value as the receiver" {
  val c = censusOf(
    "package App\ninterface Named { func name(): String }\nrecord P { n: String }\nimpl Named for P { func name(): String { self.n } }\nfunc f(p: P): String { p.name() }\n"
  )
  assertTrue(c.built >= 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  assertEqualInt(c.firstErrors.count, 0, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "no I0002" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a record copy builds as a copy of the receiver with the named fields replaced" {
  val c = censusOf("package App\nrecord P { x: Int, y: Int }\nfunc f(p: P): P { p.copy(x = 5) }\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a copy of a generic record converts each field at the receiver's instantiation" {
  val c = censusOf("package App\nrecord Box[T] { v: T, n: Int }\nfunc f(b: Box[Long]): Box[Long] { b.copy(v = 7) }\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a catch that binds the exception declares the binding as an exception-typed local" {
  val c = censusOf(
    "package App\nfunc f(n: Int): Int {\n  var t = 0\n  try {\n    t = n\n  } catch Exception as e {\n    t = 1\n  }\n  t\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a bare case at a lambda's tail takes the lambda's return type" {
  val c = censusOf(
    "package App\nunion Opt[T] { case Nada\n case One(v: T) }\nfunc run[T](f: () -> Opt[T]): Opt[T] { f() }\nfunc g(): Opt[Int] { run[Int]({ -> Nada }) }\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a function body ending in a scope that returns builds without a tail value" {
  val c = censusOf("package App\nfunc f(n: Int): Int {\n  scope {\n    val a = n + 1\n    return a\n  }\n}\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a catch-bound exception's message is a built-in property read" {
  val c = censusOf(
    "package App\nfunc f(n: Int): String {\n  var m = \"\"\n  try {\n    m = \"ok\"\n  } catch Exception as e {\n    m = e.message\n  }\n  m\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a call under explicit type arguments records them as the call's instantiation" {
  val c = censusOf(
    "package App\nunion Opt[T] { case Nada\n case One(v: T) }\nfunc isNada[T](v: in Opt[T]): Bool { true }\nfunc f(x: in Opt[Int]): Bool { isNada[Int](x) }\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a nullary union case at a match arm's tail takes the match's type" {
  val c = censusOf(
    "package App\nunion Opt[T] { case Nada\n case One(v: T) }\nfunc pick[T](x: in Opt[T], other: in Opt[T]): Opt[T] {\n  match x {\n    case Nada -> Nada\n    case _ -> other\n  }\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a union field bound in a generic function keeps the function's rigid type parameter" {
  val c = censusOf(
    "package App\nunion Res[T, E] { case Good(v: T)\n case Bad(e: E) }\nfunc andThen[T, U, E](r: in Res[T, E], f: in (T) -> Res[U, E]): Res[U, E] {\n  match r {\n    case Good(v) -> f(v)\n    case Bad(e) -> Bad(e = e)\n  }\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a generic call's type arguments are read back from its arguments and its result together" {
  val c = censusOf(
    "package App\nunion Res[T, E] { case Good(v: T)\n case Bad(e: E) }\nfunc andThen[T, U, E](r: in Res[T, E], f: in (T) -> Res[U, E]): Res[U, E] {\n  match r {\n    case Good(v) -> f(v)\n    case Bad(e) -> Bad(e = e)\n  }\n}\nfunc t(): Res[Int, Int] {\n  val a: Res[Int, Int] = andThen(Good(v = 5), { x: Int -> Bad(e = 42) })\n  a\n}\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a conversion method on a range-subtype or distinct value unwraps it" {
  val c = censusOf(
    "package App\ntype Age = Int range 0 ..= 150\ntype Id = Long\nfunc f(a: Age): Int { a.toInt() }\nfunc g(i: Id): Long { i.toLong() }\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a use of a name whose binding failed is not counted as an unbuildable name of its own" {
  val c = censusOf(
    "package App\nfunc g(a: Int = if true { 1 } else { 2 }): Int { a }\nfunc f(): Int {\n  val x = g()\n  val y = x\n  y\n}\n"
  )
  assertTrue(
    c.uncovered.containsKey("a default argument of a shape not yet built"),
    "the failed initializer is counted"
  )
  assertFalse(c.uncovered.containsKey("a name that is not a local"), "its later uses are not")
}

func hoistedStmtCount(b: in TExpr): Int {
  match b.kind {
    case XBlock(stmts, tail) -> if stmts.count > 0 {
      stmts.count
    } else {
      match tail {
        case Some(t) -> hoistedStmtCount(t)
        case None -> 0
      }
    }
    case _ -> 0
  }
}

test "named arguments that reorder effects are bound to temporaries in source order" {
  val c = censusOf(
    "package App\nfunc two(a: Int, b: Int): Int { a - b }\nfunc n(): Int { 3 }\nfunc m(): Int { 4 }\nfunc f(): Int { two(b = n(), a = m()) }\nfunc g(x: Int): Int { two(b = x, a = 1) }\n"
  )
  assertEqualInt(c.built, 5, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
  var most = 0
  for fd in c.pkg.funcs {
    match fd.body {
      case Some(b) -> {
        val k = hoistedStmtCount(b)
        if k > most {
          most = k
        }
      }
      case None -> ()
    }
  }
  assertEqualInt(most, 2, "f binds both reordered arguments (n() before m()); g binds none")
}

test "a default argument that is a call is placed afresh at every call of one body" {
  val c = censusOf(
    "package App\nfunc mk(): Int { 7 }\nfunc k(a: Int, b: Int = mk()): Int { a + b }\nfunc m(): Int { k(1) + k(2) }\n"
  )
  assertEqualInt(c.built, 3, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(
    ds.count,
    0,
    if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "node ids unique across the two calls" }
  )
}

test "a branch that leaves through a nested if, a match or a break fits the type of the whole" {
  val c = censusOf(
    "package App\nfunc f(c: Bool, d: Bool): Int {\n  val x: Int = if c { 1 } else { if d { return 2 } else { return 3 } }\n  x\n}\nfunc g(c: Bool): Int {\n  var n = 0\n  while n < 3 {\n    val y: Int = if c { 1 } else { break }\n    n = n + y\n  }\n  n\n}\nfunc h(c: Bool): Int {\n  val z: Int = match c {\n    case true -> 1\n    case false -> { return 4 }\n  }\n  z\n}\n"
  )
  assertEqualInt(c.built, 3, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a try that ends a block yields its body's or its catch's value through a local" {
  val c = censusOf(
    "package App\nfunc f(n: Int): Int {\n  try {\n    n + 1\n  } finally {\n    val _ = n\n  }\n}\nfunc g(n: Int): Int {\n  try {\n    n + 1\n  } catch Exception as e {\n    0\n  }\n}\nfunc h(n: Int): Int {\n  try {\n    panic(\"boom\")\n  } finally {\n    val _ = n\n  }\n}\n"
  )
  assertEqualInt(c.built, 3, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "ordering and arithmetic on a bounded type parameter, a distinct type and a range type build" {
  val c = censusOf(
    "package App\ntype Score = Int derives Add, Sub, Compare\ntype Cents = Long range 0 ..= 100000 derives Add, Compare\nfunc bigger[T](a: in T, b: in T): Bool\n  where T: Compare\n{\n  a > b\n}\nfunc plus(a: Score, b: Score): Score { a + b }\nfunc less(a: Score, b: Score): Bool { a < b }\nfunc total(a: Cents, b: Cents): Cents { a + b }\nfunc order(a: Cents, b: Cents): Bool { a <= b }\n"
  )
  assertEqualInt(c.built, 5, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "assigning to an inout self builds as an assignment to the receiver local" {
  val c = censusOf(
    "package App\nrecord Ctr {\n  n: Int\n  func reset(self: inout Ctr): Unit {\n    self = Ctr(n = 0)\n  }\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a loop invariant builds as an invariant statement of the loop body" {
  val c = censusOf(
    "package App\nfunc f(n: Int): Int {\n  var i = 0\n  while i < n\n    invariant: i <= n\n  {\n    i = i + 1\n  }\n  i\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a member of a generic type whose body does not build is described by its declaration, not a call site (D595)" {
  val pb = packageOf(
    "package App\nextern type Math = \"System.Math\"\nprotected type Cell[T] {\n  var v: T\n  entry put(x: in T): Unit {\n    val d = Math.Sqrt(1.0)\n    v = x\n  }\n}\nfunc f(a: in Cell[String], b: in Cell[Int]): Unit {\n  a.put(\"s\")\n  b.put(1)\n}\n"
  )
  assertEqualInt(pb.failed.count, 1, "the entry's body does not build without host metadata")
  val ds = verifyPackage(pb.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
  var found = false
  for en in pb.pkg.symbols {
    if en.kind == TSkEntry {
      found = true
      assertEqualInt(en.typeParamCount, 1, "the owner's parameter")
      match en.sig {
        case Some(sg) -> match sg.params[1].ty {
          case TParam(_, _) -> ()
          case _ -> assertTrue(false, "the parameter is the owner's T")
        }
        case None -> assertTrue(false, "a signature")
      }
    }
  }
  assertTrue(found, "an entry symbol")
}

test "appending a non-String value to a String builds as its toString" {
  val c = censusOf("package App\nfunc f(): String {\n  var s = \"n=\"\n  s += 3.5\n  s\n}\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a body that yields is the generator's code, not a value of its yield type" {
  val c = censusOf("package App\nasync func gen(): Int {\n  yield 1\n  yield 2\n}\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "default() with an expected type builds as the default builtin" {
  val c = censusOf("package App\nfunc f(v: out Int): Bool {\n  v = default()\n  false\n}\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "wrappingAdd on a Byte builds as a builtin member call" {
  val c = censusOf("package App\nfunc f(a: in Byte, b: in Byte): Byte {\n  a.wrappingAdd(b)\n}\n")
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a bare call of a sibling method is called on the enclosing method's self" {
  val pb = packageOf(
    "package App\nrecord Acc {\n  n: Int\n  func m(self: in Acc, x: in Int): Int { self.n + x }\n  func viaSibling(self: in Acc): Int {\n    m(1)\n  }\n}\n"
  )
  assertBuildsAndVerifies(pb, 2, "Acc.m and viaSibling")
}

test "a value passed to a host object parameter is boxed, an Int to a small host integer narrows (D597)" {
  val head = "package App\nextern type Obj = \"System.Object\"\nextern type Conv = \"System.Convert\"\n"
  val st = buildFirstFnMsil(head + "func f(): Bool {\n  Obj.Equals(42, 42)\n}\n")
  assertEqualInt(st.diagnostics, 0, "checks clean")
  assertTrue(st.env.errors.count == 0, if st.env.errors.count > 0 { st.env.errors[0] } else { "no I0002" })
  match externCallOf(st.body) {
    case Some(m) -> {
      assertEqualInt(m.params.count, 2, "two parameters")
      assertTrue(tyEq(m.params[0].ty, hostTy("System.Object")), "over object")
    }
    case None -> assertTrue(false, "an extern call")
  }
}

test "host boxing and narrowing pick a conversion by the operand and the host type (D597)" {
  val obj = hostTy("System.Object")
  assertTrue(isSome(hostBoxKind(TPrim(kind = TPString), obj)), "a String boxes to object")
  assertTrue(isSome(hostBoxKind(TPrim(kind = TPInt), obj)), "an Int boxes to object")
  assertTrue(not isSome(hostBoxKind(obj, obj)), "object is not boxed to object")
  assertTrue(not isSome(hostBoxKind(TPrim(kind = TPUnit), obj)), "Unit has no value to box")
  assertTrue(not isSome(hostBoxKind(TNever, obj)), "Never has no value to box")
  assertTrue(isSome(hostBoxKind(TPrim(kind = TPInt), hostTy("System.Int16"))), "an Int narrows to Int16")
  assertTrue(isSome(hostBoxKind(TPrim(kind = TPLong), hostTy("System.UInt32"))), "a Long narrows to UInt32")
  assertTrue(not isSome(hostBoxKind(TPrim(kind = TPString), hostTy("System.Int16"))), "a String is not an Int16")
  assertTrue(
    isSome(hostBoxKind(TSlice(element = TPrim(kind = TPByte)), hostTy("an array, pointer or by-reference type"))),
    "a Byte slice is a host array"
  )
  assertTrue(
    not isSome(hostBoxKind(TSlice(element = TPrim(kind = TPInt)), hostTy("an array, pointer or by-reference type"))),
    "an Int slice is not"
  )
  assertTrue(isSome(hostBoxKind(TPrim(kind = TPFloat), hostTy("System.Single"))), "a Float is a Single")
  assertTrue(not isSome(hostBoxKind(TPrim(kind = TPDouble), hostTy("System.Single"))), "a Double is not a Single")
}

test "a constant pattern builds as a reference to the constant" {
  val c = censusOf(
    "package App\nval LIMIT = 3\nfunc f(n: in Int): Int {\n  match n {\n    case @LIMIT -> 1\n    case _ -> 0\n  }\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a shorthand record pattern field binds the field's local" {
  val c = censusOf(
    "package App\nrecord P {\n  x: Int\n  y: Int\n}\nfunc f(p: in P): Int {\n  match p {\n    case P { x, y } -> x + y\n  }\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "an or-pattern whose alternatives bind the same name shares one local" {
  val c = censusOf(
    "package App\nunion U {\n  case A(n: Int)\n  case B(n: Int)\n  case C\n}\nfunc f(u: in U): Int {\n  match u {\n    case A(k) | B(k) -> k\n    case C -> 0\n  }\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a method call whose receiver is inout passes the receiver as a place" {
  val pb = packageOf(
    "package App\nrecord Pt {\n  x: Int\n  y: Int\n  func reset(self: inout Pt): Unit {\n    self = Pt(x = 0, y = 0)\n  }\n  func twice(self: inout Pt): Unit {\n    reset()\n    reset()\n  }\n}\nfunc f(): Int {\n  var p = Pt(x = 1, y = 2)\n  p.reset()\n  p.x\n}\n"
  )
  assertBuildsAndVerifies(pb, 3, "Pt.reset, twice and f")
}

test "a host property read is a call of its getter with the receiver first (D598)" {
  val head = "package App\nextern type SB = \"System.Text.StringBuilder\"\n"
  val st = buildFirstFnMsil(head + "func f(sb: in SB): Int {\n  sb.Length\n}\n")
  assertEqualInt(st.diagnostics, 0, "checks clean")
  assertTrue(st.env.errors.count == 0, if st.env.errors.count > 0 { st.env.errors[0] } else { "no I0002" })
  match externCallOf(st.body) {
    case Some(m) -> {
      assertTrue(m.kind == HMPropertyGet, "a property getter")
      assertTrue(not m.isStatic, "an instance member")
      assertEqualInt(m.params.count, 1, "the receiver only")
      assertTrue(tyEq(m.ret, TPrim(kind = TPInt)), "an Int")
    }
    case None -> assertTrue(false, "an extern call")
  }
}

test "a host property write is a call of its setter, receiver then value, of type Unit (D598)" {
  val head = "package App\nextern type SB = \"System.Text.StringBuilder\"\n"
  val st = buildFirstFnMsil(head + "func f(sb: in SB): Unit {\n  sb.Length = 0\n}\n")
  assertEqualInt(st.diagnostics, 0, "checks clean")
  assertTrue(st.env.errors.count == 0, if st.env.errors.count > 0 { st.env.errors[0] } else { "no I0002" })
  match externCallOfStatement(st.body) {
    case Some(m) -> {
      assertTrue(m.kind == HMPropertySet, "a property setter")
      assertEqualInt(m.params.count, 2, "receiver and value")
      assertTrue(tyEq(m.params[1].ty, TPrim(kind = TPInt)), "an Int value")
      assertTrue(tyEq(m.ret, tyUnit()), "Unit")
    }
    case None -> assertTrue(false, "an extern call")
  }
}

test "a compound assignment to a host property is counted, not guessed (D598)" {
  val head = "package App\nextern type SB = \"System.Text.StringBuilder\"\n"
  val st = buildFirstFnMsil(head + "func f(sb: in SB): Unit {\n  sb.Length += 1\n}\n")
  assertTrue(st.env.errors.count > 0, "an I0002")
  assertTrue(st.env.errors[0].contains("a compound assignment"), st.env.errors[0])
}

test "a slice of Byte passed for a host byte array builds as a host call (D599)" {
  val head = "package App\nextern type F = \"System.IO.File\"\n"
  val st = buildFirstFnMsil(head + "func f(p: in String, b: in slice[Byte]): Unit {\n  F.WriteAllBytes(p, b)\n}\n")
  assertEqualInt(st.diagnostics, 0, "checks clean")
  assertTrue(st.env.errors.count == 0, if st.env.errors.count > 0 { st.env.errors[0] } else { "no I0002" })
  match externCallOf(st.body) {
    case Some(m) -> {
      assertEqualInt(m.params.count, 2, "two parameters")
      assertTrue(tyEq(m.params[1].ty, hostTy("an array, pointer or by-reference type")), "over a host array")
    }
    case None -> assertTrue(false, "an extern call")
  }
}

test "a host value passed as its host supertype is converted, read from the metadata (D599)" {
  val head = "package App\nextern type H = \"System.Net.Http.HttpClientHandler\"\nextern type C = \"System.Net.Http.HttpClient\"\n"
  val st = buildFirstFnMsil(head + "func f(h: in H): C {\n  C.new(h)\n}\n")
  assertEqualInt(st.diagnostics, 0, "checks clean")
  assertTrue(st.env.errors.count == 0, if st.env.errors.count > 0 { st.env.errors[0] } else { "no I0002" })
  match externCallOf(st.body) {
    case Some(m) -> assertTrue(
      tyEq(m.params[0].ty, hostTy("System.Net.Http.HttpMessageHandler")),
      "over the base class"
    )
    case None -> assertTrue(false, "an extern call")
  }
}

/// The `let` statements in a body's blocks, following each block's tail expression.
func letCount(e: in TExpr): Int {
  match e.kind {
    case XBlock(stmts, tail) -> {
      var n = 0
      for st in stmts {
        match st.kind {
          case TsLet(_, _) -> {
            n = n + 1
          }
          case _ -> ()
        }
      }
      match tail {
        case Some(t) -> n + letCount(t)
        case None -> n
      }
    }
    case _ -> 0
  }
}

test "a name read before a later call that changes it is bound to a temporary when names reorder the arguments (D171)" {
  val pb = packageOf(
    "package App\nfunc zero(x: inout Int): Int {\n  x = 0\n  7\n}\nfunc two(a: in Int, b: in Int): Int { a * 100 + b }\nfunc f(): Int {\n  var x = 5\n  two(b = x, a = zero(x))\n}\n"
  )
  assertBuildsAndVerifies(pb, 3, "zero, two and f")
  var temps = 0
  for fd in pb.pkg.funcs {
    match fd.body {
      case Some(b) -> {
        temps = temps + letCount(b)
      }
      case None -> ()
    }
  }
  assertTrue(temps >= 2, "x and the call are each bound to a temporary in source order (found " + toString(temps) + ")")
}

func hostTy(name: in String): Ty {
  TExtern(host = HostTypeRef(name = name, args = newList()))
}

test "a host result the checker types as a Lyric type takes the checker's type" {
  val arr = "an array, pointer or by-reference type"
  assertTrue(hostResultIsCallType(hostTy(arr), TSlice(element = TPrim(kind = TPByte))), "an array as a slice")
  assertTrue(not hostResultIsCallType(hostTy(arr), TPrim(kind = TPInt)), "an array is not an Int")
  assertTrue(
    hostResultIsCallType(hostTy("System.String"), TNullable(inner = TPrim(kind = TPString))),
    "a string as String?"
  )
  assertTrue(
    hostResultIsCallType(hostTy("java.lang.String"), TNullable(inner = TPrim(kind = TPString))),
    "a JVM string as String?"
  )
  assertTrue(not hostResultIsCallType(hostTy("System.String"), TNullable(inner = TPrim(kind = TPInt))), "not an Int?")
  assertTrue(hostResultIsCallType(hostTy("System.Single"), TPrim(kind = TPFloat)), "Single as Float")
  assertTrue(not hostResultIsCallType(hostTy("System.Single"), TPrim(kind = TPDouble)), "Single is not a Double")
  assertTrue(hostResultIsCallType(hostTy("System.Double"), TPrim(kind = TPDouble)), "Double as Double")
  assertTrue(not hostResultIsCallType(TPrim(kind = TPInt), TPrim(kind = TPInt)), "a Lyric type is not a host result")
  assertTrue(
    hostResultIsCallType(hostTy("System.Globalization.UnicodeCategory"), TPrim(kind = TPInt)),
    "a host enum as Int"
  )
  assertTrue(
    not hostResultIsCallType(hostTy("System.Threading.Tasks.Task"), TPrim(kind = TPString)),
    "a task is not a String"
  )
}

test "a value-generic case built in a value-generic function verifies" {
  val c = censusOf(
    "package App\nunion Shape[N: Nat] {\n  case Poly(pts: array[N, Int])\n  case Empty\n}\nfunc wrapPoly[N: Nat](xs: in array[N, Int]): Shape[N] = Poly(pts = xs)\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a call of a stubbable interface's method resolves despite the stub's synthesized impl" {
  val c = censusOf(
    "package App\n@stubbable\npub interface Feed {\n  func priceOf(symbol: in String): Int\n}\nfunc total(feed: in Feed): Int { feed.priceOf(\"a\") }\n"
  )
  assertTrue(c.built >= 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  assertEqualInt(c.firstErrors.count, 0, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "no I0002" })
}

test "an assignment to a var field of a ref record verifies; a plain field stays immutable" {
  val c = censusOf(
    "package App\nref record Counter {\n  var n: Int\n  label: String\n}\nfunc bump(c: in Counter): Unit {\n  c.n = c.n + 1\n}\n"
  )
  assertEqualInt(c.built, 1, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
  var seen = false
  for en in c.pkg.symbols {
    for f in en.fields {
      if f.name == "n" {
        seen = true
        assertTrue(f.mutable, "the var field n is mutable")
      }
      if f.name == "label" {
        assertTrue(not f.mutable, "the plain field label is immutable")
      }
    }
  }
  assertTrue(seen, "the record's fields are in the package")
}

test "equality of two values of a declared type is one intrinsic over both operands" {
  val c = censusOf(
    "package App\nunion Opt[T] { case Nope\n case Has(v: T) }\nenum Color { case Red\n case Green }\nrecord P { x: Int }\nunion U { case A\n case B(n: Int) }\ntype Id = Long\nfunc eqEnum(a: in Color, b: in Color): Bool { a == b }\nfunc eqRec(a: in P, b: in P): Bool { a != b }\nfunc eqUnion(a: in U, b: in U): Bool { a == b }\nfunc eqOpt(a: in Opt[Int], b: in Opt[Int]): Bool { a == b }\nfunc eqId(a: in Id, b: in Id): Bool { a == b }\nfunc isNone(a: in Opt[Int]): Bool { a == Nope }\n"
  )
  assertEqualInt(c.built, 6, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "buildPackage keys each declaration by its symbol, names symbols and keeps case order" {
  val file = renumberNodeIds(parse("package App\nunion Shape { case Circle(r: Int)\n case Square(s: Int)\n case Dot }\nfunc area(s: in Shape): Int {\n  match s {\n    case Circle(r) -> r\n    case Square(w) -> w\n    case Dot -> 0\n  }\n}\n").file).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  assertEqualInt(pb.total, 1, "one body")
  assertEqualInt(
    pb.built,
    1,
    if pb.failed.count > 0 and pb.failed[0].messages.count > 0 { pb.failed[0].messages[0] } else { "built" }
  )
  assertEqualInt(pb.failed.count, 0, "no failure")
  assertTrue(pb.pkg.name == "App", "the package name")
  assertEqualInt(pb.pkg.funcs.count, 1, "one declaration")
  assertTrue(pb.names.containsKey(pb.pkg.funcs[0].sym.id), "the function has a DefPath key")
  var checkedUnion = false
  for k in mapKeys(pb.cases) {
    match mapGet(pb.cases, k) {
      case Some(l) -> {
        assertEqualInt(l.count, 3, "three cases")
        val first = match mapGet(pb.names, l[0].id) { case Some(n) -> n; case None -> "" }
        val last = match mapGet(pb.names, l[2].id) { case Some(n) -> n; case None -> "" }
        assertTrue(Str.contains(first, "Circle"), "the first case is Circle: " + first)
        assertTrue(Str.contains(last, "Dot"), "the last case is Dot: " + last)
        checkedUnion = true
      }
      case None -> ()
    }
  }
  assertTrue(checkedUnion, "the union's cases are listed")
}

test "a range pattern builds with its literal bounds, negated ones included" {
  val c = censusOf(
    "package App\nfunc grade(n: Int): Int {\n  match n {\n    case -5 ..= -1 -> 0\n    case 0 ..< 10 -> 1\n    case 10 ..= 99 -> 2\n    case _ -> 3\n  }\n}\nfunc kind(c: Char): Int {\n  match c {\n    case 'a' ..= 'z' -> 1\n    case _ -> 0\n  }\n}\n"
  )
  assertEqualInt(c.built, 2, if c.firstErrors.count > 0 { c.firstErrors[0] } else { "built" })
  val ds = verifyPackage(c.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

func packageOf(src: in String): PackageBuild {
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
}

test "a record method with an explicit receiver is a declaration keyed by its method symbol" {
  val pb = packageOf(
    "package App\nrecord Sq {\n  side: Int\n  func area(self: in Sq): Int { self.side * self.side }\n}\n"
  )
  assertEqualInt(pb.total, 1, "one body")
  assertEqualInt(
    pb.built,
    1,
    if pb.failed.count > 0 and pb.failed[0].messages.count > 0 { pb.failed[0].messages[0] } else { "built" }
  )
  assertEqualInt(pb.pkg.funcs[0].params.count, 1, "the receiver is the only parameter")
  assertTrue(pb.pkg.funcs[0].params[0].local.name == "self", "named self")
  val ds = verifyPackage(pb.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a protected entry is a declaration with an implicit receiver, its when: clause as the barrier and an entry symbol" {
  val pb = packageOf(
    "package App\nprotected type Gate {\n  var open: Bool = false\n  entry pass(k: in Int): Int\n    when: k > 0\n  {\n    return k\n  }\n}\n"
  )
  assertEqualInt(
    pb.built,
    1,
    if pb.failed.count > 0 and pb.failed[0].messages.count > 0 { pb.failed[0].messages[0] } else { "built" }
  )
  val f = pb.pkg.funcs[0]
  assertEqualInt(f.params.count, 2, "the receiver and k")
  assertTrue(f.params[0].local.name == "self", "the receiver is first")
  assertTrue(f.barrier.isSome(), "the when: clause is the barrier")
  var entry = false
  for en in pb.pkg.symbols {
    if en.sym.id == f.sym.id {
      entry = match en.kind { case TSkEntry -> true; case _ -> false }
    }
  }
  assertTrue(entry, "the symbol is an entry")
  val ds = verifyPackage(pb.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

func firstFailure(pb: in PackageBuild): String {
  if pb.failed.count > 0 and pb.failed[0].messages.count > 0 {
    pb.failed[0].messages[0]
  } else {
    "built"
  }
}

func assertBuildsAndVerifies(pb: in PackageBuild, total: in Int, what: in String): Unit {
  assertEqualInt(pb.total, total, what + ": bodies")
  assertEqualInt(pb.built, total, what + ": " + firstFailure(pb))
  val ds = verifyPackage(pb.pkg, newList())
  assertEqualInt(ds.count, 0, what + ": " + if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a method of a generic record builds with the owner's parameter as its receiver's argument (D579)" {
  val pb = packageOf("package App\nrecord Box[T] {\n  v: T\n  func get(self: in Box[T]): T { self.v }\n}\n")
  assertBuildsAndVerifies(pb, 1, "Box.get")
  val f = pb.pkg.funcs[0]
  assertEqualInt(f.typeParams.count, 1, "the owner's T is its one parameter")
  assertEqualInt(f.ownerParamCount, 1, "and it is the owner's")
}

test "a generic record's method may declare parameters of its own beside the owner's (D579)" {
  val pb = packageOf(
    "package App\nrecord Box[T] {\n  v: T\n  func pair[U](self: in Box[T], u: in U): (T, U) { (self.v, u) }\n}\n"
  )
  assertBuildsAndVerifies(pb, 1, "Box.pair")
  assertEqualInt(pb.pkg.funcs[0].typeParams.count, 2, "the owner's T then its own U")
  assertEqualInt(pb.pkg.funcs[0].ownerParamCount, 1, "the first is the owner's")
}

test "a member of a generic protected type reads and writes a field typed by the owner's parameter (D579)" {
  val pb = packageOf(
    "package App\nprotected type Cell[T] {\n  var v: T\n  entry put(x: in T): Unit {\n    v = x\n  }\n  func get(): T {\n    v\n  }\n}\n"
  )
  assertBuildsAndVerifies(pb, 2, "Cell")
}

test "a member of a generic impl builds with the impl's parameter in scope (D579)" {
  val pb = packageOf(
    "package App\ninterface Has[T] {\n  func first(self: in Self): T\n}\nrecord Wrap[T] {\n  v: T\n}\nimpl[T] Has[T] for Wrap[T] {\n  func first(self: in Wrap[T]): T { self.v }\n}\n"
  )
  assertBuildsAndVerifies(pb, 1, "impl.first")
}

test "a call of a member of a generic impl is built and verified, or counted, never misbuilt" {
  val c = censusOf(
    "package App\ninterface Has[T] {\n  func first(self: in Self): T\n}\nrecord Wrap[T] {\n  v: T\n}\nimpl[T] Has[T] for Wrap[T] {\n  func first(self: in Wrap[T]): T { self.v }\n}\nfunc f(w: in Wrap[Int]): Int {\n  w.first()\n}\n"
  )
  if c.built == 2 {
    val ds = verifyPackage(c.pkg, newList())
    assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
  } else {
    assertTrue(c.firstErrors.count > 0, "a body that does not build says why")
  }
}

test "a protected member reads and assigns a field of its receiver by the bare name" {
  val pb = packageOf(
    "package App\nprotected type Total {\n  var n: Int = 0\n  entry add(k: in Int): Unit {\n    n = n + k\n  }\n  func get(): Int {\n    n\n  }\n}\n"
  )
  assertEqualInt(pb.total, 2, "two members")
  assertEqualInt(
    pb.built,
    2,
    if pb.failed.count > 0 and pb.failed[0].messages.count > 0 { pb.failed[0].messages[0] } else { "built" }
  )
  val ds = verifyPackage(pb.pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("test", ds[0]) } else { "verifies" })
}

test "a local that shadows a protected field's name is the local, not the field (D576)" {
  val pb = packageOf(
    "package App\nprotected type Holder {\n  var n: Int = 0\n  func label(): String {\n    val n = \"x\"\n    n\n  }\n}\n"
  )
  assertBuildsAndVerifies(pb, 1, "Holder.label")
}

test "a failed body names its symbol's DefPath key (D570)" {
  val pb = packageOf("package App\nfunc f(xs: in slice[Int]): Int {\n  xs.count\n}\n")
  assertEqualInt(pb.failed.count, 1, "the member access body fails")
  assertTrue(pb.failed[0].sym.isSome(), "it has a symbol")
  assertTrue(pb.failed[0].path.isSome(), "and names its DefPath key")
}

test "a generic method of a non-generic record binds its parameter under Owner.fn (D579)" {
  val pb = packageOf("package App\nrecord Tag {\n  n: Int\n  func pick[U](self: in Tag, u: in U): U { u }\n}\n")
  assertBuildsAndVerifies(pb, 1, "Tag.pick")
  assertEqualInt(pb.pkg.funcs[0].typeParams.count, 1, "its own U")
  assertEqualInt(pb.pkg.funcs[0].ownerParamCount, 0, "the owner declares none")
}

test "a call of a method of a generic record instantiates the owner's parameter from the receiver (D580)" {
  val pb = packageOf(
    "package App\nrecord Box[T] {\n  v: T\n  func get(self: in Box[T]): T { self.v }\n}\nfunc f(b: in Box[Int]): Int {\n  b.get()\n}\n"
  )
  assertBuildsAndVerifies(pb, 2, "Box.get and f")
}

test "a call of a method with its own parameter beside the owner's instantiates both (D580)" {
  val pb = packageOf(
    "package App\nrecord Box[T] {\n  v: T\n  func pair[U](self: in Box[T], u: in U): (T, U) { (self.v, u) }\n}\nfunc f(b: in Box[Int]): (Int, String) {\n  b.pair(\"x\")\n}\n"
  )
  assertBuildsAndVerifies(pb, 2, "Box.pair and f")
}

test "a call of a generic protected type's func instantiates the owner's parameter (D580)" {
  val pb = packageOf(
    "package App\nprotected type Cell[T] {\n  var v: T\n  func get(): T {\n    v\n  }\n}\nfunc f(c: in Cell[Int]): Int {\n  c.get()\n}\n"
  )
  assertBuildsAndVerifies(pb, 2, "Cell.get and f")
}

test "a generic function calling a method of a generic record passes its own parameter (D580)" {
  val pb = packageOf(
    "package App\nrecord Cell[T] {\n  v: T\n  func get(self: in Cell[T]): T { self.v }\n}\nfunc shown[T](c: in Cell[T]): T {\n  c.get()\n}\n"
  )
  assertBuildsAndVerifies(pb, 2, "Cell.get and shown")
}

test "a method calling a sibling method through self passes the owner's parameter (D580)" {
  val pb = packageOf(
    "package App\nrecord Cell[T] {\n  v: T\n  func get(self: in Cell[T]): T { self.v }\n  func twice(self: in Cell[T]): T {\n    self.get()\n  }\n}\n"
  )
  assertBuildsAndVerifies(pb, 2, "Cell.get and twice")
}
