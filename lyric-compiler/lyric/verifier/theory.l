//! verifier/theory.l — theory mapping: Lyric source types → VC sorts,
//! Lyric operators → Vcir.Builtin.
//!
//! Mirrors compiler/src/Lyric.Verifier/Theory.fs.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Sort-info: resolved sort plus optional range bound.
// ─────────────────────────────────────────────────────────────────────────────
pub union RangeBoundKind {
  case RBKClosed(lo: Long, hi: Long)
  case RBKHalfOpen(lo: Long, hi: Long)
  // No lower bound — emit only `v <= hi`.  Models AST `..=hi` (`RBLowerOpen`).
  case RBKUpperBound(hi: Long)
  // No upper bound — emit only `lo <= v`.  Models AST `lo..` (`RBUpperOpen`).
  case RBKLowerBound(lo: Long)
  case RBKNone
}

pub record SortInfo {
  pub sort: Sort
  pub range: RangeBoundKind
}

pub func sortInfoNoRange(s: in Sort): SortInfo {
  SortInfo(sort = s, range = RBKNone)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Primitive sort lookup.
// ─────────────────────────────────────────────────────────────────────────────
// Map a primitive type name to a sort.  Returns None for unknown types.
pub func primitiveSort(name: in String): Option[SortInfo] {
  if name == "Bool" {
    return Some(value = sortInfoNoRange(SBool))
  }
  if name == "Int" {
    return Some(value = sortInfoNoRange(SInt))
  }
  if name == "Long" {
    return Some(value = sortInfoNoRange(SInt))
  }
  if name == "Nat" {
    val natRange = RBKClosed(lo = 0i64, hi = 9223372036854775807i64)
    val natSortInfo = SortInfo(sort = SInt, range = natRange)
    return Some(value = natSortInfo)
  }
  if name == "UInt" {
    return Some(value = sortInfoNoRange(SBitVec(width = 32)))
  }
  if name == "ULong" {
    return Some(value = sortInfoNoRange(SBitVec(width = 64)))
  }
  if name == "Byte" {
    return Some(value = sortInfoNoRange(SBitVec(width = 8)))
  }
  if name == "Float" {
    return Some(value = sortInfoNoRange(SFloat32))
  }
  if name == "Double" {
    return Some(value = sortInfoNoRange(SFloat64))
  }
  if name == "String" {
    return Some(value = sortInfoNoRange(SString))
  }
  if name == "Unit" {
    val args: List[Sort] = newList()
    return Some(value = sortInfoNoRange(SDatatype(name = "Unit", args = args)))
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. TypeExpr → SortInfo.
// ─────────────────────────────────────────────────────────────────────────────
// Build a qualified SMT datatype name from a module path.  Joins segments with
// `.` so distinct packages with the same short type name (e.g. `Std.Time.Instant`
// vs `MyPkg.Instant`) produce distinct sorts.  Single-segment paths return the
// segment unchanged so primitive sorts and built-ins like `Option` keep their
// canonical names.
//
// `.` is chosen over `_` because Lyric identifiers allow `_` (UAX #31
// XID_Continue), so a `_` separator would collide on inputs like
// `Pkg_A.Foo` vs `Pkg.A_Foo`.  `.` cannot appear inside a single
// identifier segment, so the joined string is unambiguous, and SMT-LIB
// v2.6 §3.1 admits `.` in simple symbols.
pub func qualifiedDatatypeName(segs: in List[String]): String {
  if segs.count == 0 {
    return "?"
  }
  if segs.count == 1 {
    return segs[0]
  }
  var name = segs[0]
  var i = 1
  while i < segs.count {
    name = name + "." + segs[i]
    i = i + 1
  }
  name
}

// Map a TypeExpr to a SortInfo.  Falls back to an uninterpreted sort for
// unknown types (M4.1 limitation).
pub func sortOfTypeExpr(t: in TypeExpr): SortInfo {
  match t.kind {
    case TRef(path) -> {
      val segs = path.segments
      if segs.count == 0 {
        val emptyArgs: List[Sort] = newList()
        return sortInfoNoRange(SDatatype(name = "?", args = emptyArgs))
      }
      val leaf = segs[segs.count - 1]
      match primitiveSort(leaf) {
        case Some(si) -> si
        case None -> {
          val emptyArgs: List[Sort] = newList()
          // Use the qualified (Pkg_Sub_Name) form so distinct types with the
          // same short name don't collapse into one SMT sort.
          sortInfoNoRange(SDatatype(name = qualifiedDatatypeName(segs), args = emptyArgs))
        }
      }
    }
    case TGenericApp(head, args) -> {
      val argSorts: List[Sort] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(te) -> argSorts.add(sortOfTypeExpr(te).sort)
          case TAValue(_) -> {
          }
        }
        i = i + 1
      }
      val segs = head.segments
      sortInfoNoRange(SDatatype(name = qualifiedDatatypeName(segs), args = argSorts))
    }
    case TArray(_, elt) -> {
      sortInfoNoRange(SSlice(element = sortOfTypeExpr(elt).sort))
    }
    case TSlice(elt) -> {
      sortInfoNoRange(SSlice(element = sortOfTypeExpr(elt).sort))
    }
    case TRefined(underlying, range) -> {
      val segs = underlying.segments
      val leaf = if segs.count > 0 { segs[segs.count - 1] } else { "" }
      val baseSort = match primitiveSort(leaf) { case Some(si) -> si.sort; case None -> SInt }
      val rb = constFoldRangeBound(range)
      SortInfo(sort = baseSort, range = rb)
    }
    case TTuple(elts) -> {
      val sorts: List[Sort] = newList()
      var i = 0
      while i < elts.count {
        sorts.add(sortOfTypeExpr(elts[i]).sort)
        i = i + 1
      }
      sortInfoNoRange(SDatatype(name = "Tuple", args = sorts))
    }
    case TNullable(inner) -> {
      val inner2 = sortOfTypeExpr(inner).sort
      val args: List[Sort] = newList()
      args.add(inner2)
      sortInfoNoRange(SDatatype(name = "Option", args = args))
    }
    case TFunction(_, _) -> sortInfoNoRange(SUninterp(name = "Function"))
    case TUnit -> {
      val args: List[Sort] = newList()
      sortInfoNoRange(SDatatype(name = "Unit", args = args))
    }
    case TSelf -> sortInfoNoRange(SUninterp(name = "Self"))
    case TNever -> sortInfoNoRange(SUninterp(name = "Never"))
    case TParen(inner) -> sortOfTypeExpr(inner)
    case TError -> sortInfoNoRange(SUninterp(name = "Error"))
  }
}

// Constant-fold a RangeBound into a RangeBoundKind.  Returns RBKNone for
// non-literal bounds.
func constFoldRangeBound(rb: in RangeBound): RangeBoundKind {
  match rb {
    case RBClosed(lo, hi) -> {
      match foldExprToLong(lo) {
        case Some(a) -> {
          match foldExprToLong(hi) {
            case Some(b) -> RBKClosed(lo = a, hi = b)
            case None -> RBKNone
          }
        }
        case None -> RBKNone
      }
    }
    case RBHalfOpen(lo, hi) -> {
      match foldExprToLong(lo) {
        case Some(a) -> {
          match foldExprToLong(hi) {
            case Some(b) -> RBKHalfOpen(lo = a, hi = b)
            case None -> RBKNone
          }
        }
        case None -> RBKNone
      }
    }
    case RBLowerOpen(hi) -> {
      // AST: `..=hi` — no lower bound, closed upper bound.
      match foldExprToLong(hi) {
        case Some(b) -> RBKUpperBound(hi = b)
        case None -> RBKNone
      }
    }
    case RBUpperOpen(lo) -> {
      // AST: `lo..` — closed lower bound, no upper bound.
      match foldExprToLong(lo) {
        case Some(a) -> RBKLowerBound(lo = a)
        case None -> RBKNone
      }
    }
  }
}

// Fold a constant integer expression to a Long.
func foldExprToLong(e: in Expr): Option[Long] {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, _, _) -> Some(value = v)
        case _ -> None
      }
    }
    case EPrefix(op, inner) -> {
      match op {
        case PreNeg -> {
          match inner.kind {
            case ELiteral(LInt(v, _)) -> Some(value = -v)
            case _ -> None
          }
        }
        case _ -> None
      }
    }
    case _ -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Operator mappings.
// ─────────────────────────────────────────────────────────────────────────────
pub func builtinOfBinop(op: in BinOp): Option[Builtin] {
  match op {
    case BAdd -> Some(value = BOpAdd)
    case BSub -> Some(value = BOpSub)
    case BMul -> Some(value = BOpMul)
    case BDiv -> Some(value = BOpDiv)
    case BMod -> Some(value = BOpMod)
    case BAnd -> Some(value = BOpAnd)
    case BOr -> Some(value = BOpOr)
    case BXor -> Some(value = BOpXor)
    case BEq -> Some(value = BOpEq)
    case BNeq -> Some(value = BOpNeq)
    case BLt -> Some(value = BOpLt)
    case BLte -> Some(value = BOpLte)
    case BGt -> Some(value = BOpGt)
    case BGte -> Some(value = BOpGte)
    case BImplies -> Some(value = BOpImplies)
    case BCoalesce -> None
    case _ -> None
  }
}

pub func builtinOfPrefix(op: in PrefixOp): Option[Builtin] {
  match op {
    case PreNeg -> Some(value = BOpNeg)
    case PreNot -> Some(value = BOpNot)
    case PreRef -> None
    case _ -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Range hypotheses.
// ─────────────────────────────────────────────────────────────────────────────
// Generate range-bound hypotheses for a binder of the given sort/range.
pub func rangeHypotheses(binder: in String, info: in SortInfo): List[Term] {
  val result: List[Term] = newList()
  match info.range {
    case RBKNone -> {
    }
    case RBKClosed(lo, hi) -> {
      val v = TVar(name = binder, sort = info.sort)
      result.add(TBuiltin(op = BOpLte, args = termList2(TLit(value = VLInt(n = lo), sort = SInt), v)))
      result.add(TBuiltin(op = BOpLte, args = termList2(v, TLit(value = VLInt(n = hi), sort = SInt))))
    }
    case RBKHalfOpen(lo, hi) -> {
      val v = TVar(name = binder, sort = info.sort)
      result.add(TBuiltin(op = BOpLte, args = termList2(TLit(value = VLInt(n = lo), sort = SInt), v)))
      result.add(TBuiltin(op = BOpLt, args = termList2(v, TLit(value = VLInt(n = hi), sort = SInt))))
    }
    case RBKUpperBound(hi) -> {
      val v = TVar(name = binder, sort = info.sort)
      result.add(TBuiltin(op = BOpLte, args = termList2(v, TLit(value = VLInt(n = hi), sort = SInt))))
    }
    case RBKLowerBound(lo) -> {
      val v = TVar(name = binder, sort = info.sort)
      result.add(TBuiltin(op = BOpLte, args = termList2(TLit(value = VLInt(n = lo), sort = SInt), v)))
    }
  }
  result
}
