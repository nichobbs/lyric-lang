//! verifier/vcgen.l — verification-condition generator (WP/SP calculus).
//! M4.1 fragment: let/val/var, if/else, match (trivial patterns), calls.
//! Mirrors compiler/src/Lyric.Verifier/VCGen.fs (simplified: no cross-package
//! imports, no ProofMeta datatype encoding).
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
  pub vars: Map[String, Term]
  pub varNames: List[String]
  pub sorts: Map[String, SortInfo]
  pub callees: Map[String, FunctionDecl]
  pub symbols: List[SymbolDecl]
  pub checkedArithmetic: Bool
  // Distinct-type alias map: `Cents` → `TRef(Long)` for `pub type Cents = Long`.
  // Threaded through every VEnv constructor so `sortOfTypeExprE` can recurse
  // through alias chains and produce the underlying primitive's sort (#3853).
  pub distincts: Map[String, TypeExpr]
  // The sort info of each record and protected-type field, keyed by its
  // selector (`<Type>__<field>`): its width for
  // `@proof_required(checked_arithmetic)` (#7871) and the range a field of a
  // range subtype carries into a proof (#7872).
  pub fieldInfos: Map[String, SortInfo]
  // Each non-generic record's field defaults in declaration order, so a
  // constructor call that leaves a defaulted field out is completed with
  // its default (#7873).
  pub recordDefaults: Map[String, List[Option[Expr]]]
  // One entry per verifier-synthesized name handed out so far — loop
  // havocs, call results, untranslated values — shared by every copy of
  // the environment, so no two of them ever share a name (#8101, #8102).
  pub fresh: List[Int]
  // `<Record>.<method>` for every method declared inside a record body: a
  // record's own method takes precedence over a dot-named function of the
  // same name, so a call to one never borrows the other's contract (#8101).
  pub recordMethods: Map[String, Bool]
  // The variables a postcondition being proved speaks of at the end of the
  // code walked — a loop invariant over the variables its body assigns, an
  // `ensures:` over the function's `out`/`inout` parameters — each with the
  // placeholder that stands for its final value in the postcondition.  Every
  // path's end substitutes the variable's value there for the placeholder
  // (`finishPost`, #8102).
  pub finals: List[FinalSlot]
  // The bindings a call may store into — `var` locals, `out`/`inout`
  // parameters, a protected type's `var` fields.  A call the verifier
  // cannot resolve may pass any of them to an `out`/`inout` parameter, so
  // each it is given holds a new value afterwards (#8102).
  pub mutables: List[String]
  // Inside a protected type's member, the names of its `func`/`entry`
  // members, which a bare call reaches before any top-level function.
  pub protectedMembers: List[String]
  // The functions whose contract is being translated at a call, innermost
  // last: a call reaching one of them again inside that contract is not
  // unfolded a second time (#8102).
  pub contractStack: List[String]
  // The functions on a cycle of the contract-call graph — whose
  // `requires:`/`ensures:` (or `@pure` body) reach themselves again.  Their
  // `ensures:` and body are never assumed at a call: a cycle can make them
  // contradictory (#8102).
  pub cyclic: List[String]
  // Copy helpers — use explicit names list to avoid iterating Map.keys on a
  // TypeBuilderInstantiation, which generates invalid IL.
}

pub record FinalSlot {
  pub varName: String
  pub placeholder: String
}

// Resolve a distinct-type chain to its underlying TypeExpr.  Stops on the first
// non-distinct type (primitive, record, generic application, etc.).  Bounded
// by a depth limit to defend against malformed cyclic alias declarations.
func resolveDistinct(distincts: in Map[String, TypeExpr], te: in TypeExpr): TypeExpr {
  var current = te
  var depth = 0
  while depth < 16 {
    match current.kind {
      case TRef(path) -> {
        if path.segments.count == 1 {
          val name = path.segments[0]
          match mapGet(distincts, name) {
            case Some(under) -> {
              current = under
              depth = depth + 1
            }
            case None -> return current
          }
        } else {
          return current
        }
      }
      case _ -> return current
    }
  }
  current
}

// Env-aware sort lookup that follows distinct-type chains (#3853).  Use this
// in vcgen wherever a TypeExpr is converted to a Sort; the env's
// `distincts` map carries the file-level `pub type X = Y` aliases registered
// in `goalsForFile`, a named range subtype (`type Port = UInt range 1 ..=
// 65535`) as its refined underlying type (#7872).
pub func sortOfTypeExprE(env: in VEnv, te: in TypeExpr): SortInfo {
  sortOfTypeExprWith(env.distincts, te)
}

pub func sortOfTypeExprWith(distincts: in Map[String, TypeExpr], te: in TypeExpr): SortInfo {
  sortOfTypeExprDepth(distincts, te, 0)
}

// Bounded like `resolveDistinct`, against a cyclic chain of range subtypes.
func sortOfTypeExprDepth(distincts: in Map[String, TypeExpr], te: in TypeExpr, depth: in Int): SortInfo {
  val resolved = resolveDistinct(distincts, te)
  match resolved.kind {
    // A range over a distinct alias (`Cents range 0 ..= 100` with `type
    // Cents = ULong`) takes the alias's underlying sort, so its bounds fold
    // signed or unsigned as that sort requires (#7848).
    case TRefined(underlying, range) -> {
      if underlying.segments.count == 1 and distincts.containsKey(underlying.segments[0]) and depth < 16 {
        val baseTe = TypeExpr(kind = TRef(path = underlying), span = resolved.span)
        val base = sortOfTypeExprDepth(distincts, baseTe, depth + 1)
        refinedSortInfo(base.sort, base.intBits, range)
      } else {
        sortOfTypeExpr(resolved)
      }
    }
    case _ -> sortOfTypeExpr(resolved)
  }
}

func copyVarMap(m: in Map[String, Term], names: in List[String]): Map[String, Term] {
  val result: Map[String, Term] = newMap()
  var i = 0
  while i < names.count {
    val k = names[i]
    match mapGet(m, k) {
      case Some(v) -> result.add(k, v)
      case None -> {
      }
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
      case None -> {
      }
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
  val vars: Map[String, Term] = newMap()
  val sorts: Map[String, SortInfo] = newMap()
  val varNames: List[String] = newList()
  val distincts: Map[String, TypeExpr] = newMap()
  val fieldInfos: Map[String, SortInfo] = newMap()
  val recordDefaults: Map[String, List[Option[Expr]]] = newMap()
  val fresh: List[Int] = newList()
  val recordMethods: Map[String, Bool] = newMap()
  val finals: List[FinalSlot] = newList()
  val mutables: List[String] = newList()
  val protectedMembers: List[String] = newList()
  val contractStack: List[String] = newList()
  val cyclic: List[String] = newList()
  VEnv(
    vars = vars,
    varNames = varNames,
    sorts = sorts,
    callees = callees,
    symbols = symbols,
    checkedArithmetic = checkedArithmetic,
    distincts = distincts,
    fieldInfos = fieldInfos,
    recordDefaults = recordDefaults,
    fresh = fresh,
    recordMethods = recordMethods,
    finals = finals,
    mutables = mutables,
    protectedMembers = protectedMembers,
    contractStack = contractStack,
    cyclic = cyclic
  )
}

// Bind name as TVar with the given sort info; copies vars and sorts maps,
// excluding any existing binding for 'name' (shadowing support).
pub func envBind(name: in String, info: in SortInfo, env: in VEnv): VEnv {
  // Build prevNames = env.varNames minus 'name' (handles shadowing).
  val prevNames: List[String] = newList()
  var i = 0
  while i < env.varNames.count {
    if env.varNames[i] != name {
      prevNames.add(env.varNames[i])
    }
    i = i + 1
  }
  val vars2 = copyVarMap(env.vars, prevNames)
  val sorts2 = copySortMap(env.sorts, prevNames)
  vars2.add(name, TVar(name = name, sort = info.sort))
  sorts2.add(name, info)
  prevNames.add(name)
  VEnv(
    vars = vars2,
    varNames = prevNames,
    sorts = sorts2,
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
    cyclic = env.cyclic
  )
}

// Bind name with an explicit term (e.g. for let-binding substitution);
// excludes any existing binding for 'name' (shadowing support).
pub func envBindTerm(name: in String, term: in Term, info: in SortInfo, env: in VEnv): VEnv {
  val prevNames: List[String] = newList()
  var i = 0
  while i < env.varNames.count {
    if env.varNames[i] != name {
      prevNames.add(env.varNames[i])
    }
    i = i + 1
  }
  val vars2 = copyVarMap(env.vars, prevNames)
  val sorts2 = copySortMap(env.sorts, prevNames)
  vars2.add(name, term)
  sorts2.add(name, info)
  prevNames.add(name)
  VEnv(
    vars = vars2,
    varNames = prevNames,
    sorts = sorts2,
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
    cyclic = env.cyclic
  )
}

pub func envLookup(name: in String, env: in VEnv): Option[Term] {
  mapGet(env.vars, name)
}

pub func envLookupSort(name: in String, env: in VEnv): Option[SortInfo] {
  mapGet(env.sorts, name)
}

// A name for a value the verifier introduces — a loop's havocked variable,
// a call's result, a construct it does not model — that no other name in
// any goal has: `!` never appears in a Lyric identifier, and the counter is
// shared by every copy of the environment.  Two distinct values must never
// share a name, or the solver takes them for equal (#8101, #8102).
func freshName(env: in VEnv, base: in String): String {
  val n = env.fresh.count
  env.fresh.add(n)
  base + "!" + intToString(n)
}

// `env` with each name that has an entry snapshot `old.<name>` bound to
// that snapshot.
func envAtEntry(env: in VEnv): VEnv {
  var entryEnv = env
  var i = 0
  while i < env.varNames.count {
    val key = env.varNames[i]
    if key.startsWith("old.") {
      val name = key.substring(4, key.length - 4)
      match envLookup(key, env) {
        case Some(t) -> match envLookupSort(key, env) {
          case Some(info) -> {
            entryEnv = envBindTerm(name, t, info, entryEnv)
          }
          case None -> ()
        }
        case None -> ()
      }
    }
    i = i + 1
  }
  entryEnv
}

// An unconstrained value of `srt` with a name of its own.
func freshVar(env: in VEnv, base: in String, srt: in Sort): Term {
  TVar(name = freshName(env, base), sort = srt)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Translation result.
// ─────────────────────────────────────────────────────────────────────────────
pub record TranslateResult {
  pub term: Term
  pub sideConds: List[Term]
  pub assumed: List[Term]
}

// `r` with its side conditions and facts holding only where `g` does: the
// translation of an operand evaluated only when `g` holds.
func guardTR(g: in Term, r: in TranslateResult): TranslateResult {
  TranslateResult(term = r.term, sideConds = guardTerms(g, r.sideConds), assumed = guardTerms(g, r.assumed))
}

func guardTerms(g: in Term, xs: in List[Term]): List[Term] {
  val guarded: List[Term] = newList()
  var i = 0
  while i < xs.count {
    guarded.add(mkImplies(g, xs[i]))
    i = i + 1
  }
  guarded
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

// Scan env.symbols for a single-ctor `DeclDatatype` whose name matches.
// Returns the constructor's fields (name → sort) so EMember can emit a
// strongly-typed selector and ECall can emit a strongly-typed ctor call
// when the receiver type is a known record (#3843).
func findRecordFields(env: in VEnv, name: in String): Option[List[DatatypeField]] {
  var i = 0
  while i < env.symbols.count {
    match env.symbols[i] {
      case DeclDatatype(rName, ctors) -> {
        if rName == name and ctors.count >= 1 {
          val fieldsOpt: Option[List[DatatypeField]] = Some(value = ctors[0].fields)
          return fieldsOpt
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  val none: Option[List[DatatypeField]] = None
  none
}

// Return the sort of a named field on a record type, or None if the record
// (or that field) isn't registered.  Drives EMember's selector emission.
func findRecordFieldSort(env: in VEnv, recName: in String, fieldName: in String): Option[Sort] {
  // Selectors are registered with a `<TypeName>__` prefix (see
  // `goalsForFile` IRecord / IProtected) so a field named `capacity` on a
  // Bucket doesn't collide with a free constant of the same name in z3's
  // global name space (#3855).  Match against the prefixed form.
  val prefixed = recName + "__" + fieldName
  match findRecordFields(env, recName) {
    case Some(fields) -> {
      var j = 0
      while j < fields.count {
        if fields[j].name == prefixed {
          val sortOpt: Option[Sort] = Some(value = fields[j].sort)
          return sortOpt
        }
        j = j + 1
      }
      val noSort: Option[Sort] = None
      noSort
    }
    case None -> {
      val noRec: Option[Sort] = None
      noRec
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Literal translation.
// ─────────────────────────────────────────────────────────────────────────────
func translateLit(lit: in Literal): Term {
  match lit {
    case LBool(v) -> TLit(value = VLBool(b = v), sort = SBool)
    case LInt(v, suffix, _) -> {
      // An unsigned-suffixed literal is a bitvector constant of its type's
      // width; a wide `u64` literal (2^63 and up) already holds its
      // two's-complement pattern (#7839), which is exactly its bitvector
      // (#7848).  A signed or unsuffixed literal is an integer; one with no
      // suffix takes an unsigned operand's sort later (`coerceToSort`).
      match unsignedSuffixWidth(suffix) {
        case Some(w) -> TLit(value = VLBitVec(bits = v, width = w), sort = SBitVec(width = w))
        case None -> TLit(value = VLInt(n = v), sort = SInt)
      }
    }
    case LFloat(v, _, _) -> TLit(value = VLFloat(f = v), sort = SFloat64)
    case LString(s) -> TLit(value = VLString(s = s), sort = SString)
    case LTripleString(s) -> TLit(value = VLString(s = s), sort = SString)
    case LRawString(s) -> TLit(value = VLString(s = s), sort = SString)
    case LChar(cp) -> TLit(value = VLInt(n = cp.toLong()), sort = SInt)
    case LUnit -> {
      val args: List[Sort] = newList()
      val unitDt = SDatatype(name = "Unit", args = args)
      TLit(value = VLUnit, sort = unitDt)
    }
  }
}

// V0033: a construct the verifier cannot translate faithfully.  The proof
// fails closed on it rather than reasoning about a term that means
// something other than the source (#7848).
func untranslatableDiag(reason: in String, sp: in Span): Diagnostic {
  errorDiagnostic("V0033", "cannot translate this into the proof logic faithfully: " + reason, sp)
}

// A term standing for a construct already reported as V0033.  It keeps
// every goal it reaches failed — the driver never hands such a goal to the
// discharger or the solver — without a second report at the goal (#7874).
func poisonTerm(t: in Term): Term {
  TApp(name = untranslatableMarker(), args = termList1(t), retSort = sortOf(t))
}

// A callee contract or `@pure` body is translated once more at every call;
// a construct there that cannot be translated is reported (once, after
// `dedupeDiagnostics`) even when the callee itself is not proved.
func keepUntranslatableDiags(src: in List[Diagnostic], dst: in List[Diagnostic]): Unit {
  var i = 0
  while i < src.count {
    if src[i].code == "V0033" {
      dst.add(src[i])
    }
    i = i + 1
  }
}

// Convert a translated value to the sort it is bound, passed or returned
// at (a literal taking an unsigned declared type, a lossless widening).  On
// failure the term is kept and a V0033 error is recorded.
func coerceTermAt(t: in Term, target: in Sort, sp: in Span, diagsOut: in List[Diagnostic]): Term {
  match coerceToSort(t, target) {
    case Ok(c) -> c
    case Err(reason) -> {
      diagsOut.add(untranslatableDiag(reason, sp))
      poisonTerm(t)
    }
  }
}

// A call's argument terms in the callee's parameter (or record's field)
// order, and whether its arguments could be paired with them.
pub record PairedArgs {
  pub terms: List[Term]
  pub paired: Bool
}

// Pair a call's arguments with `names` the way the type checker does —
// named arguments by name, positional ones into the free slots left to
// right (`Lyric.Parser.pairCallArgs`) — so a callee contract is instantiated
// with the argument each parameter actually receives, whatever order named
// arguments are written in (#7873).  A parameter the call leaves out takes
// its declared default, translated in `defaultEnv` — a default sees no
// other parameter, and one naming a value the verifier does not model fails
// closed (#8102).  Each term takes its slot's sort.  Arguments that cannot
// be paired, or an omitted parameter without a default, are V0033 and give
// poisoned terms, so no goal built from the call is discharged.
func pairArgTerms(
  calleeName: in String,
  names: in List[String],
  sorts: in List[Sort],
  defaults: in List[Option[Expr]],
  defaultEnv: in VEnv,
  args: in List[CallArg],
  rawArgTerms: in List[Term],
  argSpans: in List[Span],
  callSpan: in Span,
  sideOut: in List[Term],
  assumedOut: in List[Term],
  diagsOut: in List[Diagnostic],
): PairedArgs {
  val terms: List[Term] = newList()
  match pairCallArgs(names, 0, args) {
    case Ok(slots) -> {
      var pi = 0
      while pi < names.count {
        val slot = slots[pi]
        val t = if slot >= 0 {
          coerceTermAt(rawArgTerms[slot], sorts[pi], argSpans[slot], diagsOut)
        } else {
          val dflt: Option[Expr] = if pi < defaults.count { defaults[pi] } else { None }
          match dflt {
            case Some(d) -> {
              val (dR, dDiags) = translateExpr(defaultEnv, d)
              appendTermList2(diagsOut, dDiags)
              var k = 0
              while k < dR.sideConds.count {
                sideOut.add(dR.sideConds[k])
                k = k + 1
              }
              k = 0
              while k < dR.assumed.count {
                assumedOut.add(dR.assumed[k])
                k = k + 1
              }
              val dTerm = dR.term
              // A default naming something the verifier does not model — a
              // module-level `val` — would stand for an unrelated symbol of
              // the same name at the call; fail closed (#8102).
              if freeVarsOfTerm(dTerm).count > 0 {
                diagsOut.add(
                  untranslatableDiag(
                    "the default of '" + names[pi] + "' in the call to '" + calleeName + "' names a value the verifier does not model",
                    d.span
                  )
                )
                poisonTerm(coerceTermAt(dTerm, sorts[pi], d.span, diagsOut))
              } else {
                coerceTermAt(dTerm, sorts[pi], d.span, diagsOut)
              }
            }
            case None -> {
              diagsOut.add(
                untranslatableDiag(
                  "the call to '" + calleeName + "' gives no argument for '" + names[pi] + "', which has no default",
                  callSpan
                )
              )
              poisonTerm(TVar(name = names[pi], sort = sorts[pi]))
            }
          }
        }
        terms.add(t)
        pi = pi + 1
      }
      PairedArgs(terms = terms, paired = true)
    }
    case Err(why) -> {
      diagsOut.add(
        untranslatableDiag(
          "the arguments of the call to '" + calleeName + "' do not match its parameters: " + why,
          callSpan
        )
      )
      var pi = 0
      while pi < names.count {
        terms.add(poisonTerm(TVar(name = names[pi], sort = sorts[pi])))
        pi = pi + 1
      }
      PairedArgs(terms = terms, paired = false)
    }
  }
}

// `env` without its bindings, for an expression evaluated outside the
// caller's scope (a record field's default).
func varlessEnv(env: in VEnv): VEnv {
  val vars: Map[String, Term] = newMap()
  val sorts: Map[String, SortInfo] = newMap()
  val varNames: List[String] = newList()
  VEnv(
    vars = vars,
    varNames = varNames,
    sorts = sorts,
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
    cyclic = env.cyclic
  )
}

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
            if path.segments.count == 1 and env.distincts.containsKey(path.segments[0]) {
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
// result's range and width are facts about the result.  The result is the
// callee applied to its arguments, or — for a method call (`freshResult`)
// on a callee that is not `@pure` — a value of its own at this call site,
// so two calls agree only where the contract says so (#8101).  An `out` or
// `inout` parameter's `ensures:` speak of its value after the call, a
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
  freshResult: in Bool,
): (TranslateResult, List[Diagnostic]) {
  val resultInfo = match decl.ret { case Some(te) -> sortOfTypeExprE(env, te); case None -> unitSortInfo() }
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
    val recTerm = TApp(name = name, args = rawArgTerms, retSort = resultInfo.sort)
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
    paramSorts.add(sortOfTypeExprE(env, decl.params[pi].ty).sort)
    pi = pi + 1
  }
  addUserFunOnce(env.symbols, name, paramSorts, resultSort)

  // Build inner env for translating contracts.
  val innerVars: Map[String, Term] = newMap()
  val innerSorts: Map[String, SortInfo] = newMap()
  val innerVarNames: List[String] = newList()
  var ii = 0
  while ii < decl.params.count {
    val pInfo = sortOfTypeExprE(env, decl.params[ii].ty)
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
    cyclic = env.cyclic
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
  val rawCallTerm = if freshResult and not isPure(decl) {
    TVar(name = freshName(env, name + "!result"), sort = resultSort)
  } else {
    TApp(name = name, args = argTerms, retSort = resultSort)
  }
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
  if isPure(decl) and not cyclicCallee {
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
            val (bodyR, bodyDiags) = translateExpr(innerEnv, bodyExpr)
            keepUntranslatableDiags(bodyDiags, allArgDiags)
            val bodySubst = substTerm(paramSubst, paramSubstNames, bodyR.term)
            pureUnfold.add(TBuiltin(op = BOpEq, args = termList2(callTerm, bodySubst)))
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
        preConds.add(substTerm(paramSubst, paramSubstNames, partsObligation(preParts)))
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
        resultSorts2.add(oldKey, sortOfTypeExprE(env, pp.ty))
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
    cyclic = env.cyclic
  )
  ci = 0
  while ci < decl.contracts.count {
    match decl.contracts[ci] {
      case CCEnsures(post, _) -> {
        if not cyclicCallee {
          val postParts = translateContractParts(resultEnv, post)
          keepUntranslatableDiags(postParts.diags, allArgDiags)
          postConds.add(substTerm(postSubst, postSubstNames, mkAnd(partsHyps(postParts))))
        }
      }
      case _ -> {
      }
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
  appendTermList(asList, intWidthHypothesesForTerm(callTerm, resultInfo))
  // The callee proves its result is in its declared range (#7872).
  appendTermList(asList, rangeHypothesesForTerm(callTerm, resultInfo))
  val knownCalleeTR = TranslateResult(term = callTerm, sideConds = sc, assumed = asList)
  val knownCalleePair: (TranslateResult, List[Diagnostic]) = (knownCalleeTR, allArgDiags)
  knownCalleePair
}

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
  val freshCall = freshVar(env, "call", SUninterp(name = "call"))
  val callVar = if anyPoisoned(rawArgTerms) { poisonTerm(freshCall) } else { freshCall }
  val callTR = TranslateResult(term = callVar, sideConds = sc, assumed = asList)
  val callPair: (TranslateResult, List[Diagnostic]) = (callTR, diags)
  callPair
}

// The parameter names of the function or record a call reaches, in
// order, when the verifier can tell; `None` otherwise.
func calleeParamNames(env: in VEnv, fn: in Expr): Option[List[String]] {
  val names: List[String] = newList()
  match fn.kind {
    case EPath(path) -> {
      if localCallee(env, fn) {
        return None
      }
      val name = joinPathSegments(path.segments)
      match mapGet(env.callees, name) {
        case Some(decl) -> {
          var i = 0
          while i < decl.params.count {
            names.add(decl.params[i].name)
            i = i + 1
          }
          return Some(value = names)
        }
        case None -> ()
      }
      match findRecordFields(env, name) {
        case Some(fields) -> {
          val prefix = name + "__"
          var i = 0
          while i < fields.count {
            val fname = fields[i].name
            names.add(if fname.startsWith(prefix) { fname.substring(prefix.length, fname.length - prefix.length) } else { fname })
            i = i + 1
          }
          Some(value = names)
        }
        case None -> None
      }
    }
    case EMember(receiver, methodName) -> {
      // A static `T.m` takes its arguments from the first parameter; a
      // method's first parameter is its receiver.
      var skip = 0
      val resolved: Option[ResolvedCallee] = match resolveStaticCallee(env, receiver, methodName) {
        case Some(rc) -> Some(value = rc)
        case None -> {
          skip = 1
          match staticSortOfExpr(env, receiver) {
            case Some(srt) -> resolveMethodCallee(env, TVar(name = "self", sort = srt), methodName)
            case None -> None
          }
        }
      }
      match resolved {
        case Some(rc) -> {
          var i = skip
          while i < rc.decl.params.count {
            names.add(rc.decl.params[i].name)
            i = i + 1
          }
          Some(value = names)
        }
        case None -> None
      }
    }
    case _ -> None
  }
}

// Whether a call's arguments, as written, reach their parameters out of
// order: a named argument for an earlier parameter after one for a later.
// With the parameters unknown, any two arguments one of which is named may
// be.
func namedArgsReordered(env: in VEnv, fn: in Expr, args: in List[CallArg]): Bool {
  var named = 0
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(_, _, _) -> {
        named = named + 1
      }
      case CAPositional(_) -> ()
    }
    i = i + 1
  }
  if named == 0 {
    return false
  }
  match calleeParamNames(env, fn) {
    case Some(params) -> {
      var last = -1
      var j = 0
      while j < args.count {
        val slot = match args[j] { case CAPositional(_) -> j; case CANamed(argName, _, _) -> indexOfName(params, argName) }
        if slot < 0 or slot < last {
          return true
        }
        last = slot
        j = j + 1
      }
      false
    }
    case None -> args.count >= 2
  }
}

func indexOfName(names: in List[String], name: in String): Int {
  var i = 0
  while i < names.count {
    if names[i] == name {
      return i
    }
    i = i + 1
  }
  -1
}

// Whether any argument passes a variable to an `out`/`inout` parameter.
func anyArgChangesState(env: in VEnv, args: in List[CallArg]): Bool {
  var i = 0
  while i < args.count {
    val argExpr = match args[i] { case CANamed(_, v, _) -> v; case CAPositional(v) -> v }
    if effectsOfExpr(env, argExpr).outArgs.count > 0 {
      return true
    }
    i = i + 1
  }
  false
}

// A callee as the source spells it, for a diagnostic.
func calleeDisplayName(fn: in Expr): String {
  match qualifiedPathOf(fn) {
    case Some(segs) -> joinPathSegments(segs)
    case None -> match fn.kind { case EMember(_, m) -> m; case _ -> "a computed function" }
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
func resolveMethodCallee(env: in VEnv, recvTerm: in Term, methodName: in String): Option[ResolvedCallee] {
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
      match mapGet(env.callees, key) {
        case Some(decl) -> {
          if decl.params.count >= 1 and sortEq(sortOfTypeExprE(env, decl.params[0].ty).sort, recvSort) {
            Some(value = ResolvedCallee(name = key, decl = decl))
          } else {
            None
          }
        }
        case None -> None
      }
    }
    case _ -> None
  }
}

// `T.m(...)` where `T` names no binding but the file declares `func T.m`:
// a call of that function, like a call by its path.
func resolveStaticCallee(env: in VEnv, receiver: in Expr, methodName: in String): Option[ResolvedCallee] {
  match qualifiedPathOf(receiver) {
    case Some(segs) -> {
      match envLookup(segs[0], env) {
        case Some(_) -> None
        case None -> {
          // `T.m` (a dot-named function), `P.f` with `P` this file's
          // package, or `P.T.m`: the callee table holds each spelling.
          val key = joinPathSegments(segs) + "." + methodName
          match mapGet(env.callees, key) {
            case Some(decl) -> Some(value = ResolvedCallee(name = decl.name, decl = decl))
            case None -> None
          }
        }
      }
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
          case None -> None
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
  match resolveStaticCallee(env, receiver, methodName) {
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
        allArgDiags,
        false
      )
    }
    case None -> ()
  }
  val (recvR, recvDiags) = translateExpr(env, receiver)
  val diags: List[Diagnostic] = newList()
  appendTermList2(diags, recvDiags)
  appendTermList2(diags, allArgDiags)
  val sides: List[Term] = newList()
  appendTermList(sides, recvR.sideConds)
  appendTermList(sides, argSides)
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
  match resolveMethodCallee(env, recvR.term, methodName) {
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
      translateResolvedCall(env, rc.name, rc.decl, fullArgs, fullTerms, fullSpans, callSpan, sides, facts, diags, true)
    }
    case None -> {
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
      // compare are comparable; distinct functions keep them distinct.
      val t = TApp(name = ufName, args = ufArgs, retSort = SUninterp(name = "call"))
      val methodTR = TranslateResult(term = t, sideConds = sides, assumed = facts)
      val methodPair: (TranslateResult, List[Diagnostic]) = (methodTR, diags)
      methodPair
    }
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
  val info = sortOfTypeExprE(env, te)
  val value = coerceTermAt(arg, info.sort, argSpan, diags)
  val sc: List[Term] = newList()
  appendTermList(sc, argSides)
  val term = match rangeObligationsForTerm(value, info) {
    case Ok(obligations) -> {
      appendTermList(sc, obligations)
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

// @proof_required(checked_arithmetic) on an unsigned `+`, `-` or `*`: the
// modular bitvector result must equal the mathematical one (#7848).  `x +
// y` does not wrap iff `x <= x + y`, `x - y` iff `y <= x`, and `x * y` iff
// `y == 0` or `(x * y) / y == x` — all ordered unsigned.
func unsignedOverflowSideConds(op: in Builtin, x: in Term, y: in Term, product: in Term, w: in Int): List[Term] {
  val sc: List[Term] = newList()
  match op {
    case BOpAdd -> sc.add(TBuiltin(op = BOpLte, args = termList2(x, product)))
    case BOpSub -> sc.add(TBuiltin(op = BOpLte, args = termList2(y, x)))
    case BOpMul -> {
      val zero = TLit(value = VLBitVec(bits = 0i64, width = w), sort = SBitVec(width = w))
      val parts: List[Term] = newList()
      parts.add(TBuiltin(op = BOpEq, args = termList2(y, zero)))
      parts.add(TBuiltin(op = BOpEq, args = termList2(TBuiltin(op = BOpDiv, args = termList2(product, y)), x)))
      sc.add(mkOr(parts))
    }
    case _ -> {
    }
  }
  sc
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
// §4a. Static integer width (#7871).
// ─────────────────────────────────────────────────────────────────────────────
// `Int` and `Long` share the unbounded `Int` sort, so the width an
// overflow obligation checks against comes from the expression's static
// type: a binding's declared type (`SortInfo.intBits`), a field's, a
// callee's result type, a literal's suffix.  Returns 32 or 64, or 0 when
// the expression names no width — an unsuffixed literal, which takes its
// context's type, or a value the verifier does not type.
//
// Combining operands (an arithmetic operator, the branches of an `if` or
// `match`) yields 0 when any of them is a value of unknown width: its type
// may be wider than the others' (`l.value / d` with `d: Int`), and a width
// read as narrower than it is weakens the division obligation and the
// width recorded for a binding (#8107).  An unsuffixed literal operand
// takes the other operands' type and does not count as unknown.
func intBitsOfExpr(env: in VEnv, e: in Expr): Int {
  intBitsOfExprWith(env, e, true)
}

// `unknownWins` false gives the widest known operand's width instead, for
// an overflow obligation only: a result is at least as wide as its widest
// operand, so checking it against that width can only fail a proof.
func intBitsOfExprWith(env: in VEnv, e: in Expr, unknownWins: in Bool): Int {
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LInt(v, suffix, _) -> match suffix {
        case I64 -> 64
        case I32 | I16 | I8 -> 32
        case NoIntSuffix -> {
          // Only a `Long` holds an unsuffixed literal beyond 32 bits.
          if v < signedMinOfBits(32) or v > signedMaxOfBits(32) {
            64
          } else {
            0
          }
        }
        case _ -> 0
      }
      case _ -> 0
    }
    case EParen(inner) -> intBitsOfExprWith(env, inner, unknownWins)
    case EPath(path) -> {
      if path.segments.count == 1 {
        match envLookupSort(path.segments[0], env) {
          case Some(si) -> si.intBits
          case None -> 0
        }
      } else {
        0
      }
    }
    case EResult -> match envLookupSort("result", env) { case Some(si) -> si.intBits; case None -> 0 }
    case EOld(inner) -> intBitsOfExprWith(env, inner, unknownWins)
    case EPrefix(op, operand) -> match op { case PreNeg -> intBitsOfExprWith(env, operand, unknownWins); case _ -> 0 }
    case EBinop(op, lhs, rhs) -> match op {
      case BAdd | BSub | BMul | BDiv | BMod -> {
        val parts: List[Expr] = newList()
        parts.add(lhs)
        parts.add(rhs)
        joinIntBits(env, parts, unknownWins)
      }
      case _ -> 0
    }
    case EIf(_, thenBranch, elseBranchOpt, _) -> {
      val parts: List[Expr] = newList()
      addEobValue(parts, thenBranch)
      match elseBranchOpt {
        case Some(eb) -> addEobValue(parts, eb)
        case None -> ()
      }
      joinIntBits(env, parts, unknownWins)
    }
    case EMatch(_, arms) -> {
      val parts: List[Expr] = newList()
      var i = 0
      while i < arms.count {
        addEobValue(parts, arms[i].body)
        i = i + 1
      }
      joinIntBits(env, parts, unknownWins)
    }
    case EBlock(blk) -> match blockLastExpr(blk) {
      case Some(last) -> intBitsOfExprWith(env, last, unknownWins)
      case None -> 0
    }
    case ECall(fn, _) -> match fn.kind {
      case EPath(path) -> {
        val name = joinPathSegments(path.segments)
        if localCallee(env, fn) {
          return 0
        }
        match mapGet(env.callees, name) {
          case Some(decl) -> match decl.ret { case Some(te) -> sortOfTypeExprE(env, te).intBits; case None -> 0 }
          case None -> {
            // A distinct type's constructor yields its underlying value.
            match mapGet(env.distincts, name) {
              case Some(under) -> sortOfTypeExprE(env, under).intBits
              case None -> 0
            }
          }
        }
      }
      case EMember(receiver, methodName) -> {
        // `T.from(x)` yields a `T`, a value of `T`'s underlying width.
        match distinctFromCallee(env, fn) {
          case Some(tName) -> match mapGet(env.distincts, tName) {
            case Some(under) -> return sortOfTypeExprE(env, under).intBits
            case None -> ()
          }
          case None -> ()
        }
        val resolved = match resolveStaticCallee(env, receiver, methodName) {
          case Some(rc) -> Some(value = rc)
          case None -> match staticSortOfExpr(env, receiver) {
            case Some(srt) -> resolveMethodCallee(
              env,
              TVar(name = "self", sort = srt),
              methodName
            )
            case None -> None
          }
        }
        match resolved {
          case Some(rc) -> match rc.decl.ret { case Some(te) -> sortOfTypeExprE(env, te).intBits; case None -> 0 }
          case None -> 0
        }
      }
      case _ -> 0
    }
    case EMember(receiver, memberName) -> {
      val recName = recordNameOfExpr(env, receiver)
      if recName.length > 0 {
        match mapGet(env.fieldInfos, recName + "__" + memberName) {
          case Some(fi) -> fi.intBits
          case None -> 0
        }
      } else if memberName == "value" {
        // A distinct value's `.value` is its underlying value, of the width
        // the distinct type's binding already records.
        intBitsOfExprWith(env, receiver, unknownWins)
      } else {
        0
      }
    }
    case _ -> 0
  }
}

// The value an `if` branch or `match` arm yields, when it names one.
func addEobValue(parts: inout List[Expr], eob: in ExprOrBlock): Unit {
  match eob {
    case EOBExpr(x) -> parts.add(x)
    case EOBBlock(blk) -> match blockLastExpr(blk) { case Some(last) -> parts.add(last); case None -> () }
  }
}

// The width of a value combining `parts`: 0 when one of them is of unknown
// width and `unknownWins`, else the widest known.
func joinIntBits(env: in VEnv, parts: in List[Expr], unknownWins: in Bool): Int {
  var bits = 0
  var i = 0
  while i < parts.count {
    val b = intBitsOfExprWith(env, parts[i], unknownWins)
    if b == 0 and unknownWins and not adoptsContextWidth(parts[i]) {
      return 0
    }
    bits = maxInt(bits, b)
    i = i + 1
  }
  bits
}

// An unsuffixed integer literal in `Int`'s range, or arithmetic over only
// such literals: it takes the type its context gives it.
func adoptsContextWidth(e: in Expr): Bool {
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LInt(v, suffix, _) -> match suffix {
        case NoIntSuffix -> v >= signedMinOfBits(32) and
          v <= signedMaxOfBits(32)
        case _ -> false
      }
      case _ -> false
    }
    case EParen(inner) -> adoptsContextWidth(inner)
    case EPrefix(op, operand) -> match op { case PreNeg -> adoptsContextWidth(operand); case _ -> false }
    case EBinop(op, lhs, rhs) -> match op {
      case BAdd | BSub | BMul | BDiv | BMod -> adoptsContextWidth(lhs) and
        adoptsContextWidth(rhs)
      case _ -> false
    }
    case _ -> false
  }
}

// The record datatype an expression's value belongs to, or "" when it is
// not a known record: a binding of a record sort, or a field of one.
func recordNameOfExpr(env: in VEnv, e: in Expr): String {
  match staticSortOfExpr(env, e) {
    case Some(srt) -> match srt {
      case SDatatype(rName, _) -> match findRecordFields(env, rName) {
        case Some(_) -> rName
        case None -> ""
      }
      case _ -> ""
    }
    case None -> ""
  }
}

// The sort info of an expression that names a binding, without translating
// it; `None` for anything else.
func staticSortInfoOfExpr(env: in VEnv, e: in Expr): Option[SortInfo] {
  match e.kind {
    case EParen(inner) -> staticSortInfoOfExpr(env, inner)
    case EPath(path) -> if path.segments.count == 1 { envLookupSort(path.segments[0], env) } else { None }
    // A distinct value's `.value` has the distinct type's width and range.
    case EMember(receiver, memberName) -> {
      if memberName == "value" and recordNameOfExpr(env, receiver).length == 0 {
        match staticSortInfoOfExpr(env, receiver) {
          case Some(si) -> if isPrimitiveSort(si.sort) { Some(value = si) } else { None }
          case None -> None
        }
      } else {
        None
      }
    }
    case _ -> None
  }
}

// The sort of a binding, `result`, or a record field read from one, without
// translating the expression.
func staticSortOfExpr(env: in VEnv, e: in Expr): Option[Sort] {
  match e.kind {
    case EParen(inner) -> staticSortOfExpr(env, inner)
    case EPath(path) -> {
      if path.segments.count == 1 {
        match envLookupSort(path.segments[0], env) {
          case Some(si) -> Some(value = si.sort)
          case None -> None
        }
      } else {
        None
      }
    }
    case EResult -> match envLookupSort("result", env) { case Some(si) -> Some(value = si.sort); case None -> None }
    case EMember(receiver, memberName) -> {
      val inner = recordNameOfExpr(env, receiver)
      if inner.length > 0 {
        findRecordFieldSort(env, inner, memberName)
      } else {
        None
      }
    }
    case _ -> None
  }
}

func joinPathSegments(segs: in List[String]): String {
  var name = ""
  var j = 0
  while j < segs.count {
    if j > 0 {
      name = name + "."
    }
    name = name + segs[j]
    j = j + 1
  }
  name
}

func maxInt(a: in Int, b: in Int): Int {
  if a > b {
    a
  } else {
    b
  }
}

// The width an overflow obligation checks `e` against: its static width,
// or `Int`'s when it names none — an expression of unsuffixed literals is
// an `Int` unless its context makes it a `Long`, and checking a `Long`
// against the narrower range can only fail a proof, never pass a wrong
// one (#7871).
func overflowBitsOfExpr(env: in VEnv, e: in Expr): Int {
  val b = intBitsOfExprWith(env, e, false)
  if b == 0 {
    32
  } else {
    b
  }
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
          case None -> {
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
      // (#8102).
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
      val rR = if coalesce {
        guardTR(freshVar(env, "isnull", SBool), rRaw)
      } else {
        match builtinOfBinop(op) {
          case Some(BOpAnd) -> guardTR(lR.term, rRaw)
          case Some(BOpImplies) -> guardTR(lR.term, rRaw)
          case Some(BOpOr) -> guardTR(mkNot(lR.term), rRaw)
          case _ -> rRaw
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
          val term = if sortDiags.count > 0 { poisonTerm(TBuiltin(op = b, args = args)) } else { TBuiltin(op = b, args = args) }
          val sc: List[Term] = newList()
          appendTermList(sc, lR.sideConds)
          appendTermList(sc, rR.sideConds)
          // Integer division and remainder by zero panic in every build
          // profile: the divisor must be non-zero (#8107).
          appendTermList(sc, divisorSideConds(b, args, intBitsOfExpr(env, e)))
          // @proof_required(checked_arithmetic): overflow side conditions.
          // A signed result must stay inside its type's width — 32 bits
          // for `Int`, 64 for `Long` — since an overflow panics in a debug
          // build and wraps in a release one (D163, #7871).
          if env.checkedArithmetic {
            match sortOf(args[0]) {
              case SInt -> {
                match b {
                  case BOpAdd | BOpSub | BOpMul -> appendTermList(sc, signedWidthBounds(term, overflowBitsOfExpr(env, e)))
                  case _ -> {
                  }
                }
              }
              case SBitVec(w) -> appendTermList(sc, unsignedOverflowSideConds(b, args[0], args[1], term, w))
              case _ -> {
              }
            }
          }
          val asList: List[Term] = newList()
          appendTermList(asList, lR.assumed)
          appendTermList(asList, rR.assumed)
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
        appendTermList(argSides, ar.sideConds)
        appendTermList(argAssumed, ar.assumed)
        appendTermList2(allArgDiags, ad)
        val afterArg = havocOutArgs(argEnv, argExpr)
        appendTermList(argAssumed, afterArg.hyps)
        argEnv = afterArg.env
        i = i + 1
      }
      // Named arguments out of parameter order run in an order the language
      // does not settle yet (as written, or by parameter): with an argument
      // that changes a variable, either could break the other, so fail
      // closed (#8107).
      if namedArgsReordered(env, fn, args) and anyArgChangesState(env, args) {
        allArgDiags.add(
          untranslatableDiag(
            "the call to '" + calleeDisplayName(fn) + "': the evaluation order of named arguments written out of " +
              "parameter order is not modelled when an argument changes a variable",
            e.span
          )
        )
        argSides.add(poisonTerm(falseT()))
      }

      // A local binding — a lambda in a `val` — shadows a file function of
      // the same name: the call goes through the binding (#8102).
      if localCallee(env, fn) {
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
              val recPaired = pairArgTerms(
                name,
                fieldNames,
                fieldSorts,
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
              val emptyArgs: List[Sort] = newList()
              val recRetSort: Sort = SDatatype(name = name, args = emptyArgs)
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
                allArgDiags,
                false
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
              if env.distincts.containsKey(name) and rawArgTerms.count == 1 {
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
              // Unknown callee — emit TApp with uninterpreted sort.
              val callNameSort = SUninterp(name = "call." + name)
              val t = TApp(name = name, args = rawArgTerms, retSort = callNameSort)
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

    case EForall(binders, whereExprOpt, body) -> {
      var envAcc = env
      val sortBinders: List[SortBinder] = newList()
      var i = 0
      while i < binders.count {
        val b = binders[i]
        val info = sortOfTypeExprE(env, b.ty)
        envAcc = envBind(b.name, info, envAcc)
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
      val inner = match whereTermOpt { case Some(wt) -> mkImplies(wt, bodyR.term); case None -> bodyR.term }
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
        val b = binders[i]
        val info = sortOfTypeExprE(env, b.ty)
        envAcc = envBind(b.name, info, envAcc)
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
      // If the receiver's sort is a registered record datatype and `memberName`
      // names one of its fields, emit the SMT datatype selector
      // `(<TypeName>__<memberName> receiver)` with the field's actual sort.
      // The selector is registered with the prefixed name in the DeclDatatype
      // to avoid z3 ambiguity with same-named free constants (#3855).
      // Otherwise fall back to an uninterpreted `$field.<memberName>` symbol
      // — the SMT renderer will declare it as a uninterpreted function (#3843).
      val recvSort = sortOf(rR.term)
      val recvRecName: String = match recvSort { case SDatatype(rName, _) -> rName; case _ -> "" }
      val recordFieldHit: Option[Sort] = if recvRecName.length > 0 {
        findRecordFieldSort(env, recvRecName, memberName)
      } else {
        None
      }
      val t = match recordFieldHit {
        case Some(fSort) -> TApp(name = recvRecName + "__" + memberName, args = termList1(rR.term), retSort = fSort)
        case None -> {
          if memberName == "value" and isPrimitiveSort(recvSort) {
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
          case Some(fi) -> {
            appendTermList(asList, rangeHypothesesForTerm(t, fi))
            appendTermList(asList, intWidthHypothesesForTerm(t, fi))
          }
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
                appendTermList(facts, rangeHypothesesForTerm(initial, info))
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
    appendTermList(inside, intWidthHypothesesForTerm(pVar, info))
    appendTermList(inside, rangeHypothesesForTerm(pVar, info))
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
  val condOpt = matchCond(arm.pattern, scrutTerm)
  match condOpt {
    case None -> {
      // Pattern not supported in M4.1 — skip arm.
      diagsOut.add(warningDiagnostic("V0027", "match arm pattern not yet supported in M4.1 verifier", arm.span))
      // The arm is taken, and the later arms reached, under a condition the
      // verifier cannot state: an unknown.  The arm's body (and guard)
      // still run when it is taken, so their side conditions must hold
      // however that unknown falls, its bindings each a value of their own
      // (#8107).  Its value is the match's open question (#8142).
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
      buildMatchIte(restEnv, scrutTerm, scrutInfo, arms, idx + 1, skippedReach, diagsOut, sidesOut, assumedOut, ctxSpan)
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
    case PWildcard -> Some(value = trueT())
    case PBinding(_, _) -> Some(value = trueT())
    case PLiteral(lit) -> {
      val litTerm = translateLit(lit)
      Some(value = TBuiltin(op = BOpEq, args = termList2(subject, litTerm)))
    }
    case PParen(inner) -> matchCondKind(inner.kind, subject)
    case _ -> None
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

// ─────────────────────────────────────────────────────────────────────────────
// §6. Contract translation helper.
// ─────────────────────────────────────────────────────────────────────────────
// A contract expression translated in three parts: the side conditions
// its evaluation must meet (a callee's `requires:`, an overflow bound), the
// facts its evaluation brings (a callee's `ensures:`), and its value.  The
// facts hold only where the side conditions do, so an obligation never
// uses them to prove its own side conditions: it is `sides and (facts =>
// value)` (#8102).
record ContractParts {
  sides: List[Term]
  facts: List[Term]
  value: Term
  diags: List[Diagnostic]
}

func translateContractParts(env: in VEnv, e: in Expr): ContractParts {
  val (r, diags) = translateExpr(env, e)
  ContractParts(sides = r.sideConds, facts = r.assumed, value = r.term, diags = diags)
}

// What proving the contract takes: `sides and (facts => value)`.
func partsObligation(p: in ContractParts): Term {
  val parts: List[Term] = newList()
  appendTermList(parts, p.sides)
  parts.add(if p.facts.count == 0 { p.value } else { mkImplies(mkAnd(p.facts), p.value) })
  mkAnd(parts)
}

// What assuming the contract gives, once it has been proved where it is
// assumed: its side conditions, its facts and its value.
func partsHyps(p: in ContractParts): List[Term] {
  val hyps: List[Term] = newList()
  appendTermList(hyps, p.sides)
  appendTermList(hyps, p.facts)
  hyps.add(p.value)
  hyps
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
  pub wp: Term
  pub sideGoals: List[SideGoal]
  pub assumed: List[Term]
  pub diags: List[Diagnostic]
}

func emptyWpResult(wp: in Term): WpResult {
  val sg: List[SideGoal] = newList()
  val asList: List[Term] = newList()
  val di: List[Diagnostic] = newList()
  WpResult(wp = wp, sideGoals = sg, assumed = asList, diags = di)
}

func mergeWpResults(a: in WpResult, b: in WpResult, wp: in Term): WpResult {
  val sg: List[SideGoal] = newList()
  var i = 0
  while i < a.sideGoals.count {
    sg.add(a.sideGoals[i])
    i = i + 1
  }
  i = 0
  while i < b.sideGoals.count {
    sg.add(b.sideGoals[i])
    i = i + 1
  }
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
// WP over a single expression (for FBExpr), the value the path ends with.
func wpExpr(env: in VEnv, resultSort: in SortInfo, postcond: in Term, e: in Expr): WpResult {
  // An assignment nested in the expression is something `translateExpr`
  // cannot follow; fail closed rather than prove the postcondition of the
  // wrong state (#8102).
  if effectsOfExpr(env, e).assigned.count > 0 {
    return unsupportedWp("an assignment inside an expression", e.span)
  }
  val (r, diags) = translateExpr(env, e)
  // A variable passed to an `out`/`inout` parameter holds its new value
  // when the postcondition is checked (#8102).
  val after = havocOutArgs(env, e)
  // Substitute result into postcond, at the declared result sort (#7848).
  val wp = finishPost(after.env, postcond, coerceTermAt(r.term, resultSort.sort, e.span, diags))
  val sideGoals: List[SideGoal] = newList()
  // A value reported untranslatable (V0033) keeps a goal failed even when
  // the postcondition does not mention it (#7874).
  if termIsPoisoned(r.term) {
    sideGoals.add(SideGoal(term = poisonTerm(falseT()), kind = GKAssertion, span = e.span))
  }
  var i = 0
  while i < r.sideConds.count {
    sideGoals.add(SideGoal(term = r.sideConds[i], kind = GKAssertion, span = e.span))
    i = i + 1
  }
  val asList: List[Term] = newList()
  appendTermList(asList, r.assumed)
  appendTermList(asList, after.hyps)
  WpResult(wp = wp, sideGoals = sideGoals, assumed = asList, diags = diags)
}

pub func wpBody(env: in VEnv, resultSort: in SortInfo, postcond: in Term, body: in FunctionBody): WpResult {
  match body {
    case FBExpr(e) -> wpExpr(env, resultSort, postcond, e)
    case FBBlock(blk) -> wpBlock(env, resultSort, postcond, blk.statements)
  }
}

pub func wpBlock(env: in VEnv, resultSort: in SortInfo, postcond: in Term, stmts: in List[Statement]): WpResult {
  wpWalk(env, resultSort, postcond, stmts, 0)
}

// The rest of the block after an expression statement or binding whose
// translation is `r`: its side conditions are side goals, its facts are
// facts, and the variables it passed out hold new values from here on.
func wpAfterExpr(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  e: in Expr,
  r: in TranslateResult,
  rDiags: in List[Diagnostic],
): WpResult {
  val after = havocOutArgs(env, e)
  val inner = wpWalk(after.env, resultSort, postcond, stmts, idx + 1)
  val sg: List[SideGoal] = newList()
  // A value reported untranslatable (V0033) keeps a goal failed even when
  // the statement discards it (#7874).
  if termIsPoisoned(r.term) {
    sg.add(SideGoal(term = poisonTerm(falseT()), kind = GKAssertion, span = e.span))
  }
  var i = 0
  while i < r.sideConds.count {
    sg.add(SideGoal(term = r.sideConds[i], kind = GKAssertion, span = e.span))
    i = i + 1
  }
  i = 0
  while i < inner.sideGoals.count {
    sg.add(inner.sideGoals[i])
    i = i + 1
  }
  val asList: List[Term] = newList()
  appendTermList(asList, r.assumed)
  appendTermList(asList, after.hyps)
  appendTermList(asList, inner.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, rDiags)
  appendTermList2(di, inner.diags)
  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

func wpWalk(env: in VEnv, resultSort: in SortInfo, postcond: in Term, stmts: in List[Statement], idx: in Int): WpResult {
  if idx >= stmts.count {
    // Empty tail — postcond[result := unit].
    emptyWpResult(finishPost(env, postcond, unitTerm()))
  } else {
    val st = stmts[idx]
    match st.kind {
      case SReturn(Some(e)) -> {
        wpExpr(env, resultSort, postcond, e)
      }
      case SReturn(None) -> {
        emptyWpResult(finishPost(env, postcond, unitTerm()))
      }
      case SExpr(callExpr) -> {
        // Check if this is `assert(φ)`.
        match tryExtractAssert(callExpr) {
          case Some(argExpr) -> {
            // assert φ: add as side goal, assume φ for continuation.
            val (phiR, phiDiags) = translateExpr(env, argExpr)
            val inner = wpWalk(env, resultSort, postcond, stmts, idx + 1)
            // Its side conditions are obligations too, and its facts prove
            // its value but never those side conditions (#8102).
            val phiParts = ContractParts(sides = phiR.sideConds, facts = phiR.assumed, value = phiR.term, diags = phiDiags)
            val sg: List[SideGoal] = newList()
            sg.add(SideGoal(term = partsObligation(phiParts), kind = GKAssertion, span = callExpr.span))
            var i = 0
            while i < inner.sideGoals.count {
              sg.add(inner.sideGoals[i])
              i = i + 1
            }
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
            match tryExtractIf(callExpr) {
              // An `if` is walked branch by branch, so assignments in it
              // reach the rest of the block — and, when it ends the block,
              // its branches' values are the block's (#8102).
              case Some(ifTriple) -> {
                wpIfStmt(env, resultSort, postcond, stmts, idx, ifTriple.cond, ifTriple.thenBranch, ifTriple.elseBranchOpt, st.span)
              }
              case None -> {
                match callExpr.kind {
                  case EAssign(target, op, value) -> wpAssign(env, resultSort, postcond, stmts, idx, target, op, value, st.span)
                  case _ -> {
                    if idx + 1 >= stmts.count {
                      // Trailing expression in a block is the implicit return value (#3371).
                      wpExpr(env, resultSort, postcond, callExpr)
                    } else {
                      // An expression statement is evaluated for its effects:
                      // its obligations are side goals and its facts facts,
                      // whatever its form.  The verifier cannot follow an
                      // assignment or a jump inside one; skipping it would
                      // prove the rest of the block in the wrong state
                      // (#8102).
                      if hasEffectsOtherThanCalls(effectsOfExpr(env, callExpr)) {
                        unsupportedWp("an assignment or a jump inside an expression statement", callExpr.span)
                      } else {
                        val (stmtR, stmtDiags) = translateExpr(env, callExpr)
                        wpAfterExpr(env, resultSort, postcond, stmts, idx, callExpr, stmtR, stmtDiags)
                      }
                    }
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
        di.add(
          warningDiagnostic("V0030", "invariant: clause outside loop head is ignored; move it onto a while/loop", st.span)
        )
        var k: Int = 0
        while k < rest.diags.count {
          di.add(rest.diags[k])
          k = k + 1
        }
        WpResult(wp = rest.wp, sideGoals = rest.sideGoals, assumed = rest.assumed, diags = di)
      }
      case _ -> {
        val di: List[Diagnostic] = newList()
        di.add(errorDiagnostic("V0026", "statement form not yet supported in M4.1 verifier; proof is unsound here", st.span))
        val sg: List[SideGoal] = newList()
        val asList: List[Term] = newList()
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
                case CAPositional(v) -> Some(value = v)
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
  cond: Expr
  thenBranch: ExprOrBlock
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
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  cond: in Expr,
  thenBranch: in ExprOrBlock,
  elseBranchOpt: in Option[ExprOrBlock],
  sp: in Span,
): WpResult {
  val (condR, condDiags) = translateExpr(env, cond)

  // Convert ExprOrBlock to statement list.
  val thenStmts = eobToStmts(thenBranch)
  val elseStmts = match elseBranchOpt {
    case Some(eb) -> eobToStmts(eb)
    case None -> {
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

  val afterCond = havocOutArgs(env, cond)
  val thenR = wpWalk(afterCond.env, resultSort, postcond, thenFull, 0)
  val elseR = wpWalk(afterCond.env, resultSort, postcond, elseFull, 0)

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

  // A branch's facts hold on that branch only: one branch's assertion or
  // a loop in it that never exits must not reach the other (#8102).
  val asList: List[Term] = newList()
  appendTermList(asList, condR.assumed)
  appendTermList(asList, afterCond.hyps)
  i = 0
  while i < thenR.assumed.count {
    asList.add(mkImplies(condR.term, thenR.assumed[i]))
    i = i + 1
  }
  i = 0
  while i < elseR.assumed.count {
    asList.add(mkImplies(notCond, elseR.assumed[i]))
    i = i + 1
  }
  val di: List[Diagnostic] = newList()
  appendTermList2(di, condDiags)
  appendTermList2(di, thenR.diags)
  appendTermList2(di, elseR.diags)
  WpResult(
    wp = TIte(cond = condR.term, thenT = thenR.wp, elseT = elseR.wp),
    sideGoals = sg,
    assumed = asList,
    diags = di
  )
}

func eobToStmts(eob: in ExprOrBlock): List[Statement] {
  match eob {
    case EOBBlock(b) -> b.statements
    case EOBExpr(e) -> {
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
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  binding: in LocalBinding,
  sp: in Span,
): WpResult {
  match binding {
    case LBVal(pat, ty, init) -> {
      val name = match pat.kind { case PBinding(n, _) -> n; case _ -> "?pat" }
      wpBindInit(env, resultSort, postcond, stmts, idx, name, ty, init, false)
    }
    case LBLet(name, ty, init) -> wpBindInit(env, resultSort, postcond, stmts, idx, name, ty, init, false)
    case LBVar(name, ty, Some(init)) -> wpBindInit(env, resultSort, postcond, stmts, idx, name, ty, init, true)
    case LBVar(name, ty, None) -> {
      // Uninitialized var — bind to a fresh symbolic value of its declared
      // sort (an unannotated one is an integer, as before).  Its declared
      // range stays with it, for the values assigned to it (#7872).
      val info = match ty { case Some(t) -> sortOfTypeExprE(env, t); case None -> SortInfo(sort = SInt, range = RBKNone) }
      // The value is one of its own: the source name may be bound again
      // elsewhere in the function (#8102).
      val initial = freshVar(env, name, info.sort)
      val env2 = envSetMutable(envBindTerm(name, initial, info, env), name, true)
      val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
      val asList: List[Term] = newList()
      appendTermList(asList, rangeHypothesesForTerm(initial, info))
      appendTermList(asList, inner.assumed)
      WpResult(wp = inner.wp, sideGoals = inner.sideGoals, assumed = asList, diags = inner.diags)
    }
  }
}

// `val`/`let`/`var name[: ty] = init`, then the rest of the block.  The
// initializer's side conditions — a callee's `requires:`, an overflow
// obligation — are side goals like an expression statement's (#7871).
func wpBindInit(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  name: in String,
  ty: in Option[TypeExpr],
  init: in Expr,
  mutable: in Bool,
): WpResult {
  if effectsOfExpr(env, init).assigned.count > 0 {
    return unsupportedWp("an assignment inside an expression", init.span)
  }
  val (initR, initDiags) = translateExpr(env, init)
  // Honor the declared type's range bound (#3854) instead of always
  // discarding it in favor of the inferred-from-init RBKNone sort — a
  // `val x: Percent = ...` binding must carry `0 <= x <= 100` forward.  An
  // unannotated binding takes its initializer's sort and width.
  val info = match ty {
    case Some(t) -> sortOfTypeExprE(env, t)
    case None -> SortInfo(sort = sortOf(initR.term), range = RBKNone, intBits = intBitsOfExpr(env, init))
  }
  val boundTerm = match ty {
    case Some(_) -> coerceTermAt(initR.term, info.sort, init.span, initDiags)
    case None -> initR.term
  }
  // The initializer's `out`/`inout` arguments change before the binding.
  val after = havocOutArgs(env, init)
  val env2 = envSetMutable(envBindTerm(name, boundTerm, info, after.env), name, mutable)
  val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
  val sg: List[SideGoal] = newList()
  if termIsPoisoned(initR.term) {
    sg.add(SideGoal(term = poisonTerm(falseT()), kind = GKAssertion, span = init.span))
  }
  var i = 0
  while i < initR.sideConds.count {
    sg.add(SideGoal(term = initR.sideConds[i], kind = GKAssertion, span = init.span))
    i = i + 1
  }
  i = 0
  while i < inner.sideGoals.count {
    sg.add(inner.sideGoals[i])
    i = i + 1
  }
  val asList: List[Term] = newList()
  appendTermList(asList, initR.assumed)
  appendTermList(asList, after.hyps)
  appendTermList(asList, rangeHypothesesForTerm(boundTerm, info))
  appendTermList(asList, inner.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, initDiags)
  appendTermList2(di, inner.diags)
  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

// `x = v` / `x op= v`, then the rest of the block.  Only a variable is a
// target the verifier models: a record is a reference, and a write to one
// of its fields is seen through every alias of it, which the verifier has
// no heap to follow — so a field or element write fails closed rather than
// leave the proof reasoning about the old value (#8102).
func wpAssign(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  target: in Expr,
  op: in AssignOp,
  value: in Expr,
  sp: in Span,
): WpResult {
  val name = match target.kind {
    case EPath(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
    case _ -> ""
  }
  if name.length == 0 {
    return unsupportedWp("an assignment to a field or an element", target.span)
  }
  if effectsOfExpr(env, value).assigned.count > 0 {
    return unsupportedWp("an assignment inside an expression", value.span)
  }
  val (rhsR, rhsDiags) = translateExpr(env, value)
  // The right-hand side's side conditions are obligations, and so is a
  // compound assignment's overflow under checked arithmetic (#7871).
  val rhsSide: List[Term] = newList()
  appendTermList(rhsSide, rhsR.sideConds)
  val rawCombined = match op {
    case AssEq -> rhsR.term
    case _ -> {
      val existing = match envLookup(name, env) { case Some(t) -> t; case None -> TVar(name = name, sort = SInt) }
      val bin = match op {
        case AssPlus -> BOpAdd
        case AssMinus -> BOpSub
        case AssStar -> BOpMul
        case AssSlash -> BOpDiv
        case AssPercent -> BOpMod
        case _ -> BOpAdd
      }
      val combinedOp = match unifyOperands(existing, rhsR.term) {
        case Ok(pair) -> TBuiltin(op = bin, args = termList2(pair.lhs, pair.rhs))
        case Err(reason) -> {
          rhsDiags.add(untranslatableDiag(reason, sp))
          poisonTerm(TBuiltin(op = bin, args = termList2(existing, rhsR.term)))
        }
      }
      match combinedOp {
        case TBuiltin(_, dargs) -> appendTermList(rhsSide, divisorSideConds(bin, dargs, intBitsOfExpr(env, target)))
        case _ -> ()
      }
      if env.checkedArithmetic {
        match combinedOp {
          case TBuiltin(_, cargs) -> {
            match sortOf(cargs[0]) {
              case SInt -> match bin {
                case BOpAdd | BOpSub | BOpMul -> appendTermList(
                  rhsSide,
                  signedWidthBounds(combinedOp, overflowBitsOfExpr(env, target))
                )
                case _ -> ()
              }
              case SBitVec(w) -> appendTermList(rhsSide, unsignedOverflowSideConds(bin, cargs[0], cargs[1], combinedOp, w))
              case _ -> ()
            }
          }
          case _ -> ()
        }
      }
      combinedOp
    }
  }
  // The assigned value takes the variable's sort (#7848).
  val combined = match envLookupSort(name, env) {
    case Some(si) -> coerceTermAt(rawCombined, si.sort, value.span, rhsDiags)
    case None -> rawCombined
  }
  val info = match envLookupSort(name, env) {
    case Some(si) -> si
    case None -> SortInfo(sort = sortOf(combined), range = RBKNone)
  }
  // The right-hand side's `out`/`inout` arguments change before the store.
  val after = havocOutArgs(env, value)
  val env2 = envBindTerm(name, combined, info, after.env)
  val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
  val sg: List[SideGoal] = newList()
  if termIsPoisoned(rhsR.term) {
    sg.add(SideGoal(term = poisonTerm(falseT()), kind = GKAssertion, span = value.span))
  }
  var si = 0
  while si < rhsSide.count {
    sg.add(SideGoal(term = rhsSide[si], kind = GKAssertion, span = sp))
    si = si + 1
  }
  si = 0
  while si < inner.sideGoals.count {
    sg.add(inner.sideGoals[si])
    si = si + 1
  }
  val asList: List[Term] = newList()
  appendTermList(asList, rhsR.assumed)
  appendTermList(asList, after.hyps)
  // A range-typed variable is range-checked after every assignment
  // (docs/01 §2.2), so the assigned value is in range from here on.
  appendTermList(asList, rangeHypothesesForTerm(combined, info))
  appendTermList(asList, inner.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, rhsDiags)
  appendTermList2(di, inner.diags)
  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

// Each invariant of a loop, translated in `env`: what proving all of them
// takes, and what assuming them gives (`ContractParts`).
record LoopInvariant {
  obligation: Term
  hyps: List[Term]
  facts: List[Term]
  diags: List[Diagnostic]
}

func translateInvariants(env: in VEnv, invExprs: in List[Expr]): LoopInvariant {
  val obligations: List[Term] = newList()
  val hyps: List[Term] = newList()
  val facts: List[Term] = newList()
  val diags: List[Diagnostic] = newList()
  var i = 0
  while i < invExprs.count {
    val parts = translateContractParts(env, invExprs[i])
    obligations.add(partsObligation(parts))
    appendTermList(hyps, partsHyps(parts))
    appendTermList(facts, parts.facts)
    appendTermList2(diags, parts.diags)
    i = i + 1
  }
  LoopInvariant(obligation = mkAnd(obligations), hyps = hyps, facts = facts, diags = diags)
}

func termsWith(xs: in List[Term], ys: in List[Term]): List[Term] {
  val joined: List[Term] = newList()
  appendTermList(joined, xs)
  appendTermList(joined, ys)
  joined
}

// `while cond { invariant: inv; body }`, then the rest of the block, by the
// loop rule (#8102):
//
//   - establish: `inv` holds on entry;
//   - the condition's side conditions hold wherever it is evaluated — on
//     entry, under `inv`, and after any iteration: in a state where every
//     variable the loop may change (an assignment's target, an `out` or
//     `inout` argument) holds an arbitrary value of its type and `inv`
//     holds;
//   - preserve: in that arbitrary state, `inv and cond` and the body's
//     effects give `inv` again, evaluated in the state the body ends in;
//   - the body's own side goals hold under `inv and cond` in that state;
//   - the rest of the block runs in an arbitrary such state where `inv and
//     not cond` holds.
//
// A `return` (or `?`) in the body leaves the loop with a value the
// invariant says nothing about, so it fails closed, as `break` and
// `continue` do (#7396).
func wpWhile(
  env: in VEnv,
  resultSort: in SortInfo,
  postcond: in Term,
  stmts: in List[Statement],
  idx: in Int,
  cond: in Expr,
  body: in Block,
  sp: in Span,
): WpResult {
  // Partition SInvariant stmts from real body.
  val invExprs: List[Expr] = newList()
  val realStmts: List[Statement] = newList()
  var i = 0
  while i < body.statements.count {
    match body.statements[i].kind {
      case SInvariant(ie) -> invExprs.add(ie)
      case _ -> realStmts.add(body.statements[i])
    }
    i = i + 1
  }
  // A `?` (or any other jump) in the condition leaves the function from
  // inside the loop test, a path the loop rule does not cover (#8143).
  if effectsOfExpr(env, cond).jumps.count > 0 {
    return unsupportedWp("a `?` or another jump in a loop condition", cond.span)
  }
  val sg: List[SideGoal] = newList()
  val di: List[Diagnostic] = newList()

  // On entry.
  val invEntry = translateInvariants(env, invExprs)
  appendTermList2(di, invEntry.diags)
  sg.add(SideGoal(term = invEntry.obligation, kind = GKLoopEstablish, span = sp))
  val (condEntryR, condEntryDiags) = translateExpr(env, cond)
  appendTermList2(di, condEntryDiags)
  // The condition's own facts (a callee's `ensures:`) hold only once its
  // side conditions do, so they never guard those side conditions.
  val entryHyps: List[Term] = newList()
  appendTermList(entryHyps, invEntry.hyps)
  val condEntrySides: List[SideGoal] = newList()
  i = 0
  while i < condEntryR.sideConds.count {
    condEntrySides.add(SideGoal(term = condEntryR.sideConds[i], kind = GKAssertion, span = cond.span))
    i = i + 1
  }
  guardSideGoals(condEntrySides, entryHyps, sg)

  // An arbitrary iteration: everything the body or the condition may
  // change holds a value of its own.
  val bodyEffects = effectsOfStmts(env, realStmts)
  val changed = effectsChanged(bodyEffects)
  addNames(changed, effectsChanged(effectsOfExpr(env, cond)))
  val havoc = havocVars(env, changed, "loop")
  val envH = havoc.env
  val invH = translateInvariants(envH, invExprs)
  val (condHR, _) = translateExpr(envH, cond)
  val iterHyps: List[Term] = newList()
  appendTermList(iterHyps, havoc.hyps)
  appendTermList(iterHyps, invH.hyps)
  val condIterSides: List[SideGoal] = newList()
  i = 0
  while i < condHR.sideConds.count {
    condIterSides.add(SideGoal(term = condHR.sideConds[i], kind = GKAssertion, span = cond.span))
    i = i + 1
  }
  guardSideGoals(condIterSides, iterHyps, sg)

  // The condition's own `out`/`inout` arguments change as it is evaluated.
  val afterCond = havocOutArgs(envH, cond)
  val bodyHyps = termsWith(iterHyps, condHR.assumed)
  appendTermList(bodyHyps, afterCond.hyps)
  bodyHyps.add(condHR.term)

  if bodyEffects.jumps.contains("return") {
    di.add(
      errorDiagnostic(
        "V0026",
        "a `return` or `?` inside a loop body is not yet supported by the verifier; the proof fails here",
        sp
      )
    )
    sg.add(SideGoal(term = falseT(), kind = GKLoopPreserve, span = sp))
  } else {
    // Preserve: the invariant at the end of the body, over the values the
    // body leaves — each changed variable is a placeholder `finishPost`
    // replaces at every path's end.
    val finals: List[FinalSlot] = newList()
    var envP = envH
    i = 0
    while i < changed.count {
      match envLookupSort(changed[i], envH) {
        case Some(vinfo) -> {
          val placeholder = freshName(env, changed[i] + "!final")
          finals.add(FinalSlot(varName = changed[i], placeholder = placeholder))
          envP = envBindTerm(changed[i], TVar(name = placeholder, sort = vinfo.sort), vinfo, envP)
        }
        case None -> ()
      }
      i = i + 1
    }
    val invFinal = translateInvariants(envP, invExprs)
    val preservePost = invFinal.obligation
    // The body ends with a unit statement, so its last real statement is
    // walked as a statement — an `if` or a call there changes state — and
    // never taken for a value.
    val bodyStmts: List[Statement] = newList()
    appendStmtList(bodyStmts, realStmts)
    bodyStmts.add(Statement(kind = SExpr(expr = Expr(kind = ELiteral(lit = LUnit), span = body.span)), span = body.span))
    val bodyWp = wpWalk(envWithFinals(afterCond.env, finals), resultSort, preservePost, bodyStmts, 0)
    appendTermList2(di, bodyWp.diags)
    val preserveHyps = termsWith(bodyHyps, bodyWp.assumed)
    sg.add(SideGoal(term = mkImplies(mkAnd(preserveHyps), bodyWp.wp), kind = GKLoopPreserve, span = sp))
    guardSideGoals(bodyWp.sideGoals, bodyHyps, sg)
  }

  // After the loop.
  val exitHyps: List[Term] = newList()
  appendTermList(exitHyps, iterHyps)
  appendTermList(exitHyps, condHR.assumed)
  appendTermList(exitHyps, afterCond.hyps)
  exitHyps.add(mkNot(condHR.term))
  val rest: List[Statement] = newList()
  var ri = idx + 1
  while ri < stmts.count {
    rest.add(stmts[ri])
    ri = ri + 1
  }
  val inner = wpWalk(afterCond.env, resultSort, postcond, rest, 0)
  guardSideGoals(inner.sideGoals, exitHyps, sg)
  appendTermList2(di, invH.diags)
  appendTermList2(di, inner.diags)

  val asList: List[Term] = newList()
  appendTermList(asList, condEntryR.assumed)
  appendTermList(asList, invEntry.hyps)
  appendTermList(asList, exitHyps)
  appendTermList(asList, inner.assumed)
  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

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
      match mapGet(env.callees, name) {
        case Some(decl) -> effOutParams(decl, 0, args, eff)
        case None -> {
          val known = name == "assert" or env.protectedMembers.contains(name) or env.distincts.containsKey(name)
          val isRecord = match findRecordFields(env, name) { case Some(_) -> true; case None -> false }
          if not known and not isRecord {
            effMutableArgs(env, args, eff)
          }
        }
      }
    }
    case EMember(receiver, methodName) -> {
      match resolveStaticCallee(env, receiver, methodName) {
        case Some(rc) -> effOutParams(rc.decl, 0, args, eff)
        case None -> {
          val methodOpt = match staticSortOfExpr(env, receiver) {
            case Some(srt) -> resolveMethodCallee(env, TVar(name = "self", sort = srt), methodName)
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
        appendTermList(hyps, intWidthHypothesesForTerm(t, vinfo))
        appendTermList(hyps, rangeHypothesesForTerm(t, vinfo))
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
    cyclic = env.cyclic
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
    cyclic = env.cyclic
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

// Fail closed: `what` cannot be modelled, so the path's obligation is
// `false` and the error says why.
func unsupportedWp(what: in String, sp: in Span): WpResult {
  val di: List[Diagnostic] = newList()
  di.add(errorDiagnostic("V0026", what + " is not yet supported by the verifier; the proof fails here", sp))
  val sg: List[SideGoal] = newList()
  val asList: List[Term] = newList()
  WpResult(wp = falseT(), sideGoals = sg, assumed = asList, diags = di)
}

// Each side goal of `src`, holding where `hyps` hold.
func guardSideGoals(src: in List[SideGoal], hyps: in List[Term], dst: in List[SideGoal]): Unit {
  var i = 0
  while i < src.count {
    val g = src[i]
    val t = if hyps.count == 0 { g.term } else { mkImplies(mkAnd(hyps), g.term) }
    dst.add(SideGoal(term = t, kind = g.kind, span = g.span))
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Goals for a single function.
// ─────────────────────────────────────────────────────────────────────────────
// True when a function body contains EYield (generator); WP/SP cannot model generator suspend/resume.
func funcBodyContainsYield(decl: in FunctionDecl): Bool {
  match decl.body {
    case Some(b) -> {
      match b {
        case FBExpr(expr) -> exprContainsYield(expr)
        case FBBlock(blk) -> blockContainsYield(blk)
      }
    }
    case None -> false
  }
}

func blockContainsYield(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtContainsYield(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func stmtContainsYield(s: in Statement): Bool {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> exprContainsYield(init)
        case LBLet(_, _, init) -> exprContainsYield(init)
        case LBVar(_, _, Some(init)) -> exprContainsYield(init)
        case LBVar(_, _, None) -> false
      }
    }
    case SAssign(target, _, value) -> exprContainsYield(target) or exprContainsYield(value)
    case SReturn(Some(e)) -> exprContainsYield(e)
    case SReturn(None) -> false
    case SThrow(e) -> exprContainsYield(e)
    case STry(body, catches, finally_) -> {
      if blockContainsYield(body) {
        return true
      }
      var ci = 0
      while ci < catches.count {
        if blockContainsYield(catches[ci].body) {
          return true
        }
        ci = ci + 1
      }
      match finally_ {
        case Some(fb) -> blockContainsYield(fb)
        case None -> false
      }
    }
    case SDefer(body) -> blockContainsYield(body)
    case SScope(_, body) -> blockContainsYield(body)
    case SFor(_, _, iter, body) -> exprContainsYield(iter) or blockContainsYield(body)
    case SWhile(_, cond, body) -> exprContainsYield(cond) or blockContainsYield(body)
    case SLoop(_, body) -> blockContainsYield(body)
    case SInvariant(e) -> exprContainsYield(e)
    case SExpr(e) -> exprContainsYield(e)
    case SRule(lhs, rhs) -> exprContainsYield(lhs) or exprContainsYield(rhs)
    case _ -> false
  }
}

func exprContainsYield(e: in Expr): Bool {
  match e.kind {
    case EYield(_) -> true
    case EParen(inner) -> exprContainsYield(inner)
    case EAwait(inner) -> exprContainsYield(inner)
    case ESpawn(inner) -> exprContainsYield(inner)
    case EPropagate(inner) -> exprContainsYield(inner)
    case ETry(inner) -> exprContainsYield(inner)
    case EOld(inner) -> exprContainsYield(inner)
    case EBlock(blk) -> blockContainsYield(blk)
    case EUnsafe(blk) -> blockContainsYield(blk)
    case EPrefix(_, operand) -> exprContainsYield(operand)
    case EBinop(_, lhs, rhs) -> exprContainsYield(lhs) or exprContainsYield(rhs)
    case EMember(receiver, _) -> exprContainsYield(receiver)
    case ETypeApp(fn, _) -> exprContainsYield(fn)
    case EAssign(target, _, value) -> exprContainsYield(target) or exprContainsYield(value)
    case ECall(fn, args) -> {
      if exprContainsYield(fn) {
        return true
      }
      var i = 0
      while i < args.count {
        val argExpr = match args[i] { case CANamed(_, v, _) -> v; case CAPositional(expr) -> expr }
        if exprContainsYield(argExpr) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EIndex(receiver, indices) -> {
      if exprContainsYield(receiver) {
        return true
      }
      var i = 0
      while i < indices.count {
        if exprContainsYield(indices[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case ETuple(exprs) -> {
      var i = 0
      while i < exprs.count {
        if exprContainsYield(exprs[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EList(exprs) -> {
      var i = 0
      while i < exprs.count {
        if exprContainsYield(exprs[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISExpr(x) -> {
            if exprContainsYield(x) {
              return true
            }
          }
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
      false
    }
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> exprContainsYield(lo) or exprContainsYield(hi)
        case RBHalfOpen(lo, hi, _) -> exprContainsYield(lo) or exprContainsYield(hi)
        case RBLowerOpen(hi) -> exprContainsYield(hi)
        case RBUpperOpen(lo) -> exprContainsYield(lo)
      }
    }
    case EForall(_, whereExpr, body) -> {
      val inWhere = match whereExpr { case Some(w) -> exprContainsYield(w); case None -> false }
      inWhere or exprContainsYield(body)
    }
    case EExists(_, whereExpr, body) -> {
      val inWhere = match whereExpr { case Some(w) -> exprContainsYield(w); case None -> false }
      inWhere or exprContainsYield(body)
    }
    case ELambda(_, body) -> blockContainsYield(body)
    case EIf(cond, thenBranch, elseBranch, _) -> {
      if exprContainsYield(cond) {
        return true
      }
      if eobContainsYield(thenBranch) {
        return true
      }
      match elseBranch {
        case Some(eb) -> eobContainsYield(eb)
        case None -> false
      }
    }
    case EMatch(scrutinee, arms) -> {
      if exprContainsYield(scrutinee) {
        return true
      }
      var i = 0
      while i < arms.count {
        if eobContainsYield(arms[i].body) {
          return true
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

func eobContainsYield(eob: in ExprOrBlock): Bool {
  match eob {
    case EOBExpr(x) -> exprContainsYield(x)
    case EOBBlock(blk) -> blockContainsYield(blk)
  }
}

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
  env0: in VEnv,
  decl: in FunctionDecl,
  extraHyps: in List[Term],
  stateVars: in List[String],
): (List[Goal], List[Diagnostic]) {
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
    val hyps = rangeHypotheses(p.name, info)
    appendTermList(paramHyps, hyps)
    appendTermList(paramHyps, intWidthHypothesesForTerm(TVar(name = p.name, sort = info.sort), info))
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
  // evaluation brings, and its value.
  val preTerms: List[Term] = newList()
  val preDiags: List[Diagnostic] = newList()
  i = 0
  while i < decl.contracts.count {
    match decl.contracts[i] {
      case CCRequires(e, _) -> {
        val parts = translateContractParts(envInOwnContract(envWithParams, decl.name), e)
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
  while i < decl.contracts.count {
    match decl.contracts[i] {
      case CCEnsures(e, _) -> {
        val parts = translateContractParts(envInOwnContract(envForPost, decl.name), e)
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
    cyclic = env.cyclic
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
              appendTermList(fieldRangeHyps, rangeHypothesesForTerm(fTerm, fInfo))
              appendTermList(fieldRangeHyps, intWidthHypothesesForTerm(fTerm, fInfo))
            }
            case PFLet(fname, fty, _, _, _, _) -> {
              val fInfo = sortOfTypeExprE(env0, fty)
              val args2: List[Term] = newList()
              args2.add(selfTerm)
              val fTerm = TApp(name = protName + "__" + fname, args = args2, retSort = fInfo.sort)
              fnEnv = envBindTerm(fname, fTerm, fInfo, fnEnv)
              appendTermList(fieldRangeHyps, rangeHypothesesForTerm(fTerm, fInfo))
              appendTermList(fieldRangeHyps, intWidthHypothesesForTerm(fTerm, fInfo))
            }
            case PFImmutable(fd) -> {
              val fInfo = sortOfTypeExprE(env0, fd.ty)
              val args3: List[Term] = newList()
              args3.add(selfTerm)
              val fTerm = TApp(name = protName + "__" + fd.name, args = args3, retSort = fInfo.sort)
              fnEnv = envBindTerm(fd.name, fTerm, fInfo, fnEnv)
              appendTermList(fieldRangeHyps, rangeHypothesesForTerm(fTerm, fInfo))
              appendTermList(fieldRangeHyps, intWidthHypothesesForTerm(fTerm, fInfo))
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

// What a distinct type stands for in a proof: its underlying type, refined
// by its range when it is a range subtype (`type Port = UInt range 1 ..=
// 65535` is `UInt range 1 ..= 65535`), so a value of it carries the bound
// and a construction must establish it (#7872).
func distinctRepresentation(dt: in DistinctTypeDecl): TypeExpr {
  match dt.rangeClause {
    case Some(rb) -> match dt.underlying.kind {
      case TRef(path) -> TypeExpr(
        kind = TRefined(underlying = path, range = rb),
        span = dt.underlying.span
      )
      case _ -> dt.underlying
    }
    case None -> dt.underlying
  }
}

// Register one field of a record or protected type's datatype under its
// selector name, with its sort info: its signed width when it is an `Int` or
// `Long` (#7871), its range when it is a range subtype (#7872).
func addDatatypeField(
  dtFields: in List[DatatypeField],
  infos: in Map[String, SortInfo],
  distinctMap: in Map[String, TypeExpr],
  selector: in String,
  ty: in TypeExpr,
): Unit {
  val info = sortOfTypeExprWith(distinctMap, ty)
  dtFields.add(DatatypeField(name = selector, sort = info.sort))
  if not infos.containsKey(selector) {
    infos.add(selector, info)
  }
}

// #336: aspect weaving (Lyric.Weaver.weaveFile) now runs in the
// verifier driver before VC generation.  goalsForFile receives the
// woven SourceFile — original IFuncs are replaced with renamed
// `__aspect_target` declarations plus wrapper IFuncs carrying the
// composed contracts (§5 of docs/26-aspects.md).  IAspect items have
// already been dropped, so the verifier sees the body the runtime
// executes.  The V0031 same-package warning is therefore retired.
pub func goalsForFile(file: in SourceFile, level: in VerificationLevel): (List[Goal], List[Diagnostic]) {
  if not vlIsProofRequired(level) {
    val noGoals: List[Goal] = newList()
    val noDiags: List[Diagnostic] = newList()
    return (noGoals, noDiags)
  }

  // Build callee table from file's IFunc and protected-type PMFunc items.
  // A function is reachable by its name and by its name qualified with
  // this file's package (`P.f`, #8102).
  val callees: Map[String, FunctionDecl] = newMap()
  val calleeDecls: List[FunctionDecl] = newList()
  val packagePrefix = joinPathSegments(file.packageDecl.path.segments) + "."
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        callees.add(fn.name, fn)
        calleeDecls.add(fn)
        if not callees.containsKey(packagePrefix + fn.name) {
          callees.add(packagePrefix + fn.name, fn)
        }
      }
      case IProtected(decl) -> {
        // #663: Hoare-call rule at a PMEntry call site reads
        // `callees.<entry>.contracts` to derive the post-state.
        // Verification combines invariants with ed.contracts, so the
        // callee stub must do the same; otherwise a caller can't
        // conclude the invariant after a cross-entry call.
        val protInvs: List[ContractClause] = collectProtectedInvariants(decl)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case PMFunc(fn) -> {
              callees.add(decl.name + "::" + fn.name, fn)
              calleeDecls.add(fn)
            }
            case PMEntry(ed) -> {
              val stubContracts: List[ContractClause] = newList()
              var pi = 0
              while pi < protInvs.count {
                stubContracts.add(protInvs[pi])
                pi = pi + 1
              }
              val edOwn = ed.contracts
              pi = 0
              while pi < edOwn.count {
                stubContracts.add(edOwn[pi])
                pi = pi + 1
              }
              val noDoc: List[DocComment] = newList()
              val noAnn: List[Annotation] = newList()
              val entryFn: FunctionDecl = FunctionDecl(
                docComments = noDoc,
                annotations = noAnn,
                visibility = ed.visibility,
                isAsync = false,
                name = decl.name + "::" + ed.name,
                generics = None,
                params = ed.params,
                ret = ed.ret,
                whereClause = None,
                contracts = stubContracts,
                body = Some(value = ed.body),
                span = ed.span
              )
              callees.add(decl.name + "::" + ed.name, entryFn)
              calleeDecls.add(entryFn)
            }
            case _ -> {
            }
          }
          mi = mi + 1
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }

  val checkedArith = match level { case VLProofRequiredChecked -> true; case _ -> false }
  val sharedSymbols: List[SymbolDecl] = newList()

  // Collect distinct-type aliases (`pub type Cents = Long`) so record /
  // protected field-sort lookups and the per-function `sortOfTypeExprE`
  // call sites resolve them to the underlying primitive (#3853).
  val distinctMap: Map[String, TypeExpr] = newMap()
  var dti0 = 0
  while dti0 < file.items.count {
    match file.items[dti0].kind {
      case IDistinctType(dtDecl) -> {
        if not distinctMap.containsKey(dtDecl.name) {
          distinctMap.add(dtDecl.name, distinctRepresentation(dtDecl))
        }
      }
      case _ -> ()
    }
    dti0 = dti0 + 1
  }

  val fieldInfosMap: Map[String, SortInfo] = newMap()
  val recordDefaultsMap: Map[String, List[Option[Expr]]] = newMap()
  val recordNames: List[String] = newList()

  // Pre-register every `IRecord` as an SMT datatype with one constructor
  // matching the record's fields.  Lets the verifier reason about
  // `Amount(value = c)` constructors and `result.value` field reads against
  // a properly declared sort, instead of falling back to uninterpreted
  // names that z3 rejects as "unknown constant" (#3843).  Generic records
  // are skipped — the SMT encoding here is the simple non-parametric form.
  var ri = 0
  while ri < file.items.count {
    match file.items[ri].kind {
      // Datatype field names share z3's name space with free constants
      // and parameters, so a free param named `capacity` would clash with
      // the selector `capacity` from a Bucket datatype declaration even
      // though their sorts differ (#3855).  Disambiguate selector names by
      // prefixing them with `<TypeName>__` — `Bucket__capacity` for a
      // Bucket-field reading.  EMember's record-field translation mirrors
      // this prefix when it emits the selector TApp.
      case IRecord(recDecl) -> {
        val skipGeneric = match recDecl.generics { case Some(_) -> true; case None -> false }
        if not skipGeneric {
          val dtFields: List[DatatypeField] = newList()
          val dtDefaults: List[Option[Expr]] = newList()
          var fi = 0
          while fi < recDecl.members.count {
            match recDecl.members[fi] {
              case RMField(fld) -> {
                addDatatypeField(dtFields, fieldInfosMap, distinctMap, recDecl.name + "__" + fld.name, fld.ty)
                dtDefaults.add(fld.dflt)
              }
              case _ -> ()
            }
            fi = fi + 1
          }
          val dtCtors: List[DatatypeCtor] = newList()
          dtCtors.add(DatatypeCtor(name = recDecl.name, fields = dtFields))
          sharedSymbols.add(DeclDatatype(name = recDecl.name, constructors = dtCtors))
          if not recordDefaultsMap.containsKey(recDecl.name) {
            recordDefaultsMap.add(recDecl.name, dtDefaults)
            recordNames.add(recDecl.name)
          }
        }
      }
      // Same as IRecord above, but for protected types.  Lets
      // `make`'s `ensures: result.tokens == capacity` discharge against
      // the prefixed selector `Bucket__tokens`.
      case IProtected(pdecl) -> {
        val dtFields: List[DatatypeField] = newList()
        var pfi = 0
        while pfi < pdecl.members.count {
          match pdecl.members[pfi] {
            case PMField(pf) -> {
              match pf {
                case PFVar(fname, fty, _, _, _, _) -> addDatatypeField(
                  dtFields,
                  fieldInfosMap,
                  distinctMap,
                  pdecl.name + "__" + fname,
                  fty
                )
                case PFLet(fname, fty, _, _, _, _) -> addDatatypeField(
                  dtFields,
                  fieldInfosMap,
                  distinctMap,
                  pdecl.name + "__" + fname,
                  fty
                )
                case PFImmutable(fd) -> addDatatypeField(dtFields, fieldInfosMap, distinctMap, pdecl.name + "__" + fd.name, fd.ty)
              }
            }
            case _ -> ()
          }
          pfi = pfi + 1
        }
        val dtCtors: List[DatatypeCtor] = newList()
        dtCtors.add(DatatypeCtor(name = pdecl.name, fields = dtFields))
        sharedSymbols.add(DeclDatatype(name = pdecl.name, constructors = dtCtors))
      }
      case _ -> ()
    }
    ri = ri + 1
  }

  // A record's own methods, which a `recv.m(...)` call reaches before any
  // dot-named `func R.m` (#8101).
  val recordMethodsMap: Map[String, Bool] = newMap()
  var rmi = 0
  while rmi < file.items.count {
    match file.items[rmi].kind {
      case IRecord(rmDecl) -> {
        var rmj = 0
        while rmj < rmDecl.members.count {
          match rmDecl.members[rmj] {
            case RMFunc(rmFn) -> {
              val rmKey = rmDecl.name + "." + rmFn.name
              if not recordMethodsMap.containsKey(rmKey) {
                recordMethodsMap.add(rmKey, true)
              }
            }
            case _ -> ()
          }
          rmj = rmj + 1
        }
      }
      case _ -> ()
    }
    rmi = rmi + 1
  }

  // Build env0 carrying the distinct-type alias map collected above (#3853).
  val env0Init = envEmpty(callees, sharedSymbols, checkedArith)
  val cyclicNames = contractCycles(env0Init, calleeDecls, recordNames, recordDefaultsMap)
  val env0 = VEnv(
    vars = env0Init.vars,
    varNames = env0Init.varNames,
    sorts = env0Init.sorts,
    callees = env0Init.callees,
    symbols = env0Init.symbols,
    checkedArithmetic = env0Init.checkedArithmetic,
    distincts = distinctMap,
    fieldInfos = fieldInfosMap,
    recordDefaults = recordDefaultsMap,
    fresh = env0Init.fresh,
    recordMethods = recordMethodsMap,
    finals = env0Init.finals,
    mutables = env0Init.mutables,
    protectedMembers = env0Init.protectedMembers,
    contractStack = env0Init.contractStack,
    cyclic = cyclicNames
  )

  val allGoals: List[Goal] = newList()
  val allDiags: List[Diagnostic] = newList()

  i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        val fnLevel = levelOfFunction(level, fn)
        if vlIsProofRequired(fnLevel) {
          // #336: aspect weaving runs in driver.l before this point, so
          // the IFunc here is either an original function with no
          // matching aspect, an `__aspect_target` (the renamed inner
          // body), or a wrapper carrying the composed contracts.  All
          // three are verified the same way against their declared
          // contracts.
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
      case IProtected(decl) -> {
        val invContracts: List[ContractClause] = collectProtectedInvariants(decl)
        goalsForProtectedMembers(level, env0, decl.name, decl.members, invContracts, allGoals, allDiags)
      }
      case _ -> {
      }
    }
    i = i + 1
  };

  (allGoals, dedupeDiagnostics(allDiags))
}

// The names of the functions on a cycle of the contract-call graph: an edge
// runs from a function to every function its `requires:`/`ensures:` (and,
// for a `@pure` function, its body, which a call unfolds) calls, matched by
// last name segment so a method or qualified call is never missed.  A
// cycle — a function reaching itself, directly or through others — is what
// unfolding contracts at calls cannot settle (#8102).
func contractCycles(
  env: in VEnv,
  decls: in List[FunctionDecl],
  recordNames: in List[String],
  recordDefaults: in Map[String, List[Option[Expr]]],
): List[String] {
  // Nodes: the functions, then the records (whose field defaults a
  // constructor call translates).  A record is named by itself, as its
  // constructor's call is.
  val nodeNames: List[String] = newList()
  val nodeCalls: List[List[String]] = newList()
  var i = 0
  while i < decls.count {
    val eff = emptyEffects()
    val d = decls[i]
    var ci = 0
    while ci < d.contracts.count {
      match d.contracts[ci] {
        case CCRequires(x, _) -> effExpr(env, x, false, eff)
        case CCEnsures(x, _) -> effExpr(env, x, false, eff)
        case _ -> ()
      }
      ci = ci + 1
    }
    // A call translates the defaults of the parameters it omits.
    var pi = 0
    while pi < d.params.count {
      match d.params[pi].dflt {
        case Some(x) -> effExpr(env, x, false, eff)
        case None -> ()
      }
      pi = pi + 1
    }
    if isPure(d) {
      match d.body {
        case Some(b) -> match b {
          case FBExpr(x) -> effExpr(env, x, false, eff)
          case FBBlock(blk) -> effBlock(env, blk, false, eff)
        }
        case None -> ()
      }
    }
    nodeNames.add(d.name)
    nodeCalls.add(eff.calls)
    i = i + 1
  }
  i = 0
  while i < recordNames.count {
    val eff = emptyEffects()
    match mapGet(recordDefaults, recordNames[i]) {
      case Some(ds) -> {
        var di = 0
        while di < ds.count {
          match ds[di] {
            case Some(x) -> effExpr(env, x, false, eff)
            case None -> ()
          }
          di = di + 1
        }
      }
      case None -> ()
    }
    nodeNames.add(recordNames[i])
    nodeCalls.add(eff.calls)
    i = i + 1
  }
  val succs: List[List[Int]] = newList()
  i = 0
  while i < nodeNames.count {
    val targets: List[Int] = newList()
    var j = 0
    while j < nodeNames.count {
      if nodeCalls[i].contains(nameLeaf(nodeNames[j])) {
        targets.add(j)
      }
      j = j + 1
    }
    succs.add(targets)
    i = i + 1
  }
  val cyclic: List[String] = newList()
  i = 0
  while i < decls.count {
    if reachesItself(succs, i) {
      addName(cyclic, decls[i].name)
    }
    i = i + 1
  }
  cyclic
}

// The part of a function name after its last `.` or `::`.
func nameLeaf(name: in String): String {
  var start = 0
  var k = 0
  while k < name.length {
    val ch = name.substring(k, 1)
    if ch == "." or ch == ":" {
      start = k + 1
    }
    k = k + 1
  }
  name.substring(start, name.length - start)
}

func reachesItself(succs: in List[List[Int]], start: in Int): Bool {
  val seen: List[Int] = newList()
  val todo: List[Int] = newList()
  var k = 0
  while k < succs[start].count {
    todo.add(succs[start][k])
    k = k + 1
  }
  var t = 0
  while t < todo.count {
    val n = todo[t]
    if n == start {
      return true
    }
    if not seen.contains(n) {
      seen.add(n)
      var m = 0
      while m < succs[n].count {
        todo.add(succs[n][m])
        m = m + 1
      }
    }
    t = t + 1
  }
  false
}

// Drop a diagnostic identical (code, message and span) to an earlier one: an
// expression translated more than once — a callee contract at each call, a
// loop condition before and after the havoc — reports its construct once.
func dedupeDiagnostics(diags: in List[Diagnostic]): List[Diagnostic] {
  val seen: Map[String, Bool] = newMap()
  val kept: List[Diagnostic] = newList()
  var i = 0
  while i < diags.count {
    val d = diags[i]
    val key = d.code + "@" + spanKey(d.span) + ":" + d.message
    if not seen.containsKey(key) {
      seen.add(key, true)
      kept.add(d)
    }
    i = i + 1
  }
  kept
}

func spanKey(sp: in Span): String {
  intToString(sp.startPos.offset) + "-" + intToString(sp.endPos.offset)
}
