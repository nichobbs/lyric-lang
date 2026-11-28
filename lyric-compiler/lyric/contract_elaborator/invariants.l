//! Record and opaque-type `invariant:` enforcement at construction (#7222).
//!
//! Two passes cooperate with the type checker:
//!
//! 1. `synthesizeInvariantCheckers` runs before type checking (from
//!    `Lyric.Pipeline.pipeExpandAndRewrite`).  For every record, exposed
//!    record and opaque type in the file that declares `invariant:` clauses
//!    it appends a checker function in the declaring package:
//!
//!        func __lyric_checked_T[G](__lyric_value: in T[G]): T[G] {
//!          assert(<clause with each field f as __lyric_value.f>, "InvariantViolated: Pkg.T invariant <clause>")
//!          ...
//!          __lyric_value
//!        }
//!
//!    with the type's own visibility, so it is type-checked like any other
//!    function and visible to exactly the packages that can construct `T`.
//!
//! 2. The type checker records every construction of such a type — a
//!    constructor call or a `.copy(...)` — keyed by span, with the checker
//!    path to call (`SymbolTable.invariantCtorSites`).  After `.copy`
//!    desugaring, `wrapInvariantConstructions` rewrites each recorded
//!    construction `T(...)` into `__lyric_checked_T(T(...))`.
//!
//! Protected-type invariants are handled separately by `elaborateItem`
//! (checked when each entry returns).
package Lyric.ContractElaborator

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser
import Lyric.Fmt as Fmt

/// The name of the construction checker synthesized for type `typeName`.
pub func invariantCheckerName(typeName: in String): String {
  "__lyric_checked_" + typeName
}

/// True when a record member list declares at least one `invariant:`.
pub func recordMembersHaveInvariant(members: in List[RecordMember]): Bool {
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

/// True when an opaque-type member list declares at least one `invariant:`.
pub func opaqueMembersHaveInvariant(members: in List[OpaqueMember]): Bool {
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

// ─── Pass 1: checker synthesis ──────────────────────────────────────────────
// Not `self`: a parameter of that name in a top-level function is typed as
// `Self`.
val checkedParam: String = "__lyric_value"

pub func synthesizeInvariantCheckers(file: in SourceFile): SourceFile {
  val pkg = Fmt.pathStr(file.packageDecl.path)
  // Idempotent: a file some bridge already passed through here keeps its
  // checkers and gains no duplicates.
  val existing: Map[String, Bool] = newMap()
  var e = 0
  while e < file.items.count {
    match file.items[e].kind {
      case IFunc(fn) -> if not existing.containsKey(fn.name) { existing.add(fn.name, true) }
      case _ -> ()
    }
    e = e + 1
  }
  val added: List[Item] = newList()
  var i = 0
  while i < file.items.count {
    val it = file.items[i]
    match it.kind {
      case IRecord(decl) -> if recordMembersHaveInvariant(decl.members) and not existing.containsKey(invariantCheckerName(decl.name)) {
        added.add(
          checkerItem(it, pkg, decl.name, decl.generics, recordFieldNames(decl.members), recordInvariants(decl.members))
        )
      }
      case IExposedRec(decl) -> if recordMembersHaveInvariant(decl.members) and not existing.containsKey(invariantCheckerName(decl.name)) {
        added.add(
          checkerItem(it, pkg, decl.name, decl.generics, recordFieldNames(decl.members), recordInvariants(decl.members))
        )
      }
      case IOpaque(decl) -> if opaqueMembersHaveInvariant(decl.members) and not existing.containsKey(invariantCheckerName(decl.name)) {
        added.add(
          checkerItem(it, pkg, decl.name, decl.generics, opaqueFieldNames(decl.members), opaqueInvariants(decl.members))
        )
      }
      case _ -> ()
    }
    i = i + 1
  }
  if added.count == 0 {
    return file
  }
  val items: List[Item] = newList()
  var j = 0
  while j < file.items.count {
    items.add(file.items[j])
    j = j + 1
  }
  var k = 0
  while k < added.count {
    items.add(added[k])
    k = k + 1
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    files = file.files,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
}

func recordFieldNames(members: in List[RecordMember]): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < members.count {
    match members[i] {
      case RMField(f) -> acc.add(f.name)
      case _ -> ()
    }
    i = i + 1
  }
  acc
}

func recordInvariants(members: in List[RecordMember]): List[InvariantClause] {
  val acc: List[InvariantClause] = newList()
  var i = 0
  while i < members.count {
    match members[i] {
      case RMInvariant(inv) -> acc.add(inv)
      case _ -> ()
    }
    i = i + 1
  }
  acc
}

func opaqueFieldNames(members: in List[OpaqueMember]): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < members.count {
    match members[i] {
      case OMField(f) -> acc.add(f.name)
      case _ -> ()
    }
    i = i + 1
  }
  acc
}

func opaqueInvariants(members: in List[OpaqueMember]): List[InvariantClause] {
  val acc: List[InvariantClause] = newList()
  var i = 0
  while i < members.count {
    match members[i] {
      case OMInvariant(inv) -> acc.add(inv)
      case _ -> ()
    }
    i = i + 1
  }
  acc
}

// `T` or `T[A, B]` for the type's own generic parameters.
func selfTypeExpr(name: in String, generics: in Option[GenericParams], sp: in Span): TypeExpr {
  val segs: List[String] = newList()
  segs.add(name)
  val path = ModulePath(segments = segs, span = sp)
  val args: List[TypeArg] = newList()
  match generics {
    case Some(gps) -> {
      var i = 0
      while i < gps.params.count {
        match gps.params[i] {
          case GPType(gname, _) -> {
            val gsegs: List[String] = newList()
            gsegs.add(gname)
            args.add(TAType(ty = TypeExpr(kind = TRef(path = ModulePath(segments = gsegs, span = sp)), span = sp)))
          }
          case GPValue(gname, _, _) -> args.add(TAValue(expr = mkPath(gname, sp)))
        }
        i = i + 1
      }
    }
    case None -> ()
  }
  if args.count == 0 {
    TypeExpr(kind = TRef(path = path), span = sp)
  } else {
    TypeExpr(kind = TGenericApp(head = path, args = args), span = sp)
  }
}

func checkerItem(
  typeItem: in Item,
  pkg: in String,
  name: in String,
  generics: in Option[GenericParams],
  fields: in List[String],
  invariants: in List[InvariantClause],
): Item {
  val sp = typeItem.span
  val selfTy = selfTypeExpr(name, generics, sp)
  val params: List[Param] = newList()
  val noDflt: Option[Expr] = None
  val noAnns: List[Annotation] = newList()
  params.add(
    Param(
      mode = PMIn,
      modeExplicit = true,
      name = checkedParam,
      ty = selfTy,
      dflt = noDflt,
      annotations = noAnns,
      span = sp
    )
  )
  val renames: Map[String, String] = newMap()
  var fi = 0
  while fi < fields.count {
    renames.add(fields[fi], checkedParam + "." + fields[fi])
    fi = fi + 1
  }
  val stmts: List[Statement] = newList()
  var ii = 0
  while ii < invariants.count {
    val inv = invariants[ii]
    val cond = substResult(inv.expr, "", renames)
    val message = "InvariantViolated: " + qualify(pkg, name) + " invariant " + Fmt.exprInline(0, inv.expr)
    stmts.add(mkAssertCall(cond, message, inv.span))
    ii = ii + 1
  }
  stmts.add(mkStmt(SExpr(expr = mkPath(checkedParam, sp)), sp))
  val noDocs: List[DocComment] = newList()
  val noContracts: List[ContractClause] = newList()
  val noWhere: Option[WhereClause] = None
  val fn = FunctionDecl(
    docComments = noDocs,
    annotations = noAnns,
    visibility = typeItem.visibility,
    isAsync = false,
    name = invariantCheckerName(name),
    generics = generics,
    params = params,
    ret = Some(value = selfTy),
    whereClause = noWhere,
    contracts = noContracts,
    body = Some(value = FBBlock(block = Block(statements = stmts, span = sp))),
    span = sp
  )
  Item(docComments = noDocs, annotations = noAnns, visibility = typeItem.visibility, kind = IFunc(decl = fn), span = sp)
}

/// The `invariant:` checks of an opaque type's `members` as source text, for a function that reads the type's fields
/// off `recv` (`self.f`) and returns a `Result[_, String]`: one `if not (<clause>) { return Err("InvariantViolated:
/// Pkg.T invariant <clause>") }` per clause, in order, with the construction checker's message and the clauses'
/// runtime-checkable conjuncts (a quantifier cannot run).  `@projectable`'s `tryInto` is built from them (D511).
pub func invariantErrChecksText(
  pkg: in String, typeName: in String, members: in List[OpaqueMember], recv: in String
): List[String] {
  val renames: Map[String, String] = newMap()
  val fields = opaqueFieldNames(members)
  var fi = 0
  while fi < fields.count {
    renames.add(fields[fi], recv + "." + fields[fi])
    fi = fi + 1
  }
  val res: List[String] = newList()
  val invs = opaqueInvariants(members)
  var i = 0
  while i < invs.count {
    val inv = invs[i]
    val cond = runtimeCheckableConjuncts(substResult(inv.expr, "", renames), inv.span)
    val condText = Fmt.exprInline(0, cond)
    if condText != "true" {
      val message = "InvariantViolated: " + qualify(pkg, typeName) + " invariant " + Fmt.exprInline(0, inv.expr)
      res.add("  if not (" + condText + ") {\n    return Err(\"" + escapeStringLiteral(message) + "\")\n  }\n")
    }
    i = i + 1
  }
  res
}

func escapeStringLiteral(s: in String): String {
  var res = ""
  var i = 0
  while i < s.length {
    val ch = s.substring(i, 1)
    if ch == "\\" {
      res = res + "\\\\"
    } else if ch == "\"" {
      res = res + "\\\""
    } else {
      res = res + ch
    }
    i = i + 1
  }
  res
}

// ─── Pass 2: construction wrapping ──────────────────────────────────────────
/// Rewrite every construction the type checker recorded in `sites` (span key
/// → dotted checker path) into a call through the type's checker.
pub func wrapInvariantConstructions(file: in SourceFile, sites: in Map[String, String]): SourceFile {
  if sites.count == 0 {
    return file
  }
  mapExprsInFile(file, { e: Expr -> wrapIfConstruction(e, sites) })
}

func wrapIfConstruction(e: in Expr, sites: in Map[String, String]): Expr {
  match e.kind {
    case ECall(_, _) -> match mapGet(sites, recordCopySiteKey(e.span)) {
      case Some(checker) -> {
        val parts = Str.split(checker, ".")
        val segs: List[String] = newList()
        var i = 0
        while i < parts.length {
          segs.add(parts[i])
          i = i + 1
        }
        val callee = mkExpr(EPath(path = ModulePath(segments = segs, span = e.span)), e.span)
        val args: List[CallArg] = newList()
        args.add(CAPositional(expr = e))
        // Zero-width span: the wrapper must not share the construction's
        // span key, which later passes use to identify that one call.
        val wrapSpan = Span(startPos = e.span.startPos, endPos = e.span.startPos)
        mkExpr(ECall(fn = callee, args = args), wrapSpan)
      }
      case None -> e
    }
    case _ -> e
  }
}

// ─── Pass 3: public-boundary and `inout` re-checks ──────────────────────────
// docs/08 §7.1 points 2, 3 and 5.  Construction (pass 2) establishes the
// invariant; a `var` field written afterwards, or an `inout` parameter
// updated in place, can break it, so the value is re-checked where it next
// crosses a public boundary.  Every check calls the type's construction
// checker, so the message and clause text are the construction's.
/// The invariant-bearing types a public function's signature can name, by
/// spelled name, with the dotted path of each type's checker.  `foreign`
/// holds the types declared in another package (parameter and result checks);
/// `local` those declared in the function's own package (`inout` re-check).
pub record InvariantBoundary {
  foreign: Map[String, String]
  local: Map[String, String]
}

pub func emptyInvariantBoundary(): InvariantBoundary {
  val f: Map[String, String] = newMap()
  val l: Map[String, String] = newMap()
  InvariantBoundary(foreign = f, local = l)
}

func boundaryIsEmpty(b: in InvariantBoundary): Bool {
  b.foreign.count == 0 and b.local.count == 0
}

func boundaryTypeKey(t: in TypeExpr, selfType: in Option[TypeExpr] = None): Option[String] {
  match t.kind {
    case TRef(path) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < path.segments.count {
        parts.add(path.segments[i])
        i = i + 1
      }
      Some(value = Str.joinList(".", parts))
    }
    case TGenericApp(head, _) -> Some(value = Str.joinList(".", head.segments))
    case TSelf -> match selfType { case Some(st) -> boundaryTypeKey(st, None); case None -> None }
    case TParen(inner) -> boundaryTypeKey(inner, selfType)
    case _ -> None
  }
}

func boundaryChecker(m: in Map[String, String], t: in TypeExpr, selfType: in Option[TypeExpr] = None): Option[String] {
  match boundaryTypeKey(t, selfType) {
    case Some(k) -> mapGet(m, k)
    case None -> None
  }
}

/// The type a signature spells, `Self` replaced by the enclosing type, when it is an application of a generic type
/// (`Cell[String]`, `Cell[T]`); None for any other.
func boundaryGenericType(t: in TypeExpr, selfType: in Option[TypeExpr] = None): Option[TypeExpr] {
  match t.kind {
    case TGenericApp(_, _) -> Some(value = t)
    case TSelf -> match selfType { case Some(st) -> boundaryGenericType(st, None); case None -> None }
    case TParen(inner) -> boundaryGenericType(inner, selfType)
    case _ -> None
  }
}

/// A call of `checker` on `arg`.  A generic type's checker is called by its bare name, whatever package declares it:
/// `Lyric.Mono` specialises a call of a generic function only when the callee is a single segment, and takes the type
/// arguments from the argument's declared type, so the call is `__lyric_checked_Cell(c)` and becomes
/// `__lyric_checked_Cell__String(c)` (#9466).
func checkerCall(checker: in String, arg: in Expr, sp: in Span, isGeneric: in Bool): Expr {
  val parts = Str.split(checker, ".")
  val segs: List[String] = newList()
  if isGeneric {
    segs.add(parts[parts.length - 1])
  } else {
    var i = 0
    while i < parts.length {
      segs.add(parts[i])
      i = i + 1
    }
  }
  val callee = mkExpr(EPath(path = ModulePath(segments = segs, span = sp)), sp)
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = arg))
  mkExpr(ECall(fn = callee, args = args), sp)
}

// `{ checker(arg); true }`: an ensures expression whose evaluation runs the
// checker (which panics on a violation) and holds otherwise.
func checkerHolds(checker: in String, arg: in Expr, sp: in Span, isGeneric: in Bool): Expr {
  val stmts: List[Statement] = newList()
  stmts.add(mkStmt(SExpr(expr = checkerCall(checker, arg, sp, isGeneric)), sp))
  stmts.add(mkStmt(SExpr(expr = mkExpr(ELiteral(lit = LBool(value = true)), sp)), sp))
  mkExpr(EBlock(block = Block(statements = stmts, span = sp)), sp)
}

/// `checkerHolds` on the function's result.  `result` has no type `Lyric.Mono` can read, so a generic type's result is
/// first bound to a local declared at the signature's own type, from which the call's type arguments are read.
func resultCheckerHolds(checker: in String, genericTy: in Option[TypeExpr], sp: in Span): Expr {
  match genericTy {
    case None -> checkerHolds(checker, mkExpr(EResult, sp), sp, false)
    case Some(gt) -> {
      val name = "__lyric_boundary_result"
      val stmts: List[Statement] = newList()
      stmts.add(typedLocal(name, Some(value = gt), mkExpr(EResult, sp), sp))
      stmts.add(mkStmt(SExpr(expr = checkerCall(checker, mkPath(name, sp), sp, true)), sp))
      stmts.add(mkStmt(SExpr(expr = mkExpr(ELiteral(lit = LBool(value = true)), sp)), sp))
      mkExpr(EBlock(block = Block(statements = stmts, span = sp)), sp)
    }
  }
}

/// Entry checks of a public function: each `in` or `inout` parameter of a
/// foreign invariant-bearing type is checked before any `requires:`.
func boundaryEntryChecks(
  params: in List[Param], b: in InvariantBoundary, selfType: in Option[TypeExpr] = None
): List[Statement] {
  val acc: List[Statement] = newList()
  var i = 0
  while i < params.count {
    val p = params[i]
    val isOut = match p.mode { case PMOut -> true; case _ -> false }
    if not isOut {
      match boundaryChecker(b.foreign, p.ty, selfType) {
        case Some(checker) -> {
          val arg = mkPath(p.name, p.span)
          acc.add(mkStmt(SExpr(expr = checkerCall(checker, arg, p.span, boundaryGenericType(p.ty, selfType).isSome())), p.span))
        }
        case None -> ()
      }
    }
    i = i + 1
  }
  acc
}

/// Exit checks of a public function: the result when its type is a foreign
/// invariant-bearing type, and each `inout` / `out` parameter of a foreign or
/// local one, after the body and before the writeback.
func boundaryExitChecks(
  params: in List[Param],
  ret: in Option[TypeExpr],
  b: in InvariantBoundary,
  owner: in String,
  sp: in Span,
  selfType: in Option[TypeExpr] = None,
): List[SpannedExpr] {
  val acc: List[SpannedExpr] = newList()
  var i = 0
  while i < params.count {
    val p = params[i]
    val written = match p.mode { case PMIn -> false; case _ -> true }
    if written {
      val checker = match boundaryChecker(b.foreign, p.ty, selfType) {
        case Some(c) -> Some(value = c)
        case None -> boundaryChecker(b.local, p.ty, selfType)
      }
      match checker {
        case Some(c) -> acc.add(
          SpannedExpr(
            expr = checkerHolds(c, mkPath(p.name, p.span), p.span, boundaryGenericType(p.ty, selfType).isSome()),
            span = p.span,
            message = "InvariantViolated: " + owner + " parameter " + p.name
          )
        )
        case None -> ()
      }
    }
    i = i + 1
  }
  match ret {
    case Some(rt) -> {
      val checker = match boundaryChecker(b.foreign, rt, selfType) {
        case Some(c) -> Some(value = c)
        case None -> if owner.contains("__lyric_checked_") {
          None
        } else {
          boundaryChecker(b.local, rt, selfType)
        }
      }
      match checker {
        case Some(c) -> acc.add(
          SpannedExpr(
            expr = resultCheckerHolds(c, boundaryGenericType(rt, selfType), sp),
            span = sp,
            message = "InvariantViolated: " + owner + " result"
          )
        )
        case None -> ()
      }
    }
    case None -> ()
  }
  acc
}
