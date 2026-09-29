//! const_conds.l — compile-time-true `while` conditions (#7764).
//!
//! `while true` is the documented unconditional loop, and the elaborator
//! treats one that no `break` leaves as never completing normally: no
//! fall-off postcondition check after it, no exit invariant check (#7759).
//! A condition that is just as constant but spelled otherwise — a module
//! `val`/`const` bound to `true`, `1 == 1`, `not false` — must be treated
//! the same, so before elaboration every such condition is folded and
//! replaced by the literal `true` it always evaluates to.
//!
//! The fold is deliberately narrow and sound:
//!   * Bool literals, `not`, `and`/`or` (short-circuiting on a constant left
//!     operand), `==`/`!=` on two constant Bools or two constant integers,
//!     and `<`/`<=`/`>`/`>=` on two constant integers.
//!   * Integers are signed literals (optionally negated) only — no
//!     arithmetic, whose overflow behaviour depends on the operand type.
//!   * A bare name folds only when it is a module-level `val`/`const` of
//!     this file declared exactly once, and no parameter, local, pattern
//!     binding, lambda parameter, catch binding, quantifier binder or field
//!     anywhere in the file uses the same name — so a shadowing `var` (or any
//!     other binding) is never mistaken for the module constant.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

union CondConst {
  case CCBool(value: Bool)
  case CCInt(value: Long)
  case CCUnknown
}

/// Replaces every `while` condition that folds to the constant `true` with
/// the literal `true` (span preserved).
pub func canonicalizeConstantLoopConds(file: in SourceFile): SourceFile {
  val env = foldableModuleConsts(file)
  mapStmtsInFile(
    file,
    { s: Statement ->
      match s.kind {
        case SWhile(label, cond, body) -> {
          if not isLiteralTrue(cond) and isConstantTrueCond(cond, env) {
            val lit = Expr(kind = ELiteral(lit = LBool(value = true)), span = cond.span)
            Statement(kind = SWhile(label = label, cond = lit, body = body), span = s.span)
          } else {
            s
          }
        }
        case _ -> s
      }
    }
  )
}

/// Whether `cond` folds to `true` under `env` (name → initializer of a
/// foldable module constant).
pub func isConstantTrueCond(cond: in Expr, env: in Map[String, Expr]): Bool {
  match foldCond(cond, env, 0) {
    case CCBool(v) -> v
    case _ -> false
  }
}

/// The module-level `val`/`const` initializers a bare name may be folded
/// through: declared once at module level, and never re-bound anywhere in
/// the file.
pub func foldableModuleConsts(file: in SourceFile): Map[String, Expr] {
  val counts: Map[String, Int] = newMap()
  val inits: Map[String, Expr] = newMap()
  for it in file.items {
    match it.kind {
      case IVal(decl) -> match decl.pattern.kind {
        case PBinding(name, None) -> {
          bumpCount(counts, name)
          inits[name] = decl.init
        }
        case _ -> ()
      }
      case IConst(decl) -> {
        bumpCount(counts, decl.name)
        inits[decl.name] = decl.init
      }
      case IFunc(decl) -> bumpCount(counts, decl.name)
      case IFixture(decl) -> bumpCount(counts, decl.name)
      case _ -> ()
    }
  }
  val bound = localBoundNames(file)
  val env: Map[String, Expr] = newMap()
  for name in mapKeys(inits) {
    val once = match mapGet(counts, name) { case Some(c) -> c == 1; case None -> false }
    if once and not bound.containsKey(name) {
      match mapGet(inits, name) {
        case Some(e) -> {
          env[name] = e
        }
        case None -> ()
      }
    }
  }
  env
}

func bumpCount(counts: in Map[String, Int], name: in String): Unit {
  match mapGet(counts, name) {
    case Some(c) -> {
      counts[name] = c + 1
    }
    case None -> {
      counts[name] = 1
    }
  }
}

func foldCond(e: in Expr, env: in Map[String, Expr], depth: in Int): CondConst {
  if depth > 32 {
    return CCUnknown
  }
  match e.kind {
    case EParen(inner) -> foldCond(inner, env, depth)
    case ELiteral(lit) -> match lit {
      case LBool(v) -> CCBool(value = v)
      case LInt(v, suffix, _) -> if isSignedSuffix(suffix) and v >= 0i64 {
        CCInt(value = v)
      } else {
        CCUnknown
      }
      case _ -> CCUnknown
    }
    case EPrefix(op, operand) -> match op {
      case PreNot -> match foldCond(operand, env, depth) {
        case CCBool(v) -> CCBool(value = not v)
        case _ -> CCUnknown
      }
      case PreNeg -> match foldCond(operand, env, depth) {
        case CCInt(v) -> CCInt(value = 0i64 - v)
        case _ -> CCUnknown
      }
      case _ -> CCUnknown
    }
    case EBinop(op, lhs, rhs) -> foldBinop(op, lhs, rhs, env, depth)
    case EPath(path) -> {
      if path.segments.count != 1 {
        return CCUnknown
      }
      match mapGet(env, path.segments[0]) {
        case Some(init) -> foldCond(init, env, depth + 1)
        case None -> CCUnknown
      }
    }
    case _ -> CCUnknown
  }
}

func foldBinop(op: in BinOp, lhs: in Expr, rhs: in Expr, env: in Map[String, Expr], depth: in Int): CondConst {
  val l = foldCond(lhs, env, depth)
  match op {
    // `and`/`or` never evaluate the right operand when the left decides.
    case BAnd -> match l {
      case CCBool(lv) -> if not lv { CCBool(value = false) } else { boolOnly(foldCond(rhs, env, depth)) }
      case _ -> CCUnknown
    }
    case BOr -> match l {
      case CCBool(lv) -> if lv { CCBool(value = true) } else { boolOnly(foldCond(rhs, env, depth)) }
      case _ -> CCUnknown
    }
    case BEq -> equalConsts(l, foldCond(rhs, env, depth), true)
    case BNeq -> equalConsts(l, foldCond(rhs, env, depth), false)
    case BLt -> compareInts(l, foldCond(rhs, env, depth), op)
    case BLte -> compareInts(l, foldCond(rhs, env, depth), op)
    case BGt -> compareInts(l, foldCond(rhs, env, depth), op)
    case BGte -> compareInts(l, foldCond(rhs, env, depth), op)
    case _ -> CCUnknown
  }
}

func boolOnly(c: in CondConst): CondConst {
  match c {
    case CCBool(v) -> CCBool(value = v)
    case _ -> CCUnknown
  }
}

func equalConsts(l: in CondConst, r: in CondConst, wantEqual: in Bool): CondConst {
  match l {
    case CCBool(lv) -> match r { case CCBool(rv) -> CCBool(value = (lv == rv) == wantEqual); case _ -> CCUnknown }
    case CCInt(lv) -> match r { case CCInt(rv) -> CCBool(value = (lv == rv) == wantEqual); case _ -> CCUnknown }
    case CCUnknown -> CCUnknown
  }
}

func compareInts(l: in CondConst, r: in CondConst, op: in BinOp): CondConst {
  match l {
    case CCInt(lv) -> match r {
      case CCInt(rv) -> match op {
        case BLt -> CCBool(value = lv < rv)
        case BLte -> CCBool(value = lv <= rv)
        case BGt -> CCBool(value = lv > rv)
        case BGte -> CCBool(value = lv >= rv)
        case _ -> CCUnknown
      }
      case _ -> CCUnknown
    }
    case _ -> CCUnknown
  }
}

// Unsigned literals are excluded: their stored bit pattern does not order
// like the value once it exceeds the signed range.
func isSignedSuffix(s: in IntSuffix): Bool {
  match s {
    case NoIntSuffix -> true
    case I8 -> true
    case I16 -> true
    case I32 -> true
    case I64 -> true
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Every name bound below module level anywhere in the file.
// ─────────────────────────────────────────────────────────────────────────────
func localBoundNames(file: in SourceFile): Map[String, Bool] {
  val acc: Map[String, Bool] = newMap()
  for it in file.items {
    collectItemBinders(it, acc)
  }
  val _ = mapFileAndContracts(
    file,
    { e: Expr -> collectExprBinders(e, acc); e },
    { s: Statement -> collectStmtBinders(s, acc); s }
  )
  acc
}

func addName(acc: in Map[String, Bool], name: in String): Unit {
  acc[name] = true
}

func collectItemBinders(it: in Item, acc: in Map[String, Bool]): Unit {
  match it.kind {
    case IFunc(fn) -> collectParams(fn.params, acc)
    case IRecord(decl) -> collectRecordBinders(decl, acc)
    case IExposedRec(decl) -> collectRecordBinders(decl, acc)
    case IOpaque(decl) -> {
      for m in decl.members {
        match m {
          case OMField(fd) -> addName(acc, fd.name)
          case _ -> ()
        }
      }
    }
    case IImpl(decl) -> {
      for m in decl.members {
        match m {
          case IMplFunc(fn) -> collectParams(fn.params, acc)
          case _ -> ()
        }
      }
    }
    case IInterface(decl) -> {
      for m in decl.members {
        match m {
          case IMFunc(fn) -> collectParams(fn.params, acc)
          case _ -> ()
        }
      }
    }
    case IProtected(decl) -> {
      for m in decl.members {
        match m {
          case PMEntry(ed) -> collectParams(ed.params, acc)
          case PMFunc(fn) -> collectParams(fn.params, acc)
          case PMField(pf) -> match pf {
            case PFVar(name, _, _, _, _, _) -> addName(acc, name)
            case PFLet(name, _, _, _, _, _) -> addName(acc, name)
            case PFImmutable(fd) -> addName(acc, fd.name)
          }
          case _ -> ()
        }
      }
    }
    case IProperty(decl) -> {
      for b in decl.forAll {
        addName(acc, b.name)
      }
    }
    case _ -> ()
  }
}

func collectRecordBinders(decl: in RecordDecl, acc: in Map[String, Bool]): Unit {
  for m in decl.members {
    match m {
      case RMField(fd) -> addName(acc, fd.name)
      case RMFunc(fn) -> collectParams(fn.params, acc)
      case _ -> ()
    }
  }
}

func collectParams(ps: in List[Param], acc: in Map[String, Bool]): Unit {
  for p in ps {
    addName(acc, p.name)
  }
}

func collectExprBinders(e: in Expr, acc: in Map[String, Bool]): Unit {
  match e.kind {
    case ELambda(ps, _) -> {
      for p in ps {
        addName(acc, p.name)
      }
    }
    case EMatch(_, arms) -> {
      for a in arms {
        collectPatternBinders(a.pattern, acc)
      }
    }
    case EForall(bs, _, _) -> {
      for b in bs {
        addName(acc, b.name)
      }
    }
    case EExists(bs, _, _) -> {
      for b in bs {
        addName(acc, b.name)
      }
    }
    case _ -> ()
  }
}

func collectStmtBinders(s: in Statement, acc: in Map[String, Bool]): Unit {
  match s.kind {
    case SLocal(binding) -> match binding {
      case LBVal(pat, _, _) -> collectPatternBinders(pat, acc)
      case LBVar(name, _, _) -> addName(acc, name)
      case LBLet(name, _, _) -> addName(acc, name)
    }
    case SFor(_, pat, _, _) -> collectPatternBinders(pat, acc)
    case STry(_, catches, _) -> {
      for c in catches {
        match c.bindName {
          case Some(n) -> addName(acc, n)
          case None -> ()
        }
      }
    }
    case _ -> ()
  }
}

func collectPatternBinders(p: in Pattern, acc: in Map[String, Bool]): Unit {
  match p.kind {
    case PBinding(name, inner) -> {
      addName(acc, name)
      match inner {
        case Some(ip) -> collectPatternBinders(ip, acc)
        case None -> ()
      }
    }
    case PConstructor(_, args) -> {
      for a in args {
        collectPatternBinders(a, acc)
      }
    }
    case PRecord(_, fields, _) -> {
      for f in fields {
        match f {
          case RPFNamed(_, fp, _) -> collectPatternBinders(fp, acc)
          case RPFShort(name, _) -> addName(acc, name)
        }
      }
    }
    case PTuple(ps) -> {
      for q in ps {
        collectPatternBinders(q, acc)
      }
    }
    case PParen(ip) -> collectPatternBinders(ip, acc)
    case PTypeTest(ip, _) -> collectPatternBinders(ip, acc)
    case POr(ps) -> {
      for q in ps {
        collectPatternBinders(q, acc)
      }
    }
    case _ -> ()
  }
}
