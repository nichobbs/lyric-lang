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
import Lyric.ContractElaborator
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

val invSrc: String = "package App\nrecord Span {\n  lo: Int\n  hi: Int\n  invariant: lo <= hi\n}\npub func mk(a: Int): Span { Span(lo = a, hi = a + 1) }\npub func bump(s: inout Span): Unit { s = Span(lo = 0, hi = 1) }\nfunc hidden(): Span { Span(lo = 0, hi = 1) }\npub func take(s: in Span): Int { s.lo }\n"

func invBuild(): (PackageBuild, DefPathInterner) {
  val file = renumberNodeIds(synthesizeInvariantCheckers(parse(invSrc).file)).file
  val cr = check(file);
  (buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App"), cr.symbols.interner)
}

func firstStmtIsDirectCall(d: in TFnDecl): Bool {
  match d.body {
    case Some(b) -> match b.kind {
      case XBlock(stmts, _) -> if stmts.count > 0 {
        match stmts[0].kind {
          case TsExpr(x) -> match x.kind { case XCall(Direct(_, _), _) -> true; case _ -> false }
          case _ -> false
        }
      } else {
        false
      }
      case _ -> false
    }
    case None -> false
  }
}

func funcOf(pb: in PackageBuild, name: in String): Option[TFnDecl] {
  for f in pb.pkg.funcs {
    match mapGet(pb.names, f.sym.id) {
      case Some(k) -> if k.startsWith("App::" + name + "(") { return Some(value = f) }
      case None -> ()
    }
  }
  None
}

func messagesOfFn(d: in TFnDecl): List[String] {
  val acc: List[String] = newList()
  match d.body {
    case Some(b) -> assertMessages(b, acc)
    case None -> ()
  }
  acc
}

test "a public function's result and inout parameter of its own invariant type are re-checked at exit (D507)" {
  val (pb, interner) = invBuild()
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  for en in [true, false] {
    val done = elaborateBundle(interner, bundle, en)
    val mk = match funcOf(done[0], "mk") { case Some(f) -> f; case None -> pb.pkg.funcs[0] }
    val ms = messagesOfFn(mk)
    assertEqualInt(ms.count, 1, "one exit check on mk")
    assertTrue(ms[0] == "InvariantViolated: App.mk result", ms[0])
    val bump = match funcOf(done[0], "bump") { case Some(f) -> f; case None -> pb.pkg.funcs[0] }
    val bs = messagesOfFn(bump)
    assertEqualInt(bs.count, 1, "one exit check on bump")
    assertTrue(bs[0] == "InvariantViolated: App.bump parameter s", bs[0])
    val hidden = match funcOf(done[0], "hidden") { case Some(f) -> f; case None -> pb.pkg.funcs[0] }
    assertEqualInt(messagesOfFn(hidden).count, 0, "a function that is not pub is no boundary")
    val ds = verifyPackage(done[0].pkg, newList())
    assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("t", ds[0]) } else { "verifies" })
  }
}

test "a public function checks an in parameter of another package's invariant type on entry (D507)" {
  val (pb, interner) = invBuild()
  val libFns: List[TFnDecl] = newList()
  val appFns: List[TFnDecl] = newList()
  for f in pb.pkg.funcs {
    val key = match mapGet(pb.names, f.sym.id) { case Some(k) -> k; case None -> "" }
    if key.startsWith("App::__lyric_checked_") {
      libFns.add(f)
    } else {
      appFns.add(f)
    }
  }
  val lib = PackageBuild(
    pkg = TPackage(name = "Lib", symbols = pb.pkg.symbols, funcs = libFns),
    failed = pb.failed,
    total = pb.total,
    built = pb.built,
    names = pb.names,
    cases = pb.cases,
    uncovered = pb.uncovered,
    sites = pb.sites
  )
  val app = PackageBuild(
    pkg = TPackage(name = "App", symbols = pb.pkg.symbols, funcs = appFns),
    failed = pb.failed,
    total = pb.total,
    built = pb.built,
    names = pb.names,
    cases = pb.cases,
    uncovered = pb.uncovered,
    sites = pb.sites
  )
  val bundle: List[PackageBuild] = newList()
  bundle.add(app)
  val visible: List[PackageBuild] = newList()
  visible.add(lib)
  val done = elaborateBundleWith(interner, bundle, true, visible)
  val take = match funcOf(done[0], "take") { case Some(f) -> f; case None -> appFns[0] }
  assertTrue(firstStmtIsDirectCall(take), "the checker is called before the body")
  val ds = verifyPackage(done[0].pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("t", ds[0]) } else { "verifies" })
}

val genInvSrc: String = "package App\nrecord Cell[T] {\n  n: Int\n  tag: T\n  invariant: n >= 0\n}\npub func mkCell(a: Int): Cell[Int] { Cell(n = a, tag = a) }\npub func bumpCell(c: inout Cell[Int]): Unit { c = Cell(n = 1, tag = 2) }\npub func takeCell[T](c: in Cell[T]): Int { c.n }\n"

func genInvBuild(): (PackageBuild, DefPathInterner) {
  val file = renumberNodeIds(synthesizeInvariantCheckers(parse(genInvSrc).file)).file
  val cr = check(file);
  (buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App"), cr.symbols.interner)
}

func checkerCallTypeArgs(d: in TFnDecl): Int {
  var found = -1
  match d.body {
    case Some(b) -> match b.kind {
      case XBlock(stmts, _) -> {
        for st in stmts {
          match st.kind {
            case TsExpr(x) -> match x.kind {
              case XCall(Direct(_, targs), _) -> if found < 0 { found = targs.count }
              case _ -> ()
            }
            case _ -> ()
          }
        }
      }
      case _ -> ()
    }
    case None -> ()
  }
  found
}

test "a generic invariant type is checked at the exit of a public function, at the value's type arguments (D507, #7222)" {
  val (pb, interner) = genInvBuild()
  assertEqualInt(
    pb.failed.count,
    0,
    if pb.failed.count > 0 and pb.failed[0].messages.count > 0 { pb.failed[0].messages[0] } else { "built" }
  )
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  val done = elaborateBundle(interner, bundle, true)
  val mk = match funcOf(done[0], "mkCell") { case Some(f) -> f; case None -> pb.pkg.funcs[0] }
  val ms = messagesOfFn(mk)
  assertEqualInt(ms.count, 1, "one exit check on mkCell")
  assertTrue(ms[0] == "InvariantViolated: App.mkCell result", ms[0])
  val bump = match funcOf(done[0], "bumpCell") { case Some(f) -> f; case None -> pb.pkg.funcs[0] }
  val bs = messagesOfFn(bump)
  assertEqualInt(bs.count, 1, "one exit check on bumpCell")
  assertTrue(bs[0] == "InvariantViolated: App.bumpCell parameter c", bs[0])
  val ds = verifyPackage(done[0].pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("t", ds[0]) } else { "verifies" })
}

test "a public generic function checks a generic invariant parameter of another package on entry, at the value's arguments (D507, #7222)" {
  val (pb, interner) = genInvBuild()
  val libFns: List[TFnDecl] = newList()
  val appFns: List[TFnDecl] = newList()
  for f in pb.pkg.funcs {
    val key = match mapGet(pb.names, f.sym.id) { case Some(k) -> k; case None -> "" }
    if key.startsWith("App::__lyric_checked_") {
      libFns.add(f)
    } else {
      appFns.add(f)
    }
  }
  val lib = PackageBuild(
    pkg = TPackage(name = "Lib", symbols = pb.pkg.symbols, funcs = libFns),
    failed = pb.failed,
    total = pb.total,
    built = pb.built,
    names = pb.names,
    cases = pb.cases,
    uncovered = pb.uncovered,
    sites = pb.sites
  )
  val app = PackageBuild(
    pkg = TPackage(name = "App", symbols = pb.pkg.symbols, funcs = appFns),
    failed = pb.failed,
    total = pb.total,
    built = pb.built,
    names = pb.names,
    cases = pb.cases,
    uncovered = pb.uncovered,
    sites = pb.sites
  )
  val bundle: List[PackageBuild] = newList()
  bundle.add(app)
  val visible: List[PackageBuild] = newList()
  visible.add(lib)
  val done = elaborateBundleWith(interner, bundle, true, visible)
  val take = match funcOf(done[0], "takeCell") { case Some(f) -> f; case None -> appFns[0] }
  assertTrue(firstStmtIsDirectCall(take), "the checker is called before the body")
  assertEqualInt(checkerCallTypeArgs(take), 1, "at the one type argument of the parameter's type")
  val ds = verifyPackage(done[0].pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("t", ds[0]) } else { "verifies" })
}

/// The type arguments of the checker call at the head of `fname`'s elaborated body, for a package `src` whose
/// `__lyric_checked_*` functions are in a package the bundle sees but does not elaborate (a type of another package).
func entryCheckTypeArgs(src: in String, fname: in String): List[Ty] {
  val file = renumberNodeIds(synthesizeInvariantCheckers(parse(src).file)).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  val libFns: List[TFnDecl] = newList()
  val appFns: List[TFnDecl] = newList()
  for f in pb.pkg.funcs {
    val key = match mapGet(pb.names, f.sym.id) { case Some(k) -> k; case None -> "" }
    if key.startsWith("App::__lyric_checked_") {
      libFns.add(f)
    } else {
      appFns.add(f)
    }
  }
  val lib = PackageBuild(
    pkg = TPackage(name = "Lib", symbols = pb.pkg.symbols, funcs = libFns),
    failed = pb.failed,
    total = pb.total,
    built = pb.built,
    names = pb.names,
    cases = pb.cases,
    uncovered = pb.uncovered,
    sites = pb.sites
  )
  val app = PackageBuild(
    pkg = TPackage(name = "App", symbols = pb.pkg.symbols, funcs = appFns),
    failed = pb.failed,
    total = pb.total,
    built = pb.built,
    names = pb.names,
    cases = pb.cases,
    uncovered = pb.uncovered,
    sites = pb.sites
  )
  val bundle: List[PackageBuild] = newList()
  bundle.add(app)
  val visible: List[PackageBuild] = newList()
  visible.add(lib)
  val done = elaborateBundleWith(cr.symbols.interner, bundle, true, visible)
  val found: List[Ty] = newList()
  match funcOf(done[0], fname) {
    case Some(d) -> match d.body {
      case Some(b) -> match b.kind {
        case XBlock(stmts, _) -> {
          var seen = false
          for st in stmts {
            match st.kind {
              case TsExpr(x) -> match x.kind {
                case XCall(Direct(_, targs), _) -> if not seen { seen = true; for t in targs { found.add(t) } }
                case _ -> ()
              }
              case _ -> ()
            }
          }
        }
        case _ -> ()
      }
      case None -> ()
    }
    case None -> ()
  }
  found
}

val twoArgInvSrc: String = "package App\nrecord Pair[A, B] {\n  n: Int\n  a: A\n  b: B\n  invariant: n >= 0\n}\npub func takePair[X, Y](p: in Pair[X, Y]): Int { p.n }\npub func takeNested(p: in Pair[Int, Pair[Int, Int]]): Int { p.n }\npub func takeClosed(p: in Pair[Int, Int]): Int { p.n }\n"

test "the entry check of a generic parameter is called at the function's own type parameter (D519 test gap)" {
  val targs = entryCheckTypeArgs(genInvSrc, "takeCell")
  assertEqualInt(targs.count, 1, "one type argument")
  match targs[0] {
    case TParam(_, index) -> assertEqualInt(index, 0, "the function's first type parameter, not a closed type")
    case _ -> assertTrue(false, "a type parameter, got " + renderTy(targs[0]))
  }
}

test "the entry check of a two-argument generic type is called at both of the parameter's arguments in order (D519 test gap)" {
  val targs = entryCheckTypeArgs(twoArgInvSrc, "takePair")
  assertEqualInt(targs.count, 2, "one type argument per parameter of the type")
  match targs[0] {
    case TParam(_, index) -> assertEqualInt(index, 0, "X first")
    case _ -> assertTrue(false, "a type parameter, got " + renderTy(targs[0]))
  }
  match targs[1] {
    case TParam(_, index) -> assertEqualInt(index, 1, "Y second")
    case _ -> assertTrue(false, "a type parameter, got " + renderTy(targs[1]))
  }
}

test "the entry check of a nested generic argument is called at the closed argument types (D519 test gap)" {
  val targs = entryCheckTypeArgs(twoArgInvSrc, "takeNested")
  val closed = entryCheckTypeArgs(twoArgInvSrc, "takeClosed")
  assertEqualInt(closed.count, 2, "a closed instance of the type is checked too")
  assertEqualInt(targs.count, 2, "one type argument per parameter of the type")
  assertEqual(renderTy(targs[0]), "Int", "the first argument")
  assertTrue(
    renderTy(targs[1]).endsWith("[Int, Int]"),
    "the second is the nested Pair instance over Int, Int: " + renderTy(targs[1])
  )
}

test "a protected type's invariant is asserted at the exit of each member, with contracts on or off (D509)" {
  val src = "package App\nprotected type Gauge {\n  var level: Int = 0\n  invariant: level >= 0\n  entry bump(by: in Int): Unit {\n    level = level + by\n  }\n  func read(): Int {\n    level\n  }\n}\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  assertEqualInt(
    pb.failed.count,
    0,
    if pb.failed.count > 0 and pb.failed[0].messages.count > 0 { pb.failed[0].messages[0] } else { "built" }
  )
  assertEqualInt(pb.pkg.funcs.count, 2, "the entry and the function")
  for f in pb.pkg.funcs {
    assertEqualInt(f.invariants.count, 1, "each member carries the type's invariant")
  }
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  for en in [true, false] {
    val done = elaborateBundle(cr.symbols.interner, bundle, en)
    for f in done[0].pkg.funcs {
      val ms = messagesOfFn(f)
      assertEqualInt(ms.count, 1, "one invariant check per member")
      assertTrue(ms[0].startsWith("InvariantViolated: App.Gauge."), ms[0])
      assertTrue(ms[0].endsWith(" invariant level >= 0"), ms[0])
    }
    val ds = verifyPackage(done[0].pkg, newList())
    assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("t", ds[0]) } else { "verifies" })
  }
}

test "a protected member with an early return asserts the invariant at each exit (D509)" {
  val src = "package App\nprotected type Gauge {\n  var level: Int = 0\n  invariant: level >= 0\n  func read(by: in Int): Int {\n    if by > 100 {\n      return level\n    }\n    level + by\n  }\n}\n"
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  assertEqualInt(
    pb.failed.count,
    0,
    if pb.failed.count > 0 and pb.failed[0].messages.count > 0 { pb.failed[0].messages[0] } else { "built" }
  )
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  val done = elaborateBundle(cr.symbols.interner, bundle, true)
  val ms = messagesOfFn(done[0].pkg.funcs[0])
  assertEqualInt(ms.count, 2, "one check on the early return and one at the fall-off")
  val ds = verifyPackage(done[0].pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("t", ds[0]) } else { "verifies" })
}

val memberSrc: String = "package App\nrecord Span {\n  lo: Int\n  hi: Int\n  invariant: lo <= hi\n}\ninterface Fixer {\n  func fix(self: in Self, s: inout Span): Unit\n}\npub record Holder {\n  n: Int\n  func fix(self: in Holder, s: inout Span): Unit {\n    s = Span(lo = 0, hi = 1)\n  }\n}\nrecord Hidden {\n  n: Int\n  func fix(self: in Hidden, s: inout Span): Unit {\n    s = Span(lo = 0, hi = 1)\n  }\n}\nrecord Plain {\n  n: Int\n}\nimpl Fixer for Plain {\n  func fix(self: in Plain, s: inout Span): Unit {\n    s = Span(lo = 0, hi = 1)\n  }\n}\n"

test "a method of a pub record and an impl member are public boundaries, a method of a record that is not pub is not (D512)" {
  val file = renumberNodeIds(synthesizeInvariantCheckers(parse(memberSrc).file)).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  assertEqualInt(
    pb.failed.count,
    0,
    if pb.failed.count > 0 and pb.failed[0].messages.count > 0 { pb.failed[0].messages[0] } else { "built" }
  )
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  val done = elaborateBundle(cr.symbols.interner, bundle, true)
  var holder = 0
  var hidden = 0
  var implMs = 0
  for f in done[0].pkg.funcs {
    val key = match mapGet(done[0].names, f.sym.id) { case Some(k) -> k; case None -> "" }
    val ms = messagesOfFn(f)
    if key.startsWith("App::Holder::fix") {
      holder = ms.count
    } else if key.startsWith("App::Hidden::fix") {
      hidden = ms.count
    } else if key.contains("$impl(Fixer)") {
      implMs = ms.count
    }
  }
  assertEqualInt(holder, 1, "the pub record's method re-checks its inout parameter")
  assertEqualInt(hidden, 0, "a record that is not pub is no boundary")
  assertEqualInt(implMs, 1, "an impl member re-checks its inout parameter")
  val ds = verifyPackage(done[0].pkg, newList())
  assertEqualInt(ds.count, 0, if ds.count > 0 { renderVerifyDiag("t", ds[0]) } else { "verifies" })
}
