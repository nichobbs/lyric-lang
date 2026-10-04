//! `array[N, T]` operations (D167), lowered once for every backend.
//!
//! The type checker records each array operation it accepts
//! (`SymbolTable.arrayIndexSites`, `arrayLenSites`, `arraySliceSites`,
//! `arrayForSites`, `arrayCopySites`, `arrayZeroSites`) and `lowerArrays`
//! rewrites it into forms every backend already lowers, plus three
//! intrinsics only a backend can implement (`arrayFillIntrinsic`,
//! `arrayCopyIntrinsic`, `arrayUncheckedIntrinsic`):
//!
//!   a[i]          ->  a[__lyric_unchecked({
//!                        val __lyric_ai_<s>_<e>: Int = i
//!                        if __lyric_ai_<s>_<e> < 0 or __lyric_ai_<s>_<e> >= N {
//!                          panic("index " + <i>.toString() + " out of range for array[N]")
//!                        }
//!                        __lyric_ai_<s>_<e> })]
//!   a[i]  (the index's type proves it in 0 ..< N)  ->  a[__lyric_unchecked(i)]
//!   a.length      ->  N
//!   a.toSlice()   ->  { val a': array[N, T] = a; <copy into a new List>; .toArray() }
//!   for x in a    ->  { val a': array[N, T] = a; for i in 0 ..< N { val x = a'[i]; ... } }
//!   a  (stored)   ->  __lyric_array_copy[array[N, T]](a)
//!   var a: array[N, T]   ->   var a: array[N, T] = <zero value>
//!
//! The index stays an index, so `a[i] = v`, `a[i] += v` and `a[i][j] = v`
//! remain writes to a place.  `arraysToLists` then gives a backend whose
//! arrays are `List`s (dotnet and the JVM) the representation: every
//! `array[N, T]` becomes `List[T]` and the intrinsics become loops.
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

/// The sites `lowerArrays` rewrites, keyed by `recordCopySiteKey`.
pub record ArraySites {
  index: Map[String, ArrayIndexSite]
  len: Map[String, Int]
  slice: Map[String, ArraySite]
  forIter: Map[String, ArraySite]
  copy: Map[String, ArraySite]
  zero: Map[String, Expr]
  ctorZero: Map[String, List[CallArg]]
  /// The bracket literals typed as arrays, on a backend with typed primitive
  /// arrays only (empty elsewhere): one of a primitive element becomes
  /// `arrayOfIntrinsic` (#8041).
  literal: Map[String, TypeExpr] = newMap()
}

func arrayLiteralOfPrimitive(te: in TypeExpr): Bool {
  match te.kind {
    case TParen(inner) -> arrayLiteralOfPrimitive(inner)
    case TArray(_, el) -> primitiveArrayElement(el)
    case _ -> false
  }
}

pub func noArraySites(): ArraySites {
  ArraySites(
    index = newMap(),
    len = newMap(),
    slice = newMap(),
    forIter = newMap(),
    copy = newMap(),
    zero = newMap(),
    ctorZero = newMap()
  )
}

func arraySitesEmpty(sites: in ArraySites): Bool {
  sites.index.count == 0 and sites.len.count == 0 and sites.slice.count == 0 and sites.forIter.count == 0 and
    sites.copy.count == 0 and
    sites.zero.count == 0 and
    sites.ctorZero.count == 0 and
    sites.literal.count == 0
}

pub func lowerArrays(file: in SourceFile, sites: in ArraySites): SourceFile {
  if arraySitesEmpty(sites) {
    return file
  }
  val withZeros = fillFieldZeros(file, sites.zero)
  mapFileAndContracts(
    withZeros,
    { e: Expr -> rewriteArrayExpr(e, sites) },
    { s: Statement -> rewriteArrayStmt(s, sites) }
  )
}

// ── Field zero values ───────────────────────────────────────────────────────
func fillFieldZeros(file: in SourceFile, zeros: in Map[String, Expr]): SourceFile {
  if zeros.count == 0 {
    return file
  }
  val items: List[Item] = newList()
  for it in file.items {
    val kind: ItemKind = match it.kind {
      case IRecord(decl) -> IRecord(decl = zeroRecordFields(decl, zeros))
      case IExposedRec(decl) -> IExposedRec(decl = zeroRecordFields(decl, zeros))
      case IOpaque(decl) -> {
        val members: List[OpaqueMember] = newList()
        for m in decl.members {
          match m {
            case OMField(fd) -> members.add(OMField(field = zeroField(fd, zeros)))
            case other -> members.add(other)
          }
        }
        IOpaque(
          decl = OpaqueTypeDecl(
            name = decl.name,
            generics = decl.generics,
            whereClause = decl.whereClause,
            annotations = decl.annotations,
            members = members,
            hasBody = decl.hasBody,
            span = decl.span
          )
        )
      }
      case IProtected(decl) -> {
        val members: List[ProtectedMember] = newList()
        for m in decl.members {
          match m {
            case PMField(pf) -> members.add(PMField(field = zeroProtectedField(pf, zeros)))
            case other -> members.add(other)
          }
        }
        IProtected(
          decl = ProtectedTypeDecl(
            name = decl.name,
            generics = decl.generics,
            whereClause = decl.whereClause,
            members = members,
            span = decl.span
          )
        )
      }
      case other -> other
    }
    items.add(
      Item(
        docComments = it.docComments,
        annotations = it.annotations,
        visibility = it.visibility,
        kind = kind,
        span = it.span
      )
    )
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
}

func zeroProtectedField(pf: in ProtectedField, zeros: in Map[String, Expr]): ProtectedField {
  match pf {
    case PFVar(name, ty, init, docs, anns, sp) -> PFVar(
      name = name,
      ty = ty,
      init = zeroInit(init, sp, zeros),
      docComments = docs,
      annotations = anns,
      span = sp
    )
    case PFLet(name, ty, init, docs, anns, sp) -> PFLet(
      name = name,
      ty = ty,
      init = zeroInit(init, sp, zeros),
      docComments = docs,
      annotations = anns,
      span = sp
    )
    case PFImmutable(fd) -> PFImmutable(field = zeroField(fd, zeros))
  }
}

func zeroInit(init: in Option[Expr], sp: in Span, zeros: in Map[String, Expr]): Option[Expr] {
  match init {
    case Some(_) -> init
    case None -> match mapGet(zeros, recordCopySiteKey(sp)) { case Some(z) -> Some(value = z); case None -> None }
  }
}

func zeroField(fd: in FieldDecl, zeros: in Map[String, Expr]): FieldDecl {
  match fd.dflt {
    case Some(_) -> fd
    case None -> match mapGet(zeros, recordCopySiteKey(fd.span)) {
      case Some(z) -> FieldDecl(
        docComments = fd.docComments,
        annotations = fd.annotations,
        visibility = fd.visibility,
        isMutable = fd.isMutable,
        name = fd.name,
        ty = fd.ty,
        dflt = Some(value = z),
        span = fd.span,
        trailingAnnotationCount = fd.trailingAnnotationCount
      )
      case None -> fd
    }
  }
}

func zeroRecordFields(decl: in RecordDecl, zeros: in Map[String, Expr]): RecordDecl {
  val members: List[RecordMember] = newList()
  for m in decl.members {
    match m {
      case RMField(fd) -> members.add(RMField(field = zeroField(fd, zeros)))
      case other -> members.add(other)
    }
  }
  RecordDecl(
    name = decl.name,
    generics = decl.generics,
    whereClause = decl.whereClause,
    members = members,
    span = decl.span
  )
}

// ── Expressions ─────────────────────────────────────────────────────────────
func rewriteArrayExpr(e: in Expr, sites: in ArraySites): Expr {
  val key = recordCopySiteKey(e.span)
  var r: Expr = e
  match e.kind {
    case EIndex(recv, idxs) -> match mapGet(sites.index, key) {
      case Some(site) -> {
        if idxs.count == 1 {
          r = mkExpr(EIndex(receiver = recv, indices = oneExpr(checkedIndex(idxs[0], site, e.span))), e.span)
        }
      }
      case None -> ()
    }
    case EList(elems) -> match mapGet(sites.literal, key) {
      case Some(arrTe) -> if arrayLiteralOfPrimitive(arrTe) {
        val targs: List[TypeArg] = newList()
        targs.add(TAType(ty = arrTe))
        val callee = mkExpr(ETypeApp(fn = mkPath(arrayOfIntrinsic(), e.span), args = targs), e.span)
        val cargs: List[CallArg] = newList()
        for el in elems {
          cargs.add(CAPositional(expr = el))
        }
        r = mkExpr(ECall(fn = callee, args = cargs), e.span)
      }
      case None -> ()
    }
    case EMember(recv, _) -> match mapGet(sites.len, key) {
      case Some(n) -> {
        r = lengthOf(recv, n, e.span)
      }
      case None -> ()
    }
    // A construction that leaves out a zero-filled array field passes its
    // zero (D167, #8042).
    case ECall(fn, args) -> match mapGet(sites.ctorZero, key) {
      case Some(zeros) -> {
        val all: List[CallArg] = newList()
        for a in args {
          all.add(a)
        }
        for z in zeros {
          all.add(z)
        }
        r = mkExpr(ECall(fn = fn, args = all), e.span)
      }
      case None -> match fn.kind {
        case EMember(recv, name) -> if name == "toSlice" and args.count == 0 {
          match mapGet(sites.slice, recordCopySiteKey(fn.span)) {
            case Some(site) -> {
              r = toSliceOf(recv, site, e.span)
            }
            case None -> ()
          }
        }
        case _ -> ()
      }
    }
    case _ -> ()
  }
  match mapGet(sites.copy, key) {
    case Some(site) -> {
      r = copyOf(r, site, e.span)
    }
    case None -> ()
  }
  r
}

func oneExpr(e: in Expr): List[Expr] {
  val xs: List[Expr] = newList()
  xs.add(e)
  xs
}

func intLit(n: in Int, sp: in Span): Expr {
  mkExpr(ELiteral(lit = LInt(value = n.toLong(), suffix = I32, raw = "")), sp)
}

func intTypeExpr(sp: in Span): TypeExpr {
  val segs: List[String] = newList()
  segs.add("Int")
  TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = sp)), span = sp)
}

func boolTypeExpr(sp: in Span): TypeExpr {
  val segs: List[String] = newList()
  segs.add("Bool")
  TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = sp)), span = sp)
}

func callOf(fnName: in String, args: in List[Expr], sp: in Span): Expr {
  val cargs: List[CallArg] = newList()
  for a in args {
    cargs.add(CAPositional(expr = a))
  }
  mkExpr(ECall(fn = localRef(fnName, sp), args = cargs), sp)
}

/// `a[__lyric_unchecked(i)]`: the access whose bounds the lowering has
/// settled.
func uncheckedIndex(recv: in Expr, idx: in Expr, sp: in Span): Expr {
  mkExpr(EIndex(receiver = recv, indices = oneExpr(callOf(arrayUncheckedIntrinsic(), oneExpr(idx), sp))), sp)
}

// The index of `a[i]` with its bounds check, wrapped in the marker that
// tells a backend the access is already settled.
func checkedIndex(idx: in Expr, site: in ArrayIndexSite, sp: in Span): Expr {
  val wsp = syntheticSpan(sp)
  val i0 = if site.unwrap { mkExpr(EMember(receiver = idx, memberName = "value"), wsp) } else { idx }
  // An index that is not an `Int` is range checked as a `Long` and narrowed.
  val i = if site.wide { method0(i0, "toLong", wsp) } else { i0 }
  if site.elide {
    return callOf(arrayUncheckedIntrinsic(), oneExpr(if site.wide { method0(i, "toInt", wsp) } else { i }), wsp)
  }
  val name = "__lyric_ai_" + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset)
  val stmts: List[Statement] = newList()
  val idxTy = if site.wide { primTypeExpr("Long", wsp) } else { intTypeExpr(wsp) }
  stmts.add(typedLocal(name, Some(value = idxTy), i, wsp))
  val ref = localRef(name, wsp)
  val zeroLit = if site.wide { typedIntLit("Long", 0i64, wsp) } else { intLit(0, wsp) }
  val lenLit = if site.wide { typedIntLit("Long", site.len.toLong(), wsp) } else { intLit(site.len, wsp) }
  val outOfRange = bin(BOr, bin(BLt, ref, zeroLit, wsp), bin(BGte, ref, lenLit, wsp), wsp)
  val msg = bin(
    BAdd,
    bin(BAdd, mkExpr(ELiteral(lit = LString(text = "index ")), wsp), method0(ref, "toString", wsp), wsp),
    mkExpr(ELiteral(lit = LString(text = " out of range for array[" + toString(site.len) + "]")), wsp),
    wsp
  )
  stmts.add(panicIfDynamic(outOfRange, msg, wsp))
  stmts.add(mkStmt(SExpr(expr = if site.wide { method0(ref, "toInt", wsp) } else { ref }), wsp))
  callOf(arrayUncheckedIntrinsic(), oneExpr(blockOf(stmts, wsp)), wsp)
}

func panicIfDynamic(cond: in Expr, msg: in Expr, sp: in Span): Statement {
  val call = callOf("panic", oneExpr(msg), sp)
  val thenStmts: List[Statement] = newList()
  thenStmts.add(mkStmt(SExpr(expr = call), sp))
  val ifE = mkExpr(
    EIf(
      cond = cond,
      thenBranch = EOBBlock(block = Block(statements = thenStmts, span = sp)),
      elseBranch = None,
      thenForm = false
    ),
    sp
  )
  mkStmt(SExpr(expr = ifE), sp)
}

// `a.length` is the constant `N`; an operand that is more than a variable or
// field path is still evaluated.
func lengthOf(recv: in Expr, n: in Int, sp: in Span): Expr {
  if isSideEffectFreePath(recv) {
    return intLit(n, sp)
  }
  val stmts: List[Statement] = newList()
  stmts.add(mkStmt(SExpr(expr = recv), syntheticSpan(sp)))
  stmts.add(mkStmt(SExpr(expr = intLit(n, sp)), syntheticSpan(sp)))
  blockOf(stmts, syntheticSpan(sp))
}

func isSideEffectFreePath(e: in Expr): Bool {
  match e.kind {
    case EPath(_) -> true
    case ESelf -> true
    case EParen(inner) -> isSideEffectFreePath(inner)
    case EMember(recv, _) -> isSideEffectFreePath(recv)
    case _ -> false
  }
}

func copyOf(inner: in Expr, site: in ArraySite, sp: in Span): Expr {
  match site.arrayType {
    // A bracket literal is fresh, so it is not copied as a whole; an element
    // that is itself an array is copied, since it may be read from a place
    // the new array must not share storage with (`[a, a]`).  The literal
    // initialises a binding of the array type, which gives it its type where
    // nothing else does (a distinct type's `from` argument).
    case Some(t) -> if isListLiteral(inner) {
      val wsp = syntheticSpan(sp)
      val name = "__lyric_alit_" + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset)
      val stmts: List[Statement] = newList()
      stmts.add(typedLocal(name, Some(value = t), copyLiteralElements(inner, site.elemType), wsp))
      stmts.add(mkStmt(SExpr(expr = localRef(name, wsp)), wsp))
      blockOf(stmts, wsp)
    } else {
      val targs: List[TypeArg] = newList()
      targs.add(TAType(ty = t))
      val fn = mkExpr(ETypeApp(fn = localRef(arrayCopyIntrinsic(), sp), args = targs), sp)
      val args: List[CallArg] = newList()
      args.add(CAPositional(expr = inner))
      mkExpr(ECall(fn = fn, args = args), sp)
    }
    case None -> inner
  }
}

func copyLiteralElements(lit: in Expr, elemType: in Option[TypeExpr]): Expr {
  match lit.kind {
    case EList(elems) -> {
      val copied: List[Expr] = newList()
      for el in elems {
        if isArrayCopyCall(el) {
          copied.add(el)
        } else {
          copied.add(copyArrayElement(el, elemType, el.span))
        }
      }
      mkExpr(EList(exprs = copied), lit.span)
    }
    case EParen(inner) -> copyLiteralElements(inner, elemType)
    case _ -> lit
  }
}

func isArrayCopyCall(e: in Expr): Bool {
  match e.kind {
    case ECall(fn, _) -> match fn.kind {
      case ETypeApp(inner, _) -> match inner.kind {
        case EPath(p) -> p.segments.count == 1 and
          p.segments[0] == arrayCopyIntrinsic()
        case _ -> false
      }
      case _ -> false
    }
    case EParen(inner) -> isArrayCopyCall(inner)
    case _ -> false
  }
}

func isListLiteral(e: in Expr): Bool {
  match e.kind {
    case EList(_) -> true
    case EParen(inner) -> isListLiteral(inner)
    case _ -> false
  }
}

func listTypeOf(elem: in TypeExpr, sp: in Span): TypeExpr {
  val segs: List[String] = newList()
  segs.add("List")
  val targs: List[TypeArg] = newList()
  targs.add(TAType(ty = elem))
  TypeExpr(kind = TGenericApp(head = ModulePath(segments = segs, span = sp), args = targs), span = sp)
}

// `a.toSlice()`:
//   { val a': array[N, T] = a
//     val out: List[T] = newList()
//     for i in 0 ..< N { out.add(a'[i]) }
//     out.toArray() }
func toSliceOf(recv: in Expr, site: in ArraySite, sp: in Span): Expr {
  val wsp = syntheticSpan(sp)
  val base = "__lyric_ts_" + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset)
  val aName = base + "_a"
  val oName = base + "_o"
  val iName = base + "_i"
  val stmts: List[Statement] = newList()
  stmts.add(typedLocal(aName, site.arrayType, recv, wsp))
  val listTy = match site.elemType { case Some(et) -> Some(value = listTypeOf(et, wsp)); case None -> None }
  stmts.add(typedLocal(oName, listTy, callOf("newListWithCapacity", oneExpr(intLit(site.len, wsp)), wsp), wsp))
  val body: List[Statement] = newList()
  body.add(
    mkStmt(
      SExpr(
        expr = method1(
          localRef(oName, wsp),
          "add",
          copyArrayElement(uncheckedIndex(localRef(aName, wsp), localRef(iName, wsp), wsp), site.elemType, wsp),
          wsp
        )
      ),
      wsp
    )
  )
  stmts.add(rangeFor(None, iName, site.len, body, wsp))
  stmts.add(mkStmt(SExpr(expr = method0(localRef(oName, wsp), "toArray", wsp)), wsp))
  blockOf(stmts, wsp)
}

// An element read that is itself an array is copied into the slice (D167):
// the slice owns its elements.
func copyArrayElement(read: in Expr, elemType: in Option[TypeExpr], sp: in Span): Expr {
  match elemType {
    case Some(et) -> match arrayShapeOf(et) {
      case Some(sh) -> copyOf(
        read,
        ArraySite(
          len = sh.len,
          arrayType = Some(value = et),
          elemType = Some(value = sh.elem),
          span = sp
        ),
        sp
      )
      case None -> read
    }
    case None -> read
  }
}

func rangeFor(label: in Option[String], iName: in String, n: in Int, body: in List[Statement], sp: in Span): Statement {
  val pat = Pattern(kind = PBinding(name = iName, inner = None), span = sp)
  val range = mkExpr(ERange(bound = RBHalfOpen(lo = intLit(0, sp), hi = intLit(n, sp), bareDotDot = false)), sp)
  mkStmt(SFor(label = label, pat = pat, iter = range, body = Block(statements = body, span = sp)), sp)
}

// ── Statements ──────────────────────────────────────────────────────────────
func rewriteArrayStmt(s: in Statement, sites: in ArraySites): Statement {
  match s.kind {
    case SLocal(binding) -> match binding {
      case LBVar(name, ty, init) -> match init {
        case None -> match mapGet(sites.zero, recordCopySiteKey(s.span)) {
          case Some(z) -> mkStmt(
            SLocal(
              binding = LBVar(
                name = name,
                ty = ty,
                init = Some(
                  value = z
                )
              )
            ),
            s.span
          )
          case None -> s
        }
        case Some(_) -> s
      }
      case _ -> s
    }
    case SFor(label, pat, iter, body) -> match mapGet(sites.forIter, recordCopySiteKey(iter.span)) {
      case Some(site) -> forOverArray(s, label, pat, iter, body, site)
      case None -> s
    }
    case _ -> s
  }
}

// `for x in a { body }` over the array's value when the loop starts:
//   { val a': array[N, T] = a
//     for i in 0 ..< N { val x = a'[i]; body } }
func forOverArray(
  s: in Statement,
  label: in Option[String],
  pat: in Pattern,
  iter: in Expr,
  body: in Block,
  site: in ArraySite,
): Statement {
  val wsp = syntheticSpan(s.span)
  val base = "__lyric_fa_" + toString(s.span.startPos.offset) + "_" + toString(s.span.endPos.offset)
  val aName = base + "_a"
  val iName = base + "_i"
  val stmts: List[Statement] = newList()
  stmts.add(typedLocal(aName, site.arrayType, iter, wsp))
  val inner: List[Statement] = newList()
  val elemRead = uncheckedIndex(localRef(aName, wsp), localRef(iName, wsp), wsp)
  inner.add(mkStmt(SLocal(binding = LBVal(pat = pat, ty = None, init = elemRead)), wsp))
  for st in body.statements {
    inner.add(st)
  }
  val loop = rangeFor(label, iName, site.len, inner, wsp)
  stmts.add(loop)
  mkStmt(SExpr(expr = blockOf(stmts, wsp)), s.span)
}

// ── The `List` representation (dotnet and the JVM) ──────────────────────────
/// Lowers the array intrinsics for a backend whose `array[N, T]` is a
/// `List[T]`: the fill and copy intrinsics become loops and the unchecked
/// marker is dropped.  The caller then rewrites the remaining `array[N, T]`
/// type expressions with `Lyric.TypeAliasResolve`.
/// The fill and copy intrinsics as loops over a `List`; with `keepPrimitive`,
/// those of an array whose element is a primitive (`primitiveArrayElement`)
/// stay for a backend with typed primitive arrays (#8041).
pub func lowerArrayIntrinsicsToLists(file: in SourceFile, keepPrimitive: in Bool): SourceFile {
  mapFileAndContracts(file, { e: Expr -> rewriteArrayIntrinsic(e, keepPrimitive) }, { s: Statement -> s })
}

func rewriteArrayIntrinsic(e: in Expr, keepPrimitive: in Bool): Expr {
  match e.kind {
    case ECall(fn, args) -> {
      val name = match fn.kind {
        case EPath(p) -> if p.segments.count == 1 { p.segments[0] } else { "" }
        case ETypeApp(inner, _) -> match inner.kind {
          case EPath(p) -> if p.segments.count == 1 { p.segments[0] } else { "" }
          case _ -> ""
        }
        case _ -> ""
      }
      if name == arrayUncheckedIntrinsic() and args.count == 1 {
        return callArgValue(args[0])
      }
      if name == arrayFillIntrinsic() and args.count == 1 {
        return match fn.kind {
          case ETypeApp(_, targs) -> match arrayTypeArg(targs) {
            case Some(arr) -> if keepPrimitive and primitiveArrayElement(arr.elem) {
              e
            } else {
              fillList(arr, callArgValue(args[0]), e.span)
            }
            case None -> e
          }
          case _ -> e
        }
      }
      if name == arrayCopyIntrinsic() and args.count == 1 {
        return match fn.kind {
          case ETypeApp(_, targs) -> match arrayTypeArg(targs) {
            case Some(arr) -> if keepPrimitive and primitiveArrayElement(arr.elem) {
              e
            } else {
              copyList(arr, callArgValue(args[0]), keepPrimitive, e.span)
            }
            case None -> callArgValue(args[0])
          }
          case _ -> callArgValue(args[0])
        }
      }
      e
    }
    case _ -> e
  }
}

func callArgValue(a: in CallArg): Expr {
  match a {
    case CAPositional(x) -> x
    case CANamed(_, x, _) -> x
  }
}

record ArrayShape {
  len: Int
  elem: TypeExpr
}

func arrayTypeArg(targs: in List[TypeArg]): Option[ArrayShape] {
  if targs.count != 1 {
    return None
  }
  match targs[0] {
    case TAType(te) -> arrayShapeOf(te)
    case TAValue(_) -> None
  }
}

// How many `array[N, T]` levels `te` nests.
func arrayDepth(te: in TypeExpr): Int {
  match arrayShapeOf(te) {
    case Some(inner) -> 1 + arrayDepth(inner.elem)
    case None -> 0
  }
}

func arrayShapeOf(te: in TypeExpr): Option[ArrayShape] {
  match te.kind {
    case TParen(inner) -> arrayShapeOf(inner)
    case TArray(size, elem) -> match size {
      case TAValue(ve) -> match ve.kind {
        case ELiteral(lit) -> match lit {
          case LInt(v, _, _) -> Some(
            value = ArrayShape(
              len = v.toInt(),
              elem = elem
            )
          )
          case _ -> None
        }
        case _ -> None
      }
      case TAType(_) -> None
    }
    case _ -> None
  }
}

// `fill[array[N, T]](z)`:
//   { val l: List[T] = newList(); var i = 0; while i < N { l.add(z); i = i + 1 }; l }
func fillList(arr: in ArrayShape, z: in Expr, sp: in Span): Expr {
  val wsp = syntheticSpan(sp)
  val base = "__lyric_af_" + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset) + "_" +
    toString(arrayDepth(arr.elem))
  val lName = base + "_l"
  val iName = base + "_i"
  val stmts: List[Statement] = newList()
  stmts.add(
    typedLocal(
      lName,
      Some(value = listTypeOf(arr.elem, wsp)),
      callOf("newListWithCapacity", oneExpr(intLit(arr.len, wsp)), wsp),
      wsp
    )
  )
  stmts.add(
    mkStmt(
      SLocal(binding = LBVar(name = iName, ty = Some(value = intTypeExpr(wsp)), init = Some(value = intLit(0, wsp)))),
      wsp
    )
  )
  val body: List[Statement] = newList()
  body.add(mkStmt(SExpr(expr = method1(localRef(lName, wsp), "add", z, wsp)), wsp))
  body.add(incrementStmt(iName, wsp))
  stmts.add(whileLess(iName, arr.len, body, wsp))
  stmts.add(mkStmt(SExpr(expr = localRef(lName, wsp)), wsp))
  blockOf(stmts, wsp)
}

func incrementStmt(iName: in String, sp: in Span): Statement {
  mkStmt(
    SAssign(target = localRef(iName, sp), op = AssEq, value = bin(BAdd, localRef(iName, sp), intLit(1, sp), sp)),
    sp
  )
}

func whileLess(iName: in String, n: in Int, body: in List[Statement], sp: in Span): Statement {
  val cond = bin(BLt, localRef(iName, sp), intLit(n, sp), sp)
  mkStmt(SWhile(label = None, cond = cond, body = Block(statements = body, span = sp)), sp)
}

// `copy[array[N, T]](a)`:
//   { val s: List[T] = a; val d: List[T] = newList()
//     for x in s { d.add(x) }; d }
// with each element of a nested array copied in turn.
func copyList(arr: in ArrayShape, a: in Expr, keepPrimitive: in Bool, sp: in Span): Expr {
  val wsp = syntheticSpan(sp)
  val base = "__lyric_ac_" + toString(sp.startPos.offset) + "_" + toString(sp.endPos.offset) + "_" +
    toString(arrayDepth(arr.elem))
  val sName = base + "_s"
  val dName = base + "_d"
  val iName = base + "_i"
  val listTy = Some(value = listTypeOf(arr.elem, wsp))
  val stmts: List[Statement] = newList()
  stmts.add(typedLocal(sName, listTy, a, wsp))
  stmts.add(typedLocal(dName, listTy, callOf("newListWithCapacity", oneExpr(intLit(arr.len, wsp)), wsp), wsp))
  val elemRead = mkExpr(EIndex(receiver = localRef(sName, wsp), indices = oneExpr(localRef(iName, wsp))), wsp)
  val elemCopy = match arrayShapeOf(arr.elem) {
    // An element array the backend keeps native (#8041) is copied by the
    // intrinsic, not as a list.
    case Some(inner) -> if keepPrimitive and primitiveArrayElement(inner.elem) {
      val targs: List[TypeArg] = newList()
      targs.add(TAType(ty = arr.elem))
      val cargs: List[CallArg] = newList()
      cargs.add(CAPositional(expr = elemRead))
      mkExpr(ECall(fn = mkExpr(ETypeApp(fn = localRef(arrayCopyIntrinsic(), wsp), args = targs), wsp), args = cargs), wsp)
    } else {
      copyList(inner, elemRead, keepPrimitive, sp)
    }
    case None -> elemRead
  }
  val body: List[Statement] = newList()
  body.add(mkStmt(SExpr(expr = method1(localRef(dName, wsp), "add", elemCopy, wsp)), wsp))
  stmts.add(rangeFor(None, iName, arr.len, body, wsp))
  stmts.add(mkStmt(SExpr(expr = localRef(dName, wsp)), wsp))
  blockOf(stmts, wsp)
}
