//! typechecker_definite.l — definite assignment for variables with no valid
//! default value (#8226).
//!
//! A `var` declared without an initializer holds its type's zero value until
//! it is assigned.  For a range type whose range excludes zero
//! (`Int range 5 ..= 10`) or a named range type (`type R = Int range 5 ..= 10`)
//! that value lies outside the type, so reading the variable before it has
//! been assigned on every path is a compile error (T0191) instead of
//! observing an out-of-range value (or a null on `--target dotnet`).
//!
//! The analysis is a forward walk in evaluation order.  `assigned` is true
//! once every path reaching the current point has assigned the variable; a
//! path that ends (`return`, `break`, `continue`, `throw`, `panic`) counts as
//! assigned so it never weakens a join.  A bare variable passed to a call
//! counts as an assignment when the callee's parameter is `out`, and when the
//! callee cannot be resolved by name (a method call) it is assumed to be an
//! `out` argument rather than a read.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

record DaCtx {
  name: String
  typeText: String
  tbl: SymbolTable
  sigs: Map[String, ResolvedSignature]
  diag: List[Diagnostic]
  // One entry per enclosing loop: 2 = no `break` seen, 1 = every `break` so
  // far had the variable assigned, 0 = some `break` did not.
  breaks: List[Int]
  reported: List[Bool]
}

func zeroInRangeBound(tbl: in SymbolTable, rb: in RangeBound): Bool {
  match rb {
    case RBClosed(lo, hi) -> boundLe(tbl, lo, 0.0, true) and boundGe(tbl, hi, 0.0, true)
    case RBHalfOpen(lo, hi, _) -> boundLe(tbl, lo, 0.0, true) and boundGe(tbl, hi, 0.0, false)
    case RBLowerOpen(hi) -> boundGe(tbl, hi, 0.0, true)
    case RBUpperOpen(lo) -> boundLe(tbl, lo, 0.0, true)
  }
}

func foldBoundValue(tbl: in SymbolTable, e: in Expr): Option[Double] {
  match tryFoldInt(tbl, e) {
    case FoldOk(v) -> Some(value = v.toDouble())
    case FoldErr(_) -> tryFoldFloat(e)
  }
}

func boundLe(tbl: in SymbolTable, e: in Expr, x: in Double, inclusive: in Bool): Bool {
  match foldBoundValue(tbl, e) {
    case Some(v) -> if inclusive { v <= x } else { v < x }
    case None -> false
  }
}

func boundGe(tbl: in SymbolTable, e: in Expr, x: in Double, inclusive: in Bool): Bool {
  match foldBoundValue(tbl, e) {
    case Some(v) -> if inclusive { v >= x } else { v > x }
    case None -> false
  }
}

func distinctRangeDeclOf(tbl: in SymbolTable, t: in Type): Option[DistinctTypeDecl] {
  val tid = match t { case TyUser(id, _, _) -> id; case _ -> return None }
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKDistinctType(did, dt) -> if typeIdEq(did, tid) {
        match dt.rangeClause {
          case Some(_) -> return Some(value = dt)
          case None -> return None
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

// True when `t` has a value the zero default does not satisfy.
func typeNeedsAssignment(tbl: in SymbolTable, t: in Type): Bool {
  match t {
    case TyRefined(_, _, _, _, src) -> match src.kind {
      case TRefined(_, rb) -> not zeroInRangeBound(tbl, rb)
      case _ -> false
    }
    case TyUser(_, _, _) -> match distinctRangeDeclOf(tbl, t) { case Some(_) -> true; case None -> false }
    case _ -> false
  }
}

// ─── Entry point ─────────────────────────────────────────────────────────────
pub func checkDefiniteAssignment(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  genericNames: in List[String],
  body: in Option[FunctionBody],
): Unit {
  match body {
    case None -> ()
    case Some(b) -> match b {
      case FBBlock(blk) -> findDeclsBlock(tbl, sigs, diag, genericNames, blk)
      case FBExpr(e) -> findDeclsExpr(tbl, sigs, diag, genericNames, e)
    }
  }
}

func findDeclsBlock(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  gnames: in List[String],
  blk: in Block,
): Unit {
  var i = 0
  while i < blk.statements.count {
    val st = blk.statements[i]
    match st.kind {
      case SLocal(lb) -> match lb {
        case LBVar(name, tyOpt, initOpt) -> {
          match initOpt {
            case Some(ie) -> findDeclsExpr(tbl, sigs, diag, gnames, ie)
            case None -> match tyOpt {
              case Some(te) -> {
                val ctx = newGenericContext()
                gctxPush(ctx, gnames)
                val scratch: List[Diagnostic] = newList()
                val declT = resolveType(tbl, ctx, scratch, te)
                if typeNeedsAssignment(tbl, declT) {
                  val dc = DaCtx(
                    name = name,
                    typeText = renderTypeExpr(te, declT),
                    tbl = tbl,
                    sigs = sigs,
                    diag = diag,
                    breaks = newList(),
                    reported = newList()
                  )
                  val _ = daStmts(dc, blk.statements, i + 1, false)
                }
              }
              case None -> ()
            }
          }
        }
        case LBVal(_, _, ie) -> findDeclsExpr(tbl, sigs, diag, gnames, ie)
        case LBLet(_, _, ie) -> findDeclsExpr(tbl, sigs, diag, gnames, ie)
      }
      case SAssign(t, _, v) -> {
        findDeclsExpr(tbl, sigs, diag, gnames, t)
        findDeclsExpr(tbl, sigs, diag, gnames, v)
      }
      case SReturn(vo) -> match vo { case Some(v) -> findDeclsExpr(tbl, sigs, diag, gnames, v); case None -> () }
      case SThrow(e) -> findDeclsExpr(tbl, sigs, diag, gnames, e)
      case STry(b, catches, fin) -> {
        findDeclsBlock(tbl, sigs, diag, gnames, b)
        for c in catches {
          findDeclsBlock(tbl, sigs, diag, gnames, c.body)
        }
        match fin {
          case Some(f) -> findDeclsBlock(tbl, sigs, diag, gnames, f)
          case None -> ()
        }
      }
      case SDefer(b) -> findDeclsBlock(tbl, sigs, diag, gnames, b)
      case SScope(_, b) -> findDeclsBlock(tbl, sigs, diag, gnames, b)
      case SFor(_, _, it, b) -> {
        findDeclsExpr(tbl, sigs, diag, gnames, it)
        findDeclsBlock(tbl, sigs, diag, gnames, b)
      }
      case SWhile(_, c, b) -> {
        findDeclsExpr(tbl, sigs, diag, gnames, c)
        findDeclsBlock(tbl, sigs, diag, gnames, b)
      }
      case SLoop(_, b) -> findDeclsBlock(tbl, sigs, diag, gnames, b)
      case SExpr(e) -> findDeclsExpr(tbl, sigs, diag, gnames, e)
      case _ -> ()
    }
    i = i + 1
  }
}

func findDeclsExpr(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  gnames: in List[String],
  e: in Expr,
): Unit {
  val kids: List[Expr] = newList()
  val blocks: List[Block] = newList()
  exprKids(e, kids, blocks)
  for k in kids {
    findDeclsExpr(tbl, sigs, diag, gnames, k)
  }
  for b in blocks {
    findDeclsBlock(tbl, sigs, diag, gnames, b)
  }
}

// The direct sub-expressions and sub-blocks of `e`, in evaluation order for
// the expressions.  Quantifier bodies are contract text, not run code, so
// they are not children.
func exprKids(e: in Expr, kids: in List[Expr], blocks: in List[Block]): Unit {
  match e.kind {
    case EInterpolated(segs) -> {
      for s in segs {
        match s {
          case ISExpr(x) -> kids.add(x)
          case ISText(_, _) -> ()
        }
      }
    }
    case EParen(x) -> kids.add(x)
    case ETuple(xs) -> {
      for x in xs {
        kids.add(x)
      }
    }
    case EList(xs) -> {
      for x in xs {
        kids.add(x)
      }
    }
    case EIf(c, t, el, _) -> {
      kids.add(c)
      eobKids(t, kids, blocks)
      match el {
        case Some(x) -> eobKids(x, kids, blocks)
        case None -> ()
      }
    }
    case EMatch(s, arms) -> {
      kids.add(s)
      for a in arms {
        match a.guard {
          case Some(g) -> kids.add(g)
          case None -> ()
        }
        eobKids(a.body, kids, blocks)
      }
    }
    case EAwait(x) -> kids.add(x)
    case EYield(x) -> kids.add(x)
    case ESpawn(x) -> kids.add(x)
    case ETry(x) -> kids.add(x)
    case EPropagate(x) -> kids.add(x)
    case ELambda(_, b) -> blocks.add(b)
    case ECall(f, args) -> {
      kids.add(f)
      for a in args {
        kids.add(callArgValue(a))
      }
    }
    case ETypeApp(f, _) -> kids.add(f)
    case EIndex(r, idx) -> {
      kids.add(r)
      for x in idx {
        kids.add(x)
      }
    }
    case EMember(r, _) -> kids.add(r)
    case EPrefix(_, x) -> kids.add(x)
    case EBinop(_, l, r) -> {
      kids.add(l)
      kids.add(r)
    }
    case ERange(rb) -> match rb {
      case RBClosed(lo, hi) -> {
        kids.add(lo)
        kids.add(hi)
      }
      case RBHalfOpen(lo, hi, _) -> {
        kids.add(lo)
        kids.add(hi)
      }
      case RBLowerOpen(hi) -> kids.add(hi)
      case RBUpperOpen(lo) -> kids.add(lo)
    }
    case EAssign(t, _, v) -> {
      kids.add(t)
      kids.add(v)
    }
    case EBlock(b) -> blocks.add(b)
    case EUnsafe(b) -> blocks.add(b)
    case _ -> ()
  }
}

func eobKids(eob: in ExprOrBlock, kids: in List[Expr], blocks: in List[Block]): Unit {
  match eob {
    case EOBExpr(x) -> kids.add(x)
    case EOBBlock(b) -> blocks.add(b)
  }
}

func callArgValue(a: in CallArg): Expr {
  match a {
    case CAPositional(x) -> x
    case CANamed(_, x, _) -> x
  }
}

// ─── The walk ────────────────────────────────────────────────────────────────
func daReport(dc: in DaCtx, sp: in Span): Unit {
  if dc.reported.count > 0 {
    return
  }
  dc.reported.add(true)
  dc.diag.add(
    errorDiagnostic(
      "T0191",
      "variable '" + dc.name + "' of type " + dc.typeText +
        " may be read before it is assigned: the type has no valid default value, so assign it on every path first",
      sp
    )
  )
}

func daPatBinds(p: in Pattern, name: in String): Bool {
  match p.kind {
    case PBinding(n, inner) -> {
      if n == name {
        return true
      }
      match inner {
        case Some(ip) -> daPatBinds(ip, name)
        case None -> false
      }
    }
    case PConstructor(_, args) -> {
      for a in args {
        if daPatBinds(a, name) {
          return true
        }
      }
      false
    }
    case PRecord(_, fields, _) -> {
      for f in fields {
        match f {
          case RPFNamed(_, fp, _) -> if daPatBinds(fp, name) { return true }
          case RPFShort(n, _) -> if n == name { return true }
        }
      }
      false
    }
    case PTuple(ps) -> {
      for a in ps {
        if daPatBinds(a, name) {
          return true
        }
      }
      false
    }
    case PParen(ip) -> daPatBinds(ip, name)
    case PTypeTest(ip, _) -> daPatBinds(ip, name)
    case POr(ps) -> {
      for a in ps {
        if daPatBinds(a, name) {
          return true
        }
      }
      false
    }
    case _ -> false
  }
}

func daIsName(dc: in DaCtx, e: in Expr): Bool {
  match e.kind {
    case EParen(x) -> daIsName(dc, x)
    case EPath(path) -> path.segments.count == 1 and path.segments[0] == dc.name
    case _ -> false
  }
}

func daStmts(dc: in DaCtx, stmts: in List[Statement], from: in Int, assigned0: in Bool): Bool {
  var assigned = assigned0
  var i = from
  while i < stmts.count {
    assigned = daStmt(dc, stmts[i], assigned)
    i = i + 1
  }
  assigned
}

func daBlock(dc: in DaCtx, b: in Block, assigned: in Bool): Bool {
  daStmts(dc, b.statements, 0, assigned)
}

func daEob(dc: in DaCtx, eob: in ExprOrBlock, assigned: in Bool): Bool {
  match eob {
    case EOBExpr(x) -> daExpr(dc, x, assigned)
    case EOBBlock(b) -> daBlock(dc, b, assigned)
  }
}

func daNoteBreak(dc: in DaCtx, labelled: in Bool, assigned: in Bool): Unit {
  var i = dc.breaks.count - 1
  while i >= 0 {
    val cur = dc.breaks[i]
    val next = if assigned and not labelled { if cur == 2 { 1 } else { cur } } else { 0 }
    dc.breaks[i] = next
    if not labelled {
      return
    }
    i = i - 1
  }
}

func daStmt(dc: in DaCtx, st: in Statement, assigned: in Bool): Bool {
  match st.kind {
    case SLocal(lb) -> match lb {
      case LBVal(pat, _, ie) -> {
        val a = daExpr(dc, ie, assigned)
        if daPatBinds(pat, dc.name) {
          true
        } else {
          a
        }
      }
      case LBVar(n, _, io) -> {
        val a = match io { case Some(ie) -> daExpr(dc, ie, assigned); case None -> assigned }
        if n == dc.name {
          true
        } else {
          a
        }
      }
      case LBLet(n, _, ie) -> {
        val a = daExpr(dc, ie, assigned)
        if n == dc.name {
          true
        } else {
          a
        }
      }
    }
    case SAssign(t, op, v) -> daAssign(dc, t, op, v, assigned)
    case SReturn(vo) -> {
      match vo {
        case Some(v) -> {
          val _ = daExpr(dc, v, assigned)
        }
        case None -> ()
      }
      true
    }
    case SBreak(label) -> {
      daNoteBreak(dc, label.isSome, assigned)
      true
    }
    case SContinue(_) -> true
    case SThrow(e) -> {
      val _ = daExpr(dc, e, assigned)
      true
    }
    case STry(body, catches, fin) -> {
      var all = daBlock(dc, body, assigned)
      for c in catches {
        val shadows = match c.bindName { case Some(n) -> n == dc.name; case None -> false }
        val ca = if shadows { true } else { daBlock(dc, c.body, assigned) }
        all = all and ca
      }
      match fin {
        case Some(f) -> {
          val fa = daBlock(dc, f, assigned)
          all or fa
        }
        case None -> all
      }
    }
    case SDefer(_) -> assigned
    case SScope(_, body) -> daBlock(dc, body, assigned)
    case SFor(_, pat, it, body) -> {
      val a = daExpr(dc, it, assigned)
      if not daPatBinds(pat, dc.name) {
        dc.breaks.add(2)
        val _ = daBlock(dc, body, a)
        dc.breaks.removeAt(dc.breaks.count - 1)
      }
      a
    }
    case SWhile(_, c, body) -> {
      val a = daExpr(dc, c, assigned)
      dc.breaks.add(2)
      val _ = daBlock(dc, body, a)
      dc.breaks.removeAt(dc.breaks.count - 1)
      a
    }
    case SLoop(_, body) -> {
      dc.breaks.add(2)
      val _ = daBlock(dc, body, assigned)
      val state = dc.breaks[dc.breaks.count - 1]
      dc.breaks.removeAt(dc.breaks.count - 1)
      if state == 2 {
        true
      } else {
        state == 1
      }
    }
    case SExpr(e) -> daExpr(dc, e, assigned)
    case _ -> assigned
  }
}

func daAssign(dc: in DaCtx, t: in Expr, op: in AssignOp, v: in Expr, assigned: in Bool): Bool {
  val isPlain = match op { case AssEq -> true; case _ -> false }
  if daIsName(dc, t) {
    val a = daExpr(dc, v, assigned)
    if isPlain {
      return true
    }
    if not a {
      daReport(dc, t.span)
    }
    return a
  }
  val a1 = daExpr(dc, t, assigned)
  daExpr(dc, v, a1)
}

func daCalleeParamMode(
  dc: in DaCtx, fn: in Expr, arity: in Int, idx: in Int, argName: in Option[String]
): Option[ParamMode] {
  val fname = match fn.kind {
    case EPath(path) -> if path.segments.count == 1 { path.segments[0] } else { return None }
    case _ -> return None
  }
  val sig = match mapGet(dc.sigs, fname + "/" + toString(arity)) {
    case Some(s) -> s
    case None -> match mapGet(dc.sigs, fname) { case Some(s2) -> s2; case None -> return None }
  }
  match argName {
    case Some(an) -> {
      var k = 0
      while k < sig.params.count {
        if sig.params[k].name == an {
          return Some(value = sig.params[k].mode)
        }
        k = k + 1
      }
      None
    }
    case None -> if idx < sig.params.count { Some(value = sig.params[idx].mode) } else { None }
  }
}

func daExpr(dc: in DaCtx, e: in Expr, assigned: in Bool): Bool {
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 1 and path.segments[0] == dc.name and not assigned {
        daReport(dc, e.span)
      }
      assigned
    }
    case EAssign(t, op, v) -> daAssign(dc, t, op, v, assigned)
    case EIf(c, t, el, _) -> {
      val a = daExpr(dc, c, assigned)
      val ta = daEob(dc, t, a)
      val ea = match el { case Some(x) -> daEob(dc, x, a); case None -> a }
      ta and ea
    }
    case EMatch(s, arms) -> {
      val a = daExpr(dc, s, assigned)
      var all = true
      var any = false
      for arm in arms {
        any = true
        if daPatBinds(arm.pattern, dc.name) {
          continue
        }
        val ga = match arm.guard { case Some(g) -> daExpr(dc, g, a); case None -> a }
        all = all and daEob(dc, arm.body, ga)
      }
      if any {
        all
      } else {
        a
      }
    }
    case ELambda(params, body) -> {
      var shadows = false
      for p in params {
        if p.name == dc.name {
          shadows = true
        }
      }
      if not shadows {
        val saved = dc.breaks.count
        val _ = daBlock(dc, body, assigned)
        while dc.breaks.count > saved {
          dc.breaks.removeAt(dc.breaks.count - 1)
        }
      }
      assigned
    }
    case EBlock(b) -> daBlock(dc, b, assigned)
    case EUnsafe(b) -> daBlock(dc, b, assigned)
    case EBinop(op, l, r) -> {
      val la = daExpr(dc, l, assigned)
      val shortCircuits = match op {
        case BAnd -> true
        case BOr -> true
        case BImplies -> true
        case BCoalesce -> true
        case _ -> false
      }
      if shortCircuits {
        val _ = daExpr(dc, r, la)
        la
      } else {
        daExpr(dc, r, la)
      }
    }
    case ECall(f, args) -> daCall(dc, e, f, args, assigned)
    case EForall(_, _, _, _) -> assigned
    case EExists(_, _, _, _) -> assigned
    case EOld(_) -> assigned
    case _ -> {
      val kids: List[Expr] = newList()
      val blocks: List[Block] = newList()
      exprKids(e, kids, blocks)
      var a = assigned
      for k in kids {
        a = daExpr(dc, k, a)
      }
      a
    }
  }
}

func daCall(dc: in DaCtx, e: in Expr, f: in Expr, args: in List[CallArg], assigned: in Bool): Bool {
  var a = daExpr(dc, f, assigned)
  var idx = 0
  for arg in args {
    val name = match arg { case CANamed(n, _, _) -> Some(value = n); case CAPositional(_) -> None }
    val value = callArgValue(arg)
    if daIsName(dc, value) {
      val isMethod = match f.kind { case EMember(_, _) -> true; case _ -> false }
      match daCalleeParamMode(dc, f, args.count, idx, name) {
        case Some(mode) -> match mode { case PMOut -> { a = true }; case _ -> { if not a { daReport(dc, value.span) } } }
        case None -> if isMethod { a = true } else if not a { daReport(dc, value.span) }
      }
    } else {
      a = daExpr(dc, value, a)
    }
    idx = idx + 1
  }
  val diverges = match f.kind {
    case EPath(path) -> path.segments.count == 1 and path.segments[0] == "panic"
    case _ -> false
  }
  if diverges {
    true
  } else {
    a
  }
}
