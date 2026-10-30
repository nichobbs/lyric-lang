//! verifier/vcgen_expr.l — expression translation, value blocks, quantifiers and lambdas.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

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
          case None -> {
            if name == "None" {
              val noArgs: List[Term] = newList()
              val nonePair: (TranslateResult, List[Diagnostic]) = (singleTR(mkPendingCtor("None", noArgs)), diags)
              return nonePair
            }
            // A function this file declares, named as a value: one value
            // per function, of the sort function-typed values have.
            if env.callees.containsKey(name) and not isSome(findRecordFields(env, name)) {
              val fnPair: (TranslateResult, List[Diagnostic]) = (singleTR(functionRefTerm(name)), diags)
              return fnPair
            }
            // No binding the walk tracks declares the name — every local,
            // parameter and pattern binding has one — so it is declared at
            // module level, where a `val` never changes: one name is one
            // value.  `global!` keeps it apart from a parameter or binding
            // spelt the same in another scope (#8109).
            val uSort = match mapGet(env.distincts, globalTypeKey(name)) {
              case Some(te) -> sortOfTypeExprWith(env.distincts, te).sort
              case None -> SUninterp(name = "global!" + name)
            }
            val t = TVar(name = "global!" + name, sort = uSort)
            val ePair: (TranslateResult, List[Diagnostic]) = (singleTR(t), diags)
            ePair
          }
        }
      } else {
        // Multi-segment path — join with "." and emit uninterpreted.
        var joined = ""
        var i = 0
        while i < path.segments.count {
          if i > 0 {
            joined = joined + "."
          }
          joined = joined + path.segments[i]
          i = i + 1
        }
        val pathSort = SUninterp(name = "path")
        val t = TVar(name = joined, sort = pathSort)
        val pathPair: (TranslateResult, List[Diagnostic]) = (singleTR(t), diags)
        pathPair
      }
    }

    // A method's receiver, the parameter `self` (#8231).
    case ESelf -> {
      val diags: List[Diagnostic] = newList()
      match envLookup("self", env) {
        case Some(t) -> (singleTR(t), diags)
        case None -> {
          diags.add(warningDiagnostic("V0024", "expression construct not yet modelled in proof translation", e.span))
          val selfPair: (TranslateResult, List[Diagnostic]) = (singleTR(freshVar(env, "self", SUninterp(name = "self"))), diags)
          selfPair
        }
      }
    }

    case EResult -> {
      val diags: List[Diagnostic] = newList()
      match envLookup("result", env) {
        case Some(t) -> (singleTR(t), diags)
        case None -> {
          diags.add(errorDiagnostic("V0020", "`result` is only valid inside `ensures:` clauses", e.span))
          val resultSort2 = SUninterp(name = "result")
          val t = TVar(name = "result", sort = resultSort2)
          val resultPair: (TranslateResult, List[Diagnostic]) = (singleTR(t), diags)
          resultPair
        }
      }
    }

    case EOld(inner) -> {
      // `old(e)` is `e` evaluated where every name with an entry snapshot
      // (`old.<name>`: a parameter, an `out`/`inout` parameter, a protected
      // type's field) has its value on entry — never `e`'s current value
      // (#8102).  A name an enclosing quantifier binds is the bound
      // variable to the type checker but has a snapshot here: an operand
      // that reads one fails closed (#8214).
      val shadowed = quantifierShadowedSnapshots(env)
      if shadowed.count == 0 {
        return translateExpr(envAtEntry(env), inner)
      }
      var probeEnv = envAtEntry(env)
      var si = 0
      while si < shadowed.count {
        match envLookupSort(shadowed[si], env) {
          case Some(info) -> {
            probeEnv = envBindTerm(shadowed[si], TVar(name = oldShadowSentinel(shadowed[si]), sort = info.sort), info, probeEnv)
          }
          case None -> ()
        }
        si = si + 1
      }
      val (oldR, oldDiags) = translateExpr(probeEnv, inner)
      val read = freeVarsOfTerm(oldR.term)
      var ri = 0
      while ri < shadowed.count {
        if read.contains(oldShadowSentinel(shadowed[ri])) {
          oldDiags.add(
            untranslatableDiag(
              "`old(...)` reads `" + shadowed[ri] + "`, which an enclosing quantifier binds; rename the bound variable",
              e.span
            )
          )
          val oldPoisonTR = TranslateResult(term = poisonTerm(oldR.term), sideConds = oldR.sideConds, assumed = oldR.assumed)
          val oldPoisonPair: (TranslateResult, List[Diagnostic]) = (oldPoisonTR, oldDiags)
          return oldPoisonPair
        }
        ri = ri + 1
      }
      translateExpr(envAtEntry(env), inner)
    }

    case EIf(cond, thenBranch, elseBranchOpt, _) -> {
      val (condR, condDiags) = translateExpr(env, cond)
      // The branches run after the condition, in the state it leaves: a
      // variable it passes to an `out`/`inout` parameter holds a new value
      // there (#8107).
      val afterCond = havocOutArgs(env, cond)

      // A branch's side conditions and facts hold when it is taken.
      val (thenRaw, thenDiags) = translateEOB(afterCond.env, thenBranch, e.span)
      val thenR = guardTR(condR.term, thenRaw)

      val (elseRaw, elseDiags) = match elseBranchOpt {
        case Some(eb) -> translateEOB(afterCond.env, eb, e.span)
        case None -> {
          val ed: List[Diagnostic] = newList()
          val noBranchPair: (TranslateResult, List[Diagnostic]) = (singleTR(unitTerm()), ed)
          noBranchPair
        }
      }

      val elseR = guardTR(mkNot(condR.term), elseRaw)
      val branchDiags: List[Diagnostic] = newList()
      val term = match unifyOperands(thenR.term, elseR.term) {
        case Ok(pair) -> TIte(cond = condR.term, thenT = pair.lhs, elseT = pair.rhs)
        case Err(reason) -> {
          branchDiags.add(untranslatableDiag(reason, e.span))
          poisonTerm(TIte(cond = condR.term, thenT = thenR.term, elseT = elseR.term))
        }
      }
      val sc: List[Term] = newList()
      appendTermList(sc, condR.sideConds)
      appendTermList(sc, thenR.sideConds)
      appendTermList(sc, elseR.sideConds)
      val asList: List[Term] = newList()
      appendTermList(asList, condR.assumed)
      appendTermList(asList, afterCond.hyps)
      appendTermList(asList, thenR.assumed)
      appendTermList(asList, elseR.assumed)
      val allDiags: List[Diagnostic] = newList()
      appendTermList2(allDiags, condDiags)
      appendTermList2(allDiags, thenDiags)
      appendTermList2(allDiags, elseDiags)
      appendTermList2(allDiags, branchDiags)
      val ifTR = TranslateResult(term = term, sideConds = sc, assumed = asList)
      val ifPair: (TranslateResult, List[Diagnostic]) = (ifTR, allDiags)
      ifPair
    }

    case EPrefix(op, operand) -> {
      // A minus applied directly to a signed or unsuffixed literal is one
      // signed constant (#7853), so `-9223372036854775808` is Long.MinValue
      // rather than the negation of its magnitude's pattern.
      match op {
        case PreNeg -> match foldIntLiteral(e) {
          case Some(folded) -> {
            val negDiags: List[Diagnostic] = newList()
            val negPair: (TranslateResult, List[Diagnostic]) = (
              singleTR(TLit(value = VLInt(n = folded.value), sort = SInt)),
              negDiags
            )
            return negPair
          }
          case None -> ()
        }
        case _ -> ()
      }
      val (xR, xDiags) = translateExpr(env, operand)
      match builtinOfPrefix(op) {
        case Some(b) -> {
          val unsignedNeg = match b {
            case BOpNeg -> match sortOf(xR.term) {
              case SBitVec(_) -> {
                xDiags.add(untranslatableDiag("an unsigned value is negated", e.span))
                true
              }
              case _ -> false
            }
            case _ -> false
          }
          val sc: List[Term] = newList()
          appendTermList(sc, xR.sideConds)
          val asList: List[Term] = newList()
          appendTermList(asList, xR.assumed)
          val rawT = TBuiltin(op = b, args = termList1(xR.term))
          val t = if unsignedNeg { poisonTerm(rawT) } else { rawT }
          // `-x` overflows for the type's minimum (D163, #7871).
          if env.checkedArithmetic {
            match b {
              case BOpNeg -> match sortOf(xR.term) {
                case SInt -> appendTermList(sc, signedWidthBounds(t, overflowBitsOfExpr(env, operand)))
                case _ -> ()
              }
              case _ -> ()
            }
          }
          val prefixTR = TranslateResult(term = t, sideConds = sc, assumed = asList)
          val prefixBuiltinPair: (TranslateResult, List[Diagnostic]) = (prefixTR, xDiags)
          prefixBuiltinPair
        }
        case None -> {
          val diags: List[Diagnostic] = newList()
          appendTermList2(diags, xDiags)
          val prefixSort = SUninterp(name = "prefix")
          val prefixVar = freshVar(env, "prefix", prefixSort)
          // The operator is not modelled, but its operand is still
          // evaluated: its obligations and facts stand (#8107).
          val prefixTR = TranslateResult(term = prefixVar, sideConds = xR.sideConds, assumed = xR.assumed)
          val prefixPair: (TranslateResult, List[Diagnostic]) = (prefixTR, diags)
          prefixPair
        }
      }
    }

    case EBinop(op, lhs, rhs) -> {
      val (lR, lDiags) = translateExpr(env, lhs)
      // The right operand runs after the left one, in the state it leaves
      // (#8107).
      val afterLhs = havocOutArgs(env, lhs)
      val (rRawUnseq, rDiags) = translateExpr(afterLhs.env, rhs)
      val rRaw = TranslateResult(
        term = rRawUnseq.term,
        sideConds = rRawUnseq.sideConds,
        assumed = termsWith(afterLhs.hyps, rRawUnseq.assumed)
      )
      // The right operand of `and`, `or` and `implies` is evaluated only
      // when the left one does not decide the result: its side conditions
      // and facts hold under that condition alone (#8102).
      // `a ?? b` evaluates `b` only when `a` is null, which the verifier
      // does not model: an unknown condition, so `b`'s side conditions must
      // hold however it falls and its facts give nothing (#8107).
      val coalesce = match op { case BCoalesce -> true; case _ -> false }
      val optionLhs = coalesce and isOptionSort(sortOf(lR.term))
      val rR = if optionLhs {
        guardTR(mkNot(mkIsSome(lR.term)), rRaw)
      } else if coalesce {
        guardTR(freshVar(env, "isnull", SBool), rRaw)
      } else {
        match builtinOfBinop(op) {
          case Some(BOpAnd) -> guardTR(lR.term, rRaw)
          case Some(BOpImplies) -> guardTR(lR.term, rRaw)
          case Some(BOpOr) -> guardTR(mkNot(lR.term), rRaw)
          case _ -> rRaw
        }
      }
      // `a ?? b` on an `Option` left operand is its payload when it is a
      // `Some`, else `b`, which runs on that path alone (#8168).
      if optionLhs {
        match coerceToSort(rR.term, monadArgSort(sortOf(lR.term), 0)) {
          case Ok(rAt) -> {
            val joined = TIte(cond = mkIsSome(lR.term), thenT = mkOptionValue(lR.term), elseT = rAt)
            val coalesced = if termIsPoisoned(lR.term) or termIsPoisoned(rR.term) { poisonTerm(joined) } else { joined }
            val coalesceSides: List[Term] = newList()
            appendTermList(coalesceSides, lR.sideConds)
            appendTermList(coalesceSides, afterFacts(lR.assumed, rR.sideConds))
            val coalesceDiags: List[Diagnostic] = newList()
            appendTermList2(coalesceDiags, lDiags)
            appendTermList2(coalesceDiags, rDiags)
            val coalesceTR = TranslateResult(
              term = coalesced,
              sideConds = coalesceSides,
              assumed = termsWith(lR.assumed, rR.assumed)
            )
            val coalescePair: (TranslateResult, List[Diagnostic]) = (coalesceTR, coalesceDiags)
            return coalescePair
          }
          case Err(_) -> ()
        }
      }
      match builtinOfBinop(op) {
        case Some(rawB) -> {
          // Float operands → use real division instead of integer div.
          val b = match rawB {
            case BOpDiv -> {
              match sortOf(lR.term) {
                case SFloat32 -> BOpRealDiv
                case SFloat64 -> BOpRealDiv
                case _ -> BOpDiv
              }
            }
            case _ -> rawB
          }
          val sortDiags: List[Diagnostic] = newList()
          val args = if isSortUnifyingBuiltin(b) {
            match unifyOperands(lR.term, rR.term) {
              case Ok(pair) -> termList2(pair.lhs, pair.rhs)
              case Err(reason) -> {
                sortDiags.add(untranslatableDiag(reason, e.span))
                termList2(lR.term, rR.term)
              }
            }
          } else {
            termList2(lR.term, rR.term)
          }
          // `==` the verifier's equality does not model faithfully on every
          // target fails closed (`equalityModelled`, #8109).
          match b {
            case BOpEq | BOpNeq -> {
              if not equalityModelled(env, lR.term) or not equalityModelled(env, rR.term) {
                sortDiags.add(
                  untranslatableDiag(
                    "an equality between values that may be or hold a function, compare by identity, or be of a type the verifier does not know",
                    e.span
                  )
                )
              }
            }
            case _ -> ()
          }
          val term = if sortDiags.count > 0 { poisonTerm(TBuiltin(op = b, args = args)) } else { TBuiltin(op = b, args = args) }
          val sc: List[Term] = newList()
          appendTermList(sc, lR.sideConds)
          appendTermList(sc, afterFacts(lR.assumed, rR.sideConds))
          // The operation's own side conditions are checked once both
          // operands are evaluated.
          val ownSides: List[Term] = newList()
          // Integer division and remainder by zero panic in every build
          // profile: the divisor must be non-zero (#8107).
          appendTermList(ownSides, divisorSideConds(b, args, intBitsOfExpr(env, e)))
          // @proof_required(checked_arithmetic): overflow side conditions.
          // A signed result must stay inside its type's width — 32 bits
          // for `Int`, 64 for `Long` — since an overflow panics in a debug
          // build and wraps in a release one (D163, #7871).
          if env.checkedArithmetic {
            match sortOf(args[0]) {
              case SInt -> {
                match b {
                  case BOpAdd | BOpSub | BOpMul -> appendTermList(ownSides, signedWidthBounds(term, overflowBitsOfExpr(env, e)))
                  case _ -> {
                  }
                }
              }
              case SBitVec(w) -> appendTermList(ownSides, unsignedOverflowSideConds(b, args[0], args[1], term, w))
              case _ -> {
              }
            }
          }
          val asList: List[Term] = newList()
          appendTermList(asList, lR.assumed)
          appendTermList(asList, rR.assumed)
          appendTermList(sc, afterFacts(asList, ownSides))
          val allDiags: List[Diagnostic] = newList()
          appendTermList2(allDiags, lDiags)
          appendTermList2(allDiags, rDiags)
          appendTermList2(allDiags, sortDiags)
          val binopTR = TranslateResult(term = term, sideConds = sc, assumed = asList)
          val binopPairResult: (TranslateResult, List[Diagnostic]) = (binopTR, allDiags)
          binopPairResult
        }
        case None -> {
          val diags: List[Diagnostic] = newList()
          diags.add(warningDiagnostic("V0023", "binary operator not yet modelled in proof translation", e.span))
          appendTermList2(diags, lDiags)
          appendTermList2(diags, rDiags)
          val binopSort = SUninterp(name = "binop")
          val binopVar = freshVar(env, "binop", binopSort)
          // The operator is not modelled, but its operands are still
          // evaluated: their obligations and facts stand (#8107).
          val binopTR = TranslateResult(
            term = binopVar,
            sideConds = termsWith(lR.sideConds, rR.sideConds),
            assumed = termsWith(lR.assumed, rR.assumed)
          )
          val binopPair: (TranslateResult, List[Diagnostic]) = (binopTR, diags)
          binopPair
        }
      }
    }

    case ECall(fn, args) -> {
      // `f[T](args)` calls `f`: its type arguments change nothing the
      // verifier models, and its `out`/`inout` arguments are found the
      // same way (#8102).
      match typeAppCallee(env, fn) {
        case Some(inner) -> {
          return translateExpr(env, Expr(kind = ECall(fn = inner, args = args), span = e.span))
        }
        case None -> ()
      }
      // Translate all arguments first.
      val rawArgTerms: List[Term] = newList()
      val argSpans: List[Span] = newList()
      val argSides: List[Term] = newList()
      val argAssumed: List[Term] = newList()
      val allArgDiags: List[Diagnostic] = newList()
      // Arguments run left to right: one evaluated after an argument that
      // passes a variable to an `out`/`inout` parameter sees its new value
      // (#8107).  Before them all runs the callee: a method's receiver, or a
      // computed callee (`pick(zero(x))(pos(x))`) — translated in `env` below,
      // so the arguments start from the state it leaves.
      val calleeExpr: Expr = match fn.kind { case EMember(receiver, _) -> receiver; case _ -> fn }
      val afterCallee = havocOutArgs(env, calleeExpr)
      appendTermList(argAssumed, afterCallee.hyps)
      var argEnv = afterCallee.env
      var i = 0
      while i < args.count {
        val argExpr = match args[i] { case CANamed(_, v, _) -> v; case CAPositional(v) -> v }
        val (ar, ad) = translateExpr(argEnv, argExpr)
        rawArgTerms.add(ar.term)
        argSpans.add(argExpr.span)
        appendTermList(argSides, afterFacts(argAssumed, ar.sideConds))
        appendTermList(argAssumed, ar.assumed)
        appendTermList2(allArgDiags, ad)
        val afterArg = havocOutArgs(argEnv, argExpr)
        appendTermList(argAssumed, afterArg.hyps)
        argEnv = afterArg.env
        i = i + 1
      }
      // Arguments run as written, positional and named alike, and pair with
      // the parameters by `pairArgTerms`; omitted parameters' defaults,
      // which read no local, after them (D171).

      // A local binding — a lambda in a `val` — shadows a file function of
      // the same name: the call goes through the binding (#8102).  One
      // that holds a function this file declares, as it does here, calls
      // that function: its current value, so a reassigned binding calls
      // the function it was last given (#8109).
      if localCallee(env, fn) {
        match boundFunctionOf(env, fn) {
          case Some(decl) -> {
            return translateResolvedCall(
              env,
              decl.name,
              decl,
              args,
              rawArgTerms,
              argSpans,
              e.span,
              argSides,
              argAssumed,
              allArgDiags
            )
          }
          case None -> ()
        }
        return translateComputedCall(env, fn, rawArgTerms, argSides, argAssumed, allArgDiags)
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
              if j > 0 {
                name = name + "."
              }
              name = name + path.segments[j]
              j = j + 1
            }
          }

          // Record-constructor short-circuit (#3843): if `name` is a
          // registered record, return a TApp whose retSort is the record's
          // SDatatype — the SMT renderer recognises the symbol as the
          // declared datatype's constructor and z3 typechecks the call.
          match findRecordFields(env, name) {
            case Some(recFields) -> {
              // A field default that constructs its own record again (or
              // unfolds too deeply) would recurse without end: fail closed.
              val recordKey = "record!" + name
              if env.contractStack.contains(recordKey) or env.contractStack.count >= maxUnfoldDepth() {
                allArgDiags.add(untranslatableDiag("a default of record '" + name + "' that constructs it again", e.span))
                val emptyRecArgs: List[Sort] = newList()
                val loopTR = TranslateResult(
                  term = poisonTerm(freshVar(env, name, SDatatype(name = name, args = emptyRecArgs))),
                  sideConds = argSides,
                  assumed = argAssumed
                )
                val loopPair: (TranslateResult, List[Diagnostic]) = (loopTR, allArgDiags)
                return loopPair
              }
              // Arguments go to fields by name, positional ones in order,
              // and an omitted field takes its default (#7873).  Selectors
              // are registered as `<Record>__<field>`.
              val fieldNames: List[String] = newList()
              val fieldSorts: List[Sort] = newList()
              val prefix = name + "__"
              var fi = 0
              while fi < recFields.count {
                val fname = recFields[fi].name
                fieldNames.add(
                  if fname.startsWith(prefix) { fname.substring(prefix.length, fname.length - prefix.length) } else { fname }
                )
                fieldSorts.add(recFields[fi].sort)
                fi = fi + 1
              }
              val fieldDefaults: List[Option[Expr]] = match mapGet(env.recordDefaults, name) {
                case Some(ds) -> ds
                case None -> {
                  val noDefaults: List[Option[Expr]] = newList()
                  noDefaults
                }
              }
              // A generic record's type arguments are those its field
              // values give it (#8340), read from the arguments before they
              // take their fields' sorts, so a `Some(x)`/`Ok(x)` argument
              // takes the instantiated field sort; one the arguments leave
              // open, or give two sorts, is not known, and the value fails
              // closed.
              val recParams = recordSortParams(env, name)
              val recTypeArgs: List[Sort] = newList()
              var recInferred = true
              val slotSorts: List[Sort] = newList()
              if recParams.count > 0 {
                val bound: List[Option[Sort]] = newList()
                var bi = 0
                while bi < recParams.count {
                  bound.add(None)
                  bi = bi + 1
                }
                match pairCallArgs(fieldNames, 0, args) {
                  case Ok(slots) -> {
                    var ti = 0
                    while ti < slots.count and ti < fieldSorts.count {
                      if slots[ti] >= 0 and not matchArgSortParams(fieldSorts[ti], rawArgTerms[slots[ti]], recParams, bound) {
                        recInferred = false
                      }
                      ti = ti + 1
                    }
                  }
                  case Err(_) -> {
                    recInferred = false
                  }
                }
                for b in bound {
                  match b {
                    case Some(bs) -> recTypeArgs.add(bs)
                    case None -> {
                      recInferred = false
                    }
                  }
                }
                if recInferred {
                  for fs in fieldSorts {
                    slotSorts.add(substSortParams(fs, recParams, recTypeArgs))
                  }
                }
              } else {
                for fs in fieldSorts {
                  slotSorts.add(fs)
                }
              }
              if not recInferred {
                allArgDiags.add(
                  untranslatableDiag(
                    "a value of the generic record '" + name + "' whose type arguments its fields do not determine",
                    e.span
                  )
                )
                val openTR = TranslateResult(
                  term = poisonTerm(freshVar(env, name, SUninterp(name = "generic." + name))),
                  sideConds = argSides,
                  assumed = argAssumed
                )
                val openPair: (TranslateResult, List[Diagnostic]) = (openTR, allArgDiags)
                return openPair
              }
              val recPaired = pairArgTerms(
                name,
                fieldNames,
                slotSorts,
                fieldDefaults,
                envInOwnContract(varlessEnv(env), recordKey),
                args,
                rawArgTerms,
                argSpans,
                e.span,
                argSides,
                argAssumed,
                allArgDiags
              )
              val recRetSort: Sort = SDatatype(name = name, args = recTypeArgs)
              val recCallTerm = TApp(name = name, args = recPaired.terms, retSort = recRetSort)
              val recSc: List[Term] = newList()
              appendTermList(recSc, argSides)
              val recAs: List[Term] = newList()
              appendTermList(recAs, argAssumed)
              val recTR = TranslateResult(term = recCallTerm, sideConds = recSc, assumed = recAs)
              val recPair: (TranslateResult, List[Diagnostic]) = (recTR, allArgDiags)
              return recPair
            }
            case None -> ()
          }
          // Inside a protected type, a bare call reaches the type's own
          // member, which may change the type's fields and whose contract
          // speaks of them: not modelled yet, so fail closed (#8102).
          if path.segments.count == 1 and env.protectedMembers.contains(name) {
            match envLookup(name, env) {
              case Some(_) -> ()
              case None -> {
                val memberDiags: List[Diagnostic] = newList()
                appendTermList2(memberDiags, allArgDiags)
                memberDiags.add(untranslatableDiag("a call to '" + name + "', a member of the enclosing protected type", e.span))
                val memberTerm = poisonTerm(freshVar(env, name + "!result", SUninterp(name = "call")))
                val memberTR = TranslateResult(term = memberTerm, sideConds = argSides, assumed = argAssumed)
                val memberPair: (TranslateResult, List[Diagnostic]) = (memberTR, memberDiags)
                return memberPair
              }
            }
          }
          // A name its package declares more than once reaches the
          // declaration taking the call's argument count; a call no single
          // declaration takes that way fails closed (#8341).
          if calleeIsOverloaded(env, name) {
            match resolveOverloadedCallee(env, name, args) {
              case Some(odecl) -> {
                return translateResolvedCall(
                  env,
                  odecl.name,
                  odecl,
                  args,
                  rawArgTerms,
                  argSpans,
                  e.span,
                  argSides,
                  argAssumed,
                  allArgDiags
                )
              }
              case None -> {
                allArgDiags.add(
                  untranslatableDiag(
                    "a call to '" + name +
                      "', which its package declares more than once, that no single declaration takes by its argument count",
                    e.span
                  )
                )
                val ambTR = TranslateResult(
                  term = poisonTerm(freshVar(env, name + "!result", SUninterp(name = "call"))),
                  sideConds = argSides,
                  assumed = argAssumed
                )
                val ambPair: (TranslateResult, List[Diagnostic]) = (ambTR, allArgDiags)
                return ambPair
              }
            }
          }
          match mapGet(env.callees, name) {
            case Some(decl) -> {
              return translateResolvedCall(
                env,
                decl.name,
                decl,
                args,
                rawArgTerms,
                argSpans,
                e.span,
                argSides,
                argAssumed,
                allArgDiags
              )
            }
            case None -> {
              // Distinct-type constructor (`UserId(n)`) — `pub type UserId = Long`
              // makes UserId a nominal wrapper around Long.  The verifier
              // treats it transparently: the constructor call IS the
              // underlying value, just at the underlying sort.  Without this
              // the unknown-callee branch below emits a TApp with sort
              // SUninterp("call.UserId") which z3 then refuses to use in
              // arithmetic (#3853).
              // `Ok(v)`, `isOk(r)`, … of the standard library (#8108).
              match monadCall(name, args, rawArgTerms) {
                case Some(mt) -> {
                  val monadTR = TranslateResult(term = mt, sideConds = argSides, assumed = argAssumed)
                  val monadPair: (TranslateResult, List[Diagnostic]) = (monadTR, allArgDiags)
                  return monadPair
                }
                case None -> ()
              }
              if isFileDistinct(env, name) and rawArgTerms.count == 1 {
                return translateDistinctConstruction(
                  env,
                  name,
                  rawArgTerms[0],
                  argSpans[0],
                  e.span,
                  argSides,
                  argAssumed,
                  allArgDiags
                )
              }
              // A callee this file does not declare — another file's or
              // package's function, or one the verifier does not model.
              // Whether it is `@pure` is not known here, so its result is
              // a value of its own at this call site: two calls of it are
              // never taken for equal (#8109).
              val t = callSiteResult(env, name, rawArgTerms, SUninterp(name = "call." + name))
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
          // `T.from(x)` on a distinct type `T` constructs a `T`: the
          // argument's value, which must lie in `T`'s range when `T` is a
          // range subtype — `from` panics outside it (#7872).
          match distinctFromCallee(env, fn) {
            case Some(typeName) -> {
              if rawArgTerms.count == 1 {
                return translateDistinctConstruction(
                  env,
                  typeName,
                  rawArgTerms[0],
                  argSpans[0],
                  e.span,
                  argSides,
                  argAssumed,
                  allArgDiags
                )
              }
            }
            case None -> ()
          }
          match fn.kind {
            case EMember(receiver, methodName) -> translateMethodCall(
              env,
              receiver,
              methodName,
              args,
              rawArgTerms,
              argSpans,
              e.span,
              argSides,
              argAssumed,
              allArgDiags
            )
            case _ -> translateComputedCall(env, fn, rawArgTerms, argSides, argAssumed, allArgDiags)
          }
        }
      }
    }

    case EForall(binders, whereExprOpt, body, _) -> translateQuantifier(env, binders, whereExprOpt, body, true)

    case EExists(binders, whereExprOpt, body, _) -> translateQuantifier(env, binders, whereExprOpt, body, false)

    case EMember(receiver, memberName) -> {
      val (rR, rDiags) = translateExpr(env, receiver)
      // If the receiver's sort is a registered record datatype and `memberName`
      // names one of its fields, emit the SMT datatype selector
      // `(<TypeName>__<memberName> receiver)` with the field's actual sort.
      // The selector is registered with the prefixed name in the DeclDatatype
      // to avoid z3 ambiguity with same-named free constants (#3855).
      // Otherwise fall back to an uninterpreted `$field.<memberName>` symbol
      // — the SMT renderer will declare it as a uninterpreted function (#3843).
      val recvSort = sortOf(rR.term)
      // `.isOk`, `.value`, … of a `Result` or `Option` (#8108).
      match monadMember(rR.term, memberName) {
        case Some(acc) -> {
          val accSides: List[Term] = newList()
          appendTermList(accSides, rR.sideConds)
          appendTermList(accSides, acc.sides)
          val accFacts: List[Term] = newList()
          appendTermList(accFacts, rR.assumed)
          val accTR = TranslateResult(term = acc.term, sideConds = accSides, assumed = accFacts)
          val accPair: (TranslateResult, List[Diagnostic]) = (accTR, rDiags)
          return accPair
        }
        case None -> ()
      }
      val recvRecName: String = match recvSort { case SDatatype(rName, _) -> rName; case _ -> "" }
      val recordFieldHit: Option[Sort] = if recvRecName.length > 0 {
        findRecordFieldSort(env, recvSort, memberName)
      } else {
        None
      }
      val t = match recordFieldHit {
        case Some(fSort) -> TApp(name = recvRecName + "__" + memberName, args = termList1(rR.term), retSort = fSort)
        case None -> {
          if (memberName == "count" or memberName == "length") and isSequenceSort(recvSort) {
            lengthTerm(rR.term)
          } else if memberName == "value" and isPrimitiveSort(recvSort) {
            // `x.value` on a distinct value reads its underlying value, which
            // is how the verifier already represents `x` (#7872).
            rR.term
          } else {
            val unkSort = SUninterp(name = "field." + memberName)
            TApp(name = "$field." + memberName, args = termList1(rR.term), retSort = unkSort)
          }
        }
      }
      val sc: List[Term] = newList()
      appendTermList(sc, rR.sideConds)
      val asList: List[Term] = newList()
      appendTermList(asList, rR.assumed)
      // A field of a range subtype or of `Int`/`Long` holds a value of its
      // type (#7871, #7872).
      match recordFieldHit {
        case Some(_) -> match mapGet(env.fieldInfos, recvRecName + "__" + memberName) {
          case Some(fi) -> appendTermList(asList, valueFactsForTerm(t, fi))
          case None -> ()
        }
        case None -> ()
      }
      val memberTR = TranslateResult(term = t, sideConds = sc, assumed = asList)
      val memberPair: (TranslateResult, List[Diagnostic]) = (memberTR, rDiags)
      memberPair
    }

    case EBlock(blk) -> translateBlockValue(env, blk, e.span)

    case EMatch(scrutinee, arms) -> {
      val (scrutR, scrutDiags) = translateExpr(env, scrutinee)
      val allDiags: List[Diagnostic] = newList()
      appendTermList2(allDiags, scrutDiags)
      val allSides: List[Term] = newList()
      appendTermList(allSides, scrutR.sideConds)
      val allAssumed: List[Term] = newList()
      appendTermList(allAssumed, scrutR.assumed)

      val noReach: List[Term] = newList()
      // A binding of the whole scrutinee has its type: its width and range
      // (#8107).
      val scrutInfo = match staticSortInfoOfExpr(env, scrutinee) {
        case Some(si) -> si
        case None -> SortInfo(
          sort = sortOf(scrutR.term),
          range = RBKNone,
          intBits = intBitsOfExpr(env, scrutinee)
        )
      }
      // The arms run after the scrutinee, in the state it leaves (#8107).
      val afterScrut = havocOutArgs(env, scrutinee)
      appendTermList(allAssumed, afterScrut.hyps)
      val term = buildMatchIte(
        afterScrut.env,
        scrutR.term,
        scrutInfo,
        arms,
        0,
        noReach,
        allDiags,
        allSides,
        allAssumed,
        e.span
      )
      val matchTR = TranslateResult(term = term, sideConds = allSides, assumed = allAssumed)
      val matchPair: (TranslateResult, List[Diagnostic]) = (matchTR, allDiags)
      matchPair
    }

    case EUnsafe(blk) -> translateBlockValue(env, blk, e.span)

    case ELambda(params, body) -> translateLambda(env, params, body, e.span)

    // A `?` the statement walk did not split (one inside a block used as a
    // value, or a contract): its early return is not modelled, so it fails
    // closed (#8108).
    case EPropagate(inner) -> {
      val (iR, iDiags) = translateExpr(env, inner)
      val pDiags: List[Diagnostic] = newList()
      appendTermList2(pDiags, iDiags)
      pDiags.add(untranslatableDiag("a `?` whose early return the verifier cannot split the path at here", e.span))
      val pTR = TranslateResult(
        term = poisonTerm(freshVar(env, "propagate", SUninterp(name = "propagate"))),
        sideConds = iR.sideConds,
        assumed = iR.assumed
      )
      val pPair: (TranslateResult, List[Diagnostic]) = (pTR, pDiags)
      pPair
    }

    // `xs[i]` panics unless `0 <= i < xs.length`, so a read is an obligation
    // (#8157).  Its value is not modelled: a fresh value of the element sort.
    case EIndex(receiver, indices) -> {
      val (rR, rDiags) = translateExpr(env, receiver)
      val diags: List[Diagnostic] = newList()
      appendTermList2(diags, rDiags)
      val sc: List[Term] = newList()
      appendTermList(sc, rR.sideConds)
      val asList: List[Term] = newList()
      appendTermList(asList, rR.assumed)
      val afterRecv = havocOutArgs(env, receiver)
      appendTermList(asList, afterRecv.hyps)
      val subEnv = afterRecv.env
      var idxTerm: Option[Term] = None
      if indices.count == 1 {
        val (iR, iDiags) = translateExpr(subEnv, indices[0])
        appendTermList2(diags, iDiags)
        appendTermList(sc, iR.sideConds)
        appendTermList(asList, iR.assumed)
        idxTerm = Some(value = iR.term)
      }
      val recvSort = sortOf(rR.term)
      val elemSort: Sort = match recvSort {
        case SSlice(el) -> el
        case SArray(el) -> el
        case SDatatype(dn, dargs) -> if dn == "List" and dargs.count == 1 {
          dargs[0]
        } else {
          SUninterp(name = "element")
        }
        case SString -> SInt
        case _ -> SUninterp(name = "element")
      }
      val indexOk = match idxTerm {
        case Some(it) -> isSequenceSort(recvSort) and sortEq(sortOf(it), SInt)
        case None -> false
      }
      if indexOk {
        val it = match idxTerm { case Some(x) -> x; case None -> unitTerm() }
        val inRange = termList2(
          TBuiltin(op = BOpLte, args = termList2(TLit(value = VLInt(n = 0i64), sort = SInt), it)),
          TBuiltin(op = BOpLt, args = termList2(it, lengthTerm(rR.term)))
        )
        sc.add(mkAnd(inRange))
        val idxTR = TranslateResult(term = freshVar(env, "elem", elemSort), sideConds = sc, assumed = asList)
        val idxPair: (TranslateResult, List[Diagnostic]) = (idxTR, diags)
        return idxPair
      }
      diags.add(untranslatableDiag("an index into a value whose length or index the verifier does not model", e.span))
      val badTR = TranslateResult(term = poisonTerm(freshVar(env, "elem", elemSort)), sideConds = sc, assumed = asList)
      val badPair: (TranslateResult, List[Diagnostic]) = (badTR, diags)
      badPair
    }

    case _ -> {
      val diags: List[Diagnostic] = newList()
      diags.add(warningDiagnostic("V0024", "expression construct not yet modelled in proof translation", e.span))
      // The construct's value is unknown, but the subexpressions it
      // evaluates still are: their obligations and facts stand (#8107).
      val sc: List[Term] = newList()
      val asList: List[Term] = newList()
      val subs = evaluatedSubexprs(e)
      var subEnv = env
      var si = 0
      while si < subs.count {
        val (subR, subDiags) = translateExpr(subEnv, subs[si])
        appendTermList2(diags, subDiags)
        appendTermList(sc, subR.sideConds)
        appendTermList(asList, subR.assumed)
        // Subexpressions run in order (#8107).
        val afterSub = havocOutArgs(subEnv, subs[si])
        appendTermList(asList, afterSub.hyps)
        subEnv = afterSub.env
        si = si + 1
      }
      val exprSort = SUninterp(name = "expr")
      val exprVar = freshVar(env, "expr", exprSort)
      val exprTR = TranslateResult(term = exprVar, sideConds = sc, assumed = asList)
      val exprPair: (TranslateResult, List[Diagnostic]) = (exprTR, diags)
      exprPair
    }
  }
}

// Translate an ExprOrBlock for use in if-branches.
func translateEOB(env: in VEnv, eob: in ExprOrBlock, ctxSpan: in Span): (TranslateResult, List[Diagnostic]) {
  match eob {
    case EOBExpr(x) -> translateExpr(env, x)
    case EOBBlock(blk) -> translateBlockValue(env, blk, ctxSpan)
  }
}

// A block used as a value — an `if`-expression's branch, a match arm, a
// `{ ... }` expression: its statements run in order before its last
// expression gives the value, and every obligation and fact they raise
// stands (#8107).  `val`/`let`/`var` bindings are visible to the rest of
// the block only; `assert`s are obligations and then facts; a variable
// passed to an `out`/`inout` parameter holds a new value from there on.
// An assignment, a jump (`return`, `break`, `continue`, `throw`, `?`) or a
// statement the walk does not model (a loop) changes what follows in a
// way a value cannot carry: those fail closed (V0033).
func translateBlockValue(env: in VEnv, blk: in Block, sp: in Span): (TranslateResult, List[Diagnostic]) {
  val diags: List[Diagnostic] = newList()
  val sides: List[Term] = newList()
  val facts: List[Term] = newList()
  val eff = effectsOfStmts(env, blk.statements)
  if eff.assigned.count > 0 or eff.jumps.count > 0 {
    return blockValueFailsClosed(env, "an assignment or a jump inside a block used as a value", sp, diags)
  }
  var cur = env
  var value = unitTerm()
  var i = 0
  while i < blk.statements.count {
    val st = blk.statements[i]
    val isLast = i + 1 >= blk.statements.count
    value = unitTerm()
    match st.kind {
      case SLocal(binding) -> {
        val bound: Option[BlockBinding] = match binding {
          case LBVal(pat, ty, init) -> match pat.kind {
            case PBinding(n, _) -> Some(
              value = BlockBinding(
                name = n,
                ty = ty,
                init = Some(
                  value = init
                ),
                mutable = false
              )
            )
            case _ -> None
          }
          case LBLet(n, ty, init) -> Some(
            value = BlockBinding(
              name = n,
              ty = ty,
              init = Some(value = init),
              mutable = false
            )
          )
          case LBVar(n, ty, initOpt) -> Some(
            value = BlockBinding(
              name = n,
              ty = ty,
              init = initOpt,
              mutable = true
            )
          )
        }
        match bound {
          case Some(bb) -> {
            match bb.init {
              case Some(init) -> {
                val (initR, initDiags) = translateExpr(cur, init)
                appendTermList2(diags, initDiags)
                appendTermList(sides, initR.sideConds)
                appendTermList(facts, initR.assumed)
                val info = match bb.ty {
                  case Some(t) -> sortOfTypeExprE(cur, t)
                  case None -> SortInfo(sort = sortOf(initR.term), range = RBKNone, intBits = intBitsOfExpr(cur, init))
                }
                val boundTerm = match bb.ty {
                  case Some(_) -> coerceTermAt(initR.term, info.sort, init.span, diags)
                  case None -> initR.term
                }
                val after = havocOutArgs(cur, init)
                appendTermList(facts, after.hyps)
                appendTermList(facts, rangeHypothesesForTerm(boundTerm, info))
                // A `var` is a binding a call or a lambda may change.
                cur = envSetMutable(envBindTerm(bb.name, boundTerm, info, after.env), bb.name, bb.mutable)
              }
              case None -> {
                val info = match bb.ty {
                  case Some(t) -> sortOfTypeExprE(cur, t)
                  case None -> SortInfo(sort = SInt, range = RBKNone)
                }
                val initial = freshVar(env, bb.name, info.sort)
                // Read before any assignment it holds its type's zero, which
                // need not lie in its range (#8214): only its width holds.
                appendTermList(facts, intWidthHypothesesForTerm(initial, info))
                cur = envSetMutable(envBindTerm(bb.name, initial, info, cur), bb.name, bb.mutable)
              }
            }
          }
          case None -> {
            return blockValueFailsClosed(env, "a destructuring binding inside a block used as a value", st.span, diags)
          }
        }
      }
      case SExpr(x) -> {
        match tryExtractAssert(x) {
          case Some(phi) -> {
            val (phiR, phiDiags) = translateExpr(cur, phi)
            appendTermList2(diags, phiDiags)
            val phiParts = ContractParts(sides = phiR.sideConds, facts = phiR.assumed, value = phiR.term, diags = phiDiags)
            sides.add(partsObligation(phiParts))
            appendTermList(facts, phiR.assumed)
            facts.add(phiR.term)
          }
          case None -> {
            val (xR, xDiags) = translateExpr(cur, x)
            appendTermList2(diags, xDiags)
            appendTermList(sides, xR.sideConds)
            appendTermList(facts, xR.assumed)
            val after = havocOutArgs(cur, x)
            appendTermList(facts, after.hyps)
            if isLast {
              value = xR.term
            } else if termIsPoisoned(xR.term) {
              // A V0033 value the block discards still fails its goal.
              sides.add(poisonTerm(falseT()))
            }
            cur = after.env
          }
        }
      }
      case _ -> {
        return blockValueFailsClosed(env, "a statement of this form inside a block used as a value", st.span, diags)
      }
    }
    i = i + 1
  }
  val blockTR = TranslateResult(term = value, sideConds = sides, assumed = facts)
  val blockPair: (TranslateResult, List[Diagnostic]) = (blockTR, diags)
  blockPair
}

record BlockBinding {
  name: String
  ty: Option[TypeExpr]
  init: Option[Expr]
  mutable: Bool
}

func blockValueFailsClosed(
  env: in VEnv, what: in String, sp: in Span, diags: in List[Diagnostic]
): (TranslateResult, List[Diagnostic]) {
  diags.add(untranslatableDiag(what, sp))
  val noFacts: List[Term] = newList()
  val failed = TranslateResult(
    term = poisonTerm(freshVar(env, "block", SUninterp(name = "block"))),
    sideConds = termList1(poisonTerm(falseT())),
    assumed = noFacts
  )
  val failedPair: (TranslateResult, List[Diagnostic]) = (failed, diags)
  failedPair
}

// `forall`/`exists`: each bound variable ranges over the values of its
// declared type, the values a parameter of that type can hold — so the
// quantifier is `forall x. facts(x) and where implies body` or `exists x.
// facts(x) and where and body`, with `facts` a parameter's range and width
// (#8214).  Without them an `exists` over a range subtype would be
// witnessed by a value outside the range, and a `forall` would be checked
// against values the type cannot hold.  Each bound variable is a name of
// its own, so a term the body reads from an enclosing binding of the same
// source name is never captured by it.
//
// The `where` clause and the body are evaluated for each value of the
// domain — an `exists` too, which may try every one before it finds a
// witness — so their side conditions (a callee's `requires:`, a divisor
// that must not be zero, a selector's variant) are obligations under the
// same binders: `forall x. dom(x) implies side(x)` for the `where` clause,
// `forall x. dom(x) and where(x) implies side(x)` for the body (#8223).
// The facts their evaluation brings are not kept: a call's result that does
// not vary with the bound variable would make them claims about every value
// of the domain at once.
func translateQuantifier(
  env: in VEnv,
  binders: in List[PropertyBinder],
  whereExprOpt: in Option[Expr],
  body: in Expr,
  isForall: in Bool,
): (TranslateResult, List[Diagnostic]) {
  var envAcc = env
  val sortBinders: List[SortBinder] = newList()
  val domain: List[Term] = newList()
  var i = 0
  while i < binders.count {
    val b = binders[i]
    val info = sortOfTypeExprE(env, b.ty)
    val boundName = freshName(env, b.name + "!q")
    val bound = TVar(name = boundName, sort = info.sort)
    envAcc = envSetMutable(envBindTerm(b.name, bound, info, envAcc), b.name, false)
    sortBinders.add(SortBinder(name = boundName, sort = info.sort))
    appendTermList(domain, valueFactsForTerm(bound, info))
    i = i + 1
  }
  val allDiags: List[Diagnostic] = newList()
  val (bodyR, bodyDiags) = translateExpr(envAcc, body)
  val guards: List[Term] = newList()
  appendTermList(guards, domain)
  val sc: List[Term] = newList()
  match whereExprOpt {
    case Some(w) -> {
      val (wR, wD) = translateExpr(envAcc, w)
      appendTermList2(allDiags, wD)
      quantifySides(sortBinders, guards, wR.sideConds, sc)
      guards.add(wR.term)
    }
    case None -> ()
  }
  appendTermList2(allDiags, bodyDiags)
  quantifySides(sortBinders, guards, bodyR.sideConds, sc)
  val t = if isForall {
    val emptyTriggers: List[List[Term]] = newList()
    val inner = if guards.count == 0 { bodyR.term } else { mkImplies(mkAnd(guards), bodyR.term) }
    TForall(binders = sortBinders, triggers = emptyTriggers, body = inner)
  } else {
    val parts: List[Term] = newList()
    appendTermList(parts, guards)
    parts.add(bodyR.term)
    TExists(binders = sortBinders, body = mkAnd(parts))
  }
  val asList: List[Term] = newList()
  val quantTR = TranslateResult(term = t, sideConds = sc, assumed = asList)
  val quantPair: (TranslateResult, List[Diagnostic]) = (quantTR, allDiags)
  quantPair
}

// Each of `sides` stated for every value of `binders` where `guards` hold,
// appended to `dst`.  The guards are copied: the caller goes on adding to
// its list, which a conjunction would otherwise share.
func quantifySides(binders: in List[SortBinder], guards: in List[Term], sides: in List[Term], dst: in List[Term]): Unit {
  val noTriggers: List[List[Term]] = newList()
  val held: List[Term] = newList()
  appendTermList(held, guards)
  var i = 0
  while i < sides.count {
    val inner = if held.count == 0 { sides[i] } else { mkImplies(mkAnd(held), sides[i]) }
    dst.add(TForall(binders = binders, triggers = noTriggers, body = inner))
    i = i + 1
  }
}

// A lambda: its value is unknown, but its body may run whenever it is
// called, so the body's obligations must hold for every call — each
// parameter a value of its own of its declared sort, each captured
// binding a call may store into (a `var`, an `out`/`inout` parameter)
// whatever it holds by then, the rest at its value where the lambda is
// made.  Nothing the body establishes is assumed outside it (#8107).
func translateLambda(
  env: in VEnv, params: in List[LambdaParam], body: in Block, sp: in Span
): (TranslateResult, List[Diagnostic]) {
  val captured = havocVars(env, env.mutables, "capture")
  // What holds of the captures and parameters whatever the call: their
  // types' widths and ranges.  Never the body's own facts, which a call's
  // precondition must not be proved from (#8102).
  val inside: List[Term] = newList()
  appendTermList(inside, captured.hyps)
  var lambdaEnv = captured.env
  var pi = 0
  while pi < params.count {
    val p = params[pi]
    val info = match p.ty {
      case Some(t) -> sortOfTypeExprE(env, t)
      case None -> SortInfo(sort = SUninterp(name = "lambdaparam"), range = RBKNone)
    }
    val pVar = freshVar(env, p.name, info.sort)
    appendTermList(inside, valueFactsForTerm(pVar, info))
    lambdaEnv = envSetMutable(envBindTerm(p.name, pVar, info, lambdaEnv), p.name, false)
    pi = pi + 1
  }
  // The body is walked as a function body is: its statements' obligations
  // are side goals, and its path's own obligation (false where it has a
  // statement the verifier cannot follow) must hold too.  Its value is not
  // constrained.
  val noFinals: List[FinalSlot] = newList()
  val lambdaResult = SortInfo(sort = SUninterp(name = "lambdaresult"), range = RBKNone)
  val bodyWp = wpBlock(envWithFinals(lambdaEnv, noFinals), lambdaResult, trueT(), body.statements)
  val bodyDiags = bodyWp.diags
  val obligations: List[Term] = newList()
  var si = 0
  while si < bodyWp.sideGoals.count {
    val sc = bodyWp.sideGoals[si].term
    obligations.add(if termIsPoisoned(sc) or inside.count == 0 { sc } else { mkImplies(mkAnd(inside), sc) })
    si = si + 1
  }
  if not isTrueT(bodyWp.wp) {
    obligations.add(
      if termIsPoisoned(bodyWp.wp) or inside.count == 0 { bodyWp.wp } else { mkImplies(mkAnd(inside), bodyWp.wp) }
    )
  }
  val noFacts: List[Term] = newList()
  val lambdaTR = TranslateResult(
    term = freshVar(env, "lambda", SUninterp(name = "lambda")),
    sideConds = obligations,
    assumed = noFacts
  )
  val lambdaPair: (TranslateResult, List[Diagnostic]) = (lambdaTR, bodyDiags)
  lambdaPair
}

// The subexpressions a construct the verifier does not model evaluates
// where it stands — not a lambda's body, which runs later.
func evaluatedSubexprs(e: in Expr): List[Expr] {
  val subs: List[Expr] = newList()
  match e.kind {
    case EIndex(receiver, indices) -> {
      subs.add(receiver)
      var i = 0
      while i < indices.count {
        subs.add(indices[i])
        i = i + 1
      }
    }
    case ETuple(exprs) -> appendExprList(subs, exprs)
    case EList(exprs) -> appendExprList(subs, exprs)
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISExpr(x) -> subs.add(x)
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
    }
    case EAwait(inner) -> subs.add(inner)
    case ETry(inner) -> subs.add(inner)
    case EPropagate(inner) -> subs.add(inner)
    case ESpawn(inner) -> subs.add(inner)
    case ETypeApp(fn, _) -> subs.add(fn)
    case ERange(bound) -> match bound {
      case RBClosed(lo, hi) -> {
        subs.add(lo)
        subs.add(hi)
      }
      case RBHalfOpen(lo, hi, _) -> {
        subs.add(lo)
        subs.add(hi)
      }
      case RBLowerOpen(hi) -> subs.add(hi)
      case RBUpperOpen(lo) -> subs.add(lo)
    }
    case EAssign(target, _, value) -> {
      subs.add(target)
      subs.add(value)
    }
    case _ -> ()
  }
  subs
}

func appendExprList(dst: in List[Expr], src: in List[Expr]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

// Extract the last expression from a block.
func blockLastExpr(blk: in Block): Option[Expr] {
  if blk.statements.count == 0 {
    return None
  }
  val last = blk.statements[blk.statements.count - 1]
  match last.kind {
    case SExpr(x) -> Some(value = x)
    case SReturn(Some(x)) -> Some(value = x)
    case _ -> {
      // Walk back through all statements looking for last meaningful expr.
      var i = blk.statements.count - 1
      while i >= 0 {
        match blk.statements[i].kind {
          case SExpr(x) -> {
            return Some(value = x)
          }
          case SReturn(Some(x)) -> {
            return Some(value = x)
          }
          case _ -> {
          }
        }
        i = i - 1
      }
      None
    }
  }
}
