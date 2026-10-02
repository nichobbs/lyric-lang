//! Operators on distinct types are lowered through the underlying value
//! (#7361).
//!
//! A distinct type (`type UserId = Long`, `type Cents = Long range 0 ..= 1000
//! derives Add, Sub, Compare`) is a wrapper class with a `value` field on the
//! managed targets, and the checker accepts `==`, `!=` and the derived
//! operators on it.  No backend lowered those through the wrapper: arithmetic
//! operated on object references (memory corruption on dotnet, a verify
//! error on the JVM) and `==` compared references.  The checker records
//! every such operator (`SymbolTable.distinctOpSites` /
//! `distinctCompoundSites`) and this pass rewrites it:
//!
//! - `a op b` (derived arithmetic) becomes `T.from(a.value op b.value)`,
//!   which also re-checks a range subtype's bounds (#7226);
//! - `a == b`, `a != b` and derived comparisons become `a.value op b.value`;
//! - `x op= y` becomes `x = T.from(x.value op y.value)`.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

pub func lowerDistinctOps(
  file: in SourceFile, opSites: in Map[String, String], compoundSites: in Map[String, String]
): SourceFile {
  if opSites.count == 0 and compoundSites.count == 0 {
    return file
  }
  mapFileAndContracts(
    file,
    { e: Expr -> rewriteDistinctBinop(e, opSites) },
    { s: Statement -> rewriteDistinctCompound(s, compoundSites) }
  )
}

// A zero-width span at `sp`'s start: a synthesized node must not share a
// recorded site's key.
func syntheticSpan(sp: in Span): Span {
  Span(startPos = sp.startPos, endPos = sp.startPos)
}

func valueOf(e: in Expr): Expr {
  val sp = syntheticSpan(e.span)
  mkExpr(EMember(receiver = e, memberName = "value"), sp)
}

// `T.from(arg)`, spelled as the parser spells a static member call: a member
// access on the type's path (`EMember(EPath([T]), "from")`), which is the
// shape every backend resolves.
func fromCall(path: in String, arg: in Expr, sp: in Span): Expr {
  val parts = Str.split(path, ".")
  val segs: List[String] = newList()
  var i = 0
  while i < parts.length - 1 {
    segs.add(parts[i])
    i = i + 1
  }
  val wsp = syntheticSpan(sp)
  val typePath = mkExpr(EPath(path = ModulePath(segments = segs, span = wsp)), wsp)
  val callee = mkExpr(EMember(receiver = typePath, memberName = parts[parts.length - 1]), wsp)
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = arg))
  mkExpr(ECall(fn = callee, args = args), wsp)
}

func rewriteDistinctBinop(e: in Expr, sites: in Map[String, String]): Expr {
  match e.kind {
    case EBinop(op, lhs, rhs) -> match mapGet(sites, recordCopySiteKey(e.span)) {
      case Some(kind) -> {
        val onValues = mkExpr(EBinop(op = op, lhs = valueOf(lhs), rhs = valueOf(rhs)), syntheticSpan(e.span))
        if Str.startsWith(kind, "arith:") {
          fromCall(Str.substring(kind, 6, kind.length - 6), onValues, e.span)
        } else {
          onValues
        }
      }
      case None -> e
    }
    case _ -> e
  }
}

func compoundBinOp(op: in AssignOp): Option[BinOp] {
  match op {
    case AssPlus -> Some(value = BAdd)
    case AssMinus -> Some(value = BSub)
    case AssStar -> Some(value = BMul)
    case AssSlash -> Some(value = BDiv)
    case AssPercent -> Some(value = BMod)
    case AssEq -> None
  }
}

// `t op= v`  ->  `t = T.from(t.value op v.value)`.  The type checker only
// records a compound site whose target is a variable or field path (T0134
// otherwise), so evaluating `t` twice is side-effect free.
func rewriteDistinctCompound(s: in Statement, sites: in Map[String, String]): Statement {
  match s.kind {
    case SAssign(target, op, value) -> match mapGet(sites, recordCopySiteKey(s.span)) {
      case Some(path) -> match compoundBinOp(op) {
        case Some(bop) -> {
          val wsp = syntheticSpan(s.span)
          val combined = mkExpr(EBinop(op = bop, lhs = valueOf(target), rhs = valueOf(value)), wsp)
          mkStmt(SAssign(target = target, op = AssEq, value = fromCall(path, combined, s.span)), s.span)
        }
        case None -> s
      }
      case None -> s
    }
    case _ -> s
  }
}

// Derived component-wise arithmetic on a homogeneous numeric record (D155):
//
//   a + b   ->   {
//                  val __lyric_ra_<s>_<e>_l: R = a
//                  val __lyric_ra_<s>_<e>_r: R = b
//                  R(x = <l>.x + <r>.x, y = <l>.y + <r>.y, ...)
//                }
//
// so each operand is evaluated once, left to right, and `r += s` becomes
// `r = <the same block>` (the checker allows only a variable or field target
// there).  The temporaries are typed so a backend that erases an unannotated
// local (the JVM) can read the fields back.
pub func lowerRecordArith(file: in SourceFile, sites: in Map[String, RecordArithSite]): SourceFile {
  if sites.count == 0 {
    return file
  }
  mapFileAndContracts(
    file,
    { e: Expr -> rewriteRecordBinop(e, sites) },
    { s: Statement -> rewriteRecordCompound(s, sites) }
  )
}

func rewriteRecordBinop(e: in Expr, sites: in Map[String, RecordArithSite]): Expr {
  match e.kind {
    case EBinop(_, lhs, rhs) -> match mapGet(sites, recordCopySiteKey(e.span)) {
      case Some(site) -> recordArithBlock(site, lhs, rhs, e.span)
      case None -> e
    }
    case _ -> e
  }
}

func rewriteRecordCompound(s: in Statement, sites: in Map[String, RecordArithSite]): Statement {
  match s.kind {
    case SAssign(target, op, value) -> match op {
      case AssEq -> s
      case _ -> match mapGet(sites, recordCopySiteKey(s.span)) {
        case Some(site) -> mkStmt(
          SAssign(
            target = target,
            op = AssEq,
            value = recordArithBlock(
              site,
              target,
              value,
              s.span
            )
          ),
          s.span
        )
        case None -> s
      }
    }
    case _ -> s
  }
}

func recordArithBlock(site: in RecordArithSite, lhs: in Expr, rhs: in Expr, sp: in Span): Expr {
  val wsp = syntheticSpan(sp)
  val base = "__lyric_ra_" + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset)
  val lName = base + "_l"
  val rName = base + "_r"
  val stmts: List[Statement] = newList()
  stmts.add(typedVal(lName, site.recordType, lhs, wsp))
  stmts.add(typedVal(rName, site.recordType, rhs, wsp))
  val args: List[CallArg] = newList()
  for f in site.fields {
    val lf = mkExpr(EMember(receiver = localPath(lName, wsp), memberName = f), wsp)
    val rf = mkExpr(EMember(receiver = localPath(rName, wsp), memberName = f), wsp)
    args.add(CANamed(name = f, value = mkExpr(EBinop(op = site.op, lhs = lf, rhs = rf), wsp), span = wsp))
  }
  val parts = Str.split(site.recordName, ".")
  val segs: List[String] = newList()
  var i = 0
  while i < parts.length {
    segs.add(parts[i])
    i = i + 1
  }
  val ctor = mkExpr(ECall(fn = mkExpr(EPath(path = ModulePath(segments = segs, span = wsp)), wsp), args = args), wsp)
  stmts.add(mkStmt(SExpr(expr = ctor), wsp))
  mkExpr(EBlock(block = Block(statements = stmts, span = wsp)), wsp)
}

func typedVal(name: in String, ty: in Option[TypeExpr], init: in Expr, sp: in Span): Statement {
  val pat = Pattern(kind = PBinding(name = name, inner = None), span = sp)
  mkStmt(SLocal(binding = LBVal(pat = pat, ty = ty, init = init)), sp)
}

func localPath(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  mkExpr(EPath(path = ModulePath(segments = segs, span = sp)), sp)
}
