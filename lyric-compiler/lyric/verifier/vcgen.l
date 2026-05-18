// verifier/vcgen.l — verification-condition generator (WP/SP calculus).
// M4.1 fragment: let/val/var, if/else, match (trivial patterns), calls.
// Mirrors compiler/src/Lyric.Verifier/VCGen.fs (simplified: no cross-package
// imports, no ProofMeta datatype encoding).
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker

// ─────────────────────────────────────────────────────────────────────────────
// §1. Verification environment.
// ─────────────────────────────────────────────────────────────────────────────

pub record VEnv {
  pub vars:              Map[String, Term]
  pub varNames:          List[String]
  pub sorts:             Map[String, SortInfo]
  pub callees:           Map[String, FunctionDecl]
  pub symbols:           List[SymbolDecl]
  pub checkedArithmetic: Bool
}

// Copy helpers — use explicit names list to avoid iterating Map.keys on a
// TypeBuilderInstantiation, which generates invalid IL.

func copyVarMap(m: in Map[String, Term], names: in List[String]): Map[String, Term] {
  val result: Map[String, Term] = newMap()
  var i = 0
  while i < names.count {
    val k = names[i]
    match mapGet(m, k) {
      case Some(v) -> result.add(k, v)
      case None    -> {}
    }
    i = i + 1
  }
  result
}

func copySortMap(m: in Map[String, SortInfo], names: in List[String]): Map[String, SortInfo] {
  val result: Map[String, SortInfo] = newMap()
  var i = 0
  while i < names.count {
    val k = names[i]
    match mapGet(m, k) {
      case Some(v) -> result.add(k, v)
      case None    -> {}
    }
    i = i + 1
  }
  result
}

func copyNameList(names: in List[String]): List[String] {
  val result: List[String] = newList()
  var i = 0
  while i < names.count {
    result.add(names[i])
    i = i + 1
  }
  result
}

pub func envEmpty(callees: in Map[String, FunctionDecl], symbols: in List[SymbolDecl], checkedArithmetic: in Bool): VEnv {
  val vars:     Map[String, Term]     = newMap()
  val sorts:    Map[String, SortInfo] = newMap()
  val varNames: List[String]          = newList()
  VEnv(vars = vars, varNames = varNames, sorts = sorts, callees = callees, symbols = symbols, checkedArithmetic = checkedArithmetic)
}

// Bind name as TVar with the given sort info; copies vars and sorts maps,
// excluding any existing binding for 'name' (shadowing support).
pub func envBind(name: in String, info: in SortInfo, env: in VEnv): VEnv {
  // Build prevNames = env.varNames minus 'name' (handles shadowing).
  val prevNames: List[String] = newList()
  var i = 0
  while i < env.varNames.count {
    if env.varNames[i] != name { prevNames.add(env.varNames[i]) }
    i = i + 1
  }
  val vars2  = copyVarMap(env.vars, prevNames)
  val sorts2 = copySortMap(env.sorts, prevNames)
  vars2.add(name, TVar(name = name, sort = info.sort))
  sorts2.add(name, info)
  prevNames.add(name)
  VEnv(vars = vars2, varNames = prevNames, sorts = sorts2, callees = env.callees, symbols = env.symbols, checkedArithmetic = env.checkedArithmetic)
}

// Bind name with an explicit term (e.g. for let-binding substitution);
// excludes any existing binding for 'name' (shadowing support).
pub func envBindTerm(name: in String, term: in Term, info: in SortInfo, env: in VEnv): VEnv {
  val prevNames: List[String] = newList()
  var i = 0
  while i < env.varNames.count {
    if env.varNames[i] != name { prevNames.add(env.varNames[i]) }
    i = i + 1
  }
  val vars2  = copyVarMap(env.vars, prevNames)
  val sorts2 = copySortMap(env.sorts, prevNames)
  vars2.add(name, term)
  sorts2.add(name, info)
  prevNames.add(name)
  VEnv(vars = vars2, varNames = prevNames, sorts = sorts2, callees = env.callees, symbols = env.symbols, checkedArithmetic = env.checkedArithmetic)
}

pub func envLookup(name: in String, env: in VEnv): Option[Term] {
  mapGet(env.vars, name)
}

pub func envLookupSort(name: in String, env: in VEnv): Option[SortInfo] {
  mapGet(env.sorts, name)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Translation result.
// ─────────────────────────────────────────────────────────────────────────────

pub record TranslateResult {
  pub term:      Term
  pub sideConds: List[Term]
  pub assumed:   List[Term]
}

func singleTR(t: in Term): TranslateResult {
  val sc: List[Term] = newList()
  val asList: List[Term] = newList()
  TranslateResult(term = t, sideConds = sc, assumed = asList)
}

func appendTermList(dst: in List[Term], src: in List[Term]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Literal translation.
// ─────────────────────────────────────────────────────────────────────────────

func translateLit(lit: in Literal): Term {
  match lit {
    case LBool(v)         -> TLit(value = VLBool(b = v), sort = SBool)
    case LInt(v, _)       -> TLit(value = VLInt(n = v), sort = SInt)
    case LFloat(v, _)     -> TLit(value = VLFloat(f = v), sort = SFloat64)
    case LString(s)       -> TLit(value = VLString(s = s), sort = SString)
    case LTripleString(s) -> TLit(value = VLString(s = s), sort = SString)
    case LRawString(s)    -> TLit(value = VLString(s = s), sort = SString)
    case LChar(cp)        -> TLit(value = VLInt(n = codepointToLong(cp)), sort = SInt)
    case LUnit            -> {
      val args: List[Sort] = newList()
      val unitDt = SDatatype(name = "Unit", args = args)
      TLit(value = VLUnit, sort = unitDt)
    }
  }
}

// Convert an Int codepoint to a Long value for LInt literals.
// Lyric's surface lacks a direct Int → Long cast today; mirror the
// `intToLong` shim in lexer.l.  Inputs are bounded codepoint indices
// (typically small non-negative integers) so the constant-time-per-bit
// bound here is acceptable.  Will collapse to a single `conv.i8` IL
// instruction when the cleaner widening shim lands (lyric-lang #418 §9).
func codepointToLong(n: in Int): Long {
  var acc: Long = 0i64
  if n >= 0 {
    var i = 0
    while i < n {
      acc = acc + 1i64
      i = i + 1
    }
  } else {
    var i = 0
    while i > n {
      acc = acc - 1i64
      i = i - 1
    }
  }
  acc
}

func unitTerm(): Term {
  val args: List[Sort] = newList()
  val unitDt2 = SDatatype(name = "Unit", args = args)
  TLit(value = VLUnit, sort = unitDt2)
}

func unitSortInfo(): SortInfo {
  val args: List[Sort] = newList()
  val unitSort = SDatatype(name = "Unit", args = args)
  sortInfoNoRange(unitSort)
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
// §5. Expression translation.
// ─────────────────────────────────────────────────────────────────────────────

pub func translateExpr(env: in VEnv, e: in Expr): (TranslateResult, List[Diagnostic]) {
  match e.kind {
    case ELiteral(lit) -> {
      val emptyDiags: List[Diagnostic] = newList()
      val pair: (TranslateResult, List[Diagnostic]) = (singleTR(translateLit(lit)), emptyDiags)
      pair
    }

    case EParen(inner) -> {
      translateExpr(env, inner)
    }

    case EPath(path) -> {
      val diags: List[Diagnostic] = newList()
      if path.segments.count == 1 {
        val name = path.segments[0]
        match envLookup(name, env) {
          case Some(t) -> (singleTR(t), diags)
          case None    -> {
            val uSort = SUninterp(name = name)
            val t = TVar(name = name, sort = uSort)
            val ePair: (TranslateResult, List[Diagnostic]) = (singleTR(t), diags)
            ePair
          }
        }
      } else {
        // Multi-segment path — join with "." and emit uninterpreted.
        var joined = ""
        var i = 0
        while i < path.segments.count {
          if i > 0 { joined = joined + "." }
          joined = joined + path.segments[i]
          i = i + 1
        }
        val pathSort = SUninterp(name = "path")
        val t = TVar(name = joined, sort = pathSort)
        val pathPair: (TranslateResult, List[Diagnostic]) = (singleTR(t), diags)
        pathPair
      }
    }

    case EResult -> {
      val diags: List[Diagnostic] = newList()
      match envLookup("result", env) {
        case Some(t) -> (singleTR(t), diags)
        case None    -> {
          diags.add(errorDiagnostic("V0020",
            "`result` is only valid inside `ensures:` clauses", e.span))
          val resultSort2 = SUninterp(name = "result")
          val t = TVar(name = "result", sort = resultSort2)
          val resultPair: (TranslateResult, List[Diagnostic]) = (singleTR(t), diags)
          resultPair
        }
      }
    }

    case EOld(inner) -> {
      val diags: List[Diagnostic] = newList()
      match inner.kind {
        case EPath(path) -> {
          if path.segments.count >= 1 {
            val leafName = path.segments[path.segments.count - 1]
            val key = "old." + leafName
            match envLookup(key, env) {
              case Some(t) -> (singleTR(t), diags)
              case None    -> {
                // Fall back to current value.
                translateExpr(env, inner)
              }
            }
          } else {
            translateExpr(env, inner)
          }
        }
        case _ -> {
          // Non-trivial old(e) — treat as current.
          diags.add(warningDiagnostic("V0021",
            "`old(e)` for non-path expressions is not yet supported; treating as current",
            e.span))
          val (r, innerDiags) = translateExpr(env, inner)
          appendTermList2(diags, innerDiags)
          val oldPair: (TranslateResult, List[Diagnostic]) = (r, diags)
          oldPair
        }
      }
    }

    case EIf(cond, thenBranch, elseBranchOpt, _) -> {
      val (condR, condDiags) = translateExpr(env, cond)

      val (thenR, thenDiags) = translateEOB(env, thenBranch, e.span)

      val (elseR, elseDiags) = match elseBranchOpt {
        case Some(eb) -> translateEOB(env, eb, e.span)
        case None     -> {
          val ed: List[Diagnostic] = newList()
          val noBranchPair: (TranslateResult, List[Diagnostic]) = (singleTR(unitTerm()), ed)
          noBranchPair
        }
      }

      val term = TIte(cond = condR.term, thenT = thenR.term, elseT = elseR.term)
      val sc: List[Term] = newList()
      appendTermList(sc, condR.sideConds)
      appendTermList(sc, thenR.sideConds)
      appendTermList(sc, elseR.sideConds)
      val asList: List[Term] = newList()
      appendTermList(asList, condR.assumed)
      appendTermList(asList, thenR.assumed)
      appendTermList(asList, elseR.assumed)
      val allDiags: List[Diagnostic] = newList()
      appendTermList2(allDiags, condDiags)
      appendTermList2(allDiags, thenDiags)
      appendTermList2(allDiags, elseDiags)
      val ifTR = TranslateResult(term = term, sideConds = sc, assumed = asList)
      val ifPair: (TranslateResult, List[Diagnostic]) = (ifTR, allDiags)
      ifPair
    }

    case EPrefix(op, operand) -> {
      val (xR, xDiags) = translateExpr(env, operand)
      match builtinOfPrefix(op) {
        case Some(b) -> {
          val sc: List[Term] = newList()
          appendTermList(sc, xR.sideConds)
          val asList: List[Term] = newList()
          appendTermList(asList, xR.assumed)
          val t = TBuiltin(op = b, args = termList1(xR.term))
          val prefixTR = TranslateResult(term = t, sideConds = sc, assumed = asList)
          val prefixBuiltinPair: (TranslateResult, List[Diagnostic]) = (prefixTR, xDiags)
          prefixBuiltinPair
        }
        case None -> {
          val diags: List[Diagnostic] = newList()
          appendTermList2(diags, xDiags)
          val prefixSort = SUninterp(name = "prefix")
          val prefixVar = TVar(name = "?prefix", sort = prefixSort)
          val prefixPair: (TranslateResult, List[Diagnostic]) = (singleTR(prefixVar), diags)
          prefixPair
        }
      }
    }

    case EBinop(op, lhs, rhs) -> {
      val (lR, lDiags) = translateExpr(env, lhs)
      val (rR, rDiags) = translateExpr(env, rhs)
      match builtinOfBinop(op) {
        case Some(rawB) -> {
          // Float operands → use real division instead of integer div.
          val b = match rawB {
            case BOpDiv -> {
              match sortOf(lR.term) {
                case SFloat32 -> BOpRealDiv
                case SFloat64 -> BOpRealDiv
                case _        -> BOpDiv
              }
            }
            case _ -> rawB
          }
          val args = termList2(lR.term, rR.term)
          val term = TBuiltin(op = b, args = args)
          val sc: List[Term] = newList()
          appendTermList(sc, lR.sideConds)
          appendTermList(sc, rR.sideConds)
          // @proof_required(checked_arithmetic): overflow side conditions.
          if env.checkedArithmetic {
            match sortOf(lR.term) {
              case SInt -> {
                match b {
                  case BOpAdd | BOpSub | BOpMul -> {
                    val minI64: Long = -9223372036854775807i64 - 1i64
                    val maxI64: Long = 9223372036854775807i64
                    sc.add(TBuiltin(op = BOpLte, args = termList2(TLit(value = VLInt(n = minI64), sort = SInt), term)))
                    sc.add(TBuiltin(op = BOpLte, args = termList2(term, TLit(value = VLInt(n = maxI64), sort = SInt))))
                  }
                  case _ -> {}
                }
              }
              case _ -> {}
            }
          }
          val asList: List[Term] = newList()
          appendTermList(asList, lR.assumed)
          appendTermList(asList, rR.assumed)
          val allDiags: List[Diagnostic] = newList()
          appendTermList2(allDiags, lDiags)
          appendTermList2(allDiags, rDiags)
          val binopTR = TranslateResult(term = term, sideConds = sc, assumed = asList)
          val binopPairResult: (TranslateResult, List[Diagnostic]) = (binopTR, allDiags)
          binopPairResult
        }
        case None -> {
          val diags: List[Diagnostic] = newList()
          diags.add(warningDiagnostic("V0023",
            "binary operator not yet modelled in proof translation", e.span))
          appendTermList2(diags, lDiags)
          appendTermList2(diags, rDiags)
          val binopSort = SUninterp(name = "binop")
          val binopVar = TVar(name = "?binop", sort = binopSort)
          val binopPair: (TranslateResult, List[Diagnostic]) = (singleTR(binopVar), diags)
          binopPair
        }
      }
    }

    case ECall(fn, args) -> {
      // Translate all arguments first.
      val argTerms: List[Term]       = newList()
      val argSides: List[Term]       = newList()
      val argAssumed: List[Term]     = newList()
      val allArgDiags: List[Diagnostic] = newList()
      var i = 0
      while i < args.count {
        val argExpr = match args[i] {
          case CANamed(_, v, _) -> v
          case CAPositional(v)  -> v
        }
        val (ar, ad) = translateExpr(env, argExpr)
        argTerms.add(ar.term)
        appendTermList(argSides,   ar.sideConds)
        appendTermList(argAssumed, ar.assumed)
        appendTermList2(allArgDiags, ad)
        i = i + 1
      }

      match fn.kind {
        case EPath(path) -> {
          // Build callee name.
          var name = ""
          if path.segments.count == 1 {
            name = path.segments[0]
          } else {
            var j = 0
            while j < path.segments.count {
              if j > 0 { name = name + "." }
              name = name + path.segments[j]
              j = j + 1
            }
          }

          match mapGet(env.callees, name) {
            case Some(decl) -> {
              val resultSort = match decl.ret {
                case Some(te) -> sortOfTypeExpr(te).sort
                case None     -> {
                  val ua: List[Sort] = newList()
                  SDatatype(name = "Unit", args = ua)
                }
              }
              val paramSorts: List[Sort] = newList()
              var pi = 0
              while pi < decl.params.count {
                paramSorts.add(sortOfTypeExpr(decl.params[pi].ty).sort)
                pi = pi + 1
              }
              env.symbols.add(DeclUserFun(name = name, paramSorts = paramSorts, resultSort = resultSort))
              val callTerm = TApp(name = name, args = argTerms, retSort = resultSort)

              // Build param substitution map: param[i].name → argTerms[i].
              val paramSubst:      Map[String, Term] = newMap()
              val paramSubstNames: List[String]      = newList()
              val maxP = if decl.params.count < argTerms.count { decl.params.count } else { argTerms.count }
              var si = 0
              while si < maxP {
                paramSubst.add(decl.params[si].name, argTerms[si])
                paramSubstNames.add(decl.params[si].name)
                si = si + 1
              }

              // Build inner env for translating contracts.
              val innerVars:     Map[String, Term]     = newMap()
              val innerSorts:    Map[String, SortInfo] = newMap()
              val innerVarNames: List[String]          = newList()
              var ii = 0
              while ii < decl.params.count {
                val pInfo = sortOfTypeExpr(decl.params[ii].ty)
                innerVars.add(decl.params[ii].name, TVar(name = decl.params[ii].name, sort = pInfo.sort))
                innerSorts.add(decl.params[ii].name, pInfo)
                innerVarNames.add(decl.params[ii].name)
                ii = ii + 1
              }
              val emptyCallees: Map[String, FunctionDecl] = newMap()
              val emptySymbols: List[SymbolDecl]          = newList()
              val innerEnv = VEnv(vars = innerVars, varNames = innerVarNames, sorts = innerSorts,
                callees = emptyCallees, symbols = emptySymbols,
                checkedArithmetic = false)

              // @pure callee: translate body expr, emit equality as assumption.
              val pureUnfold: List[Term] = newList()
              if isPure(decl) {
                match decl.body {
                  case Some(body) -> {
                    val bodyExprOpt = match body {
                      case FBExpr(be)  -> Some(value = be)
                      case FBBlock(blk) -> {
                        if blk.statements.count == 1 {
                          match blk.statements[0].kind {
                            case SReturn(Some(be)) -> Some(value = be)
                            case SExpr(be)         -> Some(value = be)
                            case _                 -> None
                          }
                        } else {
                          None
                        }
                      }
                    }
                    match bodyExprOpt {
                      case Some(bodyExpr) -> {
                        val (bodyR, _) = translateExpr(innerEnv, bodyExpr)
                        val bodySubst  = substTerm(paramSubst, paramSubstNames, bodyR.term)
                        pureUnfold.add(TBuiltin(op = BOpEq, args = termList2(callTerm, bodySubst)))
                      }
                      case None -> {}
                    }
                  }
                  case None -> {}
                }
              }

              // Requires clauses → side conditions.
              val preConds: List[Term] = newList()
              var ci = 0
              while ci < decl.contracts.count {
                match decl.contracts[ci] {
                  case CCRequires(pre, _) -> {
                    val (preR, _) = translateExpr(innerEnv, pre)
                    preConds.add(substTerm(paramSubst, paramSubstNames, preR.term))
                  }
                  case _ -> {}
                }
                ci = ci + 1
              }

              // Ensures clauses → assumed hypotheses.
              val postConds: List[Term] = newList()
              val resultSI = SortInfo(sort = resultSort, range = RBKNone)
              val resultVars2     = copyVarMap(innerVars, innerVarNames)
              val resultSorts2    = copySortMap(innerSorts, innerVarNames)
              val resultVarNames2 = copyNameList(innerVarNames)
              resultVars2.add("result", callTerm)
              resultSorts2.add("result", resultSI)
              resultVarNames2.add("result")
              val resultEnv = VEnv(vars = resultVars2, varNames = resultVarNames2, sorts = resultSorts2,
                callees = emptyCallees, symbols = emptySymbols,
                checkedArithmetic = false)
              ci = 0
              while ci < decl.contracts.count {
                match decl.contracts[ci] {
                  case CCEnsures(post, _) -> {
                    val (postR, _) = translateExpr(resultEnv, post)
                    postConds.add(substTerm(paramSubst, paramSubstNames, postR.term))
                  }
                  case _ -> {}
                }
                ci = ci + 1
              }

              val sc: List[Term] = newList()
              appendTermList(sc, argSides)
              appendTermList(sc, preConds)
              val asList: List[Term] = newList()
              appendTermList(asList, argAssumed)
              appendTermList(asList, postConds)
              appendTermList(asList, pureUnfold)
              val knownCalleeTR = TranslateResult(term = callTerm, sideConds = sc, assumed = asList)
              val knownCalleePair: (TranslateResult, List[Diagnostic]) = (knownCalleeTR, allArgDiags)
              knownCalleePair
            }
            case None -> {
              // Unknown callee — emit TApp with uninterpreted sort.
              val callNameSort = SUninterp(name = "call." + name)
              val t = TApp(name = name, args = argTerms, retSort = callNameSort)
              val sc: List[Term] = newList()
              appendTermList(sc, argSides)
              val asList: List[Term] = newList()
              appendTermList(asList, argAssumed)
              val unknownCalleeTR = TranslateResult(term = t, sideConds = sc, assumed = asList)
              val unknownCalleePair: (TranslateResult, List[Diagnostic]) = (unknownCalleeTR, allArgDiags)
              unknownCalleePair
            }
          }
        }
        case _ -> {
          // Non-path callee — uninterpreted.
          val diags: List[Diagnostic] = newList()
          appendTermList2(diags, allArgDiags)
          val callSort = SUninterp(name = "call")
          val callVar = TVar(name = "?call", sort = callSort)
          val callPair: (TranslateResult, List[Diagnostic]) = (singleTR(callVar), diags)
          callPair
        }
      }
    }

    case EForall(binders, whereExprOpt, body) -> {
      var envAcc = env
      val sortBinders: List[SortBinder] = newList()
      var i = 0
      while i < binders.count {
        val b    = binders[i]
        val info = sortOfTypeExpr(b.ty)
        envAcc   = envBind(b.name, info, envAcc)
        sortBinders.add(SortBinder(name = b.name, sort = info.sort))
        i = i + 1
      }
      val (bodyR, bodyDiags) = translateExpr(envAcc, body)
      val (whereTermOpt, whereDiags) = match whereExprOpt {
        case Some(w) -> {
          val (wR, wD) = translateExpr(envAcc, w)
          val forallWherePair: (Option[Term], List[Diagnostic]) = (Some(value = wR.term), wD)
          forallWherePair
        }
        case None -> {
          val wd: List[Diagnostic] = newList()
          val forallNonePair: (Option[Term], List[Diagnostic]) = (None, wd)
          forallNonePair
        }
      }
      val inner = match whereTermOpt {
        case Some(wt) -> mkImplies(wt, bodyR.term)
        case None     -> bodyR.term
      }
      val emptyTriggers: List[List[Term]] = newList()
      val t = TForall(binders = sortBinders, triggers = emptyTriggers, body = inner)
      val allDiags: List[Diagnostic] = newList()
      appendTermList2(allDiags, bodyDiags)
      appendTermList2(allDiags, whereDiags)
      val sc: List[Term] = newList()
      val asList: List[Term] = newList()
      val forallTR = TranslateResult(term = t, sideConds = sc, assumed = asList)
      val forallPair: (TranslateResult, List[Diagnostic]) = (forallTR, allDiags)
      forallPair
    }

    case EExists(binders, whereExprOpt, body) -> {
      var envAcc = env
      val sortBinders: List[SortBinder] = newList()
      var i = 0
      while i < binders.count {
        val b    = binders[i]
        val info = sortOfTypeExpr(b.ty)
        envAcc   = envBind(b.name, info, envAcc)
        sortBinders.add(SortBinder(name = b.name, sort = info.sort))
        i = i + 1
      }
      val (bodyR, bodyDiags) = translateExpr(envAcc, body)
      val (whereTermOpt, whereDiags) = match whereExprOpt {
        case Some(w) -> {
          val (wR, wD) = translateExpr(envAcc, w)
          val existsWherePair: (Option[Term], List[Diagnostic]) = (Some(value = wR.term), wD)
          existsWherePair
        }
        case None -> {
          val wd: List[Diagnostic] = newList()
          val existsNonePair: (Option[Term], List[Diagnostic]) = (None, wd)
          existsNonePair
        }
      }
      val inner = match whereTermOpt {
        case Some(wt) -> {
          val parts: List[Term] = newList()
          parts.add(wt)
          parts.add(bodyR.term)
          mkAnd(parts)
        }
        case None -> bodyR.term
      }
      val t = TExists(binders = sortBinders, body = inner)
      val allDiags: List[Diagnostic] = newList()
      appendTermList2(allDiags, bodyDiags)
      appendTermList2(allDiags, whereDiags)
      val sc: List[Term] = newList()
      val asList: List[Term] = newList()
      val existsTR = TranslateResult(term = t, sideConds = sc, assumed = asList)
      val existsPair: (TranslateResult, List[Diagnostic]) = (existsTR, allDiags)
      existsPair
    }

    case EMember(receiver, memberName) -> {
      val (rR, rDiags) = translateExpr(env, receiver)
      val resultSort = SUninterp(name = "field." + memberName)
      val t = TApp(name = "$field." + memberName, args = termList1(rR.term), retSort = resultSort)
      val sc: List[Term] = newList()
      appendTermList(sc, rR.sideConds)
      val asList: List[Term] = newList()
      appendTermList(asList, rR.assumed)
      val memberTR = TranslateResult(term = t, sideConds = sc, assumed = asList)
      val memberPair: (TranslateResult, List[Diagnostic]) = (memberTR, rDiags)
      memberPair
    }

    case EBlock(blk) -> {
      val lastOpt = blockLastExpr(blk)
      match lastOpt {
        case Some(last) -> translateExpr(env, last)
        case None       -> {
          val blockNoneDiags: List[Diagnostic] = newList()
          val blockNonePair: (TranslateResult, List[Diagnostic]) = (singleTR(unitTerm()), blockNoneDiags)
          blockNonePair
        }
      }
    }

    case EMatch(scrutinee, arms) -> {
      val (scrutR, scrutDiags) = translateExpr(env, scrutinee)
      val allDiags: List[Diagnostic] = newList()
      appendTermList2(allDiags, scrutDiags)
      val allSides:   List[Term] = newList()
      appendTermList(allSides, scrutR.sideConds)
      val allAssumed: List[Term] = newList()
      appendTermList(allAssumed, scrutR.assumed)

      val term = buildMatchIte(env, scrutR.term, arms, 0, allDiags, allSides, allAssumed, e.span)
      val matchTR = TranslateResult(term = term, sideConds = allSides, assumed = allAssumed)
      val matchPair: (TranslateResult, List[Diagnostic]) = (matchTR, allDiags)
      matchPair
    }

    case _ -> {
      val diags: List[Diagnostic] = newList()
      diags.add(warningDiagnostic("V0024",
        "expression construct not yet modelled in proof translation", e.span))
      val exprSort = SUninterp(name = "expr")
      val exprVar = TVar(name = "?expr", sort = exprSort)
      val exprPair: (TranslateResult, List[Diagnostic]) = (singleTR(exprVar), diags)
      exprPair
    }
  }
}

// Translate an ExprOrBlock for use in if-branches.
func translateEOB(env: in VEnv, eob: in ExprOrBlock, ctxSpan: in Span): (TranslateResult, List[Diagnostic]) {
  match eob {
    case EOBExpr(x)  -> translateExpr(env, x)
    case EOBBlock(blk) -> {
      // Extract trailing expression (last SExpr or SReturn).
      val lastOpt = blockLastExpr(blk)
      match lastOpt {
        case Some(x) -> translateExpr(env, x)
        case None    -> {
          val diags: List[Diagnostic] = newList()
          diags.add(warningDiagnostic("V0022",
            "block branches in contract expressions not yet supported in M4.1", ctxSpan))
          val eobNonePair: (TranslateResult, List[Diagnostic]) = (singleTR(trueT()), diags)
          eobNonePair
        }
      }
    }
  }
}

// Extract the last expression from a block.
func blockLastExpr(blk: in Block): Option[Expr] {
  if blk.statements.count == 0 {
    return None
  }
  val last = blk.statements[blk.statements.count - 1]
  match last.kind {
    case SExpr(x)          -> Some(value = x)
    case SReturn(Some(x))  -> Some(value = x)
    case _                 -> {
      // Walk back through all statements looking for last meaningful expr.
      var i = blk.statements.count - 1
      while i >= 0 {
        match blk.statements[i].kind {
          case SExpr(x)         -> { return Some(value = x) }
          case SReturn(Some(x)) -> { return Some(value = x) }
          case _                -> {}
        }
        i = i - 1
      }
      None
    }
  }
}

// Build nested TIte for match arms (trivial patterns only).
func buildMatchIte(
  env:        in VEnv,
  scrutTerm:  in Term,
  arms:       in List[MatchArm],
  idx:        in Int,
  diagsOut:   in List[Diagnostic],
  sidesOut:   in List[Term],
  assumedOut: in List[Term],
  ctxSpan:    in Span
): Term {
  if idx >= arms.count {
    // Non-exhaustive — fallback.
    diagsOut.add(warningDiagnostic("V0029",
      "match in proof-required code is not exhaustive against the M4.1-supported pattern set",
      ctxSpan))
    return TVar(name = "?match.fallthrough", sort = sortOf(scrutTerm))
  }
  val arm = arms[idx]
  val condOpt = matchCond(arm.pattern, scrutTerm)
  match condOpt {
    case None -> {
      // Pattern not supported in M4.1 — skip arm.
      diagsOut.add(warningDiagnostic("V0027",
        "match arm pattern not yet supported in M4.1 verifier", arm.span))
      buildMatchIte(env, scrutTerm, arms, idx + 1, diagsOut, sidesOut, assumedOut, ctxSpan)
    }
    case Some(cond) -> {
      val isUnconditional = isTrueT(cond)
      // Extend env with pattern bindings.
      val bindings = patternBindings(arm.pattern, scrutTerm)
      var armEnv = env
      var bi = 0
      while bi < bindings.count {
        val bname = bindings[bi].bindName
        val bterm = bindings[bi].bindTerm
        val info  = SortInfo(sort = sortOf(bterm), range = RBKNone)
        armEnv    = envBindTerm(bname, bterm, info, armEnv)
        bi = bi + 1
      }
      val armTerm = translateArmBody(armEnv, arm, diagsOut, sidesOut, assumedOut)
      if isUnconditional {
        armTerm
      } else {
        val restTerm = buildMatchIte(env, scrutTerm, arms, idx + 1, diagsOut, sidesOut, assumedOut, ctxSpan)
        TIte(cond = cond, thenT = armTerm, elseT = restTerm)
      }
    }
  }
}

// Auxiliary record for pattern bindings.
record PatBind {
  bindName: String
  bindTerm: Term
}

func translateArmBody(
  env:        in VEnv,
  arm:        in MatchArm,
  diagsOut:   in List[Diagnostic],
  sidesOut:   in List[Term],
  assumedOut: in List[Term]
): Term {
  match arm.body {
    case EOBExpr(x) -> {
      val (r, d) = translateExpr(env, x)
      appendTermList2(diagsOut, d)
      appendTermList(sidesOut, r.sideConds)
      appendTermList(assumedOut, r.assumed)
      r.term
    }
    case EOBBlock(_) -> {
      diagsOut.add(warningDiagnostic("V0028",
        "block-form match arm bodies not yet supported in M4.1 verifier", arm.span))
      val matchblockSort = SUninterp(name = "matchblock")
      TVar(name = "?matchblock", sort = matchblockSort)
    }
  }
}

// Compute match condition for a pattern against a subject term.
// Returns None if the pattern is not supported in M4.1.
func matchCond(pat: in Pattern, subject: in Term): Option[Term] {
  matchCondKind(pat.kind, subject)
}

// Helper to match on PatternKind directly.
// PBinding(name, None) = simple binding — always matches (condition = true).
// PBinding(name, Some(p)) = @ subpattern — M4.1 does not support the inner
// constraint check; we conservatively treat the whole arm as unconditional.
// (The bootstrap emitter cannot reliably match Option[Pattern] extracted from
// union case fields, so we avoid that entirely here.)
func matchCondKind(kind: in PatternKind, subject: in Term): Option[Term] {
  match kind {
    case PWildcard      -> Some(value = trueT())
    case PBinding(_, _) -> Some(value = trueT())
    case PLiteral(lit)      -> {
      val litTerm = translateLit(lit)
      Some(value = TBuiltin(op = BOpEq, args = termList2(subject, litTerm)))
    }
    case PParen(inner) -> matchCondKind(inner.kind, subject)
    case _             -> None
  }
}

// Collect (name, term) bindings from a pattern applied to a subject.
func patternBindings(pat: in Pattern, subject: in Term): List[PatBind] {
  val result: List[PatBind] = newList()
  collectBindings(pat.kind, subject, result)
  result
}

func collectBindings(kind: in PatternKind, subject: in Term, output: in List[PatBind]): Unit {
  match kind {
    case PBinding(name, innerOpt) -> {
      output.add(PatBind(bindName = name, bindTerm = subject))
      match innerOpt {
        case Some(p) -> collectBindings(p.kind, subject, output)
        case None    -> {}
      }
    }
    case PParen(inner) -> collectBindings(inner.kind, subject, output)
    case _             -> {}
  }
}

func isTrueT(t: in Term): Bool {
  match t {
    case TLit(VLBool(true), _) -> true
    case _                    -> false
  }
}

// Append helpers for List[Diagnostic] (which is List[T] where T is Diagnostic).
func appendTermList2(dst: in List[Diagnostic], src: in List[Diagnostic]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Contract translation helper.
// ─────────────────────────────────────────────────────────────────────────────

// Translate a contract expression: side conditions folded into the term,
// assumed facts returned separately.
func translateContract(env: in VEnv, e: in Expr): (Term, List[Term], List[Diagnostic]) {
  val (r, diags) = translateExpr(env, e)
  val term = if r.sideConds.count == 0 {
    r.term
  } else {
    val parts: List[Term] = newList()
    appendTermList(parts, r.sideConds)
    parts.add(r.term)
    mkAnd(parts)
  }
  val contractTriple: (Term, List[Term], List[Diagnostic]) = (term, r.assumed, diags)
  contractTriple
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. WP result and side goals.
// ─────────────────────────────────────────────────────────────────────────────

pub record SideGoal {
  pub term: Term
  pub kind: GoalKind
  pub span: Span
}

pub record WpResult {
  pub wp:        Term
  pub sideGoals: List[SideGoal]
  pub assumed:   List[Term]
  pub diags:     List[Diagnostic]
}

func emptyWpResult(wp: in Term): WpResult {
  val sg: List[SideGoal]   = newList()
  val asList: List[Term]       = newList()
  val di: List[Diagnostic] = newList()
  WpResult(wp = wp, sideGoals = sg, assumed = asList, diags = di)
}

func mergeWpResults(a: in WpResult, b: in WpResult, wp: in Term): WpResult {
  val sg: List[SideGoal]   = newList()
  var i = 0
  while i < a.sideGoals.count { sg.add(a.sideGoals[i]); i = i + 1 }
  i = 0
  while i < b.sideGoals.count { sg.add(b.sideGoals[i]); i = i + 1 }
  val asList: List[Term] = newList()
  appendTermList(asList, a.assumed)
  appendTermList(asList, b.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, a.diags)
  appendTermList2(di, b.diags)
  WpResult(wp = wp, sideGoals = sg, assumed = asList, diags = di)
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. WP over a function body.
// ─────────────────────────────────────────────────────────────────────────────

// WP over a single expression (for FBExpr).
func wpExpr(env: in VEnv, resultSort: in SortInfo, postcond: in Term, e: in Expr): WpResult {
  val (r, diags) = translateExpr(env, e)
  // Substitute result into postcond.
  val substMap: Map[String, Term] = newMap()
  substMap.add("result", r.term)
  val substMapNames: List[String] = newList()
  substMapNames.add("result")
  val wp = substTerm(substMap, substMapNames, postcond)
  val sideGoals: List[SideGoal] = newList()
  var i = 0
  while i < r.sideConds.count {
    sideGoals.add(SideGoal(term = r.sideConds[i], kind = GKAssertion, span = e.span))
    i = i + 1
  }
  WpResult(wp = wp, sideGoals = sideGoals, assumed = r.assumed, diags = diags)
}

pub func wpBody(env: in VEnv, resultSort: in SortInfo, postcond: in Term, body: in FunctionBody): WpResult {
  match body {
    case FBExpr(e)   -> wpExpr(env, resultSort, postcond, e)
    case FBBlock(blk) -> wpBlock(env, resultSort, postcond, blk.statements)
  }
}

pub func wpBlock(env: in VEnv, resultSort: in SortInfo, postcond: in Term, stmts: in List[Statement]): WpResult {
  wpWalk(env, resultSort, postcond, stmts, 0)
}

func wpWalk(env: in VEnv, resultSort: in SortInfo, postcond: in Term, stmts: in List[Statement], idx: in Int): WpResult {
  if idx >= stmts.count {
    // Empty tail — postcond[result := unit].
    val substMap: Map[String, Term] = newMap()
    substMap.add("result", unitTerm())
    val substMapNames: List[String] = newList()
    substMapNames.add("result")
    val wp = substTerm(substMap, substMapNames, postcond)
    emptyWpResult(wp)
  } else {
    val st = stmts[idx]
    match st.kind {
      case SReturn(Some(e)) -> {
        wpExpr(env, resultSort, postcond, e)
      }
      case SReturn(None) -> {
        val substMap: Map[String, Term] = newMap()
        substMap.add("result", unitTerm())
        val substMapNames: List[String] = newList()
        substMapNames.add("result")
        val wp = substTerm(substMap, substMapNames, postcond)
        emptyWpResult(wp)
      }
      case SExpr(callExpr) -> {
        // Check if this is `assert(φ)`.
        match tryExtractAssert(callExpr) {
          case Some(argExpr) -> {
            // assert φ: add as side goal, assume φ for continuation.
            val (phiR, phiDiags) = translateExpr(env, argExpr)
            val inner = wpWalk(env, resultSort, postcond, stmts, idx + 1)
            val sg: List[SideGoal] = newList()
            sg.add(SideGoal(term = phiR.term, kind = GKAssertion, span = callExpr.span))
            var i = 0
            while i < inner.sideGoals.count { sg.add(inner.sideGoals[i]); i = i + 1 }
            val asList: List[Term] = newList()
            asList.add(phiR.term)
            appendTermList(asList, phiR.assumed)
            appendTermList(asList, inner.assumed)
            val di: List[Diagnostic] = newList()
            appendTermList2(di, phiDiags)
            appendTermList2(di, inner.diags)
            WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
          }
          case None -> {
            // Check if it's an if statement.
            match tryExtractIf(callExpr) {
              case Some(ifTriple) -> {
                wpIfStmt(env, resultSort, postcond, stmts, idx, ifTriple.cond, ifTriple.thenBranch, ifTriple.elseBranchOpt, st.span)
              }
              case None -> {
                // General call or expression statement.
                match callExpr.kind {
                  case ECall(_, _) -> {
                    val (callR, callDiags) = translateExpr(env, callExpr)
                    val inner = wpWalk(env, resultSort, postcond, stmts, idx + 1)
                    val sg: List[SideGoal] = newList()
                    var i = 0
                    while i < callR.sideConds.count {
                      sg.add(SideGoal(term = callR.sideConds[i], kind = GKAssertion, span = callExpr.span))
                      i = i + 1
                    }
                    i = 0
                    while i < inner.sideGoals.count { sg.add(inner.sideGoals[i]); i = i + 1 }
                    val asList: List[Term] = newList()
                    appendTermList(asList, callR.assumed)
                    appendTermList(asList, inner.assumed)
                    val di: List[Diagnostic] = newList()
                    appendTermList2(di, callDiags)
                    appendTermList2(di, inner.diags)
                    WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
                  }
                  case _ -> {
                    // Other SExpr — skip.
                    wpWalk(env, resultSort, postcond, stmts, idx + 1)
                  }
                }
              }
            }
          }
        }
      }
      case SLocal(binding) -> {
        wpLocal(env, resultSort, postcond, stmts, idx, binding, st.span)
      }
      case SAssign(target, op, value) -> {
        wpAssign(env, resultSort, postcond, stmts, idx, target, op, value, st.span)
      }
      case SWhile(_, cond, body) -> {
        wpWhile(env, resultSort, postcond, stmts, idx, cond, body, st.span)
      }
      case SInvariant(_) -> {
        // SInvariant outside a loop is a user error (lyric-lang #418 §7).
        // Emit a diagnostic so the misplaced clause is surfaced, then
        // walk on so the rest of the body still gets verified.
        val rest = wpWalk(env, resultSort, postcond, stmts, idx + 1)
        val di: List[Diagnostic] = newList()
        di.add(warningDiagnostic("V0030",
          "invariant: clause outside loop head is ignored; move it onto a while/loop",
          st.span))
        var k: Int = 0
        while k < rest.diags.count { di.add(rest.diags[k]); k = k + 1 }
        WpResult(wp = rest.wp, sideGoals = rest.sideGoals, assumed = rest.assumed, diags = di)
      }
      case _ -> {
        val di: List[Diagnostic] = newList()
        di.add(errorDiagnostic("V0026",
          "statement form not yet supported in M4.1 verifier; proof is unsound here", st.span))
        val sg: List[SideGoal]   = newList()
        val asList: List[Term]       = newList()
        WpResult(wp = falseT(), sideGoals = sg, assumed = asList, diags = di)
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. WP statement helpers.
// ─────────────────────────────────────────────────────────────────────────────

// Try to extract `assert(<arg>)` from an expression.
func tryExtractAssert(e: in Expr): Option[Expr] {
  match e.kind {
    case ECall(fn, args) -> {
      if args.count == 1 {
        match fn.kind {
          case EPath(path) -> {
            if path.segments.count == 1 and path.segments[0] == "assert" {
              match args[0] {
                case CAPositional(v)  -> Some(value = v)
                case CANamed(_, v, _) -> Some(value = v)
              }
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

// Auxiliary record for if-statement extraction.
record IfTriple {
  cond:          Expr
  thenBranch:    ExprOrBlock
  elseBranchOpt: Option[ExprOrBlock]
}

func tryExtractIf(e: in Expr): Option[IfTriple] {
  match e.kind {
    case EIf(cond, thenBranch, elseBranchOpt, _) -> {
      Some(value = IfTriple(cond = cond, thenBranch = thenBranch, elseBranchOpt = elseBranchOpt))
    }
    case _ -> None
  }
}

func wpIfStmt(
  env:           in VEnv,
  resultSort:    in SortInfo,
  postcond:      in Term,
  stmts:         in List[Statement],
  idx:           in Int,
  cond:          in Expr,
  thenBranch:    in ExprOrBlock,
  elseBranchOpt: in Option[ExprOrBlock],
  sp:            in Span
): WpResult {
  val (condR, condDiags) = translateExpr(env, cond)

  // Convert ExprOrBlock to statement list.
  val thenStmts = eobToStmts(thenBranch)
  val elseStmts = match elseBranchOpt {
    case Some(eb) -> eobToStmts(eb)
    case None     -> {
      val empty: List[Statement] = newList()
      empty
    }
  }
  // Collect rest of the block.
  val rest: List[Statement] = newList()
  var ri = idx + 1
  while ri < stmts.count {
    rest.add(stmts[ri])
    ri = ri + 1
  }

  // Append rest to each branch.
  val thenFull: List[Statement] = newList()
  appendStmtList(thenFull, thenStmts)
  appendStmtList(thenFull, rest)
  val elseFull: List[Statement] = newList()
  appendStmtList(elseFull, elseStmts)
  appendStmtList(elseFull, rest)

  val thenR = wpWalk(env, resultSort, postcond, thenFull, 0)
  val elseR = wpWalk(env, resultSort, postcond, elseFull, 0)

  val notCond = mkNot(condR.term)
  // Guard branch side goals by their branch condition.
  val sg: List[SideGoal] = newList()
  var i = 0
  while i < condR.sideConds.count {
    sg.add(SideGoal(term = condR.sideConds[i], kind = GKAssertion, span = sp))
    i = i + 1
  }
  i = 0
  while i < thenR.sideGoals.count {
    val g = thenR.sideGoals[i]
    sg.add(SideGoal(term = mkImplies(condR.term, g.term), kind = g.kind, span = g.span))
    i = i + 1
  }
  i = 0
  while i < elseR.sideGoals.count {
    val g = elseR.sideGoals[i]
    sg.add(SideGoal(term = mkImplies(notCond, g.term), kind = g.kind, span = g.span))
    i = i + 1
  }

  val asList: List[Term] = newList()
  appendTermList(asList, thenR.assumed)
  appendTermList(asList, elseR.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, condDiags)
  appendTermList2(di, thenR.diags)
  appendTermList2(di, elseR.diags)
  WpResult(wp = TIte(cond = condR.term, thenT = thenR.wp, elseT = elseR.wp),
    sideGoals = sg, assumed = asList, diags = di)
}

func eobToStmts(eob: in ExprOrBlock): List[Statement] {
  match eob {
    case EOBBlock(b) -> b.statements
    case EOBExpr(e)  -> {
      val lst: List[Statement] = newList()
      lst.add(Statement(kind = SExpr(expr = e), span = e.span))
      lst
    }
  }
}

func appendStmtList(dst: in List[Statement], src: in List[Statement]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

func wpLocal(
  env:       in VEnv,
  resultSort: in SortInfo,
  postcond:  in Term,
  stmts:     in List[Statement],
  idx:       in Int,
  binding:   in LocalBinding,
  sp:        in Span
): WpResult {
  match binding {
    case LBVal(pat, _, init) -> {
      val name = match pat.kind {
        case PBinding(n, _) -> n
        case _              -> "?pat"
      }
      val (initR, initDiags) = translateExpr(env, init)
      val info = SortInfo(sort = sortOf(initR.term), range = RBKNone)
      val env2 = envBindTerm(name, initR.term, info, env)
      val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
      val asList: List[Term] = newList()
      appendTermList(asList, initR.assumed)
      appendTermList(asList, inner.assumed)
      val di: List[Diagnostic] = newList()
      appendTermList2(di, initDiags)
      appendTermList2(di, inner.diags)
      WpResult(wp = inner.wp, sideGoals = inner.sideGoals, assumed = asList, diags = di)
    }
    case LBLet(name, _, init) -> {
      val (initR, initDiags) = translateExpr(env, init)
      val info = SortInfo(sort = sortOf(initR.term), range = RBKNone)
      val env2 = envBindTerm(name, initR.term, info, env)
      val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
      val asList: List[Term] = newList()
      appendTermList(asList, initR.assumed)
      appendTermList(asList, inner.assumed)
      val di: List[Diagnostic] = newList()
      appendTermList2(di, initDiags)
      appendTermList2(di, inner.diags)
      WpResult(wp = inner.wp, sideGoals = inner.sideGoals, assumed = asList, diags = di)
    }
    case LBVar(name, _, Some(init)) -> {
      val (initR, initDiags) = translateExpr(env, init)
      val info = SortInfo(sort = sortOf(initR.term), range = RBKNone)
      val env2 = envBindTerm(name, initR.term, info, env)
      val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
      val asList: List[Term] = newList()
      appendTermList(asList, initR.assumed)
      appendTermList(asList, inner.assumed)
      val di: List[Diagnostic] = newList()
      appendTermList2(di, initDiags)
      appendTermList2(di, inner.diags)
      WpResult(wp = inner.wp, sideGoals = inner.sideGoals, assumed = asList, diags = di)
    }
    case LBVar(name, _, None) -> {
      // Uninitialized var — bind to fresh symbolic value.
      val info = SortInfo(sort = SInt, range = RBKNone)
      val env2 = envBind(name, info, env)
      wpWalk(env2, resultSort, postcond, stmts, idx + 1)
    }
  }
}

func wpAssign(
  env:        in VEnv,
  resultSort: in SortInfo,
  postcond:   in Term,
  stmts:      in List[Statement],
  idx:        in Int,
  target:     in Expr,
  op:         in AssignOp,
  value:      in Expr,
  sp:         in Span
): WpResult {
  match target.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        val (rhsR, rhsDiags) = translateExpr(env, value)
        val combined = match op {
          case AssEq -> rhsR.term
          case _     -> {
            val existing = match envLookup(name, env) {
              case Some(t) -> t
              case None    -> TVar(name = name, sort = SInt)
            }
            val bin = match op {
              case AssPlus    -> BOpAdd
              case AssMinus   -> BOpSub
              case AssStar    -> BOpMul
              case AssSlash   -> BOpDiv
              case AssPercent -> BOpMod
              case _          -> BOpAdd
            }
            TBuiltin(op = bin, args = termList2(existing, rhsR.term))
          }
        }
        val info = match envLookupSort(name, env) {
          case Some(si) -> si
          case None     -> SortInfo(sort = sortOf(combined), range = RBKNone)
        }
        val env2 = envBindTerm(name, combined, info, env)
        val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
        val asList: List[Term] = newList()
        appendTermList(asList, rhsR.assumed)
        appendTermList(asList, inner.assumed)
        val di: List[Diagnostic] = newList()
        appendTermList2(di, rhsDiags)
        appendTermList2(di, inner.diags)
        WpResult(wp = inner.wp, sideGoals = inner.sideGoals, assumed = asList, diags = di)
      } else {
        val di: List[Diagnostic] = newList()
        di.add(warningDiagnostic("V0026",
          "complex assignment target not yet supported in proof body", target.span))
        val inner = wpWalk(env, resultSort, postcond, stmts, idx + 1)
        val allDi: List[Diagnostic] = newList()
        appendTermList2(allDi, di)
        appendTermList2(allDi, inner.diags)
        WpResult(wp = inner.wp, sideGoals = inner.sideGoals, assumed = inner.assumed, diags = allDi)
      }
    }
    case _ -> {
      val di: List[Diagnostic] = newList()
      di.add(warningDiagnostic("V0026",
        "complex assignment target not yet supported in proof body", target.span))
      val inner = wpWalk(env, resultSort, postcond, stmts, idx + 1)
      val allDi: List[Diagnostic] = newList()
      appendTermList2(allDi, di)
      appendTermList2(allDi, inner.diags)
      WpResult(wp = inner.wp, sideGoals = inner.sideGoals, assumed = inner.assumed, diags = allDi)
    }
  }
}

func wpWhile(
  env:        in VEnv,
  resultSort: in SortInfo,
  postcond:   in Term,
  stmts:      in List[Statement],
  idx:        in Int,
  cond:       in Expr,
  body:       in Block,
  sp:         in Span
): WpResult {
  // Partition SInvariant stmts from real body.
  val invExprs:   List[Expr]      = newList()
  val realStmts:  List[Statement] = newList()
  var i = 0
  while i < body.statements.count {
    match body.statements[i].kind {
      case SInvariant(ie) -> invExprs.add(ie)
      case _              -> realStmts.add(body.statements[i])
    }
    i = i + 1
  }

  // Translate invariant terms.
  val invTerms: List[Term]       = newList()
  val invDiags: List[Diagnostic] = newList()
  i = 0
  while i < invExprs.count {
    val (invT, _, invDs) = translateContract(env, invExprs[i])
    invTerms.add(invT)
    appendTermList2(invDiags, invDs)
    i = i + 1
  }
  val iotaT = mkAnd(invTerms)

  val (condR, condDiags) = translateExpr(env, cond)

  // Preserve: wp(realBody, iota) under the invariant environment.
  val preservePostcond = iotaT
  val bodyBlock = Block(statements = realStmts, span = body.span)
  val bodyWp = wpBody(env, resultSort, preservePostcond, FBBlock(block = bodyBlock))
  val preserveCond = mkImplies(mkAnd(termList2(iotaT, condR.term)), bodyWp.wp)

  // Havoc modified variables.
  val modifiedVars: List[String] = newList()
  collectModifiedVars(realStmts, modifiedVars)
  var envAfterHavoc = env
  i = 0
  while i < modifiedVars.count {
    val vname = modifiedVars[i]
    val vinfo = match envLookupSort(vname, env) {
      case Some(si) -> si
      case None     -> SortInfo(sort = SInt, range = RBKNone)
    }
    val havocName = vname + "$loopout"
    envAfterHavoc = envBindTerm(vname, TVar(name = havocName, sort = vinfo.sort), vinfo, envAfterHavoc)
    i = i + 1
  }

  // Re-translate invariant and cond in post-havoc env.
  val iotaPostTerms: List[Term]       = newList()
  val iotaPostDiags: List[Diagnostic] = newList()
  i = 0
  while i < invExprs.count {
    val (invT, _, invDs) = translateContract(envAfterHavoc, invExprs[i])
    iotaPostTerms.add(invT)
    appendTermList2(iotaPostDiags, invDs)
    i = i + 1
  }
  val iotaPostT = mkAnd(iotaPostTerms)
  val (condPostR, _) = translateExpr(envAfterHavoc, cond)

  // Post-loop assumed: iota /\ !cond.
  val postLoopAssumed: List[Term] = newList()
  postLoopAssumed.add(iotaPostT)
  postLoopAssumed.add(mkNot(condPostR.term))

  // Collect rest of stmts.
  val rest: List[Statement] = newList()
  var ri = idx + 1
  while ri < stmts.count {
    rest.add(stmts[ri])
    ri = ri + 1
  }
  val inner = wpWalk(envAfterHavoc, resultSort, postcond, rest, 0)

  val sg: List[SideGoal] = newList()
  sg.add(SideGoal(term = iotaT, kind = GKLoopEstablish, span = sp))
  sg.add(SideGoal(term = preserveCond, kind = GKLoopPreserve, span = sp))
  i = 0
  while i < bodyWp.sideGoals.count { sg.add(bodyWp.sideGoals[i]); i = i + 1 }
  i = 0
  while i < inner.sideGoals.count { sg.add(inner.sideGoals[i]); i = i + 1 }

  val asList: List[Term] = newList()
  appendTermList(asList, condR.assumed)
  appendTermList(asList, bodyWp.assumed)
  appendTermList(asList, postLoopAssumed)
  appendTermList(asList, inner.assumed)

  val di: List[Diagnostic] = newList()
  appendTermList2(di, invDiags)
  appendTermList2(di, condDiags)
  appendTermList2(di, bodyWp.diags)
  appendTermList2(di, inner.diags)

  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

// Collect names of variables modified by SAssign in a statement list.
func collectModifiedVars(stmts: in List[Statement], output: in List[String]): Unit {
  var i = 0
  while i < stmts.count {
    collectModifiedVarsSt(stmts[i], output)
    i = i + 1
  }
}

func collectModifiedVarsSt(st: in Statement, output: in List[String]): Unit {
  match st.kind {
    case SAssign(target, _, _) -> {
      match target.kind {
        case EPath(path) -> {
          if path.segments.count == 1 {
            val name = path.segments[0]
            if not output.contains(name) { output.add(name) }
          }
        }
        case _ -> {}
      }
    }
    case SWhile(_, _, body) -> collectModifiedVars(body.statements, output)
    case SFor(_, _, _, body) -> collectModifiedVars(body.statements, output)
    case SLoop(_, body) -> collectModifiedVars(body.statements, output)
    case SDefer(body) -> collectModifiedVars(body.statements, output)
    case SScope(_, body) -> collectModifiedVars(body.statements, output)
    case STry(body, _) -> collectModifiedVars(body.statements, output)
    case _ -> {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Goals for a single function.
// ─────────────────────────────────────────────────────────────────────────────

pub func goalsForFunction(env0: in VEnv, decl: in FunctionDecl): (List[Goal], List[Diagnostic]) {
  // Bind parameters.
  var envWithParams = env0
  val paramHyps: List[Term] = newList()
  var i = 0
  while i < decl.params.count {
    val p    = decl.params[i]
    val info = sortOfTypeExpr(p.ty)
    envWithParams = envBind(p.name, info, envWithParams)
    val hyps = rangeHypotheses(p.name, info)
    appendTermList(paramHyps, hyps)
    i = i + 1
  }

  // Result sort.
  val resultSort = match decl.ret {
    case Some(te) -> sortOfTypeExpr(te)
    case None     -> unitSortInfo()
  }

  // Bind `result` for postcondition translation.
  val envWithResult = envBind("result", resultSort, envWithParams)

  // Bind old-snapshot entries: old.<name> := <name> for each param.
  var envWithOld = envWithResult
  i = 0
  while i < decl.params.count {
    val p    = decl.params[i]
    val info = sortOfTypeExpr(p.ty)
    val t    = TVar(name = p.name, sort = info.sort)
    envWithOld = envBindTerm("old." + p.name, t, info, envWithOld)
    i = i + 1
  }

  // Translate requires clauses.
  val preTerms:   List[Term]       = newList()
  val preAssumed: List[Term]       = newList()
  val preDiags:   List[Diagnostic] = newList()
  i = 0
  while i < decl.contracts.count {
    match decl.contracts[i] {
      case CCRequires(e, _) -> {
        val (t, asList, d) = translateContract(envWithParams, e)
        preTerms.add(t)
        appendTermList(preAssumed, asList)
        appendTermList2(preDiags, d)
      }
      case _ -> {}
    }
    i = i + 1
  }
  val preTerm = mkAnd(preTerms)

  // Translate ensures clauses.
  val postTerms:   List[Term]       = newList()
  val postAssumed: List[Term]       = newList()
  val postDiags:   List[Diagnostic] = newList()
  i = 0
  while i < decl.contracts.count {
    match decl.contracts[i] {
      case CCEnsures(e, _) -> {
        val (t, asList, d) = translateContract(envWithOld, e)
        postTerms.add(t)
        appendTermList(postAssumed, asList)
        appendTermList2(postDiags, d)
      }
      case _ -> {}
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
    case None    -> {
      // No body: @axiom-like, no VCs.
      val unit = Expr(kind = ELiteral(lit = LUnit), span = decl.span)
      FBExpr(expr = unit)
    }
  }

  // Build postcondition term with result variable (will be substituted by WP).
  val resultVar = TVar(name = "result", sort = resultSort.sort)
  val rangeTerms: List[Term] = newList()
  match resultSort.range {
    case RBKNone -> {}
    case RBKClosed(lo, hi) -> {
      rangeTerms.add(TBuiltin(op = BOpLte, args = termList2(TLit(value = VLInt(n = lo), sort = SInt), resultVar)))
      rangeTerms.add(TBuiltin(op = BOpLte, args = termList2(resultVar, TLit(value = VLInt(n = hi), sort = SInt))))
    }
    case RBKHalfOpen(lo, hi) -> {
      rangeTerms.add(TBuiltin(op = BOpLte, args = termList2(TLit(value = VLInt(n = lo), sort = SInt), resultVar)))
      rangeTerms.add(TBuiltin(op = BOpLt,  args = termList2(resultVar, TLit(value = VLInt(n = hi), sort = SInt))))
    }
  }
  val allPostParts: List[Term] = newList()
  allPostParts.add(postTerm)
  appendTermList(allPostParts, rangeTerms)
  val combinedPost = mkAnd(allPostParts)

  val wpRes = wpBody(envWithOld, resultSort, combinedPost, body)

  // Main goal hypotheses.
  val hypotheses: List[Term] = newList()
  appendTermList(hypotheses, paramHyps)
  hypotheses.add(preTerm)
  appendTermList(hypotheses, preAssumed)
  appendTermList(hypotheses, postAssumed)
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
    symbols    = symbolsList,
    origin     = decl.span,
    kind       = GKPostcondition(fnName = decl.name),
    label      = decl.name + "$post"
  )

  // Side goals.
  val sideHyps: List[Term] = newList()
  appendTermList(sideHyps, paramHyps)
  sideHyps.add(preTerm)

  val goals: List[Goal] = newList()
  goals.add(mainGoal)
  i = 0
  while i < wpRes.sideGoals.count {
    val sg = wpRes.sideGoals[i]
    val sideSymbols: List[SymbolDecl] = newList()
    var si = 0
    while si < env0.symbols.count {
      sideSymbols.add(env0.symbols[si])
      si = si + 1
    }
    goals.add(Goal(
      hypotheses = sideHyps,
      conclusion = sg.term,
      symbols    = sideSymbols,
      origin     = sg.span,
      kind       = sg.kind,
      label      = decl.name + "$side"
    ))
    i = i + 1
  }

  val allDiags: List[Diagnostic] = newList()
  appendTermList2(allDiags, preDiags)
  appendTermList2(allDiags, postDiags)
  appendTermList2(allDiags, wpRes.diags)
  val goalPair: (List[Goal], List[Diagnostic]) = (goals, allDiags)
  goalPair
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Goals for an entire file.
// ─────────────────────────────────────────────────────────────────────────────

// Return a copy of env with a fresh (empty) symbols list.
func freshSymbolsEnv(env: in VEnv): VEnv {
  val freshSyms: List[SymbolDecl] = newList()
  VEnv(vars = env.vars, varNames = env.varNames, sorts = env.sorts, callees = env.callees,
    symbols = freshSyms, checkedArithmetic = env.checkedArithmetic)
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
      case _ -> {}
    }
    mi = mi + 1
  }
  result
}

// Synthesize a FunctionDecl for a protected-type entry and verify it.
// Results are accumulated into allGoals / allDiags (no tuple return needed).
func goalsForProtectedEntry(
  level:        in VerificationLevel,
  env0:         in VEnv,
  protName:     in String,
  ed:           in EntryDecl,
  invContracts: in List[ContractClause],
  allGoals:     in List[Goal],
  allDiags:     in List[Diagnostic]
): Unit {
  val entryContracts: List[ContractClause] = newList()
  var eci = 0
  while eci < invContracts.count { entryContracts.add(invContracts[eci]); eci = eci + 1 }
  val entryOwn = ed.contracts
  eci = 0
  while eci < entryOwn.count { entryContracts.add(entryOwn[eci]); eci = eci + 1 }
  val noDocComments: List[DocComment] = newList()
  val noAnnotations: List[Annotation] = newList()
  val entryBody: Option[FunctionBody] = Some(value = ed.body)
  val synthDecl: FunctionDecl = FunctionDecl(
    docComments = noDocComments,
    annotations = noAnnotations,
    visibility  = ed.visibility,
    isAsync     = false,
    name        = protName + "::" + ed.name,
    generics    = None,
    params      = ed.params,
    ret         = ed.ret,
    whereClause = None,
    contracts   = entryContracts,
    body        = entryBody,
    span        = ed.span)
  val fnLevel = levelOfFunction(level, synthDecl)
  if vlIsProofRequired(fnLevel) {
    val fnEnv = freshSymbolsEnv(env0)
    val (goals, diags) = goalsForFunction(fnEnv, synthDecl)
    var gi = 0
    while gi < goals.count { allGoals.add(goals[gi]); gi = gi + 1 }
    appendTermList2(allDiags, diags)
  }
}

// Verify a protected-type PMFunc helper that has its own contracts.
// Results are accumulated into allGoals / allDiags.
func goalsForProtectedFunc(
  level:    in VerificationLevel,
  env0:     in VEnv,
  fn:       in FunctionDecl,
  allGoals: in List[Goal],
  allDiags: in List[Diagnostic]
): Unit {
  val fnLevel = levelOfFunction(level, fn)
  if vlIsProofRequired(fnLevel) {
    val fnEnv = freshSymbolsEnv(env0)
    val (goals, diags) = goalsForFunction(fnEnv, fn)
    var gi = 0
    while gi < goals.count { allGoals.add(goals[gi]); gi = gi + 1 }
    appendTermList2(allDiags, diags)
  }
}

// Iterate over protected-type members and collect goals for entries and funcs.
func goalsForProtectedMembers(
  level:        in VerificationLevel,
  env0:         in VEnv,
  protName:     in String,
  members:      in List[ProtectedMember],
  invContracts: in List[ContractClause],
  allGoals:     in List[Goal],
  allDiags:     in List[Diagnostic]
): Unit {
  var mi = 0
  while mi < members.count {
    match members[mi] {
      case PMEntry(ed)    -> { goalsForProtectedEntry(level, env0, protName, ed, invContracts, allGoals, allDiags) }
      case PMFunc(fn)     -> { goalsForProtectedFunc(level, env0, fn, allGoals, allDiags) }
      case _              -> {}
    }
    mi = mi + 1
  }
}

pub func goalsForFile(file: in SourceFile, level: in VerificationLevel): (List[Goal], List[Diagnostic]) {
  if not vlIsProofRequired(level) {
    val noGoals: List[Goal]       = newList()
    val noDiags: List[Diagnostic] = newList()
    return (noGoals, noDiags)
  }

  // Build callee table from file's IFunc and protected-type PMFunc items.
  val callees: Map[String, FunctionDecl] = newMap()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> callees.add(fn.name, fn)
      case IProtected(decl) -> {
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case PMFunc(fn) -> callees.add(decl.name + "::" + fn.name, fn)
            case PMEntry(ed) -> {
              // Synthesise a minimal FunctionDecl so cross-entry Hoare-call
              // lookups resolve.  Uses the entry's own contracts only; the
              // invariant augmentation is applied during goal generation.
              val noDoc: List[DocComment] = newList()
              val noAnn: List[Annotation] = newList()
              val entryFn: FunctionDecl = FunctionDecl(
                docComments = noDoc,
                annotations = noAnn,
                visibility  = ed.visibility,
                isAsync     = false,
                name        = decl.name + "::" + ed.name,
                generics    = None,
                params      = ed.params,
                ret         = ed.ret,
                whereClause = None,
                contracts   = ed.contracts,
                body        = Some(value = ed.body),
                span        = ed.span)
              callees.add(decl.name + "::" + ed.name, entryFn)
            }
            case _ -> {}
          }
          mi = mi + 1
        }
      }
      case _ -> {}
    }
    i = i + 1
  }

  val checkedArith = match level {
    case VLProofRequiredChecked -> true
    case _                      -> false
  }
  val sharedSymbols: List[SymbolDecl] = newList()
  val env0 = envEmpty(callees, sharedSymbols, checkedArith)

  val allGoals: List[Goal]       = newList()
  val allDiags: List[Diagnostic] = newList()

  i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        val fnLevel = levelOfFunction(level, fn)
        if vlIsProofRequired(fnLevel) {
          val fnEnv = freshSymbolsEnv(env0)
          val (goals, diags) = goalsForFunction(fnEnv, fn)
          var gi = 0
          while gi < goals.count { allGoals.add(goals[gi]); gi = gi + 1 }
          appendTermList2(allDiags, diags)
        }
      }
      case IProtected(decl) -> {
        val invContracts: List[ContractClause] = collectProtectedInvariants(decl)
        goalsForProtectedMembers(level, env0, decl.name, decl.members, invContracts, allGoals, allDiags)
      }
      case _ -> {}
    }
    i = i + 1
  }

  (allGoals, allDiags)
}
