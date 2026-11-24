//! tir_contracts_self_test.l - Lyric.Tir.Contracts (docs/70 §7.2, D502): contract elaboration on TIR.
//!
//! Each case builds a small package into TIR, elaborates its contracts, and checks that the output verifies and
//! that the body asserts what the AST elaborator asserts: the preconditions first, the `old(..)` snapshots before
//! them, the postconditions at every way out, with the violation messages the AST pass prints.
@test_module
package Lyric.TirContractsSelfTest

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
import Lyric.Tir.Contracts

record Elab {
  pb: PackageBuild
  before: PackageBuild
  diagnostics: Int
}

func elabOf(src: in String): Elab {
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  val done = elaborateBundle(cr.symbols.interner, bundle, true)
  Elab(pb = done[0], before = pb, diagnostics = cr.diagnostics.count)
}

func assertVerifies(e: in Elab, what: in String): Unit {
  assertEqualInt(e.diagnostics, 0, what + ": the source checks")
  assertTrue(e.before.total > 0, what + ": the source has bodies")
  assertEqualInt(e.before.built, e.before.total, what + ": every body builds")
  val ds = verifyPackage(e.pb.pkg, newList())
  assertEqualInt(
    ds.count,
    0,
    what + ": verifies" + (if ds.count > 0 { " " + renderVerifyDiag("t", ds[0]) } else { "" })
  )
}

/// The message literals of every `assert(..)` call in `e`, in source order.
func assertMessages(e: in TExpr, acc: in List[String]): Unit {
  match e.kind {
    case XBlock(stmts, tail) -> {
      for st in stmts {
        stmtMessages(st, acc)
      }
      match tail {
        case Some(t) -> assertMessages(t, acc)
        case None -> ()
      }
    }
    case XIf(_, t, f) -> {
      assertMessages(t, acc)
      match f {
        case Some(x) -> assertMessages(x, acc)
        case None -> ()
      }
    }
    case XCall(callee, args) -> match callee {
      case Intrinsic(op) -> match op {
        case IoBuiltin(name) -> if name == "assert" and args.count == 2 {
          match args[1] {
            case TArgIn(m) -> match m.kind {
              case XLit(l) -> match l { case TLString(t) -> acc.add(t); case _ -> () }
              case _ -> ()
            }
            case _ -> ()
          }
        }
        case _ -> ()
      }
      case _ -> ()
    }
    case _ -> ()
  }
}

func stmtMessages(st: in TStmt, acc: in List[String]): Unit {
  match st.kind {
    case TsExpr(e) -> assertMessages(e, acc)
    case TsLet(_, init) -> assertMessages(init, acc)
    case _ -> ()
  }
}

func fnNamed(e: in Elab, name: in String): Option[TFnDecl] {
  for f in e.pb.pkg.funcs {
    match mapGet(e.pb.names, f.sym.id) {
      case Some(k) -> if k.startsWith("App::" + name + "(") { return Some(value = f) }
      case None -> ()
    }
  }
  None
}

func messagesOf(e: in Elab, name: in String): List[String] {
  val acc: List[String] = newList()
  match fnNamed(e, name) {
    case Some(f) -> match f.body { case Some(b) -> assertMessages(b, acc); case None -> () }
    case None -> ()
  }
  acc
}

test "a requires clause is asserted first, with the AST pass's message" {
  val e = elabOf("package App\nfunc f(x: Int): Int\n  requires: x > 0\n{ x }\n")
  assertVerifies(e, "requires")
  val ms = messagesOf(e, "f")
  assertEqualInt(ms.count, 1, "one assertion")
  assertTrue(ms[0] == "PreconditionViolated: App.f requires x > 0", "the message: " + ms[0])
}

test "an ensures clause runs after the body with result bound" {
  val e = elabOf("package App\nfunc f(x: Int): Int\n  ensures: result >= x\n{ x + 1 }\n")
  assertVerifies(e, "ensures")
  val ms = messagesOf(e, "f")
  assertEqualInt(ms.count, 1, "one assertion")
  assertTrue(ms[0] == "PostconditionViolated: App.f ensures result >= x", "the message: " + ms[0])
}

test "requires comes before ensures and both are kept as clauses" {
  val e = elabOf("package App\nfunc f(x: Int): Int\n  requires: x > 0\n  ensures: result > 0\n{ x }\n")
  assertVerifies(e, "both")
  val ms = messagesOf(e, "f")
  assertEqualInt(ms.count, 2, "two assertions")
  assertTrue(ms[0].startsWith("PreconditionViolated"), "the precondition first")
  assertTrue(ms[1].startsWith("PostconditionViolated"), "the postcondition last")
  match fnNamed(e, "f") {
    case Some(f) -> {
      assertEqualInt(f.preconds.count, 1, "the clauses stay for the verifier")
      assertEqualInt(f.postconds.count, 1, "the clauses stay for the verifier")
    }
    case None -> assertTrue(false, "f")
  }
}

test "a return at any depth runs the postconditions" {
  val e = elabOf(
    "package App\nfunc f(x: Int): Int\n  ensures: result >= 0\n{\n  if x < 0 {\n    return 0\n  }\n  x\n}\n"
  )
  assertVerifies(e, "nested return")
  val ms = messagesOf(e, "f")
  assertTrue(ms.count >= 1, "the tail asserts")
  // The `return` inside the `if` is a block of its own: count every assertion in the whole body.
  var total = 0
  match fnNamed(e, "f") {
    case Some(f) -> {
      total = countAsserts(f.body)
    }
    case None -> ()
  }
  assertEqualInt(total, 2, "one at the return, one at the tail")
}

func countAsserts(b: in Option[TExpr]): Int {
  match b {
    case Some(x) -> countIn(x)
    case None -> 0
  }
}

func countIn(e: in TExpr): Int {
  match e.kind {
    case XBlock(stmts, tail) -> {
      var n = 0
      for st in stmts {
        n = n + countInStmt(st)
      }
      match tail {
        case Some(t) -> {
          n = n + countIn(t)
        }
        case None -> ()
      }
      n
    }
    case XIf(_, t, f) -> {
      var n = countIn(t)
      match f {
        case Some(x) -> {
          n = n + countIn(x)
        }
        case None -> ()
      }
      n
    }
    case XCall(callee, _) -> match callee {
      case Intrinsic(op) -> match op {
        case IoBuiltin(name) -> if name == "assert" { 1 } else { 0 }
        case _ -> 0
      }
      case _ -> 0
    }
    case _ -> 0
  }
}

func countInStmt(st: in TStmt): Int {
  match st.kind {
    case TsExpr(e) -> countIn(e)
    case TsLet(_, init) -> countIn(init)
    case _ -> 0
  }
}

test "old of an expression is a snapshot taken before the preconditions" {
  val e = elabOf("package App\nfunc f(x: Int): Int\n  requires: x > 0\n  ensures: result == old(x) + 1\n{ x + 1 }\n")
  assertVerifies(e, "old")
  match fnNamed(e, "f") {
    case Some(f) -> match f.body {
      case Some(b) -> match b.kind {
        case XBlock(stmts, _) -> match stmts[0].kind {
          case TsLet(pat, _) -> match pat.kind {
            case TpBind(d, _) -> assertTrue(
              d.name ==
                "__old_0",
              "the snapshot is the first statement: " +
                d.name
            )
            case _ -> assertTrue(
              false,
              "a binding"
            )
          }
          case _ -> assertTrue(false, "a let")
        }
        case _ -> assertTrue(false, "a block")
      }
      case None -> assertTrue(false, "a body")
    }
    case None -> assertTrue(false, "f")
  }
}

test "a Unit function gets its postconditions after the body" {
  val e = elabOf("package App\nfunc f(x: Int): Unit\n  requires: x > 0\n  ensures: x > 0\n{ println(\"hi\") }\n")
  assertVerifies(e, "unit")
  assertEqualInt(messagesOf(e, "f").count, 2, "both clauses")
}

test "a function without clauses is untouched" {
  val e = elabOf("package App\nfunc f(x: Int): Int { x }\n")
  assertVerifies(e, "no clauses")
  assertEqualInt(messagesOf(e, "f").count, 0, "no assertion")
}

test "contracts disabled leaves the body alone" {
  val file = renumberNodeIds(parse("package App\nfunc f(x: Int): Int\n  requires: x > 0\n{ x }\n").file).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  val done = elaborateBundle(cr.symbols.interner, bundle, false)
  var asserts = 0
  for f in done[0].pkg.funcs {
    asserts = asserts + countAsserts(f.body)
  }
  assertEqualInt(asserts, 0, "no assertion")
}

test "two functions with clauses in one package keep node ids unique" {
  val e = elabOf(
    "package App\nfunc f(x: Int): Int\n  requires: x > 0\n  ensures: result > 0\n{ x }\nfunc g(y: Int): Int\n  requires: y > 1\n  ensures: result > 1\n{ y }\n"
  )
  assertVerifies(e, "two functions")
  assertEqualInt(messagesOf(e, "f").count, 2, "f")
  assertEqualInt(messagesOf(e, "g").count, 2, "g")
}

test "several ensures clauses each reading old(..) read their own snapshots" {
  val e = elabOf(
    "package App\nfunc f(x: Int, y: Int): Int\n  ensures: result > old(x)\n  ensures: result > old(y)\n{ x + y + 1 }\n"
  )
  assertVerifies(e, "two olds")
  val oldIds: Map[Int, Bool] = newMap()
  val readIds: Map[Int, Bool] = newMap()
  match fnNamed(e, "f") {
    case Some(f) -> match f.body {
      case Some(b) -> match b.kind {
        case XBlock(stmts, _) -> {
          for st in stmts {
            match st.kind {
              case TsLet(pat, _) -> match pat.kind {
                case TpBind(d, _) -> if d.name.startsWith("__old_") { oldIds.add(d.id.id, true) }
                case _ -> ()
              }
              case TsExpr(x) -> collectLocalReads(x, readIds)
              case _ -> ()
            }
          }
        }
        case _ -> assertTrue(false, "a block")
      }
      case None -> assertTrue(false, "a body")
    }
    case None -> assertTrue(false, "f")
  }
  assertEqualInt(oldIds.count, 2, "one snapshot per old(..)")
  var read = 0
  for k in mapKeys(oldIds) {
    if readIds.containsKey(k) {
      read = read + 1
    }
  }
  assertEqualInt(read, 2, "the two assertions read the two different snapshots")
}

func collectLocalReads(e: in TExpr, seen: in Map[Int, Bool]): Unit {
  match e.kind {
    case XLocal(l) -> if not seen.containsKey(l.id) { seen.add(l.id, true) }
    case XCall(_, args) -> {
      for a in args {
        match a {
          case TArgIn(v) -> collectLocalReads(v, seen)
          case _ -> ()
        }
      }
    }
    case _ -> ()
  }
}
