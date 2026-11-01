//! typechecker_exprs.l — bottom-up expression type inference.
//! Mirrors compiler/src/Lyric.TypeChecker/ExprChecker.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols
import Lyric.HoistEngine as HoistEngine

// `s += <rhs>` onto a String target accepts any RHS type, mirroring binary
// `+`'s "any operand + String = String" inference (#5657).  Scoped to `+=`
// with a String-typed target: a plain 1-segment variable, a field access
// (`obj.f += x`), or an index expression (`xs[i] += x`) — all three shapes'
// compound-assign codegen on both backends threads the target's real
// (checker-known) String type rather than inferring it from the RHS (#5688),
// so widening them is sound. Every other compound op and every other target
// type also stays strict, like `=`.  Shared by the SAssign
// (typechecker_stmts.l) and EAssign checking paths.
pub func isStringPlusVarAssign(target: in Expr, op: in AssignOp, targetType: in Type): Bool {
  val targetIsWidenableShape = match target.kind {
    case EPath(p) -> p.segments.count == 1
    case EMember(_, _) -> true
    case EIndex(_, _) -> true
    case _ -> false
  }
  targetIsWidenableShape and
    match op {
      case AssPlus -> match targetType {
        case TyPrim(pt) -> match pt { case PtString -> true; case _ -> false }
        case _ -> false
      }
      case _ -> false
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §1. Literal types.
// ─────────────────────────────────────────────────────────────────────────────
pub func typeOfLiteral(lit: in Literal): Type {
  match lit {
    case LInt(v, sfx, _) -> match sfx {
      // An unsuffixed literal defaults to `Int` only when its value fits;
      // a larger one is a `Long` (never a wrapped `Int`, #7346).  The one
      // exception, `-2147483648`, is handled by `inferExpr`'s negation arm.
      case NoIntSuffix -> if longFitsInt(v) { TyPrim(pt = PtInt) } else { TyPrim(pt = PtLong) }
      // `Byte` is unsigned, so the signed `i8` range (-128 ..= 127) is an
      // `Int`, as `i16`'s is (#7847); `u8` is the `Byte` suffix.
      case I8 -> TyPrim(pt = PtInt)
      case I16 -> TyPrim(pt = PtInt)
      case I32 -> TyPrim(pt = PtInt)
      case I64 -> TyPrim(pt = PtLong)
      case U8 -> TyPrim(pt = PtByte)
      case U16 -> TyPrim(pt = PtUInt)
      case U32 -> TyPrim(pt = PtUInt)
      case U64 -> TyPrim(pt = PtULong)
    }
    case LFloat(_, sfx, _) -> match sfx {
      case NoFloatSuffix -> TyPrim(pt = PtDouble)
      case F32 -> TyPrim(pt = PtFloat)
      case F64 -> TyPrim(pt = PtDouble)
    }
    case LChar(_) -> TyPrim(pt = PtChar)
    case LString(_) -> TyPrim(pt = PtString)
    case LTripleString(_) -> TyPrim(pt = PtString)
    case LRawString(_) -> TyPrim(pt = PtString)
    case LBool(_) -> TyPrim(pt = PtBool)
    case LUnit -> TyPrim(pt = PtUnit)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Codegen builtins.
// ─────────────────────────────────────────────────────────────────────────────
// A single-segment path that is no local: a type name in the type-qualified
// call form (`Int.shl(k, 2)`), not a value to infer.
func recvIsUnboundName(sc: in Scope, e: in Expr): Bool {
  match e.kind {
    case EPath(sp) -> sp.segments.count == 1 and
      (match scopeTryFind(sc, sp.segments[0]) { case Some(_) -> false; case None -> true })
    case _ -> false
  }
}

// Keep in sync with `isCodegenBuiltinName` in `typechecker_checker.l` (shadow-prevention).
func codegenBuiltinType(name: in String): Option[Type] {
  if name == "println" or name == "print" {
    val ps: List[Type] = newList()
    ps.add(TyError)
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtUnit), isAsync = false))
  }
  if name == "toString" {
    val ps: List[Type] = newList()
    ps.add(TyError)
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtString), isAsync = false))
  }
  if name == "panic" {
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtString))
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtNever), isAsync = false))
  }
  if name == "default" {
    val ps: List[Type] = newList()
    return Some(value = TyFunction(params = ps, ret = TyError, isAsync = false))
  }
  if name == "expect" {
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtBool))
    ps.add(TyPrim(pt = PtString))
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtUnit), isAsync = false))
  }
  if name == "assert" {
    // `assert(cond)` or `assert(cond, message)`: the message is optional
    // (`builtinOptionalTrailingArgs`).
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtBool))
    ps.add(TyPrim(pt = PtString))
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtUnit), isAsync = false))
  }
  match formatBuiltinArity(name) {
    case Some(arity) -> {
      // `formatN(template, a1, ..., aN)`: a `String` template and N arguments
      // of any type, each stringified as `toString` does (#7840).
      val ps: List[Type] = newList()
      ps.add(TyPrim(pt = PtString))
      var fi = 0
      while fi < arity {
        ps.add(TyError)
        fi = fi + 1
      }
      return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtString), isAsync = false))
    }
    case None -> ()
  }
  if name == "stringToUtf8Bytes" {
    // JVM codegen intrinsic (`lowerCall` in jvm/codegen/04_calls.l): kernel
    // packages (stdlib `_kernel_jvm/` and ecosystem `_kernel/jvm/` twins)
    // call it unqualified.  Registered here so fatal type-check gating on
    // user-owned JVM packages (#5609 item 1) does not reject working kernel
    // code with a spurious T0020.
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtString))
    return Some(value = TyFunction(params = ps, ret = TySlice(element = TyPrim(pt = PtByte)), isAsync = false))
  }
  if name == "hostParseIntIsValid" or name == "hostParseLongIsValid" or name == "hostParseDoubleIsValid" or name == "hostFileExists" or name == "hostReadAllTextIsValid" or name == "hostDirectoryExists" or name == "hostCreateDirectoryIsValid" {
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtString))
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtBool), isAsync = false))
  }
  if name == "hostParseIntValue" or name == "hostParseLongValue" {
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtString))
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtInt), isAsync = false))
  }
  if name == "hostParseDoubleValue" {
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtString))
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtDouble), isAsync = false))
  }
  if name == "hostReadAllTextValue" or name == "hostReadAllTextError" {
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtString))
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtString), isAsync = false))
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Operator semantics.
// ─────────────────────────────────────────────────────────────────────────────
func isNumericType(t: in Type): Bool {
  match t {
    case TyPrim(pt) -> match pt {
      case PtByte -> true
      case PtInt -> true
      case PtLong -> true
      case PtUInt -> true
      case PtULong -> true
      case PtNat -> true
      case PtFloat -> true
      case PtDouble -> true
      case _ -> false
    }
    // A range subtype is numeric/ordered when its underlying representation is —
    // otherwise arithmetic / comparison on a range-typed value would spuriously fail T0030/T0033.
    case TyRefined(u, _, _, _, _) -> isNumericType(u)
    case TyError -> true
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3a. Numeric widening (M6).
// ─────────────────────────────────────────────────────────────────────────────
// Widening rank of a signed integer primitive: Byte < Int < Long.
func signedIntRank(pt: in PrimType): Int {
  match pt {
    case PtByte -> 0
    case PtInt -> 1
    case PtLong -> 2
    case _ -> -1
  }
}

// Widening rank of an unsigned integer primitive: Byte < UInt < ULong.
func unsignedIntRank(pt: in PrimType): Int {
  match pt {
    case PtByte -> 0
    case PtUInt -> 1
    case PtULong -> 2
    case _ -> -1
  }
}

// Widening rank of a floating-point primitive: Float < Double.
func floatPrimRank(pt: in PrimType): Int {
  match pt {
    case PtFloat -> 0
    case PtDouble -> 1
    case _ -> -1
  }
}

// When `lhs` and `rhs` are numeric primitives that widen to a common type
// return that type; return `None` when they are the same type (no widening
// needed) or when they are incompatible.  Used by `inferBinop` so that e.g.
// `Int + Long` type-checks and yields `Long`.
func widenArithmetic(lhs: in Type, rhs: in Type): Option[Type] {
  match lhs {
    case TyPrim(pa) -> match rhs { case TyPrim(pb) -> widenPrimArithmetic(lhs, rhs, pa, pb); case _ -> None }
    case _ -> None
  }
}

// The widening families are disjoint by construction (each rank function
// returns -1 outside its family), so the three sections are tried in order.
func widenPrimArithmetic(lhs: in Type, rhs: in Type, pa: in PrimType, pb: in PrimType): Option[Type] {
  if primEq(pa, pb) {
    return None
  }
  // Signed integers: Byte < Int < Long.
  val asr = signedIntRank(pa)
  val bsr = signedIntRank(pb)
  if asr >= 0 and bsr >= 0 {
    return Some(value = if asr >= bsr { lhs } else { rhs })
  }
  // Unsigned integers: Byte < UInt < ULong.
  val au = unsignedIntRank(pa)
  val bu = unsignedIntRank(pb)
  if au >= 0 and bu >= 0 {
    return Some(value = if au >= bu { lhs } else { rhs })
  }
  // Floating point: Float < Double.
  val af = floatPrimRank(pa)
  val bf = floatPrimRank(pb)
  if af >= 0 and bf >= 0 {
    return Some(value = if af >= bf { lhs } else { rhs })
  }
  None
}

func isOrderedType(t: in Type): Bool {
  if isNumericType(t) {
    return true
  }
  match t {
    case TyPrim(pt) -> match pt { case PtChar -> true; case PtString -> true; case _ -> false }
    case TyRefined(u, _, _, _, _) -> isOrderedType(u)
    case _ -> false
  }
}

// A primitive's fixed capability set against the nine well-known markers
// (#5549 / D-progress-807): equality/hashing/ordering/defaults hold for
// EVERY primitive; the arithmetic markers hold only for numerics, with
// `Add` additionally extended to `String` (whose `+` is concatenation).
// Primitives have no `derives` list to opt into, so `hasDerive`'s ordinary
// `TyUser` lookup can never see them — this is the checker's own copy of
// `mono.l`'s `primitiveSatisfiesMarker`, which the two functions must be
// kept in sync with by hand (they consult different type representations —
// a resolved `Type`/`TyPrim` here vs. an unresolved `TypeExpr`/`TRef` name
// in `mono.l` — so a shared helper isn't a clean fit without a larger
// representation refactor of one side).
func primitiveHasDerive(pt: in PrimType, marker: in String): Bool {
  if marker == "Equals" or marker == "Hash" or marker == "Compare" or marker == "Default" {
    return true
  }
  val isNumeric = match pt {
    case PtByte -> true
    case PtInt -> true
    case PtLong -> true
    case PtUInt -> true
    case PtULong -> true
    case PtNat -> true
    case PtFloat -> true
    case PtDouble -> true
    case _ -> false
  }
  if marker == "Add" {
    return isNumeric or (match pt { case PtString -> true; case _ -> false })
  }
  isNumeric
}

func hasDerive(tbl: in SymbolTable, marker: in String, t: in Type): Bool {
  match t {
    case TyPrim(pt) -> primitiveHasDerive(pt, marker)
    case TyUser(tid, _, _) -> {
      var i = 0
      while i < tbl.symbols.count {
        val sym = tbl.symbols[i]
        match sym.kind {
          case DKDistinctType(did, dt) -> {
            if symbolIdEq(did, tid) {
              return listContainsStr(dt.derives, marker)
            }
          }
          case DKRecord(rid, _) -> {
            if symbolIdEq(rid, tid) {
              return listContainsStr(sym.derives, marker)
            }
          }
          case DKExposedRec(rid, _) -> {
            if symbolIdEq(rid, tid) {
              return listContainsStr(sym.derives, marker)
            }
          }
          case DKUnion(uid, _) -> {
            if symbolIdEq(uid, tid) {
              return listContainsStr(sym.derives, marker)
            }
          }
          case _ -> {
          }
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

func listContainsStr(xs: in List[String], s: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == s {
      return true
    }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §3a. Match exhaustiveness (#1483, Band-1).
// ─────────────────────────────────────────────────────────────────────────────
// The finite set of constructor case names for a union/enum scrutinee type, or
// `None` if `t` is not a type whose value space is a known finite set of named
// cases (records, tuples, externs, unresolved ids — anything we can't enumerate
// — return `None` so exhaustiveness is skipped rather than mis-reported).
func finiteCaseNames(tbl: in SymbolTable, t: in Type): Option[List[String]] {
  match t {
    case TyUser(id, _, _) -> {
      var i = 0
      while i < tbl.symbols.count {
        match tbl.symbols[i].kind {
          case DKUnion(uid, decl) -> {
            if symbolIdEq(uid, id) {
              val names: List[String] = newList()
              var c = 0
              while c < decl.cases.count {
                names.add(decl.cases[c].name)
                c = c + 1
              }
              return Some(value = names)
            }
          }
          case DKEnum(eid, decl) -> {
            if symbolIdEq(eid, id) {
              val names: List[String] = newList()
              var c = 0
              while c < decl.cases.count {
                names.add(decl.cases[c].name)
                c = c + 1
              }
              return Some(value = names)
            }
          }
          case _ -> {
          }
        }
        i = i + 1
      }
      None
    }
    case _ -> None
  }
}

// A pattern is a catch-all (irrefutable) iff it matches every value.  A bare
// `case Foo` parses as `PBinding("Foo", None)`; it is a *variable bind*
// (catch-all) only when `Foo` does NOT name a case of the scrutinee type —
// otherwise it is a nullary-constructor test (matches just that case).  This
// mirrors the codegen rule in `msil/codegen.l` (PBinding → isinst when the name
// is a known case, else bind-anything).
func patternIsCatchAll(p: in Pattern, caseNames: in List[String]): Bool {
  match p.kind {
    case PWildcard -> true
    case PBinding(name, inner) -> match inner {
      case Some(ip) -> patternIsCatchAll(ip, caseNames)
      case None -> not listContainsStr(caseNames, name)
    }
    case PParen(ip) -> patternIsCatchAll(ip, caseNames)
    case POr(ps) -> {
      var any = false
      var i = 0
      while i < ps.count {
        if patternIsCatchAll(ps[i], caseNames) {
          any = true
        }
        i = i + 1
      }
      any
    }
    case _ -> false
  }
}

// Add to `covered` any top-level constructor case names this pattern matches.
func collectCoveredCases(p: in Pattern, caseNames: in List[String], covered: in List[String]): Unit {
  match p.kind {
    case PBinding(name, inner) -> match inner {
      case Some(ip) -> collectCoveredCases(ip, caseNames, covered)
      case None -> if listContainsStr(caseNames, name) and not listContainsStr(covered, name) {
        covered.add(name)
      }
    }
    case PConstructor(head, _) -> {
      if head.segments.count > 0 {
        val nm = head.segments[head.segments.count - 1]
        if listContainsStr(caseNames, nm) and not listContainsStr(covered, nm) {
          covered.add(nm)
        }
      }
    }
    case PRecord(head, _, _) -> {
      if head.segments.count > 0 {
        val nm = head.segments[head.segments.count - 1]
        if listContainsStr(caseNames, nm) and not listContainsStr(covered, nm) {
          covered.add(nm)
        }
      }
    }
    case PParen(ip) -> collectCoveredCases(ip, caseNames, covered)
    case POr(ps) -> {
      var i = 0
      while i < ps.count {
        collectCoveredCases(ps[i], caseNames, covered)
        i = i + 1
      }
    }
    case _ -> {
    }
  }
}

// Does any unguarded arm of the match supply an irrefutable catch-all?  Guarded
// arms never count (the guard may fail at runtime).
func armsHaveCatchAll(arms: in List[MatchArm], caseNames: in List[String]): Bool {
  var i = 0
  while i < arms.count {
    match arms[i].guard {
      case None -> if patternIsCatchAll(arms[i].pattern, caseNames) { return true }
      case Some(_) -> {
      }
    }
    i = i + 1
  }
  false
}

func joinStrs(xs: in List[String], sep: in String): String {
  if xs.count == 0 {
    return ""
  }
  var s = xs[0]
  var i = 1
  while i < xs.count {
    s = s + sep + xs[i]
    i = i + 1
  }
  s
}

// Is `pt` a primitive whose value space is unbounded (so a match is exhaustive
// only via a catch-all)?  Bool is finite and handled separately; Unit/Never are
// skipped (a one-value / zero-value space needs no wildcard rule here).
func isUnboundedScalar(pt: in PrimType): Bool {
  match pt {
    case PtByte -> true
    case PtInt -> true
    case PtLong -> true
    case PtUInt -> true
    case PtULong -> true
    case PtNat -> true
    case PtFloat -> true
    case PtDouble -> true
    case PtChar -> true
    case PtString -> true
    case _ -> false
  }
}

// Emit T0016 when a `match` cannot match every possible scrutinee value.
// Conservative by construction: only unions, enums, `Bool`, and unbounded
// primitive scalars are judged; every other scrutinee shape is skipped, so a
// valid match is never rejected.
// #1485: the declared name of an *imported* opaque type that `ty` resolves to,
// or `None`.  Used to forbid cross-package pattern-matching of an opaque type's
// hidden representation.
func importedOpaqueName(tbl: in SymbolTable, ty: in Type): Option[String] {
  match unrefine(ty) {
    case TyUser(id, _, _) -> {
      val key = toString(id.id)
      if not tbl.importedOpaqueNames.containsKey(key) {
        return None
      }
      val nm = tbl.importedOpaqueNames[key]
      Some(value = nm)
    }
    case _ -> None
  }
}

// Does this pattern crack a value's representation (destructure its fields),
// as opposed to binding/ignoring the whole value?  A record pattern, or a
// constructor pattern with sub-patterns, reads the representation; a bare
// binding or wildcard does not.
func patternCracksRepr(p: in Pattern): Bool {
  match p.kind {
    case PRecord(_, _, _) -> true
    // Bare constructor with no sub-patterns (a.count == 0) does not crack the repr for
    // single-variant opaque records; if multi-variant opaque types are ever added, even
    // a bare `case Variant ->` leaks which variant is held and would need to return true.
    case PConstructor(_, a) -> a.count > 0
    case PParen(ip) -> patternCracksRepr(ip)
    case POr(ps) -> {
      var any = false
      var i = 0
      while i < ps.count {
        if patternCracksRepr(ps[i]) {
          any = true
        }
        i = i + 1
      }
      any
    }
    case _ -> false
  }
}

// #1485: pattern-matching the hidden representation of an opaque type is only
// permitted inside its declaring package.  A cross-package match that
// destructures the representation (record/constructor pattern) is rejected
// with T0102; binding or wildcard arms remain legal (the value is opaque but
// usable).
func checkOpaquePatternHiding(
  tbl: in SymbolTable, diag: in List[Diagnostic], st: in Type, arms: in List[MatchArm]
): Unit {
  match importedOpaqueName(tbl, st) {
    case None -> {
    }
    case Some(nm) -> {
      var i = 0
      while i < arms.count {
        if patternCracksRepr(arms[i].pattern) {
          diag.add(
            errorDiagnostic(
              "T0102",
              "cannot pattern-match the representation of opaque type '" + nm + "' outside its declaring package",
              arms[i].pattern.span
            )
          )
        }
        i = i + 1
      }
    }
  }
}

// Resolve a const/val name to its Bool literal value, if it is a Bool const
// initialised with a literal.  Used by Bool match exhaustiveness so that a
// `case @FLAG_ENABLED` / `case @FLAG_DISABLED` pair (const patterns, #3488)
// is recognised as covering `true`/`false` rather than falling through and
// producing a false T0016.  Returns None for non-Bool / non-literal inits.
//
// Only `EParen`/`ELiteral` need handling (#3510): a type annotation on the
// val (`val ON: Bool = true`) lives in the val's declared type, not in its
// initializer expression, so the init is still a bare `ELiteral`.  A const
// pattern that reaches exhaustiveness has already passed `checkConstRefPattern`
// (literal-init required, else T0069), so a Bool const here always has a bare
// literal init; returning None for any other shape only ever fails safe (a
// conservative T0016), never silently accepts a non-exhaustive match.
func constBoolOfExpr(e: in Expr): Option[Bool] {
  match e.kind {
    case EParen(inner) -> constBoolOfExpr(inner)
    case ELiteral(lit) -> match lit { case LBool(b) -> Some(value = b); case _ -> None }
    case _ -> None
  }
}

func tryResolveConstBool(tbl: in SymbolTable, name: in String): Option[Bool] {
  match symTableTryFindOne(tbl, name) {
    case None -> None
    case Some(sym) -> match sym.kind {
      case DKConst(cd) -> constBoolOfExpr(cd.init)
      case DKVal(vd) -> constBoolOfExpr(vd.init)
      case _ -> None
    }
  }
}

func checkMatchExhaustive(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  st0: in Type,
  arms: in List[MatchArm],
  span: in Span,
): Unit {
  val st = unrefine(st0)
  match st {
    case TyError -> {
    }
    // scrutinee type unknown — already diagnosed
    case TyVar(_) -> {
    }
    // generic type parameter — cannot enumerate
    case TyPrim(pt) -> {
      match pt {
        case PtBool -> {
          val noNames: List[String] = newList()
          if not armsHaveCatchAll(arms, noNames) {
            var sawTrue = false
            var sawFalse = false
            var i = 0
            while i < arms.count {
              match arms[i].guard {
                case Some(_) -> {
                }
                case None -> match arms[i].pattern.kind {
                  case PLiteral(lit) -> match lit {
                    case LBool(b) -> if b { sawTrue = true } else { sawFalse = true }
                    case _ -> {
                    }
                  }
                  case PConstRef(cn) -> match tryResolveConstBool(tbl, cn) {
                    case Some(b) -> if b { sawTrue = true } else { sawFalse = true }
                    case None -> {
                    }
                  }
                  case _ -> {
                  }
                }
              }
              i = i + 1
            }
            if not (sawTrue and sawFalse) {
              val missing: List[String] = newList()
              if not sawTrue {
                missing.add("true")
              }
              if not sawFalse {
                missing.add("false")
              }
              diag.add(
                errorDiagnostic(
                  "T0016",
                  "non-exhaustive match on Bool: missing " + joinStrs(missing, ", ") + " (add a `_` arm or cover both)",
                  span
                )
              )
            }
          }
        }
        case _ -> if isUnboundedScalar(pt) {
          val noNames: List[String] = newList()
          if not armsHaveCatchAll(arms, noNames) {
            diag.add(errorDiagnostic("T0016", "non-exhaustive match on " + renderType(st) + ": add a wildcard `_` arm", span))
          }
        }
      }
    }
    case _ -> match finiteCaseNames(tbl, st) {
      case None -> {
      }
      case Some(caseNames) -> {
        if not armsHaveCatchAll(arms, caseNames) {
          val covered: List[String] = newList()
          var i = 0
          while i < arms.count {
            match arms[i].guard {
              case None -> collectCoveredCases(arms[i].pattern, caseNames, covered)
              case Some(_) -> {
              }
            }
            i = i + 1
          }
          val missing: List[String] = newList()
          var c = 0
          while c < caseNames.count {
            if not listContainsStr(covered, caseNames[c]) {
              missing.add(caseNames[c])
            }
            c = c + 1
          }
          if missing.count > 0 {
            diag.add(
              errorDiagnostic(
                "T0016",
                "non-exhaustive match on " + renderType(st) + ": missing case(s) " + joinStrs(missing, ", "),
                span
              )
            )
          }
        }
      }
    }
  }
  // not a finite-case type — skip
}

// A pattern that matches every value of whatever type it meets: `_`, or a
// lowercase binding.  Unlike `patternIsCatchAll` this does not take a bare
// capitalised name for a binding: below the scrutinee's own cases (whose names
// are known) a bare name may be a case of the payload's type
// (`Some(VInteger)`), and only the lowercase spelling is a binding by
// convention.
func patternSurelyIrrefutable(p: in Pattern, caseNames: in List[String]): Bool {
  match p.kind {
    case PWildcard -> true
    case PBinding(name, inner) -> match inner {
      case Some(ip) -> patternSurelyIrrefutable(ip, caseNames)
      case None -> name.length > 0 and not listContainsStr(caseNames, name) and
        isLowerAsciiStart(name)
    }
    case PParen(ip) -> patternSurelyIrrefutable(ip, caseNames)
    case POr(ps) -> {
      for q in ps {
        if patternSurelyIrrefutable(q, caseNames) {
          return true
        }
      }
      false
    }
    case _ -> false
  }
}

func isLowerAsciiStart(name: in String): Bool {
  val c = name.substring(0, 1)
  c.toUpper() != c or c == "_"
}

// The case a pattern fully covers on its own: a bare case name, or a
// constructor/record pattern whose sub-patterns match every payload.  `None`
// for a pattern that can fail on the payload (a literal sub-pattern), which
// leaves the case reachable by a later arm.
func caseFullyCoveredBy(p: in Pattern, caseNames: in List[String]): Option[String] {
  match p.kind {
    case PParen(ip) -> caseFullyCoveredBy(ip, caseNames)
    case PBinding(name, inner) -> match inner {
      case Some(ip) -> caseFullyCoveredBy(ip, caseNames)
      case None -> if listContainsStr(caseNames, name) {
        Some(value = name)
      } else {
        None
      }
    }
    case PConstructor(head, args) -> {
      if head.segments.count == 0 {
        return None
      }
      val nm = head.segments[head.segments.count - 1]
      if not listContainsStr(caseNames, nm) {
        return None
      }
      for a in args {
        if not patternSurelyIrrefutable(a, caseNames) {
          return None
        }
      }
      Some(value = nm)
    }
    case _ -> None
  }
}

// T0196: a `match` arm that no value can reach — it follows an unguarded
// catch-all arm (`case _`, a bare binding), or every case it names was already
// matched whole by earlier unguarded arms.  The earlier arm wins at run time,
// so the later arm is silently dead code (#7916).
func checkUnreachableArms(tbl: in SymbolTable, diag: in List[Diagnostic], st0: in Type, arms: in List[MatchArm]): Unit {
  val st = unrefine(st0)
  match st {
    case TyError -> {
      return
    }
    case TyVar(_) -> {
      return
    }
    case _ -> ()
  }
  val caseNames = match finiteCaseNames(tbl, st) { case Some(ns) -> ns; case None -> newList() }
  val covered: List[String] = newList()
  var catchAll = -1
  var i = 0
  while i < arms.count {
    val arm = arms[i]
    if catchAll >= 0 {
      diag.add(
        errorDiagnostic(
          "T0196",
          "unreachable match arm: the earlier catch-all arm at line " + toString(arms[catchAll].pattern.span.startPos.line) +
            " matches every value first",
          arm.pattern.span
        )
      )
    } else {
      val orAlts: List[Pattern] = match arm.pattern.kind { case POr(ps) -> ps; case _ -> newList() }
      if orAlts.count == 0 {
        match caseFullyCoveredBy(arm.pattern, caseNames) {
          case Some(nm) -> if listContainsStr(covered, nm) {
            diag.add(
              errorDiagnostic(
                "T0196",
                "unreachable match arm: case '" + nm + "' is already matched by an earlier arm",
                arm.pattern.span
              )
            )
          }
          case None -> ()
        }
      }
      match arm.guard {
        case Some(_) -> ()
        case None -> {
          if patternSurelyIrrefutable(arm.pattern, caseNames) {
            catchAll = i
          }
          if orAlts.count > 0 {
            for alt in orAlts {
              match caseFullyCoveredBy(alt, caseNames) {
                case Some(nm) -> if not listContainsStr(covered, nm) { covered.add(nm) }
                case None -> ()
              }
            }
          } else {
            match caseFullyCoveredBy(arm.pattern, caseNames) {
              case Some(nm) -> if not listContainsStr(covered, nm) { covered.add(nm) }
              case None -> ()
            }
          }
        }
      }
    }
    i = i + 1
  }
}

// True when `e` is an integer literal written WITHOUT a type suffix
// (`0`, `42`, `1_000` — not `0i64`).  Such a literal defaults to `Int`
// but, per the language reference (integer literals "follow Rust's
// syntax"), adopts whatever concrete integer type the context requires
// (#2514).
func isUnsuffixedIntLit(e: in Expr): Bool {
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LInt(_, sfx, _) -> match sfx { case NoIntSuffix -> true; case _ -> false }
      case _ -> false
    }
    // A negated literal (`-1`) adopts the other operand's integer type like
    // the literal itself (D-progress-969).
    case EPrefix(op, operand) -> match op { case PreNeg -> isUnsuffixedIntLit(operand); case _ -> false }
    case EParen(inner) -> isUnsuffixedIntLit(inner)
    case _ -> false
  }
}

// True when `t` (after stripping range refinements) is a concrete integer
// primitive — the set an unsuffixed literal may adopt.
func isConcreteIntType(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt {
      case PtByte -> true
      case PtInt -> true
      case PtLong -> true
      case PtUInt -> true
      case PtULong -> true
      case PtNat -> true
      case _ -> false
    }
    case _ -> false
  }
}

func longFitsInt(v: in Long): Bool {
  v >= 0i64 - 2147483648i64 and v <= 2147483647i64
}

// True when the integer value `v` is representable in the integer type `t`
// (after stripping range refinements; the refinement's own bounds are T0015's
// job).  `ULong`'s upper half cannot arise: a literal's value is a `Long`.
pub func intValueFitsType(v: in Long, t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt {
      case PtByte -> v >= 0i64 and v <= 255i64
      case PtInt -> longFitsInt(v)
      case PtLong -> true
      case PtUInt -> v >= 0i64 and v <= 4294967295i64
      case PtULong -> v >= 0i64
      case PtNat -> v >= 0i64
      case _ -> true
    }
    case _ -> true
  }
}

// The value of an integer literal written without a suffix, seen through
// parentheses and one unary minus (`-2147483648` parses as a negated
// `2147483648`).  `None` for anything else.
pub func unsuffixedIntLiteralValue(e: in Expr): Option[Long] {
  match e.kind {
    case EParen(inner) -> unsuffixedIntLiteralValue(inner)
    case ELiteral(lit) -> match lit {
      case LInt(v, sfx, _) -> match sfx { case NoIntSuffix -> Some(value = v); case _ -> None }
      case _ -> None
    }
    case EPrefix(op, operand) -> match op {
      case PreNeg -> match operand.kind {
        case ELiteral(lit) -> match lit {
          case LInt(v, sfx, _) -> match sfx {
            case NoIntSuffix -> Some(
              value = 0i64 -
                v
            )
            case _ -> None
          }
          case _ -> None
        }
        case EParen(_) -> match unsuffixedIntLiteralValue(operand) {
          case Some(v) -> Some(value = 0i64 - v)
          case None -> None
        }
        case _ -> None
      }
      case _ -> None
    }
    case _ -> None
  }
}

// True when `t` is exactly the default literal type `Int` (the type an
// unsuffixed integer literal infers to before context adjustment).
func isPlainInt(t: in Type): Bool {
  match t {
    case TyPrim(pt) -> match pt { case PtInt -> true; case _ -> false }
    case _ -> false
  }
}

// Rust-style integer-literal inference: when `e` is an unsuffixed integer
// literal whose default type is `Int`, let it adopt a concrete `expected`
// integer type (e.g. `Long` from `someLong <= 0`, a return type, a binding
// annotation, or a parameter type).  Returns the adjusted type, or `actual`
// unchanged when no coercion applies.
//
// The literal's value must fit `expected` (#7346): `b == 300` with `b: Byte`
// keeps the literal an `Int` rather than adopting a `Byte` it cannot be.  A
// literal already typed `Long` because it is too large for `Int` may still
// adopt `ULong`/`UInt` when it fits.
func adoptIntLiteralType(e: in Expr, actual: in Type, expected: in Type): Type {
  if isUnsuffixedIntLit(e) and (isPlainInt(actual) or isPlainLong(actual)) and isConcreteIntType(expected) {
    match unsuffixedIntLiteralValue(e) {
      case Some(v) -> {
        if intValueFitsType(v, expected) {
          return expected
        }
      }
      case None -> ()
    }
  }
  actual
}

// The literal suffix of `t` when it is `Byte`, `UInt` or `ULong` (after
// stripping range refinements): the integer types no `Int` widens to, so an
// unsuffixed literal can initialise one only by adopting it.
func unsignedLiteralSuffix(t: in Type): Option[IntSuffix] {
  match unrefine(t) {
    case TyPrim(pt) -> match pt {
      case PtByte -> Some(value = U8)
      case PtUInt -> Some(value = U32)
      case PtULong -> Some(value = U64)
      case _ -> None
    }
    case _ -> None
  }
}

func isSomeSuffix(o: in Option[IntSuffix]): Bool {
  match o {
    case Some(_) -> true
    case None -> false
  }
}

// An unsuffixed integer literal where a `Byte`, `UInt` or `ULong` is required
// (a binding, an assignment or compound assignment, an argument, a field, a
// return value, a list element) is of that type when its value fits it
// (docs/01 §2.1, #7841).  The site is recorded so
// `Lyric.Mono.desugarCheckedFile` gives the literal the matching suffix,
// which every backend sizes the constant by.  A literal that does not fit
// keeps its own type, and the caller reports T0015 or a type mismatch.
func adoptUnsignedIntLiteral(tbl: in SymbolTable, e: in Expr, actual: in Type, expected: in Type): Type {
  val adopted = adoptIntLiteralType(e, actual, expected)
  if isPlainInt(adopted) or isPlainLong(adopted) {
    return actual
  }
  match unsignedLiteralSuffix(expected) {
    case Some(sfx) -> {
      val key = recordCopySiteKey(e.span)
      if tbl.argConversionSites.containsKey(key) {
        tbl.argConversionSites.remove(key)
      }
      tbl.argConversionSites.add(
        key,
        ArgConversionSite(method = intLiteralSiteMethod(sfx), startOffset = e.span.startPos.offset)
      )
    }
    case None -> ()
  }
  adopted
}

// True when `e` is a float literal written without a suffix (`1.5`, not
// `1.5f32`), seen through parentheses and a unary minus.  Such a literal is a
// `Double` unless its context requires a `Float` (D155).
func isUnsuffixedFloatLit(e: in Expr): Bool {
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LFloat(_, sfx, _) -> match sfx { case NoFloatSuffix -> true; case _ -> false }
      case _ -> false
    }
    case EPrefix(op, operand) -> match op { case PreNeg -> isUnsuffixedFloatLit(operand); case _ -> false }
    case EParen(inner) -> isUnsuffixedFloatLit(inner)
    case _ -> false
  }
}

func isFloatType(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtFloat -> true; case _ -> false }
    case _ -> false
  }
}

func isPlainDouble(t: in Type): Bool {
  match t {
    case TyPrim(pt) -> match pt { case PtDouble -> true; case _ -> false }
    case _ -> false
  }
}

// An unsuffixed float literal where a `Float` is required (a binding, an
// argument, a field, a return, a default, or the other operand of a `Float`
// operator) is a `Float` (D155).  The site is recorded so
// `Lyric.Mono.desugarCheckedFile` rewrites the literal to its `f32` form,
// which every backend lowers as binary32.  Returns `expected` when the
// literal adopts it, `actual` otherwise.
pub func adoptFloatLiteralType(tbl: in SymbolTable, e: in Expr, actual: in Type, expected: in Type): Type {
  if isUnsuffixedFloatLit(e) and isPlainDouble(actual) and isFloatType(expected) {
    recordFloatLiteralSite(tbl, e)
    return expected
  }
  actual
}

func recordFloatLiteralSite(tbl: in SymbolTable, e: in Expr): Unit {
  val key = recordCopySiteKey(e.span)
  if tbl.argConversionSites.containsKey(key) {
    tbl.argConversionSites.remove(key)
  }
  tbl.argConversionSites.add(
    key,
    ArgConversionSite(method = floatLiteralSiteMethod(), startOffset = e.span.startPos.offset)
  )
}

func isPlainLong(t: in Type): Bool {
  match t {
    case TyPrim(pt) -> match pt { case PtLong -> true; case _ -> false }
    case _ -> false
  }
}

// #7345: is `target` reachable from `startPkg`: one of its own imports, or
// a package one of them re-exports (`pub use`), transitively?  A package an
// import merely imports is not reachable (docs/70 §4.3, D311): the kernel/host
// idiom (`Std.Collections` and `Std.CollectionsHost`) is a re-export.
func symTableImportReachable(tbl: in SymbolTable, startPkg: in String, target: in String): Bool {
  for imp in symTablePackageImportsOf(tbl, startPkg) {
    if imp == target or symTableReexportClosure(tbl, imp).contains(target) {
      return true
    }
  }
  false
}

// #7345: a bare, uppercase-starting single-segment name used in method-call
// position (`RestClient.create(...)`, docs/49's dotted type-associated-
// function convention) is deliberately left untyped by `resolveExprPath` —
// it names a TYPE, never a value, and the actual dispatch (which function,
// in which package) is owned by codegen, which resolves it by walking the
// file's own import closure. That leniency must not swallow the case where
// the name is not reachable from this file's imports at all: without this
// check, a real stdlib type from a package the file never imported
// (`Std.Rest.RestClient`) silently degraded to a backend-specific runtime
// failure instead of a compile-time error (#7345).
//
// Under the file's import rule (docs/01 §9.2, D141) `symTableTryFindOne`
// already hides a name the imports do not make visible, so the usual report
// comes from the `None` arm: the name exists but is hidden, and the T0020
// carries `symTableHiddenImportHint`'s advice.  The `Some` arm covers a scope
// with no import rule installed (an imported package's own signatures): it
// still reports a type declared by another package that the import closure
// cannot reach (`symTableImportReachable`), `Std.Core` excepted.  A check
// with no package scope at all (`curPkg == ""`, the flat `checkWithImports`
// shim) never diagnoses: it has no import list to test against.
func checkUnimportedTypeReceiver(
  tbl: in SymbolTable,
  sc: in Scope,
  name: in String,
  span: in Span,
  diag: in List[Diagnostic],
): Unit {
  val curPkg = symTableScopePkg(tbl)
  if curPkg.length == 0 {
    return
  }
  match scopeTryFind(sc, name) {
    case Some(_) -> {
      return
    }
    case None -> ()
  }
  match symTableTryFindOne(tbl, name) {
    case Some(sym) -> {
      if not symbolIsType(sym) {
        return
      }
      symTableNoteBareUse(tbl, sym, span)
      if sym.originPackage.length == 0 or sym.originPackage == "Std.Core" or sym.originPackage == curPkg {
        return
      }
      // #7499: a package-private type is not nameable from another package
      // whether or not that package is imported, so this is T0097 (adding an
      // import cannot fix it), checked before reachability.
      if symbolIsPackagePrivateBinding(sym) {
        checkImportedVisibility(tbl, sym, span, diag)
        return
      }
      // An extern-type binding (no visibility modifier) keeps its
      // kernel-boundary resolution (docs/01 §3.1) and is not diagnosed here.
      val hasVisibility = match sym.visibility { case Some(_) -> true; case None -> false }
      if not hasVisibility or symTableImportReachable(tbl, curPkg, sym.originPackage) {
        return
      }
      diag.add(
        errorDiagnostic(
          "T0020",
          "unknown name '" + name + "' (declared in " + sym.originPackage + "; add `import " + sym.originPackage + "`)",
          span
        )
      )
    }
    case None -> {
      // Hidden by the file's import rule (docs/01 §9.2).  A package-private
      // type stays T0097 (#7499): no import would make it nameable.
      for cand in symTableTryFindAll(tbl, name) {
        if symbolIsType(cand) and cand.originPackage != curPkg and symbolIsPackagePrivateBinding(cand) {
          checkImportedVisibility(tbl, cand, span, diag)
          return
        }
      }
      val hint = symTableHiddenImportHint(tbl, name)
      if hint.length > 0 {
        diag.add(errorDiagnostic("T0020", "unknown name '" + name + "'" + hint, span))
      } else if not receiverNamesPackageOrParam(tbl, sc, name) {
        // Nothing any loaded package declares, and no package, alias or
        // generic parameter of that name: no backend can resolve it either
        // (docs/70 §5.3).
        diag.add(errorDiagnostic("T0020", "unknown name '" + name + "'", span))
      }
    }
  }
}

// Whether an uppercase receiver that names no symbol still names something a
// qualified call can go through: a primitive type (`Int.shl(k, 2)`), a
// generic parameter in scope, `Self`, a
// loaded package (by its full path, its first segment as in `Std.Http.GET`, or
// its last segment, the implicit alias of `import A.B`), an import alias, or an
// `extern package` block.
func receiverNamesPackageOrParam(tbl: in SymbolTable, sc: in Scope, name: in String): Bool {
  if name == "Self" {
    return true
  }
  match primFromString(name) {
    case Some(_) -> return true
    case None -> ()
  }
  for g in sc.genericNames {
    if g == name {
      return true
    }
  }
  if symTablePackageHasAnySymbol(tbl, name) or symTablePackageHasAnyExternBlockMember(tbl, name) {
    return true
  }
  val suffix = "." + name
  val prefix = name + "."
  for pkg in mapKeys(tbl.symbolPackages) {
    if pkg.endsWith(suffix) or pkg.startsWith(prefix) {
      return true
    }
  }
  for alias in mapValues(tbl.importAliases) {
    if alias == name {
      return true
    }
  }
  false
}

// #7499: a symbol whose cross-package use `checkImportedVisibility` rejects
// (T0097) — declared by another package with no `pub`/`internal` modifier and
// not an FFI host binding (extern types/packages sit outside the visibility
// tiers, docs/01 §3.1).
func symbolIsPackagePrivateBinding(sym: in Symbol): Bool {
  if not sym.isImported {
    return false
  }
  val isExternBinding = match sym.kind { case DKExternType(_, _) -> true; case DKExtern(_) -> true; case _ -> false }
  if isExternBinding {
    return false
  }
  match sym.visibility {
    case Some(_) -> false
    case None -> true
  }
}

// #7548: is `pkg` nameable from `curPkg`?  A qualified reference names a
// package the file imports itself, in any form (docs/70 §4.3, D311): one an
// import merely imports, or re-exports, cannot be named.  Shared by every
// package-qualified reachability check (expression paths, type paths,
// pattern heads).
func qualifiedPkgReachable(tbl: in SymbolTable, curPkg: in String, pkg: in String): Bool {
  symTableScopeAllows(tbl, pkg)
}

// #7548: T0020 reporter for a qualified reference whose ACTUAL declaring
// package the caller already knows by other means (rather than by
// splitting the reference's own segments into a package prefix — see
// `unionCaseSymbolForScrutinee`, whose caller this exists for: a pattern
// head is always flattened to one `EPath` regardless of depth, and the
// package/type-name boundary within `Pkg.Sub.Union.Case` is only knowable
// once the scrutinee's own union/enum has told us which segments are
// which — `checkQualifiedPackageRef`'s "everything but the last segment is
// the package" assumption does not hold for a pattern head the way it
// does for `Pkg.Sub.func(...)`). Same reachability test, `Std.Core`/
// same-package exemptions, and message shape as every other T0020 site
// here.
func reportUnimportedQualifiedPackage(
  tbl: in SymbolTable,
  curPkg: in String,
  pkg: in String,
  member: in String,
  span: in Span,
  diag: in List[Diagnostic],
): Bool {
  if curPkg.length == 0 or pkg.length == 0 or pkg == curPkg or pkg == "Std.Core" {
    return false
  }
  if not qualifiedPkgReachable(tbl, curPkg, pkg) {
    addDiagnosticOnce(
      diag,
      errorDiagnostic(
        "T0020",
        "unknown name '" + pkg + "." + member + "' (package " + pkg + " is not imported; add `import " + pkg + "`)",
        span
      )
    )
    return true
  }
  symTableNoteQualifiedUse(tbl, pkg, member, span, true)
  false
}

// Add `d` unless an identical diagnostic (code, message, span) is already
// present: the package-qualified checks below run from both the call-callee
// and the plain member-access paths, which can reach the same node.
func addDiagnosticOnce(diag: in List[Diagnostic], d: in Diagnostic): Unit {
  val key = recordCopySiteKey(d.span)
  var i = 0
  while i < diag.count {
    val x = diag[i]
    if x.code == d.code and x.message == d.message and recordCopySiteKey(x.span) == key {
      return
    }
    i = i + 1
  }
  diag.add(d)
}

// True when the current file imports `pkg` (`import pkg` or `import pkg as A`,
// whose uses the alias rewriter spells with the full path) yet the checker
// holds no declaration of it: no dependency provides the package (#7989).  An
// `extern package` path and a package known only by extern-block members are
// provided, and so is the standard library, which the toolchain supplies
// whether or not a dependency or the caller loaded its sources.
func importedPackageMissing(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  pkg: in String,
  name: in String,
): Bool {
  if pkg.startsWith("Std.") or pkg == "Std" or not symTableScopeAllows(tbl, pkg) {
    return false
  }
  if symTablePackageHasAnySymbol(tbl, pkg) or symTablePackageHasAnyExternBlockMember(tbl, pkg) or symTableIsExternPathPackage(tbl, pkg) {
    return false
  }
  for c in gatherOverloadCandidates(sigs, byNameSigKey(name)) {
    if pkgMatchesQualifier(c.originPackage, pkg) {
      return false
    }
  }
  true
}

// #7495: `pkgSegs` spells a package-qualified reference's qualifier
// (`Std.Rest` in `Std.Rest.RestClient.create(url)`), `member` the segment
// after it. docs/01 §9.2: apart from the `Std.Core` prelude, a name is usable
// only when its package is reachable from the file's own imports (directly
// or through the imported packages' own imports — the kernel/host re-export
// idiom). `Lyric.Pipeline` loads every stdlib package's signatures whatever
// the file imports, so without this a qualified path into an unimported
// package type-checked cleanly and whether it then built depended on the
// backend and on what the build bundled (D-progress-1011). A reachable
// qualifier naming another package's package-private type is T0097 (#7499).
//
// Only fires when the qualifier is a package the checker actually loaded
// (`symTablePackageHasAnySymbol` / an `extern package` block), so a deferred
// host path (`System.Console.WriteLine`) is untouched, and never when the
// root segment is a local or a symbol already in scope (a field chain that
// merely spells a package name). A check with no package scope (`curPkg ==
// ""`) never diagnoses, as for `checkUnimportedTypeReceiver`.
func checkQualifiedPackageRef(
  tbl: in SymbolTable,
  sc: in Scope,
  pkgSegs: in List[String],
  member: in String,
  span: in Span,
  diag: in List[Diagnostic],
): Unit {
  val curPkg = symTableScopePkg(tbl)
  if curPkg.length == 0 or pkgSegs.count == 0 {
    return
  }
  val pkg = modulePathJoin(pkgSegs)
  if pkg == curPkg or pkg == "Std.Core" or symTableIsExternPathPackage(tbl, pkg) {
    return
  }
  if not (symTablePackageHasAnySymbol(tbl, pkg) or symTablePackageHasAnyExternBlockMember(tbl, pkg)) {
    return
  }
  // `member` may be the next segment of a deeper package path rather than a
  // member of `pkg`: the member-access walk visits `Pkg.Sub` inside
  // `Pkg.Sub.value`, and when the parent `Pkg` is itself a loaded package
  // (a project's root package once every project package is registered,
  // #7583) that inner node would otherwise be reported as `Pkg` unimported
  // even though the file imports `Pkg.Sub`.  The enclosing node checks the
  // real package `Pkg.Sub`.  Only when `Pkg` declares no symbol of that name,
  // so a genuine member reference is still checked.
  val deeperPkg = pkg + "." + member
  if symTablePackageHasAnySymbol(tbl, deeperPkg) or symTablePackageHasAnyExternBlockMember(tbl, deeperPkg) {
    match symTableTryFindInPackage(tbl, pkg, member) {
      case Some(_) -> ()
      case None -> {
        return
      }
    }
  }
  match scopeTryFind(sc, pkgSegs[0]) {
    case Some(_) -> {
      return
    }
    case None -> ()
  }
  match symTableTryFindOne(tbl, pkgSegs[0]) {
    case Some(rootSym) -> {
      // A single-segment qualifier that also names a symbol is a type
      // receiver, owned by `checkUnimportedTypeReceiver`; a deeper chain
      // rooted at a symbol in scope is a value's field chain.
      if pkgSegs.count == 1 or rootSym.originPackage == curPkg or symTableScopeAllows(tbl, rootSym.originPackage) {
        return
      }
    }
    case None -> ()
  }
  // #7799: a value or call written with a package's full path needs that
  // package imported by the file itself.  The kernel/host re-export idiom
  // (`Std.Collections` importing `Std.CollectionsHost`) is reached through the
  // facade's qualifier (`Coll.newList()`), not by naming the host package:
  // the backends resolve a qualified callee from the file's own imports, so
  // accepting a transitively reachable path here was a T0115 on MSIL and
  // accepted on the JVM.
  if not symTableScopeAllows(tbl, pkg) {
    addDiagnosticOnce(
      diag,
      errorDiagnostic(
        "T0020",
        "unknown name '" + pkg + "." + member + "' (package " + pkg + " is not imported; add `import " + pkg + "`)",
        span
      )
    )
    return
  }
  symTableNoteQualifiedUse(tbl, pkg, member, span, false)
  match symTableTryFindInPackage(tbl, pkg, member) {
    case Some(sym) -> {
      if symbolIsType(sym) and symbolIsPackagePrivateBinding(sym) {
        val vd: List[Diagnostic] = newList()
        checkImportedVisibility(tbl, sym, span, vd)
        var i = 0
        while i < vd.count {
          addDiagnosticOnce(diag, vd[i])
          i = i + 1
        }
      }
    }
    case None -> ()
  }
}

// `checkQualifiedPackageRef` for a member access `recv.member` whose receiver
// is a pure dotted chain (`Pkg.Sub.member`); a no-op for any other receiver.
func checkQualifiedMemberRef(
  tbl: in SymbolTable,
  sc: in Scope,
  recv: in Expr,
  member: in String,
  span: in Span,
  diag: in List[Diagnostic],
): Unit {
  val segs: List[String] = newList()
  if flattenCalleePathSegs(recv, segs) {
    checkQualifiedPackageRef(tbl, sc, segs, member, span, diag)
  }
}

// `NativePtr[arg]` (every target) or `NativeWeak[arg]` (a `--target native`
// check), from `SymbolTable.nativeIntrinsicTypes`; None when not registered.
func nativeIntrinsicType(tbl: in SymbolTable, name: in String, arg: in Type): Option[Type] {
  match mapGet(tbl.nativeIntrinsicTypes, name) {
    case Some(tid) -> {
      val targs: List[Type] = newList()
      targs.add(arg)
      Some(value = TyUser(id = tid, name = name, args = targs))
    }
    case None -> None
  }
}

// The type of a call to an FFI intrinsic function (docs/01 §11.6):
// `nativeNullPtr()` on every target, `nativeAddrOf`/`NativeWeak` in a
// `--target native` check; None when `fn` names none of these.
// `Lyric.LlvmCodegen` intercepts these names before any name resolution:
// `nativeNullPtr()` is the C NULL pointer as a `NativePtr[Byte]`,
// `nativeAddrOf(x)` the address of the local `x: T` as a `NativePtr[T]`, and
// `NativeWeak(x)` a weak reference to `x: T`.  Where they may appear is the
// mode checker's N0100.
func nativeIntrinsicCallType(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn: in Expr,
  args: in List[CallArg],
  span: in Span,
): Option[Type] {
  if tbl.nativeIntrinsicTypes.count == 0 {
    return None
  }
  val name = match fn.kind {
    case EPath(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
    case _ -> ""
  }
  if name == "nativeLoadByte" or name == "nativeStoreByte" {
    return nativeByteAccessType(sc, tbl, sigs, diag, name, args, span)
  }
  if name == "nativeKeepCallback" or name == "nativeReleaseCallback" {
    return nativeCallbackPinType(sc, tbl, sigs, diag, name, args, span)
  }
  if name != "nativeNullPtr" and name != "nativeAddrOf" and name != "NativeWeak" {
    return None
  }
  // `nativeAddrOf` and `NativeWeak` lower only on the native target, which
  // registers `NativeWeak`; elsewhere they are unknown names (D158).
  if name != "nativeNullPtr" and not checkingForNative(tbl) {
    return None
  }
  val argTypes: List[Type] = newList()
  for a in args {
    argTypes.add(inferExpr(sc, tbl, sigs, diag, callArgExpr(a)))
  }
  val arity = if name == "nativeNullPtr" { 0 } else { 1 }
  if args.count != arity {
    diag.add(errorDiagnostic("T0042", "expected " + toString(arity) + " argument(s), got " + toString(args.count), span))
    return Some(value = TyError)
  }
  if name == "nativeNullPtr" {
    return nativeIntrinsicType(tbl, "NativePtr", TyPrim(pt = PtByte))
  }
  if name == "nativeAddrOf" {
    return nativeIntrinsicType(tbl, "NativePtr", argTypes[0])
  }
  nativeIntrinsicType(tbl, "NativeWeak", argTypes[0])
}

// The root extern type (`java.lang.Object` / `System.Object`) bound in this
// compilation, as the type `externAsObject` produces; None when no
// `extern type` / `import extern` names it.  Extern types share one id per CLR
// target (#2394), so every spelling of the root is the same type.
func rootExternObjectType(tbl: in SymbolTable): Option[Type] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKExternType(tid, d) -> if d.clrName == "java.lang.Object" or d.clrName == "System.Object" {
        return Some(value = TyUser(id = tid, name = d.name, args = newList()))
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

// `externAsObject(x)` is the explicit upcast from an extern type to the root
// extern type (D212): extern types are unrelated to each other in Lyric's type
// system, but the host's `Object` is a supertype of every one, so a kernel that
// stores extern values in a `List[JObject]` or passes them to an `Object`
// parameter says so here.  The operand must be an extern type; the result is
// the root extern type.  Where it may appear is the mode checker's N0103.
// None when `fn` is not a call of `externAsObject`.
func externUpcastCallType(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn: in Expr,
  args: in List[CallArg],
  span: in Span,
): Option[Type] {
  val isUpcast = match fn.kind {
    case EPath(path) -> path.segments.count == 1 and path.segments[0] == "externAsObject"
    case _ -> false
  }
  if not isUpcast {
    return None
  }
  val argTypes: List[Type] = newList()
  for a in args {
    argTypes.add(inferExpr(sc, tbl, sigs, diag, callArgExpr(a)))
  }
  if args.count != 1 {
    diag.add(errorDiagnostic("T0042", "expected 1 argument(s), got " + toString(args.count), span))
    return Some(value = TyError)
  }
  match argTypes[0] {
    case TyError -> return Some(value = TyError)
    case TyUser(id, name, _) -> if not symTableIsExternTypeId(tbl, id) {
      diag.add(
        errorDiagnostic(
          "T0205",
          "externAsObject upcasts an extern type to the host's root object type, but '" + name + "' is not an extern type",
          span
        )
      )
      return Some(value = TyError)
    }
    case other -> {
      diag.add(
        errorDiagnostic(
          "T0205",
          "externAsObject upcasts an extern type to the host's root object type, but the operand is a " + renderType(other),
          span
        )
      )
      return Some(value = TyError)
    }
  }
  if checkingForNative(tbl) {
    diag.add(
      errorDiagnostic(
        "T0206",
        "externAsObject exists on --target dotnet and --target jvm only: native has no host object type, and its kernels bind C symbols with `extern func`",
        span
      )
    )
    return Some(value = TyError)
  }
  match rootExternObjectType(tbl) {
    case Some(t) -> Some(value = t)
    case None -> {
      diag.add(
        errorDiagnostic(
          "T0206",
          "externAsObject needs the root object type in scope: declare `extern type Object = \"java.lang.Object\"` (JVM) or `\"System.Object\"` (.NET)",
          span
        )
      )
      Some(value = TyError)
    }
  }
}

// Whether this check is for a `--target native` build: only then are the native
// intrinsic types (`NativeWeak`) registered.
func checkingForNative(tbl: in SymbolTable): Bool = tbl.nativeIntrinsicTypes.containsKey("NativeWeak")

// A closure literal with one parameter whose type is written.
func isAnnotatedPointerLambda(e: in Expr): Bool {
  match e.kind {
    case ELambda(lparams, _) -> {
      if lparams.count != 1 {
        return false
      }
      match lparams[0].ty {
        case Some(_) -> true
        case None -> false
      }
    }
    case _ -> false
  }
}

// `b.withPointer(f)` and `b.withMutPointer(f)` on a `buffer[T]` (D187, docs/67
// §4.4): lend the buffer's packed elements to `f` as a `NativePtr[T]` for the
// duration of the call, and give back `f`'s result.  `withMutPointer` first makes
// the storage unique, so `b` must be a writable place.  Native only: the other
// targets have no address to lend.  The closure writes its parameter's type
// (`{ p: NativePtr[Byte] -> ... }`), which is what confines the call to
// `@unsafe_ffi` code and kernels (N0100).  None when `fn` is not one of these
// calls on a buffer.
func bufferPointerCallType(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn: in Expr,
  args: in List[CallArg],
  span: in Span,
): Option[Type] {
  var recvOpt: Option[Expr] = None
  var name = ""
  match fn.kind {
    case EMember(r, n) -> {
      if n == "withPointer" or n == "withMutPointer" {
        recvOpt = Some(value = r)
        name = n
      }
    }
    case _ -> ()
  }
  val recv = match recvOpt { case Some(r) -> r; case None -> return None }
  val scratch: List[Diagnostic] = newList()
  val rt = inferExpr(sc, tbl, sigs, scratch, recv)
  val elem = match bufferElementType(rt) { case Some(t) -> t; case None -> return None }
  val _ = inferExpr(sc, tbl, sigs, diag, recv)
  exemptArrayCopy(tbl, recv)
  if not bufferReceiverIsStable(recv) {
    diag.add(
      errorDiagnostic(
        "T0174",
        "a buffer is lent through a variable, a field path or an element of one: bind the buffer to a `val` first",
        recv.span
      )
    )
  }
  if not checkingForNative(tbl) {
    diag.add(
      errorDiagnostic("T0175", name + " lends a buffer's address to C code and exists only on --target native", span)
    )
    return Some(value = TyError)
  }
  if args.count != 1 {
    diag.add(errorDiagnostic("T0042", "expected 1 argument(s), got " + toString(args.count), span))
    return Some(value = TyError)
  }
  val argE = callArgExpr(args[0])
  if not isAnnotatedPointerLambda(argE) {
    diag.add(
      errorDiagnostic(
        "T0176",
        name + " takes a closure that writes its pointer parameter's type, `{ p: NativePtr[T] -> ... }`",
        argE.span
      )
    )
    return Some(value = TyError)
  }
  if name == "withMutPointer" and not arrayPlaceWritable(sc, tbl, sigs, recv) {
    diag.add(
      errorDiagnostic(
        "T0157",
        "withMutPointer writes the buffer, so it is called on a `var` local, an `out`/`inout` parameter or a `var` field",
        recv.span
      )
    )
  }
  val ptrTy = match nativeIntrinsicType(tbl, "NativePtr", elem) {
    case Some(t) -> t
    case None -> return Some(value = TyError)
  }
  val params: List[Type] = newList()
  params.add(ptrTy)
  val want = TyFunction(params = params, ret = TyError, isAsync = false)
  val got = inferExprExpected(sc, tbl, sigs, diag, argE, want)
  match got {
    case TyFunction(ps, ret, _) -> {
      val siteKey = recordCopySiteKey(span)
      if not tbl.bufferPointerSites.containsKey(siteKey) {
        match typeExprForRefWithVars(tbl, ret, span) {
          case Some(rte) -> tbl.bufferPointerSites.add(siteKey, rte)
          case None -> diag.add(
            errorDiagnostic(
              "T0177",
              name + ": the closure's result type " + renderType(ret) +
                " cannot be written out here; return a scalar, a record or a buffer",
              argE.span
            )
          )
        }
      }
      if ps.count == 1 and not typeEquiv(ps[0], ptrTy) {
        diag.add(
          errorDiagnostic(
            "T0043",
            name + ": the closure's parameter must be a " + renderType(ptrTy) + ", got " + renderType(ps[0]),
            argE.span
          )
        )
      }
      Some(value = ret)
    }
    case _ -> Some(value = TyError)
  }
}

// `nativeLoadByte(p, offset): Byte` and `nativeStoreByte(p, offset, value)`
// read and write the byte at `p + offset` in C memory, on every target
// (D161): `p` is a `NativePtr[Byte]`, `offset` an `Int` or `Long`, `value`
// a `Byte`.  Placement is the mode checker's N0100, as for `nativeNullPtr`.
func nativeByteAccessType(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  name: in String,
  args: in List[CallArg],
  span: in Span,
): Option[Type] {
  val arity = if name == "nativeLoadByte" { 2 } else { 3 }
  val argTypes: List[Type] = newList()
  for a in args {
    argTypes.add(inferExpr(sc, tbl, sigs, diag, callArgExpr(a)))
  }
  if args.count != arity {
    diag.add(errorDiagnostic("T0042", "expected " + toString(arity) + " argument(s), got " + toString(args.count), span))
    return Some(value = TyError)
  }
  val ptrTy = match nativeIntrinsicType(tbl, "NativePtr", TyPrim(pt = PtByte)) {
    case Some(t) -> t
    case None -> return None
  }
  if not argSatisfiesParam(tbl, ptrTy, argTypes[0]) {
    diag.add(
      errorDiagnostic("T0043", name + ": the pointer argument must be a NativePtr[Byte]", callArgExpr(args[0]).span)
    )
  }
  if not argSatisfiesParam(tbl, TyPrim(pt = PtLong), argTypes[1]) {
    diag.add(errorDiagnostic("T0043", name + ": the offset must be an Int or a Long", callArgExpr(args[1]).span))
  }
  if name == "nativeStoreByte" {
    if not argSatisfiesParam(tbl, TyPrim(pt = PtByte), argTypes[2]) {
      diag.add(errorDiagnostic("T0043", name + ": the value must be a Byte", callArgExpr(args[2]).span))
    }
    return Some(value = TyPrim(pt = PtUnit))
  }
  Some(value = TyPrim(pt = PtByte))
}

// `nativeKeepCallback(f): NativePtr[Byte]` pins the closure `f` as the C
// userdata pointer of a callback that outlives the call registering it, on
// every target, until `nativeReleaseCallback(p)` unpins it (D229).  `f` is a
// function value of any type; `p` a `NativePtr[Byte]`.  Placement is the mode
// checker's N0100, as for `nativeNullPtr`.
func nativeCallbackPinType(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  name: in String,
  args: in List[CallArg],
  span: in Span,
): Option[Type] {
  val argTypes: List[Type] = newList()
  for a in args {
    argTypes.add(inferExpr(sc, tbl, sigs, diag, callArgExpr(a)))
  }
  if args.count != 1 {
    diag.add(errorDiagnostic("T0042", "expected 1 argument(s), got " + toString(args.count), span))
    return Some(value = TyError)
  }
  val ptrTy = match nativeIntrinsicType(tbl, "NativePtr", TyPrim(pt = PtByte)) {
    case Some(t) -> t
    case None -> return None
  }
  if name == "nativeKeepCallback" {
    match unrefine(argTypes[0]) {
      case TyFunction(_, _, _) -> ()
      case TyError -> ()
      case _ -> diag.add(
        errorDiagnostic(
          "T0043",
          name + ": the argument must be a closure (a function value), got " + renderType(argTypes[0]),
          callArgExpr(args[0]).span
        )
      )
    }
    return Some(value = ptrTy)
  }
  if not argSatisfiesParam(tbl, ptrTy, argTypes[0]) {
    diag.add(
      errorDiagnostic(
        "T0043",
        name + ": the argument must be the NativePtr[Byte] nativeKeepCallback returned",
        callArgExpr(args[0]).span
      )
    )
  }
  Some(value = TyPrim(pt = PtUnit))
}

// `w.upgrade()` on a `w: NativeWeak[T]`: `Option[T]`, `Some` while the
// target is still alive.  None for any other receiver.
func nativeWeakUpgradeType(tbl: in SymbolTable, recvTy: in Type): Option[Type] {
  match mapGet(tbl.nativeIntrinsicTypes, "NativeWeak") {
    case Some(weakId) -> match unrefine(recvTy) {
      case TyUser(tid, _, targs) -> if symbolIdEq(tid, weakId) and targs.count == 1 {
        // `Option` not resolvable from the item pool (a partial check):
        // defer to the general member path rather than fabricate a TyError
        // that would unify with anything and swallow a real mismatch.
        match symTableTryFindInPackage(tbl, "Std.Core", "Option") {
          case Some(sym) -> match symbolTypeIdOpt(sym) {
            case Some(optId) -> Some(value = TyUser(id = optId, name = "Option", args = targs))
            case None -> None
          }
          case None -> None
        }
      } else {
        None
      }
      case _ -> None
    }
    case None -> None
  }
}

// The result type of `T.from` / `T.tryFrom` when `fn` names one on a
// distinct type `T` that no local shadows.
func distinctFactoryType(sc: in Scope, tbl: in SymbolTable, fn: in Expr): Option[Type] {
  match fn.kind {
    case EMember(recv, mname) -> {
      if mname != "from" and mname != "tryFrom" {
        return None
      }
      val tname = match recv.kind {
        case EPath(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
        case _ -> ""
      }
      if tname == "" {
        return None
      }
      match scopeTryFind(sc, tname) {
        case Some(_) -> return None
        case None -> ()
      }
      match symTableTryFindOne(tbl, tname) {
        case Some(sym) -> match sym.kind {
          case DKDistinctType(did, _) -> {
            val noArgs: List[Type] = newList()
            val dty = TyUser(id = did, name = sym.name, args = noArgs)
            if mname == "from" {
              return Some(value = dty)
            }
            // #7737: the synthesised `tryFrom` returns the stdlib
            // `Std.Core.Result` on both backends (MSIL seeds it from
            // `Std.Core/Std.Core.Result`), so resolve that by owning package
            // — a bare-name lookup picked up a package's own `union Result`,
            // whose cases then never matched the value codegen built.
            match symTableTryFindInPackage(tbl, "Std.Core", "Result") {
              case Some(rsym) -> match rsym.kind {
                case DKUnion(rid, _) -> {
                  val rargs: List[Type] = newList()
                  rargs.add(dty)
                  rargs.add(TyPrim(pt = PtString))
                  Some(value = TyUser(id = rid, name = rsym.name, args = rargs))
                }
                case _ -> None
              }
              case None -> None
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

// The underlying type of the non-generic distinct type `t`.
func distinctUnderlyingOf(tbl: in SymbolTable, t: in Type): Option[Type] {
  val tid = match t { case TyUser(id, _, _) -> id; case _ -> return None }
  var i = 0
  while i < tbl.symbols.count {
    val sym = tbl.symbols[i]
    match sym.kind {
      case DKDistinctType(did, dt) -> if symbolIdEq(did, tid) {
        match dt.generics {
          case Some(_) -> return None
          case None -> ()
        }
        val saved = enterDeclaringScope(tbl, sym)
        val scratch: List[Diagnostic] = newList()
        val underlying = resolveType(tbl, newGenericContext(), scratch, dt.underlying)
        restoreScope(tbl, saved)
        return Some(value = underlying)
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

// The `from` path of a distinct type (`type Cents = Long range ...`,
// `type UserId = Long`), if `t` is one (#7361).
pub func distinctFromPath(tbl: in SymbolTable, t: in Type): Option[String] {
  match t {
    case TyUser(tid, _, _) -> {
      var i = 0
      while i < tbl.symbols.count {
        val sym = tbl.symbols[i]
        match sym.kind {
          case DKDistinctType(did, _) -> {
            if symbolIdEq(did, tid) {
              return Some(value = sym.name + ".from")
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
      None
    }
    case _ -> None
  }
}

func recordDistinctSite(tbl: in SymbolTable, span: in Span, kind: in String): Unit {
  val key = recordCopySiteKey(span)
  if not tbl.distinctOpSites.containsKey(key) {
    tbl.distinctOpSites.add(key, kind)
  }
}

// Derived arithmetic on a distinct type.
func recordDistinctArith(tbl: in SymbolTable, lhs: in Type, rhs: in Type, span: in Span): Unit {
  if typeEquiv(lhs, rhs) {
    match distinctFromPath(tbl, lhs) {
      case Some(path) -> recordDistinctSite(tbl, span, "arith:" + path)
      case None -> ()
    }
  }
}

// Derived component-wise arithmetic on a homogeneous numeric record (D155):
// both operands are one record type that derives `Add` / `Sub`.  The
// declaration's own shape is checked by `checkRecordArithDerives` (T0152).
pub func recordRecordArith(tbl: in SymbolTable, lhs: in Type, rhs: in Type, op: in BinOp, span: in Span): Unit {
  if not typeEquiv(lhs, rhs) {
    return
  }
  match lhs {
    case TyUser(tid, _, _) -> match recordSymbolOfTid(tbl, tid) {
      case Some(rs) -> {
        val decl = match rs.kind { case DKRecord(_, rd) -> rd; case DKExposedRec(_, rd) -> rd; case _ -> return }
        val names: List[String] = newList()
        for m in decl.members {
          match m {
            case RMField(fd) -> names.add(fd.name)
            case _ -> ()
          }
        }
        val ctorPath = if rs.isImported and rs.originPackage.length > 0 { rs.originPackage + "." + rs.name } else { rs.name }
        val key = recordCopySiteKey(span)
        if not tbl.recordArithSites.containsKey(key) {
          tbl.recordArithSites.add(
            key,
            RecordArithSite(recordName = ctorPath, fields = names, recordType = typeExprForRef(tbl, lhs, span), op = op)
          )
        }
      }
      case None -> ()
    }
    case _ -> ()
  }
}

// A record whose `==` compares field by field (D164): one with no `var`
// field (a value, D157), or one that derives `Equals`.
pub func isStructuralEqRecord(tbl: in SymbolTable, t: in Type): Bool {
  match unrefine(t) {
    case TyUser(tid, _, _) -> match recordSymbolOfTid(tbl, tid) {
      case Some(rs) -> {
        val decl = match rs.kind { case DKRecord(_, rd) -> rd; case DKExposedRec(_, rd) -> rd; case _ -> return false }
        if hasDerive(tbl, "Equals", t) {
          return true
        }
        for m in decl.members {
          match m {
            case RMField(fd) -> if fd.isMutable { return false }
            case _ -> ()
          }
        }
        true
      }
      case None -> false
    }
    case _ -> false
  }
}

// `==` / `!=` on a structural record (D164).  The site lists the member
// paths compared at the leaves: a field that is itself a structural record
// is expanded into its fields, and a distinct type is compared through
// `.value`.  A field of function type has no `==` (T0153).
pub func recordRecordEq(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  lhs: in Type,
  rhs: in Type,
  negate: Bool,
  span: in Span,
): Unit {
  if not typeEquiv(lhs, rhs) or not isStructuralEqRecord(tbl, lhs) {
    return
  }
  match buildRecordEqSite(tbl, span, lhs, negate) {
    case Err(bad) -> diag.add(
      if bad.endsWith("~") {
        eqTooDeepDiagnostic(lhs, span)
      } else {
        errorDiagnostic(
          "T0153",
          "`" + renderType(lhs) + "` has no `==`: field `" + bad + "` is a function, and functions cannot be compared",
          span
        )
      }
    )
    case Ok(site) -> {
      val key = recordCopySiteKey(span)
      if not tbl.recordEqSites.containsKey(key) {
        tbl.recordEqSites.add(key, site)
      }
    }
  }
}

// The `RecordEqSite` of a structural record type `t`, or the path of the
// function-typed field that has no `==` (T0153).
pub func buildRecordEqSite(tbl: in SymbolTable, span: in Span, t: in Type, negate: Bool): Result[RecordEqSite, String] {
  val paths: List[List[String]] = newList()
  val prefix: List[String] = newList()
  val levelTypes: Map[String, TypeExpr] = newMap()
  val arrayLeaves: Map[String, ArrayEqSite] = newMap()
  val wrapLeaves: Map[String, EqShape] = newMap()
  val floatLeaves: Map[String, Bool] = newMap()
  val visiting: List[String] = newList()
  match collectEqLeaves(tbl, span, t, prefix, paths, levelTypes, arrayLeaves, wrapLeaves, floatLeaves, visiting) {
    case Some(bad) -> Err(error = bad)
    case None -> Ok(
      value = RecordEqSite(
        paths = paths,
        levelTypes = levelTypes,
        recordType = typeExprForRef(tbl, t, span),
        negate = negate,
        arrayLeaves = arrayLeaves,
        wrapLeaves = wrapLeaves,
        floatLeaves = floatLeaves
      )
    )
  }
}

func collectEqLeaves(
  tbl: in SymbolTable,
  span: in Span,
  t: in Type,
  prefix: in List[String],
  leaves: in List[List[String]],
  levelTypes: in Map[String, TypeExpr],
  arrayLeaves: in Map[String, ArrayEqSite],
  wrapLeaves: in Map[String, EqShape],
  floatLeaves: in Map[String, Bool],
  visiting: in List[String],
): Option[String] {
  val u = unrefine(t)
  match u {
    case TyFunction(_, _, _) -> return Some(value = dottedPath(prefix))
    case TyArray(Some(_), _, _) -> match buildArrayEqSite(tbl, span, u, false) {
      case Err(bad) -> return Some(value = dottedPath(prefix) + "." + bad)
      case Ok(site) -> {
        arrayLeaves[dottedPath(prefix)] = site
      }
    }
    case _ -> ()
  }
  match u {
    case TyUser(tid, _, args) -> {
      // The guard keys on the instantiated type, so `Box[Box[Int]]` expands
      // both levels.  A record that reaches itself through its own fields has
      // no finite value; its repeated occurrence is compared as a leaf, and so
      // is any expansion nested deeper than `maxEqExpansionDepth`.
      val key = renderType(u)
      if isStructuralEqRecord(tbl, u) and not listContainsStr(visiting, key) and visiting.count < maxEqExpansionDepth() {
        visiting.add(key)
        if prefix.count > 0 {
          match typeExprForRef(tbl, u, span) {
            case Some(te) -> {
              levelTypes[dottedPath(prefix)] = te
            }
            case None -> ()
          }
        }
        for f in fieldsOfRecordInstantiated(tbl, tid, args) {
          val bad = collectEqLeaves(
            tbl,
            span,
            f.ty,
            extendPath(prefix, f.name),
            leaves,
            levelTypes,
            arrayLeaves,
            wrapLeaves,
            floatLeaves,
            visiting
          )
          match bad {
            case Some(_) -> return bad
            case None -> ()
          }
        }
        visiting.removeAt(visiting.count - 1)
        return None
      }
      val scratch: List[Diagnostic] = newList()
      match distinctMemberType(tbl, scratch, u, "value", span) {
        case Some(under) -> return collectEqLeaves(
          tbl,
          span,
          under,
          extendPath(prefix, "value"),
          leaves,
          levelTypes,
          arrayLeaves,
          wrapLeaves,
          floatLeaves,
          visiting
        )
        case None -> ()
      }
    }
    case _ -> ()
  }
  // A tuple, union or distinct type that holds an array is compared by its
  // shape, not by the host's equality (D167).
  if isEqWrapperType(tbl, u) {
    match buildEqShape(tbl, span, u, 0) {
      case Err(bad) -> return Some(value = dottedPath(prefix) + "." + bad)
      case Ok(shape) -> {
        wrapLeaves[dottedPath(prefix)] = shape
      }
    }
  }
  if isFloatLeafType(u) {
    floatLeaves[dottedPath(prefix)] = isSingleFloatType(u)
  }
  leaves.add(prefix)
  None
}

func maxEqExpansionDepth(): Int = 32

func dottedPath(segs: in List[String]): String {
  var joined = ""
  for s in segs {
    joined = if joined.length == 0 { s } else { joined + "." + s }
  }
  joined
}

func extendPath(prefix: in List[String], name: in String): List[String] {
  val p: List[String] = newList()
  for s in prefix {
    p.add(s)
  }
  p.add(name)
  p
}

// The overflow-checked integer type `t` is, or "" (D163).  `Nat` is left out:
// it is a non-negative `Long` whose arithmetic keeps its own rules.
pub func overflowTypeName(t: in Type): String {
  match unrefine(t) {
    case TyPrim(pt) -> match pt {
      case PtInt -> "Int"
      case PtLong -> "Long"
      case PtUInt -> "UInt"
      case PtULong -> "ULong"
      case PtByte -> "Byte"
      case _ -> ""
    }
    case _ -> ""
  }
}

pub func recordOverflowSite(tbl: in SymbolTable, span: in Span, kind: in String): Unit {
  val key = recordCopySiteKey(span)
  if tbl.overflowSites.containsKey(key) {
    tbl.overflowSites.remove(key)
  }
  tbl.overflowSites.add(key, kind)
}

func isWrappingMethodName(n: in String): Bool {
  n == "wrappingAdd" or n == "wrappingSub" or n == "wrappingMul" or n == "wrappingNeg"
}

// `+`, `-` or `*` whose result is an overflow-checked integer type (D163).
func recordOverflowBinop(tbl: in SymbolTable, op: in BinOp, result: in Type, span: in Span): Unit {
  val opName = match op { case BAdd -> "add"; case BSub -> "sub"; case BMul -> "mul"; case _ -> return }
  val tn = overflowTypeName(result)
  if tn.length > 0 {
    recordOverflowSite(tbl, span, opName + ":" + tn)
  }
}

// `==`/`!=` or a derived comparison on two values of one distinct type.
func recordDistinctCompare(tbl: in SymbolTable, lhs: in Type, rhs: in Type, span: in Span): Unit {
  // A distinct type holding an array is compared by `recordWrapEq`, which
  // reads its `.value` and compares the array element by element.
  if typeEquiv(lhs, rhs) and not isEqWrapperType(tbl, lhs) {
    match distinctFromPath(tbl, lhs) {
      case Some(_) -> recordDistinctSite(tbl, span, "cmp")
      case None -> ()
    }
  }
}

// The `where` marker an arithmetic or relational operator is valid under on a
// type parameter: `Add` for `+`, `Compare` for `<`, and so on.  "" for every
// other operator.
pub func operatorMarker(op: in BinOp): String {
  match op {
    case BAdd -> "Add"
    case BSub -> "Sub"
    case BMul -> "Mul"
    case BDiv -> "Div"
    case BMod -> "Mod"
    case BLt -> "Compare"
    case BLte -> "Compare"
    case BGt -> "Compare"
    case BGte -> "Compare"
    case _ -> ""
  }
}

// True when `t` is a type parameter of the enclosing function whose `where`
// clause bounds it by `marker` (#7996, #8017).
func tyVarBoundedBy(sc: in Scope, t: in Type, marker: in String): Bool {
  match t {
    case TyVar(name) -> {
      for b in sc.bounds {
        if b.name == name and listContainsStr(b.constraints, marker) {
          return true
        }
      }
      false
    }
    case _ -> false
  }
}

// An operator whose operand is a type parameter bounded by the operator's
// marker takes two operands of that one parameter: a specialisation
// substitutes a single type for it, so `a + 1` over `T` has no meaning at a
// distinct type or a record.  The result is the parameter (`Bool` for a
// comparison).
func boundedOperandsClash(sc: in Scope, op: in BinOp, lhs: in Type, rhs: in Type): Bool {
  val marker = operatorMarker(op)
  if marker.length == 0 {
    return false
  }
  if not tyVarBoundedBy(sc, lhs, marker) and not tyVarBoundedBy(sc, rhs, marker) {
    return false
  }
  match lhs {
    case TyVar(ln) -> match rhs { case TyVar(rn) -> ln != rn; case TyError -> false; case _ -> true }
    case TyError -> false
    case _ -> match rhs { case TyError -> false; case _ -> true }
  }
}

func inferBinop(
  sc: in Scope,
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  op: in BinOp,
  lhs: in Type,
  rhs: in Type,
  span: in Span,
): Type {
  if boundedOperandsClash(sc, op, lhs, rhs) {
    val code = if operatorMarker(op) == "Compare" { "T0033" } else { "T0031" }
    val what = if code == "T0033" {
      "comparison operands must be matching ordered types"
    } else {
      "arithmetic operands must have the same type"
    }
    diag.add(
      errorDiagnostic(
        code,
        what + " (got " + renderType(lhs) + " and " + renderType(rhs) + "); an operator bounded by `" + operatorMarker(op) +
          "` takes two values of the one type parameter",
        span
      )
    )
    return if operatorMarker(op) == "Compare" { TyPrim(pt = PtBool) } else { lhs }
  }
  match op {
    case BAdd -> {
      match lhs {
        case TyPrim(pt) -> match pt { case PtString -> return TyPrim(pt = PtString); case _ -> {  } }
        case _ -> {
        }
      }
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Add", lhs) or tyVarBoundedBy(sc, lhs, "Add")
      if not isNumericType(lhs) and hasDerive(tbl, "Add", lhs) {
        recordDistinctArith(tbl, lhs, rhs, span)
        recordRecordArith(tbl, lhs, rhs, BAdd, span)
      }
      if not lhsOk {
        diag.add(
          errorDiagnostic("T0030", "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span)
        )
      }
      // M6: numeric widening — Int + Long → Long.  `widenArithmetic` returns
      // `None` for same-type pairs (already `typeEquiv`), so the slow path
      // only diagnoses mismatched, non-widenable operand types.
      val addWiden = widenArithmetic(lhs, rhs)
      match addWiden {
        case Some(w) -> w
        case None -> {
          if not typeEquiv(lhs, rhs) {
            diag.add(
              errorDiagnostic(
                "T0031",
                "arithmetic operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
                span
              )
            )
          }
          lhs
        }
      }
    }
    case BSub -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Sub", lhs) or tyVarBoundedBy(sc, lhs, "Sub")
      if not isNumericType(lhs) and hasDerive(tbl, "Sub", lhs) {
        recordDistinctArith(tbl, lhs, rhs, span)
        recordRecordArith(tbl, lhs, rhs, BSub, span)
      }
      if not lhsOk {
        diag.add(
          errorDiagnostic("T0030", "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span)
        )
      }
      val subWiden = widenArithmetic(lhs, rhs)
      match subWiden {
        case Some(w) -> w
        case None -> {
          if not typeEquiv(lhs, rhs) {
            diag.add(
              errorDiagnostic(
                "T0031",
                "arithmetic operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
                span
              )
            )
          }
          lhs
        }
      }
    }
    case BMul -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Mul", lhs) or tyVarBoundedBy(sc, lhs, "Mul")
      if not isNumericType(lhs) and hasDerive(tbl, "Mul", lhs) {
        recordDistinctArith(tbl, lhs, rhs, span)
      }
      if not lhsOk {
        diag.add(
          errorDiagnostic("T0030", "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span)
        )
      }
      val mulWiden = widenArithmetic(lhs, rhs)
      match mulWiden {
        case Some(w) -> w
        case None -> {
          if not typeEquiv(lhs, rhs) {
            diag.add(
              errorDiagnostic(
                "T0031",
                "arithmetic operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
                span
              )
            )
          }
          lhs
        }
      }
    }
    case BDiv -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Div", lhs) or tyVarBoundedBy(sc, lhs, "Div")
      if not isNumericType(lhs) and hasDerive(tbl, "Div", lhs) {
        recordDistinctArith(tbl, lhs, rhs, span)
      }
      if not lhsOk {
        diag.add(
          errorDiagnostic("T0030", "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span)
        )
      }
      val divWiden = widenArithmetic(lhs, rhs)
      match divWiden {
        case Some(w) -> w
        case None -> {
          if not typeEquiv(lhs, rhs) {
            diag.add(
              errorDiagnostic(
                "T0031",
                "arithmetic operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
                span
              )
            )
          }
          lhs
        }
      }
    }
    case BMod -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Mod", lhs) or tyVarBoundedBy(sc, lhs, "Mod")
      if not isNumericType(lhs) and hasDerive(tbl, "Mod", lhs) {
        recordDistinctArith(tbl, lhs, rhs, span)
      }
      if not lhsOk {
        diag.add(
          errorDiagnostic("T0030", "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span)
        )
      }
      val modWiden = widenArithmetic(lhs, rhs)
      match modWiden {
        case Some(w) -> w
        case None -> {
          if not typeEquiv(lhs, rhs) {
            diag.add(
              errorDiagnostic(
                "T0031",
                "arithmetic operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
                span
              )
            )
          }
          lhs
        }
      }
    }
    case BEq -> {
      if not typeEquiv(lhs, rhs) {
        diag.add(
          errorDiagnostic(
            "T0032",
            "equality operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
            span
          )
        )
      }
      recordDistinctCompare(tbl, lhs, rhs, span)
      recordRecordEq(tbl, diag, lhs, rhs, false, span)
      recordArrayEq(tbl, diag, lhs, rhs, false, span)
      recordWrapEq(tbl, diag, lhs, rhs, false, span)
      TyPrim(pt = PtBool)
    }
    case BNeq -> {
      if not typeEquiv(lhs, rhs) {
        diag.add(
          errorDiagnostic(
            "T0032",
            "equality operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
            span
          )
        )
      }
      recordDistinctCompare(tbl, lhs, rhs, span)
      recordRecordEq(tbl, diag, lhs, rhs, true, span)
      recordArrayEq(tbl, diag, lhs, rhs, true, span)
      recordWrapEq(tbl, diag, lhs, rhs, true, span)
      TyPrim(pt = PtBool)
    }
    case BLt -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs) or tyVarBoundedBy(sc, lhs, "Compare")
      val ltWiden = widenArithmetic(lhs, rhs)
      val ltCompat = match ltWiden { case Some(_) -> true; case None -> typeEquiv(lhs, rhs) }
      if not lhsOk or not ltCompat {
        diag.add(
          errorDiagnostic(
            "T0033",
            "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
            span
          )
        )
      }
      recordDistinctCompare(tbl, lhs, rhs, span)
      TyPrim(pt = PtBool)
    }
    case BLte -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs) or tyVarBoundedBy(sc, lhs, "Compare")
      val lteWiden = widenArithmetic(lhs, rhs)
      val lteCompat = match lteWiden { case Some(_) -> true; case None -> typeEquiv(lhs, rhs) }
      if not lhsOk or not lteCompat {
        diag.add(
          errorDiagnostic(
            "T0033",
            "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
            span
          )
        )
      }
      recordDistinctCompare(tbl, lhs, rhs, span)
      TyPrim(pt = PtBool)
    }
    case BGt -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs) or tyVarBoundedBy(sc, lhs, "Compare")
      val gtWiden = widenArithmetic(lhs, rhs)
      val gtCompat = match gtWiden { case Some(_) -> true; case None -> typeEquiv(lhs, rhs) }
      if not lhsOk or not gtCompat {
        diag.add(
          errorDiagnostic(
            "T0033",
            "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
            span
          )
        )
      }
      recordDistinctCompare(tbl, lhs, rhs, span)
      TyPrim(pt = PtBool)
    }
    case BGte -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs) or tyVarBoundedBy(sc, lhs, "Compare")
      val gteWiden = widenArithmetic(lhs, rhs)
      val gteCompat = match gteWiden { case Some(_) -> true; case None -> typeEquiv(lhs, rhs) }
      if not lhsOk or not gteCompat {
        diag.add(
          errorDiagnostic(
            "T0033",
            "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
            span
          )
        )
      }
      recordDistinctCompare(tbl, lhs, rhs, span)
      TyPrim(pt = PtBool)
    }
    case BAnd -> {
      if not typeIsBoolOperand(lhs) {
        diag.add(
          errorDiagnostic("T0034", "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span)
        )
      }
      if not typeIsBoolOperand(rhs) {
        diag.add(
          errorDiagnostic("T0034", "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span)
        )
      }
      TyPrim(pt = PtBool)
    }
    case BOr -> {
      if not typeIsBoolOperand(lhs) {
        diag.add(
          errorDiagnostic("T0034", "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span)
        )
      }
      if not typeIsBoolOperand(rhs) {
        diag.add(
          errorDiagnostic("T0034", "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span)
        )
      }
      TyPrim(pt = PtBool)
    }
    case BXor -> {
      if not typeIsBoolOperand(lhs) {
        diag.add(
          errorDiagnostic("T0034", "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span)
        )
      }
      if not typeIsBoolOperand(rhs) {
        diag.add(
          errorDiagnostic("T0034", "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span)
        )
      }
      TyPrim(pt = PtBool)
    }
    case BImplies -> {
      if not typeIsBoolOperand(lhs) {
        diag.add(
          errorDiagnostic("T0034", "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span)
        )
      }
      if not typeIsBoolOperand(rhs) {
        diag.add(
          errorDiagnostic("T0034", "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span)
        )
      }
      TyPrim(pt = PtBool)
    }
    case BCoalesce -> {
      match lhs {
        case TyNullable(inner) -> {
          if not typeEquiv(inner, rhs) {
            diag.add(
              errorDiagnostic(
                "T0035",
                "?? RHS type " + renderType(rhs) + " must match the nullable's inner type " + renderType(inner),
                span
              )
            )
          }
          inner
        }
        case TyError -> TyError
        case _ -> {
          diag.add(errorDiagnostic("T0035", "?? LHS must be a nullable type (got " + renderType(lhs) + ")", span))
          rhs
        }
      }
    }
  }
}

// T0147's text for a negated operand of `operand`'s type.  Only `Byte`
// (or a range of it) converts with `toInt`; `UInt`/`ULong` convert with
// `toLong` (docs/01 §4.1).
func unsignedNegationMessageFor(operand: in Type): String {
  unsignedNegationText(renderType(operand), isPrimOf(operand, PtByte))
}

// T0147's text for a negated constant of the unsigned primitive `typeName`
// (`Byte`, `UInt` or `ULong`), as the constant folder names it.
func unsignedNegationMessage(typeName: in String): String {
  unsignedNegationText(typeName, typeName == "Byte")
}

func unsignedNegationText(typeText: in String, isByte: in Bool): String {
  val hint = if isByte {
    "convert it to a signed type first, e.g. `-(x.toInt())`"
  } else {
    "convert it to a signed type first, e.g. `-(x.toLong())`"
  }
  "unary minus cannot be applied to an unsigned operand (got " + typeText +
    "): a non-zero unsigned value has no negation of its own type; " +
    hint
}

func inferPrefix(diag: in List[Diagnostic], op: in PrefixOp, inner: in Type, span: in Span): Type {
  match op {
    case PreNeg -> {
      if not isNumericType(inner) {
        diag.add(errorDiagnostic("T0036", "unary minus requires a numeric operand (got " + renderType(inner) + ")", span))
      } else if isUnsignedConvReceiver(inner) {
        diag.add(errorDiagnostic("T0147", unsignedNegationMessageFor(inner), span))
        return TyError
      } else if isPrimOf(inner, PtNat) {
        diag.add(
          errorDiagnostic(
            "T0147",
            "unary minus cannot be applied to a Nat operand (got " + renderType(inner) +
              "): a non-zero Nat has no negation of its own type; convert it first, e.g. `-(n.toLong())`",
            span
          )
        )
        return TyError
      }
      inner
    }
    case PreNot -> {
      if not typeIsBoolOperand(inner) {
        diag.add(errorDiagnostic("T0037", "'not' requires a Bool operand (got " + renderType(inner) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case PreRef -> {
      // `&` was reserved for a planned function-reference form (`&f`,
      // see `Lyric.LlvmCodegen`'s matching native-target panic) but no
      // backend implements it: MSIL silently passes the operand through
      // unchanged (a no-op, not a reference), and native panics outright.
      // Before this diagnostic, that MSIL no-op made `&` a landmine: `&`
      // has no infix form (it's prefix-only, `docs/grammar.ebnf`'s
      // `PrefixExpr`), so `x & y` parsed as `x` (a complete expression)
      // followed by a silently re-entered, silently accepted `&y`
      // statement — discarding `y` with no diagnostic anywhere
      // (cloud-agents docs/lyric/gotchas.md's "& is NOT bitwise-and"
      // entry). Rejecting `&<expr>` unconditionally, on every target,
      // turns that silent data loss into a compile error at the `&`
      // site itself instead of requiring a fix to statement-boundary
      // parsing in general.
      diag.add(
        errorDiagnostic(
          "T0141",
          "'&' (function-reference syntax) is not implemented yet — pass a lambda instead, or use .and()/.or()/.xor()/.shl()/.shr() for bitwise operations",
          span
        )
      )
      inner
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Member access.
// ─────────────────────────────────────────────────────────────────────────────
func builtinMember(tbl: in SymbolTable, recvRaw: in Type, name: in String): Option[Type] {
  val recv = unrefine(recvRaw)
  match recv {
    case TySlice(elem) -> {
      if name == "length" {
        return Some(value = TyPrim(pt = PtInt))
      }
      // `.append`/`.concat`/`.slice` (docs/agent/reference.md "Arrays and
      // slices") never mutate in place — each returns a NEW `slice[T]` — so
      // they are typed as real `TyFunction`s (not a bare return type)
      // precisely so the `ECall` arm's existing arg-count/arg-type
      // validation (T0042/T0043) runs against them, rather than silently
      // degrading to `TyError` the way an unrecognised method name on this
      // receiver would (#5244).
      if name == "append" {
        val ps: List[Type] = newList()
        ps.add(elem)
        return Some(value = TyFunction(params = ps, ret = TySlice(element = elem), isAsync = false))
      }
      if name == "concat" {
        val ps: List[Type] = newList()
        ps.add(TySlice(element = elem))
        return Some(value = TyFunction(params = ps, ret = TySlice(element = elem), isAsync = false))
      }
      if name == "slice" {
        val ps: List[Type] = newList()
        ps.add(TyPrim(pt = PtInt))
        ps.add(TyPrim(pt = PtInt))
        return Some(value = TyFunction(params = ps, ret = TySlice(element = elem), isAsync = false))
      }
      None
    }
    case TyArray(_, elem, _) -> {
      if name == "length" {
        return Some(value = TyPrim(pt = PtInt))
      }
      if name == "toSlice" {
        val ps: List[Type] = newList()
        return Some(value = TyFunction(params = ps, ret = TySlice(element = elem), isAsync = false))
      }
      None
    }
    case TyPrim(pt) -> match pt {
      case PtString -> {
        if name == "length" {
          return Some(value = TyPrim(pt = PtInt))
        }
        if name == "isEmpty" {
          return Some(value = TyPrim(pt = PtBool))
        }
        None
      }
      case _ -> None
    }
    case TyException -> {
      if name == "message" {
        return Some(value = TyPrim(pt = PtString))
      }
      if name == "typeName" {
        return Some(value = TyPrim(pt = PtString))
      }
      None
    }
    case TyUser(tid, _, targs) -> {
      // Generic collection methods that must carry their element type through so
      // downstream uses (notably `for x in xs.toArray()` + `match x`) see the
      // real element type rather than `TyError` — an unknown-typed match
      // scrutinee silently degenerates to the first case (#2126).  Keyed on
      // the stdlib `List`'s identity (#7737): a package's own `record
      // List[T]` has no `toArray`/`count`, and typing them here hid the
      // unknown-member diagnostic and reached codegen as invalid IL.
      if targs.count == 1 and symbolIdEq(tid, builtinBufferTypeId()) {
        if name == "length" {
          return Some(value = TyPrim(pt = PtInt))
        }
        // `Std.Buffer`'s own bridge to its `List` representation (D185): the
        // identity on a target that represents a buffer as a list.
        if name == bufferAsListMember() and symTableScopePkg(tbl) == "Std.Buffer" {
          match symTableStdCollectionsHostTypeId(tbl, "List") {
            case Some(listId) -> {
              val noParams: List[Type] = newList()
              val elemArgs: List[Type] = newList()
              elemArgs.add(targs[0])
              return Some(
                value = TyFunction(
                  params = noParams,
                  ret = TyUser(id = listId, name = "List", args = elemArgs),
                  isAsync = false
                )
              )
            }
            case None -> ()
          }
        }
      }
      if targs.count == 1 and isStdCollectionsHostType(tbl, tid, "List") {
        if name == "toArray" {
          // A real `TyFunction` (zero params), not the bare result type:
          // `toArray` is always used call-style (`xs.toArray()`), and a bare
          // `TySlice` would make the `ECall` arm report T0044 "called value
          // of non-function type" now that `inferMemberBase` consults this
          // table for `TyUser` receivers (the slice-method precedent above).
          val noParams: List[Type] = newList()
          return Some(value = TyFunction(params = noParams, ret = TySlice(element = targs[0]), isAsync = false))
        }
        if name == "count" {
          return Some(value = TyPrim(pt = PtInt))
        }
        if name == bufferFromListMember() and symTableScopePkg(tbl) == "Std.Buffer" {
          val noParams: List[Type] = newList()
          return Some(value = TyFunction(params = noParams, ret = bufferType(targs[0]), isAsync = false))
        }
      }
      None
    }
    case _ -> None
  }
}

// Direct field-style accessors on the two builtin monadic unions
// (docs/01 §generics, docs/08 §6.2, docs/02 worked examples):
// `.isOk`/`.isErr`/`.value`/`.error` on `Result[T, E]`, `.isSome`/`.isNone`/
// `.value` on `Option[T]`.  `result.isOk implies result.value >= 0` is the
// documented `ensures:` idiom this exists to make actually type-check with a
// real type instead of silently degrading to `TyError` (no field on a
// union, no dot-named function under that name either) — which reached
// codegen as an unregistered field read and produced
// `InvalidProgramException` at runtime regardless of whether `E` was
// trivial or payload-carrying (#5183).
//
// Deliberately NOT folded into `builtinMember` (consulted by
// `inferMemberBase`, which BOTH the bare-`EMember` path and the `ECall`
// callee-type lookup share, #6624 review): `isOk`/`isErr`/`isSome`/`isNone`
// are ordinary plain functions in `Std.Core` (`pub func isOk[T,E](r: in
// Result[T,E]): Bool`, not a dot-named `Result.isOk`), callable via the
// existing UFCS call-site resolution as `r.isOk()` — that path works by
// leaving the `ECall`'s callee type `TyError` (`inferMemberBase` finds no
// real field) so it falls through to `resolveMethodCallPick`'s UFCS
// candidate search. Returning a real `TyPrim(Bool)` from `inferMemberBase`
// for `.isOk` would short-circuit that fallback and make `.isOk()`
// (`ECall(EMember(...), [])`) treat a `Bool` as the callee, T0044 "called
// value of non-function type Bool" — exactly the regression this
// separation avoids. This function is consulted only from `inferMember`
// (the bare-member-access wrapper `inferExpr`'s plain `EMember` arm calls),
// never from the `ECall` arm's own direct `inferMemberBase` call, so the
// bare `.isOk` form (this fix) and the call form `.isOk()` (pre-existing)
// both keep working.
// Keyed by `SymbolId` (not simple name) — the same #2303 soundness precedent
// `SymbolTable.impls` documents: a same-simple-name `Result`/`Option`
// union declared OUTSIDE `Std.Core` must never satisfy this check (#6630).
// A plain `nm == "Result"` string test (the previous behaviour) would also
// match a package-local `MyLib.Result[T, E]` union and lower it as though
// it were the real `Std.Core.Result`, producing an incorrect isinst/
// castclass/field-read against the wrong case classes instead of a clean
// type error.
func isStdCoreMonadType(tbl: in SymbolTable, tid: in SymbolId, name: in String): Bool {
  match symTableTryFindInPackage(tbl, "Std.Core", name) {
    case Some(sym) -> match symbolTypeIdOpt(sym) { case Some(realId) -> symbolIdEq(tid, realId); case None -> false }
    case None -> false
  }
}

func monadAccessorType(tbl: in SymbolTable, recvRaw: in Type, name: in String): Option[Type] {
  match unrefine(recvRaw) {
    case TyUser(tid, nm, targs) -> {
      if nm == "Result" and targs.count == 2 and isStdCoreMonadType(tbl, tid, "Result") {
        if name == "isOk" or name == "isErr" {
          return Some(value = TyPrim(pt = PtBool))
        }
        if name == "value" {
          return Some(value = targs[0])
        }
        if name == "error" {
          return Some(value = targs[1])
        }
      }
      if nm == "Option" and targs.count == 1 and isStdCoreMonadType(tbl, tid, "Option") {
        if name == "isSome" or name == "isNone" {
          return Some(value = TyPrim(pt = PtBool))
        }
        if name == "value" {
          return Some(value = targs[0])
        }
      }
      None
    }
    case _ -> None
  }
}

// True for the six reserved bare-member accessor names `monadAccessorType`
// grants a real type to on the genuine `Std.Core.Result`/`Option` (#6630).
func isReservedMonadAccessorName(name: in String): Bool {
  name == "isOk" or name == "isErr" or name == "value" or name == "error" or name == "isSome" or name == "isNone"
}

// #6630 / #6710: `recvRaw` structurally matches `Result[T, E]` / `Option[T]`
// (the reserved bare name + arity `monadAccessorType` looks for), and
// `name` is one of the six reserved accessor names, but `monadAccessorType`
// already returned `None` for it. Called from `inferMember`'s final
// fallback, only once every legitimate resolution path (a real
// method/UFCS function the receiver's own type defines) has already come
// up empty, so a same-shaped union that genuinely implements its own
// `.isOk` etc. is unaffected. See the call site for why this diagnostic
// needs to exist at all instead of relying on the general unknown-member
// path.
//
// `monadAccessorType` returning `None` here has TWO distinct causes that
// must NOT share the same wording (#6710 review finding): either (a)
// `recvRaw` is the genuine `Std.Core.Result`/`Option`, but `name` is the
// OTHER monad's accessor (`.isSome`/`.isNone` on a real `Result`, or
// `.isOk`/`.isErr`/`.error` on a real `Option` — `monadAccessorType` only
// grants each monad its own accessor set, so this falls through even
// though the type identity check passes), or (b) `recvRaw` is a genuinely
// foreign lookalike type outside `Std.Core`. Re-running
// `isStdCoreMonadType` (the same identity check `monadAccessorType`
// itself uses) distinguishes the two: case (a) never mentions a foreign
// type (there isn't one), case (b) keeps the original "declared outside
// Std.Core" wording.
func monadAccessorShapeMismatchDiag(
  tbl: in SymbolTable, recvRaw: in Type, name: in String, span: in Span
): Option[Diagnostic] {
  if not isReservedMonadAccessorName(name) {
    return None
  }
  match unrefine(recvRaw) {
    case TyUser(tid, nm, targs) -> {
      if nm == "Result" and targs.count == 2 {
        if isStdCoreMonadType(tbl, tid, "Result") {
          return Some(
            value = errorDiagnostic(
              "T0124",
              "no member '" + name + "' on type 'Result' -- Result's accessors are .isOk/.isErr/.value/.error; '" +
                name +
                "' is Option's accessor, not Result's",
              span
            )
          )
        }
        return Some(
          value = errorDiagnostic(
            "T0124",
            "no member '" + name +
              "' on type 'Result' -- this looks like the reserved Std.Core.Result accessor sugar, but this 'Result' is a different type declared outside Std.Core",
            span
          )
        )
      }
      if nm == "Option" and targs.count == 1 {
        if isStdCoreMonadType(tbl, tid, "Option") {
          return Some(
            value = errorDiagnostic(
              "T0124",
              "no member '" + name + "' on type 'Option' -- Option's accessors are .isSome/.isNone/.value; '" +
                name +
                "' is Result's accessor, not Option's",
              span
            )
          )
        }
        return Some(
          value = errorDiagnostic(
            "T0124",
            "no member '" + name +
              "' on type 'Option' -- this looks like the reserved Std.Core.Option accessor sugar, but this 'Option' is a different type declared outside Std.Core",
            span
          )
        )
      }
      None
    }
    case _ -> None
  }
}

// Numeric / character conversion methods (#1901): `b.toInt()`, `c.toLong()`,
// etc.  The target primitive each one yields; `None` for any other name.
// `toFloat` narrows to the 32-bit `Float` (D155) with round-to-nearest-even.
// `toNat` (#2050 / Band 4's Int/Long/Byte/Char/Double
// -> Nat direction) is now implemented on `--target dotnet` as a CHECKED
// conversion (Msil.Codegen.emitCheckedToNatMsil): `Nat` erases to the same
// `int64` as `Long`, so this is really `.toLong()` plus a non-negative check,
// mirroring how `.toChar()` is `.toInt()`/`.toLong()` plus a range check.
// The reverse direction (`Nat` as a conversion-method RECEIVER, e.g. a
// hypothetical `nat.toDouble()`) is a separate, still-open gap — see
// isNumericOrCharType below.
func numericConvTarget(name: in String): Option[PrimType] {
  if name == "toByte" {
    return Some(value = PtByte)
  }
  if name == "toInt" {
    return Some(value = PtInt)
  }
  if name == "toLong" {
    return Some(value = PtLong)
  }
  if name == "toChar" {
    return Some(value = PtChar)
  }
  if name == "toDouble" {
    return Some(value = PtDouble)
  }
  if name == "toFloat" {
    return Some(value = PtFloat)
  }
  if name == "toNat" {
    return Some(value = PtNat)
  }
  None
}

// A receiver type the numeric conversion methods accept.  Restricted to the
// primitives the backend can actually represent and convert — `Byte`, `Int`,
// `Long`, `Double`, `Char` — so the type checker never accepts a `.toX()` call
// the codegen cannot lower. `Nat` itself is a valid conversion *target*
// (`numericConvTarget`'s `toNat` arm above) but is deliberately NOT added to
// this receiver whitelist: a `Nat`-typed value calling `.toDouble()`/
// `.toByte()`/etc. still has no dedicated codegen support (it currently only
// "works" for `.toInt()`/`.toLong()` by accident, since `Nat` and `Long`
// share the same MSIL erasure and codegen dispatches on the erased type).
// The other unsigned integers (`UInt`, `ULong`) have no backend representation
// as a conversion-method receiver either; conversion support for them as a
// RECEIVER is tracked in #2050 / Band 4 and must land with real backend
// support, not a checker-only claim.  `Float` is a receiver since every
// backend represents it as binary32 (D155).
func isNumericOrCharType(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt {
      case PtByte -> true
      case PtInt -> true
      case PtLong -> true
      case PtDouble -> true
      case PtFloat -> true
      case PtChar -> true
      case _ -> false
    }
    case _ -> false
  }
}

// True when `t` is a numeric primitive (not a refinement of one).
func isNumericPrimType(t: in Type): Bool {
  match t {
    case TyPrim(_) -> isNumericType(t)
    case _ -> false
  }
}

// A receiver of `.toULong()`: a primitive of the unsigned widening chain.
// `u.toLong()`, `u.toDouble()`, `u.toFloat()` and `u.toNat()` on a `UInt`
// convert the unsigned VALUE (#7901).  A `UInt` shares its 32-bit
// representation with `Int`, so the plain signed conversion would read the top
// bit as a sign: the `UInt` is zero-extended to a `ULong` first (a lossless
// widening, whose pattern is a non-negative `Long`).  A `ULong` shares the
// 64-bit representation of `Long`, so its `toLong` (checked: it panics above
// `Long.MaxValue`), `toDouble` and `toFloat` (the unsigned value) are recorded
// as overflow sites that `Lyric.ContractElaborator.lowerOverflowChecks`
// lowers to plain `Long` operations on every target (#8450).
func noteUnsignedSourceConversion(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  recvE: in Expr,
  rt: in Type,
  mname: in String,
  callSpan: in Span,
): Bool {
  if isPrimOf(rt, PtUInt) {
    if mname == "toLong" or mname == "toDouble" or mname == "toFloat" or mname == "toNat" {
      recordWideningSite(tbl, TyPrim(pt = PtULong), rt, recvE, false)
    }
    return true
  }
  if isPrimOf(rt, PtULong) and (mname == "toLong" or mname == "toDouble" or mname == "toFloat") {
    // The lowering's own conversions on the `Long` it binds are plain ones.
    if callSpan.startPos.offset != callSpan.endPos.offset {
      recordOverflowSite(tbl, callSpan, "ulong:" + mname)
    }
  }
  true
}

func isUnsignedConvReceiver(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtByte -> true; case PtUInt -> true; case PtULong -> true; case _ -> false }
    case _ -> false
  }
}

// A well-typed primitive that is *definitively* not a numeric conversion
// receiver and cannot carry a user-defined method either (`String`, `Bool`,
// `Unit`) — so a `.toInt()`-style call on it is unambiguously a mistake worth a
// targeted diagnostic rather than a bare downstream type mismatch.  The
// unsigned integers are deliberately NOT here: they are numeric (just
// unimplemented), so flagging them as "not applicable" would mislead.
func isNonConvertiblePrimitive(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtString -> true; case PtBool -> true; case PtUnit -> true; case _ -> false }
    case _ -> false
  }
}

// TyError for unknown receivers is intentional: codegen owns exotic receiver behaviour.
func indexElementType(tbl: in SymbolTable, recvRaw: in Type): Type {
  match unrefine(recvRaw) {
    case TySlice(elem) -> elem
    case TyArray(_, elem, _) -> elem
    case TyPrim(pt) -> match pt { case PtString -> TyPrim(pt = PtChar); case _ -> TyError }
    case TyUser(tid, _, targs) -> {
      // Keyed on the stdlib collections' identity, not their bare names
      // (#7737): both backends lower an index on these receivers as the
      // genuine `List<T>`/`ArrayList` `get_Item`/`get` or the
      // `Dictionary`/`HashMap` lookup, so a package's own `record List[T]` or
      // `record Map[K, V]` must not be typed as if it were one.
      if targs.count == 1 and symbolIdEq(tid, builtinBufferTypeId()) {
        targs[0]
      } else if targs.count == 1 and isStdCollectionsHostType(tbl, tid, "List") {
        targs[0]
      } else if targs.count == 2 and isStdCollectionsHostType(tbl, tid, "Map") {
        targs[1]
      } else {
        TyError
      }
    }
    case _ -> TyError
  }
}

// #7737: a Lyric-native record, union or enum is never indexable — neither
// backend has an indexer protocol for one (MSIL's `EIndex` lowering falls
// back to a `System.Collections.IList` cast, the JVM's to an `ArrayList`
// cast), so `r[i]` on one compiled and then failed at runtime with an
// `InvalidCastException`/`ClassCastException`.  Extern, distinct, opaque,
// protected and interface receivers keep the lenient `TyError` path: those
// are the "exotic receiver behaviour" codegen owns.  Returns the kind word
// phrase used in the diagnostic ("" when the receiver may be indexable).
func nonIndexableNativeKind(tbl: in SymbolTable, recvRaw: in Type): String {
  match unrefine(recvRaw) {
    case TyUser(tid, _, _) -> match symTableTypeSymbolOf(tbl, tid) {
      case Some(sym) -> match sym.kind {
        case DKRecord(_, _) -> "a record"
        case DKExposedRec(_, _) -> "an exposed record"
        case DKUnion(_, _) -> "a union"
        case DKEnum(_, _) -> "an enum"
        case _ -> ""
      }
      case None -> ""
    }
    case _ -> ""
  }
}

func fieldsOfRecord(tbl: in SymbolTable, tid: in SymbolId): List[FieldEntry] {
  val result: List[FieldEntry] = newList()
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKRecord(did, rd) -> {
        if symbolIdEq(did, tid) {
          // Field types name the declaring package's own types, resolved in
          // its scope whatever the reading file imports (docs/01 §9.2).
          val saved = enterDeclaringScopeIfForeign(tbl, tbl.symbols[i])
          extractRecordFields(tbl, rd, result)
          restoreScope(tbl, saved)
        }
      }
      case DKExposedRec(did, rd) -> {
        if symbolIdEq(did, tid) {
          // Field types name the declaring package's own types, resolved in
          // its scope whatever the reading file imports (docs/01 §9.2).
          val saved = enterDeclaringScopeIfForeign(tbl, tbl.symbols[i])
          extractRecordFields(tbl, rd, result)
          restoreScope(tbl, saved)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  result
}

record FieldEntry {
  name: String
  ty: Type
}

// The declared type of field `name` among `fields`, or `TyError` if absent.
func fieldEntryType(fields: in List[FieldEntry], name: in String): Type {
  var i = 0
  while i < fields.count {
    if fields[i].name == name {
      return fields[i].ty
    }
    i = i + 1
  }
  TyError
}

func recordDeclGenericNames(rd: in RecordDecl): List[String] {
  val names: List[String] = newList()
  match rd.generics {
    case None -> {
    }
    case Some(g) -> {
      var j = 0
      while j < g.params.count {
        match g.params[j] {
          case GPType(nm, _) -> names.add(nm)
          case GPValue(nm, _, _) -> names.add(nm)
        }
        j = j + 1
      }
    }
  }
  names
}

func recordGenericNamesOf(tbl: in SymbolTable, tid: in SymbolId): List[String] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKRecord(did, rd) -> {
        if symbolIdEq(did, tid) {
          return recordDeclGenericNames(rd)
        }
      }
      case DKExposedRec(did, rd) -> {
        if symbolIdEq(did, tid) {
          return recordDeclGenericNames(rd)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  val empty: List[String] = newList()
  empty
}

// The record's fields *instantiated* against the receiver's type args
// (mirrors `caseFieldTypesInstantiated` for union cases): `value: T` on
// `Box[Int]` → `Int`.  Type params left unresolved after substitution
// (absent or partially-inferred receiver targs) are erased to `TyError` —
// the lenient wildcard — so an under-instantiated receiver degrades to the
// pre-instantiation behaviour instead of tripping false T0030-style
// diagnostics on a raw `TyVar`.
func fieldsOfRecordInstantiated(tbl: in SymbolTable, tid: in SymbolId, targs: in List[Type]): List[FieldEntry] {
  val raw = fieldsOfRecord(tbl, tid)
  val gnames = recordGenericNamesOf(tbl, tid)
  val result: List[FieldEntry] = newList()
  var i = 0
  while i < raw.count {
    result.add(FieldEntry(name = raw[i].name, ty = eraseTyVars(substituteTyVars(raw[i].ty, gnames, targs))))
    i = i + 1
  }
  result
}

// The type parameter of the enclosing generic that field `name` of the record
// instance `recv` has, when the record declares the field as its own type
// parameter and the instance is at one of `genericNames`; `TyError` otherwise.
func rigidTypeParamField(tbl: in SymbolTable, recv: in Type, name: in String, genericNames: in List[String]): Type {
  match unrefine(recv) {
    case TyUser(tid, _, targs) -> {
      val gnames = recordGenericNamesOf(tbl, tid)
      val raw = fieldsOfRecord(tbl, tid)
      var i = 0
      while i < raw.count {
        if raw[i].name == name {
          match raw[i].ty {
            case TyVar(g) -> {
              var gi = 0
              while gi < gnames.count and gi < targs.count {
                if gnames[gi] == g {
                  match targs[gi] {
                    case TyVar(n) -> if genericNames.contains(n) { return TyVar(n) }
                    case _ -> ()
                  }
                }
                gi = gi + 1
              }
            }
            case _ -> ()
          }
        }
        i = i + 1
      }
      TyError
    }
    case _ -> TyError
  }
}

// A field of an opaque type declared in this package, instantiated against
// the receiver's arguments: its representation is visible here, so a read
// is typed like a record field's, `array[N, Int]` at the instance's length
// included (#8149).  Outside its package the type has no readable fields.
func ownOpaqueFieldType(tbl: in SymbolTable, tid: in SymbolId, targs: in List[Type], name: in String): Option[Type] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKOpaque(did, od) -> if symbolIdEq(did, tid) and not tbl.symbols[i].isImported {
        return opaqueFieldTypeOf(tbl, od, targs, name)
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

func opaqueFieldTypeOf(tbl: in SymbolTable, od: in OpaqueTypeDecl, targs: in List[Type], name: in String): Option[Type] {
  val gnames = extractGenericNames(od.generics)
  val ctx = newGenericContext()
  gctxPush(ctx, gnames)
  val scratch: List[Diagnostic] = newList()
  for m in od.members {
    match m {
      case OMField(fd) -> if fd.name == name {
        return Some(value = eraseTyVars(substituteTyVars(resolveType(tbl, ctx, scratch, fd.ty), gnames, targs)))
      }
      case OMInvariant(_) -> ()
    }
  }
  None
}

func extractRecordFields(tbl: in SymbolTable, rd: in RecordDecl, result: in List[FieldEntry]): Unit {
  val ctx = newGenericContext()
  // Register the record's own type params so a `value: T` field resolves to
  // `TyVar("T")` (substitutable by `fieldsOfRecordInstantiated`) instead of a
  // swallowed unknown-type `TyError`.
  gctxPush(ctx, recordDeclGenericNames(rd))
  val dummyDiag: List[Diagnostic] = newList()
  var i = 0
  while i < rd.members.count {
    match rd.members[i] {
      case RMField(fd) -> {
        val t = resolveType(tbl, ctx, dummyDiag, fd.ty)
        result.add(FieldEntry(name = fd.name, ty = t))
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// Is `t` the bottom type `Never`?  A `Never` branch (one that diverges via
// `return`/`throw`/`break`/`continue` or `panic`) is absorbed in branch
// unification: the `if`/`match` takes the *other* branch's type.
func isNeverType(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }
    case _ -> false
  }
}

// Type an `ExprOrBlock` (an `if`/`match` branch body): a bare expression via
// `inferExpr`, a brace block via the divergence-aware `checkBlock` (D081), which
// threads the enclosing function's `returnTy`/`genericNames` off the scope.
// #3362 follow-up (#6559): both arms below used to hardcode value position
// (`true`/an implicit always-value `inferExpr` dispatch) regardless of the
// caller's real position. That's fine when the `ExprOrBlock` genuinely is
// the value (a match arm body, an if used as a value, ...), but an
// `EOBExpr` wrapping a bare `EIf`/`EMatch` is an "else if"/chained-match
// continuation of the SAME construct the caller is already
// unifying — not an independently value-consumed sub-expression — and an
// `EOBBlock` whose own trailing statement is an `EIf`/`EMatch` is the exact
// same shape one level of braces removed. Either hardcoding `true` here
// silently re-escalates a statement-position (discarded) if/match chain
// back to value position one level down, raising a spurious T0067 on a
// Unit-vs-non-Unit branch pair that is actually discarded. `checkBlock`
// already threads `valuePos and isLast` correctly for a block's OWN
// trailing statement, so the `EOBBlock` arm just needs the caller's real
// `isValuePosition` instead of a hardcoded `true`; the `EOBExpr` arm needs
// the same forwarding since `inferExpr`'s own generic `EIf`/`EMatch` cases
// hardcode `true` for use OUTSIDE this chaining context.
// #7696: `tailExpected` is the type the value of this `if`/`match` arm is
// expected to have: the enclosing FUNCTION's declared return type when the arm
// is genuinely part of the function's return-value chain (threaded from
// `checkFunctionBody`/`checkBlock`'s own trailing-statement dispatch), or —
// #7752 — the declared type of the position an `if`/`match`/block sits in when
// it is reached through `inferExprExpected` (a `return`, an annotated
// binding, an assignment, a call argument, a record field).  It is `TyError`
// ("no expectation") for an `if`/`match` used as an UNANNOTATED
// subexpression (`val x = if …`), which must keep inferring a bracket-literal
// arm as `slice[T]` exactly as before: typing it against an unrelated
// caller's return type would silently disagree with codegen, which only ever
// consults the position's OWN declared type (`collExpectTop`, the
// annotation/parameter/field construction hints).  The arm's value is typed
// against it (`inferExprExpected`), and the arms are then checked against it
// (`branchesAgainstExpected`) rather than joined bottom-up.  See the matching
// `inferIfExpr`/`inferMatchExpr`/`checkBlock` comments for the full chain.
pub func inferExprOrBlock(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  eob: in ExprOrBlock,
  isValuePosition: in Bool,
  tailExpected: in Type,
): Type {
  match eob {
    case EOBExpr(ex) -> match ex.kind {
      case EIf(cond, thenBranch, elseBranch, _) -> inferIfExpr(
        sc,
        tbl,
        sigs,
        diag,
        ex,
        cond,
        thenBranch,
        elseBranch,
        isValuePosition,
        tailExpected
      )
      case EMatch(scrutinee, arms) -> inferMatchExpr(
        sc,
        tbl,
        sigs,
        diag,
        ex,
        scrutinee,
        arms,
        isValuePosition,
        tailExpected
      )
      // #7696: an arm's bare-expr body (`case A -> [1, 2, 3]`, or the
      // then-form `if c then [1, 2, 3] else [4, 5, 6]`) is exactly the
      // "trailing/implicit value of a block body" case for the arm itself —
      // `inferExprExpected` degrades to plain `inferExpr` whenever
      // `tailExpected` is `TyError`, so this is a strict superset of the old
      // unconditional `inferExpr` call, never a behaviour change for a
      // non-tail arm.
      case _ -> inferExprExpected(sc, tbl, sigs, diag, ex, tailExpected)
    }
    case EOBBlock(bl) -> checkBlock(
      sc,
      tbl,
      sigs,
      sc.genericNames,
      sc.returnTy,
      sc.returnTyExpr,
      diag,
      bl,
      isValuePosition,
      tailExpected
    )
  }
}

func isUnitType(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtUnit -> true; case _ -> false }
    case _ -> false
  }
}

// Does `name` begin with an ASCII uppercase letter (the UpperCamelCase
// module/type naming convention)?  Used to distinguish a module-reference
// receiver (`Str.foo`) from a value receiver (`str.foo`) so the former can be
// treated leniently while a lowercase typo still errors.
func startsUppercase(name: in String): Bool {
  if name.length == 0 {
    return false
  }
  val c = name[0]
  c >= 'A' and c <= 'Z'
}

// Unify two branch types (the arms of an `if`/`match`).  `Never` and `TyError`
// are absorbed (the other branch wins), so an early-exit branch never forces a
// false mismatch and an already-diagnosed branch does not cascade.  When either
// branch produces **no value** (`Unit` — e.g. it ends in an assignment or a
// `Unit`-returning call), the construct is being used statement-like: its value
// is discarded, so the branches need not agree and the result is `Unit`.  This
// matters because the type checker cannot distinguish statement position from
// value position, and a statement-position `if c { x = 1 } else { f() }` (where
// `f()` returns a non-`Unit` value that is discarded) is perfectly valid.  Only
// two *value*-producing branches with **distinct non-`Unit`** types are a real
// mismatch (T0067) — e.g. `if c { 1 } else { "s" }`.
// True when `t` unrefines to exactly `Int`.
func unrefinesToInt(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtInt -> true; case _ -> false }
    case _ -> false
  }
}

// True when `t` unrefines to exactly `Long`.
func unrefinesToLong(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtLong -> true; case _ -> false }
    case _ -> false
  }
}

// Branch reconciliation for Rust-style integer-literal inference: when two
// `match`/`if` branches differ only because one carries the literal-default
// `Int` where the other has `Long`, widen toward `Long` (a lossless
// widening, and the type the value almost always wants — e.g. a `colLong`
// helper whose `case _ -> 0` default sits beside `Long` arms, or an
// `if rows.count == 0 { Ok(0) } else { … Ok(v) }` whose `Ok(0)` sits beside
// `Ok(v: Long)`).  Recurses through a shared generic head so `Result[Int, E]`
// reconciles with `Result[Long, E]` (#2514).  Returns `None` when the types
// are not an Int/Long pair (or generic over one), leaving `unifyBranchTypes`
// to raise its usual T0067.
func mergeIntWiden(a: in Type, b: in Type): Option[Type] {
  if unrefinesToInt(a) and unrefinesToLong(b) {
    return Some(value = b)
  }
  if unrefinesToInt(b) and unrefinesToLong(a) {
    return Some(value = a)
  }
  match unrefine(a) {
    case TyUser(aid, an, aargs) -> match unrefine(b) {
      case TyUser(bid, _, bargs) -> {
        if symbolIdEq(aid, bid) and aargs.count == bargs.count {
          val merged: List[Type] = newList()
          var allOk = true
          var i = 0
          while i < aargs.count {
            if typeEquiv(aargs[i], bargs[i]) {
              merged.add(aargs[i])
            } else {
              match mergeIntWiden(aargs[i], bargs[i]) {
                case Some(m) -> merged.add(m)
                case None -> {
                  allOk = false
                  merged.add(aargs[i])
                }
              }
            }
            i = i + 1
          }
          if allOk {
            return Some(value = TyUser(id = aid, name = an, args = merged))
          }
          return None
        }
        None
      }
      case _ -> None
    }
    case _ -> None
  }
}

// #7752: true when `t` mentions no wildcard — no `TyVar`, `TyError` or
// `TySelf` anywhere inside it.  `typeEquiv` treats every one of those as
// equivalent to anything, so checking branches against a NON-closed expected
// type (a generic function's `T`, an unresolved annotation) would accept
// `if c { 1 } else { "s" }`; only a closed expectation may drive
// `branchesAgainstExpected`/`adoptUnionCaseExpected`.
func typeIsClosed(t: in Type): Bool {
  match t {
    case TyVar(_) -> false
    case TyError -> false
    case TySelf -> false
    case TyUser(_, _, args) -> typesAreClosed(args)
    case TySlice(e) -> typeIsClosed(e)
    case TyArray(_, e, _) -> typeIsClosed(e)
    case TyNullable(inner) -> typeIsClosed(inner)
    case TyTuple(elems) -> typesAreClosed(elems)
    case TyFunction(ps, ret, _) -> typesAreClosed(ps) and typeIsClosed(ret)
    case TyRefined(u, _, _, _, _) -> typeIsClosed(u)
    case _ -> true
  }
}

func typesAreClosed(ts: in List[Type]): Bool {
  var i = 0
  while i < ts.count {
    if not typeIsClosed(ts[i]) {
      return false
    }
    i = i + 1
  }
  true
}

// #7752: check an `if`/`match`'s branch types against the type its position
// expects (a declared return type, an annotated binding, a parameter, …)
// instead of joining them bottom-up.  When every branch that yields a value
// satisfies `expected` — `Never` (diverging) and `TyError` (already
// diagnosed) branches are absorbed, exactly as in `unifyBranchTypes` — the
// construct has type `expected`: `if c { English(…) } else { French(…) }`
// is a `Greeter` wherever a `Greeter` is expected, even though the two
// branches have no common type of their own.  Returns `None` (the caller
// then falls back to the bottom-up `unifyBranchTypes` join, with its usual
// T0067 for genuinely incompatible branches) when there is no closed
// expectation, when every branch diverges, or when any branch does not
// satisfy the expectation — so this only ever ACCEPTS more programs whose
// every branch already fits the consumer, never changes a diagnostic.
//
// The relation is `argSatisfiesParam` (exact match, numeric widening,
// interface subsumption, the empty-literal sentinel), deliberately NOT the
// generic-covariant `typeAssignable`: a `Result[English, E]` VALUE is a
// different runtime instantiation from `Result[Greeter, E]` on the CLR
// (generics are invariant), so it must not silently become one here.  A
// union-case CONSTRUCTION in a branch (`Ok(value = English(…))`) is instead
// typed at the expected instantiation up front by `adoptUnionCaseExpected`,
// matching how codegen builds it (`buildGenericCaseCtorTok`'s context type
// arguments), and so satisfies this check by plain equivalence.
func branchesAgainstExpected(tbl: in SymbolTable, branchTypes: in List[Type], expected: in Type): Option[Type] {
  if not typeIsClosed(expected) {
    return None
  }
  var anyValue = false
  var i = 0
  while i < branchTypes.count {
    val bt = branchTypes[i]
    if not isNeverType(bt) {
      val isErr = match bt { case TyError -> true; case _ -> false }
      if not isErr and not argSatisfiesParam(tbl, expected, bt) {
        return None
      }
      anyValue = true
    }
    i = i + 1
  }
  if anyValue {
    Some(value = expected)
  } else {
    None
  }
}

// #7752: may a union-case construction whose inferred type arguments are
// `actualArgs` be typed at the expected instantiation `expectedArgs`?  Each
// slot must either already agree (`typeEquiv`, which also fills an
// unconstrained `TyError` slot such as `Ok`'s `E`) or be a NON-generic
// interface the inferred argument implements.  This mirrors exactly which
// instantiation both backends build: MSIL's `buildGenericCaseCtorTok`
// constructs the case at the CONTEXT's type argument unless that argument is
// itself a generic instantiation (then it keeps the argument's own type), so
// `Ok(value = English(…))` against `Result[Greeter, String]` really is an
// `Ok<Greeter, String>`, while `Ok(value = someList)` against
// `Result[List[Greeter], E]` is not and must not be typed as if it were.  JVM
// generics are erased, so any instantiation the MSIL rule accepts is sound
// there too.
func unionCaseArgsAdoptable(tbl: in SymbolTable, expectedArgs: in List[Type], actualArgs: in List[Type]): Bool {
  if expectedArgs.count != actualArgs.count {
    return false
  }
  var i = 0
  while i < expectedArgs.count {
    if not typeEquiv(expectedArgs[i], actualArgs[i]) {
      val ok = match unrefine(expectedArgs[i]) {
        case TyUser(eid, _, eargs) -> if eargs.count == 0 {
          match unrefine(actualArgs[i]) {
            case TyUser(aid, _, _) -> symTableTypeImplements(tbl, aid, eid)
            case _ -> false
          }
        } else {
          false
        }
        case _ -> false
      }
      if not ok {
        return false
      }
    }
    i = i + 1
  }
  true
}

// #7752: type a union-case construction (`isCaseCtor`) at the expected
// instantiation of its own union when `unionCaseArgsAdoptable` allows it, so
// `Ok(value = English(…))` checked against `Result[Greeter, String]` is a
// `Result[Greeter, String]` — not `Result[English, <error>]`, whose
// unconstrained `E` would otherwise stay a wildcard and whose `T` would never
// satisfy a binding/argument position's (non-covariant) check.  Anything else
// keeps its inferred type.
func adoptUnionCaseExpected(tbl: in SymbolTable, isCaseCtor: in Bool, actual: in Type, expected: in Type): Type {
  if not isCaseCtor or not typeIsClosed(expected) {
    return actual
  }
  match unrefine(expected) {
    case TyUser(eid, _, eargs) -> match unrefine(actual) {
      case TyUser(aid, _, aargs) -> if symbolIdEq(eid, aid) and unionCaseArgsAdoptable(tbl, eargs, aargs) {
        expected
      } else {
        actual
      }
      case _ -> actual
    }
    case _ -> actual
  }
}

// #3362: `isValuePosition` distinguishes an if/match whose result is
// actually consumed (bound to a `val`/`let`/`var`, returned, passed as an
// argument, …) from one used purely as a statement (its value discarded).
// In statement position, two Unit-typed branches (or a Unit branch beside
// one that never runs) is the routine, sound case — absorb silently, as
// before. In value position, one branch producing Unit while the other
// produces a real value is a genuine mismatch (the caller can't use
// "sometimes nothing" as a value), so it raises the same T0067 the general
// incompatible-branch-types case raises rather than silently collapsing to
// `Unit`. Both branches being Unit is never an error, in either position —
// it's the *lone* Unit branch beside a non-Unit branch that value position
// must catch.
func unifyBranchTypes(a: in Type, b: in Type, span: in Span, diag: in List[Diagnostic], isValuePosition: in Bool): Type {
  if isNeverType(a) {
    return b
  }
  if isNeverType(b) {
    return a
  }
  match a {
    case TyError -> {
      return b
    }
    case _ -> {
    }
  }
  match b {
    case TyError -> {
      return a
    }
    case _ -> {
    }
  }
  val aUnit = isUnitType(a)
  val bUnit = isUnitType(b)
  if aUnit and bUnit {
    return TyPrim(pt = PtUnit)
  }
  if aUnit or bUnit {
    if not isValuePosition {
      return TyPrim(pt = PtUnit)
    }
    diag.add(
      errorDiagnostic(
        "T0067",
        "incompatible branch types: one branch has type " + renderType(a) + ", the other " + renderType(b),
        span
      )
    )
    return TyError
  }
  // Each branch may leave a different type argument open (`if c { Err(error
  // = "z") } else { Ok(value = "abc") }`): the join takes each from whichever
  // branch fixes it (#8181).
  if typeEquiv(a, b) {
    joinOpenTypes(a, b)
  } else {
    match mergeIntWiden(a, b) {
      case Some(t) -> t
      case None -> {
        diag.add(
          errorDiagnostic(
            "T0067",
            "incompatible branch types: one branch has type " + renderType(a) + ", the other " + renderType(b),
            span
          )
        )
        // Yield `TyError` (the universal unifier), not one arm's type, so the
        // containing expression context does not cascade follow-on diagnostics off
        // an arbitrary pick (#2099).
        TyError
      }
    }
  }
}

// #6496: strict typing for method-spelling `.indexOf`/`.lastIndexOf` on a
// String receiver.  With `import Std.String` in the file's scope (either
// import form — `collectImportNames` records the dotted path regardless of
// an `as` alias), the method spelling is the UFCS form of the
// Option[Int]-returning Std.String free functions on both targets, so it
// types as `(String) -> Option[Int]`.  Without the import it is the
// documented raw host binding, `(String) -> Int` (-1 sentinel).  Typed as a
// real `TyFunction` (the slice-method precedent above) so the `ECall` arm's
// arg validation runs.  Previously this shape was TyError-lenient, which is
// how the backends' Int/Option semantics could diverge silently.
func stringIndexOfMember(tbl: in SymbolTable, name: in String): Option[Type] {
  if name != "indexOf" and name != "lastIndexOf" {
    return None
  }
  val ps: List[Type] = newList()
  ps.add(TyPrim(pt = PtString))
  if listContainsStr(tbl.scopeImports, "Std.String") {
    // #7737: the Std.String functions return `Std.Core.Option`; resolve it by
    // owning package so a package's own `union Option` never types the call.
    match symTableTryFindInPackage(tbl, "Std.Core", "Option") {
      case Some(sym) -> match symbolTypeIdOpt(sym) {
        case Some(tid) -> {
          val targs: List[Type] = newList()
          targs.add(TyPrim(pt = PtInt))
          return Some(value = TyFunction(params = ps, ret = TyUser(id = tid, name = "Option", args = targs), isAsync = false))
        }
        case None -> ()
      }
      case None -> ()
    }
    // Std.String is imported but `Option` is not resolvable from the item
    // pool (a contract-surface or otherwise partial check) — keep the
    // historical leniency rather than fabricate a SymbolId.
    return None
  }
  Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtInt), isAsync = false))
}

// #7335: real `TyFunction` types for the rest of the documented `String`
// host-method surface (docs/01 §12.1) that both backends' hardcoded
// `String`-method dispatch cascades implement (`lyric-compiler/msil/codegen.l`,
// `lyric-compiler/jvm/codegen/04_calls.l`).  Before this, every one of these
// names (`substring`, `trim`, `toLower`, `replace`, ...) fell through
// `builtinMember`'s `TyPrim(PtString)` arm (which only ever knew `length`/
// `isEmpty`) to `TyError` — the universal unifier — so a call like
// `s.substring(0, 2)` type-checked with NO arg validation and its result
// silently unified with whatever the caller expected next, hiding every
// downstream check (the repro: `.indexOf`'s `Option[Int]`-vs-`Int` mismatch
// went undiagnosed). `.indexOf`/`.lastIndexOf` stay in `stringIndexOfMember`
// above (import-sensitive return type); `.length`/`.isEmpty` stay bare
// field-style types in `builtinMember` (no call syntax, so no arg
// validation is needed). Deliberately NOT a general "unknown String method"
// allowlist/diagnostic — D-progress-971 found that shape unsound (JVM's
// `String` method surface is open via auto-FFI against real
// `java.lang.String` metadata for names outside this list, e.g.
// `.getBytes()`; MSIL's is closed). A name this function does not recognise
// returns `None` and keeps falling through to `builtinMember`/`TyError`
// exactly as before, so an unmapped method call keeps whatever leniency it
// had — no new false positive for JVM's wider surface.
func stringHostMethodType(name: in String): Option[Type] {
  val strT = TyPrim(pt = PtString)
  val boolT = TyPrim(pt = PtBool)
  val intT = TyPrim(pt = PtInt)
  if name == "substring" {
    // `s.substring(start)` / `s.substring(start, count)`: both params are
    // declared so the arg-type check runs on either arity, and the second
    // (`count`) is the one optional trailing arg `builtinOptionalTrailingArgs`
    // recognises for this member name below.
    val ps: List[Type] = newList()
    ps.add(intT)
    ps.add(intT)
    return Some(value = TyFunction(params = ps, ret = strT, isAsync = false))
  }
  if name == "trim" or name == "trimStart" or name == "trimEnd" or name == "toLower" or name == "toUpper" or name == "normalize" {
    val ps: List[Type] = newList()
    return Some(value = TyFunction(params = ps, ret = strT, isAsync = false))
  }
  if name == "isNormalized" {
    val ps: List[Type] = newList()
    return Some(value = TyFunction(params = ps, ret = boolT, isAsync = false))
  }
  if name == "replace" {
    val ps: List[Type] = newList()
    ps.add(strT)
    ps.add(strT)
    return Some(value = TyFunction(params = ps, ret = strT, isAsync = false))
  }
  if name == "contains" or name == "startsWith" or name == "endsWith" {
    val ps: List[Type] = newList()
    ps.add(strT)
    return Some(value = TyFunction(params = ps, ret = boolT, isAsync = false))
  }
  if name == "codeUnitAt" {
    // `s.codeUnitAt(i)`: the raw code unit at index `i` as an `Int` (a UTF-16
    // unit on .NET/JVM, a UTF-8 byte on native) -- the one accessor that can
    // observe a surrogate half, which `s[i]: Char` rejects (D-progress-1006).
    val ps: List[Type] = newList()
    ps.add(intT)
    return Some(value = TyFunction(params = ps, ret = intT, isAsync = false))
  }
  if name == "split" {
    // `Std.String.split(s, sep): slice[String]` (`lyric-stdlib/std/string.l`)
    // — the one implementation both backends' method-syntax `.split(sep)`
    // route through (docs/01 §12.1).
    val ps: List[Type] = newList()
    ps.add(strT)
    return Some(value = TyFunction(params = ps, ret = TySlice(element = strT), isAsync = false))
  }
  None
}

// #7737: is `tid` the stdlib `Std.CollectionsHost` type called `name`
// (`List`, `Map`, `MapKeyCollection`, `MapValueCollection`)?  Every
// semantic "is this the stdlib collection?" check goes through here rather
// than comparing the `TyUser`'s bare name: codegen treats these receivers as
// the genuine BCL/JDK collection, so a package's own same-named type must
// never be classified as one.  The type is resolved by its owning package,
// never its (shadowable) bare name -- the precedent `isStdCoreMonadType` sets
// for `Std.Core.Result`/`Option` (#7665).  `extern type List[T]` and its
// siblings are declared in `Std.CollectionsHost` on BOTH targets
// (`lyric-stdlib/std/_kernel/collections_host.l` for dotnet, the
// `_kernel_jvm` twin for the JVM) and `Std.Collections` re-exports them, so
// the resolution is independent of the current file's own imports or any
// same-named local type.  The ids are memoised per symbol table
// (`symTableStdCollectionsHostTypeId`, #7765).
func isStdCollectionsHostType(tbl: in SymbolTable, tid: in SymbolId, name: in String): Bool {
  match symTableStdCollectionsHostTypeId(tbl, name) {
    case Some(sid) -> symbolIdEq(sid, tid)
    case None -> false
  }
}

// Field / builtin member typing only — no method-space consultation and no
// unknown-member diagnostics.  The `ECall` arm uses this directly for a
// member callee (methods are resolved arity-aware there); the plain `EMember`
// arm goes through `inferMember`, which layers method references and the A5
// unknown-member diagnostic on top.
func inferMemberBase(tbl: in SymbolTable, recvRaw: in Type, name: in String): Type {
  val recv = unrefine(recvRaw)
  match recv {
    case TyUser(tid, _, targs) -> {
      val fs = fieldsOfRecordInstantiated(tbl, tid, targs)
      var i = 0
      while i < fs.count {
        if fs[i].name == name {
          return fs[i].ty
        }
        i = i + 1
      }
      match ownOpaqueFieldType(tbl, tid, targs, name) {
        case Some(ot) -> return ot
        case None -> ()
      }
      // Builtin members on nominal receivers (`List.toArray`/`count`, #2126)
      // — consulted after fields so a same-named user field wins.
      match builtinMember(tbl, recv, name) {
        case Some(t) -> t
        case None -> TyError
      }
    }
    case TyError -> TyError
    case _ -> {
      // `slice[T].toList()` (#2050 gotcha, cloud-agents docs/lyric/gotchas.md):
      // the round-trip shuttle back from `List[T].toArray()`.  Its result
      // type is a genuine `List[elem]`, which — unlike `builtinMember`'s
      // other slice methods, deliberately typed via structural `TySlice` to
      // sidestep exactly this — needs `List`'s real `SymbolId` for the checker
      // to accept it where a `List[T]` is expected (a field, a `val`
      // annotation, a call argument).  `builtinMember` has no `tbl` to look
      // that SymbolId up with, so it is handled here instead.
      //
      // #7665: an earlier revision resolved `List` via a bare, shadowable
      // name lookup (`symTableTryFindOne(tbl, "List")`) — a package
      // declaring its own type named `List` would shadow the stdlib one for
      // that lookup, but `lowerSliceToListMsil` unconditionally constructs a
      // genuine BCL `List<E>` at runtime regardless of what the checker
      // resolved "List" to.  Worse, the shadowed case didn't even fail
      // cleanly: the fallback (no match) returns `TyError`, and `typeEquiv`
      // treats `TyError` as equal to anything, so a `val` binding with any
      // declared type would silently accept it and crash with
      // `InvalidCastException` at runtime instead of failing to compile.
      // `isStdCollectionsHostType` fixes both problems the same way
      // `isStdCoreMonadType` above does for `Std.Core.Result`/`Option`:
      // resolve the STDLIB's List by its OWN owning package
      // (`Std.CollectionsHost`), never by a bare, shadowable name, so
      // `.toList()` always type-checks as the genuine stdlib collection
      // codegen actually builds — with no dependence on the current file's
      // imports (`Lyric.Pipeline` preloads every stdlib package's
      // signatures) and no shadow can ever intercept it.
      match recv {
        case TySlice(elem) -> {
          if name == "toList" {
            match symTableStdCollectionsHostTypeId(tbl, "List") {
              case Some(tid) -> {
                val noParams: List[Type] = newList()
                val targs: List[Type] = newList()
                targs.add(elem)
                return TyFunction(params = noParams, ret = TyUser(id = tid, name = "List", args = targs), isAsync = false)
              }
              case None -> {
              }
            }
          }
        }
        case _ -> {
        }
      }
      // Strict String `.indexOf`/`.lastIndexOf` typing (#6496) and the rest
      // of the documented host-method surface (#7335) — consulted before
      // the generic builtin table because `.indexOf`/`.lastIndexOf`'s
      // result depends on the file's imports, which `builtinMember` does
      // not see, and because the other names need a real `TyFunction` (not
      // `builtinMember`'s bare-type shape) for the `ECall` arm's arg
      // validation to run.
      match recv {
        case TyPrim(mbPt) -> match mbPt {
          case PtString -> {
            match stringIndexOfMember(tbl, name) {
              case Some(sit) -> return sit
              case None -> ()
            }
            match stringHostMethodType(name) {
              case Some(smt) -> return smt
              case None -> ()
            }
          }
          case _ -> ()
        }
        case _ -> ()
      }
      match builtinMember(tbl, recv, name) {
        case Some(t) -> t
        case None -> TyError
      }
    }
  }
}

// #7771: note whether the call at `span` binds to a generator (a yield-bearing
// `async func`).  The `ECall` arm clears the entry, then sets it from the
// signature it actually binds -- the direct signature or the method pick --
// so a call that binds to neither (a function value, a constructor, an
// unresolved callee) is never a generator call, and a re-inference of the
// same call (the deferred-argument pass) leaves the last resolution's answer.
func recordGeneratorCallSite(tbl: in SymbolTable, span: in Span, isGen: in Bool): Unit {
  val key = recordCopySiteKey(span)
  if isGen {
    if not tbl.generatorCallSites.containsKey(key) {
      tbl.generatorCallSites.add(key, true)
    }
  } else if tbl.generatorCallSites.containsKey(key) {
    tbl.generatorCallSites.remove(key)
  }
}

// #7838: note whether the call at `span` binds to an `async func` that is not
// a generator.  Cleared and set by the `ECall` arm exactly like
// `recordGeneratorCallSite`, so a re-inference of the same call leaves the
// last resolution's answer.
func recordAsyncCallSite(tbl: in SymbolTable, span: in Span, isAsyncCall: in Bool): Unit {
  val key = recordCopySiteKey(span)
  if isAsyncCall {
    if not tbl.asyncCallSites.containsKey(key) {
      tbl.asyncCallSites.add(key, true)
    }
  } else if tbl.asyncCallSites.containsKey(key) {
    tbl.asyncCallSites.remove(key)
  }
}

// D149: note whether the call at `span` binds to an `@io` function or a
// protected type's `entry`.  Cleared and set like `recordAsyncCallSite`, so a
// re-inference of the same call keeps only the last resolution's answer.
func recordEffectCallSite(tbl: in SymbolTable, span: in Span, sig: in ResolvedSignature, callee: in Expr): Unit {
  val key = recordCopySiteKey(span)
  if tbl.effectCallSites.containsKey(key) {
    tbl.effectCallSites.remove(key)
  }
  if sig.isIo or sig.isEntry {
    tbl.effectCallSites.add(key, EffectCallSite(span = span, callee = calleeText(callee), isEntry = sig.isEntry))
  }
}

func clearEffectCallSite(tbl: in SymbolTable, span: in Span): Unit {
  val key = recordCopySiteKey(span)
  if tbl.effectCallSites.containsKey(key) {
    tbl.effectCallSites.remove(key)
  }
}

// The callee of a call as written: `f`, `Pkg.f`, `x.m`.
func calleeText(e: in Expr): String {
  match e.kind {
    case EPath(p) -> modulePathJoin(p.segments)
    case EMember(recv, name) -> {
      val r = calleeText(recv)
      if r == "" {
        name
      } else {
        r + "." + name
      }
    }
    case EParen(inner) -> calleeText(inner)
    case _ -> ""
  }
}

// #7801: note whether the call at `span` binds to one of the stdlib's
// evidence-free collection constructors (see
// `SymbolTable.emptyCollectionCtorSites`).  Cleared and set by the `ECall`
// arm exactly like `recordGeneratorCallSite`, so a re-inference of the same
// call leaves the last resolution's answer.
func recordEmptyCollectionCtorSite(tbl: in SymbolTable, span: in Span, isCtor: in Bool): Unit {
  val key = recordCopySiteKey(span)
  if isCtor {
    if not tbl.emptyCollectionCtorSites.containsKey(key) {
      tbl.emptyCollectionCtorSites.add(key, true)
    }
  } else if tbl.emptyCollectionCtorSites.containsKey(key) {
    tbl.emptyCollectionCtorSites.remove(key)
  }
}

// Is `sig`, the signature a call through callee `fn` bound to, one of
// `Std.CollectionsHost`'s `newList` / `newListWithCapacity` / `newMap`?  The
// declaring package comes from the resolved signature; the callee's spelling
// only names which of that package's functions it is.
func isStdEmptyCollectionCtor(sig: in ResolvedSignature, fn: in Expr): Bool {
  if sig.originPackage != "Std.CollectionsHost" {
    return false
  }
  val name = lastNameOfPathExpr(fn)
  name == "newList" or name == "newListWithCapacity" or name == "newMap"
}

// Method names that resolve on essentially any receiver at codegen time
// even though no source-level signature exists at type-check time:
// `toString` is a codegen intrinsic on every receiver, and the rest are
// `@derive`/`@generate`-synthesised type-associated functions — the derive
// pass runs AFTER the type checker (`pipeCheckAndMono` order), so their
// `T.equals`-style signatures are not yet in `sigs` when the checker runs.
func isUniversalMethodName(name: in String): Bool {
  name == "toString" or name == "equals" or name == "hash" or name == "show" or name == "compare" or name == "toJson"
}

// Substitute the receiver into a stored method signature: `Self` becomes the
// receiver type, and the owner's generic params are replaced by the
// receiver's type args when the arities line up (a raw/under-instantiated
// receiver leaves them as `TyVar` wildcards — lenient).
func substituteMethodSig(entry: in MethodEntry, recv: in Type, targs: in List[Type]): ResolvedSignature {
  val doSub = entry.ownerGenerics.count > 0 and entry.ownerGenerics.count == targs.count
  val np: List[ResolvedParam] = newList()
  var i = 0
  while i < entry.sig.params.count {
    val p = entry.sig.params[i]
    var ty = substitutesSelf(p.ty, recv)
    if doSub {
      ty = substituteTyVars(ty, entry.ownerGenerics, targs)
    }
    // #6467: `p.tyExpr` threads through Self/generic substitution unchanged —
    // substitution only ever rewrites a `Self` or owner-generic reference,
    // never the alias identity of an unrelated aliased annotation, so pairing
    // the original `tyExpr` with the substituted `ty` for display stays sound.
    np.add(
      ResolvedParam(
        name = p.name,
        ty = ty,
        mode = p.mode,
        hasDefault = p.hasDefault,
        span = p.span,
        tyExpr = p.tyExpr,
        defaultInert = p.defaultInert,
        defaultUnavailable = p.defaultUnavailable
      )
    )
    i = i + 1
  }
  var rty = substitutesSelf(entry.sig.returnTy, recv)
  if doSub {
    rty = substituteTyVars(rty, entry.ownerGenerics, targs)
  }
  ResolvedSignature(
    generics = entry.sig.generics,
    bounds = entry.sig.bounds,
    params = np,
    returnTy = rty,
    isAsync = entry.sig.isAsync,
    isHot = entry.sig.isHot,
    isGenerator = entry.sig.isGenerator,
    originPackage = entry.sig.originPackage,
    span = entry.sig.span,
    isPure = entry.sig.isPure,
    isIo = entry.sig.isIo,
    isEntry = entry.sig.isEntry,
    isExternFunc = entry.sig.isExternFunc
  )
}

// True when one of a type's own methods `own` implements the interface
// member `member`: same name (the caller's lookup key) and parameter count.
func methodImplementedBy(own: in List[MethodEntry], member: in MethodEntry): Bool {
  for e in own {
    if e.sig.params.count == member.sig.params.count {
      return true
    }
  }
  false
}

// Every method signature reachable on a value of type `recv` (an unrefined
// `TyUser`) under `name`: the type's own record-body/impl methods, plus the
// members of every interface it implements that the type does not implement
// itself (covers an interface default method a cross-package `impl`
// inherits).  An interface member the type implements is not a candidate: a
// call on the concrete type resolves through the implementing method, whose
// parameters (and defaults) are the ones the call gets (#7820).
// Receiver-substituted and call-facing.
func methodCandidatesFor(tbl: in SymbolTable, recv: in Type, name: in String): List[ResolvedSignature] {
  val acc: List[ResolvedSignature] = newList()
  match recv {
    case TyUser(tid, _, targs) -> {
      val entries = symTableMethodSigs(tbl, tid, name)
      var i = 0
      while i < entries.count {
        acc.add(substituteMethodSig(entries[i], recv, targs))
        i = i + 1
      }
      val noTargs: List[Type] = newList()
      var pi = 0
      while pi < tbl.impls.count {
        if symbolIdEq(tbl.impls[pi].target, tid) {
          val ientries = symTableMethodSigs(tbl, tbl.impls[pi].iface, name)
          var q = 0
          while q < ientries.count {
            if not methodImplementedBy(entries, ientries[q]) {
              acc.add(substituteMethodSig(ientries[q], recv, noTargs))
            }
            q = q + 1
          }
        }
        pi = pi + 1
      }
    }
    case _ -> {
    }
  }
  acc
}

// D037 type-associated functions (`func T.m(recv, ...)`) a call on a
// receiver of type `recv` with `argc` further arguments (`args`, of types
// `argTypes`; `args` may be empty when every argument is positional) may
// bind: every package's `T.m` whose FIRST param accepts the receiver and
// whose other parameters take `argc` arguments, defaults included, narrowed
// by `bindableDotNamed` (D181).  Returned as full signatures (receiver param
// included); the call site drops the receiver slot for argument validation
// and uses the full signature for return-type inference (a generic like
// `func Box.get[T](self: in Box[T]): T` binds `T` from the receiver).
func dotNamedCandidatesFor(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  recv: in Type,
  name: in String,
  argc: in Int,
  args: in List[CallArg],
  argTypes: in List[Type],
): List[ResolvedSignature] {
  val owner = dotNamedOwnerName(recv)
  if owner.length == 0 {
    return newList()
  }
  // Every package's `T.m`, generic ones included: the `sigs` slot keeps
  // the first registered, which may be another package's same-named type's
  // function (a caller's own `Box.set` beside a library's generic
  // `Box[T].set`, #8179); the receiver test keeps the ones declared on the
  // receiver's type.
  val key = owner + "." + name
  val arityKey = key + "/" + toString(argc + 1)
  val all = dotNamedSigsAnyArity(sigs, key)
  match mapGet(sigs, arityKey) {
    case Some(s) -> all.add(s)
    case None -> ()
  }
  for o in gatherOverloadCandidates(sigs, arityKey) {
    all.add(o)
  }
  val kept: List[ResolvedSignature] = newList()
  for c in all {
    if takesArgCount(c, argc + 1) and argSatisfiesParam(tbl, c.params[0].ty, recv) and not sigListHas(kept, c) {
      kept.add(c)
    }
  }
  // None takes that many arguments: the receiver's functions of the name
  // are kept so the call reports its arity against a real signature (T0042).
  if kept.count == 0 {
    for c in all {
      if c.params.count >= 1 and argSatisfiesParam(tbl, c.params[0].ty, recv) and not sigListHas(kept, c) {
        kept.add(c)
      }
    }
  }
  bindableDotNamed(tbl, recv, name, kept, argc, args, argTypes)
}

func takesArgCount(sig: in ResolvedSignature, n: in Int): Bool {
  sig.params.count >= 1 and n >= minRequiredParams(sig) and n <= sig.params.count
}

func sigListHas(sigs: in List[ResolvedSignature], s: in ResolvedSignature): Bool {
  for x in sigs {
    if x.originPackage == s.originPackage and sameSpan(x.span, s.span) and x.params.count == s.params.count {
      return true
    }
  }
  false
}

// Whether the full dot-named signature `sig` accepts a call's arguments
// after the receiver, by count and by type (D181's "applicable").
func dotNamedApplicable(
  tbl: in SymbolTable,
  sig: in ResolvedSignature,
  argc: in Int,
  args: in List[CallArg],
  argTypes: in List[Type],
): Bool {
  if not takesArgCount(sig, argc + 1) {
    return false
  }
  val dropped = dropReceiverParam(sig)
  suppliedArgsMatch(tbl, dropped.params, argTypesInSigOrder(dropped, 0, args, argTypes))
}

// Whether a method in the body of the receiver's type, or of an `impl` for
// it, accepts the call's arguments by count and type.
func ownBodyMethodApplicable(
  tbl: in SymbolTable,
  recv: in Type,
  name: in String,
  argc: in Int,
  args: in List[CallArg],
  argTypes: in List[Type],
): Bool {
  for m in methodCandidatesFor(tbl, unrefine(recv), name) {
    if argc >= minRequiredParams(m) and argc <= m.params.count and suppliedArgsMatch(tbl, m.params, argTypesInSigOrder(m, 0, args, argTypes)) {
      return true
    }
  }
  false
}

// Of the dot-named functions `cands` for a receiver of type `recv`, those a
// call with `argc` arguments besides the receiver binds (D181, #8219): the
// type's own (declared by its declaring package) when one of the type's
// own functions, those or a method in its body, is applicable — takes the
// call's arguments, types included — so an import never changes what an
// applicable own-method call means; otherwise the extensions, declared by
// other packages, that the file's imports reach at the nearest level
// (`dotNamedExtensionTier`), the applicable ones when there are any.
// Several packages left make the call ambiguous (`dotNamedAmbiguousPackages`).
func bindableDotNamed(
  tbl: in SymbolTable,
  recv: in Type,
  name: in String,
  cands: in List[ResolvedSignature],
  argc: in Int,
  args: in List[CallArg],
  argTypes: in List[Type],
): List[ResolvedSignature] {
  val ownPkg = match dotNamedDeclaringPackage(tbl, recv) { case Some(p) -> p; case None -> return cands }
  val own: List[ResolvedSignature] = newList()
  var ownApplies = ownBodyMethodApplicable(tbl, recv, name, argc, args, argTypes)
  val exts: List[ResolvedSignature] = newList()
  for c in cands {
    if sigPackage(tbl, c) == ownPkg {
      own.add(c)
      if dotNamedApplicable(tbl, c, argc, args, argTypes) {
        ownApplies = true
      }
    } else {
      exts.add(c)
    }
  }
  if ownApplies or exts.count == 0 {
    return own
  }
  var best = 3
  for x in exts {
    val t = dotNamedExtensionTier(tbl, sigPackage(tbl, x))
    if t >= 0 and t < best {
      best = t
    }
  }
  val nearest: List[ResolvedSignature] = newList()
  val applicable: List[ResolvedSignature] = newList()
  for x in exts {
    if dotNamedExtensionTier(tbl, sigPackage(tbl, x)) == best {
      nearest.add(x)
      if dotNamedApplicable(tbl, x, argc, args, argTypes) {
        applicable.add(x)
      }
    }
  }
  if nearest.count == 0 {
    return own
  }
  // An own function that takes the arguments' count but not their types is
  // still reported against when no extension applies either.
  if applicable.count > 0 {
    applicable
  } else if own.count > 0 {
    own
  } else {
    nearest
  }
}

// Every package's dot-named function `dotted` (`T.m`), of any arity.
func dotNamedSigsAnyArity(sigs: in Map[String, ResolvedSignature], dotted: in String): List[ResolvedSignature] {
  val acc: List[ResolvedSignature] = newList()
  match mapGet(sigs, dotted) {
    case Some(s) -> acc.add(s)
    case None -> ()
  }
  for c in gatherOverloadCandidates(sigs, byNameSigKey(dotted)) {
    acc.add(c)
  }
  acc
}

// The package that declares the type of a receiver `recv`, whose dot-named
// functions are the type's own; "" for a primitive, which every package may
// only extend, and `None` for a type whose declaration is not known here.
func dotNamedDeclaringPackage(tbl: in SymbolTable, recv: in Type): Option[String] {
  match unrefine(recv) {
    case TyUser(tid, _, _) -> match symTableTypeSymbolOf(tbl, tid) {
      case Some(sym) -> Some(
        value = if sym.originPackage.length == 0 {
          symTableScopePkg(tbl)
        } else {
          sym.originPackage
        }
      )
      case None -> None
    }
    case TyPrim(_) -> Some(value = "")
    case _ -> None
  }
}

// The package declaring `sig`, the current one when it records none.
func sigPackage(tbl: in SymbolTable, sig: in ResolvedSignature): String {
  if sig.originPackage.length == 0 {
    symTableScopePkg(tbl)
  } else {
    sig.originPackage
  }
}

// Whether `sig`, a dot-named function bound by a call on a receiver of type
// `recv`, extends the type from a package other than the one declaring it.
func isDotNamedExtension(tbl: in SymbolTable, recv: in Type, sig: in ResolvedSignature): Bool {
  match dotNamedDeclaringPackage(tbl, recv) {
    case Some(ownPkg) -> sigPackage(tbl, sig) != ownPkg
    case None -> false
  }
}

// How near an extension declared in package `origin` is to a call here, as
// the import rule orders bare names (§9.2): 0 for this package (or no import
// rule), 1 for a package imported whole, 2 for one reached only through a
// whole import's own whole imports, and -1 for one the imports do not reach
// (imported only under an alias or selectively, or not at all), whose
// extensions a method call never binds.
func dotNamedExtensionTier(tbl: in SymbolTable, origin: in String): Int {
  val curPkg = symTableScopePkg(tbl)
  if origin.length == 0 or origin == curPkg or curPkg.length == 0 or not symTableImportRuleApplies(tbl, curPkg) {
    return 0
  }
  if not tbl.importVisiblePkgs.containsKey(origin) {
    -1
  } else if symTableScopeAllows(tbl, origin) {
    1
  } else {
    2
  }
}

// The packages whose extensions `T.m` a method call `recv.m(<argc
// arguments>)` could equally bind, when there are several (#8219): each
// declares one at the nearest level the call's imports reach.  Empty when
// the call is not ambiguous.
func dotNamedAmbiguousPackages(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  recv: in Type,
  name: in String,
  argc: in Int,
  args: in List[CallArg],
  argTypes: in List[Type],
): List[String] {
  val pkgs: List[String] = newList()
  for c in dotNamedCandidatesFor(tbl, sigs, recv, name, argc, args, argTypes) {
    if takesArgCount(c, argc + 1) and isDotNamedExtension(tbl, recv, c) and not pkgs.contains(sigPackage(tbl, c)) {
      pkgs.add(sigPackage(tbl, c))
    }
  }
  if pkgs.count < 2 {
    return newList()
  }
  pkgs
}

// T0123 for a call of `T.m` that two or more packages' extensions could
// equally bind (#8219); `true` when reported.
func reportAmbiguousDotNamed(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  recv: in Type,
  name: in String,
  argc: in Int,
  args: in List[CallArg],
  argTypes: in List[Type],
  span: in Span,
): Bool {
  val pkgs = dotNamedAmbiguousPackages(tbl, sigs, recv, name, argc, args, argTypes)
  if pkgs.count < 2 {
    return false
  }
  val dotted = dotNamedOwnerName(recv) + "." + name
  diag.add(
    errorDiagnostic(
      "T0123",
      "'" + dotted + "' is ambiguous: it is declared by " + joinPackageNames(pkgs) +
        ", all reached through this file's imports, and not by the package declaring '" +
        dotNamedOwnerName(recv) +
        "' — call it through its package (e.g. '" +
        pkgs[0] +
        "." +
        dotted +
        "(...)')",
      span
    )
  )
  true
}

// The type name a dot-named function for a receiver of type `recv` is
// declared under: a user type's name (`func Box.get`), or a primitive's
// (`func Int.twice`, #8217); "" for a type no dot-named function names.
func dotNamedOwnerName(recv: in Type): String {
  match unrefine(recv) {
    case TyUser(_, tname, _) -> tname
    case TyPrim(pt) -> primName(pt)
    case _ -> ""
  }
}

// A method every backend lowers itself on a primitive receiver, which no
// signature types here: `toString()`, and the bitwise `and`/`or`/`xor`/`shl`/
// `shr` of an integer (#1610).  A dot-named function of the primitive with
// the same name does not capture the method call (#8217), as it does not
// capture one of the methods typed here (`toLong`, `trim`, ...).
func isPrimitiveIntrinsicMethod(recv: in Type, name: in String, argc: in Int): Bool {
  match unrefine(recv) {
    case TyPrim(pt) -> if name == "toString" and argc == 0 {
      true
    } else if argc == 1 and (name == "and" or name == "or" or name == "xor" or name == "shl" or name == "shr") {
      match pt {
        case PtByte -> true
        case PtInt -> true
        case PtLong -> true
        case PtUInt -> true
        case PtULong -> true
        case PtNat -> true
        case _ -> false
      }
    } else {
      false
    }
    case _ -> false
  }
}

// A resolved method call: `sig` is the receiver-dropped signature the
// argument list validates against; `fullSig` is set for dot-named
// (`func T.m(recv, ...)`) candidates whose return type must be instantiated
// against `[receiver] ++ args`.
record MethodCallPick {
  sig: ResolvedSignature
  fullSig: Option[ResolvedSignature]
}

// The receiver-dropped copy of a full dot-named signature.
func dropReceiverParam(full: in ResolvedSignature): ResolvedSignature {
  val np: List[ResolvedParam] = newList()
  var i = 1
  while i < full.params.count {
    np.add(full.params[i])
    i = i + 1
  }
  ResolvedSignature(
    generics = full.generics,
    bounds = full.bounds,
    params = np,
    returnTy = full.returnTy,
    isAsync = full.isAsync,
    isHot = full.isHot,
    isGenerator = full.isGenerator,
    originPackage = full.originPackage,
    span = full.span,
    isPure = full.isPure,
    isIo = full.isIo,
    isEntry = full.isEntry,
    isExternFunc = full.isExternFunc
  )
}

// Positional supplied-argument compatibility for CANDIDATE SELECTION only
// (named-arg pairing and the real T0042/T0043 reporting happen in
// `checkCallArgsAgainstSig` after selection).
func suppliedArgsMatch(tbl: in SymbolTable, params: in List[ResolvedParam], argTypes: in List[Type]): Bool {
  var i = 0
  while i < argTypes.count and i < params.count {
    if not argSatisfiesParam(tbl, params[i].ty, argTypes[i]) {
      return false
    }
    i = i + 1
  }
  true
}

func minRequiredParams(sig: in ResolvedSignature): Int {
  var minRequired = 0
  var i = 0
  while i < sig.params.count {
    if not sig.params[i].hasDefault {
      minRequired = minRequired + 1
    }
    i = i + 1
  }
  minRequired
}

// Resolve `recv.name(<args>)` against the method-signature space
// (docs/59 A4): the type's own/interface methods first, then dot-named
// type-associated functions.  The call binds the declaration `pickByShape`
// would choose for a free call (#7828, #8355).
func resolveMethodCallPick(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  recvRaw: in Type,
  name: in String,
  args: in List[CallArg],
  argTypes: in List[Type],
  ambiguous: in List[ResolvedSignature],
): Option[MethodCallPick] {
  val argc = args.count
  val recv = unrefine(recvRaw)
  if dotNamedOwnerName(recv).length == 0 or isPrimitiveIntrinsicMethod(recv, name, argc) {
    return None
  }
  val picks: List[MethodCallPick] = newList()
  val direct = methodCandidatesFor(tbl, recv, name)
  var i = 0
  while i < direct.count {
    picks.add(MethodCallPick(sig = direct[i], fullSig = None))
    i = i + 1
  }
  val dotted = dotNamedCandidatesFor(tbl, sigs, recv, name, argc, args, argTypes)
  var d = 0
  while d < dotted.count {
    picks.add(MethodCallPick(sig = dropReceiverParam(dotted[d]), fullSig = Some(value = dotted[d])))
    d = d + 1
  }
  // Which pick the call binds (#8355, D210), by the rule free calls follow
  // (`pickByShape`): the declarations the call fits whose parameter types the
  // arguments satisfy, the one supplied in full first, then the one that
  // leaves the fewest parameters to their defaults.  A method of the type and
  // a dot-named function of equal standing, with defaults filled, are
  // ambiguous.  With no type match, the first of the fitting declarations
  // that fills the fewest defaults answers, and with none fitting the first
  // pick at all, so T0042/T0043 report against a real signature.
  val fits: List[MethodCallPick] = newList()
  val typed: List[MethodCallPick] = newList()
  val seen: List[ResolvedSignature] = newList()
  for p in picks {
    // A declaration registered twice (as a method and as a dot-named
    // function of its type) is one candidate.
    if sigDefaultsFilled(p.sig, args) >= 0 and not sigListHas(seen, p.sig) {
      seen.add(p.sig)
      fits.add(p)
      if suppliedArgsMatch(tbl, p.sig.params, argTypesInSigOrder(p.sig, 0, args, argTypes)) {
        typed.add(p)
      }
    }
  }
  if fits.count == 0 {
    return if picks.count > 0 { Some(value = picks[0]) } else { None }
  }
  val pool = if typed.count > 0 { typed } else { fits }
  val fills: List[Int] = newList()
  for p in pool {
    fills.add(sigDefaultsFilled(p.sig, args))
  }
  val group: List[MethodCallPick] = newList()
  for i in fewestDefaultsCandidates(fills) {
    group.add(pool[i])
  }
  if group.count == 1 or typed.count == 0 or sigDefaultsFilled(group[0].sig, args) == 0 {
    return Some(value = group[0])
  }
  // A method of the type answers a call before a dot-named function of the
  // same shape does (D181, #8098); the tie is among declarations of one kind.
  val methods: List[MethodCallPick] = newList()
  for p in group {
    match p.fullSig {
      case None -> methods.add(p)
      case Some(_) -> ()
    }
  }
  val sameKind = if methods.count > 0 { methods } else { group }
  val plain: List[MethodCallPick] = newList()
  for p in sameKind {
    if p.sig.generics.count == 0 {
      plain.add(p)
    }
  }
  if plain.count == 1 {
    return Some(value = plain[0])
  }
  val tied = if plain.count > 1 { plain } else { sameKind }
  if tied.count == 1 {
    return Some(value = tied[0])
  }
  for p in tied {
    ambiguous.add(p.sig)
  }
  Some(value = tied[0])
}

// The record type a `.copy(...)` call on `recvTy` copies: a record or
// exposed record (generic or not) that declares no `copy` method or
// type-associated `copy` function of its own.
func recordCopyTarget(tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], recvTy: in Type): Option[SymbolId] {
  match unrefine(recvTy) {
    case TyUser(tid, tname, _) -> {
      if not typeIdIsRecord(tbl, tid) {
        return None
      }
      if symTableMethodSigs(tbl, tid, "copy").count > 0 or sigs.containsKey(tname + ".copy") {
        return None
      }
      Some(value = tid)
    }
    case _ -> None
  }
}

func typeIdIsRecord(tbl: in SymbolTable, tid: in SymbolId): Bool {
  match recordSymbolOfTid(tbl, tid) {
    case Some(_) -> true
    case None -> false
  }
}

func recordSymbolOfTid(tbl: in SymbolTable, tid: in SymbolId): Option[Symbol] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKRecord(did, _) -> if symbolIdEq(did, tid) { return Some(value = tbl.symbols[i]) }
      case DKExposedRec(did, _) -> if symbolIdEq(did, tid) { return Some(value = tbl.symbols[i]) }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

func sameStringLists(a: in List[String], b: in List[String]): Bool {
  if a.count != b.count {
    return false
  }
  var i = 0
  while i < a.count {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

// Check `recv.copy(name = value, ...)` against the record's fields: every
// argument must be named (T0127), name a field (T0101) at most once (T0127),
// and be assignable to that field's type at the receiver's instantiation
// (T0104).  A valid call is recorded in `tbl.recordCopySites` and has the
// receiver's type.
func checkRecordCopy(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
  tid: in SymbolId,
  recvTy: in Type,
  args: in List[CallArg],
): Type {
  val recv = unrefine(recvTy)
  val targs: List[Type] = match recv { case TyUser(_, _, a) -> a; case _ -> newList() }
  val tname = match recv { case TyUser(_, n, _) -> n; case _ -> "" }
  val fields = if targs.count > 0 { fieldsOfRecordInstantiated(tbl, tid, targs) } else { fieldsOfRecord(tbl, tid) }
  val seen: List[String] = newList()
  var ok = true
  var ai = 0
  while ai < args.count {
    match args[ai] {
      case CANamed(nm, valE, argSpan) -> {
        if stringListContains(seen, nm) {
          diag.add(errorDiagnostic("T0127", "field '" + nm + "' is given more than once in '" + tname + ".copy'", argSpan))
          ok = false
        }
        seen.add(nm)
        var found = false
        var fi = 0
        while fi < fields.count {
          if fields[fi].name == nm {
            found = true
            val want = fields[fi].ty
            val got = inferExprExpected(sc, tbl, sigs, diag, valE, want)
            recordUnsignedWidening(tbl, want, got, valE)
            noteRangeSlot(tbl, want, valE, tname + " field " + nm)
            if not argSatisfiesParam(tbl, want, got) {
              diag.add(
                errorDiagnostic(
                  "T0104",
                  "argument for field '" + nm + "' " + hasTypeOrEmptyLiteral(got, valE) + " but field expects " + renderType(want) +
                    typeMismatchHint(tbl, want, got),
                  valE.span
                )
              )
              ok = false
            }
          }
          fi = fi + 1
        }
        if not found {
          val _ = inferExpr(sc, tbl, sigs, diag, valE)
          diag.add(errorDiagnostic("T0101", "record '" + tname + "' has no field '" + nm + "'", argSpan))
          ok = false
        }
      }
      case CAPositional(pe) -> {
        val _ = inferExpr(sc, tbl, sigs, diag, pe)
        diag.add(
          errorDiagnostic("T0127", "'" + tname + ".copy' takes named field arguments, e.g. `r.copy(field = value)`", pe.span)
        )
        ok = false
      }
    }
    ai = ai + 1
  }
  if ok {
    val names: List[String] = newList()
    val fieldTes: List[Option[TypeExpr]] = newList()
    var ni = 0
    while ni < fields.count {
      names.add(fields[ni].name)
      if isStorageType(fields[ni].ty) {
        // An array field carried over by `.copy` is copied (D167), so its
        // type must be spelled, a type variable by name.
        val arrTe = typeExprForRefWithVars(tbl, fields[ni].ty, e.span)
        if (match arrTe { case Some(_) -> false; case None -> true }) and not inValueGenericBody(tbl) {
          diag.add(arrayUnknownLength(fields[ni].ty, e.span))
        }
        fieldTes.add(arrTe)
      } else {
        fieldTes.add(typeExprForRef(tbl, fields[ni].ty, e.span))
      }
      ni = ni + 1
    }
    val ctorPath = match recordSymbolOfTid(tbl, tid) {
      case Some(rs) -> if rs.isImported and rs.originPackage.length > 0 {
        rs.originPackage + "." + rs.name
      } else {
        rs.name
      }
      case None -> tname
    }
    match recordSymbolOfTid(tbl, tid) {
      case Some(rs) -> recordInvariantCtorSite(tbl, rs, e.span)
      case None -> ()
    }
    val site = RecordCopySite(
      recordName = ctorPath,
      fields = names,
      fieldTypes = fieldTes,
      startOffset = e.span.startPos.offset,
      conflicting = false
    )
    val key = recordCopySiteKey(e.span)
    match mapGet(tbl.recordCopySites, key) {
      case None -> tbl.recordCopySites.add(key, site)
      case Some(prev) -> if prev.recordName != ctorPath or not sameStringLists(prev.fields, names) {
        tbl.recordCopySites.remove(key)
        tbl.recordCopySites.add(
          key,
          RecordCopySite(
            recordName = ctorPath,
            fields = names,
            fieldTypes = newList(),
            startOffset = e.span.startPos.offset,
            conflicting = true
          )
        )
      }
    }
  }
  recvTy
}

func stringListContains(xs: in List[String], x: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == x {
      return true
    }
    i = i + 1
  }
  false
}

// #7204: is `name` a method the target being checked for cannot give a
// `String`?  The check consults, in order: the universal methods, the
// built-in surface (`stringHostMethodType`, `indexOf`/`lastIndexOf`,
// `length`/`isEmpty`), a plain function the file can call bare, and, on the JVM, the methods of `java.lang.String`
// and its supertypes.  The caller has already ruled out a dot-named
// function and an extension the imports reach.  A target that does not say
// (`SMSUnchecked`) reports nothing.
func stringMethodIsUnknown(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  pt: in PrimType,
  name: in String,
): Bool {
  match pt {
    case PtString -> ()
    case _ -> return false
  }
  if tbl.stringSurface.count == 0 {
    return false
  }
  if isUniversalMethodName(name) or name == "indexOf" or name == "lastIndexOf" or name == "length" or name == "isEmpty" {
    return false
  }
  match stringHostMethodType(name) {
    case Some(_) -> return false
    case None -> ()
  }
  // A plain function of that name the file can call bare binds by method
  // syntax to its first argument (`s.shout()`, `s.isNotEmpty()`).
  if visibleBareFuncSigs(tbl, sigs, name, -1).count > 0 {
    return false
  }
  match tbl.stringSurface[0] {
    case SMSUnchecked -> false
    case SMSClosed -> true
    case SMSOpen(hostMethods) -> not hostMethods.contains(name)
  }
}

func stringSurfaceNote(tbl: in SymbolTable): String {
  match tbl.stringSurface[0] {
    case SMSOpen(_) -> " (it is not a Std.String function or a method of java.lang.String)"
    case _ -> " (a String has only the built-in methods and the Std.String functions on this target)"
  }
}

// A5 (docs/59 §5.1): report an unknown member/method on a receiver whose
// member surface is fully known — a record, exposed record, or interface,
// local or imported (`symTableIsMemberComplete`; a restored contract's record
// repr carries its body methods since #6440, #7575).  Emits nothing when the name exists
// anywhere in the member/method space, is a universal codegen intrinsic /
// derive-synthesised name, or has a dot-named type-associated signature.
func maybeUnknownMemberDiag(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  recvRaw: in Type,
  name: in String,
  span: in Span,
  isCall: in Bool,
): Unit {
  val recv = unrefine(recvRaw)
  match recv {
    case TyUser(tid, tname, targs) -> {
      // `List` sizes with `.count`; only `String`, `slice` and arrays have
      // `.length`.  MSIL lowered the bare name silently while the JVM
      // rejected it (J009), so the front end decides (#7218).
      if name == "length" and targs.count == 1 and isStdCollectionsHostType(tbl, tid, "List") {
        diag.add(
          errorDiagnostic(
            "T0207",
            "'List' has no member 'length'; use '.count' (only String, slice and array have '.length')",
            span
          )
        )
        return
      }
      if isCall and isNonGenericDistinct(tbl, tid) {
        unknownDistinctMethodDiag(tbl, sigs, diag, recv, tname, name, span)
        return
      }
      // A union's member surface is its methods, its `impl`s and the dot-named
      // functions and UFCS functions that bind to it, so an unresolved *call*
      // on one names nothing any backend can dispatch (#8319).
      val unionCall = isCall and tbl.unionDeclIndex.containsKey(toString(tid.id))
      if not symTableIsMemberComplete(tbl, tid) and not unionCall {
        return
      }
      // A plain function of that name that the file can call bare is what a
      // method call on a union binds to by its first argument (`o.isSome()`,
      // `o.assertSome()`); one the import rule hides is not (docs/70 §4.5).
      if unionCall and visibleBareFuncSigs(tbl, sigs, name, -1).count > 0 {
        return
      }
      if isUniversalMethodName(name) {
        return
      }
      val fs = fieldsOfRecord(tbl, tid)
      var i = 0
      while i < fs.count {
        if fs[i].name == name {
          return
        }
        i = i + 1
      }
      match builtinMember(tbl, recv, name) {
        case Some(_) -> {
          return
        }
        case None -> {
        }
      }
      if symTableMethodSigs(tbl, tid, name).count > 0 {
        return
      }
      var pi = 0
      while pi < tbl.impls.count {
        if symbolIdEq(tbl.impls[pi].target, tid) {
          if symTableMethodSigs(tbl, tbl.impls[pi].iface, name).count > 0 {
            return
          }
        }
        pi = pi + 1
      }
      val hint = match hiddenExtensionsHint(tbl, sigs, recv, tname + "." + name) { case Some(h) -> h; case None -> return }
      val what = if isCall { "no method '" } else { "no member '" }
      diag.add(
        errorDiagnostic(
          "T0113",
          what + name + "' on type '" + tname + "'" + shadowedStdCollectionNote(tbl, recv) + hint,
          span
        )
      )
    }
    // A method call on a primitive that names no built-in method, no
    // dot-named function of the primitive and no extension the imports reach
    // (#8217, #8219).  A `String`'s methods stay open-ended: on the JVM its
    // host methods are reached by name.
    case TyPrim(pt) -> match hiddenExtensionsHint(tbl, sigs, recv, primName(pt) + "." + name) {
      case Some(h) -> if isCall and (h.length > 0 or not (isPrimitiveBuiltinMethodName(name) or (match pt { case PtString -> true; case _ -> false }))) {
        diag.add(errorDiagnostic("T0113", "no method '" + name + "' on type '" + primName(pt) + "'" + h, span))
      } else if isCall and stringMethodIsUnknown(tbl, sigs, pt, name) {
        diag.add(errorDiagnostic("T0113", "no method '" + name + "' on type 'String'" + h + stringSurfaceNote(tbl), span))
      }
      case None -> ()
    }
    // A method call on a slice that names none of its
    // built-in members (`xs.filter(...)`, #8471).  Neither has dot-named
    // functions or extensions, so a plain function such as `Std.Iter.filter`
    // is never bound by method syntax: MSIL lowered the call to a stub that
    // throws when reached (never lowering its lambda arguments, which then
    // failed T0115 as unreachable lifted bodies) and the JVM rejected it
    // (J008), so the front end decides.
    case TySlice(_) -> sliceUnknownMethodDiag(tbl, sigs, diag, recv, name, span, isCall)
    case _ -> {
    }
  }
}

// True when `tvName` is one of the type arguments of the enclosing record or
// `impl`'s self type, so it is a type parameter of that declaration.
func isSelfTypeArgument(selfTy: in Type, tvName: in String): Bool {
  match selfTy {
    case TyUser(_, _, selfArgs) -> {
      for sa in selfArgs {
        match sa {
          case TyVar(sn) -> {
            if sn == tvName {
              return true
            }
          }
          case _ -> ()
        }
      }
      false
    }
    case _ -> false
  }
}

// Whether the package being checked declares an `extern type` itself (not
// through an import).
func packageDeclaresExternType(tbl: in SymbolTable): Bool {
  for sym in tbl.symbols {
    if not sym.isImported {
      match sym.kind {
        case DKExternType(_, _) -> return true
        case _ -> ()
      }
    }
  }
  false
}

// T0197 for a method call on a value of a function-level type parameter that
// no `where` bound promises (#8018): a type parameter has no fields and only
// the methods of its bounds, so `x.zork()` (or `b.v.zork()` under `where T:
// Named`) would otherwise be duck-typed against whatever the type argument
// has, and a typo would fail in a backend.  Silent when the name is one every
// receiver has (`toString`, the derive-synthesised names), when a plain
// function of that name the file can call could bind by UFCS, when a bound is a marker or an
// interface whose members the checker cannot enumerate, for a type
// parameter of the enclosing record or impl, whose bounds are not in scope,
// and in a package that declares an `extern type`.
func maybeUnknownTypeParamMethodDiag(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  recvRaw: in Type,
  name: in String,
  span: in Span,
): Unit {
  match unrefine(recvRaw) {
    case TyVar(tvName) -> {
      if not sc.genericNames.contains(tvName) {
        return
      }
      if isSelfTypeArgument(sc.selfType, tvName) {
        return
      }
      if isUniversalMethodName(name) or isPrimitiveBuiltinMethodName(name) or visibleBareFuncSigs(tbl, sigs, name, -1).count > 0 {
        return
      }
      for b in sc.bounds {
        if b.name == tvName {
          for cname in b.constraints {
            if not (isPlainMarker(cname) or isKnownDeriveMarker(cname)) {
              match constraintInterfaceSym(tbl, cname) {
                case Some(ifaceSym) -> match ifaceSym.kind {
                  case DKInterface(ifaceId, _) -> {
                    if not symTableIsMemberComplete(tbl, ifaceId) or symTableMethodSigs(tbl, ifaceId, name).count > 0 {
                      return
                    }
                  }
                  case _ -> return
                }
                case None -> {
                  return
                }
              }
            }
          }
        }
      }
      // A package that declares an `extern type` is an FFI boundary (a
      // `_kernel*` file): there a type-parameter value may be a host object,
      // and a call on it resolves against the host type at codegen (on the
      // JVM every value is a java.lang.Object, so `target.getClass()` is
      // well-typed), the same open-endedness a `String` receiver has.
      if packageDeclaresExternType(tbl) {
        return
      }
      diag.add(
        errorDiagnostic(
          "T0197",
          "no method '" + name + "' on type parameter '" + tvName +
            "': a value of a type parameter has no fields; only the methods of its `where` bounds can be called on it",
          span
        )
      )
    }
    case _ -> ()
  }
}

func sliceUnknownMethodDiag(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  recv: in Type,
  name: in String,
  span: in Span,
  isCall: in Bool,
): Unit {
  // `.toArray()` is the identity on a slice (#7480).
  if not isCall or isUniversalMethodName(name) or name == "toArray" {
    return
  }
  val tname = renderType(recv)
  val hint = if visibleBareFuncSigs(tbl, sigs, name, -1).count > 0 {
    "; '" + name + "' is a plain function, not a method of " + tname + ": call it as '" + name + "(xs, ...)'"
  } else {
    ""
  }
  diag.add(errorDiagnostic("T0113", "no method '" + name + "' on type '" + tname + "'" + hint, span))
}

// The methods every backend gives a primitive receiver itself: `toString`,
// the conversions, the bitwise and the wrapping arithmetic.  A call of any
// other name on a primitive needs a dot-named function of it.
func isPrimitiveBuiltinMethodName(name: in String): Bool {
  match numericConvTarget(name) {
    case Some(_) -> return true
    case None -> ()
  }
  name == "toString" or name == "toUInt" or name == "toULong" or name == "toNat" or name == "and" or name == "or" or
    name == "xor" or
    name == "shl" or
    name == "shr" or
    isWrappingMethodName(name)
}

// Whether `tid` is a distinct type with no generic parameters.
func isNonGenericDistinct(tbl: in SymbolTable, tid: in SymbolId): Bool {
  for sym in tbl.symbols {
    match sym.kind {
      case DKDistinctType(did, dt) -> if symbolIdEq(did, tid) {
        return match dt.generics { case Some(_) -> false; case None -> true }
      }
      case _ -> ()
    }
  }
  false
}

// T0113 for a method call on a distinct type that names none of its
// methods: a distinct type does not expose its underlying type's methods
// (docs/01 §2.3), so a dot-named function of the underlying type is called
// on `.value`.
func unknownDistinctMethodDiag(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  recv: in Type,
  tname: in String,
  name: in String,
  span: in Span,
): Unit {
  if isUniversalMethodName(name) or isPrimitiveBuiltinMethodName(name) or name == "value" {
    return
  }
  match builtinMember(tbl, recv, name) {
    case Some(_) -> {
      return
    }
    case None -> ()
  }
  match recv {
    case TyUser(tid, _, _) -> {
      if symTableMethodSigs(tbl, tid, name).count > 0 {
        return
      }
    }
    case _ -> ()
  }
  val hint = match hiddenExtensionsHint(tbl, sigs, recv, tname + "." + name) { case Some(h) -> h; case None -> return }
  diag.add(
    errorDiagnostic(
      "T0113",
      "no method '" + name + "' on distinct type '" + tname + "'" + hint +
        "; a distinct type does not expose its underlying type's methods, call them on '.value' (e.g. 'x.value." +
        name +
        "()')",
      span
    )
  )
}

// For a member `dotted` (`T.m`) a call on a receiver of type `recv` did not
// bind: `None` when some dot-named function of that name is the type's own or
// an extension the file's imports reach, so the call is checked against it
// elsewhere; otherwise the clause naming the packages whose extensions the
// imports do not reach (#8219), "" when there are none.
func hiddenExtensionsHint(
  tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], recv: in Type, dotted: in String
): Option[String] {
  val hiddenIn: List[String] = newList()
  for c in dotNamedSigsAnyArity(sigs, dotted) {
    if not isDotNamedExtension(tbl, recv, c) or dotNamedExtensionTier(tbl, sigPackage(tbl, c)) >= 0 {
      return None
    }
    if not hiddenIn.contains(sigPackage(tbl, c)) {
      hiddenIn.add(sigPackage(tbl, c))
    }
  }
  if hiddenIn.count == 0 {
    return Some(value = "")
  }
  // A package imported under an alias or selectively is named in this
  // file, so its extension is called through it (#8219).
  val via: List[String] = newList()
  for pkg in hiddenIn {
    match mapGet(tbl.importAliases, pkg) {
      case Some(alias) -> via.add("'" + alias + "." + dotted + "(...)' (" + pkg + " is imported as " + alias + ")")
      case None -> if symTableScopeAllows(tbl, pkg) {
        via.add("'" + pkg + "." + dotted + "(...)' (" + pkg + " is imported selectively)")
      }
    }
  }
  if via.count > 0 {
    return Some(
      value = " ('" + dotted + "' is declared by " + joinPackageNames(hiddenIn) +
        ", whose extensions a method call binds only when the package is imported whole; call it as " +
        joinStrs(via, " or ") +
        ")"
    )
  }
  Some(
    value = " ('" + dotted + "' is declared by " + joinPackageNames(hiddenIn) +
      ", which this file's imports do not reach; import it)"
  )
}

// True when `name` names a REAL field of the LOCAL (non-imported) opaque
// type `tid` — checked via `ctorAllFields`, the only path that can see an
// opaque type's fields at all (`fieldsOfRecord`/`fieldsOfRecordInstantiated`
// only walk `DKRecord`/`DKExposedRec`; opaque fields are visible only within
// the declaring package). #6362's dot-named-only check must not fire for a
// LOCAL opaque type's own accessor body reading its own private field (`pub
// func Config.path(config: in Config): String { config.path }`, the exact
// shape in `lyric-stdlib/std/app.l`) — that read can never resolve via
// `inferMemberBase` (opaque fields are invisible to it regardless of
// whether they exist), so without an exemption it would misfire as
// "field-style access to a UFCS-only function".
//
// Narrowed to the field's OWN name (not "any name on a local opaque type"):
// an earlier version of this guard (`isOpaqueTypeId`) exempted every name on
// a local opaque receiver unconditionally, which silently let field-style
// access to an UNRELATED same-type UFCS function through too (#6383) —
// e.g. `c.summary` on `opaque type Config { path: String }` with a sibling
// `func Config.summary(c: in Config): String` reachable only by call syntax.
// Checking the name against `ctorAllFields` closes that gap: only a name
// that is an actual field is exempted, so an unrelated dot-named function
// still hits the dot-named check below and raises T0116 as it should.
//
// Scoped to `not isImported` (mirroring T0100/T0102's declaring-package
// check just above): a field on an opaque type IMPORTED from another
// package is never legitimately readable field-style from outside its
// declaring package in the first place — the type's whole design point is
// that its representation is invisible outside its package (see this
// repo's glossary). So for an imported opaque receiver, a `sigs` hit is
// just as unambiguous a "this is UFCS-only" signal as it is for a record
// or union; only the SAME-package accessor-body reading its OWN field needs
// the exemption (review follow-up on #6362: #6382 found the unscoped-by-
// package guard, #6383 found the unscoped-by-field-name guard).
func isOpaqueOwnFieldName(tbl: in SymbolTable, tid: in SymbolId, name: in String): Bool {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKOpaque(did, _) -> if symbolIdEq(did, tid) and not tbl.symbols[i].isImported {
        val fields = ctorAllFields(tbl.symbols[i])
        var j = 0
        while j < fields.count {
          if fields[j].name == name {
            return true
          }
          j = j + 1
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

func inferMember(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  recvRaw: in Type,
  name: in String,
  span: in Span,
): Type {
  val base = inferMemberBase(tbl, recvRaw, name)
  match base {
    case TyError -> {
    }
    case _ -> {
      return base
    }
  }
  // #5183 / #6624: bare (non-call) `.isOk`/`.isErr`/`.value`/`.error` /
  // `.isSome`/`.isNone` on `Result`/`Option` — see `monadAccessorType`'s own
  // comment for why this lives here (the bare-member wrapper) and not in
  // `inferMemberBase` (also consulted by `ECall`'s callee-type lookup,
  // which must keep seeing `TyError` here so `.isOk()` still resolves via
  // the ordinary UFCS call-site path).
  match monadAccessorType(tbl, recvRaw, name) {
    case Some(t) -> return t
    case None -> {
    }
  }
  // A method referenced in plain member position types as its function type
  // (receiver dropped) so `x.method` flows into the general `TyFunction`
  // call validation; a name that exists nowhere on a member-complete type
  // gets the A5 diagnostic.
  val recv = unrefine(recvRaw)
  match recv {
    case TyUser(tid, tname, _) -> {
      val cands = methodCandidatesFor(tbl, recv, name)
      if cands.count > 0 {
        val ms = cands[0]
        val pts: List[Type] = newList()
        var k = 0
        while k < ms.params.count {
          pts.add(ms.params[k].ty)
          k = k + 1
        }
        return TyFunction(params = pts, ret = ms.returnTy, isAsync = ms.isAsync)
      }
      // #6362: a name that resolves ONLY as a top-level D037 dot-named
      // (UFCS) function — e.g. `pub func IOError.message(e: in IOError):
      // String` — is never valid FIELD-style access; it requires call
      // syntax (`e.message()`).  `sigs` carries dot-named signatures for
      // every type name regardless of which package declares the receiver
      // (unlike `memberCompleteTypes`, which — by design, docs/59 A5 —
      // only covers record/interface FIELD enumeration), so this check also
      // catches receivers like the stdlib's `IOError` union that
      // `maybeUnknownMemberDiag` stays lenient about. Checked ahead of that lenient A5 path so a
      // real UFCS function's existence is never silently misread as "valid
      // field access" the way it was before this fix (the bug produced a
      // `TyError` with no diagnostic, which reached codegen as invalid IL).
      // Excluded when `name` is a real field of a LOCAL opaque receiver
      // (`isOpaqueOwnFieldName`): opaque fields are invisible to
      // `fieldsOfRecord`, so a same-named accessor UFCS function wrapping a
      // private field is indistinguishable here from a genuine UFCS-only
      // name — see `isOpaqueOwnFieldName`'s comment. An UNRELATED dot-named
      // function on the same opaque type is not exempted (#6383).
      if not isOpaqueOwnFieldName(tbl, tid, name) and sigs.containsKey(tname + "." + name) {
        diag.add(
          errorDiagnostic(
            "T0116",
            "no field '" + name + "' on type '" + tname + "' -- '" + name + "' is a function; call it as '" + name + "(...)'",
            span
          )
        )
        return TyError
      }
      // #6630: a receiver that structurally LOOKS like `Result[T, E]` /
      // `Option[T]` (same reserved bare name + arity), and `name` is one of
      // the six reserved accessor names, but `monadAccessorType` above
      // already returned `None` for it — either because this IS the
      // genuine `Std.Core` type but `name` is the OTHER monad's accessor,
      // or because it's a genuinely foreign lookalike type
      // (`monadAccessorShapeMismatchDiag` distinguishes the two, #6710) —
      // would otherwise fall through silently here: unions are never
      // "member-complete" (docs/59 A5), so `maybeUnknownMemberDiag` below
      // stays lenient and emits nothing, reaching codegen as an unresolved
      // `TyError` member read -- the exact #5183 miscompile this whole
      // accessor feature exists to prevent. Diagnose it explicitly. Placed
      // AFTER the `cands.count > 0` / `T0116` checks above (both already
      // checked this exact receiver+name and came up empty before reaching
      // here), so a same-shaped union that genuinely declares its own real
      // method or dot-named UFCS function under one of these six names is
      // unaffected — verified for the dot-named case, which resolves to
      // `T0116` ("call it as 'isOk(...)'"), not this diagnostic. An
      // unrelated genuinely-unknown member on the same union still falls
      // through to the ordinary (silent, by design) union member-access
      // path below.
      match monadAccessorShapeMismatchDiag(tbl, recvRaw, name, span) {
        case Some(d) -> {
          diag.add(d)
          return TyError
        }
        case None -> {
        }
      }
      // A bare member of `Std.Core.Result` / `Option` that names none of their
      // accessors and no function: the member surface of these two is fully
      // known, so it is a mistake rather than something codegen could resolve.
      // Lyric has no trailing-lambda call syntax, so `r.mapErr { e -> ... }`
      // lands here as the bare member `r.mapErr` followed by a block (#8472).
      match stdCoreMonadName(tbl, recvRaw) {
        case Some(monad) -> if not isUniversalMethodName(name) and visibleBareFuncSigs(tbl, sigs, name, -1).count == 0 {
          diag.add(
            errorDiagnostic(
              "T0113",
              "no member '" + name + "' on type '" + monad + "' -- a '" + monad + "' has " + monadAccessorList(monad) +
                "; to call a function pass its arguments in parentheses, `x." +
                name +
                "(...)` (there is no trailing-lambda call syntax)",
              span
            )
          )
          return TyError
        }
        case None -> {
        }
      }
      maybeUnknownMemberDiag(tbl, sigs, diag, recvRaw, name, span, false)
      TyError
    }
    case _ -> TyError
  }
}

// "Result" or "Option" when `recvRaw` is the `Std.Core` type of that name.
func stdCoreMonadName(tbl: in SymbolTable, recvRaw: in Type): Option[String] {
  match unrefine(recvRaw) {
    case TyUser(tid, nm, targs) -> {
      if nm == "Result" and targs.count == 2 and isStdCoreMonadType(tbl, tid, "Result") {
        return Some(value = "Result")
      }
      if nm == "Option" and targs.count == 1 and isStdCoreMonadType(tbl, tid, "Option") {
        return Some(value = "Option")
      }
      None
    }
    case _ -> None
  }
}

func monadAccessorList(monad: in String): String {
  if monad == "Result" {
    ".isOk, .isErr, .value and .error"
  } else {
    ".isSome, .isNone and .value"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Expression path resolution.
// ─────────────────────────────────────────────────────────────────────────────
// #6361: does package `pkg` (a dotted `originPackage` value) contribute any
// symbol at all to `tbl`?  True for every package actually reachable from a
// collapsed multi-segment `EPath` (see `resolveExprPath` below) — used to
// gate the unknown-qualified-name diagnostic so it only ever fires against a
// package the checker has full member knowledge of, never a placeholder.
//
// O(1) via `SymbolTable.symbolPackages`, a side index `symTableAdd` populates
// alongside `symbols` (review follow-up on PR #6373: this and
// `symTablePackageHasMember` were originally an O(n) scan over `symbols` on
// every multi-segment qualified reference the checker resolves — the same
// tradeoff `externBlockMembers`/`externBlockPackages` already made for the
// extern-block side of this same check).
func symTablePackageHasAnySymbol(tbl: in SymbolTable, pkg: in String): Bool {
  tbl.symbolPackages.containsKey(pkg)
}

// #6361: does package `pkg` declare a symbol named `name` (any kind, any
// arity)?  Arity-blind by design — the caller only wants to know whether the
// trailing segment names anything real in that package at all. O(1) via
// `SymbolTable.symbolPackageMembers` (see `symTablePackageHasAnySymbol`).
func symTablePackageHasMember(tbl: in SymbolTable, pkg: in String, name: in String): Bool {
  tbl.symbolPackageMembers.containsKey(pkg + "|" + name)
}

// ─── Cross-package function values (D-progress-963) ─────────────────────────
// A reference to another package's function used as a value (`f = Pkg.fn`,
// or a bare imported `fn`) is recorded as a `FuncRefSite` and rewritten by
// `Lyric.Mono.desugarRecordCopiesFile` into the typed forwarding lambda
// `{ p0: T0, ... -> Pkg.fn(p0, ...) }`, which every backend already lowers.
func dottedSegsTc(s: in String): List[String] {
  val acc: List[String] = newList()
  var start = 0
  var i = 0
  while i < s.length {
    if s.substring(i, 1) == "." {
      acc.add(s.substring(start, i - start))
      start = i + 1
    }
    i = i + 1
  }
  if start < s.length {
    acc.add(s.substring(start))
  }
  acc
}

func refTypePath(segs: in List[String], sp: in Span): ModulePath {
  ModulePath(segments = segs, span = sp)
}

// `t` spelled as source for the synthesized lambda's parameter annotation.  A
// user type from another non-stdlib package is qualified by that package, so
// the annotation names the same type in the calling package; `None` for a
// type with no source spelling here (a type variable, `Self`, an error).
func typeExprForRef(tbl: in SymbolTable, t: in Type, sp: in Span): Option[TypeExpr] {
  typeExprForRefV(tbl, t, sp, false)
}

func typeExprsForRef(tbl: in SymbolTable, ts: in List[Type], sp: in Span): Option[List[TypeExpr]] {
  typeExprsForRefV(tbl, ts, sp, false)
}

/// `typeExprForRef` that spells a type variable by its name, for the array
/// lowering's copy and fill intrinsics inside a generic body (D167).
func typeExprForRefWithVars(tbl: in SymbolTable, t: in Type, sp: in Span): Option[TypeExpr] {
  typeExprForRefV(tbl, t, sp, true)
}

func typeExprForRefV(tbl: in SymbolTable, t: in Type, sp: in Span, vars: in Bool): Option[TypeExpr] {
  match t {
    case TyPrim(pt) -> match pt {
      case PtUnit -> Some(value = TypeExpr(kind = TUnit, span = sp))
      case PtNever -> Some(value = TypeExpr(kind = TNever, span = sp))
      case _ -> {
        val segs: List[String] = newList()
        segs.add(primName(pt))
        Some(value = TypeExpr(kind = TRef(path = refTypePath(segs, sp)), span = sp))
      }
    }
    case TyRefined(u, _, _, _, _) -> typeExprForRefV(tbl, u, sp, vars)
    case TyNullable(inner) -> match typeExprForRefV(tbl, inner, sp, vars) {
      case Some(te) -> Some(value = TypeExpr(kind = TNullable(inner = te), span = sp))
      case None -> None
    }
    case TySlice(e) -> match typeExprForRefV(tbl, e, sp, vars) {
      case Some(te) -> Some(value = TypeExpr(kind = TSlice(element = te), span = sp))
      case None -> None
    }
    case TyArray(sz, e, sv) -> match sz {
      case Some(n) -> match typeExprForRefV(tbl, e, sp, vars) {
        case Some(te) -> {
          val lenLit = mkExpr(ELiteral(lit = LInt(value = n.toLong(), suffix = I32, raw = "")), sp)
          Some(value = TypeExpr(kind = TArray(size = TAValue(expr = lenLit), element = te), span = sp))
        }
        case None -> None
      }
      // A length that is a value generic parameter is spelled by its name;
      // each specialisation substitutes the bound length (D169).
      case None -> if sv.length > 0 {
        match typeExprForRefV(tbl, e, sp, vars) {
          case Some(te) -> {
            val nsegs: List[String] = newList()
            nsegs.add(sv)
            val lenTe = TypeExpr(kind = TRef(path = refTypePath(nsegs, sp)), span = sp)
            Some(value = TypeExpr(kind = TArray(size = TAType(ty = lenTe), element = te), span = sp))
          }
          case None -> None
        }
      } else {
        None
      }
    }
    case TyTuple(elems) -> match typeExprsForRefV(tbl, elems, sp, vars) {
      case Some(tes) -> Some(value = TypeExpr(kind = TTuple(types = tes), span = sp))
      case None -> None
    }
    case TyFunction(ps, r, isAsync) -> if isAsync {
      None
    } else {
      match typeExprsForRefV(tbl, ps, sp, vars) {
        case Some(ptes) -> match typeExprForRefV(tbl, r, sp, vars) {
          case Some(rte) -> Some(
            value = TypeExpr(
              kind = TFunction(parameters = ptes, retTy = rte),
              span = sp
            )
          )
          case None -> None
        }
        case None -> None
      }
    }
    case TyUser(tid, nm, args) -> if symbolIdEq(tid, builtinBufferTypeId()) and args.count == 1 {
      match typeExprForRefV(tbl, args[0], sp, vars) {
        case Some(ate) -> {
          val bsegs: List[String] = newList()
          bsegs.add("buffer")
          val btargs: List[TypeArg] = newList()
          btargs.add(TAType(ty = ate))
          Some(value = TypeExpr(kind = TGenericApp(head = refTypePath(bsegs, sp), args = btargs), span = sp))
        }
        case None -> None
      }
    } else {
      typeExprForUserType(tbl, tid, args, sp, vars)
    }
    case TyVar(nm) -> if vars {
      val vsegs: List[String] = newList()
      vsegs.add(nm)
      Some(value = TypeExpr(kind = TRef(path = refTypePath(vsegs, sp)), span = sp))
    } else {
      None
    }
    case _ -> None
  }
}

func typeExprForUserType(
  tbl: in SymbolTable, tid: in SymbolId, args: in List[Type], sp: in Span, vars: in Bool
): Option[TypeExpr] {
  match symTableTypeSymbolOf(tbl, tid) {
    case Some(sym) -> {
      val segs: List[String] = newList()
      val origin = sym.originPackage
      // The bare name is used only when it denotes this same type at the use
      // site; otherwise the type is qualified by its package. An extern type
      // (resolved by its bare name in codegen) or a type with no package has
      // no other spelling, so it has none here (#7371).
      val bareOk = match symTableTryFindOne(tbl, sym.name) {
        case Some(found) -> match symbolTypeIdOpt(found) {
          case Some(fid) -> symbolIdEq(fid, tid)
          case None -> false
        }
        case None -> false
      }
      val isExtern = match sym.kind { case DKExternType(_, _) -> true; case _ -> false }
      if not bareOk and (origin.length == 0 or isExtern) {
        return None
      }
      if not bareOk and origin != symTableScopePkg(tbl) {
        val pkgSegs = dottedSegsTc(origin)
        var k = 0
        while k < pkgSegs.count {
          segs.add(pkgSegs[k])
          k = k + 1
        }
      }
      segs.add(sym.name)
      if args.count == 0 {
        Some(value = TypeExpr(kind = TRef(path = refTypePath(segs, sp)), span = sp))
      } else {
        // A length argument (`TyLen`) is spelled as the literal (D169).
        val targs: List[TypeArg] = newList()
        for a in args {
          match a {
            case TyLen(n) -> targs.add(
              TAValue(expr = mkExpr(ELiteral(lit = LInt(value = n.toLong(), suffix = I32, raw = "")), sp))
            )
            case _ -> match typeExprForRefV(tbl, a, sp, vars) {
              case Some(ate) -> targs.add(TAType(ty = ate))
              case None -> return None
            }
          }
        }
        Some(value = TypeExpr(kind = TGenericApp(head = refTypePath(segs, sp), args = targs), span = sp))
      }
    }
    case None -> None
  }
}

func typeExprsForRefV(tbl: in SymbolTable, ts: in List[Type], sp: in Span, vars: in Bool): Option[List[TypeExpr]] {
  val acc: List[TypeExpr] = newList()
  var i = 0
  while i < ts.count {
    match typeExprForRefV(tbl, ts[i], sp, vars) {
      case Some(te) -> acc.add(te)
      case None -> return None
    }
    i = i + 1
  }
  Some(value = acc)
}

// Record `sig`, a function of the package being checked, referenced bare as a
// value at `sp` (see `SymbolTable.ownFuncValueSites`).  A function a
// forwarding lambda cannot stand for (generic, async, a non-`in` parameter, a
// parameter type not nameable here) is left out: its specialised use keeps
// the bare name, as before (#8329).
func recordOwnFuncValueSite(tbl: in SymbolTable, sig: in ResolvedSignature, name: in String, sp: in Span): Unit {
  if tbl.funcRefCallees.containsKey(recordCopySiteKey(sp)) or sig.isAsync or sig.generics.count > 0 {
    return
  }
  val ptys: List[Type] = newList()
  for p in sig.params {
    match p.mode {
      case PMIn -> ptys.add(p.ty)
      case _ -> return
    }
  }
  match typeExprsForRef(tbl, ptys, sp) {
    case Some(ptes) -> {
      val segs = dottedSegsTc(symTableScopePkg(tbl))
      segs.add(name)
      val key = recordCopySiteKey(sp)
      if tbl.ownFuncValueSites.containsKey(key) {
        tbl.ownFuncValueSites.remove(key)
      }
      tbl.ownFuncValueSites.add(
        key,
        FuncRefSite(
          calleeSegs = segs,
          paramTypes = ptes,
          retType = typeExprForRef(tbl, sig.returnTy, sp),
          startOffset = sp.startPos.offset
        )
      )
    }
    case None -> ()
  }
}

// Record `sig` (the function `name` of another package) referenced as a value
// at `sp`.  Only a function a forwarding lambda can stand for is recorded:
// non-generic, synchronous, every parameter `in`.
// Record a reference to another package's function used as a value, so
// `desugarCheckedFile` lowers it to a typed forwarding lambda. A function the
// lambda cannot stand for (generic, async, a non-`in` parameter, or a type
// not nameable here) is T0128 and returns false: left as a bare path it would
// reach the backend with no diagnostic (D-progress-963).
func recordFuncRefSite(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sig: in ResolvedSignature,
  name: in String,
  sp: in Span,
): Bool {
  if sig.originPackage.length == 0 or sig.originPackage == symTableScopePkg(tbl) {
    val byRef = firstByRefParamName(sig)
    if byRef.length > 0 {
      diag.add(byRefFuncValueDiag(name, byRef, sp))
      return false
    }
    return true
  }
  val ptys: List[Type] = newList()
  var why = if sig.isAsync { "it is async" } else if sig.generics.count > 0 { "it is generic" } else { "" }
  var i = 0
  while i < sig.params.count and why.length == 0 {
    match sig.params[i].mode {
      case PMIn -> ptys.add(sig.params[i].ty)
      case _ -> {
        why = "parameter '" + sig.params[i].name + "' is not an `in` parameter"
      }
    }
    i = i + 1
  }
  val ptesOpt = if why.length == 0 { typeExprsForRef(tbl, ptys, sp) } else { None }
  match ptesOpt {
    case Some(ptes) -> {
      val segs = dottedSegsTc(sig.originPackage)
      segs.add(name)
      val key = recordCopySiteKey(sp)
      if tbl.funcRefSites.containsKey(key) {
        tbl.funcRefSites.remove(key)
      }
      tbl.funcRefSites.add(
        key,
        FuncRefSite(
          calleeSegs = segs,
          paramTypes = ptes,
          retType = typeExprForRef(tbl, sig.returnTy, sp),
          startOffset = sp.startPos.offset
        )
      )
      true
    }
    case None -> {
      val reason = if why.length > 0 { why } else { "a parameter type cannot be named here" }
      diag.add(
        errorDiagnostic(
          "T0128",
          "'" + sig.originPackage + "." + name + "' cannot be used as a function value because " + reason +
            "; wrap the call in a lambda instead",
          sp
        )
      )
      false
    }
  }
}

// The conversion method that widens a numeric argument to `paramTy`, when
// the widening needs one (D-progress-964).
func wideningMethod(paramTy: in Type, argTy: in Type): Option[String] {
  if typeEquiv(paramTy, argTy) {
    return None
  }
  match widenArithmetic(paramTy, argTy) {
    case Some(wt) -> if not typeEquiv(wt, paramTy) { return None }
    case None -> return None
  }
  // A widening to `UInt` or `ULong` zero-extends (`Byte`/`UInt` are
  // unsigned), which `.toUInt()` / `.toULong()` spells out (#7805, #7812).
  if isPrimOf(paramTy, PtULong) {
    return Some(value = "toULong")
  }
  if isPrimOf(paramTy, PtUInt) {
    return Some(value = "toUInt")
  }
  // The other conversion methods exist only on these receivers (not `UInt`,
  // `ULong`, `Nat`: #2050); any other widening is left unconvertible.  A
  // `Float` widens to `Double` with `.toDouble()` (D155).
  if not isNumericOrCharType(argTy) {
    return None
  }
  match unrefine(paramTy) {
    case TyPrim(pt) -> match pt {
      case PtLong -> Some(value = "toLong")
      case PtDouble -> Some(value = "toDouble")
      case PtInt -> Some(value = "toInt")
      case _ -> None
    }
    case _ -> None
  }
}

// True when `t` unrefines to the primitive `pt`.
func isPrimOf(t: in Type, pt: in PrimType): Bool {
  match unrefine(t) {
    case TyPrim(p) -> primEq(p, pt)
    case _ -> false
  }
}

// True when a value of type `src` reaches a `target` slot only by an implicit
// lossless widening along `Byte < Int < Long`, `Byte < UInt < ULong` or
// `Float < Double` (docs/01 §4.1).
func numericWidensTo(target: in Type, src: in Type): Bool {
  if typeEquiv(target, src) {
    return false
  }
  match widenArithmetic(target, src) {
    case Some(wt) -> typeEquiv(wt, target)
    case None -> false
  }
}

// Record `e`, a value of type `src` implicitly widened to `target`, as a
// conversion site, so `Lyric.Mono.desugarCheckedFile` rewrites it to
// `e.<method>()` before any backend sees it.  With `unsignedOnly`, only a
// widening to `ULong` is recorded: every backend widens the signed chain
// correctly at a binding, argument, assignment or operand from the operand
// types alone, but a `UInt` there lowers to the same 32-bit representation
// as an `Int` and would be sign-extended (#7805).  Positions no backend
// widens at (a `return`, a function body's value, a slice literal element)
// record every widening that has a conversion method.
func recordWideningSite(tbl: in SymbolTable, target: in Type, src: in Type, e: in Expr, unsignedOnly: in Bool): Unit {
  if not numericWidensTo(target, src) {
    return
  }
  match wideningMethod(target, src) {
    case Some(m) -> {
      if unsignedOnly and m != "toULong" {
        return
      }
      val key = recordCopySiteKey(e.span)
      if tbl.argConversionSites.containsKey(key) {
        tbl.argConversionSites.remove(key)
      }
      tbl.argConversionSites.add(key, ArgConversionSite(method = m, startOffset = e.span.startPos.offset))
    }
    case None -> ()
  }
}

/// Records `e` as a value that must be in the inline range type `slot`
/// (`Int range 0 ..= 3`), at a position no other pass checks: a record or
/// union field, a collection element, an argument through a function value
/// (#8031).  Function parameters, bindings, returns and `var` assignments are
/// checked by `Lyric.ContractElaborator.insertRangeChecks`.
pub func noteRangeSlot(tbl: in SymbolTable, slot: in Type, e: in Expr, subject: in String): Unit {
  match slot {
    case TyRefined(_, lo, hi, inc, src) -> {
      if isNoSourceSpan(e.span) {
        return
      }
      val key = recordCopySiteKey(e.span)
      if not tbl.rangeCheckSites.containsKey(key) {
        tbl.rangeCheckSites.add(key, RangeCheckSite(subject = subject, source = src, lo = lo, hi = hi, hiInclusive = inc))
      }
    }
    case _ -> ()
  }
}

/// A union case built where an instantiation is expected whose type
/// arguments are range types (`Some(x)` for an `Option[Int range 0 ..= 3]`):
/// each payload is checked against its field at that instantiation, since
/// the case's own type arguments come from the payloads (#8031).
func noteCaseRangeAgainstExpected(
  tbl: in SymbolTable, caseSym: in Symbol, args: in List[CallArg], expected: in Type
): Unit {
  val eargs = match unrefine(expected) { case TyUser(_, _, a) -> a; case _ -> return }
  var anyRange = false
  for a in eargs {
    match a {
      case TyRefined(_, _, _, _, _) -> {
        anyRange = true
      }
      case _ -> ()
    }
  }
  if not anyRange {
    return
  }
  match caseSym.kind {
    case DKUnionCase(parentId, uc) -> match parentUnionDeclOf(tbl, parentId) {
      case Some(decl) -> {
        val gnames = unionDeclGenericNames(decl)
        if gnames.count != eargs.count {
          return
        }
        val scratch: List[Diagnostic] = newList()
        val ftypes = unionCaseFieldTypes(tbl, scratch, uc, gnames, caseSym.originPackage)
        val order = argIndicesInParamOrder(args, unionCaseSlotNames(uc))
        var k = 0
        while k < ftypes.count and k < order.count {
          val ai = order[k]
          if ai >= 0 and ai < args.count {
            noteRangeSlot(tbl, substituteTyVars(ftypes[k], gnames, eargs), callArgExpr(args[ai]), uc.name + " payload")
          }
          k = k + 1
        }
      }
      case None -> ()
    }
    case _ -> ()
  }
}

/// A compound assignment (`r.f += 1`) to a range-refined field or element:
/// the result is checked (#8031).
func noteRangeCompound(tbl: in SymbolTable, slot: in Type, assignSpan: in Span, subject: in String): Unit {
  match slot {
    case TyRefined(_, lo, hi, inc, src) -> {
      if isNoSourceSpan(assignSpan) {
        return
      }
      val key = recordCopySiteKey(assignSpan)
      if not tbl.rangeCompoundSites.containsKey(key) {
        tbl.rangeCompoundSites.add(key, RangeCheckSite(subject = subject, source = src, lo = lo, hi = hi, hiInclusive = inc))
      }
    }
    case _ -> ()
  }
}

/// The subject of a range check on an assignment target: a field or an
/// element; `None` for a variable, which the contract elaborator checks.
/// An assignment to a range-refined field or element: a plain `=` checks the
/// value, a compound assignment the result (#8031).
pub func noteRangeAssign(
  sc: in Scope,
  tbl: in SymbolTable,
  target: in Expr,
  op: in AssignOp,
  targetType: in Type,
  value: in Expr,
  assignSpan: in Span,
): Unit {
  match rangeTargetSubject(sc, target) {
    case Some(subj) -> match op {
      case AssEq -> noteRangeSlot(tbl, targetType, value, subj)
      case _ -> noteRangeCompound(tbl, targetType, assignSpan, subj)
    }
    case None -> ()
  }
}

func rangeTargetSubject(sc: in Scope, target: in Expr): Option[String] {
  match target.kind {
    case EMember(recv, f) -> {
      val owner = rangeReceiverName(sc, recv)
      Some(value = if owner.length > 0 { owner + " field " + f } else { "field " + f })
    }
    case EIndex(_, _) -> Some(value = "element")
    case EParen(inner) -> rangeTargetSubject(sc, inner)
    case _ -> None
  }
}

// The type name of a field assignment's receiver, for the range check's
// message: a local or `self`; "" for any other receiver.
func rangeReceiverName(sc: in Scope, recv: in Expr): String {
  val t = match recv.kind {
    case EPath(p) -> if p.segments.count == 1 {
      match scopeTryFind(sc, p.segments[0]) {
        case Some(b) -> b.ty
        case None -> TyError
      }
    } else {
      TyError
    }
    case ESelf -> sc.selfType
    case _ -> TyError
  }
  match unrefine(t) {
    case TyUser(_, n, _) -> n
    case _ -> ""
  }
}

// `recordWideningSite` for an implicit widening at a position every backend
// already widens signed values at.
func recordUnsignedWidening(tbl: in SymbolTable, target: in Type, src: in Type, e: in Expr): Unit {
  recordWideningSite(tbl, target, src, e, true)
}

// ── Lossless widening inside a value being built (#7813) ────────────────────
//
// A constructor argument of a generic instance (`Some(u)`, `Ok(i)`, a generic
// record or union case) and a tuple element initialise a slot whose type the
// expected instantiation fixes, so a scalar there widens like any initialiser
// (docs/01 §4.1).  The widening is recorded as a conversion site of every
// chain, signed included: the slot is generic (boxed or reified at the
// argument's own type) or a tuple element, and no backend widens a scalar
// there from the operand types.  An existing container value never widens:
// `Option[UInt]` and `Option[ULong]` stay distinct types.
// True when `ds` holds an error (warnings aside).  A second, expected-typed
// pass over a value already checked once reports into a scratch list; if that
// pass fails, its result type may hold `TyError`, which compares equal to
// anything, so the caller keeps the first pass's type and lets the ordinary
// mismatch be reported instead.
func diagnosticsHaveError(ds: in List[Diagnostic]): Bool {
  for d in ds {
    match d.severity {
      case DiagError -> return true
      case DiagWarning -> ()
    }
  }
  false
}

// True when a value of type `src` is a `target` up to lossless numeric
// widenings of its scalar parts: tuple elements and generic type arguments
// of the same type.
func widensOrEquals(target: in Type, src: in Type): Bool {
  if typeEquiv(target, src) or numericWidensTo(target, src) {
    return true
  }
  match unrefine(target) {
    case TyTuple(tes) -> match unrefine(src) { case TyTuple(ses) -> typeListsWidenOrEqual(tes, ses); case _ -> false }
    case TyUser(tid, _, targs) -> match unrefine(src) {
      case TyUser(sid, _, sargs) -> symbolIdEq(tid, sid) and
        typeListsWidenOrEqual(targs, sargs)
      case _ -> false
    }
    case _ -> false
  }
}

func typeListsWidenOrEqual(targets: in List[Type], srcs: in List[Type]): Bool {
  if targets.count != srcs.count {
    return false
  }
  var i = 0
  while i < targets.count {
    if not widensOrEquals(targets[i], srcs[i]) {
      return false
    }
    i = i + 1
  }
  true
}

// True when `src` differs from `target` only by lossless numeric widenings
// of its scalar parts (`Option[UInt]` against `Option[ULong]`,
// `(UInt, Int)` against `(ULong, Int)`).
// True when `t` is, or has among its type arguments, tuple elements or
// nullable payload, an inline range type.
func typeHasRangeArg(t: in Type): Bool {
  match t {
    case TyRefined(_, _, _, _, _) -> true
    case TyUser(_, _, args) -> {
      for a in args {
        if typeHasRangeArg(a) {
          return true
        }
      }
      false
    }
    case TyTuple(elems) -> {
      for a in elems {
        if typeHasRangeArg(a) {
          return true
        }
      }
      false
    }
    case TyNullable(inner) -> typeHasRangeArg(inner)
    case _ -> false
  }
}

func widensStructurally(target: in Type, src: in Type): Bool {
  not typeEquiv(target, src) and widensOrEquals(target, src)
}

// The type a constructor argument of `t` takes where `exp` is expected of
// it: `exp` when `t` widens to it, after recording the widening of `argE`
// for `Lyric.Mono` to spell out; `t` otherwise.
func widenedSlotType(tbl: in SymbolTable, exp: in Type, t: in Type, argE: in Expr): Type {
  if numericWidensTo(exp, t) {
    match wideningMethod(exp, t) {
      case Some(_) -> {
        recordWideningSite(tbl, exp, t, argE, false)
        return exp
      }
      case None -> ()
    }
  }
  t
}

// The type each argument of a constructor is expected to have when the
// constructed type is expected at the instantiation `eargs` of its type
// parameters `gnames`: the declared type of the slot (named `slotNames`,
// typed `slotTypes`) the argument fills, instantiated.  `TyError` (no
// expectation) for an argument that fills no slot or whose instantiated
// slot type is not closed.
func ctorArgsExpected(
  args: in List[CallArg],
  slotNames: in List[String],
  slotTypes: in List[Type],
  gnames: in List[String],
  eargs: in List[Type],
): List[Type] {
  val exps: List[Type] = newList()
  var i = 0
  while i < args.count {
    exps.add(TyError)
    i = i + 1
  }
  if eargs.count != gnames.count or slotNames.count != slotTypes.count {
    return exps
  }
  val srcIdx = argIndicesInParamOrder(args, slotNames)
  var k = 0
  while k < srcIdx.count {
    val ai = srcIdx[k]
    if ai >= 0 and ai < exps.count {
      val st = substituteTyVars(slotTypes[k], gnames, eargs)
      if typeIsClosed(st) {
        exps[ai] = st
      }
    }
    k = k + 1
  }
  exps
}

// Infer each constructor argument against its expected type (`exps`, from
// `ctorArgsExpected`), widening a scalar argument to it.
func inferCtorArgsExpected(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  args: in List[CallArg],
  exps: in List[Type],
): List[Type] {
  val tys: List[Type] = newList()
  var i = 0
  while i < args.count {
    val argE = callArgExpr(args[i])
    val exp = if i < exps.count { exps[i] } else { TyError }
    if typeIsHole(exp) {
      tys.add(inferExpr(sc, tbl, sigs, diag, argE))
    } else {
      tys.add(widenedSlotType(tbl, exp, inferExprExpected(sc, tbl, sigs, diag, argE, exp), argE))
    }
    i = i + 1
  }
  tys
}

// The identity conversion that names `t` when `t` is `UInt` or `ULong`.
func unsignedIdentityMethod(t: in Type): Option[String] {
  match unrefine(t) {
    case TyPrim(pt) -> match pt {
      case PtUInt -> Some(value = "toUInt")
      case PtULong -> Some(value = "toULong")
      case _ -> None
    }
    case _ -> None
  }
}

// Record `e`, an operand of type `t` at a position whose lowering depends on
// signedness, as a conversion site when `t` is `UInt` or `ULong` (#7812).
// `UInt` and `ULong` share their machine representation with `Int` and
// `Long` on every backend, so a backend can only choose unsigned
// stringification, comparison, division or remainder when the operand says it
// is unsigned.  `Lyric.Mono.desugarCheckedFile` rewrites the site to the
// identity `e.toUInt()` / `e.toULong()`, which the backends recognise.  The
// positions are: a stringified value (`println`/`print`/`toString`/
// `format1`–`format4` arguments, a `.toString()` receiver, an interpolated
// segment, the right operand of a `String` `+` or `+=`), an operand of `<`,
// `<=`, `>`, `>=`, `/` or `%`, and the value of a `/=` or `%=`.  A widening
// already recorded at `e` is kept: it converts to `ULong`, which is unsigned
// too.
func recordUnsignedOperand(tbl: in SymbolTable, t: in Type, e: in Expr): Unit {
  match unsignedIdentityMethod(t) {
    case Some(m) -> {
      if spellsUnsigned(e) {
        return
      }
      val key = recordCopySiteKey(e.span)
      if not tbl.argConversionSites.containsKey(key) {
        tbl.argConversionSites.add(key, ArgConversionSite(method = m, startOffset = e.span.startPos.offset))
      }
    }
    case None -> ()
  }
}

// `recordUnsignedOperand` for the value of a compound assignment `target op=
// value`: the value of a `/=` or `%=` on an unsigned target, or the value
// appended by a `String` `+=`.
func recordUnsignedCompoundValue(
  tbl: in SymbolTable,
  op: in AssignOp,
  targetType: in Type,
  valueType: in Type,
  value: in Expr,
  stringPlus: in Bool,
): Unit {
  match op {
    case AssSlash -> recordUnsignedOperand(tbl, targetType, value)
    case AssPercent -> recordUnsignedOperand(tbl, targetType, value)
    case AssPlus -> if stringPlus {
      recordUnsignedOperand(tbl, valueType, value)
      recordShowOperand(tbl, valueType, value)
    }
    case _ -> ()
  }
}

// True when `argTy` satisfies `paramTy` only by a numeric widening that a call
// through a function value cannot convert (one `wideningMethod` has no
// method for). The erased call would pass the argument boxed at its own type,
// so such a call is rejected rather than failing at run time.  Every current
// widening chain has a method, `Float < Double` included since D155; this
// keeps a future chain from silently miscompiling until it gets one.
func unconvertibleWidening(paramTy: in Type, argTy: in Type): Bool {
  if typeEquiv(paramTy, argTy) {
    return false
  }
  match widenArithmetic(paramTy, argTy) {
    case Some(wt) -> if typeEquiv(wt, paramTy) and not typeEquiv(unrefine(paramTy), unrefine(argTy)) {
      match wideningMethod(paramTy, argTy) {
        case Some(_) -> false
        case None -> true
      }
    } else {
      false
    }
    case None -> false
  }
}

// Record a widened argument of a call through a function value: the call is
// erased, so the argument reaches the function boxed at its own type unless
// the widening is made explicit.
func recordArgConversion(tbl: in SymbolTable, arg: in CallArg, paramTy: in Type, argTy: in Type): Unit {
  val argExpr = match arg { case CAPositional(ex) -> ex; case CANamed(_, ex, _) -> ex }
  match wideningMethod(paramTy, argTy) {
    case Some(m) -> {
      val key = recordCopySiteKey(argExpr.span)
      if tbl.argConversionSites.containsKey(key) {
        tbl.argConversionSites.remove(key)
      }
      tbl.argConversionSites.add(key, ArgConversionSite(method = m, startOffset = argExpr.span.startPos.offset))
    }
    case None -> ()
  }
}

// Record the widened arguments of a direct call to another package's
// function (D-progress-969). Codegen converts a widened argument only when it
// knows the callee's parameter types; a restored package's signature reaches
// the MSIL call site but not its argument lowering, so an `Int` literal was
// passed as `int32` to a `Long` parameter.
func recordSigArgConversions(
  tbl: in SymbolTable,
  sig: in ResolvedSignature,
  args: in List[CallArg],
  argTypes: in List[Type],
): Unit {
  if args.count > sig.params.count {
    return
  }
  val paramNames: List[String] = newList()
  var pni = 0
  while pni < sig.params.count {
    paramNames.add(sig.params[pni].name)
    pni = pni + 1
  }
  val srcIdx = argIndicesInParamOrder(args, paramNames)
  var k = 0
  while k < sig.params.count {
    val ai = srcIdx[k]
    val isIn = match sig.params[k].mode { case PMIn -> true; case _ -> false }
    if ai >= 0 and ai < args.count and ai < argTypes.count and isIn {
      recordArgConversion(tbl, args[ai], sig.params[k].ty, argTypes[ai])
    }
    k = k + 1
  }
}

/// Every recorded cross-package function value that is not a call callee
/// (D-progress-963), for `Lyric.Mono.desugarRecordCopiesFile`.
pub func funcValueSites(tbl: in SymbolTable): Map[String, FuncRefSite] {
  val valueSites: Map[String, FuncRefSite] = newMap()
  val keys = mapKeys(tbl.funcRefSites)
  var i = 0
  while i < keys.count {
    if not tbl.funcRefCallees.containsKey(keys[i]) {
      match mapGet(tbl.funcRefSites, keys[i]) {
        case Some(site) -> valueSites.add(keys[i], site)
        case None -> ()
      }
    }
    i = i + 1
  }
  valueSites
}

func calleeSegmentList(e: in Expr): List[String] {
  val segs: List[String] = newList()
  val _ = calleeSegments(e, segs)
  segs
}

// Whether `recv` is the dotted path of an `extern package` block that
// declares a member `member` (`lyric.db.Postgres` for `connect`, #7934).
func isExternBlockQualifier(sc: in Scope, tbl: in SymbolTable, recv: in Expr, member: in String): Bool {
  val segs: List[String] = newList()
  if calleeSegments(recv, segs) and segs.count >= 1 and not scopeHasName(sc, segs[0]) {
    return symTableHasExternBlockMember(tbl, modulePathJoin(segs), member)
  }
  false
}

// The signature of package `pkg`'s function `name` with `arity` parameters.
func pkgFuncSig(
  sigs: in Map[String, ResolvedSignature], pkg: in String, name: in String, arity: in Int
): Option[ResolvedSignature] {
  val arityKey = name + "/" + toString(arity)
  val cands = gatherOverloadCandidates(sigs, arityKey)
  var i = 0
  while i < cands.count {
    if cands[i].originPackage == pkg {
      return Some(value = cands[i])
    }
    i = i + 1
  }
  match mapGet(sigs, arityKey) {
    case Some(s) -> if s.originPackage == pkg { Some(value = s) } else { None }
    case None -> None
  }
}

// The first `out`/`inout` parameter of `sig`, or "".  A function type has no
// by-reference parameters, so such a function is not a function value.
func firstByRefParamName(sig: in ResolvedSignature): String {
  for p in sig.params {
    if modeNeedsLValue(p.mode) {
      return p.name
    }
  }
  ""
}

func byRefFuncValueDiag(name: in String, paramName: in String, sp: in Span): Diagnostic {
  errorDiagnostic(
    "T0128",
    "'" + name + "' cannot be used as a function value because parameter '" + paramName +
      "' is an `out`/`inout` parameter: a function type has no by-reference parameters; wrap the call in a lambda over a `var` instead",
    sp
  )
}

func funcValueType(sig: in ResolvedSignature): Type {
  val pts: List[Type] = newList()
  var i = 0
  while i < sig.params.count {
    pts.add(sig.params[i].ty)
    i = i + 1
  }
  TyFunction(params = pts, ret = sig.returnTy, isAsync = sig.isAsync)
}

// A qualified function value `Pkg.fn` (qualifier `pkg`, already matched by
// the caller against a known package): its type, or `None` when that package
// declares no function `name`.  Several same-named functions in the package
// are T0123, since a value reference cannot pick an overload.
// How many functions named `name` package `pkg` declares.
func pkgFuncCount(tbl: in SymbolTable, pkg: in String, name: in String): Int {
  val all = symTableTryFindAll(tbl, name)
  var n = 0
  var i = 0
  while i < all.count {
    match all[i].kind {
      case DKFunc(_) -> if all[i].originPackage == pkg { n = n + 1 }
      case _ -> ()
    }
    i = i + 1
  }
  n
}

// True when a bare function VALUE `name` cannot pick one function: the
// current package declares it at several arities, or declares it and an import
// in scope declares one of an arity the package does not (a local function
// shadows an import only at its own arity, #7527).
func localShadowsImportedArity(tbl: in SymbolTable, name: in String): Bool {
  val scopePkg = symTableScopePkg(tbl)
  val all = symTableTryFindAll(tbl, name)
  val localArities: List[Int] = newList()
  val importedArities: List[Int] = newList()
  var i = 0
  while i < all.count {
    match all[i].kind {
      case DKFunc(fd) -> {
        if all[i].originPackage == scopePkg {
          // A package's own function can be registered more than once (a
          // project build holds it as the file and as an imported package), so
          // count each arity once.
          if not intListHas(localArities, fd.params.count) {
            localArities.add(fd.params.count)
          }
          // An import under an alias is named `Alias.name`, never bare (#8155).
        } else if all[i].originPackage.length > 0 and symTableScopeAllows(tbl, all[i].originPackage) and not tbl.importAliases.containsKey(all[i].originPackage) {
          if not intListHas(importedArities, fd.params.count) {
            importedArities.add(fd.params.count)
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  if localArities.count == 0 {
    return false
  }
  if localArities.count > 1 {
    return true
  }
  for a in importedArities {
    if not intListHas(localArities, a) {
      return true
    }
  }
  false
}

func intListHas(xs: in List[Int], v: in Int): Bool {
  for x in xs {
    if x == v {
      return true
    }
  }
  false
}

func resolveQualifiedFuncValue(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  pkg: in String,
  name: in String,
  sp: in Span,
): Option[Type] {
  // A call's callee is resolved by the call, with its arguments.
  if tbl.funcRefCallees.containsKey(recordCopySiteKey(sp)) {
    return None
  }
  val all = symTableTryFindAll(tbl, name)
  val funcs: List[Symbol] = newList()
  val reexported: List[Symbol] = newList()
  var i = 0
  while i < all.count {
    match all[i].kind {
      case DKFunc(_) -> {
        if pkgMatchesQualifier(all[i].originPackage, pkg) {
          funcs.add(all[i])
        } else if pkgReexportsFrom(tbl, pkg, all[i].originPackage) {
          reexported.add(all[i])
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  if funcs.count == 0 {
    for rc in reexported {
      funcs.add(rc)
    }
  }
  if funcs.count == 0 {
    return None
  }
  // Several packages can end in the qualifier (`Lib.Bar`, `Other.Bar`); the
  // ones the current package imports win, as they would for the call. With
  // none imported, every match stays, matching unimported-name resolution
  // elsewhere (#6703).
  val scopePkg = symTableScopePkg(tbl)
  val inScope: List[Symbol] = newList()
  var k = 0
  while k < funcs.count {
    if funcs[k].originPackage == scopePkg or symTableScopeAllows(tbl, funcs[k].originPackage) {
      inScope.add(funcs[k])
    }
    k = k + 1
  }
  val chosen = if inScope.count > 0 { inScope } else { funcs }
  if chosen.count > 1 {
    val origins: List[String] = newList()
    for c in chosen {
      if not origins.contains(c.originPackage) {
        origins.add(c.originPackage)
      }
    }
    if origins.count > 1 {
      diag.add(
        errorDiagnostic(
          "T0123",
          "'" + pkg + "." + name + "' is ambiguous: the qualifier '" + pkg + "' ends " + toString(origins.count) +
            " packages (" +
            joinPackageNames(origins) +
            "), none of which this package imports; write the full package path (for example '" +
            origins[0] +
            "." +
            name +
            "') or import the one you mean",
          sp
        )
      )
    } else {
      diag.add(
        errorDiagnostic(
          "T0123",
          "'" + pkg + "." + name +
            "' names several functions; a function value cannot pick an overload, so wrap the call in a lambda with typed parameters",
          sp
        )
      )
    }
    return Some(value = TyError)
  }
  val sym = chosen[0]
  checkImportedVisibility(tbl, sym, sp, diag)
  val arity = match sym.kind { case DKFunc(fd) -> fd.params.count; case _ -> 0 }
  match pkgFuncSig(sigs, sym.originPackage, name, arity) {
    case Some(sig) -> if recordFuncRefSite(tbl, diag, sig, name, sp) {
      Some(value = funcValueType(sig))
    } else {
      Some(value = TyError)
    }
    case None -> None
  }
}

// Whether some loaded package's path ends in the dotted `qualifier`
// (`Sub.Bar` for `Lib.Sub.Bar`), as `pkgMatchesQualifier` reads it (#7368).
func anyPackageEndsWithQualifier(tbl: in SymbolTable, qualifier: in String): Bool {
  var i = 0
  while i < tbl.symbols.count {
    if pkgMatchesQualifier(tbl.symbols[i].originPackage, qualifier) {
      return true
    }
    i = i + 1
  }
  false
}

// #7799: does a package `pkg` re-exports declare `name`?
func packageReexportsMember(tbl: in SymbolTable, pkg: in String, name: in String): Bool {
  for q in symTableReexportClosure(tbl, pkg) {
    if symTablePackageHasMember(tbl, q, name) {
      return true
    }
  }
  false
}

// Whether the bare `name` denotes a module-level `val` or `const` in scope
// (the current package's own declaration first, then the imports', as
// `symTableTryFindOne` orders them) rather than a function.
func bareNameIsModuleValue(tbl: in SymbolTable, name: in String): Bool {
  match symTableTryFindOne(tbl, name) {
    case Some(vs) -> match vs.kind { case DKVal(_) -> true; case DKConst(_) -> true; case _ -> false }
    case None -> false
  }
}

func resolveExprPath(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  path: in ModulePath,
  span: in Span,
): Type {
  if path.segments.count != 1 {
    // A multi-segment `EPath` reaching here was always collapsed by
    // `Lyric.AliasRewriter.rewriteQualifiedMemberChain` from a dotted member
    // chain rooted at a real Lyric package import — the rewriter's alias
    // table excludes every `import extern` (`collectAliases`'s
    // `not imp.isExtern` guard), so this never fires for a deferred
    // auto-FFI/extern-type lookup. When the leading segments name a package
    // the checker actually has symbols for, but none of them is the
    // trailing segment, the reference is a genuine unknown name (#6361 —
    // e.g. `Std.Char.isUpperCase`, a typo'd/stale spelling of `isUpper`)
    // rather than something codegen might still resolve, so it must be
    // flagged instead of silently falling through to `TyError`.
    if path.segments.count == 0 {
      return TyError
    }
    val name = path.segments[path.segments.count - 1]
    val prefix: List[String] = newList()
    var pi = 0
    while pi < path.segments.count - 1 {
      prefix.add(path.segments[pi])
      pi = pi + 1
    }
    val pkg = modulePathJoin(prefix)
    checkQualifiedPackageRef(tbl, sc, prefix, name, span, diag)
    // #6378: a package known ONLY via `extern package { ... }` block members
    // (its file has no ordinary `pub func`/`pub val`/… at all, e.g.
    // `AwsXRay.Kernel.Net`) never adds anything to `tbl.symbols`, so
    // `symTablePackageHasAnySymbol` alone can't tell it apart from a package
    // that was never resolved at all — checking
    // `symTablePackageHasAnyExternBlockMember` too closes that gap without
    // reopening #6361 for this package shape.
    match resolveQualifiedFuncValue(tbl, sigs, diag, pkg, name, span) {
      case Some(ft) -> return ft
      case None -> ()
    }
    // A package-qualified module-level `val` (#8283).
    match moduleValSymbolOfSegs(sc, tbl, path.segments) {
      case Some(vsym) -> match vsym.kind {
        case DKVal(vd) -> {
          checkImportedVisibility(tbl, vsym, span, diag)
          return moduleValReadType(tbl, sigs, vsym, vd)
        }
        case _ -> ()
      }
      case None -> ()
    }
    if importedPackageMissing(tbl, sigs, pkg, name) {
      diag.add(
        errorDiagnostic(
          "T0215",
          "package " + pkg + " is imported but no dependency provides it, so '" + pkg + "." + name +
            "' cannot be resolved (a stale or missing restored dependency?)",
          span
        )
      )
      return TyError
    }
    val pkgKnown = symTablePackageHasAnySymbol(tbl, pkg) or symTablePackageHasAnyExternBlockMember(tbl, pkg)
    if pkgKnown and not symTablePackageHasMember(tbl, pkg, name) and not symTableHasExternBlockMember(tbl, pkg, name) and not packageReexportsMember(tbl, pkg, name) {
      diag.add(errorDiagnostic("T0020", "unknown name '" + pkg + "." + name + "'", span))
    }
    return TyError
  }
  val name = path.segments[0]
  match scopeTryFind(sc, name) {
    case Some(b) -> {
      return b.ty
    }
    case None -> {
    }
  }
  // The name's symbol in scope (the current package's first, then its
  // imports') is a `val` or `const`: it hides an imported function of that
  // name, as the package's own declarations hide its imports (#8283).
  val valueInScope = bareNameIsModuleValue(tbl, name)
  val noSig: Option[ResolvedSignature] = None
  val bareSig = match mapGet(sigs, name) {
    case Some(first) -> if valueInScope { noSig } else { visibleBareSig(tbl, sigs, name, first) }
    case None -> noSig
  }
  match bareSig {
    case Some(sig) -> {
      symTableNoteBareFuncUse(tbl, sig.originPackage, name, span)
      // #6652: `sigs`'s first-in-wins insertion policy for imported functions
      // (typechecker_checker.l, "Sig-map insertion policy") means a bare
      // function name reaching here can silently resolve to whichever
      // package's `IFunc` was collected first, hiding a genuine cross-package
      // collision — the same hazard #6287 closed for bare vals/consts/union
      // cases below. Gate it with the same helper, before consulting `sigs`
      // for a type, so this stays the single authoritative T0123 site for a
      // bare callee name (see `constructorSymbolOf`'s comment above, which
      // depends on that being true).
      if checkBareNameAmbiguity(tbl, diag, name, span) {
        return TyError
      }
      if not tbl.funcRefCallees.containsKey(recordCopySiteKey(span)) and localShadowsImportedArity(tbl, name) {
        diag.add(
          errorDiagnostic(
            "T0123",
            "'" + name +
              "' names several functions; a function value cannot pick an overload, so wrap the call in a lambda with typed parameters",
            span
          )
        )
        return TyError
      }
      // #1484: a function resolves via `sigs` (no visibility there) — consult
      // the symbol table for the same name to enforce cross-package visibility.
      match symTableTryFindOne(tbl, name) {
        case Some(sym) -> {
          checkImportedVisibility(tbl, sym, span, diag)
          // `sigs` keeps the first-registered function of this name from ANY
          // loaded package; the value is the one in scope here, the same one
          // a call would bind (D-progress-963).
          val scopePkg = symTableScopePkg(tbl)
          val inScope = sym.originPackage == scopePkg or symTableScopeAllows(tbl, sym.originPackage)
          val isCallee = tbl.funcRefCallees.containsKey(recordCopySiteKey(span))
          match sym.kind {
            case DKFunc(fd) -> if not isCallee and inScope and sym.originPackage.length > 0 and sym.originPackage != scopePkg {
              // An overloaded name leaves the value ambiguous, as for a
              // qualified reference (`resolveQualifiedFuncValue`).
              if pkgFuncCount(tbl, sym.originPackage, name) > 1 {
                diag.add(
                  errorDiagnostic(
                    "T0123",
                    "'" + name +
                      "' names several functions; a function value cannot pick an overload, so wrap the call in a lambda with typed parameters",
                    span
                  )
                )
                return TyError
              }
              match pkgFuncSig(sigs, sym.originPackage, name, fd.params.count) {
                case Some(scopedSig) -> {
                  if not recordFuncRefSite(tbl, diag, scopedSig, name, span) {
                    return TyError
                  }
                  return funcValueType(scopedSig)
                }
                case None -> ()
              }
            }
            case _ -> ()
          }
        }
        case None -> {
          // The only functions of this name are hidden by the import rule.
          val hint = symTableHiddenImportHint(tbl, name)
          if hint.length > 0 {
            diag.add(errorDiagnostic("T0020", "unknown name '" + name + "'" + hint, span))
            return TyError
          }
        }
      }
      if not tbl.funcRefCallees.containsKey(recordCopySiteKey(span)) {
        val byRef = firstByRefParamName(sig)
        if byRef.length > 0 {
          diag.add(byRefFuncValueDiag(name, byRef, span))
          return TyError
        }
      }
      val pts: List[Type] = newList()
      var i = 0
      while i < sig.params.count {
        pts.add(sig.params[i].ty)
        i = i + 1
      }
      recordOwnFuncValueSite(tbl, sig, name, span)
      return TyFunction(params = pts, ret = sig.returnTy, isAsync = sig.isAsync)
    }
    case None -> {
    }
  }
  match codegenBuiltinType(name) {
    case Some(t) -> return t
    case None -> {
    }
  }
  // #6287: a bare non-function name (union case / const / val — the function
  // case above is checked separately since `sigs` resolves it earlier)
  // ambiguous across two-or-more imported packages must be qualified, not
  // silently resolved to whichever package's symbol was registered last.
  if checkBareNameAmbiguity(tbl, diag, name, span) {
    return TyError
  }
  match symTableTryFindOne(tbl, name) {
    case Some(sym) -> {
      checkImportedVisibility(tbl, sym, span, diag)
      symTableNoteBareUse(tbl, sym, span)
      match sym.kind {
        case DKUnionCase(_, _) -> {
          // A bare constructor reference like `Some` without call args infers as the
          // parent union with TyError type-args (uninferable without arguments).
          // The enclosing ECall arm re-infers with actual arg types and wins.
          return inferUnionCaseConstruction(tbl, diag, sym, newList(), newList(), span, false)
        }
        // A val's or const's declared type, and an untyped val's initializer,
        // are written in the declaring package's scope, not the reading
        // file's (docs/01 §9.2: `import P.{v}` need not also list `v`'s type).
        case DKConst(cd) -> {
          val ctx = newGenericContext()
          val saved = enterDeclaringScopeIfForeign(tbl, sym)
          val t = resolveType(tbl, ctx, diag, cd.ty)
          restoreScope(tbl, saved)
          return t
        }
        case DKVal(vd) -> return moduleValReadType(tbl, sigs, sym, vd)
        // A bare enum case with no expected type is a value of its enum, so
        // `println(Green)` renders by case name and `val s: String = Green` is
        // rejected (#8652). Only a case name no other enum or union shares is typed:
        // two enums sharing a case name are told apart by the scrutinee or the
        // expected type, which this site cannot see.
        case DKEnumCase(pid, _) -> {
          var unshared = true
          for other in symTableTryFindAll(tbl, name) {
            match other.kind {
              case DKEnumCase(opid, _) -> if not (symbolIdEq(opid, pid) or (other.originPackage == sym.originPackage and typeNameOfId(tbl, opid) == typeNameOfId(tbl, pid))) {
                unshared = false
              }
              case _ -> {
                unshared = false
              }
            }
          }
          if unshared {
            val noArgs: List[Type] = newList()
            return TyUser(id = pid, name = typeNameOfId(tbl, pid), args = noArgs)
          }
        }
        case _ -> {
        }
      }
    }
    case None -> {
      diag.add(errorDiagnostic("T0020", "unknown name '" + name + "'" + symTableHiddenImportHint(tbl, name), span))
    }
  }
  TyError
}

// The enum a qualified case value `Color.Red` / `Pkg.Color.Red` is a value of
// (#8254).  Typed as the enum, it is a receiver the method-call resolution
// binds dot-named functions of; left untyped, `val c = Color.Red; c.num()`
// reached codegen unresolved.  A local named like the type is a field chain,
// not a type.
func qualifiedEnumCaseType(sc: in Scope, tbl: in SymbolTable, recv: in Expr, name: in String): Option[Type] {
  val segs: List[String] = newList()
  if not flattenCalleePathSegs(recv, segs) or segs.count == 0 {
    return None
  }
  match scopeTryFind(sc, segs[0]) {
    case Some(_) -> return None
    case None -> ()
  }
  val typeName = segs[segs.count - 1]
  var found: Option[Symbol] = None
  if segs.count == 1 {
    // Only a name no other enum of the program shares is typed: with two
    // packages declaring an enum `Mode`, the backends and the checker's
    // sites would have to agree on which one a bare `Mode.Fast` names.
    val candidates: List[Symbol] = newList()
    for cand in symTableTryFindAll(tbl, typeName) {
      match cand.kind {
        case DKEnum(_, _) -> candidates.add(cand)
        case _ -> ()
      }
    }
    var sameOrigin = candidates.count > 0
    for cand in candidates {
      if cand.originPackage != candidates[0].originPackage {
        sameOrigin = false
      }
    }
    if sameOrigin {
      // The declaration a written `Mode` resolves to, so the case's type is
      // the parameter and annotation type of its own enum.
      found = match symTableTryFindOne(tbl, typeName) {
        case Some(one) -> match one.kind { case DKEnum(_, _) -> Some(value = one); case _ -> None }
        case None -> None
      }
    }
  } else {
    val quals: List[String] = newList()
    var qi = 0
    while qi < segs.count - 1 {
      quals.add(segs[qi])
      qi = qi + 1
    }
    found = symTableTryFindInPackage(tbl, modulePathJoin(quals), typeName)
  }
  match found {
    case Some(sym) -> match sym.kind {
      case DKEnum(eid, decl) -> {
        for c in decl.cases {
          if c.name == name {
            val noArgs: List[Type] = newList()
            return Some(value = TyUser(id = eid, name = sym.name, args = noArgs))
          }
        }
        None
      }
      case _ -> None
    }
    case None -> None
  }
}

// True when `t` can stand where a `Bool` is required.  `typeEquiv` treats a
// type variable as a wildcard, but a bare type parameter is not `Bool` for
// every instantiation, so a condition, clause or operand of that type is
// rejected (#8332).
func typeIsBoolOperand(t: in Type): Bool {
  match t {
    case TyVar(_) -> false
    case _ -> typeEquiv(t, TyPrim(pt = PtBool))
  }
}

// A quantifier's `where` guard and body are propositions (#8322): T0132,
// the contract-clause type error, when either is not `Bool`.  An operand
// already in error, or one that never yields, was reported where it fails.
func requireQuantifierBool(diag: in List[Diagnostic], kw: in String, part: in String, t: in Type, sp: in Span): Unit {
  val reported = match t {
    case TyError -> true
    case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }
    case _ -> false
  }
  if not reported and not typeIsBoolOperand(t) {
    val article = if kw == "exists" { "an " } else { "a " }
    diag.add(errorDiagnostic("T0132", article + kw + " " + part + " must be Bool (got " + renderType(t) + ")", sp))
  }
}

// The functions named `name` a bare reference may mean under the file's
// import rule, in registration order; `arity` < 0 takes every arity.
func visibleBareFuncSigs(
  tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], name: in String, arity: in Int
): List[ResolvedSignature] {
  val all = gatherOverloadCandidates(sigs, byNameSigKey(name))
  val acc: List[ResolvedSignature] = newList()
  var i = 0
  while i < all.count {
    val cand = all[i]
    if (arity < 0 or cand.params.count == arity) and symTableBareFuncTier(tbl, cand.originPackage, name) >= 0 {
      acc.add(cand)
    }
    i = i + 1
  }
  acc
}

// The functions named `name` a call writing `args` may bind under the file's
// import rule: those the call fits (`sigDefaultsFilled`), in registration
// order.
func visibleBareFuncSigsFor(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  name: in String,
  args: in List[CallArg],
): List[ResolvedSignature] {
  val acc: List[ResolvedSignature] = newList()
  for cand in visibleBareFuncSigs(tbl, sigs, name, -1) {
    if sigDefaultsFilled(cand, args) >= 0 {
      acc.add(cand)
    }
  }
  acc
}

// How many of `sig`'s parameters a call writing `args` leaves to their
// defaults, or -1 when the call does not fit it (`callDefaultsFilled`).
func sigDefaultsFilled(sig: in ResolvedSignature, args: in List[CallArg]): Int {
  val names: List[String] = newList()
  val defaults: List[Bool] = newList()
  for p in sig.params {
    names.add(p.name)
    defaults.add(p.hasDefault)
  }
  callDefaultsFilled(names, defaults, 0, args)
}

// The declaration a call binds among `cands`, the declarations of one name
// that the file's imports make equally visible (#8355, D210).  A declaration
// is a candidate when the call fits it (`sigDefaultsFilled`: every parameter
// the call leaves out has a default, a named argument names one of its
// parameters) and the arguments' types satisfy its parameters.  Of those the
// one the call supplies in full wins, then the one that leaves the fewest
// parameters to their defaults (`fewestDefaultsCandidates`); a named argument
// that only one declares has already narrowed them.  Among declarations that
// still tie, a non-generic one beats a generic one; several left, with
// defaults filled, are added to `ambiguous` (the caller reports T0200) and
// the first is returned so that the call is checked.  A call supplying every
// parameter of several keeps the first in registration order (the stdlib's
// `toUpper(Char)` and `toUpper(String)`).  `primary` is the user's own
// definition that shadows an imported one of the same shape.  When no
// declaration's types match, the first of those the call fits with the
// fewest defaults (or `primary`) is returned, so the call reports the
// mismatch there.
func pickByShape(
  tbl: in SymbolTable,
  cands: in List[ResolvedSignature],
  args: in List[CallArg],
  argTypes: in List[Type],
  primary: in Option[ResolvedSignature],
  ambiguous: in List[ResolvedSignature],
): Option[ResolvedSignature] {
  val fitting: List[ResolvedSignature] = newList()
  val typed: List[ResolvedSignature] = newList()
  for c in cands {
    if sigDefaultsFilled(c, args) >= 0 and not sigListHas(fitting, c) {
      fitting.add(c)
      if suppliedArgsMatch(tbl, c.params, argTypesInSigOrder(c, 0, args, argTypes)) {
        typed.add(c)
      }
    }
  }
  if fitting.count == 0 {
    return None
  }
  val typeMatched = typed.count > 0
  val pool = if typeMatched { typed } else { fitting }
  val fills: List[Int] = newList()
  for c in pool {
    fills.add(sigDefaultsFilled(c, args))
  }
  val group: List[ResolvedSignature] = newList()
  for i in fewestDefaultsCandidates(fills) {
    group.add(pool[i])
  }
  val fill = sigDefaultsFilled(group[0], args)
  match primary {
    case Some(p) -> if sigListHas(group, p) { return primary }
    case None -> ()
  }
  if group.count == 1 or not typeMatched {
    return Some(value = group[0])
  }
  val plain: List[ResolvedSignature] = newList()
  for m in group {
    if m.generics.count == 0 {
      plain.add(m)
    }
  }
  if fill == 0 {
    return if plain.count > 0 { Some(value = plain[0]) } else { Some(value = group[0]) }
  }
  if plain.count == 1 {
    return Some(value = plain[0])
  }
  val tied = if plain.count > 1 { plain } else { group }
  for m in tied {
    ambiguous.add(m)
  }
  Some(value = tied[0])
}

// The function a bare call `name(args)` binds: the lowest resolution tier
// (`symTableBareFuncTier`) that declares a visible function of that name
// that the call fits decides, as for every other bare name; within it
// `pickByShape` chooses.  A matching function of a higher tier never answers
// instead, which the backends' name-and-arity lookups could not follow.
// `None` when no visible function of the name fits the call.
func tieredBareSig(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  name: in String,
  args: in List[CallArg],
  argTypes: in List[Type],
  primary: in Option[ResolvedSignature],
  ambiguous: in List[ResolvedSignature],
): Option[ResolvedSignature] {
  val visible = visibleBareFuncSigsFor(tbl, sigs, name, args)
  if visible.count == 0 {
    return None
  }
  var tier = 3
  val tiers: List[Int] = newList()
  for v in visible {
    val t = symTableBareFuncTier(tbl, v.originPackage, name)
    tiers.add(t)
    if t >= 0 and t < tier {
      tier = t
    }
  }
  val inTier: List[ResolvedSignature] = newList()
  var i = 0
  while i < visible.count {
    if tiers[i] == tier {
      inTier.add(visible[i])
    }
    i = i + 1
  }
  pickByShape(tbl, inTier, args, argTypes, primary, ambiguous)
}

// The signature a bare `name` denotes: the visible function of that name in
// the lowest resolution tier (`symTableBareFuncTier`), `first` (the
// `sigs[name]` slot) winning within its tier; `None` when every one is
// hidden.
func visibleBareSig(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  name: in String,
  first: in ResolvedSignature,
): Option[ResolvedSignature] {
  val visible = visibleBareFuncSigs(tbl, sigs, name, -1)
  val firstTier = symTableBareFuncTier(tbl, first.originPackage, name)
  val tiers: List[Int] = newList()
  for v in visible {
    tiers.add(symTableBareFuncTier(tbl, v.originPackage, name))
  }
  var tier = 0
  while tier <= 2 {
    if firstTier == tier {
      return Some(value = first)
    }
    var i = 0
    while i < visible.count {
      if tiers[i] == tier {
        return Some(value = visible[i])
      }
      i = i + 1
    }
    tier = tier + 1
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Top-level inference.
// ─────────────────────────────────────────────────────────────────────────────
// The success/element type unwrapped by `?` from a `Result[T, E]` / `Option[T]`
// operand.  Built-ins are recognised by their declared `TyUser` name, matching
// the established convention in `propagate.l` (`monadOfRet`) and the codegen
// side.  A non-monadic operand yields TyError (the propagate pass owns the
// F0020 diagnostic for a `?` in a non-Result/Option context).
func propagateUnwrap(t: in Type): Type {
  match unrefine(t) {
    case TyUser(_, name, args) -> {
      if name == "Result" and args.count >= 1 {
        args[0]
      } else if name == "Option" and args.count >= 1 {
        args[0]
      } else {
        TyError
      }
    }
    case _ -> TyError
  }
}

// `e?` (docs/01 §4.5) unwraps the operand to its success type (`Result[T,
// E]`/`Option[T]` -> `T`); the `Lyric.Propagate` pass owns the lowering and
// F0020.  `expected` is the type the `?` expression's own position expects,
// or `TyError`.
//
// The lowering matches on the operand and re-wraps its failure as the
// enclosing function's, so the operand must be of the function's monad, its
// error type must be assignable to the function's (T0169), and its success type is what
// the position takes.  An operand the backend would otherwise build at an
// instantiation it infers from context — a bare `Ok(...)`/`Err(...)`/
// `Some(...)`/`None`, possibly behind an `if`/`match`/block — or one whose
// own type leaves a slot open is recorded with its closed type, so
// `Lyric.Mono.desugarCheckedFile` binds it to a local annotated with that
// type before the lowering (#8181).  Without that, a backend with reified
// generics built `Ok(value = "bb")` in a `Result[Int, String]` function at
// `Result<int, string>` (the function's own instantiation) and the match read
// a `string` payload as an `int`.
//
// An operand that fixes no success type (`Err(error = x)?`, `None?`) where
// the position expects none is left open (`SymbolTable.openPropagateOperands`)
// until what consumes the value fixes it: a call argument's parameter
// (instantiated, for a generic one, from the type expected of the call's
// result), a record field, `Bool` for a condition, the other operand of a
// binary operator, or the type the branches of an `if`/`match` join to
// (`resolvePropagateOperand`).  Such an operand can never be `Ok`/`Some`, so
// the `?` never yields a value; one that nothing fixes is handled by
// `closeOpenPropagateOperands`.
func inferPropagate(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
  inner: in Expr,
  expected: in Type,
): Type {
  val own = inferExpr(sc, tbl, sigs, diag, inner)
  checkPropagateOperandIsMonad(diag, own, inner.span)
  checkPropagateMonad(sc, tbl, diag, own, e, inner.span)
  val closed = joinOpenTypes(own, propagateOperandContext(own, sc.returnTy, unrefine(expected)))
  val ownOpen = not typeIsClosedOver(own, sc.genericNames)
  val takesContext = propagateOperandTakesContext(tbl, sc, inner)
  val key = recordCopySiteKey(inner.span)
  if typeIsClosedOver(closed, sc.genericNames) and (ownOpen or takesContext) {
    if ownOpen {
      // A local of an open type (`val r = Ok(value = 1)`) takes the closed
      // type as its annotation (#7788).
      noteExpectedFlow(sc, tbl, inner, closed)
    }
    if hoistBindsOperand(sc, inner) {
      if tbl.openPropagateOperands.containsKey(key) {
        tbl.openPropagateOperands.remove(key)
      }
      recordHoistOperandTypeOver(tbl, sc.genericNames, inner, closed, TyError)
    }
  } else if takesContext and hoistBindsOperand(sc, inner) {
    if not tbl.hoistOperandTypeSites.containsKey(key) and not tbl.openPropagateOperands.containsKey(key) {
      val fallback = joinOpenTypes(closed, propagateOperandContext(own, sc.returnTy, propagateUnwrap(sc.returnTy)))
      tbl.openPropagateOperands.add(
        key,
        OpenPropagateOperand(operand = inner, fallback = fallback, typeParams = sc.genericNames)
      )
    }
  }
  propagateUnwrap(closed)
}

// T0195: the operand of `?` must be a `Result` or an `Option` (or a `T?`
// nullable, which lowers to `Option`).  Any other operand type the checker
// knows — a primitive, a function, a tuple, a record — has no `Ok`/`Err` or
// `Some`/`None` shape for the lowering to match on, so a backend would fail
// at run time on the cast (#8249).  An operand of unknown or generic type is
// not judged here.
func checkPropagateOperandIsMonad(diag: in List[Diagnostic], own: in Type, sp: in Span): Unit {
  val shown = unrefine(own)
  val bad = match shown {
    case TyUser(_, name, _) -> name != "Result" and name != "Option"
    case TyPrim(pt) -> match pt { case PtNever -> false; case _ -> true }
    case TyFunction(_, _, _) -> true
    case TyTuple(_) -> true
    case TySlice(_) -> true
    case TyArray(_, _, _) -> true
    case _ -> false
  }
  if bad {
    diag.add(
      errorDiagnostic(
        "T0195",
        "the operand of `?` has type " + renderType(shown) +
          ", which is neither a Result nor an Option; `?` unwraps the success value of a Result[T, E] or Option[T] " +
          "and returns the failure from the enclosing function",
        sp
      )
    )
  }
}

// T0169: the operand of `?` must be of the enclosing function's monad, with an
// error type assignable to the function's error type — the lowering re-wraps
// the operand's error in the function's `Err` (or returns `None`), docs/01
// §4.5.  An error type that widens to the function's (`Int` to `Long`) is
// recorded in `SymbolTable.propagateErrWidenings`, so the lowering converts
// it.  A function returning neither `Result` nor `Option` is the lowering's
// F0020.
func checkPropagateMonad(
  sc: in Scope,
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  own: in Type,
  e: in Expr,
  sp: in Span,
): Unit {
  val ret = unrefine(sc.returnTy)
  val retName = match ret { case TyUser(_, n, _) -> n; case _ -> return }
  if retName != "Result" and retName != "Option" {
    return
  }
  match unrefine(own) {
    case TyUser(oid, oname, oargs) -> {
      if oname != "Result" and oname != "Option" {
        return
      }
      match ret {
        case TyUser(rid, _, rargs) -> {
          if oname != retName {
            diag.add(
              errorDiagnostic(
                "T0169",
                "this `?` operand is " + articleFor(oname) + " " + oname + ", but the enclosing function returns " +
                  renderType(ret) +
                  "; `?` propagates the operand's failure as the function's result, so the operand " +
                  "must be " +
                  articleFor(retName) +
                  " " +
                  retName +
                  " too",
                sp
              )
            )
            return
          }
          if oname == "Result" and symbolIdEq(oid, rid) and oargs.count == 2 and rargs.count == 2 {
            val ownErr = oargs[1]
            if typeIsClosedOver(ownErr, sc.genericNames) {
              if not argSatisfiesParam(tbl, rargs[1], ownErr) {
                diag.add(
                  errorDiagnostic(
                    "T0169",
                    "the error type of this `?` operand, " + renderType(ownErr) + ", is not assignable to the " +
                      "enclosing function's error type " +
                      renderType(rargs[1]) +
                      " (the function returns " +
                      renderType(ret) +
                      "); `?` re-wraps the operand's error in the function's `Err`",
                    sp
                  )
                )
              } else if numericWidensTo(rargs[1], ownErr) {
                match wideningMethod(rargs[1], ownErr) {
                  case Some(m) -> match typeExprForRef(tbl, ownErr, e.span) {
                    case Some(fromTe) -> {
                      val wkey = recordCopySiteKey(e.span)
                      if not tbl.propagateErrWidenings.containsKey(wkey) {
                        tbl.propagateErrWidenings.add(wkey, PropagateErrWidening(method = m, fromType = fromTe))
                      }
                    }
                    case None -> ()
                  }
                  case None -> ()
                }
              }
            }
          }
        }
        case _ -> ()
      }
    }
    case _ -> ()
  }
}

func articleFor(name: in String): String {
  if name == "Option" {
    "an"
  } else {
    "a"
  }
}

// Give the open operand of the `?` expression `e` (through parentheses) the
// success type `succ`, when `succ` closes it (see `inferPropagate`).
pub func resolvePropagateOperand(sc: in Scope, tbl: in SymbolTable, e: in Expr, succ: in Type): Unit {
  match e.kind {
    case EParen(inner) -> resolvePropagateOperand(sc, tbl, inner, succ)
    case EPropagate(inner) -> {
      val key = recordCopySiteKey(inner.span)
      if not tbl.openPropagateOperands.containsKey(key) {
        return
      }
      recordPropagateOperandType(
        tbl,
        key,
        inner,
        propagateOperandContext(sc.returnTy, sc.returnTy, unrefine(succ)),
        sc.genericNames
      )
    }
    case _ -> ()
  }
}

// A `?` operand still open once the file is checked never yields a value
// (see `inferPropagate`), so no type is recorded for it: the JVM erases the
// success type and the dotnet backend builds a construction with no type
// expected of it at the enclosing function's instantiation, as for any such
// construction.  The native backend builds every construction at a closed
// instantiation (D-N-010: full monomorphization), so each such operand's
// fallback — the enclosing function's own instantiation, which types only the
// success path the `?` never takes — is offered in
// `SymbolTable.propagateFallbackSites`, which the middle end binds only for a
// native build (`MiddleEndOptions.nativeIntrinsics`).  An operand that is an
// argument of a generic call has none: there it would instantiate the callee.
pub func collectPropagateFallbacks(tbl: in SymbolTable): Unit {
  for k in mapKeys(tbl.openPropagateOperands) {
    match mapGet(tbl.openPropagateOperands, k) {
      case Some(op) -> {
        val t = op.fallback
        if typeIsClosedOver(t, op.typeParams) and typeMentionsGenericInst(t) and not tbl.hoistOperandTypeSites.containsKey(k) and not tbl.propagateFallbackSites.containsKey(k) {
          match typeExprForOpenBinding(tbl, t, op.operand.span, op.typeParams) {
            case Some(te) -> tbl.propagateFallbackSites.add(
              k,
              HoistOperandTypeSite(
                operandType = te,
                rendered = renderType(t),
                conflicting = false,
                startOffset = op.operand.span.startPos.offset,
                operandKind = exprKindTag(op.operand)
              )
            )
            case None -> ()
          }
        }
      }
      case None -> ()
    }
  }
}

// The open `?` argument `e` of a generic call gets no fallback (see
// `collectPropagateFallbacks`).
func dropPropagateFallback(tbl: in SymbolTable, e: in Expr): Unit {
  match e.kind {
    case EParen(inner) -> dropPropagateFallback(tbl, inner)
    case EPropagate(inner) -> {
      val key = recordCopySiteKey(inner.span)
      match mapGet(tbl.openPropagateOperands, key) {
        case Some(op) -> {
          tbl.openPropagateOperands.remove(key)
          tbl.openPropagateOperands.add(
            key,
            OpenPropagateOperand(operand = op.operand, fallback = TyError, typeParams = op.typeParams)
          )
        }
        case None -> ()
      }
    }
    case _ -> ()
  }
}

// Record the closed type `t` for the open `?` operand `operand` keyed `key`.
func recordPropagateOperandType(
  tbl: in SymbolTable,
  key: in String,
  operand: in Expr,
  t: in Type,
  typeParams: in List[String],
): Unit {
  if typeIsClosedOver(t, typeParams) and typeMentionsGenericInst(t) {
    match typeExprForOpenBinding(tbl, t, operand.span, typeParams) {
      case Some(_) -> {
        tbl.openPropagateOperands.remove(key)
        recordHoistOperandTypeOver(tbl, typeParams, operand, t, TyError)
      }
      case None -> ()
    }
  }
}

// The type a `?` operand of type `own` has in a function returning `ret`:
// the function's own monad, with the function's error type and `succ` (the
// type the `?` expression's position expects, or `TyError`) as the success
// type.  `TyError` when the operand is not of the function's monad (the
// lowering's F0020 and the match's own checks report that).
func propagateOperandContext(own: in Type, ret: in Type, succ: in Type): Type {
  match unrefine(own) {
    case TyUser(oid, oname, oargs) -> match unrefine(ret) {
      case TyUser(rid, _, rargs) -> {
        val isMonad = (oname == "Result" and oargs.count == 2) or (oname == "Option" and oargs.count == 1)
        if not isMonad or not symbolIdEq(oid, rid) or rargs.count != oargs.count {
          return TyError
        }
        val args: List[Type] = newList()
        args.add(succ)
        var i = 1
        while i < rargs.count {
          args.add(rargs[i])
          i = i + 1
        }
        TyUser(id = oid, name = oname, args = args)
      }
      case _ -> TyError
    }
    case _ -> TyError
  }
}

// Whether a `?` operand is built at an instantiation a backend infers from
// its context: a union-case construction (`Ok(...)`, `Std.Core.Some(...)`,
// a bare `None`), or an `if`/`match`/block a branch of which produces one.
func propagateOperandTakesContext(tbl: in SymbolTable, sc: in Scope, e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> propagateOperandTakesContext(tbl, sc, inner)
    case EIf(_, thenBranch, elseBranch, _) -> {
      if branchTakesContext(tbl, sc, thenBranch) {
        return true
      }
      match elseBranch {
        case Some(eb) -> branchTakesContext(tbl, sc, eb)
        case None -> false
      }
    }
    case EMatch(_, arms) -> {
      for arm in arms {
        if branchTakesContext(tbl, sc, arm.body) {
          return true
        }
      }
      false
    }
    case EBlock(blk) -> match blockValueExpr(blk) {
      case Some(v) -> propagateOperandTakesContext(tbl, sc, v)
      case None -> false
    }
    case ECall(fn, _) -> match unionCaseSymbolOf(tbl, fn) { case Some(_) -> true; case None -> false }
    case EPath(p) -> if p.segments.count == 1 and isSomeBinding(scopeTryFind(sc, p.segments[0])) {
      false
    } else {
      match unionCaseSymbolOf(tbl, e) {
        case Some(_) -> true
        case None -> false
      }
    }
    case _ -> false
  }
}

func branchTakesContext(tbl: in SymbolTable, sc: in Scope, b: in ExprOrBlock): Bool {
  match branchValueExpr(b) {
    case Some(v) -> propagateOperandTakesContext(tbl, sc, v)
    case None -> false
  }
}

func isSomeBinding(b: in Option[LocalBinding]): Bool {
  match b {
    case Some(_) -> true
    case None -> false
  }
}

// The type the generic parameter taking argument `ai` of a call to `sig` has
// once `sig`'s type parameters are bound from `resultExpected`, the type
// expected of the call's result; `fallback` when that binds nothing.
func genericArgFromResultExpected(
  sig: in ResolvedSignature,
  args: in List[CallArg],
  ai: in Int,
  fallback: in Type,
  resultExpected: in Type,
): Type {
  if sig.generics.count == 0 or typeIsHole(resultExpected) {
    return fallback
  }
  val paramNames: List[String] = newList()
  for p in sig.params {
    paramNames.add(p.name)
  }
  if args.count > sig.params.count {
    return fallback
  }
  val srcIdx = argIndicesInParamOrder(args, paramNames)
  val retTys: List[Type] = newList()
  retTys.add(sig.returnTy)
  val expTys: List[Type] = newList()
  expTys.add(resultExpected)
  val targs = inferGenericArgsDeep(sig.generics, retTys, expTys)
  var k = 0
  while k < srcIdx.count {
    if srcIdx[k] == ai {
      return substituteTyVars(sig.params[k].ty, sig.generics, targs)
    }
    k = k + 1
  }
  fallback
}

func callHasPropagateArg(tbl: in SymbolTable, args: in List[CallArg]): Bool {
  for a in args {
    val ae = callArgExpr(a)
    if argIsPropagate(ae) or argIsPropagateCall(tbl, ae) {
      return true
    }
  }
  false
}

// Give each open `?` argument of the call `e` — directly, or in a nested such
// call — the success type its parameter has once the callee's type
// parameters are bound from `resultExpected`, the type expected of `e`'s
// result (#8181).  A walk over the already-checked call, not a second check
// of it, so a nest of calls costs time linear in its depth.
func resolvePropagateCallArgs(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  e: in Expr,
  resultExpected: in Type,
): Unit {
  if tbl.openPropagateOperands.count == 0 or not typeIsClosedOver(resultExpected, sc.genericNames) {
    return
  }
  match e.kind {
    case EParen(inner) -> resolvePropagateCallArgs(sc, tbl, sigs, inner, resultExpected)
    case ECall(fn, cargs) -> {
      val holes: List[Type] = newList()
      for a in cargs {
        holes.add(TyError)
      }
      match findDirectSig(sc, tbl, sigs, fn, cargs, holes) {
        case Some(sig) -> {
          // The callee's type arguments, bound from the expected result, are
          // recorded for `Lyric.Mono` when the arguments left them open.
          match fn.kind {
            case EPath(_) -> if sig.generics.count > 0 {
              val boundArgTys: List[Type] = newList()
              var bi = 0
              while bi < cargs.count {
                boundArgTys.add(genericArgFromResultExpected(sig, cargs, bi, TyError, resultExpected))
                bi = bi + 1
              }
              recordGenericCallTypeArgs(
                tbl,
                sc.genericNames,
                sig,
                valueGenericParamsOf(tbl, fn, cargs.count),
                cargs,
                boundArgTys,
                fn.span
              )
            }
            case _ -> ()
          }
          var ai = 0
          while ai < cargs.count {
            val ae = callArgExpr(cargs[ai])
            if argIsPropagate(ae) or argIsPropagateCall(tbl, ae) {
              val pTy = genericArgFromResultExpected(sig, cargs, ai, TyError, resultExpected)
              if argIsPropagate(ae) {
                resolvePropagateOperand(sc, tbl, ae, pTy)
              } else {
                resolvePropagateCallArgs(sc, tbl, sigs, ae, pTy)
              }
            }
            ai = ai + 1
          }
        }
        case None -> ()
      }
    }
    case _ -> ()
  }
}

// Whether a call argument is a call (not a union-case construction) holding a
// `?` argument, directly or in a nested such call.
func argIsPropagateCall(tbl: in SymbolTable, e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsPropagateCall(tbl, inner)
    case ECall(fn, cargs) -> {
      if argIsCaseCtorCall(tbl, e) {
        return false
      }
      for a in cargs {
        val ae = callArgExpr(a)
        if argIsPropagate(ae) or argIsPropagateCall(tbl, ae) {
          return true
        }
      }
      false
    }
    case _ -> false
  }
}

// Whether a call argument is a `?` expression, through parentheses.
func argIsPropagate(e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsPropagate(inner)
    case EPropagate(_) -> true
    case _ -> false
  }
}

// #1487 (§5.2): the expression behind a call argument.
func callArgExpr(arg: in CallArg): Expr {
  match arg {
    case CAPositional(ae) -> ae
    case CANamed(_, ae, _) -> ae
  }
}

// #1487 (§5.2), D183: an argument bound to an `out`/`inout` parameter is the
// place the callee writes, so it must be a writable one: a `var` local, an
// `out`/`inout` parameter, a `var` field (of any receiver, as `p.f = v`
// requires; inside a protected member a bare field is a local of the field's
// own mutability), or an element of an array that is a writable place —
// the place classes `placeClass` gives assignment (T0157).  A literal, a call
// result, an operator expression, a `val`/`let`/`in` binding and a non-`var`
// field are not.  A place the checker cannot resolve (a module-qualified
// path, which `byRefArgModuleProblem` reports, or a field of a type whose
// declaration it cannot see) is accepted.
func argIsValidByRefTarget(sc: in Scope, tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsValidByRefTarget(sc, tbl, sigs, inner)
    case EPath(_) -> placeClass(sc, tbl, sigs, e) != 0
    case EMember(_, _) -> placeClass(sc, tbl, sigs, e) != 0
    case EIndex(_, _) -> true
    // `self` is a place only in a function whose receiver is `self: inout`.
    case ESelf -> match scopeTryFind(sc, "self") { case Some(b) -> b.isMutable; case None -> false }
    case _ -> false
  }
}

// T0085's message for an argument `argIsValidByRefTarget` rejects: why it is
// not a place the callee may write (D183) and what to pass instead.
func byRefTargetProblem(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  paramName: in String,
  e: in Expr,
): String {
  val head = "argument for `out`/`inout` parameter '" + paramName +
    "' must be a writable place: the parameter refers to the caller's place, which the callee may assign (D183); "
  match e.kind {
    case EParen(inner) -> byRefTargetProblem(sc, tbl, sigs, paramName, inner)
    case EPath(p) -> if p.segments.count == 1 {
      match scopeTryFind(sc, p.segments[0]) {
        case Some(b) -> if b.capturedByRefParam {
          head + "inside a lambda, the enclosing function's `out`/`inout` parameter '" + p.segments[0] +
            "' is the value the lambda captured, not the caller's place; assign it outside the lambda"
        } else {
          head + "'" + p.segments[0] +
            "' is an immutable binding (`val`, `let` or an `in` parameter); declare it `var`, or, if the callee only changes the fields of the value it is given, make that parameter `in`"
        }
        case None -> head + "pass a `var`, an `out`/`inout` parameter or a `var` field"
      }
    } else {
      head + "pass a `var`, an `out`/`inout` parameter or a `var` field"
    }
    case EMember(_, name) -> head + "the field '" + name +
      "' is not `var`; declare it `var` on its type, or pass a `var` holding its value and store it back"
    case _ -> head + "pass a `var`, an `out`/`inout` parameter or a `var` field, not a value"
  }
}

func modeNeedsLValue(m: in ParamMode): Bool {
  match m {
    case PMOut -> true
    case PMInout -> true
    case PMIn -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5a. Record / opaque construction (#1483 record-ctor, #1485 opaque hiding).
// ─────────────────────────────────────────────────────────────────────────────
record CtorField {
  name: String
  ty: Type
  hasDefault: Bool
  /// An array field with no default: the construction fills an omitted one
  /// with its zero value (D167), built from the type at the construction.
  zeroFill: Bool
}

// A field of type `t` declared without a default is zero filled when it is
// an array of fixed length.  For a generic record the element type may name
// a type parameter, so whether it has a zero is settled per construction.
func isZeroFillField(t: in Type, dflt: in Option[Expr]): Bool {
  match dflt {
    case Some(_) -> false
    // A length that is the type's own value generic parameter is settled,
    // like a type parameter, once the arguments are known (D169).
    case None -> match unrefine(t) {
      case TyArray(Some(_), _, _) -> true
      case TyArray(None, _, sv) -> sv.length > 0
      case _ -> false
    }
  }
}

func ctorIsGeneric(sym: in Symbol): Bool {
  match sym.kind {
    case DKRecord(_, rd) -> match rd.generics { case Some(_) -> true; case None -> false }
    case DKExposedRec(_, rd) -> match rd.generics { case Some(_) -> true; case None -> false }
    case DKOpaque(_, od) -> match od.generics { case Some(_) -> true; case None -> false }
    case DKProtected(_, pd) -> match pd.generics { case Some(_) -> true; case None -> false }
    case _ -> false
  }
}

// The distinct lengths the fields of a construction give the value generic
// parameter `name` (D169).
func valueParamLengths(name: in String, fieldTypes: in List[Type], argTypes: in List[Type]): List[Int] {
  val lens: List[Int] = newList()
  var i = 0
  while i < fieldTypes.count and i < argTypes.count {
    match findGenericInPair(name, fieldTypes[i], argTypes[i]) {
      case Some(t) -> match t { case TyLen(n) -> if not lens.contains(n) { lens.add(n) }; case _ -> () }
      case None -> ()
    }
    i = i + 1
  }
  lens
}

// Records the value arguments of a value-generic record's construction
// (D169): a literal length, or the enclosing value generic parameter it is
// bound to inside a value-generic body.
func noteValueRecordCtor(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sym: in Symbol,
  targs: in List[Type],
  span: in Span,
): Unit {
  val gOpt = match sym.kind {
    case DKRecord(_, rd) -> rd.generics
    case DKExposedRec(_, rd) -> rd.generics
    case DKOpaque(_, od) -> od.generics
    case DKProtected(_, pd) -> pd.generics
    case _ -> None
  }
  val params = match gOpt { case Some(g) -> g.params; case None -> return }
  if not genericParamsHaveValue(params) {
    return
  }
  val vargs = match valueArgsOfInstance(params, targs, span) { case Some(v) -> v; case None -> return }
  val key = recordCopySiteKey(span)
  if not tbl.valueRecordCtorSites.containsKey(key) {
    tbl.valueRecordCtorSites.add(key, vargs)
  }
}

// The value arguments of an instance at its value generic parameters, in
// order: a literal length, or the enclosing value generic parameter it is
// bound to inside a value-generic body.  `None` when one is not known.
func valueArgsOfInstance(params: in List[GenericParam], targs: in List[Type], span: in Span): Option[List[TypeArg]] {
  val vargs: List[TypeArg] = newList()
  var i = 0
  while i < params.count and i < targs.count {
    if genericParamIsValue(params[i]) {
      match targs[i] {
        case TyLen(n) -> vargs.add(
          TAValue(expr = mkExpr(ELiteral(lit = LInt(value = n.toLong(), suffix = I32, raw = "")), span))
        )
        case TyVar(m) -> {
          val segs: List[String] = newList()
          segs.add(m)
          vargs.add(TAType(ty = TypeExpr(kind = TRef(path = refTypePath(segs, span)), span = span)))
        }
        case _ -> return None
      }
    }
    i = i + 1
  }
  if i < params.count {
    return None
  }
  Some(value = vargs)
}

// Records a construction of a case of a union with value generic parameters
// at the instance `ty` it is typed as (#8149).  `replace` lets the typing
// against an expected type win over the construction's own inference.
// Whether `ty` is such an instance with every length known.
func noteValueUnionCtor(tbl: in SymbolTable, ty: in Type, span: in Span, replace: in Bool): Bool {
  match unrefine(ty) {
    case TyUser(id, _, targs) -> match parentUnionDeclOf(tbl, id) {
      case Some(decl) -> {
        val params = match decl.generics { case Some(g) -> g.params; case None -> return false }
        if not genericParamsHaveValue(params) {
          return false
        }
        match valueArgsOfInstance(params, targs, span) {
          case Some(vargs) -> {
            val key = recordCopySiteKey(span)
            if replace or not tbl.valueUnionCtorSites.containsKey(key) {
              tbl.valueUnionCtorSites.remove(key)
              tbl.valueUnionCtorSites.add(key, ValueUnionCtorSite(unionName = decl.name, lengths = vargs))
            }
            true
          }
          case None -> false
        }
      }
      case None -> false
    }
    case _ -> false
  }
}

// A union case construction, or a reference to a case with no fields,
// typed where `expected` is expected: recorded at its type, or at `expected`
// when its own type leaves a length open (`val s: Shape[3] = Empty`).
func noteValueUnionCaseExpected(sc: in Scope, tbl: in SymbolTable, e: in Expr, actual: in Type, expected: in Type): Unit {
  val fn = match e.kind {
    case ECall(f, _) -> f
    case EPath(p) -> if p.segments.count == 1 and scopeHasName(sc, p.segments[0]) { return } else { e }
    case EMember(_, _) -> e
    case _ -> return
  }
  match unionCaseSymbolOf(tbl, fn) {
    case Some(caseSym) -> if not noteValueUnionCtor(tbl, actual, e.span, true) {
      match caseSym.kind {
        case DKUnionCase(parentId, _) -> match unrefine(expected) {
          case TyUser(eid, _, _) -> if symbolIdEq(parentId, eid) {
            val _ = noteValueUnionCtor(tbl, expected, e.span, true)
          }
          case _ -> ()
        }
        case _ -> ()
      }
    }
    case None -> ()
  }
}

// The value generic parameter names of a constructor symbol (D169).
func ctorValueGenericNames(sym: in Symbol): List[String] {
  val gOpt = match sym.kind {
    case DKRecord(_, rd) -> rd.generics
    case DKExposedRec(_, rd) -> rd.generics
    case DKOpaque(_, od) -> od.generics
    case DKProtected(_, pd) -> pd.generics
    case _ -> None
  }
  valueGenericNames(gOpt)
}

func ctorIsForeign(sym: in Symbol): Bool {
  match sym.kind {
    case DKRecord(_, rd) -> rd.isForeign
    case _ -> false
  }
}

// A construction's argument meets its field's type.  A `foreign record` field is
// a C struct member, so it takes what an `extern func` parameter of that type
// takes: a Lyric closure for a callback-typed field, and for a `void*` field
// (`NativePtr[Byte]` or `NativeUserdata`) a closure as its own pointer (D193).
func argSatisfiesCtorField(tbl: in SymbolTable, sym: in Symbol, fieldTy: in Type, argTy: in Type, argE: in Expr): Bool {
  if ctorIsForeign(sym) {
    return argSatisfiesExternParam(tbl, fieldTy, argTy)
  }
  argFlowSatisfies(tbl, fieldTy, argTy, argE)
}

func ctorIsOpaque(sym: in Symbol): Bool {
  match sym.kind {
    case DKOpaque(_, _) -> true
    case _ -> false
  }
}

// Extract the ordered generic parameter names from a record/exposed-record/opaque
// constructor symbol.  Returns an empty list for non-generic types.
func ctorGenericNames(sym: in Symbol): List[String] {
  val names: List[String] = newList()
  val gOpt = match sym.kind {
    case DKRecord(_, rd) -> rd.generics
    case DKExposedRec(_, rd) -> rd.generics
    case DKOpaque(_, od) -> od.generics
    case DKProtected(_, pd) -> pd.generics
    case _ -> None
  }
  match gOpt {
    case None -> {
    }
    case Some(g) -> {
      var j = 0
      while j < g.params.count {
        match g.params[j] {
          case GPType(nm, _) -> names.add(nm)
          case GPValue(nm, _, _) -> names.add(nm)
        }
        j = j + 1
      }
    }
  }
  names
}

// All field declarations of a constructor symbol (record / exposed record /
// opaque) in declaration order; empty for any other symbol kind.  Centralises
// the DKRecord/DKExposedRec/DKOpaque member iteration so the helpers below
// stay in sync when a constructor-like symbol kind is added (#3159).
// A protected type's data field as the `FieldDecl` a record field would be,
// so construction of a protected type is checked like a record's (#7830):
// field names, field types, defaults, and generic inference.
func protectedFieldAsFieldDecl(pf: in ProtectedField): FieldDecl {
  match pf {
    case PFImmutable(f) -> f
    case PFVar(name, ty, init, docs, anns, sp) -> FieldDecl(
      docComments = docs,
      annotations = anns,
      visibility = None,
      isMutable = true,
      name = name,
      ty = ty,
      dflt = init,
      span = sp,
      trailingAnnotationCount = 0
    )
    case PFLet(name, ty, init, docs, anns, sp) -> FieldDecl(
      docComments = docs,
      annotations = anns,
      visibility = None,
      isMutable = false,
      name = name,
      ty = ty,
      dflt = init,
      span = sp,
      trailingAnnotationCount = 0
    )
  }
}

func ctorAllFields(sym: in Symbol): List[FieldDecl] {
  val result: List[FieldDecl] = newList()
  match sym.kind {
    case DKRecord(_, rd) -> {
      var i = 0
      while i < rd.members.count {
        match rd.members[i] {
          case RMField(fd) -> result.add(fd)
          case _ -> {
          }
        }
        i = i + 1
      }
    }
    case DKExposedRec(_, rd) -> {
      var i = 0
      while i < rd.members.count {
        match rd.members[i] {
          case RMField(fd) -> result.add(fd)
          case _ -> {
          }
        }
        i = i + 1
      }
    }
    case DKOpaque(_, od) -> {
      var i = 0
      while i < od.members.count {
        match od.members[i] {
          case OMField(fd) -> result.add(fd)
          case _ -> {
          }
        }
        i = i + 1
      }
    }
    case DKProtected(_, pd) -> {
      for m in pd.members {
        match m {
          case PMField(pf) -> result.add(protectedFieldAsFieldDecl(pf))
          case _ -> ()
        }
      }
    }
    case _ -> {
    }
  }
  result
}

// Collect the raw field types from a constructor symbol with `genericNames`
// registered in the generic context, so that type-parameter fields resolve to
// `TyVar(name)` rather than `TyError`.  Used by generic-constructor type-arg
// inference in `inferConstruction`.
func ctorFieldTypes(tbl: in SymbolTable, sym: in Symbol, genericNames: in List[String]): List[Type] {
  val ctx = newGenericContext()
  gctxPush(ctx, genericNames)
  // Resolution diagnostics are discarded here; `surfaceCtorFieldTypeErrors`
  // reports genuine field-type errors when inference fails.
  val scratch: List[Diagnostic] = newList()
  val result: List[Type] = newList()
  val fields = ctorAllFields(sym)
  // Resolve under the declaring package's scope, like `collectCtorFields`
  // (#6689): these types are also the authoritative per-argument check for
  // generic constructors, so a field type naming a type of the declaring
  // package must not bind to a same-named type of the constructing one.
  val saved = enterDeclaringScope(tbl, sym)
  var i = 0
  while i < fields.count {
    result.add(resolveType(tbl, ctx, scratch, fields[i].ty))
    i = i + 1
  }
  restoreScope(tbl, saved)
  result
}

// Returns true when `TyVar(name)` appears anywhere in `ty` (directly or nested).
// Used to determine which constructor fields constrain a given type parameter.
func fieldTypeUsesVar(name: in String, ty: in Type): Bool {
  match ty {
    case TyVar(nm) -> nm == name
    case TyUser(_, _, targs) -> {
      var i = 0
      while i < targs.count {
        if fieldTypeUsesVar(name, targs[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case TySlice(e) -> fieldTypeUsesVar(name, e)
    case TyArray(_, e, sv) -> sv == name or fieldTypeUsesVar(name, e)
    case TyNullable(inner) -> fieldTypeUsesVar(name, inner)
    case TyTuple(elems) -> {
      var i = 0
      while i < elems.count {
        if fieldTypeUsesVar(name, elems[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case TyFunction(ps, r, _) -> {
      var i = 0
      while i < ps.count {
        if fieldTypeUsesVar(name, ps[i]) {
          return true
        }
        i = i + 1
      }
      fieldTypeUsesVar(name, r)
    }
    case _ -> false
  }
}

// Returns true when at least one constructor field that constrains `name` has a
// corresponding arg of type TyError (the lenient wildcard produced by
// `eraseTyVars` in `bindPatternTyped` for pattern-bound variables).  When true,
// the inference failure for `name` is due to type-variable erasure, not a real
// mismatch — T0110 should be suppressed for this parameter.
func anyFieldArgIsLenientForParam(name: in String, fieldTypes: in List[Type], orderedArgTypes: in List[Type]): Bool {
  var i = 0
  while i < fieldTypes.count and i < orderedArgTypes.count {
    if fieldTypeUsesVar(name, fieldTypes[i]) {
      match orderedArgTypes[i] {
        case TyError -> return true
        case _ -> {
        }
      }
    }
    i = i + 1
  }
  false
}

// Re-resolve constructor field types into `diag` so genuine field-type errors
// (e.g. references to unknown types) surface even when T0110 fires early.
// Pushes the constructor's own generic parameter names so generic-position
// fields correctly resolve to TyVar (silent) rather than producing spurious
// T0010 "unknown type name" diagnostics.  Called only on the T0110
// early-return path (#3155).
func surfaceCtorFieldTypeErrors(tbl: in SymbolTable, sym: in Symbol, diag: in List[Diagnostic]): Unit {
  val ctx = newGenericContext()
  val gnames = ctorGenericNames(sym)
  if gnames.count > 0 {
    gctxPush(ctx, gnames)
  }
  val fields = ctorAllFields(sym)
  // Report in the declaring package's scope, as the field types are resolved
  // everywhere else (#6689).
  val saved = enterDeclaringScope(tbl, sym)
  var i = 0
  while i < fields.count {
    val _ = resolveType(tbl, ctx, diag, fields[i].ty)
    i = i + 1
  }
  restoreScope(tbl, saved)
}

// The type of field `name` of a generic constructor: its declared type with
// the constructor's type parameters (`gnames`) in scope, instantiated at
// `targs`.  `fallback` is used when `name` is not a declared field.
func instantiatedFieldType(
  fieldNames: in List[String],
  fieldTypes: in List[Type],
  gnames: in List[String],
  targs: in List[Type],
  name: in String,
  fallback: in Type,
): Type {
  var i = 0
  while i < fieldNames.count and i < fieldTypes.count {
    if fieldNames[i] == name {
      return substituteTyVars(fieldTypes[i], gnames, targs)
    }
    i = i + 1
  }
  fallback
}

// Return the field names of a constructor symbol in declaration order.
// Used alongside ctorFieldTypes to reorder named-arg types to declaration
// order before passing to inferGenericArgs (#3157).
func ctorFieldNames(sym: in Symbol): List[String] {
  val result: List[String] = newList()
  val fields = ctorAllFields(sym)
  var i = 0
  while i < fields.count {
    result.add(fields[i].name)
    i = i + 1
  }
  result
}

// Reorder argTypes to match declaration order so inferGenericArgs can pair
// each field type with the type of the argument that initialises it (#3157).
// Named args are placed at their declared-field index; positional args fill
// unoccupied slots left to right; any unmatched slot gets TyError so
// inferOneGenericArg simply skips it.
func argTypesInFieldOrder(args: in List[CallArg], argTypes: in List[Type], fieldNames: in List[String]): List[Type] {
  val result: List[Type] = newList()
  val occupied: List[Bool] = newList()
  var fi = 0
  while fi < fieldNames.count {
    result.add(TyError)
    occupied.add(false)
    fi = fi + 1
  }
  // Place named args at their declared slot first.
  var i = 0
  while i < args.count {
    val ty = if i < argTypes.count { argTypes[i] } else { TyError }
    match args[i] {
      case CANamed(nm, _, _) -> {
        var j = 0
        while j < fieldNames.count {
          if fieldNames[j] == nm {
            result[j] = ty
            occupied[j] = true
            j = fieldNames.count
          } else {
            j = j + 1
          }
        }
      }
      case CAPositional(_) -> {
      }
    }
    i = i + 1
  }
  // Place positional args into the first unoccupied slots, left to right.
  var posIdx = 0
  var i2 = 0
  while i2 < args.count {
    val ty = if i2 < argTypes.count { argTypes[i2] } else { TyError }
    match args[i2] {
      case CAPositional(_) -> {
        // Advance posIdx past any slots already filled by named args.
        var placed = false
        while posIdx < fieldNames.count and not placed {
          if not occupied[posIdx] {
            result[posIdx] = ty
            occupied[posIdx] = true
            posIdx = posIdx + 1
            placed = true
          } else {
            posIdx = posIdx + 1
          }
        }
      }
      case CANamed(_, _, _) -> {
      }
    }
    i2 = i2 + 1
  }
  result
}

// For each declared parameter position, the index of the call-site argument
// that fills it, or -1 when the slot is unfilled (an omitted trailing
// defaulted parameter).  Mirrors `argTypesInFieldOrder` (#3157) and codegen's
// `reorderFuncNamedArgs`: named args land at their declared slot, positional
// args fill the remaining slots left to right.  A named arg whose name matches
// no parameter occupies no slot (`reportUnpairedCallArgs` reports it), so no
// misaligned type check fires against it (#3066); a repeated one is reported
// by `reportRepeatedCallArgs` (#7846).
func argIndicesInParamOrder(args: in List[CallArg], paramNames: in List[String]): List[Int] {
  val result: List[Int] = newList()
  var fi = 0
  while fi < paramNames.count {
    result.add(-1)
    fi = fi + 1
  }
  // Place named args at their declared slot first.
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(nm, _, _) -> {
        var j = 0
        while j < paramNames.count {
          if paramNames[j] == nm {
            result[j] = i
            j = paramNames.count
          } else {
            j = j + 1
          }
        }
      }
      case CAPositional(_) -> {
      }
    }
    i = i + 1
  }
  // Second walk over the same args: place positional args into the first
  // unoccupied slots, left to right.
  var posIdx = 0
  var argIdx = 0
  while argIdx < args.count {
    match args[argIdx] {
      case CAPositional(_) -> {
        var placed = false
        while posIdx < paramNames.count and not placed {
          if result[posIdx] < 0 {
            result[posIdx] = argIdx
            placed = true
          }
          posIdx = posIdx + 1
        }
      }
      case CANamed(_, _, _) -> {
      }
    }
    argIdx = argIdx + 1
  }
  result
}

// Report, with `code`, each call argument that supplies a parameter (or
// field, per `what`) an earlier argument already supplied (#7846): a name
// given twice (`f(a = 1, a = 2)`), or a name given for a parameter a leading
// positional argument already took (`f(1, a = 2)` for `f(a: Int, b: Int = 0)`;
// positional arguments before the first named one bind in order).  Every
// pairing pass (`argIndicesInParamOrder`, `argTypesInFieldOrder`,
// `Lyric.Parser.argsWithDefaults`) assumes no such argument exists.
// `slotNames` are the callee's parameters or fields in declaration order
// ("" for a positional-only union-case field); with none (an unresolved
// callee) only a repeated name is detectable.  Each repeated name is reported
// once.  True when any was reported.
func reportRepeatedCallArgs(
  diag: in List[Diagnostic],
  code: in String,
  what: in String,
  args: in List[CallArg],
  slotNames: in List[String],
): Bool {
  var leading = 0
  var inPrefix = true
  while inPrefix and leading < args.count {
    match args[leading] {
      case CAPositional(_) -> {
        leading = leading + 1
      }
      case CANamed(_, _, _) -> {
        inPrefix = false
      }
    }
  }
  val seen: List[String] = newList()
  // A name repeated more than twice is one mistake, reported once.
  val repeated: List[String] = newList()
  var reported = false
  for a in args {
    match a {
      case CANamed(nm, _, asp) -> {
        var slot = -1
        var j = 0
        while j < slotNames.count and slot < 0 {
          if slotNames[j] == nm {
            slot = j
          }
          j = j + 1
        }
        if stringListContains(seen, nm) {
          if not stringListContains(repeated, nm) {
            diag.add(errorDiagnostic(code, what + " '" + nm + "' is given more than once", asp))
            repeated.add(nm)
          }
          reported = true
        } else if slot >= 0 and slot < leading {
          diag.add(
            errorDiagnostic(
              code,
              what + " '" + nm + "' is given more than once (positional argument " + toString(slot + 1) +
                " already supplies it)",
              asp
            )
          )
          repeated.add(nm)
          reported = true
        }
        seen.add(nm)
      }
      case CAPositional(_) -> ()
    }
  }
  reported
}

// The first field at or after `from` that no named argument supplies: a
// positional argument fills the declaration-order slots the named ones leave
// free (the order `argTypesInFieldOrder` places them in), #8005.
func nextUnnamedField(fields: in List[CtorField], args: in List[CallArg], from: in Int): Int {
  var idx = from
  while idx < fields.count and callArgsNameParam(args, fields[idx].name) {
    idx = idx + 1
  }
  idx
}

func callArgsNameParam(args: in List[CallArg], name: in String): Bool {
  for a in args {
    match a {
      case CANamed(nm, _, _) -> if nm == name { return true }
      case CAPositional(_) -> ()
    }
  }
  false
}

func fieldHasName(fields: in List[CtorField], name: in String): Bool {
  var i = 0
  while i < fields.count {
    if fields[i].name == name {
      return true
    }
    i = i + 1
  }
  false
}

func fieldTypeByName(fields: in List[CtorField], name: in String): Type {
  var i = 0
  while i < fields.count {
    if fields[i].name == name {
      return fields[i].ty
    }
    i = i + 1
  }
  TyError
}

// Append the constructor fields of a record/opaque member list to `out`
// (mirrors `extractRecordFields`).  A field with a default is optional.
func collectCtorFieldsFromRecord(
  tbl: in SymbolTable,
  ctx: in GenericContext,
  scratch: in List[Diagnostic],
  members: in List[RecordMember],
  acc: in List[CtorField],
  isGeneric: in Bool,
): Unit {
  var i = 0
  while i < members.count {
    match members[i] {
      case RMField(fd) -> {
        val t = resolveType(tbl, ctx, scratch, fd.ty)
        var hasDef = false
        match fd.dflt {
          case Some(_) -> {
            hasDef = true
          }
          case None -> {
            // An array field with no default is zero filled (D167); a generic
            // record's is settled once its type arguments are known.
            hasDef = fieldHasZeroDefault(tbl, t, fd.span) or (isGeneric and isZeroFillField(t, fd.dflt))
          }
        }
        acc.add(CtorField(name = fd.name, ty = t, hasDefault = hasDef, zeroFill = isZeroFillField(t, fd.dflt)))
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

func collectCtorFieldsFromOpaque(
  tbl: in SymbolTable,
  ctx: in GenericContext,
  scratch: in List[Diagnostic],
  members: in List[OpaqueMember],
  acc: in List[CtorField],
  isGeneric: in Bool,
): Unit {
  var i = 0
  while i < members.count {
    match members[i] {
      case OMField(fd) -> {
        val t = resolveType(tbl, ctx, scratch, fd.ty)
        var hasDef = false
        match fd.dflt {
          case Some(_) -> {
            hasDef = true
          }
          case None -> {
            hasDef = fieldHasZeroDefault(tbl, t, fd.span) or (isGeneric and isZeroFillField(t, fd.dflt))
          }
        }
        acc.add(CtorField(name = fd.name, ty = t, hasDefault = hasDef, zeroFill = isZeroFillField(t, fd.dflt)))
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// #6689: field types are resolved lazily, on every use (constructor call,
// field read, …), rather than once at the record/opaque's own declaration —
// so they must resolve under the DECLARING package's scope, not whatever
// scope happens to be active at the (possibly cross-package) call site that
// triggered this lookup.  Without this, `Pkg.Item` in `record R { xs:
// List[Item] }` resolved `Item` against the CALLER's imports: a caller that
// transitively imports an unrelated same-named `Item` from a different
// package silently constructed `R` with the wrong `Item` type baked into its
// field, compiling cleanly and failing at runtime (`MissingMethodException`
// / similar member-lookup failure) rather than at the constructor call that
// actually named the right `Item`.  Save/restore the caller's scope around
// the temporary switch so this is transparent to the caller.
func collectCtorFields(tbl: in SymbolTable, sym: in Symbol, acc: in List[CtorField]): Bool {
  val ctx = newGenericContext()
  // A field whose array length is a value generic parameter is zero filled
  // like one with a literal length (D169), which needs the parameter in
  // scope to see.
  val vnames = ctorValueGenericNames(sym)
  if vnames.count > 0 {
    gctxPush(ctx, vnames)
  }
  val scratch: List[Diagnostic] = newList()
  val saved = enterDeclaringScope(tbl, sym)
  val result = match sym.kind {
    case DKRecord(_, rd) -> {
      collectCtorFieldsFromRecord(tbl, ctx, scratch, rd.members, acc, ctorIsGeneric(sym))
      true
    }
    case DKExposedRec(_, rd) -> {
      collectCtorFieldsFromRecord(tbl, ctx, scratch, rd.members, acc, ctorIsGeneric(sym))
      true
    }
    case DKOpaque(_, od) -> {
      collectCtorFieldsFromOpaque(tbl, ctx, scratch, od.members, acc, ctorIsGeneric(sym))
      true
    }
    case DKProtected(_, _) -> {
      for fd in ctorAllFields(sym) {
        val t = resolveType(tbl, ctx, scratch, fd.ty)
        val hasDef = match fd.dflt {
          case Some(_) -> true
          case None -> fieldHasZeroDefault(tbl, t, fd.span) or
            (ctorIsGeneric(sym) and isZeroFillField(t, fd.dflt))
        }
        acc.add(CtorField(name = fd.name, ty = t, hasDefault = hasDef, zeroFill = isZeroFillField(t, fd.dflt)))
      }
      true
    }
    case _ -> false
  }
  restoreScope(tbl, saved)
  result
}

/// The caller's resolution scope, saved by `enterDeclaringScope`: its
/// package, that package's imports and the file entered (docs/70 §4.1).
record SavedScope {
  pkg: String
  imports: List[String]
  file: Int
}

// Switches `tbl` to the scope of the package that declares `sym` (#6689),
// and to the file of that package `sym` is declared in, returning the
// caller's scope for `restoreScope`.
func enterDeclaringScope(tbl: in SymbolTable, sym: in Symbol): SavedScope {
  val savedImports: List[String] = newList()
  var sii = 0
  while sii < tbl.scopeImports.count {
    savedImports.add(tbl.scopeImports[sii])
    sii = sii + 1
  }
  val savedPkg = if tbl.scopePkg.count > 0 { tbl.scopePkg[0] } else { "" }
  val savedFile = symTableCurrentFile(tbl)
  symTableSetScope(tbl, sym.originPackage, symTablePackageImportsOf(tbl, sym.originPackage))
  symTableEnterSpanFile(tbl, sym.declSpan)
  SavedScope(pkg = savedPkg, imports = savedImports, file = savedFile)
}

// `enterDeclaringScope` for a symbol declared in another package; for one
// of the current package (or with no package context) the package scope is
// kept and the file `sym` is declared in is entered.
func enterDeclaringScopeIfForeign(tbl: in SymbolTable, sym: in Symbol): SavedScope {
  val cur = symTableScopePkg(tbl)
  if sym.originPackage.length > 0 and sym.originPackage != cur {
    return enterDeclaringScope(tbl, sym)
  }
  val savedImports: List[String] = newList()
  var i = 0
  while i < tbl.scopeImports.count {
    savedImports.add(tbl.scopeImports[i])
    i = i + 1
  }
  val savedFile = symTableCurrentFile(tbl)
  symTableEnterSpanFile(tbl, sym.declSpan)
  SavedScope(pkg = cur, imports = savedImports, file = savedFile)
}

func restoreScope(tbl: in SymbolTable, saved: in SavedScope): Unit {
  symTableSetScope(tbl, saved.pkg, saved.imports)
  symTableEnterFile(tbl, saved.file)
}

// #6739: shared missing-required-field check, used by both the generic and
// non-generic constructor paths in `inferConstruction` (originally #3156,
// scoped to the generic path only — a non-generic record omitting a required
// field type-checked silently and codegen emitted invalid IL).  Only runs
// when all supplied args are named: mixed positional/named under-application
// is rare and out of scope, same as before.  Emits one T0105 per missing
// field and returns true iff at least one was reported.
func reportMissingCtorFields(
  fields: in List[CtorField],
  args: in List[CallArg],
  sym: in Symbol,
  span: in Span,
  diag: in List[Diagnostic],
): Bool {
  var hasPositional = false
  var hasUnknownName = false
  var ani = 0
  while ani < args.count {
    match args[ani] {
      case CAPositional(_) -> {
        hasPositional = true
      }
      case CANamed(nm, _, _) -> if not fieldHasName(fields, nm) { hasUnknownName = true }
    }
    ani = ani + 1
  }
  // #6739 regression guard: `Point(z = 3)` for `Point { x: Int; y: Int }`
  // supplies only an unrecognized field name — every REAL field looks
  // "missing" by construction. Reporting T0105 for x/y here would bury the
  // actual defect (T0101 "no field 'z'") under two confusing, unrelated
  // diagnostics; defer entirely to the ordinary per-arg T0101 validation
  // when any supplied name isn't a real field.
  val missing: List[String] = newList()
  if not hasPositional and not hasUnknownName {
    var mfi = 0
    while mfi < fields.count {
      val f = fields[mfi]
      if not f.hasDefault {
        var supplied = false
        var si = 0
        while si < args.count {
          match args[si] {
            case CANamed(nm, _, _) -> if nm == f.name { supplied = true }
            case CAPositional(_) -> {
            }
          }
          si = si + 1
        }
        if not supplied {
          missing.add(f.name)
        }
      }
      mfi = mfi + 1
    }
  }
  if missing.count > 0 {
    var mi = 0
    while mi < missing.count {
      diag.add(
        errorDiagnostic("T0105", "constructor '" + sym.name + "' is missing required field '" + missing[mi] + "'", span)
      )
      mi = mi + 1
    }
    true
  } else {
    false
  }
}

func ctorResultType(sym: in Symbol): Type {
  if ctorIsGeneric(sym) {
    return TyError
  }
  match symbolTypeIdOpt(sym) {
    case Some(tid) -> TyUser(id = tid, name = sym.name, args = newList())
    case None -> TyError
  }
}

// How many trailing parameters of a codegen builtin's signature may be
// omitted at a call: `assert`'s message and `println`'s value (`println()`
// writes an empty line).  Zero for every other callee.
func builtinOptionalTrailingArgs(fn: in Expr, recvTy: in Option[Type]): Int {
  match fn.kind {
    case EPath(p) -> if p.segments.count == 1 and (p.segments[0] == "assert" or p.segments[0] == "println") {
      1
    } else {
      0
    }
    // #7335: `s.substring(start)` / `s.substring(start, count)` — the second
    // `Int` param `stringHostMethodType` declares is optional.  Only for a
    // `String` receiver: a user member that happens to be named `substring`
    // keeps its full arity.
    case EMember(_, mname) -> if mname == "substring" and isStringReceiver(recvTy) { 1 } else { 0 }
    case _ -> 0
  }
}

func isStringReceiver(recvTy: in Option[Type]): Bool {
  match recvTy {
    case Some(t) -> match t { case TyPrim(p) -> match p { case PtString -> true; case _ -> false }; case _ -> false }
    case None -> false
  }
}

// Record `span` as a construction of `sym` when the type declares
// `invariant:` clauses and its construction checker
// (`__lyric_checked_<Name>`, synthesized in the declaring package by
// `Lyric.ContractElaborator.synthesizeInvariantCheckers`) is visible here.  A
// type restored from a package built without checkers has none, and is
// constructed unchecked rather than failing to compile.
func recordInvariantCtorSite(tbl: in SymbolTable, sym: in Symbol, span: in Span): Unit {
  match invariantCheckerPath(tbl, sym) {
    case Some(path) -> {
      val key = recordCopySiteKey(span)
      if not tbl.invariantCtorSites.containsKey(key) {
        tbl.invariantCtorSites.add(key, path)
      }
    }
    case None -> ()
  }
}

// The dotted path of `sym`'s construction checker when `sym` is a type that
// declares `invariant:` clauses and the checker is visible here.
func invariantCheckerPath(tbl: in SymbolTable, sym: in Symbol): Option[String] {
  val hasInv = match sym.kind {
    case DKRecord(_, rd) -> recordDeclHasInvariant(rd.members)
    case DKExposedRec(_, rd) -> recordDeclHasInvariant(rd.members)
    case DKOpaque(_, od) -> opaqueDeclHasInvariant(od.members)
    case _ -> false
  }
  // A restored type's contract `repr` carries no `invariant:` clauses, so an
  // imported record or opaque type is judged by its checker instead: the
  // reserved `__lyric_checked_<Name>` is synthesized only for a type that
  // declares invariants, and the declaring package exports it with the type.
  val restoredShape = match sym.kind {
    case DKRecord(_, _) -> true
    case DKExposedRec(_, _) -> true
    case DKOpaque(_, _) -> true
    case _ -> false
  }
  if not hasInv and not (sym.isImported and restoredShape) {
    return None
  }
  val checker = "__lyric_checked_" + sym.name
  var found = false
  var i = 0
  while i < tbl.symbols.count and not found {
    val cand = tbl.symbols[i]
    match cand.kind {
      case DKFunc(_) -> if cand.name == checker and cand.originPackage == sym.originPackage { found = true }
      case _ -> ()
    }
    i = i + 1
  }
  if not found {
    return None
  }
  Some(
    value = if sym.isImported and sym.originPackage.length > 0 { sym.originPackage + "." + checker } else { checker }
  )
}

func symbolIsNonGenericInvariantType(sym: in Symbol): Bool {
  match sym.kind {
    case DKRecord(_, rd) -> genericsAbsent(rd.generics)
    case DKExposedRec(_, rd) -> genericsAbsent(rd.generics)
    case DKOpaque(_, od) -> genericsAbsent(od.generics)
    case _ -> false
  }
}

func genericsAbsent(g: in Option[GenericParams]): Bool {
  match g {
    case None -> true
    case Some(_) -> false
  }
}

/// The non-generic invariant-bearing types a public function's signature can
/// name, keyed by the name a signature spells (`Url`, `Std.Http.Url`), valued
/// by the dotted path of the type's checker.  `imported` selects the types
/// declared in another package (the public-boundary parameter and result
/// checks, docs/08 §7.1) or in this one (the `inout` re-check).  A local
/// type shadows an imported one of the same name.
pub func invariantBoundaryTypes(tbl: in SymbolTable, imported: in Bool): Map[String, String] {
  val found: Map[String, String] = newMap()
  val localNames: Map[String, Bool] = newMap()
  var li = 0
  while li < tbl.symbols.count {
    if not tbl.symbols[li].isImported and not localNames.containsKey(tbl.symbols[li].name) {
      localNames.add(tbl.symbols[li].name, true)
    }
    li = li + 1
  }
  var i = 0
  while i < tbl.symbols.count {
    val sym = tbl.symbols[i]
    if imported and localNames.containsKey(sym.name) {
      i = i + 1
      continue
    }
    if sym.isImported == imported and symbolIsNonGenericInvariantType(sym) {
      match invariantCheckerPath(tbl, sym) {
        case Some(path) -> {
          if not found.containsKey(sym.name) {
            found.add(sym.name, path)
          }
          if imported and sym.originPackage.length > 0 {
            found.add(sym.originPackage + "." + sym.name, path)
          }
        }
        case None -> ()
      }
    }
    i = i + 1
  }
  found
}

func recordDeclHasInvariant(members: in List[RecordMember]): Bool {
  var i = 0
  while i < members.count {
    match members[i] {
      case RMInvariant(_) -> return true
      case _ -> ()
    }
    i = i + 1
  }
  false
}

func opaqueDeclHasInvariant(members: in List[OpaqueMember]): Bool {
  var i = 0
  while i < members.count {
    match members[i] {
      case OMInvariant(_) -> return true
      case _ -> ()
    }
    i = i + 1
  }
  false
}

func inferConstruction(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sym: in Symbol,
  args: in List[CallArg],
  argTypes: in List[Type],
  span: in Span,
): Type {
  inferConstructionExpected(tbl, diag, sym, args, argTypes, span, TyError)
}

// As `inferConstruction`, with the type the construction's position expects
// (`TyError` for none).  A generic record's type parameter that its field
// initializers leave unbound — `Box(left = xs, right = None)` for
// `Box[A, B]` — takes its argument from an expected instantiation of the
// same type (`val b: Box[Int, String] = ...`), matching how union-case
// constructors already use the expected type (D-progress-947).
func inferConstructionExpected(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sym: in Symbol,
  args: in List[CallArg],
  argTypes: in List[Type],
  span: in Span,
  expected: in Type,
): Type {
  recordInvariantCtorSite(tbl, sym, span)
  // For generic constructors, attempt to infer type arguments from the supplied
  // field initializer types before falling back to T0110.  T0110 fires only when
  // one or more type parameters remain unresolved after inference.
  if ctorIsGeneric(sym) {
    val gnames = ctorGenericNames(sym)
    val fieldNames = ctorFieldNames(sym)
    // #3156: check for missing required fields before attempting inference so
    // under-application is reported with a precise per-field diagnostic rather
    // than the confusing "cannot infer type arguments" T0110.
    val prelimFields: List[CtorField] = newList()
    val _ = collectCtorFields(tbl, sym, prelimFields)
    val _ = reportRepeatedCallArgs(diag, "T0104", "field", args, fieldNames)
    if reportMissingCtorFields(prelimFields, args, sym, span, diag) {
      return TyError
    }
    // Collect field types with generic names in context so type-param fields
    // resolve to TyVar("T") (not TyError), enabling inference from arg types.
    // Reorder argTypes to declaration order (#3157): named args are matched by
    // field name, positional args fill remaining slots left to right.
    val fieldTypes = ctorFieldTypes(tbl, sym, gnames)
    val orderedArgTypes = argTypesInFieldOrder(args, argTypes, fieldNames)
    val targs = inferGenericArgs(gnames, fieldTypes, orderedArgTypes)
    match unrefine(expected) {
      case TyUser(eid, _, eargs) -> match symbolTypeIdOpt(sym) {
        case Some(tid) -> if symbolIdEq(eid, tid) and eargs.count == gnames.count {
          var ei = 0
          while ei < gnames.count {
            val unbound = match targs[ei] { case TyError -> true; case _ -> false }
            if unbound {
              targs[ei] = eargs[ei]
            }
            ei = ei + 1
          }
        }
        case None -> ()
      }
      case _ -> ()
    }
    // A value generic parameter two array fields give different lengths
    // (D169) is T0043, as for a value-generic function's arguments.
    var vi = 0
    while vi < gnames.count {
      val isErr = match targs[vi] { case TyError -> true; case _ -> false }
      if isErr {
        val lens = valueParamLengths(gnames[vi], fieldTypes, orderedArgTypes)
        if lens.count > 1 {
          diag.add(
            errorDiagnostic(
              "T0043",
              "the length '" + gnames[vi] + "' of '" + sym.name + "' is given as " + toString(lens[0]) + " by one field and " +
                toString(lens[1]) +
                " by another",
              span
            )
          )
          return TyError
        }
      }
      vi = vi + 1
    }
    // Collect names of parameters that could not be inferred.
    val unresolved: List[String] = newList()
    var gi = 0
    while gi < gnames.count {
      val isErr = match targs[gi] { case TyError -> true; case _ -> false }
      if isErr {
        // Suppress T0110 for this param when the inference failure is due to
        // an erased type variable (TyError from eraseTyVars in bindPatternTyped).
        // A TyError arg at a field position that constrains the param is a lenient
        // wildcard, not a genuine mismatch — consistent with typeEquiv treating
        // TyError as a wildcard everywhere else in the type checker.
        if not anyFieldArgIsLenientForParam(gnames[gi], fieldTypes, orderedArgTypes) {
          unresolved.add(gnames[gi])
        }
      }
      gi = gi + 1
    }
    if unresolved.count > 0 {
      // #3155: surface genuine field-type resolution errors (e.g. unknown type
      // names in field declarations) that were swallowed by the inference probe.
      surfaceCtorFieldTypeErrors(tbl, sym, diag)
      var msg = "cannot infer type argument(s) for generic constructor '" + sym.name + "': "
      var ui = 0
      while ui < unresolved.count {
        if ui > 0 {
          msg = msg + ", "
        }
        msg = msg + "'" + unresolved[ui] + "'"
        ui = ui + 1
      }
      msg = msg + " could not be inferred from the supplied arguments"
      diag.add(errorDiagnostic("T0110", msg, span))
      return TyError
    }
    val inferredTy = match symbolTypeIdOpt(sym) {
      case Some(tid) -> TyUser(id = tid, name = sym.name, args = targs)
      case None -> TyError
    }
    noteValueRecordCtor(tbl, diag, sym, targs, span)
    // #1485: an opaque type's representation is hidden.
    if ctorIsOpaque(sym) and sym.isImported {
      diag.add(
        errorDiagnostic("T0100", "cannot construct opaque type '" + sym.name + "' outside its declaring package", span)
      )
      return inferredTy
    }
    // Each argument is checked against its field's type with the record's own
    // type parameters in scope, instantiated at the inferred arguments
    // (`instantiatedFieldType`).  The plain `fields` list resolves field types
    // without them, so a parameter named like a type of the constructing
    // package (`Msg`) bound to that type instead (D-progress-980).
    // Reuse the field list collected for the missing-field check above (#3162):
    // both calls traverse the same symbol and produce identical results.
    val fields = prelimFields
    var posIdx = 0
    var i = 0
    while i < args.count {
      val argTy = if i < argTypes.count { argTypes[i] } else { TyError }
      match args[i] {
        case CANamed(nm, valE, asp) -> {
          if not fieldHasName(fields, nm) {
            diag.add(errorDiagnostic("T0101", "'" + sym.name + "' has no field '" + nm + "'", asp))
          } else {
            val fieldTy = instantiatedFieldType(fieldNames, fieldTypes, gnames, targs, nm, fieldTypeByName(fields, nm))
            recordUnsignedWidening(tbl, fieldTy, argTy, valE)
            noteRangeSlot(tbl, fieldTy, valE, sym.name + " field " + nm)
            if not argFlowSatisfies(tbl, fieldTy, argTy, valE) and not literalArgSatisfiesParam(tbl, fieldTy, argTy, valE) {
              diag.add(
                errorDiagnostic(
                  "T0104",
                  "argument for field '" + nm + "' " + hasTypeOrEmptyLiteral(argTy, valE) + " but field expects " +
                    renderType(fieldTy) +
                    typeMismatchHint(tbl, fieldTy, argTy),
                  asp
                )
              )
            }
          }
        }
        case CAPositional(ae) -> {
          posIdx = nextUnnamedField(fields, args, posIdx)
          if posIdx >= fields.count {
            diag.add(
              errorDiagnostic(
                "T0104",
                "'" + sym.name + "' has " + toString(fields.count) + " field(s) but positional argument " + toString(posIdx + 1) +
                  " was supplied",
                ae.span
              )
            )
          } else {
            val fieldTy = instantiatedFieldType(fieldNames, fieldTypes, gnames, targs, fields[posIdx].name, fields[posIdx].ty)
            recordUnsignedWidening(tbl, fieldTy, argTy, ae)
            noteRangeSlot(tbl, fieldTy, ae, sym.name + " field " + fields[posIdx].name)
            if not argFlowSatisfies(tbl, fieldTy, argTy, ae) and not literalArgSatisfiesParam(tbl, fieldTy, argTy, ae) {
              diag.add(
                errorDiagnostic(
                  "T0104",
                  "positional argument " + toString(posIdx + 1) + " " + hasTypeOrEmptyLiteral(argTy, ae) + " but field '" +
                    fields[posIdx].name +
                    "' expects " +
                    renderType(fieldTy) +
                    typeMismatchHint(tbl, fieldTy, argTy),
                  ae.span
                )
              )
            }
          }
          posIdx = posIdx + 1
        }
      }
      i = i + 1
    }
    noteCtorZeroArgs(
      tbl,
      diag,
      sym,
      fields,
      args,
      span,
      { name: String, declared: Type -> instantiatedFieldType(fieldNames, fieldTypes, gnames, targs, name, declared) }
    )
    return inferredTy
  }
  val resultTy = ctorResultType(sym)
  // #1485: an opaque type's representation is hidden — it cannot be constructed
  // from outside its declaring package.
  if ctorIsOpaque(sym) and sym.isImported {
    diag.add(
      errorDiagnostic("T0100", "cannot construct opaque type '" + sym.name + "' outside its declaring package", span)
    )
    return resultTy
  }
  val fields: List[CtorField] = newList()
  val _ = collectCtorFields(tbl, sym, fields)
  val _ = reportRepeatedCallArgs(diag, "T0104", "field", args, ctorFieldNames(sym))
  // #6739: generalizes the #3156 missing-required-field check (originally
  // scoped to the generic-constructor path only) to non-generic records —
  // omitting a required field from an all-named-args construction used to
  // type-check silently and emit invalid IL at the MSIL/JVM boundary.
  if reportMissingCtorFields(fields, args, sym, span, diag) {
    return TyError
  }
  // C2: validate argument names, arity, and value types.
  // First pass: named-arg field-name and value-type check.
  // Second pass: positional args against fields in declaration order.
  var posIdx = 0
  var i = 0
  while i < args.count {
    val argTy = if i < argTypes.count { argTypes[i] } else { TyError }
    match args[i] {
      case CANamed(nm, valE, asp) -> {
        if not fieldHasName(fields, nm) {
          diag.add(errorDiagnostic("T0101", "'" + sym.name + "' has no field '" + nm + "'", asp))
        } else {
          val fieldTy = fieldTypeByName(fields, nm)
          recordUnsignedWidening(tbl, fieldTy, argTy, valE)
          noteRangeSlot(tbl, fieldTy, valE, sym.name + " field " + nm)
          if not argSatisfiesCtorField(tbl, sym, fieldTy, argTy, valE) and not literalArgSatisfiesParam(tbl, fieldTy, argTy, valE) {
            diag.add(
              errorDiagnostic(
                "T0104",
                "argument for field '" + nm + "' " + hasTypeOrEmptyLiteral(argTy, valE) + " but field expects " +
                  renderType(fieldTy) +
                  typeMismatchHint(tbl, fieldTy, argTy),
                asp
              )
            )
          }
        }
      }
      case CAPositional(ae) -> {
        posIdx = nextUnnamedField(fields, args, posIdx)
        if posIdx >= fields.count {
          diag.add(
            errorDiagnostic(
              "T0104",
              "'" + sym.name + "' has " + toString(fields.count) + " field(s) but positional argument " + toString(posIdx + 1) +
                " was supplied",
              ae.span
            )
          )
        } else {
          val fieldTy = fields[posIdx].ty
          recordUnsignedWidening(tbl, fieldTy, argTy, ae)
          noteRangeSlot(tbl, fieldTy, ae, sym.name + " field " + fields[posIdx].name)
          if not argSatisfiesCtorField(tbl, sym, fieldTy, argTy, ae) and not literalArgSatisfiesParam(tbl, fieldTy, argTy, ae) {
            diag.add(
              errorDiagnostic(
                "T0104",
                "positional argument " + toString(posIdx + 1) + " " + hasTypeOrEmptyLiteral(argTy, ae) + " but field '" +
                  fields[posIdx].name +
                  "' expects " +
                  renderType(fieldTy) +
                  typeMismatchHint(tbl, fieldTy, argTy),
                ae.span
              )
            )
          }
        }
        posIdx = posIdx + 1
      }
    }
    i = i + 1
  }
  noteCtorZeroArgs(tbl, diag, sym, fields, args, span, { name: String, declared: Type -> declared })
  resultTy
}

// Record the zero value of each array field the construction at `span`
// leaves out (D167), for `lowerArrays` to pass as a named argument.  The zero
// is built from the field's type as the construction sees it: a record from
// another package carries no default for the field, and a generic record's
// element type is known only here.  A generic record instantiated at an
// element type with no zero needs the field given (T0105).
func noteCtorZeroArgs(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sym: in Symbol,
  fields: in List[CtorField],
  args: in List[CallArg],
  span: in Span,
  fieldTypeAt: (String, Type) -> Type,
): Unit {
  var positional = 0
  for a in args {
    match a {
      case CAPositional(_) -> {
        positional = positional + 1
      }
      case CANamed(_, _, _) -> ()
    }
  }
  val zsp = Span(startPos = span.startPos, endPos = span.startPos)
  val zeros: List[CallArg] = newList()
  var fi = 0
  while fi < fields.count {
    val f = fields[fi]
    var supplied = fi < positional
    for a in args {
      match a {
        case CANamed(nm, _, _) -> if nm == f.name { supplied = true }
        case CAPositional(_) -> ()
      }
    }
    if f.zeroFill and not supplied {
      val fty = fieldTypeAt(f.name, f.ty)
      match zeroExprFor(tbl, fty, zsp, 0) {
        case Some(z) -> zeros.add(CANamed(name = f.name, value = z, span = zsp))
        case None -> diag.add(
          errorDiagnostic(
            "T0105",
            "constructor '" + sym.name + "' is missing required field '" + f.name + "': its type " +
              renderType(fty) +
              " has no zero value to fill it with",
            span
          )
        )
      }
    }
    fi = fi + 1
  }
  val key = recordCopySiteKey(span)
  if zeros.count > 0 and not tbl.arrayCtorZeroArgs.containsKey(key) {
    tbl.arrayCtorZeroArgs.add(key, zeros)
  }
}

// A QUALIFIED constructor call (`Pkg.Type(...)` or `Pkg.Sub.Type(...)`, the
// latter a nested `EMember` chain over an `EPath` head) previously returned
// `None` here unconditionally — the single-segment-only match below is the
// ONLY arm that ever matched.  `inferConstruction`'s per-field T0104 argument
// validation (and #1485's opaque-construction T0100 check) therefore never
// ran for ANY qualified constructor call: the caller falls through to the
// generic function-call type path instead, which type-checks leniently and
// silently accepts a wrong-typed field argument (a restored/imported
// record's `Docker.DockerError(details = Some("d"))` against a plain
// `String` field compiled to invalid IL at the MSIL boundary — codegen
// correctly used the record's real field type; the checker just never
// looked, #6519).  Mirrors `unionCaseSymbolOf`'s #6287 qualifier-tier fix:
// flatten the callee path, then try (a) the whole qualifier as the
// constructor's declaring package, falling back to (b) the historical bare
// last-segment lookup for an unqualified `EPath` callee (guarded by
// `fnWasFlatPath`, same EMember-chain-misrouting hazard `unionCaseSymbolOf`
// documents — a value-receiver method chain like `x.Foo(...)` must not
// mis-route into constructor typing via the bare-name fallback).
// A bare (unqualified) `ctorName` reaching the final fallback below is
// resolved leniently (no ambiguity check here): the ECall caller already
// invoked `resolveExprPath` on this same flat-`EPath` callee to type `fnT`
// (#6287's `checkBareNameAmbiguity` gate lives there, the single
// authoritative site for a bare callee name — adding a second check here
// would double-emit T0123 for one source reference, the exact hazard #6539
// fixed for the pattern-head path).
func constructorSymbolOf(tbl: in SymbolTable, fn: in Expr): Option[Symbol] {
  val flatSegs: List[String] = newList()
  if not flattenCalleePathSegs(fn, flatSegs) or flatSegs.count == 0 {
    return None
  }
  val fnWasFlatPath = match fn.kind { case EPath(_) -> true; case _ -> false }
  val ctorName = flatSegs[flatSegs.count - 1]
  if flatSegs.count >= 2 {
    val quals: List[String] = newList()
    var qi = 0
    while qi < flatSegs.count - 1 {
      quals.add(flatSegs[qi])
      qi = qi + 1
    }
    val fullQual = modulePathJoin(quals)
    match symTableTryFindInPackage(tbl, fullQual, ctorName) {
      case Some(pkgSym) -> match pkgSym.kind {
        case DKRecord(_, _) -> return Some(value = pkgSym)
        case DKExposedRec(_, _) -> return Some(value = pkgSym)
        case DKOpaque(_, _) -> return Some(value = pkgSym)
        case DKProtected(_, _) -> return Some(value = pkgSym)
        case _ -> ()
      }
      case None -> ()
    }
  }
  if not fnWasFlatPath {
    return None
  }
  match symTableTryFindOne(tbl, ctorName) {
    case Some(sym) -> match sym.kind {
      case DKRecord(_, _) -> Some(value = sym)
      case DKExposedRec(_, _) -> Some(value = sym)
      case DKOpaque(_, _) -> Some(value = sym)
      case DKProtected(_, _) -> Some(value = sym)
      case _ -> None
    }
    case None -> None
  }
}

// The union/enum TYPE symbol for a callee path — the shape behind #6838: a
// call whose callee names a union or enum *type* itself
// (`Pkg.Sub.DbError(message = "…")`) rather than one of its cases. There is no
// such constructor — a union/enum value is built through a case
// (`OpenFailed(message = "…")`) — so this callee never resolves to a function
// token. `unionCaseSymbolOf` and `constructorSymbolOf` have both already
// returned None (it is neither a case nor a record/opaque ctor) by the time
// this runs. Mirrors `constructorSymbolOf`'s qualifier-first / flat-path
// resolution exactly, matching the two TYPE kinds it deliberately skips, so a
// value-receiver method chain (`x.Foo(...)`) can never mis-route here.
func unionOrEnumTypeSymbolOf(tbl: in SymbolTable, fn: in Expr): Option[Symbol] {
  val flatSegs: List[String] = newList()
  if not flattenCalleePathSegs(fn, flatSegs) or flatSegs.count == 0 {
    return None
  }
  val fnWasFlatPath = match fn.kind { case EPath(_) -> true; case _ -> false }
  val typeName = flatSegs[flatSegs.count - 1]
  if flatSegs.count >= 2 {
    val quals: List[String] = newList()
    var qi = 0
    while qi < flatSegs.count - 1 {
      quals.add(flatSegs[qi])
      qi = qi + 1
    }
    val fullQual = modulePathJoin(quals)
    match symTableTryFindInPackage(tbl, fullQual, typeName) {
      case Some(pkgSym) -> match pkgSym.kind {
        case DKUnion(_, _) -> return Some(value = pkgSym)
        case DKEnum(_, _) -> return Some(value = pkgSym)
        case _ -> ()
      }
      case None -> ()
    }
  }
  if not fnWasFlatPath {
    return None
  }
  match symTableTryFindOne(tbl, typeName) {
    case Some(sym) -> match sym.kind {
      case DKUnion(_, _) -> Some(value = sym)
      case DKEnum(_, _) -> Some(value = sym)
      case _ -> None
    }
    case None -> None
  }
}

// A human hint listing the constructible cases of a union/enum type symbol
// (e.g. "OpenFailed, ExecFailed"), appended to the T0125 message so the fix
// — name a case — is obvious. Empty string for a caseless type.
func unionOrEnumCaseNamesHint(sym: in Symbol): String {
  val names: List[String] = newList()
  match sym.kind {
    case DKUnion(_, udecl) -> {
      var ui = 0
      while ui < udecl.cases.count {
        names.add(udecl.cases[ui].name)
        ui = ui + 1
      }
    }
    case DKEnum(_, edecl) -> {
      var ei = 0
      while ei < edecl.cases.count {
        names.add(edecl.cases[ei].name)
        ei = ei + 1
      }
    }
    case _ -> ()
  }
  var acc = ""
  var j = 0
  while j < names.count {
    if j > 0 {
      acc = acc + ", "
    }
    acc = acc + names[j]
    j = j + 1
  }
  return acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §5b. Union-case constructor typing (#2142 prerequisite).
// ─────────────────────────────────────────────────────────────────────────────
//
// `Some(value = x)` / `Ok(v)` / `None` are union-case constructors, not
// functions or record ctors — they were resolving to `TyError`.  Type them as
// the *parent union instantiated with the type args inferred from the
// arguments*: `Some(value: String)` -> `Option[String]`.  A case with no fields
// (`None`) or an uninferable generic position yields `TyError` type-args (kept
// lenient — `None` is `Option[?]` for any `?`).
// The union-case symbol for a constructor reference `fn`.
//
// A QUALIFIED constructor honours its qualifier (#6287): before this,
// `PkgA.Ping(...)` resolved the bare last segment last-registered-wins, so a
// colliding case name in another imported package silently won over the
// explicitly named one (surfacing as a baffling `T0043 Signal vs Signal`).
// Two legal qualifier shapes are tried, most-specific first:
//   (a) a package path — `PkgA.Ping(...)`, `A.B.Ping(...)`;
//   (b) the parent union's simple name, optionally itself
//       package-qualified — `Signal.Ping(...)`, `PkgA.Signal.Ping(...)`.
// When the qualifier matches neither, fall through to the historical bare
// lookup so import-relative or synthesized spellings keep resolving.
// Flatten a pure dotted-path callee into its segments: a flat `EPath`
// (`PkgA.Ping`) or a nested `EMember` chain over an `EPath` head
// (`PkgA.Signal.Ping` parses this way — the parser builds postfix members
// left-to-right).  Returns false (dest untouched semantics-wise) for any
// non-path shape (real receivers, calls, indexing).
func flattenCalleePathSegs(e: in Expr, dest: in List[String]): Bool {
  match e.kind {
    case EPath(p) -> {
      var i = 0
      while i < p.segments.count {
        dest.add(p.segments[i])
        i = i + 1
      }
      true
    }
    case EMember(recv, memberName) -> {
      if flattenCalleePathSegs(recv, dest) {
        dest.add(memberName)
        true
      } else {
        false
      }
    }
    case EParen(inner) -> flattenCalleePathSegs(inner, dest)
    case _ -> false
  }
}

func unionCaseSymbolOf(tbl: in SymbolTable, fn: in Expr): Option[Symbol] {
  val flatSegs: List[String] = newList()
  if not flattenCalleePathSegs(fn, flatSegs) or flatSegs.count == 0 {
    return None
  }
  // An `EMember` chain is only *treated* as a path when a qualifier tier
  // below actually matches — its bare-name fallback stays reserved for the
  // shapes the pre-#6287 code handled (a flat `EPath` callee).  Without
  // this, a method call on a value receiver (`x.Ping(...)`) whose member
  // name collides with some union case would mis-route to constructor
  // typing instead of falling through to method resolution.
  val fnWasFlatPath = match fn.kind { case EPath(_) -> true; case _ -> false }
  val p = ModulePath(segments = flatSegs, span = fn.span)
  val caseName = p.segments[p.segments.count - 1]
  if p.segments.count >= 2 {
    val quals: List[String] = newList()
    var qi = 0
    while qi < p.segments.count - 1 {
      quals.add(p.segments[qi])
      qi = qi + 1
    }
    // (a) whole qualifier as the declaring package.
    val fullQual = modulePathJoin(quals)
    match symTableTryFindInPackage(tbl, fullQual, caseName) {
      case Some(pkgSym) -> match pkgSym.kind { case DKUnionCase(_, _) -> return Some(value = pkgSym); case _ -> () }
      case None -> ()
    }
    // (b) last qualifier segment as the parent union's simple name,
    // any leading segments as its declaring package.
    val unionName = quals[quals.count - 1]
    val pkgSegs: List[String] = newList()
    var pj = 0
    while pj < quals.count - 1 {
      pkgSegs.add(quals[pj])
      pj = pj + 1
    }
    val pkgPrefix = modulePathJoin(pkgSegs)
    val candidates = symTableTryFindAll(tbl, caseName)
    var ci = candidates.count - 1
    while ci >= 0 {
      val cand = candidates[ci]
      match cand.kind {
        case DKUnionCase(parentId, _) -> {
          val parentMatches = match parentUnionDeclOf(tbl, parentId) {
            case Some(pu) -> pu.name == unionName
            case None -> false
          }
          if parentMatches and (pkgPrefix.length == 0 or cand.originPackage == pkgPrefix) {
            return Some(value = cand)
          }
        }
        case _ -> ()
      }
      ci = ci - 1
    }
  }
  if not fnWasFlatPath {
    return None
  }
  match symTableTryFindOne(tbl, caseName) {
    case Some(sym) -> match sym.kind { case DKUnionCase(_, _) -> Some(value = sym); case _ -> None }
    case None -> None
  }
}

// The union-case symbol for a PATTERN head, preferring the case declared by
// the SCRUTINEE's own union (#6287): with two imported unions sharing a case
// name, the bare pattern `case Ping(c)` must bind the fields of the union
// being matched, not whichever colliding case was registered last.  Falls
// back to the name-based lookup when the scrutinee is not a known union
// (TyError-lenient scrutinees keep the historical behaviour).
//
// #6287 Phase B: an EXPLICITLY qualified pattern head (`case PkgB.Ping(c)`)
// must have its qualifier validated against the scrutinee's OWN union,
// mirroring `unionCaseSymbolOf`'s qualifier tiers — (a) the whole qualifier
// as the declaring package, (b) the last qualifier segment as the parent
// union's simple name (with any leading segments as its declaring package)
// — rather than silently ignored.  Before this, `PkgB.Ping(c)` matched
// against a `PkgA`-typed scrutinee bound its fields from whichever `Ping`
// case happened to be the scrutinee's own, discarding the user's explicit
// (and here, WRONG) qualifier with no diagnostic.  A qualifier that matches
// neither tier is now a hard error (T0122) instead of a silent fallback.
func unionCaseSymbolForScrutinee(
  tbl: in SymbolTable, diag: in List[Diagnostic], fn: in Expr, scrutineeTy: in Type
): Option[Symbol] {
  match unrefine(scrutineeTy) {
    case TyUser(sid, sname, _) -> {
      val flatSegs: List[String] = newList()
      val hasSegs = flattenCalleePathSegs(fn, flatSegs) and flatSegs.count > 0
      val scrCaseName = if hasSegs { flatSegs[flatSegs.count - 1] } else { "" }
      if scrCaseName.length > 0 {
        val scrCands = symTableTryFindAll(tbl, scrCaseName)
        var sci = scrCands.count - 1
        while sci >= 0 {
          match scrCands[sci].kind {
            case DKUnionCase(scrParent, _) -> {
              if symbolIdEq(scrParent, sid) {
                if flatSegs.count >= 2 {
                  val quals: List[String] = newList()
                  var qi = 0
                  while qi < flatSegs.count - 1 {
                    quals.add(flatSegs[qi])
                    qi = qi + 1
                  }
                  val fullQual = modulePathJoin(quals)
                  val tierA = scrCands[sci].originPackage == fullQual
                  val unionName = quals[quals.count - 1]
                  val pkgSegs: List[String] = newList()
                  var pj = 0
                  while pj < quals.count - 1 {
                    pkgSegs.add(quals[pj])
                    pj = pj + 1
                  }
                  val pkgPrefix = modulePathJoin(pkgSegs)
                  val actualUnionName = match parentUnionDeclOf(tbl, scrParent) { case Some(pu) -> pu.name; case None -> scrCaseName }
                  val tierB = actualUnionName == unionName and (pkgPrefix.length == 0 or scrCands[sci].originPackage == pkgPrefix)
                  if not (tierA or tierB) {
                    diag.add(
                      errorDiagnostic(
                        "T0122",
                        "pattern qualifier '" + fullQual + "' does not match the scrutinee's own union '" + scrCands[sci].originPackage +
                          "." +
                          actualUnionName +
                          "' — this pattern is matched against a value of that union, not '" +
                          fullQual +
                          "'",
                        fn.span
                      )
                    )
                    return None
                  }
                }
                // #7591: a package-private union's case is T0097 (never
                // T0020) whether or not its package is imported, AND
                // whether the head is qualified or bare — a `pub` wrapper
                // function can return a package-private union with no
                // diagnostic at its own call site (docs/01 §3.1 enforces
                // visibility at the use site that NAMES the type), so a
                // bare case-pattern head naming that private case is the
                // first point it gets named. Mirrors
                // `checkUnimportedTypeReceiver`'s ordering (privacy before
                // reachability).
                if symbolIsPackagePrivateBinding(scrCands[sci]) {
                  checkImportedVisibility(tbl, scrCands[sci], fn.span, diag)
                  return None
                }
                if flatSegs.count >= 2 {
                  // The qualifier matches the scrutinee's own union
                  // structurally (tier A/B above), but `Lyric.Pipeline`
                  // preloads every stdlib package's signatures whatever the
                  // file imports (D-progress-1011), so that match alone
                  // doesn't mean the union's OWN package is reachable from
                  // this file's imports. Same T0020 a qualified expression
                  // path into an unimported package gets. A bare head needs
                  // no such check: D141 resolves a bare case-pattern head
                  // through the scrutinee's own type whatever the imports,
                  // so its package is reachable by construction once it is
                  // not private.
                  if reportUnimportedQualifiedPackage(tbl, symTableScopePkg(tbl), scrCands[sci].originPackage, scrCaseName, fn.span, diag) {
                    return None
                  }
                }
                return Some(value = scrCands[sci])
              }
            }
            // Enum-case analog of the DKUnionCase branch above (#6608): a
            // qualified nullary-case pattern matched against a known enum
            // scrutinee (`case GrpcStatusCode.Ok -> ...`) must resolve
            // against the SCRUTINEE's own enum, not fall through to the
            // bare-name ambiguity check below — `pat2fnExpr` always wraps
            // the pattern head as a flat `EPath` regardless of how many
            // segments it has, so an unguarded fallthrough treats an
            // explicitly-qualified enum-case name as if it were bare and
            // spuriously fires T0123 when some other package happens to
            // export a same-named case (e.g. `Std.Core.Ok`).  There is no
            // `enumDeclIndex` mirroring `unionDeclIndex`, so tier B reuses
            // the scrutinee's own `TyUser` name (`sname`) instead of a
            // separate enum-decl lookup.
            case DKEnumCase(scrParent, _) -> {
              if symbolIdEq(scrParent, sid) {
                if flatSegs.count >= 2 {
                  val quals: List[String] = newList()
                  var qi = 0
                  while qi < flatSegs.count - 1 {
                    quals.add(flatSegs[qi])
                    qi = qi + 1
                  }
                  val fullQual = modulePathJoin(quals)
                  val tierA = scrCands[sci].originPackage == fullQual
                  val enumName = quals[quals.count - 1]
                  val pkgSegs: List[String] = newList()
                  var pj = 0
                  while pj < quals.count - 1 {
                    pkgSegs.add(quals[pj])
                    pj = pj + 1
                  }
                  val pkgPrefix = modulePathJoin(pkgSegs)
                  val tierB = sname == enumName and (pkgPrefix.length == 0 or scrCands[sci].originPackage == pkgPrefix)
                  if not (tierA or tierB) {
                    diag.add(
                      errorDiagnostic(
                        "T0122",
                        "pattern qualifier '" + fullQual + "' does not match the scrutinee's own enum '" + scrCands[sci].originPackage +
                          "." +
                          sname +
                          "' — this pattern is matched against a value of that enum, not '" +
                          fullQual +
                          "'",
                        fn.span
                      )
                    )
                    return None
                  }
                }
                // #7591: see the DKUnionCase arm's identical comments above
                // — privacy applies whether the head is qualified or bare.
                if symbolIsPackagePrivateBinding(scrCands[sci]) {
                  checkImportedVisibility(tbl, scrCands[sci], fn.span, diag)
                  return None
                }
                if flatSegs.count >= 2 {
                  if reportUnimportedQualifiedPackage(tbl, symTableScopePkg(tbl), scrCands[sci].originPackage, scrCaseName, fn.span, diag) {
                    return None
                  }
                }
                return Some(value = scrCands[sci])
              }
            }
            case _ -> ()
          }
          sci = sci - 1
        }
      }
    }
    case _ -> ()
  }
  // #6287: the scrutinee's own union didn't resolve the case name (unknown/
  // `TyError` scrutinee, or no case of the scrutinee's own union matches) —
  // falling through to a pure name-based lookup is ambiguous when two or
  // more imported packages export a case with this name.  Gated on a flat
  // `EPath` head the same way `unionCaseSymbolOf`'s own bare fallback is,
  // so a qualified head (already handled above, or an `EMember` receiver
  // chain) never reaches this check.
  //
  // #6700: `pat2fnExpr` always wraps the pattern head as a flat `EPath`
  // regardless of how many segments it has (see the `DKEnumCase` comment
  // above), so `fnWasFlatPath` alone does NOT mean "bare" — a fully
  // qualified pattern head like `PkgA.Ping` is an `EPath` too.  Without
  // also checking `flatSegs2.count == 1`, a qualified head whose scrutinee
  // tiers above failed to resolve (unknown/`TyError` scrutinee) had ONLY
  // its last segment checked for ambiguity, firing a nonsensical T0123
  // telling the user to qualify a reference they already qualified.  Only
  // a genuinely bare (single-segment) head reaches the ambiguity check;
  // a qualified head falls through to `unionCaseSymbolOf` below unchecked
  // here, same as before this fix for the count == 1 case.
  val fnWasFlatPath = match fn.kind { case EPath(_) -> true; case _ -> false }
  if fnWasFlatPath {
    val flatSegs2: List[String] = newList()
    if flattenCalleePathSegs(fn, flatSegs2) and flatSegs2.count == 1 {
      val bareName = flatSegs2[flatSegs2.count - 1]
      if checkBareNameAmbiguity(tbl, diag, bareName, fn.span) {
        return None
      }
    }
  }
  unionCaseSymbolOf(tbl, fn)
}

// #7584: `PRecord`'s own `head: ModulePath` (`case Pkg.Point { x = a } -> …` —
// grammar §8 spells a record pattern with a `{`, but the parser dispatches on
// that brace alone with no check that `head` names a record at all, let
// alone THIS scrutinee's record) used to be discarded entirely: both
// `bindPatternTyped` and `checkConstRefPattern` resolved fields purely from
// the scrutinee's own type, silently ignoring a head naming a different
// record, an unimported package, or a package-private type. Mirrors
// `unionCaseSymbolForScrutinee`'s qualifier handling for `PConstructor`
// (#6287 Phase B / #7548), but simpler: a record has no separate
// "case name" layer the way a union case has a parent union name, so the
// head's last segment is the record's own simple name and every segment
// before it must be exactly that record's declaring package (no tier B).
// Reports T0137 for a head that does not name the scrutinee's own record —
// wrong record, wrong package-qualifier text, or a head that resolves to
// something else entirely (a union case, a function, nothing) — then T0097
// for a package-private record (whether the head is qualified or bare,
// #7591: a `pub` wrapper function can return a package-private record with
// no diagnostic at its own call site — docs/01 §3.1 enforces visibility at
// the use site that NAMES the type — so a bare record-pattern head naming
// that private record is the first point it gets named) before T0020, for a
// qualified head only, for one whose package isn't reachable from this
// file's imports. A bare head needs no reachability check: D141 resolves a
// bare pattern head through the scrutinee's own type whatever the imports,
// so its package is reachable by construction once it is not private. An
// unresolved/unknown scrutinee (`TyError`, a type variable, `Self`, …) is
// left alone here — already diagnosed (or not yet resolvable) elsewhere, so
// this never cascades a second error onto an already-broken scrutinee.
func checkRecordPatternHead(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  head: in ModulePath,
  span: in Span,
  scrutineeTy: in Type,
): Unit {
  match unrefine(scrutineeTy) {
    case TyUser(sid, sname, _) -> {
      val segs = head.segments
      if segs.count == 0 {
        return
      }
      val recName = segs[segs.count - 1]
      val cands = symTableTryFindAll(tbl, recName)
      var ci = cands.count - 1
      while ci >= 0 {
        val isRecordHit = match cands[ci].kind {
          case DKRecord(did, _) -> symbolIdEq(did, sid)
          case DKExposedRec(did, _) -> symbolIdEq(did, sid)
          case _ -> false
        }
        if isRecordHit {
          if segs.count >= 2 {
            val quals: List[String] = newList()
            var qi = 0
            while qi < segs.count - 1 {
              quals.add(segs[qi])
              qi = qi + 1
            }
            val fullQual = modulePathJoin(quals)
            if cands[ci].originPackage != fullQual {
              diag.add(
                errorDiagnostic(
                  "T0137",
                  "record pattern qualifier '" + fullQual + "' does not match the scrutinee's own record '" +
                    cands[ci].originPackage +
                    "." +
                    recName +
                    "' — this pattern is matched against a value of that record, not '" +
                    fullQual +
                    "'",
                  span
                )
              )
              return
            }
          }
          // #7591: privacy applies whether the head is qualified or bare —
          // same ordering as #7548's union-case checks, privacy (T0097)
          // before reachability (T0020), so an unimported private record
          // still gets T0097.
          if symbolIsPackagePrivateBinding(cands[ci]) {
            checkImportedVisibility(tbl, cands[ci], span, diag)
            return
          }
          if segs.count >= 2 {
            if reportUnimportedQualifiedPackage(tbl, symTableScopePkg(tbl), cands[ci].originPackage, recName, span, diag) {
              return
            }
          }
          return
        }
        ci = ci - 1
      }
      diag.add(
        errorDiagnostic(
          "T0137",
          "record pattern head '" + modulePathJoin(segs) + "' does not match the scrutinee's own record type '" + sname +
            "'",
          span
        )
      )
    }
    case _ -> {
    }
  }
}

// A union- or enum-case pattern can only match a value of the union or enum
// that declares the case.  `unionCaseSymbolForScrutinee` falls back to a
// name-based lookup when the scrutinee's own type has no such case, so
// without this check `case Some(i)` against an `Int` scrutinee (or
// `case Ok(v)` against an `Option`) type-checked and then silently
// miscompiled: MSIL treated the Int as the case object, JVM failed
// verification.  Returns false (after reporting T0129) on a mismatch.
// Scrutinees whose type is unknown or open (`TyError`, `TyVar`, `TySelf`,
// nullable, exception) are left alone: those are either already
// diagnosed or resolved later.
func checkCasePatternScrutinee(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  caseSym: in Symbol,
  scrutineeTy: in Type,
  span: in Span,
): Bool {
  val parentId = match caseSym.kind {
    case DKUnionCase(pid, _) -> Some(value = pid)
    case DKEnumCase(pid, _) -> Some(value = pid)
    case _ -> None
  }
  match parentId {
    case None -> true
    case Some(pid) -> {
      val shown = renderType(scrutineeTy)
      val mismatched = not caseParentMatchesScrutinee(tbl, pid, scrutineeTy)
      if mismatched {
        diag.add(
          errorDiagnostic(
            "T0129",
            "pattern '" + caseSym.name + "' is a case of a different type and can never match a value of type '" + shown + "'",
            span
          )
        )
        return false
      }
      true
    }
  }
}

// Nullary-case analog of `checkCasePatternScrutinee` for a bare `case None`
// (parsed as a binding whose name is a case constructor).  Fires only when
// no case of that name belongs to the scrutinee's type.
func checkBareCasePatternScrutinee(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  name: in String,
  scrutineeTy: in Type,
  span: in Span,
): Unit {
  val cands = symTableTryFindAll(tbl, name)
  // #7591: a bare nullary-case pattern (`case Active ->`, no parens) is a
  // `PBinding` disambiguated to a case constructor here, entirely outside
  // `unionCaseSymbolForScrutinee`'s `PConstructor` path, so it needs its own
  // privacy check: naming another package's package-private union/enum
  // case, bare or not, is T0097.  The check must run on the scrutinee's OWN
  // case (#7608): `caseParentMatchesScrutinee` accepts any same-named case
  // when the scrutinee is an enum (there is no enum-decl index), so a
  // public case of another enum could otherwise stand in for a private one,
  // or a private one for a public scrutinee's.
  match unrefine(scrutineeTy) {
    case TyUser(sid, _, _) -> {
      var e = 0
      while e < cands.count {
        val own = match cands[e].kind {
          case DKUnionCase(pid, _) -> symbolIdEq(pid, sid)
          case DKEnumCase(pid, _) -> symbolIdEq(pid, sid)
          case _ -> false
        }
        if own {
          if symbolIsPackagePrivateBinding(cands[e]) {
            checkImportedVisibility(tbl, cands[e], span, diag)
          }
          return ()
        }
        e = e + 1
      }
    }
    case _ -> ()
  }
  var i = 0
  while i < cands.count {
    val cand = cands[i]
    val belongs = match cand.kind {
      case DKUnionCase(pid, _) -> caseParentMatchesScrutinee(tbl, pid, scrutineeTy)
      case DKEnumCase(pid, _) -> caseParentMatchesScrutinee(tbl, pid, scrutineeTy)
      case _ -> true
    }
    if belongs {
      return ()
    }
    i = i + 1
  }
  if cands.count > 0 {
    diag.add(
      errorDiagnostic(
        "T0129",
        "pattern '" + name + "' is a case of a different type and can never match a value of type '" +
          renderType(scrutineeTy) +
          "'",
        span
      )
    )
  }
}

// True unless the scrutinee is a concrete type that the case with parent
// `pid` can never belong to (see `checkCasePatternScrutinee`).
func caseParentMatchesScrutinee(tbl: in SymbolTable, pid: in SymbolId, scrutineeTy: in Type): Bool {
  match unrefine(scrutineeTy) {
    case TyUser(sid, _, _) -> {
      if symbolIdEq(sid, pid) {
        true
      } else {
        match parentUnionDeclOf(tbl, sid) {
          case Some(_) -> false
          case None -> true
        }
      }
    }
    case TyPrim(_) -> false
    case TyTuple(_) -> false
    case TyFunction(_, _, _) -> false
    case TyArray(_, _, _) -> false
    case TySlice(_) -> false
    case _ -> true
  }
}

func parentUnionDeclOf(tbl: in SymbolTable, parentId: in SymbolId): Option[UnionDecl] {
  val key = toString(parentId.id)
  if not tbl.unionDeclIndex.containsKey(key) {
    return None
  }
  val ix = tbl.unionDeclIndex[key]
  val decl = tbl.unionDeclList[ix]
  Some(value = decl)
}

func unionDeclGenericNames(decl: in UnionDecl): List[String] {
  val names: List[String] = newList()
  match decl.generics {
    case None -> {
    }
    case Some(g) -> {
      var j = 0
      while j < g.params.count {
        match g.params[j] {
          case GPType(nm, _) -> names.add(nm)
          case GPValue(nm, _, _) -> names.add(nm)
        }
        j = j + 1
      }
    }
  }
  names
}

// #6972: case field types are resolved lazily, on every use (construction,
// pattern destructuring), exactly like `collectCtorFields` resolves a
// record's field types — so the same cross-package same-name collision
// hazard applies here too (a caller that transitively imports an unrelated
// same-named type must not have it picked up in place of the union's OWN
// declaring-package resolution). `originPackage` is the union's own
// declaring package (both call sites have it via `caseSym.originPackage`);
// mirrors `collectCtorFields`'s save/switch-to-declaring-scope/restore,
// centralized here so both call sites (construction and pattern-bind) get
// the fix without duplicating the scope juggling.
func unionCaseFieldTypes(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  uc: in UnionCase,
  genericNames: in List[String],
  originPackage: in String,
): List[Type] {
  val ctx = newGenericContext()
  gctxPush(ctx, genericNames)
  val savedPkg: List[String] = newList()
  var spi = 0
  while spi < tbl.scopePkg.count {
    savedPkg.add(tbl.scopePkg[spi])
    spi = spi + 1
  }
  val savedImports: List[String] = newList()
  var sii = 0
  while sii < tbl.scopeImports.count {
    savedImports.add(tbl.scopeImports[sii])
    sii = sii + 1
  }
  val savedFile = symTableCurrentFile(tbl)
  symTableSetScope(tbl, originPackage, symTablePackageImportsOf(tbl, originPackage))
  symTableEnterSpanFile(tbl, uc.span)
  val result: List[Type] = newList()
  var i = 0
  while i < uc.fields.count {
    val fty = match uc.fields[i] {
      case UFNamed(_, te, _) -> resolveType(tbl, ctx, diag, te)
      case UFPos(te, _) -> resolveType(tbl, ctx, diag, te)
    }
    result.add(fty)
    i = i + 1
  }
  val restorePkg = if savedPkg.count > 0 { savedPkg[0] } else { "" }
  symTableSetScope(tbl, restorePkg, savedImports)
  symTableEnterFile(tbl, savedFile)
  result
}

// For each parent generic name, infer the concrete type argument from the
// supplied field/arg pairs.  Uses `findGenericInPair` (the deep recursive
// matcher already used by `inferGenericArgsDeep`) so nested generic positions
// such as `List[T]` or `(T, U)` are handled (#2179).
func inferGenericArgs(genericNames: in List[String], fieldTypes: in List[Type], argTypes: in List[Type]): List[Type] {
  val result: List[Type] = newList()
  var g = 0
  while g < genericNames.count {
    result.add(inferOneGenericArg(genericNames[g], fieldTypes, argTypes))
    g = g + 1
  }
  result
}

// A union-case argument initialises its field, so it widens to the field's
// type like any initialiser (#7805).
func recordCaseFieldWidenings(
  tbl: in SymbolTable,
  uc: in UnionCase,
  ftypes: in List[Type],
  gnames: in List[String],
  targs: in List[Type],
  args: in List[CallArg],
  argTypes: in List[Type],
): Unit {
  val names: List[String] = newList()
  var i = 0
  while i < uc.fields.count {
    match uc.fields[i] {
      case UFNamed(nm, _, _) -> names.add(nm)
      case UFPos(_, _) -> names.add("")
    }
    i = i + 1
  }
  val srcIdx = argIndicesInParamOrder(args, names)
  var k = 0
  while k < srcIdx.count and k < ftypes.count {
    val ai = srcIdx[k]
    if ai >= 0 and ai < argTypes.count {
      val fieldTy = substituteTyVars(ftypes[k], gnames, targs)
      val _ = covariantFlow(tbl, fieldTy, argTypes[ai], callArgExpr(args[ai]))
      recordUnsignedWidening(tbl, fieldTy, argTypes[ai], callArgExpr(args[ai]))
      val fieldLabel = if names[k].length > 0 { "field " + names[k] } else { "field " + toString(k + 1) }
      noteRangeSlot(tbl, fieldTy, callArgExpr(args[ai]), uc.name + " " + fieldLabel)
      // An unsuffixed float literal for a `Float` field is a `Float` (D155).
      val _ = adoptFloatLiteralType(tbl, callArgExpr(args[ai]), argTypes[ai], fieldTy)
    }
    k = k + 1
  }
}

// The parameter types of `sig` with its generic parameters bound from the
// call: `recvTy` fills the leading receiver parameter of a method call's full
// signature, `args` the rest.  Used to find the implicit widenings of a
// generic call's arguments (`xs.add(u)` with `xs: List[ULong]`, #7805).
func recordGenericArgWidenings(
  tbl: in SymbolTable,
  sig: in ResolvedSignature,
  recvTy: in Option[Type],
  args: in List[CallArg],
  argTypes: in List[Type],
): Unit {
  if sig.generics.count == 0 {
    return
  }
  val offset = match recvTy { case Some(_) -> 1; case None -> 0 }
  if sig.params.count < offset or args.count > sig.params.count - offset {
    return
  }
  val paramNames: List[String] = newList()
  var pi = offset
  while pi < sig.params.count {
    paramNames.add(sig.params[pi].name)
    pi = pi + 1
  }
  val srcIdx = argIndicesInParamOrder(args, paramNames)
  val paramTys: List[Type] = newList()
  val slotTys: List[Type] = newList()
  match recvTy {
    case Some(rt) -> {
      paramTys.add(sig.params[0].ty)
      slotTys.add(rt)
    }
    case None -> ()
  }
  var k = 0
  while k < srcIdx.count {
    paramTys.add(sig.params[k + offset].ty)
    val ai = srcIdx[k]
    slotTys.add(if ai >= 0 and ai < argTypes.count { argTypes[ai] } else { TyError })
    k = k + 1
  }
  val targs = inferGenericArgsForSig(sig, paramTys, slotTys)
  var j = 0
  while j < srcIdx.count {
    val ai = srcIdx[j]
    val p = sig.params[j + offset]
    val isIn = match p.mode { case PMIn -> true; case _ -> false }
    if ai >= 0 and ai < argTypes.count and isIn {
      recordUnsignedWidening(tbl, substituteTyVars(p.ty, sig.generics, targs), argTypes[ai], callArgExpr(args[ai]))
      // A type parameter instantiated with an inline range type is checked
      // at the call: the generic body knows nothing of the range (#8031).
      // A parameter declared with a range is checked by the callee.
      match p.ty {
        case TyRefined(_, _, _, _, _) -> ()
        case _ -> noteRangeSlot(
          tbl,
          substituteTyVars(p.ty, sig.generics, targs),
          callArgExpr(args[ai]),
          "argument " + toString(j + 1)
        )
      }
    }
    j = j + 1
  }
}

// #7119: named-field constructor fields of a union case, for the shared
// `reportMissingCtorFields` missing-required-field check (mirrors
// `collectCtorFieldsFromRecord`/`collectCtorFieldsFromOpaque`). A union case
// field never has a default value, so `hasDefault` is always false. A
// positional (`UFPos`) field can't be supplied by name at all, so it's
// excluded here — `reportMissingCtorFields` already skips the whole check
// once any positional arg is present, and a purely-positional case called
// with all-named args (which can't actually name any real field) falls
// through its `hasUnknownName` guard instead of falsely reporting every
// positional field as "missing". `ty` is `TyError`: the check only reads
// `.name`/`.hasDefault`, so there's no need to resolve real field types
// (and no need for a `Diagnostic` scratch list / generic context) just to
// build this list.
// A union case's fields in declaration order, "" for a positional one.
func unionCaseSlotNames(uc: in UnionCase): List[String] {
  val names: List[String] = newList()
  for f in uc.fields {
    match f {
      case UFNamed(nm, _, _) -> names.add(nm)
      case UFPos(_, _) -> names.add("")
    }
  }
  names
}

func collectUnionCaseFields(uc: in UnionCase, acc: in List[CtorField]): Unit {
  var i = 0
  while i < uc.fields.count {
    match uc.fields[i] {
      case UFNamed(nm, _, _) -> acc.add(CtorField(name = nm, ty = TyError, hasDefault = false, zeroFill = false))
      case UFPos(_, _) -> {
      }
    }
    i = i + 1
  }
}

// The parent union type for a union-case symbol, instantiated with the type args
// inferred from `argTypes` (empty for a bare-name reference like `None`).
// #7119: also checks for a missing required named field, mirroring
// `inferConstruction`'s `reportMissingCtorFields` call for records/opaques —
// a union-case construction omitting a required named field from an
// all-named-args call used to reach codegen silently, the same invalid-IL
// hazard #6739 fixed for records. `checkMissingFields` must be `false` for
// the bare-callee-reference call site (a `ECall`'s callee expression is
// inferred standalone, with no args, purely as a placeholder the enclosing
// `ECall` arm then re-infers with the real args and wins per the comment
// below) — otherwise every field-having case would falsely report all of
// its fields "missing" at that zero-arg placeholder step, before the real
// call-site check ever runs.
func inferUnionCaseConstruction(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  caseSym: in Symbol,
  args: in List[CallArg],
  argTypes: in List[Type],
  span: in Span,
  checkMissingFields: in Bool,
): Type {
  match caseSym.kind {
    case DKUnionCase(parentId, uc) -> match parentUnionDeclOf(tbl, parentId) {
      case Some(decl) -> {
        if checkMissingFields {
          val prelimFields: List[CtorField] = newList()
          collectUnionCaseFields(uc, prelimFields)
          val _ = reportRepeatedCallArgs(diag, "T0104", "field", args, unionCaseSlotNames(uc))
          if reportMissingCtorFields(prelimFields, args, caseSym, span, diag) {
            return TyError
          }
          // #7752: a named argument must name one of the case's fields, as
          // for a record constructor (T0101).  `reportMissingCtorFields`
          // deliberately defers an unknown name to this per-argument check,
          // which union cases never had: `Err(err = "x")` (the field is
          // `error`) type-checked cleanly, the MSIL backend then built the
          // case positionally while the JVM backend matched the name and
          // silently stored `null`.
          var ni = 0
          while ni < args.count {
            match args[ni] {
              case CANamed(nm, _, asp) -> if not fieldHasName(prelimFields, nm) {
                diag.add(errorDiagnostic("T0101", "'" + caseSym.name + "' has no field '" + nm + "'", asp))
              }
              case CAPositional(_) -> ()
            }
            ni = ni + 1
          }
        }
        val gnames = unionDeclGenericNames(decl)
        val ftypes = unionCaseFieldTypes(tbl, diag, uc, gnames, caseSym.originPackage)
        // Named arguments bind by field name, in any order (#7844).
        val orderedArgTypes = argTypesInFieldOrder(args, argTypes, unionCaseSlotNames(uc))
        val targs = inferGenericArgs(gnames, ftypes, orderedArgTypes)
        recordCaseFieldWidenings(tbl, uc, ftypes, gnames, targs, args, argTypes)
        val caseTy = TyUser(id = parentId, name = decl.name, args = targs)
        val _ = noteValueUnionCtor(tbl, caseTy, span, false)
        caseTy
      }
      case None -> TyError
    }
    case _ -> TyError
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5c. Typed pattern binding for `match` arms (#2142).
// ─────────────────────────────────────────────────────────────────────────────
//
// Destructures the scrutinee *type* so each pattern variable gets its real type:
// `Some(ns)` on `Option[NameAndSpan]` binds `ns : NameAndSpan`.  Used by the
// `EMatch` arm so arm-body types are correct for branch unification.
// Replace generic type variables in `t`: each `TyVar(names[i])` becomes `args[i]`.
func substituteTyVars(t: in Type, names: in List[String], args: in List[Type]): Type {
  match t {
    case TyVar(nm) -> {
      var i = 0
      while i < names.count and i < args.count {
        if names[i] == nm {
          return args[i]
        }
        i = i + 1
      }
      t
    }
    case TyUser(id, name, targs) -> {
      val na: List[Type] = newList()
      var i = 0
      while i < targs.count {
        na.add(substituteTyVars(targs[i], names, args))
        i = i + 1
      }
      TyUser(id = id, name = name, args = na)
    }
    case TySlice(e) -> TySlice(element = substituteTyVars(e, names, args))
    case TyArray(sz, e, sv) -> {
      val elem = substituteTyVars(e, names, args)
      // A length that is a value generic parameter takes its argument: a
      // known length (`TyLen`) or another parameter (D169).
      match sz {
        case Some(_) -> TyArray(size = sz, element = elem, sizeVar = sv)
        case None -> match substituteTyVars(TyVar(name = sv), names, args) {
          case TyLen(n) -> TyArray(size = Some(value = n), element = elem, sizeVar = "")
          case TyVar(m) -> TyArray(size = None, element = elem, sizeVar = m)
          case _ -> TyArray(size = None, element = elem, sizeVar = sv)
        }
      }
    }
    case TyNullable(inner) -> TyNullable(inner = substituteTyVars(inner, names, args))
    case TyTuple(elems) -> {
      val ne: List[Type] = newList()
      var i = 0
      while i < elems.count {
        ne.add(substituteTyVars(elems[i], names, args))
        i = i + 1
      }
      TyTuple(elems = ne)
    }
    case TyFunction(ps, ret, isA) -> {
      val np: List[Type] = newList()
      var i = 0
      while i < ps.count {
        np.add(substituteTyVars(ps[i], names, args))
        i = i + 1
      }
      TyFunction(params = np, ret = substituteTyVars(ret, names, args), isAsync = isA)
    }
    case _ -> t
  }
}

// Deep generic-argument inference (#1488 category B): structurally match a
// parameter type against an argument type to find the concrete binding for the
// generic `name`.  `Option[T]` vs `Option[Int]` binds `T = Int`; `slice[T]` vs
// `slice[String]` binds `T = String`; a bare `T` vs `Int` binds directly.
// Returns the first binding found (depth-first), or `None` when `name` does not
// occur in `paramTy` or the shapes don't align.
func findGenericInPair(name: in String, paramTy: in Type, argTy: in Type): Option[Type] {
  match paramTy {
    case TyVar(nm) -> if nm == name { Some(value = argTy) } else { None }
    case TyUser(pid, _, pargs) -> {
      // Guard by SymbolId to avoid cross-constructor inference (e.g. Result vs Option).
      val aargs = match unrefine(argTy) {
        case TyUser(aid, _, a) -> if symbolIdEq(pid, aid) { a } else { newList() }
        case _ -> newList()
      }
      findGenericInPairs(name, pargs, aargs)
    }
    case TySlice(pe) -> match unrefine(argTy) { case TySlice(ae) -> findGenericInPair(name, pe, ae); case _ -> None }
    case TyArray(_, pe, psv) -> match unrefine(argTy) {
      // A length that is the value generic parameter `name` binds to the
      // argument's length (D169).
      case TyArray(asz, ae, asv) -> if psv == name {
        match asz {
          case Some(n) -> Some(value = TyLen(n = n))
          case None -> if asv.length > 0 { Some(value = TyVar(name = asv)) } else { None }
        }
      } else {
        findGenericInPair(name, pe, ae)
      }
      // A bracket literal (`Box(data = [1, 2])`) is typed as a slice; its
      // element type binds the array's (#8042).  Whether it fits the array
      // is checked against the instantiated field.
      case TySlice(ae) -> findGenericInPair(name, pe, ae)
      case _ -> None
    }
    case TyNullable(pi) -> match unrefine(argTy) {
      case TyNullable(ai) -> findGenericInPair(name, pi, ai)
      case _ -> None
    }
    case TyTuple(pes) -> {
      val aes = match unrefine(argTy) { case TyTuple(a) -> a; case _ -> newList() }
      findGenericInPairs(name, pes, aes)
    }
    case TyFunction(pps, pr, _) -> match unrefine(argTy) {
      case TyFunction(aps, ar, _) -> match findGenericInPairs(name, pps, aps) {
        case Some(v) -> Some(value = v)
        case None -> findGenericInPair(name, pr, ar)
      }
      case _ -> None
    }
    case _ -> None
  }
}

// Find `name`'s binding across positionally-paired parameter / argument type
// lists, returning the first match.
func findGenericInPairs(name: in String, paramTys: in List[Type], argTys: in List[Type]): Option[Type] {
  var i = 0
  while i < paramTys.count and i < argTys.count {
    match findGenericInPair(name, paramTys[i], argTys[i]) {
      case Some(v) -> return Some(value = v)
      case None -> {
      }
    }
    i = i + 1
  }
  None
}

// For each generic `name`, its inferred concrete type from the call's
// parameter / argument types (or `TyError` when it can't be inferred — kept
// lenient so an unconstrained generic return stays a wildcard rather than a
// spurious mismatch).  When a name occurs in more than one parameter position
// (`pair(a: T, b: T): T`) the occurrences must agree: a second binding that is
// not `typeEquiv` to the first yields `TyError` for that name (#2228), so an
// inconsistent call (already a T0043 at the argument check) doesn't produce a
// misleading concrete return type.  An argument that leaves the name open
// (`None` for an `Option[T]` parameter) does not hide what a later argument
// fixes (#7844): `f(None, 5)` with `f[T](a: Option[T], b: T)` binds `T` to
// `Int`, not to the hole.
func inferGenericArgsDeep(names: in List[String], paramTys: in List[Type], argTys: in List[Type]): List[Type] {
  val result: List[Type] = newList()
  var g = 0
  while g < names.count {
    result.add(inferOneGenericArg(names[g], paramTys, argTys))
    g = g + 1
  }
  result
}

// Infer the binding for a single generic `name` across all parameter/argument
// pairs, returning `TyError` when unbound or when two occurrences disagree.
func inferOneGenericArg(name: in String, paramTys: in List[Type], argTys: in List[Type]): Type {
  var bound: Type = TyError
  var haveBinding = false
  // Whether every occurrence behind `bound` is a bare `T` parameter, whose
  // argument widens at the call like any numeric argument.
  var boundBare = true
  var i = 0
  while i < paramTys.count and i < argTys.count {
    match findGenericInPair(name, paramTys[i], argTys[i]) {
      case Some(v) -> {
        val bare = isBareTyVar(paramTys[i], name)
        if not haveBinding {
          bound = v
          haveBinding = true
          boundBare = bare
        } else if not typeEquiv(bound, v) {
          // Numeric widening (D-progress-969): `collect(r, 0)` with `r:
          // Result[Long, E]` binds `T` to `Long`, the `Int` literal widening
          // at its bare `fallback: T` parameter.
          match widenArithmetic(bound, v) {
            case Some(w) -> if typeEquiv(w, bound) and bare {
              ()
            } else if typeEquiv(w, v) and boundBare {
              bound = v
              boundBare = bare
            } else {
              return TyError
            }
            case None -> return TyError
          }
        } else if typeIsHole(bound) {
          // An argument that left the parameter open (`None` for an
          // `Option[T]` parameter) bound nothing; a later one fixes it
          // (#7844): `Holder(value = None, fallback = 5)` binds `T` to `Int`.
          bound = v
          boundBare = bare
        } else {
          // A partly open binding (`Option[<hole>]`) takes what a later
          // occurrence fixes inside it.
          bound = joinOpenTypes(bound, v)
          boundBare = boundBare and bare
        }
      }
      case None -> {
      }
    }
    i = i + 1
  }
  bound
}

// `inferGenericArgsDeep` for a call to `sig`, where a bare `T` parameter an
// `out`/`inout` parameter declares is bound by its argument's type alone: the
// parameter refers to the caller's place (D183), so `T` is the place's type,
// and an argument that adapts to it (an integer literal) never widens it
// (`takeList(b, 3)` with `b: Byte` is `List[Byte]`, #8238).
func inferGenericArgsForSig(sig: in ResolvedSignature, paramTys: in List[Type], argTys: in List[Type]): List[Type] {
  val targs = inferGenericArgsDeep(sig.generics, paramTys, argTys)
  var g = 0
  while g < sig.generics.count {
    var pi = 0
    var pinned = false
    while pi < sig.params.count and pi < argTys.count and pi < paramTys.count and not pinned {
      val byRef = match sig.params[pi].mode { case PMIn -> false; case _ -> true }
      if byRef and isBareTyVar(paramTys[pi], sig.generics[g]) and not typeIsHole(argTys[pi]) {
        targs[g] = argTys[pi]
        pinned = true
      }
      pi = pi + 1
    }
    g = g + 1
  }
  targs
}

func typeIsHole(t: in Type): Bool {
  match t {
    case TyError -> true
    case _ -> false
  }
}

func isBareTyVar(t: in Type, name: in String): Bool {
  match t {
    case TyVar(n) -> n == name
    case _ -> false
  }
}

// A generic function's return type instantiated from the call's argument types:
// `unwrapOr(o: Option[T], default: T): T` called with an `Option[Int]` / `Int`
// pair yields `Int` instead of the raw `TyVar("T")` (#1488 category B).  A
// non-generic sig is returned unchanged.  `argTypes` are the types of the
// call's `skip` leading receiver arguments followed by those of `args`, in
// source order; each is paired with its parameter as the call pairs them
// (D171), so a named argument written out of order binds the type parameter
// of the parameter it names (#8240).
func instantiateReturnType(
  sig: in ResolvedSignature, skip: in Int, args: in List[CallArg], argTypes: in List[Type]
): Type {
  if sig.generics.count == 0 {
    return sig.returnTy
  }
  val paramTys: List[Type] = newList()
  var i = 0
  while i < sig.params.count {
    paramTys.add(sig.params[i].ty)
    i = i + 1
  }
  val targs = inferGenericArgsForSig(sig, paramTys, argTypesInSigOrder(sig, skip, args, argTypes))
  substituteTyVars(sig.returnTy, sig.generics, targs)
}

// `argTypes` (the types of `skip` leading receiver arguments, then of `args`
// in source order) rearranged into the order of `sig`'s parameters: each
// named argument's type at the parameter it names, the positional ones in
// the remaining slots left to right, and `TyError`, which binds nothing, for
// a parameter the call leaves to its default (#8240).
func argTypesInSigOrder(
  sig: in ResolvedSignature, skip: in Int, args: in List[CallArg], argTypes: in List[Type]
): List[Type] {
  if not callArgsHaveNamed(args) or skip > sig.params.count or skip > argTypes.count {
    return argTypes
  }
  val ordered: List[Type] = newList()
  val names: List[String] = newList()
  val rest: List[Type] = newList()
  var i = 0
  while i < argTypes.count {
    if i < skip {
      ordered.add(argTypes[i])
    } else {
      rest.add(argTypes[i])
    }
    i = i + 1
  }
  var p = skip
  while p < sig.params.count {
    names.add(sig.params[p].name)
    p = p + 1
  }
  for t in argTypesInFieldOrder(args, rest, names) {
    ordered.add(t)
  }
  ordered
}

// H15: verify that concrete type arguments inferred for a generic call site
// satisfy every `where T: Constraint` bound declared on `sig`.  Called from
// `ECall` after a signature is selected.  `TyError`/`TyVar` args pass
// silently (the lenient unifier, or still-abstract).
func checkBoundsSatisfied(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sig: in ResolvedSignature,
  args: in List[CallArg],
  argTypes: in List[Type],
  span: in Span,
): Unit {
  if sig.bounds.count == 0 or sig.generics.count == 0 {
    return
  }
  val paramTys: List[Type] = newList()
  var pi = 0
  while pi < sig.params.count {
    paramTys.add(sig.params[pi].ty)
    pi = pi + 1
  }
  val targs = inferGenericArgsForSig(sig, paramTys, argTypesInSigOrder(sig, 0, args, argTypes))
  var bi = 0
  while bi < sig.bounds.count {
    val bound = sig.bounds[bi]
    var idx = -1
    var gi = 0
    while gi < sig.generics.count {
      if sig.generics[gi] == bound.name {
        idx = gi
      }
      gi = gi + 1
    }
    if idx >= 0 and idx < targs.count {
      val concreteTy = targs[idx]
      match concreteTy {
        case TyError -> {
        }
        case TyVar(_) -> {
        }
        case _ -> {
          var ci = 0
          while ci < bound.constraints.count {
            val cname = bound.constraints[ci]
            var satisfied = false
            var why = ""
            if isPlainMarker(cname) {
              match plainViolation(tbl, concreteTy) {
                case None -> {
                  satisfied = true
                }
                case Some(reason) -> {
                  why = ": " + reason
                }
              }
            } else if isKnownDeriveMarker(cname) {
              satisfied = hasDerive(tbl, cname, concreteTy)
            } else {
              match constraintInterfaceSym(tbl, cname) {
                case Some(ifaceSym) -> match ifaceSym.kind {
                  case DKInterface(ifaceId, _) -> match typeIdOfType(concreteTy) {
                    case Some(concreteId) -> {
                      satisfied = symTableTypeImplements(tbl, concreteId, ifaceId)
                    }
                    case None -> {
                      satisfied = true
                    }
                  }
                  case _ -> {
                    satisfied = true
                  }
                }
                case None -> {
                  // Unknown constraint names are treated as satisfied to preserve
                  // cross-package leniency, but emit T0111 so typos are visible.
                  diag.add(
                    warningDiagnostic(
                      "T0111",
                      "unknown constraint '" + cname + "' in where-clause for type parameter '" + bound.name +
                        "' — treating as satisfied (cross-package interface or typo?)",
                      span
                    )
                  )
                  satisfied = true
                }
              }
            }
            if not satisfied {
              diag.add(
                errorDiagnostic(
                  "T0108",
                  "type argument " + renderType(concreteTy) + " does not satisfy constraint '" + cname + "' for type parameter '" +
                    bound.name +
                    "'" +
                    why,
                  span
                )
              )
            }
            ci = ci + 1
          }
        }
      }
    }
    bi = bi + 1
  }
}

// The union case's field types *instantiated* against the scrutinee's type args:
// `Some` (`value: T`) on `Option[NameAndSpan]` → `[NameAndSpan]`.
func caseFieldTypesInstantiated(
  tbl: in SymbolTable, diag: in List[Diagnostic], caseSym: in Symbol, scrutTy: in Type
): List[Type] {
  match caseSym.kind {
    case DKUnionCase(parentId, uc) -> match parentUnionDeclOf(tbl, parentId) {
      case Some(decl) -> {
        val gnames = unionDeclGenericNames(decl)
        val ftypes = unionCaseFieldTypes(tbl, diag, uc, gnames, caseSym.originPackage)
        val targs = match unrefine(scrutTy) { case TyUser(_, _, a) -> a; case _ -> newList() }
        val result: List[Type] = newList()
        var i = 0
        while i < ftypes.count {
          result.add(substituteTyVars(ftypes[i], gnames, targs))
          i = i + 1
        }
        result
      }
      case None -> newList()
    }
    case _ -> newList()
  }
}

// Bind a pattern's variables to their *destructured* types from the scrutinee
// type `ty`.  Constructor / tuple sub-patterns recurse with the instantiated
// field / element types; record-pattern fields and unresolved positions bind
// leniently (`TyError`) so an arm body never emits a false unknown-name error.
// A bare uppercase pattern like `case None` / `case Red` parses as a
// `PBinding`, but if the name resolves to a nullary union/enum *case* it is a
// constructor pattern, not a fresh variable — it must NOT bind a local (which
// would shadow the constructor in the arm body, e.g. `case None -> None`).
// Whether the scrutinee's own union or enum declares a case `name`.  A bare
// case pattern resolves against the scrutinee's type whatever the file's
// imports make visible (docs/01 §9.2): matching a value of an aliased
// package's enum still writes `case Dotnet ->`, never a fresh binding.
func scrutineeHasCaseNamed(tbl: in SymbolTable, ty: in Type, name: in String): Bool {
  match unrefine(ty) {
    case TyUser(sid, _, _) -> {
      val cands = symTableTryFindAll(tbl, name)
      var i = 0
      while i < cands.count {
        val parent = match cands[i].kind {
          case DKUnionCase(pid, _) -> Some(value = pid)
          case DKEnumCase(pid, _) -> Some(value = pid)
          case _ -> None
        }
        match parent {
          case Some(pid) -> if symbolIdEq(pid, sid) { return true }
          case None -> ()
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

func isConstructorPatternName(tbl: in SymbolTable, name: in String): Bool {
  match symTableTryFindOne(tbl, name) {
    case Some(sym) -> match sym.kind { case DKUnionCase(_, _) -> true; case DKEnumCase(_, _) -> true; case _ -> false }
    case None -> false
  }
}

// True when an expression is a compile-time constant literal: a direct literal,
// a paren-wrapped literal, or a negated numeric literal.  Used to validate
// PConstRef patterns (T0069).
func isLiteralInit(e: in Expr): Bool {
  match e.kind {
    case ELiteral(_) -> true
    case EParen(inner) -> isLiteralInit(inner)
    case EPrefix(op, operand) -> match op {
      case PreNeg -> match operand.kind { case ELiteral(_) -> true; case _ -> false }
      case _ -> false
    }
    case _ -> false
  }
}

// Validate PConstRef patterns inside a match arm against the scrutinee type.
// Emits T0068 (type mismatch), T0069 (non-constant val), T0071 (generic type),
// or T0072 (name not a val/const).  Recurses into POr/PParen/PTypeTest
// sub-patterns.  Pure diagnostics — does not modify the AST.
func checkConstRefPattern(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  pat: in Pattern,
  scrutineeTy: in Type,
): Unit {
  match pat.kind {
    case PConstRef(name) -> {
      // #6287: a const pattern `@Ident` ambiguous across imported packages
      // must be qualified rather than silently binding to whichever
      // same-named const/val was registered last.
      if checkBareNameAmbiguity(tbl, diag, name, pat.span) {
        return
      }
      match symTableTryFindOne(tbl, name) {
        case None -> {
          diag.add(errorDiagnostic("T0072", "'" + name + "' is not defined; use a val or const for a const pattern", pat.span))
        }
        case Some(sym) -> {
          match sym.kind {
            case DKConst(cd) -> {
              val ctx = newGenericContext()
              val constTy = resolveType(tbl, ctx, diag, cd.ty)
              match constTy {
                case TyVar(_) -> {
                  diag.add(
                    errorDiagnostic(
                      "T0071",
                      "const pattern '" + name + "' has a generic type; const patterns must be monomorphic",
                      pat.span
                    )
                  )
                }
                case _ -> {
                  if not typeEquiv(constTy, scrutineeTy) {
                    diag.add(
                      errorDiagnostic(
                        "T0068",
                        "const pattern type " + renderType(constTy) + " does not match scrutinee type " + renderType(scrutineeTy),
                        pat.span
                      )
                    )
                  }
                }
              }
            }
            case DKVal(vd) -> {
              if not isLiteralInit(vd.init) {
                diag.add(
                  errorDiagnostic(
                    "T0069",
                    "const pattern '@" + name + "' requires a compile-time constant val; '" + name +
                      "' is not initialized with a literal",
                    pat.span
                  )
                )
              } else {
                val ctx = newGenericContext()
                val valTy = match vd.ty {
                  case Some(te) -> resolveType(tbl, ctx, diag, te)
                  case None -> {
                    val noRte: Option[TypeExpr] = None
                    val noSelfFields: Map[String, Type] = newMap()
                    val emptyScope = newScopeForFunction(TyError, newList(), noRte, noSelfFields, false, TyError)
                    // Its errors are the declaration's to report (#7777).
                    val readDiag: List[Diagnostic] = newList()
                    inferExpr(emptyScope, tbl, sigs, readDiag, vd.init)
                  }
                }
                match valTy {
                  case TyVar(_) -> {
                    diag.add(
                      errorDiagnostic(
                        "T0071",
                        "const pattern '" + name + "' has a generic type; const patterns must be monomorphic",
                        pat.span
                      )
                    )
                  }
                  case _ -> {
                    if not typeEquiv(valTy, scrutineeTy) {
                      diag.add(
                        errorDiagnostic(
                          "T0068",
                          "const pattern type " + renderType(valTy) + " does not match scrutinee type " + renderType(scrutineeTy),
                          pat.span
                        )
                      )
                    }
                  }
                }
              }
            }
            case _ -> {
              diag.add(
                errorDiagnostic(
                  "T0072",
                  "'" + name + "' is not a val or const; use a variable pattern or const reference",
                  pat.span
                )
              )
            }
          }
        }
      }
    }
    case POr(patterns) -> {
      var i = 0
      while i < patterns.count {
        checkConstRefPattern(tbl, sigs, diag, patterns[i], scrutineeTy)
        i = i + 1
      }
    }
    case PParen(inner) -> checkConstRefPattern(tbl, sigs, diag, inner, scrutineeTy)
    case PTypeTest(inner, tyExpr) -> {
      val ctx = newGenericContext()
      val testTy = resolveType(tbl, ctx, diag, tyExpr)
      checkConstRefPattern(tbl, sigs, diag, inner, testTy)
    }
    case PConstructor(head, args) -> {
      // #6540: EMatch runs `bindPatternTyped` AND `checkConstRefPattern`
      // unconditionally on the same pattern (see the EMatch arm loop) — both
      // need `unionCaseSymbolForScrutinee`'s field types to recurse
      // correctly, but only ONE call should own the qualifier-mismatch
      // diagnostic it may emit (#6287 Phase B / T0122), or a mismatched
      // qualifier reports twice.  `bindPatternTyped`'s call is the owner;
      // this one passes a throwaway scratch list so the SAME resolution
      // runs (field types are identical either way) without a second
      // T0122 for the same source span.
      val scratchDiag: List[Diagnostic] = newList()
      val ftypes = match unionCaseSymbolForScrutinee(tbl, scratchDiag, pat2fnExpr(head, pat.span), scrutineeTy) {
        case Some(caseSym) -> caseFieldTypesInstantiated(tbl, diag, caseSym, scrutineeTy)
        case None -> newList()
      }
      var i = 0
      while i < args.count {
        val at = if i < ftypes.count { ftypes[i] } else { TyError }
        checkConstRefPattern(tbl, sigs, diag, args[i], at)
        i = i + 1
      }
    }
    case PTuple(patterns) -> {
      val elems = match unrefine(scrutineeTy) { case TyTuple(es) -> es; case _ -> newList() }
      var i = 0
      while i < patterns.count {
        val et = if i < elems.count { elems[i] } else { TyError }
        checkConstRefPattern(tbl, sigs, diag, patterns[i], et)
        i = i + 1
      }
    }
    case PRecord(_, fields, _) -> {
      // #7584: unlike `PConstructor`'s `unionCaseSymbolForScrutinee` call
      // (which resolves the field TYPES this arm needs), `checkRecordPatternHead`
      // has no effect on field resolution here — `recFields` below is
      // resolved purely from `scrutineeTy`, independent of the head — so
      // there is nothing to gain calling it a second time.
      // `bindPatternTyped`'s call is the sole owner of this pattern's
      // T0137/T0097/T0020 diagnostics.
      val recFields: List[FieldEntry] = match unrefine(scrutineeTy) {
        case TyUser(tid, _, targs) -> fieldsOfRecordInstantiated(tbl, tid, targs)
        case _ -> newList()
      }
      var i = 0
      while i < fields.count {
        match fields[i] {
          case RPFNamed(fname, p, _) -> checkConstRefPattern(tbl, sigs, diag, p, fieldEntryType(recFields, fname))
          case RPFShort(_, _) -> {
          }
        }
        i = i + 1
      }
    }
    case _ -> {
    }
  }
}

// Replace unresolved generic type variables with `TyError` (the lenient
// unifier).  A pattern variable bound to a still-generic type (e.g. `v` from
// `Some(v)` on `Option[V]` inside a generic function) must not later trip a
// false "not numeric" / type-mismatch — the type checker does not track the
// `where V: Add`-style bounds that make such uses valid.
func eraseTyVars(t: in Type): Type {
  match t {
    case TyVar(_) -> TyError
    case TyUser(id, name, targs) -> {
      val na: List[Type] = newList()
      var i = 0
      while i < targs.count {
        na.add(eraseTyVars(targs[i]))
        i = i + 1
      }
      TyUser(id = id, name = name, args = na)
    }
    case TySlice(e) -> TySlice(element = eraseTyVars(e))
    case TyArray(sz, e, sv) -> TyArray(size = sz, element = eraseTyVars(e), sizeVar = sv)
    case TyNullable(inner) -> TyNullable(inner = eraseTyVars(inner))
    case TyTuple(elems) -> {
      val ne: List[Type] = newList()
      var i = 0
      while i < elems.count {
        ne.add(eraseTyVars(elems[i]))
        i = i + 1
      }
      TyTuple(elems = ne)
    }
    case TyFunction(ps, ret, isA) -> {
      val np: List[Type] = newList()
      var i = 0
      while i < ps.count {
        np.add(eraseTyVars(ps[i]))
        i = i + 1
      }
      TyFunction(params = np, ret = eraseTyVars(ret), isAsync = isA)
    }
    case _ -> t
  }
}

// Bind the names `pat` introduces, each at its type within `ty`.
// `bindingOnly`: `pat` is (part of) a `val` or `for` pattern, which always
// binds its names; only a `match` arm's bare name can be a nullary case
// (recorded in `casePatternSites`, #8264).
func bindPatternTyped(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  pat: in Pattern,
  ty: in Type,
  bindingOnly: in Bool = false,
): Unit {
  match pat.kind {
    case PBinding(name, inner) -> {
      // The language has no `null` literal or null pattern (docs/01 §FFI,
      // D107) — the lexer treats `null` as an ordinary identifier, so
      // `case null -> ...` parses as an ordinary catch-all binding named
      // `null`, not a null test.  As the first arm (every real usage) it
      // silently matches EVERY value, null or not — a silent stdlib
      // miscompile with no diagnostic (#4775).  Reject it explicitly rather
      // than let it bind like any other identifier.
      if name == "null" {
        diag.add(
          errorDiagnostic(
            "T0073",
            "'null' has no meaning as a pattern — Lyric has no null literal or null pattern (see docs/01 §FFI); this binds a local named 'null' and matches every value",
            pat.span
          )
        )
      }
      if name != "_" {
        if not bindingOnly and (isConstructorPatternName(tbl, name) or scrutineeHasCaseNamed(tbl, ty, name)) {
          // #6287: a bare nullary-case pattern (`case Halt ->`, no parens)
          // ambiguous across imported packages must be qualified — UNLESS
          // the scrutinee is a known concrete type (`TyUser`).  Matching
          // against a resolved union/enum type already gives the reader
          // (and the rest of the type checker) the disambiguating context a
          // `PConstructor` pattern gets from `unionCaseSymbolForScrutinee`;
          // only an unresolved (`TyError`) scrutinee leaves a bare nullary
          // name genuinely ambiguous.
          val scrutineeIsKnown = match unrefine(ty) { case TyUser(_, _, _) -> true; case _ -> false }
          if not scrutineeIsKnown {
            val _ = checkBareNameAmbiguity(tbl, diag, name, pat.span)
          }
          checkBareCasePatternScrutinee(tbl, diag, name, ty, pat.span)
          recordCasePatternSite(tbl, pat.span)
          if scrutineeHasCaseNamed(tbl, ty, name) {
            recordCasePatternUnion(tbl, pat.span, ty)
            recordEnumCasePattern(tbl, pat.span, ty)
          }
        } else {
          scopeAdd(sc, LocalBinding(name = name, ty = eraseTyVars(ty), isMutable = false))
        }
      }
      match inner {
        case None -> {
        }
        case Some(p) -> bindPatternTyped(sc, tbl, sigs, diag, p, ty, bindingOnly)
      }
    }
    case PWildcard -> {
    }
    case PLiteral(lit) -> recordUnsignedLiteralPattern(tbl, diag, pat, lit, ty)
    case PConstructor(head, args) -> {
      val ftypes = match unionCaseSymbolForScrutinee(tbl, diag, pat2fnExpr(head, pat.span), ty) {
        case Some(caseSym) -> {
          if checkCasePatternScrutinee(tbl, diag, caseSym, ty, pat.span) {
            recordCasePatternUnion(tbl, pat.span, ty)
            caseFieldTypesInstantiated(tbl, diag, caseSym, ty)
          } else {
            newList()
          }
        }
        case None -> newList()
      }
      var i = 0
      while i < args.count {
        val at = if i < ftypes.count { ftypes[i] } else { TyError }
        bindPatternTyped(sc, tbl, sigs, diag, args[i], at, bindingOnly)
        i = i + 1
      }
    }
    case PTuple(patterns) -> {
      val elems = match unrefine(ty) { case TyTuple(es) -> es; case _ -> newList() }
      if not bindingOnly {
        match unrefine(ty) {
          case TyTuple(es) -> if es.count != patterns.count {
            diag.add(
              errorDiagnostic(
                "T0198",
                "a " + toString(patterns.count) + "-element tuple pattern cannot match a value of type " + renderType(ty) + ", a " +
                  toString(es.count) +
                  "-element tuple",
                pat.span
              )
            )
          }
          case t -> if not localValShapeUnknown(t) {
            diag.add(
              errorDiagnostic(
                "T0198",
                "a " + toString(patterns.count) + "-element tuple pattern cannot match a value of type " + renderType(ty) +
                  ", which is not a tuple",
                pat.span
              )
            )
          }
        }
      }
      var i = 0
      while i < patterns.count {
        val et = if i < elems.count { elems[i] } else { TyError }
        bindPatternTyped(sc, tbl, sigs, diag, patterns[i], et, bindingOnly)
        i = i + 1
      }
    }
    case PRecord(head, fields, _) -> {
      // #7584: validate the head before resolving fields — the owning call
      // for this pattern's T0137/T0097/T0020 diagnostics (mirrors
      // `PConstructor`'s `unionCaseSymbolForScrutinee` call being the
      // "owner" per the #6540 comment on `checkConstRefPattern`'s own
      // `PConstructor` arm below).
      checkRecordPatternHead(tbl, diag, head, pat.span, ty)
      // Resolve the record's declared field types from the scrutinee type so a
      // bound field carries its real type (e.g. `Point{x = a}` types `a` as
      // `Int`) rather than `TyError`.
      val recFields: List[FieldEntry] = match unrefine(ty) {
        case TyUser(tid, _, targs) -> fieldsOfRecordInstantiated(tbl, tid, targs)
        case _ -> newList()
      }
      var i = 0
      while i < fields.count {
        match fields[i] {
          case RPFNamed(fname, p, _) -> bindPatternTyped(
            sc,
            tbl,
            sigs,
            diag,
            p,
            fieldEntryType(recFields, fname),
            bindingOnly
          )
          case RPFShort(nm, _) -> scopeAdd(sc, LocalBinding(name = nm, ty = fieldEntryType(recFields, nm), isMutable = false))
        }
        i = i + 1
      }
    }
    case POr(patterns) -> {
      // All alternatives bind the same names by language rule; the first binds
      // them.  The others are walked in a scope of their own, their
      // diagnostics discarded, only so the case patterns they hold record the
      // union they match (`recordCasePatternUnion`).
      if patterns.count > 0 {
        bindPatternTyped(sc, tbl, sigs, diag, patterns[0], ty, bindingOnly)
      }
      var oi = 1
      while oi < patterns.count {
        val altDiag: List[Diagnostic] = newList()
        scopePush(sc)
        bindPatternTyped(sc, tbl, sigs, altDiag, patterns[oi], ty, bindingOnly)
        scopePop(sc)
        oi = oi + 1
      }
    }
    case PParen(inner) -> {
      bindPatternTyped(sc, tbl, sigs, diag, inner, ty, bindingOnly)
    }
    case PTypeTest(inner, tyExpr) -> {
      // `case x is T ->` narrows the scrutinee to `T`, so the inner pattern (and
      // any binding it introduces) is typed at `T` — letting `x.field` resolve
      // against the tested type rather than the wider scrutinee type.
      val ctx = newGenericContext()
      val testTy = resolveType(tbl, ctx, diag, tyExpr)
      bindPatternTyped(sc, tbl, sigs, diag, inner, testTy, bindingOnly)
    }
    case PRange(lo, _, hi, _) -> {
      if isUnsignedPatternScrutinee(ty) {
        checkUnsignedRangeBound(sc, tbl, sigs, diag, lo, ty)
        checkUnsignedRangeBound(sc, tbl, sigs, diag, hi, ty)
      }
    }
    case PConstRef(_) -> {
    }
    case _ -> {
    }
  }
}

// A `Byte`, `UInt` or `ULong` scrutinee: its literal and range patterns are
// typed against it (#7842).
func isUnsignedPatternScrutinee(ty: in Type): Bool {
  match unsignedLiteralSuffix(ty) {
    case Some(_) -> true
    case None -> false
  }
}

// A literal pattern against a `Byte`, `UInt` or `ULong` scrutinee (#7842).
// An unsuffixed literal takes the scrutinee's type, recorded so
// `Lyric.Mono` gives it the matching suffix: every backend compares the
// constant at that width and representation (a `UInt` above 2^31 is a
// 32-bit pattern, not a `Long`).  A literal the type cannot hold could never
// match, so it is T0015.
func recordUnsignedLiteralPattern(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  pat: in Pattern,
  lit: in Literal,
  ty: in Type,
): Unit {
  match lit {
    case LInt(v, sfx, _) -> match sfx {
      case NoIntSuffix -> match unsignedLiteralSuffix(ty) {
        case Some(usfx) -> {
          if intValueFitsType(v, ty) {
            val key = recordCopySiteKey(pat.span)
            if not tbl.argConversionSites.containsKey(key) {
              tbl.argConversionSites.add(
                key,
                ArgConversionSite(method = intLiteralSiteMethod(usfx), startOffset = pat.span.startPos.offset)
              )
            }
          } else {
            diag.add(errorDiagnostic("T0015", "literal " + toString(v) + " is out of range for type " + renderType(ty), pat.span))
          }
        }
        case None -> ()
      }
      case _ -> ()
    }
    case _ -> ()
  }
}

// A range-pattern bound against a `Byte`, `UInt` or `ULong` scrutinee
// (#7842): typed against the scrutinee like an initialiser, so an
// unsuffixed literal takes its suffix (T0015 when it does not fit), and a
// `UInt`/`ULong` bound of any other shape is recorded as an unsigned operand.
// Each backend's range test then compares unsigned when a bound says so.
func checkUnsignedRangeBound(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  bound: in Expr,
  ty: in Type,
): Unit {
  val bt = inferExprExpected(sc, tbl, sigs, diag, bound, ty)
  if reportIntLiteralOutOfRange(unrefine(ty), bound, diag) {
    return
  }
  recordUnsignedOperand(tbl, bt, bound)
}

// Wrap a constructor head `ModulePath` as an `EPath` expression so the existing
// `unionCaseSymbolOf` (which takes an `Expr`) can resolve the case symbol.
func pat2fnExpr(head: in ModulePath, span: in Span): Expr {
  Expr(kind = EPath(path = head), span = span)
}

// #3362: extracted from `inferExpr`'s `EIf` case so `checkBlock` can also
// invoke it directly for a statement-position `if` (`SExpr` case), passing
// the enclosing block's actual value-position instead of the `inferExpr`
// dispatch's implicit "always value position" default.
// #7696: `tailExpected` — see `inferExprOrBlock`'s header comment — is the
// declared return type to type a branch's bracket literal against when this
// `if` is genuinely the function's tail value, or `TyError` otherwise.
func inferIfExpr(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
  cond: in Expr,
  thenBranch: in ExprOrBlock,
  elseBranch: in Option[ExprOrBlock],
  isValuePosition: in Bool,
  tailExpected: in Type,
): Type {
  val condT = inferExpr(sc, tbl, sigs, diag, cond)
  resolvePropagateOperand(sc, tbl, cond, TyPrim(pt = PtBool))
  match condT {
    case TyError -> {
    }
    case TyPrim(pt) -> match pt {
      case PtBool -> {
      }
      case PtNever -> {
      }
      case _ -> diag.add(
        errorDiagnostic(
          "T0066",
          "if-condition must be Bool (got " + renderType(condT) + ")",
          cond.span
        )
      )
    }
    case _ -> diag.add(errorDiagnostic("T0066", "if-condition must be Bool (got " + renderType(condT) + ")", cond.span))
  }
  // An else-less `if` always yields `Unit` regardless of what the
  // then-branch itself produces, so the then-branch's own value is
  // discarded here even when the whole `if` is used in value position —
  // type it accordingly (statement position), or a discarded branch
  // mismatch spuriously fires T0067 one level down (#6730).
  val thenIsValuePosition = isValuePosition and (match elseBranch { case Some(_) -> true; case None -> false })
  val tt = inferExprOrBlock(sc, tbl, sigs, diag, thenBranch, thenIsValuePosition, tailExpected)
  match elseBranch {
    case None -> TyPrim(pt = PtUnit)
    case Some(eb) -> {
      val et = inferExprOrBlock(sc, tbl, sigs, diag, eb, isValuePosition, tailExpected)
      // #7752: a consumed `if` in a position with a known expected type is
      // checked against that type branch by branch; only without one (or
      // when a branch does not fit it) do the branches join bottom-up.
      if isValuePosition {
        val bts: List[Type] = newList()
        bts.add(tt)
        bts.add(et)
        match branchesAgainstExpected(tbl, bts, tailExpected) {
          case Some(t) -> {
            recordBranchWidening(tbl, t, tt, thenBranch)
            recordBranchWidening(tbl, t, et, eb)
            return t
          }
          case None -> ()
        }
      }
      val joined = unifyBranchTypes(tt, et, e.span, diag, isValuePosition)
      closePropagateBranch(sc, tbl, thenBranch, joined, isValuePosition)
      closePropagateBranch(sc, tbl, eb, joined, isValuePosition)
      recordBranchConstructionType(sc, tbl, thenBranch, tt, joined, isValuePosition)
      recordBranchConstructionType(sc, tbl, eb, et, joined, isValuePosition)
      joined
    }
  }
}

// The expression a branch or block produces its value from: the branch
// expression itself, or a block's trailing expression statement.
pub func blockValueExpr(blk: in Block): Option[Expr] {
  if blk.statements.count == 0 {
    return None
  }
  match blk.statements[blk.statements.count - 1].kind {
    case SExpr(e) -> Some(value = e)
    case _ -> None
  }
}

func branchValueExpr(b: in ExprOrBlock): Option[Expr] {
  match b {
    case EOBExpr(e) -> Some(value = e)
    case EOBBlock(blk) -> blockValueExpr(blk)
  }
}

// A branch of type `bt` accepted where the `if`/`match` expects `target`
// (`branchesAgainstExpected`) is widened at its value expression: the
// branches of one construct otherwise leave values of different widths
// (#7805).
func recordBranchWidening(tbl: in SymbolTable, target: in Type, bt: in Type, b: in ExprOrBlock): Unit {
  match branchValueExpr(b) {
    case Some(ve) -> recordWideningSite(tbl, target, bt, ve, false)
    case None -> ()
  }
}

// #3362: extracted from `inferExpr`'s `EMatch` case for the same reason as
// `inferIfExpr` above — `checkBlock` needs to pass the real value-position
// for a statement-position `match`.
// #7696: `tailExpected` — see `inferExprOrBlock`'s header comment.
func inferMatchExpr(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
  scrutinee: in Expr,
  arms: in List[MatchArm],
  isValuePosition: in Bool,
  tailExpected: in Type,
): Type {
  val st = inferExpr(sc, tbl, sigs, diag, scrutinee)
  checkMatchExhaustive(tbl, diag, st, arms, e.span)
  checkUnreachableArms(tbl, diag, st, arms)
  checkOpaquePatternHiding(tbl, diag, st, arms)
  // Branch-type unification (#2142): a `match` used as a value takes the
  // unified type of its arm bodies.  Each arm is checked in a fresh scope
  // with its pattern variables bound to their destructured types
  // (`bindPatternTyped` — `Some(ns)` on `Option[T]` binds `ns : T`), then the
  // bodies fold through `unifyBranchTypes` (Never/TyError absorbed;
  // Unit absorbed only in statement position, #3362; T0067 on a genuine
  // value mismatch).  Guards are inferred for diagnostics but do not
  // contribute to the branch type.
  // #7752: every arm's type is collected first so a consumed `match` in a
  // position with a known expected type can be checked against it arm by
  // arm (`branchesAgainstExpected`) before falling back to the bottom-up
  // join below.
  // A tuple literal matched directly is an open site as a binding's
  // initializer is (#7863): the names the arms bind from it fix its open
  // elements, and `Lyric.Mono` binds the literal to a local annotated with
  // the resolved type.
  val scrutLocalKey = openSiteOfExpr(sc, scrutinee)
  val scrutKey = if scrutLocalKey != "" { scrutLocalKey } else { registerOpenTupleSite(sc, tbl, scrutinee, st) }
  val armTypes: List[Type] = newList()
  val armSpans: List[Span] = newList()
  var ai = 0
  while ai < arms.count {
    scopePush(sc)
    bindPatternTyped(sc, tbl, sigs, diag, arms[ai].pattern, st)
    bindOpenTuplePattern(sc, tbl, arms[ai].pattern, scrutKey)
    bindOpenCasePattern(sc, tbl, arms[ai].pattern, scrutKey)
    checkConstRefPattern(tbl, sigs, diag, arms[ai].pattern, st)
    recordTuplePatternBindings(tbl, arms[ai].pattern, st, false, sc.genericNames)
    match arms[ai].guard {
      case Some(g) -> {
        val guardT = inferExpr(sc, tbl, sigs, diag, g)
        resolvePropagateOperand(sc, tbl, g, TyPrim(pt = PtBool))
        match guardT {
          case TyError -> {
          }
          case TyPrim(pt) -> match pt {
            case PtBool -> {
            }
            case PtNever -> {
            }
            case _ -> diag.add(
              errorDiagnostic(
                "T0066",
                "match-arm guard must be Bool (got " + renderType(guardT) + ")",
                g.span
              )
            )
          }
          case _ -> diag.add(
            errorDiagnostic("T0066", "match-arm guard must be Bool (got " + renderType(guardT) + ")", g.span)
          )
        }
      }
      case None -> {
      }
    }
    val bt = inferExprOrBlock(sc, tbl, sigs, diag, arms[ai].body, isValuePosition, tailExpected)
    val armSpan = match arms[ai].body { case EOBExpr(ae) -> ae.span; case EOBBlock(ab) -> ab.span }
    scopePop(sc)
    armTypes.add(bt)
    armSpans.add(armSpan)
    ai = ai + 1
  }
  if isValuePosition {
    match branchesAgainstExpected(tbl, armTypes, tailExpected) {
      case Some(t) -> {
        var wi = 0
        while wi < arms.count and wi < armTypes.count {
          recordBranchWidening(tbl, t, armTypes[wi], arms[wi].body)
          wi = wi + 1
        }
        return t
      }
      case None -> ()
    }
  }
  var acc: Type = TyError
  var ui = 0
  while ui < armTypes.count {
    acc = unifyBranchTypes(acc, armTypes[ui], armSpans[ui], diag, isValuePosition)
    ui = ui + 1
  }
  for arm in arms {
    closePropagateBranch(sc, tbl, arm.body, acc, isValuePosition)
  }
  var ri = 0
  while ri < arms.count and ri < armTypes.count {
    recordBranchConstructionType(sc, tbl, arms[ri].body, armTypes[ri], acc, isValuePosition)
    ri = ri + 1
  }
  acc
}

// A branch of a consumed `if`/`match` whose value is a construction leaving a
// type argument open (`None`, `Ok(1)`, a tuple holding one) is built at the
// type the branches join to, not at the arguments it can fix itself: a
// backend with reified generics otherwise builds `Option<object>` beside a
// sibling `Option<string>` (#7516, #8136).  Recorded in
// `hoistOperandTypeSites`, which `Lyric.Mono` turns into a binding annotated
// with that type.
func recordBranchConstructionType(
  sc: in Scope,
  tbl: in SymbolTable,
  b: in ExprOrBlock,
  own: in Type,
  joined: in Type,
  consumed: in Bool,
): Unit {
  if not consumed or not typeIsClosedOver(joined, sc.genericNames) or renderType(unrefine(own)) == renderType(unrefine(joined)) {
    return
  }
  match branchValueExpr(b) {
    case Some(ve) -> {
      val builds = match stripExprParens(ve).kind {
        case ECall(_, _) -> true
        case EPath(_) -> true
        case ETuple(_) -> true
        case _ -> false
      }
      if builds {
        recordHoistOperandTypeOver(tbl, sc.genericNames, ve, own, joined)
      }
    }
    case None -> ()
  }
}

// A branch of a consumed `if`/`match` whose value is `e?` with an open
// operand (`Err(error = x)?`, `None?`) takes, as its success type, the type
// the branches join to (#8181).
func closePropagateBranch(
  sc: in Scope, tbl: in SymbolTable, b: in ExprOrBlock, joined: in Type, consumed: in Bool
): Unit {
  if not consumed {
    return
  }
  match branchValueExpr(b) {
    case Some(ve) -> resolvePropagateOperand(sc, tbl, ve, joined)
    case None -> ()
  }
}

pub func inferExpr(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
): Type {
  val t = inferExprCore(sc, tbl, sigs, diag, e)
  match e.kind {
    case ECall(fn, _) -> recordCallResultType(tbl, fn, t, e.span)
    case _ -> ()
  }
  noteArrayPlaceRead(sc, tbl, sigs, e, t)
  t
}

// Record a qualified or method call's result type for `Lyric.Mono`
// (D-progress-969). A bare call's callee is either local (Mono sees its
// declaration) or imported generic (Mono specialises it), so only the other
// callee shapes are recorded.
func recordCallResultType(tbl: in SymbolTable, fn: in Expr, t: in Type, sp: in Span): Unit {
  val qualified = match fn.kind { case EPath(p) -> p.segments.count > 1; case EMember(_, _) -> true; case _ -> false }
  if not qualified {
    return
  }
  recordResultTypeAt(tbl, t, sp)
}

// Record `t` as the result type of the expression at `sp` (see
// `SymbolTable.callResultTypes`).
// The one place a `Task[R]` handle is given a source spelling for the middle
// end (docs/68 §3): `typeExprForRef` refuses the built-in id, so a spawn
// handle's type reaches `Lyric.Mono` only through this record, keyed like any
// call result.  Written as `Task[R]` when `R` itself has a source spelling.
func recordTaskHandleTypeAt(tbl: in SymbolTable, result: in Type, sp: in Span): Unit {
  val key = recordCopySiteKey(sp)
  if tbl.callResultTypes.containsKey(key) or isNoSourceSpan(sp) {
    return
  }
  match typeExprForRef(tbl, result, sp) {
    case Some(rte) -> {
      val segs: List[String] = newList()
      segs.add("Task")
      val targs: List[TypeArg] = newList()
      targs.add(TAType(ty = rte))
      tbl.callResultTypes.add(key, TypeExpr(kind = TGenericApp(head = refTypePath(segs, sp), args = targs), span = sp))
    }
    case None -> ()
  }
}

func recordResultTypeAt(tbl: in SymbolTable, t: in Type, sp: in Span): Unit {
  val key = recordCopySiteKey(sp)
  if tbl.callResultTypes.containsKey(key) {
    return
  }
  match typeExprForRef(tbl, t, sp) {
    case Some(te) -> tbl.callResultTypes.add(key, te)
    case None -> ()
  }
}

// Record the checked type of an unannotated local binding whose initializer
// is an `if` or `match` expression of a closed generic type (`val r = match
// o { case Some(x) -> x; case None -> Ok(value = 1) }`), as its annotation
// (see `SymbolTable.localBindingTypeSites`).  A branch that is a construction
// fixing only some of the type's arguments (`Ok(...)` says nothing of `E`)
// takes the rest from the binding's type, which the backends then see: on
// MSIL, which reifies generics, the branch otherwise built `Result_Ok<int,
// object>` where the other branch built `Result<int, string>` — unverifiable
// IL, and a `match` on the value that never recognised it.
func recordLocalBranchType(tbl: in SymbolTable, init: in Expr, t: in Type): Unit {
  if isNoSourceSpan(init.span) {
    return
  }
  val branching = match init.kind { case EIf(_, _, _, _) -> true; case EMatch(_, _) -> true; case _ -> false }
  if not branching {
    return
  }
  match unrefine(t) {
    case TyUser(_, _, args) -> {
      if args.count == 0 or not typesAreClosed(args) {
        return
      }
      val key = recordCopySiteKey(init.span)
      if tbl.localBindingTypeSites.containsKey(key) {
        return
      }
      match typeExprForRef(tbl, t, init.span) {
        case Some(te) -> tbl.localBindingTypeSites.add(key, te)
        case None -> ()
      }
    }
    case _ -> ()
  }
}

// Record the checked type of an unannotated local binding's function-valued
// initializer (see `SymbolTable.localBindingTypeSites`).  An async function, one
// that never returns, and a type with no source spelling (an error) stay
// unrecorded: the binding keeps its inferred-only form.  A type parameter of
// the enclosing declaration is spelled by its name, which names the same
// parameter at the binding; a specialised copy substitutes it (#8205).
func recordLocalFuncType(tbl: in SymbolTable, init: in Expr, t: in Type): Unit {
  if isNoSourceSpan(init.span) {
    return
  }
  match unrefine(t) {
    case TyFunction(_, ret, isAsync) -> {
      val diverges = match unrefine(ret) {
        case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }
        case _ -> false
      }
      if isAsync or diverges {
        return
      }
      val key = recordCopySiteKey(init.span)
      if tbl.localBindingTypeSites.containsKey(key) {
        return
      }
      match typeExprForRefWithVars(tbl, t, init.span) {
        case Some(te) -> tbl.localBindingTypeSites.add(key, te)
        case None -> ()
      }
    }
    case _ -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Open bindings (#7788).
// ─────────────────────────────────────────────────────────────────────────────
//
// `val xs = newList()` fixes nothing about the list's element type, so the
// binding types as `List[<error>]`, which every later use accepts.  A backend
// that erases generics (the JVM) is indifferent; one that reifies them (MSIL)
// has to choose the element type where the list is constructed, and without
// one builds `List<object>`: stored where a `List<Seed>` is declared, that is
// unverifiable IL, and a consumer's typed read of it throws.  The binding's
// uses are recorded as it is checked (`SymbolTable.openBindingSites`), and
// `resolveOpenBindingSites` makes the type they agree on its annotation.
// The `SymbolTable.openBindingSites` key for an unannotated binding
// initialized by `init` of type `initTy`, registering the site, or "" when the
// binding is not open: its initializer is neither an evidence-free
// construction nor a tuple literal whose open elements all are (or are open
// locals), or its type is already closed.
pub func registerOpenBindingSite(sc: in Scope, tbl: in SymbolTable, init: in Expr, initTy: in Type): String {
  if isEvidenceFreeOpenInit(tbl, init, initTy) {
    return addOpenBindingSite(tbl, init, unrefine(initTy), "")
  }
  val srcKey = openSiteOfExpr(sc, init)
  if srcKey != "" {
    return registerOpenAliasSite(sc, tbl, init, initTy, srcKey)
  }
  registerOpenTupleSite(sc, tbl, init, initTy)
}

// An unannotated `val o2 = o` / `var o2 = o` initialised from a bare name that
// is an open site is itself open (#7887): evidence from a use of either name
// fixes the element for both.  The alias's site has the source's children (a
// tuple source's own, or the source itself at the empty position for a plain
// one), so a type noted on the alias reaches the source's sites, and the
// alias's annotation is the source's type, resolved from whatever evidence
// reached it through either name.
func registerOpenAliasSite(sc: in Scope, tbl: in SymbolTable, init: in Expr, initTy: in Type, srcKey: in String): String {
  if isNoSourceSpan(init.span) or init.span.endPos.offset <= init.span.startPos.offset {
    return ""
  }
  val key = recordCopySiteKey(init.span)
  if tbl.openBindingSites.containsKey(key) {
    return key
  }
  match mapGet(tbl.openBindingSites, srcKey) {
    case None -> ""
    case Some(src) -> {
      val childKeys: List[String] = newList()
      val childPaths: List[List[Int]] = newList()
      if src.childKeys.count > 0 {
        var ci = 0
        while ci < src.childKeys.count {
          childKeys.add(src.childKeys[ci])
          childPaths.add(src.childPaths[ci])
          ci = ci + 1
        }
      } else {
        childKeys.add(srcKey)
        childPaths.add(newList())
      }
      val typeParams: List[String] = newList()
      var gi = 0
      while gi < sc.genericNames.count {
        typeParams.add(sc.genericNames[gi])
        gi = gi + 1
      }
      tbl.openBindingSites.add(
        key,
        OpenBindingSite(
          initSpan = init.span,
          initTy = unrefine(initTy),
          sinkTy = newList(),
          sinkTe = newList(),
          storeTy = newList(),
          storeTe = newList(),
          sinkConflict = newList(),
          storeConflict = newList(),
          childKeys = childKeys,
          childPaths = childPaths,
          parentKey = "",
          hoistExprs = newList(),
          hoistPaths = newList(),
          typeParams = typeParams,
          patSpans = newList(),
          patPaths = newList(),
          argKeys = newList(),
          argIdx = newList()
        )
      )
      key
    }
  }
}

// Whether `init`, of type `initTy`, is a construction that fixes nothing
// about some of its type's arguments.  Bare or qualified (`Coll.newList()`,
// `Std.Core.None`), recognised by what the initializer resolved to, never its
// spelling (#7801): a call the `ECall` arm bound to a stdlib collection
// constructor, a `None` whose type is the stdlib `Option`, or a `Some`/`Ok`/
// `Err` of the stdlib `Option`/`Result` (`Ok(2)` fixes `T`, not `E`, #7855).
// A package's own `newList` or its own union's cases are ordinary
// initializers.  The inferred type then decides whether anything is left
// open.
func isEvidenceFreeOpenInit(tbl: in SymbolTable, init: in Expr, initTy: in Type): Bool {
  if isNoSourceSpan(init.span) or init.span.endPos.offset <= init.span.startPos.offset {
    return false
  }
  val evidenceFree = match init.kind {
    case ECall(fn, _) -> tbl.emptyCollectionCtorSites.containsKey(recordCopySiteKey(init.span)) or
      isStdMonadCaseCtor(tbl, fn, initTy)
    case EPath(_) -> isStdOptionNone(tbl, init, initTy)
    case EMember(_, _) -> isStdOptionNone(tbl, init, initTy)
    case _ -> false
  }
  if not evidenceFree {
    return false
  }
  match unrefine(initTy) {
    case TyUser(_, _, args) -> args.count > 0 and not typesAreClosed(args)
    case _ -> false
  }
}

// Is `fn` a case constructor of the stdlib `Option` or `Result`, building a
// value of type `t`?
func isStdMonadCaseCtor(tbl: in SymbolTable, fn: in Expr, t: in Type): Bool {
  match unionCaseSymbolOf(tbl, fn) {
    case Some(caseSym) -> match caseSym.kind {
      case DKUnionCase(parentId, _) -> match unrefine(t) {
        case TyUser(tid, _, _) -> symbolIdEq(parentId, tid) and
          (
            isStdCoreMonadType(
              tbl,
              tid,
              "Option"
            ) or
              isStdCoreMonadType(
                tbl,
                tid,
                "Result"
              )
          )
        case _ -> false
      }
      case _ -> false
    }
    case None -> false
  }
}

// Register the open site of `init`, of the (unrefined) type `ty`, keyed by
// its span, unless it is registered already; `parentKey` is the tuple site
// owning it, or "".
func addOpenBindingSite(tbl: in SymbolTable, init: in Expr, ty: in Type, parentKey: in String): String {
  val key = recordCopySiteKey(init.span)
  if not tbl.openBindingSites.containsKey(key) {
    tbl.openBindingSites.add(
      key,
      OpenBindingSite(
        initSpan = init.span,
        initTy = ty,
        sinkTy = newList(),
        sinkTe = newList(),
        storeTy = newList(),
        storeTe = newList(),
        sinkConflict = newList(),
        storeConflict = newList(),
        childKeys = newList(),
        childPaths = newList(),
        parentKey = parentKey,
        hoistExprs = newList(),
        hoistPaths = newList(),
        typeParams = newList(),
        patSpans = newList(),
        patPaths = newList(),
        argKeys = newList(),
        argIdx = newList()
      )
    )
  }
  key
}

// ── Open tuples (#7855) ──────────────────────────────────────────────────────
//
// `val t = (None, 5)` leaves the `None`'s type argument open just as
// `val o = None` does, and MSIL built the element as an `Option<object>`.  A
// tuple literal whose open elements are each an evidence-free construction,
// an open local, or such a tuple is an open site with one child per open
// element (`OpenBindingSite.childKeys`).  A use of the whole tuple is a use of
// each child at its position; a name a tuple pattern binds at a child's
// position (`val (o, n) = t`, `case (o, n) ->`) is open to that child, so its
// own uses count too.  The tuple's annotation is its type with every
// child's resolved type in place, and is written only once every child has
// one.
func registerOpenTupleSite(sc: in Scope, tbl: in SymbolTable, init: in Expr, initTy: in Type): String {
  if isNoSourceSpan(init.span) or init.span.endPos.offset <= init.span.startPos.offset {
    return ""
  }
  val t = unrefine(initTy)
  if typeIsClosed(t) {
    return ""
  }
  match stripExprParens(init).kind {
    case ETuple(elems) -> match t {
      case TyTuple(ets) -> {
        val noPath: List[Int] = newList()
        val cands = OpenTupleChildren(exprs = newList(), tys = newList(), paths = newList(), localKeys = newList())
        if ets.count != elems.count or not collectOpenTupleChildren(sc, tbl, elems, ets, noPath, cands) {
          return ""
        }
        val key = recordCopySiteKey(init.span)
        if tbl.openBindingSites.containsKey(key) {
          return key
        }
        val childKeys: List[String] = newList()
        var ci = 0
        while ci < cands.exprs.count {
          childKeys.add(
            if cands.localKeys[ci] != "" {
              cands.localKeys[ci]
            } else {
              addOpenBindingSite(tbl, cands.exprs[ci], cands.tys[ci], key)
            }
          )
          ci = ci + 1
        }
        val childPaths = cands.paths
        val hoistExprs: List[Expr] = newList()
        val hoistPaths: List[List[Int]] = newList()
        collectHoistedTupleOperands(sc, elems, noPath, hoistExprs, hoistPaths)
        val typeParams: List[String] = newList()
        var gi = 0
        while gi < sc.genericNames.count {
          typeParams.add(sc.genericNames[gi])
          gi = gi + 1
        }
        tbl.openBindingSites.add(
          key,
          OpenBindingSite(
            initSpan = init.span,
            initTy = t,
            sinkTy = newList(),
            sinkTe = newList(),
            storeTy = newList(),
            storeTe = newList(),
            sinkConflict = newList(),
            storeConflict = newList(),
            childKeys = childKeys,
            childPaths = childPaths,
            parentKey = "",
            hoistExprs = hoistExprs,
            hoistPaths = hoistPaths,
            typeParams = typeParams,
            patSpans = newList(),
            patPaths = newList(),
            argKeys = newList(),
            argIdx = newList()
          )
        )
        key
      }
      case _ -> ""
    }
    case _ -> ""
  }
}

// The open elements of a tuple literal, each at its position: the element,
// its type, and, for an open local, that local's own site key ("" for an
// evidence-free construction, whose site the tuple registers).
record OpenTupleChildren {
  exprs: List[Expr]
  tys: List[Type]
  paths: List[List[Int]]
  localKeys: List[String]
}

// Collect into `acc` each open element of the tuple literal `elems` (at
// `path`), descending into nested tuple literals.  False, with `acc`
// partially filled, when an open element is none of an evidence-free
// construction, an open local, or a tuple literal of such.
func collectOpenTupleChildren(
  sc: in Scope,
  tbl: in SymbolTable,
  elems: in List[Expr],
  ets: in List[Type],
  path: in List[Int],
  acc: in OpenTupleChildren,
): Bool {
  var i = 0
  while i < elems.count {
    val et = unrefine(ets[i])
    if not typeIsClosed(et) {
      val el = stripExprParens(elems[i])
      val here = pathAppend(path, i)
      val ok = match el.kind {
        case ETuple(sub) -> match et {
          case TyTuple(subEts) -> subEts.count == sub.count and
            collectOpenTupleChildren(sc, tbl, sub, subEts, here, acc)
          case _ -> false
        }
        case _ -> {
          val localKey = openSiteOfExpr(sc, el)
          if localKey != "" or isEvidenceFreeOpenInit(tbl, el, et) {
            acc.exprs.add(el)
            acc.tys.add(et)
            acc.paths.add(here)
            acc.localKeys.add(localKey)
            true
          } else {
            false
          }
        }
      }
      if not ok {
        return false
      }
    }
    i = i + 1
  }
  true
}

func pathAppend(path: in List[Int], i: in Int): List[Int] {
  val acc: List[Int] = newList()
  var k = 0
  while k < path.count {
    acc.add(path[k])
    k = k + 1
  }
  acc.add(i)
  acc
}

func pathsEqual(a: in List[Int], b: in List[Int]): Bool {
  if a.count != b.count {
    return false
  }
  var i = 0
  while i < a.count {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

// The element of the (nested) tuple type `t` at `path`, if `t` has one.
func tupleTypeAt(t: in Type, path: in List[Int]): Option[Type] {
  var cur = t
  var i = 0
  while i < path.count {
    match unrefine(cur) {
      case TyTuple(es) -> if path[i] < es.count { cur = es[path[i]] } else { return None }
      case _ -> return None
    }
    i = i + 1
  }
  Some(value = cur)
}

// `t` with the element at `path` replaced by `repl`.
func tupleTypeWith(t: in Type, path: in List[Int], depth: in Int, repl: in Type): Type {
  if depth >= path.count {
    return repl
  }
  match unrefine(t) {
    case TyTuple(es) -> {
      val replaced: List[Type] = newList()
      var i = 0
      while i < es.count {
        replaced.add(if i == path[depth] { tupleTypeWith(es[i], path, depth + 1, repl) } else { es[i] })
        i = i + 1
      }
      TyTuple(elems = replaced)
    }
    case _ -> t
  }
}

// The elements of the tuple literal `elems` (at `path`) that the await / `?`
// hoist binds one by one: exactly those `recordHoistedOperands` and
// `recordHoistedComposite` record, which here have no type yet.
func collectHoistedTupleOperands(
  sc: in Scope,
  elems: in List[Expr],
  path: in List[Int],
  outExprs: in List[Expr],
  outPaths: in List[List[Int]],
): Unit {
  var last = -1
  var i = 0
  while i < elems.count {
    if HoistEngine.exprHasHoistHazard(elems[i]) {
      last = i
    }
    i = i + 1
  }
  if last < 0 {
    return
  }
  var k = 0
  while k < last {
    if hoistBindsOperand(sc, elems[k]) {
      outExprs.add(elems[k])
      outPaths.add(pathAppend(path, k))
    }
    k = k + 1
  }
  val composite = stripExprParens(elems[last])
  val here = pathAppend(path, last)
  match composite.kind {
    case ETuple(sub) -> collectHoistedTupleOperands(sc, sub, here, outExprs, outPaths)
    case EIf(_, _, _, _) -> {
      outExprs.add(composite)
      outPaths.add(here)
    }
    case EMatch(_, _) -> {
      outExprs.add(composite)
      outPaths.add(here)
    }
    case EBlock(_) -> {
      outExprs.add(composite)
      outPaths.add(here)
    }
    case EUnsafe(_) -> {
      outExprs.add(composite)
      outPaths.add(here)
    }
    case EBinop(op, _, _) -> if binopShortCircuits(op) { outExprs.add(composite); outPaths.add(here) }
    case _ -> ()
  }
}

// Whether the hoist binds the operand `e` to a local whose type needs
// recording: `recordHoistOperandType`'s test.
func hoistBindsOperand(sc: in Scope, e: in Expr): Bool {
  val sp = e.span
  if isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return false
  }
  not exprIsHoistExempt(sc, e)
}

// Whether a hoisted operand `e` needs no recorded type: a literal and a
// lambda are never bound, and a local is bound at its declared type already.
func exprIsHoistExempt(sc: in Scope, e: in Expr): Bool {
  match e.kind {
    case ELiteral(_) -> true
    case ELambda(_, _) -> true
    case EPath(p) -> if p.segments.count == 1 {
      match scopeTryFind(sc, p.segments[0]) {
        case Some(_) -> true
        case None -> false
      }
    } else {
      false
    }
    case _ -> false
  }
}

// A constructor pattern in a `match` arm on an open local (#8250):
// `case Err(e)` on `val r = Ok(value = true)` binds `e` at the type argument
// `E` the construction leaves open.  The name is open to that argument: what
// `e` flows into fixes `E`, and `resolveOpenBindingSites` folds it into the
// local's type, so the local is declared at the closed type rather than
// reaching a backend open.
pub func bindOpenCasePattern(sc: in Scope, tbl: in SymbolTable, pat: in Pattern, key: in String): Unit {
  if key == "" {
    return
  }
  val target = openAliasTarget(tbl, key)
  match mapGet(tbl.openBindingSites, target) {
    case Some(site) -> if site.childKeys.count == 0 { bindOpenCasePatternAt(sc, tbl, target, site, pat) }
    case None -> ()
  }
}

// The site an alias site (`registerOpenAliasSite`) stands for: the plain site
// it holds as its one child at the empty position, else `key` itself.
func openAliasTarget(tbl: in SymbolTable, key: in String): String {
  var cur = key
  var guard = 0
  while guard < 16 {
    match mapGet(tbl.openBindingSites, cur) {
      case Some(site) -> if site.childKeys.count == 1 and site.childPaths[0].count == 0 {
        cur = site.childKeys[0]
      } else {
        return cur
      }
      case None -> return cur
    }
    guard = guard + 1
  }
  cur
}

func bindOpenCasePatternAt(
  sc: in Scope, tbl: in SymbolTable, key: in String, site: in OpenBindingSite, pat: in Pattern
): Unit {
  match pat.kind {
    case PParen(inner) -> bindOpenCasePatternAt(sc, tbl, key, site, inner)
    case PConstructor(head, pargs) -> {
      val siteTargs = match site.initTy { case TyUser(_, _, targs) -> targs; case _ -> return }
      val siteTid = match site.initTy { case TyUser(tid, _, _) -> tid; case _ -> return }
      val fnExpr = Expr(kind = EPath(path = head), span = pat.span)
      match unionCaseSymbolOf(tbl, fnExpr) {
        case Some(caseSym) -> match caseSym.kind {
          case DKUnionCase(parentId, uc) -> {
            if not symbolIdEq(parentId, siteTid) {
              return
            }
            match parentUnionDeclOf(tbl, parentId) {
              case Some(decl) -> {
                val gnames = unionDeclGenericNames(decl)
                if gnames.count != siteTargs.count {
                  return
                }
                val scratch: List[Diagnostic] = newList()
                val ftypes = unionCaseFieldTypes(tbl, scratch, uc, gnames, caseSym.originPackage)
                var i = 0
                while i < pargs.count and i < ftypes.count {
                  bindOpenCaseArg(sc, tbl, key, site, pargs[i], ftypes[i], gnames, siteTargs)
                  i = i + 1
                }
              }
              case None -> ()
            }
          }
          case _ -> ()
        }
        case None -> ()
      }
    }
    case _ -> ()
  }
}

// `argPat` is the pattern for a payload field of declared type `fty`: a bare
// name over a field typed by one of the union's type parameters whose argument
// is open at `site` becomes open to that argument.
func bindOpenCaseArg(
  sc: in Scope,
  tbl: in SymbolTable,
  key: in String,
  site: in OpenBindingSite,
  argPat: in Pattern,
  fty: in Type,
  gnames: in List[String],
  siteTargs: in List[Type],
): Unit {
  match argPat.kind {
    case PParen(inner) -> bindOpenCaseArg(sc, tbl, key, site, inner, fty, gnames, siteTargs)
    case PBinding(name, None) -> {
      if name == "_" or isConstructorPatternName(tbl, name) {
        return
      }
      val gname = match fty { case TyVar(g) -> g; case _ -> return }
      var gi = -1
      var k = 0
      while k < gnames.count {
        if gnames[k] == gname {
          gi = k
        }
        k = k + 1
      }
      if gi < 0 or typeIsClosed(siteTargs[gi]) or isNoSourceSpan(argPat.span) or argPat.span.endPos.offset <= argPat.span.startPos.offset {
        return
      }
      val argKey = recordCopySiteKey(argPat.span)
      if not tbl.openBindingSites.containsKey(argKey) {
        tbl.openBindingSites.add(
          argKey,
          OpenBindingSite(
            initSpan = argPat.span,
            initTy = TyError,
            sinkTy = newList(),
            sinkTe = newList(),
            storeTy = newList(),
            storeTe = newList(),
            sinkConflict = newList(),
            storeConflict = newList(),
            childKeys = newList(),
            childPaths = newList(),
            parentKey = key,
            hoistExprs = newList(),
            hoistPaths = newList(),
            typeParams = newList(),
            patSpans = newList(),
            patPaths = newList(),
            argKeys = newList(),
            argIdx = newList()
          )
        )
        site.argKeys.add(argKey)
        site.argIdx.add(gi)
      }
      match scopeTryFind(sc, name) {
        case Some(b) -> scopeAdd(sc, LocalBinding(name = name, ty = b.ty, isMutable = b.isMutable, openSite = argKey))
        case None -> ()
      }
    }
    case _ -> ()
  }
}

// Fold the type arguments the names bound by constructor patterns fixed into
// the type of each open site that has such names (#8250): the site then has
// the closed type those names and its own uses agree on.
func foldOpenCaseArgs(tbl: in SymbolTable): Unit {
  val keys = mapKeys(tbl.openBindingSites)
  var i = 0
  while i < keys.count {
    match mapGet(tbl.openBindingSites, keys[i]) {
      case Some(site) -> if site.argKeys.count > 0 {
        match site.initTy {
          case TyUser(tid, nm, targs) -> {
            val filled: List[Type] = newList()
            var k = 0
            while k < targs.count {
              filled.add(targs[k])
              k = k + 1
            }
            var ai = 0
            while ai < site.argKeys.count {
              match mapGet(tbl.openBindingSites, site.argKeys[ai]) {
                case Some(argSite) -> {
                  val fixed: Option[Type] = match openSiteChoice(argSite) {
                    case 1 -> Some(value = argSite.sinkTy[0])
                    case 2 -> Some(value = argSite.storeTy[0])
                    case _ -> None
                  }
                  match fixed {
                    case Some(ft) -> {
                      filled[site.argIdx[ai]] = ft
                    }
                    case None -> ()
                  }
                }
                case None -> ()
              }
              ai = ai + 1
            }
            val noParams: List[String] = newList()
            noteOpenBindingType(tbl, keys[i], TyUser(id = tid, name = nm, args = filled), true, noParams)
          }
          case _ -> ()
        }
      }
      case None -> ()
    }
    i = i + 1
  }
}

// `pat` binds the value of the open site `key`: each name it binds at the
// position of one of the site's children is open to that child (#7855), and
// each name it binds to a tuple holding children (the whole value, or a
// nested sub-tuple) is open to a site of its own over those children (#7863).
pub func bindOpenTuplePattern(sc: in Scope, tbl: in SymbolTable, pat: in Pattern, key: in String): Unit {
  if key == "" {
    return
  }
  match mapGet(tbl.openBindingSites, key) {
    case Some(site) -> if site.childKeys.count > 0 {
      val noPath: List[Int] = newList()
      bindOpenTuplePatternAt(sc, tbl, key, site, pat, noPath)
    }
    case None -> ()
  }
}

func bindOpenTuplePatternAt(
  sc: in Scope,
  tbl: in SymbolTable,
  key: in String,
  site: in OpenBindingSite,
  pat: in Pattern,
  path: in List[Int],
): Unit {
  match pat.kind {
    case PParen(inner) -> bindOpenTuplePatternAt(sc, tbl, key, site, inner, path)
    case PTuple(ps) -> {
      var i = 0
      while i < ps.count {
        bindOpenTuplePatternAt(sc, tbl, key, site, ps[i], pathAppend(path, i))
        i = i + 1
      }
    }
    case PBinding(name, None) -> if name != "_" and not isConstructorPatternName(tbl, name) {
      val nameKey = if path.count == 0 { key } else { openSiteAtPath(tbl, key, site, pat.span, path) }
      if nameKey == "" {
        return
      }
      match scopeTryFind(sc, name) {
        case Some(b) -> {
          scopeAdd(sc, LocalBinding(name = name, ty = b.ty, isMutable = b.isMutable, openSite = nameKey))
          if path.count > 0 {
            site.patSpans.add(pat.span)
            site.patPaths.add(path)
          }
        }
        case None -> ()
      }
    }
    case _ -> ()
  }
}

// The open site a name bound at `path` in the value of the tuple site `site`
// (keyed `key`) is open to: the child at `path`, or, when `path` holds
// children deeper down, a site over them keyed by the binding's span `sp`,
// owned by `key` and with each child at its position below `path`.  "" when
// nothing open is at or under `path`.
func openSiteAtPath(
  tbl: in SymbolTable, key: in String, site: in OpenBindingSite, sp: in Span, path: in List[Int]
): String {
  val subKeys: List[String] = newList()
  val subPaths: List[List[Int]] = newList()
  var ci = 0
  while ci < site.childKeys.count {
    val cp = site.childPaths[ci]
    if pathsEqual(cp, path) {
      return site.childKeys[ci]
    }
    if cp.count > path.count and pathIsPrefix(path, cp) {
      subKeys.add(site.childKeys[ci])
      subPaths.add(pathSuffix(cp, path.count))
    }
    ci = ci + 1
  }
  if subKeys.count == 0 or isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return ""
  }
  val subKey = recordCopySiteKey(sp)
  if tbl.openBindingSites.containsKey(subKey) {
    return subKey
  }
  match tupleTypeAt(site.initTy, path) {
    case Some(subTy) -> {
      tbl.openBindingSites.add(
        subKey,
        OpenBindingSite(
          initSpan = sp,
          initTy = unrefine(subTy),
          sinkTy = newList(),
          sinkTe = newList(),
          storeTy = newList(),
          storeTe = newList(),
          sinkConflict = newList(),
          storeConflict = newList(),
          childKeys = subKeys,
          childPaths = subPaths,
          parentKey = key,
          hoistExprs = newList(),
          hoistPaths = newList(),
          typeParams = site.typeParams,
          patSpans = newList(),
          patPaths = newList(),
          argKeys = newList(),
          argIdx = newList()
        )
      )
      subKey
    }
    case None -> ""
  }
}

// Whether `prefix` is a prefix of `path`.
func pathIsPrefix(prefix: in List[Int], path: in List[Int]): Bool {
  if prefix.count > path.count {
    return false
  }
  var i = 0
  while i < prefix.count {
    if prefix[i] != path[i] {
      return false
    }
    i = i + 1
  }
  true
}

// `path` without its first `n` positions.
func pathSuffix(path: in List[Int], n: in Int): List[Int] {
  val acc: List[Int] = newList()
  var k = n
  while k < path.count {
    acc.add(path[k])
    k = k + 1
  }
  acc
}

// Is `e`, of type `t`, the stdlib `Option`'s `None` case?  The name says
// which case; the type's identity says whose.
func isStdOptionNone(tbl: in SymbolTable, e: in Expr, t: in Type): Bool {
  if lastNameOfPathExpr(e) != "None" {
    return false
  }
  match unrefine(t) {
    case TyUser(tid, _, _) -> isStdCoreMonadType(tbl, tid, "Option")
    case _ -> false
  }
}

// The last name of a (possibly qualified) name expression: `f` for `f`,
// `Pkg.f` and `Pkg.Sub.f`; "" for any other expression.
func lastNameOfPathExpr(e: in Expr): String {
  match e.kind {
    case EPath(p) -> if p.segments.count > 0 { p.segments[p.segments.count - 1] } else { "" }
    case EMember(recv, name) -> if lastNameOfPathExpr(recv) != "" { name } else { "" }
    case _ -> ""
  }
}

// The open-site key of the local `e` names, or "" when `e` is not a bare
// name bound to an open binding.
func openSiteOfExpr(sc: in Scope, e: in Expr): String {
  match e.kind {
    case EParen(inner) -> openSiteOfExpr(sc, inner)
    case EPath(p) -> if p.segments.count == 1 {
      match scopeTryFind(sc, p.segments[0]) {
        case Some(b) -> b.openSite
        case None -> ""
      }
    } else {
      ""
    }
    case _ -> ""
  }
}

// Record `t` as a sink (`isSink`) or store type of the open binding `key`.
// Only a closed type of the binding's own constructor counts: an `Iterable`
// parameter or an interface-typed field says nothing about the element type
// the list is built with.  A store's type may also mention `typeParams`, the
// enclosing function's type parameters: it is the type of an expression in
// that function, so its `T` is the function's own, which `Lyric.Mono`
// substitutes when it specialises the body.  A sink's never may: a generic
// callee's parameter `List[T]` names the callee's `T`.  The first sink and
// the first store win; a later one that disagrees marks the kind
// conflicting, and a conflicting kind is not used.
func noteOpenBindingType(
  tbl: in SymbolTable, key: in String, t: in Type, isSink: in Bool, typeParams: in List[String]
): Unit {
  match mapGet(tbl.openBindingSites, key) {
    case None -> ()
    case Some(site) -> {
      val ut = unrefine(t)
      // A tuple site's type is its children's, each at its position.
      if site.childKeys.count > 0 {
        var ci = 0
        while ci < site.childKeys.count {
          match tupleTypeAt(ut, site.childPaths[ci]) {
            case Some(et) -> noteOpenBindingType(tbl, site.childKeys[ci], et, isSink, typeParams)
            case None -> ()
          }
          ci = ci + 1
        }
        return
      }
      val noParams: List[String] = newList()
      val allowed = if isSink { noParams } else { typeParams }
      if not typeIsClosedOver(ut, allowed) {
        return
      }
      val sameCtor = match site.initTy {
        case TyUser(iid, _, iargs) -> match ut {
          case TyUser(tid, _, targs) -> symbolIdEq(iid, tid) and
            iargs.count == targs.count
          case _ -> false
        }
        // The site of a name a constructor pattern binds to a type argument
        // (`bindOpenCasePattern`) has no constructor of its own: any closed
        // type is the argument.
        case TyError -> true
        case _ -> false
      }
      if not sameCtor {
        return
      }
      val tys = if isSink { site.sinkTy } else { site.storeTy }
      if tys.count > 0 {
        if not typeEquiv(tys[0], ut) {
          val conflict = if isSink { site.sinkConflict } else { site.storeConflict }
          if conflict.count == 0 {
            conflict.add(true)
          }
        }
        return
      }
      match typeExprForOpenBinding(tbl, ut, site.initSpan, allowed) {
        case Some(te) -> {
          tys.add(ut)
          if isSink {
            site.sinkTe.add(te)
          } else {
            site.storeTe.add(te)
          }
        }
        case None -> ()
      }
    }
  }
}

// `typeIsClosed`, except that a type variable named in `typeParams` counts
// as closed.
func typeIsClosedOver(t: in Type, typeParams: in List[String]): Bool {
  match t {
    case TyVar(n) -> typeParams.contains(n)
    case TyError -> false
    case TySelf -> false
    case TyUser(_, _, args) -> typesAreClosedOver(args, typeParams)
    case TySlice(e) -> typeIsClosedOver(e, typeParams)
    case TyArray(_, e, _) -> typeIsClosedOver(e, typeParams)
    case TyNullable(inner) -> typeIsClosedOver(inner, typeParams)
    case TyTuple(elems) -> typesAreClosedOver(elems, typeParams)
    case TyFunction(ps, ret, _) -> typesAreClosedOver(ps, typeParams) and typeIsClosedOver(ret, typeParams)
    case TyRefined(u, _, _, _, _) -> typeIsClosedOver(u, typeParams)
    case _ -> true
  }
}

// A type parameter of the enclosing generic is rigid inside its body: it is
// the same type only as itself.  `typeEquiv` still treats every `TyVar` as a
// wildcard, because the same variable stands for an instantiation variable
// of a callee, so a mismatch against a type parameter is decided here, where
// the enclosing generic's names are known (#7974).  True when `actual` has a
// rigid type parameter of `names` where `expected` has a different type
// that a `where` bound cannot make equal: anything but another type
// variable, an interface (which a bound may satisfy) or an unknown type.
func rigidVarClash(tbl: in SymbolTable, expected: in Type, actual: in Type, names: in List[String]): Bool {
  if names.count == 0 {
    return false
  }
  val e = unrefine(expected)
  val a = unrefine(actual)
  match a {
    case TyVar(n) -> {
      if not names.contains(n) {
        return false
      }
      match e {
        case TyVar(_) -> false
        case TyError -> false
        case TySelf -> false
        case TyUser(eid, _, _) -> not typeIdIsInterface(tbl, eid) and not symTableIsExternTypeId(tbl, eid)
        case TyPrim(ept) -> match ept { case PtNever -> false; case _ -> true }
        case TyNullable(_) -> true
        case TyTuple(_) -> true
        case TySlice(_) -> true
        case TyArray(_, _, _) -> true
        case TyFunction(_, _, _) -> true
        case _ -> false
      }
    }
    case TyUser(aid, _, aargs) -> match e {
      case TyUser(eid, _, eargs) -> {
        if not symbolIdEq(aid, eid) or aargs.count != eargs.count {
          return false
        }
        var i = 0
        while i < aargs.count {
          if rigidVarClash(tbl, eargs[i], aargs[i], names) {
            return true
          }
          i = i + 1
        }
        false
      }
      case _ -> false
    }
    case TySlice(ae) -> match e { case TySlice(ee) -> rigidVarClash(tbl, ee, ae, names); case _ -> false }
    case TyNullable(ai) -> match e { case TyNullable(ei) -> rigidVarClash(tbl, ei, ai, names); case _ -> false }
    case _ -> false
  }
}

func typeIdIsInterface(tbl: in SymbolTable, tid: in SymbolId): Bool {
  for sym in tbl.symbols {
    match sym.kind {
      case DKInterface(iid, _) -> if symbolIdEq(iid, tid) { return true }
      case _ -> ()
    }
  }
  false
}

func typesAreClosedOver(ts: in List[Type], typeParams: in List[String]): Bool {
  var i = 0
  while i < ts.count {
    if not typeIsClosedOver(ts[i], typeParams) {
      return false
    }
    i = i + 1
  }
  true
}

// The source spelling of an open binding's type (`typeExprForRef`), in which
// a type variable named in `typeParams` is spelled by its name.
func typeExprForOpenBinding(tbl: in SymbolTable, t: in Type, sp: in Span, typeParams: in List[String]): Option[TypeExpr] {
  if typeIsClosed(t) {
    return typeExprForRef(tbl, t, sp)
  }
  match t {
    case TyVar(n) -> if typeParams.contains(n) {
      val segs: List[String] = newList()
      segs.add(n)
      Some(value = TypeExpr(kind = TRef(path = refTypePath(segs, sp)), span = sp))
    } else {
      None
    }
    case TyRefined(u, _, _, _, _) -> typeExprForOpenBinding(tbl, u, sp, typeParams)
    case TySlice(e) -> match typeExprForOpenBinding(tbl, e, sp, typeParams) {
      case Some(te) -> Some(value = TypeExpr(kind = TSlice(element = te), span = sp))
      case None -> None
    }
    // An array of a type parameter (`array[2, T]`, #8190): spelled as
    // `typeExprForRef` spells a closed one, its length a literal or the
    // value generic parameter that is its length (D169).
    case TyArray(sz, e, sv) -> match typeExprForOpenBinding(tbl, e, sp, typeParams) {
      case Some(te) -> match sz {
        case Some(n) -> {
          val lenLit = mkExpr(ELiteral(lit = LInt(value = n.toLong(), suffix = I32, raw = "")), sp)
          Some(value = TypeExpr(kind = TArray(size = TAValue(expr = lenLit), element = te), span = sp))
        }
        case None -> if sv.length > 0 {
          val nsegs: List[String] = newList()
          nsegs.add(sv)
          val lenTe = TypeExpr(kind = TRef(path = refTypePath(nsegs, sp)), span = sp)
          Some(value = TypeExpr(kind = TArray(size = TAType(ty = lenTe), element = te), span = sp))
        } else {
          None
        }
      }
      case None -> None
    }
    case TyNullable(inner) -> match typeExprForOpenBinding(tbl, inner, sp, typeParams) {
      case Some(te) -> Some(value = TypeExpr(kind = TNullable(inner = te), span = sp))
      case None -> None
    }
    case TyTuple(elems) -> {
      val tes: List[TypeExpr] = newList()
      var i = 0
      while i < elems.count {
        match typeExprForOpenBinding(tbl, elems[i], sp, typeParams) {
          case Some(te) -> tes.add(te)
          case None -> return None
        }
        i = i + 1
      }
      Some(value = TypeExpr(kind = TTuple(types = tes), span = sp))
    }
    case TyUser(tid, nm, args) -> {
      val noArgs: List[Type] = newList()
      match typeExprForRef(tbl, TyUser(id = tid, name = nm, args = noArgs), sp) {
        case Some(headTe) -> match headTe.kind {
          case TRef(head) -> {
            val targs: List[TypeArg] = newList()
            var i = 0
            while i < args.count {
              match typeExprForOpenBinding(tbl, args[i], sp, typeParams) {
                case Some(te) -> targs.add(TAType(ty = te))
                case None -> return None
              }
              i = i + 1
            }
            Some(value = TypeExpr(kind = TGenericApp(head = head, args = targs), span = sp))
          }
          case _ -> None
        }
        case None -> None
      }
    }
    case _ -> None
  }
}

// Whether `e` can carry an open binding to a sink: the binding itself, or a
// constructor call or tuple literal one of whose arguments or elements can.
func exprMayCarryOpenBinding(sc: in Scope, e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> exprMayCarryOpenBinding(sc, inner)
    case EPath(_) -> openSiteOfExpr(sc, e) != ""
    case ECall(_, cargs) -> {
      var i = 0
      while i < cargs.count {
        if exprMayCarryOpenBinding(sc, callArgExpr(cargs[i])) {
          return true
        }
        i = i + 1
      }
      false
    }
    case ETuple(elems) -> {
      var i = 0
      while i < elems.count {
        if exprMayCarryOpenBinding(sc, elems[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

// `e` flows into a position whose declared type is `expected`: record the
// sink of each open binding it carries — `e` itself, or an argument of a
// union-case or record construction of `expected`'s type
// (`Ok(value = xs)` against `Result[List[Seed], String]`).  Branches of an
// `if`/`match`/block are checked against the same expected type through
// `inferExprExpected`, which calls this for each of them.
pub func noteExpectedFlow(sc: in Scope, tbl: in SymbolTable, e: in Expr, expected: in Type): Unit {
  if tbl.openBindingSites.count == 0 or not typeIsClosed(expected) {
    return
  }
  if not exprMayCarryOpenBinding(sc, e) {
    return
  }
  match e.kind {
    case EParen(inner) -> noteExpectedFlow(sc, tbl, inner, expected)
    case EPath(_) -> {
      val noParams: List[String] = newList()
      noteOpenBindingType(tbl, openSiteOfExpr(sc, e), expected, true, noParams)
    }
    case ECall(fn, cargs) -> noteCtorArgFlows(sc, tbl, fn, cargs, expected)
    case ETuple(elems) -> match unrefine(expected) {
      case TyTuple(ets) -> if ets.count == elems.count {
        var i = 0
        while i < elems.count {
          noteExpectedFlow(sc, tbl, elems[i], ets[i])
          i = i + 1
        }
      }
      case _ -> ()
    }
    case _ -> ()
  }
}

// `fn(cargs)` constructs a value of type `ctorTy`: each argument flows into
// its field, whose type is the declared field type instantiated at
// `ctorTy`'s type arguments.  Nothing is recorded when `fn` is not a
// union-case or record constructor of `ctorTy`'s type.
func noteCtorArgFlows(sc: in Scope, tbl: in SymbolTable, fn: in Expr, cargs: in List[CallArg], ctorTy: in Type): Unit {
  if tbl.openBindingSites.count == 0 {
    return
  }
  var anyCarried = false
  var ci = 0
  while ci < cargs.count {
    if exprMayCarryOpenBinding(sc, callArgExpr(cargs[ci])) {
      anyCarried = true
    }
    ci = ci + 1
  }
  if not anyCarried {
    return
  }
  match ctorArgExpectedTypes(tbl, fn, cargs, ctorTy) {
    case Some(expected) -> {
      var k = 0
      while k < cargs.count {
        noteExpectedFlow(sc, tbl, callArgExpr(cargs[k]), expected[k])
        k = k + 1
      }
    }
    case None -> ()
  }
}

// The type each argument of the construction `fn(cargs)` of `ctorTy` is
// expected to have: its field's declared type instantiated at `ctorTy`'s type
// arguments, or `TyError` for an argument that fills no field.  `None` when
// `fn` is not a union-case or record constructor of `ctorTy`'s type.
func ctorArgExpectedTypes(
  tbl: in SymbolTable, fn: in Expr, cargs: in List[CallArg], ctorTy: in Type
): Option[List[Type]] {
  match unrefine(ctorTy) {
    case TyUser(tid, _, targs) -> {
      match unionCaseSymbolOf(tbl, fn) {
        case Some(caseSym) -> match caseSym.kind {
          case DKUnionCase(parentId, uc) -> if symbolIdEq(parentId, tid) {
            match parentUnionDeclOf(tbl, parentId) {
              case Some(decl) -> {
                val gnames = unionDeclGenericNames(decl)
                val scratch: List[Diagnostic] = newList()
                val ftypes = unionCaseFieldTypes(tbl, scratch, uc, gnames, caseSym.originPackage)
                val fnames: List[String] = newList()
                var fi = 0
                while fi < uc.fields.count {
                  match uc.fields[fi] {
                    case UFNamed(nm, _, _) -> fnames.add(nm)
                    case UFPos(_, _) -> fnames.add("")
                  }
                  fi = fi + 1
                }
                Some(value = argTypesAgainstFields(cargs, fnames, ftypes, gnames, targs))
              }
              case None -> None
            }
          } else {
            None
          }
          case _ -> None
        }
        case None -> match constructorSymbolOf(tbl, fn) {
          case Some(sym) -> match symbolTypeIdOpt(sym) {
            case Some(sid) -> if symbolIdEq(sid, tid) {
              val gnames: List[String] = if ctorIsGeneric(sym) { ctorGenericNames(sym) } else { newList() }
              Some(value = argTypesAgainstFields(cargs, ctorFieldNames(sym), ctorFieldTypes(tbl, sym, gnames), gnames, targs))
            } else {
              None
            }
            case None -> None
          }
          case None -> None
        }
      }
    }
    case _ -> None
  }
}

// Each constructor argument flows into its field: a named argument into the
// field it names, a positional one into the first field no argument names,
// left to right (`argTypesInFieldOrder`'s pairing).  The result holds, per
// argument, its field's type with `gnames` bound to `targs` (`TyError` when
// the argument fills no field).
func argTypesAgainstFields(
  cargs: in List[CallArg],
  fnames: in List[String],
  ftypes: in List[Type],
  gnames: in List[String],
  targs: in List[Type],
): List[Type] {
  val occupied: List[Bool] = newList()
  var oi = 0
  while oi < fnames.count {
    occupied.add(false)
    oi = oi + 1
  }
  val slots: List[Int] = newList()
  var ai = 0
  while ai < cargs.count {
    var slot = -1
    match cargs[ai] {
      case CANamed(nm, _, _) -> {
        var j = 0
        while j < fnames.count {
          if fnames[j] == nm and nm != "" {
            slot = j
            occupied[j] = true
            j = fnames.count
          } else {
            j = j + 1
          }
        }
      }
      case CAPositional(_) -> ()
    }
    slots.add(slot)
    ai = ai + 1
  }
  var pi = 0
  while pi < cargs.count {
    match cargs[pi] {
      case CAPositional(_) -> {
        var j = 0
        while j < fnames.count {
          if not occupied[j] {
            slots[pi] = j
            occupied[j] = true
            j = fnames.count
          } else {
            j = j + 1
          }
        }
      }
      case CANamed(_, _, _) -> ()
    }
    pi = pi + 1
  }
  val expected: List[Type] = newList()
  var k = 0
  while k < cargs.count {
    val slot = slots[k]
    if slot >= 0 and slot < ftypes.count {
      expected.add(substituteTyVars(ftypes[slot], gnames, targs))
    } else {
      expected.add(TyError)
    }
    k = k + 1
  }
  expected
}

// `recv.add(...)` stores into the open binding `recv` names: `add(x)` and
// `add(i, x)` on a one-parameter collection fix its element to `x`'s type,
// `add(k, v)` on a two-parameter one its key and value.
pub func noteOpenBindingAdd(sc: in Scope, tbl: in SymbolTable, recv: in Expr, argTypes: in List[Type]): Unit {
  if tbl.openBindingSites.count == 0 {
    return
  }
  val key = openSiteOfExpr(sc, recv)
  if key == "" {
    return
  }
  match mapGet(tbl.openBindingSites, key) {
    case Some(site) -> match site.initTy {
      case TyUser(id, nm, iargs) -> {
        val filled: List[Type] = newList()
        if iargs.count == 1 and (argTypes.count == 1 or argTypes.count == 2) {
          filled.add(argTypes[argTypes.count - 1])
        } else if iargs.count == 2 and argTypes.count == 2 {
          filled.add(argTypes[0])
          filled.add(argTypes[1])
        }
        if filled.count == iargs.count {
          noteOpenBindingType(tbl, key, TyUser(id = id, name = nm, args = filled), false, sc.genericNames)
        }
      }
      case _ -> ()
    }
    case None -> ()
  }
}

// One parameter of an element-taking member of the stdlib `List`, `Map` or
// `Set` (#7969): its type, and what it is for the receiver -- "element",
// "key", "value" or "index" -- so a mismatch names the slot it misses.
record CollMemberParam {
  ty: Type
  role: String
}

func collParam(ty: in Type, role: in String): CollMemberParam {
  CollMemberParam(ty = ty, role = role)
}

// The result type of an element-taking member of the stdlib `List[T]` or
// `Map[K, V]` that `stdCollectionMemberParams` checks: `Unit` for the members
// that only mutate the collection — `List.add(item)`, `List.add(index, item)`,
// `List.removeAt(index)` and `Map.add(key, value)` (void on every backend).
// Any other member's result is still left unknown (`TyError`).  Without it a
// lambda ending in `xs.add(x)` was typed `(T) -> <error>` rather than
// `(T) -> Unit`, so the backends could not tell it returns `Unit` (#8299).
func stdCollectionMemberResult(tbl: in SymbolTable, recvTy: in Type, name: in String, argCount: in Int): Type {
  match unrefine(recvTy) {
    case TyUser(id, _, targs) -> {
      val isList = targs.count == 1 and isStdCollectionsHostType(tbl, id, "List")
      val isMap = targs.count == 2 and isStdCollectionsHostType(tbl, id, "Map")
      val unitResult = (isList and name == "add" and (argCount == 1 or argCount == 2)) or
        (isList and name == "removeAt" and argCount == 1) or
        (isMap and name == "add" and argCount == 2)
      val isSet = targs.count == 1 and isStdCollectionsHostType(tbl, id, "Set")
      // Membership tests and `remove` (true iff something was removed) are
      // `Bool` and positions `Int` on every backend, so a mistyped use
      // (`val s: String = xs.contains(x)`) is reported (#7978).
      val boolResult = (argCount == 1) and
        (
          (isList and name == "contains") or (isMap and name == "containsKey") or
            (isSet and name == "contains") or
            ((isList or isMap or isSet) and name == "remove")
        )
      val intResult = isList and argCount == 1 and (name == "indexOf" or name == "lastIndexOf")
      if unitResult {
        TyPrim(pt = PtUnit)
      } else if boolResult {
        TyPrim(pt = PtBool)
      } else if intResult {
        TyPrim(pt = PtInt)
      } else {
        TyError
      }
    }
    case _ -> TyError
  }
}

// The argument counts the stdlib `List`/`Map`/`Set` member `name` accepts,
// or an empty list for a member not listed here (an open BCL/JDK method the
// backends resolve by name).
func stdCollectionMemberArities(tbl: in SymbolTable, recvTy: in Type, name: in String): List[Int] {
  val ns: List[Int] = newList()
  match unrefine(recvTy) {
    case TyUser(id, _, targs) -> {
      if targs.count == 1 and isStdCollectionsHostType(tbl, id, "List") {
        if name == "add" {
          ns.add(1)
          ns.add(2)
        } else if name == "contains" or name == "indexOf" or name == "lastIndexOf" or name == "remove" or name == "removeAt" {
          ns.add(1)
        }
      } else if targs.count == 2 and isStdCollectionsHostType(tbl, id, "Map") {
        if name == "add" {
          ns.add(2)
        } else if name == "containsKey" or name == "remove" {
          ns.add(1)
        }
      } else if targs.count == 1 and isStdCollectionsHostType(tbl, id, "Set") {
        if name == "add" or name == "contains" or name == "remove" {
          ns.add(1)
        }
      }
    }
    case _ -> ()
  }
  ns
}

// T0042 for a call of a listed stdlib collection member with an argument
// count it does not take (#7978).
func checkStdCollectionMemberArity(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  recvTy: in Type,
  name: in String,
  argCount: in Int,
  span: in Span,
): Unit {
  val ns = stdCollectionMemberArities(tbl, recvTy, name)
  if ns.count == 0 or ns.contains(argCount) {
    return
  }
  val want = if ns.count == 1 { toString(ns[0]) } else { toString(ns[0]) + " or " + toString(ns[1]) }
  diag.add(
    errorDiagnostic(
      "T0042",
      "'." + name + "' on " + renderType(recvTy) + " takes " + want + " argument(s), got " + toString(argCount),
      span
    )
  )
}

// The parameters of `recv.<name>(...)` with `argCount` arguments when `recv`
// is the stdlib `List[T]`, `Map[K, V]` or `Set[T]` and `name` is one of the
// members that take an element, key, value or index; `None` otherwise.  These
// collections are extern types whose methods the backends resolve, so their
// signatures are not in the checker's signature tables (#7969).  Which form a
// two-argument `add` is follows the receiver (#7797).
func stdCollectionMemberParams(
  tbl: in SymbolTable, recvTy: in Type, name: in String, argCount: in Int
): Option[List[CollMemberParam]] {
  val ps: List[CollMemberParam] = newList()
  match unrefine(recvTy) {
    case TyUser(id, _, targs) -> {
      if targs.count == 1 and isStdCollectionsHostType(tbl, id, "List") {
        val elem = targs[0]
        if name == "add" and argCount == 2 {
          ps.add(collParam(TyPrim(pt = PtInt), "index"))
          ps.add(collParam(elem, "element"))
        } else if argCount == 1 {
          if name == "add" or name == "contains" or name == "indexOf" or name == "lastIndexOf" or name == "remove" {
            ps.add(collParam(elem, "element"))
          } else if name == "removeAt" {
            ps.add(collParam(TyPrim(pt = PtInt), "index"))
          }
        }
      } else if targs.count == 2 and isStdCollectionsHostType(tbl, id, "Map") {
        if name == "add" and argCount == 2 {
          ps.add(collParam(targs[0], "key"))
          ps.add(collParam(targs[1], "value"))
        } else if argCount == 1 and (name == "containsKey" or name == "remove") {
          ps.add(collParam(targs[0], "key"))
        }
      } else if targs.count == 1 and isStdCollectionsHostType(tbl, id, "Set") {
        if argCount == 1 and (name == "add" or name == "contains" or name == "remove") {
          ps.add(collParam(targs[0], "element"))
        }
      }
    }
    case _ -> ()
  }
  if ps.count == 0 {
    None
  } else {
    Some(value = ps)
  }
}

// The parameter types of `stdCollectionMemberParams`'s result, in order.
func collMemberParamTypes(ps: in List[CollMemberParam]): List[Type] {
  val tys: List[Type] = newList()
  var i = 0
  while i < ps.count {
    tys.add(ps[i].ty)
    i = i + 1
  }
  tys
}

// Check each argument of an element-taking stdlib collection member call
// against the receiver's element, key or value type (#7969) under the rules
// of an ordinary call argument: numeric widening, interface conformance and a
// bracket literal where a `List` is expected are accepted.
func checkStdCollectionMemberArgs(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  recvTy: in Type,
  name: in String,
  ps: in List[CollMemberParam],
  args: in List[CallArg],
  argTypes: in List[Type],
  genericNames: in List[String],
  span: in Span,
): Unit {
  var k = 0
  while k < ps.count and k < args.count and k < argTypes.count {
    val p = ps[k]
    if (not argSatisfiesParam(tbl, p.ty, argTypes[k]) and not literalArgSatisfiesParam(tbl, p.ty, argTypes[k], callArgExpr(args[k]))) or rigidVarClash(tbl, p.ty, argTypes[k], genericNames) {
      val slot = if p.role == "index" {
        "the index type " + renderType(p.ty)
      } else {
        renderType(recvTy) + "'s " + p.role + " type " + renderType(p.ty)
      }
      diag.add(
        errorDiagnostic(
          "T0043",
          argTypeMismatchSubject(argTypes[k], args, k) + " of '." + name + "' does not match " + slot +
            typeMismatchHint(tbl, p.ty, argTypes[k]),
          span
        )
      )
    }
    k = k + 1
  }
}

// An argument of an element-taking stdlib collection member call that widens
// to the element, key or value type is recorded (#7805): the collections are
// extern types, so no signature tells a backend to convert it.
func recordCollectionArgWidenings(
  tbl: in SymbolTable,
  ps: in List[CollMemberParam],
  args: in List[CallArg],
  argTypes: in List[Type],
): Unit {
  if args.count != argTypes.count {
    return
  }
  var k = 0
  while k < ps.count and k < args.count {
    recordUnsignedWidening(tbl, ps[k].ty, argTypes[k], callArgExpr(args[k]))
    noteRangeSlot(tbl, ps[k].ty, callArgExpr(args[k]), "element")
    k = k + 1
  }
}

// An assignment `target = value` with `value` of type `valueTy`: `o = v`
// stores into the open binding `o`, `xs[i] = v` into the element of the open
// list `xs`, and `m[k] = v` into the key and value of the open map `m`.
pub func noteOpenBindingAssign(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  target: in Expr,
  valueTy: in Type,
): Unit {
  if tbl.openBindingSites.count == 0 {
    return
  }
  match target.kind {
    case EPath(_) -> {
      val key = openSiteOfExpr(sc, target)
      if key != "" {
        noteOpenBindingType(tbl, key, valueTy, false, sc.genericNames)
      }
    }
    case EIndex(recv, idxs) -> if idxs.count == 1 and openSiteOfExpr(sc, recv) != "" {
      val scratch: List[Diagnostic] = newList()
      val argTys: List[Type] = newList()
      if openBindingInitArity(tbl, openSiteOfExpr(sc, recv)) == 2 {
        argTys.add(inferExpr(sc, tbl, sigs, scratch, idxs[0]))
      }
      argTys.add(valueTy)
      noteOpenBindingAdd(sc, tbl, recv, argTys)
    }
    case _ -> ()
  }
}

// How many type arguments the open binding `key`'s type has.
func openBindingInitArity(tbl: in SymbolTable, key: in String): Int {
  match mapGet(tbl.openBindingSites, key) {
    case Some(site) -> match site.initTy { case TyUser(_, _, a) -> a.count; case _ -> 0 }
    case None -> 0
  }
}

// Each open binding whose uses agree on its type gets that type as its
// annotation (`SymbolTable.localBindingTypeSites`).  A sink is exact — it is
// the type the value must have where it is used — so the first one wins; a
// store only says what was put in (an `Int` added to what a `List[Long]`
// parameter receives), so the stores decide only when nothing sinks the
// binding.  Disagreeing sinks, or disagreeing stores with no sink, leave the
// binding as it was.  A name bound to a sub-tuple has no annotation of its
// own (its tuple's carries its type); only the names patterns bind from it
// are recorded.
pub func resolveOpenBindingSites(tbl: in SymbolTable): Unit {
  foldOpenCaseArgs(tbl)
  val keys = mapKeys(tbl.openBindingSites)
  var i = 0
  while i < keys.count {
    match mapGet(tbl.openBindingSites, keys[i]) {
      case Some(site) -> if site.parentKey != "" {
        if site.childKeys.count > 0 {
          val _ = resolveOpenTupleSite(tbl, site)
        }
      } else {
        val te: Option[TypeExpr] = if site.childKeys.count > 0 {
          resolveOpenTupleSite(tbl, site)
        } else {
          match openSiteChoice(site) {
            case 1 -> Some(value = site.sinkTe[0])
            case 2 -> Some(value = site.storeTe[0])
            case _ -> None
          }
        }
        match te {
          case Some(t) -> if not tbl.localBindingTypeSites.containsKey(keys[i]) { tbl.localBindingTypeSites.add(keys[i], t) }
          case None -> ()
        }
      }
      case None -> ()
    }
    i = i + 1
  }
}

// Which evidence decides an element site's type: 1 its first sink, 2 its
// first store, 0 none (see `resolveOpenBindingSites`).
func openSiteChoice(site: in OpenBindingSite): Int {
  if site.sinkTe.count > 0 {
    if site.sinkConflict.count == 0 {
      1
    } else {
      0
    }
  } else if site.storeTe.count > 0 and site.storeConflict.count == 0 {
    2
  } else {
    0
  }
}

// The resolved type of the open site `key`, when its uses fixed one: an
// element site's chosen sink or store, or a tuple site's own type with each
// child's resolved type in place.
func openSiteResolvedType(tbl: in SymbolTable, key: in String): Option[Type] {
  match mapGet(tbl.openBindingSites, key) {
    case Some(site) -> if site.childKeys.count > 0 {
      var t = site.initTy
      var ci = 0
      while ci < site.childKeys.count {
        match openSiteResolvedType(tbl, site.childKeys[ci]) {
          case Some(ct) -> {
            t = tupleTypeWith(t, site.childPaths[ci], 0, ct)
          }
          case None -> return None
        }
        ci = ci + 1
      }
      Some(value = t)
    } else {
      match openSiteChoice(site) {
        case 1 -> Some(value = site.sinkTy[0])
        case 2 -> Some(value = site.storeTy[0])
        case _ -> None
      }
    }
    case None -> None
  }
}

// A tuple site's annotation, once every child has a type (#7855).  Each
// element the await / `?` hoist binds one by one is recorded at its position
// in it too, as `recordHoistedOperands` records an operand whose position's
// type is known while checking.
func resolveOpenTupleSite(tbl: in SymbolTable, site: in OpenBindingSite): Option[TypeExpr] {
  match openSiteResolvedType(tbl, recordCopySiteKey(site.initSpan)) {
    case Some(t) -> {
      if not typeIsClosedOver(t, site.typeParams) {
        return None
      }
      var hi = 0
      while hi < site.hoistExprs.count {
        match tupleTypeAt(site.initTy, site.hoistPaths[hi]) {
          case Some(own) -> match tupleTypeAt(t, site.hoistPaths[hi]) {
            case Some(expected) -> recordHoistOperandTypeOver(
              tbl,
              site.typeParams,
              site.hoistExprs[hi],
              own,
              expected
            )
            case None -> ()
          }
          case None -> ()
        }
        hi = hi + 1
      }
      var pi = 0
      while pi < site.patSpans.count {
        match tupleTypeAt(t, site.patPaths[pi]) {
          case Some(et) -> recordTuplePatternBinding(tbl, site.patSpans[pi], et, site.typeParams)
          case None -> ()
        }
        pi = pi + 1
      }
      typeExprForOpenBinding(tbl, t, site.initSpan, site.typeParams)
    }
    case None -> None
  }
}

// Record a call through a function value (see `SymbolTable.funcValueCallSites`).
// Only a callee that is certainly a value is recorded: a local binding, a
// record field, or any other value-producing expression (a call, an index, a
// block) — never a function or builtin name, which the call reaches by name.
// A call whose function is async, returns `Unit` (the result is discarded,
// and a `() -> Unit` binding is a real `Action` the erased value is not) or
// never returns, or whose type has no source spelling, is left as written.  A
// type parameter of the enclosing declaration is spelled by its name, as
// `recordLocalFuncType` spells it (#8292).
func recordFuncValueCall(
  sc: in Scope,
  tbl: in SymbolTable,
  fn: in Expr,
  memberRecvTy: in Option[Type],
  memberName: in String,
  fnT: in Type,
  argCount: in Int,
  sp: in Span,
): Unit {
  if isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return
  }
  match unrefine(fnT) {
    case TyFunction(ps, ret, isAsync) -> {
      val noValue = match unrefine(ret) {
        case TyPrim(pt) -> match pt { case PtUnit -> true; case PtNever -> true; case _ -> false }
        case _ -> false
      }
      if isAsync or noValue or ps.count != argCount {
        return
      }
      if not calleeIsFuncValue(sc, tbl, fn, memberRecvTy, memberName) {
        return
      }
      match typeExprForRefWithVars(tbl, unrefine(fnT), fn.span) {
        case Some(te) -> {
          val key = recordCopySiteKey(sp)
          val rendered = renderType(fnT)
          match mapGet(tbl.funcValueCallSites, key) {
            case Some(prev) -> if prev.rendered != rendered and not prev.conflicting {
              tbl.funcValueCallSites.remove(key)
              tbl.funcValueCallSites.add(
                key,
                FuncValueCallSite(
                  calleeType = prev.calleeType,
                  rendered = prev.rendered,
                  conflicting = true,
                  startOffset = prev.startOffset
                )
              )
            }
            case None -> tbl.funcValueCallSites.add(
              key,
              FuncValueCallSite(
                calleeType = te,
                rendered = rendered,
                conflicting = false,
                startOffset = sp.startPos.offset
              )
            )
          }
        }
        case None -> ()
      }
    }
    case _ -> ()
  }
}

// Record the names a tuple pattern binds (see
// `SymbolTable.tuplePatternBindingSites`).  `pat` is matched against a value
// of type `ty`, which may name `typeParams`, the enclosing function's type
// parameters (#7863); `inTuple` is whether `pat` is an element of an
// enclosing tuple pattern, or the loop pattern of a `for` over a generator,
// whose elements arrive just as erased (#7750).  Only a name bound to such an element is
// recorded: any other name is bound to a value whose type the backend already
// sees.  An or-pattern is
// not entered, because every alternative must bind the same names, and a
// nullary union-case name is a test rather than a binding.
func recordTuplePatternBindings(
  tbl: in SymbolTable,
  pat: in Pattern,
  ty: in Type,
  inTuple: in Bool,
  typeParams: in List[String],
): Unit {
  match pat.kind {
    case PBinding(name, innerOpt) -> {
      if inTuple and name != "_" and not isConstructorPatternName(tbl, name) and not scrutineeHasCaseNamed(tbl, ty, name) {
        recordTuplePatternBinding(tbl, pat.span, ty, typeParams)
      }
      match innerOpt {
        case Some(inner) -> recordTuplePatternBindings(tbl, inner, ty, false, typeParams)
        case None -> ()
      }
    }
    case PTuple(patterns) -> match unrefine(ty) {
      case TyTuple(elems) -> if elems.count == patterns.count {
        var i = 0
        while i < patterns.count {
          recordTuplePatternBindings(tbl, patterns[i], elems[i], true, typeParams)
          i = i + 1
        }
      }
      case _ -> ()
    }
    case PParen(inner) -> recordTuplePatternBindings(tbl, inner, ty, inTuple, typeParams)
    case _ -> ()
  }
}

// Record one tuple-element binding at `sp` with checked type `ty`.  A type
// with no value (`Unit`, `Never`) or no source spelling (an element the
// checker could not type, a type variable other than one of `typeParams`) is
// left as written.  One of `typeParams` is spelled by its name: `Lyric.Mono`
// substitutes it where it specialises the body, as it does the function's
// own annotations (#7863).
func recordTuplePatternBinding(tbl: in SymbolTable, sp: in Span, ty: in Type, typeParams: in List[String]): Unit {
  if isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return
  }
  val noValue = match unrefine(ty) {
    case TyPrim(pt) -> match pt { case PtUnit -> true; case PtNever -> true; case _ -> false }
    case _ -> false
  }
  if noValue {
    return
  }
  match typeExprForOpenBinding(tbl, ty, sp, typeParams) {
    case Some(te) -> {
      val key = recordCopySiteKey(sp)
      val rendered = renderType(ty)
      match mapGet(tbl.tuplePatternBindingSites, key) {
        case Some(prev) -> if prev.rendered != rendered and not prev.conflicting {
          tbl.tuplePatternBindingSites.remove(key)
          tbl.tuplePatternBindingSites.add(
            key,
            TuplePatternBindingSite(
              bindingType = prev.bindingType,
              rendered = prev.rendered,
              conflicting = true,
              startOffset = prev.startOffset
            )
          )
        }
        case None -> tbl.tuplePatternBindingSites.add(
          key,
          TuplePatternBindingSite(
            bindingType = te,
            rendered = rendered,
            conflicting = false,
            startOffset = sp.startPos.offset
          )
        )
      }
    }
    case None -> ()
  }
}

// The join of two element types `typeEquiv` already accepted as one: each
// hole (`TyError`, an argument a construction left unconstrained, such as
// `None`'s `T` or `Ok`'s `E`) takes what the other type has in that position.
// `a` wins wherever neither is a hole.
func joinOpenTypes(a: in Type, b: in Type): Type {
  match a {
    case TyError -> return b
    case _ -> ()
  }
  match b {
    case TyError -> return a
    case _ -> ()
  }
  match a {
    case TyUser(aid, an, aargs) -> match b {
      case TyUser(bid, _, bargs) -> if symbolIdEq(aid, bid) and aargs.count == bargs.count {
        TyUser(id = aid, name = an, args = joinOpenTypeLists(aargs, bargs))
      } else {
        a
      }
      case _ -> a
    }
    case TySlice(ae) -> match b { case TySlice(be) -> TySlice(element = joinOpenTypes(ae, be)); case _ -> a }
    // Arrays of different sizes are different types: only same-sized ones join.
    case TyArray(asz, ae, asv) -> match b {
      case TyArray(bsz, be, _) -> if optIntEq(asz, bsz) {
        TyArray(size = asz, element = joinOpenTypes(ae, be), sizeVar = asv)
      } else {
        a
      }
      case _ -> a
    }
    case TyNullable(ai) -> match b { case TyNullable(bi) -> TyNullable(inner = joinOpenTypes(ai, bi)); case _ -> a }
    case TyTuple(aes) -> match b {
      case TyTuple(bes) -> if aes.count == bes.count {
        TyTuple(elems = joinOpenTypeLists(aes, bes))
      } else {
        a
      }
      case _ -> a
    }
    case _ -> a
  }
}

func joinOpenTypeLists(xs: in List[Type], ys: in List[Type]): List[Type] {
  val acc: List[Type] = newList()
  var i = 0
  while i < xs.count {
    acc.add(joinOpenTypes(xs[i], ys[i]))
    i = i + 1
  }
  acc
}

// Record the checked type `t` of a list literal typed with no collection type
// expected of it (see `SymbolTable.listLiteralTypeSites`).  Only a literal
// whose element type is or contains a generic instantiation is recorded: a
// backend builds any other element type's literal from the elements alone.
// `t` may name the enclosing function's type parameters, which `Lyric.Mono`
// substitutes when it specialises the body; a type the join leaves open
// (`[None, None]`) is left as written.
func recordListLiteralType(sc: in Scope, tbl: in SymbolTable, lit: in Expr, t: in Type): Unit {
  if not typeMentionsGenericInst(t) {
    return
  }
  recordListLiteralSite(sc, tbl, lit, t, false)
}

// Record a bracket literal `elem` that is an element of another bracket
// literal whose elements are expected to have type `elemTy`, when that is a
// slice: the literal is built as that slice, which the enclosing literal does
// not say where it is built (#8192).
func recordSliceShapedElement(sc: in Scope, tbl: in SymbolTable, elem: in Expr, elemTy: in Type): Unit {
  match unrefine(elemTy) {
    case TySlice(_) -> match bracketLiteralOf(elem) {
      case Some(lit) -> recordListLiteralSite(sc, tbl, lit, unrefine(elemTy), true)
      case None -> ()
    }
    case _ -> ()
  }
}

// The bracket literal `e` is, under any parentheses.
func bracketLiteralOf(e: in Expr): Option[Expr] {
  match e.kind {
    case EParen(inner) -> bracketLiteralOf(inner)
    case EList(_) -> Some(value = e)
    case _ -> None
  }
}

// Record the list literal `lit` in `SymbolTable.listLiteralTypeSites` at the
// type `t`, which may name the enclosing function's type parameters
// (`Lyric.Mono` substitutes them when it specialises the body); a type the
// join leaves open (`[None, None]`) is left as written.  `shapeRequired`
// marks a literal whose position alone fixes its shape
// (`recordSliceShapedElement`).
func recordListLiteralSite(sc: in Scope, tbl: in SymbolTable, lit: in Expr, t: in Type, shapeRequired: in Bool): Unit {
  val sp = lit.span
  if isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return
  }
  if not typeIsClosedOver(t, sc.genericNames) {
    return
  }
  match typeExprForOpenBinding(tbl, t, sp, sc.genericNames) {
    case Some(te) -> {
      val key = recordCopySiteKey(sp)
      val rendered = renderType(t)
      match mapGet(tbl.listLiteralTypeSites, key) {
        case Some(prev) -> if prev.conflicting {
          ()
        } else if prev.rendered != rendered {
          markListLiteralConflicting(tbl, key, prev.literalType, prev.rendered, prev.startOffset)
        } else if shapeRequired and not prev.shapeRequired {
          tbl.listLiteralTypeSites.remove(key)
          tbl.listLiteralTypeSites.add(
            key,
            ListLiteralTypeSite(
              literalType = prev.literalType,
              rendered = prev.rendered,
              conflicting = false,
              startOffset = prev.startOffset,
              shapeRequired = true
            )
          )
        }
        case None -> tbl.listLiteralTypeSites.add(
          key,
          ListLiteralTypeSite(
            literalType = te,
            rendered = rendered,
            conflicting = false,
            startOffset = sp.startPos.offset,
            shapeRequired = shapeRequired
          )
        )
      }
    }
    case None -> ()
  }
}

// A list literal checked where a `List` is expected (an annotated binding, a
// `List` parameter or field) is built as that `List`, so it is never
// recorded in `SymbolTable.listLiteralTypeSites`, even when another pass
// typed it with nothing expected (#7818).
func noteListLiteralInListContext(tbl: in SymbolTable, lit: in Expr): Unit {
  val sp = lit.span
  if isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return
  }
  val key = recordCopySiteKey(sp)
  match mapGet(tbl.listLiteralTypeSites, key) {
    case Some(prev) -> if not prev.conflicting {
      markListLiteralConflicting(tbl, key, prev.literalType, prev.rendered, prev.startOffset)
    }
    case None -> markListLiteralConflicting(tbl, key, TypeExpr(kind = TUnit, span = sp), "", sp.startPos.offset)
  }
}

func markListLiteralConflicting(
  tbl: in SymbolTable,
  key: in String,
  te: in TypeExpr,
  rendered: in String,
  startOffset: in Int,
): Unit {
  if tbl.listLiteralTypeSites.containsKey(key) {
    tbl.listLiteralTypeSites.remove(key)
  }
  tbl.listLiteralTypeSites.add(
    key,
    ListLiteralTypeSite(
      literalType = te,
      rendered = rendered,
      conflicting = true,
      startOffset = startOffset,
      shapeRequired = false
    )
  )
}

// ── Operands the await / `?` hoist binds (#7823) ─────────────────────────────
//
// `Lyric.AwaitHoist` and `Lyric.Propagate`'s hoist bind every operand
// evaluated before an `await` or a `?` in the same expression to a fresh
// local.  The local had no annotation, so a backend with reified generics
// typed it from the value alone: `add(None, await f())` built the `None` as
// an `Option<object>` and passed it where an `Option<int>` was expected.  The
// operand's type here is its own type with each hole (`None`'s `T`, `Ok`'s
// `E`) filled from the type its position expects; `Lyric.Mono` binds the
// operand to a local of that type, and the hoist keeps the annotation.
// Record the operands of `es` evaluated before the last one containing an
// `await` or a `?`: operand `i` has its own type `owns[i]` and sits where
// `expected[i]` is expected (`TyError` when nothing is).  A tuple literal
// holding the hazard is walked the same way, since the hoist binds its
// earlier elements one by one.
func recordHoistedOperands(
  sc: in Scope,
  tbl: in SymbolTable,
  es: in List[Expr],
  owns: in List[Type],
  expected: in List[Type],
): Unit {
  var last = -1
  var i = 0
  while i < es.count {
    if HoistEngine.exprHasHoistHazard(es[i]) {
      last = i
    }
    i = i + 1
  }
  if last < 0 {
    return
  }
  var k = 0
  while k < last {
    recordHoistOperandType(sc, tbl, es[k], hoistTypeAt(owns, k), hoistTypeAt(expected, k))
    k = k + 1
  }
  recordHoistedComposite(sc, tbl, es[last], hoistTypeAt(owns, last), hoistTypeAt(expected, last))
}

// The operand `e` that holds the hazard.  The hoist binds an `if`, `match`
// or block whose arms hold it, and a short-circuit operator, as a whole, so
// such an `e` is recorded itself; a tuple literal's elements are hoisted one
// by one, so they are recorded instead.
func recordHoistedComposite(sc: in Scope, tbl: in SymbolTable, e: in Expr, own: in Type, expected: in Type): Unit {
  match e.kind {
    case EParen(inner) -> recordHoistedComposite(sc, tbl, inner, own, expected)
    case ETuple(_) -> recordHoistedTupleElems(sc, tbl, e, own, expected)
    case EIf(_, _, _, _) -> recordHoistOperandType(sc, tbl, e, own, expected)
    case EMatch(_, _) -> recordHoistOperandType(sc, tbl, e, own, expected)
    case EBlock(_) -> recordHoistOperandType(sc, tbl, e, own, expected)
    case EUnsafe(_) -> recordHoistOperandType(sc, tbl, e, own, expected)
    case EBinop(op, _, _) -> if binopShortCircuits(op) { recordHoistOperandType(sc, tbl, e, own, expected) }
    case _ -> ()
  }
}

// An assignment to a field or an element (`b.o = <value>`) reads its target
// before its value, so the hoist binds a value holding an `await` or a `?` as
// a whole; it has the target's type.
func recordHoistedAssignValue(
  sc: in Scope,
  tbl: in SymbolTable,
  target: in Expr,
  value: in Expr,
  valueType: in Type,
  targetType: in Type,
): Unit {
  val stacks = match target.kind {
    case EMember(_, _) -> true
    case EIndex(_, _) -> true
    case EParen(_) -> true
    case _ -> false
  }
  if stacks and HoistEngine.exprHasHoistHazard(value) {
    recordHoistOperandType(sc, tbl, value, valueType, targetType)
  }
}

func hoistTypeAt(ts: in List[Type], i: in Int): Type {
  if i < ts.count {
    ts[i]
  } else {
    TyError
  }
}

func recordHoistedTupleElems(sc: in Scope, tbl: in SymbolTable, e: in Expr, own: in Type, expected: in Type): Unit {
  match e.kind {
    case EParen(inner) -> recordHoistedTupleElems(sc, tbl, inner, own, expected)
    case ETuple(elems) -> recordHoistedOperands(
      sc,
      tbl,
      elems,
      hoistTupleElemTypes(own, elems.count),
      hoistTupleElemTypes(unrefine(expected), elems.count)
    )
    case _ -> ()
  }
}

func hoistTupleElemTypes(t: in Type, n: in Int): List[Type] {
  match t {
    case TyTuple(elems) -> {
      if elems.count == n {
        return elems
      }
    }
    case _ -> ()
  }
  val holes: List[Type] = newList()
  var i = 0
  while i < n {
    holes.add(TyError)
    i = i + 1
  }
  holes
}

// The type a hoisted operand `e` is built at when its value is a literal
// whose runtime shape the expected type decides rather than its elements: a
// bracket literal where an `array[N, T]`, a `List[T]` or a `slice[T]` is
// expected (`inferExprExpected`'s `EList` arm builds it as that, D167), a
// tuple literal holding one, or an `if`, `match` or block whose value is one.
// `None` when `e` is no such literal.  `own` is the operand's checked type
// and `expected` the type of the position it is passed to.
func shapedOperandType(tbl: in SymbolTable, e: in Expr, own: in Type, expected: in Type): Option[Type] {
  match e.kind {
    case EParen(inner) -> shapedOperandType(tbl, inner, own, expected)
    case EList(_) -> shapedCollectionType(tbl, own, unrefine(expected))
    case ETuple(elems) -> match unrefine(expected) {
      case TyTuple(ets) -> {
        if ets.count != elems.count {
          return None
        }
        val owns = hoistTupleElemTypes(unrefine(own), elems.count)
        val ts: List[Type] = newList()
        var any = false
        var i = 0
        while i < elems.count {
          match shapedOperandType(tbl, elems[i], owns[i], ets[i]) {
            case Some(t) -> {
              any = true
              ts.add(t)
            }
            case None -> ts.add(joinOpenTypes(owns[i], unrefine(ets[i])))
          }
          i = i + 1
        }
        if any {
          Some(value = TyTuple(elems = ts))
        } else {
          None
        }
      }
      case _ -> None
    }
    case EIf(_, thenBranch, elseBranch, _) -> match shapedBranchType(tbl, thenBranch, own, expected) {
      case Some(t) -> Some(value = t)
      case None -> match elseBranch {
        case Some(eb) -> shapedBranchType(tbl, eb, own, expected)
        case None -> None
      }
    }
    case EMatch(_, arms) -> {
      for arm in arms {
        match shapedBranchType(tbl, arm.body, own, expected) {
          case Some(t) -> return Some(value = t)
          case None -> ()
        }
      }
      None
    }
    case EBlock(blk) -> shapedBranchType(tbl, EOBBlock(block = blk), own, expected)
    case EUnsafe(blk) -> shapedBranchType(tbl, EOBBlock(block = blk), own, expected)
    case _ -> None
  }
}

func shapedBranchType(tbl: in SymbolTable, b: in ExprOrBlock, own: in Type, expected: in Type): Option[Type] {
  match branchValueExpr(b) {
    case Some(ve) -> shapedOperandType(tbl, ve, own, expected)
    case None -> None
  }
}

// The collection type a bracket literal of checked type `own` is built as
// where `expected` is expected of it, or `None` when `expected` leaves the
// literal its own shape.  The element type is `expected`'s, which each
// element is widened to (`List[Long]` from `[1, 2]`), or `own`'s where
// `expected`'s is open; an array whose length is a value parameter is not
// built from a literal (T0155).
func shapedCollectionType(tbl: in SymbolTable, own: in Type, expected: in Type): Option[Type] {
  val ownElem = collectionElemType(tbl, unrefine(own))
  match expected {
    case TyArray(sz, et, _) -> match sz {
      case Some(n) -> Some(
        value = TyArray(
          size = Some(value = n),
          element = shapedElemType(ownElem, et),
          sizeVar = ""
        )
      )
      case None -> None
    }
    case TySlice(et) -> Some(value = TySlice(element = shapedElemType(ownElem, et)))
    case TyUser(id, name, args) -> if args.count == 1 and isStdCollectionsHostType(tbl, id, "List") {
      val elemArgs: List[Type] = newList()
      elemArgs.add(shapedElemType(ownElem, args[0]))
      Some(value = TyUser(id = id, name = name, args = elemArgs))
    } else {
      None
    }
    case _ -> None
  }
}

func shapedElemTypeIn(tbl: in SymbolTable, ownElem: in Type, expectedElem: in Type): Type {
  if typeIsClosed(expectedElem) {
    return expectedElem
  }
  match unrefine(ownElem) {
    case TySlice(oe) -> match unrefine(expectedElem) {
      case TyUser(eid, ename, eargs) -> if eargs.count == 1 and isStdCollectionsHostType(tbl, eid, "List") {
        val inner: List[Type] = newList()
        inner.add(shapedElemTypeIn(tbl, oe, eargs[0]))
        return TyUser(id = eid, name = ename, args = inner)
      }
      case TySlice(ee) -> return TySlice(element = shapedElemTypeIn(tbl, oe, ee))
      case TyArray(sz, ee, sv) -> return TyArray(size = sz, element = shapedElemTypeIn(tbl, oe, ee), sizeVar = sv)
      case _ -> ()
    }
    case _ -> ()
  }
  joinOpenTypes(ownElem, expectedElem)
}

func shapedElemType(ownElem: in Type, expectedElem: in Type): Type {
  if typeIsClosed(expectedElem) {
    expectedElem
  } else {
    joinOpenTypes(ownElem, expectedElem)
  }
}

// The element type of an array, slice or stdlib `List[T]`; `TyError` (a
// hole) for any other type.
func collectionElemType(tbl: in SymbolTable, t: in Type): Type {
  match t {
    case TyArray(_, et, _) -> et
    case TySlice(et) -> et
    case TyUser(id, _, args) -> if args.count == 1 and isStdCollectionsHostType(tbl, id, "List") {
      args[0]
    } else {
      TyError
    }
    case _ -> TyError
  }
}

// Record the type of one hoisted operand `e`: `own` with its holes filled
// from `expected`, when that is a closed generic instantiation.
func recordHoistOperandType(sc: in Scope, tbl: in SymbolTable, e: in Expr, own: in Type, expected: in Type): Unit {
  if hoistBindsOperand(sc, e) {
    recordHoistOperandTypeOver(tbl, sc.genericNames, e, own, expected)
  }
}

// `recordHoistOperandType` once `e` is known to be bound by the hoist; the
// recorded type may name `typeParams`, the enclosing function's type
// parameters.  An operand whose value is a literal its position shapes
// (`shapedOperandType`) is recorded at that shape, at any element type
// including a type parameter (`array[2, T]`): typed from the literal alone,
// its local would be built as a slice of the elements' own type and then
// read as an array, a list or a slice of the widened type (#8171, #8190).
// Any other operand is recorded only at a generic instantiation, the one
// type its value alone does not give.
func recordHoistOperandTypeOver(
  tbl: in SymbolTable,
  typeParams: in List[String],
  e: in Expr,
  own: in Type,
  expected: in Type,
): Unit {
  val sp = e.span
  val shaped = shapedOperandType(tbl, e, own, expected)
  val t = match shaped { case Some(st) -> st; case None -> joinOpenTypes(own, unrefine(expected)) }
  val shapeDecides = match shaped { case Some(_) -> true; case None -> false }
  if not (shapeDecides or typeMentionsGenericInst(t)) or not typeIsClosedOver(t, typeParams) {
    return
  }
  match typeExprForOpenBinding(tbl, t, sp, typeParams) {
    case Some(te) -> {
      val key = recordCopySiteKey(sp)
      val rendered = renderType(t)
      match mapGet(tbl.hoistOperandTypeSites, key) {
        case Some(prev) -> if (prev.rendered != rendered or prev.operandKind != exprKindTag(e)) and not prev.conflicting {
          tbl.hoistOperandTypeSites.remove(key)
          tbl.hoistOperandTypeSites.add(
            key,
            HoistOperandTypeSite(
              operandType = prev.operandType,
              rendered = prev.rendered,
              conflicting = true,
              startOffset = prev.startOffset,
              operandKind = prev.operandKind
            )
          )
        }
        case None -> tbl.hoistOperandTypeSites.add(
          key,
          HoistOperandTypeSite(
            operandType = te,
            rendered = rendered,
            conflicting = false,
            startOffset = sp.startPos.offset,
            operandKind = exprKindTag(e)
          )
        )
      }
    }
    case None -> ()
  }
}

// An operand of `==` / `!=` that builds a generic value leaving a type
// argument open (`Ok(2)`, whose error type only the other operand fixes, or a
// bare `None`) is built at the type the comparison gives it, the other
// operand's, so it and the value it is compared with are one runtime type
// (#8144).  Recorded in `hoistOperandTypeSites`, which `Lyric.Mono` turns into
// a binding annotated with that type, as for an operand the hoist binds.
func recordComparedConstructionType(sc: in Scope, tbl: in SymbolTable, e: in Expr, own: in Type, other: in Type): Unit {
  val builds = match e.kind { case ECall(_, _) -> true; case EPath(_) -> true; case _ -> false }
  if not builds {
    return
  }
  val ownU = unrefine(own)
  if renderType(joinOpenTypes(ownU, unrefine(other))) == renderType(ownU) {
    return
  }
  recordHoistOperandTypeOver(tbl, sc.genericNames, e, own, other)
}

// Whether `op` evaluates its right operand only on some left values; the
// hoist binds such an operator's whole expression, not its left operand.
func binopShortCircuits(op: in BinOp): Bool {
  match op {
    case BAnd -> true
    case BOr -> true
    case BCoalesce -> true
    case BImplies -> true
    case _ -> false
  }
}

// The type the method the checker resolved for `recv.name(args)` gives a
// receiver evaluated before an `await` or a `?` in the arguments (#7844):
// its receiver parameter instantiated from the receiver, the other arguments
// and then, for what they leave open, `resultExpected` (the type expected of
// the call's result, `TyError` for none).  `TyError` when the call bound to
// no method the receiver's type declares.
func hoistedRecvType(
  tbl: in SymbolTable,
  methodPick: in Option[MethodCallPick],
  collMemberParams: in Option[List[CollMemberParam]],
  recvTy: in Type,
  name: in String,
  args: in List[CallArg],
  argTypes: in List[Type],
  resultExpected: in Type,
): Type {
  match methodPick {
    case Some(mp) -> match mp.fullSig {
      case Some(fullS) -> return methodRecvTypeFromSig(fullS, recvTy, args, argTypes, resultExpected)
      case None -> ()
    }
    case None -> match collMemberParams { case Some(_) -> (); case None -> return TyError }
  }
  // A method of the receiver's own type, or a stdlib collection member: the
  // receiver's type arguments are left as fresh variables, which the
  // method's parameters bind from the arguments.
  val pattern = match unrefine(recvTy) {
    case TyUser(tid, tname, targs) -> {
      if targs.count == 0 {
        return TyError
      }
      val vars: List[Type] = newList()
      var vi = 0
      while vi < targs.count {
        vars.add(TyVar(name = recvTypeVarName(vi)))
        vi = vi + 1
      }
      TyUser(id = tid, name = tname, args = vars)
    }
    case _ -> return TyError
  }
  match methodPick {
    case Some(_) -> {
      // Every method that fits the call (overloads, or one method reached
      // through more than one registration) must give the receiver the same
      // type.
      val cands = methodCandidatesFor(tbl, pattern, name)
      var found: Type = TyError
      var any = false
      var ci = 0
      while ci < cands.count {
        val c = cands[ci]
        if args.count <= c.params.count and minRequiredParams(c) <= args.count {
          val t = recvTypeFromMethod(c, pattern, recvTy, args, argTypes, resultExpected)
          if not any {
            found = t
            any = true
          } else if renderType(t) != renderType(found) {
            return TyError
          }
        }
        ci = ci + 1
      }
      found
    }
    case None -> match stdCollectionMemberParams(tbl, pattern, name, args.count) {
      case Some(cps) -> {
        val names = recvTypeVarNames(pattern)
        val paramTys: List[Type] = newList()
        val slotTys: List[Type] = newList()
        var k = 0
        while k < cps.count and k < argTypes.count {
          paramTys.add(cps[k].ty)
          slotTys.add(argTypes[k])
          k = k + 1
        }
        paramTys.add(pattern)
        slotTys.add(recvTy)
        substituteTyVars(pattern, names, inferGenericArgsDeep(names, paramTys, slotTys))
      }
      case None -> TyError
    }
  }
}

// The type the method `sig` of the receiver's own type, its parameters over
// `pattern`'s fresh type variables, gives a receiver of type `recvTy`.
func recvTypeFromMethod(
  sig: in ResolvedSignature,
  pattern: in Type,
  recvTy: in Type,
  args: in List[CallArg],
  argTypes: in List[Type],
  resultExpected: in Type,
): Type {
  val names = recvTypeVarNames(pattern)
  var gi = 0
  while gi < sig.generics.count {
    names.add(sig.generics[gi])
    gi = gi + 1
  }
  val paramNames: List[String] = newList()
  var pi = 0
  while pi < sig.params.count {
    paramNames.add(sig.params[pi].name)
    pi = pi + 1
  }
  val srcIdx = argIndicesInParamOrder(args, paramNames)
  val paramTys: List[Type] = newList()
  val slotTys: List[Type] = newList()
  var k = 0
  while k < srcIdx.count {
    val ai = srcIdx[k]
    if ai >= 0 and ai < argTypes.count {
      paramTys.add(sig.params[k].ty)
      slotTys.add(argTypes[ai])
    }
    k = k + 1
  }
  paramTys.add(pattern)
  slotTys.add(recvTy)
  val targs = inferGenericArgsDeep(names, paramTys, slotTys)
  fillTypeArgsFromResult(targs, names, sig.returnTy, resultExpected)
  substituteTyVars(pattern, names, targs)
}

func recvTypeVarNames(pattern: in Type): List[String] {
  val names: List[String] = newList()
  var ni = 0
  while ni < typeArgsOf(pattern).count {
    names.add(recvTypeVarName(ni))
    ni = ni + 1
  }
  names
}

func recvTypeVarName(i: in Int): String {
  "__lyric_recv_" + toString(i)
}

func typeArgsOf(t: in Type): List[Type] {
  match t {
    case TyUser(_, _, targs) -> targs
    case _ -> newList()
  }
}

// Fill each type argument in `targs` (for `names`) that the call left open
// from the type expected of its result, `resultExpected`, against the
// declared result type `retTy`.
func fillTypeArgsFromResult(targs: in List[Type], names: in List[String], retTy: in Type, resultExpected: in Type): Unit {
  if typeIsHole(resultExpected) or typeIsHole(retTy) {
    return
  }
  val retTys: List[Type] = newList()
  retTys.add(retTy)
  val resTys: List[Type] = newList()
  resTys.add(unrefine(resultExpected))
  val fromResult = inferGenericArgsDeep(names, retTys, resTys)
  var g = 0
  while g < targs.count and g < fromResult.count {
    targs[g] = joinOpenTypes(targs[g], fromResult[g])
    g = g + 1
  }
}

// The type a method call's full signature `fullS` (a dot-named function,
// receiver parameter included) gives its receiver.
func methodRecvTypeFromSig(
  fullS: in ResolvedSignature,
  recvTy: in Type,
  args: in List[CallArg],
  argTypes: in List[Type],
  resultExpected: in Type,
): Type {
  if fullS.params.count == 0 or args.count > fullS.params.count - 1 {
    return TyError
  }
  val selfTy = fullS.params[0].ty
  if fullS.generics.count == 0 {
    return selfTy
  }
  val paramNames: List[String] = newList()
  var pi = 1
  while pi < fullS.params.count {
    paramNames.add(fullS.params[pi].name)
    pi = pi + 1
  }
  val srcIdx = argIndicesInParamOrder(args, paramNames)
  val targs = sigCallTypeArgsInOrder(fullS, Some(value = recvTy), srcIdx, argTypes)
  fillTypeArgsFromResult(targs, fullS.generics, fullS.returnTy, resultExpected)
  substituteTyVars(selfTy, fullS.generics, targs)
}

// A receiver the hoist binds whose type neither it nor the method's signature
// fixes (`emptyCell().size(await f())` for `func emptyCell[T](): Cell[T]` and
// `size(self: in Cell[T], k: in Int)`) would be built at an open
// instantiation by a backend with reified generics, so it is an error: the
// program annotates it (#7844).
func reportOpenHoistedReceiver(
  sc: in Scope,
  diag: in List[Diagnostic],
  recv: in Expr,
  own: in Type,
  expected: in Type,
  memberName: in String,
  hazard: in Bool,
): Unit {
  if not hoistBindsOperand(sc, recv) or not typeMentionsGenericInst(own) {
    return
  }
  val t = joinOpenTypes(own, unrefine(expected))
  if typeIsClosedOver(t, sc.genericNames) {
    return
  }
  val why = if hazard {
    "it is evaluated before an 'await' or '?' in the arguments, and neither the receiver, the other arguments " +
      "nor the type expected of the result fixes them"
  } else {
    "neither the receiver, the arguments nor the type expected of the result fixes them"
  }
  diag.add(
    errorDiagnostic(
      "T0154",
      "cannot infer the type arguments of the receiver of '" + memberName + "': " + why +
        "; bind the receiver to a local with a type annotation first",
      recv.span
    )
  )
}

// Whether the callee `fn` is a member call whose receiver is itself a call
// that leaves a type argument of its result open.
func openCallReceiver(sc: in Scope, fn: in Expr, memberRecvTy: in Option[Type]): Bool {
  match fn.kind {
    case EMember(recv, _) -> match stripExprParens(recv).kind {
      case ECall(_, _) -> match memberRecvTy {
        case Some(t) -> typeMentionsGenericInst(unrefine(t)) and
          not typeIsClosedOver(unrefine(t), sc.genericNames)
        case None -> false
      }
      case _ -> false
    }
    case _ -> false
  }
}

// Whether any argument of a call contains an `await` or a `?`.
func callArgsHaveHoistHazard(args: in List[CallArg]): Bool {
  var i = 0
  while i < args.count {
    if HoistEngine.exprHasHoistHazard(callArgExpr(args[i])) {
      return true
    }
    i = i + 1
  }
  false
}

// A bracket literal argument where its parameter is a stdlib `List` types
// (and is built) as that `List` (docs/01 §2.7), with its elements checked
// against the `List`'s element type, so an element that is itself a literal
// takes the shape that type gives it (#8192); one where its parameter is a
// slice of slices is checked against it for the same reason.
func adoptListLiteralArgs(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  args: in List[CallArg],
  argTypes: in List[Type],
  sig: in ResolvedSignature,
  resultExpected: in Type,
): Unit {
  if sig.isExternFunc {
    return
  }
  val names: List[String] = newList()
  val paramTys: List[Type] = newList()
  for p in sig.params {
    names.add(p.name)
    paramTys.add(p.ty)
  }
  adoptLiteralArgsOver(
    sc,
    tbl,
    sigs,
    diag,
    sig.generics,
    names,
    paramTys,
    args,
    argTypes,
    "T0043",
    "parameter",
    sig.returnTy,
    resultExpected
  )
}

// `adoptListLiteralArgs` over the parameters (or fields) `names` of types
// `paramTys`, which may name the type parameters `generics`.  The literals
// are adopted one at a time, in parameter order, each against its parameter
// instantiated from the arguments that are not literals and the literals
// adopted before it: the literal's own type, a slice, would contradict the
// `List` another argument binds a type parameter to (`pick(base, [1, 2])`,
// #8191) and binds nothing in a `List[T]` (`size([1, 2, 3])`, #8193), while
// an earlier literal's `List` does bind it (`k([1], ["s"])` binds `T` to
// `Int` and so rejects `["s"]`).  A type parameter left open takes the
// literal's own element type.  A literal whose elements do not fit a
// parameter that names a type parameter is reported here (`code`), since the
// parameter's own check sees only the open type; one at a closed parameter
// keeps its own type for that check to report.  An adopted `List` literal is
// recorded at its type (`hoistOperandTypeSites`), so a backend that does not
// see the parameter where it builds the argument (a method's, a generic
// record's field) builds it as that `List`.
func adoptLiteralArgsOver(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  generics: in List[String],
  names: in List[String],
  paramTys: in List[Type],
  args: in List[CallArg],
  argTypes: in List[Type],
  code: in String,
  slotWord: in String,
  retTy: in Type,
  resultExpected: in Type,
): Unit {
  if args.count > names.count or argTypes.count < args.count {
    return
  }
  val srcIdx = argIndicesInParamOrder(args, names)
  val current: List[Type] = newList()
  var any = false
  var i = 0
  while i < args.count {
    if argIsListLiteral(callArgExpr(args[i])) {
      any = true
      current.add(TyError)
    } else {
      current.add(argTypes[i])
    }
    i = i + 1
  }
  if not any {
    return
  }
  var k = 0
  while k < srcIdx.count and k < paramTys.count {
    val ai = srcIdx[k]
    if ai >= 0 and ai < args.count and argIsListLiteral(callArgExpr(args[ai])) {
      val expected = if generics.count > 0 {
        val slots: List[Type] = newList()
        var j = 0
        while j < srcIdx.count {
          val aj = srcIdx[j]
          slots.add(if aj >= 0 and aj < current.count { current[aj] } else { TyError })
          j = j + 1
        }
        val fromArgs = inferGenericArgsDeep(generics, paramTys, slots)
        substituteTyVars(paramTys[k], generics, bindOpenFromResult(generics, fromArgs, retTy, resultExpected))
      } else {
        paramTys[k]
      }
      val lit = callArgExpr(args[ai])
      val r = adoptLiteralAt(sc, tbl, sigs, lit, argTypes[ai], expected)
      if r.adopted {
        argTypes[ai] = r.ty
        current[ai] = r.ty
        if isStdListType(tbl, r.ty) and hoistBindsOperand(sc, lit) {
          recordHoistOperandTypeOver(tbl, sc.genericNames, lit, r.ty, r.ty)
        }
      } else if r.failed and generics.count > 0 and typeMentionsTyVar(paramTys[k]) {
        diag.add(
          errorDiagnostic(
            code,
            "list literal for " + slotWord + " '" + names[k] + "' has type " + renderType(argTypes[ai]) + ", but the " +
              slotWord +
              ", declared " +
              renderType(paramTys[k]) +
              ", is " +
              renderType(r.target) +
              " here, as the other arguments bind its type parameters",
            lit.span
          )
        )
        argTypes[ai] = TyError
      }
    }
    k = k + 1
  }
}

// The outcome of checking a bracket literal against the type its parameter
// or field expects (`adoptLiteralAt`): `adopted` with the literal's new
// type `ty`, or `failed` when `target`, the type it was checked against,
// does not fit its elements, or neither when the position does not shape it.
record LiteralAdoption {
  ty: Type
  adopted: Bool
  failed: Bool
  target: Type
}

// Check the bracket literal `lit`, of checked type `own`, against
// `expected` when that is a stdlib `List` (its element type the expected
// one or, where that is open, the literal's own) or a slice of slices.
// The literal is checked against the target (which records its widenings
// and the shapes of the literals inside it) only once `literalFitsType`,
// which records nothing, has found that its elements fit.
func adoptLiteralAt(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  lit: in Expr,
  own: in Type,
  expected: in Type,
): LiteralAdoption {
  val none = LiteralAdoption(ty = own, adopted = false, failed = false, target = TyError)
  val target = match unrefine(expected) {
    case TyUser(lid, lname, largs) -> if largs.count == 1 and isStdCollectionsHostType(tbl, lid, "List") {
      val elemArgs: List[Type] = newList()
      elemArgs.add(shapedElemTypeIn(tbl, collectionElemType(tbl, unrefine(own)), largs[0]))
      TyUser(id = lid, name = lname, args = elemArgs)
    } else {
      return none
    }
    case TySlice(et) -> if isSliceType(et) or isNumericPrimType(et) or isStdListType(tbl, et) {
      unrefine(expected)
    } else {
      return none
    }
    case _ -> return none
  }
  if not typeIsClosedOver(target, sc.genericNames) {
    return none
  }
  if not literalFitsType(tbl, lit, own, target) {
    return LiteralAdoption(ty = own, adopted = false, failed = true, target = target)
  }
  val scratch: List[Diagnostic] = newList()
  val adopted = inferExprExpected(sc, tbl, sigs, scratch, lit, target)
  if diagnosticsHaveError(scratch) {
    LiteralAdoption(ty = own, adopted = false, failed = true, target = target)
  } else {
    LiteralAdoption(ty = adopted, adopted = true, failed = false, target = target)
  }
}

// Whether the bracket literal `lit`, of checked type `own`, fits `target`
// element by element, without checking it (so nothing is recorded): an
// element that is itself a bracket literal fits the target's element type
// when that is a `List`, slice or array its own elements fit; any other
// element fits when its type, the literal's element type, satisfies the
// target's element type or is an unsuffixed integer or float literal the
// element type adopts.
func literalFitsType(tbl: in SymbolTable, lit: in Expr, own: in Type, target: in Type): Bool {
  val elems = match lit.kind {
    case EParen(inner) -> return literalFitsType(tbl, inner, own, target)
    case EList(es) -> es
    case _ -> return argSatisfiesParam(tbl, target, own)
  }
  val targetElem = collectionElemType(tbl, unrefine(target))
  match targetElem {
    case TyError -> return false
    case _ -> ()
  }
  val ownElem = collectionElemType(tbl, unrefine(own))
  for el in elems {
    val fits = match bracketLiteralOf(el) {
      case Some(inner) -> match ownElem {
        case TyError -> true
        case _ -> literalFitsType(tbl, inner, ownElem, unrefine(targetElem))
      }
      case None -> match ownElem {
        case TyError -> true
        case _ -> argSatisfiesParam(tbl, targetElem, ownElem) or
          literalElementAdopts(el, targetElem)
      }
    }
    if not fits {
      return false
    }
  }
  true
}

// Whether `el` is an unsuffixed numeric literal that takes the type `t` it
// initialises (D155, #7841), which its own type does not satisfy.
func literalElementAdopts(el: in Expr, t: in Type): Bool {
  (isUnsuffixedIntLit(el) and isSomeSuffix(unsignedLiteralSuffix(t))) or (isUnsuffixedFloatLit(el) and isFloatType(t))
}

func recordHoistedCallArgs(
  sc: in Scope,
  tbl: in SymbolTable,
  args: in List[CallArg],
  argTypes: in List[Type],
  expected: in List[Type],
): Unit {
  val es: List[Expr] = newList()
  var i = 0
  while i < args.count {
    es.add(callArgExpr(args[i]))
    i = i + 1
  }
  recordHoistedOperands(sc, tbl, es, argTypes, expected)
}

// ─── Argument evaluation order (D171) ──────────────────────────────────────
//
// A call's receiver is evaluated first, then its arguments exactly once,
// left to right as written, then the defaults of the parameters it leaves
// out; the values are passed in parameter order.  Every backend evaluates
// the arguments in parameter order, which is the same thing unless named
// arguments are written out of that order (or before an omitted parameter
// whose default has an effect).  When the difference is observable
// (`Lyric.Parser.callArgsNeedSourceOrder`), the call is recorded in
// `argOrderSites` and `Lyric.Mono.desugarCheckedFile` evaluates its
// arguments into temporaries first, so every backend inherits the order.
// Whether evaluating `e` as an argument can neither cause nor observe an
// effect: `Lyric.Parser.exprIsInert`, where a local name is inert only when
// it can never be reassigned.  `self` is the call's own receiver binding.
func argIsInert(sc: in Scope, e: in Expr): Bool {
  match e.kind {
    case EPath(p) -> if p.segments.count == 1 {
      match scopeTryFind(sc, p.segments[0]) {
        case Some(b) -> not b.isMutable
        case None -> true
      }
    } else {
      true
    }
    case ESelf -> true
    case EParen(inner) -> argIsInert(sc, inner)
    case _ -> exprIsInert(e)
  }
}

// Whether `e` names a place: a name, `self`, or a field or element of one.
// An `out`/`inout` argument that names a place passes the place itself, and
// a method's receiver that names one may be mutated through `inout self`,
// so neither is ever copied into a temporary.
func argIsPlace(e: in Expr): Bool {
  match e.kind {
    case EPath(_) -> true
    case ESelf -> true
    case EParen(inner) -> argIsPlace(inner)
    case EMember(recv, _) -> argIsPlace(recv)
    case EIndex(recv, _) -> argIsPlace(recv)
    case _ -> false
  }
}

// Whether the place `e` has an index that is not a literal (`xs[i()]`,
// `r.xs[j].v`): `Lyric.Mono.bindPlaceIndicesMono` evaluates each such index
// into a temporary at the place's position.
func placeHasComputedIndex(e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> placeHasComputedIndex(inner)
    case EMember(recv, _) -> placeHasComputedIndex(recv)
    case EIndex(recv, indices) -> {
      for ix in indices {
        if not exprIsLiteralIndex(ix) {
          return true
        }
      }
      placeHasComputedIndex(recv)
    }
    case _ -> false
  }
}

// A literal or a negated literal, which `bindPlaceIndicesMono` leaves in place.
func exprIsLiteralIndex(e: in Expr): Bool {
  match e.kind {
    case ELiteral(_) -> true
    case EParen(inner) -> exprIsLiteralIndex(inner)
    case EPrefix(op, operand) -> match op {
      case PreNeg -> match operand.kind { case ELiteral(_) -> true; case _ -> false }
      case _ -> false
    }
    case _ -> false
  }
}

// Whether any argument of a call is named: only then can its arguments be
// written out of parameter order.
func callArgsHaveNamed(args: in List[CallArg]): Bool {
  for a in args {
    match a {
      case CANamed(_, _, _) -> return true
      case CAPositional(_) -> ()
    }
  }
  false
}

// Record the call at `callSpan` in `argOrderSites` when its arguments must be
// evaluated into temporaries to run in source order.  `slotNames` are the
// parameters (or fields) the arguments pair with, `defaultEffect[k]` whether
// leaving out parameter `k` runs a default that may cause or observe an
// effect, `byRef[k]` whether parameter `k` is `out`/`inout`, and
// `expected[i]` the type argument `i` is expected to have.  `recvTy` is the
// type of a method call's receiver.  A call in a contract clause calls only
// `@pure` functions, whose order is unobservable, and is left alone.
//
// A call that passes a place to an `out`/`inout` parameter and has a `?` or
// `await` in an argument is recorded too, in whatever order its arguments
// are written (#8171).  The `?` and `await` hoists bind every operand
// evaluated before such an argument to a fresh local, and a local bound to
// the place is a copy: the callee would write the copy, never the caller's
// variable, field or element.  Here the arguments run into temporaries in
// source order instead, the place stays in the call, and the call itself no
// longer has an argument the hoists need to move.
//
// A call that passes an element of an array (`a[i]`, `r.a[i][j]`) to an
// `out`/`inout` parameter is recorded too (#8180): every argument that is
// not inert runs into a temporary in source order, the element's computed
// indices at its own turn, and then the element is copied into a temporary
// that the call writes and that is stored back into the element after it,
// so each index runs once and the write lands on the element on every
// target.  The copy is made after every argument has run, as the JVM fills
// the holder of any `out`/`inout` place; `resultTy` is the call's result
// type, which says whether the call's value is kept across the store and is
// the annotation of the temporary that keeps it when it is a generic
// instantiation (#7823).  `resultIsTask` is set for an `async` or generator
// callee, whose call yields its task or sequence rather than `resultTy`.
func recordArgOrderSite(
  sc: in Scope,
  tbl: in SymbolTable,
  callSpan: in Span,
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
  slotNames: in List[String],
  defaultEffect: in List[Bool],
  byRef: in List[Bool],
  expected: in List[Type],
  recvTy: in Option[Type],
  resultTy: in Type,
  resultIsTask: in Bool,
): Unit {
  if sc.contractDepth.count > 0 {
    return
  }
  val named = callArgsHaveNamed(args)
  val hazard = callArgsHaveHoistHazard(args)
  val anyElem = callArgsHaveElementPlace(args)
  if not named and not hazard and not anyElem {
    return
  }
  val slots: List[Int] = match pairCallArgs(slotNames, 0, args) { case Ok(paired) -> paired; case Err(_) -> return }
  val argByRef: List[Bool] = newList()
  var i = 0
  while i < args.count {
    argByRef.add(false)
    i = i + 1
  }
  var k = 0
  while k < slots.count {
    if slots[k] >= 0 and k < byRef.count and byRef[k] {
      argByRef[slots[k]] = true
    }
    k = k + 1
  }
  val bound: List[Bool] = newList()
  val elemCopy: List[Bool] = newList()
  var placeByRef = false
  var hasElem = false
  i = 0
  while i < args.count {
    val ae = callArgExpr(args[i])
    if argByRef[i] and argIsPlace(ae) {
      placeByRef = true
    }
    val isElem = argByRef[i] and argIsElementPlace(ae)
    if isElem {
      hasElem = true
    }
    elemCopy.add(isElem)
    bound.add(if argByRef[i] { not argIsPlace(ae) } else { not argIsInert(sc, ae) })
    i = i + 1
  }
  val reordered = named and callArgsNeedSourceOrder(slots, args.count, bound, defaultEffect)
  if not reordered and not (hazard and placeByRef) and not hasElem {
    return
  }
  // Written in parameter order, the call needs temporaries only up to the
  // last argument holding a `?` or `await`, or the last by-reference place
  // with an index the rewrite evaluates into a temporary
  // (`bindPlaceIndicesMono`), whichever comes later: the arguments after
  // both run after them either way, while an argument left in the call
  // before such an index would run after it.
  if not reordered and not hasElem {
    var lastNeed = -1
    i = 0
    while i < args.count {
      val ae = callArgExpr(args[i])
      if HoistEngine.exprHasHoistHazard(ae) or (argByRef[i] and placeHasComputedIndex(ae)) {
        lastNeed = i
      }
      i = i + 1
    }
    i = lastNeed + 1
    while i < args.count {
      bound[i] = false
      i = i + 1
    }
  }
  i = 0
  while i < args.count {
    if bound[i] {
      val own = if i < argTypes.count { argTypes[i] } else { TyError }
      val want = if i < expected.count { expected[i] } else { TyError }
      recordHoistOperandType(sc, tbl, callArgExpr(args[i]), own, want)
    }
    i = i + 1
  }
  var bindRecv = false
  match fn.kind {
    case EMember(recv, _) -> match recvTy {
      case Some(rt) -> if not argIsInert(sc, recv) and not argIsPlace(recv) {
        bindRecv = true
        recordHoistOperandType(sc, tbl, recv, rt, TyError)
      }
      case None -> ()
    }
    case _ -> ()
  }
  val key = recordCopySiteKey(callSpan)
  if tbl.argOrderSites.containsKey(key) {
    tbl.argOrderSites.remove(key)
  }
  val elemTypes: List[TypeExpr] = newList()
  val elemTyped: List[Bool] = newList()
  i = 0
  while i < args.count {
    val ae = callArgExpr(args[i])
    val te: Option[TypeExpr] = if elemCopy[i] and i < argTypes.count {
      typeExprForOpenBinding(tbl, argTypes[i], ae.span, sc.genericNames)
    } else {
      None
    }
    match te {
      case Some(t) -> {
        elemTypes.add(t)
        elemTyped.add(true)
      }
      case None -> {
        elemTypes.add(TypeExpr(kind = TUnit, span = ae.span))
        elemTyped.add(false)
      }
    }
    i = i + 1
  }
  val resultKind = if resultIsTask {
    0
  } else {
    match unrefine(resultTy) {
      case TyPrim(pt) -> match pt { case PtUnit -> 1; case PtNever -> 2; case _ -> 0 }
      case _ -> 0
    }
  }
  val resultTe: Option[TypeExpr] = if hasElem and not resultIsTask and typeMentionsGenericInst(resultTy) and typeIsClosedOver(resultTy, sc.genericNames) {
    typeExprForOpenBinding(tbl, resultTy, callSpan, sc.genericNames)
  } else {
    None
  }
  val resultTypes: List[TypeExpr] = newList()
  match resultTe {
    case Some(t) -> resultTypes.add(t)
    case None -> ()
  }
  tbl.argOrderSites.add(
    key,
    ArgOrderSite(
      bound = bound,
      byRef = argByRef,
      bindRecv = bindRecv,
      startOffset = callSpan.startPos.offset,
      elemCopy = elemCopy,
      elemTypes = elemTypes,
      elemTyped = elemTyped,
      resultKind = resultKind,
      resultType = resultTypes
    )
  )
}

// `recordArgOrderSite` for a call to `sig`, whose parameters the arguments
// pair with as `checkCallArgsAgainstSig` pairs them.
func recordSigArgOrderSite(
  sc: in Scope,
  tbl: in SymbolTable,
  callSpan: in Span,
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
  sig: in ResolvedSignature,
  expected: in List[Type],
  recvTy: in Option[Type],
): Unit {
  val names: List[String] = newList()
  val defaultEffect: List[Bool] = newList()
  val byRef: List[Bool] = newList()
  for p in sig.params {
    names.add(p.name)
    defaultEffect.add(p.hasDefault and not p.defaultInert)
    byRef.add(modeNeedsLValue(p.mode))
  }
  recordArgOrderSite(
    sc,
    tbl,
    callSpan,
    fn,
    args,
    argTypes,
    names,
    defaultEffect,
    byRef,
    expected,
    recvTy,
    instantiateReturnType(sig, 0, args, argTypes),
    sig.isAsync or sig.isGenerator
  )
}

// `recordArgOrderSite` for the construction `fn(args)` of `ctorTy`: a
// record, exposed record, opaque or protected type (`ctorSym`) or a union
// case (`caseSym`), whose fields the arguments pair with by name and then
// in order.  A union case's fields have no defaults.
func recordCtorArgOrderSite(
  sc: in Scope,
  tbl: in SymbolTable,
  callSpan: in Span,
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
  sym: in Symbol,
  ctorTy: in Type,
): Unit {
  if not callArgsHaveNamed(args) {
    return
  }
  val names: List[String] = newList()
  val defaultEffect: List[Bool] = newList()
  val byRef: List[Bool] = newList()
  match sym.kind {
    case DKUnionCase(_, uc) -> {
      for nm in unionCaseSlotNames(uc) {
        names.add(nm)
        defaultEffect.add(false)
        byRef.add(false)
      }
    }
    case _ -> {
      for fd in ctorAllFields(sym) {
        names.add(fd.name)
        defaultEffect.add(match fd.dflt { case Some(d) -> not exprIsInert(d); case None -> false })
        byRef.add(false)
      }
    }
  }
  val expected: List[Type] = match ctorArgExpectedTypes(tbl, fn, args, ctorTy) {
    case Some(tys) -> tys
    case None -> newList()
  }
  val noRecv: Option[Type] = None
  recordArgOrderSite(
    sc,
    tbl,
    callSpan,
    fn,
    args,
    argTypes,
    names,
    defaultEffect,
    byRef,
    expected,
    noRecv,
    ctorTy,
    false
  )
}

// The construction `fn(args)` of `ctorTy`: each argument is expected to have
// its field's type.  The operands the hoist binds are recorded at it, and so
// is every argument that leaves its own type open (`None`, `Ok(2)`,
// `newList()`) when the construction's type fixes it (#7844): a backend with
// reified generics builds a generic constructor's arguments before it has
// chosen the constructor's instantiation, so with no type around the
// construction (`val h = Holder(value = None, fallback = 5)`) the `None` was
// an `Option<object>` stored in an `Option<int>` field.  A bracket literal
// whose field is a `List` is recorded at the field's instantiated type for
// the same reason: a generic record's field is `List<T>` there, so
// `GBox(items = [1, 2])` was built as an `int[]` (#8193).
func recordCtorArgOperandTypes(
  sc: in Scope,
  tbl: in SymbolTable,
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
  ctorTy: in Type,
): Unit {
  val hazard = callArgsHaveHoistHazard(args)
  val openArg = ctorHasOpenArg(sc, args, argTypes, ctorTy)
  val literalArg = ctorHasListLiteralArg(args)
  if not hazard and not openArg and not literalArg {
    return
  }
  match ctorArgExpectedTypes(tbl, fn, args, ctorTy) {
    case Some(expected) -> {
      if hazard {
        recordHoistedCallArgs(sc, tbl, args, argTypes, expected)
      }
      if literalArg {
        var li = 0
        while li < args.count and li < argTypes.count and li < expected.count {
          val le = callArgExpr(args[li])
          if argIsListLiteral(le) and isStdListType(tbl, expected[li]) and hoistBindsOperand(sc, le) {
            recordHoistOperandTypeOver(tbl, sc.genericNames, le, argTypes[li], expected[li])
          }
          li = li + 1
        }
      }
      if openArg {
        var i = 0
        while i < args.count and i < argTypes.count and i < expected.count {
          val ae = callArgExpr(args[i])
          if not typeIsClosedOver(argTypes[i], sc.genericNames) and hoistBindsOperand(sc, ae) {
            recordHoistOperandTypeOver(tbl, sc.genericNames, ae, argTypes[i], expected[i])
          }
          i = i + 1
        }
      }
    }
    case None -> ()
  }
}

// Whether a construction takes a bracket literal argument.
func ctorHasListLiteralArg(args: in List[CallArg]): Bool {
  for a in args {
    if argIsListLiteral(callArgExpr(a)) {
      return true
    }
  }
  false
}

// Whether the construction of `ctorTy`, a closed generic instantiation,
// takes an argument whose own type is open.
func ctorHasOpenArg(sc: in Scope, args: in List[CallArg], argTypes: in List[Type], ctorTy: in Type): Bool {
  if not typeMentionsGenericInst(ctorTy) or not typeIsClosedOver(ctorTy, sc.genericNames) {
    return false
  }
  var i = 0
  while i < args.count and i < argTypes.count {
    if not typeIsClosedOver(argTypes[i], sc.genericNames) {
      return true
    }
    i = i + 1
  }
  false
}

// The type each argument of a call to `sig` is expected to have, in argument
// order: its parameter's type with `sig`'s generic parameters bound from the
// call (`recvTy` fills a method's leading receiver parameter), or `TyError`
// for an argument no parameter takes.
func sigExpectedArgTypes(
  sig: in ResolvedSignature,
  recvTy: in Option[Type],
  args: in List[CallArg],
  argTypes: in List[Type],
): List[Type] {
  val expected: List[Type] = newList()
  var ei = 0
  while ei < args.count {
    expected.add(TyError)
    ei = ei + 1
  }
  val offset = match recvTy { case Some(_) -> 1; case None -> 0 }
  if sig.params.count < offset or args.count > sig.params.count - offset {
    return expected
  }
  val paramNames: List[String] = newList()
  var pi = offset
  while pi < sig.params.count {
    paramNames.add(sig.params[pi].name)
    pi = pi + 1
  }
  val srcIdx = argIndicesInParamOrder(args, paramNames)
  val targs = sigCallTypeArgsInOrder(sig, recvTy, srcIdx, argTypes)
  var j = 0
  while j < srcIdx.count {
    val ai = srcIdx[j]
    if ai >= 0 and ai < expected.count {
      val pty = sig.params[j + offset].ty
      expected[ai] = if sig.generics.count > 0 { substituteTyVars(pty, sig.generics, targs) } else { pty }
    }
    j = j + 1
  }
  expected
}

// T0208: a generic record constructor written with explicit type arguments
// (`Box[Long](value = 5)`).  Only generic functions take them; a record's
// arguments come from the expected type, so the form is indexing a
// constructor name, which no backend can lower.
func reportExplicitCtorTypeArgs(sc: in Scope, tbl: in SymbolTable, diag: in List[Diagnostic], fn: in Expr): Unit {
  val inner = match fn.kind { case EIndex(i, _) -> i; case _ -> return }
  val path = match inner.kind { case EPath(p) -> p; case _ -> return }
  if path.segments.count == 0 or isNoSourceSpan(fn.span) {
    return
  }
  if scopeHasName(sc, path.segments[0]) or sc.selfFields.containsKey(path.segments[0]) {
    return
  }
  match constructorSymbolOf(tbl, inner) {
    case Some(ctorSym) -> if ctorIsGeneric(ctorSym) {
      diag.add(
        errorDiagnostic(
          "T0208",
          "'" + path.segments[path.segments.count - 1] +
            "' is a generic record constructor and does not take explicit type arguments; give the binding or parameter its type instead, as in `val b: Box[Long] = Box(value = 5)`",
          fn.span
        )
      )
    }
    case None -> ()
  }
}

// Record the callee `fn` of a call in `typeArgCalleeSites` when it is a
// generic function under explicit type arguments written as an index of its
// name (`firstOf[Int]`): the name is not a local or a field of the implicit
// receiver, the symbol it resolves to here (`calleeHeadSymbol`) is not a
// `val`, `const`, wire or config, and it names a function with one generic
// parameter per index (#8279).
func recordTypeArgCallee(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
): Unit {
  val inner = match fn.kind { case EIndex(i, _) -> i; case _ -> return }
  val count = match fn.kind { case EIndex(_, ixs) -> ixs.count; case _ -> return }
  val path = match inner.kind { case EPath(p) -> p; case _ -> return }
  if path.segments.count == 0 or isNoSourceSpan(fn.span) {
    return
  }
  val head = path.segments[0]
  if scopeHasName(sc, head) or sc.selfFields.containsKey(head) {
    return
  }
  match calleeHeadSymbol(tbl, path) {
    case Some(sym) -> if symbolIsValue(sym) { return }
    case None -> ()
  }
  match findDirectSig(sc, tbl, sigs, inner, args, argTypes) {
    case Some(sig) -> if sig.generics.count == count {
      val key = recordCopySiteKey(fn.span)
      if not tbl.typeArgCalleeSites.containsKey(key) {
        tbl.typeArgCalleeSites.add(key, true)
      }
    }
    case None -> ()
  }
}

// The symbol the path `p` names where it is written, as a reference to it
// resolves: under a package qualifier (`Lib.fns`) that package's declaration
// of the name, otherwise the bare name under the current package and its
// imports (`symTableTryFindOne`), never a package the file does not import.
func calleeHeadSymbol(tbl: in SymbolTable, p: in ModulePath): Option[Symbol] {
  val name = p.segments[p.segments.count - 1]
  if p.segments.count > 1 {
    val prefix: List[String] = newList()
    var i = 0
    while i < p.segments.count - 1 {
      prefix.add(p.segments[i])
      i = i + 1
    }
    val qual = modulePathJoin(prefix)
    for sym in symTableTryFindAll(tbl, name) {
      if sym.originPackage == qual {
        return Some(value = sym)
      }
    }
  }
  symTableTryFindOne(tbl, name)
}

func symbolIsValue(sym: in Symbol): Bool {
  match sym.kind {
    case DKVal(_) -> true
    case DKConst(_) -> true
    case DKWire(_) -> true
    case DKConfig(_) -> true
    case _ -> false
  }
}

// A call to a generic function under explicit type arguments
// (`firstOf[Int](xs, ok(1)?)`, which the parser leaves as an index of the
// function's name) has no direct signature, so its arguments are checked
// against none.  Its arguments are still evaluated into temporaries ahead of
// a `?` or an `await` and, written out of order, in source order (D171), so
// each is recorded at the parameter type the explicit type arguments give it,
// as a call to the function's bare name records them (#8190, #8279).
func recordExplicitTypeArgCall(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  callSpan: in Span,
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
): Unit {
  val hazard = callArgsHaveHoistHazard(args)
  val inner = match fn.kind { case EIndex(i, _) -> i; case ETypeApp(i, _) -> i; case _ -> return }
  match inner.kind {
    case EPath(_) -> ()
    case _ -> return
  }
  val sig = match findDirectSig(sc, tbl, sigs, inner, args, argTypes) { case Some(s) -> s; case None -> return }
  recordMethodCallArity(tbl, inner, args.count, sig.params.count, false)
  if not hazard and not callArgsHaveNamed(args) and not callArgsHaveElementPlace(args) {
    return
  }
  val targs = match explicitCallTypeArgs(sc, tbl, fn, sig) { case Some(ts) -> ts; case None -> return }
  val noRecv: Option[Type] = None
  val expected: List[Type] = newList()
  var ei = 0
  while ei < args.count {
    expected.add(TyError)
    ei = ei + 1
  }
  val paramNames: List[String] = newList()
  for p in sig.params {
    paramNames.add(p.name)
  }
  val srcIdx = argIndicesInParamOrder(args, paramNames)
  var j = 0
  while j < srcIdx.count and j < sig.params.count {
    val ai = srcIdx[j]
    if ai >= 0 and ai < expected.count {
      expected[ai] = substituteTyVars(sig.params[j].ty, sig.generics, targs)
    }
    j = j + 1
  }
  if hazard {
    recordHoistedCallArgs(sc, tbl, args, argTypes, expected)
  }
  recordSigArgOrderSite(sc, tbl, callSpan, fn, args, argTypes, sig, expected, noRecv)
}

// The types the explicit type arguments of the callee `fn` give `sig`'s type
// parameters, in order; `None` unless there is one for each and every one
// names a type here.
func explicitCallTypeArgs(sc: in Scope, tbl: in SymbolTable, fn: in Expr, sig: in ResolvedSignature): Option[List[Type]] {
  val given = explicitGenericArgs(fn)
  if given.count == 0 or given.count != sig.generics.count {
    return None
  }
  val ctx = newGenericContext()
  gctxPush(ctx, sc.genericNames)
  val ts: List[Type] = newList()
  for ta in given {
    val te = match ta {
      case TAType(t) -> t
      case TAValue(ve) -> match typeArgExprAsTypeExpr(ve) { case Some(t) -> t; case None -> return None }
    }
    val scratch: List[Diagnostic] = newList()
    val t = resolveType(tbl, ctx, scratch, te)
    if scratch.count > 0 or not typeIsClosedOver(t, sc.genericNames) {
      return None
    }
    ts.add(t)
  }
  Some(value = ts)
}

// The type an explicit type argument written as an index expression spells:
// a type name (`Int`, `Pkg.Rec`), a generic instantiation (`List[Int]`) or a
// tuple of them.
func typeArgExprAsTypeExpr(e: in Expr): Option[TypeExpr] {
  match e.kind {
    case EPath(p) -> Some(value = TypeExpr(kind = TRef(path = p), span = e.span))
    case EParen(inner) -> typeArgExprAsTypeExpr(inner)
    case EIndex(head, indices) -> match head.kind {
      case EPath(hp) -> {
        val targs: List[TypeArg] = newList()
        for ix in indices {
          match typeArgExprAsTypeExpr(ix) {
            case Some(t) -> targs.add(TAType(ty = t))
            case None -> return None
          }
        }
        Some(value = TypeExpr(kind = TGenericApp(head = hp, args = targs), span = e.span))
      }
      case _ -> None
    }
    case ETuple(elems) -> {
      val tes: List[TypeExpr] = newList()
      for el in elems {
        match typeArgExprAsTypeExpr(el) {
          case Some(t) -> tes.add(t)
          case None -> return None
        }
      }
      Some(value = TypeExpr(kind = TTuple(types = tes), span = e.span))
    }
    case _ -> None
  }
}

// The type arguments a call to the generic `sig` binds, in `sig.generics`
// order: each parameter's type unified with its argument's (`srcIdx` maps
// parameters, after a method's receiver, to argument indices), joined along
// the numeric widening chains (D-progress-969).  Empty for a non-generic sig.
func sigCallTypeArgsInOrder(
  sig: in ResolvedSignature,
  recvTy: in Option[Type],
  srcIdx: in List[Int],
  argTypes: in List[Type],
): List[Type] {
  if sig.generics.count == 0 {
    return newList()
  }
  val offset = match recvTy { case Some(_) -> 1; case None -> 0 }
  val paramTys: List[Type] = newList()
  val slotTys: List[Type] = newList()
  match recvTy {
    case Some(rt) -> {
      paramTys.add(sig.params[0].ty)
      slotTys.add(rt)
    }
    case None -> ()
  }
  var k = 0
  while k < srcIdx.count {
    paramTys.add(sig.params[k + offset].ty)
    val ai = srcIdx[k]
    slotTys.add(if ai >= 0 and ai < argTypes.count { argTypes[ai] } else { TyError })
    k = k + 1
  }
  inferGenericArgsForSig(sig, paramTys, slotTys)
}

// The value generic parameters of the value-generic function `fn` names.
func valueGenericParamsOf(tbl: in SymbolTable, fn: in Expr, argCount: in Int): List[String] {
  match valueGenericCallee(tbl, fn, argCount) {
    case Some(d) -> valueGenericNames(d.generics)
    case None -> newList()
  }
}

// The type of a call resolved to the direct signature `sig`: its return
// type, with value generic parameters bound from the arguments.  A generic
// dot-named function called through its type (`Box.get(b)`) is recorded for
// specialisation under its full name (#8173).
func directCallType(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  fn: in Expr,
  sig: in ResolvedSignature,
  args: in List[CallArg],
  argTypes: in List[Type],
): Type {
  val ret = instantiateReturnType(sig, 0, args, argTypes)
  match dottedGenericPathCallee(tbl, fn, sig) {
    case Some(dottedFn) -> {
      recordDottedGenericCallSite(tbl, fn.span, dottedCalleeName(fn, sig), false, sig)
      val noGenerics: List[String] = newList()
      recordGenericCallTypeArgs(
        tbl,
        noGenerics,
        sig,
        valueGenericParamsOf(tbl, dottedFn, args.count),
        args,
        argTypes,
        fn.span
      )
      bindValueGenericCall(tbl, diag, dottedFn, args, argTypes, ret)
    }
    case None -> bindValueGenericCall(tbl, diag, fn, args, argTypes, ret)
  }
}

func dottedSigLookup(
  sigs: in Map[String, ResolvedSignature], dotted: in String, arity: in Int
): Option[ResolvedSignature] {
  match mapGet(sigs, dotted + "/" + toString(arity)) {
    case Some(ds) -> Some(value = ds)
    case None -> mapGet(sigs, dotted)
  }
}

func scopeHasName(sc: in Scope, name: in String): Bool {
  match scopeTryFind(sc, name) {
    case Some(_) -> true
    case None -> false
  }
}

// `Box.get(b)`: a two-segment path naming a generic dot-named function
// (#8173), as the single-segment path `Box.get` the function is declared and
// specialised under, at the same span.
func dottedGenericPathCallee(tbl: in SymbolTable, fn: in Expr, sig: in ResolvedSignature): Option[Expr] {
  if sig.generics.count == 0 {
    return None
  }
  val name = dottedCalleeName(fn, sig)
  if name.length == 0 {
    return None
  }
  for sym in symTableTryFindAll(tbl, name) {
    match sym.kind {
      case DKFunc(_) -> {
        val segs: List[String] = newList()
        segs.add(name)
        return Some(value = Expr(kind = EPath(path = ModulePath(segments = segs, span = fn.span)), span = fn.span))
      }
      case _ -> ()
    }
  }
  None
}

// True when `fn` names a dot-named function through its type (`T.m`).
func dottedFuncCallee(tbl: in SymbolTable, fn: in Expr): Bool {
  val name = qualifiedDottedName(fn)
  if name.length == 0 {
    return false
  }
  for sym in symTableTryFindAll(tbl, name) {
    match sym.kind {
      case DKFunc(_) -> return true
      case _ -> ()
    }
  }
  false
}

// `T.m` for a call of the dot-named function `sig` written through its type,
// `T.m` or `Pkg.T.m` where `Pkg` is the package declaring it; "" otherwise
// (a package-qualified free function `Pkg.Sub.f` included).
func dottedCalleeName(fn: in Expr, sig: in ResolvedSignature): String {
  val segs: List[String] = newList()
  if not calleeSegments(fn, segs) or segs.count < 2 {
    return ""
  }
  if segs.count > 2 {
    val pkgSegs: List[String] = newList()
    var i = 0
    while i < segs.count - 2 {
      pkgSegs.add(segs[i])
      i = i + 1
    }
    if modulePathJoin(pkgSegs) != sig.originPackage {
      return ""
    }
  }
  segs[segs.count - 2] + "." + segs[segs.count - 1]
}

// `Pkg` for a callee written `Pkg.T.m`; "" for `T.m` or any other callee.
func calleePackagePrefix(fn: in Expr): String {
  val segs: List[String] = newList()
  if not calleeSegments(fn, segs) or segs.count < 3 {
    return ""
  }
  val pkgSegs: List[String] = newList()
  var i = 0
  while i < segs.count - 2 {
    pkgSegs.add(segs[i])
    i = i + 1
  }
  modulePathJoin(pkgSegs)
}

// `T.m` for a callee written through its type, `T.m` or package-qualified
// `Pkg.T.m`, as a path or a member chain; "" otherwise.
func qualifiedDottedName(fn: in Expr): String {
  val segs: List[String] = newList()
  if not calleeSegments(fn, segs) or segs.count < 2 {
    return ""
  }
  segs[segs.count - 2] + "." + segs[segs.count - 1]
}

func calleeSegments(e: in Expr, acc: in List[String]): Bool {
  match e.kind {
    case EPath(p) -> {
      for sg in p.segments {
        acc.add(sg)
      }
      true
    }
    case EMember(recv, member) -> if calleeSegments(recv, acc) { acc.add(member); true } else { false }
    case _ -> false
  }
}

// `Box.get` for a callee written `Box.get`, as a two-segment path or a
// member of the type name; "" otherwise.
func dottedPathName(fn: in Expr): String {
  match fn.kind {
    case EPath(p) -> if p.segments.count == 2 { p.segments[0] + "." + p.segments[1] } else { "" }
    case EMember(recv, member) -> match recv.kind {
      case EPath(rp) -> if rp.segments.count == 1 {
        rp.segments[0] + "." + member
      } else {
        ""
      }
      case _ -> ""
    }
    case _ -> ""
  }
}

func recordDottedGenericCallSite(
  tbl: in SymbolTable,
  sp: in Span,
  name: in String,
  receiverFirst: in Bool,
  sig: in ResolvedSignature,
): Unit {
  if isNoSourceSpan(sp) or name.length == 0 {
    return
  }
  val key = recordCopySiteKey(sp)
  if not tbl.dottedGenericCallSites.containsKey(key) and not tbl.byRefDotCallSites.containsKey(key) {
    val foreign = sig.originPackage.length > 0 and sig.originPackage != symTableScopePkg(tbl)
    val origin = if foreign { sig.originPackage } else { "" }
    tbl.dottedGenericCallSites.add(key, DottedGenericCall(name = name, receiverFirst = receiverFirst, originPkg = origin))
  }
}

// The full signature of a method call resolved to a dot-named function that
// takes something by reference (#8179), is called on a primitive receiver
// (#8217) or extends the receiver's type from another package (#8219): the
// call is rewritten into a plain call of the function.  None for any other
// call.
func rewrittenDotFullSig(
  tbl: in SymbolTable,
  methodPick: in Option[MethodCallPick],
  fn: in Expr,
  recvTy: in Option[Type],
): Option[ResolvedSignature] {
  match fn.kind {
    case EMember(_, _) -> ()
    case _ -> return None
  }
  match methodPick {
    case Some(mp) -> match mp.fullSig {
      case Some(fullS) -> if sigHasByRefParam(fullS) or receiverNeedsPlainDotCall(tbl, recvTy) or receiverExtendedBy(tbl, recvTy, fullS) {
        Some(value = fullS)
      } else {
        None
      }
      case None -> None
    }
    case None -> None
  }
}

// Whether `sig` extends the type of the receiver `recvTy` from a package
// other than the one declaring it (#8219): no backend finds such a function
// among the type's methods.
func receiverExtendedBy(tbl: in SymbolTable, recvTy: in Option[Type], sig: in ResolvedSignature): Bool {
  match recvTy {
    case Some(rt) -> isDotNamedExtension(tbl, rt, sig)
    case None -> false
  }
}

// A method call on a primitive or distinct-type receiver resolved to a
// dot-named function (`k.twice()` for `func Int.twice`, `a.older()` for
// `func Age.older`) becomes a plain call of the function, as a by-reference
// one does: a primitive has no methods to dispatch to on any backend, and a
// distinct type none on native, which represents it as its underlying type
// (#8217).
func receiverNeedsPlainDotCall(tbl: in SymbolTable, recvTy: in Option[Type]): Bool {
  match recvTy {
    case Some(rt) -> match unrefine(rt) {
      case TyPrim(_) -> true
      case TyUser(tid, _, _) -> isDistinctTypeId(tbl, tid) or isEnumTypeId(tbl, tid)
      case _ -> false
    }
    case None -> false
  }
}

func isDistinctTypeId(tbl: in SymbolTable, tid: in SymbolId): Bool {
  match symTableTypeSymbolOf(tbl, tid) {
    case Some(sym) -> match sym.kind { case DKDistinctType(_, _) -> true; case _ -> false }
    case None -> false
  }
}

// An enum is a bare tag on every backend: it has no methods to dispatch a
// dot-named function to (#8254).
func isEnumTypeId(tbl: in SymbolTable, tid: in SymbolId): Bool {
  match symTableTypeSymbolOf(tbl, tid) {
    case Some(sym) -> match sym.kind { case DKEnum(_, _) -> true; case _ -> false }
    case None -> false
  }
}

func isRewrittenDotPick(
  tbl: in SymbolTable, methodPick: in Option[MethodCallPick], fn: in Expr, recvTy: in Option[Type]
): Bool {
  match rewrittenDotFullSig(tbl, methodPick, fn, recvTy) {
    case Some(_) -> true
    case None -> false
  }
}

// True when some parameter of `sig` is `out` or `inout`.
func sigHasByRefParam(sig: in ResolvedSignature): Bool {
  for p in sig.params {
    if modeNeedsLValue(p.mode) {
      return true
    }
  }
  false
}

// A call of the dot-named function `name` (`fullSig`, receiver included) that
// passes something by reference is recorded for rewriting into a plain call
// of the function (#8179, #8183): a backend lowers a method call's receiver
// as a value, and a plain call's `out`/`inout` arguments as places.
func recordByRefDotCall(
  tbl: in SymbolTable,
  sp: in Span,
  name: in String,
  fullSig: in ResolvedSignature,
  receiverFirst: in Bool,
): Unit {
  if sigHasByRefParam(fullSig) {
    recordDotCallRewrite(tbl, sp, name, fullSig, receiverFirst)
  }
}

// Record a call `T.m(x, args)` through its type that binds the method `m`
// in the body of `x`'s type (`sig`, receiver included) for rewriting into
// the method call `x.m(args)` (D181), with the arity the call resolves to
// when it leaves out a defaulted argument (#7828).
func recordBodyMethodCallRewrite(
  tbl: in SymbolTable,
  fn: in Expr,
  args: in List[CallArg],
  member: in String,
  sig: in ResolvedSignature,
): Unit {
  if isNoSourceSpan(fn.span) or args.count == 0 {
    return
  }
  val key = recordCopySiteKey(fn.span)
  if tbl.byRefDotCallSites.containsKey(key) {
    tbl.byRefDotCallSites.remove(key)
  }
  if tbl.dottedGenericCallSites.containsKey(key) {
    tbl.dottedGenericCallSites.remove(key)
  }
  tbl.byRefDotCallSites.add(key, ByRefDotCall(name = member, receiverFirst = false, originPkg = "", asMethod = true))
  val recvExpr = callArgExpr(args[0])
  val asMember = Expr(kind = EMember(receiver = recvExpr, memberName = member), span = fn.span)
  recordMethodCallArity(tbl, asMember, args.count - 1, sig.params.count - 1, false)
}

// Record the call of the dot-named function `name` (`fullSig`, receiver
// included) at `sp` for rewriting into a plain call of the function
// (`SymbolTable.byRefDotCallSites`).
func recordDotCallRewrite(
  tbl: in SymbolTable,
  sp: in Span,
  name: in String,
  fullSig: in ResolvedSignature,
  receiverFirst: in Bool,
): Unit {
  if isNoSourceSpan(sp) or name.length == 0 {
    return
  }
  val key = recordCopySiteKey(sp)
  if tbl.byRefDotCallSites.containsKey(key) {
    tbl.byRefDotCallSites.remove(key)
  }
  // Another package's function is named through its package, generic or
  // not: a generic one is specialised here, and a same-named function or
  // type of this package must not capture the call (#8179).  The call is no
  // longer a generic dot-named call to rewrite bare (#8173).
  val foreign = fullSig.originPackage.length > 0 and fullSig.originPackage != symTableScopePkg(tbl)
  val origin = if foreign { fullSig.originPackage } else { "" }
  tbl.byRefDotCallSites.add(key, ByRefDotCall(name = name, receiverFirst = receiverFirst, originPkg = origin))
  if tbl.dottedGenericCallSites.containsKey(key) {
    tbl.dottedGenericCallSites.remove(key)
  }
}

// The receiver of a call that takes it by reference (`self: inout T`, or any
// `out`/`inout` first parameter called with method syntax) is the place the
// callee writes: a `var`, an `out`/`inout` parameter (`self` among them), a
// field of one, or an element of an array that is one (T0166).
func checkByRefReceiver(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  recv: in Expr,
  method: in String,
  sp: in Span,
): Unit {
  val problem = byRefReceiverProblem(sc, tbl, sigs, recv)
  if problem.length > 0 {
    diag.add(
      errorDiagnostic(
        "T0166",
        (if method == "self" { "the `self` argument" } else { "the receiver of '" + method + "'" }) +
          " is passed by reference (`inout`), so it must be a place the call can write: " +
          problem,
        sp
      )
    )
  }
}

// Why `recv` is not a writable place, or "" when it is.
func byRefReceiverProblem(
  sc: in Scope, tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], recv: in Expr
): String {
  match recv.kind {
    case EParen(inner) -> byRefReceiverProblem(sc, tbl, sigs, inner)
    case EPath(p) -> if p.segments.count == 1 {
      match scopeTryFind(sc, p.segments[0]) {
        case Some(b) -> if b.isMutable { "" } else { "'" + p.segments[0] + "' is immutable; declare it `var`" }
        case None -> moduleBindingProblem(p.segments[0])
      }
    } else {
      moduleBindingProblem(modulePathJoin(p.segments))
    }
    case ESelf -> match scopeTryFind(sc, "self") {
      case Some(b) -> if b.isMutable {
        ""
      } else {
        "this method's own receiver `self` is `in`; declare it `self: inout`"
      }
      case None -> "this method's own receiver `self` is `in`; declare it `self: inout`"
    }
    case EMember(base, fname) -> {
      val scratch: List[Diagnostic] = newList()
      val fieldVar = fieldIsVar(tbl, inferExpr(sc, tbl, sigs, scratch, base), fname)
      val notVar = match fieldVar { case Some(isVar) -> not isVar; case None -> false }
      if notVar {
        "the field '" + fname +
          "' is not `var`; declare it `var` on its type, or pass a `var` holding its value and store it back"
      } else {
        fieldPathRootProblem(sc, base)
      }
    }
    case EIndex(arr, _) -> {
      val problem = elementByRefProblem(sc, tbl, sigs, recv)
      if problem.length > 0 {
        problem
      } else if arrayPlaceWritable(sc, tbl, sigs, arr) {
        ""
      } else {
        "an array element is written through a `var` local, an `out`/`inout` parameter or a `var` field, and this array is none of them"
      }
    }
    case _ -> "a value that is not a variable or field cannot be written; bind it to a `var` first"
  }
}

// Why the element `e` (`c[i]`) cannot be passed to an `out`/`inout` parameter,
// or "" when it can or `e` is not an element.  An element of an
// `array[N, T]` is a place (whether its array may be written is T0157's
// business); an element of a `List`, `Map`, slice, `String` or extern type is
// not one (docs/01 §2.7): the call is lowered as a copy into a temporary and
// a store back into the element (`Lyric.Mono.argOrderCallMono`), and a host
// collection may change length or key set while the callee runs.
func elementByRefProblem(sc: in Scope, tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], e: in Expr): String {
  match peelParens(e).kind {
    case EIndex(recv, _) -> {
      val scratch: List[Diagnostic] = newList()
      val rt = inferExpr(sc, tbl, sigs, scratch, recv)
      match unrefine(rt) {
        case TyError -> ""
        case TyArray(_, _, _) -> ""
        case _ -> "an element of " + renderType(rt) +
          " is not a place a call can write by reference (only an element of an `array[N, T]` is); copy it into a `var`, pass that, and store it back"
      }
    }
    case _ -> ""
  }
}

// Whether `e` is an element of a place (`a[i]`, `r.a[i][j]`): passed to an
// `out`/`inout` parameter, it is copied into a temporary the call writes and
// stored back after the call (`Lyric.Mono.argOrderCallMono`, #8180).
func argIsElementPlace(e: in Expr): Bool {
  match peelParens(e).kind {
    case EIndex(_, _) -> argIsPlace(e)
    case _ -> false
  }
}

// Whether some argument is an element of a place.
func callArgsHaveElementPlace(args: in List[CallArg]): Bool {
  for a in args {
    if argIsElementPlace(callArgExpr(a)) {
      return true
    }
  }
  false
}

// Whether a method call's receiver is an element of a place (`xs[i].m()`).
func calleeReceiverIsElementPlace(fn: in Expr): Bool {
  match fn.kind {
    case EMember(recv, _) -> argIsElementPlace(recv)
    case _ -> false
  }
}

// A field written by reference belongs to an object the caller holds: the
// path must start at a named binding (a local, a parameter, `self` or a
// module-level value, whatever its mode: the field, not the binding, is
// written, as for an `out`/`inout` argument), or at an element of one.
func fieldPathRootProblem(sc: in Scope, base: in Expr): String {
  match base.kind {
    case EParen(inner) -> fieldPathRootProblem(sc, inner)
    case EPath(_) -> ""
    case ESelf -> ""
    case EMember(inner, _) -> fieldPathRootProblem(sc, inner)
    case EIndex(inner, _) -> fieldPathRootProblem(sc, inner)
    case _ -> "the field path starts at a value that is not a variable (a call result); bind it to a `val` or `var` first"
  }
}

func moduleBindingProblem(name: in String): String {
  "'" + name +
    "' is not a local variable or parameter, and a module-level binding cannot be passed by reference; copy it into a `var` first"
}

// An `out`/`inout` argument that names a module-level binding, or a qualified
// one, has no place a call can write (#8179): no backend passes it by
// reference.  "" for any other argument.
func byRefArgModuleProblem(sc: in Scope, arg: in Expr): String {
  match arg.kind {
    case EParen(inner) -> byRefArgModuleProblem(sc, inner)
    case EPath(p) -> if p.segments.count == 1 {
      match scopeTryFind(sc, p.segments[0]) {
        case Some(_) -> ""
        case None -> moduleBindingProblem(p.segments[0])
      }
    } else {
      moduleBindingProblem(modulePathJoin(p.segments))
    }
    case _ -> ""
  }
}

// The type of `recv.m(args)` resolved to the dot-named function `T.m`: its
// return type instantiated from the receiver and arguments, with a generic
// function's call recorded for specialisation (#8173).
func dottedMethodCallType(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  fn: in Expr,
  recvTy: in Option[Type],
  memberName: in String,
  args: in List[CallArg],
  fullArgTypes: in List[Type],
  fullSig: in ResolvedSignature,
): Type {
  val dotRet = instantiateReturnType(fullSig, 1, args, fullArgTypes)
  if fullSig.generics.count == 0 {
    return dotRet
  }
  match recvTy {
    case Some(rt) -> recordDottedGenericMethodCall(tbl, diag, fn, rt, memberName, args, fullArgTypes, fullSig, dotRet)
    case None -> dotRet
  }
}

// `b.get()` resolved to a generic dot-named function `Box.get` (#8173): the
// call is recorded for rewriting into `Box.get(b)`, and the function's value
// parameters are bound from the receiver and arguments as that call binds
// them, giving the call its type.
func recordDottedGenericMethodCall(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  fn: in Expr,
  recvTy: in Type,
  memberName: in String,
  args: in List[CallArg],
  fullArgTypes: in List[Type],
  fullSig: in ResolvedSignature,
  instRet: in Type,
): Type {
  val recvExpr = match fn.kind { case EMember(r, _) -> r; case _ -> return instRet }
  val tname = dotNamedOwnerName(recvTy)
  if tname.length == 0 {
    return instRet
  }
  val name = tname + "." + memberName
  recordDottedGenericCallSite(tbl, fn.span, name, true, fullSig)
  val segs: List[String] = newList()
  segs.add(name)
  val dottedFn = Expr(kind = EPath(path = ModulePath(segments = segs, span = fn.span)), span = fn.span)
  val fullArgs: List[CallArg] = newList()
  fullArgs.add(CAPositional(expr = recvExpr))
  for a in args {
    fullArgs.add(a)
  }
  val noGenerics: List[String] = newList()
  recordGenericCallTypeArgs(
    tbl,
    noGenerics,
    fullSig,
    valueGenericParamsOf(tbl, dottedFn, fullArgs.count),
    fullArgs,
    fullArgTypes,
    fn.span
  )
  bindValueGenericCall(tbl, diag, dottedFn, fullArgs, fullArgTypes, instRet)
}

// A call to a value-generic function binds each value generic parameter
// that sizes an array parameter to the length of the array argument (D167
// item 6), or to the length the call gives explicitly (`total[3](a)`),
// records an inferred binding for `Lyric.Mono`, and gives the result type
// those lengths.  Two arguments binding one parameter to different lengths,
// or an argument whose length is not the explicit one, is T0043; a parameter
// neither the arguments nor the call give a length is T0110.
func bindValueGenericCall(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
  instRet: in Type,
): Type {
  val decl = match valueGenericCallee(tbl, fn, args.count) { case Some(d) -> d; case None -> return instRet }
  val vps = valueGenericNames(decl.generics)
  val isExplicit = explicitGenericArgs(fn).count > 0
  val bound = explicitValueGenericBindings(tbl, decl, fn)
  val explicitNames = mapKeys(bound)
  val paramNames: List[String] = newList()
  for p in decl.params {
    paramNames.add(p.name)
  }
  val order = argIndicesInParamOrder(args, paramNames)
  val conflicts: List[String] = newList()
  var i = 0
  while i < decl.params.count and i < order.count {
    val ai = order[i]
    if ai >= 0 and ai < argTypes.count {
      bindArrayLengths(decl.params[i].ty, argTypes[ai], vps, bound, conflicts)
    }
    i = i + 1
  }
  for c in conflicts {
    val msg = if explicitNames.contains(c) {
      "an argument of this call does not have the length '" + c + "' = " +
        toString(match mapGet(bound, c) { case Some(n) -> n; case None -> 0 }) +
        " that the call gives '" +
        decl.name +
        "'"
    } else {
      "the arguments of this call give the length '" + c + "' of '" + decl.name +
        "' different values: every array sized by '" +
        c +
        "' must have the same length"
    }
    diag.add(errorDiagnostic("T0043", msg, fn.span))
  }
  if conflicts.count > 0 {
    return instRet
  }
  if bound.count != vps.count {
    if not inValueGenericBody(tbl) and not anyErrorType(argTypes) {
      for vp in vps {
        if not bound.containsKey(vp) {
          diag.add(
            errorDiagnostic(
              "T0110",
              "cannot infer the length '" + vp + "' of '" + decl.name +
                "': no array argument has it as its length; give the generic arguments explicitly, as in '" +
                decl.name +
                "[...](...)'",
              fn.span
            )
          )
        }
      }
      return TyError
    }
    return instRet
  }
  if not isExplicit and not isNoSourceSpan(fn.span) {
    val key = recordCopySiteKey(fn.span)
    if not tbl.valueGenericCallSites.containsKey(key) {
      tbl.valueGenericCallSites.add(key, bound)
    }
  }
  match decl.ret {
    case Some(rte) -> withBoundArrayLengths(rte, instRet, vps, bound)
    case None -> instRet
  }
}

// The result type of a call to a generic function under explicit type
// arguments (`boxer[Int]()`, the parser's `ECall(EIndex(fn, targs), args)`):
// the declared result with each type parameter replaced by the argument given
// for it.  `None` unless every parameter is given a closed type here and the
// callee is a plain generic function; the call then types as it always did
// (#8347).
func explicitTypeArgCallType(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
): Option[Type] {
  if explicitGenericArgs(fn).count == 0 {
    return None
  }
  match valueGenericCallee(tbl, fn, args.count) {
    case Some(_) -> return None
    case None -> ()
  }
  val inner = match fn.kind { case EIndex(i, _) -> i; case ETypeApp(i, _) -> i; case _ -> return None }
  match inner.kind {
    case EPath(_) -> ()
    case _ -> return None
  }
  val sig = match findDirectSig(sc, tbl, sigs, inner, args, argTypes) { case Some(s) -> s; case None -> return None }
  if sig.isAsync or sig.isGenerator {
    return None
  }
  val targs = match explicitCallTypeArgs(sc, tbl, fn, sig) { case Some(ts) -> ts; case None -> return None }
  Some(value = substituteTyVars(sig.returnTy, sig.generics, targs))
}

func checkExplicitValueGenericCall(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
  sp: in Span,
): Option[Type] {
  if explicitGenericArgs(fn).count == 0 {
    return None
  }
  match valueGenericCallee(tbl, fn, args.count) {
    case Some(_) -> ()
    case None -> return None
  }
  val inner = match fn.kind { case EIndex(i, _) -> i; case ETypeApp(i, _) -> i; case _ -> return None }
  val sig = match findDirectSig(sc, tbl, sigs, inner, args, argTypes) { case Some(s) -> s; case None -> return None }
  checkCallArgsAgainstSig(sc, tbl, sigs, diag, sig, args, argTypes, sp)
  Some(value = bindValueGenericCall(tbl, diag, fn, args, argTypes, instantiateReturnType(sig, 0, args, argTypes)))
}

// The signature `sig` with its type parameters replaced by `targs`: the form
// an explicit type-argument call (`firstOf[Int](xs, 1)`) is checked against.
func instantiateSigAt(sig: in ResolvedSignature, targs: in List[Type]): ResolvedSignature {
  val ps: List[ResolvedParam] = newList()
  for p in sig.params {
    ps.add(p.copy(ty = substituteTyVars(p.ty, sig.generics, targs)))
  }
  val noGenerics: List[String] = newList()
  val noBounds: List[ResolvedBound] = newList()
  sig.copy(
    generics = noGenerics,
    bounds = noBounds,
    params = ps,
    returnTy = substituteTyVars(sig.returnTy, sig.generics, targs)
  )
}

// A call to a plain generic function under explicit type arguments
// (`firstOf[Int](xs, 1)`, the parser's `ECall(EIndex(fn, targs), args)`) is
// checked against the signature those arguments instantiate: the argument
// count (T0042) and each argument's type (T0043).  The callee is found by
// name when no declaration takes this many arguments, so a wrong count is
// reported here and not as an internal error in a backend (#8282).
func checkExplicitTypeArgCall(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
  sp: in Span,
): Unit {
  if explicitGenericArgs(fn).count == 0 {
    return
  }
  match valueGenericCallee(tbl, fn, args.count) {
    case Some(_) -> {
      return
    }
    case None -> ()
  }
  val inner = match fn.kind { case EIndex(i, _) -> i; case ETypeApp(i, _) -> i; case _ -> { return } }
  var iname = ""
  match inner.kind {
    case EPath(path) -> {
      if path.segments.count == 1 and not scopeHasName(sc, path.segments[0]) {
        iname = path.segments[0]
      }
    }
    case _ -> ()
  }
  if iname.length == 0 {
    return
  }
  val found = match findDirectSig(sc, tbl, sigs, inner, args, argTypes) {
    case Some(s) -> s
    case None -> {
      val sameArity: List[ResolvedSignature] = newList()
      for c in gatherOverloadCandidates(sigs, byNameSigKey(iname)) {
        if c.generics.count == explicitGenericArgs(fn).count {
          sameArity.add(c)
        }
      }
      if sameArity.count != 1 {
        return
      }
      sameArity[0]
    }
  }
  if found.isAsync or found.isGenerator or found.isExternFunc or found.generics.count == 0 {
    return
  }
  match explicitCallTypeArgs(sc, tbl, fn, found) {
    case Some(targs) -> {
      val inst = instantiateSigAt(found, targs)
      var deferred = false
      for a in args {
        val ae = callArgExpr(a)
        if argIsLambdaLiteral(ae) or argIsAmbiguousUnionCaseCtor(tbl, ae) or argIsBranchingExpr(ae) or argIsListLiteral(ae) or argIsListHoldingTuple(ae) or argIsPropagate(ae) or argIsPropagateCall(tbl, ae) {
          deferred = true
        }
      }
      if not deferred {
        checkCallArgsAgainstSig(sc, tbl, sigs, diag, inst, args, argTypes, sp)
      } else {
        // An argument typed from its parameter (a lambda or bracket literal)
        // has no type yet here; only the count can be checked.
        var minRequired = 0
        for p in inst.params {
          if not p.hasDefault {
            minRequired = minRequired + 1
          }
        }
        if args.count < minRequired or args.count > inst.params.count {
          val expectedMsg = if minRequired == inst.params.count {
            toString(inst.params.count) + " argument(s)"
          } else {
            toString(minRequired) + "–" + toString(inst.params.count) + " argument(s)"
          }
          diag.add(errorDiagnostic("T0042", "expected " + expectedMsg + ", got " + toString(args.count), sp))
        }
      }
    }
    case None -> ()
  }
}

func anyErrorType(ts: in List[Type]): Bool {
  for t in ts {
    match t {
      case TyError -> return true
      case _ -> ()
    }
  }
  false
}

// Record the type arguments the call to the generic function `sig` whose
// callee is at `sp` binds (see `SymbolTable.genericCallTypeArgSites`, #7865).  Only a call whose
// every type argument is closed and has a source spelling here is recorded;
// a call checked twice at different type arguments (synthesized code sharing
// one span, or a re-check against an expected type) is `conflicting`.
func recordGenericCallTypeArgs(
  tbl: in SymbolTable,
  genericNames: in List[String],
  sig: in ResolvedSignature,
  valueParams: in List[String],
  args: in List[CallArg],
  argTypes: in List[Type],
  sp: in Span,
): Unit {
  if sig.generics.count == 0 or isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return
  }
  if args.count > sig.params.count {
    return
  }
  val paramNames: List[String] = newList()
  var pi = 0
  while pi < sig.params.count {
    paramNames.add(sig.params[pi].name)
    pi = pi + 1
  }
  val noRecv: Option[Type] = None
  val allTargs = sigCallTypeArgsInOrder(sig, noRecv, argIndicesInParamOrder(args, paramNames), argTypes)
  if allTargs.count != sig.generics.count {
    return
  }
  // A value generic parameter is bound by `bindValueGenericCall`, not here;
  // only the type parameters are recorded.
  val typeParamNames: List[String] = newList()
  val targs: List[Type] = newList()
  var gi = 0
  while gi < sig.generics.count {
    if not valueParams.contains(sig.generics[gi]) {
      typeParamNames.add(sig.generics[gi])
      targs.add(allTargs[gi])
    }
    gi = gi + 1
  }
  if targs.count == 0 {
    return
  }
  // A call in a generic body may bind a type argument to the body's own type
  // parameter (`mapOption(o, { v: T -> 3 })` over `o: Option[T]`): spelled by
  // its name, flagged for a pass that substitutes it (#8301).
  var mentionsVars = false
  for ta in targs {
    if not typeIsClosed(ta) {
      mentionsVars = true
    }
  }
  if mentionsVars {
    for ta in targs {
      if not typeIsClosedOver(ta, genericNames) {
        return
      }
    }
  }
  match typeExprsForRefV(tbl, targs, sp, mentionsVars) {
    case Some(tes) -> {
      val key = recordCopySiteKey(sp)
      val renderedArgs: List[String] = newList()
      var ri = 0
      while ri < targs.count {
        renderedArgs.add(renderType(targs[ri]))
        ri = ri + 1
      }
      val rendered = joinStrs(renderedArgs, ", ")
      match mapGet(tbl.genericCallTypeArgSites, key) {
        case Some(prev) -> if prev.rendered != rendered and not prev.conflicting {
          tbl.genericCallTypeArgSites.remove(key)
          tbl.genericCallTypeArgSites.add(
            key,
            GenericCallTypeArgsSite(
              typeParams = prev.typeParams,
              typeArgs = prev.typeArgs,
              rendered = prev.rendered,
              conflicting = true,
              mentionsVars = prev.mentionsVars
            )
          )
        }
        case None -> tbl.genericCallTypeArgSites.add(
          key,
          GenericCallTypeArgsSite(
            typeParams = typeParamNames,
            typeArgs = tes,
            rendered = rendered,
            conflicting = false,
            mentionsVars = mentionsVars
          )
        )
      }
    }
    case None -> ()
  }
}

// Whether `t` is or contains an instantiation of a generic type.
func typeMentionsGenericInst(t: in Type): Bool {
  match t {
    case TyUser(_, _, args) -> args.count > 0
    case TySlice(e) -> typeMentionsGenericInst(e)
    case TyArray(_, e, _) -> typeMentionsGenericInst(e)
    case TyNullable(inner) -> typeMentionsGenericInst(inner)
    case TyTuple(elems) -> {
      var i = 0
      while i < elems.count {
        if typeMentionsGenericInst(elems[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case TyRefined(u, _, _, _, _) -> typeMentionsGenericInst(u)
    case _ -> false
  }
}

// Whether a call's callee `fn` evaluates to a function value (see
// `recordFuncValueCall`).  A member callee is one only when the receiver's
// record declares a field of that name (a builtin or method is called by
// name); a bare name only when it is a local binding in scope.
func calleeIsFuncValue(
  sc: in Scope,
  tbl: in SymbolTable,
  fn: in Expr,
  memberRecvTy: in Option[Type],
  memberName: in String,
): Bool {
  match fn.kind {
    case EPath(p) -> isLocalNameTc(sc, p) or isModuleValNameTc(sc, tbl, p)
    // A record's function-typed field, or a package-qualified module-level
    // `val` (`Pkg.handlers`, #8283).
    case EMember(_, _) -> match moduleValSymbolOfExpr(sc, tbl, fn) {
      case Some(_) -> true
      case None -> match memberRecvTy {
        case Some(rt) -> match unrefine(rt) {
          case TyUser(tid, _, targs) -> {
            val fs = fieldsOfRecordInstantiated(tbl, tid, targs)
            var i = 0
            while i < fs.count {
              if fs[i].name == memberName {
                return true
              }
              i = i + 1
            }
            false
          }
          case _ -> false
        }
        case None -> false
      }
    }
    case EParen(inner) -> calleeIsFuncValue(sc, tbl, inner, None, "")
    // `f[T](x)` applies type arguments to a named function; an index into a
    // local's or a module-level `val`'s value (`fs[0](x)`, #8283) or any other
    // expression's is a value.
    case EIndex(recv, _) -> match recv.kind {
      case EPath(rp) -> isLocalNameTc(sc, rp) or isModuleValNameTc(sc, tbl, rp)
      case _ -> true
    }
    case ETypeApp(_, _) -> false
    case _ -> true
  }
}

// The type a read of the module-level `val` `vd` (symbol `sym`) has.  The
// declaration itself reports its type's and its initialiser's errors, once
// (`checkItemDeclaredInits`, #7777); a read reports none of them again, and an
// importer never re-reports what the declaring package's own check found.  A
// declared type, and an untyped val's initializer, are written in the
// declaring package's scope, not the reading file's (docs/01 §9.2).
func moduleValReadType(
  tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], sym: in Symbol, vd: in ValDecl
): Type {
  val saved = enterDeclaringScopeIfForeign(tbl, sym)
  val readDiag: List[Diagnostic] = newList()
  val t = match vd.ty {
    case Some(te) -> {
      val ctx = newGenericContext()
      resolveType(tbl, ctx, readDiag, te)
    }
    case None -> {
      // Infer against an empty scope to avoid the caller's local bindings
      // shadowing module-level names referenced in vd.init.
      val noRte: Option[TypeExpr] = None
      val noSelfFields: Map[String, Type] = newMap()
      val emptyScope = newScopeForFunction(TyError, newList(), noRte, noSelfFields, false, TyError)
      inferExpr(emptyScope, tbl, sigs, readDiag, vd.init)
    }
  }
  restoreScope(tbl, saved)
  t
}

// Whether `p` names a module-level `val` that no local of that name shadows:
// a value, not a function the call reaches by name (#8283).
func isModuleValNameTc(sc: in Scope, tbl: in SymbolTable, p: in ModulePath): Bool {
  match moduleValSymbolOfSegs(sc, tbl, p.segments) {
    case Some(_) -> true
    case None -> false
  }
}

// The module-level `val` a bare or package-qualified path names (`v`,
// `Pkg.v`, `Pkg.Sub.v`, the package's own name included), when its root is no
// local.  A bare name resolves under the current scope as any name does; a
// qualified one names a `val` its qualifier's package declares, preferring the
// current package and its imports when several packages end in the qualifier
// (#8283).
func moduleValSymbolOfSegs(sc: in Scope, tbl: in SymbolTable, segs: in List[String]): Option[Symbol] {
  if segs.count == 0 {
    return None
  }
  match scopeTryFind(sc, segs[0]) {
    case Some(_) -> return None
    case None -> ()
  }
  val name = segs[segs.count - 1]
  if segs.count == 1 {
    return match symTableTryFindOne(tbl, name) {
      case Some(sym) -> match sym.kind { case DKVal(_) -> Some(value = sym); case _ -> None }
      case None -> None
    }
  }
  val qualSegs: List[String] = newList()
  var qi = 0
  while qi < segs.count - 1 {
    qualSegs.add(segs[qi])
    qi = qi + 1
  }
  val qual = modulePathJoin(qualSegs)
  val scopePkg = symTableScopePkg(tbl)
  var fallback: Option[Symbol] = None
  for sym in symTableTryFindAll(tbl, name) {
    match sym.kind {
      case DKVal(_) -> if pkgMatchesQualifier(sym.originPackage, qual) {
        if sym.originPackage == scopePkg or symTableScopeAllows(tbl, sym.originPackage) {
          return Some(value = sym)
        }
        fallback = Some(value = sym)
      }
      case _ -> ()
    }
  }
  fallback
}

// The module-level `val` a member chain or path expression names
// (`moduleValSymbolOfSegs`).
func moduleValSymbolOfExpr(sc: in Scope, tbl: in SymbolTable, e: in Expr): Option[Symbol] {
  val segs: List[String] = newList()
  if not flattenCalleePathSegs(e, segs) {
    return None
  }
  moduleValSymbolOfSegs(sc, tbl, segs)
}

// Whether `p` is a bare name bound in scope (a local, parameter or pattern
// binding) rather than a function or package path.
func isLocalNameTc(sc: in Scope, p: in ModulePath): Bool {
  if p.segments.count != 1 {
    return false
  }
  match scopeTryFind(sc, p.segments[0]) {
    case Some(_) -> true
    case None -> false
  }
}

// A non-call member read on a distinct type (docs/01 §2.3).  A distinct type
// is nominal and does not expose its underlying type's members: `x.value`
// reads the underlying value, and any other member is T0113, pointing at
// `x.value`.  Before this every such read type-checked as an unchecked
// error type and miscompiled (an invalid MSIL program, a J009 refusal on the
// JVM) — `.value` itself was unchecked too (#7439).  `None` for a
// non-distinct receiver, and for a generic distinct type, whose underlying
// type depends on its arguments and keeps the lenient path.
func distinctMemberType(
  tbl: in SymbolTable, diag: in List[Diagnostic], recvRaw: in Type, name: in String, span: in Span
): Option[Type] {
  match unrefine(recvRaw) {
    case TyUser(tid, tname, _) -> {
      var i = 0
      while i < tbl.symbols.count {
        val sym = tbl.symbols[i]
        match sym.kind {
          case DKDistinctType(did, dt) -> {
            if symbolIdEq(did, tid) {
              match dt.generics {
                case Some(_) -> return None
                case None -> ()
              }
              if name == "value" {
                val saved = enterDeclaringScope(tbl, sym)
                val scratch: List[Diagnostic] = newList()
                val underlying = resolveType(tbl, newGenericContext(), scratch, dt.underlying)
                restoreScope(tbl, saved)
                return Some(value = underlying)
              }
              diag.add(
                errorDiagnostic(
                  "T0113",
                  "no member '" + name + "' on distinct type '" + tname +
                    "'; a distinct type does not expose its underlying type's members, read them through '.value' (e.g. 'x.value." +
                    name +
                    "')",
                  span
                )
              )
              return Some(value = TyError)
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
      None
    }
    case _ -> None
  }
}

// Record the union a case pattern at `sp` matches: `ty`, the scrutinee type
// the pattern was checked against (see `SymbolTable.memberRecvClasses`).  The
// JVM backend erases a generic scrutinee (`Option[Int]`) to `Object`, so
// without it a bare case name (`Some`, `None`) resolves by name through the
// enclosing package first and picks a same-named case of a local union over
// the scrutinee's own (#7761).
// Notes that the bare identifier pattern spanning `sp` names a case and binds
// nothing (`SymbolTable.casePatternSites`).
func recordCasePatternSite(tbl: in SymbolTable, sp: in Span): Unit {
  if isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return
  }
  val key = recordCopySiteKey(sp)
  if not tbl.casePatternSites.containsKey(key) {
    tbl.casePatternSites.add(key, true)
  }
}

// Record the enum a bare case-name pattern at `sp` matches, when the
// scrutinee `ty` is an enum (`SymbolTable.enumCasePatternSites`, #8421).
func recordEnumCasePattern(tbl: in SymbolTable, sp: in Span, ty: in Type): Unit {
  if isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return
  }
  match unrefine(ty) {
    case TyUser(tid, _, _) -> match symTableTypeSymbolOf(tbl, tid) {
      case Some(sym) -> match sym.kind {
        case DKEnum(_, _) -> {
          if sym.originPackage.length > 0 {
            val key = recordCopySiteKey(sp)
            if not tbl.enumCasePatternSites.containsKey(key) {
              tbl.enumCasePatternSites.add(key, sym.originPackage + "." + sym.name)
            }
          }
        }
        case _ -> ()
      }
      case None -> ()
    }
    case _ -> ()
  }
}

func recordCasePatternUnion(tbl: in SymbolTable, sp: in Span, ty: in Type): Unit {
  if isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return
  }
  match unrefine(ty) {
    case TyUser(tid, _, _) -> match symTableTypeSymbolOf(tbl, tid) {
      case Some(sym) -> match sym.kind {
        case DKUnion(_, _) -> recordMemberRecvClass(tbl, sp, ty)
        case _ -> ()
      }
      case None -> ()
    }
    case _ -> ()
  }
}

// Record the nominal type of a field-access receiver (see
// `SymbolTable.memberRecvClasses`).  Only types that are a class of their own
// on every backend are recorded: an enum, interface or extern type has no
// such class, and a type parameter or error type carries nothing to narrow
// to.
func recordMemberRecvClass(tbl: in SymbolTable, sp: in Span, t: in Type): Unit {
  match unrefine(t) {
    // #8668: the stdlib `List` a method is called on, under its own key
    // prefix.  MSIL erases a `List` of tuples to `object`, so `indexOf`,
    // `lastIndexOf` and `remove` could not tell it from a `String` or `Map`.
    case TyUser(tid, _, _) -> if isStdCollectionsHostType(tbl, tid, "List") {
      val lkey = stdListRecvSiteKey(sp)
      if not tbl.memberRecvClasses.containsKey(lkey) {
        tbl.memberRecvClasses.add(lkey, "Std.CollectionsHost.List")
      }
    } else {
      recordMemberRecvClassOfUser(tbl, sp, tid)
    }
    case _ -> ()
  }
}

func recordMemberRecvClassOfUser(tbl: in SymbolTable, sp: in Span, tid: in SymbolId): Unit {
  match symTableTypeSymbolOf(tbl, tid) {
    case Some(sym) -> {
      val isClass = match sym.kind {
        case DKRecord(_, _) -> true
        case DKExposedRec(_, _) -> true
        case DKUnion(_, _) -> true
        case DKOpaque(_, _) -> true
        case DKProtected(_, _) -> true
        // A distinct value is a wrapper class on dotnet and the JVM
        // (docs/01 §2.3), so an erased one narrows to it before `.value`.
        case DKDistinctType(_, _) -> true
        case _ -> false
      }
      if isClass and sym.originPackage.length > 0 {
        val key = recordCopySiteKey(sp)
        if not tbl.memberRecvClasses.containsKey(key) {
          tbl.memberRecvClasses.add(key, sym.originPackage + "." + sym.name)
        }
      }
    }
    case None -> ()
  }
}

func inferExprCore(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
): Type {
  match e.kind {
    case ELiteral(lit) -> typeOfLiteral(lit)

    case EPath(path) -> resolveExprPath(sc, tbl, sigs, diag, path, e.span)

    case EParen(inner) -> inferExpr(sc, tbl, sigs, diag, inner)

    case ETuple(elems) -> {
      val ts: List[Type] = newList()
      var i = 0
      while i < elems.count {
        ts.add(inferExpr(sc, tbl, sigs, diag, elems[i]))
        i = i + 1
      }
      recordHoistedOperands(sc, tbl, elems, ts, hoistTupleElemTypes(TyError, elems.count))
      TyTuple(elems = ts)
    }

    case EList(elems) -> {
      if elems.count == 0 {
        return TySlice(element = TyError)
      }
      val elemTs: List[Type] = newList()
      var i = 0
      while i < elems.count {
        elemTs.add(inferExpr(sc, tbl, sigs, diag, elems[i]))
        i = i + 1
      }
      val first = elemTs[0]
      var j = 1
      var allSame = true
      while j < elemTs.count {
        if not typeEquiv(first, elemTs[j]) {
          allSame = false
        }
        j = j + 1
      }
      if not allSame {
        diag.add(errorDiagnostic("T0041", "list literal elements must share a type", e.span))
        return TySlice(element = first)
      }
      // `[Some(1), None]`: each element leaves open what only another fixes,
      // so the literal's element type is their join (#7818).
      var joined = first
      var k = 1
      while k < elemTs.count {
        joined = joinOpenTypes(joined, elemTs[k])
        k = k + 1
      }
      recordListLiteralType(sc, tbl, e, TySlice(element = joined))
      val joinedAt: List[Type] = newList()
      var ji = 0
      while ji < elems.count {
        joinedAt.add(joined)
        ji = ji + 1
      }
      recordHoistedOperands(sc, tbl, elems, elemTs, joinedAt)
      TySlice(element = joined)
    }

    case EPrefix(op, inner) -> {
      val it = inferExpr(sc, tbl, sigs, diag, inner)
      match op {
        case PreNot -> resolvePropagateOperand(sc, tbl, inner, TyPrim(pt = PtBool))
        case _ -> ()
      }
      // `-2147483648` is `Int.MinValue`: its operand alone is too large for
      // `Int` (so it typed `Long`), but the negated value fits (#7346).
      match unsuffixedIntLiteralValue(e) {
        case Some(v) -> {
          if v == 0i64 - 2147483648i64 {
            return TyPrim(pt = PtInt)
          }
        }
        case None -> ()
      }
      val prefixT = inferPrefix(diag, op, it, e.span)
      // Negating a non-literal `Int` / `Long` overflows on its minimum value
      // (D163).  A negated literal is folded at its own type.
      match op {
        case PreNeg -> {
          val tn = overflowTypeName(prefixT)
          val isLit = match inner.kind { case ELiteral(_) -> true; case _ -> false }
          if (tn == "Int" or tn == "Long") and not isLit {
            recordOverflowSite(tbl, e.span, "neg:" + tn)
          }
        }
        case _ -> ()
      }
      prefixT
    }

    case EBinop(op, l, r) -> {
      val lt0 = inferExpr(sc, tbl, sigs, diag, l)
      val rt0 = inferExpr(sc, tbl, sigs, diag, r)
      // Rust-style integer-literal inference: an unsuffixed literal operand
      // adopts the other operand's concrete integer type, so `someLong <= 0`
      // / `someLong + 1` type-check without a `0i64` suffix (#2514).
      val lt = adoptFloatLiteralType(tbl, l, adoptIntLiteralType(l, lt0, rt0), rt0)
      val rt = adoptFloatLiteralType(tbl, r, adoptIntLiteralType(r, rt0, lt0), lt0)
      // An operand `e?` that fixes no success type takes the other operand's.
      resolvePropagateOperand(sc, tbl, l, rt)
      resolvePropagateOperand(sc, tbl, r, lt)
      // A `UInt` operand beside a `ULong` one zero-extends (#7350, #7382);
      // spelling it `.toULong()` keeps every backend from having to recover
      // the operand's signedness from its shape (#7805).
      match widenArithmetic(lt, rt) {
        case Some(wt) -> {
          recordUnsignedWidening(tbl, wt, lt, l)
          recordUnsignedWidening(tbl, wt, rt, r)
        }
        case None -> ()
      }
      // The hoist binds the left operand of an eagerly evaluated operator
      // whose right one awaits (#7823); its type is the right one's.
      if not binopShortCircuits(op) and HoistEngine.exprHasHoistHazard(r) {
        recordHoistOperandType(sc, tbl, l, lt, rt)
        recordHoistedComposite(sc, tbl, r, rt, lt)
      }
      val binT = inferBinop(sc, tbl, diag, op, lt, rt, e.span)
      match op {
        case BEq -> {
          exemptArrayCopy(tbl, l)
          exemptArrayCopy(tbl, r)
          recordComparedConstructionType(sc, tbl, l, lt, rt)
          recordComparedConstructionType(sc, tbl, r, rt, lt)
        }
        case BNeq -> {
          exemptArrayCopy(tbl, l)
          exemptArrayCopy(tbl, r)
          recordComparedConstructionType(sc, tbl, l, lt, rt)
          recordComparedConstructionType(sc, tbl, r, rt, lt)
        }
        case _ -> ()
      }
      recordOverflowBinop(tbl, op, binT, e.span)
      val signSensitive = match op {
        case BLt -> true
        case BLte -> true
        case BGt -> true
        case BGte -> true
        case BDiv -> true
        case BMod -> true
        case _ -> false
      }
      if signSensitive {
        recordUnsignedOperand(tbl, lt, l)
        recordUnsignedOperand(tbl, rt, r)
      } else {
        match op {
          case BAdd -> if isPrimOf(binT, PtString) {
            recordUnsignedOperand(tbl, rt, r)
            recordShowOperand(tbl, lt, l)
            recordShowOperand(tbl, rt, r)
          }
          case _ -> ()
        }
      }
      binT
    }

    case ECall(fn, args) -> {
      // #7495: a qualified callee (`Pkg.Sub.fn(...)`) left un-collapsed by the
      // alias rewriter never passes through the `EMember` arm below.
      match fn.kind {
        case EMember(qualRecv, qualName) -> checkQualifiedMemberRef(tbl, sc, qualRecv, qualName, fn.span, diag)
        case _ -> ()
      }
      // The callee's function reference is a call, never a value to desugar.
      val calleeKey = recordCopySiteKey(fn.span)
      if not tbl.funcRefCallees.containsKey(calleeKey) {
        tbl.funcRefCallees.add(calleeKey, true)
      }
      // So is the function under explicit type arguments (`isOk[T, E](r)`),
      // which the parser leaves as `ECall(EIndex(fn, typeArgs), args)`.
      match fn.kind {
        case EIndex(inner, _) -> {
          val innerKey = recordCopySiteKey(inner.span)
          if not tbl.funcRefCallees.containsKey(innerKey) {
            tbl.funcRefCallees.add(innerKey, true)
          }
        }
        case ETypeApp(inner, _) -> {
          val innerKey = recordCopySiteKey(inner.span)
          if not tbl.funcRefCallees.containsKey(innerKey) {
            tbl.funcRefCallees.add(innerKey, true)
          }
        }
        case _ -> ()
      }
      // A distinct type's static factories: `T.from(x): T` and
      // `T.tryFrom(x): Result[T, String]` (language reference §2.3).  Typed
      // here so an operator on their result is recorded like any other
      // distinct-typed operand (#7361); they previously typed as `TyError`.
      match distinctFactoryType(sc, tbl, fn) {
        case Some(ft) -> {
          // The argument initialises the underlying value, so a bracket
          // literal builds an `array[N, T]` or `List[T]` underlying type
          // (D167) as it would for a binding of that type.
          val under = distinctUnderlyingOf(tbl, ft)
          var ai = 0
          while ai < args.count {
            match under {
              case Some(ut) -> if ai == 0 {
                val argE = callArgExpr(args[ai])
                val _ = inferExprExpected(sc, tbl, sigs, diag, argE, ut)
                if isArrayType(ut) {
                  noteArrayLiteralType(tbl, argE, ut)
                }
              } else {
                val _ = inferExpr(sc, tbl, sigs, diag, callArgExpr(args[ai]))
              }
              case None -> {
                val _ = inferExpr(sc, tbl, sigs, diag, callArgExpr(args[ai]))
              }
            }
            ai = ai + 1
          }
          return ft
        }
        case None -> ()
      }
      match nativeIntrinsicCallType(sc, tbl, sigs, diag, fn, args, e.span) {
        case Some(nt) -> return nt
        case None -> ()
      }
      match externUpcastCallType(sc, tbl, sigs, diag, fn, args, e.span) {
        case Some(ut) -> return ut
        case None -> ()
      }
      match bufferPointerCallType(sc, tbl, sigs, diag, fn, args, e.span) {
        case Some(bt) -> return bt
        case None -> ()
      }
      // Numeric / character conversion-method intrinsics (#1901): `x.toInt()`,
      // `b.toLong()`, etc.  Recognised only on a numeric/char receiver so a
      // user-defined method of the same name on some other type still falls
      // through to the general (lenient) dispatch.  The receiver is inferred
      // once here and reused below to avoid emitting diagnostics twice when a
      // user-type receiver falls through to the general EMember path (#2700).
      var cachedRecvType: Option[Type] = None
      // `.toUInt()` and `.toULong()` are the lossless zero-extending
      // widenings of the unsigned chain (`Byte < UInt < ULong`, #7805,
      // #7812), so only a receiver below the target on that chain has them;
      // conversions between the signed and unsigned chains are not
      // implemented (docs/01 §4.1).
      match fn.kind {
        case EMember(recvE, mname) -> if (mname == "toULong" or mname == "toUInt") and args.count == 0 {
          val urt = inferExpr(sc, tbl, sigs, diag, recvE)
          val toUInt = mname == "toUInt"
          if isUnsignedConvReceiver(urt) and not (toUInt and isPrimOf(urt, PtULong)) {
            if toUInt {
              return TyPrim(pt = PtUInt)
            }
            return TyPrim(pt = PtULong)
          }
          match unrefine(urt) {
            case TyPrim(_) -> {
              val convHint = if toUInt {
                " (only Byte and UInt widen to UInt)"
              } else {
                " (only Byte, UInt and ULong widen to ULong)"
              }
              diag.add(
                errorDiagnostic(
                  "T0103",
                  "conversion method '" + mname + "' is not applicable to " + renderType(urt) + convHint,
                  recvE.span
                )
              )
              return TyError
            }
            case TyError -> return TyError
            case _ -> ()
          }
          cachedRecvType = Some(value = urt)
        }
        case _ -> ()
      }
      // `[1, 2].toSlice()`: a bracket literal is a `slice[T]`, which has no
      // `toSlice`, so a literal that is the receiver of one is the array of
      // its elements (#8218).
      match fn.kind {
        case EMember(recvE, mname) -> if mname == "toSlice" and args.count == 0 {
          match peelParens(recvE).kind {
            case EList(elems) -> if elems.count > 0 {
              match inferExpr(sc, tbl, sigs, diag, recvE) {
                case TySlice(el) -> {
                  val arrT = TyArray(size = Some(value = elems.count), element = el, sizeVar = "")
                  noteArrayLiteralType(tbl, recvE, arrT)
                  cachedRecvType = Some(value = arrT)
                }
                case _ -> ()
              }
            }
            case _ -> ()
          }
        }
        case _ -> ()
      }
      match fn.kind {
        case EMember(recvE, mname) -> match numericConvTarget(mname) {
          case Some(target) -> if args.count == 0 {
            val rt = inferExpr(sc, tbl, sigs, diag, recvE)
            if isNumericOrCharType(rt) or isPrimOf(rt, PtUInt) or isPrimOf(rt, PtULong) {
              if not noteUnsignedSourceConversion(tbl, diag, recvE, rt, mname, e.span) {
                return TyError
              }
              return TyPrim(pt = target)
            }
            if isNonConvertiblePrimitive(rt) {
              diag.add(
                errorDiagnostic("T0103", "conversion method '" + mname + "' is not applicable to " + renderType(rt), recvE.span)
              )
              return TyError
            }
            match rt {
              case TyError -> return TyError
              case _ -> {
              }
            }
            cachedRecvType = Some(value = rt)
          }
          case None -> {
          }
        }
        case _ -> {
        }
      }
      // `.wrappingAdd(y)` / `.wrappingSub(y)` / `.wrappingMul(y)` /
      // `.wrappingNeg()` on an integer: the arithmetic wraps whatever the
      // build profile (D163).  Lowered to the plain operator by
      // `Lyric.ContractElaborator.lowerOverflowChecks`.
      match fn.kind {
        case EMember(wRecv, wName) -> if isWrappingMethodName(wName) {
          val wt = match cachedRecvType { case Some(t) -> t; case None -> inferExpr(sc, tbl, sigs, diag, wRecv) }
          val tn = overflowTypeName(wt)
          if tn.length > 0 {
            val arity = if wName == "wrappingNeg" { 0 } else { 1 }
            if args.count != arity {
              diag.add(
                errorDiagnostic(
                  "T0042",
                  "'" + wName + "' expects " + toString(arity) + " argument(s), got " + toString(args.count),
                  e.span
                )
              )
              return TyError
            }
            if arity == 1 {
              val argE = callArgExpr(args[0])
              val at = inferExprExpected(sc, tbl, sigs, diag, argE, wt)
              if not typeEquiv(unrefine(at), unrefine(wt)) and not typeEquiv(at, TyError) {
                diag.add(
                  errorDiagnostic(
                    "T0043",
                    "'" + wName + "' on " + renderType(wt) + " takes a " + renderType(wt) + " (got " + renderType(at) + ")",
                    argE.span
                  )
                )
              }
            }
            recordOverflowSite(tbl, e.span, "wrap:" + tn)
            return wt
          }
          cachedRecvType = Some(value = wt)
        }
        case _ -> ()
      }
      // The bitwise methods `.and/.or/.xor/.shl/.shr` of an integer are
      // lowered by every backend; here they are typed: the operand has the
      // receiver's type (the shift count is an `Int`) and so does the result
      // (#8334).
      match fn.kind {
        case EMember(bRecv, bName) -> if (bName == "and" or bName == "or" or bName == "xor" or bName == "shl" or bName == "shr") and not recvIsUnboundName(sc, bRecv) {
          val bt = match cachedRecvType { case Some(t) -> t; case None -> inferExpr(sc, tbl, sigs, diag, bRecv) }
          cachedRecvType = Some(value = bt)
          if isConcreteIntType(bt) {
            if args.count != 1 {
              diag.add(errorDiagnostic("T0042", "'" + bName + "' expects 1 argument(s), got " + toString(args.count), e.span))
              return TyError
            }
            val wantArg = if bName == "shl" or bName == "shr" { TyPrim(pt = PtInt) } else { unrefine(bt) }
            val argE = callArgExpr(args[0])
            val at = inferExprExpected(sc, tbl, sigs, diag, argE, wantArg)
            val literalFits = literalArgSatisfiesParam(tbl, wantArg, at, argE) or
              (isUnsuffixedIntLit(argE) and argSatisfiesParam(tbl, wantArg, at))
            if not typeEquiv(unrefine(at), wantArg) and not literalFits {
              diag.add(
                errorDiagnostic(
                  "T0043",
                  "'" + bName + "' on " + renderType(bt) + " takes " +
                    (if bName == "shl" or bName == "shr" { "an Int shift count" } else { "a " + renderType(bt) }) +
                    " (got " +
                    renderType(at) +
                    ")",
                  argE.span
                )
              )
            }
            // `UInt` and `ULong` shift right logically (docs/01 §5): the
            // receiver is spelled as an unsigned operand for the backends
            // that lower from the IR type (`--target native`).
            if bName == "shr" {
              recordUnsignedOperand(tbl, bt, bRecv)
            }
            return unrefine(bt)
          }
        }
        case _ -> ()
      }
      // Record `.copy(field = value, ...)` (docs/01 §2.4): a
      // non-destructive update of a record value, checked here and rewritten
      // into a full constructor call by `Lyric.Mono`.
      match fn.kind {
        case EMember(copyRecv, copyName) -> if copyName == "copy" {
          val copyRecvTy = match cachedRecvType { case Some(t) -> t; case None -> inferExpr(sc, tbl, sigs, diag, copyRecv) }
          match recordCopyTarget(tbl, sigs, copyRecvTy) {
            case Some(copyTid) -> return checkRecordCopy(sc, tbl, sigs, diag, e, copyTid, copyRecvTy, args)
            case None -> {
              cachedRecvType = Some(value = copyRecvTy)
            }
          }
        }
        case _ -> ()
      }
      match fn.kind {
        case EMember(weakRecv, weakName) -> if weakName == "upgrade" and args.count == 0 and tbl.nativeIntrinsicTypes.count > 0 {
          val weakRecvTy = match cachedRecvType { case Some(t) -> t; case None -> inferExpr(sc, tbl, sigs, diag, weakRecv) }
          match nativeWeakUpgradeType(tbl, weakRecvTy) {
            case Some(ut) -> return ut
            case None -> {
              cachedRecvType = Some(value = weakRecvTy)
            }
          }
        }
        case _ -> ()
      }
      // A4 (docs/59 §5.1): for a member callee, infer the receiver ONCE (with
      // the same module-alias leniency as the plain `EMember` arm, and reusing
      // the conversion pre-pass's cached type) and type the callee through the
      // field/builtin surface only — the method-signature space is consulted
      // arity-aware below, after the argument types are known.
      var memberRecvTy: Option[Type] = None
      var memberName = ""
      var isMemberCallee = false
      // A package-qualified module-level `val` (`Pkg.handler(x)`) is a
      // function value called through its type, not a member (#8283).
      val calleeIsQualifiedVal = match fn.kind {
        case EMember(_, _) -> match moduleValSymbolOfExpr(sc, tbl, fn) {
          case Some(_) -> true
          case None -> false
        }
        case _ -> false
      }
      match fn.kind {
        case EMember(recvE2, mname2) -> if not calleeIsQualifiedVal {
          isMemberCallee = true
          memberName = mname2
          match cachedRecvType {
            case Some(rt0) -> {
              memberRecvTy = Some(value = rt0)
              recordMemberRecvClass(tbl, recvE2.span, rt0)
            }
            case None -> {
              // `lyric.db.Postgres` in `lyric.db.Postgres.connect(...)` names a
              // host binding, not a value (#7934).
              val recvDiag: List[Diagnostic] = if isExternBlockQualifier(sc, tbl, recvE2, mname2) { newList() } else { diag }
              val rt1 = match recvE2.kind {
                case EPath(p2) -> if p2.segments.count == 1 and startsUppercase(p2.segments[0]) {
                  checkUnimportedTypeReceiver(tbl, sc, p2.segments[0], recvE2.span, diag)
                  val scratch2: List[Diagnostic] = newList()
                  inferExpr(sc, tbl, sigs, scratch2, recvE2)
                } else if isPackageDottedCallee(sc, tbl, sigs, p2.segments, mname2, args.count) {
                  // `Pkg.T.m(x)` names the function `T.m` a package declares,
                  // which need not be the package declaring `T` (an extension,
                  // #8219): `Pkg.T` is not a value.
                  val scratch3: List[Diagnostic] = newList()
                  inferExpr(sc, tbl, sigs, scratch3, recvE2)
                } else {
                  inferExpr(sc, tbl, sigs, recvDiag, recvE2)
                }
                case _ -> inferExpr(sc, tbl, sigs, recvDiag, recvE2)
              }
              memberRecvTy = Some(value = rt1)
              recordMemberRecvClass(tbl, recvE2.span, rt1)
            }
          }
        }
        case EPath(p3) -> {
          // #6487 review (#1722/#6435): a BARE call with no receiver at all
          // (`dup()`) inside a checked record-body, impl-method, or
          // protected-member body (#6483 registered protected `entry`/`func`
          // sigs and gave those bodies a real `selfType`) dispatches on the
          // implicit `self` when the name is not a local binding but IS a
          // real method of the enclosing type — codegen's `ctx.selfClass`
          // general-static-call fallback (both backends) already resolves
          // this at runtime, so turning on body-checking (#6487) must not
          // regress it into a false T0020. Gated on an ACTUAL method match
          // (`symTableMethodSigs`) so a genuinely-unknown bare name still
          // falls through to its ordinary T0020 via the `fnT`/`inferExpr`
          // path below, unchanged.
          if p3.segments.count == 1 and sc.selfChecked {
            match scopeTryFind(sc, p3.segments[0]) {
              case Some(_) -> {
              }
              case None -> match typeIdOfType(sc.selfType) {
                case Some(selfTid) -> {
                  if symTableMethodSigs(tbl, selfTid, p3.segments[0]).count > 0 {
                    isMemberCallee = true
                    memberName = p3.segments[0]
                    memberRecvTy = Some(value = sc.selfType)
                  }
                }
                case None -> {
                }
              }
            }
          }
        }
        case _ -> {
        }
      }
      val fnT = match memberRecvTy {
        case Some(rt) -> inferMemberBase(tbl, rt, memberName)
        case None -> inferExpr(sc, tbl, sigs, diag, fn)
      }
      match memberRecvTy {
        case Some(arrRt) -> if isMemberCallee and memberName == "toSlice" { noteArrayToSlice(tbl, fn, arrRt) }
        case None -> ()
      }
      // A2 (docs/59 §5.1): lambda arguments with unannotated params — and,
      // per #6814, a bare union-case-constructor argument whose name is
      // ambiguous across imported packages — are typed in two passes.  The
      // first pass types them leniently (params `TyError`, diagnostics to a
      // scratch list) so overload selection sees the same shape it always
      // has; after the signature is selected, the second pass re-checks
      // each such argument once — into the real diagnostic list — with the
      // callee's parameter type as the expectation.  When no usable
      // expectation exists the second pass is identical to the historical
      // single pass, so nothing previously accepted is newly rejected.
      //
      // #7752: an `if`/`match`/block argument is deferred the same way, so
      // its branches are checked against the selected parameter type
      // (`branchesAgainstExpected`) instead of joined bottom-up, and a
      // union-case-constructor argument (`Ok(value = English(…))`) adopts
      // the parameter's instantiation (`adoptUnionCaseExpected`) once the
      // signature is known — neither needs, nor gets, a second pass
      // otherwise.
      val argTypes: List[Type] = newList()
      var anyDeferredLambda = false
      var anyCaseCtorArg = false
      var anyPropagateArg = false
      var i = 0
      while i < args.count {
        val ae = callArgExpr(args[i])
        if argIsPropagate(ae) {
          anyPropagateArg = true
        }
        // A call holding a `?` argument may take its success type from this
        // call's parameter once the signature is known (#8181).
        if argIsPropagateCall(tbl, ae) {
          anyPropagateArg = true
        }
        if argIsLambdaLiteral(ae) or argIsAmbiguousUnionCaseCtor(tbl, ae) or argIsBranchingExpr(ae) or argIsListLiteral(ae) or argIsListHoldingTuple(ae) {
          val scratch: List[Diagnostic] = newList()
          tbl.lenientArgDepth.add(0)
          argTypes.add(inferExpr(sc, tbl, sigs, scratch, ae))
          tbl.lenientArgDepth.removeAt(tbl.lenientArgDepth.count - 1)
          anyDeferredLambda = true
        } else {
          argTypes.add(inferExpr(sc, tbl, sigs, diag, ae))
          if argIsCaseCtorCall(tbl, ae) or argIsWideningBuiltValue(tbl, ae) {
            anyCaseCtorArg = true
          }
        }
        i = i + 1
      }
      // A value-generic function under explicit generic arguments
      // (`total[3](a)`) is indexed, not named, so it has no direct signature
      // and its callee types as an error; its arguments and lengths are
      // checked here and give the call its type.
      val explicitValueGenericTy = checkExplicitValueGenericCall(sc, tbl, sigs, diag, fn, args, argTypes, e.span)
      checkExplicitTypeArgCall(sc, tbl, sigs, diag, fn, args, argTypes, e.span)
      // Try direct-sig lookup first.
      val ambiguousPick: List[ResolvedSignature] = newList()
      val directSig = findDirectSigPick(sc, tbl, sigs, fn, args, argTypes, ambiguousPick)
      match directSig {
        case Some(ds) -> noteBareCalleeFunc(tbl, fn, ds.originPackage)
        case None -> ()
      }
      recordTypeArgCallee(sc, tbl, sigs, fn, args, argTypes)
      reportExplicitCtorTypeArgs(sc, tbl, diag, fn)
      // A4: method-space resolution for a member callee — consulted only when
      // neither a direct signature nor a field/builtin member type resolved
      // (a function-typed FIELD keeps winning over a same-named method).
      var methodPick: Option[MethodCallPick] = None
      match directSig {
        case Some(_) -> {
        }
        case None -> if isMemberCallee {
          match fnT {
            case TyError -> match memberRecvTy {
              case Some(rt3) -> {
                methodPick = resolveMethodCallPick(tbl, sigs, rt3, memberName, args, argTypes, ambiguousPick)
              }
              case None -> {
              }
            }
            case _ -> {
            }
          }
        }
      }
      reportAmbiguousDefaultCall(diag, fn, ambiguousPick, e.span)
      // An element-taking member of the stdlib `List`/`Map`/`Set` that no
      // signature or field resolved is checked against the receiver's type
      // arguments (#7969).
      val collMemberParams: Option[List[CollMemberParam]] = match directSig {
        case Some(_) -> None
        case None -> match methodPick {
          case Some(_) -> None
          case None -> match fnT {
            case TyError -> match memberRecvTy {
              case Some(crt) -> if isMemberCallee {
                stdCollectionMemberParams(tbl, crt, memberName, args.count)
              } else {
                None
              }
              case None -> None
            }
            case _ -> None
          }
        }
      }
      match directSig {
        case Some(_) -> ()
        case None -> match methodPick {
          case Some(_) -> ()
          case None -> match fnT {
            case TyError -> match memberRecvTy {
              case Some(crt0) -> if isMemberCallee {
                checkStdCollectionMemberArity(tbl, diag, crt0, memberName, args.count, e.span)
              }
              case None -> ()
            }
            case _ -> ()
          }
        }
      }
      match memberRecvTy {
        case Some(arrRt) -> if isMemberCallee and isStorageType(arrRt) and memberName != "toSlice" {
          val resolved = match directSig {
            case Some(_) -> true
            case None -> match methodPick { case Some(_) -> true; case None -> false }
          }
          if not resolved {
            diag.add(arrayNoMember(arrRt, memberName, e.span))
          }
        }
        case None -> ()
      }
      // A bracket literal given to a record field of array type is typed
      // against the field (D167); a generic record's field is instantiated
      // at what the other arguments, and the literal's elements, bind.
      val ctorFieldTys = ctorArrayFieldTypes(tbl, fn, args, argTypes, TyError)
      if anyDeferredLambda or anyCaseCtorArg or anyPropagateArg {
        val lambdaSig = match directSig {
          case Some(_) -> directSig
          case None -> match methodPick { case Some(mp0) -> Some(value = mp0.sig); case None -> None }
        }
        val expectedArgTys = match collMemberParams {
          case Some(cps) -> collMemberParamTypes(cps)
          case None -> expectedCallArgTypes(tbl, fn, args, argTypes, lambdaSig, fnT)
        }
        var di = 0
        while di < args.count {
          val dae = callArgExpr(args[di])
          // An argument `e?` whose operand fixes no success type takes its
          // parameter's (#8181), a generic one instantiated from the type
          // expected of the call's result when the arguments leave it open;
          // a call holding such an argument is checked against it.
          if argIsPropagate(dae) or argIsPropagateCall(tbl, dae) {
            val pExp = expectedArgTys[di]
            val argExp = if typeIsClosedOver(pExp, sc.genericNames) {
              pExp
            } else {
              match lambdaSig {
                case Some(psig) -> genericArgFromResultExpected(
                  psig,
                  args,
                  di,
                  pExp,
                  match mapGet(tbl.methodCallResultExpected, recordCopySiteKey(e.span)) {
                    case Some(rx) -> rx
                    case None -> TyError
                  }
                )
                case None -> pExp
              }
            }
            if argIsPropagate(dae) {
              resolvePropagateOperand(sc, tbl, dae, argExp)
              // Left open, it must not instantiate a generic callee at the
              // enclosing function's success type.
              val genericCallee = match lambdaSig { case Some(gs) -> gs.generics.count > 0; case None -> false }
              if genericCallee and not typeIsClosedOver(argExp, sc.genericNames) {
                dropPropagateFallback(tbl, dae)
              }
            } else {
              resolvePropagateCallArgs(sc, tbl, sigs, dae, argExp)
            }
            // This call's own type arguments, when only its expected result
            // binds them.
            match lambdaSig {
              case Some(osig) -> match fn.kind {
                case EPath(_) -> if osig.generics.count > 0 and not typeIsClosedOver(pExp, sc.genericNames) and typeIsClosedOver(argExp, sc.genericNames) {
                  val boundArgTys: List[Type] = newList()
                  var bi = 0
                  while bi < args.count {
                    boundArgTys.add(if bi == di { argExp } else { argTypes[bi] })
                    bi = bi + 1
                  }
                  recordGenericCallTypeArgs(
                    tbl,
                    sc.genericNames,
                    osig,
                    valueGenericParamsOf(tbl, fn, args.count),
                    args,
                    boundArgTys,
                    fn.span
                  )
                }
                case _ -> ()
              }
              case None -> ()
            }
          }
          if argIsListLiteral(dae) {
            // Typed against the parameter or field only when that is an
            // array (D167); a `List` or `slice` parameter keeps the plain
            // literal type and the literal-argument rule.
            val expectedArr = match ctorFieldTys[di] { case TyError -> expectedArgTys[di]; case ft -> ft }
            argTypes[di] = if isArrayType(expectedArr) {
              inferExprExpected(sc, tbl, sigs, diag, dae, expectedArr)
            } else {
              inferExpr(sc, tbl, sigs, diag, dae)
            }
          } else if argIsListHoldingTuple(dae) {
            // A tuple holding a bracket literal is typed against a tuple
            // parameter, so the literal takes the shape (array, slice, `List`)
            // its component gives it, as under a `val` annotation (#8277).
            argTypes[di] = if isTupleType(expectedArgTys[di]) and typeIsClosedOver(expectedArgTys[di], sc.genericNames) {
              inferExprExpected(sc, tbl, sigs, diag, dae, expectedArgTys[di])
            } else {
              inferExpr(sc, tbl, sigs, diag, dae)
            }
          } else if argIsLambdaLiteral(dae) and tbl.lenientArgDepth.count > 0 {
            // Inside an enclosing lenient first pass: this lambda is re-checked
            // against its expectation when that pass's argument is (#7879).
          } else if argIsLambdaLiteral(dae) or argIsAmbiguousUnionCaseCtor(tbl, dae) or argIsBranchingExpr(dae) {
            argTypes[di] = inferExprExpected(sc, tbl, sigs, diag, dae, expectedArgTys[di])
          } else if argIsCaseCtorCall(tbl, dae) or argIsWideningBuiltValue(tbl, dae) {
            val argExp = expectedArgTys[di]
            val adopted = adoptUnionCaseExpected(tbl, argIsCaseCtorCall(tbl, dae), argTypes[di], argExp)
            // A scalar inside a value built in the argument widens to the
            // parameter's instantiation (#7813); the first pass already
            // reported the argument's diagnostics.
            argTypes[di] = if typeIsClosed(argExp) and widensStructurally(argExp, adopted) {
              val scratch: List[Diagnostic] = newList()
              val widened = inferExprExpected(sc, tbl, sigs, scratch, dae, argExp)
              if diagnosticsHaveError(scratch) {
                adopted
              } else {
                widened
              }
            } else if typeHasRangeArg(argExp) {
              // The value is built at its own type, so its range-typed
              // slots are noted against the parameter's instantiation
              // whether or not it widens (#8145).
              val scratch: List[Diagnostic] = newList()
              val _ = inferExprExpected(sc, tbl, sigs, scratch, dae, argExp)
              adopted
            } else {
              adopted
            }
          }
          di = di + 1
        }
      }
      match directSig {
        case Some(lsig) -> adoptListLiteralArgs(sc, tbl, sigs, diag, args, argTypes, lsig, callResultExpected(tbl, e))
        case None -> match methodPick {
          case Some(lmp) -> adoptListLiteralArgs(
            sc,
            tbl,
            sigs,
            diag,
            args,
            argTypes,
            lmp.sig,
            callResultExpected(tbl, e)
          )
          case None -> adoptCtorLiteralArgs(sc, tbl, sigs, diag, fn, args, argTypes)
        }
      }
      // A receiver evaluated before an argument holding an `await` or a `?`
      // is hoisted too (#7850).  A receiver whose own type is open
      // takes it from the method's receiver parameter, instantiated from the
      // other arguments or the type expected of the result (#7844).
      // A receiver passed by reference is a place the call keeps, like a
      // by-reference argument (#8179): never hoisted into a temporary.
      // A call receiver whose own type leaves a type argument open
      // (`emptyCell().orDefault(5)`) is typed the same way with no `await` in
      // the arguments, so `Lyric.Mono` need not infer the generic callee's
      // type arguments from the call alone (#8038).
      val hoistHazard = callArgsHaveHoistHazard(args)
      if isMemberCallee and (hoistHazard or openCallReceiver(sc, fn, memberRecvTy)) and not isRewrittenDotPick(tbl, methodPick, fn, memberRecvTy) {
        match fn.kind {
          case EMember(hoistRecv, _) -> match memberRecvTy {
            case Some(hoistRecvTy) -> {
              val resultExpected = match mapGet(tbl.methodCallResultExpected, recordCopySiteKey(e.span)) {
                case Some(rx) -> rx
                case None -> TyError
              }
              val recvExpected = hoistedRecvType(
                tbl,
                methodPick,
                collMemberParams,
                hoistRecvTy,
                memberName,
                args,
                argTypes,
                resultExpected
              )
              recordHoistOperandType(sc, tbl, hoistRecv, hoistRecvTy, recvExpected)
              reportOpenHoistedReceiver(sc, diag, hoistRecv, hoistRecvTy, recvExpected, memberName, hoistHazard)
            }
            case None -> ()
          }
          case _ -> ()
        }
      }
      match fn.kind {
        case EPath(fsp) -> if fsp.segments.count == 1 { checkFormatTemplate(diag, fsp.segments[0], args) }
        case _ -> ()
      }
      // A stringified unsigned value says it is unsigned (#7812).
      match fn.kind {
        case EPath(sp) -> if sp.segments.count == 1 and isStringifyingBuiltin(sp.segments[0]) {
          var si = 0
          while si < args.count {
            recordUnsignedOperand(tbl, argTypes[si], callArgExpr(args[si]))
            recordShowOperand(tbl, argTypes[si], callArgExpr(args[si]))
            si = si + 1
          }
        }
        case EMember(tsRecv, _) -> if memberName == "toString" and args.count == 0 {
          match memberRecvTy {
            case Some(tsRecvTy) -> {
              recordUnsignedOperand(tbl, tsRecvTy, tsRecv)
              match methodPick {
                case None -> recordShowOperand(tbl, tsRecvTy, tsRecv)
                case Some(_) -> ()
              }
            }
            case None -> ()
          }
        }
        case _ -> ()
      }
      // A `.copy(...)` argument is stored into the new record's field.
      if isMemberCallee and memberName == "copy" {
        noteArrayStores(tbl, args, argTypes)
      }
      // `xs.add(x)` on an open binding fixes its element type (#7788).
      if isMemberCallee and memberName == "add" {
        match fn.kind {
          case EMember(addRecv, _) -> noteOpenBindingAdd(sc, tbl, addRecv, argTypes)
          case _ -> ()
        }
      }
      match collMemberParams {
        case Some(cps) -> recordCollectionArgWidenings(tbl, cps, args, argTypes)
        case None -> ()
      }
      recordGeneratorCallSite(tbl, e.span, false)
      recordEmptyCollectionCtorSite(tbl, e.span, false)
      recordAsyncCallSite(tbl, e.span, false)
      clearEffectCallSite(tbl, e.span)
      match directSig {
        case Some(_) -> ()
        case None -> recordExplicitTypeArgCall(sc, tbl, sigs, e.span, fn, args, argTypes)
      }
      match directSig {
        case Some(sig) -> {
          match fn.kind {
            case EPath(_) -> recordMethodCallArity(tbl, fn, args.count, sig.params.count, false)
            // `Type.f(x, ...)`: a dot-named function called through its type.
            // The MSIL lowering rebuilds the callee as a path over the
            // receiver's span, so it is recorded there too.
            case EMember(callRecv, callMember) -> {
              recordMethodCallArity(tbl, fn, args.count, sig.params.count, false)
              recordCalleeArityAt(tbl, recordCopySiteKey(callRecv.span) + ":" + callMember, args.count, sig.params.count)
            }
            case _ -> ()
          }
          recordGeneratorCallSite(tbl, e.span, sig.isGenerator)
          recordAsyncCallSite(tbl, e.span, sig.isAsync and not sig.isGenerator)
          recordEffectCallSite(tbl, e.span, sig, fn)
          recordEmptyCollectionCtorSite(tbl, e.span, isStdEmptyCollectionCtor(sig, fn))
          if callArgsHaveHoistHazard(args) {
            recordHoistedCallArgs(sc, tbl, args, argTypes, sigExpectedArgTypes(sig, None, args, argTypes))
          }
          checkContractCallPure(sc, diag, sig, fn, e.span)
          checkCallArgsAgainstSig(sc, tbl, sigs, diag, sig, args, argTypes, e.span)
          if callArgsHaveNamed(args) or callArgsHaveHoistHazard(args) or callArgsHaveElementPlace(args) {
            recordSigArgOrderSite(
              sc,
              tbl,
              e.span,
              fn,
              args,
              argTypes,
              sig,
              sigExpectedArgTypes(sig, None, args, argTypes),
              memberRecvTy
            )
          }
          recordGenericArgWidenings(tbl, sig, None, args, argTypes)
          match fn.kind {
            case EPath(_) -> recordGenericCallTypeArgs(
              tbl,
              sc.genericNames,
              sig,
              valueGenericParamsOf(tbl, fn, args.count),
              args,
              argTypes,
              fn.span
            )
            case _ -> ()
          }
          if sig.originPackage.length > 0 and sig.originPackage != symTableScopePkg(tbl) {
            recordSigArgConversions(tbl, sig, args, argTypes)
          }
          // H15: verify where-clause bounds on generic call sites.
          checkBoundsSatisfied(tbl, diag, sig, args, argTypes, e.span)
          // Instantiate a generic return type from the argument types (#1488
          // category B) so `unwrapOr(opt, 0): T` yields `Int`, not `TyVar("T")`.
          var instRet = directCallType(tbl, diag, fn, sig, args, argTypes)
          match bodyMethodCalleeBinding(tbl, sigs, fn, args, argTypes) {
            // `T.m(x, args)` binding a method in the body of `x`'s type is
            // what `x.m(args)` calls (D181): the call is written that way
            // for the backends, which have no function `T.m` for a body
            // method.  Its arguments are paired in that shape.
            case Some(bm) -> {
              val member = memberOfDotted(fn)
              val restArgs = tailArgs(args)
              val restTypes = tailTypes(argTypes)
              recordBodyMethodCallRewrite(tbl, fn, args, member, withReceiverParam(bm, argTypes[0]))
              val siteKey = recordCopySiteKey(e.span)
              if tbl.argOrderSites.containsKey(siteKey) {
                tbl.argOrderSites.remove(siteKey)
              }
              if callArgsHaveNamed(restArgs) or callArgsHaveHoistHazard(restArgs) or callArgsHaveElementPlace(restArgs) {
                val asMember = Expr(kind = EMember(receiver = callArgExpr(args[0]), memberName = member), span = fn.span)
                recordSigArgOrderSite(
                  sc,
                  tbl,
                  e.span,
                  asMember,
                  restArgs,
                  restTypes,
                  bm,
                  sigExpectedArgTypes(bm, None, restArgs, restTypes),
                  Some(value = argTypes[0])
                )
              }
            }
            case None -> if dottedFuncCallee(tbl, fn) {
              // `T.m(x, args)` binds the function `x.m(args)` does (#8219);
              // an extension is called through the package declaring it,
              // and a function declared through an alias by the aliased
              // type's name, which it is compiled under.
              val dotRecv = if argTypes.count > 0 { argTypes[0] } else { TyError }
              val restArgs = tailArgs(args)
              val restTypes = tailTypes(argTypes)
              val member = memberOfDotted(fn)
              val viaType = dottedPathName(fn).length > 0
              if viaType and reportAmbiguousDotNamed(tbl, sigs, diag, dotRecv, member, args.count - 1, restArgs, restTypes, fn.span) {
                instRet = TyError
              }
              val written = qualifiedDottedName(fn)
              val canonical = canonicalDottedName(tbl, fn)
              // A primitive's or distinct type's function named through its
              // package (`Pkg.Int.neg(k)`) is called by its own name too.
              val qualifiedPlain = not viaType and receiverNeedsPlainDotCall(tbl, Some(value = dotRecv))
              // So is one named through this package (`Main.Bag.top(b)` in
              // `Main`): the backends resolve a package prefix only for
              // another package.
              val ownPkgQualified = calleePackagePrefix(fn) == symTableScopePkg(tbl)
              if isDotNamedExtension(tbl, dotRecv, sig) or (viaType and foreignDotNamedShadowed(tbl, sigs, dotRecv, member, sig)) or canonical != written or qualifiedPlain or ownPkgQualified {
                recordDotCallRewrite(tbl, fn.span, canonical, sig, false)
              } else {
                recordByRefDotCall(tbl, fn.span, written, sig, false)
              }
            }
          }
          // A generic call's result type is evidence for `Lyric.Mono` where
          // it cannot infer the call's type arguments itself (#7865).
          if sig.generics.count > 0 {
            recordResultTypeAt(tbl, instRet, e.span)
          }
          instRet
        }
        case None -> match unionCaseSymbolOf(tbl, fn) {
          case Some(caseSym) -> {
            noteBareCalleeSym(tbl, fn, caseSym)
            val caseTy = inferUnionCaseConstruction(tbl, diag, caseSym, args, argTypes, e.span, true)
            noteCtorArgFlows(sc, tbl, fn, args, caseTy)
            recordCtorArgOperandTypes(sc, tbl, fn, args, argTypes, caseTy)
            recordCtorArgOrderSite(sc, tbl, e.span, fn, args, argTypes, caseSym, caseTy)
            caseTy
          }
          case None -> match constructorSymbolOf(tbl, fn) {
            case Some(ctorSym) -> {
              noteBareCalleeSym(tbl, fn, ctorSym)
              val ctorTy = inferConstruction(tbl, diag, ctorSym, args, argTypes, e.span)
              noteArrayStores(tbl, args, argTypes)
              noteCtorArgFlows(sc, tbl, fn, args, ctorTy)
              recordCtorArgOperandTypes(sc, tbl, fn, args, argTypes, ctorTy)
              recordCtorArgOrderSite(sc, tbl, e.span, fn, args, argTypes, ctorSym, ctorTy)
              ctorTy
            }
            // #6838: the callee names a union/enum TYPE itself, not one of its
            // cases (`Pkg.DbError(message = "…")`). No such constructor exists,
            // so it never resolves to a function token. Diagnose it here
            // (T0125) as a clear, early type error — left undiagnosed it
            // degraded to `TyError` in the fnT fallback below and reached
            // codegen as an unresolved call (a silent bogus
            // `(DbError)(object)<arg>` conversion on ≤0.5.0, a baffling T0123
            // emit-time panic once codegen stopped papering over unresolved
            // callees). Runs only after `unionCaseSymbolOf` and
            // `constructorSymbolOf` both missed, so a valid case/record ctor is
            // never intercepted.
            case None -> match unionOrEnumTypeSymbolOf(tbl, fn) {
              case Some(uSym) -> {
                val ctorHint = unionOrEnumCaseNamesHint(uSym)
                val baseMsg = "cannot construct '" + uSym.name +
                  "' by its type name; a union or enum is built through one of its cases, not the type itself"
                val fullMsg = if ctorHint == "" { baseMsg } else { baseMsg + " (cases: " + ctorHint + ")" }
                diag.add(errorDiagnostic("T0125", fullMsg, e.span))
                TyError
              }
              case None -> match methodPick {
                case Some(mp) -> {
                  val pickedDotNamed = match mp.fullSig { case Some(_) -> true; case None -> false }
                  recordMethodCallArity(tbl, fn, args.count, mp.sig.params.count, pickedDotNamed)
                  recordGeneratorCallSite(tbl, e.span, mp.sig.isGenerator)
                  recordAsyncCallSite(tbl, e.span, mp.sig.isAsync and not mp.sig.isGenerator)
                  recordEffectCallSite(tbl, e.span, mp.sig, fn)
                  checkContractCallPure(sc, diag, mp.sig, fn, e.span)
                  checkCallArgsAgainstSig(sc, tbl, sigs, diag, mp.sig, args, argTypes, e.span)
                  val mpHazard = callArgsHaveHoistHazard(args)
                  val mpNamed = callArgsHaveNamed(args)
                  val mpElem = callArgsHaveElementPlace(args) or calleeReceiverIsElementPlace(fn)
                  if mpHazard or mpNamed or mpElem {
                    val mpExpected = match mp.fullSig {
                      case Some(fullS) -> match memberRecvTy {
                        case Some(_) -> sigExpectedArgTypes(fullS, memberRecvTy, args, argTypes)
                        case None -> sigExpectedArgTypes(mp.sig, None, args, argTypes)
                      }
                      case None -> sigExpectedArgTypes(mp.sig, None, args, argTypes)
                    }
                    if mpHazard {
                      recordHoistedCallArgs(sc, tbl, args, argTypes, mpExpected)
                    }
                    if mpNamed or mpHazard or mpElem {
                      match rewrittenDotFullSig(tbl, methodPick, fn, memberRecvTy) {
                        // The call becomes `T.m(recv, args)` (#8179, #8217),
                        // so its argument order is recorded in that shape,
                        // the receiver its first argument.
                        case Some(fullS) -> {
                          val fullArgs: List[CallArg] = newList()
                          val fullArgTypes: List[Type] = newList()
                          val fullExpected: List[Type] = newList()
                          match fn.kind {
                            case EMember(fr, _) -> fullArgs.add(CAPositional(expr = fr))
                            case _ -> ()
                          }
                          fullArgTypes.add(match memberRecvTy { case Some(frt) -> frt; case None -> TyError })
                          fullExpected.add(TyError)
                          for a in args {
                            fullArgs.add(a)
                          }
                          for at in argTypes {
                            fullArgTypes.add(at)
                          }
                          for xt in mpExpected {
                            fullExpected.add(xt)
                          }
                          val noSegs: List[String] = newList()
                          val plainCallee = Expr(kind = EPath(path = ModulePath(segments = noSegs, span = fn.span)), span = fn.span)
                          val noRecvTy: Option[Type] = None
                          recordSigArgOrderSite(sc, tbl, e.span, plainCallee, fullArgs, fullArgTypes, fullS, fullExpected, noRecvTy)
                        }
                        case None -> recordSigArgOrderSite(sc, tbl, e.span, fn, args, argTypes, mp.sig, mpExpected, memberRecvTy)
                      }
                    }
                  }
                  checkBoundsSatisfied(tbl, diag, mp.sig, args, argTypes, e.span)
                  match mp.fullSig {
                    case Some(fullS) -> match memberRecvTy {
                      case Some(_) -> recordGenericArgWidenings(tbl, fullS, memberRecvTy, args, argTypes)
                      case None -> ()
                    }
                    case None -> recordGenericArgWidenings(tbl, mp.sig, None, args, argTypes)
                  }
                  match mp.fullSig {
                    case Some(fullS) -> {
                      match fn.kind {
                        case EMember(byRecv, _) -> {
                          match memberRecvTy {
                            case Some(byRt) -> {
                              val byTname = dotNamedOwnerName(byRt)
                              if byTname.length > 0 {
                                if receiverNeedsPlainDotCall(tbl, memberRecvTy) or isDotNamedExtension(tbl, byRt, fullS) {
                                  recordDotCallRewrite(tbl, fn.span, byTname + "." + memberName, fullS, true)
                                } else {
                                  recordByRefDotCall(tbl, fn.span, byTname + "." + memberName, fullS, true)
                                }
                              }
                            }
                            case None -> ()
                          }
                          if fullS.params.count > 0 and modeNeedsLValue(fullS.params[0].mode) {
                            checkByRefReceiver(sc, tbl, sigs, diag, byRecv, memberName, e.span)
                          }
                        }
                        case _ -> ()
                      }
                      val extArgs: List[Type] = newList()
                      match memberRecvTy {
                        case Some(rt4) -> extArgs.add(rt4)
                        case None -> extArgs.add(TyError)
                      }
                      var xi = 0
                      while xi < argTypes.count {
                        extArgs.add(argTypes[xi])
                        xi = xi + 1
                      }
                      val ambiguous = match memberRecvTy {
                        case Some(amRt) -> reportAmbiguousDotNamed(
                          tbl,
                          sigs,
                          diag,
                          amRt,
                          memberName,
                          args.count,
                          args,
                          argTypes,
                          fn.span
                        )
                        case None -> false
                      }
                      if ambiguous {
                        TyError
                      } else {
                        dottedMethodCallType(tbl, diag, fn, memberRecvTy, memberName, args, extArgs, fullS)
                      }
                    }
                    case None -> instantiateReturnType(mp.sig, 0, args, argTypes)
                  }
                }
                case None -> {
                  // No declared signature to pair against, but a name given
                  // twice is never a valid call (#7846).
                  val noSlots: List[String] = newList()
                  val _ = reportRepeatedCallArgs(diag, "T0042", "parameter", args, noSlots)
                  if isMemberCallee {
                    match fnT {
                      case TyError -> match memberRecvTy {
                        case Some(rt5) -> {
                          maybeUnknownMemberDiag(tbl, sigs, diag, rt5, memberName, fn.span, true)
                          maybeUnknownTypeParamMethodDiag(sc, tbl, sigs, diag, rt5, memberName, fn.span)
                        }
                        case None -> {
                        }
                      }
                      case _ -> {
                      }
                    }
                  }
                  match collMemberParams {
                    case Some(cps) -> match memberRecvTy {
                      case Some(crt2) -> checkStdCollectionMemberArgs(
                        tbl,
                        diag,
                        crt2,
                        memberName,
                        cps,
                        args,
                        argTypes,
                        sc.genericNames,
                        e.span
                      )
                      case None -> ()
                    }
                    case None -> ()
                  }
                  match fnT {
                    case TyFunction(paramTypes, ret, fnIsAsync) -> {
                      recordAsyncCallSite(tbl, e.span, fnIsAsync)
                      val minArgs = paramTypes.count - builtinOptionalTrailingArgs(fn, memberRecvTy)
                      if argTypes.count > paramTypes.count or argTypes.count < minArgs {
                        val expectedMsg = if minArgs == paramTypes.count {
                          toString(paramTypes.count) + " argument(s)"
                        } else {
                          toString(minArgs) + "–" + toString(paramTypes.count) + " argument(s)"
                        }
                        diag.add(errorDiagnostic("T0042", "expected " + expectedMsg + ", got " + toString(argTypes.count), e.span))
                      } else {
                        var k = 0
                        while k < argTypes.count {
                          if k < args.count {
                            noteExpectedFlow(sc, tbl, callArgExpr(args[k]), paramTypes[k])
                          }
                          val kLiteralOk = k < args.count and literalArgSatisfiesParam(tbl, paramTypes[k], argTypes[k], callArgExpr(args[k]))
                          if k < args.count {
                            noteRangeSlot(tbl, paramTypes[k], callArgExpr(args[k]), "argument " + toString(k + 1))
                          }
                          if not (if k < args.count { argFlowSatisfies(tbl, paramTypes[k], argTypes[k], callArgExpr(args[k])) } else { argSatisfiesParam(tbl, paramTypes[k], argTypes[k]) }) and not kLiteralOk {
                            diag.add(
                              errorDiagnostic(
                                "T0043",
                                argTypeMismatchSubject(argTypes[k], args, k) + " does not match parameter type " + renderType(paramTypes[k]) +
                                  typeMismatchHint(tbl, paramTypes[k], argTypes[k]),
                                e.span
                              )
                            )
                          } else if unconvertibleWidening(paramTypes[k], argTypes[k]) {
                            diag.add(
                              errorDiagnostic(
                                "T0043",
                                "argument type " + renderType(argTypes[k]) + " cannot be widened to " + renderType(paramTypes[k]) +
                                  " through a function value; pass a " +
                                  renderType(paramTypes[k]) +
                                  " value",
                                e.span
                              )
                            )
                          } else if k < args.count {
                            recordArgConversion(tbl, args[k], paramTypes[k], argTypes[k])
                          }
                          k = k + 1
                        }
                        recordFuncValueCall(sc, tbl, fn, memberRecvTy, memberName, fnT, args.count, e.span)
                        if callArgsHaveHoistHazard(args) {
                          recordHoistedCallArgs(sc, tbl, args, argTypes, paramTypes)
                        }
                      }
                      ret
                    }
                    case TyError -> match explicitValueGenericTy {
                      case Some(vt) -> vt
                      case None -> match explicitTypeArgCallType(sc, tbl, sigs, fn, args, argTypes) {
                        case Some(et) -> et
                        case None -> match collMemberParams {
                          case Some(_) -> match memberRecvTy {
                            case Some(crt3) -> stdCollectionMemberResult(
                              tbl,
                              crt3,
                              memberName,
                              args.count
                            )
                            case None -> TyError
                          }
                          case None -> TyError
                        }
                      }
                    }
                    case _ -> {
                      diag.add(errorDiagnostic("T0044", "called value of non-function type " + renderType(fnT), e.span))
                      TyError
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    case EMember(recv, name) -> {
      // #6485/#6487: `self.field` inside a protected-type entry/func body,
      // a record-body method, or an impl method.  `self` is a keyword —
      // every occurrence parses to the dedicated `ESelf` node, never
      // `EPath(["self"])` — so it can never resolve through the ordinary
      // scope lookup the bare-name spelling uses (#6481's
      // `extraLocals`/`scopeTryFind`, which only protected members have
      // anyway). Absent this, `inferExpr(recv)` types `self` as the
      // placeholder `TySelf`, which `inferMemberBase` cannot resolve to a
      // field and which silently degrades to `TyError` with no diagnostic.
      // `sc.selfChecked` (set by all three checked-member-body callers,
      // independent of `sc.selfFields.count` so a zero-field member still
      // gets strict resolution, #6487) gates this branch: a hit in
      // `sc.selfFields` types the field read exactly like the bare-name
      // spelling; a miss inside that same context is a genuine unknown
      // field, reported the same way an unknown bare name is (T0020).
      // Every other `self`-bearing context reaching this checker today
      // (interface default-method bodies, a `Self`-typed ordinary
      // parameter) has `selfChecked = false` and falls through unchanged to
      // the pre-existing lenient `TySelf` handling below.
      match recv.kind {
        case ESelf -> {
          if sc.selfChecked {
            match mapGet(sc.selfFields, name) {
              case Some(t) -> return t
              case None -> {
                diag.add(errorDiagnostic("T0020", "unknown name 'self." + name + "'", e.span))
                return TyError
              }
            }
          }
        }
        case _ -> {
        }
      }
      checkQualifiedMemberRef(tbl, sc, recv, name, e.span, diag)
      match qualifiedEnumCaseType(sc, tbl, recv, name) {
        case Some(enumTy) -> return enumTy
        case None -> ()
      }
      // A package-qualified module-level `val` (`Pkg.v`, the file's own
      // package included) reads as the bare name does (#8283).
      match moduleValSymbolOfExpr(sc, tbl, e) {
        case Some(vsym) -> match vsym.kind {
          case DKVal(vd) -> {
            checkImportedVisibility(tbl, vsym, e.span, diag)
            return moduleValReadType(tbl, sigs, vsym, vd)
          }
          case _ -> ()
        }
        case None -> ()
      }
      // A full package path used as a function value (`Pkg.Sub.fn`, not
      // collapsed by the alias rewriter since it is not a call callee).  A
      // root bound as a local is a field chain, never a package.
      val chainSegs: List[String] = newList()
      if flattenCalleePathSegs(e, chainSegs) and chainSegs.count >= 3 {
        match scopeTryFind(sc, chainSegs[0]) {
          case Some(_) -> ()
          case None -> {
            val qualSegs: List[String] = newList()
            var qi = 0
            while qi < chainSegs.count - 1 {
              qualSegs.add(chainSegs[qi])
              qi = qi + 1
            }
            val qualPkg = modulePathJoin(qualSegs)
            if symTablePackageHasAnySymbol(tbl, qualPkg) or anyPackageEndsWithQualifier(tbl, qualPkg) {
              match resolveQualifiedFuncValue(tbl, sigs, diag, qualPkg, name, e.span) {
                case Some(ft) -> return ft
                case None -> ()
              }
            }
          }
        }
      }
      // A bare single-segment receiver whose name follows the **module/type
      // naming convention** (UpperCamelCase) and does not resolve is treated as
      // a *module reference* (e.g. `Str.substring(...)` where a `Std.String as
      // Str` alias survived alias-rewriting in a multi-file bundle), not a hard
      // unknown-name error — qualified resolution is owned by the member/call
      // layer, and multi-segment qualified paths are already lenient here.  A
      // *lowercase* single-segment receiver is a value (a `val`/`var`/param), so
      // a typo like `stirng.method()` still surfaces its T0020.  Other receiver
      // shapes keep their diagnostics.  (This became reachable once `if`/block
      // branch bodies are type-checked, #1943.)
      val rt = match recv.kind {
        case EPath(p) -> if p.segments.count == 1 and startsUppercase(p.segments[0]) {
          checkUnimportedTypeReceiver(tbl, sc, p.segments[0], recv.span, diag)
          val scratch: List[Diagnostic] = newList()
          inferExpr(sc, tbl, sigs, scratch, recv)
        } else {
          inferExpr(sc, tbl, sigs, diag, recv)
        }
        case _ -> inferExpr(sc, tbl, sigs, diag, recv)
      }
      recordMemberRecvClass(tbl, recv.span, rt)
      match unrefine(rt) {
        case TyArray(Some(n), _, _) -> if name == "length" {
          exemptArrayCopy(tbl, recv)
          if not tbl.arrayLenSites.containsKey(recordCopySiteKey(e.span)) {
            tbl.arrayLenSites.add(recordCopySiteKey(e.span), n)
          }
        } else if name == "toSlice" {
          diag.add(arrayToSliceNotCalled(rt, e.span))
        } else {
          diag.add(arrayNoMember(rt, name, e.span))
        }
        case TyArray(None, _, _) -> if not inValueGenericBody(tbl) { diag.add(arrayUnknownLength(rt, e.span)) }
        case _ -> if isBufferType(rt) {
          if name == "length" {
            exemptArrayCopy(tbl, recv)
            if not tbl.arrayLenSites.containsKey(recordCopySiteKey(e.span)) {
              tbl.arrayLenSites.add(recordCopySiteKey(e.span), runtimeArrayLength())
            }
          } else {
            diag.add(arrayNoMember(rt, name, e.span))
          }
        }
      }
      match distinctMemberType(tbl, diag, rt, name, e.span) {
        case Some(dt) -> return dt
        case None -> ()
      }
      match unrefine(rt) {
        case TyVar(tvName) -> if sc.genericNames.contains(tvName) {
          diag.add(
            errorDiagnostic(
              "T0197",
              "no member '" + name + "' on type parameter '" + tvName +
                "': a value of a type parameter has no fields; only the methods of its `where` bounds can be called on it",
              e.span
            )
          )
          return TyError
        }
        case _ -> ()
      }
      // A field declared as the record's own type parameter, read through an
      // instance at the enclosing generic's type parameter, is that type
      // parameter; a member read of it is as unknown as one of the parameter
      // itself (#8018).  The field read alone keeps its erased type: typing
      // it `T` would send closures over it down the strongly typed path.
      match unrefine(rt) {
        case TyError -> match recv.kind {
          case EMember(innerRecv, innerName) -> {
            val scratch: List[Diagnostic] = newList()
            val innerRecvTy = inferExpr(sc, tbl, sigs, scratch, innerRecv)
            match rigidTypeParamField(tbl, innerRecvTy, innerName, sc.genericNames) {
              case TyVar(tvName) -> {
                diag.add(
                  errorDiagnostic(
                    "T0197",
                    "no member '" + name + "' on type parameter '" + tvName +
                      "': a value of a type parameter has no fields; only the methods of its `where` bounds can be called on it",
                    e.span
                  )
                )
                return TyError
              }
              case _ -> ()
            }
          }
          case _ -> ()
        }
        case _ -> ()
      }
      checkProtectedFieldAccess(sc, tbl, diag, rt, name, e.span)
      val memberTy = inferMember(tbl, sigs, diag, rt, name, e.span)
      val readTy = match memberTy {
        case TyError -> rigidTypeParamField(tbl, rt, name, sc.genericNames)
        case _ -> memberTy
      }
      recordResultTypeAt(tbl, readTy, e.span)
      readTy
    }

    case EPropagate(inner) -> inferPropagate(sc, tbl, sigs, diag, e, inner, TyError)

    // `await t` on a `Task[R]` handle yields `R`; any other operand keeps its
    // own type (a direct async call is already its result, docs/01 §7.1).
    case EAwait(inner) -> {
      val awaited = inferExpr(sc, tbl, sigs, diag, inner)
      match taskResultType(awaited) {
        case Some(r) -> r
        case None -> awaited
      }
    }
    case EYield(inner) -> {
      inferExpr(sc, tbl, sigs, diag, inner)
      TyPrim(PtUnit)
    }
    case ESpawn(inner) -> {
      val result = inferExpr(sc, tbl, sigs, diag, inner)
      recordTaskHandleTypeAt(tbl, result, e.span)
      taskType(result)
    }
    case EOld(inner) -> inferExpr(sc, tbl, sigs, diag, inner)

    // Inside a checked member body (`sc.selfChecked`, #6487) a whole-`self`
    // read has the concrete receiver type — a record-body method passing
    // `self` to a sibling UFCS function (`evictKey(self, key)`) must match
    // that function's concrete parameter type, not an opaque `Self` that
    // T0043 rejects.  A free function whose first parameter is `self` (the
    // UFCS method form, D037) reads that parameter's declared type, so
    // `self.field` is typed like any other parameter's field.  Interface
    // default-method bodies and other lenient contexts keep `TySelf`.
    case ESelf -> if sc.selfChecked {
      sc.selfType
    } else {
      match scopeTryFind(sc, "self") {
        case Some(b) -> b.ty
        case None -> TySelf
      }
    }
    // `result` in an `ensures:` clause has the enclosing function's declared
    // return type, carried on the scope (D081).
    // `result` is a contextual keyword (codegen.l:2833 agrees): a user-declared
    // local / parameter named `result` shadows the contract return-value
    // reference.  The pattern parser accepts `KwResult` in binding position, so
    // `val result = …` is a real binding whose reads must take its type — not the
    // enclosing function's return type.  Only when no such binding is in scope
    // (a genuine `ensures:` clause, pre-elaboration) does `EResult` mean the
    // return value.  This mirrors codegen, which loads `fctx.slots["result"]`
    // first and falls back to the result temp only inside contracts.
    case EResult -> match scopeTryFind(sc, "result") { case Some(b) -> b.ty; case None -> sc.returnTy }

    // TyError for unknown receivers is intentional: codegen owns exotic receiver behaviour.
    case EIndex(recvE, indices) -> {
      val rt = inferExpr(sc, tbl, sigs, diag, recvE)
      // The receiver of an index holding an `await` or a `?` is hoisted
      // (#7850).
      var hoistIdx = 0
      while hoistIdx < indices.count {
        if HoistEngine.exprHasHoistHazard(indices[hoistIdx]) {
          recordHoistOperandType(sc, tbl, recvE, rt, TyError)
          hoistIdx = indices.count
        } else {
          hoistIdx = hoistIdx + 1
        }
      }
      var ii = 0
      while ii < indices.count {
        // A bare primitive TYPE name as an index is the surface explicit
        // type application (`mapKeys[String, String](m)` parses as
        // `ECall(EIndex(...))`, never `ETypeApp`); inferring it as a value
        // expression produced a spurious `T0020 unknown name 'String'`.
        // Record/interface names already resolve through the symbol table
        // without a diagnostic; primitives are not value symbols, so skip
        // them here.  A genuine value index never names a primitive type.
        val isPrimTypeIndex = match indices[ii].kind {
          case EPath(ip) -> {
            if ip.segments.count == 1 {
              // An enclosing type parameter names a type here too
              // (`firstOf[T](...)` inside `func g[T]`, #8280), unless a local
              // of the same name shadows it.
              val shadowedByLocal = match scopeTryFind(sc, ip.segments[0]) { case Some(_) -> true; case None -> false }
              if not shadowedByLocal and listContainsStr(sc.genericNames, ip.segments[0]) {
                true
              } else {
                match primFromString(ip.segments[0]) {
                  case Some(_) -> true
                  case None -> false
                }
              }
            } else {
              false
            }
          }
          case _ -> false
        }
        if not isPrimTypeIndex {
          inferExpr(sc, tbl, sigs, diag, indices[ii])
        }
        ii = ii + 1
      }
      if isBufferType(rt) and not bufferReceiverIsStable(recvE) {
        diag.add(
          errorDiagnostic(
            "T0174",
            "a buffer is indexed through a variable, a field path or an element of one: bind " +
              "the buffer to a `val` first, because indexing reads its length as well as its element",
            recvE.span
          )
        )
      }
      if isStorageType(rt) {
        exemptArrayCopy(tbl, recvE)
        if indices.count == 1 {
          val idxScratch: List[Diagnostic] = newList()
          noteArrayIndex(tbl, diag, rt, indices[0], inferExpr(sc, tbl, sigs, idxScratch, indices[0]), e.span)
        }
      }
      val nonIndexable = nonIndexableNativeKind(tbl, rt)
      if nonIndexable != "" {
        diag.add(
          errorDiagnostic(
            "T0143",
            "cannot index into '" + renderType(rt) + "': " + nonIndexable +
              " is not indexable (only slices, arrays, String, and the stdlib List and Map support `[...]`)" +
              shadowedStdCollectionNote(tbl, rt),
            e.span
          )
        )
      }
      indexElementType(tbl, rt)
    }
    // ETypeApp: a type-application expression `foo[T]`.  Pass through to the
    // inner function so `ECall(ETypeApp(fn, targs), vargs)` finds the function
    // type for the direct-sig fallback instead of silently inferring TyError.
    case ETypeApp(fnExpr, _) -> inferExpr(sc, tbl, sigs, diag, fnExpr)
    // ELambda: a closure literal `|x: T, y: U| { body }`.  Resolve each
    // annotated parameter type (unannotated params stay lenient as TyError),
    // bind them into a fresh scope frame, check the body, then return the
    // inferred function type.  Bare inference has no contextual expectation;
    // call-argument and annotated-binding positions route through
    // `inferExprExpected` instead so unannotated params adopt the expected
    // function type's parameter types (docs/59 A2).
    case ELambda(lambdaParams, body) -> {
      val noExpectedRet: Option[Type] = None
      val blt = inferLambda(sc, tbl, sigs, diag, lambdaParams, body, newList(), noExpectedRet)
      recordLambdaUnitSite(tbl, blt, e.span)
      blt
    }
    // An `if`/`else` expression takes the unified type of its branches.  An
    // `if` without an `else` produces no value on the false path, so it is
    // `Unit` (the parser desugars a statement-position brace-`if` so a trailing
    // operator does not glue — #1943).  Each branch is an `ExprOrBlock`: a block
    // branch is typed (divergence-aware) by `checkBlock` (D081), so an
    // early-`return` branch is `Never` and unifies cleanly.  Reached only via
    // a plain `inferExpr` dispatch, which always means the result is wanted
    // as a value (a statement-position `if` is special-cased directly in
    // `checkBlock`'s `SExpr` arm — #3362) — pass `true` for `isValuePosition`.
    // #7696: `TyError` for `tailExpected` — this `if`/`match`/block is an
    // ordinary subexpression (a binding initialiser, a call argument, …),
    // not necessarily the enclosing function's own tail value, so a bracket
    // literal inside it must keep inferring as `slice[T]` exactly as before
    // (see `inferExprOrBlock`'s header comment).
    case EIf(cond, thenBranch, elseBranch, _) -> inferIfExpr(
      sc,
      tbl,
      sigs,
      diag,
      e,
      cond,
      thenBranch,
      elseBranch,
      true,
      TyError
    )
    // Reached only via a plain `inferExpr` dispatch (see the `EIf` case
    // above) — always value position (#3362).
    case EMatch(scrutinee, arms) -> inferMatchExpr(sc, tbl, sigs, diag, e, scrutinee, arms, true, TyError)
    // A value-position brace block / `unsafe { … }` has the type of its trailing
    // expression (or `Unit` if it ends in a statement, or `Never` if it diverges)
    // — `checkBlock` walks the statements (binding locals) and returns that type.
    // sc.genericNames / sc.returnTy / sc.returnTyExpr are passed explicitly here
    // because checkBlock still carries them as standalone parameters (follow-up:
    // remove them once all branch forms are wired and checkBlock can read them
    // from sc directly). `TyError` for `tailExpected`: see the `EIf` case above.
    case EBlock(blk) -> checkBlock(
      sc,
      tbl,
      sigs,
      sc.genericNames,
      sc.returnTy,
      sc.returnTyExpr,
      diag,
      blk,
      true,
      TyError
    )
    case EUnsafe(blk) -> checkBlock(
      sc,
      tbl,
      sigs,
      sc.genericNames,
      sc.returnTy,
      sc.returnTyExpr,
      diag,
      blk,
      true,
      TyError
    )
    case ETry(_) -> TyError
    // EForall/EExists: quantifier expressions used in contracts.  Bind the
    // quantified variables into a fresh scope, infer the optional `where`
    // filter and the body predicate, then return Bool — quantifiers always
    // produce a boolean truth value.
    case EForall(binders, whereOpt, body, _) -> {
      val fctx = newGenericContext()
      scopePush(sc)
      var fi = 0
      while fi < binders.count {
        val bt = resolveType(tbl, fctx, diag, binders[fi].ty)
        if binders[fi].name != "_" {
          scopeAdd(sc, LocalBinding(name = binders[fi].name, ty = bt, isMutable = false))
        }
        fi = fi + 1
      }
      match whereOpt {
        case Some(we) -> requireQuantifierBool(diag, "forall", "where guard", inferExpr(sc, tbl, sigs, diag, we), we.span)
        case None -> {
        }
      }
      requireQuantifierBool(diag, "forall", "body", inferExpr(sc, tbl, sigs, diag, body), body.span)
      scopePop(sc)
      TyPrim(pt = PtBool)
    }
    case EExists(binders, whereOpt, body, _) -> {
      val ectx = newGenericContext()
      scopePush(sc)
      var ei = 0
      while ei < binders.count {
        val bt = resolveType(tbl, ectx, diag, binders[ei].ty)
        if binders[ei].name != "_" {
          scopeAdd(sc, LocalBinding(name = binders[ei].name, ty = bt, isMutable = false))
        }
        ei = ei + 1
      }
      match whereOpt {
        case Some(we) -> requireQuantifierBool(diag, "exists", "where guard", inferExpr(sc, tbl, sigs, diag, we), we.span)
        case None -> {
        }
      }
      requireQuantifierBool(diag, "exists", "body", inferExpr(sc, tbl, sigs, diag, body), body.span)
      scopePop(sc)
      TyPrim(pt = PtBool)
    }
    // EAssign: assignment in expression position.  Check target/value types
    // and the immutability of the target exactly as the statement path does.
    case EAssign(target, op, value) -> {
      val targetType = inferExpr(sc, tbl, sigs, diag, target)
      exemptArrayCopy(tbl, target)
      checkArrayElementWrite(sc, tbl, sigs, diag, target)
      val valueType = inferExprExpected(sc, tbl, sigs, diag, value, targetType)
      noteArrayStore(tbl, value, valueType)
      recordHoistedAssignValue(sc, tbl, target, value, valueType, targetType)
      noteOpenBindingAssign(sc, tbl, sigs, target, valueType)
      val stringPlusAssign = isStringPlusVarAssign(target, op, targetType)
      if not stringPlusAssign and not argFlowSatisfies(tbl, targetType, valueType, value) {
        diag.add(
          errorDiagnostic(
            "T0063",
            "assigned value " + ofTypeOrEmptyLiteral(valueType, value) + " does not match target of type " +
              renderType(targetType) +
              typeMismatchHint(tbl, targetType, valueType),
            e.span
          )
        )
      }
      if not stringPlusAssign {
        recordUnsignedWidening(tbl, targetType, valueType, value)
      }
      noteRangeAssign(sc, tbl, target, op, targetType, value, e.span)
      recordUnsignedCompoundValue(tbl, op, targetType, valueType, value, stringPlusAssign)
      match target.kind {
        case EPath(p) -> if p.segments.count == 1 {
          match scopeTryFind(sc, p.segments[0]) {
            case Some(b) -> if not b.isMutable { diag.add(errorDiagnostic("T0087", t0087BindingMsg(b), target.span)) }
            case None -> {
            }
          }
        }
        case _ -> {
        }
      }
      TyPrim(pt = PtUnit)
    }
    case ERange(_) -> TyError
    case EInterpolated(segs) -> {
      for seg in segs {
        match seg {
          case ISExpr(se) -> {
            val segTy = inferExpr(sc, tbl, sigs, diag, se)
            recordUnsignedOperand(tbl, segTy, se)
            recordShowOperand(tbl, segTy, se)
          }
          case ISText(_, _) -> ()
        }
      }
      TyPrim(pt = PtString)
    }
    case EError -> TyError
  }
}

// True when `params` and `argTypes` have the same count and every argument is
// acceptable for its parameter (`argSatisfiesParam`): `typeEquiv` — which treats
// `TyError`/`TyVar` as wildcards, the leniency that lets an empty-literal arg
// still select the structurally-correct overload (#1488 category C) — or
// interface subtyping, so overload selection agrees with the argument check
// (#2304).
// A2 (docs/59 §5.1): the shared lambda-literal inference.  `expectedParams`
// carries the parameter types the surrounding context expects for this lambda
// (from the callee's resolved signature at a call-argument position, or a
// binding's declared function type).  An empty or arity-mismatched list means
// "no expectation": unannotated params degrade to `TyError`, the historical
// leniency, so a mismatched expectation never rejects here — the ordinary
// arg-vs-param / binding checks report any genuine mismatch.  Explicit
// annotations always win over the expectation.  Leftover generic `TyVar`s in
// an expected param (a partially-inferred generic callee) are erased to
// `TyError` so partially-known expectations still type what they can.
// #6604: `expectedReturn` is the lambda's expected return type when the
// surrounding context supplies one (a call argument's resolved `TFunction`
// parameter type, or a binding's declared function type) — `None` when no
// expectation is available (bare inference).  Mirrors `checkFunctionBody`'s
// `bodyValuePos = not isUnitType(sig.returnTy)`: a known `Unit` expectation
// checks the body in statement position (so a discarded mixed-type trailing
// `if`/`match` is absorbed, not flagged), a known non-`Unit` expectation
// checks it in value position, and an unknown expectation defaults to
// statement position — the lenient direction, matching the historical
// behaviour for lambdas with no contextual return type — rather than
// defaulting to value position, which would be the unsound direction.
// Inside a lambda, each `out`/`inout` parameter of an enclosing function is
// the value the lambda captures, not the caller's place: the lambda can be
// called after the function has returned, when the place may no longer
// exist (D183).  Bind each such parameter visible here again, immutable, in
// the lambda's own frame (`scopePush` already ran), so an assignment to it
// is T0087 and passing it to an `out`/`inout` parameter T0085.
func shadowCapturedByRefParams(sc: in Scope): Unit {
  val start = sc.frameStarts[sc.frameStarts.count - 1]
  val seen: Map[String, Bool] = newMap()
  var i = start - 1
  while i >= 0 {
    val b = sc.bindings[i]
    if not seen.containsKey(b.name) {
      seen.add(b.name, true)
      if b.byRefParam or b.capturedByRefParam {
        scopeAdd(sc, LocalBinding(name = b.name, ty = b.ty, isMutable = false, capturedByRefParam = true))
      }
    }
    i = i - 1
  }
}

func inferLambda(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  lambdaParams: in List[LambdaParam],
  body: in Block,
  expectedParams: in List[Type],
  expectedReturn: in Option[Type],
): Type {
  val useExpected = expectedParams.count == lambdaParams.count
  // A parameter annotation may name the enclosing declaration's type
  // parameters, as a local's annotation may.
  val lctx = newGenericContext()
  gctxPush(lctx, sc.genericNames)
  val paramTypes: List[Type] = newList()
  scopePush(sc)
  shadowCapturedByRefParams(sc)
  var li = 0
  while li < lambdaParams.count {
    val lp = lambdaParams[li]
    val pTy = match lp.ty {
      case None -> if useExpected { eraseTyVars(expectedParams[li]) } else { TyError }
      case Some(te) -> resolveType(tbl, lctx, diag, te)
    }
    paramTypes.add(pTy)
    scopeAdd(sc, LocalBinding(name = lp.name, ty = pTy, isMutable = false))
    li = li + 1
  }
  val bodyValuePos = match expectedReturn { case Some(rt) -> not isUnitType(rt); case None -> false }
  val noLambdaRte: Option[TypeExpr] = None
  // #7865: a closed, non-`Unit` expected return type is the lambda's declared
  // return type, exactly as a function's is: each `return` is checked against
  // it, the trailing value (through `if`/`match`/block tails) is checked
  // against it, and a value of a narrower type along a lossless widening
  // chain widens to it (docs/01 §4.1), so `{ -> 5 }` is a `() -> Long` where
  // one is expected.  With no such expectation (bare inference, or a generic
  // callee's still-open `T`) the return type is inferred from the body and
  // `TyError` keeps a literal inferring as `slice[T]` (#7696).  A bracket
  // literal that is the body's value is built as the `List` the return type
  // names through a binding annotated with it (`recordLambdaTailShape`), since
  // a backend does not see a lambda's return type where it builds the
  // literal (#7878).
  val declaredRet: Option[Type] = match expectedReturn {
    case Some(rt) -> if bodyValuePos and typeIsClosed(unrefine(rt)) {
      Some(value = rt)
    } else {
      None
    }
    case None -> None
  }
  // The body's own scope: the enclosing frames, with the lambda's return type
  // (`TyError` when it has none) in place of the enclosing function's, so a
  // `return` nested in a branch or block of the body is checked against the
  // lambda, not the function around it.
  val lsc = Scope(
    bindings = sc.bindings,
    frameStarts = sc.frameStarts,
    returnTy = match declaredRet { case Some(rt) -> rt; case None -> TyError },
    genericNames = sc.genericNames,
    returnTyExpr = noLambdaRte,
    selfFields = sc.selfFields,
    selfChecked = sc.selfChecked,
    selfType = sc.selfType,
    contractDepth = sc.contractDepth,
    bounds = sc.bounds
  )
  match declaredRet {
    case Some(rt) -> {
      val bodyTy = checkBlock(lsc, tbl, sigs, sc.genericNames, rt, noLambdaRte, diag, body, true, rt)
      scopePop(sc)
      recordLambdaTailShape(tbl, sc.genericNames, body, bodyTy, rt)
      TyFunction(params = paramTypes, ret = lambdaReturnAgainst(tbl, rt, bodyTy, body), isAsync = false)
    }
    case None -> {
      val returned: List[Type] = newList()
      tbl.lambdaReturnFrames.add(returned)
      val bodyTy = checkBlock(lsc, tbl, sigs, sc.genericNames, TyError, noLambdaRte, diag, body, bodyValuePos, TyError)
      tbl.lambdaReturnFrames.removeAt(tbl.lambdaReturnFrames.count - 1)
      scopePop(sc)
      // A body whose every path `return`s has the type `Never`; the lambda's
      // result is then the type of the first value it returns.
      val bodyDiverges = match bodyTy {
        case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }
        case _ -> false
      }
      val retTy = if bodyDiverges and returned.count > 0 { returned[0] } else { bodyTy }
      TyFunction(params = paramTypes, ret = retTy, isAsync = false)
    }
  }
}

// A lambda body's value that is a bracket literal (or an `if` / `match` whose
// branches hold one) checked against the lambda's declared return type `rt` is
// recorded at the shape `rt` gives it, so `Lyric.Mono` binds it through a local
// annotated with that type (`hoistOperandTypedMono`) and every backend builds a
// `List[T]` of the right element width (#7878).
func recordLambdaTailShape(
  tbl: in SymbolTable,
  typeParams: in List[String],
  body: in Block,
  bodyTy: in Type,
  rt: in Type,
): Unit {
  match blockValueExpr(body) {
    case Some(tailE) -> match shapedOperandType(tbl, tailE, bodyTy, rt) {
      case Some(_) -> recordHoistOperandTypeOver(tbl, typeParams, tailE, bodyTy, rt)
      case None -> ()
    }
    case None -> ()
  }
}

// Record the types the unannotated parameters of the lambda at `sp` took from
// the function type expected of it (see `SymbolTable.lambdaParamTypeSites`,
// #7865).  A parameter whose type is not closed (an unbound type parameter,
// an error) or has no source spelling here is left unannotated; two checks of
// one lambda that type a parameter differently are `conflicting`.
func recordLambdaParamTypes(tbl: in SymbolTable, ps: in List[LambdaParam], lt: in Type, sp: in Span): Unit {
  if isNoSourceSpan(sp) or sp.endPos.offset <= sp.startPos.offset {
    return
  }
  match lt {
    case TyFunction(pts, _, _) -> recordLambdaParamTypesOf(tbl, ps, pts, sp)
    case _ -> ()
  }
}

// Record whether the lambda at `sp`, checked as `lt`, returns `Unit`
// (`SymbolTable.lambdaUnitSites`).  A lambda checked more than once keeps
// `true` only while every check agrees.
pub func recordLambdaUnitSite(tbl: in SymbolTable, lt: in Type, sp: in Span): Unit {
  val isUnit = match unrefine(lt) {
    case TyFunction(_, ret, _) -> match unrefine(ret) {
      case TyPrim(pt) -> match pt { case PtUnit -> true; case _ -> false }
      case _ -> false
    }
    case _ -> false
  }
  val key = recordCopySiteKey(sp)
  match mapGet(tbl.lambdaUnitSites, key) {
    case Some(prev) -> if prev and not isUnit { tbl.lambdaUnitSites.remove(key); tbl.lambdaUnitSites.add(key, false) }
    case None -> tbl.lambdaUnitSites.add(key, isUnit)
  }
}

func recordLambdaParamTypesOf(tbl: in SymbolTable, ps: in List[LambdaParam], pts: in List[Type], sp: in Span): Unit {
  if pts.count != ps.count {
    return
  }
  val tes: List[TypeExpr] = newList()
  val known: List[Bool] = newList()
  var rendered = ""
  var anyKnown = false
  var i = 0
  while i < ps.count {
    var te = TypeExpr(kind = TUnit, span = sp)
    var isKnown = false
    match ps[i].ty {
      case Some(_) -> ()
      case None -> if typeIsClosed(pts[i]) {
        match typeExprForRef(tbl, pts[i], sp) {
          case Some(pte) -> {
            te = pte
            isKnown = true
          }
          case None -> ()
        }
      }
    }
    tes.add(te)
    known.add(isKnown)
    rendered = rendered + (if isKnown { renderType(pts[i]) } else { "_" }) + ";"
    if isKnown {
      anyKnown = true
    }
    i = i + 1
  }
  if not anyKnown {
    return
  }
  val key = recordCopySiteKey(sp)
  match mapGet(tbl.lambdaParamTypeSites, key) {
    case Some(prev) -> if prev.rendered != rendered and not prev.conflicting {
      tbl.lambdaParamTypeSites.remove(key)
      tbl.lambdaParamTypeSites.add(
        key,
        LambdaParamTypesSite(paramTypes = prev.paramTypes, known = prev.known, rendered = prev.rendered, conflicting = true)
      )
    }
    case None -> tbl.lambdaParamTypeSites.add(
      key,
      LambdaParamTypesSite(paramTypes = tes, known = known, rendered = rendered, conflicting = false)
    )
  }
}

// True when `t` is the stdlib `List[T]` (by type id, like the bracket-literal
// arm of `inferExprExpected`).
func isStdListType(tbl: in SymbolTable, t: in Type): Bool {
  match unrefine(t) {
    case TyUser(tid, _, _) -> isStdCollectionsHostType(tbl, tid, "List")
    case _ -> false
  }
}

// The return type of a lambda whose body, of type `bodyTy`, is checked
// against the declared return type `rt` (#7865): `rt` when the body diverges
// (every path `return`s or panics) or its value widens to `rt` (the widening
// is made explicit at the trailing value, as for a function body), otherwise
// the body's own type, which the consumer then reports as a mismatch.
func lambdaReturnAgainst(tbl: in SymbolTable, rt: in Type, bodyTy: in Type, body: in Block): Type {
  val diverges = match bodyTy { case TyPrim(pt) -> match pt { case PtNever -> true; case _ -> false }; case _ -> false }
  if diverges {
    return rt
  }
  if numericWidensTo(rt, bodyTy) {
    match blockValueExpr(body) {
      case Some(tailE) -> recordWideningSite(tbl, rt, bodyTy, tailE, false)
      case None -> ()
    }
    return rt
  }
  bodyTy
}

// True for a lambda literal (possibly parenthesised) with at least one
// unannotated parameter, whose type before the expectation-aware pass
// (`TyError` parameters) is no evidence for a generic callee's type
// arguments (A2).
func lambdaHasUnannotatedParam(e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> lambdaHasUnannotatedParam(inner)
    case ELambda(ps, _) -> {
      var i = 0
      while i < ps.count {
        match ps[i].ty {
          case None -> return true
          case Some(_) -> {
          }
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

// True for a lambda literal (possibly parenthesised).  Every lambda argument
// is deferred to the expectation-aware pass: an unannotated parameter takes
// its type from the parameter's function type (A2), and the lambda's return
// type is that function type's return type, so its body's value widens to it
// (#7865).
func argIsLambdaLiteral(e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsLambdaLiteral(inner)
    case ELambda(_, _) -> true
    case _ -> false
  }
}

// #7752: true for a call-argument expression (possibly parenthesised) whose
// type depends on the expected type it is checked against — an `if` with an
// `else`, a `match`, or a brace / `unsafe` block — so the `ECall` arm defers
// it to the second, expectation-aware pass alongside lambda literals.
func argIsBranchingExpr(e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsBranchingExpr(inner)
    case EIf(_, _, elseBranch, _) -> match elseBranch { case Some(_) -> true; case None -> false }
    case EMatch(_, _) -> true
    case EBlock(_) -> true
    case EUnsafe(_) -> true
    case _ -> false
  }
}

// A call argument (possibly parenthesised) that is a bracket literal `[...]`,
// which the `ECall` arm defers to the second pass so it can be typed as an
// `array[N, T]` when the selected parameter or field is one (D167).
// Each array-typed argument of a record construction or `.copy(...)` is
// stored into a field, so it is copied unless it is a fresh value (D167).
func noteArrayStores(tbl: in SymbolTable, args: in List[CallArg], argTypes: in List[Type]): Unit {
  var i = 0
  while i < args.count and i < argTypes.count {
    noteArrayStore(tbl, callArgExpr(args[i]), argTypes[i])
    i = i + 1
  }
}

// Whether the tuple component `el`, of type `t`, is a union-case construction
// or a bare case name of a generic union (`Some(1)`, `None`).
func tupleElemBuildsGeneric(sc: in Scope, tbl: in SymbolTable, el: in Expr, t: in Type): Bool {
  if not typeMentionsGenericInst(t) {
    return false
  }
  match stripExprParens(el).kind {
    case ECall(_, _) -> argIsCaseCtorCall(tbl, el)
    case EPath(p) -> p.segments.count == 1 and
      (match scopeTryFind(sc, p.segments[0]) { case Some(_) -> false; case None -> true })
    case _ -> false
  }
}

func isTupleType(t: in Type): Bool {
  match unrefine(t) {
    case TyTuple(_) -> true
    case _ -> false
  }
}

// A tuple literal one of whose components is a bracket literal or a
// construction (`None`, `Some(1)`), possibly inside a nested tuple: its shape
// and the types its components are built at follow the tuple type expected of
// it.
func argIsListHoldingTuple(e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsListHoldingTuple(inner)
    case ETuple(elems) -> {
      for el in elems {
        if argIsListLiteral(el) or argIsListHoldingTuple(el) {
          return true
        }
        match stripExprParens(el).kind {
          case ECall(_, _) -> return true
          case EPath(_) -> return true
          case _ -> ()
        }
      }
      false
    }
    case _ -> false
  }
}

// The type expected of the result of the call `e`, `TyError` for none.
func callResultExpected(tbl: in SymbolTable, e: in Expr): Type {
  match mapGet(tbl.methodCallResultExpected, recordCopySiteKey(e.span)) {
    case Some(rx) -> rx
    case None -> TyError
  }
}

// `bound`, the type arguments of `generics` the arguments fixed (`TyError`
// for one they left open), with each open one taken from `retTy` unified
// with the type `resultExpected` expected of the call's result.
func bindOpenFromResult(
  generics: in List[String], bound: in List[Type], retTy: in Type, resultExpected: in Type
): List[Type] {
  if typeIsHole(resultExpected) or not typeIsClosed(resultExpected) {
    return bound
  }
  val retTys: List[Type] = newList()
  retTys.add(retTy)
  val expTys: List[Type] = newList()
  expTys.add(resultExpected)
  val fromRet = inferGenericArgsDeep(generics, retTys, expTys)
  val merged: List[Type] = newList()
  var i = 0
  while i < bound.count {
    merged.add(if typeIsHole(bound[i]) and i < fromRet.count { fromRet[i] } else { bound[i] })
    i = i + 1
  }
  merged
}

func callHasListLiteralArg(args: in List[CallArg]): Bool {
  for a in args {
    if argIsListLiteral(callArgExpr(a)) {
      return true
    }
  }
  false
}

func argIsListLiteral(e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsListLiteral(inner)
    case EList(_) -> true
    case _ -> false
  }
}

// The field type each argument of a record construction `R(...)` initialises,
// positionally aligned with `args`, for the arguments that are bracket
// literals given to a field of array type (`TyError` elsewhere): such an
// argument is typed against the field.  A generic record's field is
// instantiated at the type arguments `argTypes` bind (a literal's own
// `slice[T]` type binds its element, #8042), or else `expected` gives.
// `ctorArrayFieldTypes` for a union case constructor: a bracket literal
// given to a case field of array type is typed against the field, as for a
// record field (D167).  A field whose type names one of the union's type
// parameters, or is sized by one of its value parameters, is left to the
// call's expected argument types.
func unionCaseArrayFieldTypes(tbl: in SymbolTable, fn: in Expr, args: in List[CallArg], tys: in List[Type]): List[Type] {
  val caseSym = match unionCaseSymbolOf(tbl, fn) { case Some(cs) -> cs; case None -> return tys }
  match caseSym.kind {
    case DKUnionCase(parentId, uc) -> match parentUnionDeclOf(tbl, parentId) {
      case Some(decl) -> {
        val scratch: List[Diagnostic] = newList()
        val ftypes = unionCaseFieldTypes(tbl, scratch, uc, unionDeclGenericNames(decl), caseSym.originPackage)
        val names = unionCaseSlotNames(uc)
        var pos = 0
        var i = 0
        while i < args.count {
          val fi = match args[i] {
            case CANamed(nm, _, _) -> indexOfName(names, nm)
            case CAPositional(_) -> {
              pos = pos + 1
              pos - 1
            }
          }
          if fi >= 0 and fi < ftypes.count and not typeMentionsGenericParam(ftypes[fi]) {
            tys[i] = ftypes[fi]
          }
          i = i + 1
        }
        tys
      }
      case None -> tys
    }
    case _ -> tys
  }
}

func indexOfName(names: in List[String], nm: in String): Int {
  var i = 0
  while i < names.count {
    if names[i] == nm {
      return i
    }
    i = i + 1
  }
  -1
}

func ctorArrayFieldTypes(
  tbl: in SymbolTable,
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
  expected: in Type,
): List[Type] {
  val tys: List[Type] = newList()
  var any = false
  for a in args {
    if argIsListLiteral(callArgExpr(a)) {
      any = true
    }
  }
  var k = 0
  while k < args.count {
    tys.add(TyError)
    k = k + 1
  }
  if not any {
    return tys
  }
  val ctorSym = match constructorSymbolOf(tbl, fn) {
    case Some(sy) -> sy
    case None -> return unionCaseArrayFieldTypes(tbl, fn, args, tys)
  }
  if ctorIsGeneric(ctorSym) {
    return genericCtorArrayFieldTypes(tbl, ctorSym, args, argTypes, expected, tys)
  }
  val fields: List[CtorField] = newList()
  if not collectCtorFields(tbl, ctorSym, fields) {
    return tys
  }
  var pos = 0
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(nm, _, _) -> {
        for f in fields {
          if f.name == nm {
            tys[i] = f.ty
          }
        }
      }
      case CAPositional(_) -> {
        if pos < fields.count {
          tys[i] = fields[pos].ty
        }
        pos = pos + 1
      }
    }
    i = i + 1
  }
  tys
}

// `adoptListLiteralArgs` for the construction `fn(args)` of a record or a
// union case: each bracket literal argument is adopted against its field,
// a generic field instantiated from the other arguments.
func adoptCtorLiteralArgs(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
): Unit {
  var anyLiteral = false
  for a in args {
    if argIsListLiteral(callArgExpr(a)) {
      anyLiteral = true
    }
  }
  if not anyLiteral {
    return
  }
  match constructorSymbolOf(tbl, fn) {
    case Some(ctorSym) -> {
      val generics: List[String] = if ctorIsGeneric(ctorSym) { ctorGenericNames(ctorSym) } else { newList() }
      val names: List[String] = newList()
      val tys: List[Type] = newList()
      if generics.count > 0 {
        for nm in ctorFieldNames(ctorSym) {
          names.add(nm)
        }
        for t in ctorFieldTypes(tbl, ctorSym, generics) {
          tys.add(t)
        }
      } else {
        val fields: List[CtorField] = newList()
        if not collectCtorFields(tbl, ctorSym, fields) {
          return
        }
        for f in fields {
          names.add(f.name)
          tys.add(f.ty)
        }
      }
      adoptLiteralArgsOver(sc, tbl, sigs, diag, generics, names, tys, args, argTypes, "T0104", "field", TyError, TyError)
    }
    case None -> match unionCaseSymbolOf(tbl, fn) {
      case Some(caseSym) -> match caseSym.kind {
        case DKUnionCase(parentId, uc) -> match parentUnionDeclOf(tbl, parentId) {
          case Some(decl) -> {
            val scratch: List[Diagnostic] = newList()
            val generics = unionDeclGenericNames(decl)
            val tys = unionCaseFieldTypes(tbl, scratch, uc, generics, caseSym.originPackage)
            adoptLiteralArgsOver(
              sc,
              tbl,
              sigs,
              diag,
              generics,
              unionCaseSlotNames(uc),
              tys,
              args,
              argTypes,
              "T0104",
              "field",
              TyError,
              TyError
            )
          }
          case None -> ()
        }
        case _ -> ()
      }
      case None -> ()
    }
  }
}

func genericCtorArrayFieldTypes(
  tbl: in SymbolTable,
  ctorSym: in Symbol,
  args: in List[CallArg],
  argTypes: in List[Type],
  expected: in Type,
  tys: in List[Type],
): List[Type] {
  val gnames = ctorGenericNames(ctorSym)
  val fieldNames = ctorFieldNames(ctorSym)
  val fieldTypes = ctorFieldTypes(tbl, ctorSym, gnames)
  val targs = inferGenericArgs(gnames, fieldTypes, argTypesInFieldOrder(args, argTypes, fieldNames))
  match unrefine(expected) {
    case TyUser(eid, _, eargs) -> match symbolTypeIdOpt(ctorSym) {
      case Some(tid) -> if symbolIdEq(eid, tid) and eargs.count == gnames.count {
        var ei = 0
        while ei < gnames.count {
          if typeIsHole(targs[ei]) {
            targs[ei] = eargs[ei]
          }
          ei = ei + 1
        }
      }
      case None -> ()
    }
    case _ -> ()
  }
  var pos = 0
  var i = 0
  while i < args.count {
    val fieldName = match args[i] {
      case CANamed(nm, _, _) -> nm
      case CAPositional(_) -> {
        val nm = if pos < fieldNames.count { fieldNames[pos] } else { "" }
        pos = pos + 1
        nm
      }
    }
    if argIsListLiteral(callArgExpr(args[i])) {
      var j = 0
      while j < fieldNames.count and j < fieldTypes.count {
        if fieldNames[j] == fieldName {
          val inst = substituteTyVars(fieldTypes[j], gnames, targs)
          match unrefine(inst) {
            case TyArray(Some(_), el, _) -> if not typeMentionsTyVar(inst) and not typeIsHole(el) {
              tys[i] = inst
              // The field's own type names a type parameter, so the
              // literal is built through a binding of the instantiated type.
              noteArrayLiteralType(tbl, callArgExpr(args[i]), inst)
            }
            case _ -> ()
          }
        }
        j = j + 1
      }
    }
    i = i + 1
  }
  tys
}

// #7752: true for a call-argument expression (possibly parenthesised) that is
// a union-case-constructor call, whose type the `ECall` arm lets adopt the
// selected parameter's instantiation (`adoptUnionCaseExpected`).
func argIsCaseCtorCall(tbl: in SymbolTable, e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsCaseCtorCall(tbl, inner)
    case ECall(fn, _) -> match unionCaseSymbolOf(tbl, fn) { case Some(_) -> true; case None -> false }
    case _ -> false
  }
}

// True for a call-argument expression (possibly parenthesised) that builds a
// value whose scalar parts widen to the parameter's type (#7813): a tuple
// literal or a generic record construction.  Union-case constructions are
// `argIsCaseCtorCall`'s.
func argIsWideningBuiltValue(tbl: in SymbolTable, e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsWideningBuiltValue(tbl, inner)
    case ETuple(_) -> true
    case ECall(fn, _) -> match unionCaseSymbolOf(tbl, fn) {
      case Some(_) -> false
      case None -> match constructorSymbolOf(tbl, fn) {
        case Some(sym) -> ctorIsGeneric(sym)
        case None -> false
      }
    }
    case _ -> false
  }
}

// #6814: true for a call-argument expression that is itself a bare
// union-case-constructor call whose callee name is ambiguous across 2+
// imported packages (every `symTableTryFindAll` candidate is a
// `DKUnionCase`) — the second expression shape (alongside
// `lambdaHasUnannotatedParam`'s lambda literals) whose typing benefits from
// a contextual expected type (A2).  A call whose bare name has fewer than 2
// candidates, or whose candidates are not ALL union cases (so it might be a
// record constructor / function call instead), is left on the eager path —
// `inferExprExpected`'s `ECall` arm below falls back to `inferExpr` for any
// shape this predicate doesn't defer, so nothing gets stricter.
func argIsAmbiguousUnionCaseCtor(tbl: in SymbolTable, e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsAmbiguousUnionCaseCtor(tbl, inner)
    // A bare nullary case name (#8649), as `inferExprExpectedCore`'s `EPath`
    // arm resolves it against the parameter type.
    case EPath(p) -> p.segments.count == 1 and nameIsSharedUnionCase(tbl, p.segments[0])
    case ECall(fn, _) -> match fn.kind {
      case EPath(p) -> p.segments.count == 1 and nameIsSharedUnionCase(tbl, p.segments[0])
      case _ -> false
    }
    case _ -> false
  }
}

// True when `name` has two or more candidates and every one is a union case.
func nameIsSharedUnionCase(tbl: in SymbolTable, name: in String): Bool {
  val candidates = symTableTryFindAll(tbl, name)
  if candidates.count < 2 {
    return false
  }
  for cand in candidates {
    match cand.kind {
      case DKUnionCase(_, _) -> ()
      case _ -> return false
    }
  }
  true
}

// The argument types of a generic record construction checked where an
// instantiation of the record, `expected`, is expected: each argument is
// checked against its field there, so a scalar widens to it (#7813) and a
// range type there is checked (#8031), and a bracket literal given to an
// array field is typed against the field at the instantiation the arguments
// and `expected` bind (#8042).
func inferGenericRecordCtorArgsExpected(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn: in Expr,
  ctorSym: in Symbol,
  cargs: in List[CallArg],
  expected: in Type,
): List[Type] {
  val gnames = ctorGenericNames(ctorSym)
  val eargs = match unrefine(expected) { case TyUser(_, _, ea) -> ea; case _ -> newList() }
  val fieldNames = ctorFieldNames(ctorSym)
  val exps = ctorArgsExpected(cargs, fieldNames, ctorFieldTypes(tbl, ctorSym, gnames), gnames, eargs)
  val cargTypes = inferCtorArgsExpected(sc, tbl, sigs, diag, cargs, exps)
  // The construction's own type arguments come from the arguments, so a
  // field the expected instantiation makes a range type is checked against
  // it here (#8031).
  val order = argIndicesInParamOrder(cargs, fieldNames)
  var k = 0
  while k < order.count and k < fieldNames.count {
    val oi = order[k]
    if oi >= 0 and oi < exps.count {
      noteRangeSlot(tbl, exps[oi], callArgExpr(cargs[oi]), ctorSym.name + " field " + fieldNames[k])
    }
    k = k + 1
  }
  val arrTys = ctorArrayFieldTypes(tbl, fn, cargs, cargTypes, expected)
  var ai = 0
  while ai < cargs.count and ai < arrTys.count {
    match arrTys[ai] {
      case TyError -> ()
      // A literal already checked against this field type needs no second
      // pass; one whose field the expectation left open is checked here.
      case at -> if typeIsHole(exps[ai]) or not typeEquiv(at, exps[ai]) {
        cargTypes[ai] = inferExprExpected(sc, tbl, sigs, diag, callArgExpr(cargs[ai]), at)
      }
    }
    ai = ai + 1
  }
  cargTypes
}

// A union-case construction (`Some(u)`, `Ok(value = i)`) checked where
// `expected` is expected: each argument is checked against its field at the
// expected instantiation of the case's union, so a scalar widens to it
// (#7813), checked against a range type there (#8031), and the construction
// is typed at that instantiation when it fits (#7752).
func inferCaseCtorExpected(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  fn: in Expr,
  cargs: in List[CallArg],
  caseSym: in Symbol,
  span: in Span,
  expected: in Type,
): Type {
  val exps = caseCtorArgsExpected(tbl, caseSym, cargs, expected)
  val cargTypes = inferCtorArgsExpected(sc, tbl, sigs, diag, cargs, exps)
  // Before the construction records its own payload sites, so a payload is
  // checked against a range at the expected instantiation (#8031).
  noteCaseRangeAgainstExpected(tbl, caseSym, cargs, expected)
  val caseTy = adoptUnionCaseExpected(
    tbl,
    true,
    inferUnionCaseConstruction(tbl, diag, caseSym, cargs, cargTypes, span, true),
    expected
  )
  recordCtorArgOperandTypes(sc, tbl, fn, cargs, cargTypes, caseTy)
  caseTy
}

// A call through a qualified callee (`Result.Ok(...)`, `Pkg.Shape.Circle(...)`)
// checked where `expected` is expected: a union-case construction adopts the
// expected instantiation (#7752), its payloads are checked against a range
// type there (#8031), and one whose arguments widen to their fields there is
// checked again against them (#7813); the first pass already reported the
// arguments' diagnostics.
func inferQualifiedCaseCtorExpected(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
  fn: in Expr,
  cargs: in List[CallArg],
  expected: in Type,
): Type {
  match unionCaseSymbolOf(tbl, fn) {
    case Some(caseSym) -> {
      val actual = adoptUnionCaseExpected(tbl, true, inferExpr(sc, tbl, sigs, diag, e), expected)
      noteCaseRangeAgainstExpected(tbl, caseSym, cargs, expected)
      if widensStructurally(expected, actual) {
        val scratch: List[Diagnostic] = newList()
        val widened = inferCaseCtorExpected(sc, tbl, sigs, scratch, fn, cargs, caseSym, e.span, expected)
        if diagnosticsHaveError(scratch) {
          actual
        } else {
          widened
        }
      } else {
        actual
      }
    }
    case None -> adoptUnionCaseExpected(tbl, false, inferExpr(sc, tbl, sigs, diag, e), expected)
  }
}

// `ctorArgsExpected` for a union case, when `expected` is a closed
// instantiation of the case's own union.
func caseCtorArgsExpected(
  tbl: in SymbolTable, caseSym: in Symbol, cargs: in List[CallArg], expected: in Type
): List[Type] {
  val none: List[Type] = newList()
  var i = 0
  while i < cargs.count {
    none.add(TyError)
    i = i + 1
  }
  if not typeIsClosed(expected) {
    return none
  }
  match caseSym.kind {
    case DKUnionCase(parentId, uc) -> match unrefine(expected) {
      case TyUser(eid, _, eargs) -> if symbolIdEq(eid, parentId) {
        match parentUnionDeclOf(tbl, parentId) {
          case Some(decl) -> {
            val gnames = unionDeclGenericNames(decl)
            // Field-type resolution errors are reported by the construction
            // itself (`inferUnionCaseConstruction`).
            val scratch: List[Diagnostic] = newList()
            val ftypes = unionCaseFieldTypes(tbl, scratch, uc, gnames, caseSym.originPackage)
            ctorArgsExpected(cargs, unionCaseSlotNames(uc), ftypes, gnames, eargs)
          }
          case None -> none
        }
      } else {
        none
      }
      case _ -> none
    }
    case _ -> none
  }
}

// True when `fn` names a generic record constructor (not a union case) and
// `expected` is an instantiation of that same record type.
func expectsGenericRecordCtor(tbl: in SymbolTable, fn: in Expr, expected: in Type): Bool {
  match unionCaseSymbolOf(tbl, fn) {
    case Some(_) -> return false
    case None -> ()
  }
  match constructorSymbolOf(tbl, fn) {
    case Some(ctorSym) -> if not ctorIsGeneric(ctorSym) {
      false
    } else {
      match unrefine(expected) {
        case TyUser(eid, _, _) -> match symbolTypeIdOpt(ctorSym) {
          case Some(tid) -> symbolIdEq(eid, tid)
          case None -> false
        }
        case _ -> false
      }
    }
    case None -> false
  }
}

// A method call checked where `expected` is expected of its result: a
// receiver the hoist binds can take its type from it (#7844).
func inferMethodCallExpected(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
  expected: in Type,
): Type {
  if typeIsHole(expected) or isNoSourceSpan(e.span) {
    return inferExpr(sc, tbl, sigs, diag, e)
  }
  val key = recordCopySiteKey(e.span)
  val prior = mapGet(tbl.methodCallResultExpected, key)
  if tbl.methodCallResultExpected.containsKey(key) {
    tbl.methodCallResultExpected.remove(key)
  }
  tbl.methodCallResultExpected.add(key, expected)
  val t = inferExpr(sc, tbl, sigs, diag, e)
  tbl.methodCallResultExpected.remove(key)
  match prior {
    case Some(p) -> tbl.methodCallResultExpected.add(key, p)
    case None -> ()
  }
  t
}

// T0221 (#8672): a protected type's state is reachable only through its
// entries and functions (docs/01 §7.5), so a field read or write by name on a
// value of a protected type is rejected outside that type's own members (an
// `entry`, a `func`, an invariant, or an `impl` method, whose scope's
// `selfType` is the type itself), or in a contract clause.  Both a read and the
// target of an assignment reach here, since the target is inferred like any
// member access.
func checkProtectedFieldAccess(
  sc: in Scope,
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  recvTy: in Type,
  name: in String,
  span: in Span,
): Unit {
  val tid = match typeIdOfType(recvTy) { case Some(t) -> t; case None -> return }
  match findProtectedDeclByTypeId(tbl, tid) {
    case Some(pd) -> {
      var isField = false
      for m in pd.members {
        match m {
          case PMField(pf) -> if protectedFieldAsFieldDecl(pf).name == name { isField = true }
          case _ -> ()
        }
      }
      if not isField {
        return
      }
      val inOwnMember = sc.selfChecked and
        match typeIdOfType(sc.selfType) { case Some(own) -> symbolIdEq(own, tid); case None -> false }
      // A contract clause is specification, not state access: `ensures:
      // result.tokens == capacity` states what a construction produced.
      if not inOwnMember and sc.contractDepth.count == 0 {
        diag.add(
          errorDiagnostic(
            "T0221",
            "field '" + name + "' of protected type '" + pd.name +
              "' cannot be read or written from outside the type's own members; call an `entry` or `func` of '" +
              pd.name +
              "' instead (docs/01 §7.5)",
            span
          )
        )
      }
    }
    case None -> ()
  }
}

// #8649: the union case a bare name stands for when two or more visible union
// cases share it and `expected` is a union declaring one of them; None when the
// name is a local, is not shared, or the expected type does not pick one.
func sharedBareCaseOfExpected(sc: in Scope, tbl: in SymbolTable, p: in ModulePath, expected: in Type): Option[Symbol] {
  if p.segments.count != 1 or scopeHasName(sc, p.segments[0]) {
    return None
  }
  val eid = match unrefine(expected) { case TyUser(id, _, _) -> id; case _ -> return None }
  val candidates = symTableTryFindAllVisible(tbl, p.segments[0])
  if candidates.count < 2 {
    return None
  }
  var ci = candidates.count - 1
  while ci >= 0 {
    match candidates[ci].kind {
      case DKUnionCase(parentId, _) -> if symbolIdEq(parentId, eid) { return Some(value = candidates[ci]) }
      case _ -> ()
    }
    ci = ci - 1
  }
  None
}

// A2: infer `e` under a contextual expected type.  The expectation is
// consumed only by the shapes that need it — a lambda literal (its
// unannotated params adopt the expected function type's parameter types), an
// ambiguous or generic constructor call, a union-case construction
// (`adoptUnionCaseExpected`, #7752), a bracket literal against `List[T]`
// (#7545), and an `if`/`match`/block whose branches are checked against it
// (#7752); every other expression shape — and any unusable expectation —
// defers to plain `inferExpr`.
pub func inferExprExpected(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
  expected: in Type,
): Type {
  val t = inferExprExpectedCore(sc, tbl, sigs, diag, e, expected)
  noteValueUnionCaseExpected(sc, tbl, e, t, expected)
  t
}

func inferExprExpectedCore(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e: in Expr,
  expected: in Type,
): Type {
  noteExpectedFlow(sc, tbl, e, expected)
  if isUnsuffixedFloatLit(e) and isFloatType(expected) {
    return adoptFloatLiteralType(tbl, e, inferExpr(sc, tbl, sigs, diag, e), expected)
  }
  if isUnsuffixedIntLit(e) and isSomeSuffix(unsignedLiteralSuffix(expected)) {
    return adoptUnsignedIntLiteral(tbl, e, inferExpr(sc, tbl, sigs, diag, e), expected)
  }
  match e.kind {
    case EParen(inner) -> inferExprExpected(sc, tbl, sigs, diag, inner, expected)
    case ELambda(ps, body) -> match unrefine(expected) {
      case TyFunction(eps, eret, _) -> {
        val lt = inferLambda(sc, tbl, sigs, diag, ps, body, eps, Some(value = eret))
        recordLambdaParamTypes(tbl, ps, lt, e.span)
        recordLambdaUnitSite(tbl, lt, e.span)
        lt
      }
      case _ -> inferExpr(sc, tbl, sigs, diag, e)
    }
    // #6814: a bare union-case-constructor call whose name is ambiguous
    // across imported packages (the shape `argIsAmbiguousUnionCaseCtor`
    // defers) resolves directly against the expected type's own union via
    // `unionCaseSymbolForScrutinee` — the same "scrutinee's own union wins"
    // tiering #6287 Phase B already uses for a match-pattern head — instead
    // of falling into `inferExpr`'s unconditional `checkBareNameAmbiguity`
    // gate.  If the expected type can't disambiguate it,
    // `unionCaseSymbolForScrutinee` itself falls through to the ordinary
    // bare-name ambiguity check (for a genuinely bare, single-segment
    // callee) and raises T0123 there — checked via `diag.count` so this
    // arm never re-raises it a second time by falling into `inferExpr`.
    case ECall(fn, cargs) -> match fn.kind {
      case EPath(p) -> if expectsGenericRecordCtor(tbl, fn, expected) {
        match constructorSymbolOf(tbl, fn) {
          case Some(ctorSym) -> {
            val cargTypes = inferGenericRecordCtorArgsExpected(sc, tbl, sigs, diag, fn, ctorSym, cargs, expected)
            val ctorTy = inferConstructionExpected(tbl, diag, ctorSym, cargs, cargTypes, e.span, expected)
            noteArrayStores(tbl, cargs, cargTypes)
            recordCtorArgOperandTypes(sc, tbl, fn, cargs, cargTypes, ctorTy)
            ctorTy
          }
          case None -> inferExpr(sc, tbl, sigs, diag, e)
        }
      } else if p.segments.count == 1 {
        val diagCountBefore = diag.count
        match unionCaseSymbolForScrutinee(tbl, diag, fn, expected) {
          case Some(caseSym) -> inferCaseCtorExpected(sc, tbl, sigs, diag, fn, cargs, caseSym, e.span, expected)
          case None -> if diag.count > diagCountBefore {
            TyError
          } else if callHasPropagateArg(tbl, cargs) {
            // A `?` argument that fixes no success type may take it from a
            // generic parameter the expected result binds (#8181).
            inferMethodCallExpected(sc, tbl, sigs, diag, e, expected)
          } else if callHasListLiteralArg(cargs) {
            // A bracket literal argument of a generic parameter takes the
            // `List` the call's expected result binds its type parameter to
            // (`val r: List[Long] = g([1, 2])`, #8293).
            inferMethodCallExpected(sc, tbl, sigs, diag, e, expected)
          } else {
            inferExpr(sc, tbl, sigs, diag, e)
          }
        }
      } else {
        // #7752: a qualified case constructor (`Result.Ok(...)`,
        // `Pkg.Shape.Circle(...)`) adopts the expected instantiation too.
        inferQualifiedCaseCtorExpected(sc, tbl, sigs, diag, e, fn, cargs, expected)
      }
      // A package-qualified module-level `val` of function type is called
      // through its type, not as a method (#8283).
      case EMember(_, _) -> match moduleValSymbolOfExpr(sc, tbl, fn) {
        case Some(_) -> inferExpr(sc, tbl, sigs, diag, e)
        case None -> match unionCaseSymbolOf(tbl, fn) {
          case Some(_) -> inferQualifiedCaseCtorExpected(
            sc,
            tbl,
            sigs,
            diag,
            e,
            fn,
            cargs,
            expected
          )
          case None -> inferMethodCallExpected(
            sc,
            tbl,
            sigs,
            diag,
            e,
            expected
          )
        }
      }
      case _ -> inferExpr(sc, tbl, sigs, diag, e)
    }
    // #7752: an `if`/`match`/brace block in a position with a known expected
    // type (a `return`, an annotated binding, an assignment, a call argument
    // — every caller of this function) checks each branch, and a block's
    // trailing value, against that type rather than joining branch types
    // bottom-up (`branchesAgainstExpected`), threading it as the same
    // `tailExpected` a function body's own tail chain already carries
    // (#7696).  With no expectation (`TyError`) this is exactly the plain
    // `inferExpr` dispatch.
    // #8649: a bare nullary case name that two unions of one package share
    // (`Idle` in `Left` and `Right`) means the case of the expected union, as
    // a bare constructor call with fields does; `symTableTryFindOne` alone
    // would pick the last declared.
    case EPath(p) -> match sharedBareCaseOfExpected(sc, tbl, p, expected) {
      case Some(caseSym) -> {
        symTableNoteBareUse(tbl, caseSym, e.span)
        adoptUnionCaseExpected(
          tbl,
          true,
          inferUnionCaseConstruction(tbl, diag, caseSym, newList(), newList(), e.span, false),
          expected
        )
      }
      case None -> inferExpr(sc, tbl, sigs, diag, e)
    }
    case EIf(cond, thenBranch, elseBranch, _) -> inferIfExpr(
      sc,
      tbl,
      sigs,
      diag,
      e,
      cond,
      thenBranch,
      elseBranch,
      true,
      expected
    )
    case EMatch(scrutinee, arms) -> inferMatchExpr(sc, tbl, sigs, diag, e, scrutinee, arms, true, expected)
    case EPropagate(inner) -> inferPropagate(sc, tbl, sigs, diag, e, inner, expected)
    case EBlock(blk) -> checkBlock(
      sc,
      tbl,
      sigs,
      sc.genericNames,
      sc.returnTy,
      sc.returnTyExpr,
      diag,
      blk,
      true,
      expected
    )
    case EUnsafe(blk) -> checkBlock(
      sc,
      tbl,
      sigs,
      sc.genericNames,
      sc.returnTy,
      sc.returnTyExpr,
      diag,
      blk,
      true,
      expected
    )
    // #7545: a bracket literal (`[...]`) always type-checks as `slice[T]`
    // (docs/01 §2.7) when inferred on its own, but the two collection kinds
    // have distinct runtime representations (`T[]`/array vs `List<T>` on
    // dotnet, a real array vs `ArrayList` on the JVM) and neither backend's
    // codegen converts one into the other implicitly at a call/return
    // boundary — only a literal `EList` node itself is representation-
    // agnostic, since each backend's own literal-lowering already consults
    // the surrounding expected type to build the right runtime value
    // (`collExpectTop`/`MConcreteList` on MSIL, the ArrayList-by-default JVM
    // path). So when the expected type is the stdlib `List[T]`, the literal
    // is typed (and its elements checked) directly against `List[T]` here,
    // instead of falling through to the slice-typed `inferExpr` path — this
    // is what lets `val xs: List[Int] = [1, 2, 3]` type-check without an
    // explicit `.toList()`, while a genuine `slice[T]`-typed VALUE (a
    // variable, a call result, …) is no longer silently accepted where a
    // `List[T]` is expected (see `argSatisfiesParam`).
    // A tuple literal where a tuple type is expected: each element is checked
    // against its element type, and the elements the hoist binds are recorded
    // at it (#7850).
    case ETuple(elems) -> match unrefine(expected) {
      case TyTuple(ets) -> if ets.count == elems.count {
        val ts: List[Type] = newList()
        val ownTs: List[Type] = newList()
        var ti = 0
        var leavesOpen = false
        while ti < elems.count {
          // An element initialises its slot, so a scalar widens to the
          // element type (#7813).
          val own = inferExprExpected(sc, tbl, sigs, diag, elems[ti], ets[ti])
          val widened = if typeIsClosed(ets[ti]) { widenedSlotType(tbl, ets[ti], own, elems[ti]) } else { own }
          val joinedElem = joinOpenTypes(widened, unrefine(ets[ti]))
          if renderType(joinedElem) != renderType(widened) or tupleElemBuildsGeneric(sc, tbl, elems[ti], joinedElem) {
            leavesOpen = true
          }
          ownTs.add(widened)
          ts.add(joinedElem)
          noteRangeSlot(tbl, ets[ti], elems[ti], "tuple element " + toString(ti + 1))
          ti = ti + 1
        }
        recordHoistedOperands(sc, tbl, elems, ts, ets)
        // A component that fixes nothing about its type (`None`, `Ok(2)`) is
        // built at the type its position gives it; a backend that erases the
        // tuple's element type (a `List` of tuples on dotnet) cannot recover
        // it from the tuple (#8092).
        if leavesOpen {
          recordHoistOperandTypeOver(tbl, sc.genericNames, e, TyTuple(elems = ownTs), expected)
        }
        TyTuple(elems = ts)
      } else {
        inferExpr(sc, tbl, sigs, diag, e)
      }
      case _ -> inferExpr(sc, tbl, sigs, diag, e)
    }
    case EList(elems) -> match unrefine(expected) {
      case TyUser(eid, ename, eargs) -> {
        // #7696: id-based, matching `.toList()`'s own resolution
        // (`isStdCollectionsHostType`, #7665) rather than the bare name —
        // an EARLIER revision of this arm matched any type named "List" by
        // NAME alone, which meant a package's own unrelated `record List[T]`
        // (not the stdlib collection) also intercepted a bracket literal
        // here, and codegen (`collExpectTop`/`MConcreteList` on MSIL, the
        // ArrayList-by-default JVM path) unconditionally builds the GENUINE
        // stdlib collection regardless of what the checker resolved "List"
        // to — exactly the same checker/codegen split #7665 fixed for
        // `.toList()`. A literal is built fresh at its own use site, so
        // (unlike `.toList()`) there is no cross-package identity to
        // preserve; it just must always be the REAL `Std.CollectionsHost.List`
        // codegen actually constructs, never a same-named local shadow.
        val isStdList = isStdCollectionsHostType(tbl, eid, "List")
        if isStdList and eargs.count == 1 {
          noteListLiteralInListContext(tbl, e)
          val elemTy = eargs[0]
          val elemOwn: List[Type] = newList()
          val elemAt: List[Type] = newList()
          var li = 0
          while li < elems.count {
            val et = inferExprExpected(sc, tbl, sigs, diag, elems[li], elemTy)
            recordSliceShapedElement(sc, tbl, elems[li], elemTy)
            elemOwn.add(et)
            elemAt.add(elemTy)
            recordWideningSite(tbl, elemTy, et, elems[li], false)
            noteRangeSlot(tbl, elemTy, elems[li], "element")
            if not argSatisfiesParam(tbl, elemTy, et) {
              diag.add(
                errorDiagnostic(
                  "T0041",
                  "list literal element has type " + renderType(et) + " but List[" + renderType(elemTy) + "] expects " +
                    renderType(elemTy),
                  elems[li].span
                )
              )
            }
            li = li + 1
          }
          recordHoistedOperands(sc, tbl, elems, elemOwn, elemAt)
          TyUser(id = eid, name = ename, args = eargs)
        } else {
          inferExpr(sc, tbl, sigs, diag, e)
        }
      }
      // A bracket literal where an `array[N, T]` is expected builds one: it
      // must have exactly `N` elements, each checked against `T` (D167,
      // T0155).
      case TyArray(Some(n), elemTy, _) -> {
        if elems.count != n {
          diag.add(
            errorDiagnostic(
              "T0155",
              "an array literal of " + toString(elems.count) + " element(s) where " + renderType(expected) +
                " is expected: it must have exactly " +
                toString(n),
              e.span
            )
          )
        }
        var ai = 0
        while ai < elems.count {
          val et = inferExprExpected(sc, tbl, sigs, diag, elems[ai], elemTy)
          recordSliceShapedElement(sc, tbl, elems[ai], elemTy)
          recordWideningSite(tbl, elemTy, et, elems[ai], false)
          noteRangeSlot(tbl, elemTy, elems[ai], "element")
          if not argSatisfiesParam(tbl, elemTy, et) {
            diag.add(
              errorDiagnostic(
                "T0041",
                "array literal element has type " + renderType(et) + " but " + renderType(expected) + " expects " +
                  renderType(elemTy),
                elems[ai].span
              )
            )
          }
          ai = ai + 1
        }
        val litKey = recordCopySiteKey(e.span)
        if not tbl.arrayLiteralSites.containsKey(litKey) {
          match typeExprForRef(tbl, TyArray(size = Some(value = n), element = elemTy, sizeVar = ""), e.span) {
            case Some(arrTe) -> tbl.arrayLiteralSites.add(litKey, arrTe)
            case None -> ()
          }
        }
        TyArray(size = Some(value = n), element = elemTy, sizeVar = "")
      }
      // A bracket literal where a numeric `slice[T]` is expected: each
      // element initialises a `T`, so it widens like an initialiser (docs/01
      // §4.1, #7805) instead of fixing the literal's element type to the
      // first element's own type.  A slice of slices checks each element
      // against the inner slice type too, so an element literal is built as
      // one (#8192).
      case TySlice(elemTy) -> if (isNumericPrimType(elemTy) or isSliceType(elemTy) or isStdListType(tbl, elemTy)) and elems.count > 0 {
        var si = 0
        while si < elems.count {
          val et = inferExprExpected(sc, tbl, sigs, diag, elems[si], elemTy)
          recordSliceShapedElement(sc, tbl, elems[si], elemTy)
          recordWideningSite(tbl, elemTy, et, elems[si], false)
          if not argSatisfiesParam(tbl, elemTy, et) {
            diag.add(
              errorDiagnostic(
                "T0041",
                "slice literal element has type " + renderType(et) + " but slice[" + renderType(elemTy) + "] expects " +
                  renderType(elemTy),
                elems[si].span
              )
            )
          }
          si = si + 1
        }
        TySlice(element = elemTy)
      } else {
        inferExpr(sc, tbl, sigs, diag, e)
      }
      case _ -> inferExpr(sc, tbl, sigs, diag, e)
    }
    case _ -> inferExpr(sc, tbl, sigs, diag, e)
  }
}

// A2: the contextual (expected) type for each call argument, used to type
// deferred lambda arguments.  Slots without a usable expectation carry
// `TyError` ("no expectation" — `inferExprExpected` then falls back to the
// historical lenient path).  Expectations come from the selected direct
// signature (named-arg aware via `argIndicesInParamOrder`; generic `TyVar`s
// substituted from the *other* arguments' types, mirroring
// `instantiateReturnType`'s substitute-then-erase approach) or, for a
// function-typed callee value, positionally from its parameter types.
// Deferred-lambda slots are blanked to `TyError` during generic inference so
// their first-pass placeholder types never poison a binding that another
// argument position determines.
// Validate a call's argument list against a selected signature: arity with
// trailing-default elision (#1503, T0042), named-arg pairing (#3066),
// per-argument assignability (T0043), and `out`/`inout` l-value-ness (#1487,
// T0085).  Shared by the direct-signature path and the A4 method-call path
// (whose signatures are receiver-dropped, so `sig.params` aligns 1:1 with
// `args` in both).
// T0133 (#7228, language reference §6.3): a contract clause or loop
// invariant may call only `@pure` functions.  Only calls that resolve to a
// declared Lyric function reach here; operators, field reads and built-in
// collection/string members are not function calls.
func checkContractCallPure(
  sc: in Scope,
  diag: in List[Diagnostic],
  sig: in ResolvedSignature,
  fn: in Expr,
  span: in Span,
): Unit {
  if sc.contractDepth.count == 0 or sig.isPure {
    return
  }
  val name = match fn.kind {
    case EPath(path) -> if path.segments.count > 0 { path.segments[path.segments.count - 1] } else { "?" }
    case EMember(_, m) -> m
    case _ -> "?"
  }
  diag.add(
    errorDiagnostic(
      "T0133",
      "a contract clause may call only @pure functions; '" + name +
        "' is not @pure (mark it @pure if it has no side effects, or move the check into the body)",
      span
    )
  )
}

// Record the callee a method call resolved to when the backends could not
// find it from the call alone (`SymbolTable.methodCallArities`): its
// parameter count when the call leaves out a defaulted argument (#7828), and
// that it is a dot-named function rather than the type's own method (#8098).
// A call inferred again replaces what an earlier inference recorded.
func recordMethodCallArity(
  tbl: in SymbolTable, callee: in Expr, written: in Int, resolved: in Int, dotNamed: in Bool
): Unit {
  val key = methodCallSiteKey(callee)
  if tbl.methodCallArities.containsKey(key) {
    tbl.methodCallArities.remove(key)
  }
  if resolved != written or dotNamed {
    tbl.methodCallArities.add(key, methodCallTargetCode(MethodCallTarget(dotNamed = dotNamed, arity = resolved)))
  }
}

// `recordMethodCallArity` under an explicit site key.
func recordCalleeArityAt(tbl: in SymbolTable, key: in String, written: in Int, resolved: in Int): Unit {
  if tbl.methodCallArities.containsKey(key) {
    tbl.methodCallArities.remove(key)
  }
  if resolved != written {
    tbl.methodCallArities.add(key, resolved)
  }
}

// A call's arguments pair with its parameters by name, then positionally
// (`argIndicesInParamOrder`); the count check alone cannot see a named
// argument naming no parameter (it would be dropped) or a parameter with no
// default left without an argument by a named or mixed call (`f(b = 1)` for
// `f(a: Int, b: Int = 0)`).  Both are T0042: no backend can fill a
// parameter that has no default (#7820).
func reportUnpairedCallArgs(
  diag: in List[Diagnostic],
  sig: in ResolvedSignature,
  args: in List[CallArg],
  paramNames: in List[String],
  srcIdx: in List[Int],
  span: in Span,
): Unit {
  reportUnknownNamedArgs(diag, args, paramNames)
  var k = 0
  while k < sig.params.count {
    if srcIdx[k] < 0 and not sig.params[k].hasDefault {
      if sig.params[k].defaultUnavailable {
        diag.add(unavailableDefaultDiagnostic(sig.params[k].name, span))
      } else {
        diag.add(
          errorDiagnostic("T0042", "missing argument for parameter '" + sig.params[k].name + "', which has no default", span)
        )
      }
    }
    k = k + 1
  }
}

// T0218: a parameter of a restored package declares a default its contract
// could not export, because the type names a type parameter or `Self`, which
// a nullary compiled thunk cannot bind (D168 item 4, #8076).
func unavailableDefaultDiagnostic(name: in String, span: in Span): Diagnostic {
  errorDiagnostic(
    "T0218",
    "parameter '" + name +
      "' has a default, but the declaring package cannot export it: its type names a type parameter or 'Self', so a compiled default cannot be used across a package boundary; pass the argument explicitly",
    span
  )
}

// Reports T0218 for each positional parameter from `supplied` on whose
// default is unavailable; true when it reported any.
func reportUnavailableDefaults(
  diag: in List[Diagnostic], sig: in ResolvedSignature, supplied: in Int, span: in Span
): Bool {
  var reported = false
  var k = supplied
  while k < sig.params.count {
    if sig.params[k].defaultUnavailable {
      diag.add(unavailableDefaultDiagnostic(sig.params[k].name, span))
      reported = true
    }
    k = k + 1
  }
  reported
}

// T0042 for each named argument that names no parameter.
func reportUnknownNamedArgs(diag: in List[Diagnostic], args: in List[CallArg], paramNames: in List[String]): Unit {
  for a in args {
    match a {
      case CANamed(nm, _, asp) -> if not paramNames.contains(nm) {
        diag.add(errorDiagnostic("T0042", "no parameter named '" + nm + "'", asp))
      }
      case CAPositional(_) -> ()
    }
  }
}

// For each parameter, the index of the argument that pairs with it whatever
// else the call repeats, or -1: a positional argument before the first named
// one fills the parameter at its own position, and otherwise the one named
// argument that names the parameter.  A positional argument after a named one
// is left out, since its slot depends on the pairing a repeat throws off.
func uniquelyPairedArgIndices(args: in List[CallArg], paramNames: in List[String]): List[Int] {
  var leading = 0
  var stop = false
  while leading < args.count and not stop {
    match args[leading] {
      case CAPositional(_) -> {
        leading = leading + 1
      }
      case CANamed(_, _, _) -> {
        stop = true
      }
    }
  }
  val idx: List[Int] = newList()
  var pi = 0
  while pi < paramNames.count {
    if pi < leading {
      idx.add(pi)
    } else {
      val pn = paramNames[pi]
      var found = -1
      var n = 0
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CANamed(nm, _, _) -> if nm == pn { found = ai; n = n + 1 }
          case CAPositional(_) -> ()
        }
        ai = ai + 1
      }
      idx.add(if n == 1 { found } else { -1 })
    }
    pi = pi + 1
  }
  idx
}

func checkCallArgsAgainstSig(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  sig: in ResolvedSignature,
  args: in List[CallArg],
  argTypes: in List[Type],
  span: in Span,
): Unit {
  // Count required params (those without a default value) to allow
  // calls that omit trailing defaulted parameters (#1503).
  var minRequired = 0
  var mri = 0
  while mri < sig.params.count {
    if not sig.params[mri].hasDefault {
      minRequired = minRequired + 1
    }
    mri = mri + 1
  }
  val paramNames: List[String] = newList()
  var pni = 0
  while pni < sig.params.count {
    paramNames.add(sig.params[pni].name)
    pni = pni + 1
  }
  // A repeated argument also throws the count and the positional pairing
  // off, so the arity check and the checks of positional arguments would
  // report the same mistake again.  A name that names no parameter, each
  // positional argument before the first named one, and each argument named
  // exactly once, are still checked.
  if reportRepeatedCallArgs(diag, "T0042", "parameter", args, paramNames) {
    reportUnknownNamedArgs(diag, args, paramNames)
    checkPairedCallArgs(sc, tbl, sigs, diag, sig, args, argTypes, uniquelyPairedArgIndices(args, paramNames), span)
    return
  }
  if args.count < minRequired or args.count > sig.params.count {
    if args.count < sig.params.count and reportUnavailableDefaults(diag, sig, args.count, span) {
      return
    }
    val expectedMsg = if minRequired == sig.params.count {
      toString(sig.params.count) + " argument(s)"
    } else {
      toString(minRequired) + "–" + toString(sig.params.count) + " argument(s)"
    }
    diag.add(errorDiagnostic("T0042", "expected " + expectedMsg + ", got " + toString(args.count), span))
  } else {
    // Only validate the args that were actually supplied; missing
    // trailing params with defaults are filled in by codegen.  Args
    // are paired with their parameter by name for named args (#3066),
    // mirroring the constructor path's `argTypesInFieldOrder`; a
    // purely positional call pairs slot k with arg k as before.
    val srcIdx = argIndicesInParamOrder(args, paramNames)
    reportUnpairedCallArgs(diag, sig, args, paramNames, srcIdx, span)
    checkPairedCallArgs(sc, tbl, sigs, diag, sig, args, argTypes, srcIdx, span)
    if sig.generics.count > 0 and not sig.isExternFunc {
      reportGenericBindingConflicts(sc, tbl, diag, sig, args, argTypes, srcIdx)
    }
  }
}

// A value generic parameter's binding (an array length), which
// `bindValueGenericCall` checks with its own diagnostic.
func isLengthBinding(t: in Type): Bool {
  match t {
    case TyLen(_) -> true
    case _ -> false
  }
}

func widensEitherWay(a: in Type, b: in Type): Bool {
  match widenArithmetic(a, b) {
    case Some(_) -> true
    case None -> false
  }
}

// T0043 for a type parameter of the generic `sig` that two arguments bind
// to types neither of which satisfies the other (`k(a, c)` with
// `k[T](xs: List[T], ys: List[T])`, `a: List[Int]` and `c: List[String]`).
// Each argument satisfies its parameter on its own, where the type parameter
// is open, so nothing else reports it, and the call would be instantiated at
// one of the two types and handed a value of the other.  A binding the
// argument leaves open, or a numeric one that widens to the other, is no
// conflict, and a value generic parameter's lengths are checked elsewhere.
func reportGenericBindingConflicts(
  sc: in Scope,
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sig: in ResolvedSignature,
  args: in List[CallArg],
  argTypes: in List[Type],
  srcIdx: in List[Int],
): Unit {
  for g in sig.generics {
    var bound: Type = TyError
    var boundArg = -1
    var k = 0
    var reported = false
    while k < srcIdx.count and k < sig.params.count and not reported {
      val ai = srcIdx[k]
      if ai >= 0 and ai < argTypes.count {
        match findGenericInPair(g, sig.params[k].ty, argTypes[ai]) {
          case Some(v) -> if typeIsClosedOver(v, sc.genericNames) and not isLengthBinding(v) {
            if boundArg < 0 {
              bound = v
              boundArg = ai
            } else if not argSatisfiesParam(tbl, bound, v) and not argSatisfiesParam(tbl, v, bound) and not widensEitherWay(bound, v) {
              diag.add(
                errorDiagnostic(
                  "T0043",
                  "argument " + toString(boundArg + 1) + " binds type parameter '" + g + "' to " + renderType(bound) +
                    " but argument " +
                    toString(ai + 1) +
                    " binds it to " +
                    renderType(v),
                  callArgExpr(args[ai]).span
                )
              )
              reported = true
            }
          }
          case None -> ()
        }
      }
      k = k + 1
    }
  }
}

// Check each argument against the parameter `srcIdx` pairs it with
// (`srcIdx[k]` is the argument for parameter k, or -1).
func checkPairedCallArgs(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  sig: in ResolvedSignature,
  args: in List[CallArg],
  argTypes: in List[Type],
  srcIdx: in List[Int],
  span: in Span,
): Unit {
  var k = 0
  while k < sig.params.count {
    val p = sig.params[k]
    val ai = srcIdx[k]
    if ai >= 0 {
      val argTy = if ai < argTypes.count { argTypes[ai] } else { TyError }
      noteExpectedFlow(sc, tbl, callArgExpr(args[ai]), p.ty)
      if (match p.mode { case PMIn -> true; case _ -> false }) {
        recordUnsignedWidening(tbl, p.ty, argTy, callArgExpr(args[ai]))
      }
      val satisfied = if sig.isExternFunc {
        argSatisfiesExternParam(tbl, p.ty, argTy)
      } else if (match p.mode { case PMIn -> true; case _ -> false }) {
        argFlowSatisfies(tbl, p.ty, argTy, callArgExpr(args[ai]))
      } else {
        argSatisfiesParam(tbl, p.ty, argTy)
      }
      if sig.isExternFunc {
        checkManagedCallbackCrossPackage(tbl, diag, sig, p.ty, argTy, callArgExpr(args[ai]).span)
      }
      val rigidClash = not sig.isExternFunc and rigidVarClash(tbl, p.ty, argTy, sc.genericNames)
      if (not satisfied and not literalArgSatisfiesParam(tbl, p.ty, argTy, callArgExpr(args[ai]))) or rigidClash {
        diag.add(
          errorDiagnostic(
            "T0043",
            argTypeMismatchSubject(argTy, args, ai) + " does not match parameter type " + renderOptTypeExpr(p.tyExpr, p.ty) +
              externCallbackHint(tbl, sig, p.ty) +
              typeMismatchHint(tbl, p.ty, argTy),
            span
          )
        )
      }
      // An array passed to `out`/`inout` is the caller's own place and is
      // not copied; any other argument is a read that escapes into the
      // callee, so one read from a writable place is copied (D167).
      if modeNeedsLValue(p.mode) {
        exemptArrayCopy(tbl, callArgExpr(args[ai]))
        checkArrayByRefArg(sc, tbl, sigs, diag, callArgExpr(args[ai]), argTy, span)
      }
      // #1487 (§5.2): an `out`/`inout` argument must be a writable l-value,
      // whatever its type: the parameter refers to the caller's place
      // (D183), which the callee may assign.
      // A by-reference receiver written as an argument (`T.m(p)`, or a
      // function whose first parameter is `self: inout T`) is held to the
      // receiver rule of a method call, whatever its type (#8179).
      if k == 0 and p.name == "self" and modeNeedsLValue(p.mode) {
        checkByRefReceiver(sc, tbl, sigs, diag, callArgExpr(args[ai]), "self", span)
      } else if modeNeedsLValue(p.mode) and elementByRefProblem(sc, tbl, sigs, callArgExpr(args[ai])).length > 0 {
        diag.add(
          errorDiagnostic(
            "T0085",
            "argument for `out`/`inout` parameter '" + p.name + "' must be a mutable l-value: " +
              elementByRefProblem(sc, tbl, sigs, callArgExpr(args[ai])),
            span
          )
        )
      } else if modeNeedsLValue(p.mode) and byRefArgModuleProblem(sc, callArgExpr(args[ai])).length > 0 {
        diag.add(
          errorDiagnostic(
            "T0085",
            "argument for `out`/`inout` parameter '" + p.name + "' must be a mutable l-value: " +
              byRefArgModuleProblem(sc, callArgExpr(args[ai])),
            span
          )
        )
      } else if modeNeedsLValue(p.mode) and not argIsValidByRefTarget(sc, tbl, sigs, callArgExpr(args[ai])) {
        diag.add(
          errorDiagnostic(
            "T0085",
            byRefTargetProblem(sc, tbl, sigs, p.name, callArgExpr(args[ai])),
            callArgExpr(args[ai]).span
          )
        )
      }
    }
    k = k + 1
  }
}

func expectedCallArgTypes(
  tbl: in SymbolTable,
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
  directSig: in Option[ResolvedSignature],
  fnT: in Type,
): List[Type] {
  val expected: List[Type] = newList()
  var i = 0
  while i < args.count {
    expected.add(TyError)
    i = i + 1
  }
  match directSig {
    case Some(sig) -> {
      if args.count <= sig.params.count {
        val paramNames: List[String] = newList()
        var pn = 0
        while pn < sig.params.count {
          paramNames.add(sig.params[pn].name)
          pn = pn + 1
        }
        val srcIdx = argIndicesInParamOrder(args, paramNames)
        var targs: List[Type] = newList()
        if sig.generics.count > 0 {
          val paramTys: List[Type] = newList()
          val argsInParamOrder: List[Type] = newList()
          var k = 0
          while k < sig.params.count {
            paramTys.add(sig.params[k].ty)
            val ai = srcIdx[k]
            var slotTy: Type = TyError
            if ai >= 0 and ai < argTypes.count {
              val slotExpr = callArgExpr(args[ai])
              if not lambdaHasUnannotatedParam(slotExpr) and not argIsAmbiguousUnionCaseCtor(tbl, slotExpr) {
                slotTy = argTypes[ai]
              }
            }
            argsInParamOrder.add(slotTy)
            k = k + 1
          }
          targs = inferGenericArgsForSig(sig, paramTys, argsInParamOrder)
        }
        var k2 = 0
        while k2 < sig.params.count {
          val ai2 = srcIdx[k2]
          if ai2 >= 0 and ai2 < expected.count {
            if sig.generics.count > 0 {
              expected[ai2] = substituteTyVars(sig.params[k2].ty, sig.generics, targs)
            } else if sig.isExternFunc {
              expected[ai2] = externArgExpectedType(tbl, sig.params[k2].ty)
            } else {
              expected[ai2] = sig.params[k2].ty
            }
          }
          k2 = k2 + 1
        }
      }
    }
    // #7752: a non-generic record constructor's arguments are expected to
    // have their fields' declared types (named args matched by field name,
    // positional ones filling the remaining slots, as `inferConstruction`
    // itself pairs them), so an `if`/`match` or union-case-constructor field
    // initialiser is checked against its field's type too.
    case None -> match nonGenericRecordCtorOf(tbl, fn) {
      case Some(ctorSym) -> {
        val fields: List[CtorField] = newList()
        if collectCtorFields(tbl, ctorSym, fields) {
          val fieldNames: List[String] = newList()
          var fn4 = 0
          while fn4 < fields.count {
            fieldNames.add(fields[fn4].name)
            fn4 = fn4 + 1
          }
          val fieldSrcIdx = argIndicesInParamOrder(args, fieldNames)
          var k4 = 0
          while k4 < fields.count {
            val ai4 = fieldSrcIdx[k4]
            if ai4 >= 0 and ai4 < expected.count {
              expected[ai4] = fields[k4].ty
            }
            k4 = k4 + 1
          }
        }
      }
      case None -> match unrefine(fnT) {
        case TyFunction(pps, _, _) -> if pps.count == args.count {
          var k3 = 0
          while k3 < pps.count {
            expected[k3] = pps[k3]
            k3 = k3 + 1
          }
        }
        case _ -> {
        }
      }
    }
  }
  expected
}

// #7752: the constructor symbol `fn` names when it is a NON-generic record
// (or exposed record / opaque type) constructor rather than a union case —
// the same `unionCaseSymbolOf`-before-`constructorSymbolOf` precedence the
// `ECall` arm dispatches with.  A generic record's field types mention its
// type parameters, so they are never a closed expectation.
func nonGenericRecordCtorOf(tbl: in SymbolTable, fn: in Expr): Option[Symbol] {
  match unionCaseSymbolOf(tbl, fn) {
    case Some(_) -> return None
    case None -> ()
  }
  match constructorSymbolOf(tbl, fn) {
    case Some(ctorSym) -> if ctorIsGeneric(ctorSym) { None } else { Some(value = ctorSym) }
    case None -> None
  }
}

// `NativePtr[Byte]`: the C `void*` an `extern func` declares for a callback's
// userdata slot and for an opaque handle.  Only a native check knows the type.
func isNativeBytePtrType(tbl: in SymbolTable, t: in Type): Bool {
  match mapGet(tbl.nativeIntrinsicTypes, "NativePtr") {
    case Some(ptrId) -> match unrefine(t) {
      case TyUser(tid, _, targs) -> if symbolIdEq(tid, ptrId) and targs.count == 1 {
        match unrefine(targs[0]) {
          case TyPrim(pt) -> match pt { case PtByte -> true; case _ -> false }
          case _ -> false
        }
      } else {
        false
      }
      case _ -> false
    }
    case None -> false
  }
}

// An `extern func` callback parameter `(P1, …, Pk-1, NativePtr[Byte]) -> R`
// takes the Lyric closure `(P1, …, Pk-1) -> R`: the native backend wraps it
// in a C-ABI trampoline that receives the closure pointer through the
// trailing userdata slot (docs/01 §11.6, N4.5).  None when `paramTy` is not
// such a callback type.
func externCallbackClosureType(tbl: in SymbolTable, paramTy: in Type): Option[Type] {
  match unrefine(paramTy) {
    case TyFunction(ps, ret, isAsync) -> {
      val ud = externCallbackUserdataIndex(tbl, ps)
      if ud < 0 {
        return None
      }
      val reduced: List[Type] = newList()
      var i = 0
      while i < ps.count {
        if i != ud {
          reduced.add(ps[i])
        }
        i = i + 1
      }
      Some(value = TyFunction(params = reduced, ret = ret, isAsync = isAsync))
    }
    case _ -> None
  }
}

// `NativeUserdata`: marks the parameter of an `extern func` callback type that
// carries the closure pointer, wherever the C API puts it (SDL3 puts it first,
// docs/67 §4.8).  It is a `void*` like `NativePtr[Byte]`.
func isNativeUserdataType(tbl: in SymbolTable, t: in Type): Bool {
  match mapGet(tbl.nativeIntrinsicTypes, "NativeUserdata") {
    case Some(udId) -> match unrefine(t) { case TyUser(tid, _, _) -> symbolIdEq(tid, udId); case _ -> false }
    case None -> false
  }
}

// The index of a callback signature's userdata slot: the first `NativeUserdata`
// parameter, else (the older spelling) a trailing `NativePtr[Byte]`; -1 when
// the signature has neither, so it is not a callback type.
func externCallbackUserdataIndex(tbl: in SymbolTable, ps: in List[Type]): Int {
  var i = 0
  while i < ps.count {
    if isNativeUserdataType(tbl, ps[i]) {
      return i
    }
    i = i + 1
  }
  if ps.count > 0 and isNativeBytePtrType(tbl, ps[ps.count - 1]) {
    return ps.count - 1
  }
  -1
}

// The type an argument to an `extern func` parameter is inferred against: the
// closure type for a callback parameter, the declared type otherwise.
func externArgExpectedType(tbl: in SymbolTable, paramTy: in Type): Type {
  match externCallbackClosureType(tbl, paramTy) {
    case Some(closureTy) -> closureTy
    case None -> paramTy
  }
}

// An `extern func` argument meets its parameter under the native extern-call
// adaptation (docs/01 §11.6, N4.5): a callback parameter takes only the
// closure of its reduced signature, a closure value also passes as a
// `NativePtr[Byte]` (its own pointer, the userdata a callback API is handed
// alongside the callback), and every other argument follows the ordinary
// rule.
func argSatisfiesExternParam(tbl: in SymbolTable, paramTy: in Type, argTy: in Type): Bool {
  match externCallbackClosureType(tbl, paramTy) {
    case Some(closureTy) -> return argSatisfiesParam(tbl, closureTy, argTy)
    case None -> ()
  }
  if isNativeBytePtrType(tbl, paramTy) or isNativeUserdataType(tbl, paramTy) {
    match unrefine(argTy) {
      case TyFunction(_, _, _) -> return true
      case _ -> ()
    }
  }
  // A `NativeUserdata` parameter is a `void*`: it also takes the pointer
  // `nativeKeepCallback` returns (D229).
  if isNativeUserdataType(tbl, paramTy) and isNativeBytePtrType(tbl, argTy) {
    return true
  }
  argSatisfiesParam(tbl, paramTy, argTy)
}

// T0184: on `--target dotnet` and `--target jvm` a C binding adapts a closure
// (into a trampoline address, or a pinned userdata pointer) where it is called,
// from the binding's declaration, so a callback argument, or a closure passed
// as a C pointer, reaches the binding only from the package that declares it
// (D229).  Another package calls a wrapper the declaring package exports.
// Native passes the closure itself and has no such limit.
func checkManagedCallbackCrossPackage(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sig: in ResolvedSignature,
  paramTy: in Type,
  argTy: in Type,
  span: in Span,
): Unit {
  if checkingForNative(tbl) or sig.originPackage.length == 0 {
    return
  }
  val curPkg = symTableScopePkg(tbl)
  if curPkg.length == 0 or curPkg == sig.originPackage {
    return
  }
  val isCallback = match externCallbackClosureType(tbl, paramTy) { case Some(_) -> true; case None -> false }
  val isClosureAsPointer = (isNativeBytePtrType(tbl, paramTy) or isNativeUserdataType(tbl, paramTy)) and
    match unrefine(argTy) { case TyFunction(_, _, _) -> true; case _ -> false }
  if isCallback or isClosureAsPointer {
    diag.add(
      errorDiagnostic(
        "T0184",
        "a closure reaches a C binding of package " + sig.originPackage +
          " only from that package on --target dotnet and --target jvm; call a wrapper function " +
          sig.originPackage +
          " declares instead",
        span
      )
    )
  }
}

// T0043 suffix naming the closure an `extern func` callback parameter takes,
// since the declared C signature carries a userdata slot the closure lacks.
func externCallbackHint(tbl: in SymbolTable, sig: in ResolvedSignature, paramTy: in Type): String {
  if not sig.isExternFunc {
    return ""
  }
  match externCallbackClosureType(tbl, paramTy) {
    case Some(closureTy) -> " (an extern callback parameter takes a closure of type " + renderType(closureTy) +
      ", without the NativeUserdata slot)"
    case None -> ""
  }
}

func paramsMatchArgs(tbl: in SymbolTable, params: in List[ResolvedParam], argTypes: in List[Type]): Bool {
  if params.count != argTypes.count {
    return false
  }
  var i = 0
  while i < params.count {
    if not argSatisfiesParam(tbl, params[i].ty, argTypes[i]) {
      return false
    }
    i = i + 1
  }
  true
}

// #7545: a bracket literal (`[...]`) passed directly as a constructor field
// argument (`R(items = [1, 2, 3])`) is, like a `List[T]`-annotated binding's
// initialiser, representation-agnostic — the backends' own `EList` codegen
// consults the field's declared type, not the checker's `TySlice` inference
// (see the `inferExprExpected` `EList` arm above for the full rationale).
// `inferConstruction`/`inferConstructionExpected` have no `sc`/`sigs` to
// re-run `inferExprExpected` with, so this reuses the ALREADY-inferred
// slice element type instead: `argTy` is `TySlice(elemTy)` (the type
// `inferExprCore`'s `EList` arm already gave the literal, `elemTy` its
// first element's type — homogeneity across elements is separately
// enforced by that arm's own T0041 check) and `fieldTy` is `List[pElem]`
// with `elemTy` assignable to `pElem` (or `elemTy` is `TyError`, the
// empty-literal `[]` case). Gated on the argument EXPRESSION itself being
// an `EList` node — never on `argTy` alone — so a genuine `slice[T]`-typed
// VALUE (a variable, a call result, …) still cannot satisfy a `List[T]`
// field; only the literal can, exactly matching what codegen actually
// builds.
//
// An unsuffixed float literal also satisfies a `Float` parameter or field: it
// adopts `Float` there (D155, `adoptFloatLiteralType`).
func literalArgSatisfiesParam(tbl: in SymbolTable, fieldTy: in Type, argTy: in Type, argExpr: in Expr): Bool {
  if isUnsuffixedFloatLit(argExpr) and isPlainDouble(argTy) and isFloatType(fieldTy) {
    recordFloatLiteralSite(tbl, argExpr)
    return true
  }
  // An unsuffixed integer literal argument for a `Byte`/`UInt`/`ULong`
  // parameter or field takes its type when it fits (#7841).
  if isUnsuffixedIntLit(argExpr) and isSomeSuffix(unsignedLiteralSuffix(fieldTy)) {
    val adopted = adoptUnsignedIntLiteral(tbl, argExpr, argTy, fieldTy)
    return not (isPlainInt(adopted) or isPlainLong(adopted))
  }
  val isLiteral = match argExpr.kind { case EList(_) -> true; case _ -> false }
  if not isLiteral {
    return false
  }
  match argTy {
    // #7696: id-based (`isStdCollectionsHostType`), matching the
    // `inferExprExpected` `EList` arm above — see its header comment. A
    // package's own unrelated `record List[T]` field must NOT accept a
    // bracket literal here either, for the same reason: this codepath
    // exists specifically because codegen builds the GENUINE stdlib
    // collection at this argument's use site, regardless of what a
    // same-named local type happens to resolve to.
    case TySlice(elemTy) -> match unrefine(fieldTy) {
      case TyUser(pid, _, pArgs) -> {
        val isStdList = isStdCollectionsHostType(tbl, pid, "List")
        if isStdList and pArgs.count == 1 {
          noteListLiteralInListContext(tbl, argExpr)
          match unrefine(elemTy) {
            case TyError -> true
            case _ -> argSatisfiesParam(tbl, pArgs[0], elemTy)
          }
        } else {
          false
        }
      }
      case _ -> false
    }
    case _ -> false
  }
}

// The suffix every type-mismatch diagnostic appends ("" when there is
// nothing to add), so callers can always append the result to their message.
// #7545: when a type mismatch is specifically a `slice[T]`/`List[T]`
// mix-up, the diagnostic points at the explicit conversion (docs/01 §2.7)
// rather than leaving the reader to guess. #7737: when the two types merely
// share a name, it says so (`sameNameTypesNote`).
//
// #7737: "List" here means the stdlib `Std.CollectionsHost.List`, by
// identity. `.toList()` always builds that type and `.toArray()` exists only
// on it, so suggesting either for a package's own same-named type was wrong
// advice; the conversion is also only suggested when it would actually fix
// the mismatch (the slice's element type fits the List's), so
// `["a"]`-against-`List[Int]` is no longer told to call `.toList()`. When the
// expected type merely shares the stdlib name, the hint says so instead — a
// rendered `List[Int]` alone reads as the stdlib type.
pub func typeMismatchHint(tbl: in SymbolTable, expected: in Type, actual: in Type): String {
  val sameName = sameNameTypesNote(tbl, expected, actual)
  if sameName != "" {
    return sameName
  }
  val widenNote = containerWideningNote(tbl, expected, actual)
  if widenNote != "" {
    return widenNote
  }
  match unrefine(actual) {
    case TySlice(sliceElem) -> match unrefine(expected) {
      case TyUser(eid, eName, eArgs) -> if eArgs.count == 1 and isStdCollectionsHostType(tbl, eid, "List") {
        if argSatisfiesParam(tbl, eArgs[0], sliceElem) {
          " (use .toList() to convert the slice to a List)"
        } else {
          ""
        }
      } else {
        val note = shadowedStdCollectionNote(tbl, expected)
        if note != "" and eName == "List" {
          " (this 'List' is a different type that only shares its name with the stdlib List; a list literal or .toList() " +
            "only builds the stdlib List)"
        } else {
          note
        }
      }
      case _ -> ""
    }
    case TyUser(aid, _, aArgs) -> if aArgs.count == 1 and isStdCollectionsHostType(tbl, aid, "List") {
      match unrefine(expected) {
        case TySlice(sliceElem) -> if argSatisfiesParam(tbl, sliceElem, aArgs[0]) {
          " (use .toArray() to convert the List to a slice)"
        } else {
          ""
        }
        case _ -> ""
      }
    } else {
      ""
    }
    case _ -> ""
  }
}

// #7813: an existing `Option[UInt]` (or tuple, `Result`, …) value where an
// `Option[ULong]` is expected.  Its scalars would widen were the value built
// in place, but a built value is not converted: say so, and how to rebuild
// it.  "" unless `actual` differs from `expected` only by such widenings.
func containerWideningNote(tbl: in SymbolTable, expected: in Type, actual: in Type): String {
  if numericWidensTo(expected, actual) or not widensStructurally(expected, actual) {
    return ""
  }
  val conv = firstWideningMethod(expected, actual)
  val head = " (implicit numeric widening converts a scalar where a value is built, not the contents of an existing " +
    renderType(actual) +
    " value; rebuild it with its contents converted"
  if conv == "" {
    return head + ")"
  }
  val helper = match unrefine(expected) {
    case TyUser(eid, _, eargs) -> match unrefine(actual) {
      case TyUser(_, _, aargs) -> if eargs.count == 1 and isStdCoreMonadType(tbl, eid, "Option") {
        "mapOption"
      } else if eargs.count == 2 and aargs.count == 2 and isStdCoreMonadType(tbl, eid, "Result") {
        if typeEquiv(eargs[0], aargs[0]) {
          "mapResultErr"
        } else if typeEquiv(eargs[1], aargs[1]) {
          "mapResult"
        } else {
          ""
        }
      } else {
        ""
      }
      case _ -> ""
    }
    case _ -> ""
  }
  if helper != "" and numericWidensTo(monadPayloadAt(expected, helper), monadPayloadAt(actual, helper)) {
    head + ", e.g. " + helper + "(value, { x -> x." + conv + "() }))"
  } else {
    head + " explicitly with ." + conv + "())"
  }
}

// The payload `helper` (`mapOption`, `mapResult`, `mapResultErr`) maps.
func monadPayloadAt(t: in Type, helper: in String): Type {
  match unrefine(t) {
    case TyUser(_, _, targs) -> {
      val idx = if helper == "mapResultErr" { 1 } else { 0 }
      if idx < targs.count {
        targs[idx]
      } else {
        TyError
      }
    }
    case _ -> TyError
  }
}

// The conversion method of the first scalar widening `src` needs to become
// `target`, in left-to-right order of their type arguments and tuple
// elements; "" when there is none.
func firstWideningMethod(target: in Type, src: in Type): String {
  if numericWidensTo(target, src) {
    return match wideningMethod(target, src) { case Some(m) -> m; case None -> "" }
  }
  val ts = typePartsOf(target)
  val ss = typePartsOf(src)
  var i = 0
  while i < ts.count and i < ss.count {
    val m = firstWideningMethod(ts[i], ss[i])
    if m != "" {
      return m
    }
    i = i + 1
  }
  ""
}

// A tuple's element types or a user type's type arguments.
func typePartsOf(t: in Type): List[Type] {
  match unrefine(t) {
    case TyTuple(es) -> es
    case TyUser(_, _, targs) -> targs
    case _ -> newList()
  }
}

// #7737: two distinct types with the same bare name render identically
// ("argument type Result[Age, String] does not match parameter type
// Result[Age, String]"), which reads as a checker bug. Name both declaring
// packages instead. "" unless `expected` and `actual` are user types with the
// same name and different identities.
func sameNameTypesNote(tbl: in SymbolTable, expected: in Type, actual: in Type): String {
  match unrefine(expected) {
    case TyUser(eid, eName, _) -> match unrefine(actual) {
      case TyUser(aid, aName, _) -> {
        if eName != aName or symbolIdEq(eid, aid) {
          return ""
        }
        val ePkg = match symTableTypeSymbolOf(tbl, eid) { case Some(sym) -> sym.originPackage; case None -> "" }
        val aPkg = match symTableTypeSymbolOf(tbl, aid) { case Some(sym) -> sym.originPackage; case None -> "" }
        if ePkg != "" and aPkg != "" and ePkg != aPkg {
          " (these are two different types named '" + eName + "': the value is " + aPkg + "." + aName + ", the target is " +
            ePkg +
            "." +
            eName +
            ")"
        } else {
          " (these are two different types named '" + eName + "')"
        }
      }
      case _ -> ""
    }
    case _ -> ""
  }
}

// #7737: when `t` is a type that merely shares a stdlib collection's bare
// name (a package's own `record List[T]`, say), a note saying so — the
// rendered type (`List[Int]`) is otherwise indistinguishable from the
// stdlib one, which makes a bracket-literal or iteration diagnostic against
// it read as self-contradictory. "" for every other type, including the
// genuine stdlib collections. A diagnostic-text-only use of the bare name.
pub func shadowedStdCollectionNote(tbl: in SymbolTable, t: in Type): String {
  match unrefine(t) {
    case TyUser(tid, name, _) -> {
      val isStdName = name == "List" or name == "Map" or name == "Set" or name == "MapKeyCollection" or
        name == "MapValueCollection"
      if isStdName and not isStdCollectionsHostType(tbl, tid, name) {
        " (this '" + name + "' is a different type that only shares its name with the stdlib " + name + ")"
      } else {
        ""
      }
    }
    case _ -> ""
  }
}

// #7737: an empty bracket literal (`[]`) infers as `slice[<error>]` — there
// is no element to type it from — and rendering that type in a mismatch
// diagnostic ("has type slice[<error>]") reads like an internal failure. The
// mismatch sites describe such an argument as "an empty list literal"
// instead.
pub func isEmptyListLiteral(e: in Expr): Bool {
  match e.kind {
    case EList(elems) -> elems.count == 0
    case _ -> false
  }
}

// The subject half of a "`<what>` has type T but ..." mismatch message:
// `"has type T"`, or `"is an empty list literal"` for `[]` (#7737).
pub func hasTypeOrEmptyLiteral(t: in Type, e: in Expr): String {
  if isEmptyListLiteral(e) {
    "is an empty list literal"
  } else {
    "has type " + renderType(t)
  }
}

// The subject of a T0043 argument-mismatch message: `"argument type T"`, or
// `"argument (an empty list literal)"` when the argument at `idx` is `[]`
// (#7737).
func argTypeMismatchSubject(t: in Type, args: in List[CallArg], idx: in Int): String {
  if idx >= 0 and idx < args.count and isEmptyListLiteral(callArgExpr(args[idx])) {
    "argument (an empty list literal)"
  } else {
    "argument type " + renderType(t)
  }
}

// The `"of type T"` qualifier of a mismatch message, or
// `"(an empty list literal)"` for `[]` (#7737).
pub func ofTypeOrEmptyLiteral(t: in Type, e: in Expr): String {
  if isEmptyListLiteral(e) {
    "(an empty list literal)"
  } else {
    "of type " + renderType(t)
  }
}

// True when an argument of type `argTy` is acceptable for a parameter of type
// `paramTy` — either `typeEquiv` (the usual case), or interface subtyping
// (#1488): `argTy` is a user type `T` and `paramTy` is an interface `I` with a
// registered `impl I for T`.  Conformance is keyed by `SymbolId`, so a
// same-simple-name interface from another package never satisfies the check
// (#2303).  Used at argument-position checks so a concrete type that conforms
// to an interface can be passed where the interface is expected
// (`invoiceTotal(feed: PriceFeed, …)` called with a `TrackedFeed`).
// True when `t` is the bare, non-generic `Task` extern type (the BCL
// `System.Threading.Tasks.Task` every kernel declares, or the JVM kernel's
// `Std.Task` record), not the built-in `Task[T]`.
func isBareTaskType(tbl: in SymbolTable, t: in Type): Bool {
  match unrefine(t) {
    case TyUser(id, _, args) -> {
      if args.count != 0 or symbolIdEq(id, builtinTaskTypeId()) {
        return false
      }
      match symTableTypeSymbolOf(tbl, id) {
        case Some(sym) -> match sym.kind {
          case DKExternType(_, decl) -> decl.clrName == "System.Threading.Tasks.Task"
          case DKRecord(_, _) -> sym.name == "Task" and sym.originPackage == "Std.Task"
          case _ -> false
        }
        case None -> false
      }
    }
    case _ -> false
  }
}

// docs/68 §3: a `Task[R]` handle satisfies the bare `Task` extern (every
// `Task<R>` is a `Task`), and the bare `Task` satisfies `Task[Unit]` (the bare
// name stands for `Task[Unit]`, as `Std.Task.delay`'s result does).
func taskHandleAssignable(tbl: in SymbolTable, expected: in Type, actual: in Type): Bool {
  match taskResultType(actual) {
    case Some(_) -> isBareTaskType(tbl, expected)
    case None -> match taskResultType(expected) {
      case Some(r) -> isBareTaskType(tbl, actual) and typeEquiv(r, TyPrim(pt = PtUnit))
      case None -> false
    }
  }
}

// `NativePtr[Byte]` is C's `void *`: it converts to any other `NativePtr[T]` (the null
// pointer, a pointer a C library hands back untyped), and a `NativePtr[Record]` converts
// to it.  A pointer to a primitive or to another pointer does not convert to
// `NativePtr[Byte]`, so a mistyped buffer pointer is still rejected.
func pointeeIsUserType(tbl: in SymbolTable, targs: in List[Type]): Bool {
  match unrefine(targs[0]) {
    case TyUser(tid, _, _) -> {
      var intrinsic = false
      for k in ["NativePtr", "NativeUserdata", "NativeWeak"] {
        match mapGet(tbl.nativeIntrinsicTypes, k) {
          case Some(id) -> if symbolIdEq(tid, id) { intrinsic = true }
          case None -> ()
        }
      }
      not intrinsic
    }
    case _ -> false
  }
}

func nativeVoidPtrConvertible(tbl: in SymbolTable, paramTy: in Type, argTy: in Type): Bool {
  match mapGet(tbl.nativeIntrinsicTypes, "NativePtr") {
    case None -> false
    case Some(ptrId) -> match unrefine(paramTy) {
      case TyUser(pid, _, pargs) -> match unrefine(argTy) {
        case TyUser(aid, _, aargs) -> {
          if symbolIdEq(pid, ptrId) and symbolIdEq(aid, ptrId) and pargs.count == 1 and aargs.count == 1 {
            (isNativeBytePtrType(tbl, paramTy) and pointeeIsUserType(tbl, aargs)) or isNativeBytePtrType(tbl, argTy)
          } else {
            false
          }
        }
        case _ -> false
      }
      case _ -> false
    }
  }
}

func argSatisfiesParam(tbl: in SymbolTable, paramTy: in Type, argTy: in Type): Bool {
  if typeEquiv(paramTy, argTy) {
    return true
  }
  // A parameter `array[N, T]` whose length is a value generic parameter
  // takes an array of any length; the call binds `N` (D167 item 6).
  match unrefine(paramTy) {
    case TyArray(None, pe, _) -> match unrefine(argTy) {
      case TyArray(_, ae, _) -> return argSatisfiesParam(tbl, pe, ae)
      case _ -> ()
    }
    case _ -> ()
  }
  if taskHandleAssignable(tbl, paramTy, argTy) {
    return true
  }
  if nativeVoidPtrConvertible(tbl, paramTy, argTy) {
    return true
  }
  // M6: numeric widening — Int satisfies Long, Float satisfies Double, etc.
  // widenArithmetic(param, arg) returns Some(param) iff arg can widen to param.
  match widenArithmetic(paramTy, argTy) {
    case Some(wt) -> if typeEquiv(wt, paramTy) { return true }
    case None -> {
    }
  }
  // #7545: `slice[T]` and `List[T]` are distinct types with distinct runtime
  // representations on every backend (a real array vs `List<T>`/`ArrayList`;
  // docs/01 §2.7 documents the conversion as the explicit `.toList()` /
  // `.toArray()` pair, never implicit), so a genuine `slice[T]`-typed VALUE
  // no longer satisfies a `List[T]` parameter/field/binding here.
  //
  // The one narrow exception is the empty-list-literal sentinel
  // `TySlice(TyError)` — the type `inferExprCore`'s `EList` arm gives `[]`
  // when it has no surrounding expected type to consult (no element to
  // infer a concrete element type from). Both backends' `EList` literal
  // codegen build the representation the CONTEXT calls for regardless of
  // this placeholder type (MSIL's `collExpectTop`/`MConcreteList`, the JVM's
  // ArrayList-by-default path), so accepting it here is representation-safe
  // — unlike a concrete-element slice, which could only reach this arm as a
  // real value, never as a literal (a non-empty `[...]` literal assigned
  // directly to a `List[T]`-expected binding is typed as `List[T]` up front
  // by `inferExprExpected`'s own `EList` arm, so it never reaches this
  // fallback either).
  //
  // #7702: the parameter must be the stdlib `List` by SymbolId
  // (`isStdCollectionsHostType`), not any type named `List`, for the same
  // reason as #7696's literal arms: codegen builds the genuine stdlib
  // collection for `[]`, so a package's own `record List[T]` must not
  // accept it.
  match argTy {
    case TySlice(elemTy) -> match unrefine(elemTy) {
      case TyError -> match unrefine(paramTy) {
        case TyUser(pid, _, pArgs) -> {
          val isStdList = isStdCollectionsHostType(tbl, pid, "List")
          if isStdList and pArgs.count == 1 {
            return true
          }
        }
        case _ -> {
        }
      }
      case _ -> {
      }
    }
    case _ -> {
    }
  }
  // A function argument returning `Never` (bottom) satisfies a function
  // parameter with any return type: the body diverges, so the "missing"
  // return value is unobservable — e.g. `{ -> panic("x") }` typed as
  // `() -> Never` passed to `assertPanics(label, fn: in () -> Unit)`.
  // Parameter lists must still match positionally (typeEquiv keeps the
  // call ABI sound).
  //
  // A lambda can also satisfy a delegate-typed extern parameter (e.g.,
  // System.Func<T,R>, System.Action<T>), enabling FFI delegate
  // instantiation (#1877, docs/50).  Non-delegate extern types reject
  // lambdas to prevent type-safety regressions (#3889).  Phase 2 (docs/42)
  // will add metadata-based detection for Predicate, Comparison, and custom
  // delegate types.
  match unrefine(paramTy) {
    case TyUser(uid, _, _) -> {
      if symTableIsExternDelegateType(tbl, uid) {
        match unrefine(argTy) {
          case TyFunction(_, _, _) -> return true
          case _ -> ()
        }
      }
    }
    case _ -> {
    }
  }
  match unrefine(argTy) {
    case TyFunction(aps, ar, _) -> {
      match unrefine(paramTy) {
        case TyFunction(pps, _, _) -> {
          if aps.count == pps.count and isNeverType(ar) {
            var fi = 0
            var allOk = true
            while fi < aps.count {
              if not typeEquiv(pps[fi], aps[fi]) {
                allOk = false
              }
              fi = fi + 1
            }
            if allOk {
              return true
            }
          }
        }
        case _ -> {
        }
      }
    }
    case _ -> {
    }
  }
  match typeIdOfType(paramTy) {
    case Some(ifaceId) -> match typeIdOfType(argTy) {
      case Some(argId) -> symTableTypeImplements(tbl, argId, ifaceId)
      case None -> false
    }
    case None -> false
  }
}

// True when a value of type `actual` may be used where `expected` is
// required.  Three cases, in order:
//   1. `typeEquiv` — exact match, or either side a wildcard (TyError/TyVar).
//   2. Interface subsumption — `expected` is an interface `I` and `actual`
//      is a concrete type `T` with a registered `impl I for T` (keyed by
//      `SymbolId`, so a same-named interface from another package never
//      matches).
//   3. Same nominal generic head with covariantly-assignable type
//      arguments — so `Result[NC, E]` satisfies `Result[Conn, E]` when
//      `NC` implements `Conn`.
// Unlike `typeEquiv`, this is directional (assignability, not equivalence)
// and recurses through generic type arguments.  Used at return /
// trailing-expression checks so a concrete record can be returned where
// the function's declared interface (or a generic over it) is expected —
// e.g. lyric-db `connect(): Result[DbConnection, DbError]` whose body
// yields `Ok(NativeConnection(...))` (#2514).
pub func typeAssignable(tbl: in SymbolTable, expected: in Type, actual: in Type): Bool {
  if typeEquiv(expected, actual) {
    return true
  }
  if taskHandleAssignable(tbl, expected, actual) {
    return true
  }
  match unrefine(expected) {
    // Assumes covariance in all type args; revisit if invariant/contravariant parameters are added.
    case TyUser(eid, _, eargs) -> match unrefine(actual) {
      case TyUser(aid, _, aargs) -> {
        if symbolIdEq(eid, aid) {
          if eargs.count != aargs.count {
            return false
          }
          var differs = false
          var i = 0
          while i < eargs.count {
            if not typeEquiv(eargs[i], aargs[i]) {
              if not typeAssignable(tbl, eargs[i], aargs[i]) {
                return false
              }
              differs = true
            }
            i = i + 1
          }
          // Only a type a value can be converted to the other instantiation
          // of is covariant (D211).
          if differs and covariantHeadKind(tbl, eid) == 0 {
            return false
          }
          return true
        }
        symTableTypeImplements(tbl, aid, eid)
      }
      case _ -> false
    }
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Covariant generic values (#7774, D211).
// ─────────────────────────────────────────────────────────────────────────────
// A value of `Result[English, E]` may be used where a `Result[Greeter, E]` is
// declared when `English` implements `Greeter`: the type arguments are
// covariant (`typeAssignable`).  On a target whose instantiations are
// distinct runtime types (dotnet, native) the two are different types with
// no common case class, so the value is converted into the declared
// instantiation where it flows into the place: `noteCovariantFlow` records
// the site and synthesizes the conversion function (`covariantHelperName`),
// which `Lyric.Pipeline` applies for such a target.  Only a union, a record
// without `var` fields (a value, with no identity to keep) and the stdlib
// `List` can be converted; a generic of any other kind stays invariant.
// 1 for a union, 2 for a record that can be rebuilt, 3 for the stdlib `List`,
// 0 for a type that cannot be converted.
func covariantHeadKind(tbl: in SymbolTable, tid: in SymbolId): Int {
  if isStdCollectionsHostType(tbl, tid, "List") {
    return 3
  }
  match symTableTypeSymbolOf(tbl, tid) {
    case Some(sym) -> match sym.kind {
      case DKUnion(_, _) -> 1
      case DKRecord(_, rd) -> if rd.isForeign or recordDeclHasVarField(rd) { 0 } else { 2 }
      case _ -> 0
    }
    case None -> 0
  }
}

func recordDeclHasVarField(rd: in RecordDecl): Bool {
  for m in rd.members {
    match m {
      case RMField(fd) -> if fd.isMutable { return true }
      case _ -> ()
    }
  }
  false
}

// True when `actual` and `expected` are one generic type over type arguments
// that differ: the value must be converted to flow into the place.  An
// interface-typed place taking a concrete type (`Greeter` from `English`) is
// not a conversion: the object is the same.
func covariantConversionNeeded(tbl: in SymbolTable, expected: in Type, actual: in Type): Bool {
  if typeEquiv(expected, actual) {
    return false
  }
  match unrefine(expected) {
    case TyUser(eid, _, eargs) -> match unrefine(actual) {
      case TyUser(aid, _, aargs) -> {
        if not symbolIdEq(eid, aid) or eargs.count != aargs.count or eargs.count == 0 {
          return false
        }
        var i = 0
        while i < eargs.count {
          if not typeEquiv(eargs[i], aargs[i]) {
            return true
          }
          i = i + 1
        }
        false
      }
      case _ -> false
    }
    case _ -> false
  }
}

// The types of the fields of the converted value under `args`, per
// constructor (a union case, or the record's one): the constructor's name,
// then each field's name ("" for a positional field) and type.
record CovCtor {
  name: String
  fieldNames: List[String]
  fieldTypes: List[Type]
}

func covariantCtors(tbl: in SymbolTable, tid: in SymbolId, args: in List[Type]): List[CovCtor] {
  val acc: List[CovCtor] = newList()
  match symTableTypeSymbolOf(tbl, tid) {
    case Some(sym) -> match sym.kind {
      case DKUnion(_, decl) -> {
        val gnames = unionDeclGenericNames(decl)
        val scratch: List[Diagnostic] = newList()
        for uc in decl.cases {
          val raw = unionCaseFieldTypes(tbl, scratch, uc, gnames, sym.originPackage)
          val names: List[String] = newList()
          val tys: List[Type] = newList()
          var i = 0
          while i < uc.fields.count {
            val fname: String = match uc.fields[i] { case UFNamed(nm, _, _) -> nm; case UFPos(_, _) -> "" }
            names.add(fname)
            val fty: Type = if i < raw.count { substituteTyVars(raw[i], gnames, args) } else { TyError }
            tys.add(fty)
            i = i + 1
          }
          acc.add(CovCtor(name = uc.name, fieldNames = names, fieldTypes = tys))
        }
      }
      case DKRecord(_, rd) -> {
        val gnames = recordDeclGenericNames(rd)
        val entries: List[FieldEntry] = newList()
        extractRecordFields(tbl, rd, entries)
        val names: List[String] = newList()
        val tys: List[Type] = newList()
        for fe in entries {
          names.add(fe.name)
          tys.add(substituteTyVars(fe.ty, gnames, args))
        }
        acc.add(CovCtor(name = rd.name, fieldNames = names, fieldTypes = tys))
      }
      case _ -> ()
    }
    case None -> ()
  }
  acc
}

// Whether `src` can be converted to `dst` by a synthesized function, every
// nested conversion included.  `visiting` holds the pairs under way, so a
// recursive type (`Tree[T]` holding `Tree[T]`) is taken as supported where it
// recurs.
func covariantSupported(tbl: in SymbolTable, src: in Type, dst: in Type, visiting: in Map[String, Bool]): Bool {
  val key = renderType(src) + " => " + renderType(dst)
  if visiting.containsKey(key) {
    return true
  }
  visiting.add(key, true)
  val s = unrefine(src)
  val d = unrefine(dst)
  match d {
    case TyUser(did, _, dargs) -> match s {
      case TyUser(sid, _, sargs) -> {
        if not symbolIdEq(did, sid) or dargs.count != sargs.count {
          return false
        }
        val kind = covariantHeadKind(tbl, did)
        if kind == 0 {
          return false
        }
        val sp = noSourceSpan()
        match typeExprForRef(tbl, s, sp) {
          case None -> return false
          case Some(_) -> ()
        }
        match typeExprForRef(tbl, d, sp) {
          case None -> return false
          case Some(_) -> ()
        }
        if kind == 3 {
          return covariantSlotSupported(tbl, sargs[0], dargs[0], visiting)
        }
        val sctors = covariantCtors(tbl, sid, sargs)
        val dctors = covariantCtors(tbl, did, dargs)
        if sctors.count != dctors.count or sctors.count == 0 {
          return false
        }
        var ci = 0
        while ci < sctors.count {
          var fi = 0
          while fi < sctors[ci].fieldTypes.count {
            if not covariantSlotSupported(tbl, sctors[ci].fieldTypes[fi], dctors[ci].fieldTypes[fi], visiting) {
              return false
            }
            fi = fi + 1
          }
          ci = ci + 1
        }
        true
      }
      case _ -> false
    }
    case _ -> false
  }
}

// A field or element of type `src` flowing into one of type `dst`: nothing to
// do when they are the same type or the place is an interface; else a nested
// conversion.
func covariantSlotSupported(tbl: in SymbolTable, src: in Type, dst: in Type, visiting: in Map[String, Bool]): Bool {
  if not covariantConversionNeeded(tbl, dst, src) {
    return true
  }
  covariantSupported(tbl, src, dst, visiting)
}

// `covariantAssignable` also holds: the types differ in a generic argument
// and `typeAssignable`'s covariance accepts the flow.
func covariantAssignable(tbl: in SymbolTable, expected: in Type, actual: in Type): Bool {
  covariantConversionNeeded(tbl, expected, actual) and typeAssignable(tbl, expected, actual)
}

// A value `e` of type `actual` flowing into a place of type `expected`
// through covariance: true after recording the site, so the target applies
// the conversion.  A flow between types mentioning a type parameter or an
// error is accepted unrecorded (its instantiation is not known here).  False
// when the flow is not covariant or no conversion can be synthesized, so the
// caller reports the mismatch.
func covariantFlow(tbl: in SymbolTable, expected: in Type, actual: in Type, e: in Expr): Bool {
  if not covariantAssignable(tbl, expected, actual) {
    return false
  }
  if isNoSourceSpan(e.span) {
    return true
  }
  if not typeIsClosed(expected) or not typeIsClosed(actual) {
    // A type parameter's instantiation is not known here; a slot nothing has
    // fixed (`Ok(…)` whose error type is open) is built at an instantiation
    // the conversion cannot name, so a covariant flow of one is not accepted
    // (#7752).
    return not typeHasOpenSlot(expected) and not typeHasOpenSlot(actual)
  }
  val visiting: Map[String, Bool] = newMap()
  if not covariantSupported(tbl, actual, expected, visiting) {
    return false
  }
  match covariantHelperName(tbl, actual, expected) {
    case Some(name) -> {
      val key = recordCopySiteKey(e.span)
      if tbl.covariantSites.containsKey(key) {
        tbl.covariantSites.remove(key)
      }
      tbl.covariantSites.add(key, name)
      true
    }
    case None -> false
  }
}

// True when `t` mentions a slot nothing has fixed (`TyError`) anywhere.
func typeHasOpenSlot(t: in Type): Bool {
  match t {
    case TyError -> true
    case TyUser(_, _, args) -> {
      for a in args {
        if typeHasOpenSlot(a) {
          return true
        }
      }
      false
    }
    case TySlice(e) -> typeHasOpenSlot(e)
    case TyArray(_, e, _) -> typeHasOpenSlot(e)
    case TyNullable(inner) -> typeHasOpenSlot(inner)
    case TyTuple(elems) -> {
      for a in elems {
        if typeHasOpenSlot(a) {
          return true
        }
      }
      false
    }
    case TyFunction(ps, ret, _) -> {
      for a in ps {
        if typeHasOpenSlot(a) {
          return true
        }
      }
      typeHasOpenSlot(ret)
    }
    case TyRefined(u, _, _, _, _) -> typeHasOpenSlot(u)
    case _ -> false
  }
}

// `argSatisfiesParam`, also accepting a covariant generic value, which is
// recorded for conversion.
func argFlowSatisfies(tbl: in SymbolTable, expected: in Type, actual: in Type, e: in Expr): Bool {
  argSatisfiesParam(tbl, expected, actual) or covariantFlow(tbl, expected, actual, e)
}

// The name of the synthesized function converting a `src` into a `dst`,
// creating it (and the functions it calls) on first use.
func covariantHelperName(tbl: in SymbolTable, src: in Type, dst: in Type): Option[String] {
  val key = renderType(src) + " => " + renderType(dst)
  match mapGet(tbl.covariantHelperNames, key) {
    case Some(n) -> return Some(value = n)
    case None -> ()
  }
  val name = "__lyric_cov_" + toString(tbl.covariantHelperNames.count)
  tbl.covariantHelperNames.add(key, name)
  match buildCovariantHelper(tbl, name, src, dst) {
    case Some(decl) -> {
      tbl.covariantHelpers.add(decl)
      Some(value = name)
    }
    case None -> None
  }
}

func covParam(name: in String, ty: in TypeExpr, sp: in Span): Param {
  val noAnns: List[Annotation] = newList()
  Param(mode = PMIn, modeExplicit = true, name = name, ty = ty, dflt = None, annotations = noAnns, span = sp)
}

func covPath(segs: in List[String], sp: in Span): ModulePath {
  ModulePath(segments = segs, span = sp)
}

func covNameExpr(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  mkExpr(EPath(path = covPath(segs, sp)), sp)
}

func covStmt(kind: in StatementKind, sp: in Span): Statement {
  Statement(kind = kind, span = sp)
}

// The path of a constructor `ctor` of the type `typeExpr` names: the type's
// package qualifier, if it has one, then `ctor`.
func covCtorPath(typeExpr: in TypeExpr, ctor: in String, sp: in Span): ModulePath {
  val noSegs: List[String] = newList()
  val head: ModulePath = match typeExpr.kind {
    case TRef(p) -> p
    case TGenericApp(h, _) -> h
    case _ -> covPath(noSegs, sp)
  }
  val segs: List[String] = newList()
  var i = 0
  while i < head.segments.count - 1 {
    segs.add(head.segments[i])
    i = i + 1
  }
  segs.add(ctor)
  covPath(segs, sp)
}

// The expression converting the value `v` of type `src` to `dst`: `v` itself
// when the place takes it unchanged, else a call of the nested conversion.
func covSlotExpr(tbl: in SymbolTable, v: in Expr, src: in Type, dst: in Type, sp: in Span): Expr {
  if not covariantConversionNeeded(tbl, dst, src) {
    return v
  }
  match covariantHelperName(tbl, src, dst) {
    case Some(name) -> {
      val args: List[CallArg] = newList()
      args.add(CAPositional(expr = v))
      mkExpr(ECall(fn = covNameExpr(name, sp), args = args), sp)
    }
    case None -> v
  }
}

// `val r: dst = init` then `r`: the constructed value typed at the target
// instantiation, which a backend with distinct instantiations builds at.
func covTypedValue(prefix: in List[Statement], dstTe: in TypeExpr, init: in Expr, sp: in Span): ExprOrBlock {
  val stmts: List[Statement] = newList()
  for st in prefix {
    stmts.add(st)
  }
  val pat = Pattern(kind = PBinding(name = "r", inner = None), span = sp)
  stmts.add(covStmt(SLocal(binding = LBVal(pat = pat, ty = Some(value = dstTe), init = init)), sp))
  stmts.add(covStmt(SExpr(expr = covNameExpr("r", sp)), sp))
  EOBBlock(block = Block(statements = stmts, span = sp))
}

// A field of the value being rebuilt, bound to a local of the target field's
// type before it is passed to the constructor: a backend that builds a generic
// value at the instantiation its arguments have (a record) then builds it at
// the target's, whatever the type the converted field is read as.  The
// expression that stands for the field in the construction.
func covBindField(
  tbl: in SymbolTable,
  stmts: in List[Statement],
  index: in Int,
  value: in Expr,
  dstTy: in Type,
  sp: in Span,
): Expr {
  match typeExprForRef(tbl, dstTy, sp) {
    case Some(te) -> {
      val name = "f" + toString(index)
      val pat = Pattern(kind = PBinding(name = name, inner = None), span = sp)
      stmts.add(covStmt(SLocal(binding = LBVal(pat = pat, ty = Some(value = te), init = value)), sp))
      covNameExpr(name, sp)
    }
    case None -> value
  }
}

func buildCovariantHelper(tbl: in SymbolTable, name: in String, src: in Type, dst: in Type): Option[FunctionDecl] {
  val sp = noSourceSpan()
  val s = unrefine(src)
  val d = unrefine(dst)
  val srcTe = match typeExprForRef(tbl, s, sp) { case Some(t) -> t; case None -> return None }
  val dstTe = match typeExprForRef(tbl, d, sp) { case Some(t) -> t; case None -> return None }
  val sid = match s { case TyUser(i, _, _) -> i; case _ -> return None }
  val did = match d { case TyUser(i, _, _) -> i; case _ -> return None }
  val sargs = match s { case TyUser(_, _, a) -> a; case _ -> return None }
  val dargs = match d { case TyUser(_, _, a) -> a; case _ -> return None }
  val kind = covariantHeadKind(tbl, did)
  val x = covNameExpr("x", sp)
  val stmts: List[Statement] = newList()
  if kind == 3 {
    // A new list of the converted elements.
    val outPat = Pattern(kind = PBinding(name = "out", inner = None), span = sp)
    val noCallArgs: List[CallArg] = newList()
    val newListCall = mkExpr(ECall(fn = covNameExpr("newList", sp), args = noCallArgs), sp)
    stmts.add(covStmt(SLocal(binding = LBVal(pat = outPat, ty = Some(value = dstTe), init = newListCall)), sp))
    val elemPat = Pattern(kind = PBinding(name = "e", inner = None), span = sp)
    val addArgs: List[CallArg] = newList()
    addArgs.add(CAPositional(expr = covSlotExpr(tbl, covNameExpr("e", sp), sargs[0], dargs[0], sp)))
    val addCall = mkExpr(
      ECall(fn = mkExpr(EMember(receiver = covNameExpr("out", sp), memberName = "add"), sp), args = addArgs),
      sp
    )
    val loopBody: List[Statement] = newList()
    loopBody.add(covStmt(SExpr(expr = addCall), sp))
    stmts.add(covStmt(SFor(label = None, pat = elemPat, iter = x, body = Block(statements = loopBody, span = sp)), sp))
    stmts.add(covStmt(SExpr(expr = covNameExpr("out", sp)), sp))
  } else if kind == 2 {
    // A record rebuilt with the converted fields.
    val ctors = covariantCtors(tbl, did, dargs)
    val sctors = covariantCtors(tbl, sid, sargs)
    if ctors.count != 1 or sctors.count != 1 {
      return None
    }
    val callArgs: List[CallArg] = newList()
    var fi = 0
    while fi < ctors[0].fieldNames.count {
      val fieldRead = mkExpr(EMember(receiver = covNameExpr("x", sp), memberName = ctors[0].fieldNames[fi]), sp)
      val converted = covSlotExpr(tbl, fieldRead, sctors[0].fieldTypes[fi], ctors[0].fieldTypes[fi], sp)
      callArgs.add(
        CANamed(
          name = ctors[0].fieldNames[fi],
          value = covBindField(tbl, stmts, fi, converted, ctors[0].fieldTypes[fi], sp),
          span = sp
        )
      )
      fi = fi + 1
    }
    val ctorCall = mkExpr(
      ECall(fn = mkExpr(EPath(path = covCtorPath(dstTe, ctors[0].name, sp)), sp), args = callArgs),
      sp
    )
    for st in covTypedBlockStmts(dstTe, ctorCall, sp) {
      stmts.add(st)
    }
  } else if kind == 1 {
    // A match over the cases, each rebuilt at the target instantiation.
    val dctors = covariantCtors(tbl, did, dargs)
    val sctors = covariantCtors(tbl, sid, sargs)
    if dctors.count != sctors.count or dctors.count == 0 {
      return None
    }
    val arms: List[MatchArm] = newList()
    var ci = 0
    while ci < dctors.count {
      val dc = dctors[ci]
      val sc0 = sctors[ci]
      val casePath = covCtorPath(dstTe, dc.name, sp)
      val patArgs: List[Pattern] = newList()
      val callArgs: List[CallArg] = newList()
      val armStmts: List[Statement] = newList()
      var fi = 0
      while fi < dc.fieldNames.count {
        val vn = "v" + toString(fi)
        patArgs.add(Pattern(kind = PBinding(name = vn, inner = None), span = sp))
        val converted0 = covSlotExpr(tbl, covNameExpr(vn, sp), sc0.fieldTypes[fi], dc.fieldTypes[fi], sp)
        val converted = covBindField(tbl, armStmts, fi, converted0, dc.fieldTypes[fi], sp)
        if dc.fieldNames[fi].length > 0 {
          callArgs.add(CANamed(name = dc.fieldNames[fi], value = converted, span = sp))
        } else {
          callArgs.add(CAPositional(expr = converted))
        }
        fi = fi + 1
      }
      val pat: Pattern = if dc.fieldNames.count == 0 and casePath.segments.count == 1 {
        Pattern(kind = PBinding(name = dc.name, inner = None), span = sp)
      } else {
        Pattern(kind = PConstructor(head = casePath, args = patArgs), span = sp)
      }
      val built: Expr = if dc.fieldNames.count == 0 {
        mkExpr(EPath(path = casePath), sp)
      } else {
        mkExpr(ECall(fn = mkExpr(EPath(path = casePath), sp), args = callArgs), sp)
      }
      arms.add(MatchArm(pattern = pat, guard = None, body = covTypedValue(armStmts, dstTe, built, sp), span = sp))
      ci = ci + 1
    }
    stmts.add(covStmt(SExpr(expr = mkExpr(EMatch(scrutinee = x, arms = arms), sp)), sp))
  } else {
    return None
  }
  val params: List[Param] = newList()
  params.add(covParam("x", srcTe, sp))
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val noContracts: List[ContractClause] = newList()
  Some(
    value = FunctionDecl(
      docComments = noDocs,
      annotations = noAnns,
      visibility = None,
      isAsync = false,
      name = name,
      generics = None,
      params = params,
      ret = Some(value = dstTe),
      whereClause = None,
      contracts = noContracts,
      body = Some(value = FBBlock(block = Block(statements = stmts, span = sp))),
      span = sp
    )
  )
}

func covTypedBlockStmts(dstTe: in TypeExpr, init: in Expr, sp: in Span): List[Statement] {
  val stmts: List[Statement] = newList()
  val pat = Pattern(kind = PBinding(name = "r", inner = None), span = sp)
  stmts.add(covStmt(SLocal(binding = LBVal(pat = pat, ty = Some(value = dstTe), init = init)), sp))
  stmts.add(covStmt(SExpr(expr = covNameExpr("r", sp)), sp))
  stmts
}

// `typeAssignable`, recording the conversion of `e` when the flow is
// covariant; false when it is covariant but cannot be converted.
func typeAssignableByFlow(tbl: in SymbolTable, expected: in Type, actual: in Type, e: in Expr): Bool {
  if not typeAssignable(tbl, expected, actual) {
    return false
  }
  if covariantConversionNeeded(tbl, expected, actual) {
    return covariantFlow(tbl, expected, actual, e)
  }
  true
}

// The trailing expression of `blk`, or an error expression with no source
// span (which records no conversion) when it ends in another statement.
func blockValueExprOr(blk: in Block): Expr {
  match blockValueExpr(blk) {
    case Some(e) -> e
    case None -> Expr(kind = EError, span = noSourceSpan())
  }
}

// True when `qualifier` (the dotted prefix of a qualified call) names
// package `pkg`: the full path, or its trailing segment(s) as an
// `import A.B` in scope allows (`B.f(...)`).
func pkgMatchesQualifier(pkg: in String, qualifier: in String): Bool {
  pkg.length > 0 and (pkg == qualifier or pkg.endsWith("." + qualifier))
}

// #7799: `origin` is a package the qualifier's package re-exports (`pub use`,
// directly or through its re-exports): `Std.Collections` re-exports
// `Std.CollectionsHost`, where `newList` is declared, so the qualified
// spelling `Coll.newList()` through it or an alias of it finds the function
// the bare `newList()` does.  A package it only imports is not reached
// (docs/70 §4.3, D311).
func pkgReexportsFrom(tbl: in SymbolTable, qualifier: in String, origin: in String): Bool {
  origin.length > 0 and symTableReexportClosure(tbl, qualifier).contains(origin)
}

// Every function named `name` that a call writing `args` fits, from every
// package: the non-generic ones first, then the generic ones.  A qualified call picks
// among them by package.  The indexed `arityKey@i` slots hold non-generic
// signatures only (a generic's type variables match any argument, so there
// it would shadow a concrete overload), which left a generic function of the
// named package unreachable and bound `Pkg.f(...)` to another package's
// same-named function.
func qualifiedCallCandidates(
  sigs: in Map[String, ResolvedSignature], name: in String, args: in List[CallArg]
): List[ResolvedSignature] {
  val all = gatherOverloadCandidates(sigs, byNameSigKey(name))
  val acc: List[ResolvedSignature] = newList()
  for c in all {
    if sigDefaultsFilled(c, args) >= 0 and c.generics.count == 0 {
      acc.add(c)
    }
  }
  for c in all {
    if sigDefaultsFilled(c, args) >= 0 and c.generics.count > 0 {
      acc.add(c)
    }
  }
  acc
}

// Whether `Pkg.T.m`, the receiver `segs` of a call of `m` with `arity`
// arguments, names an extension `T.m` that package `Pkg` declares for a type
// `T` it does not declare itself (#8219).  `Pkg.T` names no value or type
// then; where `Pkg` declares `T`, the receiver resolves as that type.
func isPackageDottedCallee(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  segs: in List[String],
  member: in String,
  arity: in Int,
): Bool {
  if segs.count < 2 or not startsUppercase(segs[segs.count - 1]) or scopeHasName(sc, segs[0]) {
    return false
  }
  val pkgSegs: List[String] = newList()
  var i = 0
  while i < segs.count - 1 {
    pkgSegs.add(segs[i])
    i = i + 1
  }
  match symTableTryFindInPackage(tbl, modulePathJoin(pkgSegs), segs[segs.count - 1]) {
    case Some(_) -> return false
    case None -> ()
  }
  val full: List[String] = newList()
  for sg in segs {
    full.add(sg)
  }
  full.add(member)
  match packageDottedSig(tbl, sigs, full, arity) {
    case Some(_) -> true
    case None -> false
  }
}

// The function a call `Pkg.T.m(x, args)` binds: the method `m` in the body
// of `T` (D181) when `Pkg` declares `T` and no dot-named `T.m`, and the
// method takes the arguments; else the dot-named function `T.m` that `Pkg`
// declares.
func qualifiedTypeDotSig(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  segs: in List[String],
  arity: in Int,
  argTypes: in List[Type],
): Option[ResolvedSignature] {
  val typeSegs: List[String] = newList()
  var i = 0
  while i < segs.count - 1 {
    typeSegs.add(segs[i])
    i = i + 1
  }
  val noArgs: List[CallArg] = newList()
  match bodyMethodViaType(tbl, sigs, typeSegs, segs[segs.count - 1], noArgs, argTypes) {
    case Some(m) -> return Some(value = withReceiverParam(m, argTypes[0]))
    case None -> ()
  }
  packageDottedSig(tbl, sigs, segs, arity)
}

// The dot-named function `T.m` declared by the package the leading
// segments of `Pkg.T.m` name, one taking `arity` arguments first.
func packageDottedSig(
  tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], segs: in List[String], arity: in Int
): Option[ResolvedSignature] {
  val n = segs.count
  val dotted = canonicalOwnerName(tbl, segs[n - 2]) + "." + segs[n - 1]
  val pkgSegs: List[String] = newList()
  var i = 0
  while i < n - 2 {
    pkgSegs.add(segs[i])
    i = i + 1
  }
  val pkg = modulePathJoin(pkgSegs)
  var other: Option[ResolvedSignature] = None
  var fewest: Option[ResolvedSignature] = None
  for c in gatherOverloadCandidates(sigs, byNameSigKey(dotted)) {
    if sigPackage(tbl, c) == pkg {
      if arity <= c.params.count and arity >= minRequiredParams(c) {
        match fewest {
          case Some(f) -> if c.params.count < f.params.count { fewest = Some(value = c) }
          case None -> {
            fewest = Some(value = c)
          }
        }
      }
      match other {
        case None -> {
          other = Some(value = c)
        }
        case Some(_) -> ()
      }
    }
  }
  // The function taking the arguments' count that leaves the fewest
  // parameters to their defaults answers (#8355).  None taking it: the call
  // still names that package's function, against which the count is
  // reported (T0042), never another function of the type's (#8097).
  match fewest {
    case Some(_) -> fewest
    case None -> other
  }
}

// The function a call `T.m(x, args)` through its type binds when the first
// argument is a `T` (D181, #8219): the method in the type's body when it
// applies and the type's package declares no dot-named `T.m` (one it does
// declare names the call, #8097), then the dot-named functions
// `dotNamedCandidatesFor` keeps, an applicable one first; otherwise the one
// registered for that name and arity.
func typeQualifiedDotSig(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  typeName: in String,
  member: in String,
  arity: in Int,
  argTypes: in List[Type],
): Option[ResolvedSignature] {
  val owner = canonicalOwnerName(tbl, typeName)
  if arity >= 1 and argTypes.count >= 1 and dotNamedOwnerName(argTypes[0]) == owner {
    val recv = argTypes[0]
    val noArgs: List[CallArg] = newList()
    val rest = tailTypes(argTypes)
    // A dot-named function of the type's package answers a call through
    // the type, the method in the type's body only when there is none
    // (#8097).
    if not ownDotNamedDeclared(tbl, sigs, recv, member) {
      match applicableBodyMethod(tbl, recv, member, arity - 1, noArgs, rest) {
        case Some(m) -> return Some(value = withReceiverParam(m, recv))
        case None -> ()
      }
    }
    val cands = dotNamedCandidatesFor(tbl, sigs, recv, member, arity - 1, noArgs, rest)
    // The applicable function that leaves the fewest parameters to their
    // defaults, as a call through the receiver binds (#8355).
    var fewest: Option[ResolvedSignature] = None
    for c in cands {
      if dotNamedApplicable(tbl, c, arity - 1, noArgs, rest) {
        match fewest {
          case Some(f) -> if c.params.count < f.params.count { fewest = Some(value = c) }
          case None -> {
            fewest = Some(value = c)
          }
        }
      }
    }
    match fewest {
      case Some(_) -> return fewest
      case None -> ()
    }
    if cands.count > 0 {
      return Some(value = cands[0])
    }
    // No dot-named function and no applicable body method: the call still
    // names the type's method, so the count and types are reported against
    // its signature (T0042/T0043) rather than passing unchecked.
    match unrefine(recv) {
      case TyUser(tid, _, targs) -> {
        val ms = symTableMethodSigs(tbl, tid, member)
        if ms.count > 0 {
          return Some(value = withReceiverParam(substituteMethodSig(ms[0], unrefine(recv), targs), recv))
        }
      }
      case _ -> ()
    }
  }
  dottedSigLookup(sigs, owner + "." + member, arity)
}

// The applicable method named `name` in the body of the receiver's type,
// receiver dropped, or `None`.
func applicableBodyMethod(
  tbl: in SymbolTable,
  recv: in Type,
  name: in String,
  argc: in Int,
  args: in List[CallArg],
  argTypes: in List[Type],
): Option[ResolvedSignature] {
  match unrefine(recv) {
    case TyUser(tid, _, targs) -> {
      for e in symTableMethodSigs(tbl, tid, name) {
        val m = substituteMethodSig(e, unrefine(recv), targs)
        if argc >= minRequiredParams(m) and argc <= m.params.count and suppliedArgsMatch(tbl, m.params, argTypesInSigOrder(m, 0, args, argTypes)) {
          return Some(value = m)
        }
      }
      None
    }
    case _ -> None
  }
}

// A receiver-dropped method signature with its receiver, of type `recv`,
// put back as the first parameter.
func withReceiverParam(m: in ResolvedSignature, recv: in Type): ResolvedSignature {
  val ps: List[ResolvedParam] = newList()
  ps.add(ResolvedParam(name = "self", ty = recv, mode = PMIn, hasDefault = false, span = m.span))
  for p in m.params {
    ps.add(p)
  }
  m.copy(params = ps)
}

// The method in the body of `x`'s type (receiver dropped) that a call
// `T.m(x, args)` or `Pkg.T.m(x, args)` through the type binds (D181): `T`
// names `x`'s type, directly or through an alias, `Pkg` the package that
// declares it, the method takes the other arguments, and that package
// declares no dot-named `T.m`.  `None` for any other call.
func bodyMethodCalleeBinding(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
): Option[ResolvedSignature] {
  val segs: List[String] = newList()
  if not calleeSegments(fn, segs) or segs.count < 2 or not receiverWrittenFirst(args) or argTypes.count == 0 {
    return None
  }
  val typeSegs: List[String] = newList()
  var i = 0
  while i < segs.count - 1 {
    typeSegs.add(segs[i])
    i = i + 1
  }
  bodyMethodViaType(tbl, sigs, typeSegs, segs[segs.count - 1], tailArgs(args), argTypes)
}

// The method `member` in the body of the type `typeSegs` names (`T`, or
// `Pkg.T` with `Pkg` the package declaring it) that takes the arguments
// after the first, whose type must be that type; `None` otherwise, and when
// the type's own package declares a dot-named `T.m`, which a call through
// the type names instead (D181, #8097).
func bodyMethodViaType(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  typeSegs: in List[String],
  member: in String,
  restArgs: in List[CallArg],
  argTypes: in List[Type],
): Option[ResolvedSignature] {
  if typeSegs.count == 0 or argTypes.count == 0 {
    return None
  }
  val recv = argTypes[0]
  val owner = dotNamedOwnerName(recv)
  if owner.length == 0 or canonicalOwnerName(tbl, typeSegs[typeSegs.count - 1]) != owner {
    return None
  }
  if typeSegs.count > 1 {
    val pkgSegs: List[String] = newList()
    var i = 0
    while i < typeSegs.count - 1 {
      pkgSegs.add(typeSegs[i])
      i = i + 1
    }
    match dotNamedDeclaringPackage(tbl, recv) {
      case Some(p) -> if p != modulePathJoin(pkgSegs) { return None }
      case None -> return None
    }
  }
  if ownDotNamedDeclared(tbl, sigs, recv, member) {
    return None
  }
  applicableBodyMethod(tbl, recv, member, argTypes.count - 1, restArgs, tailTypes(argTypes))
}

// Whether the package declaring `recv`'s type `T` also declares a dot-named
// function `T.member`, of any arity.  A call through the type then names
// that function, never the method in the type's body (#8097).
func ownDotNamedDeclared(
  tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], recv: in Type, member: in String
): Bool {
  val ownPkg = match dotNamedDeclaringPackage(tbl, recv) { case Some(p) -> p; case None -> return false }
  for c in dotNamedSigsAnyArity(sigs, dotNamedOwnerName(recv) + "." + member) {
    if sigPackage(tbl, c) == ownPkg {
      return true
    }
  }
  false
}

// The name a dot-named function's owner `name` is registered under: the
// aliased type's when `name` is a type alias of a named type (`Int` for
// `alias Num = Int`, through chains), `name` itself otherwise (#8217).
func canonicalOwnerName(tbl: in SymbolTable, name: in String): String {
  var isAlias = false
  for sym in symTableTryFindAll(tbl, name) {
    match sym.kind {
      case DKTypeAlias(_) -> {
        isAlias = true
      }
      case _ -> ()
    }
  }
  if not isAlias {
    return name
  }
  val segs: List[String] = newList()
  segs.add(name)
  val scratch: List[Diagnostic] = newList()
  val sp = noSourceSpan()
  match unrefine(resolveType(tbl, newGenericContext(), scratch, TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = sp)), span = sp))) {
    case TyUser(_, n, targs) -> if targs.count == 0 { n } else { name }
    case TyPrim(pt) -> primName(pt)
    case _ -> name
  }
}

// `T.m` for a callee written `T.m` or `Pkg.T.m`, `T` resolved through an
// alias (`canonicalOwnerName`); "" when it is neither.
func canonicalDottedName(tbl: in SymbolTable, fn: in Expr): String {
  val segs: List[String] = newList()
  if not calleeSegments(fn, segs) or segs.count < 2 {
    return ""
  }
  canonicalOwnerName(tbl, segs[segs.count - 2]) + "." + segs[segs.count - 1]
}

// Whether `sig`, bound by a call through the type, is another package's
// function that a same-named dot-named function of a different package
// (this one among them) would capture if the backends looked it up by its
// name `T.m` alone.
func foreignDotNamedShadowed(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  recv: in Type,
  member: in String,
  sig: in ResolvedSignature,
): Bool {
  val pkg = sigPackage(tbl, sig)
  if pkg == symTableScopePkg(tbl) {
    return false
  }
  for c in dotNamedSigsAnyArity(sigs, dotNamedOwnerName(recv) + "." + member) {
    if sigPackage(tbl, c) != pkg {
      return true
    }
  }
  false
}

func tailArgs(args: in List[CallArg]): List[CallArg] {
  val acc: List[CallArg] = newList()
  var i = 1
  while i < args.count {
    acc.add(args[i])
    i = i + 1
  }
  acc
}

func tailTypes(ts: in List[Type]): List[Type] {
  val acc: List[Type] = newList()
  var i = 1
  while i < ts.count {
    acc.add(ts[i])
    i = i + 1
  }
  acc
}

func receiverWrittenFirst(args: in List[CallArg]): Bool {
  args.count > 0 and (match args[0] { case CAPositional(_) -> true; case CANamed(_, _, _) -> false })
}

// `m` for a callee written `T.m` or `Pkg.T.m`; "" otherwise.
func memberOfDotted(fn: in Expr): String {
  val segs: List[String] = newList()
  if not calleeSegments(fn, segs) or segs.count < 2 {
    return ""
  }
  segs[segs.count - 1]
}

// T0200 for a call that fills defaults and binds several declarations
// equally well (`pickByShape`), once per call.
func reportAmbiguousDefaultCall(
  diag: in List[Diagnostic], fn: in Expr, tied: in List[ResolvedSignature], span: in Span
): Unit {
  if tied.count < 2 {
    return
  }
  for d in diag {
    if d.code == "T0200" and d.span.startPos.fileId == span.startPos.fileId and d.span.startPos.offset == span.startPos.offset {
      return
    }
  }
  val pkgs: List[String] = newList()
  for t in tied {
    val pn = if t.originPackage.length > 0 { t.originPackage } else { "this package" }
    var seen = false
    for q in pkgs {
      if q == pn {
        seen = true
      }
    }
    if not seen {
      pkgs.add(pn)
    }
  }
  val segs: List[String] = newList()
  val callee = if calleeSegments(fn, segs) { modulePathJoin(segs) } else { "this function" }
  diag.add(
    errorDiagnostic(
      "T0200",
      "this call to '" + callee + "' is ambiguous: it fits " + toString(tied.count) + " declarations of '" + callee +
        "' (in " +
        joinPackageNames(pkgs) +
        ") that leave the same number of parameters to their defaults; name an argument only one of them " +
        "declares, or supply the parameters of the one you mean",
      span
    )
  )
}

// T0219 for a bare callee `fn` (`f(...)`) bound to a function of `origin`
// that its file sees only through a sibling file's import (docs/70 §4.1).
func noteBareCalleeFunc(tbl: in SymbolTable, fn: in Expr, origin: in String): Unit {
  match fn.kind {
    case EPath(path) -> if path.segments.count == 1 { symTableNoteBareFuncUse(tbl, origin, path.segments[0], fn.span) }
    case _ -> ()
  }
}

// `noteBareCalleeFunc` for a bare constructor or case callee bound to `sym`.
func noteBareCalleeSym(tbl: in SymbolTable, fn: in Expr, sym: in Symbol): Unit {
  match fn.kind {
    case EPath(path) -> if path.segments.count == 1 { symTableNoteBareUse(tbl, sym, fn.span) }
    case _ -> ()
  }
}

func findDirectSig(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
): Option[ResolvedSignature] {
  val ambiguous: List[ResolvedSignature] = newList()
  findDirectSigPick(sc, tbl, sigs, fn, args, argTypes, ambiguous)
}

// `findDirectSig`, adding to `ambiguous` the declarations a call that fills
// defaults binds equally well (`pickByShape`); the signature returned is then
// the first of them.
func findDirectSigPick(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  fn: in Expr,
  args: in List[CallArg],
  argTypes: in List[Type],
  ambiguous: in List[ResolvedSignature],
): Option[ResolvedSignature] {
  val arity = args.count
  match fn.kind {
    // `Box.get(b)`: a dot-named function called through its type name
    // (#8173).  The receiver names a type, not a value in scope.
    case EMember(recv, member) -> {
      // `lyric.db.Postgres.connect(...)` or `Grpc.Kernel.Jvm.netOpenChannel(...)`:
      // a member of an `extern package` block, addressed by the block's own
      // path or by the enclosing package's (#7934).
      if isExternBlockQualifier(sc, tbl, recv, member) {
        val externPkg = modulePathJoin(calleeSegmentList(recv))
        val externCands: List[ResolvedSignature] = newList()
        for qc in qualifiedCallCandidates(sigs, member, args) {
          if qc.originPackage == externPkg {
            externCands.add(qc)
          }
        }
        if externCands.count > 0 {
          return pickByShape(tbl, externCands, args, argTypes, None, ambiguous)
        }
        // No member takes this many arguments: report against the declared
        // one (T0042) rather than falling through to an unchecked call.
        for dc in gatherOverloadCandidates(sigs, byNameSigKey(member)) {
          if dc.originPackage == externPkg {
            return Some(value = dc)
          }
        }
      }
      // `Pkg.Box.get(b)`, the type named through its package (#8179), the
      // receiver a path or a chain of members (`Main.Bag` in `Main`).
      val qsegs: List[String] = newList()
      if calleeSegments(recv, qsegs) and qsegs.count >= 2 and startsUppercase(qsegs[qsegs.count - 1]) and not scopeHasName(sc, qsegs[0]) {
        qsegs.add(member)
        match qualifiedTypeDotSig(tbl, sigs, qsegs, arity, argTypes) {
          case Some(pds) -> return Some(value = pds)
          case None -> ()
        }
      }
      val typeName = match recv.kind {
        case EPath(rp) -> if rp.segments.count == 1 and startsUppercase(rp.segments[0]) {
          rp.segments[0]
        } else {
          ""
        }
        case _ -> ""
      }
      if typeName.length == 0 or scopeHasName(sc, typeName) {
        return None
      }
      typeQualifiedDotSig(tbl, sigs, typeName, member, arity, argTypes)
    }
    case EPath(path) -> {
      if path.segments.count == 0 {
        return None
      }
      val name = path.segments[path.segments.count - 1]
      // #5792: a single-segment call-position identifier that is ALSO bound as
      // a local (val/var/param) in the current scope must resolve to the
      // local — consistent with a bare (non-call) reference to the same name,
      // which already resolves via `resolveExprPath`'s scope-first lookup
      // (`match scopeTryFind(sc, name) { ... }` before it ever consults
      // `sigs`).  Returning `None` here defers to the `ECall` arm's general
      // `fnT` resolution (itself scope-first), so a non-function-typed local
      // now produces a proper T0044 "called value of non-function type"
      // diagnostic instead of silently dispatching to an unrelated same-name
      // same-package function, and a function-typed local is invoked as
      // itself rather than the shadowed top-level function.
      if path.segments.count == 1 {
        match scopeTryFind(sc, name) {
          case Some(_) -> return None
          case None -> {
          }
        }
      }
      // #8350: a module-level `val`/`const` in scope hides an imported
      // function of that name in call position too, as it does for a bare
      // reference (#8283): the call is the val's, resolved by the `ECall`
      // arm's general `fnT` path.
      if path.segments.count == 1 and bareNameIsModuleValue(tbl, name) {
        return None
      }
      val arityKey = name + "/" + toString(arity)
      // `Box.get(b)`: a dot-named function called through its type (#8173),
      // registered under its full dotted name.
      if path.segments.count == 2 {
        match typeQualifiedDotSig(tbl, sigs, path.segments[0], name, arity, argTypes) {
          case Some(ds) -> return Some(value = ds)
          case None -> ()
        }
      }
      // `Pkg.Box.get(b)`: the same through the type's package (#8179), the
      // function `Box.get` that package declares.
      if path.segments.count >= 3 {
        match qualifiedTypeDotSig(tbl, sigs, path.segments, arity, argTypes) {
          case Some(pds) -> return Some(value = pds)
          case None -> ()
        }
      }
      // Qualified call (e.g. the alias-rewritten `Std.RegexSafe.tryCompile`):
      // the leading segments name the declaring package.  Prefer the same-arity
      // candidate whose `originPackage` matches, disambiguating two same-name /
      // same-signature overloads in different packages (#1488 regex_safe — both
      // `Std.Regex.tryCompile` and `Std.RegexSafe.tryCompile` take `String` and
      // would otherwise be picked arbitrarily by argument-type matching alone).
      // No package match falls through to the bare-name resolution below, so an
      // intra-project alias whose target package didn't register a candidate
      // slot still resolves as before.
      // Multi-segment paths reaching here are expected to be alias-rewritten
      // (e.g. `Std.RegexSafe.tryCompile`); the fallthrough to bare-name
      // resolution below is a deliberate backstop for any unmatched case.
      if path.segments.count > 1 {
        val prefix: List[String] = newList()
        var pi = 0
        while pi < path.segments.count - 1 {
          prefix.add(path.segments[pi])
          pi = pi + 1
        }
        val wantPkg = modulePathJoin(prefix)
        // A qualifier names a package by its full path or, for an
        // `import A.B` in scope, by its last segment (`B.f(...)`).  Once any
        // candidate comes from the named package the call binds to that
        // package: an argument mismatch is reported against ITS signature
        // rather than silently re-resolving to another package's same-named
        // function (D-progress-946: `Widgets.field(...)` resolved to
        // `Forms.field`).
        val pkgCands: List[ResolvedSignature] = newList()
        val reexported: List[ResolvedSignature] = newList()
        for qc in qualifiedCallCandidates(sigs, name, args) {
          if pkgMatchesQualifier(qc.originPackage, wantPkg) {
            pkgCands.add(qc)
          } else if pkgReexportsFrom(tbl, wantPkg, qc.originPackage) {
            reexported.add(qc)
          }
        }
        // A package's own declaration beats one it merely re-exports (#7799).
        if pkgCands.count == 0 {
          for rc in reexported {
            pkgCands.add(rc)
          }
        }
        if pkgCands.count > 0 {
          return pickByShape(tbl, pkgCands, args, argTypes, None, ambiguous)
        }
        // A qualifier naming a package the file imports but no dependency
        // provides never falls back to a bare-name lookup: the qualified
        // reference reports the missing package instead (T0215, #7989).
        if importedPackageMissing(tbl, sigs, wantPkg, name) {
          return None
        }
      }
      // The arity-key "primary" is the historical lookup: a user definition
      // overwrites it (so it shadows an imported same-name function), and
      // imported items register it first-in-wins.  The bare `name` key is the
      // legacy fallback — using it before the arity key would misfire as T0042
      // every time a 3-arg call hits a bare key registered for the 2-arg
      // overload, so it stays second.
      val bare = path.segments.count == 1
      val primaryAny = match mapGet(sigs, arityKey) { case Some(s) -> Some(value = s); case None -> mapGet(sigs, name) }
      // A bare call sees only the functions its file's imports make visible
      // (docs/01 §9.2); a hidden primary defers to a visible overload, or to
      // the `ECall` arm's unknown-name report.
      val primary = match primaryAny {
        case Some(s) -> if not bare or symTableBareFuncVisible(tbl, s.originPackage, name) {
          primaryAny
        } else {
          None
        }
        case None -> None
      }
      // A direct import's function shadows one reached only transitively, as
      // for every other bare name (docs/01 §9.2): take the first of the
      // lowest tier whose params match before the historical first-registered
      // order below, which knows no tiers.
      if bare {
        match tieredBareSig(tbl, sigs, name, args, argTypes, primary, ambiguous) {
          case Some(s) -> return Some(value = s)
          case None -> ()
        }
      }
      // Preserve shadowing and the common case: if the primary's params match
      // the arguments, use it.  Only when it does *not* match do we consult the
      // overload candidates — this is the disambiguation for #1488 category C.
      match primary {
        case Some(s) -> if paramsMatchArgs(tbl, s.params, argTypes) { return Some(value = s) }
        case None -> {
        }
      }
      // Overload pick (#1488 category C): the primary didn't match the argument
      // types, so select the same-arity candidate (registered by
      // `registerOverloadCandidate`) whose params do.  This dispatches
      // `toUpper("s")` to `Std.String.toUpper(String)` when the primary
      // `Std.Char.toUpper(Char)` mismatches, and — because `typeEquiv` treats
      // `TyError`/`TyVar` as wildcards — resolves `join(",", [])` (an
      // empty-literal `slice[<error>]` arg) to `Std.String.join(String,
      // slice[String])` over `Std.Path.join(String, String)`.
      val candidates = gatherOverloadCandidates(sigs, arityKey)
      var ci = 0
      var firstVisible: Option[ResolvedSignature] = None
      while ci < candidates.count {
        val cand = candidates[ci]
        if not bare or symTableBareFuncVisible(tbl, cand.originPackage, name) {
          if paramsMatchArgs(tbl, cand.params, argTypes) {
            return Some(value = cand)
          }
          match firstVisible {
            case None -> {
              firstVisible = Some(value = cand)
            }
            case Some(_) -> ()
          }
        }
        ci = ci + 1
      }
      if bare {
        match firstVisible {
          case None -> {
            // The visible declaration may be generic (no overload slot) or
            // the only one of this arity while a hidden one holds the slots.
            val visible = visibleBareFuncSigs(tbl, sigs, name, arity)
            if visible.count > 0 {
              match primary {
                case None -> return Some(value = visible[0])
                case Some(_) -> ()
              }
            }
          }
          case Some(_) -> ()
        }
      }
      match primaryAny {
        case Some(_) -> match primary { case None -> return firstVisible; case Some(_) -> () }
        case None -> ()
      }
      // No candidate matched the arguments — fall back to the primary so the
      // `ECall` arm still reports any T0042/T0043 against the historical
      // first-in-wins signature (the pre-#1488 behaviour).
      primary
    }
    case _ -> None
  }
}
