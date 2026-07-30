//! lyric/alias_rewriter.l — AST-level rewriter for `import X as A`
//! package aliases (#1378 follow-up).
//!
//! Bootstrap-grade alias semantics (matching D-progress-018):
//!
//!   import Auth.Kernel.Net as AuthKernelNet
//!   val r = AuthKernelNet.verifyJwtImpl(token, secret)
//!
//! is treated as syntactic sugar for
//!
//!   import Auth.Kernel.Net
//!   val r = verifyJwtImpl(token, secret)
//!
//! The rewriter runs after parsing and before type-check, walking
//! every `Expr`, `TypeExpr`, `Pattern`, and `ConstraintRef` in the
//! user's source file.  Selector-level aliases
//! (`import X.{foo as bar}`) are NOT handled here — they're cloned
//! into the imported-items list by the emitter so the original symbol
//! is registered under both names.
//!
//! Mirrors `bootstrap/src/Lyric.Parser/AliasRewriter.fs` so the
//! self-hosted pipeline gets the same alias-collapsing behaviour the
//! F# emitter relies on.  Wired into the self-hosted MSIL bridge via
//! `Msil.Bridge.compileToMsil*` between parse and typecheck (#1378's
//! `AuthKernelNet` symptom).
//!
//! Out-of-scope (bootstrap):
//!   - The rewriter is scope-blind.  A local variable named `Coll`
//!     after `import X as Coll` would collide; users should pick
//!     alias names that don't shadow locals.
//!   - Aliases on non-builtin user packages aren't yet wired through
//!     the emitter's package resolver for stdlib-call codegen, so
//!     this only meaningfully fires for intra-project aliases and
//!     stdlib imports today.
package Lyric.AliasRewriter

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Alias collection.
// ─────────────────────────────────────────────────────────────────────────────
// Helper: extract `asAlias` through an explicit function-typed
// indirection.  Works around the F# emitter's #1140 cross-package
// generic-arg widening bug — `imports[i].asAlias` peeks as
// `System.Object.asAlias` when the list element type widens, but a
// dedicated function with an `ImportDecl` parameter keeps the static
// type stable for codegen.  Self-hosted bridge isn't affected; this
// only matters when the F# stage-0 compiler builds this DLL.
//
// Note (#1451): the same #1140-class widening fires on bare `None`
// match arms — `case None -> None` produces an `Option[obj]` value
// whose stale generic arg poisons downstream type-inference for the
// containing `match` expression.  Every Option-shaped match in this
// file therefore returns the matched expression itself in the None
// arm (e.g. `case None -> ty`) so the arm reuses the input's fully
// resolved `Option[T]` static type instead of synthesising a fresh
// `None`.  Stage-1 (self-hosted) builds aren't affected, but the F#
// stage-0 compiler must produce a working `Lyric.AliasRewriter.dll`,
// and bare `None` in this file breaks `lyric build --manifest
// lyric-stdlib/lyric.toml`.
func asAliasOf(imp: in ImportDecl): Option[String] {
  imp.asAlias
}

// Build a list of single-segment alias names from the source file's
// imports.  Only `import X as A`-style aliases participate; selector
// aliases (`{ foo as bar }`) are handled elsewhere.
//
// A list is used instead of a set because the typechecker isn't a
// hot path for huge alias counts — linear membership is plenty.
//
// Each entry is `"<alias>=<dotted declaring package>"`, e.g. `"Rx=Std.RegexSafe"`,
// so a later `Rx.foo` rewrite can substitute the alias head with the full package
// path (preserving which package the call/type targets) rather than dropping it.
// `=` is a safe separator: neither identifiers nor package names contain it.
//
// Bare `import X` / `import A.B.X` (no `as` clause) is treated as an implicit
// `import ... as X`: the tail segment `X` is registered as an alias for the
// full dotted path so that `X.func(...)` call sites are rewritten from
// `EMember(EPath(["X"]), "func")` to the flat `EPath([..., "X", "func"])` form
// that `lowerBuiltinOrStaticCallMsil` can dispatch correctly.  Without this,
// the call lands in `lowerMethodCallMsil` which looks for `func` as a method
// on an unknown receiver and throws at runtime (#2930 single-segment, #2929
// multi-segment).  Explicit `as` aliases are collected first and win: a bare
// import never shadows a name an explicit alias already claims.  Two bare
// imports sharing a tail segment (`import Foo.Bar` + `import Other.Bar`)
// resolve first-wins in source order with no diagnostic — matching the
// existing duplicate-explicit-alias behavior; add an explicit `as` clause to
// disambiguate (#3250).
func collectAliases(imports: in List[ImportDecl]): List[String] {
  val entries: List[String] = newList()
  var i = 0
  while i < imports.count {
    val imp = imports[i]
    if not imp.isExtern {
      match asAliasOf(imp) {
        case Some(name) -> {
          val dotted = modulePathJoin(imp.path.segments)
          entries.add(name + "=" + dotted)
          // Self-mapped full-path key (#6294 follow-up): `import Pkg.Sub as X`
          // makes `X.foo(...)` the idiomatic call form, but the ORIGINAL
          // dotted name (`Pkg.Sub.foo(...)`) is still valid Lyric and parses
          // the same way — a qualified-call `EMember` chain, not a
          // single-segment `EPath` head. Without this, calling via the
          // pre-alias name (instead of the alias) hits the exact #6294
          // silent-`TyError` gap this fix exists to close, just reached
          // through an aliased rather than bare import.
          if not aliasContains(entries, dotted) {
            entries.add(dotted + "=" + dotted)
          }
        }
        case None -> ()
      }
    }
    i = i + 1
  }
  var j = 0
  while j < imports.count {
    val imp = imports[j]
    if not imp.isExtern {
      match asAliasOf(imp) {
        case Some(_) -> ()
        case None -> {
          if imp.path.segments.count >= 1 {
            val dotted = modulePathJoin(imp.path.segments)
            val tail = imp.path.segments[imp.path.segments.count - 1]
            if not aliasContains(entries, tail) {
              entries.add(tail + "=" + dotted)
            }
            // Self-mapped full-path key (#6294): a bare `import Pkg.Sub` is
            // also referenced at call sites by its FULL dotted spelling
            // (`Pkg.Sub.func(...)`), which the expression parser produces as
            // nested `EMember`s, not a single-segment `EPath` head — the
            // tail-only key above only matches the one-dot-short form
            // (`Sub.func(...)`). Registering the whole dotted path as its own
            // key lets `rewriteExpr`'s EMember-chain flattening recognise the
            // fully-qualified form too, for a package name of ANY segment
            // count (a single-segment import's tail key already covers it,
            // so this is a no-op there and only matters for segments.count >= 2).
            if dotted != tail and not aliasContains(entries, dotted) {
              entries.add(dotted + "=" + dotted)
            }
          }
        }
      }
    }
    j = j + 1
  }
  entries
}

func aliasContains(aliases: in List[String], name: in String): Bool {
  val pfx = name + "="
  var i = 0
  while i < aliases.count {
    if Str.startsWith(aliases[i], pfx) {
      return true
    }
    i = i + 1
  }
  false
}

// The declaring-package segments for alias `name` (empty list if unknown).
func aliasPkgSegs(aliases: in List[String], name: in String): List[String] {
  val pfx = name + "="
  val acc: List[String] = newList()
  var i = 0
  while i < aliases.count {
    if Str.startsWith(aliases[i], pfx) {
      val kv = Str.split(aliases[i], "=")
      if kv.length >= 2 {
        val segs = Str.split(kv[1], ".")
        var k = 0
        while k < segs.length {
          acc.add(segs[k])
          k = k + 1
        }
      }
      return acc
    }
    i = i + 1
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. ModulePath rewriting.
// ─────────────────────────────────────────────────────────────────────────────
// `Rx.tryCompile` (segments = ["Rx", "tryCompile"]) where `Rx` aliases
// `Std.RegexSafe` rewrites to the fully-qualified `Std.RegexSafe.tryCompile`
// (segments = ["Std", "RegexSafe", "tryCompile"]) — the package prefix is
// preserved so resolution can disambiguate same-name symbols across packages
// (#1488 regex_safe).  Single-segment paths and paths whose head isn't an alias
// pass through unchanged.
func rewritePath(aliases: in List[String], p: in ModulePath): ModulePath {
  if p.segments.count < 2 {
    return p
  }
  if not aliasContains(aliases, p.segments[0]) {
    return p
  }
  val acc: List[String] = newList()
  val pkg = aliasPkgSegs(aliases, p.segments[0])
  var k = 0
  while k < pkg.count {
    acc.add(pkg[k])
    k = k + 1
  }
  var i = 1
  while i < p.segments.count {
    acc.add(p.segments[i])
    i = i + 1
  }
  ModulePath(segments = acc, span = p.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. TypeExpr / TypeArg / RangeBound / ConstraintRef.
// ─────────────────────────────────────────────────────────────────────────────
func rewriteTypeExpr(aliases: in List[String], te: in TypeExpr): TypeExpr {
  val kind = match te.kind {
    case TRef(path) -> TRef(path = rewritePath(aliases, path))
    case TGenericApp(head, args) -> {
      val args2: List[TypeArg] = newList()
      var i = 0
      while i < args.count {
        args2.add(rewriteTypeArg(aliases, args[i]))
        i = i + 1
      }
      TGenericApp(head = rewritePath(aliases, head), args = args2)
    }
    case TArray(size, element) -> TArray(size = rewriteTypeArg(aliases, size), element = rewriteTypeExpr(aliases, element))
    case TSlice(element) -> TSlice(element = rewriteTypeExpr(aliases, element))
    case TRefined(underlying, range) -> TRefined(underlying = rewritePath(aliases, underlying), range = rewriteRangeBound(aliases, range))
    case TTuple(types) -> {
      val xs: List[TypeExpr] = newList()
      var i = 0
      while i < types.count {
        xs.add(rewriteTypeExpr(aliases, types[i]))
        i = i + 1
      }
      TTuple(types = xs)
    }
    case TNullable(inner) -> TNullable(inner = rewriteTypeExpr(aliases, inner))
    case TFunction(parameters, retTy) -> {
      val ps: List[TypeExpr] = newList()
      var i = 0
      while i < parameters.count {
        ps.add(rewriteTypeExpr(aliases, parameters[i]))
        i = i + 1
      }
      TFunction(parameters = ps, retTy = rewriteTypeExpr(aliases, retTy))
    }
    case TParen(inner) -> TParen(inner = rewriteTypeExpr(aliases, inner))
    case TUnit -> TUnit
    case TSelf -> TSelf
    case TNever -> TNever
    case TError -> TError
  }
  TypeExpr(kind = kind, span = te.span)
}

func rewriteTypeArg(aliases: in List[String], a: in TypeArg): TypeArg {
  match a {
    case TAType(ty) -> TAType(ty = rewriteTypeExpr(aliases, ty))
    case TAValue(expr) -> TAValue(expr = rewriteExpr(aliases, expr))
  }
}

func rewriteRangeBound(aliases: in List[String], rb: in RangeBound): RangeBound {
  match rb {
    case RBClosed(lo, hi) -> RBClosed(lo = rewriteExpr(aliases, lo), hi = rewriteExpr(aliases, hi))
    case RBHalfOpen(lo, hi) -> RBHalfOpen(lo = rewriteExpr(aliases, lo), hi = rewriteExpr(aliases, hi))
    case RBLowerOpen(hi) -> RBLowerOpen(hi = rewriteExpr(aliases, hi))
    case RBUpperOpen(lo) -> RBUpperOpen(lo = rewriteExpr(aliases, lo))
  }
}

// Flatten a pure dotted-access expression — an `EPath` or a chain of
// `EMember`s ultimately rooted at one — into its full segment list.  `None`
// for anything else (a call, index, literal, …), so the caller only ever
// treats a genuine dotted-name chain as a package-qualification candidate.
// Does NOT unwrap `EParen`: a parenthesized qualified callee
// (`(Pkg.Sub).foo()`) still falls back to the pre-#6294 depth-1-only
// behavior. Not a regression from #6294 — parens around a qualified callee
// were never handled before it either — and narrow enough in practice
// (nobody parenthesizes a bare package-qualified path) that it's left as a
// known gap rather than risking new span/precedence edge cases for an
// unobserved shape.
func flattenPathExpr(e: in Expr): Option[List[String]] {
  match e.kind {
    // Copy, not the parsed AST's own `p.segments` by reference — matches the
    // `EMember` arm below, which always builds a fresh list. No current
    // caller mutates the result, but returning the original list here would
    // be a latent aliasing hazard for a future one (review follow-up, #6323).
    case EPath(p) -> {
      val acc: List[String] = newList()
      var i = 0
      while i < p.segments.count {
        acc.add(p.segments[i])
        i = i + 1
      }
      Some(value = acc)
    }
    case EMember(receiver, memberName) -> match flattenPathExpr(receiver) { case Some(segs) -> { val acc: List[String] = newList(); var i = 0; while i < segs.count { acc.add(segs[i]); i = i + 1 }; acc.add(memberName); Some(value = acc) }; case None -> None }
    case _ -> None
  }
}

// Join every segment of `segs` with "." — the candidate package-qualifier
// tried by `rewriteQualifiedMemberChain`.
func joinSegs(segs: in List[String]): String {
  var s = segs[0]
  var i = 1
  while i < segs.count {
    s = s + "." + segs[i]
    i = i + 1
  }
  s
}

// Rebuild `pkgSegs ++ [trailingMember]` as a flat `EPath`. `pathSpan` is the
// ORIGINAL receiver chain's own span (just `Pkg.Sub`, not the trailing
// member) — the synthesized `ModulePath`'s span, matching what the
// single-segment-only code this generalizes used (`p.span`, the bare alias
// identifier's span, not the whole call's). `outerSpan` is the full original
// expression's span (`e.span`), used for the synthesized `Expr` node exactly
// as before.
func rebuildQualifiedChain(
  pkgSegs: in List[String], trailingMember: in String, pathSpan: in Span, outerSpan: in Span
): Expr {
  val baseSegs: List[String] = newList()
  var i = 0
  while i < pkgSegs.count {
    baseSegs.add(pkgSegs[i])
    i = i + 1
  }
  baseSegs.add(trailingMember)
  Expr(kind = EPath(path = ModulePath(segments = baseSegs, span = pathSpan)), span = outerSpan)
}

// The `Alias.foo(...)` / `Pkg.Sub.foo(...)` CALL-CALLEE rewrite (invoked only
// from the `ECall` arm — see its comment for why this never applies to a
// plain, non-called qualified value reference): given a call's callee
// `EMember`'s receiver chain fully flattened to `recvSegs`, collapse the
// WHOLE chain into a flat `EPath` ONLY when it matches a known
// alias/package-path key in its ENTIRETY (`aliasContains`) — never a partial
// prefix, and never retried against a shorter prefix on a miss. A
// single-segment package name or explicit alias trivially satisfies this
// (`recvSegs` has exactly one element), exactly as the code this generalizes
// did; a deeper call whose qualifier ISN'T itself wholly a known package
// (`Pkg.Sub.someVal.method()`, a real method call on a package-level value)
// returns `None`, and the `ECall` arm's caller falls back to the ordinary
// (unspecialized, depth-1-only) `EMember`-arm recursion — correctly leaving
// a genuine method call alone. `recvSpan` is the flattened receiver's own
// span, passed through to `rebuildQualifiedChain` as `pathSpan`; `outerSpan`
// is the callee `Expr`'s own span (the whole `Pkg.Sub.foo` chain, NOT
// including the call's parens).
func rewriteQualifiedMemberChain(
  aliases: in List[String],
  recvSegs: in List[String],
  trailingMember: in String,
  recvSpan: in Span,
  outerSpan: in Span,
): Option[Expr] {
  val candidate = joinSegs(recvSegs)
  if aliasContains(aliases, candidate) {
    val pkgSegs = aliasPkgSegs(aliases, candidate)
    return Some(value = rebuildQualifiedChain(pkgSegs, trailingMember, recvSpan, outerSpan))
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Expr rewriting.
// ─────────────────────────────────────────────────────────────────────────────
pub func rewriteExpr(aliases: in List[String], e: in Expr): Expr {
  // Each arm uses an early `return Expr(kind = ..., span = e.span)`
  // rather than the more idiomatic `val kind = match e.kind { ... }`
  // form because the bootstrap-stage emitter mis-infers the result
  // kind when a match-as-expression's arms return different union
  // variants — every arm gets an empty inferred type and downstream
  // typechecks of the produced value cascade into T0030/T0033/T0063
  // "got [empty]" diagnostics on otherwise trivially-typed code.
  // The split-out helpers below keep each arm's reconstruction
  // pinned to the single ExprKind variant it actually produces.
  match e.kind {
    case EPath(path) -> return Expr(kind = EPath(path = rewritePath(aliases, path)), span = e.span)
    case EMember(receiver, memberName) -> {
      // `Alias.foo`: when the receiver is a single-segment `EPath` whose head
      // is a known alias, surface the member as a fully-qualified path
      // (`<package>.foo`) so the post-rewrite typechecker resolves it against
      // the declaring package's symbols — preserving the package keeps two
      // same-name imports distinguishable (#1488 regex_safe).
      //
      // Deliberately depth-1-only, even though a multi-segment bare import's
      // FULL form (`Pkg.Sub.foo`, a depth-2+ `EMember` chain) needs the same
      // treatment (#6294) — that generalization lives in the `ECall` arm
      // below, applied ONLY to a call's own callee position, not here. This
      // arm also fires for a plain (non-called) qualified VALUE reference
      // (`Pkg.Sub.someVal`), and those already have their own scope-aware
      // resolution downstream (`tryQualifiedStaticValNameMsil` /
      // `tryQualifiedEnumOrdinalMsil` in MSIL codegen, walking the ORIGINAL
      // un-flattened `EMember` chain with a "root name shadowed by a local"
      // guard). This ARM's own logic is unchanged from before this PR and
      // carries no scope information at all — eagerly flattening a deeper
      // chain here would turn a local's OWN field-access chain that merely
      // happens to spell out an unrelated package's dotted name into a
      // bogus cross-package reference, bypassing the codegen guard that
      // exists precisely to catch that. Confirmed as a real regression
      // (`msil_project_bridge_self_test.l`'s "local shadowing a package
      // name" case: a local `val ShadowVal = ...` whose own `Lib.secret`
      // field chain collided with the unrelated bare-imported `ShadowVal.Lib`
      // package's `pub val secret`) when an earlier version of this fix
      // applied the deeper generalization here too. (Note: the `aliases`
      // list this arm CONSULTS is no longer scope-blind top to bottom — the
      // #6311/#6312 filtering upstream in `rewriteFunctionDecl` et al. and
      // `rewriteFile` already strips any alias a local/module-level `val`
      // would shadow before it ever reaches here, so a *shadowed* alias
      // simply won't be in `aliases` by the time this arm runs. That's a
      // sound, beneficial side effect for the depth-1 case this arm
      // already covered — it can only ever suppress a collapse, never
      // wrongly enable one — but this arm's OWN code makes no scope check;
      // it just consults whatever `aliases` it's handed, same as always.)
      match receiver.kind {
        case EPath(p) -> {
          if p.segments.count == 1 and aliasContains(aliases, p.segments[0]) {
            val segs: List[String] = newList()
            val pkg = aliasPkgSegs(aliases, p.segments[0])
            var k = 0
            while k < pkg.count {
              segs.add(pkg[k])
              k = k + 1
            }
            segs.add(memberName)
            return Expr(kind = EPath(path = ModulePath(segments = segs, span = p.span)), span = e.span)
          }
        }
        case _ -> ()
      }
      return Expr(kind = EMember(receiver = rewriteExpr(aliases, receiver), memberName = memberName), span = e.span)
    }
    case ELiteral(lit) -> return Expr(kind = ELiteral(lit = lit), span = e.span)
    case ESelf -> return Expr(kind = ESelf, span = e.span)
    case EResult -> return Expr(kind = EResult, span = e.span)
    case EInterpolated(segments) -> {
      val ss: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(text, span) -> ss.add(ISText(text = text, span = span))
          case ISExpr(expr) -> ss.add(ISExpr(expr = rewriteExpr(aliases, expr)))
        }
        i = i + 1
      }
      return Expr(kind = EInterpolated(segments = ss), span = e.span)
    }
    case EParen(inner) -> return Expr(kind = EParen(inner = rewriteExpr(aliases, inner)), span = e.span)
    case ETuple(exprs) -> {
      val xs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        xs.add(rewriteExpr(aliases, exprs[i]))
        i = i + 1
      }
      return Expr(kind = ETuple(exprs = xs), span = e.span)
    }
    case EList(exprs) -> {
      val xs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        xs.add(rewriteExpr(aliases, exprs[i]))
        i = i + 1
      }
      return Expr(kind = EList(exprs = xs), span = e.span)
    }
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      val el = match elseBranch {
        case Some(eob) -> Some(value = rewriteExprOrBlock(aliases, eob))
        case None -> elseBranch
      }
      return Expr(
        kind = EIf(
          cond = rewriteExpr(aliases, cond),
          thenBranch = rewriteExprOrBlock(aliases, thenBranch),
          elseBranch = el,
          thenForm = thenForm
        ),
        span = e.span
      )
    }
    case EMatch(scrutinee, arms) -> {
      val arms2: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        arms2.add(rewriteMatchArm(aliases, arms[i]))
        i = i + 1
      }
      return Expr(kind = EMatch(scrutinee = rewriteExpr(aliases, scrutinee), arms = arms2), span = e.span)
    }
    case EAwait(inner) -> return Expr(kind = EAwait(inner = rewriteExpr(aliases, inner)), span = e.span)
    case EYield(inner) -> return Expr(kind = EYield(inner = rewriteExpr(aliases, inner)), span = e.span)
    case ESpawn(inner) -> return Expr(kind = ESpawn(inner = rewriteExpr(aliases, inner)), span = e.span)
    case ETry(inner) -> return Expr(kind = ETry(inner = rewriteExpr(aliases, inner)), span = e.span)
    case EOld(inner) -> return Expr(kind = EOld(inner = rewriteExpr(aliases, inner)), span = e.span)
    case EForall(binders, whereExpr, body) -> {
      val w = match whereExpr { case Some(x) -> Some(value = rewriteExpr(aliases, x)); case None -> whereExpr }
      return Expr(kind = EForall(binders = binders, whereExpr = w, body = rewriteExpr(aliases, body)), span = e.span)
    }
    case EExists(binders, whereExpr, body) -> {
      val w = match whereExpr { case Some(x) -> Some(value = rewriteExpr(aliases, x)); case None -> whereExpr }
      return Expr(kind = EExists(binders = binders, whereExpr = w, body = rewriteExpr(aliases, body)), span = e.span)
    }
    case ELambda(lambdaParams, body) -> return Expr(kind = ELambda(lambdaParams = lambdaParams, body = rewriteBlock(aliases, body)), span = e.span)
    case ECall(fn, args) -> {
      val args2: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        args2.add(rewriteCallArg(aliases, args[i]))
        i = i + 1
      }
      // A qualified CALL specifically (`Pkg.Sub.foo(...)`, a package name of
      // ANY segment count referenced by its full dotted form — #6294) needs
      // its whole callee chain collapsed to a flat `EPath` here: codegen's
      // call lowering (`lowerCallMsil` / its JVM analogue) only dispatches a
      // user-defined package function through the `EPath` branch — an
      // `EMember` callee falls into generic method-call lowering, which
      // treats the receiver as a real value and fails (the #2929/#2930
      // symptom this whole mechanism exists to prevent, at whatever segment
      // depth the package name has). Scoped to the callee specifically (not
      // generalized into the `EMember` arm above) so a plain qualified VALUE
      // reference elsewhere keeps its existing, scope-aware resolution
      // untouched (see that arm's comment for the regression this avoids).
      val fn2 = match fn.kind {
        case EMember(receiver, memberName) -> match flattenPathExpr(receiver) { case Some(recvSegs) -> match rewriteQualifiedMemberChain(aliases, recvSegs, memberName, receiver.span, fn.span) { case Some(rewritten) -> rewritten; case None -> rewriteExpr(aliases, fn) }; case None -> rewriteExpr(aliases, fn) }
        case _ -> rewriteExpr(aliases, fn)
      }
      return Expr(kind = ECall(fn = fn2, args = args2), span = e.span)
    }
    case ETypeApp(fn, args) -> {
      val args2: List[TypeArg] = newList()
      var i = 0
      while i < args.count {
        args2.add(rewriteTypeArg(aliases, args[i]))
        i = i + 1
      }
      return Expr(kind = ETypeApp(fn = rewriteExpr(aliases, fn), args = args2), span = e.span)
    }
    case EIndex(receiver, indices) -> {
      val idxs: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        idxs.add(rewriteExpr(aliases, indices[i]))
        i = i + 1
      }
      return Expr(kind = EIndex(receiver = rewriteExpr(aliases, receiver), indices = idxs), span = e.span)
    }
    case EPropagate(inner) -> return Expr(kind = EPropagate(inner = rewriteExpr(aliases, inner)), span = e.span)
    case EPrefix(op, operand) -> return Expr(kind = EPrefix(op = op, operand = rewriteExpr(aliases, operand)), span = e.span)
    case EBinop(op, lhs, rhs) -> return Expr(kind = EBinop(op = op, lhs = rewriteExpr(aliases, lhs), rhs = rewriteExpr(aliases, rhs)), span = e.span)
    case ERange(bound) -> return Expr(kind = ERange(bound = rewriteRangeBound(aliases, bound)), span = e.span)
    case EAssign(target, op, value) -> return Expr(
      kind = EAssign(target = rewriteExpr(aliases, target), op = op, value = rewriteExpr(aliases, value)),
      span = e.span
    )
    case EBlock(block) -> return Expr(kind = EBlock(block = rewriteBlock(aliases, block)), span = e.span)
    case EUnsafe(block) -> return Expr(kind = EUnsafe(block = rewriteBlock(aliases, block)), span = e.span)
    case EError -> return e
  }
  // Unreachable — every ExprKind variant returns above.  The trailing
  // `return e` keeps the typechecker satisfied that the function has
  // a Expr-typed exit on every path.
  return e
}

func rewriteCallArg(aliases: in List[String], a: in CallArg): CallArg {
  match a {
    case CANamed(name, value, span) -> CANamed(name = name, value = rewriteExpr(aliases, value), span = span)
    case CAPositional(expr) -> CAPositional(expr = rewriteExpr(aliases, expr))
  }
}

func rewriteExprOrBlock(aliases: in List[String], eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBExpr(expr) -> EOBExpr(expr = rewriteExpr(aliases, expr))
    case EOBBlock(block) -> EOBBlock(block = rewriteBlock(aliases, block))
  }
}

func rewriteMatchArm(aliases: in List[String], arm: in MatchArm): MatchArm {
  val g = match arm.guard { case Some(x) -> Some(value = rewriteExpr(aliases, x)); case None -> arm.guard }
  MatchArm(
    pattern = rewritePattern(aliases, arm.pattern),
    guard = g,
    body = rewriteExprOrBlock(aliases, arm.body),
    span = arm.span
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Pattern rewriting.
// ─────────────────────────────────────────────────────────────────────────────
func rewritePattern(aliases: in List[String], p: in Pattern): Pattern {
  val kind = match p.kind {
    case PConstructor(head, args) -> {
      val ps: List[Pattern] = newList()
      var i = 0
      while i < args.count {
        ps.add(rewritePattern(aliases, args[i]))
        i = i + 1
      }
      PConstructor(head = rewritePath(aliases, head), args = ps)
    }
    case PRecord(head, fields, ignoreRest) -> {
      val fs: List[RecordPatternField] = newList()
      var i = 0
      while i < fields.count {
        fs.add(
          match fields[i] {
            case RPFNamed(name, pattern, span) -> RPFNamed(name = name, pattern = rewritePattern(aliases, pattern), span = span)
            case RPFShort(name, span) -> RPFShort(name = name, span = span)
          }
        )
        i = i + 1
      }
      PRecord(head = rewritePath(aliases, head), fields = fs, ignoreRest = ignoreRest)
    }
    case PTuple(patterns) -> {
      val ps: List[Pattern] = newList()
      var i = 0
      while i < patterns.count {
        ps.add(rewritePattern(aliases, patterns[i]))
        i = i + 1
      }
      PTuple(patterns = ps)
    }
    case PParen(inner) -> PParen(inner = rewritePattern(aliases, inner))
    case PTypeTest(inner, ty) -> PTypeTest(inner = rewritePattern(aliases, inner), ty = rewriteTypeExpr(aliases, ty))
    case POr(patterns) -> {
      val ps: List[Pattern] = newList()
      var i = 0
      while i < patterns.count {
        ps.add(rewritePattern(aliases, patterns[i]))
        i = i + 1
      }
      POr(patterns = ps)
    }
    case PBinding(name, inner) -> {
      val inner2 = match inner { case Some(p2) -> Some(value = rewritePattern(aliases, p2)); case None -> inner }
      PBinding(name = name, inner = inner2)
    }
    case PRange(lo, inclusive, hi) -> PRange(lo = rewriteExpr(aliases, lo), inclusive = inclusive, hi = rewriteExpr(aliases, hi))
    case PWildcard -> PWildcard
    case PLiteral(lit) -> PLiteral(lit = lit)
    case PConstRef(name) -> PConstRef(name = name)
    case PError -> PError
  }
  Pattern(kind = kind, span = p.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Block / Statement rewriting.
// ─────────────────────────────────────────────────────────────────────────────
func rewriteBlock(aliases: in List[String], b: in Block): Block {
  val ss: List[Statement] = newList()
  var i = 0
  while i < b.statements.count {
    ss.add(rewriteStatement(aliases, b.statements[i]))
    i = i + 1
  }
  Block(statements = ss, span = b.span)
}

func rewriteStatement(aliases: in List[String], s: in Statement): Statement {
  // Each arm uses an early `return` rather than the more idiomatic
  // `val kind = match s.kind { ... }` form because the bootstrap-stage
  // emitter mis-infers the result kind when a match-as-expression's
  // arms return different union variants — every arm gets an empty
  // inferred type and downstream typechecks of the produced value
  // cascade into T0030/T0033/T0063 "got [empty]" diagnostics.
  match s.kind {
    case SLocal(binding) -> return Statement(kind = SLocal(binding = rewriteLocalBinding(aliases, binding)), span = s.span)
    case SAssign(target, op, value) -> return Statement(
      kind = SAssign(target = rewriteExpr(aliases, target), op = op, value = rewriteExpr(aliases, value)),
      span = s.span
    )
    case SReturn(value) -> {
      val v = match value { case Some(e) -> Some(value = rewriteExpr(aliases, e)); case None -> value }
      return Statement(kind = SReturn(value = v), span = s.span)
    }
    case SBreak(label) -> return Statement(kind = SBreak(label = label), span = s.span)
    case SContinue(label) -> return Statement(kind = SContinue(label = label), span = s.span)
    case SThrow(expr) -> return Statement(kind = SThrow(expr = rewriteExpr(aliases, expr)), span = s.span)
    case STry(body, catches, finally_) -> {
      val cs: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        cs.add(rewriteCatch(aliases, catches[i]))
        i = i + 1
      }
      val fn = match finally_ { case Some(blk) -> Some(value = rewriteBlock(aliases, blk)); case None -> finally_ }
      return Statement(kind = STry(body = rewriteBlock(aliases, body), catches = cs, finally_ = fn), span = s.span)
    }
    case SDefer(body) -> return Statement(kind = SDefer(body = rewriteBlock(aliases, body)), span = s.span)
    case SScope(binding, body) -> return Statement(kind = SScope(binding = binding, body = rewriteBlock(aliases, body)), span = s.span)
    case SFor(label, pat, iter, body) -> return Statement(
      kind = SFor(
        label = label,
        pat = rewritePattern(aliases, pat),
        iter = rewriteExpr(aliases, iter),
        body = rewriteBlock(aliases, body)
      ),
      span = s.span
    )
    case SWhile(label, cond, body) -> return Statement(
      kind = SWhile(label = label, cond = rewriteExpr(aliases, cond), body = rewriteBlock(aliases, body)),
      span = s.span
    )
    case SLoop(label, body) -> return Statement(kind = SLoop(label = label, body = rewriteBlock(aliases, body)), span = s.span)
    case SInvariant(expr) -> return Statement(kind = SInvariant(expr = rewriteExpr(aliases, expr)), span = s.span)
    case SExpr(expr) -> return Statement(kind = SExpr(expr = rewriteExpr(aliases, expr)), span = s.span)
    case SRule(lhs, rhs) -> return Statement(kind = SRule(lhs = rewriteExpr(aliases, lhs), rhs = rewriteExpr(aliases, rhs)), span = s.span)
    case SItem(item) -> return Statement(kind = SItem(item = item), span = s.span)
  }
  return s
}

func rewriteCatch(aliases: in List[String], c: in CatchClause): CatchClause {
  CatchClause(typeName = c.typeName, bindName = c.bindName, body = rewriteBlock(aliases, c.body), span = c.span)
}

func rewriteLocalBinding(aliases: in List[String], lb: in LocalBinding): LocalBinding {
  // Each arm uses an early `return` rather than match-expression
  // form because the self-hosted typechecker mis-infers the union
  // result type when arms return different variants of the same
  // union from inside a match-as-expression (#1170 ecosystem suite
  // surfaced this as an empty-type T0030/T0033/T0063 cascade on
  // basic `var i = pos; while i < n { i = i + 1 }` shapes the moment
  // the file carried any `import X as Y` declaration).  Splitting
  // each case into an early-returning statement keeps the inferred
  // result type pinned to the variant the case actually built.
  match lb {
    case LBVal(pat, ty, init) -> {
      val t = match ty { case Some(te) -> Some(value = rewriteTypeExpr(aliases, te)); case None -> ty }
      return LBVal(pat = rewritePattern(aliases, pat), ty = t, init = rewriteExpr(aliases, init))
    }
    case LBVar(name, ty, init) -> {
      val t = match ty { case Some(te) -> Some(value = rewriteTypeExpr(aliases, te)); case None -> ty }
      val v = match init { case Some(e) -> Some(value = rewriteExpr(aliases, e)); case None -> init }
      return LBVar(name = name, ty = t, init = v)
    }
    case LBLet(name, ty, init) -> {
      val t = match ty { case Some(te) -> Some(value = rewriteTypeExpr(aliases, te)); case None -> ty }
      return LBLet(name = name, ty = t, init = rewriteExpr(aliases, init))
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6b. Scope-awareness for the ECall qualified-chain collapse (#6311).
// ─────────────────────────────────────────────────────────────────────────────
// `rewriteQualifiedMemberChain` (invoked from the `ECall` arm above) treats
// ANY multi-segment dotted call-callee chain that spells out a known
// package's full path as that package — but a local variable's own
// field-access call chain can spell out the exact same dotted name by
// coincidence (`val Foo = ...; Foo.Bar.handle()` when `import Foo.Bar` is
// ALSO in scope). Pre-existing (depth-1) codegen already carries a
// scope-aware "shadowed by a local" guard for this very case
// (`tryQualifiedStaticValNameMsil` et al. in MSIL codegen), but that guard
// only ever sees a genuine, un-flattened `EMember` chain reaching codegen —
// once this rewriter collapses a chain into a flat `EPath`, the guard never
// runs. Confirmed as a genuine regression at chain-depth 2+ introduced by
// the `ECall` generalization (#6311): a depth-1 collision already silently
// favored the package before #6294 (an accepted, pre-existing gap — see
// this file's header), but a depth-2+ collision was safe until the `ECall`
// generalization started flattening those chains too.
//
// Fix: before rewriting a function-shaped scope's body, collect every name
// bound ANYWHERE within it (params/binders, every `val`/`var`/`let`, every
// pattern binding — including match arms, for-loop patterns, and record
// shorthand fields — lambda params, catch binds, `scope` binds) and strip
// any alias entry whose key's FIRST dot-segment collides with one of those
// names from the `aliases` list threaded into the body. This is coarser
// than real per-block scoping (a name bound in one `if` branch also
// suppresses the collapse in a sibling branch that never sees it), but
// that's a conservative, SOUND direction: it can only ever suppress a
// legitimate collapse (falling back to the pre-existing, safe recursive
// per-`EMember`-arm behavior), never wrongly enable an incorrect one.
func collectPatternLocalNames(p: in Pattern, acc: List[String]): Unit {
  match p.kind {
    case PBinding(name, inner) -> {
      acc.add(name)
      match inner {
        case Some(p2) -> collectPatternLocalNames(p2, acc)
        case None -> ()
      }
    }
    case PConstructor(_, args) -> {
      var i = 0
      while i < args.count {
        collectPatternLocalNames(args[i], acc)
        i = i + 1
      }
    }
    case PRecord(_, fields, _) -> {
      var i = 0
      while i < fields.count {
        match fields[i] {
          case RPFNamed(_, pattern, _) -> collectPatternLocalNames(pattern, acc)
          case RPFShort(name, _) -> acc.add(name)
        }
        i = i + 1
      }
    }
    case PTuple(patterns) -> {
      var i = 0
      while i < patterns.count {
        collectPatternLocalNames(patterns[i], acc)
        i = i + 1
      }
    }
    case PParen(inner) -> collectPatternLocalNames(inner, acc)
    case PTypeTest(inner, _) -> collectPatternLocalNames(inner, acc)
    case POr(patterns) -> {
      var i = 0
      while i < patterns.count {
        collectPatternLocalNames(patterns[i], acc)
        i = i + 1
      }
    }
    case PRange(_, _, _) -> ()
    case PWildcard -> ()
    case PLiteral(_) -> ()
    case PConstRef(_) -> ()
    case PError -> ()
  }
}

func collectExprListLocalNames(xs: in List[Expr], acc: List[String]): Unit {
  var i = 0
  while i < xs.count {
    collectExprLocalNames(xs[i], acc)
    i = i + 1
  }
}

func collectExprOrBlockLocalNames(eob: in ExprOrBlock, acc: List[String]): Unit {
  match eob {
    case EOBExpr(expr) -> collectExprLocalNames(expr, acc)
    case EOBBlock(block) -> collectBlockLocalNames(block, acc)
  }
}

func collectExprLocalNames(e: in Expr, acc: List[String]): Unit {
  match e.kind {
    case EParen(inner) -> collectExprLocalNames(inner, acc)
    case ETuple(exprs) -> collectExprListLocalNames(exprs, acc)
    case EList(exprs) -> collectExprListLocalNames(exprs, acc)
    case EIf(cond, thenBranch, elseBranch, _) -> {
      collectExprLocalNames(cond, acc)
      collectExprOrBlockLocalNames(thenBranch, acc)
      match elseBranch {
        case Some(eob) -> collectExprOrBlockLocalNames(eob, acc)
        case None -> ()
      }
    }
    case EMatch(scrutinee, arms) -> {
      collectExprLocalNames(scrutinee, acc)
      var i = 0
      while i < arms.count {
        collectPatternLocalNames(arms[i].pattern, acc)
        match arms[i].guard {
          case Some(g) -> collectExprLocalNames(g, acc)
          case None -> ()
        }
        collectExprOrBlockLocalNames(arms[i].body, acc)
        i = i + 1
      }
    }
    case EAwait(inner) -> collectExprLocalNames(inner, acc)
    case EYield(inner) -> collectExprLocalNames(inner, acc)
    case ESpawn(inner) -> collectExprLocalNames(inner, acc)
    case ETry(inner) -> collectExprLocalNames(inner, acc)
    case EOld(inner) -> collectExprLocalNames(inner, acc)
    case EForall(binders, whereExpr, body) -> {
      var i = 0
      while i < binders.count {
        acc.add(binders[i].name)
        i = i + 1
      }
      match whereExpr {
        case Some(w) -> collectExprLocalNames(w, acc)
        case None -> ()
      }
      collectExprLocalNames(body, acc)
    }
    case EExists(binders, whereExpr, body) -> {
      var i = 0
      while i < binders.count {
        acc.add(binders[i].name)
        i = i + 1
      }
      match whereExpr {
        case Some(w) -> collectExprLocalNames(w, acc)
        case None -> ()
      }
      collectExprLocalNames(body, acc)
    }
    case ELambda(lambdaParams, body) -> {
      var i = 0
      while i < lambdaParams.count {
        acc.add(lambdaParams[i].name)
        i = i + 1
      }
      collectBlockLocalNames(body, acc)
    }
    case ECall(fn, args) -> {
      collectExprLocalNames(fn, acc)
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(_, value, _) -> collectExprLocalNames(value, acc)
          case CAPositional(value) -> collectExprLocalNames(value, acc)
        }
        i = i + 1
      }
    }
    case ETypeApp(fn, _) -> collectExprLocalNames(fn, acc)
    case EIndex(receiver, indices) -> {
      collectExprLocalNames(receiver, acc)
      collectExprListLocalNames(indices, acc)
    }
    case EMember(receiver, _) -> collectExprLocalNames(receiver, acc)
    case EPropagate(inner) -> collectExprLocalNames(inner, acc)
    case EPrefix(_, operand) -> collectExprLocalNames(operand, acc)
    case EBinop(_, lhs, rhs) -> {
      collectExprLocalNames(lhs, acc)
      collectExprLocalNames(rhs, acc)
    }
    case EAssign(target, _, value) -> {
      collectExprLocalNames(target, acc)
      collectExprLocalNames(value, acc)
    }
    case EBlock(block) -> collectBlockLocalNames(block, acc)
    case EUnsafe(block) -> collectBlockLocalNames(block, acc)
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISExpr(expr) -> collectExprLocalNames(expr, acc)
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
    }
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> {
          collectExprLocalNames(lo, acc)
          collectExprLocalNames(hi, acc)
        }
        case RBHalfOpen(lo, hi) -> {
          collectExprLocalNames(lo, acc)
          collectExprLocalNames(hi, acc)
        }
        case RBLowerOpen(hi) -> collectExprLocalNames(hi, acc)
        case RBUpperOpen(lo) -> collectExprLocalNames(lo, acc)
      }
    }
    case EPath(_) -> ()
    case ELiteral(_) -> ()
    case ESelf -> ()
    case EResult -> ()
    case EError -> ()
  }
}

func collectLocalBindingNames(lb: in LocalBinding, acc: List[String]): Unit {
  match lb {
    case LBVal(pat, _, init) -> {
      collectPatternLocalNames(pat, acc)
      collectExprLocalNames(init, acc)
    }
    case LBVar(name, _, init) -> {
      acc.add(name)
      match init {
        case Some(e) -> collectExprLocalNames(e, acc)
        case None -> ()
      }
    }
    case LBLet(name, _, init) -> {
      acc.add(name)
      collectExprLocalNames(init, acc)
    }
  }
}

func collectStatementLocalNames(s: in Statement, acc: List[String]): Unit {
  match s.kind {
    case SLocal(binding) -> collectLocalBindingNames(binding, acc)
    case SAssign(target, _, value) -> {
      collectExprLocalNames(target, acc)
      collectExprLocalNames(value, acc)
    }
    case SReturn(value) -> {
      match value {
        case Some(e) -> collectExprLocalNames(e, acc)
        case None -> ()
      }
    }
    case SBreak(_) -> ()
    case SContinue(_) -> ()
    case SThrow(expr) -> collectExprLocalNames(expr, acc)
    case STry(body, catches, finally_) -> {
      collectBlockLocalNames(body, acc)
      var i = 0
      while i < catches.count {
        match catches[i].bindName {
          case Some(n) -> acc.add(n)
          case None -> ()
        }
        collectBlockLocalNames(catches[i].body, acc)
        i = i + 1
      }
      match finally_ {
        case Some(blk) -> collectBlockLocalNames(blk, acc)
        case None -> ()
      }
    }
    case SDefer(body) -> collectBlockLocalNames(body, acc)
    case SScope(binding, body) -> {
      match binding {
        case Some(n) -> acc.add(n)
        case None -> ()
      }
      collectBlockLocalNames(body, acc)
    }
    case SFor(_, pat, iter, body) -> {
      collectPatternLocalNames(pat, acc)
      collectExprLocalNames(iter, acc)
      collectBlockLocalNames(body, acc)
    }
    case SWhile(_, cond, body) -> {
      collectExprLocalNames(cond, acc)
      collectBlockLocalNames(body, acc)
    }
    case SLoop(_, body) -> collectBlockLocalNames(body, acc)
    case SInvariant(expr) -> collectExprLocalNames(expr, acc)
    case SExpr(expr) -> collectExprLocalNames(expr, acc)
    case SRule(lhs, rhs) -> {
      collectExprLocalNames(lhs, acc)
      collectExprLocalNames(rhs, acc)
    }
    // A block-nested item declaration's own bound name is skipped here — but
    // that's harmless today, not an oversight: `typechecker_stmts.l`'s own
    // `SItem` handling in a block is itself a no-op, so a nested item can't
    // bind a live name anywhere yet. If/when block-nested items become real,
    // this collector needs the matching update.
    case SItem(_) -> ()
  }
}

func collectBlockLocalNames(b: in Block, acc: List[String]): Unit {
  var i = 0
  while i < b.statements.count {
    collectStatementLocalNames(b.statements[i], acc)
    i = i + 1
  }
}

func collectParamNames(params: in List[Param], acc: List[String]): Unit {
  var i = 0
  while i < params.count {
    acc.add(params[i].name)
    i = i + 1
  }
}

func collectFunctionBodyLocalNames(body: in FunctionBody, acc: List[String]): Unit {
  match body {
    case FBExpr(expr) -> collectExprLocalNames(expr, acc)
    case FBBlock(block) -> collectBlockLocalNames(block, acc)
  }
}

func aliasKeyFirstSegment(entry: in String): String {
  val kv = Str.split(entry, "=")
  val segs = Str.split(kv[0], ".")
  segs[0]
}

// Remove every alias entry whose key's first dot-segment collides with a
// name in `locals` — see the section header above for why this is sound.
func filterAliasesExcludingLocals(aliases: in List[String], locals: in List[String]): List[String] {
  if locals.count == 0 {
    return aliases
  }
  val kept: List[String] = newList()
  var i = 0
  while i < aliases.count {
    val head = aliasKeyFirstSegment(aliases[i])
    var shadowed = false
    var j = 0
    while j < locals.count {
      if locals[j] == head {
        shadowed = true
      }
      j = j + 1
    }
    if not shadowed {
      kept.add(aliases[i])
    }
    i = i + 1
  }
  kept
}

// #6316: a standalone expression position (a config field's `default`, a
// wire-include adjustment's `value`) can itself be an arbitrary block or
// lambda expression that introduces its own local bindings — the same
// self-referential collect-then-filter pattern `rewriteFixtureDecl` already
// uses for its `init` (collect every name bound ANYWHERE inside `e` from
// the ORIGINAL pre-rewrite tree, then rewrite `e` with those names excluded
// from `aliases`). Reused here so every free-standing expression position
// gets the same #6311-class shadowing guard as a function body, not just
// the four function-shaped scopes #6311/#6312/#6313 already cover.
func filterAliasesForExpr(aliases: in List[String], e: in Expr): List[String] {
  val locals: List[String] = newList()
  collectExprLocalNames(e, locals)
  filterAliasesExcludingLocals(aliases, locals)
}

// Module-level `val`/`const` names are visible, unqualified, from EVERY
// function in the file — not just the one it's textually declared in — so
// they need the same shadowing guard as function-locals, but computed once
// for the whole file rather than per-function (#6312, the module-scope
// counterpart to #6311: a module-level `val Foo = ...` colliding with a
// bare-imported package's first dotted segment shadows `Foo.Bar.method()`
// calls in ANY function of the file, not just the one `Foo` happens to be
// declared next to).
//
// `IFunc` is deliberately NOT collected here (review follow-up, #6321): a
// top-level function's own NAME can't collide with this hazard the way a
// `val`/`const` name can — `Foo.Bar.baz()` only ever gets read back as a
// qualified-chain CALL, and a bare function name is never itself a valid
// receiver for `.field`/`.method` access the way a record-typed `val` is,
// so there is no `Foo.Bar.baz()` shape a same-named top-level `func Foo`
// could ever shadow.
func collectModuleLevelValueNames(file: in SourceFile, acc: List[String]): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IConst(decl) -> acc.add(decl.name)
      case IVal(decl) -> collectPatternLocalNames(decl.pattern, acc)
      // #6323 SUGGESTION follow-up: `Lyric.TestSynth` already rewrites
      // `fixture X` to `val X` before the alias rewriter runs today, so this
      // arm is currently unreachable — but the collector shouldn't silently
      // rely on that ordering forever, so an `IFixture` is treated exactly
      // like the `IVal` it's synthesized from.
      case IFixture(decl) -> acc.add(decl.name)
      case _ -> ()
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Item-level rewriting.
// ─────────────────────────────────────────────────────────────────────────────
func rewriteParam(aliases: in List[String], p: in Param): Param {
  // #6320 — see filterAliasesForExpr's comment: a param default can itself
  // be a lambda (a bare `{ ... }`) introducing its own shadowing locals.
  val d = match p.dflt {
    case Some(e) -> Some(value = rewriteExpr(filterAliasesForExpr(aliases, e), e))
    case None -> p.dflt
  }
  Param(
    mode = p.mode,
    modeExplicit = p.modeExplicit,
    name = p.name,
    ty = rewriteTypeExpr(aliases, p.ty),
    dflt = d,
    annotations = p.annotations,
    span = p.span
  )
}

func rewriteFunctionBody(aliases: in List[String], b: in FunctionBody): FunctionBody {
  // Early returns for the same bootstrap-emitter match-as-expression
  // bug documented on rewriteExpr — the result inferred from a
  // single match expression whose arms return different union
  // variants ends up empty-typed.
  match b {
    case FBExpr(expr) -> return FBExpr(expr = rewriteExpr(aliases, expr))
    case FBBlock(block) -> return FBBlock(block = rewriteBlock(aliases, block))
  }
  return b
}

func rewriteFunctionDecl(aliases: in List[String], fn: in FunctionDecl): FunctionDecl {
  val ps: List[Param] = newList()
  var i = 0
  while i < fn.params.count {
    ps.add(rewriteParam(aliases, fn.params[i]))
    i = i + 1
  }
  val ret = match fn.ret { case Some(te) -> Some(value = rewriteTypeExpr(aliases, te)); case None -> fn.ret }
  // Scope-aware body rewrite (#6311): strip any alias a local declared
  // anywhere in this function would shadow before recursing into the body.
  val locals: List[String] = newList()
  collectParamNames(fn.params, locals)
  match fn.body {
    case Some(b) -> collectFunctionBodyLocalNames(b, locals)
    case None -> ()
  }
  val bodyAliases = filterAliasesExcludingLocals(aliases, locals)
  val body = match fn.body { case Some(b) -> Some(value = rewriteFunctionBody(bodyAliases, b)); case None -> fn.body }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = ps,
    ret = ret,
    whereClause = rewriteWhereClauseOpt(aliases, fn.whereClause),
    // #6313: contract clauses reference the function's own params directly
    // (`requires:`/`ensures:`/`when:`/`decreases:`), so they need the same
    // scope-aware filtering as the body — reuse `bodyAliases`, not the raw
    // `aliases`.
    contracts = rewriteContracts(bodyAliases, fn.contracts),
    body = body,
    span = fn.span
  )
}

// Param types and the return type of an `extern func` are ordinary
// TypeExprs (e.g. an aliased `NativePtr[Byte]` spelling) — rewrite them;
// the C symbol string carries no Lyric names.
func rewriteExternFuncDecl(aliases: in List[String], ef: in ExternFuncDecl): ExternFuncDecl {
  val ps: List[Param] = newList()
  var i = 0
  while i < ef.params.count {
    ps.add(rewriteParam(aliases, ef.params[i]))
    i = i + 1
  }
  val ret = match ef.ret { case Some(te) -> Some(value = rewriteTypeExpr(aliases, te)); case None -> ef.ret }
  ExternFuncDecl(name = ef.name, params = ps, ret = ret, symbol = ef.symbol, span = ef.span)
}

func rewriteFieldDecl(aliases: in List[String], f: in FieldDecl): FieldDecl {
  // #6320 — see filterAliasesForExpr's comment: a field default can itself
  // be a lambda (a bare `{ ... }`) introducing its own shadowing locals.
  val d = match f.dflt {
    case Some(e) -> Some(value = rewriteExpr(filterAliasesForExpr(aliases, e), e))
    case None -> f.dflt
  }
  FieldDecl(
    docComments = f.docComments,
    annotations = f.annotations,
    visibility = f.visibility,
    isMutable = f.isMutable,
    name = f.name,
    ty = rewriteTypeExpr(aliases, f.ty),
    dflt = d,
    span = f.span
  )
}

func rewriteRecordDecl(aliases: in List[String], rd: in RecordDecl): RecordDecl {
  val ms: List[RecordMember] = newList()
  var i = 0
  while i < rd.members.count {
    ms.add(
      match rd.members[i] {
        case RMField(field) -> RMField(field = rewriteFieldDecl(aliases, field))
        // #6321 SUGGESTION follow-up — see filterAliasesForExpr's comment:
        // an invariant clause's own expr can itself be a lambda introducing
        // its own shadowing locals, same as every other standalone position.
        case RMInvariant(inv) -> RMInvariant(inv = InvariantClause(expr = rewriteExpr(filterAliasesForExpr(aliases, inv.expr), inv.expr), span = inv.span))
        case RMFunc(fn) -> RMFunc(fn = rewriteFunctionDecl(aliases, fn))
      }
    )
    i = i + 1
  }
  RecordDecl(
    name = rd.name,
    generics = rd.generics,
    whereClause = rewriteWhereClauseOpt(aliases, rd.whereClause),
    members = ms,
    span = rd.span
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §7b. Descent into the remaining item kinds (#1834).
//
// `rewriteItem` historically rewrote only IFunc / IRecord / IExposedRec /
// IConst / IVal, leaving every other item kind pass-through.  That meant an
// alias-qualified reference inside an `impl` method body, an interface method
// signature, a union case payload, a wire/config/aspect body, etc. survived
// the rewrite and tripped T0020 ("unknown name") at type-check.  The helpers
// below close that gap for every `ItemKind` variant that carries a
// `TypeExpr`, `Expr`, `Block`, or `ConstraintRef`.
// ─────────────────────────────────────────────────────────────────────────────
func rewriteOptType(aliases: in List[String], ot: in Option[TypeExpr]): Option[TypeExpr] {
  match ot {
    case Some(te) -> return Some(value = rewriteTypeExpr(aliases, te))
    case None -> return ot
  }
  return ot
}

func rewriteOptExpr(aliases: in List[String], oe: in Option[Expr]): Option[Expr] {
  match oe {
    case Some(e) -> return Some(value = rewriteExpr(aliases, e))
    case None -> return oe
  }
  return oe
}

func rewriteConstraintRef(aliases: in List[String], cr: in ConstraintRef): ConstraintRef {
  val as2: List[TypeArg] = newList()
  var i = 0
  while i < cr.args.count {
    as2.add(rewriteTypeArg(aliases, cr.args[i]))
    i = i + 1
  }
  ConstraintRef(head = rewritePath(aliases, cr.head), args = as2, span = cr.span)
}

// `where T: Alias.Trait` bounds reference aliased traits via ConstraintRef
// (#1860).  Rewrite each bound's constraint list; the bound's own type-param
// name is a binder, not an alias reference, so it is left untouched.
//
// Unlike every other position, an aliased `where` bound collapses to the
// trait's *bare* name rather than the fully-qualified path: the type checker
// resolves `where` constraints by bare interface name and rejects qualified
// constraint paths outright (T0051), so a qualified rewrite would turn a
// resolvable aliased bound into a hard error (#1874).
func rewriteWhereConstraintRef(aliases: in List[String], cr: in ConstraintRef): ConstraintRef {
  val as2: List[TypeArg] = newList()
  var i = 0
  while i < cr.args.count {
    as2.add(rewriteTypeArg(aliases, cr.args[i]))
    i = i + 1
  }
  if cr.head.segments.count >= 2 and aliasContains(aliases, cr.head.segments[0]) {
    val segs: List[String] = newList()
    segs.add(cr.head.segments[cr.head.segments.count - 1])
    return ConstraintRef(head = ModulePath(segments = segs, span = cr.head.span), args = as2, span = cr.span)
  }
  ConstraintRef(head = rewritePath(aliases, cr.head), args = as2, span = cr.span)
}

func rewriteWhereBound(aliases: in List[String], b: in WhereBound): WhereBound {
  val cs: List[ConstraintRef] = newList()
  var i = 0
  while i < b.constraints.count {
    cs.add(rewriteWhereConstraintRef(aliases, b.constraints[i]))
    i = i + 1
  }
  WhereBound(name = b.name, constraints = cs, span = b.span)
}

func rewriteWhereClauseOpt(aliases: in List[String], wc: in Option[WhereClause]): Option[WhereClause] {
  match wc {
    case Some(w) -> {
      val bs: List[WhereBound] = newList()
      var i = 0
      while i < w.bounds.count {
        bs.add(rewriteWhereBound(aliases, w.bounds[i]))
        i = i + 1
      }
      return Some(value = WhereClause(bounds = bs, span = w.span))
    }
    case None -> return wc
  }
  return wc
}

// `requires:` / `ensures:` / `when:` / `decreases:` carry an `Expr`, and
// `raises:` carries a `List[TypeExpr]` — all of which can reference aliased
// names (#1861).
func rewriteContractClause(aliases: in List[String], c: in ContractClause): ContractClause {
  match c {
    case CCRequires(expr, span) -> return CCRequires(expr = rewriteExpr(aliases, expr), span = span)
    case CCEnsures(expr, span) -> return CCEnsures(expr = rewriteExpr(aliases, expr), span = span)
    case CCWhen(expr, span) -> return CCWhen(expr = rewriteExpr(aliases, expr), span = span)
    case CCDecreases(expr, span) -> return CCDecreases(expr = rewriteExpr(aliases, expr), span = span)
    case CCRaises(types, span) -> {
      val ts: List[TypeExpr] = newList()
      var i = 0
      while i < types.count {
        ts.add(rewriteTypeExpr(aliases, types[i]))
        i = i + 1
      }
      return CCRaises(types = ts, span = span)
    }
  }
  return c
}

func rewriteContracts(aliases: in List[String], cs: in List[ContractClause]): List[ContractClause] {
  val xs: List[ContractClause] = newList()
  var i = 0
  while i < cs.count {
    xs.add(rewriteContractClause(aliases, cs[i]))
    i = i + 1
  }
  xs
}

func rewriteFunctionSig(aliases: in List[String], sig: in FunctionSig): FunctionSig {
  val ps: List[Param] = newList()
  var i = 0
  while i < sig.params.count {
    ps.add(rewriteParam(aliases, sig.params[i]))
    i = i + 1
  }
  // #6313: a body-less interface signature has no body to filter, but its
  // own contract clauses (`requires:`/`ensures:`) still reference its
  // params directly — same scope-aware filtering as rewriteFunctionDecl's
  // `bodyAliases`, just param-only since there's no body to collect from.
  val locals: List[String] = newList()
  collectParamNames(sig.params, locals)
  val sigAliases = filterAliasesExcludingLocals(aliases, locals)
  FunctionSig(
    docComments = sig.docComments,
    isAsync = sig.isAsync,
    name = sig.name,
    generics = sig.generics,
    params = ps,
    ret = rewriteOptType(aliases, sig.ret),
    whereClause = rewriteWhereClauseOpt(aliases, sig.whereClause),
    contracts = rewriteContracts(sigAliases, sig.contracts),
    span = sig.span
  )
}

func rewriteAssociatedTypeDecl(aliases: in List[String], a: in AssociatedTypeDecl): AssociatedTypeDecl {
  AssociatedTypeDecl(name = a.name, dflt = rewriteOptType(aliases, a.dflt), span = a.span)
}

func rewriteEntryDecl(aliases: in List[String], ed: in EntryDecl): EntryDecl {
  val ps: List[Param] = newList()
  var i = 0
  while i < ed.params.count {
    ps.add(rewriteParam(aliases, ed.params[i]))
    i = i + 1
  }
  // Scope-aware body rewrite (#6311) — see rewriteFunctionDecl's comment.
  val locals: List[String] = newList()
  collectParamNames(ed.params, locals)
  collectFunctionBodyLocalNames(ed.body, locals)
  val bodyAliases = filterAliasesExcludingLocals(aliases, locals)
  EntryDecl(
    docComments = ed.docComments,
    annotations = ed.annotations,
    visibility = ed.visibility,
    name = ed.name,
    params = ps,
    ret = rewriteOptType(aliases, ed.ret),
    // #6313 — see rewriteFunctionDecl's comment.
    contracts = rewriteContracts(bodyAliases, ed.contracts),
    body = rewriteFunctionBody(bodyAliases, ed.body),
    span = ed.span
  )
}

// IImpl ───────────────────────────────────────────────────────────────────────
func rewriteImplMember(aliases: in List[String], m: in ImplMember): ImplMember {
  match m {
    case IMplFunc(fn) -> return IMplFunc(fn = rewriteFunctionDecl(aliases, fn))
    case IMplAssoc(assoc) -> return IMplAssoc(assoc = rewriteAssociatedTypeDecl(aliases, assoc))
  }
  return m
}

func rewriteImplDecl(aliases: in List[String], d: in ImplDecl): ImplDecl {
  val ms: List[ImplMember] = newList()
  var i = 0
  while i < d.members.count {
    ms.add(rewriteImplMember(aliases, d.members[i]))
    i = i + 1
  }
  ImplDecl(
    generics = d.generics,
    iface = rewriteConstraintRef(aliases, d.iface),
    target = rewriteTypeExpr(aliases, d.target),
    whereClause = rewriteWhereClauseOpt(aliases, d.whereClause),
    members = ms,
    span = d.span
  )
}

// IInterface ────────────────────────────────────────────────────────────────────
func rewriteInterfaceMember(aliases: in List[String], m: in InterfaceMember): InterfaceMember {
  match m {
    case IMSig(sig) -> return IMSig(sig = rewriteFunctionSig(aliases, sig))
    case IMFunc(fn) -> return IMFunc(fn = rewriteFunctionDecl(aliases, fn))
    case IMAssoc(assoc) -> return IMAssoc(assoc = rewriteAssociatedTypeDecl(aliases, assoc))
  }
  return m
}

func rewriteInterfaceDecl(aliases: in List[String], d: in InterfaceDecl): InterfaceDecl {
  val ms: List[InterfaceMember] = newList()
  var i = 0
  while i < d.members.count {
    ms.add(rewriteInterfaceMember(aliases, d.members[i]))
    i = i + 1
  }
  InterfaceDecl(
    name = d.name,
    generics = d.generics,
    whereClause = rewriteWhereClauseOpt(aliases, d.whereClause),
    members = ms,
    span = d.span
  )
}

// IUnion ────────────────────────────────────────────────────────────────────────
func rewriteUnionField(aliases: in List[String], f: in UnionField): UnionField {
  match f {
    case UFNamed(name, ty, span) -> return UFNamed(name = name, ty = rewriteTypeExpr(aliases, ty), span = span)
    case UFPos(ty, span) -> return UFPos(ty = rewriteTypeExpr(aliases, ty), span = span)
  }
  return f
}

func rewriteUnionCase(aliases: in List[String], c: in UnionCase): UnionCase {
  val fs: List[UnionField] = newList()
  var i = 0
  while i < c.fields.count {
    fs.add(rewriteUnionField(aliases, c.fields[i]))
    i = i + 1
  }
  UnionCase(docComments = c.docComments, annotations = c.annotations, name = c.name, fields = fs, span = c.span)
}

func rewriteUnionDecl(aliases: in List[String], d: in UnionDecl): UnionDecl {
  val cs: List[UnionCase] = newList()
  var i = 0
  while i < d.cases.count {
    cs.add(rewriteUnionCase(aliases, d.cases[i]))
    i = i + 1
  }
  UnionDecl(
    name = d.name,
    generics = d.generics,
    whereClause = rewriteWhereClauseOpt(aliases, d.whereClause),
    cases = cs,
    span = d.span
  )
}

// IOpaque ───────────────────────────────────────────────────────────────────────
func rewriteOpaqueMember(aliases: in List[String], m: in OpaqueMember): OpaqueMember {
  match m {
    case OMField(field) -> return OMField(field = rewriteFieldDecl(aliases, field))
    // #6321 SUGGESTION follow-up — see filterAliasesForExpr's comment.
    case OMInvariant(inv) -> return OMInvariant(
      inv = InvariantClause(expr = rewriteExpr(filterAliasesForExpr(aliases, inv.expr), inv.expr), span = inv.span)
    )
  }
  return m
}

func rewriteOpaqueTypeDecl(aliases: in List[String], d: in OpaqueTypeDecl): OpaqueTypeDecl {
  val ms: List[OpaqueMember] = newList()
  var i = 0
  while i < d.members.count {
    ms.add(rewriteOpaqueMember(aliases, d.members[i]))
    i = i + 1
  }
  OpaqueTypeDecl(
    name = d.name,
    generics = d.generics,
    whereClause = rewriteWhereClauseOpt(aliases, d.whereClause),
    annotations = d.annotations,
    members = ms,
    hasBody = d.hasBody,
    span = d.span
  )
}

// IProtected ────────────────────────────────────────────────────────────────────
// #6323 — see filterAliasesForExpr's comment: a protected var/let field's
// own init can itself be a lambda (a bare `{ ... }`) introducing its own
// shadowing locals, same as every other standalone-expression position.
func rewriteOptExprSelfFiltered(aliases: in List[String], oe: in Option[Expr]): Option[Expr] {
  match oe {
    case Some(e) -> Some(value = rewriteExpr(filterAliasesForExpr(aliases, e), e))
    case None -> oe
  }
}

func rewriteProtectedField(aliases: in List[String], pf: in ProtectedField): ProtectedField {
  match pf {
    case PFVar(name, ty, init, docComments, annotations, span) -> return PFVar(
      name = name,
      ty = rewriteTypeExpr(aliases, ty),
      init = rewriteOptExprSelfFiltered(aliases, init),
      docComments = docComments,
      annotations = annotations,
      span = span
    )
    case PFLet(name, ty, init, docComments, annotations, span) -> return PFLet(
      name = name,
      ty = rewriteTypeExpr(aliases, ty),
      init = rewriteOptExprSelfFiltered(aliases, init),
      docComments = docComments,
      annotations = annotations,
      span = span
    )
    case PFImmutable(field) -> return PFImmutable(field = rewriteFieldDecl(aliases, field))
  }
  return pf
}

func rewriteProtectedMember(aliases: in List[String], m: in ProtectedMember): ProtectedMember {
  match m {
    case PMField(field) -> return PMField(field = rewriteProtectedField(aliases, field))
    // #6321 SUGGESTION follow-up — see filterAliasesForExpr's comment.
    case PMInvariant(inv) -> return PMInvariant(
      inv = InvariantClause(expr = rewriteExpr(filterAliasesForExpr(aliases, inv.expr), inv.expr), span = inv.span)
    )
    case PMEntry(entryDecl) -> return PMEntry(entryDecl = rewriteEntryDecl(aliases, entryDecl))
    case PMFunc(fn) -> return PMFunc(fn = rewriteFunctionDecl(aliases, fn))
  }
  return m
}

func rewriteProtectedTypeDecl(aliases: in List[String], d: in ProtectedTypeDecl): ProtectedTypeDecl {
  val ms: List[ProtectedMember] = newList()
  var i = 0
  while i < d.members.count {
    ms.add(rewriteProtectedMember(aliases, d.members[i]))
    i = i + 1
  }
  ProtectedTypeDecl(
    name = d.name,
    generics = d.generics,
    whereClause = rewriteWhereClauseOpt(aliases, d.whereClause),
    members = ms,
    span = d.span
  )
}

// IWire ─────────────────────────────────────────────────────────────────────────
// #6320 — see filterAliasesForExpr's comment: a wire member's own
// `init`/`provider` expression can itself be a lambda (a bare `{ ... }`)
// introducing its own shadowing locals, on top of the wire-level
// `memberAliases` filtering `rewriteWireDecl` already threads in here.
func rewriteWireMember(aliases: in List[String], m: in WireMember): WireMember {
  match m {
    case WMProvided(name, ty, span) -> return WMProvided(name = name, ty = rewriteTypeExpr(aliases, ty), span = span)
    case WMSingleton(name, ty, init, span) -> return WMSingleton(
      name = name,
      ty = rewriteTypeExpr(aliases, ty),
      init = rewriteExpr(filterAliasesForExpr(aliases, init), init),
      span = span
    )
    case WMScoped(scopeName, name, ty, init, span) -> return WMScoped(
      scopeName = scopeName,
      name = name,
      ty = rewriteTypeExpr(aliases, ty),
      init = rewriteExpr(filterAliasesForExpr(aliases, init), init),
      span = span
    )
    case WMBind(iface, provider, span) -> return WMBind(
      iface = rewriteTypeExpr(aliases, iface),
      provider = rewriteExpr(filterAliasesForExpr(aliases, provider), provider),
      span = span
    )
    case WMExpose(name, span) -> return WMExpose(name = name, span = span)
    case WMLocal(name, ty, init, span) -> return WMLocal(
      name = name,
      ty = rewriteOptType(aliases, ty),
      init = rewriteExpr(filterAliasesForExpr(aliases, init), init),
      span = span
    )
    case WMContributes(iface, name, init, ordering, isSealed, span) -> return WMContributes(
      iface = rewriteTypeExpr(aliases, iface),
      name = name,
      init = rewriteExpr(filterAliasesForExpr(aliases, init), init),
      ordering = ordering,
      isSealed = isSealed,
      span = span
    )
    // Like `AspectDecl.from`, the include path is resolved by the wire
    // expander against collected template FQNs, not alias-rewritten here.
    case WMInclude(path, aliasName, adjustments, hasBody, span) -> return WMInclude(
      path = path,
      aliasName = aliasName,
      adjustments = rewriteIncludeAdjusts(aliases, adjustments),
      hasBody = hasBody,
      span = span
    )
    case WMOverridable(names, span) -> return WMOverridable(names = names, span = span)
    case WMConfigInst(decl, span) -> return WMConfigInst(decl = rewriteConfigDecl(aliases, decl), span = span)
  }
  return m
}

func rewriteIncludeAdjusts(aliases: in List[String], xs: in List[IncludeAdjust]): List[IncludeAdjust] {
  val ys: List[IncludeAdjust] = newList()
  var i = 0
  while i < xs.count {
    match xs[i] {
      // #6316 — see filterAliasesForExpr's comment: each of these `value`
      // exprs can itself be an arbitrary block/lambda introducing its own
      // shadowing locals.
      case IAProvided(name, value, span) -> ys.add(IAProvided(name = name, value = rewriteExpr(filterAliasesForExpr(aliases, value), value), span = span))
      case IAConfigOverride(name, fields, span) -> {
        val fs: List[ConfigFieldOverride] = newList()
        var j = 0
        while j < fields.count {
          val fieldAliases = filterAliasesForExpr(aliases, fields[j].value)
          fs.add(
            ConfigFieldOverride(
              name = fields[j].name,
              value = rewriteExpr(fieldAliases, fields[j].value),
              span = fields[j].span
            )
          )
          j = j + 1
        }
        ys.add(IAConfigOverride(name = name, fields = fs, span = span))
      }
      case IAReplace(name, value, span) -> ys.add(IAReplace(name = name, value = rewriteExpr(filterAliasesForExpr(aliases, value), value), span = span))
      case IARemove(name, span) -> ys.add(IARemove(name = name, span = span))
      case IAReorder(name, ordering, span) -> ys.add(IAReorder(name = name, ordering = ordering, span = span))
    }
    i = i + 1
  }
  ys
}

func rewriteWireDecl(aliases: in List[String], d: in WireDecl): WireDecl {
  val ps: List[Param] = newList()
  var i = 0
  while i < d.params.count {
    ps.add(rewriteParam(aliases, d.params[i]))
    i = i + 1
  }
  // #6316: `WireDecl.params` is a function-like parameter scope (exactly
  // analogous to `FunctionDecl.params`, #6311) visible to every member's own
  // `init`/`provider` expression — collect param names, plus each member's
  // own bound name (visible to sibling members, same coarse function-body-
  // wide spirit as #6311's `collectFunctionBodyLocalNames`), before
  // rewriting member bodies.
  val locals: List[String] = newList()
  collectParamNames(d.params, locals)
  var k = 0
  while k < d.members.count {
    match d.members[k] {
      case WMProvided(name, _, _) -> locals.add(name)
      case WMSingleton(name, _, _, _) -> locals.add(name)
      case WMScoped(_, name, _, _, _) -> locals.add(name)
      case WMLocal(name, _, _, _) -> locals.add(name)
      case WMContributes(_, name, _, _, _, _) -> locals.add(name)
      // `WMInclude`/`WMConfigInst` also introduce named bindings (a spliced
      // template's alias, a nested config instance's name). On the
      // dotnet/jvm paths `Lyric.WireExpand` always consumes `WMInclude`
      // before the alias rewriter runs, so this rarely matters there — but
      // the native/LLVM bridge invokes `pipeExpandAndRewrite` with
      // `runWireExpand = false`, so an unexpanded `WMInclude` CAN still
      // reach here.
      case WMInclude(_, aliasName, _, _, _) -> match aliasName { case Some(n) -> locals.add(n); case None -> () }
      case WMConfigInst(decl, _) -> locals.add(decl.name)
      case _ -> ()
    }
    k = k + 1
  }
  val memberAliases = filterAliasesExcludingLocals(aliases, locals)
  val ms: List[WireMember] = newList()
  var j = 0
  while j < d.members.count {
    ms.add(rewriteWireMember(memberAliases, d.members[j]))
    j = j + 1
  }
  WireDecl(name = d.name, params = ps, members = ms, span = d.span)
}

// ITypeAlias / IDistinctType ────────────────────────────────────────────────────
func rewriteTypeAliasDecl(aliases: in List[String], d: in TypeAliasDecl): TypeAliasDecl {
  TypeAliasDecl(name = d.name, generics = d.generics, rhs = rewriteTypeExpr(aliases, d.rhs), span = d.span)
}

func rewriteDistinctTypeDecl(aliases: in List[String], d: in DistinctTypeDecl): DistinctTypeDecl {
  val rc = match d.rangeClause {
    case Some(rb) -> Some(value = rewriteRangeBound(aliases, rb))
    case None -> d.rangeClause
  }
  DistinctTypeDecl(
    name = d.name,
    generics = d.generics,
    underlying = rewriteTypeExpr(aliases, d.underlying),
    rangeClause = rc,
    derives = d.derives,
    span = d.span
  )
}

// ITest / IProperty / IFixture ───────────────────────────────────────────────────
func rewriteTestDecl(aliases: in List[String], d: in TestDecl): TestDecl {
  // Scope-aware body rewrite (#6311) — see rewriteFunctionDecl's comment.
  val locals: List[String] = newList()
  collectBlockLocalNames(d.body, locals)
  val bodyAliases = filterAliasesExcludingLocals(aliases, locals)
  TestDecl(title = d.title, body = rewriteBlock(bodyAliases, d.body), span = d.span)
}

func rewritePropertyBinder(aliases: in List[String], pb: in PropertyBinder): PropertyBinder {
  PropertyBinder(name = pb.name, ty = rewriteTypeExpr(aliases, pb.ty), span = pb.span)
}

func rewritePropertyDecl(aliases: in List[String], d: in PropertyDecl): PropertyDecl {
  val bs: List[PropertyBinder] = newList()
  var i = 0
  while i < d.forAll.count {
    bs.add(rewritePropertyBinder(aliases, d.forAll[i]))
    i = i + 1
  }
  // Scope-aware body rewrite (#6311) — see rewriteFunctionDecl's comment.
  val locals: List[String] = newList()
  var j = 0
  while j < d.forAll.count {
    locals.add(d.forAll[j].name)
    j = j + 1
  }
  match d.guardExpr {
    case Some(g) -> collectExprLocalNames(g, locals)
    case None -> ()
  }
  collectBlockLocalNames(d.body, locals)
  val bodyAliases = filterAliasesExcludingLocals(aliases, locals)
  PropertyDecl(
    title = d.title,
    forAll = bs,
    guardExpr = rewriteOptExpr(bodyAliases, d.guardExpr),
    body = rewriteBlock(bodyAliases, d.body),
    span = d.span
  )
}

func rewriteFixtureDecl(aliases: in List[String], d: in FixtureDecl): FixtureDecl {
  // Scope-aware body rewrite (#6311) — see rewriteFunctionDecl's comment.
  // Uses the shared self-referential helper (#6316's `filterAliasesForExpr`)
  // rather than inlining the same collect-then-filter pattern again.
  val bodyAliases = filterAliasesForExpr(aliases, d.init)
  FixtureDecl(
    name = d.name,
    nameSpan = d.nameSpan,
    ty = rewriteOptType(aliases, d.ty),
    init = rewriteExpr(bodyAliases, d.init),
    span = d.span
  )
}

// IConfig / IAspect ──────────────────────────────────────────────────────────────
func rewriteConfigField(aliases: in List[String], f: in ConfigField): ConfigField {
  // #6316 — see filterAliasesForExpr's comment.
  val defaultAliases = match f.default { case Some(e) -> filterAliasesForExpr(aliases, e); case None -> aliases }
  ConfigField(
    docComments = f.docComments,
    annotations = f.annotations,
    name = f.name,
    ty = rewriteTypeExpr(aliases, f.ty),
    default = rewriteOptExpr(defaultAliases, f.default),
    span = f.span
  )
}

func rewriteConfigFields(aliases: in List[String], fields: in List[ConfigField]): List[ConfigField] {
  val fs: List[ConfigField] = newList()
  var i = 0
  while i < fields.count {
    fs.add(rewriteConfigField(aliases, fields[i]))
    i = i + 1
  }
  fs
}

func rewriteConfigDecl(aliases: in List[String], d: in ConfigDecl): ConfigDecl {
  ConfigDecl(name = d.name, from = d.from, fields = rewriteConfigFields(aliases, d.fields), span = d.span)
}

func rewriteArgsRowField(aliases: in List[String], f: in ArgsRowField): ArgsRowField {
  ArgsRowField(name = f.name, ty = rewriteTypeExpr(aliases, f.ty), span = f.span)
}

func rewriteArgsRow(aliases: in List[String], row: in Option[List[ArgsRowField]]): Option[List[ArgsRowField]] {
  match row {
    case None -> None
    case Some(fields) -> {
      val fs: List[ArgsRowField] = newList()
      var i = 0
      while i < fields.count {
        fs.add(rewriteArgsRowField(aliases, fields[i]))
        i = i + 1
      }
      Some(value = fs)
    }
  }
}

func rewriteAspectDecl(aliases: in List[String], d: in AspectDecl): AspectDecl {
  // `someAspectAround` (Lyric.Parser) — NOT a local `Some(value = ...)`:
  // the stage-0 bootstrap emitter miscompiles `Option[AspectAround]`
  // construction in this package, producing a value that matches neither
  // `Some` nor `None` downstream, which silently un-weaves every aspect
  // in an import-bearing file (#1298 investigation).
  // Scope-aware body rewrite (#6311) — see rewriteFunctionDecl's comment.
  // `argsName` / `retName` are the advice body's own bound names (the
  // synthesized `args` / `ret` locals), same shadowing hazard as a
  // function's params. `contractAliases` carries the SAME filtered list out
  // to `d.contracts` below (#6313) — the aspect's own `requires:`/`ensures:`
  // reference `args.<field>`/`ret`, so they need the identical shadowing
  // guard as the advice body, not the raw `aliases`. When there's no
  // `around` block, there's no `args`/`ret` scope to filter against, so
  // `contractAliases` stays the unfiltered `aliases` (matching prior,
  // pre-#6311 behavior for that case).
  var contractAliases: List[String] = aliases
  val ar = match d.around {
    case Some(a) -> {
      val locals: List[String] = newList()
      locals.add(a.argsName)
      match a.retName {
        case Some(n) -> locals.add(n)
        case None -> ()
      }
      collectBlockLocalNames(a.body, locals)
      val bodyAliases = filterAliasesExcludingLocals(aliases, locals)
      contractAliases = bodyAliases
      someAspectAround(
        AspectAround(
          argsName = a.argsName,
          retName = a.retName,
          argsRow = rewriteArgsRow(aliases, a.argsRow),
          body = rewriteBlock(bodyAliases, a.body),
          span = a.span
        )
      )
    }
    case None -> d.around
  }
  AspectDecl(
    name = d.name,
    from = d.from,
    config = rewriteConfigFields(aliases, d.config),
    matches = d.matches,
    exceptNames = d.exceptNames,
    around = ar,
    // #6313 — see the comment above `contractAliases`'s declaration.
    contracts = rewriteContracts(contractAliases, d.contracts),
    wraps = d.wraps,
    inside = d.inside,
    span = d.span
  )
}

// IExtern ─────────────────────────────────────────────────────────────────────────
func rewriteExternMember(aliases: in List[String], m: in ExternMember): ExternMember {
  match m {
    case EMRecord(decl) -> return EMRecord(decl = rewriteRecordDecl(aliases, decl))
    case EMExposedRec(decl) -> return EMExposedRec(decl = rewriteRecordDecl(aliases, decl))
    case EMUnion(decl) -> return EMUnion(decl = rewriteUnionDecl(aliases, decl))
    case EMEnum(decl) -> return EMEnum(decl = decl)
    case EMOpaque(decl) -> return EMOpaque(decl = rewriteOpaqueTypeDecl(aliases, decl))
    case EMSig(sig) -> return EMSig(sig = rewriteFunctionSig(aliases, sig))
    case EMTypeAlias(decl) -> return EMTypeAlias(decl = rewriteTypeAliasDecl(aliases, decl))
    case EMDistinctType(decl) -> return EMDistinctType(decl = rewriteDistinctTypeDecl(aliases, decl))
  }
  return m
}

func rewriteExternPackageDecl(aliases: in List[String], d: in ExternPackageDecl): ExternPackageDecl {
  val ms: List[ExternMemberDecl] = newList()
  var i = 0
  while i < d.members.count {
    val emd = d.members[i]
    ms.add(
      ExternMemberDecl(
        docComments = emd.docComments,
        annotations = emd.annotations,
        visibility = emd.visibility,
        kind = rewriteExternMember(aliases, emd.kind),
        span = emd.span
      )
    )
    i = i + 1
  }
  ExternPackageDecl(path = d.path, annotations = d.annotations, members = ms, span = d.span)
}

func rewriteItem(aliases: in List[String], it: in Item): Item {
  val kind = match it.kind {
    case IFunc(decl) -> IFunc(decl = rewriteFunctionDecl(aliases, decl))
    case IRecord(decl) -> IRecord(decl = rewriteRecordDecl(aliases, decl))
    case IExposedRec(decl) -> IExposedRec(decl = rewriteRecordDecl(aliases, decl))
    // #6321 — see filterAliasesForExpr's comment: a module-level val/const's
    // own init can itself be a lambda (a bare `{ ... }`) introducing its own
    // shadowing locals, exactly like every other standalone-expression
    // position #6316/#6320 already cover.
    case IConst(decl) -> IConst(decl = ConstDecl(name = decl.name, ty = rewriteTypeExpr(aliases, decl.ty), init = rewriteExpr(filterAliasesForExpr(aliases, decl.init), decl.init), span = decl.span))
    case IVal(decl) -> {
      val t = match decl.ty { case Some(te) -> Some(value = rewriteTypeExpr(aliases, te)); case None -> decl.ty }
      IVal(
        decl = ValDecl(
          pattern = decl.pattern,
          ty = t,
          init = rewriteExpr(filterAliasesForExpr(aliases, decl.init), decl.init),
          span = decl.span
        )
      )
    }
    case ITypeAlias(decl) -> ITypeAlias(decl = rewriteTypeAliasDecl(aliases, decl))
    case IDistinctType(decl) -> IDistinctType(decl = rewriteDistinctTypeDecl(aliases, decl))
    case IUnion(decl) -> IUnion(decl = rewriteUnionDecl(aliases, decl))
    // IEnum: an EnumCase carries no TypeExpr / Expr payloads, only a name and
    // doc/annotation metadata, so there is nothing to rewrite — passed through.
    case IEnum(decl) -> IEnum(decl = decl)
    case IOpaque(decl) -> IOpaque(decl = rewriteOpaqueTypeDecl(aliases, decl))
    case IProtected(decl) -> IProtected(decl = rewriteProtectedTypeDecl(aliases, decl))
    case IInterface(decl) -> IInterface(decl = rewriteInterfaceDecl(aliases, decl))
    case IImpl(decl) -> IImpl(decl = rewriteImplDecl(aliases, decl))
    case IWire(decl) -> IWire(decl = rewriteWireDecl(aliases, decl))
    // IScopeKind: a ScopeKindDecl is just a name; nothing to rewrite.
    case IScopeKind(decl) -> IScopeKind(decl = decl)
    case IExtern(decl) -> IExtern(decl = rewriteExternPackageDecl(aliases, decl))
    // IExternType: name + generic-param names + a CLR-name string literal —
    // no TypeExpr to rewrite, passed through.
    case IExternType(decl) -> IExternType(decl = decl)
    case IExternFunc(decl) -> IExternFunc(decl = rewriteExternFuncDecl(aliases, decl))
    case ITest(decl) -> ITest(decl = rewriteTestDecl(aliases, decl))
    case IProperty(decl) -> IProperty(decl = rewritePropertyDecl(aliases, decl))
    case IFixture(decl) -> IFixture(decl = rewriteFixtureDecl(aliases, decl))
    case IConfig(decl) -> IConfig(decl = rewriteConfigDecl(aliases, decl))
    case IAspect(decl) -> IAspect(decl = rewriteAspectDecl(aliases, decl))
    // IError carries no payload to rewrite.
    case IError -> it.kind
  }
  Item(
    docComments = it.docComments,
    annotations = it.annotations,
    visibility = it.visibility,
    kind = kind,
    span = it.span
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
/// Apply package-alias rewriting to every `Item` in `file`.  No-op when
/// the file has no `import X as Y` declarations.
pub func rewriteFile(file: in SourceFile): SourceFile {
  val aliases = collectAliases(file.imports)
  if aliases.count == 0 {
    return file
  }
  // #6312: strip any alias a module-level val/const would shadow before
  // rewriting ANY item — module-scope names are visible file-wide, unlike
  // the per-function locals #6311 already guards against.
  val moduleLocals: List[String] = newList()
  collectModuleLevelValueNames(file, moduleLocals)
  val fileAliases = filterAliasesExcludingLocals(aliases, moduleLocals)
  val items: List[Item] = newList()
  var i = 0
  while i < file.items.count {
    items.add(rewriteItem(fileAliases, file.items[i]))
    i = i + 1
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
