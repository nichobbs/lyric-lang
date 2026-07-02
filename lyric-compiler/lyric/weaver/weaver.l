//! weaver.l — Lyric.Weaver
//!
//! Self-hosted port of bootstrap/src/Lyric.Emitter/Weaver.fs (A1/A2/A3/A4).
//! Transforms a SourceFile's item list before downstream stages:
//!
//!   1. Collects every IAspect item with an `around` body.
//!   2. Matches each IFunc against the aspect's `matches:` predicates,
//!      respecting `@no_aspect` and `@no_aspect("Name")` opt-outs.
//!   3. For each matched function, renames the original to
//!      `<name>__aspect_target`, sorts the matching aspects by `wraps:` /
//!      `inside:` clauses (lexical order as the tiebreak), and splices in
//!      a chain of wrapper IFuncs — innermost calls the renamed target,
//!      outermost keeps the original name. Wrapper contracts are the
//!      composed `aspect.contracts ++ original.contracts` per §5 of
//!      `docs/26-aspects.md`.
//!   4. IAspect items are dropped from the resulting item list.
//!
//! Feature wiring beyond F# parity (todo/06):
//!
//!   - `config { }` block values (#683): each `ConfigField` with a literal
//!     default is materialised as a synthetic `val __aspect_cfg_<name>`
//!     local at the top of the woven body; `config.<name>` member accesses
//!     in the aspect body are rewritten to that local.  Fields without a
//!     default are skipped (env-var resolution at startup is a follow-up).
//!
//!   - Ambient `call` value (#682): the woven body sees compile-time-known
//!     constants for `call.shortName`, `call.qualifiedName`,
//!     `call.modulePath`, `call.sourceLocation`, and `call.annotations`,
//!     materialised as `__lyric_call_<name>` locals.  `call.aspect` is
//!     also injected (the current aspect's name).  `call.elapsed`
//!     (#1298) is runtime-instrumented: the prelude materialises
//!     `var __lyric_call_elapsed: Option[Int] = None` and each
//!     `proceed(args)` rewrite captures `Std.Time.monotonicNanos()`
//!     around the target call, assigning `Some(ms)` after it returns —
//!     so a body that never reaches `proceed` observes `None`
//!     (docs/26 §4.3, Q-aspects-003).  `import Std.Time` is
//!     auto-injected (deduplicated) into the woven file when the
//!     instrumentation fires, following the `Lyric.Stubbable`
//!     auto-import precedent (D100).  `call.caller` is not available
//!     (caller-site capture is unimplemented; docs/26 §4.3); it — and
//!     any other unrecognised `call.<field>` — surfaces as an A0043
//!     diagnostic at weave time so users get a clear message instead
//!     of a downstream "undeclared call" type error.
//!
//!   - `@inline_template` (#681): aspects annotated `@inline_template`
//!     have `args.<field>` rewrites applied at weave time; each field
//!     name must match a parameter of the matched function (otherwise a
//!     diagnostic A0042 is emitted).  Non-template aspects continue to
//!     reject `args.<field>` references downstream — this matches the
//!     parity contract with the F# weaver.
//!
//!   - `from`-instance resolution (#3497): `weaveFileWithDiagsAndTemplates`
//!     resolves `from X { … }` aspects from the supplied template map.
//!     A0045 is emitted for every `from` reference whose template is not
//!     found, so a missing dependency causes a clear error rather than a
//!     silent no-op.
//!
//! Used by the verifier driver so `lyric prove` discharges contracts on
//! the woven body (not the parsed body). Closes #336.
//!
//! Glob syntax: `*`, `?`, `[abc]`, `[a-z]`; other chars literal.
package Lyric.Weaver

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Std.Char as Char
import Std.String as Str

// ─────────────────────────────────────────────────────────────────────────────
// §1. Glob matching (POSIX-ish subset).
// ─────────────────────────────────────────────────────────────────────────────
pub func globMatch(glob: in String, name: in String): Bool {
  globMatchAt(glob, 0, name, 0)
}

func globMatchAt(glob: in String, gi: in Int, name: in String, ni: in Int): Bool {
  if gi == glob.length and ni == name.length {
    return true
  }
  if gi == glob.length {
    return false
  }
  val g = glob[gi]
  if g == '*' {
    var k = ni
    while k <= name.length {
      if globMatchAt(glob, gi + 1, name, k) {
        return true
      }
      k = k + 1
    }
    return false
  }
  if g == '?' {
    if ni >= name.length {
      return false
    }
    return globMatchAt(glob, gi + 1, name, ni + 1)
  }
  if g == '[' {
    var j = gi + 1
    var found = false
    var closed = false
    while j < glob.length and not closed {
      val c = glob[j]
      if c == ']' {
        closed = true
      } else if j + 2 < glob.length and glob[j + 1] == '-' and glob[j + 2] != ']' {
        if ni < name.length {
          val nc = name[ni]
          val ncI = Char.toInt(nc)
          if ncI >= Char.toInt(c) and ncI <= Char.toInt(glob[j + 2]) {
            found = true
          }
        }
        j = j + 3
      } else {
        if ni < name.length and c == name[ni] {
          found = true
        }
        j = j + 1
      }
    }
    if found and closed {
      return globMatchAt(glob, j + 1, name, ni + 1)
    }
    return false
  }
  if ni >= name.length {
    return false
  }
  if g != name[ni] {
    return false
  }
  globMatchAt(glob, gi + 1, name, ni + 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Synthetic AST nodes built at a zero span.
// ─────────────────────────────────────────────────────────────────────────────
func synSpan(): Span {
  makeSpan(initialPosition(), initialPosition())
}

func makePathExpr(segments: in List[String]): Expr {
  val sp = synSpan()
  val mp = ModulePath(segments = segments, span = sp)
  Expr(kind = EPath(path = mp), span = sp)
}

func singleSegPathExpr(name: in String): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  makePathExpr(segs)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Rewrite the aspect `around` body for one weave site.
//
//     The rewriter performs four orthogonal substitutions in a single
//     bottom-up pass, threading state through `RewriteCtx`:
//
//       proceed(args)        → callTargetName(p1, p2, ...)
//       config.<field>       → __aspect_cfg_<field>     (#683)
//       call.<field>         → __lyric_call_<field>     (#682)
//       args.<field>         → <field>                  (#681, @inline_template)
//
//     Mirrors Weaver.fs rewriteProceeds plus the todo/06 extensions.
// ─────────────────────────────────────────────────────────────────────────────
/// Per-weave-site rewrite state.  All four substitutions consult this
/// record; unused features are signalled by empty lists.
record RewriteCtx {
  /// Name of the renamed `__aspect_target` (or the next-inner wrapper)
  /// that `proceed(args)` substitutes to.
  targetName: String
  /// Parameter names of the matched function, forwarded as positional
  /// args by `proceed(args)`.
  paramNames: List[String]
  /// Config field names the weaver materialises into `__aspect_cfg_<n>`
  /// locals (#683).  `config.<n>` member accesses for any of these names
  /// are rewritten to `__aspect_cfg_<n>` paths regardless of whether the
  /// field carried a literal default — fields without a default are
  /// materialised with a `panic("...")` stub initializer so the body
  /// type-checks and codegen succeeds (compilation still fails because
  /// A0044 fires before any of that runs).
  configFields: Map[String, Bool]
  /// Subset of `configFields` whose prelude entry uses the panic stub
  /// because the field had no default in the `config { }` block.  Drives
  /// A0044 emission in `tryMemberRewrite` so the user sees a clear
  /// weaver-targeted message instead of a confusing downstream type
  /// error.
  configNoDefault: Map[String, Bool]
  /// Call-context field names that the weaver materialises into
  /// `__lyric_call_<n>` locals.  `call.<n>` for these names rewrites
  /// to the local; other `call.<n>` accesses pass through unchanged
  /// (the type checker will flag them) (#682).  When `elapsed` is
  /// present, `proceed(args)` additionally rewrites to the timed
  /// block form (see `proceedSubstitutionTimed`, #1298).
  callFields: Map[String, Bool]
  /// True when the matched function's declared return type is `Unit`
  /// (or absent).  The timed proceed substitution (#1298) uses this to
  /// skip binding the target's result into a local — a `Unit` value
  /// local would be meaningless and the void store trips codegen.
  targetReturnsUnit: Bool
  /// True when the matching aspect carries `@inline_template`.  In that
  /// mode `args.<n>` is rewritten to `<n>` (parameter name) when `<n>`
  /// is in `paramNames`; missing names accumulate as diagnostics in
  /// `weaveDiags` (#681).
  isInlineTemplate: Bool
  /// docs/56 / D115 — field names declared by the template's `where TArgs
  /// has { ... }` row clause.  `args.<n>` for one of these names rewrites to
  /// `__lyric_args.<n>` (a read on the per-template synthesised args
  /// record); other `args.<n>` accesses fall through to the existing
  /// `isInlineTemplate` handling (or, for a B'-mode template with no row
  /// clause at all, are left unrewritten so the type-checker's downstream
  /// "unknown name `args`" surfaces, per A0046).  Empty for local aspects
  /// and C-mode templates, which never populate this field.
  argsRowFields: Map[String, Bool]
  /// Short name of the aspect being woven (for diagnostic messages).
  aspectName: String
  /// Short name of the matched function (for diagnostic messages).
  funcName: String
  /// Accumulator for weave-time diagnostics:
  ///   - A0042 — `@inline_template` `args.<n>` does not match a
  ///             parameter of the matched function (#681).
  ///   - A0043 — `call.<n>` references an unknown context field
  ///             (e.g. `call.caller`, whose caller-site capture is
  ///             unimplemented; docs/26 §4.3).
  ///   - A0044 — `config.<n>` references a declared field that has
  ///             no default (env-var resolution is a follow-up; see
  ///             `docs/26 §8`).  Surfaced at weave time to replace
  ///             the confusing downstream "config not declared"
  ///             type error.
  ///   - A0047 — a row-constrained B'-mode `from`-instance's matched
  ///             function does not provide a field the template's
  ///             `where TArgs has { ... }` clause declares (docs/56 / D115).
  weaveDiags: List[WeaveDiagEntry]
}

/// Discriminator + payload for a weave-time diagnostic.  Three kinds
/// today; new kinds can be added without changing the rewriter's
/// signature.
union WeaveDiagKind {
  case WDArgsMismatch
  // A0042
  case WDCallUnknown
  // A0043
  case WDConfigNoDefault
  // A0044
  case WDArgsRowMismatch
  // A0047 (docs/56 / D115)
}

record WeaveDiagEntry {
  kind: WeaveDiagKind
  aspectName: String
  funcName: String
  fieldName: String
  span: Span
}

func newRewriteCtx(
  targetName: in String,
  paramNames: in List[String],
  configFields: in Map[String, Bool],
  configNoDefault: in Map[String, Bool],
  callFields: in Map[String, Bool],
  targetReturnsUnit: in Bool,
  isInlineTemplate: in Bool,
  argsRowFields: in Map[String, Bool],
  aspectName: in String,
  funcName: in String,
  weaveDiags: in List[WeaveDiagEntry],
): RewriteCtx {
  RewriteCtx(
    targetName = targetName,
    paramNames = paramNames,
    configFields = configFields,
    configNoDefault = configNoDefault,
    callFields = callFields,
    targetReturnsUnit = targetReturnsUnit,
    isInlineTemplate = isInlineTemplate,
    argsRowFields = argsRowFields,
    aspectName = aspectName,
    funcName = funcName,
    weaveDiags = weaveDiags
  )
}

/// True for a target-advancing call.  Two spellings are accepted:
///   - bare `proceed(...)` — the form the weaver self-tests use; and
///   - `call.proceed(...)` — the form every shipped library aspect
///     template uses (`ValidateInput`, `CallLogging`, `RequiresAuth`,
///     `Retry`, …).  Here `call` is the ambient call value (docs/26
///     §4.3); `.proceed()` advances to the target exactly like the bare
///     form.  Without this arm the member access `call.proceed` falls
///     into `tryMemberRewrite`'s `call.<field>` path and raises a
///     spurious A0043, so library templates never weave.
/// The proceed call's own argument list is ignored either way — the
/// substitution forwards the wrapper's own parameters (F#-weaver parity).
func isProceedCall(expr: in Expr): Bool {
  match expr.kind {
    case ECall(f, _) -> {
      match f.kind {
        case EPath(path) -> path.segments.count == 1 and path.segments[0] == "proceed"
        case EMember(recv, member) -> {
          if member == "proceed" {
            match recv.kind {
              case EPath(p) -> p.segments.count == 1 and p.segments[0] == "call"
              case _ -> false
            }
          } else {
            false
          }
        }
        case _ -> false
      }
    }
    case _ -> false
  }
}

func proceedSubstitution(targetName: in String, paramNames: in List[String]): Expr {
  val argExprs: List[CallArg] = newList()
  var i = 0
  while i < paramNames.count {
    argExprs.add(CAPositional(expr = singleSegPathExpr(paramNames[i])))
    i = i + 1
  }
  Expr(kind = ECall(fn = singleSegPathExpr(targetName), args = argExprs), span = synSpan())
}

/// `<name>()` no-arg call at a zero span.
func mkCallNoArgs(name: in String): Expr {
  val noArgs: List[CallArg] = newList()
  Expr(kind = ECall(fn = singleSegPathExpr(name), args = noArgs), span = synSpan())
}

/// `Some(value = <e>)` call at a zero span.
func mkSomeCall(e: in Expr): Expr {
  val args: List[CallArg] = newList()
  args.add(CANamed(name = "value", value = e, span = synSpan()))
  Expr(kind = ECall(fn = singleSegPathExpr("Some"), args = args), span = synSpan())
}

/// `((monotonicNanos() - __lyric_call_start) / 1000000).toInt()` —
/// the elapsed-millisecond expression assigned after `proceed`
/// returns.  `monotonicNanos` (Std.Time, auto-imported by
/// `injectWeaveImports`) is the capture primitive on both targets:
/// monotonic, so a wall-clock adjustment mid-call can't produce a
/// negative duration.  `.toInt()` truncation is safe — an around
/// body would have to run for ~24 days before the millisecond count
/// overflows Int.
func mkElapsedMillisExpr(): Expr {
  val sub = Expr(
    kind = EBinop(
      op = BSub,
      lhs = mkCallNoArgs("monotonicNanos"),
      rhs = singleSegPathExpr("__lyric_call_start")
    ),
    span = synSpan()
  )
  val divisor = Expr(kind = ELiteral(lit = LInt(value = 1000000i64, suffix = I64, raw = "")), span = synSpan())
  val divided = Expr(
    kind = EBinop(op = BDiv, lhs = Expr(kind = EParen(inner = sub), span = synSpan()), rhs = divisor),
    span = synSpan()
  )
  val noArgs: List[CallArg] = newList()
  Expr(
    kind = ECall(
      fn = Expr(
        kind = EMember(
          receiver = Expr(kind = EParen(inner = divided), span = synSpan()),
          memberName = "toInt"
        ),
        span = synSpan()
      ),
      args = noArgs
    ),
    span = synSpan()
  )
}

/// `__lyric_call_elapsed = Some(value = <elapsed-ms>)` statement.
func mkElapsedAssignStmt(): Statement {
  Statement(
    kind = SAssign(
      target = singleSegPathExpr("__lyric_call_elapsed"),
      op = AssEq,
      value = mkSomeCall(mkElapsedMillisExpr())
    ),
    span = synSpan()
  )
}

/// Timed `proceed(args)` substitution used when the aspect body
/// references `call.elapsed` (#1298).  Rewrites the proceed call to a
/// block expression so the capture is exact in any expression
/// position (statement, val-init, loop body, if-branch) and the
/// assignment runs iff `proceed` dynamically executed:
///
///   {
///     val __lyric_call_start = monotonicNanos()
///     val __lyric_call_proceed_ret = <target>(p1, ...)
///     __lyric_call_elapsed = Some(value = ...ms...)
///     __lyric_call_proceed_ret
///   }
///
/// For `Unit`-returning targets the result binding is skipped (the
/// trailing statement is the assignment, so the block stays
/// `Unit`-typed).  Locals are block-scoped, so multiple `proceed`
/// sites in one body each get their own `__lyric_call_start`.
func proceedSubstitutionTimed(targetName: in String, paramNames: in List[String], targetReturnsUnit: in Bool): Expr {
  val stmts: List[Statement] = newList()
  stmts.add(mkValStmt("__lyric_call_start", None, mkCallNoArgs("monotonicNanos")))
  val targetCall = proceedSubstitution(targetName, paramNames)
  if targetReturnsUnit {
    stmts.add(Statement(kind = SExpr(expr = targetCall), span = synSpan()))
    stmts.add(mkElapsedAssignStmt())
  } else {
    stmts.add(mkValStmt("__lyric_call_proceed_ret", None, targetCall))
    stmts.add(mkElapsedAssignStmt())
    stmts.add(Statement(kind = SExpr(expr = singleSegPathExpr("__lyric_call_proceed_ret")), span = synSpan()))
  }
  Expr(kind = EBlock(block = Block(statements = stmts, span = synSpan())), span = synSpan())
}

/// Detect `receiver.<member>` where `receiver` is a bare `name`
/// path (single-segment, no module prefix).  Returns Some(memberName)
/// when the receiver matches; None otherwise.  Used to recognise the
/// special `config.<f>` / `call.<f>` / `args.<f>` patterns.
func matchBareMemberAccess(expr: in Expr, receiverName: in String): Option[String] {
  match expr.kind {
    case EMember(recv, member) -> {
      match recv.kind {
        case EPath(path) -> {
          if path.segments.count == 1 and path.segments[0] == receiverName {
            Some(value = member)
          } else {
            None
          }
        }
        case _ -> None
      }
    }
    case _ -> None
  }
}

/// True if a `config`, `call`, or `args` rewrite applies to this expr
/// at the top level.  Lets `rewriteExpr` bail out early before
/// recursing into receivers we are about to replace.
func tryMemberRewrite(ctx: in RewriteCtx, expr: in Expr): Option[Expr] {
  // config.<field> → __aspect_cfg_<field>
  match matchBareMemberAccess(expr, "config") {
    case Some(name) -> {
      if ctx.configFields.containsKey(name) {
        // Field has been materialised in the prelude.  Fields without
        // a default are also materialised — with a `panic("...")` stub
        // initializer — so the rewrite path is uniform and the body
        // type-checks and codegen succeeds for the no-default case.
        // For those, fire A0044 alongside the rewrite so the user sees
        // a weaver-targeted message rather than a confusing downstream
        // codegen error.
        if ctx.configNoDefault.containsKey(name) {
          addWeaveDiagOnce(ctx.weaveDiags, WDConfigNoDefault, ctx.aspectName, ctx.funcName, name, expr.span)
        }
        return Some(
          value = Expr(
            kind = EPath(path = ModulePath(segments = singleSeg("__aspect_cfg_" + name), span = expr.span)),
            span = expr.span
          )
        )
      }
      // config.<unknown> falls through — the field isn't declared
      // on the aspect at all, so the downstream type error is
      // appropriate.
    }
    case None -> ()
  }
  // call.<field> → __lyric_call_<field>
  match matchBareMemberAccess(expr, "call") {
    case Some(name) -> {
      if ctx.callFields.containsKey(name) {
        return Some(
          value = Expr(
            kind = EPath(path = ModulePath(segments = singleSeg("__lyric_call_" + name), span = expr.span)),
            span = expr.span
          )
        )
      } else {
        // Unknown call.<field> — surface as A0043 so the user sees a
        // weaver-targeted message instead of a downstream "call is not
        // declared" type error.  Dedupe by (kind, fieldName) so a body
        // that mentions `call.elapsed` twice doesn't emit two A0043s.
        addWeaveDiagOnce(ctx.weaveDiags, WDCallUnknown, ctx.aspectName, ctx.funcName, name, expr.span)
      }
    }
    case None -> ()
  }
  // args.<field> → <field>  (only under @inline_template).  When the
  // field name doesn't match a parameter we record an A0042 entry and
  // leave the expression intact so the downstream type-checker can
  // surface a position too (#681).  Same per-(kind, fieldName) dedupe
  // applies (#1299).
  if ctx.isInlineTemplate {
    match matchBareMemberAccess(expr, "args") {
      case Some(name) -> {
        if paramListContains(ctx.paramNames, name) {
          return Some(
            value = Expr(kind = EPath(path = ModulePath(segments = singleSeg(name), span = expr.span)), span = expr.span)
          )
        } else {
          addWeaveDiagOnce(ctx.weaveDiags, WDArgsMismatch, ctx.aspectName, ctx.funcName, name, expr.span)
        }
      }
      case None -> ()
    }
  }
  // args.<field> → __lyric_args.<field>  (row-constrained B'-mode; docs/56 /
  // D115).  `argsRowFields` is only non-empty when `buildBModeSpecializedFunction`
  // built this ctx for a template carrying `where TArgs has { ... }`; row
  // satisfaction against the matched function's actual parameters is checked
  // separately, per match, in `weaveItemsCore` (A0047 on mismatch).
  match matchBareMemberAccess(expr, "args") {
    case Some(name) -> {
      if ctx.argsRowFields.containsKey(name) {
        return Some(
          value = Expr(
            kind = EMember(receiver = singleSegPathExpr("__lyric_args"), memberName = name),
            span = expr.span
          )
        )
      }
    }
    case None -> ()
  }
  // bare <configfield> → __aspect_cfg_<configfield>.  Every shipped aspect
  // template references config fields bare (e.g. `minLen`) rather than via
  // the documented `config.minLen` form; wire both so the materialised
  // prelude local is actually read (#3543).  A parameter of the matched
  // function shadows a like-named config field (params win), so only
  // rewrite when the bare name is a materialised config field that is not
  // also a parameter.
  //
  // LIMITATION (#3611): a `val`/`var`/`let` in the `around` body whose name
  // collides with a config field is NOT yet recognised as a shadower — only
  // parameters are.  Such a body-local would be rewritten to the config
  // value.  This is unreached by the shipped templates (their locals never
  // share a config field's name) and is fixed properly alongside the #3594
  // walker dedup, where collecting local-binding names folds into the same
  // single pass.  Until then, do not name an `around`-body local after one
  // of the aspect's own config fields.
  match expr.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val cfgName = path.segments[0]
        if ctx.configFields.containsKey(cfgName) and not paramListContains(ctx.paramNames, cfgName) {
          if ctx.configNoDefault.containsKey(cfgName) {
            addWeaveDiagOnce(ctx.weaveDiags, WDConfigNoDefault, ctx.aspectName, ctx.funcName, cfgName, expr.span)
          }
          return Some(
            value = Expr(
              kind = EPath(path = ModulePath(segments = singleSeg("__aspect_cfg_" + cfgName), span = expr.span)),
              span = expr.span
            )
          )
        }
      }
    }
    case _ -> ()
  }
  None
}

// Append a weave-time diagnostic only when no entry with the same
// (kind, aspectName, funcName, fieldName) is already present.
// Linear scan is fine — the diagnostic list is small (one entry per
// distinct field name per matched function per aspect).
//
// The dedup key has three contextual axes besides `kind`:
//   - `funcName`: `weaveDiags` is shared across every matched
//     function in one `weaveItemsCore` invocation; an aspect that
//     references `call.elapsed` and matches both `funcA` and `funcB`
//     should emit one A0043 per wrapper.
//   - `aspectName`: when two aspects both apply to the same function
//     and both reference the same unknown `call.<field>`, each
//     aspect should produce its own diagnostic.
//   - `fieldName`: dedupes within a single body so the same
//     `call.<field>` referenced twice produces one diagnostic.
func addWeaveDiagOnce(
  errs: in List[WeaveDiagEntry],
  kind: in WeaveDiagKind,
  aspectName: in String,
  funcName: in String,
  fieldName: in String,
  span: in Span,
): Unit {
  var i = 0
  while i < errs.count {
    val e = errs[i]
    if e.fieldName == fieldName and e.funcName == funcName and e.aspectName == aspectName and sameWeaveDiagKind(e.kind, kind) {
      return
    }
    i = i + 1
  }
  errs.add(
    WeaveDiagEntry(kind = kind, aspectName = aspectName, funcName = funcName, fieldName = fieldName, span = span)
  )
}

func sameWeaveDiagKind(a: in WeaveDiagKind, b: in WeaveDiagKind): Bool {
  match a {
    case WDArgsMismatch -> match b { case WDArgsMismatch -> true; case _ -> false }
    case WDCallUnknown -> match b { case WDCallUnknown -> true; case _ -> false }
    case WDConfigNoDefault -> match b { case WDConfigNoDefault -> true; case _ -> false }
    case WDArgsRowMismatch -> match b { case WDArgsRowMismatch -> true; case _ -> false }
  }
}

func singleSeg(name: in String): List[String] {
  val segs: List[String] = newList()
  segs.add(name)
  segs
}

func paramListContains(paramNames: in List[String], name: in String): Bool {
  var i = 0
  while i < paramNames.count {
    if paramNames[i] == name {
      return true
    }
    i = i + 1
  }
  false
}

func rewriteExpr(ctx: in RewriteCtx, expr: in Expr): Expr {
  if isProceedCall(expr) {
    if ctx.callFields.containsKey("elapsed") {
      return proceedSubstitutionTimed(ctx.targetName, ctx.paramNames, ctx.targetReturnsUnit)
    }
    return proceedSubstitution(ctx.targetName, ctx.paramNames)
  }
  match tryMemberRewrite(ctx, expr) {
    case Some(replaced) -> return replaced
    case None -> ()
  }
  val s = expr.span
  match expr.kind {
    case ECall(f, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        newArgs.add(rewriteCallArg(ctx, args[i]))
        i = i + 1
      }
      Expr(kind = ECall(fn = rewriteExpr(ctx, f), args = newArgs), span = s)
    }
    case EParen(inner) -> Expr(kind = EParen(inner = rewriteExpr(ctx, inner)), span = s)
    case ETuple(xs) -> {
      val newXs: List[Expr] = newList()
      var i = 0
      while i < xs.count {
        newXs.add(rewriteExpr(ctx, xs[i]))
        i = i + 1
      }
      Expr(kind = ETuple(exprs = newXs), span = s)
    }
    case EList(xs) -> {
      val newXs: List[Expr] = newList()
      var i = 0
      while i < xs.count {
        newXs.add(rewriteExpr(ctx, xs[i]))
        i = i + 1
      }
      Expr(kind = EList(exprs = newXs), span = s)
    }
    case EAwait(inner) -> Expr(kind = EAwait(inner = rewriteExpr(ctx, inner)), span = s)
    case EYield(inner) -> Expr(kind = EYield(inner = rewriteExpr(ctx, inner)), span = s)
    case ESpawn(inner) -> Expr(kind = ESpawn(inner = rewriteExpr(ctx, inner)), span = s)
    case ETry(inner) -> Expr(kind = ETry(inner = rewriteExpr(ctx, inner)), span = s)
    case EOld(inner) -> Expr(kind = EOld(inner = rewriteExpr(ctx, inner)), span = s)
    case EPropagate(inner) -> Expr(kind = EPropagate(inner = rewriteExpr(ctx, inner)), span = s)
    case EPrefix(op, operand) -> Expr(kind = EPrefix(op = op, operand = rewriteExpr(ctx, operand)), span = s)
    case EBinop(op, l, r) -> Expr(kind = EBinop(op = op, lhs = rewriteExpr(ctx, l), rhs = rewriteExpr(ctx, r)), span = s)
    case EAssign(t, op, v) -> Expr(kind = EAssign(target = rewriteExpr(ctx, t), op = op, value = rewriteExpr(ctx, v)), span = s)
    case EMember(recv, n) -> Expr(kind = EMember(receiver = rewriteExpr(ctx, recv), memberName = n), span = s)
    case EIndex(recv, idxs) -> {
      val newIdxs: List[Expr] = newList()
      var i = 0
      while i < idxs.count {
        newIdxs.add(rewriteExpr(ctx, idxs[i]))
        i = i + 1
      }
      Expr(kind = EIndex(receiver = rewriteExpr(ctx, recv), indices = newIdxs), span = s)
    }
    case ETypeApp(f, targs) -> Expr(kind = ETypeApp(fn = rewriteExpr(ctx, f), args = targs), span = s)
    case EIf(cond, thenB, elseB, form) -> {
      val newElse = match elseB { case None -> None; case Some(e) -> Some(value = rewriteEOB(ctx, e)) }
      Expr(
        kind = EIf(
          cond = rewriteExpr(ctx, cond),
          thenBranch = rewriteEOB(ctx, thenB),
          elseBranch = newElse,
          thenForm = form
        ),
        span = s
      )
    }
    case EMatch(scrut, arms) -> Expr(kind = EMatch(scrutinee = rewriteExpr(ctx, scrut), arms = rewriteMatchArms(ctx, arms)), span = s)
    case ELambda(lparams, body) -> Expr(kind = ELambda(lambdaParams = lparams, body = rewriteBlock(ctx, body)), span = s)
    case EBlock(blk) -> Expr(kind = EBlock(block = rewriteBlock(ctx, blk)), span = s)
    case EUnsafe(blk) -> Expr(kind = EUnsafe(block = rewriteBlock(ctx, blk)), span = s)
    case EInterpolated(segs) -> {
      val newSegs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, sp) -> newSegs.add(ISText(text = t, span = sp))
          case ISExpr(e) -> newSegs.add(ISExpr(expr = rewriteExpr(ctx, e)))
        }
        i = i + 1
      }
      Expr(kind = EInterpolated(segments = newSegs), span = s)
    }
    // Leaves: ELiteral, EPath, ESelf, EResult, EForall, EExists, ERange, EError
    case _ -> expr
  }
}

func rewriteCallArg(ctx: in RewriteCtx, arg: in CallArg): CallArg {
  match arg {
    case CAPositional(v) -> CAPositional(expr = rewriteExpr(ctx, v))
    case CANamed(n, v, span) -> CANamed(name = n, value = rewriteExpr(ctx, v), span = span)
  }
}

func rewriteEOB(ctx: in RewriteCtx, eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBBlock(blk) -> EOBBlock(block = rewriteBlock(ctx, blk))
    case EOBExpr(expr) -> EOBExpr(expr = rewriteExpr(ctx, expr))
  }
}

func rewriteMatchArms(ctx: in RewriteCtx, arms: in List[MatchArm]): List[MatchArm] {
  val newArms: List[MatchArm] = newList()
  var i = 0
  while i < arms.count {
    val a = arms[i]
    val newGuard = match a.guard { case Some(g) -> Some(value = rewriteExpr(ctx, g)); case None -> None }
    newArms.add(MatchArm(pattern = a.pattern, guard = newGuard, body = rewriteEOB(ctx, a.body), span = a.span))
    i = i + 1
  }
  newArms
}

func rewriteBlock(ctx: in RewriteCtx, blk: in Block): Block {
  val newStmts: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    newStmts.add(rewriteStmt(ctx, blk.statements[i]))
    i = i + 1
  }
  Block(statements = newStmts, span = blk.span)
}

func rewriteStmt(ctx: in RewriteCtx, stmt: in Statement): Statement {
  val s = stmt.span
  match stmt.kind {
    case SExpr(e) -> Statement(kind = SExpr(expr = rewriteExpr(ctx, e)), span = s)
    case SReturn(opt) -> {
      val newOpt = match opt { case None -> None; case Some(e) -> Some(value = rewriteExpr(ctx, e)) }
      Statement(kind = SReturn(value = newOpt), span = s)
    }
    case SLocal(binding) -> Statement(kind = SLocal(binding = rewriteBinding(ctx, binding)), span = s)
    case SAssign(t, op, v) -> Statement(kind = SAssign(target = rewriteExpr(ctx, t), op = op, value = rewriteExpr(ctx, v)), span = s)
    case SThrow(e) -> Statement(kind = SThrow(expr = rewriteExpr(ctx, e)), span = s)
    case SFor(lbl, pat, iter, body) -> Statement(kind = SFor(label = lbl, pat = pat, iter = rewriteExpr(ctx, iter), body = rewriteBlock(ctx, body)), span = s)
    case SWhile(lbl, cond, body) -> Statement(kind = SWhile(label = lbl, cond = rewriteExpr(ctx, cond), body = rewriteBlock(ctx, body)), span = s)
    case SLoop(lbl, body) -> Statement(kind = SLoop(label = lbl, body = rewriteBlock(ctx, body)), span = s)
    case SScope(b, body) -> Statement(kind = SScope(binding = b, body = rewriteBlock(ctx, body)), span = s)
    case STry(body, catches, finally_) -> {
      val newBody = rewriteBlock(ctx, body)
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val cc = catches[i]
        newCatches.add(
          CatchClause(typeName = cc.typeName, bindName = cc.bindName, body = rewriteBlock(ctx, cc.body), span = cc.span)
        )
        i = i + 1
      }
      val newFinally = match finally_ { case None -> None; case Some(fb) -> Some(rewriteBlock(ctx, fb)) }
      Statement(kind = STry(body = newBody, catches = newCatches, finally_ = newFinally), span = s)
    }
    case SDefer(body) -> Statement(kind = SDefer(body = rewriteBlock(ctx, body)), span = s)
    // SBreak, SContinue, SInvariant, SRule, SItem: pass through
    case _ -> stmt
  }
}

func rewriteBinding(ctx: in RewriteCtx, b: in LocalBinding): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = rewriteExpr(ctx, init))
    case LBVar(name, ty, optInit) -> {
      val newInit = match optInit { case None -> None; case Some(e) -> Some(value = rewriteExpr(ctx, e)) }
      LBVar(name = name, ty = ty, init = newInit)
    }
    case LBLet(name, ty, init) -> LBLet(name = name, ty = ty, init = rewriteExpr(ctx, init))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Build a wrapper FunctionDecl for `originalFn` carrying `aspect`'s
//     around body, with proceed(args) → callTargetName(p1, p2, ...).
//     The wrapper keeps the original's params/return/contracts (composed
//     with the aspect's contracts).  Caller assigns the wrapper's name.
//
//     The wrapper body is built as `<prelude>` ++ `<rewritten body>`,
//     where the prelude materialises any `config { }` defaults the body
//     refers to (#683) and the compile-time call-context fields the
//     body refers to (#682).  Nothing is injected when no references
//     are present, so aspects that ignore `config` and `call` produce
//     byte-identical wrappers to the pre-todo-06 weaver.
// ─────────────────────────────────────────────────────────────────────────────
/// Bundle of weave-site information consumed by buildWrapper.
record WeaveSite {
  /// Package containing the matched function (used for
  /// `call.qualifiedName` / `call.modulePath`).
  packagePath: String
  /// True iff the matched aspect carries `@inline_template` (#681).
  isInlineTemplate: Bool
  /// Accumulator for `args.<n>` validation errors (#681).  Same
  /// reference is passed to every `buildWrapper` invocation in a
  /// `weaveItems` run; entries surface as A0042 diagnostics.
  weaveDiags: List[WeaveDiagEntry]
}

func makeWeaveSite(packagePath: in String, isInlineTemplate: in Bool, weaveDiags: in List[WeaveDiagEntry]): WeaveSite {
  WeaveSite(packagePath = packagePath, isInlineTemplate = isInlineTemplate, weaveDiags = weaveDiags)
}

/// Build a synthetic `val <name>: <ty> = <init>` statement at a zero
/// span.  Used by both the config-field prelude (#683) and the
/// call-context prelude (#682).
func mkValStmt(name: in String, ty: in Option[TypeExpr], init: in Expr): Statement {
  val pat = Pattern(kind = PBinding(name = name, inner = None), span = synSpan())
  Statement(kind = SLocal(binding = LBVal(pat = pat, ty = ty, init = init)), span = synSpan())
}

/// Build a synthetic `var <name>: <ty> = <init>` statement at a zero
/// span.  Used by the `call.elapsed` prelude (#1298), which needs a
/// mutable local so the timed proceed substitution can assign into it.
func mkVarStmt(name: in String, ty: in Option[TypeExpr], init: in Expr): Statement {
  Statement(kind = SLocal(binding = LBVar(name = name, ty = ty, init = Some(value = init))), span = synSpan())
}

/// Build a synthetic `var <name>: <ty>` statement (no initializer) at a
/// zero span.  Used by the `around(...) -> ret` out-variable lowering
/// (#3402): the wrapper declares `var ret: <returnType>`, the rewritten
/// body assigns into it, and the wrapper returns it.  Codegen
/// zero-initialises an uninitialised `var` slot, so all paths are
/// well-defined even if a branch forgets to assign.  `init = None`
/// is bound through an explicitly-typed local rather than passed inline:
/// the stage-0 bootstrap emitter miscompiles a bare inline `None` (no
/// type context) into a value that matches neither `Some` nor `None`,
/// so the `LBVar` `case None` arm never fires and `return ret` reads zero.
/// Bootstrap-emitter workaround; see docs/23-fsharp-shim-elimination.md.
func mkVarStmtNoInit(name: in String, ty: in Option[TypeExpr]): Statement {
  val noInit: Option[Expr] = None
  Statement(kind = SLocal(binding = LBVar(name = name, ty = ty, init = noInit)), span = synSpan())
}

/// True iff the block (or any nested statement body) contains a
/// top-level assignment to the bare local `name` — i.e. a
/// `name = <expr>` statement.  Drives the `around(...) -> ret`
/// out-variable lowering: when the advice body writes the named return
/// value, the wrapper must declare it as a local and return it (#3402).
/// Expression-style bodies (e.g. trailing `proceed(args)`) never assign
/// `ret`, so they are left untouched.
func blockAssignsToName(blk: in Block, name: in String): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtAssignsToName(blk.statements[i], name) {
      return true
    }
    i = i + 1
  }
  false
}

func exprIsBarePath(e: in Expr, name: in String): Bool {
  match e.kind {
    case EPath(p) -> p.segments.count == 1 and p.segments[0] == name
    case _ -> false
  }
}

func stmtAssignsToName(s: in Statement, name: in String): Bool {
  match s.kind {
    case SAssign(t, _, _) -> exprIsBarePath(t, name)
    case SFor(_, _, _, body) -> blockAssignsToName(body, name)
    case SWhile(_, _, body) -> blockAssignsToName(body, name)
    case SLoop(_, body) -> blockAssignsToName(body, name)
    case SScope(_, body) -> blockAssignsToName(body, name)
    case SDefer(body) -> blockAssignsToName(body, name)
    case STry(body, catches, finally_) -> {
      if blockAssignsToName(body, name) {
        return true
      }
      var i = 0
      while i < catches.count {
        if blockAssignsToName(catches[i].body, name) {
          return true
        }
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> blockAssignsToName(fb, name)
        case None -> false
      }
    }
    case SExpr(e) -> exprAssignsToName(e, name)
    case SReturn(o) -> match o { case Some(e) -> exprAssignsToName(e, name); case None -> false }
    case SLocal(b) -> {
      match b {
        case LBVal(_, _, init) -> exprAssignsToName(init, name)
        case LBLet(_, _, init) -> exprAssignsToName(init, name)
        case LBVar(_, _, optInit) -> match optInit { case Some(e) -> exprAssignsToName(e, name); case None -> false }
      }
    }
    case _ -> false
  }
}

/// Detect assignment to `name` inside an expression.  `ret = ...` may
/// appear as the `EAssign` expression form (or be nested inside an
/// `if` / `match` arm used in expression position), so the scan
/// descends into the branch-bearing and block-bearing expression kinds.
func exprAssignsToName(e: in Expr, name: in String): Bool {
  match e.kind {
    case EAssign(t, _, _) -> exprIsBarePath(t, name)
    case EBlock(blk) -> blockAssignsToName(blk, name)
    case EUnsafe(blk) -> blockAssignsToName(blk, name)
    case EParen(inner) -> exprAssignsToName(inner, name)
    case EIf(_, thenB, elseB, _) -> {
      if eobAssignsToName(thenB, name) {
        return true
      }
      match elseB {
        case Some(e2) -> eobAssignsToName(e2, name)
        case None -> false
      }
    }
    case EMatch(_, arms) -> {
      var i = 0
      while i < arms.count {
        if eobAssignsToName(arms[i].body, name) {
          return true
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

func eobAssignsToName(eob: in ExprOrBlock, name: in String): Bool {
  match eob {
    case EOBBlock(b) -> blockAssignsToName(b, name)
    case EOBExpr(e) -> exprAssignsToName(e, name)
  }
}

/// Rewrite every assignment to the bare local `name` (`name = <expr>`) into a
/// bare expression statement (`<expr>`), descending through the same nested
/// statement and expression-position branch forms as `blockAssignsToName`.
/// Used by the out-variable lowering for `Unit`-returning targets (#3424),
/// where the named `ret` carries no value: keeping `proceed()`'s effect while
/// dropping the meaningless store avoids synthesising a void `var`/`return`.
func stripRetAssignments(blk: in Block, name: in String): Block {
  val acc: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    acc.add(stripRetAssignmentsStmt(blk.statements[i], name))
    i = i + 1
  }
  Block(statements = acc, span = blk.span)
}

func stripRetAssignmentsStmt(s: in Statement, name: in String): Statement {
  val sp = s.span
  match s.kind {
    case SAssign(t, _, value) -> {
      if exprIsBarePath(t, name) {
        Statement(kind = SExpr(expr = value), span = sp)
      } else {
        s
      }
    }
    case SExpr(e) -> Statement(kind = SExpr(expr = stripRetAssignmentsExpr(e, name)), span = sp)
    case SReturn(o) -> match o { case Some(e) -> Statement(kind = SReturn(value = Some(value = stripRetAssignmentsExpr(e, name))), span = sp); case None -> s }
    case SLocal(b) -> {
      // The detection pass (`stmtAssignsToName`) descends into local-binding
      // initializers, so the strip pass must mirror it: a `ret = …` written
      // in expression position inside a `val`/`let`/`var` init (e.g.
      // `val x = (ret = proceed())`) is rewritten the same way (#3434).
      match b {
        case LBVal(pat, ty, init) -> Statement(kind = SLocal(binding = LBVal(pat = pat, ty = ty, init = stripRetAssignmentsExpr(init, name))), span = sp)
        case LBLet(nm, ty, init) -> Statement(kind = SLocal(binding = LBLet(name = nm, ty = ty, init = stripRetAssignmentsExpr(init, name))), span = sp)
        case LBVar(nm, ty, optInit) -> match optInit { case Some(e) -> Statement(kind = SLocal(binding = LBVar(name = nm, ty = ty, init = Some(value = stripRetAssignmentsExpr(e, name)))), span = sp); case None -> s }
      }
    }
    case SFor(lbl, pat, iter, body) -> Statement(kind = SFor(label = lbl, pat = pat, iter = iter, body = stripRetAssignments(body, name)), span = sp)
    case SWhile(lbl, cond, body) -> Statement(kind = SWhile(label = lbl, cond = cond, body = stripRetAssignments(body, name)), span = sp)
    case SLoop(lbl, body) -> Statement(kind = SLoop(label = lbl, body = stripRetAssignments(body, name)), span = sp)
    case SScope(b, body) -> Statement(kind = SScope(binding = b, body = stripRetAssignments(body, name)), span = sp)
    case SDefer(body) -> Statement(kind = SDefer(body = stripRetAssignments(body, name)), span = sp)
    case STry(body, catches, finally_) -> {
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val cc = catches[i]
        newCatches.add(
          CatchClause(
            typeName = cc.typeName,
            bindName = cc.bindName,
            body = stripRetAssignments(cc.body, name),
            span = cc.span
          )
        )
        i = i + 1
      }
      val newFinally = match finally_ { case Some(fb) -> Some(value = stripRetAssignments(fb, name)); case None -> None }
      Statement(kind = STry(body = stripRetAssignments(body, name), catches = newCatches, finally_ = newFinally), span = sp)
    }
    case _ -> s
  }
}

/// Expression-position counterpart: rewrite `name = <e>` (the `EAssign` form,
/// or one nested in a branch/block used in expression position) to `<e>`.
func stripRetAssignmentsExpr(e: in Expr, name: in String): Expr {
  val s = e.span
  match e.kind {
    case EAssign(t, _, value) -> {
      if exprIsBarePath(t, name) {
        value
      } else {
        e
      }
    }
    case EParen(inner) -> Expr(kind = EParen(inner = stripRetAssignmentsExpr(inner, name)), span = s)
    case EBlock(blk) -> Expr(kind = EBlock(block = stripRetAssignments(blk, name)), span = s)
    case EUnsafe(blk) -> Expr(kind = EUnsafe(block = stripRetAssignments(blk, name)), span = s)
    case EIf(cond, thenB, elseB, form) -> {
      val newElse = match elseB { case None -> None; case Some(eob) -> Some(value = stripRetAssignmentsEOB(eob, name)) }
      Expr(
        kind = EIf(cond = cond, thenBranch = stripRetAssignmentsEOB(thenB, name), elseBranch = newElse, thenForm = form),
        span = s
      )
    }
    case EMatch(scrut, arms) -> {
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val a = arms[i]
        newArms.add(
          MatchArm(pattern = a.pattern, guard = a.guard, body = stripRetAssignmentsEOB(a.body, name), span = a.span)
        )
        i = i + 1
      }
      Expr(kind = EMatch(scrutinee = scrut, arms = newArms), span = s)
    }
    case _ -> e
  }
}

func stripRetAssignmentsEOB(eob: in ExprOrBlock, name: in String): ExprOrBlock {
  match eob {
    case EOBBlock(b) -> EOBBlock(block = stripRetAssignments(b, name))
    case EOBExpr(e) -> EOBExpr(expr = stripRetAssignmentsExpr(e, name))
  }
}

/// `Option[Int]` type expression for the `__lyric_call_elapsed` var.
func mkOptionIntTypeExpr(): TypeExpr {
  val sp = synSpan()
  val intTy = TypeExpr(kind = TRef(path = ModulePath(segments = singleSeg("Int"), span = sp)), span = sp)
  val targs: List[TypeArg] = newList()
  targs.add(TAType(ty = intTy))
  TypeExpr(kind = TGenericApp(head = ModulePath(segments = singleSeg("Option"), span = sp), args = targs), span = sp)
}

/// `ELiteral(LString(text))` at a zero span.
func mkStringLit(text: in String): Expr {
  Expr(kind = ELiteral(lit = LString(text = text)), span = synSpan())
}

/// `EList(["a", "b", ...])` at a zero span.
func mkStringSliceLit(items: in List[String]): Expr {
  val exprs: List[Expr] = newList()
  var i = 0
  while i < items.count {
    exprs.add(mkStringLit(items[i]))
    i = i + 1
  }
  Expr(kind = EList(exprs = exprs), span = synSpan())
}

/// `slice[<elemName>]` type expression for a synthetic val annotation.
/// `elemName` is a bare type name (e.g. "String", "Int").
func mkSliceTypeExpr(elemName: in String): TypeExpr {
  val sp = synSpan()
  val segs: List[String] = newList()
  segs.add(elemName)
  val mp = ModulePath(segments = segs, span = sp)
  val inner = TypeExpr(kind = TRef(path = mp), span = sp)
  TypeExpr(kind = TSlice(element = inner), span = sp)
}

/// Build the `config { }` prelude for an aspect.  Lazy: pre-scans
/// the aspect body for `config.<field>` references and only emits
/// `val __aspect_cfg_<field>: <ty> = <init>` for fields the body
/// actually reads.  Aspects whose bodies never touch `config.*` produce
/// byte-identical wrappers to the pre-todo-06 weaver, matching the
/// lazy-prelude design used by `buildCallPrelude`.
///
/// Fields without a default are still materialised (when referenced)
/// with a `panic("config '<name>' has no default value...")` stub
/// initializer.  This keeps the rewrite path uniform so the body
/// type-checks and downstream codegen succeeds; A0044 fires alongside
/// the rewrite in `tryMemberRewrite` so the user sees a clear
/// weaver-targeted error instead of a confusing "unknown name 'config'"
/// codegen failure.  Runtime env-var resolution for these fields is a
/// follow-up — see todo/06 #683.
///
/// Returns three values:
///   - the synthetic prelude statements (one `val __aspect_cfg_<f>`
///     per materialised field);
///   - `materialised`: every field name whose prelude entry was
///     emitted (rewriter substitutes those);
///   - `noDefault`: subset of `materialised` that used the panic stub
///     because the field had no default (drives A0044 emission).
func buildConfigPrelude(aspect: in AspectDecl, body: in Block): (List[Statement], Map[String, Bool], Map[String, Bool]) {
  val stmts: List[Statement] = newList()
  val materialised: Map[String, Bool] = newMap()
  val noDefault: Map[String, Bool] = newMap()
  if aspect.config.count == 0 {
    return (stmts, materialised, noDefault)
  }

  // Pre-scan: which config fields does the body reference?  Both the
  // documented `config.<field>` qualified form and the bare `<field>`
  // form (used by every shipped template, e.g. `minLen` / `enabled`) are
  // honoured (#3543) so the prelude materialises the locals the body
  // actually reads under either spelling.
  val refs: Map[String, Bool] = newMap()
  collectMemberRefsBlock(body, "config", refs)
  val fieldNames: Map[String, Bool] = newMap()
  var fnI = 0
  while fnI < aspect.config.count {
    if not fieldNames.containsKey(aspect.config[fnI].name) {
      fieldNames.add(aspect.config[fnI].name, true)
    }
    fnI = fnI + 1
  }
  collectBareRefsBlock(body, fieldNames, refs)
  if refs.count == 0 {
    return (stmts, materialised, noDefault)
  }

  var i = 0
  while i < aspect.config.count {
    val f = aspect.config[i]
    if refs.containsKey(f.name) and not materialised.containsKey(f.name) {
      match f.default {
        case Some(init) -> {
          stmts.add(mkValStmt("__aspect_cfg_" + f.name, Some(value = f.ty), init))
          materialised.add(f.name, true)
        }
        case None -> {
          // No literal default — emit a panic stub so the body
          // type-checks and codegen succeeds.  A0044 fires in
          // tryMemberRewrite, so compilation halts before the
          // panic is ever reached at runtime.
          val msg = "config '" + f.name + "' has no default value and runtime env-var " +
            "resolution is not yet wired (see todo/06 #683)"
          stmts.add(mkValStmt("__aspect_cfg_" + f.name, Some(value = f.ty), mkPanicCall(msg)))
          materialised.add(f.name, true)
          noDefault.add(f.name, true)
        }
      }
    }
    i = i + 1
  }
  return (stmts, materialised, noDefault)
}

/// `panic(<text>)` call expression at a zero span.  `panic` is a Lyric
/// built-in returning `Never`, so this expression unifies with any
/// expected type — usable as a synthesised initializer for a `val` of
/// arbitrary declared type.
func mkPanicCall(text: in String): Expr {
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = mkStringLit(text)))
  Expr(kind = ECall(fn = singleSegPathExpr("panic"), args = args), span = synSpan())
}

/// Walk an Expr (and any nested Block / EOB) collecting the set of
/// `<receiver>.<field>` member-access names that appear anywhere
/// inside.  Used by `buildCallPrelude` and `buildConfigPrelude` to
/// skip materialising locals the body never reads (#1196, #1307).
func collectMemberRefsBlock(blk: in Block, receiver: in String, into: in Map[String, Bool]): Unit {
  var i = 0
  while i < blk.statements.count {
    collectMemberRefsStmt(blk.statements[i], receiver, into)
    i = i + 1
  }
}

func collectMemberRefsStmt(s: in Statement, receiver: in String, into: in Map[String, Bool]): Unit {
  match s.kind {
    case SExpr(e) -> collectMemberRefsExpr(e, receiver, into)
    case SReturn(o) -> match o { case Some(e) -> collectMemberRefsExpr(e, receiver, into); case None -> () }
    case SLocal(b) -> {
      match b {
        case LBVal(_, _, init) -> collectMemberRefsExpr(init, receiver, into)
        case LBLet(_, _, init) -> collectMemberRefsExpr(init, receiver, into)
        case LBVar(_, _, init) -> match init { case Some(e) -> collectMemberRefsExpr(e, receiver, into); case None -> () }
      }
    }
    case SAssign(t, _, v) -> {
      collectMemberRefsExpr(t, receiver, into)
      collectMemberRefsExpr(v, receiver, into)
    }
    case SThrow(e) -> collectMemberRefsExpr(e, receiver, into)
    case SFor(_, _, iter, body) -> {
      collectMemberRefsExpr(iter, receiver, into)
      collectMemberRefsBlock(body, receiver, into)
    }
    case SWhile(_, cond, body) -> {
      collectMemberRefsExpr(cond, receiver, into)
      collectMemberRefsBlock(body, receiver, into)
    }
    case SLoop(_, body) -> collectMemberRefsBlock(body, receiver, into)
    case SScope(_, body) -> collectMemberRefsBlock(body, receiver, into)
    case STry(body, catches, finally_) -> {
      collectMemberRefsBlock(body, receiver, into)
      var i = 0
      while i < catches.count {
        collectMemberRefsBlock(catches[i].body, receiver, into)
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> collectMemberRefsBlock(fb, receiver, into)
        case None -> ()
      }
    }
    case SDefer(body) -> collectMemberRefsBlock(body, receiver, into)
    case _ -> ()
  }
}

func collectMemberRefsExpr(e: in Expr, receiver: in String, into: in Map[String, Bool]): Unit {
  // Top-level: `<receiver>.<field>` member access.  Guard `add` with
  // `containsKey` so duplicate references in a body (e.g.
  // `log(call.shortName); ...; log(call.shortName + " end")`) don't
  // trip `Dictionary<K,V>.Add`'s ArgumentException.
  match matchBareMemberAccess(e, receiver) {
    case Some(name) -> if not into.containsKey(name) { into.add(name, true) }
    case None -> ()
  }
  // Recurse into sub-expressions.
  match e.kind {
    case ECall(f, args) -> {
      collectMemberRefsExpr(f, receiver, into)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(v) -> collectMemberRefsExpr(v, receiver, into)
          case CANamed(_, v, _) -> collectMemberRefsExpr(v, receiver, into)
        }
        i = i + 1
      }
    }
    case EParen(inner) -> collectMemberRefsExpr(inner, receiver, into)
    case ETuple(xs) -> {
      var i = 0
      while i < xs.count {
        collectMemberRefsExpr(xs[i], receiver, into)
        i = i + 1
      }
    }
    case EList(xs) -> {
      var i = 0
      while i < xs.count {
        collectMemberRefsExpr(xs[i], receiver, into)
        i = i + 1
      }
    }
    case EAwait(inner) -> collectMemberRefsExpr(inner, receiver, into)
    case EYield(inner) -> collectMemberRefsExpr(inner, receiver, into)
    case ESpawn(inner) -> collectMemberRefsExpr(inner, receiver, into)
    case ETry(inner) -> collectMemberRefsExpr(inner, receiver, into)
    case EOld(inner) -> collectMemberRefsExpr(inner, receiver, into)
    case EPropagate(inner) -> collectMemberRefsExpr(inner, receiver, into)
    case EPrefix(_, operand) -> collectMemberRefsExpr(operand, receiver, into)
    case EBinop(_, l, r) -> {
      collectMemberRefsExpr(l, receiver, into)
      collectMemberRefsExpr(r, receiver, into)
    }
    case EAssign(t, _, v) -> {
      collectMemberRefsExpr(t, receiver, into)
      collectMemberRefsExpr(v, receiver, into)
    }
    case EMember(recv, _) -> collectMemberRefsExpr(recv, receiver, into)
    case EIndex(recv, idxs) -> {
      collectMemberRefsExpr(recv, receiver, into)
      var i = 0
      while i < idxs.count {
        collectMemberRefsExpr(idxs[i], receiver, into)
        i = i + 1
      }
    }
    case ETypeApp(f, _) -> collectMemberRefsExpr(f, receiver, into)
    case EIf(c, t, el, _) -> {
      collectMemberRefsExpr(c, receiver, into)
      collectMemberRefsEOB(t, receiver, into)
      match el {
        case Some(e2) -> collectMemberRefsEOB(e2, receiver, into)
        case None -> ()
      }
    }
    case EMatch(scrut, arms) -> {
      collectMemberRefsExpr(scrut, receiver, into)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> collectMemberRefsExpr(g, receiver, into)
          case None -> ()
        }
        collectMemberRefsEOB(arms[i].body, receiver, into)
        i = i + 1
      }
    }
    case ELambda(_, body) -> collectMemberRefsBlock(body, receiver, into)
    case EBlock(blk) -> collectMemberRefsBlock(blk, receiver, into)
    case EUnsafe(blk) -> collectMemberRefsBlock(blk, receiver, into)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(_, _) -> ()
          case ISExpr(inner) -> collectMemberRefsExpr(inner, receiver, into)
        }
        i = i + 1
      }
    }
    case _ -> ()
  }
}

func collectMemberRefsEOB(eob: in ExprOrBlock, receiver: in String, into: in Map[String, Bool]): Unit {
  match eob {
    case EOBExpr(e) -> collectMemberRefsExpr(e, receiver, into)
    case EOBBlock(b) -> collectMemberRefsBlock(b, receiver, into)
  }
}

// Collect bare single-segment path references whose name is in `fields`
// (the aspect's config field names).  Mirrors `collectMemberRefsExpr`'s
// traversal exactly so every shipped template's bare config references
// (e.g. `minLen`, `enabled`) are materialised by `buildConfigPrelude`, not
// just the documented `config.<field>` qualified form (#3543).
//
// MAINTENANCE: this family duplicates the `collectMemberRefs*` traversal
// structure and must stay in lockstep with it when new `Expr`/`Statement`
// kinds are added.  Folding the two into one parameterised walker (so the
// config-prelude pre-scan collects both `config.<field>` and bare `<field>`
// in a single pass) is tracked as #3594; deferred to keep the #3592 fix
// turnaround off the shared `call`/`config` collection path.
func collectBareRefsBlock(blk: in Block, fields: in Map[String, Bool], into: in Map[String, Bool]): Unit {
  var i = 0
  while i < blk.statements.count {
    collectBareRefsStmt(blk.statements[i], fields, into)
    i = i + 1
  }
}

func collectBareRefsStmt(s: in Statement, fields: in Map[String, Bool], into: in Map[String, Bool]): Unit {
  match s.kind {
    case SExpr(e) -> collectBareRefsExpr(e, fields, into)
    case SReturn(o) -> match o { case Some(e) -> collectBareRefsExpr(e, fields, into); case None -> () }
    case SLocal(b) -> {
      match b {
        case LBVal(_, _, init) -> collectBareRefsExpr(init, fields, into)
        case LBLet(_, _, init) -> collectBareRefsExpr(init, fields, into)
        case LBVar(_, _, init) -> match init { case Some(e) -> collectBareRefsExpr(e, fields, into); case None -> () }
      }
    }
    case SAssign(t, _, v) -> {
      collectBareRefsExpr(t, fields, into)
      collectBareRefsExpr(v, fields, into)
    }
    case SThrow(e) -> collectBareRefsExpr(e, fields, into)
    case SFor(_, _, iter, body) -> {
      collectBareRefsExpr(iter, fields, into)
      collectBareRefsBlock(body, fields, into)
    }
    case SWhile(_, cond, body) -> {
      collectBareRefsExpr(cond, fields, into)
      collectBareRefsBlock(body, fields, into)
    }
    case SLoop(_, body) -> collectBareRefsBlock(body, fields, into)
    case SScope(_, body) -> collectBareRefsBlock(body, fields, into)
    case STry(body, catches, finally_) -> {
      collectBareRefsBlock(body, fields, into)
      var i = 0
      while i < catches.count {
        collectBareRefsBlock(catches[i].body, fields, into)
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> collectBareRefsBlock(fb, fields, into)
        case None -> ()
      }
    }
    case SDefer(body) -> collectBareRefsBlock(body, fields, into)
    case _ -> ()
  }
}

func collectBareRefsExpr(e: in Expr, fields: in Map[String, Bool], into: in Map[String, Bool]): Unit {
  match e.kind {
    case EPath(p) -> if p.segments.count == 1 and fields.containsKey(p.segments[0]) and not into.containsKey(p.segments[0]) { into.add(p.segments[0], true) }
    case ECall(f, args) -> {
      collectBareRefsExpr(f, fields, into)
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(v) -> collectBareRefsExpr(v, fields, into)
          case CANamed(_, v, _) -> collectBareRefsExpr(v, fields, into)
        }
        i = i + 1
      }
    }
    case EParen(inner) -> collectBareRefsExpr(inner, fields, into)
    case ETuple(xs) -> {
      var i = 0
      while i < xs.count {
        collectBareRefsExpr(xs[i], fields, into)
        i = i + 1
      }
    }
    case EList(xs) -> {
      var i = 0
      while i < xs.count {
        collectBareRefsExpr(xs[i], fields, into)
        i = i + 1
      }
    }
    case EAwait(inner) -> collectBareRefsExpr(inner, fields, into)
    case EYield(inner) -> collectBareRefsExpr(inner, fields, into)
    case ESpawn(inner) -> collectBareRefsExpr(inner, fields, into)
    case ETry(inner) -> collectBareRefsExpr(inner, fields, into)
    case EOld(inner) -> collectBareRefsExpr(inner, fields, into)
    case EPropagate(inner) -> collectBareRefsExpr(inner, fields, into)
    case EPrefix(_, operand) -> collectBareRefsExpr(operand, fields, into)
    case EBinop(_, l, r) -> {
      collectBareRefsExpr(l, fields, into)
      collectBareRefsExpr(r, fields, into)
    }
    case EAssign(t, _, v) -> {
      collectBareRefsExpr(t, fields, into)
      collectBareRefsExpr(v, fields, into)
    }
    case EMember(recv, _) -> collectBareRefsExpr(recv, fields, into)
    case EIndex(recv, idxs) -> {
      collectBareRefsExpr(recv, fields, into)
      var i = 0
      while i < idxs.count {
        collectBareRefsExpr(idxs[i], fields, into)
        i = i + 1
      }
    }
    case ETypeApp(f, _) -> collectBareRefsExpr(f, fields, into)
    case EIf(c, t, el, _) -> {
      collectBareRefsExpr(c, fields, into)
      collectBareRefsEOB(t, fields, into)
      match el {
        case Some(e2) -> collectBareRefsEOB(e2, fields, into)
        case None -> ()
      }
    }
    case EMatch(scrut, arms) -> {
      collectBareRefsExpr(scrut, fields, into)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> collectBareRefsExpr(g, fields, into)
          case None -> ()
        }
        collectBareRefsEOB(arms[i].body, fields, into)
        i = i + 1
      }
    }
    case ELambda(_, body) -> collectBareRefsBlock(body, fields, into)
    case EBlock(blk) -> collectBareRefsBlock(blk, fields, into)
    case EUnsafe(blk) -> collectBareRefsBlock(blk, fields, into)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(_, _) -> ()
          case ISExpr(inner) -> collectBareRefsExpr(inner, fields, into)
        }
        i = i + 1
      }
    }
    case _ -> ()
  }
}

func collectBareRefsEOB(eob: in ExprOrBlock, fields: in Map[String, Bool], into: in Map[String, Bool]): Unit {
  match eob {
    case EOBExpr(e) -> collectBareRefsExpr(e, fields, into)
    case EOBBlock(b) -> collectBareRefsBlock(b, fields, into)
  }
}

// Back-compat aliases for the original `collectCallRefs*` surface,
// kept narrow so existing call sites read naturally.  New code
// should call `collectMemberRefs*` directly with the receiver name.
func collectCallRefsBlock(blk: in Block, into: in Map[String, Bool]): Unit {
  collectMemberRefsBlock(blk, "call", into)
}

/// Build the `call` ambient prelude for an aspect.  Only emits a
/// `val __lyric_call_<field>` local for fields the aspect body
/// actually references; aspects that don't touch `call.*` produce
/// byte-identical wrappers to the pre-todo-06 weaver.
/// Compile-time-known fields: `shortName`, `qualifiedName`,
/// `modulePath`, `sourceLocation`, `annotations`, `aspect`.  The
/// runtime field `elapsed` (#1298) materialises as a mutable
/// `var __lyric_call_elapsed: Option[Int] = None` that the timed
/// proceed substitution assigns into.  `caller` is not available
/// (caller-site capture is unimplemented; docs/26 §4.3) — references
/// surface as A0043 diagnostics handled by the rewriter.
/// DRIFT WARNING: keep this set in lockstep with the A0043 "recognised
/// fields" list in `weaveDiagsToDiagnostics::WDCallUnknown` — adding a
/// field here without removing it from that list yields a diagnostic
/// that names the field as unrecognised even after it works.
func buildCallPrelude(
  originalFn: in FunctionDecl, aspect: in AspectDecl, site: in WeaveSite, body: in Block
): (List[Statement], Map[String, Bool]) {
  val stmts: List[Statement] = newList()
  val present: Map[String, Bool] = newMap()

  // Pre-scan: which call.<field> names does the body reference?
  val refs: Map[String, Bool] = newMap()
  collectCallRefsBlock(body, refs)
  if refs.count == 0 {
    return (stmts, present)
  }

  // shortName : String
  if refs.containsKey("shortName") {
    stmts.add(mkValStmt("__lyric_call_shortName", None, mkStringLit(originalFn.name)))
    present.add("shortName", true)
  }

  // qualifiedName : String
  if refs.containsKey("qualifiedName") {
    val qualified = if site.packagePath.length > 0 { site.packagePath + "." + originalFn.name } else { originalFn.name }
    stmts.add(mkValStmt("__lyric_call_qualifiedName", None, mkStringLit(qualified)))
    present.add("qualifiedName", true)
  }

  // modulePath : String
  if refs.containsKey("modulePath") {
    stmts.add(mkValStmt("__lyric_call_modulePath", None, mkStringLit(site.packagePath)))
    present.add("modulePath", true)
  }

  // sourceLocation : String  (formatted as "<package>:<line>")
  if refs.containsKey("sourceLocation") {
    val locText = if site.packagePath.length > 0 {
      site.packagePath + ":" + toString(originalFn.span.startPos.line)
    } else {
      "<unknown>:" + toString(originalFn.span.startPos.line)
    }
    stmts.add(mkValStmt("__lyric_call_sourceLocation", None, mkStringLit(locText)))
    present.add("sourceLocation", true)
  }

  // annotations : slice[String]
  // The `slice[String]` type annotation is mandatory so the inferred
  // type from `EList(string-literals)` matches the spec — without it
  // the synthesised val takes whatever `List[T]`-shaped type the
  // empty-list path infers, which is wrong for an empty annotations
  // list.
  if refs.containsKey("annotations") {
    val annNames: List[String] = newList()
    var ai = 0
    while ai < originalFn.annotations.count {
      annNames.add(annotationShortName(originalFn.annotations[ai]))
      ai = ai + 1
    }
    // The declared `slice[String]` type is mandatory: language reference §4.6
    // allows a string-list literal `["a", "b"]` to coerce to `slice[String]` at
    // a typed binding site (the empty-list path would otherwise infer a
    // `List[T]`-shaped type and reject the synthetic statement).
    stmts.add(mkValStmt("__lyric_call_annotations", Some(value = mkSliceTypeExpr("String")), mkStringSliceLit(annNames)))
    present.add("annotations", true)
  }

  // aspect : String  (the current aspect's name)
  if refs.containsKey("aspect") {
    stmts.add(mkValStmt("__lyric_call_aspect", None, mkStringLit(aspect.name)))
    present.add("aspect", true)
  }

  // elapsed : Option[Int] — `Some(ms)` after `proceed` returns, `None`
  // before / when the body never calls `proceed` (docs/26 §4.3,
  // Q-aspects-003).  Starts at None; `proceedSubstitutionTimed`
  // assigns `Some(ms)` immediately after the target call returns, so
  // a skip path that never reaches `proceed` observes None.  The
  // explicit `Option[Int]` annotation is mandatory — a bare `None`
  // initializer carries no inferable payload type.
  if refs.containsKey("elapsed") {
    stmts.add(mkVarStmt("__lyric_call_elapsed", Some(value = mkOptionIntTypeExpr()), singleSegPathExpr("None")))
    present.add("elapsed", true)
  }

  return (stmts, present)
}

func buildWrapper(
  originalFn: in FunctionDecl, aspect: in AspectDecl, callTargetName: in String, site: in WeaveSite
): FunctionDecl {
  // `around` presence is verified by the caller.
  val around = match aspect.around {
    case Some(a) -> a
    case None -> AspectAround(argsName = "args", retName = None, argsRow = None, body = Block(statements = newList(), span = synSpan()), span = synSpan())
  }
  val paramNames: List[String] = newList()
  var pi = 0
  while pi < originalFn.params.count {
    paramNames.add(originalFn.params[pi].name)
    pi = pi + 1
  }

  // Build preludes.  `buildConfigPrelude` returns three sets:
  // emitted statements, the materialised field names (rewriter
  // substitutes those), and the subset whose initializer is a
  // `panic(...)` stub because the field had no default — the
  // rewriter fires A0044 for any reference to those.
  // Both preludes are lazy: they pre-scan `around.body` for
  // `config.<x>` / `call.<x>` refs and emit only the locals the
  // body actually reads.
  val (cfgStmts, cfgPresent, cfgNoDefault) = buildConfigPrelude(aspect, around.body)
  val (callStmts, callPresent) = buildCallPrelude(originalFn, aspect, site, around.body)

  // `: Unit` parses as a TRef named "Unit" (TUnit is only the literal
  // `()` form), so both spellings must be recognised here.
  val targetReturnsUnit = match originalFn.ret {
    case None -> true
    case Some(te) -> {
      match te.kind {
        case TUnit -> true
        case TRef(mp) -> mp.segments.count == 1 and mp.segments[0] == "Unit"
        case _ -> false
      }
    }
  }

  val noArgsRowFields: Map[String, Bool] = newMap()
  val ctx = newRewriteCtx(
    callTargetName,
    paramNames,
    cfgPresent,
    cfgNoDefault,
    callPresent,
    targetReturnsUnit,
    site.isInlineTemplate,
    noArgsRowFields,
    aspect.name,
    originalFn.name,
    site.weaveDiags
  )

  val rewiredBody = rewriteBlock(ctx, around.body)

  // Does the advice write the named return value (`ret = ...`)?  This is the
  // out-variable form every shipped library template uses; expression-style
  // bodies (trailing `proceed(args)`, no `ret` write) never do.
  val assignsRet = match around.retName {
    case Some(retVar) -> blockAssignsToName(rewiredBody, retVar)
    case None -> false
  }

  // For a `Unit`-returning target the named `ret` is meaningless — there is
  // no value to thread or return — and synthesising `var ret: Unit` +
  // `return ret` trips codegen (a void local has no slot; the discarded
  // `ret = proceed()` store pops an empty stack), producing the very
  // `InvalidProgramException` #3402 set out to remove (#3424).  Strip each
  // `ret = <expr>` to a bare `<expr>` statement so its effect (e.g.
  // `proceed()`) still runs, and emit no var/return — the wrapper is a
  // plain void method that falls off the end.
  val effectiveBody = match around.retName {
    case Some(retVar) -> {
      if assignsRet and targetReturnsUnit {
        stripRetAssignments(rewiredBody, retVar)
      } else {
        rewiredBody
      }
    }
    case None -> rewiredBody
  }

  // Compose: <config prelude> ++ <call prelude> ++ <body>.
  val finalStmts: List[Statement] = newList()
  var i = 0
  while i < cfgStmts.count {
    finalStmts.add(cfgStmts[i])
    i = i + 1
  }
  i = 0
  while i < callStmts.count {
    finalStmts.add(callStmts[i])
    i = i + 1
  }
  i = 0
  while i < effectiveBody.statements.count {
    finalStmts.add(effectiveBody.statements[i])
    i = i + 1
  }

  // `around(...) -> ret` out-variable lowering (#3402).  When the advice
  // body writes the named return value (`ret = ...`) and the target returns
  // a real value, the wrapper must declare `ret` as a local of the target's
  // return type and return it after the body runs; otherwise the synthesised
  // wrapper falls off the end of a non-void method, producing invalid IL
  // (InvalidProgramException at runtime).  Expression-style bodies and
  // `Unit`-returning targets (handled by `effectiveBody` above) are left
  // without a synthetic var/return.
  val loweredStmts = match around.retName {
    case Some(retVar) -> {
      if assignsRet and not targetReturnsUnit {
        val withRet: List[Statement] = newList()
        withRet.add(mkVarStmtNoInit(retVar, originalFn.ret))
        var ri = 0
        while ri < finalStmts.count {
          withRet.add(finalStmts[ri])
          ri = ri + 1
        }
        withRet.add(Statement(kind = SReturn(value = Some(value = singleSegPathExpr(retVar))), span = synSpan()))
        withRet
      } else {
        finalStmts
      }
    }
    case None -> finalStmts
  }
  val finalBody = Block(statements = loweredStmts, span = rewiredBody.span)

  // Composed contract: aspect.contracts ++ original.contracts (§5).
  val composed: List[ContractClause] = newList()
  var ci = 0
  while ci < aspect.contracts.count {
    composed.add(aspect.contracts[ci])
    ci = ci + 1
  }
  ci = 0
  while ci < originalFn.contracts.count {
    composed.add(originalFn.contracts[ci])
    ci = ci + 1
  }

  // Strip @no_aspect / aspect-routing annotations from the wrapper.
  val noAnnotations: List[Annotation] = newList()

  FunctionDecl(
    docComments = originalFn.docComments,
    annotations = noAnnotations,
    visibility = originalFn.visibility,
    isAsync = originalFn.isAsync,
    name = originalFn.name,
    generics = originalFn.generics,
    params = originalFn.params,
    ret = originalFn.ret,
    whereClause = originalFn.whereClause,
    contracts = composed,
    body = Some(value = FBBlock(block = finalBody)),
    span = originalFn.span
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Topological sort of aspects by wraps:/inside: clauses.
//     "A wraps B" → A is outer, B is inner (A before B).
//     "A inside B" → B is outer, A is inner (B before A = A after B).
//     Lexical order is the tiebreak; cycles fall back to lexical order.
//     Returns aspects sorted outermost → innermost.
// ─────────────────────────────────────────────────────────────────────────────
// Increment `inDegree[inner]` for every inner name in `edges[from]`.
// Extracted as a helper because the bootstrap emitter mis-resolves
// nested `match Some(inners) -> while inners.count { ... }` when the
// enclosing function returns a `List` of an imported type.
func bumpInDegrees(
  edges: in Map[String, List[String]],
  inDegree: in Map[String, Int],
  from: in String,
  delta: in Int,
  queue: in List[String],
): Unit {
  match mapGet(edges, from) {
    case Some(inners) -> {
      var ii = 0
      while ii < inners.count {
        val inner = inners[ii]
        if inDegree.containsKey(inner) {
          val d = match mapGet(inDegree, inner) { case Some(v) -> v; case None -> 0 }
          val nd = d + delta
          val _ = inDegree.remove(inner)
          inDegree.add(inner, nd)
          if delta < 0 and nd == 0 {
            queue.add(inner)
          }
        }
        ii = ii + 1
      }
    }
    case None -> ()
  }
}

func sortAspects(aspects: in List[AspectDecl]): List[AspectDecl] {
  if aspects.count <= 1 {
    val result: List[AspectDecl] = newList()
    var i = 0
    while i < aspects.count {
      result.add(aspects[i])
      i = i + 1
    }
    return result
  }

  // Adjacency: outer -> set of inner names (as list, dedup via map).
  val edges: Map[String, List[String]] = newMap()
  val edgeSeen: Map[String, Map[String, Bool]] = newMap()
  var i = 0
  while i < aspects.count {
    val a = aspects[i]
    if not edges.containsKey(a.name) {
      val empty: List[String] = newList()
      edges.add(a.name, empty)
      val emptySeen: Map[String, Bool] = newMap()
      edgeSeen.add(a.name, emptySeen)
    }
    i = i + 1
  }
  i = 0
  while i < aspects.count {
    val a = aspects[i]
    var wi = 0
    while wi < a.wraps.count {
      val inner = a.wraps[wi]
      addEdge(edges, edgeSeen, a.name, inner)
      wi = wi + 1
    }
    var ii2 = 0
    while ii2 < a.inside.count {
      val outer = a.inside[ii2]
      if edges.containsKey(outer) {
        addEdge(edges, edgeSeen, outer, a.name)
      }
      ii2 = ii2 + 1
    }
    i = i + 1
  }

  // In-degrees.
  val inDegree: Map[String, Int] = newMap()
  i = 0
  while i < aspects.count {
    inDegree.add(aspects[i].name, 0)
    i = i + 1
  }
  val unusedQueue: List[String] = newList()
  i = 0
  while i < aspects.count {
    bumpInDegrees(edges, inDegree, aspects[i].name, 1, unusedQueue)
    i = i + 1
  }

  // Kahn's algorithm: queue starts with zero in-degree (lexical order).
  val queue: List[String] = newList()
  i = 0
  while i < aspects.count {
    val n = aspects[i].name
    val d = lookupIntOr0(inDegree, n)
    if d == 0 {
      queue.add(n)
    }
    i = i + 1
  }
  val sortedNames: List[String] = newList()
  val sortedSeen: Map[String, Bool] = newMap()
  var head = 0
  while head < queue.count {
    val n = queue[head]
    head = head + 1
    sortedNames.add(n)
    sortedSeen.add(n, true)
    bumpInDegrees(edges, inDegree, n, -1, queue)
  }
  // Any remaining (cycle) — append in lexical order.
  i = 0
  while i < aspects.count {
    val n = aspects[i].name
    if not sortedSeen.containsKey(n) {
      sortedNames.add(n)
      sortedSeen.add(n, true)
    }
    i = i + 1
  }

  // Look up AspectDecl by name in lexical-order map.
  buildSortedResult(aspects, sortedNames)
}

func lookupIntOr0(m: in Map[String, Int], k: in String): Int {
  match mapGet(m, k) {
    case Some(v) -> v
    case None -> 0
  }
}

func buildSortedResult(aspects: in List[AspectDecl], sortedNames: in List[String]): List[AspectDecl] {
  val byName: Map[String, AspectDecl] = newMap()
  var i = 0
  while i < aspects.count {
    byName.add(aspects[i].name, aspects[i])
    i = i + 1
  }
  val result: List[AspectDecl] = newList()
  i = 0
  while i < sortedNames.count {
    val nm = sortedNames[i]
    if byName.containsKey(nm) {
      match mapGet(byName, nm) {
        case Some(a) -> result.add(a)
        case None -> ()
      }
    }
    i = i + 1
  }
  result
}

func addEdge(
  edges: in Map[String, List[String]],
  edgeSeen: in Map[String, Map[String, Bool]],
  from: in String,
  to: in String,
): Unit {
  match mapGet(edgeSeen, from) {
    case Some(seen) -> {
      if not seen.containsKey(to) {
        seen.add(to, true)
        match mapGet(edges, from) {
          case Some(inners) -> inners.add(to)
          case None -> ()
        }
      }
    }
    case None -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. TypeExpr → string for `signature: returns` matching.  Mirrors
//     Weaver.fs typeExprToString.
// ─────────────────────────────────────────────────────────────────────────────
func typeExprToString(te: in TypeExpr): String {
  match te.kind {
    case TRef(mp) -> segmentsJoin(mp.segments)
    case TUnit -> "Unit"
    case TNever -> "Never"
    case TSelf -> "Self"
    case TError -> "<error>"
    case TGenericApp(head, args) -> {
      val h = segmentsJoin(head.segments)
      val parts: List[String] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(inner) -> parts.add(typeExprToString(inner))
          case _ -> parts.add("_")
        }
        i = i + 1
      }
      h + "[" + commaJoin(parts) + "]"
    }
    case TSlice(inner) -> "slice[" + typeExprToString(inner) + "]"
    case TArray(_, inner) -> "array[" + typeExprToString(inner) + "]"
    case TNullable(inner) -> typeExprToString(inner) + "?"
    case TTuple(items) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < items.count {
        parts.add(typeExprToString(items[i]))
        i = i + 1
      }
      "(" + commaJoin(parts) + ")"
    }
    case TFunction(ps, ret) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < ps.count {
        parts.add(typeExprToString(ps[i]))
        i = i + 1
      }
      "(" + commaJoin(parts) + ") -> " + typeExprToString(ret)
    }
    case TRefined(mp, _) -> segmentsJoin(mp.segments)
    case TParen(inner) -> typeExprToString(inner)
  }
}

func segmentsJoin(segs: in List[String]): String {
  var acc = ""
  var i = 0
  while i < segs.count {
    if i > 0 {
      acc = acc + "."
    }
    acc = acc + segs[i]
    i = i + 1
  }
  acc
}

func commaJoin(parts: in List[String]): String {
  var acc = ""
  var i = 0
  while i < parts.count {
    if i > 0 {
      acc = acc + ", "
    }
    acc = acc + parts[i]
    i = i + 1
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Predicate matching (AND semantics; empty matchers ⇒ no match).
// ─────────────────────────────────────────────────────────────────────────────
func annotationShortName(ann: in Annotation): String {
  val segs = ann.name.segments
  if segs.count == 0 {
    return ""
  }
  segs[segs.count - 1]
}

func annotationHasName(fn: in FunctionDecl, name: in String): Bool {
  var i = 0
  while i < fn.annotations.count {
    if annotationShortName(fn.annotations[i]) == name {
      return true
    }
    i = i + 1
  }
  false
}

func matchesPredicate(m: in AspectMatcher, fn: in FunctionDecl): Bool {
  match m {
    case AMNameLike(glob, _) -> globMatch(glob, fn.name)
    case AMNameIn(names, _) -> nameListContains(names, fn.name)
    case AMAnnotated(annName, _) -> annotationHasName(fn, annName)
    case AMVisibility(vis, _) -> {
      if vis == "pub" {
        match fn.visibility {
          case Some(v) -> match v { case VisPub(_) -> true; case _ -> false }
          case None -> false
        }
      } else if vis == "internal" {
        match fn.visibility {
          case Some(v) -> match v { case VisInternal(_) -> true; case _ -> false }
          case None -> false
        }
      } else if vis == "priv" {
        match fn.visibility {
          case Some(_) -> false
          case None -> true
        }
      } else {
        false
      }
    }
    case AMSignatureReturns(typeGlob, _) -> {
      val retStr = match fn.ret { case None -> "Unit"; case Some(te) -> typeExprToString(te) }
      globMatch(typeGlob, retStr)
    }
  }
}

func matchesPredicates(matchers: in List[AspectMatcher], fn: in FunctionDecl): Bool {
  // Empty matchers ⇒ library-template aspect with no local match: clause.
  if matchers.count == 0 {
    return false
  }
  var i = 0
  while i < matchers.count {
    if not matchesPredicate(matchers[i], fn) {
      return false
    }
    i = i + 1
  }
  true
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. @no_aspect opt-out.  `@no_aspect` opts out of all; `@no_aspect("Name")`
//     opts out of just the named aspect.
// ─────────────────────────────────────────────────────────────────────────────
func annotationIsNoAspect(ann: in Annotation): Bool {
  ann.name.segments.count == 1 and ann.name.segments[0] == "no_aspect"
}

func annotationArgsTargetAspect(args: in List[AnnotationArg], aspectName: in String): Bool {
  if args.count == 0 {
    return true
  }
  // bare @no_aspect → all
  var i = 0
  while i < args.count {
    match args[i] {
      case ALiteral(value, _) -> {
        match value {
          case AVString(s, _) -> if s == aspectName { return true }
          case _ -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

func isOptedOut(fn: in FunctionDecl, aspectName: in String): Bool {
  var i = 0
  while i < fn.annotations.count {
    val a = fn.annotations[i]
    if annotationIsNoAspect(a) {
      if annotationArgsTargetAspect(a.args, aspectName) {
        return true
      }
    }
    i = i + 1
  }
  false
}

func nameListContains(names: in List[String], name: in String): Bool {
  var i = 0
  while i < names.count {
    if names[i] == name {
      return true
    }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Public entry: weave items.  Mirrors Weaver.fs weaveItems plus the
//     todo/06 extensions (config wiring, call-context prelude,
//     @inline_template `args.<field>` rewriting + A0042 diagnostics).
// ─────────────────────────────────────────────────────────────────────────────
/// One aspect collected by `collectActiveAspects`, paired with whether
/// the enclosing item carried `@inline_template` (#681).  The annotation
/// lives on the `Item.annotations` list because `AspectDecl` itself has
/// no annotations field — the parser attaches them at item granularity.
record CollectedAspect {
  decl: AspectDecl
  isInlineTemplate: Bool
}

func itemHasInlineTemplate(item: in Item): Bool {
  var i = 0
  while i < item.annotations.count {
    if annotationShortName(item.annotations[i]) == "inline_template" {
      return true
    }
    i = i + 1
  }
  false
}

func collectActiveAspects(items: in List[Item]): List[CollectedAspect] {
  val aspects: List[CollectedAspect] = newList()
  var i = 0
  while i < items.count {
    val it = items[i]
    match it.kind {
      case IAspect(decl) -> {
        match decl.around {
          case Some(_) -> aspects.add(CollectedAspect(decl = decl, isInlineTemplate = itemHasInlineTemplate(it)))
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  aspects
}

/// Result of a weave pass: the rewritten item list plus any
/// weave-time diagnostics (currently only A0042 for `@inline_template`
/// `args.<field>` mismatches).
pub record WeaveResult {
  items: List[Item]
  diagnostics: List[Diagnostic]
}

/// Compute the package path string from a SourceFile's package decl,
/// e.g. ["Std", "Time"] → "Std.Time".  Empty string when the package
/// is at the root (unusual for real code).
func packagePathString(file: in SourceFile): String {
  segmentsJoin(file.packageDecl.path.segments)
}

// True if the file already has `import Std.Time`.
func hasStdTimeImport(imports: in List[ImportDecl]): Bool {
  var i = 0
  while i < imports.count {
    val imp = imports[i]
    if imp.path.segments.count == 2 and imp.path.segments[0] == "Std" and imp.path.segments[1] == "Time" {
      return true
    }
    i = i + 1
  }
  false
}

// Return a copy of `imports` with a synthetic `import Std.Time` appended.
func addStdTimeImport(imports: in List[ImportDecl], span: in Span): List[ImportDecl] {
  val result: List[ImportDecl] = newList()
  var i = 0
  while i < imports.count {
    result.add(imports[i])
    i = i + 1
  }
  val segs: List[String] = newList()
  segs.add("Std")
  segs.add("Time")
  result.add(
    ImportDecl(
      path = ModulePath(segments = segs, span = span),
      selector = None,
      asAlias = None,
      isPubUse = false,
      isExtern = false,
      span = span
    )
  )
  result
}

/// True iff any `aspect { around ... }` item's body references
/// `call.elapsed` — i.e. weaving this file will synthesise calls to
/// `Std.Time.monotonicNanos` (#1298).
/// DRIFT WARNING: if a future `call.<field>` also requires an auto-injected
/// import (as `call.elapsed` requires `Std.Time`), extend BOTH this function
/// and `injectWeaveImports` — mirror the `"elapsed"` / `Std.Time` pattern.
pub func weaveNeedsStdTime(file: in SourceFile): Bool {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IAspect(decl) -> {
        match decl.around {
          case Some(a) -> {
            val refs: Map[String, Bool] = newMap()
            collectCallRefsBlock(a.body, refs)
            if refs.containsKey("elapsed") {
              return true
            }
          }
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

/// Return `file` with `import Std.Time` ensured (deduplicated) when
/// weaving will materialise `call.elapsed` instrumentation; identity
/// otherwise.  Mirrors the `Lyric.Stubbable` auto-import precedent
/// (D100): the synthesised dependency is made explicit on the file
/// rather than resolved ad hoc.  `weaveFile` / `weaveFileWithDiags`
/// apply this automatically, but bridges that compute an import
/// closure BEFORE the middle-end weave runs (the JVM bundler walks
/// `file.imports` to decide which stdlib packages to bundle) must
/// call it right after parse so `Std.Time` lands in the closure.
pub func injectWeaveImports(file: in SourceFile): SourceFile {
  if not weaveNeedsStdTime(file) {
    return file
  }
  if hasStdTimeImport(file.imports) {
    return file
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = addStdTimeImport(file.imports, file.span),
    items = file.items,
    span = file.span
  )
}

/// Convert weave-time diagnostic entries to user-facing Diagnostic
/// objects.  Three kinds today: A0042 (args mismatch on
/// `@inline_template`), A0043 (unknown `call.<field>`), A0044
/// (`config.<field>` declared but no literal default).
/// A0045 (unresolved `from`-instance template) is emitted directly in
/// `collectUnresolvedFromDiags` / `weaveFileWithDiagsAndTemplates`, not
/// via this converter (it has no WeaveDiagEntry form).
func weaveDiagsToDiagnostics(errs: in List[WeaveDiagEntry]): List[Diagnostic] {
  val diags: List[Diagnostic] = newList()
  var i = 0
  while i < errs.count {
    val e = errs[i]
    match e.kind {
      case WDArgsMismatch -> {
        val msg = "@inline_template aspect '" + e.aspectName + "' references args." + e.fieldName + " but matched function '" +
          e.funcName +
          "' has no parameter named '" +
          e.fieldName +
          "'"
        diags.add(errorDiagnostic("A0042", msg, e.span))
      }
      case WDCallUnknown -> {
        // **Drift warning:** the recognised-fields list below is the
        // user-visible enumeration of fields the weaver injects in
        // `buildCallPrelude`.  When a new `call.<field>` is added
        // there, this list must be updated to match — otherwise
        // A0043 will name the new field as "unrecognised" while
        // simultaneously rewriting it correctly.
        val msg = "aspect '" + e.aspectName + "' references call." + e.fieldName + " on matched function '" + e.funcName +
          "' but the weaver does not inject a value for that field " +
          "(recognised fields: shortName, qualifiedName, modulePath, " +
          "sourceLocation, annotations, aspect, elapsed; call.caller " +
          "is not available — caller-site capture is unimplemented, " +
          "see docs/26-aspects.md section 4.3)"
        diags.add(errorDiagnostic("A0043", msg, e.span))
      }
      case WDConfigNoDefault -> {
        val msg = "aspect '" + e.aspectName + "' references config." + e.fieldName + " on matched function '" + e.funcName +
          "' but the field has no literal default (runtime env-var " +
          "resolution per docs/26 §8 is not yet wired); add a default " +
          "to the `config { }` block or remove the reference"
        diags.add(errorDiagnostic("A0044", msg, e.span))
      }
      case WDArgsRowMismatch -> {
        val msg = "aspect '" + e.aspectName + "' declares `where TArgs has { " + e.fieldName +
          ": ... }` but matched function '" +
          e.funcName +
          "' has no parameter named '" +
          e.fieldName +
          "' of a compatible type (docs/56)"
        diags.add(errorDiagnostic("A0047", msg, e.span))
      }
    }
    i = i + 1
  }
  diags
}

/// Core weave loop.  Used by both `weaveItems` (drops diagnostics, for
/// back-compat) and `weaveItemsWithDiags` / `weaveFileWithDiags`.
func weaveItemsCore(items: in List[Item], packagePath: in String): WeaveResult {
  val weaveDiags: List[WeaveDiagEntry] = newList()
  val collected = collectActiveAspects(items)
  if collected.count == 0 {
    val noAspectItems: List[Item] = newList()
    var i = 0
    while i < items.count {
      match items[i].kind {
        case IAspect(_) -> ()
        case _ -> noAspectItems.add(items[i])
      }
      i = i + 1
    }
    val noDiags: List[Diagnostic] = newList()
    return WeaveResult(items = noAspectItems, diagnostics = noDiags)
  }

  // Build a `name -> isInlineTemplate` lookup so the sorted aspect list
  // (which goes through name-only Kahn ordering) can recover the
  // per-aspect template flag at weave time.  Guard the `add` with
  // `containsKey` so duplicate aspect declarations in one file (a
  // separate A0002 issue caught upstream by the type checker) don't
  // throw `Dictionary.Add`'s ArgumentException during the weave pass.
  // First-wins is fine: A0002 fires before this code runs in any
  // well-formed pipeline.
  //
  // inlineTemplateNames tracks which aspect names are inline templates as a
  // string-keyed set (name → name) rather than Map[String, Bool], because
  // mapGet+match on Bool values in the bootstrap codegen produces MObject (not
  // Bool) from the unbound PConstructor binding, causing a JIT verification
  // failure when the result is passed to a Bool parameter. containsKey returns
  // Bool directly, avoiding that codegen path.  Revert to `Map[String, Bool]`
  // once #1826 is fixed.
  // seenAspectNames enforces first-wins for duplicate aspect names.
  val inlineTemplateNames: Map[String, String] = newMap()
  val seenAspectNames: Map[String, String] = newMap()
  val declsForSort: List[AspectDecl] = newList()
  var ci = 0
  while ci < collected.count {
    val nm = collected[ci].decl.name
    if not seenAspectNames.containsKey(nm) {
      seenAspectNames.add(nm, nm)
      if collected[ci].isInlineTemplate {
        inlineTemplateNames.add(nm, nm)
      }
    }
    declsForSort.add(collected[ci].decl)
    ci = ci + 1
  }

  // B'-mode shape cache (docs/55 §3.2, §8b above): one specialised
  // function per distinct `(templateKey, shape)`, one cfg record per
  // template, one call-context record for the whole file.  Fresh per
  // `weaveItemsCore` invocation (i.e. per woven file).
  val bmodeTemplateInfoCache: Map[String, BModeTemplateInfo] = newMap()
  val bmodeSpecEmitted: Map[String, Bool] = newMap()
  var bmodeCtxEmitted = false

  val result: List[Item] = newList()
  var idx = 0
  while idx < items.count {
    val item = items[idx]
    match item.kind {
      case IAspect(_) -> ()
      case IFunc(fn) -> {
        val matched: List[AspectDecl] = newList()
        var ai = 0
        while ai < declsForSort.count {
          val a = declsForSort[ai]
          if not isOptedOut(fn, a.name) and not nameListContains(a.exceptNames, fn.name) and matchesPredicates(a.matches, fn) {
            matched.add(a)
          }
          ai = ai + 1
        }
        if matched.count == 0 {
          result.add(item)
        } else {
          val ordered = sortAspects(matched)
          val targetName = fn.name + "__aspect_target"
          // Rename original target; strip visibility so only the wrapper is public.
          val renamedFn = FunctionDecl(
            docComments = fn.docComments,
            annotations = fn.annotations,
            visibility = None,
            isAsync = fn.isAsync,
            name = targetName,
            generics = fn.generics,
            params = fn.params,
            ret = fn.ret,
            whereClause = fn.whereClause,
            contracts = fn.contracts,
            body = fn.body,
            span = fn.span
          )
          result.add(
            Item(
              docComments = item.docComments,
              annotations = item.annotations,
              visibility = item.visibility,
              kind = IFunc(decl = renamedFn),
              span = item.span
            )
          )
          // Build wrappers from innermost to outermost; outermost keeps the
          // public name, intermediates get __aspect_<AspectName>.
          val n = ordered.count
          var callTarget = targetName
          var i = 0
          while i < n {
            val aspect = ordered[n - 1 - i]
            val isOutermost = (i == n - 1)
            val wrapperName = if isOutermost { fn.name } else { fn.name + "__aspect_" + aspect.name }
            val isTpl: Bool = inlineTemplateNames.containsKey(aspect.name)
            val site = makeWeaveSite(packagePath, isTpl, weaveDiags)
            // B'-mode: a resolved `from`-instance (docs/55 §3.2) whose
            // template is not C-mode.  Local aspects (`from = None`) and
            // C-mode templates keep the existing inline-per-match path.
            val isBMode = match aspect.from { case Some(_) -> not isTpl; case None -> false }
            val wrapper0 = if isBMode {
              if not bmodeCtxEmitted {
                result.add(bmodeSynthCallCtxRecordItem(fn.span))
                bmodeCtxEmitted = true
              }
              val templateKey = match aspect.from { case Some(fp) -> bmodeTemplateKey(fp); case None -> aspect.name }
              val info = bmodeGetOrBuildTemplateInfo(bmodeTemplateInfoCache, templateKey, aspect, result, fn.span)
              val shapeKey = bmodeShapeKey(fn.params, fn.ret)
              val specName = "__lyric_bmode_" + Str.replace(templateKey, ".", "_") + "__" + shapeKey
              val specKey = templateKey + "::" + shapeKey
              if not bmodeSpecEmitted.containsKey(specKey) {
                val paramTypes: List[TypeExpr] = newList()
                var pti = 0
                while pti < fn.params.count {
                  paramTypes.add(fn.params[pti].ty)
                  pti = pti + 1
                }
                val targetReturnsUnit = bmodeIsUnitReturn(fn.ret)
                val specFn = buildBModeSpecializedFunction(
                  aspect,
                  specName,
                  paramTypes,
                  fn.ret,
                  targetReturnsUnit,
                  info.cfgRecordName,
                  info.argsRecordName,
                  fn.span
                )
                result.add(
                  Item(
                    docComments = newList(),
                    annotations = newList(),
                    visibility = None,
                    kind = IFunc(decl = specFn),
                    span = item.span
                  )
                )
                bmodeSpecEmitted.add(specKey, true)
              }
              buildBModeCallSite(
                fn,
                aspect,
                callTarget,
                site,
                specName,
                info.cfgRecordName,
                info.referencedCfgFields,
                info.argsRecordName,
                info.argsRowFields,
                weaveDiags
              )
            } else {
              buildWrapper(fn, aspect, callTarget, site)
            }
            val wrapper = FunctionDecl(
              docComments = wrapper0.docComments,
              annotations = wrapper0.annotations,
              visibility = wrapper0.visibility,
              isAsync = wrapper0.isAsync,
              name = wrapperName,
              generics = wrapper0.generics,
              params = wrapper0.params,
              ret = wrapper0.ret,
              whereClause = wrapper0.whereClause,
              contracts = wrapper0.contracts,
              body = wrapper0.body,
              span = wrapper0.span
            )
            result.add(
              Item(
                docComments = item.docComments,
                annotations = item.annotations,
                visibility = item.visibility,
                kind = IFunc(decl = wrapper),
                span = item.span
              )
            )
            callTarget = wrapperName
            i = i + 1
          }
        }
      }
      case _ -> result.add(item)
    }
    idx = idx + 1
  }
  WeaveResult(items = result, diagnostics = weaveDiagsToDiagnostics(weaveDiags))
}

/// Weave aspect wrappers into an items list and drop the IAspect items.
/// Diagnostics from the weave (A0042 args-mismatch, A0043 unknown
/// `call.<field>`, A0044 `config.<no-default>`) are silently discarded.
///
/// **Limitation:** because this overload has no `SourceFile`, the
/// package-path is unknown — so the `call.qualifiedName` and
/// `call.modulePath` synthesised locals are populated from an empty
/// package string, and the `import Std.Time` auto-injection for
/// `call.elapsed` (#1298) cannot run (there is no import list to
/// extend — callers must ensure the import themselves, e.g. via
/// `injectWeaveImports`).  Callers that need correct values should
/// use `weaveFile` or `weaveFileWithDiags` instead.
pub func weaveItems(items: in List[Item]): List[Item] {
  weaveItemsCore(items, "").items
}

/// As `weaveItems` but also returns weave-time diagnostics.  Same
/// empty-package-path limitation applies; pass a non-empty string to
/// get correct `call.qualifiedName` / `call.modulePath` values, or
/// use `weaveFileWithDiags` if a `SourceFile` is available.
pub func weaveItemsWithDiags(items: in List[Item], packagePath: in String): WeaveResult {
  weaveItemsCore(items, packagePath)
}

/// Weave aspect wrappers into a SourceFile.  Identity-op when the
/// file has no aspects.  Diagnostics from the weave (A0042 args
/// mismatch on `@inline_template`, A0043 unknown `call.<field>`,
/// A0044 `config.<no-default>`) are silently dropped — callers that
/// need to surface them should use `weaveFileWithDiags` instead.
pub func weaveFile(file: in SourceFile): SourceFile {
  // Ensure `import Std.Time` before the items are rewritten — the
  // IAspect items (which carry the `call.elapsed` references the
  // pre-scan looks for) are dropped by the weave itself (#1298).
  val file0 = injectWeaveImports(file)
  val newItems = weaveItemsCore(file0.items, packagePathString(file0)).items
  SourceFile(
    moduleDoc = file0.moduleDoc,
    fileAnnotations = file0.fileAnnotations,
    packageDecl = file0.packageDecl,
    imports = file0.imports,
    items = newItems,
    span = file0.span
  )
}

/// Result of `weaveFileWithDiags`: the rewritten file plus any
/// weave-time diagnostics.
pub record WeaveFileResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
}

/// Weave a SourceFile and return any diagnostics raised during the
/// weave (#681 A0042 — `@inline_template` args.<field> mismatches).
/// Callers that want plain back-compat behaviour can continue using
/// `weaveFile`, which drops the diagnostic list.
///
/// Thin wrapper over `weaveFileWithDiagsAndTemplates` with an empty
/// template map (#3499): the single-file case is the no-cross-package
/// specialisation of the general multi-package weave.  `resolveFromInstances`
/// short-circuits to identity when there are no `from`-instances (and, when
/// there are, an empty map leaves every `from`-instance to be dropped by the
/// standard weave exactly as before), so this is behaviour-preserving.
pub func weaveFileWithDiags(file: in SourceFile): WeaveFileResult {
  val noTemplates: Map[String, CollectedTemplate] = newMap()
  weaveFileWithDiagsAndTemplates(file, noTemplates)
}

/// One `pub aspect` template collected by `collectAspectTemplates`, paired
/// with the GROUND TRUTH of whether its declaring `Item` carried
/// `@inline_template`.  `collectAspectTemplates` stores only the
/// `AspectDecl` half historically (annotations live on `Item`, which
/// isn't retained) — `isInlineTemplate` is captured at collection time so
/// `resolveFromInstanceItem` can restore the *actual* C-mode marker on a
/// resolved `from`-instance instead of guessing from body content
/// (`aspectTemplateIsCMode` is a body-content heuristic — a reasonable
/// proxy before B'-mode existed, since only a C-mode template could use
/// `args.<field>` at all, but wrong once a body using `args.<field>`
/// *without* `@inline_template` needs to be a hard error, A0046, rather
/// than a silent auto-promotion to C-mode — docs/55 §5 Phase 1).
pub record CollectedTemplate {
  decl: AspectDecl
  isInlineTemplate: Bool
}

/// Collect all `pub` aspect declarations that carry an `around` body from
/// `items` into `dest`, keyed by their fully-qualified name
/// (`pkgName + "." + decl.name`).  Called once per package before the
/// weave loop so cross-package `from` references can be resolved.  Only
/// `pub`-visibility aspects are collected — private/local aspects must not
/// be visible outside the package they are declared in.  Aspects without
/// an `around` body (`from`-instance forms) are skipped.
pub func collectAspectTemplates(items: in List[Item], pkgName: in String, dest: in Map[String, CollectedTemplate]): Unit {
  var i = 0
  while i < items.count {
    val it = items[i]
    match it.kind {
      case IAspect(decl) -> {
        match decl.around {
          case Some(_) -> {
            val isPub = match it.visibility { case Some(_) -> true; case None -> false }
            if isPub {
              val fqn = pkgName + "." + decl.name
              if not dest.containsKey(fqn) {
                dest.add(fqn, CollectedTemplate(decl = decl, isInlineTemplate = itemHasInlineTemplate(it)))
              }
            }
          }
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

/// Join a `from` path's segments into a dotted string used as the
/// template-lookup key in the `templates` map.
func resolveFromPath(path: in ModulePath): String {
  segmentsJoin(path.segments)
}

// Find a config field by name in a config-field list, or None.
func configFieldByName(cfg: in List[ConfigField], name: in String): Option[ConfigField] {
  var i = 0
  while i < cfg.count {
    if cfg[i].name == name {
      return Some(value = cfg[i])
    }
    i = i + 1
  }
  None
}

// Merge a `from`-instance's `config { }` overrides onto the template's config
// defaults: every template field is kept (with the instance's value when the
// instance overrides it), and any instance-only field is appended.  The old
// "instance replaces template wholesale when non-empty" behaviour dropped
// template fields the instance didn't mention (e.g. `enabled`, `field`),
// leaving them unwired and read as their zero value at runtime (#3543).
func mergeAspectConfig(tplCfg: in List[ConfigField], instCfg: in List[ConfigField]): List[ConfigField] {
  val result: List[ConfigField] = newList()
  var i = 0
  while i < tplCfg.count {
    val tf = tplCfg[i]
    match configFieldByName(instCfg, tf.name) {
      case Some(ov) -> result.add(ov)
      case None -> result.add(tf)
    }
    i = i + 1
  }
  var j = 0
  while j < instCfg.count {
    match configFieldByName(tplCfg, instCfg[j].name) {
      case Some(_) -> ()
      case None -> result.add(instCfg[j])
    }
    j = j + 1
  }
  result
}

// A `from`-template is C-mode (`@inline_template`) when its `around` body
// reads the matched function's arguments via the `args.<field>` keyword.
// `collectAspectTemplates` stores only the `AspectDecl` (not the declaring
// Item's annotations), so the `@inline_template` marker is lost during
// collection; reconstruct it from the body so the resolved instance gets the
// `args.<field>` rewrite (#3543).  The receiver scanned for is the literal
// `args` — the exact keyword `tryMemberRewrite` rewrites — NOT the
// `around(<name>)` binding (which is usually `call`).  Using the binding name
// (#3592) misclassified every template that merely calls `call.proceed()` as
// C-mode and, worse, missed a genuine C-mode template that reads `args.field`
// but never references the ambient `call`, regressing the #3543 NRE.
func aspectTemplateIsCMode(decl: in AspectDecl): Bool {
  match decl.around {
    case None -> false
    case Some(a) -> {
      val refs: Map[String, Bool] = newMap()
      collectMemberRefsBlock(a.body, "args", refs)
      refs.count > 0
    }
  }
}

/// docs/56 / D115 — true when every `args.<field>` the template's body
/// references is declared by a `where TArgs has { ... }` row clause on the
/// same `around` advice.  A template satisfying this is B'-mode-with-typed-
/// args, not C-mode: `collectBModeArgsFieldDiags` must not fire A0046 for
/// it (the per-match row-satisfaction check in `buildBModeCallSite` — A0047
/// — is the operative diagnostic instead).  A template with NO row clause
/// at all is never covered (every `args.<field>` reference falls through to
/// A0046, matching the pre-D115 behaviour).
func aspectArgsFullyRowCovered(decl: in AspectDecl): Bool {
  match decl.around {
    case None -> false
    case Some(a) -> {
      match a.argsRow {
        case None -> false
        case Some(rowFields) -> {
          val declared: Map[String, Bool] = newMap()
          var i = 0
          while i < rowFields.count {
            if not declared.containsKey(rowFields[i].name) {
              declared.add(rowFields[i].name, true)
            }
            i = i + 1
          }
          val refs: Map[String, Bool] = newMap()
          collectMemberRefsBlock(a.body, "args", refs)
          var allCovered = true
          for name in mapKeys(refs) {
            if not declared.containsKey(name) {
              allCovered = false
            }
          }
          allCovered
        }
      }
    }
  }
}

func annotationsHaveInlineTemplate(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    if annotationShortName(anns[i]) == "inline_template" {
      return true
    }
    i = i + 1
  }
  false
}

func mkInlineTemplateAnnotation(span: in Span): Annotation {
  Annotation(name = ModulePath(segments = singleSeg("inline_template"), span = span), args = newList(), span = span)
}

// Resolve a `from`-instance's template by its `from` path.  The qualified
// cross-package form (`from Lib.Aspects.X`) keys directly; the unqualified
// same-package form (`from X`) is registered under the declaring package's
// FQN (`pkgName.X`), so retry with the consuming package prefix when the
// as-written path misses (#3543).
func lookupFromTemplate(
  templates: in Map[String, CollectedTemplate], fqn: in String, pkgName: in String
): Option[CollectedTemplate] {
  match mapGet(templates, fqn) {
    case Some(t) -> Some(value = t)
    case None -> {
      if pkgName.length > 0 {
        mapGet(templates, pkgName + "." + fqn)
      } else {
        None
      }
    }
  }
}

/// Pre-process a `from`-instance aspect: when its template is found in
/// `templates`, replace it with a synthesised concrete aspect that takes the
/// template's `around` / `contracts` and the instance's `matches` /
/// `exceptNames` / `wraps` / `inside`. The effective `config` is the
/// template's defaults with the instance's `config { }` entries overlaid
/// (`mergeAspectConfig`), and the template's `@inline_template` marker is
/// propagated when the template was ACTUALLY declared `@inline_template`
/// (`CollectedTemplate.isInlineTemplate`, ground truth captured at
/// `collectAspectTemplates` time — not re-derived from body content, since
/// a B'-mode template whose body reads `args.<field>` without the
/// annotation must fail closed with A0046 rather than be silently
/// auto-promoted to C-mode; docs/55 §5 Phase 1). An unresolved `from`
/// reference (template absent from `templates`) is passed through
/// unchanged so the caller can decide whether to emit a diagnostic.
func resolveFromInstanceItem(
  it: in Item,
  instDecl: in AspectDecl,
  templates: in Map[String, CollectedTemplate],
  pkgName: in String,
): Item {
  match instDecl.around {
    case Some(_) -> it
    case None -> {
      match instDecl.from {
        case None -> it
        case Some(fromPath) -> {
          val fqn = resolveFromPath(fromPath)
          match lookupFromTemplate(templates, fqn, pkgName) {
            case None -> it
            case Some(tpl) -> {
              val tplDecl = tpl.decl
              val instCfg = instDecl.config
              val effectiveConfig = mergeAspectConfig(tplDecl.config, instCfg)
              val effective = AspectDecl(
                name = instDecl.name,
                from = instDecl.from,
                config = effectiveConfig,
                matches = instDecl.matches,
                exceptNames = instDecl.exceptNames,
                around = tplDecl.around,
                contracts = tplDecl.contracts,
                wraps = instDecl.wraps,
                inside = instDecl.inside,
                span = instDecl.span
              )
              // Propagate the template's `@inline_template` marker — lost
              // during `collectAspectTemplates` (which historically stored
              // only the decl) — so the resolved aspect's `args.<field>`
              // references are rewritten to the matched function's
              // parameters (#3543).
              val baseAnns = it.annotations
              val finalAnns = if tpl.isInlineTemplate and not annotationsHaveInlineTemplate(baseAnns) {
                val merged: List[Annotation] = newList()
                var ai = 0
                while ai < baseAnns.count {
                  merged.add(baseAnns[ai])
                  ai = ai + 1
                }
                merged.add(mkInlineTemplateAnnotation(it.span))
                merged
              } else {
                baseAnns
              }
              Item(
                docComments = it.docComments,
                annotations = finalAnns,
                visibility = it.visibility,
                kind = IAspect(decl = effective),
                span = it.span
              )
            }
          }
        }
      }
    }
  }
}

func hasFromInstance(items: in List[Item]): Bool {
  var fi = 0
  while fi < items.count {
    match items[fi].kind {
      case IAspect(aDecl) -> {
        match aDecl.from {
          case Some(_) -> {
            match aDecl.around {
              case None -> return true
              case Some(_) -> ()
            }
          }
          case None -> ()
        }
      }
      case _ -> ()
    }
    fi = fi + 1
  }
  false
}

func resolveFromInstances(
  items: in List[Item], templates: in Map[String, CollectedTemplate], pkgName: in String
): List[Item] {
  // Fast-path: if no from-instance exists in items, return the original list.
  if not hasFromInstance(items) {
    return items
  }
  val result: List[Item] = newList()
  var j = 0
  while j < items.count {
    val it = items[j]
    match it.kind {
      case IAspect(aDecl) -> {
        result.add(resolveFromInstanceItem(it, aDecl, templates, pkgName))
      }
      case _ -> result.add(it)
    }
    j = j + 1
  }
  result
}

/// Emit A0045 diagnostics for any `from`-instance aspects that remain
/// unresolved after `resolveFromInstances` — i.e., aspects with `from:
/// Some(path)` and `around: None` whose template was not found in the
/// supplied template map.  A missing template is a silent no-op without
/// this diagnostic, which violates the production-readiness standard.
func collectUnresolvedFromDiags(items: in List[Item]): List[Diagnostic] {
  val diags: List[Diagnostic] = newList()
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IAspect(aDecl) -> {
        match aDecl.from {
          case Some(fromPath) -> {
            match aDecl.around {
              case None -> {
                val pathStr0 = resolveFromPath(fromPath)
                val msg = "aspect '" + aDecl.name + "' declares `from " + pathStr0 + "` but the template was not found in the build; " +
                  "ensure the package that defines '" +
                  pathStr0 +
                  "' is listed as a path dependency (`path = \"...\"`) in [dependencies] in lyric.toml " +
                  "(cross-package template resolution currently requires a path dep and a .NET project build; " +
                  "NuGet/Maven deps and JVM project builds are not yet supported — see #3498)"
                diags.add(errorDiagnostic("A0045", msg, items[i].span))
              }
              case Some(_) -> ()
            }
          }
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  diags
}

// ─────────────────────────────────────────────────────────────────────────────
// §8b. B'-mode: cross-package aspect specialisation (docs/55).
//
// A resolved `from`-instance whose template lacks `@inline_template` is
// B'-mode by default (docs/27 §6.1).  Unlike C-mode, B'-mode never inlines
// the template body per matched function: it builds ONE specialised,
// ordinary (non-generic) function per distinct `(TArgs, TRet)` shape shared
// by every matched function of that shape — across every `from`-instance of
// the same template in this file — and each matched function gets a thin
// wrapper that calls the shared specialised function.  This is what buys
// B'-mode its dedup property over C-mode (which recompiles the body at
// every use site).
//
// Because the specialised function is shared, the ambient `call.<field>`
// values and `config.<field>` values (which differ per matched function /
// per `from`-instance) cannot be baked in as prelude-injected literal
// locals the way `buildCallPrelude` / `buildConfigPrelude` do for C-mode
// and local aspects — they must be threaded in as real parameters.  Two
// synthetic record types carry them: `__LyricBModeCallContext` (one, module-
// wide, covering every `call.<field>` the weaver recognises) and
// `__LyricBModeCfg_<template>` (one per template, whose fields are exactly
// the `config.<field>` names the template body references — instance-only
// config overrides the template body never reads are never part of the
// shared shape, so they can't make two instances of the same template
// diverge in cfg-record type).  `proceed` becomes a real
// `(T1,...,Tn) -> TRet` closure parameter (the strongly-typed lambda ABI,
// D113) rather than a static call substitution — `rewriteBlock`'s existing
// `proceed(args) -> callTargetName(p1,...,pn)` substitution already just
// emits a call to whatever identifier `callTargetName` names, so passing
// the fixed parameter name `__lyric_proceed` works unchanged; nothing in
// `rewriteBlock` / `RewriteCtx` needed to change.
//
// This is a weaver-native shape cache, not a `Lyric.Mono` call — see
// Q-bmode-* in docs/55 §6 and the decision-log entry backing this file's
// B'-mode support for why: `Lyric.Mono`'s specialiser instantiates a
// genuinely generic (`TVar`-typed) function AST at a call site; an
// aspect's `around` body is never itself generic-typed AST (it has no type
// parameters at all — the "genericity" is a weave-time fiction over the
// matched target's shape).  Reusing Mono here would mean synthesising a
// fake generic `FunctionDecl` purely to hand it back to a specialiser
// whose job is instantiating real generics, for no behavioural gain over
// a direct shape-keyed cache.  The shared cache below gets the identical
// "one specialised copy per distinct shape" guarantee with less machinery.
// ─────────────────────────────────────────────────────────────────────────────
/// Per-template B'-mode info, cached once per template the first time any
/// of its `from`-instances is woven in this file.
record BModeTemplateInfo {
  /// `None` when the template body references no `config.<field>` /
  /// bare-config-field name; `Some(recordName)` otherwise.
  cfgRecordName: Option[String]
  /// The subset of the template's declared `config { }` fields the body
  /// actually references — exactly the fields the shared cfg record
  /// carries, and exactly the fields every `from`-instance's call site
  /// must supply a value for, regardless of what the instance itself
  /// overrides or adds.
  referencedCfgFields: List[ConfigField]
  /// docs/56 / D115 — `None` when the template's `around` carries no
  /// `where TArgs has { ... }` row clause; `Some(recordName)` otherwise,
  /// naming the synthesised `__LyricBModeArgs_<template>` record type.
  argsRecordName: Option[String]
  /// The row clause's declared fields (empty when `argsRecordName` is
  /// `None`) — the args record's field schema, the rewrite ctx's
  /// `argsRowFields` set, and what each matched function's parameter list
  /// is checked against (A0047 on mismatch).
  argsRowFields: List[ArgsRowField]
}

/// Canonical name of the one call-context record type synthesised (lazily,
/// at most once per weave) into the consumer's item list.  Carries every
/// `call.<field>` the weaver recognises (`elapsed` excepted — that one
/// stays a per-invocation local exactly as it is for C-mode / local
/// aspects, since it's genuinely per-call state, not per-shape data).
func bmodeCallCtxRecordName(): String {
  "__LyricBModeCallContext"
}

func bmodeStringField(name: in String): RecordMember {
  val sp = synSpan()
  RMField(
    field = FieldDecl(
      docComments = newList(),
      annotations = newList(),
      visibility = Some(value = VisPub(span = sp)),
      isMutable = false,
      name = name,
      ty = TypeExpr(kind = TRef(path = ModulePath(segments = singleSeg("String"), span = sp)), span = sp),
      dflt = None,
      span = sp
    )
  )
}

func bmodeSliceStringField(name: in String): RecordMember {
  val sp = synSpan()
  RMField(
    field = FieldDecl(
      docComments = newList(),
      annotations = newList(),
      visibility = Some(value = VisPub(span = sp)),
      isMutable = false,
      name = name,
      ty = mkSliceTypeExpr("String"),
      dflt = None,
      span = sp
    )
  )
}

// Synthesised top-level declarations (records, specialised functions) each
// take the matched function's real span (`span`) rather than a shared zero
// span (`synSpan()`) — unlike statements/exprs *inside* an existing
// function body (where every wrapper in this file already reuses a zero
// span safely), a woven file can now carry SEVERAL brand-new top-level
// items in one weave (the call-context record, a per-template cfg record,
// one specialised function per shape) where previously at most one
// synthesised wrapper function ever existed per match.
func bmodeSynthCallCtxRecordItem(span: in Span): Item {
  val members: List[RecordMember] = newList()
  members.add(bmodeStringField("shortName"))
  members.add(bmodeStringField("qualifiedName"))
  members.add(bmodeStringField("modulePath"))
  members.add(bmodeStringField("sourceLocation"))
  members.add(bmodeSliceStringField("annotations"))
  members.add(bmodeStringField("aspectName"))
  val rd = RecordDecl(
    name = bmodeCallCtxRecordName(),
    generics = None,
    whereClause = None,
    members = members,
    span = span
  )
  Item(
    docComments = newList(),
    annotations = newList(),
    visibility = Some(value = VisPub(span = span)),
    kind = IRecord(decl = rd),
    span = span
  )
}

func bmodeSynthCfgRecordItem(recordName: in String, fields: in List[ConfigField], span: in Span): Item {
  val members: List[RecordMember] = newList()
  var i = 0
  while i < fields.count {
    val f = fields[i]
    members.add(
      RMField(
        field = FieldDecl(
          docComments = newList(),
          annotations = newList(),
          visibility = Some(value = VisPub(span = span)),
          isMutable = false,
          name = f.name,
          ty = f.ty,
          dflt = None,
          span = span
        )
      )
    )
    i = i + 1
  }
  val rd = RecordDecl(name = recordName, generics = None, whereClause = None, members = members, span = span)
  Item(
    docComments = newList(),
    annotations = newList(),
    visibility = Some(value = VisPub(span = span)),
    kind = IRecord(decl = rd),
    span = span
  )
}

/// `<paramName>.<field>` member-read expression at a zero span.
func mkCtxFieldRead(paramName: in String, field: in String): Expr {
  Expr(kind = EMember(receiver = singleSegPathExpr(paramName), memberName = field), span = synSpan())
}

/// `<name> = <value>` named call-arg node at a zero span, for `mkRecordCtor`.
func mkNamedArg(name: in String, value: in Expr): CallArg {
  CANamed(name = name, value = value, span = synSpan())
}

/// `<typeName>(<name1> = <expr1>, ...)` record-construction call at a zero
/// span.  Lyric has no distinct record-literal AST node — construction is
/// an ordinary `ECall` with named args against the type's own name.
///
/// Takes already-built `CANamed` args rather than `List[(String, Expr)]`
/// tuples — a heterogeneous tuple element type (`String` alongside `Expr`)
/// hits a self-hosted MSIL emitter stack-typing bug on tuple-list element
/// reads (tracked in #3943); building the named-arg AST node directly at
/// each call site avoids it.
func mkRecordCtor(typeName: in String, fields: in List[CallArg]): Expr {
  Expr(kind = ECall(fn = singleSegPathExpr(typeName), args = fields), span = synSpan())
}

func singleStmtList(s: in Statement): List[Statement] {
  val l: List[Statement] = newList()
  l.add(s)
  l
}

/// Mirrors `buildWrapper`'s own `targetReturnsUnit` check (kept as a
/// separate function rather than factored out of `buildWrapper` to avoid
/// touching that well-tested C-mode / local-aspect path at all).
func bmodeIsUnitReturn(ret: in Option[TypeExpr]): Bool {
  match ret {
    case None -> true
    case Some(te) -> {
      match te.kind {
        case TUnit -> true
        case TRef(mp) -> mp.segments.count == 1 and mp.segments[0] == "Unit"
        case _ -> false
      }
    }
  }
}

/// Canonicalise a `TypeExpr` into an identifier-safe fragment for shape-key
/// mangling.  Coverage mirrors `Lyric.ContractMeta.renderTypeExpr` (not
/// reusable here — it isn't `pub`) but every separator is an underscore
/// instead of the source-level punctuation, since the result feeds a
/// synthesised function name rather than re-parseable source.
func bmodeTypeExprKey(te: in TypeExpr): String {
  match te.kind {
    case TUnit -> "Unit"
    case TNever -> "Never"
    case TSelf -> "Self"
    case TRef(path) -> Str.replace(segmentsJoin(path.segments), ".", "_")
    case TGenericApp(h, args) -> Str.replace(segmentsJoin(h.segments), ".", "_") + "_of_" + bmodeTypeArgListKey(args)
    case TSlice(elem) -> "slice_" + bmodeTypeExprKey(elem)
    case TNullable(inner) -> bmodeTypeExprKey(inner) + "_opt"
    case TParen(inner) -> bmodeTypeExprKey(inner)
    case TArray(_, elem) -> "array_" + bmodeTypeExprKey(elem)
    case TTuple(ts) -> "tuple_" + bmodeTypeExprListKey(ts)
    case TFunction(ps, r) -> "fn_" + bmodeTypeExprListKey(ps) + "_to_" + bmodeTypeExprKey(r)
    case TRefined(p, _) -> Str.replace(segmentsJoin(p.segments), ".", "_")
    case TError -> "Unit"
  }
}

func bmodeTypeExprListKey(ts: in List[TypeExpr]): String {
  var s = ""
  var i = 0
  while i < ts.count {
    if i > 0 {
      s = s + "_"
    }
    s = s + bmodeTypeExprKey(ts[i])
    i = i + 1
  }
  s
}

func bmodeTypeArgListKey(args: in List[TypeArg]): String {
  var s = ""
  var i = 0
  while i < args.count {
    if i > 0 {
      s = s + "_"
    }
    match args[i] {
      case TAType(t) -> {
        s = s + bmodeTypeExprKey(t)
      }
      case TAValue(_) -> {
        s = s + "v"
      }
    }
    i = i + 1
  }
  s
}

/// `(TArgs, TRet)` shape key for a matched function's signature — the
/// specialisation identity B'-mode dedups on (docs/55 §3.2 point 2).
/// Q-bmode-001 (docs/55 §6) leaves structural-vs-nominal equality open;
/// this is nominal (two records with identical field layout but different
/// names key differently) — the conservative choice until that question
/// is resolved.
func bmodeShapeKey(params: in List[Param], ret: in Option[TypeExpr]): String {
  var s = ""
  var i = 0
  while i < params.count {
    if i > 0 {
      s = s + "__"
    }
    s = s + bmodeTypeExprKey(params[i].ty)
    i = i + 1
  }
  val retStr = match ret { case Some(t) -> bmodeTypeExprKey(t); case None -> "Unit" }
  if params.count > 0 {
    s = s + "___" + retStr
  } else {
    s = retStr
  }
  s
}

/// The template's own identity for specialisation-key / cfg-record-name
/// purposes: the `from` path exactly as the consumer wrote it.  Not fully
/// qualified/canonicalised — two `from`-instances that name the same
/// template with different spellings (e.g. one qualified, one relying on
/// same-package shorthand) key separately today.  Acceptable for a first
/// cut (tracked as part of Q-bmode-001); it only costs a missed dedup
/// opportunity, never incorrect behaviour.
func bmodeTemplateKey(fromPath: in ModulePath): String {
  resolveFromPath(fromPath)
}

/// Subset of `aspect.config` whose name the template body references,
/// either as `config.<name>` or bare `<name>` (mirrors the pre-scan
/// `buildConfigPrelude` performs for C-mode / local aspects).  This list is
/// the cfg record's field schema — instance-only config additions (config
/// fields an instance's `config { }` block adds that the template never
/// declared) are never included, so every `from`-instance of the same
/// template produces the identical cfg-record shape regardless of what
/// each instance overrides.
func computeReferencedConfigFields(aspect: in AspectDecl, body: in Block): List[ConfigField] {
  val refs: Map[String, Bool] = newMap()
  collectMemberRefsBlock(body, "config", refs)
  val fieldNames: Map[String, Bool] = newMap()
  var fnI = 0
  while fnI < aspect.config.count {
    if not fieldNames.containsKey(aspect.config[fnI].name) {
      fieldNames.add(aspect.config[fnI].name, true)
    }
    fnI = fnI + 1
  }
  collectBareRefsBlock(body, fieldNames, refs)
  val result: List[ConfigField] = newList()
  var i = 0
  while i < aspect.config.count {
    if refs.containsKey(aspect.config[i].name) {
      result.add(aspect.config[i])
    }
    i = i + 1
  }
  result
}

// docs/56 / D115 — the args-record's field schema is the `where TArgs has
// { ... }` row clause verbatim (not a body pre-scan like
// `computeReferencedConfigFields`): the row clause is the aspect author's
// explicit declaration of which fields it needs, checked once per
// specialisation-site match (the row-satisfaction check inlined in
// `buildBModeCallSite`) rather than inferred from usage.
func bmodeSynthArgsRecordItem(recordName: in String, fields: in List[ArgsRowField], span: in Span): Item {
  val members: List[RecordMember] = newList()
  var i = 0
  while i < fields.count {
    val f = fields[i]
    members.add(
      RMField(
        field = FieldDecl(
          docComments = newList(),
          annotations = newList(),
          visibility = Some(value = VisPub(span = span)),
          isMutable = false,
          name = f.name,
          ty = f.ty,
          dflt = None,
          span = span
        )
      )
    )
    i = i + 1
  }
  val rd = RecordDecl(name = recordName, generics = None, whereClause = None, members = members, span = span)
  Item(
    docComments = newList(),
    annotations = newList(),
    visibility = Some(value = VisPub(span = span)),
    kind = IRecord(decl = rd),
    span = span
  )
}

/// Look up (or lazily build) the `BModeTemplateInfo` for `templateKey`,
/// appending the synthesised cfg-record / args-record `Item`s to
/// `extraItems` (`result`, from the caller) the first time this template is
/// encountered.
func bmodeGetOrBuildTemplateInfo(
  cache: in Map[String, BModeTemplateInfo],
  templateKey: in String,
  aspect: in AspectDecl,
  extraItems: in List[Item],
  span: in Span,
): BModeTemplateInfo {
  match mapGet(cache, templateKey) {
    case Some(info) -> info
    case None -> {
      val around = match aspect.around {
        case Some(a) -> a
        case None -> AspectAround(argsName = "args", retName = None, argsRow = None, body = Block(statements = newList(), span = synSpan()), span = synSpan())
      }
      val referenced = computeReferencedConfigFields(aspect, around.body)
      val cfgRecordName: Option[String] = if referenced.count > 0 {
        Some(value = "__LyricBModeCfg_" + Str.replace(templateKey, ".", "_"))
      } else {
        None
      }
      match cfgRecordName {
        case Some(rn) -> extraItems.add(bmodeSynthCfgRecordItem(rn, referenced, span))
        case None -> ()
      }
      val rowFields: List[ArgsRowField] = match around.argsRow { case Some(fs) -> fs; case None -> newList() }
      val argsRecordName: Option[String] = if rowFields.count > 0 {
        Some(value = "__LyricBModeArgs_" + Str.replace(templateKey, ".", "_"))
      } else {
        None
      }
      match argsRecordName {
        case Some(rn) -> extraItems.add(bmodeSynthArgsRecordItem(rn, rowFields, span))
        case None -> ()
      }
      val info = BModeTemplateInfo(
        cfgRecordName = cfgRecordName,
        referencedCfgFields = referenced,
        argsRecordName = argsRecordName,
        argsRowFields = rowFields
      )
      cache.add(templateKey, info)
      info
    }
  }
}

/// `call.<field>` prelude for a shared B'-mode specialised function: same
/// lazy "only materialise what the body reads" shape as `buildCallPrelude`,
/// but every value (`elapsed` excepted) is read off the `ctxParamName`
/// parameter instead of baked in as a literal — the specialised function
/// has no single matched target to bake literals from.
func buildCallPreludeShared(body: in Block, ctxParamName: in String): (List[Statement], Map[String, Bool]) {
  val stmts: List[Statement] = newList()
  val present: Map[String, Bool] = newMap()
  val refs: Map[String, Bool] = newMap()
  collectCallRefsBlock(body, refs)
  if refs.count == 0 {
    return (stmts, present)
  }
  if refs.containsKey("shortName") {
    stmts.add(mkValStmt("__lyric_call_shortName", None, mkCtxFieldRead(ctxParamName, "shortName")))
    present.add("shortName", true)
  }
  if refs.containsKey("qualifiedName") {
    stmts.add(mkValStmt("__lyric_call_qualifiedName", None, mkCtxFieldRead(ctxParamName, "qualifiedName")))
    present.add("qualifiedName", true)
  }
  if refs.containsKey("modulePath") {
    stmts.add(mkValStmt("__lyric_call_modulePath", None, mkCtxFieldRead(ctxParamName, "modulePath")))
    present.add("modulePath", true)
  }
  if refs.containsKey("sourceLocation") {
    stmts.add(mkValStmt("__lyric_call_sourceLocation", None, mkCtxFieldRead(ctxParamName, "sourceLocation")))
    present.add("sourceLocation", true)
  }
  if refs.containsKey("annotations") {
    stmts.add(
      mkValStmt(
        "__lyric_call_annotations",
        Some(value = mkSliceTypeExpr("String")),
        mkCtxFieldRead(ctxParamName, "annotations")
      )
    )
    present.add("annotations", true)
  }
  if refs.containsKey("aspect") {
    stmts.add(mkValStmt("__lyric_call_aspect", None, mkCtxFieldRead(ctxParamName, "aspectName")))
    present.add("aspect", true)
  }
  if refs.containsKey("elapsed") {
    stmts.add(mkVarStmt("__lyric_call_elapsed", Some(value = mkOptionIntTypeExpr()), singleSegPathExpr("None")))
    present.add("elapsed", true)
  }
  return (stmts, present)
}

/// `config.<field>` prelude for a shared B'-mode specialised function:
/// every referenced field is read off `cfgParamName` (no panic-stub branch
/// — unlike `buildConfigPrelude`, "does this field have a resolved value"
/// is a per-call-site question here, checked where the cfg record is
/// constructed, not inside the shared body).
func buildConfigPreludeShared(
  aspect: in AspectDecl, body: in Block, cfgParamName: in String
): (List[Statement], Map[String, Bool]) {
  val referenced = computeReferencedConfigFields(aspect, body)
  val stmts: List[Statement] = newList()
  val materialised: Map[String, Bool] = newMap()
  var i = 0
  while i < referenced.count {
    val f = referenced[i]
    stmts.add(mkValStmt("__aspect_cfg_" + f.name, Some(value = f.ty), mkCtxFieldRead(cfgParamName, f.name)))
    materialised.add(f.name, true)
    i = i + 1
  }
  return (stmts, materialised)
}

/// Build the one specialised, ordinary (non-generic) function shared by
/// every matched function of shape `(paramTypes, retTy)` for this
/// template.  Mirrors `buildWrapper`'s body composition (config prelude ++
/// call prelude ++ rewritten body ++ out-variable lowering) but sources
/// `call`/`config` from parameters instead of literals, and routes
/// `proceed(...)` to the `__lyric_proceed` closure parameter instead of a
/// static call target — `rewriteBlock` needs no changes for either since
/// both substitutions are already just "reference to a name in scope."
func buildBModeSpecializedFunction(
  aspect: in AspectDecl,
  specName: in String,
  paramTypes: in List[TypeExpr],
  retTy: in Option[TypeExpr],
  targetReturnsUnit: in Bool,
  cfgRecordName: in Option[String],
  argsRecordName: in Option[String],
  span: in Span,
): FunctionDecl {
  val around = match aspect.around {
    case Some(a) -> a
    case None -> AspectAround(argsName = "args", retName = None, argsRow = None, body = Block(statements = newList(), span = synSpan()), span = synSpan())
  }

  val paramNames: List[String] = newList()
  val params: List[Param] = newList()
  var pi = 0
  while pi < paramTypes.count {
    val pname = "p" + toString(pi)
    paramNames.add(pname)
    params.add(
      Param(
        mode = PMIn,
        modeExplicit = false,
        name = pname,
        ty = paramTypes[pi],
        dflt = None,
        annotations = newList(),
        span = synSpan()
      )
    )
    pi = pi + 1
  }

  val (callStmts, callPresent) = buildCallPreludeShared(around.body, "__lyric_callctx")
  val (cfgStmts, cfgPresent) = buildConfigPreludeShared(aspect, around.body, "__lyric_cfg")
  val emptyNoDefault: Map[String, Bool] = newMap()
  val emptyDiags: List[WeaveDiagEntry] = newList()
  val argsRowFieldsMap: Map[String, Bool] = newMap()
  match around.argsRow {
    case Some(rowFields) -> {
      var ri = 0
      while ri < rowFields.count {
        if not argsRowFieldsMap.containsKey(rowFields[ri].name) {
          argsRowFieldsMap.add(rowFields[ri].name, true)
        }
        ri = ri + 1
      }
    }
    case None -> ()
  }

  val ctx = newRewriteCtx(
    "__lyric_proceed",
    paramNames,
    cfgPresent,
    emptyNoDefault,
    callPresent,
    targetReturnsUnit,
    false,
    argsRowFieldsMap,
    aspect.name,
    specName,
    emptyDiags
  )

  val rewiredBody = rewriteBlock(ctx, around.body)

  val assignsRet = match around.retName {
    case Some(retVar) -> blockAssignsToName(rewiredBody, retVar)
    case None -> false
  }
  val effectiveBody = match around.retName {
    case Some(retVar) -> {
      if assignsRet and targetReturnsUnit {
        stripRetAssignments(rewiredBody, retVar)
      } else {
        rewiredBody
      }
    }
    case None -> rewiredBody
  }

  val finalStmts: List[Statement] = newList()
  var i = 0
  while i < cfgStmts.count {
    finalStmts.add(cfgStmts[i])
    i = i + 1
  }
  i = 0
  while i < callStmts.count {
    finalStmts.add(callStmts[i])
    i = i + 1
  }
  i = 0
  while i < effectiveBody.statements.count {
    finalStmts.add(effectiveBody.statements[i])
    i = i + 1
  }

  val loweredStmts = match around.retName {
    case Some(retVar) -> {
      if assignsRet and not targetReturnsUnit {
        val withRet: List[Statement] = newList()
        withRet.add(mkVarStmtNoInit(retVar, retTy))
        var ri = 0
        while ri < finalStmts.count {
          withRet.add(finalStmts[ri])
          ri = ri + 1
        }
        withRet.add(Statement(kind = SReturn(value = Some(value = singleSegPathExpr(retVar))), span = synSpan()))
        withRet
      } else {
        finalStmts
      }
    }
    case None -> finalStmts
  }
  val finalBody = Block(statements = loweredStmts, span = synSpan())

  val retTyOrUnit = match retTy { case Some(t) -> t; case None -> TypeExpr(kind = TUnit, span = synSpan()) }
  val proceedTy = TypeExpr(kind = TFunction(parameters = paramTypes, retTy = retTyOrUnit), span = synSpan())
  params.add(
    Param(
      mode = PMIn,
      modeExplicit = false,
      name = "__lyric_callctx",
      ty = TypeExpr(
        kind = TRef(path = ModulePath(segments = singleSeg(bmodeCallCtxRecordName()), span = synSpan())),
        span = synSpan()
      ),
      dflt = None,
      annotations = newList(),
      span = synSpan()
    )
  )
  match cfgRecordName {
    case Some(rn) -> {
      params.add(
        Param(
          mode = PMIn,
          modeExplicit = false,
          name = "__lyric_cfg",
          ty = TypeExpr(kind = TRef(path = ModulePath(segments = singleSeg(rn), span = synSpan())), span = synSpan()),
          dflt = None,
          annotations = newList(),
          span = synSpan()
        )
      )
    }
    case None -> ()
  }
  match argsRecordName {
    case Some(rn) -> {
      params.add(
        Param(
          mode = PMIn,
          modeExplicit = false,
          name = "__lyric_args",
          ty = TypeExpr(kind = TRef(path = ModulePath(segments = singleSeg(rn), span = synSpan())), span = synSpan()),
          dflt = None,
          annotations = newList(),
          span = synSpan()
        )
      )
    }
    case None -> ()
  }
  params.add(
    Param(
      mode = PMIn,
      modeExplicit = false,
      name = "__lyric_proceed",
      ty = proceedTy,
      dflt = None,
      annotations = newList(),
      span = synSpan()
    )
  )

  FunctionDecl(
    docComments = newList(),
    annotations = newList(),
    visibility = None,
    isAsync = false,
    name = specName,
    generics = None,
    params = params,
    ret = retTy,
    whereClause = None,
    contracts = newList(),
    body = Some(value = FBBlock(block = finalBody)),
    span = span
  )
}

// Find a parameter of `params` named `name`, or `None`.
func bmodeFindParamByName(params: in List[Param], name: in String): Option[Param] {
  var i = 0
  while i < params.count {
    if params[i].name == name {
      return Some(value = params[i])
    }
    i = i + 1
  }
  None
}

/// Build the thin per-match wrapper that constructs the call-context /
/// cfg records and a `proceed` closure over `callTarget`, then calls the
/// shared specialised function `specName`.  Unlike `buildWrapper`, this
/// wrapper's body never touches `config`/`call`/`args` directly — those
/// all live inside the (already-built) specialised function.
func buildBModeCallSite(
  fn: in FunctionDecl,
  aspect: in AspectDecl,
  callTarget: in String,
  site: in WeaveSite,
  specName: in String,
  cfgRecordName: in Option[String],
  referencedCfgFields: in List[ConfigField],
  argsRecordName: in Option[String],
  argsRowFields: in List[ArgsRowField],
  weaveDiags: in List[WeaveDiagEntry],
): FunctionDecl {
  val qualified = if site.packagePath.length > 0 { site.packagePath + "." + fn.name } else { fn.name }
  val annNames: List[String] = newList()
  var ai = 0
  while ai < fn.annotations.count {
    annNames.add(annotationShortName(fn.annotations[ai]))
    ai = ai + 1
  }
  val locText = if site.packagePath.length > 0 {
    site.packagePath + ":" + toString(fn.span.startPos.line)
  } else {
    "<unknown>:" + toString(fn.span.startPos.line)
  }

  val ctxFields: List[CallArg] = newList()
  ctxFields.add(mkNamedArg("shortName", mkStringLit(fn.name)))
  ctxFields.add(mkNamedArg("qualifiedName", mkStringLit(qualified)))
  ctxFields.add(mkNamedArg("modulePath", mkStringLit(site.packagePath)))
  ctxFields.add(mkNamedArg("sourceLocation", mkStringLit(locText)))
  ctxFields.add(mkNamedArg("annotations", mkStringSliceLit(annNames)))
  ctxFields.add(mkNamedArg("aspectName", mkStringLit(aspect.name)))

  val stmts: List[Statement] = newList()
  stmts.add(mkValStmt("__lyric_callctx", None, mkRecordCtor(bmodeCallCtxRecordName(), ctxFields)))

  val callArgs: List[CallArg] = newList()
  var pj = 0
  while pj < fn.params.count {
    callArgs.add(CAPositional(expr = singleSegPathExpr(fn.params[pj].name)))
    pj = pj + 1
  }
  callArgs.add(CAPositional(expr = singleSegPathExpr("__lyric_callctx")))

  match cfgRecordName {
    case Some(rn) -> {
      val cfgFields: List[CallArg] = newList()
      var ci = 0
      while ci < referencedCfgFields.count {
        // `referencedCfgFields` is cached per templateKey (docs/55 §5) and
        // may carry a *different* from-instance's ConfigField objects — its
        // field *names* are template-invariant, but its `default` values are
        // only valid for the instance that first populated the cache.  Every
        // call site must re-resolve the default from THIS aspect's own
        // merged config (`aspect.config`, built by `mergeAspectConfig` in
        // `resolveFromInstanceItem`) or a sibling instance with a narrower
        // config override silently inherits an unrelated instance's values.
        val f = match configFieldByName(aspect.config, referencedCfgFields[ci].name) {
          case Some(cf) -> cf
          case None -> referencedCfgFields[ci]
        }
        val valExpr = match f.default {
          case Some(e) -> e
          case None -> {
            addWeaveDiagOnce(weaveDiags, WDConfigNoDefault, aspect.name, fn.name, f.name, fn.span)
            mkPanicCall(
              "config '" + f.name + "' has no default value and runtime env-var resolution is not yet wired (see todo/06 #683)"
            )
          }
        }
        cfgFields.add(mkNamedArg(f.name, valExpr))
        ci = ci + 1
      }
      stmts.add(mkValStmt("__lyric_cfg", None, mkRecordCtor(rn, cfgFields)))
      callArgs.add(CAPositional(expr = singleSegPathExpr("__lyric_cfg")))
    }
    case None -> ()
  }

  // docs/56 / D115 — row satisfaction: for each field the template's
  // `where TArgs has { ... }` clause declares, this specific matched
  // function must provide a same-named, same-typed parameter.  Checked
  // per match (not per shape) because two matched functions sharing a
  // `(TArgs, TRet)` positional shape (`bmodeShapeKey`) need not share
  // field *names*.  A0047 fires per unsatisfied field; the corresponding
  // named arg is omitted from the args-record construction so the
  // downstream type-checker also flags the incomplete record literal
  // (matching the A0042/A0043/A0044 "diagnostic is additive, weaving still
  // proceeds" convention).
  match argsRecordName {
    case Some(rn) -> {
      val argFields: List[CallArg] = newList()
      var ri = 0
      while ri < argsRowFields.count {
        val rf = argsRowFields[ri]
        match bmodeFindParamByName(fn.params, rf.name) {
          case Some(p) -> {
            if bmodeTypeExprKey(p.ty) == bmodeTypeExprKey(rf.ty) {
              argFields.add(mkNamedArg(rf.name, singleSegPathExpr(rf.name)))
            } else {
              addWeaveDiagOnce(weaveDiags, WDArgsRowMismatch, aspect.name, fn.name, rf.name, fn.span)
            }
          }
          case None -> addWeaveDiagOnce(weaveDiags, WDArgsRowMismatch, aspect.name, fn.name, rf.name, fn.span)
        }
        ri = ri + 1
      }
      stmts.add(mkValStmt("__lyric_args", None, mkRecordCtor(rn, argFields)))
      callArgs.add(CAPositional(expr = singleSegPathExpr("__lyric_args")))
    }
    case None -> ()
  }

  val lambdaParams: List[LambdaParam] = newList()
  val lambdaArgs: List[CallArg] = newList()
  var lp = 0
  while lp < fn.params.count {
    val lname = "q" + toString(lp)
    val qty = TypeExpr(kind = fn.params[lp].ty.kind, span = fn.params[lp].ty.span)
    lambdaParams.add(LambdaParam(name = lname, ty = Some(value = qty), span = synSpan()))
    lambdaArgs.add(CAPositional(expr = singleSegPathExpr(lname)))
    lp = lp + 1
  }
  val lambdaCallExpr = Expr(kind = ECall(fn = singleSegPathExpr(callTarget), args = lambdaArgs), span = synSpan())
  val lambdaBody = Block(
    statements = singleStmtList(Statement(kind = SExpr(expr = lambdaCallExpr), span = synSpan())),
    span = synSpan()
  )
  callArgs.add(
    CAPositional(expr = Expr(kind = ELambda(lambdaParams = lambdaParams, body = lambdaBody), span = synSpan()))
  )

  val specCallExpr = Expr(kind = ECall(fn = singleSegPathExpr(specName), args = callArgs), span = synSpan())
  if bmodeIsUnitReturn(fn.ret) {
    stmts.add(Statement(kind = SExpr(expr = specCallExpr), span = synSpan()))
  } else {
    stmts.add(Statement(kind = SReturn(value = Some(value = specCallExpr)), span = synSpan()))
  }

  val composed: List[ContractClause] = newList()
  var cci = 0
  while cci < aspect.contracts.count {
    composed.add(aspect.contracts[cci])
    cci = cci + 1
  }
  cci = 0
  while cci < fn.contracts.count {
    composed.add(fn.contracts[cci])
    cci = cci + 1
  }

  FunctionDecl(
    docComments = fn.docComments,
    annotations = newList(),
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = fn.params,
    ret = fn.ret,
    whereClause = fn.whereClause,
    contracts = composed,
    body = Some(value = FBBlock(block = Block(statements = stmts, span = synSpan()))),
    span = fn.span
  )
}

/// A0046: a `from`-instance resolved to a template that is NOT C-mode
/// (no `@inline_template`) whose body nonetheless references
/// `args.<field>` — B'-mode `args` is opaque (docs/27 §6.1.1), so this
/// would otherwise fall through to a confusing downstream "unknown name
/// 'args'" type error.  Reuses `aspectTemplateIsCMode`'s exact detector,
/// inverted, per docs/55 §5 Phase 1.  Weaving still proceeds afterward
/// (matching the established A0042/A0043/A0044 convention: the early
/// diagnostic is additive, not a hard stop) so the type-checker's own
/// position surfaces too.
func collectBModeArgsFieldDiags(items: in List[Item]): List[Diagnostic] {
  val diags: List[Diagnostic] = newList()
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IAspect(aDecl) -> {
        match aDecl.from {
          case Some(_) -> {
            if not itemHasInlineTemplate(items[i]) and aspectTemplateIsCMode(aDecl) and not aspectArgsFullyRowCovered(aDecl) {
              val msg = "aspect '" + aDecl.name + "' is B'-mode (no @inline_template) but its template body " +
                "references args.<field>; B'-mode `args` is opaque (docs/27 §6.1.1). Either mark the " +
                "library template `@inline_template` to opt into C-mode field access, declare the field(s) " +
                "in a `where TArgs has { ... }` row clause (docs/56), or remove the args.<field> reference " +
                "from the template body."
              diags.add(errorDiagnostic("A0046", msg, items[i].span))
            }
          }
          case None -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  diags
}

/// Weave a SourceFile with cross-package aspect template resolution (#3414).
/// Before running the standard weave, resolves `from`-instance aspects whose
/// templates are found in `templates` by synthesising concrete `AspectDecl`
/// values (template `around` + instance `matches`/`config` overrides).
/// Unresolved `from` references emit A0045 diagnostics; the standard weave
/// then drops them (they have no `around` body) so codegen sees only resolved
/// aspects.
pub func weaveFileWithDiagsAndTemplates(
  file: in SourceFile, templates: in Map[String, CollectedTemplate]
): WeaveFileResult {
  val file0 = injectWeaveImports(file)
  val pkgPath = packagePathString(file0)
  val resolvedItems = resolveFromInstances(file0.items, templates, pkgPath)
  val unresolvedDiags = collectUnresolvedFromDiags(resolvedItems)
  val bmodeArgsDiags = collectBModeArgsFieldDiags(resolvedItems)
  val wr = weaveItemsCore(resolvedItems, pkgPath)
  val allDiags: List[Diagnostic] = newList()
  var ui = 0
  while ui < unresolvedDiags.count {
    allDiags.add(unresolvedDiags[ui])
    ui = ui + 1
  }
  var bi = 0
  while bi < bmodeArgsDiags.count {
    allDiags.add(bmodeArgsDiags[bi])
    bi = bi + 1
  }
  var di = 0
  while di < wr.diagnostics.count {
    allDiags.add(wr.diagnostics[di])
    di = di + 1
  }
  val newFile = SourceFile(
    moduleDoc = file0.moduleDoc,
    fileAnnotations = file0.fileAnnotations,
    packageDecl = file0.packageDecl,
    imports = file0.imports,
    items = wr.items,
    span = file0.span
  )
  WeaveFileResult(file = newFile, diagnostics = allDiags)
}
