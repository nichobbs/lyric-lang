//! typechecker_resolver.l — resolves parser TypeExpr to checker Type.
//! Mirrors compiler/src/Lyric.TypeChecker/Resolver.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
pub func resolveType(tbl: in SymbolTable, ctx: in GenericContext, diag: in List[Diagnostic], te: in TypeExpr): Type {
  match te.kind {
    case TUnit -> TyPrim(pt = PtUnit)
    case TSelf -> TySelf
    case TNever -> TyPrim(pt = PtNever)
    case TError -> TyError
    case TParen(inner) -> resolveType(tbl, ctx, diag, inner)

    case TTuple(elems) -> {
      val ts: List[Type] = newList()
      var i = 0
      while i < elems.count {
        ts.add(resolveType(tbl, ctx, diag, elems[i]))
        i = i + 1
      }
      TyTuple(elems = ts)
    }

    case TNullable(inner) -> TyNullable(inner = resolveType(tbl, ctx, diag, inner))

    case TFunction(ps, rte) -> {
      val pts: List[Type] = newList()
      var i = 0
      while i < ps.count {
        pts.add(resolveType(tbl, ctx, diag, ps[i]))
        i = i + 1
      }
      val rt = resolveType(tbl, ctx, diag, rte)
      TyFunction(params = pts, ret = rt, isAsync = false)
    }

    case TArray(_, elem) -> TyArray(size = None, element = resolveType(tbl, ctx, diag, elem))

    case TSlice(elem) -> TySlice(element = resolveType(tbl, ctx, diag, elem))

    case TRef(path) -> {
      val args: List[Type] = newList()
      resolveTypePath(tbl, ctx, diag, path, te.span, args)
    }

    case TGenericApp(head, argsList) -> {
      val resolvedArgs: List[Type] = newList()
      var i = 0
      while i < argsList.count {
        match argsList[i] {
          case TAType(t) -> resolvedArgs.add(resolveType(tbl, ctx, diag, t))
          case TAValue(ve) -> {
            diag.add(errorDiagnostic("T0109", "value expression used as type argument", ve.span))
            resolvedArgs.add(TyError)
          }
        }
        i = i + 1
      }
      resolveTypePath(tbl, ctx, diag, head, te.span, resolvedArgs)
    }

    case TRefined(under, range) -> {
      val args: List[Type] = newList()
      val baseTy = resolveTypePath(tbl, ctx, diag, under, te.span, args)
      val lo = rangeLo(range)
      val hi = rangeHi(range)
      val inc = rangeHiInclusive(range)
      TyRefined(underlying = baseTy, lo = lo, hi = hi, hiInclusive = inc)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §1a. Range-bound extraction (for inline refined types `T range lo .. hi`).
// ─────────────────────────────────────────────────────────────────────────────
// A `ULong` value from 2^63 to 2^64-1 (`18446744073709551615u64`, #7839)
// is carried in a `Long` as its two's-complement pattern.  These helpers
// order and render such a pattern as the unsigned value it stands for.
pub func ulongLessThan(a: in Long, b: in Long): Bool {
  if (a < 0i64) == (b < 0i64) {
    a < b
  } else {
    b < 0i64
  }
}

pub func ulongPatternToString(v: in Long): String {
  if v >= 0i64 {
    return toString(v)
  }
  // v + 2^64 = h + 2^63 with h = v + 2^63 in [0, 2^63); 2^63 is
  // 922337203685477580 * 10 + 8.
  val h = v + 9223372036854775807i64 + 1i64
  val lowSum = h % 10i64 + 8i64
  val q = h / 10i64 + 922337203685477580i64 + lowSum / 10i64
  toString(q) + toString(lowSum % 10i64)
}

// Extract a compile-time integer value from a bound expression, peeling a
// unary minus and parentheses.  Returns `None` for any non-integer-literal
// endpoint (those are out of scope for the inline range check; named
// distinct range subtypes with computed bounds are Band-4 work).
pub func exprLiteralLong(e: in Expr): Option[Long] {
  match e.kind {
    case ELiteral(lit) -> match lit { case LInt(v, _, _) -> Some(value = v); case _ -> None }
    case EParen(inner) -> exprLiteralLong(inner)
    case EPrefix(op, operand) -> match op {
      case PreNeg -> match exprLiteralLong(operand) {
        case Some(v) -> Some(value = 0i64 - v)
        case None -> None
      }
      case _ -> None
    }
    case _ -> None
  }
}

func rangeLo(rb: in RangeBound): Option[Long] {
  match rb {
    case RBClosed(lo, _) -> exprLiteralLong(lo)
    case RBHalfOpen(lo, _, _) -> exprLiteralLong(lo)
    case RBLowerOpen(_) -> None
    case RBUpperOpen(lo) -> exprLiteralLong(lo)
  }
}

func rangeHi(rb: in RangeBound): Option[Long] {
  match rb {
    case RBClosed(_, hi) -> exprLiteralLong(hi)
    case RBHalfOpen(_, hi, _) -> exprLiteralLong(hi)
    case RBLowerOpen(hi) -> exprLiteralLong(hi)
    case RBUpperOpen(_) -> None
  }
}

// `..=` / `..= b` are inclusive; `..` / `..< b` are half-open.  An
// upper-open bound (`a ..`) has no hi endpoint, so inclusivity is moot —
// report `true` (the `MAX` end is inclusive).
func rangeHiInclusive(rb: in RangeBound): Bool {
  match rb {
    case RBClosed(_, _) -> true
    case RBHalfOpen(_, _, _) -> false
    case RBLowerOpen(_) -> true
    case RBUpperOpen(_) -> true
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Path resolution helper.
// ─────────────────────────────────────────────────────────────────────────────
// Resolve a symbol found in type position to a `Type`.  A `pub alias X = Y`
// type-alias re-export (`DKTypeAlias`) is followed to its target `Y` — this is
// how the stdlib re-exports an extern type for callers (`pub alias Random =
// Std.RandomHost.Random`).  Concrete type symbols (records, unions, extern
// types, …) resolve to their `TyUser`; a non-type symbol is a T0013.
func symbolToType(
  tbl: in SymbolTable,
  ctx: in GenericContext,
  diag: in List[Diagnostic],
  sym: in Symbol,
  args: in List[Type],
  span: in Span,
): Type {
  match sym.kind {
    case DKTypeAlias(decl) -> {
      checkImportedVisibility(sym, span, diag)
      resolveAliasRhs(tbl, ctx, diag, decl, 0, args, span)
    }
    case _ -> match symbolTypeIdOpt(sym) {
      case Some(tid) -> {
        checkImportedVisibility(sym, span, diag)
        TyUser(id = tid, name = sym.name, args = args)
      }
      case None -> {
        diag.add(errorDiagnostic("T0013", "'" + sym.name + "' is not a type", span))
        TyError
      }
    }
  }
}

// Follow a type alias's right-hand side to a concrete `Type`.  `depth` counts
// how many alias hops have been followed on this chain.  Real alias chains are
// a handful of links deep; passing the bound (64, see `resolveAliasPath`) means
// the chain is cyclic (`alias A = B` / `alias B = A`) — a malformed program —
// so it stops with a clean T0017 rather than recursing to a stack overflow.  A
// bounded counter is used instead of a visited-name set because the F# stage-0
// bootstrap emitter (which compiles this file) cannot yet codegen the
// `List[String]` threading that would require; this mirrors the depth-bound the
// YAML/JSON parser uses for nested collections.  `args` are the type arguments
// supplied at the use site (empty for the non-generic re-export form the stdlib
// uses).
func resolveAliasRhs(
  tbl: in SymbolTable,
  ctx: in GenericContext,
  diag: in List[Diagnostic],
  decl: in TypeAliasDecl,
  depth: in Int,
  args: in List[Type],
  span: in Span,
): Type {
  match decl.rhs.kind {
    case TRef(path) -> resolveAliasPath(tbl, ctx, diag, path, depth, args, span)
    case TGenericApp(head, argsList) -> {
      val resolvedArgs: List[Type] = newList()
      var i = 0
      while i < argsList.count {
        match argsList[i] {
          case TAType(t) -> resolvedArgs.add(resolveType(tbl, ctx, diag, t))
          case TAValue(ve) -> {
            diag.add(errorDiagnostic("T0109", "value expression used as type argument in alias", ve.span))
            resolvedArgs.add(TyError)
          }
        }
        i = i + 1
      }
      resolveAliasPath(tbl, ctx, diag, head, depth, resolvedArgs, span)
    }
    case _ -> resolveType(tbl, ctx, diag, decl.rhs)
  }
}

// The `TyUser` for `sym` when it is a concrete type symbol, else `None`.
// Helper for `resolveAliasPath`'s scope-priority lookup (#2611).
func concreteAliasTarget(sym: in Symbol, args: in List[Type], span: in Span, diag: in List[Diagnostic]): Option[Type] {
  match symbolTypeIdOpt(sym) {
    case Some(tid) -> {
      checkImportedVisibility(sym, span, diag)
      Some(value = TyUser(id = tid, name = sym.name, args = args))
    }
    case None -> None
  }
}

// Resolve an alias target path to a `Type`, preferring a concrete (non-alias)
// type symbol of the path's final segment so the lookup cannot loop back on
// the alias being expanded.  Falls through to a chained alias (bounded to 64
// hops so a cycle yields a T0017 rather than unbounded recursion), then to a
// primitive, then to T0013.
func resolveAliasPath(
  tbl: in SymbolTable,
  ctx: in GenericContext,
  diag: in List[Diagnostic],
  path: in ModulePath,
  depth: in Int,
  args: in List[Type],
  span: in Span,
): Type {
  val last = path.segments[path.segments.count - 1]
  match primFromString(last) {
    case Some(prim) -> {
      if args.count > 0 {
        diag.add(errorDiagnostic("T0012", "primitive type '" + last + "' does not take type arguments", span))
      }
      return TyPrim(pt = prim)
    }
    case None -> {
    }
  }
  // A qualified target (`alias X = PA.Thing`, rewritten to `PkgA.Thing`)
  // names its package: resolve there, never through a same-named type the
  // file sees bare.
  if path.segments.count > 1 {
    return resolveQualifiedAliasPath(tbl, ctx, diag, path, depth, args, span)
  }
  // Scope-priority first (#2611): `symTableTryFindOne` honours the current
  // resolution scope (current package > imports > any), so an alias target
  // sharing its name with a type from another package resolves to the
  // scope-closest declaration — mirroring `resolveTypePath`.  Only a concrete
  // type symbol is taken here; an alias (no `TypeId`) falls through to the
  // insertion-order scan below, which prefers concrete types so the lookup
  // cannot loop back on the alias being expanded.
  match symTableTryFindOne(tbl, last) {
    case Some(scopedSym) -> {
      match concreteAliasTarget(scopedSym, args, span, diag) {
        case Some(t) -> {
          return t
        }
        case None -> {
        }
      }
    }
    case None -> {
    }
  }
  // Only what the file's import rule lets it name bare (docs/01 §9.2).
  val all = symTableTryFindAllVisible(tbl, last)
  // Then, any concrete type (record / union / extern type / …).
  var i = 0
  while i < all.count {
    match symbolTypeIdOpt(all[i]) {
      case Some(tid) -> {
        checkImportedVisibility(all[i], span, diag)
        return TyUser(id = tid, name = all[i].name, args = args)
      }
      case None -> {
      }
    }
    i = i + 1
  }
  // Then, a chained alias — but stop at the depth bound so a cycle
  // (`alias A = B` / `alias B = A`) produces a clean diagnostic instead of
  // recursing to a stack overflow.
  var j = 0
  while j < all.count {
    match all[j].kind {
      case DKTypeAlias(d2) -> {
        if depth >= 64 {
          diag.add(
            errorDiagnostic("T0017", "type alias '" + d2.name + "' is part of a cycle and does not resolve to a type", span)
          )
          return TyError
        }
        return resolveAliasRhs(tbl, ctx, diag, d2, depth + 1, args, span)
      }
      case _ -> {
      }
    }
    j = j + 1
  }
  if all.count == 0 {
    diag.add(errorDiagnostic("T0010", "unknown type name '" + last + "'" + symTableHiddenImportHint(tbl, last), span))
    return TyError
  }
  diag.add(errorDiagnostic("T0013", "'" + last + "' is not a type", span))
  TyError
}

// #7548: type-position counterpart of `checkQualifiedPackageRef`
// (typechecker_exprs.l) — a multi-segment TYPE path's qualifier names a
// package exactly the way a qualified expression path does (docs/01
// §9.2), so a qualifier outside the file's import closure (directly or
// transitively via `qualifiedPkgReachable`) is T0020 here too, with the
// same message shape and the same `Std.Core`/same-package exemptions.
// Only fires when the qualifier is a package the checker actually loaded
// (`symTablePackageHasAnySymbol`/an `extern package` block), mirroring the
// expression-position guard against a deferred host path (`System.Console`).
//
// Privacy (T0097) is NOT this function's job: `symbolToType` already calls
// `checkImportedVisibility` for every type symbol this path resolves to
// (single- and multi-segment alike — see the `#1957`/`visibility multi
// segment private type rejected` test), so adding a second T0097 site here
// would double-report. Type-expr grammar also has no `Scope`: a `TypeExpr`
// path is always a dotted type name, never a local's own field chain, so
// this needs only the reachability test, not
// `checkQualifiedPackageRef`'s scope-root / local-shadow guard.
func checkQualifiedTypePackageRef(
  tbl: in SymbolTable,
  pkgSegs: in List[String],
  member: in String,
  span: in Span,
  diag: in List[Diagnostic],
): Bool {
  val curPkg = symTableScopePkg(tbl)
  if curPkg.length == 0 or pkgSegs.count == 0 {
    return false
  }
  val pkg = modulePathJoin(pkgSegs)
  if pkg == curPkg or pkg == "Std.Core" {
    return false
  }
  if not (symTablePackageHasAnySymbol(tbl, pkg) or symTablePackageHasAnyExternBlockMember(tbl, pkg)) {
    return false
  }
  // #7499 parity: a package-private type is T0097, never T0020, whether or
  // not its declaring package is imported — adding an import cannot make a
  // private type nameable. Checked before reachability (mirroring
  // `checkUnimportedTypeReceiver`'s ordering), leaving the actual T0097 to
  // the normal `symbolToType` → `checkImportedVisibility` flow below so it
  // fires exactly once instead of being pre-empted by a T0020 here.
  match symTableTryFindInPackage(tbl, pkg, member) {
    case Some(sym) -> if symbolIsType(sym) and symbolIsPackagePrivateBinding(sym) { return false }
    case None -> ()
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
  false
}

// An alias target qualified by its package: a type, or a chained alias,
// declared by that package; the trailing segment alone never resolves it
// elsewhere.  A package that re-exports the name through its own imports (the
// kernel/host idiom) is followed like `resolveTypePath`'s qualified arm.
func resolveQualifiedAliasPath(
  tbl: in SymbolTable,
  ctx: in GenericContext,
  diag: in List[Diagnostic],
  path: in ModulePath,
  depth: in Int,
  args: in List[Type],
  span: in Span,
): Type {
  val last = path.segments[path.segments.count - 1]
  val ownerSegs: List[String] = newList()
  var i = 0
  while i < path.segments.count - 1 {
    ownerSegs.add(path.segments[i])
    i = i + 1
  }
  val ownerPkg = modulePathJoin(ownerSegs)
  val owners: List[String] = newList()
  owners.add(ownerPkg)
  match mapGet(tbl.packageImports, ownerPkg) {
    case Some(reexported) -> {
      for r in reexported {
        owners.add(r)
      }
    }
    case None -> ()
  }
  for owner in owners {
    match symTableTryFindInPackage(tbl, owner, last) {
      case Some(sym) -> {
        match concreteAliasTarget(sym, args, span, diag) {
          case Some(t) -> return t
          case None -> ()
        }
        match sym.kind {
          case DKTypeAlias(d2) -> {
            if depth >= 64 {
              diag.add(
                errorDiagnostic("T0017", "type alias '" + d2.name + "' is part of a cycle and does not resolve to a type", span)
              )
              return TyError
            }
            return resolveAliasRhs(tbl, ctx, diag, d2, depth + 1, args, span)
          }
          case _ -> ()
        }
      }
      case None -> ()
    }
  }
  diag.add(
    errorDiagnostic(
      "T0014",
      "unknown qualified type '" + modulePathJoin(path.segments) + "' ('" + last + "' not found in " + ownerPkg + ")",
      span
    )
  )
  TyError
}

func resolveTypePath(
  tbl: in SymbolTable,
  ctx: in GenericContext,
  diag: in List[Diagnostic],
  path: in ModulePath,
  span: in Span,
  args: in List[Type],
): Type {
  if path.segments.count == 0 {
    diag.add(errorDiagnostic("T0010", "empty module path in type position", span))
    return TyError
  }
  if path.segments.count == 1 {
    val name = path.segments[0]
    match primFromString(name) {
      case Some(prim) -> {
        if args.count > 0 {
          diag.add(errorDiagnostic("T0012", "primitive type '" + name + "' does not take type arguments", span))
        }
        return TyPrim(pt = prim)
      }
      case None -> {
      }
    }
    if gctxIsTypeParam(ctx, name) and args.count == 0 {
      return TyVar(name = name)
    }
    match symTableTryFindOne(tbl, name) {
      case Some(sym) -> {
        if symbolIsType(sym) {
          return symbolToType(tbl, ctx, diag, sym, args, span)
        }
        // The scope-resolved symbol is not a type (e.g. a union case or
        // function sharing a type's name — `Insn.Token` vs a sibling
        // record `Token` in a flattened restored-contract source).  In
        // type position a *type* symbol of the same name must win, so
        // scan the full candidate set before reporting T0013 — mirrors
        // `resolveAliasPath`'s concrete-type-first preference.
        val all = symTableTryFindAllVisible(tbl, name)
        var ti = 0
        while ti < all.count {
          if symbolIsType(all[ti]) {
            return symbolToType(tbl, ctx, diag, all[ti], args, span)
          }
          ti = ti + 1
        }
        return symbolToType(tbl, ctx, diag, sym, args, span)
      }
      case None -> {
        diag.add(errorDiagnostic("T0010", "unknown type name '" + name + "'" + symTableHiddenImportHint(tbl, name), span))
        return TyError
      }
    }
  }
  // Multi-segment: resolve against the symbol table using the last segment.
  // Types from checkWithImports are registered by simple name, so
  // `Std.Collections.List` resolves to the same entry as `List` when `List`
  // was imported.  Fall through to primitive check, then T0014.
  val last = path.segments[path.segments.count - 1]
  // A multi-segment path names its owning package EXPLICITLY — either
  // written literally, or flattened by `Lyric.AliasRewriter` from
  // `import X as Y` + `Y.Type`.  When `symTableTryFindOne`'s scope-priority
  // tie-break below would pick a symbol from a DIFFERENT package (it prefers
  // the CURRENT package's own same-short-name symbol — correct only for a
  // BARE unqualified reference), re-resolve against a candidate whose
  // `originPackage` matches the written owner instead.  Without this, a
  // qualified reference to an imported type whose short name collides with
  // a type declared in the referencing package's OWN package silently
  // resolved to the wrong (local) type — #6338.
  //
  // The override is GATED on the default pick actually mismatching the
  // owner: when the tie-break already resolves to the owning package, that
  // exact symbol entry must be used — `symTableTryFindAll`'s candidate
  // order can hold more than one entry for the same conceptual type
  // (multi-package builds register cross-package decls per consumer), and
  // taking a different entry than every bare reference resolves to breaks
  // nominal type identity (two `Result[Unit, SecretsError]`s that print
  // identically but compare unequal — the lyric-aws-secrets T0065/
  // InvalidProgramException regression this gate fixed).
  val ownerSegs: List[String] = newList()
  var osi = 0
  while osi < path.segments.count - 1 {
    ownerSegs.add(path.segments[osi])
    osi = osi + 1
  }
  val ownerPkg = modulePathJoin(ownerSegs)
  // #7548: an unimported qualifier is T0020 before any lookup — otherwise a
  // package the checker "knows" only because `Lyric.Pipeline` preloaded
  // every stdlib package's signatures (D-progress-1011) would resolve
  // silently here just as it did for the expression-position case.
  if checkQualifiedTypePackageRef(tbl, ownerSegs, last, span, diag) {
    return TyError
  }
  val defaultPick = symTableTryFindOne(tbl, last)
  val defaultPickMatchesOwner = match defaultPick {
    case Some(pref) -> symbolIsType(pref) and pref.originPackage == ownerPkg
    case None -> false
  }
  if not defaultPickMatchesOwner {
    val qualifiedCands = symTableTryFindAll(tbl, last)
    var qi = 0
    while qi < qualifiedCands.count {
      if qualifiedCands[qi].originPackage == ownerPkg and symbolIsType(qualifiedCands[qi]) {
        return symbolToType(tbl, ctx, diag, qualifiedCands[qi], args, span)
      }
      qi = qi + 1
    }
  }
  match defaultPick {
    case Some(sym) -> {
      if symbolIsType(sym) {
        return symbolToType(tbl, ctx, diag, sym, args, span)
      }
      // Same type-symbol preference as the single-segment arm: a non-type
      // symbol shadowing a same-named type must not hide it in type position.
      val all = symTableTryFindAll(tbl, last)
      var ti = 0
      while ti < all.count {
        if symbolIsType(all[ti]) {
          return symbolToType(tbl, ctx, diag, all[ti], args, span)
        }
        ti = ti + 1
      }
    }
    case None -> {
    }
  }
  match primFromString(last) {
    case Some(prim) -> {
      if args.count > 0 {
        diag.add(errorDiagnostic("T0012", "primitive type '" + last + "' does not take type arguments", span))
      }
      TyPrim(pt = prim)
    }
    case None -> {
      val joined = modulePathJoin(path.segments)
      diag.add(
        errorDiagnostic("T0014", "unknown qualified type '" + joined + "' ('" + last + "' not found in scope)", span)
      )
      TyError
    }
  }
}

// #1484: enforce visibility at use sites.  A reference to an *imported*
// (cross-package) symbol is rejected (T0097) only when the symbol is
// package-private (no modifier) — per language reference §3.1, `pub` and
// `internal` are both visible across packages within a project, while an
// unmarked declaration is visible only inside its own package.  The
// cross-*project* hiding of `internal` is enforced at the link/restore layer
// (only `pub` symbols are published in a package's external contract), so it is
// out of scope here.  Same-package references (`isImported = false`) are
// unaffected — a package is checked as one unit, so every sibling-file symbol
// is in-package.  (The `V0007`/`V0008` codes suggested in #1484 are already
// owned by the verifier; visibility uses the type-checker code T0097.)
func checkImportedVisibility(sym: in Symbol, span: in Span, diag: in List[Diagnostic]): Unit {
  if sym.isImported {
    // Extern types / extern packages are host-binding (FFI boundary)
    // declarations: the pub/internal/package-private tiers do not apply to
    // them.  Collection types such as `List`/`Map` are `extern type` aliases
    // (no `pub` modifier) yet are referenced directly across every package, so
    // they must not be flagged.  Their cross-package accessibility is governed
    // by the kernel-boundary convention, not the visibility check.
    val isExternBinding = match sym.kind { case DKExternType(_, _) -> true; case DKExtern(_) -> true; case _ -> false }
    if not isExternBinding {
      match sym.visibility {
        case Some(_) -> {
        }
        // pub or internal — visible cross-package in a project
        case None -> diag.add(
          errorDiagnostic(
            "T0097",
            "'" + sym.name + "' is package-private and cannot be referenced from " +
              "another package (mark it `pub` or `internal`)",
            span
          )
        )
      }
    }
  }
}

func joinPackageNames(pkgs: in List[String]): String {
  var result = ""
  var i = 0
  while i < pkgs.count {
    if i > 0 {
      result = result + ", "
    }
    result = result + "'" + pkgs[i] + "'"
    i = i + 1
  }
  result
}

// #6287 (bare-name ambiguity): a bare reference to `name` that resolves
// against two or more distinct imported packages' `pub`/`internal`
// declarations is genuinely ambiguous — silently picking the last-registered
// one hid a real collision (the issue's headline symptom). Call at every
// authoritative bare-name resolution site (never from an internal helper
// that merely probes whether a name exists, to avoid double-emitting the
// same diagnostic for one source reference). Returns `true` (and emits
// T0123) when ambiguous, so the caller can short-circuit to `TyError`/`None`
// instead of also reporting a misleading downstream error against whichever
// candidate it would otherwise have picked.
pub func checkBareNameAmbiguity(tbl: in SymbolTable, diag: in List[Diagnostic], name: in String, span: in Span): Bool {
  val pkgs = symTableAmbiguousImportPackages(tbl, name)
  if pkgs.count >= 2 {
    diag.add(
      errorDiagnostic(
        "T0123",
        "'" + name + "' is ambiguous: it is declared by " + joinPackageNames(pkgs) +
          (
            if symTableIsDirectImport(tbl, pkgs[0]) {
              ", all imported here"
            } else {
              ", all reached through this file's imports"
            }
          ) +
          " — qualify the reference (e.g. '" +
          pkgs[0] +
          "." +
          name +
          "')",
        span
      )
    )
    true
  } else {
    false
  }
}
