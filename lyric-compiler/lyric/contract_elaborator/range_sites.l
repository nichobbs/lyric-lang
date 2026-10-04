//! Range checks at the positions the type checker records (#8031).
//!
//! `insertRangeChecks` checks an inline range type (`Int range 0 ..= 3`) on
//! a function parameter, a return, a binding and a `var` assignment.  A value
//! reaching a range type anywhere else -- a record or union field, a `.copy`
//! argument, a field or element assignment, a collection element, an argument
//! through a function value or to a type parameter instantiated with a range --
//! is recorded by the checker (`SymbolTable.rangeCheckSites`, keyed by the
//! value's span) and wrapped here in a call to a synthesized checker:
//!
//!   func __lyric_range_<n>(v: in Int): Int {
//!     assert(v >= 0 and v <= 3, "RangeViolated: R field i must be in Int range 0 ..= 3")
//!     v
//!   }
//!
//! A compound assignment to a range-refined field or element
//! (`rangeCompoundSites`, keyed by the assignment's span) becomes a plain one
//! whose value is checked: `r.f += 1` is `r.f = __lyric_range_<n>(r.f + 1)`.
//! An `Int` or `Long` range uses the bounds the checker folded, so a range
//! declared in another package with a named constant needs no access to it.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Fmt as Fmt

record RangeHelpers {
  names: Map[String, String]
  items: List[Item]
}

/// Wrap every value the type checker recorded in `valueSites`, rewrite every
/// compound assignment in `compoundSites`, and append the checkers they call.
pub func insertRangeSiteChecks(
  file: in SourceFile,
  valueSites: in Map[String, RangeCheckSite],
  compoundSites: in Map[String, RangeCheckSite],
): SourceFile {
  if valueSites.count == 0 and compoundSites.count == 0 {
    return file
  }
  val helpers = RangeHelpers(names = newMap(), items = newList())
  val mapped = mapFileAndContracts(
    file,
    { e: Expr -> rangeSiteExpr(e, valueSites, compoundSites, helpers) },
    { s: Statement -> rangeSiteStmt(s, compoundSites, helpers) }
  )
  val items: List[Item] = newList()
  for it in mapped.items {
    items.add(it)
  }
  for it in helpers.items {
    items.add(it)
  }
  mapped.copy(items = items)
}

func rangeSiteExpr(
  e: in Expr,
  valueSites: in Map[String, RangeCheckSite],
  compoundSites: in Map[String, RangeCheckSite],
  helpers: in RangeHelpers,
): Expr {
  match e.kind {
    case EAssign(target, op, value) -> match compoundRewrite(target, op, value, e.span, compoundSites, helpers) {
      case Some(newValue) -> return mkExpr(EAssign(target = target, op = AssEq, value = newValue), e.span)
      case None -> ()
    }
    case _ -> ()
  }
  match mapGet(valueSites, recordCopySiteKey(e.span)) {
    case Some(site) -> wrapRangeCheck(e, site, helpers)
    case None -> e
  }
}

func rangeSiteStmt(s: in Statement, compoundSites: in Map[String, RangeCheckSite], helpers: in RangeHelpers): Statement {
  match s.kind {
    case SAssign(target, op, value) -> match compoundRewrite(target, op, value, s.span, compoundSites, helpers) {
      case Some(newValue) -> Statement(
        kind = SAssign(
          target = target,
          op = AssEq,
          value = newValue
        ),
        span = s.span
      )
      case None -> s
    }
    case _ -> s
  }
}

// `t op= v` at a recorded compound site: the checked `t op v`.
func compoundRewrite(
  target: in Expr,
  op: in AssignOp,
  value: in Expr,
  sp: in Span,
  compoundSites: in Map[String, RangeCheckSite],
  helpers: in RangeHelpers,
): Option[Expr] {
  val site = match mapGet(compoundSites, recordCopySiteKey(sp)) { case Some(st) -> st; case None -> return None }
  // The overflow pass may already have spelled `t op= v` as `t = t op v`.
  val bop = match op {
    case AssEq -> return Some(value = wrapRangeCheck(value, site, helpers))
    case AssPlus -> BAdd
    case AssMinus -> BSub
    case AssStar -> BMul
    case AssSlash -> BDiv
    case AssPercent -> BMod
  }
  // Zero-width span: the operator must not share the assignment's key.
  val opSpan = Span(startPos = sp.startPos, endPos = sp.startPos)
  val combined = mkExpr(EBinop(op = bop, lhs = target, rhs = value), opSpan)
  Some(value = wrapRangeCheck(combined, site, helpers))
}

func wrapRangeCheck(e: in Expr, site: in RangeCheckSite, helpers: in RangeHelpers): Expr {
  val name = rangeHelperFor(site, helpers, e.span)
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = e))
  // Zero-width span: the wrapper must not share the value's span key, which
  // later passes use to identify the value itself.
  val wrapSpan = Span(startPos = e.span.startPos, endPos = e.span.startPos)
  mkExpr(ECall(fn = mkPath(name, wrapSpan), args = args), wrapSpan)
}

// The checker for `site`, one per site: a failure reports the position of
// the value it checks.
func rangeHelperFor(site: in RangeCheckSite, helpers: in RangeHelpers, sp: in Span): String {
  val message = "RangeViolated: " + site.subject + " must be in " + Fmt.typeStr(site.source)
  val key = recordCopySiteKey(sp) + "|" + message
  match mapGet(helpers.names, key) {
    case Some(n) -> return n
    case None -> ()
  }
  val name = "__lyric_range_" + toString(helpers.names.count)
  helpers.names.add(key, name)
  val base = rangeBaseType(site.source)
  val rb = match refinedRangeOf(site.source) {
    case Some(r) -> foldedRange(r, site, base)
    case None -> panic("Lyric.ContractElaborator: range site recorded for an unrefined type")
  }
  val params: List[Param] = newList()
  params.add(
    Param(mode = PMIn, modeExplicit = true, name = "v", ty = base, dflt = None, annotations = newList(), span = sp)
  )
  val stmts: List[Statement] = newList()
  stmts.add(mkAssertCall(rangeCondition(mkPath("v", sp), rb, sp), message, sp))
  stmts.add(Statement(kind = SExpr(expr = mkPath("v", sp)), span = sp))
  val fn = FunctionDecl(
    docComments = newList(),
    annotations = newList(),
    visibility = None,
    isAsync = false,
    name = name,
    generics = None,
    params = params,
    ret = Some(value = base),
    whereClause = None,
    contracts = newList(),
    body = Some(value = FBBlock(block = Block(statements = stmts, span = sp))),
    span = sp
  )
  helpers.items.add(
    Item(docComments = newList(), annotations = newList(), visibility = None, kind = IFunc(decl = fn), span = sp)
  )
  name
}

// The type a range refines: `Int` for `Int range 0 ..= 3`.
func rangeBaseType(te: in TypeExpr): TypeExpr {
  match te.kind {
    case TRefined(under, _) -> TypeExpr(kind = TRef(path = under), span = te.span)
    case TParen(inner) -> rangeBaseType(inner)
    case _ -> te
  }
}

// The bounds of `rb`, each one that is not a literal replaced by the integer
// the checker folded it to, so the checker needs nothing from the package
// that declared the range.
func foldedRange(rb: in RangeBound, site: in RangeCheckSite, base: in TypeExpr): RangeBound {
  val isLong = match base.kind { case TRef(p) -> p.segments.count == 1 and p.segments[0] == "Long"; case _ -> false }
  match rb {
    case RBClosed(lo, hi) -> RBClosed(lo = foldedBound(lo, site.lo, isLong), hi = foldedBound(hi, site.hi, isLong))
    case RBHalfOpen(lo, hi, bare) -> RBHalfOpen(
      lo = foldedBound(lo, site.lo, isLong),
      hi = foldedBound(hi, site.hi, isLong),
      bareDotDot = bare
    )
    case RBLowerOpen(hi) -> RBLowerOpen(hi = foldedBound(hi, site.hi, isLong))
    case RBUpperOpen(lo) -> RBUpperOpen(lo = foldedBound(lo, site.lo, isLong))
  }
}

func foldedBound(e: in Expr, folded: in Option[Long], isLong: in Bool): Expr {
  if isLiteralBound(e) {
    return e
  }
  match folded {
    case Some(v) -> {
      val mag = if v < 0i64 { 0i64 - v } else { v }
      val suffix = if isLong { I64 } else { NoIntSuffix }
      val raw = if isLong { toString(mag) + "i64" } else { toString(mag) }
      val lit = mkExpr(ELiteral(lit = LInt(value = mag, suffix = suffix, raw = raw)), e.span)
      if v < 0i64 {
        mkExpr(EPrefix(op = PreNeg, operand = lit), e.span)
      } else {
        lit
      }
    }
    case None -> e
  }
}

func isLiteralBound(e: in Expr): Bool {
  match e.kind {
    case ELiteral(_) -> true
    case EPrefix(_, operand) -> isLiteralBound(operand)
    case EParen(inner) -> isLiteralBound(inner)
    case _ -> false
  }
}
