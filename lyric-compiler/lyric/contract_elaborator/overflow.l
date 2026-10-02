//! Integer overflow checking (D163).
//!
//! `+`, `-`, `*` and unary `-` on `Int`, `Long`, `UInt`, `ULong` and `Byte`
//! panic on overflow in a `debug` build and wrap in a `release` build; the
//! standard library always wraps (`Lyric.Pipeline.markWrappingArith`).  Every
//! backend's arithmetic wraps, so a checked build rewrites each site the type
//! checker recorded (`SymbolTable.overflowSites`) into the wrapping operation
//! followed by an overflow test:
//!
//!   a + b   ->   {
//!                  val __lyric_ov_<s>_<e>_a: Int = a
//!                  val __lyric_ov_<s>_<e>_b: Int = b
//!                  val __lyric_ov_<s>_<e>_r: Int = <a> + <b>
//!                  if (<a>.xor(<r>)).and(<b>.xor(<r>)) < 0 {
//!                    panic("arithmetic overflow: Int addition")
//!                  }
//!                  <r>
//!                }
//!
//! so each operand is evaluated once, left to right, the panic message is the
//! same on every target, and no backend changes.  The synthesized operators
//! carry zero-width spans, which no recorded site has, so they are left as
//! the wrapping operators they are.  `x op= y` becomes `x = <the same block>`
//! with `y` bound before `x` is read, the order the unchecked compound
//! assignment uses (#7005); a target that is not a side-effect-free path is
//! first bound to typed temporaries (`SymbolTable.overflowCompoundTemps`).  `.wrappingAdd(y)` and
//! its siblings become the plain operator in every build.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

pub func lowerOverflowChecks(
  file: in SourceFile,
  sites: in Map[String, String],
  compoundTemps: in Map[String, CompoundTemps],
  checked: in Bool,
): SourceFile {
  if sites.count == 0 {
    return file
  }
  mapFileAndContracts(
    file,
    { e: Expr -> rewriteOverflowExpr(e, sites, checked) },
    { s: Statement -> rewriteOverflowStmt(s, sites, compoundTemps, checked) }
  )
}

func rewriteOverflowExpr(e: in Expr, sites: in Map[String, String], checked: in Bool): Expr {
  match mapGet(sites, recordCopySiteKey(e.span)) {
    case None -> e
    case Some(kind) -> {
      val colon = match Str.indexOf(kind, ":") { case Some(c) -> c; case None -> return e }
      val what = Str.substring(kind, 0, colon)
      val tn = Str.substring(kind, colon + 1, kind.length - colon - 1)
      if what == "wrap" {
        return wrappingCall(e, tn)
      }
      if not checked {
        return e
      }
      match e.kind {
        case EBinop(op, lhs, rhs) -> checkedBinop(tn, op, lhs, rhs, false, e.span)
        case EPrefix(op, inner) -> match op { case PreNeg -> checkedNeg(tn, inner, e.span); case _ -> e }
        case _ -> e
      }
    }
  }
}

// `x.wrappingAdd(y)` -> `x + y` (likewise `Sub`, `Mul`), `x.wrappingNeg()`
// -> `0 - x`, each with a synthetic span so no check is added.
func wrappingCall(e: in Expr, tn: in String): Expr {
  val sp = syntheticSpan(e.span)
  match e.kind {
    case ECall(fn, args) -> match fn.kind {
      case EMember(recv, name) -> {
        if name == "wrappingNeg" {
          return mkExpr(EBinop(op = BSub, lhs = typedIntLit(tn, 0i64, sp), rhs = recv), sp)
        }
        if args.count != 1 {
          return e
        }
        val arg = match args[0] { case CAPositional(x) -> x; case CANamed(_, x, _) -> x }
        val op = if name == "wrappingAdd" { BAdd } else if name == "wrappingSub" { BSub } else { BMul }
        mkExpr(EBinop(op = op, lhs = recv, rhs = arg), sp)
      }
      case _ -> e
    }
    case _ -> e
  }
}

func rewriteOverflowStmt(
  s: in Statement,
  sites: in Map[String, String],
  compoundTemps: in Map[String, CompoundTemps],
  checked: in Bool,
): Statement {
  if not checked {
    return s
  }
  match s.kind {
    case SAssign(target, op, value) -> {
      val bop = match op { case AssPlus -> BAdd; case AssMinus -> BSub; case AssStar -> BMul; case _ -> return s }
      val key = recordCopySiteKey(s.span)
      val tn = match mapGet(sites, key) {
        case Some(kind) -> if Str.startsWith(kind, "compound:") {
          Str.substring(kind, 9, kind.length - 9)
        } else {
          return s
        }
        case None -> return s
      }
      match mapGet(compoundTemps, key) {
        case None -> mkStmt(
          SAssign(target = target, op = AssEq, value = checkedBinop(tn, bop, target, value, true, s.span)),
          s.span
        )
        case Some(temps) -> compoundViaTemps(tn, bop, target, value, temps, s.span)
      }
    }
    case _ -> s
  }
}

// `recv[idx] op= v` with an impure receiver or index:
//   { val <t> = recv; val <i> = idx; <t>[<i>] = <checked <t>[<i>] op v> }
// `recv.f op= v` likewise with only the receiver bound.
func compoundViaTemps(
  tn: in String,
  bop: in BinOp,
  target: in Expr,
  value: in Expr,
  temps: in CompoundTemps,
  sp: in Span,
): Statement {
  val wsp = syntheticSpan(sp)
  val base = tempBase(sp)
  val stmts: List[Statement] = newList()
  val newTarget = match target.kind {
    case EIndex(recv, idxs) -> {
      stmts.add(typedLocal(base + "_t", temps.recvType, recv, wsp))
      val newIdxs: List[Expr] = newList()
      var i = 0
      while i < idxs.count {
        val iname = base + "_i" + toString(i)
        val ity = if idxs.count == 1 { temps.indexType } else { None }
        stmts.add(typedLocal(iname, ity, idxs[i], wsp))
        newIdxs.add(localRef(iname, wsp))
        i = i + 1
      }
      mkExpr(EIndex(receiver = localRef(base + "_t", wsp), indices = newIdxs), target.span)
    }
    case EMember(recv, name) -> {
      stmts.add(typedLocal(base + "_t", temps.recvType, recv, wsp))
      mkExpr(EMember(receiver = localRef(base + "_t", wsp), memberName = name), target.span)
    }
    case _ -> target
  }
  stmts.add(
    mkStmt(SAssign(target = newTarget, op = AssEq, value = checkedBinop(tn, bop, newTarget, value, true, sp)), wsp)
  )
  mkStmt(SExpr(expr = mkExpr(EBlock(block = Block(statements = stmts, span = wsp)), wsp)), sp)
}

// `lhs op rhs` on `tn`, panicking on overflow.  A compound assignment
// (`rhsFirst`) evaluates its right-hand side before it reads the target, as
// the unchecked `x op= y` does (#7005).
func checkedBinop(tn: in String, op: in BinOp, lhs: in Expr, rhs: in Expr, rhsFirst: Bool, sp: in Span): Expr {
  val wsp = syntheticSpan(sp)
  val base = tempBase(sp)
  val aName = base + "_a"
  val bName = base + "_b"
  val rName = base + "_r"
  val stmts: List[Statement] = newList()
  val ty = Some(value = primTypeExpr(tn, wsp))
  if rhsFirst {
    stmts.add(typedLocal(bName, ty, rhs, wsp))
    stmts.add(typedLocal(aName, ty, lhs, wsp))
  } else {
    stmts.add(typedLocal(aName, ty, lhs, wsp))
    stmts.add(typedLocal(bName, ty, rhs, wsp))
  }
  val a = localRef(aName, wsp)
  val b = localRef(bName, wsp)
  val r = localRef(rName, wsp)
  val signed = tn == "Int" or tn == "Long"
  val opWord = match op { case BAdd -> "addition"; case BSub -> "subtraction"; case _ -> "multiplication" }
  val msg = "arithmetic overflow: " + tn + " " + opWord
  match op {
    case BMul -> {
      if tn == "Int" or tn == "UInt" or tn == "Byte" {
        // Multiply in the next wider type, which cannot overflow, and check
        // the product against this type's range.
        val wide = if tn == "Int" { "Long" } else if tn == "UInt" { "ULong" } else { "Int" }
        val wName = base + "_w"
        val prod = bin(BMul, widenTo(tn, a, wsp), widenTo(tn, b, wsp), wsp)
        stmts.add(typedLocal(wName, Some(value = primTypeExpr(wide, wsp)), prod, wsp))
        val w = localRef(wName, wsp)
        val outOfRange = if tn == "Int" {
          bin(
            BOr,
            bin(BLt, w, typedIntLit("Long", 0i64 - 2147483648i64, wsp), wsp),
            bin(BGt, w, typedIntLit("Long", 2147483647i64, wsp), wsp),
            wsp
          )
        } else if tn == "UInt" {
          bin(BGt, unsignedOf("ULong", w, wsp), typedIntLit("ULong", 4294967295i64, wsp), wsp)
        } else {
          bin(BGt, w, typedIntLit("Int", 255i64, wsp), wsp)
        }
        stmts.add(panicIf(outOfRange, msg, wsp))
      } else if tn == "Long" {
        stmts.add(typedLocal(rName, ty, bin(BMul, a, b, wsp), wsp))
        val minusOne = typedIntLit("Long", 0i64 - 1i64, wsp)
        val zero = typedIntLit("Long", 0i64, wsp)
        val minLong = typedIntLit("Long", 0i64 - 9223372036854775807i64 - 1i64, wsp)
        // `a == -1` is tested apart: `r / a` would itself overflow for
        // `r == MinValue`.
        val minByMinusOne = bin(BAnd, bin(BEq, a, minusOne, wsp), bin(BEq, b, minLong, wsp), wsp)
        val divCheck = bin(
          BAnd,
          bin(BAnd, bin(BNeq, a, zero, wsp), bin(BNeq, a, minusOne, wsp), wsp),
          bin(BNeq, bin(BDiv, r, a, wsp), b, wsp),
          wsp
        )
        stmts.add(panicIf(bin(BOr, minByMinusOne, divCheck, wsp), msg, wsp))
        stmts.add(mkStmt(SExpr(expr = r), wsp))
        return blockOf(stmts, wsp)
      } else {
        // ULong: `a != 0 and r / a != b` (unsigned division).
        stmts.add(typedLocal(rName, ty, bin(BMul, a, b, wsp), wsp))
        val zero = typedIntLit("ULong", 0i64, wsp)
        val quotient = bin(BDiv, unsignedOf("ULong", r, wsp), unsignedOf("ULong", a, wsp), wsp)
        stmts.add(panicIf(bin(BAnd, bin(BNeq, a, zero, wsp), bin(BNeq, quotient, b, wsp), wsp), msg, wsp))
        stmts.add(mkStmt(SExpr(expr = r), wsp))
        return blockOf(stmts, wsp)
      }
      stmts.add(typedLocal(rName, ty, bin(BMul, a, b, wsp), wsp))
      stmts.add(mkStmt(SExpr(expr = r), wsp))
      blockOf(stmts, wsp)
    }
    case _ -> {
      stmts.add(typedLocal(rName, ty, bin(op, a, b, wsp), wsp))
      val overflowed = if signed {
        val zero = typedIntLit(tn, 0i64, wsp)
        match op {
          // The result's sign differs from both operands' signs.
          case BAdd -> bin(BLt, method1(bitXor(a, r, wsp), "and", bitXor(b, r, wsp), wsp), zero, wsp)
          // The operands' signs differ and the result's differs from `a`'s.
          case _ -> bin(BLt, method1(bitXor(a, b, wsp), "and", bitXor(a, r, wsp), wsp), zero, wsp)
        }
      } else if tn == "Byte" {
        match op {
          case BAdd -> bin(BGt, bin(BAdd, toIntOf(a, wsp), toIntOf(b, wsp), wsp), typedIntLit("Int", 255i64, wsp), wsp)
          case _ -> bin(BLt, toIntOf(a, wsp), toIntOf(b, wsp), wsp)
        }
      } else {
        // An unsigned comparison: each operand is spelled through its
        // identity conversion, which is how every backend tells an unsigned
        // compare from a signed one (#7812).
        match op {
          case BAdd -> bin(BLt, unsignedOf(tn, r, wsp), unsignedOf(tn, a, wsp), wsp)
          case _ -> bin(BLt, unsignedOf(tn, a, wsp), unsignedOf(tn, b, wsp), wsp)
        }
      }
      stmts.add(panicIf(overflowed, msg, wsp))
      stmts.add(mkStmt(SExpr(expr = r), wsp))
      blockOf(stmts, wsp)
    }
  }
}

// `-x` on `Int` / `Long`, panicking on the minimum value.
func checkedNeg(tn: in String, inner: in Expr, sp: in Span): Expr {
  val wsp = syntheticSpan(sp)
  val aName = tempBase(sp) + "_a"
  val stmts: List[Statement] = newList()
  stmts.add(typedLocal(aName, Some(value = primTypeExpr(tn, wsp)), inner, wsp))
  val a = localRef(aName, wsp)
  val minValue = if tn == "Int" {
    typedIntLit("Int", 0i64 - 2147483648i64, wsp)
  } else {
    typedIntLit("Long", 0i64 - 9223372036854775807i64 - 1i64, wsp)
  }
  stmts.add(panicIf(bin(BEq, a, minValue, wsp), "arithmetic overflow: " + tn + " negation", wsp))
  stmts.add(mkStmt(SExpr(expr = mkExpr(EBinop(op = BSub, lhs = typedIntLit(tn, 0i64, wsp), rhs = a), wsp)), wsp))
  blockOf(stmts, wsp)
}

// ── AST helpers ─────────────────────────────────────────────────────────────
func tempBase(sp: in Span): String {
  "__lyric_ov_" + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset)
}

func bin(op: in BinOp, l: in Expr, r: in Expr, sp: in Span): Expr {
  mkExpr(EBinop(op = op, lhs = l, rhs = r), sp)
}

func method1(recv: in Expr, name: in String, arg: in Expr, sp: in Span): Expr {
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = arg))
  mkExpr(ECall(fn = mkExpr(EMember(receiver = recv, memberName = name), sp), args = args), sp)
}

func method0(recv: in Expr, name: in String, sp: in Span): Expr {
  val args: List[CallArg] = newList()
  mkExpr(ECall(fn = mkExpr(EMember(receiver = recv, memberName = name), sp), args = args), sp)
}

func bitXor(a: in Expr, b: in Expr, sp: in Span): Expr = method1(a, "xor", b, sp)

func toIntOf(e: in Expr, sp: in Span): Expr = method0(e, "toInt", sp)

// `e` (a `UInt` or `ULong`) spelled through its identity conversion.
func unsignedOf(tn: in String, e: in Expr, sp: in Span): Expr {
  method0(e, if tn == "UInt" { "toUInt" } else { "toULong" }, sp)
}

// `e` widened to the type `checkedBinop` multiplies `tn` in.
func widenTo(tn: in String, e: in Expr, sp: in Span): Expr {
  if tn == "Int" {
    method0(e, "toLong", sp)
  } else if tn == "UInt" {
    method0(e, "toULong", sp)
  } else {
    method0(e, "toInt", sp)
  }
}

func panicIf(cond: in Expr, msg: in String, sp: in Span): Statement {
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = mkExpr(ELiteral(lit = LString(text = msg)), sp)))
  val call = mkExpr(ECall(fn = localRef("panic", sp), args = args), sp)
  val thenStmts: List[Statement] = newList()
  thenStmts.add(mkStmt(SExpr(expr = call), sp))
  val ifE = mkExpr(
    EIf(
      cond = cond,
      thenBranch = EOBBlock(block = Block(statements = thenStmts, span = sp)),
      elseBranch = None,
      thenForm = false
    ),
    sp
  )
  mkStmt(SExpr(expr = ifE), sp)
}

func blockOf(stmts: in List[Statement], sp: in Span): Expr {
  mkExpr(EBlock(block = Block(statements = stmts, span = sp)), sp)
}

func typedLocal(name: in String, ty: in Option[TypeExpr], init: in Expr, sp: in Span): Statement {
  val pat = Pattern(kind = PBinding(name = name, inner = None), span = sp)
  mkStmt(SLocal(binding = LBVal(pat = pat, ty = ty, init = init)), sp)
}

func localRef(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  mkExpr(EPath(path = ModulePath(segments = segs, span = sp)), sp)
}

func primTypeExpr(tn: in String, sp: in Span): TypeExpr {
  val segs: List[String] = newList()
  segs.add(tn)
  TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = sp)), span = sp)
}

// An integer literal of type `tn`, spelled with that type's suffix.
func typedIntLit(tn: in String, v: in Long, sp: in Span): Expr {
  val suffix = if tn == "Long" {
    I64
  } else if tn == "UInt" {
    U32
  } else if tn == "ULong" {
    U64
  } else if tn == "Byte" {
    U8
  } else {
    I32
  }
  mkExpr(ELiteral(lit = LInt(value = v, suffix = suffix, raw = "")), sp)
}
