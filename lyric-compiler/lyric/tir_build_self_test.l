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

test "named arguments that reorder effects are refused, plain ones are not" {
  val bad = buildFirstFn(
    "package App\nfunc m(): Int { k(b = f(), a = g()) }\nfunc k(a: Int, b: Int): Int { a }\nfunc f(): Int { 1 }\nfunc g(): Int { 2 }\n"
  )
  assertEqualInt(bad.diagnostics, 0, "checks clean")
  assertTrue(not bad.body.isSome(), "no body")
  assertEqualInt(mapGetOr0(bad.env.uncovered, "a call whose named arguments reorder effects"), 1, "counted")
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

test "a refined argument to a built-in the builder cannot check is counted, not passed through" {
  val r = buildFirstFn("package App\nfunc m(s: in String, i: in Int range 0 ..= 9): String { s.substring(i) }\n")
  assertEqualInt(r.diagnostics, 0, "checks clean")
  assertTrue(not r.body.isSome(), "no body")
  assertEqualInt(mapGetOr0(r.env.uncovered, "a built-in call with an argument the builder cannot check"), 1, "counted")
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

test "an or-pattern is counted, not guessed" {
  val r = buildFirstFn(
    "package App\nfunc f(n: Int): Int {\n  match n {\n    case 1 | 2 -> 1\n    case _ -> 0\n  }\n}\n"
  )
  assertTrue(not r.body.isSome(), "no body")
  assertEqualInt(mapGetOr0(r.env.uncovered, "an or-pattern"), 1, "counted")
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

test "a method with a mutating receiver is counted, not built as an in argument" {
  val r = buildFirstFn(
    "package App\nrecord C {\n  var n: Int\n  func bump(self: inout C): Unit { self.n = self.n + 1 }\n}\nfunc f(c: inout C): Unit {\n  c.bump()\n}\n"
  )
  assertTrue(not r.body.isSome(), "no body")
  assertEqualInt(mapGetOr0(r.env.uncovered, "a method call with a mutating receiver"), 1, "counted")
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
  assertTrue(at.startsWith("3:"), "line 3 where the member access is")
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

test "a default that is not a literal or a name is counted, not guessed" {
  val c = censusOf("package App\nfunc g(a: Int, b: Int = 1 + 2): Int { a + b }\nfunc f(): Int { g(1) }\n")
  assertEqualInt(c.built, 1, "only g builds")
  assertTrue(c.firstErrors.count > 0, "f reports an I0002")
}
