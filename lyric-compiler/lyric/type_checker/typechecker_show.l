//! typechecker_show.l — structural `toString` (D282).
//!
//! `toString` of a record, union, enum, tuple, `List`, `Map`, `Set`, slice or
//! array is one text on every target.  A backend cannot produce it: a tuple
//! and a `List` are the same host class, an unsigned or `Float` leaf is only
//! known from its static type, and native has no host `toString` at all.  So
//! the type checker records each stringified operand of such a type (the
//! positions `isStringifyingBuiltin` lists, plus interpolated segments and
//! `String` `+`) and synthesises, per type, a function `__lyric_str_N(x, d)`
//! that renders it from its parts.  `Lyric.Pipeline` wraps the operand in a
//! call of that function (`showSites`), so every backend receives a `String`.
//! Like the covariant conversion functions, the helpers are plain Lyric
//! syntax with no source span and are not type-checked again.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// How a type is rendered: 0 by the host (a scalar, `String`, an extern,
// opaque, distinct or protected type, a function), else the synthesised form.
func showKind(tbl: in SymbolTable, t: in Type): Int {
  match unrefine(t) {
    case TyTuple(_) -> 1
    case TySlice(_) -> 2
    case TyUser(tid, _, targs) -> {
      if targs.count == 1 and isStdCollectionsHostType(tbl, tid, "List") {
        return 2
      }
      if targs.count == 2 and isStdCollectionsHostType(tbl, tid, "Map") {
        return 3
      }
      if targs.count == 1 and isStdCollectionsHostType(tbl, tid, "Set") {
        return 4
      }
      match symTableTypeSymbolOf(tbl, tid) {
        case Some(sym) -> match sym.kind {
          case DKRecord(_, rd) -> if rd.isForeign { 0 } else { 5 }
          case DKExposedRec(_, _) -> 5
          case DKUnion(_, _) -> 6
          case DKEnum(_, _) -> 7
          case _ -> 0
        }
        case None -> 0
      }
    }
    case _ -> 0
  }
}

// Record `e`, a stringified operand of type `t`, as a site `Lyric.Pipeline`
// wraps in the call of the function that renders `t`.
func recordShowOperand(tbl: in SymbolTable, t: in Type, e: in Expr): Unit {
  if showKind(tbl, t) == 0 {
    return
  }
  val key = recordCopySiteKey(e.span)
  if tbl.showSites.containsKey(key) {
    return
  }
  match showHelperName(tbl, t) {
    case Some(name) -> tbl.showSites.add(key, name)
    case None -> ()
  }
}

// The name of the synthesized function rendering a `t`, creating it (and the
// functions it calls) on first use; None when `t` cannot be spelled.
func showHelperName(tbl: in SymbolTable, t: in Type): Option[String] {
  val ut = unrefine(t)
  if showKind(tbl, ut) == 0 {
    return None
  }
  val key = showTypeKey(tbl, ut)
  match mapGet(tbl.showHelperNames, key) {
    case Some(n) -> return Some(value = n)
    case None -> ()
  }
  val sp = noSourceSpan()
  val te = match typeExprForRef(tbl, ut, sp) {
    case Some(x) -> x
    case None -> return None
  }
  val name = "__lyric_str_" + key
  tbl.showHelperNames.add(key, name)
  val stmts = showHelperBody(tbl, ut, te, sp)
  val params: List[Param] = newList()
  params.add(covParam("x", te, sp))
  params.add(covParam("d", showPrimTypeExpr("Int", sp), sp))
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val noContracts: List[ContractClause] = newList()
  tbl.showHelpers.add(
    FunctionDecl(
      docComments = noDocs,
      annotations = noAnns,
      visibility = None,
      isAsync = false,
      name = name,
      generics = None,
      params = params,
      ret = Some(value = showPrimTypeExpr("String", sp)),
      whereClause = None,
      contracts = noContracts,
      body = Some(value = FBBlock(block = Block(statements = stmts, span = sp))),
      span = sp
    )
  )
  Some(value = name)
}

func showPrimTypeExpr(name: in String, sp: in Span): TypeExpr {
  val segs: List[String] = newList()
  segs.add(name)
  TypeExpr(kind = TRef(path = refTypePath(segs, sp)), span = sp)
}

func showStrLit(s: in String, sp: in Span): Expr {
  mkExpr(ELiteral(lit = LString(text = s)), sp)
}

func showIntLit(n: in Int, sp: in Span): Expr {
  mkExpr(ELiteral(lit = LInt(value = n.toLong(), suffix = I32, raw = "")), sp)
}

func showConcat(a: in Expr, b: in Expr, sp: in Span): Expr {
  mkExpr(EBinop(op = BAdd, lhs = a, rhs = b), sp)
}

func showCall(fnName: in String, argList: in List[Expr], sp: in Span): Expr {
  val args: List[CallArg] = newList()
  for a in argList {
    args.add(CAPositional(expr = a))
  }
  mkExpr(ECall(fn = covNameExpr(fnName, sp), args = args), sp)
}

func showQualifiedCall(pkgPath: in List[String], fnName: in String, argList: in List[Expr], sp: in Span): Expr {
  val segs: List[String] = newList()
  for p in pkgPath {
    segs.add(p)
  }
  segs.add(fnName)
  val args: List[CallArg] = newList()
  for a in argList {
    args.add(CAPositional(expr = a))
  }
  mkExpr(ECall(fn = mkExpr(EPath(path = covPath(segs, sp)), sp), args = args), sp)
}

// `Std.String.<fnName>(...)`, the joins every rendering ends in.
func showStringCall(fnName: in String, argList: in List[Expr], sp: in Span): Expr {
  val pkg: List[String] = newList()
  pkg.add("Std")
  pkg.add("String")
  showQualifiedCall(pkg, fnName, argList, sp)
}

func showCollectionsCall(fnName: in String, argList: in List[Expr], sp: in Span): Expr {
  val pkg: List[String] = newList()
  pkg.add("Std")
  pkg.add("Collections")
  showQualifiedCall(pkg, fnName, argList, sp)
}

func showMethodCall(recv: in Expr, method: in String, argList: in List[Expr], sp: in Span): Expr {
  val args: List[CallArg] = newList()
  for a in argList {
    args.add(CAPositional(expr = a))
  }
  mkExpr(ECall(fn = mkExpr(EMember(receiver = recv, memberName = method), sp), args = args), sp)
}

func showValLocal(name: in String, te: in TypeExpr, init: in Expr, sp: in Span): Statement {
  val pat = Pattern(kind = PBinding(name = name, inner = None), span = sp)
  covStmt(SLocal(binding = LBVal(pat = pat, ty = Some(value = te), init = init)), sp)
}

func showExprStmt(e: in Expr, sp: in Span): Statement {
  covStmt(SExpr(expr = e), sp)
}

// A `val parts: List[String] = newList()`.
func showPartsDecl(sp: in Span): Statement {
  val noArgs: List[Expr] = newList()
  val listTe = TypeExpr(
    kind = TGenericApp(
      head = refTypePath(showSingle("List"), sp),
      args = showSingleTypeArg(showPrimTypeExpr("String", sp), sp)
    ),
    span = sp
  )
  showValLocal("parts", listTe, showCall("newList", noArgs, sp), sp)
}

func showSingle(s: in String): List[String] {
  val l: List[String] = newList()
  l.add(s)
  l
}

func showSingleTypeArg(te: in TypeExpr, sp: in Span): List[TypeArg] {
  val l: List[TypeArg] = newList()
  l.add(TAType(ty = te))
  l
}

func showListOfStringTe(sp: in Span): TypeExpr {
  TypeExpr(
    kind = TGenericApp(
      head = refTypePath(showSingle("List"), sp),
      args = showSingleTypeArg(showPrimTypeExpr("String", sp), sp)
    ),
    span = sp
  )
}

func showPartsAdd(partExpr: in Expr, sp: in Span): Statement {
  val a: List[Expr] = newList()
  a.add(partExpr)
  showExprStmt(showMethodCall(covNameExpr("parts", sp), "add", a, sp), sp)
}

// `Std.String.showSeq(open, parts, close)`.
func showJoined(open: in String, close: in String, sp: in Span): Expr {
  val a: List[Expr] = newList()
  a.add(showStrLit(open, sp))
  a.add(covNameExpr("parts", sp))
  a.add(showStrLit(close, sp))
  showStringCall("showSeq", a, sp)
}

// The expression rendering `v`, a value of type `ty`; `d` is the ref-record
// depth in scope.
func showExprFor(tbl: in SymbolTable, ty: in Type, v: in Expr, sp: in Span): Expr {
  match unrefine(ty) {
    case TyPrim(pt) -> match pt {
      case PtString -> v
      case PtUnit -> showStrLit("()", sp)
      case PtUInt -> showCall("toString", showSingleExpr(showMethodCall(v, "toUInt", newExprList(), sp)), sp)
      case PtULong -> showCall("toString", showSingleExpr(showMethodCall(v, "toULong", newExprList(), sp)), sp)
      case _ -> showCall("toString", showSingleExpr(v), sp)
    }
    case other -> match showHelperName(tbl, other) {
      case Some(name) -> {
        val a: List[Expr] = newList()
        a.add(v)
        a.add(covNameExpr("d", sp))
        showCall(name, a, sp)
      }
      case None -> showCall("toString", showSingleExpr(v), sp)
    }
  }
}

func newExprList(): List[Expr] {
  val l: List[Expr] = newList()
  l
}

func showSingleExpr(e: in Expr): List[Expr] {
  val l: List[Expr] = newList()
  l.add(e)
  l
}

// `d + 1` where `inc`, else `d`: the depth handed to the parts of a ref record.
func showDepthArg(inc: in Bool, sp: in Span): Expr {
  if inc {
    showConcat(covNameExpr("d", sp), showIntLit(1, sp), sp)
  } else {
    covNameExpr("d", sp)
  }
}

// The part rendering a field or element; a ref record's fields are one level
// deeper, which `showDepthArg` hands to the nested function through a shadowing
// `d`.
func showPart(tbl: in SymbolTable, ty: in Type, v: in Expr, label: in String, sp: in Span): Expr {
  val body = showExprFor(tbl, ty, v, sp)
  if label.length > 0 {
    showConcat(showStrLit(label + " = ", sp), body, sp)
  } else {
    body
  }
}

func showHelperBody(tbl: in SymbolTable, ty: in Type, te: in TypeExpr, sp: in Span): List[Statement] {
  val stmts: List[Statement] = newList()
  val kind = showKind(tbl, ty)
  val x = covNameExpr("x", sp)
  if kind == 1 {
    match ty {
      case TyTuple(elems) -> showTupleBody(tbl, elems, te, stmts, sp)
      case _ -> ()
    }
  } else if kind == 2 {
    stmts.add(showPartsDecl(sp))
    val elemTy = showElementType(tbl, ty)
    val loopBody: List[Statement] = newList()
    loopBody.add(showPartsAdd(showExprFor(tbl, elemTy, covNameExpr("e", sp), sp), sp))
    val elemPat = Pattern(kind = PBinding(name = "e", inner = None), span = sp)
    stmts.add(covStmt(SFor(label = None, pat = elemPat, iter = x, body = Block(statements = loopBody, span = sp)), sp))
    stmts.add(showExprStmt(showJoined("[", "]", sp), sp))
  } else if kind == 3 {
    showMapBody(tbl, ty, stmts, sp)
  } else if kind == 4 {
    showSetBody(tbl, ty, stmts, sp)
  } else if kind == 5 or kind == 6 {
    showUserTypeBody(tbl, ty, te, kind == 6, stmts, sp)
  } else if kind == 7 {
    showEnumBody(tbl, ty, te, stmts, sp)
  }
  stmts
}

func showElementType(tbl: in SymbolTable, ty: in Type): Type {
  match unrefine(ty) {
    case TySlice(e) -> e
    case TyArray(_, e, _) -> e
    case TyUser(_, _, targs) -> if targs.count > 0 { targs[0] } else { TyError }
    case _ -> TyError
  }
}

// `val (b0, b1): (A, B) = x`, each part then bound at its own type.
func showTupleBody(
  tbl: in SymbolTable,
  elems: in List[Type],
  te: in TypeExpr,
  stmts: in List[Statement],
  sp: in Span,
): Unit {
  val pats: List[Pattern] = newList()
  var i = 0
  while i < elems.count {
    pats.add(Pattern(kind = PBinding(name = "b" + toString(i), inner = None), span = sp))
    i = i + 1
  }
  val tupPat = Pattern(kind = PTuple(patterns = pats), span = sp)
  stmts.add(
    covStmt(SLocal(binding = LBVal(pat = tupPat, ty = Some(value = te), init = covNameExpr("x", sp))), sp)
  )
  stmts.add(showPartsDecl(sp))
  var j = 0
  while j < elems.count {
    stmts.add(showPartsAdd(showTypedPart(tbl, elems[j], "b" + toString(j), "t" + toString(j), "", stmts, sp), sp))
    j = j + 1
  }
  stmts.add(showExprStmt(showJoined("(", ")", sp), sp))
}

// `val <local>: T = <source>` then the rendering of `<local>`: the part is
// rendered from a local of its own type, so a backend that erases the
// container's element type reads it back at the type it renders.
func showTypedPart(
  tbl: in SymbolTable,
  ty: in Type,
  sourceName: in String,
  localName: in String,
  label: in String,
  stmts: in List[Statement],
  sp: in Span,
): Expr {
  match typeExprForRef(tbl, ty, sp) {
    case Some(fte) -> {
      stmts.add(showValLocal(localName, fte, covNameExpr(sourceName, sp), sp))
      showPart(tbl, ty, covNameExpr(localName, sp), label, sp)
    }
    case None -> showPart(tbl, ty, covNameExpr(sourceName, sp), label, sp)
  }
}

func showMapBody(tbl: in SymbolTable, ty: in Type, stmts: in List[Statement], sp: in Span): Unit {
  val kt = match unrefine(ty) { case TyUser(_, _, a) -> a[0]; case _ -> TyError }
  val vt = match unrefine(ty) { case TyUser(_, _, a) -> a[1]; case _ -> TyError }
  val noArgs: List[Expr] = newList()
  val stringList = showListOfStringTe(sp)
  stmts.add(showValLocal("ks", stringList, showCall("newList", noArgs, sp), sp))
  stmts.add(showValLocal("vs", stringList, showCall("newList", noArgs, sp), sp))
  val keyTe = match typeExprForRef(tbl, kt, sp) {
    case Some(t) -> t
    case None -> showPrimTypeExpr("String", sp)
  }
  val keyListTe = TypeExpr(
    kind = TGenericApp(head = refTypePath(showSingle("List"), sp), args = showSingleTypeArg(keyTe, sp)),
    span = sp
  )
  val keysCall = showCollectionsCall("mapKeys", showSingleExpr(covNameExpr("x", sp)), sp)
  stmts.add(showValLocal("keys", keyListTe, keysCall, sp))
  val body: List[Statement] = newList()
  val ksAdd: List[Expr] = newList()
  ksAdd.add(showExprFor(tbl, kt, covNameExpr("k", sp), sp))
  body.add(showExprStmt(showMethodCall(covNameExpr("ks", sp), "add", ksAdd, sp), sp))
  val valTe = match typeExprForRef(tbl, vt, sp) {
    case Some(t) -> t
    case None -> showPrimTypeExpr("String", sp)
  }
  val optTe = TypeExpr(
    kind = TGenericApp(head = refTypePath(showSingle("Option"), sp), args = showSingleTypeArg(valTe, sp)),
    span = sp
  )
  val getArgs: List[Expr] = newList()
  getArgs.add(covNameExpr("x", sp))
  getArgs.add(covNameExpr("k", sp))
  body.add(showValLocal("ov", optTe, showCollectionsCall("mapGet", getArgs, sp), sp))
  val someArgs: List[Expr] = newList()
  someArgs.add(showExprFor(tbl, vt, covNameExpr("v", sp), sp))
  val noneArgs: List[Expr] = newList()
  noneArgs.add(showStrLit("", sp))
  val somePats: List[Pattern] = newList()
  somePats.add(Pattern(kind = PBinding(name = "v", inner = None), span = sp))
  val arms: List[MatchArm] = newList()
  arms.add(
    MatchArm(
      pattern = Pattern(kind = PConstructor(head = covPath(showSingle("Some"), sp), args = somePats), span = sp),
      guard = None,
      body = EOBExpr(expr = showMethodCall(covNameExpr("vs", sp), "add", someArgs, sp)),
      span = sp
    )
  )
  arms.add(
    MatchArm(
      pattern = Pattern(kind = PBinding(name = "None", inner = None), span = sp),
      guard = None,
      body = EOBExpr(expr = showMethodCall(covNameExpr("vs", sp), "add", noneArgs, sp)),
      span = sp
    )
  )
  body.add(showExprStmt(mkExpr(EMatch(scrutinee = covNameExpr("ov", sp), arms = arms), sp), sp))
  val keyPat = Pattern(kind = PBinding(name = "k", inner = None), span = sp)
  stmts.add(
    covStmt(
      SFor(label = None, pat = keyPat, iter = covNameExpr("keys", sp), body = Block(statements = body, span = sp)),
      sp
    )
  )
  val joinArgs: List[Expr] = newList()
  joinArgs.add(covNameExpr("ks", sp))
  joinArgs.add(covNameExpr("vs", sp))
  stmts.add(showExprStmt(showStringCall("showMap", joinArgs, sp), sp))
}

func showSetBody(tbl: in SymbolTable, ty: in Type, stmts: in List[Statement], sp: in Span): Unit {
  val et = showElementType(tbl, ty)
  stmts.add(showPartsDecl(sp))
  val body: List[Statement] = newList()
  body.add(showPartsAdd(showExprFor(tbl, et, covNameExpr("e", sp), sp), sp))
  val elemPat = Pattern(kind = PBinding(name = "e", inner = None), span = sp)
  stmts.add(
    covStmt(
      SFor(label = None, pat = elemPat, iter = covNameExpr("x", sp), body = Block(statements = body, span = sp)),
      sp
    )
  )
  stmts.add(showExprStmt(showStringCall("showSet", showSingleExpr(covNameExpr("parts", sp)), sp), sp))
}

// A record, or a union's cases: `Name(f = v, ...)`, the bare name for a case
// with no fields.
func showUserTypeBody(
  tbl: in SymbolTable,
  ty: in Type,
  te: in TypeExpr,
  isUnion: in Bool,
  stmts: in List[Statement],
  sp: in Span,
): Unit {
  val tid = match ty { case TyUser(i, _, _) -> i; case _ -> return }
  val targs = match ty { case TyUser(_, _, a) -> a; case _ -> return }
  val ctors = covariantCtors(tbl, tid, targs)
  val deeper = showIsRefRecord(tbl, tid)
  if deeper {
    val guardArms: List[Statement] = newList()
    guardArms.add(covStmt(SReturn(value = Some(value = showStrLit("...", sp))), sp))
    val cond = mkExpr(EBinop(op = BGt, lhs = covNameExpr("d", sp), rhs = showIntLit(32, sp)), sp)
    stmts.add(
      showExprStmt(
        mkExpr(
          EIf(
            cond = cond,
            thenBranch = EOBBlock(block = Block(statements = guardArms, span = sp)),
            elseBranch = None,
            thenForm = false
          ),
          sp
        ),
        sp
      )
    )
  }
  if not isUnion {
    if ctors.count == 1 {
      showCtorRender(tbl, ctors[0], "x", te, deeper, stmts, sp)
    }
    return
  }
  val arms: List[MatchArm] = newList()
  for c in ctors {
    val casePath = covCtorPath(te, c.name, sp)
    val patArgs: List[Pattern] = newList()
    var fi = 0
    while fi < c.fieldNames.count {
      patArgs.add(Pattern(kind = PBinding(name = "v" + toString(fi), inner = None), span = sp))
      fi = fi + 1
    }
    val pat: Pattern = if c.fieldNames.count == 0 and casePath.segments.count == 1 {
      Pattern(kind = PBinding(name = c.name, inner = None), span = sp)
    } else {
      Pattern(kind = PConstructor(head = casePath, args = patArgs), span = sp)
    }
    val armStmts: List[Statement] = newList()
    showCtorRender(tbl, c, "v", te, deeper, armStmts, sp)
    arms.add(
      MatchArm(
        pattern = pat,
        guard = None,
        body = EOBBlock(block = Block(statements = armStmts, span = sp)),
        span = sp
      )
    )
  }
  stmts.add(showExprStmt(mkExpr(EMatch(scrutinee = covNameExpr("x", sp), arms = arms), sp), sp))
}

// The statements ending in the rendering of one constructor.  `source` is
// "x" for a record (fields are read as `x.f`) and "v" for a union case (field
// `i` is the pattern variable `v<i>`).
func showCtorRender(
  tbl: in SymbolTable,
  c: in CovCtor,
  source: in String,
  te: in TypeExpr,
  deeper: in Bool,
  stmts: in List[Statement],
  sp: in Span,
): Unit {
  if c.fieldNames.count == 0 {
    stmts.add(showExprStmt(showStrLit(c.name + (if source == "x" { "()" } else { "" }), sp), sp))
    return
  }
  stmts.add(showPartsDecl(sp))
  var i = 0
  while i < c.fieldNames.count {
    val readExpr: Expr = if source == "x" {
      mkExpr(EMember(receiver = covNameExpr("x", sp), memberName = c.fieldNames[i]), sp)
    } else {
      covNameExpr("v" + toString(i), sp)
    }
    val local = "f" + toString(i)
    val part: Expr = match typeExprForRef(tbl, c.fieldTypes[i], sp) {
      case Some(fte) -> {
        stmts.add(showValLocal(local, fte, readExpr, sp))
        showFieldPart(tbl, c.fieldTypes[i], local, c.fieldNames[i], deeper, sp)
      }
      case None -> showPart(tbl, c.fieldTypes[i], readExpr, c.fieldNames[i], sp)
    }
    stmts.add(showPartsAdd(part, sp))
    i = i + 1
  }
  stmts.add(showExprStmt(showJoined(c.name + "(", ")", sp), sp))
}

// The part rendering the field in local `local`: through a nested function with
// `d + 1` when the enclosing type is a ref record.
func showFieldPart(
  tbl: in SymbolTable,
  ty: in Type,
  local: in String,
  label: in String,
  deeper: in Bool,
  sp: in Span,
): Expr {
  val v = covNameExpr(local, sp)
  val body: Expr = match unrefine(ty) {
    case TyPrim(_) -> showExprFor(tbl, ty, v, sp)
    case other -> match showHelperName(tbl, other) {
      case Some(name) -> {
        val a: List[Expr] = newList()
        a.add(v)
        a.add(showDepthArg(deeper, sp))
        showCall(name, a, sp)
      }
      case None -> showCall("toString", showSingleExpr(v), sp)
    }
  }
  if label.length > 0 {
    showConcat(showStrLit(label + " = ", sp), body, sp)
  } else {
    body
  }
}

func showIsRefRecord(tbl: in SymbolTable, tid: in TypeId): Bool {
  match symTableTypeSymbolOf(tbl, tid) {
    case Some(sym) -> match sym.kind {
      case DKRecord(_, rd) -> rd.isRef
      case _ -> false
    }
    case None -> false
  }
}

// An enum: its case name.
func showEnumBody(tbl: in SymbolTable, ty: in Type, te: in TypeExpr, stmts: in List[Statement], sp: in Span): Unit {
  val tid = match ty { case TyUser(i, _, _) -> i; case _ -> return }
  val ed = match symTableTypeSymbolOf(tbl, tid) {
    case Some(sym) -> match sym.kind {
      case DKEnum(_, decl) -> decl
      case _ -> return
    }
    case None -> return
  }
  val typeName = ed.name
  val arms: List[MatchArm] = newList()
  for c in ed.cases {
    val head = showEnumCasePath(te, typeName, c.name, sp)
    arms.add(
      MatchArm(
        pattern = Pattern(kind = PConstructor(head = head, args = newPatternList()), span = sp),
        guard = None,
        body = EOBExpr(expr = showStrLit(c.name, sp)),
        span = sp
      )
    )
  }
  stmts.add(showExprStmt(mkExpr(EMatch(scrutinee = covNameExpr("x", sp), arms = arms), sp), sp))
}

func newPatternList(): List[Pattern] {
  val l: List[Pattern] = newList()
  l
}

// The path `Type.Case`, qualified by the type's package when it has one.
func showEnumCasePath(te: in TypeExpr, typeName: in String, caseName: in String, sp: in Span): ModulePath {
  val head: ModulePath = match te.kind {
    case TRef(p) -> p
    case _ -> covPath(showSingle(typeName), sp)
  }
  val segs: List[String] = newList()
  for s in head.segments {
    segs.add(s)
  }
  segs.add(caseName)
  covPath(segs, sp)
}

// The name-safe text identifying `t` by its declaring package and name, the
// same in every check of the same program, so a specialisation re-checked on
// its own (`Lyric.Pipeline.recheckSpecs`) names the function rendering a type
// as the file's own check does and the two are one function.  Letters and
// digits are kept; every run of other characters becomes one `_` (a `__` in
// a name marks a monomorphised copy).
func showTypeKey(tbl: in SymbolTable, t: in Type): String {
  showSanitize(showTypeText(tbl, t))
}

func showTypeText(tbl: in SymbolTable, t: in Type): String {
  match unrefine(t) {
    case TyPrim(pt) -> primName(pt)
    case TyTuple(elems) -> "Tuple" + showTypeListText(tbl, elems)
    case TySlice(e) -> "Slice" + showTypeListText(tbl, showSingleType(e))
    case TyUser(tid, name, args) -> {
      val pkg = match symTableTypeSymbolOf(tbl, tid) {
        case Some(sym) -> sym.originPackage
        case None -> ""
      }
      pkg + "." + name + (if args.count > 0 { showTypeListText(tbl, args) } else { "" })
    }
    case other -> renderType(other)
  }
}

func showSingleType(t: in Type): List[Type] {
  val l: List[Type] = newList()
  l.add(t)
  l
}

func showTypeListText(tbl: in SymbolTable, ts: in List[Type]): String {
  var acc = "("
  var i = 0
  while i < ts.count {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + showTypeText(tbl, ts[i])
    i = i + 1
  }
  acc + ")"
}

func showSanitize(text: in String): String {
  var acc = ""
  var lastSep = false
  var i = 0
  while i < text.length {
    val c = text[i]
    val keep = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')
    if keep {
      acc = acc + c.toString()
      lastSep = false
    } else if not lastSep {
      acc = acc + "_"
      lastSep = true
    }
    i = i + 1
  }
  acc
}
