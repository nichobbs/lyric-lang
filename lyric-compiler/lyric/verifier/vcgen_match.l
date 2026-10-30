//! verifier/vcgen_match.l — match translation: arm conditions, pattern bindings, scope case facts.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// Build nested TIte for match arms (trivial patterns only).
func buildMatchIte(
  env: in VEnv,
  scrutTerm: in Term,
  scrutInfo: in SortInfo,
  arms: in List[MatchArm],
  idx: in Int,
  reach: in List[Term],
  diagsOut: in List[Diagnostic],
  sidesOut: in List[Term],
  assumedOut: in List[Term],
  ctxSpan: in Span,
): Term {
  if idx >= arms.count {
    // Non-exhaustive — fallback.
    diagsOut.add(
      warningDiagnostic(
        "V0029",
        "match in proof-required code is not exhaustive against the M4.1-supported pattern set",
        ctxSpan
      )
    )
    return freshVar(env, "match", sortOf(scrutTerm))
  }
  val arm = arms[idx]
  val condOpt = matchCond(env, scrutInfo.sort, arm.pattern, scrutTerm)
  match condOpt {
    case None -> {
      // A pattern the verifier does not model (#8142, #8230).
      diagsOut.add(
        warningDiagnostic(
          "V0027",
          "match arm pattern not modelled by the verifier; every obligation that depends on this match's value is not proved",
          arm.span
        )
      )
      // The arm is taken, and the later arms reached, under a condition the
      // verifier cannot state: an unknown.  The arm's body (and guard)
      // still run when it is taken, so their side conditions must hold
      // however that unknown falls, its bindings each a value of their own
      // (#8107).  The match's value is not known: it is marked, so every
      // goal it reaches fails closed (`unmodelledPatternTerm`).
      val unknownMatch = freshVar(env, "arm", SBool)
      var skipEnv = env
      val binders: List[String] = newList()
      collectPatternBinders(arm.pattern.kind, binders)
      var bn = 0
      while bn < binders.count {
        val binderInfo = SortInfo(sort = SUninterp(name = "binding"), range = RBKNone)
        skipEnv = envBindTerm(binders[bn], freshVar(env, binders[bn], binderInfo.sort), binderInfo, skipEnv)
        bn = bn + 1
      }
      val skipSides: List[Term] = newList()
      val skipFacts: List[Term] = newList()
      // A guard that runs and fails still leaves what it passed to an `out`
      // or `inout` parameter changed for the later arms (#8107).
      var restEnv = env
      match arm.guard {
        case Some(g) -> {
          val (gR, gDiags) = translateExpr(skipEnv, g)
          appendTermList2(diagsOut, gDiags)
          appendTermList(skipSides, gR.sideConds)
          skipEnv = havocOutArgs(skipEnv, g).env
          val afterSkippedGuard = havocOutArgs(env, g)
          appendTermList(assumedOut, afterSkippedGuard.hyps)
          restEnv = afterSkippedGuard.env
        }
        case None -> ()
      }
      val skippedArmTerm = translateArmBody(skipEnv, arm, diagsOut, skipSides, skipFacts)
      if termIsPoisoned(skippedArmTerm) {
        skipSides.add(poisonTerm(falseT()))
      }
      appendTermList(sidesOut, guardTerms(mkAnd(termsWith(reach, termList1(unknownMatch))), skipSides))
      val skippedReach = termsWith(reach, termList1(mkNot(unknownMatch)))
      unmodelledPatternTerm(
        buildMatchIte(restEnv, scrutTerm, scrutInfo, arms, idx + 1, skippedReach, diagsOut, sidesOut, assumedOut, ctxSpan)
      )
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
        // Every binding a supported pattern makes is the scrutinee itself.
        val info = SortInfo(sort = sortOf(bterm), range = scrutInfo.range, intBits = scrutInfo.intBits)
        armEnv = envSetMutable(envBindTerm(bname, bterm, info, armEnv), bname, false)
        bi = bi + 1
      }
      // The arm's side conditions and facts hold when it is the arm taken:
      // no earlier arm matched and its pattern (and guard, which the
      // verifier does not model, so an unknown) holds (#8102).
      // The guard runs, in the arm's bindings, when the pattern matches and
      // no earlier arm did: its side conditions and facts hold there, and
      // the arm is taken when it holds too (#8107).
      // The later arms run after a guard that ran and failed, in the state it
      // leaves; with the guard's variables at values of their own they also
      // cover the case where it did not run (#8107).
      var restEnv = env
      val armMatches = match arm.guard {
        case Some(g) -> {
          val (gR, gDiags) = translateExpr(armEnv, g)
          appendTermList2(diagsOut, gDiags)
          // The body runs after the guard, in the state it leaves.
          val afterGuard = havocOutArgs(armEnv, g)
          appendTermList(assumedOut, afterGuard.hyps)
          armEnv = afterGuard.env
          val afterFailedGuard = havocOutArgs(env, g)
          appendTermList(assumedOut, afterFailedGuard.hyps)
          restEnv = afterFailedGuard.env
          val guardReach = mkAnd(termsWith(reach, termList1(cond)))
          appendTermList(sidesOut, guardTerms(guardReach, gR.sideConds))
          appendTermList(assumedOut, guardTerms(guardReach, gR.assumed))
          mkAnd(termList2(cond, gR.term))
        }
        case None -> cond
      }
      val armSides: List[Term] = newList()
      val armAssumed: List[Term] = newList()
      val armTerm = translateArmBody(armEnv, arm, diagsOut, armSides, armAssumed)
      val armReach = mkAnd(termsWith(reach, termList1(armMatches)))
      appendTermList(sidesOut, guardTerms(armReach, armSides))
      appendTermList(assumedOut, guardTerms(armReach, armAssumed))
      if isUnconditional and isNone(arm.guard) {
        armTerm
      } else {
        val restReach = termsWith(reach, termList1(mkNot(armMatches)))
        val restTerm = buildMatchIte(
          restEnv,
          scrutTerm,
          scrutInfo,
          arms,
          idx + 1,
          restReach,
          diagsOut,
          sidesOut,
          assumedOut,
          ctxSpan
        )
        TIte(cond = armMatches, thenT = armTerm, elseT = restTerm)
      }
    }
  }
}

// The names a pattern binds, at any depth.
func collectPatternBinders(kind: in PatternKind, names: in List[String]): Unit {
  match kind {
    case PBinding(n, inner) -> {
      addName(names, n)
      match inner {
        case Some(p) -> collectPatternBinders(p.kind, names)
        case None -> ()
      }
    }
    case PConstructor(_, args) -> {
      var i = 0
      while i < args.count {
        collectPatternBinders(args[i].kind, names)
        i = i + 1
      }
    }
    case PRecord(_, fields, _) -> {
      var i = 0
      while i < fields.count {
        collectFieldPatternBinders(fields[i], names)
        i = i + 1
      }
    }
    case PTuple(pats) -> {
      var i = 0
      while i < pats.count {
        collectPatternBinders(pats[i].kind, names)
        i = i + 1
      }
    }
    case POr(pats) -> {
      var i = 0
      while i < pats.count {
        collectPatternBinders(pats[i].kind, names)
        i = i + 1
      }
    }
    case PParen(inner) -> collectPatternBinders(inner.kind, names)
    case PTypeTest(inner, _) -> collectPatternBinders(inner.kind, names)
    case _ -> ()
  }
}

func collectFieldPatternBinders(field: in RecordPatternField, names: in List[String]): Unit {
  match field {
    case RPFNamed(_, p, _) -> collectPatternBinders(p.kind, names)
    case RPFShort(n, _) -> addName(names, n)
  }
}

// Auxiliary record for pattern bindings.
record PatBind {
  bindName: String
  bindTerm: Term
}

func translateArmBody(
  env: in VEnv,
  arm: in MatchArm,
  diagsOut: in List[Diagnostic],
  sidesOut: in List[Term],
  assumedOut: in List[Term],
): Term {
  match arm.body {
    case EOBExpr(x) -> {
      val (r, d) = translateExpr(env, x)
      appendTermList2(diagsOut, d)
      appendTermList(sidesOut, r.sideConds)
      appendTermList(assumedOut, r.assumed)
      r.term
    }
    case EOBBlock(blk) -> {
      val (r, d) = translateBlockValue(env, blk, arm.span)
      appendTermList2(diagsOut, d)
      appendTermList(sidesOut, r.sideConds)
      appendTermList(assumedOut, r.assumed)
      r.term
    }
  }
}

// The condition under which `pat` matches `subject`, a scrutinee of sort
// `scrutSort`, or None when the verifier does not model the pattern: a
// constructor, record, tuple, range, type-test, or-, or const pattern, a
// bare name that names a union or enum case, a bare name that may name one
// (`bareNameBinds`), and a `name @ p` whose `p` is any of those.
func matchCond(env: in VEnv, scrutSort: in Sort, pat: in Pattern, subject: in Term): Option[Term] {
  matchCondKind(env, scrutSort, pat.kind, subject)
}

func matchCondKind(env: in VEnv, scrutSort: in Sort, kind: in PatternKind, subject: in Term): Option[Term] {
  match kind {
    case PWildcard -> Some(value = trueT())
    case PBinding(name, inner) -> {
      if not bareNameBinds(env, scrutSort, name) {
        return None
      }
      // `name @ p` matches where `p` does (#8142).
      match inner {
        case Some(p) -> matchCondKind(env, scrutSort, p.kind, subject)
        case None -> Some(value = trueT())
      }
    }
    case PLiteral(lit) -> {
      val litTerm = translateLit(lit)
      Some(value = TBuiltin(op = BOpEq, args = termList2(subject, litTerm)))
    }
    case PParen(inner) -> matchCondKind(env, scrutSort, inner.kind, subject)
    case _ -> None
  }
}

// Whether the bare pattern name `name`, matched against a value of sort
// `scrutSort`, binds that value rather than naming a union or enum case.
// The type checker reads a bare name as a case whenever a case of that name
// is in scope — the file's, its package's, the standard library's (the
// prelude's `Some`/`None`/`Ok`/`Err` included) and its imports' — and
// rejects a case that can never match the scrutinee (T0129) unless the
// scrutinee is a record, an enum or a type parameter (docs/01 §2.12,
// #8264).  So in a well-typed program the name binds:
//   * against a primitive, a slice, a tuple or `Unit`, always;
//   * against the standard `Option` (`Result`), unless it is `Some` or
//     `None` (`Ok` or `Err`);
//   * against a union, unless it is one of that union's cases — when the
//     verifier read every package in scope and the type's name resolves to
//     exactly one union declaration as the type checker resolves it (the
//     package's own, else the one import that declares it), never a
//     same-named union of a package the file does not import;
//   * against anything else, unless a case of that name is in scope — which
//     the verifier can tell only when it read every package in scope
//     (`addScopeCaseFacts`); otherwise the arm is not modelled (#8230).
func bareNameBinds(env: in VEnv, scrutSort: in Sort, name: in String): Bool {
  match scrutSort {
    case SDatatype(n, _) -> {
      if not env.typeParams.contains(n) {
        if isOptionSort(scrutSort) {
          return name != "Some" and name != "None"
        }
        if isResultSort(scrutSort) {
          return name != "Ok" and name != "Err"
        }
        if isTupleSortName(n) or n == unitSortName() {
          return true
        }
        if env.valueTypes.containsKey(scopeCasesKnownKey()) and env.valueTypes.containsKey(scopeUnionKey(n)) {
          return not env.valueTypes.containsKey(scopeUnionCaseKey(n, name))
        }
      }
    }
    case SSlice(_) -> return true
    case SArray(_) -> return true
    case SUninterp(_) -> ()
    case _ -> return isPrimitiveSort(scrutSort)
  }
  env.valueTypes.containsKey(scopeCasesKnownKey()) and not env.valueTypes.containsKey(scopeCaseKey(name))
}

// The key under which `valueTypes` records that a union or enum in scope
// has a case named `name`.
func scopeCaseKey(name: in String): String {
  "!case!" + name
}

// The key under which `valueTypes` records that the type name `name`
// resolves to one union declaration the verifier read
// (`addScopeCaseFacts`), and the key for each of its cases.
func scopeUnionKey(name: in String): String {
  "!scopeunion!" + name
}

func scopeUnionCaseKey(union: in String, name: in String): String {
  "!scopeunion!" + union + "!" + name
}

// The key under which `valueTypes` records that every case in scope is
// known: the verifier read every package the proved package imports, and
// the standard library's prelude.
func scopeCasesKnownKey(): String {
  "!casesknown!"
}

// Record the cases in scope of the proved `file` (`bareNameBinds`): its
// own unions' and enums', those of the package's other files, and those of
// every package the verifier read — every one of them, imported or not,
// since a case recorded that is not in scope only makes a bare name fail
// closed.  Every case is known when each package the file and its package's
// other files import, and `Std.Core`, was read.
func addScopeCaseFacts(file: in SourceFile, pscope: in PackageScope, valueTypes: in Map[String, Bool]): Unit {
  val ownDecls = scopeDeclsOfFile(file)
  addScopeDeclCases(ownDecls, valueTypes)
  addScopeDeclCases(pscope.siblings, valueTypes)
  for p in pscope.imports.packages {
    addScopeDeclCases(p.decls, valueTypes)
  }
  // Every case is known only when every file of the package was seen and
  // every package it imports, and the prelude, was read.
  if not pscope.known {
    return
  }
  val needed: List[String] = newList()
  needed.add("Std.Core")
  for n in ownDecls.imports {
    if not needed.contains(n) {
      needed.add(n)
    }
  }
  for n in pscope.siblings.imports {
    if not needed.contains(n) {
      needed.add(n)
    }
  }
  val own = joinPathSegments(file.packageDecl.path.segments)
  for n in needed {
    if n != own and not importResolved(pscope.imports, n) {
      return
    }
  }
  addKey(valueTypes, scopeCasesKnownKey())
  // A union a scrutinee's type names: the package's own of that name, or
  // the one of the packages it imports (the prelude included) that
  // declares it — the type checker's resolution.  A name declared by more
  // than one of those is ambiguous here and gets no entry, so a bare name
  // against it is decided by the general rule (#8230).
  val candidates: List[UnionDecl] = newList()
  val candidateOwners: List[String] = newList()
  for u in ownDecls.unions {
    candidates.add(u)
    candidateOwners.add(own)
  }
  for u in pscope.siblings.unions {
    candidates.add(u)
    candidateOwners.add(own)
  }
  for n in needed {
    if n != own {
      for p in pscope.imports.packages {
        if p.name == n {
          for u in p.decls.unions {
            candidates.add(u)
            candidateOwners.add(n)
          }
        }
      }
    }
  }
  var ci = 0
  while ci < candidates.count {
    val u = candidates[ci]
    var unique = true
    var cj = 0
    while cj < candidates.count {
      if cj != ci and candidates[cj].name == u.name and candidateOwners[cj] != candidateOwners[ci] {
        unique = false
      }
      cj = cj + 1
    }
    if unique {
      addKey(valueTypes, scopeUnionKey(u.name))
      for c in u.cases {
        addKey(valueTypes, scopeUnionCaseKey(u.name, c.name))
      }
    }
    ci = ci + 1
  }
}

func importResolved(imports: in ImportScope, name: in String): Bool {
  for p in imports.packages {
    if p.name == name {
      return true
    }
  }
  false
}

// Record every case name `decls` declares.
func addScopeDeclCases(decls: in ScopeDecls, valueTypes: in Map[String, Bool]): Unit {
  for c in decls.enumCases {
    addKey(valueTypes, scopeCaseKey(c))
  }
  for u in decls.unions {
    for c in u.cases {
      addKey(valueTypes, scopeCaseKey(c.name))
    }
  }
}

func addKey(m: in Map[String, Bool], key: in String): Unit {
  if not m.containsKey(key) {
    m.add(key, true)
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
        case None -> {
        }
      }
    }
    case PParen(inner) -> collectBindings(inner.kind, subject, output)
    case _ -> {
    }
  }
}

func isTrueT(t: in Term): Bool {
  match t {
    case TLit(VLBool(true), _) -> true
    case _ -> false
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
