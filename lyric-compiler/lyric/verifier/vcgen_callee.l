//! verifier/vcgen_callee.l — callee resolution: computed, method and static calls, distinct construction.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// A call through a computed callee — a lambda, a local binding, another
// call's result: a value of its own at this call site, never one shared
// with another call (#8101).  The callee expression's and the arguments'
// obligations and facts still hold.
func translateComputedCall(
  env: in VEnv,
  fn: in Expr,
  rawArgTerms: in List[Term],
  argSides: in List[Term],
  argAssumed: in List[Term],
  allArgDiags: in List[Diagnostic],
): (TranslateResult, List[Diagnostic]) {
  val (fnR, fnDiags) = translateExpr(env, fn)
  val diags: List[Diagnostic] = newList()
  appendTermList2(diags, fnDiags)
  appendTermList2(diags, allArgDiags)
  val sc: List[Term] = newList()
  appendTermList(sc, fnR.sideConds)
  appendTermList(sc, argSides)
  val asList: List[Term] = newList()
  appendTermList(asList, fnR.assumed)
  appendTermList(asList, argAssumed)
  // An argument reported untranslatable (V0033) keeps the result poisoned,
  // so a goal built from it stays failed (#7874).
  val callVar = callSiteResult(env, "call", rawArgTerms, SUninterp(name = "call"))
  val callTR = TranslateResult(term = callVar, sideConds = sc, assumed = asList)
  val callPair: (TranslateResult, List[Diagnostic]) = (callTR, diags)
  callPair
}

// The function a value names when it is one this file declares, named
// where no binding shadows it (`functionRefTerm`).
func functionRefPrefix(): String {
  "fn!"
}

// The key under which the distinct-type map holds the declared type of a
// module-level `val` or `const` of this file.
func globalTypeKey(name: in String): String {
  "!global." + name
}

func functionRefTerm(name: in String): Term {
  TVar(name = functionRefPrefix() + name, sort = SUninterp(name = "Function"))
}

// The function a callee binding holds now, when it holds one this file
// declares by name (`val h = sq`): never a lambda, a parameter or a value
// a loop or a call has given it, which are values of their own.
func boundFunctionOf(env: in VEnv, fn: in Expr): Option[FunctionDecl] {
  match fn.kind {
    case EPath(path) -> {
      if path.segments.count != 1 {
        return None
      }
      match envLookup(path.segments[0], env) {
        case Some(t) -> match t {
          case TVar(n, _) -> {
            val prefix = functionRefPrefix()
            if n.startsWith(prefix) {
              mapGet(env.callees, n.substring(prefix.length, n.length - prefix.length))
            } else {
              None
            }
          }
          case _ -> None
        }
        case None -> None
      }
    }
    case _ -> None
  }
}

// A callee that names a local binding, which shadows any file function.
func localCallee(env: in VEnv, fn: in Expr): Bool {
  match fn.kind {
    case EPath(path) -> path.segments.count == 1 and isSome(envLookup(path.segments[0], env))
    case _ -> false
  }
}

// The function a `recv.m(...)` call runs, when this file declares it: a
// dot-named `func R.m(self: R, ...)` on the record (or protected type) `R`
// that `recv` is, unless `R` declares its own method `m`, which the call
// reaches first.  `None` when the receiver's type is not one of the file's
// records, or the function's first parameter does not take it.
func resolveMethodCallee(
  env: in VEnv, recvTerm: in Term, methodName: in String, args: in List[CallArg]
): Option[ResolvedCallee] {
  val recvSort = sortOf(recvTerm)
  match recvSort {
    case SDatatype(rName, targs) -> {
      if targs.count > 0 or env.recordMethods.containsKey(rName + "." + methodName) {
        return None
      }
      match findRecordFields(env, rName) {
        case Some(_) -> ()
        case None -> {
          return None
        }
      }
      val key = rName + "." + methodName
      // The receiver is the first argument of a dot-named function, which
      // may be overloaded (#8341).
      val withRecv: List[CallArg] = newList()
      withRecv.add(CAPositional(expr = Expr(kind = ESelf, span = makeSpan(initialPosition(), initialPosition()))))
      for a in args {
        withRecv.add(a)
      }
      match fileCallee(env, key, withRecv) {
        case Some(decl) -> {
          if decl.params.count >= 1 and sortEq(calleeSortInfo(env, decl, decl.params[0].ty).sort, recvSort) {
            Some(value = ResolvedCallee(name = key, decl = decl))
          } else {
            None
          }
        }
        case None -> None
      }
    }
    // A primitive receiver: the one `func <Primitive>.m` of the file whose
    // receiver parameter has the receiver's sort.  Types sharing a sort
    // (`Int`, `Long`) that both declare `m` leave the call unresolved, since
    // the sort does not say which was meant (#8336).
    case _ -> {
      var found: Option[ResolvedCallee] = None
      var matches = 0
      val withRecv: List[CallArg] = newList()
      withRecv.add(CAPositional(expr = Expr(kind = ESelf, span = makeSpan(initialPosition(), initialPosition()))))
      for a in args {
        withRecv.add(a)
      }
      for tn in primitiveTypeNamesOfSort(recvSort) {
        val key = tn + "." + methodName
        if calleeIsOverloaded(env, key) {
          matches = matches + 2
        }
        match fileCallee(env, key, withRecv) {
          case Some(decl) -> {
            if decl.params.count >= 1 and sortEq(calleeSortInfo(env, decl, decl.params[0].ty).sort, recvSort) {
              matches = matches + 1
              found = Some(value = ResolvedCallee(name = key, decl = decl))
            }
          }
          case None -> ()
        }
      }
      if matches == 1 {
        found
      } else {
        None
      }
    }
  }
}

// The primitive types a value of sort `s` can be, by source name.  A width
// not listed (`Short`, `UShort`) has no entry on purpose: the call stays
// unresolved and fails closed.
func primitiveTypeNamesOfSort(s: in Sort): List[String] {
  val names: List[String] = newList()
  match s {
    case SBool -> names.add("Bool")
    case SInt -> {
      names.add("Int")
      names.add("Long")
    }
    case SString -> names.add("String")
    case SFloat64 -> names.add("Double")
    case SFloat32 -> names.add("Float")
    case SBitVec(w) -> {
      if w == 8 {
        names.add("Byte")
      } else if w == 32 {
        names.add("UInt")
      } else if w == 64 {
        names.add("ULong")
      }
    }
    case _ -> ()
  }
  names
}

// `T.m(...)` where `T` names no binding but the file declares `func T.m`:
// a call of that function, like a call by its path.
func resolveStaticCallee(
  env: in VEnv, receiver: in Expr, methodName: in String, args: in List[CallArg]
): Option[ResolvedCallee] {
  match staticCalleeKey(env, receiver, methodName) {
    // `T.m` (a dot-named function), `P.f` with `P` this file's package, or
    // `P.T.m`: the callee table holds each spelling, an overloaded one by
    // its arity (#8341).
    case Some(key) -> match fileCallee(env, key, args) {
      case Some(decl) -> Some(value = ResolvedCallee(name = decl.name, decl = decl))
      case None -> None
    }
    case None -> None
  }
}

// The callee-table spelling of `receiver.methodName` when `receiver` is a
// path naming no binding.
func staticCalleeKey(env: in VEnv, receiver: in Expr, methodName: in String): Option[String] {
  match qualifiedPathOf(receiver) {
    case Some(segs) -> match envLookup(segs[0], env) {
      case Some(_) -> None
      case None -> Some(value = joinPathSegments(segs) + "." + methodName)
    }
    case None -> None
  }
}

// The callee `f` of `f[T](args)`: an explicit type application, or — as
// the parser reads `f[T]` before it knows `f` — an index into a name this
// file declares as a generic function.
func typeAppCallee(env: in VEnv, fn: in Expr): Option[Expr] {
  match fn.kind {
    case ETypeApp(inner, _) -> Some(value = inner)
    case EIndex(receiver, _) -> match receiver.kind {
      case EPath(path) -> {
        if isSome(envLookup(joinPathSegments(path.segments), env)) {
          return None
        }
        match mapGet(env.callees, joinPathSegments(path.segments)) {
          case Some(decl) -> match decl.generics { case Some(_) -> Some(value = receiver); case None -> None }
          // A function cannot be indexed: `f[T]` of an overloaded `f` is a
          // type application.
          case None -> if calleeIsOverloaded(env, joinPathSegments(path.segments)) { Some(value = receiver) } else { None }
        }
      }
      case _ -> None
    }
    case _ -> None
  }
}

// The dotted path an expression spells — `a`, `P.T` — if it is one.
func qualifiedPathOf(e: in Expr): Option[List[String]] {
  match e.kind {
    case EPath(path) -> Some(value = path.segments)
    case EMember(receiver, member) -> match qualifiedPathOf(receiver) {
      case Some(segs) -> {
        val longer: List[String] = newList()
        var i = 0
        while i < segs.count {
          longer.add(segs[i])
          i = i + 1
        }
        longer.add(member)
        Some(value = longer)
      }
      case None -> None
    }
    case _ -> None
  }
}

record ResolvedCallee {
  name: String
  decl: FunctionDecl
}

// `recv.m(args)`.  A method this file declares is applied by its contract,
// the receiver its first argument, with a result of its own at each call
// unless the method is `@pure`.  Any other method is an uninterpreted
// function of the receiver and the arguments, named by the method and their
// sorts: two calls are equal when their method, receiver and arguments are
// (congruence), and nothing more is known — so `a.f() == b.g()` is not
// provable (#8101).
func translateMethodCall(
  env: in VEnv,
  receiver: in Expr,
  methodName: in String,
  args: in List[CallArg],
  rawArgTerms: in List[Term],
  argSpans: in List[Span],
  callSpan: in Span,
  argSides: in List[Term],
  argAssumed: in List[Term],
  allArgDiags: in List[Diagnostic],
): (TranslateResult, List[Diagnostic]) {
  match resolveStaticCallee(env, receiver, methodName, args) {
    case Some(rc) -> {
      return translateResolvedCall(
        env,
        rc.name,
        rc.decl,
        args,
        rawArgTerms,
        argSpans,
        callSpan,
        argSides,
        argAssumed,
        allArgDiags
      )
    }
    case None -> ()
  }
  // `P.f(...)` of a name its package declares more than once that no single
  // declaration takes by the call's argument count fails closed (#8341).
  match staticCalleeKey(env, receiver, methodName) {
    case Some(key) -> {
      if calleeIsOverloaded(env, key) {
        allArgDiags.add(
          untranslatableDiag(
            "a call to '" + key +
              "', which its package declares more than once, that no single declaration takes by its argument count",
            callSpan
          )
        )
        val ambTR = TranslateResult(
          term = poisonTerm(freshVar(env, methodName + "!result", SUninterp(name = "call"))),
          sideConds = argSides,
          assumed = argAssumed
        )
        val ambPair: (TranslateResult, List[Diagnostic]) = (ambTR, allArgDiags)
        return ambPair
      }
    }
    case None -> ()
  }
  // `U.C(args)` for a union `U` the file declares builds case `C`: a
  // value of `U`, so `==` on it is `U`'s.  When `U` compares by structure
  // over modelled payloads (`equalityModelledSort`), equal arguments build
  // equal values; otherwise each construction is a value of its own — a
  // payload may compare by identity (#8109).
  match receiver.kind {
    case EPath(upath) -> {
      if upath.segments.count == 1 and env.valueTypes.containsKey(unionKey(upath.segments[0])) and not isSome(envLookup(upath.segments[0], env)) {
        val unionName = upath.segments[0]
        val noArgs: List[Sort] = newList()
        val unionSort = SDatatype(name = unionName, args = noArgs)
        var caseName = "case!" + unionName + "!" + methodName
        var ci = 0
        while ci < args.count {
          caseName = caseName + match args[ci] { case CANamed(argName, _, _) -> "!n!" + argName; case CAPositional(_) -> "!p" }
          ci = ci + 1
        }
        val caseTerm = if equalityModelledSort(env.valueTypes, env.typeParams, unionSort, 0) and allEqualityModelled(env, rawArgTerms) {
          TApp(name = caseName, args = rawArgTerms, retSort = unionSort)
        } else {
          callSiteResult(env, caseName, rawArgTerms, unionSort)
        }
        val caseTR = TranslateResult(
          term = if anyPoisoned(rawArgTerms) { poisonTerm(caseTerm) } else { caseTerm },
          sideConds = argSides,
          assumed = argAssumed
        )
        val casePair: (TranslateResult, List[Diagnostic]) = (caseTR, allArgDiags)
        return casePair
      }
    }
    case _ -> ()
  }
  val (recvR, recvDiags) = translateExpr(env, receiver)
  val diags: List[Diagnostic] = newList()
  appendTermList2(diags, recvDiags)
  appendTermList2(diags, allArgDiags)
  val sides: List[Term] = newList()
  appendTermList(sides, recvR.sideConds)
  // The arguments run after the receiver.
  appendTermList(sides, afterFacts(recvR.assumed, argSides))
  val facts: List[Term] = newList()
  appendTermList(facts, recvR.assumed)
  appendTermList(facts, argAssumed)
  // `self.m()` inside a protected type reaches the type's own member, as a
  // bare `m()` does, and a receiver the verifier does not model (V0024)
  // says nothing of what the call reads or changes: fail closed (#8102).
  val selfInProtected = match receiver.kind { case ESelf -> env.protectedMembers.count > 0; case _ -> false }
  var unmodelledReceiver = false
  var di = 0
  while di < recvDiags.count {
    if recvDiags[di].code == "V0024" {
      unmodelledReceiver = true
    }
    di = di + 1
  }
  if selfInProtected or unmodelledReceiver {
    diags.add(
      untranslatableDiag(
        if selfInProtected {
          "a call to '" + methodName + "' on `self`, a member of the enclosing protected type"
        } else {
          "a call to '" + methodName + "' on a receiver the verifier does not model"
        },
        callSpan
      )
    )
    val selfTR = TranslateResult(
      term = poisonTerm(freshVar(env, methodName + "!result", SUninterp(name = "call"))),
      sideConds = sides,
      assumed = facts
    )
    val selfPair: (TranslateResult, List[Diagnostic]) = (selfTR, diags)
    return selfPair
  }
  match resolveMethodCallee(env, recvR.term, methodName, args) {
    case Some(rc) -> {
      val fullArgs: List[CallArg] = newList()
      fullArgs.add(CAPositional(expr = receiver))
      val fullTerms: List[Term] = newList()
      fullTerms.add(recvR.term)
      val fullSpans: List[Span] = newList()
      fullSpans.add(receiver.span)
      var i = 0
      while i < args.count {
        fullArgs.add(args[i])
        fullTerms.add(rawArgTerms[i])
        fullSpans.add(argSpans[i])
        i = i + 1
      }
      translateResolvedCall(env, rc.name, rc.decl, fullArgs, fullTerms, fullSpans, callSpan, sides, facts, diags)
    }
    case None -> {
      // A dot-named function its package declares more than once that no
      // single declaration takes by the call's argument count (#8341).
      val dotKey = match sortOf(recvR.term) { case SDatatype(rName, _) -> rName + "." + methodName; case _ -> "" }
      if dotKey.length > 0 and calleeIsOverloaded(env, dotKey) and not env.recordMethods.containsKey(dotKey) {
        diags.add(
          untranslatableDiag(
            "a call to '" + dotKey +
              "', which its package declares more than once, that no single declaration takes by its argument count",
            callSpan
          )
        )
        val ambTR = TranslateResult(
          term = poisonTerm(freshVar(env, methodName + "!result", SUninterp(name = "call"))),
          sideConds = sides,
          assumed = facts
        )
        val ambPair: (TranslateResult, List[Diagnostic]) = (ambTR, diags)
        return ambPair
      }
      val ufArgs: List[Term] = newList()
      ufArgs.add(recvR.term)
      // One function per method, argument shape and sorts: `!`-separated
      // parts (no part contains a `!`), a named argument keeping its name,
      // so `a.f(x = 1, y = 2)` and `a.f(y = 1, x = 2)` are different
      // applications, and every application is well-sorted.
      var ufName = "method!" + methodName + "!" + smtSanitize(sortDisplay(sortOf(recvR.term)))
      var i = 0
      while i < rawArgTerms.count {
        ufArgs.add(rawArgTerms[i])
        val shape = match args[i] { case CANamed(argName, _, _) -> "!n!" + argName; case CAPositional(_) -> "!p" }
        ufName = ufName + shape + "!" + smtSanitize(sortDisplay(sortOf(rawArgTerms[i])))
        i = i + 1
      }
      // Every unmodelled result shares one sort, so results the source may
      // compare are comparable; distinct functions keep them distinct.  A
      // sibling method called on `self` inside a method has its declared
      // result type (#8231).
      val selfResult = match receiver.kind {
        case ESelf -> mapGet(env.distincts, selfMethodResultKey(methodName))
        case _ -> None
      }
      val t = match selfResult {
        case Some(te) -> TApp(name = ufName, args = ufArgs, retSort = sortOfTypeExprE(env, te).sort)
        case None -> TApp(
          name = ufName,
          args = ufArgs,
          retSort = recordMethodResultSort(env, sortOf(recvR.term), methodName)
        )
      }
      val methodTR = TranslateResult(term = t, sideConds = sides, assumed = facts)
      val methodPair: (TranslateResult, List[Diagnostic]) = (methodTR, diags)
      methodPair
    }
  }
}

// The sort of the result of the method `methodName` of the record the sort
// `recvSort` is an instance of: the method's declared result sort at that
// instance, so a method of `Box[T]` returning `T` returns an `Int` on a
// `Box[Int]` (#8356).  A method the file's records do not declare, or one
// whose result is left uninterpreted, has the sort of an unmodelled value.
// Only the sort is carried: a result of a range subtype is an `Int` with no
// range assumed, which assumes less and so stays sound; the method's own
// contract is not applied at the call yet (record-body methods are not
// callees).
func recordMethodResultSort(env: in VEnv, recvSort: in Sort, methodName: in String): Sort {
  val unmodelled = SUninterp(name = "call")
  match recvSort {
    case SDatatype(rName, _) -> {
      if not env.recordMethods.containsKey(rName + "." + methodName) {
        return unmodelled
      }
      match mapGet(env.fieldInfos, recordMethodResultKey(rName, methodName)) {
        case Some(info) -> {
          if smtRenderSort(info.sort) == smtRenderSort(unmodelled) {
            return unmodelled
          }
          match instantiateRecordSort(env, recvSort, info.sort) {
            case Some(srt) -> srt
            case None -> unmodelled
          }
        }
        case None -> unmodelled
      }
    }
    case _ -> unmodelled
  }
}

// Construct a value of the distinct type `typeName` from `arg`: the verifier
// treats a distinct value as its underlying value (#3853), so the result is
// the argument at the underlying sort.  For a range subtype the argument
// must lie in the range — the construction panics otherwise — so the bound
// is a side condition (#7872); a bound the verifier cannot state fails
// closed (V0033).
func translateDistinctConstruction(
  env: in VEnv,
  typeName: in String,
  arg: in Term,
  argSpan: in Span,
  callSpan: in Span,
  argSides: in List[Term],
  argAssumed: in List[Term],
  diags: in List[Diagnostic],
): (TranslateResult, List[Diagnostic]) {
  val segs: List[String] = newList()
  segs.add(typeName)
  val te = TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = callSpan)), span = callSpan)
  val info = sortOfTypeExprWith(env.distincts, te)
  val value = coerceTermAt(arg, info.sort, argSpan, diags)
  val sc: List[Term] = newList()
  appendTermList(sc, argSides)
  val term = match rangeObligationsForTerm(value, info) {
    case Ok(obligations) -> {
      appendTermList(sc, afterFacts(argAssumed, obligations))
      value
    }
    case Err(reason) -> {
      diags.add(untranslatableDiag("the range of `" + typeName + "`: " + reason, callSpan))
      poisonTerm(value)
    }
  }
  val constructed: (TranslateResult, List[Diagnostic]) = (
    TranslateResult(
      term = term,
      sideConds = sc,
      assumed = argAssumed
    ),
    diags
  )
  constructed
}
