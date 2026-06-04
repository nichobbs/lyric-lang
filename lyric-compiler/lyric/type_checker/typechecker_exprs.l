// typechecker_exprs.l — bottom-up expression type inference.
// Mirrors compiler/src/Lyric.TypeChecker/ExprChecker.fs.
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
    case LInt(_, sfx) ->
      match sfx {
        case NoIntSuffix -> TyPrim(pt = PtInt)
        case I8          -> TyPrim(pt = PtByte)
        case I16         -> TyPrim(pt = PtInt)
        case I32         -> TyPrim(pt = PtInt)
        case I64         -> TyPrim(pt = PtLong)
        case U8          -> TyPrim(pt = PtByte)
        case U16         -> TyPrim(pt = PtUInt)
        case U32         -> TyPrim(pt = PtUInt)
        case U64         -> TyPrim(pt = PtULong)
      }
    case LFloat(_, sfx) ->
      match sfx {
        case NoFloatSuffix -> TyPrim(pt = PtDouble)
        case F32           -> TyPrim(pt = PtFloat)
        case F64           -> TyPrim(pt = PtDouble)
      }
    case LChar(_)        -> TyPrim(pt = PtChar)
    case LString(_)      -> TyPrim(pt = PtString)
    case LTripleString(_) -> TyPrim(pt = PtString)
    case LRawString(_)   -> TyPrim(pt = PtString)
    case LBool(_)        -> TyPrim(pt = PtBool)
    case LUnit           -> TyPrim(pt = PtUnit)
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
  if name == "hostParseIntIsValid" or name == "hostParseLongIsValid" or
     name == "hostParseDoubleIsValid" or name == "hostFileExists" or
     name == "hostReadAllTextIsValid" or name == "hostDirectoryExists" or
     name == "hostCreateDirectoryIsValid" {
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
    case TyPrim(pt) ->
      match pt {
        case PtByte   -> true
        case PtInt    -> true
        case PtLong   -> true
        case PtUInt   -> true
        case PtULong  -> true
        case PtNat    -> true
        case PtFloat  -> true
        case PtDouble -> true
        case _        -> false
      }
    case TyError -> true
    case _       -> false
  }
}

func isOrderedType(t: in Type): Bool {
  if isNumericType(t) { return true }
  match t {
    case TyPrim(pt) ->
      match pt {
        case PtChar   -> true
        case PtString -> true
        case _        -> false
      }
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
          case _ -> {}
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
    if xs[i] == s { return true }
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
              while c < decl.cases.count { names.add(decl.cases[c].name); c = c + 1 }
              return Some(value = names)
            }
          }
          case DKEnum(eid, decl) -> {
            if typeIdEq(eid, id) {
              val names: List[String] = newList()
              var c = 0
              while c < decl.cases.count { names.add(decl.cases[c].name); c = c + 1 }
              return Some(value = names)
            }
          }
          case _ -> {}
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
    case PBinding(name, inner) ->
      match inner {
        case Some(ip) -> patternIsCatchAll(ip, caseNames)
        case None     -> not listContainsStr(caseNames, name)
      }
    case PParen(ip) -> patternIsCatchAll(ip, caseNames)
    case POr(ps) -> {
      var any = false
      var i = 0
      while i < ps.count {
        if patternIsCatchAll(ps[i], caseNames) { any = true }
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
    case PBinding(name, inner) ->
      match inner {
        case Some(ip) -> collectCoveredCases(ip, caseNames, covered)
        case None     ->
          if listContainsStr(caseNames, name) and not listContainsStr(covered, name) {
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
      while i < ps.count { collectCoveredCases(ps[i], caseNames, covered); i = i + 1 }
    }
    case _ -> {}
  }
}

// Does any unguarded arm of the match supply an irrefutable catch-all?  Guarded
// arms never count (the guard may fail at runtime).
func armsHaveCatchAll(arms: in List[MatchArm], caseNames: in List[String]): Bool {
  var i = 0
  while i < arms.count {
    match arms[i].guard {
      case None    -> if patternIsCatchAll(arms[i].pattern, caseNames) { return true }
      case Some(_) -> {}
    }
    i = i + 1
  }
  false
}

func joinStrs(xs: in List[String], sep: in String): String {
  if xs.count == 0 { return "" }
  var s = xs[0]
  var i = 1
  while i < xs.count { s = s + sep + xs[i]; i = i + 1 }
  s
}

// Is `pt` a primitive whose value space is unbounded (so a match is exhaustive
// only via a catch-all)?  Bool is finite and handled separately; Unit/Never are
// skipped (a one-value / zero-value space needs no wildcard rule here).
func isUnboundedScalar(pt: in PrimType): Bool {
  match pt {
    case PtByte   -> true
    case PtInt    -> true
    case PtLong   -> true
    case PtUInt   -> true
    case PtULong  -> true
    case PtNat    -> true
    case PtFloat  -> true
    case PtDouble -> true
    case PtChar   -> true
    case PtString -> true
    case _        -> false
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
          case _ -> {}
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
    case PRecord(_, _, _)   -> true
    case PConstructor(_, a) -> a.count > 0
    case PParen(ip)         -> patternCracksRepr(ip)
    case POr(ps) -> {
      var any = false
      var i = 0
      while i < ps.count {
        if patternCracksRepr(ps[i]) { any = true }
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
func checkOpaquePatternHiding(tbl: in SymbolTable, diag: in List[Diagnostic], st: in Type, arms: in List[MatchArm]): Unit {
  match importedOpaqueName(tbl, st) {
    case None -> {}
    case Some(nm) -> {
      var i = 0
      while i < arms.count {
        if patternCracksRepr(arms[i].pattern) {
          diag.add(errorDiagnostic("T0102",
            "cannot pattern-match the representation of opaque type '" + nm +
            "' outside its declaring package", arms[i].pattern.span))
        }
        i = i + 1
      }
    }
  }
}

func checkMatchExhaustive(
  tbl:  in SymbolTable,
  diag: in List[Diagnostic],
  st0:  in Type,
  arms: in List[MatchArm],
  span: in Span
): Unit {
  val st = unrefine(st0)
  match st {
    case TyError  -> {}        // scrutinee type unknown — already diagnosed
    case TyVar(_) -> {}        // generic type parameter — cannot enumerate
    case TyPrim(pt) -> {
      match pt {
        case PtBool -> {
          val noNames: List[String] = newList()
          if not armsHaveCatchAll(arms, noNames) {
            var sawTrue  = false
            var sawFalse = false
            var i = 0
            while i < arms.count {
              match arms[i].guard {
                case Some(_) -> {}
                case None ->
                  match arms[i].pattern.kind {
                    case PLiteral(lit) ->
                      match lit {
                        case LBool(b) -> if b { sawTrue = true } else { sawFalse = true }
                        case _        -> {}
                      }
                    case _ -> {}
                  }
              }
              i = i + 1
            }
            if not (sawTrue and sawFalse) {
              val missing: List[String] = newList()
              if not sawTrue  { missing.add("true") }
              if not sawFalse { missing.add("false") }
              diag.add(errorDiagnostic("T0016",
                "non-exhaustive match on Bool: missing " + joinStrs(missing, ", ") +
                " (add a `_` arm or cover both)", span))
            }
          }
        }
        case _ ->
          if isUnboundedScalar(pt) {
            val noNames: List[String] = newList()
            if not armsHaveCatchAll(arms, noNames) {
              diag.add(errorDiagnostic("T0016",
                "non-exhaustive match on " + renderType(st) +
                ": add a wildcard `_` arm", span))
            }
          }
      }
    }
    case _ ->
      match finiteCaseNames(tbl, st) {
        case None -> {}        // not a finite-case type — skip
        case Some(caseNames) -> {
          if not armsHaveCatchAll(arms, caseNames) {
            val covered: List[String] = newList()
            var i = 0
            while i < arms.count {
              match arms[i].guard {
                case None    -> collectCoveredCases(arms[i].pattern, caseNames, covered)
                case Some(_) -> {}
              }
              i = i + 1
            }
            val missing: List[String] = newList()
            var c = 0
            while c < caseNames.count {
              if not listContainsStr(covered, caseNames[c]) { missing.add(caseNames[c]) }
              c = c + 1
            }
            if missing.count > 0 {
              diag.add(errorDiagnostic("T0016",
                "non-exhaustive match on " + renderType(st) +
                ": missing case(s) " + joinStrs(missing, ", "), span))
            }
          }
        }
      }
  }
}

func inferBinop(
  tbl:  in SymbolTable,
  diag: in List[Diagnostic],
  op:   in BinOp,
  lhs:  in Type,
  rhs:  in Type,
  span: in Span
): Type {
  match op {
    case BAdd -> {
      match lhs {
        case TyPrim(pt) ->
          match pt {
            case PtString -> return TyPrim(pt = PtString)
            case _        -> {}
          }
        case _ -> {}
      }
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Add", lhs)
      if not lhsOk {
        diag.add(errorDiagnostic("T0030",
          "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span))
      }
      // TODO(#1891): the `val addEquiv = …; if not addEquiv { … }` shape
      // avoids inlining the `typeEquiv` call inside the `if` directly, which
      // would otherwise route through the PConstructor MObject codegen bug.
      val addEquiv = typeEquiv(lhs, rhs)
      if not addEquiv {
        diag.add(errorDiagnostic("T0031",
          "arithmetic operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      lhs
    }
    case BSub -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Sub", lhs)
      if not lhsOk {
        diag.add(errorDiagnostic("T0030",
          "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span))
      }
      if not typeEquiv(lhs, rhs) {
        diag.add(errorDiagnostic("T0031",
          "arithmetic operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      lhs
    }
    case BMul -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Mul", lhs)
      if not lhsOk {
        diag.add(errorDiagnostic("T0030",
          "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span))
      }
      if not typeEquiv(lhs, rhs) {
        diag.add(errorDiagnostic("T0031",
          "arithmetic operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      lhs
    }
    case BDiv -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Div", lhs)
      if not lhsOk {
        diag.add(errorDiagnostic("T0030",
          "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span))
      }
      if not typeEquiv(lhs, rhs) {
        diag.add(errorDiagnostic("T0031",
          "arithmetic operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      lhs
    }
    case BMod -> {
      val lhsOk = isNumericType(lhs) or hasDerive(tbl, "Mod", lhs)
      if not lhsOk {
        diag.add(errorDiagnostic("T0030",
          "left operand of arithmetic operator is not numeric (got " + renderType(lhs) + ")", span))
      }
      if not typeEquiv(lhs, rhs) {
        diag.add(errorDiagnostic("T0031",
          "arithmetic operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      lhs
    }
    case BEq -> {
      if not typeEquiv(lhs, rhs) {
        diag.add(errorDiagnostic("T0032",
          "equality operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case BNeq -> {
      if not typeEquiv(lhs, rhs) {
        diag.add(errorDiagnostic("T0032",
          "equality operands must have the same type (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case BLt -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs)
      if not lhsOk or not typeEquiv(lhs, rhs) {
        diag.add(errorDiagnostic("T0033",
          "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case BLte -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs)
      if not lhsOk or not typeEquiv(lhs, rhs) {
        diag.add(errorDiagnostic("T0033",
          "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case BGt -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs)
      if not lhsOk or not typeEquiv(lhs, rhs) {
        diag.add(errorDiagnostic("T0033",
          "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case BGte -> {
      val lhsOk = isOrderedType(lhs) or hasDerive(tbl, "Compare", lhs)
      if not lhsOk or not typeEquiv(lhs, rhs) {
        diag.add(errorDiagnostic("T0033",
          "comparison operands must be matching ordered types (got " + renderType(lhs) + " and " + renderType(rhs) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case BAnd -> {
      if not typeEquiv(lhs, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0034",
          "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span))
      }
      if not typeEquiv(rhs, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0034",
          "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case BOr -> {
      if not typeEquiv(lhs, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0034",
          "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span))
      }
      if not typeEquiv(rhs, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0034",
          "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case BXor -> {
      if not typeEquiv(lhs, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0034",
          "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span))
      }
      if not typeEquiv(rhs, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0034",
          "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case BImplies -> {
      if not typeEquiv(lhs, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0034",
          "left operand of logical operator must be Bool (got " + renderType(lhs) + ")", span))
      }
      if not typeEquiv(rhs, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0034",
          "right operand of logical operator must be Bool (got " + renderType(rhs) + ")", span))
      }
      TyPrim(pt = PtBool)
    }
    case BCoalesce -> {
      match lhs {
        case TyNullable(inner) -> {
          if not typeEquiv(inner, rhs) {
            diag.add(errorDiagnostic("T0035",
              "?? RHS type " + renderType(rhs) + " must match the nullable's inner type " + renderType(inner), span))
          }
          inner
        }
        case TyError -> TyError
        case _ -> {
          diag.add(errorDiagnostic("T0035",
            "?? LHS must be a nullable type (got " + renderType(lhs) + ")", span))
          rhs
        }
      }
    }
  }
}

func inferPrefix(
  diag:  in List[Diagnostic],
  op:    in PrefixOp,
  inner: in Type,
  span:  in Span
): Type {
  match op {
    case PreNeg -> {
      if not isNumericType(inner) {
        diag.add(errorDiagnostic("T0036",
          "unary minus requires a numeric operand (got " + renderType(inner) + ")", span))
      }
      inner
    }
    case PreNot -> {
      if not typeEquiv(inner, TyPrim(pt = PtBool)) {
        diag.add(errorDiagnostic("T0037",
          "'not' requires a Bool operand (got " + renderType(inner) + ")", span))
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
      if name == "length" { return Some(value = TyPrim(pt = PtInt)) }
      None
    }
    case TyArray(_, _) -> {
      if name == "length" { return Some(value = TyPrim(pt = PtInt)) }
      None
    }
    case TyPrim(pt) ->
      match pt {
        case PtString -> {
          if name == "length"  { return Some(value = TyPrim(pt = PtInt)) }
          if name == "isEmpty" { return Some(value = TyPrim(pt = PtBool)) }
          None
        }
        case _ -> None
      }
    case TyException -> {
      if name == "message"  { return Some(value = TyPrim(pt = PtString)) }
      if name == "typeName" { return Some(value = TyPrim(pt = PtString)) }
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
  if name == "toByte"   { return Some(value = PtByte) }
  if name == "toInt"    { return Some(value = PtInt) }
  if name == "toLong"   { return Some(value = PtLong) }
  if name == "toChar"   { return Some(value = PtChar) }
  if name == "toDouble" { return Some(value = PtDouble) }
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
    case TyPrim(pt) ->
      match pt {
        case PtByte   -> true
        case PtInt    -> true
        case PtLong   -> true
        case PtDouble -> true
        case PtChar   -> true
        case _        -> false
      }
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
    case TyPrim(pt) ->
      match pt {
        case PtString -> true
        case PtBool   -> true
        case PtUnit   -> true
        case _        -> false
      }
    case _ -> false
  }
}

// Element type produced by indexing `recv[i]` (#1901 part B).  `slice[T]` and
// `array[N,T]` yield `T`; `String` yields `Char`; `List[T]` yields `T` and
// `Map[K,V]` yields `V` (both modelled as `TyUser` with resolved type args).
// An unknown / non-indexable receiver yields `TyError` (lenient — the codegen
// owns the runtime behaviour for exotic receivers).
func indexElementType(recvRaw: in Type): Type {
  match unrefine(recvRaw) {
    case TySlice(elem)    -> elem
    case TyArray(_, elem) -> elem
    case TyPrim(pt) ->
      match pt {
        case PtString -> TyPrim(pt = PtChar)
        case _        -> TyError
      }
    case TyUser(_, nm, targs) -> {
      if nm == "List" and targs.count == 1 { targs[0] }
      else if nm == "Map" and targs.count == 2 { targs[1] }
      else { TyError }
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
      case _ -> {}
    }
    i = i + 1
  }
  result
}

record FieldEntry {
  name: String
  ty:   Type
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
      case _ -> {}
    }
    i = i + 1
  }
}

func inferMember(
  tbl:  in SymbolTable,
  diag: in List[Diagnostic],
  recvRaw: in Type,
  name: in String,
  span: in Span
): Type {
  val recv = unrefine(recvRaw)
  match recv {
    case TyUser(tid, _, _) -> {
      val fs = fieldsOfRecord(tbl, tid)
      var i = 0
      while i < fs.count {
        if fs[i].name == name { return fs[i].ty }
        i = i + 1
      }
      TyError
    }
    case TyError -> TyError
    case _ -> {
      match builtinMember(recv, name) {
        case Some(t) -> t
        case None    -> TyError
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Expression path resolution.
// ─────────────────────────────────────────────────────────────────────────────

func resolveExprPath(
  sc:   in Scope,
  tbl:  in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  path: in ModulePath,
  span: in Span
): Type {
  if path.segments.count != 1 {
    return TyError
  }
  val name = path.segments[0]
  match scopeTryFind(sc, name) {
    case Some(b) -> { return b.ty }
    case None    -> {}
  }
  match mapGet(sigs, name) {
    case Some(sig) -> {
      // #1484: a function resolves via `sigs` (no visibility there) — consult
      // the symbol table for the same name to enforce cross-package visibility.
      match symTableTryFindOne(tbl, name) {
        case Some(sym) -> checkImportedVisibility(sym, span, diag)
        case None      -> {}
      }
      val pts: List[Type] = newList()
      var i = 0
      while i < sig.params.count {
        pts.add(sig.params[i].ty)
        i = i + 1
      }
      return TyFunction(params = pts, ret = sig.returnTy, isAsync = sig.isAsync)
    }
    case None -> {}
  }
  match codegenBuiltinType(name) {
    case Some(t) -> return t
    case None    -> {}
  }
  match symTableTryFindOne(tbl, name) {
    case Some(sym) -> checkImportedVisibility(sym, span, diag)
    case None    -> {
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
      if name == "Result" and args.count >= 1 { args[0] }
      else if name == "Option" and args.count >= 1 { args[0] }
      else { TyError }
    }
    case _ -> TyError
  }
}

// #1487 (§5.2): the expression behind a call argument.
func callArgExpr(arg: in CallArg): Expr {
  match arg {
    case CAPositional(ae)  -> ae
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
    case EPath(p) ->
      if p.segments.count == 1 {
        match scopeTryFind(sc, p.segments[0]) {
          case Some(b) -> b.isMutable     // a local binding must be mutable
          case None    -> true            // not a local (global / unknown) — accept
        }
      } else { true }                     // qualified path — accept
    case EMember(_, _) -> true            // field access — potential l-value
    case EIndex(_, _)  -> true            // element access — potential l-value
    case _             -> false           // literal / call / operator / … — not an l-value
  }
}

func modeNeedsLValue(m: in ParamMode): Bool {
  match m {
    case PMOut   -> true
    case PMInout -> true
    case PMIn    -> false
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
    case TyPrim(pt) ->
      match pt {
        case PtString -> false
        case PtUnit   -> false
        case PtNever  -> false
        case _        -> true
      }
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5a. Record / opaque construction (#1483 record-ctor, #1485 opaque hiding).
// ─────────────────────────────────────────────────────────────────────────────

record CtorField {
  name:       String
  ty:         Type
  hasDefault: Bool
}

func ctorIsGeneric(sym: in Symbol): Bool {
  match sym.kind {
    case DKRecord(_, rd)     -> match rd.generics { case Some(_) -> true; case None -> false }
    case DKExposedRec(_, rd) -> match rd.generics { case Some(_) -> true; case None -> false }
    case DKOpaque(_, od)     -> match od.generics { case Some(_) -> true; case None -> false }
    case _                   -> false
  }
}

func ctorIsOpaque(sym: in Symbol): Bool {
  match sym.kind { case DKOpaque(_, _) -> true; case _ -> false }
}

func fieldHasName(fields: in List[CtorField], name: in String): Bool {
  var i = 0
  while i < fields.count {
    if fields[i].name == name { return true }
    i = i + 1
  }
  false
}

// Append the constructor fields of a record/opaque member list to `out`
// (mirrors `extractRecordFields`).  A field with a default is optional.
func collectCtorFieldsFromRecord(tbl: in SymbolTable, ctx: in GenericContext, scratch: in List[Diagnostic], members: in List[RecordMember], acc: in List[CtorField]): Unit {
  var i = 0
  while i < members.count {
    match members[i] {
      case RMField(fd) -> {
        val t = resolveType(tbl, ctx, scratch, fd.ty)
        var hasDef = false
        match fd.dflt { case Some(_) -> { hasDef = true } case None -> {} }
        acc.add(CtorField(name = fd.name, ty = t, hasDefault = hasDef))
      }
      case _ -> {}
    }
    i = i + 1
  }
}

func collectCtorFieldsFromOpaque(tbl: in SymbolTable, ctx: in GenericContext, scratch: in List[Diagnostic], members: in List[OpaqueMember], acc: in List[CtorField]): Unit {
  var i = 0
  while i < members.count {
    match members[i] {
      case OMField(fd) -> {
        val t = resolveType(tbl, ctx, scratch, fd.ty)
        var hasDef = false
        match fd.dflt { case Some(_) -> { hasDef = true } case None -> {} }
        acc.add(CtorField(name = fd.name, ty = t, hasDefault = hasDef))
      }
      case _ -> {}
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
    case DKRecord(_, rd)     -> { collectCtorFieldsFromRecord(tbl, ctx, scratch, rd.members, acc); true }
    case DKExposedRec(_, rd) -> { collectCtorFieldsFromRecord(tbl, ctx, scratch, rd.members, acc); true }
    case DKOpaque(_, od)     -> { collectCtorFieldsFromOpaque(tbl, ctx, scratch, od.members, acc); true }
    case _                   -> false
  }
}

func ctorResultType(sym: in Symbol): Type {
  if ctorIsGeneric(sym) { return TyError }
  match symbolTypeIdOpt(sym) {
    case Some(tid) -> TyUser(id = tid, name = sym.name, args = newList())
    case None      -> TyError
  }
}

func inferConstruction(
  tbl:  in SymbolTable,
  diag: in List[Diagnostic],
  sym:  in Symbol,
  args: in List[CallArg],
  span: in Span
): Type {
  val resultTy = ctorResultType(sym)
  // #1485: an opaque type's representation is hidden — it cannot be constructed
  // from outside its declaring package.
  if ctorIsOpaque(sym) and sym.isImported {
    diag.add(errorDiagnostic("T0100",
      "cannot construct opaque type '" + sym.name +
      "' outside its declaring package", span))
    return resultTy
  }
  // Named arguments must reference a real field (T0101).  Full arg validation
  // (missing-required, positional arity, value-type matching) is a follow-up.
  val fields: List[CtorField] = newList()
  val _ = collectCtorFields(tbl, sym, fields)
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(nm, _, asp) -> {
        if not fieldHasName(fields, nm) {
          diag.add(errorDiagnostic("T0101",
            "'" + sym.name + "' has no field '" + nm + "'", asp))
        }
      }
      case CAPositional(_) -> {}
    }
    i = i + 1
  }
  resultTy
}

func constructorSymbolOf(tbl: in SymbolTable, fn: in Expr): Option[Symbol] {
  match fn.kind {
    case EPath(p) ->
      if p.segments.count == 1 {
        match symTableTryFindOne(tbl, p.segments[0]) {
          case Some(sym) ->
            match sym.kind {
              case DKRecord(_, _)     -> Some(value = sym)
              case DKExposedRec(_, _) -> Some(value = sym)
              case DKOpaque(_, _)     -> Some(value = sym)
              case _                  -> None
            }
          case None -> None
        }
      } else { None }
    case _ -> None
  }
}

pub func inferExpr(
  sc:   in Scope,
  tbl:  in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  e:    in Expr
): Type {
  match e.kind {
    case ELiteral(lit) -> typeOfLiteral(lit)

    case EPath(path)   -> resolveExprPath(sc, tbl, sigs, diag, path, e.span)

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
      if elems.count == 0 { return TySlice(element = TyError) }
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
        if not typeEquiv(first, elemTs[j]) { allSame = false }
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
      val lt = inferExpr(sc, tbl, sigs, diag, l)
      val rt = inferExpr(sc, tbl, sigs, diag, r)
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
        case EMember(recvE, mname) ->
          match numericConvTarget(mname) {
            case Some(target) ->
              if args.count == 0 {
                val rt = inferExpr(sc, tbl, sigs, diag, recvE)
                if isNumericOrCharType(rt) { return TyPrim(pt = target) }
                // A `String`/`Bool`/`Unit` receiver can be neither converted nor
                // host a user method of this name — report it precisely.
                if isNonConvertiblePrimitive(rt) {
                  diag.add(errorDiagnostic("T0103",
                    "conversion method '" + mname + "' is not applicable to " + renderType(rt), recvE.span))
                }
                return TyError
              }
            case None -> {}
          }
        case _ -> {}
      }
      val fnT = inferExpr(sc, tbl, sigs, diag, fn)
      val argTypes: List[Type] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(ae)    -> argTypes.add(inferExpr(sc, tbl, sigs, diag, ae))
          case CANamed(_, ae, _)   -> argTypes.add(inferExpr(sc, tbl, sigs, diag, ae))
        }
        i = i + 1
      }
      // Try direct-sig lookup first.
      val directSig = findDirectSig(sc, sigs, fn, args.count)
      match directSig {
        case Some(sig) -> {
          if sig.params.count != args.count {
            diag.add(errorDiagnostic("T0042",
              "expected " + toString(sig.params.count) + " argument(s), got " + toString(args.count), e.span))
          } else {
            var k = 0
            while k < sig.params.count {
              val p = sig.params[k]
              if not typeEquiv(p.ty, argTypes[k]) {
                diag.add(errorDiagnostic("T0043",
                  "argument type " + renderType(argTypes[k]) + " does not match parameter type " + renderType(p.ty), e.span))
              }
              // #1487 (§5.2): a value-type `out`/`inout` argument must be a
              // writable l-value (reference-type by-ref params are mutated in
              // place — see `isByRefValueType`).
              if modeNeedsLValue(p.mode) and isByRefValueType(p.ty)
                 and not argIsValidByRefTarget(sc, callArgExpr(args[k])) {
                diag.add(errorDiagnostic("T0085",
                  "argument for `out`/`inout` parameter '" + p.name +
                  "' must be a mutable l-value (a `var`, or an `out`/`inout` binding)", e.span))
              }
              k = k + 1
            }
          }
          sig.returnTy
        }
        case None ->
          match constructorSymbolOf(tbl, fn) {
            case Some(ctorSym) -> inferConstruction(tbl, diag, ctorSym, args, e.span)
            case None ->
              match fnT {
                case TyFunction(paramTypes, ret, _) -> {
                  if paramTypes.count != argTypes.count {
                    diag.add(errorDiagnostic("T0042",
                      "expected " + toString(paramTypes.count) + " argument(s), got " + toString(argTypes.count), e.span))
                  } else {
                    var k = 0
                    while k < paramTypes.count {
                      if not typeEquiv(paramTypes[k], argTypes[k]) {
                        diag.add(errorDiagnostic("T0043",
                          "argument type " + renderType(argTypes[k]) + " does not match parameter type " + renderType(paramTypes[k]), e.span))
                      }
                      k = k + 1
                    }
                  }
                  ret
                }
                case TyError -> TyError
                case _ -> {
                  diag.add(errorDiagnostic("T0044",
                    "called value of non-function type " + renderType(fnT), e.span))
                  TyError
                }
              }
          }
      }
    }

    case EMember(recv, name) -> {
      val rt = inferExpr(sc, tbl, sigs, diag, recv)
      inferMember(tbl, diag, rt, name, e.span)
    }

    case EPropagate(inner) -> {
      // `e?` unwraps the operand to its success type (`Result[T,E]`/`Option[T]` -> `T`); the `Lyric.Propagate` pass owns the lowering and F0020.
      val it = inferExpr(sc, tbl, sigs, diag, inner)
      propagateUnwrap(it)
    }

    case EAwait(inner)  -> inferExpr(sc, tbl, sigs, diag, inner)
    case EYield(inner)  -> { inferExpr(sc, tbl, sigs, diag, inner); TyPrim(PtUnit) }
    case ESpawn(inner)  -> inferExpr(sc, tbl, sigs, diag, inner)
    case EOld(inner)    -> inferExpr(sc, tbl, sigs, diag, inner)

    case ESelf          -> TySelf
    // `result` in an `ensures:` clause has the enclosing function's declared
    // return type, carried on the scope (D081).
    case EResult        -> sc.returnTy

    // Index expression `recv[i]` yields the receiver's element type (#1901
    // part B): `slice[T]`/`array[N,T]` -> `T`, `String` -> `Char`,
    // `List[T]` -> `T`, `Map[K,V]` -> `V`.  An unknown / non-indexable receiver
    // stays `TyError` (lenient — codegen owns exotic receivers).  The index
    // expressions are inferred so their own diagnostics surface.
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
    case ELambda(_, _)  -> TyError
    case EIf(_, _, _, _) -> TyError
    case EMatch(scrutinee, arms) -> {
      // Check exhaustiveness; branch-type unification (real match result type) is the next split.
      val st = inferExpr(sc, tbl, sigs, diag, scrutinee)
      checkMatchExhaustive(tbl, diag, st, arms, e.span)
      checkOpaquePatternHiding(tbl, diag, st, arms)
      TyError
    }
    // A value-position brace block / `unsafe { … }` has the type of its trailing
    // expression (or `Unit` if it ends in a statement, or `Never` if it diverges)
    // — `checkBlock` walks the statements (binding locals) and returns that type.
    case EBlock(blk)    -> checkBlock(sc, tbl, sigs, sc.genericNames, sc.returnTy, diag, blk)
    case EUnsafe(blk)   -> checkBlock(sc, tbl, sigs, sc.genericNames, sc.returnTy, diag, blk)
    case ETry(_)        -> TyError
    case EForall(_, _, _) -> TyError
    case EExists(_, _, _) -> TyError
    case EAssign(_, _, _) -> TyError
    case ERange(_)      -> TyError
    case EInterpolated(_) -> TyPrim(pt = PtString)
    case EError         -> TyError
  }
}

func findDirectSig(
  sc:    in Scope,
  sigs:  in Map[String, ResolvedSignature],
  fn:    in Expr,
  arity: in Int
): Option[ResolvedSignature] {
  match fn.kind {
    case EPath(path) -> {
      if path.segments.count != 1 { return None }
      val name = path.segments[0]
      // Prefer the arity-qualified signature so overloaded functions
      // (e.g. Std.String.substring/2 and substring/3) dispatch to the
      // overload that actually matches the call's arity.  The bare
      // `name` key carries the first-in-wins entry from
      // `addSigsFromItems` (and stays as a fallback for callers that
      // expect the historical lookup) — using it before the arity
      // key would misfire as T0042 every time a 3-arg call hits a
      // bare key registered for the 2-arg overload.
      val arityKey = name + "/" + toString(arity)
      match mapGet(sigs, arityKey) {
        case Some(s) -> Some(value = s)
        case None    -> mapGet(sigs, name)
      }
    }
    case _ -> None
  }
}
