//! typechecker_exprs.l — bottom-up expression type inference.
//! Mirrors compiler/src/Lyric.TypeChecker/ExprChecker.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Literal types.
// ─────────────────────────────────────────────────────────────────────────────
pub func typeOfLiteral(lit: in Literal): Type {
  match lit {
    case LInt(_, sfx, _) -> match sfx { case NoIntSuffix -> TyPrim(pt = PtInt); case I8 -> TyPrim(pt = PtByte); case I16 -> TyPrim(pt = PtInt); case I32 -> TyPrim(pt = PtInt); case I64 -> TyPrim(pt = PtLong); case U8 -> TyPrim(pt = PtByte); case U16 -> TyPrim(pt = PtUInt); case U32 -> TyPrim(pt = PtUInt); case U64 -> TyPrim(pt = PtULong) }
    case LFloat(_, sfx, _) -> match sfx { case NoFloatSuffix -> TyPrim(pt = PtDouble); case F32 -> TyPrim(pt = PtFloat); case F64 -> TyPrim(pt = PtDouble) }
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
// Keep in sync with `isCodegenBuiltinName` in `typechecker_checker.l` (shadow-prevention).
func codegenBuiltinType(name: in String): Option[Type] {
  if name == "println" {
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
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtBool))
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtUnit), isAsync = false))
  }
  if name == "format1" {
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtString))
    ps.add(TyError)
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtString), isAsync = false))
  }
  if name == "format2" {
    val ps: List[Type] = newList()
    ps.add(TyPrim(pt = PtString))
    ps.add(TyError)
    ps.add(TyError)
    return Some(value = TyFunction(params = ps, ret = TyPrim(pt = PtString), isAsync = false))
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
    case TyPrim(pt) -> match pt { case PtByte -> true; case PtInt -> true; case PtLong -> true; case PtUInt -> true; case PtULong -> true; case PtNat -> true; case PtFloat -> true; case PtDouble -> true; case _ -> false }
    // A range subtype is numeric/ordered when its underlying representation is —
    // otherwise arithmetic / comparison on a range-typed value would spuriously fail T0030/T0033.
    case TyRefined(u, _, _, _) -> isNumericType(u)
    case TyError -> true
    case _ -> false
  }
}

func isOrderedType(t: in Type): Bool {
  if isNumericType(t) {
    return true
  }
  match t {
    case TyPrim(pt) -> match pt { case PtChar -> true; case PtString -> true; case _ -> false }
    case TyRefined(u, _, _, _) -> isOrderedType(u)
    case _ -> false
  }
}

func hasDerive(tbl: in SymbolTable, marker: in String, t: in Type): Bool {
  match t {
    case TyUser(tid, _, _) -> {
      var i = 0
      while i < tbl.symbols.count {
        match tbl.symbols[i].kind {
          case DKDistinctType(did, dt) -> {
            if typeIdEq(did, tid) {
              return listContainsStr(dt.derives, marker)
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
            if typeIdEq(uid, id) {
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
            if typeIdEq(eid, id) {
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
    case PBinding(name, inner) -> match inner { case Some(ip) -> patternIsCatchAll(ip, caseNames); case None -> not listContainsStr(caseNames, name) }
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
    case PBinding(name, inner) -> match inner { case Some(ip) -> collectCoveredCases(ip, caseNames, covered); case None -> if listContainsStr(caseNames, name) and not listContainsStr(covered, name) { covered.add(name) } }
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
      var i = 0
      while i < tbl.symbols.count {
        match tbl.symbols[i].kind {
          case DKOpaque(oid, _) -> {
            if typeIdEq(oid, id) and tbl.symbols[i].isImported {
              return Some(value = tbl.symbols[i].name)
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
                case None -> match arms[i].pattern.kind { case PLiteral(lit) -> match lit { case LBool(b) -> if b { sawTrue = true } else { sawFalse = true }; case _ -> {  } }; case _ -> {  } }
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
        case _ -> if isUnboundedScalar(pt) { val noNames: List[String] = newList(); if not armsHaveCatchAll(arms, noNames) { diag.add(errorDiagnostic("T0016", "non-exhaustive match on " + renderType(st) + ": add a wildcard `_` arm", span)) } }
      }
    }
    case _ -> match finiteCaseNames(tbl, st) { case None -> {  }; case Some(caseNames) -> { if not armsHaveCatchAll(arms, caseNames) { val covered: List[String] = newList(); var i = 0; while i < arms.count { match arms[i].guard { case None -> collectCoveredCases(arms[i].pattern, caseNames, covered); case Some(_) -> {  } }; i = i + 1 }; val missing: List[String] = newList(); var c = 0; while c < caseNames.count { if not listContainsStr(covered, caseNames[c]) { missing.add(caseNames[c]) }; c = c + 1 }; if missing.count > 0 { diag.add(errorDiagnostic("T0016", "non-exhaustive match on " + renderType(st) + ": missing case(s) " + joinStrs(missing, ", "), span)) } } } }
  }
  // not a finite-case type — skip
}

// True when `e` is an integer literal written WITHOUT a type suffix
// (`0`, `42`, `1_000` — not `0i64`).  Such a literal defaults to `Int`
// but, per the language reference (integer literals "follow Rust's
// syntax"), adopts whatever concrete integer type the context requires
// (#2514).
func isUnsuffixedIntLit(e: in Expr): Bool {
  match e.kind {
    case ELiteral(lit) -> match lit { case LInt(_, sfx, _) -> match sfx { case NoIntSuffix -> true; case _ -> false }; case _ -> false }
    case _ -> false
  }
}

// True when `t` (after stripping range refinements) is a concrete integer
// primitive — the set an unsuffixed literal may adopt.
func isConcreteIntType(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtByte -> true; case PtInt -> true; case PtLong -> true; case PtUInt -> true; case PtULong -> true; case PtNat -> true; case _ -> false }
    case _ -> false
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
func adoptIntLiteralType(e: in Expr, actual: in Type, expected: in Type): Type {
  if isUnsuffixedIntLit(e) and isPlainInt(actual) and isConcreteIntType(expected) {
    return expected
  }
  actual
}

func inferBinop(
  tbl: in SymbolTable, diag: in List[Diagnostic], op: in BinOp, lhs: in Type, rhs: in Type, span: in Span
): Type {
  match op {
    case BAdd -> {
      match lhs {
        case TyPrim(pt) -> match pt { case PtString -> return TyPrim(pt = PtString); case _ -> {  } }
        case _ -> {
        }
      }
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Add", lhs)
      if not lhsOk {
        diag.add(
          errorDiagnostic("T0030", "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span)
        )
      }
      // TODO(#1891): the `val addEquiv = …; if not addEquiv { … }` shape
      // avoids inlining the `typeEquiv` call inside the `if` directly, which
      // would otherwise route through the PConstructor MObject codegen bug.
      val addEquiv = typeEquiv(lhs, rhs)
      if not addEquiv {
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
    case BSub -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Sub", lhs)
      if not lhsOk {
        diag.add(
          errorDiagnostic("T0030", "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span)
        )
      }
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
    case BMul -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Mul", lhs)
      if not lhsOk {
        diag.add(
          errorDiagnostic("T0030", "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span)
        )
      }
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
    case BDiv -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Div", lhs)
      if not lhsOk {
        diag.add(
          errorDiagnostic("T0030", "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span)
        )
      }
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
    case BMod -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Mod", lhs)
      if not lhsOk {
        diag.add(
          errorDiagnostic("T0030", "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span)
        )
      }
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
      TyPrim(pt = PtBool)
    }
    case BLt -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs)
      if not lhsOk or not typeEquiv(lhs, rhs) {
        diag.add(
          errorDiagnostic(
            "T0033",
            "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
            span
          )
        )
      }
      TyPrim(pt = PtBool)
    }
    case BLte -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs)
      if not lhsOk or not typeEquiv(lhs, rhs) {
        diag.add(
          errorDiagnostic(
            "T0033",
            "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
            span
          )
        )
      }
      TyPrim(pt = PtBool)
    }
    case BGt -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs)
      if not lhsOk or not typeEquiv(lhs, rhs) {
        diag.add(
          errorDiagnostic(
            "T0033",
            "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
            span
          )
        )
      }
      TyPrim(pt = PtBool)
    }
    case BGte -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs)
      if not lhsOk or not typeEquiv(lhs, rhs) {
        diag.add(
          errorDiagnostic(
            "T0033",
            "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")",
            span
          )
        )
      }
      TyPrim(pt = PtBool)
    }
    case BAnd -> {
      if not typeEquiv(lhs, TyPrim(pt = PtBool)) {
        diag.add(
          errorDiagnostic("T0034", "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span)
        )
      }
      if not typeEquiv(rhs, TyPrim(pt = PtBool)) {
        diag.add(
          errorDiagnostic("T0034", "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span)
        )
      }
      TyPrim(pt = PtBool)
    }
    case BOr -> {
      if not typeEquiv(lhs, TyPrim(pt = PtBool)) {
        diag.add(
          errorDiagnostic("T0034", "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span)
        )
      }
      if not typeEquiv(rhs, TyPrim(pt = PtBool)) {
        diag.add(
          errorDiagnostic("T0034", "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span)
        )
      }
      TyPrim(pt = PtBool)
    }
    case BXor -> {
      if not typeEquiv(lhs, TyPrim(pt = PtBool)) {
        diag.add(
          errorDiagnostic("T0034", "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span)
        )
      }
      if not typeEquiv(rhs, TyPrim(pt = PtBool)) {
        diag.add(
          errorDiagnostic("T0034", "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span)
        )
      }
      TyPrim(pt = PtBool)
    }
    case BImplies -> {
      if not typeEquiv(lhs, TyPrim(pt = PtBool)) {
        diag.add(
          errorDiagnostic("T0034", "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span)
        )
      }
      if not typeEquiv(rhs, TyPrim(pt = PtBool)) {
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

func inferPrefix(diag: in List[Diagnostic], op: in PrefixOp, inner: in Type, span: in Span): Type {
  match op {
    case PreNeg -> {
      if not isNumericType(inner) {
        diag.add(errorDiagnostic("T0036", "unary minus requires a numeric operand (got " + renderType(inner) + ")", span))
      }
      inner
    }
    case PreNot -> {
      if not typeEquiv(inner, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0037", "'not' requires a Bool operand (got " + renderType(inner) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case PreRef -> inner
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Member access.
// ─────────────────────────────────────────────────────────────────────────────
func builtinMember(recvRaw: in Type, name: in String): Option[Type] {
  val recv = unrefine(recvRaw)
  match recv {
    case TySlice(_) -> {
      if name == "length" {
        return Some(value = TyPrim(pt = PtInt))
      }
      None
    }
    case TyArray(_, _) -> {
      if name == "length" {
        return Some(value = TyPrim(pt = PtInt))
      }
      None
    }
    case TyPrim(pt) -> match pt { case PtString -> { if name == "length" { return Some(value = TyPrim(pt = PtInt)) }; if name == "isEmpty" { return Some(value = TyPrim(pt = PtBool)) }; None }; case _ -> None }
    case TyException -> {
      if name == "message" {
        return Some(value = TyPrim(pt = PtString))
      }
      if name == "typeName" {
        return Some(value = TyPrim(pt = PtString))
      }
      None
    }
    case TyUser(_, nm, targs) -> {
      // Generic collection methods that must carry their element type through so
      // downstream uses (notably `for x in xs.toArray()` + `match x`) see the
      // real element type rather than `TyError` — an unknown-typed match
      // scrutinee silently degenerates to the first case (#2126).
      if nm == "List" and targs.count == 1 {
        if name == "toArray" {
          return Some(value = TySlice(element = targs[0]))
        }
        if name == "count" {
          return Some(value = TyPrim(pt = PtInt))
        }
      }
      None
    }
    case _ -> None
  }
}

// Numeric / character conversion methods (#1901): `b.toInt()`, `c.toLong()`,
// etc.  The target primitive each one yields; `None` for any other name.
// `toFloat` is intentionally absent — the MSIL backend has no R4 representation
// distinct from `Double`, so a `Float` conversion is not offered until that
// gap is closed (Band 4).
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
  None
}

// A receiver type the numeric conversion methods accept.  Restricted to the
// primitives the backend can actually represent and convert — `Byte`, `Int`,
// `Long`, `Double`, `Char` — so the type checker never accepts a `.toX()` call
// the codegen cannot lower.  The unsigned integers (`UInt`, `ULong`, `Nat`) have
// no backend representation yet (no unsigned-integer support on either target),
// and `Float` has no R4 representation distinct from `Double`; conversion
// support for them is tracked in #2050 / Band 4 and must land with real backend
// support, not a checker-only claim.
func isNumericOrCharType(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtByte -> true; case PtInt -> true; case PtLong -> true; case PtDouble -> true; case PtChar -> true; case _ -> false }
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
func indexElementType(recvRaw: in Type): Type {
  match unrefine(recvRaw) {
    case TySlice(elem) -> elem
    case TyArray(_, elem) -> elem
    case TyPrim(pt) -> match pt { case PtString -> TyPrim(pt = PtChar); case _ -> TyError }
    case TyUser(_, nm, targs) -> {
      // Matched by short name: `nm` is the unqualified name as registered by the
      // stdlib kernel (`List`, `Map`).  User-defined types with those names and the
      // matching arity would also match here — this is acceptable given that `List`
      // and `Map` are effectively reserved stdlib names in the kernel convention.
      if nm == "List" and targs.count == 1 {
        targs[0]
      } else if nm == "Map" and targs.count == 2 {
        targs[1]
      } else {
        TyError
      }
    }
    case _ -> TyError
  }
}

func fieldsOfRecord(tbl: in SymbolTable, tid: in TypeId): List[FieldEntry] {
  val result: List[FieldEntry] = newList()
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKRecord(did, rd) -> {
        if typeIdEq(did, tid) {
          extractRecordFields(tbl, rd, result)
        }
      }
      case DKExposedRec(did, rd) -> {
        if typeIdEq(did, tid) {
          extractRecordFields(tbl, rd, result)
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

func extractRecordFields(tbl: in SymbolTable, rd: in RecordDecl, result: in List[FieldEntry]): Unit {
  val ctx = newGenericContext()
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
pub func inferExprOrBlock(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  eob: in ExprOrBlock,
): Type {
  match eob {
    case EOBExpr(ex) -> inferExpr(sc, tbl, sigs, diag, ex)
    case EOBBlock(bl) -> checkBlock(sc, tbl, sigs, sc.genericNames, sc.returnTy, diag, bl)
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
    case TyUser(aid, an, aargs) -> match unrefine(b) { case TyUser(bid, _, bargs) -> { if typeIdEq(aid, bid) and aargs.count == bargs.count { val merged: List[Type] = newList(); var allOk = true; var i = 0; while i < aargs.count { if typeEquiv(aargs[i], bargs[i]) { merged.add(aargs[i]) } else { match mergeIntWiden(aargs[i], bargs[i]) { case Some(m) -> merged.add(m); case None -> { allOk = false; merged.add(aargs[i]) } } }; i = i + 1 }; if allOk { return Some(value = TyUser(id = aid, name = an, args = merged)) }; return None }; None }; case _ -> None }
    case _ -> None
  }
}

func unifyBranchTypes(a: in Type, b: in Type, span: in Span, diag: in List[Diagnostic]): Type {
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
  if isUnitType(a) or isUnitType(b) {
    return TyPrim(pt = PtUnit)
  }
  if typeEquiv(a, b) {
    a
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

func inferMember(tbl: in SymbolTable, diag: in List[Diagnostic], recvRaw: in Type, name: in String, span: in Span): Type {
  val recv = unrefine(recvRaw)
  match recv {
    case TyUser(tid, _, _) -> {
      val fs = fieldsOfRecord(tbl, tid)
      var i = 0
      while i < fs.count {
        if fs[i].name == name {
          return fs[i].ty
        }
        i = i + 1
      }
      TyError
    }
    case TyError -> TyError
    case _ -> {
      match builtinMember(recv, name) {
        case Some(t) -> t
        case None -> TyError
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Expression path resolution.
// ─────────────────────────────────────────────────────────────────────────────
func resolveExprPath(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  path: in ModulePath,
  span: in Span,
): Type {
  if path.segments.count != 1 {
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
  match mapGet(sigs, name) {
    case Some(sig) -> {
      // #1484: a function resolves via `sigs` (no visibility there) — consult
      // the symbol table for the same name to enforce cross-package visibility.
      match symTableTryFindOne(tbl, name) {
        case Some(sym) -> checkImportedVisibility(sym, span, diag)
        case None -> {
        }
      }
      val pts: List[Type] = newList()
      var i = 0
      while i < sig.params.count {
        pts.add(sig.params[i].ty)
        i = i + 1
      }
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
  match symTableTryFindOne(tbl, name) {
    case Some(sym) -> {
      checkImportedVisibility(sym, span, diag)
      match sym.kind {
        case DKUnionCase(_, _) -> {
          // A bare constructor reference like `Some` without call args infers as the
          // parent union with TyError type-args (uninferable without arguments).
          // The enclosing ECall arm re-infers with actual arg types and wins.
          return inferUnionCaseConstruction(tbl, diag, sym, newList(), span)
        }
        case DKConst(cd) -> {
          val ctx = newGenericContext()
          return resolveType(tbl, ctx, diag, cd.ty)
        }
        case DKVal(vd) -> {
          match vd.ty {
            case Some(te) -> {
              val ctx = newGenericContext()
              return resolveType(tbl, ctx, diag, te)
            }
            case None -> {
              // Infer against an empty scope to avoid the caller's local bindings
              // shadowing module-level names referenced in vd.init.
              val emptyScope = newScopeForFunction(TyError, newList())
              return inferExpr(emptyScope, tbl, sigs, diag, vd.init)
            }
          }
        }
        case _ -> {
        }
      }
    }
    case None -> {
      diag.add(errorDiagnostic("T0020", "unknown name '" + name + "'", span))
    }
  }
  TyError
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

// #1487 (§5.2): the expression behind a call argument.
func callArgExpr(arg: in CallArg): Expr {
  match arg {
    case CAPositional(ae) -> ae
    case CANamed(_, ae, _) -> ae
  }
}

// #1487 (§5.2): an argument bound to an `out`/`inout` parameter must be a
// writable l-value.  Conservative by construction (zero false positives): flag
// only arguments that are *definitely not* assignable targets — literals, call
// results, operator expressions — and single-segment locals that are *known
// immutable* (`val` / `let` / `in`).  Member access (`x.field`), element access
// (`x[i]`), qualified paths, and non-local names are accepted as potential
// l-values; precise mutability of fields / elements is deferred rather than
// risk a false positive on valid by-ref code.
func argIsValidByRefTarget(sc: in Scope, e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsValidByRefTarget(sc, inner)
    case EPath(p) -> if p.segments.count == 1 { match scopeTryFind(sc, p.segments[0]) { case Some(b) -> b.isMutable; case None -> true } } else { true }
    // a local binding must be mutable
    // not a local (global / unknown) — accept
    // qualified path — accept
    case EMember(_, _) -> true
    // field access — potential l-value
    case EIndex(_, _) -> true
    // element access — potential l-value
    case _ -> false
  }
  // literal / call / operator / … — not an l-value
}

func modeNeedsLValue(m: in ParamMode): Bool {
  match m {
    case PMOut -> true
    case PMInout -> true
    case PMIn -> false
  }
}

// The mutable-l-value requirement for an `out`/`inout` argument applies only to
// *value-type* parameters, where the callee writes a value back into the
// caller's binding (so it must be assignable).  Reference-type parameters
// (records, `String`, slices, arrays, …) are mutated in place through the
// reference — the idiomatic `inout RecordState` pattern passes a `val`-bound
// record and mutates its fields without rebinding — so requiring a mutable
// l-value there would false-positive on valid by-ref code.  Restricting to
// value types is conservative (it never rejects valid code) and still catches
// the common `out Int` / `inout Bool` mis-argument.
func isByRefValueType(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtString -> false; case PtUnit -> false; case PtNever -> false; case _ -> true }
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5a. Record / opaque construction (#1483 record-ctor, #1485 opaque hiding).
// ─────────────────────────────────────────────────────────────────────────────
record CtorField {
  name: String
  ty: Type
  hasDefault: Bool
}

func ctorIsGeneric(sym: in Symbol): Bool {
  match sym.kind {
    case DKRecord(_, rd) -> match rd.generics { case Some(_) -> true; case None -> false }
    case DKExposedRec(_, rd) -> match rd.generics { case Some(_) -> true; case None -> false }
    case DKOpaque(_, od) -> match od.generics { case Some(_) -> true; case None -> false }
    case _ -> false
  }
}

func ctorIsOpaque(sym: in Symbol): Bool {
  match sym.kind {
    case DKOpaque(_, _) -> true
    case _ -> false
  }
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

// Append the constructor fields of a record/opaque member list to `out`
// (mirrors `extractRecordFields`).  A field with a default is optional.
func collectCtorFieldsFromRecord(
  tbl: in SymbolTable,
  ctx: in GenericContext,
  scratch: in List[Diagnostic],
  members: in List[RecordMember],
  acc: in List[CtorField],
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
          }
        }
        acc.add(CtorField(name = fd.name, ty = t, hasDefault = hasDef))
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
          }
        }
        acc.add(CtorField(name = fd.name, ty = t, hasDefault = hasDef))
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// Fill `out` with the constructor fields of `sym`; returns true if `sym` is a
// constructible type (record / exposed-record / opaque).
func collectCtorFields(tbl: in SymbolTable, sym: in Symbol, acc: in List[CtorField]): Bool {
  val ctx = newGenericContext()
  val scratch: List[Diagnostic] = newList()
  match sym.kind {
    case DKRecord(_, rd) -> {
      collectCtorFieldsFromRecord(tbl, ctx, scratch, rd.members, acc)
      true
    }
    case DKExposedRec(_, rd) -> {
      collectCtorFieldsFromRecord(tbl, ctx, scratch, rd.members, acc)
      true
    }
    case DKOpaque(_, od) -> {
      collectCtorFieldsFromOpaque(tbl, ctx, scratch, od.members, acc)
      true
    }
    case _ -> false
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

func inferConstruction(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  sym: in Symbol,
  args: in List[CallArg],
  span: in Span,
): Type {
  val resultTy = ctorResultType(sym)
  // #1485: an opaque type's representation is hidden — it cannot be constructed
  // from outside its declaring package.
  if ctorIsOpaque(sym) and sym.isImported {
    diag.add(
      errorDiagnostic("T0100", "cannot construct opaque type '" + sym.name + "' outside its declaring package", span)
    )
    return resultTy
  }
  // Named arguments must reference a real field (T0101).  Full arg validation
  // (missing-required, positional arity, value-type matching) is a follow-up;
  // CtorField.ty and CtorField.hasDefault are pre-populated for that follow-up.
  val fields: List[CtorField] = newList()
  val _ = collectCtorFields(tbl, sym, fields)
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(nm, _, asp) -> {
        if not fieldHasName(fields, nm) {
          diag.add(errorDiagnostic("T0101", "'" + sym.name + "' has no field '" + nm + "'", asp))
        }
      }
      case CAPositional(_) -> {
      }
    }
    i = i + 1
  }
  resultTy
}

func constructorSymbolOf(tbl: in SymbolTable, fn: in Expr): Option[Symbol] {
  match fn.kind {
    case EPath(p) -> if p.segments.count == 1 { match symTableTryFindOne(tbl, p.segments[0]) { case Some(sym) -> match sym.kind { case DKRecord(_, _) -> Some(value = sym); case DKExposedRec(_, _) -> Some(value = sym); case DKOpaque(_, _) -> Some(value = sym); case _ -> None }; case None -> None } } else { None }
    case _ -> None
  }
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
// The union-case symbol for a constructor reference `fn` (last path segment).
func unionCaseSymbolOf(tbl: in SymbolTable, fn: in Expr): Option[Symbol] {
  match fn.kind {
    case EPath(p) -> if p.segments.count >= 1 { match symTableTryFindOne(tbl, p.segments[p.segments.count - 1]) { case Some(sym) -> match sym.kind { case DKUnionCase(_, _) -> Some(value = sym); case _ -> None }; case None -> None } } else { None }
    case _ -> None
  }
}

func parentUnionDeclOf(tbl: in SymbolTable, parentId: in TypeId): Option[UnionDecl] {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKUnion(uid, decl) -> if typeIdEq(uid, parentId) { return Some(value = decl) }
      case _ -> {
      }
    }
    i = i + 1
  }
  None
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

func unionCaseFieldTypes(
  tbl: in SymbolTable, diag: in List[Diagnostic], uc: in UnionCase, genericNames: in List[String]
): List[Type] {
  val ctx = newGenericContext()
  gctxPush(ctx, genericNames)
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
  result
}

// For each parent generic name, take the argument type at the field position
// that is exactly `TyVar(name)` (single-level inference; nested generic
// positions fall back to `TyError`).
func inferGenericArgs(genericNames: in List[String], fieldTypes: in List[Type], argTypes: in List[Type]): List[Type] {
  val result: List[Type] = newList()
  var g = 0
  while g < genericNames.count {
    var found: Type = TyError
    var i = 0
    while i < fieldTypes.count and i < argTypes.count {
      match fieldTypes[i] {
        case TyVar(nm) -> if nm == genericNames[g] { found = argTypes[i] }
        case _ -> {
        }
      }
      i = i + 1
    }
    result.add(found)
    g = g + 1
  }
  result
}

// The parent union type for a union-case symbol, instantiated with the type args
// inferred from `argTypes` (empty for a bare-name reference like `None`).
func inferUnionCaseConstruction(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  caseSym: in Symbol,
  argTypes: in List[Type],
  span: in Span,
): Type {
  match caseSym.kind {
    case DKUnionCase(parentId, uc) -> match parentUnionDeclOf(tbl, parentId) { case Some(decl) -> { val gnames = unionDeclGenericNames(decl); val ftypes = unionCaseFieldTypes(tbl, diag, uc, gnames); val targs = inferGenericArgs(gnames, ftypes, argTypes); TyUser(id = parentId, name = decl.name, args = targs) }; case None -> TyError }
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
    case TyArray(sz, e) -> TyArray(size = sz, element = substituteTyVars(e, names, args))
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
      // Guard by TypeId to avoid cross-constructor inference (e.g. Result vs Option).
      val aargs = match unrefine(argTy) {
        case TyUser(aid, _, a) -> if typeIdEq(pid, aid) { a } else { newList() }
        case _ -> newList()
      }
      findGenericInPairs(name, pargs, aargs)
    }
    case TySlice(pe) -> match unrefine(argTy) { case TySlice(ae) -> findGenericInPair(name, pe, ae); case _ -> None }
    case TyArray(_, pe) -> match unrefine(argTy) { case TyArray(_, ae) -> findGenericInPair(name, pe, ae); case _ -> None }
    case TyNullable(pi) -> match unrefine(argTy) { case TyNullable(ai) -> findGenericInPair(name, pi, ai); case _ -> None }
    case TyTuple(pes) -> {
      val aes = match unrefine(argTy) { case TyTuple(a) -> a; case _ -> newList() }
      findGenericInPairs(name, pes, aes)
    }
    case TyFunction(pps, pr, _) -> match unrefine(argTy) { case TyFunction(aps, ar, _) -> match findGenericInPairs(name, pps, aps) { case Some(v) -> Some(value = v); case None -> findGenericInPair(name, pr, ar) }; case _ -> None }
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
// misleading concrete return type.
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
  var i = 0
  while i < paramTys.count and i < argTys.count {
    match findGenericInPair(name, paramTys[i], argTys[i]) {
      case Some(v) -> if not haveBinding { bound = v; haveBinding = true } else { if not typeEquiv(bound, v) { return TyError } }
      case None -> {
      }
    }
    i = i + 1
  }
  bound
}

// A generic function's return type instantiated from the call's argument types:
// `unwrapOr(o: Option[T], default: T): T` called with an `Option[Int]` / `Int`
// pair yields `Int` instead of the raw `TyVar("T")` (#1488 category B).  A
// non-generic sig is returned unchanged.
func instantiateReturnType(sig: in ResolvedSignature, argTypes: in List[Type]): Type {
  if sig.generics.count == 0 {
    return sig.returnTy
  }
  val paramTys: List[Type] = newList()
  var i = 0
  while i < sig.params.count {
    paramTys.add(sig.params[i].ty)
    i = i + 1
  }
  val targs = inferGenericArgsDeep(sig.generics, paramTys, argTypes)
  substituteTyVars(sig.returnTy, sig.generics, targs)
}

// The union case's field types *instantiated* against the scrutinee's type args:
// `Some` (`value: T`) on `Option[NameAndSpan]` → `[NameAndSpan]`.
func caseFieldTypesInstantiated(
  tbl: in SymbolTable, diag: in List[Diagnostic], caseSym: in Symbol, scrutTy: in Type
): List[Type] {
  match caseSym.kind {
    case DKUnionCase(parentId, uc) -> match parentUnionDeclOf(tbl, parentId) { case Some(decl) -> { val gnames = unionDeclGenericNames(decl); val ftypes = unionCaseFieldTypes(tbl, diag, uc, gnames); val targs = match unrefine(scrutTy) { case TyUser(_, _, a) -> a; case _ -> newList() }; val result: List[Type] = newList(); var i = 0; while i < ftypes.count { result.add(substituteTyVars(ftypes[i], gnames, targs)); i = i + 1 }; result }; case None -> newList() }
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
func isConstructorPatternName(tbl: in SymbolTable, name: in String): Bool {
  match symTableTryFindOne(tbl, name) {
    case Some(sym) -> match sym.kind { case DKUnionCase(_, _) -> true; case DKEnumCase(_, _) -> true; case _ -> false }
    case None -> false
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
    case TyArray(sz, e) -> TyArray(size = sz, element = eraseTyVars(e))
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

func bindPatternTyped(sc: in Scope, tbl: in SymbolTable, diag: in List[Diagnostic], pat: in Pattern, ty: in Type): Unit {
  match pat.kind {
    case PBinding(name, inner) -> {
      if name != "_" and not isConstructorPatternName(tbl, name) {
        scopeAdd(sc, LocalBinding(name = name, ty = eraseTyVars(ty), isMutable = false))
      }
      match inner {
        case None -> {
        }
        case Some(p) -> bindPatternTyped(sc, tbl, diag, p, ty)
      }
    }
    case PWildcard -> {
    }
    case PLiteral(_) -> {
    }
    case PConstructor(head, args) -> {
      val ftypes = match unionCaseSymbolOf(tbl, pat2fnExpr(head, pat.span)) {
        case Some(caseSym) -> caseFieldTypesInstantiated(tbl, diag, caseSym, ty)
        case None -> newList()
      }
      var i = 0
      while i < args.count {
        val at = if i < ftypes.count { ftypes[i] } else { TyError }
        bindPatternTyped(sc, tbl, diag, args[i], at)
        i = i + 1
      }
    }
    case PTuple(patterns) -> {
      val elems = match unrefine(ty) { case TyTuple(es) -> es; case _ -> newList() }
      var i = 0
      while i < patterns.count {
        val et = if i < elems.count { elems[i] } else { TyError }
        bindPatternTyped(sc, tbl, diag, patterns[i], et)
        i = i + 1
      }
    }
    case PRecord(_, fields, _) -> {
      // Resolve the record's declared field types from the scrutinee type so a
      // bound field carries its real type (e.g. `Point{x = a}` types `a` as
      // `Int`) rather than `TyError`.
      val recFields: List[FieldEntry] = match unrefine(ty) {
        case TyUser(tid, _, _) -> fieldsOfRecord(tbl, tid)
        case _ -> newList()
      }
      var i = 0
      while i < fields.count {
        match fields[i] {
          case RPFNamed(fname, p, _) -> bindPatternTyped(sc, tbl, diag, p, fieldEntryType(recFields, fname))
          case RPFShort(nm, _) -> scopeAdd(sc, LocalBinding(name = nm, ty = fieldEntryType(recFields, nm), isMutable = false))
        }
        i = i + 1
      }
    }
    case POr(patterns) -> {
      // All alternatives bind the same names by language rule; process the first.
      if patterns.count > 0 {
        bindPatternTyped(sc, tbl, diag, patterns[0], ty)
      }
    }
    case PParen(inner) -> {
      bindPatternTyped(sc, tbl, diag, inner, ty)
    }
    case PTypeTest(inner, tyExpr) -> {
      // `case x is T ->` narrows the scrutinee to `T`, so the inner pattern (and
      // any binding it introduces) is typed at `T` — letting `x.field` resolve
      // against the tested type rather than the wider scrutinee type.
      val ctx = newGenericContext()
      val testTy = resolveType(tbl, ctx, diag, tyExpr)
      bindPatternTyped(sc, tbl, diag, inner, testTy)
    }
    case PRange(_, _, _) -> {
    }
    case _ -> {
    }
  }
}

// Wrap a constructor head `ModulePath` as an `EPath` expression so the existing
// `unionCaseSymbolOf` (which takes an `Expr`) can resolve the case symbol.
func pat2fnExpr(head: in ModulePath, span: in Span): Expr {
  Expr(kind = EPath(path = head), span = span)
}

pub func inferExpr(
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
      }
      TySlice(element = first)
    }

    case EPrefix(op, inner) -> {
      val it = inferExpr(sc, tbl, sigs, diag, inner)
      inferPrefix(diag, op, it, e.span)
    }

    case EBinop(op, l, r) -> {
      val lt0 = inferExpr(sc, tbl, sigs, diag, l)
      val rt0 = inferExpr(sc, tbl, sigs, diag, r)
      // Rust-style integer-literal inference: an unsuffixed literal operand
      // adopts the other operand's concrete integer type, so `someLong <= 0`
      // / `someLong + 1` type-check without a `0i64` suffix (#2514).
      val lt = adoptIntLiteralType(l, lt0, rt0)
      val rt = adoptIntLiteralType(r, rt0, lt0)
      inferBinop(tbl, diag, op, lt, rt, e.span)
    }

    case ECall(fn, args) -> {
      // Numeric / character conversion-method intrinsics (#1901): `x.toInt()`,
      // `b.toLong()`, etc.  Recognised only on a numeric/char receiver so a
      // user-defined method of the same name on some other type still falls
      // through to the general (lenient) dispatch.  A non-numeric receiver
      // yields `TyError`, exactly what the general path would produce — so the
      // receiver is inferred once, with no duplicate diagnostics.
      match fn.kind {
        case EMember(recvE, mname) -> match numericConvTarget(mname) { case Some(target) -> if args.count == 0 { val rt = inferExpr(sc, tbl, sigs, diag, recvE); if isNumericOrCharType(rt) { return TyPrim(pt = target) }; if isNonConvertiblePrimitive(rt) { diag.add(errorDiagnostic("T0103", "conversion method '" + mname + "' is not applicable to " + renderType(rt), recvE.span)); return TyError }; match rt { case TyError -> return TyError; case _ -> {  } } }; case None -> {  } }
        // Non-numeric, non-primitive receiver: fall through to general dispatch so
        // a user-defined method named toInt/toLong/etc. on a user type is not
        // silently shadowed by this intrinsic path once C2 method resolution lands.
        case _ -> {
        }
      }
      val fnT = inferExpr(sc, tbl, sigs, diag, fn)
      val argTypes: List[Type] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(ae) -> argTypes.add(inferExpr(sc, tbl, sigs, diag, ae))
          case CANamed(_, ae, _) -> argTypes.add(inferExpr(sc, tbl, sigs, diag, ae))
        }
        i = i + 1
      }
      // Try direct-sig lookup first.
      val directSig = findDirectSig(sc, tbl, sigs, fn, args.count, argTypes)
      match directSig {
        case Some(sig) -> {
          if sig.params.count != args.count {
            diag.add(
              errorDiagnostic(
                "T0042",
                "expected " + toString(sig.params.count) + " argument(s), got " + toString(args.count),
                e.span
              )
            )
          } else {
            var k = 0
            while k < sig.params.count {
              val p = sig.params[k]
              if not argSatisfiesParam(tbl, p.ty, argTypes[k]) {
                diag.add(
                  errorDiagnostic(
                    "T0043",
                    "argument type " + renderType(argTypes[k]) + " does not match parameter type " + renderType(p.ty),
                    e.span
                  )
                )
              }
              // #1487 (§5.2): a value-type `out`/`inout` argument must be a
              // writable l-value (reference-type by-ref params are mutated in
              // place — see `isByRefValueType`).
              if modeNeedsLValue(p.mode) and isByRefValueType(p.ty) and not argIsValidByRefTarget(sc, callArgExpr(args[k])) {
                diag.add(
                  errorDiagnostic(
                    "T0085",
                    "argument for `out`/`inout` parameter '" + p.name +
                      "' must be a mutable l-value (a `var`, or an `out`/`inout` binding)",
                    e.span
                  )
                )
              }
              k = k + 1
            }
          }
          // Instantiate a generic return type from the argument types (#1488
          // category B) so `unwrapOr(opt, 0): T` yields `Int`, not `TyVar("T")`.
          instantiateReturnType(sig, argTypes)
        }
        case None -> match unionCaseSymbolOf(tbl, fn) { case Some(caseSym) -> inferUnionCaseConstruction(tbl, diag, caseSym, argTypes, e.span); case None -> match constructorSymbolOf(tbl, fn) { case Some(ctorSym) -> inferConstruction(tbl, diag, ctorSym, args, e.span); case None -> match fnT { case TyFunction(paramTypes, ret, _) -> { if paramTypes.count != argTypes.count { diag.add(errorDiagnostic("T0042", "expected " + toString(paramTypes.count) + " argument(s), got " + toString(argTypes.count), e.span)) } else { var k = 0; while k < paramTypes.count { if not argSatisfiesParam(tbl, paramTypes[k], argTypes[k]) { diag.add(errorDiagnostic("T0043", "argument type " + renderType(argTypes[k]) + " does not match parameter type " + renderType(paramTypes[k]), e.span)) }; k = k + 1 } }; ret }; case TyError -> TyError; case _ -> { diag.add(errorDiagnostic("T0044", "called value of non-function type " + renderType(fnT), e.span)); TyError } } } }
      }
    }

    case EMember(recv, name) -> {
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
        case EPath(p) -> if p.segments.count == 1 and startsUppercase(p.segments[0]) { val scratch: List[Diagnostic] = newList(); inferExpr(sc, tbl, sigs, scratch, recv) } else { inferExpr(sc, tbl, sigs, diag, recv) }
        case _ -> inferExpr(sc, tbl, sigs, diag, recv)
      }
      inferMember(tbl, diag, rt, name, e.span)
    }

    case EPropagate(inner) -> {
      // `e?` unwraps the operand to its success type (`Result[T,E]`/`Option[T]` -> `T`); the `Lyric.Propagate` pass owns the lowering and F0020.
      val it = inferExpr(sc, tbl, sigs, diag, inner)
      propagateUnwrap(it)
    }

    case EAwait(inner) -> inferExpr(sc, tbl, sigs, diag, inner)
    case EYield(inner) -> {
      inferExpr(sc, tbl, sigs, diag, inner)
      TyPrim(PtUnit)
    }
    case ESpawn(inner) -> inferExpr(sc, tbl, sigs, diag, inner)
    case EOld(inner) -> inferExpr(sc, tbl, sigs, diag, inner)

    case ESelf -> TySelf
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
      var ii = 0
      while ii < indices.count {
        inferExpr(sc, tbl, sigs, diag, indices[ii])
        ii = ii + 1
      }
      indexElementType(rt)
    }
    case ETypeApp(_, _) -> TyError
    case ELambda(_, _) -> TyError
    // An `if`/`else` expression takes the unified type of its branches.  An
    // `if` without an `else` produces no value on the false path, so it is
    // `Unit` (the parser desugars a statement-position brace-`if` so a trailing
    // operator does not glue — #1943).  Each branch is an `ExprOrBlock`: a block
    // branch is typed (divergence-aware) by `checkBlock` (D081), so an
    // early-`return` branch is `Never` and unifies cleanly.
    case EIf(cond, thenBranch, elseBranch, _) -> {
      val condT = inferExpr(sc, tbl, sigs, diag, cond)
      match condT {
        case TyError -> {
        }
        case TyPrim(pt) -> match pt { case PtBool -> {  }; case PtNever -> {  }; case _ -> diag.add(errorDiagnostic("T0066", "if-condition must be Bool (got " + renderType(condT) + ")", cond.span)) }
        case _ -> diag.add(errorDiagnostic("T0066", "if-condition must be Bool (got " + renderType(condT) + ")", cond.span))
      }
      val tt = inferExprOrBlock(sc, tbl, sigs, diag, thenBranch)
      match elseBranch {
        case None -> TyPrim(pt = PtUnit)
        case Some(eb) -> {
          val et = inferExprOrBlock(sc, tbl, sigs, diag, eb)
          unifyBranchTypes(tt, et, e.span, diag)
        }
      }
    }
    case EMatch(scrutinee, arms) -> {
      val st = inferExpr(sc, tbl, sigs, diag, scrutinee)
      checkMatchExhaustive(tbl, diag, st, arms, e.span)
      checkOpaquePatternHiding(tbl, diag, st, arms)
      // Branch-type unification (#2142): a `match` used as a value takes the
      // unified type of its arm bodies.  Each arm is checked in a fresh scope
      // with its pattern variables bound to their destructured types
      // (`bindPatternTyped` — `Some(ns)` on `Option[T]` binds `ns : T`), then the
      // bodies fold through `unifyBranchTypes` (Never/TyError/Unit absorbed;
      // T0067 on a genuine value mismatch).  Guards are inferred for diagnostics but
      // do not contribute to the branch type.
      var acc: Type = TyError
      var ai = 0
      while ai < arms.count {
        scopePush(sc)
        bindPatternTyped(sc, tbl, diag, arms[ai].pattern, st)
        match arms[ai].guard {
          case Some(g) -> inferExpr(sc, tbl, sigs, diag, g)
          case None -> TyError
        }
        val bt = inferExprOrBlock(sc, tbl, sigs, diag, arms[ai].body)
        val armSpan = match arms[ai].body { case EOBExpr(ae) -> ae.span; case EOBBlock(ab) -> ab.span }
        scopePop(sc)
        acc = unifyBranchTypes(acc, bt, armSpan, diag)
        ai = ai + 1
      }
      acc
    }
    // A value-position brace block / `unsafe { … }` has the type of its trailing
    // expression (or `Unit` if it ends in a statement, or `Never` if it diverges)
    // — `checkBlock` walks the statements (binding locals) and returns that type.
    // sc.genericNames / sc.returnTy are passed explicitly here because checkBlock
    // still carries them as standalone parameters (follow-up: remove them once all
    // branch forms are wired and checkBlock can read them from sc directly).
    case EBlock(blk) -> checkBlock(sc, tbl, sigs, sc.genericNames, sc.returnTy, diag, blk)
    case EUnsafe(blk) -> checkBlock(sc, tbl, sigs, sc.genericNames, sc.returnTy, diag, blk)
    case ETry(_) -> TyError
    case EForall(_, _, _) -> TyError
    case EExists(_, _, _) -> TyError
    case EAssign(_, _, _) -> TyError
    case ERange(_) -> TyError
    case EInterpolated(_) -> TyPrim(pt = PtString)
    case EError -> TyError
  }
}

// True when `params` and `argTypes` have the same count and every argument is
// acceptable for its parameter (`argSatisfiesParam`): `typeEquiv` — which treats
// `TyError`/`TyVar` as wildcards, the leniency that lets an empty-literal arg
// still select the structurally-correct overload (#1488 category C) — or
// interface subtyping, so overload selection agrees with the argument check
// (#2304).
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

// True when an argument of type `argTy` is acceptable for a parameter of type
// `paramTy` — either `typeEquiv` (the usual case), or interface subtyping
// (#1488): `argTy` is a user type `T` and `paramTy` is an interface `I` with a
// registered `impl I for T`.  Conformance is keyed by `TypeId`, so a
// same-simple-name interface from another package never satisfies the check
// (#2303).  Used at argument-position checks so a concrete type that conforms
// to an interface can be passed where the interface is expected
// (`invoiceTotal(feed: PriceFeed, …)` called with a `TrackedFeed`).
func argSatisfiesParam(tbl: in SymbolTable, paramTy: in Type, argTy: in Type): Bool {
  if typeEquiv(paramTy, argTy) {
    return true
  }
  match typeIdOfType(paramTy) {
    case Some(ifaceId) -> match typeIdOfType(argTy) { case Some(argId) -> symTableTypeImplements(tbl, argId, ifaceId); case None -> false }
    case None -> false
  }
}

// True when a value of type `actual` may be used where `expected` is
// required.  Three cases, in order:
//   1. `typeEquiv` — exact match, or either side a wildcard (TyError/TyVar).
//   2. Interface subsumption — `expected` is an interface `I` and `actual`
//      is a concrete type `T` with a registered `impl I for T` (keyed by
//      `TypeId`, so a same-named interface from another package never
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
  match unrefine(expected) {
    // Assumes covariance in all type args; revisit if invariant/contravariant parameters are added.
    case TyUser(eid, _, eargs) -> match unrefine(actual) { case TyUser(aid, _, aargs) -> { if typeIdEq(eid, aid) { if eargs.count != aargs.count { return false }; var i = 0; while i < eargs.count { if not typeAssignable(tbl, eargs[i], aargs[i]) { return false }; i = i + 1 }; return true }; symTableTypeImplements(tbl, aid, eid) }; case _ -> false }
    case _ -> false
  }
}

func findDirectSig(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  fn: in Expr,
  arity: in Int,
  argTypes: in List[Type],
): Option[ResolvedSignature] {
  match fn.kind {
    case EPath(path) -> {
      if path.segments.count == 0 {
        return None
      }
      val name = path.segments[path.segments.count - 1]
      val arityKey = name + "/" + toString(arity)
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
        val wantPkg = joinSegments(prefix)
        val qcands = gatherOverloadCandidates(sigs, arityKey)
        var qi = 0
        while qi < qcands.count {
          val qc = qcands[qi]
          if qc.originPackage == wantPkg and paramsMatchArgs(tbl, qc.params, argTypes) {
            return Some(value = qc)
          }
          qi = qi + 1
        }
      }
      // The arity-key "primary" is the historical lookup: a user definition
      // overwrites it (so it shadows an imported same-name function), and
      // imported items register it first-in-wins.  The bare `name` key is the
      // legacy fallback — using it before the arity key would misfire as T0042
      // every time a 3-arg call hits a bare key registered for the 2-arg
      // overload, so it stays second.
      val primary = match mapGet(sigs, arityKey) { case Some(s) -> Some(value = s); case None -> mapGet(sigs, name) }
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
      while ci < candidates.count {
        val cand = candidates[ci]
        if paramsMatchArgs(tbl, cand.params, argTypes) {
          return Some(value = cand)
        }
        ci = ci + 1
      }
      // No candidate matched the arguments — fall back to the primary so the
      // `ECall` arm still reports any T0042/T0043 against the historical
      // first-in-wins signature (the pre-#1488 behaviour).
      primary
    }
    case _ -> None
  }
}
