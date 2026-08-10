//! lyric/type_alias_resolve.l — Lyric.TypeAliasResolve: whole-file AST
//! pre-pass that resolves `alias X = RHS` references to their underlying
//! `TypeExpr` before codegen (#6404).
//!
//! Motivation: `typeExprToJvm`'s `TRef` fallback treats ANY name it doesn't
//! recognize as "user-defined type in the same package" and emits
//! `JRef(pkg/<name>)`. Before #6393/#6405 that included function-type
//! aliases (`alias Handler = (Int) -> Int`); #6404 tracks the remaining
//! gaps: non-function alias targets (`alias Meters = Long`), and the many
//! JVM signature/lowering call sites (protected entries, record/impl/
//! interface methods, opaque fields) that never receive an alias map at
//! all (`registerInstanceSig`/`registerFieldElemSig`/`lowerProtectedMethod`/
//! etc., `jvm/codegen/06_items.l`).
//!
//! Design (chosen over threading an `aliasTargets` parameter through the
//! ~80 `typeExprToJvm`/`typeExprToJvmExtern`/`typeExprToJvmErasedExtern`
//! call sites across `jvm/codegen/{01_types,02_exprs,03_match,04_calls,
//! 05_stmts,06_items}.l` and every intermediate signature-collection/
//! lowering function that calls them): resolve the ENTIRE file's `alias`
//! references ONCE, structurally, before any JVM codegen function ever
//! runs. `typeExprToJvm`'s fallback then never sees an alias name — the
//! AST already carries the resolved type — so every consumer (including
//! ones #6404's tracker calls out by name, plus incidental ones like
//! `fileNeedsLambdaIface`) is fixed by construction, with no change to
//! the codegen call graph at all. This mirrors the repo's established
//! pre-codegen AST-transform precedent (`Lyric.Cfg.applyCfgErasure`,
//! `Lyric.Stubbable.stubbableRewriteFile`, and — closest in shape, since
//! it already walks every `Item`/`Expr`/`TypeExpr`/`Pattern` in a file for
//! a DIFFERENT alias mechanism (`import X as A`) — `Lyric.AliasRewriter`).
//! `Lyric.AliasRewriter` was deliberately NOT extended with a second
//! threaded parameter for this: its traversal carries extensive
//! local-variable-shadowing bookkeeping (`filterAliasesExcludingLocals`,
//! `collect*LocalNames`) that only matters for VALUE-level import aliases,
//! not TYPE-level aliases (types and values are different namespaces, so a
//! local variable can never shadow a type alias) — grafting an unrelated
//! resolution concern onto that already-dense traversal risked subtle
//! interaction bugs for no shared benefit. The pass is wired into BOTH
//! backends (`Jvm.Bridge` and `Msil.Bridge`, each at both their single-file
//! and per-package pipelines, immediately after `pipeExpandAndRewrite`):
//! MSIL's own `cctx.aliasTargets` consultation in `typeExprToMsilCtx`
//! (#3673) is retained as a no-op layer for the SAME-FILE shapes this pass
//! already resolves, but is NOT sufficient on its own — positions that
//! bypass `typeExprToMsilCtx` entirely (a generic-application HEAD such as
//! `alias L = List` used as `L[Int]`, and `implTargetNameMsil`'s direct
//! `decl.target` pattern-match) miscompiled silently on MSIL until this
//! pass resolved them structurally (#6411, #6414).
//!
//! Retirement audit (#6413): with this pass covering both targets, #6413
//! asked whether the OLDER, narrower per-site alias machinery each backend
//! carried before this pass existed (MSIL's `cctx.aliasTargets`/
//! `registerTypeAliasMsil`/`resolveFuncTypeExprMsil`; JVM's
//! `FuncCtx.aliasTargets`/`Lyric.BareFuncRef.collectFuncAliasTargets`
//! call sites in `jvm/codegen/*.l`) is now fully redundant and could be
//! deleted. It is NOT — both mechanisms cover real shapes this file-scoped
//! AST pass structurally cannot reach, because it only ever sees ONE
//! already-parsed `SourceFile` at a time:
//!   - MSIL cross-package (same-bundle) aliases: `cctx.aliasTargets` is
//!     shared across a WHOLE project build (one `CodegenCtx`, `Msil.Bridge`
//!     Phase 3's `addPackageTokens` loop runs for every package before
//!     Phase 4 codegen runs for any of them), so `typeExprToMsilCtx`
//!     resolves a sibling package's `pub alias` referenced either bare
//!     (`Handler`, via `import Pkg`) or fully qualified (`Pkg.Handler`) —
//!     `lastSegmentMsil` always keys by simple name. This pass has no such
//!     shared state: `resolveTypeAliasesMsil` runs per-package, in
//!     isolation, before any other package's file even exists in memory.
//!     Verified live in `msil_project_bridge_self_test.l`'s "two packages
//!     each defining their own lambda index 0..." case, which references
//!     `XPkgLambda0.A.Handler` (a cross-package function-type alias) from
//!     package B and depends on `cctx.aliasTargets` to resolve it — deleting
//!     the MSIL layer breaks that test.
//!   - MSIL cross-ASSEMBLY (restored-dependency) aliases: a `pub alias`
//!     from a separately-compiled, already-built DLL reaches
//!     `registerTypeAliasMsil` via `registerRestoredArtifactTokens`'s
//!     `ITypeAlias` arm, fed from contract metadata, not from re-parsed
//!     Lyric source at all — there is no `SourceFile` for this pass to walk.
//!   - JVM stdlib-bundled files: `Jvm.Bridge.compileToJarBundledWithFeatures`
//!     compiles the user's own file(s) (alias-resolved by this pass, per
//!     `resolveTypeAliases` above) PLUS the transitive closure of imported
//!     stdlib packages (`toBundle`/`stdlibFiles`), which — per this doc's own
//!     scope note above — this pass deliberately does NOT touch. Those files
//!     still flow through the SAME codegen entry points as user files
//!     (`codegenPackageWithSigsSeeded`, `collectFileSigsSeeded`, `lowerFunc`,
//!     `makeFuncCtx`), so `FuncCtx.aliasTargets` / `collectFuncAliasTargets`
//!     remain the only mechanism that would resolve a function-type `pub
//!     alias` declared and used within one stdlib file. No stdlib `.l` file
//!     declares such an alias today (verified by grep), so this is currently
//!     dormant rather than exercised — but it is a real, reachable gap this
//!     pass does not close, not a hypothetical one, so the JVM per-site
//!     machinery stays.
//! Both older mechanisms are therefore KEPT, not retired — see
//! `docs/03-decision-log.md` D-progress-752 for the full per-site audit.
//!
//! Scope (matches #6404's three axes; language reference: `alias` is fully
//! transparent, so every annotation position must behave identically to
//! writing the underlying type inline):
//!   - Resolved: function params/returns/bodies (top-level, record/impl/
//!     interface/protected methods, protected entries), record/union/
//!     opaque/protected fields, interface method signatures, `impl` header
//!     `target`/`iface` (#6414), a distinct type's UNDERLYING representation
//!     (`DistinctTypeDecl.underlying`, #6412 — the distinct type's own NAME
//!     stays nominal), wire member types + inits, config field types, local
//!     `val`/`var`/`let` annotations, lambda param annotations,
//!     `match`/`as`-style type-test patterns (`PTypeTest`), explicit
//!     type-application args (`ETypeApp`).
//!   - NOT resolved (by design): the `alias X = ...` declarations
//!     themselves (`ITypeAlias.rhs` stays exactly as written — the alias
//!     table is derived from it); a generic type parameter's own name, even
//!     if it happens to collide with an outer alias name (the type param
//!     shadows the alias in that scope, exactly as a JVM-codegen `typeParams`
//!     check would if it ran instead); `extern`/`extern type`/`extern func`
//!     boundaries (a different, host-FQN-keyed resolution mechanism);
//!     `where`-clause bounds and a const-generic value param's
//!     `GPValue.constraint` (type-checker-only surfaces — checked against
//!     declarations before codegen, never lowered into emitted signatures);
//!     `aspect` bodies (deferred — complex `call`/`proceed` body shape,
//!     no evidence they hit this bug; tracked with the depth-bound residual
//!     in #6416). Contract clauses ARE resolved
//!     (`resolveContracts`): they lower into real runtime asserts in
//!     `@runtime_checked` modules, so they are compiled like any other
//!     code (#6410 review).
//!   - Axis 3 (visibility): docs/19 multi-file packages are concatenated
//!     into one `SourceFile` BEFORE parsing, so the per-file
//!     `Lyric.BareFuncRef.collectFuncAliasTargets` already sees every
//!     alias of the package being compiled. A cross-PACKAGE alias (a
//!     different package's `pub alias`) stays out of scope, same as
//!     MSIL's historical cross-package limit.
package Lyric.TypeAliasResolve

import Std.Core
import Std.Collections
import Lyric.Parser
import Lyric.BareFuncRef as BFR

// ─────────────────────────────────────────────────────────────────────────────
// §1. Small helpers.
// ─────────────────────────────────────────────────────────────────────────────
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

func unionNames(a: in List[String], b: in List[String]): List[String] {
  val merged: List[String] = newList()
  var i = 0
  while i < a.count {
    merged.add(a[i])
    i = i + 1
  }
  var j = 0
  while j < b.count {
    if not listContainsStr(merged, b[j]) {
      merged.add(b[j])
    }
    j = j + 1
  }
  merged
}

func genericParamNamesOf(generics: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  match generics {
    case Some(gp) -> {
      var i = 0
      while i < gp.params.count {
        match gp.params[i] {
          case GPType(name, _) -> names.add(name)
          case GPValue(name, _, _) -> names.add(name)
        }
        i = i + 1
      }
    }
    case None -> {
    }
  }
  names
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. TypeExpr / TypeArg resolution.
// ─────────────────────────────────────────────────────────────────────────────
// Resolve a `TRef` alias chain to its underlying `TypeExpr`, recursing so a
// multi-hop chain (`alias A = B; alias B = Long`) and any alias reference
// NESTED inside the resolved target (`alias Ints = List[Meters]`) both fully
// bottom out. `genericNames` are the type parameter names in scope at this
// point in the AST — a `TRef` naming one is left untouched (the type param
// shadows any outer alias of the same name). CYCLE GUARD (#6410): this pass
// runs BEFORE the type checker on the JVM pipeline, so a cyclic alias
// (`alias A = B; alias B = A`, or nested self-reference `alias A = List[A]`)
// reaches it before T0017 can reject it — the whole type-family recursion
// therefore threads a depth bound (same rationale as
// `Lyric.Propagate.classifyRetType`'s bound); past it the node is returned
// UNRESOLVED so the type checker's own cycle diagnostic fires downstream
// instead of a hang/stack overflow. (Known theoretical residual, accepted:
// a cycle routed through a const-generic VALUE expression's own type
// annotation re-enters the expr walker, which does not thread depth — that
// shape requires an alias whose rhs embeds a typed lambda naming the alias
// inside an array-size expression.) The ORIGINAL reference site's span is
// kept on the resolved node so diagnostics still point at the use site,
// not the `alias` declaration.
pub func resolveTypeExpr(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], te: in TypeExpr
): TypeExpr {
  resolveTypeExprAt(aliasTargets, genericNames, te, 0)
}

func resolveTypeExprAt(
  aliasTargets: in Map[String, TypeExpr],
  genericNames: in List[String],
  te: in TypeExpr,
  depth: in Int,
): TypeExpr {
  if depth > 64 {
    return te
  }
  val kind = match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 and not listContainsStr(genericNames, path.segments[0]) {
        match mapGet(aliasTargets, path.segments[0]) {
          case Some(rhs) -> resolveTypeExprAt(aliasTargets, genericNames, rhs, depth + 1).kind
          case None -> TRef(path = path)
        }
      } else {
        TRef(path = path)
      }
    }
    case TGenericApp(head, args) -> {
      val args2: List[TypeArg] = newList()
      var i = 0
      while i < args.count {
        args2.add(resolveTypeArgAt(aliasTargets, genericNames, args[i], depth + 1))
        i = i + 1
      }
      // A single-segment alias in HEAD position (`alias M = SomeMap` used as
      // `M[K, V]`) substitutes only when the alias bottoms out in a plain
      // `TRef` — any other resolved shape can't be expressed as a
      // `ModulePath` head and is left unresolved (parameterized aliases are
      // never registered at all; see the collector's guard).
      val head2 = if head.segments.count == 1 and not listContainsStr(genericNames, head.segments[0]) {
        match mapGet(aliasTargets, head.segments[0]) {
          case Some(rhs) -> {
            match resolveTypeExprAt(aliasTargets, genericNames, rhs, depth + 1).kind {
              case TRef(rp) -> rp
              case _ -> head
            }
          }
          case None -> head
        }
      } else {
        head
      }
      TGenericApp(head = head2, args = args2)
    }
    case TArray(size, element) -> TArray(size = resolveTypeArgAt(aliasTargets, genericNames, size, depth + 1), element = resolveTypeExprAt(aliasTargets, genericNames, element, depth + 1))
    case TSlice(element) -> TSlice(element = resolveTypeExprAt(aliasTargets, genericNames, element, depth + 1))
    // `TRefined.underlying` is a bare `ModulePath`, not a `TypeExpr` — it
    // can only be replaced in place when the fully-resolved alias target is
    // itself a plain `TRef` (e.g. `alias Meters = Long; type Age = Meters
    // range 0 ..= 150`). Any other resolved shape (generic, tuple, ...)
    // can't be expressed as a `ModulePath`; left untouched in that rare
    // case exactly as before this pass existed.
    case TRefined(underlying, range) -> {
      if underlying.segments.count == 1 and not listContainsStr(genericNames, underlying.segments[0]) {
        match mapGet(aliasTargets, underlying.segments[0]) {
          case Some(rhs) -> {
            val resolved = resolveTypeExprAt(aliasTargets, genericNames, rhs, depth + 1)
            match resolved.kind {
              case TRef(rp) -> TRefined(underlying = rp, range = range)
              case _ -> TRefined(underlying = underlying, range = range)
            }
          }
          case None -> TRefined(underlying = underlying, range = range)
        }
      } else {
        TRefined(underlying = underlying, range = range)
      }
    }
    case TTuple(types) -> {
      val xs: List[TypeExpr] = newList()
      var i = 0
      while i < types.count {
        xs.add(resolveTypeExprAt(aliasTargets, genericNames, types[i], depth + 1))
        i = i + 1
      }
      TTuple(types = xs)
    }
    case TNullable(inner) -> TNullable(inner = resolveTypeExprAt(aliasTargets, genericNames, inner, depth + 1))
    case TFunction(parameters, retTy) -> {
      val ps: List[TypeExpr] = newList()
      var i = 0
      while i < parameters.count {
        ps.add(resolveTypeExprAt(aliasTargets, genericNames, parameters[i], depth + 1))
        i = i + 1
      }
      TFunction(parameters = ps, retTy = resolveTypeExprAt(aliasTargets, genericNames, retTy, depth + 1))
    }
    case TParen(inner) -> TParen(inner = resolveTypeExprAt(aliasTargets, genericNames, inner, depth + 1))
    case TUnit -> TUnit
    case TSelf -> TSelf
    case TNever -> TNever
    case TError -> TError
  }
  TypeExpr(kind = kind, span = te.span)
}

// Contract clauses are lowered into REAL runtime asserts by
// `Lyric.ContractElaborator` in `@runtime_checked` modules, so their
// expressions get JVM-compiled like any other code — an alias inside a
// clause (a type-test pattern, an explicit generic instantiation, a
// quantifier binder annotation) must resolve like everywhere else.
func resolveContracts(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], cs: in List[ContractClause]
): List[ContractClause] {
  val out2: List[ContractClause] = newList()
  var i = 0
  while i < cs.count {
    val resolved = match cs[i] {
      case CCRequires(e, sp) -> CCRequires(expr = resolveExpr(aliasTargets, genericNames, e), span = sp)
      case CCEnsures(e, sp) -> CCEnsures(expr = resolveExpr(aliasTargets, genericNames, e), span = sp)
      case CCWhen(e, sp) -> CCWhen(expr = resolveExpr(aliasTargets, genericNames, e), span = sp)
      case CCDecreases(e, sp) -> CCDecreases(expr = resolveExpr(aliasTargets, genericNames, e), span = sp)
      case CCRaises(types, sp) -> {
        val ts: List[TypeExpr] = newList()
        var ti = 0
        while ti < types.count {
          ts.add(resolveTypeExpr(aliasTargets, genericNames, types[ti]))
          ti = ti + 1
        }
        CCRaises(types = ts, span = sp)
      }
    }
    out2.add(resolved)
    i = i + 1
  }
  out2
}

func resolveOptType(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], oty: in Option[TypeExpr]
): Option[TypeExpr] {
  match oty {
    case Some(te) -> Some(value = resolveTypeExpr(aliasTargets, genericNames, te))
    case None -> oty
  }
}

func resolveTypeArg(aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], a: in TypeArg): TypeArg {
  resolveTypeArgAt(aliasTargets, genericNames, a, 0)
}

func resolveTypeArgAt(
  aliasTargets: in Map[String, TypeExpr],
  genericNames: in List[String],
  a: in TypeArg,
  depth: in Int,
): TypeArg {
  match a {
    case TAType(ty) -> TAType(ty = resolveTypeExprAt(aliasTargets, genericNames, ty, depth))
    case TAValue(e) -> TAValue(expr = resolveExpr(aliasTargets, genericNames, e))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Pattern resolution (only `PTypeTest` carries a literal `TypeExpr`;
// the rest is a structural walk to reach any nested occurrence).
// ─────────────────────────────────────────────────────────────────────────────
func resolvePattern(aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], p: in Pattern): Pattern {
  val kind = match p.kind {
    case PConstructor(head, args) -> {
      val ps: List[Pattern] = newList()
      var i = 0
      while i < args.count {
        ps.add(resolvePattern(aliasTargets, genericNames, args[i]))
        i = i + 1
      }
      PConstructor(head = head, args = ps)
    }
    case PRecord(head, fields, ignoreRest) -> {
      val fs: List[RecordPatternField] = newList()
      var i = 0
      while i < fields.count {
        fs.add(
          match fields[i] {
            case RPFNamed(name, pattern, span) -> RPFNamed(name = name, pattern = resolvePattern(aliasTargets, genericNames, pattern), span = span)
            case RPFShort(name, span) -> RPFShort(name = name, span = span)
          }
        )
        i = i + 1
      }
      PRecord(head = head, fields = fs, ignoreRest = ignoreRest)
    }
    case PTuple(patterns) -> {
      val ps: List[Pattern] = newList()
      var i = 0
      while i < patterns.count {
        ps.add(resolvePattern(aliasTargets, genericNames, patterns[i]))
        i = i + 1
      }
      PTuple(patterns = ps)
    }
    case PParen(inner) -> PParen(inner = resolvePattern(aliasTargets, genericNames, inner))
    case PTypeTest(inner, ty) -> PTypeTest(inner = resolvePattern(aliasTargets, genericNames, inner), ty = resolveTypeExpr(aliasTargets, genericNames, ty))
    case POr(patterns) -> {
      val ps: List[Pattern] = newList()
      var i = 0
      while i < patterns.count {
        ps.add(resolvePattern(aliasTargets, genericNames, patterns[i]))
        i = i + 1
      }
      POr(patterns = ps)
    }
    case PBinding(name, inner) -> {
      val inner2 = match inner {
        case Some(p2) -> Some(value = resolvePattern(aliasTargets, genericNames, p2))
        case None -> inner
      }
      PBinding(name = name, inner = inner2)
    }
    case PRange(lo, inclusive, hi) -> PRange(lo = resolveExpr(aliasTargets, genericNames, lo), inclusive = inclusive, hi = resolveExpr(aliasTargets, genericNames, hi))
    case PWildcard -> PWildcard
    case PLiteral(lit) -> PLiteral(lit = lit)
    case PConstRef(name) -> PConstRef(name = name)
    case PError -> PError
  }
  Pattern(kind = kind, span = p.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Block / Statement / Expr resolution — structural walk to reach every
// local `val`/`var`/`let` annotation, lambda param annotation, explicit
// type-application arg, and type-test pattern nested inside a function body.
// `genericNames` never changes within a body (Lyric has no generic lambdas),
// so it is threaded unchanged all the way down.
// ─────────────────────────────────────────────────────────────────────────────
func resolveBlock(aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], b: in Block): Block {
  val ss: List[Statement] = newList()
  var i = 0
  while i < b.statements.count {
    ss.add(resolveStatement(aliasTargets, genericNames, b.statements[i]))
    i = i + 1
  }
  Block(statements = ss, span = b.span)
}

func resolveLocalBinding(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], lb: in LocalBinding
): LocalBinding {
  match lb {
    case LBVal(pat, ty, init) -> LBVal(pat = resolvePattern(aliasTargets, genericNames, pat), ty = resolveOptType(aliasTargets, genericNames, ty), init = resolveExpr(aliasTargets, genericNames, init))
    case LBVar(name, ty, init) -> {
      val ni = match init { case Some(e) -> Some(value = resolveExpr(aliasTargets, genericNames, e)); case None -> None }
      LBVar(name = name, ty = resolveOptType(aliasTargets, genericNames, ty), init = ni)
    }
    case LBLet(name, ty, init) -> LBLet(name = name, ty = resolveOptType(aliasTargets, genericNames, ty), init = resolveExpr(aliasTargets, genericNames, init))
  }
}

func resolveCatch(aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], c: in CatchClause): CatchClause {
  CatchClause(
    typeName = c.typeName,
    bindName = c.bindName,
    body = resolveBlock(aliasTargets, genericNames, c.body),
    span = c.span
  )
}

func resolveStatement(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], stmt: in Statement
): Statement {
  val k = match stmt.kind {
    case SLocal(binding) -> SLocal(binding = resolveLocalBinding(aliasTargets, genericNames, binding))
    case SAssign(target, op, value) -> SAssign(target = resolveExpr(aliasTargets, genericNames, target), op = op, value = resolveExpr(aliasTargets, genericNames, value))
    case SReturn(value) -> {
      match value {
        case Some(e) -> SReturn(value = Some(value = resolveExpr(aliasTargets, genericNames, e)))
        case None -> SReturn(value = None)
      }
    }
    case SBreak(label) -> SBreak(label = label)
    case SContinue(label) -> SContinue(label = label)
    case SThrow(expr) -> SThrow(expr = resolveExpr(aliasTargets, genericNames, expr))
    case STry(body, catches, finally_) -> {
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        newCatches.add(resolveCatch(aliasTargets, genericNames, catches[i]))
        i = i + 1
      }
      val newFin = match finally_ {
        case Some(b) -> Some(value = resolveBlock(aliasTargets, genericNames, b))
        case None -> None
      }
      STry(body = resolveBlock(aliasTargets, genericNames, body), catches = newCatches, finally_ = newFin)
    }
    case SDefer(body) -> SDefer(body = resolveBlock(aliasTargets, genericNames, body))
    case SScope(binding, body) -> SScope(binding = binding, body = resolveBlock(aliasTargets, genericNames, body))
    case SFor(label, pat, iter, body) -> SFor(label = label, pat = resolvePattern(aliasTargets, genericNames, pat), iter = resolveExpr(aliasTargets, genericNames, iter), body = resolveBlock(aliasTargets, genericNames, body))
    case SWhile(label, cond, body) -> SWhile(label = label, cond = resolveExpr(aliasTargets, genericNames, cond), body = resolveBlock(aliasTargets, genericNames, body))
    case SLoop(label, body) -> SLoop(label = label, body = resolveBlock(aliasTargets, genericNames, body))
    case SInvariant(expr) -> SInvariant(expr = resolveExpr(aliasTargets, genericNames, expr))
    case SExpr(expr) -> SExpr(expr = resolveExpr(aliasTargets, genericNames, expr))
    case SRule(lhs, rhs) -> SRule(lhs = resolveExpr(aliasTargets, genericNames, lhs), rhs = resolveExpr(aliasTargets, genericNames, rhs))
    case SItem(item) -> SItem(item = resolveItem(aliasTargets, item))
  }
  Statement(kind = k, span = stmt.span)
}

func resolveExprOrBlock(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], eob: in ExprOrBlock
): ExprOrBlock {
  match eob {
    case EOBExpr(e) -> EOBExpr(expr = resolveExpr(aliasTargets, genericNames, e))
    case EOBBlock(b) -> EOBBlock(block = resolveBlock(aliasTargets, genericNames, b))
  }
}

func resolveExpr(aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], expr: in Expr): Expr {
  val k = match expr.kind {
    case EParen(inner) -> EParen(inner = resolveExpr(aliasTargets, genericNames, inner))
    case ETuple(es) -> {
      val ne: List[Expr] = newList()
      var i = 0
      while i < es.count {
        ne.add(resolveExpr(aliasTargets, genericNames, es[i]))
        i = i + 1
      }
      ETuple(exprs = ne)
    }
    case EList(es) -> {
      val ne: List[Expr] = newList()
      var i = 0
      while i < es.count {
        ne.add(resolveExpr(aliasTargets, genericNames, es[i]))
        i = i + 1
      }
      EList(exprs = ne)
    }
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      val ne = match elseBranch {
        case Some(eb) -> Some(value = resolveExprOrBlock(aliasTargets, genericNames, eb))
        case None -> None
      }
      EIf(
        cond = resolveExpr(aliasTargets, genericNames, cond),
        thenBranch = resolveExprOrBlock(aliasTargets, genericNames, thenBranch),
        elseBranch = ne,
        thenForm = thenForm
      )
    }
    case EMatch(scrutinee, arms) -> {
      val na: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val ng = match arm.guard {
          case Some(g) -> Some(value = resolveExpr(aliasTargets, genericNames, g))
          case None -> None
        }
        na.add(
          MatchArm(
            pattern = resolvePattern(aliasTargets, genericNames, arm.pattern),
            guard = ng,
            body = resolveExprOrBlock(aliasTargets, genericNames, arm.body),
            span = arm.span
          )
        )
        i = i + 1
      }
      EMatch(scrutinee = resolveExpr(aliasTargets, genericNames, scrutinee), arms = na)
    }
    case EAwait(inner) -> EAwait(inner = resolveExpr(aliasTargets, genericNames, inner))
    case EYield(inner) -> EYield(inner = resolveExpr(aliasTargets, genericNames, inner))
    case ESpawn(inner) -> ESpawn(inner = resolveExpr(aliasTargets, genericNames, inner))
    case ETry(inner) -> ETry(inner = resolveExpr(aliasTargets, genericNames, inner))
    case EOld(inner) -> EOld(inner = resolveExpr(aliasTargets, genericNames, inner))
    case ELambda(lambdaParams, body) -> {
      val nps: List[LambdaParam] = newList()
      var i = 0
      while i < lambdaParams.count {
        val lp = lambdaParams[i]
        nps.add(LambdaParam(name = lp.name, ty = resolveOptType(aliasTargets, genericNames, lp.ty), span = lp.span))
        i = i + 1
      }
      ELambda(lambdaParams = nps, body = resolveBlock(aliasTargets, genericNames, body))
    }
    case ECall(fn, args) -> {
      val na: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(e) -> na.add(CAPositional(expr = resolveExpr(aliasTargets, genericNames, e)))
          case CANamed(n, e, span) -> na.add(CANamed(name = n, value = resolveExpr(aliasTargets, genericNames, e), span = span))
        }
        i = i + 1
      }
      ECall(fn = resolveExpr(aliasTargets, genericNames, fn), args = na)
    }
    case ETypeApp(fn, args) -> {
      val na: List[TypeArg] = newList()
      var i = 0
      while i < args.count {
        na.add(resolveTypeArg(aliasTargets, genericNames, args[i]))
        i = i + 1
      }
      ETypeApp(fn = resolveExpr(aliasTargets, genericNames, fn), args = na)
    }
    case EIndex(receiver, indices) -> {
      val ni: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        ni.add(resolveExpr(aliasTargets, genericNames, indices[i]))
        i = i + 1
      }
      EIndex(receiver = resolveExpr(aliasTargets, genericNames, receiver), indices = ni)
    }
    case EMember(receiver, memberName) -> EMember(receiver = resolveExpr(aliasTargets, genericNames, receiver), memberName = memberName)
    case EPropagate(inner) -> EPropagate(inner = resolveExpr(aliasTargets, genericNames, inner))
    case EPrefix(op, operand) -> EPrefix(op = op, operand = resolveExpr(aliasTargets, genericNames, operand))
    case EBinop(op, lhs, rhs) -> EBinop(op = op, lhs = resolveExpr(aliasTargets, genericNames, lhs), rhs = resolveExpr(aliasTargets, genericNames, rhs))
    case ERange(bound) -> {
      val nb = match bound {
        case RBClosed(lo, hi) -> RBClosed(lo = resolveExpr(aliasTargets, genericNames, lo), hi = resolveExpr(aliasTargets, genericNames, hi))
        case RBHalfOpen(lo, hi) -> RBHalfOpen(lo = resolveExpr(aliasTargets, genericNames, lo), hi = resolveExpr(aliasTargets, genericNames, hi))
        case RBLowerOpen(hi) -> RBLowerOpen(hi = resolveExpr(aliasTargets, genericNames, hi))
        case RBUpperOpen(lo) -> RBUpperOpen(lo = resolveExpr(aliasTargets, genericNames, lo))
      }
      ERange(bound = nb)
    }
    case EAssign(target, op, value) -> EAssign(target = resolveExpr(aliasTargets, genericNames, target), op = op, value = resolveExpr(aliasTargets, genericNames, value))
    case EBlock(block) -> EBlock(block = resolveBlock(aliasTargets, genericNames, block))
    case EUnsafe(block) -> EUnsafe(block = resolveBlock(aliasTargets, genericNames, block))
    case EInterpolated(segments) -> {
      val ns: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(text, span) -> ns.add(ISText(text = text, span = span))
          case ISExpr(e) -> ns.add(ISExpr(expr = resolveExpr(aliasTargets, genericNames, e)))
        }
        i = i + 1
      }
      EInterpolated(segments = ns)
    }
    // Remaining ExprKind variants (ELiteral, EPath, ESelf, EResult, ...)
    // carry no TypeExpr and no nested Block/Expr — pass through unchanged.
    case EForall(binders, whereExpr, body) -> {
      val bs: List[PropertyBinder] = newList()
      var bi = 0
      while bi < binders.count {
        bs.add(
          PropertyBinder(
            name = binders[bi].name,
            ty = resolveTypeExpr(aliasTargets, genericNames, binders[bi].ty),
            span = binders[bi].span
          )
        )
        bi = bi + 1
      }
      val w2 = match whereExpr {
        case Some(w) -> Some(value = resolveExpr(aliasTargets, genericNames, w))
        case None -> None
      }
      EForall(binders = bs, whereExpr = w2, body = resolveExpr(aliasTargets, genericNames, body))
    }
    case EExists(binders, whereExpr, body) -> {
      val bs: List[PropertyBinder] = newList()
      var bi = 0
      while bi < binders.count {
        bs.add(
          PropertyBinder(
            name = binders[bi].name,
            ty = resolveTypeExpr(aliasTargets, genericNames, binders[bi].ty),
            span = binders[bi].span
          )
        )
        bi = bi + 1
      }
      val w2 = match whereExpr {
        case Some(w) -> Some(value = resolveExpr(aliasTargets, genericNames, w))
        case None -> None
      }
      EExists(binders = bs, whereExpr = w2, body = resolveExpr(aliasTargets, genericNames, body))
    }
    case _ -> expr.kind
  }
  Expr(kind = k, span = expr.span)
}

func resolveFunctionBody(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], b: in FunctionBody
): FunctionBody {
  match b {
    case FBExpr(e) -> FBExpr(expr = resolveExpr(aliasTargets, genericNames, e))
    case FBBlock(block) -> FBBlock(block = resolveBlock(aliasTargets, genericNames, block))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Item-level resolution.
// ─────────────────────────────────────────────────────────────────────────────
func resolveParam(aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], p: in Param): Param {
  val d = match p.dflt { case Some(e) -> Some(value = resolveExpr(aliasTargets, genericNames, e)); case None -> p.dflt }
  Param(
    mode = p.mode,
    modeExplicit = p.modeExplicit,
    name = p.name,
    ty = resolveTypeExpr(aliasTargets, genericNames, p.ty),
    dflt = d,
    annotations = p.annotations,
    span = p.span
  )
}

func resolveParams(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], params: in List[Param]
): List[Param] {
  val ps: List[Param] = newList()
  var i = 0
  while i < params.count {
    ps.add(resolveParam(aliasTargets, genericNames, params[i]))
    i = i + 1
  }
  ps
}

func resolveFieldDecl(aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], f: in FieldDecl): FieldDecl {
  val d = match f.dflt { case Some(e) -> Some(value = resolveExpr(aliasTargets, genericNames, e)); case None -> f.dflt }
  FieldDecl(
    docComments = f.docComments,
    annotations = f.annotations,
    visibility = f.visibility,
    isMutable = f.isMutable,
    name = f.name,
    ty = resolveTypeExpr(aliasTargets, genericNames, f.ty),
    dflt = d,
    span = f.span
  )
}

// A top-level `FunctionDecl`'s own generics are its scope; a MEMBER
// function's scope is its own generics unioned with the enclosing
// type's (`outerGenerics`) — a record/protected/interface/impl method may
// reference the enclosing declaration's type parameters.
func resolveFunctionDecl(
  aliasTargets: in Map[String, TypeExpr], outerGenerics: in List[String], fn: in FunctionDecl
): FunctionDecl {
  val ownGenerics = genericParamNamesOf(fn.generics)
  val fnScope = unionNames(outerGenerics, ownGenerics)
  val ret = resolveOptType(aliasTargets, fnScope, fn.ret)
  val body = match fn.body {
    case Some(b) -> Some(value = resolveFunctionBody(aliasTargets, fnScope, b))
    case None -> fn.body
  }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = resolveParams(aliasTargets, fnScope, fn.params),
    ret = ret,
    whereClause = fn.whereClause,
    contracts = resolveContracts(aliasTargets, fnScope, fn.contracts),
    body = body,
    span = fn.span
  )
}

func resolveEntryDecl(
  aliasTargets: in Map[String, TypeExpr], outerGenerics: in List[String], ed: in EntryDecl
): EntryDecl {
  EntryDecl(
    docComments = ed.docComments,
    annotations = ed.annotations,
    visibility = ed.visibility,
    name = ed.name,
    params = resolveParams(aliasTargets, outerGenerics, ed.params),
    ret = resolveOptType(aliasTargets, outerGenerics, ed.ret),
    contracts = resolveContracts(aliasTargets, outerGenerics, ed.contracts),
    body = resolveFunctionBody(aliasTargets, outerGenerics, ed.body),
    span = ed.span
  )
}

func resolveFunctionSig(
  aliasTargets: in Map[String, TypeExpr], outerGenerics: in List[String], sig: in FunctionSig
): FunctionSig {
  val sigScope = unionNames(outerGenerics, genericParamNamesOf(sig.generics))
  FunctionSig(
    docComments = sig.docComments,
    isAsync = sig.isAsync,
    name = sig.name,
    generics = sig.generics,
    params = resolveParams(aliasTargets, sigScope, sig.params),
    ret = resolveOptType(aliasTargets, sigScope, sig.ret),
    whereClause = sig.whereClause,
    contracts = resolveContracts(aliasTargets, sigScope, sig.contracts),
    span = sig.span
  )
}

func resolveRecordDecl(aliasTargets: in Map[String, TypeExpr], d: in RecordDecl): RecordDecl {
  val ownGenerics = genericParamNamesOf(d.generics)
  val ms: List[RecordMember] = newList()
  var i = 0
  while i < d.members.count {
    ms.add(
      match d.members[i] {
        case RMField(field) -> RMField(field = resolveFieldDecl(aliasTargets, ownGenerics, field))
        case RMInvariant(inv) -> RMInvariant(inv = inv)
        case RMFunc(fn) -> RMFunc(fn = resolveFunctionDecl(aliasTargets, ownGenerics, fn))
      }
    )
    i = i + 1
  }
  RecordDecl(name = d.name, generics = d.generics, whereClause = d.whereClause, members = ms, span = d.span)
}

func resolveUnionField(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], f: in UnionField
): UnionField {
  match f {
    case UFNamed(name, ty, span) -> UFNamed(name = name, ty = resolveTypeExpr(aliasTargets, genericNames, ty), span = span)
    case UFPos(ty, span) -> UFPos(ty = resolveTypeExpr(aliasTargets, genericNames, ty), span = span)
  }
}

func resolveUnionDecl(aliasTargets: in Map[String, TypeExpr], d: in UnionDecl): UnionDecl {
  val ownGenerics = genericParamNamesOf(d.generics)
  val cs: List[UnionCase] = newList()
  var i = 0
  while i < d.cases.count {
    val c = d.cases[i]
    val fs: List[UnionField] = newList()
    var j = 0
    while j < c.fields.count {
      fs.add(resolveUnionField(aliasTargets, ownGenerics, c.fields[j]))
      j = j + 1
    }
    cs.add(UnionCase(docComments = c.docComments, annotations = c.annotations, name = c.name, fields = fs, span = c.span))
    i = i + 1
  }
  UnionDecl(name = d.name, generics = d.generics, whereClause = d.whereClause, cases = cs, span = d.span)
}

func resolveOpaqueTypeDecl(aliasTargets: in Map[String, TypeExpr], d: in OpaqueTypeDecl): OpaqueTypeDecl {
  val ownGenerics = genericParamNamesOf(d.generics)
  val ms: List[OpaqueMember] = newList()
  var i = 0
  while i < d.members.count {
    ms.add(
      match d.members[i] {
        case OMField(field) -> OMField(field = resolveFieldDecl(aliasTargets, ownGenerics, field))
        case OMInvariant(inv) -> OMInvariant(inv = inv)
      }
    )
    i = i + 1
  }
  OpaqueTypeDecl(
    name = d.name,
    generics = d.generics,
    whereClause = d.whereClause,
    annotations = d.annotations,
    members = ms,
    hasBody = d.hasBody,
    span = d.span
  )
}

func resolveProtectedField(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], pf: in ProtectedField
): ProtectedField {
  match pf {
    case PFVar(name, ty, init, docComments, annotations, span) -> {
      val ni = match init { case Some(e) -> Some(value = resolveExpr(aliasTargets, genericNames, e)); case None -> init }
      PFVar(
        name = name,
        ty = resolveTypeExpr(aliasTargets, genericNames, ty),
        init = ni,
        docComments = docComments,
        annotations = annotations,
        span = span
      )
    }
    case PFLet(name, ty, init, docComments, annotations, span) -> {
      val ni = match init { case Some(e) -> Some(value = resolveExpr(aliasTargets, genericNames, e)); case None -> init }
      PFLet(
        name = name,
        ty = resolveTypeExpr(aliasTargets, genericNames, ty),
        init = ni,
        docComments = docComments,
        annotations = annotations,
        span = span
      )
    }
    case PFImmutable(field) -> PFImmutable(field = resolveFieldDecl(aliasTargets, genericNames, field))
  }
}

func resolveProtectedTypeDecl(aliasTargets: in Map[String, TypeExpr], d: in ProtectedTypeDecl): ProtectedTypeDecl {
  val ownGenerics = genericParamNamesOf(d.generics)
  val ms: List[ProtectedMember] = newList()
  var i = 0
  while i < d.members.count {
    ms.add(
      match d.members[i] {
        case PMField(field) -> PMField(field = resolveProtectedField(aliasTargets, ownGenerics, field))
        case PMInvariant(inv) -> PMInvariant(inv = inv)
        case PMEntry(entryDecl) -> PMEntry(entryDecl = resolveEntryDecl(aliasTargets, ownGenerics, entryDecl))
        case PMFunc(fn) -> PMFunc(fn = resolveFunctionDecl(aliasTargets, ownGenerics, fn))
      }
    )
    i = i + 1
  }
  ProtectedTypeDecl(name = d.name, generics = d.generics, whereClause = d.whereClause, members = ms, span = d.span)
}

func resolveInterfaceDecl(aliasTargets: in Map[String, TypeExpr], d: in InterfaceDecl): InterfaceDecl {
  val ownGenerics = genericParamNamesOf(d.generics)
  val ms: List[InterfaceMember] = newList()
  var i = 0
  while i < d.members.count {
    ms.add(
      match d.members[i] {
        case IMSig(sig) -> IMSig(sig = resolveFunctionSig(aliasTargets, ownGenerics, sig))
        case IMFunc(fn) -> IMFunc(fn = resolveFunctionDecl(aliasTargets, ownGenerics, fn))
        case IMAssoc(assoc) -> IMAssoc(assoc = AssociatedTypeDecl(name = assoc.name, dflt = resolveOptType(aliasTargets, ownGenerics, assoc.dflt), span = assoc.span))
      }
    )
    i = i + 1
  }
  InterfaceDecl(name = d.name, generics = d.generics, whereClause = d.whereClause, members = ms, span = d.span)
}

// Resolve a `ConstraintRef` (an interface reference: `impl <iface> for ...`,
// where-clause bounds). Its `head` is a bare `ModulePath`, not a `TypeExpr`,
// so — exactly like `TGenericApp`'s head substitution — a single-segment
// alias head substitutes only when the alias chain bottoms out in a plain
// `TRef`; any other resolved shape can't be expressed as a `ModulePath` and
// is left unresolved. Type/value args resolve like any other `TypeArg`.
func resolveConstraintRef(
  aliasTargets: in Map[String, TypeExpr], genericNames: in List[String], c: in ConstraintRef
): ConstraintRef {
  val args2: List[TypeArg] = newList()
  var i = 0
  while i < c.args.count {
    args2.add(resolveTypeArg(aliasTargets, genericNames, c.args[i]))
    i = i + 1
  }
  val head2 = if c.head.segments.count == 1 and not listContainsStr(genericNames, c.head.segments[0]) {
    match mapGet(aliasTargets, c.head.segments[0]) {
      case Some(rhs) -> {
        match resolveTypeExpr(aliasTargets, genericNames, rhs).kind {
          case TRef(rp) -> rp
          case _ -> c.head
        }
      }
      case None -> c.head
    }
  } else {
    c.head
  }
  ConstraintRef(head = head2, args = args2, span = c.span)
}

// `ImplDecl.target` (the concrete type an `impl <iface> for <target>` block
// implements for) and `ImplDecl.iface` both reach backend naming directly
// WITHOUT the MSIL `cctx.aliasTargets` layer (`implTargetNameMsil` and JVM's
// `typeExprToJvmClass` pattern-match the raw AST), so an alias in either
// header position must resolve here or it miscompiles on both targets
// (#6414: silent wrong-name emission on MSIL, `NoClassDefFoundError` on JVM).
func resolveImplDecl(aliasTargets: in Map[String, TypeExpr], d: in ImplDecl): ImplDecl {
  val ownGenerics = genericParamNamesOf(d.generics)
  val ms: List[ImplMember] = newList()
  var i = 0
  while i < d.members.count {
    ms.add(
      match d.members[i] {
        case IMplFunc(fn) -> IMplFunc(fn = resolveFunctionDecl(aliasTargets, ownGenerics, fn))
        case IMplAssoc(assoc) -> IMplAssoc(assoc = AssociatedTypeDecl(name = assoc.name, dflt = resolveOptType(aliasTargets, ownGenerics, assoc.dflt), span = assoc.span))
      }
    )
    i = i + 1
  }
  ImplDecl(
    generics = d.generics,
    iface = resolveConstraintRef(aliasTargets, ownGenerics, d.iface),
    target = resolveTypeExpr(aliasTargets, ownGenerics, d.target),
    whereClause = d.whereClause,
    members = ms,
    span = d.span
  )
}

func resolveWireMember(aliasTargets: in Map[String, TypeExpr], m: in WireMember): WireMember {
  val noGenerics: List[String] = newList()
  match m {
    case WMProvided(name, ty, span) -> WMProvided(name = name, ty = resolveTypeExpr(aliasTargets, noGenerics, ty), span = span)
    case WMSingleton(name, ty, init, span) -> WMSingleton(name = name, ty = resolveTypeExpr(aliasTargets, noGenerics, ty), init = resolveExpr(aliasTargets, noGenerics, init), span = span)
    case WMScoped(scopeName, name, ty, init, span) -> WMScoped(scopeName = scopeName, name = name, ty = resolveTypeExpr(aliasTargets, noGenerics, ty), init = resolveExpr(aliasTargets, noGenerics, init), span = span)
    case WMBind(iface, provider, span) -> WMBind(iface = resolveTypeExpr(aliasTargets, noGenerics, iface), provider = resolveExpr(aliasTargets, noGenerics, provider), span = span)
    case WMExpose(name, span) -> WMExpose(name = name, span = span)
    case WMLocal(name, ty, init, span) -> WMLocal(name = name, ty = resolveOptType(aliasTargets, noGenerics, ty), init = resolveExpr(aliasTargets, noGenerics, init), span = span)
    case WMContributes(iface, name, init, ordering, isSealed, span) -> WMContributes(iface = resolveTypeExpr(aliasTargets, noGenerics, iface), name = name, init = resolveExpr(aliasTargets, noGenerics, init), ordering = ordering, isSealed = isSealed, span = span)
    case WMInclude(path, aliasName, adjustments, hasBody, span) -> WMInclude(path = path, aliasName = aliasName, adjustments = resolveIncludeAdjusts(aliasTargets, adjustments), hasBody = hasBody, span = span)
    case WMOverridable(names, span) -> WMOverridable(names = names, span = span)
    case WMConfigInst(decl, span) -> WMConfigInst(decl = resolveConfigDecl(aliasTargets, decl), span = span)
  }
}

func resolveIncludeAdjusts(aliasTargets: in Map[String, TypeExpr], xs: in List[IncludeAdjust]): List[IncludeAdjust] {
  val noGenerics: List[String] = newList()
  val ys: List[IncludeAdjust] = newList()
  var i = 0
  while i < xs.count {
    match xs[i] {
      case IAProvided(name, value, span) -> ys.add(IAProvided(name = name, value = resolveExpr(aliasTargets, noGenerics, value), span = span))
      case IAConfigOverride(name, fields, span) -> {
        val fs: List[ConfigFieldOverride] = newList()
        var j = 0
        while j < fields.count {
          fs.add(
            ConfigFieldOverride(
              name = fields[j].name,
              value = resolveExpr(aliasTargets, noGenerics, fields[j].value),
              span = fields[j].span
            )
          )
          j = j + 1
        }
        ys.add(IAConfigOverride(name = name, fields = fs, span = span))
      }
      case IAReplace(name, value, span) -> ys.add(IAReplace(name = name, value = resolveExpr(aliasTargets, noGenerics, value), span = span))
      case IARemove(name, span) -> ys.add(IARemove(name = name, span = span))
      case IAReorder(name, ordering, span) -> ys.add(IAReorder(name = name, ordering = ordering, span = span))
    }
    i = i + 1
  }
  ys
}

func resolveWireDecl(aliasTargets: in Map[String, TypeExpr], d: in WireDecl): WireDecl {
  val noGenerics: List[String] = newList()
  val ms: List[WireMember] = newList()
  var i = 0
  while i < d.members.count {
    ms.add(resolveWireMember(aliasTargets, d.members[i]))
    i = i + 1
  }
  WireDecl(name = d.name, params = resolveParams(aliasTargets, noGenerics, d.params), members = ms, span = d.span)
}

func resolveConfigField(aliasTargets: in Map[String, TypeExpr], f: in ConfigField): ConfigField {
  val noGenerics: List[String] = newList()
  val d = match f.default {
    case Some(e) -> Some(value = resolveExpr(aliasTargets, noGenerics, e))
    case None -> f.default
  }
  ConfigField(
    docComments = f.docComments,
    annotations = f.annotations,
    name = f.name,
    ty = resolveTypeExpr(aliasTargets, noGenerics, f.ty),
    default = d,
    span = f.span
  )
}

func resolveConfigDecl(aliasTargets: in Map[String, TypeExpr], d: in ConfigDecl): ConfigDecl {
  val fs: List[ConfigField] = newList()
  var i = 0
  while i < d.fields.count {
    fs.add(resolveConfigField(aliasTargets, d.fields[i]))
    i = i + 1
  }
  ConfigDecl(name = d.name, from = d.from, fields = fs, span = d.span)
}

func resolveTestDecl(aliasTargets: in Map[String, TypeExpr], d: in TestDecl): TestDecl {
  val noGenerics: List[String] = newList()
  TestDecl(title = d.title, body = resolveBlock(aliasTargets, noGenerics, d.body), span = d.span)
}

func resolvePropertyDecl(aliasTargets: in Map[String, TypeExpr], d: in PropertyDecl): PropertyDecl {
  val noGenerics: List[String] = newList()
  val bs: List[PropertyBinder] = newList()
  var i = 0
  while i < d.forAll.count {
    val pb = d.forAll[i]
    bs.add(PropertyBinder(name = pb.name, ty = resolveTypeExpr(aliasTargets, noGenerics, pb.ty), span = pb.span))
    i = i + 1
  }
  val g = match d.guardExpr {
    case Some(e) -> Some(value = resolveExpr(aliasTargets, noGenerics, e))
    case None -> d.guardExpr
  }
  PropertyDecl(
    title = d.title,
    forAll = bs,
    guardExpr = g,
    body = resolveBlock(aliasTargets, noGenerics, d.body),
    span = d.span
  )
}

func resolveFixtureDecl(aliasTargets: in Map[String, TypeExpr], d: in FixtureDecl): FixtureDecl {
  val noGenerics: List[String] = newList()
  FixtureDecl(
    name = d.name,
    nameSpan = d.nameSpan,
    ty = resolveOptType(aliasTargets, noGenerics, d.ty),
    init = resolveExpr(aliasTargets, noGenerics, d.init),
    span = d.span
  )
}

// Resolve one `Item`. `ITypeAlias` declarations pass through unchanged (the
// alias table is derived from them; rewriting their rhs is pointless churn),
// as do `extern`-boundary items (`IExtern`/`IExternType`/`IExternFunc`) and
// `IAspect` bodies — see the module doc's scope note. `IDistinctType` keeps
// its own NAME nominal (a distinct type is never resolved away) but its
// UNDERLYING representation type must resolve like any other annotation —
// `type Distance = Meters` where `Meters` is an alias otherwise reaches
// codegen unresolved and emits a nonexistent class on JVM (#6412).
pub func resolveItem(aliasTargets: in Map[String, TypeExpr], it: in Item): Item {
  val noGenerics: List[String] = newList()
  val k = match it.kind {
    case IConst(decl) -> IConst(decl = ConstDecl(name = decl.name, ty = resolveTypeExpr(aliasTargets, noGenerics, decl.ty), init = resolveExpr(aliasTargets, noGenerics, decl.init), span = decl.span))
    case IVal(decl) -> IVal(decl = ValDecl(pattern = resolvePattern(aliasTargets, noGenerics, decl.pattern), ty = resolveOptType(aliasTargets, noGenerics, decl.ty), init = resolveExpr(aliasTargets, noGenerics, decl.init), span = decl.span))
    case IFunc(decl) -> IFunc(decl = resolveFunctionDecl(aliasTargets, noGenerics, decl))
    case ITypeAlias(decl) -> ITypeAlias(decl = decl)
    case IDistinctType(decl) -> IDistinctType(decl = DistinctTypeDecl(name = decl.name, generics = decl.generics, underlying = resolveTypeExpr(aliasTargets, genericParamNamesOf(decl.generics), decl.underlying), rangeClause = decl.rangeClause, derives = decl.derives, span = decl.span))
    case IRecord(decl) -> IRecord(decl = resolveRecordDecl(aliasTargets, decl))
    case IExposedRec(decl) -> IExposedRec(decl = resolveRecordDecl(aliasTargets, decl))
    case IUnion(decl) -> IUnion(decl = resolveUnionDecl(aliasTargets, decl))
    case IEnum(decl) -> IEnum(decl = decl)
    case IOpaque(decl) -> IOpaque(decl = resolveOpaqueTypeDecl(aliasTargets, decl))
    case IProtected(decl) -> IProtected(decl = resolveProtectedTypeDecl(aliasTargets, decl))
    case IInterface(decl) -> IInterface(decl = resolveInterfaceDecl(aliasTargets, decl))
    case IImpl(decl) -> IImpl(decl = resolveImplDecl(aliasTargets, decl))
    case IWire(decl) -> IWire(decl = resolveWireDecl(aliasTargets, decl))
    case IScopeKind(decl) -> IScopeKind(decl = decl)
    case IExtern(decl) -> IExtern(decl = decl)
    case IExternType(decl) -> IExternType(decl = decl)
    case IExternFunc(decl) -> IExternFunc(decl = decl)
    case ITest(decl) -> ITest(decl = resolveTestDecl(aliasTargets, decl))
    case IProperty(decl) -> IProperty(decl = resolvePropertyDecl(aliasTargets, decl))
    case IFixture(decl) -> IFixture(decl = resolveFixtureDecl(aliasTargets, decl))
    case IConfig(decl) -> IConfig(decl = resolveConfigDecl(aliasTargets, decl))
    case IAspect(decl) -> IAspect(decl = decl)
    case IError -> IError
  }
  Item(docComments = it.docComments, annotations = it.annotations, visibility = it.visibility, kind = k, span = it.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Public entry points.
// ─────────────────────────────────────────────────────────────────────────────
// Resolve every `alias` reference in `file` against `aliasTargets` (built by
// `Lyric.BareFuncRef.collectFuncAliasTargets` — which sees the whole package,
// since docs/19 multi-file packages are concatenated before parsing; axis 3
// of #6404).
pub func resolveAliasesInFile(aliasTargets: in Map[String, TypeExpr], file: in SourceFile): SourceFile {
  val items: List[Item] = newList()
  var i = 0
  while i < file.items.count {
    items.add(resolveItem(aliasTargets, file.items[i]))
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
