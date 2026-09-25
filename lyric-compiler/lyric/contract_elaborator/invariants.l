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
