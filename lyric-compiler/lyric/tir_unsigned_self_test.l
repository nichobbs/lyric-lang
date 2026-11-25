//! tir_unsigned_self_test.l - Lyric.Tir.Unsigned (docs/70 §7.2, D508): the checked and corrected `ULong`
//! conversions of D278 on TIR, over a same-width `CvReinterpret`.
//!
//! Each case builds a small package, lowers it, and checks that no `ULong.to*` built-in is left, that the result
//! verifies, and that the blocks read the bits through `CvReinterpret` and carry D278's panic message.
@test_module
package Lyric.TirUnsignedSelfTest

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
import Lyric.Tir.Unsigned

record Lowered {
  pb: PackageBuild
  before: PackageBuild
  diagnostics: Int
}

func lowerOf(src: in String): Lowered {
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  val done = lowerUnsignedBundle(bundle)
  Lowered(pb = done[0], before = pb, diagnostics = cr.diagnostics.count)
}

record Counts {
  conversions: Int
  reinterprets: Int
  panics: Int
}

func count(pb: in PackageBuild): Counts {
  val acc: List[Int] = newList()
  acc.add(0)
  acc.add(0)
  acc.add(0)
  val w = Walker(pre = { e: TExpr -> None }, post = { e: TExpr -> tally(acc, e) })
  for f in pb.pkg.funcs {
    match f.body {
      case Some(b) -> {
        walkExpr(w, b)
      }
      case None -> ()
    }
  }
  Counts(conversions = acc[0], reinterprets = acc[1], panics = acc[2])
}

func tally(acc: in List[Int], e: in TExpr): TExpr {
  match e.kind {
    case XCall(Intrinsic(IoBuiltin(name)), _) -> {
      if name == "ULong.toLong" or name == "ULong.toDouble" or name == "ULong.toFloat" {
        acc[0] = acc[0] + 1
      }
      if name == "panic" {
        acc[2] = acc[2] + 1
      }
    }
    case XConvert(CvReinterpret, _) -> {
      acc[1] = acc[1] + 1
    }
    case _ -> ()
  }
  e
}

func assertLowered(l: in Lowered, what: in String): Unit {
  assertEqualInt(l.diagnostics, 0, what + ": the source checks")
  assertEqualInt(l.before.built, l.before.total, what + ": every body builds")
  val ds = verifyPackage(l.pb.pkg, newList())
  assertEqualInt(
    ds.count,
    0,
    what + ": verifies" + (if ds.count > 0 { " " + renderVerifyDiag("t", ds[0]) } else { "" })
  )
}

test "ULong.toLong becomes a reinterpret and a panic on the top bit" {
  val l = lowerOf("package App\nfunc f(w: in ULong): Long { w.toLong() }\n")
  assertLowered(l, "toLong")
  assertEqualInt(count(l.before).conversions, 1, "the built-in is there before")
  val c = count(l.pb)
  assertEqualInt(c.conversions, 0, "and gone after")
  assertEqualInt(c.reinterprets, 1, "one reinterpret")
  assertEqualInt(c.panics, 1, "one panic")
}

test "ULong.toDouble and toFloat become the halved correction over a reinterpret" {
  val l = lowerOf(
    "package App\nfunc d(w: in ULong): Double { w.toDouble() }\nfunc g(w: in ULong): Float { w.toFloat() }\n"
  )
  assertLowered(l, "toDouble and toFloat")
  assertEqualInt(count(l.before).conversions, 2, "both built-ins are there before")
  val c = count(l.pb)
  assertEqualInt(c.conversions, 0, "and gone after")
  assertEqualInt(c.reinterprets, 2, "one reinterpret each")
  assertEqualInt(c.panics, 0, "no panic")
}

test "a conversion whose receiver is a call, nested in an expression, is lowered once" {
  val l = lowerOf(
    "package App\nfunc big(): ULong { 18446744073709551615u64 }\nfunc f(): Double { big().toDouble() + 1.0 }\n"
  )
  assertLowered(l, "nested")
  assertEqualInt(count(l.pb).conversions, 0, "lowered")
  assertEqualInt(count(l.pb).reinterprets, 1, "once")
}

test "a function with no ULong conversion is returned unchanged" {
  val l = lowerOf("package App\nfunc f(x: in Int): Long { x.toLong() }\n")
  assertLowered(l, "plain")
  assertEqualInt(count(l.pb).reinterprets, 0, "nothing to lower")
}

test "CvReinterpret verifies between a signed and an unsigned integer of one width only" {
  val l = lowerOf("package App\nfunc f(w: in ULong): Long { w.toLong() }\n")
  val f = l.pb.pkg.funcs[0]
  val body = match f.body { case Some(b) -> b; case None -> panic("body") }
  // Re-type the node a reinterpret produces to an unrelated type: the verifier rejects it.
  val w = Walker(pre = { e: TExpr -> None }, post = { e: TExpr -> retype(e) })
  val bad = walkExpr(w, body)
  val broken = TPackage(name = l.pb.pkg.name, symbols = l.pb.pkg.symbols, funcs = [f.copy(body = Some(value = bad))])
  val ds = verifyPackage(broken, newList())
  assertTrue(ds.count > 0, "a reinterpret to String is a convert-type error")
}

func retype(e: in TExpr): TExpr {
  match e.kind {
    case XConvert(CvReinterpret, inner) -> TExpr(id = e.id, ty = tyString(), span = e.span, kind = e.kind)
    case _ -> e
  }
}
