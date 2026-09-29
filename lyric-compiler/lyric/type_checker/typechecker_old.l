//! typechecker_old.l — `old(...)` placement check (T0080).
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// `old(e)` placement (T0080, #7731).  `old` names the value `e` had at
// function entry, and only a postcondition can compare against it: it is
// valid solely inside an `ensures:` clause — of a function, a method, an
// interface or extern signature, a protected `entry`/`func`, or an aspect
// (docs/08-contract-semantics.md §3, §4.4).  The contract elaborator
// snapshots exactly the `old` operands of `ensures:` clauses; any other
// `old` would otherwise survive to codegen, which has no lowering for it.
//
// `pos` is "" inside an `ensures:` clause and otherwise describes the
// enclosing position for the diagnostic.  `inOld` is true inside an `old`
// operand, which must itself be evaluable at entry: no nested `old`, no
// `result`.
pub func checkOldPlacement(diag: in List[Diagnostic], file: in SourceFile): Unit {
  var i = 0
  while i < file.items.count {
    oldItem(diag, file.items[i])
    i = i + 1
  }
}

func oldItem(diag: in List[Diagnostic], it: in Item): Unit {
  match it.kind {
    case IConst(decl) -> {
      oldType(diag, decl.ty)
      oldExpr(diag, "a `const` initializer", false, decl.init)
    }
    case IVal(decl) -> {
      oldTypeOpt(diag, decl.ty)
      oldExpr(diag, "a module-level `val` initializer", false, decl.init)
    }
    case IFunc(decl) -> oldFunction(diag, decl)
    case IDistinctType(decl) -> oldDistinct(diag, decl)
    case ITypeAlias(decl) -> oldTypeAlias(diag, decl)
    case IRecord(decl) -> oldRecord(diag, decl)
    case IExposedRec(decl) -> oldRecord(diag, decl)
    case IUnion(decl) -> oldUnion(diag, decl)
    case IEnum(_) -> ()
    case IOpaque(decl) -> oldOpaque(diag, decl)
    case IProtected(decl) -> {
      oldGenerics(diag, decl.generics, decl.whereClause)
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case PMField(pf) -> match pf {
            case PFVar(_, ty, init, _, _, _) -> {
              oldType(diag, ty)
              oldExprOpt(diag, "a protected field initializer", init)
            }
            case PFLet(_, ty, init, _, _, _) -> {
              oldType(diag, ty)
              oldExprOpt(diag, "a protected field initializer", init)
            }
            case PFImmutable(fd) -> oldField(diag, fd)
          }
          case PMInvariant(inv) -> oldExpr(diag, "a type `invariant:`", false, inv.expr)
          case PMEntry(ed) -> {
            oldParams(diag, ed.params)
            oldTypeOpt(diag, ed.ret)
            oldContracts(diag, ed.contracts)
            oldBody(diag, "an entry body", ed.body)
          }
          case PMFunc(fn) -> oldFunction(diag, fn)
        }
        i = i + 1
      }
    }
    case IInterface(decl) -> {
      oldGenerics(diag, decl.generics, decl.whereClause)
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMSig(sig) -> oldSig(diag, sig)
          case IMFunc(fn) -> oldFunction(diag, fn)
          case IMAssoc(assoc) -> oldTypeOpt(diag, assoc.dflt)
        }
        i = i + 1
      }
    }
    case IImpl(decl) -> {
      oldGenerics(diag, decl.generics, decl.whereClause)
      oldType(diag, decl.target)
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case IMplFunc(fn) -> oldFunction(diag, fn)
          case IMplAssoc(assoc) -> oldTypeOpt(diag, assoc.dflt)
        }
        i = i + 1
      }
    }
    case IWire(decl) -> {
      oldParams(diag, decl.params)
      var i = 0
      while i < decl.members.count {
        match decl.members[i] {
          case WMProvided(_, ty, _) -> oldType(diag, ty)
          case WMSingleton(_, ty, init, _) -> {
            oldType(diag, ty)
            oldExpr(diag, "a wire binding", false, init)
          }
          case WMScoped(_, _, ty, init, _) -> {
            oldType(diag, ty)
            oldExpr(diag, "a wire binding", false, init)
          }
          case WMBind(iface, provider, _) -> {
            oldType(diag, iface)
            oldExpr(diag, "a wire binding", false, provider)
          }
          case WMLocal(_, ty, init, _) -> {
            oldTypeOpt(diag, ty)
            oldExpr(diag, "a wire binding", false, init)
          }
          case WMContributes(iface, _, init, _, _, _) -> {
            oldType(diag, iface)
            oldExpr(diag, "a wire binding", false, init)
          }
          case WMConfigInst(cd, _) -> oldConfig(diag, cd)
          case WMInclude(_, _, adjustments, _, _) -> oldIncludeAdjustments(diag, adjustments)
          case WMExpose(_, _) -> ()
          case WMOverridable(_, _) -> ()
        }
        i = i + 1
      }
    }
    case IExtern(decl) -> {
      var i = 0
      while i < decl.members.count {
        match decl.members[i].kind {
          case EMSig(sig) -> oldSig(diag, sig)
          case EMRecord(rd) -> oldRecord(diag, rd)
          case EMExposedRec(rd) -> oldRecord(diag, rd)
          case EMOpaque(od) -> oldOpaque(diag, od)
          case EMDistinctType(dd) -> oldDistinct(diag, dd)
          case EMUnion(ud) -> oldUnion(diag, ud)
          case EMTypeAlias(ad) -> oldTypeAlias(diag, ad)
          case EMEnum(_) -> ()
        }
        i = i + 1
      }
    }
    case IExternFunc(decl) -> {
      oldParams(diag, decl.params)
      oldTypeOpt(diag, decl.ret)
    }
    case IExternType(decl) -> oldGenerics(diag, decl.generics, None)
    case ITest(decl) -> oldBlock(diag, "a test body", false, decl.body)
    case IProperty(decl) -> {
      oldBinders(diag, decl.forAll)
      oldExprOpt(diag, "a property guard", decl.guardExpr)
      oldBlock(diag, "a property body", false, decl.body)
    }
    case IFixture(decl) -> {
      oldTypeOpt(diag, decl.ty)
      oldExpr(diag, "a fixture initializer", false, decl.init)
    }
    case IConfig(decl) -> oldConfig(diag, decl)
    case IAspect(decl) -> {
      oldConfigFields(diag, decl.config)
      oldContracts(diag, decl.contracts)
      match decl.around {
        case Some(ar) -> {
          match ar.argsRow {
            case Some(fields) -> {
              var i = 0
              while i < fields.count {
                oldType(diag, fields[i].ty)
                i = i + 1
              }
            }
            case None -> ()
          }
          oldBlock(diag, "an aspect's `around` body", false, ar.body)
        }
        case None -> ()
      }
    }
    // A scope kind declares only a name.
    case IScopeKind(_) -> ()
    case IError -> ()
  }
}

func oldOpaque(diag: in List[Diagnostic], decl: in OpaqueTypeDecl): Unit {
  oldGenerics(diag, decl.generics, decl.whereClause)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case OMField(fd) -> oldField(diag, fd)
      case OMInvariant(inv) -> oldExpr(diag, "a type `invariant:`", false, inv.expr)
    }
    i = i + 1
  }
}

func oldDistinct(diag: in List[Diagnostic], decl: in DistinctTypeDecl): Unit {
  oldGenerics(diag, decl.generics, None)
  oldType(diag, decl.underlying)
  match decl.rangeClause {
    case Some(rb) -> oldRange(diag, "a range subtype's bounds", false, rb)
    case None -> ()
  }
}

func oldTypeAlias(diag: in List[Diagnostic], decl: in TypeAliasDecl): Unit {
  oldGenerics(diag, decl.generics, None)
  oldType(diag, decl.rhs)
}

func oldUnion(diag: in List[Diagnostic], decl: in UnionDecl): Unit {
  oldGenerics(diag, decl.generics, decl.whereClause)
  var i = 0
  while i < decl.cases.count {
    var j = 0
    while j < decl.cases[i].fields.count {
      match decl.cases[i].fields[j] {
        case UFNamed(_, ty, _) -> oldType(diag, ty)
        case UFPos(ty, _) -> oldType(diag, ty)
      }
      j = j + 1
    }
    i = i + 1
  }
}

func oldIncludeAdjustments(diag: in List[Diagnostic], adjs: in List[IncludeAdjust]): Unit {
  var i = 0
  while i < adjs.count {
    match adjs[i] {
      case IAProvided(_, value, _) -> oldExpr(diag, "a wire `include` adjustment", false, value)
      case IAReplace(_, value, _) -> oldExpr(diag, "a wire `include` adjustment", false, value)
      case IAConfigOverride(_, fields, _) -> {
        var j = 0
        while j < fields.count {
          oldExpr(diag, "a wire `include` adjustment", false, fields[j].value)
          j = j + 1
        }
      }
      case IARemove(_, _) -> ()
      case IAReorder(_, _, _) -> ()
    }
    i = i + 1
  }
}

func oldRecord(diag: in List[Diagnostic], decl: in RecordDecl): Unit {
  oldGenerics(diag, decl.generics, decl.whereClause)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(fd) -> oldField(diag, fd)
      case RMInvariant(inv) -> oldExpr(diag, "a type `invariant:`", false, inv.expr)
      case RMFunc(fn) -> oldFunction(diag, fn)
    }
    i = i + 1
  }
}

func oldField(diag: in List[Diagnostic], fd: in FieldDecl): Unit {
  oldType(diag, fd.ty)
  oldExprOpt(diag, "a field default", fd.dflt)
}

func oldConfig(diag: in List[Diagnostic], decl: in ConfigDecl): Unit {
  oldConfigFields(diag, decl.fields)
}

// Shared by module-level `config { }` blocks, config-template instances in a
// wire, and an aspect's inline `config { }` block, whose defaults the weaver
// splices verbatim into every woven function.
func oldConfigFields(diag: in List[Diagnostic], fields: in List[ConfigField]): Unit {
  var i = 0
  while i < fields.count {
    oldType(diag, fields[i].ty)
    oldExprOpt(diag, "a config field default", fields[i].default)
    i = i + 1
  }
}

func oldFunction(diag: in List[Diagnostic], fn: in FunctionDecl): Unit {
  oldGenerics(diag, fn.generics, fn.whereClause)
  oldParams(diag, fn.params)
  oldTypeOpt(diag, fn.ret)
  oldContracts(diag, fn.contracts)
  match fn.body {
    case Some(b) -> oldBody(diag, "a function body", b)
    case None -> ()
  }
}

func oldSig(diag: in List[Diagnostic], sig: in FunctionSig): Unit {
  oldGenerics(diag, sig.generics, sig.whereClause)
  oldParams(diag, sig.params)
  oldTypeOpt(diag, sig.ret)
  oldContracts(diag, sig.contracts)
}

func oldBody(diag: in List[Diagnostic], pos: in String, b: in FunctionBody): Unit {
  match b {
    case FBExpr(e) -> oldExpr(diag, pos, false, e)
    case FBBlock(blk) -> oldBlock(diag, pos, false, blk)
  }
}

func oldParams(diag: in List[Diagnostic], ps: in List[Param]): Unit {
  var i = 0
  while i < ps.count {
    oldType(diag, ps[i].ty)
    oldExprOpt(diag, "a parameter default", ps[i].dflt)
    i = i + 1
  }
}

func oldContracts(diag: in List[Diagnostic], cs: in List[ContractClause]): Unit {
  var i = 0
  while i < cs.count {
    match cs[i] {
      case CCEnsures(e, _) -> oldExpr(diag, "", false, e)
      case CCRequires(e, _) -> oldExpr(diag, "a `requires:` clause", false, e)
      case CCWhen(e, _) -> oldExpr(diag, "a `when:` barrier", false, e)
      case CCDecreases(e, _) -> oldExpr(diag, "a `decreases:` measure", false, e)
      case CCRaises(_, _) -> ()
    }
    i = i + 1
  }
}

func oldExprOpt(diag: in List[Diagnostic], pos: in String, eo: in Option[Expr]): Unit {
  match eo {
    case Some(e) -> oldExpr(diag, pos, false, e)
    case None -> ()
  }
}

func oldBlock(diag: in List[Diagnostic], pos: in String, inOld: in Bool, blk: in Block): Unit {
  var i = 0
  while i < blk.statements.count {
    oldStmt(diag, pos, inOld, blk.statements[i])
    i = i + 1
  }
}

func oldStmt(diag: in List[Diagnostic], pos: in String, inOld: in Bool, stmt: in Statement): Unit {
  match stmt.kind {
    case SBreak(_) -> ()
    case SContinue(_) -> ()
    case SLoop(_, body) -> oldBlock(diag, pos, inOld, body)
    case SFor(_, pat, iter, body) -> {
      oldPattern(diag, pat)
      oldExpr(diag, pos, inOld, iter)
      oldBlock(diag, pos, inOld, body)
    }
    case SWhile(_, cond, body) -> {
      oldExpr(diag, pos, inOld, cond)
      oldBlock(diag, pos, inOld, body)
    }
    case SExpr(e) -> oldExpr(diag, pos, inOld, e)
    case SThrow(e) -> oldExpr(diag, pos, inOld, e)
    case SReturn(v) -> match v { case Some(e) -> oldExpr(diag, pos, inOld, e); case None -> () }
    // A loop invariant describes each iteration's head state, never the
    // function's entry state, so it rejects `old` even when the loop sits in
    // a lambda inside an `ensures:` clause.
    case SInvariant(e) -> oldExpr(diag, "a loop `invariant:`", inOld, e)
    case SItem(it) -> oldItem(diag, it)
    case SAssign(t, _, v) -> {
      oldExpr(diag, pos, inOld, t)
      oldExpr(diag, pos, inOld, v)
    }
    case SLocal(binding) -> match binding {
      case LBVal(pat, ty, e) -> {
        oldPattern(diag, pat)
        oldTypeOpt(diag, ty)
        oldExpr(diag, pos, inOld, e)
      }
      case LBLet(_, ty, e) -> {
        oldTypeOpt(diag, ty)
        oldExpr(diag, pos, inOld, e)
      }
      case LBVar(_, ty, init) -> {
        oldTypeOpt(diag, ty)
        match init {
          case Some(e) -> oldExpr(diag, pos, inOld, e)
          case None -> ()
        }
      }
    }
    case STry(body, catches, finally_) -> {
      oldBlock(diag, pos, inOld, body)
      var i = 0
      while i < catches.count {
        oldBlock(diag, pos, inOld, catches[i].body)
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> oldBlock(diag, pos, inOld, fb)
        case None -> ()
      }
    }
    case SDefer(b) -> oldBlock(diag, pos, inOld, b)
    case SScope(_, b) -> oldBlock(diag, pos, inOld, b)
    case SRule(l, r) -> {
      oldExpr(diag, pos, inOld, l)
      oldExpr(diag, pos, inOld, r)
    }
  }
}

func oldOptBody(diag: in List[Diagnostic], pos: in String, inOld: in Bool, b: in ExprOrBlock): Unit {
  match b {
    case EOBExpr(e) -> oldExpr(diag, pos, inOld, e)
    case EOBBlock(blk) -> oldBlock(diag, pos, inOld, blk)
  }
}

func oldExprs(diag: in List[Diagnostic], pos: in String, inOld: in Bool, es: in List[Expr]): Unit {
  var i = 0
  while i < es.count {
    oldExpr(diag, pos, inOld, es[i])
    i = i + 1
  }
}

func oldRange(diag: in List[Diagnostic], pos: in String, inOld: in Bool, rb: in RangeBound): Unit {
  match rb {
    case RBClosed(a, b) -> {
      oldExpr(diag, pos, inOld, a)
      oldExpr(diag, pos, inOld, b)
    }
    case RBHalfOpen(a, b, _) -> {
      oldExpr(diag, pos, inOld, a)
      oldExpr(diag, pos, inOld, b)
    }
    case RBLowerOpen(a) -> oldExpr(diag, pos, inOld, a)
    case RBUpperOpen(a) -> oldExpr(diag, pos, inOld, a)
  }
}

func oldExpr(diag: in List[Diagnostic], pos: in String, inOld: in Bool, e: in Expr): Unit {
  match e.kind {
    case EOld(inner) -> {
      if inOld {
        diag.add(
          errorDiagnostic(
            "T0080",
            "`old(...)` cannot be nested inside another `old(...)`: the enclosing `old` already evaluates its " +
              "whole operand at function entry",
            e.span
          )
        )
      } else if pos != "" {
        diag.add(
          errorDiagnostic(
            "T0080",
            "`old(...)` is only valid in an `ensures:` clause, not in " + pos +
              " (it names a value captured at function entry, which only a postcondition can refer to)",
            e.span
          )
        )
      }
      oldExpr(diag, pos, true, inner)
    }
    case EResult -> {
      if inOld {
        diag.add(
          errorDiagnostic(
            "T0080",
            "`result` cannot appear inside `old(...)`: the return value does not exist yet at function entry",
            e.span
          )
        )
      }
    }
    case ELambda(params, body) -> {
      var i = 0
      while i < params.count {
        oldTypeOpt(diag, params[i].ty)
        i = i + 1
      }
      oldBlock(diag, pos, inOld, body)
    }
    case ELiteral(_) -> ()
    case EPath(_) -> ()
    case ESelf -> ()
    case EError -> ()
    case EYield(inner) -> oldExpr(diag, pos, inOld, inner)
    case EParen(inner) -> oldExpr(diag, pos, inOld, inner)
    case EAwait(inner) -> oldExpr(diag, pos, inOld, inner)
    case ESpawn(inner) -> oldExpr(diag, pos, inOld, inner)
    case EPropagate(inner) -> oldExpr(diag, pos, inOld, inner)
    case ETry(inner) -> oldExpr(diag, pos, inOld, inner)
    case EPrefix(_, inner) -> oldExpr(diag, pos, inOld, inner)
    case ETuple(elems) -> oldExprs(diag, pos, inOld, elems)
    case EList(elems) -> oldExprs(diag, pos, inOld, elems)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(se) -> oldExpr(diag, pos, inOld, se)
          case ISText(_) -> ()
        }
        i = i + 1
      }
    }
    case EBinop(_, l, r) -> {
      oldExpr(diag, pos, inOld, l)
      oldExpr(diag, pos, inOld, r)
    }
    case EAssign(t, _, v) -> {
      oldExpr(diag, pos, inOld, t)
      oldExpr(diag, pos, inOld, v)
    }
    case EMember(recv, _) -> oldExpr(diag, pos, inOld, recv)
    case ETypeApp(f, targs) -> {
      oldExpr(diag, pos, inOld, f)
      oldTypeArgs(diag, targs)
    }
    case EIndex(recv, idxs) -> {
      oldExpr(diag, pos, inOld, recv)
      oldExprs(diag, pos, inOld, idxs)
    }
    case ECall(f, args) -> {
      oldExpr(diag, pos, inOld, f)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(v) -> oldExpr(diag, pos, inOld, v)
          case CANamed(_, v, _) -> oldExpr(diag, pos, inOld, v)
        }
        i = i + 1
      }
    }
    case ERange(rb) -> oldRange(diag, pos, inOld, rb)
    case EIf(c, t, eOpt, _) -> {
      oldExpr(diag, pos, inOld, c)
      oldOptBody(diag, pos, inOld, t)
      match eOpt {
        case Some(b) -> oldOptBody(diag, pos, inOld, b)
        case None -> ()
      }
    }
    case EMatch(subj, arms) -> {
      oldExpr(diag, pos, inOld, subj)
      var i = 0
      while i < arms.count {
        oldPattern(diag, arms[i].pattern)
        match arms[i].guard {
          case Some(g) -> oldExpr(diag, pos, inOld, g)
          case None -> ()
        }
        oldOptBody(diag, pos, inOld, arms[i].body)
        i = i + 1
      }
    }
    case EBlock(blk) -> oldBlock(diag, pos, inOld, blk)
    case EUnsafe(blk) -> oldBlock(diag, pos, inOld, blk)
    case EForall(binders, w, body) -> {
      oldBinders(diag, binders)
      match w {
        case Some(we) -> oldExpr(diag, pos, inOld, we)
        case None -> ()
      }
      oldExpr(diag, pos, inOld, body)
    }
    case EExists(binders, w, body) -> {
      oldBinders(diag, binders)
      match w {
        case Some(we) -> oldExpr(diag, pos, inOld, we)
        case None -> ()
      }
      oldExpr(diag, pos, inOld, body)
    }
  }
}

// Types and patterns never admit `old`, even inside an `ensures:` clause: a
// range bound in a type (`Int range 0 ..= n`) or a range pattern is evaluated
// where the type or pattern is used, and the contract elaborator snapshots
// only `old` operands of the clause's own expression tree.
val oldTypePosition = "a type annotation"

val oldPatternPosition = "a pattern"

func oldTypeOpt(diag: in List[Diagnostic], t: in Option[TypeExpr]): Unit {
  match t {
    case Some(ty) -> oldType(diag, ty)
    case None -> ()
  }
}

func oldType(diag: in List[Diagnostic], t: in TypeExpr): Unit {
  match t.kind {
    case TRefined(_, rb) -> oldRange(diag, oldTypePosition, false, rb)
    case TGenericApp(_, args) -> oldTypeArgs(diag, args)
    case TArray(size, element) -> {
      oldTypeArg(diag, size)
      oldType(diag, element)
    }
    case TSlice(element) -> oldType(diag, element)
    case TTuple(types) -> {
      var i = 0
      while i < types.count {
        oldType(diag, types[i])
        i = i + 1
      }
    }
    case TNullable(inner) -> oldType(diag, inner)
    case TFunction(ps, r) -> {
      var i = 0
      while i < ps.count {
        oldType(diag, ps[i])
        i = i + 1
      }
      oldType(diag, r)
    }
    case TParen(inner) -> oldType(diag, inner)
    case TRef(_) -> ()
    case TUnit -> ()
    case TSelf -> ()
    case TNever -> ()
    case TError -> ()
  }
}

func oldTypeArg(diag: in List[Diagnostic], a: in TypeArg): Unit {
  match a {
    case TAType(ty) -> oldType(diag, ty)
    case TAValue(e) -> oldExpr(diag, oldTypePosition, false, e)
  }
}

func oldTypeArgs(diag: in List[Diagnostic], args: in List[TypeArg]): Unit {
  var i = 0
  while i < args.count {
    oldTypeArg(diag, args[i])
    i = i + 1
  }
}

func oldGenerics(diag: in List[Diagnostic], gps: in Option[GenericParams], wc: in Option[WhereClause]): Unit {
  match gps {
    case Some(g) -> {
      var i = 0
      while i < g.params.count {
        match g.params[i] {
          case GPValue(_, constraint, _) -> oldType(diag, constraint)
          case GPType(_, _) -> ()
        }
        i = i + 1
      }
    }
    case None -> ()
  }
  match wc {
    case Some(w) -> {
      var i = 0
      while i < w.bounds.count {
        var j = 0
        while j < w.bounds[i].constraints.count {
          oldTypeArgs(diag, w.bounds[i].constraints[j].args)
          j = j + 1
        }
        i = i + 1
      }
    }
    case None -> ()
  }
}

func oldBinders(diag: in List[Diagnostic], bs: in List[PropertyBinder]): Unit {
  var i = 0
  while i < bs.count {
    oldType(diag, bs[i].ty)
    i = i + 1
  }
}

func oldPattern(diag: in List[Diagnostic], p: in Pattern): Unit {
  match p.kind {
    case PRange(lo, _, hi, _) -> {
      oldExpr(diag, oldPatternPosition, false, lo)
      oldExpr(diag, oldPatternPosition, false, hi)
    }
    case PBinding(_, inner) -> match inner { case Some(ip) -> oldPattern(diag, ip); case None -> () }
    case PConstructor(_, args) -> oldPatterns(diag, args)
    case PRecord(_, fields, _) -> {
      var i = 0
      while i < fields.count {
        match fields[i] {
          case RPFNamed(_, fp, _) -> oldPattern(diag, fp)
          case RPFShort(_, _) -> ()
        }
        i = i + 1
      }
    }
    case PTuple(ps) -> oldPatterns(diag, ps)
    case PParen(inner) -> oldPattern(diag, inner)
    case PTypeTest(inner, ty) -> {
      oldPattern(diag, inner)
      oldType(diag, ty)
    }
    case POr(ps) -> oldPatterns(diag, ps)
    case PWildcard -> ()
    case PLiteral(_) -> ()
    case PConstRef(_) -> ()
    case PError -> ()
  }
}

func oldPatterns(diag: in List[Diagnostic], ps: in List[Pattern]): Unit {
  var i = 0
  while i < ps.count {
    oldPattern(diag, ps[i])
    i = i + 1
  }
}
