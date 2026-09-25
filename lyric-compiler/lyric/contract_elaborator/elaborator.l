//! elaborator.l — Lyric.ContractElaborator
//!
//! Phase 5 §M5.2 stage 2.  The contract elaborator transforms a parsed
//! SourceFile by inserting runtime contract checks (`assert(...)` calls)
//! for `requires:` and `ensures:` clauses on each function.  The original
//! `contracts` list on each FunctionDecl is preserved so the verifier and
//! the contract-meta consumers can still see the source-level clauses.
//!
//! Mirrors the in-IL contract emission in
//! compiler/src/Lyric.Emitter/Emitter.fs (see `emitContractCheck` around
//! lines 1940 / 2698 / 2808): the bootstrap emitter runs every
//! `CCRequires` clause as a runtime check before executing the body, and
//! runs every `CCEnsures` clause at the function exit label after the
//! result has been routed into the function's `ResultLocal`.  The
//! elaborator produces a transformed AST where these checks appear as
//! explicit `assert(cond)` statements at the corresponding source
//! positions.
//!
//! Stage 2 scope (this file):
//!
//!   * `requires:` clauses — full elaboration.  An `assert(req)`
//!     statement is prepended (in source order) to the body block of
//!     every non-`@axiom` function with a body.
//!
//!   * `ensures:`  clauses — full elaboration including nested returns.
//!     Each `SReturn(Some(e))` and `SReturn(None)` at any nesting depth
//!     inside `if` / `match` / `try` / `for` / `while` / `loop` bodies
//!     is rewritten to bind the produced value into a synthetic local
//!     `__lyric_result_<n>`, run every `assert(<ensures with result ->
//!     __lyric_result_<n>>)`, then yield (or `return`) the local.  The
//!     trailing `SExpr` (implicit fall-off at the outermost level) is also
//!     rewritten.  Nested trailing expressions inside blocks are NOT
//!     rewritten — they are the value of the block expression, not a
//!     function return.
//!
//!   * `@axiom` functions — skipped (axiom decls have no body, so there
//!     is nothing to elaborate).
//!
//!   * Loop `invariant:` (`SInvariant`) — lowered to `assert(inv)` at
//!     the top of every reachable loop body (docs/41 §9 Band 4).  The
//!     check fires on initial entry and at the start of each iteration
//!     (continue / fall-through both re-enter the loop head).  Break
//!     exits without re-checking, matching the operational semantics in
//!     `docs/08-contract-semantics.md`.  The verifier consumes
//!     `SInvariant` nodes from the original AST (before elaboration), so
//!     the F# emitter and `lyric prove` continue to see them.
//!
//!   * Protected-type entries (`PMEntry`) — fully elaborated.  For each
//!     `IProtected` item, the `PMInvariant` clauses are collected as
//!     `CCEnsures` and appended to each `PMEntry`'s own contract list.
//!     `elaborateFunctionBody` is then applied to the combined list,
//!     inserting `assert(requires)` at the top and the combined
//!     ensures / invariant asserts at every return / fall-off site.
//!     `PMFunc` members delegate to `elaborateFunction`.  `PMField` and
//!     `PMInvariant` are passed through unchanged.  Barrier (`when:`)
//!     clauses survive in `ed.contracts` for the verifier but are not
//!     lowered to run-time asserts here (they become Monitor.Wait
//!     conditions in the backend).
//!
//! Public surface:
//!
//!   pub func elaborateFile(file: in SourceFile): SourceFile
//!
//!     Returns a new SourceFile with the requires/ensures elaboration
//!     applied.  The input is not mutated.
//!
//!   pub func elaborateFunction(fn: in FunctionDecl): FunctionDecl
//!
//!     Per-function elaboration.  Useful when callers want to elaborate
//!     a single FunctionDecl (e.g. an interface default method) without
//!     wrapping it in a SourceFile.
//!
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Fmt as Fmt

// ─────────────────────────────────────────────────────────────────────────────
// §1. Annotation predicates.
// ─────────────────────────────────────────────────────────────────────────────
func hasSimpleAnnotation(name: in String, anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val a = anns[i]
    if a.name.segments.count == 1 and a.name.segments[0] == name {
      return true
    }
    i = i + 1
  }
  false
}

func functionIsAxiom(fn: in FunctionDecl): Bool {
  hasSimpleAnnotation("axiom", fn.annotations)
}

// True when the file carries `@proof_required` (with or without a modifier).
// In @proof_required files, contract clauses are SMT obligations consumed by
// `lyric prove` — they must NOT be lowered to runtime assert() calls by the
// elaborator.  The verifier reads the original clauses directly from
// fn.contracts, so the SourceFile is returned unchanged.
func fileIsProofRequired(file: in SourceFile): Bool {
  hasSimpleAnnotation("proof_required", file.fileAnnotations)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Synthetic-name counter.  The elaborator threads a `RenameCounter`
//     through each function so generated locals in nested scopes do not
//     collide.  The counter is reset per function — no two synthetic
//     names live in the same scope.
// ─────────────────────────────────────────────────────────────────────────────
pub record RenameCounter {
  var next: Int
}

/// A contract clause's expression together with the span of the clause it
/// came from.
///
/// `CCRequires`/`CCEnsures` each carry their own span, but the collectors used
/// to drop it and hand back a bare `List[Expr]`, so every synthesized `assert`
/// was anchored at the enclosing function body or `return` statement instead of
/// at the `requires:`/`ensures:` line the user wrote. §3's own comment claims
/// helpers build "at the same `Span` as the source clause they correspond to";
/// this is what makes that true for the asserts (docs/63 band B1).
///
/// A record rather than a raw tuple: the pair threads through ten functions
/// here, which is the situation `llvm_ir.l` moved *away* from tuples for
/// ("keeping match sites self-describing"), and it mirrors `lexer.l`'s
/// `SpannedToken` — the same value-plus-its-own-span shape.
record SpannedExpr {
  expr: Expr
  span: Span
  // The failure message the synthesized assert raises, naming the violation
  // kind, the owning function and the clause as written (#7225).
  message: String
}

pub func newRenameCounter(): RenameCounter {
  RenameCounter(next = 0)
}

func freshResultName(c: inout RenameCounter): String {
  val n = c.next
  c.next = n + 1
  "__lyric_result_" + toString(n)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. AST builders.  All helpers in this section construct Expr / Stmt
//     fragments at the same `Span` as the source clause they correspond
//     to, so downstream diagnostics keep pointing at user code.
// ─────────────────────────────────────────────────────────────────────────────
func mkUnit(sp: in Span): Expr {
  mkExpr(ELiteral(lit = LUnit), sp)
}

// Returns true iff any clause in the list contains an EResult node.
func anyHaveResultSpanned(cs: in List[SpannedExpr]): Bool {
  var i = 0
  while i < cs.count {
    if exprContainsResult(cs[i].expr) {
      return true
    }
    i = i + 1
  }
  false
}

// Returns true iff any expression in the list contains an EResult node.
func anyHaveResult(exprs: in List[Expr]): Bool {
  var i = 0
  while i < exprs.count {
    if exprContainsResult(exprs[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func exprContainsResult(e: in Expr): Bool {
  match e.kind {
    case EResult -> true
    case ELiteral(_) -> false
    case EPath(_) -> false
    case ESelf -> false
    case EError -> false
    case ERange(_) -> false
    case EParen(inner) -> exprContainsResult(inner)
    case ETuple(exprs) -> anyHaveResult(exprs)
    case EList(exprs) -> anyHaveResult(exprs)
    case EIf(cond, thenBranch, elseOpt, _) -> {
      if exprContainsResult(cond) {
        return true
      }
      if eobContainsResult(thenBranch) {
        return true
      }
      match elseOpt {
        case Some(eb) -> eobContainsResult(eb)
        case None -> false
      }
    }
    case EMatch(scrutinee, arms) -> {
      if exprContainsResult(scrutinee) {
        return true
      }
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> if exprContainsResult(g) { return true }
          case None -> {
          }
        }
        if eobContainsResult(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case ECall(fn, args) -> {
      if exprContainsResult(fn) {
        return true
      }
      var i = 0
      while i < args.count {
        val hasIt = match args[i] {
          case CAPositional(v) -> exprContainsResult(v)
          case CANamed(_, v, _) -> exprContainsResult(v)
        }
        if hasIt {
          return true
        }
        i = i + 1
      }
      false
    }
    case ETypeApp(fn, _) -> exprContainsResult(fn)
    case EIndex(recv, indices) -> {
      if exprContainsResult(recv) {
        return true
      }
      anyHaveResult(indices)
    }
    case EMember(recv, _) -> exprContainsResult(recv)
    case EBinop(_, l, r) -> exprContainsResult(l) or exprContainsResult(r)
    case EPrefix(_, x) -> exprContainsResult(x)
    case EPropagate(inner) -> exprContainsResult(inner)
    case EAwait(inner) -> exprContainsResult(inner)
    case EYield(inner) -> exprContainsResult(inner)
    case ESpawn(inner) -> exprContainsResult(inner)
    case ETry(inner) -> exprContainsResult(inner)
    case EOld(inner) -> exprContainsResult(inner)
    case EAssign(t, _, v) -> exprContainsResult(t) or exprContainsResult(v)
    case EBlock(blk) -> blockContainsResult(blk)
    case EUnsafe(blk) -> blockContainsResult(blk)
    case ELambda(_, body) -> blockContainsResult(body)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(x) -> if exprContainsResult(x) { return true }
          case ISText(_, _) -> {
          }
        }
        i = i + 1
      }
      false
    }
    case EForall(_, whereOpt, body) -> {
      match whereOpt {
        case Some(w) -> if exprContainsResult(w) { return true }
        case None -> {
        }
      }
      exprContainsResult(body)
    }
    case EExists(_, whereOpt, body) -> {
      match whereOpt {
        case Some(w) -> if exprContainsResult(w) { return true }
        case None -> {
        }
      }
      exprContainsResult(body)
    }
  }
}

func blockContainsResult(body: in Block): Bool {
  var i = 0
  while i < body.statements.count {
    match body.statements[i].kind {
      case SExpr(e) -> if exprContainsResult(e) { return true }
      case SReturn(Some(e)) -> if exprContainsResult(e) { return true }
      case SLocal(binding) -> match binding {
        case LBVal(_, _, init) -> if exprContainsResult(init) { return true }
        case LBLet(_, _, init) -> if exprContainsResult(init) { return true }
        case LBVar(_, _, Some(init)) -> if exprContainsResult(init) { return true }
        case LBVar(_, _, None) -> {
        }
      }
      case SFor(_, _, iter, bdy) -> {
        if exprContainsResult(iter) {
          return true
        }
        if blockContainsResult(bdy) {
          return true
        }
      }
      case SWhile(_, cond, bdy) -> {
        if exprContainsResult(cond) {
          return true
        }
        if blockContainsResult(bdy) {
          return true
        }
      }
      case SLoop(_, bdy) -> if blockContainsResult(bdy) { return true }
      case SAssign(_, _, rhs) -> if exprContainsResult(rhs) { return true }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

func eobContainsResult(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(e) -> exprContainsResult(e)
    case EOBBlock(body) -> blockContainsResult(body)
  }
}

func mkPath(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  mkExpr(EPath(path = ModulePath(segments = segs, span = sp)), sp)
}

func mkAssertCall(cond: in Expr, message: in String, sp: in Span): Statement {
  val callee = mkPath("assert", sp)
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = cond))
  args.add(CAPositional(expr = mkExpr(ELiteral(lit = LString(text = message)), sp)))
  val call = mkExpr(ECall(fn = callee, args = args), sp)
  mkStmt(SExpr(expr = call), sp)
}

// `let <name> = <init>` with type inferred.
func mkLetBinding(name: in String, init: in Expr, sp: in Span): Statement {
  // The `ty` field MUST be bound through an explicitly-typed `None` local.
  // A bare `LBLet(..., ty = None, ...)` hits the #1451 cross-package
  // generic-arg widening bug when the stage-0 F# compiler builds this
  // package: the fresh `None` widens to `Option[obj]` with a stale generic
  // arg, so the value reaching the MSIL codegen's `match binding.ty` can't
  // dispatch — `annoTy` resolves to null and `annoTy != MObject` NREs in
  // `lowerStmtMsil`'s LBLet arm (#1871).  Pinning the static type here emits
  // a proper `Option[TypeExpr].None`.
  val noTy: Option[TypeExpr] = None
  val binding = LBLet(name = name, ty = noTy, init = init)
  mkStmt(SLocal(binding = binding), sp)
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. `result` substitution.
//
//     `substResult(e, name)` returns a structural copy of `e` with every
//     `EResult` leaf rewritten to `EPath([name])`.  Identity-preserving
//     for the rest of the tree (we still allocate fresh records, but
//     each leaf retains its original `Span`).
// ─────────────────────────────────────────────────────────────────────────────
func substResult(e: in Expr, name: in String, renames: in Map[String, String]): Expr {
  match e.kind {
    case EResult -> if name == "" { e } else { mkPath(name, e.span) }
    case ELiteral(_) -> e
    case EPath(p) -> renamePath(e, p, renames)
    case ESelf -> e
    case EError -> e
    case EParen(inner) -> mkExpr(EParen(inner = substResult(inner, name, renames)), e.span)
    case ETuple(exprs) -> {
      val outs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        outs.add(substResult(exprs[i], name, renames))
        i = i + 1
      }
      mkExpr(ETuple(exprs = outs), e.span)
    }
    case EList(exprs) -> {
      val outs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        outs.add(substResult(exprs[i], name, renames))
        i = i + 1
      }
      mkExpr(EList(exprs = outs), e.span)
    }
    case EIf(cond, thenBranch, elseOpt, thenForm) -> {
      val newElse: Option[ExprOrBlock] = match elseOpt {
        case Some(eb) -> Some(value = substResultEob(eb, name, renames))
        case None -> None
      }
      mkExpr(
        EIf(
          cond = substResult(cond, name, renames),
          thenBranch = substResultEob(thenBranch, name, renames),
          elseBranch = newElse,
          thenForm = thenForm
        ),
        e.span
      )
    }
    case EMatch(scrutinee, arms) -> {
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val armRenames = withoutNames(renames, patternBoundNames(arm.pattern))
        val newGuard: Option[Expr] = match arm.guard {
          case Some(g) -> Some(value = substResult(g, name, armRenames))
          case None -> None
        }
        newArms.add(
          MatchArm(
            pattern = arm.pattern,
            guard = newGuard,
            body = substResultEob(arm.body, name, armRenames),
            span = arm.span
          )
        )
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = substResult(scrutinee, name, renames), arms = newArms), e.span)
    }
    case EAwait(inner) -> mkExpr(EAwait(inner = substResult(inner, name, renames)), e.span)
    case EYield(inner) -> mkExpr(EYield(inner = substResult(inner, name, renames)), e.span)
    case ESpawn(inner) -> mkExpr(ESpawn(inner = substResult(inner, name, renames)), e.span)
    case ETry(inner) -> mkExpr(ETry(inner = substResult(inner, name, renames)), e.span)
    case EOld(inner) -> mkExpr(EOld(inner = substResult(inner, name, renames)), e.span)
    case EForall(binders, whereOpt, body) -> {
      val qRenames = withoutNames(renames, propertyBinderNames(binders))
      val newWhere: Option[Expr] = match whereOpt {
        case Some(w) -> Some(value = substResult(w, name, qRenames))
        case None -> None
      }
      mkExpr(EForall(binders = binders, whereExpr = newWhere, body = substResult(body, name, qRenames)), e.span)
    }
    case EExists(binders, whereOpt, body) -> {
      val qRenames = withoutNames(renames, propertyBinderNames(binders))
      val newWhere: Option[Expr] = match whereOpt {
        case Some(w) -> Some(value = substResult(w, name, qRenames))
        case None -> None
      }
      mkExpr(EExists(binders = binders, whereExpr = newWhere, body = substResult(body, name, qRenames)), e.span)
    }
    case ELambda(params, body) -> mkExpr(
      ELambda(
        lambdaParams = params,
        body = substResultBlock(
          body,
          name,
          withoutNames(renames, lambdaParamNames(params))
        )
      ),
      e.span
    )
    case ECall(fn, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(n, v, sp) -> newArgs.add(CANamed(name = n, value = substResult(v, name, renames), span = sp))
          case CAPositional(v) -> newArgs.add(CAPositional(expr = substResult(v, name, renames)))
        }
        i = i + 1
      }
      mkExpr(ECall(fn = substResult(fn, name, renames), args = newArgs), e.span)
    }
    case ETypeApp(fn, ts) -> mkExpr(ETypeApp(fn = substResult(fn, name, renames), args = ts), e.span)
    case EIndex(recv, indices) -> {
      val newIdx: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        newIdx.add(substResult(indices[i], name, renames))
        i = i + 1
      }
      mkExpr(EIndex(receiver = substResult(recv, name, renames), indices = newIdx), e.span)
    }
    case EMember(recv, mname) -> mkExpr(
      EMember(receiver = substResult(recv, name, renames), memberName = mname),
      e.span
    )
    case EPropagate(inner) -> mkExpr(EPropagate(inner = substResult(inner, name, renames)), e.span)
    case EPrefix(op, x) -> mkExpr(EPrefix(op = op, operand = substResult(x, name, renames)), e.span)
    case EBinop(op, l, r) -> mkExpr(
      EBinop(op = op, lhs = substResult(l, name, renames), rhs = substResult(r, name, renames)),
      e.span
    )
    case ERange(bound) -> mkExpr(ERange(bound = substResultRange(bound, name, renames)), e.span)
    case EAssign(t, op, v) -> mkExpr(
      EAssign(
        target = substResult(t, name, renames),
        op = op,
        value = substResult(v, name, renames)
      ),
      e.span
    )
    case EBlock(blk) -> mkExpr(EBlock(block = substResultBlock(blk, name, renames)), e.span)
    case EUnsafe(blk) -> mkExpr(EUnsafe(block = substResultBlock(blk, name, renames)), e.span)
    case EInterpolated(segs) -> {
      val outs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, sp) -> outs.add(ISText(text = t, span = sp))
          case ISExpr(x) -> outs.add(ISExpr(expr = substResult(x, name, renames)))
        }
        i = i + 1
      }
      mkExpr(EInterpolated(segments = outs), e.span)
    }
  }
}

// Rename a single-segment path per `renames` (interface-parameter name ->
// implementing method's parameter name, used when an impl method inherits
// its interface method's contract clauses).  Multi-segment paths are
// qualified references and never name a parameter.
func renamePath(e: in Expr, p: in ModulePath, renames: in Map[String, String]): Expr {
  if p.segments.count != 1 {
    return e
  }
  match mapGet(renames, p.segments[0]) {
    case Some(target) -> mkPath(target, e.span)
    case None -> e
  }
}

func withoutNames(renames: in Map[String, String], names: in List[String]): Map[String, String] {
  var hit = false
  var i = 0
  while i < names.count {
    if renames.containsKey(names[i]) {
      hit = true
    }
    i = i + 1
  }
  if not hit {
    return renames
  }
  val acc: Map[String, String] = newMap()
  val keys = mapKeys(renames)
  var k = 0
  while k < keys.count {
    if not names.contains(keys[k]) {
      match mapGet(renames, keys[k]) {
        case Some(v) -> acc.add(keys[k], v)
        case None -> ()
      }
    }
    k = k + 1
  }
  acc
}

func lambdaParamNames(ps: in List[LambdaParam]): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < ps.count {
    acc.add(ps[i].name)
    i = i + 1
  }
  acc
}

func propertyBinderNames(bs: in List[PropertyBinder]): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < bs.count {
    acc.add(bs[i].name)
    i = i + 1
  }
  acc
}

func localBindingNames(b: in LocalBinding): List[String] {
  match b {
    case LBVal(pat, _, _) -> patternBoundNames(pat)
    case LBLet(n, _, _) -> {
      val acc: List[String] = newList()
      acc.add(n)
      acc
    }
    case LBVar(n, _, _) -> {
      val acc: List[String] = newList()
      acc.add(n)
      acc
    }
  }
}

func patternBoundNames(pat: in Pattern): List[String] {
  val acc: List[String] = newList()
  collectPatternNames(pat, acc)
  acc
}

func collectPatternNames(pat: in Pattern, acc: in List[String]): Unit {
  match pat.kind {
    case PBinding(n, innerOpt) -> {
      acc.add(n)
      match innerOpt {
        case Some(inner) -> collectPatternNames(inner, acc)
        case None -> ()
      }
    }
    case PConstructor(_, args) -> {
      var i = 0
      while i < args.count {
        collectPatternNames(args[i], acc)
        i = i + 1
      }
    }
    case PRecord(_, fields, _) -> {
      var i = 0
      while i < fields.count {
        match fields[i] {
          case RPFNamed(_, p, _) -> collectPatternNames(p, acc)
          case RPFShort(n, _) -> acc.add(n)
        }
        i = i + 1
      }
    }
    case PTuple(ps) -> {
      var i = 0
      while i < ps.count {
        collectPatternNames(ps[i], acc)
        i = i + 1
      }
    }
    case PParen(inner) -> collectPatternNames(inner, acc)
    case PTypeTest(inner, _) -> collectPatternNames(inner, acc)
    case POr(ps) -> {
      if ps.count > 0 {
        collectPatternNames(ps[0], acc)
      }
    }
    case _ -> ()
  }
}

func substResultEob(eob: in ExprOrBlock, name: in String, renames: in Map[String, String]): ExprOrBlock {
  match eob {
    case EOBExpr(x) -> EOBExpr(expr = substResult(x, name, renames))
    case EOBBlock(blk) -> EOBBlock(block = substResultBlock(blk, name, renames))
  }
}

func substResultBlock(blk: in Block, name: in String, renames: in Map[String, String]): Block {
  val outs: List[Statement] = newList()
  var scopeRenames = renames
  var i = 0
  while i < blk.statements.count {
    val st = blk.statements[i]
    outs.add(substResultStmt(st, name, scopeRenames))
    // A local binding shadows a renamed parameter for the rest of the block.
    match st.kind {
      case SLocal(binding) -> {
        scopeRenames = withoutNames(scopeRenames, localBindingNames(binding))
      }
      case _ -> ()
    }
    i = i + 1
  }
  Block(statements = outs, span = blk.span)
}

func substResultStmt(s: in Statement, name: in String, renames: in Map[String, String]): Statement {
  match s.kind {
    case SLocal(binding) -> mkStmt(SLocal(binding = substResultBinding(binding, name, renames)), s.span)
    case SAssign(t, op, v) -> mkStmt(
      SAssign(
        target = substResult(t, name, renames),
        op = op,
        value = substResult(v, name, renames)
      ),
      s.span
    )
    case SReturn(valOpt) -> {
      val newVal: Option[Expr] = match valOpt {
        case Some(v) -> Some(value = substResult(v, name, renames))
        case None -> None
      }
      mkStmt(SReturn(value = newVal), s.span)
    }
    case SBreak(_) -> s
    case SContinue(_) -> s
    case SThrow(x) -> mkStmt(SThrow(expr = substResult(x, name, renames)), s.span)
    case STry(body, catches, finally_) -> {
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val c = catches[i]
        newCatches.add(
          CatchClause(
            typeName = c.typeName,
            bindName = c.bindName,
            body = substResultBlock(c.body, name, renames),
            span = c.span
          )
        )
        i = i + 1
      }
      val newFinally = match finally_ { case None -> None; case Some(fb) -> Some(substResultBlock(fb, name, renames)) }
      mkStmt(STry(body = substResultBlock(body, name, renames), catches = newCatches, finally_ = newFinally), s.span)
    }
    case SDefer(body) -> mkStmt(SDefer(body = substResultBlock(body, name, renames)), s.span)
    case SScope(label, body) -> mkStmt(SScope(binding = label, body = substResultBlock(body, name, renames)), s.span)
    case SFor(label, pat, iter, body) -> mkStmt(
      SFor(
        label = label,
        pat = pat,
        iter = substResult(iter, name, renames),
        body = substResultBlock(body, name, renames)
      ),
      s.span
    )
    case SWhile(label, cond, body) -> mkStmt(
      SWhile(
        label = label,
        cond = substResult(cond, name, renames),
        body = substResultBlock(body, name, renames)
      ),
      s.span
    )
    case SLoop(label, body) -> mkStmt(SLoop(label = label, body = substResultBlock(body, name, renames)), s.span)
    case SInvariant(x) -> mkStmt(SInvariant(expr = substResult(x, name, renames)), s.span)
    case SExpr(x) -> mkStmt(SExpr(expr = substResult(x, name, renames)), s.span)
    case SRule(l, r) -> mkStmt(SRule(lhs = substResult(l, name, renames), rhs = substResult(r, name, renames)), s.span)
    case SItem(_) -> s
  }
}

func substResultBinding(b: in LocalBinding, name: in String, renames: in Map[String, String]): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = substResult(init, name, renames))
    case LBLet(n, ty, init) -> LBLet(name = n, ty = ty, init = substResult(init, name, renames))
    case LBVar(n, ty, initOpt) -> {
      val newInit: Option[Expr] = match initOpt {
        case Some(x) -> Some(value = substResult(x, name, renames))
        case None -> None
      }
      LBVar(name = n, ty = ty, init = newInit)
    }
  }
}

func substResultRange(b: in RangeBound, name: in String, renames: in Map[String, String]): RangeBound {
  match b {
    case RBClosed(lo, hi) -> RBClosed(lo = substResult(lo, name, renames), hi = substResult(hi, name, renames))
    case RBHalfOpen(lo, hi, bareDotDot) -> RBHalfOpen(
      lo = substResult(lo, name, renames),
      hi = substResult(hi, name, renames),
      bareDotDot = bareDotDot
    )
    case RBLowerOpen(hi) -> RBLowerOpen(hi = substResult(hi, name, renames))
    case RBUpperOpen(lo) -> RBUpperOpen(lo = substResult(lo, name, renames))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4b. EOld collection and replacement.
//
//     `old(e)` in an `ensures:` clause captures the value of expression `e`
//     at function entry (the pre-state).  The elaborator materialises each
//     `EOld(inner)` as a synthetic `let __old_N = inner` binding prepended
//     to the function body before requires asserts, then rewrites the ensures
//     expressions to replace `EOld(inner)` with `EPath("__old_N")`.
//
//     Collection and replacement traverse ensures expressions in the same
//     depth-first left-to-right order so counter values stay in sync.
//     `EOld` is treated as a leaf in both passes (no recursion into `inner`).
// ─────────────────────────────────────────────────────────────────────────────
func freshOldName(n: in Int): String {
  "__old_" + toString(n)
}

func collectOldExpr(e: in Expr, acc: inout List[Expr]) {
  match e.kind {
    case EOld(inner) -> acc.add(inner)
    case ELiteral(_) -> ()
    case EPath(_) -> ()
    case ESelf -> ()
    case EResult -> ()
    case EError -> ()
    case ERange(bound) -> collectOldExprRange(bound, acc)
    case EParen(inner) -> collectOldExpr(inner, acc)
    case ETuple(exprs) -> collectOldExprList(exprs, acc)
    case EList(exprs) -> collectOldExprList(exprs, acc)
    case EIf(cond, thenBranch, elseOpt, _) -> {
      collectOldExpr(cond, acc)
      collectOldExprEob(thenBranch, acc)
      match elseOpt {
        case Some(eb) -> collectOldExprEob(eb, acc)
        case None -> ()
      }
    }
    case EMatch(scrutinee, arms) -> {
      collectOldExpr(scrutinee, acc)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> collectOldExpr(g, acc)
          case None -> ()
        }
        collectOldExprEob(arms[i].body, acc)
        i = i + 1
      }
    }
    case ECall(fn, args) -> {
      collectOldExpr(fn, acc)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(v) -> collectOldExpr(v, acc)
          case CANamed(_, v, _) -> collectOldExpr(v, acc)
        }
        i = i + 1
      }
    }
    case ETypeApp(fn, _) -> collectOldExpr(fn, acc)
    case EIndex(recv, indices) -> {
      collectOldExpr(recv, acc)
      collectOldExprList(indices, acc)
    }
    case EMember(recv, _) -> collectOldExpr(recv, acc)
    case EBinop(_, l, r) -> {
      collectOldExpr(l, acc)
      collectOldExpr(r, acc)
    }
    case EPrefix(_, x) -> collectOldExpr(x, acc)
    case EPropagate(inner) -> collectOldExpr(inner, acc)
    case EAwait(inner) -> collectOldExpr(inner, acc)
    case EYield(inner) -> collectOldExpr(inner, acc)
    case ESpawn(inner) -> collectOldExpr(inner, acc)
    case ETry(inner) -> collectOldExpr(inner, acc)
    case EForall(_, whereOpt, body) -> {
      match whereOpt {
        case Some(w) -> collectOldExpr(w, acc)
        case None -> ()
      }
      collectOldExpr(body, acc)
    }
    case EExists(_, whereOpt, body) -> {
      match whereOpt {
        case Some(w) -> collectOldExpr(w, acc)
        case None -> ()
      }
      collectOldExpr(body, acc)
    }
    case ELambda(_, body) -> collectOldExprBlock(body, acc)
    case EAssign(t, _, v) -> {
      collectOldExpr(t, acc)
      collectOldExpr(v, acc)
    }
    case EBlock(blk) -> collectOldExprBlock(blk, acc)
    case EUnsafe(blk) -> collectOldExprBlock(blk, acc)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(x) -> collectOldExpr(x, acc)
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
    }
  }
}

func collectOldExprList(exprs: in List[Expr], acc: inout List[Expr]) {
  var i = 0
  while i < exprs.count {
    collectOldExpr(exprs[i], acc)
    i = i + 1
  }
}

func collectOldExprRange(b: in RangeBound, acc: inout List[Expr]) {
  match b {
    case RBClosed(lo, hi) -> {
      collectOldExpr(lo, acc)
      collectOldExpr(hi, acc)
    }
    case RBHalfOpen(lo, hi, _) -> {
      collectOldExpr(lo, acc)
      collectOldExpr(hi, acc)
    }
    case RBLowerOpen(hi) -> collectOldExpr(hi, acc)
    case RBUpperOpen(lo) -> collectOldExpr(lo, acc)
  }
}

func collectOldExprEob(eob: in ExprOrBlock, acc: inout List[Expr]) {
  match eob {
    case EOBExpr(e) -> collectOldExpr(e, acc)
    case EOBBlock(blk) -> collectOldExprBlock(blk, acc)
  }
}

func collectOldExprBlock(blk: in Block, acc: inout List[Expr]) {
  var i = 0
  while i < blk.statements.count {
    collectOldExprStmt(blk.statements[i], acc)
    i = i + 1
  }
}

func collectOldExprStmt(s: in Statement, acc: inout List[Expr]) {
  match s.kind {
    case SReturn(opt) -> {
      match opt {
        case Some(e) -> collectOldExpr(e, acc)
        case None -> ()
      }
    }
    case SExpr(e) -> collectOldExpr(e, acc)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> collectOldExpr(init, acc)
        case LBLet(_, _, init) -> collectOldExpr(init, acc)
        case LBVar(_, _, optInit) -> {
          match optInit {
            case Some(init) -> collectOldExpr(init, acc)
            case None -> ()
          }
        }
      }
    }
    case SAssign(t, _, v) -> {
      collectOldExpr(t, acc)
      collectOldExpr(v, acc)
    }
    case SFor(_, _, iter, body) -> {
      collectOldExpr(iter, acc)
      collectOldExprBlock(body, acc)
    }
    case SWhile(_, cond, body) -> {
      collectOldExpr(cond, acc)
      collectOldExprBlock(body, acc)
    }
    case SLoop(_, body) -> collectOldExprBlock(body, acc)
    case SInvariant(x) -> collectOldExpr(x, acc)
    case SRule(l, r) -> {
      collectOldExpr(l, acc)
      collectOldExpr(r, acc)
    }
    case _ -> ()
  }
}

// Replace each `EOld` node in `e` with `EPath("__old_N")` (same traversal
// order as `collectOldExpr`), incrementing `counter.next` each time.
func replaceOldExpr(e: in Expr, counter: inout RenameCounter): Expr {
  match e.kind {
    case EOld(_) -> {
      val n = counter.next
      counter.next = n + 1
      mkPath(freshOldName(n), e.span)
    }
    case ELiteral(_) -> e
    case EPath(_) -> e
    case ESelf -> e
    case EResult -> e
    case EError -> e
    case EParen(inner) -> mkExpr(EParen(inner = replaceOldExpr(inner, counter)), e.span)
    case ETuple(exprs) -> {
      val outs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        outs.add(replaceOldExpr(exprs[i], counter))
        i = i + 1
      }
      mkExpr(ETuple(exprs = outs), e.span)
    }
    case EList(exprs) -> {
      val outs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        outs.add(replaceOldExpr(exprs[i], counter))
        i = i + 1
      }
      mkExpr(EList(exprs = outs), e.span)
    }
    case EIf(cond, thenBranch, elseOpt, thenForm) -> {
      val newElse: Option[ExprOrBlock] = match elseOpt {
        case Some(eb) -> Some(value = replaceOldExprEob(eb, counter))
        case None -> None
      }
      mkExpr(
        EIf(
          cond = replaceOldExpr(cond, counter),
          thenBranch = replaceOldExprEob(thenBranch, counter),
          elseBranch = newElse,
          thenForm = thenForm
        ),
        e.span
      )
    }
    case EMatch(scrutinee, arms) -> {
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val newGuard: Option[Expr] = match arm.guard {
          case Some(g) -> Some(value = replaceOldExpr(g, counter))
          case None -> None
        }
        newArms.add(
          MatchArm(pattern = arm.pattern, guard = newGuard, body = replaceOldExprEob(arm.body, counter), span = arm.span)
        )
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = replaceOldExpr(scrutinee, counter), arms = newArms), e.span)
    }
    case EAwait(inner) -> mkExpr(EAwait(inner = replaceOldExpr(inner, counter)), e.span)
    case EYield(inner) -> mkExpr(EYield(inner = replaceOldExpr(inner, counter)), e.span)
    case ESpawn(inner) -> mkExpr(ESpawn(inner = replaceOldExpr(inner, counter)), e.span)
    case ETry(inner) -> mkExpr(ETry(inner = replaceOldExpr(inner, counter)), e.span)
    case EForall(binders, whereOpt, body) -> {
      val newWhere: Option[Expr] = match whereOpt {
        case Some(w) -> Some(value = replaceOldExpr(w, counter))
        case None -> None
      }
      mkExpr(EForall(binders = binders, whereExpr = newWhere, body = replaceOldExpr(body, counter)), e.span)
    }
    case EExists(binders, whereOpt, body) -> {
      val newWhere: Option[Expr] = match whereOpt {
        case Some(w) -> Some(value = replaceOldExpr(w, counter))
        case None -> None
      }
      mkExpr(EExists(binders = binders, whereExpr = newWhere, body = replaceOldExpr(body, counter)), e.span)
    }
    case ELambda(params, body) -> {
      mkExpr(ELambda(lambdaParams = params, body = replaceOldExprBlock(body, counter)), e.span)
    }
    case ECall(fn, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(n, v, sp) -> newArgs.add(CANamed(name = n, value = replaceOldExpr(v, counter), span = sp))
          case CAPositional(v) -> newArgs.add(CAPositional(expr = replaceOldExpr(v, counter)))
        }
        i = i + 1
      }
      mkExpr(ECall(fn = replaceOldExpr(fn, counter), args = newArgs), e.span)
    }
    case ETypeApp(fn, ts) -> mkExpr(ETypeApp(fn = replaceOldExpr(fn, counter), args = ts), e.span)
    case EIndex(recv, indices) -> {
      val newIdx: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        newIdx.add(replaceOldExpr(indices[i], counter))
        i = i + 1
      }
      mkExpr(EIndex(receiver = replaceOldExpr(recv, counter), indices = newIdx), e.span)
    }
    case EMember(recv, mname) -> mkExpr(EMember(receiver = replaceOldExpr(recv, counter), memberName = mname), e.span)
    case EPropagate(inner) -> mkExpr(EPropagate(inner = replaceOldExpr(inner, counter)), e.span)
    case EPrefix(op, x) -> mkExpr(EPrefix(op = op, operand = replaceOldExpr(x, counter)), e.span)
    case EBinop(op, l, r) -> {
      mkExpr(EBinop(op = op, lhs = replaceOldExpr(l, counter), rhs = replaceOldExpr(r, counter)), e.span)
    }
    case ERange(bound) -> mkExpr(ERange(bound = replaceOldExprRange(bound, counter)), e.span)
    case EAssign(t, op, v) -> {
      mkExpr(EAssign(target = replaceOldExpr(t, counter), op = op, value = replaceOldExpr(v, counter)), e.span)
    }
    case EBlock(blk) -> mkExpr(EBlock(block = replaceOldExprBlock(blk, counter)), e.span)
    case EUnsafe(blk) -> mkExpr(EUnsafe(block = replaceOldExprBlock(blk, counter)), e.span)
    case EInterpolated(segs) -> {
      val outs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, sp) -> outs.add(ISText(text = t, span = sp))
          case ISExpr(x) -> outs.add(ISExpr(expr = replaceOldExpr(x, counter)))
        }
        i = i + 1
      }
      mkExpr(EInterpolated(segments = outs), e.span)
    }
  }
}

func replaceOldExprEob(eob: in ExprOrBlock, counter: inout RenameCounter): ExprOrBlock {
  match eob {
    case EOBExpr(x) -> EOBExpr(expr = replaceOldExpr(x, counter))
    case EOBBlock(blk) -> EOBBlock(block = replaceOldExprBlock(blk, counter))
  }
}

func replaceOldExprBlock(blk: in Block, counter: inout RenameCounter): Block {
  val outs: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    outs.add(replaceOldExprStmt(blk.statements[i], counter))
    i = i + 1
  }
  Block(statements = outs, span = blk.span)
}

func replaceOldExprRange(b: in RangeBound, counter: inout RenameCounter): RangeBound {
  match b {
    case RBClosed(lo, hi) -> RBClosed(lo = replaceOldExpr(lo, counter), hi = replaceOldExpr(hi, counter))
    case RBHalfOpen(lo, hi, bareDotDot) -> RBHalfOpen(
      lo = replaceOldExpr(lo, counter),
      hi = replaceOldExpr(hi, counter),
      bareDotDot = bareDotDot
    )
    case RBLowerOpen(hi) -> RBLowerOpen(hi = replaceOldExpr(hi, counter))
    case RBUpperOpen(lo) -> RBUpperOpen(lo = replaceOldExpr(lo, counter))
  }
}

func replaceOldExprStmt(s: in Statement, counter: inout RenameCounter): Statement {
  match s.kind {
    case SReturn(opt) -> {
      match opt {
        case Some(v) -> mkStmt(SReturn(value = Some(value = replaceOldExpr(v, counter))), s.span)
        case None -> s
      }
    }
    case SLocal(binding) -> mkStmt(SLocal(binding = replaceOldExprBinding(binding, counter)), s.span)
    case SAssign(t, op, v) -> {
      mkStmt(SAssign(target = replaceOldExpr(t, counter), op = op, value = replaceOldExpr(v, counter)), s.span)
    }
    case SFor(label, pat, iter, body) -> {
      mkStmt(
        SFor(label = label, pat = pat, iter = replaceOldExpr(iter, counter), body = replaceOldExprBlock(body, counter)),
        s.span
      )
    }
    case SWhile(label, cond, body) -> {
      mkStmt(SWhile(label = label, cond = replaceOldExpr(cond, counter), body = replaceOldExprBlock(body, counter)), s.span)
    }
    case SLoop(label, body) -> mkStmt(SLoop(label = label, body = replaceOldExprBlock(body, counter)), s.span)
    case SInvariant(x) -> mkStmt(SInvariant(expr = replaceOldExpr(x, counter)), s.span)
    case SExpr(x) -> mkStmt(SExpr(expr = replaceOldExpr(x, counter)), s.span)
    case SRule(l, r) -> {
      mkStmt(SRule(lhs = replaceOldExpr(l, counter), rhs = replaceOldExpr(r, counter)), s.span)
    }
    case _ -> s
  }
}

func replaceOldExprBinding(b: in LocalBinding, counter: inout RenameCounter): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = replaceOldExpr(init, counter))
    case LBLet(n, ty, init) -> LBLet(name = n, ty = ty, init = replaceOldExpr(init, counter))
    case LBVar(n, ty, initOpt) -> {
      val newInit: Option[Expr] = match initOpt {
        case Some(x) -> Some(value = replaceOldExpr(x, counter))
        case None -> None
      }
      LBVar(name = n, ty = ty, init = newInit)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Function-body elaboration.
//
//     `elaborateFunctionBody` produces a transformed `Block` with:
//       0. `let __old_N = expr` snapshot bindings for each `old()` in ensures,
//          prepended at function entry before requires asserts;
//       1. one `assert(req)` statement per `CCRequires` clause, prepended
//          in source order;
//       2. each top-level `SReturn(Some(e))` rewritten to
//          `let __lyric_result_<n> = e; <ensures asserts>; return
//          __lyric_result_<n>`;
//       3. each top-level `SReturn(None)` rewritten to `<ensures
//          asserts>; return`;
//       4. the trailing `SExpr(e)` (implicit fall-off) rewritten to
//          `let __lyric_result_<n> = e; <ensures asserts>;
//          __lyric_result_<n>`.
//
//     The clauses in `contracts` are scanned once into separate
//     `requires` / `ensures` lists; non-`requires` / non-`ensures`
//     clauses (`when:` / `decreases:` / `raises:`) are ignored —
//     these aren't run-time-checked by the bootstrap either.
// ─────────────────────────────────────────────────────────────────────────────
// `PreconditionViolated: Std.String.repeat requires count >= 0` — the kind,
// the owning function and the clause text as the formatter renders it.
func violationMessage(kind: in String, owner: in String, keyword: in String, e: in Expr): String {
  kind + ": " + owner + " " + keyword + " " + Fmt.exprInline(0, e)
}

func collectRequires(contracts: in List[ContractClause], owner: in String): List[SpannedExpr] {
  val xs: List[SpannedExpr] = newList()
  var i = 0
  while i < contracts.count {
    match contracts[i] {
      case CCRequires(e, sp) -> xs.add(
        SpannedExpr(
          expr = e,
          span = sp,
          message = violationMessage("PreconditionViolated", owner, "requires", e)
        )
      )
      case _ -> {
      }
    }
    i = i + 1
  }
  xs
}

func collectEnsures(contracts: in List[ContractClause], owner: in String): List[SpannedExpr] {
  val xs: List[SpannedExpr] = newList()
  var i = 0
  while i < contracts.count {
    match contracts[i] {
      case CCEnsures(e, sp) -> xs.add(
        SpannedExpr(
          expr = e,
          span = sp,
          message = violationMessage("PostconditionViolated", owner, "ensures", e)
        )
      )
      case _ -> {
      }
    }
    i = i + 1
  }
  xs
}

// Append `assert(<ensures with result -> name>)` statements for every
// ensures clause to `acc`, each anchored at its own clause's span.
//
// No `sp` parameter: this used to take the enclosing `return` statement's
// span and stamp it on every assert, so a failing `ensures:` reported the
// return site rather than the clause (docs/63 band B1).
func appendEnsuresAsserts(acc: in List[Statement], ensuresExprs: in List[SpannedExpr], resultName: in String): Unit {
  var i = 0
  while i < ensuresExprs.count {
    val ec = ensuresExprs[i]
    val cond = substResult(ec.expr, resultName, newMap())
    acc.add(mkAssertCall(cond, ec.message, ec.span))
    i = i + 1
  }
}

// Variant for `SReturn(None)` and other no-result paths: ensures
// clauses are inserted with `result` substituted by `()` if any clause
// references EResult.  This prevents dangling EResult nodes from reaching
// codegen when the type-checker does not reject `ensures: result == …`
// on a Unit-returning function.  Clauses that do not reference result
// are emitted directly without extra bindings.
// `sp` is retained here, unlike `appendEnsuresAsserts`: it anchors the
// synthetic `__lyric_result_unit` binding, which genuinely belongs to the
// return site rather than to any one clause.  The asserts themselves are
// anchored per clause.
func appendEnsuresAssertsNoResult(acc: in List[Statement], ensuresExprs: in List[SpannedExpr], sp: in Span): Unit {
  if ensuresExprs.count == 0 {
    return
  }
  val needUnit = anyHaveResultSpanned(ensuresExprs)
  val dummyName = "__lyric_result_unit"
  if needUnit {
    acc.add(mkLetBinding(dummyName, mkUnit(sp), sp))
  }
  var i = 0
  while i < ensuresExprs.count {
    val ec = ensuresExprs[i]
    val cond = if needUnit { substResult(ec.expr, dummyName, newMap()) } else { ec.expr }
    acc.add(mkAssertCall(cond, ec.message, ec.span))
    i = i + 1
  }
}

// Rewrite a top-level `SReturn(Some(e))` into:
//   let __lyric_result_<n> = e
//   <ensures asserts>
//   return __lyric_result_<n>
func rewriteReturnSome(
  e: in Expr,
  ensuresExprs: in List[SpannedExpr],
  counter: inout RenameCounter,
  sp: in Span,
  acc: in List[Statement],
): Unit {
  if ensuresExprs.count == 0 {
    acc.add(mkStmt(SReturn(value = Some(value = e)), sp))
    return
  }
  val name = freshResultName(counter)
  acc.add(mkLetBinding(name, e, sp))
  appendEnsuresAsserts(acc, ensuresExprs, name)
  acc.add(mkStmt(SReturn(value = Some(value = mkPath(name, sp))), sp))
}

// Rewrite the trailing `SExpr(e)` of a non-Unit body block into:
//   let __lyric_result_<n> = e
//   <ensures asserts>
//   __lyric_result_<n>
func rewriteTrailingSExpr(
  e: in Expr,
  ensuresExprs: in List[SpannedExpr],
  counter: inout RenameCounter,
  sp: in Span,
  acc: in List[Statement],
  isVoidReturn: in Bool,
): Unit {
  if ensuresExprs.count == 0 {
    // No ensures clauses, but we still need to descend through any
    // nested EIf/EMatch branches so loop invariants buried inside
    // them get lowered (#826: stmtHasInvariant's new SExpr arm now
    // opts a function with no contracts into elaboration when an
    // invariant hides inside an if-block, but the deep-walk has to
    // actually reach the nested SInvariant — `elaborateExprDeep` is
    // the existing rewriter that recurses through EIf/EMatch into
    // the inner blocks).
    val newE = elaborateExprDeep(e, ensuresExprs, counter)
    acc.add(mkStmt(SExpr(expr = newE), sp))
    return
  }
  // For void-returning functions, the trailing expression produces no value,
  // so binding it to a `let` would create a void-typed local that the codegen
  // cannot stloc (nothing on the stack) → InvalidProgramException (#3505).
  // Emit the expression as a plain statement and check ensures without result
  // substitution.  Protected-type invariant ensures are the typical case here:
  // they reference field names, never `result`.
  if isVoidReturn {
    val newE = elaborateExprDeep(e, ensuresExprs, counter)
    acc.add(mkStmt(SExpr(expr = newE), sp))
    appendEnsuresAssertsNoResult(acc, ensuresExprs, sp)
    return
  }
  // The trailing expression may itself be an EMatch / EIf whose arms exit
  // via `return` on every branch (e.g. `match c { case A -> return "a"; ... }`
  // — common in helper functions that prefer per-arm `return` over a single
  // trailing value).  Wrapping such a divergent expression in
  // `let __lyric_result_<n> = <match>` produces invalid IL: the `stloc` has
  // nothing on the stack (every arm `ret`s instead of yielding a value),
  // which the JIT rejects as `InvalidProgramException` (#3842).  Deep-walk
  // first so the nested SReturns are rewritten in place (per-arm let + assert
  // + return); if the resulting expression always exits, emit it directly
  // without the outer let-bind / assert / yield.
  val newE = elaborateExprDeep(e, ensuresExprs, counter)
  if exprAlwaysExits(newE) {
    acc.add(mkStmt(SExpr(expr = newE), sp))
    return
  }
  val name = freshResultName(counter)
  acc.add(mkLetBinding(name, newE, sp))
  appendEnsuresAsserts(acc, ensuresExprs, name)
  acc.add(mkStmt(SExpr(expr = mkPath(name, sp)), sp))
}

// True iff every reachable path through `e` ends in `return` or `throw`.
// Used by `rewriteTrailingSExpr` to skip the let-bind / assert / yield wrap
// for trailing expressions that diverge unconditionally — wrapping them
// emits IL that loads from an unset slot (#3842).
func exprAlwaysExits(e: in Expr): Bool {
  match e.kind {
    case EMatch(_, arms) -> {
      if arms.count == 0 {
        return false
      }
      var i = 0
      while i < arms.count {
        if not exprOrBlockAlwaysExits(arms[i].body) {
          return false
        }
        i = i + 1
      }
      true
    }
    case EIf(_, thenBranch, elseOpt, _) -> {
      match elseOpt {
        case None -> false
        case Some(eb) -> exprOrBlockAlwaysExits(thenBranch) and exprOrBlockAlwaysExits(eb)
      }
    }
    case EBlock(blk) -> blockAlwaysExits(blk)
    case EParen(inner) -> exprAlwaysExits(inner)
    case _ -> false
  }
}

func exprOrBlockAlwaysExits(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(inner) -> exprAlwaysExits(inner)
    case EOBBlock(blk) -> blockAlwaysExits(blk)
  }
}

func blockAlwaysExits(blk: in Block): Bool {
  if blk.statements.count == 0 {
    return false
  }
  val last = blk.statements[blk.statements.count - 1]
  match last.kind {
    case SReturn(_) -> true
    case SThrow(_) -> true
    case SExpr(inner) -> exprAlwaysExits(inner)
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5b. Deep (nested) elaboration.
//
//  `elaborateBlockDeep` / `elaborateStmtDeep` recursively rewrite
//  `SReturn` nodes at any nesting depth inside if-branches, match arms,
//  for/while/loop bodies, and try blocks.  They do NOT rewrite trailing
//  `SExpr` statements (those are only implicit returns at the outermost
//  level; inside an if-branch or loop they are just expression-statement
//  side-effects or the value of the block expression).
// ─────────────────────────────────────────────────────────────────────────────
func elaborateExprOrBlockDeep(
  eob: in ExprOrBlock, ensuresExprs: in List[SpannedExpr], counter: inout RenameCounter
): ExprOrBlock {
  match eob {
    case EOBBlock(body) -> EOBBlock(block = elaborateBlockDeep(body, ensuresExprs, counter))
    case EOBExpr(e) -> EOBExpr(expr = elaborateExprDeep(e, ensuresExprs, counter))
  }
}

func elaborateExprDeep(e: in Expr, ensuresExprs: in List[SpannedExpr], counter: inout RenameCounter): Expr {
  match e.kind {
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      val newThen = elaborateExprOrBlockDeep(thenBranch, ensuresExprs, counter)
      val newElse: Option[ExprOrBlock] = match elseBranch {
        case Some(eob) -> Some(
          value = elaborateExprOrBlockDeep(eob, ensuresExprs, counter)
        )
        case None -> None
      }
      mkExpr(EIf(cond = cond, thenBranch = newThen, elseBranch = newElse, thenForm = thenForm), e.span)
    }
    case EMatch(scrutinee, arms) -> {
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        newArms.add(
          MatchArm(
            pattern = arm.pattern,
            guard = arm.guard,
            body = elaborateExprOrBlockDeep(arm.body, ensuresExprs, counter),
            span = arm.span
          )
        )
        i = i + 1
      }
      mkExpr(EMatch(scrutinee = scrutinee, arms = newArms), e.span)
    }
    // A value-producing block or `unsafe { }` can hold a `return` that exits
    // the enclosing function (#7224).  Lambdas are deliberately not entered:
    // a `return` there leaves the lambda, not the function.
    case EBlock(blk) -> mkExpr(EBlock(block = elaborateBlockDeep(blk, ensuresExprs, counter)), e.span)
    case EUnsafe(blk) -> mkExpr(EUnsafe(block = elaborateBlockDeep(blk, ensuresExprs, counter)), e.span)
    case EParen(inner) -> mkExpr(EParen(inner = elaborateExprDeep(inner, ensuresExprs, counter)), e.span)
    case _ -> e
  }
}

// A `val`/`var`/`let` initializer can hold a `return` inside a `match`/`if`
// expression (`val v = match o { case None -> return 0; ... }`); rewrite it
// so the early return also runs the postconditions (#7224).
func elaborateBindingDeep(
  b: in LocalBinding, ensuresExprs: in List[SpannedExpr], counter: inout RenameCounter
): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = elaborateExprDeep(init, ensuresExprs, counter))
    case LBLet(n, ty, init) -> LBLet(name = n, ty = ty, init = elaborateExprDeep(init, ensuresExprs, counter))
    case LBVar(n, ty, initOpt) -> {
      val newInit: Option[Expr] = match initOpt {
        case Some(x) -> Some(value = elaborateExprDeep(x, ensuresExprs, counter))
        case None -> None
      }
      LBVar(name = n, ty = ty, init = newInit)
    }
  }
}

func elaborateBlockDeep(block: in Block, ensuresExprs: in List[SpannedExpr], counter: inout RenameCounter): Block {
  val outs: List[Statement] = newList()
  var i = 0
  while i < block.statements.count {
    elaborateStmtDeep(block.statements[i], ensuresExprs, counter, outs)
    i = i + 1
  }
  Block(statements = outs, span = block.span)
}

// Recursively rewrite SReturn nodes inside nested blocks, recursing into
// SFor/SWhile/SLoop/STry/SScope bodies and SExpr(EIf)/SExpr(EMatch).
// Does NOT rewrite trailing SExpr (nested trailing exprs are block values,
// not function returns).
func elaborateStmtDeep(
  s: in Statement,
  ensuresExprs: in List[SpannedExpr],
  counter: inout RenameCounter,
  acc: in List[Statement],
): Unit {
  match s.kind {
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> rewriteReturnSome(e, ensuresExprs, counter, s.span, acc)
        case None -> {
          appendEnsuresAssertsNoResult(acc, ensuresExprs, s.span)
          acc.add(s)
        }
      }
    }
    case SExpr(e) -> {
      val newE = elaborateExprDeep(e, ensuresExprs, counter)
      acc.add(mkStmt(SExpr(expr = newE), s.span))
    }
    case SLocal(binding) -> acc.add(
      mkStmt(SLocal(binding = elaborateBindingDeep(binding, ensuresExprs, counter)), s.span)
    )
    case SAssign(target, op, value) -> acc.add(
      mkStmt(
        SAssign(
          target = target,
          op = op,
          value = elaborateExprDeep(value, ensuresExprs, counter)
        ),
        s.span
      )
    )
    case SFor(label, pat, iter, body) -> acc.add(
      mkStmt(
        SFor(
          label = label,
          pat = pat,
          iter = iter,
          body = elaborateBlockDeep(body, ensuresExprs, counter)
        ),
        s.span
      )
    )
    case SWhile(label, cond, body) -> acc.add(
      mkStmt(
        SWhile(
          label = label,
          cond = cond,
          body = elaborateBlockDeep(body, ensuresExprs, counter)
        ),
        s.span
      )
    )
    case SLoop(label, body) -> acc.add(
      mkStmt(
        SLoop(label = label, body = elaborateBlockDeep(body, ensuresExprs, counter)),
        s.span
      )
    )
    case STry(body, catches, finally_) -> {
      val newBody = elaborateBlockDeep(body, ensuresExprs, counter)
      val newCatches: List[CatchClause] = newList()
      var ci = 0
      while ci < catches.count {
        val c = catches[ci]
        newCatches.add(
          CatchClause(
            typeName = c.typeName,
            bindName = c.bindName,
            body = elaborateBlockDeep(c.body, ensuresExprs, counter),
            span = c.span
          )
        )
        ci = ci + 1
      }
      val newFinally = match finally_ {
        case None -> None
        case Some(fb) -> Some(elaborateBlockDeep(fb, ensuresExprs, counter))
      }
      acc.add(mkStmt(STry(body = newBody, catches = newCatches, finally_ = newFinally), s.span))
    }
    case SScope(label, body) -> acc.add(
      mkStmt(
        SScope(binding = label, body = elaborateBlockDeep(body, ensuresExprs, counter)),
        s.span
      )
    )
    case SInvariant(inv) -> acc.add(
      mkAssertCall(inv, "LoopInvariantViolated: invariant " + Fmt.exprInline(0, inv), s.span)
    )
    // Loop `invariant:` (docs/41 §9 Band 4).  We lower to a runtime
    // `assert(inv)` so the check fires at the top of every iteration:
    // the first iteration checks the entry state, and every subsequent
    // iteration checks that the previous body re-established the
    // invariant.  Continue / fall-through both re-enter the loop head,
    // so a single assert at the start of the body covers them; break
    // exits without a check (no postcondition is recovered here).
    case _ -> {
      acc.add(s)
    }
  }
}

// Process a single statement at the top level of the function body.
// `isLast` indicates whether this is the trailing statement of the
// outer function-body block (relevant for implicit fall-off rewriting).
// For non-SReturn, non-last-SExpr statements, delegates to
// `elaborateStmtDeep` to rewrite nested returns inside any inner blocks.
func elaborateTopLevelStmt(
  s: in Statement,
  isLast: in Bool,
  ensuresExprs: in List[SpannedExpr],
  counter: inout RenameCounter,
  acc: in List[Statement],
  isVoidReturn: in Bool,
): Unit {
  match s.kind {
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> rewriteReturnSome(e, ensuresExprs, counter, s.span, acc)
        case None -> {
          appendEnsuresAssertsNoResult(acc, ensuresExprs, s.span)
          acc.add(s)
        }
      }
    }
    case SExpr(e) -> {
      if isLast {
        rewriteTrailingSExpr(e, ensuresExprs, counter, s.span, acc, isVoidReturn)
      } else {
        // Not the trailing expression: recurse into any nested blocks so
        // that returns inside if/match/loop branches are also elaborated.
        val newE = elaborateExprDeep(e, ensuresExprs, counter)
        acc.add(mkStmt(SExpr(expr = newE), s.span))
      }
    }
    case _ -> {
      elaborateStmtDeep(s, ensuresExprs, counter, acc)
    }
  }
}

// True iff any reachable statement inside `fn.body` is an `SInvariant`
// (a loop `invariant:` clause that has been prepended to a loop body by
// `prependLoopInvariants`).  Used to opt the function into elaboration
// when it has no requires / ensures but does need loop-invariant
// lowering.  Walks SWhile / SFor / SLoop / STry / SScope / SDefer
// bodies; nested expression matches (EIf / EMatch / EBlock) cannot
// contain SInvariant because the parser only attaches invariants to
// loops.
func functionBodyHasInvariant(fn: in FunctionDecl): Bool {
  match fn.body {
    case None -> false
    case Some(fb) -> {
      match fb {
        case FBBlock(blk) -> blockHasInvariant(blk)
        case FBExpr(_) -> false
      }
    }
  }
}

func entryBodyHasInvariant(body: in FunctionBody): Bool {
  match body {
    case FBBlock(blk) -> blockHasInvariant(blk)
    case FBExpr(_) -> false
  }
}

func blockHasInvariant(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtHasInvariant(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func stmtHasInvariant(s: in Statement): Bool {
  match s.kind {
    case SInvariant(_) -> true
    case SWhile(_, _, body) -> blockHasInvariant(body)
    case SFor(_, _, _, body) -> blockHasInvariant(body)
    case SLoop(_, body) -> blockHasInvariant(body)
    case SScope(_, body) -> blockHasInvariant(body)
    case SDefer(body) -> blockHasInvariant(body)
    case STry(body, catches, finally_) -> {
      if blockHasInvariant(body) {
        return true
      }
      var i = 0
      while i < catches.count {
        if blockHasInvariant(catches[i].body) {
          return true
        }
        i = i + 1
      }
      match finally_ {
        case None -> false
        case Some(fb) -> blockHasInvariant(fb)
      }
    }
    // #826: statement-level if/match blocks lower to SExpr(EIf|EMatch), so
    // a `while ... invariant:` nested inside an `if` body produces a
    // tree like SExpr(EIf(_, EOBBlock([SWhile(..., SInvariant)]))).
    // Without this case, `functionBodyHasInvariant` returns false and
    // `elaborateFunction` skips the deep walk that would lower
    // SInvariant — the runtime assert is silently dropped.
    case SExpr(e) -> exprHasInvariant(e)
    case _ -> false
  }
}

func exprHasInvariant(e: in Expr): Bool {
  match e.kind {
    case EIf(_, thenBranch, elseOpt, _) -> {
      if exprOrBlockHasInvariant(thenBranch) {
        return true
      }
      match elseOpt {
        case Some(eb) -> exprOrBlockHasInvariant(eb)
        case None -> false
      }
    }
    case EMatch(_, arms) -> {
      var i = 0
      while i < arms.count {
        if exprOrBlockHasInvariant(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EParen(inner) -> exprHasInvariant(inner)
    case _ -> false
  }
}

func exprOrBlockHasInvariant(eb: in ExprOrBlock): Bool {
  match eb {
    case EOBExpr(e) -> exprHasInvariant(e)
    case EOBBlock(blk) -> blockHasInvariant(blk)
  }
}

func elaborateFunctionBody(
  contracts: in List[ContractClause],
  typeInvariants: in List[InvariantClause],
  owner: in String,
  body: in Block,
  counter: inout RenameCounter,
  isVoidReturn: in Bool,
): Block {
  val requiresExprs = collectRequires(contracts, owner)
  val ensuresExprs = collectEnsures(contracts, owner)
  var ti = 0
  while ti < typeInvariants.count {
    val inv = typeInvariants[ti]
    ensuresExprs.add(
      SpannedExpr(
        expr = inv.expr,
        span = inv.span,
        message = violationMessage("InvariantViolated", owner, "invariant", inv.expr)
      )
    )
    ti = ti + 1
  }

  val outs: List[Statement] = newList()

  // (0) Materialise `old()` snapshots.  Collect all `EOld(inner)` inner
  //     expressions from the ensures clauses in traversal order, emit one
  //     `let __old_N = inner` binding per occurrence, then rewrite the
  //     ensures expressions with EOld replaced by `EPath("__old_N")`.
  //     Snapshots are emitted before requires asserts so they capture the
  //     genuine pre-state even when a requires assertion fires first.
  val oldInners: List[Expr] = newList()
  var oei = 0
  while oei < ensuresExprs.count {
    collectOldExpr(ensuresExprs[oei].expr, oldInners)
    oei = oei + 1
  }
  var rewrittenEnsures = ensuresExprs
  if oldInners.count > 0 {
    var oi = 0
    while oi < oldInners.count {
      outs.add(mkLetBinding(freshOldName(oi), oldInners[oi], body.span))
      oi = oi + 1
    }
    val replCounter = newRenameCounter()
    val rewritten: List[SpannedExpr] = newList()
    var rei = 0
    while rei < ensuresExprs.count {
      // `replaceOldExpr` rewrites `EOld` leaves inside the clause expression;
      // the clause's own span is a separate field and passes through unchanged.
      val ec = ensuresExprs[rei]
      rewritten.add(SpannedExpr(expr = replaceOldExpr(ec.expr, replCounter), span = ec.span, message = ec.message))
      rei = rei + 1
    }
    rewrittenEnsures = rewritten
  }

  // (1) Prepend requires asserts, each at its own clause's span rather than
  //     at the body's — a failing `requires:` should report the line the user
  //     wrote it on, not the function's opening brace (docs/63 band B1).
  var ri = 0
  while ri < requiresExprs.count {
    val rc = requiresExprs[ri]
    outs.add(mkAssertCall(rc.expr, rc.message, rc.span))
    ri = ri + 1
  }

  // (2) / (3) / (4): walk top-level statements.
  var si = 0
  while si < body.statements.count {
    val isLast = si == body.statements.count - 1
    elaborateTopLevelStmt(body.statements[si], isLast, rewrittenEnsures, counter, outs, isVoidReturn)
    si = si + 1
  }

  Block(statements = outs, span = body.span)
}

// Wrap an `FBExpr(e)` into a block so the same elaboration pipeline can
// run.  The resulting block contains a single `SExpr(e)` statement; the
// trailing-fall-off case in `elaborateTopLevelStmt` handles the rewrite.
func wrapExprBody(e: in Expr): Block {
  val stmts: List[Statement] = newList()
  stmts.add(mkStmt(SExpr(expr = e), e.span))
  Block(statements = stmts, span = e.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Top-level driver.  `elaborateFunction` rebuilds a FunctionDecl
//     with an elaborated body; `elaborateFile` walks every item and
//     elaborates each `IFunc`.  Other item kinds (records, unions,
//     interfaces, …) are passed through unchanged for now; protected-
//     type entries and interface default methods are picked up in a
//     follow-up stage.
// ─────────────────────────────────────────────────────────────────────────────
// Returns the import alias for `Std.Core` (`import Std.Core as X`) when the
// file declares one.  Used to canonicalize a 2-segment `X.Unit` return-type
// path to the 3-segment `Std.Core.Unit` form `isUnitTypeExpr` recognises,
// without accepting an arbitrary 2-segment `Y.Unit` (which would reintroduce
// the #3636 false positive for a user-defined `Y.Unit` type) — see #4717.
func stdCoreAliasName(imports: in List[ImportDecl]): Option[String] {
  var i = 0
  var found: Option[String] = None
  while i < imports.count {
    val imp = imports[i]
    val segs = imp.path.segments
    if segs.count == 2 and segs[0] == "Std" and segs[1] == "Core" {
      match imp.asAlias {
        case Some(a) -> {
          found = Some(a)
        }
        case None -> {
        }
      }
    }
    i = i + 1
  }
  found
}

func canonicalStdCoreUnitPath(sp: in Span): ModulePath {
  val segs: List[String] = newList()
  segs.add("Std")
  segs.add("Core")
  segs.add("Unit")
  ModulePath(segments = segs, span = sp)
}

// Rewrites a `<aliasName>.Unit` TRef (where `aliasName` resolves to `Std.Core`) into
// the 3-segment `Std.Core.Unit` form.  Recurses through parens; every other
// shape is returned unchanged.
func canonicalizeUnitTypeExpr(te: in TypeExpr, aliasName: in String): TypeExpr {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 2 and path.segments[0] == aliasName and path.segments[1] == "Unit" {
        TypeExpr(kind = TRef(path = canonicalStdCoreUnitPath(path.span)), span = te.span)
      } else {
        te
      }
    }
    case TParen(inner) -> TypeExpr(kind = TParen(inner = canonicalizeUnitTypeExpr(inner, aliasName)), span = te.span)
    case _ -> te
  }
}

func canonicalizeUnitRetOpt(ret: in Option[TypeExpr], aliasName: in String): Option[TypeExpr] {
  match ret {
    case None -> ret
    case Some(te) -> Some(value = canonicalizeUnitTypeExpr(te, aliasName))
  }
}

func canonicalizeUnitAliasesInMember(m: in ProtectedMember, aliasName: in String): ProtectedMember {
  match m {
    case PMEntry(ed) -> PMEntry(
      entryDecl = EntryDecl(
        docComments = ed.docComments,
        annotations = ed.annotations,
        visibility = ed.visibility,
        name = ed.name,
        params = ed.params,
        ret = canonicalizeUnitRetOpt(ed.ret, aliasName),
        contracts = ed.contracts,
        body = ed.body,
        span = ed.span
      )
    )
    case PMFunc(fn) -> PMFunc(
      fn = FunctionDecl(
        docComments = fn.docComments,
        annotations = fn.annotations,
        visibility = fn.visibility,
        isAsync = fn.isAsync,
        name = fn.name,
        generics = fn.generics,
        params = fn.params,
        ret = canonicalizeUnitRetOpt(fn.ret, aliasName),
        whereClause = fn.whereClause,
        contracts = fn.contracts,
        body = fn.body,
        span = fn.span
      )
    )
    case other -> other
  }
}

// #4766: `impl`/`interface` method return types carry the same aliased
// `Std.Core.Unit` shape as top-level funcs and protected entries, so they
// need the same rewrite — mirrors `canonicalizeUnitAliasesInMember`.
func canonicalizeUnitAliasesInImplMember(m: in ImplMember, aliasName: in String): ImplMember {
  match m {
    case IMplFunc(fn) -> IMplFunc(
      fn = FunctionDecl(
        docComments = fn.docComments,
        annotations = fn.annotations,
        visibility = fn.visibility,
        isAsync = fn.isAsync,
        name = fn.name,
        generics = fn.generics,
        params = fn.params,
        ret = canonicalizeUnitRetOpt(fn.ret, aliasName),
        whereClause = fn.whereClause,
        contracts = fn.contracts,
        body = fn.body,
        span = fn.span
      )
    )
    case other -> other
  }
}

func canonicalizeUnitAliasesInInterfaceMember(m: in InterfaceMember, aliasName: in String): InterfaceMember {
  match m {
    case IMSig(sig) -> IMSig(
      sig = FunctionSig(
        docComments = sig.docComments,
        isAsync = sig.isAsync,
        name = sig.name,
        generics = sig.generics,
        params = sig.params,
        ret = canonicalizeUnitRetOpt(sig.ret, aliasName),
        whereClause = sig.whereClause,
        contracts = sig.contracts,
        span = sig.span
      )
    )
    case IMFunc(fn) -> IMFunc(
      fn = FunctionDecl(
        docComments = fn.docComments,
        annotations = fn.annotations,
        visibility = fn.visibility,
        isAsync = fn.isAsync,
        name = fn.name,
        generics = fn.generics,
        params = fn.params,
        ret = canonicalizeUnitRetOpt(fn.ret, aliasName),
        whereClause = fn.whereClause,
        contracts = fn.contracts,
        body = fn.body,
        span = fn.span
      )
    )
    case other -> other
  }
}

func canonicalizeUnitAliasesInItem(it: in Item, aliasName: in String): Item {
  match it.kind {
    case IFunc(fn) -> Item(
      docComments = it.docComments,
      annotations = it.annotations,
      visibility = it.visibility,
      kind = IFunc(
        decl = FunctionDecl(
          docComments = fn.docComments,
          annotations = fn.annotations,
          visibility = fn.visibility,
          isAsync = fn.isAsync,
          name = fn.name,
          generics = fn.generics,
          params = fn.params,
          ret = canonicalizeUnitRetOpt(fn.ret, aliasName),
          whereClause = fn.whereClause,
          contracts = fn.contracts,
          body = fn.body,
          span = fn.span
        )
      ),
      span = it.span
    )
    case IImpl(decl) -> {
      val newMembers: List[ImplMember] = newList()
      var mi = 0
      while mi < decl.members.count {
        newMembers.add(canonicalizeUnitAliasesInImplMember(decl.members[mi], aliasName))
        mi = mi + 1
      }
      Item(
        docComments = it.docComments,
        annotations = it.annotations,
        visibility = it.visibility,
        kind = IImpl(
          decl = ImplDecl(
            generics = decl.generics,
            iface = decl.iface,
            target = decl.target,
            whereClause = decl.whereClause,
            members = newMembers,
            span = decl.span
          )
        ),
        span = it.span
      )
    }
    case IInterface(decl) -> {
      val newMembers: List[InterfaceMember] = newList()
      var mi = 0
      while mi < decl.members.count {
        newMembers.add(canonicalizeUnitAliasesInInterfaceMember(decl.members[mi], aliasName))
        mi = mi + 1
      }
      Item(
        docComments = it.docComments,
        annotations = it.annotations,
        visibility = it.visibility,
        kind = IInterface(
          decl = InterfaceDecl(
            name = decl.name,
            generics = decl.generics,
            whereClause = decl.whereClause,
            members = newMembers,
            span = decl.span
          )
        ),
        span = it.span
      )
    }
    case IProtected(decl) -> {
      val newMembers: List[ProtectedMember] = newList()
      var mi = 0
      while mi < decl.members.count {
        newMembers.add(canonicalizeUnitAliasesInMember(decl.members[mi], aliasName))
        mi = mi + 1
      }
      Item(
        docComments = it.docComments,
        annotations = it.annotations,
        visibility = it.visibility,
        kind = IProtected(
          decl = ProtectedTypeDecl(
            name = decl.name,
            generics = decl.generics,
            whereClause = decl.whereClause,
            members = newMembers,
            span = decl.span
          )
        ),
        span = it.span
      )
    }
    case _ -> it
  }
}

// Pre-pass run at the top of `elaborateFile`, BEFORE any call into
// `elaborateItem` / `elaborateFunction`: canonicalizes every function's
// (and protected entry's) `Std.Core` return-type alias path so
// `isUnitTypeExpr` sees only the two forms it already handles.  Resolving
// the alias here — once, against the file's own import table — means
// `isUnitTypeExpr` / `isVoidReturnOpt` / `elaborateFunction` need no alias
// context threaded into their own signatures.  A no-op (returns `file`
// unchanged) when the file declares no `Std.Core` alias, which is the
// overwhelmingly common case.  (Parameter names in the helpers below use
// `aliasName` rather than the bare word `alias` — `alias` is a Lyric
// soft keyword (`alias X = Type`), and the F# bootstrap parser used for
// the one-time stage-0 mint recovery does not disambiguate it from an
// ordinary identifier in this position, unlike the self-hosted parser.)
func canonicalizeFileUnitAliases(file: in SourceFile): SourceFile {
  match stdCoreAliasName(file.imports) {
    case None -> file
    case Some(aliasName) -> {
      val newItems: List[Item] = newList()
      var i = 0
      while i < file.items.count {
        newItems.add(canonicalizeUnitAliasesInItem(file.items[i], aliasName))
        i = i + 1
      }
      SourceFile(
        moduleDoc = file.moduleDoc,
        fileAnnotations = file.fileAnnotations,
        packageDecl = file.packageDecl,
        imports = file.imports,
        items = newItems,
        span = file.span
      )
    }
  }
}

// True if a type expression denotes the Unit type.  Covers the three
// representations that can appear in a return-type annotation:
//   TUnit       — the empty-tuple syntax `()`
//   TRef("Unit") / TRef("Std.Core.Unit") — unqualified or fully-qualified name
// Parenthesised forms are unwrapped.
func isUnitTypeExpr(te: in TypeExpr): Bool {
  match te.kind {
    case TUnit -> true
    case TRef(path) -> {
      val n = path.segments.count
      if n == 1 {
        path.segments[0] == "Unit"
      } else if n == 3 {
        path.segments[0] == "Std" and path.segments[1] == "Core" and path.segments[2] == "Unit"
      } else {
        false
      }
    }
    case TParen(inner) -> isUnitTypeExpr(inner)
    case _ -> false
  }
}

// True if the return-type option represents a void (Unit) return.  Covers
// both `func foo()` (ret = None) and `func foo(): Unit` (ret = Some(Unit)).
func isVoidReturnOpt(ret: in Option[TypeExpr]): Bool {
  match ret {
    case None -> true
    case Some(te) -> isUnitTypeExpr(te)
  }
}

pub func elaborateFunction(fn: in FunctionDecl): FunctionDecl {
  elaborateFunctionOwned(fn, fn.name)
}

/// `elaborateFunction`, naming the function `owner` in contract-violation
/// messages (e.g. `Std.String.repeat`, `Box.scaled`).
pub func elaborateFunctionOwned(fn: in FunctionDecl, owner: in String): FunctionDecl {
  // @axiom functions have no body — nothing to elaborate.
  if functionIsAxiom(fn) {
    return fn
  }

  // Functions without a body (signatures, externs) — pass through.
  match fn.body {
    case None -> {
      return fn
    }
    case _ -> {
    }
  }

  // No requires / ensures / loop invariants → nothing to do.  Preserve
  // identity of the input record so downstream passes (verifier,
  // contract-meta) see the original FunctionDecl.
  val hasReq = collectRequires(fn.contracts, owner).count > 0
  val hasEns = collectEnsures(fn.contracts, owner).count > 0
  val hasInv = functionBodyHasInvariant(fn)
  if not hasReq and not hasEns and not hasInv {
    return fn
  }

  var counter = newRenameCounter()
  val isVoid = isVoidReturnOpt(fn.ret)
  val newBody: FunctionBody = match fn.body {
    case Some(b) -> match b {
      case FBBlock(blk) -> FBBlock(
        block = elaborateFunctionBody(
          fn.contracts,
          newList(),
          owner,
          blk,
          counter,
          isVoid
        )
      )
      case FBExpr(e) -> FBBlock(
        block = elaborateFunctionBody(
          fn.contracts,
          newList(),
          owner,
          wrapExprBody(e),
          counter,
          isVoid
        )
      )
    }
    case None -> FBExpr(expr = mkExpr(EError, fn.span))
  }
  // unreachable per the early return above

  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = fn.params,
    ret = fn.ret,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = Some(value = newBody),
    span = fn.span
  )
}

func elaborateProtectedMember(
  m: in ProtectedMember, invariants: in List[InvariantClause], typeName: in String
): ProtectedMember {
  match m {
    case PMEntry(ed) -> {
      val owner = typeName + "." + ed.name
      val hasReq = collectRequires(ed.contracts, owner).count > 0
      val hasEns = collectEnsures(ed.contracts, owner).count > 0 or invariants.count > 0
      val hasInv = entryBodyHasInvariant(ed.body)
      if not hasReq and not hasEns and not hasInv {
        m
      } else {
        var counter = newRenameCounter()
        val isVoid = isVoidReturnOpt(ed.ret)
        val newBody: FunctionBody = match ed.body {
          case FBBlock(blk) -> FBBlock(
            block = elaborateFunctionBody(
              ed.contracts,
              invariants,
              owner,
              blk,
              counter,
              isVoid
            )
          )
          case FBExpr(e) -> FBBlock(
            block = elaborateFunctionBody(
              ed.contracts,
              invariants,
              owner,
              wrapExprBody(e),
              counter,
              isVoid
            )
          )
        }
        PMEntry(
          entryDecl = EntryDecl(
            docComments = ed.docComments,
            annotations = ed.annotations,
            visibility = ed.visibility,
            name = ed.name,
            params = ed.params,
            ret = ed.ret,
            contracts = ed.contracts,
            body = newBody,
            span = ed.span
          )
        )
      }
    }
    case PMFunc(fn) -> PMFunc(fn = elaborateFunctionOwned(fn, typeName + "." + fn.name))
    case other -> other
  }
}

// Interface declarations visible to this file, keyed by bare name.  Used to
// give each `impl I for T` method the `requires:`/`ensures:` clauses its
// interface method declares (#7223).  File-local interfaces shadow imported
// ones of the same name.
pub func interfaceTable(file: in SourceFile, imported: in List[InterfaceDecl]): Map[String, InterfaceDecl] {
  val table: Map[String, InterfaceDecl] = newMap()
  var j = 0
  while j < file.items.count {
    match file.items[j].kind {
      case IInterface(decl) -> if not table.containsKey(decl.name) { table.add(decl.name, decl) }
      case _ -> ()
    }
    j = j + 1
  }
  var i = 0
  while i < imported.count {
    if not table.containsKey(imported[i].name) {
      table.add(imported[i].name, imported[i])
    }
    i = i + 1
  }
  table
}

// The contract-bearing parts of an interface member named `name`, or None.
func interfaceMemberContract(iface: in InterfaceDecl, name: in String): Option[FunctionSig] {
  var i = 0
  while i < iface.members.count {
    match iface.members[i] {
      case IMSig(sig) -> if sig.name == name { return Some(value = sig) }
      case IMFunc(fn) -> if fn.name == name {
        return Some(
          value = FunctionSig(
            docComments = fn.docComments,
            isAsync = fn.isAsync,
            name = fn.name,
            generics = fn.generics,
            params = fn.params,
            ret = fn.ret,
            whereClause = fn.whereClause,
            contracts = fn.contracts,
            span = fn.span
          )
        )
      }
      case IMAssoc(_) -> ()
    }
    i = i + 1
  }
  None
}

// Interface `requires:`/`ensures:` clauses rewritten into the implementing
// method's parameter names.  Composition is additive, as for aspects
// (docs/01 §6.1.1): the impl is checked against the interface clauses AND
// its own.  A signature whose arity differs from the impl's is not the
// method being implemented (the type checker reports that separately), so
// nothing is inherited from it.
func inheritedClauses(sig: in FunctionSig, fn: in FunctionDecl): List[ContractClause] {
  val acc: List[ContractClause] = newList()
  if sig.params.count != fn.params.count {
    return acc
  }
  val renames: Map[String, String] = newMap()
  var i = 0
  while i < sig.params.count {
    if sig.params[i].name != fn.params[i].name {
      renames.add(sig.params[i].name, fn.params[i].name)
    }
    i = i + 1
  }
  var c = 0
  while c < sig.contracts.count {
    match sig.contracts[c] {
      case CCRequires(x, sp) -> acc.add(CCRequires(expr = substResult(x, "", renames), span = sp))
      case CCEnsures(x, sp) -> acc.add(CCEnsures(expr = substResult(x, "", renames), span = sp))
      case _ -> ()
    }
    c = c + 1
  }
  acc
}

// Elaborate `fn` with `extra` clauses prepended to its own, then restore the
// source-level clause list so contract metadata and the verifier see only
// what the author wrote on this declaration.
func elaborateFunctionWith(fn: in FunctionDecl, extra: in List[ContractClause], owner: in String): FunctionDecl {
  if extra.count == 0 {
    return elaborateFunctionOwned(fn, owner)
  }
  val merged: List[ContractClause] = newList()
  var i = 0
  while i < extra.count {
    merged.add(extra[i])
    i = i + 1
  }
  var j = 0
  while j < fn.contracts.count {
    merged.add(fn.contracts[j])
    j = j + 1
  }
  val acc = elaborateFunctionOwned(withContracts(fn, merged), owner)
  withContracts(acc, fn.contracts)
}

func withContracts(fn: in FunctionDecl, contracts: in List[ContractClause]): FunctionDecl {
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = fn.params,
    ret = fn.ret,
    whereClause = fn.whereClause,
    contracts = contracts,
    body = fn.body,
    span = fn.span
  )
}

// `pkg.name`, or `name` when the file declares no package.
func qualify(pkg: in String, name: in String): String {
  if pkg.length == 0 {
    name
  } else {
    pkg + "." + name
  }
}

func elaborateRecordDecl(decl: in RecordDecl, pkg: in String): RecordDecl {
  val members: List[RecordMember] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> members.add(RMFunc(fn = elaborateFunctionOwned(fn, qualify(pkg, decl.name + "." + fn.name))))
      case other -> members.add(other)
    }
    i = i + 1
  }
  RecordDecl(
    name = decl.name,
    generics = decl.generics,
    whereClause = decl.whereClause,
    members = members,
    span = decl.span
  )
}

func elaborateImplDecl(decl: in ImplDecl, ifaces: in Map[String, InterfaceDecl], pkg: in String): ImplDecl {
  val segs = decl.iface.head.segments
  val ifaceOpt: Option[InterfaceDecl] = if segs.count == 0 { None } else { mapGet(ifaces, segs[segs.count - 1]) }
  val members: List[ImplMember] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMplFunc(fn) -> {
        val extra: List[ContractClause] = match ifaceOpt {
          case Some(iface) -> match interfaceMemberContract(iface, fn.name) {
            case Some(sig) -> inheritedClauses(sig, fn)
            case None -> newList()
          }
          case None -> newList()
        }
        members.add(IMplFunc(fn = elaborateFunctionWith(fn, extra, qualify(pkg, Fmt.typeStr(decl.target) + "." + fn.name))))
      }
      case other -> members.add(other)
    }
    i = i + 1
  }
  ImplDecl(
    generics = decl.generics,
    iface = decl.iface,
    target = decl.target,
    whereClause = decl.whereClause,
    members = members,
    span = decl.span
  )
}

func withKind(it: in Item, kind: in ItemKind): Item {
  Item(
    docComments = it.docComments,
    annotations = it.annotations,
    visibility = it.visibility,
    kind = kind,
    span = it.span
  )
}

func elaborateItem(it: in Item, ifaces: in Map[String, InterfaceDecl], pkg: in String): Item {
  match it.kind {
    case IRecord(decl) -> withKind(it, IRecord(decl = elaborateRecordDecl(decl, pkg)))
    case IExposedRec(decl) -> withKind(it, IExposedRec(decl = elaborateRecordDecl(decl, pkg)))
    case IImpl(decl) -> withKind(it, IImpl(decl = elaborateImplDecl(decl, ifaces, pkg)))
    case IFunc(fn) -> Item(
      docComments = it.docComments,
      annotations = it.annotations,
      visibility = it.visibility,
      kind = IFunc(decl = elaborateFunctionOwned(fn, qualify(pkg, fn.name))),
      span = it.span
    )
    case IProtected(decl) -> {
      val invariants: List[InvariantClause] = newList()
      var mi = 0
      while mi < decl.members.count {
        match decl.members[mi] {
          case PMInvariant(inv) -> invariants.add(inv)
          case _ -> {
          }
        }
        mi = mi + 1
      }
      val newMembers: List[ProtectedMember] = newList()
      mi = 0
      while mi < decl.members.count {
        newMembers.add(elaborateProtectedMember(decl.members[mi], invariants, qualify(pkg, decl.name)))
        mi = mi + 1
      }
      Item(
        docComments = it.docComments,
        annotations = it.annotations,
        visibility = it.visibility,
        kind = IProtected(
          decl = ProtectedTypeDecl(
            name = decl.name,
            generics = decl.generics,
            whereClause = decl.whereClause,
            members = newMembers,
            span = decl.span
          )
        ),
        span = it.span
      )
    }
    case _ -> it
  }
}

pub func elaborateFile(file: in SourceFile): SourceFile {
  elaborateFileWithInterfaces(file, newList())
}

/// `elaborateFile`, additionally resolving `impl` blocks against interfaces
/// declared in other packages (`importedIfaces`) so their method contracts
/// are enforced on the implementation (#7223).
pub func elaborateFileWithInterfaces(file: in SourceFile, importedIfaces: in List[InterfaceDecl]): SourceFile {
  val canonFile = canonicalizeFileUnitAliases(file)
  val ifaces = interfaceTable(canonFile, importedIfaces)
  val newItems: List[Item] = newList()
  val isProofRequired = fileIsProofRequired(canonFile)
  var i = 0
  while i < canonFile.items.count {
    if isProofRequired {
      // @proof_required files: contract clauses are SMT obligations for `lyric prove`,
      // not runtime assertions.  Reconstruct Item wrappers without calling
      // elaborateFunction so no runtime assert() calls are injected.
      // The verifier reads the original clauses from fn.contracts unchanged.
      val it = canonFile.items[i]
      match it.kind {
        case IFunc(fn) -> newItems.add(
          Item(
            docComments = it.docComments,
            annotations = it.annotations,
            visibility = it.visibility,
            kind = IFunc(decl = fn),
            span = it.span
          )
        )
        case _ -> newItems.add(it)
      }
    } else {
      newItems.add(elaborateItem(canonFile.items[i], ifaces, Fmt.pathStr(canonFile.packageDecl.path)))
    }
    i = i + 1
  }
  SourceFile(
    moduleDoc = canonFile.moduleDoc,
    fileAnnotations = canonFile.fileAnnotations,
    packageDecl = canonFile.packageDecl,
    imports = canonFile.imports,
    items = newItems,
    span = canonFile.span
  )
}
