//! verifier/theory.l — theory mapping: Lyric source types → VC sorts,
//! Lyric operators → Vcir.Builtin.
//!
//! Mirrors compiler/src/Lyric.Verifier/Theory.fs.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
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
  // A declared bound the verifier cannot translate faithfully: a bound that
  // is not an integer literal, a negative or over-wide bound on an unsigned
  // base, or a wide `u64` bound on a signed base.  No hypothesis is drawn
  // from it, and an obligation to establish it fails closed (V0033, #7848).
  case RBKUnsupported(reason: String)
}

pub record SortInfo {
  pub sort: Sort
  pub range: RangeBoundKind
  // The width of a fixed-width signed integer modelled as the unbounded
  // `Int` sort: 32 for `Int`, 64 for `Long` and `Nat`, 0 for every other
  // sort or an integer whose width is not known (#7871).
  pub intBits: Int = 0
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
    return Some(value = SortInfo(sort = SInt, range = RBKNone, intBits = 32))
  }
  if name == "Long" {
    return Some(value = SortInfo(sort = SInt, range = RBKNone, intBits = 64))
  }
  if name == "Nat" {
    val natRange = RBKClosed(lo = 0i64, hi = 9223372036854775807i64)
    val natSortInfo = SortInfo(sort = SInt, range = natRange, intBits = 64)
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

// The bit width of a bitvector sort, or `None` for every other sort.
pub func bitVecWidth(s: in Sort): Option[Int] {
  match s {
    case SBitVec(w) -> Some(value = w)
    case _ -> None
  }
}

// A literal of sort `s` holding `n`: a mathematical integer for `SInt`, and
// a bitvector constant whose pattern is `n` for `SBitVec` (#7848).
pub func intLitOfSort(n: in Long, s: in Sort): Term {
  match s {
    case SBitVec(w) -> TLit(value = VLBitVec(bits = n, width = w), sort = s)
    case _ -> TLit(value = VLInt(n = n), sort = SInt)
  }
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
      match primitiveSort(leaf) {
        case Some(si) -> refinedSortInfo(si.sort, si.intBits, range)
        // `Char` (whose literals translate to their code point) and a base
        // the file does not declare are modelled as integers, as before.
        case None -> refinedSortInfo(SInt, 0, range)
      }
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

// The sort/range of `base range <bound>`, where `intBits` is the base's
// signed width (`SortInfo.intBits`).  Only an integer or bitvector base
// carries a range the verifier can state.
pub func refinedSortInfo(base: in Sort, intBits: in Int, range: in RangeBound): SortInfo {
  match base {
    case SInt -> SortInfo(sort = base, range = constFoldRangeBound(range, base), intBits = intBits)
    case SBitVec(_) -> SortInfo(sort = base, range = constFoldRangeBound(range, base))
    case _ -> SortInfo(
      sort = base,
      range = RBKUnsupported(reason = "a range over the " + sortDisplay(base) + " sort is not modelled")
    )
  }
}

// Constant-fold a RangeBound into a RangeBoundKind for a value of sort
// `base`.  A bound on a bitvector base is folded unsigned and held as its
// bit pattern; a bound on an integer base is folded signed (#7848).  A bound
// that cannot be folded faithfully is `RBKUnsupported`.
func constFoldRangeBound(rb: in RangeBound, base: in Sort): RangeBoundKind {
  match rb {
    case RBClosed(lo, hi) -> {
      match foldBound(lo, base) {
        case Ok(a) -> match foldBound(hi, base) {
          case Ok(b) -> RBKClosed(lo = a, hi = b)
          case Err(r) -> RBKUnsupported(reason = r)
        }
        case Err(r) -> RBKUnsupported(reason = r)
      }
    }
    case RBHalfOpen(lo, hi, _) -> {
      match foldBound(lo, base) {
        case Ok(a) -> match foldBound(hi, base) {
          case Ok(b) -> RBKHalfOpen(lo = a, hi = b)
          case Err(r) -> RBKUnsupported(reason = r)
        }
        case Err(r) -> RBKUnsupported(reason = r)
      }
    }
    case RBLowerOpen(hi) -> {
      // AST: `..=hi` — no lower bound, closed upper bound.
      match foldBound(hi, base) {
        case Ok(b) -> RBKUpperBound(hi = b)
        case Err(r) -> RBKUnsupported(reason = r)
      }
    }
    case RBUpperOpen(lo) -> {
      // AST: `lo..` — closed lower bound, no upper bound.
      match foldBound(lo, base) {
        case Ok(a) -> RBKLowerBound(lo = a)
        case Err(r) -> RBKUnsupported(reason = r)
      }
    }
  }
}

// Fold one range bound for a value of sort `base`.
func foldBound(e: in Expr, base: in Sort): Result[Long, String] {
  match foldIntLiteral(e) {
    case Some(lit) -> {
      match bitVecWidth(base) {
        case Some(w) -> {
          if lit.negative {
            Err(error = "a negative bound on an unsigned range cannot be represented")
          } else if lit.wideUnsigned and w < 64 {
            Err(error = "a `u64` bound above 2^63 does not fit a " + intToString(w) + "-bit unsigned range")
          } else if fitsUnsignedWidth(lit.value, w) {
            Ok(value = lit.value)
          } else {
            Err(error = "the bound " + longToString(lit.value) + " does not fit a " + intToString(w) + "-bit unsigned range")
          }
        }
        case None -> {
          if lit.wideUnsigned {
            Err(error = "a `u64` bound above 2^63 does not fit a signed range")
          } else {
            Ok(value = lit.value)
          }
        }
      }
    }
    case None -> Err(error = "a range bound that is not an integer literal is not modelled")
  }
}

// A folded integer literal.  `value` is the literal's `Long` value, or for
// a `u64` literal from 2^63 up (`wideUnsigned`) its two's-complement
// pattern.  `negative` marks a negated literal, whose value is below zero.
pub record FoldedIntLit {
  pub value: Long
  pub negative: Bool
  pub wideUnsigned: Bool
}

// Fold an integer literal, or a unary minus applied directly to one, the
// way `Lyric.Pipeline.foldNegatedIntLiteral` does for the backends (#7853):
// the magnitude one past a signed maximum (`-9223372036854775808`,
// `-0x8000_0000_0000_0000`, `-2147483648i32`, `-128i8`) is one signed
// constant, and `Long.MinValue`'s magnitude — carried as its own pattern —
// negates to itself rather than to +2^63.  An unsigned-suffixed literal
// under a minus has no signed value and does not fold.
pub func foldIntLiteral(e: in Expr): Option[FoldedIntLit] {
  match e.kind {
    case EParen(inner) -> foldIntLiteral(inner)
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, sfx, _) -> {
          val wide = isSome(unsignedSuffixWidth(sfx)) and v < 0i64
          Some(value = FoldedIntLit(value = v, negative = false, wideUnsigned = wide))
        }
        case LChar(cp) -> Some(value = FoldedIntLit(value = cp.toLong(), negative = false, wideUnsigned = false))
        case _ -> None
      }
    }
    case EPrefix(op, inner) -> {
      match op {
        case PreNeg -> {
          match stripExprParens(inner).kind {
            case ELiteral(LInt(v, sfx, _)) -> {
              if isSome(unsignedSuffixWidth(sfx)) {
                None
              } else {
                val minLong: Long = -9223372036854775807i64 - 1i64
                val n = if v == minLong { v } else { 0i64 - v }
                Some(value = FoldedIntLit(value = n, negative = n < 0i64, wideUnsigned = false))
              }
            }
            case _ -> None
          }
        }
        case _ -> None
      }
    }
    case _ -> None
  }
}

// The bit width of an unsigned integer suffix's type; `None` for a signed
// suffix or none.
func unsignedSuffixWidth(suffix: in IntSuffix): Option[Int] {
  match suffix {
    case U8 -> Some(value = 8)
    case U16 -> Some(value = 16)
    case U32 -> Some(value = 32)
    case U64 -> Some(value = 64)
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
// Generate range-bound hypotheses for an arbitrary Term of the given
// sort/range (#3855) — e.g. a protected-type field, which is bound to a
// selector `TApp` rather than a plain `TVar`, so the hypothesis must be
// stated over the same term the body's field references resolve to.
//
// A bound is stated in the value's own sort: a bitvector base compares
// against a bitvector constant, which the SMT back-end orders unsigned
// (`bvule`/`bvult`), so a `ULong range 0 ..= 18446744073709551615u64`
// bound means what it says (#7848).  An `RBKUnsupported` bound yields no
// hypothesis — dropping an assumption is sound; the obligation side is
// `rangeObligationsForTerm`.
pub func rangeHypothesesForTerm(v: in Term, info: in SortInfo): List[Term] {
  val result: List[Term] = newList()
  val s = info.sort
  match info.range {
    case RBKNone -> {
    }
    case RBKUnsupported(_) -> {
    }
    case RBKClosed(lo, hi) -> {
      result.add(TBuiltin(op = BOpLte, args = termList2(intLitOfSort(lo, s), v)))
      result.add(TBuiltin(op = BOpLte, args = termList2(v, intLitOfSort(hi, s))))
    }
    case RBKHalfOpen(lo, hi) -> {
      result.add(TBuiltin(op = BOpLte, args = termList2(intLitOfSort(lo, s), v)))
      result.add(TBuiltin(op = BOpLt, args = termList2(v, intLitOfSort(hi, s))))
    }
    case RBKUpperBound(hi) -> {
      result.add(TBuiltin(op = BOpLte, args = termList2(v, intLitOfSort(hi, s))))
    }
    case RBKLowerBound(lo) -> {
      result.add(TBuiltin(op = BOpLte, args = termList2(intLitOfSort(lo, s), v)))
    }
  }
  result
}

// The terms a value of this sort/range must satisfy, for an obligation
// (a function's range-typed result).  `Err` carries the reason when the
// declared bound cannot be translated: the caller fails closed (V0033)
// rather than dropping the obligation.
pub func rangeObligationsForTerm(v: in Term, info: in SortInfo): Result[List[Term], String] {
  match info.range {
    case RBKUnsupported(reason) -> Err(error = reason)
    case _ -> Ok(value = rangeHypothesesForTerm(v, info))
  }
}

// Generate range-bound hypotheses for a binder of the given sort/range.
pub func rangeHypotheses(binder: in String, info: in SortInfo): List[Term] {
  rangeHypothesesForTerm(TVar(name = binder, sort = info.sort), info)
}

// The least and greatest value of a `bits`-wide signed integer (32 or 64).
pub func signedMinOfBits(bits: in Int): Long {
  if bits == 32 {
    -2147483648i64
  } else {
    -9223372036854775807i64 - 1i64
  }
}

pub func signedMaxOfBits(bits: in Int): Long {
  if bits == 32 {
    2147483647i64
  } else {
    9223372036854775807i64
  }
}

// `MIN <= v <= MAX` for a `bits`-wide signed integer `v` modelled as an
// unbounded `Int` (#7871).
pub func signedWidthBounds(v: in Term, bits: in Int): List[Term] {
  val result: List[Term] = newList()
  val lo = TLit(value = VLInt(n = signedMinOfBits(bits)), sort = SInt)
  val hi = TLit(value = VLInt(n = signedMaxOfBits(bits)), sort = SInt)
  result.add(TBuiltin(op = BOpLte, args = termList2(lo, v)))
  result.add(TBuiltin(op = BOpLte, args = termList2(v, hi)))
  result
}

// The width facts of a value that exists at runtime — a parameter, a
// protected-type field, a callee's result: an `Int` is within 32 bits and a
// `Long` within 64, whatever the build profile (#7871).  Empty for every
// other sort.  A value computed by the body is not covered: its arithmetic
// is mathematical, and only `@proof_required(checked_arithmetic)` proves it
// stays in range.
pub func intWidthHypothesesForTerm(v: in Term, info: in SortInfo): List[Term] {
  match info.sort {
    case SInt -> {
      if info.intBits > 0 {
        signedWidthBounds(v, info.intBits)
      } else {
        val none: List[Term] = newList()
        none
      }
    }
    case _ -> {
      val none: List[Term] = newList()
      none
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Integer / bitvector sort reconciliation (#7848).
// ─────────────────────────────────────────────────────────────────────────────
// `UInt`, `ULong` and `Byte` are `(_ BitVec n)`; `Int`, `Long` and `Nat` are
// mathematical integers.  A source literal is translated before its context
// is known, so an unsuffixed literal next to an unsigned operand starts life
// as an `SInt` constant and is converted here into a bitvector constant of
// the operand's width — the same rule the type checker applies ("next to an
// operand of another integer type the literal takes that type", docs/01
// §2.1).  A narrower unsigned operand widens by zero-extension along
// `Byte < UInt < ULong`, and a `Byte` widens into the signed chain through
// its non-negative value.  Anything else that mixes the two sorts has no
// faithful translation, and the caller fails closed with the `Err` reason.
func isArithBuiltin(op: in Builtin): Bool {
  match op {
    case BOpAdd -> true
    case BOpSub -> true
    case BOpMul -> true
    case BOpDiv -> true
    case BOpMod -> true
    case _ -> false
  }
}

// The builtins whose operands must share one numeric sort.
pub func isSortUnifyingBuiltin(op: in Builtin): Bool {
  match op {
    case BOpAdd -> true
    case BOpSub -> true
    case BOpMul -> true
    case BOpDiv -> true
    case BOpMod -> true
    case BOpLt -> true
    case BOpLte -> true
    case BOpGt -> true
    case BOpGte -> true
    case BOpEq -> true
    case BOpNeq -> true
    case _ -> false
  }
}

// True for an `SInt` term built only from integer literals, the arithmetic
// builtins and `ite` — a constant whose sort is still open.
pub func isIntConstTree(t: in Term): Bool {
  match t {
    case TLit(VLInt(_), _) -> true
    case TBuiltin(op, args) -> {
      if isArithBuiltin(op) or builtinEq(op, BOpNeg) {
        var i = 0
        while i < args.count {
          if not isIntConstTree(args[i]) {
            return false
          }
          i = i + 1
        }
        args.count > 0
      } else {
        false
      }
    }
    case TIte(_, a, b) -> isIntConstTree(a) and isIntConstTree(b)
    case _ -> false
  }
}

// Convert an integer constant tree to a `width`-bit unsigned constant.
func coerceIntConst(t: in Term, width: in Int): Result[Term, String] {
  val bvSort = SBitVec(width = width)
  match t {
    case TLit(VLInt(n), _) -> {
      if n < 0i64 {
        Err(
          error = "the negative constant (-" + longMagnitudeToString(n) + ") has no " + intToString(width) +
            "-bit unsigned value"
        )
      } else if not fitsUnsignedWidth(n, width) {
        Err(error = "the constant " + longToString(n) + " does not fit " + intToString(width) + " unsigned bits")
      } else {
        Ok(value = TLit(value = VLBitVec(bits = n, width = width), sort = bvSort))
      }
    }
    case TBuiltin(op, args) -> {
      if builtinEq(op, BOpNeg) {
        Err(error = "a negated constant has no " + intToString(width) + "-bit unsigned value")
      } else {
        val coerced: List[Term] = newList()
        var i = 0
        while i < args.count {
          match coerceIntConst(args[i], width) {
            case Ok(c) -> coerced.add(c)
            case Err(r) -> return Err(error = r)
          }
          i = i + 1
        }
        Ok(value = TBuiltin(op = op, args = coerced))
      }
    }
    case TIte(c, a, b) -> {
      match coerceIntConst(a, width) {
        case Ok(a2) -> match coerceIntConst(b, width) {
          case Ok(b2) -> Ok(value = TIte(cond = c, thenT = a2, elseT = b2))
          case Err(r) -> Err(error = r)
        }
        case Err(r) -> Err(error = r)
      }
    }
    case _ -> Err(error = "the operand is not an integer constant")
  }
}

func sortWord(s: in Sort): String {
  match s {
    case SBitVec(w) -> intToString(w) + "-bit unsigned"
    case SInt -> "signed integer"
    case other -> sortDisplay(other)
  }
}

// Convert `t` to `target` where the language converts implicitly (a literal
// taking its context's type, a lossless widening).  Sorts that are not
// integers or bitvectors are left unchanged — the solver reports those.
pub func coerceToSort(t: in Term, target: in Sort): Result[Term, String] {
  val src = sortOf(t)
  match target {
    case SBitVec(w) -> {
      match src {
        case SBitVec(w2) -> {
          if w2 == w {
            Ok(value = t)
          } else if w2 < w {
            Ok(value = TBuiltin(op = BOpZeroExtend(bits = w - w2), args = termList1(t)))
          } else {
            Err(error = "a " + sortWord(src) + " value is used where a " + sortWord(target) + " value is expected")
          }
        }
        case SInt -> {
          if isIntConstTree(t) {
            coerceIntConst(t, w)
          } else {
            Err(error = "a signed integer value is used where a " + sortWord(target) + " value is expected")
          }
        }
        case _ -> Ok(value = t)
      }
    }
    case SInt -> {
      match src {
        case SBitVec(w) -> {
          if w == 8 {
            Ok(value = TBuiltin(op = BOpBvToNat, args = termList1(t)))
          } else {
            Err(error = "a " + sortWord(src) + " value is used where a signed integer value is expected")
          }
        }
        case _ -> Ok(value = t)
      }
    }
    case _ -> Ok(value = t)
  }
}

pub record OperandPair {
  pub lhs: Term
  pub rhs: Term
}

// Bring two operands of an arithmetic, ordering or equality builtin to one
// sort.
pub func unifyOperands(a: in Term, b: in Term): Result[OperandPair, String] {
  val sa = sortOf(a)
  val sb = sortOf(b)
  match sa {
    case SBitVec(wa) -> {
      match sb {
        case SBitVec(wb) -> {
          if wa == wb {
            Ok(value = OperandPair(lhs = a, rhs = b))
          } else if wa < wb {
            match coerceToSort(a, sb) {
              case Ok(a2) -> Ok(value = OperandPair(lhs = a2, rhs = b))
              case Err(r) -> Err(error = r)
            }
          } else {
            match coerceToSort(b, sa) {
              case Ok(b2) -> Ok(value = OperandPair(lhs = a, rhs = b2))
              case Err(r) -> Err(error = r)
            }
          }
        }
        case SInt -> unifyBitVecWithInt(a, b, wa, false)
        case _ -> Ok(value = OperandPair(lhs = a, rhs = b))
      }
    }
    case SInt -> {
      match sb {
        case SBitVec(wb) -> unifyBitVecWithInt(b, a, wb, true)
        case _ -> Ok(value = OperandPair(lhs = a, rhs = b))
      }
    }
    case _ -> Ok(value = OperandPair(lhs = a, rhs = b))
  }
}

// `bv` has sort `(_ BitVec w)` and `n` sort `Int`; `swapped` says `bv` was
// the right-hand operand.
func unifyBitVecWithInt(bv: in Term, n: in Term, w: in Int, swapped: in Bool): Result[OperandPair, String] {
  if isIntConstTree(n) {
    match coerceIntConst(n, w) {
      case Ok(n2) -> Ok(value = orderedPair(bv, n2, swapped))
      case Err(r) -> Err(error = r)
    }
  } else if w == 8 {
    Ok(value = orderedPair(TBuiltin(op = BOpBvToNat, args = termList1(bv)), n, swapped))
  } else {
    Err(error = "an operation mixes a " + intToString(w) + "-bit unsigned operand with a signed integer operand")
  }
}

func orderedPair(first: in Term, second: in Term, swapped: in Bool): OperandPair {
  if swapped {
    OperandPair(lhs = second, rhs = first)
  } else {
    OperandPair(lhs = first, rhs = second)
  }
}

// Reconcile every sort-unifying builtin and `ite` in `t`, bottom-up.  Run on
// each goal after VC generation: substitution (a parameter replaced by a
// call's argument, `result` by the returned value) can bring an `Int`
// constant next to a bitvector after the expression itself was translated.
// A bitvector negation is rejected — no Lyric unsigned type has a unary
// minus.
pub func reconcileTermSorts(t: in Term): Result[Term, String] {
  match t {
    case TVar(_, _) -> Ok(value = t)
    case TLit(_, _) -> Ok(value = t)
    case TBuiltin(op, args) -> {
      val rargs: List[Term] = newList()
      var i = 0
      while i < args.count {
        match reconcileTermSorts(args[i]) {
          case Ok(a) -> rargs.add(a)
          case Err(r) -> return Err(error = r)
        }
        i = i + 1
      }
      if builtinEq(op, BOpNeg) and rargs.count == 1 and isBitVecTerm(rargs[0]) {
        return Err(error = "an unsigned value is negated")
      }
      if isSortUnifyingBuiltin(op) and rargs.count == 2 {
        match unifyOperands(rargs[0], rargs[1]) {
          case Ok(p) -> Ok(value = TBuiltin(op = op, args = termList2(p.lhs, p.rhs)))
          case Err(r) -> Err(error = r)
        }
      } else if builtinEq(op, BOpIte) and rargs.count == 3 {
        match unifyOperands(rargs[1], rargs[2]) {
          case Ok(p) -> Ok(value = TBuiltin(op = op, args = termList3(rargs[0], p.lhs, p.rhs)))
          case Err(r) -> Err(error = r)
        }
      } else {
        Ok(value = TBuiltin(op = op, args = rargs))
      }
    }
    case TApp(name, args, rs) -> {
      val rargs: List[Term] = newList()
      var i = 0
      while i < args.count {
        match reconcileTermSorts(args[i]) {
          case Ok(a) -> rargs.add(a)
          case Err(r) -> return Err(error = r)
        }
        i = i + 1
      }
      Ok(value = TApp(name = name, args = rargs, retSort = rs))
    }
    case TLet(bindings, body) -> {
      val rbs: List[TermBinding] = newList()
      var i = 0
      while i < bindings.count {
        match reconcileTermSorts(bindings[i].term) {
          case Ok(bt) -> rbs.add(TermBinding(name = bindings[i].name, term = bt))
          case Err(r) -> return Err(error = r)
        }
        i = i + 1
      }
      match reconcileTermSorts(body) {
        case Ok(b2) -> Ok(value = TLet(bindings = rbs, body = b2))
        case Err(r) -> Err(error = r)
      }
    }
    case TIte(c, a, b) -> {
      match reconcileTermSorts(c) {
        case Ok(c2) -> match reconcileTermSorts(a) {
          case Ok(a2) -> match reconcileTermSorts(b) {
            case Ok(b2) -> match unifyOperands(a2, b2) {
              case Ok(p) -> Ok(
                value = TIte(
                  cond = c2,
                  thenT = p.lhs,
                  elseT = p.rhs
                )
              )
              case Err(r) -> Err(error = r)
            }
            case Err(r) -> Err(error = r)
          }
          case Err(r) -> Err(error = r)
        }
        case Err(r) -> Err(error = r)
      }
    }
    case TForall(binders, triggers, body) -> {
      match reconcileTermSorts(body) {
        case Ok(b2) -> Ok(value = TForall(binders = binders, triggers = triggers, body = b2))
        case Err(r) -> Err(error = r)
      }
    }
    case TExists(binders, body) -> {
      match reconcileTermSorts(body) {
        case Ok(b2) -> Ok(value = TExists(binders = binders, body = b2))
        case Err(r) -> Err(error = r)
      }
    }
  }
}

func isBitVecTerm(t: in Term): Bool {
  match sortOf(t) {
    case SBitVec(_) -> true
    case _ -> false
  }
}
