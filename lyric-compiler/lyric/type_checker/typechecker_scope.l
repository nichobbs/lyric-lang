//! typechecker_scope.l — lexical scope and generic-context stacks.
//! Mirrors compiler/src/Lyric.TypeChecker/Scope.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer

// ─────────────────────────────────────────────────────────────────────────────
// §1. Local binding — a single val/var/let or parameter in scope.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record LocalBinding {
  name: String
  ty: Type
  isMutable: Bool
  // ─────────────────────────────────────────────────────────────────────────────
  // §2. Scope — stack of lexical frames (flat list + watermark indices).
  // ─────────────────────────────────────────────────────────────────────────────
  // `returnTy` / `genericNames` carry the enclosing function's declared return
  // type and type-parameter names so that value-position blocks and branch
  // expressions (`EBlock`/`EUnsafe`/`EIf`/`EMatch`/`EResult`) can be typed inside
  // `inferExpr` without re-threading them through every call site (D081).  They
  // are Scope-level (set once at function entry, untouched by frame push/pop), so
  // a nested block sees the same enclosing context.
}

@stable(since = "0.1")
pub record Scope {
  bindings: List[LocalBinding]
  frameStarts: List[Int]
  returnTy: Type
  genericNames: List[String]
  // #6467: the ORIGINAL (pre-erasure) return-type annotation `TypeExpr` that
  // `returnTy` was resolved from, when one exists — carries `aliasName` when
  // the user wrote an alias here (mirrors `fn.ret`, D-progress-765).
  // `renderTypeExpr` pairs it with `returnTy` to render `Meters (aka Long)`
  // instead of the bare underlying name.  `None` outside a function body, or
  // for a synthetic `TyError`/lambda-body context that has no source annotation.
  returnTyExpr: Option[TypeExpr]
  // A scope with no enclosing-function context — `returnTy` defaults to `TyError`
  // (the universal unifier, so a stray `EResult`/block read stays lenient) and no
  // generic names.  Used by callers that type expressions outside a function body.
  // #6485: the enclosing member's own field names, resolved to their declared
  // `Type`s — lets `self.field` (the `ESelf` receiver spelling) resolve the
  // same way the bare-name spelling already does via `checkFunctionBody`'s
  // `extraLocals` (protected members only; record/impl methods have no
  // bare-name spelling — `self.field` is their only spelling, #6487). Empty
  // for every non-member scope.
  selfFields: Map[String, Type]
  // #6487: true exactly when this scope belongs to a checked MEMBER body
  // (protected entry/func, record-body method, impl method) — independent of
  // `selfFields.count`, so a zero-field member's `self.x` still resolves
  // through the "is this a checked member context" branch and reports a
  // genuine T0020 instead of silently falling through to the lenient `TySelf`
  // handling that non-member `self`-bearing contexts (interface default
  // methods, a `Self`-typed ordinary parameter) still get. `false` for every
  // scope outside these three member-body callers.
  selfChecked: Bool
  // #6487 review: the enclosing member's own nominal type — `TyError` unless
  // this scope belongs to a record-body or impl method whose self type is a
  // real record (never seeded for protected members, matching the #6483
  // bare-sibling-dispatch gap those deliberately still carry). Lets a BARE
  // sibling-method call with no receiver at all (`dup()` inside another
  // method of the same record/impl, #1722/#6435 — codegen's `ctx.selfClass`
  // general-static-call fallback on both backends) resolve against this
  // type's method-signature space instead of raising a false T0020, exactly
  // as an explicit `self.dup()` call already would.
  selfType: Type
}

pub func newScope(): Scope {
  val bindings: List[LocalBinding] = newList()
  val starts: List[Int] = newList()
  starts.add(0)
  val noReturnTyExpr: Option[TypeExpr] = None
  val noSelfFields: Map[String, Type] = newMap()
  Scope(
    bindings = bindings,
    frameStarts = starts,
    returnTy = TyError,
    genericNames = newList(),
    returnTyExpr = noReturnTyExpr,
    selfFields = noSelfFields,
    selfChecked = false,
    selfType = TyError
  )
}

// A scope seeded with the enclosing function's return type and generic-parameter
// names, used by `checkFunctionBody` so value-position blocks/branches inside
// the body type against the real return context.  `returnTyExpr` is the
// original declared-return-type `TypeExpr` (`fn.ret`) when the caller has one,
// so alias-aware diagnostics (T0064/T0065 and friends) can render the alias
// name the user wrote instead of the bare resolved type (#6467).  `selfFields`
// is the enclosing member's field-name-to-type map (#6485/#6487, empty for
// every non-member caller); `selfChecked` (#6487) is set independently of
// `selfFields.count` so a zero-field member still gets strict `self.<name>`
// resolution.
pub func newScopeForFunction(
  returnTy: in Type,
  genericNames: in List[String],
  returnTyExpr: in Option[TypeExpr],
  selfFields: in Map[String, Type],
  selfChecked: in Bool,
  selfType: in Type,
): Scope {
  val bindings: List[LocalBinding] = newList()
  val starts: List[Int] = newList()
  starts.add(0)
  Scope(
    bindings = bindings,
    frameStarts = starts,
    returnTy = returnTy,
    genericNames = genericNames,
    returnTyExpr = returnTyExpr,
    selfFields = selfFields,
    selfChecked = selfChecked,
    selfType = selfType
  )
}

pub func scopePush(sc: in Scope): Unit {
  sc.frameStarts.add(sc.bindings.count)
}

pub func scopePop(sc: in Scope): Unit {
  val n = sc.frameStarts.count
  if n > 1 {
    val start = sc.frameStarts[n - 1]
    val toRemove = sc.bindings.count - start
    var j = 0
    while j < toRemove {
      sc.bindings.removeAt(sc.bindings.count - 1)
      j = j + 1
    }
    sc.frameStarts.removeAt(n - 1)
  }
}

pub func scopeAdd(sc: in Scope, b: in LocalBinding): Unit {
  sc.bindings.add(b)
}

pub func scopeTryFind(sc: in Scope, name: in String): Option[LocalBinding] {
  var i = sc.bindings.count - 1
  while i >= 0 {
    if sc.bindings[i].name == name {
      return Some(value = sc.bindings[i])
    }
    i = i - 1
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. GenericContext — type-parameter names currently in scope.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record GenericContext {
  params: List[String]
  stackDepths: List[Int]
}

pub func newGenericContext(): GenericContext {
  val params: List[String] = newList()
  val depths: List[Int] = newList()
  GenericContext(params = params, stackDepths = depths)
}

pub func gctxPush(ctx: in GenericContext, names: in List[String]): Unit {
  ctx.stackDepths.add(ctx.params.count)
  var i = 0
  while i < names.count {
    ctx.params.add(names[i])
    i = i + 1
  }
}

pub func gctxPop(ctx: in GenericContext): Unit {
  val n = ctx.stackDepths.count
  if n > 0 {
    val start = ctx.stackDepths[n - 1]
    val toRemove = ctx.params.count - start
    var j = 0
    while j < toRemove {
      ctx.params.removeAt(ctx.params.count - 1)
      j = j + 1
    }
    ctx.stackDepths.removeAt(n - 1)
  }
}

pub func gctxIsTypeParam(ctx: in GenericContext, name: in String): Bool {
  var i = 0
  while i < ctx.params.count {
    if ctx.params[i] == name {
      return true
    }
    i = i + 1
  }
  false
}
