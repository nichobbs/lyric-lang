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
