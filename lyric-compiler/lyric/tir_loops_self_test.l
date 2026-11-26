//! tir_loops_self_test.l - Lyric.Tir.Loops (docs/70 §7.2, D510): loop `invariant:` lowering on TIR.
//!
//! Each case builds a small package, lowers its loops, and checks that no `TsInvariant` is left, that the result
//! verifies, and that the assertions stand where the AST pass puts them: at the head of every iteration, and after a
//! loop that ends normally (not after a `break`, and not after a `while true`).
@test_module
package Lyric.TirLoopsSelfTest

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
import Lyric.Tir.Loops

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
  val done = lowerLoopsBundle(bundle)
  Lowered(pb = done[0], before = pb, diagnostics = cr.diagnostics.count)
}

record Counts {
  invariants: Int
  whiles: Int
  loops: Int
  fors: Int
  vars: Int
  asserts: Int
}

func count(pb: in PackageBuild): Counts {
  val acc: List[Int] = newList()
  var i = 0
  while i < 6 {
    acc.add(0)
    i = i + 1
  }
  val w = Walker(
    pre = { e: TExpr -> None },
    post = { e: TExpr -> tallyExpr(acc, e) },
    preStmt = { st: TStmt -> tallyStmt(acc, st) }
  )
  for f in pb.pkg.funcs {
    match f.body {
      case Some(b) -> {
        walkExpr(w, b)
      }
      case None -> ()
    }
  }
  Counts(invariants = acc[0], whiles = acc[1], loops = acc[2], fors = acc[3], vars = acc[4], asserts = acc[5])
}

func tallyStmt(acc: in List[Int], st: in TStmt): Option[List[TStmt]] {
  match st.kind {
    case TsInvariant(_, _) -> {
      acc[0] = acc[0] + 1
    }
    case TsWhile(_, _, _) -> {
      acc[1] = acc[1] + 1
    }
    case TsLoop(_, _) -> {
      acc[2] = acc[2] + 1
    }
    case TsFor(_, _, _, _) -> {
      acc[3] = acc[3] + 1
    }
    case TsVar(_, _) -> {
      acc[4] = acc[4] + 1
    }
    case _ -> ()
  }
  None
}

func tallyExpr(acc: in List[Int], e: in TExpr): TExpr {
  match e.kind {
    case XCall(Intrinsic(IoBuiltin(name)), args) -> if name == "assert" and args.count == 2 {
      match args[1] {
        case TArgIn(m) -> match m.kind {
          case XLit(TLString(t)) -> if t.startsWith("LoopInvariantViolated: invariant ") {
            acc[5] = acc[5] + 1
          }
          case _ -> ()
        }
        case _ -> ()
      }
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
  assertEqualInt(count(l.pb).invariants, 0, what + ": no invariant statement is left")
}

test "a while loop's invariant is asserted each iteration and when the condition goes false" {
  val l = lowerOf(
    "package App\nfunc f(n: Int): Int {\n  var i = 0\n  while i < n\n    invariant: i <= n\n  {\n    i = i + 1\n  }\n  i\n}\n"
  )
  assertEqualInt(count(l.before).invariants, 1, "one invariant before")
  assertLowered(l, "while")
  val c = count(l.pb)
  assertEqualInt(c.asserts, 2, "the iteration check and the exit check")
  assertEqualInt(c.whiles, 0, "the while became a loop")
  assertEqualInt(c.loops, 1, "one loop")
}

test "while true has no exit check" {
  val l = lowerOf(
    "package App\nfunc f(n: Int): Int {\n  var i = 0\n  while true\n    invariant: i >= 0\n  {\n    i = i + 1\n    if i > n { return i }\n  }\n  i\n}\n"
  )
  assertLowered(l, "while true")
  val c = count(l.pb)
  assertEqualInt(c.asserts, 1, "only the iteration check")
  assertEqualInt(c.whiles, 1, "the loop keeps its form")
}

test "a for loop's invariant is checked after the loop through a flag a break sets" {
  val l = lowerOf(
    "package App\nfunc f(n: Int): Int {\n  var s = 0\n  for i in 0 ..< n\n    invariant: s >= 0\n  {\n    if i > 3 { break }\n    s = s + i\n  }\n  s\n}\n"
  )
  assertLowered(l, "for with break")
  val c = count(l.pb)
  assertEqualInt(c.asserts, 2, "the iteration check and the guarded exit check")
  assertEqualInt(c.vars, 2, "the accumulator and the break flag")
  assertEqualInt(c.fors, 1, "the for keeps its form")
}

test "a for loop with no break needs no flag, and a clause naming the loop variable is checked per iteration only" {
  val l = lowerOf(
    "package App\nfunc f(n: Int): Int {\n  var s = 0\n  for i in 0 ..< n\n    invariant: s >= 0\n    invariant: i <= n\n  {\n    s = s + i\n  }\n  s\n}\n"
  )
  assertLowered(l, "for")
  val c = count(l.pb)
  assertEqualInt(c.asserts, 3, "two iteration checks and the one exit check on the clause that does not read i")
  assertEqualInt(c.vars, 1, "only the accumulator")
}

test "a break of an inner loop leaves the outer for loop's flag alone" {
  val l = lowerOf(
    "package App\nfunc f(n: Int): Int {\n  var s = 0\n  for i in 0 ..< n\n    invariant: s >= 0\n  {\n    var j = 0\n    while j < 3\n      invariant: j <= 3\n    {\n      if j == 2 { break }\n      j = j + 1\n    }\n    s = s + j\n  }\n  s\n}\n"
  )
  assertLowered(l, "nested")
  val c = count(l.pb)
  assertEqualInt(c.asserts, 4, "the for's iteration and exit checks and the while's")
  assertEqualInt(c.vars, 2, "the accumulator and the inner counter: no flag, the break is the inner loop's")
}

test "a labelled break from an inner loop sets the outer for loop's flag" {
  val l = lowerOf(
    "package App\nfunc f(n: Int): Int {\n  var s = 0\n  outer: for i in 0 ..< n\n    invariant: s >= 0\n  {\n    for k in 0 ..< 3 {\n      if k == 1 { break outer }\n      s = s + k\n    }\n  }\n  s\n}\n"
  )
  assertLowered(l, "labelled break")
  val c = count(l.pb)
  assertEqualInt(c.asserts, 2, "the iteration check and the guarded exit check")
  assertEqualInt(c.vars, 2, "the accumulator and the outer loop's break flag")
}
