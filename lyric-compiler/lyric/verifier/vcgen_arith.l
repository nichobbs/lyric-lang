//! verifier/vcgen_arith.l — width and overflow obligations, integer width inference, purity.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// @proof_required(checked_arithmetic) on an unsigned `+`, `-` or `*`: the
// modular bitvector result must equal the mathematical one (#7848).  `x +
// y` does not wrap iff `x <= x + y`, `x - y` iff `y <= x`, and `x * y` iff
// `y == 0` or `(x * y) / y == x` — all ordered unsigned.
func unsignedOverflowSideConds(op: in Builtin, x: in Term, y: in Term, product: in Term, w: in Int): List[Term] {
  val sc: List[Term] = newList()
  match op {
    case BOpAdd -> sc.add(TBuiltin(op = BOpLte, args = termList2(x, product)))
    case BOpSub -> sc.add(TBuiltin(op = BOpLte, args = termList2(y, x)))
    case BOpMul -> {
      val zero = TLit(value = VLBitVec(bits = 0i64, width = w), sort = SBitVec(width = w))
      val parts: List[Term] = newList()
      parts.add(TBuiltin(op = BOpEq, args = termList2(y, zero)))
      parts.add(TBuiltin(op = BOpEq, args = termList2(TBuiltin(op = BOpDiv, args = termList2(product, y)), x)))
      sc.add(mkOr(parts))
    }
    case _ -> {
    }
  }
  sc
}

func unitTerm(): Term {
  TLit(value = VLUnit, sort = unitSort())
}

func unitSortInfo(): SortInfo {
  sortInfoNoRange(unitSort())
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Helper: check if function is @pure.
// ─────────────────────────────────────────────────────────────────────────────
func isPure(fn: in FunctionDecl): Bool {
  var i = 0
  while i < fn.annotations.count {
    val a = fn.annotations[i]
    if a.name.segments.count == 1 and a.name.segments[0] == "pure" {
      return true
    }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §4a. Static integer width (#7871).
// ─────────────────────────────────────────────────────────────────────────────
// `Int` and `Long` share the unbounded `Int` sort, so the width an
// overflow obligation checks against comes from the expression's static
// type: a binding's declared type (`SortInfo.intBits`), a field's, a
// callee's result type, a literal's suffix.  Returns 32 or 64, or 0 when
// the expression names no width — an unsuffixed literal, which takes its
// context's type, or a value the verifier does not type.
//
// Combining operands (an arithmetic operator, the branches of an `if` or
// `match`) yields 0 when any of them is a value of unknown width: its type
// may be wider than the others' (`l.value / d` with `d: Int`), and a width
// read as narrower than it is weakens the division obligation and the
// width recorded for a binding (#8107).  An unsuffixed literal operand
// takes the other operands' type and does not count as unknown.
func intBitsOfExpr(env: in VEnv, e: in Expr): Int {
  intBitsOfExprWith(env, e, true)
}

// `unknownWins` false gives the widest known operand's width instead, for
// an overflow obligation only: a result is at least as wide as its widest
// operand, so checking it against that width can only fail a proof.
func intBitsOfExprWith(env: in VEnv, e: in Expr, unknownWins: in Bool): Int {
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LInt(v, suffix, _) -> match suffix {
        case I64 -> 64
        case I32 | I16 | I8 -> 32
        case NoIntSuffix -> {
          // Only a `Long` holds an unsuffixed literal beyond 32 bits.
          if v < signedMinOfBits(32) or v > signedMaxOfBits(32) {
            64
          } else {
            0
          }
        }
        case _ -> 0
      }
      case _ -> 0
    }
    case EParen(inner) -> intBitsOfExprWith(env, inner, unknownWins)
    case EPath(path) -> {
      if path.segments.count == 1 {
        match envLookupSort(path.segments[0], env) {
          case Some(si) -> si.intBits
          case None -> 0
        }
      } else {
        0
      }
    }
    case EResult -> match envLookupSort("result", env) { case Some(si) -> si.intBits; case None -> 0 }
    case ESelf -> match envLookupSort("self", env) { case Some(si) -> si.intBits; case None -> 0 }
    case EOld(inner) -> intBitsOfExprWith(env, inner, unknownWins)
    case EPrefix(op, operand) -> match op { case PreNeg -> intBitsOfExprWith(env, operand, unknownWins); case _ -> 0 }
    case EBinop(op, lhs, rhs) -> match op {
      case BAdd | BSub | BMul | BDiv | BMod -> {
        val parts: List[Expr] = newList()
        parts.add(lhs)
        parts.add(rhs)
        joinIntBits(env, parts, unknownWins)
      }
      case _ -> 0
    }
    case EIf(_, thenBranch, elseBranchOpt, _) -> {
      val parts: List[Expr] = newList()
      addEobValue(parts, thenBranch)
      match elseBranchOpt {
        case Some(eb) -> addEobValue(parts, eb)
        case None -> ()
      }
      joinIntBits(env, parts, unknownWins)
    }
    case EMatch(_, arms) -> {
      val parts: List[Expr] = newList()
      var i = 0
      while i < arms.count {
        addEobValue(parts, arms[i].body)
        i = i + 1
      }
      joinIntBits(env, parts, unknownWins)
    }
    case EBlock(blk) -> match blockLastExpr(blk) {
      case Some(last) -> intBitsOfExprWith(env, last, unknownWins)
      case None -> 0
    }
    case ECall(fn, callArgs) -> match fn.kind {
      case EPath(path) -> {
        val name = joinPathSegments(path.segments)
        if localCallee(env, fn) {
          return 0
        }
        match fileCallee(env, name, callArgs) {
          case Some(decl) -> match decl.ret { case Some(te) -> calleeSortInfo(env, decl, te).intBits; case None -> 0 }
          case None -> {
            // A distinct type's constructor yields its underlying value.
            match fileDistinct(env, name) {
              case Some(under) -> sortOfTypeExprWith(env.distincts, under).intBits
              case None -> 0
            }
          }
        }
      }
      case EMember(receiver, methodName) -> {
        // `T.from(x)` yields a `T`, a value of `T`'s underlying width.
        match distinctFromCallee(env, fn) {
          case Some(tName) -> match mapGet(env.distincts, tName) {
            case Some(under) -> return sortOfTypeExprWith(env.distincts, under).intBits
            case None -> ()
          }
          case None -> ()
        }
        val resolved = match resolveStaticCallee(env, receiver, methodName, callArgs) {
          case Some(rc) -> Some(value = rc)
          case None -> match staticSortOfExpr(env, receiver) {
            case Some(srt) -> resolveMethodCallee(
              env,
              TVar(name = "self", sort = srt),
              methodName,
              callArgs
            )
            case None -> None
          }
        }
        match resolved {
          case Some(rc) -> match rc.decl.ret { case Some(te) -> calleeSortInfo(env, rc.decl, te).intBits; case None -> 0 }
          case None -> 0
        }
      }
      case _ -> 0
    }
    case EMember(receiver, memberName) -> {
      val recName = recordNameOfExpr(env, receiver)
      if recName.length > 0 {
        match mapGet(env.fieldInfos, recName + "__" + memberName) {
          case Some(fi) -> fi.intBits
          case None -> 0
        }
      } else if memberName == "value" {
        // A distinct value's `.value` is its underlying value, of the width
        // the distinct type's binding already records.
        intBitsOfExprWith(env, receiver, unknownWins)
      } else {
        0
      }
    }
    case _ -> 0
  }
}

// The value an `if` branch or `match` arm yields, when it names one.
func addEobValue(parts: in List[Expr], eob: in ExprOrBlock): Unit {
  match eob {
    case EOBExpr(x) -> parts.add(x)
    case EOBBlock(blk) -> match blockLastExpr(blk) { case Some(last) -> parts.add(last); case None -> () }
  }
}

// The width of a value combining `parts`: 0 when one of them is of unknown
// width and `unknownWins`, else the widest known.
func joinIntBits(env: in VEnv, parts: in List[Expr], unknownWins: in Bool): Int {
  var bits = 0
  var i = 0
  while i < parts.count {
    val b = intBitsOfExprWith(env, parts[i], unknownWins)
    if b == 0 and unknownWins and not adoptsContextWidth(parts[i]) {
      return 0
    }
    bits = maxInt(bits, b)
    i = i + 1
  }
  bits
}

// An unsuffixed integer literal in `Int`'s range, or arithmetic over only
// such literals: it takes the type its context gives it.
func adoptsContextWidth(e: in Expr): Bool {
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LInt(v, suffix, _) -> match suffix {
        case NoIntSuffix -> v >= signedMinOfBits(32) and
          v <= signedMaxOfBits(32)
        case _ -> false
      }
      case _ -> false
    }
    case EParen(inner) -> adoptsContextWidth(inner)
    case EPrefix(op, operand) -> match op { case PreNeg -> adoptsContextWidth(operand); case _ -> false }
    case EBinop(op, lhs, rhs) -> match op {
      case BAdd | BSub | BMul | BDiv | BMod -> adoptsContextWidth(lhs) and
        adoptsContextWidth(rhs)
      case _ -> false
    }
    case _ -> false
  }
}

// The record datatype an expression's value belongs to, or "" when it is
// not a known record: a binding of a record sort, or a field of one.
func recordNameOfExpr(env: in VEnv, e: in Expr): String {
  match staticSortOfExpr(env, e) {
    case Some(srt) -> match srt {
      case SDatatype(rName, _) -> match findRecordFields(env, rName) {
        case Some(_) -> rName
        case None -> ""
      }
      case _ -> ""
    }
    case None -> ""
  }
}

// The sort info of an expression that names a binding, without translating
// it; `None` for anything else.
func staticSortInfoOfExpr(env: in VEnv, e: in Expr): Option[SortInfo] {
  match e.kind {
    case EParen(inner) -> staticSortInfoOfExpr(env, inner)
    case EPath(path) -> if path.segments.count == 1 { envLookupSort(path.segments[0], env) } else { None }
    case ESelf -> envLookupSort("self", env)
    // A distinct value's `.value` has the distinct type's width and range.
    case EMember(receiver, memberName) -> {
      if memberName == "value" and recordNameOfExpr(env, receiver).length == 0 {
        match staticSortInfoOfExpr(env, receiver) {
          case Some(si) -> if isPrimitiveSort(si.sort) { Some(value = si) } else { None }
          case None -> None
        }
      } else {
        None
      }
    }
    case _ -> None
  }
}

// The sort of a binding, `result`, or a record field read from one, without
// translating the expression.
func staticSortOfExpr(env: in VEnv, e: in Expr): Option[Sort] {
  match e.kind {
    case EParen(inner) -> staticSortOfExpr(env, inner)
    case EPath(path) -> {
      if path.segments.count == 1 {
        match envLookupSort(path.segments[0], env) {
          case Some(si) -> Some(value = si.sort)
          case None -> None
        }
      } else {
        None
      }
    }
    case EResult -> match envLookupSort("result", env) { case Some(si) -> Some(value = si.sort); case None -> None }
    case ESelf -> match envLookupSort("self", env) { case Some(si) -> Some(value = si.sort); case None -> None }
    case EMember(receiver, memberName) -> {
      if recordNameOfExpr(env, receiver).length > 0 {
        match staticSortOfExpr(env, receiver) {
          case Some(recvSort) -> findRecordFieldSort(env, recvSort, memberName)
          case None -> None
        }
      } else {
        None
      }
    }
    case _ -> None
  }
}

func joinPathSegments(segs: in List[String]): String {
  var name = ""
  var j = 0
  while j < segs.count {
    if j > 0 {
      name = name + "."
    }
    name = name + segs[j]
    j = j + 1
  }
  name
}

func maxInt(a: in Int, b: in Int): Int {
  if a > b {
    a
  } else {
    b
  }
}

// The width an overflow obligation checks `e` against: its static width,
// or `Int`'s when it names none — an expression of unsuffixed literals is
// an `Int` unless its context makes it a `Long`, and checking a `Long`
// against the narrower range can only fail a proof, never pass a wrong
// one (#7871).
func overflowBitsOfExpr(env: in VEnv, e: in Expr): Int {
  val b = intBitsOfExprWith(env, e, false)
  if b == 0 {
    32
  } else {
    b
  }
}
