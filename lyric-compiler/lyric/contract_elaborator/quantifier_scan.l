//! W0002: a `forall`/`exists` in a contract is not checked at runtime (#7228).
//!
//! Quantifier domains are types (`forall (i: Int) where ... { ... }`), so a
//! runtime-checked build cannot evaluate them.  `mkAssertCall` drops every
//! top-level `and` conjunct that contains one; this scan reports each such
//! quantifier at its own span so the author knows which part of which clause
//! is only a proof obligation.  The pipeline runs it for files that are not
//! `@proof_required`.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

pub func runtimeQuantifierWarnings(file: in SourceFile): List[Diagnostic] {
  val diags: List[Diagnostic] = newList()
  // Function bodies (including loop `invariant:` clauses), vals, consts and
  // field defaults.
  val _ = mapExprsInFile(file, { e -> noteQuantifier(e, diags) })
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> scanContracts(fn.contracts, diags)
      case IRecord(decl) -> scanRecordMembers(decl.members, diags)
      case IExposedRec(decl) -> scanRecordMembers(decl.members, diags)
      case IOpaque(decl) -> {
        var j = 0
        while j < decl.members.count {
          match decl.members[j] {
            case OMInvariant(inv) -> scanExpr(inv.expr, diags)
            case _ -> ()
          }
          j = j + 1
        }
      }
      case IImpl(decl) -> {
        var j = 0
        while j < decl.members.count {
          match decl.members[j] {
            case IMplFunc(fn) -> scanContracts(fn.contracts, diags)
            case _ -> ()
          }
          j = j + 1
        }
      }
      case IInterface(decl) -> {
        var j = 0
        while j < decl.members.count {
          match decl.members[j] {
            case IMFunc(fn) -> scanContracts(fn.contracts, diags)
            case _ -> ()
          }
          j = j + 1
        }
      }
      case IProtected(decl) -> {
        var j = 0
        while j < decl.members.count {
          match decl.members[j] {
            case PMEntry(ed) -> scanContracts(ed.contracts, diags)
            case PMFunc(fn) -> scanContracts(fn.contracts, diags)
            case PMInvariant(inv) -> scanExpr(inv.expr, diags)
            case _ -> ()
          }
          j = j + 1
        }
      }
      case IAspect(decl) -> scanContracts(decl.contracts, diags)
      case _ -> ()
    }
    i = i + 1
  }
  diags
}

func scanRecordMembers(members: in List[RecordMember], diags: in List[Diagnostic]): Unit {
  var j = 0
  while j < members.count {
    match members[j] {
      case RMInvariant(inv) -> scanExpr(inv.expr, diags)
      case RMFunc(fn) -> scanContracts(fn.contracts, diags)
      case _ -> ()
    }
    j = j + 1
  }
}

func scanContracts(contracts: in List[ContractClause], diags: in List[Diagnostic]): Unit {
  var i = 0
  while i < contracts.count {
    match contracts[i] {
      case CCRequires(e, _) -> scanExpr(e, diags)
      case CCEnsures(e, _) -> scanExpr(e, diags)
      case _ -> ()
    }
    i = i + 1
  }
}

func scanExpr(e: in Expr, diags: in List[Diagnostic]): Unit {
  val _ = mapExpr(e, { x -> noteQuantifier(x, diags) })
}

func noteQuantifier(e: in Expr, diags: in List[Diagnostic]): Expr {
  match e.kind {
    case EForall(_, _, _) -> diags.add(quantifierWarning("forall", e.span))
    case EExists(_, _, _) -> diags.add(quantifierWarning("exists", e.span))
    case _ -> ()
  }
  e
}

func quantifierWarning(kw: in String, sp: in Span): Diagnostic {
  warningDiagnostic(
    "W0002",
    "`" + kw +
      "` in a contract is not checked at runtime: the `and`-conjunct containing it is skipped, the rest of the clause is still checked. Put the property in a @proof_required package to have it proved.",
    sp
  )
}

/// True when `e` contains a `forall` or `exists` anywhere.
pub func exprHasQuantifier(e: in Expr): Bool {
  val hits: List[Span] = newList()
  val _ = mapExpr(e, { x -> noteQuantifierSpan(x, hits) })
  hits.count > 0
}

func noteQuantifierSpan(e: in Expr, hits: in List[Span]): Expr {
  match e.kind {
    case EForall(_, _, _) -> hits.add(e.span)
    case EExists(_, _, _) -> hits.add(e.span)
    case _ -> ()
  }
  e
}
