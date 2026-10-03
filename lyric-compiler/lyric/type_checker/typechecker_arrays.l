//! typechecker_arrays.l — the checker's half of `array[N, T]` (D167): the
//! zero value (T0156), the writable-place rule for element writes (T0157),
//! the index rule and bounds-check elision, element-wise `==`, and the sites
//! `Lyric.ContractElaborator.lowerArrays` rewrites.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

pub func arrayLengthOf(t: in Type): Option[Int] {
  match unrefine(t) {
    case TyArray(sz, _) -> sz
    case _ -> None
  }
}

pub func isArrayType(t: in Type): Bool {
  match unrefine(t) {
    case TyArray(_, _) -> true
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Place reads and copies.
//
// The invariant (D167): every writable place (a `var` local, an `out`/`inout`
// parameter, a `var` field) exclusively owns its array storage, and storage
// reachable from an immutable place (a `val`, an `in` parameter, a non-`var`
// field, a collection element, a temporary) is never mutated.  So:
//   (a) an array STORED into a writable place is copied, unless it is a
//       bracket literal of scalars (a fresh value);
//   (b) an array READ FROM a writable place is copied when the read escapes
//       (bound, passed to any parameter, returned, captured, stored, iterated);
//   (c) a read of an immutable place is never copied;
// and a read used immediately (index receiver, `.length`, `.toSlice()`
// receiver, `==` operand, assignment target, `inout`/`out` argument) is
// exempt.  Copies are decided here, where the type is concrete, so a generic
// callee needs nothing.
// ─────────────────────────────────────────────────────────────────────────────
func isPlaceExprKind(e: in Expr): Bool {
  match e.kind {
    case EPath(_) -> true
    case EMember(_, _) -> true
    case EIndex(_, _) -> true
    case ESelf -> true
    case _ -> false
  }
}

/// The array operand's site, its type spelled (a type variable by name).
pub func arraySiteOf(tbl: in SymbolTable, t: in Type, sp: in Span): Option[ArraySite] {
  match unrefine(t) {
    case TyArray(sz, el) -> match sz {
      case Some(n) -> match typeExprForRefWithVars(tbl, t, sp) {
        case Some(at) -> Some(
          value = ArraySite(
            len = n,
            arrayType = Some(value = at),
            elemType = typeExprForRefWithVars(
              tbl,
              el,
              sp
            ),
            span = sp
          )
        )
        case None -> None
      }
      case None -> None
    }
    case _ -> None
  }
}

// A copy site for an array whose length or spelling is unknown: kept so
// `reportUnspellableArrayCopies` rejects it (T0160) rather than share storage.
func poisonedArraySite(sp: in Span): ArraySite {
  ArraySite(len = 0 - 1, arrayType = None, elemType = None, span = sp)
}

func addArrayCopySite(tbl: in SymbolTable, e: in Expr, t: in Type): Unit {
  val key = recordCopySiteKey(e.span)
  if tbl.arrayCopySites.containsKey(key) or tbl.arrayCopyExempt.containsKey(key) {
    return
  }
  val site = match arraySiteOf(tbl, t, e.span) {
    case Some(s) -> s
    // A value-generic length: the copy is recorded when the specialisation
    // that binds it is checked.
    case None -> if inValueGenericBody(tbl) { return } else { poisonedArraySite(e.span) }
  }
  tbl.arrayCopySites.add(key, site)
}

/// A bracket literal adopted as an array where no binding, parameter or field
/// gives it that type (a distinct type's `from` argument): recorded as a copy
/// site, which `lowerArrays` lowers to a typed binding of the literal.
pub func noteArrayLiteralType(tbl: in SymbolTable, e: in Expr, t: in Type): Unit {
  match peelParens(e).kind {
    case EList(_) -> addArrayCopySite(tbl, e, t)
    case _ -> ()
  }
}

/// A read of an array out of a place: copied when the place is writable (or
/// unknown) and the read escapes, i.e. unless its consumer exempts it.
pub func noteArrayPlaceRead(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  e: in Expr,
  t: in Type,
): Unit {
  if not isPlaceExprKind(e) or not isArrayType(t) {
    return
  }
  if placeClass(sc, tbl, sigs, e) == 0 {
    return
  }
  addArrayCopySite(tbl, e, t)
}

func peelParens(e: in Expr): Expr {
  match e.kind {
    case EParen(inner) -> peelParens(inner)
    case _ -> e
  }
}

/// An array value `e` of type `t` stored into a writable place (a `var`
/// initialiser or assignment, a record construction or `.copy` argument): it
/// is copied unless it is already a copy or a fresh bracket literal of
/// scalars.  Idempotent per expression.
pub func noteArrayStore(tbl: in SymbolTable, e: in Expr, t: in Type): Unit {
  if not isArrayType(t) {
    return
  }
  val v = peelParens(e)
  match v.kind {
    case EList(_) -> match unrefine(t) { case TyArray(_, el) -> if not isArrayType(el) { return }; case _ -> () }
    case _ -> ()
  }
  addArrayCopySite(tbl, v, t)
}

/// `e` is only inspected or written through (an index receiver, a `.length`
/// or `==` operand, an assignment target, an `inout` argument), never stored:
/// it is not copied.
pub func exemptArrayCopy(tbl: in SymbolTable, e: in Expr): Unit {
  val key = recordCopySiteKey(e.span)
  if not tbl.arrayCopyExempt.containsKey(key) {
    tbl.arrayCopyExempt.add(key, true)
  }
  if tbl.arrayCopySites.containsKey(key) {
    tbl.arrayCopySites.remove(key)
  }
  match e.kind {
    case EParen(inner) -> exemptArrayCopy(tbl, inner)
    case _ -> ()
  }
}

/// T0160 for each copy of an array whose length is not known (value-generic
/// `N`, D167 item 6) or whose type cannot be spelled: sharing its storage
/// would break value semantics.
pub func reportUnspellableArrayCopies(tbl: in SymbolTable, diag: in List[Diagnostic]): Unit {
  for k in mapKeys(tbl.arrayCopySites) {
    match mapGet(tbl.arrayCopySites, k) {
      case Some(site) -> match site.arrayType {
        case Some(_) -> ()
        case None -> diag.add(
          errorDiagnostic(
            "T0160",
            "this array cannot be copied: its length is not a compile-time constant or its type cannot be written out here; copying it would share its storage (D167)",
            site.span
          )
        )
      }
      case None -> ()
    }
  }
}

/// T0113 for a member an array does not have: it has `.length`, `.toSlice()`,
/// indexing and `==`.
pub func arrayNoMember(t: in Type, name: in String, sp: in Span): Diagnostic {
  errorDiagnostic(
    "T0113",
    "no member '" + name + "' on type '" + renderType(t) +
      "' (an array has `.length`, `.toSlice()`, indexing, `for` and `==`; use a `slice[T]` or `List[T]` for anything else)",
    sp
  )
}

/// `a.toSlice` not called: the copy is made when the call runs, so it is not
/// a function value of its own.
pub func arrayToSliceNotCalled(t: in Type, sp: in Span): Diagnostic {
  errorDiagnostic(
    "T0113",
    "`toSlice` on '" + renderType(t) +
      "' is called, not referenced: write `a.toSlice()`, or `{ -> a.toSlice() }` for a function that copies the array when it is called",
    sp
  )
}

/// Inside a value-generic function's body (D167 item 6): an array whose
/// length is a value generic parameter is checked again, with the length
/// bound, in each specialisation, so its length-dependent operations are
/// neither recorded nor reported here.
pub func inValueGenericBody(tbl: in SymbolTable): Bool = tbl.valueGenericBodies.count > 0

pub func arrayUnknownLength(t: in Type, sp: in Span): Diagnostic {
  errorDiagnostic(
    "T0160",
    "the length of " + renderType(t) +
      " is not a compile-time constant (an array length set by a record's value generic parameter is not supported yet, #8090)",
    sp
  )
}

/// `a.toSlice()` on an array (the call's callee `fn` is the member
/// expression): recorded for `lowerArrays`, and the receiver is not copied.
pub func noteArrayToSlice(tbl: in SymbolTable, fn: in Expr, recvTy: in Type): Unit {
  match fn.kind {
    case EMember(recv, _) -> match arraySiteOf(tbl, recvTy, fn.span) {
      case Some(site) -> {
        exemptArrayCopy(tbl, recv)
        val key = recordCopySiteKey(fn.span)
        if not tbl.arraySliceSites.containsKey(key) {
          tbl.arraySliceSites.add(key, site)
        }
      }
      case None -> ()
    }
    case _ -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Indexing.
// ─────────────────────────────────────────────────────────────────────────────
// The `0 ..= N-1` check of an index of range type `lo ..= hi`.
// `unsigned` when the bounds are `ULong` literals, carried as two's-complement
// patterns (a bound above Long.MaxValue is negative, #7839): they are ordered
// as `checkClosed` orders them.
func boundsWithin(lo: in Option[Long], hi: in Option[Long], n: in Int, unsigned: in Bool): Bool {
  if n <= 0 {
    return false
  }
  match lo {
    case Some(l) -> match hi {
      case Some(h) -> if unsigned {
        not ulongLessThan(n.toLong() - 1i64, h)
      } else {
        l >= 0i64 and h <= n.toLong() - 1i64
      }
      case None -> false
    }
    case None -> false
  }
}

func indexBoundsOfRange(rb: in RangeBound): Tuple2OptLong {
  Tuple2OptLong(lo = rangeLo(rb), hi = rangeHiClosed(rb))
}

record Tuple2OptLong {
  lo: Option[Long]
  hi: Option[Long]
}

// The closed upper bound of a range, when its upper endpoint is a literal.
func rangeHiClosed(rb: in RangeBound): Option[Long] {
  match rb {
    case RBClosed(_, hi) -> exprLiteralLong(hi)
    case RBHalfOpen(_, hi, _) -> match exprLiteralLong(hi) { case Some(h) -> Some(value = h - 1i64); case None -> None }
    case RBLowerOpen(hi) -> exprLiteralLong(hi)
    case RBUpperOpen(_) -> None
  }
}

// How an array is indexed by a value of type `idxTy`: `kind` is `""` for an
// integer, `"distinct"` for a distinct type over one, `"bad"` otherwise;
// `wide` when the integer is not an `Int` (it is range checked as a `Long`
// and narrowed); `elide` only for a NAMED range subtype whose bounds lie in
// `0 ..= n - 1`: every value of such a type was made through its checked
// `from`, which an inline `Int range 0 ..= 3` annotation is not (record
// fields, lambda parameters and collection elements do not enforce it).
record IndexKind {
  kind: String
  elide: Bool
  wide: Bool
}

func badIndex(): IndexKind {
  IndexKind(kind = "bad", elide = false, wide = false)
}

// 0 not an integer, 1 an `Int`, 2 another integer type.
func intFlavor(t: in Type): Int {
  match unrefine(t) {
    case TyPrim(pt) -> match pt {
      case PtInt -> 1
      case PtLong -> 2
      case PtByte -> 2
      case PtUInt -> 2
      case PtULong -> 2
      case _ -> 0
    }
    case _ -> 0
  }
}

func isULongType(t: in Type): Bool {
  match unrefine(t) {
    case TyPrim(pt) -> match pt { case PtULong -> true; case _ -> false }
    case _ -> false
  }
}

func classifyArrayIndex(tbl: in SymbolTable, idxTy: in Type, n: in Int): IndexKind {
  match idxTy {
    case TyRefined(u, _, _, _) -> match intFlavor(u) {
      case 1 -> IndexKind(kind = "", elide = false, wide = false)
      case 2 -> IndexKind(kind = "", elide = false, wide = true)
      case _ -> badIndex()
    }
    case TyPrim(_) -> match intFlavor(idxTy) {
      case 1 -> IndexKind(kind = "", elide = false, wide = false)
      case 2 -> IndexKind(kind = "", elide = false, wide = true)
      case _ -> badIndex()
    }
    case TyUser(tid, _, _) -> match symTableTypeSymbolOf(tbl, tid) {
      case Some(sym) -> match sym.kind {
        case DKDistinctType(_, dt) -> {
          match dt.generics {
            case Some(_) -> return badIndex()
            case None -> ()
          }
          val saved = enterDeclaringScope(tbl, sym)
          val scratch: List[Diagnostic] = newList()
          val under = resolveType(tbl, newGenericContext(), scratch, dt.underlying)
          restoreScope(tbl, saved)
          val flavor = intFlavor(under)
          if flavor == 0 {
            return badIndex()
          }
          val wide = flavor == 2
          match dt.rangeClause {
            case Some(rb) -> {
              val b = indexBoundsOfRange(rb)
              IndexKind(kind = "distinct", elide = boundsWithin(b.lo, b.hi, n, isULongType(under)), wide = wide)
            }
            case None -> IndexKind(kind = "distinct", elide = false, wide = wide)
          }
        }
        case _ -> badIndex()
      }
      case None -> badIndex()
    }
    case TyError -> IndexKind(kind = "", elide = false, wide = false)
    case TyVar(_) -> IndexKind(kind = "", elide = false, wide = false)
    case _ -> badIndex()
  }
}

/// An index `recv[idx]` whose receiver is an `array[N, T]` (D167): the
/// index must be an integer or an integer range subtype (T0158), and the
/// access is recorded for `lowerArrays`, with its bounds check elided only
/// when the index is a literal in range or a named range subtype within
/// `0 ..= N - 1`.
pub func noteArrayIndex(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  recvTy: in Type,
  idx: in Expr,
  idxTy: in Type,
  span: in Span,
): Unit {
  val n = match arrayLengthOf(recvTy) {
    case Some(n) -> n
    case None -> {
      if inValueGenericBody(tbl) {
        return
      }
      diag.add(
        errorDiagnostic(
          "T0160",
          "cannot index " + renderType(recvTy) +
            ": its length is not a compile-time constant (an array length set by a record's value generic parameter is not supported yet, #8090)",
          span
        )
      )
      return
    }
  }
  val litIdx = match peelParens(idx).kind {
    case ELiteral(lit) -> match lit {
      case LInt(v, sfx, _) -> match sfx {
        case I32 -> Some(value = v)
        case NoIntSuffix -> Some(value = v)
        case _ -> None
      }
      case _ -> None
    }
    case _ -> None
  }
  val ik = match litIdx {
    case Some(v) -> IndexKind(kind = "", elide = v >= 0i64 and v < n.toLong(), wide = false)
    case None -> classifyArrayIndex(tbl, idxTy, n)
  }
  if ik.kind == "bad" {
    diag.add(
      errorDiagnostic(
        "T0158",
        "an array index must be an integer or a range subtype of one (got " + renderType(idxTy) + ")",
        idx.span
      )
    )
    return
  }
  val key = recordCopySiteKey(span)
  if tbl.arrayIndexSites.containsKey(key) {
    tbl.arrayIndexSites.remove(key)
  }
  tbl.arrayIndexSites.add(
    key,
    ArrayIndexSite(len = n, elide = ik.elide, unwrap = ik.kind == "distinct", wide = ik.wide)
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Writable places (T0157).
// ─────────────────────────────────────────────────────────────────────────────
// Whether a field `name` of a record, opaque or protected type is `var`;
// `None` when the type or field cannot be resolved.
func fieldIsVar(tbl: in SymbolTable, recvTy: in Type, name: in String): Option[Bool] {
  match unrefine(recvTy) {
    case TyUser(tid, _, _) -> match symTableTypeSymbolOf(tbl, tid) {
      case Some(rs) -> match rs.kind {
        case DKRecord(_, rd) -> recordDeclFieldIsVar(rd, name)
        case DKExposedRec(_, rd) -> recordDeclFieldIsVar(rd, name)
        case DKOpaque(_, od) -> {
          for m in od.members {
            match m {
              case OMField(fd) -> if fd.name == name { return Some(value = fd.isMutable) }
              case _ -> ()
            }
          }
          None
        }
        case DKProtected(_, pd) -> {
          for m in pd.members {
            match m {
              case PMField(pf) -> match pf {
                case PFVar(fname, _, _, _, _, _) -> if fname == name { return Some(value = true) }
                case PFLet(fname, _, _, _, _, _) -> if fname == name { return Some(value = false) }
                case PFImmutable(fd) -> if fd.name == name { return Some(value = fd.isMutable) }
              }
              case _ -> ()
            }
          }
          None
        }
        case _ -> None
      }
      case None -> None
    }
    case _ -> None
  }
}

func recordDeclFieldIsVar(rd: in RecordDecl, name: in String): Option[Bool] {
  for m in rd.members {
    match m {
      case RMField(fd) -> if fd.name == name { return Some(value = fd.isMutable) }
      case _ -> ()
    }
  }
  None
}

// What owns the storage `place` denotes: 0 an immutable place (a `val`, an
// `in` parameter, a non-`var` field, a collection element), 1 a writable one
// (a `var` local, an `out`/`inout` parameter, a `var` field, an element of a
// writable array), 2 one the checker cannot resolve.
func placeClass(sc: in Scope, tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], place: in Expr): Int {
  match place.kind {
    case EParen(inner) -> placeClass(sc, tbl, sigs, inner)
    case EPath(p) -> if p.segments.count == 1 {
      match scopeTryFind(sc, p.segments[0]) {
        case Some(b) -> if b.isMutable { 1 } else { 0 }
        case None -> 2
      }
    } else {
      2
    }
    case ESelf -> 1
    case EMember(recv, name) -> {
      val scratch: List[Diagnostic] = newList()
      val rt = inferExpr(sc, tbl, sigs, scratch, recv)
      match fieldIsVar(tbl, rt, name) {
        case Some(isVar) -> if isVar { 1 } else { 0 }
        case None -> 2
      }
    }
    case EIndex(recv, _) -> {
      val scratch: List[Diagnostic] = newList()
      val rt = inferExpr(sc, tbl, sigs, scratch, recv)
      if isArrayType(rt) {
        placeClass(sc, tbl, sigs, recv)
      } else {
        0
      }
    }
    case _ -> 0
  }
}

/// Whether an element of an array may be written through `place`.
pub func arrayPlaceWritable(
  sc: in Scope, tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], place: in Expr
): Bool {
  placeClass(sc, tbl, sigs, place) == 1
}

/// T0157: `target` is `a[i]` (or `a[i][j]`, ...) on an array, so the write
/// needs a writable place.
pub func checkArrayElementWrite(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  target: in Expr,
): Unit {
  match target.kind {
    case EParen(inner) -> checkArrayElementWrite(sc, tbl, sigs, diag, inner)
    case EIndex(recv, _) -> {
      val scratch: List[Diagnostic] = newList()
      val rt = inferExpr(sc, tbl, sigs, scratch, recv)
      if isArrayType(rt) and not arrayPlaceWritable(sc, tbl, sigs, recv) {
        diag.add(
          errorDiagnostic(
            "T0157",
            "cannot write an element of " + renderType(rt) +
              " here: an array element is written through a `var` local, an `out`/`inout` parameter or a `var` field (a collection element or an unresolved place is not one)",
            target.span
          )
        )
      }
    }
    case _ -> ()
  }
}

/// T0157 for an array passed as an `inout`/`out` argument: the callee writes
/// the caller's storage, so the argument must be a writable variable or field.
/// An element of an array passed that way is written like `a[i] = v`, so its
/// array must be a writable place.
pub func checkArrayByRefArg(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  arg: in Expr,
  argTy: in Type,
  span: in Span,
): Unit {
  if not isArrayType(argTy) {
    checkArrayElementWrite(sc, tbl, sigs, diag, arg)
    return
  }
  val plain = match peelParens(arg).kind { case EPath(_) -> true; case EMember(_, _) -> true; case _ -> false }
  if not plain or not arrayPlaceWritable(sc, tbl, sigs, arg) {
    diag.add(
      errorDiagnostic(
        "T0157",
        "an `out`/`inout` array argument must be a writable variable or field (a `var` local, an `out`/`inout` parameter or a `var` field), not an element or an expression",
        span
      )
    )
  }
}

/// The temporaries an overflow-checked compound assignment to an array
/// element binds (D163): only the index of each level (and an impure record
/// the array is a field of), never the array, which a native `val` would copy.
pub func arrayCompoundTemps(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  target: in Expr,
  span: in Span,
): Option[CompoundTemps] {
  val scratch: List[Diagnostic] = newList()
  match target.kind {
    case EIndex(recv, _) -> {
      val rt = inferExpr(sc, tbl, sigs, scratch, recv)
      if not isArrayType(rt) {
        return None
      }
      // The array chain's root: `c.hits` in `c.hits[i][j]`.
      var root = recv
      var going = true
      while going {
        match root.kind {
          case EIndex(inner, _) -> {
            root = inner
          }
          case EParen(inner) -> {
            root = inner
          }
          case _ -> {
            going = false
          }
        }
      }
      var rootRecvType: Option[TypeExpr] = None
      match root.kind {
        case EMember(owner, _) -> if not isOverflowPureTarget(owner) {
          rootRecvType = typeExprForRef(tbl, inferExpr(sc, tbl, sigs, scratch, owner), span)
        }
        case _ -> ()
      }
      Some(value = CompoundTemps(recvType = rootRecvType, indexType = None, arrayChain = true))
    }
    case _ -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The zero value (T0156).
// ─────────────────────────────────────────────────────────────────────────────
func zeroLit(lit: in Literal, sp: in Span): Expr = mkExpr(ELiteral(lit = lit), sp)

func pathExprOf(segs: in List[String], sp: in Span): Expr {
  mkExpr(EPath(path = ModulePath(segments = segs, span = sp)), sp)
}

func typeSegsOf(te: in Option[TypeExpr]): Option[List[String]] {
  match te {
    case Some(t) -> match t.kind {
      case TRef(path) -> Some(value = path.segments)
      case TGenericApp(head, _) -> Some(value = head.segments)
      case _ -> None
    }
    case None -> None
  }
}

func rangeBoundContainsZero(rb: in RangeBound): Bool {
  val b = indexBoundsOfRange(rb)
  val loOk = match rb {
    case RBUpperOpen(_) -> match b.lo { case Some(l) -> l <= 0i64; case None -> false }
    case RBLowerOpen(_) -> true
    case _ -> match b.lo { case Some(l) -> l <= 0i64; case None -> false }
  }
  val hiOk = match rb {
    case RBUpperOpen(_) -> true
    case _ -> match b.hi { case Some(h) -> h >= 0i64; case None -> false }
  }
  loOk and hiOk
}

/// The expression that builds the zero value of `t` (D167 item 1), or `None`
/// when `t` has none: a scalar primitive, an enum (its first case), a
/// distinct type over a type with a zero whose range contains it, a record
/// whose fields all have zeros or defaults, or an array of a type with a zero.
pub func zeroExprFor(tbl: in SymbolTable, t: in Type, sp: in Span, depth: in Int): Option[Expr] {
  if depth > 8 {
    return None
  }
  match t {
    case TyRefined(u, lo, hi, inc) -> {
      val loOk = match lo { case Some(l) -> l <= 0i64; case None -> true }
      val hiOk = match hi { case Some(h) -> if inc { h >= 0i64 } else { h > 0i64 }; case None -> true }
      if loOk and hiOk {
        zeroExprFor(tbl, u, sp, depth)
      } else {
        None
      }
    }
    case TyPrim(pt) -> match pt {
      case PtInt -> Some(value = zeroLit(LInt(value = 0i64, suffix = I32, raw = ""), sp))
      case PtLong -> Some(value = zeroLit(LInt(value = 0i64, suffix = I64, raw = ""), sp))
      case PtByte -> Some(value = zeroLit(LInt(value = 0i64, suffix = U8, raw = ""), sp))
      case PtUInt -> Some(value = zeroLit(LInt(value = 0i64, suffix = U32, raw = ""), sp))
      case PtULong -> Some(value = zeroLit(LInt(value = 0i64, suffix = U64, raw = ""), sp))
      case PtFloat -> Some(value = zeroLit(LFloat(value = 0.0, suffix = F32, raw = ""), sp))
      case PtDouble -> Some(value = zeroLit(LFloat(value = 0.0, suffix = F64, raw = ""), sp))
      case PtBool -> Some(value = zeroLit(LBool(value = false), sp))
      case PtChar -> Some(value = zeroLit(LChar(codepoint = 0), sp))
      case _ -> None
    }
    case TyArray(sz, el) -> match sz {
      case Some(_) -> match zeroExprFor(tbl, el, sp, depth + 1) {
        case Some(z) -> match typeExprForRef(tbl, t, sp) {
          case Some(arrTe) -> {
            val fillFn = mkExpr(
              ETypeApp(fn = pathExprOf(listOf1(arrayFillIntrinsic()), sp), args = listOf1Arg(TAType(ty = arrTe))),
              sp
            )
            Some(value = mkExpr(ECall(fn = fillFn, args = listOf1CallArg(CAPositional(expr = z))), sp))
          }
          case None -> None
        }
        case None -> None
      }
      case None -> None
    }
    case TyUser(tid, _, targs) -> {
      if targs.count > 0 {
        return None
      }
      match symTableTypeSymbolOf(tbl, tid) {
        case Some(sym) -> match sym.kind {
          case DKEnum(_, ed) -> {
            if ed.cases.count == 0 {
              return None
            }
            match typeSegsOf(typeExprForRef(tbl, t, sp)) {
              case Some(segs) -> {
                val full: List[String] = newList()
                for sg in segs {
                  full.add(sg)
                }
                full.add(ed.cases[0].name)
                Some(value = pathExprOf(full, sp))
              }
              case None -> None
            }
          }
          case DKDistinctType(_, dt) -> {
            match dt.generics {
              case Some(_) -> return None
              case None -> ()
            }
            match dt.rangeClause {
              case Some(rb) -> if not rangeBoundContainsZero(rb) { return None }
              case None -> ()
            }
            val saved = enterDeclaringScope(tbl, sym)
            val scratch: List[Diagnostic] = newList()
            val under = resolveType(tbl, newGenericContext(), scratch, dt.underlying)
            restoreScope(tbl, saved)
            match zeroExprFor(tbl, under, sp, depth + 1) {
              case Some(z) -> match typeSegsOf(typeExprForRef(tbl, t, sp)) {
                case Some(segs) -> {
                  // Spelled as the parser spells a static member call.
                  val callee = mkExpr(EMember(receiver = pathExprOf(segs, sp), memberName = "from"), sp)
                  Some(value = mkExpr(ECall(fn = callee, args = listOf1CallArg(CAPositional(expr = z))), sp))
                }
                case None -> None
              }
              case None -> None
            }
          }
          case DKRecord(_, rd) -> zeroRecord(tbl, t, tid, rd, sp, depth)
          case _ -> None
        }
        case None -> None
      }
    }
    case _ -> None
  }
}

func listOf1(s: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(s)
  xs
}

func listOf1Arg(a: in TypeArg): List[TypeArg] {
  val xs: List[TypeArg] = newList()
  xs.add(a)
  xs
}

func listOf1CallArg(a: in CallArg): List[CallArg] {
  val xs: List[CallArg] = newList()
  xs.add(a)
  xs
}

func zeroRecord(
  tbl: in SymbolTable, t: in Type, tid: in TypeId, rd: in RecordDecl, sp: in Span, depth: in Int
): Option[Expr] {
  match rd.generics {
    case Some(_) -> return None
    case None -> ()
  }
  // A zero value is built by a synthesised constructor call, which no
  // invariant check wraps: a record with an invariant has no zero (T0156).
  for m in rd.members {
    match m {
      case RMInvariant(_) -> return None
      case _ -> ()
    }
  }
  val segs = match typeSegsOf(typeExprForRef(tbl, t, sp)) { case Some(s) -> s; case None -> return None }
  val fields = fieldsOfRecord(tbl, tid)
  val args: List[CallArg] = newList()
  for m in rd.members {
    match m {
      case RMField(fd) -> match fd.dflt {
        case Some(_) -> ()
        case None -> {
          var fty: Type = TyError
          for fe in fields {
            if fe.name == fd.name {
              fty = fe.ty
            }
          }
          match zeroExprFor(tbl, fty, sp, depth + 1) {
            case Some(z) -> args.add(CANamed(name = fd.name, value = z, span = sp))
            case None -> return None
          }
        }
      }
      case _ -> ()
    }
  }
  Some(value = mkExpr(ECall(fn = pathExprOf(segs, sp), args = args), sp))
}

/// A declaration of array type `declT` with no initializer is filled with its
/// zero value: recorded under `key` for `lowerArrays`, or T0156 when the
/// element type has no zero.
pub func noteArrayZeroInit(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  declT: in Type,
  key: in String,
  sp: in Span,
  what: in String,
): Unit {
  val zsp = Span(startPos = sp.startPos, endPos = sp.startPos)
  match unrefine(declT) {
    case TyArray(Some(_), _) -> match zeroExprFor(tbl, declT, zsp, 0) {
      case Some(z) -> if not tbl.arrayZeroSites.containsKey(key) {
        tbl.arrayZeroSites.add(key, z)
      }
      case None -> diag.add(
        errorDiagnostic(
          "T0156",
          what + " of type " + renderType(declT) +
            " has no initializer and its element type has no zero value (a `String`, a union, a function, a range excluding zero or a record with an invariant); give it an initializer",
          sp
        )
      )
    }
    case _ -> ()
  }
}

/// Whether a field of type `t` with no default is filled with a zero value
/// (D167): it is an array whose element type has one.
pub func fieldHasZeroDefault(tbl: in SymbolTable, t: in Type, sp: in Span): Bool {
  match unrefine(t) {
    case TyArray(Some(_), _) -> match zeroExprFor(tbl, t, sp, 0) { case Some(_) -> true; case None -> false }
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Equality (D167 item 4).
// ─────────────────────────────────────────────────────────────────────────────
/// The element-wise comparison of two `array[N, T]` values, or the path of
/// the function-typed element that has no `==` (T0153).
pub func buildArrayEqSite(tbl: in SymbolTable, span: in Span, t: in Type, negate: Bool): Result[ArrayEqSite, String] {
  match unrefine(t) {
    case TyArray(Some(n), el) -> {
      val elem: ArrayEqElem = match unrefine(el) {
        case TyFunction(_, _, _) -> return Err(error = "element")
        case TyArray(Some(_), _) -> match buildArrayEqSite(tbl, span, el, false) {
          case Err(bad) -> return Err(error = "element." + bad)
          case Ok(site) -> AEArray(site = site)
        }
        case _ -> if isEqWrapperType(tbl, el) {
          match buildEqShape(tbl, span, el, 0) {
            case Err(bad) -> return Err(error = "element." + bad)
            case Ok(shape) -> AEShape(shape = shape)
          }
        } else if isStructuralEqRecord(tbl, el) {
          match buildRecordEqSite(tbl, span, el, false) {
            case Err(bad) -> return Err(error = "element." + bad)
            case Ok(site) -> AERecord(site = site)
          }
        } else {
          match distinctFromPath(tbl, el) {
            case Some(_) -> AEValue
            case None -> AEPlain
          }
        }
      }
      Ok(
        value = ArrayEqSite(
          len = n,
          arrayType = typeExprForRef(tbl, t, span),
          elemType = typeExprForRef(tbl, el, span),
          elem = elem,
          negate = negate
        )
      )
    }
    case _ -> Err(error = "")
  }
}

/// `==` / `!=` on two arrays of one type.
pub func recordArrayEq(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  lhs: in Type,
  rhs: in Type,
  negate: Bool,
  span: in Span,
): Unit {
  if not typeEquiv(lhs, rhs) {
    return
  }
  match unrefine(lhs) {
    case TyArray(Some(_), _) -> match buildArrayEqSite(tbl, span, lhs, negate) {
      case Err(bad) -> diag.add(
        if bad.endsWith("~") {
          eqTooDeepDiagnostic(lhs, span)
        } else {
          errorDiagnostic(
            "T0153",
            "`" + renderType(lhs) + "` has no `==`: its `" + bad + "` is a function, and functions cannot be compared",
            span
          )
        }
      )
      case Ok(site) -> {
        val key = recordCopySiteKey(span)
        if not tbl.arrayEqSites.containsKey(key) {
          tbl.arrayEqSites.add(key, site)
        }
      }
    }
    case TyArray(None, _) -> if not inValueGenericBody(tbl) { diag.add(arrayUnknownLength(lhs, span)) }
    case _ -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Derived code (T0159).
// ─────────────────────────────────────────────────────────────────────────────
/// Whether a value of type `t` holds an array anywhere: directly, in an
/// `Option`/tuple/slice/generic argument, or in a field of a nested record or
/// union.  Derived `Equals`/`Hash`/`Show`/ordering would treat it by
/// reference.
///
/// Exact at any depth: every recursive path runs through a named type, which
/// `seen` visits once, and the rest of a resolved type is a finite tree.
pub func typeHoldsArray(tbl: in SymbolTable, t: in Type, seen: in List[Int]): Bool {
  match t {
    case TyArray(_, _) -> true
    case TyRefined(u, _, _, _) -> typeHoldsArray(tbl, u, seen)
    case TyNullable(inner) -> typeHoldsArray(tbl, inner, seen)
    case TySlice(el) -> typeHoldsArray(tbl, el, seen)
    case TyTuple(elems) -> {
      for el in elems {
        if typeHoldsArray(tbl, el, seen) {
          return true
        }
      }
      false
    }
    case TyUser(tid, _, args) -> {
      for a in args {
        if typeHoldsArray(tbl, a, seen) {
          return true
        }
      }
      for sid in seen {
        if sid == tid.id {
          return false
        }
      }
      seen.add(tid.id)
      match symTableTypeSymbolOf(tbl, tid) {
        case Some(sym) -> match sym.kind {
          case DKRecord(_, _) -> recordFieldsHoldArray(tbl, tid, seen)
          case DKExposedRec(_, _) -> recordFieldsHoldArray(tbl, tid, seen)
          case DKDistinctType(_, _) -> {
            val scratch: List[Diagnostic] = newList()
            match distinctMemberType(tbl, scratch, t, "value", unknownSpan()) {
              case Some(under) -> typeHoldsArray(tbl, under, seen)
              case None -> false
            }
          }
          case DKUnion(_, ud) -> {
            val saved = enterDeclaringScopeIfForeign(tbl, sym)
            val ctx = declGenericContext(ud.generics)
            val scratch: List[Diagnostic] = newList()
            var found = false
            for c in ud.cases {
              for f in c.fields {
                val fte = match f { case UFNamed(_, ty, _) -> ty; case UFPos(ty, _) -> ty }
                if typeHoldsArray(tbl, resolveType(tbl, ctx, scratch, fte), seen) {
                  found = true
                }
              }
            }
            restoreScope(tbl, saved)
            found
          }
          case _ -> false
        }
        case None -> false
      }
    }
    case _ -> false
  }
}

func recordFieldsHoldArray(tbl: in SymbolTable, tid: in TypeId, seen: in List[Int]): Bool {
  for f in fieldsOfRecord(tbl, tid) {
    if typeHoldsArray(tbl, f.ty, seen) {
      return true
    }
  }
  false
}

/// Whether `t` mentions a type variable anywhere.
pub func typeMentionsTyVar(t: in Type): Bool {
  match t {
    case TyVar(_) -> true
    case TyRefined(u, _, _, _) -> typeMentionsTyVar(u)
    case TyNullable(inner) -> typeMentionsTyVar(inner)
    case TySlice(el) -> typeMentionsTyVar(el)
    case TyArray(_, el) -> typeMentionsTyVar(el)
    case TyTuple(elems) -> {
      for el in elems {
        if typeMentionsTyVar(el) {
          return true
        }
      }
      false
    }
    case TyUser(_, _, args) -> {
      for a in args {
        if typeMentionsTyVar(a) {
          return true
        }
      }
      false
    }
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// `==` through a tuple, union or distinct type that holds an array (D167).
// ─────────────────────────────────────────────────────────────────────────────
func unknownSpan(): Span {
  val p = Position(offset = 0, line = 0, column = 0)
  Span(startPos = p, endPos = p)
}

/// A tuple, a union (`Option` and `Result` included) or a distinct type that
/// holds an array: its `==` is built from its parts' (`EqShape`), because the
/// host's equality would compare the array by reference.
pub func isEqWrapperType(tbl: in SymbolTable, t: in Type): Bool {
  val u = unrefine(t)
  val kind = match u {
    case TyTuple(_) -> true
    case TyUser(tid, _, _) -> match symTableTypeSymbolOf(tbl, tid) {
      case Some(sym) -> match sym.kind {
        case DKUnion(_, _) -> true
        case DKDistinctType(_, _) -> true
        case _ -> false
      }
      case None -> false
    }
    case _ -> false
  }
  if not kind {
    return false
  }
  val seen: List[Int] = newList()
  typeHoldsArray(tbl, u, seen)
}

/// The `EqShape` of `t`: how `==` compares a value of that type element by
/// element wherever an array lies inside it.  `Err` carries the path of a
/// function-typed part (T0153) or `"~"` for a shape too deep or recursive.
pub func buildEqShape(tbl: in SymbolTable, span: in Span, t: in Type, depth: in Int): Result[EqShape, String] {
  // A recursive type that holds an array has no finite shape; the record and
  // array sites built below restart `depth`, so the nesting is counted here.
  if tbl.eqShapeNesting.count > 24 {
    return Err(error = "~")
  }
  tbl.eqShapeNesting.add(depth)
  val r = buildEqShapeAt(tbl, span, t, depth)
  tbl.eqShapeNesting.removeAt(tbl.eqShapeNesting.count - 1)
  r
}

func buildEqShapeAt(tbl: in SymbolTable, span: in Span, t: in Type, depth: in Int): Result[EqShape, String] {
  val u = unrefine(t)
  val seen: List[Int] = newList()
  if not typeHoldsArray(tbl, u, seen) {
    return Ok(value = ESPlain)
  }
  if depth > 6 {
    return Err(error = "~")
  }
  match u {
    case TyFunction(_, _, _) -> Err(error = "value")
    case TyArray(Some(_), _) -> match buildArrayEqSite(tbl, span, u, false) {
      case Err(bad) -> Err(error = bad)
      case Ok(site) -> Ok(value = ESArray(site = site))
    }
    case TyTuple(elems) -> {
      val shapes: List[EqShape] = newList()
      for el in elems {
        match buildEqShape(tbl, span, el, depth + 1) {
          case Err(bad) -> return Err(error = bad)
          case Ok(sh) -> shapes.add(sh)
        }
      }
      Ok(value = ESTuple(elems = shapes))
    }
    case TyUser(tid, _, targs) -> {
      if isStructuralEqRecord(tbl, u) {
        return match buildRecordEqSite(tbl, span, u, false) {
          case Err(bad) -> Err(error = bad)
          case Ok(site) -> Ok(value = ESRecord(site = site))
        }
      }
      match symTableTypeSymbolOf(tbl, tid) {
        case Some(sym) -> match sym.kind {
          case DKDistinctType(_, _) -> {
            val scratch: List[Diagnostic] = newList()
            match distinctMemberType(tbl, scratch, u, "value", span) {
              case Some(under) -> match buildEqShape(tbl, span, under, depth + 1) {
                case Err(bad) -> Err(error = bad)
                case Ok(sh) -> Ok(value = ESDistinct(inner = sh))
              }
              case None -> Ok(value = ESPlain)
            }
          }
          case DKUnion(_, ud) -> buildUnionEqShape(tbl, span, u, tid, targs, sym, ud, depth)
          case _ -> Ok(value = ESPlain)
        }
        case None -> Ok(value = ESPlain)
      }
    }
    case _ -> Ok(value = ESPlain)
  }
}

func buildUnionEqShape(
  tbl: in SymbolTable,
  span: in Span,
  u: in Type,
  tid: in TypeId,
  targs: in List[Type],
  sym: in Symbol,
  ud: in UnionDecl,
  depth: in Int,
): Result[EqShape, String] {
  val gnames = unionDeclGenericNames(ud)
  val typeSegs = match typeSegsOf(typeExprForRefWithVars(tbl, u, span)) {
    case Some(segs) -> segs
    case None -> return Err(error = "~")
  }
  val cases: List[EqUnionCase] = newList()
  val scratch: List[Diagnostic] = newList()
  for uc in ud.cases {
    val ftys = unionCaseFieldTypes(tbl, scratch, uc, gnames, sym.originPackage)
    val shapes: List[EqShape] = newList()
    for ft in ftys {
      match buildEqShape(tbl, span, substituteTyVars(ft, gnames, targs), depth + 1) {
        case Err(bad) -> return Err(error = bad)
        case Ok(sh) -> shapes.add(sh)
      }
    }
    // The case is written bare when the file reaches it that way, as `Some`
    // and `None` are, and qualified by its union otherwise.
    val bare = match symTableTryFindOne(tbl, uc.name) {
      case Some(found) -> match found.kind { case DKUnionCase(pid, _) -> typeIdEq(pid, tid); case _ -> false }
      case None -> false
    }
    val head: List[String] = newList()
    if not bare {
      for sg in typeSegs {
        head.add(sg)
      }
    }
    head.add(uc.name)
    cases.add(EqUnionCase(head = head, fields = shapes))
  }
  Ok(value = ESUnion(cases = cases))
}

pub func eqTooDeepDiagnostic(t: in Type, span: in Span): Diagnostic {
  errorDiagnostic(
    "T0160",
    "`" + renderType(t) +
      "` has no `==`: it holds an array too deeply or recursively for the comparison to be built; compare the parts",
    span
  )
}

/// `==` / `!=` on a tuple, union or distinct type that holds an array.
pub func recordWrapEq(
  tbl: in SymbolTable,
  diag: in List[Diagnostic],
  lhs: in Type,
  rhs: in Type,
  negate: Bool,
  span: in Span,
): Unit {
  if not typeEquiv(lhs, rhs) or not isEqWrapperType(tbl, lhs) {
    return
  }
  match buildEqShape(tbl, span, lhs, 0) {
    case Err(bad) -> if bad.endsWith("~") {
      diag.add(eqTooDeepDiagnostic(lhs, span))
    } else {
      diag.add(
        errorDiagnostic(
          "T0153",
          "`" + renderType(lhs) + "` has no `==`: its `" + bad + "` is a function, and functions cannot be compared",
          span
        )
      )
    }
    case Ok(shape) -> {
      val key = recordCopySiteKey(span)
      if not tbl.wrapEqSites.containsKey(key) {
        tbl.wrapEqSites.add(
          key,
          WrapEqSite(shape = shape, valueType = typeExprForRefWithVars(tbl, lhs, span), negate = negate)
        )
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Value-generic array lengths (D167 item 6).
// ─────────────────────────────────────────────────────────────────────────────
/// The value generic parameters of `generics`, in order.
pub func valueGenericNames(generics: in Option[GenericParams]): List[String] {
  val acc: List[String] = newList()
  match generics {
    case Some(gp) -> {
      for p in gp.params {
        match p {
          case GPValue(n, _, _) -> acc.add(n)
          case _ -> ()
        }
      }
    }
    case None -> ()
  }
  acc
}

/// The value generic parameter an `array[N, T]` length names, if any.
pub func arrayLengthParam(size: in TypeArg, vps: in List[String]): Option[String] {
  val name = match size {
    case TAType(te) -> match te.kind {
      case TRef(p) -> if p.segments.count == 1 { p.segments[0] } else { "" }
      case _ -> ""
    }
    case TAValue(ve) -> match ve.kind {
      case EPath(p) -> if p.segments.count == 1 { p.segments[0] } else { "" }
      case _ -> ""
    }
  }
  if name.length > 0 and vps.contains(name) {
    Some(value = name)
  } else {
    None
  }
}

/// The value-generic function a call names, when it has one: the length
/// parameters of its arrays are bound from the call's arguments.
pub func valueGenericCallee(tbl: in SymbolTable, fn: in Expr, argCount: in Int): Option[FunctionDecl] {
  val name = match fn.kind {
    case EPath(p) -> if p.segments.count == 1 { p.segments[0] } else { return None }
    case _ -> return None
  }
  for sym in symTableTryFindAll(tbl, name) {
    match sym.kind {
      case DKFunc(decl) -> if decl.params.count >= argCount and valueGenericNames(decl.generics).count > 0 {
        return Some(value = decl)
      }
      case _ -> ()
    }
  }
  None
}

/// Binds each value generic parameter `te` names as an array length to the
/// length of the matching array in `t` (the argument's type).  A parameter
/// bound to two different lengths is recorded in `conflicts`.
pub func bindArrayLengths(
  te: in TypeExpr,
  t: in Type,
  vps: in List[String],
  bound: in Map[String, Int],
  conflicts: in List[String],
): Unit {
  match te.kind {
    case TParen(inner) -> bindArrayLengths(inner, t, vps, bound, conflicts)
    case TArray(size, elemTe) -> match unrefine(t) {
      case TyArray(sz, elemTy) -> {
        match arrayLengthParam(size, vps) {
          case Some(p) -> match sz {
            case Some(n) -> match mapGet(bound, p) {
              case Some(prev) -> if prev != n and not conflicts.contains(p) {
                conflicts.add(p)
              }
              case None -> bound.add(p, n)
            }
            case None -> ()
          }
          case None -> ()
        }
        bindArrayLengths(elemTe, elemTy, vps, bound, conflicts)
      }
      case _ -> ()
    }
    case TSlice(elemTe) -> match unrefine(t) {
      case TySlice(elemTy) -> bindArrayLengths(elemTe, elemTy, vps, bound, conflicts)
      case _ -> ()
    }
    case TTuple(tes) -> match unrefine(t) {
      case TyTuple(tys) -> if tes.count == tys.count {
        var i = 0
        while i < tes.count {
          bindArrayLengths(tes[i], tys[i], vps, bound, conflicts)
          i = i + 1
        }
      }
      case _ -> ()
    }
    case TGenericApp(_, targs) -> match unrefine(t) {
      case TyUser(_, _, tys) -> if targs.count == tys.count {
        var i = 0
        while i < targs.count {
          match targs[i] {
            case TAType(ate) -> bindArrayLengths(ate, tys[i], vps, bound, conflicts)
            case TAValue(_) -> ()
          }
          i = i + 1
        }
      }
      case _ -> ()
    }
    case _ -> ()
  }
}

/// `t` (the instantiated result type of a value-generic call) with each
/// array whose length `te` spells as a bound value generic parameter given
/// that length.
pub func withBoundArrayLengths(te: in TypeExpr, t: in Type, vps: in List[String], bound: in Map[String, Int]): Type {
  match te.kind {
    case TParen(inner) -> withBoundArrayLengths(inner, t, vps, bound)
    case TArray(size, elemTe) -> match t {
      case TyArray(sz, elemTy) -> {
        val len = match sz {
          case Some(_) -> sz
          case None -> match arrayLengthParam(size, vps) { case Some(p) -> mapGet(bound, p); case None -> None }
        }
        TyArray(size = len, element = withBoundArrayLengths(elemTe, elemTy, vps, bound))
      }
      case _ -> t
    }
    case TSlice(elemTe) -> match t {
      case TySlice(elemTy) -> TySlice(
        element = withBoundArrayLengths(elemTe, elemTy, vps, bound)
      )
      case _ -> t
    }
    case TTuple(tes) -> match t {
      case TyTuple(tys) -> if tes.count == tys.count {
        val acc: List[Type] = newList()
        var i = 0
        while i < tes.count {
          acc.add(withBoundArrayLengths(tes[i], tys[i], vps, bound))
          i = i + 1
        }
        TyTuple(elems = acc)
      } else {
        t
      }
      case _ -> t
    }
    case TGenericApp(_, targs) -> match t {
      case TyUser(id, nm, tys) -> if targs.count == tys.count {
        val acc: List[Type] = newList()
        var i = 0
        while i < targs.count {
          match targs[i] {
            case TAType(ate) -> acc.add(withBoundArrayLengths(ate, tys[i], vps, bound))
            case TAValue(_) -> acc.add(tys[i])
          }
          i = i + 1
        }
        TyUser(id = id, name = nm, args = acc)
      } else {
        t
      }
      case _ -> t
    }
    case _ -> t
  }
}
