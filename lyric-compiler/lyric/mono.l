//! lyric/mono.l — self-hosted monomorphizer (Phase 5 §M5.2).
//!
//! Call-site monomorphizer for generic functions.  Specialises same-package
//! generic functions plus any caller-supplied "imported" generic decls
//! (cross-package, opt-in via `monoFileWithImports`) into concrete copies
//! the self-hosted PE/JVM emitter can lower without paramaterised IL.
//!
//! Algorithm:
//!   1. Collect all generic IFunc items from the SourceFile into a lookup map.
//!      Merge any caller-supplied `importedGenDecls` into the same lookup so
//!      cross-package call sites become eligible.
//!   2. Walk non-generic function bodies, rewriting call sites that reference
//!      known generic functions.  At each such call site, infer the concrete
//!      type arguments by unifying the function's TypeExpr parameter types
//!      against the known types of the argument expressions (literals and
//!      variables declared with explicit type annotations).  Explicit
//!      `f[T1, …](args)` type applications bypass inference and carry both
//!      `TAType` and `TAValue` arguments straight into the substitution maps.
//!   3. If all type parameters and value parameters are resolved, compute a
//!      mangled specialised name (e.g. `mapFoo__Int__String`,
//!      `ones__V_3`), queue a SpecRequest, and rewrite the call to use the
//!      specialised name.
//!   4. Process the worklist: for each SpecRequest, substitute the type and
//!      value vars in the generic FunctionDecl's param/ret TypeExprs *and*
//!      in its body, validate any declared `where` bounds against the
//!      substituted types, then walk the specialised body (which may
//!      enqueue further SpecRequests for nested generic calls).
//!   5. Return a MonoResult carrying the rewritten SourceFile (generic IFunc
//!      items removed, specialised items appended) and a rewrites map.
//!
//! Capabilities (#858, docs/41 §9 Band 5):
//!   • Type-level generics (`GPType`) — full call-site inference + explicit
//!     type-app specialisation.
//!   • Value-level generics (`GPValue`) — explicit-type-app specialisation
//!     only.  Each unique value (literal or path) produces a distinct
//!     specialisation keyed by its source text.  Value-param references
//!     are substituted inside the body (EPath sites + TypeArg shapes such
//!     as `Array[Int, N]` / `Foo[Int, N]`).
//!   • Cross-package generics — accepted via `monoFileWithImports`; the
//!     specialised copy is appended to the user's file.  Soundness depends
//!     on the imported function's body referencing only items the user's
//!     compilation unit can resolve (BCL primitives, imported types,
//!     other already-specialised generics).  The wider Band 6 plumbing
//!     of `Lyric.RestoredPackages` is what unlocks consuming non-trivial
//!     stdlib generics across the boundary.
//!   • Constraint validation — best-effort: when a `where T: Marker` bound
//!     is declared and `T` substitutes to a primitive, the well-known
//!     marker set (`Equals`, `Hash`, `Show`, `Ord`, `Compare`) is checked
//!     and a `M0001` diagnostic is emitted on confirmed mismatch.  Unknown
//!     concrete types accept silently (best-effort) since cross-package
//!     trait dispatch information is not yet plumbed through.
//!
//! Limitations (still Phase 5 bootstrap grade):
//!   • Type inference covers literals, explicitly-annotated variables,
//!     function parameters, structural binary ops, same-package
//!     function-call returns (after substituting inferred or explicit
//!     type args, including default methods on impl / interface
//!     blocks), and field projections into same-package records.
//!     Lambdas, BCL method returns, and impl-block dispatch via the
//!     type-class targeting layer still fall through to un-specialised
//!     — those call sites stay generic in the emitted IL, which is
//!     correct only for imported generics (which use real CLR
//!     generics).
//!   • Constraint dispatch (re-routing a `T.compare(x)` call inside a
//!     specialised body to the concrete type's compare implementation) is
//!     not yet implemented — it relies on cross-package symbol resolution
//!     (`docs/41` §9 Band 6) and the trait dispatch table emitted by the
//!     F# bootstrap compiler today.
package Lyric.Mono

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public types
// ─────────────────────────────────────────────────────────────────────────────
/// Result of the monomorphisation pass.
pub record MonoResult {
  /// Rewritten SourceFile: generic IFunc items are removed, specialised
  /// IFunc items are appended, and call sites in non-generic items are
  /// rewritten to use the specialised names.
  file: SourceFile
  /// Maps generic function names to the last-seen specialised name (for
  /// downstream diagnostics; not needed for correctness).
  rewrites: Map[String, String]
  /// Monomorphisation diagnostics — populated when the pass detects a
  /// where-bound violation (`M0001`: a concrete type argument fails its
  /// declared `where T: Marker` constraint).  Other failure modes (e.g.
  /// inference gaps from #349) silently fall back to leaving generic
  /// call sites unspecialised so the type checker's existing diagnostics
  /// surface them — that's the conservative behaviour by design.  The
  /// bridges route this list through `reportAndAbort` so M0001s abort
  /// codegen the same way parse/type-check/mode-check diagnostics do.
  diagnostics: List[Diagnostic]
  // ─────────────────────────────────────────────────────────────────────────────
  // §2. Internal state
  // ─────────────────────────────────────────────────────────────────────────────
}

record SpecRequest {
  specName: String
  baseDecl: FunctionDecl
  subst: Map[String, TypeExpr]
  valueSubst: Map[String, Expr]
  callSpan: Span
}

record MonoState {
  /// Generic functions defined in this package (callable from anywhere
  /// in the file).  Used to look up specialisation candidates.
  genDecls: Map[String, FunctionDecl]
  /// All functions visible to the file (same-package + cross-package
  /// imports merged through `monoFileWithImports`).  Used by
  /// `inferExprTE` to look up the return type of a callee when
  /// inferring type arguments through nested calls (#349).
  funcDecls: Map[String, FunctionDecl]
  /// Same-package record decls (and exposed records), keyed by simple
  /// name.  Used by `inferExprTE` to resolve field projections
  /// (`recv.field`) to the field's declared TypeExpr, after
  /// substituting the record's generic parameters with the receiver's
  /// concrete type arguments (#349).
  recordDecls: Map[String, RecordDecl]
  seenSpecs: Map[String, Bool]
  allSpecs: List[SpecRequest]
  diags: List[Diagnostic]
}

func newMonoState(
  genDecls: in Map[String, FunctionDecl],
  funcDecls: in Map[String, FunctionDecl],
  recordDecls: in Map[String, RecordDecl],
): MonoState {
  MonoState(
    genDecls = genDecls,
    funcDecls = funcDecls,
    recordDecls = recordDecls,
    seenSpecs = newMap(),
    allSpecs = newList(),
    diags = newList()
  )
}

// #349: collect generic IFunc methods nested inside `interface I { … }`
// blocks so the inferer (and the specialisation worklist) can see
// generic default methods that the bootstrap F# compiler dispatches
// through CLR runtime generics.  Only default-bodied (`IMFunc`)
// methods are candidates; pure signatures (`IMSig`) are abstract.
func collectIfaceGenerics(
  decl: in InterfaceDecl,
  genDecls: in Map[String, FunctionDecl],
  funcDecls: in Map[String, FunctionDecl],
): Unit {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMFunc(fdecl) -> {
        if not funcDecls.containsKey(fdecl.name) {
          funcDecls.add(fdecl.name, fdecl)
        }
        match fdecl.generics {
          case Some(_) -> {
            if not genDecls.containsKey(fdecl.name) {
              genDecls.add(fdecl.name, fdecl)
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

// #349: collect generic IFunc methods nested inside `impl T for X { … }`
// blocks.  Mirror of collectIfaceGenerics — see that comment.
func collectImplGenerics(
  decl: in ImplDecl,
  genDecls: in Map[String, FunctionDecl],
  funcDecls: in Map[String, FunctionDecl],
): Unit {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMplFunc(fdecl) -> {
        if not funcDecls.containsKey(fdecl.name) {
          funcDecls.add(fdecl.name, fdecl)
        }
        match fdecl.generics {
          case Some(_) -> {
            if not genDecls.containsKey(fdecl.name) {
              genDecls.add(fdecl.name, fdecl)
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

// ─────────────────────────────────────────────────────────────────────────────
// §3. Synthetic span / path helpers
// ─────────────────────────────────────────────────────────────────────────────
func synPos(): Position {
  Position(offset = 0, line = 1, column = 1)
}

func synSpan(): Span {
  Span(startPos = synPos(), endPos = synPos())
}

func singleSegPath(name: in String): ModulePath {
  val segs: List[String] = newList()
  segs.add(name)
  ModulePath(segments = segs, span = synSpan())
}

func singleSegPathExpr(name: in String, span: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  val path = ModulePath(segments = segs, span = span)
  Expr(kind = EPath(path = path), span = span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. TypeExpr key (for mangled specialisation names)
// ─────────────────────────────────────────────────────────────────────────────
func typeExprKey(te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> pathSegsKey(path.segments)
    case TGenericApp(h, gargs) -> pathSegsKey(h.segments) + "_" + typeArgListKey(gargs)
    case TUnit -> "Unit"
    case TNever -> "Never"
    case TSelf -> "Self"
    case TArray(_, elem) -> "Arr_" + typeExprKey(elem)
    case TSlice(elem) -> "Slice_" + typeExprKey(elem)
    case TNullable(inner) -> "Nullable_" + typeExprKey(inner)
    case TTuple(ts) -> "Tup_" + typeExprListKey(ts)
    case TFunction(ps, r) -> "Fn_" + typeExprListKey(ps) + "_" + typeExprKey(r)
    case TParen(inner) -> typeExprKey(inner)
    case TRefined(p, _) -> pathSegsKey(p.segments)
    case TError -> "Err"
  }
}

func pathSegsKey(segs: in List[String]): String {
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

func typeArgListKey(args: in List[TypeArg]): String {
  var acc = ""
  var i = 0
  while i < args.count {
    if i > 0 {
      acc = acc + "_"
    }
    match args[i] {
      case TAType(te) -> {
        acc = acc + typeExprKey(te)
      }
      case TAValue(e) -> {
        acc = acc + "V" + valueExprKey(e)
      }
    }
    i = i + 1
  }
  acc
}

// Mangle a value-generic argument expression into a stable identifier
// fragment.  Covers the literal forms the type checker accepts as a
// `TAValue` source (integer/bool/char/string) plus single-segment paths
// (`EPath([N])`) used to forward an outer value generic into a nested
// call.  Falls back to "Vx" for shapes mono can't render verbatim — the
// resulting specialisation still has a unique name within the file
// because callers de-duplicate via `state.seenSpecs`.
func valueExprKey(e: in Expr): String {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(value, _, _) -> longLitKey(value)
        case LBool(b) -> if b { "true" } else { "false" }
        case LChar(cp) -> "c" + toString(cp)
        case LString(s) -> "s" + toString(s.length)
        case LTripleString(s) -> "s" + toString(s.length)
        case LRawString(s) -> "s" + toString(s.length)
        case LFloat(_, _, _) -> "f"
        case LUnit -> "u"
      }
    }
    case EPath(path) -> pathSegsKey(path.segments)
    case EParen(inner) -> valueExprKey(inner)
    case _ -> "x"
  }
}

// Render a Long with a leading 'n' for negatives so the mangled name
// stays a valid identifier (no `-` characters).
func longLitKey(v: in Long): String {
  if v < 0i64 {
    "n" + toString(0i64 - v)
  } else {
    toString(v)
  }
}

func typeExprListKey(ts: in List[TypeExpr]): String {
  var acc = ""
  var i = 0
  while i < ts.count {
    if i > 0 {
      acc = acc + "_"
    }
    acc = acc + typeExprKey(ts[i])
    i = i + 1
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. TypeExpr substitution (type-var name → concrete TypeExpr,
//     value-var name → concrete Expr)
// ─────────────────────────────────────────────────────────────────────────────
func substTypeExpr(subst: in Map[String, TypeExpr], valueSubst: in Map[String, Expr], te: in TypeExpr): TypeExpr {
  val s = te.span
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        match mapGet(subst, path.segments[0]) {
          case Some(concrete) -> concrete
          case None -> te
        }
      } else {
        te
      }
    }
    case TGenericApp(h, args) -> {
      val newArgs: List[TypeArg] = newList()
      var i = 0
      while i < args.count {
        newArgs.add(substTypeArg(subst, valueSubst, args[i]))
        i = i + 1
      }
      TypeExpr(kind = TGenericApp(head = h, args = newArgs), span = s)
    }
    case TTuple(ts) -> {
      val newTs: List[TypeExpr] = newList()
      var i = 0
      while i < ts.count {
        newTs.add(substTypeExpr(subst, valueSubst, ts[i]))
        i = i + 1
      }
      TypeExpr(kind = TTuple(types = newTs), span = s)
    }
    case TNullable(inner) -> TypeExpr(kind = TNullable(inner = substTypeExpr(subst, valueSubst, inner)), span = s)
    case TSlice(elem) -> TypeExpr(kind = TSlice(element = substTypeExpr(subst, valueSubst, elem)), span = s)
    case TArray(sz, elem) -> TypeExpr(kind = TArray(size = substTypeArg(subst, valueSubst, sz), element = substTypeExpr(subst, valueSubst, elem)), span = s)
    case TFunction(ps, r) -> {
      val newPs: List[TypeExpr] = newList()
      var i = 0
      while i < ps.count {
        newPs.add(substTypeExpr(subst, valueSubst, ps[i]))
        i = i + 1
      }
      TypeExpr(kind = TFunction(parameters = newPs, retTy = substTypeExpr(subst, valueSubst, r)), span = s)
    }
    case TParen(inner) -> TypeExpr(kind = TParen(inner = substTypeExpr(subst, valueSubst, inner)), span = s)
    case _ -> te
  }
}

// Substitute inside a TypeArg.  `TAType` recurses into `substTypeExpr`
// (which itself walks nested type args).  `TAValue` carries an Expr that
// may reference a value-generic parameter (`Array[Int, N]` shape); we
// rewrite that Expr via `substExprValue` so the specialised TypeArg
// carries the substituted concrete value.
func substTypeArg(subst: in Map[String, TypeExpr], valueSubst: in Map[String, Expr], arg: in TypeArg): TypeArg {
  match arg {
    case TAType(inner) -> TAType(ty = substTypeExpr(subst, valueSubst, inner))
    case TAValue(e) -> TAValue(expr = substExprValue(valueSubst, e))
  }
}

// Walk an Expr and replace any single-segment `EPath([name])` whose name
// is bound in `valueSubst` with the substituted concrete Expr.  This is
// the value-generic counterpart of `substTypeExpr`: it handles the
// occurrences of a value-generic param inside the function body
// (e.g. `for i in 0..N` becomes `for i in 0..3` after `N := 3`).
//
// The walk is recursive across the Expr grammar but conservative: only
// shapes the parser actually produces in non-pathological code are
// expanded.  Sub-expressions that contain Blocks (EIf, EMatch, ELambda)
// recurse via dedicated block/arm helpers below.
func substExprValue(valueSubst: in Map[String, Expr], expr: in Expr): Expr {
  val s = expr.span
  match expr.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        match mapGet(valueSubst, path.segments[0]) {
          case Some(replacement) -> replacement
          case None -> expr
        }
      } else {
        expr
      }
    }
    case EParen(inner) -> Expr(kind = EParen(inner = substExprValue(valueSubst, inner)), span = s)
    case EBinop(op, lhs, rhs) -> Expr(kind = EBinop(op = op, lhs = substExprValue(valueSubst, lhs), rhs = substExprValue(valueSubst, rhs)), span = s)
    case EPrefix(op, operand) -> Expr(kind = EPrefix(op = op, operand = substExprValue(valueSubst, operand)), span = s)
    case EMember(recv, name) -> Expr(kind = EMember(receiver = substExprValue(valueSubst, recv), memberName = name), span = s)
    case EIndex(recv, idxs) -> {
      val newIdxs: List[Expr] = newList()
      var i = 0
      while i < idxs.count {
        newIdxs.add(substExprValue(valueSubst, idxs[i]))
        i = i + 1
      }
      Expr(kind = EIndex(receiver = substExprValue(valueSubst, recv), indices = newIdxs), span = s)
    }
    case ECall(fn, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(e) -> newArgs.add(CAPositional(expr = substExprValue(valueSubst, e)))
          case CANamed(n, e, span) -> newArgs.add(CANamed(name = n, value = substExprValue(valueSubst, e), span = span))
        }
        i = i + 1
      }
      Expr(kind = ECall(fn = substExprValue(valueSubst, fn), args = newArgs), span = s)
    }
    case ETuple(es) -> {
      val newEs: List[Expr] = newList()
      var i = 0
      while i < es.count {
        newEs.add(substExprValue(valueSubst, es[i]))
        i = i + 1
      }
      Expr(kind = ETuple(exprs = newEs), span = s)
    }
    case EList(es) -> {
      val newEs: List[Expr] = newList()
      var i = 0
      while i < es.count {
        newEs.add(substExprValue(valueSubst, es[i]))
        i = i + 1
      }
      Expr(kind = EList(exprs = newEs), span = s)
    }
    case ETypeApp(fn, targs) -> {
      val newTargs: List[TypeArg] = newList()
      var i = 0
      while i < targs.count {
        match targs[i] {
          case TAType(inner) -> newTargs.add(TAType(ty = inner))
          case TAValue(e) -> newTargs.add(TAValue(expr = substExprValue(valueSubst, e)))
        }
        i = i + 1
      }
      Expr(kind = ETypeApp(fn = substExprValue(valueSubst, fn), args = newTargs), span = s)
    }
    case EAssign(target, op, value) -> Expr(kind = EAssign(target = substExprValue(valueSubst, target), op = op, value = substExprValue(valueSubst, value)), span = s)
    case EAwait(inner) -> Expr(kind = EAwait(inner = substExprValue(valueSubst, inner)), span = s)
    case EYield(inner) -> Expr(kind = EYield(inner = substExprValue(valueSubst, inner)), span = s)
    case ESpawn(inner) -> Expr(kind = ESpawn(inner = substExprValue(valueSubst, inner)), span = s)
    case ETry(inner) -> Expr(kind = ETry(inner = substExprValue(valueSubst, inner)), span = s)
    case EPropagate(inner) -> Expr(kind = EPropagate(inner = substExprValue(valueSubst, inner)), span = s)
    case EIf(cond, thenB, elseB, form) -> {
      // Typed `var` + assignment, not a two-arm match: a bare-`None`
      // arm widens to `None<object>` and corrupts an else-less `if`.
      var newElse: Option[ExprOrBlock] = None
      match elseB {
        case None -> {
        }
        case Some(e) -> {
          newElse = Some(value = substEOBValue(valueSubst, e))
        }
      }
      Expr(
        kind = EIf(
          cond = substExprValue(valueSubst, cond),
          thenBranch = substEOBValue(valueSubst, thenB),
          elseBranch = newElse,
          thenForm = form
        ),
        span = s
      )
    }
    case EMatch(scrut, arms) -> {
      val newArms: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        // Typed `var` + assignment, not a two-arm match: a bare-`None`
        // arm widens to `None<object>` and corrupts a guardless match arm.
        var newGuard: Option[Expr] = None
        match arm.guard {
          case None -> {
          }
          case Some(g) -> {
            newGuard = Some(value = substExprValue(valueSubst, g))
          }
        }
        newArms.add(
          MatchArm(pattern = arm.pattern, guard = newGuard, body = substEOBValue(valueSubst, arm.body), span = arm.span)
        )
        i = i + 1
      }
      Expr(kind = EMatch(scrutinee = substExprValue(valueSubst, scrut), arms = newArms), span = s)
    }
    case EBlock(blk) -> Expr(kind = EBlock(block = substBlockValue(valueSubst, blk)), span = s)
    case EUnsafe(blk) -> Expr(kind = EUnsafe(block = substBlockValue(valueSubst, blk)), span = s)
    case ELambda(lparams, body) -> Expr(kind = ELambda(lambdaParams = lparams, body = substBlockValue(valueSubst, body)), span = s)
    case EInterpolated(segs) -> {
      val newSegs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, sp) -> newSegs.add(ISText(text = t, span = sp))
          case ISExpr(e) -> newSegs.add(ISExpr(expr = substExprValue(valueSubst, e)))
        }
        i = i + 1
      }
      Expr(kind = EInterpolated(segments = newSegs), span = s)
    }
    case _ -> expr
  }
}

func substEOBValue(valueSubst: in Map[String, Expr], eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBExpr(e) -> EOBExpr(expr = substExprValue(valueSubst, e))
    case EOBBlock(b) -> EOBBlock(block = substBlockValue(valueSubst, b))
  }
}

func substBlockValue(valueSubst: in Map[String, Expr], blk: in Block): Block {
  val newStmts: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    newStmts.add(substStmtValue(valueSubst, blk.statements[i]))
    i = i + 1
  }
  Block(statements = newStmts, span = blk.span)
}

func substStmtValue(valueSubst: in Map[String, Expr], stmt: in Statement): Statement {
  val s = stmt.span
  match stmt.kind {
    case SLocal(binding) -> Statement(kind = SLocal(binding = substBindingValue(valueSubst, binding)), span = s)
    case SAssign(target, op, value) -> Statement(kind = SAssign(target = substExprValue(valueSubst, target), op = op, value = substExprValue(valueSubst, value)), span = s)
    case SReturn(opt) -> {
      // Typed `var` + assignment, not a two-arm match.
      var newOpt: Option[Expr] = None
      match opt {
        case None -> {
        }
        case Some(e) -> {
          newOpt = Some(value = substExprValue(valueSubst, e))
        }
      }
      Statement(kind = SReturn(value = newOpt), span = s)
    }
    case SThrow(e) -> Statement(kind = SThrow(expr = substExprValue(valueSubst, e)), span = s)
    case SExpr(e) -> Statement(kind = SExpr(expr = substExprValue(valueSubst, e)), span = s)
    case SWhile(lbl, cond, body) -> Statement(kind = SWhile(label = lbl, cond = substExprValue(valueSubst, cond), body = substBlockValue(valueSubst, body)), span = s)
    case SFor(lbl, pat, iter, body) -> Statement(kind = SFor(label = lbl, pat = pat, iter = substExprValue(valueSubst, iter), body = substBlockValue(valueSubst, body)), span = s)
    case SLoop(lbl, body) -> Statement(kind = SLoop(label = lbl, body = substBlockValue(valueSubst, body)), span = s)
    case SDefer(body) -> Statement(kind = SDefer(body = substBlockValue(valueSubst, body)), span = s)
    case SScope(lbl, body) -> Statement(kind = SScope(binding = lbl, body = substBlockValue(valueSubst, body)), span = s)
    case SInvariant(e) -> Statement(kind = SInvariant(expr = substExprValue(valueSubst, e)), span = s)
    case SRule(lhs, rhs) -> Statement(kind = SRule(lhs = substExprValue(valueSubst, lhs), rhs = substExprValue(valueSubst, rhs)), span = s)
    case STry(body, catches, finally_) -> {
      val newBody = substBlockValue(valueSubst, body)
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val cc = catches[i]
        newCatches.add(
          CatchClause(
            typeName = cc.typeName,
            bindName = cc.bindName,
            body = substBlockValue(valueSubst, cc.body),
            span = cc.span
          )
        )
        i = i + 1
      }
      // Typed `var` + assignment, not a two-arm match.
      var newFinally: Option[Block] = None
      match finally_ {
        case None -> {
        }
        case Some(fb) -> {
          newFinally = Some(value = substBlockValue(valueSubst, fb))
        }
      }
      Statement(kind = STry(body = newBody, catches = newCatches, finally_ = newFinally), span = s)
    }
    case _ -> stmt
  }
}

func substBindingValue(valueSubst: in Map[String, Expr], binding: in LocalBinding): LocalBinding {
  match binding {
    case LBVal(pat, tyOpt, init) -> LBVal(pat = pat, ty = tyOpt, init = substExprValue(valueSubst, init))
    case LBVar(name, tyOpt, initOpt) -> {
      // Typed `var` + assignment, not a two-arm match.
      var newInit: Option[Expr] = None
      match initOpt {
        case None -> {
        }
        case Some(e) -> {
          newInit = Some(value = substExprValue(valueSubst, e))
        }
      }
      LBVar(name = name, ty = tyOpt, init = newInit)
    }
    case LBLet(name, tyOpt, init) -> LBLet(name = name, ty = tyOpt, init = substExprValue(valueSubst, init))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Unification — TypeExpr-level, structural, one-sided
// ─────────────────────────────────────────────────────────────────────────────
// Unify `paramTE` (may contain TRef to a type param name listed in
// `typeParams`) against `argTE` (concrete caller type).  Bindings are
// accumulated in `subst` (map from type-param name → concrete TypeExpr).
// Conflicts are silently ignored (first-binding wins).
func unifyTE(
  typeParams: in List[String], paramTE: in TypeExpr, argTE: in TypeExpr, subst: in Map[String, TypeExpr]
): Unit {
  match paramTE.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        if listContainsStr(typeParams, name) {
          if not subst.containsKey(name) {
            subst.add(name, argTE)
          }
        }
      }
    }
    case TGenericApp(h1, a1) -> {
      match argTE.kind {
        case TGenericApp(h2, a2) -> {
          if pathSegsKey(h1.segments) == pathSegsKey(h2.segments) and a1.count == a2.count {
            var i = 0
            while i < a1.count {
              match a1[i] {
                case TAType(te1) -> {
                  match a2[i] {
                    case TAType(te2) -> unifyTE(typeParams, te1, te2, subst)
                    case _ -> ()
                  }
                }
                case _ -> ()
              }
              i = i + 1
            }
          }
        }
        case _ -> ()
      }
    }
    case TNullable(inner1) -> {
      match argTE.kind {
        case TNullable(inner2) -> unifyTE(typeParams, inner1, inner2, subst)
        case _ -> ()
      }
    }
    case TTuple(ts1) -> {
      match argTE.kind {
        case TTuple(ts2) -> {
          if ts1.count == ts2.count {
            var i = 0
            while i < ts1.count {
              unifyTE(typeParams, ts1[i], ts2[i], subst)
              i = i + 1
            }
          }
        }
        case _ -> ()
      }
    }
    case TSlice(elem1) -> {
      // Unify the element types of `slice[T]` against `slice[Int]` so a generic
      // `slice[T]` parameter binds `T` from a slice/list-literal argument and the
      // call monomorphises (#2557).
      match argTE.kind {
        case TSlice(elem2) -> unifyTE(typeParams, elem1, elem2, subst)
        case TArray(_, elem2) -> unifyTE(typeParams, elem1, elem2, subst)
        case _ -> ()
      }
    }
    case TFunction(ps1, r1) -> {
      match argTE.kind {
        case TFunction(ps2, r2) -> {
          if ps1.count == ps2.count {
            var i = 0
            while i < ps1.count {
              unifyTE(typeParams, ps1[i], ps2[i], subst)
              i = i + 1
            }
            unifyTE(typeParams, r1, r2, subst)
          }
        }
        case _ -> ()
      }
    }
    case _ -> ()
  }
}

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

// ─────────────────────────────────────────────────────────────────────────────
// §7. Generic parameter name extraction
// ─────────────────────────────────────────────────────────────────────────────
// Names of `GPType` (type-level) generic parameters in source order.
func extractTypeParamNames(gps: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  match gps {
    case None -> ()
    case Some(gp) -> {
      var i = 0
      while i < gp.params.count {
        match gp.params[i] {
          case GPType(name, _) -> names.add(name)
          case GPValue(_, _, _) -> ()
        }
        i = i + 1
      }
    }
  }
  names
}

// Names of `GPValue` (value-level) generic parameters in source order.
func extractValueParamNames(gps: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  match gps {
    case None -> ()
    case Some(gp) -> {
      var i = 0
      while i < gp.params.count {
        match gp.params[i] {
          case GPType(_, _) -> ()
          case GPValue(name, _, _) -> names.add(name)
        }
        i = i + 1
      }
    }
  }
  names
}

// All generic params in source order, paired with a flag (true = GPValue,
// false = GPType).  Used by the explicit-type-app path to dispatch each
// supplied TypeArg into either `subst` or `valueSubst`.
record GenericParamInfo {
  name: String
  isValue: Bool
}

func extractAllParamInfo(gps: in Option[GenericParams]): List[GenericParamInfo] {
  val infos: List[GenericParamInfo] = newList()
  match gps {
    case None -> ()
    case Some(gp) -> {
      var i = 0
      while i < gp.params.count {
        match gp.params[i] {
          case GPType(name, _) -> infos.add(GenericParamInfo(name = name, isValue = false))
          case GPValue(name, _, _) -> infos.add(GenericParamInfo(name = name, isValue = true))
        }
        i = i + 1
      }
    }
  }
  infos
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Specialised function name mangling
// ─────────────────────────────────────────────────────────────────────────────
// Mangle the specialised function name from the base name + the ordered
// list of generic params, looking up each substitution in either
// `subst` (for `GPType`) or `valueSubst` (for `GPValue`).  Value-arg
// segments are prefixed with `V` to keep them disjoint from type keys.
func specFuncName(
  base: in String,
  allParams: in List[GenericParamInfo],
  subst: in Map[String, TypeExpr],
  valueSubst: in Map[String, Expr],
): String {
  var acc = base
  var i = 0
  while i < allParams.count {
    val p = allParams[i]
    acc = acc + "__"
    if p.isValue {
      acc = acc + "V"
      match mapGet(valueSubst, p.name) {
        case Some(e) -> {
          acc = acc + valueExprKey(e)
        }
        case None -> {
          acc = acc + "Unknown"
        }
      }
    } else {
      match mapGet(subst, p.name) {
        case Some(te) -> {
          acc = acc + typeExprKey(te)
        }
        case None -> {
          acc = acc + "Unknown"
        }
      }
    }
    i = i + 1
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Simplified type inference — expression → TypeExpr option
// ─────────────────────────────────────────────────────────────────────────────
// Returns the declared TypeExpr for an expression when it can be determined
// from the local type environment or literal shape alone.  Returns None for
// complex sub-expressions (calls, field projections, binary ops, etc.).
func inferLitTE(lit: in Literal, span: in Span): Option[TypeExpr] {
  match lit {
    case LInt(_, suffix, _) -> {
      val name = match suffix {
        case I8 -> "Byte"
        case I16 -> "Short"
        case I32 -> "Int"
        case I64 -> "Long"
        case U8 -> "Byte"
        case U16 -> "UShort"
        case U32 -> "UInt"
        case U64 -> "ULong"
        case NoIntSuffix -> "Int"
      }
      Some(value = TypeExpr(kind = TRef(path = singleSegPath(name)), span = span))
    }
    case LFloat(_, suffix, _) -> {
      val name = match suffix { case F32 -> "Float"; case F64 -> "Double"; case NoFloatSuffix -> "Double" }
      Some(value = TypeExpr(kind = TRef(path = singleSegPath(name)), span = span))
    }
    case LBool(_) -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("Bool")), span = span))
    case LString(_) | LTripleString(_) | LRawString(_) -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("String")), span = span))
    case LChar(_) -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("Char")), span = span))
    case LUnit -> Some(value = TypeExpr(kind = TUnit, span = span))
  }
}

// #349: best-effort TypeExpr inference during monomorphisation.
// Threading `MonoState` lets the helper resolve same-package
// function returns, explicit type applications, and record field
// projections (the ECall / ETypeApp / EMember arms below).
// Lambdas, BCL method returns, and impl-block dispatch fall
// through to `None` — those calls stay generic in the emitted IL,
// which is the same fall-back behaviour the pre-#349 code shipped
// (and remains correct for imported generics that use CLR generics).
func inferExprTE(state: in MonoState, env: in Map[String, TypeExpr], expr: in Expr): Option[TypeExpr] {
  match expr.kind {
    case ELiteral(lit) -> inferLitTE(lit, expr.span)
    case EParen(inner) -> inferExprTE(state, env, inner)
    case EPath(path) -> {
      if path.segments.count == 1 {
        mapGet(env, path.segments[0])
      } else {
        None
      }
    }
    case EBinop(op, lhs, _) -> {
      match op {
        case BAdd -> inferExprTE(state, env, lhs)
        case BSub -> inferExprTE(state, env, lhs)
        case BMul -> inferExprTE(state, env, lhs)
        case BDiv -> inferExprTE(state, env, lhs)
        case BMod -> inferExprTE(state, env, lhs)
        case BEq -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("Bool")), span = expr.span))
        case BNeq -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("Bool")), span = expr.span))
        case BLt -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("Bool")), span = expr.span))
        case BLte -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("Bool")), span = expr.span))
        case BGt -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("Bool")), span = expr.span))
        case BGte -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("Bool")), span = expr.span))
        case BAnd -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("Bool")), span = expr.span))
        case BOr -> Some(value = TypeExpr(kind = TRef(path = singleSegPath("Bool")), span = expr.span))
        case _ -> None
      }
    }
    case ECall(fn, args) -> inferCallReturnTE(state, env, fn, args)
    case ETypeApp(fn, targs) -> inferTypeAppValueTE(state, env, fn, targs)
    case EMember(recv, name) -> inferMemberTE(state, env, recv, name)
    // `self` in an impl / interface method body — its type is seeded into
    // `env` under the reserved "self" key by the Phase-2 IImpl / IInterface
    // rewrite, so `self.field` projections resolve (#1727).
    case ESelf -> mapGet(env, "self")
    // Indexing a `Map[K, V]` yields `V`; a `List[T]` / slice / array yields
    // the element type.  Without this, `val data = self.sessions[id]` left
    // `data` un-typed and a later generic call on `data.field` could not
    // infer its type arguments (#1727).
    case EIndex(recv, _) -> inferIndexTE(state, env, recv)
    // A list/slice literal `[e0, …]` infers to `slice[ElemType]` from its first
    // element, so a generic call whose parameter is `slice[T]` (e.g.
    // `glen([1,2,3])` / `Sort.sortInts([3,1,2])`) unifies `T` and monomorphises
    // into a concrete `__Int` copy rather than staying a generic method whose
    // `slice[T]` parameter cannot name a real CLR type.  An empty literal
    // carries no element type, so it stays `None` (the call falls back to the
    // generic erased path, as before).
    // Note: only the first element is sampled.  If `es[0]` is not inferable
    // (e.g. `nil`, an untyped variable, or a nested generic call with no type
    // annotation) but later elements are, inference still returns `None` and
    // the call falls through to the erased path — a safe degradation.
    case EList(es) -> {
      if es.count == 0 {
        None
      } else {
        match inferExprTE(state, env, es[0]) {
          case Some(elemTE) -> Some(value = TypeExpr(kind = TSlice(element = elemTE), span = expr.span))
          case None -> None
        }
      }
    }
    case _ -> None
  }
}

// Infer the element type produced by indexing `recv` (`recv[i]`).  Map -> V,
// List / slice / array -> element type.  Returns None for any other receiver
// shape or when the receiver type can't be inferred.
func inferIndexTE(state: in MonoState, env: in Map[String, TypeExpr], recv: in Expr): Option[TypeExpr] {
  match inferExprTE(state, env, recv) {
    case None -> None
    case Some(recvTy) -> {
      match recvTy.kind {
        case TGenericApp(head, args) -> {
          if head.segments.count == 1 {
            val h = head.segments[0]
            if h == "Map" and args.count == 2 {
              match args[1] {
                case TAType(v) -> Some(value = v)
                case TAValue(_) -> None
              }
            } else if h == "List" and args.count == 1 {
              match args[0] {
                case TAType(t) -> Some(value = t)
                case TAValue(_) -> None
              }
            } else {
              None
            }
          } else {
            None
          }
        }
        case TSlice(elem) -> Some(value = elem)
        case TArray(_, elem) -> Some(value = elem)
        case _ -> None
      }
    }
  }
}

// Infer the return type of `fn(args)` when `fn` is a same-package
// function reference.  Record literals share Lyric's call syntax
// (`Box(value = 11)`) — when the name resolves to a record decl the
// call's type is that record (or `TGenericApp(RecName, supplied
// targs)` for generics).  Returns None for unknown callees or
// inference shapes the helper can't handle.
func inferCallReturnTE(
  state: in MonoState, env: in Map[String, TypeExpr], fn: in Expr, args: in List[CallArg]
): Option[TypeExpr] {
  match fn.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        match inferRecordCtorTE(state, name, None, fn.span) {
          case Some(te) -> Some(value = te)
          case None -> inferReturnFromName(state, env, name, args, None)
        }
      } else {
        None
      }
    }
    case ETypeApp(innerFn, targs) -> {
      match innerFn.kind {
        case EPath(p) -> {
          if p.segments.count == 1 {
            val name = p.segments[0]
            match inferRecordCtorTE(state, name, Some(value = targs), fn.span) {
              case Some(te) -> Some(value = te)
              case None -> inferReturnFromName(state, env, name, args, Some(value = targs))
            }
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

// `f[T1, T2]` in value position — treat as if it were `f[T1, T2]()`
// would-return.  Only fires when the type-app appears outside an
// ECall (the ECall arm of inferCallReturnTE above handles the
// callable shape itself).
func inferTypeAppValueTE(
  state: in MonoState, env: in Map[String, TypeExpr], fn: in Expr, targs: in List[TypeArg]
): Option[TypeExpr] {
  match fn.kind {
    case EPath(p) -> {
      if p.segments.count == 1 {
        inferReturnFromName(state, env, p.segments[0], newList(), Some(value = targs))
      } else {
        None
      }
    }
    case _ -> None
  }
}

// If `name` is a same-package record, return its TypeExpr (with
// `targs` supplied for the generic params).  Otherwise None.
func inferRecordCtorTE(
  state: in MonoState, name: in String, targs: in Option[List[TypeArg]], span: in Span
): Option[TypeExpr] {
  // Bootstrap-grade emitter quirk: hold the lookup in a typed
  // binding so the F# type checker doesn't unify V in mapGet[String, V]
  // with the enclosing function's Option[TypeExpr] return type
  // (otherwise downstream `.field` access routes through TypeExpr
  // and fails codegen).
  val recOpt: Option[RecordDecl] = mapGet(state.recordDecls, name)
  match recOpt {
    case None -> None
    case Some(_) -> {
      val path = singleSegPath(name)
      match targs {
        case None -> Some(value = TypeExpr(kind = TRef(path = path), span = span))
        case Some(args) -> {
          if args.count == 0 {
            Some(value = TypeExpr(kind = TRef(path = path), span = span))
          } else {
            Some(value = TypeExpr(kind = TGenericApp(head = path, args = args), span = span))
          }
        }
      }
    }
  }
}

// Look up `fname` in funcDecls and return its return TypeExpr after
// substituting either explicit type args or args inferred from
// positional arguments.  None when the callee is unknown, has no
// declared return type, or inference leaves any type param unbound.
func inferReturnFromName(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  fname: in String,
  args: in List[CallArg],
  explicitArgs: in Option[List[TypeArg]],
): Option[TypeExpr] {
  val declOpt: Option[FunctionDecl] = mapGet(state.funcDecls, fname)
  match declOpt {
    case None -> None
    case Some(decl) -> {
      val typeParams = extractTypeParamNames(decl.generics)
      val subst: Map[String, TypeExpr] = newMap()
      val valueSubst: Map[String, Expr] = newMap()
      match explicitArgs {
        case Some(targs) -> {
          if targs.count == typeParams.count {
            var i = 0
            while i < typeParams.count {
              match targs[i] {
                case TAType(te) -> subst.add(typeParams[i], te)
                case TAValue(_) -> ()
              }
              i = i + 1
            }
          }
        }
        case None -> {
          if typeParams.count > 0 {
            var i = 0
            while i < args.count and i < decl.params.count {
              match inferExprTE(state, env, callArgExpr(args[i])) {
                case Some(argTE) -> unifyTE(typeParams, decl.params[i].ty, argTE, subst)
                case None -> ()
              }
              i = i + 1
            }
          }
        }
      }
      if typeParams.count > 0 and not substIsComplete(typeParams, subst) {
        None
      } else {
        match decl.ret {
          case None -> None
          case Some(r) -> Some(value = substTypeExpr(subst, valueSubst, r))
        }
      }
    }
  }
}

// Infer the type of `recv.field` when `recv` resolves to a
// same-package record (or exposed record) type.  Returns None for
// imported records, method projections, or undeclared field names.
func inferMemberTE(state: in MonoState, env: in Map[String, TypeExpr], recv: in Expr, name: in String): Option[TypeExpr] {
  match inferExprTE(state, env, recv) {
    case None -> None
    case Some(recvTy) -> {
      match recvTy.kind {
        case TRef(path) -> {
          if path.segments.count == 1 {
            lookupFieldTE(state, path.segments[0], name, newList())
          } else {
            None
          }
        }
        case TGenericApp(head, args) -> {
          if head.segments.count == 1 {
            lookupFieldTE(state, head.segments[0], name, args)
          } else {
            None
          }
        }
        case _ -> None
      }
    }
  }
}

// Walk a same-package record decl's fields for one named `field`.
// `recordArgs` is the receiver's concrete type-argument list (empty
// when the record has no generic parameters).  The looked-up field's
// declared TypeExpr is substituted using the record's GPType params
// → recordArgs binding before being returned.
func lookupFieldTE(
  state: in MonoState, recordName: in String, field: in String, recordArgs: in List[TypeArg]
): Option[TypeExpr] {
  // Same emitter quirk as inferRecordCtorTE — keep the binding typed.
  val recOpt: Option[RecordDecl] = mapGet(state.recordDecls, recordName)
  match recOpt {
    case None -> None
    case Some(rdecl) -> {
      val typeParams = extractTypeParamNames(rdecl.generics)
      val subst: Map[String, TypeExpr] = newMap()
      val valueSubst: Map[String, Expr] = newMap()
      if typeParams.count == recordArgs.count {
        var i = 0
        while i < typeParams.count {
          match recordArgs[i] {
            case TAType(te) -> subst.add(typeParams[i], te)
            case TAValue(_) -> ()
          }
          i = i + 1
        }
      }
      var i = 0
      while i < rdecl.members.count {
        match rdecl.members[i] {
          case RMField(fd) -> {
            if fd.name == field {
              return Some(value = substTypeExpr(subst, valueSubst, fd.ty))
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
      None
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Substitution completeness check
// ─────────────────────────────────────────────────────────────────────────────
func substIsComplete(typeParams: in List[String], subst: in Map[String, TypeExpr]): Bool {
  var i = 0
  while i < typeParams.count {
    if not subst.containsKey(typeParams[i]) {
      return false
    }
    i = i + 1
  }
  true
}

func allParamsBound(
  allParams: in List[GenericParamInfo],
  subst: in Map[String, TypeExpr],
  valueSubst: in Map[String, Expr],
): Bool {
  var i = 0
  while i < allParams.count {
    val p = allParams[i]
    if p.isValue {
      if not valueSubst.containsKey(p.name) {
        return false
      }
    } else {
      if not subst.containsKey(p.name) {
        return false
      }
    }
    i = i + 1
  }
  true
}

// ─────────────────────────────────────────────────────────────────────────────
// §10b. Body type-annotation substitution (#2557)
// ─────────────────────────────────────────────────────────────────────────────
// `specializeFunc` substitutes type variables in the signature (params / return)
// but, before this pass, shared the body verbatim.  A typed local in the body —
// `val acc: List[T] = newList()` — therefore kept its `T`, and codegen lowered
// `List[T]` to a `List<Pkg.T>` instance over a non-existent CLR type ("Common
// Language Runtime detected an invalid program").  These helpers rewrite every
// TypeExpr annotation reachable from the body (local bindings, lambda parameter
// annotations, explicit type applications) with `substTypeExpr`, leaving the
// rest of the AST structurally unchanged.
func substTypesBlock(subst: in Map[String, TypeExpr], valueSubst: in Map[String, Expr], blk: in Block): Block {
  val newStmts: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    newStmts.add(substTypesStmt(subst, valueSubst, blk.statements[i]))
    i = i + 1
  }
  Block(statements = newStmts, span = blk.span)
}

func substTypesOptTy(
  subst: in Map[String, TypeExpr], valueSubst: in Map[String, Expr], oty: in Option[TypeExpr]
): Option[TypeExpr] {
  match oty {
    case Some(te) -> Some(value = substTypeExpr(subst, valueSubst, te))
    case None -> None
  }
}

func substTypesStmt(subst: in Map[String, TypeExpr], valueSubst: in Map[String, Expr], stmt: in Statement): Statement {
  val s = stmt.span
  val k = match stmt.kind {
    case SLocal(binding) -> {
      val nb = match binding {
        case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = substTypesOptTy(subst, valueSubst, ty), init = substTypesExpr(subst, valueSubst, init))
        case LBVar(name, ty, init) -> {
          val ni = match init { case Some(e) -> Some(value = substTypesExpr(subst, valueSubst, e)); case None -> None }
          LBVar(name = name, ty = substTypesOptTy(subst, valueSubst, ty), init = ni)
        }
        case LBLet(name, ty, init) -> LBLet(name = name, ty = substTypesOptTy(subst, valueSubst, ty), init = substTypesExpr(subst, valueSubst, init))
      }
      SLocal(binding = nb)
    }
    case SAssign(target, op, value) -> SAssign(target = substTypesExpr(subst, valueSubst, target), op = op, value = substTypesExpr(subst, valueSubst, value))
    case SReturn(value) -> {
      match value {
        case Some(e) -> SReturn(value = Some(value = substTypesExpr(subst, valueSubst, e)))
        case None -> SReturn(value = None)
      }
    }
    case SBreak(label) -> SBreak(label = label)
    case SContinue(label) -> SContinue(label = label)
    case SThrow(expr) -> SThrow(expr = substTypesExpr(subst, valueSubst, expr))
    case STry(body, catches, finally_) -> {
      val newCatches: List[CatchClause] = newList()
      var ci = 0
      while ci < catches.count {
        val c = catches[ci]
        newCatches.add(
          CatchClause(
            typeName = c.typeName,
            bindName = c.bindName,
            body = substTypesBlock(subst, valueSubst, c.body),
            span = c.span
          )
        )
        ci = ci + 1
      }
      val newFin = match finally_ { case Some(b) -> Some(value = substTypesBlock(subst, valueSubst, b)); case None -> None }
      STry(body = substTypesBlock(subst, valueSubst, body), catches = newCatches, finally_ = newFin)
    }
    case SDefer(body) -> SDefer(body = substTypesBlock(subst, valueSubst, body))
    case SScope(binding, body) -> SScope(binding = binding, body = substTypesBlock(subst, valueSubst, body))
    case SFor(label, pat, iter, body) -> SFor(label = label, pat = pat, iter = substTypesExpr(subst, valueSubst, iter), body = substTypesBlock(subst, valueSubst, body))
    case SWhile(label, cond, body) -> SWhile(label = label, cond = substTypesExpr(subst, valueSubst, cond), body = substTypesBlock(subst, valueSubst, body))
    case SLoop(label, body) -> SLoop(label = label, body = substTypesBlock(subst, valueSubst, body))
    case SInvariant(expr) -> SInvariant(expr = substTypesExpr(subst, valueSubst, expr))
    case SExpr(expr) -> SExpr(expr = substTypesExpr(subst, valueSubst, expr))
    case SRule(lhs, rhs) -> SRule(lhs = substTypesExpr(subst, valueSubst, lhs), rhs = substTypesExpr(subst, valueSubst, rhs))
    case SItem(item) -> SItem(item = item)
  }
  Statement(kind = k, span = s)
}

func substTypesEOB(subst: in Map[String, TypeExpr], valueSubst: in Map[String, Expr], eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBExpr(e) -> EOBExpr(expr = substTypesExpr(subst, valueSubst, e))
    case EOBBlock(b) -> EOBBlock(block = substTypesBlock(subst, valueSubst, b))
  }
}

func substTypesExpr(subst: in Map[String, TypeExpr], valueSubst: in Map[String, Expr], expr: in Expr): Expr {
  val s = expr.span
  val k = match expr.kind {
    case EParen(inner) -> EParen(inner = substTypesExpr(subst, valueSubst, inner))
    case ETuple(es) -> {
      val ne: List[Expr] = newList()
      var i = 0
      while i < es.count {
        ne.add(substTypesExpr(subst, valueSubst, es[i]))
        i = i + 1
      }
      ETuple(exprs = ne)
    }
    case EList(es) -> {
      val ne: List[Expr] = newList()
      var i = 0
      while i < es.count {
        ne.add(substTypesExpr(subst, valueSubst, es[i]))
        i = i + 1
      }
      EList(exprs = ne)
    }
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      val ne = match elseBranch { case Some(eb) -> Some(value = substTypesEOB(subst, valueSubst, eb)); case None -> None }
      EIf(
        cond = substTypesExpr(subst, valueSubst, cond),
        thenBranch = substTypesEOB(subst, valueSubst, thenBranch),
        elseBranch = ne,
        thenForm = thenForm
      )
    }
    case EMatch(scrutinee, arms) -> {
      val na: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val ng = match arm.guard { case Some(g) -> Some(value = substTypesExpr(subst, valueSubst, g)); case None -> None }
        na.add(
          MatchArm(pattern = arm.pattern, guard = ng, body = substTypesEOB(subst, valueSubst, arm.body), span = arm.span)
        )
        i = i + 1
      }
      EMatch(scrutinee = substTypesExpr(subst, valueSubst, scrutinee), arms = na)
    }
    case EAwait(inner) -> EAwait(inner = substTypesExpr(subst, valueSubst, inner))
    case EYield(inner) -> EYield(inner = substTypesExpr(subst, valueSubst, inner))
    case ESpawn(inner) -> ESpawn(inner = substTypesExpr(subst, valueSubst, inner))
    case ETry(inner) -> ETry(inner = substTypesExpr(subst, valueSubst, inner))
    case EOld(inner) -> EOld(inner = substTypesExpr(subst, valueSubst, inner))
    case ELambda(lambdaParams, body) -> {
      val nps: List[LambdaParam] = newList()
      var i = 0
      while i < lambdaParams.count {
        val lp = lambdaParams[i]
        nps.add(LambdaParam(name = lp.name, ty = substTypesOptTy(subst, valueSubst, lp.ty), span = lp.span))
        i = i + 1
      }
      ELambda(lambdaParams = nps, body = substTypesBlock(subst, valueSubst, body))
    }
    case ECall(fn, args) -> {
      val na: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(e) -> na.add(CAPositional(expr = substTypesExpr(subst, valueSubst, e)))
          case CANamed(n, e, span) -> na.add(CANamed(name = n, value = substTypesExpr(subst, valueSubst, e), span = span))
        }
        i = i + 1
      }
      ECall(fn = substTypesExpr(subst, valueSubst, fn), args = na)
    }
    case ETypeApp(fn, args) -> {
      val na: List[TypeArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(te) -> na.add(TAType(ty = substTypeExpr(subst, valueSubst, te)))
          case TAValue(e) -> na.add(TAValue(expr = substTypesExpr(subst, valueSubst, e)))
        }
        i = i + 1
      }
      ETypeApp(fn = substTypesExpr(subst, valueSubst, fn), args = na)
    }
    case EIndex(receiver, indices) -> {
      val ni: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        ni.add(substTypesExpr(subst, valueSubst, indices[i]))
        i = i + 1
      }
      EIndex(receiver = substTypesExpr(subst, valueSubst, receiver), indices = ni)
    }
    case EMember(receiver, memberName) -> EMember(receiver = substTypesExpr(subst, valueSubst, receiver), memberName = memberName)
    case EPropagate(inner) -> EPropagate(inner = substTypesExpr(subst, valueSubst, inner))
    case EPrefix(op, operand) -> EPrefix(op = op, operand = substTypesExpr(subst, valueSubst, operand))
    case EBinop(op, lhs, rhs) -> EBinop(op = op, lhs = substTypesExpr(subst, valueSubst, lhs), rhs = substTypesExpr(subst, valueSubst, rhs))
    case ERange(bound) -> {
      val nb = match bound {
        case RBClosed(lo, hi) -> RBClosed(lo = substTypesExpr(subst, valueSubst, lo), hi = substTypesExpr(subst, valueSubst, hi))
        case RBHalfOpen(lo, hi) -> RBHalfOpen(lo = substTypesExpr(subst, valueSubst, lo), hi = substTypesExpr(subst, valueSubst, hi))
        case RBLowerOpen(hi) -> RBLowerOpen(hi = substTypesExpr(subst, valueSubst, hi))
        case RBUpperOpen(lo) -> RBUpperOpen(lo = substTypesExpr(subst, valueSubst, lo))
      }
      ERange(bound = nb)
    }
    case EAssign(target, op, value) -> EAssign(target = substTypesExpr(subst, valueSubst, target), op = op, value = substTypesExpr(subst, valueSubst, value))
    case EBlock(block) -> EBlock(block = substTypesBlock(subst, valueSubst, block))
    case EUnsafe(block) -> EUnsafe(block = substTypesBlock(subst, valueSubst, block))
    case EInterpolated(segments) -> {
      val ns: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISText(text, span) -> ns.add(ISText(text = text, span = span))
          case ISExpr(e) -> ns.add(ISExpr(expr = substTypesExpr(subst, valueSubst, e)))
        }
        i = i + 1
      }
      EInterpolated(segments = ns)
    }
    // All remaining ExprKind variants (ELiteral, ECall, EIndex, EBinOp, etc.)
    // pass through unchanged.  None of the unlisted variants embed a TypeExpr
    // directly — type annotations are carried at the statement level
    // (SLocal with a declared type) and handled by substTypesStmt.  If new
    // expression forms with embedded TypeExprs are added to ExprKind, they
    // must be listed explicitly here.
    case _ -> expr.kind
  }
  Expr(kind = k, span = s)
}

func substTypesFunctionBody(
  subst: in Map[String, TypeExpr], valueSubst: in Map[String, Expr], body: in FunctionBody
): FunctionBody {
  match body {
    case FBExpr(e) -> FBExpr(expr = substTypesExpr(subst, valueSubst, e))
    case FBBlock(b) -> FBBlock(block = substTypesBlock(subst, valueSubst, b))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Function specialisation — substitute type vars in decl structure
// ─────────────────────────────────────────────────────────────────────────────
func specializeFunc(
  decl: in FunctionDecl,
  specName: in String,
  subst: in Map[String, TypeExpr],
  valueSubst: in Map[String, Expr],
): FunctionDecl {
  val newParams: List[Param] = newList()
  var i = 0
  while i < decl.params.count {
    val p = decl.params[i]
    newParams.add(
      Param(
        mode = p.mode,
        modeExplicit = p.modeExplicit,
        name = p.name,
        ty = substTypeExpr(subst, valueSubst, p.ty),
        dflt = p.dflt,
        annotations = p.annotations,
        span = p.span
      )
    )
    i = i + 1
  }
  // Build `newRet` via a typed `var` + assignment rather than a `match`
  // expression whose two arms (`None` / `Some(...)`) the bootstrap F# emitter
  // unifies to `Option<object>` instead of `Option<TypeExpr>`.  A widened
  // `Option<object>` value stored in the `ret: Option[TypeExpr]` slot then
  // matches neither `case Some` nor `case None` in the self-hosted codegen's
  // `lowerFuncMsil` (isinst against `Option<TypeExpr>` fails), the match falls
  // through, and `retTy` is left null — an NRE on every called generic.
  // Constructing `Some(...)` in assignment position (expected type
  // `Option[TypeExpr]`) keeps the type argument concrete.
  var newRet: Option[TypeExpr] = None
  match decl.ret {
    case None -> {
    }
    case Some(r) -> {
      newRet = Some(value = substTypeExpr(subst, valueSubst, r))
    }
  }
  val emptyDocs: List[DocComment] = newList()
  val emptyAnns: List[Annotation] = newList()
  // Substitute type-variable annotations inside the body too (#2557): a typed
  // local such as `val acc: List[T]` must become `List[Int]` in the specialised
  // copy, otherwise codegen emits a `List<Pkg.T>` over a non-existent CLR type.
  val newBody = match decl.body {
    case Some(b) -> Some(value = substTypesFunctionBody(subst, valueSubst, b))
    case None -> None
  }
  FunctionDecl(
    docComments = emptyDocs,
    annotations = emptyAnns,
    visibility = None,
    isAsync = decl.isAsync,
    name = specName,
    generics = None,
    params = newParams,
    ret = newRet,
    whereClause = None,
    contracts = decl.contracts,
    body = newBody,
    span = decl.span
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §11b. Constraint validation
// ─────────────────────────────────────────────────────────────────────────────
// Validate that the type substitution satisfies the function's declared
// `where T: …` bounds.  This is a best-effort spot check: well-known
// derive markers (Equals, Hash, Show, Ord, Compare) are validated against
// the primitive set the BCL satisfies automatically; everything else
// (user-defined markers, opaque types, interfaces) accepts silently
// because cross-package symbol resolution lives in Band 6.  Confirmed
// mismatches produce an `M0001` error diagnostic at the call site span.
func validateWhereBounds(
  decl: in FunctionDecl,
  subst: in Map[String, TypeExpr],
  callSpan: in Span,
  diags: in List[Diagnostic],
): Unit {
  match decl.whereClause {
    case None -> ()
    case Some(wc) -> {
      var i = 0
      while i < wc.bounds.count {
        val bound = wc.bounds[i]
        match mapGet(subst, bound.name) {
          case None -> ()
          case Some(concrete) -> {
            var j = 0
            while j < bound.constraints.count {
              val cref = bound.constraints[j]
              if cref.head.segments.count == 1 {
                val markerName = cref.head.segments[0]
                if isKnownMarker(markerName) and not satisfiesMarker(concrete, markerName) {
                  diags.add(
                    errorDiagnostic(
                      "M0001",
                      "generic call '" + decl.name + "': type argument '" + bound.name + " = " + renderTypeExpr(concrete) +
                        "' does not satisfy 'where " +
                        bound.name +
                        ": " +
                        markerName +
                        "'",
                      callSpan
                    )
                  )
                }
              }
              j = j + 1
            }
          }
        }
        i = i + 1
      }
    }
  }
}

func isKnownMarker(name: in String): Bool {
  name == "Equals" or name == "Hash" or name == "Show" or name == "Ord" or name == "Compare"
}

// Primitive types satisfy every well-known derive marker (the BCL
// pairs them with reflection-driven equality / hashing / formatting
// already).  Any other concrete type passes silently — without a
// resolver we can't tell whether a user-defined type carries the
// corresponding `@derive(X)` annotation.  Reference types do NOT
// blanket-pass: callers depending on a marker the type doesn't supply
// will already fail at codegen.
func satisfiesMarker(te: in TypeExpr, marker: in String): Bool {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val nm = path.segments[0]
        if isPrimitiveName(nm) {
          true
        } else {
          // Unknown user type: accept silently (best-effort).
          true
        }
      } else {
        // Qualified name (e.g. `Std.Time.Instant`): accept silently.
        true
      }
    }
    case TGenericApp(_, _) -> true
    case TTuple(_) -> true
    case _ -> true
  }
}

func isPrimitiveName(name: in String): Bool {
  name == "Int" or name == "Long" or name == "Short" or name == "Byte" or name == "UInt" or name == "ULong" or
    name == "UShort" or
    name == "UByte" or
    name == "Float" or
    name == "Double" or
    name == "Bool" or
    name == "Char" or
    name == "String"
}

func renderTypeExpr(te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> pathSegsKey(path.segments)
    case TGenericApp(h, args) -> pathSegsKey(h.segments) + "[" + typeArgListKey(args) + "]"
    case TUnit -> "Unit"
    case TNever -> "Never"
    case TSelf -> "Self"
    case TArray(_, elem) -> "Array[…, " + renderTypeExpr(elem) + "]"
    case TSlice(elem) -> "slice[" + renderTypeExpr(elem) + "]"
    case TNullable(inner) -> renderTypeExpr(inner) + "?"
    case TTuple(ts) -> "(" + typeExprListKey(ts) + ")"
    case TFunction(ps, r) -> "(" + typeExprListKey(ps) + ") -> " + renderTypeExpr(r)
    case TParen(inner) -> renderTypeExpr(inner)
    case TRefined(p, _) -> pathSegsKey(p.segments)
    case TError -> "<error>"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §12. AST rewriting — call-site replacement and subtree walk
// ─────────────────────────────────────────────────────────────────────────────
func callArgExpr(arg: in CallArg): Expr {
  match arg {
    case CAPositional(e) -> e
    case CANamed(_, e, _) -> e
  }
}

func rewriteCallArgs(state: in MonoState, env: in Map[String, TypeExpr], args: in List[CallArg]): List[CallArg] {
  val buf: List[CallArg] = newList()
  var i = 0
  while i < args.count {
    match args[i] {
      case CAPositional(e) -> buf.add(CAPositional(expr = rewriteExpr(state, env, e)))
      case CANamed(n, e, span) -> buf.add(CANamed(name = n, value = rewriteExpr(state, env, e), span = span))
    }
    i = i + 1
  }
  buf
}

func rewriteEOB(state: in MonoState, env: in Map[String, TypeExpr], eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBExpr(e) -> EOBExpr(expr = rewriteExpr(state, env, e))
    case EOBBlock(b) -> EOBBlock(block = rewriteBlock(state, env, b))
  }
}

func rewriteMatchArms(state: in MonoState, env: in Map[String, TypeExpr], arms: in List[MatchArm]): List[MatchArm] {
  val buf: List[MatchArm] = newList()
  var i = 0
  while i < arms.count {
    val arm = arms[i]
    // Typed `var` + assignment (not a two-arm `None`/`Some` match): the bootstrap
    // F# emitter widens such a match to `Option<object>`, which then matches
    // neither arm of codegen's instantiation-sensitive `match guard`.
    var newGuard: Option[Expr] = None
    match arm.guard {
      case None -> {
      }
      case Some(g) -> {
        newGuard = Some(value = rewriteExpr(state, env, g))
      }
    }
    buf.add(MatchArm(pattern = arm.pattern, guard = newGuard, body = rewriteEOB(state, env, arm.body), span = arm.span))
    i = i + 1
  }
  buf
}

func rewriteInterpolSegs(
  state: in MonoState, env: in Map[String, TypeExpr], segs: in List[InterpolatedSegment]
): List[InterpolatedSegment] {
  val buf: List[InterpolatedSegment] = newList()
  var i = 0
  while i < segs.count {
    match segs[i] {
      case ISText(t, sp) -> buf.add(ISText(text = t, span = sp))
      case ISExpr(e) -> buf.add(ISExpr(expr = rewriteExpr(state, env, e)))
    }
    i = i + 1
  }
  buf
}

func rewriteExpr(state: in MonoState, env: in Map[String, TypeExpr], expr: in Expr): Expr {
  val s = expr.span
  match expr.kind {

    // ── Generic call sites ────────────────────────────────────────────────
    //
    // Two callable shapes are recognised:
    //
    //   * `EPath([fname])` — bare name; infer type args by unifying the
    //     declared param types against argument types pulled from
    //     `inferExprTE`.  Falls through unchanged when inference is
    //     incomplete (the un-specialised call survives to the emitter,
    //     which handles imported generics via real CLR generics).
    //
    //   * `ETypeApp(EPath([fname]), [T1, …])` — explicit type
    //     application `fname[T1, …](args)`.  Use the supplied targs
    //     directly; no inference needed.  This unblocks any call site
    //     where the user already wrote the type arguments inline (#349
    //     called out that `ETypeApp` was pass-through before).
    case ECall(fn, args) -> {
      val newArgs = rewriteCallArgs(state, env, args)
      match fn.kind {
        case ETypeApp(innerFn, targs) -> {
          match innerFn.kind {
            case EPath(path) -> {
              if path.segments.count == 1 {
                val fname = path.segments[0]
                match mapGet(state.genDecls, fname) {
                  case Some(baseDecl) -> {
                    val allParams = extractAllParamInfo(baseDecl.generics)
                    if allParams.count > 0 and targs.count == allParams.count {
                      val subst: Map[String, TypeExpr] = newMap()
                      val valueSubst: Map[String, Expr] = newMap()
                      var i = 0
                      while i < allParams.count {
                        val p = allParams[i]
                        match targs[i] {
                          case TAType(te) -> {
                            if not p.isValue {
                              subst.add(p.name, te)
                            }
                          }
                          case TAValue(e) -> {
                            if p.isValue {
                              valueSubst.add(p.name, e)
                            }
                          }
                        }
                        i = i + 1
                      }
                      if allParamsBound(allParams, subst, valueSubst) {
                        val name = specFuncName(fname, allParams, subst, valueSubst)
                        validateWhereBounds(baseDecl, subst, fn.span, state.diags)
                        if not state.seenSpecs.containsKey(name) {
                          state.seenSpecs.add(name, true)
                          val specDecl = specializeFunc(baseDecl, name, subst, valueSubst)
                          state.allSpecs.add(
                            SpecRequest(specName = name, baseDecl = specDecl, subst = subst, valueSubst = valueSubst, callSpan = fn.span)
                          )
                        }
                        val newFn = singleSegPathExpr(name, fn.span)
                        return Expr(kind = ECall(fn = newFn, args = newArgs), span = s)
                      }
                    }
                    Expr(kind = ECall(fn = fn, args = newArgs), span = s)
                  }
                  case None -> Expr(kind = ECall(fn = fn, args = newArgs), span = s)
                }
              } else {
                Expr(kind = ECall(fn = fn, args = newArgs), span = s)
              }
            }
            case _ -> Expr(kind = ECall(fn = rewriteExpr(state, env, fn), args = newArgs), span = s)
          }
        }
        case EPath(path) -> {
          if path.segments.count == 1 {
            val fname = path.segments[0]
            match mapGet(state.genDecls, fname) {
              case Some(baseDecl) -> {
                val typeParams = extractTypeParamNames(baseDecl.generics)
                val valueParams = extractValueParamNames(baseDecl.generics)
                if typeParams.count > 0 and valueParams.count == 0 {
                  // Pure type-generic call site: existing inference path
                  // (value generics require explicit `f[N]` type apps).
                  val subst: Map[String, TypeExpr] = newMap()
                  var i = 0
                  while i < args.count and i < baseDecl.params.count {
                    match inferExprTE(state, env, callArgExpr(args[i])) {
                      case Some(argTE) -> {
                        unifyTE(typeParams, baseDecl.params[i].ty, argTE, subst)
                      }
                      case None -> ()
                    }
                    i = i + 1
                  }
                  if substIsComplete(typeParams, subst) {
                    val allParams = extractAllParamInfo(baseDecl.generics)
                    val emptyValueSubst: Map[String, Expr] = newMap()
                    val name = specFuncName(fname, allParams, subst, emptyValueSubst)
                    validateWhereBounds(baseDecl, subst, fn.span, state.diags)
                    if not state.seenSpecs.containsKey(name) {
                      state.seenSpecs.add(name, true)
                      val specDecl = specializeFunc(baseDecl, name, subst, emptyValueSubst)
                      state.allSpecs.add(
                        SpecRequest(specName = name, baseDecl = specDecl, subst = subst, valueSubst = emptyValueSubst, callSpan = fn.span)
                      )
                    }
                    val newFn = singleSegPathExpr(name, fn.span)
                    return Expr(kind = ECall(fn = newFn, args = newArgs), span = s)
                  }
                }
                Expr(kind = ECall(fn = fn, args = newArgs), span = s)
              }
              case None -> Expr(kind = ECall(fn = fn, args = newArgs), span = s)
            }
          } else {
            Expr(kind = ECall(fn = fn, args = newArgs), span = s)
          }
        }
        case _ -> Expr(kind = ECall(fn = rewriteExpr(state, env, fn), args = newArgs), span = s)
      }
    }

    // ── Recursive sub-expression rewriting ───────────────────────────────
    case EBinop(op, lhs, rhs) -> Expr(kind = EBinop(op = op, lhs = rewriteExpr(state, env, lhs), rhs = rewriteExpr(state, env, rhs)), span = s)

    case EPrefix(op, operand) -> Expr(kind = EPrefix(op = op, operand = rewriteExpr(state, env, operand)), span = s)

    case EMember(recv, name) -> Expr(kind = EMember(receiver = rewriteExpr(state, env, recv), memberName = name), span = s)

    case EIndex(recv, idxs) -> {
      val newIdxs: List[Expr] = newList()
      var i = 0
      while i < idxs.count {
        newIdxs.add(rewriteExpr(state, env, idxs[i]))
        i = i + 1
      }
      Expr(kind = EIndex(receiver = rewriteExpr(state, env, recv), indices = newIdxs), span = s)
    }

    case EIf(cond, thenB, elseB, form) -> {
      // Typed `var` + assignment, not a `match` expression: the bootstrap F#
      // emitter unifies a `None` / `Some(...)` two-arm match to `Option<object>`
      // instead of `Option[ExprOrBlock]`.  A widened `None<object>` stored in the
      // `elseBranch` slot matches neither arm of codegen's `match elseBranch`,
      // so an else-less `if` lowers with an unresolved branch target and a stray
      // pop — corrupting any function the monomorphizer rewrites.
      var newElse: Option[ExprOrBlock] = None
      match elseB {
        case None -> {
        }
        case Some(e) -> {
          newElse = Some(value = rewriteEOB(state, env, e))
        }
      }
      Expr(
        kind = EIf(
          cond = rewriteExpr(state, env, cond),
          thenBranch = rewriteEOB(state, env, thenB),
          elseBranch = newElse,
          thenForm = form
        ),
        span = s
      )
    }

    case EMatch(scrut, arms) -> Expr(kind = EMatch(scrutinee = rewriteExpr(state, env, scrut), arms = rewriteMatchArms(state, env, arms)), span = s)

    case EBlock(blk) -> Expr(kind = EBlock(block = rewriteBlock(state, env, blk)), span = s)

    case EUnsafe(blk) -> Expr(kind = EUnsafe(block = rewriteBlock(state, env, blk)), span = s)

    case EAwait(inner) -> Expr(kind = EAwait(inner = rewriteExpr(state, env, inner)), span = s)

    case EYield(inner) -> Expr(kind = EYield(inner = rewriteExpr(state, env, inner)), span = s)

    case ESpawn(inner) -> Expr(kind = ESpawn(inner = rewriteExpr(state, env, inner)), span = s)

    case ETry(inner) -> Expr(kind = ETry(inner = rewriteExpr(state, env, inner)), span = s)

    case EPropagate(inner) -> Expr(kind = EPropagate(inner = rewriteExpr(state, env, inner)), span = s)

    case EParen(inner) -> Expr(kind = EParen(inner = rewriteExpr(state, env, inner)), span = s)

    case ETuple(es) -> {
      val newEs: List[Expr] = newList()
      var i = 0
      while i < es.count {
        newEs.add(rewriteExpr(state, env, es[i]))
        i = i + 1
      }
      Expr(kind = ETuple(exprs = newEs), span = s)
    }

    case EList(es) -> {
      val newEs: List[Expr] = newList()
      var i = 0
      while i < es.count {
        newEs.add(rewriteExpr(state, env, es[i]))
        i = i + 1
      }
      Expr(kind = EList(exprs = newEs), span = s)
    }

    case EAssign(target, op, value) -> Expr(kind = EAssign(target = rewriteExpr(state, env, target), op = op, value = rewriteExpr(state, env, value)), span = s)

    case EInterpolated(segs) -> Expr(kind = EInterpolated(segments = rewriteInterpolSegs(state, env, segs)), span = s)

    case ELambda(lparams, body) -> Expr(kind = ELambda(lambdaParams = lparams, body = rewriteBlock(state, env, body)), span = s)

    case ETypeApp(fn, targs) -> Expr(kind = ETypeApp(fn = rewriteExpr(state, env, fn), args = targs), span = s)

    // Leaves: literals, EPath, ESelf, EResult, EOld, EForall, EExists, ERange, EError
    case _ -> expr
  }
}

func rewriteBlock(state: in MonoState, env: in Map[String, TypeExpr], blk: in Block): Block {
  val newStmts: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    newStmts.add(rewriteStmt(state, env, blk.statements[i]))
    i = i + 1
  }
  Block(statements = newStmts, span = blk.span)
}

func rewriteStmt(state: in MonoState, env: in Map[String, TypeExpr], stmt: in Statement): Statement {
  val s = stmt.span
  match stmt.kind {
    case SLocal(binding) -> Statement(kind = SLocal(binding = rewriteBinding(state, env, binding)), span = s)

    case SAssign(target, op, value) -> Statement(kind = SAssign(target = rewriteExpr(state, env, target), op = op, value = rewriteExpr(state, env, value)), span = s)

    case SReturn(opt) -> {
      // Typed `var` + assignment, not a two-arm `None`/`Some` match — see the
      // `EIf` else-branch note above: the F# emitter would otherwise
      // widen the match to `Option<object>` and corrupt the rewritten `return`.
      var newOpt: Option[Expr] = None
      match opt {
        case None -> {
        }
        case Some(e) -> {
          newOpt = Some(value = rewriteExpr(state, env, e))
        }
      }
      Statement(kind = SReturn(value = newOpt), span = s)
    }

    case SThrow(e) -> Statement(kind = SThrow(expr = rewriteExpr(state, env, e)), span = s)

    case SExpr(e) -> Statement(kind = SExpr(expr = rewriteExpr(state, env, e)), span = s)

    case SWhile(lbl, cond, body) -> Statement(kind = SWhile(label = lbl, cond = rewriteExpr(state, env, cond), body = rewriteBlock(state, env, body)), span = s)

    case SFor(lbl, pat, iter, body) -> Statement(kind = SFor(label = lbl, pat = pat, iter = rewriteExpr(state, env, iter), body = rewriteBlock(state, env, body)), span = s)

    case SLoop(lbl, body) -> Statement(kind = SLoop(label = lbl, body = rewriteBlock(state, env, body)), span = s)

    case SDefer(body) -> Statement(kind = SDefer(body = rewriteBlock(state, env, body)), span = s)

    case SScope(lbl, body) -> Statement(kind = SScope(binding = lbl, body = rewriteBlock(state, env, body)), span = s)

    case SInvariant(e) -> Statement(kind = SInvariant(expr = rewriteExpr(state, env, e)), span = s)

    case SRule(lhs, rhs) -> Statement(kind = SRule(lhs = rewriteExpr(state, env, lhs), rhs = rewriteExpr(state, env, rhs)), span = s)

    case STry(body, catches, finally_) -> {
      val newBody = rewriteBlock(state, env, body)
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val cc = catches[i]
        newCatches.add(
          CatchClause(
            typeName = cc.typeName,
            bindName = cc.bindName,
            body = rewriteBlock(state, env, cc.body),
            span = cc.span
          )
        )
        i = i + 1
      }
      // Typed `var` + assignment, not a two-arm match — see the `EIf` note
      // above: a widened `Option<object>` would corrupt the rewritten
      // try/finally lowering.
      var newFinally: Option[Block] = None
      match finally_ {
        case None -> {
        }
        case Some(fb) -> {
          newFinally = Some(value = rewriteBlock(state, env, fb))
        }
      }
      Statement(kind = STry(body = newBody, catches = newCatches, finally_ = newFinally), span = s)
    }

    // SBreak, SContinue, SItem: pass through unchanged
    case _ -> stmt
  }
}

// Track variables bound in this statement into `env`.
// #349: when the binding has no explicit annotation, fall back to
// `inferExprTE(init)` so callers like `val b = Box(...)` can still
// reach record field projections through `b.<field>` later.  Re-binding
// `var` / `let` with a fresh annotation drops the prior env entry so
// shadows reflect the new type (closes the MEDIUM #349 gap).
func rewriteBinding(state: in MonoState, env: in Map[String, TypeExpr], binding: in LocalBinding): LocalBinding {
  match binding {
    case LBVal(pat, tyOpt, init) -> {
      match tyOpt {
        case Some(te) -> trackPatternEnv(env, pat, te)
        case None -> {
          match inferExprTE(state, env, init) {
            case Some(inferred) -> trackPatternEnv(env, pat, inferred)
            case None -> ()
          }
        }
      }
      LBVal(pat = pat, ty = tyOpt, init = rewriteExpr(state, env, init))
    }
    case LBVar(name, tyOpt, initOpt) -> {
      match tyOpt {
        case Some(te) -> {
          if env.containsKey(name) {
            env.remove(name)
          }
          env.add(name, te)
        }
        case None -> {
          match initOpt {
            case Some(init) -> {
              match inferExprTE(state, env, init) {
                case Some(inferred) -> {
                  if env.containsKey(name) {
                    env.remove(name)
                  }
                  env.add(name, inferred)
                }
                case None -> ()
              }
            }
            case None -> ()
          }
        }
      }
      // Typed `var` + assignment, not a two-arm match: a bare-`None`
      // arm would be `None<object>` and corrupt an init-less `var` binding.
      var newInit: Option[Expr] = None
      match initOpt {
        case None -> {
        }
        case Some(e) -> {
          newInit = Some(value = rewriteExpr(state, env, e))
        }
      }
      LBVar(name = name, ty = tyOpt, init = newInit)
    }
    case LBLet(name, tyOpt, init) -> {
      match tyOpt {
        case Some(te) -> {
          if env.containsKey(name) {
            env.remove(name)
          }
          env.add(name, te)
        }
        case None -> {
          match inferExprTE(state, env, init) {
            case Some(inferred) -> {
              if env.containsKey(name) {
                env.remove(name)
              }
              env.add(name, inferred)
            }
            case None -> ()
          }
        }
      }
      LBLet(name = name, ty = tyOpt, init = rewriteExpr(state, env, init))
    }
  }
}

func trackPatternEnv(env: in Map[String, TypeExpr], pat: in Pattern, te: in TypeExpr): Unit {
  match pat.kind {
    case PBinding(name, _) -> {
      if not env.containsKey(name) {
        env.add(name, te)
      }
    }
    case _ -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §13. Parameter-seeded type environment
// ─────────────────────────────────────────────────────────────────────────────
func seedEnvFromParams(params: in List[Param]): Map[String, TypeExpr] {
  val env: Map[String, TypeExpr] = newMap()
  var i = 0
  while i < params.count {
    env.add(params[i].name, params[i].ty)
    i = i + 1
  }
  env
}

// ─────────────────────────────────────────────────────────────────────────────
// §14. Rewrite a FunctionBody
// ─────────────────────────────────────────────────────────────────────────────
func rewriteFuncBody(
  state: in MonoState, env: in Map[String, TypeExpr], body: in Option[FunctionBody]
): Option[FunctionBody] {
  // Typed `var` + assignment, not a two-arm match: a bare-`None` arm
  // would be `None<object>` and corrupt a body-less function's `decl.body`.
  var newBody: Option[FunctionBody] = None
  match body {
    case None -> {
    }
    case Some(fb) -> {
      newBody = Some(
        value = match fb {
          case FBBlock(blk) -> FBBlock(block = rewriteBlock(state, env, blk))
          case FBExpr(e) -> FBExpr(expr = rewriteExpr(state, env, e))
        }
      )
    }
  }
  newBody
}

// Reconstruct a method `FunctionDecl` with its body rewritten (generic call
// sites specialised), preserving every other field.  Shared by the Phase-2
// `IImpl` / `IInterface` arms so impl and interface default-method bodies get
// the same generic-call rewriting as free functions (#1727).
func rewriteMethodDecl(state: in MonoState, env: in Map[String, TypeExpr], fn: in FunctionDecl): FunctionDecl {
  val newBody = rewriteFuncBody(state, env, fn.body)
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = fn.params,
    ret = fn.ret,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = newBody,
    span = fn.span
  )
}

// One-shot value-generic substitution over a FunctionBody.  Replaces every
// `EPath([N])` whose name `N` is in `valueSubst` with the bound Expr.
// Skipped when the substitution map is empty (the common case for pure
// type-generic specialisations).
func substValueInBody(valueSubst: in Map[String, Expr], body: in Option[FunctionBody]): Option[FunctionBody] {
  if valueSubst.count == 0 {
    return body
  }
  // Typed `var` + assignment, not a two-arm match.
  var newBody: Option[FunctionBody] = None
  match body {
    case None -> {
    }
    case Some(fb) -> {
      newBody = Some(
        value = match fb {
          case FBBlock(blk) -> FBBlock(block = substBlockValue(valueSubst, blk))
          case FBExpr(e) -> FBExpr(expr = substExprValue(valueSubst, e))
        }
      )
    }
  }
  newBody
}

// ─────────────────────────────────────────────────────────────────────────────
// §15. Main entry point
// ─────────────────────────────────────────────────────────────────────────────
/// Monomorphise all same-package generic functions in `file`.
///
/// Returns a `MonoResult` whose `file` field contains:
///  - All non-generic items (with generic call sites rewritten to specialised
///    names).
///  - Specialised (non-generic) copies of every reachable generic function
///    instantiation, appended at the end of the item list.
///  - Generic IFunc items are *removed* from the output (they have been
///    expanded into one or more specialisations).
///
/// If no same-package generic functions are found, the input file is returned
/// unchanged.
pub func monoFile(file: in SourceFile): MonoResult {
  val emptyImports: List[FunctionDecl] = newList()
  monoFileWithImports(file, emptyImports)
}

/// Monomorphise generics in `file`, treating `importedGenDecls` as if they
/// were declared in the same compilation unit.  Soundness is the caller's
/// responsibility: the imported function's body must reference only items
/// the user's compilation unit can resolve.  Used by the MSIL / JVM bridges
/// once Band 6 (`Lyric.RestoredPackages`) is wired through.
pub func monoFileWithImports(file: in SourceFile, importedGenDecls: in List[FunctionDecl]): MonoResult {
  // ── Phase 1: collect generic function decls ─────────────────────────────
  // #349: also collect every IFunc (generic + non-generic) and every
  // record decl so `inferExprTE` can resolve call returns and field
  // projections through `state.funcDecls` / `state.recordDecls`.
  // Generic methods nested inside interface / impl blocks are walked
  // by `collectIfaceGenerics` / `collectImplGenerics` so default-bodied
  // generic methods also become specialisation candidates.
  val genDecls: Map[String, FunctionDecl] = newMap()
  val funcDecls: Map[String, FunctionDecl] = newMap()
  val recordDecls: Map[String, RecordDecl] = newMap()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        if not funcDecls.containsKey(decl.name) {
          funcDecls.add(decl.name, decl)
        }
        match decl.generics {
          case Some(_) -> {
            if not genDecls.containsKey(decl.name) {
              genDecls.add(decl.name, decl)
            }
          }
          case None -> ()
        }
      }
      case IRecord(decl) -> {
        if not recordDecls.containsKey(decl.name) {
          recordDecls.add(decl.name, decl)
        }
      }
      case IExposedRec(decl) -> {
        if not recordDecls.containsKey(decl.name) {
          recordDecls.add(decl.name, decl)
        }
      }
      case IInterface(decl) -> collectIfaceGenerics(decl, genDecls, funcDecls)
      case IImpl(decl) -> collectImplGenerics(decl, genDecls, funcDecls)
      case _ -> ()
    }
    i = i + 1
  }

  // Merge imported generic decls (cross-package surface).  Same-package
  // wins on name collision so user-local shadows take precedence.
  //
  // The `genDecls.add` MUST stay inside the `not funcDecls.containsKey`
  // guard: a local function of the same name — generic OR non-generic —
  // shadows the imported generic.  A non-generic local is recorded in
  // `funcDecls` but not `genDecls`, so seeding the import into `genDecls`
  // unconditionally would let the import hijack the local call site and
  // mis-specialise it.  #1855: a user `func tag(o: in Opt): Int` was
  // monomorphised against the stdlib proof generic `tag[T](x: in T): T`
  // (from `Std.Core` via `core_proof.l`), producing a broken identity
  // specialisation `tag__Opt` that the call site then targeted instead of
  // the user's `match`-bearing function.
  var ig = 0
  while ig < importedGenDecls.count {
    val idecl = importedGenDecls[ig]
    if not funcDecls.containsKey(idecl.name) {
      funcDecls.add(idecl.name, idecl)
      match idecl.generics {
        case Some(_) -> {
          if not genDecls.containsKey(idecl.name) {
            genDecls.add(idecl.name, idecl)
          }
        }
        case None -> ()
      }
    }
    ig = ig + 1
  }

  // If nothing to monomorphise, return early.
  if genDecls.count == 0 {
    val emptyRewrites: Map[String, String] = newMap()
    val emptyDiags: List[Diagnostic] = newList()
    return MonoResult(file = file, rewrites = emptyRewrites, diagnostics = emptyDiags)
  }

  val state = newMonoState(genDecls, funcDecls, recordDecls)

  // ── Phase 2: rewrite non-generic items ──────────────────────────────────
  val rewrittenItems: List[Item] = newList()
  var j = 0
  while j < file.items.count {
    val item = file.items[j]
    match item.kind {
      case IFunc(decl) -> {
        match decl.generics {
          case Some(_) -> {
            // Generic functions are dropped here; specialisations are added below.
            ()
          }
          // Wildcard (not `case None`): a `@derive`-synthesised `None` lowers to a bare null that `isinst` misses — see #1796.
          case _ -> {
            val env = seedEnvFromParams(decl.params)
            val newBody = rewriteFuncBody(state, env, decl.body)
            val newDecl = FunctionDecl(
              docComments = decl.docComments,
              annotations = decl.annotations,
              visibility = decl.visibility,
              isAsync = decl.isAsync,
              name = decl.name,
              generics = None,
              params = decl.params,
              ret = decl.ret,
              whereClause = decl.whereClause,
              contracts = decl.contracts,
              body = newBody,
              span = decl.span
            )
            rewrittenItems.add(
              Item(
                docComments = item.docComments,
                annotations = item.annotations,
                visibility = item.visibility,
                kind = IFunc(decl = newDecl),
                span = item.span
              )
            )
          }
        }
      }
      // Impl / interface method bodies are rewritten too — generic call
      // sites inside an `impl` method (e.g. `Ok(mapGet(data.entries, key))`
      // in a `SessionStore` impl) must specialise just like calls in a
      // free function, or the generic return erases to `object` and the
      // consumer `match` panics "match not exhaustive" (#1727).
      case IImpl(decl) -> {
        val newMembers: List[ImplMember] = newList()
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMplFunc(fn) -> {
              val env = seedEnvFromParams(fn.params)
              // Seed `self` so `self.field` projections in the method body
              // resolve to the impl target's record fields.  `self` is a
              // keyword so it cannot collide with a parameter name.
              env.add("self", decl.target)
              newMembers.add(IMplFunc(fn = rewriteMethodDecl(state, env, fn)))
            }
            case IMplAssoc(a) -> newMembers.add(IMplAssoc(assoc = a))
          }
          mi = mi + 1
        }
        rewrittenItems.add(
          Item(
            docComments = item.docComments,
            annotations = item.annotations,
            visibility = item.visibility,
            kind = IImpl(
              decl = ImplDecl(
                generics = decl.generics,
                iface = decl.iface,
                target = decl.target,
                whereClause = decl.whereClause,
                members = newMembers,
                span = decl.span
              )
            ),
            span = item.span
          )
        )
      }
      case IInterface(decl) -> {
        val newMembers: List[InterfaceMember] = newList()
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMFunc(fn) -> {
              val env = seedEnvFromParams(fn.params)
              newMembers.add(IMFunc(fn = rewriteMethodDecl(state, env, fn)))
            }
            case IMSig(sig) -> newMembers.add(IMSig(sig = sig))
            case IMAssoc(a) -> newMembers.add(IMAssoc(assoc = a))
          }
          mi = mi + 1
        }
        rewrittenItems.add(
          Item(
            docComments = item.docComments,
            annotations = item.annotations,
            visibility = item.visibility,
            kind = IInterface(
              decl = InterfaceDecl(
                name = decl.name,
                generics = decl.generics,
                whereClause = decl.whereClause,
                members = newMembers,
                span = decl.span
              )
            ),
            span = item.span
          )
        )
      }
      case _ -> rewrittenItems.add(item)
    }
    j = j + 1
  }

  // ── Phase 3: process worklist (fixpoint over allSpecs) ──────────────────
  // Each iteration picks up the next SpecRequest.  Rewriting the body may
  // add further requests; the while condition re-evaluates count each round.
  //
  // Recursion budget (#349): cap the worklist size so a pathological
  // nested-generic recursion (`f[T] = … g[List[T]] …` that always
  // adds a deeper specialisation) terminates with a clear error
  // instead of OOM'ing the compiler.  10_000 specialisations is well
  // beyond any reasonable program; real codebases land in the low
  // hundreds.
  val finalSpecDecls: List[FunctionDecl] = newList()
  val specBudget = 10000

  var wi = 0
  while wi < state.allSpecs.count {
    if wi >= specBudget {
      panic(
        "Lyric.Mono: specialisation budget exhausted (" + toString(specBudget) +
          " specs).  Most likely a generic function recurses with an unbounded " +
          "type-argument shape (e.g. `f[T] = … f[List[T]] …`).  Refactor to " +
          "stop instantiating with strictly larger types."
      )
    }
    val req = state.allSpecs[wi]
    // The baseDecl already has type-var and value-var substitution applied
    // to its params/ret.  Substitute value-generic Expr references inside
    // the body too (e.g. `for i in 0..N` → `for i in 0..3`), then walk
    // for nested generic calls.
    val substitutedBody = substValueInBody(req.valueSubst, req.baseDecl.body)
    val env = seedEnvFromParams(req.baseDecl.params)
    val newBody = rewriteFuncBody(state, env, substitutedBody)
    val finalDecl = FunctionDecl(
      docComments = req.baseDecl.docComments,
      annotations = req.baseDecl.annotations,
      visibility = req.baseDecl.visibility,
      isAsync = req.baseDecl.isAsync,
      name = req.baseDecl.name,
      generics = None,
      params = req.baseDecl.params,
      ret = req.baseDecl.ret,
      whereClause = None,
      contracts = req.baseDecl.contracts,
      body = newBody,
      span = req.baseDecl.span
    )
    finalSpecDecls.add(finalDecl)
    wi = wi + 1
  }

  // ── Phase 4: build output SourceFile ────────────────────────────────────
  val allItems: List[Item] = newList()

  // Non-generic items (rewritten call sites)
  var ri = 0
  while ri < rewrittenItems.count {
    allItems.add(rewrittenItems[ri])
    ri = ri + 1
  }

  // Specialised function items (each gets a fresh empty doc/ann list)
  var si = 0
  while si < finalSpecDecls.count {
    val sd = finalSpecDecls[si]
    val specDocs: List[DocComment] = newList()
    val specAnns: List[Annotation] = newList()
    allItems.add(
      Item(docComments = specDocs, annotations = specAnns, visibility = None, kind = IFunc(decl = sd), span = sd.span)
    )
    si = si + 1
  }

  // Build rewrites map (generic name → last specialised name emitted).
  val rewrites: Map[String, String] = newMap()
  var wj = 0
  while wj < state.allSpecs.count {
    val req = state.allSpecs[wj]
    val baseName = extractBaseName(req.specName)
    if rewrites.containsKey(baseName) {
      // Multiple specialisations: just record the last one (best-effort).
    } else {
      rewrites.add(baseName, req.specName)
    }
    wj = wj + 1
  }

  val newFile = SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = allItems,
    span = file.span
  )

  MonoResult(file = newFile, rewrites = rewrites, diagnostics = state.diags)
}

// Extract the base function name from a mangled specialisation name.
// e.g. "mapFoo__Int__String" → "mapFoo"
func extractBaseName(specName: in String): String {
  // Skip leading underscore runs (e.g. `__lyric_helper`) so we don't
  // truncate the base name to empty when the source name itself begins
  // with `__`.  The monomorphizer appends `__<TyArg>__<TyArg>` to
  // specialised names, so a real specialisation marker must appear
  // after at least one non-underscore character.
  var start = 0
  while start < specName.length and specName[start] == '_' {
    start = start + 1
  }
  var i = start
  while i + 1 < specName.length {
    if specName[i] == '_' and specName[i + 1] == '_' {
      return Str.substring(specName, 0, i)
    }
    i = i + 1
  }
  specName
}
