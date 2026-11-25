//! tir_await_hoist_self_test.l - Lyric.Tir.AwaitHoist (docs/70 §7.2, D504): await hoisting on TIR.
//!
//! Each case builds a small async package into TIR, hoists its awaits, and checks that the output verifies and
//! that no `await` is left at a non-empty stack: every operand ahead of an awaiting operand is a local read.
@test_module
package Lyric.TirAwaitHoistSelfTest

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
import Lyric.Tir.AwaitHoist

record Hoisted {
  pb: PackageBuild
  before: PackageBuild
  diagnostics: Int
}

func hoistOf(src: in String): Hoisted {
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  Hoisted(pb = hoistAwaitsBundle(bundle)[0], before = pb, diagnostics = cr.diagnostics.count)
}

func assertHoisted(h: in Hoisted, what: in String): Unit {
  assertEqualInt(h.diagnostics, 0, what + ": the source checks")
  assertTrue(h.before.total > 0, what + ": the source has bodies")
  assertEqualInt(h.before.built, h.before.total, what + ": every body builds")
  val ds = verifyPackage(h.pb.pkg, newList())
  assertEqualInt(
    ds.count,
    0,
    what + ": verifies" + (if ds.count > 0 { " " + renderVerifyDiag("t", ds[0]) } else { "" })
  )
}

/// How many calls have an `await` among their arguments ahead of which another argument sits: the hazard.
func stackedAwaits(pb: in PackageBuild): Int {
  val acc: List[Int] = newList()
  acc.add(0)
  val w = Walker(pre = { e: TExpr -> None }, post = { e: TExpr -> countStacked(acc, e) })
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

func isAwait(e: in TExpr): Bool {
  match e.kind {
    case XAwait(_) -> true
    case _ -> false
  }
}

func countStacked(acc: in List[Int], e: in TExpr): TExpr {
  match e.kind {
    case XCall(_, args) -> {
      var i = 0
      for a in args {
        match a {
          case TArgIn(v) -> {
            if i > 0 and isAwait(v) {
              acc[0] = acc[0] + 1
            }
            i = i + 1
          }
          case _ -> ()
        }
      }
    }
    case _ -> ()
  }
  e
}

test "an await after another argument is bound to a local ahead of the call" {
  val h = hoistOf(
    "package App\nasync func g(): Int { 1 }\nfunc add(a: Int, b: Int): Int { a + b }\nasync func f(x: Int): Int {\n  add(x, await g())\n}\n"
  )
  assertEqualInt(stackedAwaits(h.before), 1, "one stacked await before")
  assertEqualInt(stackedAwaits(h.pb), 0, "none after")
  assertHoisted(h, "argument")
}

test "an await as the first argument stays where it is" {
  val h = hoistOf(
    "package App\nasync func g(): Int { 1 }\nfunc add(a: Int, b: Int): Int { a + b }\nasync func f(x: Int): Int {\n  add(await g(), x)\n}\n"
  )
  assertEqualInt(stackedAwaits(h.pb), 0, "none")
  assertHoisted(h, "first argument")
}

test "an await in a binary operand's right side is hoisted" {
  val h = hoistOf("package App\nasync func g(): Int { 1 }\nasync func f(x: Int): Int {\n  x + await g()\n}\n")
  assertEqualInt(stackedAwaits(h.before), 1, "one stacked await before")
  assertEqualInt(stackedAwaits(h.pb), 0, "none after")
  assertHoisted(h, "binary")
}

test "an await in the right side of a short-circuit stays inside it" {
  val h = hoistOf("package App\nasync func g(): Bool { true }\nasync func f(x: Bool): Bool {\n  x and await g()\n}\n")
  assertHoisted(h, "short-circuit")
}

test "a function without await is untouched" {
  val h = hoistOf("package App\nfunc f(x: Int): Int { x + 1 }\n")
  assertEqualInt(stackedAwaits(h.pb), 0, "none")
  assertHoisted(h, "plain")
}

test "a while condition with an await becomes a loop that evaluates it each turn" {
  val h = hoistOf(
    "package App\nasync func more(): Bool { false }\nasync func f(): Int {\n  var n = 0\n  while await more() {\n    n = n + 1\n  }\n  n\n}\n"
  )
  assertHoisted(h, "while")
}
