//! verifier/vcgen_effects.l — effect analysis of statements and expressions, havoc, environment updates.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// ─────────────────────────────────────────────────────────────────────────────
// §9a. What code may change, and how it may leave.
// ─────────────────────────────────────────────────────────────────────────────
// The effects of a statement list or expression, as far as the verifier's
// model of state goes: the variables it assigns (the root variable of an
// assigned field or element, `p` for `p.x = v`), the variables it passes to
// an `out`/`inout` parameter of a function this file declares (and the
// receiver of such a method), and the ways it may leave other than by
// falling through (`return`, `break`, `continue`, `throw`).  Assignments
// inside a lambda count — the lambda may run here — but its jumps do not.
record Effects {
  assigned: List[String]
  outArgs: List[String]
  jumps: List[String]
  // The last name segment of every callee the code calls (`f` for `f(x)`,
  // `P.f(x)` and `r.f()`), for the contract-call graph.
  calls: List[String]
}

func emptyEffects(): Effects {
  val assigned: List[String] = newList()
  val outArgs: List[String] = newList()
  val jumps: List[String] = newList()
  val calls: List[String] = newList()
  Effects(assigned = assigned, outArgs = outArgs, jumps = jumps, calls = calls)
}

// The last name segment a callee expression names, or "".
func calleeLeaf(fn: in Expr): String {
  match fn.kind {
    case EPath(path) -> if path.segments.count > 0 { path.segments[path.segments.count - 1] } else { "" }
    case EMember(_, member) -> member
    case EParen(inner) -> calleeLeaf(inner)
    case ETypeApp(inner, _) -> calleeLeaf(inner)
    case EIndex(inner, _) -> calleeLeaf(inner)
    case _ -> ""
  }
}

func effectsOfStmts(env: in VEnv, stmts: in List[Statement]): Effects {
  val eff = emptyEffects()
  effStmts(env, stmts, false, eff)
  eff
}

func effectsOfExpr(env: in VEnv, e: in Expr): Effects {
  val eff = emptyEffects()
  effExpr(env, e, false, eff)
  eff
}

// Every variable `eff` says may change: assigned or passed out.
func effectsChanged(eff: in Effects): List[String] {
  val names: List[String] = newList()
  addNames(names, eff.assigned)
  addNames(names, eff.outArgs)
  names
}

func hasEffectsOtherThanCalls(eff: in Effects): Bool {
  eff.assigned.count > 0 or eff.jumps.count > 0
}

func addName(names: in List[String], n: in String): Unit {
  if not names.contains(n) {
    names.add(n)
  }
}

func addNames(names: in List[String], src: in List[String]): Unit {
  var i = 0
  while i < src.count {
    addName(names, src[i])
    i = i + 1
  }
}

// The variable an assignment target or argument stores into: `x` for `x`,
// `x.f`, `x.f.g` and `x[i]`.
func rootVarOf(e: in Expr): Option[String] {
  match e.kind {
    case EPath(path) -> if path.segments.count == 1 { Some(value = path.segments[0]) } else { None }
    case EParen(inner) -> rootVarOf(inner)
    case EMember(receiver, _) -> rootVarOf(receiver)
    case EIndex(receiver, _) -> rootVarOf(receiver)
    case _ -> None
  }
}

func effBlock(env: in VEnv, blk: in Block, inLambda: in Bool, eff: in Effects): Unit {
  effStmts(env, blk.statements, inLambda, eff)
}

func effStmts(env: in VEnv, stmts: in List[Statement], inLambda: in Bool, eff: in Effects): Unit {
  var i = 0
  while i < stmts.count {
    effStmt(env, stmts[i], inLambda, eff)
    i = i + 1
  }
}

func effJump(kind: in String, inLambda: in Bool, eff: in Effects): Unit {
  if not inLambda {
    addName(eff.jumps, kind)
  }
}

func effStmt(env: in VEnv, st: in Statement, inLambda: in Bool, eff: in Effects): Unit {
  match st.kind {
    case SLocal(binding) -> match binding {
      case LBVal(_, _, init) -> effExpr(env, init, inLambda, eff)
      case LBLet(_, _, init) -> effExpr(env, init, inLambda, eff)
      case LBVar(_, _, Some(init)) -> effExpr(env, init, inLambda, eff)
      case LBVar(_, _, None) -> ()
    }
    case SAssign(target, _, value) -> effAssign(env, target, value, inLambda, eff)
    case SReturn(valueOpt) -> {
      match valueOpt {
        case Some(v) -> effExpr(env, v, inLambda, eff)
        case None -> ()
      }
      effJump("return", inLambda, eff)
    }
    case SBreak(_) -> effJump("break", inLambda, eff)
    case SContinue(_) -> effJump("continue", inLambda, eff)
    case SThrow(x) -> {
      effExpr(env, x, inLambda, eff)
      effJump("throw", inLambda, eff)
    }
    case STry(body, catches, finally_) -> {
      effBlock(env, body, inLambda, eff)
      var ci = 0
      while ci < catches.count {
        effBlock(env, catches[ci].body, inLambda, eff)
        ci = ci + 1
      }
      match finally_ {
        case Some(fb) -> effBlock(env, fb, inLambda, eff)
        case None -> ()
      }
    }
    case SDefer(body) -> effBlock(env, body, inLambda, eff)
    case SScope(_, body) -> effBlock(env, body, inLambda, eff)
    case SFor(_, _, iter, body) -> {
      effExpr(env, iter, inLambda, eff)
      effBlock(env, body, inLambda, eff)
    }
    case SWhile(_, cond, body) -> {
      effExpr(env, cond, inLambda, eff)
      effBlock(env, body, inLambda, eff)
    }
    case SLoop(_, body) -> effBlock(env, body, inLambda, eff)
    case SInvariant(x) -> effExpr(env, x, inLambda, eff)
    case SExpr(x) -> effExpr(env, x, inLambda, eff)
    case SRule(lhs, rhs) -> {
      effExpr(env, lhs, inLambda, eff)
      effExpr(env, rhs, inLambda, eff)
    }
    case SItem(_) -> ()
  }
}

func effAssign(env: in VEnv, target: in Expr, value: in Expr, inLambda: in Bool, eff: in Effects): Unit {
  match rootVarOf(target) {
    case Some(n) -> addName(eff.assigned, n)
    case None -> ()
  }
  // An index or a field's receiver is evaluated too.
  effExpr(env, target, inLambda, eff)
  effExpr(env, value, inLambda, eff)
}

func effEob(env: in VEnv, eob: in ExprOrBlock, inLambda: in Bool, eff: in Effects): Unit {
  match eob {
    case EOBExpr(x) -> effExpr(env, x, inLambda, eff)
    case EOBBlock(blk) -> effBlock(env, blk, inLambda, eff)
  }
}

func effExprList(env: in VEnv, xs: in List[Expr], inLambda: in Bool, eff: in Effects): Unit {
  var i = 0
  while i < xs.count {
    effExpr(env, xs[i], inLambda, eff)
    i = i + 1
  }
}

func effExpr(env: in VEnv, e: in Expr, inLambda: in Bool, eff: in Effects): Unit {
  match e.kind {
    case EParen(inner) -> effExpr(env, inner, inLambda, eff)
    case EAwait(inner) -> effExpr(env, inner, inLambda, eff)
    case EYield(inner) -> effExpr(env, inner, inLambda, eff)
    case ESpawn(inner) -> effExpr(env, inner, inLambda, eff)
    case ETry(inner) -> effExpr(env, inner, inLambda, eff)
    case EOld(inner) -> effExpr(env, inner, inLambda, eff)
    case EPropagate(inner) -> {
      // `e?` returns early on an error.
      effExpr(env, inner, inLambda, eff)
      effJump("return", inLambda, eff)
    }
    case EBlock(blk) -> effBlock(env, blk, inLambda, eff)
    case EUnsafe(blk) -> effBlock(env, blk, inLambda, eff)
    case EPrefix(_, operand) -> effExpr(env, operand, inLambda, eff)
    case EBinop(_, lhs, rhs) -> {
      effExpr(env, lhs, inLambda, eff)
      effExpr(env, rhs, inLambda, eff)
    }
    case EMember(receiver, _) -> effExpr(env, receiver, inLambda, eff)
    case ETypeApp(fn, _) -> effExpr(env, fn, inLambda, eff)
    case EAssign(target, _, value) -> effAssign(env, target, value, inLambda, eff)
    case ECall(fn, args) -> {
      effExpr(env, fn, inLambda, eff)
      var i = 0
      while i < args.count {
        val argExpr = match args[i] { case CANamed(_, v, _) -> v; case CAPositional(x) -> x }
        effExpr(env, argExpr, inLambda, eff)
        i = i + 1
      }
      effOutArgs(env, fn, args, eff)
      val leaf = calleeLeaf(fn)
      if leaf.length > 0 {
        addName(eff.calls, leaf)
      }
    }
    case EIndex(receiver, indices) -> {
      effExpr(env, receiver, inLambda, eff)
      effExprList(env, indices, inLambda, eff)
    }
    case ETuple(exprs) -> effExprList(env, exprs, inLambda, eff)
    case EList(exprs) -> effExprList(env, exprs, inLambda, eff)
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISExpr(x) -> effExpr(env, x, inLambda, eff)
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
    }
    case ERange(bound) -> match bound {
      case RBClosed(lo, hi) -> {
        effExpr(env, lo, inLambda, eff)
        effExpr(env, hi, inLambda, eff)
      }
      case RBHalfOpen(lo, hi, _) -> {
        effExpr(env, lo, inLambda, eff)
        effExpr(env, hi, inLambda, eff)
      }
      case RBLowerOpen(hi) -> effExpr(env, hi, inLambda, eff)
      case RBUpperOpen(lo) -> effExpr(env, lo, inLambda, eff)
    }
    case ELambda(_, body) -> effBlock(env, body, true, eff)
    case EIf(cond, thenBranch, elseBranch, _) -> {
      effExpr(env, cond, inLambda, eff)
      effEob(env, thenBranch, inLambda, eff)
      match elseBranch {
        case Some(eb) -> effEob(env, eb, inLambda, eff)
        case None -> ()
      }
    }
    case EMatch(scrutinee, arms) -> {
      effExpr(env, scrutinee, inLambda, eff)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> effExpr(env, g, inLambda, eff)
          case None -> ()
        }
        effEob(env, arms[i].body, inLambda, eff)
        i = i + 1
      }
    }
    case _ -> ()
  }
}

// The variables a call passes to an `out`/`inout` parameter.  For a call
// this file resolves — by path, qualified by the file's own package or not,
// a dot-named `T.m(...)`, or a method — those are the arguments its non-`in`
// parameters receive (and a non-`in` receiver).  A call the verifier cannot
// resolve may have such parameters too: every argument (and receiver)
// naming a binding a call may store into is taken to change (#8102).
func effOutArgs(env: in VEnv, fn: in Expr, args: in List[CallArg], eff: in Effects): Unit {
  match typeAppCallee(env, fn) {
    case Some(inner) -> {
      return effOutArgs(env, inner, args, eff)
    }
    case None -> ()
  }
  if localCallee(env, fn) {
    effMutableArgs(env, args, eff)
    return ()
  }
  match fn.kind {
    case EParen(inner) -> effOutArgs(env, inner, args, eff)
    case EPath(path) -> {
      val name = joinPathSegments(path.segments)
      match fileCallee(env, name, args) {
        case Some(decl) -> effOutParams(decl, 0, args, eff)
        case None -> {
          val known = name == "assert" or env.protectedMembers.contains(name) or isFileDistinct(env, name)
          val isRecord = match findRecordFields(env, name) { case Some(_) -> true; case None -> false }
          if not known and not isRecord {
            effMutableArgs(env, args, eff)
          }
        }
      }
    }
    case EMember(receiver, methodName) -> {
      match resolveStaticCallee(env, receiver, methodName, args) {
        case Some(rc) -> effOutParams(rc.decl, 0, args, eff)
        case None -> {
          val methodOpt = match staticSortOfExpr(env, receiver) {
            case Some(srt) -> resolveMethodCallee(env, TVar(name = "self", sort = srt), methodName, args)
            case None -> None
          }
          match methodOpt {
            case Some(rc) -> {
              match rc.decl.params[0].mode {
                case PMIn -> ()
                case _ -> match rootVarOf(receiver) { case Some(n) -> addName(eff.outArgs, n); case None -> () }
              }
              effOutParams(rc.decl, 1, args, eff)
            }
            case None -> {
              match distinctFromCallee(env, fn) {
                case Some(_) -> ()
                case None -> {
                  effMutableRoot(env, receiver, eff)
                  effMutableArgs(env, args, eff)
                }
              }
            }
          }
        }
      }
    }
    case _ -> effMutableArgs(env, args, eff)
  }
}

func effMutableArgs(env: in VEnv, args: in List[CallArg], eff: in Effects): Unit {
  var i = 0
  while i < args.count {
    val argExpr = match args[i] { case CANamed(_, v, _) -> v; case CAPositional(x) -> x }
    effMutableRoot(env, argExpr, eff)
    i = i + 1
  }
}

func effMutableRoot(env: in VEnv, e: in Expr, eff: in Effects): Unit {
  match rootVarOf(e) {
    case Some(n) -> {
      if env.mutables.contains(n) {
        addName(eff.outArgs, n)
      }
    }
    case None -> ()
  }
}

func effOutParams(decl: in FunctionDecl, skip: in Int, args: in List[CallArg], eff: in Effects): Unit {
  val names: List[String] = newList()
  var k = 0
  while k < decl.params.count {
    names.add(decl.params[k].name)
    k = k + 1
  }
  match pairCallArgs(names, skip, args) {
    case Ok(slots) -> {
      var si = 0
      while si < slots.count {
        val slot = slots[si]
        if slot >= 0 {
          match decl.params[skip + si].mode {
            case PMIn -> ()
            case _ -> {
              val argExpr = match args[slot] { case CANamed(_, v, _) -> v; case CAPositional(x) -> x }
              match rootVarOf(argExpr) {
                case Some(n) -> addName(eff.outArgs, n)
                case None -> ()
              }
            }
          }
        }
        si = si + 1
      }
    }
    case Err(_) -> {
      // Arguments that do not fit the parameters fail closed at the call
      // (#7873); every variable passed may change for all this knows.
      var ai = 0
      while ai < args.count {
        val argExpr = match args[ai] { case CANamed(_, v, _) -> v; case CAPositional(x) -> x }
        match rootVarOf(argExpr) {
          case Some(n) -> addName(eff.outArgs, n)
          case None -> ()
        }
        ai = ai + 1
      }
    }
  }
}

// `env` with each of `names` that it binds rebound to a value of its own of
// the same sort — what it holds after code that may change it — plus what
// is still known of each: a range-typed variable is in its range, an
// `Int`/`Long` within its width.  `tag` names the havoc in the solver's
// counterexamples (`i!loop12`).
record Havoc {
  env: VEnv
  hyps: List[Term]
}

func havocVars(env: in VEnv, names: in List[String], tag: in String): Havoc {
  var envH = env
  val hyps: List[Term] = newList()
  var i = 0
  while i < names.count {
    val vname = names[i]
    match envLookupSort(vname, env) {
      case Some(vinfo) -> {
        val t = freshVar(env, vname + "!" + tag, vinfo.sort)
        envH = envBindTerm(vname, t, vinfo, envH)
        appendTermList(hyps, valueFactsForTerm(t, vinfo))
      }
      // A name with no binding here is declared inside the code itself.
      case None -> ()
    }
    i = i + 1
  }
  Havoc(env = envH, hyps = hyps)
}

// After an expression evaluates: the variables it passed to an `out` or
// `inout` parameter hold new values (#8102).
func havocOutArgs(env: in VEnv, e: in Expr): Havoc {
  val eff = effectsOfExpr(env, e)
  havocVars(env, eff.outArgs, "out")
}

// `env` where `name` is (or is no longer) a binding a call may store into.
func envSetMutable(env: in VEnv, name: in String, mutable: in Bool): VEnv {
  val mutables: List[String] = newList()
  var i = 0
  while i < env.mutables.count {
    if env.mutables[i] != name {
      mutables.add(env.mutables[i])
    }
    i = i + 1
  }
  if mutable {
    mutables.add(name)
  }
  envWithState(env, env.finals, mutables, env.protectedMembers)
}

// `env` for translating `name`'s own contracts: `name` is on the contract
// stack, so a call to it there is cut where its callers cut it, and what
// the function assumes of its contract is what they prove (#8102).
func envInOwnContract(env: in VEnv, name: in String): VEnv {
  VEnv(
    vars = env.vars,
    varNames = env.varNames,
    sorts = env.sorts,
    callees = env.callees,
    symbols = env.symbols,
    checkedArithmetic = env.checkedArithmetic,
    distincts = env.distincts,
    fieldInfos = env.fieldInfos,
    recordDefaults = env.recordDefaults,
    fresh = env.fresh,
    recordMethods = env.recordMethods,
    finals = env.finals,
    mutables = env.mutables,
    protectedMembers = env.protectedMembers,
    contractStack = termsWithNames(env.contractStack, name),
    cyclic = env.cyclic,
    valueTypes = env.valueTypes,
    typeParams = env.typeParams
  )
}

// `env` translating the body and contract of a generic with type
// parameters `names`.
func envWithTypeParams(env: in VEnv, names: in List[String]): VEnv {
  VEnv(
    vars = env.vars,
    varNames = env.varNames,
    sorts = env.sorts,
    callees = env.callees,
    symbols = env.symbols,
    checkedArithmetic = env.checkedArithmetic,
    distincts = env.distincts,
    fieldInfos = env.fieldInfos,
    recordDefaults = env.recordDefaults,
    fresh = env.fresh,
    recordMethods = env.recordMethods,
    finals = env.finals,
    mutables = env.mutables,
    protectedMembers = env.protectedMembers,
    contractStack = env.contractStack,
    cyclic = env.cyclic,
    valueTypes = env.valueTypes,
    typeParams = names
  )
}

// `env` whose distinct-type and declaration map is `distincts`.
func envWithDistincts(env: in VEnv, distincts: in Map[String, TypeExpr]): VEnv {
  VEnv(
    vars = env.vars,
    varNames = env.varNames,
    sorts = env.sorts,
    callees = env.callees,
    symbols = env.symbols,
    checkedArithmetic = env.checkedArithmetic,
    distincts = distincts,
    fieldInfos = env.fieldInfos,
    recordDefaults = env.recordDefaults,
    fresh = env.fresh,
    recordMethods = env.recordMethods,
    finals = env.finals,
    mutables = env.mutables,
    protectedMembers = env.protectedMembers,
    contractStack = env.contractStack,
    cyclic = env.cyclic,
    valueTypes = env.valueTypes,
    typeParams = env.typeParams
  )
}

// `env` whose postcondition placeholders are `finals`.
func envWithFinals(env: in VEnv, finals: in List[FinalSlot]): VEnv {
  envWithState(env, finals, env.mutables, env.protectedMembers)
}

func envWithState(
  env: in VEnv, finals: in List[FinalSlot], mutables: in List[String], protectedMembers: in List[String]
): VEnv {
  VEnv(
    vars = env.vars,
    varNames = env.varNames,
    sorts = env.sorts,
    callees = env.callees,
    symbols = env.symbols,
    checkedArithmetic = env.checkedArithmetic,
    distincts = env.distincts,
    fieldInfos = env.fieldInfos,
    recordDefaults = env.recordDefaults,
    fresh = env.fresh,
    recordMethods = env.recordMethods,
    finals = finals,
    mutables = mutables,
    protectedMembers = protectedMembers,
    contractStack = env.contractStack,
    cyclic = env.cyclic,
    valueTypes = env.valueTypes,
    typeParams = env.typeParams
  )
}

// The postcondition at the end of a path: `result` is `resultTerm`, and
// each placeholder in `env.finals` is its variable's value here.
func finishPost(env: in VEnv, postcond: in Term, resultTerm: in Term): Term {
  val substMap: Map[String, Term] = newMap()
  val substNames: List[String] = newList()
  substMap.add("result", resultTerm)
  substNames.add("result")
  var i = 0
  while i < env.finals.count {
    val slot = env.finals[i]
    match envLookup(slot.varName, env) {
      case Some(t) -> {
        substMap.add(slot.placeholder, t)
        substNames.add(slot.placeholder)
      }
      case None -> ()
    }
    i = i + 1
  }
  substTerm(substMap, substNames, postcond)
}
