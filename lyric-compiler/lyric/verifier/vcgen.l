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
  // `SortInfo.intBits` of each `Int`/`Long` record or protected-type field,
  // keyed by its selector (`<Type>__<field>`), so the width of a field read
  // is known to `@proof_required(checked_arithmetic)` (#7871).
  pub fieldIntBits: Map[String, Int]
  // Each non-generic record's field defaults in declaration order, so a
  // constructor call that leaves a defaulted field out is completed with
  // its default (#7873).
  pub recordDefaults: Map[String, List[Option[Expr]]]
  // Copy helpers — use explicit names list to avoid iterating Map.keys on a
  // TypeBuilderInstantiation, which generates invalid IL.
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
// in `goalsForFile`.
pub func sortOfTypeExprE(env: in VEnv, te: in TypeExpr): SortInfo {
  val resolved = resolveDistinct(env.distincts, te)
  match resolved.kind {
    // A range over a distinct alias (`Cents range 0 ..= 100` with `type
    // Cents = ULong`) takes the alias's underlying sort, so its bounds fold
    // signed or unsigned as that sort requires (#7848).
    case TRefined(underlying, range) -> {
      if underlying.segments.count == 1 and env.distincts.containsKey(underlying.segments[0]) {
        val baseTe = TypeExpr(kind = TRef(path = underlying), span = resolved.span)
        val base = sortOfTypeExpr(resolveDistinct(env.distincts, baseTe))
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
  val fieldIntBits: Map[String, Int] = newMap()
  val recordDefaults: Map[String, List[Option[Expr]]] = newMap()
  VEnv(
    vars = vars,
    varNames = varNames,
    sorts = sorts,
    callees = callees,
    symbols = symbols,
    checkedArithmetic = checkedArithmetic,
    distincts = distincts,
    fieldIntBits = fieldIntBits,
    recordDefaults = recordDefaults
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
    fieldIntBits = env.fieldIntBits,
    recordDefaults = env.recordDefaults
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
    fieldIntBits = env.fieldIntBits,
    recordDefaults = env.recordDefaults
  )
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
  pub term: Term
  pub sideConds: List[Term]
  pub assumed: List[Term]
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
// its declared default, translated in `defaultEnv`; with `substEarlier` the
// default may name an earlier parameter, which is replaced by that
// parameter's term.  Each term takes its slot's sort.  Arguments that cannot
// be paired, or an omitted parameter without a default, are V0033 and give
// poisoned terms, so no goal built from the call is discharged.
func pairArgTerms(
  calleeName: in String,
  names: in List[String],
  sorts: in List[Sort],
  defaults: in List[Option[Expr]],
  defaultEnv: in VEnv,
  substEarlier: in Bool,
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
      val earlier: Map[String, Term] = newMap()
      val earlierNames: List[String] = newList()
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
                sideOut.add(substIf(substEarlier, earlier, earlierNames, dR.sideConds[k]))
                k = k + 1
              }
              k = 0
              while k < dR.assumed.count {
                assumedOut.add(substIf(substEarlier, earlier, earlierNames, dR.assumed[k]))
                k = k + 1
              }
              coerceTermAt(substIf(substEarlier, earlier, earlierNames, dR.term), sorts[pi], d.span, diagsOut)
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
        earlier.add(names[pi], t)
        earlierNames.add(names[pi])
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
    fieldIntBits = env.fieldIntBits,
    recordDefaults = env.recordDefaults
  )
}

func substIf(cond: in Bool, m: in Map[String, Term], names: in List[String], t: in Term): Term {
  if cond {
    substTerm(m, names, t)
  } else {
    t
  }
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
func intBitsOfExpr(env: in VEnv, e: in Expr): Int {
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
    case EParen(inner) -> intBitsOfExpr(env, inner)
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
    case EOld(inner) -> intBitsOfExpr(env, inner)
    case EPrefix(op, operand) -> match op { case PreNeg -> intBitsOfExpr(env, operand); case _ -> 0 }
    case EBinop(op, lhs, rhs) -> match op {
      case BAdd | BSub | BMul | BDiv | BMod -> maxInt(
        intBitsOfExpr(env, lhs),
        intBitsOfExpr(env, rhs)
      )
      case _ -> 0
    }
    case EIf(_, thenBranch, elseBranchOpt, _) -> {
      val a = intBitsOfEob(env, thenBranch)
      match elseBranchOpt {
        case Some(eb) -> maxInt(a, intBitsOfEob(env, eb))
        case None -> a
      }
    }
    case EMatch(_, arms) -> {
      var bits = 0
      var i = 0
      while i < arms.count {
        bits = maxInt(bits, intBitsOfEob(env, arms[i].body))
        i = i + 1
      }
      bits
    }
    case EBlock(blk) -> match blockLastExpr(blk) { case Some(last) -> intBitsOfExpr(env, last); case None -> 0 }
    case ECall(fn, _) -> match fn.kind {
      case EPath(path) -> {
        val name = joinPathSegments(path.segments)
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
      case _ -> 0
    }
    case EMember(receiver, memberName) -> {
      val recName = recordNameOfExpr(env, receiver)
      if recName.length > 0 {
        match mapGet(env.fieldIntBits, recName + "__" + memberName) {
          case Some(b) -> b
          case None -> 0
        }
      } else {
        0
      }
    }
    case _ -> 0
  }
}

func intBitsOfEob(env: in VEnv, eob: in ExprOrBlock): Int {
  match eob {
    case EOBExpr(x) -> intBitsOfExpr(env, x)
    case EOBBlock(blk) -> match blockLastExpr(blk) { case Some(last) -> intBitsOfExpr(env, last); case None -> 0 }
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
  val b = intBitsOfExpr(env, e)
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
      val diags: List[Diagnostic] = newList()
      match inner.kind {
        case EPath(path) -> {
          if path.segments.count >= 1 {
            val leafName = path.segments[path.segments.count - 1]
            val key = "old." + leafName
            match envLookup(key, env) {
              case Some(t) -> (singleTR(t), diags)
              case None -> {
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
          diags.add(
            warningDiagnostic("V0021", "`old(e)` for non-path expressions is not yet supported; treating as current", e.span)
          )
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
        case None -> {
          val ed: List[Diagnostic] = newList()
          val noBranchPair: (TranslateResult, List[Diagnostic]) = (singleTR(unitTerm()), ed)
          noBranchPair
        }
      }

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
          val binopVar = TVar(name = "?binop", sort = binopSort)
          val binopPair: (TranslateResult, List[Diagnostic]) = (singleTR(binopVar), diags)
          binopPair
        }
      }
    }

    case ECall(fn, args) -> {
      // Translate all arguments first.
      val rawArgTerms: List[Term] = newList()
      val argSpans: List[Span] = newList()
      val argSides: List[Term] = newList()
      val argAssumed: List[Term] = newList()
      val allArgDiags: List[Diagnostic] = newList()
      var i = 0
      while i < args.count {
        val argExpr = match args[i] { case CANamed(_, v, _) -> v; case CAPositional(v) -> v }
        val (ar, ad) = translateExpr(env, argExpr)
        rawArgTerms.add(ar.term)
        argSpans.add(argExpr.span)
        appendTermList(argSides, ar.sideConds)
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
                varlessEnv(env),
                false,
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
          match mapGet(env.callees, name) {
            case Some(decl) -> {
              val resultInfo = match decl.ret { case Some(te) -> sortOfTypeExprE(env, te); case None -> unitSortInfo() }
              val resultSort = resultInfo.sort
              val paramSorts: List[Sort] = newList()
              var pi = 0
              while pi < decl.params.count {
                paramSorts.add(sortOfTypeExprE(env, decl.params[pi].ty).sort)
                pi = pi + 1
              }
              env.symbols.add(DeclUserFun(name = name, paramSorts = paramSorts, resultSort = resultSort))

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
              val emptyCallees: Map[String, FunctionDecl] = newMap()
              val emptySymbols: List[SymbolDecl] = newList()
              val innerEnv = VEnv(
                vars = innerVars,
                varNames = innerVarNames,
                sorts = innerSorts,
                callees = emptyCallees,
                symbols = emptySymbols,
                checkedArithmetic = false,
                distincts = env.distincts,
                fieldIntBits = env.fieldIntBits,
                recordDefaults = env.recordDefaults
              )
              // A parameter default is evaluated at the call, in the callee's
              // parameter scope.
              val defaultEnv = VEnv(
                vars = innerVars,
                varNames = innerVarNames,
                sorts = innerSorts,
                callees = env.callees,
                symbols = env.symbols,
                checkedArithmetic = env.checkedArithmetic,
                distincts = env.distincts,
                fieldIntBits = env.fieldIntBits,
                recordDefaults = env.recordDefaults
              )

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
                true,
                args,
                rawArgTerms,
                argSpans,
                e.span,
                argSides,
                argAssumed,
                allArgDiags
              )
              val argTerms = paired.terms
              val rawCallTerm = TApp(name = name, args = argTerms, retSort = resultSort)
              val callTerm = if paired.paired { rawCallTerm } else { poisonTerm(rawCallTerm) }

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
              if isPure(decl) {
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
                    val (preR, preDiags) = translateExpr(innerEnv, pre)
                    keepUntranslatableDiags(preDiags, allArgDiags)
                    preConds.add(substTerm(paramSubst, paramSubstNames, preR.term))
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
              resultVars2.add("result", callTerm)
              resultSorts2.add("result", resultSI)
              resultVarNames2.add("result")
              val resultEnv = VEnv(
                vars = resultVars2,
                varNames = resultVarNames2,
                sorts = resultSorts2,
                callees = emptyCallees,
                symbols = emptySymbols,
                checkedArithmetic = false,
                distincts = env.distincts,
                fieldIntBits = env.fieldIntBits,
                recordDefaults = env.recordDefaults
              )
              ci = 0
              while ci < decl.contracts.count {
                match decl.contracts[ci] {
                  case CCEnsures(post, _) -> {
                    val (postR, postDiags) = translateExpr(resultEnv, post)
                    keepUntranslatableDiags(postDiags, allArgDiags)
                    postConds.add(substTerm(paramSubst, paramSubstNames, postR.term))
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
              val knownCalleeTR = TranslateResult(term = callTerm, sideConds = sc, assumed = asList)
              val knownCalleePair: (TranslateResult, List[Diagnostic]) = (knownCalleeTR, allArgDiags)
              knownCalleePair
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
                val distinctTR = TranslateResult(term = rawArgTerms[0], sideConds = argSides, assumed = argAssumed)
                val distinctPair: (TranslateResult, List[Diagnostic]) = (distinctTR, allArgDiags)
                return distinctPair
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
          val unkSort = SUninterp(name = "field." + memberName)
          TApp(name = "$field." + memberName, args = termList1(rR.term), retSort = unkSort)
        }
      }
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
        case None -> {
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
      val allSides: List[Term] = newList()
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
      diags.add(warningDiagnostic("V0024", "expression construct not yet modelled in proof translation", e.span))
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
    case EOBExpr(x) -> translateExpr(env, x)
    case EOBBlock(blk) -> {
      // Extract trailing expression (last SExpr or SReturn).
      val lastOpt = blockLastExpr(blk)
      match lastOpt {
        case Some(x) -> translateExpr(env, x)
        case None -> {
          val diags: List[Diagnostic] = newList()
          diags.add(warningDiagnostic("V0022", "block branches in contract expressions not yet supported in M4.1", ctxSpan))
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
  arms: in List[MatchArm],
  idx: in Int,
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
    return TVar(name = "?match.fallthrough", sort = sortOf(scrutTerm))
  }
  val arm = arms[idx]
  val condOpt = matchCond(arm.pattern, scrutTerm)
  match condOpt {
    case None -> {
      // Pattern not supported in M4.1 — skip arm.
      diagsOut.add(warningDiagnostic("V0027", "match arm pattern not yet supported in M4.1 verifier", arm.span))
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
        val info = SortInfo(sort = sortOf(bterm), range = RBKNone)
        armEnv = envBindTerm(bname, bterm, info, armEnv)
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
    case EOBBlock(_) -> {
      diagsOut.add(warningDiagnostic("V0028", "block-form match arm bodies not yet supported in M4.1 verifier", arm.span))
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
// WP over a single expression (for FBExpr).
func wpExpr(env: in VEnv, resultSort: in SortInfo, postcond: in Term, e: in Expr): WpResult {
  val (r, diags) = translateExpr(env, e)
  // Substitute result into postcond, at the declared result sort (#7848).
  val substMap: Map[String, Term] = newMap()
  substMap.add("result", coerceTermAt(r.term, resultSort.sort, e.span, diags))
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
    case FBExpr(e) -> wpExpr(env, resultSort, postcond, e)
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
            // Trailing expression in a block is the implicit return value (#3371).
            if idx + 1 >= stmts.count {
              wpExpr(env, resultSort, postcond, callExpr)
            } else {
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
                      while i < inner.sideGoals.count {
                        sg.add(inner.sideGoals[i])
                        i = i + 1
                      }
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
      wpBindInit(env, resultSort, postcond, stmts, idx, name, ty, init)
    }
    case LBLet(name, ty, init) -> wpBindInit(env, resultSort, postcond, stmts, idx, name, ty, init)
    case LBVar(name, ty, Some(init)) -> wpBindInit(env, resultSort, postcond, stmts, idx, name, ty, init)
    case LBVar(name, ty, None) -> {
      // Uninitialized var — bind to a fresh symbolic value of its declared
      // sort (an unannotated one is an integer, as before).
      val info = match ty {
        case Some(t) -> {
          val declared = sortOfTypeExprE(env, t)
          SortInfo(sort = declared.sort, range = RBKNone, intBits = declared.intBits)
        }
        case None -> SortInfo(sort = SInt, range = RBKNone)
      }
      val env2 = envBind(name, info, env)
      wpWalk(env2, resultSort, postcond, stmts, idx + 1)
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
): WpResult {
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
  val env2 = envBindTerm(name, boundTerm, info, env)
  val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
  val sg: List[SideGoal] = newList()
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
  appendTermList(asList, rangeHypotheses(name, info))
  appendTermList(asList, inner.assumed)
  val di: List[Diagnostic] = newList()
  appendTermList2(di, initDiags)
  appendTermList2(di, inner.diags)
  WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
}

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
  match target.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
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
        val env2 = envBindTerm(name, combined, info, env)
        val inner = wpWalk(env2, resultSort, postcond, stmts, idx + 1)
        val sg: List[SideGoal] = newList()
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
        appendTermList(asList, inner.assumed)
        val di: List[Diagnostic] = newList()
        appendTermList2(di, rhsDiags)
        appendTermList2(di, inner.diags)
        WpResult(wp = inner.wp, sideGoals = sg, assumed = asList, diags = di)
      } else {
        val di: List[Diagnostic] = newList()
        di.add(warningDiagnostic("V0026", "complex assignment target not yet supported in proof body", target.span))
        val inner = wpWalk(env, resultSort, postcond, stmts, idx + 1)
        val allDi: List[Diagnostic] = newList()
        appendTermList2(allDi, di)
        appendTermList2(allDi, inner.diags)
        WpResult(wp = inner.wp, sideGoals = inner.sideGoals, assumed = inner.assumed, diags = allDi)
      }
    }
    case _ -> {
      val di: List[Diagnostic] = newList()
      di.add(warningDiagnostic("V0026", "complex assignment target not yet supported in proof body", target.span))
      val inner = wpWalk(env, resultSort, postcond, stmts, idx + 1)
      val allDi: List[Diagnostic] = newList()
      appendTermList2(allDi, di)
      appendTermList2(allDi, inner.diags)
      WpResult(wp = inner.wp, sideGoals = inner.sideGoals, assumed = inner.assumed, diags = allDi)
    }
  }
}

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

  // Translate invariant terms.
  val invTerms: List[Term] = newList()
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
  // A havocked `Int`/`Long` still holds a value of its type (#7871).
  val havocWidthHyps: List[Term] = newList()
  i = 0
  while i < modifiedVars.count {
    val vname = modifiedVars[i]
    val vinfo = match envLookupSort(vname, env) {
      case Some(si) -> si
      case None -> SortInfo(sort = SInt, range = RBKNone)
    }
    val havocName = vname + "$loopout"
    val havocTerm = TVar(name = havocName, sort = vinfo.sort)
    envAfterHavoc = envBindTerm(vname, havocTerm, vinfo, envAfterHavoc)
    appendTermList(havocWidthHyps, intWidthHypothesesForTerm(havocTerm, vinfo))
    i = i + 1
  }

  // Re-translate invariant and cond in post-havoc env.
  val iotaPostTerms: List[Term] = newList()
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
  appendTermList(postLoopAssumed, havocWidthHyps)

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
  while i < bodyWp.sideGoals.count {
    sg.add(bodyWp.sideGoals[i])
    i = i + 1
  }
  i = 0
  while i < inner.sideGoals.count {
    sg.add(inner.sideGoals[i])
    i = i + 1
  }

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
            if not output.contains(name) {
              output.add(name)
            }
          }
        }
        case _ -> {
        }
      }
    }
    case SWhile(_, _, body) -> collectModifiedVars(body.statements, output)
    case SFor(_, _, _, body) -> collectModifiedVars(body.statements, output)
    case SLoop(_, body) -> collectModifiedVars(body.statements, output)
    case SDefer(body) -> collectModifiedVars(body.statements, output)
    case SScope(_, body) -> collectModifiedVars(body.statements, output)
    case STry(body, _, _) -> collectModifiedVars(body.statements, output)
    case _ -> {
    }
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
    envWithParams = envBind(p.name, info, envWithParams)
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

  // Translate requires clauses.
  val preTerms: List[Term] = newList()
  val preAssumed: List[Term] = newList()
  val preDiags: List[Diagnostic] = newList()
  i = 0
  while i < decl.contracts.count {
    match decl.contracts[i] {
      case CCRequires(e, _) -> {
        val (t, asList, d) = translateContract(envWithParams, e)
        preTerms.add(t)
        appendTermList(preAssumed, asList)
        appendTermList2(preDiags, d)
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  val preTerm = mkAnd(preTerms)

  // Translate ensures clauses.
  val postTerms: List[Term] = newList()
  val postAssumed: List[Term] = newList()
  val postDiags: List[Diagnostic] = newList()
  i = 0
  while i < decl.contracts.count {
    match decl.contracts[i] {
      case CCEnsures(e, _) -> {
        val (t, asList, d) = translateContract(envWithOld, e)
        postTerms.add(t)
        appendTermList(postAssumed, asList)
        appendTermList2(postDiags, d)
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

  val wpRes = wpBody(envWithOld, resultSort, combinedPost, body)

  // Main goal hypotheses.
  val hypotheses: List[Term] = newList()
  appendTermList(hypotheses, paramHyps)
  appendTermList(hypotheses, extraHyps)
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
    fieldIntBits = env.fieldIntBits,
    recordDefaults = env.recordDefaults
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
    val (goals, diags) = goalsForFunctionWithExtraHyps(fnEnv, synthDecl, fieldRangeHyps)
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
  var mi = 0
  while mi < members.count {
    match members[mi] {
      case PMEntry(ed) -> {
        goalsForProtectedEntry(level, env0, protName, ed, invContracts, members, allGoals, allDiags)
      }
      case PMFunc(fn) -> {
        goalsForProtectedFunc(level, env0, fn, allGoals, allDiags)
      }
      case _ -> {
      }
    }
    mi = mi + 1
  }
}

// Register one field of a record or protected type's datatype under its
// selector name, and its signed width when it is an `Int` or `Long` (#7871).
func addDatatypeField(
  dtFields: in List[DatatypeField],
  bitsMap: in Map[String, Int],
  distinctMap: in Map[String, TypeExpr],
  selector: in String,
  ty: in TypeExpr,
): Unit {
  val info = sortOfTypeExpr(resolveDistinct(distinctMap, ty))
  dtFields.add(DatatypeField(name = selector, sort = info.sort))
  if info.intBits > 0 and not bitsMap.containsKey(selector) {
    bitsMap.add(selector, info.intBits)
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
  val callees: Map[String, FunctionDecl] = newMap()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> callees.add(fn.name, fn)
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
            case PMFunc(fn) -> callees.add(decl.name + "::" + fn.name, fn)
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
          distinctMap.add(dtDecl.name, dtDecl.underlying)
        }
      }
      case _ -> ()
    }
    dti0 = dti0 + 1
  }

  val fieldIntBitsMap: Map[String, Int] = newMap()
  val recordDefaultsMap: Map[String, List[Option[Expr]]] = newMap()

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
                addDatatypeField(dtFields, fieldIntBitsMap, distinctMap, recDecl.name + "__" + fld.name, fld.ty)
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
                  fieldIntBitsMap,
                  distinctMap,
                  pdecl.name + "__" + fname,
                  fty
                )
                case PFLet(fname, fty, _, _, _, _) -> addDatatypeField(
                  dtFields,
                  fieldIntBitsMap,
                  distinctMap,
                  pdecl.name + "__" + fname,
                  fty
                )
                case PFImmutable(fd) -> addDatatypeField(dtFields, fieldIntBitsMap, distinctMap, pdecl.name + "__" + fd.name, fd.ty)
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

  // Build env0 carrying the distinct-type alias map collected above (#3853).
  val env0Init = envEmpty(callees, sharedSymbols, checkedArith)
  val env0 = VEnv(
    vars = env0Init.vars,
    varNames = env0Init.varNames,
    sorts = env0Init.sorts,
    callees = env0Init.callees,
    symbols = env0Init.symbols,
    checkedArithmetic = env0Init.checkedArithmetic,
    distincts = distinctMap,
    fieldIntBits = fieldIntBitsMap,
    recordDefaults = recordDefaultsMap
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
