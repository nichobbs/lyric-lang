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

// IMPORTANT: keep the recognised-name set in lock-step with
// `isCodegenBuiltinName` in `typechecker_checker.l` — that helper prevents
// imported stdlib signatures from shadowing the names registered here.
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

func builtinMember(recv: in Type, name: in String): Option[Type] {
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
  recv: in Type,
  name: in String,
  span: in Span
): Type {
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
    case Some(_) -> {}
    case None    -> {
      diag.add(errorDiagnostic("T0020", "unknown name '" + name + "'", span))
    }
  }
  TyError
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Top-level inference.
// ─────────────────────────────────────────────────────────────────────────────

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
              k = k + 1
            }
          }
          sig.returnTy
        }
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

    case EMember(recv, name) -> {
      val rt = inferExpr(sc, tbl, sigs, diag, recv)
      inferMember(tbl, diag, rt, name, e.span)
    }

    case EPropagate(inner) -> {
      val _ = inferExpr(sc, tbl, sigs, diag, inner)
      TyError
    }

    case EAwait(inner)  -> inferExpr(sc, tbl, sigs, diag, inner)
    case EYield(inner)  -> { inferExpr(sc, tbl, sigs, diag, inner); TyPrim(PtUnit) }
    case ESpawn(inner)  -> inferExpr(sc, tbl, sigs, diag, inner)
    case EOld(inner)    -> inferExpr(sc, tbl, sigs, diag, inner)

    case ESelf          -> TySelf
    case EResult        -> TyError

    case EIndex(_, _)   -> TyError
    case ETypeApp(_, _) -> TyError
    case ELambda(_, _)  -> TyError
    case EIf(_, _, _, _) -> TyError
    case EMatch(_, _)   -> TyError
    case EBlock(_)      -> TyError
    case EUnsafe(_)     -> TyError
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
