//! verifier/vcgen_calls.l — call translation: resolved callees, contract unfolding, value-determined arguments.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// `x / y` and `x % y` on integers trap in every build profile (D163)
// when `y` is zero, and on a signed `bits`-wide value when `x` is the
// type's minimum and `y` is -1 (the quotient does not fit; .NET throws for
// the remainder too): the obligations `y != 0` and `not (x == Min and y ==
// -1)` (#8107, #7882), for both widths when `bits` is 0 (unknown).  Real
// division follows IEEE 754 and has none.
func divisorSideConds(b: in Builtin, args: in List[Term], bits: in Int): List[Term] {
  val conds: List[Term] = newList()
  if args.count == 2 {
    val isIntDiv = match b { case BOpDiv | BOpMod -> true; case _ -> false }
    if isIntDiv {
      val divisorSort = sortOf(args[1])
      match divisorSort {
        case SInt -> {
          conds.add(TBuiltin(op = BOpNeq, args = termList2(args[1], intLitOfSort(0i64, divisorSort))))
          // A width the verifier does not know (0) is either: excluding
          // only the narrower minimum would let a `Long`'s through.
          val widths: List[Int] = newList()
          if bits == 0 or bits == 32 {
            widths.add(32)
          }
          if bits == 0 or bits == 64 {
            widths.add(64)
          }
          var wi = 0
          while wi < widths.count {
            val atMin = TBuiltin(op = BOpEq, args = termList2(args[0], intLitOfSort(signedMinOfBits(widths[wi]), SInt)))
            val byMinusOne = TBuiltin(op = BOpEq, args = termList2(args[1], intLitOfSort(-1i64, SInt)))
            conds.add(mkNot(mkAnd(termList2(atMin, byMinusOne))))
            wi = wi + 1
          }
        }
        case SBitVec(_) -> conds.add(TBuiltin(op = BOpNeq, args = termList2(args[1], intLitOfSort(0i64, divisorSort))))
        case _ -> ()
      }
    }
  }
  conds
}

// A sort no Lyric value but a primitive (or a distinct type over one) has.
func isPrimitiveSort(srt: in Sort): Bool {
  match srt {
    case SInt -> true
    case SBitVec(_) -> true
    case SFloat32 -> true
    case SFloat64 -> true
    case SString -> true
    case SBool -> true
    case _ -> false
  }
}

// The distinct type `T` a callee `T.from` names, if any.
func distinctFromCallee(env: in VEnv, fn: in Expr): Option[String] {
  match fn.kind {
    case EMember(receiver, memberName) -> {
      if memberName == "from" {
        match receiver.kind {
          case EPath(path) -> {
            if path.segments.count == 1 and isFileDistinct(env, path.segments[0]) {
              Some(value = path.segments[0])
            } else {
              None
            }
          }
          case _ -> None
        }
      } else {
        None
      }
    }
    case _ -> None
  }
}

// The variable passed to two of `decl`'s `out`/`inout` parameters by
// `args`, or "" when no variable is.
func outArgsAlias(decl: in FunctionDecl, args: in List[CallArg]): String {
  val names: List[String] = newList()
  var k = 0
  while k < decl.params.count {
    names.add(decl.params[k].name)
    k = k + 1
  }
  match pairCallArgs(names, 0, args) {
    case Ok(slots) -> {
      val roots: List[String] = newList()
      var si = 0
      while si < slots.count {
        if slots[si] >= 0 {
          match decl.params[si].mode {
            case PMIn -> ()
            case _ -> {
              val argExpr = match args[slots[si]] { case CANamed(_, v, _) -> v; case CAPositional(x) -> x }
              match rootVarOf(argExpr) {
                case Some(root) -> {
                  if roots.contains(root) {
                    return root
                  }
                  roots.add(root)
                }
                case None -> ()
              }
            }
          }
        }
        si = si + 1
      }
      ""
    }
    case Err(_) -> ""
  }
}

// How many contracts and defaults may unfold inside one another at a call.
func maxUnfoldDepth(): Int {
  32
}

func hasRequires(decl: in FunctionDecl): Bool {
  var i = 0
  while i < decl.contracts.count {
    match decl.contracts[i] {
      case CCRequires(_, _) -> {
        return true
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

// `names` and then `name`, as a new list.
func termsWithNames(names: in List[String], name: in String): List[String] {
  val longer: List[String] = newList()
  var i = 0
  while i < names.count {
    longer.add(names[i])
    i = i + 1
  }
  longer.add(name)
  longer
}

// Declare the callee `name` once per goal's symbols, however many calls
// reach it: a second `declare-fun` of one name is an SMT-LIB error.
func addUserFunOnce(symbols: in List[SymbolDecl], name: in String, paramSorts: in List[Sort], resultSort: in Sort): Unit {
  var i = 0
  while i < symbols.count {
    match symbols[i] {
      case DeclUserFun(existing, _, _) -> {
        if existing == name {
          return ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  symbols.add(DeclUserFun(name = name, paramSorts = paramSorts, resultSort = resultSort))
}

// A call to a function this file declares, by the Hoare call rule: its
// `requires:` are side conditions at the arguments, its `ensures:` and its
// result's range and width are facts about the result.  The result of a
// `@pure` callee is the callee applied to its arguments, so two calls with
// equal arguments are equal; any other callee's — a free call, a method
// call, a static call alike — is a value of its own at this call site, so
// two calls agree only where the contract says so (#8101, #8109).  An `out`
// or `inout` parameter's `ensures:` speak of its value after the call, a
// value of its own; `old(p)` is the argument (#8102).
func translateResolvedCall(
  env: in VEnv,
  name: in String,
  decl: in FunctionDecl,
  args: in List[CallArg],
  rawArgTerms: in List[Term],
  argSpans: in List[Span],
  callSpan: in Span,
  argSides: in List[Term],
  argAssumed: in List[Term],
  allArgDiags: in List[Diagnostic],
): (TranslateResult, List[Diagnostic]) {
  val resultInfo = match decl.ret { case Some(te) -> calleeSortInfo(env, decl, te); case None -> unitSortInfo() }
  // A backstop on how deep contracts and defaults unfold into one
  // another: past it the call fails closed rather than recursing on.
  if env.contractStack.count >= maxUnfoldDepth() {
    allArgDiags.add(untranslatableDiag("the contracts reached through '" + decl.name + "' unfold too deeply", callSpan))
    val deepTR = TranslateResult(
      term = poisonTerm(TApp(name = name, args = rawArgTerms, retSort = resultInfo.sort)),
      sideConds = argSides,
      assumed = argAssumed
    )
    val deepPair: (TranslateResult, List[Diagnostic]) = (deepTR, allArgDiags)
    return deepPair
  }
  // A call reaching a function whose contract is already being unfolded
  // here — a function's own contracts are translated with it on the
  // stack — is that function applied to its arguments, with no second
  // unfolding and so no facts.  Its precondition would be an obligation
  // here, which unfolding it again cannot state: a callee with a
  // `requires:` fails closed (#8102).
  if env.contractStack.contains(decl.name) {
    val recTerm = callResultTerm(env, name, decl, rawArgTerms, resultInfo.sort)
    if hasRequires(decl) {
      allArgDiags.add(
        untranslatableDiag(
          "a call to '" + decl.name + "' inside the contract it reaches again, whose `requires:` cannot be checked there",
          callSpan
        )
      )
      val recPoisonTR = TranslateResult(term = poisonTerm(recTerm), sideConds = argSides, assumed = argAssumed)
      val recPoisonPair: (TranslateResult, List[Diagnostic]) = (recPoisonTR, allArgDiags)
      return recPoisonPair
    }
    val recTR = TranslateResult(term = recTerm, sideConds = argSides, assumed = argAssumed)
    val recPair: (TranslateResult, List[Diagnostic]) = (recTR, allArgDiags)
    return recPair
  }
  // A function on a cycle of the contract-call graph has its `requires:`
  // proved at the call, but its `ensures:` and `@pure` body, which the
  // cycle can make contradictory, are never assumed (#8102).
  val cyclicCallee = env.cyclic.contains(decl.name)
  // The callee's contract is translated against the file's functions, so
  // a call nested in a `requires:` brings its own precondition into the
  // caller's obligation (#8102).
  val contractStack = termsWithNames(env.contractStack, decl.name)
  val resultSort = resultInfo.sort
  val paramSorts: List[Sort] = newList()
  var pi = 0
  while pi < decl.params.count {
    paramSorts.add(calleeSortInfo(env, decl, decl.params[pi].ty).sort)
    pi = pi + 1
  }
  addUserFunOnce(env.symbols, name, paramSorts, resultSort)

  // Build inner env for translating contracts.
  val innerVars: Map[String, Term] = newMap()
  val innerSorts: Map[String, SortInfo] = newMap()
  val innerVarNames: List[String] = newList()
  var ii = 0
  while ii < decl.params.count {
    val pInfo = calleeSortInfo(env, decl, decl.params[ii].ty)
    innerVars.add(decl.params[ii].name, TVar(name = decl.params[ii].name, sort = pInfo.sort))
    innerSorts.add(decl.params[ii].name, pInfo)
    innerVarNames.add(decl.params[ii].name)
    ii = ii + 1
  }
  val innerEnv = VEnv(
    vars = innerVars,
    varNames = innerVarNames,
    sorts = innerSorts,
    callees = env.callees,
    symbols = env.symbols,
    checkedArithmetic = false,
    distincts = env.distincts,
    fieldInfos = env.fieldInfos,
    recordDefaults = env.recordDefaults,
    fresh = env.fresh,
    recordMethods = env.recordMethods,
    finals = env.finals,
    mutables = env.mutables,
    protectedMembers = env.protectedMembers,
    contractStack = contractStack,
    cyclic = env.cyclic,
    valueTypes = env.valueTypes,
    typeParams = typeParamNames(decl)
  )
  // A parameter default sees the names declared at module level, never
  // the callee's other parameters (docs/01): it is translated with no
  // bindings, like a record field's default.
  val defaultEnv = envInOwnContract(varlessEnv(env), decl.name)

  // Each argument goes to the parameter it names, or by position,
  // and an omitted one takes its default (#7873); each takes its
  // parameter's sort (#7848), so a literal passed to a `UInt`
  // parameter is a bitvector in the call and in the callee
  // contract it is substituted into.
  val paramNames: List[String] = newList()
  val paramDefaults: List[Option[Expr]] = newList()
  var pn = 0
  while pn < decl.params.count {
    paramNames.add(decl.params[pn].name)
    paramDefaults.add(decl.params[pn].dflt)
    pn = pn + 1
  }
  val paired = pairArgTerms(
    name,
    paramNames,
    paramSorts,
    paramDefaults,
    defaultEnv,
    args,
    rawArgTerms,
    argSpans,
    callSpan,
    argSides,
    argAssumed,
    allArgDiags
  )
  val argTerms = paired.terms
  val rawCallTerm = callResultTerm(env, name, decl, argTerms, resultSort)
  // Two `out`/`inout` parameters bound to one variable alias each other,
  // which the callee's proof assumes they do not: fail closed (#8102).
  val aliased = outArgsAlias(decl, args)
  if aliased.length > 0 {
    allArgDiags.add(
      untranslatableDiag(
        "the call to '" + name + "' passes '" + aliased + "' to two `out`/`inout` parameters, which may alias",
        callSpan
      )
    )
  }
  val callTerm = if paired.paired and aliased.length == 0 { rawCallTerm } else { poisonTerm(rawCallTerm) }

  // Param substitution map: param[i].name → argTerms[i].
  val paramSubst: Map[String, Term] = newMap()
  val paramSubstNames: List[String] = newList()
  var si = 0
  while si < decl.params.count {
    paramSubst.add(decl.params[si].name, argTerms[si])
    paramSubstNames.add(decl.params[si].name)
    si = si + 1
  }

  // @pure callee: translate body expr, emit equality as assumption.
  val pureUnfold: List[Term] = newList()
  var unfoldSkipped = false
  // A call whose arguments may differ between two calls with the same term
  // (a list, a closure) is not unfolded: its result is its call site's own.
  if isPure(decl) and not cyclicCallee and allValueDetermined(env, argTerms) {
    match decl.body {
      case Some(body) -> {
        val bodyExprOpt = match body {
          case FBExpr(be) -> Some(value = be)
          case FBBlock(blk) -> {
            if blk.statements.count == 1 {
              match blk.statements[0].kind {
                case SReturn(Some(be)) -> Some(value = be)
                case SExpr(be) -> Some(value = be)
                case _ -> None
              }
            } else {
              None
            }
          }
        }
        match bodyExprOpt {
          case Some(bodyExpr) -> {
            val (bodyR, _) = translateExpr(innerEnv, bodyExpr)
            // A body the verifier cannot translate faithfully (V0033), one
            // whose value comes from a `match` it does not model (V0027), or
            // one whose value is not of the result's sort, is not assumed: the
            // call is still the callee applied to its arguments, equal for
            // equal arguments, with its contract.  Leaving out a fact never
            // proves anything false (#8109, #8230).
            if termHasUnmodelledPattern(bodyR.term) and not termIsPoisoned(bodyR.term) {
              unfoldSkipped = true
            }
            if not termIsPoisoned(bodyR.term) and not termHasUnmodelledPattern(bodyR.term) {
              match coerceToSort(bodyR.term, resultSort) {
                case Ok(bodyAtSort) -> {
                  val bodySubst = substTerm(paramSubst, paramSubstNames, bodyAtSort)
                  val unfold = TBuiltin(op = BOpEq, args = termList2(callTerm, bodySubst))
                  match reconcileTermSorts(unfold) {
                    case Ok(well) -> {
                      if sortProblem(well, SBool).length == 0 {
                        if not unmodelledEquality(env, well) {
                          pureUnfold.add(well)
                        }
                      }
                    }
                    case Err(_) -> ()
                  }
                }
                case Err(_) -> ()
              }
            }
          }
          case None -> {
          }
        }
      }
      case None -> {
      }
    }
  }

  // Requires clauses → side conditions.
  val preConds: List[Term] = newList()
  var ci = 0
  while ci < decl.contracts.count {
    match decl.contracts[ci] {
      case CCRequires(pre, _) -> {
        val preParts = translateContractParts(innerEnv, pre)
        keepUntranslatableDiags(preParts.diags, allArgDiags)
        preConds.add(
          checkInstantiated(
            env,
            substTerm(paramSubst, paramSubstNames, partsObligation(preParts)),
            decl.name,
            callSpan,
            allArgDiags
          )
        )
      }
      case _ -> {
      }
    }
    ci = ci + 1
  }

  // Ensures clauses → assumed hypotheses.
  val postConds: List[Term] = newList()
  val resultSI = SortInfo(sort = resultSort, range = RBKNone)
  val resultVars2 = copyVarMap(innerVars, innerVarNames)
  val resultSorts2 = copySortMap(innerSorts, innerVarNames)
  val resultVarNames2 = copyNameList(innerVarNames)
  // `result` is a placeholder the parameter substitution replaces with the
  // call, together with the parameters: substituting the parameters into
  // the call itself would rewrite the caller's variables inside its
  // arguments (`fact(n - 1)` read as `fact(n - 1 - 1)`, #8102).
  val resultPlaceholder = freshVar(env, "result", resultSort)
  resultVars2.add("result", resultPlaceholder)
  resultSorts2.add("result", resultSI)
  resultVarNames2.add("result")
  // An `out`/`inout` parameter named in an `ensures:` is its value after
  // the call; `old(p)` is the value passed in.
  val postSubst: Map[String, Term] = newMap()
  val postSubstNames: List[String] = newList()
  match resultPlaceholder {
    case TVar(placeholderName, _) -> {
      postSubst.add(placeholderName, callTerm)
      postSubstNames.add(placeholderName)
    }
    case _ -> ()
  }
  var psi = 0
  while psi < decl.params.count {
    val pp = decl.params[psi]
    match pp.mode {
      case PMIn -> postSubst.add(pp.name, argTerms[psi])
      case _ -> {
        val oldKey = "old." + pp.name
        resultVars2.add(oldKey, TVar(name = oldKey, sort = paramSorts[psi]))
        resultSorts2.add(oldKey, calleeSortInfo(env, decl, pp.ty))
        resultVarNames2.add(oldKey)
        postSubst.add(oldKey, argTerms[psi])
        postSubstNames.add(oldKey)
        postSubst.add(pp.name, TVar(name = freshName(env, pp.name + "!post"), sort = paramSorts[psi]))
      }
    }
    postSubstNames.add(pp.name)
    psi = psi + 1
  }
  val resultEnv = VEnv(
    vars = resultVars2,
    varNames = resultVarNames2,
    sorts = resultSorts2,
    callees = env.callees,
    symbols = env.symbols,
    checkedArithmetic = false,
    distincts = env.distincts,
    fieldInfos = env.fieldInfos,
    recordDefaults = env.recordDefaults,
    fresh = env.fresh,
    recordMethods = env.recordMethods,
    finals = env.finals,
    mutables = env.mutables,
    protectedMembers = env.protectedMembers,
    contractStack = contractStack,
    cyclic = env.cyclic,
    valueTypes = env.valueTypes,
    typeParams = typeParamNames(decl)
  )
  ci = 0
  while ci < decl.contracts.count {
    match decl.contracts[ci] {
      case CCEnsures(post, _) -> {
        if not cyclicCallee {
          val postParts = translateContractParts(resultEnv, post)
          keepUntranslatableDiags(postParts.diags, allArgDiags)
          postConds.add(
            checkInstantiated(
              env,
              substTerm(postSubst, postSubstNames, mkAnd(partsHyps(postParts))),
              decl.name,
              callSpan,
              allArgDiags
            )
          )
        }
      }
      case _ -> {
      }
    }
    ci = ci + 1
  }

  val sc: List[Term] = newList()
  appendTermList(sc, argSides)
  // The precondition is checked once the arguments are evaluated.
  appendTermList(sc, afterFacts(argAssumed, preConds))
  val asList: List[Term] = newList()
  appendTermList(asList, argAssumed)
  appendTermList(asList, postConds)
  appendTermList(asList, pureUnfold)
  // The callee proves its result is in its declared range (#7872).
  appendTermList(asList, valueFactsForTerm(callTerm, resultInfo))
  // A goal this call reaches without its body is reported as V0027 when it
  // is not discharged (`unfoldSkippedMarker`).
  val knownCalleeTR = TranslateResult(
    term = if unfoldSkipped {
      TApp(name = unfoldSkippedMarker(), args = termList1(callTerm), retSort = sortOf(callTerm))
    } else {
      callTerm
    },
    sideConds = sc,
    assumed = asList
  )
  val knownCalleePair: (TranslateResult, List[Diagnostic]) = (knownCalleeTR, allArgDiags)
  knownCalleePair
}

// A callee's contract clause instantiated at a call, failing closed (V0033)
// when an `==` in it, over a type parameter in the callee, compares here
// values whose equality the verifier does not model (#8109).
func checkInstantiated(env: in VEnv, t: in Term, callee: in String, sp: in Span, diags: in List[Diagnostic]): Term {
  if unmodelledEquality(env, t) {
    diags.add(
      untranslatableDiag(
        "the contract of '" + callee +
          "' compares, at this call, values that may be or hold a function, compare by identity, or be of a type the verifier does not know",
        sp
      )
    )
    poisonTerm(t)
  } else {
    t
  }
}

// The value a call of `decl` returns.  A `@pure` callee — `@pure` is
// trusted, not checked — whose arguments are all values that determine
// what it can compute is the callee applied to them, so equal arguments
// give equal results.  Any other call's result is its own call site's
// (`callSiteResult`): two calls of a counter or a random source differ, as
// do two calls of a `@pure` function passed a closure, a list, or a
// protected object whose state changed in between (#8109).
func callResultTerm(
  env: in VEnv, name: in String, decl: in FunctionDecl, argTerms: in List[Term], resultSort: in Sort
): Term {
  if isPure(decl) and allValueDetermined(env, argTerms) {
    TApp(name = name, args = argTerms, retSort = resultSort)
  } else {
    callSiteResult(env, name, argTerms, resultSort)
  }
}

// The result of one call site that is not known to be a function of its
// arguments alone: a function of its own, applied to the arguments, so it
// varies with a quantifier's bound variable they mention and is never
// shared with another call site.  An argument reported untranslatable
// (V0033) keeps it poisoned (#7874).
func callSiteResult(env: in VEnv, name: in String, argTerms: in List[Term], resultSort: in Sort): Term {
  val siteName = freshName(env, name + "!result")
  val t = if argTerms.count == 0 {
    TVar(name = siteName, sort = resultSort)
  } else {
    TApp(name = siteName, args = argTerms, retSort = resultSort)
  }
  if anyPoisoned(argTerms) {
    poisonTerm(t)
  } else {
    t
  }
}

// Whether every argument is a value `==` sees all of: one of a value sort
// (`isValueSort`), or a function the file declares `@pure`, named.  A
// closure, a function from elsewhere, a collection, a protected object or
// any value the verifier does not model may behave differently between two
// calls with the same term.
func allValueDetermined(env: in VEnv, argTerms: in List[Term]): Bool {
  var i = 0
  while i < argTerms.count {
    if not valueDetermined(env, argTerms[i]) {
      return false
    }
    i = i + 1
  }
  true
}

func valueDetermined(env: in VEnv, t: in Term): Bool {
  match t {
    case TVar(n, _) -> {
      val prefix = functionRefPrefix()
      if n.startsWith(prefix) {
        return match mapGet(env.callees, n.substring(prefix.length, n.length - prefix.length)) {
          case Some(decl) -> isPure(decl)
          case None -> false
        }
      }
    }
    case _ -> ()
  }
  isValueSort(env.valueTypes, env.distincts, sortOf(t), 0)
}

// Whether a value of `s` is all `==` compares: a primitive, `String`,
// `Unit`, a tuple, `Result` or `Option` of such values, or a type of the
// file's that `fileValueTypes` lists.  `List`, `Map`, `Set`, slices,
// protected and opaque types, functions and anything unmodelled are not.
func isValueSort(valueTypes: in Map[String, Bool], distincts: in Map[String, TypeExpr], s: in Sort, depth: in Int): Bool {
  if depth > 16 {
    return false
  }
  match s {
    case SBool -> true
    case SInt -> true
    case SBitVec(_) -> true
    case SFloat32 -> true
    case SFloat64 -> true
    case SString -> true
    case SDatatype(name, args) -> {
      val stdMonad = (name == "Result" or name == "Option") and not distincts.containsKey(shadowedMonadKey(name))
      if name == unitSortName() or isTupleSortName(name) or stdMonad {
        var i = 0
        while i < args.count {
          if not isValueSort(valueTypes, distincts, args[i], depth + 1) {
            return false
          }
          i = i + 1
        }
        true
      } else {
        args.count == 0 and valueTypes.containsKey(name)
      }
    }
    case _ -> false
  }
}

// The type `file` declares or imports by name, or one of `siblingTypeNames`
// (what the package's other files declare) that is spelt like a primitive
// (`Int`, `String`, `Char`, ...), or "".
func shadowedPrimitiveName(file: in SourceFile, siblingTypeNames: in List[String]): String {
  val names = declaredTypeNames(file)
  var si = 0
  while si < siblingTypeNames.count {
    names.add(siblingTypeNames[si])
    si = si + 1
  }
  var j = 0
  while j < file.imports.count {
    val imp = file.imports[j]
    match imp.asAlias {
      case Some(a) -> names.add(a)
      case None -> ()
    }
    match imp.selector {
      case Some(sel) -> {
        val items: List[ImportItem] = match sel {
          case ISSingle(item) -> {
            val one: List[ImportItem] = newList()
            one.add(item)
            one
          }
          case ISGroup(group) -> group
        }
        var k = 0
        while k < items.count {
          names.add(match items[k].asAlias { case Some(a) -> a; case None -> items[k].name })
          k = k + 1
        }
      }
      case None -> ()
    }
    j = j + 1
  }
  var i = 0
  while i < names.count {
    if isSome(primitiveSort(names[i])) {
      return names[i]
    }
    i = i + 1
  }
  ""
}

// The non-generic enums, records and unions `file` declares whose values
// are what `==` compares: every field immutable and of a value sort
// (`isValueSort`), resolved to a fixed point so a record of records
// qualifies.
func fileValueTypes(file: in SourceFile, distincts: in Map[String, TypeExpr]): Map[String, Bool] {
  val valueTypes: Map[String, Bool] = newMap()
  val candidates: List[String] = newList()
  val candidateFields: List[List[TypeExpr]] = newList()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IEnum(d) -> {
        if not valueTypes.containsKey(d.name) {
          valueTypes.add(d.name, true)
        }
      }
      case IRecord(d) -> {
        if isNone(d.generics) {
          val tys: List[TypeExpr] = newList()
          var mutable = false
          var mi = 0
          while mi < d.members.count {
            match d.members[mi] {
              case RMField(fld) -> {
                if fld.isMutable {
                  mutable = true
                }
                tys.add(fld.ty)
              }
              case _ -> ()
            }
            mi = mi + 1
          }
          if not mutable {
            candidates.add(d.name)
            candidateFields.add(tys)
          }
        }
      }
      case IUnion(d) -> {
        if isNone(d.generics) {
          val tys: List[TypeExpr] = newList()
          var ci = 0
          while ci < d.cases.count {
            var fi = 0
            while fi < d.cases[ci].fields.count {
              match d.cases[ci].fields[fi] {
                case UFNamed(_, ty, _) -> tys.add(ty)
                case UFPos(ty, _) -> tys.add(ty)
              }
              fi = fi + 1
            }
            ci = ci + 1
          }
          candidates.add(d.name)
          candidateFields.add(tys)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  var changed = true
  while changed {
    changed = false
    var ci = 0
    while ci < candidates.count {
      val name = candidates[ci]
      if not valueTypes.containsKey(name) {
        val tys = candidateFields[ci]
        var allValues = true
        var ti = 0
        while ti < tys.count {
          if not isValueSort(valueTypes, distincts, sortOfTypeExprWith(distincts, tys[ti]).sort, 0) {
            allValues = false
          }
          ti = ti + 1
        }
        if allValues {
          valueTypes.add(name, true)
          changed = true
        }
      }
      ci = ci + 1
    }
  }
  addStructuralEqualityTypes(file, distincts, valueTypes)
  var ui = 0
  while ui < file.items.count {
    match file.items[ui].kind {
      case IUnion(d) -> {
        if not valueTypes.containsKey(unionKey(d.name)) {
          valueTypes.add(unionKey(d.name), true)
        }
      }
      case _ -> ()
    }
    ui = ui + 1
  }
  valueTypes
}

func noTypeParams(): List[String] {
  val none: List[String] = newList()
  none
}

// The names of `decl`'s type parameters.
func typeParamNames(decl: in FunctionDecl): List[String] {
  genericTypeParamNames(decl.generics)
}
