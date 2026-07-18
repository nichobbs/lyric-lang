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
//!     is declared and `T` substitutes to a primitive, the marker
//!     vocabulary shared with the type checker (`Add`, `Sub`, `Mul`,
//!     `Div`, `Mod`, `Compare`, `Hash`, `Equals`, `Default` — see
//!     `isKnownDeriveMarker` in `typechecker_checker.l`) is checked
//!     against the primitive's capabilities and an `M0001` diagnostic is
//!     emitted on confirmed mismatch (e.g. `String` against `Div`).
//!     Non-primitive concrete types accept silently — the type checker's
//!     `checkBoundsSatisfied` (T0108) owns `@derive`-list and interface
//!     satisfaction, which need the symbol table.
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
import Std.Char as Ch
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
  /// Monomorphisation diagnostics:
  ///   • `M0001` — a concrete type argument fails its declared
  ///     `where T: Marker` constraint.
  ///   • `M0002` — a call site targeting a same-package generic could not
  ///     be rewritten to a specialisation; the generic's declaration is
  ///     erased from the output, so the surviving call would be a dangling
  ///     reference at codegen (a silent runtime crash before this
  ///     diagnostic existed — docs/59 §5.2 B2).
  ///   • `M0003` — the specialisation worklist exhausted its budget
  ///     (unbounded recursive instantiation), formerly a compiler panic.
  ///   • `M0004` — a call site targeting an IMPORTED generic left one or
  ///     more type params unbound AND an opaque, uninferable argument
  ///     flows into a parameter slot that mentions those params.  Most
  ///     inference gaps on imported-generic calls default the unbound
  ///     params to `Object` and specialise anyway (#5604 — safe when
  ///     nothing opaque is actually handed to the specialised body, e.g. a
  ///     zero-arg call or a param that doesn't mention the unbound param).
  ///     This shape is NOT safe: the specialised copy pattern-matches /
  ///     narrows the slot as if it were always `Object`, but the real
  ///     argument may carry a genuinely different closed-generic runtime
  ///     identity (e.g. `Result[Unit, IOError]`) that the erased
  ///     `Object`/`Object` arms can never structurally match — a runtime
  ///     `InvalidProgramException` / "match not exhaustive" crash instead
  ///     of a compile-time error (#5970).  Reported instead of silently
  ///     defaulting.
  /// The bridges route this list through `reportAndAbort` so M-errors
  /// abort codegen the same way parse/type-check/mode-check diagnostics
  /// do.
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
  /// Interface decls visible to the file (same-package + cross-package
  /// imports), keyed by simple name.  Used by `inferExprTE` to resolve a
  /// method-call return type (`recv.method(...)`) when `recv` is an
  /// interface-typed value, after substituting the interface's generic
  /// parameters with the receiver's concrete type arguments (#3813).
  ifaceDecls: Map[String, InterfaceDecl]
  /// Same-package distinct/range-subtype decls (`type Age = Int range 0
  /// ..= 150`), keyed by simple name.  Used by `inferCallReturnTE` to
  /// recognise the compiler-synthesised static factories `Type.from(x)` /
  /// `Type.tryFrom(x)` (#1501) — these dispatch directly on the type NAME
  /// rather than through normal method resolution, so `recv` never
  /// resolves to a value the general inferer can see through (#5841).
  distinctDecls: Map[String, DistinctTypeDecl]
  /// Simple names of top-level generic functions declared in THIS file
  /// that Phase 2 will drop from the output (neither `@externTarget`-kept
  /// nor `@axiom`).  A call site still referencing one of these after the
  /// rewrite failed to specialise would reference a function that no
  /// longer exists at codegen; `M0002` fires instead of the former silent
  /// dangling-reference miscompile (docs/59 §5.2 B2).
  droppedLocalGenerics: Map[String, Bool]
  /// Cross-package function names whose imported candidates have
  /// genuinely differing signatures (#5843/#5961/#5962), keyed to every
  /// distinct-signature candidate collected under that bare name.  Never
  /// populated for a name a same-package local shadows (#5961 — the local
  /// is what the type checker resolves at every call site, so the
  /// ambiguity among imports of that name is moot).  Superseding the prior
  /// "evict the name from `funcDecls`/`genDecls` entirely" degradation
  /// (which pushed every ambiguous call onto the Object-fallback
  /// specialisation path — a path that crashes at runtime against a real
  /// generic instantiation, not just an inference dead end): inference
  /// paths consult this table to resolve the correct candidate AT EACH
  /// CALL SITE (by argument count, then by argument type), only falling
  /// back to the Object-defaulted degradation when a call site is
  /// genuinely irresolvable (e.g. an untyped argument).  See
  /// `resolveAmbiguousOverload`.
  ambiguousFuncOverloads: Map[String, List[FunctionDecl]]
  seenSpecs: Map[String, Bool]
  allSpecs: List[SpecRequest]
  diags: List[Diagnostic]
}

func newMonoState(
  genDecls: in Map[String, FunctionDecl],
  funcDecls: in Map[String, FunctionDecl],
  recordDecls: in Map[String, RecordDecl],
  ifaceDecls: in Map[String, InterfaceDecl],
  distinctDecls: in Map[String, DistinctTypeDecl],
  droppedLocalGenerics: in Map[String, Bool],
  ambiguousFuncOverloads: in Map[String, List[FunctionDecl]],
): MonoState {
  MonoState(
    genDecls = genDecls,
    funcDecls = funcDecls,
    recordDecls = recordDecls,
    ifaceDecls = ifaceDecls,
    distinctDecls = distinctDecls,
    droppedLocalGenerics = droppedLocalGenerics,
    ambiguousFuncOverloads = ambiguousFuncOverloads,
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
// Flatten a pure path expression (`EPath` / nested `EMember` over `EPath`)
// to its dotted-segment list.  Returns an empty list as soon as a non-path
// node is hit, so the result is safe to test with `count > 0` for "this
// looked like a qualified path" (issue #3852-adjacent).
func flattenPathExprSegsMono(e: in Expr): List[String] {
  match e.kind {
    case EPath(path) -> {
      val segs: List[String] = newList()
      var i = 0
      while i < path.segments.count {
        segs.add(path.segments[i])
        i = i + 1
      }
      segs
    }
    case EMember(receiver, memberName) -> {
      val pre = flattenPathExprSegsMono(receiver)
      if pre.count == 0 {
        return newList()
      }
      val segs: List[String] = newList()
      var i = 0
      while i < pre.count {
        segs.add(pre[i])
        i = i + 1
      }
      segs.add(memberName)
      segs
    }
    case _ -> newList()
  }
}

// True iff `state.funcDecls` has an entry for `name` whose declared parameter
// count exactly matches `callArity`.  Used by `inferCallReturnTE`'s qualified-
// call fall-through to guard against same-named functions in a different
// package having an incompatible signature (issue #3852-adjacent).
//
// `name` ambiguous (#5843/#5961/#5962): `state.funcDecls` holds only a single
// first-seen representative, which may have the WRONG arity for this call
// site while a different overload matches — checking every overload catches
// that case instead of spuriously blocking a resolvable qualified call.
func funcDeclArityMatches(state: in MonoState, name: in String, callArity: in Int): Bool {
  match mapGet(state.ambiguousFuncOverloads, name) {
    case Some(cands) -> {
      var i = 0
      while i < cands.count {
        if cands[i].params.count == callArity {
          return true
        }
        i = i + 1
      }
      false
    }
    case None -> match mapGet(state.funcDecls, name) { case None -> true; case Some(decl) -> decl.params.count == callArity }
  }
}

// resulting specialisation still has a unique name within the file
// because callers de-duplicate via `state.seenSpecs`.
func valueExprKey(e: in Expr): String {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(value, _, _) -> longLitKey(value)
        case LBool(b) -> if b { "true" } else { "false" }
        case LChar(cp) -> "c" + toString(cp)
        case LString(s) -> stringLitKey(s)
        case LTripleString(s) -> stringLitKey(s)
        case LRawString(s) -> stringLitKey(s)
        case LFloat(_, _, raw) -> floatLitKey(raw)
        case LUnit -> "u"
      }
    }
    case EPath(path) -> pathSegsKey(path.segments)
    case EParen(inner) -> valueExprKey(inner)
    case _ -> "x"
  }
}

// Injective key for a string-valued generic argument.  The prior `"s" +
// length` collided for any two equal-length strings (and across the
// triple/raw variants), so the second distinct value reused the first's
// specialisation via `seenSpecs` — baking the wrong constant into the
// emitted IL.  Encode the length plus every code point so distinct strings
// always produce distinct, identifier-safe keys.
func stringLitKey(s: in String): String {
  var acc = "s" + toString(s.length)
  var i = 0
  while i < s.length {
    acc = acc + "_" + toString(Ch.toInt(s[i]))
    i = i + 1
  }
  acc
}

// Injective key for a float-valued generic argument.  The prior `"f"`
// collided for every float literal.  Use the literal's raw source text with
// the non-identifier characters remapped (`.`->d, `-`->n, `+`->p) so distinct
// literals stay distinct.
func floatLitKey(raw: in String): String {
  "f" + Str.replace(Str.replace(Str.replace(raw, ".", "d"), "-", "n"), "+", "p")
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

// A structural signature key for a `FunctionDecl` — its parameter modes and
// types joined with its return type — used to tell apart two DIFFERENT
// functions that merely share a bare name (#5843) from genuine duplicate
// collections of the SAME declaration (which must keep comparing equal).
// Generic type parameters are folded in verbatim via `typeExprKey` (their
// names are part of the structural shape, so `f[T](x: T): T` and
// `f[U](x: U): Bool` still compare unequal on the return type), and each
// parameter's `in`/`out`/`inout` mode is part of the key too (#5962 — two
// differently-moded overloads sharing a name are a genuine ambiguity, not a
// duplicate) — this key is for name-collision detection only, never for
// specialisation mangling.
func funcSigKeyMono(decl: in FunctionDecl): String {
  var acc = ""
  var i = 0
  while i < decl.params.count {
    val p = decl.params[i]
    val modeKey = match p.mode { case PMIn -> "in "; case PMOut -> "out "; case PMInout -> "inout " }
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + modeKey + typeExprKey(p.ty)
    i = i + 1
  }
  val retKey = match decl.ret { case Some(r) -> typeExprKey(r); case None -> "Unit" }
  "(" + acc + ")->" + retKey
}

// Append `decl` to `table[decl.name]`'s overload list, deduping against any
// existing candidate with the same structural signature (`sigKey`) so a
// name re-seeded across several loop iterations doesn't accumulate
// duplicate entries.  See `MonoState.ambiguousFuncOverloads`.
func addAmbiguousOverloadCandidate(
  table: in Map[String, List[FunctionDecl]], decl: in FunctionDecl, sigKey: in String
): Unit {
  match mapGet(table, decl.name) {
    case None -> {
      val lst: List[FunctionDecl] = newList()
      lst.add(decl)
      table.add(decl.name, lst)
    }
    case Some(lst) -> {
      var isDup = false
      var i = 0
      while i < lst.count {
        if funcSigKeyMono(lst[i]) == sigKey {
          isDup = true
        }
        i = i + 1
      }
      if not isDup {
        lst.add(decl)
      }
    }
  }
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

// Recognise a call to a distinct/range-subtype's compiler-synthesised
// static factory — `Type.from(x): Type` or `Type.tryFrom(x): Result[Type,
// String]` (#1501, codegen.l's `lowerMethodCallMsil`) — and return its real
// instantiated return type.  `recv` must be a bare single-segment path
// naming a same-package distinct type; any other receiver shape (a value,
// an imported/cross-package type, a qualified path) yields `None` so the
// caller falls through to the general inference paths (#5841).
func inferDistinctStaticFactoryTE(
  state: in MonoState, recv: in Expr, methodName: in String, span: in Span
): Option[TypeExpr] {
  match recv.kind {
    case EPath(rp) -> {
      if rp.segments.count == 1 {
        match mapGet(state.distinctDecls, rp.segments[0]) {
          case Some(dt) -> {
            if methodName == "from" {
              Some(value = TypeExpr(kind = TRef(path = singleSegPath(dt.name)), span = span))
            } else if methodName == "tryFrom" {
              val targs: List[TypeArg] = newList()
              targs.add(TAType(ty = TypeExpr(kind = TRef(path = singleSegPath(dt.name)), span = span)))
              targs.add(TAType(ty = TypeExpr(kind = TRef(path = singleSegPath("String")), span = span)))
              Some(value = TypeExpr(kind = TGenericApp(head = singleSegPath("Result"), args = targs), span = span))
            } else {
              None
            }
          }
          case None -> None
        }
      } else {
        None
      }
    }
    case _ -> None
  }
}

// Resolve a qualified call site by its trailing simple name (`methodName`)
// against same-package record constructors, then the generic worklist
// (skipped, to avoid a cross-package mis-specialisation), then the
// non-generic inference surface (arity-guarded, #3852-adjacent).  Shared by
// both AST shapes a qualified call can take at this point in the pipeline:
// a nested `EMember` chain the parser produced directly, and a flattened
// multi-segment `EPath` `Lyric.AliasRewriter` produces from `Alias.method(…)`
// (`import X as Alias` + `Alias.method(...)` rewrites to the full dotted
// `EPath([...,"method"])` — see `inferCallReturnTE`'s `EPath` arm below).
// `None` when nothing on the inference surface resolves; callers with a
// receiver expression (the `EMember` case) fall back further to
// `inferMethodReturnTE` — a bare qualified `EPath` has no receiver value to
// fall back through, so `None` is final there.
func inferQualifiedFuncByTailNameTE(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  methodName: in String,
  args: in List[CallArg],
  span: in Span,
): Option[TypeExpr] {
  match inferRecordCtorTE(state, methodName, None, span) {
    case Some(te) -> Some(value = te)
    case None -> {
      if state.genDecls.containsKey(methodName) {
        None
      } else if funcDeclArityMatches(state, methodName, args.count) {
        inferReturnFromName(state, env, methodName, args, None)
      } else {
        None
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
        // A qualified call surviving to a multi-segment `EPath` at this
        // point is a stdlib/package call `Lyric.AliasRewriter` flattened
        // from `Alias.method(...)` (`import X as Alias`) into the full
        // dotted path — resolve it by its trailing simple name exactly like
        // the `EMember` qualified-call case below.  Without this, e.g.
        // `File.writeText(...)` (imported `as File`) never fed its return
        // type into inference, so a later `isOk(r)` on the untracked
        // binding degraded to the Object-fallback specialisation and
        // crashed against the real `Result[Unit, IOError]` instance.
        val methodName = path.segments[path.segments.count - 1]
        inferQualifiedFuncByTailNameTE(state, env, methodName, args, fn.span)
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
    // Method call `recv.method(args)` — the callee is an `EMember`.  Infer
    // the receiver's type, find the method on its interface/record decl, and
    // return the method's declared return type with the receiver's generic
    // type-args substituted.  Without this a call like
    // `isOk(bucket.exists(...))` (where `bucket: StorageBucket`) could not
    // infer its argument type, so the generic `isOk` stayed type-erased and
    // failed at runtime (#3813, same failure mode as #3705).
    case EMember(recv, methodName) -> {
      // Distinct/range-subtype static factories (#1501) dispatch directly on
      // the type NAME (`Age.tryFrom(x)`), not through normal method
      // resolution — `recv` is a bare type reference that never resolves to
      // a value, so none of the general inference paths below can see
      // through it. Recognise `Type.from`/`Type.tryFrom` up front against
      // the real synthesised return type so a caller like
      // `isOk(Age.tryFrom(x))` monomorphises against the concrete
      // `Result[Age, String]` instantiation instead of leaving `T`/`E`
      // unbound (which previously defaulted the specialisation to `Object`
      // and mismatched the real runtime instantiation at the match site,
      // #5841).
      match inferDistinctStaticFactoryTE(state, recv, methodName, fn.span) {
        case Some(te) -> return Some(value = te)
        case None -> {
        }
      }
      // Detect when the EMember chain flattens to a pure dotted path
      // (e.g. `JobQueue.Domain.jobStatusFromString`) the parser left as
      // nested `EMember(EMember(EPath["Pkg"], "Sub"), "fn")` rather than a
      // multi-segment EPath.  Look up `<methodName>` in funcDecls /
      // recordDecls by simple name so generic call sites like
      // `isNone(Pkg.parse("x"))` can specialise off `parse`'s return type
      // (issue #3852-adjacent).  Two safety guards: skip when a same-named
      // generic exists (the rewriter would otherwise mis-specialise across
      // packages) and require an exact arity match against funcDecls.
      //
      // `recv`'s own method resolution is tried FIRST, not the qualified
      // free-function guess: `flattenPathExprSegsMono` can't distinguish a
      // genuine qualified package path (`Pkg.Sub.fn`, no receiver VALUE)
      // from an ordinary `recv.method(args)` call whose single-segment
      // receiver happens to flatten the same way (`bucket.exists(...)` — one
      // segment for `bucket`, one for `exists`, `flatSegs.count == 2` too).
      // `Lyric.AliasRewriter` already rewrites every genuine import-aliased
      // qualified call into a multi-segment `EPath` before mono runs (see
      // `inferCallReturnTE`'s `EPath` arm above), so by the time an `EMember`
      // reaches here its head is never a real package alias — trying the
      // real method call first (and only falling back to the qualified-name
      // guess when `recv`'s type can't be resolved, or has no such method)
      // avoids an unrelated same-named free function hijacking a genuine
      // method call purely because their arities happen to coincide (e.g.
      // `bucket.exists("k")`, one explicit arg, colliding by pure chance with
      // arity-1 `Std.Directory.exists(path: String): Bool` while the real
      // free-function counterpart `Storage.exists(bucket, key)` is arity 2 —
      // the ambiguity table's arity-only fast path would otherwise resolve
      // uniquely to the WRONG, unrelated `Directory.exists`).
      val flatSegs = flattenPathExprSegsMono(fn)
      if flatSegs.count >= 2 {
        match inferMethodReturnTE(state, env, recv, methodName, args) {
          case Some(te) -> Some(value = te)
          case None -> inferQualifiedFuncByTailNameTE(state, env, methodName, args, fn.span)
        }
      } else {
        inferMethodReturnTE(state, env, recv, methodName, args)
      }
    }
    case _ -> None
  }
}

// Infer the return type of `recv.method(args)`.  Resolves `recv`'s type to a
// known interface (or record) decl, locates `method`, and returns its
// declared return type after substituting the type's generic parameters with
// the receiver's concrete type arguments and inferring any method-level
// generics from the call arguments.  Returns None when the receiver type is
// unknown, the method has no declared return, or a method-level type param
// cannot be inferred.
func inferMethodReturnTE(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  recv: in Expr,
  methodName: in String,
  args: in List[CallArg],
): Option[TypeExpr] {
  match inferExprTE(state, env, recv) {
    case None -> None
    case Some(recvTy) -> {
      val typeName = match recvTy.kind {
        case TRef(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
        case TGenericApp(head, _) -> if head.segments.count == 1 { head.segments[0] } else { "" }
        case _ -> ""
      }
      if typeName.length == 0 {
        None
      } else {
        val recvArgs: List[TypeArg] = match recvTy.kind { case TGenericApp(_, a) -> a; case _ -> newList() }
        // Interfaces first (the common case — `bucket.exists` on
        // `StorageBucket`), then records (methods declared in a record body).
        val ifaceOpt: Option[InterfaceDecl] = mapGet(state.ifaceDecls, typeName)
        match ifaceOpt {
          case Some(idecl) -> lookupIfaceMethodRetTE(state, env, idecl, methodName, recvArgs, args)
          case None -> {
            val recOpt: Option[RecordDecl] = mapGet(state.recordDecls, typeName)
            match recOpt {
              case None -> None
              case Some(rdecl) -> lookupRecordMethodRetTE(state, env, rdecl, methodName, recvArgs, args)
            }
          }
        }
      }
    }
  }
}

// Look up `methodName` among an interface's members and return its declared
// return type, substituted for the interface's generic params (bound to
// `recvArgs`) plus any method-level generics inferred from `args`.
func lookupIfaceMethodRetTE(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  idecl: in InterfaceDecl,
  methodName: in String,
  recvArgs: in List[TypeArg],
  args: in List[CallArg],
): Option[TypeExpr] {
  val typeParams = extractTypeParamNames(idecl.generics)
  var i = 0
  while i < idecl.members.count {
    match idecl.members[i] {
      case IMSig(sig) -> {
        if sig.name == methodName {
          return substMethodRetTE(state, env, typeParams, recvArgs, sig.generics, sig.params, sig.ret, args)
        }
      }
      case IMFunc(fn) -> {
        if fn.name == methodName {
          return substMethodRetTE(state, env, typeParams, recvArgs, fn.generics, fn.params, fn.ret, args)
        }
      }
      case IMAssoc(_) -> ()
    }
    i = i + 1
  }
  None
}

// Counterpart of `lookupIfaceMethodRetTE` for methods declared inside a
// record body (`RMFunc`).
func lookupRecordMethodRetTE(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  rdecl: in RecordDecl,
  methodName: in String,
  recvArgs: in List[TypeArg],
  args: in List[CallArg],
): Option[TypeExpr] {
  val typeParams = extractTypeParamNames(rdecl.generics)
  var i = 0
  while i < rdecl.members.count {
    match rdecl.members[i] {
      case RMFunc(fn) -> {
        if fn.name == methodName {
          return substMethodRetTE(state, env, typeParams, recvArgs, fn.generics, fn.params, fn.ret, args)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

// Build the substitution for a method's return type: the declaring type's
// generic params bind to `recvArgs`; method-level generics are inferred from
// the call `args` (via `unifyTE`).  Returns the substituted return type, or
// None when there is no declared return or a method generic stays unbound.
func substMethodRetTE(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  typeParams: in List[String],
  recvArgs: in List[TypeArg],
  methodGenerics: in Option[GenericParams],
  params: in List[Param],
  ret: in Option[TypeExpr],
  args: in List[CallArg],
): Option[TypeExpr] {
  match ret {
    case None -> None
    case Some(r) -> {
      val subst: Map[String, TypeExpr] = newMap()
      val valueSubst: Map[String, Expr] = newMap()
      // Bind the declaring type's params to the receiver's concrete args.
      if typeParams.count == recvArgs.count {
        var i = 0
        while i < typeParams.count {
          match recvArgs[i] {
            case TAType(te) -> subst.add(typeParams[i], te)
            case TAValue(_) -> ()
          }
          i = i + 1
        }
      }
      // Infer method-level generics from the call arguments.
      val methodParams = extractTypeParamNames(methodGenerics)
      if methodParams.count > 0 {
        var ai = 0
        while ai < args.count and ai < params.count {
          match inferExprTE(state, env, callArgExpr(args[ai])) {
            case Some(argTE) -> unifyTE(methodParams, params[ai].ty, argTE, subst)
            case None -> ()
          }
          ai = ai + 1
        }
        if not substIsComplete(methodParams, subst) {
          return None
        }
      }
      Some(value = substTypeExpr(subst, valueSubst, r))
    }
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

// True when `te` mentions any name in `typeParams` (i.e. it is not yet a
// fully concrete type under the current substitution).
func teMentionsTypeParam(typeParams: in List[String], te: in TypeExpr): Bool {
  match te.kind {
    case TRef(path) -> path.segments.count == 1 and listContainsStr(typeParams, path.segments[0])
    case TGenericApp(_, args) -> {
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(inner) -> {
            if teMentionsTypeParam(typeParams, inner) {
              return true
            }
          }
          case TAValue(_) -> ()
        }
        i = i + 1
      }
      false
    }
    case TNullable(inner) -> teMentionsTypeParam(typeParams, inner)
    case TSlice(elem) -> teMentionsTypeParam(typeParams, elem)
    case TArray(_, elem) -> teMentionsTypeParam(typeParams, elem)
    case TFunction(ps, ret) -> {
      var i = 0
      while i < ps.count {
        if teMentionsTypeParam(typeParams, ps[i]) {
          return true
        }
        i = i + 1
      }
      teMentionsTypeParam(typeParams, ret)
    }
    case TTuple(elems) -> {
      var i = 0
      while i < elems.count {
        if teMentionsTypeParam(typeParams, elems[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case TParen(inner) -> teMentionsTypeParam(typeParams, inner)
    case _ -> false
  }
}

// The result TypeExpr of a lambda's block body, when the block ends in a
// single inferable trailing expression (`SExpr` fall-off or `return e`).
// Bounded on purpose: multi-branch bodies return None and the caller's
// unification simply skips the return slot.
func lambdaBodyResultTE(state: in MonoState, env: in Map[String, TypeExpr], body: in Block): Option[TypeExpr] {
  if body.statements.count == 0 {
    return None
  }
  match body.statements[body.statements.count - 1].kind {
    case SExpr(e) -> inferExprTE(state, env, e)
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> inferExprTE(state, env, e)
        case None -> None
      }
    }
    case _ -> None
  }
}

// Unify a lambda argument against its declared `(P0, …) -> R` parameter type,
// binding any of `typeParams` reachable from the lambda's ANNOTATED parameter
// types and (when the body ends in an inferable trailing expression) its
// result type.  This is what lets a call whose only type-argument source is
// the lambda — `forEach([], { x: Int -> () })`, `mapOption(None, { x: Int ->
// x * 2 })` — specialise instead of silently staying generic (#5604).
// Unannotated lambda params are seeded from the declared parameter type when
// the substitution built so far already makes it concrete (earlier arguments
// bound it), so `{ x -> x * 2 }` still types its body against a `T` pinned by
// a preceding argument.  The caller's `env` is temporarily extended for the
// body inference and restored before returning (params shadow outer names).
func unifyLambdaArgTE(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  typeParams: in List[String],
  declParamTy: in TypeExpr,
  lambdaParams: in List[LambdaParam],
  body: in Block,
  subst: in Map[String, TypeExpr],
): Unit {
  match declParamTy.kind {
    case TFunction(dParams, dRet) -> {
      val emptyValueSubst: Map[String, Expr] = newMap()
      // Save shadowed outer bindings so env can be restored afterwards.
      val addedNames: List[String] = newList()
      val shadowedNames: List[String] = newList()
      val shadowedVals: List[TypeExpr] = newList()
      var j = 0
      while j < lambdaParams.count and j < dParams.count {
        val lp = lambdaParams[j]
        var seedTy: Option[TypeExpr] = None
        match lp.ty {
          case Some(annTy) -> {
            unifyTE(typeParams, dParams[j], annTy, subst)
            seedTy = Some(value = annTy)
          }
          case None -> {
            val substituted = substTypeExpr(subst, emptyValueSubst, dParams[j])
            if not teMentionsTypeParam(typeParams, substituted) {
              seedTy = Some(value = substituted)
            }
          }
        }
        match seedTy {
          case Some(sty) -> {
            match mapGet(env, lp.name) {
              case Some(prev) -> {
                shadowedNames.add(lp.name)
                shadowedVals.add(prev)
                // `val _ =`: Map.remove returns Bool; a value-returning call as
                // the arm's trailing statement leaves Int32 on one merge path
                // while the None arm's () leaves a null objref — ILVerify
                // PathStackUnexpected (#3943 emitter family).
                val _ = env.remove(lp.name)
              }
              case None -> ()
            }
            env.add(lp.name, sty)
            addedNames.add(lp.name)
          }
          case None -> ()
        }
        j = j + 1
      }
      if teMentionsTypeParam(typeParams, dRet) {
        match lambdaBodyResultTE(state, env, body) {
          case Some(bodyTE) -> unifyTE(typeParams, dRet, bodyTE, subst)
          case None -> ()
        }
      }
      var ai = 0
      while ai < addedNames.count {
        if env.containsKey(addedNames[ai]) {
          val _ = env.remove(addedNames[ai])
        }
        ai = ai + 1
      }
      var si = 0
      while si < shadowedNames.count {
        env.add(shadowedNames[si], shadowedVals[si])
        si = si + 1
      }
    }
    case _ -> {
    }
  }
}

// A call argument's lambda shape, unwrapped through parens; `None` for any
// other expression.
func lambdaShapeOfArg(e: in Expr): Option[Expr] {
  match e.kind {
    case ELambda(_, _) -> Some(value = e)
    case EParen(inner) -> lambdaShapeOfArg(inner)
    case _ -> None
  }
}

// Strip wrapping EParen layers (mono-local mirror of the codegen helper).
func unwrapParenExprMono(e: in Expr): Expr {
  match e.kind {
    case EParen(inner) -> unwrapParenExprMono(inner)
    case _ -> e
  }
}

// The inference-only union-case ctor decl a call argument names, when the
// argument is a direct `CaseName(...)` construction; `None` otherwise.
func ctorSynthOfArg(state: in MonoState, e: in Expr): Option[FunctionDecl] {
  match e.kind {
    case EParen(inner) -> ctorSynthOfArg(state, inner)
    case ECall(fn, _) -> {
      match fn.kind {
        case EPath(path) -> {
          if path.segments.count == 1 {
            match mapGet(state.funcDecls, path.segments[0]) {
              case Some(d) -> {
                if annsInferenceOnlyMono(d.annotations) {
                  Some(value = d)
                } else {
                  None
                }
              }
              case None -> None
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

// Unify a union-case constructor ARGUMENT against its declared parameter
// type, binding only the slots the constructor's fields actually PIN
// (`isOk(Ok(value = 7))` binds T=Int and leaves E untouched).  A
// construction in argument position takes the surrounding parameter's
// instantiation as its per-slot HINT for every slot its fields don't pin,
// so the unpinned slots agree with WHATEVER the outer params finally
// resolve to (a later argument, or the final Object default) — binding
// them eagerly to the Object fill here would poison a later, more precise
// binding (`andThenResult(Ok(5), { x: Int -> Err(error = 42) })`: E must
// come from the lambda body's Err, not from Ok's unpinned slot).  Only the
// matching-generic-head shape partial-binds; any other declared parameter
// shape falls back to the caller's full-TE path (where the fill is the
// correct construction model).  Returns true when the partial path applied.
func partialUnifyCtorArg(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  outerTypeParams: in List[String],
  declParamTy: in TypeExpr,
  ctorDecl: in FunctionDecl,
  ctorArgs: in List[CallArg],
  subst: in Map[String, TypeExpr],
): Bool {
  val innerParams = extractTypeParamNames(ctorDecl.generics)
  if innerParams.count == 0 {
    return false
  }
  val declShape = match declParamTy.kind { case TGenericApp(dHead, dArgs) -> Some(value = dArgs); case _ -> None }
  match declShape {
    case None -> false
    case Some(dArgs) -> {
      match ctorDecl.ret {
        case None -> false
        case Some(retTe) -> {
          match retTe.kind {
            case TGenericApp(retHead, retArgs) -> {
              val dHeadName = match declParamTy.kind {
                case TGenericApp(h, _) -> if h.segments.count > 0 { h.segments[h.segments.count - 1] } else { "" }
                case _ -> ""
              }
              val rHeadName = if retHead.segments.count > 0 { retHead.segments[retHead.segments.count - 1] } else { "" }
              if dHeadName.length == 0 or dHeadName != rHeadName or dArgs.count != retArgs.count {
                return false
              }
              val innerSubst: Map[String, TypeExpr] = newMap()
              var k = 0
              while k < ctorArgs.count and k < ctorDecl.params.count {
                match inferExprTE(state, env, callArgExpr(ctorArgs[k])) {
                  case Some(argTE) -> unifyTE(innerParams, ctorDecl.params[k].ty, argTE, innerSubst)
                  case None -> ()
                }
                k = k + 1
              }
              var q = 0
              while q < retArgs.count {
                match retArgs[q] {
                  case TAType(rte) -> {
                    match rte.kind {
                      case TRef(rp) -> {
                        if rp.segments.count == 1 {
                          match mapGet(innerSubst, rp.segments[0]) {
                            case Some(pinnedTE) -> {
                              match dArgs[q] {
                                case TAType(dte) -> unifyTE(outerTypeParams, dte, pinnedTE, subst)
                                case TAValue(_) -> ()
                              }
                            }
                            case None -> ()
                          }
                        }
                      }
                      case _ -> {
                      }
                    }
                  }
                  case TAValue(_) -> {
                  }
                }
                q = q + 1
              }
              true
            }
            case _ -> false
          }
        }
      }
    }
  }
}

// True iff `argTE`'s structural key equals `paramTy`'s — used to match a
// call argument's inferred type against one candidate overload's declared
// parameter type.  Structural (not identity) comparison so e.g. two
// `Result[Unit, IOError]` TypeExprs built from different AST nodes still
// compare equal.
func teKeysEqual(argTE: in TypeExpr, paramTy: in TypeExpr): Bool {
  typeExprKey(argTE) == typeExprKey(paramTy)
}

// True iff `cand` is a plausible resolution of a call site's arguments:
// no argument whose type IS inferable conflicts with `cand`'s declared
// parameter type at that position, AND at least one argument's inferred
// type positively matches — an all-unknown-argument call matches every
// candidate equally and must not be treated as "resolved" (that would
// silently guess, exactly the failure mode #5843 exists to prevent).
func candidateArgsCompatible(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  cand: in FunctionDecl,
  args: in List[CallArg],
): Bool {
  var matchCount = 0
  var conflict = false
  var i = 0
  while i < cand.params.count and i < args.count {
    match inferExprTE(state, env, callArgExpr(args[i])) {
      case Some(argTE) -> {
        if teKeysEqual(argTE, cand.params[i].ty) {
          matchCount = matchCount + 1
        } else {
          conflict = true
        }
      }
      case None -> {
      }
    }
    i = i + 1
  };
  (not conflict) and matchCount > 0
}

// Resolve a call site against `fname`'s ambiguous overload set (see
// `MonoState.ambiguousFuncOverloads`): filter by argument COUNT first
// (`del1(s: String)` vs `del2(b: SomeRecord, k: String)` sharing the name
// `del` — a 2-argument call site can only mean `del2`); if more than one
// candidate still ties on arity, attempt to type the call's arguments via
// the existing inference environment (an annotated lambda param, a
// literal, a known local's tracked type) and keep only the candidate(s)
// whose declared parameter types don't conflict with what's known.  A
// UNIQUE surviving candidate resolves the call; zero or several surviving
// candidates give up (`None`) rather than guess — the caller degrades to
// the existing Object-defaulted behaviour, same as an unknown callee.
func resolveAmbiguousOverload(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  fname: in String,
  args: in List[CallArg],
): Option[FunctionDecl] {
  match mapGet(state.ambiguousFuncOverloads, fname) {
    case None -> None
    case Some(cands) -> {
      val arityMatched: List[FunctionDecl] = newList()
      var i = 0
      while i < cands.count {
        if cands[i].params.count == args.count {
          arityMatched.add(cands[i])
        }
        i = i + 1
      }
      if arityMatched.count == 0 {
        None
      } else if arityMatched.count == 1 {
        Some(value = arityMatched[0])
      } else {
        val compatible: List[FunctionDecl] = newList()
        var j = 0
        while j < arityMatched.count {
          if candidateArgsCompatible(state, env, arityMatched[j], args) {
            compatible.add(arityMatched[j])
          }
          j = j + 1
        }
        if compatible.count == 1 {
          Some(value = compatible[0])
        } else {
          None
        }
      }
    }
  }
}

// Look up `fname` in funcDecls and return its return TypeExpr after
// substituting either explicit type args or args inferred from
// positional arguments.  None when the callee is unknown, has no
// declared return type, or inference leaves any type param unbound.
//
// `fname` ambiguous (#5843/#5961/#5962): resolve the call site's specific
// overload via `resolveAmbiguousOverload` instead of trusting
// `state.funcDecls`' single first-seen representative (which may be the
// WRONG overload for this call site) — and if the call site can't be
// resolved, give up outright (`None`) rather than fall back to that
// arbitrary representative, which is exactly the mis-specialisation
// #5843 was written to prevent.
func inferReturnFromName(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  fname: in String,
  args: in List[CallArg],
  explicitArgs: in Option[List[TypeArg]],
): Option[TypeExpr] {
  val declOpt: Option[FunctionDecl] = if state.ambiguousFuncOverloads.containsKey(fname) {
    resolveAmbiguousOverload(state, env, fname, args)
  } else {
    mapGet(state.funcDecls, fname)
  }
  match declOpt {
    case None -> None
    case Some(decl) -> if decl.isAsync {
      // #5xxx: an un-awaited call to an `async func` evaluates to the
      // physical Task/Task<T> the codegen backend produces for it, not
      // to `decl.ret` (the function's logical Lyric return type). Feeding
      // `decl.ret` into generic-parameter unification here mis-inferred
      // `T=Unit` for `taskWaitMs(asyncGreet(name), ms)` (asyncGreet's
      // logical return is Unit), producing a specialisation whose
      // parameter type lowers to the illegal MSIL `ELEMENT_TYPE_VOID` in
      // a parameter position (`TypeLoadException: The signature is
      // incorrect.` at type-load time, unconditionally).
      //
      // For a `Unit`-returning async func the physical value is a bare
      // `System.Threading.Tasks.Task` — nameable via the same `Task`
      // extern type `Std.Task` already exposes (D-progress-541 and
      // friends), so report that instead of the misleading `Unit`. A
      // non-`Unit` async return would physically be `Task<T>`, which has
      // no corresponding public Lyric generic type to name safely here;
      // fall back to the same `None` degradation used for lambdas, BCL
      // returns, and impl-block dispatch so the call stays generic/erased
      // instead of guessing at a shape that might not resolve.
      val isUnitRet = match decl.ret {
        case None -> true
        case Some(r) -> match r.kind {
          case TUnit -> true
          // `: Unit` written explicitly parses as `TRef(["Unit"])` — only the
          // `()` spelling produces `TUnit` (see parser_exprs.l's
          // parseTypeExpr/parseTypeExprNoArrow); `async func f(): Unit` is the
          // common spelling, so both must count as Unit here.
          case TRef(path) -> path.segments.count == 1 and path.segments[0] == "Unit"
          case _ -> false
        }
      }
      if isUnitRet {
        Some(value = TypeExpr(kind = TRef(path = singleSegPath("Task")), span = decl.span))
      } else {
        None
      }
    } else {
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
              match lambdaShapeOfArg(callArgExpr(args[i])) {
                case Some(lamE) -> {
                  match lamE.kind {
                    case ELambda(lps, lbody) -> unifyLambdaArgTE(state, env, typeParams, decl.params[i].ty, lps, lbody, subst)
                    case _ -> ()
                  }
                }
                case None -> {
                  // Direct union-case construction: bind only field-pinned
                  // slots (see partialUnifyCtorArg); everything else takes the
                  // full inferred TE.
                  var handled = false
                  match ctorSynthOfArg(state, callArgExpr(args[i])) {
                    case Some(ctorD) -> {
                      val ctorCallArgs = match unwrapParenExprMono(callArgExpr(args[i])).kind {
                        case ECall(_, cas) -> cas
                        case _ -> newList()
                      }
                      handled = partialUnifyCtorArg(state, env, typeParams, decl.params[i].ty, ctorD, ctorCallArgs, subst)
                    }
                    case None -> ()
                  }
                  if not handled {
                    match inferExprTE(state, env, callArgExpr(args[i])) {
                      case Some(argTE) -> unifyTE(typeParams, decl.params[i].ty, argTE, subst)
                      case None -> ()
                    }
                  }
                }
              }
              i = i + 1
            }
          }
        }
      }
      // Two decl classes report their UNPINNED type params as `Object`
      // rather than failing the whole inference (#5604):
      //   - Inference-only union-case ctor synths: mirrors exactly what
      //     codegen constructs for the corresponding slot with no hint or an
      //     erased hint (field-derived types win per slot; everything else
      //     fills as `object`), so `Ok(value = 7)` infers as
      //     `Result[Int, Object]`.
      //   - IMPORTED (non-dropped-local, non-axiom) generics: the call-site
      //     rewriter defaults exactly these params to Object when it
      //     specialises, so the value a binding receives really carries the
      //     filled instantiation (`val mapped = mapResult(Ok(5), f)` returns
      //     the `Result[Int, Object]` of `mapResult__Int__Int__Object`).
      //     Reporting `None` instead left the binding untyped, and a later
      //     `isOk(mapped)` specialised at `__Object__Object` — an
      //     instantiation the value never had, so its closed isinst missed
      //     every arm.
      // Same-package generics stay all-or-nothing: their uninferable call
      // sites raise M0002 at the rewriter, never a defaulted specialisation.
      val importedFill = (not state.droppedLocalGenerics.containsKey(fname)) and not annsHaveAxiomMono(decl.annotations)
      val fillsUnpinned = annsInferenceOnlyMono(decl.annotations) or importedFill
      if typeParams.count > 0 and fillsUnpinned {
        var uf = 0
        while uf < typeParams.count {
          if not subst.containsKey(typeParams[uf]) {
            subst.add(typeParams[uf], TypeExpr(kind = TRef(path = singleSegPath("Object")), span = decl.span))
          }
          uf = uf + 1
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
// The `"Type.Member"` string of an `@externTarget(...)` annotation, or "".
func externTargetStringMono(anns: in List[Annotation]): String {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "externTarget" {
      var j = 0
      while j < anns[i].args.count {
        match anns[i].args[j] {
          case ALiteral(v, _) -> match v { case AVString(s, _) -> { return s }; case _ -> () }
          case AAName(_, v, _) -> match v { case AVString(s, _) -> { return s }; case _ -> () }
          case _ -> ()
        }
        j = j + 1
      }
    }
    i = i + 1
  }
  ""
}

// True iff the function is an `@externTarget` over a *generic declaring type*
// (the target's type name carries a `\`N` arity suffix, e.g.
// `ConcurrentDictionary\`2`).  Only such externs are kept un-specialised by the
// monomorphizer: the MSIL backend's `emitGenericExternMember` can emit them, and
// a zero-arg ctor extern invoked from a module-`val` initializer (never walked
// by the monomorphizer) needs the generic definition to survive.  An extern over
// a NON-generic type (`Monitor.Enter`) is always reachable through its
// specialised call-site copies and never needs keeping; keeping it broadly would
// also force the JVM backend — which has no generic-extern emission — to compile
// erased collection-kernel externs (`newList` → `java.util.ArrayList.<init>`)
// it previously dropped, tripping F0015-J.
func annsKeepGenericExternMono(anns: in List[Annotation]): Bool {
  Str.contains(externTargetStringMono(anns), "`")
}

// True iff the annotation list carries `@axiom(...)`.
func annsHaveAxiomMono(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "axiom" {
      return true
    }
    i = i + 1
  }
  false
}

// Reserved compiler-internal marker (never parseable from source — `__lyric_`
// names are reserved): tags a FunctionDecl synthesized by
// `unionCtorInferenceDecls` purely so `inferExprTE` can type a union-case
// constructor call (`Some(value = 1)` → `Option[Int]`).  Marked decls join
// `funcDecls` (the inference surface) but NEVER `genDecls`: rewriting the
// call site to a specialised name (`Some__Int`) would break codegen's
// by-case-name union-construction resolution, and the decl has no body to
// specialise.
func annsInferenceOnlyMono(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "__lyric_union_ctor_infer" {
      return true
    }
    i = i + 1
  }
  false
}

/// Synthesize one inference-only constructor FunctionDecl per union case in
/// `items` (`case Some(value: T)` of `union Option[T]` →
/// `func Some[T](value: T): Option[T]`, body-less, tagged with the reserved
/// `__lyric_union_ctor_infer` annotation).  Feed the result into the
/// monomorphizer's imported-generics list so a generic call whose only
/// type-argument source is a union-case constructor argument
/// (`isSome(Some(value = 1))`) can bind its type parameters instead of
/// silently staying generic (#5604).  Positional case fields synthesize
/// `field<i>` parameter names; inference unifies positionally, so the names
/// only need to be distinct.
pub func unionCtorInferenceDecls(items: in List[Item]): List[FunctionDecl] {
  val ctorDecls: List[FunctionDecl] = newList()
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IUnion(decl) -> {
        val typeParamNames = extractTypeParamNames(decl.generics)
        val retTe = if typeParamNames.count > 0 {
          val retArgs: List[TypeArg] = newList()
          var gi = 0
          while gi < typeParamNames.count {
            retArgs.add(TAType(ty = TypeExpr(kind = TRef(path = singleSegPath(typeParamNames[gi])), span = decl.span)))
            gi = gi + 1
          }
          TypeExpr(kind = TGenericApp(head = singleSegPath(decl.name), args = retArgs), span = decl.span)
        } else {
          TypeExpr(kind = TRef(path = singleSegPath(decl.name)), span = decl.span)
        }
        val marker: List[Annotation] = newList()
        val markerArgs: List[AnnotationArg] = newList()
        marker.add(Annotation(name = singleSegPath("__lyric_union_ctor_infer"), args = markerArgs, span = decl.span))
        var ci = 0
        while ci < decl.cases.count {
          val c = decl.cases[ci]
          val ctorParams: List[Param] = newList()
          var fi = 0
          while fi < c.fields.count {
            val pName = match c.fields[fi] { case UFNamed(fname, _, _) -> fname; case UFPos(_, _) -> "field" + toString(fi) }
            val pTy = match c.fields[fi] { case UFNamed(_, fty, _) -> fty; case UFPos(fty, _) -> fty }
            val pAnns: List[Annotation] = newList()
            ctorParams.add(
              Param(mode = PMIn, modeExplicit = false, name = pName, ty = pTy, dflt = None, annotations = pAnns, span = c.span)
            )
            fi = fi + 1
          }
          val noDocs: List[DocComment] = newList()
          val noContracts: List[ContractClause] = newList()
          ctorDecls.add(
            FunctionDecl(
              docComments = noDocs,
              annotations = marker,
              visibility = None,
              isAsync = false,
              name = c.name,
              generics = decl.generics,
              params = ctorParams,
              ret = Some(value = retTe),
              whereClause = None,
              contracts = noContracts,
              body = None,
              span = c.span
            )
          )
          ci = ci + 1
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  ctorDecls
}

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
  // Preserve `@externTarget` (and the `@externStatic` / `@externInstance`
  // resolve hints) on the specialised copy: a monomorphised generic extern
  // wrapper (`cdSetItem[K, V]` -> `cdSetItem__String__RateEntry`) must keep
  // its kernel-boundary annotation, or codegen falls through to the
  // placeholder `= ()` body and emits a broken `ldnull; ret` stub — invalid
  // IL for a `Unit`/void return, and a silent always-false for a `Bool`
  // return (#3392 / #3175).  Every other annotation (`@stable`, `@axiom`,
  // doc markers, …) is intentionally dropped — a specialised copy is a fresh
  // codegen target, not a re-published surface.
  val keptAnns: List[Annotation] = newList()
  var ai = 0
  while ai < decl.annotations.count {
    val segs = decl.annotations[ai].name.segments
    if segs.count == 1 and (segs[0] == "externTarget" or segs[0] == "externStatic" or segs[0] == "externInstance") {
      keptAnns.add(decl.annotations[ai])
    }
    ai = ai + 1
  }
  // Substitute type-variable annotations inside the body too (#2557): a typed
  // local such as `val acc: List[T]` must become `List[Int]` in the specialised
  // copy, otherwise codegen emits a `List<Pkg.T>` over a non-existent CLR type.
  val newBody = match decl.body {
    case Some(b) -> Some(value = substTypesFunctionBody(subst, valueSubst, b))
    case None -> None
  }
  FunctionDecl(
    docComments = emptyDocs,
    annotations = keptAnns,
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
// `where T: …` bounds.  This is a best-effort spot check: when the bound
// names a well-known derive marker (the same closed vocabulary the type
// checker's `isKnownDeriveMarker` validates with T0051) and the type
// argument is a primitive, the primitive's capability set decides —
// every primitive carries Equals/Hash/Compare/Default, only numerics
// carry Sub/Mul/Div/Mod, and Add additionally holds for String
// (concatenation).  Everything else (user types, opaque types,
// interfaces, generic instantiations) accepts silently: mono operates on
// pre-resolution syntax and cannot see `@derive(...)` lists or impls —
// the type checker's `checkBoundsSatisfied` (T0108) owns that half.
// Confirmed mismatches produce an `M0001` error diagnostic at the call
// site span.
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

// Mirror of the type checker's `isKnownDeriveMarker`
// (`typechecker_checker.l`) — the single marker vocabulary T0051
// validates `where` bounds against.  A constraint name outside this set
// is either a user interface (accepted silently here; T0108 owns it) or
// was already rejected at the declaration.
func isKnownMarker(name: in String): Bool {
  name == "Add" or name == "Sub" or name == "Mul" or name == "Div" or name == "Mod" or name == "Compare" or
    name == "Hash" or
    name == "Equals" or
    name == "Default"
}

// A concrete type argument satisfies a well-known derive marker unless
// the mismatch can be ruled out syntactically: primitives carry a fixed
// capability set (see `primitiveSatisfiesMarker`).  Any non-primitive
// concrete type passes silently — without a resolver we can't tell
// whether a user-defined type carries the corresponding `@derive(X)`
// annotation; the type checker's T0108 covers that case.
func satisfiesMarker(te: in TypeExpr, marker: in String): Bool {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val nm = path.segments[0]
        if isPrimitiveName(nm) {
          primitiveSatisfiesMarker(nm, marker)
        } else {
          // Unknown user type: accept silently (best-effort).
          true
        }
      } else {
        // Qualified name (e.g. `Std.Time.Instant`): accept silently.
        true
      }
    }
    case TParen(inner) -> satisfiesMarker(inner, marker)
    case _ -> true
  }
}

// Which well-known markers a primitive satisfies: equality, hashing,
// ordering, and defaults hold for every primitive; the arithmetic
// markers only for numerics — with `Add` extended to `String`, whose
// `+` is concatenation.  `marker` is already `isKnownMarker`-filtered,
// so the fall-through covers exactly Sub / Mul / Div / Mod.
func primitiveSatisfiesMarker(name: in String, marker: in String): Bool {
  if marker == "Equals" or marker == "Hash" or marker == "Compare" or marker == "Default" {
    return true
  }
  if marker == "Add" {
    return isNumericPrimitiveName(name) or name == "String"
  }
  isNumericPrimitiveName(name)
}

func isNumericPrimitiveName(name: in String): Bool {
  name == "Int" or name == "Long" or name == "Short" or name == "Byte" or name == "UInt" or name == "ULong" or
    name == "UShort" or
    name == "UByte" or
    name == "Float" or
    name == "Double"
}

func isPrimitiveName(name: in String): Bool {
  isNumericPrimitiveName(name) or name == "Bool" or name == "Char" or name == "String"
}

// Emit `M0002` when a call site targeting a same-package generic function
// could not be rewritten to a specialisation.  Phase 2 erases the generic's
// declaration from the output, so leaving the call site referencing the
// generic name would hand codegen a dangling reference that lowers to a
// broken fallback call (a runtime crash on both managed targets) instead
// of a compile-time error (docs/59 §5.2 B2).  Only single-segment call
// sites are diagnosed: a qualified `Pkg.f(...)` may legitimately target a
// same-named function in another package (#3627), and a name shadowed by
// a typed local binding in `env` is a lambda/function-value call, not a
// call to the generic.
func noteUnspecialisableLocalCall(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  fname: in String,
  reason: in String,
  callSpan: in Span,
): Unit {
  if not state.droppedLocalGenerics.containsKey(fname) {
    return
  }
  if env.containsKey(fname) {
    return
  }
  state.diags.add(
    errorDiagnostic(
      "M0002",
      "call to generic function '" + fname + "' could not be monomorphised: " + reason +
        "; the generic declaration is erased after monomorphisation, so this call would not resolve at code generation — make the argument types inferable (e.g. bind the arguments to explicitly-typed locals) or wrap the call in a non-generic helper with annotated parameters",
      callSpan
    )
  )
}

// #5970: does `te` structurally reference any name in `names`?  Walks the
// same TypeExpr shapes `substTypeExpr` substitutes through, but tests
// membership instead of replacing.  Used to find parameter slots whose
// declared type actually depends on a type param the Object-default
// fallback is about to fill — the slots where an opaque runtime argument
// can crash a specialised body's structural match (see
// `importedFallbackHasUnresolvedFlow`).
func typeExprMentionsAnyName(te: in TypeExpr, names: in List[String]): Bool {
  match te.kind {
    case TRef(path) -> path.segments.count == 1 and listContainsStr(names, path.segments[0])
    case TGenericApp(_, targs) -> {
      var i = 0
      while i < targs.count {
        val hit = match targs[i] { case TAType(inner) -> typeExprMentionsAnyName(inner, names); case TAValue(_) -> false }
        if hit {
          return true
        }
        i = i + 1
      }
      false
    }
    case TTuple(ts) -> {
      var i = 0
      while i < ts.count {
        if typeExprMentionsAnyName(ts[i], names) {
          return true
        }
        i = i + 1
      }
      false
    }
    case TNullable(inner) -> typeExprMentionsAnyName(inner, names)
    case TSlice(elem) -> typeExprMentionsAnyName(elem, names)
    case TArray(_, elem) -> typeExprMentionsAnyName(elem, names)
    case TFunction(ps, r) -> {
      var i = 0
      while i < ps.count {
        if typeExprMentionsAnyName(ps[i], names) {
          return true
        }
        i = i + 1
      }
      typeExprMentionsAnyName(r, names)
    }
    case TParen(inner) -> typeExprMentionsAnyName(inner, names)
    case _ -> false
  }
}

// #5970: is `e` a shape mono ALREADY treats as a recognised-safe erasure
// point, independent of whether `inferExprTE` can name its type?
//
//   - A lambda (`{ x -> … }`): unification already tried
//     `unifyLambdaArgTE` against it (the per-argument loop above this
//     call site) and it stayed unbound.  Lambdas construct a fresh
//     closure AT THE CALL SITE from whatever the specialised body's
//     parameter type says — there is no pre-existing, independently-typed
//     runtime value to mismatch (the #5843/#5962 ambiguous-overload tests
//     document this as the intentional erased degradation).
//   - A bare reference to a NULLARY inference-only union case (e.g.
//     `NoneLike`, no parens, no fields): `ctorSynthOfArg` only recognises
//     the CALL form (`Some(value = …)`), so a nullary case reference never
//     reaches that unification path either — but it carries zero runtime
//     data, so it constructs exactly as erased-Object at the call site too
//     (the #5604 `isEmptyLike(NoneLike)` test documents this).
//
// Any other opaque shape (an unresolvable function call, an `if`/`match`/
// block whose value may already carry an independently-fixed closed-generic
// identity from elsewhere) is NOT recognised here and stays classified as
// risky by the caller.
func argIsRecognizedSafeErasure(state: in MonoState, e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> argIsRecognizedSafeErasure(state, inner)
    case ELambda(_, _) -> true
    case EPath(path) -> {
      if path.segments.count == 1 {
        match mapGet(state.funcDecls, path.segments[0]) {
          case Some(d) -> annsInferenceOnlyMono(d.annotations) and d.params.count == 0
          case None -> false
        }
      } else {
        false
      }
    }
    case _ -> false
  }
}

// #5970: before an IMPORTED generic's unbound type params are defaulted to
// `Object` (see the call site in the single-segment `EPath` rewrite arm),
// decide whether that default is the SAFE erased degradation (#5604) or the
// shape that crashes at runtime.
//
// Safe: no argument flows into a parameter slot whose declared type
// mentions an unbound param (e.g. a zero-arg call like `pickImported()`,
// or every unbound param only appears in the return type) — nothing
// opaque is being handed to the specialised body to pattern-match against,
// so an `Object`-typed slot is exactly the uniform erased ABI this
// function always had.  A lambda argument or a bare nullary-case reference
// is ALSO safe even when unresolved (`argIsRecognizedSafeErasure`) — both
// construct fresh, at the call site, under the same Object substitution.
//
// Unsafe: an argument DOES flow into such a slot, that argument's own type
// could not be inferred (`inferExprTE` returns `None`), AND it isn't one of
// the recognised-safe shapes above.  The specialised copy will pattern-match
// / narrow that slot as if it always carried `Object`, but the real argument
// may carry a genuinely different, independently-fixed closed-generic
// runtime identity (e.g. `Result[Unit, IOError]`) whose structural checks
// the erased `Object`/`Object` arms can never match — `InvalidProgramException`
// / "match not exhaustive" at runtime (#5970).  Reported loudly instead of
// silently defaulting.
func importedFallbackHasUnresolvedFlow(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  typeParams: in List[String],
  subst: in Map[String, TypeExpr],
  params: in List[Param],
  args: in List[CallArg],
): Bool {
  val unbound: List[String] = newList()
  var i = 0
  while i < typeParams.count {
    if not subst.containsKey(typeParams[i]) {
      unbound.add(typeParams[i])
    }
    i = i + 1
  }
  if unbound.count == 0 {
    return false
  }
  var ai = 0
  while ai < args.count and ai < params.count {
    if typeExprMentionsAnyName(params[ai].ty, unbound) {
      val argExpr = callArgExpr(args[ai])
      if not argIsRecognizedSafeErasure(state, argExpr) {
        match inferExprTE(state, env, argExpr) {
          case None -> return true
          case Some(_) -> ()
        }
      }
    }
    ai = ai + 1
  }
  false
}

// Emit `M0004` when an IMPORTED generic call site is about to default its
// unbound type param(s) to `Object` (the #5604 erased fallback) while an
// opaque, uninferable argument is flowing into a parameter slot that
// mentions those params — the shape `importedFallbackHasUnresolvedFlow`
// confirmed can crash at runtime against the argument's real closed-generic
// identity (#5970).  Unlike `noteUnspecialisableLocalCall`'s M0002 (a
// same-package generic whose declaration is erased outright), the imported
// generic's declaration still exists and specialises fine for OTHER call
// sites — only this call site's inference gap is the problem, so the
// message points at annotating the binding rather than the generic itself.
func noteUnresolvableImportedCall(state: in MonoState, fname: in String, unresolved: in String, callSpan: in Span): Unit {
  state.diags.add(
    errorDiagnostic(
      "M0004",
      "cannot infer type argument(s) " + unresolved + " for call to imported generic function '" + fname +
        "'; the argument's type could not be determined, and defaulting it to 'Object' here would produce a specialisation that can crash at runtime against the argument's real type — annotate the binding that produces this argument with its concrete type (e.g. `val r: Result[T, E] = …`) so the call can be monomorphised precisely",
      callSpan
    )
  )
}

// The subset of `typeParams` that `subst` failed to bind, rendered as a
// quoted comma-separated list for the M0002 message.
func unresolvedTypeParamList(typeParams: in List[String], subst: in Map[String, TypeExpr]): String {
  var acc = ""
  var i = 0
  while i < typeParams.count {
    if not subst.containsKey(typeParams[i]) {
      if acc.length > 0 {
        acc = acc + ", "
      }
      acc = acc + "'" + typeParams[i] + "'"
    }
    i = i + 1
  }
  acc
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

// Convert one index of a surface explicit type application
// (`f[String, WebRateEntry](...)`) to a `TypeArg`: a bare single-segment
// name that resolves as a type in this file's mono tables.  `None` for
// anything else so a genuine indexed-value call is never hijacked (a local
// value name, a literal, a qualified constant all stay indices).
func indexExprToTypeArgMono(state: in MonoState, e: in Expr): Option[TypeArg] {
  match e.kind {
    case EPath(p) -> {
      if p.segments.count == 1 {
        val nm = p.segments[0]
        if isPrimitiveName(nm) or state.recordDecls.containsKey(nm) or state.ifaceDecls.containsKey(nm) {
          Some(value = TAType(ty = TypeExpr(kind = TRef(path = p), span = e.span)))
        } else {
          None
        }
      } else {
        None
      }
    }
    case _ -> None
  }
}

// True iff, when `fname` is one of an ambiguous overload set, THIS call
// site's arguments actually resolve to `baseDecl` — the specific decl
// sitting in `state.genDecls` under that bare name.  `state.genDecls` is a
// first-wins slot exactly like `state.funcDecls` (see the collector in
// `monoFileWithImportsAndTypeDecls`): an ambiguous name's GENERIC candidate
// can occupy that slot even when a DIFFERENT, non-generic (or
// different-arity) overload is what a given call site actually means —
// e.g. `Validation.all(errors: in slice[slice[ValidationError]])` (arity 1,
// non-generic) and `Std.Iter.all[T](xs: in slice[T], pred: (T) -> Bool)`
// (arity 2, generic) share the bare name `all`.  Whichever is collected
// first wins the `genDecls` slot; if it's the generic, an unrelated arity-1
// call would otherwise be attempted against it — the call-site arity
// guards below (`args.count <= baseDecl.params.count`) only reject MORE
// args than params (the #3627/#3677 same-named-generic-with-fewer-params
// collision), never FEWER, so a 1-argument call against a 2-parameter
// generic slips through, gets "specialised" with an argument list that
// doesn't match the specialisation's real signature, and produces invalid
// IL at runtime.  When `fname` is unambiguous this is a no-op (`true`);
// when ambiguous, only a call site `resolveAmbiguousOverload` confirms
// targets THIS SPECIFIC (generic) candidate is allowed to proceed through
// the specialisation path below — any other outcome (the call resolves to
// a different overload, or can't be resolved at all) leaves the call
// untouched so it binds through normal, non-generic cross-package
// resolution at codegen, mirroring the existing "uninferable call to an
// imported generic stays silent" degradation.
func genDeclResolvesForCallSite(
  state: in MonoState,
  env: in Map[String, TypeExpr],
  fname: in String,
  args: in List[CallArg],
  baseDecl: in FunctionDecl,
): Bool {
  match mapGet(state.ambiguousFuncOverloads, fname) {
    case None -> true
    case Some(_) -> {
      match resolveAmbiguousOverload(state, env, fname, args) {
        case None -> false
        case Some(resolved) -> funcSigKeyMono(resolved) == funcSigKeyMono(baseDecl)
      }
    }
  }
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
                      // An ambiguous `fname` resolving to a DIFFERENT overload
                      // than the one sitting in `genDecls` is not a targs-count
                      // mismatch — silently leave the call untouched (no
                      // diagnostic) rather than firing the misleading "expected
                      // N explicit type argument(s)" message below.
                      if genDeclResolvesForCallSite(state, env, fname, args, baseDecl) {
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
                        noteUnspecialisableLocalCall(
                          state,
                          env,
                          fname,
                          "the explicit type arguments do not bind every generic parameter",
                          fn.span
                        )
                      }
                    } else {
                      noteUnspecialisableLocalCall(
                        state,
                        env,
                        fname,
                        "expected " + toString(allParams.count) + " explicit type argument(s), got " + toString(targs.count),
                        fn.span
                      )
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
                // A genuine call to this generic can never supply more arguments
                // than it has parameters; reject that case so an unrelated
                // same-named function isn't hijacked into a broken specialisation
                // (the unqualified sibling of the #3627 collision).  When `fname`
                // is ambiguous, `genDeclResolvesForCallSite` additionally confirms
                // THIS call site's arguments actually target the generic sitting
                // in `genDecls` (not, say, an unrelated non-generic overload that
                // merely has fewer params — #3677's guard above only rejects
                // MORE args than params, never fewer; see that helper's doc
                // comment for the `Validation.all`/`Std.Iter.all` shape this
                // closes).  A call that fails this check falls all the way
                // through to the final `Expr(...)` below, untouched — same as
                // the `case None` arm — so it binds through normal, non-generic
                // cross-package resolution at codegen instead of being rewritten
                // with an argument list that doesn't match the specialisation's
                // real signature (invalid IL at runtime).
                if typeParams.count > 0 and valueParams.count == 0 and args.count <= baseDecl.params.count {
                  if genDeclResolvesForCallSite(state, env, fname, args, baseDecl) {
                    // Pure type-generic call site: existing inference path
                    // (value generics require explicit `f[N]` type apps).
                    val subst: Map[String, TypeExpr] = newMap()
                    var i = 0
                    while i < args.count and i < baseDecl.params.count {
                      match lambdaShapeOfArg(callArgExpr(args[i])) {
                        case Some(lamE) -> {
                          match lamE.kind {
                            case ELambda(lps, lbody) -> unifyLambdaArgTE(state, env, typeParams, baseDecl.params[i].ty, lps, lbody, subst)
                            case _ -> ()
                          }
                        }
                        case None -> {
                          // Direct union-case construction: bind only
                          // field-pinned slots (see partialUnifyCtorArg).
                          var handled = false
                          match ctorSynthOfArg(state, callArgExpr(args[i])) {
                            case Some(ctorD) -> {
                              val ctorCallArgs = match unwrapParenExprMono(callArgExpr(args[i])).kind {
                                case ECall(_, cas) -> cas
                                case _ -> newList()
                              }
                              handled = partialUnifyCtorArg(state, env, typeParams, baseDecl.params[i].ty, ctorD, ctorCallArgs, subst)
                            }
                            case None -> ()
                          }
                          if not handled {
                            match inferExprTE(state, env, callArgExpr(args[i])) {
                              case Some(argTE) -> {
                                unifyTE(typeParams, baseDecl.params[i].ty, argTE, subst)
                              }
                              case None -> ()
                            }
                          }
                        }
                      }
                      i = i + 1
                    }
                    // An IMPORTED generic whose declaration is erased from every
                    // assembly (generic pub funcs are never emitted — the bundle
                    // drops them and `registerStdlibFunc` skips them) has exactly
                    // one executable form: a local specialisation.  When the
                    // arguments pin only some (or none) of the type parameters,
                    // default the unbound ones to `Object` — the erased
                    // uniform-ABI meaning the un-specialised call always had —
                    // instead of leaving the call generic, which codegen then
                    // silently DROPPED (arguments lowered, no call emitted:
                    // `isNone(None)` returned its own argument, #5604).  Local
                    // generics keep the loud M0002 below: their declaration is
                    // still in the file, so the erased-default is never the
                    // user's intent there.
                    if not substIsComplete(typeParams, subst) {
                      if not state.droppedLocalGenerics.containsKey(fname) and not annsHaveAxiomMono(baseDecl.annotations) {
                        // #5970: an opaque argument flowing into a slot that
                        // mentions an unbound param would default to `Object`
                        // here and crash the specialised body's structural
                        // match against the argument's real (possibly
                        // closed-generic) runtime identity — see
                        // `importedFallbackHasUnresolvedFlow`'s doc comment.
                        // Report loudly instead of defaulting in that case;
                        // every other unbound-param shape (zero-arg calls,
                        // params that don't mention the unbound params, or
                        // an argument mono DID manage to type) keeps the
                        // existing #5604 erased fallback unchanged.
                        if importedFallbackHasUnresolvedFlow(state, env, typeParams, subst, baseDecl.params, args) {
                          noteUnresolvableImportedCall(state, fname, unresolvedTypeParamList(typeParams, subst), fn.span)
                        } else {
                          var du = 0
                          while du < typeParams.count {
                            if not subst.containsKey(typeParams[du]) {
                              subst.add(typeParams[du], TypeExpr(kind = TRef(path = singleSegPath("Object")), span = fn.span))
                            }
                            du = du + 1
                          }
                        }
                      }
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
                    noteUnspecialisableLocalCall(
                      state,
                      env,
                      fname,
                      "could not infer type argument(s) " + unresolvedTypeParamList(typeParams, subst) + " from the call's arguments",
                      fn.span
                    )
                  }
                } else {
                  // The arity guard above deliberately skips calls with MORE
                  // args than the generic has params (they target an unrelated
                  // same-named function, #3677) — those stay silent.  A call
                  // with compatible arity to a value-generic function has no
                  // surface syntax for the explicit type application it needs,
                  // so it can never specialise: diagnose instead of leaving
                  // the dangling reference.
                  if valueParams.count > 0 and args.count <= baseDecl.params.count {
                    noteUnspecialisableLocalCall(
                      state,
                      env,
                      fname,
                      "value-generic parameters require an explicit type application, which this call site does not carry",
                      fn.span
                    )
                  }
                }
                Expr(kind = ECall(fn = fn, args = newArgs), span = s)
              }
              case None -> Expr(kind = ECall(fn = fn, args = newArgs), span = s)
            }
          } else {
            // Multi-segment qualified call: try the last segment as a generic
            // so `Validation.toResult(42,[])` specialises when `toResult[T]` is
            // in genDecls (imported from the `Validation` in-bundle package).
            // Same inference path as the single-segment case above (#2932).
            val qfname = path.segments[path.segments.count - 1]
            match mapGet(state.genDecls, qfname) {
              case Some(qBaseDecl) -> {
                val qTypeParams = extractTypeParamNames(qBaseDecl.generics)
                val qValueParams = extractValueParamNames(qBaseDecl.generics)
                // Guard against a bare-name collision: `genDecls` is keyed by
                // last segment only, so `Pkg.fn(a, b, c)` could otherwise match
                // an unrelated generic `fn[T](x)` in a *different* package (e.g.
                // `Testing.assertEq(a, b, msg)` vs `Std.Core.Proof.assertEq[T](x)`,
                // #3627).  A genuine call to this generic can never supply more
                // arguments than it has parameters, so reject that case and leave
                // the call for normal (non-generic) resolution.  `genDeclResolvesForCallSite`
                // closes the same-arity ambiguous-name hole (see its doc comment)
                // for a qualified call too.
                if qTypeParams.count > 0 and qValueParams.count == 0 and args.count <= qBaseDecl.params.count and genDeclResolvesForCallSite(state, env, qfname, args, qBaseDecl) {
                  val qSubst: Map[String, TypeExpr] = newMap()
                  var qi = 0
                  while qi < args.count and qi < qBaseDecl.params.count {
                    match inferExprTE(state, env, callArgExpr(args[qi])) {
                      case Some(qArgTE) -> unifyTE(qTypeParams, qBaseDecl.params[qi].ty, qArgTE, qSubst)
                      case None -> ()
                    }
                    qi = qi + 1
                  }
                  if substIsComplete(qTypeParams, qSubst) {
                    val qAllParams = extractAllParamInfo(qBaseDecl.generics)
                    val qEmptyVS: Map[String, Expr] = newMap()
                    val qName = specFuncName(qfname, qAllParams, qSubst, qEmptyVS)
                    validateWhereBounds(qBaseDecl, qSubst, fn.span, state.diags)
                    if not state.seenSpecs.containsKey(qName) {
                      state.seenSpecs.add(qName, true)
                      val qSpecDecl = specializeFunc(qBaseDecl, qName, qSubst, qEmptyVS)
                      state.allSpecs.add(
                        SpecRequest(specName = qName, baseDecl = qSpecDecl, subst = qSubst, valueSubst = qEmptyVS, callSpan = fn.span)
                      )
                    }
                    val qNewFn = singleSegPathExpr(qName, fn.span)
                    return Expr(kind = ECall(fn = qNewFn, args = newArgs), span = s)
                  }
                }
                Expr(kind = ECall(fn = fn, args = newArgs), span = s)
              }
              case None -> Expr(kind = ECall(fn = fn, args = newArgs), span = s)
            }
          }
        }
        case EIndex(idxRecv, idxExprs) -> {
          // Surface explicit type application: `f[T, U](args)` parses as
          // `ECall(EIndex(EPath([f]), [T, U]))` — the parser never builds
          // `ETypeApp` (see mono_self_test.l's synthetic-AST note), so the
          // ETypeApp arm above was unreachable from real source.  Recognise
          // the shape when `f` names a known generic AND every index is a
          // bare single-segment name resolvable as a type in this file's
          // tables (primitive / record / interface) — then route through the
          // ETypeApp arm via a synthetic node.  Anything else (a genuine
          // indexed-value call, a value-generic literal index, an
          // unresolvable name) falls through unchanged, exactly as before.
          match idxRecv.kind {
            case EPath(ipath) -> {
              if ipath.segments.count == 1 and state.genDecls.containsKey(ipath.segments[0]) and idxExprs.count > 0 {
                val targsConv: List[TypeArg] = newList()
                var convOk = true
                var xi = 0
                while xi < idxExprs.count {
                  match indexExprToTypeArgMono(state, idxExprs[xi]) {
                    case Some(ta) -> targsConv.add(ta)
                    case None -> {
                      convOk = false
                    }
                  }
                  xi = xi + 1
                }
                if convOk {
                  val taFn = Expr(kind = ETypeApp(fn = idxRecv, args = targsConv), span = fn.span)
                  return rewriteExpr(state, env, Expr(kind = ECall(fn = taFn, args = args), span = s))
                }
              }
            }
            case _ -> ()
          }
          Expr(kind = ECall(fn = rewriteExpr(state, env, fn), args = newArgs), span = s)
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
// The env TE for an ANNOTATED binding: when the initializer is a call to a
// known (non-ctor-synth) single-segment function, the runtime value's closed
// instantiation is decided by the CALLEE's specialisation — not by the
// binding annotation.  `val err: Result[Int, Int] = andThenResult(...)`
// annotates a value that actually carries the callee's `Result[Object, Int]`
// instantiation; tracking the annotation would make a later `isErr(err)`
// specialise (and closed-isinst) at an instantiation the value never had
// (#5604).  A DIRECT construction initializer keeps the annotation: codegen
// threads the annotation into the construction as its per-slot hint, so
// there the annotation IS the runtime instantiation.
func bindingEnvTE(state: in MonoState, env: in Map[String, TypeExpr], annoTe: in TypeExpr, init: in Expr): TypeExpr {
  val callFnName = match unwrapParenExprMono(init).kind {
    case ECall(fn, _) -> {
      match fn.kind {
        case EPath(fp) -> if fp.segments.count == 1 { fp.segments[0] } else { "" }
        case _ -> ""
      }
    }
    case _ -> ""
  }
  if callFnName.length == 0 {
    return annoTe
  }
  val isNonCtorCall = match mapGet(state.funcDecls, callFnName) {
    case Some(d) -> not annsInferenceOnlyMono(d.annotations)
    case None -> false
  }
  if not isNonCtorCall {
    return annoTe
  }
  match inferExprTE(state, env, init) {
    case Some(te) -> te
    case None -> annoTe
  }
}

func rewriteBinding(state: in MonoState, env: in Map[String, TypeExpr], binding: in LocalBinding): LocalBinding {
  match binding {
    case LBVal(pat, tyOpt, init) -> {
      match tyOpt {
        case Some(te) -> trackPatternEnv(env, pat, bindingEnvTE(state, env, te, init))
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
          val envTe = match initOpt { case Some(ie) -> bindingEnvTE(state, env, te, ie); case None -> te }
          if env.containsKey(name) {
            env.remove(name)
          }
          env.add(name, envTe)
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
          env.add(name, bindingEnvTE(state, env, te, init))
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
  val emptyIfaces: List[InterfaceDecl] = newList()
  monoFileWithImportsAndIfaces(file, importedGenDecls, emptyIfaces)
}

/// As `monoFileWithImports`, but also takes the interface decls visible to
/// `file` (same-package interfaces are collected from the file itself;
/// `importedIfaceDecls` carries cross-package ones).  These let the inferer
/// resolve a method-call return type (`recv.method(...)`) on an
/// interface-typed receiver, which is what lets a generic predicate over the
/// method's result — e.g. `isOk(bucket.exists(...))` — specialise instead of
/// staying type-erased (#3813).
pub func monoFileWithImportsAndIfaces(
  file: in SourceFile,
  importedGenDecls: in List[FunctionDecl],
  importedIfaceDecls: in List[InterfaceDecl],
): MonoResult {
  val emptyRecs: List[RecordDecl] = newList()
  monoFileWithImportsAndTypeDecls(file, importedGenDecls, importedIfaceDecls, emptyRecs)
}

/// As `monoFileWithImportsAndIfaces`, but also takes cross-package *record*
/// decls.  These let the inferer resolve a field projection (`recv.field`) on
/// a value whose record type is declared in another package, so a generic
/// predicate over that field — e.g. `isSome(page.nextContinuationToken)` where
/// `page: ListResult` is an imported record and `nextContinuationToken:
/// Option[String]` — specialises instead of staying type-erased (#3813
/// follow-up; the lyric-storage `list` pagination case).
pub func monoFileWithImportsAndTypeDecls(
  file: in SourceFile,
  importedGenDecls: in List[FunctionDecl],
  importedIfaceDecls: in List[InterfaceDecl],
  importedRecordDecls: in List[RecordDecl],
): MonoResult {
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
  // #3813: interface decls keyed by simple name, for method-return inference.
  val ifaceDecls: Map[String, InterfaceDecl] = newMap()
  // #5841: same-package distinct/range-subtype decls, for the
  // `Type.from`/`Type.tryFrom` static-factory return-type special case.
  val distinctDecls: Map[String, DistinctTypeDecl] = newMap()
  // Same-file generic functions that Phase 2 will erase from the output —
  // an unrewritten call site to one of these is a dangling reference and
  // must raise M0002 (docs/59 §5.2 B2).  `@externTarget`-kept generics
  // survive Phase 2 and `@axiom` generics are proof-only, so neither is
  // eligible.
  val droppedLocalGenerics: Map[String, Bool] = newMap()
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
            if not annsHaveAxiomMono(decl.annotations) and not annsKeepGenericExternMono(decl.annotations) {
              if not droppedLocalGenerics.containsKey(decl.name) {
                droppedLocalGenerics.add(decl.name, true)
              }
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
      case IInterface(decl) -> {
        if not ifaceDecls.containsKey(decl.name) {
          ifaceDecls.add(decl.name, decl)
        }
        collectIfaceGenerics(decl, genDecls, funcDecls)
      }
      case IImpl(decl) -> collectImplGenerics(decl, genDecls, funcDecls)
      case IDistinctType(decl) -> {
        if not distinctDecls.containsKey(decl.name) {
          distinctDecls.add(decl.name, decl)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }

  // Merge imported (cross-package) interface decls.  Same-package wins on
  // name collision, mirroring the imported-generic merge below.
  var ii2 = 0
  while ii2 < importedIfaceDecls.count {
    val idf = importedIfaceDecls[ii2]
    if not ifaceDecls.containsKey(idf.name) {
      ifaceDecls.add(idf.name, idf)
    }
    ii2 = ii2 + 1
  }

  // Merge imported (cross-package) record decls — same-package wins.  Lets
  // `recv.field` projections resolve when `recv`'s record type is declared in
  // another package (#3813 follow-up).
  var ir2 = 0
  while ir2 < importedRecordDecls.count {
    val rdf = importedRecordDecls[ir2]
    if not recordDecls.containsKey(rdf.name) {
      recordDecls.add(rdf.name, rdf)
    }
    ir2 = ir2 + 1
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
  // #5843: two distinct cross-package functions sharing a bare name (e.g.
  // `Std.String.toUpper(String): String` and `Std.Char.toUpper(Char): Char`
  // — `pipeAddNonGenericFuncs` collects every stdlib package's `pub func`s
  // into one flat pool regardless of what the compiled file actually
  // imports) previously resolved to whichever decl happened to be collected
  // first — an arbitrary, package-iteration-order artefact, not the
  // signature the type checker actually resolved at any given call site.
  // A generic caller inferring its type argument off the WRONG overload's
  // return type (e.g. `mapOption(opt, { s: String -> toUpper(s) })`
  // specialising against `Char` instead of `String`) mis-specialises into a
  // real closed instantiation the runtime value never had, crashing with an
  // `InvalidCastException`/`InvalidProgramException` at the call site.
  //
  // A prior fix (#5843, superseded here) tracked the first-seen signature
  // per name and, on a genuine conflict, evicted the name from both
  // `funcDecls` and `genDecls` entirely so `inferReturnFromName` safely
  // missed instead of guessing.  That is too blunt for common cross-package
  // code: real programs routinely have several DIFFERENT functions sharing
  // a name (`Std.Directory.delete(String)`, `Storage.delete(bucket, key)`,
  // `Cache.delete(store, key)`) where the call site itself already
  // disambiguates (argument count, argument types) — evicting the name
  // outright threw away that information and pushed the call onto the
  // Object-fallback specialisation path, which does not merely leave the
  // call un-specialised — it CRASHES at runtime
  // (`InvalidProgramException`/non-exhaustive match) against a real generic
  // instantiation the erased `Object`/`Object` arms can never match.  Track
  // every distinct-signature candidate per ambiguous name in
  // `ambiguousFuncOverloads` instead, and resolve each CALL SITE against
  // that table (`resolveAmbiguousOverload`) — only a call site that
  // genuinely can't be resolved (e.g. an untyped argument) still degrades
  // to the Object fallback, same as an unknown callee.  Inference-only
  // union-ctor synths never participate: they are appended last
  // specifically so a real function's entry always wins their name
  // collision (see the comment below), not a queue of equally-weighted
  // "real" candidates.
  val importedFuncSigKeys: Map[String, String] = newMap()
  val ambiguousImportedFuncNames: Map[String, Bool] = newMap()
  val ambiguousFuncOverloads: Map[String, List[FunctionDecl]] = newMap()
  // Snapshot the names Phase 1 already registered from the SAME package
  // before any imported decl is merged (#5961): a same-package local always
  // shadows every import ("same-package wins on name collision"), so an
  // ambiguity between two IMPORTS of that name is irrelevant to inference
  // (the local is what the type checker resolves at every local call site)
  // — never build an overload table for it, and never let an import
  // overwrite its `funcDecls`/`genDecls` entry.  During the loop,
  // `funcDecls.containsKey` alone can't make this distinction: an earlier
  // iteration may have added an IMPORTED decl under the same name.
  val localFuncNames: Map[String, Bool] = newMap()
  val preImportNames = mapKeys(funcDecls)
  var pin = 0
  while pin < preImportNames.count {
    localFuncNames.add(preImportNames[pin], true)
    pin = pin + 1
  }
  var ig = 0
  while ig < importedGenDecls.count {
    val idecl = importedGenDecls[ig]
    if not annsInferenceOnlyMono(idecl.annotations) {
      val sigKey = funcSigKeyMono(idecl)
      match mapGet(importedFuncSigKeys, idecl.name) {
        case None -> importedFuncSigKeys.add(idecl.name, sigKey)
        case Some(prevKey) -> {
          if prevKey != sigKey {
            if not ambiguousImportedFuncNames.containsKey(idecl.name) {
              ambiguousImportedFuncNames.add(idecl.name, true)
            }
            if not localFuncNames.containsKey(idecl.name) {
              // Seed the overload table with the first-seen representative
              // (already sitting in `funcDecls`, added on this name's first
              // iteration below) — `addAmbiguousOverloadCandidate` dedupes
              // by signature, so re-seeding on a 3rd/4th distinct overload
              // is a harmless no-op.
              match mapGet(funcDecls, idecl.name) {
                case Some(firstDecl) -> addAmbiguousOverloadCandidate(ambiguousFuncOverloads, firstDecl, funcSigKeyMono(firstDecl))
                case None -> ()
              }
              addAmbiguousOverloadCandidate(ambiguousFuncOverloads, idecl, sigKey)
            }
          }
        }
      }
    }
    // First-seen representative wins (unconditionally kept, never evicted)
    // so non-inference-precision-critical consumers — `funcDeclArityMatches`'
    // fallback, `ctorSynthOfArg`, `bindingEnvTE`'s non-ctor-call check — see
    // a real function under this name.  Every entry `ambiguousFuncOverloads`
    // ever holds is a non-inference-only real function (inference-only
    // union-ctor synths are excluded above from ambiguity detection
    // entirely), so those consumers' `annsInferenceOnlyMono` checks are
    // correct regardless of which representative they see.
    if not funcDecls.containsKey(idecl.name) {
      funcDecls.add(idecl.name, idecl)
      // Inference-only union-ctor synths (see `annsInferenceOnlyMono`) join
      // the inference surface but must never become specialisation
      // candidates.
      match idecl.generics {
        case Some(_) -> {
          if not genDecls.containsKey(idecl.name) and not annsInferenceOnlyMono(idecl.annotations) {
            genDecls.add(idecl.name, idecl)
          }
        }
        case None -> ()
      }
    }
    ig = ig + 1
  }

  // Same-file union-case constructors join the inference surface too, so a
  // generic call typed only by a local union's constructor argument
  // (`isSome(MyCase(x = 1))` against a same-file union) infers exactly like
  // the imported-union path above.  Real functions win name collisions (the
  // `containsKey` guard), and none of these enter `genDecls`.
  val localUnionCtors = unionCtorInferenceDecls(file.items)
  var lu = 0
  while lu < localUnionCtors.count {
    val ldecl = localUnionCtors[lu]
    if not funcDecls.containsKey(ldecl.name) {
      funcDecls.add(ldecl.name, ldecl)
    }
    lu = lu + 1
  }

  // If nothing to monomorphise, return early.
  if genDecls.count == 0 {
    val emptyRewrites: Map[String, String] = newMap()
    val emptyDiags: List[Diagnostic] = newList()
    return MonoResult(file = file, rewrites = emptyRewrites, diagnostics = emptyDiags)
  }

  val state = newMonoState(
    genDecls,
    funcDecls,
    recordDecls,
    ifaceDecls,
    distinctDecls,
    droppedLocalGenerics,
    ambiguousFuncOverloads
  )

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
            //
            // Exception: a generic `@externTarget` kernel wrapper is kept (with
            // its type parameters erased by codegen's generic-extern path).  A
            // call site reached by the monomorphizer is still rewritten to a
            // concrete copy, but call sites the monomorphizer does NOT walk —
            // e.g. a zero-argument ctor extern (`newConcurrentDict()`) invoked
            // from a module-level `val` initializer — keep calling the generic
            // name, which would resolve to nothing if it were dropped.  `@axiom`
            // generics stay dropped (proof-only, never emitted as runtime code).
            if annsKeepGenericExternMono(decl.annotations) and not annsHaveAxiomMono(decl.annotations) {
              rewrittenItems.add(item)
            }
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
              // resolve to the impl target's record fields.  Impl methods
              // declare the receiver as an explicit `self: in Target` param
              // (D037), so seedEnvFromParams may already have bound the name —
              // rebind with the authoritative impl target rather than double-add.
              if env.containsKey("self") {
                env.remove("self")
              }
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
      // Module-level `val` initializers are function-free bodies too: a
      // generic call in one (`val m: Dict[String, Entry] = newDict[String,
      // Entry]()`) must specialise exactly like a call inside a function
      // body — without this arm the init passed through untouched, its
      // explicit type application never produced a specialisation, and the
      // call site dangled against a generic that phase 2 erases
      // (NoSuchMethodError at class init on the JVM, which emits only
      // specialised copies).
      case IVal(decl) -> {
        val env: Map[String, TypeExpr] = newMap()
        match decl.ty {
          case Some(te) -> trackPatternEnv(env, decl.pattern, te)
          case None -> ()
        }
        rewrittenItems.add(
          Item(
            docComments = item.docComments,
            annotations = item.annotations,
            visibility = item.visibility,
            kind = IVal(
              decl = ValDecl(
                pattern = decl.pattern,
                ty = decl.ty,
                init = rewriteExpr(state, env, decl.init),
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
  // adds a deeper specialisation) terminates with a clear M0003 error
  // (formerly a compiler panic) instead of OOM'ing the compiler.
  // 10_000 specialisations is well beyond any reasonable program; real
  // codebases land in the low hundreds.
  val finalSpecDecls: List[FunctionDecl] = newList()
  val specBudget = 10000

  var wi = 0
  while wi < state.allSpecs.count {
    if wi >= specBudget {
      val overReq = state.allSpecs[wi]
      state.diags.add(
        errorDiagnostic(
          "M0003",
          "monomorphisation budget exhausted (" + toString(specBudget) +
            " specialisations) while expanding generic function '" +
            extractBaseName(overReq.specName) +
            "' — a generic most likely recurses with an unbounded type-argument shape (e.g. `f[T]` instantiating `f[List[T]]`); refactor the recursion to stop instantiating with strictly larger types",
          overReq.callSpan
        )
      )
      // Stop expanding; the error diagnostic aborts the build in every
      // bridge, so the truncated specialisation list is never emitted.
      break
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
