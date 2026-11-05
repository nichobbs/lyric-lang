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
      case TTuple(xs) -> {
        assertEqualInt(xs.count, 2, "two elements")
        assertTrue(tyEq(xs[0], TPrim(kind = TPInt)), "first is Int")
      }
      case _ -> fail("expected a tuple")
    }
    case Err(e) -> fail(e)
  }
  match tyOfType(ctx, TyPrim(pt = PtNever)) {
    case Ok(t) -> assertTrue(tyEq(t, TNever), "Never")
    case Err(e) -> fail(e)
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
    case Err(e) -> fail(e)
  }
  assertTrue(tyOfType(ctx, TyParam(name = "V", owner = "id")).isErr(), "not declared by its binder")
}
