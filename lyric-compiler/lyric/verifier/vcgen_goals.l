//! verifier/vcgen_goals.l — goals for a function and for protected-type members.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

pub func goalsForFunction(env0: in VEnv, decl: in FunctionDecl): (List[Goal], List[Diagnostic]) {
  val noExtraHyps: List[Term] = newList()
  goalsForFunctionWithExtraHyps(env0, decl, noExtraHyps)
}

// Like `goalsForFunction`, but folds `extraHyps` into both the main goal's
// and every side goal's hypothesis set — e.g. protected-type field range
// bounds (#3854, #3855), which aren't reachable from `decl.params` since
// the fields are bound directly into the caller's `env0`/`fnEnv`, not
// declared as parameters of the synthesized entry/func `decl`.
pub func goalsForFunctionWithExtraHyps(
  env0: in VEnv, decl: in FunctionDecl, extraHyps: in List[Term]
): (List[Goal], List[Diagnostic]) {
  val noState: List[String] = newList()
  goalsForFunctionWithState(env0, decl, extraHyps, noState)
}

// Like `goalsForFunctionWithExtraHyps`, where the names in `stateVars` —
// bound in `env0`, like a protected type's `var` fields — are state the
// body may change: an `ensures:` speaks of their values when the function
// returns, and `old(n)` of their values on entry (#8102).
pub func goalsForFunctionWithState(
  envIn: in VEnv,
  decl: in FunctionDecl,
  extraHyps: in List[Term],
  stateVars: in List[String],
): (List[Goal], List[Diagnostic]) {
  goalsForFunctionInheriting(envIn, decl, extraHyps, stateVars, noInheritedClauses())
}

// Like `goalsForFunctionWithState`, where `decl` also carries the `inherited`
// clauses of the interface method it implements (#8231): each `requires:`
// is a precondition and each `ensures:` an obligation beside `decl`'s own,
// read with the interface's parameter names standing for `decl`'s
// parameters at the same positions, as the contract elaborator inserts them
// at run time (docs/01 §6.1.1).
func goalsForFunctionInheriting(
  envIn: in VEnv,
  decl: in FunctionDecl,
  extraHyps: in List[Term],
  stateVars: in List[String],
  inherited: in InheritedClauses,
): (List[Goal], List[Diagnostic]) {
  val env0 = envWithTypeParams(envIn, typeParamNames(decl))
  // Soundness guard: WP/SP has no suspend/resume model; reject contract-bearing async/yield rather than opaquing (#3298).
  if decl.contracts.count > 0 and (decl.isAsync or funcBodyContainsYield(decl)) {
    val asyncDiags: List[Diagnostic] = newList()
    asyncDiags.add(
      errorDiagnostic(
        "V0032",
        "contracts on async/yield functions are not yet verifiable; the proof " +
          "system cannot model suspend/resume control flow, so 'requires:'/'ensures:' " +
          "clauses on '" +
          decl.name +
          "' would be checked against an unmodelled body. " +
          "Move the contract to a synchronous core, or mark the package @runtime_checked.",
        decl.span
      )
    )
    val noGoals: List[Goal] = newList()
    val asyncPair: (List[Goal], List[Diagnostic]) = (noGoals, asyncDiags)
    return asyncPair
  }

  // Bind parameters.
  var envWithParams = env0
  val paramHyps: List[Term] = newList()
  var i = 0
  while i < decl.params.count {
    val p = decl.params[i]
    val info = sortOfTypeExprE(env0, p.ty)
    val passedOut = match p.mode { case PMIn -> false; case _ -> true }
    envWithParams = envSetMutable(envBind(p.name, info, envWithParams), p.name, passedOut)
    appendTermList(paramHyps, valueFactsForTerm(TVar(name = p.name, sort = info.sort), info))
    i = i + 1
  }

  // Result sort.
  val resultSort = match decl.ret { case Some(te) -> sortOfTypeExprE(env0, te); case None -> unitSortInfo() }

  // Bind `result` for postcondition translation.
  val envWithResult = envBind("result", resultSort, envWithParams)

  // Bind old-snapshot entries: old.<name> := <name> for each param.
  var envWithOld = envWithResult
  i = 0
  while i < decl.params.count {
    val p = decl.params[i]
    val info = sortOfTypeExprE(env0, p.ty)
    val t = TVar(name = p.name, sort = info.sort)
    envWithOld = envBindTerm("old." + p.name, t, info, envWithOld)
    i = i + 1
  }
  i = 0
  while i < stateVars.count {
    match envLookup(stateVars[i], env0) {
      case Some(entryTerm) -> match envLookupSort(stateVars[i], env0) {
        case Some(info) -> {
          envWithOld = envBindTerm("old." + stateVars[i], entryTerm, info, envWithOld)
        }
        case None -> ()
      }
      case None -> ()
    }
    i = i + 1
  }

  // Translate requires clauses.
  // A precondition is assumed whole: its side conditions, the facts its
  // evaluation brings, and its value.  Its side conditions are the caller's
  // obligation like the rest of it (#8102): `requires: x == 0 or pos(x) > 0`
  // asks the caller for `x == 0 or x > 0`.  But a clause that no argument can
  // meet (side conditions that always fail, a value that is never true, or
  // one that contradicts an earlier clause) can be met by no call, and
  // assuming it would make every obligation of the function hold vacuously.
  // So each clause carries a goal that some argument meets it, side
  // conditions, facts and value together, under the parameters' facts and
  // the clauses before it (#8223).
  val preTerms: List[Term] = newList()
  val preDiags: List[Diagnostic] = newList()
  val preSideHyps: List[List[Term]] = newList()
  val preSideTerms: List[Term] = newList()
  val preSideSpans: List[Span] = newList()
  // The inherited clauses first, as the contract elaborator orders them.
  val allClauses: List[ContractClause] = newList()
  val clauseInherited: List[Bool] = newList()
  for c in inherited.clauses {
    allClauses.add(c)
    clauseInherited.add(true)
  }
  for c in decl.contracts {
    allClauses.add(c)
    clauseInherited.add(false)
  }
  i = 0
  while i < allClauses.count {
    match allClauses[i] {
      case CCRequires(e, clauseSpan) -> {
        val preEnv = envInOwnContract(envWithParams, decl.name)
        val parts = translateContractParts(
          if clauseInherited[i] {
            withInterfaceParamNames(preEnv, inherited.paramNames, decl.params)
          } else {
            preEnv
          },
          e
        )
        val before: List[Term] = newList()
        appendTermList(before, paramHyps)
        appendTermList(before, extraHyps)
        appendTermList(before, preTerms)
        preSideHyps.add(before)
        preSideTerms.add(mkAnd(partsHyps(parts)))
        preSideSpans.add(clauseSpan)
        appendTermList(preTerms, partsHyps(parts))
        appendTermList2(preDiags, parts.diags)
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  val preTerm = mkAnd(preTerms)

  // An `out`/`inout` parameter named in an `ensures:` is its value when the
  // function returns: a placeholder each path's end replaces with the value
  // the parameter holds there (`finishPost`); `old(p)` is its value on entry
  // (#8102).
  val paramFinals: List[FinalSlot] = newList()
  var envForPost = envWithOld
  i = 0
  while i < decl.params.count {
    val p = decl.params[i]
    match p.mode {
      case PMIn -> ()
      case _ -> {
        val info = sortOfTypeExprE(env0, p.ty)
        val placeholder = freshName(env0, p.name + "!final")
        paramFinals.add(FinalSlot(varName = p.name, placeholder = placeholder))
        envForPost = envBindTerm(p.name, TVar(name = placeholder, sort = info.sort), info, envForPost)
      }
    }
    i = i + 1
  }
  i = 0
  while i < stateVars.count {
    match envLookupSort(stateVars[i], env0) {
      case Some(info) -> {
        val placeholder = freshName(env0, stateVars[i] + "!final")
        paramFinals.add(FinalSlot(varName = stateVars[i], placeholder = placeholder))
        envForPost = envBindTerm(stateVars[i], TVar(name = placeholder, sort = info.sort), info, envForPost)
      }
      case None -> ()
    }
    i = i + 1
  }

  // Translate ensures clauses.
  // A postcondition is proved as `sides and (facts => value)`: the facts
  // of a call in it never prove that call's own precondition (#8102).
  val postTerms: List[Term] = newList()
  val postDiags: List[Diagnostic] = newList()
  i = 0
  while i < allClauses.count {
    match allClauses[i] {
      case CCEnsures(e, _) -> {
        val postEnv = envInOwnContract(envForPost, decl.name)
        val parts = translateContractParts(
          if clauseInherited[i] {
            withInterfaceParamNames(postEnv, inherited.paramNames, decl.params)
          } else {
            postEnv
          },
          e
        )
        postTerms.add(partsObligation(parts))
        appendTermList2(postDiags, parts.diags)
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  val postTerm = mkAnd(postTerms)

  // Build postcondition: post term with result substituted + range bounds.
  // The WP calculus substitutes `result` for us via the postcond term.
  // We build a combined postcond that includes the range bound check.
  // The WP function will substitute `result` when it reaches the return.

  val body = match decl.body {
    case Some(b) -> b
    case None -> {
      // No body: @axiom-like, no VCs.
      val unit = Expr(kind = ELiteral(lit = LUnit), span = decl.span)
      FBExpr(expr = unit)
    }
  }

  // Build postcondition term with result variable (will be substituted by WP).
  val resultVar = TVar(name = "result", sort = resultSort.sort)
  // A declared result range whose bound cannot be translated fails closed
  // (V0033) rather than dropping the obligation (#7848).
  val rangeDiags: List[Diagnostic] = newList()
  val rangeTerms: List[Term] = match rangeObligationsForTerm(resultVar, resultSort) {
    case Ok(ts) -> ts
    case Err(reason) -> {
      val retSpan = match decl.ret { case Some(te) -> te.span; case None -> decl.span }
      rangeDiags.add(untranslatableDiag("the result's declared range: " + reason, retSpan))
      // The obligation stays in the goal, failed, so the postcondition is
      // never reported discharged while weaker than declared (#7874).
      val failed: List[Term] = newList()
      failed.add(poisonTerm(falseT()))
      failed
    }
  }
  val allPostParts: List[Term] = newList()
  allPostParts.add(postTerm)
  appendTermList(allPostParts, rangeTerms)
  val combinedPost = mkAnd(allPostParts)

  val wpRes = wpBody(envWithFinals(envWithOld, paramFinals), resultSort, combinedPost, body)

  // Main goal hypotheses.
  val hypotheses: List[Term] = newList()
  appendTermList(hypotheses, paramHyps)
  appendTermList(hypotheses, extraHyps)
  hypotheses.add(preTerm)
  appendTermList(hypotheses, wpRes.assumed)

  val symbolsList: List[SymbolDecl] = newList()
  i = 0
  while i < env0.symbols.count {
    symbolsList.add(env0.symbols[i])
    i = i + 1
  }

  val mainGoal = Goal(
    hypotheses = hypotheses,
    conclusion = wpRes.wp,
    symbols = symbolsList,
    origin = decl.span,
    kind = GKPostcondition(fnName = decl.name),
    label = decl.name + "$post"
  )

  // Side goals.
  val sideHyps: List[Term] = newList()
  appendTermList(sideHyps, paramHyps)
  appendTermList(sideHyps, extraHyps)
  sideHyps.add(preTerm)

  val goals: List[Goal] = newList()
  goals.add(mainGoal)
  i = 0
  while i < preSideTerms.count {
    val preSymbols: List[SymbolDecl] = newList()
    for sym in env0.symbols {
      preSymbols.add(sym)
    }
    goals.add(
      Goal(
        hypotheses = preSideHyps[i],
        conclusion = mkNot(preSideTerms[i]),
        symbols = preSymbols,
        origin = preSideSpans[i],
        kind = GKPreconditionDomain(fnName = decl.name),
        label = decl.name + "$pre"
      )
    )
    i = i + 1
  }
  i = 0
  while i < wpRes.sideGoals.count {
    val sg = wpRes.sideGoals[i]
    val sideSymbols: List[SymbolDecl] = newList()
    var si = 0
    while si < env0.symbols.count {
      sideSymbols.add(env0.symbols[si])
      si = si + 1
    }
    goals.add(
      Goal(
        hypotheses = sideHyps,
        conclusion = sg.term,
        symbols = sideSymbols,
        origin = sg.span,
        kind = sg.kind,
        label = decl.name + "$side"
      )
    )
    i = i + 1
  }

  val allDiags: List[Diagnostic] = newList()
  appendTermList2(allDiags, preDiags)
  appendTermList2(allDiags, postDiags)
  appendTermList2(allDiags, rangeDiags)
  appendTermList2(allDiags, wpRes.diags)
  val goalPair: (List[Goal], List[Diagnostic]) = (goals, allDiags)
  goalPair
}

// `env` where each interface parameter name in `ifaceNames` stands for the
// implementing method's parameter at its position, its entry value (`old`)
// included.  Every binding is read before any is made, so parameters the
// implementation swaps (`a`, `b` for the interface's `b`, `a`) stay apart.
func withInterfaceParamNames(env: in VEnv, ifaceNames: in List[String], params: in List[Param]): VEnv {
  val names: List[String] = newList()
  val terms: List[Term] = newList()
  val infos: List[SortInfo] = newList()
  var i = 0
  while i < ifaceNames.count and i < params.count {
    if ifaceNames[i] != params[i].name {
      var k = 0
      while k < 2 {
        val prefix = if k == 0 { "" } else { "old." }
        match envLookup(prefix + params[i].name, env) {
          case Some(t) -> match envLookupSort(prefix + params[i].name, env) {
            case Some(info) -> {
              names.add(prefix + ifaceNames[i])
              terms.add(t)
              infos.add(info)
            }
            case None -> ()
          }
          case None -> ()
        }
        k = k + 1
      }
    }
    i = i + 1
  }
  var bound = env
  i = 0
  while i < names.count {
    bound = envBindTerm(names[i], terms[i], infos[i], bound)
    i = i + 1
  }
  bound
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Goals for an entire file.
// ─────────────────────────────────────────────────────────────────────────────
// Return a copy of env with a fresh (empty) symbols list.
func freshSymbolsEnv(env: in VEnv): VEnv {
  // Start each function with its own symbol-accumulator list so per-function
  // DeclUserFun additions don't leak across functions, but copy the file-
  // level pre-registered symbols (e.g. record DeclDatatypes from #3843) so
  // EMember field selectors and ECall record constructors can resolve them.
  val freshSyms: List[SymbolDecl] = newList()
  var i = 0
  while i < env.symbols.count {
    freshSyms.add(env.symbols[i])
    i = i + 1
  }
  VEnv(
    vars = env.vars,
    varNames = env.varNames,
    sorts = env.sorts,
    callees = env.callees,
    symbols = freshSyms,
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
    typeParams = env.typeParams
  )
}

// Collect invariant contracts from a protected type's members.
// Each PMInvariant becomes a CCRequires (assume at entry) and a CCEnsures
// (must hold at exit) so entries are required to preserve the invariant.
func collectProtectedInvariants(decl: in ProtectedTypeDecl): List[ContractClause] {
  val result: List[ContractClause] = newList()
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case PMInvariant(inv) -> {
        result.add(CCRequires(expr = inv.expr, span = inv.span))
        result.add(CCEnsures(expr = inv.expr, span = inv.span))
      }
      case _ -> {
      }
    }
    mi = mi + 1
  }
  result
}

// Synthesize a FunctionDecl for a protected-type entry and verify it.
// Results are accumulated into allGoals / allDiags (no tuple return needed).
func goalsForProtectedEntry(
  level: in VerificationLevel,
  env0: in VEnv,
  protName: in String,
  ed: in EntryDecl,
  invContracts: in List[ContractClause],
  protMembers: in List[ProtectedMember],
  allGoals: in List[Goal],
  allDiags: in List[Diagnostic],
): Unit {
  val entryContracts: List[ContractClause] = newList()
  var eci = 0
  while eci < invContracts.count {
    entryContracts.add(invContracts[eci])
    eci = eci + 1
  }
  val entryOwn = ed.contracts
  eci = 0
  while eci < entryOwn.count {
    entryContracts.add(entryOwn[eci])
    eci = eci + 1
  }
  val noDocComments: List[DocComment] = newList()
  val entryBody: Option[FunctionBody] = Some(value = ed.body)
  // Pass entry-level annotations through (#662): @axiom / @runtime_checked
  // overrides on the EntryDecl must reach `levelOfFunction` below.
  val synthDecl: FunctionDecl = FunctionDecl(
    docComments = noDocComments,
    annotations = ed.annotations,
    visibility = ed.visibility,
    isAsync = false,
    name = protName + "::" + ed.name,
    generics = None,
    params = ed.params,
    ret = ed.ret,
    whereClause = None,
    contracts = entryContracts,
    body = entryBody,
    span = ed.span
  )
  val fnLevel = levelOfFunction(level, synthDecl)
  if vlIsProofRequired(fnLevel) {
    // Bind every protected-type field (PFVar / PFLet / PFImmutable) as a
    // term that projects the field from a synthetic `__self_<protName>` of
    // the protected datatype's sort.  Two reasons (#3855):
    //   1. The body refers to fields by bare identifier (`tokens`, not
    //      `self.tokens`), and without a binding the verifier translates
    //      them as SUninterp("tokens") free variables — sort-incompatible
    //      with the arithmetic the body does on them.
    //   2. We also register the protected type as a DeclDatatype so
    //      `make`'s `ensures: result.tokens == capacity` can use the
    //      datatype's selector.  Binding `tokens` to a free TVar of the
    //      same sort as the selector triggers a z3 "ambiguous constant
    //      reference" error.  Binding `tokens` to a TApp through the
    //      synthetic `__self_<protName>` avoids the clash — the selector
    //      use-site and the field-binding use-site become the same SMT
    //      term, structurally indistinguishable from a regular field
    //      projection.
    val emptyArgs: List[Sort] = newList()
    val selfSort = SDatatype(name = protName, args = emptyArgs)
    val selfInfo = sortInfoNoRange(selfSort)
    val selfName = "__self_" + protName
    var fnEnv = freshSymbolsEnv(env0)
    fnEnv = envBind(selfName, selfInfo, fnEnv)
    val selfTerm = TVar(name = selfName, sort = selfSort)
    // Range-subtype-typed fields (e.g. `var tokens: Percent`) must carry
    // their bound forward as a hypothesis too (#3854, #3855) — stated over
    // the field's selector `TApp`, the same term the body's bare-identifier
    // field references resolve to via `fnEnv` below, not a free `TVar`.
    val fieldRangeHyps: List[Term] = newList()
    var mfi = 0
    while mfi < protMembers.count {
      match protMembers[mfi] {
        case PMField(pf) -> {
          match pf {
            case PFVar(fname, fty, _, _, _, _) -> {
              val fInfo = sortOfTypeExprE(env0, fty)
              val args1: List[Term] = newList()
              args1.add(selfTerm)
              val fTerm = TApp(name = protName + "__" + fname, args = args1, retSort = fInfo.sort)
              fnEnv = envBindTerm(fname, fTerm, fInfo, fnEnv)
              appendTermList(fieldRangeHyps, valueFactsForTerm(fTerm, fInfo))
            }
            case PFLet(fname, fty, _, _, _, _) -> {
              val fInfo = sortOfTypeExprE(env0, fty)
              val args2: List[Term] = newList()
              args2.add(selfTerm)
              val fTerm = TApp(name = protName + "__" + fname, args = args2, retSort = fInfo.sort)
              fnEnv = envBindTerm(fname, fTerm, fInfo, fnEnv)
              appendTermList(fieldRangeHyps, valueFactsForTerm(fTerm, fInfo))
            }
            case PFImmutable(fd) -> {
              val fInfo = sortOfTypeExprE(env0, fd.ty)
              val args3: List[Term] = newList()
              args3.add(selfTerm)
              val fTerm = TApp(name = protName + "__" + fd.name, args = args3, retSort = fInfo.sort)
              fnEnv = envBindTerm(fd.name, fTerm, fInfo, fnEnv)
              appendTermList(fieldRangeHyps, valueFactsForTerm(fTerm, fInfo))
            }
          }
        }
        case _ -> ()
      }
      mfi = mfi + 1
    }
    // An entry may assign its type's `var` fields: its `ensures:` and the
    // type's invariant hold of their values when it returns (#8102).
    val varFields: List[String] = newList()
    var vfi = 0
    while vfi < protMembers.count {
      match protMembers[vfi] {
        case PMField(pf) -> match pf { case PFVar(vfName, _, _, _, _, _) -> varFields.add(vfName); case _ -> () }
        case _ -> ()
      }
      vfi = vfi + 1
    }
    vfi = 0
    while vfi < varFields.count {
      fnEnv = envSetMutable(fnEnv, varFields[vfi], true)
      vfi = vfi + 1
    }
    val (goals, diags) = goalsForFunctionWithState(fnEnv, synthDecl, fieldRangeHyps, varFields)
    var gi = 0
    while gi < goals.count {
      allGoals.add(goals[gi])
      gi = gi + 1
    }
    appendTermList2(allDiags, diags)
  }
}

// Verify a protected-type PMFunc helper that has its own contracts.
// Results are accumulated into allGoals / allDiags.
func goalsForProtectedFunc(
  level: in VerificationLevel,
  env0: in VEnv,
  fn: in FunctionDecl,
  allGoals: in List[Goal],
  allDiags: in List[Diagnostic],
): Unit {
  val fnLevel = levelOfFunction(level, fn)
  if vlIsProofRequired(fnLevel) {
    val fnEnv = freshSymbolsEnv(env0)
    val (goals, diags) = goalsForFunction(fnEnv, fn)
    var gi = 0
    while gi < goals.count {
      allGoals.add(goals[gi])
      gi = gi + 1
    }
    appendTermList2(allDiags, diags)
  }
}

// Iterate over protected-type members and collect goals for entries and funcs.
func goalsForProtectedMembers(
  level: in VerificationLevel,
  env0: in VEnv,
  protName: in String,
  members: in List[ProtectedMember],
  invContracts: in List[ContractClause],
  allGoals: in List[Goal],
  allDiags: in List[Diagnostic],
): Unit {
  // A member's body reaches the type's other members by their bare names.
  val memberNames: List[String] = newList()
  var mn = 0
  while mn < members.count {
    match members[mn] {
      case PMEntry(med) -> memberNames.add(med.name)
      case PMFunc(mfn) -> memberNames.add(mfn.name)
      case _ -> ()
    }
    mn = mn + 1
  }
  val memberEnv = envWithState(env0, env0.finals, env0.mutables, memberNames)
  var mi = 0
  while mi < members.count {
    match members[mi] {
      case PMEntry(ed) -> {
        goalsForProtectedEntry(level, memberEnv, protName, ed, invContracts, members, allGoals, allDiags)
      }
      case PMFunc(fn) -> {
        goalsForProtectedFunc(level, memberEnv, fn, allGoals, allDiags)
      }
      case _ -> {
      }
    }
    mi = mi + 1
  }
}
