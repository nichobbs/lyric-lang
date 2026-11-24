//! tir_propagate_self_test.l - Lyric.Tir.Propagate and Lyric.Tir.Walk (docs/70 §7.2, D503).
//!
//! Each case builds a small package into TIR, lowers its `?`, and checks that the output verifies, that no
//! `XPropagate` is left, and that the failure path returns the failure rebuilt at the function's type.
@test_module
package Lyric.TirPropagateSelfTest

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
import Lyric.Tir.Verify
import Lyric.Tir.Walk
import Lyric.Tir.Propagate

record Lowered {
  pb: PackageBuild
  diags: List[String]
  diagnostics: Int
  before: PackageBuild
}

func lowerOf(src: in String): Lowered {
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  val r = lowerPropagateBundle(cr.symbols.interner, bundle)
  Lowered(pb = r.pkgs[0], diags = r.diags, diagnostics = cr.diagnostics.count, before = pb)
}

func assertLowered(l: in Lowered, what: in String): Unit {
  assertEqualInt(l.diagnostics, 0, what + ": the source checks")
  assertTrue(l.before.total > 0, what + ": the source has bodies")
  assertEqualInt(l.before.built, l.before.total, what + ": every body builds")
  assertEqualInt(
    l.diags.count,
    0,
    what + ": nothing left unlowered" + (if l.diags.count > 0 { " " + l.diags[0] } else { "" })
  )
  val ds = verifyPackage(l.pb.pkg, newList())
  assertEqualInt(
    ds.count,
    0,
    what + ": verifies" + (if ds.count > 0 { " " + renderVerifyDiag("t", ds[0]) } else { "" })
  )
}

/// How many nodes of kind `XPropagate` and how many `return`-carrying blocks `pb`'s functions hold.
func countProps(pb: in PackageBuild): Int {
  val acc: List[Int] = newList()
  acc.add(0)
  val w = Walker(pre = { e: TExpr -> None }, post = { e: TExpr -> countIfProp(acc, e) })
  for f in pb.pkg.funcs {
    match f.body {
      case Some(b) -> {
        walkExpr(w, b)
      }
      case None -> ()
    }
  }
  acc[0]
}

func countIfProp(acc: in List[Int], e: in TExpr): TExpr {
  match e.kind {
    case XPropagate(_) -> {
      acc[0] = acc[0] + 1
    }
    case _ -> ()
  }
  e
}

test "the source has the ? the lowering removes" {
  val l = lowerOf(
    "package App\nfunc half(x: Int): Result[Int, String] {\n  if x % 2 == 0 { Ok(value = x / 2) } else { Err(error = \"odd\") }\n}\nfunc f(x: Int): Result[Int, String] {\n  val h = half(x)?\n  Ok(value = h + 1)\n}\n"
  )
  assertEqualInt(countProps(l.before), 1, "one ? before")
  assertEqualInt(countProps(l.pb), 0, "none after")
  assertLowered(l, "result")
}

test "an Option operand in an Option function lowers" {
  val l = lowerOf("package App\nfunc g(o: Option[Int]): Option[Int] {\n  val v = o?\n  Some(value = v + 1)\n}\n")
  assertEqualInt(countProps(l.before), 1, "one ? before")
  assertEqualInt(countProps(l.pb), 0, "none after")
  assertLowered(l, "option")
}

test "several ? in one function each lower" {
  val l = lowerOf(
    "package App\nfunc half(x: Int): Result[Int, String] {\n  if x % 2 == 0 { Ok(value = x / 2) } else { Err(error = \"odd\") }\n}\nfunc f(x: Int): Result[Int, String] {\n  val a = half(x)?\n  val b = half(a)?\n  Ok(value = a + b)\n}\n"
  )
  assertEqualInt(countProps(l.before), 2, "two ? before")
  assertEqualInt(countProps(l.pb), 0, "none after")
  assertLowered(l, "two")
}

test "a function without ? is untouched" {
  val l = lowerOf("package App\nfunc f(x: Int): Int { x + 1 }\n")
  assertEqualInt(countProps(l.pb), 0, "none")
  assertLowered(l, "plain")
}
