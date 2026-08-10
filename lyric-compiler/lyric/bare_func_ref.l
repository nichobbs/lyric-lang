//! lyric/bare_func_ref.l — Lyric.BareFuncRef: shared, target-independent
//! helpers for "first-class function value" support (#6389/#6393).
//!
//! Two concerns, both pure `SourceFile`/`TypeExpr` -> data transforms with
//! zero backend-specific content, factored out so the MSIL and JVM backends
//! don't carry two copies of the same predicate:
//!
//!   1. Eligibility: which same-package top-level functions may be
//!      referenced bare (`apply(double, 21)`) as a first-class value at all.
//!      A function is eligible when it has a body, is non-generic,
//!      non-async, not `@externTarget`-annotated (that path bridges to a
//!      real BCL/JDK delegate/functional-interface signature by other
//!      means — docs/50/D122/#1622 — and mixing the two would be wrong),
//!      and every parameter is plain `in`-mode (an `out`/`inout` parameter
//!      has no meaning as an ordinary delegate/closure argument).  MSIL's
//!      `synthesizeBareFuncRefThunksMsil` (msil/codegen.l, #5362/D-progress-738)
//!      and JVM's inline-closure fallback (jvm/codegen/02_exprs.l, #6393)
//!      both need exactly this predicate, applied at different points in
//!      two structurally different codegen strategies (MSIL pre-synthesizes
//!      a top-level forwarding-thunk `IFunc` per eligible+referenced name
//!      before lambda-lifting so the uniform boxed-ABI MethodDef pre-scan
//!      sees it; JVM has no such pre-scan — closures are synthesized
//!      on-demand at the point of use — so it looks the predicate up once
//!      per file, at signature-collection time, and builds the forwarding
//!      closure inline the first time a given name is actually read as a
//!      bare value).  The two *drivers* are backend-specific and stay in
//!      their own files; only the predicate is shared.
//!
//!   2. Alias-to-function-type resolution: `alias Handler = (Int) -> Int`
//!      used as a type annotation (`h: in Handler`, `: Handler` return,
//!      `f: Handler` record field, `val f: Handler = ...`) must resolve
//!      exactly like the literal `(Int) -> Int` annotation already does —
//!      not as a same-package class named `Handler` (#5366's MSIL half;
//!      #6393's JVM half, "NoClassDefFoundError: Repro/Handler").
//!      `resolveFuncTypeAlias` follows a `TRef` through an alias chain
//!      (`cctx.aliasTargets`-shaped, but expressed as a plain
//!      `Map[String, TypeExpr]` so it has no MSIL/JVM context dependency)
//!      down to an underlying literal `TFunction` shape; `None` for any
//!      other shape, or for a chain that never bottoms out in `TFunction`
//!      (the type checker already rejects cyclic aliases, so this always
//!      terminates).  `collectFuncAliasTargets` builds that map from a
//!      single file's own `alias X = ...` declarations — same-file only
//!      (a cross-package function-type alias is a follow-up; MSIL's
//!      `cctx.aliasTargets` happens to see earlier-processed sibling
//!      packages too, purely as a side effect of one `CodegenCtx` being
//!      reused across a whole project build — JVM's per-file callers below
//!      don't have an equivalent shared context to piggyback on).
package Lyric.BareFuncRef

import Std.Core
import Std.Collections
import Lyric.Parser

// True iff `anns` contains `@externTarget(...)`.
func hasExternTargetAnn(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "externTarget" {
      return true
    }
    i = i + 1
  }
  false
}

// True iff every parameter is plain `in`-mode.
func allParamsInMode(params: in List[Param]): Bool {
  var i = 0
  while i < params.count {
    match params[i].mode {
      case PMIn -> {
      }
      case _ -> return false
    }
    i = i + 1
  }
  true
}

/// True iff `decl` may be referenced bare as a first-class function value:
/// has a body, non-generic, non-async, not `@externTarget`, every param
/// `in`-mode.  See the module doc for the full rationale.
pub func isEligibleBareFuncRefTarget(decl: in FunctionDecl): Bool {
  val hasBody = match decl.body { case Some(_) -> true; case None -> false }
  val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
  hasBody and not isGeneric and not decl.isAsync and not hasExternTargetAnn(decl.annotations) and
    allParamsInMode(decl.params)
}

/// Every same-package top-level function in `file` eligible per
/// `isEligibleBareFuncRefTarget`, keyed by bare name (first-wins on a
/// same-name overload, mirroring the token/signature tables' own bare-key
/// convention elsewhere).
pub func eligibleBareFuncRefTargets(file: in SourceFile): Map[String, FunctionDecl] {
  val eligible: Map[String, FunctionDecl] = newMap()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        if isEligibleBareFuncRefTarget(decl) and not eligible.containsKey(decl.name) {
          eligible.add(decl.name, decl)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  eligible
}

func lastSegmentOfPath(path: in ModulePath): String {
  path.segments[path.segments.count - 1]
}

/// Follow a `TFunction` OR a chain of `alias X = ...` (`aliasTargets`) down
/// to an underlying literal `TFunction` shape.  See the module doc (§2).
pub func resolveFuncTypeAlias(aliasTargets: in Map[String, TypeExpr], te: in TypeExpr): Option[TypeExpr] {
  match te.kind {
    case TFunction(_, _) -> Some(value = te)
    case TRef(path) -> {
      val seg = lastSegmentOfPath(path)
      match mapGet(aliasTargets, seg) {
        case Some(rhs) -> resolveFuncTypeAlias(aliasTargets, rhs)
        case None -> None
      }
    }
    case _ -> None
  }
}

/// Build the `alias X = RHS` table for a single file (simple name -> RHS,
/// first-wins).  Skips a re-export whose RHS names a type with the same
/// simple name (the stdlib's `pub alias Random = <extern Random>` pattern):
/// registering it would recurse on the same name forever in
/// `resolveFuncTypeAlias`; leaving it unregistered routes the name through
/// the normal (non-alias) erasure path, exactly as before this resolution
/// existed. Mirrors `Msil.Codegen.registerTypeAliasMsil`'s self-reference
/// guard, minus its cross-package qualified-name registration (see module
/// doc §2 for why that half is out of scope here).
pub func collectFuncAliasTargets(file: in SourceFile): Map[String, TypeExpr] {
  val aliasTargets: Map[String, TypeExpr] = newMap()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case ITypeAlias(decl) -> {
        val rhsSelfNamed = match decl.rhs.kind { case TRef(path) -> lastSegmentOfPath(path) == decl.name; case _ -> false }
        if not rhsSelfNamed and not aliasTargets.containsKey(decl.name) {
          aliasTargets.add(decl.name, decl.rhs)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  aliasTargets
}

/// `resolveFuncTypeAlias`, defaulting to `te` itself when no alias-to-
/// function resolution applies (te is already a literal `TFunction`, or is
/// some unrelated shape, or is an alias chain that never bottoms out in a
/// `TFunction`).  The common call-site shape at every registration/erasure
/// site that only cares "give me the best TypeExpr to erase from" rather
/// than "tell me whether this was function-shaped".
pub func resolveFuncTypeAliasOrSelf(aliasTargets: in Map[String, TypeExpr], te: in TypeExpr): TypeExpr {
  match resolveFuncTypeAlias(aliasTargets, te) {
    case Some(resolved) -> resolved
    case None -> te
  }
}
