// typechecker_constfold.l — compile-time integer constant folding.
// Mirrors compiler/src/Lyric.TypeChecker/ConstFold.fs.
// Used to validate range-subtype bounds at type-check time (T0090/T0093).
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Result type.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union FoldError {
  case FENotConstant
  case FECycle(name: String)
  case FEOverflow
  case FEDivByZero
}

@stable(since="0.1")
pub union FoldResult {
  case FoldOk(value: Long)
  case FoldErr(error: FoldError)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Constant folding entry point.
// ─────────────────────────────────────────────────────────────────────────────

pub func tryFoldInt(tbl: in SymbolTable, root: in Expr): FoldResult {
  foldGo(tbl, 0, root)
}

func foldGo(tbl: in SymbolTable, depth: in Int, e: in Expr): FoldResult {
  if depth > 64 { return FoldErr(error = FECycle(name = "<depth>")) }
  match e.kind {
    case EParen(inner) -> foldGo(tbl, depth, inner)

    case ELiteral(lit) ->
      match lit {
        case LInt(v, _, _) -> FoldOk(value = v)
        case _          -> FoldErr(error = FENotConstant)
      }

    case EPrefix(op, inner) ->
      match op {
        case PreNeg -> {
          // #425 item 5: `-9223372036854775808` is the canonical
          // spelling of `Long.MinValue`.  The lexer stores the inner
          // literal `9223372036854775808` as the bit pattern of
          // Long.MinValue (`parseDigits` special case), and the
          // PreNeg + literal pair folds to Long.MinValue here as a
          // single unit — preserving the spelling rather than
          // re-routing through `0 - v` (which would saturate to
          // Long.MinValue via two's-complement wraparound anyway,
          // but lose the explicit-vs-saturation distinction).
          match inner.kind {
            case ELiteral(litInner) ->
              match litInner {
                case LInt(lv, _, _) ->
                  if lv == -9223372036854775808i64 {
                    FoldOk(value = -9223372036854775808i64)
                  } else {
                    FoldOk(value = 0i64 - lv)
                  }
                case _ ->
                  match foldGo(tbl, depth, inner) {
                    case FoldErr(e2) -> FoldErr(error = e2)
                    case FoldOk(v)   ->
                      if v == -9223372036854775808i64 { FoldErr(error = FEOverflow) }
                      else { FoldOk(value = 0i64 - v) }
                  }
              }
            case _ ->
              match foldGo(tbl, depth, inner) {
                case FoldErr(e2) -> FoldErr(error = e2)
                case FoldOk(v)   ->
                  if v == -9223372036854775808i64 { FoldErr(error = FEOverflow) }
                  else { FoldOk(value = 0i64 - v) }
              }
          }
        }
        case _ -> FoldErr(error = FENotConstant)
      }

    case EBinop(op, l, r) -> {
      match foldGo(tbl, depth, l) {
        case FoldErr(e2) -> FoldErr(error = e2)
        case FoldOk(lv) ->
          match foldGo(tbl, depth, r) {
            case FoldErr(e2) -> FoldErr(error = e2)
            case FoldOk(rv)  -> foldArith(op, lv, rv)
          }
      }
    }

    case EPath(path) -> {
      if path.segments.count != 1 { return FoldErr(error = FENotConstant) }
      val name = path.segments[0]
      match symTableTryFindOne(tbl, name) {
        case None -> FoldErr(error = FENotConstant)
        case Some(sym) ->
          match sym.kind {
            case DKConst(cd) -> foldGo(tbl, depth + 1, cd.init)
            case DKVal(vd)   -> foldGo(tbl, depth + 1, vd.init)
            case _           -> FoldErr(error = FENotConstant)
          }
      }
    }

    case _ -> FoldErr(error = FENotConstant)
  }
}

func foldArith(op: in BinOp, lv: in Long, rv: in Long): FoldResult {
  match op {
    case BAdd -> FoldOk(value = lv + rv)
    case BSub -> FoldOk(value = lv - rv)
    case BMul -> FoldOk(value = lv * rv)
    case BDiv -> {
      if rv == 0 { FoldErr(error = FEDivByZero) }
      else { FoldOk(value = lv / rv) }
    }
    case BMod -> {
      if rv == 0 { FoldErr(error = FEDivByZero) }
      else { FoldOk(value = lv % rv) }
    }
    case _ -> FoldErr(error = FENotConstant)
  }
}
